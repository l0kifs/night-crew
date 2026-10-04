import Foundation
import NightCrewCore

/// `nightcrew watch`: the real poll loop (timer + FSEvents) in dry-run mode. Actions are printed, never executed,
/// and no outcome is recorded, so a needed action repeats every poll.
struct WatchCommand {
    var duration: TimeInterval
    var mode: Mode

    func run() -> Never {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let poller = Poller(processes: ProcessProbe(), transcripts: TranscriptProbe(), power: PowerControl(),
                            ownership: OwnershipFile(), clock: SystemClock())
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.S"
        print("Dry run for \(Int(duration)) s, mode \(mode): actions are printed, not executed.")

        let loop = PollLoop(poller: poller, watchedPaths: [home.appendingPathComponent(".claude/projects").path,
                                                          home.appendingPathComponent(".codex/sessions").path]) { tick, trigger, persist in
            let sessions = tick.activity.sessions
            let actions = tick.output.actions.isEmpty ? "nothing" : tick.output.actions.map { "\($0)" }.joined(separator: ", ")
            print("\(clock.string(from: tick.at))  [\(trigger.rawValue)]  \(tick.output.status) · awake \(tick.output.awake)"
                  + " · \(sessions.filter(\.working).count)/\(sessions.count) sessions working · would run: \(actions)"
                  + (persist == nil ? "" : " · would persist lastWorkingAt"))
        }
        loop.mode = mode
        loop.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            loop.stop()
            exit(0)
        }
        dispatchMain()
    }
}
