// GGFlexGlow test (Sources/Glow.swift): path of the two glow layers per 27 FlexValue.updateGlow
// (SwiftUICore 27 0x190c24688). Run by tests/run-tests.sh (copied as main.swift, compiled with Spring.swift, Glow.swift).
import AppKit
var bad = 0
func expect(_ c: Bool, _ m: String) { print(c ? "OK  \(m)" : "FAIL \(m)"); if !c { bad += 1 } }

func run(_ g: GGFlexGlow, on: Bool, at p: CGPoint, for t: Double) -> Bool {
    var off = false, e = 0.0
    while e < t - 1e-9 { off = g.step(on: on, at: p, dt: 1.0 / 120); e += 1.0 / 120 }
    return off
}
func little(_ g: GGFlexGlow) -> CALayer { g.clip.sublayers![1] }
func scaleOf(_ l: CALayer) -> Double { l.transform.m11 }
func matrixWhite(_ l: CALayer) -> Float {   // element [0][0] of the LittleGlow matrix: (white - sat) * 0.2126 + sat
    guard let v = (l.filters?.first as AnyObject?)?.value(forKey: "inputColorMatrix") as? NSValue else { return -1 }
    var m = [Float](repeating: 0, count: 20); m.withUnsafeMutableBytes { v.getValue($0.baseAddress!, size: 80) }
    return m[0]
}

let g = GGFlexGlow()
g.layout(CGRect(x: 0, y: 0, width: 74, height: 36), cornerRadius: 18)
let c = CGPoint(x: 20, y: 18)
g.begin(at: c, dark: false)
_ = run(g, on: true, at: c, for: 0.1)
expect(g.bigOpacity > 0.7, "BigGlow rises near 0.75 after 0.1 s (spring 0.1/1.0), got \(g.bigOpacity)")
_ = run(g, on: true, at: c, for: 0.4)
let l = little(g)
expect(abs(l.bounds.width - 54) < 0.01, "LittleGlow diameter = 1.5 x short side (54), got \(l.bounds.width)")
expect(abs(Double(l.opacity) - 0.2625) < 0.005 && abs(scaleOf(l) - 1) < 0.01, "near the press point: LittleGlow 0.2625, scale 1 (got \(l.opacity), \(scaleOf(l)))")
let lightWhite = matrixWhite(l)
_ = run(g, on: true, at: CGPoint(x: 72, y: 18), for: 2)   // drag 52 pt > 50
expect(abs(Double(l.opacity) - 0.13125) < 0.005 && abs(scaleOf(l) - 2) < 0.02, "dragged past 50 pt: x0.5, scale 2 (got \(l.opacity), \(scaleOf(l)))")
expect(abs(l.position.x - 72) < 0.5, "spot follows the pointer (got \(l.position.x))")
var off = run(g, on: false, at: CGPoint(x: 72, y: 18), for: 0.1)
expect(g.bigOpacity < 0.05 && !off, "released 0.1 s: BigGlow nearly off, LittleGlow still fading (big \(g.bigOpacity), little \(l.opacity))")
expect(scaleOf(l) > 2.2, "released: spot spreads toward scale 4 (got \(scaleOf(l)))")
off = run(g, on: false, at: CGPoint(x: 72, y: 18), for: 3)
expect(off && l.opacity == 0 && g.bigOpacity == 0, "released 3 s: fully off")
g.begin(at: c, dark: true)
let darkWhite = matrixWhite(little(g))
// light k = 1/0.6: (k - 1.5k) * 0.2126 + 1.5k = 1.3937 k; dark k = 4
expect(abs(lightWhite - 1.3937 / 0.6) < 0.01 && abs(darkWhite - 1.3937 * 4) < 0.01, "LittleGlow matrix follows appearance (light \(lightWhite), dark \(darkWhite))")
// View removed from the window while glowing (toolbar rearranging platters): reset must turn off at once, no stuck spot.
g.begin(at: c, dark: false); _ = run(g, on: true, at: c, for: 0.3)
g.reset()
expect(g.bigOpacity == 0 && little(g).opacity == 0 && run(g, on: false, at: c, for: 1.0 / 120), "reset: off at once and at rest")
// Click shorter than a frame (press 1.000 s, release 1.004 s, next frame 1.016 s): the spring must still run exactly 4 ms
// "pressed" then 12 ms "released", without dropping the press (bug: plain clicks had no effect).
var tl = GGPressTimeline()
tl.set(true, at: 1.0); tl.set(false, at: 1.004)
var segs: [(Bool, Double)] = []
tl.advance(to: 1.016) { segs.append(($0, $1)) }
expect(segs.count == 2 && segs[0].0 && abs(segs[0].1 - 0.004) < 1e-9 && !segs[1].0 && abs(segs[1].1 - 0.012) < 1e-9,
       "4 ms click between two frames: (pressed 4 ms, released 12 ms), got \(segs)")
segs = []; tl.set(true, at: 1.020); tl.advance(to: 1.032) { segs.append(($0, $1)) }
expect(segs.count == 2 && !segs[0].0 && abs(segs[0].1 - 0.004) < 1e-9 && segs[1].0 && abs(segs[1].1 - 0.012) < 1e-9,
       "press mid-frame: (released 4 ms, pressed 12 ms), got \(segs)")
segs = []; tl.advance(to: 5.0) { segs.append(($0, $1)) }
expect(segs.count == 1 && segs[0].0 && abs(segs[0].1 - 0.1) < 1e-9, "long frame stall: each segment at most 0.1 s, got \(segs)")
// A single 4 ms press still makes BigGlow visibly light up (spring 0.1/1.0 has momentum): peak > 0.05.
let gq = GGFlexGlow(); gq.layout(CGRect(x: 0, y: 0, width: 39, height: 36), cornerRadius: 18); gq.begin(at: c, dark: false)
var peak = 0.0; var tq = GGPressTimeline(); tq.set(true, at: 0); tq.set(false, at: 0.004)
for i in 1...30 { tq.advance(to: Double(i) / 60) { on, dt in _ = gq.step(on: on, at: c, dt: dt) }; peak = max(peak, gq.bigOpacity) }
expect(peak > 0.05, "4 ms click: BigGlow still flashes (peak \(peak))")
let big = GGFlexGlow(); big.layout(CGRect(x: 0, y: 0, width: 300, height: 200), cornerRadius: 0)
big.begin(at: .zero, dark: false); _ = run(big, on: true, at: .zero, for: 0.05)
expect(abs(little(big).bounds.width - 160) < 0.01, "LittleGlow diameter capped at 160 (got \(little(big).bounds.width))")
// Menu variant, pointer (27 Settings.menu cursor): BigGlow 0, LittleGlow 0.05, dissipation 25.
let gm = GGFlexGlow(bigGlow: 0, littleGlow: 0.05, dissipation: 25)
gm.layout(CGRect(x: 0, y: 0, width: 200, height: 300), cornerRadius: 12); gm.begin(at: c, dark: false)
_ = run(gm, on: true, at: c, for: 0.5)
expect(gm.bigOpacity == 0 && abs(gm.littleOpacity - 0.05) < 0.002, "menu: BigGlow 0, LittleGlow 0.05 (got \(gm.bigOpacity), \(gm.littleOpacity))")
_ = run(gm, on: true, at: CGPoint(x: c.x, y: c.y + 30), for: 2)   // drag 30 pt > 25
expect(abs(gm.littleOpacity - 0.025) < 0.002 && abs(scaleOf(little(gm)) - 2) < 0.02, "menu: dragged past 25 pt: 0.025, scale 2 (got \(gm.littleOpacity), \(scaleOf(little(gm))))")
expect(run(gm, on: false, at: c, for: 3) && gm.littleOpacity == 0, "menu: released 3 s fully off")
print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed")
exit(bad == 0 ? 0 : 1)
