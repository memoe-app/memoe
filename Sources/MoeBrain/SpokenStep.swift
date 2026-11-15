import Foundation

/// What Moe says out loud about the step it is on, built from the step Hermes
/// reports rather than from anything invented here.
///
/// This exists because the account of a long job cannot be left to the model
/// alone. The prompt asks it for a line before it goes quiet and it often
/// writes one — but not always, and when it does not there is nothing to say:
///
///     19:53:42  → What did I ship on the pulse repos today?
///     19:54:41  turn: first token 59.3 s after the mic closed
///
/// Fifty-nine seconds, and the first token was already the answer. Someone
/// listening rather than watching cannot tell that from a crash.
///
/// The one live signal through a stretch like that is `hermes.tool.progress`,
/// which carries the tool and `agent.display.build_tool_preview`'s summary of
/// its arguments — the command, the query, the path, already redacted for
/// secrets. So the tool gives the verb and the label gives the thing, and what
/// comes out is true about this particular job: "Looking through GitHub",
/// not "still working".
///
/// Nothing here guesses. A step it cannot describe honestly returns nil and
/// Moe stays quiet about that one, because a wrong account of what your
/// computer is doing is worse than no account.
public enum SpokenStep {

    /// "click (953, 59) in Freeform" → "Clicking in Freeform".
    ///
    /// Returns nil when the detail names no app, so the caller can fall back
    /// to something that does not pretend to know where the action landed.
    static func inApp(_ detail: String, verb: String) -> String? {
        guard let range = detail.range(of: " in ", options: .backwards) else { return nil }
        let app = detail[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return nil }
        return "\(verb) \(app)"
    }

    /// A phrase for this step, or nil if there is nothing honest to say.
    ///
    /// Always opens with a gerund so `continuing` can put "Still" in front of
    /// it and still be a sentence.
    public static func phrase(tool: String, label: String) -> String? {
        let tool = canonical(tool)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // A label that is just the tool's own name carries no argument — the
        // gateway falls back to it when a tool reports none.
        let detail = (label.isEmpty || canonical(label) == tool) ? "" : label

        switch tool {
        case "terminal", "execute_code", "process":
            return shellPhrase(detail)

        case "web_search":
            guard let what = speakable(detail) else { return "Searching the web" }
            return "Searching the web for \(what)"

        case "web_extract":
            guard let site = host(in: detail) else { return "Reading a page" }
            return "Reading something on \(site)"

        // Hermes's one browser tool since its browser rewire: navigation,
        // clicks and typing are all code inside a browser_exec call.
        case "browser_exec":
            return "Working through the page"

        // Never the name. A guard used to sit here keeping machine-made
        // names out of Moe's mouth, and it kept being walked past, because
        // there is always another shape a filename can take:
        //
        //     "Reading multiagentsecurityreview.md L1 200"     three words,
        //     "Reading multiagentsecurityreview.md L201 400"   no long digit
        //     "Reading multiagentsecurityreview.md L401 600"   run — passes
        //     "Reading SHARED AGENT ARCHITECTURE"
        //     "Reading elements d3bbb344404845779b22bdcd359e…"
        //     "Reading mcp hermes tools tool call 1788546547356"
        //
        // That is CLAUDE.md's rule about guards that enumerate: each fix
        // named a shape, and the next filename was a shape nobody had named.
        // A file's *name* was never worth saying out loud anyway — the person
        // asked for the thing, not the path — so the branch that needed the
        // guard is gone rather than guarded again. What Moe is reading, when
        // it is worth saying, is the model's job now, and since the narration
        // prompt landed the model speaks about three times as often as this
        // table does.
        case "read_file":
            return "Reading a file"

        case "write_file", "patch":
            return "Writing a file"

        case "search_files":
            // The label here is a glob — "*.md" — which is not language.
            return "Searching your files"

        case "delegate_task":
            guard let what = speakable(detail) else { return "Handing part of this off" }
            return "Getting someone onto \(what)"

        case "vision_analyze":
            return "Looking at that"

        // Moe's own connectors and the Hermes tools a voice turn actually
        // reaches. These were the commonest steps in the log and every one of
        // them fell through to `default` and was logged "not spoken":
        //
        //     10:53:48  tool: calendar_pull — calendar_pull · not spoken
        //
        // So the one turn most likely to need a beat of "hang on" — the one
        // that goes and reads your mail — was the one that got silence.
        // Counted over ~250 steps on this Mac: terminal 95, browser 43,
        // search_files 30, read_file 15, then computer_use 11, notes_create 8,
        // gmail_send 8, telegram_pull 7, gmail_crawl 7, gmail_pull 6.
        case "gmail_pull", "gmail_crawl", "gmail_search", "gmail_find":
            return "Going through your mail"
        case "calendar_pull", "calendar_search":
            return "Checking your calendar"
        case "notes_pull", "notes_search":
            return "Looking through your notes"
        case "notes_create":
            return "Writing that into your notes"
        case "reminders_pull":
            return "Checking your reminders"
        case "reminders_create":
            return "Setting that reminder"
        case "telegram_pull", "telegram_crawl", "telegram_find":
            return "Going through your Telegram"
        case "whatsapp_pull", "whatsapp_crawl", "whatsapp_chats",
             "whatsapp_find", "whatsapp_status":
            return "Going through your WhatsApp"
        case "imessage_pull", "imessage_crawl", "imessage_find", "search_messages":
            return "Going through your messages"
        case "drive_pull", "drive_docs_pull", "drive_search":
            return "Looking through your Drive"
        case "chrome_pull", "chrome_tabs":
            return "Looking at what's open in your browser"
        case "calls_pull":
            return "Checking your calls"
        // Anything that puts a message on the wire. Deliberately "getting it
        // ready" and never "sending": Moe's send gate may still stop and ask,
        // and a spoken "sending that" while a dialog waits is a lie.
        case "gmail_send", "telegram_send", "whatsapp_send", "imessage_send",
             "send_message", "send_email":
            return "Getting that ready to send"
        case "computer_use":
            // One fixed phrase for every screen action meant a person watching
            // Moe drive their Mac heard "Working on your Mac" eight times in
            // seventy-six seconds and could not tell a screenshot from a click,
            // or progress from a loop. Hermes now sends what it is doing —
            // "menu Insert > Media… in Freeform", "click (953, 59) in
            // Freeform" — and this turns that into something speakable.
            let d = detail.lowercased()
            if d.hasPrefix("looking") {
                return inApp(detail, verb: "Looking at") ?? "Looking at your screen"
            }
            if d.hasPrefix("menu ") {
                let item = detail.dropFirst(5)
                    .components(separatedBy: " in ").first ?? ""
                let leaf = item.components(separatedBy: " > ").last ?? String(item)
                return leaf.isEmpty ? "Using a menu" : "Choosing \(leaf)"
            }
            if d.hasPrefix("checking it worked") {
                return "Checking that worked"
            }
            if d.hasPrefix("click") || d.hasPrefix("double click")
                || d.hasPrefix("right click") || d.hasPrefix("middle click") {
                return inApp(detail, verb: "Clicking in") ?? "Clicking"
            }
            if d.hasPrefix("typing") { return inApp(detail, verb: "Typing in") ?? "Typing" }
            if d.hasPrefix("pressing") {
                // The keystroke itself is not worth reading aloud — "cmd shift
                // g" is noise in a sentence — but the app is.
                return inApp(detail, verb: "Using a shortcut in") ?? "Using a keyboard shortcut"
            }
            if d.hasPrefix("scrolling") { return inApp(detail, verb: "Scrolling in") ?? "Scrolling" }
            if d.hasPrefix("switching to") { return "Switching to " + detail.dropFirst(13) }
            if d.hasPrefix("list windows") || d.hasPrefix("list apps") {
                return "Seeing what's open"
            }
            if d.hasPrefix("focused element") { return "Checking what's in focus" }
            if let n = d.firstIndex(of: " "), d.hasSuffix("steps")
                || d.contains("steps: ") {
                _ = n
                return "Doing a few things on your Mac"
            }
            // An action this build has no phrase for. The old code said
            // "Working on your Mac" for everything; saying it only here is
            // the honest remainder rather than the default.
            return "Working on your Mac"
        case "cronjob", "schedule":
            return "Sorting out the schedule"
        case "session_search":
            return "Looking back through what we've said"
        case "memory":
            // Hermes uses one tool for both halves, so the label is the only
            // thing that says which — and when it says neither, nothing here
            // guesses.
            let d = detail.lowercased()
            if d.contains("save") || d.contains("remember") || d.contains("store") {
                return "Making a note of that"
            }
            if d.contains("recall") || d.contains("search") || d.contains("get") {
                return "Checking what I remember"
            }
            return nil

        case "image_generate":
            return "Making that image"

        case "todo":
            // Hermes already phrases this one as prose — "reading task list",
            // "planning 4 task(s)" — and only the plural bracket has to go.
            let tidied = detail.replacingOccurrences(of: "(s)", with: "s")
            guard let what = speakable(tidied) else { return nil }
            return what.prefix(1).uppercased() + what.dropFirst()

        default:
            // Not one of Moe's own tools. It may still be a connector's, in
            // which case its name says which — see `toolkitPhrase`.
            return toolkitPhrase(tool)
        }
    }

    /// A phrase for a connector tool named `TOOLKIT_ACTION`.
    ///
    /// Composio names every action that way — `GMAIL_FETCH_EMAILS`,
    /// `GMAIL_REPLY_TO_THREAD`, `GOOGLECALENDAR_FIND_EVENT` — and the switch
    /// above was written against Moe's own names (`gmail_pull`,
    /// `gmail_crawl`). So every Composio call fell to `default` and Moe said
    /// nothing at all: measured on this Mac, **20 of 20 MCP tool calls were
    /// silent**, including the whole two-minute stretch where it fetched and
    /// replied to an email. Silence during a long job is the exact thing
    /// spoken progress exists to prevent.
    ///
    /// Matching the toolkit rather than the action means a connector gaining
    /// an action does not need a line here. The action still has to be
    /// recognisably a read or a write, because "Going through your mail" for
    /// something that deletes it would be worse than silence — anything else
    /// stays silent, which is this file's standing rule.
    static func toolkitPhrase(_ name: String) -> String? {
        guard let cut = name.firstIndex(of: "_") else { return nil }
        let toolkit = String(name[name.startIndex..<cut])
        let action = String(name[name.index(after: cut)...])
        guard let place = place(toolkit) else { return nil }

        // Composio's own plumbing — searching for a tool, fetching a schema,
        // running a batch. Real work, but not work the person asked for, and
        // narrating it is how "Moe is being weird" starts.
        if toolkit == "composio" { return nil }

        let verb = action.split(separator: "_").first.map(String.init) ?? action
        switch verb {
        case "fetch", "get", "list", "find", "search", "read", "pull", "crawl", "check":
            return "Going through \(place)"
        case "send", "reply", "create", "draft", "post", "add", "update", "modify":
            return "Getting that ready to send"
        default:
            return nil
        }
    }

    /// The words a person would use for a connector, or nil for one Moe has
    /// no honest name for.
    private static func place(_ toolkit: String) -> String? {
        switch toolkit {
        case "gmail", "outlook", "mail":            return "your mail"
        case "googlecalendar", "calendar":          return "your calendar"
        case "googledrive", "drive", "dropbox":     return "your Drive"
        case "googledocs", "docs":                  return "your documents"
        case "googlesheets", "sheets":              return "your spreadsheets"
        case "slack":                               return "Slack"
        case "notion":                              return "Notion"
        case "linear", "jira":                      return "your issues"
        case "github":                              return "GitHub"
        case "telegram":                            return "your Telegram"
        case "whatsapp":                            return "your WhatsApp"
        default:                                    return nil
        }
    }

    /// The same phrase, said again a while later without sounding like a
    /// repeat: "Looking through GitHub" → "Still looking through GitHub".
    public static func continuing(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return "Still " + first.lowercased() + phrase.dropFirst()
    }

    // MARK: - Shell

    /// The program being run is the honest, speakable part of a command; the
    /// flags and paths are not. `gh pr list --repo pulse` is "Looking through
    /// GitHub" and nothing more, because the rest of that line read aloud is
    /// noise.
    private static func shellPhrase(_ command: String) -> String? {
        switch program(in: command) {
        case "gh":                       return "Looking through GitHub"
        case "git":                      return "Going through your commits"
        case "du", "df":                 return "Adding up what's on your disk"
        case "ls", "find", "fd", "tree": return "Looking through your files"
        case "grep", "rg", "ag":         return "Searching through your files"
        case "curl", "wget":             return "Fetching that"
        case "docker", "kubectl":        return "Checking your containers"
        case "npm", "pnpm", "yarn", "swift", "cargo", "go", "make":
                                         return "Building that"
        case "python", "python3", "node", "ruby", "osascript":
                                         return "Running that"
        case "sqlite3", "psql", "mysql": return "Querying the database"
        case "":                         return nil
        default:                         return "Running something on your Mac"
        }
    }

    /// The command's head word, past the wrappers a real command arrives
    /// wrapped in. `cd /x && gh pr list` is a `gh` command.
    private static func program(in command: String) -> String {
        let skip: Set<String> = ["sudo", "env", "time", "nice", "command", "exec", "nohup", "xargs"]
        // Hermes has already compacted the plumbing; this only has to find the
        // first word that names a program rather than a shell nicety.
        for piece in command.split(whereSeparator: { "|&;".contains($0) }) {
            for word in piece.split(separator: " ") {
                let w = String(word)
                if w.isEmpty || w.contains("=") { continue }        // FOO=bar
                if w == "cd" || w.hasPrefix("-") { break }          // a `cd` leg
                if skip.contains(w) { continue }
                return (w as NSString).lastPathComponent
            }
        }
        return ""
    }

    // MARK: - Bits of a label that can be said

    /// A label is only spoken when it reads as language. Identifiers, paths,
    /// globs and namespaced tool ids are wiring.
    private static func speakable(_ text: String, limit: Int = 60) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= limit else { return nil }
        guard t.first?.isLetter == true || t.first?.isNumber == true else { return nil }
        // Punctuation a person does not pronounce. A pipe read aloud is
        // "pipe", a colon turns a list header into a stumble, and "task(s)"
        // comes out as "task parens s".
        for bad in ["__", "::", "/", "\\", "*", "{", "<", "$", "`", "|", ":", "(", ")"]
        where t.contains(bad) {
            return nil
        }
        return t
    }

    /// "github.com" out of a URL, without the www or the suffix — a domain
    /// read out in full is a mouthful and the useful half is the name.
    private static func host(in text: String) -> String? {
        let first = text.split(separator: ",").first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard var h = URL(string: trimmed)?.host ?? trimmed.split(separator: "/").first.map(String.init)
        else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let parts = h.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }


    /// Tools arrive namespaced when they come from an MCP server —
    /// `mcp__hermes-tools__terminal`, sometimes behind a `select:` — and a
    /// switch on "terminal" matches none of them.
    private static func canonical(_ tool: String) -> String {
        var t = tool.trimmingCharacters(in: .whitespaces)
        if let colon = t.lastIndex(of: ":") { t = String(t[t.index(after: colon)...]) }
        if let range = t.range(of: "__", options: .backwards) {
            t = String(t[range.upperBound...])
        }
        return t.lowercased()
    }
}
