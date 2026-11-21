// Shared ggapp test app: runs inside an .app with DYLD_INSERT_LIBRARIES=GGApp.dylib (built by tests/app.sh).
// Modes: flex, lights, pocket, ... (see the dispatch at the end). Captures its own windows to PNG ($OUT) and prints
// "OK"/"FAIL" results.
import AppKit
import SwiftUI

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "flex"
let outDir = ProcessInfo.processInfo.environment["OUT"] ?? "/tmp"
var bad = 0
func expect(_ c: Bool, _ m: String) { print(c ? "OK  \(m)" : "FAIL \(m)"); if !c { bad += 1 } }
func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

func snap(_ w: NSWindow, _ name: String) -> CGImage? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map({ unsafeBitCast($0, to: Fn.self) }),
          let img = fn(.null, 8, UInt32(w.windowNumber), 1)?.takeRetainedValue() else { print("snap failed"); return nil }
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(mode)-\(name).png"))
    return img
}

func mouse(_ w: NSWindow, _ type: NSEvent.EventType, _ p: NSPoint) {
    let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    NSApp.sendEvent(e)
}

typealias DebugFn = @convention(c) () -> UnsafePointer<CChar>
func flexDebug() -> [String: Double] {
    guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_flex_debug").map({ unsafeBitCast($0, to: DebugFn.self) }),
          let d = try? JSONSerialization.jsonObject(with: Data(String(cString: f()).utf8)) as? [String: Double] else { return [:] }
    return d
}

/// Largest width of a pixel run that differs from the background (background taken at column 3 of each row). The interactive
/// pill is the widest. Returns that width and R+G+B (0..3) at 1/4 of the run on that row (avoiding the text in the middle).
func pill(_ img: CGImage) -> (width: Int, luma: Double) {
    let rep = NSBitmapImageRep(cgImage: img)
    var best = 0, bestY = 0, bestEnd = 0
    for y in 40..<rep.pixelsHigh - 10 {
        guard let bg = rep.colorAt(x: 3, y: y) else { continue }
        var run = 0
        for x in 0..<rep.pixelsWide {
            let c = rep.colorAt(x: x, y: y)!
            let d = abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent)
            run = d > 0.06 ? run + 1 : 0
            if run > best { best = run; bestY = y; bestEnd = x }
        }
    }
    let c = rep.colorAt(x: bestEnd - best * 3 / 4, y: bestY)!
    return (best, Double(c.redComponent + c.greenComponent + c.blueComponent))
}

struct FlexContent: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("interactive").frame(width: 140, height: 40).glassEffect(.regular.interactive())
            Text("plain").padding(12).glassEffect(.regular)
            Button("Glass") { print("ACTION glass") }.buttonStyle(.glass)
            Button("Prominent") {}.buttonStyle(.glassProminent)
        }.frame(width: 320, height: 300).background(Color(red: 0.2, green: 0.35, blue: 0.6))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 300), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)

func runFlex() {
    let host = NSHostingView(rootView: FlexContent())
    w.contentView = host
    w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    after(1.0) {
        // The interactive button is at the top: center x 160, y (window coordinates, origin bottom) about 300 - (position in the VStack).
        let target = NSPoint(x: 160, y: 230)
        let d0 = flexDebug(); print("debug rest", d0)
        let p0 = snap(w, "0-idle").map(pill) ?? (width: 0, luma: 0)
        mouse(w, .leftMouseDown, target)
        after(0.16) {
            let d1 = flexDebug(); print("debug 0.16 s", d1)
            let p1 = snap(w, "1-press016").map(pill) ?? (width: 0, luma: 0)
            expect(p1.width - p0.width >= 6, "pill grows >= 6 px when pressed (rest \(p0.width), pressed \(p1.width))")
            expect(p1.luma - p0.luma >= 0.05, "glow brightens the pill (rest \(p0.luma), pressed \(p1.luma))")
            after(0.4) {
                _ = snap(w, "2-press056"); mouse(w, .leftMouseUp, target)
                after(0.8) {
                    let d2 = flexDebug(); print("debug release 0.8 s", d2); _ = snap(w, "3-release")
                    // interactive + .glass + .glassProminent (DesignLibrary GOT patch); plain is not.
                    expect(d0["entries"] == 3, "3 interactive entries (got \(d0["entries"] ?? -1))")
                    expect((d1["scale"] ?? 1) >= 1.05, "scale at 0.16 s >= 1.05 (got \(d1["scale"] ?? -1))")
                    expect((d1["bigGlow"] ?? 0) > 0.3, "BigGlow lit while pressed (got \(d1["bigGlow"] ?? -1))")
                    expect(abs((d2["scale"] ?? 0) - 1) < 0.001 && (d2["bigGlow"] ?? 1) < 0.01, "released 0.8 s: back at rest")
                    // Press, then the window loses key: must return to rest.
                    mouse(w, .leftMouseDown, target)
                    after(0.1) {
                        w.resignKey(); NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
                        after(0.8) {
                            let d3 = flexDebug()
                            expect(abs((d3["scale"] ?? 0) - 1) < 0.001, "key lost midway -> back at rest (got \(d3["scale"] ?? -1))")
                            // Closing the window during the animation: no crash.
                            w.makeKeyAndOrderFront(nil)
                            mouse(w, .leftMouseDown, target)
                            after(0.05) { w.close(); after(0.5) { print("closing the window mid-animation: no crash"); print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1) } }
                        }
                    }
                }
            }
        }
    }
}

/// Other DesignLibrary controls: records which glass gets interactive enabled (run with GG_TRACE=1 to see debugDescription).
struct ControlsContent: View {
    @State var on = true
    @State var v = 0.5
    @State var seg = 0
    var body: some View {
        VStack(spacing: 14) {
            Toggle("Switch", isOn: $on).toggleStyle(.switch)
            Slider(value: $v)
            Picker("Seg", selection: $seg) { Text("A").tag(0); Text("B").tag(1) }.pickerStyle(.segmented)
            Menu("Menu") { Button("x") {} }
            Button("Disabled") {}.buttonStyle(.glass).disabled(true)
        }.padding(20).frame(width: 320, height: 300)
    }
}

func runControls() {
    w.contentView = NSHostingView(rootView: ControlsContent())
    w.makeKeyAndOrderFront(nil)
    after(1.0) { _ = snap(w, "controls"); print("controls entries", flexDebug()["entries"] ?? -1); exit(0) }
}

/// Number of "close light red" pixels (R > 180, R - G > 70, R - B > 70) and their average color.
func redPixels(_ img: CGImage) -> (count: Int, avg: (Double, Double, Double)) {
    let rep = NSBitmapImageRep(cgImage: img)
    var n = 0, r = 0.0, g = 0.0, b = 0.0
    for y in 0..<rep.pixelsHigh { for x in 0..<min(rep.pixelsWide, 80) {
        let c = rep.colorAt(x: x, y: y)!
        let (cr, cg, cb) = (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
        if cr > 180 && cr - cg > 70 && cr - cb > 70 { n += 1; r += cr; g += cg; b += cb }
    } }
    return (n, n > 0 ? (r / Double(n), g / Double(n), b / Double(n)) : (0, 0, 0))
}

/// Close light pixel count regardless of color: columns 0..24 differing from the titlebar background (taken at column 75,
/// past the zoom light) by more than 0.14.
func closeLightArea(_ img: CGImage) -> Int {
    let rep = NSBitmapImageRep(cgImage: img)
    var n = 0
    for y in 0..<rep.pixelsHigh {
        guard let bg = rep.colorAt(x: 75, y: y) else { continue }
        for x in 0..<24 {
            let c = rep.colorAt(x: x, y: y)!
            if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.14 { n += 1 }
        }
    }
    return n
}

/// A test run from a terminal may not be activated at once: wait until the window becomes key (up to 3 s).
func whenKey(_ w: NSWindow, tries: Int = 30, _ f: @escaping () -> Void) {
    if w.isKeyWindow || tries == 0 { if !w.isKeyWindow { print("warning: window did not become key") }; f(); return }
    NSApp.activate(); w.makeKeyAndOrderFront(nil)
    after(0.1) { whenKey(w, tries: tries - 1, f) }
}

func ourLights(_ w: NSWindow) -> Int {
    [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].reduce(0) { acc, t in
        acc + (w.standardWindowButton(t)?.subviews.filter { NSStringFromClass(type(of: $0)).contains("GGWCHost") }.count ?? 0)
    }
}

func runLights() {
    w.contentView = NSView()
    w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    let panel = NSPanel(contentRect: NSRect(x: 600, y: 200, width: 200, height: 120), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    panel.orderFront(nil)
    after(1.0) { whenKey(w) {
        let idle = snap(w, "0-key").map(redPixels) ?? (count: 0, avg: (0, 0, 0))
        let idleArea = snap(w, "0-key").map(closeLightArea) ?? 0
        print("red while key", idle)
        // The machine in use may steal focus: check color only when the window is really key; growth is measured by area.
        if w.isKeyWindow { expect(idle.count > 80, "close light red in a key window (\(idle.count) pixels, color \(idle.avg))") }
        else { print("SKIP key color check: window could not keep key") }
        expect(ourLights(w) == 3, "3 ggapp lights on the window (got \(ourLights(w)))")
        let orig = w.standardWindowButton(.closeButton)?.subviews.filter { NSStringFromClass(type(of: $0)).contains("_NSCoreHostingView") && !$0.isHidden }.count ?? -1
        expect(orig == 0, "original light hosting view hidden (remaining \(orig))")
        let pb = panel.standardWindowButton(.closeButton)
        expect(pb?.subviews.contains { !$0.isHidden } ?? false, "utility panel still shows its close light")
        // Holding the close button: AppKit runs a nested tracking loop inside sendEvent (measured: blocks about 3 s) in
        // eventTracking mode, where DispatchQueue.main blocks do not run, and it may exit after ~0.5 s because the real mouse
        // button is not pressed; use a Timer in .common mode to capture early while held (press spring 0.1/1.0 settles after
        // ~0.08 s), then release outside the button so the window does not close.
        let close = w.standardWindowButton(.closeButton)!
        let p = close.convert(NSPoint(x: 7, y: 7), to: nil)
        after(0.05) { mouse(w, .leftMouseDown, p) }
        RunLoop.main.add(Timer(timeInterval: 0.25, repeats: false) { _ in   // press at 0.05, capture 0.2 s later
            let pressed = snap(w, "1-press").map(closeLightArea) ?? 0
            expect(Double(pressed) >= Double(idleArea) * 1.15, "light grows when pressed (\(idleArea) -> \(pressed) pixels)")
            // The button decides "inside/outside" from the last drag event, not the mouseUp location: drag out before releasing.
            for t in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x + 150, y: p.y - 100), modifierFlags: [], timestamp: 0,
                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
            }
            after(0.6) {
                let back = snap(w, "2-release").map(closeLightArea) ?? 0
                expect(abs(back - idleArea) <= 8, "release returns to the original size (\(idleArea) -> \(back) pixels)")
                // Another window becomes key: gray lights.
                let w2 = NSWindow(contentRect: NSRect(x: 600, y: 400, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                w2.makeKeyAndOrderFront(nil)
                after(0.8) {
                    let inactive = snap(w, "3-inactive").map(redPixels) ?? (count: -1, avg: (0, 0, 0))
                    let area = snap(w, "3-inactive").map(closeLightArea) ?? 0
                    expect(!w.isKeyWindow && inactive.count == 0 && area > 100, "non-key window: gray lights, still visible (\(inactive.count) red pixels, \(area) light pixels)")
                    w2.orderOut(nil)   // not close(): the default isReleasedWhenClosed would release twice
                    // Dark appearance on the real window (system appearance unchanged).
                    w.appearance = NSAppearance(named: .darkAqua)
                    whenKey(w) { after(0.6) {
                        let dark = snap(w, "4-dark").map(redPixels) ?? (count: 0, avg: (0, 0, 0))
                        if w.isKeyWindow { expect(dark.count > 80, "dark appearance: close light red (\(dark.count) pixels, color \(dark.avg))") }
                        else { print("SKIP dark color check: window could not keep key") }
                        expect(ourLights(w) == 3, "dark appearance: still 3 ggapp lights")
                        runLightsDrag(p) { runLightsGlass() }
                    } }
                }
            }
        }, forMode: .common)
    } }
}

/// Bounding box (width, height, center x) of the close light: columns 0..28 differing from the titlebar background
/// (column 75) by more than 0.14, rows 0..31.
func closeLightBox(_ img: CGImage) -> (w: Int, h: Int, cx: Double) {
    let rep = NSBitmapImageRep(cgImage: img)
    var x0 = 99, x1 = -1, y0 = 99, y1 = -1
    for y in 0..<min(32, rep.pixelsHigh) {
        guard let bg = rep.colorAt(x: 75, y: y) else { continue }
        for x in 0..<29 {
            let c = rep.colorAt(x: x, y: y)!
            if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.14 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
    }
    return x1 < 0 ? (0, 0, 0) : (x1 - x0 + 1, y1 - y0 + 1, Double(x0 + x1) / 2)
}

/// Dragging the close light (27 windowControl FlexInteraction): press through the event queue (so the light's local monitor
/// sees it), drag 300 pt to the right, capture while held: the light stretches horizontally (k ≈ 0.08), shrinks vertically and
/// drifts right; releasing outside the button (window not closed) returns it to the original size. Events are nested in the
/// button tracking loop, so Timers in .common mode are used.
func runLightsDrag(_ p: NSPoint, then: @escaping () -> Void) {
    func post(_ t: NSEvent.EventType, _ q: NSPoint) {
        NSApp.postEvent(NSEvent.mouseEvent(with: t, location: q, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
    }
    let idle = snap(w, "6-drag-idle").map(closeLightBox) ?? (w: 0, h: 0, cx: 0)
    post(.leftMouseDown, p)
    RunLoop.main.add(Timer(timeInterval: 0.15, repeats: false) { _ in post(.leftMouseDragged, NSPoint(x: p.x + 300, y: p.y)) }, forMode: .common)
    RunLoop.main.add(Timer(timeInterval: 0.6, repeats: false) { (_: Timer) in
        let d = snap(w, "7-drag").map(closeLightBox) ?? (w: 0, h: 0, cx: 0)
        expect(d.w - d.h >= 2 && d.cx > idle.cx + 0.4, "light drag: stretches horizontally, shrinks vertically, drifts with the drag (rest \(idle), drag \(d))")
        post(.leftMouseUp, NSPoint(x: p.x + 300, y: p.y))
        RunLoop.main.add(Timer(timeInterval: 0.9, repeats: false) { (_: Timer) in
            let r = snap(w, "8-drag-release").map(closeLightBox) ?? (w: 0, h: 0, cx: 0)
            expect(abs(r.w - idle.w) <= 1 && abs(r.h - idle.h) <= 1 && w.isVisible, "drag release: original size, window still open (rest \(idle), release \(r))")
            then()
        }, forMode: .common)
    }, forMode: .common)
}

/// "glass" phase of the lights: builds 3 ggapp lights (gg_wc_make/gg_wc_update) scaled 2x with sublayerTransform (the SDF is
/// computed in screen pixels, so it renders like Retina) on a flat background, then checks the reverse-engineered 27
/// characteristics by pixel. The close light covers x 18..46, y 16..44 (center 32,30) in the image.
func runLightsGlass() {
    typealias Make = @convention(c) () -> Unmanaged<NSView>
    typealias Upd = @convention(c) (NSView, Int, Bool, Bool, Int, Bool, Int) -> Void
    guard let mk = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_wc_make").map({ unsafeBitCast($0, to: Make.self) }),
          let up = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_wc_update").map({ unsafeBitCast($0, to: Upd.self) }) else {
        expect(false, "glass: gg_wc_make/gg_wc_update present"); print("TOTAL: some failed"); exit(1)
    }
    struct Case { let name: String; let dark: Bool; let state: Int; let active: Bool }
    let cases = [Case(name: "light", dark: false, state: 0, active: true), Case(name: "dark", dark: true, state: 0, active: true),
                 Case(name: "light-hover", dark: false, state: 4, active: true), Case(name: "dark-hover", dark: true, state: 4, active: true),
                 Case(name: "light-inactive", dark: false, state: 0, active: false)]
    var reps: [String: NSBitmapImageRep] = [:]
    func run(_ i: Int) {
        guard i < cases.count else { check(); return }
        let c = cases[i]
        let gw = NSWindow(contentRect: NSRect(x: 260, y: 520, width: 140, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        gw.appearance = NSAppearance(named: c.dark ? .darkAqua : .aqua)
        let root = NSView(); root.wantsLayer = true
        root.layer?.backgroundColor = c.dark ? CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1) : CGColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)
        gw.contentView = root
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 60)); box.wantsLayer = true
        box.layer?.sublayerTransform = CATransform3DMakeScale(2, 2, 1)
        root.addSubview(box)
        for (k, id) in [25, 26, 27].enumerated() {
            let v = mk().takeUnretainedValue()
            v.frame = NSRect(x: 9 + 23 * CGFloat(k), y: 8, width: 14, height: 14)
            box.addSubview(v)
            up(v, id, false, false, c.state, c.active, 1)
        }
        gw.orderFrontRegardless()
        after(0.6) {
            if let img = snap(gw, "5-glass-\(c.name)") { reps[c.name] = NSBitmapImageRep(cgImage: img) }
            gw.orderOut(nil)
            run(i + 1)
        }
    }
    func px(_ n: String, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        guard let c = reps[n]?.colorAt(x: x, y: y) else { return (-1, -1, -1) }
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }
    func check() {
        let body = px("light", 32, 30), side = min(px("light", 18, 30).g, px("light", 19, 30).g), top = px("light", 32, 17)
        expect(side < body.g - 50, "light: dark colored rim on both sides (edge G \(Int(side)), body \(Int(body.g)))")
        expect(top.g > side + 40, "light: top edge has no rim like the sides (top G \(Int(top.g)), sides \(Int(side)))")
        let gTop = px("light", 32, 19).g, gBottom = px("light", 32, 41).g
        expect(gTop < gBottom - 10, "light: gradient darker at top, lighter at bottom (G \(Int(gTop)) -> \(Int(gBottom)))")
        let halo = px("light", 32, 45)
        expect(halo.r - halo.g > 8, "light: colored shadow under the light (\(Int(halo.r)),\(Int(halo.g)),\(Int(halo.b)))")
        let dBody = px("dark", 32, 30), dTop = max(px("dark", 32, 16).g, px("dark", 32, 17).g), dSide = max(px("dark", 18, 30).g, px("dark", 19, 30).g)
        expect(dTop > dBody.g + 40, "dark: bright streak on the top edge (G \(Int(dTop)), body \(Int(dBody.g)))")
        expect(dSide < dTop - 30, "dark: sides have no bright streak like the top edge (sides G \(Int(dSide)), top \(Int(dTop)))")
        expect(abs(px("light", 32, 30).g - body.g) < 1 && body.g > 100, "light without rollover: no glyph (center G \(Int(body.g)))")
        for n in ["light-hover", "dark-hover"] {
            let g = px(n, 32, 30)
            expect(g.r < 215 && g.g < 70, "\(n): dark red x glyph (plusDarker) at the center (\(Int(g.r)),\(Int(g.g)),\(Int(g.b)))")
        }
        let ina = px("light-inactive", 32, 30)
        expect(abs(ina.r - ina.g) < 12 && abs(ina.g - ina.b) < 12, "inactive: gray body (\(Int(ina.r)),\(Int(ina.g)),\(Int(ina.b)))")
        print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
    }
    run(0)
}

// ---- pocket: window with toolbar + sidebar + scrolled scroll view, dumps the NSScrollPocket tree ----

func filterDesc(_ l: CALayer) -> String {
    (l.filters ?? []).map { f -> String in
        let o = f as AnyObject
        let t = (o.value(forKey: "type") as? String) ?? "?"
        let r = o.responds(to: NSSelectorFromString("inputKeys")) && ((o.value(forKey: "inputKeys") as? [String])?.contains("inputRadius") ?? false)
            ? "(\(o.value(forKey: "inputRadius") ?? "-"))" : ""
        return t + r
    }.joined(separator: ",")
}

/// Every visible layer (not hidden, opacity > 0) in the pocket tree: class/layer name, filters, frame.
func visibleLayers(_ l: CALayer, _ out: inout [CALayer]) {
    guard !l.isHidden && l.opacity > 0 else { return }
    out.append(l)
    l.sublayers?.forEach { visibleLayers($0, &out) }
}

func pockets(_ v: NSView, _ out: inout [NSView]) {
    if NSStringFromClass(type(of: v)) == "NSScrollPocket" { out.append(v) }
    v.subviews.forEach { pockets($0, &out) }
}

func dumpPockets(_ w: NSWindow) -> [(pocket: NSView, layers: [CALayer])] {
    var ps: [NSView] = []
    if let root = w.contentView?.superview { pockets(root, &ps) }
    return ps.map { p in
        var ls: [CALayer] = []
        if let l = p.layer, !p.isHiddenOrHasHiddenAncestor { visibleLayers(l, &ls) }
        print("pocket in \(type(of: p.superview!)) frame \(p.frame) hidden \(p.isHiddenOrHasHiddenAncestor)")
        for l in ls where ProcessInfo.processInfo.environment["GG_DUMPALL"] != nil || !filterDesc(l).isEmpty || l.name != nil || NSStringFromClass(type(of: l)) == "CABackdropLayer" {
            print("   \(type(of: l)) name=\(l.name ?? "") \(filterDesc(l)) op=\(l.opacity) frame=\(l.frame)\(NSStringFromClass(type(of: l)) == "CABackdropLayer" ? " scale=\(l.value(forKey: "scale") ?? "-")" : "")")
        }
        return (p, ls)
    }
}

final class Doc: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ r: NSRect) {
        for i in 0..<60 {
            (i % 2 == 0 ? NSColor.systemRed : NSColor.systemBlue).setFill()
            NSRect(x: 0, y: CGFloat(i) * 30, width: bounds.width, height: 15).fill()
        }
    }
}

func scroller(_ width: CGFloat) -> NSScrollView {
    let s = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    s.documentView = Doc(frame: NSRect(x: 0, y: 0, width: width, height: 1800))
    s.hasVerticalScroller = true
    s.contentView.scroll(to: NSPoint(x: 0, y: 300)); s.reflectScrolledClipView(s.contentView)
    return s
}

final class TBDelegate: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("a"), .flexibleSpace, .init("b")] }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let i = NSToolbarItem(itemIdentifier: id); i.image = NSImage(systemSymbolName: id.rawValue == "a" ? "star" : "gear", accessibilityDescription: nil); i.label = id.rawValue
        return i
    }
}
let tbDelegate = TBDelegate()

func runPocket() {
    // Non-activating NSPanel: can become key even while another app holds focus (machine in use), for the key cases.
    let pw = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 700, height: 450), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    pw.becomesKeyOnlyIfNeeded = false
    let tb = NSToolbar(identifier: "gg"); tb.delegate = tbDelegate; pw.toolbar = tb
    let split = NSSplitViewController()
    let side = NSViewController(); side.view = scroller(200)
    let main = NSViewController(); main.view = scroller(500)
    split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: side))
    split.addSplitViewItem(NSSplitViewItem(viewController: main))
    pw.contentViewController = split
    pw.setFrame(NSRect(x: 150, y: 150, width: 700, height: 450), display: true)
    pw.makeKeyAndOrderFront(nil)
    // A helper window to take key (inactive case), a window with title text over the toolbar (27: ThinFilm) and an untitled
    // window whose scroll view asks for a hard pocket (private setScrollPocketStyle:onEdge: 2, all edges).
    let other = NSWindow(contentRect: NSRect(x: 900, y: 150, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let tw = NSWindow(contentRect: NSRect(x: 150, y: 650, width: 500, height: 300), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    tw.title = "Title"; tw.toolbar = NSToolbar(identifier: "gg2"); tw.toolbar!.delegate = tbDelegate; tw.contentView = scroller(500)
    let hw = NSWindow(contentRect: NSRect(x: 700, y: 650, width: 500, height: 300), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    hw.titleVisibility = .hidden; hw.toolbar = NSToolbar(identifier: "gg3"); hw.toolbar!.delegate = tbDelegate
    let hs = scroller(500); hw.contentView = hs
    // Untitled toolbar window with plain (non scroll view) content in a color far from windowBackgroundColor.
    let cw = NSPanel(contentRect: NSRect(x: 400, y: 300, width: 500, height: 300), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    cw.becomesKeyOnlyIfNeeded = false; cw.titleVisibility = .hidden; cw.toolbar = NSToolbar(identifier: "gg4"); cw.toolbar!.delegate = tbDelegate
    let plain = NSView(); plain.wantsLayer = true; plain.layer!.backgroundColor = CGColor(srgbRed: 0.6, green: 0.4, blue: 0.2, alpha: 1); cw.contentView = plain
    typealias SetStyle = @convention(c) (AnyObject, Selector, Int, Int) -> Void
    let setStyle = NSSelectorFromString("setScrollPocketStyle:onEdge:")
    if hs.responds(to: setStyle) { for e in 0..<4 { unsafeBitCast(hs.method(for: setStyle), to: SetStyle.self)(hs, setStyle, 2, e) } }
    // Window pockets: "<ptr> NSScrollView 3 {{0, 0}, {500, 66}}|Layer:opacity:scale,..." (gg_pocket_debug).
    // Recipe: 1 Hard, 2 ThinFilm, 3 Conditional ThinFilm, 4 ThinFilm over glass, 5 Clear.
    func pocketInfo(_ w: NSWindow) -> [(sup: String, recipe: Int, width: Int, layers: [String: (Float, String)])] {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_pocket_debug").map({ unsafeBitCast($0, to: DebugFn.self) }) else { return [] }
        var ps: [NSView] = []; if let r = w.contentView?.superview { pockets(r, &ps) }
        let byPtr = Dictionary(ps.map { (String(format: "%p", unsafeBitCast($0, to: Int.self)), $0) }, uniquingKeysWith: { a, _ in a })
        return String(cString: f()).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            let head = parts[0].split(separator: " ")
            guard head.count >= 3, let p = byPtr[String(head[0])], !p.isHiddenOrHasHiddenAncestor, let r = Int(head[2]) else { return nil }
            let wd = Int(p.frame.width)
            var ls: [String: (Float, String)] = [:]
            for l in parts[1].split(separator: ",") { let x = l.split(separator: ":"); if x.count == 3 { ls[String(x[0])] = (Float(x[1]) ?? -1, String(x[2])) } }
            return (String(head[1]), r, wd, ls)
        }
    }
    /// Largest range over the three channels along one column in the bar band of the content scroll view (y 30-62 pt from
    /// the top, x 450 pt): large when the stripes show clearly, small through ThinFilm (blur + background replay).
    /// colorAt: y = 0 is the top of the window.
    func band(_ img: CGImage) -> (range: CGFloat, mean: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(rep.pixelsWide) / pw.frame.width
        var lo: [CGFloat] = [1, 1, 1], hi: [CGFloat] = [0, 0, 0], sum: CGFloat = 0, n: CGFloat = 0
        for y in stride(from: 30.0, through: 62.0, by: 1.0) {
            guard let c = rep.colorAt(x: Int(450 * s), y: Int(y * s)) else { continue }
            for (i, v) in [c.redComponent, c.greenComponent, c.blueComponent].enumerated() { lo[i] = min(lo[i], v); hi[i] = max(hi[i], v) }
            sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3; n += 1
        }
        return ((0..<3).map { hi[$0] - lo[$0] }.max()!, n > 0 ? sum / n : 0)
    }
    var phases: [(String, NSAppearance.Name, Bool)] = [("light key", .aqua, true), ("dark key", .darkAqua, true), ("light inactive", .aqua, false), ("dark inactive", .darkAqua, false)]
    var means: [String: CGFloat] = [:]
    func phase() {
        guard !phases.isEmpty else { hoverCase(); return }
        let (name, ap, key) = phases.removeFirst()
        NSApp.appearance = NSAppearance(named: ap)
        if key { pw.makeKeyAndOrderFront(nil) } else { other.orderFront(nil); other.makeKey() }
        after(1.0) { (key ? { f in whenKey(pw, f) } : { f in f() })({
            let realKey = pw.isKeyWindow
            let ps = dumpPockets(pw), info = pocketInfo(pw)
            let img = snap(pw, name.replacingOccurrences(of: " ", with: "-"))
            print("[\(name)] real key \(realKey)\n" + info.map { "  \($0.sup) recipe \($0.recipe) \($0.width): \($0.layers)" }.joined(separator: "\n"))
            let variable = ps.flatMap { $0.layers }.filter { filterDesc($0).contains("variableBlur") }
            expect(variable.isEmpty, "[\(name)] no progressive blur (variableBlur) visible anymore (\(variable.count))")
            let tbar = info.filter { $0.sup != "NSScrollView" }
            expect(!tbar.isEmpty && tbar.allSatisfy { $0.recipe == 5 && $0.layers.isEmpty }, "[\(name)] titlebar pocket: Clear, no layers (got \(tbar.map { $0.recipe }))")
            let scrolls = info.filter { $0.sup == "NSScrollView" }
            expect(scrolls.count == 2, "[\(name)] 2 scroll view pockets: content, sidebar (got \(scrolls.count))")
            let dark = ap == .darkAqua
            for p in scrolls {
                let glass = p.width == 200
                expect(p.recipe == (glass ? 4 : 3), "[\(name)] \(p.sup) \(p.width) recipe \(glass ? "ThinFilm over glass" : "Conditional ThinFilm") (got \(p.recipe))")
                // Conditional: key and not hovered -> every layer 0; otherwise 27 ThinFilm.
                let shown = glass || !realKey
                let replay = p.layers["ThinFilmBackgroundReplay"].map { $0.0 } ?? -1
                let wantReplay: Float = shown ? (dark ? 0.6 : 0.5) : 0
                expect(abs(replay - wantReplay) < 0.01, "[\(name)] \(p.width) background replay \(wantReplay) (got \(replay))")
                let dk = p.layers["ThinFilmFillDarken"]?.0 ?? -1, lt = p.layers["ThinFilmFillLighten"]?.0 ?? -1, nm = p.layers["ThinFilmFillNormal"]?.0 ?? -1
                let want: (Float, Float, Float) = shown ? (dark ? (0.6, 0.4, 0) : (0.4, 0.6, 0.25)) : (0, 0, 0)
                expect(abs(dk - want.0) < 0.01 && abs(lt - want.1) < 0.01 && abs(nm - want.2) < 0.01, "[\(name)] \(p.width) blur-fill darken/lighten/normal \(want) (got \(dk), \(lt), \(nm))")
                expect(p.layers["ThinFilmContentBlurFill"]?.1 == "0.5" && p.layers["ThinFilmFillDarken"]?.1 == "0.5", "[\(name)] \(p.width) ContentBlurFill scale 0.5")
                expect(p.layers["Separator"]?.0 == (shown ? 1 : 0), "[\(name)] \(p.width) divider \(shown ? "shown" : "hidden") (got \(p.layers["Separator"]?.0 ?? -1))")
            }
            if let img = img {
                let b = band(img); means[name] = b.mean
                print("[\(name)] content bar band: range \(b.range), mean brightness \(b.mean)")
                if realKey { expect(b.range > 0.6, "[\(name)] key: Conditional transparent, content clearly visible under the bar (range \(b.range) > 0.6)") }
                else { expect(b.range < 0.35, "[\(name)] inactive: content blurred under ThinFilm (range \(b.range) < 0.35, clear stripes > 0.6)") }
            }
            phase()
        }) }
    }
    // Hovering the bar while key: Conditional switches to ThinFilm (calls the tracking area owner like AppKit sending mouseEntered).
    func hoverCase() {
        if let a = means["light inactive"], let b = means["dark inactive"] { expect(a > b + 0.2, "inactive: light bar (\(a)) brighter than dark bar (\(b))") }
        NSApp.appearance = NSAppearance(named: .aqua)
        pw.makeKeyAndOrderFront(nil)
        after(0.8) { whenKey(pw) {
            var ps: [NSView] = []; pockets(pw.contentView!.superview!, &ps)
            let content = ps.first { $0.superview is NSScrollView && $0.frame.width == 500 }
            let owner = content?.trackingAreas.compactMap { $0.owner as? NSObject }.first { NSStringFromClass(type(of: $0)) == "GGHover" }
            owner?.perform(NSSelectorFromString("mouseEntered:"), with: nil)
            after(0.8) {
                let p = pocketInfo(pw).first { $0.sup == "NSScrollView" && $0.width == 500 }
                expect(p?.layers["ThinFilmBackgroundReplay"].map { $0.0 } == 0.5, "hover while key: Conditional shows ThinFilm (background 0.5)")
                if let img = snap(pw, "hover") { let b = band(img); expect(b.range < 0.35, "hover: content blurred under the bar (range \(b.range) < 0.35)") }
                owner?.perform(NSSelectorFromString("mouseExited:"), with: nil)
                titleCase()
            }
        } }
    }
    /// Lowest channel (0-1) down one column (x 300 pt, y 4-60 pt from the top) of the bar in a window snapshot: stripes
    /// showing through give low channels, a background replay over them lifts the minimum.
    func barMin(_ img: CGImage, _ w: NSWindow) -> CGFloat {
        let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(rep.pixelsWide) / w.frame.width
        var lo: CGFloat = 1
        for y in stride(from: 4.0, through: 60.0, by: 1.0) {
            if let c = rep.colorAt(x: Int(300 * s), y: Int(y * s)) { lo = min(lo, c.redComponent, c.greenComponent, c.blueComponent) }
        }
        return lo
    }
    /// 26.6 drawing views of the content (NSScrollView) pocket still on screen (not hidden, alpha > 0).
    func leftover26(_ w: NSWindow) -> [String] {
        var ps: [NSView] = []; pockets(w.contentView!.superview!, &ps)
        return ps.filter { $0.superview is NSScrollView }.flatMap { $0.subviews }.filter { s in
            let c = NSStringFromClass(type(of: s))
            return ["PocketBlur", "NSHardPocketView", "LuminanceAdjustment"].contains { c.hasSuffix($0) } && !s.isHidden && s.alphaValue > 0
        }.map { NSStringFromClass(type(of: $0)) }
    }
    // 27 recipe tree: a toolbar title (NSToolbarTitleStackView, element style 0) picks ThinFilm, not Hard
    // (Photos 27 shows a milky ThinFilm band under its titled toolbar; hiding the title gives Conditional).
    func titleCase() {
        tw.makeKeyAndOrderFront(nil)
        after(1.0) {
            let info = pocketInfo(tw)
            print("[title] " + info.map { "\($0.sup) recipe \($0.recipe)" }.joined(separator: ", "))
            let p = info.first { $0.sup == "NSScrollView" }
            expect(p?.recipe == 2, "window with title text: content pocket is ThinFilm (got \(p.map { String($0.recipe) } ?? "-"))")
            let replay = p?.layers["ThinFilmBackgroundReplay"]?.0 ?? -1
            expect(abs(replay - 0.5) < 0.01, "title ThinFilm: background replay 0.5 even when key and not hovered (got \(replay))")
            expect(p?.layers["Separator"]?.0 == 1, "title ThinFilm: divider shown")
            let left = leftover26(tw)
            expect(left.isEmpty, "title ThinFilm: no 26.6 pocket backdrop left visible (\(left))")
            if let img = snap(tw, "title") { let m = barMin(img, tw); expect(m > 0.62, "title ThinFilm: milky band, background replay visible over the stripes (lowest channel \(m) > 0.62; empty replay 0.54)") }
            hardCase()
        }
    }
    // Hard (setScrollPocketStyle 2) must draw itself and hide every 26.6 layer, whether 26.6 chose its hard or soft
    // drawing for that pocket (Notes: 26.6 soft under a Hard recipe stayed exactly 26.6).
    func hardCase() {
        hw.makeKeyAndOrderFront(nil)
        after(1.0) {
            let info = pocketInfo(hw)
            print("[hard] " + info.map { "\($0.sup) recipe \($0.recipe) \($0.layers)" }.joined(separator: ", "))
            let p = info.first { $0.sup == "NSScrollView" }
            expect(p?.recipe == 1, "style 2: content pocket is HardPocket (got \(p.map { String($0.recipe) } ?? "-"))")
            expect(p?.layers["HardPocketContentBlur"]?.1 == "0.25" && p?.layers["HardPocketContentBlur"]?.0 == 1, "HardPocketContentBlur: shown, scale 0.25")
            let replay = p?.layers["HardPocketBackgroundReplay"]?.0 ?? -1
            expect(abs(replay - 0.8245) < 0.001, "Hard background replay 0.85 * (1 - 0.03) = 0.8245 (got \(replay))")
            expect(p?.layers["Separator"]?.0 == 1, "Hard divider shown")
            let hb = dumpPockets(hw).flatMap { $0.layers }.first { $0.name == "HardPocketContentBlur" }
            expect(filterDesc(hb ?? CALayer()).contains("gaussianBlur(6"), "HardPocketContentBlur: gaussianBlur 6 (got \(hb.map { filterDesc($0) } ?? "-"))")
            let left = leftover26(hw)
            expect(left.isEmpty, "Hard: no 26.6 pocket backdrop left visible (\(left))")
            if let img = snap(hw, "hard") { let m = barMin(img, hw); expect(m > 0.75, "Hard: 82% background over the blurred stripes (lowest channel \(m) > 0.75; empty replay 0.22)") }
            emptyCase()
        }
    }
    // Untitled toolbar window whose content is not a scroll view yet (App Store while a page loads): the titlebar pocket
    // is not covered by a scroll view pocket. 27 tree without a title -> Conditional, so a key window shows the content
    // color under the bar instead of a band (was Hard: windowBackgroundColor at 82% over the content, a dark block).
    func emptyCase() {
        cw.makeKeyAndOrderFront(nil)
        after(1.0) { whenKey(cw) {
            let info = pocketInfo(cw)
            print("[empty] key \(cw.isKeyWindow) " + info.map { "\($0.sup) recipe \($0.recipe)" }.joined(separator: ", "))
            let p = info.first { $0.sup == "NSTitlebarBackgroundView" }
            expect(p?.recipe == 3, "untitled toolbar, no scroll view: titlebar pocket is Conditional (got \(p.map { String($0.recipe) } ?? "-"))")
            if cw.isKeyWindow, let img = snap(cw, "empty") {
                let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(rep.pixelsWide) / cw.frame.width
                let bar = rep.colorAt(x: Int(250 * s), y: Int(45 * s))!, body = rep.colorAt(x: Int(250 * s), y: Int(200 * s))!
                let d = max(abs(bar.redComponent - body.redComponent), abs(bar.greenComponent - body.greenComponent), abs(bar.blueComponent - body.blueComponent))
                expect(d < 0.02, "key, nothing scrolled under the bar: bar shows the content color, no band (max channel difference \(d) < 0.02)")
            } else { print("SKIP key-only pixel check: window did not become key") }
            // Inactive: ThinFilm shows, and its background replay must replay the real (brown) background, not a stock
            // window color.
            other.orderFront(nil); other.makeKey()
            after(1.0) {
                if !cw.isKeyWindow, let img = snap(cw, "empty-inactive") {
                    let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(rep.pixelsWide) / cw.frame.width
                    let bar = rep.colorAt(x: Int(250 * s), y: Int(45 * s))!, body = rep.colorAt(x: Int(250 * s), y: Int(200 * s))!
                    let d = max(abs(bar.redComponent - body.redComponent), abs(bar.greenComponent - body.greenComponent), abs(bar.blueComponent - body.blueComponent))
                    expect(d < 0.1, "inactive ThinFilm over plain content keeps the real background color (max channel difference \(d) < 0.1)")
                } else { print("SKIP inactive pixel check: window still key") }
                print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
            }
        } }
    }
    after(1.0) { whenKey(pw) { tw.orderFront(nil); pw.makeKeyAndOrderFront(nil); phase() } }
}

// ---- toolbar: pressing buttons in NSToolbar glass platters (ToolbarPress.swift), light then dark ----

final class TBPressDelegate: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("nav"), .space, .init("one"), .space, .init("dis"), .flexibleSpace, .init("seg")] }   // .space: one platter per item
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let img = { (n: String) in NSImage(systemSymbolName: n, accessibilityDescription: nil)! }
        switch id.rawValue {
        case "nav":   // like Back/Forward: a group of two buttons sharing one platter
            let g = NSToolbarItemGroup(itemIdentifier: id, images: [img("chevron.left"), img("chevron.right")], selectionMode: .momentary,
                                       labels: ["Back", "Forward"], target: self, action: #selector(act))
            g.controlRepresentation = .expanded
            return g
        case "seg":
            let i = NSToolbarItem(itemIdentifier: id)
            // momentary: no segment stays selected after release, so the release image compares with the rest image
            i.view = NSSegmentedControl(labels: ["One", "Two", "Three"], trackingMode: .momentary, target: self, action: #selector(act))
            return i
        default:
            let i = NSToolbarItem(itemIdentifier: id); i.image = img(id.rawValue == "dis" ? "trash" : "star"); i.label = id.rawValue
            i.isBordered = true; i.target = self; i.action = #selector(act)
            if id.rawValue == "dis" { i.autovalidates = false; i.isEnabled = false }
            return i
        }
    }
    @objc func act(_ s: Any?) { print("ACTION toolbar \(s.map { "\(type(of: $0))" } ?? "")") }
}
let tbPressDelegate = TBPressDelegate()

func toolbarDebug() -> [String: Double] {
    guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_toolbar_press_debug").map({ unsafeBitCast($0, to: DebugFn.self) }),
          let d = try? JSONSerialization.jsonObject(with: Data(String(cString: f()).utf8)) as? [String: Double] else { return [:] }
    return d
}

func allViews(_ v: NSView, _ name: String, _ out: inout [NSView]) {
    if NSStringFromClass(type(of: v)) == name { out.append(v) }
    v.subviews.forEach { allViews($0, name, &out) }
}

/// Compares two captures of window w within area r (window coordinates, origin bottom left; image row 0 = top edge): number
/// of differing pixels (sum |ΔRGB| > 0.1), their bounding box, mean R+G+B inside the box in each image.
func imageDiff(_ a: CGImage, _ b: CGImage, in r: NSRect, of w: NSWindow) -> (count: Int, w: Int, h: Int, lumaA: Double, lumaB: Double) {
    let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b), s = w.backingScaleFactor, H = w.frame.height
    var n = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    let ys = max(0, Int((H - r.maxY) * s))..<min(ra.pixelsHigh, rb.pixelsHigh, Int((H - r.minY) * s))
    let xs = max(0, Int(r.minX * s))..<min(ra.pixelsWide, rb.pixelsWide, Int(r.maxX * s))
    for y in ys { for x in xs {
        let p = ra.colorAt(x: x, y: y)!, q = rb.colorAt(x: x, y: y)!
        if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.1 {
            n += 1; x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        }
    } }
    guard n > 0 else { return (0, 0, 0, 0, 0) }
    var la = 0.0, lb = 0.0
    for y in y0...y1 { for x in x0...x1 {
        let p = ra.colorAt(x: x, y: y)!, q = rb.colorAt(x: x, y: y)!
        la += Double(p.redComponent + p.greenComponent + p.blueComponent); lb += Double(q.redComponent + q.greenComponent + q.blueComponent)
    } }
    let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
    return (n, x1 - x0 + 1, y1 - y0 + 1, la / area, lb / area)
}

/// Mean R+G+B of an area (window coordinates, origin bottom left) in a window capture (row 0 = top edge).
func lumaIn(_ img: CGImage, _ r: NSRect, _ w: NSWindow) -> Double {
    let rep = NSBitmapImageRep(cgImage: img), s = w.backingScaleFactor, H = w.frame.height
    var sum = 0.0, n = 0
    for y in Int((H - r.maxY) * s)..<Int((H - r.minY) * s) { for x in Int(r.minX * s)..<Int(r.maxX * s) {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        sum += Double(c.redComponent + c.greenComponent + c.blueComponent); n += 1
    } }
    return n > 0 ? sum / Double(n) : 0
}

func runToolbar() {
    let tw = NSWindow(contentRect: NSRect(x: 150, y: 250, width: 640, height: 260), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    let bg = NSView(); bg.wantsLayer = true; bg.layer?.backgroundColor = NSColor(red: 0.15, green: 0.45, blue: 0.55, alpha: 1).cgColor
    tw.contentView = bg
    let tb = NSToolbar(identifier: "ggpress"); tb.delegate = tbPressDelegate; tb.displayMode = .iconOnly; tw.toolbar = tb
    tw.makeKeyAndOrderFront(nil)
    // Each case: (name, point in the platter as a horizontal ratio, should grow?). Platters are found left to right.
    var phases: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    func phase() {
        guard !phases.isEmpty else { print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1) }
        let (pname, ap) = phases.removeFirst()
        tw.appearance = NSAppearance(named: ap)
        after(0.8) { whenKey(tw) {
            var ps: [NSView] = []; allViews(tw.contentView!.superview!, "NSToolbarPlatterView", &ps)
            ps.sort { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            expect(ps.count == 4, "[\(pname)] 4 platters (group, button, disabled button, segmented), got \(ps.count)")
            guard ps.count == 4 else { phase(); return }
            // (name, platter, press point as a horizontal ratio, should grow?, glow probe area as a horizontal ratio). 26.6 tints
            // the pressed button background itself (light: darker, dark: brighter), so glow is measured on the unpressed part
            // of the platter; single buttons only check debug values.
            // Last element: capture time after mouseDown. The first case is a plain click (held about 0.1 s) and the first
            // press on that platter (user-visible bug: plain clicks had no effect, a second click was needed).
            var cases: [(String, NSView, CGFloat, Bool, ClosedRange<CGFloat>?, Double)] = [
                ("plain click single button", ps[1], 0.5, true, nil, 0.09),
                ("Back-Forward group", ps[0], 0.25, true, 0.62...0.88, 0.25), ("single button", ps[1], 0.5, true, nil, 0.25),
                ("disabled button", ps[2], 0.5, false, nil, 0.25), ("segmented", ps[3], 0.15, true, 0.55...0.9, 0.25)]
            // The machine in use (or another session's test app) may steal focus: clicking a non-key window makes AppKit
            // activate it instead of tracking, and the toolbar dims. A case that loses key during press/hold/release reruns, up to 3 times.
            var tries: [String: Int] = [:]
            func next() {
                guard !cases.isEmpty else { phase(); return }
                whenKey(tw) { after(0.3) { run(cases.removeFirst()) } }
            }
            func run(_ c: (String, NSView, CGFloat, Bool, ClosedRange<CGFloat>?, Double)) {
                let (name, p, fx, lifts, probe, hold) = c
                let r = p.convert(p.bounds, to: nil), s = tw.backingScaleFactor
                let pt = NSPoint(x: r.minX + r.width * fx, y: r.midY)
                let probeRect = probe.map { NSRect(x: r.minX + r.width * $0.lowerBound, y: r.midY - 8, width: r.width * ($0.upperBound - $0.lowerBound), height: 16) }
                guard let idle = snap(tw, "\(pname)-\(name)-0") else { next(); return }
                var keyAll = true
                func retry() -> Bool {   // true if this case lost key and will rerun
                    guard !keyAll else { return false }
                    let n = (tries[name] ?? 0) + 1; tries[name] = n
                    if n < 3 { print("RERUN [\(pname)] \(name): window lost key"); cases.insert(c, at: 0); return true }
                    expect(false, "[\(pname)] \(name): window lost key 3 times, could not check"); return true
                }
                // The release Timer is scheduled together with sending mouseDown (not before): if mouseUp arrives before
                // mouseDown, the button tracking loop waits forever (seen with the 0.09 s hold case when the after block was late).
                after(0.05) {
                    keyAll = tw.isKeyWindow
                    RunLoop.main.add(Timer(timeInterval: hold, repeats: false) { _ in held() }, forMode: .common)
                    mouse(tw, .leftMouseDown, pt)   // the button runs its nested tracking loop here
                }
                func held() {   // 0.25 s after the press, still held
                    keyAll = keyAll && tw.isKeyWindow
                    // The button decides inside/outside from the last drag event: drag out, then release so the action does not run.
                    func releaseOutside() {
                        for t in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
                            NSApp.postEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: pt.x, y: pt.y - 150), modifierFlags: [], timestamp: 0,
                                                               windowNumber: tw.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
                        }
                    }
                    if !keyAll { releaseOutside(); after(0.8) { _ = retry(); next() }; return }
                    let dbg = toolbarDebug()
                    let heldImg = snap(tw, "\(pname)-\(name)-1")
                    // Compare only around the platter under test (grown 8 pt): 26.6 NSToolbarItemGroup keeps/clears the highlight of a previously pressed segment itself.
                    let d = heldImg.map { imageDiff(idle, $0, in: r.insetBy(dx: -8, dy: -8), of: tw) } ?? (count: 0, w: 0, h: 0, lumaA: 0, lumaB: 0)
                    let grew = Double(d.w) >= Double(r.width + 1.2) * s && Double(d.h) >= Double(r.height + 1.5) * s
                    if lifts {
                        expect(grew, "[\(pname)] \(name): glass grows while held (platter \(Int(r.width))x\(Int(r.height)) pt, changed area \(d.w)x\(d.h) px, x\(s))")
                        if let pr = probeRect, let h = heldImg {
                            let (a, b) = (lumaIn(idle, pr, tw), lumaIn(h, pr, tw))
                            expect(b - a > 0.04, "[\(pname)] \(name): glow brightens the unpressed part (luma \(String(format: "%.3f -> %.3f", a, b)))")
                        }
                        // Press spring 0.262/0.625, target 1.069: about 1.047 at 0.075 s (debug only integrates to the latest tick), 1.068 at 0.25 s.
                        let minScale = hold < 0.2 ? 1.04 : 1.05
                        expect((dbg["scale"] ?? 1) > minScale, "[\(pname)] \(name): scale > \(minScale) while held (got \(dbg["scale"] ?? -1))")
                        expect((dbg["bigGlow"] ?? 0) > 0.3, "[\(pname)] \(name): BigGlow > 0.3 while held (got \(dbg["bigGlow"] ?? -1))")
                        // 27 puts item viewers in the platter glass contentView, so the button grows with the glass.
                        expect((dbg["content"] ?? 0) >= 1, "[\(pname)] \(name): button (item viewer) grows with the glass (got \(dbg["content"] ?? -1) views)")
                        // The real glass is drawn together in NSGlassContainerView (one CASDFElementLayer per platter), not in
                        // NSToolbarPlatterView: the glass outline must stretch with the button (user-visible bug: button overflowing the outline).
                        expect((dbg["glass"] ?? 0) == 1, "[\(pname)] \(name): platter glass shape (CASDFElementLayer) stretches along (got \(dbg["glass"] ?? -1))")
                    } else {
                        expect(!grew && (dbg["scale"] ?? 1) < 1.001, "[\(pname)] \(name): does not grow (changed area \(d.w)x\(d.h) px, scale \(dbg["scale"] ?? -1))")
                    }
                    releaseOutside()
                    after(0.8) {
                        keyAll = keyAll && tw.isKeyWindow
                        if retry() { next(); return }
                        let back = snap(tw, "\(pname)-\(name)-2").map { imageDiff(idle, $0, in: r.insetBy(dx: -8, dy: -8), of: tw) } ?? (count: -1, w: 0, h: 0, lumaA: 0, lumaB: 0)
                        let dbg2 = toolbarDebug()
                        expect(abs((dbg2["scale"] ?? 0) - 1) < 0.001 && (dbg2["bigGlow"] ?? 1) < 0.01,
                               "[\(pname)] \(name): release returns scale/glow to rest (scale \(dbg2["scale"] ?? -1), glow \(dbg2["bigGlow"] ?? -1), presses \(dbg["presses"] ?? -1) -> \(dbg2["presses"] ?? -1))")
                        expect(back.count >= 0 && Double(back.count) < Double(r.width * r.height * s * s) * 0.03,
                               "[\(pname)] \(name): release returns the image to rest (\(back.count) differing pixels)")
                        next()
                    }
                }
            }
            next()
        } }
    }
    after(0.5) { phase() }
}

/// 27 slider path: the NSGlassEffectView glassBackground filter must carry the slider amount code in inputClampPreserveHue,
/// even when 26.6 rebuilds the filter (resize, key loss), and follow NSGlassTintAmount on recommit. GG_LEGIBILITY: path of
/// the built GGLegibility.dylib.
func runLegibility() {
    let prefs = ProcessInfo.processInfo.environment["GG_PREFS"]!
    func setTint(_ v: Double) {
        let d = NSMutableDictionary(contentsOfFile: prefs) ?? NSMutableDictionary()
        d["NSGlassTintAmount"] = v; d.write(toFile: prefs, atomically: true)
    }
    setTint(0.3)
    guard let h = dlopen(ProcessInfo.processInfo.environment["GG_LEGIBILITY"], RTLD_NOW) else { print("FAIL cannot load GGLegibility: \(String(cString: dlerror()))"); exit(1) }
    typealias V = @convention(c) () -> Void
    typealias B = @convention(c) () -> Bool
    typealias R = @convention(c) (UnsafeRawPointer, UInt32) -> Void
    func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
    guard let install = sym("gg_legibility_install", V.self), let needs = sym("gg_legibility_needs_update", B.self),
          let recommit = sym("gg_legibility_recommit", V.self) else { print("FAIL missing GGLegibility symbol"); exit(1) }
    install()
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let g = NSGlassEffectView(frame: NSRect(x: 40, y: 40, width: 200, height: 80))
    w.contentView!.addSubview(g)
    w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    func glassLayers(_ l: CALayer, _ out: inout [CALayer]) {
        if (l.filters ?? []).contains(where: { (($0 as AnyObject).value(forKey: "type") as? String) == "glassBackground" }) { out.append(l) }
        for s in l.sublayers ?? [] { glassLayers(s, &out) }
    }
    func codes(_ win: NSWindow? = nil) -> [Int] {
        var ls: [CALayer] = []; glassLayers((win ?? w).contentView!.superview!.layer!, &ls)
        return ls.map { ($0.value(forKeyPath: "filters.glassBackground.inputClampPreserveHue") as? NSNumber)?.intValue ?? -1 }
    }
    // Glass in a view carries that view's appearance (like 27): negative code -(2 + 4 round(a 500) + 2 dark + flag). Window w follows the system.
    func isDark(_ v: NSView) -> Bool { v.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    func code(_ a: Double, dark: Bool? = nil) -> Int { -(2 + 4 * Int((a * 500).rounded()) + ((dark ?? isDark(g)) ? 2 : 0)) }
    func presentationCodes() -> [Int] {
        var ls: [CALayer] = []; glassLayers(w.contentView!.superview!.layer!, &ls)
        return ls.map { ($0.presentation()?.value(forKeyPath: "filters.glassBackground.inputClampPreserveHue") as? NSNumber)?.intValue ?? -1 }
    }
    after(1.0) {
        let c0 = codes()
        expect(!c0.isEmpty && c0.allSatisfy { $0 == code(0.3) }, "filter carries the code after creation (\(c0), want \(code(0.3)))")
        w.setFrame(NSRect(x: 220, y: 220, width: 380, height: 240), display: true)
        g.frame = NSRect(x: 40, y: 40, width: 220, height: 90)
        after(0.5) {
            let c1 = codes()
            expect(!c1.isEmpty && c1.allSatisfy { $0 == code(0.3) }, "code kept after resize (\(c1))")
            w.resignKey(); NSApp.deactivate()
            after(0.5) {
                let c2 = codes()
                expect(!c2.isEmpty && c2.allSatisfy { $0 == code(0.3) }, "code kept after key loss (\(c2))")
                setTint(0.8)
                let changed = needs()
                recommit()
                after(0.3) {
                    let c3 = codes(), p3 = presentationCodes()
                    expect(changed && !c3.isEmpty && c3.allSatisfy { $0 == code(0.8) } && p3.allSatisfy { $0 == code(0.8) },
                           "recommit changes the value (needs \(changed), model \(c3), presentation \(p3))")
                    // A self-made filter with original preserve flag 1, assigned via setFilters:, must keep the flag in the code.
                    let own = CALayer(), f = (NSClassFromString("CAFilter") as! NSObject.Type).perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")!.takeUnretainedValue() as! NSObject
                    f.setValue(1, forKey: "inputClampPreserveHue")
                    own.filters = [f]
                    let oc = ((own.filters?.first as AnyObject?)?.value(forKey: "inputClampPreserveHue") as? NSNumber)?.intValue ?? -1
                    expect(oc == 1603, "original preserve flag kept (\(oc))")
                    if let receive = sym("gg_legibility_test_receive", R.self) {   // receiving type 12 applies by itself
                        setTint(0.1)
                        var payload: [UInt32] = [12, 0, 0, 0]
                        receive(&payload, 16)
                        after(0.5) {
                            let c4 = codes()
                            expect(!c4.isEmpty && c4.allSatisfy { $0 == code(0.1) }, "receiving type 12 applies the new value (\(c4))")
                            // Windows with their own appearance (dark in a light system and vice versa): glass carries the
                            // window appearance, not the system one.
                            func glassWindow(_ name: NSAppearance.Name, _ x: CGFloat) -> NSWindow {
                                let win = NSWindow(contentRect: NSRect(x: x, y: 480, width: 300, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
                                win.appearance = NSAppearance(named: name)
                                win.contentView!.addSubview(NSGlassEffectView(frame: NSRect(x: 30, y: 30, width: 200, height: 70)))
                                win.orderFront(nil)
                                return win
                            }
                            let wd = glassWindow(.darkAqua, 200), wl = glassWindow(.aqua, 540)
                            after(0.8) {
                                let cd = codes(wd), cl = codes(wl)
                                expect(!cd.isEmpty && cd.allSatisfy { $0 == code(0.1, dark: true) }, "dark window: glass carries the dark code (\(cd))")
                                expect(!cl.isEmpty && cl.allSatisfy { $0 == code(0.1, dark: false) }, "light window: glass carries the light code (\(cl))")
                                // Changing the window appearance: like 27 (recipe recomputed from effectiveAppearance, then
                                // committed), the glass switches appearance at once without waiting for a rebuild.
                                wd.appearance = NSAppearance(named: .aqua); wl.appearance = NSAppearance(named: .darkAqua)
                                after(0.3) {
                                    let cd2 = codes(wd), cl2 = codes(wl)
                                    expect(!cd2.isEmpty && cd2.allSatisfy { $0 == code(0.1, dark: false) }, "dark window switched to light: glass code changes (\(cd2))")
                                    expect(!cl2.isEmpty && cl2.allSatisfy { $0 == code(0.1, dark: true) }, "light window switched to dark: glass code changes (\(cl2))")
                                    print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
                                }
                            }
                        }
                    } else { print("FAIL missing gg_legibility_test_receive"); exit(1) }
                }
            }
        }
    }
}

// ---- recipes: the app computes glass 27 recipes and writes the real values + recipe codes (Legibility/Recipe.m).
// Run: tests/app.sh recipes GG_ABI_FAKE=2 (and =0: nothing new is written).

struct RecipeButton: View { var body: some View { Button("Glass") {}.buttonStyle(.glass).padding(30) } }

func runRecipes() {
    let abi = ProcessInfo.processInfo.environment["GG_ABI_FAKE"] ?? "2"
    guard let h = dlopen(ProcessInfo.processInfo.environment["GG_LEGIBILITY"], RTLD_NOW) else { print("FAIL cannot load GGLegibility"); exit(1) }
    typealias V = @convention(c) () -> Void
    typealias D = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Bool>,
                                  UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Float>) -> Bool
    guard let install = dlsym(h, "gg_legibility_install").map({ unsafeBitCast($0, to: V.self) }),
          let decode = dlsym(h, "gg_recipe_decode").map({ unsafeBitCast($0, to: D.self) }) else { print("FAIL missing symbol"); exit(1) }
    install()
    struct Info { let code: Int32; let recipe: Int32; let inactive: Bool; let dark: Bool; let ok: Bool; let black: Double; let white: Double; let inner: Double; let innerH: Double; let size: CGSize }
    func info(_ l: CALayer) -> Info {
        let code = (l.value(forKeyPath: "filters.glassBackground.inputClampPreserveHue") as? NSNumber)?.int32Value ?? 0
        var r: Int32 = -1, i = false, d = false, f: Int32 = 0, a: Float = 0
        let ok = decode(code, &r, &i, &d, &f, &a)
        func n(_ k: String) -> Double { (l.value(forKeyPath: "filters.glassBackground.\(k)") as? NSNumber)?.doubleValue ?? .nan }
        return Info(code: code, recipe: r, inactive: i, dark: d, ok: ok, black: n("inputFaceColorMatrixBlack"), white: n("inputFaceColorMatrixWhite"),
                    inner: n("inputInnerRefractionAmount"), innerH: n("inputInnerRefractionHeight"), size: l.bounds.size)
    }
    func glass(_ v: NSView) -> [CALayer] {
        var out: [CALayer] = []
        func walk(_ l: CALayer) {
            if (l.filters ?? []).contains(where: { (($0 as AnyObject).value(forKey: "type") as? String) == "glassBackground" }) { out.append(l) }
            for s in l.sublayers ?? [] { walk(s) }
        }
        if let l = v.layer { walk(l) }
        return out
    }
    func dark(_ v: NSView) -> Bool { v.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 360, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: RecipeButton()); host.frame = NSRect(x: 0, y: 120, width: 200, height: 110)
    let g = NSGlassEffectView(frame: NSRect(x: 220, y: 40, width: 80, height: 40))
    w.contentView!.addSubview(host); w.contentView!.addSubview(g)
    w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    let frameView = w.contentView!.superview!
    after(1.2) {
        let gi = glass(g).map(info), all = glass(frameView).map(info)
        if abi != "2" {
            expect(!all.isEmpty && all.allSatisfy { abs($0.code) < 2048 && !$0.ok }, "ABI \(abi): old codes only (\(all.map { $0.code }))")
            // 26.6 face (regular or adaptive to the background), not the 27 face the app writes (0.4 light, 0.125 dark, 0.08 inactive dark).
            expect(!gi.isEmpty && gi.allSatisfy { x in ![0.4, 0.125, 0.08].contains(where: { b in abs(x.black - b) < 1e-4 }) },
                   "ABI \(abi): 26.6 face kept (\(gi.map { $0.black }))")
            print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
        }
        let dk = dark(g)
        expect(!gi.isEmpty && gi.allSatisfy { $0.ok && $0.recipe == 0 && !$0.inactive && $0.dark == dk },
               "NSGlassEffectView key: regular recipe code, active, appearance from the view (\(gi.map { ($0.code, $0.recipe, $0.inactive) }))")
        expect(!gi.isEmpty && gi.allSatisfy { abs($0.inner + 20) < 1e-3 && abs($0.black - (dk ? 0.125 : 0.4)) < 1e-4 },
               "NSGlassEffectView 80x40: x = 40 (inner -20), face 27 (\(gi.map { ($0.inner, $0.black) }))")
        let bi = glass(host).map(info)
        expect(!bi.isEmpty && bi.allSatisfy { $0.ok && $0.recipe == 0 && !$0.inactive }, "SwiftUI .glass button key: regular active recipe (\(bi.map { ($0.code, $0.recipe, $0.inactive, $0.size) }))")
        // A filter already carrying a code (27 regular light face 0.4/1.03/1.2 matches sidebar signature #17) assigned to a new
        // layer with no identity: the recipe must follow the code, not re-read the 27 face as sidebar.
        if let src = glass(g).first?.filters?.first as? NSObject, let copy = src.copy() as? NSObject {
            copy.setValue(0.4, forKey: "inputFaceColorMatrixBlack"); copy.setValue(1.03, forKey: "inputFaceColorMatrixWhite")
            copy.setValue(1.2, forKey: "inputFaceColorMatrixSaturation")
            copy.setValue(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2).cgColor, forKey: "inputFaceColorMatrixFillColor")
            var code = Int32(0)
            if let enc = dlsym(h, "gg_recipe_encode") {
                typealias E = @convention(c) (Int32, Bool, Bool, Int32, Float) -> Int32
                code = unsafeBitCast(enc, to: E.self)(0, false, false, 0, 0.5)
            }
            copy.setValue(code, forKey: "inputClampPreserveHue")
            let bl = (NSClassFromString("CABackdropLayer") as! CALayer.Type).init()
            bl.bounds = CGRect(x: 0, y: 0, width: 60, height: 30)
            bl.filters = [copy]
            let ci = info(bl)
            expect(ci.ok && ci.recipe == 0, "coded filter on a new layer: recipe follows the code (\(ci.code), recipe \(ci.recipe))")
        } else { expect(false, "coded filter: could not get the filter") }
        w.resignKey(); NSApp.deactivate()
        after(0.8) {
            let gi2 = glass(g).map(info), bi2 = glass(host).map(info)
            expect(!gi2.isEmpty && gi2.allSatisfy { $0.ok && $0.recipe == 0 && $0.inactive && (dk ? abs($0.black - 0.08) < 1e-4 : abs($0.white - 0.96) < 1e-4) },
                   "NSGlassEffectView non-key: inactive, 27 inactive face (\(gi2.map { ($0.inactive, $0.black, $0.white) }))")
            expect(!bi2.isEmpty && bi2.allSatisfy { $0.ok && $0.recipe == 0 && $0.inactive },
                   "SwiftUI .glass button non-key: carries the inactive code (\(bi2.map { ($0.code, $0.inactive) }))")
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let p = NSPopover(); let vc = NSViewController(); vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 70)); p.contentViewController = vc
            p.show(relativeTo: NSRect(x: 60, y: 40, width: 20, height: 20), of: w.contentView!, preferredEdge: .maxY)
            after(1.0) {
                guard let pw = vc.view.window, let pf = pw.contentView?.superview else { expect(false, "popover: no window"); exit(1) }
                let pi = glass(pf).map(info)
                let act = (pw.value(forKey: "_hasActiveAppearance") as? Bool) ?? true
                expect(!pi.isEmpty && pi.allSatisfy { $0.ok && $0.recipe == 6 && abs($0.innerH - 5) < 1e-4 && $0.inactive == !act },
                       "popover with an arrow: recipe 6, inner height 5, inactive per window (\(pi.map { ($0.code, $0.recipe, $0.innerH, $0.inactive, $0.size) }), active \(act))")
                p.close()
                let wd = NSWindow(contentRect: NSRect(x: 600, y: 300, width: 300, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
                wd.appearance = NSAppearance(named: dk ? .aqua : .darkAqua)
                wd.contentView!.addSubview(NSGlassEffectView(frame: NSRect(x: 30, y: 30, width: 200, height: 70)))
                wd.orderFront(nil)
                after(0.8) {
                    let di = glass(wd.contentView!.superview!).map(info)
                    expect(!di.isEmpty && di.allSatisfy { $0.ok && $0.dark == !dk && ($0.code < 0) == !dk },
                           "window with the opposite appearance: code carries the window appearance (\(di.map { ($0.code, $0.dark) }))")
                    // Window only ordered front (not key): inactive, 27 inactive face per its appearance.
                    expect(!di.isEmpty && di.allSatisfy { $0.inactive && (!dk ? abs($0.black - 0.08) < 1e-4 : abs($0.white - 0.96) < 1e-4) },
                           "opposite appearance window, non-key: 27 inactive face (\(di.map { ($0.inactive, $0.black, $0.white) }))")
                    // NotificationCenter (GG_HOST_NC): widget glass in a view whose appearance is opposite to the face. 27 takes the
                    // widget light/dark from the tint style (face), not the appearance.
                    setenv("GG_HOST_NC", "1", 1)
                    let wv = NSView(frame: NSRect(x: 0, y: 0, width: 164, height: 164)); wv.wantsLayer = true
                    wd.contentView!.addSubview(wv)
                    let wl = (NSClassFromString("CABackdropLayer") as! CALayer.Type).init()
                    wl.bounds = CGRect(x: 0, y: 0, width: 164, height: 164); wv.layer!.addSublayer(wl)
                    let wf = (NSClassFromString("CAFilter") as! NSObject.Type).perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")!
                        .takeUnretainedValue() as! NSObject
                    let faceDark = dk   // wd has the opposite of the system appearance: !dk
                    wf.setValue(faceDark ? 0.05 : 0.12, forKey: "inputFaceColorMatrixBlack")
                    wf.setValue(faceDark ? 0.3 : 0.8, forKey: "inputFaceColorMatrixWhite")
                    wf.setValue(faceDark ? 0.8 : 1.2, forKey: "inputFaceColorMatrixSaturation")
                    wl.filters = [wf]
                    let wi = info(wl)
                    expect(wi.ok && wi.recipe == 7 && wi.dark == faceDark && dark(wv) != faceDark,
                           "NotificationCenter: widget recipe 7, light/dark from the face, not the view (\(wi.code), recipe \(wi.recipe), dark \(wi.dark), view dark \(dark(wv)))")
                    unsetenv("GG_HOST_NC")
                    print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
                }
            }
        }
    }
}

// ---- sidebar: 27 style sidebars (Sources/Sidebar.m), AppKit and SwiftUI, light/dark, key/inactive ----

final class SBData: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let items = [("Recents", "clock"), ("Applications", "app.badge"), ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"), ("🎉 Party", "star")]
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? items.count : 0 }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { items[i].0 }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        let name = item as! String, sym = items.first { $0.0 == name }!.1
        let v = NSTableCellView(), iv = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)!), tf = NSTextField(labelWithString: name)
        v.addSubview(iv); v.addSubview(tf); v.imageView = iv; v.textField = tf
        iv.translatesAutoresizingMaskIntoConstraints = false; tf.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6), tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        return v
    }
}
let sbData = SBData()

struct SBSwiftUI: View {
    @State var sel: String? = "Recents"
    var body: some View {
        NavigationSplitView {
            List(selection: $sel) {
                Label("Recents", systemImage: "clock").tag("Recents")
                Label("Applications", systemImage: "app.badge").tag("Applications")
                Label("Documents", systemImage: "doc").tag("Documents")
            }.listStyle(.sidebar)
        } detail: { Color.white }
    }
}

func sbViews(_ v: NSView, _ cls: String, _ out: inout [NSView]) {
    if NSStringFromClass(type(of: v)) == cls { out.append(v) }
    v.subviews.forEach { sbViews($0, cls, &out) }
}

/// First glassBackground filter in the layer tree of l.
func sbGlassFilter(_ l: CALayer) -> NSObject? {
    if let f = (l.filters ?? []).first(where: { (($0 as AnyObject).value(forKey: "type") as? String) == "glassBackground" }) { return f as? NSObject }
    for s in l.sublayers ?? [] { if let f = sbGlassFilter(s) { return f } }
    return nil
}

/// Most saturated pixel in the first 28 pt of row `row` of a SwiftUI List(.sidebar) (icon area), in a capture of window w.
func sbSwiftUIIcon(_ w: NSWindow, _ img: CGImage, row: Int) -> NSColor? {
    func find(_ v: NSView) -> NSOutlineView? { (v as? NSOutlineView) ?? v.subviews.lazy.compactMap(find).first }
    guard let ov = find(w.contentView!.superview!), let rv = ov.rowView(atRow: row, makeIfNecessary: false) else { return nil }
    let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(rep.pixelsWide) / w.frame.width
    var rc = rv.convert(rv.bounds, to: nil); rc.size.width = 28 + 16; rc.origin.x += 8
    var best: NSColor?, bs: CGFloat = -1
    for y in Int(rc.minY * s)..<Int(rc.maxY * s) { for x in Int(rc.minX * s)..<Int(rc.maxX * s) {
        guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
        let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
        if sat > bs { bs = sat; best = c }
    } }
    return best
}

func sbWeight(_ f: NSFont?) -> CGFloat {
    ((f?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? -9
}

func runSidebar() {
    // Like Music: the app explicitly enables floating and defaults enable floating; 27 drops floating entirely (wantsFloatingAppearance always NO).
    UserDefaults.standard.setVolatileDomain(["NSSplitViewItemSidebarDefaultsToFloatingAppearance": true], forName: UserDefaults.argumentDomain)
    let glassOn = (NSDictionary(contentsOfFile: ProcessInfo.processInfo.environment["GG_PREFS"] ?? "")?["GGApp.sidebarGlass"] as? Bool) ?? false
    func panel(_ x: CGFloat) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: x, y: 200, width: 560, height: 360), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        return p
    }
    let pa = panel(100), ps = panel(700)
    let split = NSSplitViewController(), side = NSViewController(), sv = NSScrollView(), ov = NSOutlineView()
    let col = NSTableColumn(identifier: .init("c")); ov.addTableColumn(col); ov.outlineTableColumn = col; ov.headerView = nil
    ov.style = .sourceList; ov.dataSource = sbData; ov.delegate = sbData
    sv.documentView = ov; sv.drawsBackground = false; side.view = sv
    let item = NSSplitViewItem(sidebarWithViewController: side)
    item.setValue(true, forKey: "wantsFloatingAppearance")
    let main = NSViewController(); main.view = NSView()
    split.addSplitViewItem(item); split.addSplitViewItem(NSSplitViewItem(viewController: main))
    pa.contentViewController = split; pa.toolbar = NSToolbar(identifier: "sb")
    pa.setFrame(NSRect(x: 100, y: 200, width: 560, height: 360), display: true)
    ov.rowSizeStyle = .default   // like an IB-built sidebar (outlines created in code default to custom: own font, unchanged by 27)
    ov.reloadData(); ov.selectRowIndexes([1], byExtendingSelection: false)
    ps.contentViewController = NSHostingController(rootView: SBSwiftUI())
    ps.setFrame(NSRect(x: 700, y: 200, width: 560, height: 360), display: true)
    pa.orderFront(nil); ps.orderFront(nil)
    let other = NSWindow(contentRect: NSRect(x: 1300, y: 200, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)

    func cell(_ r: Int) -> NSTableCellView? { ov.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView }
    /// Shared checks for one window: not floating, edge sidebar glass (variant 17), 27 SidebarRecipe glass parameters.
    func checkGlass(_ tag: String, _ w: NSWindow, dark: Bool) {
        var gs: [NSView] = []; sbViews(w.contentView!.superview!, "NSContainerConcentricGlassEffectView", &gs)
        guard let g = gs.first, let wrap = g.superview else { expect(false, "[\(tag)] sidebar glass present"); return }
        let it = wrap.value(forKey: "splitViewItem") as? NSObject
        expect((it?.value(forKey: "_hasFloatingAppearance") as? Bool) == false && (it?.value(forKey: "wantsFloatingAppearance") as? Bool) == false,
               "[\(tag)] not floating (has \(it?.value(forKey: "_hasFloatingAppearance") ?? "-"), wants \(it?.value(forKey: "wantsFloatingAppearance") ?? "-"))")
        expect((g.value(forKey: "_variant") as? Int) == 17 && g.frame == wrap.bounds && g.layer?.cornerRadius == 0,
               "[\(tag)] edge glass: variant 17, frame = wrapper, radius 0 (got \(g.value(forKey: "_variant") ?? "-"), \(g.frame) / \(wrap.bounds), r \(g.layer?.cornerRadius ?? -1))")
        guard let f = sbGlassFilter(g.layer!) else { expect(false, "[\(tag)] glassBackground filter present"); return }
        func n(_ k: String) -> Double { (f.value(forKey: k) as? NSNumber)?.doubleValue ?? -9 }
        let fill = (f.value(forKey: "inputFaceColorMatrixFillColor")).map { NSColor(cgColor: $0 as! CGColor)?.alphaComponent ?? -9 } ?? -9
        let face = (n("inputFaceColorMatrixBlack"), n("inputFaceColorMatrixWhite"), n("inputFaceColorMatrixSaturation"), Double(fill))
        let want = dark ? (0.1, 0.5, 0.6, 0.0) : (0.4, 1.03, 1.2, 0.2)
        let same = abs(face.0 - want.0) < 1e-3 && abs(face.1 - want.1) < 1e-3 && abs(face.2 - want.2) < 1e-3 && abs(face.3 - want.3) < 1e-3
        if glassOn {
            expect(same, "[\(tag)] 27 SidebarRecipe face \(want) (got \(face))")
            let bleed = (n("inputBleedColorMatrixBlack"), n("inputBleedColorMatrixWhite"), n("inputBleedColorMatrixSaturation"))
            let wb = dark ? (0.1, 0.5, 1.5) : (0.75, 0.9, 1.5)
            expect(abs(bleed.0 - wb.0) < 1e-3 && abs(bleed.1 - wb.1) < 1e-3 && abs(bleed.2 - wb.2) < 1e-3, "[\(tag)] edge bleed ycc \(wb) (got \(bleed))")
            expect(n("inputRefractionOpacity") == 0 && n("inputShadowOpacity") == 0, "[\(tag)] Planar: outer refraction 0, shadow 0 (got \(n("inputRefractionOpacity")), \(n("inputShadowOpacity")))")
        } else {
            expect(!same, "[\(tag)] GGApp.sidebarGlass off: 26.6 face kept (got \(face))")
        }
    }
    /// Most saturated pixel in the icon (or text) of row r (window capture, y = 0 at the top).
    func iconColor(_ img: CGImage, _ r: Int, text: Bool = false) -> NSColor? {
        guard let iv: NSView = text ? cell(r)?.textField : cell(r)?.imageView else { return nil }
        let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(rep.pixelsWide) / pa.frame.width
        let rc = iv.convert(iv.bounds, to: nil)
        var best: NSColor?, bs: CGFloat = -1
        for y in Int(rc.minY * s)..<Int(rc.maxY * s) { for x in Int(rc.minX * s)..<Int(rc.maxX * s) {
            guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
            let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
            if sat > bs { bs = sat; best = c }
        } }
        return best
    }
    var phases: [(String, NSAppearance.Name, Bool)] = [("light key", .aqua, true), ("dark key", .darkAqua, true), ("light inactive", .aqua, false), ("dark inactive", .darkAqua, false)]
    func phase() {
        guard !phases.isEmpty else { selectionCase(); return }
        let (name, ap, key) = phases.removeFirst(), dark = ap == .darkAqua
        NSApp.appearance = NSAppearance(named: ap)
        func step(_ w: NSWindow, _ tag: String, _ then: @escaping () -> Void) {
            if key { w.makeKeyAndOrderFront(nil) } else { other.orderFront(nil); other.makeKey() }
            after(1.0) { (key ? { f in whenKey(w, f) } : { f in f() })({
                let realKey = w.isKeyWindow
                print("[\(tag) \(name)] real key \(realKey)")
                checkGlass("\(tag) \(name)", w, dark: dark)
                let img = snap(w, "\(tag)-\(name.replacingOccurrences(of: " ", with: "-"))")
                if w === pa {
                    // Selected row text semibold (27: -[NSTableCellView _updateFont] switches to weight 0.3), other rows regular.
                    let w1 = sbWeight(cell(1)?.textField?.font), w0 = sbWeight(cell(0)?.textField?.font)
                    expect(w1 > 0.25 && w0 < 0.1, "[\(tag) \(name)] selected row text semibold, other rows regular (got \(w1), \(w0))")
                    // Unselected row icons: accent color when key, labelColor (no color) when inactive.
                    var accent = NSColor.black
                    w.effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)! }
                    let accentSat = max(accent.redComponent, accent.greenComponent, accent.blueComponent) - min(accent.redComponent, accent.greenComponent, accent.blueComponent)
                    if let img = img, let c = iconColor(img, 0) {
                        let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
                        // Vibrant glyphs blend with the glass background, so their lightness differs from the accent: compare hue, not RGB.
                        let dh = min(abs(c.hueComponent - accent.hueComponent), 1 - abs(c.hueComponent - accent.hueComponent))
                        if accentSat < 0.2 { print("skipping icon color check: accent color has no hue (\(accent))") }
                        else if realKey { expect(sat > 0.4 && dh < 0.06, "[\(tag) \(name)] regular row icon in accent color (got \(c), accent \(accent), hue diff \(dh), saturation \(sat))") }
                        else { expect(sat < 0.15, "[\(tag) \(name)] regular row icon colorless when inactive (saturation \(sat), \(c))") }
                    } else { expect(false, "[\(tag) \(name)] icon color readable") }
                    // Text (contentType 0): 27 always labelColor; 26.6 tints selected row text with the accent in inactive windows.
                    if !realKey, accentSat >= 0.2, let img = img, let c = iconColor(img, 1, text: true) {
                        let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
                        expect(sat < 0.15, "[\(tag) \(name)] selected row text not accent colored when inactive (saturation \(sat), \(c))")
                    }
                    // Emoji (27 _updateSourceListAttributesInRowView: 0x18a4f6914): text with emoji dims to 0.5 in a non-key window.
                    let oe = cell(5)?.textField?.layer?.opacity ?? -1, on = cell(0)?.textField?.layer?.opacity ?? -1
                    expect(oe == (realKey ? 1 : 0.5) && on == 1, "[\(tag) \(name)] emoji text opacity \(realKey ? 1 : 0.5), regular text 1 (got \(oe), \(on))")
                }
                if w === ps, let img = img {
                    // SwiftUI icons (27 SidebarRow_Mac.calistogaIconStyle 0x19a670c58): unselected rows in accent color when the
                    // window is active, secondary (no color) when inactive.
                    var accent = NSColor.black
                    w.effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)! }
                    let accentSat = max(accent.redComponent, accent.greenComponent, accent.blueComponent) - min(accent.redComponent, accent.greenComponent, accent.blueComponent)
                    if accentSat < 0.2 { print("skipping SwiftUI icon color check: accent color has no hue") }
                    else if let c = sbSwiftUIIcon(w, img, row: 1) {
                        let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
                        let dh = min(abs(c.hueComponent - accent.hueComponent), 1 - abs(c.hueComponent - accent.hueComponent))
                        if realKey { expect(sat > 0.4 && dh < 0.06, "[\(tag) \(name)] SwiftUI regular row icon in accent color (got \(c), hue diff \(dh), saturation \(sat))") }
                        else { expect(sat < 0.15, "[\(tag) \(name)] SwiftUI regular row icon colorless when inactive (saturation \(sat), \(c))") }
                    } else { expect(false, "[\(tag) \(name)] SwiftUI icon color readable") }
                }
                then()
            }) }
        }
        step(pa, "AppKit") { step(ps, "SwiftUI") { phase() } }
    }
    // Changing the selection: the old row returns to regular text, the new row is semibold.
    func selectionCase() {
        NSApp.appearance = NSAppearance(named: .aqua)
        pa.makeKeyAndOrderFront(nil)
        after(0.8) { whenKey(pa) {
            ov.selectRowIndexes([3], byExtendingSelection: false)
            after(0.5) {
                let w1 = sbWeight(cell(1)?.textField?.font), w3 = sbWeight(cell(3)?.textField?.font)
                expect(w1 < 0.1 && w3 > 0.25, "selection change: old row regular, new row semibold (got \(w1), \(w3))")
                print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
            }
        } }
    }
    after(1.0) { phase() }
}

// ---- corners: 27 window corner radius (Sources/WindowCorners.m) ----

/// Number of transparent pixels (alpha < 0.5) on the top row counted from the left edge: larger corners give longer runs.
func cornerRun(_ img: CGImage) -> Int {
    let rep = NSBitmapImageRep(cgImage: img)
    var n = 0
    while n < rep.pixelsWide / 2, let c = rep.colorAt(x: n, y: 0), c.alphaComponent < 0.5 { n += 1 }
    return n
}

func runCorners() {
    func win(_ mask: NSWindow.StyleMask, _ y: CGFloat, _ cls: NSWindow.Type = NSWindow.self) -> NSWindow {
        let w = cls.init(contentRect: NSRect(x: 150, y: y, width: 360, height: 160), styleMask: mask, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }
    let std: NSWindow.StyleMask = [.titled, .closable, .resizable]
    let plain = win(std, 120)
    func tb(_ s: NSWindow.ToolbarStyle, _ y: CGFloat) -> NSWindow {
        let w = win(std.union(.fullSizeContentView), y); w.toolbar = NSToolbar(identifier: "c\(s.rawValue)"); w.toolbar!.delegate = tbDelegate; w.toolbarStyle = s
        return w
    }
    let unified = tb(.unified, 320), compact = tb(.unifiedCompact, 520), expanded = tb(.expanded, 720)
    let util = win([.titled, .closable, .utilityWindow], 120, NSPanel.self); util.setFrameOrigin(NSPoint(x: 560, y: 120))
    let parent = win(std, 320); parent.setFrameOrigin(NSPoint(x: 560, y: 320))
    let sheet = win([.titled], 0)
    let alert = NSAlert(); alert.messageText = "Corners"; alert.layout()
    let borderless = win([.borderless], 0)
    for w in [plain, unified, compact, expanded, util, parent, alert.window] { w.orderFront(nil) }
    parent.beginSheet(sheet)
    func radius(_ w: NSWindow) -> Double { (w.contentView?.superview?.value(forKey: "_cornerRadius") as? NSNumber)?.doubleValue ?? -1 }
    after(1.5) {
        // 27 (-[NSThemeFrame _getCachedDefaultWindowCornerRadius] 0x18aca6624): titled or sheet 16, alert 26, otherwise 0.
        for (name, w, want) in [("no toolbar", plain, 16.0), ("toolbar unified", unified, 16), ("toolbar unifiedCompact", compact, 16),
                                ("toolbar expanded", expanded, 16), ("utility panel", util, 16), ("sheet", sheet, 16), ("alert", alert.window, 26),
                                ("borderless", borderless, 0)] as [(String, NSWindow, Double)] {
            expect(radius(w) == want, "radius \(name) = \(want) (got \(radius(w)))")
        }
        var phases: [(String, NSAppearance.Name, Bool)] = [("light key", .aqua, true), ("dark key", .darkAqua, true), ("light inactive", .aqua, false), ("dark inactive", .darkAqua, false)]
        let other = NSWindow(contentRect: NSRect(x: 1100, y: 120, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        func phase() {
            guard !phases.isEmpty else { print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1) }
            let (name, ap, key) = phases.removeFirst()
            NSApp.appearance = NSAppearance(named: ap)
            if key { unified.makeKeyAndOrderFront(nil) } else { other.makeKeyAndOrderFront(nil) }
            after(0.8) { (key ? { f in whenKey(unified, f) } : { f in f() })({
                // Real corner shape (WindowServer clips by the mask AppKit sends): a toolbar window must match a plain window.
                guard let a = snap(plain, "plain-\(name.replacingOccurrences(of: " ", with: "-"))"),
                      let b = snap(unified, "toolbar-\(name.replacingOccurrences(of: " ", with: "-"))") else { expect(false, "[\(name)] captured"); phase(); return }
                let ra = cornerRun(a), rb = cornerRun(b)
                expect(ra > 2 && abs(ra - rb) <= 1, "[\(name)] toolbar window corner = plain window corner (top row transparent \(rb) / \(ra) px)")
                // Shadow (kCGWindowImageOnlyShadows): WindowServer builds it from the window shape, so the shadow corners must match too.
                // Compared only when both are non-key (a key window has a larger active shadow).
                guard !key else { phase(); return }
                typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                let fn = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Fn.self)
                if let sa = fn(.null, 8, UInt32(plain.windowNumber), 4)?.takeRetainedValue(), let sb = fn(.null, 8, UInt32(unified.windowNumber), 4)?.takeRetainedValue() {
                    // Shadow alpha along the diagonal from the top-left corner of the shadow image to 60 px (no size normalization needed: both windows are the same size).
                    func diag(_ i: CGImage) -> [Int] { let r = NSBitmapImageRep(cgImage: i); return (0..<60).map { Int((r.colorAt(x: $0, y: $0)?.alphaComponent ?? 0) * 255) } }
                    let da = diag(sa), db = diag(sb), dmax = zip(da, db).map { abs($0 - $1) }.max() ?? 99
                    expect(sa.width == sb.width && dmax <= 8, "[\(name)] toolbar window corner shadow = plain window (max alpha diff \(dmax)/255)")
                }
                phase()
            }) }
        }
        phase()
    }
}

// 27 interactive menu glass (Sources/MenuGlass.swift). The menu loop closes itself on a fake mouseDown (the real pointer is
// outside the menu), so held presses go through gg_menu_glass_event (the same handling path as the hook), while the hook
// itself is checked with a real mouseDown posted to the queue at the end of each phase (menu closes, press count grows).
// GG_EXPECT_OFF=1: GGApp.menuGlass off.
final class MenuTarget: NSObject { @objc func act(_ s: Any?) { print("ACTION menu \((s as? NSMenuItem)?.title ?? "")") } }
let menuTarget = MenuTarget()
func runMenu() {
    let off = ProcessInfo.processInfo.environment["GG_EXPECT_OFF"] != nil
    typealias Ev = @convention(c) (NSEvent) -> Void
    let inject = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_menu_glass_event").map { unsafeBitCast($0, to: Ev.self) }
    func dbg() -> [String: Double] {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_menu_glass_debug").map({ unsafeBitCast($0, to: DebugFn.self) }),
              let d = try? JSONSerialization.jsonObject(with: Data(String(cString: f()).utf8)) as? [String: Double] else { return [:] }
        return d
    }
    func ev(_ t: NSEvent.EventType, _ mw: NSWindow, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: mw.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func at(_ t: Double, _ f: @escaping () -> Void) { RunLoop.main.add(Timer(timeInterval: t, repeats: false) { _ in f() }, forMode: .common) }
    let menu = NSMenu()
    for s in ["One", "Two", "Three", "Four", "Five", "Six"] { menu.addItem(withTitle: s, action: #selector(MenuTarget.act(_:)), keyEquivalent: "").target = menuTarget }
    w.contentView = NSView()
    w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    var phases: [NSAppearance.Name] = [.aqua, .darkAqua]
    var run = 0, tries = 0
    func phase() {
        guard !phases.isEmpty else { print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1) }
        let ap = phases[0], tag = ap == .aqua ? "light" : "dark"
        run += 1; let me = run
        var finished = false, closing = false
        func finish() { finished = true; phases.removeFirst(); tries = 0; menu.cancelTracking(); after(0.3) { phase() } }
        NSApp.appearance = NSAppearance(named: ap)
        at(0.5) {
            guard run == me, let mw = NSApp.windows.first(where: { $0 !== w && $0.isVisible && NSStringFromClass(type(of: $0)) == "NSPopupMenuWindow" }),
                  let glass = mw.contentView?.superview?.subviews.first(where: { $0 is NSGlassEffectView }) else {
                if run == me { expect(false, "\(tag): menu window with glass present"); finish() }; return
            }
            func alive() -> Bool { run == me && mw.isVisible }   // menu closed by itself midway: drop it, the phase reruns
            let b = glass.bounds, p = NSPoint(x: b.midX, y: b.maxY - 40)   // middle, near the second row
            let rest = snap(mw, "rest-\(tag)")
            inject?(ev(.leftMouseDown, mw, glass.convert(p, to: nil)))
            at(0.3) {
                guard alive() else { return }
                let d = dbg(), v = glass.subviews.last
                if off {
                    expect(v.map { NSStringFromClass(type(of: $0)) }?.contains("GGMenuGlowView") != true && (d["presses"] ?? 0) == 0,
                           "\(tag): GGApp.menuGlass off: no glow (presses \(d["presses"] ?? -1))")
                } else {
                    expect(v.map { NSStringFromClass(type(of: $0)) }?.contains("GGMenuGlowView") == true, "\(tag): glow view on top inside the menu glass (below the content)")
                    expect(d["active"] == 1 && abs((d["little"] ?? 0) - 0.05) < 0.003 && d["big"] == 0,
                           "\(tag): held 0.3 s: LittleGlow 0.05, BigGlow 0 like the 27 menu pointer set (got \(d))")
                    if let r = rest, let h = snap(mw, "hold-\(tag)") {
                        let box = NSRect(x: 4, y: 4, width: mw.frame.width - 8, height: mw.frame.height - 8)
                        let a = lumaIn(r, box, mw), c = lumaIn(h, box, mw)
                        expect(c > a + 0.002, "\(tag): menu brightens while held (luma \(a) -> \(c))")
                    }
                }
                inject?(ev(.leftMouseDragged, mw, glass.convert(NSPoint(x: p.x, y: p.y - 40), to: nil)))
                at(1.0) {
                    guard alive() else { return }
                    let d = dbg()
                    if !off { expect(abs((d["little"] ?? 0) - 0.025) < 0.002, "\(tag): dragged past 25 pt: LittleGlow 0.025 (got \(d["little"] ?? -1))") }
                    inject?(ev(.leftMouseDragged, mw, glass.convert(NSPoint(x: b.maxX + 30, y: p.y), to: nil)))
                    let exited = dbg()["active"] ?? -1
                    inject?(ev(.leftMouseDragged, mw, glass.convert(p, to: nil)))
                    let entered = dbg()["active"] ?? -1
                    if !off { expect(exited == 0 && entered == 1, "\(tag): dragging out of the menu turns off, re-entering while held turns on (\(exited), \(entered))") }
                    inject?(ev(.leftMouseUp, mw, glass.convert(p, to: nil)))
                    at(1.5) {
                        guard alive() else { return }
                        let d = dbg(), n = d["presses"] ?? 0
                        if !off { expect(d["active"] == 0 && d["little"] == 0, "\(tag): released 1.5 s fully off (got \(d))") }
                        // Real hook: mouseDown into the queue, NSMenuTrackingSession handleEvent: receives it and closes the menu.
                        closing = true
                        NSApp.postEvent(ev(.leftMouseDown, mw, glass.convert(p, to: nil)), atStart: false)
                        at(0.3) {
                            let m = dbg()["presses"] ?? 0
                            expect(off ? m == 0 : m == n + 1, off ? "\(tag): key off: not hooked (\(n) -> \(m))" : "\(tag): handleEvent: hook receives mouseDown in the menu (\(n) -> \(m))")
                            finish()
                        }
                    }
                }
            }
        }
        DispatchQueue.main.async {
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 60, y: 260), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSMenu.popUpContextMenu(menu, with: e, for: w.contentView!)
            guard run == me, !finished, !closing else { return }
            tries += 1
            print("menu \(tag) closed early (attempt \(tries)), rerunning the phase")
            if tries >= 3 { expect(false, "\(tag): menu closed early 3 times"); phases.removeFirst(); tries = 0 }
            after(0.3) { phase() }
        }
    }
    after(0.5) { phase() }
}

// ---- settings: 27 Liquid Glass slider of the Appearance pane (Sources/SettingsSlider.*) ----
// GGTestGlassRow plays Appearance.GlassStyleRow: its View witness table is patched as ggapp patches the real pane, then the
// row is checked to show the 27 slider (AX element "Liquid Glass Tint Amount", text "Liquid Glass", old content gone) and
// the write path: drag -> preview (writes NSGlassTintAmount, no commit), release -> commit.

struct GGTestGlassRow: View {
    var body: some View { Text("row 26.6") }
}

func axLabels(_ e: Any, _ depth: Int = 0, _ out: inout [String]) {
    guard depth < 40, let o = e as? NSObject else { return }
    if o.responds(to: #selector(NSAccessibilityElement.accessibilityLabel)), let l = o.value(forKey: "accessibilityLabel") as? String, !l.isEmpty { out.append(l) }
    if o.responds(to: #selector(NSAccessibilityElement.accessibilityValue)), let v = o.value(forKey: "accessibilityValue") as? String, !v.isEmpty { out.append(v) }
    for c in (o.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { axLabels(c, depth + 1, &out) }
}

func runSettings() {
    let prefs = "\(outDir)/settings-prefs.plist"
    try? FileManager.default.removeItem(atPath: prefs)
    NSDictionary(dictionary: ["NSGlassTintAmount": 0.5]).write(toFile: prefs, atomically: true)
    setenv("GG_PREFS_WRITE", prefs, 1); setenv("GG_TINT_NOPOST", "1", 1)
    setenv("GG_OAKRIDGE", "1", 1)   // preview: act as if AKURLBag returned enableOakRidge = true, without asking the server
    typealias PatchFn = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    let module = String(reflecting: GGTestGlassRow.self).components(separatedBy: ".").first!
    let patched = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_settings_patch_row").map { unsafeBitCast($0, to: PatchFn.self)("GGTestGlassRow", module) } ?? -1
    expect(patched == 1, "GGTestGlassRow View witness table patched (got \(patched))")
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 620, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
    // Extra rows below so the parent Form scrolls like the real Appearance pane (nested scrolling).
    w.contentView = NSHostingView(rootView: Form {
        GGTestGlassRow()
        ForEach(0..<12) { Text("row \($0)") }
    }.formStyle(.grouped))
    w.orderFront(nil)
    // 27 preview (Sources/SettingsPreview.swift): state read through gg_settings_preview_state. The demo is timed from when
    // .task runs (after the Form is built, about 0.3 s): down 52 at +1.3 s, back to 0 at +2.2 s; measured at 2.0 s and 3.0 s.
    typealias StateFn = @convention(c) () -> UnsafePointer<CChar>
    let stateFn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_settings_preview_state").map { unsafeBitCast($0, to: StateFn.self) }
    func pstate() -> [String: Any] {
        stateFn.flatMap { try? JSONSerialization.jsonObject(with: Data(String(cString: $0()).utf8)) as? [String: Any] } ?? [:]
    }
    func num(_ s: [String: Any], _ k: String) -> Double { (s[k] as? NSNumber)?.doubleValue ?? -999 }
    var s16: [String: Any] = [:], s28: [String: Any] = [:]
    after(2.0) { s16 = pstate() }
    after(3.0) { s28 = pstate() }
    func check(_ dark: Bool, _ then: @escaping () -> Void) {
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        after(1.2) {
            var classes: [String] = []
            func walk(_ v: NSView) { classes.append(NSStringFromClass(type(of: v))); v.subviews.forEach(walk) }
            walk(w.contentView!)
            var labels: [String] = []; axLabels(w.contentView!, 0, &labels)
            let tag = dark ? "dark" : "light"
            let slider = classes.first { $0.contains("Slider") }
            expect(slider != nil && !labels.contains("row 26.6"),
                   "[\(tag)] row shows the 27 slider instead of the 26.6 content (slider \(slider ?? "-"), AX \(labels.prefix(8)))")
            // 27 (0x2612db01c): slider row horizontal padding = style == .setup ? 12 : 0, i.e. 0 for .settings: the slider row
            // is exactly the 268 column (2x screenshot: icons 1.5..16.5 and 251.5..266.5 pt, track 23..244 pt, width 221).
            // The "Slider" view is the track.
            var sliderWidths: [CGFloat] = []
            func sw(_ v: NSView) { if NSStringFromClass(type(of: v)).contains("Slider") { sliderWidths.append(v.frame.width) }; v.subviews.forEach(sw) }
            sw(w.contentView!)
            expect(sliderWidths.contains { abs($0 - 221) < 3 }, "[\(tag)] slider track ~221 wide like 27 (no horizontal padding) (got \(sliderWidths.map { Int($0) }))")
            _ = snap(w, tag)
            then()
        }
    }
    typealias DragFn = @convention(c) (Double, Bool) -> Int32
    typealias ValFn = @convention(c) () -> Double
    let drag = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_settings_test_drag").map { unsafeBitCast($0, to: DragFn.self) }
    let val = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_settings_test_value").map { unsafeBitCast($0, to: ValFn.self) }
    func tint() -> Double { (NSDictionary(contentsOfFile: prefs)?["NSGlassTintAmount"] as? NSNumber)?.doubleValue ?? -1 }
    check(false) { check(true) {
        typealias GetFn = @convention(c) () -> Float
        let sys = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GGGlassSystemLegibility").map { Double(unsafeBitCast($0, to: GetFn.self)()) } ?? -9
        expect(abs((val?() ?? -1) - sys) < 1e-6, "initial value = system NSGlassTintAmount \(sys) (got \(val?() ?? -1))")
        let c1 = drag?(0.2, false) ?? -1
        expect(c1 == 100 && abs(tint() - 0.2) < 1e-6, "drag to 0.2: 1 preview, writes 0.2, no commit (got \(c1), \(tint()))")
        let c2 = drag?(0.8, true) ?? -1
        expect(c2 == 201 && abs(tint() - 0.8) < 1e-6, "drag to 0.8 and release: 2 previews, 1 commit, writes 0.8 (got \(c2), \(tint()))")
        after(1.0) { previewChecks() }
    } }
    func previewChecks() {
        let s = pstate()
        // Resources/SettingsPreview is extracted from macOS 27 and not shipped in the repository: skip when absent.
        if (s["resources"] as? String ?? "").isEmpty { print("SKIP preview resources: ggapp/Resources/SettingsPreview not present") }
        else { expect(num(s, "images") == 5 && num(s, "locs") >= 40 && (s["title"] as? String) == "Welcome to Apple Park",
               "preview has all 5 images (Apple Park x4, Clarus), 27 string table \(num(s, "locs")) languages, title '\(s["title"] ?? "")' (\(s["resources"] ?? ""))") }
        expect(num(s16, "photoOpacity") == 1 && num(s16, "demoScrollOffset") == -52 && num(s16, "scrollDemoFinished") == 0,
               "2.0 s: images shown, demo scrolled down 52 pt (offset \(num(s16, "demoScrollOffset")), finished \(num(s16, "scrollDemoFinished")))")
        expect(num(s28, "demoScrollOffset") == 0 && num(s28, "scrollDemoFinished") == 1,
               "3.0 s: demo scrolled back to 0 and finished (offset \(num(s28, "demoScrollOffset")), finished \(num(s28, "scrollDemoFinished")))")
        expect(num(s, "orEnabled") == 1 && num(s, "orCharCount") == 0, "Oak Ridge enabled, no letter shown yet")
        scrollChecks { moofChecks() }
    }
    /// Scrolling in the preview is not forwarded to the parent Form (27: `_scrollInputForwardingBehavior(.never, axes: .vertical)`,
    /// making `wantsForwardedScrollEvents(for: .vertical)` of the preview scroll area return false). The parent Form stays true.
    /// Real pane: once the preview hits the bottom, its `scrollWheel:` asks the ancestor Form `wantsForwardedScrollEventsForAxis:`,
    /// the Form returns true so that event moves to the Form and the Form scrolls. This case sends a trackpad gesture straight
    /// into the preview scroll area at the bottom and checks the Form does not move (the preview keeps the gesture like 27 `.never`).
    func scrollChecks(_ next: @escaping () -> Void) {
        var views: [NSView] = []
        func walk(_ v: NSView) { if v is NSScrollView { views.append(v) }; v.subviews.forEach(walk) }
        walk(w.contentView!)
        let all = views.compactMap { $0 as? NSScrollView }
        guard let inner = all.first(where: { abs($0.frame.width - 268) < 1 }), let outer = all.first(where: { $0.frame.width > 300 }),
              let doc = inner.documentView else { expect(false, "found the preview scroll area and the Form"); next(); return }
        let bottom = doc.frame.height - inner.contentView.bounds.height
        inner.contentView.scroll(to: NSPoint(x: 0, y: bottom)); inner.reflectScrolledClipView(inner.contentView)
        let y0 = outer.contentView.bounds.origin.y
        func ev(_ phase: Int64, _ d: Int32) -> NSEvent? {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: d, wheel2: 0, wheel3: 0) else { return nil }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(d))
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(d))
            e.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)   // kCGScrollWheelEventScrollPhase
            return NSEvent(cgEvent: e)
        }
        // Count the events the Form receives: a runtime subclass for just that Form object (test instrumentation, like KVO).
        var forwarded = 0
        let base: AnyClass = object_getClass(outer)!
        let sub: AnyClass = objc_getClass("GGTestFormScrollView") as? AnyClass ?? {
            let c: AnyClass = objc_allocateClassPair(base, "GGTestFormScrollView", 0)!
            let ssel = #selector(NSResponder.scrollWheel(with:))
            typealias SFn = @convention(c) (NSObject, Selector, NSEvent) -> Void
            let sup = unsafeBitCast(class_getMethodImplementation(base, ssel), to: SFn.self)
            let blk: @convention(block) (NSObject, NSEvent) -> Void = { v, e in
                NotificationCenter.default.post(name: .init("GGTestFormScroll"), object: nil); sup(v, ssel, e)
            }
            class_addMethod(c, ssel, imp_implementationWithBlock(blk), "v@:@")
            objc_registerClassPair(c)
            return c
        }()
        let obs = NotificationCenter.default.addObserver(forName: .init("GGTestFormScroll"), object: nil, queue: nil) { _ in forwarded += 1 }
        object_setClass(outer, sub)
        // began, 6 changed (scrolling down 40 pt each), ended, sent straight into the preview scroll area at the bottom.
        for (p, d) in [(Int64(1), Int32(0))] + Array(repeating: (Int64(2), Int32(-40)), count: 6) + [(Int64(4), Int32(0))] {
            if let e = ev(p, d) { inner.scrollWheel(with: e) }
        }
        object_setClass(outer, base)
        NotificationCenter.default.removeObserver(obs)
        after(0.5) {
            let y1 = outer.contentView.bounds.origin.y
            expect(forwarded == 0 && abs(y1 - y0) < 1,
                   "scrolling on with the preview at the bottom: no event forwarded to the parent Form (got \(forwarded)), Form does not scroll (y \(Int(y0)) -> \(Int(y1)))")
            next()
        }
    }
    func moofChecks() {
        typealias OverFn = @convention(c) (Double) -> Void
        let over = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_settings_preview_overscroll").map { unsafeBitCast($0, to: OverFn.self) }
        /// Waits on a condition: checks every 20 ms, up to `timeout` seconds, then continues (met or timed out; the check reports failures).
        func waitFor(_ timeout: Double, _ cond: @escaping () -> Bool, _ then: @escaping () -> Void) {
            let end = Date().addingTimeInterval(timeout)
            func poll() { if cond() || Date() > end { then() } else { after(0.02) { poll() } } }
            poll()
        }
        over?(10)
        // Increasing overscroll: first letter threshold 14 pt, each following letter 2.5 pt more, at least 0.035 s apart. Like
        // 27, each scroll geometry change reveals at most one letter and a change arriving while the previous letter is still
        // pending is ignored, so the test sends the next step only after the previous letter appeared (fixed timers would
        // bunch the steps into one run loop pass).
        let steps: [Double] = [15, 18, 21, 24, 27, 30]
        func step(_ i: Int) {
            guard i < steps.count else { return checkLocked() }
            over?(steps[i])
            waitFor(2) { num(pstate(), "orCharCount") >= Double(min(i + 1, 5)) } _: { step(i + 1) }
        }
        func checkLocked() {
            let a = pstate()
            expect(num(a, "orCharCount") == 5 && num(a, "orLocked") == 1 && num(a, "haptics") == 5,
                   "overscroll to 30 pt: full 'Moof!' shown (\(num(a, "orCharCount")) letters), locked, 5 haptics (\(num(a, "haptics")))")
            over?(-20)
            waitFor(3) { num(pstate(), "orOpacity") > 0.99 } _: {
                let b = pstate()
                expect(num(b, "orOpacity") > 0.99 && num(b, "orCharCount") == 5, "Clarus shown (opacity \(num(b, "orOpacity"))), the lock keeps 'Moof!' when back above the bottom")
                // Release: the preview scrolls (spring 0.7/0.85) to the bottom, the 268 x 180 Clarus image fills the frame like 27 screenshots.
                typealias RelFn = @convention(c) () -> Void
                dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gg_settings_preview_release").map { unsafeBitCast($0, to: RelFn.self)() }
                waitFor(3) { abs(num(pstate(), "bottom")) < 1 } _: {
                    expect(abs(num(pstate(), "bottom")) < 1, "release after locking: scrolls to the bottom, Clarus fills the frame (distance to bottom \(num(pstate(), "bottom")))")
                    w.appearance = NSAppearance(named: .aqua)
                    after(0.5) {
                        _ = snap(w, "moof-light")
                        layoutChecks()
                        w.appearance = NSAppearance(named: .darkAqua)
                        after(0.5) {
                            _ = snap(w, "moof-dark")
                            clipCheck { print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1) }
                        }
                    }
                }
            }
        }
        /// The preview NSScrollView (268 x 180) in the window.
        func previewScroll() -> NSScrollView? {
            func find(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView, abs(s.frame.width - 268) < 1, abs(s.frame.height - 180) < 1 { return s }
                for c in v.subviews { if let s = find(c) { return s } }
                return nil
            }
            return find(w.contentView!)
        }
        /// 27 toolbar (from a public 27 demo video; the search field typeref has a Spacer): three glass capsules spanning the
        /// preview, 8 pt margins (8 | 71 | 8 | 35 | 8 | ~130 | 8). Measures the CASDFElementLayer frames of the toolbar glass.
        func layoutChecks() {
            guard let sv = previewScroll(), let root = w.contentView?.superview?.layer else { expect(false, "preview not found"); return }
            // Preview frame in the window root layer coordinates (not flipped): preview top = maxY.
            let pr = sv.convert(sv.bounds, to: nil)
            var els: [CGRect] = []
            func walk(_ l: CALayer) {
                if NSStringFromClass(type(of: l)) == "CASDFElementLayer", let sl = l.superlayer {
                    let r = sl.convert(l.frame, to: root)
                    let rel = CGRect(x: r.minX - pr.minX, y: pr.maxY - r.maxY, width: r.width, height: r.height)
                    if rel.height > 30 && rel.height < 42 && rel.minY > -2 && rel.minY < 20 && rel.minX > -2 && rel.maxX < 270 { els.append(rel) }
                }
                for s in l.sublayers ?? [] { walk(s) }
            }
            walk(root)
            let minX = els.map(\.minX).min() ?? -1, maxX = els.map(\.maxX).max() ?? -1
            expect(els.count == 3 && abs(minX - 8) < 2 && abs(maxX - 260) < 2,
                   "toolbar: 3 capsules spanning the width, 8 pt margins (got \(els.count) capsules, x \(Int(minX))..\(Int(maxX)), \(els.map { Int($0.width) }))")
        }
        /// 27: Clarus `.aspectRatio(.fill).frame(268, 180).clipped()` (typeref IDView<…_ClipEffect<Rectangle>…>). Scrolling back
        /// up 100 pt after locking: the 32 pt padding band above the image must be background, not covered by the portrait overflow.
        func clipCheck(_ then: @escaping () -> Void) {
            w.appearance = NSAppearance(named: .aqua)
            guard let sv = previewScroll(), let doc = sv.documentView else { expect(false, "preview not found"); then(); return }
            let clip = sv.contentView
            let start = clip.bounds.origin.y
            // After locking, the preview locks scrolling until the scrollTo animation ends: repeat the scroll until the position changes (up to 3 s).
            func tryScroll(_ n: Int) {
                var o = clip.bounds.origin
                o.y = start + (doc.isFlipped ? -100 : 100)
                clip.scroll(to: o); sv.reflectScrolledClipView(clip)
                after(0.2) { if abs(clip.bounds.origin.y - start) < 50 && n < 15 { tryScroll(n + 1) } else { measure() } }
            }
            tryScroll(0)
            func measure() { after(0.4) {
                guard let img = snap(w, "moof-scroll-up") else { then(); return }
                let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(img.width) / w.frame.width
                let r = sv.convert(sv.bounds, to: nil)
                // Image top from the actual scroll position (SwiftUI may adjust after the scroll command): the image is the last 180 pt of content.
                let off = doc.isFlipped ? clip.bounds.minY : doc.frame.height - clip.bounds.maxY
                let imageTop = doc.frame.height - 180 - off   // from the top of the visible frame
                let y = imageTop - 16                          // middle of the 32 pt padding band above the image
                func px(_ rep: NSBitmapImageRep) -> [Double] {
                    guard let c = rep.colorAt(x: Int(r.midX * s), y: Int((w.frame.height - (r.maxY - y)) * s))?.usingColorSpace(.sRGB) else { return [0, 0, 0] }
                    return [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
                }
                // 27 article background: dynamic NSColor (0x2612df4xx) sRGB light (0.912, 0.897, 0.876), dark (0.076, 0.07, 0.06);
                // measured from 27 video (229, 225, 220). The padding band above the image shows exactly this color when the image is clipped.
                func near(_ a: [Double], _ b: [Double]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.03 } }
                let light = px(rep), fmt = { (a: [Double]) in a.map { String(format: "%.3f", $0) }.joined(separator: ", ") }
                expect(y > 56 && y < 170 && near(light, [0.912, 0.897, 0.876]),
                       "scroll up after locking: Clarus does not overflow onto text, padding band is the 27 light article background (y \(Int(y)), color \(fmt(light)))")
                w.appearance = NSAppearance(named: .darkAqua)
                after(0.5) {
                    let dark = snap(w, "moof-scroll-up-dark").map { px(NSBitmapImageRep(cgImage: $0)) } ?? [1, 1, 1]
                    expect(near(dark, [0.076, 0.07, 0.06]), "27 dark article background (color \(fmt(dark)))")
                    then()
                }
            } }
        }
        step(0)
    }
}

/// Content inside `.glassEffect` must be upright: flex attaches a GGFlexView to every glass entry with content, and the SwiftUI
/// content layers sit under its layer; if that view is not flipped, AppKit sets geometryFlipped and the content flips vertically.
struct GlassFlipProbe: View {
    var body: some View {
        VStack(spacing: 2) {
            Color.red.frame(width: 40, height: 12)
            Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
            Text("TOP").font(.system(size: 14, weight: .bold))
            Color.blue.frame(width: 40, height: 12)
        }.frame(width: 90, height: 90)
    }
}

func runGlassFlip() {
    let cols = ["no glass", "inside .glassEffect(.regular)", "inside .glassEffect(.regular.interactive())", "glass as background"]
    let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 600, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: HStack(spacing: 0) {
        GlassFlipProbe().frame(width: 150, height: 150)
        GlassFlipProbe().glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)).frame(width: 150, height: 150)
        GlassFlipProbe().glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16)).frame(width: 150, height: 150)
        GlassFlipProbe().background { Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16)) }.frame(width: 150, height: 150)
    }.background(Color.green.opacity(0.4)))
    w.orderFront(nil)
    after(1.5) {
        var flex: [NSView] = []; allViews(w.contentView!, "GGApp.GGFlexView", &flex)
        expect(!flex.isEmpty, "flex attaches GGFlexView to glass entries with content (got \(flex.count))")
        guard let img = snap(w, "orientation") else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(img.width) / w.frame.width
        for (i, name) in cols.enumerated() {
            var ry = 0.0, rn = 0.0, by = 0.0, bn = 0.0
            for y in 0..<img.height { for x in Int(CGFloat(i) * 150 * s)..<Int(CGFloat(i + 1) * 150 * s) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8 && c.greenComponent < 0.5 && c.blueComponent < 0.5 { ry += Double(y); rn += 1 }
                if c.blueComponent > 0.8 && c.redComponent < 0.3 && c.greenComponent < 0.7 { by += Double(y); bn += 1 }
            } }
            // image row 0 = top edge: the red bar (top) must have a smaller y than the blue bar (bottom).
            expect(rn > 20 && bn > 20 && ry / rn < by / bn,
                   "[\(name)] red on top, blue at the bottom (red y \(rn > 0 ? Int(ry / rn) : -1), blue y \(bn > 0 ? Int(by / bn) : -1))")
        }
        print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1)
    }
}

// ---- searchfield: search field glass in a sidebar (Legibility/Recipe.m) ----
// Run: tests/app.sh searchfield GG_ABI_FAKE=2. 27: DesignLibrary.MacEngineeringSearchField uses glass when there is a pocket;
// the enclosing sidebar glass must not pull the child glass into the sidebar recipe (the search field is
// RegularEntryFieldRecipe: regular + DisableBlur, with a bright rim like 27).

struct SFSidebar: View {
    @State var q = ""
    var body: some View {
        NavigationSplitView {
            List { Label("Wi-Fi", systemImage: "wifi"); Label("Bluetooth", systemImage: "wave.3.right") }
                .listStyle(.sidebar).searchable(text: $q, placement: .sidebar)
        } detail: { Color.white }
    }
}

/// Like the App Store 26.6 private SearchField class: only overrides searchTextBounds. AppKit 26.6/27 treats that as a drawing
/// override (Aquaduck provider) and draws the field with a context, without glass; App Store 27 drops this subclass.
/// Sidebar.m does what App Store 27 does.
final class GGAppStoreLikeSearchField: NSSearchField {
    override var searchTextBounds: NSRect { super.searchTextBounds }
}

func runSearchField() {
    // App Store 27 (tests/app.sh searchfield GG_SEARCH27=1 simulates App Store): a subclass that only overrides
    // searchTextBounds still has the glass hosting view like a plain NSSearchField.
    do {
        let plain = NSSearchField(frame: NSRect(x: 10, y: 10, width: 180, height: 28))
        let f = GGAppStoreLikeSearchField(frame: NSRect(x: 210, y: 10, width: 180, height: 28))
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 48), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView!.addSubview(plain); w.contentView!.addSubview(f); w.orderFront(nil)
        func hosting(_ v: NSView) -> Bool { v.subviews.contains { NSStringFromClass(type(of: $0)).contains("HostingView") } }
        let like27 = ProcessInfo.processInfo.environment["GG_SEARCH27"] != nil
        let end = Date().addingTimeInterval(3)
        func poll() {
            guard !(hosting(plain) && (hosting(f) || !like27)) && Date() < end else {
                if like27 {
                    expect(hosting(plain) && hosting(f),
                           "search field subclass overriding searchTextBounds (like App Store 26.6) has the glass hosting view like App Store 27 (plain \(hosting(plain)), subclass \(hosting(f)))")
                } else {   // outside App Store: keep AppKit behavior (26.6 and 27 both draw with a context when a subclass overrides)
                    expect(hosting(plain) && !hosting(f), "non-App Store app: subclass overriding searchTextBounds keeps context drawing like AppKit 27 (plain \(hosting(plain)), subclass \(hosting(f)))")
                }
                w.orderOut(nil); return
            }
            after(0.1) { poll() }
        }
        poll()
    }
    guard let h = dlopen(ProcessInfo.processInfo.environment["GG_LEGIBILITY"], RTLD_NOW) else { print("FAIL cannot load GGLegibility"); exit(1) }
    typealias V = @convention(c) () -> Void
    typealias D = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Bool>,
                                  UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Float>) -> Bool
    guard let install = dlsym(h, "gg_legibility_install").map({ unsafeBitCast($0, to: V.self) }),
          let decode = dlsym(h, "gg_recipe_decode").map({ unsafeBitCast($0, to: D.self) }) else { print("FAIL missing symbol"); exit(1) }
    install()
    func recipe(_ l: CALayer) -> (ok: Bool, recipe: Int32, dark: Bool, inactive: Bool) {
        let code = (l.value(forKeyPath: "filters.glassBackground.inputClampPreserveHue") as? NSNumber)?.int32Value ?? 0
        var r: Int32 = -1, i = false, d = false, f: Int32 = 0, a: Float = 0
        return (decode(code, &r, &i, &d, &f, &a), r, d, i)
    }
    func num(_ l: CALayer, _ k: String) -> Double { (l.value(forKeyPath: "filters.glassBackground.\(k)") as? NSNumber)?.doubleValue ?? .nan }
    func glass(_ v: NSView) -> [CALayer] {
        var out: [CALayer] = []
        func walk(_ l: CALayer) {
            if (l.filters ?? []).contains(where: { (($0 as AnyObject).value(forKey: "type") as? String) == "glassBackground" }) { out.append(l) }
            for s in l.sublayers ?? [] { walk(s) }
        }
        if let l = v.layer { walk(l) }
        return out
    }
    func find<T: NSView>(_ v: NSView, _ t: T.Type) -> T? { if let x = v as? T { return x }; for s in v.subviews { if let x = find(s, t) { return x } }; return nil }
    func findGlass(_ v: NSView) -> NSGlassEffectView? { find(v, NSGlassEffectView.self) }
    func waitFor(_ timeout: Double, _ cond: @escaping () -> Bool, _ then: @escaping () -> Void) {
        let end = Date().addingTimeInterval(timeout)
        func poll() { if cond() || Date() > end { then() } else { after(0.1) { poll() } } }
        poll()
    }
    var schemes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    func next() {
        guard !schemes.isEmpty else { print(bad == 0 ? "TOTAL: all passed" : "TOTAL: some failed"); exit(bad == 0 ? 0 : 1) }
        let (name, ap) = schemes.removeFirst()
        let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 520, height: 300), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: ap)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SFSidebar())
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // The window must be key: otherwise the recipe is inactive (highlight off, flat field like 27 in an inactive window).
        after(1.0) { whenKey(w) { after(0.5) {
            w.makeFirstResponder(nil)
            let frame = w.contentView!.superview!
            guard let field = find(frame, NSSearchField.self), let side = findGlass(frame) else { expect(false, "[\(name)] search field or sidebar glass not found"); w.close(); next(); return }
            // Taking key may fail while the user is using the machine (macOS blocks focus stealing): then check the inactive
            // branch (27: RegularRecipe.Inactive turns highlight off, flat field) instead of key window pixels.
            // Same criterion as Recipe.m (_hasActiveAppearance), not isKeyWindow (the two sometimes disagree).
            let key = (w.value(forKey: "_hasActiveAppearance") as? Bool) ?? w.isKeyWindow
            if !key { print("warning: [\(name)] window not active, checking the inactive branch") }
            let fg = glass(field), dark = ap == .darkAqua
            expect(!fg.isEmpty && fg.allSatisfy { let r = recipe($0); return r.ok && r.recipe == 0 && r.dark == dark && r.inactive == !key },
                   "[\(name)] search field glass: regular recipe (not sidebar), appearance from the view, inactive = \(!key) (\(fg.map { recipe($0) }))")
            expect(!fg.isEmpty && fg.allSatisfy { l in num(l, "inputBlurRadius") == 0 && (0..<4).allSatisfy { num(l, "inputBlurOpacity\($0)") == 0 } },
                   "[\(name)] search field glass: RegularEntryFieldRecipe DisableBlur (blur opacity \(fg.map { l in (0..<4).map { num(l, "inputBlurOpacity\($0)") } }))")
            // The sidebar's own glass (layers owned by NSGlassEffectView, not nested child glass) stays the sidebar recipe.
            let own = glass(side).filter { l in !fg.contains { $0 === l } && !(field.layer.map { l.isDescendant(of: $0) } ?? false) }
            expect(own.contains { let r = recipe($0); return r.ok && r.recipe == 2 }, "[\(name)] sidebar glass keeps the sidebar recipe (\(own.map { recipe($0) }))")
            // Vertical profile through the field (27 Default light screenshot: inner rim 252, fill 234, sidebar 236): the inner
            // rim is brighter than the fill, the fill is close to the sidebar color. The buggy version (sidebar recipe or blur 0):
            // flat fill ~15 below the sidebar, dark rim. Dark: no 27 reference yet, only the bright rim is checked. Recapture
            // until WindowServer has drawn the recipe (up to 3 s).
            let r = field.convert(field.bounds, to: nil)
            func profile() -> (top: Double, mid: Double, side: Double)? {
                guard let img = snap(w, "search-field-\(name)") else { return nil }
                let rep = NSBitmapImageRep(cgImage: img), s = CGFloat(img.width) / w.frame.width
                func luma(_ y: CGFloat) -> Double {
                    guard let c = rep.colorAt(x: Int((r.minX + 0.75 * r.width) * s), y: Int((w.frame.height - y) * s))?.usingColorSpace(.sRGB) else { return .nan }
                    return Double(0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) * 255
                }
                return (luma(r.maxY - 1.5), luma(r.midY), luma(r.maxY + 6))
            }
            func settled(_ p: (top: Double, mid: Double, side: Double)?) -> Bool { p.map { $0.top > $0.mid + 4 } ?? false }
            waitFor(key ? 3 : 0, { settled(profile()) }) {
                let p = profile() ?? (.nan, .nan, .nan)
                if key {
                    expect(p.top > p.mid + 4, "[\(name)] search field has a bright inner rim (rim \(Int(p.top)), fill \(Int(p.mid)))")
                    if !dark { expect(abs(p.mid - p.side) < 10, "[\(name)] field fill close to the sidebar color (fill \(Int(p.mid)), sidebar \(Int(p.side)))") }
                }
                // No close: closing the last window deactivates the app, and the next window would not become key.
                w.orderBack(nil)
                after(0.3) { next() }
            }
        } } }
    }
    next()
}

extension CALayer {
    func isDescendant(of a: CALayer) -> Bool { var l: CALayer? = self; while let x = l { if x === a { return true }; l = x.superlayer }; return false }
}

switch mode {
case "searchfield": runSearchField()
case "glassflip": runGlassFlip()
case "settings": runSettings()
case "menu": runMenu()
case "corners": runCorners()
case "sidebar": runSidebar()
case "legibility": runLegibility()
case "recipes": runRecipes()
case "toolbar": runToolbar()
case "pocket": runPocket()
case "flex": runFlex()
case "controls": runControls()
case "lights": runLights()
default: print("unknown mode"); exit(2)
}
app.run()
