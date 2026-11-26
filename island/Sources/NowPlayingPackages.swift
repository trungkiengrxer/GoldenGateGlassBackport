// Animated transport glyphs: the system's own MediaCoreUI CAPackages (macOS 26.6 ships NowPlaying.PlayPauseStop.ca and
// NowPlaying.ForwardBackward.ca; loaded at runtime from /System, never copied), driven by CAStateController like 27.3
// NowPlayingUI.PackageView and patched to the 27.3 package values (docs/RE-27-NOWPLAYING.md section 5d).
import AppKit
import QuartzCore
import SwiftUI

final class PackageGlyph {
    enum File: String {
        case playPause = "NowPlaying.PlayPauseStop.ca", nextPrevious = "NowPlaying.ForwardBackward.ca"
    }

    static let directory = "/System/Library/PrivateFrameworks/MediaCoreUI.framework/Versions/A/Resources/"
    static func isAvailable(_ f: File) -> Bool { FileManager.default.fileExists(atPath: directory + f.rawValue) }

    let root: CALayer
    private let controller: NSObject

    init?(_ file: File) {
        guard let packageClass = NSClassFromString("CAPackage"), let controllerClass = NSClassFromString("CAStateController"),
              let load = class_getClassMethod(packageClass, NSSelectorFromString("packageWithContentsOfURL:type:options:error:"))
        else { return nil }
        typealias Load = @convention(c) (AnyClass, Selector, NSURL, NSString, NSDictionary?, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        var error: NSError?
        guard let package = unsafeBitCast(method_getImplementation(load), to: Load.self)(
                  packageClass, NSSelectorFromString("packageWithContentsOfURL:type:options:error:"),
                  NSURL(fileURLWithPath: Self.directory + file.rawValue), "com.apple.coreanimation-bundle", nil, &error),
              let root = package.value(forKey: "rootLayer") as? CALayer,
              let allocated = (controllerClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let controller = allocated.perform(NSSelectorFromString("initWithLayer:"), with: root)?.takeRetainedValue() as? NSObject
        else { return nil }
        self.root = root
        self.controller = controller
        root.isGeometryFlipped = true   // packages are authored y-down
        switch file {
        case .playPause: patchPlayPause()
        case .nextPrevious: layer(named: "origin")?.transform = CATransform3DMakeScale(0.333, 0.333, 1)   // 27.3 (26.6: 0.86)
        }
    }

    // MARK: State machine

    private var states: [NSObject] { root.value(forKey: "states") as? [NSObject] ?? [] }
    private var transitions: [NSObject] { root.value(forKey: "stateTransitions") as? [NSObject] ?? [] }
    private func elements(_ o: NSObject) -> [NSObject] { o.value(forKey: "elements") as? [NSObject] ?? [] }
    private func targetName(_ e: NSObject) -> String? { (e.value(forKey: "target") as? CALayer)?.name }

    var stateNames: [String] { states.compactMap { $0.value(forKey: "name") as? String } }
    var stateTargets: Set<String> { Set(states.flatMap { elements($0).compactMap(targetName) }) }

    func stateValue(_ state: String, _ target: String, _ keyPath: String) -> Double? {
        let s = states.first { $0.value(forKey: "name") as? String == state }
        let e = s.map(elements)?.first { targetName($0) == target && $0.value(forKey: "keyPath") as? String == keyPath }
        return (e?.value(forKey: "value") as? NSNumber)?.doubleValue
    }

    func setState(_ name: String, animated: Bool) {
        guard let state = root.perform(NSSelectorFromString("stateWithName:"), with: name)?.takeUnretainedValue() else { return }
        if animated {
            typealias Set = @convention(c) (AnyObject, Selector, AnyObject, CALayer, Float) -> Void
            let sel = NSSelectorFromString("setState:ofLayer:transitionSpeed:")
            unsafeBitCast(controller.method(for: sel), to: Set.self)(controller, sel, state, root, 1)
        } else {
            typealias Set = @convention(c) (AnyObject, Selector, AnyObject, CALayer) -> Void
            let sel = NSSelectorFromString("setState:ofLayer:")
            unsafeBitCast(controller.method(for: sel), to: Set.self)(controller, sel, state, root)
        }
    }

    /// 26.6's PlayPauseStop scales the 'origin' layer per state (0.9 / 1, root 0.9 on pause); 27.3's scales the root's
    /// sublayerTransform instead (0.97 'play', 0.93 'pause') with the same spring. Retarget, keep everything else.
    private func patchPlayPause() {
        let groupScale = ["play": 0.97, "pause": 0.93]
        for s in states {
            let name = s.value(forKey: "name") as? String ?? ""
            var kept: [NSObject] = [], rootSet: NSObject?
            for e in elements(s) {
                let isOrigin = targetName(e) == "origin", isRootScale = targetName(e) == root.name
                    && e.value(forKey: "keyPath") as? String == "sublayerTransform.scale.xy"
                if isRootScale { rootSet = e }
                if !isOrigin && !isRootScale { kept.append(e) }
                if isOrigin && rootSet == nil && groupScale[name] != nil { rootSet = e }
            }
            if let r = rootSet, let v = groupScale[name] {
                r.setValue(root, forKey: "target")
                r.setValue("sublayerTransform.scale.xy", forKey: "keyPath")
                r.setValue(NSNumber(value: v), forKey: "value")
                kept.append(r)
            }
            s.setValue(kept, forKey: "elements")
        }
        for t in transitions {
            var seen = false
            let kept = elements(t).filter { e in
                guard targetName(e) == "origin" || targetName(e) == root.name else { return true }
                e.setValue(root, forKey: "target")
                e.setValue("sublayerTransform.scale.xy", forKey: "key")
                defer { seen = true }
                return !seen
            }
            t.setValue(kept, forKey: "elements")
        }
    }

    // MARK: Layers

    func layer(named name: String, in l: CALayer? = nil) -> CALayer? {
        let l = l ?? root
        if l.name == name { return l }
        for s in l.sublayers ?? [] { if let f = layer(named: name, in: s) { return f } }
        return nil
    }

    func layerValue(_ name: String, _ keyPath: String) -> Double? {
        (layer(named: name)?.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue
    }

    var originScale: CGFloat { layer(named: "origin")?.transform.m11 ?? 0 }

    /// CAPackageViewLayer.foregroundColor: fills the package's "...-tint-shape" layers.
    func tint(_ color: CGColor, in l: CALayer? = nil) {
        let l = l ?? root
        if let s = l as? CAShapeLayer, s.name?.hasSuffix("tint-shape") == true { s.fillColor = color }
        for s in l.sublayers ?? [] { tint(color, in: s) }
    }
}

/// PackageView: the package root (84 x 84) centred in the glyph box, scaled by NowPlayingMetrics.packageScale(file) and
/// mirrored for previous (PackageAsset.isHorizontallyFlipped).
struct PackageGlyphView: NSViewRepresentable {
    let file: PackageGlyph.File
    let state: String
    let box: CGSize
    var flipped = false

    func makeNSView(context: Context) -> PackageHostView { PackageHostView(file) }

    func updateNSView(_ v: PackageHostView, context: Context) {
        v.apply(state: state, box: box, flipped: flipped)
    }
}

final class PackageHostView: NSView {
    private let glyph: PackageGlyph?
    private let file: PackageGlyph.File
    private var current: String?
    private var box = CGSize.zero, mirrored = false

    init(_ file: PackageGlyph.File) {
        self.file = file
        glyph = PackageGlyph(file)
        super.init(frame: .zero)
        wantsLayer = true
        guard let g = glyph else { return }
        // TransportControlDefaultStyle: CAPackageViewForegroundColorModifier(Color.primary), resolved for the black island.
        var color = NSColor.white.cgColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        g.tint(color)
        layer?.addSublayer(g.root)
    }

    required init?(coder: NSCoder) { nil }

    func apply(state: String, box: CGSize, flipped: Bool) {
        if state != current {
            glyph?.setState(state, animated: current != nil)
            current = state
        }
        self.box = box
        mirrored = flipped
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let root = glyph?.root else { return }
        let s = NowPlayingMetrics.packageScale(file)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        root.transform = CATransform3DMakeScale(mirrored ? -s : s, s, 1)
        CATransaction.commit()
    }
}
