import Foundation
import Testing
@testable import Moe

/// Moe's own background jobs used to fail into a log and nowhere else.
/// `routine_health.record_own_jobs` keeps when each last ran and last worked;
/// this is the line Settings › Running in the background makes of it.
struct JobHealthTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    /// Thursday 12 November 2026, 14:00 UTC.
    static let now = at("2026-11-12T14:00:00Z")

    /// The file exactly as the Python writes it
    /// (`OwnJobHealthTest.test_the_last_success_survives_the_failures_after_it`).
    static let file = Data("""
    {"checked": "2026-11-12T14:00:00Z", "jobs": {
     "moe-learn-deep": {"enabled": true, "id": "bb22", "last_failure": "2026-11-12T08:00:00Z",
      "last_run": "2026-11-12T08:00:00Z", "last_status": "error",
      "last_success": "2026-11-10T08:00:00Z", "next_run": ""},
     "moe-proactive": {"enabled": true, "id": "aa11", "last_failure": "",
      "last_run": "2026-11-12T12:00:00Z", "last_status": "ok",
      "last_success": "2026-11-12T12:00:00Z", "next_run": "2026-11-12T14:00:00Z"}}}
    """.utf8)

    @Test func theFileThePluginWritesIsRead() throws {
        let snap = try #require(JobHealth.parse(Self.file))
        #expect(snap.checked == Self.now)
        #expect(snap.jobs.count == 2)
        let learn = try #require(snap.jobs["moe-learn-deep"])
        #expect(learn.lastSuccess == Self.at("2026-11-10T08:00:00Z"))
        #expect(learn.lastFailure == Self.at("2026-11-12T08:00:00Z"))
        #expect(learn.nextRun == nil, "an empty stamp is no date, not 1970")
    }

    @Test func aJobThatWorkedSaysWhenItLastRan() throws {
        let snap = try #require(JobHealth.parse(Self.file))
        #expect(JobHealth.line(snap.jobs["moe-proactive"]!, now: Self.now, calendar: Self.utc) == "Last ran 2 h ago.")
    }

    /// The case the feature exists for: failing since Tuesday, said so.
    @Test func aJobThatIsFailingSaysSinceWhen() throws {
        let snap = try #require(JobHealth.parse(Self.file))
        #expect(JobHealth.line(snap.jobs["moe-learn-deep"]!, now: Self.now, calendar: Self.utc)
                == "Has not worked since Tuesday.")
        let never = JobHealth.Entry(lastRun: Self.now, lastFailure: Self.now)
        #expect(JobHealth.line(never, now: Self.now, calendar: Self.utc) == "Has not worked yet.")
    }

    /// Not failing — just not running: well past the time it said it would.
    @Test func aJobThatStoppedRunningSaysSinceWhen() {
        var e = JobHealth.Entry(lastRun: Self.at("2026-11-09T09:00:00Z"),
                                lastSuccess: Self.at("2026-11-09T09:00:00Z"),
                                nextRun: Self.at("2026-11-09T09:30:00Z"))
        #expect(JobHealth.line(e, now: Self.now, calendar: Self.utc) == "Has not run since Monday.")
        // A tick that is merely late is not a stopped job.
        e.nextRun = Self.now.addingTimeInterval(-600)
        #expect(JobHealth.line(e, now: Self.now, calendar: Self.utc) == "Last ran 3 days ago.")
        // Older than a week is a date, not a weekday that could be last week's.
        e.lastRun = Self.at("2026-10-28T09:00:00Z")
        e.nextRun = Self.at("2026-10-28T09:30:00Z")
        #expect(JobHealth.line(e, now: Self.now, calendar: Self.utc) == "Has not run since 28 October.")
    }

    @Test func aJobThatRecoveredStopsSayingItIsBroken() {
        let e = JobHealth.Entry(lastRun: Self.at("2026-11-12T13:48:00Z"),
                                lastSuccess: Self.at("2026-11-12T13:48:00Z"),
                                lastFailure: Self.at("2026-11-11T13:00:00Z"))
        #expect(JobHealth.line(e, now: Self.now, calendar: Self.utc) == "Last ran 12 min ago.")
    }

    @Test func switchedOffOrNeverRunAddsNothing() {
        #expect(JobHealth.line(.init(enabled: false, lastFailure: Self.now), now: Self.now, calendar: Self.utc) == nil)
        #expect(JobHealth.line(.init(), now: Self.now, calendar: Self.utc) == nil)
    }

    /// The watcher is one of the watched. An hour with no look, and the pane
    /// says the times are old rather than letting "Last ran 2 h ago" stand
    /// for a week.
    @Test func aWatcherThatStoppedIsSaid() {
        var snap = JobHealth.Snapshot(checked: Self.now.addingTimeInterval(-300))
        #expect(JobHealth.staleLine(snap, now: Self.now, calendar: Self.utc) == nil)
        snap.checked = Self.at("2026-11-10T09:00:00Z")
        #expect(JobHealth.staleLine(snap, now: Self.now, calendar: Self.utc)
                == "Moe has not checked on these since Tuesday, so the times here may be older than they read.")
        #expect(JobHealth.staleLine(.init(), now: Self.now, calendar: Self.utc) == nil)
    }

    @Test func garbageIsNoSnapshotAndABadEntryCostsOnlyItself() throws {
        #expect(JobHealth.parse(Data("{ not json".utf8)) == nil)
        let snap = try #require(JobHealth.parse(Data(#"{"jobs": {"a": 3, "b": {"last_run": 7, "enabled": "yes"}}}"#.utf8)))
        #expect(snap.jobs["a"] == nil)
        #expect(snap.jobs["b"] == JobHealth.Entry())
    }
}
