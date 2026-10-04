import AppKit
import NightCrewCore
import os

private let log = Logger(subsystem: "dev.l0kifs.nightcrew", category: "app")
private let stateFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nightcrew")

/// Notifications need an app bundle (UNUserNotificationCenter); until `bundle.sh` exists they are logged.
struct LogNotifier: Notifying {
    func notify(_ notice: Notice) { log.notice("notification: \(String(describing: notice), privacy: .public)") }
}

enum MenuApp {
    /// SPEC §8: one instance, always under launchd. Without `--launchd`, hand off to the LaunchAgent if it is
    /// loaded; if not (not installed, or Launch at login off), run in-process.
    static func run(launchedByLaunchd: Bool) -> Never {
        if !launchedByLaunchd && kickstartLaunchAgent() {
            print("Handed off to the NightCrew LaunchAgent.")
            exit(0)
        }
        guard acquireInstanceLock() else {
            print("NightCrew is already running.")
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }

    private static func kickstartLaunchAgent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/dev.l0kifs.nightcrew"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `flock` on `~/.nightcrew/lock`, held until the process exits.
    private static func acquireInstanceLock() -> Bool {
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        let descriptor = open(stateFolder.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var loop: PollLoop!
    private var menu: MenuController!
    private var signalSources: [DispatchSourceSignal] = []
    private var lastStatusKind: String?
    private var shutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let poller = Poller(config: settings.config, lastWorkingAt: settings.lastWorkingAt, processes: ProcessProbe(),
                            transcripts: TranscriptProbe(), power: PowerControl(), ownership: OwnershipFile(),
                            clock: SystemClock())
        let home = FileManager.default.homeDirectoryForCurrentUser
        let heartbeat = stateFolder.appendingPathComponent("heartbeat")
        loop = PollLoop(poller: poller, watchedPaths: [home.appendingPathComponent(".claude/projects").path,
                                                      home.appendingPathComponent(".codex/sessions").path]) { [weak self] tick, trigger, outcomes, persist in
            // Poll queue: heartbeat for the watchdog (§8), persisted lastWorkingAt (§6.2).
            FileManager.default.createFile(atPath: heartbeat.path, contents: nil)
            DispatchQueue.main.async { self?.handle(tick, trigger: trigger, outcomes: outcomes, persist: persist) }
        }
        loop.runner = ActionRunner(power: PowerControl(), ownership: OwnershipFile(), notifier: LogNotifier(), modes: loop)
        loop.mode = settings.mode
        menu = MenuController(settings: settings, loop: loop) { [weak self] in self?.quit() }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signalSources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            return source
        }
        log.notice("started, mode \(String(describing: self.settings.mode), privacy: .public)")
        loop.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        giveBackSleep()
    }

    private func handle(_ tick: Tick, trigger: PollLoop.Trigger, outcomes: [Outcome], persist: Date?) {
        if let persist { settings.lastWorkingAt = persist }
        if tick.output.actions.contains(.revertModeToAuto) { settings.mode = .auto }
        // §12: every state transition, not every poll.
        let kind = Self.kind(of: tick.output.status) + (tick.output.awake ? " (awake)" : "")
        if kind != lastStatusKind {
            log.notice("state \(self.lastStatusKind ?? "start", privacy: .public) → \(kind, privacy: .public)")
            lastStatusKind = kind
        }
        for outcome in outcomes { log.notice("outcome \(String(describing: outcome), privacy: .public)") }
        menu.update(tick)
    }

    /// The status without its changing payload (grace minutes, session counts), for transition logging.
    private static func kind(of status: Status) -> String {
        switch status {
        case .awake: return "awake"
        case .grace: return "grace"
        case .alwaysAwake: return "alwaysAwake"
        case .pausedBattery: return "pausedBattery"
        case .error(let message): return "error(\(message))"
        default: return String(describing: status)
        }
    }

    private func quit() {
        giveBackSleep()
        NSApp.terminate(nil)
    }

    private func giveBackSleep() {
        guard !shutDown else { return }
        shutDown = true
        let outcome = loop.shutdown()
        log.notice("quit: \(outcome.map { String(describing: $0) } ?? "nothing owned", privacy: .public)")
    }
}
