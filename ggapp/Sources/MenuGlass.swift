// 27 style interactive menu glass.
// 27: -[NSContextMenuImpl loadView] (AppKit 0x18a95dc2c..0x18a95dc58) sets the menu glass _effectIsInteractive =
// _NSEnableFlexiglass() (except NSMenuDisableFlexiglassForKeynote), "menu" variant; NSMenuTrackingSession feeds mouse events
// into -[NSContextMenuImpl handleMouseEvent:/handleTrackEntered:/handleTrackExited:] -> _NSFlexiglassInteractionDriver
// (0x18a898810): press (types 1, 3, 25) goes active at the press point, drag updates the position, release (2, 4, 26) or
// leaving the menu goes inactive, re-entering while the button is held goes active (trackEntered checks pressedMouseButtons).
// Submenus use the driver of the parent menu.
// Menu pointer set: lift 0, scaleDistanceThreshold 0 (flex off, applyInteraction skips when <= 0), BigGlow 0, LittleGlow 0.05,
// dissipation 25: with a mouse only a faint LittleGlow spot under the pointer remains.
// 26.6: the menu glass is the first NSGlassView (NSGlassEffectView subclass, radius 12) in the NSPopupMenuWindow frame view,
// with no FlexInteraction, and NSContextMenuImpl has no handleMouseEvent:. Here: hook -[NSMenuTrackingSession handleEvent:]
// (the common entry for events in the menu loop); the glow is a GGFlexGlow (Glow.swift) in a view above the glass, below the content.
import AppKit

final class GGMenuGlowView: NSView {
    let glow = GGFlexGlow(bigGlow: 0, littleGlow: 0.05, dissipation: 25)
    private var displayLink: CADisplayLink?
    private var timeline = GGPressTimeline()
    private var point = CGPoint.zero
    private(set) var active = false

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
        glow.layout(bounds, cornerRadius: (superview?.value(forKey: "cornerRadius") as? CGFloat) ?? 12)
    }

    func local(_ screen: NSPoint) -> NSPoint { window.map { convert($0.convertPoint(fromScreen: screen), from: nil) } ?? .zero }

    func press(at p: NSPoint) {
        active = true
        point = p
        timeline.set(true, at: CACurrentMediaTime())
        glow.begin(at: p, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        startTicking()
    }

    func move(to p: NSPoint) { point = p }

    func release() {
        guard active else { return }
        active = false
        timeline.set(false, at: CACurrentMediaTime())
        startTicking()
    }

    private func startTicking() {
        guard displayLink == nil, window != nil else { return }
        let dl = displayLink(target: self, selector: #selector(tick(_:)))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    @objc private func tick(_ dl: CADisplayLink) {
        if active && window?.isVisible != true { release() }   // menu closed without a release (Esc key, timeout)
        // Simplification: 27 turns the glow off per accessibilityReduceHighlightingEffects (absent on 26.6); Reduce Transparency stands in.
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        var off = false
        timeline.advance(to: CACurrentMediaTime()) { on, dt in off = glow.step(on: on && !reduce, at: point, dt: dt) }
        if !active && off { timeline.reset(); dl.invalidate(); displayLink = nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        displayLink?.invalidate(); displayLink = nil; active = false
        timeline.reset(); glow.reset()
    }
}

final class GGMenuGlassDriver {
    static let shared = GGMenuGlassDriver()
    private let menuWindowClass: AnyClass? = NSClassFromString("NSPopupMenuWindow")
    private(set) var presses = 0
    private weak var last: GGMenuGlowView?

    func install() {
        let sel = NSSelectorFromString("handleEvent:")
        guard menuWindowClass != nil, let c = NSClassFromString("NSMenuTrackingSession"), let m = class_getInstanceMethod(c, sel),
              String(cString: method_getTypeEncoding(m)!).hasPrefix("c") else { ggLog("menuGlass: no NSMenuTrackingSession handleEvent:, skipping"); return }
        typealias F = @convention(c) (AnyObject, Selector, NSEvent) -> Int8
        let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
        let blk: @convention(block) (AnyObject, NSEvent) -> Int8 = { s, e in
            GGMenuGlassDriver.shared.handle(e)
            return orig(s, sel, e)
        }
        method_setImplementation(m, imp_implementationWithBlock(blk))
        ggLog("menuGlass: installed")
    }

    /// Glass of a menu window: the first NSGlassEffectView in the frame view; the glow view sits on top inside that glass.
    private func glowView(_ w: NSWindow) -> GGMenuGlowView? {
        guard let c = menuWindowClass, w.isKind(of: c), w.isVisible,
              let g = w.contentView?.superview?.subviews.first(where: { $0 is NSGlassEffectView }) else { return nil }
        if let v = g.subviews.last as? GGMenuGlowView { return v }
        let v = GGMenuGlowView(frame: g.bounds)
        g.addSubview(v, positioned: .above, relativeTo: nil)
        return v
    }

    func handle(_ e: NSEvent) {
        let kind: Int
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = 0
        // mouseMoved is ignored: 27 only uses it to update the position while active, and with a button held only drag events arrive.
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = 1
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = 2
        default: return
        }
        let screen = e.window.map { $0.convertPoint(toScreen: e.locationInWindow) } ?? NSEvent.mouseLocation
        for w in NSApp.windows {
            guard let v = glowView(w) else { continue }
            let p = v.local(screen), inside = v.bounds.contains(p)
            switch kind {
            case 0 where inside:
                presses += 1; last = v
                if presses == 1 { ggLog("menuGlass: menu press \(Int(v.bounds.width))x\(Int(v.bounds.height))") }
                if ggTrace { print("TRACE menuGlass: press \(p)") }
                v.press(at: p)
            case 1 where v.active && !inside: v.release()                 // trackExited
            case 1 where v.active: v.move(to: p)
            case 1 where inside: last = v; v.press(at: p)                 // trackEntered while the button is held (drag event)
            case 2: v.release()
            default: break
            }
        }
    }

    var debugJSON: String {
        "{\"presses\": \(presses), \"active\": \(last?.active == true ? 1 : 0), \"little\": \(last?.glow.littleOpacity ?? 0), \"big\": \(last?.glow.bigOpacity ?? 0)}"
    }
}

private var menuDebugBuffer = [CChar]()
@_cdecl("gg_menu_glass_debug") public func ggMenuGlassDebug() -> UnsafePointer<CChar> {
    menuDebugBuffer = Array(GGMenuGlassDriver.shared.debugJSON.utf8CString)
    return menuDebugBuffer.withUnsafeBufferPointer { $0.baseAddress! }
}

/// For tests: sends an event through the exact handling path of the hook (the menu loop closes itself on a fake mouseDown
/// because the real pointer is outside the menu, so a test cannot hold a press through AppKit).
@_cdecl("gg_menu_glass_event") public func ggMenuGlassEvent(_ e: NSEvent) { if menuGlassInstalled { GGMenuGlassDriver.shared.handle(e) } }

private var menuGlassInstalled = false
@_cdecl("gg_menu_glass_install") public func ggMenuGlassInstall() {
    guard !menuGlassInstalled else { return }
    menuGlassInstalled = true
    GGMenuGlassDriver.shared.install()
}
