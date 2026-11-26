// The island window: shape springs (IslandAnimator, window-free) and IslandPanel, which draws the 27.3 shape with
// CAShapeLayers and drives it from a display link that is paused whenever nothing moves.
import AppKit
import QuartzCore

/// centerHUD.transitions.contentBlurRadius.
private let contentBlurRadius = 16.666

/// The new state presents the very views already shown (same instances, same order): the primary is steady and only the
/// adjunct zone transitions (RE 22.25 (2)), so the content keeps its container, alpha and scale.
func keepsPresentedContent(_ views: [NSView], shown: [NSView]) -> Bool {
    !views.isEmpty && views.count == shown.count && zip(views, shown).allSatisfy { $0 === $1 }
}

/// Mitosis background (CenterHUDMultiZoneMitosisBackgroundViewsComponent, sub_1001a85c8): the black fills of primary and
/// adjunct share one container filtered by gaussianBlur (mitosis.blurRadius while mitosis / recombination runs, else 0;
/// fcsel at 0x1001a8940) then alphaThreshold 0.5 (0x1001a898c), so close fills join with a neck [V].
enum Metaball {
    static let blurRadius = 6.6667   // centerHUD.mitosis.blurRadius
    static let threshold = 0.5
    /// Blur, then alpha -> threshold + k (alpha - threshold) clamped to 0...1, k making the edge about one pixel wide
    /// (slope of a blurred straight edge is 1 / (sqrt(2 pi) sigma)) [I: the private alphaThreshold filter's softness].
    static func filters(scale: CGFloat) -> [CIFilter] {
        let k = (2 * Double.pi).squareRoot() * blurRadius * Double(scale)
        let blur = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": blurRadius])!
        let matrix = CIFilter(name: "CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
                                                                 "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: threshold * (1 - k))])!
        return [blur, matrix, CIFilter(name: "CIColorClamp")!]
    }
}

extension PrivacyIndicatorMetrics {
    /// The dot layer: diameter d, radius d / 2 or 0 (MediaLayer _dotLayer), sRGB colour of the kind [V]. The
    /// contrastBorderLayer is not drawn: the dot always sits on the black island here [I].
    static func style(_ l: CALayer, kind: PrivacyIndicatorKind, diameter d: CGFloat, dark: Bool, differentiateWithoutColor: Bool) {
        let c = kind.rgb(dark: dark)
        l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        l.cornerRadius = isSquare(kind, differentiateWithoutColor: differentiateWithoutColor) ? 0 : d / 2
        l.backgroundColor = CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

/// 27.3 FluidSpring step (sub_10020ce5c family): exact damped-oscillator solution, omega0 = 2π / response,
/// beta = dampingRatio * omega0; under-, critically and over-damped regimes. Retargeting keeps value and velocity.
struct FluidSpring {
    var value: Double
    var velocity: Double

    mutating func step(to target: Double, response: Double, damping: Double, dt: Double) {
        guard dt > 0 else { return }
        let w0 = 2 * Double.pi / response, beta = damping * w0, dx = value - target, e = exp(-beta * dt)
        if damping < 1 {
            let wd = w0 * (1 - damping * damping).squareRoot(), a = dx, b = (velocity + beta * dx) / wd
            let c = cos(wd * dt), s = sin(wd * dt)
            value = target + e * (a * c + b * s)
            velocity = e * (-beta * (a * c + b * s) + wd * (b * c - a * s))
        } else if damping == 1 {
            let b = velocity + beta * dx
            value = target + e * (dx + b * dt)
            velocity = e * (b - beta * (dx + b * dt))
        } else {
            let wd = w0 * (damping * damping - 1).squareRoot(), a = dx, b = (velocity + beta * dx) / wd
            let c = cosh(wd * dt), s = sinh(wd * dt)
            value = target + e * (a * c + b * s)
            velocity = e * (-beta * (a * c + b * s) + wd * (b * c + a * s))
        }
    }

    // ponytail: [?] 27.3 keeps its epsilon in the solver state (+0x28); 0.001 pt / 0.01 pt/s until it is read.
    func settled(target: Double) -> Bool { abs(value - target) <= 0.001 && abs(velocity) <= 0.01 }
}

/// One spring-driven scalar with its own target and parameters; snaps to the target once settled.
struct Tween {
    var spring: FluidSpring
    var target: Double
    var response = Springs.transition.response, damping = Springs.transition.damping

    init(_ v: Double) { spring = FluidSpring(value: v, velocity: 0); target = v }
    var value: Double { spring.value }

    mutating func set(_ t: Double, response r: Double, damping d: Double) { target = t; response = r; damping = d }

    /// Returns true when settled.
    mutating func step(_ dt: Double) -> Bool {
        if spring.settled(target: target) { spring = FluidSpring(value: target, velocity: 0); return true }
        spring.step(to: target, response: response, damping: damping, dt: dt)
        return false
    }
}

/// Five springs (midX, maxY, width, height, corner radius); settles exactly on the target.
struct IslandAnimator {
    private var springs: [FluidSpring]
    private var target: [Double]
    private var targetShape: IslandShape
    private(set) var current: IslandShape
    private(set) var isSettled = true
    private var response = Springs.transition.response, damping = Springs.transition.damping

    private static func values(_ s: IslandShape) -> [Double] {
        [s.frame.midX, s.frame.maxY, s.frame.width, s.frame.height, s.cornerRadius]
    }

    init(_ s: IslandShape) {
        target = Self.values(s)
        springs = target.map { FluidSpring(value: $0, velocity: 0) }
        targetShape = s
        current = s
    }

    var targetFrame: CGRect { targetShape.frame }

    /// Default: centerHUD.transitions.spring. Retargeting keeps value and velocity.
    mutating func setTarget(_ s: IslandShape, response: Double = Springs.transition.response, damping: Double = Springs.transition.damping) {
        self.response = response
        self.damping = damping
        guard s != targetShape || !isSettled else { return }
        targetShape = s
        target = Self.values(s)
        isSettled = false
    }

    mutating func step(_ dt: Double) -> IslandShape {
        guard !isSettled else { return current }
        for i in springs.indices { springs[i].step(to: target[i], response: response, damping: damping, dt: dt) }
        if springs.indices.allSatisfy({ springs[$0].settled(target: target[$0]) }) {
            springs = target.map { FluidSpring(value: $0, velocity: 0) }
            current = targetShape
            isSettled = true
        } else {
            let v = springs.map(\.value)
            current = IslandShape(frame: CGRect(x: v[0] - v[2] / 2, y: v[1] - v[3], width: v[2], height: v[3]), cornerRadius: v[4])
        }
        return current
    }
}

/// Adjunct container motion (mitosis / recombination), window-free. `reveal` 0 = the hidden frame under the primary's tail
/// (adjunctHidden: half size, centred on the right end), 1 = its own capsule interContainerPadding past the primary.
/// `.follows` takes both from the primary's animated shape every frame (FOOTAGE-MAC-PROLED 5c: the circle buds from the
/// centre of the right end, rides a growing body out of its top-right corner, drifts with the primary's right end while it
/// settles, and slides into the tail on recombination) [I: the binary's adjunct layout guide is not read].
/// `.fixed` holds one frame while an expanded body covers it: swallowed in place on a tap on the primary, back at full
/// size at once when that body collapses (5b, 5c.3).
struct AdjunctMotion {
    enum Anchor: Equatable { case follows, fixed(IslandShape) }
    private(set) var anchor: Anchor
    private(set) var reveal: Tween
    let content: CGSize

    /// Mitosis toward the primary `target`, from `current` (the primary on screen now). `old`: the same view's motion.
    init(dividing old: AdjunctMotion?, content: CGSize, target: IslandShape, current: IslandShape, in g: IslandGeometry, response: Double) {
        let final = g.adjunct(after: target, content: content)
        self.content = content
        if current.covers(final) {
            anchor = .fixed(final)
            reveal = Tween(1)
        } else {
            anchor = .follows
            // An interrupted recombination turns around with its velocity; a swallowed one comes back at full size.
            if let o = old, case .follows = o.anchor { reveal = o.reveal } else { reveal = Tween(old == nil ? 0 : 1) }
        }
        reveal.set(1, response: response, damping: Springs.transition.damping)
    }

    /// Recombination: into the tail of the primary, or held in place when `target` will cover it.
    mutating func recombine(target: IslandShape, current: IslandShape, in g: IslandGeometry, response: Double) {
        let s = shape(primary: current, in: g)
        if target.covers(s) { anchor = .fixed(s) }
        else if case .fixed = anchor { anchor = .follows; reveal = Tween(1) }
        reveal.set(0, response: response, damping: Springs.transition.damping)
    }

    /// Returns true when settled. A revealed fixed adjunct follows `primary` (on screen now, unhovered) from the frame its
    /// following place reaches it: the shrinking body's right end is back at interContainerPadding, so it rides the
    /// primary's undershoot instead of opening the gap (FOOTAGE-MAC-PROLED 5c.3: both drift left 6 px after the break).
    mutating func step(_ dt: Double, primary: IslandShape, in g: IslandGeometry) -> Bool {
        let settled = reveal.step(dt)
        if reveal.target == 1, case .fixed(let s) = anchor, g.adjunct(after: primary, content: content).frame.minX <= s.frame.minX {
            anchor = .follows
        }
        return settled
    }

    /// Out in its own capsule at the full gap: nothing left for the mitosis metaball to join, and its blur would only
    /// shrink both ends (about sigma^2 / 2R = 1.3 pt each) for the rest of the settle.
    var isApart: Bool { anchor == .follows && reveal.target == 1 && reveal.value >= 1 }

    func shape(primary: IslandShape, in g: IslandGeometry) -> IslandShape {
        if case .fixed(let s) = anchor { return s }
        let to = g.adjunct(after: primary, content: content), from = g.adjunctHidden(to), k = CGFloat(reveal.value)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return IslandShape(frame: CGRect(x: mix(from.frame.minX, to.frame.minX), y: mix(from.frame.minY, to.frame.minY),
                                         width: mix(from.frame.width, to.frame.width), height: mix(from.frame.height, to.frame.height)),
                           cornerRadius: mix(from.cornerRadius, to.cornerRadius))
    }
}

enum IslandState {
    case inert
    case compact(leading: NSView, trailing: NSView?)
    case minimal(NSView, edge: HorizontalEdge = .leading)   // AV module: .trailing (Metrics minimal)
    /// Two containers (mitosis): primary = leading minimal with hasAdjunctZone, adjunct = minimal content in its own
    /// capsule interContainerPadding past it (Metrics adjunct). The adjunct view's frame size is its content size.
    case split(primary: NSView, adjunct: NSView)
    /// `adjunct`: an activity kept in its own capsule interContainerPadding past the expanded body, top edges equal (the
    /// displaced primary after a tap on the adjunct, FOOTAGE-MAC-PROLED 5c.1).
    case expanded(NSView, size: CGSize?, type: ExpandedType?, shape: ShapePreference = .systemBanner, adjunct: NSView? = nil)

    var adjunctView: NSView? {
        switch self {
        case let .split(_, a): a
        case let .expanded(_, _, _, _, a): a
        default: nil
        }
    }
}

/// Non-activating panel at the top center of a screen, above the menu bar and below menus. The inert state is the
/// sensor-sized idle pill (like the PROLED hardware island), hidden with IdleHide once settled there
/// unless GGIsland.showWhenIdle is set.
final class IslandPanel: NSPanel {
    private(set) var geometry: IslandGeometry
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    enum DragPhase { case began, changed, ended }
    /// Mouse down/drag/up inside the island, in the coordinates of the current content view.
    var onDrag: ((CGPoint, DragPhase) -> Void)?
    private(set) var expandedType: ExpandedType?
    private(set) var zone: Zone = .inert

    private enum Anchor { case leading(CGFloat), trailing(CGFloat), center }
    private let island = IslandView()
    private let background = CAShapeLayer()
    private let keyLine = CAShapeLayer()       // ring shape, used as the mask of keyLineGroup
    private let keyLineGroup = CALayer()
    /// Incoming and outgoing content live in separate containers so each can carry its own transform (27.3 keeps one
    /// CenterHUDZoneContentItemModel { geometry, blurRadius, opacity, affineTransform } per item); each is masked to the island.
    private final class ContentLayer {
        let view = NSView(), mask = CAShapeLayer()
        var scale = Tween(1)
    }
    private var front = ContentLayer(), back = ContentLayer()   // front: incoming, back: outgoing
    private var animator: IslandAnimator
    private var fade = Tween(1)
    private var hoverScale = Tween(1), leanX = Tween(0), leanY = Tween(0)
    private var keyLineAlpha = Tween(0), shadowAlpha = Tween(0)
    /// User hide when idle (IdleHide): whether the black fill is hidden or hiding, and the time since that last changed.
    private var hidden = false, hideTime = IdleHide.duration
    private var pointer: CGPoint?            // screen point while the pointer is over the island
    private var followsShape = false         // in-place resize: centered content is sized to the current shape each frame
    private var incoming: [(NSView, Anchor)] = []
    private var outgoing: [(NSView, Anchor)] = []
    /// Adjunct container: own shape spring, content alpha/blur (mitosis.blurRadius) and whether it is recombining.
    private struct Adjunct {
        var view: NSView
        var motion: AdjunctMotion
        var fade = Tween(0)
        var leaving = false
    }
    private var adjunct: Adjunct?
    /// Metaball fill while mitosis / recombination runs (Metaball); background then draws the shadow only.
    private let blob = CAShapeLayer()
    private var mitosis = false
    /// throughInert second leg: the state to grow into once the collapse from `startWidth` passes collisionProgress.
    private var pending: (state: IslandState, momentary: Bool, startWidth: CGFloat)?
    private var shown: IslandState = .inert   // last state passed to show, re-laid out when the privacy indicator changes
    /// Privacy indicator dot, fixed on screen at the sensor's maxX + 6 (WindowServer draws it there on 27.3).
    private let privacyDot = CALayer()
    private let privacyDiameter: CGFloat
    private var privacyExit: DispatchWorkItem?
    private var link: CADisplayLink!
    private var lastTimestamp: CFTimeInterval?

    var isIdle: Bool { link.isPaused }
    /// Display-link intervals of animated frames (demo frame-pacing check).
    var frameIntervals: [Double] = []
    var currentShape: IslandShape { animator.current }
    /// What is on screen: the current shape with the hover scale and lean applied.
    var displayedShape: IslandShape {
        hovered(animator.current, scale: CGFloat(hoverScale.value), offset: CGPoint(x: leanX.value, y: leanY.value))
    }

    init(screen: NSScreen) {
        geometry = IslandGeometry(screen: screen.frame, scale: screen.backingScaleFactor)
        animator = IslandAnimator(geometry.inert)
        // Density of the real panel (SkyLight keys the table on points per inch; no physical size gives 5).
        let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        privacyDiameter = PrivacyIndicatorMetrics.diameter(pointsPerInch: PrivacyIndicatorMetrics.pointsPerInch(
            points: screen.frame.size, millimeters: display.map { CGDisplayScreenSize($0) } ?? .zero))
        let size = CGSize(width: 520, height: 480)   // squareLarge (430 x 423) + offsets + shadow
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        island.wantsLayer = true
        island.frame = CGRect(origin: .zero, size: size)
        island.panel = self
        // Software background: gainMapMode automatic resolves to software on a display without the hardware style
        // (sub_100202d80); HIG: "Live Activities in the Dynamic Island use a black opaque background".
        background.fillColor = NSColor.black.cgColor
        background.shadowColor = NSColor.black.cgColor
        background.shadowOpacity = 0
        island.layer!.addSublayer(background)
        island.layerUsesCoreImageFilters = true
        blob.frame = island.bounds   // filters render within the layer's bounds
        blob.fillColor = NSColor.black.cgColor
        blob.filters = Metaball.filters(scale: screen.backingScaleFactor)
        island.layer!.addSublayer(blob)
        // Key line = lighten of #262626 over what is behind the window (Apple's kit; 27.3 draws it inside a backdrop
        // group). A compositing filter alone only sees this window's transparent backing, so the ring holds a
        // CABackdropLayer (private, windowServerAware: a copy of the screen behind) with the lighten layer above it.
        keyLine.fillColor = NSColor.black.cgColor
        keyLine.fillRule = .evenOdd
        keyLineGroup.mask = keyLine
        keyLineGroup.opacity = 0
        if let backdrop = keyLineBackdrop {
            backdrop.frame = island.bounds
            keyLineGroup.addSublayer(backdrop)
        }
        let lighten = CALayer()
        lighten.frame = island.bounds
        lighten.backgroundColor = NSColor(srgbRed: KeyLine.lightenGray, green: KeyLine.lightenGray, blue: KeyLine.lightenGray, alpha: 1).cgColor
        lighten.compositingFilter = "lightenBlendMode"
        keyLineGroup.addSublayer(lighten)
        keyLineGroup.frame = island.bounds
        island.layer!.addSublayer(keyLineGroup)
        for c in [back, front] {
            c.view.frame = island.bounds
            c.view.wantsLayer = true
            c.view.layerUsesCoreImageFilters = true
            c.view.layer!.mask = c.mask
            island.addSubview(c.view)
        }
        privacyDot.opacity = 0
        island.layer!.addSublayer(privacyDot)   // above the content containers
        contentView = island
        // AppKit turns on WindowServer's behind-window capture for a window only while it shows an NSVisualEffectView
        // (.behindWindow); the key line backdrop joins that capture group. Measured in IslandDemo keyline-idle: alpha 0
        // turns the capture off again, and WindowServer draws the material above the black background whatever the
        // layer order (a 1 px dot of 38/255), so 1 x 1 pt at alpha 0.01 at the centre of the idle pill (reads 0).
        // hitTest never returns subviews.
        let inert = geometry.inert.frame
        let capture = NSVisualEffectView(frame: CGRect(x: inert.midX - frame.minX, y: inert.midY - frame.minY, width: 1, height: 1))
        capture.blendingMode = .behindWindow
        capture.state = .active
        capture.alphaValue = 0.01
        island.addSubview(capture, positioned: .below, relativeTo: nil)

        link = island.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        hidden = idleHidden(.inert, showWhenIdle: showsIdlePill(), settled: true)
        render(animator.current)
    }

    private func setHidden(_ h: Bool) {
        guard h != hidden else { return }
        hidden = h
        hideTime = 0
    }

    /// A copy of the screen behind the window (private CABackdropLayer) in the behind-window capture group that
    /// NSVisualEffectView's backdrop uses (groupName and groupNamespace read at run time on 26.6). With
    /// windowServerAware alone nothing is captured: the copy only showed while the window committed every frame and
    /// read black in ControlCenter once it stopped (ring #262626 over the menu bar after each show).
    let keyLineBackdrop: CALayer? = {
        guard let b = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init() else { return nil }
        b.setValue(true, forKey: "windowServerAware")
        b.setValue("NSCGSWindowBehindWindowCaptureBackdropGroup", forKey: "groupName")
        b.setValue("hostingNamespacedContext", forKey: "groupNamespace")
        return b
    }()

    /// `momentary`: the element comes and goes on its own (HUD, banner); it arrives with
    /// transitionPolicy.momentaryArrivalResponseScale.
    /// `throughInert`: another element replaces the shown one (CenterHUDPrimaryZoneTransitionConfiguration.throughInert
    /// { from, to, waypoint }): collapse to the inert pill, then grow into `state` once the collapse passes
    /// Springs.collisionProgress [V mode and value, I when the resolver picks it: a different primary element].
    /// FOOTAGE-MAC-PROLED 5c: a tap on the adjunct and a split 1 -> 2 both pass the neutral (inert) pill this way, the
    /// fromInert leg starting about 0.20 s after the collapse starts; contents go dark first (Springs.mergeContentFade).
    func show(_ state: IslandState, momentary: Bool = false, throughInert: Bool) {
        guard throughInert, zone != .inert else { return show(state, momentary: momentary) }
        let start = animator.current.frame.width
        present(.inert, momentary: false, merging: true)
        pending = (state, momentary, start)
    }

    /// Shape, anchored views and zone of a state. Anchors are edge-relative, so they hold when only the shape changes.
    private func layout(_ state: IslandState) -> (target: IslandShape, views: [(NSView, Anchor)], zone: Zone) {
        switch state {
        case .inert:
            return (geometry.inert, [], .inert)
        case let .compact(leading, trailing):
            let l = geometry.compact(leading: leading.frame.width, trailing: trailing?.frame.width)
            var views: [(NSView, Anchor)] = [(leading, .leading(l.leadingX - l.shape.frame.minX))]
            if let trailing, let x = l.trailingX { views.append((trailing, .trailing(l.shape.frame.maxX - x))) }
            return (l.shape, views, .compact)
        case let .minimal(view, edge):
            let l = geometry.minimal(width: view.frame.width, edge: edge)
            return (l.shape, [(view, edge == .leading ? .leading(l.contentX - l.shape.frame.minX) : .trailing(l.shape.frame.maxX - l.contentX))], .minimal)
        case let .split(primary, _):
            let l = geometry.minimal(width: primary.frame.width, edge: .leading, hasAdjunct: true)
            return (l.shape, [(primary, .leading(l.contentX - l.shape.frame.minX))], .minimal)
        case let .expanded(view, size, type, shape, _):
            let l = geometry.expanded(content: size, type: type, preference: shape)
            view.setFrameSize(l.shape.frame.size)
            return (l.shape, [(view, .center)], .expanded(l.type))
        }
    }

    func show(_ state: IslandState, momentary: Bool = false) { present(state, momentary: momentary, merging: false) }

    /// `merging`: throughInert's toInert leg; the shown contents and the adjunct's go dark on Springs.mergeContentFade.
    private func present(_ state: IslandState, momentary: Bool, merging: Bool) {
        pending = nil
        shown = state
        let (target, views, z) = layout(state)
        zone = z
        if case .expanded(let t) = zone { expandedType = t } else { expandedType = nil }
        let t = Springs.transition
        let response = t.response * (momentary ? Springs.momentaryArrivalResponseScale : Springs.momentaryDepartureResponseScale)
        let s = zone.shadow
        background.shadowRadius = s.radius
        background.shadowOffset = CGSize(width: 0, height: -s.offsetY)
        shadowAlpha.set(Double(s.opacity), response: response, damping: t.damping)
        let k = zone == .inert ? KeyLine.disappearSpring : KeyLine.appearSpring
        keyLineAlpha.set(keyLineOpacity(zone), response: k.response, damping: k.damping)
        setHidden(idleHidden(zone, showWhenIdle: showsIdle, settled: false))

        // Content choreography (sub_10011a8a8, island-re): the new item is set at once to blur 16.666, opacity 0 and
        // scale min(old / new) (sub_10011c0c8), then springs to blur 0, opacity 1, identity on the transition spring;
        // the old item springs to blur 16.666, opacity 0 and the reverse scale [I reverse].
        let old = animator.current.frame.size, new = target.frame.size
        if keepsPresentedContent(views.map(\.0), shown: incoming.map(\.0)) {
            incoming = views   // same views: new anchors only, no swap, blur, fade or entry scale
        } else {
            for (v, _) in outgoing { v.removeFromSuperview() }
            outgoing = incoming
            incoming = views
            swap(&front, &back)   // the old front keeps its views and becomes the outgoing container
            followsShape = false  // a presented view keeps its final size; it scales in (entry scale) instead of reflowing
            back.scale.set(Double(contentEntryScale(from: new, to: old)), response: response, damping: t.damping)
            front.scale = Tween(Double(contentEntryScale(from: old, to: new)))
            front.scale.set(1, response: response, damping: t.damping)
            for (v, _) in incoming {
                v.alphaValue = 0
                front.view.addSubview(v)
                v.layoutSubtreeIfNeeded()   // presentation.stallDeadline: present only once the client content is laid out
                v.displayIfNeeded()
            }
            let m = Springs.mergeContentFade
            fade = Tween(0)
            fade.set(1, response: merging ? m.response : response, damping: merging ? m.damping : t.damping)
        }
        let current = animator.current
        animator.setTarget(target, response: response, damping: t.damping)
        if let view = state.adjunctView { divide(view, primary: target, current: current, response: response) }
        else { recombine(primary: target, current: current, response: response, merging: merging) }
        updateHover()
        wake()
    }

    /// Mitosis (CenterHUDAdjunctMitosisZoneModelComponent, AdjunctMotion): the adjunct buds from the primary's right end
    /// to its own capsule while its content clears from mitosis.blurRadius, or waits at full size under an expanded body
    /// that covers it. A new view starts its own mitosis; the same view turns an interrupted recombination around
    /// [I timing: same transition spring].
    private func divide(_ view: NSView, primary: IslandShape, current: IslandShape, response: Double) {
        let t = Springs.transition, same = adjunct?.view === view
        if !same { adjunct?.view.removeFromSuperview() }
        let motion = AdjunctMotion(dividing: same ? adjunct?.motion : nil, content: view.frame.size, target: primary,
                                   current: current, in: geometry, response: response)
        adjunct = Adjunct(view: view, motion: motion, fade: same ? adjunct!.fade : Tween(0))
        if view.superview !== island { view.alphaValue = 0; island.addSubview(view) }
        adjunct!.fade.set(1, response: response, damping: t.damping)
        mitosis = true
    }

    /// Recombination (AdjunctMotion.recombine): into the primary's tail (neck at mid height, a knob at the centre of the
    /// right end, absorbed), or swallowed in place by an expanded body that covers it; removed once settled.
    private func recombine(primary: IslandShape, current: IslandShape, response: Double, merging: Bool) {
        guard var a = adjunct, !a.leaving else { return }
        let t = Springs.transition, m = Springs.mergeContentFade
        a.motion.recombine(target: primary, current: current, in: geometry, response: response)
        a.fade.set(0, response: merging ? m.response : response, damping: merging ? m.damping : t.damping)
        a.leaving = true
        adjunct = a
        mitosis = true
    }

    /// Resizes expanded content in place (slider inflation): new shape target, same content view, no crossfade.
    /// Driven by the pointer, so it uses centerHUD.interaction.contentInteractionSpring.
    /// The content view then takes the animated shape's size every frame (one source of geometry: content and island ride
    /// the same resize spring; the content lays itself out from its own size).
    func reshape(expanded size: CGSize) {
        let l = geometry.expanded(content: size, type: nil, preference: .systemBanner)   // slider only
        followsShape = true
        let c = Springs.contentInteraction
        animator.setTarget(l.shape, response: c.response, damping: c.damping)
        wake()
    }

    /// Privacy indicators in use (camera, microphone, screen / system audio recording). Draws one dot (PrivacyIndicatorKind
    /// .shown) at the sensor's maxX + 6 and widens the inert pill and minimal views around it (27.3 MenuBarAgent). An
    /// empty set keeps the dot PrivacyIndicatorMetrics.exitHold, then fades it and shrinks to the indicator-free shape.
    func setPrivacyIndicators(_ kinds: Set<PrivacyIndicatorKind>) {
        privacyExit?.cancel()
        privacyExit = nil
        guard let kind = PrivacyIndicatorKind.shown(in: kinds) else {
            guard geometry.privacyIndicatorDiameter > 0 else { return }
            let exit = DispatchWorkItem { [weak self] in self?.removePrivacyIndicator() }
            privacyExit = exit
            DispatchQueue.main.asyncAfter(deadline: .now() + PrivacyIndicatorMetrics.exitHold, execute: exit)
            return
        }
        let appearing = geometry.privacyIndicatorDiameter == 0
        geometry.privacyIndicatorDiameter = privacyDiameter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Context.appearance is the menu bar's appearance; the app's effective appearance stands in for it [I].
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PrivacyIndicatorMetrics.style(privacyDot, kind: kind, diameter: privacyDiameter, dark: dark,
                                      differentiateWithoutColor: NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor)
        if let c = geometry.privacyIndicatorCenter { privacyDot.position = CGPoint(x: c.x - frame.minX, y: c.y - frame.minY) }
        privacyDot.removeAllAnimations()
        privacyDot.opacity = 1
        if appearing { fadePrivacyDot(from: 0, to: 1, delay: PrivacyIndicatorMetrics.appearDelay, duration: PrivacyIndicatorMetrics.appearDuration) }
        CATransaction.commit()
        if appearing { relayout() }
    }

    private func removePrivacyIndicator() {
        privacyExit = nil
        geometry.privacyIndicatorDiameter = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        privacyDot.opacity = 0
        fadePrivacyDot(from: 1, to: 0, delay: 0, duration: PrivacyIndicatorMetrics.exitFade)
        CATransaction.commit()
        relayout()
    }

    private func fadePrivacyDot(from: Float, to: Float, delay: Double, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.beginTime = CACurrentMediaTime() + delay
        a.duration = duration
        a.fillMode = .backwards
        privacyDot.add(a, forKey: "fade")
    }

    /// Retargets the shown state's shape after the indicator changed; content stays (edge-relative anchors). Expanded
    /// shapes ignore the indicator and may have been resized in place, so they are left alone.
    private func relayout() {
        if case .expanded = zone { return }
        let target = layout(shown).target, t = Springs.transition, current = animator.current
        animator.setTarget(target, response: t.response, damping: t.damping)
        if let view = shown.adjunctView { divide(view, primary: target, current: current, response: t.response) }
        setHidden(idleHidden(zone, showWhenIdle: showsIdle, settled: false))
        wake()
    }

    /// The idle pill stays visible while it holds a privacy indicator.
    private var showsIdle: Bool { showsIdlePill() || geometry.privacyIndicatorDiameter > 0 }

    private func wake() {
        lastTimestamp = nil
        link.isPaused = false
    }

    /// Hover scale and lean toward the pointer (centerHUD.interaction, contentInteractionSpring).
    private func updateHover() {
        let m = hoverMetrics(zone), c = Springs.contentInteraction
        let o = pointer.map { lean(pointer: $0, in: animator.targetFrame, maximum: m.lean) } ?? .zero
        hoverScale.set(pointer == nil ? 1 : Double(m.scale), response: c.response, damping: c.damping)
        leanX.set(Double(o.x), response: c.response, damping: c.damping)
        leanY.set(Double(o.y), response: c.response, damping: c.damping)
    }

    @objc private func tick(_ l: CADisplayLink) {
        let dt = lastTimestamp.map { min(max(l.timestamp - $0, 0), 1.0 / 30) } ?? l.duration
        if let last = lastTimestamp, frameIntervals.count < 600 { frameIntervals.append(l.timestamp - last) }   // bounded
        lastTimestamp = l.timestamp
        let shape = animator.step(dt)
        if let p = pending,
           collapseProgress(start: p.startWidth, current: shape.frame.width, inert: geometry.inert.frame.width) >= Springs.collisionProgress {
            show(p.state, momentary: p.momentary)
        }
        setHidden(idleHidden(zone, showWhenIdle: showsIdle, settled: animator.isSettled))
        hideTime = min(hideTime + dt, IdleHide.duration)
        let tweens = [fade.step(dt), hoverScale.step(dt), leanX.step(dt), leanY.step(dt), keyLineAlpha.step(dt), shadowAlpha.step(dt),
                      front.scale.step(dt), back.scale.step(dt), hideTime >= IdleHide.duration]
        var adjunctSettled = true
        if var a = adjunct {
            let moved = a.motion.step(dt, primary: shape, in: geometry)
            adjunctSettled = a.fade.step(dt) && moved
            adjunct = a
            if adjunctSettled && a.leaving { a.view.removeFromSuperview(); adjunct = nil }
        }
        // Blur back to 0 (sharp edges) at rest, or as soon as the adjunct is out at the full gap.
        if adjunctSettled && animator.isSettled || adjunct.map({ !$0.leaving && $0.motion.isApart }) == true { mitosis = false }
        render(shape)
        if animator.isSettled && !tweens.contains(false) && adjunctSettled {
            for (v, _) in outgoing { v.removeFromSuperview() }
            outgoing = []
            link.isPaused = true
        }
    }

    private func render(_ shape: IslandShape) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let local = IslandShape(frame: shape.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), cornerRadius: shape.cornerRadius)
        let k = CGFloat(hoverScale.value), offset = CGPoint(x: leanX.value, y: leanY.value)
        let shown = hovered(local, scale: k, offset: offset)
        let path = islandPath(shown)
        // IdleHide shrinks the black fill only: the key line and shadow are already 0 when idle, and the 1 pt capture
        // view must stay as it is to keep the key line backdrop alive.
        let f = IdleHide.factors(hideTime, hiding: hidden), sf = shown.frame
        let w = sf.width * f.w, h = sf.height * f.h
        var fill = f == (1, 1) ? path
            : islandPath(IslandShape(frame: CGRect(x: sf.midX - w / 2, y: sf.midY - h / 2, width: w, height: h), cornerRadius: min(w, h) / 2))
        // Adjunct capsule: drawn in the same black fill and key line, no hover transform of its own [I].
        let adj = adjunct.map { a -> IslandShape in
            let s = a.motion.shape(primary: shape, in: geometry)   // follows the unhovered primary
            return IslandShape(frame: s.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), cornerRadius: s.cornerRadius)
        }
        var hit = path
        if let adj {
            let both = CGMutablePath(), adjPath = islandPath(adj)
            both.addPath(fill); both.addPath(adjPath)
            fill = both
            let h2 = CGMutablePath(); h2.addPath(path); h2.addPath(adjPath); hit = h2
        }
        let joined = mitosis && adj != nil
        background.path = joined ? nil : fill
        background.shadowPath = fill
        // At rest the blob keeps a 1 pt square: blurred to alpha 1 / (2 pi sigma^2) < 0.004 it is cut by the threshold, but
        // the filters stay compiled, so the first merge does not stall (ControlCenter 2026-11-23: one 150 ms hold on the
        // first collapse after launch) [I cause: Core Image kernel compile on first use].
        blob.path = joined ? fill : CGPath(rect: CGRect(x: local.frame.midX, y: local.frame.midY, width: 1, height: 1), transform: nil)
        background.shadowOpacity = Float(max(shadowAlpha.value, 0))
        let t = KeyLine.thickness
        let ring = CGMutablePath()
        // The even-odd ring would cut through the primary while the adjunct is still under it: ring it once clear.
        let ringed = adj.flatMap { $0.frame.minX >= shown.frame.maxX ? [$0] : nil } ?? []
        for s in [shown] + ringed {
            ring.addPath(islandPath(IslandShape(frame: s.frame.insetBy(dx: -t, dy: -t), cornerRadius: s.cornerRadius + t)))
            ring.addPath(islandPath(s))
        }
        keyLine.path = ring
        // The key line is off during mitosis (12.3: restored at keyLine.mitosisRestorationProgress 0.7 [I: here at rest]),
        // so no ring cuts across the neck.
        keyLineGroup.opacity = joined ? 0 : Float(min(max(keyLineAlpha.value, 0), 1))
        island.hitPath = hidden ? nil : hit   // a hidden island takes no clicks or hover
        if let a = adjunct, let adj {
            let s = a.view.frame.size, p = min(max(a.fade.value, 0), 1)
            a.view.setFrameOrigin(CGPoint(x: adj.frame.midX - s.width / 2, y: adj.frame.midY - s.height / 2))
            a.view.alphaValue = p
            a.view.wantsLayer = true
            let blur = (1 - p) * Metaball.blurRadius
            a.view.layer?.filters = blur > 0.05 ? [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": blur])!] : nil
        }
        // Content is laid out on the unhovered shape, then scaled about its center by the hover scale and its item scale.
        for c in [front, back] {
            // sublayerTransform applies about the layer's anchor point; AppKit layers use (0, 0), not the center.
            guard let layer = c.view.layer else { continue }
            let anchor = CGPoint(x: layer.bounds.width * layer.anchorPoint.x, y: layer.bounds.height * layer.anchorPoint.y)
            let d = CGPoint(x: local.frame.midX - anchor.x, y: local.frame.midY - anchor.y), s = k * CGFloat(c.scale.value)
            let a = CGAffineTransform(translationX: d.x + offset.x, y: d.y + offset.y).scaledBy(x: s, y: s).translatedBy(x: -d.x, y: -d.y)
            layer.sublayerTransform = CATransform3DMakeAffineTransform(a)
            // The mask is transformed by sublayerTransform too: give it the island path in pre-transform space so it
            // clips to exactly the island on screen.
            var inverse = a.inverted()
            c.mask.path = path.copy(using: &inverse)
        }
        let p = min(max(fade.value, 0), 1)
        place(incoming, local.frame, alpha: p, followShape: followsShape)
        place(outgoing, local.frame, alpha: 1 - p, followShape: false)
        CATransaction.commit()
    }

    private func place(_ views: [(NSView, Anchor)], _ f: CGRect, alpha: Double, followShape: Bool) {
        let blur = (1 - alpha) * contentBlurRadius
        for (v, a) in views {
            if followShape, case .center = a, v.frame.size != f.size { v.setFrameSize(f.size) }
            let s = v.frame.size
            let x: CGFloat
            switch a {
            case .leading(let o): x = f.minX + o
            case .trailing(let o): x = f.maxX - o   // o = distance from the right edge to the view's left edge
            case .center: x = f.midX - s.width / 2
            }
            v.setFrameOrigin(CGPoint(x: x, y: f.midY - s.height / 2))
            v.alphaValue = alpha
            v.wantsLayer = true
            v.layer?.filters = blur > 0.05 ? [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": blur])!] : nil
        }
    }

    fileprivate func clicked() { onClick?() }
    fileprivate func pointerMoved(_ inside: Bool, at windowPoint: NSPoint) {
        let wasInside = pointer != nil
        pointer = inside ? convertPoint(toScreen: windowPoint) : nil
        updateHover()
        wake()
        if inside != wasInside { onHover?(inside) }
    }
    fileprivate func dragged(_ windowPoint: NSPoint, _ phase: DragPhase) {
        guard let v = incoming.first?.0 else { return }
        onDrag?(v.convert(windowPoint, from: nil), phase)
    }
}

private final class IslandView: NSView {
    weak var panel: IslandPanel?
    var hitPath: CGPath?
    private var inside = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitPath?.contains(convert(point, from: superview)) == true ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    private func track(_ e: NSEvent) {
        let now = hitPath?.contains(convert(e.locationInWindow, from: nil)) == true
        if now || now != inside { inside = now; panel?.pointerMoved(now, at: e.locationInWindow) }
    }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { track(event) }
    override func mouseDown(with event: NSEvent) { panel?.clicked(); panel?.dragged(event.locationInWindow, .began) }
    override func mouseDragged(with event: NSEvent) { panel?.dragged(event.locationInWindow, .changed) }
    override func mouseUp(with event: NSEvent) { panel?.dragged(event.locationInWindow, .ended) }
}
