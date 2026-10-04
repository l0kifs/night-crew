import Foundation

public enum MachTime {
    /// `pti_total_user + pti_total_system` are mach ticks, not nanoseconds, on Apple Silicon (SPEC §5.3).
    /// Measured 2026-10-04: 24 067 890 ticks at timebase 125/3 = 1.00283 s; getrusage said 1.002832 s.
    public static func seconds(ticks: UInt64, numer: UInt32, denom: UInt32) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1e9
    }
}

public enum Transcripts {
    /// Folder name under `~/.claude/projects` for a cwd: every character other than A–Z, a–z, 0–9 becomes "-".
    /// Applied per UTF-16 code unit, as a JS `replace(/[^a-zA-Z0-9]/g, "-")` would. Observed for "/" and "." only.
    public static func claudeProjectFolder(for cwd: String) -> String {
        String(decoding: cwd.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return unit
            default: return 0x2D
            }
        }, as: UTF16.self)
    }
}

/// What `TranscriptProbe` found on disk this poll (SPEC §5.3 signal 1).
public struct TranscriptSnapshot: Equatable, Sendable {
    /// Newest `*.jsonl` mtime per folder in `~/.claude/projects`. Nil when that folder does not exist.
    public var claudeProjects: [String: Date]?
    public var codexRootExists: Bool
    /// Newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` mtime.
    public var codexNewest: Date?

    public init(claudeProjects: [String: Date]? = [:], codexRootExists: Bool = true, codexNewest: Date? = nil) {
        self.claudeProjects = claudeProjects
        self.codexRootExists = codexRootExists
        self.codexNewest = codexNewest
    }
}

public struct SessionActivity: Equatable, Sendable {
    public var root: SessionRoot
    public var working: Bool
    /// Subtree CPU seconds within `activityWindow`, for the calibration log.
    public var cpuInWindow: Double
    /// Seconds since the session's transcript was written, nil if none was found.
    public var transcriptAge: TimeInterval?
}

public struct ActivityReport: Equatable, Sendable {
    public var sessions: [SessionActivity]
    /// Agents with live sessions whose transcript root is missing: CPU only, menu shows "Detection degraded".
    public var degraded: Set<Agent>

    public var engineSessions: [Session] { sessions.map { Session(root: $0.root, working: $0.working) } }
}

/// Root plus all descendants, from the ppid map.
public struct ProcessTree: Sendable {
    private let children: [Int32: [Int32]]

    public init(_ processes: [ProcessRecord]) {
        children = Dictionary(grouping: processes.filter { $0.pid != $0.ppid }, by: \.ppid).mapValues { $0.map(\.pid) }
    }

    public func subtree(of root: Int32) -> [Int32] {
        var seen: Set<Int32> = [root]
        var order = [root]
        var index = 0
        while index < order.count {
            for child in children[order[index]] ?? [] where seen.insert(child).inserted { order.append(child) }
            index += 1
        }
        return order
    }
}

/// SPEC §5.3: a session is working when its transcript was written, or its subtree used at least
/// `cpuThreshold` CPU seconds, within the last `activityWindow`.
public struct ActivityTracker: Sendable {
    public var config: Config

    private var previousCPU: [Int32: Double] = [:]
    private var polled = false
    /// Per session root: CPU used by its subtree between consecutive polls, stamped with the later poll.
    private var increments: [Int32: [(at: Date, seconds: Double)]] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func update(now: Date, processes: [ProcessRecord], roots: [SessionRoot],
                                transcripts: TranscriptSnapshot) -> ActivityReport {
        let tree = ProcessTree(processes)
        let cpuByPid = Dictionary(processes.compactMap { p in p.cpuSeconds.map { (p.pid, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        let windowStart = now.addingTimeInterval(-config.activityWindow)
        var activities: [SessionActivity] = []
        var kept: [Int32: [(at: Date, seconds: Double)]] = [:]

        for root in roots {
            // CPU since the previous poll. A child that exits keeps its earlier increments until they age out.
            // The first poll has no baseline; a pid first seen later was born since the previous poll.
            var used = 0.0
            if polled {
                for pid in tree.subtree(of: root.pid) {
                    guard let cpu = cpuByPid[pid] else { continue }
                    if let before = previousCPU[pid], cpu >= before {
                        used += cpu - before
                    } else {
                        used += cpu   // new process, or a reused pid whose counter restarted
                    }
                }
            }
            var series = (increments[root.pid] ?? []).filter { $0.at > windowStart }
            if polled { series.append((now, used)) }
            kept[root.pid] = series
            let cpuInWindow = series.reduce(0) { $0 + $1.seconds }

            let written = transcriptWrite(for: root, in: transcripts)
            let age = written.map { now.timeIntervalSince($0) }
            let transcriptRecent = age.map { $0 < config.activityWindow } ?? false
            activities.append(SessionActivity(root: root, working: transcriptRecent || cpuInWindow >= config.cpuThreshold,
                                              cpuInWindow: cpuInWindow, transcriptAge: age))
        }

        increments = kept
        previousCPU = cpuByPid
        polled = true

        var degraded: Set<Agent> = []
        let agents = Set(roots.map(\.agent))
        if agents.contains(.claude) && transcripts.claudeProjects == nil { degraded.insert(.claude) }
        if agents.contains(.codex) && !transcripts.codexRootExists { degraded.insert(.codex) }
        return ActivityReport(sessions: activities, degraded: degraded)
    }

    private func transcriptWrite(for root: SessionRoot, in transcripts: TranscriptSnapshot) -> Date? {
        switch root.agent {
        case .claude:
            guard let cwd = root.cwd else { return nil }
            return transcripts.claudeProjects?[Transcripts.claudeProjectFolder(for: cwd)]
        case .codex:
            // Codex rollout files are not attributable to one session: any write marks every codex session.
            return transcripts.codexNewest
        }
    }
}
