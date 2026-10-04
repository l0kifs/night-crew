import Foundation
import NightCrewCore

struct PrintNotifier: Notifying {
    func notify(_ notice: Notice) { print("  notification: \(notice)") }
}

/// `nightcrew watch`: the real poll loop (timer + FSEvents). Dry run by default: actions are printed, never
/// executed, and no outcome is recorded, so a needed action repeats every poll. `--live` executes them through
/// `ActionRunner` (sudo -n pmset, ownership file) and gives an owned SleepDisabled back on exit or Ctrl-C.
struct WatchCommand {
    var duration: TimeInterval
    var mode: Mode
    var live: Bool

    func run() -> Never {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let poller = Poller(processes: ProcessProbe(), transcripts: TranscriptProbe(), power: PowerControl(),
                            ownership: OwnershipFile(), clock: SystemClock())
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.S"
        print(live ? "Live for \(Int(duration)) s, mode \(mode): actions are executed. Ctrl-C gives sleep back."
                   : "Dry run for \(Int(duration)) s, mode \(mode): actions are printed, not executed.")

        let loop = PollLoop(poller: poller, watchedPaths: [home.appendingPathComponent(".claude/projects").path,
                                                          home.appendingPathComponent(".codex/sessions").path]) { tick, trigger, outcomes, persist in
            let sessions = tick.activity.sessions
            let actions = tick.output.actions.isEmpty ? "nothing" : tick.output.actions.map { "\($0)" }.joined(separator: ", ")
            print("\(clock.string(from: tick.at))  [\(trigger.rawValue)]  \(tick.output.status) · awake \(tick.output.awake)"
                  + " · \(sessions.filter(\.working).count)/\(sessions.count) sessions working"
                  + " · \(live ? "ran" : "would run"): \(actions)"
                  + (outcomes.isEmpty ? "" : " → \(outcomes.map { "\($0)" }.joined(separator: ", "))")
                  + (tick.output.iconError ? " · icon: error" : "")
                  + (persist == nil ? "" : " · persist lastWorkingAt"))
        }
        if live {
            loop.runner = ActionRunner(power: PowerControl(), ownership: OwnershipFile(), notifier: PrintNotifier(), modes: loop)
        }
        loop.mode = mode
        loop.start()

        func finish(_ reason: String) -> Never {
            let outcome = loop.shutdown()
            print("\(reason): \(outcome.map { "gave SleepDisabled back → \($0)" } ?? "nothing owned, nothing to give back")")
            exit(0)
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { finish(number == SIGINT ? "Interrupted" : "Terminated") }
            source.resume()
            return source
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            _ = signals
            finish("Done")
        }
        dispatchMain()
    }
}
