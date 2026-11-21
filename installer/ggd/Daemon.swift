// ggd daemon (root, LaunchDaemon com.goldengateglass.daemon):
// - arm GGGlass for the next WindowServer launch, and re-arm every time a new WindowServer appears;
// - at boot, while still at the login window: arm, then restart WindowServer once (the daemon starts ~5 s after it);
// - when the console switches to a regular user: set DYLD_INSERT_LIBRARIES for that user's gui domain right away
//   (racing Dock, won by 0.28 s in testing); the agent is the safety net.
// Test: installer/tests/ggd.sh (`ggd daemon --once`, GG_CONSOLE_USER, GG_WS_PID stand in for console and WindowServer).
import Foundation
import SystemConfiguration

enum Daemon {
    static let paths = Paths.fromEnvironment(environment)
    static let logFile = environment["GG_LOG"] ?? "/Library/Logs/GoldenGate/ggd.log"
    static var lastConsole = ""
    static var exitSource: DispatchSourceProcess?

    static func log(_ s: String) { logLine(logFile, s) }

    /// Console owner. The login window (SC returns nil or loginwindow) maps to "root", like `stat -f %Su /dev/console`.
    static func consoleUser() -> String {
        if let u = environment["GG_CONSOLE_USER"] { return u }
        let u = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?
        return (u == nil || u == "loginwindow") ? "root" : u!
    }

    static func windowServerPID() -> pid_t? {
        if let s = environment["GG_WS_PID"] { return Int32(s).flatMap { $0 > 0 ? $0 : nil } }
        return pids(named: "WindowServer").first
    }

    /// Arm GGGlass for the next WindowServer launch. Status 37: already armed and pending (still in effect).
    static func arm() {
        guard glassAllowed(paths, exists: fileExists) else { log("not armed: missing \(paths.glassDylib) or \(paths.disable) exists"); return }
        let r = run(launchctl, ["debug", "system/com.apple.WindowServer", "--environment", "DYLD_INSERT_LIBRARIES=\(paths.glassDylib)"])
        log(r.status == 37 ? "WindowServer already armed (pending)" : "armed GGGlass for the next launch (\(r.status))")
    }

    /// Whether the user's Dock is running (GG_DOCK_FILE for tests: the file exists means Dock is running).
    static func dockRunning(_ uid: uid_t) -> Bool {
        if let f = environment["GG_DOCK_FILE"] { return fileExists(f) }
        return !pids(named: "Dock", uid: uid).isEmpty
    }

    /// Set the variable for the gui domain of the user who just took the console (racing Dock):
    /// - the console changes before launchd creates the gui domain (40 ms-1 s); `asuser setenv` at that point lands in the
    ///   user domain, which gui does not inherit; launchd spawns Dock ~1-1.1 s after the domain; each asuser call during
    ///   login costs 100-650 ms;
    /// - so for a fresh login (no Dock yet) do not query the domain, just keep calling `asuser setenv` until Dock runs
    ///   (checked in-process, nearly free), then set it once more to be sure it lands in gui. The domain is new, so the
    ///   variable holds only the loader;
    /// - Dock already running (daemon restarted while the user is logged in): getenv then setenv, keeping other entries.
    /// At most GG_GUI_WAIT seconds (default 10); after that the agent handles what is left.
    static func handleConsole(_ user: String) {
        lastConsole = user
        guard let uid = envTarget(consoleUser: user, uid: getpwnam(user)?.pointee.pw_uid) else { return }
        guard appAllowed(paths, exists: fileExists) else { log("console \(user): variable not set, missing \(paths.loader) or \(paths.appDylib)"); return }
        let id = String(uid), start = Date()
        var value = paths.loader, rounds = 0, docked = true
        func set() { rounds += 1; run(launchctl, ["asuser", id, launchctl, "setenv", "DYLD_INSERT_LIBRARIES", value]) }
        if dockRunning(uid) {
            let current = run(launchctl, ["asuser", id, launchctl, "getenv", "DYLD_INSERT_LIBRARIES"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value = mergedInsertLibraries(current: current, loader: paths.loader)
            set()
        } else {
            let deadline = start.addingTimeInterval(Double(environment["GG_GUI_WAIT"] ?? "") ?? 10)
            repeat { set() } while !dockRunning(uid) && Date() < deadline
            docked = dockRunning(uid)
            set()
        }
        let total = Int(Date().timeIntervalSince(start) * 1000)
        log("console \(user) (uid \(uid)): set DYLD_INSERT_LIBRARIES = \(value); \(rounds) times, \(total) ms"
            + (docked ? "" : "; Dock not running after the wait limit (agent handles the rest)"))
    }

    static func startup() {
        let ws = windowServerPID(), user = consoleUser()
        log("daemon running, WindowServer: \(ws.map(String.init) ?? "none"), console: \(user)")
        if restartAtBoot(windowServerRunning: ws != nil, glassAllowed: glassAllowed(paths, exists: fileExists), consoleUser: user) {
            arm()
            run(killallTool, ["-HUP", "WindowServer"])
            log("WindowServer started before the daemon, at the login window: armed, then restarted WindowServer")
        } else {
            arm()
        }
        handleConsole(user)
    }

    /// Wait for the current WindowServer to exit (kqueue), wait for the new pid, arm for the launch after that, then
    /// watch the new pid.
    static func watchWindowServer() {
        guard let pid = windowServerPID() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { watchWindowServer() }   // Simplification: polls only while waiting for a new pid
            return
        }
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler {
            src.cancel()
            log("WindowServer \(pid) exited")
            waitForNewWindowServer(old: pid)
        }
        exitSource = src
        src.resume()
    }

    static func waitForNewWindowServer(old: pid_t) {
        if let pid = windowServerPID(), pid != old {
            log("new WindowServer: \(pid)")
            arm()
            watchWindowServer()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForNewWindowServer(old: old) }
        }
    }

    static func watchConsole() {
        var ctx = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "com.goldengateglass.daemon" as CFString, { _, _, _ in
            let user = Daemon.consoleUser()
            if user != Daemon.lastConsole { Daemon.handleConsole(user) }
        }, &ctx) else { log("could not create SCDynamicStore"); return }
        SCDynamicStoreSetNotificationKeys(store, ["State:/Users/ConsoleUser"] as CFArray, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .defaultMode)
    }

    static func main(once: Bool) -> Never {
        startup()
        if once { exit(0) }
        watchConsole()
        watchWindowServer()
        RunLoop.main.run()
        exit(0)
    }
}
