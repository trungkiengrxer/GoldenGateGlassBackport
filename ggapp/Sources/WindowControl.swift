// 27 style traffic lights (B4): port of the 27 DesignLibrary.MacWindowControlElement + WindowControlMaterialProvider,
// built with the SwiftUICore 26.6 MaterialProvider SPI.
// WindowControlHook.m puts this view on _NSThemeWidget and calls gg_wc_update when AppKit updates the bezel.
import AppKit
import SwiftUI

private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color.Resolved {
    Color.Resolved(colorSpace: .sRGB, red: Float(r / 255), green: Float(g / 255), blue: Float(b / 255), opacity: Float(a))
}
private func white(_ w: Double, _ a: Double = 1) -> Color.Resolved { rgb(w * 255, w * 255, w * 255, a) }

enum GGWCVariant: Int { case close, minimize, zoom }

/// Colors measured from 27 (sRGB).
struct GGWCColors: Hashable {
    var variant: GGWCVariant, isDark: Bool, isDimmed: Bool, isGraphite: Bool

    var fill: Color.Resolved {   // 3.1
        if isDimmed { return white(isDark ? 0.1373 : 0.8627) }
        if isGraphite { return rgb(65, 72, 79) }
        switch variant {
        case .close: return rgb(255, 16, 0)
        case .minimize: return rgb(255, 141, 0)
        case .zoom: return rgb(60, 181, 0)
        }
    }
    var gradient: (Color.Resolved, Color.Resolved) {   // from the top edge down to 75% of the height
        if isDimmed { return isDark ? (white(0.98, 0.2), white(0.937, 0.16)) : (rgb(228, 228, 239, 0.3), rgb(224, 224, 235, 0.3)) }
        if isGraphite { return isDark ? (rgb(222, 223, 224, 0.58), rgb(222, 223, 224, 0.52)) : (rgb(222, 223, 224), rgb(227, 228, 230)) }
        switch (variant, isDark) {
        case (.close, true): return (rgb(250, 106, 97), rgb(239, 105, 98))
        case (.close, false): return (rgb(255, 109, 99), rgb(245, 114, 105, 0.8))
        case (.minimize, true): return (rgb(250, 181, 26), rgb(254, 207, 52))
        case (.minimize, false): return (rgb(251, 179, 22, 0.92), rgb(255, 209, 52, 0.92))
        case (.zoom, true): return (rgb(86, 200, 58), rgb(82, 196, 61))
        case (.zoom, false): return (rgb(90, 207, 31), rgb(121, 211, 76, 0.73))
        }
    }
    var rim: Color.Resolved {   // dark rim of highlight A (light appearance)
        if isDimmed { return white(0) }
        if isGraphite { return rgb(91, 92, 97) }
        switch variant {
        case .close: return rgb(203, 0, 0)
        case .minimize: return rgb(192, 94, 0)
        case .zoom: return rgb(42, 127, 0)
        }
    }
    var shadowOpacity: Float {   // G3
        if isGraphite { return isDark ? 0.3 : 0.24 }
        if !isDark { return isDimmed ? 0.5 : 0.3 }
        if isDimmed { return 0.1 }
        return variant == .close ? 0.4 : 0.54
    }
    /// 27 glyph color (0x195e3c790): a dark color per variant, then .opacity(0.7) and plusDarker blend over the light body.
    var glyph: Color {
        if isDimmed { return Color.black.opacity(0.4) }
        if isGraphite { return Color(.sRGB, red: 0.38, green: 0.42, blue: 0.459) }
        switch variant {
        case .close: return Color(.sRGB, red: isDark ? 0.55 : 0.639, green: 0, blue: 0)
        case .minimize: return isDark ? Color(.sRGB, red: 0.65, green: 0.228, blue: 0) : Color(.sRGB, red: 0.756, green: 0.27, blue: 0)
        case .zoom: return isDark ? Color(.sRGB, red: 0.18, green: 0.45, blue: 0) : Color(.sRGB, red: 0.213, green: 0.533, blue: 0)
        }
    }
}

struct GGWCGradientFill: _Material_CustomFillProvider {
    var c0: Color.Resolved, c1: Color.Resolved
    func makeCALayer() -> CALayer? { let g = CAGradientLayer(); updateCALayer(g); return g }
    func updateCALayer(_ layer: CALayer) {
        guard let g = layer as? CAGradientLayer else { return }
        g.colors = [c0.cgColor, c1.cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 0.75)
    }
    func draw(in context: inout GraphicsContext, bounds: CGRect) {
        context.fill(Path(bounds), with: .linearGradient(Gradient(colors: [Color(c0), Color(c1)]),
            startPoint: CGPoint(x: bounds.midX, y: bounds.minY), endPoint: CGPoint(x: bounds.midX, y: bounds.minY + 0.75 * bounds.height)))
    }
}

/// Layer stack of 27 WindowControlMaterialProvider.resolveLayers (0x195f78670):
/// [sdf(G1).opacity(k), sdf(group[G2 gradient, highlight, G3 plusDarker].mask(circle))]. There is no solid fill layer:
/// the fill is only the color of G1/G3, so the gradient (alpha < 1 in the light appearance) lets the titlebar show through.
struct GGWindowControlMaterialProvider: MaterialProvider {
    var colors: GGWCColors

    func resolveLayers(in context: Material.Context) -> [Material.Layer] {
        typealias S = Material.Layer.SDFLayer
        typealias G = Material.Layer.SDFLayer.GroupLayer
        let c = colors, fill = c.fill, w = white(1)
        func ring(_ col: Color.Resolved, _ r: CGFloat, _ dy: CGFloat) -> S {
            S.group(type: .compositing, layers: [
                G(S.shadow(inset: 0, color: col, radius: r, offset: CGSize(width: 0, height: dy), knockout: false, inverted: false), blend: .mode(.normal), opacity: 1),
                G(S.shadow(inset: 1, color: col, radius: r, offset: CGSize(width: 0, height: dy), knockout: false, inverted: false), blend: .mode(.destinationOut), opacity: 1),
            ], filters: [.gaussianBlur(radius: r, isOpaque: false, isDithered: false)])
        }
        // G1: fill colored rim offset down 1 pt (colored shadow at the bottom), outer layer without mask; light appearance only.
        let g1 = ring(fill, 1, 1)
        let g1Opacity = c.isGraphite ? 0.1 : (c.isDark || c.isDimmed ? 0 : 0.2)
        let (gs, ge) = c.gradient
        let g2 = G(S.customFill(GGWCGradientFill(c0: gs, c1: ge)), blend: .mode(.normal), opacity: 1)
        let g3 = G(ring(c.isDimmed ? (c.isDark ? white(0) : white(0.702)) : fill, 2, 4), blend: .mode(.plusDarker), opacity: c.shadowOpacity)
        // Highlight (0x195f7a558 light / 0x195f7acf8 dark): key/fill highlight drawn with backdropAwareColorMatrix (recolors
        // the body underneath: light darkens into colored side rims, dark brightens into top/bottom streaks), clipped to a
        // 0.7 pt rim, the whole group blended hardLight (light) or normal (dark) over the gradient.
        // Two places where 26.6 draws differently from 27 (measured):
        // - CASDFKeyFillHighlightEffect draws nothing (even when calling QuartzCore directly). The sdf_key_fill_highlight
        //   shader = sum of two sdf_glass_highlight with the same formula, and the key/fill angle ranges do not overlap, so two
        //   glassHighlight_v2 (CASDFGlassHighlightEffect, curvature 0 = solid band like KeyFill) are used. GlassHighlight
        //   spread is a half angle (threshold cos(spread)), 27 KeyFill spread is the full angle: pass spread/2 (compared with
        //   27 screenshots: rim only on the sides/top and bottom).
        // - SDFLayer.color(_:inset:) ignores inset (effectOffset 0), so the 27 destinationOut "inset 0.7" clip layer erases
        //   the whole rim. The 27 band = [27 inset (-1/-0.5, negative is outward, the part outside the disc is masked off),
        //   height 2] intersected with the rim [0, 0.7]: build the band [27 inset, inner edge] directly. The inner edge uses
        //   0.9 instead of 0.7: 26.6 SDF edge AA is off by half a pixel, and 0.9 gives the 2x pixel profile closest to real 27
        //   screenshots (measured).
        func keyFill(inset: CGFloat, color: Color.Resolved, key: Double, fill: Double, spread: Double, amount: CGFloat) -> S {
            func one(_ a: Double) -> G {
                G(S.glassHighlight_v2(inset: inset, color: Color.ResolvedHDR(color), height: 0.9 - inset, angle: .radians(a), appliesDisplayAngle: false,
                                      curvature: 0, spread: .radians(spread / 2), amount: amount), blend: .mode(.normal), opacity: 1)
            }
            return S.group(type: .compositing, layers: [one(key), one(fill)], filters: [])
        }
        var m = _ColorMatrix()
        let h: S, outer: G.Blend
        if c.isDark {   // highlight B + M_B; 27 uses alpha 0.56 for screenSharing, 1 for normal lights
            h = keyFill(inset: -0.5, color: w, key: 0, fill: .pi, spread: 1.3962634, amount: 0.15)
            (m.m11, m.m12, m.m13, m.m15) = (0.947, -0.179, -0.018, 0.5)
            (m.m21, m.m22, m.m23, m.m25) = (-0.053, 0.821, -0.018, 0.5)
            (m.m31, m.m32, m.m33, m.m35) = (-0.053, -0.179, 0.982, 0.5)
            outer = .mode(.normal)
        } else {        // highlight A + M_A; dimmed: black α 0.5, amount 0.2; normal: rim color, amount 0.1567
            h = keyFill(inset: -1, color: c.isDimmed ? white(0, 0.5) : c.rim, key: .pi / 2, fill: 3 * .pi / 2, spread: 2.0943951,
                        amount: c.isDimmed ? 0.2 : 0.1567)
            (m.m11, m.m12, m.m13) = (0.841, -0.536, -0.054)
            (m.m21, m.m22, m.m23) = (-0.159, 0.464, -0.054)
            (m.m31, m.m32, m.m33) = (-0.16, -0.536, 0.946)
            outer = .mode(.hardLight)
        }
        let highlight = G(S.group(type: .compositing, layers: [
            G(h, blend: .backdropAwareColorMatrix(m), opacity: 1),
        ], filters: []), blend: outer, opacity: 1)
        let body = S.group(type: .compositing, layers: [g2, highlight, g3], filters: [])
        return [Material.Layer.sdf(g1).opacity(g1Opacity), .sdf(body.mask(S.color(w, inset: 0)))]
    }
}

final class GGWCModel: ObservableObject {
    @Published var variant = GGWCVariant.close
    @Published var glyph = "WindowControls/Close"
    @Published var state = 0          // NSControlInteractionState measured on 26.6: 0 normal, 1 disabled, 2 pressed, 4 rollover
    @Published var active = true
    @Published var obscured = false
    @Published var size: CGFloat = 14
    /// Drag gesture in progress (nil when not held): t = mouse translation, b = the part of the translation still inside
    /// the light frame (27 FlexValue.ResolvedLocalGesture, 0x190c20ae4), in SwiftUI axes (y down).
    @Published var drag: GGWCDrag?
}

struct GGWCDrag: Equatable { var t = CGSize.zero, b = CGSize.zero }

/// 27 windowControl FlexInteraction transform (FlexValue.applyInteraction 0x190c225d0, Settings.windowControl):
/// lift s = (m + 2)/m; per axis k = (|t| - |b|)/D + |b|/(4D), D = 3825.649, that axis +k, the other -k, drift sign(t)·k·side.
struct GGWCFlex: Equatable {
    var sx: CGFloat = 1, sy: CGFloat = 1, dx: CGFloat = 0, dy: CGFloat = 0
    init() {}
    init(size w: CGFloat, drag: GGWCDrag) {
        let D: CGFloat = 3825.649
        func k(_ t: CGFloat, _ b: CGFloat) -> CGFloat { (abs(t) - abs(b)) / D + abs(b) / (4 * D) }
        let kx = k(drag.t.width, drag.b.width), ky = k(drag.t.height, drag.b.height), s = (w + 2) / w
        sx = s + kx - ky; sy = s + ky - kx
        dx = (drag.t.width < 0 ? -kx : kx) * w; dy = (drag.t.height < 0 ? -ky : ky) * w
    }
}

private let designLibrary = Bundle(path: "/System/Library/PrivateFrameworks/DesignLibrary.framework")
private var glyphCache: [String: NSImage] = [:]
private func glyphImage(_ name: String) -> NSImage? {
    if let i = glyphCache[name] { return i }
    let i = designLibrary?.image(forResource: name)
    glyphCache[name] = i
    return i
}

struct GGWindowControl: View {
    @ObservedObject var model: GGWCModel
    @Environment(\.colorScheme) var scheme

    // 27 FlexInteraction follows the mouse gesture (held even when dragged outside the button, after AppKit dropped the
    // pressed state); state 2 covers events that do not pass the local monitor.
    var pressed: Bool { model.state == 2 || model.drag != nil }
    // Measured 26.6 states: 0 normal, 1 disabled, 2 pressed, 4 mouse inside the light group (rollover). Glyphs show on press/rollover.
    var revealGlyph: Bool { model.state == 2 || model.state == 4 }
    // 27 isDimmed (0x195e3a120): disabled, or normal state with an inactive window; press/rollover shows color.
    var dimmed: Bool { model.state == 1 || (model.state == 0 && !model.active) }
    var flex: GGWCFlex { pressed && model.size < 26 ? GGWCFlex(size: model.size, drag: model.drag ?? GGWCDrag()) : GGWCFlex() }

    var body: some View {
        let colors = GGWCColors(variant: model.variant, isDark: scheme == .dark, isDimmed: dimmed,
                                isGraphite: (UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int) == -1)
        let mat = Material(provider: GGWindowControlMaterialProvider(colors: colors))
        ZStack {
            Color.clear.materialEffect(mat, in: _ShapeSet(elements: [_ShapeSet.Element(Capsule(), tags: _ShapeSet.Tags(rawValue: .max))], smoothness: 0))
            if let img = glyphImage(model.glyph) {
                Image(nsImage: img).renderingMode(.template).foregroundStyle(colors.glyph.opacity(0.7).blendMode(.plusDarker))
                    .opacity(revealGlyph ? 1 : 0)
                    .animation(.spring(response: 0.1, dampingFraction: 1), value: revealGlyph)
            }
        }
        .frame(width: model.size, height: model.size)
        // windowControl FlexInteraction: lift 2 pt + stretch/drift with the drag (GGWCFlex), tracking 0.1/1.0 while held,
        // release spring 0.355/0.4 (bouncy); 27 only enables it when controlSize < large.
        .scaleEffect(x: flex.sx, y: flex.sy)
        .offset(x: flex.dx, y: flex.dy)
        .animation(pressed ? .spring(response: 0.1, dampingFraction: 1) : .spring(response: 0.355, dampingFraction: 0.4), value: flex)
        .opacity(model.obscured ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class GGWCHost: NSHostingView<GGWindowControl> {
    let model: GGWCModel
    var start: NSPoint?
    init(model: GGWCModel) { self.model = model; super.init(rootView: GGWindowControl(model: model)) }
    required init(rootView: GGWindowControl) { model = rootView.model; super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

/// FlexInteraction gesture, taken from the _NSThemeWidgetCell tracking loop (WindowControlHook.m): phase 0 begin,
/// 1 drag, 2 end; p in host coordinates. The button tracking loop runs until mouse up, even when dragged outside.
@_cdecl("gg_wc_drag") public func ggWCDrag(_ v: NSView, _ p: NSPoint, _ phase: Int) {
    guard let h = v as? GGWCHost else { return }
    if ggTrace { print("TRACE wc drag \(h.model.variant) phase \(phase) p \(p)") }
    switch phase {
    case 0: h.start = p; h.model.drag = GGWCDrag()
    case 1:
        guard let s = h.start else { return }
        let bx = min(max(p.x, 0), h.bounds.width) - s.x, by = min(max(p.y, 0), h.bounds.height) - s.y
        let f: CGFloat = h.isFlipped ? 1 : -1   // to SwiftUI axes (y down)
        let d = GGWCDrag(t: CGSize(width: p.x - s.x, height: (p.y - s.y) * f), b: CGSize(width: bx, height: by * f))
        if h.model.drag != d { h.model.drag = d }
    default: h.start = nil; if h.model.drag != nil { h.model.drag = nil }
    }
}

@_cdecl("gg_wc_make") public func ggWCMake() -> NSView { GGWCHost(model: GGWCModel()) }

/// zoomKind: 0 zoom, 1 enter full screen, 2 exit full screen.
@_cdecl("gg_wc_update") public func ggWCUpdate(_ v: NSView, _ buttonID: Int, _ edited: Bool, _ obscured: Bool,
                                               _ state: Int, _ active: Bool, _ zoomKind: Int) {
    guard let m = (v as? GGWCHost)?.model else { return }
    let variant: GGWCVariant = buttonID == 25 ? .close : buttonID == 26 ? .minimize : .zoom
    let glyph: String
    switch variant {
    case .close: glyph = edited ? "WindowControls/CloseUnsaved" : "WindowControls/Close"
    case .minimize: glyph = "WindowControls/Minimize"
    case .zoom: glyph = ["WindowControls/Zoom", "WindowControls/FullScreenEnter", "WindowControls/FullScreenExit"][max(0, min(2, zoomKind))]
    }
    let size = min(v.bounds.width, v.bounds.height)
    if m.variant != variant { m.variant = variant }
    if m.glyph != glyph { m.glyph = glyph }
    if m.state != state { m.state = state; if ggTrace { print("TRACE wc id \(buttonID) state \(state) t=\(ProcessInfo.processInfo.systemUptime)") } }
    if m.active != active { m.active = active }
    if m.obscured != obscured { m.obscured = obscured }
    if size > 0 && m.size != size { m.size = size }
}

@_silgen_name("gg_wc_hook") func ggWCHook() -> Bool
private var wcInstalled = false
@_cdecl("gg_wc_install") public func ggWCInstall() {
    guard !wcInstalled else { return }
    wcInstalled = true
    ggLog("traffic lights: \(ggWCHook() ? "hooked" : "could not hook (missing class/selector)")")
}
