// Pointer parameters and the two glow layers (BigGlow, LittleGlow) of 27 interactive glass, shared by Flex.swift (SwiftUI
// glass buttons) and ToolbarPress.swift (AppKit toolbar platters). No SwiftUI, so it can be unit tested (tests/glow.swift).
import AppKit

/// 27 pointer parameters for small buttons (`automatic` < 120 pt -> `ultraSmall`, cursor source).
enum GGFlexParams {
    static let lift = 2.5
    static let pressResponse = 0.262, pressDamping = 0.625      // tracking
    static let releaseResponse = 0.25, releaseDamping = 0.629   // spring
    static let bigGlow = 0.75, littleGlow = 0.2625
    static let littleGlowDissipation = 50.0
}

/// Presses/releases between two frames, at their real times. A click shorter than a frame (released before the first
/// display link tick) is still integrated for its exact press duration, like 27: the FlexValue spring runs on AttributeGraph
/// time, and the run loop keeps running inside the button tracking loop, so the `active` phase is recorded during the press.
struct GGPressTimeline {
    private var changes: [(CFTimeInterval, Bool)] = []
    private var state = false
    private var last: CFTimeInterval = 0

    mutating func set(_ on: Bool, at t: CFTimeInterval) { changes.append((t, on)) }

    /// Calls f(pressed, dt) for each segment from the previous call to `now`; each segment at most 0.1 s (long frame stalls).
    mutating func advance(to now: CFTimeInterval, _ f: (Bool, Double) -> Void) {
        var t = last == 0 ? (changes.first?.0 ?? now) : last
        for (ct, on) in changes {
            if ct > t { f(state, min(ct - t, 0.1)); t = ct }
            state = on
        }
        if now > t { f(state, min(now - t, 0.1)) }
        changes.removeAll()
        last = now
    }

    /// Restarts from the released state (display link stopped, view left the window).
    mutating func reset() { changes.removeAll(); state = false; last = 0 }
}

/// CAFilter `vibrantColorMatrix` with a matrix like CA::ColorMatrix::set_ycc_composite (fill alpha 0):
/// c' = sat c + (white - black - sat) Y(c) + black, Y per BT.709 (glass-harness/group.swift faceRows).
/// inputBackdropAware = YES like the 27 GlowContainer (SwiftUICore 27 0x190c1f7a0..0x190c1f7c8): the matrix applies to the
/// backdrop behind the layer, the layer alpha acts as a mask. Without it the layer shows nothing on 26.6 (tested).
func ggVibrant(black: Float, white: Float, sat: Float) -> NSObject? {
    guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
          let f = cls.perform(NSSelectorFromString("filterWithType:"), with: "vibrantColorMatrix")?.takeUnretainedValue() as? NSObject
    else { return nil }
    f.setValue(true, forKey: "inputBackdropAware")
    let L: [Float] = [0.2126, 0.7152, 0.0722]
    var m = [Float](repeating: 0, count: 20)
    for i in 0..<3 {
        for j in 0..<3 { m[i * 5 + j] = (white - black - sat) * L[j] + (i == j ? sat : 0) }
        m[i * 5 + 4] = black
    }
    m[18] = 1
    m.withUnsafeBytes { f.setValue(NSValue(bytes: $0.baseAddress!, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix") }
    return f
}

/// The two 27 glow layers: GlowContainer (layer) + FlexValue.updateGlow (path). updateGlow (SwiftUICore 27
/// 0x190c24688..0x190c24b5c):
/// - BigGlow: target bigGlowOpacity while pressed, 0 when released; glowSpringAnimation response 0.1, damping 1.
/// - LittleGlow: diameter min(1.5 x short side, 160); while pressed and the pointer is within littleGlowDissipationDistance
///   of the start point: opacity littleGlowOpacity, scale 1, response 0.1; farther: opacity x0.5, scale 2, response 0.5;
///   released: opacity 0, scale 4, response 0.5 (the spot fades and spreads); damping 1. Position follows the pointer,
///   response 0.15, damping 1.
/// - LittleGlow filter: YCC(0, 1, 1.5) then a dodge per appearance (0x190c1fa0c..0x190c1fc20, _ColorMatrix.apply(fills:)
///   branch 2): f = 0.40 light / 0.75 dark, multiplied by 1/(1-f) -> YCC(0, k, 1.5k), k = 1.667 / 4.0.
final class GGFlexGlow {
    let clip = CALayer()
    private let big = CALayer(), little = CALayer()
    private var bigS = GGSpring(value: 0, velocity: 0), littleS = GGSpring(value: 0, velocity: 0)
    private var scaleS = GGSpring(value: 4, velocity: 0)
    private var posX = GGSpring(value: 0, velocity: 0), posY = GGSpring(value: 0, velocity: 0)
    private var start = CGPoint.zero
    private var dark: Bool?
    /// Parameter set (ParameterSet) of the variant: default ultraSmall pointer; menu pointer: 0 / 0.05 / 25.
    private let bigGlow: Double, littleGlow: Double, dissipation: Double
    var bigOpacity: Double { Double(big.opacity) }
    var littleOpacity: Double { Double(little.opacity) }

    init(bigGlow: Double = GGFlexParams.bigGlow, littleGlow: Double = GGFlexParams.littleGlow,
         dissipation: Double = GGFlexParams.littleGlowDissipation) {
        self.bigGlow = bigGlow; self.littleGlow = littleGlow; self.dissipation = dissipation
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        big.backgroundColor = CGColor(gray: 1, alpha: 1)
        big.filters = ggVibrant(black: 0.05, white: 1.05, sat: 1.2).map { [$0] }
        little.cornerCurve = .circular
        little.setValue(true, forKey: "shadowPathIsBounds")
        little.shadowOffset = .zero
        little.shadowOpacity = 1
        little.shadowColor = CGColor(gray: 1, alpha: 1)
        for l in [big, little] { l.opacity = 0; clip.addSublayer(l) }
    }

    func layout(_ b: CGRect, cornerRadius: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = b
        clip.cornerRadius = min(cornerRadius, min(b.width, b.height) / 2)
        big.frame = clip.bounds
        CATransaction.commit()
    }

    /// Start of a press: start point (for the dissipation check) and filter per appearance.
    func begin(at p: CGPoint, dark d: Bool) {
        start = p
        if littleS.value < 0.001 { posX = GGSpring(value: p.x, velocity: 0); posY = GGSpring(value: p.y, velocity: 0) }
        if dark != d {
            dark = d
            let k: Float = d ? 4.0 : 1 / 0.6
            little.filters = ggVibrant(black: 0, white: k, sat: 1.5 * k).map { [$0] }
        }
    }

    /// Turns off at once, back to rest (view left the window while glowing).
    func reset() {
        bigS = GGSpring(value: 0, velocity: 0); littleS = bigS; scaleS = GGSpring(value: 4, velocity: 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        big.opacity = 0; little.opacity = 0
        CATransaction.commit()
    }

    /// One frame. `on` = pressed and allowed to glow; `p` = current pointer position (clip coordinates).
    /// Returns true once fully off (only when not pressed).
    func step(on: Bool, at p: CGPoint, dt: Double) -> Bool {
        let b = clip.bounds
        let D = min(1.5 * min(b.width, b.height), 160)
        let far = hypot(p.x - start.x, p.y - start.y) > dissipation
        let (lt, st, r): (Double, Double, Double) = on ? (far ? (littleGlow * 0.5, 2, 0.5) : (littleGlow, 1, 0.1)) : (0, 4, 0.5)
        bigS.step(to: on ? bigGlow : 0, response: 0.1, damping: 1, dt: dt)
        littleS.step(to: lt, response: r, damping: 1, dt: dt)
        scaleS.step(to: st, response: r, damping: 1, dt: dt)
        posX.step(to: p.x, response: 0.15, damping: 1, dt: dt)
        posY.step(to: p.y, response: 0.15, damping: 1, dt: dt)
        let off = !on && bigS.settled(target: 0) && littleS.settled(target: 0)
        if off { bigS = GGSpring(value: 0, velocity: 0); littleS = bigS; scaleS = GGSpring(value: 4, velocity: 0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        big.opacity = Float(max(0, bigS.value))
        little.opacity = Float(max(0, littleS.value))
        little.bounds = CGRect(x: 0, y: 0, width: D, height: D)
        little.cornerRadius = D / 2
        little.shadowRadius = D / 2
        little.position = CGPoint(x: posX.value, y: posY.value)
        little.transform = CATransform3DMakeScale(scaleS.value, scaleS.value, 1)
        CATransaction.commit()
        return off
    }
}
