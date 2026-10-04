import Foundation
import Testing
@testable import NightCrewCore

// MARK: - Units

@Test("§5.3 mach ticks → seconds", arguments: [
    // Measured on this Mac 2026-10-04: getrusage reported 1.002832 s for the same process.
    (ticks: UInt64(24_067_890), numer: UInt32(125), denom: UInt32(3), seconds: 1.00282875),
    // Intel: timebase 1/1, ticks are nanoseconds.
    (ticks: UInt64(1_500_000_000), numer: UInt32(1), denom: UInt32(1), seconds: 1.5),
])
func machTicks(_ c: (ticks: UInt64, numer: UInt32, denom: UInt32, seconds: Double)) {
    #expect(abs(MachTime.seconds(ticks: c.ticks, numer: c.numer, denom: c.denom) - c.seconds) < 1e-9)
}

@Test("§5.3 Claude project folder for a cwd", arguments: [
    // Observed in ~/.claude/projects on 2026-10-02.
    ("/Users/skonovalov/dev/night-crew", "-Users-skonovalov-dev-night-crew"),
    ("/Users/skonovalov/.my-assistant/cache/runs/run-01M1S3GN78MQ0G3EA6",
     "-Users-skonovalov--my-assistant-cache-runs-run-01M1S3GN78MQ0G3EA6"),
    // Assumed from the same rule (no such folders exist to check against).
    ("/Users/u/my_proj v2", "-Users-u-my-proj-v2"),
    ("/Users/u/проект", "-Users-u-------"),
])
func claudeFolder(_ c: (String, String)) {
    #expect(Transcripts.claudeProjectFolder(for: c.0) == c.1)
}

@Test("§5.3 subtree from the ppid map")
func subtree() {
    let processes = [
        ProcessRecord(pid: 0, ppid: 0, executablePath: "kernel_task"),
        ProcessRecord(pid: 100, ppid: 1, executablePath: "claude"),
        ProcessRecord(pid: 101, ppid: 100, executablePath: "npm"),
        ProcessRecord(pid: 102, ppid: 101, executablePath: "node"),
        ProcessRecord(pid: 103, ppid: 100, executablePath: "zsh"),
        ProcessRecord(pid: 200, ppid: 1, executablePath: "other"),
    ]
    let tree = ProcessTree(processes)
    #expect(Set(tree.subtree(of: 100)) == [100, 101, 102, 103])
    #expect(tree.subtree(of: 0) == [0])
}

// MARK: - Tracker scenarios

let projectCwd = "/Users/u/dev/night-crew"
let folder = "-Users-u-dev-night-crew"

private func claude(_ cpu: Double, pid: Int32 = 100, cwd: String = projectCwd) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: 1, executablePath: "/x/anthropic.claude-code-2.1.286/claude",
                  arguments: ["claude"], cwd: cwd, cpuSeconds: cpu)
}
private func codex(_ pid: Int32) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: 1, executablePath: "/opt/homebrew/bin/codex", arguments: ["codex"], cpuSeconds: 1)
}
private func child(_ pid: Int32, of parent: Int32 = 100, cpu: Double) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: parent, executablePath: "/bin/zsh", arguments: ["zsh"], cpuSeconds: cpu)
}

struct TrackPoll: Sendable {
    var at: TimeInterval
    var processes: [ProcessRecord]
    var transcripts = TranscriptSnapshot()
    var working: [Int32: Bool]
    var cpu: [Int32: Double] = [:]
    var degraded: Set<Agent> = []
}

struct TrackScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let polls: [TrackPoll]
    var testDescription: String { name }
}

let trackerRows: [TrackScenario] = [
    .init(name: "first poll has no CPU baseline", polls: [
        TrackPoll(at: 0, processes: [claude(50)], working: [100: false], cpu: [100: 0]),
    ]),
    .init(name: "idle VS Code panel as measured (0.57 s per 60 s) is not working", polls: [
        TrackPoll(at: 0, processes: [claude(10)], working: [100: false]),
        TrackPoll(at: 30, processes: [claude(10.3)], working: [100: false]),
        TrackPoll(at: 60, processes: [claude(10.57)], working: [100: false], cpu: [100: 0.57]),
    ]),
    .init(name: "light tool calls as measured (2.9 s per 60 s): CPU alone is not enough", polls: [
        TrackPoll(at: 0, processes: [claude(10)], working: [100: false]),
        TrackPoll(at: 60, processes: [claude(12.9)], working: [100: false], cpu: [100: 2.9]),
    ]),
    .init(name: "… the same session with a transcript written 1 s ago is working", polls: [
        TrackPoll(at: 0, processes: [claude(10)], working: [100: false]),
        TrackPoll(at: 60, processes: [claude(12.9)], transcripts: TranscriptSnapshot(claudeProjects: [folder: t0 + 59]),
                  working: [100: true]),
    ]),
    .init(name: "CPU exactly at the threshold is working", polls: [
        TrackPoll(at: 0, processes: [claude(0)], working: [100: false]),
        TrackPoll(at: 5, processes: [claude(3)], working: [100: true], cpu: [100: 3]),
    ]),
    .init(name: "heavy child born after the first poll counts at once", polls: [
        TrackPoll(at: 0, processes: [claude(10)], working: [100: false]),
        TrackPoll(at: 5, processes: [claude(10.1), child(102, cpu: 4)], working: [100: true], cpu: [100: 4.1]),
    ]),
    .init(name: "an exited child keeps counting until its CPU ages out of the window", polls: [
        TrackPoll(at: 0, processes: [claude(10), child(102, cpu: 0)], working: [100: false]),
        TrackPoll(at: 5, processes: [claude(10), child(102, cpu: 5)], working: [100: true], cpu: [100: 5]),
        TrackPoll(at: 10, processes: [claude(10)], working: [100: true], cpu: [100: 5]),
        TrackPoll(at: 64, processes: [claude(10)], working: [100: true], cpu: [100: 5]),
        TrackPoll(at: 66, processes: [claude(10)], working: [100: false], cpu: [100: 0]),
    ]),
    .init(name: "a reused pid with a restarted counter never goes negative", polls: [
        TrackPoll(at: 0, processes: [claude(10), child(102, cpu: 100)], working: [100: false]),
        TrackPoll(at: 5, processes: [claude(10), child(102, cpu: 1)], working: [100: false], cpu: [100: 1]),
    ]),
    .init(name: "a grandchild counts (tool call under a shell)", polls: [
        TrackPoll(at: 0, processes: [claude(10), child(101, cpu: 0)], working: [100: false]),
        TrackPoll(at: 5, processes: [claude(10), child(101, cpu: 0), child(102, of: 101, cpu: 3.5)],
                  working: [100: true], cpu: [100: 3.5]),
    ]),
    .init(name: "transcript age boundary: 59 s working, 60 s not", polls: [
        TrackPoll(at: 0, processes: [claude(10)], transcripts: TranscriptSnapshot(claudeProjects: [folder: t0 - 59]),
                  working: [100: true]),
        TrackPoll(at: 1, processes: [claude(10)], transcripts: TranscriptSnapshot(claudeProjects: [folder: t0 - 59]),
                  working: [100: false]),
    ]),
    .init(name: "another project's transcript does not count", polls: [
        TrackPoll(at: 0, processes: [claude(10)], transcripts: TranscriptSnapshot(claudeProjects: ["-Users-u-dev-other": t0]),
                  working: [100: false]),
    ]),
    .init(name: "a codex rollout write marks every codex session, not claude", polls: [
        TrackPoll(at: 0, processes: [claude(10), codex(200), codex(300)], transcripts: TranscriptSnapshot(codexNewest: t0 - 2),
                  working: [100: false, 200: true, 300: true]),
    ]),
    .init(name: "claude transcript root missing → degraded, CPU still counts", polls: [
        TrackPoll(at: 0, processes: [claude(0)], transcripts: TranscriptSnapshot(claudeProjects: nil),
                  working: [100: false], degraded: [.claude]),
        TrackPoll(at: 5, processes: [claude(4)], transcripts: TranscriptSnapshot(claudeProjects: nil),
                  working: [100: true], degraded: [.claude]),
    ]),
    .init(name: "missing roots without live sessions are not degraded", polls: [
        TrackPoll(at: 0, processes: [], transcripts: TranscriptSnapshot(claudeProjects: nil, codexRootExists: false),
                  working: [:], degraded: []),
    ]),
]

@Test("§5.3 activity", arguments: trackerRows)
func trackerRow(_ s: TrackScenario) {
    var tracker = ActivityTracker()
    for (i, poll) in s.polls.enumerated() {
        let roots = Matcher.defaults.sessionRoots(in: poll.processes)
        let report = tracker.update(now: t0.addingTimeInterval(poll.at), processes: poll.processes, roots: roots,
                                    transcripts: poll.transcripts)
        let working = Dictionary(uniqueKeysWithValues: report.sessions.map { ($0.root.pid, $0.working) })
        #expect(working == poll.working, "poll \(i) at +\(poll.at)s")
        for (pid, expected) in poll.cpu {
            let actual = report.sessions.first { $0.root.pid == pid }?.cpuInWindow ?? -1
            #expect(abs(actual - expected) < 1e-9, "poll \(i) at +\(poll.at)s: cpu \(actual) ≠ \(expected)")
        }
        #expect(report.degraded == poll.degraded, "poll \(i) at +\(poll.at)s")
    }
}
