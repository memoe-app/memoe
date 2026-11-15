import AppKit
import MoeBrain
import MoeDesign
import MoeLedger
import SwiftUI

// Settings › Brain, as three things a person can see at once: whose
// account Moe is borrowing, which model, and how hard it thinks.
//
// What changed from the pane this replaces, and why:
//
//   * Model and thinking effort were folded under "Advanced", so the two
//     settings people most wanted to change were the two they could not
//     find. They are the page now, as rows of chips with every option in
//     view and two words under each saying what picking it gets you.
//   * The words on the chips are the provider's own — `claude-opus-4-8`,
//     `xhigh` — never a Moe-invented scale. A person on ChatGPT sees the
//     levels ChatGPT has; a person on Claude sees Claude's. See
//     BrainProviderKind.effortLevels(for:).
//   * There is no Apply. Tapping a chip saves it, tells Hermes, and checks
//     that Moe still answers; the card at the top says what happened. An
//     Apply button that sat two screens below the thing it applied was how
//     a change could be made and never take.
//   * Everything that needs a field — a key, an address, a sign-in — is in
//     one sheet behind "Change account…", so the page itself never shows a
//     text field. The sheet lists every provider Hermes offers, in three
//     plain groups, each row ending in its one next step.
//   * "Hermes" is not said anywhere on this pane or its sheet.

struct BrainPane: View {
    @ObservedObject var conductor: Conductor

    @State private var hermes: BrainStatus?
    /// The last hard failure on this provider, kept until it is fixed.
    /// Re-read on every appearance and whenever `BrainTrouble.changed` fires.
    @State private var trouble: BrainTrouble.Record?
    @State private var hermesError = ""
    @State private var brainInstalled = Bootstrap.hermesInstalled()
    @State private var brainInstalling = false
    @State private var brainInstallLine = ""

    /// A change on its way through: saving, restarting, checking.
    @State private var busy = false
    /// The last finished change's verdict, shown on the card until the
    /// next change. Nil: nothing has been changed on this visit.
    @State private var verdict: (tone: PaneBanner.Tone, text: String)?

    @State private var showAccount = false
    @State private var showSignIn = false
    @StateObject private var signInFlow = ClaudeSignInFlow()
    @State private var showChatGPT = false
    @StateObject private var chatgptFlow = ChatGPTSignInFlow()
    @State private var otherModel = ""
    @State private var showOther = false

    // MARK: What the away machine makes of this change (CLOUD-PLAN §18.30)
    //
    // **Two panes, one question, and nothing joined them.** This pane changes
    // what THIS Mac thinks with; Settings › Away changes what the away machine
    // thinks with. On 2026-09-16 the owner changed his brain here, looked at
    // his away machine, and found it still on what he had given it weeks
    // earlier — no error, and nothing on either pane that said the two could
    // disagree at all.
    //
    // So a change here now carries itself over wherever it can, and says so
    // where it cannot — at the moment of the change, on the pane the person is
    // looking at, with the button that finishes it. `AwayBrainFollow` is the
    // fold, and it lives in `MoeLedger` because this target has no tests.
    //
    // **All of this is nil for somebody with no away machine**, which is the
    // common case: the cloud's follow (`Cloud.followBrain`, nil in a build
    // without one) asks the ledger first, the fold
    // answers `noMachine`, its note is nil, and none of it renders.
    @State private var awayNote: AwayBrainFollowNote?
    @State private var awayWorking = false
    @State private var showAwaySheet = false
    @State private var awaySheetStart = ""

    private static let otherID = "\u{1}other"

    private var config: Config { conductor.config }
    private var provider: BrainProviderKind { config.brainProvider }
    private var model: String { config.brainModel }
    private var effort: String { config.brainExtras["reasoningEffort"] ?? "" }
    private var guide: BrainGuide { BrainGuide.find(provider) }

    /// The one thing still to do before this provider can answer, or nil.
    ///
    /// Two different questions, answered in this order:
    ///
    ///   * **Did the last turn fail in a way the person must fix?**
    ///     `BrainTrouble` — a revoked key, a cancelled plan, an account with
    ///     no credit. This comes first because a credential that *exists* is
    ///     not a credential that *works*, and everything below only knows
    ///     whether one exists. It is the same mistake the Claude sign-in
    ///     marker was written to close, made once per provider; this makes
    ///     it one mechanism for all of them.
    ///   * **Is there a credential at all?** the rows below, from
    ///     `configure-hermes.py --show`.
    ///
    /// It clears itself: `HermesBrain` deletes the record on the first turn
    /// that works, and `BrainSetup.probe` on the check that follows any
    /// change made on this page — so nobody has to restart Moe or find a
    /// second button to make the row go away.
    private var outstanding: String? {
        guard let hermes else { return nil }
        // "There is no credential" beats "the credential was refused",
        // because this page is the one place that can tell them apart. A
        // provider answering 401 cannot say whether the key was revoked,
        // mistyped or never sent — so the chat sentence hedges all three —
        // but `hermes.keys` says plainly whether one is stored, and "No key
        // yet." is both truer and already ends in the right next step.
        switch provider.access {
        case .claudeSignIn:
            if !hermes.claude_signed_in {
                return hermes.claude_signin_rejected
                    ? "Claude rejected the stored sign-in. Sign in again." : "Not signed in yet."
            }
        case .codexSignIn:
            if !hermes.codex_signed_in { return "Not signed in yet." }
        case .apiKey:
            if !(hermes.keys[provider.keyEnvName ?? ""] ?? false) { return "No key yet." }
        case .localServer:
            break
        }
        // A credential exists. Whether it still works is a different
        // question, and only a turn can answer it.
        if let t = trouble { return BrainTrouble.whatIsWrong(t.kind, provider) }
        return nil
    }

    /// Brain has two tabs since 2026-09-28: what Moe thinks with, and the
    /// skills it reads (Skills was its own page until the owner asked for
    /// fewer).
    enum Tab: Hashable { case brain, skills }
    @State private var tab: Tab = .brain

    init(conductor: Conductor, start: MainWindow.Section? = nil) {
        self.conductor = conductor
        _tab = State(initialValue: start == .skills ? .skills : .brain)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Brain")
            HStack {
                PaneTabs(tabs: [(Tab.brain, "What it thinks with"), (Tab.skills, "Skills")], selection: $tab)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, Theme.Space.base)
            if tab == .skills {
                SkillsPane(conductor: conductor, embedded: true)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    accountCard
                    awayCard
                    if !brainInstalled { installCard }
                    VStack(alignment: .leading, spacing: 0) {
                        Calm.header("How it thinks")
                        modelGroup
                        effortGroup
                        workLimitGroup
                    }
                    // Only while typing by voice is offered (Features.dictation):
                    // a model picker for a rewrite nobody can start is noise.
                    if Features.dictation { polishGroup }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
            }
        }
        .background(Theme.raised)
        .onAppear { loadStatus() }
        .onReceive(NotificationCenter.default.publisher(for: BrainTrouble.changed)) { _ in
            trouble = BrainTrouble.current(for: provider)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moeSignIn)) { _ in
            if provider.access == .claudeSignIn { showSignIn = true }
        }
        .sheet(isPresented: $showSignIn) {
            ClaudeSignInSheet(flow: signInFlow) { _ in
                showSignIn = false
                loadStatus()
            }
        }
        .sheet(isPresented: $showAccount) {
            BrainAccountSheet(conductor: conductor, hermes: hermes) { applied, followed in
                showAccount = false
                loadStatus()
                // The sheet did the away step itself, because the sheet is
                // where the key the person just typed lives and it must not
                // travel any further than that. All that comes back is the
                // sentence.
                if let followed {
                    awayNote = followed.note
                    awaySheetStart = followed.sheetStart
                }
                if applied { checkAfterChange(restarted: true) }
            }
        }
        .sheet(isPresented: $showAwaySheet) {
            Cloud.link.awayBrainSheet(onDone: { note in
                showAwaySheet = false
                if let note {
                    awayNote = AwayBrainFollowNote(sentence: note, needsYou: false, action: nil)
                }
            }, startOn: awaySheetStart,
               provider: provider.access == .apiKey ? provider : .anthropic,
               model: model)
        }
    }

    // MARK: - The card

    /// Who Moe is borrowing from, whether it is working, and the way to
    /// change it. The only place on the page that says anything about
    /// state, so there is one thing to read.
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Calm.header("Your AI")
            HStack(alignment: .center, spacing: Theme.Space.base) {
                ServiceIcon(name: provider.iconName, label: provider.shortName, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.accountTitle)
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: Theme.Space.small) {
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle().fill(stateColour).frame(width: 7, height: 7)
                        }
                        Text(stateLine)
                            .font(Theme.Typo.ui(12, weight: .medium))
                            .foregroundStyle(verdict?.tone == .bad ? Theme.bad : Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.base)
                VStack(alignment: .trailing, spacing: Theme.Space.small) {
                    if outstanding != nil, provider.access == .claudeSignIn {
                        PaneButton(title: "Sign in with Claude…", prominent: true) {
                            signInFlow.onStored = { conductor.restartBrain() }
                            showSignIn = true
                        }
                    }
                    if outstanding != nil, provider.access == .codexSignIn {
                        PaneButton(title: "Sign in with ChatGPT…", prominent: true) {
                            chatgptFlow.onStored = { conductor.restartBrain() }
                            showChatGPT = true
                        }
                        .sheet(isPresented: $showChatGPT) {
                            ChatGPTSignInSheet(flow: chatgptFlow) { _ in
                                showChatGPT = false
                                loadStatus()
                            }
                        }
                    }
                    PaneButton(title: "Change account…") { showAccount = true }
                        .disabled(busy)
                }
            }
            // What this way of paying is, in one sentence, for someone
            // meeting it for the first time. The next step lives on the
            // sheet's row for this provider, so it is not repeated here.
            Text(guide.cost)
                .font(Theme.Typo.prose(12.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
            if !hermesError.isEmpty {
                Text(hermesError)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What this change means for the away machine — or nothing at all, which
    /// is what everybody without one sees.
    ///
    /// It is a second card rather than a line in the first because it is about
    /// a **different computer**. Folding it into the account card's state line
    /// would give that line two subjects, and "Working, on claude-sonnet-4-6"
    /// followed by a sentence about Virginia is how a person ends up believing
    /// one of them is about the other.
    @ViewBuilder
    private var awayCard: some View {
        if awayWorking || awayNote != nil {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                    if awayWorking { ProgressView().controlSize(.small) }
                    Text(awayWorking
                         ? "Checking your away machine…"
                         : (awayNote?.sentence ?? ""))
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(awayNote?.needsYou == true ? Theme.warn : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if !awayWorking, let action = awayNote?.action {
                    PaneButton(title: action, prominent: awayNote?.needsYou == true) {
                        showAwaySheet = true
                    }
                }
            }
            .padding(Theme.Space.cosy)
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.edge)
            )
        }
    }

    /// Keep the away machine in step with the change just made here.
    ///
    /// Off the main thread and after the local change has landed, never
    /// before: this Mac's brain is the thing the person asked for, and a
    /// ledger read that is slow or a machine that cannot be reached must not
    /// hold it up or be able to fail it.
    ///
    /// `key` is a credential and is passed, used and dropped inside one
    /// detached task. It is never stored in a `@State`, and the only path that
    /// has one at all is a key the person typed on the account sheet a moment
    /// ago — see `AwayBrainSetup.follow`. Nothing at all without a cloud.
    private func followAway(_ sel: BrainSelection, baseURL: String, key: String) {
        guard let follow = Cloud.followBrain else { return }
        let here = AwayBrainFollow.Here(provider: sel.provider.rawValue, model: sel.model,
                                        baseURL: baseURL, keyInHand: !key.isEmpty)
        awayWorking = true
        awayNote = nil
        Task.detached(priority: .utility) {
            let followed = follow(here, key)
            await MainActor.run {
                awayWorking = false
                awayNote = followed.note
                awaySheetStart = followed.sheetStart
            }
        }
    }

    private var stateColour: Color {
        if let verdict {
            switch verdict.tone {
            case .good: return Theme.good
            case .bad: return Theme.bad
            case .warn: return Theme.warn
            case .neutral: return Theme.ink3
            }
        }
        if outstanding != nil { return Theme.warn }
        return conductor.connected ? Theme.good : Theme.warn
    }

    private var stateLine: String {
        if let verdict { return verdict.text }
        if let outstanding {
            return outstanding + " " + guide.nextStep
        }
        if conductor.connected {
            return "Working, on \(BrainProviderKind.prettyModel(model.isEmpty ? provider.defaultModel : model))"
                + (effort.isEmpty ? "." : ", \(effort) effort.")
        }
        return conductor.needsSignIn ? "Waiting for a sign-in." : "Starting…"
    }

    /// The part of Moe that runs a model is a separate program, and on a Mac
    /// that only downloaded the app it is not installed. Same code path as
    /// onboarding's "Set it up", so there is one installer and one set of
    /// words for it.
    private var installCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text("Moe's thinking part isn't installed yet")
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("It downloads about a gigabyte and takes a minute or two. Meetings and your connections work without it; answering a question is the part that needs it.")
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
            if brainInstalling {
                HStack(spacing: Theme.Space.small) {
                    ProgressView().controlSize(.small)
                    Text(brainInstallLine).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                PaneButton(title: "Set it up", prominent: true, action: installBrain)
                if !brainInstallLine.isEmpty {
                    Text(brainInstallLine).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.cosy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.sidebar)
        )
    }

    // MARK: - Model

    /// For ChatGPT: the account's own list, once read. A ChatGPT plan offers
    /// what OpenAI says it offers, which is not a list Moe can type in —
    /// several of the fixed ones failed on the owner's account (2026-09-09).
    @State private var liveCodexModels: [String]?

    private var offeredModels: [String] {
        if provider == .codex, let live = liveCodexModels { return live }
        return provider.curatedModels
    }

    /// The saved model is not one this ChatGPT account offers.
    private var modelNotOffered: Bool {
        provider == .codex && !model.isEmpty && (liveCodexModels.map { !$0.contains(model) } ?? false)
    }

    private var modelChips: [ChoiceChip] {
        var ids = offeredModels
        // The model in use is always a chip, even one typed under Other…,
        // so the page shows what is set rather than a row with nothing on.
        if !model.isEmpty, !ids.contains(model) { ids.insert(model, at: 0) }
        var chips = ids.map { ChoiceChip(id: $0, title: $0, caption: provider.modelCaption($0)) }
        chips.append(ChoiceChip(id: Self.otherID, title: "Other…", caption: "Type a model name"))
        return chips
    }

    /// "sonnet — Quick and capable": the menu's words for a model.
    private func modelLabel(_ id: String) -> String {
        let caption = provider.modelCaption(id)
        return caption.isEmpty ? id : "\(id) — \(caption)"
    }

    /// A row with a menu, like Settings › Voice, where it was a wall of
    /// chips (2026-09-28).
    private var modelGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Model",
                       detail: provider.curatedModels.isEmpty && model.isEmpty
                        ? (provider.access == .localServer
                           ? "Type the name of a model your server has loaded."
                           : "Type the name of a model this service offers.")
                        : "Sees your screen \(capabilities.vision.mark)  ·  Uses tools \(capabilities.tools.mark)") {
                SettingMenu(value: showOther ? "Other…" : (model.isEmpty ? "Choose" : modelLabel(model))) {
                    ForEach(modelChips) { chip in
                        Button(chip.id == Self.otherID ? "Other…" : modelLabel(chip.id)) {
                            if chip.id == Self.otherID {
                                showOther = true
                                otherModel = provider.curatedModels.contains(model) ? "" : model
                            } else {
                                showOther = false
                                choose(model: chip.id)
                            }
                        }
                    }
                }
                .disabled(busy)
            }
            if showOther {
                Calm.Reveal {
                    HStack(spacing: Theme.Space.small) {
                        TextField("Model name", text: $otherModel, prompt: Text(otherPrompt))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 360)
                            .onSubmit(useOther)
                        PaneButton(title: "Use it", prominent: true, action: useOther)
                            .disabled(otherModel.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                    .padding(.vertical, 6)
                }
            }
            if modelNotOffered {
                Text("Your ChatGPT plan doesn't offer \(model), so questions on it fail. Pick another.")
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            if let why = capabilities.missingCaption {
                Text(why)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
        }
    }

    private var otherPrompt: String {
        switch provider {
        case .claudeCode: return "opus, sonnet, haiku, or a full name like claude-sonnet-4-6"
        case .openRouter: return "company/model, e.g. anthropic/claude-sonnet-4.5"
        case .lmStudio, .local: return "the model name your server lists"
        default: return "a model name this service accepts"
        }
    }

    private func useOther() {
        let id = otherModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        showOther = false
        choose(model: id)
    }

    // MARK: - Effort

    private var effortLevels: [String] { provider.effortLevels(for: model) }

    @ViewBuilder
    private var effortGroup: some View {
        if !effortLevels.isEmpty {
            let current = effortLevels.contains(effort) ? effort : ""
            SettingRow(title: "How hard it thinks", detail: effortNote) {
                SettingMenu(value: current.isEmpty ? "Default"
                            : "\(current) — \(BrainProviderKind.effortCaption(current))") {
                    Button("Default — let \(provider.shortName) decide") { choose(effort: "") }
                    ForEach(effortLevels, id: \.self) { level in
                        Button("\(level) — \(BrainProviderKind.effortCaption(level))") { choose(effort: level) }
                    }
                }
                .disabled(busy)
            }
        }
    }

    private var effortNote: String {
        let own = "Higher is slower and more thorough."
        switch provider {
        case .claudeCode:
            return own
        case .lmStudio, .local:
            return own + " A model that doesn't think ignores it."
        default:
            return own + " Takes effect on your next question."
        }
    }

    // MARK: - Work limit

    /// docs/DEFAULTS.md row 32. Only on the Claude plan:
    /// `claude_code.turn_timeout` bounds the Claude Code child's turn and
    /// nothing else, so on a key or a local server this row would promise a
    /// limit that is not there.
    @ViewBuilder
    private var workLimitGroup: some View {
        if provider == .claudeCode {
            SettingRow(title: "Longest it works on one thing",
                       detail: "If a task is still going when time is up, Moe stops it and tells you.") {
                Calm.Segments(options: WorkLimit.choices.map { (String($0), $0 == 60 ? "1 hour" : "\($0) min") },
                              selection: Binding(
                                get: { String(config.workLimitMinutes ?? WorkLimit.defaultMinutes) },
                                set: { if let m = Int($0), !busy { choose(workLimit: m) } }))
            }
        }
    }

    // MARK: - Dictation clean-up

    private var polishGroup: some View {
        SettingGroup(title: "Dictation clean-up") {
            SettingRow(title: "Tidy dictation with",
                       detail: "The quick rewrite of what you dictate. A smaller model keeps typing fast.",
                       last: true) {
                SettingMenu(value: config.dictationPolishModel.isEmpty ? "Same as the brain"
                            : config.dictationPolishModel) {
                    Picker("", selection: Binding(
                        get: { config.dictationPolishModel },
                        set: { choose(polish: $0) })) {
                        Text("Same as the brain").tag("")
                        ForEach(provider.curatedModels, id: \.self) { Text($0).tag($0) }
                        if !config.dictationPolishModel.isEmpty,
                           !provider.curatedModels.contains(config.dictationPolishModel) {
                            Text(config.dictationPolishModel).tag(config.dictationPolishModel)
                        }
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
                .disabled(busy)
            }
        }
    }

    // MARK: - Capabilities

    private var capabilities: BrainCapabilities { config.brainCapabilities }

    // MARK: - Changes

    private func choose(model id: String) {
        guard id != model else { return }
        apply(BrainSelection(provider: provider, model: id, reasoningEffort: effort),
              restart: false, follows: true)
    }

    private func choose(effort level: String) {
        guard level != effort else { return }
        // The child reads its `--effort` when it is built, so a new level
        // means a new child; every API transport takes it per request.
        // `follows: false` — and it is not an oversight. A brain document
        // carries `kind`, `provider`, `model` and `base_url` and no thinking
        // effort at all (`moeledger.brain.check_body`), so there is nothing
        // for the machine to be brought up to date with, and publishing an
        // identical document would be a ledger record, a sync and a line on
        // this pane saying something happened when nothing did.
        apply(BrainSelection(provider: provider, model: model, reasoningEffort: level),
              restart: provider == .claudeCode, follows: false)
    }

    /// Save the choice and write it into ~/.hermes, by the same road the
    /// model and effort chips take (`BrainSetup.run`, off the main thread).
    /// No restart and no probe: Hermes reads the limit afresh on the next
    /// turn. A refusal puts the old choice back, so the chips never show a
    /// limit that is not set.
    private func choose(workLimit minutes: Int) {
        // Nil — never chosen — differs from every chip, so picking the 30
        // shown for it is recorded as a choice, and the launch run then holds
        // Hermes to it.
        let before: Int? = config.workLimitMinutes
        guard before != minutes else { return }
        conductor.config = Config.update { $0.workLimitMinutes = minutes }
        busy = true
        verdict = (.neutral, "Saving…")
        Task {
            let written = await Task.detached(priority: .userInitiated) {
                BrainSetup.setWorkLimit(minutes: minutes)
            }.value
            if case .failure(let f) = written {
                conductor.config = Config.update { $0.workLimitMinutes = before }
                finish(bad: f.message)
                return
            }
            busy = false
            verdict = (.good, "Saved. Moe may work on one thing for up to \(WorkLimit.label(minutes)).")
        }
    }

    private func choose(polish id: String) {
        guard id != config.dictationPolishModel else { return }
        conductor.applyBrain(BrainSelection(config: config),
                             baseURL: config.brainExtras["baseURL"] ?? "",
                             polishModel: id, restartGateway: false)
    }

    /// Write the choice, hand it to the live brain, and ask one question to
    /// prove it answers. The card reads out each step and then the verdict.
    private func apply(_ sel: BrainSelection, restart: Bool, follows: Bool) {
        let url = config.brainExtras["baseURL"] ?? provider.defaultBaseURL
        let polish = config.dictationPolishModel
        busy = true
        verdict = (.neutral, "Saving…")
        Task {
            let written = await Task.detached(priority: .userInitiated) {
                BrainSetup.apply(sel, baseURL: url, key: nil)
            }.value
            if case .failure(let f) = written {
                finish(bad: f.message)
                return
            }
            conductor.applyBrain(sel, baseURL: url, polishModel: polish, restartGateway: restart)
            loadStatus()
            // Started before the probe, not after it: they are two different
            // computers and neither answer should wait on the other. No key —
            // this path never has one, so an away machine on a different
            // provider is reported rather than given anything.
            if follows { followAway(sel, baseURL: url, key: "") }
            await check(sel, restarted: restart)
        }
    }

    /// After the account sheet applied a change of its own.
    private func checkAfterChange(restarted: Bool) {
        busy = true
        verdict = (.neutral, restarted ? "Switching…" : "Checking…")
        Task { await check(BrainSelection(config: conductor.config), restarted: restarted) }
    }

    private func check(_ sel: BrainSelection, restarted: Bool) async {
        verdict = (.neutral, restarted ? "Switching to \(sel.provider.shortName)…" : "Checking…")
        let deadline = Date().addingTimeInterval(120)
        while !conductor.connected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard conductor.connected else {
            // `brainStatus` is an honest diagnostic and used to be appended
            // here: its failed case reads "Not running. exit 1: <log tail>".
            // That is a sentence for the log, which is where it goes now.
            Log.write("brain switch timed out: \(conductor.brainStatus)")
            finish(bad: "Moe didn't come back within two minutes. "
                      + "Try switching again, or pick the model you were on before.")
            return
        }
        verdict = (.neutral, "Checking \(BrainProviderKind.prettyModel(sel.model.isEmpty ? sel.provider.defaultModel : sel.model))…")
        if let problem = await BrainSetup.probe(config: conductor.config, brain: sel) {
            finish(bad: problem)
            return
        }
        await conductor.refreshBrainCapabilities()
        busy = false
        verdict = (.good, "It works. Moe is thinking with \(sel.provider.shortName) "
                   + "(\(BrainProviderKind.prettyModel(sel.model.isEmpty ? sel.provider.defaultModel : sel.model)))"
                   + (sel.reasoningEffort.isEmpty ? "." : ", \(sel.reasoningEffort) effort."))
    }

    private func finish(bad message: String) {
        busy = false
        verdict = (.bad, message)
        Log.write("brain settings: \(message)")
    }

    private func loadStatus() {
        trouble = BrainTrouble.current(for: provider)
        let isCodex = provider == .codex
        Task.detached(priority: .userInitiated) {
            let result = BrainSetup.show()
            // Only once signed in: before that there is no account to ask.
            var live: [String]?
            if isCodex, case .success(let s) = result, s.codex_signed_in {
                live = BrainSetup.codexModels()
            }
            await MainActor.run {
                switch result {
                case .success(let s): hermes = s; hermesError = ""
                case .failure(let f): hermes = nil; hermesError = f.message
                }
                liveCodexModels = live
            }
        }
    }

    private func installBrain() {
        brainInstalling = true
        brainInstallLine = "Starting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Bootstrap.installHermes { line in
                DispatchQueue.main.async { brainInstallLine = line }
            }
            DispatchQueue.main.async {
                brainInstalling = false
                brainInstalled = ok || Bootstrap.hermesInstalled()
            }
        }
    }
}

// MARK: - Change account

/// Every way of giving Moe something to think with, in three plain groups,
/// each row ending in its one next step. Choosing a row shows what that
/// row needs — a sign-in button, a key, an address — right under it, and
/// Done writes the lot at once.
struct BrainAccountSheet: View {
    @ObservedObject var conductor: Conductor
    let hermes: BrainStatus?
    /// Called on close; true when a change was written and the brain told,
    /// with what became of the away machine — nil when nothing was written, or
    /// when there is no away machine to keep in step.
    ///
    /// **The away step happens in here rather than in the pane**, because this
    /// is where the key the person just typed lives. Handing it out through
    /// this closure so the pane could do the publishing would put a credential
    /// in a second place for no reason; what comes back is a sentence.
    let done: (Bool, BrainFollowed?) -> Void

    @State private var chosen: BrainProviderKind
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var testing = false
    @State private var testResult = ""
    @State private var testFailed = false
    @State private var showChatGPT = false
    @StateObject private var chatgptFlow = ChatGPTSignInFlow()
    @State private var busy = false
    @State private var problem = ""
    @State private var showSignIn = false
    @StateObject private var signInFlow = ClaudeSignInFlow()
    /// Signed in during this sheet, so the row can say so before --show
    /// has been asked again.
    @State private var signedInNow: Set<BrainProviderKind> = []

    init(conductor: Conductor, hermes: BrainStatus?,
         done: @escaping (Bool, BrainFollowed?) -> Void) {
        self.conductor = conductor
        self.hermes = hermes
        self.done = done
        let p = conductor.config.brainProvider
        _chosen = State(initialValue: p)
        _baseURL = State(initialValue: conductor.config.brainExtras["baseURL"] ?? p.defaultBaseURL)
    }

    private var current: BrainProviderKind { conductor.config.brainProvider }

    private var canApply: Bool {
        guard !busy else { return false }
        if chosen.usesBaseURL, !baseURL.hasPrefix("http") { return false }
        if chosen.access == .apiKey, !hasKey(chosen), apiKey.isEmpty { return false }
        return true
    }

    private func hasKey(_ p: BrainProviderKind) -> Bool {
        hermes?.keys[p.keyEnvName ?? ""] ?? false
    }

    private func signedIn(_ p: BrainProviderKind) -> Bool {
        if signedInNow.contains(p) { return true }
        switch p.access {
        case .claudeSignIn: return hermes?.claude_signed_in == true
        case .codexSignIn:  return hermes?.codex_signed_in == true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                Text("Which account should Moe use?")
                    .font(Theme.Typo.heading(20))
                    .foregroundStyle(Theme.ink)
                Text("Moe borrows one you already have. It charges nothing and has no account of its own.")
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.roomy) {
                    group("A plan you already pay for",
                          BrainProviderKind.allCases.filter { $0.access == .claudeSignIn || $0.access == .codexSignIn })
                    group("A key you have — you pay by the word",
                          BrainProviderKind.allCases.filter { $0.access == .apiKey })
                    group("On this Mac — private, and free",
                          BrainProviderKind.allCases.filter { $0.access == .localServer })
                }
                .padding(.trailing, Theme.Space.small)
            }
            if !problem.isEmpty {
                Text(problem)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.small) {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                PaneButton(title: "Cancel") { done(false, nil) }
                    .keyboardShortcut(.cancelAction)
                PaneButton(title: chosen == current ? "Done" : "Use \(chosen.shortName)", prominent: true, action: apply)
                    .disabled(!canApply)
                    .opacity(canApply ? 1 : 0.5)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.wide)
        .frame(width: 580, height: 620)
        .background(Theme.raised)
        .sheet(isPresented: $showSignIn) {
            ClaudeSignInSheet(flow: signInFlow) { _ in
                showSignIn = false
                signedInNow.insert(.claudeCode)
            }
        }
    }

    private func group(_ title: String, _ kinds: [BrainProviderKind]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            settingsLabel(title)
            VStack(spacing: 0) {
                ForEach(kinds) { kind in row(kind) }
            }
        }
    }

    private func row(_ kind: BrainProviderKind) -> some View {
        let on = kind == chosen
        let guide = BrainGuide.find(kind)
        return VStack(alignment: .leading, spacing: Theme.Space.base) {
            Button {
                choose(kind)
            } label: {
                HStack(alignment: .center, spacing: Theme.Space.base) {
                    ServiceIcon(name: kind.iconName, label: kind.shortName, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.snug) {
                            Text(kind.displayName.components(separatedBy: " — ").first ?? kind.displayName)
                                .font(Theme.Typo.ui(13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            if kind == current {
                                tag("In use", Theme.accentDeep)
                            } else if signedIn(kind) || hasKey(kind) {
                                tag(signedIn(kind) ? "Signed in" : "Key stored", Theme.good)
                            }
                            // Both plans, equally (docs/DEFAULTS.md row 1):
                            // the same badge the first-run screen shows.
                            if guide.isRecommended {
                                tag("Recommended", Theme.accentDeep)
                            }
                        }
                        Text(guide.cost)
                            .font(Theme.Typo.ui(11))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.small)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Theme.accent : Theme.ruleStrong)
                        .accessibilityLabel(on ? "Selected" : "Not selected")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if on { needs(kind, guide: guide) }
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(on ? Theme.selected : Color.clear)
        )
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(Theme.Typo.label(9))
            .tracking(Theme.tracking)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 2)
            .background(colour.opacity(0.14), in: Capsule())
            .foregroundStyle(colour)
    }

    /// What this row still needs, under it: the one next step, and the
    /// field or button that does it.
    @ViewBuilder
    private func needs(_ kind: BrainProviderKind, guide: BrainGuide) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text(guide.whatItIs)
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !guide.tradeOff.isEmpty {
                Text(guide.tradeOff)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch kind.access {
            case .claudeSignIn:
                HStack(spacing: Theme.Space.small) {
                    PaneButton(title: signedIn(kind) ? "Sign in again…" : "Sign in with Claude…",
                               prominent: !signedIn(kind)) {
                        signInFlow.onStored = { conductor.restartBrain() }
                        showSignIn = true
                    }
                    Text(signedIn(kind) ? "Signed in." : "A page opens in your browser; you say yes there and come back.")
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .codexSignIn:
                HStack(spacing: Theme.Space.small) {
                    PaneButton(title: signedIn(kind) ? "Sign in again…" : "Sign in with ChatGPT…",
                               prominent: !signedIn(kind)) {
                        chatgptFlow.onStored = { signedInNow.insert(.codex) }
                        showChatGPT = true
                    }
                    Text(signedIn(kind) ? "Signed in." : "A ChatGPT page opens in your browser; you enter a code there and come back.")
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .sheet(isPresented: $showChatGPT) {
                    ChatGPTSignInSheet(flow: chatgptFlow) { _ in showChatGPT = false }
                }
            case .apiKey:
                if kind.usesBaseURL {
                    TextField("Address", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                }
                SecureField(hasKey(kind) ? "Stored — paste a new key to replace it" : "Paste your key here",
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                if kind.usesBaseURL {
                    HStack(spacing: Theme.Space.small) {
                        PaneButton(title: testing ? "Testing…" : "Test") { test(kind) }
                            .disabled(testing || !baseURL.hasPrefix("http"))
                        if !testResult.isEmpty {
                            Image(systemName: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(testFailed ? Theme.warn : Theme.good)
                                .accessibilityLabel(testFailed ? "Failed" : "Worked")
                            Text(testResult)
                                .font(Theme.Typo.ui(11))
                                .foregroundStyle(testFailed ? Theme.warn : Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(hasKey(kind) ? "Your key is kept on this Mac, readable only by you. It is never shown here again."
                                  : "The key is kept on this Mac, readable only by you.")
                    .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
            case .localServer:
                TextField("Address", text: $baseURL, prompt: Text(kind.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                Text("The address the server answers on, ending in /v1. Load a model there first.")
                    .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(.leading, 30 + Theme.Space.base)
        .padding(.bottom, Theme.Space.tight)
    }

    private func choose(_ kind: BrainProviderKind) {
        guard kind != chosen else { return }
        chosen = kind
        apiKey = ""
        testResult = ""
        testFailed = false
        problem = ""
        baseURL = kind == current ? (conductor.config.brainExtras["baseURL"] ?? kind.defaultBaseURL)
                                  : kind.defaultBaseURL
    }

    private func test(_ kind: BrainProviderKind) {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            testFailed = true
            testResult = "Paste the key to test it — the stored one is never read back out."
            return
        }
        testing = true
        testResult = ""
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let model = kind == current ? conductor.config.brainModel : kind.defaultModel
        Task {
            let result = await BrainSetup.testEndpoint(baseURL: url, key: key, model: model)
            testing = false
            switch result {
            case .success(let good): testFailed = false; testResult = good
            case .failure(let bad):  testFailed = true;  testResult = bad.message
            }
        }
    }

    /// Write the choice and hand it to the brain. A different provider, a
    /// new key or a new address means the gateway starts again on it; the
    /// pane behind runs the check and reads out the verdict.
    private func apply() {
        let before = conductor.config
        let sameProvider = chosen == before.brainProvider
        let effort = sameProvider ? (before.brainExtras["reasoningEffort"] ?? "") : ""
        let kind = chosen
        let url = chosen.usesBaseURL ? (baseURL.isEmpty ? chosen.defaultBaseURL : baseURL) : ""
        let key = apiKey.isEmpty ? nil : apiKey
        let restart = !sameProvider || key != nil || url != (before.brainExtras["baseURL"] ?? "")
        // Nothing to write: the sheet was opened and closed on the same row.
        guard restart || !sameProvider else { done(false, nil); return }
        busy = true
        problem = ""
        Task {
            let keepModel = before.brainModel
            let (written, sel) = await Task.detached(priority: .userInitiated) {
                // A new ChatGPT account starts on a model it offers.
                let model = sameProvider ? keepModel : BrainSetup.startingModel(for: kind)
                let sel = BrainSelection(provider: kind, model: model, reasoningEffort: effort)
                return (BrainSetup.apply(sel, baseURL: url, key: key), sel)
            }.value
            if case .failure(let f) = written {
                busy = false
                problem = f.message
                return
            }
            conductor.applyBrain(sel, baseURL: url,
                                 polishModel: sameProvider ? before.dictationPolishModel : "",
                                 restartGateway: restart)
            // **The away machine, while the key is still here and nowhere
            // else.** The sheet stays up for this — a local ledger read and,
            // at most, one publish — because closing first would mean handing
            // the credential to the pane so it could finish the job, and a
            // credential in a second place for the sake of a spinner is the
            // trade this whole slice refuses to make. `busy` keeps the button
            // reading "Working…" throughout.
            let here = AwayBrainFollow.Here(provider: sel.provider.rawValue, model: sel.model,
                                            baseURL: url, keyInHand: key != nil)
            let sending = key ?? ""
            let follow = Cloud.followBrain
            let followed = await Task.detached(priority: .userInitiated) {
                follow?(here, sending)
            }.value
            // The field is the only copy this sheet keeps and it must not
            // survive the sheet.
            apiKey = ""
            busy = false
            done(true, followed)
        }
    }
}
