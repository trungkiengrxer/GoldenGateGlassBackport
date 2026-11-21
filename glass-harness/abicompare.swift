// Compares the ABI (buffer/texture bindings, uniform struct layout) between Apple's glass functions in QuartzCore's
// default.metallib (read-only) and our replacement functions. Each line of the list file:
// "<Apple name> <our name>". Exits 1 if any pair differs or a function is missing.
// Build: swiftc -O -o build/abicompare abicompare.swift
// Run:   build/abicompare shaders/glass26_replica.metal shaders/gg27-entries.txt
import Foundation
import Metal

let args = CommandLine.arguments
let shaderPath = args.count > 1 ? args[1] : "shaders/glass26_replica.metal"
let listPath = args.count > 2 ? args[2] : "shaders/gg27-entries.txt"
let device = MTLCreateSystemDefaultDevice()!
let appleLib = try! device.makeLibrary(URL: URL(fileURLWithPath:
    "/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"))
let ourLib = try! device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8), options: nil)

/// Flat description of the fragment bindings: "buffer1 struct: name@offset:type ...", "texture3 type".
/// The texture SDF variants (no "_sdf_" in the name) take texcoord0/texcoord1 varyings, so they use the harness_tex_vert
/// vertex; the vertex only supplies varyings and does not affect the fragment bindings being compared.
func signature(_ frag: MTLFunction) -> [String]? {
    let tex = !frag.name.contains("_sdf_")
    guard let vert = tex ? ourLib.makeFunction(name: "harness_tex_vert") : appleLib.makeFunction(name: "sdf_filter_vert_lpf") else { return nil }
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = vert
    d.fragmentFunction = frag
    let vd = MTLVertexDescriptor()
    var off = 0
    for a in vert.vertexAttributes ?? [] where a.isActive {
        let f: (MTLVertexFormat, Int) = a.attributeType == .float4 ? (.float4, 16) : (.float2, 8)
        vd.attributes[a.attributeIndex].format = f.0; vd.attributes[a.attributeIndex].offset = off
        vd.attributes[a.attributeIndex].bufferIndex = 30; off += f.1
    }
    vd.layouts[30].stride = max(off, 4)
    d.vertexDescriptor = vd
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    var refl: MTLRenderPipelineReflection?
    guard (try? device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &refl)) != nil,
          let r = refl else { return nil }
    func members(_ s: MTLStructType, _ base: Int, _ pre: String) -> [String] {
        s.members.flatMap { m -> [String] in
            if let sub = m.structType() { return members(sub, base + m.offset, pre + m.name + ".") }
            return ["\(pre)\(m.name)@\(base + m.offset):\(m.dataType.rawValue)"]
        }
    }
    return r.fragmentBindings.filter { $0.isUsed || $0.type == .buffer }.sorted { ($0.type.rawValue, $0.index) < ($1.type.rawValue, $1.index) }.map { b in
        if let buf = b as? MTLBufferBinding {
            if let s = buf.bufferStructType { return "buffer\(b.index) " + members(s, 0, "").joined(separator: " ") }
            return "buffer\(b.index) \(buf.bufferDataType.rawValue)"
        }
        // Only compare texture indices: the element type (half/float) is how the shader reads, not part of the binding
        // contract (Metal allows reading float-format textures as texture2d<half> or texture2d<float>).
        if b is MTLTextureBinding { return "texture\(b.index)" }
        return "\(b.type.rawValue)\(b.index)"
    }
}

var bad = 0
for line in try! String(contentsOfFile: listPath, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
    let p = line.split(separator: " ").map(String.init)
    guard p.count == 2 else { continue }
    guard let a = appleLib.makeFunction(name: p[0]), let sa = signature(a) else { print("FAIL \(p[0]): missing Apple function"); bad += 1; continue }
    guard let o = try? ourLib.makeFunction(name: p[1], constantValues: MTLFunctionConstantValues()), let so = signature(o) else {
        print("FAIL \(p[1]): missing function or pipeline cannot be built"); bad += 1; continue
    }
    if sa == so { print("OK  \(p[0]) = \(p[1])") } else {
        bad += 1
        print("FAIL \(p[0]) != \(p[1])")
        for (x, y) in zip(sa, so) where x != y { print("   Apple: \(x.prefix(300))\n   ours : \(y.prefix(300))") }
        if sa.count != so.count { print("   binding count: \(sa.count) vs \(so.count)") }
    }
}
print(bad == 0 ? "TOTAL: all pairs match ABI" : "TOTAL: \(bad) pairs differ")
exit(bad == 0 ? 0 : 1)
