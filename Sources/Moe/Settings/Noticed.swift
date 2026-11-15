import Foundation
import MoeDesign
import SwiftUI

// Settings › Background › Noticed: what the situations engine saw
// (docs/PROACTIVE-MEMORY.md §4, §9 "the monitor"). The owner, 2026-09-24:
// no fixed cap on offers — a monitor instead, read on his own Mac while the
// engine is tuned. So this shows everything it decided and nothing it said:
// in slice 2 it says nothing at all.
//
// Two files, both written by moe-home/lib/situations.py:
//   ~/.moe/proactive/situations.json  one record per conversation it thinks
//                                      is open, keyed by its id
//   ~/.moe/logs/situations.jsonl       one line per decision: gated (and
//                                      why), asked, situation, tick, failures
// and a third, by moe-home/lib/promises.py:
//   ~/.moe/proactive/promises.json     who owes what by when, both ways

struct NoticedReport: Equatable {
    struct Situation: Identifiable, Equatable {
        let id: String
        let title: String
        let source: String
        let thread: String
        let atStake: String
        let openQuestion: String
        let ownerPosition: String
        let otherPosition: String
        let nextMove: String
        let deadline: String
        let help: [String]
        let pWanted: Double
        let status: String
        let updated: Date?
        let quotes: [String]
        /// What the preparer made (lib/prepare.py), when it has: the offer
        /// Moe would make, the options, the research with its sources, and
        /// a draft. Nothing here has been sent.
        var offer: String = ""
        var options: [String] = []
        var research: [(point: String, source: String)] = []
        var draft: String = ""

        /// Every field: a report differing only in its research, its
        /// stakes or its quotes used to compare equal and not redraw.
        static func == (a: Situation, b: Situation) -> Bool {
            a.id == b.id && a.title == b.title && a.source == b.source && a.thread == b.thread
                && a.atStake == b.atStake && a.openQuestion == b.openQuestion
                && a.ownerPosition == b.ownerPosition && a.otherPosition == b.otherPosition
                && a.nextMove == b.nextMove && a.deadline == b.deadline && a.help == b.help
                && a.pWanted == b.pWanted && a.status == b.status && a.updated == b.updated
                && a.quotes == b.quotes && a.offer == b.offer && a.options == b.options
                && a.draft == b.draft
                && a.research.map(\.point) == b.research.map(\.point)
                && a.research.map(\.source) == b.research.map(\.source)
        }

        /// Settled or waved away: shown last, dimmed, and not "your move".
        var isSettled: Bool { status == "resolved" || status == "dismissed" }
    }

    struct Counts: Equatable {
        var threads = 0
        var gated = 0
        var asked = 0
        var found = 0
        var failures = 0
        var reasons: [String: Int] = [:]
    }

    /// A promise the engine is watching (lib/promises.py): the owner's or
    /// someone else's, to its date. Kept ones close by themselves.
    struct Promise: Identifiable, Equatable {
        let id: String
        let mine: Bool
        let who: String
        let what: String
        let due: String
        let status: String
        let source: String
        let thread: String
        let updated: Date?
        let quote: String

        var isOpen: Bool { status == "open" }
    }

    var situations: [Situation] = []
    var promises: [Promise] = []
    var today = Counts()
    var lastTick: Date?

    static var situationsURL: URL { Paths.home.appendingPathComponent("proactive/situations.json") }
    static var monitorURL: URL { Paths.home.appendingPathComponent("logs/situations.jsonl") }
    static var promisesURL: URL { Paths.home.appendingPathComponent("proactive/promises.json") }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// How much of the monitor's end is read: the last day's lines are all
    /// the tab counts, and the file grows by every tick.
    static let monitorTail = 512 * 1024

    static func load(now: Date = Date()) -> NoticedReport {
        var r = parse(situations: try? Data(contentsOf: situationsURL),
                      monitor: tail(of: monitorURL, bytes: monitorTail), now: now)
        r.promises = parsePromises(try? Data(contentsOf: promisesURL))
        return r
    }

    /// Open first, soonest due first (no date last); then the settled, the
    /// most recent first.
    static func parsePromises(_ data: Data?) -> [Promise] {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Promise] = []
        for (id, raw) in obj {
            guard let p = raw as? [String: Any], let what = p["what"] as? String, !what.isEmpty else { continue }
            let quote = ((p["evidence"] as? [[String: Any]])?.first?["quote"] as? String) ?? ""
            out.append(Promise(id: id, mine: (p["by"] as? String) == "owner",
                               who: (p["who"] as? String) ?? "", what: what,
                               due: (p["due"] as? String) ?? "", status: (p["status"] as? String) ?? "open",
                               source: (p["source"] as? String) ?? "", thread: (p["thread_name"] as? String) ?? "",
                               updated: (p["updated_at"] as? String).flatMap { iso.date(from: $0) },
                               quote: quote))
        }
        return out.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            if $0.isOpen {
                let a = $0.due.isEmpty ? "~" : $0.due, b = $1.due.isEmpty ? "~" : $1.due
                return a == b ? $0.id < $1.id : a < b
            }
            return ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
        }
    }

    /// The last `bytes` of a file, from the first whole line in them.
    static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data.subdata(in: data.index(after: newline)..<data.endIndex)
        }
        return data
    }

    /// Pure, for the tests: the two files' bytes to what the tab shows.
    static func parse(situations: Data?, monitor: Data?, now: Date) -> NoticedReport {
        var report = NoticedReport()
        if let situations,
           let obj = try? JSONSerialization.jsonObject(with: situations) as? [String: Any] {
            for (id, raw) in obj {
                guard let s = raw as? [String: Any] else { continue }
                let quotes = ((s["evidence"] as? [[String: Any]]) ?? []).compactMap { $0["quote"] as? String }
                let prepared = (s["prepared"] as? [String: Any]) ?? [:]
                var sit = Situation(
                    id: id,
                    title: (s["title"] as? String) ?? "",
                    source: (s["source"] as? String) ?? "",
                    thread: (s["thread_name"] as? String) ?? "",
                    atStake: (s["at_stake"] as? String) ?? "",
                    openQuestion: (s["open_question"] as? String) ?? "",
                    ownerPosition: (s["owner_position"] as? String) ?? "",
                    otherPosition: (s["other_position"] as? String) ?? "",
                    nextMove: (s["next_move"] as? String) ?? "none",
                    deadline: (s["deadline"] as? String) ?? "",
                    help: (s["help"] as? [String]) ?? [],
                    pWanted: ((s["p_wanted"] as? NSNumber)?.doubleValue).map { $0.isFinite ? $0 : 0 } ?? 0,
                    status: (s["status"] as? String) ?? "sensed",
                    updated: (s["updated_at"] as? String).flatMap { iso.date(from: $0) },
                    quotes: quotes)
                sit.offer = (prepared["offer"] as? String) ?? ""
                sit.options = (prepared["options"] as? [String]) ?? []
                sit.draft = (prepared["draft"] as? String) ?? ""
                sit.research = ((prepared["research"] as? [[String: Any]]) ?? []).compactMap {
                    guard let p = $0["point"] as? String, let u = $0["source"] as? String else { return nil }
                    return (p, u)
                }
                report.situations.append(sit)
            }
        }
        // Open first, then the most recently touched.
        report.situations.sort {
            let a = $0.isSettled ? 1 : 0, b = $1.isSettled ? 1 : 0
            if a != b { return a < b }
            return ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
        }
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        if let monitor, let text = String(data: monitor, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let event = e["event"] as? String,
                      let at = (e["at"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
                if event == "tick" { report.lastTick = max(report.lastTick ?? at, at) }
                guard at >= dayAgo else { continue }
                switch event {
                case "gated":
                    report.today.threads += 1
                    report.today.gated += 1
                    for why in (e["why"] as? [String]) ?? [] { report.today.reasons[why, default: 0] += 1 }
                case "asked":
                    report.today.threads += 1
                    report.today.asked += 1
                case "situation":
                    report.today.threads += 1
                    report.today.asked += 1
                    report.today.found += 1
                case "read-failed", "sensor-failed", "dropped":
                    report.today.failures += 1
                case "prepare-failed":
                    // "Nothing usable" is the preparer declining, not failing
                    // (the engine counts it the same way, situations.py).
                    if (e["why"] as? String) != "nothing usable prepared" { report.today.failures += 1 }
                default:
                    break
                }
            }
        }
        return report
    }
}

/// The tab itself.
struct NoticedTab: View {
    @State private var report = NoticedReport()
    @State private var open: Set<String> = []
    var demo: NoticedReport? = nil
    /// The two offer switches; nil in a snapshot, which draws them off.
    var conductor: Conductor? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            Text("Moe looks at what's new in the chats you let it learn from, and asks one question of each conversation that moved: is something open here where you have something at stake, that it could prepare for you? For the ones that matter most, it gets the work ready: the research, the options worked out, a draft. Nothing is ever sent unless you say so and confirm.")
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)

            SettingGroup(title: "Offers") {
                SettingRow(
                    title: "Offer what's ready",
                    detail: "When Moe has the work ready and is fairly sure you'd want it, the island glows with one line: Use draft, See it, Not now. Use draft sends exactly that reply where the conversation is, after you see it and confirm. Off, it's only shown here."
                ) {
                    VoicePane.lever(Binding(get: { conductor?.config.situationOffers ?? false },
                                            set: { conductor?.setSituationOffers($0) }),
                                    enabled: conductor != nil)
                }
                SettingRow(
                    title: "Also send offers to my chats when I'm away",
                    detail: "To the chats you get reminders in, with the draft written out. Reply \u{201C}send it\u{201D} and Moe asks you to confirm before anything goes. Off, offers wait for you at the Mac.",
                    last: true
                ) {
                    VoicePane.lever(Binding(get: { conductor?.config.situationOffersToChats ?? false },
                                            set: { conductor?.setSituationOffersToChats($0) }),
                                    enabled: conductor != nil && (conductor?.config.situationOffers ?? false))
                }
            }

            SettingGroup(title: "The last 24 hours") {
                Text(summary)
                    .font(Theme.Typo.ui(13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.small)
                if !reasons.isEmpty {
                    Text(reasons)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingGroup(title: "Promises") {
                Text("What you said you'd do, and what others said they'd do for you, found in the same conversations. Moe checks everywhere it reads for signs a promise was kept and closes it by itself; if not, it comes up the morning it's due, and again if the day passes.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.small)
                if report.promises.isEmpty {
                    Text("None yet.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .padding(.bottom, Theme.Space.small)
                }
                ForEach(report.promises.prefix(30)) { p in
                    promiseRow(p)
                }
            }

            SettingGroup(title: "What it noticed") {
                if report.situations.isEmpty {
                    Text("Nothing yet. It starts from the moment it was switched on, never from your history.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .padding(.vertical, Theme.Space.small)
                }
                ForEach(report.situations) { s in
                    row(s)
                    if s.id != report.situations.last?.id {
                        Rectangle().fill(Theme.rule).frame(height: 1)
                    }
                }
            }
        }
        .onAppear {
            if let demo { report = demo; return }
            // Off the main thread: two files, one of them a growing log.
            Task.detached(priority: .userInitiated) {
                let loaded = NoticedReport.load()
                await MainActor.run { report = loaded }
            }
        }
    }

    private var summary: String {
        let c = report.today
        if c.threads == 0 && c.failures == 0 {
            return report.lastTick == nil
                ? "It hasn't looked yet."
                : "Nothing new in your conversations. Last looked \(Self.ago(report.lastTick!))."
        }
        var s = "\(c.threads) conversation\(c.threads == 1 ? "" : "s") moved. "
            + "\(c.gated) passed over without asking anything, "
            + "\(c.asked) looked at more closely, "
            + "\(c.found) noticed."
        if c.failures > 0 { s += " \(c.failures) look\(c.failures == 1 ? "" : "s") didn't work." }
        if let t = report.lastTick { s += " Last looked \(Self.ago(t))." }
        return s
    }

    private var reasons: String {
        let words: [String: String] = [
            "not addressed to the owner": "not to you",
            "only the owner's own messages": "only your own messages",
            "automated": "automated",
            "no signal": "nothing that needed you",
            "reply pending on the owner": "waiting on you, nothing more",
        ]
        let parts = report.today.reasons.sorted { $0.value > $1.value }.compactMap { k, v in
            words[k].map { "\(v) \($0)" }
        }
        return parts.isEmpty ? "" : "Passed over: " + parts.joined(separator: ", ") + "."
    }

    private func row(_ s: NoticedReport.Situation) -> some View {
        let expanded = open.contains(s.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if expanded { open.remove(s.id) } else { open.insert(s.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                    Text(s.title)
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(s.isSettled ? Theme.ink3 : Theme.ink)
                    Spacer(minLength: 8)
                    Text(badge(s))
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink3)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .accessibilityLabel(expanded ? "Expanded" : "Collapsed")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(line(s))
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !s.offer.isEmpty {
                (Text("Ready: ").foregroundStyle(Theme.accent) + Text(s.offer).foregroundStyle(Theme.ink))
                    .font(Theme.Typo.ui(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    detail("You", s.ownerPosition)
                    detail("Them", s.otherPosition)
                    detail("Open", s.openQuestion)
                    detail("By", s.deadline)
                    detail("Could help by", s.help.map(Self.helpWord).joined(separator: ", "))
                    ForEach(Array(s.options.enumerated()), id: \.offset) { _, o in
                        detail("Option", o)
                    }
                    ForEach(Array(s.research.enumerated()), id: \.offset) { _, r in
                        detail("Found", r.point + " (" + (URL(string: r.source)?.host ?? r.source) + ")")
                    }
                    if !s.draft.isEmpty {
                        Text("Draft, not sent:")
                            .font(Theme.Typo.ui(12))
                            .foregroundStyle(Theme.ink3)
                            .padding(.top, 2)
                        Text(s.draft)
                            .font(Theme.Typo.prose(13))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Theme.Space.small)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(Theme.sunk))
                    }
                    ForEach(Array(s.quotes.enumerated()), id: \.offset) { _, q in
                        Text("\u{201C}\(q)\u{201D}")
                            .font(Theme.Typo.prose(12))
                            .italic()
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, Theme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promiseRow(_ p: NoticedReport.Promise) -> some View {
        let who = p.who.isEmpty ? "them" : p.who
        let title = p.mine ? "You → \(who): \(p.what)" : "\(who) → you: \(p.what)"
        var meta: [String] = []
        switch p.status {
        case "open": meta.append(p.due.isEmpty ? "no date" : "due \(Self.dueWord(p.due))")
        case "kept": meta.append("kept")
        case "released": meta.append("called off")
        case "lapsed": meta.append("let go")
        default: meta.append(p.status)
        }
        if !p.thread.isEmpty { meta.append("\(p.thread) on \(Self.sourceName(p.source))") }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typo.ui(13, weight: p.isOpen ? .medium : .regular))
                .foregroundStyle(p.isOpen ? Theme.ink : Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Text(meta.joined(separator: " · "))
                .font(Theme.Typo.ui(11))
                .foregroundStyle(Theme.ink3)
            if p.isOpen && !p.quote.isEmpty {
                Text("\u{201C}\(p.quote)\u{201D}")
                    .font(Theme.Typo.prose(12))
                    .italic()
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "2026-10-01" → "Oct 1"; "2026-10-01T15:00" → "Oct 1, 15:00".
    static func dueWord(_ due: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(due.prefix(10))) else { return due }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        let day = out.string(from: d)
        return due.count > 10 ? "\(day), \(due.dropFirst(11).prefix(5))" : day
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            (Text(label + ": ").foregroundStyle(Theme.ink3) + Text(value).foregroundStyle(Theme.ink2))
                .font(Theme.Typo.ui(12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ s: NoticedReport.Situation) -> String {
        var parts: [String] = []
        if !s.thread.isEmpty { parts.append("\(s.thread) on \(Self.sourceName(s.source))") }
        if !s.atStake.isEmpty { parts.append(s.atStake) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ s: NoticedReport.Situation) -> String {
        if s.status == "resolved" { return "settled" }
        if s.status == "dismissed" { return "dismissed" }
        let move = s.nextMove == "owner" ? "your move" : s.nextMove == "other" ? "their move" : "no move yet"
        return "\(move) · \(Int((s.pWanted * 100).rounded()))% you'd want help"
    }

    static func helpWord(_ h: String) -> String {
        switch h {
        case "gather-records": return "pulling the records"
        case "compare-options": return "comparing options"
        case "research": return "looking into it"
        case "draft": return "drafting a reply"
        case "compute": return "working out the numbers"
        case "schedule": return "finding a time"
        case "remind": return "reminding you"
        default: return h
        }
    }

    static func sourceName(_ qualified: String) -> String {
        // "native/whatsapp", "composio/gmail": the engine's source names.
        let s = qualified.split(separator: "/").last.map(String.init) ?? qualified
        switch s {
        case "whatsapp": return "WhatsApp"
        case "imessage": return "Messages"
        case "mail": return "Mail"
        case "gmail": return "Gmail"
        case "telegram": return "Telegram"
        case "github": return "GitHub"
        case "googlecalendar": return "Google Calendar"
        case "slack": return "Slack"
        case "notes": return "Notes"
        case "call-recordings": return "recorded calls"
        case "meetings": return "Meetings"
        case "chats": return "your chats with Moe"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60) minutes ago" }
        if s < 86400 { return "\(s / 3600) hour\(s / 3600 == 1 ? "" : "s") ago" }
        return "\(s / 86400) day\(s / 86400 == 1 ? "" : "s") ago"
    }
}

#if DEBUG
extension NoticedReport {
    /// What the snapshot draws: the shape of the owner's measured run
    /// (2026-09-24, 72 h of WhatsApp), with the particulars made up.
    static var demo: NoticedReport {
        var r = NoticedReport()
        r.today = Counts(threads: 13, gated: 9, asked: 4, found: 3, failures: 0,
                         reasons: ["not addressed to the owner": 4, "no signal": 2,
                                   "reply pending on the owner": 2, "only the owner's own messages": 1])
        r.lastTick = Date().addingTimeInterval(-240)
        r.promises = [
            Promise(id: "prm_1", mine: true, who: "Dana", what: "send the pitch deck", due: "2026-10-01",
                    status: "open", source: "native/whatsapp", thread: "Dana Levi", updated: Date(),
                    quote: "I'll send you the deck by Thursday"),
            Promise(id: "prm_2", mine: false, who: "Acme Foods", what: "credit the missing 450 birds", due: "",
                    status: "open", source: "native/whatsapp", thread: "Acme Foods", updated: Date(), quote: ""),
            Promise(id: "prm_3", mine: true, who: "Yossi", what: "call about the lease", due: "2026-09-27",
                    status: "kept", source: "native/mail", thread: "Yossi", updated: Date(), quote: ""),
        ]
        r.situations = [
            Situation(id: "sit_1", title: "Supplier short delivery", source: "whatsapp", thread: "Acme Foods",
                      atStake: "$4,200 and an ongoing supplier",
                      openQuestion: "How much to pay for a partial delivery",
                      ownerPosition: "Pay half: 250 of 700 arrived, two hours late",
                      otherPosition: "Wants the full $4,200 by Friday",
                      nextMove: "owner", deadline: "2026-09-26", help: ["gather-records", "research", "draft"],
                      pWanted: 0.8, status: "sensed", updated: Date().addingTimeInterval(-600),
                      quotes: ["Full payment of $4,200 by Friday", "Only 250 came and you were 2 hours late"],
                      offer: "Acme wants the full $4,200 for a short delivery; I worked out pro-rata and have a reply ready.",
                      options: ["Pay pro-rata: $1,500 for the 250 of 700 that arrived", "Pay for what arrived plus a credit note for the rest"],
                      research: [("Buyers usually pay for what was delivered", "https://law.example/short-ship")],
                      draft: "Hi — 250 of the 700 arrived, two hours late, so I'll pay $1,500 now for what came. Happy to talk about the rest."),
            Situation(id: "sit_2", title: "Haircut price before booking", source: "whatsapp", thread: "Faded Crown",
                      atStake: "Booking today at a confirmed price", openQuestion: "Does the $25 include a taper?",
                      ownerPosition: "", otherPosition: "", nextMove: "owner", deadline: "", help: ["draft"],
                      pWanted: 0.6, status: "sensed", updated: Date().addingTimeInterval(-3600), quotes: []),
            Situation(id: "sit_3", title: "Event settlement", source: "whatsapp", thread: "Kaporos team",
                      atStake: "About $3,110 still to settle", openQuestion: "What the venue will pay per unit",
                      ownerPosition: "", otherPosition: "", nextMove: "other", deadline: "", help: ["compute"],
                      pWanted: 0.62, status: "resolved", updated: Date().addingTimeInterval(-7200), quotes: []),
        ]
        return r
    }
}
#endif
