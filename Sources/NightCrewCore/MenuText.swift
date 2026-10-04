import Foundation

/// The words and symbols of the SPEC §10 menu, kept out of AppKit so they are testable.
public enum MenuText {
    public static func statusLine(_ status: Status, sessions: [SessionActivity], now: Date) -> String {
        switch status {
        case .awake(let working):
            let perAgent = Agent.allCases.compactMap { agent -> String? in
                let count = sessions.filter { $0.working && $0.root.agent == agent }.count
                return count > 0 ? "\(agent.rawValue) ×\(count)" : nil
            }
            return "Awake — \(working) working (\(perAgent.joined(separator: ", ")))"
        case .grace(let remaining): return "Grace: \(duration(remaining)) left"
        case .idle: return "Idle"
        case .alwaysAwake(let until): return "Always awake — reverts in \(duration(until.timeIntervalSince(now)))"
        case .off: return "Off — normal sleep"
        case .setupRequired: return "Setup required — sudo rule missing"
        case .error(let message): return "Error: \(message)"
        case .unmanaged: return "Sleep disabled manually (unmanaged)"
        case .pausedBattery(let floor): return "Paused: battery below \(floor)%"
        case .pausedThermal: return "Paused: Mac too hot"
        }
    }

    public static func sessionRow(_ session: SessionActivity, home: String) -> String {
        var cwd = session.root.cwd ?? "?"
        if !home.isEmpty, cwd.hasPrefix(home) { cwd = "~" + cwd.dropFirst(home.count) }
        return "\(session.root.agent.rawValue)  \(cwd)  —  \(session.working ? "working" : "idle")"
    }

    public static func degradedLine(_ agents: Set<Agent>) -> String? {
        agents.isEmpty ? nil : "Detection degraded: \(agents.map(\.rawValue).sorted().joined(separator: ", ")) (CPU only)"
    }

    /// SF Symbol names from §10.
    public static func iconSymbol(_ output: Output) -> String {
        if output.iconError { return "exclamationmark.triangle" }
        return output.awake ? "moon.stars.fill" : "moon.zzz"
    }

    /// Rounded up to the minute: "1 min", "59 min", "1 h", "7 h 52 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
