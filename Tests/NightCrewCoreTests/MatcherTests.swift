import Testing
@testable import NightCrewCore

struct MatchCase: Sendable, CustomTestStringConvertible {
    let name: String
    let process: ProcessRecord
    let expected: Agent?
    var testDescription: String { name }
}

private func proc(_ path: String, _ args: [String] = []) -> ProcessRecord {
    ProcessRecord(pid: 100, ppid: 1, executablePath: path, arguments: args)
}

/// One case per condition of every SPEC §5.2 row, plus its exclusion.
let matchCases: [MatchCase] = [
    // claude
    .init(name: "claude: argv[0] basename", process: proc("/opt/homebrew/bin/node", ["claude", "-p", "hi"]), expected: .claude),
    .init(name: "claude: argv[0] full path", process: proc("/usr/local/bin/claude", ["/usr/local/bin/claude"]), expected: .claude),
    .init(name: "claude: npm install runs as node cli.js",
          process: proc("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
          expected: .claude),
    .init(name: "claude: native install named after its version",
          process: proc("/Users/u/.local/share/claude/versions/2.1.286", ["2.1.286"]), expected: .claude),
    .init(name: "claude: VS Code extension (seen 2026-10-02)",
          process: proc("/Users/u/.vscode/extensions/anthropic.claude-code-2.1.286-darwin-arm64/resources/native-binary/claude",
                        ["/Users/u/.vscode/extensions/anthropic.claude-code-2.1.286-darwin-arm64/resources/native-binary/claude",
                         "--output-format", "stream-json"]),
          expected: .claude),
    .init(name: "claude: excluded inside an .app bundle",
          process: proc("/Applications/Claude.app/Contents/Helpers/claude", ["claude"]), expected: nil),
    .init(name: "claude: Claude.app chrome-native-host is not a session",
          process: proc("/Applications/Claude.app/Contents/Helpers/chrome-native-host", ["chrome-native-host"]), expected: nil),
    // codex
    .init(name: "codex: argv[0] basename", process: proc("/opt/homebrew/bin/codex", ["codex"]), expected: .codex),
    .init(name: "codex: npm install", process: proc("/opt/homebrew/bin/node", ["node", "/x/node_modules/@openai/codex/bin/codex.js"]),
          expected: .codex),
    .init(name: "codex: VS Code extension app-server",
          process: proc("/Users/u/.vscode/extensions/openai.chatgpt-1.0.0/bin/codex-app", ["codex-app", "app-server"]),
          expected: .codex),
    .init(name: "codex: excluded inside an .app bundle",
          process: proc("/Applications/Codex.app/Contents/Resources/codex", ["codex"]), expected: nil),
    // neither
    .init(name: "unrelated process", process: proc("/bin/zsh", ["zsh"]), expected: nil),
    .init(name: "argv unreadable (EPERM): path only", process: proc("/Users/u/.local/share/claude/versions/2.0.1"), expected: .claude),
    .init(name: "both rules match: first rule (claude) wins",
          process: proc("/usr/local/bin/claude", ["claude", "--mcp", "@openai/codex"]), expected: .claude),
]

@Test("§5.2 matcher", arguments: matchCases)
func matcherRow(_ c: MatchCase) {
    #expect(Matcher.defaults.agent(of: c.process) == c.expected)
}

@Test("§5.2 a child of the same agent is not a second session root")
func sameAgentChildIsNotRoot() {
    let processes = [
        ProcessRecord(pid: 10, ppid: 1, executablePath: "/opt/homebrew/bin/node", arguments: ["node", "/x/@openai/codex/bin/codex.js"]),
        ProcessRecord(pid: 11, ppid: 10, executablePath: "/x/@openai/codex/vendor/codex", arguments: ["codex"]),
    ]
    #expect(Matcher.defaults.sessionRoots(in: processes).map(\.pid) == [10])
}

@Test("§5.2 roots: other-agent parent, shell parent, missing parent")
func rootsAcrossParents() {
    let processes = [
        ProcessRecord(pid: 20, ppid: 2894, executablePath: "/x/anthropic.claude-code-2/claude", arguments: ["claude"], cwd: "/p/a"),
        ProcessRecord(pid: 21, ppid: 20, executablePath: "/bin/zsh", arguments: ["zsh"]),
        ProcessRecord(pid: 22, ppid: 21, executablePath: "/usr/local/bin/claude", arguments: ["claude", "-p"]),  // nested via a shell
        ProcessRecord(pid: 23, ppid: 20, executablePath: "/opt/homebrew/bin/codex", arguments: ["codex"]),       // other agent's child
    ]
    let roots = Matcher.defaults.sessionRoots(in: processes)
    #expect(roots == [
        SessionRoot(pid: 20, agent: .claude, cwd: "/p/a"),
        SessionRoot(pid: 22, agent: .claude),
        SessionRoot(pid: 23, agent: .codex),
    ])
}
