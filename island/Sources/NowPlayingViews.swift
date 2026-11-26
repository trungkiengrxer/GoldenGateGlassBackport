// Now Playing island content with the 27.3 NowPlayingUI / MediaCoreUI metrics (docs/RE-27-NOWPLAYING.md; addresses are
// in dyld-extract/NowPlayingUI and dyld-extract/MediaCoreUI of 26C5047e). [I] = inferred, [?] = placeholder.
import AppKit
import SwiftUI

enum NowPlayingMetrics {
    // Compact leading: NowPlayingLeadingActivitySurface.body 0x2a166ac4c (values for a non-zero obstruction).
    static let compactArtwork: CGFloat = 20, compactArtworkPadding: CGFloat = 4, compactArtworkRadius: CGFloat = 5
    static let placeholderFontSize: CGFloat = 10
    static let artworkShadow = (opacity: 0.6, radius: CGFloat(3), y: CGFloat(1))
    // Compact trailing: Waveform(size: .compact) = WaveformSize.custom(16) + padding(.all, 4) (0x2a167a8c8, 0x2a1654c94).
    static let compactWaveform: CGFloat = 16, compactWaveformPadding: CGFloat = 4
    static let waveformMaxFPS = 30.0                                     // WaveformFramerateSettings.custom(5...30, 24)
    static let waveformBackdropBlur: CGFloat = 6                         // ArtworkBackdropView blur 0x2268c29dc (0x4018...)

    // FlippingArtworkView (compact and expanded artwork). A new artwork image flips the face 180 degrees around y; the
    // image swaps just before edge-on, then appears blurred with a white glow that fades out. Same artwork, no flip
    // (27.3 footage 776.65 / 777.35 / 780.0 s: three track changes on one album, the artwork never turns).
    static let flipAnimation = Animation.interpolatingSpring(mass: 1.25, stiffness: 300, damping: 25, initialVelocity: 0)
        .speed(0.5)                                                      // 0x2a1613d80, Transaction at 0x2a161315c
    static let flipSwapLead = 0.05                                       // AnimatableFlipRotation.swapLead (body 0x2a16119e0)
    static let flipPerspective: CGFloat = 0.1                            // rotation3DEffect axis (0, 1, 0) 0x2a160de78
    static let revealBlur = 15.0                                         // blur set on reveal, then animated to 0
    static let glowIntensity = 0.3                                       // ArtworkGlowModifier intensity, .plusLighter
    static let revealAnimation = Animation.easeOut(duration: 0.15)       // blur 15 -> 0, glow on -> off (0x2a1613e28)
    static let placeholderFade = Animation.easeInOut(duration: 0.25)     // no image: fade to placeholder (0x2a1613e04)
    static let flipBackwardTimeout = 3.0                                 // [?] FlipDirectionTracker.timeout (Duration not read)
    // ArtworkLegibilityModifier 0x2a160ec84: backdrop colorMatrix, grey 0.402 at alpha 0.198 - luminance (lifts dark
    // artwork off the black island).
    static let legibilityMatrix: _ColorMatrix = {
        var m = _ColorMatrix()
        (m.m11, m.m22, m.m33, m.m44) = (0, 0, 0, 0.198)
        (m.m15, m.m25, m.m35) = (0.402, 0.402, 0.402)
        (m.m41, m.m42, m.m43) = (-0.213, -0.715, -0.072)
        return m
    }()

    /// Angle shown by AnimatableFlipRotation: flipAngle minus whole half turns (rounded away from zero, frinta).
    static func flipDisplayAngle(_ angle: Double) -> Double { angle - (angle / 180).rounded() * 180 }

    /// Face whose image must swap in at this animated angle, nil before swapLead x 180 degrees ahead of the midpoint.
    static func flipSwapFace(angle: Double, target: Double, lastFace: Int) -> Int? {
        let face = Int((target / 180).rounded())
        guard face != lastFace else { return nil }
        let mid = Double(lastFace + face) * 0.5 * 180, lead = flipSwapLead * 180
        return (face > lastFace ? angle >= mid - lead : angle <= mid + lead) ? face : nil
    }

    /// Faces turned per flip: forward -180 degrees, backward (after "previous") +180 (fcsel at 0x2a1613468).
    static func flipStep(backward: Bool) -> Int { backward ? 1 : -1 }

    // Expanded: NowPlayingActivitySurface.body 0x2a1673ce4 and NowPlayingActivitySessionView (solo layout).
    static let expandedWidth: CGFloat = 286                              // frame(width: 286) [V], DynamicEnabler 286
    // Margins 16 on all sides: NowPlayingActivityContext default margins 16 (0x2a167ee28) [V]; footage drlYGnbWurM
    // 775.9 s artwork at 15.9 from the left/top, waveform frame ending 16.3 from the right, controls 16.3 above the
    // bottom; Apple's PROLED image 15.5 / 14.6. (11 = hostedSceneMetrics.expanded.layoutMargin is not what reaches it.)
    static let margin: CGFloat = 16
    // Artwork 50 on screen: drlYGnbWurM 775.9 s 50.3 (laid out at 16...66, the title starts 10 after it), paused 778.5 s
    // 40 = 0.8 x 50 about the same centre (41, 41); XWXKHTb6o3w 703.47 s 50.7; Apple's image 50.7. [?] The solo frame
    // literal is 55 (first / multiple 42, radius 12 / 7) at 0x2a166e378; what turns it into 50 is not read.
    static let artwork: CGFloat = 50, artworkRadius: CGFloat = 12
    static let appIcon: CGFloat = 16, appIconOffset: CGFloat = 2         // 0x2a166f074 (16, 16), (2, 2) [I placement]
    /// AppIcon(AppIconViewModel(appBundleIdentifier:)) overlays the artwork, but no footage of Apple Music shows it
    /// (drlYGnbWurM, XWXKHTb6o3w, Apple's image). [?] The condition is not read: hidden for Music only.
    static func showsAppIcon(bundleID: String?) -> Bool { bundleID != nil && bundleID != "com.apple.Music" }
    static let metadataPadding: CGFloat = 10                             // padding(.horizontal, 10)
    /// Title / artist line pitch: 15.8 in drlYGnbWurM, 15.4 in Apple's image, i.e. the 13 pt font's own line height
    /// (ascender - descender, no leading). SwiftUI on macOS 26 makes the line 18 with the glyphs at its top, so each line
    /// gets a top-aligned frame of this height (baseline 13 below the line top, footage 13.05).
    static let metadataLine: CGFloat = {
        // The text-style font reports 18 (its line height); the plain system font of that size has no extra leading.
        let f = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize)
        return ceil(f.ascender - f.descender)
    }()
    static let pausedArtworkScale: CGFloat = 0.8, pausedArtworkOpacity = 0.5   // ArtworkProminence (0.8, 0.5) 0x2a160d334
    static let prominenceScaleAnimation = Animation.interpolatingSpring(mass: 1.25, stiffness: 300, damping: 25, initialVelocity: 0)
    static let waveform: CGFloat = 22, waveformFrame = CGSize(width: 25, height: 50)   // WaveformSize regular; frame 25 x 50
    static let timelineTop: CGFloat = 12, controlsTop: CGFloat = 15     // padding(.top, 12) / (.top, 15) 0x2a166c524 [I order]
    /// Timeline row = its caption2 medium labels (TimelineControlTimeLabelLockScreenStyleView; CapsuleProgress is only
    /// 10). SwiftUI on macOS 26 lays the 10 pt line out 15 tall; the footage fits 13 (drlYGnbWurM 775.9 s: track centre
    /// 84, arrows 113...129, bottom 151.8 with margins 16 and artwork 50), the same missing leading as the metadata lines.
    static let timelineRow: CGFloat = 13
    // Timeline: the session view takes CapsuleProgressStyle preset 0x2a15f81e8 (swift_once at 0x2a166d9c0): height 10,
    // filled Color.secondary, filled while dragging .primary, unfilled .quaternary, rubberBandMode .nowPlayingActivity,
    // interactionScale 1 (no inflation). Track clipped to a Capsule, filled part is a plain rect (CapsuleProgress.Body).
    static let capsuleHeight: CGFloat = 10
    static let timelineSpacing: CGFloat = 8                              // [?] HStack spacing nil (system default)
    // RubberBandMode.nowPlayingActivity = RubberBandConfiguration (0x2a160bd58, picked at 0x2a160a1c8).
    static let rubberMaxOvershoot = 0.04, rubberResistance = 2.0, rubberVerticalCompression = 0.2
    static let snapBack = Animation.spring(response: 0.4, dampingFraction: 0.8)
    // TimelineControlStyle.InteractionAnimation onBegin / onEnd (0x2a162ebb4 preset, 0x2a166c524).
    static let scrubBegin = Animation.spring(Spring(mass: 1, stiffness: 288, damping: 26.5))
    static let scrubEnd = Animation.spring(Spring(mass: 2, stiffness: 500, damping: 40))
    static let timelineHitSlop: CGFloat = 6                              // [?] DraggableViewModifier contentShape inset
    /// TimelineProgressInterpolatingView.Body = TimelineView(.animation(minimumInterval: nil, paused:)) (0x2a163d084):
    /// the progress follows every frame. [?] The paused condition reads UserInteractionState; here: idle while paused.
    static func timelinePaused(isPlaying: Bool, scrubbing: Bool) -> Bool { !isPlaying && !scrubbing }

    // MetadataMarquee: NowPlayingUI MarqueeConfiguration 0x2a161c0d4 (spacing 10, rate 30 pt/s, delay 1.5 s, feathering
    // 6 / 6, frame rate 30-60). MediaCoreUI Marquee 0x2268b058c: CAKeyframeAnimation "transform.translation.x" values
    // [0, a, D - a, D], keyTimes [0, r / T, (T - r) / T, 1], timing functions quadratic ease-in (1/3, 0, 2/3, 1/3), linear,
    // ease-out (1/3, 1/3, 2/3, 1), r = 0.5 s (T / 2 when T < 1), duration T = D / rate; wrapped in a CAAnimationGroup of
    // duration T + delay (or the CoordinatedMarquees maximum), beginTime now + delay, repeatCount infinity.
    static let marqueeSpacing: CGFloat = 10, marqueeRate = 30.0, marqueeDelay = 1.5, marqueeFeather: CGFloat = 6
    static let marqueeRamp = 0.5
    static let marqueeMaxFPS = 60.0

    /// Loop length of one marquee (its group duration); coordinated lines all use the longest one.
    static func marqueeCycle(distance d: Double) -> Double { d / marqueeRate + marqueeDelay }

    /// Translation (negative = to the left) `t` seconds after the content appeared; `d` = content width + spacing.
    static func marqueeOffset(_ t: Double, distance d: Double, period: Double) -> Double {
        let travel = d / marqueeRate
        guard t >= marqueeDelay, d > 0 else { return 0 }
        // Group duration = max(own, coordinated maximum) (0x2268b058c compares with animationDurationMax).
        let tau = (t - marqueeDelay).truncatingRemainder(dividingBy: max(period, marqueeCycle(distance: d)))
        guard tau < travel else { return 0 }   // the copy now sits where the original was
        let r = travel >= 2 * marqueeRamp ? marqueeRamp : travel / 2
        let v = d / (travel - r), a = 0.5 * r * v
        let x = tau < r ? a * (tau / r) * (tau / r)
            : tau < travel - r ? a + v * (tau - r)
            : d - a * ((travel - tau) / r) * ((travel - tau) / r)
        return -x
    }
    static let controlFont: CGFloat = 24, centerControlFont: CGFloat = 30, controlSpacing: CGFloat = 45   // (24, 30) (18, 45)
    /// Controls row = the hidden Image of the 30 pt center glyph (TransportControl.Body; the HStack spacing is 45, its
    /// height the tallest control): 29 for play.fill / pause.fill.
    static let controlsRow: CGFloat = max(glyphSize("play.fill", centerControlFont).height,
                                          glyphSize("pause.fill", centerControlFont).height)
    // TransportControlDefaultStyle (0x2a163f3f4, background 0x2a163f6f8): glyph scale 0.8 while pressed; a Circle of
    // white @ 0.1 (dark scheme) behind it at scale 1.5 and opacity 1 while pressed, 1.75 and 0 otherwise; pressing animates
    // linear(0.2), releasing interpolatingSpring(mass 1, stiffness 845.74, damping 58.163); hit area inset -10.
    static let pressedScale: CGFloat = 0.8, highlightOpacity = 0.1
    static func highlightScale(pressed: Bool) -> CGFloat { pressed ? 1.5 : 1.75 }
    static let pressAnimation = Animation.linear(duration: 0.2)
    static let releaseAnimation = Animation.interpolatingSpring(mass: 1, stiffness: 845.74, damping: 58.163, initialVelocity: 0)
    // Animated glyphs = PackageView (NowPlayingPackages.swift): PackageAsset.scale 2.6 for playPauseStop and nextPrevious
    // (0x2a15fcdd0, 0x2a15fea40), applied as PackageView.scaleEffect; nextPrevious = .multiple([State 1 ... State 4],
    // 0.8 s each), isHorizontallyFlipped for previous.
    static let packageAssetScale: CGFloat = 2.6, packageCanvas: CGFloat = 84
    /// Points per package root unit on screen. [?] How CAPackageViewLayer maps the 84 canvas before the 2.6 is not read;
    /// the old guess (fill the SF glyph box) drew the arrows 35 x 20 and the pause 25 tall. Footage drlYGnbWurM (775.9 /
    /// 778.5 s, threshold 128) against the package laid out with its 27.3 state scale (root sublayerTransform included):
    /// pause 20.4 x 27.4 for 21.05 x 28.1 -> 0.975 (fitted: the playing state); play 26.4 x 29.2 for 25.8 x 28.8 would
    /// want 1.02 [?]; arrows 28.1 x 15.9 for 31.93 x 18.33 -> 0.88.
    static func packageScale(_ file: PackageGlyph.File) -> CGFloat { file == .playPause ? 0.975 : 0.88 }
    static func nextPreviousState(taps n: Int) -> String { "State \(n % 4 + 1)" }   // [I] one state per tap, cycling

    static func glyphSize(_ name: String, _ size: CGFloat) -> CGSize {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))?.size ?? CGSize(width: size, height: size)
    }
    // [I] The client's shape preference is not read. The default (pill, radius h / 2 = 73.5) puts the artwork corner
    // outside the island at margin 11, against the HIG's concentric margins; standard keeps it inside.
    static let expandedType = ExpandedType.standard

    static var expandedHeight: CGFloat {
        margin + artwork + timelineTop + timelineRow + controlsTop + controlsRow + margin
    }

    static func compactLeadingSize(sensorHeight h: CGFloat) -> CGSize { minimalSize(sensorHeight: h, obstructed: true) }

    /// NowPlayingLeadingActivitySurface (0x2a166ac4c) branches only on the context's obstruction: non-zero -> 20 / 4 / 5 /
    /// placeholder 10, zero -> 16 / 5 / 3 / 9 (ArtworkViewStyle).
    static func leadingArtwork(obstructed: Bool) -> (side: CGFloat, padding: CGFloat, radius: CGFloat, placeholder: CGFloat) {
        obstructed ? (compactArtwork, compactArtworkPadding, compactArtworkRadius, placeholderFontSize) : (16, 5, 3, 9)
    }

    /// Minimal = the compact-leading artwork (IntegratedViewGroup_V1 minimal closure 0x2a166757c branches to the
    /// compact-leading one 0x2a1667414) [V], for split primary and adjunct alike. Which obstruction the host sends to a
    /// minimal scene is not read [?]: compact receives the sensor's.
    static func minimalSize(sensorHeight h: CGFloat, obstructed: Bool) -> CGSize {
        let a = leadingArtwork(obstructed: obstructed)
        return CGSize(width: a.side + 2 * a.padding, height: h)
    }

    static func compactTrailingSize(sensorHeight h: CGFloat) -> CGSize {
        CGSize(width: compactWaveform + 2 * compactWaveformPadding, height: h)
    }

    static func playPauseSymbol(_ playing: Bool) -> String { playing ? "pause.fill" : "play.fill" }

    /// Width of an SF Symbol at a point size, regular weight (TransportControl is sized by a hidden Image of its glyph).
    static func glyphWidth(_ name: String, _ size: CGFloat) -> CGFloat {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))?.size.width ?? size
    }

    /// x centers of previous, play/pause, next in the expanded content (width 286): glyph widths, spacing 45, centered.
    static func controlCenters(isPlaying: Bool) -> [CGFloat] {
        let side = glyphWidth("backward.fill", controlFont), mid = glyphWidth(playPauseSymbol(isPlaying), centerControlFont)
        let x0 = (expandedWidth - (side + controlSpacing + mid + controlSpacing + side)) / 2
        return [x0 + side / 2, x0 + side + controlSpacing + mid / 2, x0 + side + controlSpacing + mid + controlSpacing + side / 2]
    }

    /// Transport control under a point of the expanded content (origin top-left, width 286). The hosted SwiftUI views
    /// do not take the mouse (the island view does), so the host maps clicks with this. Pass the model's isPlaying:
    /// play.fill and pause.fill differ in width, which shifts the outer centers slightly.
    static func control(at p: CGPoint, isPlaying: Bool = true) -> NowPlayingCommand? {
        let top = margin + artwork + timelineTop + timelineRow + controlsTop
        guard p.y >= top, p.y <= top + controlsRow else { return nil }
        let c = controlCenters(isPlaying: isPlaying), reach = (c[1] - c[0]) / 2
        for (x, cmd) in zip(c, [NowPlayingCommand.previousTrack, .togglePlayPause, .nextTrack]) where abs(p.x - x) <= reach {
            return cmd
        }
        return nil
    }

    /// DraggableViewModifier rubber band (0x2a160ae98): beyond either end the value moves 1 - 1 / (excess * R + 1) of the
    /// maximum overshoot.
    static func rubberBand(_ p: Double) -> Double {
        func eased(_ x: Double) -> Double { rubberMaxOvershoot * (1 - 1 / (x * rubberResistance + 1)) }
        return p < 0 ? -eased(-p) : (p > 1 ? 1 + eased(p - 1) : p)
    }

    /// Track stretch while overshooting (0x2a160a180): x 1 + o, y 1 - compression * o / maxOvershoot, anchored on the
    /// opposite end.
    static func stretch(_ value: Double) -> (x: CGFloat, y: CGFloat, anchor: UnitPoint) {
        let o = value < 0 ? -value : (value > 1 ? value - 1 : 0)
        return (CGFloat(1 + o), CGFloat(1 - rubberVerticalCompression * o / rubberMaxOvershoot), value < 0 ? .trailing : .leading)
    }

    /// Elapsed / remaining labels get a fixed width (min label trailing-aligned, max label leading-aligned,
    /// ContentInlineSliderView 0x2a162ada0), caption2 medium with monospaced digits. Each is as wide as its own text at
    /// the duration's digit count: the elapsed label starts at the margin in the footage (drlYGnbWurM 775.9 s, Apple's
    /// image), so it is not padded to the wider remaining label. [I] w per label.
    static func labelWidths(duration: Double) -> (elapsed: CGFloat, remaining: CGFloat) {
        let size = NSFont.preferredFont(forTextStyle: .caption2).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        func w(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
        return (w(NowPlayingInfo.label(duration)), w(NowPlayingInfo.label(-duration)))
    }

    /// Capsule track in the expanded content (origin top-left, width 286).
    static func trackFrame(duration: Double) -> CGRect {
        let w = labelWidths(duration: duration)
        let x = margin + w.elapsed + timelineSpacing
        return CGRect(x: x, y: margin + artwork + timelineTop + (timelineRow - capsuleHeight) / 2,
                      width: expandedWidth - margin - w.remaining - timelineSpacing - x, height: capsuleHeight)
    }

    /// The whole slider row is draggable (DraggableViewModifier wraps the HStack of labels and track).
    static func timelineHit(_ p: CGPoint) -> Bool {
        let top = margin + artwork + timelineTop
        return p.x >= margin && p.x <= expandedWidth - margin
            && p.y >= top - timelineHitSlop && p.y <= top + timelineRow + timelineHitSlop
    }

    /// MediaCoreUI WaveformLayer bar layout (0x22677a3e0), six bars in a side x side square, origin top-left.
    static func waveformBars(side: CGFloat, values: [Double], scale: CGFloat) -> [CGRect] {
        let n = CGFloat(values.count), bw = side * 0.125 * 5 / 6, slot = 1.08 * bw
        let gap = n > 1 ? (side - slot * n) / (n - 1) : 0
        return values.enumerated().map { i, v in
            let v = CGFloat(max(v, 0))
            let w = (1 + 0.12 * v) * bw, h = max(bw, min(v, 1) * side)
            return CGRect(x: CGFloat(i) * (slot + gap) + (slot - w) / 2, y: (side - h) / 2, width: w, height: h)
        }
    }

    // Level without live audio: 26.6 ControlCenter has no audio tap on other processes, and 27.3's WaveformLayer then
    // runs its canned BouncyBarsAsset (MediaCoreUI.framework/Resources/BouncyBars.caar): five layers, each a
    // CAKeyframeAnimation of bounds.size.height (% of a 100 pt frame), duration 2.66 s, repeat forever, cubic. The layer
    // picks one of three variants at random (0x2268f4fb0, random(3)), which permute the same five rows.
    static let bouncePeriod = 2.66
    private static let bounceRows: [(values: [Double], times: [Double])] = [
        ([49, 51, 42.9, 78.9, 65.5, 31, 47.3, 51, 53.2, 68.8, 70.9, 49],
         [0, 0.091, 0.1818, 0.273, 0.3636, 0.4545, 0.5454, 0.6363, 0.7272, 0.8181, 0.909, 1]),
        ([77, 48, 77, 55.2, 45.1, 46.1, 88.1, 70, 90.7, 53.4, 51.9, 77],
         [0, 0.091, 0.1818, 0.2727, 0.3636, 0.4545, 0.5454, 0.6363, 0.7272, 0.8181, 0.909, 1]),
        ([60, 68, 58, 82.9, 68, 79, 61.4, 88, 57.1, 82.9, 62, 60],
         [0, 0.091, 0.1818, 0.2727, 0.3636, 0.4545, 0.5454, 0.6363, 0.7272, 0.8181, 0.909, 1]),
        ([33, 58.9, 68, 46.9, 93.7, 59.9, 71.7, 52, 68.8, 44, 73, 33],
         [0, 0.091, 0.1818, 0.2727, 0.3636, 0.4545, 0.5454, 0.6363, 0.7272, 0.8181, 0.909, 1]),
        ([40, 24, 48.9, 57, 42.1, 33.9, 25, 72, 29, 58.8, 50.1, 40],
         [0, 0.091, 0.1818, 0.2727, 0.3636, 0.4545, 0.5454, 0.6363, 0.7272, 0.8181, 0.909, 1]),
    ]
    private static let bounceVariants = [[0, 1, 2, 3, 4], [4, 2, 0, 1, 3], [3, 0, 1, 2, 4]]   // VariantA / B / C layer rows

    /// Bar level 0...1 at time t. The asset animates only min(bars, 5) layers; the sixth bar of the sixBars layout gets
    /// the first row half a period later [I] (27.3 leaves it unanimated in the canned path).
    static func bounce(_ t: Double, bar i: Int, variant: Int) -> Double {
        let rows = bounceVariants[variant % 3], row = bounceRows[rows[i % 5]]
        var phase = (t + (i >= 5 ? bouncePeriod / 2 : 0)).truncatingRemainder(dividingBy: bouncePeriod) / bouncePeriod
        if phase < 0 { phase += 1 }
        return cubicKeyframe(row.values, row.times, at: phase) / 100
    }

    /// CAKeyframeAnimation calculationMode cubic: Catmull-Rom through the keyframes; the loop is closed (first == last).
    private static func cubicKeyframe(_ v: [Double], _ k: [Double], at p: Double) -> Double {
        let n = v.count - 1
        var s = 0
        while s < n - 1 && p > k[s + 1] { s += 1 }
        let u = (p - k[s]) / (k[s + 1] - k[s])
        let p0 = v[s == 0 ? n - 1 : s - 1], p1 = v[s], p2 = v[s + 1], p3 = v[s + 1 == n ? 1 : s + 2]
        return 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u)
    }
}

/// ArtworkTreatment from the artwork's mean Rec.601 luminance. MediaCoreUI 0x226822da4 classifies (< 0.6 lighten by
/// 0.6 - L, > 0.7 darken by L - 0.7); 0x2268246cc builds the treatment: saturation 1.25, plus 4 (0.6 - L) when lightening.
struct ArtworkTreatment: Equatable {
    var lightening = 0.0, darkening = 0.0, saturation = 1.25
    static let neutral = ArtworkTreatment()

    init() {}

    init(luminance l: Double) {
        guard l > 0, l <= 1 else { return }
        if l < 0.6 { lightening = 0.6 - l; saturation += 4 * (0.6 - l) }
        if l > 0.7 { darkening = l - 0.7 }
    }

    init(image: NSImage) {
        var px = [UInt8](repeating: 0, count: 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { self.init(); return }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        self.init(luminance: (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255)
    }
}

/// 27.3 FlipModel.reactTo / flipEdge (NowPlayingUI log strings): how a new artwork image reaches the face. The seed is
/// the image itself (NowPlayingModel makes a new one only when the artwork bytes change).
struct FlipModel {
    enum Reaction: Equatable { case placeholder, firstDraw, unchanged, flip, buffered }
    private(set) var seed: ObjectIdentifier?
    private(set) var pending: NSImage?
    private(set) var targetFace = 0, shownFace = 0

    var isFlipping: Bool { shownFace != targetFace }

    mutating func react(to image: NSImage?, backward: Bool) -> Reaction {
        guard let image else { seed = nil; pending = nil; return .placeholder }   // fade to placeholder, reset
        let s = ObjectIdentifier(image)
        guard let old = seed else { seed = s; return .firstDraw }              // update in place, no flip
        guard s != old else { return .unchanged }
        seed = s
        pending = image
        if isFlipping { return .buffered }                                     // coalesce onto the current flip
        targetFace += NowPlayingMetrics.flipStep(backward: backward)
        return .flip
    }

    /// The flip reached `face`'s swap point: returns the buffered image to reveal (nil for a duplicate boundary).
    mutating func edge(_ face: Int) -> NSImage? {
        guard face != shownFace else { return nil }
        shownFace = face
        defer { pending = nil }
        return pending
    }
}

/// View state shared by the compact and expanded views. Main queue.
final class NowPlayingModel: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var isPlaying = false
    @Published private(set) var bundleID: String?
    private(set) var image: NSImage?
    private(set) var appIcon: NSImage?
    private(set) var treatment = ArtworkTreatment.neutral
    private(set) var playChange = Date.distantPast
    /// BouncyBarsAsset variant, chosen at random once per waveform owner (WaveformLayer, 0x2268f4fb0).
    let waveformVariant = Int.random(in: 0..<3)

    func update(_ s: NowPlayingSource.State) {
        if s.info?.artwork != info?.artwork {
            image = s.info?.artwork.flatMap(NSImage.init(data:))
            treatment = image.map(ArtworkTreatment.init(image:)) ?? .neutral
        }
        if s.bundleID != bundleID {
            appIcon = s.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        if s.isPlaying != isPlaying {
            playChange = Date()
            // Re-render once the bars have settled so the paused waveform's timeline can stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.objectWillChange.send() }
        }
        info = s.info
        isPlaying = s.isPlaying
        bundleID = s.bundleID
    }

    // MARK: Timeline scrubbing (DraggableViewModifier: relative drag, rubber band, commit on release)

    /// Rubber-banded drag value while scrubbing (may leave 0...1 by the overshoot), nil otherwise.
    @Published private(set) var scrub: Double?
    private var scrubStart: (x: CGFloat, value: Double)?

    var scrubValue: Double? { scrub.map { min(max($0, 0), 1) } }

    func beginScrub(x: CGFloat, now: Date = Date()) {
        guard let i = info, let d = i.duration, d > 0 else { return }
        let v = i.progress(at: now)
        scrubStart = (x, v)
        scrub = v
    }

    func moveScrub(x: CGFloat) {
        guard let s = scrubStart, let d = info?.duration else { return }
        scrub = NowPlayingMetrics.rubberBand(s.value + Double(x - s.x) / Double(NowPlayingMetrics.trackFrame(duration: d).width))
    }

    /// Ends the drag; returns the seek target in seconds. The elapsed time jumps there at once (optimistic, like
    /// TimelineProgressInterpolatingView.__optimisticSeekValue) until MediaRemote reports the new position.
    func endScrub(now: Date = Date()) -> Double? {
        defer { scrubStart = nil; scrub = nil }
        guard scrubStart != nil, let v = scrubValue, var i = info, let d = i.duration else { return nil }
        i.elapsed = v * d
        i.timestamp = now
        info = i
        return i.elapsed
    }

    // MARK: Transport buttons (pressed highlight, symbol effect on release)

    @Published private(set) var pressed: NowPlayingCommand?
    @Published private(set) var skipCount: [NowPlayingCommand: Int] = [:]

    func press(_ c: NowPlayingCommand) { pressed = c }

    /// Ends a press; returns the command to send (LongPressingButton fires the tap on release).
    func release(now: Date = Date()) -> NowPlayingCommand? {
        guard let c = pressed else { return nil }
        pressed = nil
        skipCount[c, default: 0] += 1
        if c == .previousTrack { backwardUntil = now.addingTimeInterval(NowPlayingMetrics.flipBackwardTimeout) }
        return c
    }

    // FlipDirectionTracker: the next artwork flips backward for a while after "previous", forward otherwise.
    private var backwardUntil = Date.distantPast

    func flipsBackward(at now: Date = Date()) -> Bool { now < backwardUntil }
}

/// FlippingArtworkView.body (0x2a16119e0): placeholder fill, image or glyph, .compositingGroup .blur(blur, opaque: true)
/// .clipShape, ArtworkGlowModifier, ArtworkLegibilityModifier, AnimatableFlipRotation. Each instance keeps its own flip
/// state like the 27.3 @State, so a new compact or expanded view starts with a first draw.
struct NowPlayingArtwork: View {
    @ObservedObject var model: NowPlayingModel
    var side: CGFloat, radius: CGFloat
    var placeholderFont = NowPlayingMetrics.placeholderFontSize
    typealias M = NowPlayingMetrics

    @State private var flip = FlipModel()
    @State private var shown: NSImage?
    @State private var angle = 0.0
    @State private var blur = 0.0
    @State private var glow = false

    var body: some View {
        // ArtworkLegibilityModifier: a backdrop of the face (over the black island) through the color matrix.
        face.overlay { face.background(.black).compositingGroup()._colorMatrix(M.legibilityMatrix).clipShape(shape) }
            .modifier(FlipRotation(angle: angle, target: angle, lastFace: flip.shownFace, onMidFlip: reveal))
            .shadow(color: .black.opacity(M.artworkShadow.opacity), radius: M.artworkShadow.radius, x: 0, y: M.artworkShadow.y)
            .onChange(of: model.image, initial: true) { _, img in react(img) }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    @ViewBuilder private var face: some View {
        // Before the first reaction (an off-screen render) the model's image is drawn directly.
        let image = flip.seed == nil ? model.image : shown
        ZStack {
            shape.fill(.primary.opacity(0.2))                    // float 0x3e4ccccd
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                // Image(systemName: placeholder).foregroundStyle(.secondary).font(.system(size:)) (0x2a1612614, no weight).
                Image(systemName: "music.note")   // [?] ArtworkViewModel._placeholder comes from the session
                    .font(.system(size: placeholderFont))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .compositingGroup()
        .blur(radius: blur, opaque: true)
        .clipShape(shape)
        // ArtworkGlowModifier 0x2a160e54c: white rounded rect, opacity isActive ? intensity : 0, BlendMode.plusLighter.
        .overlay(shape.fill(.white).opacity(glow ? M.glowIntensity : 0).blendMode(.plusLighter))
    }

    private func react(_ image: NSImage?) {
        var f = flip
        switch f.react(to: image, backward: model.flipsBackward()) {
        case .placeholder: withAnimation(M.placeholderFade) { flip = f; shown = nil }
        case .firstDraw: flip = f; shown = image
        case .flip: flip = f; withAnimation(M.flipAnimation) { angle = Double(f.targetFace) * 180 }
        case .buffered, .unchanged: flip = f
        }
    }

    /// flipEdge: the buffered image appears blurred and glowing, both fade out (case 4 of 0x2a161315c).
    private func reveal(_ face: Int) {
        guard let image = flip.edge(face) else { return }
        shown = image
        blur = M.revealBlur
        glow = true
        withAnimation(M.revealAnimation) { blur = 0; glow = false }
    }
}

/// AnimatableFlipRotation (0x2a160da34 animatableData setter, 0x2a160de78 body): rotation3DEffect of the shown angle
/// around y, and a mid-flip callback swapLead ahead of edge-on.
struct FlipRotation: ViewModifier, Animatable {
    var angle: Double
    let target: Double
    let lastFace: Int
    let onMidFlip: (Int) -> Void

    var animatableData: Double {
        get { angle }
        set {
            angle = newValue
            if let face = NowPlayingMetrics.flipSwapFace(angle: newValue, target: target, lastFace: lastFace) {
                let report = onMidFlip
                DispatchQueue.main.async { report(face) }   // FlipModel.edge drops duplicate boundaries
            }
        }
    }

    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(NowPlayingMetrics.flipDisplayAngle(angle)), axis: (0, 1, 0), anchor: .center,
                                 anchorZ: 0, perspective: NowPlayingMetrics.flipPerspective)
    }
}

/// MediaCoreUI Marquee with the NowPlayingUI configuration. Body = ViewThatFits { content, MarqueeingContent }: content
/// that fits is drawn as is; wider content scrolls as two copies `marqueeSpacing` apart, masked by MaskView (gradient,
/// color, gradient; 6 pt feathers on both edges). Reports its loop length for CoordinatedMarquees; `period` is the
/// coordinated maximum (0 = its own).
struct NowPlayingMarquee<Content: View>: View {
    var period: Double
    var onCycle: (Double) -> Void = { _ in }
    @ViewBuilder var content: Content
    @State private var distance = 0.0
    @State private var start = Date()
    typealias M = NowPlayingMetrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            TimelineView(.animation(minimumInterval: 1 / M.marqueeMaxFPS, paused: distance == 0)) { tl in
                HStack(spacing: M.marqueeSpacing) {
                    content.fixedSize()
                        .onGeometryChange(for: Double.self) { Double($0.size.width + M.marqueeSpacing) } action: { d in
                            distance = d
                            start = Date()
                            onCycle(M.marqueeCycle(distance: d))
                        }
                    content.fixedSize()
                }
                .offset(x: M.marqueeOffset(tl.date.timeIntervalSince(start), distance: distance, period: period))
                // Ideal width 0: ViewThatFits then hands this child the real width (AnimatingContent sizes to the proposal).
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: M.marqueeFeather)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: M.marqueeFeather)
                    }
                }
            }
            .onDisappear { onCycle(0) }
        }
    }
}

/// Six-bar waveform tinted by the artwork (WaveformTheme.artwork + ArtworkTreatment), white without artwork.
struct NowPlayingWaveform: View {
    @ObservedObject var model: NowPlayingModel
    var side: CGFloat
    @Environment(\.displayScale) private var scale

    private static let ramp = 0.25   // [?] bars grow from / settle to dots

    var body: some View {
        let settled = !model.isPlaying && Date().timeIntervalSince(model.playChange) > Self.ramp
        TimelineView(.animation(minimumInterval: 1 / NowPlayingMetrics.waveformMaxFPS, paused: settled)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate, dt = tl.date.timeIntervalSince(model.playChange)
            let a = model.isPlaying ? min(dt / Self.ramp, 1) : max(1 - dt / Self.ramp, 0)
            let values = (0..<6).map { NowPlayingMetrics.bounce(t, bar: $0, variant: model.waveformVariant) * a }
            fill.mask {
                Canvas { ctx, _ in
                    for r in NowPlayingMetrics.waveformBars(side: side, values: values, scale: scale) {
                        let radius = (r.width / 2 * scale).rounded() / scale
                        ctx.fill(Path(roundedRect: r, cornerRadius: radius), with: .color(.white))
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }

    /// MediaCoreUI ArtworkBackdropView.body (0x2268c29dc): image .frame .aspectRatio .saturation(treatment.saturation)
    /// .overlay(black @ darkening) .overlay(white @ lightening) .compositingGroup .blur(radius: 6), masked by the bars.
    /// opaque: the backdrop is not faded at the 16 pt frame edge [I], otherwise the outer bars turn dim and grey.
    @ViewBuilder private var fill: some View {
        if let img = model.image {
            let t = model.treatment
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: side, height: side)
                .saturation(t.saturation)
                .overlay(Color.black.opacity(t.darkening))
                .overlay(Color.white.opacity(t.lightening))
                .compositingGroup()
                .blur(radius: NowPlayingMetrics.waveformBackdropBlur, opaque: true)
                .clipped()
        } else {
            Color.white
        }
    }
}

/// NowPlayingLeadingActivitySurface: compact leading and minimal (split primary or adjunct) are the same view.
struct NowPlayingCompactLeading: View {
    @ObservedObject var model: NowPlayingModel
    var sensorHeight: CGFloat
    var obstructed = true   // the context's obstruction is non-zero (compact gets the sensor's)

    var body: some View {
        let a = NowPlayingMetrics.leadingArtwork(obstructed: obstructed)
        NowPlayingArtwork(model: model, side: a.side, radius: a.radius, placeholderFont: a.placeholder)
            .padding(.horizontal, a.padding)
            .frame(height: sensorHeight)
            .environment(\.colorScheme, .dark)   // the island is black: .primary / .secondary must be the dark-mode ones
    }
}

typealias NowPlayingMinimal = NowPlayingCompactLeading

struct NowPlayingCompactTrailing: View {
    @ObservedObject var model: NowPlayingModel
    var sensorHeight: CGFloat

    var body: some View {
        NowPlayingWaveform(model: model, side: NowPlayingMetrics.compactWaveform)
            .padding(NowPlayingMetrics.compactWaveformPadding)
            .frame(height: sensorHeight)
            .environment(\.colorScheme, .dark)
    }
}

struct NowPlayingExpanded: View {
    @ObservedObject var model: NowPlayingModel
    typealias M = NowPlayingMetrics
    @State private var titleCycle = 0.0
    @State private var artistCycle = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // ArtworkProminence (0x2a166c2ac scale, 0x2a166c3e0 opacity, values 0x2a160d334): not playing -> scale 0.8
                // around the center and opacity 0.5; the app icon overlay comes after it and keeps its place.
                NowPlayingArtwork(model: model, side: M.artwork, radius: M.artworkRadius)
                    .scaleEffect(model.isPlaying ? 1 : M.pausedArtworkScale)
                    .animation(M.prominenceScaleAnimation, value: model.isPlaying)
                    .opacity(model.isPlaying ? 1 : M.pausedArtworkOpacity)
                    .animation(.easeOut, value: model.isPlaying)   // [I] which animation drives which effect
                    .overlay(alignment: .bottomTrailing) {
                        if M.showsAppIcon(bundleID: model.bundleID), let icon = model.appIcon {
                            Image(nsImage: icon).resizable().frame(width: M.appIcon, height: M.appIcon)
                                .offset(x: M.appIconOffset, y: M.appIconOffset)
                        }
                    }
                // Solo layout aligns the row to the top; the text sits below the sensor, at the artwork's bottom [I].
                // MetadataView: a MetadataMarquee per line, CoordinatedMarquees (both loop with the longer cycle). Text
                // changes are not animated (no contentTransition in NowPlayingUI).
                VStack(alignment: .leading, spacing: 0) {
                    NowPlayingMarquee(period: max(titleCycle, artistCycle), onCycle: { titleCycle = $0 }) {
                        Text(model.info?.title ?? "").font(.headline).foregroundStyle(.primary)
                    }
                    .frame(height: M.metadataLine, alignment: .top)
                    NowPlayingMarquee(period: max(titleCycle, artistCycle), onCycle: { artistCycle = $0 }) {
                        Text(model.info?.artist ?? "").font(.body).foregroundStyle(.secondary)
                    }
                    .frame(height: M.metadataLine, alignment: .top)
                }
                .lineLimit(1)
                .padding(.horizontal, M.metadataPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                NowPlayingWaveform(model: model, side: M.waveform)
                    .frame(width: M.waveformFrame.width, height: M.waveformFrame.height)
            }
            .frame(height: M.artwork)
            timeline.frame(height: M.timelineRow).padding(.top, M.timelineTop)
            controls.frame(height: M.controlsRow).padding(.top, M.controlsTop)
        }
        .padding(M.margin)
        .frame(width: M.expandedWidth, height: M.expandedHeight)
        .environment(\.colorScheme, .dark)
    }

    /// ContentInlineSliderView: [elapsed, fixed width, trailing] [CapsuleProgress] [remaining, fixed width, leading];
    /// labels caption2 medium, Color.secondary, primary while dragging (TimelineControlTimeLabelLockScreenStyleView).
    private var timeline: some View {
        TimelineView(.animation(minimumInterval: nil,
                                paused: M.timelinePaused(isPlaying: model.isPlaying, scrubbing: model.scrub != nil))) { tl in
            let info = model.info, d = info?.duration ?? 0, scrubbing = model.scrub != nil
            let p = model.scrubValue ?? info?.progress(at: tl.date) ?? 0
            let e = scrubbing ? p * d : info?.elapsed(at: tl.date) ?? 0
            let st = M.stretch(model.scrub ?? p), w = M.labelWidths(duration: d)
            HStack(spacing: M.timelineSpacing) {
                Text(NowPlayingInfo.label(e)).frame(width: w.elapsed, alignment: .trailing)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.quaternary)
                        Rectangle().fill(scrubbing ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary))
                            .frame(width: g.size.width * p)
                    }
                    .frame(height: M.capsuleHeight)
                    .clipShape(Capsule())
                    .scaleEffect(x: st.x, y: st.y, anchor: st.anchor)
                    .animation(scrubbing ? nil : M.snapBack, value: st.x)
                    .frame(maxHeight: .infinity)
                }
                Text(NowPlayingInfo.label(-(d - e))).frame(width: w.remaining, alignment: .leading)
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(scrubbing ? Color.primary : Color.secondary)
            .animation(scrubbing ? M.scrubBegin : M.scrubEnd, value: scrubbing)
        }
    }

    private var controls: some View {
        HStack(spacing: M.controlSpacing) {
            control(.previousTrack, width: M.glyphWidth("backward.fill", M.controlFont)) {
                glyph(.nextPrevious, M.nextPreviousState(taps: model.skipCount[.previousTrack, default: 0]),
                      symbol: "backward.fill", size: M.controlFont, flipped: true)
            }
            control(.togglePlayPause, width: M.glyphWidth(M.playPauseSymbol(model.isPlaying), M.centerControlFont)) {
                glyph(.playPause, model.isPlaying ? "pause" : "play", symbol: M.playPauseSymbol(model.isPlaying),
                      size: M.centerControlFont, flipped: false)
            }
            control(.nextTrack, width: M.glyphWidth("forward.fill", M.controlFont)) {
                glyph(.nextPrevious, M.nextPreviousState(taps: model.skipCount[.nextTrack, default: 0]),
                      symbol: "forward.fill", size: M.controlFont, flipped: false)
            }
        }
        .foregroundStyle(.primary)
    }

    /// The system package when it loads (PackageView), the plain SF Symbol otherwise.
    @ViewBuilder
    private func glyph(_ file: PackageGlyph.File, _ state: String, symbol: String, size: CGFloat, flipped: Bool) -> some View {
        let box = M.glyphSize(symbol, size)
        if PackageGlyph.isAvailable(file) {
            PackageGlyphView(file: file, state: state, box: box, flipped: flipped).frame(width: box.width, height: box.height)
        } else {
            Image(systemName: symbol).font(.system(size: size))
        }
    }

    /// TransportControlsStyle font: Font.system(size:) with no weight (0x2a1643278); the control is as wide as its glyph
    /// (TransportControl sizes itself with a hidden Image), with the TransportControlDefaultStyle press feedback.
    private func control<G: View>(_ c: NowPlayingCommand, width: CGFloat, @ViewBuilder glyph: () -> G) -> some View {
        let pressed = model.pressed == c
        return glyph()
            .frame(width: width)
            .background {
                Circle().fill(Color.white.opacity(M.highlightOpacity))
                    .scaleEffect(M.highlightScale(pressed: pressed))
                    .opacity(pressed ? 1 : 0)
            }
            .scaleEffect(pressed ? M.pressedScale : 1)
            .animation(pressed ? M.pressAnimation : M.releaseAnimation, value: pressed)
            .frame(height: M.controlsRow)
    }
}
