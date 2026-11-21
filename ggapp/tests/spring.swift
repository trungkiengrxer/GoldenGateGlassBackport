// GGSpring test (Sources/Spring.swift): macOS 27 spring characteristics (response 0.25, damping 0.629) per theory:
// overshoot exp(-ζπ/√(1-ζ²)) = 7.9%, peak at π/ω_d = 0.161 s. Run by tests/run-tests.sh (copied as main.swift).
// Peak measured with a 1 ms step: 60 Hz sampling lands on 0.150/0.167 s and misses the real peak.
import Foundation
var bad = 0
func expect(_ c: Bool, _ m: String) { print(c ? "OK  \(m)" : "FAIL \(m)"); if !c { bad += 1 } }

var s = GGSpring(value: 0, velocity: 0)
var peak = 0.0, peakT = 0.0, settleT = -1.0, t = 0.0
let dt = 0.001
while t < 1.0 {
    s.step(to: 1, response: 0.25, damping: 0.629, dt: dt); t += dt
    if s.value > peak { peak = s.value; peakT = t }
    if settleT < 0 && s.settled(target: 1) { settleT = t }
}
expect(abs(peak - 1.079) < 0.005, "overshoot 7.9% (got \(peak))")
expect(abs(peakT - 0.161) < 0.02, "peak at 0.16 s (got \(peakT))")
expect(settleT > 0 && settleT < 0.6, "settles before 0.6 s (got \(settleT))")

var r = GGSpring(value: 0, velocity: 0)
for _ in 0..<5 { r.step(to: 1, response: 0.262, damping: 0.625, dt: 1.0 / 60) }
let (v0, vel0) = (r.value, r.velocity)
r.step(to: 0, response: 0.25, damping: 0.629, dt: 0)
expect(r.value == v0 && r.velocity == vel0, "retargeting mid-flight keeps value and velocity")
expect(!GGSpring(value: 1, velocity: 0.5).settled(target: 1), "not settled while velocity remains")
exit(bad == 0 ? 0 : 1)
