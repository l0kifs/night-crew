import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "probe":
    var seconds: TimeInterval = 60
    if let flag = arguments.firstIndex(of: "--seconds"), flag + 1 < arguments.count,
       let value = TimeInterval(arguments[flag + 1]), value > 0 {
        seconds = value
    }
    ProbeCommand(duration: seconds).run()
default:
    FileHandle.standardError.write(Data("usage: nightcrew probe [--seconds N]\n".utf8))
    exit(64)
}
