import Darwin
import Foundation

/// Every confirmation card is bound to whoever asked for it.
///
/// On 2026-09-25 a scheduled job asked to send a WhatsApp message. The card
/// went up; the job's watchdog killed the job ten minutes later; the
/// connector's subprocess timeout killed only `whatsapp.sh`; and the card,
/// which had no idea any of that had happened, sat in front of the owner's
/// chat for ninety minutes asking about a send that nothing was waiting for
/// any more. A Send on it would have been answered to nobody.
///
/// So a card now knows three things about its own life, and leaves on any of
/// them with `exitWithdrawn` — a status that is neither Send nor Cancel:
///
/// * **Its requesters.** The process ids `confirm.sh` hands it (the caller
///   that ran `confirm.sh`, and the plugin process that ran the connector).
///   When one of them is gone, nobody is waiting on the answer.
/// * **Its parent.** When `confirm.sh` itself is killed — a SIGKILL runs no
///   trap — the card is re-parented to launchd, and that is the same news.
/// * **Its deadline.** An absolute time, never more than `longestWait` away,
///   whatever it was asked for. A card nobody has answered in an hour is a
///   card nobody is going to answer.
///
/// Withdrawal is never a send, by construction: nothing in this file can
/// produce a 0, and the only thing the card does on the way out is leave a
/// sentence in the person's inbox saying what did not happen.
public enum ConfirmLifecycle {
    /// "Withdrawn": the requester went away, or nobody answered in time.
    /// Distinct from Cancel (1) so the caller can say which, and from "could
    /// not ask" (2) so `confirm.sh` does not fall through to its AppleScript
    /// dialog — which would be a second orphan, drawn by the first.
    public static let exitWithdrawn: Int32 = 7

    /// The longest any card may wait, whatever deadline it was handed.
    public static let longestWait: TimeInterval = 3600

    public enum Reason: String, Equatable {
        /// A requester process is gone, or the requester hung up (SIGHUP —
        /// what the connectors plugin sends when the turn that asked ended).
        case requesterGone = "the task that asked for it stopped"
        case parentGone = "the script that asked for it stopped"
        case deadline = "nobody answered in time"
        /// SIGTERM or SIGINT: somebody closed it.
        case terminated = "it was closed"
    }

    /// Tests only, and only ever SHORTER: a ceiling below `longestWait` from
    /// `MOE_CONFIRM_LONGEST_WAIT_FOR_TESTS`, so the cap on a far-future
    /// deadline can be watched working in seconds rather than an hour.
    public static func ceiling(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["MOE_CONFIRM_LONGEST_WAIT_FOR_TESTS"],
              let seconds = TimeInterval(raw), seconds > 0 else { return longestWait }
        return min(seconds, longestWait)
    }

    /// The `requester=` record: process ids separated by spaces or commas.
    /// Nonsense is dropped, as are 0, 1 (launchd) and negatives — `kill(0,…)`
    /// and `kill(-1,…)` address groups, not a process.
    public static func pids(_ record: String) -> [pid_t] {
        record.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Int32($0) }
            .filter { $0 > 1 }
    }

    /// The `deadline=` record: seconds since 1970. Nil when absent or not a
    /// number; the caller then uses `longestWait`.
    public static func deadline(_ record: String) -> Date? {
        guard let seconds = Double(record.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The deadline the card actually keeps: what it was asked for, never
    /// later than `longestWait` from now.
    public static func effectiveDeadline(_ asked: Date?, now: Date = Date(),
                                         longest: TimeInterval = longestWait) -> Date {
        let ceiling = now.addingTimeInterval(min(longest, longestWait))
        guard let asked else { return ceiling }
        return min(asked, ceiling)
    }

    /// Whether a process id names a live process. EPERM means it exists and
    /// belongs to someone else, which is still alive.
    public static func alive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Why the card should leave now, or nil to keep waiting.
    public static func check(requesters: [pid_t], parent: pid_t, deadline: Date,
                             now: Date = Date(),
                             alive: (pid_t) -> Bool = ConfirmLifecycle.alive) -> Reason? {
        if requesters.contains(where: { !alive($0) }) { return .requesterGone }
        if parent == 1 { return .parentGone }
        if now >= deadline { return .deadline }
        return nil
    }

    // MARK: - The sentence left behind

    /// What the person reads afterwards. Plain, about what did NOT happen
    /// ("nothing was sent" is the one fact they need), and honest about why:
    /// an unanswered card expired; one whose task stopped was withdrawn; one
    /// somebody closed was closed. The recipient is quoted, because it can be
    /// words a model or the other party wrote, and it is read aloud on Play.
    public static func withdrawnNote(channel: String, to: String, kind: String,
                                     reason: Reason = .deadline) -> String {
        let service = clean(channel, limit: 40)
        let who = clean(to, limit: 80)
        let why: String
        switch reason {
        case .deadline: why = "expired before you answered"
        case .requesterGone, .parentGone: why = "was withdrawn because the task that asked for it stopped"
        case .terminated: why = "was closed before you answered"
        }
        if kind == "act" {
            let what = service.isEmpty ? "action" : "\(service) action"
            return "That \(what)\(who.isEmpty ? "" : " on \u{201C}\(who)\u{201D}") \(why) — nothing was done."
        }
        let what = service.isEmpty ? "send" : "\(service) send"
        return "That \(what)\(who.isEmpty ? "" : " to \u{201C}\(who)\u{201D}") \(why) — nothing was sent."
    }

    /// One line, no steering characters, capped. The recipient can come out
    /// of a chats table the other party writes to; a newline or a bidi
    /// override in it must not draw a second sentence on the island.
    public static func clean(_ text: String, limit: Int) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let steering = v < 0x20 || v == 0x7F || (0x200B...0x200F).contains(v)
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0x2028 || v == 0x2029 || v == 0xFEFF || v == 0x061C
            if steering {
                if !out.hasSuffix(" ") { out.append(" ") }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > limit { out = String(out.prefix(limit - 1)) + "…" }
        return out
    }

    // MARK: - Whether to leave it at all

    /// The `source` a card's note carries in its inbox file, and what the
    /// app reads to say such a note only once.
    public static let noteSource = "confirm"

    /// Whether a withdrawn card leaves a sentence in the inbox, or only a
    /// line in the log.
    ///
    /// On 2026-09-30 the owner, mid-conversation by voice, was shown a card
    /// for a WhatsApp send; the turn that asked moved on, the card withdrew,
    /// and "That WhatsApp send to “Kaporos” was withdrawn…" landed on the
    /// island — three times, one per retry — about a card they had just
    /// watched go. Machinery describing itself to the person who saw it
    /// happen. So the note is left only when it is news: the person is away,
    /// so a card on the screen reached no one and they could not have known a
    /// send was waiting (review: `shown` is true the moment the window is
    /// ordered front, empty room or not). At the Mac, logged and nothing more.
    public static func leavesNote(shown: Bool, ownerAtMac: Bool) -> Bool {
        !ownerAtMac
    }

    /// How fresh `presence.json` must be to say "here". The same rule as
    /// the connectors plugin's `owner_at_mac` and moe-screen's `at_mac`:
    /// stale, absent or malformed is "not here".
    public static let presenceFresh: TimeInterval = 3 * 60

    /// Is the owner at this Mac, by the app's `presence.json`?
    public static func ownerAtMac(presence data: Data?, now: Date = Date()) -> Bool {
        guard let data,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (body["active"] as? Bool) == true,
              let stamp = body["at"] as? NSNumber,
              CFGetTypeID(stamp) != CFBooleanGetTypeID()
        else { return false }
        let at = stamp.doubleValue
        let age = now.timeIntervalSince1970 - at
        return age >= 0 && age <= presenceFresh
    }

    /// The Moe home, by the same rule as `inbox`.
    public static func home(_ home: String, environment: [String: String]) -> URL {
        if !home.isEmpty, FileManager.default.isExecutableFile(atPath: home + "/tools/confirm.sh") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        if let moe = environment["MOE_HOME"], !moe.isEmpty {
            return URL(fileURLWithPath: moe, isDirectory: true)
        }
        // ~/Library/Application Support/Moe, matching Config.homeDir — the
        // real directory, not the legacy link to it. Built here for the same
        // reason Vocabulary.swift builds it: this module sits below Moe and
        // cannot see its constant. scripts/test-moe-home.sh keeps them in step.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Moe", isDirectory: true)
    }

    /// Where the note goes: the Moe home's `inbox/`, which the app polls
    /// (`Conductor.watchForInbox`) whether or not a turn is running — so the
    /// person hears about it even when no conversation was waiting on the
    /// card. `home` is the directory `confirm.sh` lives under, and is only
    /// believed when it IS a Moe home (it holds `tools/confirm.sh`);
    /// otherwise `$MOE_HOME`, otherwise `~/Library/Application Support/Moe`.
    public static func inbox(home: String, environment: [String: String]) -> URL {
        Self.home(home, environment: environment).appendingPathComponent("inbox", isDirectory: true)
    }

    /// One inbox file, in the shape moe-screen's `deliver.write_inbox`
    /// writes and `ReminderChannels.pending` reads: 0600, written beside and
    /// renamed in so the poller never reads half of it.
    @discardableResult
    public static func writeNote(_ text: String, inbox: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let millis = Int(now.timeIntervalSince1970 * 1000)
        let tag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let url = inbox.appendingPathComponent("\(millis)-\(tag).json")
        let body: [String: Any] = [
            "text": text, "at": now.timeIntervalSince1970, "source": noteSource,
            "job": "", "chat_id": "screen", "said": "", "job_id": "", "loops": [String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
