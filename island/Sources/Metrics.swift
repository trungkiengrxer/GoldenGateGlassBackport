// macOS 27.3 (26C5047e) CenterHUD geometry, rebuilt from MenuBarAgent defaults and layout calculators.
// Sources: docs/RE-27-CENTERHUD.md (setting keys = MenuBarAgentSettings.centerHUD.*). AppKit points, origin bottom-left.
// [I] = inferred, [?] = placeholder until the corresponding 27.3 function is read.
import CoreGraphics
import Foundation

enum ExpandedType: Int { case standard, pill, shortPill, square, squareLarge, oval, tallRect }   // CenterHUDExpandedLayoutType
enum HorizontalEdge { case leading, trailing }   // CenterHUDHorizontalEdge (side of a minimal view)

/// Element shape preference byte read by sub_1001fe6fc = `preferredContainerShape: ComponentIntegratedContainerShape?`:
/// 0 capsule (pill or shortPill, never standard), 1 roundedRectangle (standard), 2 nil (automatic). RE-27-BEHAVIOR s21.2.
enum ShapePreference { case automatic, standard, defaultPill
    /// SystemBannerUI (slider, battery, Focus): CenterHUDBannerContainer sets preferredContainerShape(.capsule) on the
    /// expanded branch (0x2b1aae39c; GOT 0x2d8097fd0 -> HostedContainerShape.capsule case tag 0x29e23f508) [V].
    static let systemBanner = ShapePreference.defaultPill
    /// Live Activity (AirDrop): ElementRegistryClientSceneSettings has no shape field, so nil = automatic [V field, I].
    static let liveActivity = ShapePreference.automatic
}

struct IslandShape: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat

    /// Whether this shape's frame holds `other` (half a point of slack for equal edges).
    func covers(_ other: IslandShape) -> Bool { frame.insetBy(dx: -0.5, dy: -0.5).contains(other.frame) }
}

struct Shadow {
    var opacity: Float
    var radius: CGFloat
    var offsetY: CGFloat
}

private enum K {
    static let sensorSize = CGSize(width: 59, height: 34)        // sub_100202d1c literal (59, 34) @0x1005d5900
    static let sensorTopInset: CGFloat = 7                       // sub_100202d1c `fmov v2.2d, #7`; input = whole screen [I]
    static let compactWidthPercentage: CGFloat = 0.5             // layout.compactWidthPercentage
    static let concentricMinimumPadding: CGFloat = 8             // layout.concentricMinimumPadding
    static let maximumMinimalViewWidth: CGFloat = 45             // layout.maximumMinimalViewWidth
    static let adjunctAspectWidthInset: CGFloat = 8              // layout.adjunctAspectWidthInset (box +0x810)
    static let interContainerPadding: CGFloat = 8                // layout.interContainerPadding (box +0x828)
    static let mitosisInitialScaleFactor: CGFloat = 0.5          // mitosis.initialScaleFactor
    static let symmetryMinimumRequired: CGFloat = 0.75           // layout.symmetry.minimumRequired
    static let symmetryEdgePaddingThreshold: CGFloat = 46        // layout.symmetry.edgePaddingThreshold
    static let maximumShortPillHeight: CGFloat = 73              // layout.heightBands
    static let maximumPillHeight: CGFloat = 91
    static let defaultExpandedContentSize = CGSize(width: 250, height: 84)   // layout.defaultExpandedContentSize
    static let squareMin = CGSize(width: 143.667, height: 144.667)           // layout.square.minWidth/minHeight
    static let squareYOffset: CGFloat = 4, squareRadius: CGFloat = 39
    static let squareLargeHeight: CGFloat = 423                              // layout.square.squareLargeContentHeight
    static let ovalMin = CGSize(width: 250, height: 180)                     // layout.oval.minWidth/minHeight
    static let ovalYOffset: CGFloat = 4, ovalRadius: CGFloat = 90
    static let tallRectWidth: CGFloat = 166, tallRectMinHeight: CGFloat = 220 // layout.tallRect
    static let tallRectYOffset: CGFloat = 6, tallRectRadius: CGFloat = 71.333
    // Upper clamp sub_1001f704c: max(sensor, (min(availableWidth - 2 * topGap, 408), ...)); layoutMargin is not added.
    static let maximumExpandedWidth: CGFloat = 408
    // CenterHUDDisplayMetrics.defaultMaximumCornerRadius: 32 on an emulated display (builder emulate branch, `mov x8,
    // #0x4040000000000000` @0x100202a54; the hardware branch reads the display +0xb8 and also falls back to 32).
    // Apple's PROLED page image shows r ≈ 27 on the real panel.
    static let defaultMaximumCornerRadius: CGFloat = 32
}

/// Visual kind of the primary zone (drives hover, shadow and key line).
enum Zone: Equatable {
    case inert, compact, minimal, expanded(ExpandedType)

    /// centerHUD.shadow.<type>: entries exist only for expanded types; inert, compact and minimal have none (island-re;
    /// Apple's Live Activities kit draws only the key line on compact). Radius/offset kept so the fade has a shape.
    var shadow: Shadow {
        switch self {
        case .inert, .compact, .minimal: return Shadow(opacity: 0, radius: 13.333, offsetY: 5)
        case .expanded(let t): return shadowFor(t)
        }
    }
}

struct HoverMetrics: Equatable {
    var scale: CGFloat
    var lean: CGPoint
}

/// CenterHUDInteractionMetrics { hoverScale, leanMaximumOffset } per zone, from centerHUD.interaction.*.
/// Expanded has no hover scale entry; the expanded slider inflates instead (ExpandedSlider isInflated).
func hoverMetrics(_ z: Zone) -> HoverMetrics {
    switch z {
    case .inert: return HoverMetrics(scale: 1.15, lean: CGPoint(x: 2.75, y: 2))   // inertHoverScale / inertHoverLean
    case .compact, .minimal: return HoverMetrics(scale: 1.05, lean: CGPoint(x: 2, y: 1))   // compactHover*; minimal [I]
    case .expanded: return HoverMetrics(scale: 1, lean: .zero)
    }
}

/// Lean toward the pointer, up to `maximum` when the pointer is at (or beyond) the zone edge [I].
func lean(pointer p: CGPoint, in f: CGRect, maximum m: CGPoint) -> CGPoint {
    func unit(_ d: CGFloat, _ half: CGFloat) -> CGFloat { half > 0 ? min(max(d / half, -1), 1) : 0 }
    return CGPoint(x: unit(p.x - f.midX, f.width / 2) * m.x, y: unit(p.y - f.midY, f.height / 2) * m.y)
}

/// Initial uniform scale of incoming content (sub_10011c0c8): min(old / new) per axis, 1 where the new side is <= 0;
/// it then springs to 1 on the transition spring (contentSpring = transitions.spring x responseScale, 0x1000e7ef0).
func contentEntryScale(from old: CGSize, to new: CGSize) -> CGFloat {
    min(new.width > 0 ? old.width / new.width : 1, new.height > 0 ? old.height / new.height : 1)
}

/// Hover transform: scale about the center (CenterHUDZoneInteractionComponent minimumVerticalGrowthPerSide: grows on
/// both sides), then lean offset [I].
func hovered(_ s: IslandShape, scale k: CGFloat, offset o: CGPoint) -> IslandShape {
    let f = s.frame, w = f.width * k, h = f.height * k
    return IslandShape(frame: CGRect(x: f.midX - w / 2 + o.x, y: f.midY - h / 2 + o.y, width: w, height: h), cornerRadius: s.cornerRadius * k)
}

/// MenuBarAgentSettings.KeyLine (root settings @0xa0): darkBackgroundOpacity 0.35, lightBackgroundOpacity 1.0,
/// defaultTintColor 0.916 grey, fixedLstar 50; centerHUD.keyLine.thickness 2, isOutset true (KeyLineSpecification
/// built at 0x1001c2e40). Over a dark backdrop 27.3 draws the tint forced to L* 50 (sub_10033dc54) with plusL at 0.35;
/// over a light one, the backdrop through adaptiveColorMatrix (almost invisible); both live in a backdrop group.
/// Rebuilt as Apple's Live Activities kit draws it: lighten of #262626 (0.149) over the backdrop, which is the 27.3
/// dark result on black (0.149 vs 0.466 * 0.35 = 0.163) and invisible over anything lighter. Gone in inert.
enum KeyLine {
    static let thickness: CGFloat = 2, darkOpacity = 0.35
    static let tintLstar50 = 0.4663   // sRGB of a grey with L* 50: Y = (66 / 116)^3, 1.055 Y^(1/2.4) - 0.055
    static let lightenGray: CGFloat = 0.149   // kit DROP_SHADOW #262626, blend LIGHTEN, alpha 1
    static let appearSpring = (damping: 1.0, response: 0.75)        // centerHUD.keyLine.appearForSwoopSpring
    static let disappearSpring = (damping: 1.0, response: 1.2)      // centerHUD.keyLine.disappearToInertSpring
}

/// Key line visibility (the group's opacity): 1 with content, 0 in inert.
func keyLineOpacity(_ z: Zone) -> Double { z == .inert ? 0 : 1 }

/// User choice, not 27.3: with nothing to show the island collapses to the idle pill (27.3 toInert), then hides once the
/// shape has settled, unless the user keeps the idle pill (`defaults write -g GGIsland.showWhenIdle -bool YES`; read at
/// every change, so it applies from the next show).
func idleHidden(_ z: Zone, showWhenIdle: Bool, settled: Bool) -> Bool { z == .inert && !showWhenIdle && settled }

/// 27.3 never hides the island: a software CenterHUD keeps the black inert pill (RE-27-CENTERHUD s9). The hide follows
/// the iPhone Duo under-display camera (YouTube qMOZBcfpEF4, 2.90-3.28 s, measured per frame): the pill stays solid black
/// with sharp edges (no fade, no blur) and shrinks to a point at its centre, height ~e^(-6.8 t), width ~e^(-8.7 t) so it
/// rounds towards a circle; under 5 % after 0.45 s [V footage, I exponential fit]. Showing is not affected: the full pill
/// comes back at once and grows as 27.3 fromInert.
enum IdleHide {
    static let heightRate = 6.8, widthRate = 8.7, duration = 0.45

    /// Width and height factors of the idle pill t s after the hide started (always full when not hiding).
    static func factors(_ t: Double, hiding: Bool) -> (w: Double, h: Double) {
        guard hiding else { return (1, 1) }
        return t >= duration ? (0, 0) : (exp(-widthRate * t), exp(-heightRate * t))
    }
}
func showsIdlePill(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: "GGIsland.showWhenIdle") }

/// Springs (FluidSpringParameters dampingRatio / response).
enum Springs {
    static let transition = (damping: 0.75, response: 0.3843)            // centerHUD.transitions.spring
    static let contentInteraction = (damping: 1.0, response: 0.3974)     // centerHUD.interaction.contentInteractionSpring
    static let momentaryArrivalResponseScale = 0.6                       // centerHUD.transitionPolicy
    static let momentaryDepartureResponseScale = 1.0
    /// centerHUD.settling.collisionProgress: throughInert starts its fromInert leg once the toInert leg passes this
    /// (Begin.afterProgress, written at 0x100186b60).
    static let collisionProgress = 0.9668
    /// Contents going dark as two containers merge (throughInert's toInert leg, recombination): off within about 50 ms of
    /// contact (FOOTAGE-MAC-PROLED 5c.1) / 0.08 s (5c.2) [I footage; the 27.3 opacity spring of this step is not read].
    static let mergeContentFade = (damping: 1.0, response: 0.08)
}

/// Share of a collapse toward the inert pill already done, measured on the width (CenterHUDTransitionProgress [I axis]).
func collapseProgress(start: CGFloat, current: CGFloat, inert: CGFloat) -> Double {
    start == inert ? 1 : Double((start - current) / (start - inert))
}

/// centerHUD.shadow.<type> (opacity, radius, offsetY; offsetX is 0). nil = compact/minimal, which have no own entry [I].
func shadow(for type: ExpandedType?) -> Shadow { shadowFor(type) }

private func shadowFor(_ type: ExpandedType?) -> Shadow {
    switch type {
    case .pill: return Shadow(opacity: 0.4, radius: 16.667, offsetY: 5)
    case .standard, .tallRect: return Shadow(opacity: 0.4, radius: 16.667, offsetY: 10.667)
    case .square, .squareLarge, .oval: return Shadow(opacity: 0.35, radius: 20, offsetY: 9.333)
    case .shortPill, nil: return Shadow(opacity: 0.25, radius: 13.333, offsetY: 5)
    }
}

/// sub_1001fe6fc: 73 / 91 height bands; the default preference never yields standard; no height -> pill.
func expandedType(height: CGFloat?, preference: ShapePreference) -> ExpandedType {
    guard let h = height, h > 0 else { return .pill }
    let auto: ExpandedType = h <= K.maximumShortPillHeight ? .shortPill : (h <= K.maximumPillHeight ? .pill : .standard)
    switch preference {
    case .standard: return .standard
    case .automatic: return auto
    case .defaultPill: return auto == .shortPill ? .shortPill : .pill
    }
}

/// PKGPrivacyIndicatorMediaType { camera, microphone, systemScreenRecording, systemAudioRecording } (SkyLight 27.3) [V].
enum PrivacyIndicatorKind: CaseIterable {
    case camera, microphone, screenRecording, systemAudio

    /// MediaLayer (0x182bfe938, block 0x182bfec0c-0x182bfee58), sRGB by Context.appearance (+0x44): light / dark menu bar [V].
    func rgb(dark: Bool) -> (r: Int, g: Int, b: Int) {
        switch self {
        case .camera: return dark ? (50, 215, 75) : (40, 205, 65)
        case .microphone: return dark ? (255, 159, 10) : (255, 149, 0)
        case .screenRecording: return dark ? (99, 97, 241) : (84, 82, 204)
        case .systemAudio: return dark ? (191, 90, 242) : (175, 82, 222)
        }
    }

    /// One dot per location (MediaIndicatorController.mediaType: a single value) [V]; which type wins with several is
    /// not read [?]: declaration order, so camera beats microphone as on iOS [I].
    static func shown(in kinds: Set<PrivacyIndicatorKind>) -> PrivacyIndicatorKind? { allCases.first(where: kinds.contains) }
}

enum PrivacyIndicatorMetrics {
    /// PKGPrivacyIndicatorWindowContainer (0x182c35b34-0x182c35c98): centre x = CenterHUD rect maxX + 6 (RTL minX - 6),
    /// y = midY [V]. The island draws LTR only.
    static let centerOffset: CGFloat = 6
    /// The CenterHUD default rect is not the sensor: WS::Displays::Display::evaluate_display_parts (SkyLight
    /// 0x18286f80c-0x18286f86c) widens the aperture by max(0, d13 - d12) x corner_expansion_factor per side, the factor
    /// read at run time (0x18286fc98) [V shape, ? value]. 4 pt fits FOOTAGE-MAC-PROLED 4 (dot-only pill 114, camera
    /// +47 right, dot centre 40 from the pill centre) [I].
    static let centerHUDRectExpansion: CGFloat = 4
    /// layout.privacyIndicatorPadding: between the indicator's outer edge and a trailing minimal view (sub_1001fa96c) [V].
    static let padding: CGFloat = 6
    /// Footage (FOOTAGE-MAC-PROLED 4): the dot fades in from ~0.17 s to 0.4 s after the shape starts; on exit it stays
    /// 0.22 s (the island first shrinks to the dot-only pill), then fades in ~0.07 s while the pill shrinks to idle [I].
    /// MediaIndicatorController.Phase / minOnTime values are not read [?].
    static let appearDelay = 0.17, appearDuration = 0.23, exitHold = 0.22, exitFade = 0.07

    /// Round; microphone with differentiateWithoutColor (+0x49) has radius 0 (0x182bfeb08) [V].
    static func isSquare(_ kind: PrivacyIndicatorKind, differentiateWithoutColor: Bool) -> Bool {
        kind == .microphone && differentiateWithoutColor
    }

    /// sub_182c08990: key = max(pointW / physW, pointH / physH) (fcsel ls at 0x182c089c4); first table entry whose density
    /// exceeds the key or lies within 0.1 of it, else the last [V]. Entries 85.5-110.0 all give 5, folded into one.
    static func diameter(pointsPerInch key: CGFloat) -> CGFloat {
        let table: [(density: CGFloat, diameter: CGFloat)] = [(110.0, 5), (116.4, 5.5), (127.5, 6), (128.1, 6), (148.9, 7),
                                                               (151.5, 7), (174.6, 8), (186.3, 8.5), (219.0, 10)]
        return table.first { abs($0.density - key) < 0.1 || key < $0.density }?.diameter ?? 10
    }

    static func pointsPerInch(points: CGSize, millimeters: CGSize) -> CGFloat {
        guard millimeters.width > 0, millimeters.height > 0 else { return 0 }
        return max(points.width / (millimeters.width / 25.4), points.height / (millimeters.height / 25.4))
    }
}

struct IslandGeometry {
    let screen: CGRect
    let scale: CGFloat
    let sensor: CGRect
    /// Diameter of the trailing privacy indicator, 0 when none (CenterHUDPrivacyIndicatorGeometry.trailing).
    var privacyIndicatorDiameter: CGFloat = 0

    init(screen: CGRect, scale: CGFloat) {
        self.screen = screen
        self.scale = scale
        sensor = CGRect(x: screen.minX + (screen.width - K.sensorSize.width) / 2,
                        y: screen.maxY - K.sensorTopInset - K.sensorSize.height,
                        width: K.sensorSize.width, height: K.sensorSize.height)
    }

    func roundPx(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    func floorPx(_ v: CGFloat) -> CGFloat { (v * scale).rounded(.down) / scale }

    /// Physical sensor frame in emulate: sub_100202d48 of the dynamic frame, x + t, top 1 pt lower, w - 2t, h - 1, with t =
    /// table @0x1005d5910 {0.5, 0.7643325, 0.575, 0.6}[layout.cornerCurve = 3 (ID1)] = 0.6 (island-re). The inert zone then
    /// rounds it outwards to pixels (sub_1002e32f4: minX floor, maxX ceil) in sub_1001fa708.
    var physicalSensor: CGRect {
        let t: CGFloat = 0.6
        let minX = (((sensor.minX + t) * scale).rounded(.down)) / scale, maxX = (((sensor.maxX - t) * scale).rounded(.up)) / scale
        return CGRect(x: minX, y: sensor.minY, width: maxX - minX, height: sensor.height - 1)
    }

    /// The empty island: layout.emptySensorRegionHeight = physical (contentSensorRegionHeight = dynamic), read by
    /// sub_1002007ec. States with content stay anchored to the dynamic `sensor`.
    /// With a privacy indicator (sub_1001fa708): the dynamic frame, inset by -(the larger side's outer edge distance +
    /// pad(indicator width)) on both sides, rounded outwards to pixels, radius min(32, min(w, h) / 2) [V].
    var inert: IslandShape {
        guard privacyIndicatorDiameter > 0 else { return IslandShape(frame: physicalSensor, cornerRadius: physicalSensor.height / 2) }
        let e = indicatorExtension
        let minX = ((sensor.minX - e) * scale).rounded(.down) / scale, maxX = ((sensor.maxX + e) * scale).rounded(.up) / scale
        let f = CGRect(x: minX, y: sensor.minY, width: maxX - minX, height: sensor.height)
        return IslandShape(frame: f, cornerRadius: min(K.defaultMaximumCornerRadius, min(f.width, f.height) / 2))
    }

    var privacyIndicatorCenter: CGPoint? {
        privacyIndicatorDiameter > 0 ? CGPoint(x: sensor.maxX + centerFromSensor, y: sensor.midY) : nil
    }

    private var centerFromSensor: CGFloat { PrivacyIndicatorMetrics.centerHUDRectExpansion + PrivacyIndicatorMetrics.centerOffset }

    /// sub_100201a9c: distance from the sensor edge to the indicator's outer edge (Side.outerEdgeX - maxX). Outer edge =
    /// centre + diameter / 2 and indicatorWidth = diameter [I: WindowServer's requiredWidth is not read].
    private var indicatorOuterEdge: CGFloat {
        privacyIndicatorDiameter > 0 ? centerFromSensor + privacyIndicatorDiameter / 2 : 0
    }

    /// Outer edge + concentric pad of the indicator width, kept >= 0 (sub_1001fa708 0x1001fa7d0-0x1001fa888) [V].
    private var indicatorExtension: CGFloat {
        privacyIndicatorDiameter > 0 ? max(0, indicatorOuterEdge + pad(privacyIndicatorDiameter)) : 0
    }

    /// privacyIndicatorPadding + outer edge, kept >= 0: what a trailing view needs past the sensor to clear the dot
    /// (compact 0x1001f8a1c, minimal 0x1001faaec) [V].
    private var indicatorPast: CGFloat {
        privacyIndicatorDiameter > 0 ? max(0, PrivacyIndicatorMetrics.padding + indicatorOuterEdge) : 0
    }

    /// Concentric padding (RE 4.1 step 3): a round content view sits on a circle concentric with the pill cap.
    private func pad(_ w: CGFloat) -> CGFloat {
        roundPx(max(K.concentricMinimumPadding, sensor.height / 2 + 1 / scale - w / 2))
    }

    /// sub_1002026b0: the shorter side only needs 0.75 of the longer one when the longer one keeps > 46 pt to the edge.
    private func symmetric(_ l: CGFloat, _ r: CGFloat) -> (CGFloat, CGFloat) {
        let edgeL = sensor.minX - l - screen.minX, edgeR = screen.maxX - sensor.maxX - r
        if r < l && edgeL > K.symmetryEdgePaddingThreshold { return (l, max(r, roundPx(K.symmetryMinimumRequired * l))) }
        if l < r && edgeR > K.symmetryEdgePaddingThreshold { return (max(l, roundPx(K.symmetryMinimumRequired * r)), r) }
        let m = max(l, r)
        return (m, m)
    }

    private func pill(_ l: CGFloat, _ r: CGFloat) -> IslandShape {
        IslandShape(frame: CGRect(x: sensor.minX - l, y: sensor.minY, width: sensor.width + l + r, height: sensor.height),
                    cornerRadius: sensor.height / 2)
    }

    /// sub_1001f87e4. Returns the shape and the x of each content view.
    /// Trailing privacy indicator (0x1001f8a1c-0x1001f8a74): the trailing side adds privacyIndicatorPadding (+0x848) +
    /// the outer edge distance, kept >= 0, with or without a trailing view, before balancing [V].
    func compact(leading: CGFloat, trailing: CGFloat?) -> (shape: IslandShape, leadingX: CGFloat, trailingX: CGFloat?) {
        let sideMax = floorPx((K.compactWidthPercentage * screen.width - sensor.width) / 2)
        let wl = min(sideMax, leading), pl = pad(wl)
        let wr = trailing.map { min(sideMax, $0) }, pr = wr.map(pad)
        let (l, r) = symmetric(wl + pl, (wr.map { $0 + pr! } ?? 0) + indicatorPast)
        let s = pill(l, r)
        // Content at the outer edge + concentric padding (sub_1001f87e4, 0x1001f8e4c-0x1001f8e70); balancing slack lies
        // on the sensor side (RE-27-BEHAVIOR s18).
        return (s, s.frame.minX + pl, wr.map { s.frame.maxX - pr! - $0 })
    }

    /// sub_1001fa96c: one content view, width capped at 45, extended on `edge` (CenterHUDHorizontalEdge, input byte
    /// read at 0x1001faad8) then balanced; content at that outer edge + padding (sub_100202114, 0x1001facd0) [V].
    /// A standalone AV module uses .trailing (0x1000d13ec) [V]; standard minimal .leading (0x1000d6a48) [I which caller].
    /// `hasAdjunct` (CenterHUDPrimaryMinimalConfiguration.hasAdjunctZone): a leading minimal drops its trailing
    /// extension so the adjunct sits next to the sensor (`movi v3, #0` at 0x1001fabf8, no privacy indicator) [V].
    /// Trailing privacy indicator (0x1001faaec-0x1001fab6c, 0x1001fac04): a trailing view adds privacyIndicatorPadding +
    /// the outer edge distance; a leading view's trailing side gets the inert extension, kept with an adjunct [V].
    func minimal(width: CGFloat, edge: HorizontalEdge = .leading, hasAdjunct: Bool = false) -> (shape: IslandShape, contentX: CGFloat) {
        let w = min(width, K.maximumMinimalViewWidth), p = pad(w)
        var (l, r) = edge == .leading ? symmetric(w + p, indicatorExtension) : symmetric(0, w + p + indicatorPast)
        if hasAdjunct && edge == .leading { r = indicatorExtension }
        let s = pill(l, r)
        return (s, edge == .leading ? s.frame.minX + p : s.frame.maxX - p - w)
    }

    /// Adjunct container (mitosis), sub_1001f7570: height = sensor height, width = max(sensorH, aspect * sensorH -
    /// 2 * layout.adjunctAspectWidthInset), pixel-rounded, radius min(w, h) / 2 capped at defaultMaximumCornerRadius [V].
    /// x = primary trailing edge + layout.interContainerPadding (sub_1001f79c4 reads box +0x828) [V value, I reference].
    func adjunct(after primary: IslandShape, content: CGSize) -> IslandShape {
        let h = sensor.height, aspect = content.height > 0 ? content.width / content.height : 1
        let w = roundPx(max(h, aspect * h - 2 * K.adjunctAspectWidthInset))
        return IslandShape(frame: CGRect(x: primary.frame.maxX + K.interContainerPadding, y: sensor.minY, width: w, height: h),
                           cornerRadius: min(min(w, h) / 2, K.defaultMaximumCornerRadius))
    }

    /// Where the adjunct starts its mitosis and ends its recombination (sub_1001f79c4 flag branch): size x
    /// mitosis.initialScaleFactor (box +0x630 [I field]), vertically centred, right edge interContainerPadding before
    /// the final left edge, i.e. tucked under the primary's trailing end [V arithmetic, I reference frame].
    func adjunctHidden(_ a: IslandShape) -> IslandShape {
        let k = K.mitosisInitialScaleFactor, w = a.frame.width * k, h = a.frame.height * k
        return IslandShape(frame: CGRect(x: a.frame.minX - K.interContainerPadding - w, y: a.frame.midY - h / 2, width: w, height: h),
                           cornerRadius: a.cornerRadius * k)
    }

    /// sub_1001f9440 (sizes, radii and vertical offsets per type). `type` is a client-chosen square/oval/tallRect/squareLarge.
    func expanded(content: CGSize?, type: ExpandedType?, preference: ShapePreference) -> (shape: IslandShape, type: ExpandedType) {
        let valid = content.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let c = valid ?? K.defaultExpandedContentSize
        let t = type ?? expandedType(height: valid?.height, preference: preference)
        let maxW = K.maximumExpandedWidth
        var size: CGSize, radius: CGFloat, yOffset: CGFloat = 0
        switch t {
        case .standard, .pill, .shortPill:
            size = CGSize(width: min(max(c.width, sensor.width), maxW), height: min(max(c.height, sensor.height), K.squareLargeHeight))
            radius = min(size.width, size.height) / 2
            if t == .standard { radius = min(radius, K.defaultMaximumCornerRadius) }
        case .square:
            let w = min(maxW, max(K.squareMin.width, c.width))
            size = CGSize(width: w, height: w * K.squareMin.height / K.squareMin.width)
            radius = K.squareRadius; yOffset = K.squareYOffset
        case .squareLarge:
            size = CGSize(width: maxW, height: K.squareLargeHeight); radius = K.defaultMaximumCornerRadius
        case .oval:
            let w = min(maxW, max(K.ovalMin.width, c.width))
            size = CGSize(width: w, height: w * K.ovalMin.height / K.ovalMin.width)
            radius = K.ovalRadius; yOffset = K.ovalYOffset
        case .tallRect:
            size = CGSize(width: K.tallRectWidth, height: max(c.height, K.tallRectMinHeight))
            radius = K.tallRectRadius; yOffset = K.tallRectYOffset
        }
        size = CGSize(width: roundPx(size.width), height: roundPx(size.height))
        let top = sensor.maxY - yOffset   // top edge anchored to the sensor top [I]
        let frame = CGRect(x: sensor.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        return (IslandShape(frame: frame, cornerRadius: roundPx(radius)), t)
    }
}

// MARK: - Corner curve (ViewCornerCurve case 3, the layout.cornerCurve default; sub_10020223c, literals @0x1005d56a0)
// 27.3 uses it only for the gap between the primary and adjunct pills (mitosis, caller 0x1001f7b74), not for the outline.

private let curveA = 1.2738875, curveB = -0.2738875
private let curveK = -0.0690355937
private let curveC = (-4.82147, 16.0335, -17.858, 4.90132, 2.74464)
private let curveExtent = 1.528665

private func curveF(_ a: Double, _ b: Double) -> Double {
    let mx = max(a, b), rho = mx == 0 ? 0 : min(a, b) / mx
    let poly = (((curveC.0 * rho + curveC.1) * rho + curveC.2) * rho + curveC.3) * rho + curveC.4
    return hypot(a, b) + curveK * rho * rho * poly - 1
}

/// Inset of the outline at distance x along an edge from the corner, for corner radius r (0 beyond 1.2 r).
func cornerInset(_ x: Double, radius r: Double) -> Double {
    let e = curveExtent * r
    guard r > 0, x < e else { return 0 }
    let a = max(curveA * (1 - x / e) + curveB, 0)
    var lo = 0.0, hi = 1.0
    for _ in 0..<32 {
        let m = (lo + hi) / 2
        if curveF(a, max(curveA * m + curveB, 0)) <= 0 { lo = m } else { hi = m }
    }
    return e * (1 - (lo + hi) / 2)
}

/// Closed outline of the island. The 27.3 layer uses kCACornerCurveID1 (expansion factor 1.0 in QuartzCore +[CALayer
/// cornerCurveExpansionFactor:]: the corner ends at r along each edge). Its exact profile is not in the binaries; the
/// corners of Apple's PROLED island image fit a circle (error 0.24) far better than the case 3 profile above (2.32), so
/// the outline is circular [I measured]. The radius is capped at half the shorter side, so pills are capsules.
func islandPath(_ s: IslandShape) -> CGPath {
    let f = s.frame, r = min(s.cornerRadius, min(f.width, f.height) / 2)
    return CGPath(roundedRect: f, cornerWidth: r, cornerHeight: r, transform: nil)
}
