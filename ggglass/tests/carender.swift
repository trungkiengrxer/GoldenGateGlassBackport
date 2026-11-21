// Exercises QuartzCore's glass render path in our own process with CARenderer (does not touch WindowServer).
// Layer tree: background image + CABackdropLayer (capsule) carrying a glassBackground CAFilter with inputs measured on 26.6
// (measurements/glass-states-25G72.json, regular, Aqua). Renders to PNG; run with GGGlass to see whether functions are replaced.
// Build: swiftc -O -o build/carender carender.swift
// Run:   build/carender <out.png> [background image] [glass-states.json]
import AppKit
import Metal
import QuartzCore

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "carender.png"
let photoPath = args.count > 2 ? args[2] : "/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic"
let W = 360, H = 160

let device = MTLCreateSystemDefaultDevice()!
let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
td.usage = [.renderTarget, .shaderRead]; td.storageMode = .managed
let target = device.makeTexture(descriptor: td)!

let root = CALayer()
root.frame = CGRect(x: 0, y: 0, width: W, height: H)
root.backgroundColor = CGColor(gray: 1, alpha: 1)
let photo = CALayer()
photo.frame = root.bounds
photo.contents = NSImage(contentsOfFile: photoPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
photo.contentsGravity = .resize
root.addSublayer(photo)

guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
      let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { print("missing CABackdropLayer/CAFilter"); exit(1) }
let glass = backdropClass.init()
glass.frame = CGRect(x: 102, y: 62, width: 156, height: 36)
glass.cornerRadius = 18
glass.setValue(0.25, forKey: "scale")
let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")!.takeUnretainedValue() as! NSObject
let doc = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
    CommandLine.arguments.count > 3 ? args[3] : "../measurements/glass-states-25G72.json"))) as! [String: Any]
let inputs = ((doc["states"] as! [[String: Any]]).first { ($0["style"] as? String) == "regular" && (($0["appearance"] as? String)?.hasSuffix("Aqua") ?? false) && !(($0["appearance"] as? String)?.contains("Dark") ?? true) }!)["inputs"] as! [String: Any]
var set = 0
for (k, v) in inputs {
    if let n = v as? NSNumber { filter.setValue(n, forKey: k); set += 1 }
    else if let c = (v as? [String: Any])?["cgcolor"] as? [Double], c.count == 4 {
        filter.setValue(CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]), forKey: k); set += 1
    }
}
glass.filters = [filter]
root.addSublayer(glass)
print("set \(set) glassBackground inputs")

let renderer = CARenderer(mtlTexture: target, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
renderer.layer = root
renderer.bounds = root.bounds
CATransaction.flush()
for _ in 0..<3 {   // a few frames so the backdrop has content
    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
}
let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, b = cb.makeBlitCommandEncoder()!
b.synchronize(resource: target); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
var px = [UInt8](repeating: 0, count: W * H * 4)
target.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
// Color at the capsule center (to compare with/without the dylib).
let i = ((H - 80) * W + 150) * 4
print("wrote \(outPath); pixel (150,80) BGRA = \(px[i]) \(px[i + 1]) \(px[i + 2]) \(px[i + 3])")
