// Reads the ABI of the glass shaders in the system QuartzCore default.metallib (read-only,
// runs in its own process): buffer/texture/sampler bind points, uniform struct layout.
// Build: swiftc -O -o build/reflect reflect.swift
// Run:   build/reflect > glass-abi-<build>.json
import Foundation
import Metal

let libURL = URL(fileURLWithPath: "/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib")
let device = MTLCreateSystemDefaultDevice()!
let lib = try! device.makeLibrary(URL: libURL)

func dataTypeName(_ t: MTLDataType) -> String {
    switch t {
    case .float: "float"; case .float2: "float2"; case .float3: "float3"; case .float4: "float4"
    case .half: "half"; case .half2: "half2"; case .half3: "half3"; case .half4: "half4"
    case .int: "int"; case .uint: "uint"; case .bool: "bool"; case .struct: "struct"; case .array: "array"
    case .float4x4: "float4x4"; case .float3x3: "float3x3"; case .half3x3: "half3x3"
    default: "type\(t.rawValue)"
    }
}

func structJSON(_ s: MTLStructType) -> [[String: Any]] {
    s.members.map { m in
        var d: [String: Any] = ["name": m.name, "offset": m.offset, "type": dataTypeName(m.dataType)]
        if let sub = m.structType() { d["members"] = structJSON(sub) }
        if let a = m.arrayType() { d["arrayLength"] = a.arrayLength; d["elementType"] = dataTypeName(a.elementType) }
        return d
    }
}

func bindingJSON(_ b: MTLBinding) -> [String: Any] {
    var d: [String: Any] = ["name": b.name, "index": b.index, "used": b.isUsed]
    switch b {
    case let buf as MTLBufferBinding:
        d["kind"] = "buffer"; d["size"] = buf.bufferDataSize; d["alignment"] = buf.bufferAlignment
        d["dataType"] = dataTypeName(buf.bufferDataType)
        if let s = buf.bufferStructType { d["members"] = structJSON(s) }
    case let tex as MTLTextureBinding:
        d["kind"] = "texture"; d["textureType"] = tex.textureType.rawValue; d["dataType"] = dataTypeName(tex.textureDataType)
    default:
        d["kind"] = "type\(b.type.rawValue)"
    }
    return d
}

/// Vertex descriptor built from the vertex function's attributes, placed at buffer 30 so it
/// does not overlap the uniform buffers. Only for reflection, no drawing.
func vertexDescriptor(for vert: MTLFunction) -> MTLVertexDescriptor {
    let formats: [MTLDataType: (MTLVertexFormat, Int)] = [
        .float: (.float, 4), .float2: (.float2, 8), .float3: (.float3, 12), .float4: (.float4, 16),
        .half2: (.half2, 4), .half4: (.half4, 8), .uint: (.uint, 4), .int: (.int, 4),
    ]
    let vd = MTLVertexDescriptor()
    var offset = 0
    for a in vert.vertexAttributes ?? [] where a.isActive {
        let (fmt, size) = formats[a.attributeType] ?? (.float4, 16)
        vd.attributes[a.attributeIndex].format = fmt
        vd.attributes[a.attributeIndex].offset = offset
        vd.attributes[a.attributeIndex].bufferIndex = 30
        offset += size
    }
    vd.layouts[30].stride = max(offset, 4)
    return vd
}

let names = lib.functionNames.sorted()
let glass = names.filter { $0.hasPrefix("glass_") }
let vertexCandidates = ["sdf_filter_vert_lpf", "variable_blur_vert_lpf", "sdf_filter_vert_lph", "variable_blur_vert_lph"]
let formats: [MTLPixelFormat] = [.bgra8Unorm, .rgba16Float]

var out: [String: Any] = [
    "device": device.name,
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "functionCount": names.count,
    "glassFunctions": glass,
]
var reflected: [String: Any] = [:]
for name in glass {
    let frag = lib.makeFunction(name: name)!
    var entry: [String: Any] = ["functionType": frag.functionType == .fragment ? "fragment" : "other"]
    if !frag.functionConstantsDictionary.isEmpty {
        entry["functionConstants"] = frag.functionConstantsDictionary.map { ["name": $0.key, "index": $0.value.index, "required": $0.value.required, "type": dataTypeName($0.value.type)] }
    }
    var errors: [String] = []
    search: for v in vertexCandidates {
        guard let vert = lib.makeFunction(name: v) else { continue }
        for f in formats {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vert
            desc.vertexDescriptor = vertexDescriptor(for: vert)
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = f
            do {
                var refl: MTLAutoreleasedRenderPipelineReflection?
                _ = try device.makeRenderPipelineState(descriptor: desc, options: [.bindingInfo, .bufferTypeInfo], reflection: &refl)
                entry["vertexFunction"] = v
                entry["pixelFormat"] = f.rawValue
                entry["fragmentBindings"] = (refl?.fragmentBindings ?? []).map(bindingJSON)
                entry["vertexBindings"] = (refl?.vertexBindings ?? []).map(bindingJSON)
                break search
            } catch {
                errors.append("\(v)/\(f.rawValue): \(error.localizedDescription)")
            }
        }
    }
    if entry["fragmentBindings"] == nil { entry["errors"] = errors }
    reflected[name] = entry
}
out["reflection"] = reflected
let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
let failed = reflected.values.filter { ($0 as! [String: Any])["fragmentBindings"] == nil }.count
FileHandle.standardError.write("reflected \(glass.count - failed)/\(glass.count)\n".data(using: .utf8)!)
exit(failed == 0 ? 0 : 1)
