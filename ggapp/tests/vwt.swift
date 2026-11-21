// ABI test: value witness sizes of the SPI types must match the table measured on 26.6. A mismatch means a
// hand-written declaration is wrong (indirect, @frozen...) and the dylib would crash the app.
// Built and run by tests/abi.sh with the same fake interface as build.sh.
import SwiftUI

var bad = 0
func check<T>(_ t: T.Type, _ size: Int, _ stride: Int, _ name: String) {
    let ok = MemoryLayout<T>.size == size && MemoryLayout<T>.stride == stride
    print("\(ok ? "OK  " : "FAIL") \(name): \(MemoryLayout<T>.size)/\(MemoryLayout<T>.stride) (expected \(size)/\(stride))")
    if !ok { bad += 1 }
}
check(Material.Layer.SDFLayer.GroupLayer.Blend.self, 8, 8, "GroupLayer.Blend")
check(Material.Layer.SDFLayer.GroupLayer.self, 52, 56, "GroupLayer")
check(Material.Layer.self, 49, 56, "Material.Layer")
check(Material.Layer.SDFLayer.self, 16, 16, "SDFLayer")
check(Material.Layer.SDFLayer.Contents.GlassKeyFillHighlight.self, 136, 136, "GlassKeyFillHighlight")
check(Material.Layer.Filter.self, 124, 128, "Layer.Filter")
check(_ShapeSet.Tags.self, 8, 8, "_ShapeSet.Tags")
check(_ShapeSet.self, 16, 16, "_ShapeSet")
check(Material.self, 17, 24, "Material")
check(PlatformGlassInteractionState.self, 33, 40, "PlatformGlassInteractionState")
exit(bad == 0 ? 0 : 1)
