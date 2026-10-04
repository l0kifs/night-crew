import Foundation
import Testing
@testable import NightCrewCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let workingClaude = Session(root: SessionRoot(pid: 1, agent: .claude), working: true)
let idleClaude = Session(root: SessionRoot(pid: 1, agent: .claude), working: false)

/// One poll: seconds after t0, how the inputs differ from the default, what must come out.
struct Poll: Sendable {
    var at: TimeInterval
    var set: @Sendable (inout Inputs) -> Void = { _ in }
    var actions: [Action]
    var status: Status? = nil
    var record: Outcome? = nil
    var retryAfter = false
}

struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    var config: @Sendable (inout Config) -> Void = { _ in }
    var lastWorkingAt: Date? = nil
    let polls: [Poll]
    var testDescription: String { name }
}

private func run(_ s: Scenario) {
    var config = Config()
    s.config(&config)
    var engine = Engine(config: config, lastWorkingAt: s.lastWorkingAt)
    for (i, poll) in s.polls.enumerated() {
        var input = Inputs(now: t0.addingTimeInterval(poll.at))
        poll.set(&input)
        let out = engine.step(input)
        #expect(out.actions == poll.actions, "poll \(i) at +\(poll.at)s")
        if let status = poll.status { #expect(out.status == status, "poll \(i) at +\(poll.at)s") }
        if let outcome = poll.record { engine.record(outcome, at: input.now) }
        if poll.retryAfter { engine.retry() }
    }
}

// MARK: - §6.2 desired state: one scenario per rule and per boundary

let desiredStateRows: [Scenario] = [
    .init(name: "rule 1: SleepDisabled 1, not owned → Unmanaged, no action even with a working agent",
          polls: [Poll(at: 0, set: { $0.sleepDisabled = true; $0.sessions = [workingClaude]; $0.lidClosed = true },
                       actions: [], status: .unmanaged)]),
    .init(name: "rule 2: thermal serious overrides Always awake, notifies once",
          polls: [Poll(at: 0, set: { $0.thermal = .serious; $0.mode = .alwaysOn(until: t0 + 3600) },
                       actions: [.notify(.thermalPause)], status: .pausedThermal),
                  Poll(at: 5, set: { $0.thermal = .critical; $0.mode = .alwaysOn(until: t0 + 3600) },
                       actions: [], status: .pausedThermal)]),
    .init(name: "rule 2: pause holds until fair-or-better for 10 min",
          polls: [Poll(at: 0, set: { $0.thermal = .serious; $0.sessions = [workingClaude] }, actions: [.notify(.thermalPause)]),
                  Poll(at: 5, set: { $0.thermal = .fair; $0.sessions = [workingClaude] }, actions: [], status: .pausedThermal),
                  Poll(at: 604, set: { $0.thermal = .nominal; $0.sessions = [workingClaude] }, actions: [], status: .pausedThermal),
                  Poll(at: 605, set: { $0.thermal = .nominal; $0.sessions = [workingClaude] },
                       actions: [.enableSleepDisabled], status: .awake(working: 1))]),
    .init(name: "rule 3: on battery below the floor overrides Always awake",
          polls: [Poll(at: 0, set: { $0.onBattery = true; $0.batteryPercent = 14; $0.mode = .alwaysOn(until: t0 + 3600) },
                       actions: [.notify(.batteryPause(floor: 15))], status: .pausedBattery(floor: 15))]),
    .init(name: "rule 3 boundary: exactly at the floor is not paused",
          polls: [Poll(at: 0, set: { $0.onBattery = true; $0.batteryPercent = 15; $0.sessions = [workingClaude] },
                       actions: [.enableSleepDisabled], status: .awake(working: 1))]),
    .init(name: "rule 3: below the floor on AC is not paused",
          polls: [Poll(at: 0, set: { $0.batteryPercent = 5; $0.sessions = [workingClaude] },
                       actions: [.enableSleepDisabled], status: .awake(working: 1))]),
    .init(name: "rule 3: floor Off never pauses",
          config: { $0.batteryFloor = nil },
          polls: [Poll(at: 0, set: { $0.onBattery = true; $0.batteryPercent = 3; $0.sessions = [workingClaude] },
                       actions: [.enableSleepDisabled], status: .awake(working: 1))]),
    .init(name: "rule 3: no notification when nothing would be awake",
          polls: [Poll(at: 0, set: { $0.onBattery = true; $0.batteryPercent = 10 }, actions: [], status: .pausedBattery(floor: 15))]),
    .init(name: "rule 3: one notification per discharge, reset on AC",
          polls: [Poll(at: 0, set: { $0.onBattery = true; $0.batteryPercent = 10; $0.sessions = [workingClaude] },
                       actions: [.notify(.batteryPause(floor: 15))]),
                  Poll(at: 5, set: { $0.onBattery = true; $0.batteryPercent = 9; $0.sessions = [workingClaude] }, actions: []),
                  Poll(at: 10, set: { $0.batteryPercent = 9; $0.sessions = [workingClaude] }, actions: [.enableSleepDisabled]),
                  Poll(at: 15, set: { $0.onBattery = true; $0.batteryPercent = 9; $0.sessions = [workingClaude]; $0.sleepDisabled = true; $0.owned = true },
                       actions: [.notify(.batteryPause(floor: 15)), .disableSleepDisabled])]),
    .init(name: "rule 4: Off with a working agent",
          polls: [Poll(at: 0, set: { $0.mode = .off; $0.sessions = [workingClaude] }, actions: [], status: .off)]),
    .init(name: "rule 5: Always awake with no sessions",
          polls: [Poll(at: 0, set: { $0.mode = .alwaysOn(until: t0 + 3600) },
                       actions: [.enableSleepDisabled], status: .alwaysAwake(until: t0 + 3600))]),
    .init(name: "rule 5: Always awake expired → reverts to Auto",
          polls: [Poll(at: 0, set: { $0.mode = .alwaysOn(until: t0) }, actions: [.revertModeToAuto], status: .idle)]),
    .init(name: "rule 6: working",
          polls: [Poll(at: 0, set: { $0.sessions = [workingClaude, idleClaude] },
                       actions: [.enableSleepDisabled], status: .awake(working: 1))]),
    .init(name: "rule 6: grace, 9 min after the last work",
          lastWorkingAt: t0 - 540,
          polls: [Poll(at: 0, set: { $0.sessions = [idleClaude]; $0.sleepDisabled = true; $0.owned = true },
                       actions: [], status: .grace(remaining: 60))]),
    .init(name: "rule 6 boundary: exactly at grace is idle",
          lastWorkingAt: t0 - 600,
          polls: [Poll(at: 0, set: { $0.sessions = [idleClaude] }, actions: [], status: .idle)]),
    .init(name: "rule 6: never worked → idle",
          polls: [Poll(at: 0, set: { $0.sessions = [idleClaude] }, actions: [], status: .idle)]),
]

@Test("§6.2 desired state", arguments: desiredStateRows)
func desiredState(_ s: Scenario) { run(s) }

// MARK: - §6.3 actions: one scenario per table row

private let ownedAwake: @Sendable (inout Inputs) -> Void = { $0.sessions = [workingClaude]; $0.sleepDisabled = true; $0.owned = true }

let actionRows: [Scenario] = [
    .init(name: "row 1: awake, observed ≠ 1 → enable",
          polls: [Poll(at: 0, set: { $0.sessions = [workingClaude] }, actions: [.enableSleepDisabled])]),
    .init(name: "row 1: external disablesleep 0 while working → enable again within 1 poll (AC9)",
          polls: [Poll(at: 0, set: ownedAwake, actions: []),
                  Poll(at: 5, set: { $0.sessions = [workingClaude]; $0.owned = true }, actions: [.enableSleepDisabled])]),
    .init(name: "row 1: sudo failure → Setup required, ON path stops until Retry",
          polls: [Poll(at: 0, set: { $0.sessions = [workingClaude] }, actions: [.enableSleepDisabled], record: .enableSudoFailed),
                  Poll(at: 5, set: { $0.sessions = [workingClaude] }, actions: [], status: .setupRequired, retryAfter: true),
                  Poll(at: 10, set: { $0.sessions = [workingClaude] }, actions: [.enableSleepDisabled])]),
    .init(name: "row 1: read-back ≠ 1 → error state, ON path stops",
          polls: [Poll(at: 0, set: { $0.sessions = [workingClaude] }, actions: [.enableSleepDisabled], record: .enableHadNoEffect),
                  Poll(at: 5, set: { $0.sessions = [workingClaude] }, actions: [], status: .error("disablesleep had no effect"))]),
    .init(name: "row 1: ownership file not writable → error state, ON path stops",
          polls: [Poll(at: 0, set: { $0.sessions = [workingClaude] }, actions: [.enableSleepDisabled], record: .enableOwnershipFailed),
                  Poll(at: 5, set: { $0.sessions = [workingClaude] }, actions: [], status: .error("cannot write ~/.nightcrew/owned"))]),
    .init(name: "row 2: not awake, owned → disable; failure retried every 60 s, never stops",
          polls: [Poll(at: 0, set: { $0.sleepDisabled = true; $0.owned = true }, actions: [.disableSleepDisabled], record: .disableFailed),
                  Poll(at: 59, set: { $0.sleepDisabled = true; $0.owned = true }, actions: []),
                  Poll(at: 60, set: { $0.sleepDisabled = true; $0.owned = true }, actions: [.disableSleepDisabled], record: .disableFailed),
                  Poll(at: 120, set: { $0.sleepDisabled = true; $0.owned = true }, actions: [.disableSleepDisabled])]),
    .init(name: "row 2: owned but already 0 → disable path clears ownership",
          polls: [Poll(at: 0, set: { $0.owned = true }, actions: [.disableSleepDisabled])]),
    .init(name: "row 3: agents finished, lid closed, sleepWhenDone → sleepnow only once SleepDisabled reads not 1",
          config: { $0.grace = 0 },
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: []),
                  Poll(at: 5, set: { $0.sessions = [idleClaude]; $0.sleepDisabled = true; $0.owned = true; $0.lidClosed = true },
                       actions: [.disableSleepDisabled]),
                  Poll(at: 10, set: { $0.sessions = [idleClaude]; $0.lidClosed = true }, actions: [.sleepNow])]),
    .init(name: "row 3: sleepWhenDone off → no sleepnow",
          config: { $0.grace = 0; $0.sleepWhenDone = false },
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: []),
                  Poll(at: 5, set: { $0.sleepDisabled = true; $0.owned = true; $0.lidClosed = true }, actions: [.disableSleepDisabled]),
                  Poll(at: 10, set: { $0.lidClosed = true }, actions: [])]),
    .init(name: "row 3: lid opened before SleepDisabled reads 0 → no sleepnow",
          config: { $0.grace = 0 },
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: []),
                  Poll(at: 5, set: { $0.sleepDisabled = true; $0.owned = true; $0.lidClosed = true }, actions: [.disableSleepDisabled]),
                  Poll(at: 10, set: { _ in }, actions: [])]),
    .init(name: "row 4: battery guard, lid closed → sleepnow even with sleepWhenDone off",
          config: { $0.sleepWhenDone = false },
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: []),
                  Poll(at: 5, set: { ownedAwake(&$0); $0.lidClosed = true; $0.onBattery = true; $0.batteryPercent = 14 },
                       actions: [.notify(.batteryPause(floor: 15)), .disableSleepDisabled]),
                  Poll(at: 10, set: { $0.sessions = [workingClaude]; $0.lidClosed = true; $0.onBattery = true; $0.batteryPercent = 14 },
                       actions: [.sleepNow])]),
    .init(name: "row 4: thermal guard, lid closed → sleepnow",
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: []),
                  Poll(at: 5, set: { ownedAwake(&$0); $0.lidClosed = true; $0.thermal = .serious },
                       actions: [.notify(.thermalPause), .disableSleepDisabled]),
                  Poll(at: 10, set: { $0.sessions = [workingClaude]; $0.lidClosed = true; $0.thermal = .serious }, actions: [.sleepNow])]),
    .init(name: "row 5: lid open→closed while owned and awake → displaysleepnow",
          polls: [Poll(at: 0, set: ownedAwake, actions: []),
                  Poll(at: 5, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: [.displaySleepNow])]),
    .init(name: "row 6: lid closed, built-in lit → displaysleepnow at most once per 60 s",
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.lidClosed = true }, actions: [.displaySleepNow]),
                  Poll(at: 5, set: { ownedAwake(&$0); $0.lidClosed = true }, actions: []),
                  Poll(at: 60, set: { ownedAwake(&$0); $0.lidClosed = true }, actions: [.displaySleepNow]),
                  Poll(at: 65, set: { ownedAwake(&$0); $0.lidClosed = true; $0.builtinDisplayAsleep = true }, actions: [])]),
    .init(name: "row 6: toggle off → no display action",
          config: { $0.sleepDisplayOnLidClose = false },
          polls: [Poll(at: 0, set: ownedAwake, actions: []),
                  Poll(at: 5, set: { ownedAwake(&$0); $0.lidClosed = true }, actions: [])]),
    .init(name: "row 7: external display online → no displaysleepnow and no sleepnow",
          config: { $0.grace = 0 },
          polls: [Poll(at: 0, set: { ownedAwake(&$0); $0.externalDisplayOnline = true }, actions: []),
                  Poll(at: 5, set: { ownedAwake(&$0); $0.externalDisplayOnline = true; $0.lidClosed = true }, actions: []),
                  Poll(at: 70, set: { ownedAwake(&$0); $0.externalDisplayOnline = true; $0.lidClosed = true }, actions: []),
                  Poll(at: 75, set: { $0.sleepDisabled = true; $0.owned = true; $0.externalDisplayOnline = true; $0.lidClosed = true },
                       actions: [.disableSleepDisabled]),
                  Poll(at: 80, set: { $0.externalDisplayOnline = true; $0.lidClosed = true }, actions: [])]),
    .init(name: "row 8: Unmanaged → no row fires (lid closing, agents finishing)",
          config: { $0.grace = 0 },
          polls: [Poll(at: 0, set: { $0.sleepDisabled = true; $0.sessions = [workingClaude] }, actions: [], status: .unmanaged),
                  Poll(at: 5, set: { $0.sleepDisabled = true; $0.sessions = [workingClaude]; $0.lidClosed = true }, actions: []),
                  Poll(at: 10, set: { $0.sleepDisabled = true; $0.lidClosed = true }, actions: [])]),
    .init(name: "§8 restart with lid closed mid-task: restored lastWorkingAt keeps it awake, no sleepnow (F-03)",
          lastWorkingAt: t0 - 30,
          polls: [Poll(at: 0, set: { $0.sessions = [idleClaude]; $0.sleepDisabled = true; $0.owned = true; $0.lidClosed = true; $0.builtinDisplayAsleep = true },
                       actions: [], status: .grace(remaining: 570))]),
]

@Test("§6.3 actions", arguments: actionRows)
func actionRow(_ s: Scenario) { run(s) }
