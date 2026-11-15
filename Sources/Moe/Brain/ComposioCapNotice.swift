import Foundation

/// The one plain line a person sees when Moe has used up its allowance of
/// requests to their connected apps.
///
/// The allowance is enforced by `moe-home/hermes/hooks/composio-budget.sh`,
/// inside a tool call, and until 2026-11-12 its refusal reached only the
/// model — which said whatever it made of it, or carried on as though the
/// service were broken. The hook now leaves `composio/cap-notice.json` the
/// first time a cap is hit in a window, and the brain reads it when a turn
/// ends and says it once, as a notice in the conversation. Not an inbox card:
/// it is Moe talking about Moe, and there is nothing to tap.
///
/// **The file carries numbers and keys, never a sentence, and the words are
/// written here.** Anything that can run a tool can write a file in Moe's
/// home; if this showed text from one, that would be a way to put arbitrary
/// words in front of the person in Moe's voice. A forged file can at most
/// make Moe say this sentence, with a number in it, once an hour.
enum ComposioCapNotice {
    static var url: URL { Paths.home.appendingPathComponent("composio/cap-notice.json") }

    /// The line to say now, if a cap was hit in the window that is still
    /// running. Consumes the file either way: a notice is said once, and one
    /// from an hour that has passed ("again at 3 PM", read at 4) is dropped.
    static func take(from url: URL = ComposioCapNotice.url, now: Date = Date(),
                     calendar: Calendar = .current) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return line(data, now: now, calendar: calendar)
    }

    static func line(_ data: Data, now: Date, calendar: Calendar) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let window = obj["window"] as? String,
              let key = obj["key"] as? String,
              let limit = obj["limit"] as? Int, (1...1_000_000).contains(limit)
        else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        switch window {
        case "hour":
            // The hook's own key for the hour, in local time.
            f.dateFormat = "yyyy-MM-dd'T'HH"
            guard f.string(from: now) == key,
                  let next = calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0),
                                               matchingPolicy: .nextTime)
            else { return nil }
            f.dateFormat = "h a"
            return "Moe has reached this hour's limit of \(limit) requests to your connected apps. "
                + "It can use them again at \(f.string(from: next))."
        case "day":
            f.dateFormat = "yyyy-MM-dd"
            guard f.string(from: now) == key else { return nil }
            return "Moe has reached today's limit of \(limit) requests to your connected apps. "
                + "It can use them again tomorrow."
        default:
            return nil
        }
    }
}
