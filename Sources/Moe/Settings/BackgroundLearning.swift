import AppKit
import Foundation

/// The daily pass that goes back over what you have connected and writes
/// down what it works out about you.
///
/// The pass itself is `moe-home/hermes-jobs/moe-learn-deep.sh`, run once a
/// day, which calls `~/.moe/learn.sh all --stage deep --no-ask`. It was
/// installed as a side effect of setup and nothing in the app said so; this
/// file is the ask, the switch and the stop.
///
/// One store, not two: the answer goes into the same
/// `memory/profile/consent.json` every per-source answer lives in, written
/// by the same `learn/consent.sh`. The name reserved for it is
/// `background-learning` — not a source, but the separate question of
/// whether Moe may do this on its own. `moe-learn-deep.sh` checks it first
/// and exits without reading anything when the answer is no, which is what
/// makes the switch below a real stop rather than a label.
enum BackgroundLearning {
    /// The name `learn/consent.sh` reserves for this answer. Kept in one
    /// place so the app and the script can never drift apart.
    static let source = "background-learning"

    enum State: String {
        case granted, refused, unset
        /// No consent script on disk — an install that has not finished.
        case unavailable
    }

    /// ~/.moe/learn/consent.sh (installed), then the copy inside the app,
    /// then the checkout. Same ladder the Connections screen uses.
    static func scriptPath() -> String? {
        var candidates = [Paths.home.appendingPathComponent("learn/consent.sh").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("learn/consent.sh").path)
        }
        if let c = Payload.checkoutPath("moe-home/learn/consent.sh") { candidates.append(c) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking; call off the main thread.
    static func state() -> State { state(of: source) }

    /// The recorded answer for any name consent.sh knows. Blocking.
    static func state(of name: String) -> State {
        guard let script = scriptPath() else { return .unavailable }
        let r = ScriptRunner.run(script, ["state", name], timeout: 20)
        guard r.status == 0 else { return .unavailable }
        let word = r.output.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return State(rawValue: word) ?? .unavailable
    }

    /// Record the answer. Blocking; call off the main thread.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        set(source, on: on)
    }

    /// The name `learn/consent.sh` reserves for "may what the crawl learns
    /// be saved into Moe's long-term memory" — the USER.md/MEMORY.md the
    /// brain carries into every chat, as opposed to Moe's own reviewable
    /// profile files. A separate, heavier answer; `learn.sh` never seeds
    /// without it.
    static let seeding = "memory-seeding"

    /// One thing the daily pass could read, as `consent.sh list` reports it.
    struct Source: Equatable, Identifiable {
        let name: String
        let state: State
        /// The connector's own status says it is set up. A source that is
        /// not connected is shown, not hidden — a person looking for "why
        /// doesn't Moe know my mail" should find the answer here — but its
        /// switch does nothing until Connections has it.
        let connected: Bool
        let label: String
        /// What saying yes hands over, in the words the terminal prompt
        /// uses: one sentence, the same one, wherever the question is asked.
        let reads: String
        /// For a watch: whether a recipe (what to read, how often) exists in
        /// ~/.moe/watch/ yet. Every connection Hermes has is listed either
        /// way; a watch with no recipe has nothing to run and its switch
        /// waits. Always true for a learning source.
        var configured: Bool = true
        /// The three things a person can say about one source, and the one
        /// thing Moe says back. These come from the seventh field of
        /// `consent.sh list` (learn/source_profile.py resolves them from
        /// the defaults table, what Moe guessed from the connection's own
        /// tools, and anything the person has set).
        ///
        /// They are separate answers on purpose. Before this, one row meant
        /// "may the daily pass learn from it", and a person who switched
        /// their chats off still heard Moe talk about a message from them —
        /// because the ten-minute pull and the proactive pass were governed
        /// by neither that switch nor any other.
        var profile: Profile = Profile()
        var id: String { name }
    }

    /// What Moe does with one source, on a clock.
    struct Profile: Equatable {
        /// Kept ready: pulled every ten minutes into the brief on this Mac.
        var sync = false
        /// May be spoken about: the proactive pass and any watch.
        var speak = false
        /// Read back once, and then caught up on `update`.
        var seed = false
        /// daily | weekly | monthly | never.
        var update = "never"
        /// The day the one-time read happened, or nil.
        var seeded: String?
        /// default | inferred | user — where these answers came from.
        var origin = "default"

        /// "sync=yes;speak=yes;seed=yes;update=daily;seeded=never;origin=default"
        /// Unknown keys are ignored and missing ones keep their default, so
        /// an older payload's shorter field cannot break the pane.
        init(field: String = "") {
            for pair in field.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "sync": sync = kv[1] == "yes"
                case "speak": speak = kv[1] == "yes"
                case "seed": seed = kv[1] == "yes"
                case "update": update = kv[1]
                case "seeded": seeded = kv[1] == "never" ? nil : kv[1]
                case "origin": origin = kv[1]
                default: break
                }
            }
        }

        /// How often Moe catches up, for a row's detail line.
        var cadence: String {
            switch update {
            case "daily": return "every day"
            case "weekly": return "once a week"
            case "monthly": return "once a month"
            default: return "never again"
            }
        }

        /// Said under a row when the answer was not the shipped default.
        var provenance: String? {
            switch origin {
            case "user": return "You set this."
            case "inferred": return "Moe worked this out from what the connection offers."
            default: return nil
            }
        }
    }

    /// Every source the crawl could visit — the manifests that say
    /// `deep_crawl=yes` and know the `crawl` verb, which is exactly what
    /// `learn.sh all` iterates — with its recorded answer. The two
    /// non-connector answers (`source`, `seeding`) are filtered out here;
    /// they have their own switches. Nil when the script is missing.
    /// Blocking; call off the main thread.
    static func sources(quick: Bool = false) -> [Source]? {
        guard let script = scriptPath() else { return nil }
        // `--quick` makes no live probe: "connected" comes from the last
        // known answer (~/.moe/status.json, kept by the sync and by the full
        // list) and the rows arrive in well under a second. The pane shows
        // that first and runs the full list behind it.
        let r = ScriptRunner.run(script, quick ? ["list", "--quick"] : ["list"], timeout: quick ? 20 : 120)
        guard r.status == 0 else { return nil }
        return r.output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, f[0] != source, f[0] != seeding else { return nil }
            return Source(name: f[0], state: State(rawValue: f[1]) ?? .unset,
                          connected: f[2] == "yes", label: f[3], reads: f[4],
                          configured: f.count < 6 || f[5] != "no",
                          profile: Profile(field: f.count < 7 ? "" : f[6]))
        }
    }

    /// One answer, for one name — a source, `source`, or `seeding`. Both
    /// directions go through `consent.sh`, so the answer lands in the one
    /// file the crawl reads and the terminal prompt writes. Blocking; call
    /// off the main thread.
    @discardableResult
    static func set(_ name: String, on: Bool) -> Bool {
        guard let script = scriptPath() else { return false }
        return ScriptRunner.run(script, [on ? "grant" : "revoke", name], timeout: 20).status == 0
    }

    // MARK: - The words on the switches

    /// The two switch titles a person meets in three places — the first-run
    /// step, the Memory page's sheet and Settings › Background — spelled
    /// once so they cannot drift into three vocabularies for one answer.
    enum Words {
        /// The daily pass's own switch.
        static let pass = "Once a day, read back over what I've allowed and note what it learns"
        /// One source's switch, the only one it has since 2026-09-29 (the
        /// owner: one switch covers everything — reading it, learning from
        /// it, watching it, mentioning it): "Learn from Gmail and watch it".
        static func row(_ label: String) -> String { "Learn from \(label) and watch it" }
        /// The group those switches sit in.
        static let section = "Learn and watch"
    }

    // MARK: - Rows, and what the step writes

    /// One connected thing, one switch. consent.sh keeps two answers for a
    /// Hermes connection — `watch:<name>` (tell me when something happens
    /// there) and, once a gather recipe exists, the bare name (learn from
    /// it) — and a Mac source has one. Nobody on a screen should have to
    /// know that: a row is the connection, and its switch sets every
    /// answer the connection has.
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let detail: String
        let names: [String]
        let on: Bool
        /// What Moe does with this source on a clock, so a row can draw its
        /// own "keep ready" and "tell me" switches beside the consent one.
        var profile = Profile()
        /// Only a Hermes connection with no watch recipe yet: there is
        /// nothing for "tell me when something happens here" to run.
        var awaitingRecipe = false

        /// The one sentence the terminal prompt uses for what this hands
        /// over, without the trailing full stop, so it can sit inside a
        /// longer line. `detail` is "Reads <that>." already.
        func reads(default fallback: String) -> String {
            let d = detail.hasPrefix("Reads ") ? String(detail.dropFirst(6)) : ""
            let cut = d.split(separator: ".").first.map(String.init) ?? ""
            return cut.isEmpty ? fallback : cut
        }
    }

    /// Every connected source, merged by connection, in the order the list
    /// gives them. Not connected → not here: a person looking for Cloudflare
    /// finds it the moment Connections has it, and stops finding it the
    /// moment Connections does not. `state` is what a screen believes a
    /// source's answer is right now — the file's word, or a switch the
    /// person just moved that the file has not caught up with.
    static func rows(_ sources: [Source]?, state: (Source) -> State = { $0.state }) -> [Row] {
        var order: [String] = []
        var byKey: [String: [Source]] = [:]
        for s in sources ?? [] where s.connected {
            let key = s.name.hasPrefix("watch:") ? String(s.name.dropFirst(6)) : s.name
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(s)
        }
        return order.map { key in
            let group = byKey[key] ?? []
            let plain = group.first { !$0.name.hasPrefix("watch:") }
            let watch = group.first { $0.name.hasPrefix("watch:") }
            var detail = "Reads " + (plain?.reads ?? watch?.reads ?? key) + "."
            if plain == nil, let watch, !watch.configured {
                detail += " Nothing runs until you tell Moe what to look for here — it writes the recipe."
            }
            return Row(id: key,
                       label: plain?.label ?? watch?.label ?? key,
                       detail: detail,
                       names: group.map(\.name),
                       on: group.contains { state($0) == .granted },
                       profile: (plain ?? watch)?.profile ?? Profile(),
                       awaitingRecipe: plain == nil && watch?.configured == false)
        }
    }

    /// What the first-run step (and the Memory page's copy of it) writes
    /// when its button is pressed, as a list of answers in the order they
    /// are recorded — worked out here, with no screen in the way, so
    /// `Moe --learn-step` can run exactly this against a scratch home and
    /// scripts/test-onboarding-learn.sh can hold the file it leaves against
    /// the one Settings › Background leaves for the same switches.
    ///
    /// The rule: every switch the person moved is written, as moved; and
    /// when at least one source ends up on, the daily-pass switch is written
    /// as they left it — that is the "one answer" the step exists to take.
    /// Nothing moved and nothing on is an empty list: Skip, and a Next
    /// with every switch still off, both leave the file exactly as it was.
    /// A source left off is *not* recorded as a no — that is what Settings
    /// › Background does for a switch nobody touched, and it is what keeps
    /// `askIfNeeded` honest about "never asked".
    static func stepWrites(rows: [Row], ticked: Set<String>, pass: Bool, passState: State)
        -> [(name: String, on: Bool)] {
        var writes: [(name: String, on: Bool)] = []
        for r in rows where ticked.contains(r.id) != r.on {
            for n in r.names { writes.append((n, ticked.contains(r.id))) }
        }
        let anyOn = rows.contains { ticked.contains($0.id) }
        let recordedOn: Bool? = passState == .granted ? true : passState == .refused ? false : nil
        if anyOn, recordedOn != pass {
            writes.append((source, pass))
        }
        return writes
    }

    /// Record a list of answers, each through `set` — the same verb the
    /// Settings › Background switches and the terminal prompt use. Stops at
    /// the first failure and says so. Blocking; call off the main thread.
    @discardableResult
    static func record(_ writes: [(name: String, on: Bool)]) -> Bool {
        for w in writes where !set(w.name, on: w.on) {
            Log.write("learn step: could not record \(w.name)=\(w.on ? "yes" : "no")")
            return false
        }
        return true
    }

    // MARK: - Recommended on the first-run step

    /// The rows the first-run step starts ticked (the step's model with
    /// `recommend: true`; the copy of the step elsewhere starts from the
    /// files, unticked) — docs/DEFAULTS.md row 24: the daily pass is the recommended
    /// choice, so every connected source starts on and the person unticks.
    /// Every source except one already said no to: a row granted before
    /// stays on, and a row refused before stays off, so pressing Save
    /// without touching a switch can never turn an old no into a yes.
    ///
    /// With these ticks `stepWrites` needs no change to make "just press
    /// Save" an answer: a pre-ticked unset row differs from its file, so it
    /// is written, and a source that ends up on writes the pass beside it.
    /// Skip never reaches the writer, so it still records nothing.
    static func recommendedTicks(_ sources: [Source]?) -> Set<String> {
        let refused = Set((sources ?? []).filter { $0.state == .refused }.map(\.name))
        return Set(rows(sources)
            .filter { r in r.on || !r.names.contains(where: { refused.contains($0) }) }
            .map(\.id))
    }

    // MARK: - Asked again when something is connected

    /// docs/DEFAULTS.md row 25. The first-run step runs on a Mac that has
    /// usually connected nothing yet, so its list is empty and the question
    /// has to come again. It comes the first time a source is connected
    /// (ConnectFlow's success → ConnectionsView): "Let Moe read <Source>
    /// back and learn about you?", Yes recommended, Not now.
    ///
    /// Asked only while every answer that source has is still unset — a
    /// source already said yes or no to is never asked about. Yes goes
    /// through `record`, the same writer the Settings switches use, and
    /// also says yes to the daily pass when that has never been answered.
    /// Not now records nothing in the consent file — not a no — and asks
    /// **once more a week later** (owner, 2026-09-29); a second Not now is
    /// the last time, and the switch in Settings is the way back.
    enum ConnectAsk {
        /// How long a Not now holds before the one more ask.
        static let againAfter: TimeInterval = 7 * 86400
        /// How many times a source is asked at most.
        static let most = 2

        /// One line per connection asked about: `id<TAB>yyyy-mm-dd<TAB>times`.
        /// A bare id (the file before 2026-09-29) is one ask, long ago.
        static func markerURL(home: URL = Paths.home) -> URL {
            home.appendingPathComponent(".learn-asked-at-connect")
        }

        struct Asked: Equatable { var day: String; var times: Int }

        static func record(home: URL = Paths.home) -> [String: Asked] {
            guard let text = try? String(contentsOf: markerURL(home: home), encoding: .utf8) else { return [:] }
            var out: [String: Asked] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let id = f.first, !id.isEmpty else { continue }
                out[id] = Asked(day: f.count > 1 ? f[1] : "", times: f.count > 2 ? max(1, Int(f[2]) ?? 1) : 1)
            }
            return out
        }

        private static let dayFormat: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        /// The connections NOT to ask about now: asked as often as they may
        /// be, or asked less than a week ago. Pure over the file's contents.
        static func notDue(_ asked: [String: Asked], now: Date = Date()) -> Set<String> {
            Set(asked.filter { _, a in
                if a.times >= most { return true }
                guard let d = dayFormat.date(from: a.day) else { return false }   // long ago
                return now.timeIntervalSince(d) < againAfter
            }.keys)
        }

        static func asked(home: URL = Paths.home, now: Date = Date()) -> Set<String> {
            notDue(record(home: home), now: now)
        }

        static func markAsked(_ id: String, home: URL = Paths.home, now: Date = Date()) {
            var all = record(home: home)
            let today = dayFormat.string(from: now)
            // Asked twice in one day (the connect sheet and the launch
            // question racing for one new connection) is one ask, or the
            // week-later ask would never come (review 2026-09-29 #5).
            if all[id]?.day == today { return }
            all[id] = Asked(day: today, times: (all[id]?.times ?? 0) + 1)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let text = all.keys.sorted().map { "\($0)\t\(all[$0]!.day)\t\(all[$0]!.times)" }
                .joined(separator: "\n") + "\n"
            try? text.write(to: markerURL(home: home), atomically: true, encoding: .utf8)
        }

        /// A connected source nobody has answered for and that is due an
        /// ask — the one question at launch that covers sources connected
        /// before this question existed, or connected outside Connections
        /// (a permission given in System Settings, a server added by hand).
        /// Pure.
        static func pending(sources: [BackgroundLearning.Source]?, asked: Set<String>) -> BackgroundLearning.Row? {
            pendingAll(sources: sources, asked: asked).first
        }

        /// The row to ask about for a connection just made, or nil. Pure.
        ///
        /// - Parameter names: what the connection is called — its `name`
        ///   and its `connectName` (a Mac source's key is its consent name;
        ///   a Hermes connection's name is both its gather answer and, after
        ///   `watch:`, its watch answer).
        static func row(forConnection names: [String], sources: [BackgroundLearning.Source]?,
                        asked: Set<String>) -> BackgroundLearning.Row? {
            let keys = Set(names.filter { !$0.isEmpty })
            guard !keys.isEmpty, let sources else { return nil }
            func mine(_ s: BackgroundLearning.Source) -> Bool {
                keys.contains(s.name.hasPrefix("watch:") ? String(s.name.dropFirst(6)) : s.name)
            }
            let own = sources.filter(mine)
            // Nothing to consent to (a service the daily pass cannot read),
            // or already answered one way or the other: no question.
            guard !own.isEmpty, own.allSatisfy({ $0.state == .unset }) else { return nil }
            // Just connected: the list's own "connected" may not have caught
            // up yet, and `rows` lists only what is connected.
            let fresh = sources.map { s -> BackgroundLearning.Source in
                guard mine(s) else { return s }
                return BackgroundLearning.Source(name: s.name, state: s.state, connected: true,
                                                 label: s.label, reads: s.reads,
                                                 configured: s.configured, profile: s.profile)
            }
            guard let r = BackgroundLearning.rows(fresh).first(where: { keys.contains($0.id) }),
                  !asked.contains(r.id) else { return nil }
            return r
        }

        /// The full list (it probes), then `row`. Blocking; call off the
        /// main thread.
        static func check(names: [String]) -> BackgroundLearning.Row? {
            row(forConnection: names, sources: BackgroundLearning.sources(), asked: asked())
        }

        /// What Yes writes, in order: every answer the connection has, then
        /// the daily pass when it has never been answered. Pure.
        static func writes(for row: BackgroundLearning.Row,
                           passState: BackgroundLearning.State) -> [(name: String, on: Bool)] {
            var out: [(name: String, on: Bool)] = row.names.map { (name: $0, on: true) }
            if passState == .unset { out.append((name: BackgroundLearning.source, on: true)) }
            return out
        }

        /// The launch question: every connected source nobody has answered
        /// and that is due, in ONE question with the same words as at
        /// connect ("Let Moe learn from Calendar, Notes and Mail and watch
        /// them…"), so a Mac that lost its unanswered sources from the brief
        /// gets them back with one Yes (review 2026-09-29 #8). Only over a
        /// visible window, never while another question or sheet is up (no
        /// stacking, no focus stolen from another app), and at most every
        /// few hours.
        @MainActor
        static func askPending(over window: NSWindow?) {
            guard let window, window.isVisible, window.attachedSheet == nil, !Notice.showing, !inFlight,
                  Date().timeIntervalSince(lastLook) > lookSpacing,
                  Date().timeIntervalSince(lastPending) > pendingSpacing else { return }
            // The list is read at most every few minutes (it runs a status per
            // Mac source): not on every click into Moe (re-review N2).
            lastLook = Date()
            inFlight = true
            Task { @MainActor in
                defer { inFlight = false }
                let rows = await ScriptRunner.offMain({
                    pendingAll(sources: BackgroundLearning.sources(quick: true), asked: asked())
                })
                // Re-checked now: the list took seconds, and a sheet may have
                // come up meanwhile (a connection just made asks by itself).
                guard !rows.isEmpty, window.isVisible, window.attachedSheet == nil, !Notice.showing else { return }
                lastPending = Date()
                for r in rows { markAsked(r.id) }
                let one = rows.count == 1
                let label = one ? rows[0].label : ""
                let reads = one ? rows[0].reads(default: rows[0].label) : Self.listed(rows.map(\.label))
                let yes = await withCheckedContinuation { cont in
                    Notice.show(over: window,
                                title: one ? LearnStepCopy.askTitle(label) : LearnStepCopy.askTitleMany(rows.count),
                                body: one ? LearnStepCopy.askBody(reads) : LearnStepCopy.askBodyMany(reads),
                                detail: LearnStepCopy.askDetail,
                                confirm: LearnStepCopy.askYes,
                                dismiss: LearnStepCopy.askNotNow) { cont.resume(returning: $0) }
                }
                if yes { for r in rows { _ = await ScriptRunner.offMain { grant(r) } } }
                Log.write("learn and watch, asked at launch: \(rows.map(\.id).joined(separator: ",")) \(yes ? "yes" : "not now")")
            }
        }
        @MainActor private static var lastPending = Date.distantPast
        @MainActor private static var inFlight = false
        @MainActor private static var lastLook = Date.distantPast
        static let lookSpacing: TimeInterval = 10 * 60
        static let pendingSpacing: TimeInterval = 4 * 3600

        /// "Calendar", "Calendar and Notes", "Calendar, Notes and Mail".
        static func listed(_ labels: [String]) -> String {
            guard labels.count > 1 else { return labels.first ?? "" }
            return labels.dropLast().joined(separator: ", ") + " and " + labels.last!
        }

        /// Every row `pending` would ask about, in list order. Pure.
        static func pendingAll(sources: [BackgroundLearning.Source]?, asked: Set<String>) -> [BackgroundLearning.Row] {
            guard let sources else { return [] }
            return BackgroundLearning.rows(sources).filter { r in
                !asked.contains(r.id) && r.names.allSatisfy { n in sources.first { $0.name == n }?.state == .unset }
            }
        }

        /// Yes. Blocking; call off the main thread.
        @discardableResult
        static func grant(_ row: BackgroundLearning.Row) -> Bool {
            let ok = BackgroundLearning.record(writes(for: row, passState: BackgroundLearning.state()))
            Log.write("learn at connect: \(row.id) \(ok ? "granted" : "could not be recorded")")
            return ok
        }
    }

    /// One of the clock answers — `sync`, `speak`, `seed` — for one source.
    /// The same path a person has in the terminal (`consent.sh mode <src>
    /// <key> <value>`), so the app and the shell cannot mean different
    /// things by the same switch. Blocking; call off the main thread.
    @discardableResult
    static func setMode(_ name: String, _ key: String, on: Bool) -> Bool {
        guard let script = scriptPath() else { return false }
        return ScriptRunner.run(script, ["mode", name, key, on ? "yes" : "no"],
                                timeout: 20).status == 0
    }

    /// True when at least one real source has already been said yes to — so
    /// there is something for a daily pass to read. Used to decide whether
    /// the question below is worth asking yet: on a Mac with nothing
    /// connected, a sheet about a background pass over nothing is noise.
    ///
    /// Blocking; call off the main thread.
    static func hasConsentedSource() -> Bool {
        guard let script = scriptPath() else { return false }
        let r = ScriptRunner.run(script, ["show"], timeout: 20)
        guard r.status == 0 else { return false }
        for line in r.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == "granted", String(parts[0]) != source else { continue }
            return true
        }
        return false
    }

    // MARK: - What the pass did last time

    /// The record `learn/last_pass.py` keeps in `~/.moe/logs/learn-last.json`:
    /// what the daily pass did the last time Hermes ran it, and why. Written
    /// by `moe-learn-deep.sh` at every gate it exits through and by
    /// `learn.sh` at the end of a pass that ran — so a pass that did nothing
    /// has a reason on disk, which it did not until 2026-09-14: three silent
    /// `ok` runs after an erase, a switch nobody had turned on, and nothing
    /// on the Mac that could say so.
    struct LastPass: Equatable {
        /// paused | not-asked | off | no-gate | ran | failed
        let outcome: String
        /// ISO 8601 with offset, as the script wrote it.
        let at: String
        /// One clause for a person: "didn't run — the daily pass is switched off."
        let reason: String

        /// "14 Sep", "today", "yesterday" — or nil if the stamp is unreadable.
        var day: String? {
            let f = ISO8601DateFormatter()
            guard let d = f.date(from: at) else { return nil }
            let cal = Calendar.current
            if cal.isDateInToday(d) { return "today" }
            if cal.isDateInYesterday(d) { return "yesterday" }
            return d.formatted(.dateTime.day().month(.abbreviated))
        }

        /// The note under the switch in Settings › Background: "Last daily
        /// pass, 14 Sep: read nothing — gmail: not switched on."
        var words: String {
            "Last daily pass, \(day ?? "recently"): \(reason)"
        }
    }

    /// ~/.moe/learn/last_pass.py (installed), the app's copy, the checkout —
    /// the same ladder as `scriptPath()`.
    static func lastPassScript() -> String? {
        var candidates = [Paths.home.appendingPathComponent("learn/last_pass.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("learn/last_pass.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/learn/last_pass.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// The record, read straight off disk — nil when the pass has never
    /// been through a gate on this Mac, or the file is not one this build
    /// can read. Blocking only on a small file; fine off the main thread.
    static func lastPass() -> LastPass? {
        let url = Paths.logs.appendingPathComponent("learn-last.json")
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = d["outcome"] as? String, !outcome.isEmpty,
              let at = d["at"] as? String,
              let reason = d["reason"] as? String else { return nil }
        return LastPass(outcome: outcome, at: at, reason: reason)
    }

    /// One sentence for the Memory page when there is nothing to show: why
    /// Moe has not learned about the person yet, from the recorded consent
    /// and the last-pass record — `last_pass.py explain`, so the terminal,
    /// the tests and the app say the same thing. Nil when the script is
    /// missing. Blocking; call off the main thread.
    static func explain() -> String? {
        guard let script = lastPassScript() else { return nil }
        let r = ScriptRunner.run(BrainSetup.python(), [script, "explain"], timeout: 10)
        guard r.status == 0 else { return nil }
        let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - The ask

    /// Asked once, before the pass has ever run, and never again: "Not now"
    /// is recorded as a no, so nobody is nagged. Turning it on later is one
    /// switch in Settings › Background.
    ///
    /// Every sentence below is checked against what actually happens:
    /// `learn-deep.json` schedules it `every 1d`; `learn.sh` passes
    /// `--no-ask`, so a source without its own recorded yes is skipped;
    /// `DEEP_DAYS` is 365; the crawled text is written 0600 under
    /// `context/crawl/` and deleted whatever the outcome; what is kept is
    /// `memory/profile/*.md`, one claim a line, each with where it came from
    /// and when.
    @MainActor
    static func askIfNeeded(over window: NSWindow?, completion: @escaping (Bool) -> Void = { _ in }) {
        Task {
            let ready = await ScriptRunner.offMain { () -> Bool in
                state() == .unset && hasConsentedSource()
            }
            guard ready else { completion(false); return }

            // The app's own sheet (NoticeSheet), not an NSAlert: this is the
            // first thing a person sees after onboarding, and it used to be
            // the one stock dialog in the flow.
            let yes = await withCheckedContinuation { cont in
                Notice.show(
                    over: (window?.isVisible == true) ? window : nil,
                    title: "Learn about you in the background?",
                    body: "Once a day, Moe can go back over the things you've already said yes to and keep a short list of what it works out — who matters to you, what you're working on, how you like things done.",
                    detail: "Only what you've already allowed, never anything new. It all stays on this Mac, in plain writing you can read and change in the Memory tab. Stop it any time in Settings › Background.",
                    confirm: "Yes, learn about me") { cont.resume(returning: $0) }
            }
            _ = await ScriptRunner.offMain { set(yes) }
            Log.write("background learning: \(yes ? "granted" : "declined") at the sheet")
            // Whether a question was SHOWN — the caller asks nothing else
            // straight after one (review 2026-09-29 #3); not the answer.
            completion(true)
        }
    }
}
