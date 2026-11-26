// What the island shows, decided from bridge events (window-free). M3 scope: volume and display brightness (expanded
// slider, 27.3 preferredPresentationVariant = expanded) and Focus (compact). RE: docs/RE-27-CENTERHUD.md section 6.3b.
import Foundation

enum LevelKind: Equatable { case volume, displayBrightness }

struct FocusActivity: Equatable {
    var identifier, name, symbol, colorName: String
}

enum IslandEvent: Equatable {
    case level(LevelKind, value: Double, fadeMs: Int)
    case focus(FocusActivity?)
    case power(level: Double, isCharging: Bool, lowPowerMode: Bool)   // IOPS / Low Power Mode update (Bootstrap)
    case lowBattery(level: Double)                                    // showLowBattery: (IOPS warning Early)
    case accessory(AccessoryInfo)
    case smartRouting(SmartRoutingInfo)
    case smartRoutingRemoved
}

enum Presentation: Equatable {
    case level(LevelKind, Double)
    case focus(FocusActivity, isOn: Bool)
    case battery(BatteryState)
    case accessory(AccessoryInfo)
    case smartRouting(SmartRoutingInfo)
}

private let chicletsSelector = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"

/// Bridge event -> island event. OSD image ids seen in ControlCenter 26.6 (M2 log): 1 display brightness, 4 volume at
/// 0 / muted, 5 and 23 volume. Anything else returns nil and stays with 26.6.
func parseOSD(_ event: String, _ args: [Any]) -> IslandEvent? {
    func num(_ i: Int) -> Double? { i < args.count ? (args[i] as? NSNumber)?.doubleValue : nil }
    if event == chicletsSelector, let image = num(0), let fade = num(3), let filled = num(4), let total = num(5), total > 0 {
        let kind: LevelKind
        switch Int(image) {
        case 1: kind = .displayBrightness
        case 4, 5, 23: kind = .volume
        default: return nil
        }
        return .level(kind, value: min(max(filled / total, 0), 1), fadeMs: Int(fade))
    }
    if event == "activeActivityDidChangeForManager:" {
        let s = args.map { $0 as? String }
        guard s.count == 4, let id = s[0], let name = s[1], let symbol = s[2], let color = s[3] else { return .focus(nil) }
        return .focus(FocusActivity(identifier: id, name: name, symbol: symbol, colorName: color))
    }
    // SystemBannerService (RE-27-BEHAVIOR s20). The *WithUserInfo: and showAccessoryWithType: forms stay with 26.6:
    // their name key / type numbering is not known yet [?].
    let text = { (i: Int) in i < args.count ? args[i] as? String : nil }
    switch event {
    case "showLowBattery:":
        return num(0).map { .lowBattery(level: $0) }
    case "showAccessory:text:", "showAccessory:text:batteryLevel:":
        guard let name = text(0) else { return nil }
        let level = num(2).flatMap(fraction)
        return .accessory(AccessoryInfo(kind: accessoryKind(name), name: name, message: text(1), batteryLevel: level,
                                        isLowBattery: level.map { $0 <= 0.2 } ?? false))   // ControlCenter 0x1004a53b8
    case "showSmartRoutingConnected:", "showSmartRoutingConnected:batteryLevel:":
        guard let name = text(0) else { return nil }
        return .smartRouting(SmartRoutingInfo(title: name, message: nil, batteryLevel: num(1).flatMap(fraction), needsAlerting: false))
    case "removeSmartRoutingForEvent:":
        return .smartRoutingRemoved
    default:
        return nil
    }
}

/// Battery level as 0...1; negative means unknown. [?] 26.6 scale not observed yet: values above 1 are read as percent.
private func fraction(_ v: Double) -> Double? { v < 0 ? nil : min(v > 1 ? v / 100 : v, 1) }

// ponytail: [I] the 26.6 call carries only a name; kind is guessed from it (27.3 gets userInfo "type").
private func accessoryKind(_ name: String) -> AccessoryKind {
    let n = name.lowercased()
    if n.contains("mouse") { return .mouse }
    if n.contains("trackpad") { return .trackpad }
    if n.contains("controller") { return .gameController }
    return .keyboard
}

struct IslandController {
    // MBSystemBannerAssertion.TimeoutMode (docs/RE-27-BEHAVIOR.md, island-re finding (e)): short 1, standard 4, long 20 s.
    static let levelDuration = 1.0             // volume/brightness: ControlCenter 27.3 passes custom(duration 1.0)
    static let focusDuration = 4.0             // Focus: standard
    static let bannerDuration = 4.0            // battery, accessory, SmartRouting: protocol default (nil -> standard)
    static let focusSuppression = 1.5          // [I] 26.6 posts the queued Focus banner ~0.25 s after the change
    static let idleAfterInteraction = 0.5      // pointer over the island holds it; released 0.5 s after it leaves
    // ponytail: [I] 27.3 starts the countdown when the presentation transition completes; here it starts at the event.

    private(set) var presentation: Presentation?
    private(set) var deadline: Double?
    private var hovering = false, dragging = false
    private var lastFocus: FocusActivity?
    private var power: (isCharging: Bool, lowPowerMode: Bool)?
    private var suppressUntil = -Double.infinity

    /// Returns true when the island takes the event (the 26.6 presentation must then be skipped).
    mutating func handle(_ e: IslandEvent, now: Double) -> Bool {
        switch e {
        case let .level(kind, value, fadeMs):
            if dragging, case .level(kind, _)? = presentation {
                // our own drag sets the value; the OSD echo must not make the slider jump
            } else {
                presentation = .level(kind, value)
            }
            _ = fadeMs   // 26.6 msecUntilFade is ignored: 27.3 uses its own timeout
            deadline = now + Self.levelDuration
            return true
        case let .focus(activity):
            // Off carries no activity: 27.3 shows the last one greyed with "Off" (RE-27-BEHAVIOR s18).
            guard let a = activity ?? lastFocus else { return false }
            lastFocus = a
            presentation = .focus(a, isOn: activity != nil)
            deadline = now + Self.focusDuration
            suppressUntil = now + Self.focusSuppression
            return true
        case let .power(level, isCharging, lpm):
            defer { power = (isCharging, lpm) }
            guard let old = power else { return false }   // first update: previous state unknown (RE s19.2)
            if isCharging && !old.isCharging {
                present(.battery(BatteryState(level: level, isCharging: true, isLowPowerMode: lpm, isWarning: false)), now)
            } else if case var .battery(b)? = presentation {
                if b.isCharging && !isCharging { presentation = nil; deadline = nil; return false }   // unplugged
                b.level = level
                if b.isLowPowerMode != lpm { b.isLowPowerMode = lpm; deadline = now + Self.bannerDuration }
                presentation = .battery(b)
            }
            return false
        case let .lowBattery(level):
            present(.battery(BatteryState(level: level, isCharging: false, isLowPowerMode: power?.lowPowerMode ?? false, isWarning: true)), now)
            return true
        case let .accessory(info):
            present(.accessory(info), now)
            return true
        case let .smartRouting(info):
            present(.smartRouting(info), now)
            return true
        case .smartRoutingRemoved:
            if case .smartRouting? = presentation { presentation = nil; deadline = nil }
            return false
        }
    }

    /// System banners (kind 2, 4, 6): standard timeout, and the 26.6 banner window for the same event is suppressed.
    private mutating func present(_ p: Presentation, _ now: Double) {
        presentation = p
        deadline = now + Self.bannerDuration
        suppressUntil = now + Self.focusSuppression
    }

    mutating func tick(now: Double) {
        guard !hovering, !dragging, let d = deadline, now >= d else { return }
        presentation = nil
        deadline = nil
    }

    mutating func setHovering(_ h: Bool, now: Double) {
        hovering = h
        if !h, presentation != nil { deadline = now + Self.idleAfterInteraction }
    }

    mutating func setDragging(_ d: Bool, now: Double) {
        dragging = d
        if !d, presentation != nil { deadline = now + Self.idleAfterInteraction }
    }

    mutating func dragged(to value: Double) {
        if case let .level(kind, _)? = presentation { presentation = .level(kind, min(max(value, 0), 1)) }
    }

    func suppressesBanner(now: Double) -> Bool { now < suppressUntil }
}
