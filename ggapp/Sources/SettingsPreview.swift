// Liquid Glass slider preview, rebuilding the .settings branch of 27 AppearancePreferencesFramework GlassStylePreviewView.
// Resources (Apple Park and Clarus images, string tables) are extracted from macOS 27 and are not part of the repository;
// they live in <GGApp.dylib directory>/Resources/SettingsPreview (installed: /Users/Shared/GoldenGate/Resources) or
// ../Resources when running from the build directory. The Appearance pane is not sandboxed, so it can read them.
// Without them the preview still works: images fall back to a placeholder symbol and text to the English keys.
import SwiftUI
import AppKit

enum GGPreviewRes {
    static let dir: URL? = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let f = info.dli_fname else { return nil }
        let lib = URL(fileURLWithPath: String(cString: f)).deletingLastPathComponent()
        return [lib.appendingPathComponent("Resources/SettingsPreview"), lib.appendingPathComponent("../Resources/SettingsPreview").standardized]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Localizable.loctable").path) }
    }()
    /// Localizable.loctable string table of the 27 framework (43 languages).
    static let bundle: Bundle? = dir.flatMap { Bundle(url: $0) }
    private static var cache: [String: NSImage] = [:]
    static func nsImage(_ name: String) -> NSImage? {
        if let im = cache[name] { return im }
        let im = dir.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name + ".heic")) }
        cache[name] = im
        return im
    }
    static func image(_ name: String) -> Image { nsImage(name).map { Image(nsImage: $0) } ?? Image(systemName: "photo") }
}

/// Text(key, bundle: 27 string table) like the framework's Text(_:tableName:bundle:comment:).
func ggL(_ key: String) -> Text { Text(LocalizedStringKey(key), tableName: "Localizable", bundle: GGPreviewRes.bundle) }

private func ggSettingDefault(_ key: String, _ def: Bool) -> Bool {
    typealias Fn = @convention(c) (NSString, Bool) -> Bool
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ggSettingDefault").map { unsafeBitCast($0, to: Fn.self)(key as NSString, def) } ?? def
}

/// 27 article background (dynamic NSColor provider 0x2612df4xx): dark sRGB (0.076, 0.07, 0.06), light (0.912, 0.897, 0.876).
private let ggArticleBackground = NSColor(name: nil) { ap in
    ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.076, green: 0.07, blue: 0.06, alpha: 1)
        : NSColor(srgbRed: 0.912, green: 0.897, blue: 0.876, alpha: 1)
}

/// SwiftUI.ToolbarControlGroupStyle exists in SwiftUI 26.6 (SPI, not in the SDK): build the value at runtime from metadata and
/// the conformance descriptor. Empty type (size 0), so the existential needs no buffer.
private let toolbarControlGroupStyle: (any ControlGroupStyle)? = {
    typealias Acc = @convention(c) (Int) -> UnsafeRawPointer
    typealias GetWT = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
    let rt = UnsafeMutableRawPointer(bitPattern: -2)
    guard let acc = dlsym(rt, "$s7SwiftUI24ToolbarControlGroupStyleVMa"),
          let cd = dlsym(rt, "$s7SwiftUI24ToolbarControlGroupStyleVAA0deF0AAMc"),
          let gwt = dlsym(rt, "swift_getWitnessTable") else { return nil }
    let meta = unsafeBitCast(acc, to: Acc.self)(0)
    let vwt = meta.load(fromByteOffset: -8, as: UnsafeRawPointer.self)
    guard vwt.load(fromByteOffset: 0x40, as: Int.self) == 0,
          let wt = unsafeBitCast(gwt, to: GetWT.self)(UnsafeRawPointer(cd), meta, nil) else { return nil }
    struct Existential { var b0 = 0, b1 = 0, b2 = 0; var meta: UnsafeRawPointer; var wt: UnsafeRawPointer }
    return unsafeBitCast(Existential(meta: meta, wt: wt), to: (any ControlGroupStyle).self)
}()

extension View {
    fileprivate func ggToolbarControlGroupStyle() -> AnyView {
        func apply<S: ControlGroupStyle>(_ s: S) -> AnyView { AnyView(controlGroupStyle(s)) }
        return toolbarControlGroupStyle.map { apply($0) } ?? AnyView(self)
    }
}

/// 27 `_scrollInputForwardingBehavior(.never, axes: .vertical)` (new SPI, absent on 26.6): gestures in the preview are not
/// forwarded to the parent Form. Measured on the real pane: when the preview hits the bottom, its `scrollWheel:` asks the
/// ancestor HostingScrollView (Form) `wantsForwardedScrollEventsForAxis:`, the Form returns true so that event goes to the
/// Form and the Form scrolls; AppKit does not ask the preview. Here: while `scrollWheel:` of the preview scroll area (marked
/// with an associated object) runs, every HostingScrollView returns false for the vertical axis, so the preview keeps the
/// gesture and rubber-bands.
private var ggNoForwardKey: UInt8 = 0
private var ggPreviewScrollDepth = 0   // > 0: inside scrollWheel: of the preview scroll area (main thread)
private let ggInstallNoForward: Void = {
    let sel = #selector(NSResponder.wantsForwardedScrollEvents(for:))
    guard let cls = NSClassFromString("_TtC7SwiftUI17HostingScrollView"),
          let m = class_getInstanceMethod(cls, sel) else { return }
    typealias Fn = @convention(c) (NSObject, Selector, NSEvent.GestureAxis) -> Bool
    let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
    let block: @convention(block) (NSObject, NSEvent.GestureAxis) -> Bool = { view, axis in
        if axis == .vertical, ggPreviewScrollDepth > 0 { return false }
        return orig(view, sel, axis)
    }
    method_setImplementation(m, imp_implementationWithBlock(block))
    // scrollWheel: of the preview scroll area: while it handles the event, ancestors do not accept vertical forwarding.
    let ssel = #selector(NSResponder.scrollWheel(with:))
    if let sm = class_getInstanceMethod(cls, ssel) {
        typealias SFn = @convention(c) (NSObject, Selector, NSEvent) -> Void
        let so = unsafeBitCast(method_getImplementation(sm), to: SFn.self)
        let sb: @convention(block) (NSObject, NSEvent) -> Void = { view, event in
            let marked = objc_getAssociatedObject(view, &ggNoForwardKey) != nil
            if marked { ggPreviewScrollDepth += 1 }
            so(view, ssel, event)
            if marked { ggPreviewScrollDepth -= 1 }
        }
        method_setImplementation(sm, imp_implementationWithBlock(sb))
    }
}()

private struct GGScrollInputNever: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let sv = enclosingScrollView else { return }
            _ = ggInstallNoForward
            objc_setAssociatedObject(sv, &ggNoForwardKey, true, .OBJC_ASSOCIATION_RETAIN)
        }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ nsView: Marker, context: Context) {}
}

/// State of 27 GlassStylePreviewView (the @State properties of the same names: photoOpacity, demoScrollOffset, OREnabled, ...).
/// "OR" = Oak Ridge: the "Moof!" easter egg enabled by the AKURLBag enableOakRidge key. Gathered in one model so tests can drive it.
final class GGPreviewModel: ObservableObject {
    static let message = "Moof!"   // 27: byte array minus 0x10 at 0x26e782bc0
    /// Per-letter colors while bouncing (27: 0x2612d2f20..0x2612d3084, sRGB).
    static let letterColors: [Color] = [
        Color(.sRGB, red: 0.25, green: 0.52, blue: 1.0), Color(.sRGB, red: 0.42, green: 0.24, blue: 0.9),
        Color(.sRGB, red: 0.7, green: 0.2, blue: 0.65), Color(.sRGB, red: 0.88, green: 0.25, blue: 0.42),
        Color(.sRGB, red: 1.0, green: 0.42, blue: 0.22)]
    let step: CGFloat = 2.5   // .settings 2.5, .setup 3.0
    let threshold: CGFloat = 14

    @Published var photoOpacity = 0.0
    @Published var demoScrollOffset: CGFloat = 0
    @Published var orEnabled = false
    @Published var scrollDemoFinished = false
    @Published var orLocked = false
    @Published var orCharCount = 0
    @Published var orBounceTrigger = false
    @Published var orOpacity = 0.0
    @Published var scrollLocked = false
    var lastBottomDistance: CGFloat = -1
    var currentScrollPhase: ScrollPhase = .idle
    var pendingORScrollToBottom = false
    var orLastRevealDistance: CGFloat = 0
    var orLastRevealTime: Date?
    var orRevealScheduled = false
    var scrollToBottom: (() -> Void)?
    var haptics = 0
    private var started = false

    private func noAnimation(_ f: () -> Void) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t, f)
    }

    /// 27 .task (0x2612e0280): images fade in, a 52 pt scroll demo and back, then asks AKURLBag.
    func start(reduceMotion: Bool) {
        guard !started else { return }
        started = true
        if reduceMotion {
            photoOpacity = 1; scrollDemoFinished = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.photoOpacity = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { if !self.scrollDemoFinished { self.demoScrollOffset = -52 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if !self.scrollDemoFinished { self.demoScrollOffset = 0; self.scrollDemoFinished = true }
            }
        }
        queryOakRidge()
    }

    /// 27 (0x2612d70b8): AKURLBag.sharedBag configurationValueForKey:"enableOakRidge" fromCache:NO, a Bool value.
    /// GGApp.settingsMoof (unset by default) forces on/off without asking the server; tests use GG_OAKRIDGE=0/1.
    private func queryOakRidge() {
        if let e = ProcessInfo.processInfo.environment["GG_OAKRIDGE"] { orEnabled = e == "1"; return }
        let forced = ggSettingDefault("GGApp.settingsMoof", false) == ggSettingDefault("GGApp.settingsMoof", true)   // key is set
        if forced { orEnabled = ggSettingDefault("GGApp.settingsMoof", false); return }
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW)
        guard let cls = NSClassFromString("AKURLBag") as? NSObject.Type,
              let bag = cls.perform(NSSelectorFromString("sharedBag"))?.takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("configurationValueForKey:fromCache:completion:")
        guard bag.responds(to: sel), let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return }
        typealias Send = @convention(c) (NSObject, Selector, NSString, Bool, @escaping @convention(block) (Any?, Error?) -> Void) -> Void
        unsafeBitCast(send, to: Send.self)(bag, sel, "enableOakRidge", false) { value, _ in
            let on = (value as? NSNumber)?.boolValue ?? false
            DispatchQueue.main.async { self.orEnabled = on }
        }
    }

    /// onScrollPhaseChange (0x2612e4de8).
    func phaseChanged(_ new: ScrollPhase) {
        currentScrollPhase = new
        if new != .idle, !scrollDemoFinished {
            scrollDemoFinished = true
            noAnimation { demoScrollOffset = 0 }
        }
        if new == .idle { performPendingScroll() }
    }

    /// onChange(of: ORLocked) (0x2612e50d8): once locked, scroll down to the Clarus image; while dragging, wait for release (up to 2 s).
    func lockedChanged(_ locked: Bool) {
        guard locked else { return }
        pendingORScrollToBottom = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (currentScrollPhase == .idle ? 0.05 : 2.0)) { self.performPendingScroll() }
    }

    private func performPendingScroll() {
        guard pendingORScrollToBottom else { return }
        pendingORScrollToBottom = false
        scrollLocked = true
        withAnimation(.spring(response: 0.7, dampingFraction: 0.85), completionCriteria: .logicallyComplete) {
            scrollToBottom?()
        } completion: { self.scrollLocked = false }
    }

    func charCount(_ d: CGFloat) -> Int { d < threshold ? 0 : min(Self.message.count, Int((d - threshold) / step) + 1) }   // 0x2612deb94
    func nextThreshold() -> CGFloat { orCharCount == 0 ? threshold : orLastRevealDistance + step }                       // 0x2612eba98

    private func resetReveal() { orCharCount = 0; orLastRevealDistance = 0; orLastRevealTime = nil }                     // 0x2612eb918

    /// onScrollGeometryChange action (0x2612e4d74 -> 0x2612eac68). d = overscroll past the bottom (negative before the bottom).
    func bottomDistanceChanged(_ d: CGFloat) {
        lastBottomDistance = d
        if d < 0 {
            if !orLocked { noAnimation { resetReveal() } }
            return
        }
        guard orEnabled, scrollDemoFinished, !orLocked else { return }
        let c = charCount(d)
        if c < orCharCount { noAnimation { orCharCount = c; orLastRevealDistance = d; orLastRevealTime = Date() } }
        if d < 5 { noAnimation { resetReveal() }; return }
        scheduleReveal()
    }

    /// 0x2612eb244: letters at least 0.035 s apart, only once dragged past the next letter's threshold.
    private func scheduleReveal() {
        guard !orRevealScheduled, orCharCount < Self.message.count, nextThreshold() < lastBottomDistance else { return }
        let elapsed = orLastRevealTime.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, 0.035 - elapsed)
        orRevealScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.revealStep() }
    }

    /// 0x2612ebb6c: reveals one more letter with a light haptic; once "Moof!" is complete, lock, bounce the letters and show
    /// Clarus (0x2612ec004).
    func revealStep() {
        orRevealScheduled = false
        guard orEnabled, scrollDemoFinished, !orLocked, orCharCount < Self.message.count, nextThreshold() < lastBottomDistance else { return }
        noAnimation { orCharCount += 1; orLastRevealDistance = lastBottomDistance; orLastRevealTime = Date() }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        haptics += 1
        if orCharCount == Self.message.count {
            orLocked = true
            orBounceTrigger.toggle()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { orOpacity = 1 }
        }
    }
}

/// ORLetter: one letter of "Moof!" with a keyframeAnimator (trigger = ORBounceTrigger), 27: 0x2612d3000..0x2612d5560.
private struct GGORLetter: View {
    struct AnimationState { var offsetY: CGFloat = 0; var scale: CGFloat = 1; var base = 1.0; var overlay = 0.0 }
    let char: String
    let index: Int
    let trigger: Bool

    var body: some View {
        let delay = max(0.001, Double(index) * 0.06)
        Text(char).font(.body).fontWeight(.medium).foregroundStyle(.primary)
            .keyframeAnimator(initialValue: AnimationState(), trigger: trigger) { content, s in
                content.opacity(s.base)
                    .overlay {
                        Text(char).font(.body).fontWeight(.semibold)
                            .foregroundStyle(GGPreviewModel.letterColors[index % GGPreviewModel.letterColors.count])
                            .opacity(s.overlay)
                    }
                    .offset(y: s.offsetY)
                    .scaleEffect(s.scale)
            } keyframes: { _ in
                KeyframeTrack(\.offsetY) {
                    LinearKeyframe(0, duration: delay, timingCurve: .linear)
                    SpringKeyframe(-8, duration: 0.25, spring: Spring(response: 0.35, dampingRatio: 0.5))
                    SpringKeyframe(2, duration: 0.25, spring: Spring(response: 0.35, dampingRatio: 0.6))
                    SpringKeyframe(0, duration: 0.5, spring: Spring(response: 0.4, dampingRatio: 0.75))
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: delay, timingCurve: .linear)
                    SpringKeyframe(1.15, duration: 0.25, spring: Spring(response: 0.35, dampingRatio: 0.5))
                    SpringKeyframe(0.97, duration: 0.25, spring: Spring(response: 0.35, dampingRatio: 0.6))
                    SpringKeyframe(1, duration: 0.5, spring: Spring(response: 0.4, dampingRatio: 0.75))
                }
                KeyframeTrack(\.base) {
                    LinearKeyframe(1, duration: delay, timingCurve: .linear)
                    CubicKeyframe(0, duration: 0.15)
                    LinearKeyframe(0, duration: 0.4, timingCurve: .linear)
                    CubicKeyframe(1, duration: 0.3)
                }
                KeyframeTrack(\.overlay) {
                    LinearKeyframe(0, duration: delay, timingCurve: .linear)
                    CubicKeyframe(1, duration: 0.15)
                    LinearKeyframe(1, duration: 0.4, timingCurve: .linear)
                    CubicKeyframe(0, duration: 0.3)
                }
            }
    }
}

/// GlassStylePreviewView(style: .settings): 268 x 180, bo 16.
struct GGGlassPreview27: View {
    @StateObject private var model = GGPreviewModel().register()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Article item (0x2612e5f34): image with radius 16, bold title3 heading, body description.
    private func section(_ image: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GGPreviewRes.image(image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.vertical, 16)
                .accessibilityLabel(ggL(title))
            ggL(title).font(.title3).fontWeight(.bold)
            ggL(text).font(.body).foregroundStyle(.primary)
        }
    }

    /// Scroll content (0x2612e24b4): 268 x 152 header image under the toolbar, articles, Clarus image once locked.
    private var article: some View {
        VStack(alignment: .leading) {
            GGPreviewRes.image("apple-park").resizable().aspectRatio(contentMode: .fill)
                .frame(width: 268, height: 152)
                .clipped()
                .accessibilityLabel(ggL("Apple Park"))
                .padding(.bottom, -8)
            VStack(alignment: .leading, spacing: 8) {
                ggL("Welcome to Apple Park").font(.title3).fontWeight(.semibold).padding(.bottom, -4)
                ggL("Cupertino, California").font(.title3).fontWeight(.regular).foregroundStyle(.secondary).padding(.bottom, 4)
                ggL("Learn about the design and history of Apple Park, and discover its unique nature and beauty.")
                    .font(.body).foregroundStyle(.primary)
                section("architecture", "The Architecture",
                        "Apple Park was made for walking and exploring. The innovative design elements emphasize openness and connection to nature.")
                section("pond", "The Pond", "With gently lapping waves and a surrounding of trees, it’s one of the most serene spots on campus.")
                section("rainbow", "The Rainbow",
                        "One of the most iconic features of Apple Park, the Rainbow brings much joy to all who experience it.")
            }
            .padding(16)
            if model.orLocked { Spacer().frame(height: 32) } else { Spacer().frame(height: 8) }
            if model.orLocked, let clarus = GGPreviewRes.nsImage("clarus") {
                // 27 (typeref IDView<ModifiedContent<Image.aspectRatio.frame, _ClipEffect<Rectangle>>, _OpacityEffect>):
                // fills the frame (portrait image center-cropped) and clips to it, so overflow does not cover text when scrolling back up.
                Image(nsImage: clarus).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 268, height: 180)
                    .clipped()
                    .opacity(model.orOpacity)
                    .id("or")
            }
        }
        .frame(width: 268, alignment: .leading)
        .offset(y: model.demoScrollOffset)
        .animation(.spring(response: 2.0, dampingFraction: 0.82), value: model.demoScrollOffset)
    }

    /// Search field in the ControlGroup: "Search" or the revealed letters of "Moof!" (ORRevealField).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.body)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if model.orCharCount == 0 {
                ggL("Search").font(.body).fontWeight(.medium).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(GGPreviewModel.message.prefix(model.orCharCount).enumerated()), id: \.offset) { i, c in
                        GGORLetter(char: String(c), index: i, trigger: model.orBounceTrigger)
                    }
                }
            }
            Spacer()   // 27 (the search field HStack typeref has a Spacer): the field stretches to fill the rest of the toolbar
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    /// Toolbar (0x2612e100c..0x2612e14cc): toolbar style ControlGroup, 36 tall, padding 8.
    private var toolbar: some View {
        // 27 (0x2612e6ac0, typeref): group 1 = share + ellipsis (0x2612e6ec8), group 2 = square.on.square, group 3 = search
        // field (0x2612e72d8); button text labels are empty strings.
        ControlGroup {
            Section {
                Button("", systemImage: "square.and.arrow.up") {}
                Button("", systemImage: "ellipsis") {}
            }
            Section { Button("", systemImage: "square.on.square") {} }
            Section { searchField }
        }
        .ggToolbarControlGroupStyle()
        .focusable(false)
        .accessibilityHidden(true)
        .frame(height: 36)
        .padding(.top, 8).padding(.horizontal, 8).padding(.bottom, 8)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) { article.background(GGScrollInputNever()) }
                    .contentMargins(.top, 52, for: .scrollIndicators)
                    .contentMargins(.bottom, 16, for: .scrollIndicators)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    .scrollDisabled(model.scrollLocked)
                    .onScrollGeometryChange(for: CGFloat.self) { g in
                        let maxOffset = g.contentSize.height - g.visibleRect.height + g.contentInsets.bottom
                        return maxOffset > 0 ? g.contentOffset.y - maxOffset : -1
                    } action: { _, d in model.bottomDistanceChanged(d) }
                    .onScrollPhaseChange { _, new in model.phaseChanged(new) }
                    .onChange(of: model.orLocked) { _, locked in model.lockedChanged(locked) }
                    .onAppear { model.scrollToBottom = { proxy.scrollTo("or", anchor: .bottom) } }
            }
            .opacity(model.photoOpacity)
            .animation(.spring(response: 0.7, dampingFraction: 0.65), value: model.photoOpacity)
            .background(Color(nsColor: ggArticleBackground))
            toolbar
        }
        .frame(width: 268, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { model.start(reduceMotion: reduceMotion) }    }
}

// For tests/app.swift (settings mode): reads the preview state and simulates overscrolling past the bottom.
private weak var lastPreview: GGPreviewModel?
extension GGPreviewModel { func register() -> Self { lastPreview = self; return self } }

@_cdecl("gg_settings_preview_state") public func ggSettingsPreviewState() -> UnsafePointer<CChar> {
    struct S { static var buf: [CChar] = [] }
    var d: [String: Any] = ["resources": GGPreviewRes.dir?.path ?? "", "locs": GGPreviewRes.bundle?.localizations.count ?? 0]
    if let m = lastPreview {
        d.merge(["photoOpacity": m.photoOpacity, "demoScrollOffset": m.demoScrollOffset, "scrollDemoFinished": m.scrollDemoFinished,
                 "orEnabled": m.orEnabled, "orCharCount": m.orCharCount, "orLocked": m.orLocked, "orOpacity": m.orOpacity,
                 "haptics": m.haptics, "bottom": m.lastBottomDistance, "images": ["apple-park", "architecture", "pond", "rainbow", "clarus"].filter { GGPreviewRes.nsImage($0) != nil }.count,
                 "title": GGPreviewRes.bundle?.localizedString(forKey: "Welcome to Apple Park", value: nil, table: "Localizable") ?? ""]) { $1 }
    }
    S.buf = Array((String(data: (try? JSONSerialization.data(withJSONObject: d)) ?? Data(), encoding: .utf8) ?? "{}").utf8CString)
    return S.buf.withUnsafeBufferPointer { $0.baseAddress! }
}

/// Simulates the user overscrolling d pt past the bottom and holding (one scroll geometry change, as onScrollGeometryChange calls).
@_cdecl("gg_settings_preview_overscroll") public func ggSettingsPreviewOverscroll(_ d: Double) {
    lastPreview?.phaseChanged(.interacting)
    lastPreview?.bottomDistanceChanged(CGFloat(d))
}

/// Simulates the user lifting the fingers (scroll phase back to .idle): once locked, the preview scrolls down to Clarus like 27.
@_cdecl("gg_settings_preview_release") public func ggSettingsPreviewRelease() { lastPreview?.phaseChanged(.idle) }
