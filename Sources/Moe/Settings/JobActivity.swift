import Foundation

/// What each background job has been doing, and what it has cost.
///
/// The numbers come from `hermes-jobs/job-activity.py`, which reads
/// Hermes's own run ledger and usage table. The app does not touch those
/// databases itself: the shapes are Hermes's, they have moved once
/// already, and one of the two cost paths is easy to report dishonestly.
///
/// The honest split, which the script decides and this only renders: a
/// subscription records no money at all, so tokens are the only true
/// number and `label` says "included in your plan". An API key is priced
/// from a snapshot of published rates and never from an invoice, so its
/// figure says "estimated". Show `label`, never a bare amount.
enum JobActivity {
    /// **Every type here reads its keys through `decodeIfPresent`, and none of
    /// them may go back to the synthesised `init(from:)`.**
    ///
    /// Swift's synthesised `Decodable` does NOT fall back to a property's
    /// default when a key is missing — it throws `keyNotFound`, and the throw
    /// takes the whole value with it. Verified with a standalone program
    /// rather than from memory, after it silently turned every successful
    /// listing in the Reminders pane into "Moe couldn't reach the part of
    /// itself…".
    ///
    /// Here the failure would be quieter still: one missing key anywhere in
    /// `job-activity.py`'s output throws the WHOLE array, `activity` becomes
    /// empty, and every row on the Reminders screen loses its outcome and its
    /// cost line — with no error shown anywhere, because an empty result is
    /// indistinguishable from a Mac with no jobs. Silent, and in the direction
    /// that hides trouble.
    struct Cost: Decodable, Equatable {
        var tokensIn = 0
        var tokensOut = 0
        var calls = 0
        var amount = 0.0
        /// estimated | included | none | elsewhere | unpriced
        var basis = "none"
        var label = ""
        var models: [String] = []

        enum CodingKeys: String, CodingKey {
            case tokensIn = "tokens_in", tokensOut = "tokens_out"
            case calls, amount, basis, label, models
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
            tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
            calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
            amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
            basis = try c.decodeIfPresent(String.self, forKey: .basis) ?? "none"
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        }

        /// "$0.0047, estimated" / "Included in your plan" — the figure and
        /// what kind of figure it is, never one without the other.
        var summary: String {
            switch basis {
            case "estimated":
                return amount < 0.01 && amount > 0
                    ? "under a penny, estimated"
                    : String(format: "$%.2f, estimated", amount)
            case "included": return "included in your plan"
            case "elsewhere": return "counted elsewhere"
            case "unpriced": return "no price recorded"
            default: return "nothing charged"
            }
        }

        var tokens: String {
            let total = tokensIn + tokensOut
            if total == 0 { return "no thinking" }
            if total < 1000 { return "\(total) tokens" }
            return String(format: "%.0fk tokens", Double(total) / 1000)
        }
    }

    struct Job: Decodable, Identifiable, Equatable {
        var name = ""
        var id = ""
        var enabled = true
        var schedule: String?
        var monitor = false
        var lastRun: String?
        var nextRun: String?
        /// ok | quiet | failed | interrupted | paused | never
        var outcome = "never"
        var runs = 0
        var failures = 0
        var error = ""
        var windowDays = 7
        var cost = Cost()

        enum CodingKeys: String, CodingKey {
            case name, id, enabled, schedule, monitor, outcome, runs, failures, error, cost
            case lastRun = "last_run", nextRun = "next_run", windowDays = "window_days"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            schedule = try c.decodeIfPresent(String.self, forKey: .schedule)
            monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? false
            lastRun = try c.decodeIfPresent(String.self, forKey: .lastRun)
            nextRun = try c.decodeIfPresent(String.self, forKey: .nextRun)
            outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? "never"
            runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
            failures = try c.decodeIfPresent(Int.self, forKey: .failures) ?? 0
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 7
            cost = try c.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        }

        /// What Moe calls this job to a person. The job names are ours and
        /// mean nothing to anyone else.
        var title: String { JobActivity.title(for: name) }

        /// The one line under the title. `quiet` is the word that stops a
        /// healthy monitor job reading as broken: it looked, nothing had
        /// changed, nothing was spent.
        var state: String {
            switch outcome {
            case "ok": return "Ran, and had something to do."
            case "quiet": return "Looked, and there was nothing new to say."
            // Never `error` — that is Hermes's own string, and it is an
            // exit code, a stderr tail or a Python traceback every time.
            // This pane is the one place a job that needs a look says so,
            // so it has to say it in words: the raw text is in
            // ~/.moe/logs/job-failures.log for whoever is debugging it.
            case "failed": return "The last run didn't finish. Moe will try again on its next turn."
            case "interrupted": return "A run was cut short, usually because Moe restarted."
            case "paused": return "Switched off."
            default: return "Has not run yet."
            }
        }

        var isTrouble: Bool { outcome == "failed" }
    }

    /// The name of one of Moe's own jobs, said to a person. Lifted off
    /// `Job` so the Reminders pane can name the same job the same way
    /// without holding a `Job` to ask: it reads the schedule store rather
    /// than the run ledger, and two screens naming one job two ways is
    /// worse than either name.
    static func title(for name: String) -> String {
        switch name {
        case "moe-proactive": return "Speaking up"
        case "moe-learn-deep": return "Learning about you"
        case "moe-drain-intents": return "Work handed back from Moe Away"
        case "moe-calendar-heads-up": return "Calendar heads-up"
        case "moe-loop-check": return "Checking the pages you asked Moe to watch"
        case "moe-channel-holder": return "Keeping your chat apps connected"
        case "moe-situations": return "Noticing what you might want help with"
        case "moe-memory-tidy": return "Tidying your memory overnight"
        case "moe-weekly-digest": return "What I learned about you this week"
        default:
            if name.hasPrefix("moe-watch-") {
                return "Watching " + name.dropFirst("moe-watch-".count)
            }
            return name
        }
    }

    /// `hermes-jobs/job-activity.py` — installed beside the other job
    /// scripts, with the checkout as the fallback so a developer's build
    /// shows the same thing.
    static func scriptPath() -> String? {
        var candidates = [Paths.home.appendingPathComponent("hermes-jobs/job-activity.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes-jobs/job-activity.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes-jobs/job-activity.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Every job, newest window first. Nil when the script is missing or
    /// unreadable — which the pane says plainly rather than showing zeros,
    /// because "nothing has run" and "I could not look" are different
    /// answers and only one of them is alarming. Blocking; call off the
    /// main thread.
    static func all(days: Int = 7) -> [Job]? {
        guard let script = scriptPath() else { return nil }
        let r = ScriptRunner.run(BrainSetup.python(), [script, "--days", String(days)], timeout: 20)
        guard r.status == 0, let data = jsonPart(r.output) else { return nil }
        return try? JSONDecoder().decode([Job].self, from: data)
    }

    /// stderr is merged into stdout by ScriptRunner, so take the JSON from
    /// the first bracket that starts a line.
    private static func jsonPart(_ text: String) -> Data? {
        guard let start = text.range(of: "\n[")?.lowerBound
                ?? (text.hasPrefix("[") ? text.startIndex : nil) else { return nil }
        return Data(text[start...].utf8)
    }
}
