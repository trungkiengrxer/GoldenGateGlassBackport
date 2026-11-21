// ggd decisions (daemon and agent), kept apart from launchd so they can be tested (installer/tests/units.swift).
import Foundation

/// Install locations. glassDir: GGGlass, shader, ggd (root). appDir: ggapp dylibs (root, not 777). sharedDir: disable kill-switch.
struct Paths {
    var glassDir: String
    var appDir: String
    var sharedDir: String
    var glassDylib: String { glassDir + "/GGGlass.dylib" }
    var loader: String { appDir + "/GGAppLoader.dylib" }
    var appDylib: String { appDir + "/GGApp.dylib" }
    var disable: String { sharedDir + "/disable" }

    static func fromEnvironment(_ env: [String: String]) -> Paths {
        Paths(glassDir: env["GG_GLASS_DIR"] ?? "/Library/GoldenGate",
              appDir: env["GG_APP_DIR"] ?? "/Library/GoldenGate/app",
              sharedDir: env["GG_ROOT"] ?? "/Users/Shared/GoldenGate")
    }
}

/// Arm GGGlass for WindowServer only when the dylib really exists (if missing, dyld kills WindowServer) and there is no
/// kill-switch (set by the user, or created by the GGGlass crash guard).
func glassAllowed(_ p: Paths, exists: (String) -> Bool) -> Bool {
    exists(p.glassDylib) && !exists(p.disable)
}

/// Set the user variable only when the loader and GGApp.dylib really exist (without the loader no app of the user can launch).
func appAllowed(_ p: Paths, exists: (String) -> Bool) -> Bool {
    exists(p.loader) && exists(p.appDylib)
}

/// The daemon starts about 5 s after WindowServer: if still at the login window, restart WindowServer once so the new
/// launch loads GGGlass. Not when someone is already logged in (that would log them out).
func restartAtBoot(windowServerRunning: Bool, glassAllowed: Bool, consoleUser: String) -> Bool {
    windowServerRunning && glassAllowed && consoleUser == "root"
}

/// uid to set the variable for when the console switches to this user: regular users only. While WindowServer restarts,
/// the console briefly belongs to _windowserver (uid 88).
func envTarget(consoleUser: String, uid: UInt32?) -> UInt32? {
    guard let uid, uid >= 501, !["", "root", "_windowserver", "loginwindow"].contains(consoleUser) else { return nil }
    return uid
}

/// New DYLD_INSERT_LIBRARIES value: keep other entries in order, loader last, no duplicates (like ggapp session-on).
func mergedInsertLibraries(current: String?, loader: String) -> String {
    let others = (current ?? "").split(separator: ":").map(String.init).filter { $0 != loader }
    return (others + [loader]).joined(separator: ":")
}

struct LoginItem: Equatable {
    let pid: Int32
    let path: String
}

/// Login items that started before the agent, read from `lsappinfo list`: apps with UI (Foreground/UIElement), not nested
/// in another app, outside /System/Library (Mail in /System/Applications still counts), checked in to LaunchServices less
/// than 1 minute ago (running it by hand while using the machine leaves open apps alone).
func loginItems(lsappinfo: String) -> [LoginItem] {
    var items: [LoginItem] = []
    var path = "", pid: Int32 = 0, ui = false
    for line in lsappinfo.split(whereSeparator: \.isNewline).map(String.init) {
        if let r = line.range(of: "bundle path=\"") {
            path = String(line[r.upperBound...].prefix { $0 != "\"" })
        } else if let r = line.range(of: "pid = ") {
            pid = Int32(line[r.upperBound...].prefix { $0.isNumber }) ?? 0
            ui = line.contains("type=\"Foreground\"") || line.contains("type=\"UIElement\"")
        } else if line.contains("checkin time") {
            let recent = line.range(of: #"\( [0-9.]+ seconds ago \)"#, options: .regularExpression) != nil
            let nested = path.dropLast(4).contains(".app/")
            if ui, pid > 0, recent, path.hasSuffix(".app"), !nested, !path.hasPrefix("/System/Library/") {
                items.append(LoginItem(pid: pid, path: path))
            }
            ui = false
        }
    }
    return items
}

/// System UI processes that start before the agent; launchd relaunches them when they exit.
let systemUIProcesses = ["Dock", "ControlCenter", "NotificationCenter", "SystemUIServer", "Spotlight", "Finder"]

/// Whether `lsof -p <pid> -Fn` output includes the loader.
func hasLoader(lsofOutput: String, loader: String) -> Bool {
    lsofOutput.split(whereSeparator: \.isNewline).contains { $0 == "n" + loader }
}
