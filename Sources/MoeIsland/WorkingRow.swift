import Foundation

/// The island while Moe works: one row, not a conversation.
///
/// Decided 2026-09-19 from three drawn options. Hovering the notch mid-job
/// used to show the whole panel — the question, the half-written reply, the
/// raw step under it and a field to type into — which is a lot to read for
/// "is it still going, and how do I stop it". While a job runs the panel is
/// now a single line: what Moe is doing, how long it has been at it, the
/// quiet switch and Stop. The conversation comes back when the answer does,
/// with what Moe did folded under it.
///
/// The rules live here, in a library target, so they can be tested without
/// AppKit, and so the view and the height arithmetic read the same answer.
public enum WorkingRow {

    /// Whether the open panel is the working row rather than the conversation.
    ///
    /// `thinking` is the stretch before the first word; `acting` is the rest
    /// of the job, from the first tool step to the end of the turn. Dictation
    /// and a meeting each have a panel of their own and are never this one.
    public static func shows(thinking: Bool, acting: Bool,
                             dictating: Bool, meetingOn: Bool) -> Bool {
        guard !dictating, !meetingOn else { return false }
        return thinking || acting
    }

    /// The words on the row. The spoken phrase for the step when there is
    /// one ("Searching your files"), else Hermes's own preview of the step
    /// with its first letter raised, else the fallback. Never empty.
    public static func label(step: String?, fallback: String = "Thinking") -> String {
        guard let step = step?.trimmingCharacters(in: .whitespacesAndNewlines),
              !step.isEmpty else { return fallback }
        return step.prefix(1).uppercased() + step.dropFirst()
    }

    /// The one line the notch card gives the thinking inside the opened
    /// steps: its first words, after a label.
    public static func thinkingLine(_ thinking: String) -> String? {
        let words = thinking.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return "Thinking: " + words
    }

    /// "0:42", "12:03" — a clock, not a duration in words, because it is
    /// glanced at rather than read.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "3 steps · 48 s" under an answer, or nil when there is nothing to fold.
    /// `thought`: the provider streamed its thinking, which folds in here
    /// too (the owner's answer 10) — "Thought it through" when there were
    /// no steps besides.
    public static func summary(steps: Int, took: TimeInterval?, thought: Bool = false) -> String? {
        guard steps > 0 || thought else { return nil }
        let count = steps == 0 ? "Thought it through" : steps == 1 ? "1 step" : "\(steps) steps"
        guard let took, took >= 1 else { return count }
        return "\(count) · \(Int(took.rounded())) s"
    }

    /// The row's drawn height, read off `IslandView.workingBody`.
    public static let height = 26.0
    /// Padding above and below it — 14 over, 12 under, tighter than the
    /// conversation's because there is one line to clear the shoulders.
    public static let padding = 26.0
}
