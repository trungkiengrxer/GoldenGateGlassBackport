// System activity views from 27.3: screen recording (screencaptureui ScreenRecording Live Activity), Voice Memos
// (VoiceMemos.app platter views) and the camera / microphone AV module (ControlCenter AudioVideoLAMinimalView).
// Values and addresses: docs/RE-27-BEHAVIOR.md section 22. [V] read from the binary, [I] inferred, [?] unknown.
import AppKit
import SwiftUI

// MARK: Screen recording (screencaptureui 27.3)

enum ScreenRecordingMetrics {
    static let dotSize: CGFloat = 11     // RecordingDot: frame(11, 11) + Color.red (0x10002c02c) [V]
    static let frameSize: CGFloat = 17   // CompactLeadingView / MinimalView frame(17, 17) (0x100028cbc, 0x1000280b8) [V]
    /// FlashingModifier (0x10002c0c0): opacity dimmed ? (intense ? 0.6 : 0.8) : 1 [V].
    static func flashOpacity(dimmed: Bool, intense: Bool) -> Double { dimmed ? (intense ? 0.6 : 0.8) : 1 }
    /// linear(duration: intense ? 0.5 : 0.75).repeatForever(autoreverses: true) (0x10002c22c) [V].
    static func flashDuration(intense: Bool) -> Double { intense ? 0.5 : 0.75 }

    // Expanded (ExpandedView body 0x10002b0f4, built in the IntegratedContentView expanded closure 0x100027e40).
    static let expandedMinSize = CGSize(width: 260, height: 60)   // containerSize = max(minimumSize, (260, 60)) [V]
    static let layoutMargin: CGFloat = 11                         // expanded HostedMetrics margins (section 2 table) [V field, I branch]
    static let labelLeading: CGFloat = 15 + layoutMargin          // .padding(.leading, 15 + margins.leading) 0x10002b4e4 [V]
    static let durationSpacing: CGFloat = 5                       // RecordingDurationView HStack spacing (0x10002d6dc) [V]
    static let stopRingSize: CGFloat = 40, stopRingLine: CGFloat = 2          // StopButton 0x10002cc30 / 0x10002cc14 [V]
    static let stopSquareSize: CGFloat = 17, stopSquareRadius: CGFloat = 4    // 0x10002d0b8 / 0x10002d098 [V]
    /// Font.system(size: NSFont.systemFontSize) (global 0x100025048); its capHeight and -descender feed the height [V].
    static var font: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    /// 0x10002a550: top of the label line, below the obstruction; nil without one [V].
    static func textTop(obstruction: CGFloat) -> CGFloat? {
        obstruction > 0 ? max(obstruction + 1.5, expandedMinSize.height / 2 + 5.5) : nil
    }
    /// 0x10002a5c0: max(container height, textTop + capHeight + descent + margins.bottom) [V].
    static func expandedHeight(obstruction: CGFloat, capHeight: CGFloat = font.capHeight, descent: CGFloat = -font.descender) -> CGFloat {
        guard let t = textTop(obstruction: obstruction) else { return expandedMinSize.height }
        return max(expandedMinSize.height, t + capHeight + descent + layoutMargin)
    }
    static func expandedSize(obstruction: CGFloat) -> CGSize {
        CGSize(width: expandedMinSize.width, height: expandedHeight(obstruction: obstruction))
    }
    /// The 40 pt ring, centred in the height x height frame at the trailing edge (0x10002b5a4); top-left origin [I hit
    /// area = the ring's square].
    static func stopButtonFrame(in size: CGSize) -> CGRect {
        let h = size.height, inset = (h - stopRingSize) / 2
        return CGRect(x: size.width - h + inset, y: inset, width: stopRingSize, height: stopRingSize)
    }
}

/// ExpandedView: HStack(.top) { duration + "Screen Recording" .font(13) .padding(.leading, 26), Spacer, StopButton
/// .frame(h, h) } .frame(width: 260, height: h, alignment: .top). With an obstruction the two lines sit in a
/// ZStack(.topLeading): the duration's first baseline at h / 2 (guide 0x10002acc8), the label's cap top at textTop
/// (guide 0x10002ae00) [V]. The island always reports its sensor as the obstruction [I], so the VStack branch is unused.
struct ScreenRecordingExpanded: View {
    var startDate: Date
    var obstructionHeight: CGFloat
    var stopPressed = false

    var body: some View {
        let m = ScreenRecordingMetrics.self
        let h = m.expandedHeight(obstruction: obstructionHeight), top = m.textTop(obstruction: obstructionHeight) ?? 0
        HStack(alignment: .top) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 0, height: 0)   // pins the guides' zero to the container top
                // RecordingDurationView (0x10002d5c0, 0x10002d664): HStack(.center, spacing: 5) { RecordingDot,
                // stopwatch(startingAt:, showsHours: true, maxFieldCount: 3, maxPrecision: .seconds(1)) weight medium
                // red } .modifier(FlashingModifier(intense: true)) [V].
                HStack(alignment: .center, spacing: m.durationSpacing) {
                    RecordingDot()
                    Text(.currentDate, format: .stopwatch(startingAt: startDate, showsHours: true, maxFieldCount: 3, maxPrecision: .seconds(1)))
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                }
                .modifier(RecordingFlashing(intense: true))
                .alignmentGuide(.top) { $0[.firstTextBaseline] - h / 2 }
                Text("Screen Recording")
                    .foregroundStyle(.white)   // [I] default primary on the dark island
                    .alignmentGuide(.top) { $0[.firstTextBaseline] - m.font.capHeight - top }
            }
            .frame(height: h, alignment: .topLeading)
            .font(.system(size: NSFont.systemFontSize))
            .padding(.leading, m.labelLeading)
            Spacer()
            ScreenRecordingStopButton(pressed: stopPressed)
                .frame(width: h, height: h)
        }
        .frame(width: m.expandedMinSize.width, height: h, alignment: .top)
    }
}

/// StopButton label (0x10002cb94): white ring Circle stroke 2 in 40 x 40 around a red RoundedRectangle 17 x 17 radius 4.
/// Once pressed the ring trims from 0.1 (easeIn 0.2) and spins, linear(1).repeatForever, rotation -2 pi [V values].
/// [I] Circle shape, continuous corners, autoreverses false. The action is wired by the host (hit-tested in Bootstrap).
struct ScreenRecordingStopButton: View {
    var pressed = false
    @State private var spin = false

    var body: some View {
        let m = ScreenRecordingMetrics.self
        ZStack {
            Circle()
                .trim(from: pressed ? 0.1 : 0, to: 1)
                .stroke(Color.white, style: StrokeStyle(lineWidth: m.stopRingLine))
                .rotationEffect(.radians(spin ? -2 * .pi : 0))
                .animation(.easeIn(duration: 0.2), value: pressed)
                .animation(spin ? .linear(duration: 1).repeatForever(autoreverses: false) : nil, value: spin)
            RoundedRectangle(cornerRadius: m.stopSquareRadius, style: .continuous)
                .fill(Color.red)
                .frame(width: m.stopSquareSize, height: m.stopSquareSize)
        }
        .frame(width: m.stopRingSize, height: m.stopRingSize)
        .onChange(of: pressed) { spin = pressed }
    }
}

/// RecordingDot with FlashingModifier, in the 17 x 17 compact leading / minimal frame. While recording the compact
/// trailing view is Color.clear with width 0 (0x100029f80) [V], so the island shows the dot alone.
/// `intense` false [?]: the caller's flag is not read yet.
struct ScreenRecordingDot: View {
    var animates = true

    var body: some View {
        RecordingDot()
            .modifier(RecordingFlashing(intense: false, animates: animates))
            .frame(width: ScreenRecordingMetrics.frameSize, height: ScreenRecordingMetrics.frameSize)
    }
}

/// RecordingDot: Circle().foregroundStyle(Color.red).frame(11, 11) (body type, 0x10002c02c) [V].
struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: ScreenRecordingMetrics.dotSize, height: ScreenRecordingMetrics.dotSize)
    }
}

/// FlashingModifier: opacity + animation(value: dimmed) + onAppear (body type, 0x10002c0c0) [V].
struct RecordingFlashing: ViewModifier {
    var intense: Bool
    var animates = true
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(ScreenRecordingMetrics.flashOpacity(dimmed: dimmed, intense: intense))
            .animation(.linear(duration: ScreenRecordingMetrics.flashDuration(intense: intense)).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { if animates { dimmed = true } }   // the modifier flips its LazyState once on appear [I]
    }
}

// MARK: Voice Memos (VoiceMemos.app 27.3, RCRecorderStyleProvider, isIOSMac branch)

enum VoiceMemosMetrics {
    static let compactSlices = 16, minimalSlices = 10   // platterCompactViewSliceCount / MinimalViewSliceCount [V]
    static let sliceWidth: CGFloat = 1.2                // platterWaveformSliceWidth (iOS 1.6) 0x10000ea20 [V]
    static let slicePadding: CGFloat = 1.0              // platterWaveformSlicePadding (iOS 1.2) 0x10000ea50 [V]
    static let compactHeightMultiplier: CGFloat = 0.53  // platterCompactLeadingViewHeightMultiplier 0x10000ebb0 [V]
    static let minimalSize = CGSize(width: 35, height: 15)   // platterMinimalViewWidth / MinimalWaveformViewHeight [V]
    static let activeRGB = (1.0, 0.349, 0.345)          // platterWaveformActiveSliceColor 0x10000eb5c [V]
    static let inactiveAlpha = 0.3                      // platterWaveformInactiveSliceColor white 1, alpha 0.3 [V]

    /// _platterWaveformWidthCompact: (0x10000eb14): n * width + n * padding [V].
    static func waveformWidth(slices n: Int) -> CGFloat { CGFloat(n) * sliceWidth + CGFloat(n) * slicePadding }
    /// Compact leading waveform height = sensor height x 0.53 [I: multiplier of the obstruction height].
    static func compactWaveformHeight(sensorHeight h: CGFloat) -> CGFloat { h * compactHeightMultiplier }
    /// _heightForAmplitude (0x100052038): min + level * (max - min), min = slice width (0x1000529f0), max = the view
    /// height (0x1000529f4) [V]; level 0...1 [I].
    static func sliceHeight(level: Double, maxHeight: CGFloat, scale: CGFloat = 1) -> CGFloat {
        let lo = sliceWidth * scale
        return lo + (maxHeight - lo) * CGFloat(min(max(level, 0), 1))
    }

    static let roundedSlicesShare: CGFloat = 0.3   // platterWaveformPercentageOfRoundedSlices 0x10000ea88 [V]
    static let minimumRoundedWidth: CGFloat = 5    // platterWaveformMinimumRoundedSliceWidthPerSide 0x10000ea94 [V]
    /// _maxHeightForSliceAtIndex (0x10005207c) for active slices: rounded frames of width max(5, n * (w + p) * 0.3 / 2)
    /// at both ends of the active frame (0x1000521f0, 0x100051e44); inside one the max height is x sqrt(1 - (1 - t)^2),
    /// t = distance from the outer edge / width [V]. Slice x = i * (w + p) [I: the time-window scroll offset is 0].
    static func edgeTaper(index i: Int, slices n: Int, scale: CGFloat = 1) -> CGFloat {
        let w = sliceWidth * scale, p = slicePadding * scale
        let active = CGFloat(n) * (w + p), r = max(minimumRoundedWidth, active * roundedSlicesShare / 2)
        let x = CGFloat(i) * (w + p), end = x + w
        let d: CGFloat
        if end <= r { d = x } else if x >= active - r { d = active - end } else { return 1 }
        let t = min(max(d / r, 0), 1)
        return (1 - (1 - t) * (1 - t)).squareRoot()
    }

    // Expanded (VoiceMemos.ExpandedView body 0x10013bf08)
    static let expandedSize = CGSize(width: 292, height: 86)   // bannerSize, isIOSMac branch (0x10000e7f8) [V]
    static let stopButtonSize: CGFloat = 44                     // platterStopButtonHeight, Mac (iOS 57) 0x10000e9cc [V]
    static let expandedSliceScale: CGFloat = 2.3                // platterWaveformSliceScaleFactorForExpandedMode [V]
    static let timeToStopSpacing: CGFloat = 8                   // RCPlatterTimeView _interitemSpacing (0x100092090) [V]
    /// platterCustomLeadingViewLeadingPadding = round((bannerSize.h - stopButtonHeight) / 2) (0x10000ebbc) [V].
    static var expandedPadding: CGFloat { ((expandedSize.height - stopButtonSize) / 2).rounded() }
    /// HStack default spacing between the waveform and the time view [I: platform default].
    static let expandedStackSpacing: CGFloat = 8
    /// The leading waveform representable's sizeThatFits (sub_100103240), expanded style: proposed width and 0.53 x the
    /// proposed height [V]. Both children are flexible, so each takes half of the content (equal split [I]).
    static var expandedWaveformWidth: CGFloat { (expandedSize.width - 2 * expandedPadding - expandedStackSpacing) / 2 }
    static var expandedWaveformHeight: CGFloat { expandedSize.height * compactHeightMultiplier }
    /// _activeSliceFrame (0x100051e44): n * w + n * p from the leading edge; its end is the playhead [V].
    static var expandedActiveWidth: CGFloat { CGFloat(compactSlices) * (sliceWidth + slicePadding) * expandedSliceScale }
    /// numberOfInactiveSlices (0x100052678): floor((bounds.w - active.maxX) / (w + p)) grey dots after the playhead [V].
    static var expandedInactiveSlices: Int {
        Int(((expandedWaveformWidth - expandedActiveWidth) / ((sliceWidth + slicePadding) * expandedSliceScale)).rounded(.down))
    }
    /// Stop button pinned to the trailing edge (inside the padding), centred vertically (0x1000916d8); top-left origin.
    static func stopButtonFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width - expandedPadding - stopButtonSize, y: (size.height - stopButtonSize) / 2,
               width: stopButtonSize, height: stopButtonSize)
    }
    /// PlatterStopButton.ca (identical on 26.6), state "zoom" for a recording time view (mica 1, 0x100091224): Oval 239
    /// line 16.6 scale 0.246, stop 25.35 x 25.17 radius 6.6 scale 1.149, colour (1, 0.3504, 0.3462), container x 1/3 [V].
    /// The 23 x 23 root layer fills the button: RCPlatterStopButton layoutSubviews (0x100030d50) sets the package view to
    /// platterStopButtonHeight square, BSUICAPackageView layoutSubviews (BaseBoardUI 0x1d7a03a24) scales the package by
    /// min(bounds / package size) about the centre [V]. Width used for both sides of the square (0.07 pt apart) [I].
    static let stopGlyphScale: CGFloat = stopButtonSize / 23
    static let stopRingDiameter: CGFloat = 239 * 0.246 / 3 * stopGlyphScale
    static let stopRingLine: CGFloat = 16.6 * 0.246 / 3 * stopGlyphScale
    static let stopSquareSize: CGFloat = 25.347625732422 * 1.149 / 3 * stopGlyphScale
    static let stopSquareRadius: CGFloat = 6.6 * 1.149 / 3 * stopGlyphScale
    static var stopColor: Color { Color(.sRGB, red: 1, green: 0.3504, blue: 0.3462) }
    /// platterTimeLabelCustomModeFont: monospaced digits, title3 size, medium (0x10000e8f8) [V]; 26.6 size [I].
    static var expandedTimeFont: Font {
        .system(size: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .medium).monospacedDigit()
    }
    /// RCPlatterTimeView text [? format]: m:ss, h:mm:ss past an hour.
    static func timeText(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    static var activeColor: Color { Color(.sRGB, red: activeRGB.0, green: activeRGB.1, blue: activeRGB.2) }
    /// platterTimeLabelCompactModeFont: monospacedDigitSystemFont(size: subheadline pointSize, weight: .medium) [V];
    /// subheadline size from the 26.6 text style [I].
    static var timeFont: Font {
        .system(size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium).monospacedDigit()
    }
}

/// RCPlatterWaveformView: slices of width 1.2 with padding 1.0, centred vertically; active slices red, inactive
/// white 0.3. Levels are 0...1, newest last; missing levels draw as inactive dots [I].
struct VoiceMemosWaveform: View {
    var levels: [Double]
    var slices: Int
    var height: CGFloat
    var scale: CGFloat = 1   // expanded style: slice width and padding x 2.3 (_sliceScale 0x100052dac) [V]
    var waiting = 0          // inactive slices after the playhead (expanded), minimum height, white 0.3 [V]

    var body: some View {
        let m = VoiceMemosMetrics.self
        HStack(spacing: m.slicePadding * scale) {
            ForEach(0..<(slices + waiting), id: \.self) { i in
                let k = i - (slices - levels.count), active = i < slices && k >= 0
                // heightForSlice (0x100051fd4): min(amplitude height, tapered max); inactive slices are not tapered [V]
                let h = active ? min(m.sliceHeight(level: levels[k], maxHeight: height, scale: scale),
                                     height * m.edgeTaper(index: i, slices: slices, scale: scale))
                               : m.sliceHeight(level: 0, maxHeight: height, scale: scale)
                Capsule()   // [I] rounded slice
                    .fill(active ? m.activeColor : Color.white.opacity(m.inactiveAlpha))
                    .frame(width: m.sliceWidth * scale, height: h)
            }
        }
        // compact / minimal: the style provider width n * (w + p); expanded: the caller's frame (sizeThatFits) [V]
        .frame(width: scale == 1 ? m.waveformWidth(slices: slices) : nil, height: height)
    }
}

/// Compact leading: RCPlatterLeadingWaveformView, 16 slices, height = sensor x 0.53 [V count, I height].
struct VoiceMemosCompactLeading: View {
    var levels: [Double]
    var sensorHeight: CGFloat
    var body: some View {
        VoiceMemosWaveform(levels: levels, slices: VoiceMemosMetrics.compactSlices,
                           height: VoiceMemosMetrics.compactWaveformHeight(sensorHeight: sensorHeight))
    }
}

/// Compact trailing: RCPlatterTimeView, red (platterDefaultTimeLabelColor = active slice colour, 0x10000e8f0) [V].
struct VoiceMemosCompactTrailing: View {
    var seconds: Int
    var body: some View {
        Text(VoiceMemosMetrics.timeText(seconds))
            .font(VoiceMemosMetrics.timeFont)
            .foregroundStyle(VoiceMemosMetrics.activeColor)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Minimal: RCPlatterMinimalWaveformView, 10 slices in 35 x 15 [V].
struct VoiceMemosMinimal: View {
    var levels: [Double]
    var body: some View {
        VoiceMemosWaveform(levels: levels, slices: VoiceMemosMetrics.minimalSlices, height: VoiceMemosMetrics.minimalSize.height)
            .frame(width: VoiceMemosMetrics.minimalSize.width, height: VoiceMemosMetrics.minimalSize.height)
    }
}

/// Expanded: HStack(.center) { leading waveform (expanded style: half the content, 121 x 45.58; 16 active slices up
/// to the playhead, then 7 grey dots), time view (flex width, .leading) } .padding(.horizontal, 21)
/// .frame(width: 292, height: 86) [V]. The time view pins the stop
/// button to its trailing edge and the label 8 before it (RCPlatterTimeView 0x1000916d8, state 1 shows both).
/// [I] width stays 292: the widening in 0x10013c9a8 only acts when the time label overlaps the obstruction band.
struct VoiceMemosExpanded: View {
    var levels: [Double]
    var seconds: Int

    var body: some View {
        let m = VoiceMemosMetrics.self
        HStack(alignment: .center, spacing: m.expandedStackSpacing) {
            VoiceMemosWaveform(levels: levels, slices: m.compactSlices, height: m.expandedWaveformHeight, scale: m.expandedSliceScale,
                               waiting: m.expandedInactiveSlices)
                .frame(width: m.expandedWaveformWidth, alignment: .leading)
            HStack(spacing: m.timeToStopSpacing) {
                Spacer(minLength: 0)
                Text(VoiceMemosMetrics.timeText(seconds))
                    .font(m.expandedTimeFont)
                    .foregroundStyle(m.activeColor)   // [I] state 1 uses platterDefaultTimeLabelColor, as compact
                    .lineLimit(1)
                    .fixedSize()
                VoiceMemosStopButton()
                    .frame(width: m.stopButtonSize, height: m.stopButtonSize)
            }
        }
        .padding(.horizontal, m.expandedPadding)
        .frame(width: m.expandedSize.width, height: m.expandedSize.height)
    }
}

/// PlatterStopButton.ca "zoom": white ring around the red rounded stop square, the 23 pt document scaled to the button.
/// The tap goes RCPlatterStopButton -> RCPlatterTimeView -> PlatterTimeViewDelegateAdapter.onDidTapStopRecording
/// (in-process in VoiceMemos 27.3); the host wires the 26.6 action.
struct VoiceMemosStopButton: View {
    var body: some View {
        let m = VoiceMemosMetrics.self
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: m.stopRingLine)
                .frame(width: m.stopRingDiameter, height: m.stopRingDiameter)
            RoundedRectangle(cornerRadius: m.stopSquareRadius, style: .continuous)   // cornerCurve continuous [V]
                .fill(m.stopColor)
                .frame(width: m.stopSquareSize, height: m.stopSquareSize)
        }
    }
}

// MARK: Camera / microphone AV module (ControlCenter 27.3)

/// AudioVideoLAActivityIcon cases used here (screen sharing and SharePlay need data the 26.6 hooks do not give).
enum AVActivityIcon: CaseIterable {
    case camera, mic

    /// Image(systemName:) globals (inits 0x1003b0ab0 "video.fill", 0x1003b0b54 "mic.fill") [V].
    var symbol: String { self == .camera ? "video.fill" : "mic.fill" }
    /// Color.green / Color.orange (inits 0x1003b0ae8, 0x1003b0b88) [V].
    var color: Color { self == .camera ? .green : .orange }
    /// AudioVideoLAModel.activityIcon: camera wins over mic [I order].
    static func current(camera: Bool, mic: Bool) -> AVActivityIcon? { camera ? .camera : (mic ? .mic : nil) }
    /// ForEach closure 0x1003a872c: opacity icon == activityIcon ? 1 : 0, the others accessibilityHidden [V].
    static func opacity(of icon: AVActivityIcon, current: AVActivityIcon) -> Double { icon == current ? 1 : 0 }
}

/// AudioVideoLAMinimalView (0x1003a85e8): ZStack(.center) of every icon, only the current one visible, padding 0
/// when integrated in the island (2 in the menu bar) [V]. No font modifier, so the host's default body font [I].
struct AVModuleMinimal: View {
    var current: AVActivityIcon
    var body: some View {
        ZStack {
            ForEach(AVActivityIcon.allCases, id: \.self) { icon in
                Image(systemName: icon.symbol)
                    .foregroundStyle(icon.color)
                    .opacity(AVActivityIcon.opacity(of: icon, current: current))
            }
        }
        .font(.body)
    }
}
