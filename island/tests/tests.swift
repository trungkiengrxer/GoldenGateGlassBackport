// Window-free tests for island/Sources (geometry, corner curve, path, animator) and GGSpring.
// Expected values are computed by hand from docs/RE-27-CENTERHUD.md section 4 (27.3 26C5047e).
import CoreGraphics
import Foundation

var failures = 0
func expect(_ c: Bool, _ name: String) { print(c ? "OK   \(name)" : "FAIL \(name)"); if !c { failures += 1 } }
func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) <= eps }

@main enum Tests {
    static func main() {
        geometry()
        corner()
        animator()
        controller()
        content()
        interaction()
        NowPlayingTests.run()
        // Read-only: tests never change the volume or brightness.
        let v = SystemControls.volume(), b = SystemControls.brightness(display: CGMainDisplayID())
        expect(v.map { (0...1).contains($0) } ?? true, "volumeReadable (\(v.map { String($0) } ?? "nil"))")
        expect(b.map { (0...1).contains($0) } ?? true, "brightnessReadable (\(b.map { String($0) } ?? "nil"))")
        exit(failures == 0 ? 0 : 1)
    }

    static func geometry() {
        let g = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        expect(g.sensor == CGRect(x: 930.5, y: 1039, width: 59, height: 34), "sensorOnMainScreen")
        let o = IslandGeometry(screen: CGRect(x: 1920, y: 0, width: 1440, height: 900), scale: 2)
        expect(o.sensor == CGRect(x: 1920 + 690.5, y: 859, width: 59, height: 34), "sensorOnOffsetScreen")

        // w 26, pad max(8, 17 + 1 - 13) = 8, extension 34 on both sides.
        expect(g.compact(leading: 26, trailing: 26).shape
               == IslandShape(frame: CGRect(x: 896.5, y: 1039, width: 127, height: 34), cornerRadius: 17), "compactSymmetric")
        // extL 34, extR 68, both edges > 46 -> extL = max(34, round(0.75 * 68)) = 51.
        expect(g.compact(leading: 26, trailing: 60).shape.frame == CGRect(x: 879.5, y: 1039, width: 178, height: 34),
               "compactRelaxedSymmetry")
        // Content at the OUTER edge + concentric padding (sub_1001f87e4, 0x1001f8e4c-0x1001f8e70): leading x = minX + pad,
        // trailing x = maxX - pad - w; the 17 pt balancing slack on the leading side lies on the sensor side.
        let edge = g.compact(leading: 26, trailing: 60)
        expect(edge.leadingX == 879.5 + 8 && edge.trailingX == 1057.5 - 8 - 60, "compactContentAtOuterEdge")
        // sideMax = floor((0.5 * 1920 - 59) / 2) = 450 -> extension 458.
        expect(g.compact(leading: 500, trailing: 26).leadingX == 930.5 - 458 + 8, "compactClampSide")
        // 200 pt screen: extL 23 (w 10, pad 13), extR 28 (w clamped to 20, pad 8); edgeR 42.5 <= 46 -> both 28.
        let n = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 200, height: 400), scale: 1)
        expect(n.compact(leading: 10, trailing: 60).shape.frame == CGRect(x: 42.5, y: 359, width: 115, height: 34),
               "compactNearEdgeFullSymmetry")
        // Scale 2: pad = 17 + 0.5 - 5 = 12.5 survives pixel rounding.
        expect(o.compact(leading: 10, trailing: 10).shape.frame.width == 59 + 2 * 22.5, "compactScale2")

        // [I] minimal = one-sided extension then symmetry: extL 38, extR round(0.75 * 38) = 29.
        expect(g.minimal(width: 30).shape.frame == CGRect(x: 892.5, y: 1039, width: 126, height: 34), "minimalOneSided")
        expect(g.minimal(width: 80).shape.frame.width == 59 + 53 + 40, "minimalClamp45")

        expect(expandedType(height: 73, preference: .automatic) == .shortPill, "band73")
        expect(expandedType(height: 73.5, preference: .automatic) == .pill, "band73.5")
        expect(expandedType(height: 92, preference: .automatic) == .standard, "band92")
        expect(expandedType(height: 92, preference: .defaultPill) == .pill, "defaultNeverStandard")
        expect(expandedType(height: 50, preference: .defaultPill) == .shortPill, "defaultShort")
        expect(expandedType(height: nil, preference: .automatic) == .pill, "nilIsPill")
        expect(expandedType(height: 10, preference: .standard) == .standard, "prefStandard")

        // Expanded: centered on the sensor, top = sensor top (1073) - yOffset.
        expect(g.expanded(content: CGSize(width: 250, height: 84), type: nil, preference: .defaultPill)
               == (IslandShape(frame: CGRect(x: 835, y: 989, width: 250, height: 84), cornerRadius: 42), .pill), "expandedPill")
        expect(g.expanded(content: nil, type: nil, preference: .defaultPill).shape.frame.size == CGSize(width: 250, height: 84),
               "expandedDefaultSize")
        expect(g.expanded(content: CGSize(width: 0, height: 0), type: nil, preference: .defaultPill)
               == (IslandShape(frame: CGRect(x: 835, y: 989, width: 250, height: 84), cornerRadius: 42), .pill), "expandedZeroSize")
        expect(g.expanded(content: CGSize(width: 100, height: 100), type: .square, preference: .defaultPill).shape
               == IslandShape(frame: CGRect(x: 888, y: 924, width: 144, height: 145), cornerRadius: 39), "expandedSquare")
        expect(g.expanded(content: CGSize(width: 300, height: 10), type: .oval, preference: .defaultPill).shape
               == IslandShape(frame: CGRect(x: 810, y: 853, width: 300, height: 216), cornerRadius: 90), "expandedOval")
        expect(g.expanded(content: CGSize(width: 100, height: 300), type: .tallRect, preference: .defaultPill).shape
               == IslandShape(frame: CGRect(x: 877, y: 767, width: 166, height: 300), cornerRadius: 71), "expandedTallRect")
        expect(g.expanded(content: CGSize(width: 10, height: 10), type: .squareLarge, preference: .defaultPill).shape.frame.size
               == CGSize(width: 408, height: 423), "expandedSquareLarge")   // max width 408 (sub_1001f704c, island-re)
        // layout.emptySensorRegionHeight = physical: the empty island is the physical frame, sub_100202d48 of the dynamic one
        // (x + t, top 1 pt lower, w - 2t, h - 1; t = 0.6 = table[layout.cornerCurve ID1]), then rounded outwards to pixels
        // (sub_1002e32f4): 931.1..988.9 -> 931..989 at 1x, i.e. 58 x 33, bottom unchanged; radius min(32, h / 2).
        let fine = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 10).physicalSensor
        expect(g.physicalSensor == CGRect(x: 931, y: 1039, width: 58, height: 33)
               && g.inert == IslandShape(frame: g.physicalSensor, cornerRadius: 16.5)
               && near(fine.minX, 931.1) && near(fine.width, 57.8), "inertIsPhysicalSensor")
        // defaultMaximumCornerRadius on an emulated display: 32 (CenterHUDDisplayMetrics builder, emulate branch 0x100202a54).
        expect(g.expanded(content: CGSize(width: 234, height: 143), type: nil, preference: .standard).shape.cornerRadius == 32,
               "standardRadiusEmulated")
        // AirDrop is a Live Activity (ElementRegistryClientSceneSettings has no shape field): preferredContainerShape nil
        // = automatic, so a card taller than 91 is standard with radius min(h / 2, 32) (RE-27-BEHAVIOR s21.2).
        expect(g.expanded(content: CGSize(width: 274, height: 100), type: nil, preference: .liveActivity)
               == (IslandShape(frame: CGRect(x: 823, y: 973, width: 274, height: 100), cornerRadius: 32), .standard),
               "airDropShapeAutomatic")
        expect(shadow(for: .pill).opacity == 0.4 && shadow(for: .pill).offsetY == 5 && shadow(for: nil).opacity == 0.25,
               "shadowTable")
    }

    static func corner() {
        let r = 20.0, ext = 1.528665 * r
        expect(cornerInset(ext, radius: r) == 0 && cornerInset(ext + 5, radius: r) == 0, "insetZeroBeyondExtent")
        expect(near(cornerInset(0, radius: r), 1.2 * r, 0.01 * r), "insetAtCorner")   // E * (1 + B / A) = 1.2 r
        expect(stride(from: 0.0, to: ext, by: 0.25).allSatisfy { cornerInset($0, radius: r) >= cornerInset($0 + 0.25, radius: r) },
               "insetMonotonic")
        expect(stride(from: 0.0, to: 1.2 * r, by: 0.5).allSatisfy { near(cornerInset(cornerInset($0, radius: r), radius: r), $0, 0.01 * r) },
               "insetSymmetric")

        let pill = IslandShape(frame: CGRect(x: 0, y: 0, width: 127, height: 34), cornerRadius: 17)
        let p = islandPath(pill)
        expect(pill.frame.insetBy(dx: -0.01, dy: -0.01).contains(p.boundingBoxOfPath)
               && p.contains(CGPoint(x: 63.5, y: 17)) && p.contains(CGPoint(x: 1, y: 17)) && !p.contains(CGPoint(x: 0.5, y: 0.5)),
               "pillPathInsideFrame")
        // Apple's PROLED image (AirDrop island) fits a circular corner (error 0.24) far better than the case 3 profile
        // (2.32): the outline is circular. Just outside / inside the corner circle on the diagonal:
        expect(!p.contains(CGPoint(x: 17 - 17 * 0.7071 - 0.4, y: 17 + 17 * 0.7071 + 0.4))
               && p.contains(CGPoint(x: 17 - 17 * 0.7071 + 0.4, y: 17 + 17 * 0.7071 - 0.4)), "outlineCircular")
        let wide = IslandShape(frame: CGRect(x: 0, y: 0, width: 250, height: 84), cornerRadius: 42)
        expect(near(p.boundingBoxOfPath.width, 127, 0.01) && near(islandPath(wide).boundingBoxOfPath.width, 250, 0.01),
               "pillPathTouchesEdges")
        // QuartzCore 27.3 +[CALayer cornerCurveExpansionFactor:]: 1.528665 for continuous, 1.0 for ID0/ID1 (case 3):
        // the corner ends at r along each edge, so tallRect (166 wide, r 71.333) keeps a flat top in the middle.
        let tall = IslandShape(frame: CGRect(x: 0, y: 0, width: 166, height: 300), cornerRadius: 71.333)
        let t = islandPath(tall)
        expect(t.contains(CGPoint(x: 72.5, y: 299.9)) && t.contains(CGPoint(x: 93.5, y: 299.9))
               && !t.contains(CGPoint(x: 35, y: 299.5)), "cornerExtentEqualsRadius")
        let sq = IslandShape(frame: CGRect(x: 10, y: 20, width: 144, height: 145), cornerRadius: 39)
        let q = islandPath(sq)
        expect(near(q.boundingBoxOfPath.width, 144, 0.01) && near(q.boundingBoxOfPath.height, 145, 0.01)
               && !q.contains(CGPoint(x: 12, y: 22)) && q.contains(CGPoint(x: 82, y: 92)), "squarePathBounds")
    }

    static func controller() {
        // OSD args as logged in ControlCenter 26.6 (M2): image, displayID, priority, msecUntilFade, filled, total, locked.
        let vol: [Any] = [5, 1141190272, 500, 4000, 625, 10000, 0]
        expect(parseOSD("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:", vol)
               == .level(.volume, value: 0.0625, fadeMs: 4000), "parseVolume")
        expect(parseOSD("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:", [1, 1, 500, 1000, 8125, 10000, 0])
               == .level(.displayBrightness, value: 0.8125, fadeMs: 1000), "parseBrightness")
        expect(parseOSD("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:", [9, 1, 500, 1000, 0, 10000, 0]) == nil,
               "unknownImageForwarded")
        let gaming = FocusActivity(identifier: "com.apple.focus.gaming", name: "Gaming", symbol: "rocket.fill", colorName: "systemBlueColor")
        expect(parseOSD("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"]) == .focus(gaming),
               "parseFocusOn")
        expect(parseOSD("activeActivityDidChangeForManager:", [NSNull()]) == .focus(nil), "parseFocusOff")

        var c = IslandController()
        expect(c.handle(.level(.volume, value: 0.5, fadeMs: 4000), now: 10), "levelConsumed")
        // 27.3: ControlCenter shows volume/brightness with timeoutMode custom(1.0) whatever the 26.6 msecUntilFade says.
        expect(c.deadline.map { abs($0 - 11) < 1e-9 } == true, "levelTimeoutCustom1s")
        _ = c.handle(.level(.volume, value: 0.5, fadeMs: 1000), now: 10.1)
        expect(c.presentation == .level(.volume, 0.5) && c.deadline.map { abs($0 - 11.1) < 1e-9 } == true, "pairedCallsCoalesce")
        c.tick(now: 11.0); let stillOpen = c.presentation != nil
        c.tick(now: 11.2)
        expect(stillOpen && c.presentation == nil, "closesAtDeadline")

        var h = IslandController()
        _ = h.handle(.level(.displayBrightness, value: 0.3, fadeMs: 1000), now: 0)
        h.setHovering(true, now: 0.5); h.tick(now: 5)
        let openWhileHover = h.presentation != nil
        h.setHovering(false, now: 5)
        expect(openWhileHover && h.deadline.map { abs($0 - 5.5) < 1e-9 } == true, "hoverKeepsOpen")   // release 0.5 s after the pointer leaves

        var dr = IslandController()
        _ = dr.handle(.level(.volume, value: 0.2, fadeMs: 1000), now: 0)
        dr.setDragging(true, now: 0.1); dr.dragged(to: 0.7)
        _ = dr.handle(.level(.volume, value: 0.5, fadeMs: 1000), now: 0.2)
        expect(dr.presentation == .level(.volume, 0.7), "ownChangeIgnoredWhileDragging")

        var f = IslandController()
        expect(f.handle(.focus(gaming), now: 0) && f.presentation == .focus(gaming, isOn: true) && f.deadline == 4, "focusShowsCompact")   // timeoutMode standard = 4 s
        expect(f.suppressesBanner(now: 1.0) && !f.suppressesBanner(now: 2.0), "suppressWindow")
        f.tick(now: 5)
        // RE-27-BEHAVIOR s18: Focus off shows the same compact with the last activity, grey, "Off", standard 4 s.
        expect(f.handle(.focus(nil), now: 10) && f.presentation == .focus(gaming, isOn: false) && f.deadline == 14
               && f.suppressesBanner(now: 11), "focusOffShowsLastActivityOff")
        var off = IslandController()
        expect(!off.handle(.focus(nil), now: 0) && off.presentation == nil && !off.suppressesBanner(now: 0.5), "focusOffUnknownShowsNothing")

        // RE-27-BEHAVIOR s19.2: charging banner on plug-in only (first update skipped), level updates while shown,
        // unplug removes it, a Low Power Mode change re-shows it; kind 6, standard 4 s.
        func bat(_ l: Double, _ charging: Bool, _ lpm: Bool, warning: Bool = false) -> Presentation {
            .battery(BatteryState(level: l, isCharging: charging, isLowPowerMode: lpm, isWarning: warning))
        }
        var q = IslandController()
        _ = q.handle(.power(level: 0.5, isCharging: true, lowPowerMode: false), now: 0)
        expect(q.presentation == nil, "powerFirstUpdateSilent")
        var p = IslandController()
        _ = p.handle(.power(level: 0.5, isCharging: false, lowPowerMode: false), now: 0)
        _ = p.handle(.power(level: 0.5, isCharging: true, lowPowerMode: false), now: 1)
        expect(p.presentation == bat(0.5, true, false) && p.deadline == 5, "plugInShowsCharging")
        _ = p.handle(.power(level: 0.51, isCharging: true, lowPowerMode: false), now: 2)
        expect(p.presentation == bat(0.51, true, false) && p.deadline == 5, "chargingLevelUpdates")
        _ = p.handle(.power(level: 0.51, isCharging: true, lowPowerMode: true), now: 3)
        expect(p.presentation == bat(0.51, true, true) && p.deadline == 7, "lowPowerModeReshowsCharging")
        _ = p.handle(.power(level: 0.51, isCharging: false, lowPowerMode: true), now: 3.5)
        expect(p.presentation == nil, "unplugRemovesCharging")
        // s19.2 (0x1000c9b70, 0x100571454): "charging" for the banner = internal battery Power Source State "AC Power",
        // not Is Charging, so plugging in at 100% "charged" still shows it.
        expect(PowerSource.isOnACPower(["Power Source State": "AC Power", "Is Charging": false])
               && !PowerSource.isOnACPower(["Power Source State": "Battery Power", "Is Charging": true]), "chargingMeansACPower")
        // s19.2: IOPS warning Early -> ControlCenter calls showLowBattery: -> expanded warning with the current LPM.
        var w = IslandController()
        _ = w.handle(.power(level: 0.1, isCharging: false, lowPowerMode: true), now: 0)
        expect(w.handle(.lowBattery(level: 0.1), now: 1) && w.presentation == bat(0.1, false, true, warning: true)
               && w.deadline == 5 && w.suppressesBanner(now: 1.5), "lowBatteryShowsWarning")
        _ = w.handle(.power(level: 0.1, isCharging: false, lowPowerMode: false), now: 2)
        expect(w.presentation == bat(0.1, false, false, warning: true) && w.deadline == 6, "warningFollowsLowPowerMode")

        // s20: SystemBannerService accessory / SmartRouting calls (26.6 argument shapes: name string, text, level).
        let mouse = AccessoryInfo(kind: .mouse, name: "Magic Mouse", message: "Connected", batteryLevel: 0.15, isLowBattery: true)
        expect(parseOSD("showAccessory:text:batteryLevel:", ["Magic Mouse", "Connected", 0.15]) == .accessory(mouse), "parseAccessory")
        expect(parseOSD("showAccessory:text:", ["Magic Keyboard", NSNull()])
               == .accessory(AccessoryInfo(kind: .keyboard, name: "Magic Keyboard", message: nil, batteryLevel: nil, isLowBattery: false)),
               "parseAccessoryNoBattery")
        let pods = SmartRoutingInfo(title: "AirPods Pro", message: nil, batteryLevel: 0.8, needsAlerting: false)
        expect(parseOSD("showSmartRoutingConnected:batteryLevel:", ["AirPods Pro", 0.8]) == .smartRouting(pods), "parseSmartRouting")
        expect(parseOSD("removeSmartRoutingForEvent:", [0]) == .smartRoutingRemoved, "parseSmartRoutingRemove")
        expect(parseOSD("showLowBattery:", [0.08]) == .lowBattery(level: 0.08), "parseLowBattery")
        var a = IslandController()
        expect(a.handle(.accessory(mouse), now: 0) && a.presentation == .accessory(mouse) && a.deadline == 4
               && a.suppressesBanner(now: 1), "accessoryShowsCompact")
        var s = IslandController()
        expect(s.handle(.smartRouting(pods), now: 0) && s.presentation == .smartRouting(pods) && s.deadline == 4, "smartRoutingShowsCompact")
        _ = s.handle(.smartRoutingRemoved, now: 1)
        expect(s.presentation == nil, "smartRoutingRemoved")

        // AirDrop receive (RE s21): combined fraction by bytes; the 27.3 count is transfer SESSIONS (0x10000cb9c), not
        // files, and the files of one session cannot be told apart on 26.6, so concurrent files count as one session.
        expect(airDropProgress([]) == nil, "airDropIdle")
        expect(airDropProgress([(completed: 50, total: 100), (completed: 0, total: 300)])
               == AirDropProgress(fraction: 0.125, itemCount: 1, isFinished: false), "airDropCombinedOneSession")
        // Real 26.6 AirDrop receive (probe 2026-11-23): at publish the proxy's fileOperationKind / fileURL are nil and
        // only userInfo carries them; a browser download is .downloading.
        let photo = URL(fileURLWithPath: "/Users/x/Downloads/sunset.PNG")
        expect(AirDropMonitor.receivedFile([.fileOperationKindKey: Progress.FileOperationKind.receiving.rawValue, .fileURLKey: photo]) == photo
               && AirDropMonitor.receivedFile([.fileOperationKindKey: Progress.FileOperationKind.downloading.rawValue, .fileURLKey: photo]) == nil,
               "airDropReceiveFromUserInfo")
        // ReadyForOpen text (RE s21.2.2, AirDropUI loctable): "Received %@" / "From %@", sender default "Unknown".
        let en = airDropReadyText(fileName: "Photo.heic", sender: nil, language: "en")
        expect(en.title == "Received “Photo.heic”" && en.subtitle == "From Unknown", "airDropReadyTextEn")
        let vi = airDropReadyText(fileName: "Ảnh.heic", sender: "Lan", language: "vi-VN")
        expect(vi.title == "Đã nhận “Ảnh.heic”" && vi.subtitle == "Từ Lan", "airDropReadyTextVi")
        expect(airDropProgress([(completed: 0, total: 0)]) == AirDropProgress(fraction: 0, itemCount: 1, isFinished: false),
               "airDropUnknownTotal")
        // Last item unpublished: finished (ReadyForOpen) unless it was cancelled (ring button or sender), then gone.
        expect(airDropEnd(cancelled: false) == AirDropProgress(fraction: 1, itemCount: 1, isFinished: true)
               && airDropEnd(cancelled: true) == nil, "airDropCancelledEndsWithoutReady")
        // 26.6 STMediaStatusDomain attributions (bundle ids) -> system activity shown in the island (RE s22).
        expect(mediaActivity(camera: [], mic: [], screen: []) == nil, "mediaIdle")
        expect(mediaActivity(camera: [], mic: ["com.apple.VoiceMemos"], screen: []) == .voiceMemos, "mediaVoiceMemos")
        expect(mediaActivity(camera: [], mic: ["us.zoom.xos"], screen: []) == .av(.mic), "mediaMic")
        expect(mediaActivity(camera: ["us.zoom.xos"], mic: ["us.zoom.xos"], screen: []) == .av(.camera), "mediaCameraWinsOverMic")
        expect(mediaActivity(camera: [], mic: ["com.apple.VoiceMemos"], screen: ["com.apple.screencaptureui"]) == .screenRecording,
               "mediaScreenRecordingFirst")
        expect(mediaActivity(camera: [], mic: [], screen: ["com.example.Sharer"]) == nil, "mediaOtherScreenCaptureIgnored")
        // All activities at once, in priority order; camera + mic of a call is one AV module (camera icon).
        expect(mediaActivities(camera: ["us.zoom.xos"], mic: ["us.zoom.xos"], screen: ["com.apple.screencaptureui"])
               == [.screenRecording, .av(.camera)], "mediaActivitiesScreenAndCall")
        expect(mediaActivities(camera: [], mic: ["com.apple.VoiceMemos", "us.zoom.xos"], screen: []) == [.voiceMemos, .av(.mic)],
               "mediaActivitiesVoiceMemosAndMic")
        expect(mediaActivities(camera: [], mic: ["com.apple.VoiceMemos"], screen: []) == [.voiceMemos], "mediaActivitiesVoiceMemosOnly")
        // Privacy indicator kinds (WindowServer dot, RE 22.11): any attributed app counts, not only screencaptureui.
        expect(privacyKinds(camera: [], mic: [], screen: [], systemAudio: []).isEmpty, "privacyNone")
        expect(privacyKinds(camera: ["us.zoom.xos"], mic: ["com.apple.VoiceMemos"], screen: ["com.example.Sharer"], systemAudio: ["x"])
               == [.camera, .microphone, .screenRecording, .systemAudio], "privacyAllKinds")
        // Split (mitosis, RE 22.8): the first two elements, both needing a minimal view; otherwise one element.
        expect(splitPair([1, 2, 3], hasMinimal: { _ in true }).map { [$0.0, $0.1] } == [1, 2], "splitFirstTwo")
        expect(splitPair([1, 2], hasMinimal: { $0 != 2 }) == nil && splitPair([1], hasMinimal: { _ in true }) == nil,
               "splitNeedsTwoMinimals")
        // Voice Memos levels from GGApp (ggapp/Sources/VoiceMemosPack.h): seq high 32 bits, newest level lowest byte.
        let first = voiceMemosLevels(state: 0x00000007FF800033, lastSeq: nil, levels: [])
        expect(first.seq == 7 && first.levels.map { ($0 * 255).rounded() } == [255, 128, 0, 51], "vmLevelsFirstTakesFour")
        let next = voiceMemosLevels(state: 0x0000000800000011, lastSeq: 7, levels: [0.5])
        expect(next.seq == 8 && next.levels.count == 2 && (next.levels[1] * 255).rounded() == 17, "vmLevelsAppendsNewOnly")
        let gap = voiceMemosLevels(state: 0x0000000F00000000, lastSeq: 8, levels: [])
        expect(gap.levels == [0, 0, 0, 0, 0, 0, 0], "vmLevelsFillsLostSlices")
        let same = voiceMemosLevels(state: 0x0000000800000011, lastSeq: 8, levels: [0.1])
        expect(same.levels == [0.1], "vmLevelsIgnoresRepeat")
        let reset = voiceMemosLevels(state: 0x00000001000000FF, lastSeq: 40, levels: [0.3, 0.3])
        expect(reset.seq == 1 && reset.levels.count == 2 && reset.levels.last == 1, "vmLevelsNewRecordingResets")
        let many = (0..<5).reduce((seq: UInt32?(nil), levels: [Double]())) { acc, i in
            let r = voiceMemosLevels(state: UInt64(10 + 4 * i) << 32, lastSeq: acc.seq, levels: acc.levels)
            return (r.seq, r.levels)
        }
        expect(many.levels.count == 16, "vmLevelsKeepsSixteen")
        // Click on a split container (RE 22.20): that element becomes the primary expanded, adjunct included; the AV
        // module has no expanded view yet.
        expect(splitExpansionTarget(onAdjunct: true, primary: .nowPlaying, adjunct: .media(.voiceMemos)) == .media(.voiceMemos),
               "splitTapAdjunctExpandsAdjunct")
        expect(splitExpansionTarget(onAdjunct: false, primary: .nowPlaying, adjunct: .media(.voiceMemos)) == .nowPlaying,
               "splitTapPrimaryExpandsPrimary")
        expect(splitExpansionTarget(onAdjunct: true, primary: .nowPlaying, adjunct: .media(.av(.camera))) == nil, "splitTapAVIgnored")
        // RE 22.25 (3): beside an expanded body only consequential elements and the AV module stay as the adjunct.
        expect(adjunctBesideExpanded(.airDrop), "adjunctBesideExpandedAirDrop")
        expect(adjunctBesideExpanded(.media(.screenRecording)), "adjunctBesideExpandedScreenRecording")
        expect(adjunctBesideExpanded(.media(.av(.camera))), "adjunctBesideExpandedAV")
        expect(!adjunctBesideExpanded(.media(.voiceMemos)), "adjunctBesideExpandedNotVoiceMemos")
        expect(!adjunctBesideExpanded(.nowPlaying), "adjunctBesideExpandedNotNowPlaying")
        // RE 22.25: whichever way the body was expanded, the first other element that qualifies sits beside it
        // (hidden -> visible = mitosis when it arrives later), the rest stay hidden.
        expect(adjunctBesideExpanded(expanded: .nowPlaying, elements: [.airDrop, .nowPlaying]) == .airDrop, "expandedAdjunctArrivingAirDrop")
        expect(adjunctBesideExpanded(expanded: .nowPlaying, elements: [.media(.voiceMemos), .nowPlaying]) == nil, "expandedAdjunctNoneForOrdinary")
        expect(adjunctBesideExpanded(expanded: .media(.voiceMemos), elements: [.media(.voiceMemos), .media(.av(.camera)), .nowPlaying])
               == .media(.av(.camera)), "expandedAdjunctSkipsNowPlaying")
        expect(adjunctBesideExpanded(expanded: .airDrop, elements: [.airDrop]) == nil, "expandedAdjunctNotItself")
        // The user-expanded element outranks the split while it is still present.
        expect(userExpandedElement(airDrop: false, airDropExpanded: false, media: [.screenRecording, .voiceMemos],
                                   mediaExpanded: .voiceMemos, nowPlayingExpanded: false) == .media(.voiceMemos),
               "userExpandedPicksClickedMedia")
        expect(userExpandedElement(airDrop: false, airDropExpanded: false, media: [], mediaExpanded: .voiceMemos,
                                   nowPlayingExpanded: false) == nil, "userExpandedGoneWithActivity")
        expect(userExpandedElement(airDrop: true, airDropExpanded: false, media: [.voiceMemos], mediaExpanded: nil,
                                   nowPlayingExpanded: true) == .nowPlaying, "userExpandedNowPlaying")
        expect(userExpandedElement(airDrop: false, airDropExpanded: true, media: [], mediaExpanded: nil,
                                   nowPlayingExpanded: false) == nil, "userExpandedAirDropGone")
    }

    static func content() {
        // ExpandedSlider: 309 wide (321 inflated), track row padded 64 / 31, row height 4 (18 inflated). RE 6.3b.
        let t = SliderMetrics.trackFrame(inflated: false), ti = SliderMetrics.trackFrame(inflated: true)
        // The drawn track is always 4 pt (TickedSliderTrack frame(height: 4) twice, RE-27-BEHAVIOR s16); the 18 pt row
        // when inflated is the SwiftUI.Slider frame only.
        expect(t.minX == 64 && t.width == 214 && t.height == 4 && ti.minX == 64 && ti.width == 226 && ti.height == 4, "sliderTrackFrame")
        expect(SliderMetrics.value(atX: 10, inflated: false) == 0 && SliderMetrics.value(atX: 400, inflated: false) == 1
               && abs(SliderMetrics.value(atX: 64 + 107, inflated: false) - 0.5) < 1e-9, "sliderValueClamps")
        expect(FocusMetrics.textWidth(String(repeating: "Very long focus name ", count: 5)) == 120
               && FocusMetrics.textWidth("Gaming") > 20 && FocusMetrics.textWidth("Gaming") < 120, "focusTextWidthCapped")
        // ExpandedComposition = JindoTripleVStack(notchSize: centerHUDSize) (island-re): bottom region = track row
        // (4 | 18) + max(0, 41 - 34) right below the notch; the bottom region is taken symmetric about the notch [I], so
        // the island is 34 + row + 34 = 79 | 93 pt and the track sits at mid height: the PROLED footage (309 x ~79 pt,
        // icon and track on one centred row). Bottom-left origin for the track.
        expect(SliderMetrics.size(inflated: false) == CGSize(width: 309, height: 79)
               && SliderMetrics.size(inflated: true) == CGSize(width: 321, height: 93), "sliderIslandSize")
        expect(t.minY == 37.5 && ti.minY == 44.5 && t.midY == 39.5 && ti.midY == 46.5, "sliderTrackMidHeight")
        // Leading region: SliderBannerImageView + padding 16 / 9, vertically centred on the whole island (top-left origin).
        expect(SliderMetrics.iconBox(inflated: false) == CGRect(x: 16, y: 0, width: 39, height: 79), "sliderIconLeadingRegion")
        // tickProgress = (showTicks && \.isEnabled) ? 1 : 0 with showTicks = !isInflated (0x2b1ae5668, island-re).
        expect(SliderMetrics.tickProgress(inflated: false) == 1 && SliderMetrics.tickProgress(inflated: true) == 0, "ticksOnThinTrack")
        // SystemBannerUI Focus values (symbol 18 + padding 8, text + padding 10, callout semibold) at scale 1: the user chose
        // the PROLED look (hardware case, obstruction == reference) over the emulate ReferenceScaledLayout 34 / 41.
        // Trailing text is the localized state, not the Focus name: FOCUS_MODE_ON / FOCUS_MODE_OFF (0x2b1ac05c4).
        expect(FocusMetrics.leadingWidth == 26
               && FocusMetrics.trailingWidth(isOn: true) == FocusMetrics.textWidth(FocusMetrics.stateText(isOn: true)) + 10
               && FocusMetrics.font.pointSize == 12, "focusBannerScale1")   // macOS .callout
        expect(FocusMetrics.stateText(isOn: true, language: "en") == "On" && FocusMetrics.stateText(isOn: false, language: "en-US") == "Off"
               && FocusMetrics.stateText(isOn: true, language: "vi-VN") == "Bật" && FocusMetrics.stateText(isOn: false, language: "vi") == "Tắt",
               "focusStateText")
        // Off: icon and text #636366 (Color(0.38824, 0.38824, 0.4) @0x2e1f4cb00); on: the activity colour.
        expect(FocusMetrics.offGrey == (0.38824, 0.38824, 0.4), "focusOffGrey")
        // TickedTrackMask (0x2b1aeba74): rect i at x = width * i / count, width = tickWidth * tickProgress, full height.
        let ticks = SliderMetrics.tickRects(width: 160, height: 18, progress: 0.5)
        expect(ticks.count == 15 && ticks[0] == CGRect(x: 10, y: 0, width: 0.5, height: 18) && ticks[14].minX == 150
               && SliderMetrics.tickRects(width: 160, height: 18, progress: 0).isEmpty, "tickRects")
        // Fill UnevenRoundedRectangle (0x2b1aeb3ec): leading radii 2, trailing radii 2 only when the value is 1.
        expect(SliderMetrics.fillTrailingRadius(value: 1) == 2 && SliderMetrics.fillTrailingRadius(value: 0.5) == 0, "fillTrailingRadius")
        // Discrete symbols (volume 0x2b1ad124c, brightness 0x2b1acf7bc, island-re RE-27-BEHAVIOR s15).
        expect(SliderMetrics.symbol(.volume, 0) == "speaker.slash.fill" && SliderMetrics.symbol(.volume, 0.2) == "speaker.wave.1.fill"
               && SliderMetrics.symbol(.volume, 0.5) == "speaker.wave.2.fill" && SliderMetrics.symbol(.volume, 0.7) == "speaker.wave.3.fill"
               && SliderMetrics.symbol(.displayBrightness, 0.3) == "sun.min.fill" && SliderMetrics.symbol(.displayBrightness, 0.4) == "sun.max.fill",
               "sliderSymbol")
        // .symbolEffect(.bounce, value: seed): the seed advances only when the value changes onto exactly 0 or 1 (0x2b1ab7448).
        expect(SliderMetrics.bouncesAtEnd(from: 0.9375, to: 1) && SliderMetrics.bouncesAtEnd(from: 0.0625, to: 0)
               && !SliderMetrics.bouncesAtEnd(from: 1, to: 1) && !SliderMetrics.bouncesAtEnd(from: 0.5, to: 0.5625), "bounceAtEnds")
    }

    static func interaction() {
        let g = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        // centerHUD.interaction: inertHoverScale 1.15 / inertHoverLean (2.75, 2), compactHoverScale 1.05 / compactHoverLean (2, 1).
        expect(hoverMetrics(.inert) == HoverMetrics(scale: 1.15, lean: CGPoint(x: 2.75, y: 2))
               && hoverMetrics(.compact) == HoverMetrics(scale: 1.05, lean: CGPoint(x: 2, y: 1))
               && hoverMetrics(.expanded(.shortPill)) == HoverMetrics(scale: 1, lean: .zero), "hoverMetricsTable")
        let f = g.inert.frame, m = CGPoint(x: 2.75, y: 2)
        expect(lean(pointer: CGPoint(x: f.maxX + 50, y: f.midY), in: f, maximum: m) == CGPoint(x: 2.75, y: 0)
               && lean(pointer: CGPoint(x: f.midX - f.width / 4, y: f.minY), in: f, maximum: m) == CGPoint(x: -1.375, y: -2),
               "leanTowardPointer")
        let h = hovered(g.inert, scale: 1.15, offset: CGPoint(x: 1, y: -1))
        expect(near(h.frame.width, 58 * 1.15) && near(h.frame.height, 33 * 1.15) && near(h.frame.midX, f.midX + 1)
               && near(h.frame.midY, f.midY - 1) && near(h.cornerRadius, 16.5 * 1.15), "hoverScalesAboutCenter")
        expect(hovered(g.inert, scale: 1, offset: .zero) == g.inert, "hoverIdentity")
        // Incoming content starts at min(w_old / w_new, h_old / h_new) (sub_10011c0c8, island-re), uniform, no clamp;
        // a ratio with a non-positive denominator counts as 1.
        expect(near(Double(contentEntryScale(from: CGSize(width: 58, height: 33), to: CGSize(width: 172, height: 34))), 58.0 / 172)
               && near(Double(contentEntryScale(from: CGSize(width: 309, height: 45), to: CGSize(width: 58, height: 33))), 45.0 / 33)
               && contentEntryScale(from: CGSize(width: 50, height: 10), to: .zero) == 1, "contentEntryScale")
        // keyLine (MenuBarAgentSettings.KeyLine): darkBackgroundOpacity 0.35; gone in inert (disappearToInertSpring).
        // Tint forced to fixedLstar 50 (sub_10033dc54): defaultTintColor 0.916 grey -> sRGB 0.466; plusL at 0.35 over a dark
        // backdrop == white at alpha 0.466 * 0.35 composited normally (island-re, RE-27-BEHAVIOR s5).
        // Drawn as Apple's kit: lighten of #262626 over a backdrop copy (visible 1, inert 0); still the 27.3 dark result on black.
        expect(keyLineOpacity(.inert) == 0 && keyLineOpacity(.compact) == 1 && keyLineOpacity(.expanded(.pill)) == 1
               && near(KeyLine.tintLstar50, 0.4663, 0.0005) && KeyLine.lightenGray == 0.149, "keyLineOpacity")
        // centerHUD.shadow has entries only for expanded types; compact/minimal have none (island-re, Apple kit: key line only).
        expect(Zone.inert.shadow.opacity == 0 && Zone.expanded(.pill).shadow.opacity == 0.4 && Zone.compact.shadow.opacity == 0
               && Zone.minimal.shadow.opacity == 0, "zoneShadow")
        // User choice: the idle pill is hidden unless GGIsland.showWhenIdle is set; any activity shows the island.
        // It first collapses to the idle pill as 27.3 toInert, and hides only once the shape has settled there.
        expect(idleHidden(.inert, showWhenIdle: false, settled: true) && !idleHidden(.inert, showWhenIdle: false, settled: false)
               && !idleHidden(.inert, showWhenIdle: true, settled: true) && !idleHidden(.compact, showWhenIdle: false, settled: true)
               && !idleHidden(.expanded(.pill), showWhenIdle: false, settled: true), "idleHiddenAfterCollapse")
        // 27.3 never hides the island (RE-27-CENTERHUD s9); the hide follows the iPhone Duo footage: the solid pill shrinks
        // to a point, width faster than height, gone after ~0.4 s. Showing is unchanged: the full pill at once, then 27.3 fromInert.
        let h0 = IdleHide.factors(0, hiding: true), hMid = IdleHide.factors(0.115, hiding: true)
        let hEnd = IdleHide.factors(IdleHide.duration, hiding: true)
        let s0 = IdleHide.factors(0, hiding: false), sEnd = IdleHide.factors(IdleHide.duration, hiding: false)
        expect(h0 == (1, 1) && near(hMid.w, 0.37, 0.03) && near(hMid.h, 0.46, 0.03) && hEnd == (0, 0)
               && s0 == (1, 1) && sEnd == (1, 1), "idleHideDuoFootage")
        let prefs = UserDefaults(suiteName: "gg-island-tests-\(getpid())")!
        expect(!showsIdlePill(prefs), "idlePillHiddenByDefault")
        prefs.set(true, forKey: "GGIsland.showWhenIdle")
        expect(showsIdlePill(prefs), "idlePillShownByFlag")
        prefs.removePersistentDomain(forName: "gg-island-tests-\(getpid())")
    }

    static func animator() {
        let g = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let compact = g.compact(leading: 26, trailing: 26).shape
        var a = IslandAnimator(g.inert)
        a.setTarget(compact)
        for _ in 0..<180 { _ = a.step(1.0 / 60) }
        expect(a.isSettled && a.current == compact, "animatorSettles")

        var b = IslandAnimator(g.inert)
        b.setTarget(g.expanded(content: nil, type: nil, preference: .defaultPill).shape)
        for _ in 0..<6 { _ = b.step(1.0 / 60) }
        let before = b.current
        b.setTarget(g.inert)
        let after = b.step(1.0 / 60)
        expect(abs(after.frame.width - before.frame.width) < 15 && !b.isSettled, "animatorRetargetIsContinuous")

        // transitionPolicy.momentaryArrivalResponseScale 0.6: a momentary element (HUD) arrives faster.
        let target = g.expanded(content: CGSize(width: 309, height: 34), type: nil, preference: .defaultPill).shape
        var slow = IslandAnimator(g.inert), fast = IslandAnimator(g.inert)
        slow.setTarget(target)
        fast.setTarget(target, response: Springs.transition.response * Springs.momentaryArrivalResponseScale, damping: Springs.transition.damping)
        for _ in 0..<6 { _ = slow.step(1.0 / 60); _ = fast.step(1.0 / 60) }
        expect(Springs.momentaryArrivalResponseScale == 0.6 && fast.current.frame.width > slow.current.frame.width, "momentaryArrivalFaster")

        // FluidSpring stepped frame by frame with centerHUD.transitions.spring (dampingRatio 0.75, response 0.3843)
        // against the closed form of RE section 7: x = 1 - e^(-beta t) (cos(wd t) + beta / wd sin(wd t)).
        let w0 = 2 * Double.pi / 0.3843, beta = 0.75 * w0, wd = w0 * (1 - 0.75 * 0.75).squareRoot()
        var s = FluidSpring(value: 0, velocity: 0), worst = 0.0
        for i in 1...60 {
            s.step(to: 1, response: 0.3843, damping: 0.75, dt: 1.0 / 60)
            let t = Double(i) / 60
            worst = max(worst, abs(s.value - (1 - exp(-beta * t) * (cos(wd * t) + beta / wd * sin(wd * t)))))
        }
        expect(worst < 1e-9, "springMatchesAnalytic (max error \(worst))")
        // Critically damped (keyLine springs use dampingRatio 1.0): x = 1 - e^(-w0 t)(1 + w0 t).
        var c = FluidSpring(value: 0, velocity: 0)
        for _ in 0..<30 { c.step(to: 1, response: 1.2, damping: 1, dt: 1.0 / 60) }
        let w1 = 2 * Double.pi / 1.2
        expect(near(c.value, 1 - exp(-w1 * 0.5) * (1 + w1 * 0.5), 1e-9), "springCritical")
        // Overdamped stays monotonic and below the target.
        var o = FluidSpring(value: 0, velocity: 0), mono = true, prev = 0.0
        for _ in 0..<120 { o.step(to: 1, response: 0.5, damping: 1.5, dt: 1.0 / 60); mono = mono && o.value >= prev && o.value <= 1; prev = o.value }
        expect(mono && o.value > 0.9, "springOverdamped")
    }
}
