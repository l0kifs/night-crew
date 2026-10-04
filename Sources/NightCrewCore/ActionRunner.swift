// The primitives the actions are built from (SPEC §7, §8), behind protocols so the sequences are testable.
public protocol PowerCommanding {
    /// `sudo -n /usr/bin/pmset -a disablesleep 1|0`. False when sudo or pmset exits non-zero.
    func setSleepDisabled(_ on: Bool) -> Bool
    /// `SleepDisabled` from `pmset -g`; anything but 1 reads as false.
    func readSleepDisabled() -> Bool
    func sleepNow() -> Bool
    func displaySleepNow() -> Bool
}

public protocol OwnershipStoring: OwnershipReading {
    /// Creates `~/.nightcrew/owned`, durable (fsync) before returning.
    func create() throws
    func remove() throws
}

public protocol Notifying {
    func notify(_ notice: Notice)
}

public protocol ModeStoring {
    func revertToAuto()
}

/// Executes `Engine` actions. The two SleepDisabled actions are sequences whose result goes back to the engine.
public struct ActionRunner {
    private let power: any PowerCommanding
    private let ownership: any OwnershipStoring
    private let notifier: any Notifying
    private let modes: any ModeStoring

    public init(power: any PowerCommanding, ownership: any OwnershipStoring, notifier: any Notifying, modes: any ModeStoring) {
        self.power = power
        self.ownership = ownership
        self.notifier = notifier
        self.modes = modes
    }

    /// Runs one action. Returns the outcome to pass to `Engine.record` for the two SleepDisabled actions.
    public func run(_ action: Action) -> Outcome? {
        switch action {
        case .enableSleepDisabled: return enable()
        case .disableSleepDisabled: return disable()
        case .sleepNow: _ = power.sleepNow(); return nil
        case .displaySleepNow: _ = power.displaySleepNow(); return nil
        case .notify(let notice): notifier.notify(notice); return nil
        case .revertModeToAuto: modes.revertToAuto(); return nil
        }
    }

    /// SPEC §8 Quit / SIGTERM / SIGINT: give back a SleepDisabled the app owns.
    public func shutdown() -> Outcome? {
        ownership.isOwned() ? disable() : nil
    }

    /// §6.3 row 1. Ownership is durable before SleepDisabled can become 1, so a crash in between is still owned.
    private func enable() -> Outcome {
        do { try ownership.create() } catch { return .enableOwnershipFailed }
        let sudoWorked = power.setSleepDisabled(true)
        if sudoWorked && power.readSleepDisabled() { return .enabled }
        _ = disable()
        return sudoWorked ? .enableHadNoEffect : .enableSudoFailed
    }

    /// §6.3 row 2. Ownership is cleared only once a read-back shows SleepDisabled is not 1, whatever sudo said.
    private func disable() -> Outcome {
        _ = power.setSleepDisabled(false)
        guard !power.readSleepDisabled() else { return .disableFailed }
        try? ownership.remove()
        return .disabled
    }
}
