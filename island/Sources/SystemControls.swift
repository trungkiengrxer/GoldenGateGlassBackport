// Volume (CoreAudio, default output device, virtual main volume) and display brightness (DisplayServices, private,
// loaded with dlsym) for the draggable island slider.
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.ps

enum SystemControls {
    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc', AudioToolbox AudioServices.h).
    private static var volumeAddress = AudioObjectPropertyAddress(mSelector: 0x766d_7663, mScope: kAudioObjectPropertyScopeOutput,
                                                                  mElement: kAudioObjectPropertyElementMain)

    private static func outputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func volume() -> Double? {
        guard let d = outputDevice(), AudioObjectHasProperty(d, &volumeAddress) else { return nil }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(d, &volumeAddress, 0, nil, &size, &v) == noErr ? Double(v) : nil
    }

    static func setVolume(_ value: Double) {
        guard let d = outputDevice() else { return }
        var v = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(d, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setBrightnessFn = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    static func brightness(display: CGDirectDisplayID) -> Double? {
        var v = Float(0)
        guard let f = getBrightness, f(display, &v) == 0 else { return nil }
        return Double(v)
    }

    @discardableResult
    static func setBrightness(_ value: Double, display: CGDirectDisplayID) -> Bool {
        guard let f = setBrightnessFn else { return false }
        return f(display, Float(min(max(value, 0), 1))) == 0
    }
}

/// Internal battery (public IOPowerSources) and Low Power Mode, for the charging / low battery banners.
enum PowerSource {
    struct Reading { var level: Double; var isCharging: Bool; var source: String }

    /// nil on a machine without an internal battery.
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Double, let max = d[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            return Reading(level: min(current / max, 1), isCharging: isOnACPower(d),
                           source: d[kIOPSPowerSourceStateKey] as? String ?? kIOPSBatteryPowerValue)
        }
        return nil
    }

    /// RE-27-BEHAVIOR s19.2 (0x1000c9b70, 0x100571454): the charging banner follows Power Source State == "AC Power",
    /// not Is Charging (plugging in at 100% still shows it, "Fully Charged").
    // ponytail: [I] 27.3 also drops it while Smart Charging holds; not read on 26.6.
    static func isOnACPower(_ d: [String: Any]) -> Bool { d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue }

    private static var handler: (() -> Void)?

    /// Calls `change` on the main run loop after every power source change.
    static func observe(_ change: @escaping () -> Void) {
        handler = change
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in PowerSource.handler?() }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// RE-27-BEHAVIOR s19.2: the banner button sets the energy mode of the current power source. ControlCenter 26.6 makes
    /// the same call (0x10001cb65): IOPMSetEnergyModePreference(mode "Low Power" | "Automatic", source "Battery Power" | ...).
    @discardableResult
    static func setLowPowerMode(_ on: Bool) -> Bool {
        typealias Fn = @convention(c) (CFString, CFString) -> Int32
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMSetEnergyModePreference").map({ unsafeBitCast($0, to: Fn.self) })
        else { return false }
        return f((on ? "Low Power" : "Automatic") as CFString, (read()?.source ?? kIOPSBatteryPowerValue) as CFString) == 0
    }
}
