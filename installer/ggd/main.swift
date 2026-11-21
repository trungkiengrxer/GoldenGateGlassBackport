// ggd: helper for the Golden Gate Glass package. `ggd daemon [--once]` (root) or `ggd agent` (user).
import Foundation

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "daemon": Daemon.main(once: args.dropFirst().first == "--once")
case "agent": Agent.main()
default:
    FileHandle.standardError.write(Data("usage: ggd daemon [--once] | ggd agent\n".utf8))
    exit(2)
}
