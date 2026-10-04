import Foundation
import NightCrewCore

/// Menu choices and `lastWorkingAt`, in the `dev.l0kifs.nightcrew` defaults domain (removed by `uninstall.sh --purge`).
final class Settings {
    private let defaults: UserDefaults

    init() {
        // A bundled app's standard domain is already its bundle id; a bare executable needs the suite.
        defaults = Bundle.main.bundleIdentifier == "dev.l0kifs.nightcrew"
            ? .standard : (UserDefaults(suiteName: "dev.l0kifs.nightcrew") ?? .standard)
    }

    var mode: Mode {
        get {
            switch defaults.string(forKey: "mode") {
            case "off": return .off
            case "alwaysOn": return .alwaysOn(until: defaults.object(forKey: "alwaysOnUntil") as? Date ?? .distantPast)
            default: return .auto
            }
        }
        set {
            switch newValue {
            case .auto: defaults.set("auto", forKey: "mode")
            case .off: defaults.set("off", forKey: "mode")
            case .alwaysOn(let until):
                defaults.set("alwaysOn", forKey: "mode")
                defaults.set(until, forKey: "alwaysOnUntil")
            }
        }
    }

    var config: Config {
        get {
            var config = Config()
            if let grace = defaults.object(forKey: "graceMinutes") as? Int { config.grace = TimeInterval(grace * 60) }
            if let floor = defaults.object(forKey: "batteryFloor") as? Int { config.batteryFloor = floor > 0 ? floor : nil }
            if let value = defaults.object(forKey: "sleepDisplayOnLidClose") as? Bool { config.sleepDisplayOnLidClose = value }
            if let value = defaults.object(forKey: "sleepWhenDone") as? Bool { config.sleepWhenDone = value }
            return config
        }
        set {
            defaults.set(Int(newValue.grace / 60), forKey: "graceMinutes")
            defaults.set(newValue.batteryFloor ?? 0, forKey: "batteryFloor")
            defaults.set(newValue.sleepDisplayOnLidClose, forKey: "sleepDisplayOnLidClose")
            defaults.set(newValue.sleepWhenDone, forKey: "sleepWhenDone")
        }
    }

    var lastWorkingAt: Date? {
        get { defaults.object(forKey: "lastWorkingAt") as? Date }
        set { defaults.set(newValue, forKey: "lastWorkingAt") }
    }
}
