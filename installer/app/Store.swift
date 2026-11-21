// State and actions of the management app (machine checks, GGApp.* keys, kill-switch, guard, uninstall).
// The pure parts (effect list, log parsing, machine check codes) live in Model.swift, which is tested.
import AppKit
import Observation

@Observable @MainActor
final class Store {
    static let sharedDir = "/Users/Shared/GoldenGate"
    static let disableFile = sharedDir + "/disable"
    static let glassLog = "/Library/Logs/WindowServer/GoldenGate/ggglass.log"
    static let bootsFile = "/Library/Logs/WindowServer/GoldenGate/boots.plist"
    static let loader = "/Library/GoldenGate/app/GGAppLoader.dylib"
    static let logsDir = NSHomeDirectory() + "/Library/Logs/GoldenGate"

    var problem: String?       // nil: machine meets the requirements
    var daemonRunning = false
    var agentRunning = false
    var glassActive = false    // the current WindowServer has loaded GGGlass
    var sessionOn = false
    var glassOff = false
    var appOff = false
    var values: [String: Bool] = [:]
    var excluded: [String] = []
    var glassChanged = false   // GGGlass kill-switch changed during this app run: WindowServer restart needed

    var everythingOff: Bool { glassOff && appOff }

    func refresh() {
        let check = Bundle.main.path(forResource: "check", ofType: "sh") ?? ""
        problem = machineProblem(checkExitCode: run("/bin/zsh", [check]).status)
        daemonRunning = run("/bin/launchctl", ["print", "system/com.goldengateglass.daemon"]).status == 0
        agentRunning = run("/bin/launchctl", ["print", "gui/\(getuid())/com.goldengateglass.agent"]).status == 0
        let ws = Int32(run("/usr/bin/pgrep", ["-x", "WindowServer"]).out.split(separator: "\n").first ?? "") ?? 0
        glassActive = ws > 0 && glassLoaded(log: tail(Self.glassLog, bytes: 256 * 1024), windowServerPID: ws)
        sessionOn = run("/bin/launchctl", ["getenv", "DYLD_INSERT_LIBRARIES"]).out.contains(Self.loader)
        glassOff = FileManager.default.fileExists(atPath: Self.disableFile)
        appOff = pref("GGApp.disable") ?? false
        values = Dictionary(uniqueKeysWithValues: effects.map { ($0.key, pref("GGApp." + $0.key) ?? $0.defaultOn) })
        excluded = excludedBundleIDs(guardDirs: guardDirs()) {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
    }

    func set(_ key: String, _ on: Bool) {
        setPref("GGApp." + key, on)
        values[key] = on
    }

    func turnOff() {
        FileManager.default.createFile(atPath: Self.disableFile, contents: nil)
        setPref("GGApp.disable", true)
        glassChanged = true
        refresh()
    }

    /// Like `ggglass on` + `ggapp on`: remove the kill-switch and the crash guard history of GGGlass and of apps.
    func turnOn() {
        for f in [Self.disableFile, Self.bootsFile, Self.logsDir + "/guard"] { try? FileManager.default.removeItem(atPath: f) }
        setPref("GGApp.disable", nil)
        glassChanged = true
        refresh()
    }

    func allowAgain(_ bundleID: String) {
        for dir in guardDirs() {
            for ext in ["excluded", "crashes"] { try? FileManager.default.removeItem(atPath: "\(dir)/\(bundleID).\(ext)") }
        }
        refresh()
    }

    func openLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: Self.logsDir)) }

    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Golden Gate Glass?"
        alert.informativeText = "This removes the background helpers and this app. Remaining files are removed the next time you restart your Mac."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, let script = Bundle.main.path(forResource: "uninstall", ofType: "sh") else { return }
        var error: NSDictionary?
        let source = "do shell script \"/bin/zsh \" & quoted form of \"\(script)\" with administrator privileges"
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        let done = NSAlert()
        if let error {
            done.messageText = "Uninstall did not finish"
            done.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Unknown error."
        } else {
            done.messageText = "Restart your Mac to finish uninstalling."
        }
        done.runModal()
        if error == nil { NSApp.terminate(nil) }
    }

    // MARK: - Helpers

    private func guardDirs() -> [String] {
        let containers = NSHomeDirectory() + "/Library/Containers"
        let inContainers = ((try? FileManager.default.contentsOfDirectory(atPath: containers)) ?? [])
            .map { "\(containers)/\($0)/Data/Library/Logs/GoldenGate/guard" }
        return [Self.logsDir + "/guard"] + inContainers
    }

    /// Key in the current user's global domain (like `defaults write -g`).
    private func pref(_ key: String) -> Bool? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
    }

    private func setPref(_ key: String, _ value: Bool?) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func tail(_ path: String, bytes: Int) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let end = h.seekToEndOfFile()
        h.seek(toFileOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
