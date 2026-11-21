// Renders comparison images: the original 26.6 glass_background_sdf_lpf vs gg27 (27 algorithm on the 26.6 ABI)
// on a UHD 630. The backdrop is sampled at 1/4 resolution like CABackdropLayer.scale = 0.25.
// Uniforms are derived from real NSGlassEffectView CAFilter parameters; Apple's CAFilter -> uniform
// mapping is not decoded, so this is an approximation, but both shaders get the same input.
// Build: swiftc -O -o build/render render.swift
// Run:   build/render [.metal file] [output directory, default ../renders] [checker]
import AppKit
import Metal
import Accelerate
import ImageIO
import UniformTypeIdentifiers

let shaderPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "shaders/glass26_replica.metal"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "../renders"
let checker = CommandLine.arguments.contains("checker")   // checkerboard background + blur ~0 to inspect refraction
let W = 640, H = 400, scale = checker ? 1 : 4   // points = pixels; regular backdrop 160x100

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let appleLib = try! device.makeLibrary(URL: URL(fileURLWithPath:
    "/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"))
let ourLib = try! device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8), options: nil)

func pso(_ frag: MTLFunction) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = try! ourLib.makeFunction(name: "harness_vert", constantValues: MTLFunctionConstantValues())
    d.fragmentFunction = frag
    let vd = MTLVertexDescriptor()
    for (i, (fmt, off)) in [(MTLVertexFormat.float4, 0), (.float2, 16), (.float2, 24)].enumerated() {
        vd.attributes[i].format = fmt; vd.attributes[i].offset = off; vd.attributes[i].bufferIndex = 30
    }
    vd.layouts[30].stride = 32
    d.vertexDescriptor = vd
    // Premultiplied source-over onto the backdrop, as WindowServer does.
    let c = d.colorAttachments[0]!
    c.pixelFormat = .rgba32Float
    c.isBlendingEnabled = true
    c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
    c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try! device.makeRenderPipelineState(descriptor: d)
}
let apple26 = pso(appleLib.makeFunction(name: "glass_background_sdf_lpf")!)
let gg27 = pso(try! ourLib.makeFunction(name: "gg27_glass_background_sdf_lpf", constantValues: MTLFunctionConstantValues()))

// ---- Backdrop: gradient, colored circles, stripes and text (drawn with CoreGraphics) ----
func drawBackdrop(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(w) / CGFloat(W)
    ctx.scaleBy(x: s, y: s)
    if checker {
        for y in 0..<(H / 20) { for x in 0..<(W / 20) {
            ctx.setFillColor((x + y) % 2 == 0 ? NSColor.white.cgColor : NSColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1).cgColor)
            ctx.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
        } }
        return ctx.makeImage()!
    }
    let g = CGGradient(colorsSpace: nil, colors: [NSColor(red: 0.95, green: 0.45, blue: 0.2, alpha: 1).cgColor,
                                                  NSColor(red: 0.25, green: 0.2, blue: 0.75, alpha: 1).cgColor] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
    for (x, y, r, c) in [(120.0, 300.0, 90.0, NSColor.systemTeal), (480, 120, 110, .systemPink), (330, 230, 60, .systemYellow)] {
        ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    for i in 0..<20 where i % 2 == 0 {
        ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor); ctx.fill(CGRect(x: 40 + i * 14, y: 40, width: 7, height: 90))
    }
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    NSAttributedString(string: "Liquid Glass", attributes: [.font: NSFont.boldSystemFont(ofSize: 54), .foregroundColor: NSColor.white])
        .draw(at: CGPoint(x: 300, y: 300))
    NSAttributedString(string: "UHD 630 · macOS 26.6", attributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        .draw(at: CGPoint(x: 330, y: 270))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func texture(_ img: CGImage, mipmapped: Bool) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: mipmapped)
    d.usage = [.shaderRead]
    let t = device.makeTexture(descriptor: d)!
    let data = img.dataProvider!.data! as Data
    data.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.bytesPerRow) }
    if mipmapped {
        let cb = queue.makeCommandBuffer()!; let b = cb.makeBlitCommandEncoder()!
        b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }
    return t
}
let backdropFull = drawBackdrop(W, H)
let backdropQuarter = texture(drawBackdrop(W / scale, H / scale), mipmapped: true)

// ---- Uniform ----
func half(_ v: Float) -> UInt16 {
    var f = v, h: UInt16 = 0
    var sb = vImage_Buffer(data: &f, height: 1, width: 1, rowBytes: 4)
    var db = vImage_Buffer(data: &h, height: 1, width: 1, rowBytes: 2)
    vImageConvert_PlanarFtoPlanar16F(&sb, &db, 0)
    return h
}

struct Glass { var center: SIMD2<Float>; var half: SIMD2<Float>; var radius: Float
               var blur: Float; var black: Float; var white: Float; var fill: SIMD4<Float> }

func uniforms(_ g: Glass) -> [UInt8] {
    var u = [UInt8](repeating: 0, count: 320)
    func f(_ off: Int, _ v: Float) { withUnsafeBytes(of: v) { u.replaceSubrange(off..<off + 4, with: $0) } }
    func h4(_ off: Int, _ v: [Float]) { for (i, x) in v.enumerated() { withUnsafeBytes(of: half(x)) { u.replaceSubrange(off + i * 2..<off + i * 2 + 2, with: $0) } } }
    // SDF mode 5: continuous corners, all 4 corners with the same radius
    f(0, g.half.x); f(4, g.half.y); f(8, 5); f(12, 0)
    f(16, 1); f(20, 0); f(24, 0); f(28, 1)
    for i in 0..<4 { f(32 + i * 4, g.radius) }
    let b = 48
    f(b + 0, 1 / Float(W)); f(b + 4, 0); f(b + 8, 0); f(b + 12, -1 / Float(H))   // points -> uv; sdf y up, uv y down
    f(b + 16, -60); f(b + 20, 1 / 20)                     // inputInnerRefractionAmount/Height
    f(b + 32, -1); f(b + 36, 0)                            // inputRefractionDistance0/1
    f(b + 40, checker ? 0.5 : g.blur)                      // inputBlurRadius (px backdrop 1/4)
    f(b + 44, 0); f(b + 48, 56); f(b + 52, 1 / 56)         // bleed (opacity 0 as in reality)
    f(b + 56, 75); f(b + 60, 1 / 64); f(b + 64, 0); f(b + 68, 8); f(b + 76, 1)
    // face color matrix from black/white/fill: c' = mix(black + (white-black)c, fill.rgb, fill.a)
    let k = (g.white - g.black) * (1 - g.fill.w)
    for i in 0..<3 {
        var row: [Float] = [0, 0, 0, g.black * (1 - g.fill.w) + g.fill[i] * g.fill.w]; row[i] = k
        h4(b + 80 + i * 8, row)
        var id: [Float] = [0, 0, 0, 0]; id[i] = 1; h4(b + 104 + i * 8, id)   // bleed_cm = identity
    }
    f(b + 160, 1)                                          // blur_alpha0 = 1, flat ramp
    f(b + 176, -3); f(b + 180, -2); f(b + 184, -1); f(b + 188, 0)
    f(b + 192, 1); f(b + 196, 0); f(b + 204, 1)            // edge_bleed_dist0/1, face_opacity
    f(b + 232, -1); f(b + 236, 0)
    f(b + 240, 1); f(b + 248, 1); f(b + 256, 1)            // clamp_limit, sdr_white, complex_refraction
    return u
}

func quad(_ g: Glass) -> MTLBuffer {
    // Covers the whole frame; sdf_uv = point relative to the glass panel center (y down), src_uv = backdrop uv.
    var v: [Float] = []
    for (x, y) in [(0, 0), (W, 0), (0, H), (W, H)] {
        v += [Float(x) / Float(W) * 2 - 1, 1 - Float(y) / Float(H) * 2, 0, 1,
              Float(x) - g.center.x, g.center.y - Float(y), Float(x) / Float(W), Float(y) / Float(H)]
    }
    return device.makeBuffer(bytes: v, length: v.count * 4)!
}

let panels = [
    Glass(center: [200, 200], half: [150, 90], radius: 28, blur: 4, black: 0.2, white: 0.6, fill: [0, 0, 0, 0.35]),     // .regular, Dark
    Glass(center: [480, 260], half: [110, 70], radius: 36, blur: 10, black: 0.05, white: 0.8, fill: [1, 1, 1, 0.05]),  // .clear, Dark
]

func render(_ pipeline: MTLRenderPipelineState?) -> CGImage {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: W, height: H, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .managed
    let target = device.makeTexture(descriptor: d)!
    // Background = full-resolution backdrop, converted to float.
    let bg = backdropFull.dataProvider!.data! as Data
    var bgF = [Float](repeating: 0, count: W * H * 4)
    bg.withUnsafeBytes { p in for i in 0..<(W * H * 4) { bgF[i] = Float(p[i]) / 255 } }
    target.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: bgF, bytesPerRow: W * 16)
    let cb = queue.makeCommandBuffer()!
    if let pipeline {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .load; rp.colorAttachments[0].storeAction = .store
        let e = cb.makeRenderCommandEncoder(descriptor: rp)!
        e.setRenderPipelineState(pipeline)
        var edr: Float = 1
        for g in panels {
            let u = uniforms(g)
            e.setVertexBuffer(quad(g), offset: 0, index: 30)
            e.setFragmentBytes(u, length: u.count, index: 1)
            e.setFragmentBytes(&edr, length: 4, index: 6)
            e.setFragmentTexture(backdropQuarter, index: 3)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        e.endEncoding()
    }
    let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: target); b.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var out = [Float](repeating: 0, count: W * H * 4)
    target.getBytes(&out, bytesPerRow: W * 16, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    var px = [UInt8](repeating: 255, count: W * H * 4)
    for i in 0..<out.count { px[i] = UInt8(max(0, min(1, out[i])) * 255 + 0.5) }
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
    print("wrote \(url.path)")
}

/// Labeled side-by-side sheet, with a 4x zoom of the glass panel edge.
func sheet(_ items: [(String, CGImage)]) -> CGImage {
    let pad = 16, label = 34, zoom = 4, crop = CGRect(x: 30, y: 90, width: 80, height: 60)   // top-left corner of the .regular panel
    let cw = Int(crop.width) * zoom, ch = Int(crop.height) * zoom
    let sw = items.count * (W + pad) + pad, sh = label + H + pad + ch + pad
    let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: sw, height: sh))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, (name, img)) in items.enumerated() {
        let x = pad + i * (W + pad)
        ctx.draw(img, in: CGRect(x: x, y: pad + ch + pad, width: W, height: H))
        ctx.interpolationQuality = .none
        let flippedCrop = CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)
        ctx.draw(img.cropping(to: flippedCrop)!, in: CGRect(x: x, y: pad, width: cw, height: ch))
        NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
            .draw(at: CGPoint(x: x, y: sh - label + 6))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
/// |a - b| × 8 on black, to show the areas the 27 algorithm changes.
func diff(_ a: CGImage, _ b: CGImage) -> CGImage {
    let pa = a.dataProvider!.data! as Data, pb = b.dataProvider!.data! as Data
    var px = [UInt8](repeating: 255, count: W * H * 4)
    var maxd = 0, sum = 0
    for i in 0..<(W * H) { for c in 0..<3 {
        let d = abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])); maxd = max(maxd, d); sum += d
        px[i * 4 + c] = UInt8(min(255, d * 8))
    } }
    print("difference 26 vs 27: max \(maxd)/255, mean \(String(format: "%.2f", Double(sum) / Double(W * H * 3)))/255")
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

let base = render(nil), a = render(apple26), b = render(gg27)
let tag = checker ? "-checker" : ""
save(a, "apple-26.6-glass_background_sdf_lpf\(tag).png")
save(b, "gg27-on-26-abi\(tag).png")
save(sheet([("macOS 26.6 (Apple original shader)", a), ("27 algorithm on the 26.6 ABI", b), ("Difference × 8", diff(a, b))]), "compare\(tag).png")
