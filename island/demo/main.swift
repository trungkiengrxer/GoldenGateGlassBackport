// IslandDemo: M1 test app for the 27.3 island on 26.6. Modes:
//   shots  show every state, wait until the display link pauses, capture the panel to PNG ($OUT, default <build>/shots)
//          and compare the opaque area with the computed shape; prints OK/FAIL, exit status = failures.
//   live   cycle the states every 3 s for 90 s; click the island to expand/collapse, click elsewhere to collapse.
//   nowplaying  Now Playing with a fake track (compact, expanded, paused), captured like shots.
import AppKit

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "live"
let outDir = ProcessInfo.processInfo.environment["OUT"]
    ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("shots").path
var failures = 0
func expect(_ c: Bool, _ m: String) { print(c ? "OK   \(m)" : "FAIL \(m)"); if !c { failures += 1 } }

func symbol(_ name: String, _ side: CGFloat = 26) -> NSView {
    let v = NSImageView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: side * 0.7, weight: .semibold))
    v.contentTintColor = .white
    return v
}

func card(_ title: String) -> NSView {
    let v = NSView(frame: CGRect(x: 0, y: 0, width: 250, height: 84))
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 17, weight: .semibold)
    label.textColor = .white
    label.sizeToFit()
    let icon = symbol("music.note", 32)
    let w = icon.frame.width + 10 + label.frame.width
    icon.frame.origin = CGPoint(x: (v.bounds.width - w) / 2, y: (v.bounds.height - icon.frame.height) / 2)
    label.frame.origin = CGPoint(x: icon.frame.maxX + 10, y: (v.bounds.height - label.frame.height) / 2)
    for s in [icon, label] { s.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]; v.addSubview(s) }
    return v
}

let states: [(String, () -> IslandState)] = [
    ("compact", { .compact(leading: symbol("waveform"), trailing: symbol("timer")) }),
    ("minimal", { .minimal(symbol("timer", 30)) }),
    ("pill", { .expanded(card("Now Playing"), size: CGSize(width: 250, height: 84), type: nil) }),
    ("square", { .expanded(card("Square"), size: CGSize(width: 100, height: 100), type: .square) }),
    ("oval", { .expanded(card("Oval"), size: CGSize(width: 300, height: 200), type: .oval) }),
    ("tallRect", { .expanded(card("Tall"), size: CGSize(width: 100, height: 300), type: .tallRect) }),
    ("squareLarge", { .expanded(card("Large"), size: nil, type: .squareLarge) }),
    ("inert", { .inert }),
]

func snap(_ w: NSWindow, _ name: String) -> CGImage? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    // CGWindowListCreateImage is hidden from the 26 SDK; options: including window (8), bounds ignore framing (1).
    guard let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map({ unsafeBitCast($0, to: Fn.self) }),
          let img = fn(.null, 8, UInt32(w.windowNumber), 1)?.takeRetainedValue() else { return nil }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(outDir)/island-\(name).png"))
    return img
}

/// What the capture shows as opaque: the island, plus the key line ring (2 pt outside, an opaque backdrop copy in the
/// window image) whenever the island has content.
func visibleFrame(_ p: IslandPanel) -> CGRect {
    // displayedShape: the real pointer may hover the island during a run (hover scale and lean).
    p.zone == .inert ? p.displayedShape.frame : p.displayedShape.frame.insetBy(dx: -KeyLine.thickness, dy: -KeyLine.thickness)
}

/// Bounding box (pixels) of pixels with alpha > 0.9: the island body, without its translucent shadow.
func opaqueBox(_ img: CGImage) -> CGRect? {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var box: CGRect?
    for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 230 {
        box = box?.union(CGRect(x: x, y: y, width: 1, height: 1)) ?? CGRect(x: x, y: y, width: 1, height: 1)
    } }
    return box
}

NSApplication.shared.setActivationPolicy(.accessory)
let panel = IslandPanel(screen: NSScreen.main!)
panel.orderFrontRegardless()

func shots(_ i: Int) {
    guard i < states.count else { exit(Int32(failures)) }
    let (name, make) = states[i]
    panel.show(make())
    let start = Date()
    func wait() {
        if !panel.isIdle && Date().timeIntervalSince(start) < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait); return }
        expect(panel.isIdle, "\(name): display link paused after settling (\(String(format: "%.2f", Date().timeIntervalSince(start))) s)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {   // let the last frame reach the window server
            let scale = panel.geometry.scale, s = visibleFrame(panel)
            if let img = snap(panel, name) {
                let box = opaqueBox(img)
                if let box {
                    expect(abs(box.width - s.width * scale) <= 1 && abs(box.height - s.height * scale) <= 1,
                           "\(name): opaque \(Int(box.width)) x \(Int(box.height)) px vs shape \(s.width) x \(s.height) pt")
                } else {
                    expect(false, "\(name): no opaque pixels")
                }
            } else {
                expect(false, "\(name): capture failed")
            }
            shots(i + 1)
        }
    }
    wait()
}

func live() {
    let cycle = [0, 2, 0, 1, 3, 5, 7]   // compact, pill, compact, minimal, square, tallRect, inert
    var step = 0, expanded = false
    func next() {
        let i = cycle[step % cycle.count]
        panel.show(states[i].1())
        expanded = [2, 3, 4, 5, 6].contains(i)
        step += 1
    }
    panel.onClick = {
        expanded.toggle()
        panel.show(expanded ? states[2].1() : states[0].1())
    }
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
        if expanded { expanded = false; panel.show(states[0].1()) }
    }
    print("""
        Island live demo (90 s). Check:
          1. click menu bar items and windows next to the island: they must react;
          2. switch to a full-screen app: the island must still show;
          3. transitions look smooth.
        """)
    next()
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in next() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { exit(0) }
}

/// M3 content through the real IslandHost: volume expanded, volume inflated (hover), Focus compact.
func osd() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let chiclets = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    let volume = { host.receive(chiclets, [5, 1, 500, 4000, 6250, 10000, 0]) }
    // (name, action, repeated every 0.25 s until the capture: the volume HUD times out after 1 s, like a held key)
    let steps: [(String, () -> Void, (() -> Void)?)] = [
        ("idle", {}, nil),   // the idle pill: inert stays on screen
        ("volume", volume, volume),
        ("volume-inflated", { host.hover(true) }, nil),
        ("focus", { host.hover(false); host.receive("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"]) }, nil),
    ]
    func step(_ i: Int) {
        guard i < steps.count else { exit(Int32(failures)) }
        steps[i].1()
        let start = Date()
        var captured = false
        func repeatKey() {
            guard !captured, let r = steps[i].2 else { return }
            r()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: repeatKey)
        }
        repeatKey()
        func wait() {
            if !host.panel.isIdle && Date().timeIntervalSince(start) < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let s = visibleFrame(host.panel), scale = host.panel.geometry.scale
                if let img = snap(host.panel, "osd-" + steps[i].0), let box = opaqueBox(img) {
                    expect(abs(box.width - s.width * scale) <= 1 && abs(box.height - s.height * scale) <= 1,
                           "\(steps[i].0): opaque \(Int(box.width)) x \(Int(box.height)) px vs shape \(s.width) x \(s.height) pt")
                } else {
                    expect(false, "\(steps[i].0): capture failed")
                }
                captured = true
                step(i + 1)
            }
        }
        wait()
    }
    step(0)
}

/// Fake album art for the nowplaying mode: flat colors.
func fakeArtwork() -> Data? {
    let img = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
        NSColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 1).setFill(); r.fill()
        NSColor(red: 0.98, green: 0.75, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 60, y: 60, width: 180, height: 180)).fill()
        NSColor(red: 0.15, green: 0.1, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 130, y: 130, width: 40, height: 40)).fill()
        return true
    }
    return img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
}

/// M4 Now Playing with a fake track: compact (playing), expanded, compact (paused). PNGs: island-nowplaying-<step>.png.
func nowPlaying() {
    let model = NowPlayingModel(), h = panel.geometry.sensor.height
    let info = NowPlayingInfo(title: "Midnight City", artist: "M83", duration: 243, elapsed: 61, rate: 1, timestamp: Date(),
                              artwork: fakeArtwork())
    let compact = {
        panel.show(.compact(leading: hosted(NowPlayingCompactLeading(model: model, sensorHeight: h),
                                            size: NowPlayingMetrics.compactLeadingSize(sensorHeight: h)),
                            trailing: hosted(NowPlayingCompactTrailing(model: model, sensorHeight: h),
                                             size: NowPlayingMetrics.compactTrailingSize(sensorHeight: h))))
    }
    let steps: [(String, () -> Void)] = [
        ("compact", { model.update(.init(info: info, isPlaying: true, bundleID: "com.apple.Music")); compact() }),
        ("expanded", {
            let size = CGSize(width: NowPlayingMetrics.expandedWidth, height: NowPlayingMetrics.expandedHeight)
            panel.show(.expanded(hosted(NowPlayingExpanded(model: model), size: size), size: size, type: NowPlayingMetrics.expandedType))
        }),
        ("paused", { var p = info; p.rate = 0; model.update(.init(info: p, isPlaying: false, bundleID: "com.apple.Music")); compact() }),
    ]
    func step(_ i: Int) {
        guard i < steps.count else { exit(Int32(failures)) }
        steps[i].1()
        let start = Date()
        func wait() {
            if !panel.isIdle && Date().timeIntervalSince(start) < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {   // the waveform ramp (0.25 s) has settled
                let s = visibleFrame(panel), scale = panel.geometry.scale
                if let img = snap(panel, "nowplaying-" + steps[i].0), let box = opaqueBox(img) {
                    expect(abs(box.width - s.width * scale) <= 1 && abs(box.height - s.height * scale) <= 1,
                           "nowplaying-\(steps[i].0): opaque \(Int(box.width)) x \(Int(box.height)) px vs shape \(s.width) x \(s.height) pt")
                } else {
                    expect(false, "nowplaying-\(steps[i].0): capture failed")
                }
                step(i + 1)
            }
        }
        wait()
    }
    step(0)
}

/// Pixels of content (bright, mostly opaque) drawn outside `shape` grown by `margin` pt: must stay 0 in every frame.
func ghostPixels(_ img: CGImage, window: NSWindow, shape: CGRect, scale: CGFloat, margin: CGFloat = 6) -> Int {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let f = shape.insetBy(dx: -margin, dy: -margin)
    // Image rows start at the top of the window; the shape is in screen points (origin bottom-left).
    let x0 = (f.minX - window.frame.minX) * scale, x1 = (f.maxX - window.frame.minX) * scale
    let y0 = (window.frame.maxY - f.maxY) * scale, y1 = (window.frame.maxY - f.minY) * scale
    var n = 0
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        guard px[i + 3] > 40, Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 100 else { continue }   // also fading content
        if CGFloat(x) < x0 || CGFloat(x) > x1 || CGFloat(y) < y0 || CGFloat(y) > y1 { n += 1 }
    } }
    return n
}

/// Transition burst: capture the panel every 40 ms while volume, Focus and the collapse animate; no content may be
/// drawn outside the current island. PNGs: island-burst-<step>-<frame>.png.
func burst() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let chiclets = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    let steps: [(String, () -> Void)] = [
        ("volume", { host.receive(chiclets, [5, 1, 500, 4000, 6250, 10000, 0]) }),
        ("focus", { host.receive("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"]) }),
        ("collapse", { host.panel.show(.inert) }),
        // Clipping: solid white content as large as the final island while the island grows from the idle pill.
        ("clip", {
            let v = NSView(frame: CGRect(x: 0, y: 0, width: 250, height: 84))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.cgColor
            host.panel.show(.expanded(v, size: v.frame.size, type: nil))
        }),
        ("clip-collapse", { host.panel.show(.inert) }),
    ]
    func step(_ i: Int) {
        guard i < steps.count else { exit(Int32(failures)) }
        steps[i].1()
        var worst = 0
        func frame(_ k: Int) {
            guard k < 20 else {
                expect(worst == 0, "burst \(steps[i].0): no content outside the island (worst \(worst) px)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step(i + 1) }
                return
            }
            let s = host.panel.displayedShape.frame
            if let img = snap(host.panel, "burst-\(steps[i].0)-\(String(format: "%02d", k))") {
                worst = max(worst, ghostPixels(img, window: host.panel, shape: s, scale: host.panel.geometry.scale))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { frame(k + 1) }
        }
        frame(0)
    }
    step(0)
}

/// Key line over a coloured backdrop window: captures the panel composited with the window below it and compares the
/// ring (1 pt above the compact island) with the bare backdrop at the same height. Lighten of #262626 must leave any
/// backdrop lighter than #262626 unchanged and lift a black one to 0.149.
func keyline() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let screen = NSScreen.main!.frame
    let region = CGRect(x: screen.midX - 200, y: screen.maxY - 80, width: 400, height: 80)
    let backdrop = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
    backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    backdrop.ignoresMouseEvents = true
    backdrop.orderFrontRegardless()
    host.receive("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"])
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map { unsafeBitCast($0, to: Fn.self) }!
    let colors: [(String, NSColor, Double)] = [("blue", NSColor(srgbRed: 0.16, green: 0.33, blue: 0.6, alpha: 1), 0),
                                               ("black", .black, 0.149), ("white", .white, 0)]
    func test(_ i: Int) {
        guard i < colors.count else { backdrop.orderOut(nil); exit(Int32(failures)) }
        backdrop.backgroundColor = colors[i].1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // Below-window (4) + including-window (8): the panel and every window under it; CG rect origin is top-left.
            let cg = CGRect(x: region.minX - screen.minX, y: 0, width: region.width, height: region.height)
            guard let img = fn(cg, 12, UInt32(host.panel.windowNumber), 0)?.takeRetainedValue() else { expect(false, "keyline capture"); return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(outDir)/island-keyline-\(colors[i].0).png"))
            let rep = NSBitmapImageRep(cgImage: img), k = CGFloat(img.width) / region.width
            let top = (screen.maxY - host.panel.displayedShape.frame.maxY - 1) * k   // 1 pt above the island top edge
            func px(_ x: CGFloat) -> NSColor { rep.colorAt(x: Int(x), y: Int(top))!.usingColorSpace(.sRGB)! }
            let ring = px(region.width / 2 * k), bare = px(10 * k), want = colors[i].2
            let lifted = ring.redComponent - bare.redComponent
            // Over black the capture reads #262626 as ~0.198 (colour matching of the capture scales both the old white
            // alpha 0.163 -> 0.218 and 0.149 -> 0.198 by ~1.33), so accept a visible dark-grey lift there.
            expect(want > 0 ? (0.12...0.22).contains(ring.redComponent) : abs(lifted) < 0.03,
                   "keyline over \(colors[i].0): ring \(String(format: "%.3f %.3f %.3f", ring.redComponent, ring.greenComponent, ring.blueComponent)) bare \(String(format: "%.3f %.3f %.3f", bare.redComponent, bare.greenComponent, bare.blueComponent))")
            test(i + 1)
        }
    }
    test(0)
}

/// Bright content pixels inside `shape` inset by 3 pt (excludes the key line ring, which copies the desktop).
func contentPixels(_ img: CGImage, window: NSWindow, shape: CGRect, scale: CGFloat) -> Int {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let f = shape.insetBy(dx: 3, dy: 3)
    let x0 = Int((f.minX - window.frame.minX) * scale), x1 = Int((f.maxX - window.frame.minX) * scale)
    let y0 = Int((window.frame.maxY - f.maxY) * scale), y1 = Int((window.frame.maxY - f.minY) * scale)
    var n = 0
    for y in max(y0, 0)..<min(y1, h) { for x in max(x0, 0)..<min(x1, w) {
        let i = (y * w + x) * 4
        if Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 300 { n += 1 }
    } }
    return n
}

/// Arrival timing (measurement): from the volume event, capture every ~16 ms and print the island width and the
/// visible content pixels; round 0 warms SwiftUI, round 1 is the one to read.
func arrival() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let chiclets = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    // Round 0 warms SwiftUI and the symbol cache (ControlCenter is warm); round 1 is measured.
    func round(_ r: Int) {
        let start = CACurrentMediaTime()
        host.receive(chiclets, [5, 1, 500, 4000, 6250, 10000, 0])
        var blankWhileGrowing = 0, firstContent: Double?
        func frame(_ k: Int) {
            guard k < 25 else {
                if r == 0 {
                    host.panel.show(.inert)   // let the HUD go (the controller still holds it; show inert directly)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { round(1) }
                    return
                }
                // Measurement only until the 27.3 content arrival timing is read (CenterHUDZoneContentItemModel).
                print("arrival: blank growing frames \(blankWhileGrowing), first content at \(firstContent.map { String(format: "%.0f ms", $0) } ?? "never")")
                exit(0)
            }
            let s = host.panel.displayedShape.frame, t = (CACurrentMediaTime() - start) * 1000
            if let img = snap(host.panel, "arrival-\(String(format: "%02d", k))") {
                let n = contentPixels(img, window: host.panel, shape: s, scale: host.panel.geometry.scale)
                print(String(format: "  t %4.0f ms  width %5.1f  content %5d px", t, s.width, n))
                if n > 0, firstContent == nil { firstContent = t }
                if n == 0 && s.width > 120 && s.width < 300 { blankWhileGrowing += 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { frame(k + 1) }
        }
        print("round \(r)")
        frame(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { round(0) }
}

/// Frame pacing during real transitions (no captures, which would steal the main thread): every display-link interval
/// must stay within 1.5 frames of the display refresh.
func timing() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let chiclets = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    let steps: [(String, () -> Void)] = [
        ("warm", { host.receive(chiclets, [5, 1, 500, 4000, 6250, 10000, 0]) }),
        ("warm-collapse", { host.panel.show(.inert) }),
        ("volume", { host.receive(chiclets, [5, 1, 500, 4000, 3000, 10000, 0]) }),
        ("inflate", { host.hover(true) }),
        ("focus", { host.hover(false); host.receive("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"]) }),
        ("collapse", { host.panel.show(.inert) }),
    ]
    let refresh = 1.0 / Double(NSScreen.main!.maximumFramesPerSecond)
    func step(_ i: Int) {
        guard i < steps.count else { exit(Int32(failures)) }
        host.panel.frameIntervals = []
        steps[i].1()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let f = host.panel.frameIntervals, late = f.filter { $0 > refresh * 1.5 }
            if !steps[i].0.hasPrefix("warm") {
                expect(late.isEmpty, "timing \(steps[i].0): \(f.count) frames, \(late.count) late, max \(String(format: "%.1f", (f.max() ?? 0) * 1000)) ms (refresh \(String(format: "%.1f", refresh * 1000)) ms)")
            }
            step(i + 1)
        }
    }
    step(0)
}

/// Inflated track must be solid (tickProgress 0 closes every gap): hover in/out repeatedly on brightness and volume,
/// then scan the middle row of the 18 pt track for seams (a pixel darker than both neighbours by > 24).
func inflate() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let chiclets = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    let steps: [(String, () -> Void, Double)] = [
        ("brightness", { host.receive(chiclets, [1, 1, 500, 4000, 6250, 10000, 0]); host.hover(true) }, 1.0),
        ("brightness-cycle", { host.hover(false); host.hover(true); host.hover(false); host.hover(true) }, 1.0),
        ("brightness-quick", { host.hover(false); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { host.hover(true) } }, 1.2),
        ("volume", { host.hover(false); host.receive(chiclets, [5, 1, 500, 4000, 3750, 10000, 0]); host.hover(true) }, 1.0),
    ]
    func step(_ i: Int) {
        guard i < steps.count else { exit(Int32(failures)) }
        steps[i].1()
        DispatchQueue.main.asyncAfter(deadline: .now() + steps[i].2) {
            let p = host.panel, scale = p.geometry.scale, s = p.currentShape.frame
            guard let img = snap(p, "inflate-\(steps[i].0)") else { expect(false, "inflate capture"); step(i + 1); return }
            let rep = NSBitmapImageRep(cgImage: img)
            let t = SliderMetrics.trackFrame(inflated: true)
            // Track middle row in window pixels (window top-left origin); x across the track, 2 px inside each end.
            let y = Int((p.frame.maxY - (s.minY + t.midY)) * scale)
            let x0 = Int((s.minX + t.minX - p.frame.minX) * scale) + 2, x1 = Int((s.minX + t.maxX - p.frame.minX) * scale) - 2
            let lum = (x0...x1).map { x -> Int in let c = rep.colorAt(x: x, y: y)!; return Int((c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255) }
            var seams = 0
            for k in 1..<(lum.count - 1) where lum[k] + 24 < lum[k - 1] && lum[k] + 24 < lum[k + 1] { seams += 1 }
            expect(seams == 0, "inflate \(steps[i].0): solid 18 pt track (\(seams) seams)")
            step(i + 1)
        }
    }
    step(0)
}

/// Inflate motion: the track must stay at the island's mid height in every frame (one resize spring for island and
/// content). Captures every 33 ms on a background queue (captures on the main thread would stall the display link and
/// hide a jump), then scans the window's centre column (inside the track) for the track row and the island edges.
func inflateMotion() {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let chiclets = "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    host.receive(chiclets, [1, 1, 500, 4000, 6250, 10000, 0])
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map { unsafeBitCast($0, to: Fn.self) }!
    let id = UInt32(host.panel.windowNumber)
    func run(_ inside: Bool, then next: @escaping () -> Void) {
        let queue = DispatchQueue(label: "burst")
        var images: [CGImage] = []
        queue.async {
            for _ in 0..<18 {
                if let img = fn(.null, 8, id, 1)?.takeRetainedValue() { images.append(img) }
                Thread.sleep(forTimeInterval: 0.033)
            }
            DispatchQueue.main.async {
                var worst = 0.0, measured = 0
                for img in images {
                    let rep = NSBitmapImageRep(cgImage: img), x = img.width / 2
                    func lum(_ y: Int) -> Double { let c = rep.colorAt(x: x, y: y)!; return Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 }
                    let island = (0..<img.height).filter { Double(rep.colorAt(x: x, y: $0)!.alphaComponent) > 0.9 }
                    let inner = island.dropFirst(3).dropLast(3).filter { lum($0) > 0.12 }   // track rows inside the black body
                    if let t = island.first, let b = island.last, !inner.isEmpty {
                        let track = Double(inner.reduce(0, +)) / Double(inner.count), mid = Double(t + b) / 2
                        if ProcessInfo.processInfo.environment["BURST_LOG"] != nil { print(String(format: "  mid %.1f track %.1f", mid, track)) }
                        worst = max(worst, abs(track - mid)); measured += 1
                    }
                }
                expect(measured == images.count && worst <= 1.0,
                       "inflate motion \(inside ? "in" : "out"): track centre stays at island mid height (\(measured)/\(images.count) frames measured, worst \(String(format: "%.1f", worst)) px)")
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // The HUD times out after 1 s: re-send the event (a key press) so it stays open through the deflate frames.
            if !inside { host.receive(chiclets, [1, 1, 500, 4000, 6250, 10000, 0]) }
            host.hover(inside)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {   // arrival settled, before the 1 s timeout
        run(true) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { run(false) { exit(Int32(failures)) } } }
    }
}

/// Patterned backdrop (menu-bar-like stripes, all lighter than #262626): the ring area of the composite with the panel
/// must equal the same area captured without the panel, i.e. the backdrop copy is aligned and lighten leaves it alone.
final class Stripes: NSView {
    override func draw(_ r: NSRect) {
        for i in 0..<Int(bounds.width / 3) + 1 {
            (i % 2 == 0 ? NSColor(srgbRed: 0.16, green: 0.33, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.9, blue: 1, alpha: 1)).setFill()
            CGRect(x: CGFloat(i) * 3, y: 0, width: 3, height: bounds.height).fill()
        }
    }
}

/// Stripes behind the compact island: the 2 pt ring above its top edge must equal the bare backdrop.
/// idle: Focus on, settle, Focus off, settle (display link paused), as in ControlCenter where the key line backdrop
/// read black once the window stopped committing. The demo does not show that black, so idle also lets the backdrop
/// fall back to its substitute colour (light grey): the ring then matches the stripes only when WindowServer really
/// captures the screen behind the window.
func keylinePattern(idle: Bool = false) {
    panel.orderOut(nil)
    let host = IslandHost(screen: NSScreen.main!)
    let screen = NSScreen.main!.frame
    let region = CGRect(x: screen.midX - 200, y: screen.maxY - 80, width: 400, height: 80)
    let backdrop = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
    backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    backdrop.ignoresMouseEvents = true
    backdrop.contentView = Stripes(frame: CGRect(origin: .zero, size: region.size))
    backdrop.orderFrontRegardless()
    if idle { host.panel.keyLineBackdrop?.setValue(true, forKey: "allowsSubstituteColor") }
    host.receive("activeActivityDidChangeForManager:", ["com.apple.focus.gaming", "Gaming", "rocket.fill", "systemBlueColor"])
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map { unsafeBitCast($0, to: Fn.self) }!
    func measure() {
        if idle { expect(host.panel.isIdle, "keyline idle: display link paused before the capture") }
        let cg = CGRect(x: region.minX - screen.minX, y: 0, width: region.width, height: region.height)
        let id = UInt32(host.panel.windowNumber)
        guard let with = fn(cg, 12, id, 0)?.takeRetainedValue(), let without = fn(cg, 4, id, 0)?.takeRetainedValue() else {
            expect(false, "pattern capture"); exit(1)
        }
        try? NSBitmapImageRep(cgImage: with).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(outDir)/island-keyline-\(idle ? "idle" : "pattern").png"))
        let a = NSBitmapImageRep(cgImage: with), b = NSBitmapImageRep(cgImage: without), k = CGFloat(with.width) / region.width
        let f = host.panel.displayedShape.frame
        // The 2 pt band above the island's straight top edge (rows from the screen top).
        let y0 = Int((screen.maxY - f.maxY - KeyLine.thickness) * k), y1 = Int((screen.maxY - f.maxY) * k) - 1
        let x0 = Int((f.minX + f.height / 2 - region.minX) * k), x1 = Int((f.maxX - f.height / 2 - region.minX) * k)
        var worst = 0.0
        for y in y0...y1 { for x in x0...x1 {
            let p = a.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!, q = b.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            worst = max(worst, abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent), abs(p.blueComponent - q.blueComponent))
        } }
        expect(worst < 0.03, "keyline over stripes: ring equals the bare backdrop (max channel diff \(String(format: "%.3f", worst)))")
        backdrop.orderOut(nil)
        exit(Int32(failures))
    }
    func waitIdle(_ n: Int, then: @escaping () -> Void) {   // settled, then 1 s more
        if host.panel.isIdle || n > 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: then); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitIdle(n + 1, then: then) }
    }
    if idle { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitIdle(0) {
        host.receive("activeActivityDidChangeForManager:", [NSNull()])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitIdle(0, then: measure) }
    } } }
    else { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: measure) }
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
DispatchQueue.main.async {
    switch mode {
    case "shots": shots(0)
    case "osd": osd()
    case "burst": burst()
    case "keyline": keyline()
    case "keyline-pattern": keylinePattern()
    case "keyline-idle": keylinePattern(idle: true)
    case "arrival": arrival()
    case "timing": timing()
    case "inflate": inflate()
    case "inflate-motion": inflateMotion()
    case "nowplaying": nowPlaying()
    default: live()
    }
}
NSApplication.shared.run()
