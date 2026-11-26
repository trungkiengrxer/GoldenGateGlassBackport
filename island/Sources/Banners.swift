// System banners from 27.3 SystemBannerUI: battery (LowBatterySystemBannerContent), HID accessory
// (AccessorySystemBannerContent) and headphones/speaker connect (SmartRoutingSystemBannerContent).
// Values and addresses: docs/RE-27-BEHAVIOR.md sections 19 and 20. [V] read from the binary, [I] inferred, [?] unknown.
import AppKit
import SwiftUI

struct BatteryState: Equatable {
    var level: Double
    var isCharging: Bool
    var isLowPowerMode: Bool
    var isWarning: Bool   // IOPS warning level Early
}

enum AccessoryKind: String { case keyboard, mouse, trackpad, gameController }   // userInfo "type" (sub_2b1afe198) [V]

struct AccessoryInfo: Equatable {
    var kind: AccessoryKind
    var name: String
    var message: String?
    var batteryLevel: Double?
    var isLowBattery: Bool
}

struct SmartRoutingInfo: Equatable {
    var title: String
    var message: String?
    var batteryLevel: Double?
    var needsAlerting: Bool
}

enum BannerVariant { case compact, expanded, banner }
enum GlyphColor: Equatable { case style, white, black }

enum BannerMetrics {
    // MARK: Battery style and strings

    /// Style byte +9 (0x2b1ac3e04): charging unless the warning case. Color.Resolved floats (0x2b1ac91f4): green
    /// 0x2b1ac9190, LPM yellow 0x2b1ac91b4 (both cases), warning red 0x2b1ac91d0 [V]; colour space [?] (sRGB assumed).
    static func batteryRGB(_ s: BatteryState) -> (Double, Double, Double) {
        s.isLowPowerMode ? (1.0, 0.8383, 0.0) : s.isCharging ? (0.1834, 0.8199, 0.3428) : (0.9979, 0.2579, 0.2698)
    }
    static func batteryColor(_ s: BatteryState) -> Color { let c = batteryRGB(s); return Color(red: c.0, green: c.1, blue: c.2) }
    static func isLowBattery(_ level: Double) -> Bool { level <= 0.2 }   // ControlCenter 0x1004a53b8 [V]

    static var language: String { Locale.preferredLanguages.first ?? "en" }

    /// Compact leading text (0x2b1ac4938), SystemBannerUI.loctable en / vi [V].
    static func batteryCompactText(_ s: BatteryState, language: String = language) -> String {
        let vi = language.hasPrefix("vi")
        if s.isCharging { return vi ? "Đang sạc" : "Charging" }
        if s.isLowPowerMode { return vi ? "Nguồn điện thấp" : "Low Power" }
        return vi ? "Pin yếu" : "Low Battery"
    }

    /// Text(level, format: percent) (0x2b1ac64d0) [V]; whole percent [I] (IOPS capacities are integer percent).
    static func percentText(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    /// "%@ Battery" / "%@ pin" (0x2b1ac503c) [V].
    static func batteryTitle(_ s: BatteryState, language: String = language) -> String {
        if s.isCharging { return language.hasPrefix("vi") ? "Đang sạc" : "Charging" }
        return percentText(s.level) + (language.hasPrefix("vi") ? " pin" : " Battery")
    }

    /// Bottom line of the warning (0x2b1ac5e94): LPM -> enabled (yellow), else the tap hint (SystemBannerUI-K114) [V].
    static func batteryBottomText(_ s: BatteryState, language: String = language) -> String {
        let vi = language.hasPrefix("vi")
        return s.isLowPowerMode ? (vi ? "Đã bật Chế độ nguồn điện thấp" : "Low Power Mode Enabled")
                                : (vi ? "Chạm để bật Chế độ nguồn điện thấp" : "Tap to turn on Low Power Mode")
    }

    /// HID_DEVICE_CONNECTED (0x2b1afc4bc) when the request has no message [V].
    static func accessoryMessage(_ message: String?, language: String = language) -> String {
        message ?? (language.hasPrefix("vi") ? "Đã kết nối" : "Connected")
    }

    // MARK: Battery compact

    /// Font of the compact texts: CompactTextModifier font 0x2e1f4c830 = system(.callout, weight: .semibold)
    /// .leading(.tight) (initialiser 0x2b1aaa354) [V]; the same font as the Focus compact text.
    static var font: NSFont { FocusMetrics.font }
    static let compactInset: CGFloat = 11, maxTextWidth: CGFloat = 120, trailingSpacing: CGFloat = 5   // 0x2e1f4cbe8, 0x2b1ac6798 [V]

    static func textWidth(_ s: String) -> CGFloat {
        min(ceil((s as NSString).size(withAttributes: [.font: font]).width), maxTextWidth)
    }
    static func batteryCompactLeadingSize(_ s: BatteryState, sensorHeight h: CGFloat) -> CGSize {
        CGSize(width: compactInset + textWidth(batteryCompactText(s)), height: h)
    }
    static func batteryCompactTrailingSize(_ s: BatteryState, sensorHeight h: CGFloat) -> CGSize {
        CGSize(width: textWidth(percentText(s.level)) + trailingSpacing + glyphSize(.compact).width + compactInset, height: h)
    }

    // MARK: Battery expanded (warning)

    /// 300 x 60 with a bottom line, 220 x 50 without (0x2b1ac4f7c) [V].
    static func batteryExpandedSize(hasBottomLine: Bool) -> CGSize {
        hasBottomLine ? CGSize(width: 300, height: 60) : CGSize(width: 220, height: 50)
    }
    static let expandedLeadingInset: CGFloat = 13, warningTitlePadding: CGFloat = 8, titleBottom: CGFloat = 4   // 0x2e1f4cc10, 0x2b1ac547c [V]
    static let lowPowerButton = CGSize(width: 54, height: 35), lowPowerButtonRadius: CGFloat = 16.333       // 0x2b1ac7708 [V]
    static let bottomGap: CGFloat = 7                                                                   // 0x2b1ac6020 [V]
    static var warningTextLeading: CGFloat { expandedLeadingInset + warningTitlePadding }
    static func warningTextTrailing(height: CGFloat) -> CGFloat { (height - lowPowerButton.height) / 2 + lowPowerButton.width + bottomGap }

    /// Top-left origin; right margin (H - 35) / 2, vertically centred (0x2b1ac5698) [V]. The island view hit-tests this.
    static func lowPowerButtonFrame(in s: CGSize) -> CGRect {
        let m = (s.height - lowPowerButton.height) / 2
        return CGRect(x: s.width - m - lowPowerButton.width, y: m, width: lowPowerButton.width, height: lowPowerButton.height)
    }

    // MARK: Battery glyph (LowBatterySystemBannerView 0x2b1ac7e50; compact = expanded = minimal, banner)

    static func glyphSize(_ v: BannerVariant) -> CGSize {
        v == .banner ? CGSize(width: 34 + 2 + 3, height: 20) : CGSize(width: 30 + 1 + 2, height: 15)
    }
    static func glyphBody(_ v: BannerVariant) -> (width: CGFloat, radius: CGFloat) { v == .banner ? (34, 7) : (30, 5) }
    static func glyphNub(_ v: BannerVariant) -> (size: CGSize, radius: CGFloat, spacing: CGFloat) {
        v == .banner ? (CGSize(width: 3, height: 7), 2, 2) : (CGSize(width: 2, height: 5), 1, 1)
    }

    /// Fill in body coordinates (top-left): compact full-bleed 30 x level; otherwise inset 3 / (2.5 | 4.5), radius 4 / 6
    /// (0x2b1ac7ba0) [V numbers, I geometry].
    static func glyphFill(_ v: BannerVariant, level: Double) -> CGRect {
        let l = CGFloat(min(max(level, 0), 1)), w = glyphBody(v).width, h = glyphSize(v).height
        if v == .compact { return CGRect(x: 0, y: 0, width: w * l, height: h) }
        let dy: CGFloat = v == .banner ? 4.5 : 2.5
        return CGRect(x: 3, y: dy, width: (w - 6) * l, height: h - 2 * dy)
    }
    static func glyphFillRadius(_ v: BannerVariant) -> CGFloat { v == .banner ? 6 : 4 }

    /// Nub opacity 1 when full (|level - 1| <= epsilon), 0.5 otherwise (0x2b1ac9270) [V]; the 0.3 branch [?].
    static func nubOpacity(level: Double) -> Double { abs(level - 1) <= 0.001 ? 1 : 0.5 }

    /// Expanded: warning without LPM fills white (0x2b1ac7a6c), the nub is black off plain charging (0x2b1ac7854) [V, I scope].
    static func glyphColors(_ s: BatteryState, _ v: BannerVariant) -> (fill: GlyphColor, nub: GlyphColor) {
        guard v == .expanded, !s.isCharging || s.isLowPowerMode else { return (.style, .style) }
        return (s.isCharging || s.isLowPowerMode ? .style : .white, .black)
    }

    /// Expanded warning without LPM adds the optional second ZStack child (body typealias): StrokeShapeView with
    /// lineWidth 0.5, padding(.horizontal, -5), padding(.vertical, -3), scaleEffect(chargeScale), chargeScale 8/9 then
    /// withAnimation(.easeOut(duration: 0.48).delay(0.5)) { 1 } on appear (0x2b1ac85a4, 0x2b1ac8fd8, 0x2b1ac9068)
    /// [V numbers]. Shape = body RoundedRectangle, colour = style, and the frame width 13 / offset not applied [I / ?].
    static func hasChargeOutline(_ s: BatteryState, _ v: BannerVariant) -> Bool {
        v == .expanded && s.isWarning && !s.isCharging && !s.isLowPowerMode
    }
    static let chargeScaleStart: CGFloat = 8.0 / 9
    static let chargeAnimation = Animation.easeOut(duration: 0.48).delay(0.5)
    static let chargeOutlineWidth: CGFloat = 0.5
    static let chargeOutlineOutset = CGSize(width: 5, height: 3)

    // MARK: Accessory and SmartRouting compact

    /// Compact insets {0, 10, 0, 8.5} (0x2b1abe86c), asset 20 x 20 (0x2b1aaa178), ring 23 / 36 (0x2b1aaa324) [V].
    static let accessoryLeading: CGFloat = 10, accessoryTrailing: CGFloat = 8.5, assetSize: CGFloat = 20
    static func ringDiameter(_ v: BannerVariant) -> CGFloat { v == .compact ? 23 : 36 }
    /// CircularProgressView line width table (0x2b1aecb58): minimal nil, compact 2.45, expanded 3, banner 4 [V].
    static func ringLineWidth(_ v: BannerVariant) -> CGFloat {
        switch v { case .compact: return 2.45; case .expanded: return 3; case .banner: return 4 }
    }

    static func accessoryCompactLeadingSize(sensorHeight h: CGFloat) -> CGSize { CGSize(width: accessoryLeading + assetSize, height: h) }
    static func accessoryCompactTrailingSize(batteryLevel: Double?, sensorHeight h: CGFloat) -> CGSize {
        CGSize(width: batteryLevel == nil ? 0 : ringDiameter(.compact) + accessoryTrailing, height: h)
    }
    static func ringIsRed(_ info: AccessoryInfo) -> Bool { info.isLowBattery }   // red if low, else green (0x2b1abdf90) [V]

    /// [I] SF Symbols stand in for the product images (27.3: productID + color or a UTType icon).
    static func symbol(_ k: AccessoryKind) -> String {
        switch k {
        case .keyboard: return "keyboard"
        case .mouse: return "magicmouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gameController: return "gamecontroller"
        }
    }

    /// SmartRouting compact uses the accessory insets (0x2b1acbdc8 -> 0x2b1abe8c8) [V call, I layout]; the product
    /// image or video is replaced by a symbol [I].
    static let smartRoutingSymbol = "airpods"
    static func smartRoutingCompactLeadingSize(sensorHeight h: CGFloat) -> CGSize { accessoryCompactLeadingSize(sensorHeight: h) }
    static func smartRoutingCompactTrailingSize(batteryLevel: Double?, sensorHeight h: CGFloat) -> CGSize {
        accessoryCompactTrailingSize(batteryLevel: batteryLevel, sensorHeight: h)
    }
}

// MARK: - Views

private func resolve(_ c: GlyphColor, style: Color) -> Color {
    switch c { case .style: return style; case .white: return .white; case .black: return .black }
}

struct BatteryGlyph: View {
    var state: BatteryState
    var variant: BannerVariant

    var body: some View {
        typealias M = BannerMetrics
        let style = M.batteryColor(state), colors = M.glyphColors(state, variant)
        let b = M.glyphBody(variant), n = M.glyphNub(variant), h = M.glyphSize(variant).height
        let fill = M.glyphFill(variant, level: state.level)
        return HStack(spacing: n.spacing) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: b.radius, style: .continuous).fill(style.opacity(0.3))   // [I] body opacity
                Group {
                    if variant == .compact { Rectangle() } else { RoundedRectangle(cornerRadius: M.glyphFillRadius(variant), style: .continuous) }
                }
                .foregroundStyle(resolve(colors.fill, style: style))
                .frame(width: fill.width, height: fill.height)
                .offset(x: fill.minX, y: fill.minY)
            }
            .frame(width: b.width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: b.radius, style: .continuous))
            .overlay { if M.hasChargeOutline(state, variant) { ChargeOutline(radius: b.radius, color: style) } }
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: n.radius, topTrailingRadius: n.radius)
                .fill(resolve(colors.nub, style: style).opacity(M.nubOpacity(level: state.level)))
                .frame(width: n.size.width, height: n.size.height)
        }
        .frame(height: h)
    }
}

/// See BannerMetrics.hasChargeOutline: grows from 8/9 to 1 once, on appear.
private struct ChargeOutline: View {
    var radius: CGFloat
    var color: Color
    @State private var scale = BannerMetrics.chargeScaleStart
    private typealias M = BannerMetrics
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(color, lineWidth: M.chargeOutlineWidth)
            .padding(.horizontal, -M.chargeOutlineOutset.width)
            .padding(.vertical, -M.chargeOutlineOutset.height)
            .scaleEffect(scale)
            .onAppear { withAnimation(M.chargeAnimation) { scale = 1 } }
    }
}

struct BatteryCompactLeading: View {
    var state: BatteryState
    var body: some View {
        Text(BannerMetrics.batteryCompactText(state))
            .font(.system(.callout, weight: .semibold).leading(.tight))   // CompactTextModifier (0x2b1aaa354) [V]
            .foregroundStyle(.white)                                      // default (primary) on the dark island
            .lineLimit(1)
            .frame(maxWidth: BannerMetrics.maxTextWidth, alignment: .leading)
            .padding(.leading, BannerMetrics.compactInset)
    }
}

struct BatteryCompactTrailing: View {
    var state: BatteryState
    var body: some View {
        HStack(alignment: .center, spacing: BannerMetrics.trailingSpacing) {
            Text(BannerMetrics.percentText(state.level))
                .font(.system(.callout, weight: .semibold).leading(.tight))
                .foregroundStyle(BannerMetrics.batteryColor(state))
                .lineLimit(1)
            BatteryGlyph(state: state, variant: .compact)
        }
        .padding(.trailing, BannerMetrics.compactInset)
    }
}

/// Low-battery warning, expanded 300 x 60: title + bottom line on the left, Low Power Mode button on the right.
/// Fonts [?]: not read; title callout semibold, bottom line footnote.
struct BatteryWarningExpanded: View {
    var state: BatteryState
    var onLowPowerMode: () -> Void

    var body: some View {
        typealias M = BannerMetrics
        let size = M.batteryExpandedSize(hasBottomLine: true), button = M.lowPowerButtonFrame(in: size)
        let style = M.batteryColor(state)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(M.batteryTitle(state))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)   // GreedyText max 200 (0x2b1ac503c) [V]
                    .padding(.bottom, M.titleBottom)
                Text(M.batteryBottomText(state))
                    .font(.footnote)
                    .foregroundStyle(state.isLowPowerMode ? style : Color.white.opacity(0.6))   // [?] secondary tone
                    .lineLimit(2)
            }
            .frame(width: size.width - M.warningTextLeading - M.warningTextTrailing(height: size.height), height: size.height,
                   alignment: .leading)
            .offset(x: M.warningTextLeading)
            Button(action: onLowPowerMode) {
                BatteryGlyph(state: state, variant: .expanded).padding(.trailing, -2)   // label padding (0x2b1ac73ac) [V]
            }
            .buttonStyle(LowPowerButtonStyle(color: style))
            .offset(x: button.minX, y: button.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// ExpandedLowBatterySystemBannerTrailingButtonStyle: continuous RoundedRectangle(16.333) in the style colour at 0.3,
/// 54 x 35 (0x2b1ac7708) [V]. Pressed look [?].
private struct LowPowerButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: BannerMetrics.lowPowerButton.width, height: BannerMetrics.lowPowerButton.height)
            .background(RoundedRectangle(cornerRadius: BannerMetrics.lowPowerButtonRadius, style: .continuous).fill(color.opacity(0.3)))
    }
}

/// Battery ring, CompactCircularProgressView / ExpandedCircularProgressView -> CircularProgressView: red when low,
/// green otherwise (0x2b1abdf90) [V]; fill round cap from 12 o'clock [V]; track colour (a Material in 27.3) [?].
struct BatteryRing: View {
    var level: Double
    var isLow: Bool
    var variant: BannerVariant = .compact

    var body: some View {
        let c: Color = isLow ? .red : .green, w = BannerMetrics.ringLineWidth(variant)
        ZStack {
            Circle().stroke(c.opacity(0.3), lineWidth: w)
            Circle().trim(from: 0, to: min(max(level, 0), 1))
                .stroke(c, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(w / 2)
        .frame(width: BannerMetrics.ringDiameter(variant), height: BannerMetrics.ringDiameter(variant))
    }
}

private struct AssetSymbol: View {
    var name: String
    var body: some View {
        Image(systemName: name).resizable().scaledToFit()
            .foregroundStyle(.white)
            .frame(width: BannerMetrics.assetSize, height: BannerMetrics.assetSize)
            .padding(.leading, BannerMetrics.accessoryLeading)
    }
}

private struct RingTrailing: View {
    var level: Double?
    var isLow: Bool
    var body: some View {
        if let level { BatteryRing(level: level, isLow: isLow).padding(.trailing, BannerMetrics.accessoryTrailing) }
    }
}

struct AccessoryCompactLeading: View {
    var info: AccessoryInfo
    var body: some View { AssetSymbol(name: BannerMetrics.symbol(info.kind)) }
}

struct AccessoryCompactTrailing: View {
    var info: AccessoryInfo
    var body: some View { RingTrailing(level: info.batteryLevel, isLow: info.isLowBattery) }
}

struct SmartRoutingCompactLeading: View {
    var info: SmartRoutingInfo
    var body: some View { AssetSymbol(name: BannerMetrics.smartRoutingSymbol) }
}

/// [I] Same trailing as the accessory: ring when a level is known, nothing otherwise; low = level <= 0.2.
struct SmartRoutingCompactTrailing: View {
    var info: SmartRoutingInfo
    var body: some View { RingTrailing(level: info.batteryLevel, isLow: info.batteryLevel.map(BannerMetrics.isLowBattery) ?? false) }
}
