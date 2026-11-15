import Foundation

/// What Moe has spent, and what it will cost you when it runs out.
///
/// **Source:** `token-usage.py`, over `~/.hermes/state.db`'s `sessions`
/// table — every column one `agent/insights.py` already reads. `hermes
/// insights` computes the same numbers, prints them in a box-drawing table
/// with no `--json`, and takes several seconds doing charts nobody asked
/// for.
///
/// Four things measured on this Mac on 2026-09-04, each of which changes
/// what an honest screen can say.
///
/// **"Total tokens" is not what you and Moe wrote.** Thirty days here:
/// 1.6M input and 900k output against 194M of cache read. `hermes
/// insights` adds all four and prints "Total tokens: 216,847,032", which
/// reads like a bill and is almost entirely the same context arriving
/// again on every turn. The two are kept apart here and never summed.
///
/// **Almost none of it is metered, and that is recorded rather than
/// guessed.** 708 of 776 sessions carry `cost_status = "included"` against
/// `claude-code-subscription`: the Claude plan paid for them, per turn,
/// already. 32 carry `"estimated"` against DeepSeek and hold the only real
/// money on this Mac — 56 cents. 36 carry no status and have zero tokens,
/// which is a session that never took a turn, not a cost nobody knows.
///
/// **§4.4's own worry is fixed and this file says so.** It says the
/// auxiliary lanes are all `auto`, so title generation records `$0.00`
/// against an "unknown" billing route. Measured now: those lanes are named
/// (`deepseek-v4-pro`, `deepseek-v4-flash`), their provider is `deepseek`,
/// their status is `estimated`, and they are where the dollars are. The §6
/// config audit closed it.
///
/// **Cost per tool cannot be computed.** §4.4 asks for "which tools cost
/// most". Hermes attributes tokens to a session and to nothing smaller —
/// there is no per-tool token column anywhere in `state.db` — so what
/// comes back is how often each tool ran, under a key called `calls`, and
/// the pane says which of the two it is showing.
///
/// Everything here blocks on a subprocess. Call it off the main thread.
enum Usage {

    // MARK: - What comes back
    //
    // Every key below is read with `decodeIfPresent`. Swift's synthesised
    // `Decodable` throws `keyNotFound` for a missing key rather than
    // falling back to the property's default, and one absent key takes the
    // whole answer with it — measured on this repo on 2026-09-04, where
    // adding a single `var error = ""` turned every success into "Moe
    // couldn't reach…". `token-usage.py` fills every key on every path
    // too; one half would do today, two is what survives either end
    // changing.

    /// The counts, added up over the window.
    struct Totals: Decodable, Equatable {
        var sessions = 0
        var messages = 0
        var toolCalls = 0
        var apiCalls = 0
        /// Input plus output — what you and Moe actually said.
        var written = 0
        /// Cache read plus cache write — the same context arriving again,
        /// turn after turn. Never added to `written`: on this Mac it is 98
        /// per cent of the tokens and none of the conversation.
        var readBack = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0

        enum CodingKeys: String, CodingKey {
            case sessions, messages, written, input, output, reasoning
            case toolCalls = "tool_calls", apiCalls = "api_calls"
            case readBack = "read_back", cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = c.usageValue(.sessions, 0)
            messages = c.usageValue(.messages, 0)
            toolCalls = c.usageValue(.toolCalls, 0)
            apiCalls = c.usageValue(.apiCalls, 0)
            written = c.usageValue(.written, 0)
            readBack = c.usageValue(.readBack, 0)
            input = c.usageValue(.input, 0)
            output = c.usageValue(.output, 0)
            cacheRead = c.usageValue(.cacheRead, 0)
            cacheWrite = c.usageValue(.cacheWrite, 0)
            reasoning = c.usageValue(.reasoning, 0)
        }
        init() {}
    }

    /// The three buckets, which is what "cost" honestly is here.
    struct Money: Decodable, Equatable {
        /// Real money, for the lanes billed per token.
        var meteredUSD = 0.0
        var metered = 0
        /// Sessions the Claude plan already paid for.
        var included = 0
        /// Sessions with no billing status at all. On this Mac all 36 of
        /// them have zero tokens — a session that never took a turn — so
        /// the token count travels beside the number, and the pane only
        /// worries when it is not zero.
        var unknown = 0
        var unknownTokens = 0
        /// What a provider actually charged, where one told us. Nothing
        /// on this Mac ever has, which is worth showing as zero rather
        /// than hiding: it is the difference between an estimate and a bill.
        var actualUSD = 0.0
        /// Split by bucket, never pooled. One list put `deepseek` — the
        /// only thing on this Mac that charges money — into the sentence
        /// under "covered by a plan you already pay for", because a list
        /// printed beneath a row can only be read as belonging to it.
        /// Found by rendering.
        var planProviders: [String] = []
        var meteredProviders: [String] = []

        enum CodingKeys: String, CodingKey {
            case metered, included, unknown
            case meteredUSD = "metered_usd", unknownTokens = "unknown_tokens"
            case actualUSD = "actual_usd"
            case planProviders = "plan_providers"
            case meteredProviders = "metered_providers"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            meteredUSD = c.usageValue(.meteredUSD, 0.0)
            metered = c.usageValue(.metered, 0)
            included = c.usageValue(.included, 0)
            unknown = c.usageValue(.unknown, 0)
            unknownTokens = c.usageValue(.unknownTokens, 0)
            actualUSD = c.usageValue(.actualUSD, 0.0)
            planProviders = c.usageValue(.planProviders, [])
            meteredProviders = c.usageValue(.meteredProviders, [])
        }
        init() {}
    }

    struct Day: Decodable, Equatable, Identifiable {
        var day = ""
        var sessions = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var usd = 0.0

        var id: String { day }
        var written: Int { input + output }

        enum CodingKeys: String, CodingKey {
            case day, sessions, input, output, usd
            case cacheRead = "cache_read", cacheWrite = "cache_write"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = c.usageValue(.day, "")
            sessions = c.usageValue(.sessions, 0)
            input = c.usageValue(.input, 0)
            output = c.usageValue(.output, 0)
            cacheRead = c.usageValue(.cacheRead, 0)
            cacheWrite = c.usageValue(.cacheWrite, 0)
            usd = c.usageValue(.usd, 0.0)
        }
        init() {}
    }

    struct Model: Decodable, Equatable, Identifiable {
        var model = ""
        var sessions = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var usd = 0.0
        /// Hermes's own word: `included`, `estimated`, `mixed`, or empty.
        /// Read from the rows rather than derived from the model name —
        /// `sonnet` is included on a subscription Mac and metered on one
        /// paying per token, and a pane that decided from the name would
        /// be wrong on one of them without ever saying which.
        var status = ""
        var provider = ""

        var id: String { model.isEmpty ? "—" : model }
        var written: Int { input + output }

        enum CodingKeys: String, CodingKey {
            case model, sessions, input, output, usd, status, provider
            case cacheRead = "cache_read", cacheWrite = "cache_write"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = c.usageValue(.model, "")
            sessions = c.usageValue(.sessions, 0)
            input = c.usageValue(.input, 0)
            output = c.usageValue(.output, 0)
            cacheRead = c.usageValue(.cacheRead, 0)
            cacheWrite = c.usageValue(.cacheWrite, 0)
            usd = c.usageValue(.usd, 0.0)
            status = c.usageValue(.status, "")
            provider = c.usageValue(.provider, "")
        }
        init() {}
    }

    struct Source: Decodable, Equatable, Identifiable {
        var source = ""
        var sessions = 0
        var messages = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var usd = 0.0

        var id: String { source.isEmpty ? "—" : source }
        var written: Int { input + output }

        enum CodingKeys: String, CodingKey {
            case source, sessions, messages, input, output, usd
            case cacheRead = "cache_read"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = c.usageValue(.source, "")
            sessions = c.usageValue(.sessions, 0)
            messages = c.usageValue(.messages, 0)
            input = c.usageValue(.input, 0)
            output = c.usageValue(.output, 0)
            cacheRead = c.usageValue(.cacheRead, 0)
            usd = c.usageValue(.usd, 0.0)
        }
        init() {}
    }

    /// How often a tool ran. **Calls, never cost** — see the note at the
    /// head of this file.
    struct Tool: Decodable, Equatable, Identifiable {
        var tool = ""
        var calls = 0
        var id: String { tool }

        enum CodingKeys: String, CodingKey { case tool, calls }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tool = c.usageValue(.tool, "")
            calls = c.usageValue(.calls, 0)
        }
        init() {}
    }

    /// Whether Moe has ever told you it was near a limit.
    ///
    /// `checked` is the honest half. False means the log could not be read
    /// at all, and `seen == false` then means nothing — a screen that drew
    /// "you have never been near a limit" over a log it could not open
    /// would be making that up.
    struct Warning: Decodable, Equatable {
        var seen = false
        var at = ""
        var text = ""
        var log = ""
        var checked = false

        enum CodingKeys: String, CodingKey { case seen, at, text, log, checked }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seen = c.usageValue(.seen, false)
            at = c.usageValue(.at, "")
            text = c.usageValue(.text, "")
            log = c.usageValue(.log, "")
            checked = c.usageValue(.checked, false)
        }
        init() {}
    }

    /// The whole answer. `ok == false` carries `error`; `missing` with
    /// `ok` is a Mac where Hermes has not started, which has spent nothing
    /// — a different and far less alarming thing than "I could not look".
    struct Report: Decodable, Equatable {
        var ok = false
        var error = ""
        var days = 30
        var db = ""
        var missing = true
        var totals = Totals()
        var money = Money()
        var daily: [Day] = []
        var models: [Model] = []
        var sources: [Source] = []
        var tools: [Tool] = []
        /// How many distinct tools ran, of which `tools` lists the top
        /// few. Stated rather than the list simply stopping.
        var toolsTotal = 0
        var warning = Warning()

        enum CodingKeys: String, CodingKey {
            case ok, error, days, db, missing, totals, money, daily
            case models, sources, tools, warning
            case toolsTotal = "tools_total"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.usageValue(.ok, false)
            error = c.usageValue(.error, "")
            days = c.usageValue(.days, 30)
            db = c.usageValue(.db, "")
            missing = c.usageValue(.missing, true)
            totals = c.usageValue(.totals, Totals())
            money = c.usageValue(.money, Money())
            daily = c.usageValue(.daily, [])
            models = c.usageValue(.models, [])
            sources = c.usageValue(.sources, [])
            tools = c.usageValue(.tools, [])
            toolsTotal = c.usageValue(.toolsTotal, 0)
            warning = c.usageValue(.warning, Warning())
        }
        init() {}
    }

    // MARK: - Running it

    /// `~/.moe/hermes/token-usage.py` — installed, then the app's own
    /// copy, then the checkout. The ladder every other reader here uses:
    /// the middle rung is what keeps a home whose payload copy failed from
    /// showing an empty screen with no explanation.
    static func scriptPath() -> String? {
        var candidates = [Paths.home.appendingPathComponent("hermes/token-usage.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes/token-usage.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes/token-usage.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Asked with `BrainSetup.python()` — Moe's own interpreter, and never
    /// the system `python3`, which without developer tools is a stub that
    /// puts up an install dialog.
    ///
    /// `token-usage.py` is still stdlib-only on purpose — no PyYAML, nothing
    /// imported out of Hermes — so that any real interpreter can run it:
    /// `BrainSetup.python()` falls back to one when Moe's own is broken and
    /// the Mac has developer tools, which is the most that can be offered
    /// without risking that dialog.
    static func report(days: Int = 30, tools: Int = 12) -> Report? {
        guard let script = scriptPath() else { return nil }
        // Joined, for the same reason `Chats.askIndex` joins its own: one
        // spelling for every argument this repo hands argparse, so nobody
        // has to remember which of them can carry a leading hyphen.
        let r = ScriptRunner.run(BrainSetup.python(),
                                 [script, "usage", "--days=\(days)", "--tools=\(tools)"],
                                 timeout: 30)
        guard let data = Chats.jsonPart(r.output) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    // MARK: - Words

    /// "1.6M", "194M", "907". A settings pane is read, not audited: nine
    /// digits with separators in them is a number nobody parses.
    static func compact(_ n: Int) -> String {
        let value = Double(n)
        switch abs(n) {
        case 1_000_000_000...:
            return trim(value / 1_000_000_000) + "B"
        case 1_000_000...:
            return trim(value / 1_000_000) + "M"
        case 10_000...:
            return trim(value / 1_000) + "k"
        default:
            return grouped(n)
        }
    }

    private static func trim(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Money, and never a rounding that hides a real charge. `$0.56` is
    /// fine; `$0.00` over four cents is the dishonesty Hermes's own
    /// `format_cost_label` exists to avoid, so anything under a cent is
    /// said in words instead of rounded to nothing.
    static func dollars(_ usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 0.01 { return "under a cent" }
        if usd < 1 { return String(format: "$%.2f", usd) }
        return String(format: "$%.2f", usd)
    }

    /// Hermes's `source` column, said to a person. These are where a turn
    /// came FROM, not which model answered it.
    static func where_(_ source: String) -> String {
        switch source {
        case "api_server": return "The app on this Mac"
        case "cron": return "Things on a clock"
        case "subagent": return "Work Moe handed to itself"
        case "cli": return "The command line"
        case "": return "Somewhere unrecorded"
        default: return ReminderChannels.title(for: source)
        }
    }

    /// Hermes's `cost_status`, said to a person.
    static func billing(_ status: String) -> String {
        switch status {
        case "included": return "Covered by your plan"
        case "estimated": return "Billed per token"
        case "mixed": return "Some covered, some billed"
        case "": return "No billing recorded"
        default: return status
        }
    }

    /// "Today", "Yesterday", "Tuesday", "12 August" — from the `YYYY-MM-DD`
    /// the script writes in local time.
    static func day(_ text: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: text) else { return text }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let out = DateFormatter()
        // Inside the last week a weekday is what a person recognises;
        // beyond it a weekday is ambiguous and a date is not. The same
        // rule `Activity.day` follows, because two screens disagreeing
        // about what to call Tuesday is how a person stops trusting both.
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: Date())).day, days < 7 {
            out.dateFormat = "EEEE"
        } else {
            out.dateFormat = "d MMMM"
        }
        return out.string(from: date)
    }
}

/// One key, or the fallback — never a thrown `keyNotFound` that takes the
/// whole answer with it. See the note on `Chats.chatsValue`; this is the
/// same tool under a fifth name, because a module may not declare two
/// `value(_:_:)` on `KeyedDecodingContainer`.
private extension KeyedDecodingContainer {
    func usageValue<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
