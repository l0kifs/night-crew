import Foundation
import Testing
@testable import NightCrewCore

final class FakeProcesses: ProcessProbing {
    var list: [ProcessRecord] = []
    func processes() -> [ProcessRecord] { list }
}

final class FakeTranscripts: TranscriptProbing {
    var claude: [String: Date] = [:]
    var requested: Set<String> = []
    func snapshot(claudeFolders: Set<String>, now: Date) -> TranscriptSnapshot {
        requested = claudeFolders
        return TranscriptSnapshot(claudeProjects: claude.filter { claudeFolders.contains($0.key) })
    }
}

final class FakePower: PowerSensing {
    var reading = PowerReading(sleepDisabled: false, lidClosed: false, externalDisplayOnline: false,
                               builtinDisplayAsleep: false, onBattery: false, batteryPercent: 80, thermal: .nominal)
    func read() -> PowerReading { reading }
}

final class FakeOwnership: OwnershipReading {
    var owned = false
    func isOwned() -> Bool { owned }
}

final class FakeClock: Clock {
    var now = t0
}

struct Fakes {
    let processes = FakeProcesses()
    let transcripts = FakeTranscripts()
    let power = FakePower()
    let ownership = FakeOwnership()
    let clock = FakeClock()

    func poller(lastWorkingAt: Date? = nil) -> Poller {
        Poller(lastWorkingAt: lastWorkingAt, processes: processes, transcripts: transcripts, power: power,
               ownership: ownership, clock: clock)
    }
}

private func claudeRoot(pid: Int32 = 100, cwd: String = projectCwd) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: 1, executablePath: "/x/anthropic.claude-code-2/claude", arguments: ["claude"],
                  cwd: cwd, cpuSeconds: 1)
}

@Test("§6.1 power readings, ownership and sessions reach the engine")
func pollerWiring() {
    let f = Fakes()
    var poller = f.poller()
    f.processes.list = [claudeRoot()]
    f.transcripts.claude = [folder: t0]

    var tick = poller.tick(mode: .auto)
    #expect(tick.output.actions == [.enableSleepDisabled])
    #expect(tick.activity.sessions.map(\.working) == [true])

    // Lid closed alone, owned, SleepDisabled 1, built-in lit → displaysleepnow.
    f.clock.now = t0 + 5
    f.ownership.owned = true
    f.power.reading.sleepDisabled = true
    f.power.reading.lidClosed = true
    tick = poller.tick(mode: .auto)
    #expect(tick.output.actions == [.displaySleepNow])

    // External display online → no lid action.
    f.clock.now = t0 + 70
    f.transcripts.claude = [folder: t0 + 70]
    f.power.reading.externalDisplayOnline = true
    tick = poller.tick(mode: .auto)
    #expect(tick.output.actions == [])

    // Battery and thermal readings reach the guards.
    f.clock.now = t0 + 75
    f.power.reading.onBattery = true
    f.power.reading.batteryPercent = 10
    tick = poller.tick(mode: .auto)
    #expect(tick.output.status == .pausedBattery(floor: 15))
    #expect(tick.output.actions == [.notify(.batteryPause(floor: 15)), .disableSleepDisabled])

    f.clock.now = t0 + 80
    f.power.reading.thermal = .serious
    tick = poller.tick(mode: .auto)
    #expect(tick.output.status == .pausedThermal)
}

@Test("§5.3 only live Claude sessions' folders are listed")
func pollerRequestsLiveFolders() {
    let f = Fakes()
    var poller = f.poller()
    f.processes.list = [
        claudeRoot(pid: 100, cwd: "/Users/u/a"),
        claudeRoot(pid: 101, cwd: "/Users/u/b.c"),
        ProcessRecord(pid: 200, ppid: 1, executablePath: "/opt/homebrew/bin/codex", arguments: ["codex"], cwd: "/Users/u/z"),
    ]
    _ = poller.tick(mode: .auto)
    #expect(f.transcripts.requested == ["-Users-u-a", "-Users-u-b-c"])
}

@Test("§5.3 a transcript write polls at once only while not awake, at most once per second")
func transcriptTrigger() {
    let f = Fakes()
    var poller = f.poller()
    #expect(poller.shouldPollOnTranscriptChange())       // nothing polled yet

    f.processes.list = [claudeRoot()]
    _ = poller.tick(mode: .auto)                          // idle at t0
    #expect(!poller.shouldPollOnTranscriptChange())      // < 1 s later
    f.clock.now = t0 + 1
    #expect(poller.shouldPollOnTranscriptChange())

    f.transcripts.claude = [folder: t0 + 1]
    _ = poller.tick(mode: .auto)                          // awake now
    f.clock.now = t0 + 10
    #expect(!poller.shouldPollOnTranscriptChange())
}

@Test("§6.2 lastWorkingAt is persisted every 30 s while working and at once when work stops")
func persistLastWorkingAt() {
    let f = Fakes()
    var poller = f.poller()
    f.processes.list = [claudeRoot()]
    var persisted: [TimeInterval: TimeInterval] = [:]   // tick time → persisted value, both relative to t0
    for at in stride(from: 0.0, through: 55, by: 5) {
        f.clock.now = t0 + at
        f.transcripts.claude = at <= 40 ? [folder: t0 + at] : [folder: t0 + 40 - 61]
        _ = poller.tick(mode: .auto)
        if let value = poller.lastWorkingAtToPersist() { persisted[at] = value.timeIntervalSince(t0) }
    }
    #expect(persisted == [0: 0, 30: 30, 45: 40])
}

@Test("§8 a restarted poller with a restored lastWorkingAt stays awake and emits nothing")
func restartedPoller() {
    let f = Fakes()
    var poller = f.poller(lastWorkingAt: t0 - 30)
    f.processes.list = [claudeRoot()]
    f.ownership.owned = true
    f.power.reading.sleepDisabled = true
    f.power.reading.lidClosed = true
    f.power.reading.builtinDisplayAsleep = true
    let tick = poller.tick(mode: .auto)
    #expect(tick.output.awake)
    #expect(tick.output.actions == [])
    #expect(tick.output.status == .grace(remaining: 570))
}
