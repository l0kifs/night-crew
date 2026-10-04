import Foundation
import NightCrewCore

let arguments = Array(CommandLine.arguments.dropFirst())

func seconds(default value: TimeInterval) -> TimeInterval {
    guard let flag = arguments.firstIndex(of: "--seconds"), flag + 1 < arguments.count,
          let parsed = TimeInterval(arguments[flag + 1]), parsed >= 0 else { return value }
    return parsed
}

switch arguments.first {
case nil, "--launchd":
    MenuApp.run(launchedByLaunchd: arguments.first == "--launchd")
case "menu":
    MenuCommand().run()
case "probe":
    ProbeCommand(duration: seconds(default: 60)).run()
case "power":
    PowerCommand(duration: seconds(default: 0)).run()
case "watch":
    let mode: Mode = arguments.contains("--off") ? .off : .auto
    WatchCommand(duration: seconds(default: 60), mode: mode, live: arguments.contains("--live")).run()
default:
    FileHandle.standardError.write(Data("""
        usage: nightcrew [--launchd]          the menu bar app
               nightcrew menu                     print the menu once (dry)
               nightcrew probe [--seconds N]
               nightcrew power [--seconds N]
               nightcrew watch [--seconds N] [--off] [--live]

        """.utf8))
    exit(64)
}
