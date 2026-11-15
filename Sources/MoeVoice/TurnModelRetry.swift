import Foundation

/// The turn model did not load. Try again later instead of giving up.
///
/// It used to be one attempt at the first voice start: Hugging Face slow, a
/// captive portal, a laptop opened on a train — and that session ended every
/// turn on the 1.5 s silence timer with one line in the log to show for it,
/// until the app happened to be restarted somewhere with a network.
///
/// The waits grow and then hold at half an hour: nothing here is urgent (the
/// silence timer still ends turns), and a Mac that is offline all day should
/// not spend it knocking.
public enum TurnModelRetry {

    /// The wait after the first, second, third failure; the last one repeats.
    public static let delays: [Double] = [30, 120, 600, 1800]

    public static func delay(afterFailures failures: Int) -> Double {
        delays[min(max(failures, 1), delays.count) - 1]
    }

    /// Load, and keep trying until it does.
    /// - Parameters:
    ///   - load: one attempt.
    ///   - sleep: wait this many seconds; false when the wait was cancelled.
    ///   - onFailure: after each failed attempt — how many so far, why, and
    ///     how long until the next.
    /// - Returns: how many attempts it took, or nil when cancelled.
    public static func run(load: @Sendable () async throws -> Void,
                           sleep: @Sendable (Double) async -> Bool,
                           onFailure: @Sendable (_ failures: Int, _ error: Error, _ retryIn: Double) -> Void) async -> Int? {
        var failures = 0
        while true {
            do {
                try await load()
                return failures + 1
            } catch {
                failures += 1
                let wait = delay(afterFailures: failures)
                onFailure(failures, error, wait)
                guard await sleep(wait) else { return nil }
            }
        }
    }
}
