// Liquid Glass button group comparison: real 26.6 screenshot | original 26.6 shader (Apple) | 27 algorithm
// (reconstructed, 26.6 ABI) | difference × 8, on white and photo backgrounds. Rendered at 3x to see edges clearly.
// Same geometry and parameters as a SwiftUI ButtonGroup sample (capsule 156x36pt, .regular, Aqua).
// Also runs the automatic-path, slider, texture-variant and diagnostic checks (OK / FAIL lines).
// Build: swiftc -O -o build/group group.swift
// Run:   build/group [.metal file] [renders directory, default ../renders] [background image]
// Real screenshots (<renders>/buttongroup-white.png, buttongroup-image.png) are optional; the column is skipped without them.
import AppKit
import Metal
import Accelerate

let args = CommandLine.arguments
let shaderPath = args.count > 1 ? args[1] : "shaders/glass26_replica.metal"
let outDir = args.count > 2 ? args[2] : "../renders"
let photoPath = args.count > 3 ? args[3] : "/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let W = 360, H = 160, S = 3                 // points, pixel scale
let PW = W * S, PH = H * S
let center = SIMD2<Float>(180, 80), halfSize = SIMD2<Float>(78, 18), radius: Float = 18

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let appleLib = try! device.makeLibrary(URL: URL(fileURLWithPath:
    "/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"))
let ourLib = try! device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8), options: nil)

func pso(_ frag: MTLFunction, blend: Bool = true, vertex: String = "harness_vert") -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = try! ourLib.makeFunction(name: vertex, constantValues: MTLFunctionConstantValues())
    d.fragmentFunction = frag
    let vd = MTLVertexDescriptor()
    for (i, (fmt, off)) in [(MTLVertexFormat.float4, 0), (.float2, 16), (.float2, 24)].enumerated() {
        vd.attributes[i].format = fmt; vd.attributes[i].offset = off; vd.attributes[i].bufferIndex = 30
    }
    vd.layouts[30].stride = 32
    d.vertexDescriptor = vd
    let c = d.colorAttachments[0]!
    c.pixelFormat = .rgba32Float; c.isBlendingEnabled = blend   // premultiplied source-over like WindowServer
    c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
    c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try! device.makeRenderPipelineState(descriptor: d)
}
let apple26 = pso(appleLib.makeFunction(name: "glass_background_sdf_lpf")!)
// 27's separate highlight layer (the shader does its own source-over onto the backdrop, so blending is off).
let highlightPSO = pso(try! ourLib.makeFunction(name: "kf_highlight_vibrant", constantValues: MTLFunctionConstantValues()), blend: false)
/// CASDFKeyFillHighlightEffect parameters of the 27 NSGlassEffectView converted to shader form (SDFNode::apply), per
/// DesignLibrary 27.2.1: key 0 / fill pi, height 1 pt, amount 0.5 -> 0, curvature 0.75, spread clampedLinear(short
/// side; 96..192 -> 80..90 degrees), diffuse height x8, spread x0.65, amount x0.15, key/fill alpha 1.0, clamp
/// maxColorComponent = max(gain 1.2, 1).
/// "Up" in sdf_uv (y up) is (0, 1).
/// Vibrant matrix as DesignLibrary builds it (0x195f7fe60, 0x195f80488, 0x195f805d0): YCC(black, white, sat)
/// then a gray dodgeFill `dodge` (divides the whole row by 1 - min(dodge, 0.996)), drops |x| < 1e-12, rounds to 1e-4 steps.
/// Returns 3 rows (R, G, B, bias).
func vibrantRows(black: Double, white: Double, sat: Double, dodge: Double) -> [[Float]] {
    let L = [0.2126, 0.7152, 0.0722], s = 1 / (1 - min(dodge, 0.996))
    return (0..<3).map { i in
        var row = L.map { (white - black - sat) * $0 }
        row[i] += sat
        return (row + [black]).map { v in
            let x = v * s
            return Float(abs(x) < 1e-12 ? 0 : (x / 1e-4).rounded() * 1e-4)
        }
    }
}

/// Uniforms for the highlight layer: the shape is the same for every glass kind, only the vibrant matrix differs.
/// The group layer has gain = highlights.hdr = SolariumHighlightWhite (1.2). QuartzCore 27
/// CA::OGL::prepare_compositing_filter (0x18deb7728): with gain > 1 the matrix RGB rows (bias included) are multiplied
/// by powf(gain, 1 / gamma), gamma = CGColorCurveGetGamma(context colorspace) = 2.2 for sRGB/P3 (measured on the
/// machine). The filter clamp threshold also moves to the gamma domain: clampMax = powf(inputClamp, 1 / gamma)
/// (0x18deb77a4..0x18deb780c), with inputClamp = maxColorComponent = max(gain, 1) set by SwiftUICore.
func highlightUniforms(_ m: [[Float]], gain: Float = 1.2, gamma: Float = 2.2) -> [Float] {
    let deg = Float.pi / 180, short = 2 * min(halfSize.x, halfSize.y)
    let spread = (80 + 10 * min(max((short - 96) / 96, 0), 1)) * deg
    let g: Float = gain > 1 ? powf(gain, 1 / gamma) : 1
    let clampMax: Float = powf(max(gain, 1), 1 / gamma)
    let shape: [Float] = [halfSize.x, halfSize.y, radius, 1, 1, 1, cos(spread), 1 / 0.5 - 2, 0.75, 0,
                          8, cos(spread * 0.65), 1 / (0.5 * 0.15) - 2, clampMax, 0, 1]
    let matrix: [Float] = m.flatMap { row in row.map { $0 * g } }
    return shape + matrix
}
/// Regular (light = dark): highlights.key.ycc = (0.125, 0.9, 1) + dodge 0.15 (Spec.Highlights 0x195eef0b0).
let hlRegular = highlightUniforms(vibrantRows(black: 0.125, white: 0.9, sat: 1, dodge: 0.15))
/// Clear: ClearSpec.Modifier rebuilds highlights with keyYCC = (0.15, 1.1, 1) + dodge 0.25 (0x195f02378..0x195f02534).
let hlClear = highlightUniforms(vibrantRows(black: 0.15, white: 1.1, sat: 1, dodge: 0.25))
/// Dock (DockRecipe.Other): light only changes white = 0.9 on ClearSpec's highlight; dark (0.25, 0.95, 1.2), no dodge.
let hlDockLight = highlightUniforms(vibrantRows(black: 0.15, white: 0.9, sat: 1, dodge: 0.25))
let hlDockDark = highlightUniforms(vibrantRows(black: 0.25, white: 0.95, sat: 1.2, dodge: 0))
/// The automatic path (kInBounds) moves the 1 px dark rim (kfh = 1.6 pl when pl < 0.5) from outside the edge to inside.
/// To keep 27's ordering (gray rim outermost, bright line just inside), the highlight is also inset by kfh; otherwise the
/// bright line covers the gray rim at the top/bottom edges (Finder buttons were seen missing the top/bottom gray rim
/// while the sides still had it).
func inset(_ h: [Float]) -> [Float] { var h = h; h[9] = 1.6 / Float(S); return h }

/// 27 pipeline with float function constants (index -> value), e.g. [27: diffusion].
/// pixelLength (index 36) defaults to 1/3 because the harness renders at 3x.
/// inBounds: enables kInBounds (44) like the automatic path in WindowServer (dark rim inside the edge), to compare
/// against the automatic path.
func gg27With(_ consts: [Int: Float], dark: Bool = false, variant: Int32 = 0, inactive: Bool = false,
              inBounds: Bool = false) -> MTLRenderPipelineState {
    let fc = MTLFunctionConstantValues()
    for (i, v) in consts.merging([36: 1 / Float(S)], uniquingKeysWith: { a, _ in a }) {
        var x = v; fc.setConstantValue(&x, type: .float, index: i)
    }
    var d = dark; fc.setConstantValue(&d, type: .bool, index: 3)
    var vr = variant; fc.setConstantValue(&vr, type: .int, index: 38)
    var ia = inactive; fc.setConstantValue(&ia, type: .bool, index: 4)
    if inBounds { var ib = true; fc.setConstantValue(&ib, type: .bool, index: 44) }
    return pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
}
let gg27 = gg27With([:])
let gg27b = gg27With([:], inBounds: true)   // regular light like the automatic path (no drawing outside the edge)
let kDiffusionIndex = 27, kFillLightIndex = 23, kFillDarkIndex = 24, kFillNormalIndex = 25, kFaceFillAIndex = 31
// Bias of the 27 dark rim at pixelLength 1/3 (< 0.5): -0.3.
let kfBias27 = 0.3
// Compares the highlight drawn inside the glass (automatic path) with the separate highlight layer (QuartzCore 27): the
// separate layer reads the composited framebuffer and the harness uses an analytic rounded SDF, while the in-glass version
// reads the glass color before compositing and the uniform SDF. The two only differ at antialiased pixels right on the
// edge, so the criterion is: at most 0.1% of channels off by more than hlTol.
let hlTol = 3
func hlMatch(_ a: CGImage, _ b: CGImage) -> (ok: Bool, text: String) {
    let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
    var over = 0, worst = 0
    for i in 0..<pa.count where i % 4 != 3 {
        let d = abs(Int(pa[i]) - Int(pb[i])); worst = max(worst, d); if d > hlTol { over += 1 }
    }
    let frac = Double(over) / Double(pa.count / 4 * 3)
    return (frac <= 0.001, String(format: "max %d/255, %.3f%% channels off > %d", worst, frac * 100, hlTol))
}
// Face color matrix rebuilt by the 27 adapter (default function constants 28..34, RegularBase.Base Aqua),
// and Aqua's default max luma complement on an SDR display (1 - 0.94).
let face27 = faceRows(black: 0.4, white: 1.03, sat: 1.2, fill: [1, 1, 1, 0.2]), maxLumaComp27 = 0.06

/// luma_compress of the 27 shader (Rec.709, factor 0.3), same constants as in glass26_replica.metal.
func lumaCompress(_ c: [Double], _ k: Double) -> [Double] {
    let L = Double(Float(bitPattern: 0x3E59B3D0)) * c[0] + Double(Float(bitPattern: 0x3F371759)) * c[1]
          + Double(Float(bitPattern: 0x3D93DD98)) * c[2]
    let s = min(max(1 - L * k, 0), 1), t = (1 - s) * Double(Float(bitPattern: 0x3E99999A)) + 1
    return c.map { s * L + (s * $0 - s * L) * t }
}

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}
func backdrop(_ photo: CGImage?, _ w: Int, _ h: Int, fill: CGColor = .white) -> CGImage {
    bitmap(w, h) { ctx in
        ctx.setFillColor(fill); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let photo { ctx.interpolationQuality = .high; ctx.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h)) }  // stretched like NSImageView
    }
}
func texture(_ img: CGImage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: true)
    d.usage = [.shaderRead]
    let t = device.makeTexture(descriptor: d)!
    (img.dataProvider!.data! as Data).withUnsafeBytes {
        t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.bytesPerRow)
    }
    let cb = queue.makeCommandBuffer()!; let b = cb.makeBlitCommandEncoder()!
    b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return t
}

// ---- Mip chain using Apple's own kernel: variable_blur_downsample_frag_lpf (13 taps) ----
// Apple's compute path uses imageblocks (Apple GPUs only), so on Intel the fragment path is the real one.
let downPSO: MTLRenderPipelineState = {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = try! ourLib.makeFunction(name: "harness_blur_vert", constantValues: MTLFunctionConstantValues())
    d.fragmentFunction = appleLib.makeFunction(name: "variable_blur_downsample_frag_lpf")!
    let vd = MTLVertexDescriptor()
    vd.attributes[0].format = .float4; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 30
    vd.attributes[1].format = .float2; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 30
    vd.layouts[30].stride = 24
    d.vertexDescriptor = vd
    d.colorAttachments[0].pixelFormat = .rgba16Float
    return try! device.makeRenderPipelineState(descriptor: d)
}()
let linearClamp: MTLSamplerState = {
    let s = MTLSamplerDescriptor()
    s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
    s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
    return device.makeSamplerState(descriptor: s)!
}()
let blurQuad: MTLBuffer = {
    let v: [Float] = [-1, -1, 0, 1, 0, 1,   1, -1, 0, 1, 1, 1,   -1, 1, 0, 1, 0, 0,   1, 1, 0, 1, 1, 0]
    return device.makeBuffer(bytes: v, length: v.count * 4)!
}()

func tex16(_ w: Int, _ h: Int, mips: Bool = false) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: mips)
    d.usage = [.shaderRead, .renderTarget]
    return device.makeTexture(descriptor: d)!
}

/// One 1/2 downsample with Apple's kernel; dx, dy = source texel size.
func downsample(_ src: MTLTexture, _ cb: MTLCommandBuffer) -> MTLTexture {
    let dst = tex16(max(1, src.width / 2), max(1, src.height / 2))   // rounded down like Metal mip sizes
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(downPSO)
    e.setVertexBuffer(blurQuad, offset: 0, index: 30)
    var u: [Float] = [0, 1 / Float(src.width), 1 / Float(src.height), 0, 0, 0, 1, 1]   // source_level, dx, dy, _, clamp
    e.setFragmentBytes(&u, length: 32, index: 1)
    var edr: Float = 1; e.setFragmentBytes(&edr, length: 4, index: 6)
    e.setFragmentTexture(src, index: 3)
    e.setFragmentSamplerState(linearClamp, index: 0)
    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    e.endEncoding()
    return dst
}

/// 1/4 backdrop (2 downsamples from full res, inferred) + further mip levels with Apple's kernel.
/// `halvings` = number of halvings before building mips: 2 for backdropScale 0.25 (regular), 1 for 0.5 (clear).
func appleMipTexture(_ img: CGImage, halvings: Int = 2) -> MTLTexture {
    let full = texture(img)
    let cb = queue.makeCommandBuffer()!
    var level = downsample(full, cb)
    for _ in 1..<halvings { level = downsample(level, cb) }
    let out = tex16(level.width, level.height, mips: true)
    for i in 0..<out.mipmapLevelCount {
        let b = cb.makeBlitCommandEncoder()!
        b.copy(from: level, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
               sourceSize: .init(width: level.width, height: level.height, depth: 1),
               to: out, destinationSlice: 0, destinationLevel: i, destinationOrigin: .init(x: 0, y: 0, z: 0))
        b.endEncoding()
        if i + 1 < out.mipmapLevelCount { level = downsample(level, cb) }
    }
    cb.commit(); cb.waitUntilCompleted()
    return out
}

func half(_ v: Float) -> UInt16 {
    var f = v, h: UInt16 = 0
    var sb = vImage_Buffer(data: &f, height: 1, width: 1, rowBytes: 4)
    var db = vImage_Buffer(data: &h, height: 1, width: 1, rowBytes: 2)
    vImageConvert_PlanarFtoPlanar16F(&sb, &db, 0)
    return h
}

func unhalf(_ v: UInt16) -> Float {
    var h = v, f: Float = 0
    withUnsafeMutableBytes(of: &h) { hp in
        withUnsafeMutableBytes(of: &f) { fp in
            var sb = vImage_Buffer(data: hp.baseAddress, height: 1, width: 1, rowBytes: 2)
            var db = vImage_Buffer(data: fp.baseAddress, height: 1, width: 1, rowBytes: 4)
            _ = vImageConvert_Planar16FtoPlanarF(&sb, &db, 0)
        }
    }
    return f
}

/// Face color matrix per CA::ColorMatrix::set_ycc_composite (QuartzCore 26.6): 3 rows (r, g, b, bias),
/// c' = (1 - fa)(sat c + (white - black - sat) Y(c) + black) + fill.rgb fa, Y per BT.709.
func faceRows(black: Float, white: Float, sat: Float, fill: [Float]) -> [[Float]] {
    let L: [Float] = [0.2126, 0.7152, 0.0722], k = 1 - fill[3]
    return (0..<3).map { i in
        var row = L.map { (white - black - sat) * $0 * k }
        row[i] += sat * k
        return row + [black * k + fill[i] * fill[3]]
    }
}

/// Uniforms from the real CAFilter parameters of .regular on 26.6: blur radius 4,
/// face Aqua black 0.5, white 0.95, sat 1, fill (1,1,1,0.35); DarkAqua 0.2, 0.6, 1, (0,0,0,0.35).
func makeUniforms(dark: Bool = false, face customFace: [[Float]]? = nil) -> [UInt8] {
    var u = [UInt8](repeating: 0, count: 320)
    func f(_ off: Int, _ v: Float) { withUnsafeBytes(of: v) { u.replaceSubrange(off..<off + 4, with: $0) } }
    func h4(_ off: Int, _ v: [Float]) { for (i, x) in v.enumerated() { withUnsafeBytes(of: half(x)) { u.replaceSubrange(off + i * 2..<off + i * 2 + 2, with: $0) } } }
    f(0, halfSize.x); f(4, halfSize.y); f(8, 5); f(16, 1); f(28, 1)
    for i in 0..<4 { f(32 + i * 4, radius) }
    let b = 48
    f(b + 0, 1 / Float(W)); f(b + 12, -1 / Float(H))   // sdf y points up, uv y points down
    f(b + 16, -60); f(b + 20, 1 / 20); f(b + 32, -1); f(b + 36, 0)
    f(b + 40, 4); f(b + 48, 56); f(b + 52, 1 / 56)
    f(b + 56, 75); f(b + 60, 1 / 64); f(b + 68, 8); f(b + 76, 1)
    let face = customFace ?? (dark ? faceRows(black: 0.2, white: 0.6, sat: 1, fill: [0, 0, 0, 0.35])
                                   : faceRows(black: 0.5, white: 0.95, sat: 1, fill: [1, 1, 1, 0.35]))
    for (i, row) in face.enumerated() {
        h4(b + 80 + i * 8, row)
        var id: [Float] = [0, 0, 0, 0]; id[i] = 1; h4(b + 104 + i * 8, id)
    }
    f(b + 160, 1); f(b + 176, -3); f(b + 180, -2); f(b + 184, -1)
    f(b + 192, 1); f(b + 204, 1); f(b + 232, -1); f(b + 240, 1); f(b + 248, 1); f(b + 256, 1)
    return u
}
let uniforms = makeUniforms()

let quad: MTLBuffer = {
    var v: [Float] = []
    for (x, y) in [(0, 0), (W, 0), (0, H), (W, H)] {
        v += [Float(x) / Float(W) * 2 - 1, 1 - Float(y) / Float(H) * 2, 0, 1,
              Float(x) - center.x, center.y - Float(y), Float(x) / Float(W), Float(y) / Float(H)]  // sdf y up: offset (0,8) = downward
    }
    return device.makeBuffer(bytes: v, length: v.count * 4)!
}()

/// Draws 4 icons like the ButtonGroup sample (15pt, labelColor), identical for every column.
var iconAppearance = NSAppearance.Name.aqua   // switched to .darkAqua for dark mode rows
func drawIcons(_ img: CGImage) -> CGImage {
    bitmap(PW, PH) { ctx in
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        ctx.scaleBy(x: CGFloat(S), y: CGFloat(S))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // labelColor depends on the system appearance; force it to match the real screenshot (ButtonGroup uses Aqua).
        NSAppearance(named: iconAppearance)!.performAsCurrentDrawingAppearance {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(hierarchicalColor: .labelColor))
        for (i, name) in ["info", "square.and.arrow.up", "tag", "ellipsis"].enumerated() {
            let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
            let cx = CGFloat(center.x - halfSize.x) + 6 + 18 + CGFloat(i) * 36
            sym.draw(in: NSRect(x: cx - sym.size.width / 2, y: CGFloat(H) - CGFloat(center.y) - sym.size.height / 2,
                                width: sym.size.width, height: sym.size.height))
        }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

func render(_ pipeline: MTLRenderPipelineState, full: CGImage, quarter: MTLTexture, uniforms: [UInt8] = uniforms,
            highlight: [Float]? = nil, sdf: MTLTexture? = nil, verts: MTLBuffer = quad, appearance: UInt32? = nil,
            liveTint: Float = 0.5) -> CGImage {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: PW, height: PH, mipmapped: false)
    d.usage = [.renderTarget]; d.storageMode = .managed
    let target = device.makeTexture(descriptor: d)!
    let bg = full.dataProvider!.data! as Data
    var bgF = [Float](repeating: 0, count: PW * PH * 4)
    bg.withUnsafeBytes { p in for i in 0..<bgF.count { bgF[i] = Float(p[i]) / 255 } }
    target.replace(region: MTLRegionMake2D(0, 0, PW, PH), mipmapLevel: 0, withBytes: bgF, bytesPerRow: PW * 16)
    let cb = queue.makeCommandBuffer()!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .load; rp.colorAttachments[0].storeAction = .store
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(pipeline)
    var edr: Float = 1
    e.setVertexBuffer(verts, offset: 0, index: 30)
    e.setFragmentBytes(uniforms, length: uniforms.count, index: 1)
    e.setFragmentBytes(&edr, length: 4, index: 6)
    e.setFragmentTexture(quarter, index: 3)
    if let sdf { e.setFragmentTexture(sdf, index: 4) }
    if let appearance {   // GGLive {appearance flag, slider amount} that the dylib binds at buffer 28
        var live: (UInt32, Float) = (appearance, liveTint)
        e.setFragmentBytes(&live, length: 8, index: 28)
    }
    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    e.endEncoding()
    if let highlight {   // 27's highlight layer reads the glass result as its backdrop
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: PW, height: PH, mipmapped: false)
        cd.usage = [.shaderRead]; cd.storageMode = .private
        let copy = device.makeTexture(descriptor: cd)!
        let bc = cb.makeBlitCommandEncoder()!; bc.copy(from: target, to: copy); bc.endEncoding()
        let h = cb.makeRenderCommandEncoder(descriptor: rp)!
        h.setRenderPipelineState(highlightPSO)
        h.setVertexBuffer(quad, offset: 0, index: 30)
        h.setFragmentBytes(highlight, length: highlight.count * 4, index: 1)
        h.setFragmentTexture(copy, index: 0)
        h.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        h.endEncoding()
    }
    let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: target); b.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var out = [Float](repeating: 0, count: PW * PH * 4)
    target.getBytes(&out, bytesPerRow: PW * 16, from: MTLRegionMake2D(0, 0, PW, PH), mipmapLevel: 0)
    var px = out.map { UInt8(max(0, min(1, $0)) * 255 + 0.5) }
    let ctx = CGContext(data: &px, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return drawIcons(ctx.makeImage()!)
}

func diff(_ a: CGImage, _ b: CGImage) -> (CGImage, String) {
    let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
    var px = [UInt8](repeating: 255, count: PW * PH * 4)
    var maxd = 0, sum = 0
    for i in 0..<(PW * PH) { for c in 0..<3 {
        let d = abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])); maxd = max(maxd, d); sum += d
        px[i * 4 + c] = UInt8(min(255, d * 8))
    } }
    let ctx = CGContext(data: &px, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return (ctx.makeImage()!, String(format: "max %d/255, mean %.2f/255", maxd, Double(sum) / Double(PW * PH * 3)))
}

// Crop region around the capsule (points), for the comparison tiles.
let crop = CGRect(x: 80, y: 50, width: 200, height: 60)
func cropped(_ img: CGImage, scale s: Int) -> CGImage {
    img.cropping(to: CGRect(x: crop.minX * CGFloat(s), y: crop.minY * CGFloat(s), width: crop.width * CGFloat(s), height: crop.height * CGFloat(s)))!
}

let photo: CGImage? = NSImage(contentsOfFile: photoPath).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
var rows: [(String, [(String, CGImage)])] = []
for (name, src, native) in [("White background", nil as CGImage?, "buttongroup-white.png"), ("Photo background", photo, "buttongroup-image.png")] {
    let full = backdrop(src, PW, PH), quarter = appleMipTexture(full)
    let a = render(apple26, full: full, quarter: quarter), b = render(gg27, full: full, quarter: quarter, highlight: hlRegular)
    let (d, stat) = diff(a, b)
    print("\(name): difference 26 vs 27 \(stat)")
    // Find the 27 rim: darkest pixel in the 0..1.5pt band outside the edge, on the right side and the top edge.
    let pb = b.dataProvider!.data! as Data
    func darkest(_ pts: [(Int, Int)]) -> Int { pts.map { Int(pb[($0.1 * PW + $0.0) * 4 + 1]) }.min()! }
    let sideX = Int((center.x + halfSize.x) * Float(S)), topY = Int((center.y - halfSize.y) * Float(S))
    let side = darkest((0..<5).map { (sideX + $0, Int(center.y) * S) })
    let top = darkest((0..<5).map { (Int(center.x) * S, topY - 1 - $0) })
    print("  27 rim (G channel): side \(side)/255, top \(top)/255")
    var cols: [(String, CGImage)] = []
    if let n = NSImage(contentsOfFile: "\(outDir)/\(native)")?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        cols.append(("Real 26.6 screenshot (1x)", cropped(n, scale: 1)))
    }
    cols += [("Apple 26.6 shader", cropped(a, scale: S)), ("27 algorithm (reconstructed)", cropped(b, scale: S)),
             ("Difference × 8 (\(stat))", cropped(d, scale: S))]
    rows.append((name, cols))
}

// Per-channel check of the 27 rim against the 27.2.1 formula: on a solid background (rebuilt backdrop = real),
// rim pixel = T(H) with P = mix(B, min(grade(B), B), H), T = P(1 - bias H (3 - 2P)), bias = kfBias27.
// Solve H per channel; all 3 channels must give the same H.
do {
    let solid = bitmap(PW, PH) { $0.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: PW, height: PH)) }
    let quarter = appleMipTexture(solid)
    let out = render(gg27, full: solid, quarter: quarter).dataProvider!.data! as Data
    let bg = solid.dataProvider!.data! as Data
    let y = Int(center.y) * S, x0 = Int((center.x + halfSize.x) * Float(S))
    let x = (x0..<x0 + 5).min { out[(y * PW + $0) * 4 + 1] < out[(y * PW + $1) * 4 + 1] }!
    let i = (y * PW + x) * 4
    // grade(luma_compress(B)) with the face matrix the adapter builds (face27), rounded to half as in the shader.
    let B = (0..<3).map { Double(bg[i + $0]) / 255 }
    let C = lumaCompress(B, Double(Float(maxLumaComp27)))
    let G = face27.map { r -> Double in
        let q = r.map { Double(unhalf(half($0))) }
        return q[0] * C[0] + q[1] * C[1] + q[2] * C[2] + q[3]
    }
    let h = (0..<3).map { c -> Double in
        let b = B[c], o = Double(out[i + c]) / 255
        let g = min(G[c], b)
        func t(_ H: Double) -> Double { let p = b + (g - b) * H; return p * (1 - kfBias27 * H * (3 - 2 * p)) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let mid = (lo + hi) / 2; if t(mid) > o { lo = mid } else { hi = mid } }
        return (lo + hi) / 2
    }
    // Use the median H for all 3 channels; the residual must stay within 8-bit quantization.
    let hm = h.sorted()[1]
    let resid = (0..<3).map { c -> Double in
        let b = B[c], o = Double(out[i + c]) / 255, g = min(G[c], b)
        let p = b + (g - b) * hm
        return abs(p * (1 - kfBias27 * hm * (3 - 2 * p)) - o) * 255
    }
    let ok = hm > 0.1 && resid.max()! <= 1.5
    print(String(format: "per-channel rim check (27.2.1 formula): H = %.3f %.3f %.3f, residual %.2f %.2f %.2f /255 -> %@",
                 h[0], h[1], h[2], resid[0], resid[1], resid[2], ok ? "OK" : "FAIL"))
    if !ok { exit(1) }
}

// Automatic classification (the path running in WindowServer: no kVariant/kDarkMode): 26.6 regular light uniforms
// must give the same 27 result as when the harness forces regular light.
// Threshold 1/255: when the glass kind is constant (forced), the compiler pre-folds cos(spread), clamped_linear and the
// face rows before converting to half; the automatic path computes them on the GPU, a few ulps off, shifting half rounding.
// (Ruled out: not fast-math, not unassigned uniform fields; identical pipelines are bit-exact.)
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S); fc.setConstantValue(&plv, type: .float, index: 36)
    let auto = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    let full = backdrop(photo, PW, PH), quarter = appleMipTexture(full)
    // The default uniforms (0.5 / 0.95 / white 0.35) are 26.6's regular **inactive**, so the automatic path must draw
    // 27's regular inactive.
    let d = maxDiff(render(auto, full: full, quarter: quarter), render(gg27With([:], inactive: true, inBounds: true), full: full, quarter: quarter))
    print("automatic classification vs forced (regular inactive light): max \(d)/255 -> \(d <= 1 ? "OK" : "FAIL")")
    if d > 1 { exit(1) }
    // 26.6 regular active light (#4: 0.5 / 1.03 / white 0.4) -> 27 regular active. The automatic path (WindowServer) also
    // draws the 27 highlight layer inside the glass shader (WindowServer 26.6 has no such layer, 26.6 leaves alpha 0), so
    // it is compared with forced + a separate highlight layer as QuartzCore 27 draws it. hlTol threshold: the separate
    // layer reads the composited framebuffer and an analytic rounded SDF, the in-glass version reads the glass color
    // before compositing and the uniform SDF.
    let act = makeUniforms(face: faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]))
    let ha = render(auto, full: full, quarter: quarter, uniforms: act)
    let hb = render(gg27b, full: full, quarter: quarter, uniforms: act, highlight: inset(hlRegular))
    let ma = hlMatch(ha, hb)
    print("automatic (with highlight) vs forced + highlight layer (regular active light): \(ma.text) -> \(ma.ok ? "OK" : "FAIL")")
    if !ma.ok { diffReport(ha, hb); exit(1) }
    // Toolbar button on white (27 Settings capsule): interior 247-250 in the upper half, 252-253 in the lower half, nearly
    // independent of the slider; a 1 px gray ~235 rim outermost, with 1 px white 255 just inside.
    // Measures the capsule's middle column on the automatic path, slider 0.5 and 0 (tint 0 in use). Threshold ±2 around measurements.
    for a in [Float(0.5), 0] {
        let wf = MTLFunctionConstantValues()
        var plw = 1 / Float(S), aw = a
        wf.setConstantValue(&plw, type: .float, index: 36); wf.setConstantValue(&aw, type: .float, index: 27)
        let autoW = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: wf))
        let white = backdrop(nil, PW, PH, fill: .white)
        let p = render(autoW, full: white, quarter: appleMipTexture(white), uniforms: act).dataProvider!.data! as Data
        let cx = Int(center.x) * S
        func g(_ ypt: Float) -> Double { Double(p[(Int(ypt * Float(S)) * PW + cx) * 4 + 1]) }
        func mean(_ r: ClosedRange<Int>) -> Double { r.map { g(Float($0)) }.reduce(0, +) / Double(r.count) }
        let top = Int(center.y - halfSize.y)
        let upper = mean(top + 3...Int(center.y) - 3), lower = mean(Int(center.y) + 3...Int(center.y + halfSize.y) - 3)
        let rows = (top * S - 2...top * S + 6).map { Int(p[($0 * PW + cx) * 4 + 1]) }
        // Dark ring on both sides (the Settings button had lost 27's dark ring; 27 screenshots: sides 217-221 on 254):
        // darkest point around the left edge on the middle row, compared with the original 27 glass (forced, ring drawn
        // outside the edge + highlight layer).
        let ref = render(gg27With([27: a]), full: white, quarter: appleMipTexture(white), uniforms: act, highlight: hlRegular)
            .dataProvider!.data! as Data
        let ex = Int(center.x - halfSize.x) * S, cy = Int(center.y) * S
        func sideMin(_ q: Data) -> Int { (ex - 4...ex + 5).map { Int(q[(cy * PW + $0) * 4 + 1]) }.min()! }
        let sa = sideMin(p), sr = sideMin(ref)
        let ok = (245...252).contains(upper) && (250...255).contains(lower) && sa <= sr + 6
        print(String(format: "button on white, slider %.1f: upper interior %.1f (27: 247-250), lower %.1f (27: 252-253), top edge %@, left dark ring %d (original 27 %d) -> %@",
                     a, upper, lower, rows.description, sa, sr, ok ? "OK" : "FAIL"))
        if !ok { exit(1) }
    }
    // 26.6 Dock -> 27 DockRecipe (kVariant 4).
    for (dark, face) in [(false, faceRows(black: 0.15, white: 0.9, sat: 1.05, fill: [1, 1, 1, 0.1])),
                         (true, faceRows(black: 0.075, white: 0.9, sat: 1.06, fill: [0, 0, 0, 0.1]))] {
        let u = makeUniforms(face: face)
        let ia = render(auto, full: full, quarter: quarter, uniforms: u)
        let ib = render(gg27With([:], dark: dark, variant: 4, inBounds: true), full: full, quarter: quarter, uniforms: u,
                        highlight: inset(dark ? hlDockDark : hlDockLight))
        let md = hlMatch(ia, ib)
        let vs26 = maxDiff(render(apple26, full: full, quarter: quarter, uniforms: u), ia)
        let ok = md.ok && vs26 > 8
        print("Dock \(dark ? "dark" : "light"): automatic vs forced 27 Dock + highlight layer \(md.text), differs from 26.6 \(vs26)/255 -> \(ok ? "OK" : "FAIL")")
        if !ok { diffReport(ia, ib); exit(1) }
    }
}

// 26.6 adaptive glass (toolbar buttons, Music playback bar: the face keeps changing with hover and background brightness,
// so it cannot be matched exactly): draw full 27 regular (Golden Gate buttons are darker, gray interior 248-253 thanks to
// 27's face and max luma; keeping the 26.6 tone left the interior white as in 26). The automatic path must equal forced
// regular light. Two samples: a measured idle button face (0.411 / 0.245 / 0.641) and #6.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S); fc.setConstantValue(&plv, type: .float, index: 36)
    let auto = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    let full = backdrop(photo, PW, PH), quarter = appleMipTexture(full)
    for (name, face) in [("idle button", faceRows(black: 0.127, white: 0.723, sat: 1, fill: [1, 1, 1, 0.589])),
                         ("#6", faceRows(black: 0.75, white: 0.97, sat: 1.1, fill: [0, 0, 0, 0]))] {
        var u = makeUniforms(face: face)
        withUnsafeBytes(of: Float(0.8)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }   // blur 0.8 like the measured button
        let ia = render(auto, full: full, quarter: quarter, uniforms: u)
        let ib = render(gg27b, full: full, quarter: quarter, uniforms: u, highlight: inset(hlRegular))
        let m = hlMatch(ia, ib)
        print("adaptive glass (\(name)) vs forced 27 regular + highlight layer: \(m.text) -> \(m.ok ? "OK" : "FAIL")")
        if !m.ok { diffReport(ia, ib); exit(1) }
    }
    // 26.6 Mac Control Center (face 0.125 / 0.8 / 1.3, shader blur 3.2) -> 27 Mac ControlCenterRecipe (kVariant 5):
    // automatic equals forced, and differs from 26.6.
    var cc = makeUniforms(face: faceRows(black: 0.125, white: 0.8, sat: 1.3, fill: [0, 0, 0, 0]))
    withUnsafeBytes(of: Float(3.2)) { cc.replaceSubrange(48 + 40..<48 + 44, with: $0) }   // blur radius 3.2 as measured
    let ca = render(auto, full: full, quarter: quarter, uniforms: cc)
    let cb = render(gg27With([:], variant: 5, inBounds: true), full: full, quarter: quarter, uniforms: cc, highlight: inset(hlClear))
    let mcc = hlMatch(ca, cb)
    let v26 = maxDiff(ca, render(apple26, full: full, quarter: quarter, uniforms: cc))
    let okcc = mcc.ok && v26 > 8
    print("Control Center: automatic vs forced 27 CC + highlight layer \(mcc.text), differs from 26.6 \(v26)/255 -> \(okcc ? "OK" : "FAIL")")
    if !okcc { diffReport(ca, cb); exit(1) }
    // No drawing outside the glass edge on the automatic path: QuartzCore 26.6 only redraws glass within the frame it
    // computes from 26.6 parameters; anything drawn outside (the 27 dark rim 1 px outside, the ring shadow 8 points down) is
    // erased when content behind is redrawn, leaving a broken rim until the glass redraws (seen on the "..." button). Every
    // pixel more than 0.5 points outside the edge must match 26.6 (the 26.6 shadow keeps its parameters).
    do {
        let act = makeUniforms(face: faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]))
        let pa = render(auto, full: full, quarter: quarter, uniforms: act).dataProvider!.data! as Data
        let pb = render(apple26, full: full, quarter: quarter, uniforms: act).dataProvider!.data! as Data
        var worst = 0, at = (0, 0)
        for y in 0..<PH { for x in 0..<PW {
            let px = (Float(x) + 0.5) / Float(S) - center.x, py = (Float(y) + 0.5) / Float(S) - center.y
            let qx = abs(px) - (halfSize.x - radius), qy = abs(py) - (halfSize.y - radius)
            let d = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - radius
            if d <= 0.5 { continue }
            for c in 0..<3 {
                let i = (y * PW + x) * 4 + c, dv = abs(Int(pa[i]) - Int(pb[i]))
                if dv > worst { worst = dv; at = (x, y) }
            }
        } }
        print("outside the glass edge matches 26.6: max \(worst)/255 at pixel \(at) -> \(worst <= 1 ? "OK" : "FAIL")")
        if worst > 1 { exit(1) }
    }
    // Unknown faces with blur >= 3 used to keep 26.6 (to preserve unknown Control Center glass); the Settings toolbar button
    // lost 27's dark ring by falling into this branch, and everything must look like 27. Now drawn as 27 regular like adaptive glass.
    var odd = makeUniforms(face: faceRows(black: 0.3, white: 0.7, sat: 1.4, fill: [0, 0, 0, 0]))
    withUnsafeBytes(of: Float(3.2)) { odd.replaceSubrange(48 + 40..<48 + 44, with: $0) }
    let mo = hlMatch(render(auto, full: full, quarter: quarter, uniforms: odd),
                     render(gg27b, full: full, quarter: quarter, uniforms: odd, highlight: inset(hlRegular)))
    print("unknown face blur >= 3 draws 27 regular: \(mo.text) -> \(mo.ok ? "OK" : "FAIL")")
    if !mo.ok { exit(1) }
    // 26.6 clear base (#13: 0.075 / 1.15 / 1.06, background of Dock/Control Center/focusBorder) -> 27 clear (kVariant 1).
    let cb13 = makeUniforms(face: faceRows(black: 0.075, white: 1.15, sat: 1.06, fill: [0, 0, 0, 0]))
    let m13 = hlMatch(render(auto, full: full, quarter: quarter, uniforms: cb13),
                      render(gg27With([:], variant: 1, inBounds: true), full: full, quarter: quarter, uniforms: cb13, highlight: inset(hlClear)))
    print("clear base (#13) draws 27 clear: \(m13.text) -> \(m13.ok ? "OK" : "FAIL")")
    if !m13.ok { exit(1) }
    // Sidebar (ggapp GGApp.sidebarGlass writes the 27 SidebarRecipe face): the automatic path must draw exactly the 27
    // sidebar (kVariant 2: no highlight, ring, dark rim; max luma 0.85 light), light and dark. Light on white:
    // flat interior 235-238 as in 27 screenshots.
    for (dark, face) in [(false, faceRows(black: 0.4, white: 1.03, sat: 1.2, fill: [1, 1, 1, 0.2])),
                         (true, faceRows(black: 0.1, white: 0.5, sat: 0.6, fill: [0, 0, 0, 0]))] {
        let u = makeUniforms(face: face)
        let ia = render(auto, full: full, quarter: quarter, uniforms: u)
        let ib = render(gg27With([:], dark: dark, variant: 2, inBounds: true), full: full, quarter: quarter, uniforms: u)
        let d = maxDiff(ia, ib)
        try? NSBitmapImageRep(cgImage: ia).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(outDir)/sidebar-27-auto-\(dark ? "dark" : "light").png"))
        print("sidebar \(dark ? "dark" : "light"): automatic vs forced 27 sidebar: max \(d)/255 -> \(d <= 1 ? "OK" : "FAIL")")
        if d > 1 { diffReport(ia, ib); exit(1) }
    }
    do {
        // Short side like a real sidebar (~200 pt, constant 39): the sidebar edge bleed (darken, ycc 0.75/0.9/1.5) only
        // turns on when the short side >= 64, which the harness's 36 pt capsule lacks.
        let sf = MTLFunctionConstantValues()
        var pls = 1 / Float(S), xs: Float = 200
        sf.setConstantValue(&pls, type: .float, index: 36); sf.setConstantValue(&xs, type: .float, index: 39)
        let autoSB = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: sf))
        let white = backdrop(nil, PW, PH, fill: .white)
        let u = makeUniforms(face: faceRows(black: 0.4, white: 1.03, sat: 1.2, fill: [1, 1, 1, 0.2]))
        let p = render(autoSB, full: white, quarter: appleMipTexture(white), uniforms: u).dataProvider!.data! as Data
        let mid = Int(p[(Int(center.y) * S * PW + Int(center.x) * S) * 4 + 1])
        print("light sidebar on white: interior \(mid) (27: 235-238) -> \((234...239).contains(mid) ? "OK" : "FAIL")")
        if !(234...239).contains(mid) { exit(1) }
    }
}

// Real toolbar buttons (WindowServer dump): 73x36 button groups of Settings and Finder, in both light and dark appearance,
// same face (sat 1.3, W - B - sat -0.78..-0.95, black 0.1), blur 0.4-0.8, taking the adaptive glass branch. In light
// appearance the real 27 button has a dark ring at the edge (27 screenshots: sides 217-221 on 254). The light Settings
// button had lost the ring, with a white rim. Measures the middle row around the left edge and the middle column around
// the top edge, on a light toolbar-like background (243 Settings, 250 Finder).
// Adaptive glass faces change with background brightness and carry no light/dark information: guessing from the face drew
// the light Settings button as dark 27 glass (debug capture: interior ≈ 185 like the dark branch, Finder ≈ 247). Light/dark
// comes from the system appearance (constant 46 = dark, set by the dylib from AppleInterfaceStyle): in light appearance the
// button is light glass (interior close to the background) with a dark ring.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S), sysDark = false
    fc.setConstantValue(&plv, type: .float, index: 36); fc.setConstantValue(&sysDark, type: .bool, index: 46)
    let auto = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    for (bgName, gray) in [("Settings", CGFloat(243) / 255), ("Finder", CGFloat(250) / 255)] {
        let full = backdrop(nil, PW, PH, fill: CGColor(gray: gray, alpha: 1)), quarter = appleMipTexture(full)
        for kw in [Float(-0.78), -0.9] {
            var u = makeUniforms(face: faceRows(black: 0.1, white: 1.3 + kw + 0.1, sat: 1.3, fill: [0, 0, 0, 0]))
            withUnsafeBytes(of: Float(0.4)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }
            let p = render(auto, full: full, quarter: quarter, uniforms: u).dataProvider!.data! as Data
            let ex = Int(center.x - halfSize.x) * S, cy = Int(center.y) * S, cx = Int(center.x) * S, ty = Int(center.y - halfSize.y) * S
            let side = (ex - 2...ex + 5).map { Int(p[(cy * PW + $0) * 4 + 1]) }
            let top = (ty - 2...ty + 5).map { Int(p[($0 * PW + cx) * 4 + 1]) }
            let mid = Int(p[(cy * PW + cx) * 4 + 1]), bg = Int(gray * 255)
            let ok = side.min()! < bg - 10 && top.min()! < bg - 3 && mid >= bg - 15
            print("real toolbar button (kw \(kw)), light appearance, \(bgName) background \(bg): left edge \(side), top edge \(top), interior \(mid) -> \(ok ? "OK" : "FAIL")")
            if !ok { exit(1) }
        }
    }
    // Live appearance switch (no WindowServer restart): the dylib binds the appearance flag (uint, 1 = dark) at buffer 28
    // every time one of our glass pipelines is bound (constant 47 enables reading the buffer). With the same pipeline, flag 0
    // must give light glass (interior close to the background), flag 1 dark glass (clearly dark interior). The flag takes
    // priority over constant 46.
    let lf = MTLFunctionConstantValues()
    var plw = 1 / Float(S), useBuf = true, stale = true
    lf.setConstantValue(&plw, type: .float, index: 36); lf.setConstantValue(&useBuf, type: .bool, index: 47)
    lf.setConstantValue(&stale, type: .bool, index: 46)   // a stale constant 46 (dark) must be overridden by the flag
    let live = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: lf))
    let full = backdrop(nil, PW, PH, fill: CGColor(gray: 243.0 / 255, alpha: 1)), quarter = appleMipTexture(full)
    var u = makeUniforms(face: faceRows(black: 0.1, white: 1.3 - 0.8 + 0.1, sat: 1.3, fill: [0, 0, 0, 0]))
    withUnsafeBytes(of: Float(0.4)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }
    func midG(_ img: CGImage) -> Int { let p = img.dataProvider!.data! as Data; return Int(p[((Int(center.y) * S) * PW + Int(center.x) * S) * 4 + 1]) }
    let ml = midG(render(live, full: full, quarter: quarter, uniforms: u, appearance: 0))
    let md = midG(render(live, full: full, quarter: quarter, uniforms: u, appearance: 1))
    let okLive = ml >= 228 && md <= 200
    print("live appearance switch (same pipeline, buffer 28 flag): light interior \(ml), dark \(md) -> \(okLive ? "OK" : "FAIL")")
    if !okLive { exit(1) }

    // Runtime slider amount: GGLive.diffusion at buffer 28, or the code P = 2 + 2 round(a 1000) + flag in preserve_hue
    // (offset 48 + 244), must give exactly the same as constant 27 = a.
    func autoPSO(_ consts: [Int: Float], dark: Bool, live: Bool) -> MTLRenderPipelineState {
        let f = MTLFunctionConstantValues()
        var pl = 1 / Float(S), sd = dark, lb = live
        f.setConstantValue(&pl, type: .float, index: 36); f.setConstantValue(&sd, type: .bool, index: 46)
        if live { f.setConstantValue(&lb, type: .bool, index: 47) }
        for (i, v) in consts { var x = v; f.setConstantValue(&x, type: .float, index: i) }
        return pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: f))
    }
    func withPreserve(_ u: [UInt8], _ p: Float) -> [UInt8] {
        var u = u; withUnsafeBytes(of: p) { u.replaceSubrange(48 + 244..<48 + 248, with: $0) }; return u
    }
    let photoBg = backdrop(photo, PW, PH), photoQ = appleMipTexture(photoBg)
    var okTint = true
    for dark in [false, true] {
        let ud = makeUniforms(dark: dark), livePSO = autoPSO([:], dark: dark, live: true)
        for a: Float in [0, 0.5, 1] {
            let ref = render(autoPSO([27: a], dark: dark, live: false), full: photoBg, quarter: photoQ, uniforms: ud)
            let d1 = maxDiff(render(livePSO, full: photoBg, quarter: photoQ, uniforms: ud, appearance: dark ? 1 : 0, liveTint: a), ref)
            print("runtime slider amount (buffer 28) a \(a) \(dark ? "dark" : "light"): diff \(d1)/255 -> \(d1 == 0 ? "OK" : "FAIL")")
            if d1 != 0 { okTint = false }
        }
        let ref03 = render(autoPSO([27: 0.3], dark: dark, live: false), full: photoBg, quarter: photoQ, uniforms: ud)
        let d2 = maxDiff(render(autoPSO([:], dark: dark, live: false), full: photoBg, quarter: photoQ, uniforms: withPreserve(ud, 602)), ref03)
        print("preserve_hue 602 carries a 0.3 \(dark ? "dark" : "light"): diff \(d2)/255 -> \(d2 == 0 ? "OK" : "FAIL")")
        let ref03p = render(autoPSO([27: 0.3], dark: dark, live: false), full: photoBg, quarter: photoQ, uniforms: withPreserve(ud, 1))
        let d3 = maxDiff(render(autoPSO([:], dark: dark, live: false), full: photoBg, quarter: photoQ, uniforms: withPreserve(ud, 603)), ref03p)
        print("preserve_hue 603 keeps preserve flag 1 \(dark ? "dark" : "light"): diff \(d3)/255 -> \(d3 == 0 ? "OK" : "FAIL")")
        let ref0 = render(autoPSO([27: 0], dark: dark, live: false), full: photoBg, quarter: photoQ, uniforms: ud)
        let d4 = maxDiff(render(livePSO, full: photoBg, quarter: photoQ, uniforms: withPreserve(ud, 2), appearance: dark ? 1 : 0, liveTint: 1), ref0)
        print("per-glass code beats buffer 28 \(dark ? "dark" : "light"): diff \(d4)/255 -> \(d4 == 0 ? "OK" : "FAIL")")
        if d2 != 0 || d3 != 0 || d4 != 0 { okTint = false }
    }
    // Per-glass appearance (negative code written by ggapp from the view's effectiveAppearance): adaptive glass (#5, face
    // carries no light/dark) with a dark code while the global flag is light must be bit-exact with the global flag dark,
    // and vice versa.
    do {
        let ua = makeUniforms(face: faceRows(black: 0.8, white: 0.97, sat: 1, fill: [1, 1, 1, 0.25])), livePSO = autoPSO([:], dark: false, live: true)
        func r(_ code: Float, _ sys: UInt32) -> CGImage { render(livePSO, full: photoBg, quarter: photoQ, uniforms: withPreserve(ua, code), appearance: sys) }
        let dDark = maxDiff(r(-1004, 0), r(1002, 1)), dLight = maxDiff(r(-1002, 1), r(1002, 0)), dDiff = maxDiff(r(1002, 0), r(1002, 1))
        let ok = dDark == 0 && dLight == 0 && dDiff > 8
        print("adaptive glass own appearance: dark code/system light diff \(dDark), light code/system dark diff \(dLight) (light vs dark \(dDiff)) -> \(ok ? "OK" : "FAIL")")
        if !ok { okTint = false }
    }
    if !okTint { exit(1) }
}

// Quick Look "clear then frosted": the shader's blur radius is in source_texture texels; QuartzCore changes the backdrop
// scale over time (Quick Look: 1.0 while zooming, 0.25 when still) and 26.6 multiplies the radius by that scale (shader =
// 1.6 x texels/point x CA). The same glass with backdrops at two scales 4x apart (1/4 and 1/16 framebuffer mips) must look
// the same: the mean interior difference must be as small as 26.6's.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S); fc.setConstantValue(&plv, type: .float, index: 36)
    let auto = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    let full = backdrop(photo, PW, PH)
    let hi = appleMipTexture(full, halvings: 2), lo = appleMipTexture(full, halvings: 4)
    let act = makeUniforms(face: faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]))
    func interiorMean(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
        var s = 0.0, n = 0
        for y in 0..<PH { for x in 0..<PW {
            let qx = abs((Float(x) + 0.5) / Float(S) - center.x) - (halfSize.x - radius)
            let qy = abs((Float(y) + 0.5) / Float(S) - center.y) - (halfSize.y - radius)
            let d = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - radius
            if d > -3 { continue }
            for c in 0..<3 { let i = (y * PW + x) * 4 + c; s += abs(Double(pa[i]) - Double(pb[i])) }
            n += 3
        } }
        return s / Double(n)
    }
    // 26.6 receives the scaled radius from QuartzCore: a separate blur uniform per scale (4 x 1.6 x texels/point).
    func with26Blur(_ u: [UInt8], _ tex: MTLTexture) -> [UInt8] {
        var v = u
        withUnsafeBytes(of: Float(4 * 1.6) * Float(tex.width) / Float(W)) { v.replaceSubrange(48 + 40..<48 + 44, with: $0) }
        return v
    }
    let m27 = interiorMean(render(auto, full: full, quarter: hi, uniforms: act), render(auto, full: full, quarter: lo, uniforms: act))
    let m26 = interiorMean(render(apple26, full: full, quarter: hi, uniforms: with26Blur(act, hi)),
                           render(apple26, full: full, quarter: lo, uniforms: with26Blur(act, lo)))
    let ok = m27 <= max(2 * m26, 3)
    print(String(format: "same glass, backdrop texel scales 4x apart (Quick Look): mean diff 27 %.2f/255, 26.6 %.2f/255 -> %@",
                 m27, m26, ok ? "OK" : "FAIL"))
    if !ok { exit(1) }
}

// Show/hide animations (measured on a WindowServer dump): 26.6 interpolates the face linearly from identity to the target
// recipe by progress t, blur = B t (2 - t). The automatic path must draw the 27 glass of the target recipe at the same
// progress (no 26.6 mixing, it must look like 27): nearly invisible at small t, growing steadily, matching the final frame
// near the end. Old bug: interpolated faces did not match kSigs26, so full light 27 regular was drawn right away (an opaque
// white patch when opening Control Center in dark mode, a white ghost when closing Quick Look), and blur >= 3 jumped to 26.6.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S); fc.setConstantValue(&plv, type: .float, index: 36)
    let auto = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    let full = backdrop(nil, PW, PH, fill: CGColor(gray: 0.12, alpha: 1)), quarter = appleMipTexture(full)   // dark background
    let pf = full.dataProvider!.data! as Data
    func animUniforms(_ rows: [[Float]], _ blur: Float, _ t: Float) -> [UInt8] {
        let face = (0..<3).map { i in (0..<4).map { j in (1 - t) * (i == j ? 1 : 0) + t * rows[i][j] } }
        var u = makeUniforms(face: face)
        withUnsafeBytes(of: blur * t * (2 - t)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }
        return u
    }
    /// Glass strength: mean difference from the background in the glass interior (more than 3 points from the edge).
    func strength(_ img: CGImage) -> Double {
        let p = img.dataProvider!.data! as Data
        var s = 0.0, n = 0
        for y in 0..<PH { for x in 0..<PW {
            let qx = abs((Float(x) + 0.5) / Float(S) - center.x) - (halfSize.x - radius)
            let qy = abs((Float(y) + 0.5) / Float(S) - center.y) - (halfSize.y - radius)
            let d = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - radius
            if d > -3 { continue }
            for c in 0..<3 { let i = (y * PW + x) * 4 + c; s += abs(Double(p[i]) - Double(pf[i])) }
            n += 3
        } }
        return s / Double(n)
    }
    for (name, rows, blur) in [("Control Center", faceRows(black: 0.125, white: 0.8, sat: 1.3, fill: [0, 0, 0, 0]), Float(3.2)),
                               ("regular light (Quick Look, dialog)", faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]), 1.6),
                               ("regular dark", faceRows(black: 0.2, white: 0.6, sat: 1, fill: [0, 0, 0, 0.4]), 1.6)] {
        let ts: [Float] = [0.002, 0.1, 0.3, 0.6, 0.9]
        let s = ts.map { strength(render(auto, full: full, quarter: quarter, uniforms: animUniforms(rows, blur, $0))) }
        let fin = strength(render(auto, full: full, quarter: quarter, uniforms: animUniforms(rows, blur, 1)))
        let rising = zip(s, s.dropFirst()).allSatisfy { $0 < $1 }
        let ok = rising && s[0] < 0.05 * fin + 0.5 && s[1] < 0.5 * fin && s[4] > 0.8 * fin && s[4] < 1.05 * fin + 0.5
        print(String(format: "animation %@: strength t = 0.002 / 0.1 / 0.3 / 0.6 / 0.9 = %.1f / %.1f / %.1f / %.1f / %.1f, final frame %.1f -> %@",
                     name, s[0], s[1], s[2], s[3], s[4], fin, ok ? "OK" : "FAIL"))
        if !ok { exit(1) }
    }
}

// Anti-flicker: QuartzCore sometimes draws the same glass with the SDF variant and sometimes with the texture variant
// (Dock while magnifying, buttons on hover). Both must give the same result. sdf_texture is "baked" with the uniforms' own
// compute_sdf_with_mode, covering a box around the capsule (24 point margin, 1 texel per pixel); the texture variant's
// shadow_offset is converted to uv as QuartzCore does.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S); fc.setConstantValue(&plv, type: .float, index: 36)
    let sdfPath = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    let texPath = pso(try! ourLib.makeFunction(name: "gg27_glass_background_lpf", constantValues: fc), vertex: "harness_tex_vert")
    let apple26Tex = pso(appleLib.makeFunction(name: "glass_background_lpf")!, vertex: "harness_tex_vert")
    let bake = try! device.makeComputePipelineState(function: ourLib.makeFunction(name: "harness_bake_sdf")!)
    let full = backdrop(photo, PW, PH), quarter = appleMipTexture(full)
    /// Draws the texture variant: sdf_texture covers a box around the capsule (24 point margin), extended extraRight points to the right.
    /// res: sdf_texture texels per point (default S: 1 texel per harness pixel; real 1x display: 1).
    /// unit: distance units per texel (QuartzCore: ~1; otherwise geometric texels/point no longer equal units/point, as
    /// with the Settings toolbar button that still lost its ring on 3 edges after the texel -> point fix).
    func texRender(_ u: [UInt8], extraRight: Float = 0, band: Float = 0, path: MTLRenderPipelineState? = nil,
                   res: Float = Float(S), unit: Float = 1) -> CGImage {
        let margin: Float = 24
        let bmin = center - halfSize - margin, bsize = (halfSize + margin) * 2 + SIMD2<Float>(extraRight, 0)
        let tw = Int(bsize.x * res), th = Int(bsize.y * res)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: tw, height: th, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        let sdfTex = device.makeTexture(descriptor: td)!
        let cb = queue.makeCommandBuffer()!, ce = cb.makeComputeCommandEncoder()!
        ce.setComputePipelineState(bake); ce.setTexture(sdfTex, index: 0)
        u.withUnsafeBytes { ce.setBytes($0.baseAddress!, length: 48, index: 0) }
        var box = SIMD4<Float>(bmin.x, bmin.y, bsize.x, bsize.y); ce.setBytes(&box, length: 16, index: 1)
        var ctr = center; ce.setBytes(&ctr, length: 8, index: 2)
        var bd = band; ce.setBytes(&bd, length: 4, index: 3)
        var un = unit; ce.setBytes(&un, length: 4, index: 4)
        ce.dispatchThreads(MTLSize(width: tw, height: th, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        ce.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var v: [Float] = []   // attribute 1 = texcoord1 (sdf_texture uv) at the frame corners
        for (x, y) in [(0, 0), (W, 0), (0, H), (W, H)] {
            v += [Float(x) / Float(W) * 2 - 1, 1 - Float(y) / Float(H) * 2, 0, 1,
                  (Float(x) - bmin.x) / bsize.x, (Float(y) - bmin.y) / bsize.y, Float(x) / Float(W), Float(y) / Float(H)]
        }
        let texQuad = device.makeBuffer(bytes: v, length: v.count * 4)!
        var tu = Array(u[48...])   // texture variant: glass part only; shadow_offset (points, y up) -> uv (y down)
        var so = SIMD2<Float>(0, 0)
        _ = withUnsafeMutableBytes(of: &so) { tu.copyBytes(to: $0, from: 64..<72) }
        so = SIMD2(so.x / bsize.x, -so.y / bsize.y)
        withUnsafeBytes(of: so) { tu.replaceSubrange(64..<72, with: $0) }
        return render(path ?? texPath, full: full, quarter: quarter, uniforms: tu, sdf: sdfTex, verts: texQuad)
    }
    let sdfImg = render(sdfPath, full: full, quarter: quarter), texImg = texRender(uniforms)
    let d = maxDiff(sdfImg, texImg)
    print("texture variant vs SDF variant (same glass, regular light): max \(d)/255 -> \(d <= 4 ? "OK" : "FAIL")")
    if d > 4 { diffReport(texImg, sdfImg); exit(1) }
    // Distance units other than texels (2 and 0.5 units per texel): the band near the edge (dark ring, highlight) takes its
    // unit from the SDF's own slope, so it must still match the SDF variant. The interior (estimated short side) shifts by
    // that ratio and is not checked (limitation noted in the shader).
    do {
        let ps = sdfImg.dataProvider!.data! as Data
        let ex = Int(center.x - halfSize.x) * S, cy = Int(center.y) * S, cx = Int(center.x) * S, ty = Int(center.y - halfSize.y) * S
        func band(_ q: Data) -> [Int] {
            (ex - 3...ex + 6).map { Int(q[(cy * PW + $0) * 4 + 1]) } + (ty - 3...ty + 6).map { Int(q[($0 * PW + cx) * 4 + 1]) }
        }
        for unit: Float in [2, 0.5] {
            let pt = texRender(uniforms, unit: unit).dataProvider!.data! as Data
            let worst = zip(band(ps), band(pt)).map { abs($0 - $1) }.max()!
            print("sdf_texture \(unit) units per texel: left/top edge band texture vs SDF variant diff \(worst) -> \(worst <= 8 ? "OK" : "FAIL")")
            if worst > 8 { exit(1) }
        }
    }
    // The real sdf_texture is an atlas (captured from WindowServer: RGBA16Float, size a multiple of 64, the glass takes one
    // cell, texels at the texture center are empty x = 0, w = 0). Estimating the short side as 2 x the depth at the texture
    // center gives 0: the Settings toolbar button lost its dark ring, white rim. Glass offset to a texture corner (texture
    // center outside the shape) must match the SDF variant over the whole glass, not just outside the edge.
    do {
        let btn = makeUniforms(face: faceRows(black: 0.1, white: 1.3 - 0.8 + 0.1, sat: 1.3, fill: [0, 0, 0, 0]))
        let atlasS = render(sdfPath, full: full, quarter: quarter, uniforms: btn), atlasT = texRender(btn, extraRight: 200)
        let dAtlas = maxDiff(atlasS, atlasT)
        print("atlas sdf_texture (texture center outside glass): texture vs SDF variant max \(dAtlas)/255 -> \(dAtlas <= 4 ? "OK" : "FAIL")")
        if dAtlas > 4 { diffReport(atlasT, atlasS); exit(1) }
    }
    // Real toolbar buttons (Finder, Settings) take the texture variant with a 1 texel per point sdf_texture (1x display),
    // 3x coarser than the harness. The 27 dark ring at the edge (key/fill rim, ~1 px tall) must remain as in the SDF
    // variant. Measures the middle row around the left edge, regular active.
    do {
        let act = makeUniforms(face: faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]))
        let ps = render(sdfPath, full: full, quarter: quarter, uniforms: act).dataProvider!.data! as Data
        let ex = Int(center.x - halfSize.x) * S, cy = Int(center.y) * S
        func edge(_ q: Data) -> [Int] { (ex - 3...ex + 6).map { Int(q[(cy * PW + $0) * 4 + 1]) } }
        for res in [Float(S), 1] {
            let pt = texRender(act, res: res).dataProvider!.data! as Data
            let es = edge(ps), et = edge(pt)
            let worst = zip(es, et).map { abs($0 - $1) }.max()!
            print("left edge dark ring, texture variant \(Int(res)) texel/point vs SDF variant: \(et) vs \(es), diff \(worst) -> \(worst <= 8 ? "OK" : "FAIL")")
            if worst > 8 { exit(1) }
        }
    }
    // Mid show/hide animation (Quick Look, dialogs, Control Center: QuartzCore often switches to the texture variant while
    // the shape changes) both variants must also match, or the glass flickers.
    for (name, rows, blur) in [("regular light", faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]), Float(1.6)),
                               ("Control Center", faceRows(black: 0.125, white: 0.8, sat: 1.3, fill: [0, 0, 0, 0]), 3.2)] {
        let t: Float = 0.5
        var u = makeUniforms(face: (0..<3).map { i in (0..<4).map { j in (1 - t) * (i == j ? 1 : 0) + t * rows[i][j] } })
        withUnsafeBytes(of: blur * t * (2 - t)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }
        let dm = maxDiff(render(sdfPath, full: full, quarter: quarter, uniforms: u), texRender(u))
        print("mid animation (\(name), t = 0.5): texture vs SDF variant max \(dm)/255 -> \(dm <= 4 ? "OK" : "FAIL")")
        if dm > 4 { exit(1) }
    }
    // Per-glass slider amount (preserve_hue carries a code): Control Center (clear group) enables blur fill when a > 0.5, so
    // at a = 1 both variants must match (2026-11-19: hovering Control Center flashed frosted glass for 1 frame when
    // switching to the texture variant).
    for (code, label) in [(Float(2002), "a = 1"), (Float(2), "a = 0")] {
        var u = makeUniforms(face: faceRows(black: 0.125, white: 0.8, sat: 1.3, fill: [0, 0, 0, 0]))
        withUnsafeBytes(of: Float(3.2)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }
        withUnsafeBytes(of: code) { u.replaceSubrange(48 + 244..<48 + 248, with: $0) }
        let sImg = render(sdfPath, full: full, quarter: quarter, uniforms: u), tImg = texRender(u)
        let dm = maxDiff(sImg, tImg)
        print("Control Center \(label) (preserve_hue \(Int(code))): texture vs SDF variant max \(dm)/255 -> \(dm <= 4 ? "OK" : "FAIL")")
        if dm > 4 { diffReport(tImg, sImg); exit(1) }
        // Real 1x display: sdf_texture with 1 texel per point. a = 0 disables blur (Control Center blur 4 x 2a) and
        // refraction is -2 x short side, so a short side estimated from sdf_texture off by half a point shows clearly
        // (27 has an explicit short side, no error).
        let t1 = texRender(u, res: 1), d1 = maxDiff(sImg, t1)
        print("Control Center \(label), texture variant 1 texel/point vs SDF variant: max \(d1)/255 -> \(d1 <= 8 ? "OK" : "FAIL")")
        if d1 > 8 { diffReport(t1, sImg); exit(1) }
    }
    // debugSize (constant 45): colors by the short side the adapter uses (< 64 red, 64-160 green, >= 160 blue), to see on
    // the real machine whether the texture variant estimates the short side differently from the SDF variant (Quick Look
    // turns from clear to frosted exactly when QuartzCore switches from SDF to texture). Harness capsule: 36 points -> red in both.
    do {
        let fs = MTLFunctionConstantValues()
        var plz = 1 / Float(S), on = true
        fs.setConstantValue(&plz, type: .float, index: 36); fs.setConstantValue(&on, type: .bool, index: 45)
        let sdfDbg = render(pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fs)),
                            full: full, quarter: quarter)
        let texDbg = texRender(uniforms, path: pso(try! ourLib.makeFunction(name: "gg27_glass_background_lpf", constantValues: fs),
                                                   vertex: "harness_tex_vert"))
        func red(_ img: CGImage) -> Bool {
            let p = img.dataProvider!.data! as Data, i = ((Int(center.y) * S) * PW + Int(center.x) * S) * 4
            return Int(p[i]) > Int(p[i + 1]) + 60 && Int(p[i]) > Int(p[i + 2]) + 60
        }
        let ok = red(sdfDbg) && red(texDbg)
        print("debugSize: 36 point capsule red in SDF variant \(red(sdfDbg)), texture variant \(red(texDbg)) -> \(ok ? "OK" : "FAIL")")
        if !ok { exit(1) }
    }
    // sdf_texture center outside the shape (text textures, textures holding several shapes like the Spotlight bar): the
    // short side estimated from the texture center is 0, and a rectangular frame appeared around texture-variant glass.
    // Outside the edge must match 26.6.
    // Also: an sdf_texture with SDF only in a 4 point band around the edge, empty outside (distance 0, coverage 0): a 27 dark
    // rim and highlight based on distance alone would think the whole frame is on the edge (dark frame around the lock clock).
    let act = makeUniforms(face: faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]))
    // Reference: Apple's 26.6 texture shader on the same sdf_texture (26.6 also reads the shadow from the texture; empty band means no shadow).
    for (name, ex, bd) in [("texture center outside the shape", Float(200), Float(0)), ("SDF only in a 4 point band around the edge", 0, 4)] {
        let pa = texRender(act, extraRight: ex, band: bd).dataProvider!.data! as Data
        let pb = texRender(act, extraRight: ex, band: bd, path: apple26Tex).dataProvider!.data! as Data
        var worst = 0, at = (0, 0), atD: Float = 0, over = 0
        for y in 0..<PH { for x in 0..<PW {
            let px = (Float(x) + 0.5) / Float(S) - center.x, py = (Float(y) + 0.5) / Float(S) - center.y
            let qx = abs(px) - (halfSize.x - radius), qy = abs(py) - (halfSize.y - radius)
            let dd = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - radius
            if dd <= 0.5 { continue }
            for c in 0..<3 {
                let i = (y * PW + x) * 4 + c, dv = abs(Int(pa[i]) - Int(pb[i]))
                if dv > 2 { over += 1 }
                if dv > worst { worst = dv; at = (x, y); atD = dd }
            }
        } }
        let wi = (at.1 * PW + at.0) * 4
        print("texture variant, \(name): outside the edge matches 26.6 max \(worst)/255 at \(at) (\(atD) points from the edge, "
              + "\(Array(pa[wi..<wi + 4])) vs \(Array(pb[wi..<wi + 4])), \(over) channels off > 2) -> \(worst <= 2 ? "OK" : "FAIL")")
        if worst > 2 { exit(1) }
    }
}

// Slider diffusion (27's NSGlassTintAmount): checks and renders 0 / 0.5 / 1.
/// Diagnostics when a comparison fails: the most different pixel (point coordinates relative to the capsule center) and
/// the number of channels off by more than hlTol.
func diffReport(_ a: CGImage, _ b: CGImage) {
    let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
    var k = 0, best = -1, over = 0
    for i in 0..<pa.count where i % 4 != 3 {
        let d = abs(Int(pa[i]) - Int(pb[i]))
        if d > best { best = d; k = i }
        if d > hlTol { over += 1 }
    }
    let x = Float(k / 4 % PW) / Float(S) - center.x, y = Float(k / 4 / PW) / Float(S) - center.y
    print(String(format: "  largest diff at (%.1f, %.1f) points from center, channel %d: %d vs %d; channels off > %d: %d / %d",
                 x, y, k % 4, Int(pa[k]), Int(pb[k]), hlTol, over, pa.count / 4 * 3))
}
func maxDiff(_ a: CGImage, _ b: CGImage) -> Int {
    let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
    var m = 0
    for i in 0..<pa.count where i % 4 != 3 { m = max(m, abs(Int(pa[i]) - Int(pb[i]))) }
    return m
}
/// Background detail remaining through the glass: mean |luma gradient| in the capsule's bottom band (below the icons)
/// divided by the same measure on the background. Real 27 screenshots: ~30% at the clear end,
/// 6-25% in the middle, 1-13% at the opaque end.
func detailRatio(_ img: CGImage, _ bg: CGImage) -> Double {
    func grad(_ c: CGImage) -> Double {
        let p = c.dataProvider!.data! as Data
        func l(_ x: Int, _ y: Int) -> Double { let i = (y * PW + x) * 4; return 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2]) }
        var s = 0.0, n = 0.0
        for y in (Int(center.y) + 10) * S..<(Int(center.y) + 15) * S {
            for x in (Int(center.x) - 60) * S..<(Int(center.x) + 60) * S { s += abs(l(x + 1, y) - l(x, y)) + abs(l(x, y + 1) - l(x, y)); n += 1 }
        }
        return s / n
    }
    return grad(img) / grad(bg)
}

/// Text background like the web page behind the Now Playing bar in a 9to5Mac screenshot: 13 pt dark gray text on white.
func textBackdrop() -> CGImage {
    bitmap(PW, PH) { ctx in
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: PW, height: PH))
        ctx.scaleBy(x: CGFloat(S), y: CGFloat(S))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.2, alpha: 1)]
        let line = "What could've just been another county landfill, slated to open in 2027, will instead be a campus "
        for i in 0..<10 { NSAttributedString(string: line, attributes: font).draw(at: CGPoint(x: -CGFloat(i * 17 % 60), y: CGFloat(i * 17))) }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Like the verification measurement for Now Playing: luma standard deviation in the capsule's bottom band
/// divided by the text background's standard deviation in the same band. Real screenshots: 39% / 9% / 3% (clear / middle / opaque).
func stdRatio(_ img: CGImage, _ bg: CGImage) -> Double {
    func sd(_ c: CGImage) -> Double {
        let p = c.dataProvider!.data! as Data
        var v: [Double] = []
        for y in (Int(center.y) + 10) * S..<(Int(center.y) + 15) * S {
            for x in (Int(center.x) - 60) * S..<(Int(center.x) + 60) * S {
                let i = (y * PW + x) * 4; v.append(0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2]))
            }
        }
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }
    return sd(img) / sd(bg)
}
do {
    let full = textBackdrop(), quarter = appleMipTexture(full)
    let r = [0, 0.5, 1].map { a -> Double in
        stdRatio(render(gg27With([kDiffusionIndex: Float(a)]), full: full, quarter: quarter, highlight: hlRegular), full)
    }
    print(String(format: "text background, std inside/outside: 26.6 %.0f%%; 27 slider 0 %.0f%%, 0.5 %.0f%%, 1 %.0f%% (real 39 / 9 / 3)",
                 stdRatio(render(apple26, full: full, quarter: quarter), full) * 100, r[0] * 100, r[1] * 100, r[2] * 100))
}

var sliderRows: [(String, [(String, CGImage)])] = [], sliderRowsDark: [(String, [(String, CGImage)])] = []
for dark in [false, true] {
    iconAppearance = dark ? .darkAqua : .aqua
    let solid: CGColor = dark ? CGColor(gray: 0.12, alpha: 1) : .white
    for (name, src) in [(dark ? "Dark background" : "White background", nil as CGImage?), ("Photo background", photo)] {
        let full = backdrop(src, PW, PH, fill: solid), quarter = appleMipTexture(full)
        let base26 = render(apple26, full: full, quarter: quarter, uniforms: makeUniforms(dark: dark))
        let a0 = render(gg27With([kDiffusionIndex: 0], dark: dark), full: full, quarter: quarter, highlight: hlRegular)
        let a05 = render(gg27With([kDiffusionIndex: 0.5], dark: dark), full: full, quarter: quarter, highlight: hlRegular)
        let a1 = render(gg27With([kDiffusionIndex: 1], dark: dark), full: full, quarter: quarter, highlight: hlRegular)
        // Check 1: a = 0.5 is neutral, bit-exact with the default pipeline.
        let neutral = maxDiff(a05, render(gg27With([:], dark: dark), full: full, quarter: quarter, highlight: hlRegular))
        // Check 2: a = 0 in the shader (face fill -> alpha 0, blur fill via the formula) must equal the case precomputed
        // on the host at a = 0.5: fill alpha 0 and blur fill x0.75, normal 0 (Aqua: measured 0.675 / 0 / 0).
        let hostSide = render(gg27With([kDiffusionIndex: 0.5, kFillLightIndex: dark ? 0 : 0.675, kFillDarkIndex: dark ? 0.675 : 0,
                                        kFillNormalIndex: 0, kFaceFillAIndex: 0], dark: dark), full: full, quarter: quarter,
                              highlight: hlRegular)
        let a0VsHost = maxDiff(a0, hostSide)
        print("\(dark ? "Dark" : "Light") \(name): slider a=0.5 vs default max \(neutral)/255; a=0 vs host-precomputed max \(a0VsHost)/255; a=0 vs a=1 max \(maxDiff(a0, a1))/255")
        if neutral != 0 || a0VsHost > 2 { print("FAIL: slider"); exit(1) }
        if src != nil {
            print(String(format: "  remaining background detail: 26.6 %.0f%%; 27 slider 0 %.0f%%, 0.5 %.0f%%, 1 %.0f%%",
                         detailRatio(base26, full) * 100, detailRatio(a0, full) * 100, detailRatio(a05, full) * 100, detailRatio(a1, full) * 100))
        }
        let row = (name, [("26.6 (Apple)", cropped(base26, scale: S)), ("27, slider 0 (clear)", cropped(a0, scale: S)),
                          ("27, slider 0.5 (default)", cropped(a05, scale: S)), ("27, slider 1 (frosted)", cropped(a1, scale: S))])
        if dark { sliderRowsDark.append(row) } else { sliderRows.append(row) }
    }
}
iconAppearance = .aqua

// Various backgrounds (light): synthetic text and some system wallpapers.
var bgRows: [(String, [(String, CGImage)])] = []
let wallDir = "/System/Library/Desktop Pictures/.thumbnails/"
let walls: [(String, CGImage?)] = [("Text background", textBackdrop())] + [
    ("Big Sur Graphic", "Big Sur Graphic.heic"), ("Catalina Evening", "Catalina Evening.heic"),
    ("Chroma Red", "Chroma Red.heic"), ("Big Sur Road", "Big Sur Road.heic"), ("Grid Green", "Grid Green.heic"),
].map { ($0.0, NSImage(contentsOfFile: wallDir + $0.1)?.cgImage(forProposedRect: nil, context: nil, hints: nil)) }
for (name, img) in walls {
    guard let img else { print("skipping \(name): cannot read image"); continue }
    let full = name == "Text background" ? img : backdrop(img, PW, PH), quarter = appleMipTexture(full)
    var cols = [("26.6 (Apple)", cropped(render(apple26, full: full, quarter: quarter), scale: S))]
    for (t, a) in [("27, slider 0", Float(0)), ("27, slider 0.5", 0.5), ("27, slider 1", 1)] {
        cols.append((t, cropped(render(gg27With([kDiffusionIndex: a]), full: full, quarter: quarter, highlight: hlRegular), scale: S)))
    }
    bgRows.append((name, cols))
}

// Other glass kinds: .clear (backdropScale 0.5), .regular and sidebar simulating a 200 pt short side (function
// constant 39) to show blur radius / edge bleed by size. Sidebars have no highlight.
var variantRows: [(String, [(String, CGImage)])] = []
let graphic = walls.first { $0.0 == "Big Sur Graphic" }?.1
// Inactive: highlight off (InactiveHighlights sets key/fill alpha = 0).
for (name, src, variant, dark, size, hl, inactive) in [
    (".clear, photo", photo, Int32(1), false, Float(0), hlClear as [Float]?, false),
    (".clear, Big Sur Graphic", graphic, 1, false, 0, hlClear, false),
    (".clear dark, photo", photo, 1, true, 0, hlClear, false),
    (".regular 200 pt, photo", photo, 0, false, 200, hlRegular, false),
    ("sidebar 200 pt, photo", photo, 2, false, 200, nil, false),
    ("sidebar 200 pt dark, photo", photo, 2, true, 200, nil, false),
    (".regular inactive, photo", photo, 0, false, 0, nil, true),
    (".regular inactive dark, photo", photo, 0, true, 0, nil, true),
    ("menu 200 pt inactive, photo", photo, 3, false, 200, nil, true),
    ("menu 200 pt inactive dark, photo", photo, 3, true, 200, nil, true),
] {
    iconAppearance = dark ? .darkAqua : .aqua
    let full = backdrop(src, PW, PH), mip = appleMipTexture(full, halvings: variant == 1 ? 1 : 2)
    var cols: [(String, CGImage)] = []
    for (t, a) in [("slider 0", Float(0)), ("slider 0.5", 0.5), ("slider 1", 1)] {
        var c: [Int: Float] = [kDiffusionIndex: a]
        if size > 0 { c[39] = size }
        cols.append((t, cropped(render(gg27With(c, dark: dark, variant: variant, inactive: inactive), full: full, quarter: mip,
                                       highlight: hl), scale: S)))
    }
    variantRows.append((name, cols))
}
iconAppearance = .aqua

// The 26.6 highlight layer (CASDFKeyFillHighlightEffect, uber shader constant 28 = 66) is white alpha 1 when the window is
// key, drawn over the 27 dark ring at button edges (white rim on the Settings toolbar button). The dylib replaces it with
// gg_no_kf_highlight: it must not change any pixel already drawn below (the 27 highlight is in the glass shader).
do {
    let bg = backdrop(photo, PW, PH), q = appleMipTexture(bg)
    let none = pso(try! ourLib.makeFunction(name: "gg_no_kf_highlight", constantValues: MTLFunctionConstantValues()))
    let d = maxDiff(render(none, full: bg, quarter: q), drawIcons(bg))
    print("drop 26.6 highlight: the replacement draws nothing, diff \(d)/255 -> \(d == 0 ? "OK" : "FAIL")")
    if d != 0 { exit(1) }
}

// debugEdge (constant 48, on-machine diagnostics): solid fill by SDF distance at pixels we draw: purple ring band
// (-1 <= d < 0 points), green interior, blue outside the edge but still drawn (shadow). Shows whether the outermost button
// pixels on the machine are ours (purple) or something drawn over them. Checks the capsule's middle row: the pixel just
// inside the left edge is purple, the interior green.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S), on = true
    fc.setConstantValue(&plv, type: .float, index: 36); fc.setConstantValue(&on, type: .bool, index: 48)
    let dbg = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    let bg = backdrop(nil, PW, PH), q = appleMipTexture(bg)
    let p = render(dbg, full: bg, quarter: q).dataProvider!.data! as Data
    let cy = Int(center.y) * S, ex = Int(center.x - halfSize.x) * S
    func px(_ x: Int) -> [Int] { (0..<3).map { Int(p[(cy * PW + x) * 4 + $0]) } }
    let ring = px(ex + 1), mid = px(Int(center.x) * S + 9)
    let ok = ring[0] > 200 && ring[1] < 60 && ring[2] > 200 && mid[1] > 200 && mid[0] < 60
    print("debugEdge: left edge \(ring) (purple), interior \(mid) (green) -> \(ok ? "OK" : "FAIL")")
    if !ok { exit(1) }
}

// debugScale (constant 49, diagnostics): the texture variant writes into the glass interior color R = geometric sdf_texture
// texels per point (sdf_texels_per_point), G = |d(s.x)/dx|, B = |d(s.x)/dy| per point (the real distance slope), each
// channel = value / 4. On the machine, read the image to see whether the geometric k matches the real slope. Harness:
// sdf_texture at 3 texels/point in texel units -> all three ~3.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S), on = true
    fc.setConstantValue(&plv, type: .float, index: 36); fc.setConstantValue(&on, type: .bool, index: 49)
    let texDbg = pso(try! ourLib.makeFunction(name: "gg27_glass_background_lpf", constantValues: fc), vertex: "harness_tex_vert")
    let bake = try! device.makeComputePipelineState(function: ourLib.makeFunction(name: "harness_bake_sdf")!)
    let bg = backdrop(nil, PW, PH), q = appleMipTexture(bg)
    let margin: Float = 24, res = Float(S)
    let bmin = center - halfSize - margin, bsize = (halfSize + margin) * 2
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Int(bsize.x * res), height: Int(bsize.y * res), mipmapped: false)
    td.usage = [.shaderRead, .shaderWrite]
    let sdfTex = device.makeTexture(descriptor: td)!
    let cb = queue.makeCommandBuffer()!, ce = cb.makeComputeCommandEncoder()!
    ce.setComputePipelineState(bake); ce.setTexture(sdfTex, index: 0)
    uniforms.withUnsafeBytes { ce.setBytes($0.baseAddress!, length: 48, index: 0) }
    var box = SIMD4<Float>(bmin.x, bmin.y, bsize.x, bsize.y); ce.setBytes(&box, length: 16, index: 1)
    var ctr = center; ce.setBytes(&ctr, length: 8, index: 2)
    var bd: Float = 0; ce.setBytes(&bd, length: 4, index: 3)
    var un: Float = 1; ce.setBytes(&un, length: 4, index: 4)
    ce.dispatchThreads(MTLSize(width: td.width, height: td.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    ce.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var v: [Float] = []
    for (x, y) in [(0, 0), (W, 0), (0, H), (W, H)] {
        v += [Float(x) / Float(W) * 2 - 1, 1 - Float(y) / Float(H) * 2, 0, 1,
              (Float(x) - bmin.x) / bsize.x, (Float(y) - bmin.y) / bsize.y, Float(x) / Float(W), Float(y) / Float(H)]
    }
    let p = render(texDbg, full: bg, quarter: q, uniforms: Array(uniforms[48...]), sdf: sdfTex,
                   verts: device.makeBuffer(bytes: v, length: v.count * 4)!).dataProvider!.data! as Data
    let cy = Int(center.y) * S, ex = Int(center.x - halfSize.x) * S + 3, cx = Int(center.x) * S, ty = Int(center.y - halfSize.y) * S + 3
    let left = (0..<3).map { Float(p[(cy * PW + ex) * 4 + $0]) / 255 * 4 }, top = (0..<3).map { Float(p[(ty * PW + cx) * 4 + $0]) / 255 * 4 }
    let ok = abs(left[0] - 3) < 0.2 && abs(left[1] - 3) < 0.3 && abs(top[2] - 3) < 0.3
    print(String(format: "debugScale: geometric k %.2f, x slope at left edge %.2f, y slope at top edge %.2f (all ~3) -> %@", left[0], left[1], top[2], ok ? "OK" : "FAIL"))
    if !ok { exit(1) }
}

// noHighlight27 (constant 50, on-machine A/B test): disables the 27 highlight drawn in the glass shader. The Settings
// toolbar button had 2 rows of white 255 at the edge: if they vanish when disabled, it is our highlight (rim band leaking);
// if they stay, another layer draws over it. Checked on gray 243 (like the Settings toolbar): the top edge has a bright
// line >= 254 when on, none when off.
do {
    func topMax(_ off: Bool) -> Int {
        let fc = MTLFunctionConstantValues()
        var plv = 1 / Float(S), sysDark = false, flag = off
        fc.setConstantValue(&plv, type: .float, index: 36); fc.setConstantValue(&sysDark, type: .bool, index: 46)
        if off { fc.setConstantValue(&flag, type: .bool, index: 50) }
        let p = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
        let bg = backdrop(nil, PW, PH, fill: CGColor(gray: 243.0 / 255, alpha: 1)), q = appleMipTexture(bg)
        var u = makeUniforms(face: faceRows(black: 0.1, white: 1.3 - 0.8 + 0.1, sat: 1.3, fill: [0, 0, 0, 0]))
        withUnsafeBytes(of: Float(0.4)) { u.replaceSubrange(48 + 40..<48 + 44, with: $0) }
        let d = render(p, full: bg, quarter: q, uniforms: u).dataProvider!.data! as Data
        let cx = Int(center.x) * S + 30, ty = Int(center.y - halfSize.y) * S
        return (ty...ty + 8).map { Int(d[($0 * PW + cx) * 4 + 1]) }.max()!
    }
    let on = topMax(false), off = topMax(true)
    let ok = on >= 254 && off <= 251
    print("noHighlight27: brightest top edge when on \(on), when off \(off) -> \(ok ? "OK" : "FAIL")")
    if !ok { exit(1) }
}

// Outer refraction reads source_texture outside the glass edge (the backdrop margin). After the own_only fix, SwiftUI
// toolbar buttons (inputBlurRadius = 0) on the machine still lost the ring with edge pixels at 255: rim factor
// 1 + bias H (3 - 2V) > 1, i.e. V > 1.5 (glass color at the edge too bright). Simulation: the source_texture area outside
// the glass frame is transparent (0, 0, 0, 0). The 27 shader blends premultiplied samples directly, so the glass surface
// alpha drops, and the color matrix (with an additive constant) applied to premultiplied color then divided by alpha comes
// out too bright. On a uniform background the image must match a margin with real background (26.6 unpremultiplies after
// blending, so it is unaffected).
do {
    let gray = CGColor(gray: 243.0 / 255, alpha: 1)
    let bg = backdrop(nil, PW, PH, fill: gray)
    let noMargin = bitmap(PW, PH) { ctx in
        ctx.setFillColor(gray)
        ctx.fill(CGRect(x: CGFloat(center.x - halfSize.x) * CGFloat(S), y: CGFloat(center.y - halfSize.y) * CGFloat(S),
                        width: CGFloat(halfSize.x * 2) * CGFloat(S), height: CGFloat(halfSize.y * 2) * CGFloat(S)))
    }
    let a = render(gg27b, full: bg, quarter: appleMipTexture(bg))
    let b = render(gg27b, full: bg, quarter: appleMipTexture(noMargin))
    let d = maxDiff(a, b)
    print("transparent backdrop margin (outer refraction reads outside the edge): diff \(d)/255 -> \(d <= 2 ? "OK" : "FAIL")")
    if d > 2 { diffReport(a, b); exit(1) }
}

// Transparent margin on a non-uniform background: 27's outer refraction blends background from outside the edge into the
// band next to it. When the margin has no data, the adapter fills the gap with the background at the pixel itself (closer
// to the outside background than dropping outer refraction entirely). Horizontal black -> white ramp: compares the
// transparent-margin image with the real-margin image.
do {
    let ramp = bitmap(PW, PH) { ctx in
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor.black, CGColor.white] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: PW, y: 0), options: [])
    }
    let noMargin = bitmap(PW, PH) { ctx in
        ctx.clip(to: CGRect(x: CGFloat(center.x - halfSize.x) * CGFloat(S), y: CGFloat(center.y - halfSize.y) * CGFloat(S),
                            width: CGFloat(halfSize.x * 2) * CGFloat(S), height: CGFloat(halfSize.y * 2) * CGFloat(S)))
        ctx.draw(ramp, in: CGRect(x: 0, y: 0, width: PW, height: PH))
    }
    let d = maxDiff(render(gg27b, full: ramp, quarter: appleMipTexture(ramp)), render(gg27b, full: ramp, quarter: appleMipTexture(noMargin)))
    print("transparent margin, ramp background: diff vs real-background margin \(d)/255 -> \(d <= 6 ? "OK" : "FAIL")")
    if d > 6 { exit(1) }
}

// 26.6 active-window parameters the adapter used to keep (real uniforms of a 36 point toolbar button: shadow opacity 0.5,
// radius 20, offset (0, -8); holding tone opacity 1, distance -2 / -1, white 0.97). Per DesignLibrary 27.2.1
// (RegularBase.Base, 27 branch): holding tone off (white 1.0); shadow opacity clampedLinear(short side; 64..160 ->
// 0.04..0.4, dark 0.6), radius clampedLinear(64..160 -> 4..24), offset (0, 8), no refraction. 36 point button: the
// interior is not multiplied by 0.97, and the shadow below the button is many times lighter than 26.6's.
do {
    let fc = MTLFunctionConstantValues()
    var plv = 1 / Float(S), sysDark = false
    fc.setConstantValue(&plv, type: .float, index: 36); fc.setConstantValue(&sysDark, type: .bool, index: 46)
    let auto = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: fc))
    func u(shadow: Bool, holding: Bool) -> [UInt8] {
        var u = makeUniforms(face: faceRows(black: 0.5, white: 1.03, sat: 1, fill: [1, 1, 1, 0.4]))
        func f(_ off: Int, _ v: Float) { withUnsafeBytes(of: v) { u.replaceSubrange(48 + off..<48 + off + 4, with: $0) } }
        if shadow { f(220, 0.5); f(76, 1 / 20); f(64, 0); f(68, -8); f(156, 1) }
        if holding { f(228, 1); f(232, -2); f(236, -1); f(248, 0.97) }
        return u
    }
    let white = backdrop(nil, PW, PH, fill: .white), q = appleMipTexture(white)
    let cx = Int(center.x) * S
    func g(_ img: CGImage, _ ypt: Float) -> Int { Int((img.dataProvider!.data! as Data)[(Int(ypt * Float(S)) * PW + cx) * 4 + 1]) }
    let midY = center.y + 6, belowY = center.y + halfSize.y + 5
    let held = g(render(auto, full: white, quarter: q, uniforms: u(shadow: false, holding: true)), midY)
    let plain = g(render(auto, full: white, quarter: q, uniforms: u(shadow: false, holding: false)), midY)
    let s27 = 255 - g(render(auto, full: white, quarter: q, uniforms: u(shadow: true, holding: false)), belowY)
    let s26 = 255 - g(render(apple26, full: white, quarter: q, uniforms: u(shadow: true, holding: false)), belowY)
    let ok = abs(held - plain) <= 1 && s26 >= 20 && s27 * 6 <= s26
    print("active 26.6 -> 27: interior with holding tone \(held) vs without \(plain); shadow below button 27 darkness \(s27), 26.6 darkness \(s26) -> \(ok ? "OK" : "FAIL")")
    if !ok { exit(1) }
    // The 27 dark ring sits 1 px outside the edge (darkSpecular effectOffset = -h). Active 26.6 glass has a shadow, so
    // QuartzCore also draws the area outside the frame (marginWidth, the SDF maximum): the ring could then go outside the
    // edge as in 27; glass without a shadow stays inside the edge (kInBounds, avoiding broken rims). Middle row, left edge.
    // A transparent backdrop margin (blur 0 buttons) has no background to rebuild.
    let ex = Int(center.x - halfSize.x) * S, cy = Int(center.y) * S
    func gx(_ img: CGImage, _ x: Int) -> Int { Int((img.dataProvider!.data! as Data)[(cy * PW + x) * 4 + 1]) }
    let noMargin = bitmap(PW, PH) { ctx in
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: CGFloat(center.x - halfSize.x) * CGFloat(S), y: CGFloat(center.y - halfSize.y) * CGFloat(S),
                        width: CGFloat(halfSize.x * 2) * CGFloat(S), height: CGFloat(halfSize.y * 2) * CGFloat(S)))
    }
    let act = render(auto, full: white, quarter: q, uniforms: u(shadow: true, holding: true))
    let actNo = render(auto, full: white, quarter: appleMipTexture(noMargin), uniforms: u(shadow: true, holding: true))
    let quiet = render(auto, full: white, quarter: q, uniforms: u(shadow: false, holding: false))
    func outMin(_ img: CGImage) -> Int { (ex - 3...ex - 1).map { gx(img, $0) }.min()! }   // 1 point just outside the edge
    func inMin(_ img: CGImage) -> Int { (ex...ex + 2).map { gx(img, $0) }.min()! }         // 1 point just inside the edge
    // Correction 2026-11-21 (measured on the machine): the outside ring of glass with a shadow was sometimes broken at the
    // left/right ends. Pixels outside the frame are erased when content behind is redrawn, and QuartzCore 26.6 does not
    // redraw the glass because the dirty region does not touch its frame. Decision: the ring always stays inside the edge,
    // with or without shadow, transparent margin or not, the dark ring is at the point just inside the edge.
    let outA = outMin(act), inA = inMin(act), inN = inMin(actNo), outQ = outMin(quiet), inQ = inMin(quiet)
    let ok2 = outA >= 245 && inA <= 235 && abs(inN - inA) <= 8 && outQ >= 250 && inQ <= 235
    print("dark ring always inside the edge: with shadow outside \(outA), inside \(inA); transparent margin inside \(inN); no shadow: outside \(outQ), inside \(inQ) -> \(ok2 ? "OK" : "FAIL")")
    if !ok2 { exit(1) }
}

// Sheet layout: each tile 600x180 px.
let cw = Int(crop.width) * S, ch = Int(crop.height) * S, pad = 16, label = 28, rowLabel = 110
func makeSheet(_ rows: [(String, [(String, CGImage)])]) -> CGImage {
let sheetW = rowLabel + rows[0].1.count * (cw + pad) + pad, sheetH = label + rows.count * (ch + pad) + pad
return bitmap(sheetW, sheetH) { ctx in
    ctx.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
    for (c, (title, _)) in rows[0].1.enumerated() {
        NSAttributedString(string: title, attributes: font).draw(at: CGPoint(x: rowLabel + c * (cw + pad), y: sheetH - label + 4))
    }
    for (r, (name, cols)) in rows.enumerated() {
        let y = sheetH - label - (r + 1) * (ch + pad)
        NSAttributedString(string: name, attributes: font).draw(at: CGPoint(x: pad, y: y + ch / 2 - 10))
        for (c, (_, img)) in cols.enumerated() {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: rowLabel + c * (cw + pad), y: y, width: cw, height: ch))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}
}
for (file, rs) in [("buttongroup-26-vs-27.png", rows), ("buttongroup-27-slider.png", sliderRows),
                   ("buttongroup-27-slider-dark.png", sliderRowsDark), ("buttongroup-27-backgrounds.png", bgRows),
                   ("buttongroup-27-variants.png", variantRows)] {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(file)
    try! NSBitmapImageRep(cgImage: makeSheet(rs)).representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}
