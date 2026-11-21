// Pixel comparison: the original glass_background_sdf_lpf (QuartzCore default.metallib, read-only) against
// our MSL shader, over many random uniform sets and 3 SDF modes.
// Build: swiftc -O -o build/compare compare.swift
// Run:   build/compare <.metal file> <fragment name> [case count, default 60] [Apple function name] [per-channel tolerance]
//        [allowed fraction of channels over tolerance]
// Exits 1 if differences exceed the tolerance.
import Accelerate
import Foundation
import Metal

let args = CommandLine.arguments
let shaderPath = args.count > 1 ? args[1] : "shaders/glass26_replica.metal"
let ourName = args.count > 2 ? args[2] : "replica_glass_background_sdf_lpf"
let cases = args.count > 3 ? Int(args[3])! : 60
// 5th argument (optional): per-channel tolerance. Default 2e-3 (effectively bit-exact with the float variant).
let tolerance: Float = args.count > 5 ? Float(args[5])! : 2e-3
// 6th argument (optional): fraction of channels allowed over tolerance per case (default 0: none).
// Used for _lph: ours computes in float, Apple partly in half, so a few pixels near the edge
// (alpha near 0) are discarded differently.
let maxBadFraction = args.count > 6 ? Double(args[6])! : 0
// _lph Apple functions: half uniforms from offset 160 of GlassBackgroundUniforms, edr_scale is half.
let halfABI = (args.count > 4 ? args[4] : "").hasSuffix("_lph")

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let appleLib = try! device.makeLibrary(URL: URL(fileURLWithPath:
    "/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"))
let ourLib = try! device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8), options: nil)

// Texture SDF variant (glass_background_{,no_bleed_}lp?): uniforms only hold the glass part, the SDF is read from
// sdf_texture (index 4), fragment inputs are named texcoord0 (source uv) and texcoord1 (sdf_texture uv).
let texMode = !(args.count > 4 ? args[4] : "_sdf_").contains("_sdf_")

func pipeline(_ frag: MTLFunction) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = ourLib.makeFunction(name: texMode ? "harness_tex_vert" : "harness_vert")!
    d.fragmentFunction = frag
    let vd = MTLVertexDescriptor()
    for (i, (fmt, off)) in [(MTLVertexFormat.float4, 0), (.float2, 16), (.float2, 24)].enumerated() {
        vd.attributes[i].format = fmt; vd.attributes[i].offset = off; vd.attributes[i].bufferIndex = 30
    }
    vd.layouts[30].stride = 32
    d.vertexDescriptor = vd
    d.colorAttachments[0].pixelFormat = .rgba32Float
    return try! device.makeRenderPipelineState(descriptor: d)
}
let appleName = args.count > 4 ? args[4] : "glass_background_sdf_lpf"
let applePSO = pipeline(appleLib.makeFunction(name: appleName)!)
let ourFn = try! ourLib.makeFunction(name: ourName, constantValues: MTLFunctionConstantValues())
let ourPSO = pipeline(ourFn)

// Mipmapped backdrop: color stripes + gradient + varying alpha (premultiplied).
let texSize = 256
let src: MTLTexture = {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: texSize, height: texSize, mipmapped: true)
    d.usage = [.shaderRead]
    let t = device.makeTexture(descriptor: d)!
    var px = [UInt8](repeating: 0, count: texSize * texSize * 4)
    for y in 0..<texSize { for x in 0..<texSize {
        let a = 0.55 + 0.45 * Double((x + y) % 64) / 63
        let stripe = (x / 16) % 4
        let rgb: [Double] = [stripe == 0 ? 1 : 0.1, stripe == 1 ? 0.9 : Double(y) / 255, stripe >= 2 ? 1 : 0.2]
        let i = (y * texSize + x) * 4
        for c in 0..<3 { px[i + c] = UInt8(rgb[c] * a * 255) }
        px[i + 3] = UInt8(a * 255)
    } }
    t.replace(region: MTLRegionMake2D(0, 0, texSize, texSize), mipmapLevel: 0, withBytes: px, bytesPerRow: texSize * 4)
    let cb = queue.makeCommandBuffer()!; let b = cb.makeBlitCommandEncoder()!
    b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return t
}()

// Seeded random generator so failing cases are reproducible.
struct LCG { var s: UInt64; mutating func next(_ lo: Float, _ hi: Float) -> Float {
    s = s &* 6364136223846793005 &+ 1442695040888963407
    return lo + (hi - lo) * Float(s >> 40) / Float(1 << 24) } }

func half(_ v: Float) -> UInt16 {
    var f = v, h: UInt16 = 0
    var sb = vImage_Buffer(data: &f, height: 1, width: 1, rowBytes: 4)
    var db = vImage_Buffer(data: &h, height: 1, width: 1, rowBytes: 2)
    vImageConvert_PlanarFtoPlanar16F(&sb, &db, 0)
    return h
}

let W = 192, H = 128, halfW: Float = 70, halfH: Float = 40
func uniforms(_ r: inout LCG, mode: Int) -> [UInt8] {
    var u = [UInt8](repeating: 0, count: 320)
    func f(_ off: Int, _ v: Float) { withUnsafeBytes(of: v) { u.replaceSubrange(off..<off + 4, with: $0) } }
    func h4(_ off: Int, _ v: [Float]) { for (i, x) in v.enumerated() { withUnsafeBytes(of: half(x)) { u.replaceSubrange(off + i * 2..<off + i * 2 + 2, with: $0) } } }
    func rnd(_ lo: Float, _ hi: Float) -> Float { r.next(lo, hi) }
    func on(_ p: Float) -> Bool { r.next(0, 1) < p }
    // sdf (offset 0): arg = (halfW, halfH, mode, ovalization), tr = gradient transform, arg2
    f(0, halfW); f(4, halfH); f(8, Float(mode)); f(12, rnd(0, 1))
    let a = rnd(-0.4, 0.4); f(16, cos(a)); f(20, -sin(a)); f(24, sin(a)); f(28, cos(a))
    if mode == 4 { f(32, rnd(0, 1)); f(36, rnd(0, 1)); f(40, rnd(8, 30)); f(44, 0) }
    else { f(32, rnd(4, 30)); f(36, rnd(4, 30)); f(40, rnd(4, 30)); f(44, rnd(4, 30)) }
    let g = 48   // GlassBackgroundUniforms
    let px: Float = 1 / Float(texSize)   // displacement maps points -> uv
    f(g + 0, px); f(g + 4, 0); f(g + 8, 0); f(g + 12, px)
    f(g + 16, rnd(-60, 60)); f(g + 20, 1 / rnd(8, 30)); f(g + 24, rnd(-30, 30)); f(g + 28, 1 / rnd(5, 20))
    f(g + 32, rnd(-12, -6)); f(g + 36, rnd(-4, 0))
    f(g + 40, rnd(0.5, 12)); f(g + 44, rnd(0, 20)); f(g + 48, on(0.7) ? rnd(0, 40) : 0); f(g + 52, 1 / rnd(10, 40))
    f(g + 56, rnd(0, 60)); f(g + 60, 1 / rnd(20, 60)); f(g + 64, rnd(-6, 6)); f(g + 68, rnd(0, 12))
    f(g + 72, rnd(0, 20)); f(g + 76, 1 / rnd(6, 30))
    for off in stride(from: 80, through: 144, by: 8) {
        h4(g + off, [rnd(-0.3, 1.2), rnd(-0.3, 1.2), rnd(-0.3, 1.2), rnd(-0.2, 0.4)])
    }
    f(g + 152, on(0.6) ? rnd(0.1, 1) : 0); f(g + 156, rnd(0, 1))
    f(g + 160, 1); f(g + 164, rnd(0, 0.5)); f(g + 168, rnd(0, 0.3)); f(g + 172, rnd(0, 0.2))
    f(g + 176, -40); f(g + 180, -20); f(g + 184, -8); f(g + 188, 0)
    f(g + 192, rnd(-20, -10)); f(g + 196, rnd(-8, 0)); f(g + 200, on(0.7) ? rnd(0, 1) : 0); f(g + 204, on(0.8) ? rnd(0.2, 1) : 0)
    f(g + 208, rnd(-1, 1)); f(g + 212, rnd(0, 1)); f(g + 216, rnd(-4, 4)); f(g + 220, rnd(0, 1))
    f(g + 224, on(0.6) ? rnd(0.2, 1) : 0); f(g + 228, on(0.5) ? rnd(0.2, 1) : 0)
    f(g + 232, rnd(-20, -10)); f(g + 236, rnd(-8, 4))
    f(g + 240, on(0.5) ? rnd(0.6, 1.5) : 0); f(g + 244, on(0.5) ? 1 : 0); f(g + 248, rnd(0.8, 1.2))
    f(g + 252, 0); f(g + 256, on(0.8) ? 1 : 0)
    if texMode {   // texture variant: shadow_offset in sdf_texture uv; drop the 48 bytes of SdfFragmentUniforms
        f(g + 64, rnd(-0.05, 0.05)); f(g + 68, rnd(-0.05, 0.05))
        return Array((halfABI ? halfLayout(u) : u)[48...])
    }
    return halfABI ? halfLayout(u) : u
}

/// sdf_texture for the texture variant: a random rounded rectangle covering the quad, channels (distance in points,
/// gradient x, gradient y, coverage). rgba32Float, no mips.
func sdfTexture(_ r: inout LCG) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: W, height: H, mipmapped: false)
    d.usage = [.shaderRead]
    let t = device.makeTexture(descriptor: d)!
    let hw = halfW * r.next(0.6, 1), hh = halfH * r.next(0.6, 1), rad = r.next(4, min(hw, hh)), w = r.next(0.6, 1)
    var px = [Float](repeating: 0, count: W * H * 4)
    for y in 0..<H { for x in 0..<W {
        let p = (Float(x) + 0.5) / Float(W) * 2 * (halfW + m) - (halfW + m), q = (Float(y) + 0.5) / Float(H) * 2 * (halfH + m) - (halfH + m)
        let dx = abs(p) - hw + rad, dy = abs(q) - hh + rad
        let ox = max(dx, 0), oy = max(dy, 0), len = (ox * ox + oy * oy).squareRoot()
        let dist = len + min(max(dx, dy), 0) - rad
        var g: (Float, Float) = len > 0 ? (ox / len, oy / len) : (dx > dy ? (1, 0) : (0, 1))
        g.0 *= p < 0 ? -1 : 1; g.1 *= q < 0 ? -1 : 1
        let i = (y * W + x) * 4
        px[i] = dist; px[i + 1] = g.0; px[i + 2] = g.1; px[i + 3] = w
    } }
    t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 16)
    return t
}
var sdfTex: MTLTexture? = nil

/// Converts the _lpf uniform layout (320 bytes) to _lph (272 bytes): float fields from offset 160 of
/// GlassBackgroundUniforms become half, new offset = 160 + (old - 160) / 2. x86_workaround = 1 (x86 machine).
func halfLayout(_ u: [UInt8]) -> [UInt8] {
    var out = Array(u[0..<(48 + 160)]) + [UInt8](repeating: 0, count: 272 - 48 - 160)
    for fo in stride(from: 160, to: 260, by: 4) {
        var v: Float = 0
        _ = withUnsafeMutableBytes(of: &v) { u.copyBytes(to: $0, from: (48 + fo)..<(52 + fo)) }
        if fo == 252 { v = 1 }
        withUnsafeBytes(of: half(v)) { out.replaceSubrange((48 + 160 + (fo - 160) / 2)..<(50 + 160 + (fo - 160) / 2), with: $0) }
    }
    return out
}

let m: Float = 14   // margin around the shape so the shadow is visible
let verts: [Float] = [
    -1, -1, 0, 1,  -halfW - m,  halfH + m,  0.15, 0.85,
     1, -1, 0, 1,   halfW + m,  halfH + m,  0.85, 0.85,
    -1,  1, 0, 1,  -halfW - m, -halfH - m,  0.15, 0.15,
     1,  1, 0, 1,   halfW + m, -halfH - m,  0.85, 0.15,
]
// Texture variant: attribute 1 is the sdf_texture uv (0..1 over the quad) instead of SDF coordinates.
let texVerts: [Float] = [
    -1, -1, 0, 1,  0, 1,  0.15, 0.85,
     1, -1, 0, 1,  1, 1,  0.85, 0.85,
    -1,  1, 0, 1,  0, 0,  0.15, 0.15,
     1,  1, 0, 1,  1, 0,  0.85, 0.15,
]
let vbuf = device.makeBuffer(bytes: texMode ? texVerts : verts, length: verts.count * 4)!

func render(_ pso: MTLRenderPipelineState, _ u: [UInt8], edr: Float) -> [Float] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: W, height: H, mipmapped: false)
    d.usage = [.renderTarget]; d.storageMode = .managed
    let target = device.makeTexture(descriptor: d)!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].clearColor = MTLClearColor(red: -1, green: -1, blue: -1, alpha: -1)  // discarded pixels stay -1
    rp.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(pso)
    e.setVertexBuffer(vbuf, offset: 0, index: 30)
    e.setFragmentBytes(u, length: u.count, index: 1)
    if halfABI { var h = half(edr); e.setFragmentBytes(&h, length: 2, index: 6) }
    else { var edrV = edr; e.setFragmentBytes(&edrV, length: 4, index: 6) }
    e.setFragmentTexture(src, index: 3)
    if let sdfTex { e.setFragmentTexture(sdfTex, index: 4) }
    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    e.endEncoding()
    let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: target); b.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var out = [Float](repeating: 0, count: W * H * 4)
    target.getBytes(&out, bytesPerRow: W * 16, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    return out
}

var rng = LCG(s: 0xC0FFEE)
var worst: Float = 0, failures = 0, nanMismatch = 0
for i in 0..<cases {
    let mode = [0, 4, 5][i % 3]
    let u = uniforms(&rng, mode: mode)
    if texMode { sdfTex = sdfTexture(&rng) }
    let edr = rng.next(0.8, 1.5)
    let a = render(applePSO, u, edr: edr), b = render(ourPSO, u, edr: edr)
    var maxd: Float = 0, bad = 0
    for k in 0..<a.count {
        // One side discards (stays -1), the other draws with alpha < 1/512: invisible (rounds to 0 in 8-bit), treated as equal.
        // Happens with _lph: Apple partly computes in half, so it discards pixels where the float variant still has alpha ~1e-5.
        let p = k / 4 * 4, da = a[p + 3] == -1, db = b[p + 3] == -1
        if da != db && (da ? b[p + 3] : a[p + 3]) < 1.0 / 512 { continue }
        if a[k].isNaN != b[k].isNaN { nanMismatch += 1; bad += 1; continue }
        if a[k].isNaN { continue }
        let d = abs(a[k] - b[k]); maxd = max(maxd, d); if d > tolerance { bad += 1 }
    }
    worst = max(worst, maxd)
    if Double(bad) / Double(a.count) > maxBadFraction || (maxBadFraction == 0 && bad > 0) { failures += 1 }
    // Coverage: number of non-discarded pixels and number of distinct R values (the image has real content).
    let drawn = stride(from: 0, to: a.count, by: 4).filter { a[$0 + 3] != -1 }.count
    let distinct = Set(stride(from: 0, to: a.count, by: 4).map { a[$0] }).count
    print(String(format: "case %2d mode %d  max|Δ| %.6f  channels>%.0e: %d  pixels drawn %d/%d  distinct R values %d",
                 i, mode, maxd, tolerance, bad, drawn, W * H, distinct))
}
print(String(format: "TOTAL: %d/%d passed, max|Δ| %.6f, NaN mismatches %d", cases - failures, cases, worst, nanMismatch))
exit(failures == 0 ? 0 : 1)
