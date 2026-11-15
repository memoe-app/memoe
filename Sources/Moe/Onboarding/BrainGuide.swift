import AppKit
import Foundation
import MoeBrain

// What Moe says about each way of giving it something to think with, written
// once and read by both the onboarding screen and the Brain pane.
//
// The failure this file exists to prevent: onboarding used to say "Sign in
// with your Claude account" as though that were the only way. It is one of
// eleven (BrainProviderKind), across four ways of paying
// (BrainProviderKind.Access). A person who already pays for ChatGPT, or who
// has a key, or who wants nothing to leave the Mac, was told none of that.
//
// Rules this file keeps, and scripts/test-onboarding.sh enforces:
//
//   * every case of BrainProviderKind has an entry — the switch in
//     `guide(for:)` is exhaustive, so a twelfth provider will not compile
//     until someone writes its words;
//   * no entry may be empty, and every one ends in a `nextStep` — the single
//     next thing the person does, not a description of a state;
//   * `whatItIs` never assumes the reader knows what a subscription plan, an
//     API key or a local model is. One line each, no jargon;
//   * `tradeOff` is only ever a real difference, taken from what the
//     capability table actually knows (BrainCapabilityTable.lookup on the
//     provider's own defaultModel), never a guess.

struct BrainGuide: Sendable {
    let kind: BrainProviderKind
    /// The row's heading. Reuses the provider's own display name so the
    /// onboarding screen and the Brain pane cannot drift apart.
    var name: String { kind.displayName }
    /// One sentence: what this thing is, for someone who has never met it.
    let whatItIs: String
    /// What it costs the person, in money words rather than billing words.
    let cost: String
    /// The one next thing to do. Never a state, always a verb.
    let nextStep: String
    /// A real capability difference, or "" when there is none worth saying.
    var tradeOff: String = ""

    /// Moe's own recommendation: a plan the person already pays for.
    /// Claude and ChatGPT are recommended equally (docs/DEFAULTS.md row 1),
    /// then a key, then this Mac.
    var isRecommended: Bool { kind == .claudeCode || kind == .codex }

    // MARK: - One entry per provider

    static func guide(for kind: BrainProviderKind) -> BrainGuide {
        switch kind {
        case .claudeCode:
            return BrainGuide(
                kind: kind,
                whatItIs: "A Claude plan is the monthly one you may already pay Anthropic for — the same account you use on claude.ai. Moe borrows it; you are not charged twice, and nothing is billed by the question.",
                cost: "Nothing on top of the plan you already have.",
                nextStep: "Click Sign in with Claude. A page opens in your browser, you say yes there, and you come back here.")

        case .codex:
            return BrainGuide(
                kind: kind,
                whatItIs: "A ChatGPT plan is the monthly one you may already pay OpenAI for — the same account you use on chatgpt.com. Moe borrows it the same way, and nothing is billed by the question.",
                cost: "Nothing on top of the plan you already have.",
                nextStep: "Click Sign in with ChatGPT. It shows you a code to approve in your browser, once.")

        case .anthropic:
            return BrainGuide(
                kind: kind,
                whatItIs: "A key is a long password a company gives you so a program can use its models on your behalf. Anthropic hands them out at console.anthropic.com. You are billed for what you use, by the word, with no monthly plan.",
                cost: "Pennies a question, billed by Anthropic. You set your own spending cap there.",
                nextStep: "Get a key from console.anthropic.com, then paste it into Settings › Brain.")

        case .openAI:
            return BrainGuide(
                kind: kind,
                whatItIs: "The same idea, from OpenAI: a long password from platform.openai.com that lets Moe use their models, billed by the word rather than monthly.",
                cost: "Pennies a question, billed by OpenAI. You set your own spending cap there.",
                nextStep: "Get a key from platform.openai.com, then paste it into Settings › Brain.")

        case .openRouter:
            return BrainGuide(
                kind: kind,
                whatItIs: "One key that reaches hundreds of models from different companies, so you can change your mind later without a second account anywhere. Models are named the-company/the-model.",
                cost: "Pennies a question, billed by OpenRouter, whichever model you pick.",
                nextStep: "Get a key from openrouter.ai, then paste it into Settings › Brain and pick a model.")

        case .gemini:
            return BrainGuide(
                kind: kind,
                whatItIs: "Google's version: a long password from aistudio.google.com. It has a free allowance, so this is the one way to try Moe without paying anything or installing anything.",
                cost: "Free up to Google's daily allowance, then pennies a question.",
                nextStep: "Get a key from aistudio.google.com, then paste it into Settings › Brain.")

        case .deepSeek:
            return BrainGuide(
                kind: kind,
                whatItIs: "DeepSeek is a Chinese company whose models cost a fraction of what the others charge for similar work. A key from platform.deepseek.com lets Moe use them, billed by the word.",
                cost: "A fraction of a penny a question, billed by DeepSeek. Cheapest of the paid options here.",
                nextStep: "Get a key from platform.deepseek.com, then paste it into Settings › Brain.")

        case .xai:
            return BrainGuide(
                kind: kind,
                whatItIs: "xAI makes Grok, the model behind X's assistant. A key from console.x.ai lets Moe use it, billed by the word rather than monthly — and it is the one that reads what is happening on X right now.",
                cost: "Pennies a question, billed by xAI. You set your own spending cap there.",
                nextStep: "Get a key from console.x.ai, then paste it into Settings › Brain.")

        case .customKey:
            return BrainGuide(
                kind: kind,
                whatItIs: "Any other company whose service works the same way OpenAI's does — DeepSeek, Groq, Mistral, Together, xAI, one your workplace runs, or a model you host yourself. You give Moe the web address it answers on and the key that company gave you, and Moe treats it like any of the others.",
                cost: "Whatever that company charges you. Moe adds nothing and sees no bill.",
                nextStep: "Paste the service's address, ending in /v1, and its key, then press Test to check them before you Apply.")

        case .lmStudio:
            return BrainGuide(
                kind: kind,
                whatItIs: "LM Studio is a free app that downloads a model onto this Mac and runs it here. Nothing you say goes to any company — the answering happens on your own machine, and it works with the wi-fi off.",
                cost: "Free. It uses your Mac's memory rather than anyone's servers.",
                nextStep: "Install LM Studio, load a model, start its local server, then choose it in Settings › Brain.",
                tradeOff: Self.localTradeOff)

        case .local:
            return BrainGuide(
                kind: kind,
                whatItIs: "Ollama and friends do the same job from the command line: the model lives on this Mac and answers here, so nothing you say leaves the machine.",
                cost: "Free. It uses your Mac's memory rather than anyone's servers.",
                nextStep: "Start Ollama (or any server that speaks the same language), then give Moe its address in Settings › Brain.",
                tradeOff: Self.localTradeOff)
        }
    }

    /// Said once, for both on-this-Mac options. A model small enough to run
    /// on a laptop is slower and less capable than one in a data centre, and
    /// whether it can look at a picture or use Moe's connections depends
    /// entirely on which model you loaded — which is exactly what
    /// `BrainCapabilityTable.lookup(provider:"lmstudio"…)` returns as
    /// unknown for tools, and works out per family for vision.
    static let localTradeOff = """
    Slower, and less sure of itself, than a model in a data centre. Whether it can look at \
    your screen or use your connections depends on which model you load — Moe shows you what \
    the one you picked can do, and quietly stops offering what it can't.
    """

    static let all: [BrainGuide] = BrainProviderKind.allCases.map(guide(for:))

    static func find(_ kind: BrainProviderKind) -> BrainGuide { guide(for: kind) }

    /// What the person gives up on this provider's own default model, in
    /// plain words — taken from the capability table rather than written by
    /// hand, so it can never claim a model can do something it can't.
    /// Nil when the default model can do everything Moe uses.
    var capabilityCost: String? {
        BrainGuide.capabilityCost(provider: kind, model: kind.defaultModel)
    }

    /// The same for any model, so the Brain pane can say it about whatever
    /// is actually selected. `BrainCapabilities.missingCaption` is the
    /// wording; this only decides whether there is anything to say.
    static func capabilityCost(provider: BrainProviderKind, model: String) -> String? {
        BrainCapabilityTable.lookup(provider: provider.rawValue, model: model).missingCaption
    }

    var json: [String: Any] {
        ["id": kind.rawValue, "name": name, "access": BrainGuide.accessID(kind.access),
         "whatItIs": whatItIs, "cost": cost, "nextStep": nextStep, "tradeOff": tradeOff,
         "recommended": isRecommended]
    }

    static func accessID(_ a: BrainProviderKind.Access) -> String {
        switch a {
        case .claudeSignIn: return "claude-sign-in"
        case .codexSignIn:  return "chatgpt-sign-in"
        case .apiKey:       return "api-key"
        case .localServer:  return "on-this-mac"
        }
    }
}

// MARK: - The four ways in, as the onboarding screen groups them

/// One row on the brain screen. Four rows, not eight: the question a person
/// can actually answer is "what do you already pay for?", and the eleven
/// providers collapse onto four answers (BrainProviderKind.Access).
struct BrainPath: Sendable, Identifiable {
    let id: String
    /// The row's heading.
    let title: String
    /// One line, no jargon, no assumed knowledge.
    let whatItIs: String
    /// The button.
    let action: String
    /// The providers this row covers, in the order the pane lists them.
    let providers: [BrainProviderKind]

    static let claude = BrainPath(
        id: "claude-sign-in",
        title: "Sign in with Claude",
        whatItIs: "Already pay for Claude? Moe uses that plan. Nothing extra to buy.",
        action: "Sign in with Claude",
        providers: [.claudeCode])

    static let chatgpt = BrainPath(
        id: "chatgpt-sign-in",
        title: "Sign in with ChatGPT",
        whatItIs: "Already pay for ChatGPT? Moe uses that plan. Nothing extra to buy.",
        action: "Sign in with ChatGPT",
        providers: [.codex])

    static let key = BrainPath(
        id: "api-key",
        title: "Paste a key you already have",
        whatItIs: "A key is a company's long password; you pay by the word. Anthropic, OpenAI, OpenRouter, Gemini, DeepSeek, xAI and more.",
        action: "Use a key",
        providers: [.anthropic, .openAI, .openRouter, .gemini, .deepSeek, .xai, .customKey])

    static let onThisMac = BrainPath(
        id: "on-this-mac",
        title: "Run a model on this Mac",
        whatItIs: "Free and private: a model that lives here, so nothing you say leaves this Mac. Slower, and it depends on which model you load.",
        action: "Set this up",
        providers: [.lmStudio, .local])

    /// Whose account a sign-in row borrows, as "Signed in with …" names
    /// it — the row's own title, less the verb.
    var accountName: String { title.replacingOccurrences(of: "Sign in with ", with: "") }

    /// In the order the screen offers them: the two recommendations first,
    /// as a pair. Under them the screen adds a row of its own for someone
    /// with no plan (`Onboarding.freeStartTitle`) — a way through the key
    /// row, not a fifth kind of access.
    static let all: [BrainPath] = [claude, chatgpt, key, onThisMac]

    /// A plan the person already pays for — Claude or ChatGPT, recommended
    /// equally (docs/DEFAULTS.md row 1). Keys and local models are offered
    /// below them, unbadged.
    var recommended: Bool { providers.contains { BrainGuide.find($0).isRecommended } }

    var json: [String: Any] {
        ["id": id, "title": title, "whatItIs": whatItIs, "action": action,
         "providers": providers.map(\.rawValue), "recommended": recommended]
    }
}

// MARK: - Starting the ChatGPT sign-in

/// The ChatGPT sign-in is still a terminal flow — the CLI shows a code the
/// person types into a browser page — so both the Brain pane and the
/// onboarding screen hand it off the same way. The Claude one is in-app
/// (ClaudeSignInSheet) and needs nothing here.
enum CodexSignIn {
    static let script = "hermes-codex-signin.sh"

    /// Opens it in Terminal. Returns the line to show the person: what just
    /// happened, or what to do because it didn't. Never silent — a button
    /// that appears to do nothing is the failure this returns instead of.
    @MainActor
    static func start() -> String {
        var candidates = [Paths.home.appendingPathComponent("scripts/\(script)").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("scripts/\(script)").path)
        }
        if let c = Payload.checkoutPath("scripts/\(script)") { candidates.append(c) }
        guard let target = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "Couldn't find \(script)."
        }
        var err: NSDictionary?
        NSAppleScript(source: Terminal.script(running: target))?.executeAndReturnError(&err)
        guard err == nil else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target, forType: .string)
            return "Command copied — paste it into Terminal, then come back here."
        }
        return "A window opened. Follow it, then come back here."
    }
}
