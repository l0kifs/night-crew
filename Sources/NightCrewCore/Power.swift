/// What `PowerControl` reads on one poll (SPEC §6.1, §7).
public struct PowerReading: Equatable, Sendable {
    public var sleepDisabled: Bool
    public var lidClosed: Bool
    public var externalDisplayOnline: Bool
    public var builtinDisplayAsleep: Bool
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalState

    public init(sleepDisabled: Bool, lidClosed: Bool, externalDisplayOnline: Bool, builtinDisplayAsleep: Bool,
                onBattery: Bool, batteryPercent: Int?, thermal: ThermalState) {
        self.sleepDisabled = sleepDisabled
        self.lidClosed = lidClosed
        self.externalDisplayOnline = externalDisplayOnline
        self.builtinDisplayAsleep = builtinDisplayAsleep
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

public enum Pmset {
    /// `SleepDisabled` from `pmset -g`. Anything but a `SleepDisabled 1` line, including a missing line, reads as
    /// "not 1" (SPEC §7), so the OFF path can never be skipped because of an unexpected format.
    public static func sleepDisabled(in output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
        }
        return false
    }
}
