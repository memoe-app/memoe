import Foundation

/// The rate and channel count of one side of the microphone path.
public struct AudioShape: Equatable, Sendable, CustomStringConvertible {
    public var sampleRate: Double
    public var channels: Int
    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
    public var description: String { "\(channels) ch, \(Int(sampleRate)) Hz" }
}

/// When the audio graph needs a **new** `AVAudioEngine`, not another try on
/// the one it has.
///
/// Measured on the owner's Mac (macOS 27.2), 2026-11-13 15:30Z: Chrome took
/// the microphone for a Meet, the graph was restarted to turn voice
/// processing off so the call could hear him, and the engine's input node
/// never recovered. Turning voice processing off *in place* left its output
/// hardware format invalid (`-10875 IsFormatSampleRateAndChannelCountValid
/// (outputHWFormat)`) and its input node reading **2 ch, 44100 Hz** — a
/// format no device on the Mac had: the MacBook Pro Microphone, the default
/// input, was 1 ch, 48000 Hz (and so was the iPhone's). Every later
/// `installTap` raised "Failed to create tap due to format mismatch" with
/// that 2 ch / 44.1 kHz format: four ordinary retries, the plain retry, and
/// every hold press for the next hour and a quarter — 27 lines that day —
/// because every one of them was another try on the same engine, and the
/// engine lived as long as the app. On macOS 26 the same in-place switch
/// had come up at 1 ch, 48000 Hz sixteen times in October.
///
/// So a fresh engine is built — which starts with voice processing off, so
/// "off" never has to be switched — when:
///
/// - the last start on this engine failed: whatever it threw, the next try
///   must not inherit it;
/// - voice processing is on in the engine and is not wanted now (a call app
///   has the microphone, or the device refused it);
/// - with voice processing off, the input node's format is not the default
///   input device's (`isStale`). With it on, the node's channel count is the
///   canceller's (3, 7, 9 seen here) and says nothing about staleness.
public enum MicEngineRenewal {

    public enum Reason: Equatable, Sendable, CustomStringConvertible {
        case lastStartFailed
        case voiceProcessingOff
        case staleFormat(node: AudioShape, device: AudioShape)

        public var description: String {
            switch self {
            case .lastStartFailed: return "the last start on this engine failed"
            case .voiceProcessingOff: return "voice processing goes off, which this engine cannot do in place"
            case .staleFormat(let node, let device): return "its input reads \(node), the microphone is \(device)"
            }
        }
    }

    /// Before anything is set on the engine.
    public static func before(lastStartFailed: Bool,
                              voiceProcessingOnEngine: Bool,
                              voiceProcessingWanted: Bool) -> Reason? {
        if lastStartFailed { return .lastStartFailed }
        if voiceProcessingOnEngine && !voiceProcessingWanted { return .voiceProcessingOff }
        return nil
    }

    /// After voice processing is settled, with the input node's format read
    /// back. `device` nil (unknown) is never called stale: an unread device
    /// must not cost a rebuild on every start.
    public static func after(node: AudioShape, device: AudioShape?, voiceProcessing: Bool) -> Reason? {
        guard let device, isStale(node: node, device: device, voiceProcessing: voiceProcessing) else { return nil }
        return .staleFormat(node: node, device: device)
    }

    public static func isStale(node: AudioShape, device: AudioShape, voiceProcessing: Bool) -> Bool {
        guard !voiceProcessing, device.sampleRate > 0, device.channels > 0 else { return false }
        return node.sampleRate != device.sampleRate || node.channels != device.channels
    }
}

/// What the voice status in the sidebar says. It reads the microphone as
/// well as the models: "Voice ready" stood under a microphone that had been
/// dead for an hour and a quarter on 2026-11-13, because the dot was set
/// once, when the models finished loading, and never looked again.
public enum VoiceStatus {
    public static func sidebar(modelsReady: Bool, microphoneDead: Bool) -> (ok: Bool, text: String) {
        if microphoneDead { return (false, "Microphone not working") }
        return modelsReady ? (true, "Voice ready") : (false, "Voice loading…")
    }
}
