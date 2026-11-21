// 27 style interactive glass buttons (A2): registers an interaction definition for .appKit so SwiftUI 26.6 itself
// expands the glass entry shape through PlatformGlassInteractionProxy.updateState. What 26.6 lacks is done here like 27:
// event source (local monitor), spring integrated in-app every frame, two glow layers (26.6 updateGlowLayer is empty).
import AppKit
import SwiftUI

@_silgen_name("gg_log_c") func ggLogC(_ s: UnsafePointer<CChar>)
func ggLog(_ s: String) { s.withCString { ggLogC($0) } }

// GGFlexParams, ggVibrant, GGFlexGlow (the two glow layers): Glow.swift.

/// SwiftUI calls resolvedInteraction -> rep.appendInteractions -> view.init(coreInteractions:) in that order for each
/// glass entry (measured in a test app). The proxy travels from rep to view through this pending variable (main thread only).
private var pendingLink: GGFlexLink?

final class GGFlexLink {
    let proxy: PlatformGlassInteractionProxy
    let cornerRadius: CGFloat
    init(_ c: PlatformGlassInteractionContext) {
        proxy = c.proxy
        // Simplification: control glass has 4 equal corners; take one. Unequal corners would need a CAShapeLayer mask.
        cornerRadius = c.cornerRadii.topLeading
    }
}

struct GGFlexRep: CoreInteractionRepresentable {
    typealias InteractionView = GGFlexView
    let link: GGFlexLink
    static func appendFeature(to buffer: inout CoreInteractionRepresentableFeatureBufferProxy) {}
    func appendInteractions(to proxy: inout CoreInteractionRepresentableInteractionsProxy) { pendingLink = link }
    func updateInteraction(_ interaction: AnyObject, tag: Int) {}
}

final class GGFlexDefinition: PlatformGlassInteractionDefinition {
    override class var system: PlatformSystemDefinition { .appKit }
    override class var interactionType: (any CoreInteractionRepresentable.Type)? { GGFlexRep.self }
    override class func resolvedInteraction(context: PlatformGlassInteractionContext) -> (any CoreInteractionRepresentable)? {
        pendingLink = nil
        // 26.6 calls this for every glass entry; like 27, only glass with `.interactive()` (option supportsFlexInteraction).
        let d = context.glass.debugDescription
        if ggTrace { print("TRACE resolve \(d) corner \(context.cornerRadii.topLeading)") }
        guard d.contains("supportsFlexInteraction") else { return nil }
        return GGFlexRep(link: GGFlexLink(context))
    }
}

final class GGFlexView: NSView, CoreInteractionView {
    typealias Content = GGFlexRep
    var coreInteractions: CoreInteractionRepresentableInteractionsProxy
    let link: GGFlexLink?
    private let glow = GGFlexGlow()
    private var scale = GGSpring(value: 1, velocity: 0)
    private var point = CGPoint.zero
    private(set) var pressed = false
    private var displayLink: CADisplayLink?
    private var timeline = GGPressTimeline()

    required init(coreInteractions: CoreInteractionRepresentableInteractionsProxy) {
        self.coreInteractions = coreInteractions
        link = pendingLink
        pendingLink = nil
        super.init(frame: .zero)
        guard link != nil else { return }
        wantsLayer = true
        layer?.addSublayer(glow.clip)
        GGFlexDriver.shared.register(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// SwiftUI places the glass entry content layers under this view's layer with y pointing down like every SwiftUI
    /// view. Without flipping, AppKit sets geometryFlipped on the layer (parent flipped, child not) and the content flips vertically.
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    func coreAddInteraction(_ interaction: AnyObject) {}
    func coreRemoveInteraction(_ interaction: AnyObject) {}
    func coreSetParentGestureContainerProxy(_ proxy: CoreInteractionViewParentGestureContainerProxy) {}

    var currentScale: Double { scale.value }
    var currentGlow: Double { glow.bigOpacity }

    override func layout() {
        super.layout()
        glow.layout(bounds, cornerRadius: link?.cornerRadius ?? 0)
    }

    func press(at p: NSPoint) {
        pressed = true
        timeline.set(true, at: CACurrentMediaTime())
        point = p
        glow.begin(at: p, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        startTicking()
    }

    func drag(to p: NSPoint) { point = p }

    func release() { pressed = false; timeline.set(false, at: CACurrentMediaTime()); startTicking() }

    private func startTicking() {
        guard displayLink == nil, window != nil else { if window == nil { pressed = false }; return }
        let dl = displayLink(target: self, selector: #selector(tick(_:)))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    @objc private func tick(_ dl: CADisplayLink) {
        guard let link else { return }
        if pressed && !GGFlexDriver.synthetic && NSEvent.pressedMouseButtons & 1 == 0 {   // lost mouseUp
            pressed = false; timeline.set(false, at: CACurrentMediaTime())
        }
        let ws = NSWorkspace.shared
        let m = min(bounds.width, bounds.height)
        // Integrates by the real press/release times (GGPressTimeline): clicks shorter than a frame still get the effect.
        // Simplification: 27 turns the glow off per accessibilityReduceHighlightingEffects (absent on 26.6); Reduce Transparency stands in.
        var glowOff = false
        timeline.advance(to: CACurrentMediaTime()) { on, dt in
            let target = on && !ws.accessibilityDisplayShouldReduceMotion && m > 0 ? (m + GGFlexParams.lift) / m : 1
            let (r, z) = on ? (GGFlexParams.pressResponse, GGFlexParams.pressDamping) : (GGFlexParams.releaseResponse, GGFlexParams.releaseDamping)
            scale.step(to: target, response: r, damping: z, dt: dt)
            glowOff = glow.step(on: on && !ws.accessibilityDisplayShouldReduceTransparency, at: point, dt: dt)
        }
        let settled = !pressed && scale.settled(target: 1) && glowOff
        if settled { scale = GGSpring(value: 1, velocity: 0); timeline.reset() }
        let s = scale.value
        link.proxy.updateState(PlatformGlassInteractionState(scale: CGSize(width: s, height: s), translation: .zero).active(!settled))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        layer?.sublayerTransform = settled ? CATransform3DIdentity
            : CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(c.x, c.y, 0), s, s, 1), -c.x, -c.y, 0)
        CATransaction.commit()
        if settled { dl.invalidate(); displayLink = nil }
    }

    /// Leaving the window mid-bounce: return to rest at once (glass, transform, glow) so nothing is stuck when reattached.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        displayLink?.invalidate(); displayLink = nil; pressed = false
        if scale.value != 1 { link?.proxy.updateState(PlatformGlassInteractionState(scale: CGSize(width: 1, height: 1), translation: .zero).active(false)) }
        scale = GGSpring(value: 1, velocity: 0)
        timeline.reset()
        glow.reset()
        layer?.sublayerTransform = CATransform3DIdentity
    }
}

/// One driver for the whole app: receives the mouse through a local monitor (events are not blocked, buttons work as before).
final class GGFlexDriver {
    static let shared = GGFlexDriver()
    /// Tests send fake events through sendEvent: the real mouse button is not pressed, so skip the "lost mouseUp" check.
    static let synthetic = ProcessInfo.processInfo.environment["GG_SYNTH_EVENTS"] != nil
    private let views = NSHashTable<GGFlexView>.weakObjects()
    private var monitor: Any?
    private weak var active: GGFlexView?

    func register(_ v: GGFlexView) {
        views.add(v)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.handle(e); return e
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            if let a = self?.active, a.window === n.object as? NSWindow { a.release(); self?.active = nil }
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            active?.release(); active = nil
            guard let w = e.window else { return }
            for v in views.allObjects where v.window === w && !v.isHiddenOrHasHiddenAncestor {
                let p = v.convert(e.locationInWindow, from: nil)
                if v.bounds.contains(p) { active = v; v.press(at: p); return }
            }
        case .leftMouseDragged:
            if let a = active { a.drag(to: a.convert(e.locationInWindow, from: nil)) }
        default:
            active?.release(); active = nil
        }
    }

    var debugJSON: String {
        let all = views.allObjects
        let v = active ?? all.first
        return "{\"entries\": \(all.count), \"scale\": \(v?.currentScale ?? 1), \"bigGlow\": \(v?.currentGlow ?? 0)}"
    }
}

private var debugBuffer = [CChar]()
@_cdecl("gg_flex_debug") public func ggFlexDebug() -> UnsafePointer<CChar> {
    debugBuffer = Array(GGFlexDriver.shared.debugJSON.utf8CString)
    return debugBuffer.withUnsafeBufferPointer { $0.baseAddress! }
}

let ggTrace = ProcessInfo.processInfo.environment["GG_TRACE"] != nil

/// Replaces the `_Glass.regular` that DesignLibrary calls: 27 builds MacGlassButton glass with
/// `_Glass.interactive(state != .disabled)`, 26.6 does not. Called from DesignLibrary's GOT slot, so the `_Glass.regular`
/// inside goes through this dylib's GOT, no recursion. ABI: static getter of a resilient struct = swiftcc function with no
/// arguments, indirect return.
/// Simplification: the disabled state is unknown here, so disabled buttons bounce too (27 does not); fixing it needs a patch of
/// the MacGlassButton body.
@_silgen_name("gg_glass_regular") public func ggGlassRegular() -> _Glass { _Glass.regular.interactive(true) }

@_silgen_name("gg_patch_got") func ggPatchGOT(_ image: UnsafePointer<CChar>, _ target: UnsafeMutableRawPointer?, _ repl: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("gg_setting_c") func ggSettingC(_ key: UnsafePointer<CChar>) -> Bool

private var flexInstalled = false
@_cdecl("gg_flex_install") public func ggFlexInstall() {
    guard !flexInstalled else { return }
    flexInstalled = true
    PlatformGlassInteractionDefinition.setDefinition(GGFlexDefinition.self, system: .appKit)
    let cur = PlatformGlassInteractionDefinition.appKit
    ggLog("flex: definition .appKit = \(cur.map { String(describing: $0) } ?? "nil")")
    guard ggSettingC("GGApp.flexGlassButton") else { return }
    let target = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI6_GlassV7regularACvgZ")
    let repl = dlsym(UnsafeMutableRawPointer(bitPattern: -3), "gg_glass_regular")
    let n = ggPatchGOT("/DesignLibrary", target, repl)
    ggLog("flex: patched \(n) DesignLibrary GOT slots for _Glass.regular")
    if ggTrace { print("TRACE patched GOT \(n)") }
}
