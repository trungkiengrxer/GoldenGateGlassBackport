// Shared by daemon and agent: run external commands, write logs, look up processes.
import Foundation

let environment = ProcessInfo.processInfo.environment
let launchctl = environment["LAUNCHCTL"] ?? "/bin/launchctl"   // LAUNCHCTL, KILLALL: fake commands for tests
let killallTool = environment["KILLALL"] ?? "/usr/bin/killall"

/// Run a command, return the exit status and stdout (read fully before waiting, so large output like lsappinfo does not
/// block the pipe).
@discardableResult
func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Append a `yyyy-MM-dd HH:mm:ss.SSS <text>` line to the log file (creating the directory if missing).
func logLine(_ file: String, _ text: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "\(f.string(from: Date())) \(text)\n"
    try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let h = FileHandle(forWritingAtPath: file) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        FileManager.default.createFile(atPath: file, contents: Data(line.utf8))
    }
}

func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

/// pids of processes whose name (p_comm) is exactly `name`; when `uid` is non-nil, only that user's. Uses sysctl
/// KERN_PROC_ALL (proc_pidinfo cannot read other users' processes without root, e.g. WindowServer owned by _windowserver).
func pids(named name: String, uid: uid_t? = nil) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
    return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { p in
        let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard comm == name, uid == nil || p.kp_eproc.e_ucred.cr_uid == uid! else { return nil }
        return p.kp_proc.p_pid
    }
}
