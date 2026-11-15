import AppKit
import MoeBrain
import MoeDesign
import MoeIsland
import MoeVoice
import SwiftUI

// Settings › Voice — one page for how you talk to Moe and how it answers.
//
// Until 2026-09-25 this was three screens: Voice › Talking to Moe (seventeen
// rows, three of them about the screen rather than the voice), Voice › How
// Moe sounds (the engine and the voice as two choices), and Settings ›
// Replies (eleven more). The owner's word for it was "overstimulating", and
// the design he picked (D, ~/moe-voice-notes/voice-settings-proposal.md) is
// this: three short sections of independent, plainly named choices, each
// main switch opening its own one or two controls when it is on, and the
// rarely touched rest behind one "More". Nothing was dropped — every
// person-facing option is on the page or under More; the screen rows moved
// to Settings › Permissions. `VoiceSettingsModel` holds the bindings and the
// reveal rules, and is what the tests drive.

struct VoicePane: View {
    @ObservedObject var conductor: Conductor

    enum Tab: Hashable { case typing, talking }
    @State private var tab: Tab

    /// The tabs, only while dictation is a feature (`Features.dictation`,
    /// docs/DEFAULTS.md row 4). Without it the page has no tab bar at all.
    static var tabs: [(Tab, String)] {
        Features.dictation ? [(.typing, "Typing by voice"), (.talking, "Talking to Moe")] : [(.talking, "Talking to Moe")]
    }

    /// The pane's name. "& Dictation" only while there is a dictation tab.
    static var title: String { Features.dictation ? "Voice & Dictation" : "Voice" }

    /// A state to draw instead of the real one — `Moe --settings-snapshot`
    /// poses the download offer and the open "More" this way. Nothing here
    /// starts a download.
    struct Pose {
        var engine: TtsEngineKind? = nil
        var pocketDownloaded: Bool? = nil
        var downloading = false
        var downloadFraction = 0.0
        var downloadNote = ""
        var moreOpen = false
    }
    private let posed: Pose?

    init(conductor: Conductor, tab: Tab? = nil, posed: Pose? = nil) {
        self.conductor = conductor
        self.posed = posed
        let wanted = tab ?? .talking
        _tab = State(initialValue: Self.tabs.contains { $0.0 == wanted } ? wanted : Self.tabs[0].0)
        _moreOpen = State(initialValue: posed?.moreOpen ?? false)
    }

    /// The engine and voice as picked. They are applied the moment they are
    /// picked, except a PocketTTS voice before its pack is here.
    @State private var engine: TtsEngineKind = .kokoro
    @State private var voice: String = ""
    @State private var busy = false
    /// The last pick could not use the engine that was chosen, and this is
    /// what speaks instead — shown in full under the voice, never folded
    /// into a passing note (the 2026-09-07 silent-substitution fix).
    @State private var fellBack: VoiceFallback?
    @State private var pocketDownloaded = PocketBackend.isDownloaded
    @State private var downloading = false
    @State private var downloadFraction = 0.0
    @State private var downloadNote = ""
    @State private var downloadError = ""
    @State private var downloadTask: Task<Void, Never>?
    @State private var showDictationHistory = false
    @State private var showMore = false
    @State private var moreOpen: Bool
    /// One flag for every microphone action: running the echo test during
    /// an enrolment measured Moe's own test sentence as the owner's voice.
    @State private var micBusy = false
    @State private var echoVerdict: (good: Bool, text: String)?
    @State private var ownerTurns = 0
    @State private var ownerPrompt: String?
    /// "Teach Moe how you say it": what was measured last time (nil until
    /// it has been done), the clips on this Mac, and the card while open.
    @State private var wakeTuning: WakeTuning?
    @State private var wakeClips = 0
    @State private var teach: WakeTeachModel?

    private var config: Config { conductor.config }
    private var model: VoiceSettingsModel { VoiceSettingsModel(conductor: conductor) }
    @Environment(\.settingSpotlight) private var spotlight

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(Self.title)
            if Self.tabs.count > 1 {
                HStack {
                    PaneTabs(tabs: Self.tabs, selection: $tab)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.wide)
                .padding(.top, Theme.Space.base)
            }
            ScrollView {
                switch tab {
                case .typing:
                    VStack(alignment: .leading, spacing: 30) { typing }
                        .padding(.horizontal, Theme.Space.wide)
                        .padding(.vertical, Theme.Space.roomy)
                case .talking:
                    talking
                        .padding(.horizontal, 36)
                        .padding(.vertical, 28)
                }
            }
        }
        .background(Theme.raised)
        // Moe opened Settings on a row behind "More": open it.
        .onChange(of: spotlight, initial: true) { _, title in
            if SettingSpotlight.under(title) == "More" { tab = .talking; moreOpen = true }
        }
        .sheet(isPresented: $showDictationHistory) {
            DictationHistoryView(conductor: conductor)
        }
        .sheet(isPresented: Binding(get: { teach != nil },
                                    set: { if !$0 { teach?.send(.cancel); closeTeach() } })) {
            if let teach {
                WakeTeachCard(model: teach, clipsOnMac: wakeClips,
                              previous: wakeTuning?.note,
                              send: { sendWakeRecordings() },
                              forget: { forgetWakeRecordings() })
            }
        }
        .sheet(isPresented: $showMore) {
            VoiceMoreSheet(conductor: conductor, showHistory: {
                showMore = false
                showDictationHistory = true
            }, close: { showMore = false })
        }
        .onAppear {
            Task {
                let state = await conductor.ownerVoiceState()
                await MainActor.run { ownerTurns = state.turns }
            }
            refreshWake()
            // The file, not a copy of it, so no route can leave this page
            // showing a voice that is not the one speaking.
            let saved = Config.load()
            engine = posed?.engine ?? TtsEngineKind(rawValue: saved.ttsEngine) ?? .kokoro
            // A voice saved for a different engine is not a voice: land on
            // the engine's default, visibly, rather than show a selection
            // no row carries.
            let offered = TtsCatalogue.voices(for: engine, locale: config.locale)
            voice = offered.contains { $0.id == saved.ttsVoice } && !saved.ttsVoice.isEmpty
                ? saved.ttsVoice
                : TtsCatalogue.defaultVoice(for: engine, locale: config.locale)
            pocketDownloaded = posed?.pocketDownloaded ?? PocketBackend.isDownloaded
            if let posed, posed.downloading {
                downloading = true
                downloadFraction = posed.downloadFraction
                downloadNote = posed.downloadNote
            }
        }
    }

    static func shortcutLabel(_ mods: UInt32) -> String {
        switch mods {
        case 6144: return "⌃⌥Space"
        case 2048: return "⌥Space"
        case 2304: return "⌘⌥Space"
        case 4096: return "⌃Space"
        default:   return "Custom"
        }
    }

    static func closeOfferLabel(_ how: String) -> String {
        switch how {
        case "spoken": return "Ask out loud"
        case "both":   return "Both"
        case "off":    return "Just stop listening"
        default:       return "Ask on the island"
        }
    }

    static func budgetLabel(_ seconds: Double) -> String {
        seconds == 2.5 ? "2.5 s" : seconds == 6.0 ? "6 s" : "4 s"
    }

    /// A switch, in the app's own accent. Every toggle in Settings goes
    /// through this so none of them drifts back to the system tint.
    static func lever(_ value: Binding<Bool>, enabled: Bool = true) -> some View {
        Toggle("", isOn: value)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .disabled(!enabled)
    }

    // MARK: - Typing by voice

    private var typing: some View {
        let on = config.dictationEnabled
        let key = config.dictationKey == .off ? DictationKey.rightCommand : config.dictationKey
        return Group {
            SettingGroup(title: "Hold \(key.displayName) and speak") {
                SettingRow(
                    title: "Type what I say",
                    detail: "Hold the key anywhere, speak, let go: the words appear where your cursor is. Double-tap to keep going hands-free; Esc drops it without typing anything."
                ) { Self.lever(Binding(get: { config.dictationEnabled },
                                       set: { conductor.setDictationEnabled($0) })) }

                SettingRow(title: "The key to hold",
                           detail: "The fn key only works if macOS is not already using it.",
                           last: true) {
                    SettingMenu(value: key.displayName) {
                        Picker("", selection: Binding(
                            get: { key },
                            set: { conductor.setDictationKey($0) })) {
                            ForEach(DictationKey.allCases.filter { $0 != .off }) { k in
                                Text(k.displayName).tag(k)
                            }
                        }
                        .labelsHidden().pickerStyle(.inline)
                    }
                    .disabled(!on)
                }
                // The Language row used to sit here, and this tab is hidden
                // (`Features.dictation`), so nobody could reach it. It is on
                // the Talking tab now: the language is Moe's, not dictation's.
            }

            SettingGroup(title: "Making it read well") {
                SettingRow(
                    title: "Tidy it up with your AI",
                    detail: "Punctuation, no ums, and the tone of the app you are typing into. Each dictation goes to the AI behind Moe and nowhere else; Moe never keeps the text. Off, nothing you dictate leaves this Mac."
                ) {
                    Self.lever(Binding(get: { config.dictationPolish },
                                       set: { conductor.setDictationPolish($0) }), enabled: on)
                }

                SettingRow(
                    title: "Spell names the way I do",
                    detail: "Uses your Contacts and the names on the screen you are typing into, and learns a spelling when you correct one. Each of the three can be turned off on its own under More options."
                ) {
                    Self.lever(Binding(get: { namesOn }, set: { setNames($0) }), enabled: on)
                }

                SettingRow(
                    title: "More options",
                    detail: "Sounds, how long to wait for the tidy-up, where the rewrite runs, and a history of what you have dictated.",
                    last: true
                ) {
                    PaneButton(title: "Show") { showMore = true }
                }
            }
        }
    }

    /// The three name switches as one: on when any is on, and setting it
    /// sets all three. The sheet still offers them one at a time.
    private var namesOn: Bool {
        config.dictationContactsNames || config.dictationScreenVocabulary || config.dictationLearnCorrections
    }

    private func setNames(_ on: Bool) {
        conductor.setDictationContactsNames(on)
        conductor.setDictationScreenVocabulary(on)
        conductor.setDictationLearnCorrections(on)
    }

    /// Under the Language row. The first sentence is the promise (Moe
    /// starts in the Mac's own language, and talking is tuned for
    /// English); the second is what changing it costs, which depends on
    /// the recogniser that language uses.
    private var languageNote: String {
        let backend = conductor.voice.stt.backend(for: config.locale)
        let recogniser = SpeechLanguages.usesWhisper(config.locale) && !WhisperBackend.modelIsPresent
            ? "\(backend.displayName) recogniser — downloads a ~600 MB model the first time."
            : "\(backend.displayName) recogniser, on this Mac."
        return "Moe starts in the language this Mac is set to. Talking to Moe is tuned for English — "
            + "another language works, with a beat of silence to mark the end of a sentence. "
            + recogniser
    }

    /// The picker's value: the row for the configured locale, or the locale
    /// itself when it is one the list doesn't carry (an old config).
    private var languageMenu: some View {
        SettingMenu(value: SpeechLanguages.entry(for: config.locale)?.label ?? config.locale) {
            Picker("", selection: Binding(
                get: { SpeechLanguages.entry(for: config.locale)?.locale ?? config.locale },
                set: { conductor.setLanguage($0) })) {
                ForEach(SpeechLanguages.all) { Text($0.label).tag($0.locale) }
                if SpeechLanguages.entry(for: config.locale) == nil {
                    Text(config.locale).tag(config.locale)
                }
            }
            .labelsHidden().pickerStyle(.inline)
        }
    }


    // MARK: - Talking to Moe

    /// Under the hold key. Short, with the two cases that need a word more.
    private var talkKeyNote: String {
        var note = "Hold it anywhere, talk, let go. Double-tap to talk hands-free."
        if config.talkKey == .fn {
            note += " Set System Settings › Keyboard › Press 🌐 key to Do Nothing, or macOS acts on it too."
        }
        if Features.dictation, config.dictationEnabled, config.talkKey.collides(with: config.dictationKey) {
            note += " It is also your dictation key, so dictation is off until you pick another."
        }
        return note
    }

    private var talking: some View {
        let open = model.reveals
        return VStack(alignment: .leading, spacing: 30) {
            // Talking to Moe is tuned for English: the endpointer is an
            // English model and the wake word one English phrase. Say so,
            // rather than let it feel broken (VOICE-PLAN.md §8).
            if SpeechLanguages.usesEnglishTurnTaking(config.locale) == false {
                PaneBanner(tone: .neutral, text: languageDegradationNote)
            }
            starting(open)
            conversation(open)
            answers(open)
            more
        }
    }

    private func starting(_ open: Set<VoiceSettingsModel.Reveal>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("Starting")
            Calm.Row(title: "Hold a key to talk", detail: talkKeyNote) {
                SettingMenu(value: config.talkKey.label) {
                    Picker("", selection: model.talkKey) {
                        ForEach(TalkKey.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
            }
            Calm.Row(title: "Or just say “Hey Moe”",
                     detail: "No keys. Moe listens only for its name — the room is not transcribed.") {
                Self.lever(model.heyMoe)
            }
            if open.contains(.teachName) {
                Calm.Reveal {
                    Calm.Row(title: wakeTuning == nil ? "Teach Moe how you say it" : "Moe knows how you say it",
                             detail: wakeTuning?.note ?? "About two minutes, in this room. The clips stay on this Mac.") {
                        PaneButton(title: wakeTuning == nil ? "Teach…" : "Teach again…") { openTeach() }
                            .disabled(micBusy)
                    }
                }
            }
        }
    }

    private func conversation(_ open: Set<VoiceSettingsModel.Reveal>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("The conversation")
            Calm.Row(title: "Keep listening after Moe answers",
                     detail: "Just carry on talking — no key, no name. The island shows while it listens.") {
                Self.lever(model.keepListening)
            }
            if open.contains(.listeningWindow) {
                Calm.Reveal {
                    Calm.Row(title: "Waits for") {
                        Calm.Segments(options: VoiceSettingsModel.waitChoices(current: config.followUpSeconds)
                                        .map { (String($0), "\($0) s") },
                                      selection: model.waitsFor)
                    }
                    Calm.Row(title: "When you go quiet") {
                        SettingMenu(value: Self.closeOfferLabel(config.closeOffer)) {
                            Picker("", selection: model.whenQuiet) {
                                Text("Ask on the island").tag("shown")
                                Text("Ask out loud").tag("spoken")
                                Text("Both").tag("both")
                                Text("Just stop listening").tag("off")
                            }
                            .labelsHidden().pickerStyle(.inline)
                        }
                    }
                }
            }
            Calm.Row(title: "Let me interrupt Moe by talking",
                     detail: "Works best in a quiet room, on the Mac’s own microphone and speakers. Off: nothing you say stops Moe — the key still does.") {
                Self.lever(model.interrupt)
            }
            if open.contains(.interruptCheck) {
                Calm.Reveal {
                    Calm.Row(title: "Check my microphone and speakers",
                             detail: "Moe says a sentence and listens for how much comes back. Stay quiet for the eight seconds.") {
                        PaneButton(title: micBusy && ownerPrompt == nil && teach == nil ? "Testing…" : "Test") { runEchoTest() }
                            .disabled(micBusy)
                    }
                    if let echo = echoVerdict {
                        PaneBanner(tone: echo.good ? .good : .warn, text: echo.text)
                    } else if micBusy, ownerPrompt == nil, teach == nil {
                        PaneBanner(tone: .neutral, text: "Stay quiet — Moe is listening to its own voice.", busy: true)
                    }
                }
            }
        }
    }

    private func answers(_ open: Set<VoiceSettingsModel.Reveal>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("Moe’s answers")
            Calm.Row(title: "Answers",
                     detail: config.speakReplies
                        ? "Out loud when you talk to Moe; a typed question is answered on screen."
                        : "Moe never speaks — every answer is on screen.") {
                Calm.Segments(options: [("loud", "Out loud"), ("screen", "On screen only")], selection: model.answers)
            }
            if open.contains(.voice) {
                voiceRow
            }
            Calm.Row(title: "How much Moe says",
                     detail: "Asking for more — “tell me everything” — always gets more.") {
                Calm.Segments(options: ReplyLength.allCases.map { ($0.rawValue, $0.label) },
                              selection: model.replyLength)
            }
        }
    }

    // MARK: - The voice

    private var voiceLabel: String {
        let name = TtsCatalogue.voices(for: engine, locale: config.locale).first { $0.id == voice }?.label ?? voice
        switch engine {
        case .kokoro: return name
        case .pocket: return "\(name) · PocketTTS"
        case .inworld: return "\(name) · Premium"
        }
    }

    /// One menu for every voice, grouped by where it comes from — the old
    /// "Set of voices" choice folded into the voice itself.
    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.Row(title: "Voice", detail: voiceDetail) {
                HStack(spacing: Theme.Space.small) {
                    SettingMenu(value: voiceLabel) {
                        ForEach(TtsEngineKind.offered) { kind in
                            Section(Self.sectionTitle(kind)) {
                                ForEach(TtsCatalogue.voices(for: kind, locale: config.locale)) { v in
                                    Button(v.label) { pick(kind, v.id) }
                                }
                            }
                        }
                    }
                    Button { preview() } label: {
                        Image(systemName: "play.fill").font(.system(size: 9))
                            .foregroundStyle(Theme.accentDeep)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.accentTint))
                            .accessibilityLabel("Hear this voice")
                    }
                    .buttonStyle(.plain)
                    .help("Hear this voice")
                    .disabled(busy || pocketPending)
                    .opacity(busy || pocketPending ? 0.5 : 1)
                }
            }
            if pocketPending {
                Calm.Reveal {
                    Calm.Row(title: downloading ? "Downloading PocketTTS" : "Download PocketTTS",
                             detail: downloadDetail) {
                        downloadControl
                    }
                    Text(downloading ? "Downloading PocketTTS…" : "Download PocketTTS first.")
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .padding(.bottom, 4)
                }
            }
            if let fellBack {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.warn)
                        .accessibilityLabel("Warning")
                    Text(fellBack.sentence)
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, Theme.Space.small)
            }
        }
    }

    private static func sectionTitle(_ kind: TtsEngineKind) -> String {
        switch kind {
        case .kokoro: return "Included"
        case .pocket: return PocketBackend.isDownloaded ? "PocketTTS" : "PocketTTS — 939 MB download"
        case .inworld: return "Premium — with an Away plan"
        }
    }

    private var voiceDetail: String {
        switch engine {
        case .kokoro: return ""
        case .pocket: return "Starts speaking before it has finished thinking."
        case .inworld: return "Rendered in the cloud on your plan; Moe speaks with Kokoro when it is out of reach."
        }
    }

    /// A pick applies at once. The cloud voice is offered to everyone, and
    /// picking it is how a person finds the plan that has it: without one
    /// it goes to Upgrade and the voice stays as it was; with one and the
    /// Premium switch off, the switch comes on, which is what the pick meant.
    private func pick(_ kind: TtsEngineKind, _ id: String) {
        if kind.isCloud {
            // A plan status still loading is unknown, not free.
            switch VoicePanePick.cloudPick(
                mayUse: CloudVoice.mayUse(.tts),
                liveTier: conductor.cloudSnapshot?.tier,
                cachedTier: Cloud.plan?.cached()) {
            case .use: break
            case .upgrade:
                SettingsWindow.show(conductor: conductor, at: .away)
                return
            case .turnOn:
                conductor.setCloudVoice(true)
            }
        }
        engine = kind
        voice = id
        fellBack = nil
        // PocketTTS is a download, not a file in the app, and `useVoice`
        // will not fetch it: the Download row under the voice does, and
        // the voice is applied when it lands.
        guard !pocketPending else { return }
        apply()
    }

    private func apply() {
        let (e, v) = (engine, voice)
        Task {
            busy = true
            fellBack = await conductor.useVoice(engine: e, voice: v)
            busy = false
        }
    }

    private func preview() {
        Task {
            busy = true
            await conductor.voice.preview()
            busy = false
        }
    }

    // MARK: - More

    private var more: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1).padding(.bottom, 4)
            Calm.MoreToggle(open: $moreOpen, hint: "shortcut, language, the panel, sounds, Premium")
            if moreOpen {
                VStack(alignment: .leading, spacing: 18) {
                    moreStarting
                    moreWhileWorking
                    moreReplies
                    moreYou
                }
                .padding(.leading, 20)
                .padding(.top, 6)
            }
        }
    }

    private func moreLabel(_ text: String) -> some View {
        Text(text).font(Theme.Typo.ui(11, weight: .semibold)).foregroundStyle(Theme.ink3)
    }

    private var moreStarting: some View {
        VStack(alignment: .leading, spacing: 0) {
            moreLabel("Starting")
            Calm.Row(title: "Shortcut to ask",
                     detail: "Works alongside the key you hold. If it pastes or starts something else, another app owns it — pick another. Takes effect when Moe restarts.") {
                SettingMenu(value: Self.shortcutLabel(config.hotKeyModifiers)) {
                    Picker("", selection: model.shortcut) {
                        Text("⌃⌥Space").tag(UInt32(6144))
                        Text("⌥Space").tag(UInt32(2048))
                        Text("⌘⌥Space").tag(UInt32(2304))
                        Text("⌃Space").tag(UInt32(4096))
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
            }
            Calm.Row(title: "Keep listening after a held-key turn too",
                     detail: "Holding the key is a one-off question: Moe stops listening after that answer unless this is on.") {
                Self.lever(model.alsoAfterHold, enabled: config.conversationMode)
            }
            Calm.Row(title: "Language", detail: languageNote) { languageMenu }
        }
    }

    private var moreWhileWorking: some View {
        VStack(alignment: .leading, spacing: 0) {
            moreLabel("While Moe works")
            Calm.Row(title: "Say “on it” as soon as I ask",
                     detail: "Only when Moe is going to answer out loud.") {
                Self.lever(model.sayOnIt)
            }
            Calm.Row(title: "Tell me what it’s doing while it works",
                     detail: "“Checking your calendar”, once, when something takes a while.") {
                Self.lever(model.tellProgress)
            }
            Calm.Row(title: "Ding when a written answer is ready",
                     detail: "One soft note, only when Moe is not saying the answer.") {
                HStack(spacing: Theme.Space.small) {
                    PaneButton(title: "Hear it") { conductor.previewReplyChime() }
                        .disabled(!config.replyChime)
                    Self.lever(model.ding)
                }
            }
        }
    }

    private var moreReplies: some View {
        VStack(alignment: .leading, spacing: 0) {
            moreLabel("Answers")
            Calm.Row(title: "Answer questions I ask out loud, out loud") {
                Self.lever(model.speakSpoken, enabled: config.speakReplies)
            }
            Calm.Row(title: "Answer typed questions out loud too",
                     detail: "Off: typed in, text out.") {
                Self.lever(model.speakTyped, enabled: config.speakReplies)
            }
            Calm.Row(title: "Write typed answers to be read",
                     detail: "Headings and short lists where they help, rather than a spoken sentence or two.") {
                Self.lever(model.typedReadAsText)
            }
            Calm.Row(title: "Open the island panel by itself",
                     detail: "A recorded meeting always opens it.") {
                SettingMenu(value: PanelReveal(configValue: config.panelOnReply).label) {
                    Picker("", selection: model.panelOpens) {
                        ForEach(PanelReveal.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
            }
            Calm.Row(title: "How long the panel stays") {
                SettingMenu(value: VoiceSettingsModel.readingLabel(config.replyReadingSeconds)) {
                    Picker("", selection: model.panelStays) {
                        ForEach(VoiceSettingsModel.readingChoices, id: \.self) {
                            Text(VoiceSettingsModel.readingLabel($0)).tag($0)
                        }
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
            }
            Calm.Row(title: "Typed questions open the Chat window",
                     detail: "Off, the answer stays in the panel under the notch.") {
                Self.lever(model.typedOpensChat)
            }
            Calm.Row(title: "Hovering the notch opens it",
                     detail: "Off, only a click does.") {
                Self.lever(model.hoverOpens)
            }
        }
    }

    private var moreYou: some View {
        VStack(alignment: .leading, spacing: 0) {
            moreLabel("Your voice and Premium")
            Calm.Row(title: ownerTurns >= 3 ? "Moe knows your voice" : "Teach Moe your voice",
                     detail: ownerVoiceDetail) {
                HStack(spacing: Theme.Space.small) {
                    if ownerTurns > 0 {
                        PaneButton(title: "Forget") {
                            Task {
                                await conductor.forgetOwnerVoice()
                                ownerTurns = 0
                                ownerPrompt = nil
                            }
                        }
                        .disabled(micBusy)
                    }
                    PaneButton(title: micBusy && ownerPrompt != nil ? "Listening…" : (ownerTurns > 0 ? "Read another" : "Read one")) {
                        enrolOwnerVoice()
                    }
                    .disabled(micBusy)
                }
            }
            if let prompt = ownerPrompt {
                PaneBanner(tone: micBusy ? .neutral : .good, text: prompt, busy: micBusy)
            }
            // Paid plans hear and speak through the cloud on a monthly
            // allowance; on the free plan this changes nothing and nothing
            // is sent. The note says which is true right now.
            Calm.Row(title: "Premium hearing and voice",
                     detail: "On a paid plan, what you say goes to the speech services behind the sharper ears and voice. Off keeps your voice on this Mac. Moe carries on with its own voice if the allowance runs out or anything goes wrong. " + CloudVoice.statusLine()) {
                Self.lever(model.premium)
            }
        }
    }

    /// What is different in this language, in one sentence.
    private var languageDegradationNote: String {
        let name = SpeechLanguages.entry(for: config.locale)?.englishName ?? config.locale
        return "Moe is listening in \(name). Talking to Moe is tuned for English: the model that hears "
            + "a finished sentence only knows English, so in \(name) Moe waits for a moment of silence "
            + "instead — leave a beat when you are done. “Hey Moe” is an English phrase too, so the "
            + "key is the reliable way in."
    }

    private var ownerVoiceDetail: String {
        switch ownerTurns {
        case 0:
            return "Read one sentence so Moe can tell you from the room while it keeps listening. A hint, never a lock."
        case 1..<3:
            return "\(ownerTurns) recording so far. One or two more and Moe can use it."
        default:
            return "Learned from \(ownerTurns) recordings, and it keeps learning. A hint, never a lock."
        }
    }

    /// Something with enough different sounds in it to be worth an
    /// embedding, and short enough that nobody minds reading it.
    /// No "Hey Moe" in them: with the wake word on, reading the prompt
    /// would open a session and take the microphone from the enrolment.
    private static let ownerPrompts = [
        "What does the rest of my afternoon look like?",
        "Read me the last message from the group, would you.",
        "Remind me to call the plumber at six o'clock.",
    ]

    private func enrolOwnerVoice() {
        micBusy = true
        let line = Self.ownerPrompts[min(ownerTurns, Self.ownerPrompts.count - 1)]
        ownerPrompt = "Getting the microphone ready…"
        Task {
            let result = await conductor.enrolOwnerVoice(onListening: {
                // Only now is anything recorded: on a Mac that is still
                // loading its models, "read this" came minutes early.
                ownerPrompt = "Listening — read this aloud: “\(line)”"
            })
            await MainActor.run {
                micBusy = false
                switch result {
                case .enrolled(let turns):
                    ownerTurns = turns
                    ownerPrompt = turns >= 3 ? "Got it. Moe knows your voice." : "Got it — \(turns) so far."
                case .heardNothing:
                    ownerPrompt = "Moe didn't hear a voice it could use. Try again, a little louder."
                case .busy:
                    ownerPrompt = "Moe is using the microphone for something else. Try again in a moment."
                case .unavailable(let why):
                    ownerPrompt = why
                }
            }
        }
    }

    /// The card, over Settings. It holds the microphone from Start until
    /// it is measuring or closed; the row reads the file again after.
    private func openTeach() {
        let model = WakeTeachModel(driver: EngineWakeTeachDriver(conductor: conductor))
        model.onDismiss = { closeTeach() }
        teach = model
    }

    private func closeTeach() {
        teach = nil
        refreshWake()
    }

    private func refreshWake() {
        wakeTuning = WakeTuning.load()
        let clips = WakeRecordings.count()
        wakeClips = clips.positives + clips.others
    }

    private func forgetWakeRecordings() {
        Task {
            await conductor.forgetWakeRecordings()
            refreshWake()
            teach?.note = "Forgotten. Moe listens for its name the way it shipped."
        }
    }

    /// Never sends: a compose window, or the zip in the Finder.
    private func sendWakeRecordings() {
        do {
            let zip = try WakeRecordings.zip()
            switch WakeRecordings.hand(zip) {
            case .composed:
                teach?.note = "A message to \(WakeRecordings.teamAddress) is open in your mail app. Nothing goes until you press Send."
            case .revealed:
                teach?.note = "The zip is selected in the Finder — drag it into a message to \(WakeRecordings.teamAddress)."
            }
        } catch {
            teach?.note = "Moe could not zip the recordings: \(error.localizedDescription)"
        }
    }

    private func runEchoTest() {
        micBusy = true
        echoVerdict = nil
        Task {
            let verdict = await conductor.runEchoTest()
            let summary = EchoTest.summary(verdict)
            await MainActor.run {
                echoVerdict = summary
                micBusy = false
            }
        }
    }


    // MARK: - PocketTTS

    /// PocketTTS is chosen and not on this Mac yet.
    private var pocketPending: Bool { engine == .pocket && !pocketDownloaded }

    /// The Download row's words. Kokoro is already here and says so; the
    /// cloud voice has nothing to fetch. PocketTTS says what it costs
    /// before the button is pressed — the size, once, kept — then how far
    /// along it is, then the reason if it failed.
    private var downloadDetail: String {
        guard pocketPending else { return downloadError }
        if downloading { return downloadNote }
        if !downloadError.isEmpty { return downloadError }
        return "PocketTTS is a 939 MB download, once. It stays on this Mac."
    }

    /// The Download row's right-hand side. PocketTTS gets a button until it
    /// is here, a bar and a Cancel while it is coming, and the word after.
    @ViewBuilder private var downloadControl: some View {
        if pocketPending {
            if downloading {
                HStack(spacing: Theme.Space.small) {
                    ProgressView(value: downloadFraction)
                        .frame(width: 120)
                    Text("\(Int((downloadFraction * 100).rounded()))%")
                        .font(Theme.Typo.data(11))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                    PaneButton(title: "Cancel") { cancelPocketDownload() }
                }
            } else {
                PaneButton(title: "Download", symbol: "arrow.down.circle", prominent: true) {
                    startPocketDownload()
                }
            }
        } else {
            Text(engine.downloadSize)
                .font(Theme.Typo.data(11))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// Fetch the PocketTTS pack, the row following along. What has arrived
    /// stays on disk if it is stopped, and the next Download carries on
    /// from there — FluidAudio resumes by file.
    private func startPocketDownload() {
        guard !downloading else { return }
        downloading = true
        downloadFraction = 0
        downloadNote = "Starting…"
        downloadError = ""
        downloadTask = Task { @MainActor in
            defer { downloading = false; downloadTask = nil }
            do {
                for try await step in PocketBackend.download() {
                    downloadFraction = step.fraction
                    downloadNote = step.text
                }
                pocketDownloaded = PocketBackend.isDownloaded
                downloadNote = ""
                // The voice they picked, now that it can speak.
                if pocketDownloaded { apply() }
            } catch is CancellationError {
                downloadNote = ""
            } catch {
                downloadNote = ""
                downloadError = Task.isCancelled ? "" : "Couldn't download PocketTTS: \(error.localizedDescription)"
            }
        }
    }

    /// Stop the fetch. Cancelling the task ends the stream, and ending the
    /// stream cancels FluidAudio's download (its `onTermination`).
    private func cancelPocketDownload() {
        downloadTask?.cancel()
    }

}


// MARK: - More options

/// The dictation switches most people never touch, one sheet, same rows.
/// Nothing here is new; it is what used to sit between the two things the
/// pane is about.
struct VoiceMoreSheet: View {
    @ObservedObject var conductor: Conductor
    let showHistory: () -> Void
    let close: () -> Void

    private var config: Config { conductor.config }
    private var on: Bool { config.dictationEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            Text("More dictation options")
                .font(Theme.Typo.heading(20))
                .foregroundStyle(Theme.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    SettingGroup(title: "The tidy-up") {
                        SettingRow(title: "Give it at most",
                                   detail: "If the tidy-up takes longer than this, the plain version is typed instead.") {
                            SettingMenu(value: VoicePane.budgetLabel(config.dictationPolishBudget)) {
                                Picker("", selection: Binding(
                                    get: { config.dictationPolishBudget },
                                    set: { conductor.setDictationPolishBudget($0) })) {
                                    Text("2.5 s").tag(2.5)
                                    Text("4 s").tag(4.0)
                                    Text("6 s").tag(6.0)
                                }
                                .labelsHidden().pickerStyle(.inline)
                            }
                            .disabled(!on || !config.dictationPolish)
                        }
                        SettingRow(
                            title: "Where the rewrite runs",
                            detail: "The tidy-up needs a small model. Which one decides how fast dictation feels and whether what you say leaves this Mac."
                        ) { EmptyView() }
                        PolishTierPicker(conductor: conductor)
                            .padding(.leading, Theme.Space.base)
                            .padding(.bottom, Theme.Space.small)
                        SettingRow(
                            title: "Let the AI think before it rewrites",
                            detail: "Off is faster and the result is the same: a rewrite is punctuation and tidying, with nothing to deliberate about."
                        ) {
                            VoicePane.lever(Binding(get: { config.dictationPolishThinking },
                                                    set: { conductor.setDictationPolishThinking($0) }),
                                            enabled: on && config.dictationPolish)
                        }
                        SettingRow(
                            title: "Fit what I dictate to what I was already writing",
                            detail: "The few lines before your cursor go along with what you said, so a dictation continues the sentence you were in. At most 320 characters, only the field you are typing in, never a password field, never saved.",
                            last: true
                        ) {
                            VoicePane.lever(Binding(get: { config.dictationCursorContext },
                                                    set: { conductor.setDictationCursorContext($0) }),
                                            enabled: on && config.dictationPolish)
                        }
                    }

                    SettingGroup(title: "Names") {
                        SettingRow(
                            title: "Use my Contacts for names",
                            detail: "Spells the people and companies in your Contacts the way you have them. macOS asks once for access."
                        ) {
                            VoicePane.lever(Binding(get: { config.dictationContactsNames },
                                                    set: { conductor.setDictationContactsNames($0) }), enabled: on)
                        }
                        SettingRow(
                            title: "Use the names on my screen",
                            detail: "Before you speak, Moe reads the window you are dictating into and picks out its names and identifiers, for just that sentence. Nothing is saved; never a password field."
                        ) {
                            VoicePane.lever(Binding(get: { config.dictationScreenVocabulary },
                                                    set: { conductor.setDictationScreenVocabulary($0) }), enabled: on)
                        }
                        SettingRow(
                            title: "Learn spellings from my corrections",
                            detail: "When you type over a word Moe just pasted, it remembers the spelling — after the second time, so a slip is not learned.",
                            last: true
                        ) {
                            VoicePane.lever(Binding(get: { config.dictationLearnCorrections },
                                                    set: { conductor.setDictationLearnCorrections($0) }), enabled: on)
                        }
                    }

                    SettingGroup(title: "Sounds and history") {
                        SettingRow(title: "Play a sound when dictation starts and stops") {
                            VoicePane.lever(Binding(get: { config.dictationSounds },
                                                    set: { conductor.setDictationSounds($0) }), enabled: on)
                        }
                        SettingRow(
                            title: "Keep a history of what I dictate",
                            detail: "Kept only on this Mac, readable by you alone. The last 2,000 dictations.",
                            last: true
                        ) {
                            HStack(spacing: Theme.Space.base) {
                                PaneButton(title: "History…", action: showHistory)
                                VoicePane.lever(Binding(get: { config.dictationHistory },
                                                        set: { conductor.setDictationHistory($0) }), enabled: on)
                            }
                        }
                    }
                }
                .padding(.trailing, Theme.Space.small)
            }
            HStack {
                Spacer()
                PaneButton(title: "Done", prominent: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.wide)
        .frame(width: 600, height: 620)
        .background(Theme.raised)
    }
}
