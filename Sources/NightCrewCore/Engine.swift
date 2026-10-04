import Foundation

public enum Mode: Equatable, Sendable {
    case auto
    case off
    /// Always awake until the given time; then it reverts to Auto (SPEC §6.2).
    case alwaysOn(until: Date)
}

/// Mirrors `ProcessInfo.ThermalState`.
public enum ThermalState: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Session: Equatable, Sendable {
    public var root: SessionRoot
    public var working: Bool

    public init(root: SessionRoot, working: Bool) {
        self.root = root
        self.working = working
    }
}

/// Everything the engine reads on one poll (SPEC §6.1).
public struct Inputs: Equatable, Sendable {
    public var now: Date
    public var sessions: [Session] = []
    public var lidClosed = false
    public var externalDisplayOnline = false
    public var builtinDisplayAsleep = false
    public var onBattery = false
    public var batteryPercent: Int?
    public var thermal: ThermalState = .nominal
    /// `SleepDisabled` from `pmset -g` this poll. A missing line reads as false (SPEC §7).
    public var sleepDisabled = false
    /// `~/.nightcrew/owned` exists (SPEC §8).
    public var owned = false
    public var mode: Mode = .auto

    public init(now: Date) {
        self.now = now
    }
}

public enum Notice: Equatable, Sendable {
    case thermalPause
    case batteryPause(floor: Int)
}

public enum Action: Equatable, Sendable {
    /// Create the ownership file, `sudo -n pmset -a disablesleep 1`, read back. On failure undo and clear
    /// ownership. Report the result with `Engine.record(_:at:)` (SPEC §6.3 row 1).
    case enableSleepDisabled
    /// `sudo -n pmset -a disablesleep 0`, read back, remove the ownership file once it is not 1.
    /// Report the result with `Engine.record(_:at:)` (SPEC §6.3 row 2).
    case disableSleepDisabled
    case sleepNow
    case displaySleepNow
    case notify(Notice)
    /// Always awake expired: persist mode = Auto (SPEC §6.2).
    case revertModeToAuto
}

/// Results of the two composite power actions.
public enum Outcome: Equatable, Sendable {
    case enabled
    case enableSudoFailed
    case enableHadNoEffect
    /// `~/.nightcrew/owned` could not be written, so SleepDisabled was not touched.
    case enableOwnershipFailed
    case disabled
    case disableFailed
}

public enum Status: Equatable, Sendable {
    case unmanaged
    case setupRequired
    case error(String)
    case pausedThermal
    case pausedBattery(floor: Int)
    case off
    case alwaysAwake(until: Date)
    case awake(working: Int)
    case grace(remaining: TimeInterval)
    case idle
}

public struct Output: Equatable, Sendable {
    public var actions: [Action]
    public var awake: Bool
    public var status: Status
    /// The menu icon shows the error symbol.
    public var iconError: Bool
}

/// SPEC §6: desired state and actions. Pure: inputs in, actions out; the app layer executes them.
public struct Engine: Sendable {
    public var config: Config
    /// Persisted by the app (at most every 30 s while working) and passed back on launch (SPEC §6.2).
    public private(set) var lastWorkingAt: Date?

    private var previousAwake: Bool?
    private var previousLidClosed: Bool?
    private var lastDisplaySleepAt: Date?
    private var pendingSleepNow = false
    private var thermalPaused = false
    private var thermalCalmSince: Date?
    private var thermalNotified = false
    private var batteryNotified = false
    /// Set by an ON-path failure; only `retry()` clears it (SPEC §7).
    private var onPathSuspended: Status?
    private var lastOffAttemptAt: Date?
    private var offFailing = false

    public init(config: Config = Config(), lastWorkingAt: Date? = nil) {
        self.config = config
        self.lastWorkingAt = lastWorkingAt
    }

    /// The menu's Retry item.
    public mutating func retry() {
        onPathSuspended = nil
    }

    public mutating func record(_ outcome: Outcome, at now: Date) {
        switch outcome {
        case .enabled: break
        case .enableSudoFailed: onPathSuspended = .setupRequired
        case .enableHadNoEffect: onPathSuspended = .error("disablesleep had no effect")
        case .enableOwnershipFailed: onPathSuspended = .error("cannot write ~/.nightcrew/owned")
        case .disabled: offFailing = false
        case .disableFailed: offFailing = true
        }
    }

    public mutating func step(_ input: Inputs) -> Output {
        let now = input.now
        defer { previousLidClosed = input.lidClosed }

        // Rule 1: the user's own SleepDisabled. No power action of any kind.
        if input.sleepDisabled && !input.owned {
            previousAwake = nil
            pendingSleepNow = false
            return Output(actions: [], awake: false, status: .unmanaged, iconError: false)
        }

        var actions: [Action] = []
        var mode = input.mode
        if case .alwaysOn(let until) = mode, now >= until {
            mode = .auto
            actions.append(.revertModeToAuto)
        }

        let workingCount = input.sessions.filter(\.working).count
        if workingCount > 0 { lastWorkingAt = now }

        // Rules 4–6.
        let modeAwake: Bool
        let modeStatus: Status
        switch mode {
        case .off:
            (modeAwake, modeStatus) = (false, .off)
        case .alwaysOn(let until):
            (modeAwake, modeStatus) = (true, .alwaysAwake(until: until))
        case .auto:
            if workingCount > 0 {
                (modeAwake, modeStatus) = (true, .awake(working: workingCount))
            } else if let last = lastWorkingAt, now.timeIntervalSince(last) < config.grace {
                (modeAwake, modeStatus) = (true, .grace(remaining: config.grace - now.timeIntervalSince(last)))
            } else {
                (modeAwake, modeStatus) = (false, .idle)
            }
        }

        // Rule 2: thermal pause with recovery hysteresis.
        if input.thermal >= .serious {
            thermalPaused = true
            thermalCalmSince = nil
        } else if thermalPaused {
            let calmSince = thermalCalmSince ?? now
            thermalCalmSince = calmSince
            if now.timeIntervalSince(calmSince) >= config.thermalRecovery {
                thermalPaused = false
                thermalCalmSince = nil
                thermalNotified = false
            }
        }

        // Rule 3: battery pause, lifted as soon as on AC or at/above the floor.
        if !input.onBattery { batteryNotified = false }
        var batteryFloorHit: Int?
        if input.onBattery, let floor = config.batteryFloor, let percent = input.batteryPercent, percent < floor {
            batteryFloorHit = floor
        }

        let awake: Bool
        var status: Status
        let guardActive = thermalPaused || batteryFloorHit != nil
        if thermalPaused {
            (awake, status) = (false, .pausedThermal)
            // One notification per pause, and only if the pause overrides an awake state.
            if modeAwake && !thermalNotified {
                actions.append(.notify(.thermalPause))
                thermalNotified = true
            }
        } else if let floor = batteryFloorHit {
            (awake, status) = (false, .pausedBattery(floor: floor))
            if modeAwake && !batteryNotified {
                actions.append(.notify(.batteryPause(floor: floor)))
                batteryNotified = true
            }
        } else {
            (awake, status) = (modeAwake, modeStatus)
        }

        // SleepDisabled is level-triggered against the observed value (§6.3 rows 1–2).
        if awake {
            lastOffAttemptAt = nil
            if !input.sleepDisabled && onPathSuspended == nil {
                actions.append(.enableSleepDisabled)
            }
        } else if input.owned {
            if lastOffAttemptAt.map({ now.timeIntervalSince($0) >= config.offRetryInterval }) ?? true {
                actions.append(.disableSleepDisabled)
                lastOffAttemptAt = now
            }
        }

        let lidClosedAlone = input.lidClosed && !input.externalDisplayOnline

        // §6.3 rows 3–4: sleepnow after awake true→false. It is refused while SleepDisabled is 1,
        // so it waits for a poll that reads SleepDisabled as not 1.
        if previousAwake == true && !awake && lidClosedAlone {
            let agentsFinished = mode == .auto && modeStatus == .idle
            if guardActive || (agentsFinished && config.sleepWhenDone) { pendingSleepNow = true }
        }
        if awake || !lidClosedAlone { pendingSleepNow = false }
        if pendingSleepNow && !input.sleepDisabled {
            actions.append(.sleepNow)
            pendingSleepNow = false
        }

        // §6.3 rows 5–6: built-in display off while the Mac is kept awake with the lid closed.
        if config.sleepDisplayOnLidClose && awake && input.owned && lidClosedAlone {
            let dueAgain = lastDisplaySleepAt.map { now.timeIntervalSince($0) >= config.displaySleepRepeat } ?? true
            if previousLidClosed == false || (!input.builtinDisplayAsleep && dueAgain) {
                actions.append(.displaySleepNow)
                lastDisplaySleepAt = now
            }
        }

        previousAwake = awake
        if let suspended = onPathSuspended { status = suspended }
        return Output(actions: actions, awake: awake, status: status,
                      iconError: offFailing || onPathSuspended != nil)
    }
}
