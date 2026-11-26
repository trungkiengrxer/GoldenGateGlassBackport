// Camera / microphone / screen recording / Voice Memos activity for the island (RE-27-BEHAVIOR s22). 27.3 gets these
// as Live Activities; 26.6 has none, so they are read from SystemStatus.framework's media domain (the data behind the
// menu-bar recording indicators). ControlCenter 26.6 holds com.apple.systemstatus.domains = [media] [V]; a process
// without it gets no data.
import Foundation
import notify
import os

enum MediaActivity: Hashable {
    case screenRecording, voiceMemos, av(AVActivityIcon)
}

/// Bundle ids of the attributed apps per kind -> the activities, screen recording > Voice Memos > AV module [I order].
/// Camera and mic of other apps make one AV module (camera icon wins).
func mediaActivities(camera: [String], mic: [String], screen: [String]) -> [MediaActivity] {
    let vm = "com.apple.VoiceMemos", otherMic = mic.filter { $0 != vm }
    return (screen.contains("com.apple.screencaptureui") ? [.screenRecording] : [])
        + (mic.contains(vm) ? [.voiceMemos] : [])
        + (AVActivityIcon.current(camera: !camera.isEmpty, mic: !otherMic.isEmpty).map { [.av($0)] } ?? [])
}

/// Privacy indicator kinds (the WindowServer dot, RE 22.11): any attributed app, Voice Memos and screen capture included.
func privacyKinds(camera: [String], mic: [String], screen: [String], systemAudio: [String]) -> Set<PrivacyIndicatorKind> {
    var k = Set<PrivacyIndicatorKind>()
    if !camera.isEmpty { k.insert(.camera) }
    if !mic.isEmpty { k.insert(.microphone) }
    if !screen.isEmpty { k.insert(.screenRecording) }
    if !systemAudio.isEmpty { k.insert(.systemAudio) }
    return k
}

/// The activity shown alone (highest priority).
func mediaActivity(camera: [String], mic: [String], screen: [String]) -> MediaActivity? {
    mediaActivities(camera: camera, mic: mic, screen: screen).first
}

/// Voice Memos slice levels from GGApp's Voice Memos module (ggapp/Sources/VoiceMemosPack.h): appends the slices newer
/// than lastSeq (lost ones as 0), keeps the newest `keep`; a lower seq is a new recording and starts over.
func voiceMemosLevels(state: UInt64, lastSeq: UInt32?, levels: [Double], keep: Int = 16) -> (seq: UInt32, levels: [Double]) {
    let seq = UInt32(truncatingIfNeeded: state >> 32)
    var out = levels
    let new: Int
    if let last = lastSeq, seq >= last {
        new = Int(seq - last)
    } else {
        out = []
        new = Int(min(seq, 3)) + 1   // slices 0...seq exist
    }
    let packed = (0..<min(new, 4)).reversed().map { Double((state >> (8 * UInt64($0))) & 0xFF) / 255 }   // oldest first
    out += [Double](repeating: 0, count: max(0, new - 4)) + packed
    return (seq, Array(out.suffix(keep)))
}

/// Slice levels GGApp posts from inside Voice Memos (ggapp/Sources/VoiceMemosWaveform.m): one Darwin notify state per
/// 0.125 s slice while recording, read on the main queue.
final class VoiceMemosLevelsMonitor {
    var onChange: (([Double]) -> Void)?
    private(set) var levels: [Double] = []
    private var seq: UInt32?
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    init() {
        notify_register_dispatch("com.goldengate.island.vmlevel", &token, .main) { [weak self] t in
            guard let self else { return }
            var state: UInt64 = 0
            notify_get_state(t, &state)
            (self.seq, self.levels) = voiceMemosLevels(state: state, lastSeq: self.seq, levels: self.levels)
            self.onChange?(self.levels)
        }
    }

    /// A new recording starts from an empty waveform.
    func reset() {
        seq = nil
        levels = []
    }

    deinit { notify_cancel(token) }
}

/// Split (mitosis, RE 22.8): the first two elements as (primary, adjunct), only when both have a minimal view.
func splitPair<T>(_ elements: [T], hasMinimal: (T) -> Bool) -> (T, T)? {
    guard elements.count >= 2, hasMinimal(elements[0]), hasMinimal(elements[1]) else { return nil }
    return (elements[0], elements[1])
}

/// Calls onChange on the main queue with the current activities (empty when none). Private API reached through the ObjC
/// runtime; every selector is checked with responds(to:) first so a renamed key cannot raise inside ControlCenter.
final class MediaStatusMonitor {
    var onChange: (([MediaActivity], Set<PrivacyIndicatorKind>) -> Void)?
    private let domain: NSObject
    private let log = Logger(subsystem: "com.goldengate.island", category: "media")
    private var lastSummary = ""

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/SystemStatus.framework/SystemStatus", RTLD_LAZY) != nil,
              let cls = NSClassFromString("STMediaStatusDomain") as? NSObject.Type else { return nil }
        domain = cls.init()
        let observe = NSSelectorFromString("observeDataWithBlock:")
        guard domain.responds(to: observe) else { return nil }
        let block: @convention(block) (AnyObject?) -> Void = { [weak self] data in
            DispatchQueue.main.async { self?.update(data) }
        }
        domain.perform(observe, with: unsafeBitCast(block, to: AnyObject.self))
        if domain.responds(to: NSSelectorFromString("data")) { update(domain.value(forKey: "data") as AnyObject?) }
    }

    private func update(_ data: AnyObject?) {
        let camera = Self.bundleIDs(data, "cameraAttributions"), mic = Self.bundleIDs(data, "microphoneAttributions")
        let screen = Self.bundleIDs(data, "screenCaptureAttributions"), audio = Self.bundleIDs(data, "systemAudioRecordingAttributions")
        // Every change (26.6 Voice Memos recording seen 2026-11-23: mic=["com.apple.VoiceMemos"] for the 6 s of recording).
        let summary = "camera=\(camera) mic=\(mic) screen=\(screen) audio=\(audio)"
        if summary != lastSummary {
            lastSummary = summary
            log.notice("media status \(summary, privacy: .public)")
        }
        // 27.3 builds the AV module for mic only with mic modes (AudioVideoController.AppInfo, sub_10036e1c0); CoreSpeech
        // (Siri, dictation) gets the dot alone (RE 22.15). ponytail: [I] 26.6 has no per-app mic modes, apps only stands in.
        let micApps = Self.bundleIDs(data, "microphoneAttributions", appsOnly: true)
        onChange?(mediaActivities(camera: camera, mic: micApps, screen: screen),
                  privacyKinds(camera: camera, mic: mic, screen: screen, systemAudio: audio))
    }

    /// data.<key> is a collection of attributions; each -> activityAttribution -> attributedEntity -> bundleIdentifier.
    /// appsOnly keeps entities whose bundlePath is an .app.
    private static func bundleIDs(_ data: AnyObject?, _ key: String, appsOnly: Bool = false) -> [String] {
        guard let d = data as? NSObject, d.responds(to: NSSelectorFromString(key)) else { return [] }
        let v = d.value(forKey: key)
        let items = (v as? NSArray as? [NSObject]) ?? ((v as? NSSet)?.allObjects as? [NSObject]) ?? []
        return items.compactMap { a in
            let entity = get(get(a, "activityAttribution") ?? a, "attributedEntity")
            if appsOnly, (get(entity, "bundlePath") as? String)?.hasSuffix(".app") != true { return nil }
            return get(entity, "bundleIdentifier") as? String
        }
    }

    private static func get(_ o: NSObject?, _ key: String) -> NSObject? {
        guard let o, o.responds(to: NSSelectorFromString(key)) else { return nil }
        return o.value(forKey: key) as? NSObject
    }
}
