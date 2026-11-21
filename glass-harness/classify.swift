// Tests for classify_glass26: for every state measured on 26.6 (measurements/glass-states-25G72.json), builds the
// 26.6 glass uniforms (face color matrix as in set_ycc_composite, blur radius), runs the test_classify_glass26 kernel
// on the GPU and checks (variant, dark). Unknown value sets must return -1 (use Apple's original shader).
// Also checks the 27 parameter path, interpolated faces, per-glass appearance and app recipe codes.
// Build: swiftc -O -o build/classify classify.swift
// Run:   build/classify [shaders/glass26_replica.metal] [../measurements/glass-states-25G72.json]
import Foundation
import Metal
import Accelerate

let args = CommandLine.arguments
let shaderPath = args.count > 1 ? args[1] : "shaders/glass26_replica.metal"
let statesPath = args.count > 2 ? args[2] : "../measurements/glass-states-25G72.json"

func half(_ v: Float) -> UInt16 {
    var f = v, h: UInt16 = 0
    withUnsafeMutableBytes(of: &f) { fp in
        withUnsafeMutableBytes(of: &h) { hp in
            var s = vImage_Buffer(data: fp.baseAddress, height: 1, width: 1, rowBytes: 4)
            var d = vImage_Buffer(data: hp.baseAddress, height: 1, width: 1, rowBytes: 2)
            _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
        }
    }
    return h
}

/// 26.6 GlassBackgroundUniforms (272 bytes) with only the fields classify needs: blur_radius (40), face_cm0..2 (80, 88, 96).
func uniforms(black: Float, white: Float, sat: Float, fill: [Float], blur: Float) -> [UInt8] {
    var u = [UInt8](repeating: 0, count: 272)
    withUnsafeBytes(of: blur) { u.replaceSubrange(40..<44, with: $0) }
    let L: [Float] = [0.2126, 0.7152, 0.0722], k = 1 - fill[3]
    for i in 0..<3 {
        var row = L.map { (white - black - sat) * $0 * k }
        row[i] += sat * k
        row.append(black * k + fill[i] * fill[3])
        for (j, x) in row.enumerated() { withUnsafeBytes(of: half(x)) { u.replaceSubrange(80 + i * 8 + j * 2..<82 + i * 8 + j * 2, with: $0) } }
    }
    return u
}

struct Case { let name: String; let u: [UInt8]; let variant: Int32; let dark: Int32 }
var cases: [Case] = []

let doc = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: statesPath))) as! [String: Any]
for s in doc["states"] as! [[String: Any]] {
    let i = s["inputs"] as! [String: Any]
    let fill = ((i["inputFaceColorMatrixFillColor"] as? [String: Any])?["cgcolor"] as? [Double])?.map(Float.init) ?? [0, 0, 0, 0]
    let dark = (s["appearance"] as! String).contains("Dark")
    let style = s["style"] as! String
    cases.append(Case(name: "\(style) \(dark ? "dark" : "light") \((s["active"] as! Bool) ? "active" : "inactive")",
                      u: uniforms(black: Float(i["inputFaceColorMatrixBlack"] as! Double), white: Float(i["inputFaceColorMatrixWhite"] as! Double),
                                  sat: Float(i["inputFaceColorMatrixSaturation"] as! Double), fill: fill,
                                  blur: Float(i["inputBlurRadius"] as! Double)),
                      variant: style == "clear" ? 1 : 0, dark: dark ? 1 : 0))
}
// Sidebar: ggapp (GGApp.sidebarGlass, ggapp/Sources/Sidebar.m) writes the 27 SidebarRecipe face into the sidebar glass
// filter; it matches no 26.6 face. Also when the window is not key (27 has no inactive schema for sidebars), so it is
// always an active sidebar.
cases.append(Case(name: "sidebar 27 light (ggapp)", u: uniforms(black: 0.4, white: 1.03, sat: 1.2, fill: [1, 1, 1, 0.2], blur: 4), variant: 2, dark: 0))
cases.append(Case(name: "sidebar 27 dark (ggapp)", u: uniforms(black: 0.1, white: 0.5, sat: 0.6, fill: [0, 0, 0, 0], blur: 4), variant: 2, dark: 1))
// preserve_hue (offset 244) carries the encoded slider amount: recipe recognition must not change.
for c in cases where c.variant >= 0 {
    for p: Float in [2, 1003, 2003] {
        var u = c.u
        withUnsafeBytes(of: p) { u.replaceSubrange(244..<248, with: $0) }
        cases.append(Case(name: "\(c.name), preserve_hue \(Int(p))", u: u, variant: c.variant, dark: c.dark))
    }
}
// Value sets not in the table: must return -1.
cases.append(Case(name: "unknown: black 0.33 white 0.77", u: uniforms(black: 0.33, white: 0.77, sat: 1, fill: [1, 1, 1, 0.35], blur: 4), variant: -1, dark: 0))
cases.append(Case(name: "unknown: regular light but sat 1.5", u: uniforms(black: 0.5, white: 0.95, sat: 1.5, fill: [1, 1, 1, 0.35], blur: 4), variant: -1, dark: 0))
cases.append(Case(name: "unknown: regular light but fill 0.5", u: uniforms(black: 0.5, white: 0.95, sat: 1, fill: [1, 1, 1, 0.5], blur: 4), variant: -1, dark: 0))

let device = MTLCreateSystemDefaultDevice()!
let lib = try! device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8), options: nil)
guard let fn = lib.makeFunction(name: "test_classify_glass26") else { print("FAIL: missing kernel test_classify_glass26"); exit(1) }
let pso = try! device.makeComputePipelineState(function: fn)
let queue = device.makeCommandQueue()!
var failed = 0
for c in cases {
    let out = device.makeBuffer(length: 16, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(pso)
    e.setBytes(c.u, length: c.u.count, index: 0)
    e.setBuffer(out, offset: 0, index: 1)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let r = out.contents().bindMemory(to: Int32.self, capacity: 4)
    let ok = r[0] == c.variant && (c.variant < 0 || r[1] == c.dark)
    if !ok { failed += 1 }
    print("\(ok ? "OK " : "FAIL") \(c.name): variant \(r[0]) dark \(r[1]) (expected \(c.variant) / \(c.dark))")
}
// The 27 parameter set of the automatic path (WindowServer) must equal the one forced via function constants, for every
// mapped 26.6 recipe (kSigs26). On failure, prints the differing fields (float index in GlassBackgroundUniforms27, 320 bytes).
struct Mapped { let name: String; let b, w, s: Float; let fill: [Float]; let variant: Int32; let dark, inact: Bool }
let mapped: [Mapped] = [
    Mapped(name: "regular inactive light", b: 0.5, w: 0.95, s: 1, fill: [1, 1, 1, 0.35], variant: 0, dark: false, inact: true),
    Mapped(name: "regular inactive dark", b: 0.2, w: 0.6, s: 1, fill: [0, 0, 0, 0.35], variant: 0, dark: true, inact: true),
    Mapped(name: "clear light", b: 0.2, w: 0.95, s: 1, fill: [1, 1, 1, 0.1], variant: 1, dark: false, inact: false),
    Mapped(name: "clear dark", b: 0.05, w: 0.8, s: 1, fill: [1, 1, 1, 0.05], variant: 1, dark: true, inact: false),
    Mapped(name: "regular active light", b: 0.5, w: 1.03, s: 1, fill: [1, 1, 1, 0.4], variant: 0, dark: false, inact: false),
    Mapped(name: "regular active dark", b: 0.2, w: 0.6, s: 1, fill: [0, 0, 0, 0.4], variant: 0, dark: true, inact: false),
    Mapped(name: "Dock light", b: 0.15, w: 0.9, s: 1.05, fill: [1, 1, 1, 0.1], variant: 4, dark: false, inact: false),
    Mapped(name: "Dock dark", b: 0.075, w: 0.9, s: 1.06, fill: [0, 0, 0, 0.1], variant: 4, dark: true, inact: false),
    Mapped(name: "menu inactive light", b: 0.8, w: 0.96, s: 1, fill: [0.96, 0.96, 0.96, 0.04], variant: 3, dark: false, inact: true),
    Mapped(name: "menu inactive dark", b: 0.15, w: 0.3, s: 1, fill: [0, 0, 0, 0], variant: 3, dark: true, inact: true),
    Mapped(name: "Control Center", b: 0.125, w: 0.8, s: 1.3, fill: [0, 0, 0, 0], variant: 5, dark: false, inact: false),
    Mapped(name: "sidebar light", b: 0.4, w: 1.03, s: 1.2, fill: [1, 1, 1, 0.2], variant: 2, dark: false, inact: false),
    Mapped(name: "sidebar dark", b: 0.1, w: 0.5, s: 0.6, fill: [0, 0, 0, 0], variant: 2, dark: true, inact: false),
]
func params(_ fc: MTLFunctionConstantValues, _ u: [UInt8]) -> ([Float], [UInt8]) {
    let f = try! lib.makeFunction(name: "test_gg27_params", constantValues: fc)
    let p = try! device.makeComputePipelineState(function: f)
    let ov = device.makeBuffer(length: 320, options: .storageModeShared)!, ox = device.makeBuffer(length: 32, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(p); e.setBytes(u, length: u.count, index: 0)
    e.setBuffer(ov, offset: 0, index: 1); e.setBuffer(ox, offset: 0, index: 2)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return (Array(UnsafeBufferPointer(start: ov.contents().bindMemory(to: Float.self, capacity: 80), count: 80)),
            Array(UnsafeBufferPointer(start: ox.contents().bindMemory(to: UInt8.self, capacity: 25), count: 25)))
}
var pfail = 0
for m in mapped {
    let u = uniforms(black: m.b, white: m.w, sat: m.s, fill: m.fill, blur: 4)
    let (va, xa) = params(MTLFunctionConstantValues(), u)
    let fc = MTLFunctionConstantValues()
    var vr = m.variant, dk = m.dark, ia = m.inact
    fc.setConstantValue(&vr, type: .int, index: 38); fc.setConstantValue(&dk, type: .bool, index: 3); fc.setConstantValue(&ia, type: .bool, index: 4)
    var ib = true; fc.setConstantValue(&ib, type: .bool, index: 44)   // like the automatic path: no drawing outside the edge
    let (vf, xf) = params(fc, u)
    let bad = (0..<80).filter { abs(va[$0] - vf[$0]) > 1e-4 * max(1, abs(vf[$0])) && !(va[$0].isNaN && vf[$0].isNaN) }
    let ok = bad.isEmpty && xa == xf
    if !ok { pfail += 1 }
    print("\(ok ? "OK " : "FAIL") params \(m.name): automatic = forced" + (bad.isEmpty ? "" : ", float diff " + bad.map { "#\($0) \(va[$0]) vs \(vf[$0])" }.joined(separator: ", ")) + (xa == xf ? "" : ", ext diff"))
}
failed += pfail
// Interpolated face in 26.6 show/hide animations: face = mix(identity, recipe s, t).
// The test_interp_sig26 kernel returns (s, t); on no line (adaptive glass) or exactly the recipe (t = 1): -1.
// A face near identity with blur near 0 (first frame): t = 0.
func interpUniforms(b: Float, w: Float, s: Float, fill: [Float], t: Float, blur: Float) -> [UInt8] {
    let L: [Float] = [0.2126, 0.7152, 0.0722], k = 1 - fill[3]
    var u = [UInt8](repeating: 0, count: 272)
    withUnsafeBytes(of: blur) { u.replaceSubrange(40..<44, with: $0) }
    for i in 0..<3 {
        var row = L.map { (w - b - s) * $0 * k }
        row[i] += s * k
        row.append(b * k + fill[i] * fill[3])
        for j in 0..<4 {
            let x = (1 - t) * (i == j ? 1 : 0) + t * row[j]
            withUnsafeBytes(of: half(x)) { u.replaceSubrange(80 + i * 8 + j * 2..<82 + i * 8 + j * 2, with: $0) }
        }
    }
    return u
}
struct ICase { let name: String; let u: [UInt8]; let sig: Int32; let t: Float }
let icases = [
    ICase(name: "Control Center t = 0.4", u: interpUniforms(b: 0.125, w: 0.8, s: 1.3, fill: [0, 0, 0, 0], t: 0.4, blur: 2.05), sig: 14, t: 0.4),
    ICase(name: "regular active light t = 0.25", u: interpUniforms(b: 0.5, w: 1.03, s: 1, fill: [1, 1, 1, 0.4], t: 0.25, blur: 0.7), sig: 4, t: 0.25),
    ICase(name: "regular active dark t = 0.7", u: interpUniforms(b: 0.2, w: 0.6, s: 1, fill: [0, 0, 0, 0.4], t: 0.7, blur: 1.4), sig: 8, t: 0.7),
    // At t = 0 the 27 glass does not depend on the recipe: always returns #4 (regular).
    ICase(name: "near identity, blur 0", u: interpUniforms(b: 0.125, w: 0.8, s: 1.3, fill: [0, 0, 0, 0], t: 0.001, blur: 0), sig: 4, t: 0),
    // The interpolation line is continuous up to t = 1 (no gap left between the interpolation's t < 0.995 and the region
    // classify accepts: Control Center flashed white for 1 frame when the spring animation crossed u ~ 0.995, 2026-11-19).
    // At t = 1 classify accepts first, so rendering does not change.
    ICase(name: "exact recipe #4 (t = 1)", u: interpUniforms(b: 0.5, w: 1.03, s: 1, fill: [1, 1, 1, 0.4], t: 1, blur: 1.6), sig: 4, t: 1),
    ICase(name: "sidebar light t = 0.5", u: interpUniforms(b: 0.4, w: 1.03, s: 1.2, fill: [1, 1, 1, 0.2], t: 0.5, blur: 3), sig: 17, t: 0.5),
    ICase(name: "adaptive glass (idle button)", u: interpUniforms(b: 0.127, w: 0.723, s: 1, fill: [1, 1, 1, 0.589], t: 1, blur: 0.8), sig: -1, t: 0),
]
if let ifn = lib.makeFunction(name: "test_interp_sig26") {
    let ip = try! device.makeComputePipelineState(function: ifn)
    for c in icases {
        let out = device.makeBuffer(length: 8, options: .storageModeShared)!
        let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(ip); e.setBytes(c.u, length: c.u.count, index: 0); e.setBuffer(out, offset: 0, index: 1)
        e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let s = out.contents().load(as: Int32.self), t = out.contents().load(fromByteOffset: 4, as: Float.self)
        let ok = s == c.sig && (c.sig < 0 || abs(t - c.t) < 0.01)
        if !ok { failed += 1 }
        print("\(ok ? "OK " : "FAIL") interpolation \(c.name): recipe \(s) t \(t) (expected \(c.sig) / \(c.t))")
    }
} else { print("FAIL: missing kernel test_interp_sig26"); failed += 1 }
// The identity -> Control Center line (B, W, S, blur linear in u, as Control Center interpolates itself, traced 2026-11-19):
// every u in [0.99, 1] must be accepted by classify or interpolation; any point not accepted is drawn as 27 regular (white flash).
var gaps: [Float] = []
if let ifn = lib.makeFunction(name: "test_interp_sig26") {
    let ip = try! device.makeComputePipelineState(function: ifn)
    func kernel(_ p: MTLComputePipelineState, _ u: [UInt8]) -> Int32 {
        let out = device.makeBuffer(length: 16, options: .storageModeShared)!
        let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(p); e.setBytes(u, length: u.count, index: 0); e.setBuffer(out, offset: 0, index: 1)
        e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return out.contents().load(as: Int32.self)
    }
    for k in 0...20 {
        let u = 0.99 + Float(k) * 0.0005
        let un = interpUniforms(b: 0.125, w: 0.8, s: 1.3, fill: [0, 0, 0, 0], t: u, blur: 3.2 * u)
        if kernel(pso, un) < 0 && kernel(ip, un) < 0 { gaps.append(u) }
    }
}
print(gaps.isEmpty ? "OK  identity -> Control Center line continuous up to u = 1" : "FAIL identity -> Control Center line has gaps at u = \(gaps)")
if !gaps.isEmpty { failed += 1 }
// Per-glass appearance as in 27 (ggapp writes a negative code into preserve_hue: -(2 + 4 round(a 500) + 2 dark + flag),
// from the view's effectiveAppearance): adaptive glass (face carries no appearance, #5) follows the code's bit, not the
// global flag (sys, buffer 28); old positive codes follow the global flag; recognized glass (regular #4) follows its own
// face and ignores the bit.
struct ACase { let name: String; let u: [UInt8]; let sys: Int32; let mode: Int32; let dark: Int32 }
func withCode(_ u: [UInt8], _ p: Float) -> [UInt8] { var v = u; withUnsafeBytes(of: p) { v.replaceSubrange(244..<248, with: $0) }; return v }
let adaptive = uniforms(black: 0.8, white: 0.97, sat: 1, fill: [1, 1, 1, 0.25], blur: 4)
let regLight = uniforms(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4], blur: 4)
let acases = [
    ACase(name: "adaptive, dark code (-1004), system light", u: withCode(adaptive, -1004), sys: 0, mode: 0, dark: 1),
    ACase(name: "adaptive, light code (-1002), system dark", u: withCode(adaptive, -1002), sys: 1, mode: 0, dark: 0),
    ACase(name: "adaptive, dark code with flag (-1005), system light", u: withCode(adaptive, -1005), sys: 0, mode: 0, dark: 1),
    ACase(name: "adaptive, positive code (1002), system dark", u: withCode(adaptive, 1002), sys: 1, mode: 0, dark: 1),
    ACase(name: "regular light, dark code (-1004), system dark", u: withCode(regLight, -1004), sys: 1, mode: 0, dark: 0),
]
if let fm = try? lib.makeFunction(name: "test_glass_mode26", constantValues: MTLFunctionConstantValues()) {
    let p = try! device.makeComputePipelineState(function: fm)
    for c in acases {
        let out = device.makeBuffer(length: 8, options: .storageModeShared)!
        var sys = c.sys
        let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(p); e.setBytes(c.u, length: c.u.count, index: 0); e.setBuffer(out, offset: 0, index: 1)
        e.setBytes(&sys, length: 4, index: 2)
        e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let r = out.contents().bindMemory(to: Int32.self, capacity: 2)
        let ok = r[0] == c.mode && r[1] == c.dark
        if !ok { failed += 1 }
        print("\(ok ? "OK " : "FAIL") glass appearance: \(c.name): mode \(r[0]) dark \(r[1]) (expected \(c.mode) / \(c.dark))")
    }
} else { print("FAIL: missing kernel test_glass_mode26"); failed += 1 }
// A negative code carrying the same slider amount as a positive code: 27 parameters must match (0.3 = 150/500 = 300/1000;
// the preserve flag is kept).
for (pos, neg) in [(Float(602), Float(-604)), (603, -603), (2003, -2005)] {
    let (vp, xp) = params(MTLFunctionConstantValues(), withCode(regLight, pos)), (vn, xn) = params(MTLFunctionConstantValues(), withCode(regLight, neg))
    let ok = vp == vn && xp == xn
    if !ok { failed += 1 }
    print("\(ok ? "OK " : "FAIL") negative code \(Int(neg)) gives the same 27 params as positive code \(Int(pos))")
}
// App recipe code: |P| >= 2048, n = ((recipe 2 + inactive) 2 + flag) 79 + round(a 78) is the index of a half-precision
// integer from 2048, negative when dark. The app writes the real 27 values into the shared keys: the shader copies the
// shared group from the uniforms and only computes the 27-only group from the code.
func recipeCode(_ r: Int, _ inact: Bool, _ dark: Bool, _ flag: Int, _ a: Float) -> Float {
    let q = Int((min(max(a, 0), 1) * 78).rounded())
    let n = ((r * 2 + (inact ? 1 : 0)) * 2 + flag) * 79 + q
    let e = 11 + n / 1024, k = n % 1024
    let m = (1 << e) + k * (1 << (e - 10))
    return Float(dark ? -m : m)
}
var appCount = 0
func run1(_ name: String, _ fc: MTLFunctionConstantValues, _ bytes: [UInt8], outLen: Int, extra: Int = 0) -> [UInt8] {
    guard let f = try? lib.makeFunction(name: name, constantValues: fc) else { return [] }
    let p = try! device.makeComputePipelineState(function: f)
    let o = device.makeBuffer(length: outLen, options: .storageModeShared)!
    let o2 = device.makeBuffer(length: max(extra, 16), options: .storageModeShared)!
    let o3 = device.makeBuffer(length: 16, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(p); e.setBytes(bytes, length: bytes.count, index: 0)
    e.setBuffer(o, offset: 0, index: 1); e.setBuffer(o2, offset: 0, index: 2); e.setBuffer(o3, offset: 0, index: 3)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: o.contents().bindMemory(to: UInt8.self, capacity: outLen), count: outLen))
        + Array(UnsafeBufferPointer(start: o2.contents().bindMemory(to: UInt8.self, capacity: extra), count: extra))
        + Array(UnsafeBufferPointer(start: o3.contents().bindMemory(to: UInt8.self, capacity: 16), count: 16))
}
func floats(_ b: [UInt8]) -> [Float] { b.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
// Decoding in the shader.
for (r, ina, dk, fl, a) in [(0, false, false, 0, Float(0.5)), (6, true, true, 1, 0.25), (15, true, false, 1, 1), (2, false, true, 0, 0)] {
    var p = recipeCode(r, ina, dk, fl, a)
    let out = floats(run1("test_decode_recipe", MTLFunctionConstantValues(), withUnsafeBytes(of: &p) { Array($0) }, outLen: 32))
    let ok = out.count >= 6 && out[5] == 1 && Int(out[0]) == r && (out[1] == 1) == ina && Int(out[2]) == fl
        && abs(out[3] - (a * 78).rounded() / 78) < 1e-6 && (out[4] == 1) == dk
    if !ok { failed += 1 }; appCount += 1
    print("\(ok ? "OK " : "FAIL") decode recipe P = \(Int(p)) -> recipe \(r) inactive \(ina) flag \(fl) a \(a) dark \(dk)" + (ok ? "" : " (got \(out.prefix(6)))"))
}
do {   // an old code is not a recipe code
    var p: Float = -2005
    let out = floats(run1("test_decode_recipe", MTLFunctionConstantValues(), withUnsafeBytes(of: &p) { Array($0) }, outLen: 32))
    let ok = out.count >= 6 && out[5] == 0
    if !ok { failed += 1 }; appCount += 1
    print("\(ok ? "OK " : "FAIL") old code -2005 is not a recipe code")
}
// App mode: shared fields come from the uniforms (marker values), 27-only fields match forcing the same state.
func put(_ u: inout [UInt8], _ off: Int, _ v: Float) { withUnsafeBytes(of: v) { u.replaceSubrange(off..<off + 4, with: $0) } }
func marked(_ base: [UInt8]) -> [UInt8] {
    var u = base
    for (o, v) in [(16, Float(-11)), (20, 0.2), (24, 17), (28, 0.0625), (40, 0.77), (48, 9), (52, 0.111), (76, 0.0833),
                   (160, 1), (164, 0.5), (168, 0), (172, -0.5), (176, -18), (180, -1), (184, 0), (188, 0),
                   (200, 0.33), (220, 0), (224, 0.6)] { put(&u, o, v) }
    for j in 0..<12 { withUnsafeBytes(of: half(0.1 + Float(j) * 0.05)) { u.replaceSubrange(104 + j * 2..<106 + j * 2, with: $0) } }
    return u
}
let copyRanges: [Range<Int>] = [16..<32, 40..<44, 48..<56, 76..<80, 80..<128, 160..<192, 200..<204, 220..<228]
let only27: [Range<Int>] = [240..<284, 288..<312]
struct AppCase { let name: String; let r: Int; let inact: Bool; let dark: Bool; let a: Float; let face: [UInt8] }
let adaptiveFace = uniforms(black: 0.8, white: 0.97, sat: 1, fill: [1, 1, 1, 0.25], blur: 4)
let appCases = [
    AppCase(name: "regular active light", r: 0, inact: false, dark: false, a: 0.5, face: regLight),
    AppCase(name: "adaptive glass, inactive dark", r: 0, inact: true, dark: true, a: 0.5, face: adaptiveFace),
    // a is quantized to 1/78 (recipe code) and 1/1000 (old code used when forcing): only 0, 0.5, 1 coincide.
    AppCase(name: "regular light a 0", r: 0, inact: false, dark: false, a: 0, face: regLight),
    AppCase(name: "popover inactive light", r: 6, inact: true, dark: false, a: 0.5, face: regLight),
    AppCase(name: "menu inactive dark", r: 3, inact: true, dark: true, a: 0.5, face: regLight),
    AppCase(name: "sidebar dark", r: 2, inact: false, dark: true, a: 0.5, face: regLight),
    AppCase(name: "clear a 1", r: 1, inact: false, dark: false, a: 1, face: regLight),
    AppCase(name: "Dock dark", r: 4, inact: false, dark: true, a: 0.5, face: regLight),
    AppCase(name: "Control Center", r: 5, inact: false, dark: false, a: 0.5, face: regLight),
]
for c in appCases {
    let u = withCode(marked(c.face), recipeCode(c.r, c.inact, c.dark, 0, c.a))
    let app = run1("test_gg27_params_auto", MTLFunctionConstantValues(), u, outLen: 320, extra: 28)
    let fc = MTLFunctionConstantValues()
    var vr = Int32(c.r), dk = c.dark, ia = c.inact
    fc.setConstantValue(&vr, type: .int, index: 38); fc.setConstantValue(&dk, type: .bool, index: 3); fc.setConstantValue(&ia, type: .bool, index: 4)
    // Forced: same uniforms, an old code carrying the same a (gg_tint_encode), no recipe code.
    let forcedU = withCode(marked(c.face), Float(2 + 2 * Int((c.a * 1000).rounded())))
    let forced = run1("test_gg27_params_auto", fc, forcedU, outLen: 320, extra: 28)
    guard app.count == 364, forced.count == 364 else { print("FAIL app mode \(c.name): missing kernel test_gg27_params_auto"); failed += 1; appCount += 1; continue }
    let copyOK = copyRanges.allSatisfy { Array(app[$0]) == Array(u[$0]) }
    // Compare floats with relative tolerance 1e-4: when forced, the compiler folds cos(spread) at compile time (~1e-5 off).
    let fa = floats(Array(app[0..<320])), ff = floats(Array(forced[0..<320]))
    let xa = floats(Array(app[320..<340])), xf = floats(Array(forced[320..<340]))
    let ha = floats(Array(app[348..<364])), hf = floats(Array(forced[348..<364]))
    func close(_ p: Float, _ q: Float) -> Bool { abs(p - q) <= 1e-4 * max(1, abs(q)) || (p.isNaN && q.isNaN) }
    var diff: [String] = []
    for r in only27 { for o in r where o % 4 == 0 && !close(fa[o / 4], ff[o / 4]) { diff.append("@\(o) \(fa[o / 4]) vs \(ff[o / 4])") } }
    for i in 0..<5 where !close(xa[i], xf[i]) { diff.append("ext#\(i) \(xa[i]) vs \(xf[i])") }
    for i in 0..<4 where !close(ha[i], hf[i]) { diff.append("hl#\(i) \(ha[i]) vs \(hf[i])") }
    let onlyOK = diff.isEmpty && Array(app[340..<345]) == Array(forced[340..<345])
    let ok = copyOK && onlyOK
    if !ok { failed += 1 }; appCount += 1
    print("\(ok ? "OK " : "FAIL") app mode \(c.name): shared fields from uniforms \(copyOK ? "ok" : "wrong"), 27 fields as forced \(onlyOK ? "ok" : "wrong " + diff.joined(separator: ", "))")
}
// Popover inactive (CartouchePopoverRecipe): only the Parameters layer changes: ring stays 0.06, darkSpecular 120°, highlight off.
do {
    let u = withCode(marked(regLight), recipeCode(6, true, false, 0, 0.5))
    let out = run1("test_gg27_params_auto", MTLFunctionConstantValues(), u, outLen: 320, extra: 28)
    let f = out.count == 364 ? floats(Array(out[0..<320])) : [], hl = out.count == 364 ? floats(Array(out[348..<364])) : []
    let ok = !f.isEmpty && abs(f[256 / 4] - 0.06) < 1e-6 && abs(f[276 / 4] - cos(120 * Float.pi / 180)) < 1e-5 && hl[3] < 0
    if !ok { failed += 1 }; appCount += 1
    print("\(ok ? "OK " : "FAIL") popover inactive: ring 0.06, darkSpecular 120°, highlight off" + (ok || f.isEmpty ? "" : " (ring \(f[64]) spread \(f[69]) hl \(hl))"))
    let ua = withCode(marked(adaptiveFace), recipeCode(0, true, false, 0, 0.5))
    let oa = run1("test_gg27_params_auto", MTLFunctionConstantValues(), ua, outLen: 320, extra: 28)
    let fa = oa.count == 364 ? floats(Array(oa[0..<320])) : [], ha = oa.count == 364 ? floats(Array(oa[348..<364])) : []
    let ok2 = !fa.isEmpty && fa[256 / 4] == 0 && abs(fa[276 / 4] - cos(120 * Float.pi / 180)) < 1e-5 && ha[3] < 0
    if !ok2 { failed += 1 }; appCount += 1
    print("\(ok2 ? "OK " : "FAIL") adaptive glass with inactive code: ring 0, darkSpecular 120°, highlight off")
}
// Widgets (recipe 7, ChicletRecipe branch P) and notification cards (recipe 8, NotificationCenterRecipe) in
// NotificationCenter. The inactive bit of these two recipes' codes means subdued: the shader does not apply inactive.
// Chiclet: the 27-only group as clear (ClearSpec), highlight white 0.85. Notifications: regular active; cards (short side
// >= 40) are computed with x = 166 (surfaceSize .medium).
func runX(_ u: [UInt8], _ xs: Float, _ fc: MTLFunctionConstantValues = MTLFunctionConstantValues()) -> [UInt8] {
    guard let f = try? lib.makeFunction(name: "test_gg27_params_auto_x", constantValues: fc) else { return [] }
    let p = try! device.makeComputePipelineState(function: f)
    let o = device.makeBuffer(length: 320, options: .storageModeShared)!, o2 = device.makeBuffer(length: 28, options: .storageModeShared)!
    let o3 = device.makeBuffer(length: 16, options: .storageModeShared)!
    var x = xs
    let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(p); e.setBytes(u, length: u.count, index: 0)
    e.setBuffer(o, offset: 0, index: 1); e.setBuffer(o2, offset: 0, index: 2); e.setBuffer(o3, offset: 0, index: 3); e.setBytes(&x, length: 4, index: 4)
    e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: o.contents().bindMemory(to: UInt8.self, capacity: 320), count: 320))
        + Array(UnsafeBufferPointer(start: o2.contents().bindMemory(to: UInt8.self, capacity: 28), count: 28))
        + Array(UnsafeBufferPointer(start: o3.contents().bindMemory(to: UInt8.self, capacity: 16), count: 16))
}
do {
    func close(_ p: Float, _ q: Float) -> Bool { abs(p - q) <= 1e-4 * max(1, abs(q)) || (p.isNaN && q.isNaN) }
    func forced(_ v: Int32, _ dk: Bool) -> MTLFunctionConstantValues {
        let fc = MTLFunctionConstantValues(); var vr = v, d = dk, ia = false
        fc.setConstantValue(&vr, type: .int, index: 38); fc.setConstantValue(&d, type: .bool, index: 3); fc.setConstantValue(&ia, type: .bool, index: 4)
        return fc
    }
    // Compares the 27-only group (except highlight) of an app code against forcing; returns a description of differences.
    func only27Diff(_ app: [UInt8], _ ref: [UInt8]) -> [String] {
        guard app.count == 364, ref.count == 364 else { return ["missing kernel"] }
        let fa = floats(Array(app[0..<320])), ff = floats(Array(ref[0..<320]))
        let xa = floats(Array(app[320..<340])), xf = floats(Array(ref[320..<340]))
        var d: [String] = []
        for r in only27 { for o in r where o % 4 == 0 && !close(fa[o / 4], ff[o / 4]) { d.append("@\(o) \(fa[o / 4]) vs \(ff[o / 4])") } }
        for i in 0..<5 where !close(xa[i], xf[i]) { d.append("ext#\(i) \(xa[i]) vs \(xf[i])") }
        return d
    }
    let legacy = Float(2 + 2 * 500)   // old code a 0.5 used when forcing
    let chic = runX(withCode(marked(regLight), recipeCode(7, false, false, 0, 0.5)), 36)
    let chicSub = runX(withCode(marked(regLight), recipeCode(7, true, false, 0, 0.5)), 36)
    let clearRef = runX(withCode(marked(regLight), legacy), 36, forced(1, false))
    let hc = chic.count == 364 ? floats(Array(chic[348..<364])) : []
    let d1 = only27Diff(chic, clearRef), d2 = only27Diff(chicSub, clearRef)
    let ok1 = d1.isEmpty && d2.isEmpty && hc.count == 4 && close(hc[0], 0.15) && close(hc[1], 0.85) && close(hc[2], 1) && close(hc[3], 0.25)
    if !ok1 { failed += 1 }; appCount += 1
    print("\(ok1 ? "OK " : "FAIL") widget (recipe 7, also subdued): 27 group as clear, highlight (0.15, 0.85, 1, 0.25)" + (ok1 ? "" : " (\(d1 + d2), hl \(hc))"))
    let notifSub = runX(withCode(marked(regLight), recipeCode(8, true, false, 0, 0.5)), 36)
    let regRef = runX(withCode(marked(regLight), legacy), 36, forced(0, false))
    let hn = notifSub.count == 364 ? floats(Array(notifSub[348..<364])) : []
    let d3 = only27Diff(notifSub, regRef)
    let ok2 = d3.isEmpty && hn.count == 4 && close(hn[1], 0.9) && close(hn[3], 0.15)
    if !ok2 { failed += 1 }; appCount += 1
    print("\(ok2 ? "OK " : "FAIL") subdued notification button (recipe 8, x 36): as regular active, not inactive" + (ok2 ? "" : " (\(d3), hl \(hn))"))
    func lumaComp(_ b: [UInt8]) -> Float { b.count == 364 ? floats(Array(b[320..<340]))[4] : .nan }
    let card = lumaComp(runX(withCode(marked(regLight), recipeCode(8, false, true, 0, 0.5)), 60))
    let reg60 = lumaComp(runX(withCode(marked(regLight), recipeCode(0, false, true, 0, 0.5)), 60))
    let btn = lumaComp(runX(withCode(marked(regLight), recipeCode(8, true, true, 0, 0.5)), 24))
    let ok3 = close(card, 0.65) && close(reg60, 0.4) && close(btn, 0.4)
    if !ok3 { failed += 1 }; appCount += 1
    print("\(ok3 ? "OK " : "FAIL") dark notification card x 60 computed as x 166 (max luma 0.35), regular / button x 24 use the real x (0.6)"
          + (ok3 ? "" : " (card \(card), regular \(reg60), button \(btn))"))
}
// Subdued (0x195e79e30) multiplies the key/fill highlight intensity by 0.4 (0x195e7a330, 0x195e7a954; measured on 26.6:
// keyColor/fillColor alpha 1 -> 0.4). Only recipes 7, 8 carry the subdued bit; for other recipes that bit means inactive
// (highlight turned off separately), factor 1.
if let fg = try? lib.makeFunction(name: "test_hl_gain", constantValues: MTLFunctionConstantValues()) {
    let p = try! device.makeComputePipelineState(function: fg)
    func gain(_ code: Float) -> Float {
        let u = withCode(marked(regLight), code), o = device.makeBuffer(length: 16, options: .storageModeShared)!
        let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(p); e.setBytes(u, length: u.count, index: 0); e.setBuffer(o, offset: 0, index: 1)
        e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return o.contents().load(as: Float.self)
    }
    let g = [gain(recipeCode(8, true, false, 0, 0.5)), gain(recipeCode(7, true, true, 0, 0.5)), gain(recipeCode(8, false, false, 0, 0.5)),
             gain(recipeCode(0, true, false, 0, 0.5)), gain(1002)]
    let ok = g == [0.4, 0.4, 1, 1, 1]
    if !ok { failed += 1 }; appCount += 1
    print("\(ok ? "OK " : "FAIL") subdued highlight x0.4 (recipes 7/8 with the bit), other recipes and old codes x1" + (ok ? "" : " (\(g))"))
} else { print("FAIL: missing kernel test_hl_gain"); failed += 1; appCount += 1 }
let total = cases.count + mapped.count + icases.count + 1 + acases.count + 3 + appCount
print(failed == 0 ? "TOTAL: \(total)/\(total) passed" : "TOTAL: \(failed) failed")
exit(failed == 0 ? 0 : 1)
