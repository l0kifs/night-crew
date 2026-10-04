import CoreServices
import Foundation
import NightCrewCore

struct OwnershipFile: OwnershipReading {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nightcrew/owned")
    func isOwned() -> Bool { FileManager.default.fileExists(atPath: Self.url.path) }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

/// Runs `Poller` every `pollInterval`, plus at once when a transcript changes while the Mac is not kept awake
/// (SPEC §5.3). Everything runs on one serial queue.
final class PollLoop {
    enum Trigger: String { case timer, transcript }

    /// Set from any thread; read on the poll queue.
    var mode: Mode {
        get { queue.sync { currentMode } }
        set { queue.async { self.currentMode = newValue } }
    }

    private let queue = DispatchQueue(label: "dev.l0kifs.nightcrew.poll")
    private var poller: Poller
    private var currentMode: Mode = .auto
    private let watchedPaths: [String]
    private let onTick: (Tick, Trigger, _ persistLastWorkingAt: Date?) -> Void
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?

    init(poller: Poller, watchedPaths: [String], onTick: @escaping (Tick, Trigger, Date?) -> Void) {
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

    private func poll(_ trigger: Trigger) {
        let tick = poller.tick(mode: currentMode)
        onTick(tick, trigger, poller.lastWorkingAtToPersist())
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
