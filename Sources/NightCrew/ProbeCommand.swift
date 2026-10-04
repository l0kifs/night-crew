import Foundation
import NightCrewCore

/// `nightcrew probe`: prints what session detection sees, poll by poll. The calibration log of SPEC §5.3.
struct ProbeCommand {
    var duration: TimeInterval
    var config = Config()

    func run() {
        let processProbe = ProcessProbe()
        let transcriptProbe = TranscriptProbe()
        var tracker = ActivityTracker(config: config)
        let home = NSHomeDirectory()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"

        print("Polling every \(Int(config.pollInterval)) s for \(Int(duration)) s. Working = transcript written "
              + "< \(Int(config.activityWindow)) s ago, or subtree CPU ≥ \(config.cpuThreshold) s per \(Int(config.activityWindow)) s.")
        let start = Date()
        var next = start
        while next.timeIntervalSince(start) <= duration {
            Thread.sleep(until: next)
            let now = Date()
            let started = DispatchTime.now()
            let processes = processProbe.processes()
            let roots = Matcher.defaults.sessionRoots(in: processes)
            let folders = Set(roots.filter { $0.agent == .claude }.compactMap { $0.cwd.map(Transcripts.claudeProjectFolder) })
            let transcripts = transcriptProbe.snapshot(claudeFolders: folders, now: now)
            let probeMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            let report = tracker.update(now: now, processes: processes, roots: roots, transcripts: transcripts)

            let filling = now.timeIntervalSince(start) < config.activityWindow ? " (window still filling)" : ""
            let degraded = report.degraded.isEmpty ? "" : ", detection degraded: \(report.degraded.map(\.rawValue).sorted())"
            print("\(clock.string(from: now))  \(processes.count) processes, probe \(String(format: "%.0f", probeMs)) ms\(filling)\(degraded)")
            let totals = Dictionary(processes.map { ($0.pid, $0.cpuSeconds ?? 0) }, uniquingKeysWith: { first, _ in first })
            for session in report.sessions.sorted(by: { $0.root.pid < $1.root.pid }) {
                let cwd = (session.root.cwd ?? "?").replacingOccurrences(of: home, with: "~")
                let age = session.transcriptAge.map { String(format: "%.0f s ago", $0) } ?? "none"
                print(String(format: "  %@  pid %-6d %@  cpu %5.2f s in window, root total %7.2f s, transcript %@  %@",
                             session.root.agent.rawValue, session.root.pid, session.working ? "working" : "idle   ",
                             session.cpuInWindow, totals[session.root.pid] ?? 0, age, cwd))
            }
            next += config.pollInterval
        }
    }
}
