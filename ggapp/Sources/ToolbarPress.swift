// 27 style AppKit toolbar button press.
// 27: -[NSToolbarPlatterView initWithFrame:] (AppKit 0x18af2584c) creates an NSGlassEffectView with _effectIsInteractive = YES,
// _flexInteractionSources = 1 (.interaction), no variant set -> FlexInteraction `automatic`; the platter is 36 pt tall < 120
// so it uses the ultraSmall pointer set (GGFlexParams): grows 2.5 pt along the short side, BigGlow 0.75, LittleGlow 0.2625.
// AppKit applies the same transform to the content layer with an additive CAPresentationModifier "transform"
// (0x18b310fb4..0x18b311300).
// 26.6: the platter is only a placeholder (the real glass is drawn together in NSGlassContainerView, one CASDFElementLayer
// per platter), buttons sit outside the platter, and 26.6 NSGlassEffectView has no FlexInteraction. Here: a local monitor
// catches mouseDown inside the platter frame, the 27 spring is integrated every frame, and one transform is attached via
// CAPresentationModifier (without changing model values managed by AppKit/SwiftUI) to the platter's CASDFElementLayer, the
// platter layer (holding the glow) and the platter's item viewers.
import AppKit

/// CAPresentationModifier (QuartzCore, private, present on 26.6) called through the runtime.
private enum GGPresentation {
    static let cls: AnyClass? = NSClassFromString("CAPresentationModifier")
    typealias Init = @convention(c) (AnyObject, Selector, NSString, AnyObject, ObjCBool) -> Unmanaged<AnyObject>

    static func transformModifier(on layer: CALayer) -> NSObject? {
        let sel = NSSelectorFromString("initWithKeyPath:initialValue:additive:")
        guard let cls, let imp = class_getMethodImplementation(cls, sel), layer.responds(to: NSSelectorFromString("addPresentationModifier:")),
              let raw = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        // init consumes the +1 from alloc and returns +1: balanced by takeUnretained above and takeRetained below.
        let m = unsafeBitCast(imp, to: Init.self)(raw, sel, "transform", NSValue(caTransform3D: CATransform3DIdentity), true).takeRetainedValue()
        layer.perform(NSSelectorFromString("addPresentationModifier:"), with: m)
        return m as? NSObject
    }

    static func set(_ m: NSObject, _ t: CATransform3D) {
        m.perform(NSSelectorFromString("setValue:"), with: NSValue(caTransform3D: t))
    }
}

/// Glow + press state of a platter (last subview of NSToolbarPlatterView, does not take the mouse).
final class GGToolbarPressView: NSView {
    private let glow = GGFlexGlow()
    private var scale = GGSpring(value: 1, velocity: 0)
    private var point = CGPoint.zero
    private var modifier: NSObject?
    /// Platter item viewer -> "transform" modifier on its layer. 27 puts viewers in the platter glass contentView
    /// (-[NSToolbarView _layoutItems:withAttributes:supportsGlass:] 0x18ad0d724..0x18ad0d7ac) so AppKit 27 transforms them
    /// with the glass; 26.6 puts viewers outside the platter, so the same transform around the platter center is applied separately.
    private let contentModifiers = NSMapTable<NSView, NSObject>.weakToStrongObjects()
    private var contents: [NSView] = []
    var contentCount: Int { contents.count }
    /// The real glass shape of the platter: 26.6 draws every platter's glass together in NSGlassContainerView (hosting
    /// "NSEffects": SwiftUI.SDFLayer -> CABackdropLayer -> CASDFLayer -> one CASDFElementLayer per platter, same frame), the
    /// platter is only a placeholder. 27 transforms the glass shape itself (FlexStateModifier), so the transform is applied
    /// to that CASDFElementLayer here.
    private weak var element: CALayer?
    private let elementModifiers = NSMapTable<CALayer, NSObject>.weakToStrongObjects()
    var hasGlassElement: Bool { element != nil }
    private var displayLink: CADisplayLink?
    private var timeline = GGPressTimeline()
    private var peak: (Double, Double) = (1, 0)   // GG_TRACE only
    private(set) var pressed = false
    var currentScale: Double { scale.value }
    var currentGlow: Double { glow.bigOpacity }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        layer?.addSublayer(glow.clip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glow.layout(bounds, cornerRadius: .greatestFiniteMagnitude)   // toolbar platters are capsules
    }

    func press(at p: NSPoint) {
        pressed = true
        timeline.set(true, at: CACurrentMediaTime())
        point = p
        glow.begin(at: p, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        // containedItems of a 26.6 platter (ivar _containedItems): item viewers, or NSToolbarItems with an _itemViewer.
        let items = (superview?.value(forKey: "containedItems") as? [AnyObject]) ?? []
        contents = items.compactMap { o -> NSView? in
            if let v = o as? NSView { return v }
            return o.responds(to: NSSelectorFromString("_itemViewer")) ? o.value(forKey: "_itemViewer") as? NSView : nil
        }.filter { $0.layer != nil }
        for v in contents where contentModifiers.object(forKey: v) == nil {
            if let m = GGPresentation.transformModifier(on: v.layer!) { contentModifiers.setObject(m, forKey: v) }
        }
        // SwiftUI may rebuild the element layer on update: look it up again on every press.
        element = findGlassElement()
        if let e = element, elementModifiers.object(forKey: e) == nil, let m = GGPresentation.transformModifier(on: e) {
            elementModifiers.setObject(m, forKey: e)
        }
        startTicking()
    }

    /// CASDFElementLayer matching the platter frame, searched in the nearby ancestor views (up to NSGlassContainerView).
    private func findGlassElement() -> CALayer? {
        guard let p = superview, let pl = p.layer else { return nil }
        let t = pl.bounds
        func match(_ l: CALayer) -> CALayer? {
            if NSStringFromClass(type(of: l)) == "CASDFElementLayer" {
                let r = l.convert(l.bounds, to: pl)
                if abs(r.minX - t.minX) < 1, abs(r.minY - t.minY) < 1, abs(r.width - t.width) < 1, abs(r.height - t.height) < 1 { return l }
            }
            for s in l.sublayers ?? [] { if let f = match(s) { return f } }
            return nil
        }
        var v = p.superview
        for _ in 0..<4 {
            guard let a = v, let l = a.layer else { break }
            if let f = match(l) { return f }
            if NSStringFromClass(type(of: a)).contains("GlassContainer") { break }
            v = a.superview
        }
        return nil
    }

    /// Scale s around point q (view coordinates) for the additive modifier: T(-c) S T(c), c from the layer anchorPoint like 27.
    private static func scale(_ s: Double, about q: CGPoint, in l: CALayer) -> CATransform3D {
        let b = l.bounds, ap = l.anchorPoint
        let c = CGPoint(x: q.x - (b.minX + b.width * ap.x), y: q.y - (b.minY + b.height * ap.y))
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0), CATransform3DMakeScale(s, s, 1)),
                                   CATransform3DMakeTranslation(c.x, c.y, 0))
    }

    func release() {
        if ggTrace { print("TRACE toolbarPress: release, scale \(scale.value), glow \(glow.bigOpacity)") }
        pressed = false
        timeline.set(false, at: CACurrentMediaTime())
        startTicking()
    }

    private func startTicking() {
        guard displayLink == nil, window != nil else { if window == nil { pressed = false }; return }
        if modifier == nil, let l = superview?.layer { modifier = GGPresentation.transformModifier(on: l) }
        let dl = displayLink(target: self, selector: #selector(tick(_:)))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    @objc private func tick(_ dl: CADisplayLink) {
        let synthetic = GGFlexDriver.synthetic
        if pressed && !synthetic && NSEvent.pressedMouseButtons & 1 == 0 {   // mouseUp swallowed by the tracking loop
            pressed = false; timeline.set(false, at: CACurrentMediaTime())
        }
        let ws = NSWorkspace.shared
        let m = min(bounds.width, bounds.height)
        if pressed && !synthetic, let w = window {   // current pointer (the tracking loop does not pass drag events to the monitor)
            point = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        }
        // Integrates by the real press/release times: clicks shorter than a frame still get the effect.
        // Simplification: 27 turns the glow off per accessibilityReduceHighlightingEffects (absent on 26.6); Reduce Transparency stands in.
        var glowOff = false
        timeline.advance(to: CACurrentMediaTime()) { on, dt in
            let target = on && !ws.accessibilityDisplayShouldReduceMotion && m > 0 ? (m + GGFlexParams.lift) / m : 1
            let (r, z) = on ? (GGFlexParams.pressResponse, GGFlexParams.pressDamping) : (GGFlexParams.releaseResponse, GGFlexParams.releaseDamping)
            scale.step(to: target, response: r, damping: z, dt: dt)
            glowOff = glow.step(on: on && !ws.accessibilityDisplayShouldReduceTransparency, at: point, dt: dt)
        }
        let settled = !pressed && scale.settled(target: 1) && glowOff
        if ggTrace { peak = (max(peak.0, scale.value), max(peak.1, glow.bigOpacity)) }
        if settled {
            if ggTrace { print("TRACE toolbarPress: at rest, peak scale \(peak.0), BigGlow \(peak.1)"); peak = (1, 0) }
            scale = GGSpring(value: 1, velocity: 0); timeline.reset()
        }
        let s = scale.value
        if let modifier, let p = superview, let l = p.layer {
            let center = CGPoint(x: p.bounds.midX, y: p.bounds.midY)
            GGPresentation.set(modifier, settled ? CATransform3DIdentity : Self.scale(s, about: center, in: l))
            for v in contents {
                guard let m = contentModifiers.object(forKey: v), let vl = v.layer else { continue }
                GGPresentation.set(m, settled ? CATransform3DIdentity : Self.scale(s, about: v.convert(center, from: p), in: vl))
            }
            if let e = element, let m = elementModifiers.object(forKey: e) {
                GGPresentation.set(m, settled ? CATransform3DIdentity : Self.scale(s, about: CGPoint(x: e.bounds.midX, y: e.bounds.midY), in: e))
            }
        }
        if settled { dl.invalidate(); displayLink = nil }
    }

    /// AppKit may detach and reattach platters when arranging the toolbar: on leaving the window return to rest at once so
    /// no transform/glow gets stuck.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        if ggTrace && (pressed || scale.value != 1) { print("TRACE toolbarPress: platter left the window before resting (scale \(scale.value))") }
        displayLink?.invalidate(); displayLink = nil; pressed = false
        scale = GGSpring(value: 1, velocity: 0)
        timeline.reset()
        glow.reset()
        if let modifier { GGPresentation.set(modifier, CATransform3DIdentity) }
        for v in contents { if let m = contentModifiers.object(forKey: v) { GGPresentation.set(m, CATransform3DIdentity) } }
        if let e = element, let m = elementModifiers.object(forKey: e) { GGPresentation.set(m, CATransform3DIdentity) }
    }
}

final class GGToolbarPressDriver {
    static let shared = GGToolbarPressDriver()
    private let platterClass: AnyClass? = NSClassFromString("NSToolbarPlatterView")
    private let views = NSHashTable<GGToolbarPressView>.weakObjects()
    private weak var active: GGToolbarPressView?
    private weak var last: GGToolbarPressView?
    private var loggedFirstPress = false
    private var presses = 0

    func install() {
        guard platterClass != nil else { ggLog("toolbarPress: no NSToolbarPlatterView, skipping"); return }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in self?.handle(e); return e }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            if let a = self?.active, a.window === n.object as? NSWindow { self?.releaseActive() }
        }
        ggLog("toolbarPress: installed")
    }

    private func releaseActive() { active?.release(); active = nil }

    private func platters(in v: NSView, _ out: inout [NSView]) {
        if let c = platterClass, v.isKind(of: c) { out.append(v); return }
        v.subviews.forEach { platters(in: $0, &out) }
    }

    private func handle(_ e: NSEvent) {
        guard e.type == .leftMouseDown else { releaseActive(); return }
        releaseActive()
        guard let w = e.window, w.toolbar != nil, let root = w.contentView?.superview else { return }
        // The toolbar lives in the titlebar container; do not scan the whole content tree of the app.
        let bars = root.subviews.filter { NSStringFromClass(type(of: $0)).contains("Titlebar") }
        var ps: [NSView] = []
        (bars.isEmpty ? [root] : bars).forEach { platters(in: $0, &ps) }
        let loc = e.locationInWindow
        guard let p = ps.first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 && $0.convert($0.bounds, to: nil).contains(loc) }) else { return }
        // Simplification: 27 disables per the platter contentsEnabled (_isEnabledAndHasEnabledSubitem); here the control under the pointer is checked.
        var hit = root.hitTest(loc)
        while let h = hit, !(h is NSControl) { hit = h.superview }
        if let c = hit as? NSControl, !c.isEnabled { return }
        let v = p.subviews.compactMap { $0 as? GGToolbarPressView }.first ?? {
            let n = GGToolbarPressView(frame: p.bounds)
            p.addSubview(n, positioned: .above, relativeTo: nil)
            views.add(n)
            return n
        }()
        active = v; last = v; presses += 1
        v.press(at: v.convert(loc, from: nil))
        if ggTrace { print("TRACE toolbarPress: press platter \(Int(p.bounds.width)) at \(e.timestamp), key \(w.isKeyWindow)") }
        if !loggedFirstPress {
            loggedFirstPress = true
            ggLog("toolbarPress: press platter \(Int(p.bounds.width))x\(Int(p.bounds.height)), \(v.contentCount) item viewers")
        }
        // The button runs a nested tracking loop inside sendEvent, mouseUp does not pass the monitor. A block in default mode
        // only runs when that loop ends; then if the mouse button is up (or a fake test event) return to rest, otherwise let tick watch.
        RunLoop.main.perform(inModes: [.default]) { [weak self, weak v] in
            guard let self, let v, self.active === v, GGFlexDriver.synthetic || NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.releaseActive()
        }
    }

    var debugJSON: String {
        let v = active ?? last
        return "{\"platters\": \(views.allObjects.count), \"scale\": \(v?.currentScale ?? 1), \"bigGlow\": \(v?.currentGlow ?? 0), \"content\": \(v?.contentCount ?? 0), \"glass\": \(v?.hasGlassElement == true ? 1 : 0), \"presses\": \(presses)}"
    }
}

private var toolbarDebugBuffer = [CChar]()
@_cdecl("gg_toolbar_press_debug") public func ggToolbarPressDebug() -> UnsafePointer<CChar> {
    toolbarDebugBuffer = Array(GGToolbarPressDriver.shared.debugJSON.utf8CString)
    return toolbarDebugBuffer.withUnsafeBufferPointer { $0.baseAddress! }
}

private var toolbarPressInstalled = false
@_cdecl("gg_toolbar_press_install") public func ggToolbarPressInstall() {
    guard !toolbarPressInstalled else { return }
    toolbarPressInstalled = true
    GGToolbarPressDriver.shared.install()
}
