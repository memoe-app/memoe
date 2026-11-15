import Foundation

/// Bringing the microphone back after the graph went down under it.
///
/// It used to be one try: wait 300 ms after the device changed, call
/// `start()`, and on a throw show one error and stay deaf until the app was
/// restarted. A device that is still settling — AirPods mid-handshake, a
/// display's audio coming up after wake — refuses that one try and is
/// perfectly usable a second later.
///
/// So: a few tries with growing waits (`backoff`, 7.3 s in all), then once
/// more **without voice processing** — a plain microphone is better than a
/// dead one, which is what the call-app restart already does — and only when
/// that fails too is anything said to the person. One error, not five.
///
/// Bounded on purpose: this never loops. A later configuration change starts
/// a fresh run; nothing else does.
///
/// Pure of audio: the caller hands in how to wait, how to start and whether
/// the microphone is still wanted, so the whole ladder is tested without a
/// device.
public enum CaptureRecovery {

    /// The wait before each attempt with voice processing as wanted.
    public static let backoff: [Double] = [0.3, 1, 2, 4]

    public enum Outcome: Equatable, Sendable {
        /// The graph is up. `plain`: it took giving up voice processing.
        case restarted(plain: Bool, attempts: Int)
        /// Nobody wants the microphone any more, or something else brought
        /// it up (or superseded this run) while it waited.
        case abandoned
        /// Every attempt failed, the plain one included. The last error.
        case failed(String)
    }

    /// Run the ladder.
    /// - Parameters:
    ///   - delays: the wait before each ordinary attempt.
    ///   - sleep: wait this many seconds.
    ///   - stillWanted: asked after every wait; false ends the run quietly.
    ///   - start: bring the graph up; `plain` means without voice processing.
    ///   - log: one line per failed attempt.
    @MainActor
    public static func run(delays: [Double] = backoff,
                           sleep: (Double) async -> Void,
                           stillWanted: () -> Bool,
                           start: (_ plain: Bool) throws -> Void,
                           log: (String) -> Void = { _ in }) async -> Outcome {
        var attempts = 0
        for delay in delays {
            await sleep(delay)
            guard stillWanted() else { return .abandoned }
            attempts += 1
            do {
                try start(false)
                return .restarted(plain: false, attempts: attempts)
            } catch {
                log("microphone restart \(attempts) of \(delays.count) failed: \(error.localizedDescription)")
            }
        }
        guard stillWanted() else { return .abandoned }
        attempts += 1
        do {
            try start(true)
            return .restarted(plain: true, attempts: attempts)
        } catch {
            log("microphone restart without voice processing failed too: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}
