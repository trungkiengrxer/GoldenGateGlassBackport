import Foundation

/// macOS 27 spring (FluidSpringAnimation: response, dampingFraction), integrated in-app every frame.
/// mass 1, k = (2π/response)², c = 4π·ζ/response; semi-implicit integration, substeps <= 1/240 s.
/// Retargeting mid-flight keeps value and velocity (pressing again while bouncing).
struct GGSpring {
    var value: Double
    var velocity: Double

    mutating func step(to target: Double, response: Double, damping: Double, dt: Double) {
        guard dt > 0 else { return }
        let w = 2 * Double.pi / response, k = w * w, c = 2 * damping * w
        let n = Int((dt * 240).rounded(.up)), h = dt / Double(n)
        for _ in 0..<n {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
    }

    func settled(target: Double) -> Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }
}
