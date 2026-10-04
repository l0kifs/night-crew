import Foundation
import Testing
@testable import NightCrewCore

private let sessions = [
    SessionActivity(root: SessionRoot(pid: 1, agent: .claude, cwd: "/Users/u/proj/foo"), working: true, cpuInWindow: 0, transcriptAge: 1),
    SessionActivity(root: SessionRoot(pid: 2, agent: .codex, cwd: "/Users/u/proj/bar"), working: true, cpuInWindow: 0, transcriptAge: nil),
    SessionActivity(root: SessionRoot(pid: 3, agent: .claude, cwd: "/tmp/x"), working: false, cpuInWindow: 0, transcriptAge: nil),
]

@Test("§10 status line", arguments: [
    (Status.awake(working: 2), "Awake — 2 working (claude ×1, codex ×1)"),
    (.grace(remaining: 420), "Grace: 7 min left"),
    (.grace(remaining: 1), "Grace: 1 min left"),
    (.idle, "Idle"),
    (.alwaysAwake(until: t0 + 7 * 3600 + 52 * 60), "Always awake — reverts in 7 h 52 min"),
    (.off, "Off — normal sleep"),
    (.setupRequired, "Setup required — sudo rule missing"),
    (.error("disablesleep had no effect"), "Error: disablesleep had no effect"),
    (.unmanaged, "Sleep disabled manually (unmanaged)"),
    (.pausedBattery(floor: 15), "Paused: battery below 15%"),
    (.pausedThermal, "Paused: Mac too hot"),
])
func statusLine(_ c: (Status, String)) {
    #expect(MenuText.statusLine(c.0, sessions: sessions, now: t0) == c.1)
}

@Test("§10 durations round up to the minute", arguments: [
    (0.5, "1 min"), (60.0, "1 min"), (61.0, "2 min"), (3540.0, "59 min"), (3600.0, "1 h"), (3601.0, "1 h 1 min"),
    (28_800.0, "8 h"),
])
func duration(_ c: (Double, String)) {
    #expect(MenuText.duration(c.0) == c.1)
}

@Test("§10 session rows, degraded line and icon")
func rowsAndIcon() {
    #expect(MenuText.sessionRow(sessions[0], home: "/Users/u") == "claude  ~/proj/foo  —  working")
    #expect(MenuText.sessionRow(sessions[2], home: "/Users/u") == "claude  /tmp/x  —  idle")
    #expect(MenuText.degradedLine([]) == nil)
    #expect(MenuText.degradedLine([.codex, .claude]) == "Detection degraded: claude, codex (CPU only)")
    let base = Output(actions: [], awake: false, status: .idle, iconError: false)
    #expect(MenuText.iconSymbol(base) == "moon.zzz")
    #expect(MenuText.iconSymbol(Output(actions: [], awake: true, status: .awake(working: 1), iconError: false)) == "moon.stars.fill")
    #expect(MenuText.iconSymbol(Output(actions: [], awake: true, status: .setupRequired, iconError: true)) == "exclamationmark.triangle")
}
