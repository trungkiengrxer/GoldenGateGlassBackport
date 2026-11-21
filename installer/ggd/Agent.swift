// ggd agent (user, LaunchAgent com.goldengateglass.agent): safety net after login. The daemon usually sets the variable
// in time; the agent only relaunches processes that started before the variable existed (GGAppLoader not loaded).
import Foundation

enum Agent {
    static let paths = Paths.fromEnvironment(environment)
    static let logFile = environment["GG_AGENT_LOG"] ?? NSHomeDirectory() + "/Library/Logs/GoldenGate/agent.log"

    static func log(_ s: String) { logLine(logFile, s) }

    static func loaded(_ pid: pid_t) -> Bool {
        hasLoader(lsofOutput: run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"]).out, loader: paths.loader)
    }

    static func main() -> Never {
        guard appAllowed(paths, exists: fileExists) else { log("missing \(paths.loader) or \(paths.appDylib), not enabling"); exit(0) }
        let current = run(launchctl, ["getenv", "DYLD_INSERT_LIBRARIES"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = mergedInsertLibraries(current: current, loader: paths.loader)
        let r = run(launchctl, ["setenv", "DYLD_INSERT_LIBRARIES", value])
        log("agent running, previous value: \(current.isEmpty ? "(empty)" : current), set \(value) (\(r.status))")

        for name in systemUIProcesses {
            for pid in pids(named: name, uid: getuid()) {
                if loaded(pid) { log("\(name) (\(pid)) already loaded"); continue }
                kill(pid, SIGTERM)   // launchd relaunches it
                log("\(name) (\(pid)) not loaded: relaunching")
            }
        }
        for item in loginItems(lsappinfo: run("/usr/bin/lsappinfo", ["list"]).out) {
            if loaded(item.pid) { log("login item \(item.path) (\(item.pid)) already loaded"); continue }
            kill(item.pid, SIGTERM)
            for _ in 0..<50 where kill(item.pid, 0) == 0 { usleep(100_000) }
            run("/usr/bin/open", ["-g", item.path])
            log("login item \(item.path) (\(item.pid)) not loaded: relaunching")
        }
        exit(0)
    }
}
