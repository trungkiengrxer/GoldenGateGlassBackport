// M3 island host inside ControlCenter: wires bridge events (OSDBridge.m) to IslandController, the panel and the
// content views, and slider drags to the system volume / brightness. Started by the bridge constructor on the main
// queue; only in ControlCenter (or with GG_ISLAND_FORCE_UI) so test binaries never open a window.
import AppKit
import QuartzCore
import SwiftUI
import notify
import os

private typealias SinkFn = @convention(c) (NSString, NSArray) -> Void
private typealias ForwardFn = @convention(c) (NSString, NSArray) -> ObjCBool
private typealias SuppressFn = @convention(c) () -> ObjCBool

/// Address of a C global exported by this image (bridge side), or nil.
private func global<T>(_ name: String, _: T.Type) -> UnsafeMutablePointer<T>? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { $0.assumingMemoryBound(to: T.self) }
}

private let log = Logger(subsystem: "com.goldengate.island", category: "host")
private var previousSink: SinkFn?

@_cdecl("gg_island_start")
public func ggIslandStart() {
    let env = ProcessInfo.processInfo.environment
    guard Bundle.main.bundleIdentifier == "com.apple.controlcenter" || env["GG_ISLAND_FORCE_UI"] != nil else { return }
    guard let screen = NSScreen.main, let sink = global("gg_island_osd_sink", SinkFn?.self),
          let forward = global("gg_island_should_forward", ForwardFn?.self),
          let suppress = global("gg_island_suppress_banner", SuppressFn?.self) else {
        log.error("island host not started (no screen or bridge symbols): 26.6 presentation kept")
        return
    }
    IslandHost.shared = IslandHost(screen: screen)
    previousSink = sink.pointee
    sink.pointee = { e, a in
        previousSink?(e, a)
        let event = e as String, args = a as? [Any] ?? []
        DispatchQueue.main.async { IslandHost.shared?.receive(event, args) }
    }
    // Called on the bridge's XPC thread: decide from the event alone (pure parse), present on the main queue.
    forward.pointee = { e, a in
        if case .level? = parseOSD(e as String, a as? [Any] ?? []) { return false }
        return true
    }
    suppress.pointee = { ObjCBool(IslandHost.shared?.suppressesBanner() ?? false) }
    // Debug harness: `notifyutil -p com.goldengate.island.debug` runs the commands in /tmp/gg-island-debug/cmd
    // (see IslandHost.runDebugScript). Lets the island be driven and photographed from inside ControlCenter, which
    // holds kTCCServiceScreenCapture, without user input.
    var token: Int32 = 0
    notify_register_dispatch("com.goldengate.island.debug", &token, .main) { _ in IslandHost.shared?.runDebugScript() }
    log.info("island host started")
}

enum PassiveElement: Equatable { case airDrop, media(MediaActivity), nowPlaying }

/// RE 22.20: a click (or long press) on either split container requests that element's expansion (expandRequested ->
/// prominence userExpanded); it becomes the primary expanded in place, the other recombines into it. The AV module has
/// no expanded view yet, so a click on it does nothing.
func splitExpansionTarget(onAdjunct: Bool, primary: PassiveElement, adjunct: PassiveElement) -> PassiveElement? {
    let e = onAdjunct ? adjunct : primary
    if case .media(.av) = e { return nil }
    return e
}

/// RE 22.25 (3): while the primary is expanded only consequential elements (AirDropUI, screencaptureui in the static
/// ElementBundlePolicy table 0x1006d98f8) and the AV module (avModuleAnchored, 0x1000d9c88) stay beside it as the adjunct;
/// the rest (Now Playing systemExperience, Voice Memos ordinary) recombine into the body (footage 5c.1 vs 5c.3).
func adjunctBesideExpanded(_ e: PassiveElement) -> Bool {
    switch e {
    case .airDrop, .media(.screenRecording), .media(.av): return true
    case .media(.voiceMemos), .nowPlaying: return false
    }
}

/// The adjunct beside an expanded element: the first other present element that qualifies, however the body was
/// expanded (a tap on the split, or an element arriving while expanded: hidden -> visible = mitosis, RE 22.25 (2)).
/// ponytail: first in passive order stands in for 27.3's RankKey among qualifying elements [I].
func adjunctBesideExpanded(expanded: PassiveElement, elements: [PassiveElement]) -> PassiveElement? {
    elements.first { $0 != expanded && adjunctBesideExpanded($0) }
}

/// The element the user expanded, while it is still present; it outranks the split (RE 22.20).
func userExpandedElement(airDrop: Bool, airDropExpanded: Bool, media: [MediaActivity], mediaExpanded: MediaActivity?,
                         nowPlayingExpanded: Bool) -> PassiveElement? {
    if airDrop && airDropExpanded { return .airDrop }
    if let m = mediaExpanded, media.contains(m) { return .media(m) }
    return nowPlayingExpanded ? .nowPlaying : nil
}

final class IslandHost {
    static var shared: IslandHost?

    /// What the panel currently shows: a momentary banner (volume/brightness/Focus) or Now Playing.
    private enum Shown: Equatable { case none, momentary(Presentation), nowPlaying(NowPlayingPresence.Mode), airDrop,
                                       airDropExpanded, airDropReady, media(MediaActivity), mediaExpanded(MediaActivity),
                                       split(Passive, Passive) }
    private typealias Passive = PassiveElement

    let panel: IslandPanel
    private var controller = IslandController()
    private var shown = Shown.none
    private var slider: SliderModel?
    private var work: DispatchWorkItem?
    private var collapse: DispatchWorkItem?
    private var hovering = false
    // M4 Now Playing (NowPlaying.swift / NowPlayingViews.swift): passive, shown when no momentary banner is up
    // (27.3 RankKey: alerting/system banners rank above passive elements).
    private let source = NowPlayingSource()
    private let nowPlaying = NowPlayingModel()
    private var presence = NowPlayingPresence()
    // AirDrop receive (AirDrop.swift / AirDropViews.swift): a Live Activity, shown above Now Playing.
    private let airDropMonitor = AirDropMonitor()
    private var airDrop: AirDropProgress?
    private var airDropTrailing: NSHostingView<AirDropCompactTrailing>?
    private var airDropLeading: NSView?   // drag points arrive in this view's coordinates (first content view)
    private var airDropExpandedView: NSHostingView<AirDropExpandedProgress>?
    private var airDropExpanded = false   // the user clicked the compact activity
    private var airDropReadySize = CGSize.zero
    private var airDropClear: DispatchWorkItem?
    // Screen recording / Voice Memos / camera-mic (MediaStatus.swift / SystemActivities.swift): passive, below AirDrop,
    // above Now Playing [I order].
    private let mediaMonitor = MediaStatusMonitor()
    private var media: [MediaActivity] = []
    private var voiceMemosTrailing: NSHostingView<VoiceMemosCompactTrailing>?
    private let voiceMemosLevels = VoiceMemosLevelsMonitor()   // slices from GGApp inside Voice Memos (RE 22.22)
    private var voiceMemosLeading: NSHostingView<VoiceMemosCompactLeading>?
    private var voiceMemosMinimal: NSHostingView<VoiceMemosMinimal>?
    private var voiceMemosTimer: Timer?
    private var voiceMemosStart: Date?
    private var voiceMemosExpandedView: NSHostingView<VoiceMemosExpanded>?
    private var recordingStart: Date?   // screen recording first seen [I: screencaptureui's own start time is not read]
    private var recordingExpandedView: NSHostingView<ScreenRecordingExpanded>?
    private var mediaExpanded: MediaActivity?   // clicked to expand: screen recording / Voice Memos (compact or split)
    private var lastPrimary: Passive?   // primary passive element last shown (throughInert)
    private var splitViews: (primary: NSView, adjunct: NSView)?
    private var shownExpandedAdjunct: Passive?
    private var nowPlayingExpandedView: NSView?   // drag points arrive in primary's coordinates
    private var pendingThrough: Bool?       // throughInert for the next passive show, set by the transition that knows it

    init(screen: NSScreen) {
        panel = IslandPanel(screen: screen)
        panel.orderFrontRegardless()
        panel.onHover = { [weak self] in self?.hover($0) }
        panel.onDrag = { [weak self] in self?.drag($0, $1) }
        if source == nil { log.error("MediaRemote unavailable: Now Playing disabled") }
        source?.onChange = { [weak self] state in
            guard let self else { return }
            self.nowPlaying.update(state)
            self.presence.update(hasTrack: state.info != nil, isPlaying: state.isPlaying, now: self.now)
            self.render()
        }
        source?.refresh()
        voiceMemosLevels.onChange = { [weak self] levels in
            guard let self else { return }
            let h = self.panel.geometry.sensor.height
            self.voiceMemosLeading?.rootView = VoiceMemosCompactLeading(levels: levels, sensorHeight: h)
            self.voiceMemosMinimal?.rootView = VoiceMemosMinimal(levels: levels)
            self.voiceMemosExpandedView?.rootView = VoiceMemosExpanded(levels: levels, seconds: self.voiceMemosSeconds)
        }
        PowerSource.observe { [weak self] in self?.powerChanged() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.powerChanged()
        }
        powerChanged()   // first reading: baseline only, no banner
        airDropMonitor?.onChange = { [weak self] in self?.airDropChanged($0) }
        if mediaMonitor == nil { log.error("SystemStatus media domain unavailable: recording indicators disabled") }
        mediaMonitor?.onChange = { [weak self] activities, dots in
            self?.panel.setPrivacyIndicators(dots)
            self?.mediaChanged(activities)
        }
        DispatchQueue.main.async { [weak self] in self?.prewarm() }
    }

    private func powerChanged() {
        guard let r = PowerSource.read() else { return }
        _ = controller.handle(.power(level: r.level, isCharging: r.isCharging, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled), now: now)
        render()
    }

    // ponytail: [I] done stays compact 4 s; 27.3 expands with Open (ModernReadyForOpenView), not built yet.
    private func airDropChanged(_ p: AirDropProgress?) {
        airDropClear?.cancel()
        if (airDrop == nil) != (p == nil) || p?.isFinished == true {
            log.notice("AirDrop \(p == nil ? "ended" : p!.isFinished ? "finished" : "started", privacy: .public)")
        }
        airDrop = p
        if p == nil { airDropExpanded = false }
        if p?.isFinished == true {
            let c = DispatchWorkItem { [weak self] in self?.airDrop = nil; self?.render() }
            airDropClear = c
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandController.bannerDuration, execute: c)
        }
        render()
    }

    /// Compact AirDrop; progress updates go to the same trailing view (no re-presentation).
    /// RE s21.3: compact while transferring; finished -> prominent expanded ReadyForOpen; a click on the compact shows the
    /// expanded ProgressView. Progress updates go to the same hosted view (no re-presentation).
    private func renderAirDrop(_ a: AirDropProgress) {
        slider = nil
        if a.isFinished {
            guard shown != .airDropReady else { return }
            let text = airDropReadyText(fileName: airDropMonitor?.lastFile?.lastPathComponent, sender: nil, language: BannerMetrics.language)
            let size = MainActor.assumeIsolated { AirDropMetrics.expandedReadyForOpenSize(title: text.title, subtitle: text.subtitle) }
            airDropReadySize = size
            showPassive(.expanded(hosted(AirDropExpandedReadyForOpen(title: text.title, subtitle: text.subtitle, onOpen: { [weak self] in self?.openAirDropFile() }),
                                         size: size), size: size, type: nil, shape: .liveActivity), primary: .airDrop)
            shown = .airDropReady
            return
        }
        if airDropExpanded {
            // RE s21.2.1: without sharingd's progress string the subtitle is "From %@" with the default sender.
            let from = airDropReadyText(fileName: nil, sender: nil, language: BannerMetrics.language).subtitle
            if shown == .airDropExpanded, !expandedAdjunctChanged(beside: .airDrop), let v = airDropExpandedView { v.rootView = AirDropExpandedProgress(progress: a, subtitle: from); return }
            let size = MainActor.assumeIsolated { AirDropMetrics.expandedProgressSize(progress: a, subtitle: from) }   // main queue
            // Only the adjunct changed: keep the same content view so the body stays steady (mitosis / recombination only).
            let v = (shown == .airDropExpanded ? airDropExpandedView : nil) ?? NSHostingView(rootView: AirDropExpandedProgress(progress: a, subtitle: from))
            v.rootView = AirDropExpandedProgress(progress: a, subtitle: from)
            v.frame = CGRect(origin: .zero, size: size)
            airDropExpandedView = v
            showPassive(.expanded(v, size: size, type: nil, shape: .liveActivity, adjunct: expandedAdjunctView(beside: .airDrop)), primary: .airDrop)
            shown = .airDropExpanded
            return
        }
        if shown == .airDrop, let t = airDropTrailing { t.rootView = AirDropCompactTrailing(progress: a); return }
        let h = panel.geometry.sensor.height
        let t = NSHostingView(rootView: AirDropCompactTrailing(progress: a))
        t.frame = CGRect(origin: .zero, size: AirDropMetrics.compactTrailingSize(sensorHeight: h))
        airDropTrailing = t
        let l = hosted(AirDropCompactLeading(), size: AirDropMetrics.compactLeadingSize(sensorHeight: h))
        airDropLeading = l
        showPassive(.compact(leading: l, trailing: t), primary: .airDrop)
        shown = .airDrop
    }

    /// screencaptureui 26.6 stops on its documented shortcut Command-Control-Esc (string " to stop screen recording", RE 22.10).
    private func stopScreenRecording() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)   // kVK_Escape
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
    }

    private func openAirDropFile() {
        guard let url = airDropMonitor?.lastFile else { return }
        NSWorkspace.shared.open(url)
        airDropChanged(nil)
    }

    /// Low battery banner button; the resulting NSProcessInfoPowerStateDidChange re-presents the banner.
    private func toggleLowPowerMode() {
        if !PowerSource.setLowPowerMode(!ProcessInfo.processInfo.isLowPowerModeEnabled) { log.error("IOPMSetEnergyModePreference failed") }
    }

    /// The first NSHostingView/SwiftUI build blocks the main thread ~175 ms (measured by island-ui-exact with
    /// `IslandDemo arrival`), which delays the first presentation. Build and render each content view once off-screen
    /// at launch so real presentations start warm.
    private func prewarm() {
        let h = panel.geometry.sensor.height
        let views: [NSView] = [
            hosted(SliderView(model: SliderModel(kind: .volume, value: 0.5)), size: SliderMetrics.size(inflated: false)),
            hosted(FocusLeading(activity: FocusActivity(identifier: "", name: "Focus", symbol: "moon.fill", colorName: "systemIndigoColor")),
                   size: CGSize(width: FocusMetrics.leadingWidth, height: h)),
            hosted(NowPlayingCompactLeading(model: nowPlaying, sensorHeight: h), size: NowPlayingMetrics.compactLeadingSize(sensorHeight: h)),
            hosted(NowPlayingExpanded(model: nowPlaying),
                   size: CGSize(width: NowPlayingMetrics.expandedWidth, height: NowPlayingMetrics.expandedHeight)),
        ]
        for v in views {
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep) }
        }
    }

    private var now: Double { CACurrentMediaTime() }

    func suppressesBanner() -> Bool { controller.suppressesBanner(now: now) }

    func receive(_ event: String, _ args: [Any]) {
        guard let e = parseOSD(event, args) else { return }
        _ = controller.handle(e, now: now)
        render()
    }

    private func render() {
        guard let p = controller.presentation else {
            // A finished AirDrop takes the island as the prominent ReadyForOpen (RE s21.3), never split. An element the
            // user expanded outranks the split (RE 22.20).
            let expanded = userExpandedElement(airDrop: airDrop != nil, airDropExpanded: airDropExpanded, media: media,
                                               mediaExpanded: mediaExpanded, nowPlayingExpanded: presence.mode == .expanded)
            if let a = airDrop, a.isFinished || expanded == .airDrop {
                renderAirDrop(a)
            } else if case let .media(m)? = expanded {
                renderMedia(m)
            } else if expanded == .nowPlaying {
                renderNowPlaying()
            } else if let (p, a) = splitPair(passiveElements, hasMinimal: { _ in true }) {
                renderSplit(p, a)
            } else {
                // 2 -> 1 (an element ended): merge through the neutral pill [I: iOS 0qW-LOgZU44-178, no Mac footage].
                if case .split = shown { pendingThrough = true }
                if let a = airDrop { renderAirDrop(a) } else if let m = media.first { renderMedia(m) } else { renderNowPlaying() }
            }
            schedule()
            return
        }
        switch p {
        case let .level(kind, value):
            if let s = slider, s.kind == kind {
                s.value = value
            } else {
                let s = SliderModel(kind: kind, value: value)
                slider = s
                let size = SliderMetrics.size(inflated: false)
                panel.show(.expanded(hosted(SliderView(model: s), size: size), size: size, type: nil), momentary: true)
            }
        case let .focus(a, isOn):
            if shown != .momentary(p) {
                slider = nil
                let h = panel.geometry.sensor.height
                panel.show(.compact(leading: hosted(FocusLeading(activity: a, isOn: isOn), size: CGSize(width: FocusMetrics.leadingWidth, height: h)),
                                    trailing: hosted(FocusTrailing(activity: a, isOn: isOn), size: CGSize(width: FocusMetrics.trailingWidth(isOn: isOn), height: h))),
                           momentary: true)
            }
        case let .battery(b):
            // ponytail: a level change while shown re-presents (crossfade); at most once per percent inside the 4 s window.
            if shown != .momentary(p) {
                slider = nil
                let h = panel.geometry.sensor.height
                if b.isWarning {
                    let size = BannerMetrics.batteryExpandedSize(hasBottomLine: true)   // warning always has the bottom line
                    panel.show(.expanded(hosted(BatteryWarningExpanded(state: b, onLowPowerMode: { [weak self] in self?.toggleLowPowerMode() }),
                                                size: size), size: size, type: nil), momentary: true)
                } else {
                    panel.show(.compact(leading: hosted(BatteryCompactLeading(state: b), size: BannerMetrics.batteryCompactLeadingSize(b, sensorHeight: h)),
                                        trailing: hosted(BatteryCompactTrailing(state: b), size: BannerMetrics.batteryCompactTrailingSize(b, sensorHeight: h))),
                               momentary: true)
                }
            }
        case let .accessory(i):
            if shown != .momentary(p) {
                slider = nil
                let h = panel.geometry.sensor.height, t = BannerMetrics.accessoryCompactTrailingSize(batteryLevel: i.batteryLevel, sensorHeight: h)
                panel.show(.compact(leading: hosted(AccessoryCompactLeading(info: i), size: BannerMetrics.accessoryCompactLeadingSize(sensorHeight: h)),
                                    trailing: t.width > 0 ? hosted(AccessoryCompactTrailing(info: i), size: t) : nil), momentary: true)
            }
        case let .smartRouting(i):
            if shown != .momentary(p) {
                slider = nil
                let h = panel.geometry.sensor.height, t = BannerMetrics.smartRoutingCompactTrailingSize(batteryLevel: i.batteryLevel, sensorHeight: h)
                panel.show(.compact(leading: hosted(SmartRoutingCompactLeading(info: i), size: BannerMetrics.smartRoutingCompactLeadingSize(sensorHeight: h)),
                                    trailing: t.width > 0 ? hosted(SmartRoutingCompactTrailing(info: i), size: t) : nil), momentary: true)
            }
        }
        shown = .momentary(p)
        schedule()
    }

    /// Voice Memos timer counts from when the recording was first seen [I: the recorder's own elapsed time is not read].
    private func mediaChanged(_ m: [MediaActivity]) {
        guard m != media else { return }
        if let e = mediaExpanded, !m.contains(e) { mediaExpanded = nil }
        if !m.contains(.screenRecording) { recordingStart = nil } else if recordingStart == nil { recordingStart = Date() }
        if !m.contains(.voiceMemos) {
            voiceMemosTimer?.invalidate()
            voiceMemosTimer = nil
            voiceMemosStart = nil
        } else if voiceMemosStart == nil {
            voiceMemosStart = Date()
            voiceMemosLevels.reset()
            voiceMemosTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.voiceMemosTrailing?.rootView = VoiceMemosCompactTrailing(seconds: self.voiceMemosSeconds)
                self.voiceMemosExpandedView?.rootView = VoiceMemosExpanded(levels: self.voiceMemosLevels.levels, seconds: self.voiceMemosSeconds)
            }
        }
        media = m
        render()
    }

    private var voiceMemosSeconds: Int { voiceMemosStart.map { Int(Date().timeIntervalSince($0)) } ?? 0 }

    /// Passive elements in rank order: AirDrop > system activities > Now Playing [I].
    private var passiveElements: [Passive] {
        (airDrop != nil ? [.airDrop] : []) + media.map { .media($0) } + (presence.mode != nil ? [.nowPlaying] : [])
    }

    /// Shows a passive state; another primary element than last time goes through the inert pill (throughInert,
    /// RE 22.9) [I: when 27.3 picks it].
    private func showPassive(_ state: IslandState, primary: Passive?) {
        let through = pendingThrough ?? (lastPrimary != nil && primary != nil && lastPrimary != primary)
        pendingThrough = nil
        lastPrimary = primary
        panel.show(state, throughInert: through)
    }

    private func renderMedia(_ m: MediaActivity) {
        slider = nil
        let h = panel.geometry.sensor.height
        if mediaExpanded == m, m == .screenRecording || m == .voiceMemos {   // RE 22.10; AV expanded not built
            guard shown != .mediaExpanded(m) || expandedAdjunctChanged(beside: .media(m)) else { return }
            let steady = shown == .mediaExpanded(m)   // only the adjunct changed: keep the content view
            if m == .screenRecording {
                let size = ScreenRecordingMetrics.expandedSize(obstruction: h)
                let v = (steady ? recordingExpandedView : nil)
                    ?? NSHostingView(rootView: ScreenRecordingExpanded(startDate: recordingStart ?? Date(), obstructionHeight: h))
                v.frame.size = size
                recordingExpandedView = v
                showPassive(.expanded(v, size: size, type: nil, shape: .liveActivity, adjunct: expandedAdjunctView(beside: .media(m))), primary: .media(m))
            } else {
                let size = VoiceMemosMetrics.expandedSize
                let v = (steady ? voiceMemosExpandedView : nil)
                    ?? NSHostingView(rootView: VoiceMemosExpanded(levels: voiceMemosLevels.levels, seconds: voiceMemosSeconds))
                v.frame.size = size
                voiceMemosExpandedView = v
                showPassive(.expanded(v, size: size, type: nil, shape: .liveActivity, adjunct: expandedAdjunctView(beside: .media(m))), primary: .media(m))
            }
            shown = .mediaExpanded(m)
            return
        }
        voiceMemosExpandedView = nil
        recordingExpandedView = nil
        guard shown != .media(m) else { return }
        switch m {
        case .screenRecording:
            showPassive(.compact(leading: hosted(ScreenRecordingDot(), size: CGSize(width: ScreenRecordingMetrics.frameSize, height: h)),
                                 trailing: nil), primary: .media(m))
        case .voiceMemos:
            let t = NSHostingView(rootView: VoiceMemosCompactTrailing(seconds: voiceMemosSeconds))
            t.frame.size = CGSize(width: t.fittingSize.width, height: h)
            voiceMemosTrailing = t
            let w = VoiceMemosMetrics.waveformWidth(slices: VoiceMemosMetrics.compactSlices)
            let l = NSHostingView(rootView: VoiceMemosCompactLeading(levels: voiceMemosLevels.levels, sensorHeight: h))
            l.frame.size = CGSize(width: w, height: h)
            voiceMemosLeading = l
            showPassive(.compact(leading: l, trailing: t), primary: .media(m))
        case .av:
            showPassive(.minimal(minimalView(m), edge: .trailing), primary: .media(m))   // AV module on the trailing side (RE s22.7)
        }
        shown = .media(m)
    }

    /// Minimal content, frame = content size (split primary <= 45 wide, adjunct; RE 22.8); every passive element has one.
    private func minimalView(_ e: Passive) -> NSView? {
        let h = panel.geometry.sensor.height
        switch e {
        case .airDrop: return hosted(AirDropMinimal(), size: AirDropMetrics.minimalSize(sensorHeight: h))
        case let .media(m): return minimalView(m)
        case .nowPlaying:   // obstruction a minimal scene receives is not read [?]: the sensor's, as compact
            return hosted(NowPlayingMinimal(model: nowPlaying, sensorHeight: h), size: NowPlayingMetrics.minimalSize(sensorHeight: h, obstructed: true))
        }
    }

    /// Minimal of the element shown beside the expanded element (5c.1, RE 22.25).
    private func expandedAdjunctView(beside e: Passive) -> NSView? {
        shownExpandedAdjunct = adjunctBesideExpanded(expanded: e, elements: passiveElements)
        return shownExpandedAdjunct.flatMap(minimalView)
    }

    /// An element arrived or left beside the expanded body: show it again so the adjunct splits off or recombines.
    private func expandedAdjunctChanged(beside e: Passive) -> Bool {
        adjunctBesideExpanded(expanded: e, elements: passiveElements) != shownExpandedAdjunct
    }

    private func minimalView(_ m: MediaActivity) -> NSView {
        switch m {
        case .screenRecording:
            let s = ScreenRecordingMetrics.frameSize
            return hosted(ScreenRecordingDot(), size: CGSize(width: s, height: s))
        case .voiceMemos:
            let v = NSHostingView(rootView: VoiceMemosMinimal(levels: voiceMemosLevels.levels))
            v.frame.size = VoiceMemosMetrics.minimalSize
            voiceMemosMinimal = v
            return v
        case let .av(icon):
            let v = NSHostingView(rootView: AVModuleMinimal(current: icon))
            v.frame.size = v.fittingSize
            return v
        }
    }

    private func renderSplit(_ p: Passive, _ a: Passive) {
        slider = nil
        guard shown != .split(p, a), let pv = minimalView(p), let av = minimalView(a) else { return }
        voiceMemosTrailing = nil
        airDropExpanded = false
        mediaExpanded = nil
        splitViews = (pv, av)
        switch shown {
        case .airDropExpanded, .mediaExpanded, .nowPlaying(.expanded): pendingThrough = false   // collapse: expandedToMinimal, then mitosis (RE 22.20)
        case .split: break
        default: pendingThrough = true   // 1 -> 2: the content clears, then the adjunct buds (5c.2)
        }
        showPassive(.split(primary: pv, adjunct: av), primary: p)
        shown = .split(p, a)
    }

    private func renderNowPlaying() {
        slider = nil
        let want: Shown = presence.mode.map { .nowPlaying($0) } ?? .none
        guard want != shown || (presence.mode == .expanded && expandedAdjunctChanged(beside: .nowPlaying)) else { return }
        let h = panel.geometry.sensor.height
        switch presence.mode {
        case nil:
            showPassive(.inert, primary: nil)
        case .compact?:
            showPassive(.compact(leading: hosted(NowPlayingCompactLeading(model: nowPlaying, sensorHeight: h),
                                                size: NowPlayingMetrics.compactLeadingSize(sensorHeight: h)),
                                trailing: hosted(NowPlayingCompactTrailing(model: nowPlaying, sensorHeight: h),
                                                 size: NowPlayingMetrics.compactTrailingSize(sensorHeight: h))), primary: .nowPlaying)
        case .expanded?:
            let size = CGSize(width: NowPlayingMetrics.expandedWidth, height: NowPlayingMetrics.expandedHeight)
            // Only the adjunct changed: keep the content view so the body stays steady (mitosis / recombination only).
            let v = (shown == want ? nowPlayingExpandedView : nil) ?? hosted(NowPlayingExpanded(model: nowPlaying), size: size)
            nowPlayingExpandedView = v
            showPassive(.expanded(v, size: size, type: NowPlayingMetrics.expandedType,
                                  adjunct: expandedAdjunctView(beside: .nowPlaying)), primary: .nowPlaying)
        }
        shown = want
    }

    private func schedule() {
        work?.cancel()
        guard let d = [controller.deadline, presence.deadline].compactMap({ $0 }).min() else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.controller.tick(now: self.now)
            self.presence.tick(now: self.now)
            self.render()
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(d - now, 0) + 0.01, execute: w)
    }

    func hover(_ inside: Bool) {
        hovering = inside
        controller.setHovering(inside, now: now)
        if let s = slider {
            s.inflated = inside
            panel.reshape(expanded: SliderMetrics.size(inflated: inside))
        }
        // ponytail: [?] expanded Now Playing collapses 0.5 s after the pointer leaves; the 27.3 collapse rule is not read.
        collapse?.cancel()
        if !inside, shown == .nowPlaying(.expanded) {
            let c = DispatchWorkItem { [weak self] in
                guard let self, self.presence.mode == .expanded, self.nowPlaying.scrub == nil else { return }   // not mid-scrub
                self.presence.toggleExpanded()
                self.render()
            }
            collapse = c
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandController.idleAfterInteraction, execute: c)
        }
        schedule()
    }

    /// Now Playing pointer: compact click -> expanded. Expanded: down on the timeline row scrubs (drag, seek on release),
    /// down on a transport control shows its press and sends the command on release, down elsewhere collapses.
    /// Points are in the hosted content view (flipped, origin top-left).
    private func nowPlayingPointer(_ p: CGPoint, _ phase: IslandPanel.DragPhase) {
        switch (shown, phase) {
        case (.nowPlaying(.compact), .began):
            presence.toggleExpanded()
            render()
        case (.nowPlaying(.expanded), .began):
            if NowPlayingMetrics.timelineHit(p) {
                nowPlaying.beginScrub(x: p.x)
            } else if let cmd = NowPlayingMetrics.control(at: p, isPlaying: nowPlaying.isPlaying) {   // glyph widths differ
                nowPlaying.press(cmd)
            } else {
                presence.toggleExpanded()
                render()
            }
        case (.nowPlaying(.expanded), .changed):
            nowPlaying.moveScrub(x: p.x)
        case (_, .ended):
            if let t = nowPlaying.endScrub(), source?.seek(to: t) != true { log.error("MRMediaRemoteSetElapsedTime failed") }
            if let cmd = nowPlaying.release(), source?.send(cmd) != true { log.error("MRMediaRemoteSendCommand failed") }
        default:
            break
        }
    }

    // MARK: Debug harness (development only; driven by the Darwin notification above)

    private static let debugDir = "/tmp/gg-island-debug"

    /// One command per line: `volume|brightness <0..1>`, `focus`, `np` (fake track playing), `np-pause`, `np-stop`,
    /// `hover 0|1`, `click <x> <y>` (content coordinates, top-left), `drag <x> <y> began|changed|ended`, `wait <s>`, `shot <name>`,
    /// `burst <name> <count> <interval s>`. Screenshots: top 300 pt x 800 pt around the island, whole desktop composited,
    /// written to /tmp/gg-island-debug/<name>.png.
    func runDebugScript() {
        guard let text = try? String(contentsOfFile: Self.debugDir + "/cmd", encoding: .utf8) else { return }
        runDebug(text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty })
    }

    private func runDebug(_ lines: [[String]]) {
        guard let c = lines.first else { log.info("debug script done"); return }
        let rest = Array(lines.dropFirst()), arg = { (i: Int) in i < c.count ? c[i] : "" }
        var delay = 0.0
        switch c[0] {
        case "volume", "brightness":
            let v = Double(arg(1)) ?? 0.5
            receive("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:",
                    [c[0] == "volume" ? 5 : 1, 1, 500, 1000, Int(v * 10000), 10000, 0])
        case "focus":
            receive("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"])
        case "focus-off":
            receive("activeActivityDidChangeForManager:", [NSNull()])
        case "charge":   // charge <level> [lpm]: plug-in (not charging -> charging)
            let l = Double(arg(1)) ?? 0.42, lpm = arg(2) == "lpm"
            _ = controller.handle(.power(level: l, isCharging: false, lowPowerMode: lpm), now: now)
            _ = controller.handle(.power(level: l, isCharging: true, lowPowerMode: lpm), now: now)
            render()
        case "lowbat": receive("showLowBattery:", [Double(arg(1)) ?? 0.1])
        case "accessory": receive("showAccessory:text:batteryLevel:", ["Magic Mouse", "Connected", Double(arg(1)) ?? 0.15])
        case "airpods": receive("showSmartRoutingConnected:batteryLevel:", ["AirPods Pro", Double(arg(1)) ?? 0.8])
        case "airdrop":   // airdrop <fraction> <count> | airdrop done <count> | airdrop stop
            airDropChanged(arg(1) == "stop" ? nil
                           : AirDropProgress(fraction: arg(1) == "done" ? 1 : Double(arg(1)) ?? 0.3, itemCount: Int(arg(2)) ?? 1, isFinished: arg(1) == "done"))
        case "media":   // media screen,vm,camera,mic (any subset, in rank order) | media off
            let kinds: [String: MediaActivity] = ["screen": .screenRecording, "vm": .voiceMemos, "camera": .av(.camera), "mic": .av(.mic)]
            let list = arg(1).split(separator: ",").compactMap { kinds[String($0)] }
            let dots: [MediaActivity: PrivacyIndicatorKind] = [.screenRecording: .screenRecording, .voiceMemos: .microphone,
                                                               .av(.camera): .camera, .av(.mic): .microphone]
            panel.setPrivacyIndicators(Set(list.compactMap { dots[$0] }))
            mediaChanged(list)
        case "np", "np-pause", "np-stop":
            let playing = c[0] == "np"
            let info = c[0] == "np-stop" ? nil
                : NowPlayingInfo(title: "Midnight City", artist: "M83", duration: 243, elapsed: 61, rate: playing ? 1 : 0,
                                 timestamp: Date(), artwork: nil)
            nowPlaying.update(.init(info: info, isPlaying: playing, bundleID: "com.apple.Music"))
            presence.update(hasTrack: info != nil, isPlaying: playing, now: now)
            render()
        case "np-art":   // np-art <n>: fake track playing with generated artwork n (a different n flips it)
            let info = NowPlayingInfo(title: "Midnight City", artist: "M83", duration: 243, elapsed: 61, rate: 1, timestamp: Date(),
                                      artwork: Self.testArtwork(Int(arg(1)) ?? 1))
            nowPlaying.update(.init(info: info, isPlaying: true, bundleID: "com.apple.Music"))
            presence.update(hasTrack: true, isPlaying: true, now: now)
            render()
        case "hover": hover(arg(1) == "1")
        case "click": drag(CGPoint(x: Double(arg(1)) ?? 0, y: Double(arg(2)) ?? 0), .began)
        case "drag":   // drag <x> <y> began|changed|ended
            let phase: IslandPanel.DragPhase = arg(3) == "began" ? .began : arg(3) == "ended" ? .ended : .changed
            drag(CGPoint(x: Double(arg(1)) ?? 0, y: Double(arg(2)) ?? 0), phase)
        case "wait": delay = Double(arg(1)) ?? 0.5
        case "shot": debugShot(arg(1))
        case "burst":
            // Captured off the main thread so the main-thread animator keeps its frame rate; PNGs are written after the
            // burst, with capture times (ms from the first frame) in <name>-times.txt.
            let n = Int(arg(2)) ?? 10, dt = Double(arg(3)) ?? 0.033, name = arg(1), rect = debugRect()
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = CACurrentMediaTime()
                var frames: [(CGImage, Double)] = []
                for i in 0..<n {
                    if let img = Self.capture(rect) { frames.append((img, (CACurrentMediaTime() - t0) * 1000)) }
                    let next = t0 + Double(i + 1) * dt - CACurrentMediaTime()
                    if next > 0 { Thread.sleep(forTimeInterval: next) }
                }
                for (i, f) in frames.enumerated() { Self.write(f.0, String(format: "%@-%02d", name, i)) }
                try? frames.map { String(format: "%.0f", $0.1) }.joined(separator: " ")
                    .write(toFile: "\(Self.debugDir)/\(name)-times.txt", atomically: true, encoding: .utf8)
            }
            delay = Double(n) * dt + 0.05
        default: log.error("debug: unknown command \(c[0], privacy: .public)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.runDebug(rest) }
    }

    private func debugRect() -> CGRect {
        let screen = panel.screen ?? NSScreen.main
        return CGRect(x: (screen?.frame.midX ?? 960) - 400, y: 0, width: 800, height: 300)   // global, origin top-left
    }

    /// Solid artwork with a white corner mark (shows the flip direction): odd n red, even n blue.
    private static func testArtwork(_ n: Int) -> Data? {
        let side: CGFloat = 300, img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        (n % 2 == 1 ? NSColor.systemRed : NSColor.systemBlue).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSColor.white.setFill()
        NSRect(x: 20, y: 200, width: 80, height: 80).fill()
        img.unlockFocus()
        return img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }

    private func debugShot(_ name: String) {
        guard let img = Self.capture(debugRect()) else { log.error("debug shot failed"); return }
        Self.write(img, name)
    }

    private static func capture(_ rect: CGRect) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // CGWindowListCreateImage is hidden from the 26 SDK. Options: on-screen only (1), null window, best resolution (8).
        guard let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map({ unsafeBitCast($0, to: Fn.self) })
        else { return nil }
        return fn(rect, 1, 0, 8)?.takeRetainedValue()
    }

    private static func write(_ img: CGImage, _ name: String) {
        let url = URL(fileURLWithPath: "\(debugDir)/\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }

    private func drag(_ p: CGPoint, _ phase: IslandPanel.DragPhase) {
        // Hosted SwiftUI does not take the mouse: AirDrop and the low battery button are hit-tested here.
        if phase == .began {
            switch shown {
            case .airDrop, .airDropExpanded:   // ring = cancel (RE s21.4); elsewhere toggles compact <-> expanded [I]
                let onRing = shown == .airDrop
                    ? airDropTrailing.flatMap { t in airDropLeading.map { AirDropMetrics.compactRingFrame(trailingSize: t.frame.size).contains(t.convert(p, from: $0)) } }
                    : airDropExpandedView.map { AirDropMetrics.expandedRingFrame(in: $0.frame.size).contains(p) }
                if onRing == true {
                    airDropMonitor?.cancel()
                    return
                }
                airDropExpanded.toggle()
                render()
                return
            case .airDropReady:
                if AirDropMetrics.openButtonFrame(in: airDropReadySize).contains(p) { openAirDropFile() }
                return
            case let .media(m) where m == .screenRecording || m == .voiceMemos:   // click opens expanded (RE 22.10)
                mediaExpanded = m
                render()
                return
            case let .split(primary, adjunct):   // RE 22.20: the clicked container expands in place
                let onAdjunct = splitViews.map { $0.adjunct.bounds.contains($0.adjunct.convert(p, from: $0.primary)) } ?? false
                guard let e = splitExpansionTarget(onAdjunct: onAdjunct, primary: primary, adjunct: adjunct) else { return }
                switch e {
                case .airDrop: airDropExpanded = true
                case let .media(m): mediaExpanded = m
                case .nowPlaying: if presence.mode == .compact { presence.toggleExpanded() }
                }
                // 5c: a click on the adjunct merges both into a neutral pill first, a click on the primary expands in
                // place. The other element then stays beside the body only if it qualifies (RE 22.25), else it is swallowed.
                pendingThrough = onAdjunct
                lastPrimary = e
                render()
                return
            case .mediaExpanded(.screenRecording):
                if let v = recordingExpandedView, ScreenRecordingMetrics.stopButtonFrame(in: v.frame.size).contains(p) {
                    v.rootView = ScreenRecordingExpanded(startDate: recordingStart ?? Date(), obstructionHeight: panel.geometry.sensor.height,
                                                         stopPressed: true)
                    stopScreenRecording()
                } else {
                    mediaExpanded = nil
                    render()
                }
                return
            case .mediaExpanded(.voiceMemos):
                if let v = voiceMemosExpandedView, VoiceMemosMetrics.stopButtonFrame(in: v.frame.size).contains(p) {
                    VoiceMemosStopper.stop()   // App Intent through WorkflowKit (VoiceMemosStop.swift)
                } else {
                    mediaExpanded = nil
                    render()
                }
                return
            default: break
            }
        }
        if case .momentary(.battery(let b)) = shown, b.isWarning {
            if phase == .began, BannerMetrics.lowPowerButtonFrame(in: BannerMetrics.batteryExpandedSize(hasBottomLine: true)).contains(p) {
                toggleLowPowerMode()
            }
            return
        }
        guard let s = slider else {
            nowPlayingPointer(p, phase)
            return
        }
        switch phase {
        case .began: controller.setDragging(true, now: now)
        case .ended: controller.setDragging(false, now: now)
        case .changed: break
        }
        let v = SliderMetrics.value(atX: p.x, inflated: s.inflated)
        controller.dragged(to: v)
        s.value = v
        switch s.kind {
        case .volume: SystemControls.setVolume(v)
        case .displayBrightness:
            if !SystemControls.setBrightness(v, display: CGMainDisplayID()) { log.error("DisplayServicesSetBrightness failed") }
        }
        schedule()
    }
}
