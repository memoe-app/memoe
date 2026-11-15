import Foundation

/// When each of Moe's own background jobs last ran, last worked and last
/// failed — the quiet line under its name in Settings › Running in the
/// background.
///
/// The file is `proactive/job-health.json`, kept every five minutes by
/// `moe-screen/routine_health.py` (`record_own_jobs`). Hermes's own record
/// has only the last run's status, so "when did this last work" is gone at
/// the first failure; the file carries it forward.
///
/// Until 2026-11-12 a failure of one of these was dropped and logged, and
/// that was all: the proactive pass, the learning pass or the calendar
/// heads-up could be dead for weeks with nothing a person looks at saying
/// so. It is still not an inbox card — a card needs a one-tap answer
/// (docs/INBOX-QUIET.md) and "your learning pass is failing" has none — so
/// it is a line here, where someone wondering why Moe went quiet will look.
enum JobHealth {
    struct Entry: Equatable {
        var enabled = true
        var lastRun: Date?
        var lastSuccess: Date?
        var lastFailure: Date?
        var nextRun: Date?
    }

    struct Snapshot: Equatable {
        /// When the watcher last looked. The watcher is itself one of the
        /// jobs, so a stale stamp is how its own death shows.
        var checked: Date?
        var jobs: [String: Entry] = [:]
    }

    static var url: URL { Paths.home.appendingPathComponent("proactive/job-health.json") }

    /// Nil when there is no file yet (a new install, before the first look).
    static func read(from url: URL = JobHealth.url) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Every key optional, every type checked: one malformed entry costs
    /// that entry's line and nothing else.
    static func parse(_ data: Data) -> Snapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var snap = Snapshot(checked: date(obj["checked"]))
        for (name, raw) in obj["jobs"] as? [String: Any] ?? [:] {
            guard let j = raw as? [String: Any] else { continue }
            snap.jobs[name] = Entry(enabled: j["enabled"] as? Bool ?? true,
                                    lastRun: date(j["last_run"]),
                                    lastSuccess: date(j["last_success"]),
                                    lastFailure: date(j["last_failure"]),
                                    nextRun: date(j["next_run"]))
        }
        return snap
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// A run this late past its own next-run time is not just a slow tick.
    static let overdueAfter: TimeInterval = 3600
    /// The watcher runs every five minutes; an hour without a look means it
    /// has stopped, and every line it wrote is older than it reads.
    static let staleAfter: TimeInterval = 3600

    /// The one line for a job, or nil when there is nothing true to add
    /// (switched off — the row already says so).
    ///
    /// - last run failed → "Has not worked since Tuesday."
    /// - enabled, and well past the time it said it would next run →
    ///   "Has not run since Tuesday."
    /// - otherwise → "Last ran 2 h ago."
    static func line(_ e: Entry, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard e.enabled else { return nil }
        if let failed = e.lastFailure, failed >= (e.lastSuccess ?? .distantPast) {
            guard let worked = e.lastSuccess else { return "Has not worked yet." }
            return "Has not worked since \(since(worked, now: now, calendar: calendar))."
        }
        if let due = e.nextRun, now.timeIntervalSince(due) > overdueAfter {
            guard let ran = e.lastRun else { return "Has not run yet." }
            return "Has not run since \(since(ran, now: now, calendar: calendar))."
        }
        guard let ran = e.lastRun else { return nil }
        return "Last ran \(ago(ran, now: now))."
    }

    /// The line for the whole list when the watcher itself has stopped.
    static func staleLine(_ snap: Snapshot, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let checked = snap.checked, now.timeIntervalSince(checked) > staleAfter else { return nil }
        return "Moe has not checked on these since \(since(checked, now: now, calendar: calendar)), "
            + "so the times here may be older than they read."
    }

    /// "just now" / "12 min ago" / "2 h ago" / "3 days ago".
    static func ago(_ then: Date, now: Date) -> String {
        let secs = max(0, now.timeIntervalSince(then))
        let mins = Int(secs / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins) min ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// "9:40 this morning" style is more than this needs: today is a clock
    /// time, the last six days are a weekday, anything older is a date.
    static func since(_ then: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDate(then, inSameDayAs: now) {
            f.dateFormat = "h:mm a"
            return f.string(from: then) + " today"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: then),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "yesterday" }
        f.dateFormat = days < 7 ? "EEEE" : "d MMMM"
        return f.string(from: then)
    }
}
