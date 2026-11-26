// Island content views for M3, measured from 27.3 SystemBannerUI (docs/RE-27-CENTERHUD.md section 6.3b).
import AppKit
import SwiftUI

/// ExpandedSlider + TickedSliderTrack + SliderBannerImageView. Coordinates: content view, origin bottom-left.
enum SliderMetrics {
    static let width: CGFloat = 309, inflatedWidth: CGFloat = 321      // ExpandedSlider frame (0x2b1ae4394)
    // Slider row frame 0x2b1ae5c84 (isInflated ? 18 : 4); the drawn track is always 4 (TickedSliderTrack, RE-27-BEHAVIOR s16).
    static let trackHeight: CGFloat = 4, inflatedRowHeight: CGFloat = 18
    static let cornerRadius: CGFloat = 2                                 // UnevenRoundedRectangle radii 2
    static let ticks = 16, tickWidth: CGFloat = 1                        // TickedTrackMask(tickCount: 16, tickWidth: 1)
    static let leading: CGFloat = 64, trailing: CGFloat = 31             // padding(.leading 64) / (.trailing 31)
    static let iconLeading: CGFloat = 16, iconTrailing: CGFloat = 9      // EdgeInsets 16 / 9 of closure 0x2b1ae4ef0 [I icon]
    static let iconSize: CGFloat = 27, iconInflatedScale: CGFloat = 1.1  // SystemBannerAssetView expanded 27; scale 1.1
    // ExpandedComposition = SwiftUI.JindoTripleVStack(notchSize: centerHUDSize), insets 0 (RE-27-BEHAVIOR s14): the stack reserves
    // the notch (h) on top; leading = icon, vertically centred on the whole island; bottom = VStack(alignment: .leading)
    // { SystemBannerSlider.frame(height: (4 | 18) + max(0, 41 - h)), Text? (device name only), Spacer().frame(height: h) }
    // + padding 64 / 31 (0x2b1ae5668 is the Spacer frame). Island = 2h + row = 79 | 93 for h = 34, track at mid height [V].
    // Matches the PROLED footage (youtube drlYGnbWurM 765.6 s: 309 x ~79 pt, icon and track on one centred row).
    static let sensorHeight: CGFloat = 34, rowReference: CGFloat = 41
    // Inflate runs in Animation.spring(HostedMetrics.resizeAnimation) (0x2b1ae5e6c; client default 0.5 / 1.0). The host
    // fills it from the zone's hostedContentResizeSpring (setHostedResizeAnimationSettings: 0x1002cf8e0); for an
    // interaction resize that is centerHUD.interaction.contentInteractionSpring 1.0 / 0.3974 [I, island-re s16].
    static let inflateSpring = Animation.spring(response: Springs.contentInteraction.response, dampingFraction: Springs.contentInteraction.damping)
    static let fillEpsilon = 0.001                                       // [?] epsilon of |value - 1| in 0x2b1aeb3ec

    static func rowHeight(inflated: Bool) -> CGFloat { (inflated ? inflatedRowHeight : trackHeight) + max(0, rowReference - sensorHeight) }

    static func size(inflated: Bool) -> CGSize {
        CGSize(width: inflated ? inflatedWidth : width, height: 2 * sensorHeight + rowHeight(inflated: inflated))
    }

    /// Bottom-left origin: the track is centered in its row, right below the notch (= at mid height).
    static func trackFrame(inflated: Bool) -> CGRect { trackFrame(in: size(inflated: inflated)) }

    /// For any island size: x 64 .. w - 31, centred vertically (notch H above, Spacer H below: the row centre is the
    /// island centre). The view lays out from its actual size, which follows the animated island during a resize.
    static func trackFrame(in s: CGSize) -> CGRect {
        CGRect(x: leading, y: (s.height - trackHeight) / 2, width: s.width - leading - trailing, height: trackHeight)
    }

    /// Leading region: SliderBannerImageView + padding 16 / 9, vertically centered on the whole island. Top-left origin.
    static func iconBox(inflated: Bool) -> CGRect { iconBox(in: size(inflated: inflated)) }
    static func iconBox(in s: CGSize) -> CGRect {
        CGRect(x: iconLeading, y: 0, width: leading - iconLeading - iconTrailing, height: s.height)
    }

    /// TickedSliderTrack tickProgress = (showTicks && \.isEnabled) ? 1 : 0; ExpandedSlider passes showTicks = !isInflated.
    static func tickProgress(inflated: Bool) -> CGFloat { inflated ? 0 : 1 }

    /// TickedTrackMask(tickCount: 16, tickWidth: 1, tickProgress:) gaps (0x2b1aeba74).
    static func tickRects(width: CGFloat, height: CGFloat, progress: CGFloat) -> [CGRect] {
        guard progress > 0 else { return [] }
        return (1..<ticks).map { CGRect(x: width * CGFloat($0) / CGFloat(ticks), y: 0, width: tickWidth * progress, height: height) }
    }

    static func fillTrailingRadius(value: Double) -> CGFloat { abs(value - 1) <= fillEpsilon ? cornerRadius : 0 }

    /// Discrete SF Symbol by value, .fill variant (RE-27-BEHAVIOR s15): volume 0x2b1ad124c, brightness 0x2b1acf7bc.
    static func symbol(_ kind: LevelKind, _ v: Double) -> String {
        switch kind {
        case .volume:
            return v < 0.001 ? "speaker.slash.fill" : v < 0.333 ? "speaker.wave.1.fill" : v < 0.667 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .displayBrightness:
            return v < 0.333 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    /// The icon's .symbolEffect(.bounce, value: seed) seed advances when the value changes onto exactly 0 or 1 (0x2b1ab7448).
    static func bouncesAtEnd(from old: Double, to new: Double) -> Bool { new != old && (new == 0 || new == 1) }

    /// The track declares no animation; the fill follows the transaction that updates the value (RE-27-BEHAVIOR s15),
    /// and on the PROLED footage that transaction animates: youtube drlYGnbWurM 764.4-765.4 s (30 fps, key held), the
    /// fill end lands mid-tick and reaches each 1/16 step at ~0.45 / 0.80 / 0.95 / 1.0 of the step on frames 1-4, which
    /// fits the controller's spring(0.2, 0.85) (0.43 / 0.76 / 0.93 / 0.98 at a 10 ms phase); spring(0.48669, 1.0),
    /// spring(0.62832, 0.73333) and interpolatingSpring(2, 300, 50) are far slower (0.11 or less on frame 1) [footage].
    static let fillSpring = Animation.spring(response: 0.2, dampingFraction: 0.85)

    static func value(atX x: CGFloat, inflated: Bool) -> Double {
        let t = trackFrame(inflated: inflated)
        return Double(min(max((x - t.minX) / t.width, 0), 1))
    }
}

/// Focus compact (SystemBannerUI): SystemBannerAssetView 18 + padding(.leading, 8); GreedyTextLayout(max 120) +
/// padding(.trailing, 10); Font.system(.callout, weight: .semibold).leading(.tight). 27.3 scales compact content by
/// ReferenceScaledLayout(obstruction height / 41) (CenterHUDBannerContainer 0x2b1aadfe4): 34 / 41 on the emulate path.
/// User decision (2026-11-23): the PROLED look, i.e. the hardware case where the obstruction equals the reference: scale 1.
enum FocusMetrics {
    static let iconSize: CGFloat = 18, leading: CGFloat = 8, trailing: CGFloat = 10, maxTextWidth: CGFloat = 120
    static var font: NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
    }
    static func textWidth(_ s: String) -> CGFloat {
        min(ceil((s as NSString).size(withAttributes: [.font: font]).width), maxTextWidth)
    }
    static var leadingWidth: CGFloat { leading + iconSize }
    static func trailingWidth(isOn: Bool) -> CGFloat { textWidth(stateText(isOn: isOn)) + trailing }

    /// The trailing text is the localized state, not the Focus name: isOn ? "FOCUS_MODE_ON" : "FOCUS_MODE_OFF"
    /// (0x2b1ac05c4, accessibilityIdentifier "focus-mode-state"); values from the 27.3 SystemBannerUI.loctable (en, vi).
    static func stateText(isOn: Bool, language: String = Locale.preferredLanguages.first ?? "en") -> String {
        language.hasPrefix("vi") ? (isOn ? "Bật" : "Tắt") : (isOn ? "On" : "Off")
    }

    /// Off: icon and text Color(red 0.38824, green 0.38824, blue 0.4) = #636366 (@0x2e1f4cb00, init 0x2b1ac09cc);
    /// on: both in the activity colour (RE-27-BEHAVIOR s18).
    static let offGrey = (0.38824, 0.38824, 0.4)
    static func color(_ activity: FocusActivity, isOn: Bool) -> Color {
        isOn ? systemColor(activity.colorName) : Color(red: offGrey.0, green: offGrey.1, blue: offGrey.2)
    }
}

final class SliderModel: ObservableObject {
    @Published var kind: LevelKind
    @Published var value: Double {
        didSet { if SliderMetrics.bouncesAtEnd(from: oldValue, to: value) { bounceSeed += 1 } }
    }
    @Published var inflated = false
    @Published private(set) var bounceSeed = 0
    init(kind: LevelKind, value: Double) { self.kind = kind; self.value = value }
}

struct SliderView: View {
    @ObservedObject var model: SliderModel

    var body: some View {
        // Geometry comes from the view's own size (the panel sizes it with the animated island), so the track and the
        // icon never move relative to the island; SwiftUI only animates the icon scale and the tick closing.
        GeometryReader { g in content(g.size) }
            .environment(\.colorScheme, .dark)
            .animation(SliderMetrics.inflateSpring, value: model.inflated)
    }

    private func content(_ size: CGSize) -> some View {
        let track = SliderMetrics.trackFrame(in: size), icon = SliderMetrics.iconBox(in: size)
        return ZStack(alignment: .topLeading) {
            Image(systemName: SliderMetrics.symbol(model.kind, model.value))
                .font(.system(size: SliderMetrics.iconSize))   // Font.system(size:) without weight (SystemBannerAssetView)
                .foregroundStyle(.white)                       // SliderBannerImageView Color.white
                .symbolEffect(.bounce, options: .default, value: model.bounceSeed)
                .offset(y: model.kind == .displayBrightness ? -0.5 : 0)   // brightness symbol vertical offset (0x2b1acf7bc)
                .scaleEffect(model.inflated ? SliderMetrics.iconInflatedScale : 1, anchor: .trailing)
                .frame(width: icon.width, height: icon.height, alignment: .leading)   // starts right after padding 16
                .offset(x: icon.minX, y: icon.minY)
            TrackView(value: model.value, tickProgress: SliderMetrics.tickProgress(inflated: model.inflated))
                .animation(SliderMetrics.fillSpring, value: model.value)
                .frame(width: track.width, height: track.height)
                .offset(x: track.minX, y: size.height - track.maxY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct TrackView: View {
    var value: Double
    var tickProgress: CGFloat

    var body: some View {
        GeometryReader { g in
            let r = SliderMetrics.cornerRadius, tr = SliderMetrics.fillTrailingRadius(value: value)
            ZStack(alignment: .leading) {
                Capsule().fill(.tertiary)   // Capsule + HierarchicalShapeStyle.tertiary (global @0x2b1aaac98), RE-27-BEHAVIOR s16
                UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: tr, topTrailingRadius: tr)
                    .fill(.primary)
                    .frame(width: max(0, g.size.width * value))
            }
            .foregroundStyle(.white)
            .mask { TickMask(progress: tickProgress).fill(style: FillStyle(eoFill: true)) }
        }
    }
}

/// TickedTrackMask: the track rect with SliderMetrics.tickRects cut out (even-odd) [I even-odd].
private struct TickMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        for t in SliderMetrics.tickRects(width: rect.width, height: rect.height, progress: progress) { p.addRect(t.offsetBy(dx: rect.minX, dy: rect.minY)) }
        return p
    }
}

func systemColor(_ name: String) -> Color {
    let sel = NSSelectorFromString(name)
    guard NSColor.responds(to: sel), let c = NSColor.perform(sel)?.takeUnretainedValue() as? NSColor else { return .white }
    return Color(nsColor: c)
}

/// SF Symbol by name, public or private (27.3 Focus uses Image(_internalSystemName:); e.g. "rocket.fill" for Gaming is
/// private on 26.6 and loads through +[NSImage imageWithPrivateSystemSymbolName:]).
func symbolImage(_ name: String, pointSize: CGFloat) -> Image {
    let sel = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? (NSImage.responds(to: sel) ? NSImage.perform(sel, with: name)?.takeUnretainedValue() as? NSImage : nil)
    guard let img, let sized = img.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) else {
        return Image(systemName: "questionmark")
    }
    return Image(nsImage: sized).renderingMode(.template)
}

struct FocusLeading: View {
    var activity: FocusActivity
    var isOn = true
    var body: some View {
        symbolImage(activity.symbol, pointSize: FocusMetrics.iconSize)   // Image(_internalSystemName: activity.imageName)
            .foregroundStyle(FocusMetrics.color(activity, isOn: isOn))
            .frame(width: FocusMetrics.iconSize, height: FocusMetrics.iconSize)
            .padding(.leading, FocusMetrics.leading)
    }
}

struct FocusTrailing: View {
    var activity: FocusActivity
    var isOn = true
    var body: some View {
        Text(FocusMetrics.stateText(isOn: isOn))
            .font(.system(.callout, weight: .semibold).leading(.tight))
            .foregroundStyle(FocusMetrics.color(activity, isOn: isOn))
            .lineLimit(1)
            .frame(maxWidth: FocusMetrics.maxTextWidth, alignment: .leading)
            .padding(.trailing, FocusMetrics.trailing)
    }
}

/// NSHostingView sized to `size`, transparent, not hit-testable (the island view handles the mouse).
func hosted<V: View>(_ view: V, size: CGSize) -> NSView {
    let h = NSHostingView(rootView: view)
    h.frame = CGRect(origin: .zero, size: size)
    return h
}
