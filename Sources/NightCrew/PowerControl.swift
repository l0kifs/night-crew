import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import NightCrewCore

/// SPEC §7, read side. Writes (`sudo -n pmset -a disablesleep`, `sleepnow`, `displaysleepnow`) come later.
struct PowerControl {
    func read() -> PowerReading {
        let displays = displayState()
        let battery = batteryState()
        return PowerReading(sleepDisabled: Pmset.sleepDisabled(in: run("/usr/bin/pmset", ["-g"])),
                            lidClosed: lidClosed(),
                            externalDisplayOnline: displays.externalOnline,
                            builtinDisplayAsleep: displays.builtinAsleep,
                            onBattery: battery.onBattery,
                            batteryPercent: battery.percent,
                            thermal: thermalState())
    }

    /// IORegistry `IOPMrootDomain` → `AppleClamshellState`. A Mac without a lid has no such key: not closed.
    private func lidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`; asleep is read on the built-in display, never `CGMainDisplayID`.
    private func displayState() -> (externalOnline: Bool, builtinAsleep: Bool) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return (false, false) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return (false, false) }
        let online = ids.prefix(Int(count))
        let builtin = online.first { CGDisplayIsBuiltin($0) != 0 }
        return (online.contains { CGDisplayIsBuiltin($0) == 0 }, builtin.map { CGDisplayIsAsleep($0) != 0 } ?? false)
    }

    private func batteryState() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (onBattery, current * 100 / max)
        }
        return (onBattery, nil)
    }

    private func thermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious   // unknown is treated as a reason to pause (SPEC §6.2 rule 2)
        }
    }

    private func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
