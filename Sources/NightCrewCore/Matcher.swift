public enum Agent: String, CaseIterable, Sendable {
    case claude, codex
}

/// One process as `ProcessProbe` sees it (SPEC §5.1).
public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// `proc_pidpath`.
    public var executablePath: String
    /// argv via `KERN_PROCARGS2`, argv[0] first. Empty when unreadable.
    public var arguments: [String]
    public var cwd: String?
    /// Cumulative user + system CPU in seconds (`PROC_PIDTASKINFO`, converted with `MachTime`). Nil when unreadable.
    public var cpuSeconds: Double?

    public init(pid: Int32, ppid: Int32, executablePath: String, arguments: [String] = [], cwd: String? = nil,
                cpuSeconds: Double? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.executablePath = executablePath
        self.arguments = arguments
        self.cwd = cwd
        self.cpuSeconds = cpuSeconds
    }
}

public struct SessionRoot: Equatable, Sendable {
    public var pid: Int32
    public var agent: Agent
    public var cwd: String?

    public init(pid: Int32, agent: Agent, cwd: String? = nil) {
        self.pid = pid
        self.agent = agent
        self.cwd = cwd
    }
}

/// One row of the SPEC §5.2 table: a process matches when any "match" condition holds and no exclusion does.
public struct MatchRule: Equatable, Sendable {
    public var agent: Agent
    public var argv0Basenames: [String]
    public var argumentContains: [String]
    public var pathContains: [String]
    public var excludePathContains: [String]

    public init(agent: Agent, argv0Basenames: [String], argumentContains: [String],
                pathContains: [String], excludePathContains: [String]) {
        self.agent = agent
        self.argv0Basenames = argv0Basenames
        self.argumentContains = argumentContains
        self.pathContains = pathContains
        self.excludePathContains = excludePathContains
    }

    public func matches(_ process: ProcessRecord) -> Bool {
        if excludePathContains.contains(where: process.executablePath.contains) { return false }
        if let argv0 = process.arguments.first, argv0Basenames.contains(Self.basename(argv0)) { return true }
        if process.arguments.contains(where: { arg in argumentContains.contains(where: arg.contains) }) { return true }
        return pathContains.contains(where: process.executablePath.contains)
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

public struct Matcher: Equatable, Sendable {
    /// Evaluated in order; the first matching rule wins.
    public var rules: [MatchRule]

    public init(rules: [MatchRule]) {
        self.rules = rules
    }

    /// SPEC §5.2 defaults.
    public static let defaults = Matcher(rules: [
        MatchRule(agent: .claude,
                  argv0Basenames: ["claude"],
                  argumentContains: ["@anthropic-ai/claude-code"],
                  pathContains: ["/.local/share/claude/versions/", "anthropic.claude-code-"],
                  excludePathContains: [".app/Contents/"]),
        MatchRule(agent: .codex,
                  argv0Basenames: ["codex"],
                  argumentContains: ["@openai/codex"],
                  pathContains: ["openai.chatgpt-"],
                  excludePathContains: [".app/Contents/"]),
    ])

    public func agent(of process: ProcessRecord) -> Agent? {
        rules.first { $0.matches(process) }?.agent
    }

    /// Matching processes whose parent does not match the same agent, so one session is counted once.
    public func sessionRoots(in processes: [ProcessRecord]) -> [SessionRoot] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return processes.compactMap { process in
            guard let agent = agent(of: process) else { return nil }
            if let parent = byPid[process.ppid], self.agent(of: parent) == agent { return nil }
            return SessionRoot(pid: process.pid, agent: agent, cwd: process.cwd)
        }
    }
}
