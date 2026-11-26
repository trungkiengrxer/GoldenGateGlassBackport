// Window-free tests for Now Playing (island/Sources/NowPlaying.swift, NowPlayingViews.swift). Expected values are
// computed by hand from docs/RE-27-NOWPLAYING.md (27.3 NowPlayingUI / MediaCoreUI).
import CoreGraphics
import Foundation
import SwiftUI

enum NowPlayingTests {
    static func run() {
        parse()
        interpolation()
        timeLabels()
        presence()
        waveform()
        treatment()
        metrics()
        expandedLayout()
        MainActor.assumeIsolated { placeholder() }
        MainActor.assumeIsolated { rowHeights() }
        scrubber()
        transport()
        marquee()
        mediaRemote()
    }

    /// 27.3 sizes the expanded rows by their content (session VStack and row HStack spacing 0, 0x2a166f740 / 0x2a166c524):
    /// the timeline row is as tall as its caption2 medium labels (CapsuleProgress is 10), the controls row as tall as the
    /// hidden Image of the 30 pt center glyph (TransportControl.Body). Expected values come from SwiftUI's own layout.
    @MainActor static func rowHeights() {
        func height<V: View>(_ v: V) -> CGFloat { NSHostingController(rootView: v).sizeThatFits(in: CGSize(width: 500, height: 500)).height }
        let label = height(Text("0:00").font(.caption2.weight(.medium).monospacedDigit()))
        let glyph = max(height(Image(systemName: "play.fill").font(.system(size: 30))),
                        height(Image(systemName: "pause.fill").font(.system(size: 30))))
        // SwiftUI on macOS 26 makes the caption2 label line 15 tall; the footage fits 13 (drlYGnbWurM 775.9 s: track
        // centre 84, arrows 113...129, bottom 151.8 for margins 16 and artwork 50), so the row is 2 shorter than it.
        ok(NowPlayingMetrics.timelineRow == 13 && label - NowPlayingMetrics.timelineRow == 2,
           "timelineRowFootage (\(NowPlayingMetrics.timelineRow) vs label \(label))")
        ok(NowPlayingMetrics.controlsRow == glyph, "controlsRowIsGlyphHeight (\(NowPlayingMetrics.controlsRow) vs \(glyph))")
        let sum = 16 + 50 + 12 + 13 + 15 + glyph + 16   // 151 (footage 151.8, Apple's image 151.2)
        ok(NowPlayingMetrics.expandedHeight == sum, "expandedHeightFromRows (\(NowPlayingMetrics.expandedHeight) vs \(sum))")
        // Metadata lines are 16 apart in the footage (baseline pitch 15.8 in drlYGnbWurM 775.9 s, 15.4 in Apple's image);
        // SwiftUI on macOS 26 lays a 13 pt line out 18 tall with the glyphs at its top, so a 16 pt top-aligned frame
        // puts the baseline 13 below the line top (footage 13.05).
        ok(NowPlayingMetrics.metadataLine == 16, "metadataLine (\(NowPlayingMetrics.metadataLine))")
    }

    /// Expanded layout against 27.3 footage (docs/RE-27-NOWPLAYING.md 5i): drlYGnbWurM 775.9 / 778.5 s (tripod, 2.846
    /// px/pt), XWXKHTb6o3w 703.47 s and Apple's PROLED image all show margins 16 on every side and a 50 pt artwork.
    static func expandedLayout() {
        typealias M = NowPlayingMetrics
        ok(M.margin == 16, "marginIsContextDefault16 (\(M.margin))")      // NowPlayingActivityContext default 0x2a167ee28
        ok(M.artwork == 50, "artworkFootage50 (\(M.artwork))")
        // Waveform frame 25 ends at the right margin: bars (22) end 1.5 inside it, at 268.5 (footage 268.4).
        ok(near(M.expandedWidth - M.margin - (M.waveformFrame.width - M.waveform) / 2, 268.5), "waveformRightEdge")
        // Elapsed label starts at the margin (footage 16.5 at threshold 90): each label is as wide as its own text.
        let d = 182.0, w = M.labelWidths(duration: d), f = M.trackFrame(duration: d)
        ok(w.elapsed < w.remaining, "elapsedLabelNarrowerThanRemaining (\(w))")
        ok(near(f.minX, M.margin + w.elapsed + M.timelineSpacing)
           && near(f.maxX, M.expandedWidth - M.margin - w.remaining - M.timelineSpacing), "trackBetweenOwnLabelWidths")
        // Apple Music shows no app badge on the artwork in any footage; other apps keep it [?].
        ok(!M.showsAppIcon(bundleID: "com.apple.Music") && M.showsAppIcon(bundleID: "com.spotify.client")
           && !M.showsAppIcon(bundleID: nil), "appBadgeHiddenForMusic")
        // Transport glyph sizes in drlYGnbWurM (threshold 128): play 26.4 x 29.2, pause 20.4 x 27.4, arrows 28.1 x 15.9
        // for package boxes (state scale already in) play 25.8 x 28.8, pause 21.05 x 28.1, arrows 31.93 x 18.33. The
        // pause (playing state) is fitted; play is checked in packages() [?].
        ok(near(Double(M.packageScale(.playPause)) * 28.1, 27.4, 0.3), "playPauseGlyphFootage")
        ok(near(Double(M.packageScale(.nextPrevious)) * 31.93, 28.1, 0.3)
           && near(Double(M.packageScale(.nextPrevious)) * 18.33, 15.9, 0.3), "nextPreviousGlyphFootage")
    }

    /// MetadataMarquee (27.3): NowPlayingUI MarqueeConfiguration 0x2a161c0d4 (spacing 10, rate 30, delay 1.5, feathering
    /// 6 / 6, 30-60 fps); MediaCoreUI Marquee animation 0x2268b058c: CAKeyframeAnimation transform.translation.x
    /// [0, a, D - a, D] with quadratic ease-in / linear / ease-out segments, 0.5 s ramps, inside a group of duration
    /// D / rate + delay that starts delay after the content appears, repeating forever; CoordinatedMarquees take the
    /// longest group. TimelineProgressInterpolatingView: TimelineView(.animation(minimumInterval: nil, paused:)).
    static func marquee() {
        typealias M = NowPlayingMetrics
        ok(M.marqueeSpacing == 10 && M.marqueeRate == 30 && M.marqueeDelay == 1.5 && M.marqueeFeather == 6
           && M.marqueeRamp == 0.5, "marqueeConfiguration")
        // D = 150 pt: travel 5 s, group 6.5 s; cruise v = D / (T - 0.5) = 33.33 pt/s, ramp distance a = 0.5 * 0.5 * v.
        let d = 150.0, p = M.marqueeCycle(distance: d)
        ok(near(p, 6.5), "marqueeCycle")
        ok(M.marqueeOffset(0, distance: d, period: p) == 0 && M.marqueeOffset(1.49, distance: d, period: p) == 0,
           "marqueeWaitsDelay")
        ok(near(M.marqueeOffset(1.5 + 0.25, distance: d, period: p), -(150.0 / 4.5 * 0.25 * 0.25 / 0.5 * 0.5)),
           "marqueeEasesIn")
        let v = 150.0 / 4.5, a = 0.25 * v
        ok(near(M.marqueeOffset(1.5 + 0.5, distance: d, period: p), -a)
           && near(M.marqueeOffset(1.5 + 2.5, distance: d, period: p), -(a + 2 * v)), "marqueeCruises")
        ok(near(M.marqueeOffset(1.5 + 4.75, distance: d, period: p), -(d - a * 0.25)), "marqueeEasesOut")
        // After the travel the copy sits where the original was: rest at 0 for the delay, then go again.
        ok(M.marqueeOffset(1.5 + 5.2, distance: d, period: p) == 0 && M.marqueeOffset(1.5 + 6.4, distance: d, period: p) == 0
           && near(M.marqueeOffset(1.5 + 6.5 + 0.5, distance: d, period: p), -a), "marqueeLoops")
        // A coordinated (longer) group: the short line rests until the long one finishes.
        ok(M.marqueeOffset(1.5 + 7, distance: d, period: 9) == 0
           && near(M.marqueeOffset(1.5 + 9.5, distance: d, period: 9), -a), "marqueeCoordinated")
        // Short travel (T < 1 s): two half-length ramps meet in the middle.
        let s = 15.0, sp = M.marqueeCycle(distance: s)
        ok(near(M.marqueeOffset(1.5 + 0.25, distance: s, period: sp), -7.5), "marqueeShortTravel")

        ok(M.timelinePaused(isPlaying: false, scrubbing: false) && !M.timelinePaused(isPlaying: true, scrubbing: false)
           && !M.timelinePaused(isPlaying: false, scrubbing: true), "timelineFollowsFrames")

        MainActor.assumeIsolated { marqueeRender() }
    }

    /// Content wider than the box is masked by 6 pt feathers at both edges (MaskView: gradient, color, gradient);
    /// content that fits is drawn as is (Marquee.Body = ViewThatFits).
    @MainActor static func marqueeRender() {
        func columns(_ contentWidth: CGFloat) -> [Int] {
            let v = NowPlayingMarquee(period: 0) { Color.white.frame(width: contentWidth, height: 10) }
                .frame(width: 100, height: 10, alignment: .leading).background(Color.black)   // MetadataView VStack(.leading)
            guard let cg = ImageRenderer(content: v).cgImage else { return [] }
            var px = [UInt8](repeating: 0, count: 4 * cg.width)
            let ctx = CGContext(data: &px, width: cg.width, height: 1, bitsPerComponent: 8, bytesPerRow: 4 * cg.width,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: -cg.height / 2, width: cg.width, height: cg.height))
            return [0, 3, 50, cg.width - 1].map { Int(px[4 * $0 + 1]) }
        }
        let long = columns(300), short = columns(50)
        ok(long.count == 4 && long[0] < 60 && long[1] > 80 && long[1] < 200 && long[2] > 250 && long[3] < 60,
           "marqueeFeathersEdges (\(long))")
        ok(short.count == 4 && short[0] > 250, "marqueeFitsUnmasked (\(short))")
    }

    /// 27.3 timeline: CapsuleProgressStyle 0x2a15f81e8 (height 10, interactionScale 1, rubberBandMode
    /// .nowPlayingActivity = RubberBandConfiguration(0.04, 2.0, 0.2, spring(0.4, 0.8)) 0x2a160bd58), DraggableViewModifier
    /// (relative drag 0x2a160ab2c, rubber band 0x2a160ae98, stretch 0x2a160a180).
    static func scrubber() {
        typealias M = NowPlayingMetrics
        ok(M.capsuleHeight == 10, "capsuleHeight")
        ok(near(M.rubberBand(0.5), 0.5) && near(M.rubberBand(1.5), 1.02) && near(M.rubberBand(-0.5), -0.02), "rubberBand")
        ok(M.rubberBand(50) < 1.04 && M.rubberBand(50) > 1.039, "rubberBandLimit")
        let s = M.stretch(1.02)
        ok(near(Double(s.x), 1.02) && near(Double(s.y), 0.9) && s.anchor == .leading, "stretchRight")
        let l = M.stretch(-0.02)
        ok(near(Double(l.x), 1.02) && l.anchor == .trailing, "stretchLeft")
        ok(M.stretch(0.4).x == 1 && M.stretch(0.4).y == 1, "noStretchInside")

        let t0 = Date(timeIntervalSince1970: 1000)
        let m = NowPlayingModel()
        m.update(.init(info: NowPlayingInfo(title: "a", artist: nil, duration: 200, elapsed: 50, rate: 0, timestamp: t0,
                                            artwork: nil), isPlaying: false, bundleID: nil))
        let track = M.trackFrame(duration: 200)
        ok(track.minX > M.margin && track.maxX < M.expandedWidth - M.margin && track.height == 10, "trackFrame")
        ok(M.timelineHit(CGPoint(x: track.midX, y: track.midY)), "timelineHit")
        ok(!M.timelineHit(CGPoint(x: track.midX, y: track.midY + 30)), "timelineMissBelow")
        m.beginScrub(x: 100, now: t0)
        ok(near(m.scrub ?? -1, 0.25), "scrubStartsAtCurrentProgress")
        m.moveScrub(x: 100 + track.width * 0.25)
        ok(near(m.scrub ?? -1, 0.5), "scrubIsRelative")
        m.moveScrub(x: 100 + track.width * 2)
        ok(near(m.scrub ?? -1, M.rubberBand(2.25)) && near(m.scrubValue ?? -1, 1), "scrubOvershootRubberBands")
        m.moveScrub(x: 100 + track.width * 0.25)
        let seek = m.endScrub(now: t0)
        ok(near(seek ?? -1, 100) && m.scrub == nil, "scrubCommitsOnRelease")
        ok(near(m.info?.elapsed(at: t0.addingTimeInterval(5)) ?? -1, 100), "optimisticElapsedAfterSeek")
    }

    /// TransportControlDefaultStyle 0x2a163f3f4 / 0x2a163f6f8: press scale 0.8, highlight circle 1.5 / 1.75.
    static func transport() {
        typealias M = NowPlayingMetrics
        ok(M.pressedScale == 0.8 && M.highlightScale(pressed: true) == 1.5 && M.highlightScale(pressed: false) == 1.75,
           "pressMetrics")
        let m = NowPlayingModel()
        m.press(.nextTrack)
        ok(m.pressed == .nextTrack, "pressShowsHighlight")
        ok(m.release() == .nextTrack && m.pressed == nil && m.skipCount[.nextTrack] == 1, "releaseFiresAndBounces")
        ok(m.release() == nil, "releaseWithoutPress")

        packages()
        flip()
    }

    /// FlippingArtworkView (27.3): AnimatableFlipRotation 0x2a160de78 / 0x2a160da34, FlipModel.reactTo / flipEdge
    /// (log strings), reveal and glow 0x2a161315c, ArtworkGlowModifier 0x2a160e54c, ArtworkLegibilityModifier 0x2a160ec84.
    static func flip() {
        typealias M = NowPlayingMetrics
        // Shown angle = flipAngle - round(flipAngle / 180) * 180: the face turns edge-on, jumps to the other edge, lands.
        ok(M.flipDisplayAngle(0) == 0 && M.flipDisplayAngle(-81) == -81 && M.flipDisplayAngle(-100) == 80
           && M.flipDisplayAngle(-180) == 0 && M.flipDisplayAngle(270) == -90, "flipDisplayAngle")
        // The new image swaps in swapLead (0.05 x 180 = 9 degrees) before the midpoint, in the flip's direction.
        ok(M.flipSwapLead == 0.05, "flipSwapLead")
        ok(M.flipSwapFace(angle: -80, target: -180, lastFace: 0) == nil
           && M.flipSwapFace(angle: -81, target: -180, lastFace: 0) == -1, "flipSwapBackwardEdge")
        ok(M.flipSwapFace(angle: 80, target: 180, lastFace: 0) == nil
           && M.flipSwapFace(angle: 81, target: 180, lastFace: 0) == 1, "flipSwapForwardEdge")
        ok(M.flipSwapFace(angle: 0, target: 0, lastFace: 0) == nil, "flipSwapIdle")
        ok(M.flipPerspective == 0.1 && M.revealBlur == 15 && M.glowIntensity == 0.3, "flipConstants")
        // forward = -180, backward (after "previous", FlipDirectionTracker) = +180.
        ok(M.flipStep(backward: false) == -1 && M.flipStep(backward: true) == 1, "flipDirection")

        let a = NSImage(size: NSSize(width: 4, height: 4)), b = NSImage(size: NSSize(width: 4, height: 4))
        let c = NSImage(size: NSSize(width: 4, height: 4))
        var f = FlipModel()
        ok(f.react(to: a, backward: false) == .firstDraw && !f.isFlipping, "flipFirstDrawInPlace")
        ok(f.react(to: a, backward: false) == .unchanged, "flipSameImage")
        ok(f.react(to: b, backward: false) == .flip && f.targetFace == -1 && f.isFlipping, "flipNewImageStartsFlip")
        ok(f.react(to: c, backward: false) == .buffered && f.targetFace == -1, "flipMidFlipCoalesces")
        ok(f.edge(-1) === c && !f.isFlipping, "flipEdgeRevealsLatest")
        ok(f.edge(-1) == nil, "flipEdgeDuplicateIgnored")
        ok(f.react(to: a, backward: true) == .flip && f.targetFace == 0, "flipBackward")
        ok(f.react(to: nil, backward: false) == .placeholder && f.react(to: b, backward: false) == .firstDraw,
           "flipPlaceholderResetsSeed")

        // ArtworkLegibilityModifier color matrix: grey 0.402, alpha 0.198 - Rec.709 luminance.
        let lm = M.legibilityMatrix
        ok(lm.m15 == 0.402 && lm.m25 == 0.402 && lm.m35 == 0.402 && lm.m11 == 0 && lm.m22 == 0 && lm.m33 == 0
           && lm.m41 == -0.213 && lm.m42 == -0.715 && lm.m43 == -0.072 && lm.m44 == 0.198 && lm.m45 == 0, "legibilityMatrix")

        let m = NowPlayingModel(), t0 = Date(timeIntervalSince1970: 1000)
        ok(!m.flipsBackward(at: t0), "flipsForwardByDefault")
        m.press(.previousTrack)
        _ = m.release(now: t0)
        ok(m.flipsBackward(at: t0.addingTimeInterval(1)), "previousFlipsBackward")
        ok(!m.flipsBackward(at: t0.addingTimeInterval(M.flipBackwardTimeout + 0.1)), "backwardReverts")

        MainActor.assumeIsolated { flipRender() }
    }

    /// FlipRotation turns the face around y: 60 degrees leaves about cos 60 of its width, a half turn shows it flat.
    @MainActor static func flipRender() {
        func width(_ angle: Double) -> Int {
            let v = Color.white.frame(width: 40, height: 40)
                .modifier(FlipRotation(angle: angle, target: angle, lastFace: Int((angle / 180).rounded()), onMidFlip: { _ in }))
                .frame(width: 60, height: 60).background(Color.black)
            guard let cg = ImageRenderer(content: v).cgImage, let data = cg.dataProvider?.data as Data? else { return -1 }
            let row = cg.height / 2 * cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
            return (0..<cg.width).filter { data[row + $0 * bpp + 1] > 128 }.count
        }
        let flat = width(0), turned = width(-60), half = width(-180)
        ok(flat == 40 && half == 40 && abs(turned - 20) <= 3, "flipRenderNarrows (\(flat), \(turned), \(half))")

        // ArtworkLegibilityModifier: black artwork is lifted to grey 0.402 at alpha 0.198 (about 20 / 255), white stays.
        func centre(_ c: NSColor) -> Int {
            let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in c.setFill(); r.fill(); return true }
            let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])
            let m = NowPlayingModel()
            m.update(.init(info: NowPlayingInfo(title: "a", artist: nil, duration: nil, elapsed: 0, rate: 0, timestamp: Date(),
                                                artwork: png), isPlaying: true, bundleID: nil))
            let v = NowPlayingArtwork(model: m, side: 40, radius: 5).background(Color.black).environment(\.colorScheme, .dark)
            // The renderer may hand back extended-range float pixels: read the centre through an 8-bit sRGB context.
            guard let cg = ImageRenderer(content: v).cgImage else { return -1 }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: -cg.width / 2, y: -cg.height / 2, width: cg.width, height: cg.height))
            return Int(px[1])
        }
        let black = centre(.black), white = centre(.white)
        ok(abs(black - 20) <= 6 && white >= 250, "legibilityLiftsDarkArtwork (\(black), \(white))")
    }

    /// The animated glyphs are the system's own MediaCoreUI packages (macOS 26.6 ships NowPlaying.PlayPauseStop.ca and
    /// NowPlaying.ForwardBackward.ca), driven by CAStateController like 27.3 PackageView, patched to the 27.3 values.
    static func packages() {
        guard let pp = PackageGlyph(.playPause), let fb = PackageGlyph(.nextPrevious) else {
            ok(false, "systemPackagesLoad")
            return
        }
        ok(pp.stateNames == ["play", "pause", "stop"], "playPauseStates (\(pp.stateNames))")
        ok(fb.stateNames == ["State 1", "State 2", "State 3", "State 4"], "nextPreviousStates (\(fb.stateNames))")
        // 27.3 PlayPauseStop.caar: root sublayerTransform 0.97 in 'play', 0.93 in 'pause', nothing on 'origin'.
        ok(pp.stateValue("play", "Root Layer", "sublayerTransform.scale.xy") == 0.97
           && pp.stateValue("pause", "Root Layer", "sublayerTransform.scale.xy") == 0.93, "playPausePatchedTo27_3")
        ok(!pp.stateTargets.contains("origin"), "playPauseNoOriginScale")
        // The glyph through every layer transform (root sublayerTransform included, as on screen) times the package
        // scale. ControlCenter 2026-11-23 with scale 1.05 showed the pause 22 x 29 where footage has 20.4 x 27.4.
        func glyphSize(_ state: String) -> CGSize {
            pp.setState(state, animated: false)
            guard let shape = pp.layer(named: "path-\(state)-tint-shape") as? CAShapeLayer, let path = shape.path else { return .zero }
            let s = NowPlayingMetrics.packageScale(.playPause), r = shape.convert(path.boundingBoxOfPath, to: pp.root)
            return CGSize(width: r.width * s, height: r.height * s)
        }
        let pause = glyphSize("pause"), play = glyphSize("play")
        ok(near(pause.height, 27.4, 0.3) && near(pause.width, 20.4, 0.4), "pauseGlyphOnScreen (\(pause))")
        // [?] play is 29.2 tall in the 778.5 s footage: the one scale cannot fit both states; it stays within 1.2.
        ok(near(play.height, 29.2, 1.2), "playGlyphOnScreen (\(play))")
        // 27.3 ForwardBackward.caar origin scale 0.333 (26.6: 0.86).
        ok(near(Double(fb.originScale), 0.333), "nextPreviousOriginScale")
        pp.setState("pause", animated: false)
        ok(pp.layerValue("pause shape", "opacity") == 1 && pp.layerValue("play shape", "opacity") == 0, "playPauseSetState")
        // PackageAsset.scale 2.6 for both (0x2a15fea40, 0x2a15fcdd0); how CAPackageViewLayer maps the 84 canvas is not
        // read [?], so the on-screen scale per package comes from footage (expandedLayout).
        ok(NowPlayingMetrics.packageScale(.playPause) > NowPlayingMetrics.packageScale(.nextPrevious), "packageScale")
        ok(NowPlayingMetrics.nextPreviousState(taps: 0) == "State 1" && NowPlayingMetrics.nextPreviousState(taps: 5) == "State 2",
           "nextPreviousCycle")
    }

    private static func ok(_ c: Bool, _ name: String) { expect(c, "nowPlaying." + name) }

    static func parse() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let info = NowPlayingInfo(mediaRemote: [
            "kMRMediaRemoteNowPlayingInfoTitle": "Song",
            "kMRMediaRemoteNowPlayingInfoArtist": "Artist",
            "kMRMediaRemoteNowPlayingInfoDuration": 200.0,
            "kMRMediaRemoteNowPlayingInfoElapsedTime": 30.0,
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1.0,
            "kMRMediaRemoteNowPlayingInfoTimestamp": t0,
            "kMRMediaRemoteNowPlayingInfoArtworkData": Data([1, 2, 3]),
        ])
        ok(info?.title == "Song" && info?.artist == "Artist", "parseText")
        ok(info?.duration == 200 && info?.elapsed == 30 && info?.rate == 1 && info?.timestamp == t0, "parseTiming")
        ok(info?.artwork == Data([1, 2, 3]), "parseArtwork")
        ok(NowPlayingInfo(mediaRemote: [:]) == nil, "parseEmptyIsNil")
        // No timestamp: elapsed is taken as of now; no duration: nil.
        let bare = NowPlayingInfo(mediaRemote: ["kMRMediaRemoteNowPlayingInfoTitle": "Live"])
        ok(bare?.duration == nil && bare?.elapsed == 0 && bare?.rate == 0, "parseDefaults")
    }

    static func interpolation() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let i = NowPlayingInfo(title: "a", artist: nil, duration: 100, elapsed: 10, rate: 1, timestamp: t0, artwork: nil)
        ok(near(i.elapsed(at: t0.addingTimeInterval(5)), 15), "elapsedAdvancesWithRate")
        ok(near(i.elapsed(at: t0.addingTimeInterval(500)), 100), "elapsedClampedToDuration")
        var paused = i; paused.rate = 0
        ok(near(paused.elapsed(at: t0.addingTimeInterval(5)), 10), "elapsedFrozenWhenPaused")
        var fast = i; fast.rate = 2
        ok(near(fast.elapsed(at: t0.addingTimeInterval(5)), 20), "elapsedUsesRate")
        ok(near(i.progress(at: t0.addingTimeInterval(40)), 0.5), "progress")
    }

    static func timeLabels() {
        ok(NowPlayingInfo.label(42) == "0:42", "labelSeconds")
        ok(NowPlayingInfo.label(198) == "3:18", "labelMinutes")
        ok(NowPlayingInfo.label(3725) == "1:02:05", "labelHours")
        // Remaining time uses U+2212: the dash is 5.6 pt wide at caption2 in drlYGnbWurM 775.9 s (a hyphen is ~3).
        ok(NowPlayingInfo.label(-198) == "\u{2212}3:18", "labelRemaining")
    }

    static func presence() {
        var p = NowPlayingPresence()
        ok(p.mode == nil, "hiddenWithoutTrack")
        p.update(hasTrack: true, isPlaying: true, now: 0)
        ok(p.mode == .compact, "compactWhilePlaying")
        p.toggleExpanded()
        ok(p.mode == .expanded, "clickExpands")
        p.toggleExpanded()
        ok(p.mode == .compact, "clickCollapses")
        p.update(hasTrack: true, isPlaying: false, now: 10)
        p.tick(now: 10 + NowPlayingPresence.pausedHideDelay - 0.1)
        ok(p.mode == .compact, "pausedStaysBriefly")
        p.tick(now: 10 + NowPlayingPresence.pausedHideDelay)
        ok(p.mode == nil, "pausedHidesAfterDelay")
        // User setting (2026-11-26): a paused track keeps the island for 10 minutes.
        var q = NowPlayingPresence()
        q.update(hasTrack: true, isPlaying: true, now: 0)
        q.update(hasTrack: true, isPlaying: false, now: 0)
        q.tick(now: 9 * 60)
        ok(q.mode == .compact, "pausedStaysNineMinutes")
        q.tick(now: 10 * 60)
        ok(q.mode == nil, "pausedHidesAtTenMinutes")
        p.update(hasTrack: true, isPlaying: true, now: 20)
        ok(p.mode == .compact, "resumeShowsAgain")
        p.toggleExpanded()
        p.update(hasTrack: true, isPlaying: false, now: 22)
        p.tick(now: 22 + NowPlayingPresence.pausedHideDelay + 1)
        ok(p.mode == .expanded, "expandedNotHiddenWhilePaused")
        p.update(hasTrack: false, isPlaying: false, now: 30)
        ok(p.mode == nil, "noTrackHides")
    }

    static func waveform() {
        // 16 x 16, six bars: bw = 16 * 0.125 * 5/6 = 1.6667, slot 1.8, spacing (16 - 10.8) / 5 = 1.04.
        let w = NowPlayingMetrics.waveformBars(side: 16, values: [0, 1, 0.5, 0, 0, 0], scale: 2)
        ok(w.count == 6, "sixBars")
        ok(near(Double(w[0].width), 16 * 0.125 * 5 / 6) && near(Double(w[0].height), 16 * 0.125 * 5 / 6), "restBarIsDot")
        ok(near(Double(w[0].minX), (1.8 - 16 * 0.125 * 5 / 6) / 2), "firstBarCenteredInSlot")
        ok(near(Double(w[1].height), 16) && near(Double(w[1].width), 1.12 * 16 * 0.125 * 5 / 6), "fullBar")
        ok(near(Double(w[1].midX), 1.8 + 1.04 + 0.9), "secondBarSlot")
        ok(near(Double(w[2].height), 8) && near(Double(w[2].midY), 8), "halfBarCentered")
        ok(near(Double(w[5].maxX), 16 - (1.8 - Double(w[5].width)) / 2), "lastBarEndsAtEdge")
        // Level without an audio tap = MediaCoreUI BouncyBars.caar (canned fallback): per bar a keyframed
        // bounds.size.height (% of the frame), duration 2.66 s, repeat forever, calculationMode cubic; variant A row 0 is
        // [49, 51, 42.9, 78.9, ...] at keyTimes [0, 0.091, 0.1818, 0.273, ...].
        typealias M = NowPlayingMetrics
        ok(M.bouncePeriod == 2.66, "bouncePeriod")
        ok(near(M.bounce(0, bar: 0, variant: 0), 0.49) && near(M.bounce(0.091 * 2.66, bar: 0, variant: 0), 0.51)
           && near(M.bounce(2.66 + 0.4545 * 2.66, bar: 0, variant: 0), 0.31), "bounceHitsKeyframes")
        ok(near(M.bounce(0, bar: 0, variant: 1), 0.40) && near(M.bounce(0, bar: 0, variant: 2), 0.33), "bounceVariantsPermuteRows")
        ok(near(M.bounce(1.234, bar: 3, variant: 0), M.bounce(1.234 + 2.66, bar: 3, variant: 0)), "bounceRepeats")
        let samples = stride(from: 0.0, to: 10.64, by: 1.0 / 30).map { t in (0..<6).map { M.bounce(t, bar: $0, variant: 0) } }
        ok(samples.allSatisfy { $0.allSatisfy { (0.2...1).contains($0) } }, "bounceRange")
        // Footage (PROLED review, expanded, live FFT): about 1.9 peaks per second per bar. Canned rows: 3-5 peaks per 2.66 s.
        var peaks = [Int](repeating: 0, count: 6)
        for k in 1..<(samples.count - 1) { for i in 0..<6 where samples[k][i] > samples[k - 1][i] && samples[k][i] >= samples[k + 1][i] { peaks[i] += 1 } }
        ok(peaks.allSatisfy { (1.0...2.2).contains(Double($0) / 10.64) }, "bounceSpeedLikeFootage (\(peaks))")
    }

    static func treatment() {
        let dark = ArtworkTreatment(luminance: 0.2)
        // MediaCoreUI 0x2268246cc: saturation 1.25 baseline, + 4 (0.6 - L) when lightening.
        ok(near(dark.lightening, 0.4) && dark.darkening == 0 && near(dark.saturation, 2.85), "treatmentDark")
        let mid = ArtworkTreatment(luminance: 0.65)
        ok(mid.lightening == 0 && mid.darkening == 0 && mid.saturation == 1.25, "treatmentNeutral")
        let light = ArtworkTreatment(luminance: 0.9)
        ok(near(light.darkening, 0.2) && light.lightening == 0 && light.saturation == 1.25, "treatmentLight")
        ok(ArtworkTreatment(luminance: 0) == ArtworkTreatment.neutral, "treatmentInvalidIsNeutral")
    }

    /// Minimal (27.3): IntegratedViewGroup_V1 gets (Leading, Leading, Trailing, Expanded) surfaces and the minimal closure
    /// 0x2a166757c is `b 0x2a1667414` (the compact-leading one): minimal = the artwork, same view for split primary and
    /// adjunct. NowPlayingLeadingActivitySurface (0x2a166ac4c) only branches on the obstruction the host sends:
    /// non-zero -> artwork 20, padding 4, radius 5, placeholder 10; zero -> 16, 5, 3, 9.
    @MainActor static func minimal() {
        typealias M = NowPlayingMetrics
        let o = M.leadingArtwork(obstructed: true), n = M.leadingArtwork(obstructed: false)
        ok(o.side == 20 && o.padding == 4 && o.radius == 5 && o.placeholder == 10, "leadingArtworkObstructed")
        ok(n.side == 16 && n.padding == 5 && n.radius == 3 && n.placeholder == 9, "leadingArtworkUnobstructed")
        ok(M.minimalSize(sensorHeight: 34, obstructed: true) == CGSize(width: 28, height: 34)
           && M.minimalSize(sensorHeight: 34, obstructed: false) == CGSize(width: 26, height: 34), "minimalSize")
        ok(M.minimalSize(sensorHeight: 34, obstructed: true) == M.compactLeadingSize(sensorHeight: 34), "minimalIsCompactLeading")
        let model = NowPlayingModel()
        func fit<V: View>(_ v: V) -> CGSize { NSHostingController(rootView: v).sizeThatFits(in: CGSize(width: 500, height: 500)) }
        ok(fit(NowPlayingMinimal(model: model, sensorHeight: 34, obstructed: false)) == CGSize(width: 26, height: 34)
           && fit(NowPlayingMinimal(model: model, sensorHeight: 34)) == CGSize(width: 28, height: 34), "minimalViewSize")
    }

    static func metrics() {
        MainActor.assumeIsolated { minimal() }
        ok(NowPlayingMetrics.compactLeadingSize(sensorHeight: 34) == CGSize(width: 28, height: 34), "compactLeadingSize")
        ok(NowPlayingMetrics.compactTrailingSize(sensorHeight: 34) == CGSize(width: 24, height: 34), "compactTrailingSize")
        ok(NowPlayingMetrics.expandedWidth == 286, "expandedWidth")
        let h = NowPlayingMetrics.expandedHeight
        ok(h > 91 && h <= 160, "expandedHeightInHIGRange (\(h))")
        // Controls row y = 16 + 50 + 12 + 15 + 15 = 108...137. Each TransportControl is as wide as its glyph (a hidden
        // Image sizes it), spaced 45: centers are glyph-width dependent, the row is centered in 286.
        let y = 121.0
        for playing in [true, false] {
            let c = NowPlayingMetrics.controlCenters(isPlaying: playing)
            let side = NowPlayingMetrics.glyphWidth(NowPlayingMetrics.playPauseSymbol(playing), NowPlayingMetrics.centerControlFont) / 2
                + NowPlayingMetrics.controlSpacing + NowPlayingMetrics.glyphWidth("backward.fill", NowPlayingMetrics.controlFont) / 2
            ok(near(c[1], 143) && near(c[0] + c[2], 286) && near(c[2] - c[1], side), "controlCentersFromGlyphs(\(playing))")
            ok(NowPlayingMetrics.control(at: CGPoint(x: c[1], y: y), isPlaying: playing) == .togglePlayPause, "hitPlayPause(\(playing))")
            ok(NowPlayingMetrics.control(at: CGPoint(x: c[0], y: y), isPlaying: playing) == .previousTrack, "hitPrevious(\(playing))")
            ok(NowPlayingMetrics.control(at: CGPoint(x: c[2], y: y), isPlaying: playing) == .nextTrack, "hitNext(\(playing))")
        }
        ok(NowPlayingMetrics.glyphWidth("backward.fill", 24) > 24, "glyphWiderThanPointSize")
        ok(NowPlayingMetrics.control(at: CGPoint(x: 143, y: 30), isPlaying: true) == nil, "hitOutsideControls")
        ok(NowPlayingMetrics.control(at: CGPoint(x: 20, y: y), isPlaying: true) == nil, "hitBesideControls")
    }

    /// The island is always black: the compact placeholder must be visible whatever the host's appearance is.
    @MainActor static func placeholder() {
        let model = NowPlayingModel()
        model.update(.init(info: NowPlayingInfo(title: "a", artist: nil, duration: nil, elapsed: 0, rate: 0, timestamp: Date(),
                                                 artwork: nil), isPlaying: false, bundleID: nil))
        let view = NowPlayingCompactLeading(model: model, sensorHeight: 34).environment(\.colorScheme, .light)
            .background(Color.black)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let img = r.cgImage else { ok(false, "placeholderRenders"); return }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Sample the artwork square's corner area (inside the rounded rect, away from the glyph): x 4+3, y 7+3.
        ctx.draw(img, in: CGRect(x: -7, y: -(CGFloat(img.height) - 10 - 1), width: CGFloat(img.width), height: CGFloat(img.height)))
        ok(px[0] > 25, "compactPlaceholderVisibleOnBlack (\(px[0]))")
    }

    static func mediaRemote() {
        // Read-only: resolving symbols sends nothing and changes nothing.
        ok(MediaRemote.shared != nil, "mediaRemoteSymbolsResolve")
        ok(MediaRemote.shared?.setElapsedTime != nil, "mediaRemoteSeekResolves")
    }
}
