import Foundation

/// Every setting Moe may know about, in one list (docs/SETTINGS-ASSISTANT.md).
///
/// The owner, 2026-11-14: when someone does not want something Memoe does,
/// Moe should already know there is a switch for it, offer it, and either
/// flip it or open Settings exactly there. That needs one place that says,
/// for each switch: its words on screen, its page, what it does, what people
/// say when it bothers them, and whether Moe may change it.
///
/// Three things are made from this list and nothing else:
/// - `publish` — `settings-catalogue.json` in Moe's home, read by the brain's
///   `moe_settings_find` (moe-screen/settings.py), current values included;
/// - `map` — every title by page, in the stable system prompt, no values;
/// - `SettingsBridge` — the only route by which the brain changes a value,
///   through the entry's own `write`, refusing anything marked `.person`.
enum SettingsCatalogue {

    /// Who flips it once the person wants it changed.
    enum Who: String, Sendable {
        /// Moe changes it after the person says yes, and says so.
        case moe
        /// Moe opens Settings on the row; the person flips it. Privacy,
        /// sending on their behalf, deleting, money, screen control.
        case person
    }

    enum Kind: Sendable {
        case toggle
        /// `value` is what the brain sends and `read` returns; `label` is
        /// the words on screen.
        case choice([(value: String, label: String)])
        case number(min: Double, max: Double, unit: String)

        var name: String {
            switch self {
            case .toggle: return "toggle"
            case .choice: return "choice"
            case .number: return "number"
            }
        }
    }

    struct Entry: Sendable {
        /// Stable, and the config.json key where there is one.
        let id: String
        /// The row's title on screen, verbatim — `SettingsCatalogueTests`
        /// finds it in the page's source.
        let title: String
        /// Where it lives. A page folded into another (`.replies`) is fine:
        /// `SettingsWindow.Selection` lands it on its host.
        let page: MainWindow.Section
        /// Words a person would need to find it on the page: "More", a tab.
        var under: String? = nil
        /// What it does, in the person's words.
        let does: String
        /// What someone says when they would want this changed — the search
        /// lands on these, so write them the way people complain.
        let says: [String]
        let who: Who
        let kind: Kind
        /// The current value: "on"/"off", a choice's `value`, or a number.
        let read: @MainActor @Sendable (Conductor) -> String
        /// Applies a value already checked against `kind`. False when the
        /// app could not (a toggle that needs a permission first, say).
        let write: @MainActor @Sendable (Conductor, String) -> Bool
    }

    // MARK: - Values

    static func toggleValue(_ on: Bool) -> String { on ? "on" : "off" }

    /// "on"/"off" and the words people use for them. Nil for anything else.
    static func parseToggle(_ raw: String) -> Bool? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "on", "true", "yes", "1", "enable", "enabled": return true
        case "off", "false", "no", "0", "disable", "disabled": return false
        default: return nil
        }
    }

    /// The value `raw` names for `entry`, normalised, or nil when it is not
    /// one the entry accepts. A choice matches its value or its label.
    static func normalise(_ raw: String, for entry: Entry) -> String? {
        switch entry.kind {
        case .toggle:
            return parseToggle(raw).map(toggleValue)
        case .choice(let options):
            let want = raw.lowercased().trimmingCharacters(in: .whitespaces)
            return options.first { $0.value.lowercased() == want || $0.label.lowercased() == want }?.value
        case .number(let lo, let hi, _):
            guard let n = Double(raw.trimmingCharacters(in: .whitespaces)), n >= lo, n <= hi else { return nil }
            return n == n.rounded() ? String(Int(n)) : String(n)
        }
    }

    static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// **The values Moe may set without the send gate asking** — each one only
    /// makes Moe do, say or listen less, or changes how an answer is shown.
    /// Any other change of a `.moe` setting (turning speech, nudges or offers
    /// on, quiet hours off, a longer listening window, a new talk key) asks
    /// the person first, through the gate, the way a send does: text Moe read
    /// can ask for a tool call, and widening what Moe does on someone else's
    /// say-so must reach the person's eyes (moe-bd's review, 2026-11-14).
    ///
    /// The gate holds its own copy — `SETTINGS_DIRECT` in
    /// moe-home/hermes/hooks/confirm-send.sh — because a rule the gate reads
    /// from a file under the home could be rewritten by whatever wrote there.
    /// `SettingsCatalogueTests.theGateHoldsTheSameTable` keeps them equal.
    static let direct: [String: Set<String>] = [
        // Quieter.
        "replyChime": ["off"], "instantAck": ["off"], "spokenProgress": ["off"],
        "speakSpokenReplies": ["off"], "speakTypedReplies": ["off"], "speakReplies": ["screen"],
        "nudges": ["off"], "quietHours": ["on"], "situationOffers": ["off"],
        "closeOffer": ["off", "shown"], "meetingAutoStopOnCallEnd": ["on"],
        "calendarHeadsUpMinutes": ["0"], "followUpSeconds": ["8"],
        // How an answer is shown, either way.
        "replyLength": ["short", "balanced", "detailed"],
        "replyReadingSeconds": ["6", "12", "30", "0"],
        "typedRepliesReadAsText": ["on", "off"],
        "panelOnReply": ["always", "silent", "never"],
        "typedAnswersOpenChat": ["on", "off"],
        "notchHoverOpens": ["on", "off"],
        "tenMinuteCheck": ["off"],
    ]

    /// Values that live outside config.json and cost a process to read (a
    /// `launchctl list`, consent.sh). Read off the main thread by `refresh`
    /// before every publish and every bridge request; nil until then, which
    /// the entries report as "unknown" rather than a guess.
    @MainActor enum Live {
        static var jobLoaded: Bool?
        static var learning: Bool?
        static var seeding: Bool?

        /// granted → true, refused → false; unset or unavailable is no answer.
        nonisolated static func answer(_ s: BackgroundLearning.State) -> Bool? {
            switch s {
            case .granted: return true
            case .refused: return false
            case .unset, .unavailable: return nil
            }
        }

        static func refresh() async {
            let job = await ScriptRunner.offMain { Launchd.loadedLabels().contains(Launchd.jobsLabel) }
            let learn = await ScriptRunner.offMain { BackgroundLearning.state() }
            let seed = await ScriptRunner.offMain { BackgroundLearning.state(of: BackgroundLearning.seeding) }
            jobLoaded = job
            learning = answer(learn)
            seeding = answer(seed)
        }
    }

    // MARK: - What the brain reads

    /// The published file, by the same path every plugin spells
    /// (`$MOE_HOME` or `~/.moe`, which is a link to the real home).
    nonisolated static var fileURL: URL { Config.homeDir.appendingPathComponent("settings-catalogue.json") }

    @MainActor static func json(_ c: Conductor) -> [String: Any] {
        let rows: [[String: Any]] = all.map { e in
            var row: [String: Any] = [
                "id": e.id, "title": e.title,
                "page": SettingsView.label(SettingsWindow.Selection.landing(e.page), awayTier: nil),
                "does": e.does, "says": e.says, "who": e.who.rawValue,
                "kind": e.kind.name, "value": e.read(c),
            ]
            if e.who == .moe { row["direct"] = (direct[e.id] ?? []).sorted() }
            if let under = e.under { row["under"] = under }
            switch e.kind {
            case .choice(let options):
                row["choices"] = options.map { ["value": $0.value, "label": $0.label] }
            case .number(let lo, let hi, let unit):
                row["min"] = lo; row["max"] = hi; row["unit"] = unit
            case .toggle: break
            }
            return row
        }
        return ["version": 1, "settings": rows]
    }

    /// Writes the file when its contents changed; atomic, so a reader never
    /// sees half of it.
    @MainActor static func publish(_ c: Conductor) {
        guard let data = try? JSONSerialization.data(withJSONObject: json(c),
                                                     options: [.sortedKeys, .prettyPrinted]) else { return }
        if (try? Data(contentsOf: fileURL)) == data { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Every title by page, for the stable system prompt. No values: a value
    /// would change the prompt every time a switch moved and respawn the
    /// brain (docs/SETTINGS-ASSISTANT.md, "How Moe knows when to offer").
    static var map: String {
        var order: [String] = []
        var byPage: [String: [String]] = [:]
        for e in all {
            let page = SettingsView.label(SettingsWindow.Selection.landing(e.page), awayTier: nil)
            if byPage[page] == nil { order.append(page) }
            byPage[page, default: []].append(e.title)
        }
        return order.map { "\($0): " + byPage[$0]!.joined(separator: "; ") }.joined(separator: "\n")
    }

    // MARK: - Builders for the common shapes

    static func toggle(_ id: String, _ title: String, _ page: MainWindow.Section, under: String? = nil,
                       does: String, says: [String], who: Who,
                       get: @escaping @MainActor @Sendable (Conductor) -> Bool,
                       set: @escaping @MainActor @Sendable (Conductor, Bool) -> Void) -> Entry {
        Entry(id: id, title: title, page: page, under: under, does: does, says: says, who: who,
              kind: .toggle,
              read: { toggleValue(get($0)) },
              write: { c, v in
                  guard let on = parseToggle(v) else { return false }
                  set(c, on)
                  return get(c) == on
              })
    }
}
