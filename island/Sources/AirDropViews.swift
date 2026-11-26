// AirDrop compact island views from 27.3 AirDropUI (IntegratedViewGroup_V1 at 0x100089970). The progress ring is the
// airdrop-progress.ca package redrawn in SwiftUI (the package is not on 26.6 and is not copied).
// Values and addresses: docs/RE-27-BEHAVIOR.md section 21. [V] read from the binary, [I] inferred, [?] unknown.
import AppKit
import SwiftUI

enum AirDropMetrics {
    /// AirDropSymbolSystemApertureIcon: Image(_internalSystemName: "airdrop") (0x10008e118), private on 26.6 [V].
    static let symbol = "airdrop"
    static let iconSize: CGFloat = 18          // 0x1000899ec [V]
    static let padding: CGFloat = 2            // EdgeInsets(0, 2, 0, 2), 0x1000899d4 / 0x10008a590 [V]
    /// 20 when the host reports an obstruction, 16 when obstructionSize is .zero (0x10008a3c4) [V]; the island here
    /// always has a (fake) sensor, so 20 [I].
    static let ringSize: CGFloat = 20
    static let iconRGB = (0.043, 0.608, 1.0)   // Color(.sRGB, ...) global 0x1000e4b30, set at 0x100045cfc [V]

    static func compactLeadingSize(sensorHeight h: CGFloat) -> CGSize { CGSize(width: padding + iconSize + padding, height: h) }
    /// Minimal shares the compactLeading closure (0x10008df5c -> 0x100089994, no session input) [V]: same 22 x H for the
    /// split primary and adjunct; any per-slot scaling is the host's [I].
    static func minimalSize(sensorHeight h: CGFloat) -> CGSize { compactLeadingSize(sensorHeight: h) }
    static func compactTrailingSize(sensorHeight h: CGFloat) -> CGSize { CGSize(width: padding + ringSize + padding, height: h) }

    // MARK: Ring (airdrop-progress.ca/main.caml, root 50 x 50; 200-unit shape scaled 0.423 * 2.596 / 3 = 0.366) [V]

    /// `progress fill` strokeStart = 0.999 - max(fractionCompleted, 0.01) (0x1000395d8), clamped like CA.
    static func strokeStart(_ fraction: Double) -> Double { max(0.999 - max(fraction, 0.01), 0) }
    /// currentMicaState (0x1000a128c): "compact-done" when fractionCompleted >= 1 (0x1000a1448), else "compact".
    static func isDone(_ p: AirDropProgress) -> Bool { p.fraction >= 1 }
    /// Path centre line is a circle of radius about 21.9 of 50 [V numbers, I circle fit].
    static let diameterRatio = 0.876
    /// lineWidth 15.6, compact-done 10.6, times 0.366, over 50.
    static func lineRatio(done: Bool) -> Double { (done ? 10.6 : 15.6) * 0.366036 / 50 }
    static let trackRGB = (-0.07883, 0.1984, 0.433)   // `back fill` strokeColor (extended sRGB)
    /// `progress fill` strokeColor; compact-done sets it to white.
    static func fillRGB(done: Bool) -> (Double, Double, Double) { done ? (1, 1, 1) : (0.04583, 0.6083, 1.002) }

    /// compact-done draws the `check` shape (strokeEnd 0 -> 1, colour 0.9726, lineWidth 29.1, layer scale 2.405).
    /// Path points mapped into root units over 50, y down: move 0, line 1, curve(to 3, c1 1, c2 2), curve(to 5, c1 4, c2 5).
    static let checkPoints = [CGPoint(x: 15.242, y: 26.069), CGPoint(x: 20.294, y: 32.561), CGPoint(x: 22.160, y: 34.506),
                              CGPoint(x: 23.906, y: 31.912), CGPoint(x: 25.652, y: 29.318), CGPoint(x: 33.847, y: 16.553)]
        .map { CGPoint(x: $0.x / 50, y: $0.y / 50) }
    static let checkLineRatio = 29.1 * 0.175 * 2.405 / 3 / 50
    static let checkWhite = 0.9726
    /// State transitions of the package (compact <-> compact-done, zoom <-> zoom-done): CASpringAnimation mass 2,
    /// stiffness 300, damping 50 (main.caml) [V]; SwiftUI runs the same spring to rest instead of CA's 0.8 s cut [I].
    static let stateSpring = Animation.interpolatingSpring(mass: 2, stiffness: 300, damping: 50)
    /// Before done (main.caml base values, all reached on stateSpring except the scale) [V]: the `saving` layer (#7, centre
    /// 75.67, 75.30 of 150) sits at scale 1 and grows to 2.405 on a damping-20 spring (CA duration 1.455; compact
    /// beginTime 0.01, dropped); the check (#6) is blue (0.04465, 0.6083, 1.002), line 25.4, blur 37.5. Ratios here are
    /// at the final scale (x 0.175 x 2.405 / 3, over 50) because the view scales the drawn check as a whole.
    static let checkSpring = Animation.interpolatingSpring(mass: 2, stiffness: 300, damping: 20)
    static let checkStartScale: CGFloat = 1 / 2.405
    static let checkAnchor = UnitPoint(x: 75.672157287597 / 150, y: 75.299247741699 / 150)
    static let checkBlueRGB = (0.04465, 0.6083, 1.002)
    static let checkStartLineRatio = 25.4 * 0.175 * 2.405 / 3 / 50
    static let checkBlurRatio = 37.5 * 0.175 * 2.405 / 3 / 50
    /// zoom-done: `stop button` opacity 1 -> 0 and gaussianBlur 0 -> 25 in the 150 layer scaled 1/3, on stateSpring [V].
    static let stopBlurRatio = 25.0 / 3 / 50

    // MARK: Count overlay (AirDropSystemApertureProgress body 0x10009fb88) [V]

    /// count >= 2 (0x1000a035c) with no state check, so 27.3 keeps the number over the compact-done check mark [V].
    /// 27.3 counts the transfers of the banner session (array count set at 0x10000cbfc) [I element type].
    static func showsCount(_ p: AirDropProgress) -> Bool { p.itemCount >= 2 }
    /// NSNumberFormatter (style [?]).
    static func countText(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .none) }
    static let countFrame = ringSize * 0.6   // 0x1000a0528

    // MARK: Expanded rows (RE-27-BEHAVIOR 21.2.1 - 21.2.4)

    /// 0x1000891b8: 274 unless a single transfer failed (234); both rows here are 274 [V].
    static let expandedWidth: CGFloat = 274

    /// zoom (expanded, in flight): line 13.1, zoom-done 7.7, times 0.366, over 50 (main.caml) [V numbers, I conversion].
    static func zoomLineRatio(done: Bool) -> Double { (done ? 7.7 : 13.1) * 0.366036 / 50 }
    static let zoomCheckLineRatio = 26 * 0.175 * 2.405 / 3 / 50
    /// `stop button` 48 x 48, corner 13 continuous, scale 1.05, in the 150 layer scaled 1/3; colour (0.04465, 0.6083, 1.002).
    static let stopSideRatio = 48 * 1.05 / 3 / 50
    static let stopCornerRatio = 13 * 1.05 / 3 / 50
    static let stopRGB = (0.04465, 0.6083, 1.002)

    /// AirDropProgressView in the island on macOS (isHostedInJindo): HStack spacing 8 (0x100036178), padding
    /// EdgeInsets(11, 16, 11, 11) (0x1000360e8), frame(minHeight: 60) [I parameter], ring 38 (0x100036818) [V].
    static let progressInsets = EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 11)
    static let progressSpacing: CGFloat = 8
    static let progressMinHeight: CGFloat = 60
    static let expandedRingSize: CGFloat = 38
    static let progressTitle = "AirDrop"   // String(localized: "AIRDROP"), same in en and vi

    /// AirDropModernReadyForOpenView, liveActivitiesUI branch: padding 16 (0x10004988c), HStack(.top) spacing 12
    /// (0x10004b24c), icon frame 32 x 27 (0x10004bd24), text padding 4 (0x10004c0d0) [V].
    static let readyPadding: CGFloat = 16
    static let readySpacing: CGFloat = 12
    static let readyIconSize = CGSize(width: 32, height: 27)
    static let readyTextPadding: CGFloat = 4

    /// AirDropUIOpenButtonTitle (AirDropUI Localizable.loctable); the 27.3 label comes from sharingd [I].
    static func openTitle(language: String = BannerMetrics.language) -> String { language.hasPrefix("vi") ? "Mở" : "Open" }

    /// DeviceDiscoveryUI AirDropUIButtonStyle(.jindoDefault, .hugging) on macOS (RE-27-BEHAVIOR 21.2.5) [V]:
    /// .font(.body) (0x222b38a18), lineLimit 1 + minimumScaleFactor 0.7 + padding (10, 16, 10, 16) (0x222b37de0),
    /// Capsule(.continuous) of sRGB gray 0.302 (0x222b36c04), white label, both at opacity 0.8 while pressed (0x222b37050).
    /// AirDropUI builds a .fillingFullSize and a .hugging button row inside a ViewThatFits; this build uses .hugging [I].
    static let openButtonInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    static let openButtonMinScale: CGFloat = 0.7
    static let openButtonGray = 0.302
    static let openButtonPressedOpacity = 0.8
    static var openButtonFont: NSFont { .preferredFont(forTextStyle: .body) }
    /// No fixed size in 27.3: label plus padding, label rounded up to whole points as NSHostingView lays it out at 1x.
    static func openButtonSize(language: String = BannerMetrics.language) -> CGSize {
        let t = (openTitle(language: language) as NSString).size(withAttributes: [.font: openButtonFont])
        let w = ceil(t.width), h = ceil(t.height)
        return CGSize(width: w + openButtonInsets.leading + openButtonInsets.trailing,
                      height: h + openButtonInsets.top + openButtonInsets.bottom)
    }
    /// Top-left origin; the button is the last item of the HStack(.top) inside the 16 padding.
    /// Cancel hit rects, top-left origin. 27.3's Button(action: cancel) wraps only the icon frame(s, s) (0x10009fb88) [V];
    /// tapping the compact trailing ring cancels (0x1000a0ac4) [V]. Expanded: inside AirDropExpandedProgress content,
    /// right inset 11, ring 38, centred by HStack(.center) [V numbers, I centring]. Compact: inside the trailing frame,
    /// padding 2 outside the button (0x10008a590), ring 20 vertically centred [V].
    static func expandedRingFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width - progressInsets.trailing - expandedRingSize, y: (size.height - expandedRingSize) / 2,
               width: expandedRingSize, height: expandedRingSize)
    }
    static func compactRingFrame(trailingSize s: CGSize) -> CGRect {
        CGRect(x: s.width - padding - ringSize, y: (s.height - ringSize) / 2, width: ringSize, height: ringSize)
    }

    static func openButtonFrame(in size: CGSize, language: String = BannerMetrics.language) -> CGRect {
        let b = openButtonSize(language: language)
        return CGRect(x: size.width - readyPadding - b.width, y: readyPadding, width: b.width, height: b.height)
    }

    /// Heights follow the content (27.3 sets no fixed height, 21.2): measured, width fixed at 274.
    @MainActor static func expandedProgressSize(progress: AirDropProgress, subtitle: String?) -> CGSize {
        NSHostingView(rootView: AirDropExpandedProgress(progress: progress, subtitle: subtitle)).fittingSize
    }
    @MainActor static func expandedReadyForOpenSize(title: String, subtitle: String) -> CGSize {
        NSHostingView(rootView: AirDropExpandedReadyForOpen(title: title, subtitle: subtitle, onOpen: {})).fittingSize
    }
}

private func rgb(_ c: (Double, Double, Double), _ o: Double = 1) -> Color { Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: o) }

/// AirDrop minimal (split primary or adjunct): the compact leading icon, no progress ring (see minimalSize) [V].
typealias AirDropMinimal = AirDropCompactLeading

struct AirDropCompactLeading: View {
    var body: some View {
        symbolImage(AirDropMetrics.symbol, pointSize: AirDropMetrics.iconSize)
            .resizable()
            .foregroundStyle(rgb(AirDropMetrics.iconRGB))
            .frame(width: AirDropMetrics.iconSize, height: AirDropMetrics.iconSize)
            .padding(.horizontal, AirDropMetrics.padding)
    }
}

/// The airdrop-progress package: track, fill (clockwise from 12 o'clock [I]) and, when done, the check. `expanded`
/// selects the zoom states (thinner ring, stop square while in flight) instead of compact.
struct AirDropRing: View {
    var progress: AirDropProgress
    var size: CGFloat = AirDropMetrics.ringSize
    var expanded = false
    private typealias M = AirDropMetrics
    var body: some View {
        let s = size, done = M.isDone(progress)
        let line = s * (expanded ? M.zoomLineRatio(done: done) : M.lineRatio(done: done))
        let fill = 1 - M.strokeStart(progress.fraction)
        ZStack {
            Circle().stroke(rgb(M.trackRGB), lineWidth: line)
            Circle().trim(from: 0, to: fill)
                .stroke(rgb(M.fillRGB(done: done)), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: s * M.diameterRatio, height: s * M.diameterRatio)
        .frame(width: s, height: s)
        .animation(M.stateSpring, value: done)
        .overlay {
            // check: strokeEnd 0 -> 1, blur -> 0, blue -> white, line 25.4 -> final on stateSpring; scale on checkSpring.
            let doneLine = expanded ? M.zoomCheckLineRatio : M.checkLineRatio
            Path { p in
                let q = M.checkPoints.map { CGPoint(x: $0.x * s, y: $0.y * s) }
                p.move(to: q[0]); p.addLine(to: q[1])
                p.addCurve(to: q[3], control1: q[1], control2: q[2])
                p.addCurve(to: q[5], control1: q[4], control2: q[5])
            }
            .trim(from: 0, to: done ? 1 : 0)
            .stroke(done ? Color(.sRGB, white: M.checkWhite) : rgb(M.checkBlueRGB),
                    style: StrokeStyle(lineWidth: s * (done ? doneLine : M.checkStartLineRatio), lineCap: .round))
            .blur(radius: done ? 0 : s * M.checkBlurRatio)
            .animation(M.stateSpring, value: done)
            .scaleEffect(done ? 1 : M.checkStartScale, anchor: M.checkAnchor)
            .animation(M.checkSpring, value: done)
            if expanded {
                RoundedRectangle(cornerRadius: s * M.stopCornerRatio, style: .continuous)
                    .fill(rgb(M.stopRGB))
                    .frame(width: s * M.stopSideRatio, height: s * M.stopSideRatio)
                    .blur(radius: done ? s * M.stopBlurRatio : 0)
                    .opacity(done ? 0 : 1)
                    .animation(M.stateSpring, value: done)
            }
        }
    }
}

/// AirDropSystemApertureProgress: ring plus the count. 27.3 wraps it in Button(action: cancel) with PlainButtonStyle
/// [V]; here the Button exists only when the owner passes onCancel. The press look (PressActionsModifier) [?].
private struct AirDropProgressIcon: View {
    var progress: AirDropProgress
    var size: CGFloat
    var expanded: Bool
    var onCancel: (() -> Void)?
    var body: some View {
        if let onCancel { Button(action: onCancel) { icon }.buttonStyle(.plain) } else { icon }
    }
    private var icon: some View {
        AirDropRing(progress: progress, size: size, expanded: expanded)
            .overlay {
                if AirDropMetrics.showsCount(progress) {
                    Text(AirDropMetrics.countText(progress.itemCount))
                        .font(.title2)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(width: size * 0.6, height: size * 0.6)
                }
            }
    }
}

struct AirDropCompactTrailing: View {
    var progress: AirDropProgress
    /// Tapping the ring cancels the transfer in 27.3; nil keeps the ring passive.
    var onCancel: (() -> Void)? = nil
    var body: some View {
        AirDropProgressIcon(progress: progress, size: AirDropMetrics.ringSize, expanded: false, onCancel: onCancel)
            .padding(.horizontal, AirDropMetrics.padding)
    }
}

/// AirDropDescriptionView (0x1000357c4): title in the given font, `.primary`; the subtitle at 50 % [I opacity].
/// Title gets 3 pt vertical padding when there is no subtitle [I condition]; lineHeight (tight / variable) not set [?].
/// Title: environment(\.lineLimit, 1) + truncationMode(.tail) (0x100033eac, 0x100033fbc) [V]. Subtitle line limit from
/// LineConfiguration: 2 in the ProgressView, none for the ReadyForOpen sender line (21.2.3) [V].
private struct AirDropDescription: View {
    var title: String
    var titleFont: Font
    var subtitle: String?
    var subtitleFont: Font
    var subtitleLineLimit: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, subtitle == nil ? 3 : 0)
            if let subtitle {
                Text(subtitle)
                    .font(subtitleFont)
                    .lineLimit(subtitleLineLimit)
                    .foregroundStyle(.primary.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// AirDropProgressView hosted in the island (21.2.1): "AirDrop" in callout bold tight, the progress line in subheadline
/// tight, the 38 pt ring in the zoom states.
struct AirDropExpandedProgress: View {
    var progress: AirDropProgress
    var subtitle: String?
    /// Tapping the ring (stop square while in flight) cancels in 27.3; nil keeps it passive.
    var onCancel: (() -> Void)? = nil
    private typealias M = AirDropMetrics
    var body: some View {
        HStack(alignment: .center, spacing: M.progressSpacing) {
            AirDropDescription(title: M.progressTitle, titleFont: .callout.leading(.tight).bold(),
                               subtitle: subtitle, subtitleFont: .subheadline.leading(.tight), subtitleLineLimit: 2)
            AirDropProgressIcon(progress: progress, size: M.expandedRingSize, expanded: true, onCancel: onCancel)
        }
        .padding(M.progressInsets)
        .frame(minHeight: M.progressMinHeight)
        .frame(width: M.expandedWidth)
        .environment(\.colorScheme, .dark)
    }
}

/// AirDropModernReadyForOpenView, macOS liveActivitiesUI branch (21.2.2): zoom-done package in 32 x 27, title in
/// headline tight, subtitle in body tight, then the Open button.
struct AirDropExpandedReadyForOpen: View {
    var title: String
    var subtitle: String
    var onOpen: () -> Void
    private typealias M = AirDropMetrics
    var body: some View {
        HStack(alignment: .top, spacing: M.readySpacing) {
            // The package fits the 32 x 27 frame by its height [I].
            AirDropRing(progress: AirDropProgress(fraction: 1, itemCount: 1, isFinished: true), size: M.readyIconSize.height, expanded: true)
                .frame(width: M.readyIconSize.width, height: M.readyIconSize.height)
            AirDropDescription(title: title, titleFont: .headline.leading(.tight), subtitle: subtitle, subtitleFont: .body.leading(.tight), subtitleLineLimit: nil)
                .padding(M.readyTextPadding)
            AirDropOpenButton(title: M.openTitle(), action: onOpen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(M.readyPadding)
        .frame(width: M.expandedWidth)
        .environment(\.colorScheme, .dark)
    }
}

struct AirDropOpenButton: View {
    var title: String
    var action: () -> Void
    var body: some View { Button(title, action: action).buttonStyle(AirDropOpenButtonStyle()) }
}

/// DeviceDiscoveryUI AirDropUIButtonStyle(style: .jindoDefault, labelSizing: .hugging) on macOS (21.2.5), modifiers in
/// the 27.3 order: FontStyleModifier, LabelSizingModifier, BackgroundStyleModifier, foregroundColor, Capsule clip.
private struct AirDropOpenButtonStyle: ButtonStyle {
    private typealias M = AirDropMetrics
    func makeBody(configuration: Configuration) -> some View {
        let o = configuration.isPressed ? M.openButtonPressedOpacity : 1
        configuration.label
            .font(.body)
            .lineLimit(1)
            .minimumScaleFactor(M.openButtonMinScale)
            .padding(M.openButtonInsets)
            .background(Color(.sRGB, red: M.openButtonGray, green: M.openButtonGray, blue: M.openButtonGray).opacity(o))
            .foregroundColor(Color(.sRGB, red: 1, green: 1, blue: 1).opacity(o))
            .clipShape(Capsule(style: .continuous))
    }
}
