import Foundation

/// The chat platforms a reminder can be forwarded to, and the file the
/// moe-screen plugin drops reminders into for this screen.
///
/// The list of platforms is Hermes's, not ours: `hermes send --list --json`
/// names every platform the gateway has credentials for, from the same
/// `.env` and `config.yaml` the cron scheduler delivers through. Asking
/// Hermes rather than parsing those files means a connector added by any
/// route — `hermes gateway setup`, a connect script, the dashboard — shows
/// up here without this file knowing about it. Nothing here is hand-picked.
enum ReminderChannels {
    /// One platform Hermes can send to. `name` is the bare id (`telegram`);
    /// `title` is what a person reads; `ready` is whether that platform has
    /// a chat to deliver to right now (a paired WhatsApp, a Telegram that
    /// has heard from you) — a switch for one that is not is still offered,
    /// with a note, because ticking it is the point of pairing it next.
    struct Platform: Equatable, Identifiable {
        let name: String
        let title: String
        let ready: Bool
        var id: String { name }
    }

    /// Platforms Hermes lists, in its order. Blocking; call off the main
    /// thread. An empty list means Hermes could not be asked, not that
    /// there is nothing — the pane says which.
    static func available() -> [Platform]? {
        let hermes = Paths.hermesBinary()
        let r = ScriptRunner.run(hermes, ["send", "--list", "--json"], timeout: 20)
        guard r.status == 0,
              let start = r.output.firstIndex(of: "{"),
              let data = r.output[start...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = obj["platforms"] as? [String: Any] else { return nil }
        return platforms.keys.sorted().compactMap { name in
            // Hermes's own screen target is always on and is not a choice.
            guard name != "moe", name != "api_server" else { return nil }
            let chats = platforms[name] as? [[String: Any]] ?? []
            return Platform(name: name, title: title(for: name), ready: !chats.isEmpty)
        }
    }

    // MARK: - The first chat app, ticked for you

    /// Which chat Moe should tick for reminders by itself, or nil.
    /// docs/DEFAULTS.md row 26: reminders should reach the phone as soon as
    /// there is a phone to reach, so the first chat app that becomes ready
    /// (a home chat exists — the person has messaged Moe there) is ticked
    /// without being asked. Only ever once, and only into an empty list.
    ///
    /// - `alreadyPicked`: Moe or the person has chosen before
    ///   (`Config.reminderChannelsAutoPicked`) — never again, so an untick
    ///   is kept and a second chat app stays opt-in.
    /// - Exactly one ready platform. Two ready at the very first look is no
    ///   sign of which one the person means reminders to go to, and Moe
    ///   does not guess: both stay unticked, for the person to choose.
    /// - A platform that is connected but not ready is never picked:
    ///   every reminder sent to it would fail.
    static func autoPick(current: [String], alreadyPicked: Bool, platforms: [Platform]) -> String? {
        guard !alreadyPicked, current.isEmpty else { return nil }
        let ready = platforms.filter(\.ready)
        guard ready.count == 1 else { return nil }
        return ready[0].name
    }

    /// The launch watcher's looks before it gives up: every ten minutes for
    /// a day. `hermes send --list` is a process; a Mac with no chat app must
    /// not start one every ten minutes forever.
    static let maxWatchLooks = 144

    enum WatchStep: Equatable {
        /// Look again at the next tick.
        case keepWatching
        /// Stop the timer.
        case stop
        /// Stop, and set `reminderChannelsAutoPicked`: two or more chat apps
        /// were ready at one look, so `autoPick` will never pick one — the
        /// choice is the person's, and there is nothing left to watch for.
        case stopAndRemember
    }

    /// After one look (and any pick it made): whether the watcher goes on.
    /// `platforms` is what the look saw, or nil when Hermes could not be
    /// asked; `looks` counts this one.
    static func watchStep(alreadyPicked: Bool, looks: Int, platforms: [Platform]?) -> WatchStep {
        if alreadyPicked { return .stop }
        if let platforms, platforms.filter(\.ready).count >= 2 { return .stopAndRemember }
        if looks >= maxWatchLooks { return .stop }
        return .keepWatching
    }

    /// Apply `autoPick` to a config: tick the chat and remember that the
    /// pick happened. Returns the name ticked, or nil when nothing changed.
    /// Called inside `Config.update` so it decides on the latest file.
    @discardableResult
    static func adopt(_ platforms: [Platform], into config: inout Config) -> String? {
        guard let name = autoPick(current: config.reminderChannels,
                                  alreadyPicked: config.reminderChannelsAutoPicked,
                                  platforms: platforms) else { return nil }
        config.reminderChannels = [name]
        config.reminderChannelsAutoPicked = true
        return name
    }

    /// Hermes's ids are lower-case tokens; a few have a spelling people use.
    static func title(for name: String) -> String {
        switch name {
        case "telegram": return "Telegram"
        case "whatsapp", "whatsapp_cloud": return "WhatsApp"
        case "imessage", "bluebubbles": return "Messages"
        case "email": return "Email"
        case "sms": return "Text message"
        case "teams": return "Microsoft Teams"
        case "slack": return "Slack"
        case "discord": return "Discord"
        case "signal": return "Signal"
        case "matrix": return "Matrix"
        case "mattermost": return "Mattermost"
        case "google_chat": return "Google Chat"
        case "homeassistant": return "Home Assistant"
        default:
            return name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: - The inbox

    /// Where the moe-screen plugin puts a reminder for this Mac: one JSON
    /// file per message, `{text, at, source, job, job_id, loops, said}`,
    /// mode 0600 — every one of those keys is read below. Directory, not file, so two reminders a second apart are
    /// two reminders.
    static var inbox: URL { Paths.home.appendingPathComponent("inbox", isDirectory: true) }

    /// One waiting message, and the handles for changing what put it there.
    ///
    /// `loops` are the open-loop slugs Moe raised this about, and `jobID`
    /// is the cron behind it. Either can be empty. They exist so that
    /// "stop reminding me about that", said to the island, reaches the
    /// thing that would say it again — the brain gets them with the
    /// message in `playNudge`.
    ///
    /// `said` is the id of the same message in `~/.moe/proactive/said.json`,
    /// the spool the chat platforms read to answer their own copy of it.
    /// Playing or dismissing here writes that id into
    /// `~/.moe/proactive/answered/`, so a nudge dealt with on this Mac is
    /// not still waiting to be attached to an unrelated Telegram message
    /// that evening. A file rather than an edit to `said.json`: the spool's
    /// shape belongs to `deliver.py`, and a second reader of it here would
    /// be two files with two beliefs about one shape.
    struct Message: Equatable {
        let url: URL
        let text: String
        let job: String
        let jobID: String
        let loops: [String]
        let said: String
        let at: Date
        /// What the brain is told when this is played or answered, when the
        /// writer knows better than the generic handle text — a support
        /// ticket waiting on a yes (`TicketNotices`). Empty for everything
        /// `moe-screen` writes today.
        var instruction: String = ""
        /// What the app does with it. Empty is a reminder: a nudge on the
        /// island. "turn" is a finished helper's result (moe-screen's
        /// `completions.py`): the app runs a turn on it so Moe says the
        /// outcome in its own words instead of reading a results block.
        var kind: String = ""
        /// An offer from the situations engine (docs/PROACTIVE-MEMORY.md
        /// §4.8): the situation's id, whose prepared work is on the
        /// situation in ~/.moe/proactive/situations.json. "" for a reminder.
        var offer: String = ""
        /// What to say instead when this is still waiting a day later. A
        /// held send (moe-connectors `hold_for_owner`) must not just vanish
        /// at the 24-hour cut: the person is told it expired and nothing was
        /// sent. Empty for everything else, which is dropped as before.
        var expiredText: String = ""
        /// A finished helper's: the Hermes session it was started from — the
        /// id this app sent as `X-Hermes-Session-Id`, which is derived from
        /// the conversation (`BrainSession.id`). The app answers it in THAT
        /// conversation. Empty for a reminder, and for a result written by a
        /// plugin older than 2026-09-29, which goes to the one on screen.
        var sessionID: String = ""
        /// The inbox's words for it (docs/INBOX.md), when the writer gave
        /// them: a few-word title, a sentence or two of summary, answers to
        /// offer as chips, and which job it came from as a person would say
        /// it. All optional; `NoticeWords` derives what is missing.
        var title: String = ""
        var summary: String = ""
        var options: [String] = []
        var source: String = ""
        /// What it is about (docs/INBOX-QUIET.md decision 8): one open card
        /// per subject, updated in place. "" when the writer named none.
        var subject: String = ""
        /// The file's `source`: who wrote it (`reach_owner`, `confirm`,
        /// `cron`). Not the by-line (`source_label`, above). The inbox's bar
        /// reads it (`InboxGate`): the brain reaching for the person on
        /// purpose is shown, and a card's own withdrawal note is not.
        var writer: String = ""
        /// `time_critical: true` in the file: a pure FYI that cannot wait
        /// (docs/INBOX-QUIET.md decision 1). Only ever a real JSON true.
        var timeCritical = false
    }

    /// Say that the island dealt with a proactive message. Best effort:
    /// an empty id, or a home that cannot be written, costs one stale
    /// context attach on a phone and nothing else.
    static func markAnsweredOnScreen(_ said: String) {
        let id = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 32,
              id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return }
        let dir = Paths.home.appendingPathComponent("proactive/answered", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(id).path, contents: nil,
            attributes: [.posixPermissions: 0o600])
    }

    /// The inbox files that would not parse, so each is read once.
    ///
    /// Keyed by name, with the size and modification time it had: a file
    /// somebody then fixes or finishes writing is a different file and is
    /// read again. Kept in memory only — one more read per launch is the
    /// whole cost of forgetting, and nothing is moved or deleted, so the
    /// file is still there for whoever wants a look.
    final class Unreadable: @unchecked Sendable {
        static let shared = Unreadable()

        struct Stamp: Equatable {
            let size: Int
            let modified: Date?
            init(of url: URL) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
                modified = attrs?[.modificationDate] as? Date
            }
        }

        private let lock = NSLock()
        private var seen: [String: Stamp] = [:]

        func isKnown(_ name: String, _ stamp: Stamp) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return seen[name] == stamp
        }

        /// Remember it. True the first time this name is noted, so the log
        /// says it once rather than at every change.
        @discardableResult
        func note(_ name: String, _ stamp: Stamp) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let new = seen[name] == nil
            seen[name] = stamp
            return new
        }

        /// Forget files that are gone, so the list cannot grow without end.
        func keepOnly(_ names: [String]) {
            lock.lock(); defer { lock.unlock() }
            guard !seen.isEmpty else { return }
            let present = Set(names)
            seen = seen.filter { present.contains($0.key) }
        }
    }

    /// Whether any message file is still in the inbox. A directory listing,
    /// nothing read: what `Conductor.watchForInbox` asks after a pass, to
    /// know whether something is waiting on more than a file changing.
    static func hasWaiting(in dir: URL = inbox) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .contains { $0.hasSuffix(".json") }
    }

    /// Everything waiting, oldest first. Unreadable files are skipped, not
    /// deleted — the plugin writes atomically, so a half file is somebody
    /// else's, and a file that will not parse is worth a look.
    ///
    /// Skipped *and remembered*: the inbox is looked at every five seconds,
    /// and a file that would not parse was read and parsed again on every
    /// one of them for as long as it sat there. It is read once now, and
    /// again only if it changes (`Unreadable`).
    static func pending(in dir: URL = inbox, remembering unreadable: Unreadable = .shared,
                        read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> [Message] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let files = names.filter { $0.hasSuffix(".json") }.sorted()
        unreadable.keepOnly(files)
        return files.compactMap { name in
            let url = dir.appendingPathComponent(name)
            let stamp = Unreadable.Stamp(of: url)
            if unreadable.isKnown(name, stamp) { return nil }
            guard let data = read(url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if unreadable.note(name, stamp) {
                    Log.write("inbox: \(name) is not a message Moe can read — left where it is, not read again unless it changes")
                }
                return nil
            }
            // No `at`, or one that is not a number, is as old as it gets —
            // never "now". A held send (expired_text) is then shown as
            // expired, not as a fresh ask anyone could still answer, and a
            // reminder with no time is dropped rather than shown out of the
            // blue. Every writer stamps `at`; this is the malformed case.
            let at = (obj["at"] as? NSNumber).flatMap { n -> Date? in
                CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : Date(timeIntervalSince1970: n.doubleValue)
            } ?? .distantPast
            return Message(url: url, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           job: obj["job"] as? String ?? "",
                           jobID: obj["job_id"] as? String ?? "",
                           loops: (obj["loops"] as? [String] ?? []).filter { !$0.isEmpty },
                           said: obj["said"] as? String ?? "",
                           at: at,
                           instruction: obj["instruction"] as? String ?? "",
                           kind: obj["kind"] as? String ?? "",
                           offer: obj["offer"] as? String ?? "",
                           expiredText: obj["expired_text"] as? String ?? "",
                           sessionID: (obj["session_id"] as? String ?? "")
                               .trimmingCharacters(in: .whitespacesAndNewlines),
                           title: obj["title"] as? String ?? "",
                           summary: obj["summary"] as? String ?? "",
                           options: (obj["options"] as? [String] ?? []).filter { !$0.isEmpty },
                           source: obj["source_label"] as? String ?? "",
                           subject: obj["subject"] as? String ?? "",
                           writer: (obj["source"] as? String ?? "")
                               .trimmingCharacters(in: .whitespacesAndNewlines),
                           timeCritical: (obj["time_critical"] as? NSNumber).map {
                               CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
                           } ?? false)
        }
    }
}
