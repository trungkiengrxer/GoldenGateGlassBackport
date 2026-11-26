// Window-free tests for the battery, accessory (HID) and SmartRouting banners (island/Sources/Banners.swift).
// Expected values are computed by hand from docs/RE-27-BEHAVIOR.md sections 19 and 20 (27.3 SystemBannerUI).
// Own executable (own @main) so it needs no hook in tests.swift.
import AppKit
import Foundation
import SwiftUI

private var failures = 0
private func ok(_ c: Bool, _ name: String) { print(c ? "OK   banners.\(name)" : "FAIL banners.\(name)"); if !c { failures += 1 } }
private func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) <= eps }

@main enum BannerTests {
    static func main() {
        style()
        strings()
        battery()
        glyph()
        accessory()
        smartRouting()
        MainActor.assumeIsolated { renders() }
        exit(failures == 0 ? 0 : 1)
    }

    static let charging = BatteryState(level: 0.8, isCharging: true, isLowPowerMode: false, isWarning: false)
    static let chargingLPM = BatteryState(level: 0.8, isCharging: true, isLowPowerMode: true, isWarning: false)
    static let warning = BatteryState(level: 0.1, isCharging: false, isLowPowerMode: false, isWarning: true)
    static let warningLPM = BatteryState(level: 0.1, isCharging: false, isLowPowerMode: true, isWarning: true)

    /// Style byte +9 (0x2b1ac3e04): charging unless the warning case; colours 0x2b1ac9190 / 0x2b1ac91b4 / 0x2b1ac91d0.
    static func style() {
        typealias M = BannerMetrics
        ok(M.batteryRGB(charging) == (0.1834, 0.8199, 0.3428), "greenWhenCharging")
        ok(M.batteryRGB(chargingLPM) == (1.0, 0.8383, 0.0) && M.batteryRGB(warningLPM) == (1.0, 0.8383, 0.0), "yellowWithLPM")
        ok(M.batteryRGB(warning) == (0.9979, 0.2579, 0.2698), "redWarning")
        // isLowBattery = level <= 0.2 (ControlCenter 0x1004a53b8).
        ok(M.isLowBattery(0.2) && !M.isLowBattery(0.21), "lowBatteryThreshold")
    }

    /// SystemBannerUI.loctable / SystemBannerUI-K114.loctable (27.3), en and vi.
    static func strings() {
        typealias M = BannerMetrics
        ok(M.batteryCompactText(charging, language: "en") == "Charging" && M.batteryCompactText(charging, language: "vi") == "Đang sạc",
           "compactCharging")
        ok(M.batteryCompactText(warning, language: "en") == "Low Battery" && M.batteryCompactText(warning, language: "vi") == "Pin yếu",
           "compactLowBattery")
        ok(M.batteryCompactText(warningLPM, language: "en") == "Low Power"
           && M.batteryCompactText(warningLPM, language: "vi") == "Nguồn điện thấp", "compactLowPower")
        ok(M.percentText(0.8) == "80%" && M.percentText(0.105) == "11%", "percent")
        ok(M.batteryTitle(warning, language: "en") == "10% Battery" && M.batteryTitle(warning, language: "vi") == "10% pin", "title")
        ok(M.batteryBottomText(warning, language: "en") == "Tap to turn on Low Power Mode"
           && M.batteryBottomText(warning, language: "vi") == "Chạm để bật Chế độ nguồn điện thấp", "bottomTap")
        ok(M.batteryBottomText(warningLPM, language: "en") == "Low Power Mode Enabled"
           && M.batteryBottomText(warningLPM, language: "vi") == "Đã bật Chế độ nguồn điện thấp", "bottomEnabled")
        ok(M.accessoryMessage(nil, language: "en") == "Connected" && M.accessoryMessage(nil, language: "vi") == "Đã kết nối"
           && M.accessoryMessage("Hi", language: "en") == "Hi", "accessoryMessage")
    }

    /// Compact insets {0, 11, 0, 11} (0x2e1f4cbe8), GreedyText max 120, trailing HStack spacing 5 { percent; glyph }.
    static func battery() {
        typealias M = BannerMetrics
        let lead = M.batteryCompactLeadingSize(charging, sensorHeight: 34)
        ok(lead.height == 34 && near(lead.width, 11 + M.textWidth(M.batteryCompactText(charging))), "compactLeadingWidth")
        ok(M.textWidth(String(repeating: "W", count: 60)) == 120, "compactTextCapped")
        let trail = M.batteryCompactTrailingSize(charging, sensorHeight: 34)
        ok(near(trail.width, M.textWidth(M.percentText(0.8)) + 5 + M.glyphSize(.compact).width + 11), "compactTrailingWidth")
        ok(M.glyphSize(.compact) == CGSize(width: 33, height: 15) && M.glyphSize(.banner) == CGSize(width: 39, height: 20), "glyphSize")

        // Expanded 300 x 60 with a bottom line, 220 x 50 without (0x2b1ac4f7c); the warning always has one.
        ok(M.batteryExpandedSize(hasBottomLine: true) == CGSize(width: 300, height: 60)
           && M.batteryExpandedSize(hasBottomLine: false) == CGSize(width: 220, height: 50), "expandedSize")
        // Button 54 x 35, right margin (60 - 35) / 2 = 12.5, centred (0x2b1ac73ac, 0x2b1ac7708). Top-left origin.
        ok(M.lowPowerButtonFrame(in: CGSize(width: 300, height: 60)) == CGRect(x: 233.5, y: 12.5, width: 54, height: 35), "buttonFrame")
        ok(M.lowPowerButtonRadius == 16.333, "buttonRadius")
        // Text column: leading 13 + 8, trailing 12.5 + 54 + 7 (0x2b1ac5e94).
        ok(M.warningTextLeading == 21 && near(M.warningTextTrailing(height: 60), 73.5), "textInsets")
    }

    /// LowBatterySystemBannerView 0x2b1ac7e50 / 0x2b1ac7ba0 / 0x2b1ac80d0 (compact = expanded = minimal; banner).
    static func glyph() {
        typealias M = BannerMetrics
        // compact fill: full-bleed 30 x level; expanded: inset 3 / 2.5, so 24 x level.
        ok(near(M.glyphFill(.compact, level: 0.5).width, 15) && M.glyphFill(.compact, level: 0.5).height == 15, "fillCompact")
        let e = M.glyphFill(.expanded, level: 0.5)
        ok(near(e.width, 12) && e.height == 10 && e.minX == 3 && e.minY == 2.5, "fillExpanded")
        ok(M.glyphFill(.compact, level: 1.4).width == 30 && M.glyphFill(.compact, level: -1).width == 0, "fillClamped")
        ok(M.nubOpacity(level: 1) == 1 && M.nubOpacity(level: 0.5) == 0.5, "nubOpacity")
        // Expanded warning without LPM: white fill, black nub (0x2b1ac7a6c, 0x2b1ac7854).
        ok(M.glyphColors(warning, .expanded) == (.white, .black), "expandedWarningColors")
        ok(M.glyphColors(warning, .compact) == (.style, .style), "compactColors")
        ok(M.glyphColors(warningLPM, .expanded) == (.style, .black), "expandedLPMColors")
        // Outline only on the expanded warning without LPM (0x2b1ac85a4); chargeScale 8/9 -> 1, easeOut 0.48 after 0.5.
        ok(M.hasChargeOutline(warning, .expanded) && !M.hasChargeOutline(warningLPM, .expanded)
           && !M.hasChargeOutline(warning, .compact) && !M.hasChargeOutline(charging, .expanded), "chargeOutlineScope")
        ok(near(M.chargeScaleStart, 8.0 / 9) && M.chargeAnimation == .easeOut(duration: 0.48).delay(0.5), "chargeAnimation")
        ok(M.chargeOutlineWidth == 0.5 && M.chargeOutlineOutset == CGSize(width: 5, height: 3), "chargeOutline")
    }

    /// AccessorySystemBannerContent: compact insets {0, 10, 0, 8.5} (0x2b1abe86c), asset 20 (0x2b1aaa178), ring 23 / 36
    /// (0x2b1aaa324); no battery -> no trailing.
    static func accessory() {
        typealias M = BannerMetrics
        let info = AccessoryInfo(kind: .keyboard, name: "Keyboard", message: nil, batteryLevel: 0.15, isLowBattery: true)
        ok(M.accessoryCompactLeadingSize(sensorHeight: 34) == CGSize(width: 30, height: 34), "leadingSize")
        ok(M.accessoryCompactTrailingSize(batteryLevel: 0.5, sensorHeight: 34) == CGSize(width: 31.5, height: 34), "trailingSize")
        ok(M.accessoryCompactTrailingSize(batteryLevel: nil, sensorHeight: 34).width == 0, "noBatteryNoTrailing")
        ok(M.ringDiameter(.compact) == 23 && M.ringDiameter(.expanded) == 36, "ringDiameter")
        // CircularProgressView line width per variant (0x2b1aecb58): minimal nil, compact 2.45, expanded 3, banner 4.
        ok(M.ringLineWidth(.compact) == 2.45 && M.ringLineWidth(.expanded) == 3 && M.ringLineWidth(.banner) == 4, "ringLineWidth")
        ok(M.ringIsRed(info) && !M.ringIsRed(AccessoryInfo(kind: .mouse, name: "m", message: nil, batteryLevel: 0.9, isLowBattery: false)),
           "ringColor")
        for k in [AccessoryKind.keyboard, .mouse, .trackpad, .gameController] {
            ok(NSImage(systemSymbolName: M.symbol(k), accessibilityDescription: nil) != nil, "symbolExists.\(k.rawValue)")
        }
        ok(AccessoryKind(rawValue: "gameController") == .gameController && AccessoryKind(rawValue: "pen") == nil, "kindRawValues")
    }

    /// SmartRouting compact reuses the accessory insets (0x2b1acbdc8 -> 0x2b1abe8c8).
    static func smartRouting() {
        typealias M = BannerMetrics
        ok(M.smartRoutingCompactLeadingSize(sensorHeight: 34) == M.accessoryCompactLeadingSize(sensorHeight: 34), "leadingSize")
        ok(M.smartRoutingCompactTrailingSize(batteryLevel: 0.4, sensorHeight: 34).width == 31.5
           && M.smartRoutingCompactTrailingSize(batteryLevel: nil, sensorHeight: 34).width == 0, "trailingSize")
        ok(NSImage(systemSymbolName: M.smartRoutingSymbol, accessibilityDescription: nil) != nil, "symbolExists")
    }

    /// Every view renders at its metrics size (no fixed-size overflow).
    @MainActor static func renders() {
        func size<V: View>(_ v: V) -> CGSize? {
            let r = ImageRenderer(content: v)
            r.scale = 1
            return r.cgImage.map { CGSize(width: $0.width, height: $0.height) }
        }
        typealias M = BannerMetrics
        let h: CGFloat = 34
        let acc = AccessoryInfo(kind: .trackpad, name: "Trackpad", message: nil, batteryLevel: 0.5, isLowBattery: false)
        let sr = SmartRoutingInfo(title: "AirPods", message: nil, batteryLevel: 0.7, needsAlerting: false)
        let cases: [(String, CGSize?, CGSize)] = [
            ("batteryLeading", size(BatteryCompactLeading(state: charging).frame(height: h)), M.batteryCompactLeadingSize(charging, sensorHeight: h)),
            ("batteryTrailing", size(BatteryCompactTrailing(state: charging).frame(height: h)), M.batteryCompactTrailingSize(charging, sensorHeight: h)),
            ("warningExpanded", size(BatteryWarningExpanded(state: warning, onLowPowerMode: {})), M.batteryExpandedSize(hasBottomLine: true)),
            ("accessoryLeading", size(AccessoryCompactLeading(info: acc).frame(height: h)), M.accessoryCompactLeadingSize(sensorHeight: h)),
            ("accessoryTrailing", size(AccessoryCompactTrailing(info: acc).frame(height: h)), M.accessoryCompactTrailingSize(batteryLevel: 0.5, sensorHeight: h)),
            ("smartRoutingLeading", size(SmartRoutingCompactLeading(info: sr).frame(height: h)), M.smartRoutingCompactLeadingSize(sensorHeight: h)),
            ("smartRoutingTrailing", size(SmartRoutingCompactTrailing(info: sr).frame(height: h)), M.smartRoutingCompactTrailingSize(batteryLevel: 0.7, sensorHeight: h)),
        ]
        for (name, got, want) in cases {
            ok(got.map { abs($0.width - ceil(want.width)) <= 1 && $0.height == ceil(want.height) } ?? false,
               "renders.\(name) (\(got.map { "\($0.width)x\($0.height)" } ?? "nil") vs \(want.width)x\(want.height))")
        }
    }
}
