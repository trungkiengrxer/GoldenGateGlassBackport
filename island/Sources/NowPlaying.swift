// Now Playing data for the island (M4): MediaRemote on 26.6 (loaded with dlsym, event-driven) and when the island
// shows it. 27.3 behaviour and layout: docs/RE-27-NOWPLAYING.md. [I] = inferred, [?] = placeholder.
import AppKit

/// One MediaRemote now-playing snapshot. Elapsed time is interpolated from (elapsed, rate, timestamp), never polled.
struct NowPlayingInfo: Equatable {
    var title: String?
    var artist: String?
    var duration: Double?
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var artwork: Data?

    /// kMRMediaRemoteNowPlayingInfo* keys (the CFString values equal the symbol names). nil without title and artist.
    init?(mediaRemote d: [String: Any], now: Date = Date()) {
        func value<T>(_ k: String) -> T? { d["kMRMediaRemoteNowPlayingInfo" + k] as? T }
        let title: String? = value("Title"), artist: String? = value("Artist")
        guard title != nil || artist != nil else { return nil }
        self.init(title: title, artist: artist, duration: value("Duration"), elapsed: value("ElapsedTime") ?? 0,
                  rate: value("PlaybackRate") ?? 0, timestamp: value("Timestamp") ?? now, artwork: value("ArtworkData"))
    }

    init(title: String?, artist: String?, duration: Double?, elapsed: Double, rate: Double, timestamp: Date, artwork: Data?) {
        self.title = title; self.artist = artist; self.duration = duration
        self.elapsed = elapsed; self.rate = rate; self.timestamp = timestamp; self.artwork = artwork
    }

    func elapsed(at date: Date) -> Double {
        let e = max(elapsed + rate * date.timeIntervalSince(timestamp), 0)
        return duration.map { min(e, $0) } ?? e
    }

    func progress(at date: Date) -> Double {
        guard let d = duration, d > 0 else { return 0 }
        return elapsed(at: date) / d
    }

    /// AVTimeFormatter style used by the 27.3 timeline labels: m:ss, h:mm:ss, U+2212 for remaining time (the dash is
    /// 5.6 pt wide at caption2 in drlYGnbWurM 775.9 s; a hyphen is about 3).
    static func label(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded(.down)), sign = seconds < 0 ? "\u{2212}" : ""
        return s >= 3600 ? String(format: "%@%d:%02d:%02d", sign, s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%@%d:%02d", sign, s / 60, s % 60)
    }
}

/// When the island shows Now Playing: compact while playing, expanded on click, hidden a while after pausing.
struct NowPlayingPresence {
    enum Mode: Equatable { case compact, expanded }

    // User setting (2026-11-26): keep a paused track 10 minutes. 27.3 _delayedHideTask duration not read [?]; the
    // MenuBarAgent standard timeout (4 s) was used before.
    static let pausedHideDelay = 600.0

    private(set) var mode: Mode?
    private var pausedAt: Double?

    /// Time at which tick() hides the island, if any (expanded never auto-hides).
    var deadline: Double? { mode == .compact ? pausedAt.map { $0 + Self.pausedHideDelay } : nil }

    mutating func update(hasTrack: Bool, isPlaying: Bool, now: Double) {
        guard hasTrack else { mode = nil; pausedAt = nil; return }
        if isPlaying {
            pausedAt = nil
            if mode == nil { mode = .compact }
        } else if mode != nil, pausedAt == nil {
            pausedAt = now
        }
    }

    mutating func tick(now: Double) {
        guard let d = deadline, now >= d else { return }
        mode = nil
        pausedAt = nil
    }

    mutating func toggleExpanded() {
        guard let m = mode else { return }
        mode = m == .compact ? .expanded : .compact
    }
}

enum NowPlayingCommand: UInt32 { case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5 }   // MRCommand

/// MediaRemote.framework entry points, resolved once. nil when the framework or a symbol is missing.
final class MediaRemote {
    static let shared = MediaRemote()

    typealias Register = @convention(c) (DispatchQueue) -> Void
    typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (DarwinBoolean) -> Void) -> Void
    typealias GetPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    typealias Send = @convention(c) (UInt32, CFDictionary?) -> DarwinBoolean
    typealias SetElapsed = @convention(c) (Double) -> Void

    let register: Register, getInfo: GetInfo, getPlaying: GetPlaying, getPID: GetPID, send: Send
    let setElapsedTime: SetElapsed?   // optional: Now Playing still works without seeking
    let notifications: [Notification.Name]

    private init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else { return nil }
        func fn<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        func name(_ n: String) -> Notification.Name? {
            dlsym(h, n).map { Notification.Name($0.assumingMemoryBound(to: CFString.self).pointee as String) }
        }
        guard let r = fn("MRMediaRemoteRegisterForNowPlayingNotifications", Register.self),
              let i = fn("MRMediaRemoteGetNowPlayingInfo", GetInfo.self),
              let p = fn("MRMediaRemoteGetNowPlayingApplicationIsPlaying", GetPlaying.self),
              let d = fn("MRMediaRemoteGetNowPlayingApplicationPID", GetPID.self),
              let s = fn("MRMediaRemoteSendCommand", Send.self),
              let n1 = name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
              let n2 = name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
              let n3 = name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification") else { return nil }
        register = r; getInfo = i; getPlaying = p; getPID = d; send = s
        setElapsedTime = fn("MRMediaRemoteSetElapsedTime", SetElapsed.self)
        notifications = [n1, n2, n3]
    }
}

/// Event-driven Now Playing state from MediaRemote: refreshes on its notifications only. Main queue.
final class NowPlayingSource {
    struct State: Equatable {
        var info: NowPlayingInfo?
        var isPlaying = false
        var bundleID: String?
    }

    private(set) var state = State()
    var onChange: ((State) -> Void)?
    private let mr: MediaRemote
    private var observers: [NSObjectProtocol] = []

    init?() {
        guard let mr = MediaRemote.shared else { return nil }
        self.mr = mr
        mr.register(.main)
        observers = mr.notifications.map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func refresh() {
        mr.getInfo(.main) { [weak self] d in
            guard let self else { return }
            var info = (d as? [String: Any]).flatMap { NowPlayingInfo(mediaRemote: $0) }
            // Artwork often arrives in a later notification than the text: keep it for the same track.
            if let old = self.state.info, info?.artwork == nil, info?.title == old.title, info?.artist == old.artist {
                info?.artwork = old.artwork
            }
            self.mr.getPlaying(.main) { playing in
                self.mr.getPID(.main) { pid in
                    let bundle = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
                    let s = State(info: info, isPlaying: playing.boolValue, bundleID: bundle)
                    guard s != self.state else { return }
                    self.state = s
                    self.onChange?(s)
                }
            }
        }
    }

    @discardableResult
    func send(_ c: NowPlayingCommand) -> Bool { mr.send(c.rawValue, nil).boolValue }

    /// MRMediaRemoteSetElapsedTime (27.3 TimelineControlAction.seek(to:)). False when the symbol is missing.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard let set = mr.setElapsedTime else { return false }
        set(seconds)
        return true
    }
}
