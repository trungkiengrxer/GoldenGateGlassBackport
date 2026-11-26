// Window-free tests for the system activity views (island/Sources/SystemActivities.swift): screen recording
// (27.3 screencaptureui), Voice Memos (27.3 VoiceMemos.app platter views) and the camera / microphone AV module
// (27.3 ControlCenter AudioVideoLAMinimalView). Expected values come from docs/RE-27-BEHAVIOR.md section 22.
// Own executable (own @main) so it needs no hook in tests.swift.
import AppKit
import Foundation
import SwiftUI

private var failures = 0
private func ok(_ c: Bool, _ name: String) { print(c ? "OK   activities.\(name)" : "FAIL activities.\(name)"); if !c { failures += 1 } }
private func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) <= eps }

@main enum ActivitiesTests {
    static func main() {
        screenRecording()
        voiceMemos()
        avModule()
        privacyIndicator()
        metaball()
        MainActor.assumeIsolated { renders(); privacyDotLayer(); keepsContent() }
        exit(failures == 0 ? 0 : 1)
    }

    /// RecordingDot 11 x 11 Color.red in a 17 x 17 frame (0x10002c02c, 0x100028cbc); FlashingModifier opacity
    /// dimmed ? (intense ? 0.6 : 0.8) : 1, linear(intense ? 0.5 : 0.75).repeatForever(autoreverses: true) (0x10002c0c0).
    static func screenRecording() {
        typealias M = ScreenRecordingMetrics
        ok(M.dotSize == 11 && M.frameSize == 17, "recording.sizes")
        ok(M.flashOpacity(dimmed: false, intense: false) == 1 && M.flashOpacity(dimmed: true, intense: false) == 0.8
           && M.flashOpacity(dimmed: true, intense: true) == 0.6, "recording.flashOpacity")
        ok(M.flashDuration(intense: false) == 0.75 && M.flashDuration(intense: true) == 0.5, "recording.flashDuration")
        // ExpandedView (body 0x10002b0f4): containerSize = max(minimumSize, (260, 60)) (0x100027ea8, 0x100027edc); the
        // expanded HostedMetrics minimum is 0 and its margins 11 (RE-27-BEHAVIOR line 38).
        ok(M.expandedMinSize == CGSize(width: 260, height: 60) && M.layoutMargin == 11, "recording.expandedMin")
        // 0x10002a550: text top = max(obstruction + 1.5, container.h / 2 + 5.5), nil without an obstruction.
        ok(M.textTop(obstruction: 34) == 35.5 && M.textTop(obstruction: 50) == 51.5 && M.textTop(obstruction: 0) == nil, "recording.textTop")
        // 0x10002a5c0: height = max(container.h, textTop + capHeight + descent + margins.bottom).
        ok(M.expandedHeight(obstruction: 0, capHeight: 9, descent: 3) == 60 && M.expandedHeight(obstruction: 34, capHeight: 9, descent: 3) == 60
           && M.expandedHeight(obstruction: 50, capHeight: 9, descent: 3) == 74.5, "recording.expandedHeight")
        // Label padding .leading 15 + margins.leading (0x10002b4e4); StopButton 40 x 40 ring (0x10002cc30) centred in a
        // height x height frame at the trailing edge (0x10002b5a4).
        ok(M.labelLeading == 26, "recording.labelLeading")
        // RecordingDurationView (0x10002d664): HStack(.center, spacing: 5) { RecordingDot, stopwatch } with
        // FlashingModifier(intense: true) on the row.
        ok(M.durationSpacing == 5, "recording.durationSpacing")
        ok(M.stopButtonFrame(in: CGSize(width: 260, height: 60)) == CGRect(x: 210, y: 10, width: 40, height: 40), "recording.stopButtonFrame")
        ok(expandedType(height: 60, preference: .liveActivity) == .shortPill, "recording.expandedType")
    }

    /// RCRecorderStyleProvider, isIOSMac branch: 16 compact / 10 minimal slices, slice 1.2 wide, padding 1.0,
    /// width n * (w + p) (_platterWaveformWidthCompact: 0x10000eb14); minimal 35 x 15; compact height x 0.53.
    static func voiceMemos() {
        typealias M = VoiceMemosMetrics
        ok(M.compactSlices == 16 && M.minimalSlices == 10, "voice.sliceCounts")
        ok(near(Double(M.waveformWidth(slices: 16)), 35.2) && near(Double(M.waveformWidth(slices: 10)), 22), "voice.waveformWidth")
        ok(M.minimalSize == CGSize(width: 35, height: 15), "voice.minimalSize")
        ok(near(Double(M.compactWaveformHeight(sensorHeight: 34)), 18.02), "voice.compactHeight")
        // Slice height follows the level, never below the slice width (a dot when silent) [I].
        ok(M.sliceHeight(level: 0, maxHeight: 18) == M.sliceWidth && M.sliceHeight(level: 1, maxHeight: 18) == 18
           && M.sliceHeight(level: 2, maxHeight: 18) == 18, "voice.sliceHeight")
        ok(M.timeText(5) == "0:05" && M.timeText(65) == "1:05" && M.timeText(3725) == "1:02:05", "voice.timeText")
        voiceMemosExpanded()
    }

    /// VoiceMemos.ExpandedView (body 0x10013bf08): HStack { RCPlatterLeadingWaveformView, RCPlatterTimeView }
    /// .padding(.horizontal, platterCustomLeadingViewLeadingPadding) .frame(width: 0x10013c9a8, height: bannerSize.h).
    /// Mac: bannerSize 292 x 86, stop button 44 (0x10000e9cc), padding round((86 - 44) / 2) = 21 (0x10000ebbc).
    static func voiceMemosExpanded() {
        typealias M = VoiceMemosMetrics
        ok(M.expandedSize == CGSize(width: 292, height: 86) && M.expandedPadding == 21 && M.stopButtonSize == 44, "voice.expandedSizes")
        // Expanded style: slice width and padding x 2.3 (_sliceScale 0x100052dac), 16 active slices (makeUIView
        // 0x100102cb4). The representable's sizeThatFits (sub_100103240) takes the proposed width and 0.53 x the proposed
        // height, so the waveform and the flexible time view split the 250 pt content: (250 - 8) / 2 = 121, 45.58 high.
        ok(M.expandedWaveformWidth == 121 && near(Double(M.expandedWaveformHeight), 86 * 0.53), "voice.expandedWaveformFrame")
        // _activeSliceFrame (0x100051e44) = n * (w + p) = 80.96 from the leading edge (the playhead); numberOfInactiveSlices
        // (0x100052678) = floor((bounds.w - active.maxX) / (w + p)) = 7 grey dots after it.
        ok(near(Double(M.expandedActiveWidth), 80.96) && M.expandedInactiveSlices == 7, "voice.expandedPlayhead")
        // Slice height = min + level * (max - min), min = slice width (0x100052038, 0x1000529f0), max = view height.
        ok(near(Double(M.sliceHeight(level: 0, maxHeight: 86, scale: 2.3)), 2.76)
           && near(Double(M.sliceHeight(level: 0.5, maxHeight: 86, scale: 2.3)), 2.76 + 0.5 * (86 - 2.76)), "voice.expandedSliceHeight")
        // RCPlatterTimeView: stop button pinned to the trailing edge, centred vertically, 44 x 44 (0x1000916d8).
        ok(M.stopButtonFrame(in: M.expandedSize) == CGRect(x: 227, y: 21, width: 44, height: 44), "voice.stopButtonFrame")
        // PlatterStopButton.ca "zoom" state (same file on 26.6): Oval 239 x 0.246, line 16.6; stop 25.35 x 1.149,
        // radius 6.6; container scale 1/3. The 23 x 23 root layer is scaled to fit the 44 x 44 package view
        // (BSUICAPackageView layoutSubviews 0x1d7a03a24: min(bounds / package size); RCPlatterStopButton 0x100030d50).
        let k = 44.0 / 23
        ok(near(Double(M.stopRingDiameter), 19.598 * k) && near(Double(M.stopRingLine), 1.3612 * k)
           && near(Double(M.stopSquareSize), 9.708 * k) && near(Double(M.stopSquareRadius), 2.5278 * k), "voice.stopGlyph")
        ok(expandedType(height: M.expandedSize.height, preference: .liveActivity) == .pill, "voice.expandedType")
        // _maxHeightForSliceAtIndex (0x10005207c), active slices only: inside the leading / trailing rounded frames
        // (width max(5, active width x 0.3 / 2), 0x1000521f0) the max height is x sqrt(1 - (1 - d / r)^2).
        ok(M.edgeTaper(index: 0, slices: 16, scale: 2.3) == 0 && near(Double(M.edgeTaper(index: 1, slices: 16, scale: 2.3)), 0.81223)
           && M.edgeTaper(index: 8, slices: 16, scale: 2.3) == 1 && near(Double(M.edgeTaper(index: 15, slices: 16, scale: 2.3)), 0.58559),
           "voice.edgeTaper")
    }

    /// AudioVideoLAActivityIcon: camera video.fill green, mic mic.fill orange (0x10035c864, 0x10035c9d8, inits
    /// 0x1003b0ab0 / 0x1003b0b54 / 0x1003b0ae8 / 0x1003b0b88); the shown icon has opacity 1, the others 0 (0x1003a872c).
    static func avModule() {
        ok(AVActivityIcon.camera.symbol == "video.fill" && AVActivityIcon.mic.symbol == "mic.fill", "av.symbols")
        ok(AVActivityIcon.current(camera: true, mic: true) == .camera && AVActivityIcon.current(camera: false, mic: true) == .mic
           && AVActivityIcon.current(camera: false, mic: false) == nil, "av.current")
        ok(AVActivityIcon.opacity(of: .mic, current: .mic) == 1 && AVActivityIcon.opacity(of: .camera, current: .mic) == 0, "av.opacity")
        // A standalone AV module is PrimaryZoneLayout.minimal(detachedMinimal, edge: .trailing) (strb #1 at 0x1000d13ec,
        // content case 2 = avModule): the mirror of the leading minimal (tests.swift minimalOneSided, x 892.5 w 126).
        let g = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let t = g.minimal(width: 30, edge: .trailing)
        ok(t.shape.frame == CGRect(x: 901.5, y: 1039, width: 126, height: 34) && t.contentX == 1027.5 - 8 - 30, "av.minimalTrailing")
        ok(g.minimal(width: 30, edge: .leading).shape.frame == g.minimal(width: 30).shape.frame, "av.minimalDefaultLeading")
        split(g)
    }

    /// Two containers (mitosis). Primary = minimal with hasAdjunctZone: leading minimal drops its trailing extension
    /// (sub_1001fa96c `movi v3, #0` at 0x1001fabf8). Adjunct (sub_1001f7570): height = sensor, width =
    /// max(sensorH, aspect * sensorH - 2 * adjunctAspectWidthInset 8), radius h/2; placed interContainerPadding 8 past the
    /// primary. Hidden adjunct (sub_1001f79c4): size x initialScaleFactor 0.5, right edge 8 before the final left edge.
    static func split(_ g: IslandGeometry) {
        let p = g.minimal(width: 30, edge: .leading, hasAdjunct: true).shape
        ok(p.frame == CGRect(x: 892.5, y: 1039, width: 97, height: 34), "split.primaryNoTrailing \(p.frame)")
        let a = g.adjunct(after: p, content: CGSize(width: 17, height: 17))
        ok(a == IslandShape(frame: CGRect(x: 997.5, y: 1039, width: 34, height: 34), cornerRadius: 17), "split.adjunctCircle \(a)")
        ok(g.adjunct(after: p, content: CGSize(width: 60, height: 20)).frame.width == 86, "split.adjunctWide")
        let h = g.adjunctHidden(a)
        ok(h.frame == CGRect(x: 972.5, y: 1047.5, width: 17, height: 17) && h.cornerRadius == 8.5, "split.adjunctHidden \(h.frame)")
        // FOOTAGE-MAC-PROLED 5b: tapping the primary of a split, the expanded body covers the adjunct (NP 286.5 x 147, VM
        // 292 x 86, top edges equal), so it is swallowed in place; the split primary does not cover it.
        let body = IslandShape(frame: CGRect(x: 960 - 143.25, y: 1073 - 147, width: 286.5, height: 147), cornerRadius: 32)
        let vm = g.expanded(content: CGSize(width: 292, height: 86), type: nil, preference: .systemBanner).shape
        ok(body.covers(a) && vm.covers(a) && !p.covers(a), "split.covers \(vm.frame)")
        splitTimeline(g)
        // throughInert (CenterHUDPrimaryThroughInertZoneModelComponent): toInert, then fromInert once the collapse passes
        // settling.collisionProgress 0.9668 (0x100186b60). Progress = share of the width already collapsed.
        ok(Springs.collisionProgress == 0.9668, "through.collisionProgress")
        ok(near(collapseProgress(start: 134, current: 60, inert: 58), 74.0 / 76) && collapseProgress(start: 58, current: 58, inert: 58) == 1,
           "through.progress")
        ok(collapseProgress(start: 134, current: 61, inert: 58) < Springs.collisionProgress
           && collapseProgress(start: 134, current: 60, inert: 58) >= Springs.collisionProgress, "through.boundary")
    }

    /// Privacy indicator dot (RE-27-BEHAVIOR 22.11, 22.14). SkyLight 27.3 MediaLayer colours (0x182bfec0c-0x182bfee58)
    /// by menu bar appearance; density table sub_182c08990; position PKGPrivacyIndicatorWindowContainer; MenuBarAgent
    /// inert sub_1001fa708 and minimal sub_1001fa96c.
    /// Merge and split timelines against FOOTAGE-MAC-PROLED 5c (frame by frame, docs/footage-frames/merge-mac-*), 60 fps
    /// steps like IslandPanel.tick. Gap = adjunct minX - primary maxX; the metaball (blur 6.667, threshold 0.5) joins a
    /// gap under about 4 pt, so "contact" is gap <= 4 and "break" is gap >= 4.
    static func splitTimeline(_ g: IslandGeometry) {
        typealias Frame = (t: Double, p: IslandShape, a: IslandShape, apart: Bool)
        let r = Springs.transition.response, c = CGSize(width: 17, height: 17)
        let split = g.minimal(width: 30, edge: .leading, hasAdjunct: true).shape, final = g.adjunct(after: split, content: c)
        let body = g.expanded(content: CGSize(width: 286.5, height: 147), type: nil, preference: .systemBanner).shape
        func run(_ from: IslandShape, _ to: IslandShape, _ a: AdjunctMotion) -> [Frame] {
            var p = IslandAnimator(from), a = a, out: [Frame] = []
            p.setTarget(to)
            for i in 1...48 {
                let s = p.step(1.0 / 60)
                _ = a.step(1.0 / 60, primary: s, in: g)
                out.append((Double(i) / 60, s, a.shape(primary: s, in: g), a.isApart))
            }
            return out
        }
        func gap(_ f: Frame) -> CGFloat { f.a.frame.minX - f.p.frame.maxX }
        var steady = AdjunctMotion(dividing: nil, content: c, target: split, current: split, in: g, response: r)
        for _ in 0..<240 { _ = steady.step(1.0 / 60, primary: split, in: g) }
        ok(steady.shape(primary: split, in: g) == final && steady.anchor == .follows, "timeline.steady")

        // 5c.1 tap on the adjunct, leg 1 (throughInert to inert): the circle slides into the still primary and touches
        // within a frame or two at full size; the body shrinks to the neutral (inert) pill and the knob is absorbed; the
        // expansion leg starts about 0.20 s after contact (collisionProgress).
        var merging = steady
        merging.recombine(target: g.inert, current: split, in: g, response: r)
        let leg1 = run(split, g.inert, merging)
        let contact = leg1.first { gap($0) <= 4 }
        ok(contact.map { $0.t > 0.017 && $0.t <= 0.07 && $0.a.frame.width >= 0.85 * 34 && abs($0.p.frame.maxX - split.frame.maxX) <= 1 } == true,
           "timeline.tapAdjunctContact \(String(describing: contact.map { ($0.t, $0.a.frame.width) }))")
        let leg2At = leg1.first { collapseProgress(start: split.frame.width, current: $0.p.frame.width, inert: g.inert.frame.width) >= Springs.collisionProgress }
        ok(leg2At.map { $0.t >= 0.17 && $0.t <= 0.23 && $0.a.frame.maxX - $0.p.frame.maxX <= 6 } == true,
           "timeline.tapAdjunctNeutral \(String(describing: leg2At.map { ($0.t, $0.a.frame.maxX - $0.p.frame.maxX) }))")

        // Leg 2 (expanded + adjunct): the displaced activity buds from the centre of the right end and rides the growing body
        // out of its top-right corner, breaking off about 0.17 s after the expansion starts; final gap 8.
        let leg2 = run(g.inert, body, AdjunctMotion(dividing: nil, content: c, target: body, current: g.inert, in: g, response: r))
        let off = leg2.first { gap($0) >= 4 }
        let bud = leg2[0]
        // First frame (17 ms): flush with the right end at t = 0, out by 42 x reveal (about 1.4 pt) one frame later.
        ok(abs(bud.a.frame.midY - g.sensor.midY) <= 1 && bud.a.frame.maxX - bud.p.frame.maxX <= 2,
           "timeline.budCentreRightEnd midY \(bud.a.frame.midY - g.sensor.midY) past \(bud.a.frame.maxX - bud.p.frame.maxX)")
        ok(off.map { $0.t >= 0.12 && $0.t <= 0.21 && $0.a.frame.width >= 0.85 * 34 && abs($0.a.frame.maxY - $0.p.frame.maxY) <= 2 } == true,
           "timeline.pinchTopRight \(String(describing: off.map { ($0.t, $0.a.frame.width, $0.p.frame.maxY - $0.a.frame.maxY) }))")
        ok(abs(gap(leg2.last!) - 8) < 0.05, "timeline.expandedAdjunctGap \(gap(leg2.last!))")
        // The metaball stops once the circle is out (gap 8, past bridging): its blur would shrink both ends by about
        // sigma^2 / 2R = 1.3 pt each for the rest of the settle (ControlCenter 2026-11-23: gap 15, circle 28-30).
        let out = leg2.first { $0.apart }
        ok(out.map { gap($0) >= 7.9 && $0.t < 0.4 } == true && leg2.prefix { !$0.apart }.allSatisfy { gap($0) < 8 },
           "timeline.metaballOffWhenApart \(String(describing: out.map { ($0.t, gap($0)) }))")

        // 5c.2 split 1 -> 2, leg 2 from the neutral pill: knob to break about 0.13 s.
        let budding = run(g.inert, split, AdjunctMotion(dividing: nil, content: c, target: split, current: g.inert, in: g, response: r))
        let broke = budding.first { gap($0) >= 4 }
        ok(broke.map { $0.t >= 0.10 && $0.t <= 0.20 } == true, "timeline.splitBreak \(String(describing: broke?.t))")

        // 5c.3 tap on the primary, in place: the circle does not move; the growing body covers it.
        var swallowed = steady
        swallowed.recombine(target: body, current: split, in: g, response: r)
        let grow = run(split, body, swallowed)
        ok(grow.allSatisfy { $0.a == final } && !grow[0].p.covers(final) && grow.first { $0.t >= 0.25 }!.p.covers(final),
           "timeline.tapPrimarySwallow")
        // Collapse back: the circle is at full size at once, emerges from the shrinking body and breaks off about 0.2 s in.
        let emerging = AdjunctMotion(dividing: nil, content: c, target: split, current: body, in: g, response: r)
        let shrink = run(body, split, emerging)
        let apart = shrink.first { gap($0) >= 4 }
        ok(shrink[0].a == final && apart.map { $0.t >= 0.15 && $0.t <= 0.25 } == true, "timeline.collapseEmerge \(String(describing: apart?.t))")
        // Then it follows the primary's right end through the undershoot (5c.3 703.867-704.0: both move left 6 px, gap
        // 9-10 px) instead of waiting in place while the gap opens to 12.5 (ControlCenter 2026-11-23).
        let reached = shrink.firstIndex { gap($0) >= 7.99 }
        ok(reached.map { i in shrink[i...].allSatisfy { abs(gap($0) - 8) < 0.5 && $0.apart } } == true,
           "timeline.collapseDriftsWithPrimary \(shrink.map { gap($0) }.max() ?? 0)")

        // Contents go dark within about 50 ms of contact (5c.1) / 0.08 s (5c.2): merge fade spring.
        var fade = Tween(1)
        fade.set(0, response: Springs.mergeContentFade.response, damping: Springs.mergeContentFade.damping)
        for _ in 0..<6 { _ = fade.step(0.01) }
        ok(fade.value <= 0.06, "timeline.mergeContentFade \(fade.value)")
    }

    /// Mitosis background (CenterHUDMultiZoneMitosisBackgroundViewsComponent, sub_1001a85c8): gaussian blur
    /// mitosis.blurRadius 6.667 then alpha threshold 0.5 over the shared black fill. A primary capsule and the adjunct
    /// circle 4 pt apart join at mid height only (FOOTAGE-MAC-PROLED 5b neck); 12 pt apart they stay apart; a straight
    /// edge stays where it was.
    static func metaball() {
        ok(Metaball.blurRadius == 6.6667 && Metaball.threshold == 0.5, "split.metaballConstants")
        func alpha(gap: CGFloat, _ x: CGFloat, _ y: CGFloat) -> Double {
            let w = Int(10 + 50 + gap + 34 + 10)
            let ctx = CGContext(data: nil, width: w, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(.black)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 10, y: 13, width: 50, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
            ctx.addEllipse(in: CGRect(x: 60 + gap, y: 13, width: 34, height: 34))
            ctx.fillPath()
            var img = CIImage(cgImage: ctx.makeImage()!)
            for f in Metaball.filters(scale: 1) { f.setValue(img, forKey: kCIInputImageKey); img = f.outputImage! }
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(px[3]) / 255
        }
        ok(alpha(gap: 4, 62, 30) > 0.9, "split.metaballNeck \(alpha(gap: 4, 62, 30))")
        ok(alpha(gap: 4, 62, 15) < 0.1, "split.metaballNeckMidHeightOnly \(alpha(gap: 4, 62, 15))")
        ok(alpha(gap: 12, 66, 30) < 0.1, "split.metaballApart \(alpha(gap: 12, 66, 30))")
        ok(alpha(gap: 12, 30, 14) > 0.9 && alpha(gap: 12, 30, 11) < 0.1, "split.metaballEdgeKept")
    }

    static func privacyIndicator() {
        typealias K = PrivacyIndicatorKind
        typealias M = PrivacyIndicatorMetrics
        func rgb(_ k: K, _ dark: Bool) -> [Int] { let c = k.rgb(dark: dark); return [c.r, c.g, c.b] }
        ok(rgb(.camera, false) == [40, 205, 65] && rgb(.camera, true) == [50, 215, 75]
           && rgb(.microphone, false) == [255, 149, 0] && rgb(.microphone, true) == [255, 159, 10]
           && rgb(.screenRecording, false) == [84, 82, 204] && rgb(.screenRecording, true) == [99, 97, 241]
           && rgb(.systemAudio, false) == [175, 82, 222] && rgb(.systemAudio, true) == [191, 90, 242], "privacy.colors")
        ok(M.isSquare(.microphone, differentiateWithoutColor: true) && !M.isSquare(.microphone, differentiateWithoutColor: false)
           && !M.isSquare(.camera, differentiateWithoutColor: true), "privacy.square")
        // First entry whose density exceeds the key or lies within 0.1 of it, else the last; key = max of both axes.
        let d = [100, 110.05, 112, 116.4, 127, 128, 141.8, 150, 160, 180, 200, 250].map { M.diameter(pointsPerInch: $0) }
        ok(d == [5, 5, 5.5, 5.5, 6, 6, 7, 7, 8, 8.5, 10, 10], "privacy.diameter \(d)")
        ok(near(M.pointsPerInch(points: CGSize(width: 1920, height: 1080), millimeters: CGSize(width: 344, height: 194)), 1920 / (344 / 25.4)),
           "privacy.pointsPerInch")
        ok(M.centerOffset == 6 && M.padding == 6 && M.centerHUDRectExpansion == 4, "privacy.offsets")
        ok(K.shown(in: [.microphone, .camera]) == .camera && K.shown(in: [.systemAudio, .microphone]) == .microphone
           && K.shown(in: []) == nil, "privacy.priority")

        var g = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let idle = g.inert, avPlain = g.minimal(width: 30, edge: .trailing)
        g.privacyIndicatorDiameter = 7
        // Centre at the CenterHUD default rect's maxX + 6, midY; that rect is the sensor widened by 4 per side.
        ok(g.privacyIndicatorCenter == CGPoint(x: 999.5, y: 1056), "privacy.center \(String(describing: g.privacyIndicatorCenter))")
        // Inert: dynamic frame inset by -(outer edge 10 + 3.5 + pad max(8, 17 + 1 - 3.5) = 15) on both sides, radius h / 2.
        ok(g.inert == IslandShape(frame: CGRect(x: 902, y: 1039, width: 116, height: 34), cornerRadius: 17), "privacy.inert \(g.inert)")
        // Trailing minimal: + privacyIndicatorPadding 6 + outer edge 13.5 on the trailing side, then balanced (0.75).
        let av = g.minimal(width: 30, edge: .trailing)
        ok(av.shape.frame == CGRect(x: 887.5, y: 1039, width: 159.5, height: 34) && av.contentX == 1009, "privacy.minimalTrailing \(av)")
        // Leading minimal with an adjunct keeps the indicator's extension (0x1001fac04) instead of 0.
        ok(g.minimal(width: 30, edge: .leading, hasAdjunct: true).shape.frame == CGRect(x: 892.5, y: 1039, width: 125.5, height: 34),
           "privacy.splitPrimary \(g.minimal(width: 30, edge: .leading, hasAdjunct: true).shape.frame)")
        // Compact (sub_1001f87e4, 0x1001f8a1c-0x1001f8a74): the trailing side adds privacyIndicatorPadding 6 + outer edge
        // 13.5 = 19.5, then balances; trailing content stays at the outer edge + pad, 6 past the dot.
        let c = g.compact(leading: 40, trailing: 40)
        ok(c.shape.frame == CGRect(x: 879.5, y: 1039, width: 177.5, height: 34) && c.trailingX == 1009,
           "privacy.compact \(c.shape.frame) \(String(describing: c.trailingX))")
        ok(c.trailingX! - (g.privacyIndicatorCenter!.x + 3.5) == M.padding, "privacy.compactClearsDot")
        // No trailing view: the trailing side is the indicator alone (19.5 > 0.75 x 23 = 17).
        ok(g.compact(leading: 10, trailing: nil).shape.frame == CGRect(x: 907.5, y: 1039, width: 101.5, height: 34),
           "privacy.compactLeadingOnly \(g.compact(leading: 10, trailing: nil).shape.frame)")
        // FOOTAGE-MAC-PROLED 4 (2x, dot 6 pt): dot-only pill ~114 pt; camera pill grows ~47 pt right, 36-38 left, 141-145 wide.
        var f = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        f.privacyIndicatorDiameter = 6
        let cam = f.minimal(width: 20, edge: .trailing).shape.frame
        ok(f.inert.frame.width == 114 && cam.maxX - f.sensor.maxX == 47 && f.sensor.minX - cam.minX == 35.5 && cam.width == 141.5,
           "privacy.footage inert \(f.inert.frame.width) camera \(cam)")
        g.privacyIndicatorDiameter = 0
        ok(g.inert == idle && g.minimal(width: 30, edge: .trailing).shape == avPlain.shape && g.privacyIndicatorCenter == nil, "privacy.none")
        ok(M.appearDelay == 0.17 && M.appearDuration == 0.23 && M.exitHold == 0.22 && M.exitFade == 0.07, "privacy.timing")
        let api: (IslandPanel) -> (Set<PrivacyIndicatorKind>) -> Void = IslandPanel.setPrivacyIndicators
        _ = api
    }

    /// RE 22.25 (2): with the expanded primary steady (same content view) only the adjunct zone transitions, so the
    /// content keeps its container, alpha and scale; any other view (or count) runs the content choreography.
    @MainActor static func keepsContent() {
        let v = NSView(), w = NSView(), x = NSView()
        ok(keepsPresentedContent([v], shown: [v]) && keepsPresentedContent([v, x], shown: [v, x]), "content.sameViewKept")
        ok(!keepsPresentedContent([w], shown: [v]) && !keepsPresentedContent([v], shown: [v, x]) && !keepsPresentedContent([], shown: [])
           && !keepsPresentedContent([v], shown: []), "content.otherViewCrossfades")
    }

    @MainActor static func privacyDotLayer() {
        let l = CALayer()
        PrivacyIndicatorMetrics.style(l, kind: .microphone, diameter: 7, dark: true, differentiateWithoutColor: false)
        let c = l.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        ok(l.bounds.size == CGSize(width: 7, height: 7) && l.cornerRadius == 3.5
           && c.map { near($0.redComponent, 1) && near($0.greenComponent, 159.0 / 255) && near($0.blueComponent, 10.0 / 255) } ?? false,
           "privacy.layer")
        PrivacyIndicatorMetrics.style(l, kind: .microphone, diameter: 7, dark: true, differentiateWithoutColor: true)
        ok(l.cornerRadius == 0, "privacy.layerSquare")
    }

    @MainActor static func renders() {
        func image<V: View>(_ v: V, scale: CGFloat = 1) -> CGImage? {
            let r = ImageRenderer(content: v)
            r.scale = scale
            return r.cgImage
        }
        func pixel(_ i: CGImage?, _ x: Double, _ y: Double) -> (Double, Double, Double, Double)? {
            guard let i, let c = NSBitmapImageRep(cgImage: i).colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        }
        func size(_ i: CGImage?) -> String { i.map { "\($0.width)x\($0.height)" } ?? "nil" }

        let dot = image(ScreenRecordingDot(animates: false), scale: 4)
        ok(size(dot) == "68x68", "render.dotFrame (\(size(dot)))")
        let centre = pixel(dot, 34, 34), corner = pixel(dot, 2, 2)
        ok(centre.map { $0.0 > 0.9 && $0.1 < 0.4 && $0.3 > 0.9 } ?? false, "render.dotRed \(String(describing: centre))")
        ok(corner.map { $0.3 < 0.05 } ?? false, "render.dotClearOutside \(String(describing: corner))")

        let minimal = image(VoiceMemosMinimal(levels: Array(repeating: 1, count: 10)), scale: 4)
        ok(size(minimal) == "140x60", "render.voiceMinimal (\(size(minimal)))")
        let slice = pixel(minimal, (6.5 + 5) * 4, 30)   // third slice: the first two sit in the tapered edge
        ok(slice.map { $0.0 > 0.9 && $0.1 < 0.5 && $0.3 > 0.9 } ?? false, "render.voiceSliceRed \(String(describing: slice))")

        let av = image(AVModuleMinimal(current: .mic).background(Color.black), scale: 4)
        let hasOrange = av.map { img -> Bool in
            for y in stride(from: 0, to: img.height, by: 2) { for x in stride(from: 0, to: img.width, by: 2) {
                if let p = pixel(img, Double(x), Double(y)), p.0 > 0.9, p.1 > 0.45, p.1 < 0.75, p.2 < 0.2 { return true }
            } }
            return false
        } ?? false
        ok(hasOrange, "render.avMicOrange")

        // Voice Memos expanded: 292 x 86; red stop square at the button centre, white ring 18.75 from it.
        let vm = image(VoiceMemosExpanded(levels: Array(repeating: 1, count: 16), seconds: 65).background(Color.black), scale: 2)
        ok(size(vm) == "584x172", "render.voiceExpanded (\(size(vm)))")
        let stop = pixel(vm, 249 * 2, 43 * 2), ring = pixel(vm, 249 * 2, (43 - 18.75) * 2)
        ok(stop.map { $0.0 > 0.9 && $0.1 < 0.5 } ?? false, "render.voiceStopRed \(String(describing: stop))")
        ok(ring.map { $0.0 > 0.8 && $0.1 > 0.8 && $0.2 > 0.8 } ?? false, "render.voiceStopRing \(String(describing: ring))")
        let bar = pixel(vm, (21 + 4 * 5.06 + 1.38) * 2, 43 * 2)   // fifth slice (past the taper), level 1
        ok(bar.map { $0.0 > 0.9 && $0.1 < 0.5 } ?? false, "render.voiceExpandedSlice \(String(describing: bar))")
        // Level 1 reaches the 45.58 waveform height, centred: red 20 above the middle, black 25 above it.
        let barX: Double = (21 + 4 * 5.06 + 1.38) * 2
        let top = pixel(vm, barX, 23 * 2), above = pixel(vm, barX, 18 * 2)
        let topRed = top.map { $0.0 > 0.9 && $0.1 < 0.5 } ?? false, aboveBlack = above.map { $0.0 < 0.1 } ?? false
        ok(topRed && aboveBlack, "render.voiceExpandedHeight \(String(describing: top)) \(String(describing: above))")
        // First grey dot after the playhead at x = 21 + 80.96 (+ half a slice).
        let waiting = pixel(vm, (21 + 80.96 + 1.38) * 2, 43 * 2)
        let grey = waiting.map { $0.0 > 0.15 && $0.0 < 0.5 && abs($0.0 - $0.1) < 0.05 } ?? false
        ok(grey, "render.voiceExpandedInactive \(String(describing: waiting))")

        // Screen recording expanded: 260 x 60 with a 34 pt obstruction; red square in the ring centre, white ring.
        let sr = image(ScreenRecordingExpanded(startDate: Date(), obstructionHeight: 34).background(Color.black), scale: 2)
        ok(size(sr) == "520x120", "render.recordingExpanded (\(size(sr)))")
        let sq = pixel(sr, 230 * 2, 30 * 2), rim = pixel(sr, 230 * 2, 10 * 2)   // ring stroke centred on y = 10
        ok(sq.map { $0.0 > 0.9 && $0.1 < 0.4 } ?? false, "render.recordingStopRed \(String(describing: sq))")
        ok(rim.map { $0.0 > 0.8 && $0.1 > 0.8 && $0.2 > 0.8 } ?? false, "render.recordingStopRing \(String(describing: rim))")
        // Red 11 pt dot leading the duration line: centre x = 26 + 5.5, centred on the text (baseline at h / 2 = 30).
        // The renderer may capture the flash at opacity 0.6, so only the hue is checked.
        let dotHit = sr.map { img -> Bool in
            for y in stride(from: 20.0, through: 30, by: 0.5) {
                if let p = pixel(img, 31.5 * 2, y * 2), p.0 > 0.5, p.1 < 0.25, p.2 < 0.25 { return true }
            }
            return false
        } ?? false
        ok(dotHit, "render.recordingDurationDot")
        // Label cap top at textTop = 35.5: white ink in rows 36...44 under the first letters, none in rows 0...15.
        func whiteInk(_ rows: StrideThrough<Double>) -> Bool {
            sr.map { img in rows.contains { y in stride(from: 26.0, through: 60, by: 0.5).contains { x in
                pixel(img, x * 2, y * 2).map { $0.0 > 0.8 && $0.1 > 0.8 && $0.2 > 0.8 } ?? false
            } } } ?? false
        }
        ok(whiteInk(stride(from: 36, through: 44, by: 0.5)) && !whiteInk(stride(from: 0, through: 15, by: 0.5)), "render.recordingLabelTop")
    }
}
