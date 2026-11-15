import Foundation

/// What Moe knows how to do, and the one key that turns a piece of it off.
///
/// A skill is a page of instructions Hermes hands the model when the job
/// looks like the one the page describes — how to read a PDF, how to work
/// a GitHub pull request, how to talk to Obsidian. There are 96 of them on
/// this Mac. The model does not run them; it reads them, and then does
/// what they say with the tools it already has.
///
/// **Source:** `skills-catalogue.py`, which reads the five stores
/// `hermes skills list` reads and answers in JSON — that command prints a
/// rich table with no `--json` and truncates every name past twenty
/// characters, so the one thing a pane needs from it (a name it can write
/// back) is the one thing it will not give.
///
/// **It writes `skills.disabled` and nothing else** (HERMES-SURFACES §4.5).
/// That key already travels between the Mac and the machine as a sealed
/// `document` record, so this pane is cross-device on the day it ships and
/// must not invent a second mechanism. The write is a surgical text edit
/// verified by re-parsing — `config.yaml` opens with twenty lines of
/// comment that a `safe_load` → `safe_dump` round-trip deletes without a
/// word.
///
/// **Curation is a security property, not a nicety.** A skill that tells
/// the model to run a command this Mac does not have is worse than an
/// absent skill: the model reads the page, runs `memo`, gets `command not
/// found`, and has spent the turn finding out. Hermes does not check —
/// `tools/skills_tool.py` builds its answer with `"required_commands": []`
/// and `"missing_required_commands": []` hard-coded — so this does, and
/// the number is bigger than §4.5's four: **eleven** of the fourteen
/// skills declaring a command are missing it on this Mac, and seven of
/// those eleven are switched on.
///
/// Everything here blocks on a subprocess. Call it off the main thread.
enum Skills {

    // MARK: - What comes back

    /// One skill, as the catalogue reports it.
    ///
    /// Every key is read with `decodeIfPresent`. Swift's synthesised
    /// `Decodable` throws `keyNotFound` for an absent key rather than
    /// falling back to the property's default, and one missing key takes
    /// the whole answer with it — measured on this repo on 2026-09-04,
    /// where adding a single `var error = ""` turned every success into
    /// "Moe couldn't reach…". The Python side fills every key on every
    /// path too; one half would do today, two is what survives either end
    /// changing.
    struct Skill: Decodable, Equatable, Identifiable {
        var name = ""
        var category = ""
        var description = ""
        /// `builtin`, `official`, `hub` or `local` — where the page came
        /// from, which is most of what "should I trust this" means.
        var source = ""
        var trust = ""
        var enabled = true
        /// Hermes subtracts these from `skills.disabled` on read, so a
        /// switch for one would be a switch that does nothing.
        var essential = false
        var path = ""
        /// Commands the page says it needs, from its own frontmatter.
        var needs: [String] = []
        /// The ones this Mac does not have. Never a subset guessed at
        /// here: the catalogue looks in the places a Mac keeps commands,
        /// not only in this process's PATH, which under launchd is four
        /// directories and no Homebrew.
        var missing: [String] = []
        /// Hermes's own counter, out of `skills/.usage.json`.
        var uses = 0
        var lastUsed = ""
        /// Environments Hermes will only offer this skill inside. One
        /// skill on this Mac declares one (`sdlc-review`, kanban) and it
        /// is the whole of the difference between the 96 skills on disk
        /// and the 94 `hermes skills list` prints.
        var onlyIn: [String] = []
        var platforms: [String] = []

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, category, description, source, trust, enabled
            case essential, path, needs, missing, uses, platforms
            case lastUsed = "last_used", onlyIn = "only_in"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.skillsValue(.name, "")
            category = c.skillsValue(.category, "")
            description = c.skillsValue(.description, "")
            source = c.skillsValue(.source, "")
            trust = c.skillsValue(.trust, "")
            enabled = c.skillsValue(.enabled, true)
            essential = c.skillsValue(.essential, false)
            path = c.skillsValue(.path, "")
            needs = c.skillsValue(.needs, [])
            missing = c.skillsValue(.missing, [])
            uses = c.skillsValue(.uses, 0)
            lastUsed = c.skillsValue(.lastUsed, "")
            onlyIn = c.skillsValue(.onlyIn, [])
            platforms = c.skillsValue(.platforms, [])
        }
        init() {}

        /// True when this one is on AND its page tells the model to run
        /// something that is not here. The pair is the point: a disabled
        /// skill with a missing command is already handled, and a skill
        /// with no declared command cannot be judged either way.
        var willMisfire: Bool { enabled && !missing.isEmpty }

        /// Only offered inside something this Mac is not in right now.
        /// Shown, and never given a switch: turning it on changes nothing
        /// a person could see, and a switch that does nothing is worse
        /// than no switch.
        var gated: Bool { !onlyIn.isEmpty }
    }

    /// The whole answer. `ok == false` carries `error`.
    struct Catalogue: Decodable, Equatable {
        var ok = false
        var error = ""
        var skills: [Skill] = []
        var disabled: [String] = []
        var essential: [String] = []
        /// False when the settings file cannot be edited safely from
        /// here — no PyYAML, so no way to check the write afterwards.
        /// The switches are drawn and refused rather than hidden: a
        /// person who cannot see the state cannot tell it is wrong.
        var canWrite = false
        var whyNot = ""
        var config = ""
        var root = ""
        var counted = 0

        enum CodingKeys: String, CodingKey {
            case ok, error, skills, disabled, essential, config, root, counted
            case canWrite = "can_write", whyNot = "why_not"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.skillsValue(.ok, false)
            error = c.skillsValue(.error, "")
            skills = c.skillsValue(.skills, [])
            disabled = c.skillsValue(.disabled, [])
            essential = c.skillsValue(.essential, [])
            canWrite = c.skillsValue(.canWrite, false)
            whyNot = c.skillsValue(.whyNot, "")
            config = c.skillsValue(.config, "")
            root = c.skillsValue(.root, "")
            counted = c.skillsValue(.counted, 0)
        }
        init() {}

        /// On plus off must equal `counted`, and it did not until this was
        /// rendered: `on` excluded the one gated skill, so the pane read
        /// "96 skills — 91 switched on, 4 off" and left a reader to find
        /// the missing one. Gated is a fact about where Hermes offers a
        /// skill, not about whether it is switched on, and it is said
        /// separately.
        var on: Int { skills.filter(\.enabled).count }
        var off: Int { skills.filter { !$0.enabled }.count }
        var misfiring: Int { skills.filter(\.willMisfire).count }
        var gated: Int { skills.filter(\.gated).count }
    }

    /// What a switch produced. `changed == false` with `ok` means the key
    /// already said that — pressing an already-off switch is not an error.
    struct Switched: Decodable, Equatable {
        var ok = false
        var error = ""
        var name = ""
        var state = ""
        var disabled: [String] = []
        var changed = false

        enum CodingKeys: String, CodingKey { case ok, error, name, state, disabled, changed }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.skillsValue(.ok, false)
            error = c.skillsValue(.error, "")
            name = c.skillsValue(.name, "")
            state = c.skillsValue(.state, "")
            disabled = c.skillsValue(.disabled, [])
            changed = c.skillsValue(.changed, false)
        }
        init() {}
    }

    // MARK: - Running it

    /// `~/.moe/hermes/skills-catalogue.py` — installed, then the app's own
    /// copy, then the checkout. The ladder `Reminders`, `Chats` and
    /// `BrainSetup` all use, for the same reason: the middle rung is what
    /// keeps a home whose payload copy failed from showing an empty screen
    /// with no explanation.
    static func scriptPath() -> String? {
        var candidates = [Paths.home.appendingPathComponent("hermes/skills-catalogue.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes/skills-catalogue.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes/skills-catalogue.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// The Hermes venv's interpreter, never the system one.
    ///
    /// Reading works under either — the catalogue is stdlib-only on
    /// purpose. **Writing does not**, and deliberately: the script refuses
    /// to touch `config.yaml` without PyYAML, because without it there is
    /// no way to parse the file back and prove the edit landed where it
    /// was aimed. Asking the venv for both halves is what makes
    /// `canWrite` true on a working Mac and honest on a broken one.
    /// `BrainSetup.python()` decides what stands in when that is missing,
    /// so this is one call and not a branch.
    private static func ask<T: Decodable>(_ args: [String], timeout: TimeInterval = 25) -> T? {
        guard let script = scriptPath() else { return nil }
        let r = ScriptRunner.run(BrainSetup.python(), [script] + args, timeout: timeout)
        guard let data = Chats.jsonPart(r.output) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Nil only when the script gave no answer at all — it could not be
    /// found, could not start, or crashed. A refusal comes back decoded
    /// with `ok == false` and words in `error`, and the two are different
    /// things the pane says differently.
    static func catalogue() -> Catalogue? { ask(["list"]) }

    /// Turn one on or off.
    ///
    /// `--name=NAME`, joined, never `--name`, `NAME` as two arguments. A
    /// skill may legitimately be called `-ish`, and the split form hands
    /// argparse something that looks like an option — it answers by
    /// printing usage to stderr and exiting 2, which is not a refusal a
    /// pane can read. The same lesson `reminders.py` and `history.py` both
    /// carry at their call sites.
    static func set(_ name: String, on: Bool) -> Switched? {
        ask(["set", "--name=" + name, "--state=" + (on ? "on" : "off")])
    }

    // MARK: - Words

    /// Hermes's category slug, in Moe's voice.
    ///
    /// §4.5 asks for task language, and `autonomous-ai-agents` is not
    /// task language — it is a folder name. Anything not named here falls
    /// back to the slug with its hyphens opened out, so a category Hermes
    /// adds next month reads as words rather than as nothing.
    static func heading(for category: String) -> String {
        switch category {
        case "": return "Everything else"
        case "apple": return "Your Mac and your Apple apps"
        case "autonomous-ai-agents": return "Handing work to another agent"
        case "communication": return "Talking to people"
        case "creative": return "Drawing, designing and making"
        case "devops": return "Running and shipping software"
        case "email": return "Email"
        case "finance": return "Money and markets"
        case "github": return "GitHub"
        case "media": return "Music, video and images"
        case "mlops": return "Models and machine learning"
        case "note-taking": return "Notes"
        case "productivity": return "Documents and everyday work"
        case "research": return "Looking things up"
        case "smart-home": return "Your home"
        case "social-media": return "Social media"
        case "software-development": return "Writing code"
        default:
            let opened = category.replacingOccurrences(of: "-", with: " ")
            return opened.prefix(1).uppercased() + opened.dropFirst()
        }
    }

    /// Words a person would recognise, so an acronym is not shouted at
    /// once and mumbled the next time.
    ///
    /// Sentence case alone gave "Github pr workflow", "Comfyui", "Ocr and
    /// documents" and "Nano pdf" — all of them wrong in the same way, and
    /// all of them found by rendering rather than by reading the source.
    /// The list is deliberately short and deliberately about *spelling*: it
    /// never renames a skill, so a name here always resolves back to the
    /// one `skills.disabled` carries.
    private static let acronyms: [String: String] = [
        "ai": "AI", "api": "API", "arxiv": "arXiv", "ascii": "ASCII",
        "cli": "CLI", "comfyui": "ComfyUI", "css": "CSS", "csv": "CSV",
        "docx": "DOCX", "duckduckgo": "DuckDuckGo", "gif": "GIF",
        "github": "GitHub", "html": "HTML", "http": "HTTP",
        "huggingface": "HuggingFace", "imessage": "iMessage", "js": "JS",
        "json": "JSON", "llm": "LLM", "llms": "LLMs", "macos": "macOS",
        "mcp": "MCP", "md": "MD", "mlops": "MLOps", "ocr": "OCR",
        "openhue": "OpenHue", "pdf": "PDF", "pdfs": "PDFs", "pr": "PR",
        "sdlc": "SDLC", "searxng": "SearXNG", "sql": "SQL", "ui": "UI",
        "url": "URL", "vllm": "vLLM", "xlsx": "XLSX", "xurl": "xurl",
        "yaml": "YAML", "youtube": "YouTube",
    ]

    /// A skill's name as a phrase. `github-pr-workflow` is a directory
    /// name; "GitHub PR workflow" is English. The description carries the
    /// real meaning and is shown under it.
    static func title(for name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").map(String.init)
        guard !words.isEmpty else { return name }
        var out: [String] = []
        for (i, word) in words.enumerated() {
            if let fixed = acronyms[word.lowercased()] {
                out.append(fixed)
            } else if i == 0 {
                out.append(word.prefix(1).uppercased() + word.dropFirst())
            } else {
                out.append(word)
            }
        }
        // "GitHub pr workflow" would still be wrong if the first word were
        // the acronym and nothing else were touched, so the sentence's
        // first character is raised whatever produced it — except where an
        // acronym deliberately starts lower ("macOS", "vLLM").
        let joined = out.joined(separator: " ")
        if let first = words.first?.lowercased(), acronyms[first] != nil { return joined }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// "Comes with Hermes", not "builtin". The words a person can act on.
    static func origin(_ skill: Skill) -> String {
        switch skill.source {
        case "builtin": return "Comes with Moe"
        case "official": return "Installed by Moe from a trusted registry"
        case "local": return "Written for this Mac"
        case "hub": return "Installed from a registry"
        default: return skill.source.isEmpty ? "" : "From \(skill.source)"
        }
    }

    /// The quiet line under a row: what it needs, when it was last used,
    /// and why it might not be offered. Empty when there is nothing worth
    /// saying, so an ordinary row stays two lines.
    static func note(_ skill: Skill) -> String {
        var parts: [String] = []
        if !skill.missing.isEmpty {
            let list = skill.missing.joined(separator: ", ")
            parts.append(skill.missing.count == 1
                         ? "Needs \(list), which isn't installed on this Mac."
                         : "Needs \(list) — none of which are installed on this Mac.")
        }
        if skill.gated {
            parts.append("Only offered inside a \(skill.onlyIn.joined(separator: " or ")) session, which this is not.")
        }
        if skill.essential {
            parts.append("Moe needs this one to work at all, so it cannot be switched off.")
        }
        if skill.uses > 0 {
            let when = day(skill.lastUsed)
            parts.append(skill.uses == 1
                         ? "Moe has opened it once\(when.isEmpty ? "" : ", \(when)")."
                         : "Moe has opened it \(skill.uses) times\(when.isEmpty ? "" : ", last \(when)").")
        }
        return parts.joined(separator: " ")
    }

    /// "on 12 August" out of the ISO stamp `.usage.json` keeps, or "".
    ///
    /// That file writes UTC with a `+00:00` offset and fractional seconds;
    /// some rows have neither. Both are tried rather than one assumed,
    /// which is the same two-format dance `Activity.date` does for Hermes's
    /// own stamps.
    static func day(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: text)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: text)
        }
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let out = DateFormatter()
        out.dateFormat = "d MMMM"
        return "on " + out.string(from: date)
    }
}

/// One key, or the fallback — never a thrown `keyNotFound` that takes the
/// whole answer with it. See the note on `Chats.chatsValue`; this is the
/// same tool under a fourth name, because a module may not declare two
/// `value(_:_:)` on `KeyedDecodingContainer`.
private extension KeyedDecodingContainer {
    func skillsValue<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
