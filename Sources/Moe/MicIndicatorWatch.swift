import Combine
import CoreAudio
import Foundation

/// Whether any app on this Mac has a microphone open — which is when macOS
/// draws its own indicator beside a floating camera capsule
/// (`NotchGeometry.SystemIndicator`), over the island.
///
/// Asked of CoreAudio the way `CameraProbe` asks CoreMediaIO: each input
/// device's `kAudioDevicePropertyDeviceIsRunningSomewhere`. It opens no
/// device and needs no microphone permission. Polled twice a second rather
/// than listened for, because the set of devices changes (AirPods, a
/// display's microphone) and a listener is per device.
///
/// `open` stays true for `linger` after the last device closes: the
/// system's indicator outlives the microphone by a few seconds, and an
/// island that slid back under it early would be hidden by it again.
///
/// Only ever started on a Mac with a capsule (`NotchIsland.indicatorLive`).
final class MicIndicatorWatch: ObservableObject {
    static let shared = MicIndicatorWatch()

    @Published private(set) var open: Bool

    /// How long after the microphone closes the indicator is still assumed
    /// to be on screen. Not measured: generous on purpose.
    static let linger: TimeInterval = 10

    private var lastOpen: Date?
    private var timer: Timer?

    private init() {
        let now = Self.anyInputRunning()
        open = now
        lastOpen = now ? Date() : nil
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let now = Date()
        if Self.anyInputRunning() { lastOpen = now }
        let value = Self.holds(lastOpen: lastOpen, now: now)
        if value != open { open = value }
    }

    /// The rule, apart from the clock and the hardware.
    static func holds(lastOpen: Date?, now: Date) -> Bool {
        guard let lastOpen else { return false }
        return now.timeIntervalSince(lastOpen) <= linger
    }

    static func anyInputRunning() -> Bool {
        for device in devices() where hasInput(device) && isRunningSomewhere(device) { return true }
        return false
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
