import Testing
@testable import NightCrewCore

/// A fake Mac: SleepDisabled state, a sudo rule that may be missing, a pmset that may silently do nothing.
final class FakeMac: PowerCommanding, OwnershipStoring, Notifying, ModeStoring {
    var log: [String] = []
    var sleepDisabled = false
    var sudoWorks = true
    var pmsetTakesEffect = true
    var owned = false
    var ownershipWritable = true

    func setSleepDisabled(_ on: Bool) -> Bool {
        log.append("pmset \(on ? 1 : 0)")
        guard sudoWorks else { return false }
        if pmsetTakesEffect { sleepDisabled = on }
        return true
    }
    func readSleepDisabled() -> Bool { log.append("read"); return sleepDisabled }
    func sleepNow() -> Bool { log.append("sleepnow"); return true }
    func displaySleepNow() -> Bool { log.append("displaysleepnow"); return true }
    func isOwned() -> Bool { owned }
    func create() throws {
        log.append("own")
        guard ownershipWritable else { throw CocoaLikeError() }
        owned = true
    }
    func remove() throws { log.append("disown"); owned = false }
    func notify(_ notice: Notice) { log.append("notify \(notice)") }
    func revertToAuto() { log.append("auto") }

    struct CocoaLikeError: Error {}
    var runner: ActionRunner { ActionRunner(power: self, ownership: self, notifier: self, modes: self) }
}

struct RunCase: Sendable, CustomTestStringConvertible {
    let name: String
    var setup: @Sendable (FakeMac) -> Void = { _ in }
    let action: Action
    let outcome: Outcome?
    let log: [String]
    let sleepDisabled: Bool
    let owned: Bool
    var testDescription: String { name }
}

let runCases: [RunCase] = [
    .init(name: "enable: ownership is written before pmset, kept after a read-back of 1",
          action: .enableSleepDisabled, outcome: .enabled,
          log: ["own", "pmset 1", "read"], sleepDisabled: true, owned: true),
    .init(name: "enable without a sudo rule → undo attempt, ownership cleared after read-back, Setup required",
          setup: { $0.sudoWorks = false }, action: .enableSleepDisabled, outcome: .enableSudoFailed,
          log: ["own", "pmset 1", "pmset 0", "read", "disown"], sleepDisabled: false, owned: false),
    .init(name: "enable when pmset silently does nothing → undo, ownership cleared, error",
          setup: { $0.pmsetTakesEffect = false }, action: .enableSleepDisabled, outcome: .enableHadNoEffect,
          log: ["own", "pmset 1", "read", "pmset 0", "read", "disown"], sleepDisabled: false, owned: false),
    .init(name: "enable when the ownership file cannot be written → pmset never runs",
          setup: { $0.ownershipWritable = false }, action: .enableSleepDisabled, outcome: .enableOwnershipFailed,
          log: ["own"], sleepDisabled: false, owned: false),
    .init(name: "disable: ownership cleared only after the read-back",
          setup: { $0.sleepDisabled = true; $0.owned = true }, action: .disableSleepDisabled, outcome: .disabled,
          log: ["pmset 0", "read", "disown"], sleepDisabled: false, owned: false),
    .init(name: "disable when sudo fails but SleepDisabled is already 0 → still clears ownership",
          setup: { $0.owned = true; $0.sudoWorks = false }, action: .disableSleepDisabled, outcome: .disabled,
          log: ["pmset 0", "read", "disown"], sleepDisabled: false, owned: false),
    .init(name: "disable when SleepDisabled stays 1 → ownership kept for the retry and the watchdog",
          setup: { $0.sleepDisabled = true; $0.owned = true; $0.sudoWorks = false }, action: .disableSleepDisabled,
          outcome: .disableFailed, log: ["pmset 0", "read"], sleepDisabled: true, owned: true),
    .init(name: "sleepnow", action: .sleepNow, outcome: nil, log: ["sleepnow"], sleepDisabled: false, owned: false),
    .init(name: "displaysleepnow", action: .displaySleepNow, outcome: nil, log: ["displaysleepnow"], sleepDisabled: false, owned: false),
    .init(name: "notify", action: .notify(.thermalPause), outcome: nil, log: ["notify thermalPause"], sleepDisabled: false, owned: false),
    .init(name: "revert mode", action: .revertModeToAuto, outcome: nil, log: ["auto"], sleepDisabled: false, owned: false),
]

@Test("§6.3 action sequences", arguments: runCases)
func runAction(_ c: RunCase) {
    let mac = FakeMac()
    c.setup(mac)
    #expect(mac.runner.run(c.action) == c.outcome)
    #expect(mac.log == c.log)
    #expect(mac.sleepDisabled == c.sleepDisabled)
    #expect(mac.owned == c.owned)
}

@Test("§8 shutdown gives back an owned SleepDisabled and leaves a manual one alone")
func shutdown() {
    let owner = FakeMac()
    owner.sleepDisabled = true
    owner.owned = true
    #expect(owner.runner.shutdown() == .disabled)
    #expect(!owner.sleepDisabled)

    let manual = FakeMac()
    manual.sleepDisabled = true
    #expect(manual.runner.shutdown() == nil)
    #expect(manual.sleepDisabled && manual.log.isEmpty)
}
