import AppKit
import Foundation

// The Connections screen's data: what can be connected, what is, and how.
//
// Moe's connections are Hermes's connections (CONNECTORS.md): the catalog and
// the connected state come from the two scripts that already know —
// connectors/hermes-catalog.py (what exists) and hermes-connections.py (what
// is set up, with real checks) — plus the Mac-native connectors' own
// `status` lines. The app never reads ~/.hermes itself, and every connect
// or disconnect goes through scripts/connect.sh, so the terminal and the
// screen can never disagree about what "connected" means.
//
// House rule, enforced by scripts/test-connections-ui.sh: nothing here
// shows the user an engine or protocol word. A service "signs in", a key is
// "pasted", a permission is "needed".

/// One row on the screen.
struct Connection: Identifiable, Equatable {
    /// `composio` is a service reached through the Composio broker — Gmail,
    /// Drive, Calendar and ~500 more behind one MCP server. It is its own
    /// kind rather than `.mcp` because a person connects the SERVICE, not
    /// the server: one broker row called "composio" sitting beside Gmail
    /// would be true and useless.
    enum Kind: String { case mac, mcp, skill, platform, composio }

    /// What clicking Connect does.
    enum AuthKind: String {
        case oauth          // sign in in the browser; the script prints the URL
        case oneClick       // one button; the script drives it (the Telegram bot)
        case apiKey         // paste one or more keys (platforms: plus who may talk to Moe)
        case none           // nothing to enter; the script just sets it up
        case macPermission  // a System Settings pane
        case appPassword    // Gmail: an address and an app password, in a sheet
        case consent        // off until the user turns it on: one click, revocable
        case terminal       // interactive on purpose (a texted code): opened in Terminal
        // A QR code, drawn in the sheet. The script emits `QR=<payload>` and
        // the sheet renders it (MachineLine.qr → the .qr phase), so nothing
        // opens a Terminal. Kept separate from `oneClick` rather than folded
        // into it: oneClick's copy is Telegram's throughout ("Finish in
        // Telegram…", "make the bot yourself in Telegram and paste its key"),
        // and putting those words on a WhatsApp sheet is the same mistake as
        // the one this file's own note at `humanDetail` was written about.
        case scan
    }

    enum State: String { case connected, notConnected, needsAttention, unavailable }

    let id: String              // "<kind>/<name>", the connections script's key
    let kind: Kind
    let name: String
    let label: String
    let blurb: String           // catalog text, squashed to one line already; shown as plain Text
    let authKind: AuthKind
    var state: State
    var detail: String          // the status line's explanation, in the user's words
    let envKeys: [String]
    /// Platforms: the env name listing who may talk to Moe there, or "".
    let allowedUsersKey: String
    /// Per-key wording from the catalog ("Telegram bot token"), when it has some.
    let prompts: [String: String]
    /// Where to get the key / read about the service. https only (the catalog filters).
    let docs: String
    /// What `connect.sh` takes ("skill/notion", "platform/telegram", "linear").
    let connectName: String
    /// Mac-native only: the connect-*.sh to open in Terminal, if any.
    let setupScript: String
    /// Exotic: folded under the "Advanced" disclosure at the bottom.
    var advanced: Bool = false
    /// Listed when nobody has typed a search, or only found by typing its
    /// name. **False is not "hidden"** — the row exists, search finds it,
    /// Connect works, and if it is connected it sits at the top under
    /// "Yours" like anything else. It is the difference between a shop's
    /// shelves and its stockroom.
    ///
    /// Only the brokered services set it to false, and only where Composio
    /// does not hold the sign-in (`docs/COMPOSIO.md`). 1,378 services with
    /// 1,259 of them behind a search is a list; 1,378 on the shelves is a
    /// phone book, and the owner reading it said so.
    ///
    /// Defaults to `true`, so every other kind — and a catalog script older
    /// than this app, which sends no such field — is listed exactly as
    /// before. An absent flag must never empty this screen.
    var featured: Bool = true
    /// How popular the service is, 0–100, from `composio-ranking.json` —
    /// the order the shelves show it in, most used first. Never drawn: the
    /// owner asked for the popular ones on top, not for a visible ranking.
    /// 0 for everything the ranking does not cover.
    var rank: Int = 0
    /// A brokered service with nothing to sign in to — on for everyone.
    var isAlwaysOn: Bool { kind == .composio && authKind == .none }
    /// "personal" or "business": which shelf a listed brokered row sits on.
    var shelf: String = ""
    /// Other ways to connect the same brand, offered inside this row's
    /// sheet ("Also read my Telegram chats"). Each is a full row of its own.
    var alternates: [Connection] = []

    /// One sign-in behind a service. Most people have one; plenty have two
    /// — a personal Google and a work one — and before this the screen could
    /// not say so, because the row carried a single yes/no.
    struct Account: Equatable, Identifiable {
        let id: String            // Composio's account id; what Disconnect takes
        var who: String           // what the person called it, or "" if unnamed
        var status: String        // ACTIVE / EXPIRED / INITIATED …
        var live: Bool { status == "ACTIVE" }
    }

    /// The sign-ins behind this row. Empty for everything that has exactly
    /// one by construction, which is every kind except `.composio` today.
    var accounts: [Account] = []

    /// A brokered service whose cleanup at the broker is still pending
    /// (`composio.py list` → `cleanup_pending`). Keeps Disconnect on the row
    /// even when nothing is connected: Disconnect is how that cleanup is
    /// retried, and the message saying so used to name a button that a
    /// not-connected row did not have.
    var cleanupPending: Bool = false

    /// Moe's own email address, for the Email row's Copy button (slice G3):
    /// `name@in.moebot.app`, from `hermes-connections.py`'s `address`. Empty
    /// for every other row, and for Email until a name is chosen.
    var address: String = ""

    /// How many of them actually work. The row says "2 accounts" from this,
    /// never from `accounts.count` — a dead sign-in beside a live one must
    /// not be counted as a second way in.
    var liveAccounts: Int { accounts.filter(\.live).count }

    /// The detail a Mac source carries when its check did not answer in
    /// time. Not a verdict about the source, so the screen says "Couldn't
    /// check" rather than "Not available yet".
    static let couldNotCheckWords = "Didn't answer in time — press Check again."
    var couldNotCheck: Bool { state == .unavailable && detail.hasPrefix("Didn't answer") }

    /// What an `unavailable:` row says instead of "Not available yet", or
    /// nil when that generic line is the right one.
    ///
    /// "Not available yet" is true of a brokered service this Mac's account
    /// cannot have: it really is not out for them. It is never true of a Mac
    /// source — WhatsApp, Calendar, Notes and the rest are all right here —
    /// and their `unavailable:` line is a sentence about this minute ("Moe
    /// is starting your WhatsApp link"). Dropping it for "Not available yet"
    /// told a person who had just scanned a code that Moe does not do
    /// WhatsApp yet.
    var unavailableWords: String? {
        guard state == .unavailable, kind == .mac, !couldNotCheck, !detail.isEmpty else { return nil }
        return detail
    }

    /// Which way this connection points, and why that earns two screens.
    ///
    /// One list was answering two different questions — "what can Moe reach"
    /// and "where can I reach Moe" — and a person looking for the second was
    /// reading eighty rows of the first. A **platform** is a place a person
    /// starts a conversation Moe answers: they text it and Moe replies.
    /// Everything else — a Mac source, an MCP server, a skill with a
    /// credential — is something Moe reaches out to while answering.
    ///
    /// `kind` is the whole test and deliberately so: `kind == .platform`
    /// comes from Hermes's own platform list, so a platform Hermes adds
    /// appears on the right screen without this file learning its name.
    /// The rule for connections is bridge the catalogue, never curate it.
    var isInbound: Bool { kind == .platform }

    /// The human name for an env key when the catalog gave none:
    /// STRIPE_API_KEY → "Stripe API key".
    static func humanKey(_ key: String) -> String {
        if let special = specialKeys[key] { return special }
        let acronyms: Set<String> = ["API", "URL", "ID", "SMS", "IMAP", "SMTP", "HTTP", "QQ", "TLS"]
        let words = key.split(separator: "_").map(String.init)
        var out: [String] = []
        for (i, w) in words.enumerated() {
            if acronyms.contains(w) { out.append(w); continue }
            let low = w.lowercased()
            out.append(i == 0 ? low.prefix(1).uppercased() + low.dropFirst() : low)
        }
        return humaniseLabel(out.joined(separator: " "))
    }

    /// Keys whose mechanical name reads badly.
    static let specialKeys: [String: String] = [
        "MSGRAPH_TENANT_ID": "Your Microsoft tenant (ask IT)",
        "MSGRAPH_CLIENT_ID": "Your Microsoft client ID (ask IT)",
        "MSGRAPH_CLIENT_SECRET": "Your Microsoft client secret (ask IT)",
        "TELEGRAM_BOT_TOKEN": "The key BotFather gave you",
        "DISCORD_BOT_TOKEN": "The key Discord gave you",
        "SLACK_BOT_TOKEN": "The key Slack gave you",
        "SLACK_APP_TOKEN": "The app-level key Slack gave you",
        "EMAIL": "Your email address",
        "PASSWORD": "Password",
        "PHONE": "Your phone number, with country code",
    ]

    /// Wording fixes for labels the catalog or the key name produced:
    /// engine names → the brand, jargon → what a person calls it.
    static func humaniseLabel(_ label: String) -> String {
        var s = label
        let swaps: [(String, String)] = [
            // Composio's display names for a pasted field ("Firecrawl Api
            // Key", "Api Token"): the sheet says "key", like every other.
            ("Api Key", "key"), ("API Key", "key"), ("Api Token", "key"), ("API Token", "key"),
            ("Msgraph", "Microsoft"), ("MSGraph", "Microsoft"), ("MS Graph", "Microsoft"),
            ("SA JSON", "service account file"), ("SA json", "service account file"),
            ("service account JSON", "service account file"),
            ("Tenant ID", "Your Microsoft tenant (ask IT)"), ("tenant ID", "tenant (ask IT)"),
            ("API key", "key"), ("API token", "key"), ("access token", "key"),
            ("Bot token", "Bot key"), ("bot token", "bot key"), ("Token", "Key"), ("token", "key"),
            ("Api ", "API "), (" Url", " address"), (" URL", " address"),
        ]
        for (from, to) in swaps { s = s.replacingOccurrences(of: from, with: to) }
        return s
    }

    func fieldLabel(_ key: String) -> String {
        if let special = Self.specialKeys[key] { return special }
        if let p = prompts[key] { return Self.humaniseLabel(p) }
        return Self.humanKey(key)
    }

    /// The one field a script asks for mid-flow (`NEED=<field>`), worded for
    /// the person typing it.
    static func promptLabel(field: String, brand: String) -> String {
        switch field.lowercased() {
        case "code": return "The code \(brand) just sent you"
        case "password": return "Your two-step password"
        case "phone": return "Your phone number, with country code"
        case "email": return "Your email address"
        case "label": return "A name for this account (optional)"
        case "api_id": return "Your Telegram app ID (from my.telegram.org)"
        case "api_hash": return "Your Telegram app hash (from my.telegram.org)"
        default: return humanKey(field.uppercased())
        }
    }

    /// The keys the sheet asks for: every credential, then the allowed-users
    /// field for a platform. Names Hermes's installer treats as flags are
    /// skipped (connect.sh does the same).
    var askedKeys: [String] {
        var keys = envKeys.filter { !$0.hasSuffix("_ALLOW_ALL_USERS") && !$0.hasSuffix("_ENABLED") && !$0.contains(".") }
        if !allowedUsersKey.isEmpty { keys.append(allowedUsersKey) }
        return keys
    }

    static func isSecret(_ key: String) -> Bool {
        for w in ["TOKEN", "SECRET", "KEY", "PASSWORD", "PRIVATE"] where key.contains(w) { return true }
        return false
    }

    /// The System Settings pane a Mac-native "needs-setup" line points at.
    /// The connector scripts say which grant they lack in plain words; this
    /// maps those words to the pane, so the button opens the right one.
    var settingsPaneURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        // By what the source is, first: the grant it needs never changes.
        if kind == .mac {
            switch name {
            // Chrome's history and Drive's synced folder both sit under
            // another app's directory: Full Disk Access territory.
            case "imessage", "mail", "calls", "call-recordings", "chrome", "drive": return URL(string: base + "Privacy_AllFiles")
            case "notes", "calendar", "reminders": return URL(string: base + "Privacy_Automation")
            case "contacts": return URL(string: base + "Privacy_Contacts")
            default: break
            }
        }
        let low = detail.lowercased()
        if low.contains("full disk") { return URL(string: base + "Privacy_AllFiles") }
        if low.contains("automation") { return URL(string: base + "Privacy_Automation") }
        if low.contains("reminders") { return URL(string: base + "Privacy_Reminders") }
        if low.contains("calendar") { return URL(string: base + "Privacy_Calendars") }
        if low.contains("contacts") { return URL(string: base + "Privacy_Contacts") }
        return nil
    }

    /// The grant is Full Disk Access — the one that needs a relaunch after.
    var needsFullDiskAccess: Bool { settingsPaneURL?.absoluteString.hasSuffix("Privacy_AllFiles") == true }
}

// MARK: - Machine lines

/// What a connect script tells the app on stdout, one line each. Anything
/// else is text for a person. Parsed by a pure function so the test suite
/// can drive it (`Moe --connections-json --parse-machine-lines`).
enum MachineLine: Equatable {
    case signInURL(URL)          // open in the browser, once
    case need(String)            // the script waits for `<FIELD>=value` on stdin
    case needsRestart(String)    // after exit 0, restart what it names ("gateway")
    case qr(String)              // render this payload as a QR code
    /// The code was scanned and the service said yes. Everything after it —
    /// a phone sending its history, a gateway restarting — is Moe's work,
    /// not the person's, and it can take minutes. Without this the sheet
    /// held a dead QR code for all of them.
    case linked

    static let prefixes = ["SIGN_IN_URL=", "NEED=", "NEEDS_RESTART=", "QR=", "LINKED="]

    /// A sign-in page is https, or the app's own loopback callback.
    static func isOpenable(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        return url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }

    static func parse(_ raw: String) -> MachineLine? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("SIGN_IN_URL=") {
            guard let url = URL(string: String(line.dropFirst("SIGN_IN_URL=".count))), isOpenable(url) else { return nil }
            return .signInURL(url)
        }
        if line.hasPrefix("NEED=") {
            let field = String(line.dropFirst("NEED=".count)).trimmingCharacters(in: .whitespaces)
            guard !field.isEmpty, field.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            return .need(field)
        }
        if line.hasPrefix("NEEDS_RESTART=") {
            let what = String(line.dropFirst("NEEDS_RESTART=".count)).trimmingCharacters(in: .whitespaces)
            return what.isEmpty ? nil : .needsRestart(what)
        }
        if line.hasPrefix("QR=") {
            let payload = String(line.dropFirst("QR=".count))
            return payload.isEmpty ? nil : .qr(payload)
        }
        // The value is only ever "1"; the line's arrival is the whole of it.
        if line.hasPrefix("LINKED=") {
            return line.dropFirst("LINKED=".count).trimmingCharacters(in: .whitespaces).isEmpty ? nil : .linked
        }
        return nil
    }

    static func isMachine(_ line: String) -> Bool { prefixes.contains { line.hasPrefix($0) } }

    var json: [String: String] {
        switch self {
        case .signInURL(let u): return ["type": "sign_in_url", "value": u.absoluteString]
        case .need(let f): return ["type": "need", "value": f]
        case .needsRestart(let w): return ["type": "needs_restart", "value": w]
        case .qr(let p): return ["type": "qr", "value": p]
        case .linked: return ["type": "linked", "value": "1"]
        }
    }
}

/// One thing to paste for a brokered service Composio holds no sign-in
/// for, in the service's own terms (`composio.py fields` →
/// `connect.sh --fields composio/<slug>`): the field name Composio's record
/// gives it, worded for a person, and where to find it.
struct KeyField: Equatable, Identifiable {
    /// The answer's key on connect.sh's stdin: the field name, upper-cased
    /// (`api_key` → `API_KEY`), which is how every other paste flow's
    /// answers are spelt and what connect.sh asks `ask_value` for.
    let key: String
    let label: String
    /// Composio's description of the field — usually the page it is on.
    let help: String
    let secret: Bool
    var id: String { key }

    /// The JSON `composio.py fields` prints: {"scheme", "managed",
    /// "fields": [{"name", "label", "help", "secret", "required", "stage"}],
    /// "help_url"}. Empty fields mean "nothing to paste" — the caller says
    /// why, using `managed`.
    static func parse(_ data: Data) -> (fields: [KeyField], helpURL: String, managed: Bool) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], "", false) }
        let managed = (obj["managed"] as? Bool) ?? false
        var url = (obj["help_url"] as? String) ?? ""
        if URL(string: url)?.scheme != "https" { url = "" }
        let fields = ((obj["fields"] as? [[String: Any]]) ?? []).compactMap { f -> KeyField? in
            guard let name = f["name"] as? String, !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
            // Composio's display names read "Firecrawl Api Key"; the sheet
            // says "key" the way every other paste field here does
            // (humaniseLabel carries the swap).
            var label = Connection.humaniseLabel((f["label"] as? String) ?? name)
            if label.trimmingCharacters(in: .whitespaces).isEmpty { label = Connection.humanKey(name.uppercased()) }
            return KeyField(key: name.uppercased().replacingOccurrences(of: "-", with: "_"),
                            label: label,
                            help: Connection.humaniseLabel((f["help"] as? String) ?? ""),
                            // Blind unless the record says it is not a secret:
                            // composio.py marks every field secret but a short
                            // list of plain names, and no flag means the same.
                            secret: (f["secret"] as? Bool) ?? true)
        }
        return (fields, url, managed)
    }
}

/// Someone messaged Moe's bot and is waiting to be let in
/// (`hermes-connections.py --json` → `pending_pairings`).
struct Pairing: Identifiable, Equatable {
    let platform: String
    /// "<platform>/<request_id>" — unique across platforms for the list.
    let id: String
    let name: String
    /// "3 minutes ago", from `age_minutes`; "" when the script gave none.
    let when: String

    /// The shape hermeslib.pending_pairings writes: platform, request_id
    /// (16 hex characters — the only thing pairing.sh approve accepts from
    /// the app), user_name, user_id, age_minutes, created_at. A name is
    /// whatever the stranger typed on the platform: one line, capped, and
    /// only ever rendered as plain text.
    static func parse(_ v: Any?) -> [Pairing] {
        guard let list = v as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let platform = p["platform"] as? String, !platform.isEmpty,
                  platform.allSatisfy({ ($0.isASCII && $0.isLetter && $0.isLowercase) || ($0.isASCII && $0.isNumber) || $0 == "_" })
            else { return nil }
            guard let rid = p["request_id"] as? String, rid.count == 16, rid.allSatisfy(\.isHexDigit) else { return nil }
            let name = (p["user_name"] as? String ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            var when = ""
            if let m = (p["age_minutes"] as? NSNumber)?.intValue {
                when = m <= 0 ? "just now" : (m == 1 ? "a minute ago" : (m < 60 ? "\(m) minutes ago" : (m < 120 ? "an hour ago" : "\(m / 60) hours ago")))
            }
            return Pairing(platform: platform, id: "\(platform)/\(rid.lowercased())",
                           name: name.isEmpty ? "Someone" : String(name.prefix(60)), when: when)
        }
    }

    /// The request id the pairing script takes (without the platform prefix).
    var rawID: String { String(id.dropFirst(platform.count + 1)) }
    var platformLabel: String {
        if isSlackInstall { return "Slack" }
        // A hello waiting at a channel Moe's cloud holds (`cloud_telegram`).
        if platform.hasPrefix("cloud_") { return ConnectionsCatalog.label(for: String(platform.dropFirst(6))) }
        return ConnectionsCatalog.label(for: platform)
    }
    /// Not a stranger at all: an Add to Slack for Moe's own Slack app, already
    /// proved with a Google sign-in on the install page and waiting for this
    /// Mac's word as well — the second layer, never the only one
    /// (`hermes-connections.py` `slack_install_pairings`). `name` is "Slack workspace <name> as <Slack
    /// name>", and Approve runs `pairing.sh approve slack_link <id>`.
    var isSlackInstall: Bool { platform == "slack_link" }
    /// The one line the banner asks.
    var question: String {
        isSlackInstall ? "\(name) wants to connect to Moe — confirm?"
                       : "Someone messaged Moe on \(platformLabel) — let them in?"
    }
}

// MARK: - Parsing

enum ConnectionsCatalog {
    /// The names shown first, in this order, when not yet connected.
    /// GitHub joined the catalog on 2026-09-06; before that GitLab and
    /// Atlassian stood in for it, which meant the row a person came looking
    /// for was the one row that was not there.
    ///
    /// **What an ordinary person uses first, then what work uses.** Until
    /// 2026-09-10 this was one list that led with Gmail and then went
    /// straight to Notion, Slack, GitHub, Linear and Stripe — a developer's
    /// Monday, not a person's. The owner asked for the consumer services up
    /// front, the popular business ones under them, and everything else
    /// after. So there are two lists and two headings.
    ///
    /// A brand is named by each route that can carry it (`composio/gmail`
    /// and `mac/gmail`, `composio/notion` and `mcp/notion`): which rows
    /// exist depends on the Mac, and the first one present wins its place —
    /// `sections` keeps one card per name in each group.
    ///
    /// **Composio first, wherever it covers the service** (decided
    /// 2026-09-11, docs/CHANNELS-CONNECTORS-DECISIONS.md §4). Until then the
    /// direct route led each pair — `mac/gmail` before `composio/gmail`,
    /// `mcp/notion` before `composio/notion` — so a NEW connect went to the
    /// app-password mailbox or a server that works only on this Mac. One
    /// sign-in through the broker works on the Mac and on the away machine
    /// alike, which the direct routes cannot promise. The direct route stays
    /// only where Composio cannot do the thing: Apple's apps, a person's own
    /// WhatsApp and Telegram, Chrome, calls, the Mac itself — none of which
    /// has a `composio/` twin here. A route someone has ALREADY connected is
    /// untouched by this order: a connected row sits under "Yours" before
    /// these shelves are dealt, whichever route it took.
    ///
    /// Gmail's pair is the exception to "order decides": it is in
    /// `brokerFold`, so `merge(mac:engine:)` folds `mac/gmail` into the
    /// `composio/gmail` row whenever both exist, before this list is read.
    /// Its position here only matters on a Mac with no broker row at all —
    /// swapping the two Gmail entries changes nothing a person sees.
    static let popular = [
        "composio/gmail", "mac/gmail", "composio/googlecalendar", "composio/googledrive",
        "composio/outlook", "platform/whatsapp", "platform/telegram",
        "composio/notion", "mcp/notion", "composio/dropbox", "mcp/dropbox",
        "composio/googledocs", "composio/googlesheets", "composio/googlephotos",
        "composio/one_drive", "composio/youtube", "composio/todoist", "mcp/todoist",
        "composio/zoom", "composio/instagram", "composio/linkedin", "composio/reddit",
        "composio/discord", "composio/canva", "composio/splitwise", "composio/ynab",
    ]

    /// The popular ones at work, shown under `popular`. Same rule: the
    /// broker's row leads its pair.
    static let work = [
        "platform/slack", "composio/slack", "skill/teams-meeting-pipeline", "composio/microsoft_teams",
        "composio/github", "mcp/github", "composio/linear", "mcp/linear",
        "composio/jira", "composio/confluence", "mcp/atlassian",
        "composio/asana", "composio/trello", "composio/clickup", "composio/airtable",
        "composio/hubspot", "composio/salesforce", "composio/stripe", "mcp/stripe",
        "composio/quickbooks", "composio/figma", "mcp/figma", "composio/miro",
        "composio/calendly", "composio/zendesk", "composio/intercom", "composio/box",
        "composio/gitlab", "mcp/gitlab",
    ]

    /// Cards per shelf. The ranking lists ~40 personal and ~130 business
    /// services before search; a shelf of 130 cards is a catalogue again.
    static let shelfSize = 36

    /// Scores, on the ranking's 0–100 scale, for the routes the Composio
    /// ranking cannot score: Moe's own channels and the direct twins of
    /// brokered services. A twin sits just under its broker row, so where
    /// both exist the broker keeps the card (one card per name).
    static let nativeRank: [String: Int] = [
        "mac/gmail": 99, "platform/whatsapp": 96, "platform/telegram": 84,
        "platform/slack": 92, "skill/teams-meeting-pipeline": 89,
        "mcp/notion": 80, "mcp/dropbox": 75, "mcp/todoist": 58,
        "mcp/github": 86, "mcp/linear": 55, "mcp/atlassian": 70,
        "mcp/stripe": 76, "mcp/figma": 74, "mcp/gitlab": 45,
    ]

    /// What is pushed first — docs/DEFAULTS.md row 34, slice 13: the Mac's
    /// own apps, in this order, then Google's three through the broker.
    /// Local plus Google is the "knows you" win on day one. Everything else
    /// (Messages, the other Mac sources, the shelves below) stays in the
    /// list under them. An explicit order rather than a reshuffle of
    /// `popular`: `Sections.macFirst` takes these four out of "Your Mac" in
    /// this order, `popular` already leads with the Google three, and
    /// `Sections.inOrder` is the one place the screen's order is written.
    ///
    /// `mac/contacts` was listed here for a day it had no row, and the
    /// welcome's "Calendar, Reminders, Notes and Contacts" was one ahead of
    /// the screen until 2026-09-16. It is a `MacSources` row now, of the
    /// same kind as Calendar: a macOS permission, read by `contacts.sh`.
    static let firstMac = ["mac/calendar", "mac/reminders", "mac/notes", "mac/contacts"]
    static let firstGoogle = ["composio/gmail", "composio/googlecalendar", "composio/googledrive"]
    static var firstConnections: [String] { firstMac + firstGoogle }
    /// The same order, in words, for the last first-run screen.
    static let firstMacWords = "Calendar, Reminders, Notes and Contacts"
    static let firstGoogleWords = "Gmail, Calendar and Drive"

    /// Catalog names that read badly as-is.
    static let labels: [String: String] = [
        "teams-meeting-pipeline": "Microsoft 365",
        "1password": "1Password",
        "hugging_face": "Hugging Face",
        "wordpress-com": "WordPress.com",
        "aws-knowledge": "AWS Knowledge",
        "microsoft-learn": "Microsoft Learn",
        "prisma-postgres": "Prisma Postgres",
        "twelve-data": "Twelve Data",
        "twilio-docs": "Twilio Docs",
        "unreal-engine": "Unreal Engine",
        "comfy-cloud": "Comfy Cloud",
        "gif-search": "GIF search",
        "paypal": "PayPal",
        "github": "GitHub",
        "gitlab": "GitLab",
        "clickup": "ClickUp",
        "wolfram": "Wolfram",
        "alltrails": "AllTrails",
        "deepwiki": "DeepWiki",
        "betterstack": "Better Stack",
        "circleci": "CircleCI",
        "motherduck": "MotherDuck",
        "n8n": "n8n",
    ]

    static func label(for name: String) -> String {
        if let l = labels[name] { return l }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    struct Parsed {
        var connections: [Connection]
        /// Set when the connected state could not be read at all (the
        /// connections script says so with a "hermes/config" line).
        var warning: String
        var pairings: [Pairing] = []
    }

    /// Names the catalog has not marked `advanced` yet but which no new
    /// user should meet before the Advanced disclosure.
    static let advancedNames: Set<String> = [
        "webhook", "bluebubbles", "weixin", "qqbot", "yuanbao", "buzz", "photon", "simplex",
        "a2a", "raft", "matrix", "mattermost", "xmpp", "irc",
    ]
    /// Duplicates of a row that already exists in a friendlier form.
    /// Never shown, whatever the catalog says. google-workspace is the
    /// retired Google OAuth path (CONNECTORS.md): hermes-catalog.py already
    /// skips it, and this is the second lock, for an installed ~/.moe whose
    /// catalog script is older than this app.
    static let hiddenNames: Set<String> = ["whatsapp_cloud", "google-workspace"]
    /// The chat apps "Ways to reach Moe" lists: the five the cloud carries,
    /// each verified to start with what the sheet collects
    /// (scripts/test-platform-credentials.sh). Decided with the owner on
    /// 2026-09-11 (docs/CHANNELS-CONNECTORS-DECISIONS.md §2). Hermes speaks
    /// twenty-odd more; hermes-catalog.py marks those `shown: false` and
    /// this set is the second lock, for an installed ~/.moe whose catalogue
    /// script predates the flag. Hidden is not removed: one somebody set up
    /// by hand still runs and still reports — it is just not offered here.
    /// scripts/test-connections-ui.sh requires this and SHOWN_PLATFORMS in
    /// hermes-catalog.py to be the same six.
    ///
    /// Signal is the sixth (docs/CHANNELS-CONNECTORS-DECISIONS.md §5b, slice
    /// G4): a QR scan like WhatsApp, and like WhatsApp it lives on the Mac
    /// that scanned it — the cloud does not carry it (docs/SIGNAL.md).
    static let shownPlatforms: Set<String> = ["telegram", "whatsapp", "signal", "slack", "discord", "line"]

    /// Brokered rows whose catalog label names a brand Moe already reaches
    /// another way, where the two are **not the same thing**. The broker's
    /// own description says which — and hermes-catalog.py's blurb, which is
    /// synthesised from the label for every one of ~1,400 services, throws
    /// that sentence away.
    ///
    /// WhatsApp is the one that has cost something. Composio's own words:
    /// *"Only supports WhatsApp Business accounts, not WhatsApp Personal
    /// accounts."* The row said "WhatsApp" and promised to read "your
    /// WhatsApp"; the owner read that as the connection that links this Mac
    /// to his own phone, and asked what had happened to it (2026-09-07).
    /// Nothing had — it is the row directly above — but two rows may not
    /// both be called WhatsApp when only one of them is his.
    static let brokerLabels: [String: String] = ["whatsapp": "WhatsApp Business"]
    static let brokerBlurbs: [String: String] = [
        // Kept under 120 characters: every blurb is one line on a card, and
        // scripts/test-connections-ui.sh holds that line.
        "whatsapp": "For a WhatsApp Business account — a company answering customers. Not your own chats; those are “WhatsApp on this Mac”.",
    ]

    /// The catalog's blurb, or a description with the engine words taken
    /// out — the Swift-side fallback for a catalog that has not sanitised.
    static func sanitiseBlurb(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"https?://[^\s)]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "Hermes", with: "Moe")
        // "via Stripe's hosted remote", "over its local MCP" — how, not what.
        s = s.replacingOccurrences(of: #"(?i)\s*\bvia [A-Za-z0-9.'’]+ hosted( remote)?"#, with: "", options: .regularExpression)
        // "… via the official remote MCP.", "… via curl + jq." — the whole
        // clause, to the end of its sentence.
        s = s.replacingOccurrences(of: #"(?i)\s*\bvia\b[^.;:]*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\s*\bover its local\b"#, with: "", options: .regularExpression)
        for word in ["MCP server", "MCP", "API", "stdio", "curl", "OAuth", "SSE", "HTTP", "JSON", "CLI", "SDK", "webhook", "remote"] {
            s = s.replacingOccurrences(of: #"(?i)(?<![A-Za-z])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![A-Za-z])"#,
                                       with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\(\s*[,;\s]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\(\s*[,;]\s*"#, with: "(", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:,")))
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        return s
    }

    /// The screen's groups. Pure, so `--connections-json` can print them.
    struct Sections {
        /// Things you set up that have since stopped working. Not things you
        /// never connected — those are simply not connected, and belong in
        /// the list with everything else.
        var attention: [Connection] = []
        var connected: [Connection] = []
        var mac: [Connection] = []
        var popular: [Connection] = []
        /// Popular at work — under `popular`, above everything else.
        var work: [Connection] = []
        var rest: [Connection] = []
        var advanced: [Connection] = []
        /// In the catalogue, connectable, findable by name — and not on the
        /// shelves. The screen renders every other group and never this one,
        /// which is the whole mechanism: a row moves out of here the moment
        /// someone types its name, connects it, or it needs them.
        ///
        /// It is in `ids` so `--connections-json` can be asked "where did
        /// Firecrawl go" and answer, rather than a service vanishing from
        /// the output and looking deleted.
        var searchOnly: [Connection] = []

        /// "Your Mac" in two parts: the four pushed first
        /// (`ConnectionsCatalog.firstMac`, in that order), drawn above the
        /// Google shelf, and the rest of the Mac's sources, drawn under it.
        var macFirst: [Connection] {
            ConnectionsCatalog.firstMac.compactMap { id in mac.first { $0.id == id } }
        }
        var macMore: [Connection] {
            mac.filter { !ConnectionsCatalog.firstMac.contains($0.id) }
        }
        /// Every listed row in the order the Connections screen draws it:
        /// what needs you, yours, the Mac's four, Google (the head of
        /// `popular`), then everything else. `searchOnly` is never drawn.
        var inOrder: [Connection] {
            attention + connected + macFirst + popular + macMore + work + rest + advanced
        }

        var ids: [String: [String]] {
            ["attention": attention.map(\.id),
             // `macFirst` is derived, and the derivation is the check: an id
             // in `firstMac` with no row behind it (Contacts, until
             // 2026-09-16) simply never appears here, silently.
             "macFirst": macFirst.map(\.id),
             "connected": connected.map(\.id), "mac": mac.map(\.id), "popular": popular.map(\.id),
             "work": work.map(\.id), "rest": rest.map(\.id), "advanced": advanced.map(\.id),
             "searchOnly": searchOnly.map(\.id)]
        }
    }

    /// The inbound screen's groups: the ways a person can reach Moe.
    ///
    /// Deliberately flatter than `Sections`. There are ~28 of these, not
    /// eighty, and none of them is "popular" in the sense a service is —
    /// a person has the apps they have. So: what is set up, what else is
    /// possible, and the exotic ones behind a disclosure.
    struct Reach {
        /// Set up and answering. Also the ones that need you: a platform
        /// with a credential but nobody paired cannot be reached yet, and
        /// that is the one thing worth saying loudly on this screen.
        var attention: [Connection] = []
        var connected: [Connection] = []
        var available: [Connection] = []
        var advanced: [Connection] = []
        var ids: [String: [String]] {
            ["attention": attention.map(\.id), "connected": connected.map(\.id),
             "available": available.map(\.id), "advanced": advanced.map(\.id)]
        }
        var isEmpty: Bool {
            attention.isEmpty && connected.isEmpty && available.isEmpty && advanced.isEmpty
        }
    }

    /// Group the inbound rows. Same search behaviour as `sections`, so the
    /// two screens feel like one app.
    static func reach(_ rows: [Connection], search: String = "") -> Reach {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var g = Reach()
        for c in rows where c.isInbound {
            guard q.isEmpty || c.label.lowercased().contains(q)
                    || c.name.lowercased().contains(q) || c.blurb.lowercased().contains(q)
            else { continue }
            if c.state == .connected { g.connected.append(c) }
            else if c.state == .needsAttention { g.attention.append(c) }
            else if c.advanced { g.advanced.append(c) }
            else { g.available.append(c) }
        }
        let byLabel: (Connection, Connection) -> Bool = {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        g.attention.sort(by: byLabel); g.connected.sort(by: byLabel)
        g.advanced.sort(by: byLabel)
        // What to try first, before the alphabet — ordered by how much work
        // it is to get talking, which is a different question from `popular`
        // and must not borrow its answer. `popular` ranks Slack above
        // Telegram because Slack is a big service to *reach*; here Telegram
        // wins outright, because it is the only way in that needs nothing but
        // a button (the managed bot), while Slack wants a bot token and an
        // app token. Borrowing `popular` led the screen with the hardest
        // option on a fresh Mac.
        g.available.sort {
            let a = Self.easiestWaysIn.firstIndex(of: $0.id)
            let b = Self.easiestWaysIn.firstIndex(of: $1.id)
            switch (a, b) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return byLabel($0, $1)
            }
        }
        return g
    }

    /// Ways in, easiest first. Telegram is one button; WhatsApp is a QR code
    /// on a phone; Discord is one token from its developer portal; Slack
    /// wants two; LINE wants two and the cloud. Signal is a QR code too, with
    /// a one-time download before it. Only `shownPlatforms` ever reach this
    /// sort, so the list is the six in that order.
    static let easiestWaysIn = [
        "platform/telegram", "platform/whatsapp", "platform/signal",
        "platform/discord", "platform/slack", "platform/line",
    ]

    /// - Parameter excludingInbound: drop the platforms, because they have
    ///   their own screen now (`reach`). Off by default so
    ///   `--connections-json`'s `sections` keeps meaning "every row,
    ///   grouped" — the shape the test suite pins — while the Connections
    ///   screen passes `true` and shows only what Moe reaches outward.
    static func sections(_ rows: [Connection], search: String = "",
                         excludingInbound: Bool = false) -> Sections {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = rows.filter { c in
            (!excludingInbound || !c.isInbound)
            && (q.isEmpty || c.label.lowercased().contains(q) || c.name.lowercased().contains(q) || c.blurb.lowercased().contains(q))
        }
        var g = Sections()
        for c in all {
            // A row whose OTHER route is the connected one — the
            // app-password mailbox folded inside the broker's Gmail row — is
            // a connection the person made, and it lives under "Yours" like
            // any other. Without this a connected mailbox sat on the Popular
            // shelf with no pill, because the fold had moved the connected
            // row inside one that was not; and since the broker's row now
            // leads its pair, that is exactly where every pre-existing
            // app-password mailbox would have gone.
            // An always-on brokered service (nothing to sign in to) is on
            // for everyone, not something this person connected: it stays
            // on the shelves, not under "Yours".
            if (c.state == .connected && !c.isAlwaysOn) || c.alternates.contains(where: { $0.state == .connected }) { g.connected.append(c) }
            // Before `advanced`, and before the alphabet. A server whose
            // sign-in never completed used to sort in among eighty services
            // nobody has connected, or fold into a collapsed Advanced group —
            // visible, in the sense that a word is visible in a dictionary.
            // Vercel sat like that for days while Moe silently had no Vercel
            // tools. Mac rows are excluded because a missing macOS permission
            // already has its own home and its own fix button in "Your Mac";
            // this section is for the things Moe reaches over the network.
            else if c.state == .needsAttention, c.kind != .mac { g.attention.append(c) }
            // Moe's cleanup at the broker is still pending, and nothing is
            // connected: always drawn, and where the person looks first.
            // composio.py's give-up message says "press Disconnect on it in
            // Connections" — and a non-featured row went to `searchOnly`,
            // which the screen never draws, so the button it named could not
            // be found (the sixth review, with `--connections-json`).
            else if c.cleanupPending { g.attention.append(c) }
            else if c.advanced { g.advanced.append(c) }
            // Popular is checked before .mac so Gmail — a Mac connector, but
            // the one thing most people come here to connect — is a card at
            // the top rather than a line in the "Your Mac" list.
            // A listed brokered row goes on the shelf its ranking names; the
            // hand lists still place the routes the ranking cannot know
            // (Moe's own WhatsApp and Telegram, the MCP twins, Mac Gmail).
            // A row the ranking placed is placed by it alone: Zoom in the
            // hand list under "popular" is business by its ranking.
            else if q.isEmpty, c.shelf.isEmpty ? popular.contains(c.id) : (c.featured && c.shelf == "personal") { g.popular.append(c) }
            else if q.isEmpty, c.shelf.isEmpty ? work.contains(c.id) : (c.featured && c.shelf == "business") { g.work.append(c) }
            // Off the shelves, into the stockroom — and only while nobody is
            // searching. Deliberately AFTER connected, needs-you and popular:
            // a service someone signed into is theirs and is listed under
            // "Yours" whatever this flag says, which is the property that
            // makes an unlisted long tail safe rather than a way to lose
            // something. Typing anything at all (`q` non-empty) skips this
            // branch entirely, so search reaches all 1,378.
            else if q.isEmpty, !c.featured { g.searchOnly.append(c) }
            else if c.kind == .mac { g.mac.append(c) }
            else { g.rest.append(c) }
        }
        // Most popular first. A ranked row carries its score; a hand-listed
        // one without a score takes its native score, or falls back to its
        // place in the hand list — so a catalog script older than the
        // ranking still draws the shelves in the order they always had.
        //
        // `nativeRank` is on the ranking's scale and means something only
        // beside it: each direct twin is scored just under what the ranking
        // gives its broker row. With no ranking at all (composio-ranking.json
        // missing or unreadable — hermes-catalog.py answers `{}` — or a
        // catalog script older than it) the broker rows have no score, fall
        // back to their place in the hand list, which tops out at 60, and
        // every twin with a native score in the 70s and 80s took the card
        // from the broker's row: mcp/notion before composio/notion, the order
        // the 2026-09-11 decision reversed. So without a ranking nobody is
        // scored and the hand lists decide, broker first, as they are written.
        let hasRanking = all.contains { $0.rank > 0 }
        func score(_ c: Connection, _ list: [String]) -> Int {
            if c.rank > 0 { return c.rank }
            if hasRanking, let n = nativeRank[c.id] { return n }
            if let i = list.firstIndex(of: c.id) { return max(1, 60 - i) }
            return 0
        }
        let ranked: ([String]) -> (Connection, Connection) -> Bool = { list in { a, b in
            let (x, y) = (score(a, list), score(b, list))
            if x != y { return x > y }
            // One brand, two routes: the broker's leads (decided 2026-09-11).
            if (a.kind == .composio) != (b.kind == .composio) { return a.kind == .composio }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        } }
        g.popular.sort(by: ranked(popular))
        g.work.sort(by: ranked(work))
        // One card per name on a shelf. Where two routes to one brand both
        // exist (Notion's own server and Composio's), the one listed first
        // keeps the card and the other goes to the alphabet with the rest.
        for shelf in [\Sections.popular, \Sections.work] {
            var seen = Set<String>()
            var keep: [Connection] = []
            for c in g[keyPath: shelf] {
                if seen.insert(c.label.lowercased()).inserted { keep.append(c) } else { g.rest.append(c) }
            }
            // A shelf is the popular few, not the catalogue: past
            // `shelfSize` the rest go under "Everything else", still in
            // popularity order there.
            g[keyPath: shelf] = Array(keep.prefix(shelfSize))
            g.rest.append(contentsOf: keep.dropFirst(shelfSize))
        }
        let byLabel: (Connection, Connection) -> Bool = { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        // Everything else, and every search result: the popular ones first,
        // then the alphabet — Gmail before 0CodeKit when someone types "mail".
        let byRank: (Connection, Connection) -> Bool = { a, b in
            a.rank != b.rank ? a.rank > b.rank : byLabel(a, b)
        }
        g.rest.sort(by: byRank); g.connected.sort(by: byLabel); g.advanced.sort(by: byLabel)
        g.attention.sort(by: byLabel); g.searchOnly.sort(by: byRank)
        return g
    }

    /// One row per brand — with two deliberate exceptions, Telegram and
    /// WhatsApp. Gmail used to hide behind a Google Workspace row; there is
    /// no such row now (CONNECTORS.md §Google: the decision), so Gmail is the
    /// Gmail row — popular, never advanced.
    ///
    /// **WhatsApp is the Telegram case again, and it was missed when Telegram
    /// was fixed.** `mac/whatsapp` used to set `advanced` whenever the
    /// catalog contained `platform/whatsapp` — which it always does — so
    /// Moe's own WhatsApp, the one that links this Mac from the phone, sat
    /// collapsed inside a grey "Advanced" chevron at the bottom of the page.
    /// The row it was deduplicating against then moved to another screen
    /// (`excludingInbound`), and ~1,400 Composio rows arrived, one of them
    /// called WhatsApp. So the only WhatsApp on the Connections page was the
    /// broker's — which is WhatsApp *Business*, a different product that
    /// cannot see a personal account at all — and the owner asked where his
    /// had gone. It had gone nowhere; nothing on screen said so.
    ///
    /// **Telegram is two rows, not one, and stopped being folded when the
    /// screens split.** The two are different capabilities pointing opposite
    /// ways: `platform/telegram` is a bot you message and Moe answers
    /// (inbound, "Ways to reach Moe"), and `mac/telegram` is Moe reading and
    /// sending as *you* (outbound, Connections). Folding the second into the
    /// first existed only because one list showed both and two rows called
    /// Telegram was confusing. On two screens that reason is gone, and the
    /// fold became a bug: the alternate is not a top-level row, so it
    /// appeared in neither list, and it changed screens depending on its own
    /// state — unconnected it hid inside a reach row, connected it surfaced
    /// on Connections. A person could connect it from one screen and find
    /// Disconnect only on the other.
    static func merge(mac: [Connection], engine: [Connection]) -> [Connection] {
        var engine = engine
        var extraMac: [Connection] = []
        for m in mac {
            // Telegram and WhatsApp fall through with everyone else: neither
            // is in `brokerFold`, so neither is folded, and neither sets
            // `advanced`. That is the whole of the exception — see above.
            if let brokerIndex = brokerRow(for: m, in: engine) {
                // Two rows both called Gmail, both saying "Working", is what
                // a person actually saw. Unlike the Telegram case above
                // these are the SAME capability by two routes — read this
                // person's mail — so one row with the other offered inside
                // it is the honest shape, and it is what `alternates` is for.
                engine[brokerIndex].alternates.append(foldIntoBroker(m))
            } else {
                extraMac.append(m)
            }
        }
        return extraMac + engine
    }

    /// Services where a Mac-native row and a brokered row are the same job by
    /// two routes, so the local one belongs inside the brokered row rather
    /// than beside it.
    ///
    /// The owner asked for these three to be one row each. An earlier version
    /// of this comment argued Drive was a different answer — the synced folder
    /// versus the account — and that is still true of what it READS, but it is
    /// not what a person meets: they met two rows both called Google Drive,
    /// both saying Working, and had to guess. The distinction belongs in the
    /// words inside the row, which is where it now is.
    ///
    /// **Folded, not deleted, and that is a privacy decision rather than
    /// caution.** Both local connectors still pull hourly through `sync.sh`.
    /// Removing the row would leave something reading this person's files
    /// every hour with nothing on screen to see it or switch it off — the row
    /// IS the off switch. Retiring the connectors is a separate change that
    /// has to stop the pulling first.
    ///
    /// `mac/calendar` is still not folded: it reads every calendar on the Mac,
    /// including work ones Google has never heard of, so it answers a question
    /// the brokered row cannot.
    static let brokerFold: [String: String] = [
        "gmail": "composio/gmail",
        "drive": "composio/googledrive",
        "drive-docs": "composio/googledocs",
    ]

    /// What the folded row is called once it sits inside another, and why a
    /// person might still want it. Each says what is DIFFERENT about the local
    /// route, because that is the only reason to choose it.
    static let foldWords: [String: (String, String)] = [
        "gmail": ("Use an app password instead",
                  "Moe reads this mailbox straight from your Mac, with a "
                  + "Google app password rather than your real one. Nothing passes "
                  + "through anyone else's servers — a little more to set up, and the "
                  + "most private way to do it."),
        "drive": ("Read the folder on this Mac instead",
                  "Moe reads the files Google Drive has already synced to this Mac. "
                  + "No sign-in at all, and nothing leaves the machine — but only "
                  + "what Drive for Desktop has actually downloaded, and only while "
                  + "this Mac is awake."),
        "drive-docs": ("Read documents you pick, on this Mac",
                       "The contents of the Google Docs, Sheets and Slides you choose "
                       + "by hand, and nothing else. The narrowest way to let Moe read "
                       + "a document, and it never sees the rest of your Drive."),
    ]

    static func brokerRow(for m: Connection, in engine: [Connection]) -> Int? {
        guard let target = brokerFold[m.name] else { return nil }
        // Only fold when the broker row is actually there. Without this a Mac
        // with no Composio configured loses its Gmail row entirely — folded
        // into a parent that does not exist, visible nowhere, which is
        // precisely the bug the Telegram note above records.
        return engine.firstIndex { $0.id == target }
    }

    /// The local row, reworded for the place it now sits: inside another
    /// row's sheet, as the other way to do the same thing.
    static func foldIntoBroker(_ m: Connection) -> Connection {
        // No fallback to the original label on purpose: a folded row keeping
        // its own name is how two rows called "Google Drive" became one row
        // containing another row called "Google Drive".
        let words = foldWords[m.name] ?? ("Do it on this Mac instead", m.blurb)
        var alt = Connection(
            id: m.id, kind: m.kind, name: m.name,
            label: words.0,
            blurb: words.1,
            authKind: m.authKind, state: m.state, detail: m.detail,
            envKeys: m.envKeys, allowedUsersKey: m.allowedUsersKey, prompts: m.prompts,
            docs: m.docs, connectName: m.connectName, setupScript: m.setupScript)
        alt.advanced = m.advanced
        alt.accounts = m.accounts
        return alt
    }

    /// The pure part: catalog JSON + connections JSON → rows. Tested by
    /// scripts/test-connections-ui.sh through `Moe --connections-json`.
    static func parse(catalogJSON: Data, connectionsJSON: Data) -> Parsed {
        let cat = (try? JSONSerialization.jsonObject(with: catalogJSON)) as? [String: Any] ?? [:]
        // The connections script prints a list; newer ones an object with
        // the list under "connections" plus "pending_pairings".
        let connsAny = try? JSONSerialization.jsonObject(with: connectionsJSON)
        var conns = connsAny as? [[String: Any]] ?? []
        var pairings: [Pairing] = []
        if let obj = connsAny as? [String: Any] {
            conns = (obj["connections"] as? [[String: Any]]) ?? (obj.values.first { $0 is [[String: Any]] } as? [[String: Any]]) ?? []
            pairings = Pairing.parse(obj["pending_pairings"])
        }

        var states: [String: (Connection.State, String)] = [:]
        var accountsByService: [String: [Connection.Account]] = [:]
        var cleanupByService: Set<String> = []
        var addresses: [String: String] = [:]
        var warning = ""
        for c in conns {
            guard let kind = c["kind"] as? String, let name = c["name"] as? String else { continue }
            let state = mapState(c["state"] as? String ?? "")
            let detail = humanDetail(c["detail"] as? String ?? "")
            if kind == "hermes" { warning = detail; continue }
            states["\(kind)/\(name)"] = (state, detail)
            // A service can have several sign-ins. The connections script
            // reports every one; the row keeps them so the sheet can list
            // them, name them and disconnect one without touching the rest.
            if let list = c["accounts"] as? [[String: Any]] {
                accountsByService[name] = list.compactMap { a in
                    guard let id = a["id"] as? String, !id.isEmpty else { return nil }
                    return Connection.Account(id: id,
                                              who: (a["who"] as? String) ?? "",
                                              status: ((a["status"] as? String) ?? "").uppercased())
                }
            }
            if kind == "composio", (c["cleanup_pending"] as? Bool) == true { cleanupByService.insert(name) }
            if let a = c["address"] as? String, !a.isEmpty { addresses["\(kind)/\(name)"] = a }
        }

        func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }
        func str(_ v: Any?) -> String { v as? String ?? "" }
        func blurb(_ e: [String: Any]) -> String {
            let b = str(e["blurb"])
            return b.isEmpty ? sanitiseBlurb(str(e["description"])) : b
        }
        func advanced(_ e: [String: Any], _ name: String) -> Bool {
            (e["advanced"] as? Bool ?? false) || (e["advanced"] as? NSNumber)?.boolValue == true || advancedNames.contains(name)
        }
        func prompts(_ v: Any?) -> [String: String] {
            var out: [String: String] = [:]
            for (k, val) in (v as? [String: Any]) ?? [:] { if let s = val as? String { out[k] = s } }
            return out
        }

        var rows: [Connection] = []
        var mcpNames: Set<String> = []

        for e in (cat["mcp"] as? [[String: Any]]) ?? [] {
            let name = str(e["name"]); guard !name.isEmpty, !hiddenNames.contains(name) else { continue }
            mcpNames.insert(name)
            let auth: Connection.AuthKind
            switch str(e["auth"]) {
            case "oauth": auth = .oauth
            case "api-key": auth = .apiKey
            default: auth = .none
            }
            let id = "mcp/\(name)"
            let (state, detail) = states[id] ?? (.notConnected, "")
            rows.append(Connection(
                id: id, kind: .mcp, name: name, label: label(for: name), blurb: blurb(e),
                authKind: auth, state: state, detail: detail, envKeys: strings(e["credentials"]),
                allowedUsersKey: "", prompts: prompts(e["prompts"]), docs: str(e["docs"]),
                connectName: name, setupScript: "", advanced: advanced(e, name)))
        }

        // Servers configured outside the catalog (connect.sh --url / --command):
        // the connections script knows them, so they get a row too.
        for c in conns {
            guard c["kind"] as? String == "mcp", let name = c["name"] as? String, !mcpNames.contains(name) else { continue }
            mcpNames.insert(name)
            let id = "mcp/\(name)"
            let (state, detail) = states[id] ?? (.notConnected, "")
            let auth: Connection.AuthKind = str(c["auth"]) == "oauth" ? .oauth : (str(c["auth"]) == "api-key" ? .apiKey : .none)
            rows.append(Connection(
                id: id, kind: .mcp, name: name, label: label(for: name), blurb: "Added by address.",
                authKind: auth, state: state, detail: detail, envKeys: [], allowedUsersKey: "", prompts: [:], docs: "",
                connectName: name, setupScript: ""))
        }

        for e in (cat["skills"] as? [[String: Any]]) ?? [] {
            let name = str(e["name"]); guard !name.isEmpty, !hiddenNames.contains(name) else { continue }
            let id = "skill/\(name)"
            let (state, detail) = states[id] ?? (.notConnected, "")
            // notion and airtable exist as a one-click server *and* as a
            // paste-a-key skill; connect.sh picks the server, so the screen
            // shows one row — unless the skill is what is actually connected.
            if mcpNames.contains(name), state == .notConnected { continue }
            let creds = strings(e["credentials"])
            let auth: Connection.AuthKind
            if creds.contains(where: { $0.contains(".") }) { auth = .terminal }   // a file only a person can make
            else { auth = .apiKey }
            rows.append(Connection(
                id: id, kind: .skill, name: name, label: label(for: name), blurb: blurbForSkill(name, blurb(e)),
                authKind: auth, state: state, detail: detail, envKeys: creds,
                allowedUsersKey: "", prompts: prompts(e["prompts"]), docs: str(e["docs"]),
                connectName: "skill/\(name)", setupScript: "", advanced: advanced(e, name)))
        }

        // Services behind the Composio broker. The list is Composio's, not
        // ours: hermes-catalog.py asks it what exists rather than carrying a
        // set of names that would freeze the day it was written.
        for e in (cat["composio"] as? [[String: Any]]) ?? [] {
            let name = str(e["name"]); guard !name.isEmpty, !hiddenNames.contains(name) else { continue }
            let id = "composio/\(name)"
            let (state, detail) = states[id] ?? (.notConnected, "")
            let label = brokerLabels[name]
                ?? Connection.humaniseLabel(str(e["label"]).isEmpty ? Self.label(for: name) : str(e["label"]))
            // .oauth: clicking Connect opens a browser and there is nothing
            // to type. .apiKey: Composio holds no sign-in for this service
            // and it takes a key from its own settings page — the paste
            // sheet, whose fields are asked of Composio's record at connect
            // time (`connect.sh --fields`; ConnectFlow.askForKey), which is
            // why envKeys stays empty even then. Either way the broker holds
            // the credential and there is nothing on this Mac to store. A
            // catalog script older than this field sends "oauth", which is
            // what every row was before 2026-09-11.
            // .none: nothing to sign in to (Yelp, Hacker News). A session
            // calls these with no account at all, so the row is simply on:
            // there is no Connect to press and nothing to Disconnect.
            let auth: Connection.AuthKind = str(e["auth"]) == "api-key" ? .apiKey
                : str(e["auth"]) == "none" ? .none : .oauth
            let broken = (e["broken"] as? Bool) ?? ((e["broken"] as? NSNumber)?.boolValue ?? false)
            let (rowState, rowDetail) = broken
                ? (Connection.State.unavailable, "Not working at Composio right now")
                : auth == .none ? (Connection.State.connected, "Always on — nothing to sign in to") : (state, detail)
            var row = Connection(
                id: id, kind: .composio, name: name, label: label,
                blurb: brokerBlurbs[name] ?? blurb(e),
                authKind: auth, state: rowState, detail: rowDetail, envKeys: [],
                allowedUsersKey: "", prompts: [:], docs: str(e["docs"]),
                connectName: id, setupScript: "", advanced: false,
                // Absent means true: an installed ~/.moe whose catalog script
                // predates this field must keep listing its services, not
                // lose all of them at once.
                featured: (e["featured"] as? Bool) ?? ((e["featured"] as? NSNumber)?.boolValue ?? true))
            row.rank = (e["rank"] as? Int) ?? ((e["rank"] as? NSNumber)?.intValue ?? 0)
            row.shelf = str(e["shelf"])
            row.accounts = accountsByService[name] ?? []
            row.cleanupPending = cleanupByService.contains(name)
            rows.append(row)
        }

        for e in (cat["platforms"] as? [[String: Any]]) ?? [] {
            let name = str(e["name"]); guard !name.isEmpty, !hiddenNames.contains(name) else { continue }
            // Both locks: the catalogue's own verdict when it has one, and
            // this app's list regardless. Either alone is walked past by a
            // stale copy of the other.
            let catalogueShows = (e["shown"] as? Bool) ?? ((e["shown"] as? NSNumber)?.boolValue ?? true)
            guard catalogueShows, shownPlatforms.contains(name) else { continue }
            let id = "platform/\(name)"
            let (state, detail) = states[id] ?? (.notConnected, "")
            let label = Connection.humaniseLabel(str(e["label"]).isEmpty ? Self.label(for: name) : str(e["label"]))
            // WhatsApp pairs from the phone (a QR code, drawn here); Telegram
            // is one click. WhatsApp was `.terminal` until 2026-09-09, which
            // is why connecting it opened Terminal — and connect.sh's own
            // WhatsApp branch then said "run 'hermes whatsapp' in a terminal",
            // for a bridge Hermes had shipped and could drive all along.
            // Slack joined the one-click list on 2026-09-11: Moe has its own
            // Slack app now, so "Add to Slack" is a page you approve rather
            // than two keys to find. The paste-the-keys sheet is still there
            // behind it (`offerKeys`) for a workspace that will not allow a
            // third-party app.
            let auth: Connection.AuthKind
            switch name {
            // Signal is a QR code as well: this Mac becomes a linked device
            // of the person's own account (scripts/connect-signal.sh).
            case "whatsapp", "signal": auth = .scan
            // Slack is one click since slice G1: Moe's own Slack app.
            case "telegram", "slack": auth = .oneClick
            default: auth = .apiKey
            }
            // These used to promise an answer "even when this Mac is closed".
            // Nothing in the product does that: the part of Moe that thinks
            // is a child of this app (HermesSupervisor), so it answers while
            // the Mac is awake and not otherwise. The cloud tier that would
            // make the old sentence true is a plan, not a build (PRODUCT.md
            // §5). PRODUCT.md's own instruction there is "be honest in the UI".
            //
            // LINE is the odd one of the five: it only ever delivers to a
            // public address (a webhook; no polling, no socket), which a Mac
            // behind a router does not have. So a LINE message reaches Moe
            // through the cloud — connect.sh's LINE branch registers it there
            // — and the row says so rather than "while this Mac is awake",
            // which would be true of the reply and false of the arrival.
            let text: String
            switch name {
            case "telegram": text = "Text Moe from your phone. It replies while this Mac is awake."
            case "line": text = "Message Moe on LINE. LINE only delivers through Moe's cloud, so this needs you signed in to Moe."
            // The trust ask, said before Connect is clicked: a linked device
            // receives the whole account, and the answers land in Note to Self.
            case "signal": text = "Talk to Moe in Note to Self. Linking gives this Mac your whole Signal account; Moe answers only there."
            default: text = "Message Moe on \(label). It replies while this Mac is awake."
            }
            rows.append(Connection(
                id: id, kind: .platform, name: name, label: label,
                blurb: text,
                authKind: auth, state: state, detail: detail, envKeys: strings(e["credentials"]),
                allowedUsersKey: str(e["allowed_users"]), prompts: prompts(e["prompts"]), docs: str(e["docs"]),
                connectName: "platform/\(name)", setupScript: "",
                advanced: advanced(e, name)))
        }

        // Moe's own email address (slice G3): `platform/moemail`. Not a Hermes
        // platform -- it is not in the catalog -- and never `platform/email`,
        // which is the person's own mailbox and has its own row above. Always
        // listed, like Spotify below: it needs nothing on this Mac but a name.
        let (emState, emDetail) = states["platform/moemail"] ?? (.notConnected, "")
        var emailRow = Connection(
            id: "platform/moemail", kind: .platform, name: "moemail", label: "Email Moe",
            blurb: "Your own address for writing to Moe, like you@in.moebot.app.",
            authKind: .oneClick, state: emState, detail: emDetail, envKeys: [],
            allowedUsersKey: "", prompts: [:], docs: "", connectName: "platform/moemail",
            setupScript: "")
        emailRow.address = addresses["platform/moemail"] ?? ""
        rows.append(emailRow)

        // Spotify is neither a server nor a skill: its own sign-in, kept by
        // the engine (connect.sh spotify). The connections script lists it as auth/spotify.
        let (spState, spDetail) = states["auth/spotify"] ?? (.notConnected, "")
        rows.append(Connection(
            id: "auth/spotify", kind: .skill, name: "spotify", label: "Spotify",
            blurb: "Your playlists, and what is playing.", authKind: .oauth, state: spState, detail: spDetail,
            envKeys: [], allowedUsersKey: "", prompts: [:], docs: "", connectName: "spotify", setupScript: ""))

        return Parsed(connections: rows, warning: warning, pairings: pairings)
    }

    static func mapState(_ s: String) -> Connection.State {
        switch s {
        case "ok": return .connected
        case "needs-setup": return .needsAttention
        case "unavailable", "timeout": return .unavailable
        // Spelled out rather than left to `default`. needs-setup is amber and
        // sorts above everything; a service nobody ever connected must not
        // land there, and a connector saying so should read as a decision
        // here rather than as a string that happened to miss every case.
        case "not-connected": return .notConnected
        default: return .notConnected
        }
    }

    /// The scripts' detail lines are written for a terminal: they name the
    /// command to run and the engine. On screen the button is the command.
    /// Moe's name, in text written about Moe's own engine. Deliberately just
    /// the name: `humanDetail` strips commands, env vars and engine jargon as
    /// well, which is right for a one-line status pill and wrong for a live
    /// script line whose whole job is to say what is happening.
    static func renameEngine(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "Hermes's", with: "Moe's")
        s = s.replacingOccurrences(of: "Hermes", with: "Moe")
        return s
    }

    static func humanDetail(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: " — run ") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: " - run ") { s = String(s[..<r.lowerBound]) }
        // The scripts name themselves by their installed path (~/.moe/scripts/)
        // or the checkout's (~/moe/scripts/): neither belongs on screen.
        s = s.replacingOccurrences(of: "~/.moe/scripts/", with: "")
        s = s.replacingOccurrences(of: "~/moe/scripts/", with: "")
        // "… Run connect.sh telegram." / "run connect-gmail.sh to add an
        // account" — the button is the command.
        s = s.replacingOccurrences(of: #"(?i)\.?\s*\(?run (scripts/)?connect[^.)]*\)?\.?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "Hermes answers nobody", with: "Moe answers nobody")
        s = s.replacingOccurrences(of: "restart Hermes", with: "restart Memoe")
        s = s.replacingOccurrences(of: "Restart Hermes", with: "Restart Memoe")
        s = s.replacingOccurrences(of: "Moe starts Hermes", with: "Moe starts it")
        // "token present" (a platform's key is in .env) — the pill already
        // says Connected; the line says what that rests on.
        s = s.replacingOccurrences(of: "token present", with: "key saved")
        s = s.replacingOccurrences(of: "Hermes", with: "Moe")
        s = s.replacingOccurrences(of: "hermes ", with: "")
        s = s.replacingOccurrences(of: "MCP ", with: "")
        s = s.replacingOccurrences(of: "OAuth", with: "sign-in")
        s = s.replacingOccurrences(of: "API key", with: "key")
        s = s.replacingOccurrences(of: "token", with: "sign-in")
        s = s.replacingOccurrences(of: "in .env", with: "")
        s = s.replacingOccurrences(of: "from .env", with: "")
        // "(MCP_X_API_KEY)" / "missing TELEGRAM_BOT_TOKEN" — the env names
        // are the paste sheet's business, not the row's.
        s = s.replacingOccurrences(of: #"\s*\(?[A-Z][A-Z0-9_]{3,}(, [A-Z][A-Z0-9_]{3,})*\)?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func blurbForSkill(_ name: String, _ description: String) -> String {
        switch name {
        case "teams-meeting-pipeline": return "Teams meetings, Outlook and OneDrive, through your organisation's account."
        default: return description
        }
    }
}

// MARK: - Mac-native sources

/// The connectors that only a process on this Mac can run. Their `status`
/// verb is the truth; the words in its line pick the fix-it button.
enum MacSources {
    /// `connectName` is what `connect.sh --remove` takes. Empty for the
    /// rows that are a macOS permission rather than a credential — there is
    /// nothing to disconnect. Without it the Disconnect button ran
    /// `connect.sh --remove ""`, which every row failed on.
    struct Spec {
        let key: String; let label: String; let blurb: String
        let setupScript: String
        var connectName: String = ""
        /// Sources whose one button opens a page in the browser: the script
        /// prints the address, the app opens it, and the script blocks until
        /// the browser comes back. Not a sheet, not a Terminal.
        var browserSignIn: Bool = false
        /// Sources that are off until the user says otherwise. The button is
        /// a switch (learn/consent.sh grant|revoke), not a Terminal and not a
        /// System Settings pane.
        var consentSource: String = ""
    }

    static let specs: [Spec] = [
        // The Google question people ask most: "where do I connect Google
        // Calendar?" — nowhere, it is already here, because Calendar.app
        // holds it. Said in the row so nobody goes hunting for a Google row
        // that no longer exists.
        Spec(key: "calendar", label: "Calendar", blurb: "Moe knows what you have on — every calendar in Calendar.app, Google ones included. Nothing to connect.", setupScript: "", connectName: ""),
        Spec(key: "reminders", label: "Reminders", blurb: "Moe knows what you still owe people, and can add a reminder when you ask.", setupScript: ""),
        Spec(key: "notes", label: "Apple Notes", blurb: "Moe reads your notes, and re-reads them every ten minutes — not only when you ask.", setupScript: ""),
        // A permission, not a credential, like Calendar: contacts.sh asks
        // the app (Moe --contacts --status) whether the Contacts grant is
        // Moe's. Looked up when a name comes up, never pulled into context.
        Spec(key: "contacts", label: "Contacts", blurb: "Moe knows who you mean when you say a name, and can find their number or email.", setupScript: ""),
        Spec(key: "call-recordings", label: "Recorded calls", blurb: "Moe can tell you what was said on calls your iPhone recorded, from their transcripts.", setupScript: ""),
        Spec(key: "imessage", label: "Messages", blurb: "Moe knows what people have said to you in iMessage and SMS.", setupScript: ""),
        // Every account in Mail.app, not only Gmail: the index and message
        // files Mail keeps on this disk (connectors/mail-items.py). A
        // permission like Messages, not a credential.
        Spec(key: "mail", label: "Mail", blurb: "Moe reads the mail in the Mail app on this Mac \u{2014} every account set up there. Nothing to connect.", setupScript: ""),
        Spec(key: "calls", label: "Phone call history", blurb: "Moe can tell you who called and when, so you know who you missed.", setupScript: ""),
        Spec(key: "drive", label: "Google Drive", blurb: "Moe finds and reads the files Google's Drive app has synced here. No Google password.", setupScript: ""),
        Spec(key: "chrome", label: "Chrome browsing", blurb: "Moe can find the page you were reading. Off until you turn it on; never your searches.", setupScript: "", consentSource: "chrome"),
        // The companion to the Google Drive row, not an alternative to it.
        // Drive for Desktop syncs a Doc as a link, so that row can show the
        // name and never the text; this one reads the text of the documents
        // the user picks, and of nothing else. They cannot be one row: the
        // permission this asks Google for is the only one of its kind that
        // may not be combined with any other.
        Spec(key: "drive-docs", label: "Google Docs and Sheets",
             blurb: "Moe reads the documents you pick yourself \u{2014} those, and nothing else in your Drive.",
             setupScript: "connect-drive-docs.sh", connectName: "drive-docs", browserSignIn: true),
        Spec(key: "gmail", label: "Gmail", blurb: "Moe reads your mail and drafts replies. Needs an app password, never your Google password.", setupScript: "connect-gmail.sh", connectName: "gmail"),
        // connectName, not the default "": this row IS a credential — a
        // delegated login on this disk — so Disconnect has something to do.
        // Without it the button ran `connect.sh --remove ""` and told the
        // user there was nothing to disconnect while they were looking at a
        // row that said connected.
        Spec(key: "telegram", label: "My own Telegram", blurb: "Moe signs in to your Telegram as a linked device, so it can follow your conversations and write a message when you ask. Every message it sends asks you first.", setupScript: "connect-telegram.sh", connectName: "telegram"),
        Spec(key: "whatsapp", label: "WhatsApp on this Mac", blurb: "Moe reads your own WhatsApp conversations, once your phone links this Mac.", setupScript: "connect-whatsapp.sh"),
    ]

    /// Row from one status line ("ok: …" / "needs-setup: …" / "unavailable: …").
    static func connection(for spec: Spec, statusLine: String) -> Connection {
        let prefix = statusLine.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        var state = ConnectionsCatalog.mapState(prefix)
        // An opt-in source that is off is not broken. Its connector says
        // "needs-setup" because that is the connector contract's word for
        // "not ready", but on screen an orange "Needs attention" and a Fix
        // button would be Moe nagging for a permission the user declined by
        // doing nothing. It reads as simply not connected, with a switch.
        if !spec.consentSource.isEmpty, state == .needsAttention,
           !statusLine.lowercased().contains("full disk") {
            state = .notConnected
        }
        var detail = statusLine.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        if statusLine.isEmpty { detail = "Not installed on this Mac." }
        detail = ConnectionsCatalog.humanDetail(detail)
        // Gmail is an in-app sheet: an address and an app password, typed
        // here. WhatsApp is a QR code, also drawn here since 2026-09-09 —
        // connect-whatsapp.sh drives Hermes's bundled bridge and emits
        // QR=<payload>, so the Terminal it used to open (and the Go toolchain
        // it asked the person to install first) is gone. What is left on
        // .terminal is Telegram's phone login, which asks for a texted code.
        let auth: Connection.AuthKind
        if !spec.consentSource.isEmpty { auth = .consent }
        else if spec.browserSignIn { auth = .oauth }
        else if spec.setupScript.isEmpty { auth = .macPermission }
        else if spec.key == "whatsapp" { auth = .scan }
        else { auth = spec.key == "gmail" ? .appPassword : .terminal }
        // A second way in, once the first has worked: picking more documents
        // is a fresh trip through Google's picker, because Google issues the
        // permission one basketful at a time. Offered only when there is
        // already a list to add to — before that, the main button is it.
        var extras: [Connection] = []
        if spec.key == "drive-docs", state == .connected {
            extras.append(Connection(
                id: "mac/drive-docs-pick", kind: .mac, name: "drive-docs-pick",
                label: "Pick more files…", blurb: "Add more Google documents to the ones Moe may read.",
                authKind: .oauth, state: .notConnected, detail: "",
                envKeys: [], allowedUsersKey: "", prompts: [:], docs: "", connectName: "",
                setupScript: spec.setupScript))
        }
        return Connection(
            id: "mac/\(spec.key)", kind: .mac, name: spec.key, label: spec.label, blurb: spec.blurb,
            authKind: auth, state: statusLine.isEmpty ? .unavailable : state, detail: detail,
            envKeys: [], allowedUsersKey: "", prompts: [:], docs: "", connectName: spec.connectName,
            setupScript: spec.setupScript, alternates: extras)
    }

    /// One Mac connector's `status` line, or "" when there is no connector
    /// by that key on this Mac. Blocks; call off the main thread.
    ///
    /// The one place a connector is run, so the list and any single check of
    /// a row ask the same script the same way and cannot disagree about what
    /// a source says.
    static func macStatusLine(_ key: String) -> String {
        let dir = Paths.home.appendingPathComponent("connectors")
        let candidates = [dir.appendingPathComponent("\(key).sh"), dir.appendingPathComponent("\(key).py")]
        guard let script = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return "" }
        var r = ScriptRunner.run(script.path, [], timeout: 12)
        // Twelve scripts run at once, and right after launch the Mac
        // is also warming models and starting the brain: a check
        // that took thirteen seconds used to read as "Not installed
        // on this Mac" and stay that way. Once more, with room.
        if r.timedOut { r = ScriptRunner.run(script.path, [], timeout: 30) }
        return r.timedOut
            ? "timeout: " + Connection.couldNotCheckWords
            : r.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// Run every native connector's `status`, concurrently, 12 s each (the
    /// alarm doctor.sh uses). Blocks; call off the main thread.
    static func checkAll() -> [Connection] {
        var results = [String](repeating: "", count: specs.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (i, spec) in specs.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let line = macStatusLine(spec.key)
                lock.lock(); results[i] = line; lock.unlock()
            }
        }
        group.wait()
        // What each check said, in one line: the only way to tell, after
        // the fact, why a source the person knows is connected read as
        // anything else on the screen.
        Log.write("connections: Mac checks — " + zip(specs, results).map { spec, line in
            let word = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "(nothing)"
            return "\(spec.key)=\(word.isEmpty ? "(nothing)" : word)"
        }.joined(separator: " "))
        return zip(specs, results).map { connection(for: $0, statusLine: $1) }
    }
}

// MARK: - Certificate failures

/// **A secure connection that could not be made, in words a person can use.**
///
/// Measured 2026-11-12: a python.org Python 3.15 first on PATH, with an empty
/// trust store, made every helper script fail with
/// `[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get
/// local issuer certificate`, and Connections › Add another showed that raw
/// line — or, when it came as a traceback, an unrelated earlier line — with
/// "check the key was copied whole" under it. The cause is fixed
/// (`BrainSetup.pathWithMoePython`); this is the net for the next one — a
/// clock that is wrong, a VPN or web filter that inspects traffic, another
/// interpreter — none of which a person fixes by pasting a key again.
///
/// Keyed on the words the TLS stacks themselves print (OpenSSL through
/// Python, curl, URLSession), never on a script's own phrasing, so a new
/// script walks into it.
enum CertificateFailure {
    static let sentence = "Moe couldn't make a secure connection to finish setting this up."
    static let nextStep = "Quit Memoe, open it again, and try once more. If it still fails, check that your Mac's date and time are set automatically (System Settings › General › Date & Time), and pause any VPN or web filter while you connect."

    /// Lowercased fragments only a TLS failure prints.
    static let markers = [
        "certificate_verify_failed", "certificate verify failed", "sslcertverificationerror",
        "[ssl:", "ssl: certificate", "sslerror", "ssl error", "ssl_error",
        "unable to get local issuer certificate", "self signed certificate",
        "self-signed certificate", "certificate has expired", "certificate is not yet valid",
        "tlsv1 alert", "tlsv13 alert", "wrong version number",
        "curl: (60)", "curl: (35)", "nsurlerrorservercertificate",
        "the certificate for this server is invalid", "secure connection to the server cannot be made",
    ]

    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        return markers.contains { lower.contains($0) }
    }

    /// `text` itself, or the plain sentence when it is a certificate failure.
    static func plain(_ text: String) -> String { matches(text) ? sentence : text }
}

// MARK: - Running the scripts

/// Runs a connection script with its output captured, a hard time limit,
/// and a kill that reaches the whole tree. Blocking: call off the main thread.
enum ScriptRunner {
    struct Result {
        let status: Int32
        let output: String
        let timedOut: Bool
        /// The last line a person would read: skips blanks and machine lines.
        ///
        /// Renamed on the way out, because this is the one place every connect
        /// script's words reach the screen. The scripts are written for a
        /// terminal and said "Hermes" in seventeen places — "Creating your
        /// Telegram bot through Hermes", "Message your bot once Hermes
        /// restarts" — and the sheet showed them verbatim while the row's own
        /// detail line, which goes through `humanDetail`, had been saying Moe
        /// all along. Those seventeen are fixed; this is here because the
        /// eighteenth has not been written yet. Enforcement belongs on the
        /// path a new one has to travel, not on a list of the ones we found.
        ///
        /// A certificate failure anywhere in the output wins over the last
        /// line, because Python reports it in a traceback (which
        /// `humanLine` drops, leaving whatever "Opening…" came before it) or
        /// folds it into a `✗ … <urlopen error [SSL: …]>` line nobody can act
        /// on. `CertificateFailure` says it in one plain sentence instead.
        var lastHumanLine: String {
            if CertificateFailure.matches(output) { return CertificateFailure.sentence }
            let raw = Result.humanLine(in: output)
            return ConnectionsCatalog.renameEngine(raw)
        }

        /// The last line of `text` that was written for a person, ignoring
        /// everything a crashing interpreter wrote after it.
        ///
        /// stderr is merged into stdout on purpose (a stray warning may come
        /// first), and *last* line is the contract every connect script is
        /// written to. Those two together have one hole, and a person fell
        /// into it: a script printed its honest `✗ Telegram does not
        /// recognise that phone number…`, then died on the way out, and
        /// Python printed a traceback — so the sheet showed
        /// `sqlite3.OperationalError: no such table: update_state` under the
        /// heading "My own Telegram", with the api_id/api_hash advice
        /// underneath it. (Measured 2026-09-07; the script's own bug is
        /// fixed in scripts/connect-telegram.sh, and this is the net, because
        /// there are eleven connect scripts and the next crash will be in a
        /// different one.)
        ///
        /// The rule keys on the one marker CPython always prints and never
        /// on the name of an error, so a new exception type walks into it
        /// rather than past it: a traceback block runs from
        /// `Traceback (most recent call last):` to the end of the output —
        /// chained exceptions ("During handling of…") included, since those
        /// stay inside the same block — so everything from the first such
        /// line down is dropped, and the answer is the last human line
        /// before it. A script that crashed before saying anything gets an
        /// empty string, and every caller already has an honest sentence for
        /// that.
        static func humanLine(in text: String) -> String {
            var lines = text.split(whereSeparator: \.isNewline).map(String.init)
            if let crash = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("Traceback (most recent call last):")
            }) {
                lines = Array(lines[..<crash])
            }
            return lines.last {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
                    && !MachineLine.isMachine($0)
                    && !$0.hasPrefix("argv=")
            } ?? ""
        }
    }

    /// A running script, for Cancel.
    final class Child {
        let process: Process
        /// True when the child leads its own process group (the perl
        /// wrapper); then a signal to -pid reaches the whole tree. Without
        /// the wrapper the child shares Moe's group and only the pid is safe.
        let ownsGroup: Bool
        /// The write end of stdin, when the script was started with it kept
        /// open (`NEED=<field>` answers go here). Nil otherwise.
        private var input: FileHandle?
        private let lock = NSLock()
        init(_ p: Process, ownsGroup: Bool, input: FileHandle? = nil) { process = p; self.ownsGroup = ownsGroup; self.input = input }
        /// One `KEY=value` line, newline-clean. False when stdin is closed.
        @discardableResult
        func send(_ key: String, _ value: String) -> Bool {
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespaces)
            lock.lock(); defer { lock.unlock() }
            guard let input, process.isRunning else { return false }
            input.write(Data("\(key)=\(clean)\n".utf8))
            return true
        }
        func closeInput() {
            lock.lock(); defer { lock.unlock() }
            try? input?.close(); input = nil
        }
        /// The whole process group: connect.sh, its python, the engine's CLI.
        func cancel() {
            closeInput()
            guard process.isRunning else { return }
            let target = ownsGroup ? -process.processIdentifier : process.processIdentifier
            kill(target, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
                if process.isRunning { kill(target, SIGKILL) }
            }
        }
    }

    /// Runs blocking script work on a GCD thread rather than a Swift
    /// concurrency thread: the cooperative pool has only as many threads as
    /// cores, and a sign-in can block for three minutes.
    static func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: body()) }
        }
    }

    /// ~/.moe/scripts/<name> (installed), then the copy inside the app, then
    /// the checkout — the same ladder the Brain pane uses.
    ///
    /// The installed copy wins in every normal case: Payload lays it down on
    /// first run. The bundle is what stands behind it if that copy failed or
    /// a file was deleted, and it is runnable from there because these
    /// scripts write through $MOE_HOME rather than beside themselves. The
    /// checkout is last and only ever exists on a developer's Mac — until
    /// 2026-08-31 it was the *only* fallback, which is why a downloaded Moe
    /// reported "couldn't find its own setup file" instead of working.
    static func scriptPath(_ name: String) -> String? {
        var candidates = [Paths.home.appendingPathComponent("scripts/\(name)").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("scripts/\(name)").path)
        }
        if let c = Payload.checkoutPath("scripts/\(name)") { candidates.append(c) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// ~/.moe/connectors, then the app's own copy, then the checkout's.
    ///
    /// The probe is `hermes-catalog.py` being executable, because that file is
    /// what the whole pane is built from: an unexecutable one means an empty
    /// catalog and a pane with nothing in it.
    static func connectorsDir() -> URL {
        let fm = FileManager.default
        let installed = Paths.home.appendingPathComponent("connectors", isDirectory: true)
        if fm.isExecutableFile(atPath: installed.appendingPathComponent("hermes-catalog.py").path) {
            return installed
        }
        if let b = Payload.bundlePayload {
            let inApp = b.appendingPathComponent("connectors", isDirectory: true)
            if fm.isReadableFile(atPath: inApp.appendingPathComponent("hermes-catalog.py").path) {
                return inApp
            }
        }
        // A developer's own checkout, debug builds only. A shipped Moe that
        // has neither copy answers with the installed path: the catalog there
        // is missing, the pane says so, and nothing is read from somewhere
        // the person never installed.
        if let c = Payload.checkoutPath("moe-home/connectors") {
            return URL(fileURLWithPath: c, isDirectory: true)
        }
        return installed
    }

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["MOE_HOME"] = Paths.home.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        // A script run from inside the app has the app's permissions
        // (Calendar, Messages, Contacts…). The same script run from a
        // terminal does not, and a Mac source it then reports as "not
        // connected" is wrong in a way that outlives the run if it is
        // cached. consent_list.py writes the status cache only when this
        // is set — so a hand-run list can never make Calendar vanish from
        // Settings › Background.
        env["MOE_FROM_APP"] = "1"
        // Moe's own Python first: 123 helpers start by `#!/usr/bin/env
        // python3` and their shell scripts say `python3` 183 times more, and
        // whichever Python this Mac has in /usr/local/bin is not one Moe can
        // vouch for (`BrainSetup.pathWithMoePython` has what that cost).
        env["PATH"] = BrainSetup.pathWithMoePython(
            "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"))
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Run `exe args…` in its own process group (perl's setpgrp, so a cancel
    /// or a timeout takes the engine's children with it). `stdin` is written
    /// then closed; nil closes it at once. stdout and stderr arrive merged,
    /// line by line, through `onLine` as they happen.
    @discardableResult
    static func run(_ exe: String, _ args: [String], stdin: String? = nil, extraEnv: [String: String] = [:],
                    timeout: TimeInterval, keepStdinOpen: Bool = false, started: ((Child) -> Void)? = nil,
                    onLine: ((String) -> Void)? = nil) -> Result {
        let p = Process()
        // Stock macOS ships /usr/bin/perl; should it ever go, run the script
        // directly and settle for killing the script alone.
        let perl = "/usr/bin/perl"
        let ownsGroup = FileManager.default.isExecutableFile(atPath: perl)
        if ownsGroup {
            p.executableURL = URL(fileURLWithPath: perl)
            // `exec { $ARGV[0] } @ARGV`, never `exec @ARGV`: with exactly one
            // element perl treats the list form as a shell command line and
            // splits it on spaces. Moe's home is "~/Library/Application
            // Support/Moe", so every status script run with no arguments
            // became "/Users/…/Library/Application: No such file or
            // directory" — and every Mac source read as not connected. The
            // block form execs the path as given, whatever is in it.
            p.arguments = ["-e", "setpgrp(0,0); exec { $ARGV[0] } @ARGV or die \"$!\\n\"", "--", exe] + args
        } else {
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
        }
        p.environment = environment(extraEnv)
        p.currentDirectoryURL = Paths.home
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = (stdin == nil && !keepStdinOpen) ? FileHandle.nullDevice : input
        do { try p.run() } catch {
            return Result(status: -1, output: "Couldn't run \(URL(fileURLWithPath: exe).lastPathComponent): \(error.localizedDescription)", timedOut: false)
        }
        let child = Child(p, ownsGroup: ownsGroup, input: keepStdinOpen ? input.fileHandleForWriting : nil)
        started?(child)
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            if !keepStdinOpen { try? input.fileHandleForWriting.close() }
        }
        var timedOut = false
        let timer = DispatchWorkItem { timedOut = true; child.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Read to EOF here, before waiting: a script that fills the pipe
        // would otherwise block forever.
        var buffer = Data()
        var text = ""
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                text += line + "\n"
                onLine?(line)
            }
        }
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            text += line
            onLine?(line)
        }
        p.waitUntilExit()
        timer.cancel()
        return Result(status: p.terminationStatus, output: text, timedOut: timedOut)
    }

    /// `connect.sh args…`. Non-interactive: the answers (KEY=value lines)
    /// travel on stdin — never argv, never the log.
    static func connect(_ args: [String], answers: [String: String]? = nil, timeout: TimeInterval,
                        keepStdinOpen: Bool = false, extraEnv: [String: String] = [:],
                        started: ((Child) -> Void)? = nil, onLine: ((String) -> Void)? = nil) -> Result {
        guard let script = scriptPath("connect.sh") else {
            return Result(status: -1, output: "Couldn't find connect.sh (expected in ~/.moe/scripts).", timedOut: false)
        }
        return runScript(script, args, answers: answers, timeout: timeout, keepStdinOpen: keepStdinOpen,
                         extraEnv: extraEnv, started: started, onLine: onLine)
    }

    /// Any connect script, non-interactive: the answers (`KEY=value` lines)
    /// travel on stdin — never argv, never the log. With `keepStdinOpen`
    /// the script may ask for more (`NEED=<field>`) through `Child.send`.
    static func runScript(_ script: String, _ args: [String], answers: [String: String]?, timeout: TimeInterval,
                          keepStdinOpen: Bool = false, extraEnv: [String: String] = [:],
                          started: ((Child) -> Void)? = nil, onLine: ((String) -> Void)? = nil) -> Result {
        // One `KEY=value` line each. A pasted value can carry a trailing
        // newline or CR, or be nothing but blanks; none of that belongs in .env.
        var stdin = ""
        for (k, v) in (answers ?? [:]).sorted(by: { $0.key < $1.key }) {
            let clean = v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            stdin += "\(k)=\(clean)\n"
        }
        var env = extraEnv
        env["MOE_CONNECT_NONINTERACTIVE"] = "1"
        return run(script, args, stdin: (answers == nil && !keepStdinOpen) ? nil : stdin, extraEnv: env,
                   timeout: timeout, keepStdinOpen: keepStdinOpen, started: started, onLine: onLine)
    }

    /// `pairing.sh approve <platform> <id>` — let a person who messaged the
    /// bot talk to Moe.
    static func approvePairing(_ p: Pairing) -> Result {
        guard let script = scriptPath("pairing.sh") else {
            return Result(status: -1, output: "Couldn't find pairing.sh (expected in ~/.moe/scripts).", timedOut: false)
        }
        return run(script, ["approve", p.platform, p.rawID], extraEnv: ["MOE_CONNECT_NONINTERACTIVE": "1"], timeout: 30)
    }

    /// `connect.sh --status <name>` → true when it answers "ok:".
    static func isConnected(_ connectName: String) -> Bool {
        // A Mac source is not one of connect.sh's names. Its truth is the
        // connector beside it — the same script the list reads — and asking
        // connect.sh instead would be a well-formed name that resolves to
        // nothing: always false, forever, for every Mac row.
        if connectName.hasPrefix("mac/") {
            return MacSources.macStatusLine(String(connectName.dropFirst("mac/".count))).hasPrefix("ok:")
        }
        // stderr is merged in (a stray warning may come first): any line.
        return connect(["--status", connectName], timeout: 45).output
            .split(whereSeparator: \.isNewline).contains { $0.hasPrefix("ok:") }
    }
}

// MARK: - The model

/// Loads everything off the main thread and publishes it in two passes:
/// first what the files say (a second), then what the real checks say (up
/// to a minute and a half). The catalog is read once per session.
@MainActor
final class ConnectionsModel: ObservableObject {
    /// One per app: the pane is rebuilt every time the sidebar switches to
    /// it, and the live checks (which start real servers) must not re-run
    /// on each visit — only on Re-check.
    static let shared = ConnectionsModel()

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var loading = false
    @Published private(set) var checkingLive = false
    @Published private(set) var warning = ""
    @Published private(set) var loadedOnce = false
    /// People waiting to be let in on a chat platform (the banner).
    @Published private(set) var pairings: [Pairing] = []

    private var catalogCache: Data?
    private var generation = 0

    /// The two phases' time limits. The connections script has its own live
    /// budget (60 s); this is the outer cap, after which what came back is shown.
    nonisolated static let filesTimeout: TimeInterval = 30
    nonisolated static let liveTimeout: TimeInterval = 90

    /// Rows put here by hand rather than read from this Mac — only for
    /// `--settings-snapshot` and the layout tests, which draw a Gmail with
    /// three accounts without there being one. While posed, `reload` does
    /// nothing: a photograph must not start the connector scripts, and a
    /// read that came back late would replace the pose mid-picture.
    private(set) var posed = false
    func pose(_ rows: [Connection]?) {
        generation += 1          // a read already in flight loses
        posed = rows != nil
        connections = rows ?? []
        warning = ""
        pairings = []
        loading = false
        checkingLive = false
        loadedOnce = rows != nil
    }

    func reload() {
        guard !posed else { return }
        generation += 1
        let gen = generation
        loading = true
        let cached = catalogCache
        Task {
            let (catalog, conns, mac) = await ScriptRunner.offMain { Self.loadFiles(catalogCache: cached) }
            let parsed = ConnectionsCatalog.parse(catalogJSON: catalog, connectionsJSON: conns)
            await MainActor.run {
                guard self.generation == gen else { return }
                if !catalog.isEmpty { self.catalogCache = catalog }
                self.connections = ConnectionsCatalog.merge(mac: mac, engine: parsed.connections)
                self.warning = parsed.warning
                self.pairings = parsed.pairings
                self.loading = false
                self.loadedOnce = true
                self.checkingLive = true
            }
            // Pass two: the real checks, merged in state by state.
            let live = await ScriptRunner.offMain { Self.loadConnections(live: true) }
            let parsedLive = ConnectionsCatalog.parse(catalogJSON: catalog, connectionsJSON: live)
            await MainActor.run {
                guard self.generation == gen else { return }
                if !live.isEmpty {
                    var byID: [String: Connection] = [:]
                    for c in parsedLive.connections { byID[c.id] = c }
                    self.connections = self.connections.map { row in
                        guard row.kind != .mac, let fresh = byID[row.id] else { return row }
                        var updated = row
                        updated.state = fresh.state
                        updated.detail = fresh.detail
                        updated.alternates = row.alternates.map { alt in
                            guard let f = byID[alt.id] else { return alt }
                            var a = alt; a.state = f.state; a.detail = f.detail; return a
                        }
                        return updated
                    }
                    self.pairings = parsedLive.pairings
                }
                self.checkingLive = false
            }
        }
    }

    /// Files-only re-read of who is waiting (cheap; the pairing sheet polls it).
    func refreshPairings() async -> [Pairing] {
        let conns = await ScriptRunner.offMain { Self.loadConnections(live: false) }
        let parsed = ConnectionsCatalog.parse(catalogJSON: Data(), connectionsJSON: conns)
        pairings = parsed.pairings
        return parsed.pairings
    }

    func forget(_ p: Pairing) { pairings.removeAll { $0.id == p.id } }

    /// "Check again" on a row the cloud said was not available
    /// (`ConnectionDetail.offersCheckAgain`): `connect.sh --status <row>` asks
    /// the cloud now — for Moe's Slack app that rewrites the marker from
    /// `/v1/channels/slack/link` — and the reload reads the answer.
    func checkAgain(_ c: Connection) {
        let name = c.connectName.isEmpty ? c.id : c.connectName
        Task {
            _ = await ScriptRunner.offMain { ScriptRunner.isConnected(name) }
            reload()
        }
    }

    nonisolated static func loadFiles(catalogCache: Data?) -> (Data, Data, [Connection]) {
        var catalog = catalogCache ?? Data()
        var conns = Data()
        var mac: [Connection] = []
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { if catalog.isEmpty { catalog = loadCatalog() }; group.leave() }
        group.enter(); DispatchQueue.global().async { conns = loadConnections(live: false); group.leave() }
        group.enter(); DispatchQueue.global().async { mac = MacSources.checkAll(); group.leave() }
        group.wait()
        return (catalog, conns, mac)
    }

    nonisolated static func loadCatalog() -> Data {
        let script = ScriptRunner.connectorsDir().appendingPathComponent("hermes-catalog.py").path
        guard FileManager.default.isExecutableFile(atPath: script) else { return Data() }
        let r = ScriptRunner.run(script, ["--json"], timeout: filesTimeout)
        return jsonPart(of: r.output)
    }

    nonisolated static func loadConnections(live: Bool) -> Data {
        let script = ScriptRunner.connectorsDir().appendingPathComponent("hermes-connections.py").path
        guard FileManager.default.isExecutableFile(atPath: script) else { return Data() }
        let r = ScriptRunner.run(script, live ? ["list", "--live", "--json"] : ["list", "--json"],
                                 timeout: live ? liveTimeout : filesTimeout)
        return jsonPart(of: r.output)
    }

    /// **Rewrite `context/_connections.md` now, because something changed.**
    ///
    /// That file is the only thing the model is told about which services
    /// exist — it goes into the system prompt, because Hermes runs the
    /// claude-code child with Read disallowed and the model cannot open a
    /// file to find out. Until 2026-09-07 its only writer was `sync.sh` on a
    /// ten-minute tick, so the minutes right after someone connected
    /// something were the minutes in which Moe would tell them "no mailbox is
    /// added yet" and offer to walk them through connecting the mailbox they
    /// had just connected. That happened to the owner, 88 seconds after the
    /// connection.
    ///
    /// `connect.sh` does this itself, which covers a terminal and Moe's own
    /// tools as well as the app. This is here because the pane does not
    /// always go through `connect.sh` — `connect-gmail.sh`,
    /// `connect-telegram.sh` and `connect-drive-docs.sh` are driven directly
    /// — and running it twice writes the same bytes twice, which
    /// `PromptSource` treats as no change at all.
    ///
    /// Off the main queue and never waited on: the person has finished, and
    /// a network read they did not ask for must not hold the sheet open.
    nonisolated static func refreshBrainContext() {
        let script = ScriptRunner.connectorsDir().appendingPathComponent("hermes-connections.py").path
        guard FileManager.default.isExecutableFile(atPath: script) else { return }
        DispatchQueue.global().async {
            _ = ScriptRunner.run(script, ["refresh"], timeout: liveTimeout)
        }
    }

    /// stderr is merged into stdout (a stray warning from the YAML fallback,
    /// say), so take the text from the first `{` or `[` on a line of its own.
    nonisolated static func jsonPart(of text: String) -> Data {
        guard let start = text.range(of: "\n{")?.lowerBound ?? text.range(of: "\n[")?.lowerBound
                ?? ((text.hasPrefix("{") || text.hasPrefix("[")) ? text.startIndex : nil)
        else { return Data() }
        return Data(text[start...].utf8)
    }

    /// The plan the gate would honour on this Mac, off disk and with no
    /// network — the same call `CloudVoice.mayUse` makes, against the same
    /// file. The running screen reads it from `cloudStatus`, which is this
    /// value having come the long way round; the dump reads it directly
    /// because there is no conductor in a `--connections-json` process.
    nonisolated private static func honouredTier() -> String {
        Cloud.honouredTier()
    }

    /// `Moe --connections-json`: the parsed rows as JSON, for the test suite.
    /// Catalog and connected state only — the Mac-native checks would touch
    /// the real Calendar and Messages.
    ///
    /// `--catalog <file> --connections <file>` read fixtures instead of the
    /// scripts; `--mac <file>` adds Mac-native rows from `<key>\t<status line>`
    /// lines; `--parse-machine-lines` parses stdin as script output and prints
    /// the machine lines it found.
    ///
    /// `--search <words>` groups as though someone had typed that into the
    /// search box. Without it the groups are the empty-search ones, which is
    /// the shape the suite pins — and which is exactly why the flag had to
    /// exist: "the unlisted services are still reachable by search" is a
    /// claim about a state this dump could not otherwise reach, so it could
    /// only have been asserted by re-implementing the filter in the test,
    /// where it would agree with itself forever.
    nonisolated static func dumpJSON(_ args: [String] = []) -> String {
        func arg(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--parse-key-fields") {
            // stdin: what `connect.sh --fields composio/<slug>` printed; out:
            // the sheet's fields, so a test can read the labels the person
            // would (and that none of them says "token").
            let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let parsed = KeyField.parse(jsonPart(of: text))
            let data = (try? JSONSerialization.data(withJSONObject: [
                "fields": parsed.fields.map { ["key": $0.key, "label": $0.label, "help": $0.help, "secret": $0.secret] },
                "helpURL": parsed.helpURL, "managed": parsed.managed,
            ], options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        if args.contains("--parse-machine-lines") {
            let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let found = text.split(whereSeparator: \.isNewline).compactMap { MachineLine.parse(String($0)) }.map(\.json)
            let human = ScriptRunner.Result(status: 0, output: text, timedOut: false).lastHumanLine
            let data = (try? JSONSerialization.data(withJSONObject: ["machine": found, "lastHumanLine": human],
                                                    options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let catalog = arg("--catalog").flatMap { FileManager.default.contents(atPath: $0) } ?? loadCatalog()
        let conns = arg("--connections").flatMap { FileManager.default.contents(atPath: $0) } ?? loadConnections(live: false)
        let parsed = ConnectionsCatalog.parse(catalogJSON: catalog, connectionsJSON: conns)
        var mac: [Connection] = []
        if let file = arg("--mac"), let text = FileManager.default.contents(atPath: file).map({ String(decoding: $0, as: UTF8.self) }) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard let spec = MacSources.specs.first(where: { $0.key == parts[0] }) else { continue }
                mac.append(MacSources.connection(for: spec, statusLine: parts.count > 1 ? parts[1] : ""))
            }
        }
        let all = ConnectionsCatalog.merge(mac: mac, engine: parsed.connections)
        func row(_ c: Connection) -> [String: Any] {
            ["accounts": c.accounts.map { ["id": $0.id, "who": $0.who, "status": $0.status] },
             "id": c.id, "kind": c.kind.rawValue, "name": c.name, "label": c.label, "blurb": c.blurb,
             "authKind": c.authKind.rawValue, "state": c.state.rawValue, "detail": c.detail,
             "envKeys": c.envKeys, "allowedUsersKey": c.allowedUsersKey, "docs": c.docs,
             "connectName": c.connectName, "fields": c.askedKeys.map { c.fieldLabel($0) },
             "advanced": c.advanced, "featured": c.featured, "alternates": c.alternates.map { $0.id },
             "settingsPane": c.settingsPaneURL?.absoluteString ?? "",
             "cleanupPending": c.cleanupPending, "canDisconnect": ConnectionDetail.canDisconnect(c),
             "checkAgain": ConnectionDetail.offersCheckAgain(c), "address": c.address,
             "emailActions": ConnectionDetail.emailActions(c)]
        }
        let rows: [[String: Any]] = all.flatMap { [row($0)] + $0.alternates.map(row) }
        let search = arg("--search") ?? ""
        let obj: [String: Any] = ["connections": rows, "warning": parsed.warning,
                                  "popular": ConnectionsCatalog.popular,
                                  "work": ConnectionsCatalog.work,
                                  "search": search,
                                  "sections": ConnectionsCatalog.sections(all, search: search).ids,
                                  // What the Connections screen actually renders now
                                  // that the platforms left it, and what the new
                                  // "Ways to reach Moe" screen renders in their place.
                                  // `sections` above stays every row, grouped.
                                  "outbound": ConnectionsCatalog.sections(all, search: search, excludingInbound: true).ids,
                                  "reach": ConnectionsCatalog.reach(all, search: search).ids,
                                  // The line each screen puts at the top, for
                                  // the tier this Mac is actually on — read
                                  // here from the same `tier.json` the
                                  // Composio gate reads, not passed in. It is
                                  // in the dump so that
                                  // scripts/test-connections-ui.sh can write a
                                  // tier into a scratch home and watch the
                                  // real binary's words change: a paid Mac was
                                  // being told its messages only work while
                                  // this Mac is awake, and a unit test of the
                                  // strings would have stayed green through
                                  // the screen never calling them.
                                  "reachBlurb": Cloud.connectionsBlurb(reach: true, tier: honouredTier()),
                                  "servicesBlurb": Cloud.connectionsBlurb(reach: false, tier: honouredTier()),
                                  "tier": honouredTier(),
                                  "pendingPairings": parsed.pairings.map { ["platform": $0.platform, "request_id": $0.rawID, "name": $0.name, "when": $0.when] }]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
