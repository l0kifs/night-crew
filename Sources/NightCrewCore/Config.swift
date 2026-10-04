import Foundation

/// Tunables from SPEC §5.3, §6 and §10. Defaults are the spec's defaults.
public struct Config: Equatable, Sendable {
    /// §6.1
    public var pollInterval: TimeInterval = 5
    /// §5.3: window for transcript writes and CPU deltas.
    public var activityWindow: TimeInterval = 60
    /// §5.3: subtree CPU seconds within `activityWindow` that count as working.
    public var cpuThreshold: TimeInterval = 3.0
    /// §6.2 rule 6.
    public var grace: TimeInterval = 10 * 60
    /// §6.2 rule 3, in percent. `nil` is "Off".
    public var batteryFloor: Int? = 15
    /// §6.2: a thermal pause ends after this long at `fair` or better.
    public var thermalRecovery: TimeInterval = 10 * 60
    /// §6.2: Always awake reverts to Auto after this long.
    public var alwaysAwakeDuration: TimeInterval = 8 * 60 * 60
    /// §6.3: repeat interval for `displaysleepnow` while the lid stays closed.
    public var displaySleepRepeat: TimeInterval = 60
    /// §6.3: OFF-path retry interval after a failure.
    public var offRetryInterval: TimeInterval = 60
    /// §10 "Sleep display when lid closes".
    public var sleepDisplayOnLidClose = true
    /// §10 "Sleep Mac when agents finish (lid closed)".
    public var sleepWhenDone = true

    public init() {}
}
