import CoreServices
import Foundation
import NightCrewCore

struct OwnershipFile: OwnershipStoring {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nightcrew/owned")

    func isOwned() -> Bool { FileManager.default.fileExists(atPath: Self.url.path) }

    /// The file and its directory entry are fsync'ed before this returns (SPEC §8).
    func create() throws {
        let folder = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = open(Self.url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(file) }
        guard fsync(file) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = open(folder.path, O_RDONLY)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }

    func remove() throws {
        if unlink(Self.url.path) != 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

/// Runs `Poller` every `pollInterval`, plus at once when a transcript changes while the Mac is not kept awake
/// (SPEC §5.3). With a `runner`, the engine's actions are executed and their outcomes recorded; without, it is a
/// dry run. Everything runs on one serial queue.
final class PollLoop: ModeStoring {
    enum Trigger: String { case timer, transcript, request }

    /// Set from any thread; read on the poll queue.
    var mode: Mode {
        get { queue.sync { currentMode } }
        set { queue.async { self.currentMode = newValue } }
    }

    /// Set from any thread; applied on the poll queue.
    var config: Config {
        get { queue.sync { poller.config } }
        set { queue.async { self.poller.config = newValue } }
    }

    private let queue = DispatchQueue(label: "dev.l0kifs.nightcrew.poll")
    private var poller: Poller
    private var currentMode: Mode = .auto
    private let watchedPaths: [String]
    private let onTick: (Tick, Trigger, _ outcomes: [Outcome], _ persistLastWorkingAt: Date?) -> Void
    /// Set before `start()`. Nil = dry run.
    var runner: ActionRunner?
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?

    init(poller: Poller, watchedPaths: [String], onTick: @escaping (Tick, Trigger, [Outcome], Date?) -> Void) {
        self.poller = poller
        self.watchedPaths = watchedPaths
        self.onTick = onTick
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: poller.config.pollInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll(.timer) }
        timer.resume()
        self.timer = timer
        startTranscriptWatch()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Stops polling and gives back an owned SleepDisabled (SPEC §8 Quit / SIGTERM / SIGINT).
    func shutdown() -> Outcome? {
        queue.sync {
            stop()
            return runner?.shutdown()
        }
    }

    /// Polls now instead of waiting for the timer, e.g. after a menu choice.
    func pollNow() {
        queue.async { self.poll(.request) }
    }

    /// The menu's Retry item.
    func retry() {
        queue.async { self.poller.retry() }
    }

    /// `ActionRunner` calls this on the poll queue when Always awake expires.
    func revertToAuto() {
        currentMode = .auto
    }

    private func poll(_ trigger: Trigger) {
        let tick = poller.tick(mode: currentMode)
        var outcomes: [Outcome] = []
        if let runner {
            for action in tick.output.actions {
                if let outcome = runner.run(action) {
                    poller.record(outcome)
                    outcomes.append(outcome)
                }
            }
        }
        onTick(tick, trigger, outcomes, poller.lastWorkingAtToPersist())
    }

    private func transcriptChanged() {
        if poller.shouldPollOnTranscriptChange() { poll(.transcript) }
    }

    /// FSEvents on the transcript roots, latency 0.5 s; NoDefer delivers the first event of a burst at once.
    private func startTranscriptWatch() {
        let paths = watchedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<PollLoop>.fromOpaque(info).takeUnretainedValue().transcriptChanged()
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
