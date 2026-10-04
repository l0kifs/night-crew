import Foundation
import NightCrewCore

/// `nightcrew power`: prints the power inputs the engine sees (SPEC §6.1), once per poll.
struct PowerCommand {
    var duration: TimeInterval
    var config = Config()

    func run() {
        let power = PowerControl()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let start = Date()
        var next = start
        while next.timeIntervalSince(start) <= duration {
            Thread.sleep(until: next)
            let r = power.read()
            let battery = r.batteryPercent.map { "\($0)%" } ?? "none"
            print("\(clock.string(from: Date()))  SleepDisabled \(r.sleepDisabled ? 1 : 0) · lid \(r.lidClosed ? "closed" : "open")"
                  + " · built-in display \(r.builtinDisplayAsleep ? "asleep" : "on")"
                  + " · external display \(r.externalDisplayOnline ? "online" : "none")"
                  + " · battery \(battery) \(r.onBattery ? "(on battery)" : "(on AC)") · thermal \(r.thermal)")
            next += config.pollInterval
        }
    }
}
