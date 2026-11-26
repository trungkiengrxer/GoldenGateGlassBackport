// Window-free tests for the AirDrop compact views (island/Sources/AirDropViews.swift).
// Expected values are computed by hand from docs/RE-27-BEHAVIOR.md section 21 (27.3 AirDropUI and its
// airdrop-progress.ca package). Own executable (own @main) so it needs no hook in tests.swift.
import AppKit
import Foundation
import SwiftUI

private var failures = 0
private func ok(_ c: Bool, _ name: String) { print(c ? "OK   airdrop.\(name)" : "FAIL airdrop.\(name)"); if !c { failures += 1 } }
private func near(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) <= eps }

@main enum AirDropTests {
    static func main() {
        sizes()
        ring()
        count()
        colors()
        MainActor.assumeIsolated { renders(); expanded(); animation() }
        exit(failures == 0 ? 0 : 1)
    }

    /// airdrop-progress.ca state transitions: CASpringAnimation mass 2, stiffness 300, damping 50 (main.caml).
    /// AirDropSystemApertureProgress is a Button(action: cancel) in 27.3: the views take the cancel closure.
    @MainActor static func animation() {
        ok(M.stateSpring == .interpolatingSpring(mass: 2, stiffness: 300, damping: 50), "stateSpring")
        // To compact-done / zoom-done (main.caml): `saving` (#7) scale 1 -> 2.405 on a damping-20 spring; check (#6)
        // blur 37.5 -> 0, line 25.4 -> 29.1 (zoom 26), blue (0.04465, 0.6083, 1.002) -> 0.9726; stop button blur 0 -> 25.
        ok(M.checkSpring == .interpolatingSpring(mass: 2, stiffness: 300, damping: 20), "checkSpring")
        ok(near(M.checkStartScale, 1 / 2.405) && M.checkAnchor == UnitPoint(x: 75.672157287597 / 150, y: 75.299247741699 / 150),
           "checkScale")
        ok(near(M.checkBlurRatio, 37.5 * 0.175 * 2.405 / 3 / 50) && near(M.checkStartLineRatio, 25.4 * 0.175 * 2.405 / 3 / 50)
           && M.checkBlueRGB == (0.04465, 0.6083, 1.002), "checkStart")
        ok(near(M.stopBlurRatio, 25.0 / 3 / 50), "stopBlur")
        var tapped = 0
        let t = AirDropCompactTrailing(progress: half, onCancel: { tapped += 1 })
        t.onCancel?()
        let e = AirDropExpandedProgress(progress: half, subtitle: nil, onCancel: { tapped += 1 })
        e.onCancel?()
        ok(tapped == 2 && AirDropCompactTrailing(progress: half).onCancel == nil, "cancelHook")
        let r = ImageRenderer(content: AirDropCompactTrailing(progress: half, onCancel: {}).frame(height: 34))
        r.scale = 1
        ok(r.cgImage.map { $0.width == 24 && $0.height == 34 } ?? false, "cancelButtonKeepsSize")
    }

    typealias M = AirDropMetrics
    static let half = AirDropProgress(fraction: 0.5, itemCount: 1, isFinished: false)

    /// Leading 2 + 18 + 2 (0x1000899d4), trailing 2 + 20 + 2 (0x10008a3c4, 0x10008a590).
    static func sizes() {
        ok(M.compactLeadingSize(sensorHeight: 34) == CGSize(width: 22, height: 34), "leadingSize")
        ok(M.compactTrailingSize(sensorHeight: 34) == CGSize(width: 24, height: 34), "trailingSize")
        ok(M.iconSize == 18 && M.ringSize == 20 && M.padding == 2, "constants")
        // Private symbol on 26.6: imageWithPrivateSystemSymbolName (systemSymbolName returns nil).
        let sel = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
        ok(NSImage.perform(sel, with: M.symbol)?.takeUnretainedValue() is NSImage, "privateSymbolExists")
    }

    /// strokeStart = 0.999 - max(fraction, 0.01) (0x1000395d8); root 50: diameter 43.8, line 15.6 * 0.366 = 5.71,
    /// compact-done line 10.6 * 0.366 = 3.88.
    static func ring() {
        ok(near(M.strokeStart(0.5), 0.499) && near(M.strokeStart(0), 0.989) && M.strokeStart(1) == 0, "strokeStart")
        ok(near(M.diameterRatio, 0.876) && near(M.lineRatio(done: false), 0.1142) && near(M.lineRatio(done: true), 0.0776),
           "ringRatios")
        // Check mark: first point (15.242, 26.069), last (33.847, 16.553) of 50, y down.
        ok(near(M.checkPoints.first!.x, 15.242 / 50) && near(M.checkPoints.last!.y, 16.553 / 50) && M.checkPoints.count == 6,
           "checkPoints")
        ok(near(M.checkLineRatio, 4.0825 / 50), "checkLine")
        // currentMicaState 0x1000a128c: compact-done when fractionCompleted >= 1 (0x1000a1448), not on a finished flag.
        ok(M.isDone(AirDropProgress(fraction: 1, itemCount: 1, isFinished: false))
           && !M.isDone(AirDropProgress(fraction: 0.99, itemCount: 1, isFinished: false)), "doneAtFullFraction")
        // The count overlay (0x1000a035c) has no state check: it stays over the compact-done check mark.
        ok(M.showsCount(AirDropProgress(fraction: 1, itemCount: 3, isFinished: true)), "countKeptWhenDone")
    }

    /// Count overlay when itemCount >= 2 (0x1000a035c), frame 0.6 s (0x1000a0528).
    static func count() {
        ok(!M.showsCount(half) && M.showsCount(AirDropProgress(fraction: 0.5, itemCount: 2, isFinished: false)), "showsCount")
        ok(M.countText(12) == "12", "countText")
        ok(M.countFrame == 12, "countFrame")
    }

    static func colors() {
        ok(M.iconRGB == (0.043, 0.608, 1.0), "iconColor")
        ok(M.trackRGB == (-0.07883, 0.1984, 0.433), "trackColor")
        ok(M.fillRGB(done: false) == (0.04583, 0.6083, 1.002) && M.fillRGB(done: true) == (1, 1, 1), "fillColor")
        ok(M.checkWhite == 0.9726, "checkColor")
    }

    @MainActor static func renders() {
        func image<V: View>(_ v: V, scale: CGFloat = 1) -> CGImage? {
            let r = ImageRenderer(content: v)
            r.scale = scale
            return r.cgImage
        }
        func size(_ i: CGImage?) -> String { i.map { "\($0.width)x\($0.height)" } ?? "nil" }
        let lead = image(AirDropCompactLeading().frame(height: 34))
        ok(size(lead) == "22x34", "renders.leading (\(size(lead)))")
        // Minimal = the compactLeading closure (0x10008df5c -> 0x100089994): icon 18 + padding 2, no ring, no session
        // input, so primary and adjunct draw the same 22 x H.
        let minimal = image(AirDropMinimal().frame(height: 34))
        ok(size(minimal) == "22x34" && M.minimalSize(sensorHeight: 34) == CGSize(width: 22, height: 34)
           && M.minimalSize(sensorHeight: 34).width <= 45, "renders.minimal (\(size(minimal)))")
        ok(minimal?.dataProvider?.data == lead?.dataProvider?.data && minimal != nil, "renders.minimalIsLeadingIcon")
        let trail = image(AirDropCompactTrailing(progress: half).frame(height: 34))
        ok(size(trail) == "24x34", "renders.trailing (\(size(trail)))")
        let many = image(AirDropCompactTrailing(progress: AirDropProgress(fraction: 0.3, itemCount: 3, isFinished: false)).frame(height: 34))
        ok(size(many) == "24x34", "renders.trailingCount (\(size(many)))")

        // Fill grows clockwise from 12 o'clock [I]: at 25 % the ring is blue at 1:30 and track-coloured at 9 o'clock.
        func pixel(_ i: CGImage, _ x: Int, _ y: Int) -> (Double, Double, Double, Double)? {
            // colorAt uses a top-left origin.
            guard let c = NSBitmapImageRep(cgImage: i).colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        }
        let s = 10.0, r = 20 * M.diameterRatio / 2 * s, c = 10 * s   // ring alone, 20 pt at 10x: centre line radius
        func at(_ img: CGImage?, deg: Double) -> (Double, Double, Double, Double)? {
            img.flatMap { pixel($0, Int(c + r * sin(deg * .pi / 180)), Int(c - r * cos(deg * .pi / 180))) }
        }
        let quarter = image(AirDropRing(progress: AirDropProgress(fraction: 0.25, itemCount: 1, isFinished: false)), scale: s)
        let blue = at(quarter, deg: 45), track = at(quarter, deg: 270)
        ok(blue.map { $0.2 > 0.8 && $0.0 < 0.3 } ?? false, "ring.fillAt45 \(String(describing: blue))")
        ok(track.map { $0.2 > 0.3 && $0.2 < 0.6 && $0.1 < 0.35 } ?? false, "ring.trackAt270 \(String(describing: track))")
        let done = image(AirDropRing(progress: AirDropProgress(fraction: 1, itemCount: 1, isFinished: false)), scale: s)
        let white = at(done, deg: 200)
        ok(white.map { $0.0 > 0.9 && $0.1 > 0.9 && $0.2 > 0.9 } ?? false, "ring.doneWhite \(String(describing: white))")
    }

    /// Expanded rows (RE-27-BEHAVIOR 21.2.1 - 21.2.4): width 274 for a single in-flight or received transfer
    /// (0x1000891b8), ProgressView insets (11, 16, 11, 11) / minHeight 60 / ring 38, ReadyForOpen padding 16 / icon 32 x 27.
    @MainActor static func expanded() {
        ok(M.expandedWidth == 274, "expanded.width")
        ok(M.progressInsets == EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 11) && M.progressMinHeight == 60
           && M.expandedRingSize == 38 && M.progressSpacing == 8, "expanded.progressMetrics")
        // zoom: line 13.1, zoom-done 7.7, check 26 (x 0.175 x 2.405 / 3), stop 48 x 1.05 / 3 corner 13 x 1.05 / 3; over 50.
        ok(near(M.zoomLineRatio(done: false), 0.0959) && near(M.zoomLineRatio(done: true), 0.0564), "expanded.zoomLines")
        ok(near(M.zoomCheckLineRatio, 3.6475 / 50) && near(M.stopSideRatio, 16.8 / 50) && near(M.stopCornerRatio, 4.55 / 50),
           "expanded.zoomShapes")
        ok(M.readyPadding == 16 && M.readyIconSize == CGSize(width: 32, height: 27) && M.readySpacing == 12 && M.readyTextPadding == 4,
           "expanded.readyMetrics")
        ok(M.progressTitle == "AirDrop", "expanded.title")
        ok(M.openTitle(language: "en") == "Open" && M.openTitle(language: "vi") == "Mở", "expanded.openTitle")

        func image<V: View>(_ v: V, scale: CGFloat = 1) -> CGImage? {
            let r = ImageRenderer(content: v)
            r.scale = scale
            return r.cgImage
        }
        func pixel(_ i: CGImage?, _ x: Double, _ y: Double) -> (Double, Double, Double, Double)? {
            guard let i, let c = NSBitmapImageRep(cgImage: i).colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return nil }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        }
        func size(_ i: CGImage?) -> CGSize? { i.map { CGSize(width: $0.width, height: $0.height) } }

        // Sizes: width 274, height from content; the rendered view matches the metrics.
        let p = AirDropProgress(fraction: 0.25, itemCount: 1, isFinished: false)
        let ps = M.expandedProgressSize(progress: p, subtitle: "12 MB of 40 MB")
        ok(ps.width == 274 && ps.height >= 60, "expanded.progressSize (\(ps))")
        let pr = size(image(AirDropExpandedProgress(progress: p, subtitle: "12 MB of 40 MB")))
        ok(pr == CGSize(width: 274, height: ceil(ps.height)), "expanded.progressRenders (\(String(describing: pr)))")
        let rs = M.expandedReadyForOpenSize(title: "Received photo.jpg", subtitle: "From Kien")
        ok(rs.width == 274 && rs.height >= 16 + 27 + 16, "expanded.readySize (\(rs))")
        let rr = size(image(AirDropExpandedReadyForOpen(title: "Received photo.jpg", subtitle: "From Kien", onOpen: {})))
        ok(rr == CGSize(width: 274, height: ceil(rs.height)), "expanded.readyRenders (\(String(describing: rr)))")

        // Title: environment(\.lineLimit, 1) + truncationMode(.tail) (21.2.3), so a long received name stays on one line
        // and the card keeps the one-line height: 16 + 4 + headline + body + 4 + 16, 80 on 26.6 where .leading(.tight)
        // lines are 20 pt; <= 91, so a capsule (pill) under the automatic shape too.
        let short = M.expandedReadyForOpenSize(title: "Received", subtitle: "From Unknown")
        let long = M.expandedReadyForOpenSize(title: "Received GG 2.MOV", subtitle: "From Unknown")
        let longer = M.expandedReadyForOpenSize(title: "Received " + String(repeating: "Holiday video ", count: 6), subtitle: "From Unknown")
        ok(long.height == short.height && longer.height == short.height && short.height <= 91,
           "expanded.readyTitleOneLine (\(short.height), \(long.height), \(longer.height))")
        // The ReadyForOpen subtitle (.sender) has no line limit: it wraps.
        let wrap = M.expandedReadyForOpenSize(title: "Received", subtitle: "From " + String(repeating: "Somebody ", count: 8))
        ok(wrap.height > short.height, "expanded.readySubtitleWraps (\(wrap.height))")
        // ProgressView subtitle: LineConfiguration lineLimit 2 (21.2.3); title one line.
        let one = M.expandedProgressSize(progress: p, subtitle: "12 MB")
        let two = M.expandedProgressSize(progress: p, subtitle: String(repeating: "12 MB of 40 MB ", count: 4))
        let many = M.expandedProgressSize(progress: p, subtitle: String(repeating: "12 MB of 40 MB ", count: 12))
        ok(two.height > one.height && many.height == two.height, "expanded.progressSubtitleTwoLines (\(one.height), \(two.height), \(many.height))")

        // Open button: top-right inside the 16 padding, top-aligned in the HStack(.top).
        let b = M.openButtonFrame(in: rs)
        ok(near(b.maxX, 274 - 16) && near(b.minY, 16) && b.size == M.openButtonSize(), "expanded.openButtonFrame (\(b))")

        // AirDropUIButtonStyle(.jindoDefault, .hugging), RE-27-BEHAVIOR 21.2.5: body font, padding (10, 16, 10, 16),
        // lineLimit 1, minimumScaleFactor 0.7, Capsule sRGB gray 0.302, white label, pressed opacity 0.8.
        ok(M.openButtonInsets == EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16) && M.openButtonMinScale == 0.7
           && M.openButtonGray == 0.302 && M.openButtonPressedOpacity == 0.8, "expanded.openButtonStyle")
        let body = NSFont.preferredFont(forTextStyle: .body)
        ok(M.openButtonFont.pointSize == body.pointSize && M.openButtonFont.fontName == body.fontName, "expanded.openButtonFont")
        let tw = ceil(("Open" as NSString).size(withAttributes: [.font: body]).width)
        let os = M.openButtonSize(language: "en")
        ok(os.width == tw + 32 && os.height >= 20 + body.pointSize, "expanded.openButtonSize (\(os))")
        // Natural size (no frame in 27.3) at 1x, as the island lays it out, matches the hit-test metrics.
        let fit = NSHostingView(rootView: AirDropOpenButton(title: "Open", action: {})).fittingSize
        ok(fit == os, "expanded.openButtonRenders (\(fit))")
        let bs = 4.0
        let bshot = image(AirDropOpenButton(title: "Open", action: {}), scale: bs)
        // Top centre of the capsule (sRGB gray 0.302 = byte 77); the label sits in the vertical middle. The image is
        // already sRGB, so read the raw components (usingColorSpace(.sRGB) on calibrated RGB shifts 0.302 to 0.375).
        let fillPx = bshot.flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: Int(os.width / 2 * bs), y: Int(2 * bs)) }
            .map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)) }
        ok(fillPx.map { near($0.0, 0.302, 0.02) && near($0.2, 0.302, 0.02) && $0.3 > 0.99 } ?? false,
           "expanded.openButtonFill \(String(describing: fillPx))")

        // Ring 38 at the right: blue fill at 1:30 for 25 %, blue stop square in the centre; zoom-done is white.
        let s = 4.0, cx = (274 - 11 - 19) * s, cy = ps.height / 2 * s, rad = 19 * M.diameterRatio * s
        let shot = image(AirDropExpandedProgress(progress: p, subtitle: "12 MB of 40 MB").background(Color.black), scale: s)
        let fill = pixel(shot, cx + rad * sin(.pi / 4), cy - rad * cos(.pi / 4)), stop = pixel(shot, cx, cy)
        ok(fill.map { $0.2 > 0.8 && $0.0 < 0.3 } ?? false, "expanded.ringFill \(String(describing: fill))")
        ok(stop.map { $0.2 > 0.8 && $0.0 < 0.3 } ?? false, "expanded.stopSquare \(String(describing: stop))")
        let done = AirDropProgress(fraction: 1, itemCount: 1, isFinished: true)
        let dh = M.expandedProgressSize(progress: done, subtitle: nil).height
        let dshot = image(AirDropExpandedProgress(progress: done, subtitle: nil).background(Color.black), scale: s)
        let white = pixel(dshot, cx - rad, dh / 2 * s)
        ok(white.map { $0.0 > 0.9 && $0.1 > 0.9 && $0.2 > 0.9 } ?? false, "expanded.zoomDoneWhite \(String(describing: white))")

        // Cancel hit rects (the Button wraps only the icon frame(s, s), 0x10009fb88; padding stays outside).
        // Expanded: right inset 11, 38 x 38, centred in the HStack(.center); the stop square sits at its centre.
        let er = M.expandedRingFrame(in: ps)
        ok(er == CGRect(x: 274 - 11 - 38, y: (ps.height - 38) / 2, width: 38, height: 38), "expanded.ringFrame (\(er))")
        let mid = pixel(shot, er.midX * s, er.midY * s)
        ok(mid.map { $0.2 > 0.8 && $0.0 < 0.3 } ?? false, "expanded.ringFrameOnStop \(String(describing: mid))")
        // Compact trailing 2 + 20 + 2 (0x10008a3c4, 0x10008a590): ring 20 x 20 at x 2, vertically centred.
        let cr = M.compactRingFrame(trailingSize: M.compactTrailingSize(sensorHeight: 34))
        ok(cr == CGRect(x: 2, y: 7, width: 20, height: 20), "compact.ringFrame (\(cr))")
        let cshot = image(AirDropCompactTrailing(progress: p).frame(height: 34).background(Color.black), scale: s)
        let top = pixel(cshot, cr.midX * s, (cr.minY + 20 * (1 - M.diameterRatio) / 2 + 0.5) * s)
        ok(top.map { $0.2 > 0.8 } ?? false, "compact.ringFrameOnRing \(String(describing: top))")
    }
}
