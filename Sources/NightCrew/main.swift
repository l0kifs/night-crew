import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func seconds(default value: TimeInterval) -> TimeInterval {
    guard let flag = arguments.firstIndex(of: "--seconds"), flag + 1 < arguments.count,
          let parsed = TimeInterval(arguments[flag + 1]), parsed >= 0 else { return value }
    return parsed
}

switch arguments.first {
case "probe":
    ProbeCommand(duration: seconds(default: 60)).run()
case "power":
    PowerCommand(duration: seconds(default: 0)).run()
default:
    FileHandle.standardError.write(Data("usage: nightcrew probe [--seconds N]\n       nightcrew power [--seconds N]\n".utf8))
    exit(64)
}
