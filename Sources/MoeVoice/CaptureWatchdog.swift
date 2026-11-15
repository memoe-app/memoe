import Foundation

/// A graph that says it is running and delivers nothing.
///
/// Nothing used to notice. The engine reports `isRunning`, the tap is
/// installed, and no buffer arrives — after a sleep, after another app
/// reconfigured the device without a notification reaching us, after the
/// voice-processing unit wedged. Moe looked alive and was deaf until the app
/// was restarted.
///
/// The render thread does no bookkeeping beyond bumping one atomic counter
/// per buffer (`SampleRing.deliveries`). A timer on the main actor reads the
/// counter about once a second and asks this. A microphone at 48 kHz with
/// 1024-frame buffers delivers ~47 a second, so a counter that has not moved
/// in `silenceSeconds` is not a slow stream — it is no stream.
///
/// Bounded: `maxRestarts` restarts for one quiet spell, each a full
/// `startGraceSeconds` after the last, then one `giveUp` and nothing more until
/// buffers arrive again (or the caller starts over with a fresh value, as it
/// does on a configuration change). Never while Moe is speaking: a restart
/// stops the player, and the reply in flight is worth more than two seconds
/// of hearing.
///
/// Pure: counts and a clock in, a verdict out.
public struct CaptureWatchdog: Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Buffers arrived since the last look.
        case healthy
        /// None yet, but not for long enough to act — or nothing to do.
        case waiting
        /// Restart the graph. `attempt` counts from 1 within this quiet spell.
        case restart(attempt: Int)
        /// Restarting did not help. Said once per quiet spell.
        case giveUp
    }

    /// No buffers for this long, on a graph that is wanted and "running".
    public var silenceSeconds: Double = 2
    /// …and this long for a graph that has only just come up: a Bluetooth
    /// microphone switching profiles takes a moment to send its first
    /// buffer, and restarting it for that would only start the wait again.
    public var startGraceSeconds: Double = 5
    /// Restarts before giving up on one quiet spell.
    public var maxRestarts = 3

    private var lastDelivered: Int?
    private var quietSince: Double = 0
    private var window: Double = 5
    public private(set) var restarts = 0
    private var gaveUp = false

    public init() {}

    /// The graph has just come up (first start, or a restart — ours or
    /// anyone's): the quiet clock starts from now. The restart count is
    /// kept; only buffers arriving clear it.
    public mutating func graphStarted(delivered: Int, now: Double) {
        lastDelivered = delivered
        quietSince = now
        window = max(startGraceSeconds, silenceSeconds)
    }

    /// One look.
    /// - Parameters:
    ///   - delivered: buffers delivered so far (any monotonic counter).
    ///   - speaking: whether Moe has audio queued or playing.
    ///   - now: seconds, any monotonic origin.
    public mutating func observe(delivered: Int, speaking: Bool, now: Double) -> Verdict {
        guard let last = lastDelivered else {
            graphStarted(delivered: delivered, now: now)
            return .waiting
        }
        if delivered != last {
            lastDelivered = delivered
            quietSince = now
            window = silenceSeconds
            restarts = 0
            gaveUp = false
            return .healthy
        }
        guard now - quietSince >= window, !gaveUp else { return .waiting }
        guard restarts < maxRestarts else {
            gaveUp = true
            return .giveUp
        }
        guard !speaking else { return .waiting }
        restarts += 1
        quietSince = now
        window = max(startGraceSeconds, silenceSeconds)
        return .restart(attempt: restarts)
    }
}
