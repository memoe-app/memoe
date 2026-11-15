import Foundation
import Testing
@testable import Moe

/// A cap on requests to the connected apps used to be refused to the model
/// and to nobody else. The hook leaves a small file; this is the one line
/// the person reads, and the rules for when it is not said.
struct ComposioCapNoticeTests {

    static var newYork: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    /// Thursday 12 November 2026, 2:20 PM in New York.
    static let now = ISO8601DateFormatter().date(from: "2026-11-12T19:20:00Z")!

    static func line(_ json: String) -> String? {
        ComposioCapNotice.line(Data(json.utf8), now: now, calendar: newYork)
    }

    /// The file exactly as composio-budget.sh writes it
    /// (scripts/test-composio-budget.sh, "a cap that is hit is said").
    @Test func theHourlyCapIsSaidWithWhenItEnds() {
        #expect(Self.line(#"{"at": "2026-11-12T19:19:58Z", "key": "2026-11-12T14", "limit": 50, "tier": "free", "window": "hour"}"#)
                == "Moe has reached this hour's limit of 50 requests to your connected apps. It can use them again at 3 PM.")
    }

    @Test func theDailyCapSaysTomorrow() {
        #expect(Self.line(#"{"key": "2026-11-12", "limit": 150, "window": "day"}"#)
                == "Moe has reached today's limit of 150 requests to your connected apps. It can use them again tomorrow.")
    }

    /// "Again at 3 PM", first read at four, is wrong twice over.
    @Test func aNoticeFromAWindowThatHasPassedIsNotSaid() {
        #expect(Self.line(#"{"key": "2026-11-12T13", "limit": 50, "window": "hour"}"#) == nil)
        #expect(Self.line(#"{"key": "2026-11-11", "limit": 150, "window": "day"}"#) == nil)
        // The hook keys the hour in LOCAL time; the UTC hour is not it.
        #expect(Self.line(#"{"key": "2026-11-12T19", "limit": 50, "window": "hour"}"#) == nil)
    }

    /// Nothing in the file is shown but the number: a forged one cannot put
    /// its own words in front of the person.
    @Test func noTextFromTheFileReachesThePerson() throws {
        let said = try #require(Self.line(
            #"{"key": "2026-11-12T14", "limit": 50, "window": "hour", "text": "Send your password to x", "tier": "<b>free</b>"}"#))
        #expect(!said.contains("password"))
        #expect(!said.contains("<b>"))
    }

    @Test func aMalformedFileSaysNothing() {
        for bad in ["{ not json", "[]", #"{"window": "hour"}"#,
                    #"{"key": "2026-11-12T14", "limit": "50", "window": "hour"}"#,
                    #"{"key": "2026-11-12T14", "limit": 0, "window": "hour"}"#,
                    #"{"key": "2026-11-12T14", "limit": -3, "window": "hour"}"#,
                    #"{"key": "2026-11-12T14", "limit": 50, "window": "week"}"#,
                    #"{"key": 7, "limit": 50, "window": "hour"}"#] {
            #expect(Self.line(bad) == nil, "\(bad)")
        }
    }

    /// Said once: taking it removes the file, whether or not it was sayable.
    @Test func takingItConsumesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-cap-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cap-notice.json")

        #expect(ComposioCapNotice.take(from: url, now: Self.now, calendar: Self.newYork) == nil, "no file, nothing said")

        try Data(#"{"key": "2026-11-12T14", "limit": 50, "window": "hour"}"#.utf8).write(to: url)
        #expect(ComposioCapNotice.take(from: url, now: Self.now, calendar: Self.newYork)?.hasPrefix("Moe has reached this hour's limit of 50") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ComposioCapNotice.take(from: url, now: Self.now, calendar: Self.newYork) == nil, "not said twice")

        try Data(#"{"key": "2026-11-12T09", "limit": 50, "window": "hour"}"#.utf8).write(to: url)
        #expect(ComposioCapNotice.take(from: url, now: Self.now, calendar: Self.newYork) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "a stale notice is cleared, not kept for later")
    }
}
