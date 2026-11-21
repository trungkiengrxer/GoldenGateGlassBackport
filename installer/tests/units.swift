import Foundation

@main
enum ModelTests {
    static func main() {
        var failed = false
        func check(_ condition: Bool, _ name: String) {
            print(condition ? "OK  \(name)" : "FAIL \(name)")
            if !condition { failed = true }
        }

        check(machineProblem(checkExitCode: 0) == nil, "supported machine")
        check(machineProblem(checkExitCode: 3) == "System Integrity Protection (filesystem) must be disabled.", "SIP requirement message")
        check(machineProblem(checkExitCode: 99) == "Could not check this Mac.", "unknown check code")

        let log = "2026-11-20 00:46:19 +0000 [443] enabled (tint 0.5)"
        check(glassLoaded(log: log, windowServerPID: 443), "log has an enabled line for the current PID")
        check(!glassLoaded(log: log, windowServerPID: 444), "ignores enabled lines of other PIDs")
        check(!glassLoaded(log: "2026-11-20 00:46:19 +0000 [443] enabled again after restart", windowServerPID: 443), "does not treat 'enabled again' as loaded")

        let files = ["user": ["a.excluded", "b.crashes"], "container": ["z.excluded", "a.excluded"]]
        check(excludedBundleIDs(guardDirs: ["container", "user"]) { files[$0] ?? [] } == ["a", "z"], "merges, dedupes and sorts excluded apps")
        check(effects.count == 14 && Set(effects.map(\.key)).count == 14, "all 14 effects, no duplicate keys")
        check(effects.filter { !$0.defaultOn }.map(\.key) == ["sidebarGlass"], "only sidebarGlass is off by default")
        check(!effects.contains { ["sidebarCatalyst", "settingsMoof"].contains($0.key) }, "experimental keys not exposed in the app")

        // ggd (installer/ggd/Logic.swift)
        check(envTarget(consoleUser: "alice", uid: 501) == 501, "variable set for user 501")
        check(envTarget(consoleUser: "anna", uid: 502) == 502, "variable set for a user other than 501")
        check(envTarget(consoleUser: "_windowserver", uid: 88) == nil, "no variable for _windowserver")
        check(envTarget(consoleUser: "root", uid: 0) == nil, "no variable for root (login window)")
        check(envTarget(consoleUser: "", uid: nil) == nil, "no console user")
        check(envTarget(consoleUser: "daemonish", uid: 300) == nil, "uid below 501")

        check(mergedInsertLibraries(current: nil, loader: "/L") == "/L", "merge: no variable yet")
        check(mergedInsertLibraries(current: "", loader: "/L") == "/L", "merge: empty variable")
        check(mergedInsertLibraries(current: "/L", loader: "/L") == "/L", "merge: no duplicate")
        check(mergedInsertLibraries(current: "/x/a.dylib", loader: "/L") == "/x/a.dylib:/L", "merge: keeps other dylibs")
        check(mergedInsertLibraries(current: "/L:/x/a.dylib", loader: "/L") == "/x/a.dylib:/L", "merge: moves loader to the end")

        check(restartAtBoot(windowServerRunning: true, glassAllowed: true, consoleUser: "root"), "restart WindowServer at the login window")
        check(!restartAtBoot(windowServerRunning: true, glassAllowed: true, consoleUser: "alice"), "no restart when someone is logged in")
        check(!restartAtBoot(windowServerRunning: false, glassAllowed: true, consoleUser: "root"), "no restart when WindowServer is not running")
        check(!restartAtBoot(windowServerRunning: true, glassAllowed: false, consoleUser: "root"), "no restart when GGGlass is not allowed")

        let p = Paths(glassDir: "/g", appDir: "/a", sharedDir: "/s")
        let all: Set = ["/g/GGGlass.dylib", "/a/GGAppLoader.dylib", "/a/GGApp.dylib"]
        check(glassAllowed(p) { all.contains($0) }, "GGGlass allowed with the dylib and no disable")
        check(!glassAllowed(p) { all.union(["/s/disable"]).contains($0) }, "disable present: not armed")
        check(!glassAllowed(p) { $0 == "/s/x" }, "GGGlass.dylib missing: not armed")
        check(appAllowed(p) { all.contains($0) }, "ggapp allowed with both loader and GGApp.dylib")
        check(!appAllowed(p) { $0 == "/a/GGAppLoader.dylib" }, "GGApp.dylib missing: variable not set")
        let env = Paths.fromEnvironment(["GG_GLASS_DIR": "/g", "GG_APP_DIR": "/a", "GG_ROOT": "/s"])
        check(env.glassDylib == "/g/GGGlass.dylib" && env.loader == "/a/GGAppLoader.dylib" && env.disable == "/s/disable", "paths read from env")
        let def = Paths.fromEnvironment([:])
        check(def.glassDylib == "/Library/GoldenGate/GGGlass.dylib" && def.loader == "/Library/GoldenGate/app/GGAppLoader.dylib"
              && def.disable == "/Users/Shared/GoldenGate/disable", "default paths")

        func entry(_ pid: Int32, _ path: String, _ type: String, _ ago: String) -> String {
            """
              \(pid)) "\((path as NSString).lastPathComponent)" ASN:0x0-0x\(pid):
                bundleID="x.\(pid)"
                bundle path="\(path)"
                executable path="\(path)/Contents/MacOS/x"
                pid = \(pid) type="\(type)" flavor=3 Version="1" fileType="APPL" creator="????" Arch=x86_64
                checkin time = 2026/11/20 07:46:35 ( \(ago) ago )
            """
        }
        let sample = [
            entry(10, "/Applications/Raycast.app", "UIElement", "12.5 seconds"),
            entry(11, "/Applications/Bandwidth+.app", "UIElement", "3.1 seconds"),
            entry(12, "/Users/u/Applications/My App.app", "Foreground", "40 seconds"),
            entry(13, "/System/Applications/Mail.app", "Foreground", "5 seconds"),
            entry(14, "/Applications/Example.app/Contents/Frameworks/Example Helper.app", "UIElement", "5 seconds"),
            entry(15, "/System/Library/CoreServices/Finder.app", "Foreground", "5 seconds"),
            entry(16, "/Applications/Old.app", "Foreground", "2 minutes, 3.0 seconds"),
            entry(17, "/Applications/Bg.app", "BackgroundOnly", "5 seconds"),
            """
              18) "universalaccessd" ASN:0x0-0x9009:
                bundleID=[ NULL ]
                bundle path="/usr/sbin/universalaccessd"
                pid = 18 !signalled type="BackgroundOnly" flavor=3 Version=[ NULL ]  fileType="????" creator="????" Arch=x86_64
                checkin time = 2026/11/20 07:46:35 ( 3.9 seconds ago )
            """,
        ].joined(separator: "\n")
        check(loginItems(lsappinfo: sample) == [
            LoginItem(pid: 10, path: "/Applications/Raycast.app"),
            LoginItem(pid: 11, path: "/Applications/Bandwidth+.app"),
            LoginItem(pid: 12, path: "/Users/u/Applications/My App.app"),
            LoginItem(pid: 13, path: "/System/Applications/Mail.app"),
        ], "login item filter: top-level UI apps, recently launched, outside /System/Library")
        check(systemUIProcesses == ["Dock", "ControlCenter", "NotificationCenter", "SystemUIServer", "Spotlight", "Finder"], "system process list")
        check(hasLoader(lsofOutput: "p12\nn/x/GGAppLoader.dylib\n", loader: "/x/GGAppLoader.dylib"), "lsof has loader")
        check(!hasLoader(lsofOutput: "p12\nn/y/other.dylib\n", loader: "/x/GGAppLoader.dylib"), "lsof without loader")
        if failed { exit(1) }
    }
}
