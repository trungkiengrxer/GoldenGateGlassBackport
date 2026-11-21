// macOS 27 style Liquid Glass slider of the Appearance pane.
// 27: GlassStyleRow.body = AppearancePreferencesFramework.GlassStylePicker(model: GlassStyleModel(), style: .settings).
// Rebuilds the .settings branch: HStack(alignment: .top) { "Liquid Glass"; VStack { preview; slider } .frame(width: 268) },
// a SwiftUI slider with ticks 0 / 0.5 / 1 (plus a 1.1 tick and range up to 1.1 while Reduce Transparency is on), neutralValue 0,
// end symbols capsule.on.rectangle.liquid.glass / capsule.on.rectangle (fill), AX label "Liquid Glass Tint Amount".
// Drag: previewSystemLegibility (only the pane changes); release: commitSystemLegibility (every app changes in the same
// frame) through GGLegibility.
import SwiftUI
import AppKit

private func legibility<T>(_ name: String, _ type: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
}
private typealias GetFn = @convention(c) () -> Float
private typealias PreviewFn = @convention(c) (Float, Bool) -> Void
private typealias CommitFn = @convention(c) (UnsafeRawPointer?) -> Int32
private typealias AXSetFn = @convention(c) (Bool) -> Void

/// 27 GlassStyleModel + AccessibilityModel combined: slider value, Reduce Transparency, writes through GGLegibility.
final class GGGlassTintModel: ObservableObject {
    @Published var value: Double
    @Published var showExtraTick: Bool
    let reduceTransparencyAtEntry: Bool
    private(set) var previews = 0, commits = 0

    init() {
        let rt = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        reduceTransparencyAtEntry = rt
        showExtraTick = rt
        value = rt ? 1.1 : Double(legibility("GGGlassSystemLegibility", GetFn.self)?() ?? 0.5)
    }

    /// Binding setter of the 27 slider: changes the value; within 0...1 it previews immediately in the pane process.
    func set(_ v: Double) {
        value = v
        guard v <= 1 else { return }
        legibility("GGGlassPreviewSystemLegibility", PreviewFn.self)?(Float(v), false)
        previews += 1
    }

    /// onEditingChanged: on release, commit for every app; if Reduce Transparency is on, turn it off (27 calls
    /// _AXInterfaceSetReduceTransparencyEnabled) and drop the extra tick.
    func editingChanged(_ editing: Bool) {
        guard !editing, value <= 1 else { return }
        if showExtraTick || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_NOW)
            if let f = h.flatMap({ dlsym($0, "_AXInterfaceSetReduceTransparencyEnabled") }) { unsafeBitCast(f, to: AXSetFn.self)(false) }
            showExtraTick = false
        }
        _ = legibility("GGGlassCommitSystemLegibility", CommitFn.self)?(nil)
        commits += 1
    }
}

/// 27 GlassStylePicker(style: .settings) (body 0x2612da21c, content 0x2612dac68, slider 0x2612dbb2c).
struct GGGlassStylePicker27: View {
    @StateObject var model = GGGlassTintModel().register()

    // 27 (0x2612dc730..0x2612dc8f0): Image(_internalSystemName:) (private symbol catalog), .secondary, symbolVariant.
    // It must be a symbol image, not Image(nsImage:): SwiftUI's PlatformSliderStyle wraps both end labels in
    // _DiscreteSymbolEffectModifier keyed by SymbolEffectState.minimum/maximumValueLabelSeed, so the end symbol
    // animates when the slider reaches that end; a bitmap image has nothing to animate.
    private func icon(_ name: String, _ variant: SymbolVariants) -> some View {
        Image(_internalSystemName: name).foregroundStyle(.secondary).symbolVariant(variant)
    }

    var body: some View {
        HStack(alignment: .top) {
            ggL("Liquid Glass")
            Spacer(minLength: 0)
            VStack(alignment: .center, spacing: 0) {
                GGGlassPreview27().padding(.bottom, 12)
                Slider(value: Binding(get: { model.value }, set: { model.set($0) }),
                       in: 0...(model.showExtraTick ? 1.1 : 1.0), neutralValue: 0,
                       label: { ggL("Liquid Glass Tint Amount") },
                       minimumValueLabel: { icon("capsule.on.rectangle.liquid.glass", .none) },
                       maximumValueLabel: { icon("capsule.on.rectangle", .fill) },
                       ticks: {
                           SliderTick(0.0); SliderTick(0.5); SliderTick(1.0)
                           if model.showExtraTick { SliderTick(1.1) }
                       },
                       onEditingChanged: { model.editingChanged($0) })
                    .labelsHidden()
                    .accessibilityLabel(ggL("Liquid Glass Tint Amount"))
                    // 27 (0x2612db01c): horizontal padding = style == .setup ? 12 : 0, the .settings branch has none.
                if model.reduceTransparencyAtEntry {
                    ggL("When Reduce Transparency is on, adjusting Liquid Glass may turn this setting off.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
            .frame(width: 268)
        }
    }
}

/// Replacement body for GlassStyleRow (called from gg_settings_body_thunk, SettingsSlider.m). Returns +1.
@_silgen_name("gg_settings_glass_row") public func ggSettingsGlassRow() -> AnyView { AnyView(GGGlassStylePicker27()) }

// For tests/app.swift (settings mode): drives the visible slider model as if the user dragged and released.
private weak var lastModel: GGGlassTintModel?
extension GGGlassTintModel { func register() -> Self { lastModel = self; return self } }
@_cdecl("gg_settings_test_drag") public func ggSettingsTestDrag(_ v: Double, _ release: Bool) -> Int32 {
    guard let m = lastModel else { return -1 }
    m.editingChanged(true); m.set(v)
    if release { m.editingChanged(false) }
    return Int32(m.previews * 100 + m.commits)
}
@_cdecl("gg_settings_test_value") public func ggSettingsTestValue() -> Double { lastModel?.value ?? -1 }
