import Combine
import Foundation
import MoeBrain
import MoeChat
import MoeDesign
import MoeDictation
import MoeIsland
import MoeLedger
import MoeMeeting
import MoeVoice
import MoeScreen
import SwiftUI

struct Turn: Identifiable, Equatable {
    enum Role { case you, moe, system }
    let id = UUID()
    var role: Role
    var text: String
    var isStreaming: Bool = false
    var at: Date = Date()
    /// What Moe did to answer this, in the plain language `describeTool`
    /// already produces — "Read 3 files", not `fs_read`. Chat collapses these
    /// into chips you can open; before this they were written to a transient
    /// `statusLine` and then thrown away, so the window showed a bare
    /// "Thinking…" and no account of what had happened.
    var tools: [String] = []
    /// How long the job took, question to answer. Shown under the answer
    /// beside its steps ("3 steps · 48 s"); nil for a turn that ran no
    /// steps, or one that arrived from the ledger.
    var took: TimeInterval? = nil
    /// The id this turn has in its thread's file and in the ledger, when it
    /// came from there rather than being said here. `id` is the view's and
    /// is minted per `Turn`; saving under that would tell the ledger a turn
    /// it already holds is new, every time a thread is reopened or arrives
    /// from another device.
    var storedID: String? = nil
    /// The pages Moe opened to answer this — read off Hermes's own preview
    /// of each tool call, not off the reply, so they are where it actually
    /// went. Shown as links you can click; never spoken.
    var links: [ReplyLinks.Link] = []
    /// The model's own thinking before this answer, when the provider
    /// streamed it. Folded inside the steps.
    var thinking: String = ""
    /// A note saying the brain did not answer: the one note that offers
    /// Retry.
    var failed: Bool = false
    /// Photos and files handed over with this turn. Only ever on yours.
    var attachments: [ChatAttachment] = []
    /// What Moe learned from what the person said just before this answer
    /// ("Noted: … · Undo", `NotedLog`). Only ever on Moe's.
    var noted: [NotedFact] = []
}

/// Ties the microphone, the brain, and the voice together.
@MainActor
final class Conductor: ObservableObject {

    enum Mode: Equatable { case idle, listening, thinking, speaking }

    /// Dictation runs beside `mode`, not inside it: it shares the microphone
    /// but none of the conversation state, and the island draws it instead of
    /// whatever `mode` says while it is on.
    enum DictationState: Equatable { case off, listening, transcribing, typing }

    /// Meeting mode (PRODUCT.md §4.2). Beside `mode` like dictation: it has
    /// its own microphone engine and its own indicator, and never opens a
    /// conversation. `done` carries the folder the notes are in.
    enum MeetingState: Equatable {
        case off, starting, recording(since: Date), stopping, done(url: URL)

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
        var isBusy: Bool { self == .starting || self == .stopping }
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var dictation: DictationState = .off
    /// Double-tapped: recording with nothing held. The island breathes.
    @Published private(set) var dictationLatched = false
    /// Recording was taken down by something other than the key; whoever
    /// owns the key should forget the hold.
    var onDictationAbandoned: (() -> Void)?
    /// The talk key was double-tapped with Moe idle: a conversation turn is
    /// recording with nothing held, and the next tap sends it. The island
    /// breathes and says so.
    @Published private(set) var talkLatched = false
    /// The hands-free turn was taken down by something other than the key;
    /// whoever owns the key should forget the latch.
    var onTalkLatchAbandoned: (() -> Void)?
    @Published private(set) var turns: [Turn] = []
    /// The reply a ▶ is reading out again, while it is. The chat row shows
    /// a stop for it instead of a play.
    @Published private(set) var replayingTurnID: UUID?
    @Published private(set) var partial: String = ""

    /// Live speech-to-text for a *dictation*, kept apart from `partial`.
    ///
    /// Dictation and the agent share one microphone and one recogniser, so for
    /// a long time they shared one `partial` too — which meant every word you
    /// dictated into Slack also appeared as a half-transparent "you" turn in
    /// Chat. Chat was not doing anything wrong: it had no way to tell that the
    /// text was addressed to the cursor rather than to Moe. Two properties, and
    /// the question stops existing.
    @Published private(set) var dictationPartial: String = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var statusLine: String = ""

    /// The app Moe is driving right now, or nil when it is not driving one.
    ///
    /// Nothing published this before, which is why nothing could show it. The
    /// owner watched Moe pull him back to Freeform, pressed stop twice, and
    /// had no way to tell whether anything was still running — the island said
    /// the same thing either way, the spoken step said "Working on your Mac"
    /// for every action, and the helper process called itself "thinking"
    /// while idle. Three symptoms, one cause: no state signal.
    @Published private(set) var drivingApp: String?
    /// Moe is in its own browser: `browser_exec` and the `browser_*` tools,
    /// which open pages off-screen in the packaged Chromium and never in the
    /// person's Chrome. Shown in the same colour as driving, with its own
    /// stop, because it is the other run a person may want to end mid-flight
    /// — and until this existed the only way out of one was the double-tap.
    @Published private(set) var browsing = false
    /// The window has gone quiet and Moe is offering to close it. The
    /// island shows the question with a tick and a cross; saying anything
    /// answers it too, because a conversation is answered by talking.
    @Published private(set) var offeringToClose = false
    /// The last engine notice put into the transcript, so the same sentence
    /// is not repeated every turn. See `.notice` in the event handler.
    private var lastNotice: String = ""
    @Published private(set) var connected = false
    /// The brain can't start because there is no Claude sign-in yet. The
    /// menus show one "Sign in" call to action while this is true.
    @Published private(set) var needsSignIn = false
    /// Fix cards: a tool failed for a reason the person can fix, and said
    /// which (`FixOffer`, docs/FIXABLE-FAILURES.md slice 3). Shown on the
    /// island and in Chat until pressed or dismissed, or the next thing the
    /// person asks.
    @Published private(set) var fixOffers: [FixOffer] = []
    /// The codes already offered this turn: one card per cause per turn, not
    /// one per failed call — a browser job can fail the same way six times.
    private var fixCodesThisTurn = Set<FixCode>()
    /// What a card's button does. Replaced in tests.
    var fixActions = FixActions.live
    /// How a System Settings pane is opened. A seam so no test ever opens
    /// System Settings on the Mac running it.
    var openSettingsURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Watches a grant after its pane is opened, and carries the task on when
    /// it flips (docs/FIXABLE-FAILURES.md slice 4).
    let grantWatch = GrantWatch()
    /// Turns the person started, counted. A carry-on is only for the turn
    /// that was current when its pane was opened: anything newer the person
    /// said supersedes it.
    private(set) var personTurns = 0
    /// Who started the turn in flight (or the last one).
    private(set) var turnStarter: TurnStarter = .background
    /// The latest fixable failure per pane, this conversation, with the
    /// person turn it arrived in: what `moe_open_settings` may open and
    /// watches for (its subject, its path).
    private var fixesByPane: [String: (fix: ToolFix, personTurn: Int)] = [:]
    /// Panes the brain opened, with the person turn: at most once per turn.
    private var panesOpened: [String: Int] = [:]
    private var openSettingsObserver: NSObjectProtocol?
    /// `moe_location`'s app half (Location/LocationBridge.swift).
    let location = LocationBridge()
    /// `moe_settings_change` / `_show`'s app half (Settings/SettingsBridge.swift).
    let settingsBridge = SettingsBridge()
    private var settingsPublish: AnyCancellable?
    /// Asks macOS whether Automation is really off for an app before a
    /// `tcc_automation` card is shown (`AutomationConsent`). A seam for tests.
    var automationConsent: (String) -> AutomationConsent = AutomationConsent.live(appName:)
    @Published private(set) var voiceReady = false
    /// The microphone is not working (every restart failed, or it runs
    /// and sends nothing). Read by the sidebar's voice dot, which used to
    /// say "Voice ready" over a dead microphone for an hour (2026-11-13).
    @Published private(set) var microphoneDead = false
    /// The sidebar's voice dot: the models *and* the microphone.
    var voiceStatus: (ok: Bool, text: String) {
        VoiceStatus.sidebar(modelsReady: voiceReady, microphoneDead: microphoneDead)
    }
    @Published private(set) var alwaysListening = false
    /// The follow-up window: Moe has answered and the microphone stays open
    /// in case you go on, but nobody is speaking. `mode` says `.listening`
    /// all the same; a floating capsule shows it as rest (`IslandEars`).
    @Published private(set) var betweenTurns = false
    /// True while a back-and-forth is in progress — drives "your turn" in the UI.
    @Published private(set) var inConversation = false {
        // The live transcript lasts one conversation. It used to stay on until
        // pressed again, invisibly, so an accidental press at 17:33 on
        // 2026-09-24 had the island opening on every "Hey Moe" and every
        // answer for the rest of the day, over "Open by itself: Never", with
        // nothing on screen to say why.
        didSet {
            if oldValue, !inConversation, showsTranscript {
                showsTranscript = false
                Log.write("island: transcript off — the conversation ended")
            }
        }
    }
    /// Something Moe noticed and wants to tell you — shown as an amber glow
    /// until you tap it. It never speaks on its own: being startled by your
    /// laptop is worse than hearing the news a minute later.
    @Published private(set) var pendingNudge: String?
    /// What the pulse on the island can be changed through, when it came
    /// from something changeable. Not `@Published`: nothing draws it, and
    /// the views that draw `pendingNudge` are edited often enough that a
    /// second published property would be a merge conflict for no gain.
    private(set) var pendingNudgeHandle: NudgeHandle?
    /// When a late one was for — "Earlier, at 8:11 AM" — as its own line.
    ///
    /// It used to be glued onto the front of the sentence, so the island
    /// read "Earlier, at 8:11 AM: Eli's waiting for your help with Rite
    /// Care." in one run: a timestamp competing with the words for the
    /// same twelve points. Kept apart, the card can caption it and the
    /// sentence can be the sentence. `playNudge` puts them back together
    /// for the speaking, because out loud the ordering is right.
    @Published private(set) var pendingNudgeWhen: String?
    /// Everything Moe brought up on its own and the person has not finished
    /// with, and the last week of what they did (docs/INBOX.md). The island's
    /// inbox, the reading card and the app's Inbox page all draw from this.
    /// `pendingNudge` is now only the notice being acted on, for the moment
    /// an action takes — never a card on screen.
    @Published private(set) var notices: [InboxItem] = []
    /// The island shows the inbox instead of the conversation.
    @Published var showingInbox = false
    /// The one line under the notch for a few seconds when something arrives.
    @Published private(set) var noticePeek: InboxItem?
    /// "Also mark it done in Reminders?", after Done on a notice the ledger
    /// traced to an Apple Reminder (`LoopLedger`).
    @Published private(set) var reminderTick: ReminderTick?
    /// A tick that did not happen says so, in the same place it was asked.
    @Published var tickTrouble: String?
    /// moe-screen's follow-up ledger; nil under unit tests unless one is set.
    var loopLedger: LoopLedger? = LoopLedger.underTest ? nil : .live
    /// When the inbox last asked each card's source whether it is over
    /// (`closeResolvedNotices`): once a minute, not every drain.
    var lastSourceSweep: Date = .distantPast
    /// The conversation a reply to a notice left, so the island can offer
    /// the way back to it.
    @Published private(set) var noticeReturn: NoticeReturn?
    struct NoticeReturn: Equatable {
        let from: String
        let fromTitle: String
        let to: String
    }
    var peekTimer: Timer?
    /// Opens the reading card for a notice (`NoticeCardWindow`), and the
    /// app's Inbox page at one. Set by the app delegate.
    var onOpenNoticeCard: ((String) -> Void)?
    var onOpenInboxPage: ((String?) -> Void)?
    /// The notice the app's Inbox page should show when it next opens.
    @Published var inboxFocus: String?
    /// The inbox item a reply is open for: the island says so above the
    /// field, with Cancel, until something is sent.
    @Published var replyingTo: String?
    /// Opens the island, expanded, from a card's "Continue in island".
    var onOpenIsland: (() -> Void)?
    /// Words another screen wants typed into Chat's box, ready to send —
    /// Memory's "Answer" puts Moe's own question here. Chat takes it and
    /// clears it.
    @Published var chatDraft: String?
    /// Photos and files that go with `chatDraft`: what was waiting in the
    /// notch's box when ⌘J handed the conversation to the window.
    @Published var chatDraftAttachments: [ChatAttachment] = []

    /// The notch or the floating window hands the conversation to the Chat
    /// page (⌘J, or the window button): the conversation is the same one,
    /// and what was half-typed there, words and files, waits in Chat's box.
    func handOffDraft(text: String, attachments: [ChatAttachment]) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty { chatDraftAttachments += attachments }
        if !words.isEmpty { chatDraft = text }
    }
    /// True from the first tool call of a turn until the turn ends: Moe may
    /// be moving the cursor and clicking, so the island must stay out of the way.
    @Published private(set) var acting = false

    /// "Work silently", pressed on the island for the turn in flight: no step
    /// lines, no "still on it", none of the model's interim sentences — just
    /// the answer when the turn ends. `WorkSilently` holds the rules; this is
    /// published so the button's label follows it.
    @Published private(set) var workingSilently = false
    /// You muted yourself: Moe keeps working and talking, and nothing said
    /// in the room reaches it until you press mute again. Sticky across
    /// answers and follow-up windows; the talk key talks through it while
    /// held; the hotkey and the end of the conversation lift it. Mirrors
    /// `VoiceMachine.muted` by way of `.micMuted`: the island's pill and
    /// the chat's button both read this one value.
    @Published private(set) var micMuted = false
    /// "Transcript" pressed: while Moe listens and works the island shows
    /// the conversation — your words as they are heard — instead of the one
    /// working row. The owner, 2026-09-23: "it doesn't really show you the
    /// transcription in real time … there should be a way to press
    /// transcription, and then it'll show you the transcription." Stays on
    /// until pressed again or the conversation ends (`inConversation`).
    @Published private(set) var showsTranscript = false
    /// The step Moe is on, in words for the island's one working row
    /// (`WorkingRow`): the spoken phrase for the step when there is one,
    /// else Hermes's own preview of it. Nil between steps, which the row
    /// shows as "Thinking".
    @Published private(set) var workingStep: String?
    /// When the job in flight began, for the clock on the working row.
    @Published private(set) var workingSince: Date?
    private var quietWork = WorkSilently()
    /// `Moe --panel-snapshot` only: a working spoken turn, posed. Nil in the app.
    private var posedWorking: Bool?

    /// Whether the island offers the button: a spoken turn that is working.
    var offersWorkSilently: Bool {
        if let posedWorking { return posedWorking }
        return WorkSilently.offered(awaitingReply: awaitingReply, replySpeaks: replySpeaks,
                             abandoned: replyAbandoned)
    }

    /// The island's button. Silences progress speech for the rest of this
    /// turn, or — pressed again — turns it back on.
    /// The owner, 2026-09-23: "you're in conversational mode and it's in the
    /// middle of a task — if you say anything you will interrupt it, so you
    /// should be able to mute yourself." The voice machine holds the rule
    /// (`VoiceMachine.Event.setMuted`); this is the button's end of it.
    func toggleTranscript() {
        showsTranscript.toggle()
        Log.write("island: transcript \(showsTranscript ? "shown" : "hidden") while Moe works")
    }

    /// The mute and unmute controls, wherever they are pressed. `from` names
    /// the control for the log line ("island's Unmute pill (expanded)",
    /// "chat's Mute button"). One direction only, and no toggle anywhere
    /// (2026-09-25): a toggle behind a control that reads "Unmute" would
    /// mute if the state moved under the click; this cannot.
    func setMicMuted(_ on: Bool, from surface: String) {
        guard on != micMuted else { return }
        voice.setMicMuted(on, from: surface)
    }

    func toggleWorkSilently() {
        guard WorkSilently.offered(awaitingReply: awaitingReply, replySpeaks: replySpeaks,
                                   abandoned: replyAbandoned) else { return }
        let on = quietWork.toggle()
        workingSilently = on
        Log.write("work silently: \(on ? "on" : "off")")
        // Talking again: the next thing said is new, not a replay of what
        // was skipped, and not an instant "still on it" either.
        lastNarrationAt = Date()
        guard on else { return }
        speechStall?.cancel(); speechStall = nil
        // What the model has written so far is narration of a job still
        // running; it is skipped, not held. The answer is found again at
        // the end of the turn by `WorkSilently.finalReplyStart`.
        if let id = streamingTurnID, let turn = turns.first(where: { $0.id == id }) {
            spokenUpTo = turn.text
        }
        // And whatever is queued goes now — unless a confirmation sheet is
        // up, whose announcement may be the line playing.
        if WorkSilently.cutsQueuedSpeech(confirmWaiting: confirmWaiting != nil) {
            voice.stopSpeaking()
        }
    }

    // MARK: Meeting state

    @Published private(set) var meeting: MeetingState = .off

    /// DEBUG only: the island's meeting states without a microphone, a
    /// consent sheet or a recording on disk. `MOE_FAKE_MEETING=1`.
    func debugEnterFakeMeeting() {
        guard TestHooks.env("MOE_FAKE_MEETING") != nil else { return }
        meeting = .recording(since: Date())
        meetingClock = "00:07"
        Log.write("DEBUG: fake meeting state entered (no microphone)")
    }
    /// `mm:ss` since the recording began; ticks once a second while recording.
    @Published private(set) var meetingClock = "00:00"
    /// One line about the meeting for the island and the pane: "Writing
    /// your notes…", a permission problem, the outcome.
    @Published private(set) var meetingStatus = ""
    /// The live transcript, for the Meetings pane.
    @Published private(set) var meetingTimeline: [Segment] = []
    /// The last finished meeting's record, for the "Open notes" link.
    @Published private(set) var meetingOutcome: MeetingSummary.Outcome?
    /// "mic silent" / "no meeting audio", or empty. See ChannelHealth.
    @Published private(set) var meetingHealth = ""
    /// Off the record: audio and text dropped until resumed.
    @Published private(set) var meetingPaused = false
    /// How many "note this" marks so far.
    @Published private(set) var meetingBookmarks = 0
    /// True while the hold key is down mid-meeting: the meeting's mic is
    /// feeding Moe's recogniser (a whisper), so the island shows listening.
    @Published private(set) var meetingWhisper = false
    /// Action items the minute-by-minute scan has picked out so far
    /// (Config.meetingSummarise); the island shows the count.
    @Published private(set) var meetingLiveActions: [MeetingNotes.ActionItem] = []
    /// "Catch me up": two sentences on what was missed while away, or nil.
    @Published private(set) var meetingCatchUp: String?
    /// The far side said the user's name: the sentence, for the panel.
    @Published private(set) var meetingMention: String?
    /// Bumped when the ring should flash (a name mention); the view animates on change.
    @Published private(set) var meetingFlash = 0
    /// The one-time hint, shown on the first meeting only.
    @Published private(set) var meetingHint: String?
    /// The notes went to Telegram (or why not), for the done panel.
    @Published private(set) var meetingDelivery = ""
    /// Naming the key you actually hold (`Config.talkKey`), not a ⌥ that
    /// may not be it.
    static func meetingHintText(_ key: TalkKey) -> String {
        "Hold \(key.inSentence) and whisper, or click to type — I answer in text."
    }
    /// When the agent key went down, to tell a tap ("note this") from a hold.
    private var holdBeganAt: Date?
    /// Whether Moe was at rest when the talk key last went down — read
    /// before the press itself changed anything, because by the second tap
    /// of a double-tap the first has already moved the voice. Decides what
    /// that double-tap means (`doubleTapListensHandsFree`).
    private var pressFoundMoeAtRest = false
    /// A press from rest that has not yet lasted a tap's length: when it
    /// went down. Nothing is shown and no recogniser is opened until the
    /// key says it is a hold (`holdConfirmed`) or a double-tap latches;
    /// the audio graph is warm meanwhile, so a hold loses nothing — its
    /// pre-roll reaches back to this moment.
    private var unconfirmedPressAt: Date?
    /// When the last double-tap stopped everything. See `stopStillSettling`.
    private var stoppedAt: Date?
    /// "Stopped" is in the island's left ear: a stop just happened
    /// (`confirmStopped`), for `stoppedShownSeconds`.
    @Published private(set) var showingStopped = false
    private var stoppedShownTask: Task<Void, Never>?
    /// Two "note this" within half a second are one (a double-tap of the
    /// hold key sends two releases).
    private var lastBookmarkAt: Date?
    /// While a meeting is being set up or recorded the microphone belongs to
    /// `MicCapture`'s engine (voice processing on). `VoiceEngine` opening a
    /// second engine on the same input — with or without its own voice
    /// processing — is untested (MEETING-MODE.md), so nothing here starts it
    /// until the meeting is over: the hold key bookmarks, dictation and
    /// "Talk to Moe" say so, wake-word standby is paused and restored.
    private var meetingOwnsMic: Bool {
        switch meeting {
        case .starting, .recording: return true
        case .off, .stopping, .done: return false
        }
    }
    private var meetingSession: MeetingSession?
    private var meetingClockTimer: Timer?
    private var meetingTapCheck: Task<Void, Never>?
    private var meetingScanTimer: Timer?
    private var meetingScanCursor = LiveCursor()
    private var meetingScanBusy = false
    private var meetingAway = CatchUp()
    private var meetingAwayTimer: Timer?
    private var meetingAwayObservers: [NSObjectProtocol] = []
    /// Lock/unlock/sleep/wake, watched for the whole life of the app —
    /// unlike `meetingAwayObservers`, which exist only while recording.
    private var lockObservers: [NSObjectProtocol] = []
    /// The wake word was switched off because nobody is at the Mac.
    private var micReleasedWhileAway = false
    private var meetingMentionCursor = 0
    private var meetingOwnerName: String?
    /// One brain per job, never one for all of them — see `liveBrain`.
    private var meetingBrains: [HermesMeetingBrain.Purpose: HermesMeetingBrain] = [:]
    /// What this meeting's sessions are derived from. Fresh per meeting, so
    /// last week's hour of action items is not in this week's context.
    private var meetingBrainID = UUID().uuidString.lowercased()

    // MARK: Capture and call detection (MEETING-MODE.md, Phase D)

    /// "Zoom meeting detected — record it?" on the island. `countdown` is
    /// set while the auto mode counts down to starting by itself.
    struct MeetingOffer: Equatable {
        let app: CallApp
        var countdown: Int?
    }
    @Published private(set) var meetingOffer: MeetingOffer?
    /// "Your Zoom meeting seems to have ended — stop and write the notes?"
    @Published private(set) var meetingEndOffer: String?
    /// "Moe heard 4 other voices and could not put names to them." Set once,
    /// after a meeting Calendar access would have named, and only while the
    /// permission has never been asked for.
    @Published private(set) var meetingCalendarOffer: String?
    /// The call audio never arrived and could not be recovered (`TapWatch`).
    /// Not a status line: while this is set the meeting is only hearing one
    /// side, and the person needs to know before the notes are written
    /// rather than after.
    @Published private(set) var meetingTapFault: String?
    /// Screenshots and clips taken so far this meeting, newest last.
    @Published private(set) var meetingCaptures: [CaptureRecord] = []
    /// A clip is being recorded.
    @Published private(set) var meetingClip = false
    /// "Screenshot saved" for a moment on the panel.
    @Published private(set) var meetingCaptureStatus = ""
    /// Screen Recording is not granted: the app shows the notice with the
    /// deep link. `permission` is false for an ordinary failure.
    var onMeetingCaptureProblem: ((String, _ permission: Bool) -> Void)?
    private var watcher: MeetingWatcher?
    private var captureScheduler = CaptureScheduler()
    private var captureCueCursor = 0
    private var captureBusy = false
    private let clipRecorder = MeetingClipRecorder()
    private let regionPicker = RegionPicker()
    /// The call app the running meeting was started for, from the offer.
    private var meetingCallApp: CallApp?
    private var offerTimer: Timer?
    private var captureStatusTimer: Timer?
    /// Ask the user before recording. The closure gets true to go ahead.
    /// Set by AppDelegate, which owns the sheet; unset means: refuse to
    /// start, because consent is a product requirement (§4.2), not a
    /// default.
    var onMeetingConsent: ((@escaping (Bool) -> Void) -> Void)?
    /// Something the user has to act on: a denied System Audio Recording
    /// grant (`permission` true, so the alert can deep-link) or a failure.
    var onMeetingProblem: ((String, _ permission: Bool) -> Void)?
    /// The ⌃⌥M setting changed.
    var onMeetingHotkeyChanged: ((Bool) -> Void)?

    private var nudgeWatch: FileWatch?
    /// The beat the island shows "typing…" after a paste. Cancelled if the
    /// key goes down again before it ends, so a quick second dictation is
    /// not swallowed.
    private var dictationSettleTask: Task<Void, Never>?
    /// True from the key going down until the island is allowed to show it.
    /// Capture starts at once (the first words must not be lost), but the
    /// visible state waits `dictationRevealDelay`: a ⌘C typed with the right
    /// thumb is cancelled by its key press long before that, so it never
    /// flashes the strip.
    private var dictationPending = false
    private var dictationRevealTask: Task<Void, Never>?
    private let dictationRevealDelay: UInt64 = 150_000_000
    /// The second cleanup pass, through the brain. See DictationPolisher.
    private var polisher: DictationPolisher
    /// Who actually does the rewrite: on-device first, the brain last. See
    /// PolishTier — the ladder is what makes this fast on a Mac with Apple
    /// Intelligence, and what will make it fast on Windows and Linux through
    /// a local model server.
    private var polishRouter: PolishRouter
    /// The app the cursor was in when the dictation key went down. Read
    /// then, not at paste time: transcription takes long enough for the
    /// user to have switched windows, and the register belongs to where
    /// they were speaking into.
    private var dictationFrontApp: PolishPrompt.FrontApp?
    /// What was already in that field, ahead of the cursor. Read at press
    /// time for the same reason as the app — and because reading it at
    /// release would put an Accessibility round-trip on the one path that
    /// has to feel instant. Never logged; see `CursorContext`.
    private var dictationBefore: String?
    private let chime = Chime()
    private let history = DictationHistory(url: Paths.dictationHistory)
    /// Threads on disk, so ⌘N files the current one instead of deleting it.
    private let conversationStore = ConversationStore(directory: Paths.conversations)
    /// Names threads for the Chat list with one small call each (`TitleNamer`).
    private lazy var titleNamer = TitleNamer(config: config)
    /// Older threads waiting for a name, one call at a time.
    private var titleBackfill: [(id: String, first: String)] = []
    private var titleBackfillStarted = false
    /// The ledger the threads are derived from, and the projector that is the
    /// only thing writing `conversations/` (docs/ONE-AGENT.md §1.3).
    private(set) lazy var conversationLedger = ConversationLedger(
        directory: Paths.ledger, store: conversationStore,
        note: { Log.write($0) })
    /// The lock/unlock/sleep/wake observers. See `startPresence`.
    private var presenceWatcher: PresenceWatcher?

    /// Memoe's cloud, when this build has one (`Cloud`); `LocalOnly` when not.
    var cloud: CloudLink { Cloud.link }
    /// What the screens show of the cloud's state; pushed by the closed half.
    @Published var cloudSnapshot: CloudSnapshot?
    /// The thread being added to. A fresh id per launch until something is
    /// said — `save` drops empty threads, so an unused one leaves no file.
    private var conversationID = UUID().uuidString
    private var conversationStartedAt = Date()
    /// Tool steps seen since the last reply began, waiting to be attached to
    /// the turn they belong to.
    private var pendingTools: [String] = []
    /// Pages opened since the last reply began, waiting to be attached to
    /// the turn they belong to. Same life as `pendingTools`.
    private var pendingLinks: [ReplyLinks.Link] = []
    /// Thinking streamed since the last reply began. Same life again.
    private var pendingThinking = ""
    /// The screenshot taken as the agent key went down, for the next turn.
    private let screen = ScreenContext()
    /// The capture the reply in flight was shown, so its `[POINT:…]` tags
    /// map back to the screen.
    private var lastCapture: ScreenCapture?
    private var pointParser = PointTagParser()
    private let pointer = PointerOverlay()
    @Published var config: Config

    /// Whichever AI config.json asked for. Nothing below this line knows which.
    /// Replaced wholesale by `applyBrain` when the provider changes.
    private var bridge: BrainProvider
    let voice: VoiceEngine

    private var streamingTurnID: UUID?
    private var spokenUpTo = ""      // how much of the streaming reply has been sent to TTS
    private var restartAttempts = 0
    private var lastStartAt = Date.distantPast
    private var shuttingDown = false
    /// True only while Claude owes us a reply. The busy check must key on this,
    /// not on `mode == .thinking` — transcription also shows as "thinking", so
    /// the guard was rejecting the very transcript it had just produced.
    private var awaitingReply = false {
        didSet {
            workAssertion.set(held: awaitingReply)
            // The turn finished: an offer's send in it has been decided, and
            // what you typed while it ran goes now.
            if oldValue, !awaitingReply { offerTurnEnded() }
            if oldValue, !awaitingReply, queuedTyped != nil { sendQueued() }
        }
    }

    /// A message typed while Moe was still on the last one (the owner,
    /// 2026-09-25: the island's field is always there now). It used to be
    /// dropped with "Still working on the last one — one sec."; it is held
    /// and sent the moment the turn in flight finishes. Stopping Moe, or a
    /// new conversation, drops it with the turn.
    @Published private(set) var queuedTyped: String?
    private var queuedAttachments: [ChatAttachment] = []

    private func sendQueued() {
        guard let text = queuedTyped else { return }
        let files = queuedAttachments
        queuedTyped = nil
        queuedAttachments = []
        // After this turn's own ending has run, not inside it.
        DispatchQueue.main.async { [weak self] in
            self?.submit(text, origin: .typed, starter: .person, attachments: files)
        }
    }

    /// Stop, cancel and a new conversation drop the held message with the
    /// turn it was waiting on.
    private func dropQueued() {
        queuedTyped = nil
        queuedAttachments = []
    }

    /// Moe is on a job: before the first word, or any step after it. What
    /// turns send into ■ on every surface (the owner, 2026-11-13).
    var isWorking: Bool { mode == .thinking || acting }

    /// The held message's ✕: it is not sent.
    func cancelQueued() {
        guard queuedTyped != nil else { return }
        Log.write("queued message cancelled by hand")
        dropQueued()
    }

    /// The held message's Edit: it comes back out, to go into the box again.
    func takeBackQueued() -> (text: String, attachments: [ChatAttachment])? {
        guard let text = queuedTyped else { return nil }
        let files = queuedAttachments
        dropQueued()
        return (text, files)
    }

    /// The held message's "Send now": stop the job it was waiting on and
    /// send it at once.
    func sendQueuedNow() {
        guard let held = takeBackQueued() else { return }
        Log.write("queued message sent now — stopping the turn it waited on")
        stopEverything()
        DispatchQueue.main.async { [weak self] in
            self?.submit(held.text, origin: .typed, starter: .person, attachments: held.attachments)
        }
    }
    /// While a reply is owed, the Mac is asked not to idle-sleep. Every
    /// path that ends a turn writes `awaitingReply`, so the `didSet` above
    /// is the one place this is released — an assertion tied to a dozen
    /// exits would leak on the thirteenth.
    private let workAssertion = WorkAssertion()
    /// You interrupted the reply: the rest of it is transcript only.
    private var replyAbandoned = false
    /// True between abandoning a reply and the next `submit`: events the
    /// old turn still emits (already queued, or before the reset lands)
    /// belong to nothing on screen.
    private var replyIsAbandoned: Bool { replyAbandoned && !awaitingReply }
    /// "A turn ended with an answer", so a view can react to Moe replying
    /// rather than guessing from `mode` or the turn array — neither of which
    /// tells an answer apart from a tool call or a clock tick.
    /// docs/PANEL-FINDINGS.md §5; the rules are `MoeIsland.ReplySignal`.
    private var replySignal = ReplySignal()
    private var progressTimer: Timer?
    /// Armed by every delta; fires when they stop coming. See `armSpeechStall`.
    private var speechStall: Task<Void, Never>?
    private var lastToolDetail = ""
    /// The last thing sent to the voice this turn — the model's own words or
    /// a step Moe narrated — so a step line is only ever spoken into a real
    /// silence, never over the top of an answer that is already arriving.
    private var lastNarrationAt = Date.distantPast
    /// What was last said about a step, so the same one is not said twice.
    private var lastSpokenStep = ""
    /// The phrase for whatever is running now, for the "still …" follow-up.
    private var currentStepPhrase: String?
    /// The steps Hermes says are running right now, by its `toolCallId`.
    /// A dictionary rather than a single value because `delegate_task` runs
    /// several at once, and because a `completed` has to remove the step it
    /// belongs to rather than whichever happened to be last.
    private var runningTools: [String: String] = [:]
    /// The same steps by tool name, for `openSettingsForBrain`: only a
    /// running `moe_open_settings` step may open a pane.
    private var runningToolNames: [String: String] = [:]

    /// A confirmation sheet on screen, waiting on the person — posted by the
    /// dialog itself (`ConfirmSignal`), because nothing else can know. While
    /// it is set, Moe says "press Send" rather than "still getting that ready
    /// to send": Hermes reported the step before its hook opened the sheet,
    /// and the step does not end until the person answers.
    private struct ConfirmWaiting {
        let kind: ConfirmWait.Kind
        let pid: String
        let since: Date
        var reminded = false
    }
    private var confirmWaiting: ConfirmWaiting?
    private var confirmObservers: [NSObjectProtocol] = []

    /// The moment the user stopped talking, for the turn budget in the log.
    /// Nil for a turn typed into the chat window — there is no one waiting on
    /// a reply to start being spoken, so there is nothing to measure.
    private var turnBeganAt: Date?

    /// How the turn now in flight reached Moe.
    ///
    /// This used to be read off `turnBeganAt`, which is nil for anything
    /// typed — and exactly one caller used it, so everything else that speaks
    /// went by the single global switch and answered a quietly typed question
    /// out loud. A latency mark is the wrong thing to hang delivery on: it is
    /// consumed by whoever reads it first, and it means "when did they stop
    /// talking", not "how do they want to be answered".
    ///
    /// Typed is the safe default for anything that arrives without saying —
    /// the worst a wrong guess can do here is stay quiet.
    private var turnOrigin: TurnOrigin = .typed

    /// Whether the answer to the turn in flight is read out loud.
    ///
    /// Every speaking gate in this file goes through here, so there is one
    /// place that decides and one place to change. It folds in the two rules
    /// that were repeated at each of those gates: a recorded meeting is
    /// always silent, and the master switch is the master switch.
    /// Read by the island too (`NotchIsland.revealReply`): whether the panel
    /// has to open depends on whether the answer reached the person any other
    /// way. Not private for that reason and no other.
    var replySpeaks: Bool {
        ReplyRoute.speaks(origin: turnOrigin,
                          master: config.speakReplies,
                          typed: config.speakTypedReplies,
                          spoken: config.speakSpokenReplies,
                          meetingRecording: meeting.isRecording)
    }

    /// Cleared by the first delta, so the budget records the first token
    /// rather than every one of them.
    private var awaitingFirstToken = false
    /// The same, for the first sound actually heard.
    private var awaitingFirstAudio = false

    /// true = show the island, false = hide it.
    var onWantsIsland: ((Bool) -> Void)?
    /// Fired once when a turn the user asked for ends — with the answer, or
    /// with the error that stood in for one. Never on a streaming delta,
    /// never on a status change, and never for the silent background turns
    /// nobody is waiting on. docs/PANEL-FINDINGS.md §5.
    var onReply: ((Reply) -> Void)?
    /// The effective dictation key changed in Settings (`.off` when disabled).
    var onDictationKeyChanged: ((DictationKey) -> Void)?
    /// The key you hold to talk changed in Settings.
    var onTalkKeyChanged: ((TalkKey) -> Void)?

    /// Where the Hermes gateway stands, for the window. Pair it with
    /// `connected`: before the gateway answers this still says "running".
    var brainStatus: String {
        (bridge as? HermesBrain)?.gatewayStatus ?? "\(config.brain.displayName) brain"
    }

    /// `brain` is for tests: a stand-in that records what it is sent and
    /// replays events, so the turn handling can be driven for real. The app
    /// passes nothing and gets the brain config.json asks for.
    init(config: Config, brain: BrainProvider? = nil) {
        self.config = config
        self.bridge = brain ?? BrainFactory.make(config: config)
        self.voice = VoiceEngine(config: config)
        self.alwaysListening = config.wakeWordEnabled
        self.polisher = DictationPolisher(config: config, vocabulary: Self.vocabularyTerms)
        self.polishRouter = PolishRouter(brain: self.polisher)
        // Both switches: the user's, and whether the model can see at all
        // (a definite "no vision" never gets a screenshot; unknown does).
        self.screen.enabled = config.screenContext && config.brainCapabilities.mayAttachImages
        wire()
        grantWatch.onGranted = { [weak self] watch in
            self?.grantTurnedOn(watch) ?? .dropped("the app is going away")
        }
        // Refreshes a day-old Contacts cache, or removes it when the
        // setting is off. No prompt unless the user opted in.
        ContactsVocabulary.sync(enabled: config.dictationContactsNames)
        // Pull the system dictionary into memory now, off the main thread.
        // `CommonWords.system` is 200k words read lazily on first touch, and
        // its first toucher is the screen harvest — which runs on the main
        // thread, on the keypress. Measured cold: 127 ms, which is a visibly
        // late chime on the first dictation of every launch and nothing at
        // all on the ones after it, so it is exactly the kind of stall nobody
        // ever reproduces.
        DispatchQueue.global(qos: .utility).async { _ = CommonWords.system }
    }

    // MARK: - Wiring

    private func wire() {
        // Memoe's cloud, when this build has one, needs the conductor itself.
        cloud.attach(self)
        // The open ask (docs/AWAY-HANDOFF.md slice 2): what the brain says
        // about the turn in flight goes to the edge through CloudSync, and
        // the brain asks the edge who holds an ask before re-issuing one a
        // sleep broke.
        if let hermes = bridge as? HermesBrain {
            hermes.onTask = { [weak self] report in
                DispatchQueue.main.async { self?.cloud.task(report) }
            }
            hermes.taskArbiter = { [weak self] task, done in
                guard let self else { done(true); return }
                DispatchQueue.main.async { self.cloud.taskClaim(task, done: done) }
            }
        }
        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready(_, let tools, let servers):
                let wasConnected = self.connected
                self.connected = true
                self.needsSignIn = false
                // First words after a launch should not pay for a cold
                // claude child; one silent turn brings the session up.
                if !wasConnected, self.config.dictationPolish, self.effectiveDictationKey != .off {
                    self.polisher.warmUp()
                }
                self.restartAttempts = 0
                if !wasConnected { self.pickUpLeftoverTurn() }
                // "1 tools ready" — the first thing under the greeting, and
                // both wrong and jargon: a count of tools is a number about
                // Moe's insides, and it read "1 tools" whenever there was
                // one. What a person wants to know here is whether Moe can
                // hear them, and what of theirs it can reach. The counts go
                // to the log, where they were the useful thing anyway.
                Log.write("brain ready: \(tools.count) tool(s), \(servers.count) connection(s)")
                self.statusLine = servers.isEmpty
                    ? "Ready"
                    : "Ready · \(servers.count) connection\(servers.count == 1 ? "" : "s")"

            case .textDelta(let t):
                // An abandoned reply's stragglers — deltas already on the
                // main queue when the brain was reset — are not a new turn.
                guard !self.replyIsAbandoned else { return }
                // On the voice turn's trace, whatever this turn turns out to be.
                self.voice.markFirstToken()
                if self.awaitingFirstToken, let began = self.turnBeganAt {
                    self.awaitingFirstToken = false
                    Log.write("turn: first token \(VoiceEngine.ms(since: began)) after the mic closed")
                }
                // `[POINT:x,y:label]` tags come out here and never reach
                // the transcript or the voice.
                let (text, tags) = self.pointParser.feed(t)
                if !text.isEmpty { self.appendToStreamingTurn(text) }
                for tag in tags { self.showPoint(tag) }
                self.speakReadySentences()
                self.armSpeechStall()

            case .reasoningDelta(let t):
                guard !self.replyIsAbandoned else { return }
                self.pendingThinking += t

            case .toolStarted(let toolName, let id, let emoji, let detail, let spoken):
                guard !self.replyIsAbandoned else { return }
                // Hermes's icon for that tool, straight off the wire. It is
                // the same one its own CLI shows, so the account Moe gives of
                // a job reads like the account Hermes gives of it.
                let shown = emoji.map { "\($0) \(detail)" } ?? detail
                self.runningTools[id] = shown
                self.runningToolNames[id] = toolName
                self.statusLine = shown
                self.lastToolDetail = detail
                self.workingStep = spoken ?? detail
                self.acting = true
                // Every step is a boundary between what the model wrote
                // before it and what comes after — the answer, if this turns
                // out to be the last one. See `WorkSilently`.
                if let sid = self.streamingTurnID,
                   let turn = self.turns.first(where: { $0.id == sid }) {
                    self.quietWork.stepStarted(at: turn.text.count)
                    if !self.quietWork.speaks(.interim) { self.spokenUpTo = turn.text }
                }
                // The model has stopped writing to go and do something, so
                // whatever it wrote is finished — say it now rather than hold
                // it behind a boundary rule for the length of the tool call.
                self.flushPendingSpeech()
                // Consecutive identical steps ("Reading your mail" three
                // times) would make the chip row noise rather than an account.
                // In the words Moe would say about it ("Searching your
                // files"), not the argument preview ("🔍 *.png"): this list
                // is read back under the answer, by a person.
                let step = spoken ?? shown
                if self.pendingTools.last != step, !step.isEmpty {
                    self.pendingTools.append(step)
                }
                // The pages this turn opened, off Hermes's own preview of
                // the call. This is the answer to "give me the links" that
                // is not the model remembering where it went.
                for link in ReplyLinks.found(in: detail)
                where !self.pendingLinks.contains(link) {
                    self.pendingLinks.append(link)
                }
                self.currentStepPhrase = spoken
                self.drivingApp = Self.appBeingDriven(tool: toolName, detail: detail)
                    ?? self.drivingApp
                if Self.isBrowserTool(toolName) { self.browsing = true }
                if let spoken { self.narrateStep(spoken) }

            case .toolFinished(let id, let fix):
                guard !self.replyIsAbandoned else { return }
                if let fix { self.offerFix(fix) }
                self.runningTools[id] = nil
                self.runningToolNames[id] = nil
                if self.runningTools.isEmpty {
                    self.currentStepPhrase = nil
                    // The send step ends only once the sheet is answered, so
                    // this is the backstop for a dialog killed before it
                    // could say "answered".
                    self.confirmWaiting = nil
                    // `drivingApp` deliberately NOT cleared here.
                    //
                    // It used to be, and that made the teal notch useless:
                    // it tracked "a screen tool is executing right now",
                    // which is a second or two at a time. Measured on this
                    // Mac from the gaps between consecutive tool starts in
                    // one session: 1, 13, 2, 0, 13, 1, 1, 1, 77, 1, 1, 30,
                    // 32 seconds. Three stretches over half a minute with
                    // nothing running — during which the island went back to
                    // its ordinary colour and the stop disappeared with it.
                    //
                    // What a person needs to know is "Moe has your screen on
                    // this task", which stays true through the thinking
                    // between calls. It is cleared when the TURN ends —
                    // abandonTurnState() and stopEverything() both do it —
                    // which is when it stops being true.
                }
                // Report whatever is still running, not the last thing that
                // started. Several steps overlap on a `delegate_task`, and
                // the one that finishes first is rarely the one to drop.
                if let current = self.runningTools.values.first {
                    self.statusLine = current
                } else if self.awaitingReply {
                    // Nothing running: the model has the results and is
                    // writing. Say that rather than leave a finished step up.
                    self.statusLine = "thinking"
                    self.lastToolDetail = ""
                    self.workingStep = nil
                }

            case .turnFinished(let full, let end):
                guard !self.replyIsAbandoned else { return }
                // Read before the lines below clear them: the stall guard
                // only prods a turn somebody was owed, with nothing running.
                let wasOwed = self.awaitingReply
                let stepsRunning = !self.runningTools.isEmpty
                if let began = self.turnBeganAt {
                    Log.write("turn: brain done in \(VoiceEngine.ms(since: began))")
                }
                self.awaitingFirstToken = false
                self.awaitingReply = false
                self.acting = false
                // The run is over, so the colour that says "there is
                // something to stop" goes with it. It used to stay up until
                // the next turn or a double-tap — which is why "to get it
                // off you have to double-press Option" was the report.
                self.drivingApp = nil
                self.browsing = false
                self.speechStall?.cancel(); self.speechStall = nil
                self.progressTimer?.invalidate(); self.progressTimer = nil
                self.runningTools.removeAll()
                self.runningToolNames.removeAll()
                self.confirmWaiting = nil
                self.lastToolDetail = ""
                let held = self.pointParser.flush()
                if !held.isEmpty { self.appendToStreamingTurn(held) }
                // The model marks a goodbye itself, because only it reads
                // "that's all" in whatever language it was said — and its
                // own marker is not phrase matching against the user's
                // words. It also works when Apple's on-device judge is
                // unavailable, which on a new Mac it is for days.
                let saidGoodbye = full.contains(Self.endMarker)
                // The other marker: the user asked to record in words the
                // local grammar does not cover, and the model is asking Moe
                // to do it. Moe still owns what happens — the consent sheet,
                // the ring, the recorder — so this is a request, not the
                // model recording.
                let meetingAsk = MeetingIntent.marker(in: full)
                let answer = PointTagParser.strip(
                    MeetingIntent.strippingMarkers(Self.strippingEndMarker(full)))
                // A continuation writes on the end of the reply it continues:
                // the promise and what followed it are one answer.
                let base = self.continuationBase ?? ""
                self.continuationBase = nil
                self.finishStreamingTurn(base.isEmpty ? answer
                    : (base + answer).trimmingCharacters(in: .whitespacesAndNewlines))
                self.statusLine = ""
                // The end of a turn somebody asked for. Once, here — not on
                // a delta, not on a status line, and not for the silent
                // background turns, which never armed the signal.
                self.announce(self.replySignal.ended(answer))
                // Retention (owner decision, 2026-10-01): a real answer to a
                // turn that both started by voice and was started by the
                // person, not one Moe raised itself, counts toward "three
                // uses in the first week" and "a day-7 return". See
                // `CloudLink.spokenTurnAnswered`.
                if self.turnOrigin == .spoken, self.turnStarter == .person, end == .answered {
                    self.cloud.spokenTurnAnswered()
                }
                // The first answer to anything a person said or typed
                // (`CloudLink.personTurnAnswered`).
                if self.turnStarter == .person, end == .answered { self.cloud.personTurnAnswered() }
                // File the thread on every completed exchange rather than on
                // quit alone: a crash or a force-quit must not cost the
                // conversation you just had.
                self.saveConversation(delivered: true)
                if self.quietWork.isOn, let id = self.streamingTurnID,
                   let turn = self.turns.first(where: { $0.id == id }) {
                    // Worked silently: only the answer — the text after the
                    // last step — is said, not the narration before it.
                    let start = self.quietWork.finalReplyStart(in: turn.text)
                    self.spokenUpTo = String(turn.text.prefix(start))
                    Log.write("work silently: saying the answer, \(turn.text.count - start) of \(turn.text.count) chars")
                }
                self.speakRemainder()
                // After the remainder, never before: `replyFinished` is what
                // lets the speech pump close the turn out, and if it were
                // cleared first the last chunk would still be arriving when
                // the pump decided the reply was over.
                self.voice.replyFinished()
                if saidGoodbye {
                    Log.write("turn: the model marked the conversation over")
                    self.voice.closeAfterSpeaking()
                }
                if let meetingAsk { self.handleMeetingMarker(meetingAsk) }
                // Only the model's own end of turn. A turn the harness ended —
                // stopped after a sleep because it had already sent or paid, or
                // handed to the cloud — must never be told to carry on.
                if wasOwed, end == .answered, !stepsRunning, !saidGoodbye, meetingAsk == nil {
                    self.continueIfStalled(answer)
                }

            case .status(let s):
                self.statusLine = s

            case .notice(let text):
                // The engine re-emits the usage warning on every turn once
                // the window is over 90%, so the same sentence would land in
                // the transcript again and again. Said once per wording: the
                // percentage climbs, so a genuinely worse number still
                // speaks, and an unchanged one stays quiet.
                guard self.lastNotice != text else { break }
                self.lastNotice = text
                Log.write("notice: \(text)")
                self.turns.append(Turn(role: .system, text: text))

            case .error(let message):
                let asked = self.awaitingReply
                self.awaitingReply = false
                self.speechStall?.cancel(); self.speechStall = nil
                // Said, not only written, when the question was spoken: a
                // failed turn used to leave the person talking to silence
                // while the window reopened as though Moe had answered
                // (`SpokenError`). Queued before the reply is called
                // finished, so the window opens after it has been heard.
                if self.replySpeaks, !self.replyAbandoned, self.quietWork.speaks(.interim) {
                    self.voice.speak(SpokenError.line(for: message, needsSignIn: self.needsSignIn))
                }
                // Asked with no AI connected: the place to connect one opens.
                if asked, self.needsSignIn { NotificationCenter.default.post(name: .moeConnectAnAI, object: nil) }
                self.voice.replyFinished()
                self.acting = false
                self.drivingApp = nil
                self.browsing = false
                self.statusLine = ""
                var note = Turn(role: .system, text: message)
                note.failed = asked
                self.turns.append(note)
                if self.mode == .thinking { self.mode = .idle }
                // A question that got an error is still an answer to the
                // question. §5: silence is the one thing this must not be.
                self.announce(self.replySignal.ended(message, failed: true))

            case .failedToLaunch(let message):
                // A question was waiting and no AI is connected: said, and
                // the place to connect one opened — it used to be silence.
                if self.awaitingReply, message.hasPrefix(HermesKey.needSignInPrefix) {
                    if self.replySpeaks { self.voice.speak(SpokenError.connectAnAI) }
                    NotificationCenter.default.post(name: .moeConnectAnAI, object: nil)
                }
                self.awaitingReply = false
                self.speechStall?.cancel(); self.speechStall = nil
                self.voice.replyFinished()
                self.acting = false
                self.drivingApp = nil
                self.browsing = false
                self.connected = false
                self.mode = .idle
                if message.hasPrefix(HermesKey.needSignInPrefix) {
                    // One plain call to action, on the island and in the
                    // chat, instead of the supervisor's diagnosis.
                    self.needsSignIn = true
                    self.statusLine = "Connect an AI to start (Moe menu › Connect an AI)"
                    self.turns.append(Turn(role: .system,
                        text: "Connect an AI to start — your Claude or ChatGPT plan, or an API key. Moe menu › Connect an AI."))
                } else {
                    self.statusLine = ""
                    self.turns.append(Turn(role: .system, text: message))
                }
                // Whichever of the two was just put on screen: a brain that
                // would not start is the answer this question got.
                self.announce(self.replySignal.ended(self.turns.last?.text ?? message,
                                                     failed: true))

            case .exited(let code):
                self.awaitingReply = false
                self.speechStall?.cancel(); self.speechStall = nil
                self.voice.replyFinished()
                self.acting = false
                self.drivingApp = nil
                self.browsing = false
                self.connected = false
                // A brain that died mid-thought owes an answer it will never
                // give. Say so rather than leave the question hanging — but
                // say it, not its exit status. The code is in the log.
                Log.write("brain exited mid-answer: \(self.config.brain.cliName) code \(code)")
                self.announce(self.replySignal.ended(
                    "Moe lost its train of thought there — ask me again?",
                    failed: true))
                self.handleExit(code: code)
            }
        }

        // One recogniser, two destinations: the machine's turns go to the
        // conversation, a dictation's words go to the cursor.
        voice.onPartial = { [weak self] text in self?.partial = text }
        voice.onDictationPartial = { [weak self] text in self?.dictationPartial = text }

        // A turn began by your hand or your voice: light the island and
        // take the screenshot that rides with it.
        voice.onSessionOpened = { [weak self] in
            guard let self else { return }
            self.onWantsIsland?(true)
            self.screen.pressBegan()
        }

        voice.onUtterance = { [weak self] text in
            guard let self else { return }
            self.partial = ""
            self.onWantsIsland?(true)
            // Hotkey and wake-word turns end on silence, not a key-up: a
            // long request refreshes its screenshot here instead.
            self.screen.pressEnded()
            // The one path into `submit` that came through a microphone.
            self.submit(text, origin: .spoken, starter: .person)
        }
        voice.onContinuation = { [weak self] text in
            guard let self else { return }
            self.partial = ""
            self.onWantsIsland?(true)
            self.screen.pressEnded()
            self.submit(text, origin: .spoken, starter: .person, continuation: true)
        }

        // The mic meter, and the one place it is allowed to reach the UI.
        //
        // `level` is `@Published` on `Conductor`, and `Conductor` is held as
        // `@ObservedObject` by twenty-one views — MainWindow, ChatPane,
        // IslandView and every settings pane. `ObservableObject` sends one
        // `objectWillChange` for *any* property, with no per-property
        // tracking, so one assignment here invalidates all of them.
        //
        // The pipeline offers a reading about fifteen times a second for as
        // long as the audio graph is up, which is always. Assigned
        // unconditionally — as this line used to be — that is fifteen full
        // view-tree invalidations a second, for ever, in an app nobody is
        // talking to. It was the largest single item in a CPU profile of an
        // idle Moe: `LayoutEngineBox.sizeThatFits` above every model.
        //
        // Two conditions, and both are exact rather than cautious:
        //
        // 1. Nothing renders the number unless something is listening.
        //    `IslandView.notchHalo` computes `drive = listening ? voice :
        //    (idle ? 0 : 0.4)` and `StateDot` sizes on it only in
        //    `.listening`. Off the microphone the meter is not dimmed or
        //    approximated — it is unread. So publish zero and stop.
        // 2. `@Published` does not de-duplicate: assigning 0 over 0 still
        //    fires. Hence the compare, not just the gate.
        //
        // The rule itself is `MicMeterGate`, not this closure: nothing in
        // the suite can build a `Conductor`, so a gate written here could
        // only ever be tested by reading it. There it has `MicMeterGateTests`
        // counting what it publishes over a run of readings.
        voice.onLevel = { [weak self] l in
            guard let self else { return }
            let heard = self.mode == .listening || self.dictation == .listening
            // 3. Muted, nothing on screen follows the microphone (the owner,
            //    2026-09-25: "when muted it still tracks my voice; I see it
            //    pulsing when I talk"). The pipeline still hears the room —
            //    the wake word and the talk-through need it — but the UI is
            //    handed zero.
            guard let next = MicMeterGate.next(reading: l, listening: heard,
                                               muted: self.micMuted, current: self.level)
            else { return }
            self.level = next
        }

        // The number that actually describes how fast Moe feels: the gap
        // between the microphone closing and the first word being heard.
        voice.onFirstAudio = { [weak self] in
            guard let self, self.awaitingFirstAudio, let began = self.turnBeganAt else { return }
            self.awaitingFirstAudio = false
            Log.write("turn: first word heard \(VoiceEngine.ms(since: began)) after the mic closed")
        }

        // One state machine, one view of it. `mode` is derived here and
        // nowhere else for a spoken turn.
        voice.onStateChange = { [weak self] s in
            guard let self else { return }
            self.inConversation = self.voice.inConversation
            self.applyVoiceState(s)
        }

        voice.onError = { [weak self] message in
            guard let self else { return }
            self.partial = ""
            self.mode = .idle
            // On the island too: an error only in the chat window is invisible
            // when you're looking at the notch waiting for something to happen.
            self.statusLine = message
            self.turns.append(Turn(role: .system, text: message))
            self.onWantsIsland?(true)
        }

        // A dead microphone is a state, not a turn: one quiet status line
        // and the sidebar's dot, said when it changes. It used to come
        // through `onError` — a bubble in the conversation, raw
        // AVFoundation text included, once per hold press that failed
        // (docs/INBOX-QUIET.md: Moe-about-Moe is never noise in the thread).
        var micLine = ""
        voice.onMicrophoneHealth = { [weak self] dead, message in
            guard let self else { return }
            self.microphoneDead = dead
            if dead {
                micLine = message ?? ""
                if !micLine.isEmpty { self.statusLine = micLine }
            } else {
                if !micLine.isEmpty, self.statusLine == micLine { self.statusLine = "" }
                micLine = ""
            }
        }

        // Not an error: the turn goes on, in another voice. Written into the
        // conversation so it is read, and never spoken over the reply.
        voice.onNotice = { [weak self] message in
            guard let self else { return }
            // The status line is one glance; the whole of it is in the chat.
            self.statusLine = message.count > 80 ? String(message.prefix(79)) + "…" : message
            self.turns.append(Turn(role: .system, text: message))
            self.onWantsIsland?(true)
        }

        var loadLine = ""
        voice.onLoadProgress = { [weak self] s in
            guard let self else { return }
            // Empty is "ready": take the warm-up line down, and only that
            // line — it used to stay up until something else replaced it.
            guard !s.isEmpty else {
                if self.statusLine == loadLine { self.statusLine = "" }
                return
            }
            loadLine = s
            self.statusLine = s
        }

        // The key came up before the microphone was ever armed — the models
        // were still loading. `holdBegan` lit the island the instant the key
        // went down, so nothing else is going to put it out.
        voice.onHoldAbandoned = { [weak self] in
            guard let self else { return }
            self.partial = ""
            if self.mode == .listening { self.mode = .idle }
            self.statusLine = "still warming up — hold the key again."
            self.onWantsIsland?(true)
        }

        // You interrupted: whatever else this reply says is read, not heard.
        voice.onAbandonReply = { [weak self] in self?.abandonSpokenReply() }
        // …or you didn't, really: carry on from the last sentence heard.
        voice.onResumeReply = { [weak self] in self?.resumeSpokenReply() }

        // A tap of the key held the reply. `.speaking` with nothing coming
        // out is what a broken assistant looks like, so say what happened
        // and how to undo it — the gesture is invisible otherwise, which
        // was half the original complaint about it.
        voice.onReplyHeld = { [weak self] held in
            guard let self else { return }
            self.replyHeldByKey = held
            self.statusLine = held ? Self.replyHeldLine : ""
        }

        voice.onMicMuted = { [weak self] on in
            guard let self else { return }
            self.micMuted = on
            // Flat the moment it mutes, not at the next meter reading.
            if on, self.level != 0 { self.level = 0 }
        }

        voice.onOfferToClose = { [weak self] in
            guard let self else { return }
            self.offeringToClose = true
        }
        voice.onConversationEnded = { [weak self] in
            guard let self else { return }
            self.inConversation = false
            self.offeringToClose = false
            self.partial = ""
            self.onWantsIsland?(false)
        }
    }

    /// The island's view of a spoken turn, from the voice's state.
    ///
    /// A typed turn keeps its own `thinking` (set by `submit`, cleared by
    /// `settleMode`); a spoken one is whatever the machine says it is.
    private func applyVoiceState(_ s: VoiceEngine.State) {
        if statusLine == Self.readingBack {
            if case .deciding = s {} else { statusLine = "" }
        }
        switch s {
        case .off, .standby, .suspended, .attending, .followUp: replayingTurnID = nil
        default: break
        }
        if case .speaking = s {
            voicedTurnID = replayingTurnID ?? streamingTurnID
                ?? turns.last(where: { $0.role == .moe })?.id
        } else if !replyHeldByKey {
            voicedTurnID = nil
        }
        betweenTurns = s == .followUp || s == .attending(.followUp)
        switch s {
        case .off, .standby, .suspended:
            // A typed turn's reply may still be on its way (its sentences
            // play as asides, and the machine rests between them).
            mode = awaitingReply ? .thinking : .idle
        case .attending, .capturing, .followUp:
            mode = .listening
        case .deciding:
            mode = .thinking
            statusLine = Self.readingBack
        case .thinking:
            mode = .thinking
        case .speaking:
            mode = .speaking
        }
        // A held reply stays `.speaking`, and the island would otherwise
        // animate as though the answer were still being said. The line is
        // the only thing telling the person their tap landed.
        if replyHeldByKey, statusLine != Self.replyHeldLine { statusLine = Self.replyHeldLine }
        // A hands-free turn is a recording. Once the voice is anywhere else
        // (an error, a stop from the island) there is nothing for the next
        // tap to send.
        if talkLatched, !Self.stillRecording(s) { abandonTalkLatch() }
    }

    private static func stillRecording(_ s: VoiceEngine.State) -> Bool {
        if case .capturing(.hold) = s { return true }
        return false
    }

    private static let readingBack = "reading that back…"
    /// Shown while a tap is holding the reply. It names the way out,
    /// because a pause nobody can undo is a hang.
    static let replyHeldLine = "paused — tap again to carry on"

    /// The reply is stopped where it is, waiting for the next tap or ▶.
    @Published private(set) var replyHeldByKey = false
    /// The reply whose voice is out now (playing or paused) — the chat row
    /// and the island put their ⏸ ▶ ↺ on it.
    @Published private(set) var voicedTurnID: UUID?

    /// You interrupted the reply in flight — by the key, by its name, or by
    /// talking over it. The words so far stay in the transcript; nothing
    /// more of it is spoken, and the brain is freed for what you say next.
    ///
    /// Freed, not paused: Hermes runs one turn per session, and the next
    /// question would otherwise be refused with "still working on the last
    /// one" for as long as the abandoned turn's tools take. Same recipe as
    /// `stopEverything`: a fresh session, the conversation restored into it.
    /// The last exchange was the first half of a request and the reply it
    /// never got (`abandonSpokenReply` left it as "…"): both go, because
    /// the whole request is about to take their place.
    private func withdrawFragment() {
        guard turns.count >= 2,
              turns[turns.count - 1].role == .moe,
              turns[turns.count - 2].role == .you else { return }
        let reply = turns[turns.count - 1]
        guard reply.text == "…" || reply.text.isEmpty || reply.isStreaming else { return }
        turns.removeLast(2)
        if streamingTurnID == reply.id { streamingTurnID = nil }
    }

    private func abandonSpokenReply() {
        // The brain is usually done before the audio is: the cut and
        // the note apply either way, the reset only to a busy brain.
        let brainBusy = awaitingReply
        replyAbandoned = true
        // A pane opened in the turn being abandoned has nobody to carry on for.
        let abandoned = personTurns
        grantWatch.cancel(where: { $0.personTurn == abandoned }, "the turn was abandoned")
        speechStall?.cancel(); speechStall = nil
        // The transcript keeps what was heard, and marks the cut: the
        // words after it were written, never said. The brain is told the
        // same with the next question, so it does not believe it finished.
        // By offset into the raw reply (what each piece carried when it
        // went to the voice), never by matching heard speech against the
        // text: markdown, newlines and step narration never match.
        var heard = ""
        if let id = streamingTurnID ?? turns.last(where: { $0.role == .moe })?.id,
           let idx = turns.firstIndex(where: { $0.id == id }) {
            let full = turns[idx].text
            let offset = min(voice.heardReplyOffset, full.count)
            heard = String(full.prefix(offset))
            // What was written but never said still happened: Moe filed
            // the note, said so, and was talked over before a word of it
            // played. Replacing that with "…" deleted the only record the
            // person had — they never heard it, so the transcript is
            // where they find out. Keep it whole when none of it was
            // heard; cut it where they stopped hearing it when some was.
            if offset > 0, offset < full.count {
                turns[idx].text = heard + " …"
            } else if offset == 0, brainBusy {
                // Nothing heard and nothing finished: there is no answer
                // to keep, only a question that was withdrawn.
                turns[idx].text = "…"
            }
            spokenUpTo = turns[idx].text
        }
        // Only what was heard is known here. What the interruption *means*
        // for the standing request depends on the words that follow, and
        // those arrive at `submit` — so the sentence is finished there.
        interruptedHeard = heard
        guard brainBusy else {
            Log.write("turn: interrupted — finished reply cut after \(heard.count) chars heard")
            return
        }
        awaitingReply = false
        replySignal.abandoned()    // a withdrawn question gets no panel for its answer
        abandonTurnState()
        // The turn goes; the session stays. This used to be a reset with
        // the conversation restored into a fresh session, and the cost was
        // measured twice. 2026-09-04, one reset at 12:24:00:
        //
        //     +0s   → (You were interrupted…)   the person's next turn
        //     +5s   ← (silent turn complete)     the warm-up, "say ready"
        //     +10s  ← (silent turn complete)     the context restore
        //     +14s  turn: first token 13.9 s
        //
        // Then, with the warm-up dropped and the restore folded into the
        // next turn (7 days to 2026-09-06): the fresh session still made
        // Hermes spawn a new child — 1.6–5.2 s to boot, plus its own
        // "say ready" turn at p50 1.7 s — inside the person's next turn,
        // 85 times; first token after an interruption came at 12–27 s
        // against p50 5 s otherwise. Closing the request frees the turn in
        // about 65 ms and the same warm child answers the next words. The
        // interruption itself is still explained to the brain: the note
        // rides on the next `submit` as before.
        bridge.abandonTurn()
        Log.write("turn: interrupted — reply abandoned after \(heard.count) chars heard, brain turn dropped")
    }

    /// What the model writes when the person is leaving. Its own token,
    /// never theirs, so reading it is not phrase matching (VOICE-PLAN §4.3).
    static let endMarker = "<end/>"

    static func strippingEndMarker(_ text: String) -> String {
        text.replacingOccurrences(of: endMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The conversation a restarted brain has to be told about, waiting for
    /// the next turn to carry it. Sent as its own message it costs a whole
    /// round trip in front of the person's question; carried with it, none.
    private var stagedContext: String?
    /// The card's words and its handle, waiting to ride in front of the
    /// answer typed into the nudge card's Reply field. Set by `replyToNudge`
    /// immediately before it calls `submit`, consumed there, and never
    /// anywhere else — so it can never attach to a later, unrelated turn.
    private var nudgeReplyNote: String?
    /// True once the stall guard has sent its one continuation for the turn
    /// in flight (`StallGuard`, docs/FIXABLE-FAILURES.md bug 9). Set by the
    /// continuation's own `submit`, cleared by every other one — so a reply
    /// that promises work and stops gets exactly one "carry on", and the
    /// reply to that can never earn a second.
    private var stallContinuationSent = false
    /// The reply the stall guard's continuation is writing on the end of —
    /// its text so far and a paragraph break. Set only while that one
    /// continuation runs.
    private var continuationBase: String?

    /// The brief as the brain has already been told it, section by section,
    /// and which session it was told in (`BriefLedger`).
    ///
    /// Keyed by session id rather than cleared at each of the six places that
    /// abandon a conversation, because a seventh will be written and will not
    /// know to clear this. Rotating the session id is what "the model has not
    /// heard any of this" actually means, and every one of those paths does it
    /// already. See CLAUDE.md on guards that enumerate their cases.
    private var briefLedger = BriefLedger()
    /// Which session has read the delivery reminder in full; same keying.
    private var deliveryReminderLedger = BrainPrompt.DeliveryReminderLedger()

    /// A note for the brain's next turn: where the last reply was cut.
    private var interruptionNote: String?
    /// What the person heard of the reply they cut off, waiting for the words
    /// that will say whether they are amending the request or dropping it.
    private var interruptedHeard: String?

    /// The interruption was nothing (a cough, "mm-hmm", Moe's own echo):
    /// say the rest of the reply from the last sentence that was heard.
    private func resumeSpokenReply() {
        // A reply played again from its ▶ picks up where the tap held it,
        // whatever the reply settings say: somebody asked to hear this one.
        if let id = replayingTurnID, let turn = turns.first(where: { $0.id == id }) {
            let offset = min(voice.heardReplyOffset, turn.text.count)
            spokenUpTo = String(turn.text.prefix(offset))
            Log.write("turn: resuming replay from \(offset) of \(turn.text.count) chars")
            speakToEnd(of: turn.text)
            return
        }
        guard replySpeaks,
              let id = streamingTurnID ?? turns.last(where: { $0.role == .moe })?.id,
              let turn = turns.first(where: { $0.id == id }) else { return }
        // Rewind to what was heard — by offset into the raw reply, which
        // is what each piece carried when it was sent to the voice. The
        // words after it go to the voice again.
        var offset = min(voice.heardReplyOffset, turn.text.count)
        // Worked silently and finished: a resume never reaches back into the
        // narration that was skipped, even when nothing had been heard yet.
        if quietWork.isOn, !awaitingReply {
            offset = max(offset, quietWork.finalReplyStart(in: turn.text))
        }
        spokenUpTo = String(turn.text.prefix(offset))
        replyAbandoned = false
        Log.write("turn: resuming reply from \(offset) of \(turn.text.count) chars")
        if awaitingReply { speakReadySentences() } else { speakRemainder() }
    }

    /// Restart the CLI, but never in a tight loop.
    private func handleExit(code: Int32) {
        guard !shuttingDown else { return }
        if Date().timeIntervalSince(lastStartAt) > 30 { restartAttempts = 0 }
        restartAttempts += 1

        guard restartAttempts <= 5 else {
            // The exit code, the CLI's name and "check the log" are three
            // things a person cannot use; they go to the log, which is
            // where the person who can use them is looking anyway.
            Log.write("brain gave up after \(restartAttempts) restarts: \(config.brain.cliName) exit \(code)")
            turns.append(Turn(role: .system, text:
                "Moe can't reach \(config.brain.displayName) right now. Start a new "
                + "conversation to try again."))
            mode = .idle
            return
        }

        let delay = min(pow(2.0, Double(restartAttempts - 1)), 30)
        if code != 0 { statusLine = "reconnecting in \(Int(delay))s…" }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.lastStartAt = Date()
            self.bridge.start()
            self.bridge.warmUp()
            self.restoreContext()
        }
    }

    // MARK: - Lifecycle

    /// Give the microphone back while the Mac is locked or asleep.
    ///
    /// The audio graph is up around the clock because the wake word needs
    /// it, and even with Apple's canceller bypassed that costs about a
    /// ninth of a CPU core: the voice-processing unit still runs, the VAD
    /// still runs, buffers are still resampled. On a locked laptop, all of
    /// it is spent listening to an empty room — and a laptop shut on a desk
    /// overnight is exactly the case that makes someone uninstall an app
    /// they otherwise like.
    ///
    /// Nothing was watching for this. There are lock observers in
    /// `startMeetingAwayWatch`, but they are installed only while a meeting
    /// is recording and they only mark the transcript.
    ///
    /// Switching the wake word off is all this does: `setWakeWord(false)`
    /// takes the machine out of standby, which schedules the front end's
    /// existing 60-second teardown. That delay is deliberate cover — a lock
    /// and an immediate unlock never reaches the teardown at all, so the
    /// graph is not churned by someone glancing at their screen.
    ///
    /// **Nothing here may leave the wake word off.** A Moe that stops
    /// answering to its name after an unlock, silently, would be far worse
    /// than the CPU it saves — so the restore is hung on both notifications
    /// that can end the state (unlock, and wake from sleep), it re-reads
    /// `alwaysListening` rather than trusting a remembered flag, and it is
    /// safe to run when nothing was ever quieted.
    private func watchForLock() {
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        lockObservers = [
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.awayEvent(.locked, "screen locked") }
            },
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.awayEvent(.unlocked, "screen unlocked") }
            },
            wnc.addObserver(forName: NSWorkspace.willSleepNotification,
                            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.awayEvent(.willSleep, "going to sleep") }
            },
            wnc.addObserver(forName: NSWorkspace.didWakeNotification,
                            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.awayEvent(.didWake, "woke up") }
            },
        ]
    }

    /// One lock/unlock/sleep/wake notification, applied.
    ///
    /// The rule itself is `AwayMic.decide`, in MoeVoice, because nothing in
    /// the suite can build a `Conductor` — and the failure this must not
    /// have is silent, so it needs a test that can run every ordering of
    /// these four notifications rather than the one pair a person thinks of.
    private func awayEvent(_ event: AwayMic.Event, _ why: String) {
        let decision = AwayMic.decide(event,
                                      released: micReleasedWhileAway,
                                      alwaysListening: alwaysListening,
                                      meetingHasMic: meetingOwnsMic || meeting.isRecording)
        micReleasedWhileAway = decision.released
        guard let on = decision.wakeWord else { return }
        Log.write("audio: \(why) — \(on ? "listening again" : "letting the microphone go until you are back")")
        voice.setWakeWord(on)
    }


    /// Told when the background job has written something worth your
    /// attention (`FileWatch` on the home: `nudge.json` appearing, and once a
    /// minute regardless). It was a read every twenty seconds.
    private func watchForNudges() {
        nudgeWatch?.stop()
        let w = FileWatch(directory: Paths.home, accepting: { $0 == "nudge.json" }) { [weak self] in
            Task { @MainActor in
                // Not while a meeting is on the island. A nudge lights the
                // notch amber and is claimed by a click — but during a
                // meeting a click on the island opens the meeting panel, so
                // the amber would sit over the consent ring with no way to
                // act on it, and (`pendingNudge == nil` above) block every
                // later nudge until the meeting was over. nudge.json is only
                // deleted when the nudge is played or dismissed, so it is
                // still there the moment the notes are done with.
                // The switch is read on every tick rather than captured at
                // start-up: turning it off in Settings must go quiet at once,
                // and a nudge.json written just before the switch was flipped
                // must never surface afterwards. `moe-home/nudge.sh` checks
                // the same key, so with this off nothing is even looked at.
                guard let self, self.config.nudges, self.meeting == .off else { return }
                let url = Paths.home.appendingPathComponent("nudge.json")
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = obj["text"] as? String, !text.isEmpty else {
                    self.maybeRemindAwayCarry()
                    return
                }
                // Through `queueReminder`, not straight into `pendingNudge`:
                // the amber pulse has one door, and the machinery filter
                // lives in it. `moe-home/nudge.sh` writes four human
                // sentences today, but nothing stops anything else on this
                // Mac writing nudge.json, and a second unguarded way onto
                // the island is how the first one stayed unguarded.
                //
                // No handle either: nudge.sh writes nothing that could
                // later be closed, snoozed or muted. Going through the one
                // door is also what clears `pendingNudgeHandle`, so this
                // never inherits the previous pulse's follow-up.
                self.queueReminder(text, origin: InboxGate.Origin(moment: true))
                // In the inbox now, where it stays until it is finished; the
                // file is spent. Left in place it came back every 20 s.
                try? FileManager.default.removeItem(at: url)
            }
            return false
        }
        w.start()
        nudgeWatch = w
    }

    // MARK: - Offers (docs/PROACTIVE-MEMORY.md §4.8)

    /// The offer on the island now, read from the situation it is about —
    /// loaded off the main thread when the card arrives, not parsed on
    /// every redraw (review of the offer path #21).
    @Published private(set) var currentOffer: SituationOffer?
    /// Where the card's offer stands: still loading, current, or no longer
    /// current (settled, redrafted, stale). Only `.current` shows the offer's
    /// buttons; the other two show Dismiss alone — never the reminder's Play
    /// and Reply, which would hand the brain an old draft (re-review #2).
    enum OfferCard: Equatable { case none, loading, current, gone }
    @Published private(set) var offerCard: OfferCard = .none
    /// One send per card: a second tap on "Use draft" does nothing.
    private var offerSendStarted: String?
    /// The offer request that should mark the send gate when it actually
    /// runs — not when it was queued behind a turn in flight.
    private var offerRequestPending: String?
    /// True while the turn carrying an offer's send runs; when it ends, the
    /// send has been decided and the gate's marker is cleared.
    private var offerTurnInFlight = false

    var pendingOffer: SituationOffer? {
        guard let id = pendingNudgeHandle?.offer, !id.isEmpty, offerCard == .current,
              currentOffer?.id == id else { return nil }
        return currentOffer
    }

    /// Whether the card on the island is an offer at all (whatever its state).
    var cardIsOffer: Bool { !(pendingNudgeHandle?.offer ?? "").isEmpty }

    private func refreshOffer() {
        guard let id = pendingNudgeHandle?.offer, !id.isEmpty else {
            currentOffer = nil; offerCard = .none; return
        }
        currentOffer = nil
        offerCard = .loading
        Task.detached(priority: .userInitiated) {
            let loaded = SituationOffer.load(id: id)
            await MainActor.run { [weak self] in
                guard let self, self.pendingNudgeHandle?.offer == id else { return }
                self.currentOffer = loaded
                self.offerCard = loaded == nil ? .gone : .current
            }
        }
    }

    /// What the brain is told about the card, in two parts: a line inside
    /// the background note's parentheses, and the offer's own note — the
    /// fenced draft — AFTER them, so nothing in a draft can close them. An
    /// offer that is not current hands over no draft at all. Every path
    /// that hands one over marks the send gate (re-review #1).
    private func handleNote(_ handle: NudgeHandle?) -> (inline: String, after: String) {
        guard let handle else { return ("", "") }
        guard !handle.offer.isEmpty else { return (handle.instruction, "") }
        guard offerCard == .current, currentOffer?.id == handle.offer else {
            return ("This was an offer that is no longer current: nothing from it is to be sent.", "")
        }
        SituationOffer.markOfferSend(for: SituationOffer.contextLife)
        return ("", handle.instruction)
    }

    /// "Use draft". Checked again first, against the card the person saw: a
    /// situation settled, redrafted or re-offered since is not sent — the
    /// draft that goes is the one on the card (re-review #4). One send per
    /// card, however many taps.
    ///
    /// Where the conversation's own connector can take the exact chat (a
    /// WhatsApp jid), the app sends it itself — no model in between, and the
    /// connector's dialog shows the words and the chat and waits for the
    /// click, every time. "Used" is recorded only when that send went.
    /// Anywhere else it is a turn asking Moe to send it, with the draft and
    /// the conversation fenced as data, and the send gate told that this is
    /// an offer's send, which no session grant answers for.
    func useOfferDraft() {
        guard let seen = pendingOffer, !seen.draft.isEmpty, offerSendStarted != seen.id else { return }
        offerSendStarted = seen.id
        let id = seen.id
        Task.detached(priority: .userInitiated) {
            let now = SituationOffer.load(id: id)
            await MainActor.run { [weak self] in
                guard let self, self.pendingNudgeHandle?.offer == id else { return }
                self.clearNudge()
                guard let offer = now, offer.sameVersion(as: seen) else {
                    self.turns.append(Turn(role: .system, text: "That offer is no longer current — nothing was sent."))
                    return
                }
                if let direct = offer.directSend {
                    self.sendDirectly(offer, direct)
                } else {
                    SituationOffer.record(offer.id, "chose-to-send")
                    self.offerRequestPending = offer.sendRequest
                    self.submit(offer.sendRequest, origin: .typed, starter: .person)
                }
            }
        }
    }

    /// The offer request is about to go to the brain (now, or later from the
    /// queue): mark the gate for as long as that turn runs.
    private func offerRequestRuns(_ outgoing: String) {
        guard let pending = offerRequestPending, outgoing.contains(pending) else { return }
        offerRequestPending = nil
        offerTurnInFlight = true
        SituationOffer.markOfferSend(for: SituationOffer.requestLife)
    }

    /// The turn that carried an offer's send ended: it was sent or it was
    /// not, and the gate goes back to normal (re-review #8).
    private func offerTurnEnded() {
        guard offerTurnInFlight else { return }
        offerTurnInFlight = false
        SituationOffer.clearOfferSend()
    }

    private func sendDirectly(_ offer: SituationOffer,
                              _ direct: (script: String, args: [String], stdin: String)) {
        let script = Paths.home.appendingPathComponent(direct.script).path
        turns.append(Turn(role: .system, text: "Showing you the reply to \(offer.to.isEmpty ? "them" : offer.to) before it goes…"))
        Task.detached(priority: .userInitiated) {
            let r = ScriptRunner.run(script, direct.args, stdin: direct.stdin, timeout: 600)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if r.status == 0 {
                    SituationOffer.record(offer.id, "used")
                    self.turns.append(Turn(role: .system, text: "Sent to \(offer.to.isEmpty ? "them" : offer.to) on \(offer.source)."))
                } else {
                    Log.write("offer \(offer.id): not sent (\(r.status))")
                    self.turns.append(Turn(role: .system, text: SituationOffer.notSentLine(r.output)))
                }
            }
        }
    }

    /// "See it": the whole of what was prepared, as Moe's turn in this
    /// conversation, where there is room for the options, what was found and
    /// the draft. The brain is told they opened it — with the offer's own
    /// note after the background note, so "send it" said next has the draft
    /// behind it — and the gate is marked for that send.
    func seeOffer() {
        guard let offer = pendingOffer else { return }
        SituationOffer.record(offer.id, "opened")
        let note = handleNote(pendingNudgeHandle)
        clearNudge(note: """
        (Background note, not from the user. They opened an offer you made and are reading it on \
        screen. Do not reply to this message.)
        """ + (note.after.isEmpty ? "" : "\n\n" + note.after))
        turns.append(Turn(role: .moe, text: offer.card))
    }

    /// "Not now" and "Not this kind of thing": what the learner reads
    /// (lib/learner.py) — this is what makes the next offer of that kind
    /// less likely, or silences the kind for a month.
    func declineOffer(kind: Bool) {
        if let id = pendingNudgeHandle?.offer, !id.isEmpty {
            SituationOffer.record(id, kind ? "not-this-kind" : "not-now")
        }
        let said = kind ? "not to suggest this kind of thing" : "not now"
        clearNudge(note: """
        (Background note, not from the user. They said \(said) to an offer you made; Moe has \
        recorded it and will hold back accordingly. Do not reply to this message.)
        """)
    }

    /// Dismiss on an offer card that is not current: gone, and nothing of
    /// it handed to the brain.
    func dismissOffer() {
        clearNudge(note: """
        (Background note, not from the user. An offer you made was no longer current and they \
        dismissed it; nothing from it is to be sent. Do not reply to this message.)
        """)
    }

    // MARK: - While your Mac is off (2026-09-25)

    /// When the island last looked for a *While your Mac is off* reminder.
    private var awayCarryLookedAt: Date = .distantPast
    /// How often it looks: the answer changes when something is connected,
    /// not by the minute.
    nonisolated static let awayCarryLookEvery: TimeInterval = 30 * 60

    /// The connection a *While your Mac is off* card on the island is about.
    var pendingAwayCarry: String? {
        guard let id = pendingNudgeHandle?.awayCarry, !id.isEmpty else { return nil }
        return id
    }

    /// The owner, 2026-09-25: his WhatsApp never reached his cloud computer
    /// and nothing said so. With Away set up, one card on the island for the
    /// first connection that one step would carry over — Show me, Not now
    /// (a week), Don't remind me (for good). The rows Connections has loaded
    /// are used when it has loaded them; before that, only WhatsApp and
    /// Telegram, which the Away linker knows without running anything.
    private func maybeRemindAwayCarry(now: Date = Date()) {
        guard now.timeIntervalSince(awayCarryLookedAt) >= Self.awayCarryLookEvery else { return }
        awayCarryLookedAt = now
        // The decision, the words and the snooze are the cloud's
        // (`CloudLink.carryReminderDue`); a build without one has none.
        guard let item = cloud.carryReminderDue(now: now) else { return }
        queueReminder(item.text, handle: NudgeHandle(job: "", jobID: "", loops: [], said: "", awayCarry: item.id))
    }

    /// **Show me**: Settings › Away, where the line and its button are.
    func openAwayCarry() {
        if let id = pendingAwayCarry { cloud.carryReminderAnswered(id, never: false) }
        clearNudge()
        (NSApp.delegate as? AppDelegate)?.showMainWindow(at: .away)
    }

    /// **Not now**: back in a week.
    func awayCarryNotNow() {
        if let id = pendingAwayCarry { cloud.carryReminderAnswered(id, never: false) }
        clearNudge()
    }

    /// **Don't remind me**: never again for this connection, until *Remind
    /// me again* on Settings › Away.
    func awayCarryNever() {
        if let id = pendingAwayCarry { cloud.carryReminderAnswered(id, never: true) }
        clearNudge()
    }

    /// Take the card down without the "waved it away" note `dismissNudge`
    /// sends, saying `note` instead when there is one.
    private func clearNudge(note: String? = nil) {
        ReminderChannels.markAnsweredOnScreen(pendingNudgeHandle?.said ?? "")
        if let note { bridge.send(note, silent: true, starter: .background) }
        pendingNudge = nil
        pendingNudgeWhen = nil
        pendingNudgeHandle = nil
        currentOffer = nil
        offerCard = .none
        offerSendStarted = nil
        try? FileManager.default.removeItem(at: Paths.home.appendingPathComponent("nudge.json"))
        onWantsIsland?(false)
    }

    // MARK: - Noted · Undo

    private var notedWatch: FileWatch?
    private var notedSeen = Set<String>()
    private var notedStamp: Date?

    /// Pick up what per-turn learning noted (`NotedLog`) and put it under
    /// the answer it followed. When the file changes (`FileWatch` on its
    /// directory; it was a stat every three seconds), and only past a stat
    /// while the file is unchanged. Whatever is in the file at launch is
    /// history and is marked seen without being shown.
    private func watchForNoted() {
        notedWatch?.stop()
        if let data = try? Data(contentsOf: NotedLog.url) {
            notedSeen = Set(NotedLog.parse(data).map(\.claim))
        }
        notedStamp = Self.modified(NotedLog.url)
        let name = NotedLog.url.lastPathComponent
        let w = FileWatch(directory: NotedLog.url.deletingLastPathComponent(),
                          accepting: { $0 == name }) { [weak self] in
            Task { @MainActor in self?.readNoted() }
            return false
        }
        w.start()
        notedWatch = w
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func readNoted() {
        let stamp = Self.modified(NotedLog.url)
        guard stamp != notedStamp else { return }
        notedStamp = stamp
        guard let data = try? Data(contentsOf: NotedLog.url) else { return }
        let (updated, consumed) = NotedLog.attach(NotedLog.parse(data), to: turns, seen: notedSeen)
        notedSeen.formUnion(consumed)
        if updated != turns {
            turns = updated
            Log.write("noted: \(consumed.count) fact(s) read, under the answers they followed")
        }
    }

    /// Undo on a "Noted" line: forget the fact, the Memory page's way.
    func forgetNoted(turnID: UUID, claim: String) {
        guard let i = turns.firstIndex(where: { $0.id == turnID }),
              let j = turns[i].noted.firstIndex(where: { $0.claim == claim }) else { return }
        turns[i].noted[j].forgotten = true
        Task {
            let problem: String? = await ScriptRunner.offMain {
                MemoryReader.perform(.forgetMemory(id: claim))
            }
            await MainActor.run {
                if let problem {
                    Log.write("noted: could not forget \(claim): \(problem)")
                    if let i = self.turns.firstIndex(where: { $0.id == turnID }),
                       let j = self.turns[i].noted.firstIndex(where: { $0.claim == claim }) {
                        self.turns[i].noted[j].forgotten = false
                    }
                } else {
                    Log.write("noted: forgot \(claim) at the person's Undo")
                }
            }
        }
    }

    private var inboxWatch: FileWatch?

    /// Told when Hermes delivers a reminder to this screen.
    ///
    /// Same surface as a nudge: the notch pulses amber, hovering shows the
    /// words, Play speaks them. A reminder is something you asked for, but
    /// asking to be reminded is not asking to be read to — the first version
    /// spoke the moment it landed, once to a person on a call. So it waits
    /// to be tapped; what it never does is get lost. The file stays put
    /// while something else is already waiting or a meeting is on, so a
    /// reminder that lands at the wrong moment is late, not gone.
    ///
    /// The files come from the moe-screen Hermes plugin (`~/.moe/inbox/`),
    /// which is where `deliver: moe` goes — every cron job Moe makes, the
    /// proactive pass, a failed background job. The directory is watched
    /// (`FileWatch`), so a reminder set for a time is on the island within
    /// the second; it was a read and a parse every five seconds, all day.
    /// While a file is still waiting (a helper's result, for a quiet moment
    /// or for its conversation) it is asked about every five seconds as
    /// before, because what it waits for is not a file changing; and once a
    /// minute regardless, which is also when snoozes come due.
    private func watchForInbox() {
        inboxWatch?.stop()
        let w = FileWatch(directory: ReminderChannels.inbox, accepting: { $0.hasSuffix(".json") },
                          createIfMissing: true) { [weak self] in
            MainActor.assumeIsolated {
                self?.drainInbox()
                return ReminderChannels.hasWaiting()
            }
        }
        w.start()
        inboxWatch = w
    }

    /// Helper results waiting for a conversation that is not on screen,
    /// already announced there: file → thread. Announced once each, not
    /// every five seconds; the file itself stays in the inbox until that
    /// conversation is opened, so a quit in between loses nothing.
    private var helpersAnnounced: [URL: String] = [:]

    /// One pass over the inbox. The timer's body, and a test's.
    ///
    /// Two rules, because there are two kinds of thing in there:
    ///
    /// - A finished helper's result (`kind: "turn"`) runs whenever Moe is
    ///   idle and no meeting is on — whatever is on the island. On
    ///   2026-09-29 seven helpers finished at 16:30 and their result sat in
    ///   the inbox all day behind an unanswered "Marketing brief" nudge,
    ///   because this used to wait for `pendingNudge == nil` for everything.
    ///   A result is not a card on the island; it is a turn, and it leaves
    ///   the nudge exactly where it was.
    /// - A reminder is the island's, one at a time: it waits while something
    ///   else is already waiting there.
    ///
    /// Oldest first within each.
    func drainInbox(now: Date = Date()) {
        // A held send being acted on past its day is retired first, and
        // snoozes and held sends in the inbox come due (docs/INBOX.md).
        retireExpiredNudge(now: now)
        tidyNotices(now: now)
        let queued = ReminderChannels.pending()
        // A finished helper runs a turn, so it waits for a quiet moment in
        // its file: not during a meeting, and only while idle.
        // Reminders behind it are still kept, in the same pass.
        if mode == .idle, meeting == .off {
            _ = deliverFinishedHelper(from: queued.filter { $0.kind == "turn" }, now: now)
        }

        // Every other file becomes an inbox item at once, whatever else is
        // going on: the inbox holds them, so nothing waits its turn in a file
        // any more, and nothing is lost by being shown. It used to be one at
        // a time, deleted as it was shown.
        var seenTexts = Set<String>()
        for m in queued where m.kind != "turn" {
            // Removed first: if the app dies mid-way the message is gone
            // rather than repeated every five seconds for ever.
            try? FileManager.default.removeItem(at: m.url)
            // Every copy of one sentence in the same sweep is one item.
            // Measured: a five-minute job whose plugin was half-installed
            // left eleven identical notices waiting.
            guard seenTexts.insert(m.text).inserted else {
                Log.write("reminder: dropped another copy of the same message")
                continue
            }
            // Inbox files outlive a closed app and a sleeping Mac, on
            // purpose — but past a day a reminder is history, and is logged
            // instead. A held send says it expired rather than vanishing:
            // somebody may still be expecting it to have gone.
            let age = now.timeIntervalSince(m.at)
            if age > 24 * 3600 {
                if !m.expiredText.isEmpty {
                    Log.write("reminder: a held send expired unanswered (\(Int(age / 3600)) h old)")
                    queueReminder(m.expiredText, earlierAt: nil, handle: nil,
                                  origin: InboxGate.Origin(consequence: true))
                } else {
                    Log.write("reminder dropped (\(Int(age / 3600)) h old): \(m.text.prefix(80))")
                }
                continue
            }
            receive(m)
        }
    }

    /// The first helper result that can be answered now: true when a turn
    /// was started on one. A result for the conversation on screen — or one
    /// that names none (a plugin older than 2026-09-29), or names one this
    /// Mac no longer has — is answered here. A result for another saved
    /// conversation is not answered in this one: the person is told which
    /// conversation it belongs to and offered it, and the file waits until
    /// that conversation is open, where this same pass answers it.
    private func deliverFinishedHelper(from results: [ReminderChannels.Message], now: Date) -> Bool {
        for m in results {
            if now.timeIntervalSince(m.at) > 24 * 3600 {
                try? FileManager.default.removeItem(at: m.url)
                helpersAnnounced[m.url] = nil
                Log.write("helper result dropped (\(Int(now.timeIntervalSince(m.at) / 3600)) h old): "
                          + "\(m.text.prefix(80))")
                continue
            }
            if let thread = helperConversation(for: m) {
                guard helpersAnnounced[m.url] == nil else { continue }
                helpersAnnounced[m.url] = thread
                offerHelperConversation(thread)
                continue
            }
            // Removed first: if the app dies mid-turn the result is not
            // reported twice.
            try? FileManager.default.removeItem(at: m.url)
            helpersAnnounced[m.url] = nil
            reportFinishedHelper(m.text)
            return true
        }
        return false
    }

    /// The saved conversation a helper result belongs to, when that is not
    /// the one on screen; nil means answer it here.
    ///
    /// The session id in the file is the one this app sent Hermes, derived
    /// from the thread and the brain (`BrainSession.id`), so the thread is
    /// found by deriving again. A session no thread derives to — the brain
    /// has changed since, or the thread was deleted — is answered here, as
    /// every result was before, rather than held for a conversation that
    /// will never be opened.
    func helperConversation(for m: ReminderChannels.Message) -> String? {
        let session = m.sessionID
        guard !session.isEmpty, session != bridge.currentSessionID else { return nil }
        let brain = bridge.brainFingerprint
        if BrainSession.id(thread: conversationID, brain: brain) == session { return nil }
        if let known = helpersAnnounced[m.url] { return known }
        return conversationStore.all().first { BrainSession.id(thread: $0.id, brain: brain) == session }?.id
    }

    /// Say where a finished helper's result is, and offer to go there.
    /// In the chat on screen, as a line of Moe's own; and on the island, when
    /// the island is free, where ▶ opens that conversation and the result is
    /// answered in it.
    private func offerHelperConversation(_ thread: String) {
        let title = conversationTitle(thread)
        Log.write("helper finished for another conversation (\(thread.prefix(8))): offered, not answered here")
        turns.append(Turn(role: .system, text:
            "Something you handed off in “\(title)” has finished. Open that conversation to hear how it went."))
        var handle = NudgeHandle(job: "", jobID: "", loops: [], said: "")
        handle.openThread = thread
        queueReminder("Something you handed off in “\(title)” has finished. Open it to hear how it went.",
                      earlierAt: nil, handle: handle)
    }

    /// What a person would call a thread: its name, or its first words.
    private func conversationTitle(_ thread: String) -> String {
        if let title = conversationStore.titles()[thread], !title.isEmpty { return title }
        let first = conversationStore.load(id: thread)?.turns
            .first { $0.role == .you && !$0.text.isEmpty }?.text ?? ""
        let words = first.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        return words.isEmpty ? "an earlier conversation" : words
    }

    /// Hold it up, never read it out.
    ///
    /// The first version spoke a reminder the moment it landed. That is a
    /// laptop talking unprompted — the thing the nudge design was built to
    /// avoid — and it happened to a person on a call. So a reminder takes the
    /// nudge's path exactly: the notch pulses amber, hovering shows the words,
    /// Play speaks them and tells the brain, × drops them. The one difference
    /// from a nudge is that this is something the person asked for, so it
    /// shows even with "Let Moe get your attention" switched off.
    ///
    /// **Every route to the amber pulse ends here** — the inbox, nudge.json,
    /// and whatever is added next — which is what makes it the place to ask
    /// whether this is a message for a person at all. `nudge.json` used to
    /// set `pendingNudge` itself, a second door with no lock on it.
    ///
    /// `earlierAt` is when a late one was for, and the "Earlier, at 3:00 PM: "
    /// is put on HERE rather than by a caller. A prefix in front of a
    /// start-anchored filter is a way straight past it — and it was one:
    /// seven of the notices in moe.log reached the island reading
    /// "Earlier, at 9:30 AM: ⚠️ Cron 'moe-drain-intents' failed: …".
    ///
    /// `handle` is what the thing on the island can be CHANGED through —
    /// the follow-up it came from, or the cron that scheduled it. It rides
    /// with the words all the way to the brain (`playNudge`,
    /// `dismissNudge`) so that "stop reminding me about that" has something
    /// to act on. Nothing gives a handle to a nudge.json nudge: there is
    /// nothing behind one to close.
    /// A job Moe handed off has finished while the person was doing
    /// something else, and the result is in the inbox (`kind: "turn"`,
    /// written by moe-screen's `completions.py` off the gateway's
    /// `deliver_detached_completion` hook). Not a reminder: nothing here is
    /// worth reading aloud as it stands, and the person did not write it.
    /// Run a turn on it, so Moe says the outcome in its own words — spoken,
    /// as a reminder would be, because they are not looking at the chat.
    ///
    /// Until 2026-09-16 a handed-off job under the Claude Code brain held the
    /// conversation for the whole of its run and was killed at ten minutes;
    /// the person asked for "in the background" and got neither the
    /// background nor the result.
    func reportFinishedHelper(_ result: String) {
        Log.write("helper finished: \(result.prefix(80))")
        // Measured 2026-09-19 (moe.log 02:16–02:18Z): given a result that was
        // only a pointer to a summary file, the model said "Research's done —
        // here's the synthesis" — spoken at once, because sentences are spoken
        // as they stream — then read the file, then spent 78 s WRITING a
        // thirty-page report nobody asked for, then gave the synthesis. The
        // person heard "done", watched it think for two minutes, and heard
        // "done" again. Hence the three rules below: outcome first and only
        // once it is in hand, no side work, short.
        // `.background`: the result is a subagent's words, possibly web content.
        // And in a tag pair, so a reader with only the transcript (the loop
        // sweep, per-turn learning: moe-screen `persons_words`) leaves it out
        // by its shape — never the person's words, whatever it says.
        submit("Something you handed off just finished.", origin: .spoken, starter: .background, outgoing: """
        (Background note, not from the user. A job you handed off earlier has finished; \
        this is its result. If it is only a pointer to a summary file, read that file \
        first, silently. Then tell them the outcome in your own words, in a few \
        sentences — what got done, what did not, and anything they need to decide. Your \
        first sentence must BE the outcome, not an announcement that it is coming: \
        everything you write is spoken as it streams, so "here's the summary" followed \
        by work is heard as done, then silence, then done again. Do no further work: do \
        not write files or reports, do not save anything, do not start the job again. \
        If the result is long, give the gist and offer the rest.)

        <helper-result>
        \(Self.sealed(result, in: "helper-result"))
        </helper-result>
        """)
    }

    /// A reply that promised work and ended the turn gets one continuation.
    ///
    /// On 2026-09-23 at 21:39:09Z the brain closed a turn on "…one sec while
    /// I set the Hanoi to Kunming search for around October 30th." with no
    /// step after it, and the flight search silently stopped. The guard is
    /// here, in the harness, because Moe is provider-agnostic and a rule in
    /// one model's prompt does nothing for the next. `StallGuard` decides
    /// what counts; this decides when: only a turn somebody was owed, with
    /// nothing running, and only once per turn the person started.
    private func continueIfStalled(_ answer: String) {
        guard !stallContinuationSent, !meeting.isRecording,
              let promise = StallGuard.promise(in: answer),
              let id = turns.last(where: { $0.role == .moe })?.id,
              let idx = turns.firstIndex(where: { $0.id == id }) else { return }
        stallContinuationSent = true
        Log.write("stall guard: the reply ended on a promise with nothing running — "
                  + "sending one continuation: \"\(promise.prefix(120))\"")
        // Not `submit`: this is the same turn going on, not a new one. No
        // line of the person's, no "on it", and the promise is not cut off —
        // it is still being said. The words that come stream onto the end of
        // the same answer, so ⏸ ↺ and a barge-in all find the reply they
        // belong to, and what was heard is counted in one text.
        continuationBase = turns[idx].text + "\n\n"
        turns[idx].text = continuationBase ?? turns[idx].text
        turns[idx].isStreaming = true
        streamingTurnID = id
        pendingTools = turns[idx].tools
        pendingLinks = turns[idx].links
        pendingThinking = turns[idx].thinking
        replyAbandoned = false
        awaitingFirstToken = true
        pointParser = PointTagParser()
        mode = .thinking
        statusLine = "thinking"
        workingStep = nil
        workingSince = Date()
        armReply()
        startProgressNarration()
        // …and the voice owes the reply again, as a spoken turn's is owed:
        // pending and live, so the key and a voice over it interrupt it, and
        // what is said next is not dropped as "still working on the last one".
        if turnOrigin == .spoken { voice.replyContinues() }
        // Moe's own words, not the person's — whoever asked the turn.
        bridge.send(StallGuard.note(for: promise), images: [], silent: false,
                    logAs: "(stall guard: carry on)", starter: .background)
    }

    /// A reply is owed to someone who asked. The one place a question is
    /// armed, which is what makes `onReply` exactly "the user asked and got
    /// an answer" — §5. Two callers: `submit`, and the stall guard's
    /// continuation, which is the same question still being answered.
    private func armReply() {
        awaitingReply = true
        replySignal.asked()
    }

    func queueReminder(_ text: String, earlierAt: Date? = nil,
                       handle: NudgeHandle? = nil, origin: InboxGate.Origin = InboxGate.Origin()) {
        // A job's own failure notice is never shown, at any age. Moe is not
        // a technical product and these are not written for a person: an
        // exit code, a stderr tail, a traceback, and a job name nobody
        // outside this repo has heard of. `moe-screen`'s deliver.py drops
        // them before an inbox file is ever written — this is the same rule
        // where the copies it cannot reach pass through: a file written by
        // an older plugin, by `hermes send --to moe`, or before that fix was
        // installed. A guard that only lives upstream is undone by the
        // staleness it guards against. Settings › Background is where a job
        // that needs a look says so, in words.
        guard !MachineryNotice.isJobFailure(text) else {
            Log.write("job failure notice dropped, not shown: \(text.prefix(80))")
            return
        }
        var input = NoticeInput(text: text, at: earlierAt ?? Date())
        if let handle {
            input.job = handle.job
            input.jobID = handle.jobID
            input.loops = handle.loops
            input.said = handle.said
            input.instruction = handle.note
            input.offer = handle.offer
            input.awayCarry = handle.awayCarry
            input.expiredText = handle.expiredText
            input.openThread = handle.openThread
        }
        receiveNotice(input, expiresAt: handle?.expiresAt, origin: origin)
    }

    /// What the thing on the island can be changed through.
    ///
    /// A follow-up Moe raised is `loops` — slugs in `~/.moe/proactive/` that
    /// the `moe_followups` tool closes, snoozes or mutes. A reminder the
    /// person asked for themselves is `jobID` — a Hermes cron, changed with
    /// the `cronjob` tool. They are different stores because they are
    /// different things, and the note below says which one this was, so
    /// "stop reminding me about that" reaches the thing that would say it
    /// again instead of an apology.
    struct NudgeHandle: Equatable {
        let job: String
        let jobID: String
        let loops: [String]
        /// This message's id in `~/.moe/proactive/said.json`, so playing or
        /// dismissing it here also settles the copy that went to a phone.
        let said: String
        /// The writer's own sentence for the brain, when it has one; wins
        /// over everything below. A support ticket's says which command
        /// answers it.
        var note: String = ""
        /// An offer's situation id (`SituationOffer`); "" for a reminder.
        var offer: String = ""
        /// A *While your Mac is off* reminder: the connection's key
        /// (`AwayCarry.Item.id`); "" for anything else.
        var awayCarry: String = ""
        /// A held send (moe-connectors `hold_for_owner`): when it stops
        /// being answerable — a day after it was CREATED, not after it was
        /// read — and what to say instead. Past that it is retired, its
        /// replay instruction with it, and the person is told it expired.
        var expiresAt: Date? = nil
        var expiredText: String = ""
        /// A finished helper's offer: the conversation it was started in,
        /// which ▶ opens so the result is answered there
        /// (`offerHelperConversation`). "" for anything else.
        var openThread: String = ""

        /// Held too long to act on: the island shows `expiredText` instead,
        /// and nothing replays it. Measured on the wall clock, against the
        /// `at` the plugin stamped when it held the send: a clock set
        /// forward retires it early (the safe side), a clock set back keeps
        /// it longer. The cut is a day, so neither matters in practice, and
        /// a monotonic clock does not survive the app restarting anyway.
        func expired(now: Date = Date()) -> Bool {
            guard let expiresAt, !expiredText.isEmpty else { return false }
            return now >= expiresAt
        }

        /// How long a held send stays answerable, from when it was made.
        static let heldLifetime: TimeInterval = 24 * 3600

        /// The handle for an inbox message, carrying a held send's expiry.
        static func forInbox(_ m: ReminderChannels.Message) -> NudgeHandle {
            var h = NudgeHandle(job: m.job, jobID: m.jobID, loops: m.loops, said: m.said,
                                note: m.instruction, offer: m.offer)
            if !m.expiredText.isEmpty {
                h.expiresAt = m.at.addingTimeInterval(heldLifetime)
                h.expiredText = m.expiredText
            }
            return h
        }

        /// One of Moe's own background jobs, rather than a reminder the
        /// person set. Every job `configure-hermes.py` installs is named
        /// `moe-…`; a reminder made from a request is named from the
        /// request. The rule is spelled the same way in `deliver.is_moe_job`
        /// — see the reasoning there, and change both together.
        var isMoeJob: Bool { job.lowercased().hasPrefix("moe-") }

        /// The sentence that tells the brain what it may do about this.
        var instruction: String {
            if !note.isEmpty { return note }
            if !loops.isEmpty {
                return "If they answer it — including with a bare \"done\", \"not now\" "
                    + "or \"stop reminding me\" — act on it with the moe_followups tool: "
                    + "follow-up \(loops.joined(separator: ", ")). close when it is dealt "
                    + "with, snooze when they want it later, mute when they ask you to "
                    + "stop bringing it up."
            }
            if !jobID.isEmpty && !isMoeJob {
                return "This was the scheduled reminder \(job.isEmpty ? "?" : job), which "
                    + "they set up themselves. If they ask you to stop it or move it, use "
                    + "the cronjob tool with job_id \(jobID) — pause to stop it for now, "
                    + "remove to be rid of it, update with a new schedule to move it."
            }
            if !job.isEmpty {
                // Moe's own pass, and the cronjob tool is the WRONG answer:
                // removing moe-proactive deletes every follow-up because one
                // nudge was unwelcome, and pausing moe-calendar-heads-up
                // leaves Settings still promising a heads-up that never comes.
                return "This came from Moe's own background pass, not a reminder they set, "
                    + "and there is nothing specific to stop. Do not touch any cron job "
                    + "over it. If they want this kind of message to stop, that is a "
                    + "switch in Settings › Background — say so; if they mean one "
                    + "particular thing, say you cannot tell which and ask."
            }
            return "There is no handle on this one, so if they ask you to stop it, say "
                + "plainly that you cannot tell which reminder it was and ask which they mean."
        }
    }

    /// You tapped the glow: say it, then clear it.
    ///
    /// The note also goes to Claude as a silent turn. Without that, Moe speaks
    /// something the model has never seen — so "what did he say?" came back as
    /// "I don't have anything queued up", which is worse than not telling you
    /// at all.
    ///
    /// It carries the handle as well as the words, and that is the island's
    /// half of the same fix `moe-home/hermes-plugins/moe-screen/followups.py`
    /// makes on Telegram: measured on 2026-09-04, "ok dont remond me anymore
    /// about that" came back as "which reminder do you mean?" — the model had
    /// the sentence and no way to change what produced it.
    /// A held send that has been on the island past its day: take it down,
    /// with its replay instruction, and say it expired and nothing was sent.
    /// `sayWhy` false is for a dismissal: the person was already waving it
    /// away, so it simply goes — one action, not a second card to dismiss.
    @discardableResult
    func retireExpiredNudge(now: Date = Date(), sayWhy: Bool = true) -> Bool {
        guard let handle = pendingNudgeHandle, handle.expired(now: now) else { return false }
        Log.write("reminder: a held send on the island expired unanswered")
        pendingNudge = nil
        pendingNudgeWhen = nil
        pendingNudgeHandle = nil
        if sayWhy {
            queueReminder(handle.expiredText, earlierAt: nil, handle: nil,
                          origin: InboxGate.Origin(consequence: true))
        } else {
            onWantsIsland?(false)
        }
        return true
    }

    func playNudge() {
        if retireExpiredNudge() { return }
        guard let words = pendingNudge else { return }
        let handle = pendingNudgeHandle
        // Out loud the timestamp belongs in front of the sentence, which is
        // where it was until the card learned to caption it.
        let text = pendingNudgeWhen.map { "\($0): \(words)" } ?? words
        pendingNudge = nil
        pendingNudgeWhen = nil
        pendingNudgeHandle = nil
        // A finished helper's offer: ▶ is "open it". The conversation it
        // belongs to comes on screen, and the result is answered there —
        // nothing here is read out or told to the brain of this one.
        if let thread = handle?.openThread, !thread.isEmpty {
            currentOffer = nil
            offerCard = .none
            openConversation(id: thread)
            drainInbox()
            return
        }
        try? FileManager.default.removeItem(at: Paths.home.appendingPathComponent("nudge.json"))
        turns.append(Turn(role: .moe, text: text))
        // The same message may also be sitting on the person's phone. Saying
        // it here settles it there too, so tonight's unrelated Telegram
        // message does not arrive with this morning's nudge attached.
        ReminderChannels.markAnsweredOnScreen(handle?.said ?? "")
        let note = handleNote(handle)
        bridge.send("""
        (Background note, not from the user. You just told them out loud: \"\(text)\" \
        Remember it — they may well ask you to follow up on it. \
        \(note.inline) Do not reply to this message.)
        """ + (note.after.isEmpty ? "" : "\n\n" + note.after), silent: true, starter: .background)
        currentOffer = nil
        offerCard = .none
        voice.speak(text)
    }

    /// Where a reply's voice is, for its ⏸ ▶ ↺.
    func voiceState(of id: UUID) -> ReplyVoice {
        guard voicedTurnID == id else { return .silent }
        return replyHeldByKey ? .paused : .playing
    }

    /// Whether this answer offers ▶ — the chat's rule, and now the island's
    /// (`ConversationControls.canPlay`), so the two can never disagree.
    func canPlayReply(_ turn: Turn) -> Bool {
        ConversationControls.canPlay(
            isMoe: turn.role == .moe, streaming: turn.isStreaming,
            hasText: !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            voiced: voiceState(of: turn.id) != .silent, thinking: mode == .thinking)
    }

    /// The one button on a reply: ▶ plays it, ⏸ holds it, ▶ again carries
    /// on from where it was held — never from the top; that is ↺.
    func playPauseReply(_ id: UUID) {
        switch voiceState(of: id) {
        case .silent: playReply(id)
        case .playing: pauseReply()
        case .paused: resumeReply()
        }
    }

    /// ⏸ — hold the reply where it is. The sound stops at the sample, and
    /// ▶ carries on from there (`VoiceMachine.Event.pauseReply`).
    func pauseReply() { voice.pauseReply(true) }

    /// ▶ on a paused reply: on from where it stopped.
    func resumeReply() { voice.pauseReply(false) }

    /// ↺ — the reply that is out now, again from the top. Not while it is
    /// still being written: the top is all there is to restart then.
    func restartReply() {
        guard let id = voicedTurnID, !awaitingReply else { return }
        if replyHeldByKey { voice.pauseReply(false) }   // let go of the hold first
        replayingTurnID = nil
        playReply(id)
    }

    /// ▶ on a reply in the chat: read it out, from the top, in Moe's voice.
    ///
    /// The owner, 2026-09-23: "let's say you were texting it … there should
    /// be a way to play that message that he sent to you so he can talk back
    /// to you." It is spoken as a reply is — sentence by sentence, each
    /// carrying its offset — so a tap of the key pauses it and the next tap
    /// carries on from the sentence it was in (`resumeSpokenReply`).
    ///
    /// Pressed again while it plays, it stops. Never while a turn is in
    /// flight: that reply owns the voice, and ▶ is hidden until it is done.
    func playReply(_ id: UUID) {
        guard !awaitingReply,
              let turn = turns.first(where: { $0.id == id }),
              turn.role == .moe, !turn.isStreaming,
              !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // Whatever was being said gives way to what was asked for.
        voice.stopSpeaking()
        replayingTurnID = id
        spokenUpTo = ""
        speakToEnd(of: turn.text)
    }

    /// You tapped ×: it is not spoken, and it is not lost either.
    ///
    /// The brain is told, quietly. Dismissing is "not now", not "never" —
    /// and the person who dismisses a pulse and then says "stop reminding me
    /// about that" is the exact case this whole change is about. Without
    /// this line the words they are referring to were never anywhere the
    /// model could see them.
    /// Tests only: where a dismissal's background note goes instead of the
    /// brain, so a test can read what the brain would be told without a
    /// real bridge (and without reaching a real gateway).
    var dismissalNoteForTests: ((String) -> Void)?

    func dismissNudge() {
        // An expired held send is retired first, and in the same action: the
        // brain never gets its replay instruction once it can no longer be
        // answered, and there is no second card to wave away.
        if retireExpiredNudge(sayWhy: false) { return }
        if let text = pendingNudge, pendingNudgeHandle?.openThread.isEmpty ?? true {
            let handle = pendingNudgeHandle
            ReminderChannels.markAnsweredOnScreen(handle?.said ?? "")
            // Waving away a held send is a no: its replay instruction ("call
            // … if they say to send it") is not passed on, and the brain is
            // told it is not to be sent.
            let note = (handle?.expiredText.isEmpty ?? true)
                ? handleNote(handle)
                : (inline: "It was a send held for their yes; waving it away means it is not sent — do not send it.",
                   after: "")
            let message = """
            (Background note, not from the user. You put this on the island and they \
            waved it away without listening: \"\(text)\" They may say something about \
            it next. \(note.inline) Do not reply to this message.)
            """ + (note.after.isEmpty ? "" : "\n\n" + note.after)
            if let hook = dismissalNoteForTests {
                hook(message)
            } else {
                bridge.send(message, silent: true, starter: .background)
            }
        }
        pendingNudge = nil
        pendingNudgeWhen = nil
        pendingNudgeHandle = nil
        currentOffer = nil
        offerCard = .none
        try? FileManager.default.removeItem(at: Paths.home.appendingPathComponent("nudge.json"))
        onWantsIsland?(false)
    }

    /// You tapped Reply on the card and typed: what you wrote is your answer
    /// to what was on it.
    ///
    /// The third thing a person does with a pulse, after playing it and
    /// waving it away — and the one the owner reached for on 2026-09-06,
    /// hovering the island and typing "stop reminding me about that" into
    /// the ask field, where the words arrived with no card behind them. This
    /// is the Mac's version of what `followups.py` attaches to a Telegram
    /// reply: the card's words and its handle go in front of the answer, in
    /// the same turn, so "done", "not now" and "stop" reach the thing that
    /// would say it again. The card's words are put in the thread as Moe's,
    /// so the exchange reads whole, and the copy that went to a phone is
    /// settled exactly as Play and Dismiss settle it.
    func replyToNudge(_ text: String, shownAs: String? = nil) {
        if retireExpiredNudge() { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let words = pendingNudge, !trimmed.isEmpty else { return }
        guard !awaitingReply else {
            // The card stays: `submit` would drop this turn, and a dropped
            // answer must not take the thing it was answering with it.
            turns.append(Turn(role: .system, text: "Still working on the last one — one sec."))
            return
        }
        let handle = pendingNudgeHandle
        let note = handleNote(handle)
        let shown = pendingNudgeWhen.map { "\($0): \(words)" } ?? words
        currentOffer = nil
        offerCard = .none
        pendingNudge = nil
        pendingNudgeWhen = nil
        pendingNudgeHandle = nil
        try? FileManager.default.removeItem(at: Paths.home.appendingPathComponent("nudge.json"))
        ReminderChannels.markAnsweredOnScreen(handle?.said ?? "")
        turns.append(Turn(role: .moe, text: shownAs ?? shown))
        nudgeReplyNote = """
        (Background note, not from the user. You put this on the island: \"\(shown)\" \
        They read it and typed the message below as their answer to it. \
        \(note.inline) Act on their answer, then reply briefly.)
        """ + (note.after.isEmpty ? "" : "\n\n" + note.after)
        submit(trimmed, origin: .typed, starter: .person)
        // Consumed by `submit` on every path that reaches the brain; cleared
        // here for the ones that do not (a meeting phrase, say), so it can
        // never ride in front of an unrelated question later.
        nudgeReplyNote = nil
    }

    func startUp() {
        // The app takes this lock before it builds a Conductor; this is for
        // every other way of reaching here (a headless mode, a test) so a
        // second process never opens the mic or the brain beside the app.
        guard InstanceLock.acquire() else {
            let who = InstanceLock.holderDescription
            Log.write("not starting the brain or the mic: \(who) already runs Moe")
            statusLine = "Memoe is already running"
            return
        }
        lastStartAt = Date()
        watchForNudges()
        loadNotices()
        watchForInbox()
        watchForNoted()
        watchForFirstReminderChannel()
        startPresence()
        watchForLock()
        watchForConfirm()
        watchForOpenSettings()
        watchForLocation()
        watchForSettings()
        startMeetingWatcher()
        // Memoe's cloud, when this build has one: the sync, Away's starter,
        // a problem report still owed, the away machine's brain, and the
        // incident reporter (`CloudLink.launched`). Nothing in a build
        // without one.
        cloud.launched()
        bridge.start()
        bridge.warmUp()
        // Warm the CoreML models in the background — the vocoder alone takes
        // ~6s to load cold, and paying that on the first "Hey Moe" would make
        // Moe feel broken.
        Task {
            await voice.loadModels()
            voiceReady = voice.isReady
        }
        if config.wakeWordEnabled { voice.setWakeWord(true) }
    }

    func shutDown() {
        shuttingDown = true
        grantWatch.cancelAll("the app is quitting")
        // Quitting is `away` too (S3): the machine must not be told
        // `mac-here` about a Mac whose app is gone. Bounded wait — a quit
        // must not hang on the edge.
        presenceWatcher?.stop()
        cloud.quitting()
        saveConversation(flush: true)
        // Close the WAVs cleanly (headers patched); no notes on quit.
        stopMeetingWatchers()
        watcher?.stop()
        offerTimer?.invalidate(); offerTimer = nil
        meetingSession?.captures = meetingCaptures
        meetingSession?.abandon()
        meetingSession = nil
        voice.detachExternalInput()
        voice.shutDown()
        bridge.stop()
    }

    // MARK: - Commands

    /// Key down: start recording. Key up: transcribe and send.
    ///
    /// This replaces the wake word, the silence timer and the end-of-utterance
    /// model with the one signal that is never ambiguous — whether you are
    /// holding the key.
    func holdBegan() {
        let atRest = Self.doubleTapListensHandsFree(
            voice: voice.state, mode: mode, awaitingReply: awaitingReply, acting: acting,
            replyHeld: replyHeldByKey, dictating: dictation != .off || dictationPending)
        pressFoundMoeAtRest = atRest && !meetingOwnsMic
            && !Self.stopStillSettling(since: stoppedAt, now: Date())
        if meetingOwnsMic {
            onWantsIsland?(true)
            // The mic is the meeting's. A tap of the key is "note this"; a
            // hold is a whisper to Moe — the meeting's own 16 kHz buffers
            // feed the recogniser (no second engine on the input), and the
            // reply is text on the island, never spoken. Capture starts at
            // once so the first words are not lost; a tap cancels it.
            holdBeganAt = Date()
            guard meeting.isRecording, let session = meetingSession else { return }
            partial = ""
            meetingWhisper = true
            voice.attachExternalInput()
            let voice = self.voice
            session.recorder.forwardMic { buffer in voice.feedExternalInput(buffer) }
            Task { await voice.beginHold() }
            return
        }
        Self.primeAutomationOnce()
        if atRest {
            // From rest a press is most often the first tap of a double-tap,
            // and lighting the island as listening for it — then putting it
            // out — was the flash that read as "it heard me" (2026-10-13).
            // Wait for the key to say it is a hold. Over a reply or a turn
            // the press acts at once: it is the pause button.
            unconfirmedPressAt = Date()
            voice.warmHold()
            return
        }
        beginListening(since: nil)
    }

    /// Light the island as listening and start the hold. `since`: the press
    /// went down earlier than now, and the capture reaches back to it.
    private func beginListening(since pressedAt: Date?) {
        onWantsIsland?(true)
        partial = ""
        mode = .listening
        let earlier = pressedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        Task { await voice.beginHold(earlierBy: earlier) }
    }

    /// The key has been down for a tap's length (`PushToTalk.onHoldConfirmed`):
    /// a press from rest is a hold, so now it is shown and heard.
    func holdConfirmed() {
        guard let at = unconfirmedPressAt else { return }
        unconfirmedPressAt = nil
        beginListening(since: at)
    }

    /// A press from rest that never became a hold: nothing was shown and
    /// nothing opened, so there is nothing to take down but the warm graph.
    private func dropUnconfirmedPress() -> Bool {
        guard unconfirmedPressAt != nil else { return false }
        unconfirmedPressAt = nil
        voice.coolHold()
        return true
    }

    /// - Parameter tap: the key says the press was a tap (`PushToTalk.onTap`).
    ///   Its release arrives after the double-tap window, so no clock read
    ///   here can tell a tap from a hold any more.
    func holdEnded(tap tapped: Bool = false) {
        if let began = holdBeganAt {
            holdBeganAt = nil
            let tap = tapped || Date().timeIntervalSince(began) < 0.35
            guard meetingWhisper else {
                if tap { addMeetingBookmark() } else { statusLine = Self.meetingMicHint }
                return
            }
            meetingSession?.recorder.forwardMic(nil)
            meetingWhisper = false
            if tap {
                voice.cancelHold()
                if mode == .listening { mode = .idle }
                addMeetingBookmark()
            } else {
                Task { await voice.endHold() }
            }
            return
        }
        if dropUnconfirmedPress() {
            Log.write("hold: a tap from rest — nothing opened")
            return
        }
        screen.pressEnded()
        Task { await voice.endHold(tap: tapped) }
    }

    /// The key went down as part of a shortcut — fn+Delete, right ⌘+Tab —
    /// not to talk (`PushToTalk.onCancel`). Take down what `holdBegan`
    /// started, silently: no turn, no screenshot, no meeting bookmark, and
    /// a reply the press stopped carries on.
    func holdCancelled() {
        if holdBeganAt != nil {
            holdBeganAt = nil
            guard meetingWhisper else { return }
            meetingSession?.recorder.forwardMic(nil)
            meetingWhisper = false
            voice.abortHold()
            if mode == .listening { mode = .idle }
            return
        }
        if dropUnconfirmedPress() { return }
        screen.discard()
        partial = ""
        voice.abortHold()
        // `holdBegan` lit the island and said `.listening` before the voice
        // had moved. If the voice never got as far as capturing (still
        // asking for the microphone, still loading), no state change will
        // come to undo that, so undo it here.
        if mode == .listening {
            switch voice.state {
            case .off, .standby, .suspended:
                mode = awaitingReply ? .thinking : .idle
                if !voice.inConversation { onWantsIsland?(false) }
            default:
                break
            }
        }
    }

    /// What a double-tap of the talk key means, from how Moe was when its
    /// first tap went down: from true rest — the voice off or in standby,
    /// nothing owed, held or being dictated — it listens hands-free; from
    /// anything else it stops everything.
    ///
    /// It used to latch from any `.listening`, and the voice is "listening"
    /// right after a "Hey Moe" and in the follow-up window. On the owner's
    /// Mac 45 of 76 hands-free latches started from those two states, and in
    /// 30 of them stray words reached the brain within 3 s: the double-tap
    /// meant stop, latched instead, and the third tap sent (2026-10-13
    /// 13:40:13). Read off the voice, not `mode`: `mode` is what the island
    /// shows, and a press can change it before the double-tap is decided.
    nonisolated static func doubleTapListensHandsFree(voice: VoiceEngine.State, mode: Mode,
                                                      awaitingReply: Bool, acting: Bool,
                                                      replyHeld: Bool, dictating: Bool) -> Bool {
        guard !awaitingReply, !acting, !replyHeld, !dictating, mode == .idle else { return false }
        switch voice {
        case .off, .standby: return true
        default: return false
        }
    }

    /// How long after a double-tap stop another double-tap still means
    /// "stop", never "listen hands-free" — exactly as long as "Stopped" is
    /// on the island.
    ///
    /// Measured on 2026-10-05 19:03:15: the stop worked, but nothing on
    /// screen said so beyond the island going away, so the owner kept
    /// tapping, and a double-tap a second later latched the microphone.
    /// That was 2 s; it cut both ways, because a real "listen to me" a
    /// moment after a stop stopped again. The stop now says so — a sound and
    /// the word — and a double-tap is only a latch from true rest, so the
    /// window need only cover the confirmation itself.
    static let stopSettleSeconds: TimeInterval = stoppedShownSeconds

    /// How long "Stopped" stays in the island's ear.
    static let stoppedShownSeconds: TimeInterval = 0.8

    nonisolated static func stopStillSettling(since stoppedAt: Date?, now: Date) -> Bool {
        guard let stoppedAt else { return false }
        let elapsed = now.timeIntervalSince(stoppedAt)
        return elapsed >= 0 && elapsed < stopSettleSeconds
    }

    /// Asked by the key at a double-tap (`PushToTalk.talkLatchAllowed`).
    /// The press must have found Moe at rest, and must still be the one
    /// standing — not yet shown (`unconfirmedPressAt`) or already listening.
    /// A hold the voice already gave up on has nothing to latch.
    func talkLatchAllowed() -> Bool {
        pressFoundMoeAtRest && holdBeganAt == nil && !talkLatched
            && (unconfirmedPressAt != nil || mode == .listening)
    }

    /// Double-tapped with Moe idle: the recording the first tap started
    /// carries on with nothing held, until a tap sends it or Esc drops it.
    /// Never on silence — a pause to think is not the end of the turn.
    func talkLatchBegan() {
        talkLatched = true
        Log.write("hold: latched hands-free")
        // The first tap was never shown; this is where listening starts,
        // with the capture reaching back to when it went down.
        if let at = unconfirmedPressAt {
            unconfirmedPressAt = nil
            beginListening(since: at)
        }
    }

    /// A tap (send), Esc or the lock (drop). The release or cancel that
    /// follows does the rest, on the same path as a held press.
    func talkLatchEnded(_ reason: TalkChordMachine.UnlatchReason) {
        guard talkLatched else { return }
        talkLatched = false
        Log.write("hold: unlatched (\(reason.rawValue))")
        // A tap straight after the latch: the cancel that follows takes the
        // recording down; say it stopped, the way a double-tap stop does.
        if reason == .undo { confirmStopped() }
    }

    /// The hands-free turn ended without the key: forget the latch here and
    /// tell the key, so its next tap is a fresh press.
    private func abandonTalkLatch() {
        guard talkLatched else { return }
        talkLatched = false
        Log.write("hold: hands-free ended without the key")
        onTalkLatchAbandoned?()
    }

    static let meetingMicHint = "Recording — tap the key to bookmark, hold it and whisper to ask Moe; click the island to type."


    // MARK: - Dictation

    /// The key you hold to dictate, or `.off` when dictation is switched off.
    ///
    /// Also `.off` while the whole feature is hidden (`Features.dictation`,
    /// docs/DEFAULTS.md row 4), whatever config.json says: this is the one
    /// value `PushToTalk` is armed with, so gating here means no chord is
    /// ever watched for and nothing downstream can start a dictation.
    var effectiveDictationKey: DictationKey { Self.effectiveDictationKey(config) }

    /// The same, for any config — so a test can hand it an old config.json
    /// that still says `dictationEnabled: true` without starting a conductor.
    ///
    /// And `.off` when the dictation key is the very key you hold to talk
    /// (docs/DEFAULTS.md row 8): one key cannot mean both "do what I said"
    /// and "type what I said", and talking is the one Moe is for. While
    /// dictation is hidden there is nothing to collide with.
    nonisolated static func effectiveDictationKey(_ config: Config) -> DictationKey {
        guard Features.dictation && config.dictationEnabled else { return .off }
        return config.talkKey.collides(with: config.dictationKey) ? .off : config.dictationKey
    }

    /// Say so in the log when a key choice just switched dictation off.
    private func noteTalkKeyCollision() {
        guard Features.dictation, config.dictationEnabled,
              config.talkKey.collides(with: config.dictationKey) else { return }
        Log.write("talk key \(config.talkKey.rawValue) is also the dictation key — "
                  + "dictation is off until one of them changes")
    }

    /// Dictation key down: record, showing a live transcript on the island.
    /// Nothing here opens a conversation or reaches the brain.
    func dictationBegan() {
        // `.typing` is only the island lingering after a finished paste; the
        // engine is already back at rest, so a new hold may start over it.
        guard dictation == .off || dictation == .typing, !dictationPending else { return }
        if meetingOwnsMic {
            statusLine = "Dictation is off while a meeting is recorded — the mic is the meeting's."
            onWantsIsland?(true)
            return
        }
        dictationSettleTask?.cancel(); dictationSettleTask = nil
        Log.write("dictation: press")
        // Stop talking first, and reflect it now — the voice's own state
        // change goes through `onStateChange` regardless, but the island
        // should not show "speaking" under the dictation panel meanwhile.
        voice.stopSpeaking()
        if mode == .speaking { mode = .idle }
        partial = ""
        dictationPartial = ""
        dictationFrontApp = NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.bundleIdentifier.map { PolishPrompt.FrontApp(bundleID: $0, name: app.localizedName ?? $0) }
        }
        // Only when the rewrite is on at all: with polish off there is
        // nobody to show it to, and reading it would be a privacy cost for
        // no benefit whatsoever.
        dictationBefore = (config.dictationCursorContext && config.dictationPolish)
            ? CursorContext.tidy(CursorContext.textBeforeCursor()) : nil
        // The names in front of the speaker, for this utterance only. Read
        // here rather than at release for the same two reasons as the app and
        // the prefix: the window may have changed by then, and an
        // Accessibility walk belongs anywhere except the path between letting
        // go of the key and seeing text. Always set — an empty list when the
        // setting is off — so the last window's words can never survive into
        // the next dictation.
        LiveVocabulary.shared.set(config.dictationScreenVocabulary
            ? ContextTerms.extract(ScreenText.sources(), common: .system) : [])
        Task { await voice.beginDictation() }

        dictationPending = true
        dictationRevealTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.dictationRevealDelay ?? 0)
            guard !Task.isCancelled, let self, self.dictationPending else { return }
            self.revealDictation()
        }
    }

    /// The press outlived the reveal window, so it is a dictation and not a
    /// shortcut: show it, and say so. Glow only — dictation never opens the
    /// panel. The lavender halo around the notch is the whole cue; a strip
    /// with a live transcript pulled the eye off the field being typed
    /// into. The chime lands here rather than on the key for the same
    /// reason the glow does: a ⌘C must stay silent.
    private func revealDictation() {
        dictationPending = false
        dictation = .listening
        if config.dictationSounds { chime.play(.start) }
    }

    /// Double-tapped: the recording that is running stays on with nothing
    /// held. Reveal it now if the second tap was inside the reveal window.
    func dictationLatchBegan() {
        guard dictation == .listening || dictationPending else { return }
        if dictationPending { clearDictationPending(); revealDictation() }
        dictationLatched = true
        Log.write("dictation: latched")
    }

    /// Ended by a tap, Esc, the 3-minute limit, or the screen locking. The
    /// release or cancel that follows does the rest.
    func dictationLatchEnded(_ reason: DictationChordMachine.UnlatchReason) {
        guard dictationLatched else { return }
        dictationLatched = false
        Log.write("dictation: unlatched (\(reason.rawValue))")
    }

    private func clearDictationPending() {
        dictationRevealTask?.cancel(); dictationRevealTask = nil
        dictationPending = false
    }

    /// Key up: transcribe, tidy, type. The island says "typing…" for a beat
    /// so the paste is seen to come from Moe, then goes quiet.
    func dictationEnded() {
        let wasPending = dictationPending
        guard dictation == .listening || wasPending else { return }
        clearDictationPending()
        dictationLatched = false
        // A release inside the reveal window is a tap shorter than any word;
        // read it silently rather than flashing "Reading…" for nothing.
        if !wasPending {
            dictation = .transcribing
            if config.dictationSounds { chime.play(.stop) }
        }
        let app = dictationFrontApp
        let before = dictationBefore
        let polishOn = config.dictationPolish
        Task {
            // Where the time between letting go of the key and seeing text
            // actually goes. Measured on the real path because the parts move
            // independently: the engines are fast and get faster, the polish
            // is a network round trip to whatever model is configured, and
            // guessing which dominates is how the last optimisation attempt
            // went wrong. Durations only — never a word of what was said.
            let releasedAt = Date()
            func since(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

            let raw = await voice.endDictation()
            let heardMs = since(releasedAt)
            var text = TranscriptCleaner.clean(raw)
            // Never the text itself: a transcript is whatever you were typing.
            // Case profile only (never the words): settles "it came out in
            // caps" in one glance at the log.
            let letters = text.filter(\.isLetter)
            let upper = letters.isEmpty ? 0 : 100 * letters.filter(\.isUppercase).count / letters.count
            Log.write("dictation: release, \(text.count) chars, \(upper)% upper")
            guard !text.isEmpty else {
                LiveVocabulary.shared.clear()
                dictationPartial = ""
                dictation = .off
                return
            }
            // Second pass through the brain, still under the glow: the
            // island stays "transcribing" until there is something to
            // paste. Only when the brain is there to ask — a gateway that
            // is down would cost the whole budget for nothing.
            var polished = false
            let polishStart = Date()
            if polishOn {
                // One prompt, whichever tier answers: a difference between
                // tiers should be the model, never the question.
                let prompt = PolishPrompt.assemble(transcript: text, app: app, before: before,
                                                   vocabulary: Self.vocabularyTerms(),
                                                   onScreen: LiveVocabulary.shared.current())
                let preferred = PolishTier(rawValue: config.dictationPolishTier)
                if let better = await polishRouter.polish(
                        text, prompt: prompt,
                        budget: Self.polishBudget(for: text, base: config.dictationPolishBudget),
                        preferred: preferred, brainReachable: connected) {
                    text = better
                    polished = true
                }
            }
            let polishMs = polishOn && connected ? since(polishStart) : 0
            dictation = .typing
            switch TextInserter.insert(text) {
            case .pasted:
                // Come back in a few seconds to see whether a word was
                // typed over; see CorrectionWatcher.
                if config.dictationLearnCorrections {
                    CorrectionWatcher.watch(pasted: text, frontApp: app?.bundleID)
                }
                remember(text, app: app, polished: polished)
            case .noAccessibility:
                statusLine = "copied — press ⌘V to paste (Accessibility needed to type for you)"
            case .noTarget:
                statusLine = "Copied — nothing to paste into"
                remember(text, app: app, polished: polished)
            }
            // The one line to read when dictation feels slow. "heard" is the
            // engines (decode plus any vocabulary boost); "polish" is the
            // round trip, 0 when it was off or skipped; the total is what the
            // user actually waited after letting go of the key.
            // The utterance is over: the screen words go with it.
            LiveVocabulary.shared.clear()
            let tier = await polishRouter.lastUsed
            Log.write("dictation: \(since(releasedAt)) ms key-up to paste "
                    + "(heard \(heardMs), polish \(polishMs) via \(tier.rawValue)"
                    + "\(polished ? "" : ", unused"))")
            dictationSettleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self, self.dictation == .typing else { return }
                self.dictationPartial = ""
                self.dictation = .off
            }
        }
    }

    /// The text reached the cursor (or the clipboard): keep it, if asked
    /// to. Never the text in the log — only that a line was written.
    private func remember(_ text: String, app: PolishPrompt.FrontApp?, polished: Bool) {
        guard config.dictationHistory else { return }
        let entry = DictationHistory.Entry(appBundleID: app?.bundleID, appName: app?.name,
                                           polished: polished, text: text)
        do { try history.append(entry) }
        catch { Log.write("dictation: history append failed: \(error.localizedDescription)") }
    }

    /// Everything kept so far, newest first. For Settings.
    func dictationHistoryEntries(matching query: String) -> [DictationHistory.Entry] {
        history.search(query)
    }

    func deleteDictationHistory(id: String) {
        try? history.delete(id: id)
    }

    func clearDictationHistory() {
        try? history.clear()
    }

    /// Type an earlier dictation at the cursor again.
    func pasteAgain(_ text: String) {
        switch TextInserter.insert(text) {
        case .pasted: break
        case .noAccessibility: statusLine = "copied — press ⌘V to paste (Accessibility needed to type for you)"
        case .noTarget: statusLine = "Copied — nothing to paste into"
        }
    }

    /// Thrown away from the island's own ✕ rather than from the keyboard.
    ///
    /// Separate from `dictationCancelled()` because that one is called *by*
    /// the key owner, which therefore already knows the hold is over. This is
    /// called while the key is very likely still down, so the owner has to be
    /// told to forget it — otherwise the eventual release arrives against a
    /// dictation that no longer exists.
    func cancelDictationFromIsland() {
        guard dictation != .off || dictationPending else { return }
        dictationCancelled()
        onDictationAbandoned?()
    }

    /// The held key was a shortcut after all. Nothing is typed.
    func dictationCancelled() {
        guard dictation == .listening || dictationPending else { return }
        let wasPending = dictationPending
        clearDictationPending()
        dictationLatched = false
        Log.write("dictation: cancelled")
        if !wasPending, config.dictationSounds { chime.play(.cancel) }
        voice.cancelDictation()
        LiveVocabulary.shared.clear()
        dictationPartial = ""
        dictation = .off
    }

    func setDictationEnabled(_ on: Bool) {
        config = Config.update { $0.dictationEnabled = on }
        onDictationKeyChanged?(effectiveDictationKey)
    }

    func setDictationKey(_ key: DictationKey) {
        config = Config.update { $0.dictationKey = key }
        noteTalkKeyCollision()
        onDictationKeyChanged?(effectiveDictationKey)
    }

    /// The key you hold to talk. Applies at once: PushToTalk reads it on
    /// every flag change. Dictation is told too, since a key it shared with
    /// talking takes it off (and a key that moves away gives it back).
    func setTalkKey(_ key: TalkKey) {
        config = Config.update { $0.talkKey = key }
        onTalkKeyChanged?(key)
        noteTalkKeyCollision()
        onDictationKeyChanged?(effectiveDictationKey)
    }

    func setDictationPolish(_ on: Bool) {
        config = Config.update { $0.dictationPolish = on }
        if on, connected { polisher.warmUp() }
    }

    func setDictationPolishBudget(_ seconds: Double) {
        config = Config.update { $0.dictationPolishBudget = seconds }
    }

    func setDictationContactsNames(_ on: Bool) {
        config = Config.update { $0.dictationContactsNames = on }
        // Switching on is the one moment a Contacts prompt is welcome:
        // the user just asked for it. Off deletes the cache.
        if on { ContactsVocabulary.refreshNow() } else { ContactsVocabulary.sync(enabled: false) }
    }

    /// Tick or untick one chat platform for reminders. Bare platform names
    /// only — the moe-screen plugin that reads this drops anything else,
    /// so a chat id can never be smuggled in through the config file.
    func setReminderChannel(_ name: String, on: Bool) {
        let clean = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return }
        config = Config.update {
            var list = $0.reminderChannels.filter { $0 != clean }
            if on { list.append(clean) }
            $0.reminderChannels = list
            // The person has chosen: Moe never ticks a chat by itself after
            // this, so an untick stays an untick (docs/DEFAULTS.md row 26).
            $0.reminderChannelsAutoPicked = true
        }
        Log.write("reminders → \(clean): \(on ? "on" : "off")")
    }

    /// docs/DEFAULTS.md row 26: the first chat app that becomes ready is
    /// ticked for reminders without being asked — once, into an empty list
    /// (`ReminderChannels.autoPick` has the rules). Given a list already
    /// fetched, so the Background pane's own refresh costs nothing extra.
    func adoptFirstReminderChannel(from platforms: [ReminderChannels.Platform]) {
        guard ReminderChannels.autoPick(current: config.reminderChannels,
                                        alreadyPicked: config.reminderChannelsAutoPicked,
                                        platforms: platforms) != nil else { return }
        var picked: String?
        config = Config.update { picked = ReminderChannels.adopt(platforms, into: &$0) }
        if let picked {
            Log.write("reminders → \(picked): on (the first chat app ready — ticked by Moe, once)")
        }
    }

    private var firstReminderChannelTimer: Timer?
    private var firstReminderChannelLooks = 0

    /// The same pick without the pane open: a person connects Telegram,
    /// messages Moe there, and never visits Settings. Every ten minutes,
    /// until a chat has been picked (by Moe or the person), until two chat
    /// apps were ready at one look (Moe never guesses between them), or for
    /// a day at most (`ReminderChannels.watchStep`) — after that the timer
    /// stops and `hermes send --list` is not asked from here again. A chat
    /// app connected in Settings looks at once (`chatAppConnected`); the
    /// timer is only the fallback.
    private func watchForFirstReminderChannel() {
        firstReminderChannelTimer?.invalidate()
        firstReminderChannelTimer = nil
        firstReminderChannelLooks = 0
        guard !config.reminderChannelsAutoPicked else { return }
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.lookForFirstReminderChannel() }
        }
        RunLoop.main.add(t, forMode: .common)
        firstReminderChannelTimer = t
    }

    /// One look: pick if there is exactly one ready chat app, then decide
    /// whether to look again.
    private func lookForFirstReminderChannel() async {
        firstReminderChannelLooks += 1
        var platforms: [ReminderChannels.Platform]?
        if !config.reminderChannelsAutoPicked {
            platforms = await ScriptRunner.offMain({ ReminderChannels.available() })
            if let platforms { adoptFirstReminderChannel(from: platforms) }
        }
        switch ReminderChannels.watchStep(alreadyPicked: config.reminderChannelsAutoPicked,
                                          looks: firstReminderChannelLooks, platforms: platforms) {
        case .keepWatching:
            return
        case .stopAndRemember:
            config = Config.update { $0.reminderChannelsAutoPicked = true }
            Log.write("reminders: two or more chat apps ready at once — the choice is yours; Moe stops looking")
        case .stop:
            break
        }
        firstReminderChannelTimer?.invalidate()
        firstReminderChannelTimer = nil
    }

    /// A chat app was just connected, or a phone let in, in Settings ›
    /// Connections: look now rather than in up to ten minutes, and watch
    /// afresh from here.
    func chatAppConnected() {
        guard !config.reminderChannelsAutoPicked else { return }
        watchForFirstReminderChannel()
        Task { await lookForFirstReminderChannel() }
    }

    /// Settings › Background's "Let Moe get your attention".
    ///
    /// Switching off drops anything already waiting as well as stopping the
    /// next one: a glow left over from a minute ago is exactly the thing the
    /// person just said they did not want.
    /// Minutes before a calendar event Moe says so, or 0 for not at all.
    /// Clamped the same way the job clamps it, so the two cannot disagree
    /// about what a number means.
    func setCalendarHeadsUp(_ minutes: Int) {
        let m = min(120, max(0, minutes))
        config = Config.update { $0.calendarHeadsUpMinutes = m }
        Log.write("calendar heads-up: \(m == 0 ? "off" : "\(m) min before")")
    }

    func setBackgroundThinking(_ on: Bool) {
        config = Config.update { $0.backgroundThinking = on }
        Log.write("background thinking: \(on ? "on" : "off")")
    }

    func setSituationOffers(_ on: Bool) {
        config = Config.update { $0.situationOffers = on }
        Log.write("situation offers: \(on ? "on" : "off")")
    }

    func setSituationOffersToChats(_ on: Bool) {
        config = Config.update { $0.situationOffersToChats = on }
        Log.write("situation offers to chats: \(on ? "on" : "off")")
    }

    func setLaunchAtLogin(_ on: Bool) {
        config = Config.update { $0.launchAtLogin = on }
        LoginItem.set(on)
    }

    func setQuietHours(_ on: Bool) {
        config = Config.update { $0.quietHours = on }
        Log.write("quiet hours: \(on ? "on" : "off")")
    }

    /// Whether quiet hours can act right now: the zone stamp this Mac wrote
    /// is under a day old. Settings says so when it is not.
    var quietHoursArmed: Bool {
        guard let data = try? Data(contentsOf: Paths.timeZone),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["at"] as? Double else { return false }
        return Date().timeIntervalSince1970 - at < 24 * 3600
    }

    // MARK: - Where the person is (docs/LOOPS.md §2)

    private var presenceTimer: Timer?
    private var presenceObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var macAsleep = false
    /// The display went to sleep with the screen still unlocked (NSWorkspace
    /// screensDidSleep): nobody is looking, so the fork's hand-over treats it
    /// as away and nothing is put up on a dark screen.
    private var displayAsleep = false

    /// Keep `~/.moe/presence.json` true: at the Mac, or not. The delivery
    /// path reads it to decide whether a message for the person goes to the
    /// island alone or to their phone as well. Every minute, and at once on
    /// lock, unlock, sleep and wake — a stamp older than three minutes is
    /// read as "not here", so the timer is what keeps "here" alive and a
    /// closed app or a sleeping Mac falls to "away" by itself.
    func startPresence() {
        presenceTimer?.invalidate()
        // Running means here: a sentinel left by a sleep the app never woke
        // from (quit, crash, update) must not keep the Mac's cron silent.
        cloud.presenceStarted()
        // The four lock/unlock/sleep/wake observers live in
        // `PresenceWatcher`, the same class the CLI drives in its tests — so
        // the hook the suite proves is the hook the app runs. Each event
        // writes the local presence file, and a build with a cloud also
        // tells it (`CloudLink.presence`): `away` at once on sleep, so the
        // machine covers a reminder without waiting for the relay socket's
        // ping deadline; `here` on wake or unlock, so it stands down.
        presenceWatcher = PresenceWatcher { [weak self] event in
            // The watcher calls on the main queue. `willSleep` is handled
            // RIGHT HERE, synchronously: macOS holds the sleep only while
            // this handler is running, and the `Task` hop below returns at
            // once — so a turn told about the sleep from inside the Task, and
            // an `away` waited for there, ran after the OS had stopped
            // waiting (found by review, 2026-09-18). The quit path's wait is
            // synchronous for the same reason.
            if event == .willSleep, let self {
                MainActor.assumeIsolated {
                    self.macAsleep = true
                    // Before `away` reaches the edge: the cloud may claim
                    // from that moment, so the Mac must already be silent.
                    self.cloud.macWillSleep()
                    self.writePresence()
                    // A turn in flight is told the sleep is happening, so a
                    // stream found broken on wake is picked up, not reported
                    // (`TurnKeeper`). And `away` is waited for, briefly: the
                    // fire-and-forget it used to be had to beat the lid on its
                    // own, and whether it ever did was never measured
                    // (docs/CLOUD-REMAINING.md B11.1).
                    self.bridge.noteSystemSleep()
                    self.cloud.presence(event)
                }
                return
            }
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .locked: self.screenLocked = true
                case .unlocked: self.screenLocked = false
                case .willSleep: self.macAsleep = true
                case .didWake: self.macAsleep = false
                case .quit: break
                }
                self.writePresence()
                if event == .didWake {
                    self.cloud.macDidWake()
                    self.writeTimeZone()
                    // A turn whose stream survived the sleep asks the edge
                    // whether the cloud took the ask meanwhile — before it
                    // runs on and answers a second time.
                    self.bridge.noteSystemWake()
                }
                self.cloud.presence(event)
            }
        }
        presenceWatcher?.start()
        let wsc = NSWorkspace.shared.notificationCenter
        presenceObservers = [
            NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.writeTimeZone(force: true) }
            },
            wsc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayAsleep = true; self?.writePresence() }
            },
            wsc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.displayAsleep = false; self?.writePresence() }
            },
        ]
        // The zone too, on the same beat: `writeTimeZone` rewrites nothing
        // unless the zone moved or its stamp is twelve hours old, but it has
        // to be ASKED, and until 2026-09-11 it was asked only at launch, on
        // wake and on a zone change — so a Mac left running for a day had a
        // stamp older than the 24 h deliver.py trusts, and quiet hours
        // silently held nothing (measured with the reader: 23:30 tonight
        // quiet, 07:59 tomorrow not, on a file from this morning).
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.writePresence(); self?.writeTimeZone(); self?.sayStillHere()
                self?.startFreshIfIdle()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        presenceTimer = t
        writePresence()
        writeTimeZone()
        sayStillHere()
    }

    /// "Mac wins" (owner, 2026-09-30): a running Mac tells its cloud it is
    /// here at launch and every few minutes (`CloudLink.stillHere`).
    private func sayStillHere() {
        cloud.stillHere(asleep: macAsleep)
    }

    /// The Mac's zone, for the cloud copy (docs/LOOPS.md §5). Rewritten only
    /// when the zone actually changed or the stamp is older than twelve
    /// hours: the file is a ledger document, and a stamp that moved every
    /// minute would publish a record every minute.
    func writeTimeZone(force: Bool = false) {
        let zone = TimeZone.current
        let body: [String: Any] = ["iana": zone.identifier,
                                   "utc_offset_seconds": zone.secondsFromGMT(),
                                   "at": Date().timeIntervalSince1970,
                                   "source": "mac-os"]
        let url = Paths.timeZone
        if !force, let data = try? Data(contentsOf: url),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           old["iana"] as? String == zone.identifier,
           old["utc_offset_seconds"] as? Int == zone.secondsFromGMT(),
           let at = old["at"] as? Double, Date().timeIntervalSince1970 - at < 12 * 3600 {
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            Log.write("timezone: \(zone.identifier) (\(zone.secondsFromGMT() / 3600)h)")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Hands on it in the last three minutes, unlocked, awake.
    nonisolated static let presenceIdleSeconds: Double = 180

    /// The presence stamp's fields. `locked`, `asleep` and `display_asleep` say WHY `active` is
    /// false: a person who asked from the Mac a moment ago and touched it then is still at it for
    /// that turn (the fork's `at_this_mac` grace, browser hand-over); a locked screen, a sleeping
    /// Mac or a dark display never is. `active` is false with the display asleep too, so
    /// moe-screen `deliver.at_mac`, which reads only `active`, sends to the phone then as well.
    nonisolated static func presenceBody(locked: Bool, asleep: Bool, displayAsleep: Bool = false,
                                         idle: Double, now: Double) -> [String: Any] {
        let active = !locked && !asleep && !displayAsleep && idle < presenceIdleSeconds
        return ["active": active, "at": now, "idle": Int(idle), "locked": locked, "asleep": asleep,
                "display_asleep": displayAsleep]
    }

    func writePresence() {
        let body = Self.presenceBody(locked: screenLocked, asleep: macAsleep, displayAsleep: displayAsleep,
                                     idle: Self.secondsSinceInput(), now: Date().timeIntervalSince1970)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let url = Paths.presence
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    func setNudges(_ on: Bool) {
        config = Config.update { $0.nudges = on }
        if !on {
            pendingNudge = nil
            pendingNudgeWhen = nil
            pendingNudgeHandle = nil
            try? FileManager.default.removeItem(at: Paths.home.appendingPathComponent("nudge.json"))
        }
        Log.write("nudges: \(on ? "on" : "off")")
    }

    func setScreenContext(_ on: Bool) {
        config = Config.update { $0.screenContext = on }
        screen.enabled = on && brainSupportsVision
        if !on { screen.discard() }
        Log.write("screen: \(on ? "on" : "off")")
    }

    func setScreenPointerMovesMouse(_ on: Bool) {
        config = Config.update { $0.screenPointerMovesMouse = on }
    }

    /// Whether Moe may front a window or switch Space to finish something.
    ///
    /// The gateway reads this from its environment, so a change only reaches
    /// the running brain when it is restarted — the same shape as every other
    /// setting Hermes is told about at spawn.
    func setComputerUseMayTakeOver(_ on: Bool) {
        config = Config.update { $0.computerUseMayTakeOver = on }
        Log.write("computer use: takeover \(on ? "allowed" : "off") — takes effect on the next brain restart")
    }

    /// Put the ring where the model pointed, in the screenshot it was shown.
    private func showPoint(_ tag: PointTag) {
        guard let cap = lastCapture else { return }
        guard cap.geometry.contains(x: tag.x, y: tag.y) else {
            Log.write("screen: point \(tag.x),\(tag.y) is outside \(cap.width)×\(cap.height); ignored")
            return
        }
        let at = cap.screenPoint(x: tag.x, y: tag.y)
        pointer.point(at: at, label: tag.label, moveMouse: config.screenPointerMovesMouse)
    }

    func setDictationSounds(_ on: Bool) {
        config = Config.update { $0.dictationSounds = on }
    }

    func setDictationHistory(_ on: Bool) {
        config = Config.update { $0.dictationHistory = on }
    }

    /// Thinking is a property of the request, so the polisher is rebuilt to
    /// carry the new `BrainSelection`; a live one would keep the old setting
    /// until Settings changed something else.
    func setDictationPolishThinking(_ on: Bool) {
        config = Config.update { $0.dictationPolishThinking = on }
        polisher = DictationPolisher(config: config, vocabulary: Self.vocabularyTerms)
        let rebuilt = polisher
        Task { await polishRouter.replaceBrain(rebuilt) }
    }

    /// What each rewrite tier can do right now, for the Settings pane.
    ///
    /// Refreshed on demand rather than observed: all three checks are cheap
    /// but none is free (two loopback probes and an Apple availability
    /// query), and nobody needs them while they are not looking at the pane.
    @Published private(set) var polishTierStatus: [PolishTier: String] = [:]
    @Published private(set) var polishTierReady: Set<PolishTier> = [.rulesOnly, .configuredBrain]

    /// Ask every tier whether it could run, and say so in words a person can
    /// act on — "Apple Intelligence is off" tells someone what to do;
    /// "unavailable" does not.
    func refreshPolishTiers() {
        Task { @MainActor in
            var status: [PolishTier: String] = [:]
            var ready: Set<PolishTier> = [.rulesOnly]

            status[.rulesOnly] = "Always available. No model, so no formatting."

            let apple = await polishRouter.appleStatus()
            status[.appleOnDevice] = apple.detail
            if apple.ready { ready.insert(.appleOnDevice) }

            if let found = await LocalModelServer.detect() {
                if found.isReady {
                    let pick = LocalModelServer.preferredModel(from: found.models) ?? "?"
                    status[.localServer] = "Found \(found.name), using \(pick)."
                    ready.insert(.localServer)
                } else {
                    status[.localServer] = "\(found.name) is running but has no model downloaded yet."
                }
            } else {
                status[.localServer] = "Nothing found. Install Ollama or LM Studio and Moe will use it."
            }

            status[.configuredBrain] = connected
                ? "Ready. The only choice that sends what you dictate off this Mac."
                : "Your AI is not reachable right now."
            if connected { ready.insert(.configuredBrain) }

            polishTierStatus = status
            polishTierReady = ready
        }
    }

    func setDictationPolishTier(_ tier: PolishTier?) {
        config = Config.update { $0.dictationPolishTier = tier?.rawValue ?? "" }
    }

    /// Switching it off mid-hold must drop what was already read, or the
    /// dictation in flight would still send it.
    func setDictationCursorContext(_ on: Bool) {
        config = Config.update { $0.dictationCursorContext = on }
        if !on { dictationBefore = nil }
    }

    /// Switching it off mid-hold drops what was already read, the same as
    /// the cursor prefix: a dictation in flight must not still carry it.
    func setDictationScreenVocabulary(_ on: Bool) {
        config = Config.update { $0.dictationScreenVocabulary = on }
        if !on { LiveVocabulary.shared.clear() }
    }

    func setDictationLearnCorrections(_ on: Bool) {
        config = Config.update { $0.dictationLearnCorrections = on }
    }

    // MARK: - Brain settings

    /// Put a new provider/model into effect. Called by the Brain pane after
    /// configure-hermes.py has written ~/.hermes.
    ///
    /// Two costs, chosen by what changed:
    /// - `restartGateway` (provider or credentials changed): the gateway
    ///   process reads .env and resolves the provider at start, so it is
    ///   stopped and a fresh `HermesBrain` + supervisor brings it back.
    ///   Seconds, plus a cold claude child for the Claude provider.
    /// - otherwise (model or effort only): every request already names the
    ///   model, so only the sessions rotate — Hermes keeps one warm child
    ///   per session id with the model it was started with, and a new id
    ///   is what makes it start another. One cold turn, no restart.
    ///
    /// Either way the conversation on screen carries on (`rebuildBrain`),
    /// except for an effort-only change, which still starts a fresh one.
    func applyBrain(_ selection: BrainSelection, baseURL: String, polishModel: String, restartGateway: Bool) {
        config = Config.update {
            $0.brainProvider = selection.provider
            $0.brainModel = selection.model
            // The table's answer now; Hermes's, if it has one, once the
            // gateway is back (BrainPane calls refreshBrainCapabilities).
            $0.brainCapabilitiesCache = BrainCapabilityCache(
                provider: selection.provider.rawValue, model: selection.model,
                capabilities: selection.provider.capabilities(for: selection.model))
            var extras = $0.brainExtras
            extras["reasoningEffort"] = selection.reasoningEffort.isEmpty ? nil : selection.reasoningEffort
            extras["baseURL"] = baseURL.isEmpty ? nil : baseURL
            $0.brainExtras = extras
            $0.dictationPolishModel = polishModel
            // A fresh dictation session, so its warm child is rebuilt on
            // the new model instead of answering on the old one.
            $0.dictationSessionID = UUID().uuidString.lowercased()
        }
        // A model that cannot see gets no screenshot; the user switch is unchanged.
        screen.enabled = config.screenContext && brainSupportsVision
        polisher = DictationPolisher(config: config, vocabulary: Self.vocabularyTerms)
        // The router holds the brain tier; a Settings change that rebuilds
        // the polisher must reach it, or the ladder keeps calling the old
        // gateway with the old key.
        let rebuilt = polisher
        Task { await polishRouter.replaceBrain(rebuilt) }
        if restartGateway {
            rebuildBrain()
        } else {
            // The live brain keeps its selection from init; hand it the new
            // one before the reset, or the next session would start on the
            // old model while the probe (which names the model itself) passes.
            let before = bridge.brainFingerprint
            applyChatBrain()
            if bridge.brainFingerprint != before {
                // A new model: the same conversation, on a session of the
                // new model's. The derived id changes with the model, so
                // Hermes starts a child on it, primed with the thread. This
                // used to be `newConversation()` — a model change that also
                // put the conversation away.
                settleForBrainChange()
                bridge.resume(conversationLedger.resume(
                    thread: conversationID, brain: bridge.brainFingerprint,
                    knownTurns: storedTurns(), startedAt: conversationStartedAt))
            } else {
                // Effort only. The session id is derived from provider and
                // model, so resuming would land on the same warm child with
                // the old effort; only a fresh thread's session starts a new
                // one. Unchanged from before 2026-09-29.
                newConversation()
            }
        }
    }

    /// Bring the brain up again from scratch — after a sign-in, when the
    /// gateway that couldn't start now can.
    func restartBrain() {
        needsSignIn = false
        rebuildBrain()
        // Every caller is a sign-in (Claude, ChatGPT, the seed finishing), and
        // a new sign-in here is the cloud machine's too (owner, 2026-09-25).
        followAwayBrain("after a sign-in")
    }

    /// Keep the cloud machine's brain in step with this Mac's — the owner's
    /// "follow unless I set it apart" (2026-09-25). Off the main thread; one
    /// local ledger read decides whether there is a machine at all, so a Mac
    /// with no Away plan does nothing and reads no credential. A machine set
    /// apart in Settings › Away is left alone. Logged, never shown: the Brain
    /// pane says what happened when the person is looking at it.
    func followAwayBrain(_ why: String) {
        // Moe Dev is a workbench on this Mac, never the person's brain: a
        // sign-in tried there must not replace what their cloud computer
        // thinks with.
        guard !BuildInfo.isDev, let follow = Cloud.followBrain else { return }
        let kind = config.brainProvider
        let here = AwayBrainFollow.Here(
            provider: kind.rawValue, model: config.brainModel,
            baseURL: kind.usesBaseURL ? (config.brainExtras["baseURL"] ?? kind.defaultBaseURL) : "",
            keyInHand: false)
        Task.detached(priority: .utility) {
            let followed = follow(here, "")
            if AwayBrainFollow.travels(followed.step) || followed.note?.needsYou == true {
                Log.write("away brain (\(why)): \(followed.step) — \(followed.note?.sentence ?? "sent")")
            }
        }
    }

    // MARK: Capabilities (PRODUCT.md §3.4a)

    /// The brain takes images. Consulted by the screen-context feature
    /// (Sources/Moe/Screen/ScreenContext.swift) before it attaches a
    /// screenshot: true on ✓ or ?, false only on a definite —.
    var brainSupportsVision: Bool { config.brainCapabilities.mayAttachImages }
    /// The brain calls tools. Consulted by the prompt builder
    /// (`BrainPrompt.systemPrompt(supportsTools:)`), which tells a tool-less
    /// model to say what it would do instead.
    var brainSupportsTools: Bool { config.brainCapabilities.mayUseTools }

    /// Ask Hermes what it knows about the current model and lay that over
    /// the table's answer in `config.brainCapabilitiesCache`. Best effort:
    /// a gateway that is down or an older Hermes leaves the table's answer.
    func refreshBrainCapabilities() async {
        let selection = BrainSelection(config: config)
        let table = selection.provider.capabilities(for: selection.model)
        let merged = await BrainCapabilityProbe.fetch(config: config, brain: selection, over: table)
        guard merged != config.brainCapabilities else { return }
        config = Config.update {
            $0.brainCapabilitiesCache = BrainCapabilityCache(
                provider: selection.provider.rawValue, model: selection.model, capabilities: merged)
        }
    }

    /// Tear the brain down — its gateway with it, when Moe owns it — and
    /// bring up a new one on the current config, **carrying on the
    /// conversation that is on screen**.
    ///
    /// Every reason this runs keeps the conversation: a sign-in (a different
    /// Claude or ChatGPT account, the seed finishing) changes who pays for
    /// the thinking, not what is being talked about; and a new provider is
    /// the same person in the same conversation, with a different model
    /// reading it. The thread's turns stay on screen and the new brain is
    /// resumed on it exactly as the conversation switcher does
    /// (`openConversation`): the session id is derived from the thread and
    /// the brain, so with the same provider and model Hermes simply carries
    /// on the same session, transcript, helpers and all; a new provider or
    /// model gets a new session, primed with what it has not been told.
    ///
    /// Until 2026-09-29 this cleared the chat and started the new brain on a
    /// random session. The owner signed in to another Claude account at
    /// 20:33 with seven helpers finished in the conversation on screen; the
    /// next question went to a session that had never started them, and Moe
    /// said it had started no helpers.
    private func rebuildBrain() {
        settleForBrainChange()
        connected = false
        restartAttempts = 0
        statusLine = "switching brain…"
        let old = RetiredBrain(bridge)
        old.brain.onEvent = nil
        // stop() blocks while the gateway is asked, then made, to leave
        // (up to five seconds); not on the main thread.
        let fresh = makeBrain(config)
        let freshID = ObjectIdentifier(fresh)
        bridge = fresh
        wire()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            old.brain.stop()
            DispatchQueue.main.async {
                guard let self, ObjectIdentifier(self.bridge) == freshID else { return }
                self.lastStartAt = Date()
                self.applyChatBrain()
                // `resume` starts it: on the thread's session, primed or
                // warmed up, never on a random one first.
                self.bridge.resume(self.conversationLedger.resume(
                    thread: self.conversationID, brain: self.bridge.brainFingerprint,
                    knownTurns: self.storedTurns(), startedAt: self.conversationStartedAt))
            }
        }
    }

    /// Whatever the old brain was saying stops, and the conversation is
    /// filed as it stands, so the brain that follows can be resumed on it.
    private func settleForBrainChange() {
        awaitingReply = false
        replySignal.abandoned()
        replyAbandoned = true      // stragglers of the old brain's turn are nobody's
        interruptionNote = nil
        interruptedHeard = nil
        stagedContext = nil
        voice.stopAll()
        partial = ""
        // A reply that was streaming stops where it is; what it said stays.
        for i in turns.indices where turns[i].isStreaming { turns[i].isStreaming = false }
        // Filed before the brain is resumed on it, so the resume sees every
        // turn — the ledger's queue orders the two.
        saveConversation()
        streamingTurnID = nil
        spokenUpTo = ""
        mode = .idle
    }

    /// How the brain is built: `BrainFactory` in the app, a stand-in in a
    /// test that drives `restartBrain`.
    var makeBrain: (Config) -> BrainProvider = { BrainFactory.make(config: $0) }

    /// A brain on its way out, handed to a background queue for its
    /// blocking `stop()`. Nothing else touches it once it's here.
    private final class RetiredBrain: @unchecked Sendable {
        let brain: BrainProvider
        init(_ brain: BrainProvider) { self.brain = brain }
    }

    /// The canonical spellings from the vocabulary files, for the polish
    /// prompt. Values only: the heard forms are the recogniser's mistakes,
    /// and the rule cleaner has already replaced them. The user's own file
    /// comes first and a cap keeps a big Contacts cache from swamping the
    /// prompt (which is baked into the warm brain session).
    nonisolated static func vocabularyTerms() -> [String] {
        Vocabulary.shared.promptTerms(limit: promptVocabularyLimit)
    }

    nonisolated static let promptVocabularyLimit = 400

    /// The hotkey and the island button. One key does the obvious thing
    /// in every state — and the machine, not this file, says what that is.
    func toggle() {
        if meetingOwnsMic, !voice.inConversation {
            onWantsIsland?(true)
            statusLine = Self.meetingMicHint
            return
        }
        onWantsIsland?(true)
        voice.toggle()
    }

    /// Double-tap: drop everything, right now.
    ///
    /// Stops the voice mid-word, abandons the turn Claude is working on, closes
    /// the microphone, and clears the island. Nothing carries on in the
    /// background afterwards.
    func stopEverything() {
        let receipt = StopReceipt()
        let wasSpeaking = voice.isSpeaking
        let wasCapturing = Self.captureIsOpen(voice.state) || unconfirmedPressAt != nil
        _ = dropUnconfirmedPress()
        dropQueued()
        abandonTalkLatch()
        // A whisper to Moe mid-meeting is a hold like any other: the key
        // that started it must not find it still open, and the meeting's mic
        // must stop feeding a recogniser nobody is listening to.
        holdBeganAt = nil
        if meetingWhisper {
            meetingSession?.recorder.forwardMic(nil)
            meetingWhisper = false
        }
        // A dictation in flight — held or latched — goes with everything
        // else; the key must not type what was heard when it next moves.
        if dictation == .listening || dictationPending {
            clearDictationPending()
            dictationLatched = false
            dictation = .off
            partial = ""
            onDictationAbandoned?()
        }
        let wasWorking = awaitingReply
        voice.stopAll()
        receipt.mark(.ttsSilent, applies: wasSpeaking)
        voice.afterPipeline { receipt.mark(.captureClosed, applies: wasCapturing) }
        // False by now if the machine abandoned a spoken reply just above.
        let needsReset = awaitingReply
        // Deliberately dropped: the cut transcript reaches the fresh
        // brain through `restoreContext`, and stop-everything is a clean
        // slate, not an interruption to explain.
        interruptionNote = nil
        interruptedHeard = nil
        stagedContext = nil
        screen.discard()
        pointer.hide()
        awaitingReply = false
        // Everything the stopped turn still emits is nobody's: deltas, tool
        // starts and its finish already queued on main, or arriving before
        // `abandonTurn` lands. `voice.stopAll()` only marks this when a spoken
        // reply was live, so a typed turn, or one stopped before its first
        // sentence was spoken, went on to speak and relight the island after
        // the stop. `submit` clears it, as it does for every other abandon.
        replyAbandoned = true
        stoppedAt = Date()
        // Stopped, not answered: nothing is owed and nothing is announced.
        replySignal.abandoned()
        partial = ""
        statusLine = ""
        mode = .idle
        inConversation = false
        abandonTurnState()

        // Only drop the brain's turn if it was actually mid-thought, and
        // drop the *turn*, not the session: restarting the process was the
        // one way to abandon work already handed over, and it also wiped
        // the conversation — doing that on every stop is why Moe forgot
        // what it had just told you, and why the next answer took 12–27 s.
        // `voice.stopAll()` above may already have abandoned a spoken reply
        // (in `abandonSpokenReply`); `awaitingReply` is false by now if it
        // did. Never twice.
        if wasWorking {
            if needsReset {
                bridge.abandonTurn { Task { @MainActor in receipt.mark(.brainAbandoned, applies: true) } }
            } else {
                // The machine's `.abandonReply` already handed it over.
                receipt.mark(.brainAbandoned, applies: true)
            }
            turns.append(Turn(role: .system, text: "Stopped."))
        } else {
            receipt.mark(.brainAbandoned, applies: false)
        }
        confirmStopped()
        // A meeting owns the microphone and the island: its Recording ear
        // and its panel stay exactly where they were.
        if !meetingOwnsMic { onWantsIsland?(false) }
    }

    /// Esc in the island's panel or the chat window
    /// (`AppDelegate.watchForEscape`). True when it stopped something and
    /// the key is spent; false leaves Esc to the window.
    func escapePressedInMoe() -> Bool {
        guard Self.escStops(talkLatched: talkLatched,
                            dictating: dictation != .off || dictationPending,
                            somethingToStop: mode != .idle || awaitingReply || acting
                                || voice.isSpeaking || unconfirmedPressAt != nil)
        else { return false }
        Log.write("esc in Moe — stopping everything")
        stopEverything()
        return true
    }

    /// Whether Esc, read in one of Moe's own windows, is a stop. Not while
    /// hands-free (the talk key drops that turn itself) or dictating (its
    /// Esc types nothing), and not with nothing going on.
    nonisolated static func escStops(talkLatched: Bool, dictating: Bool, somethingToStop: Bool) -> Bool {
        !talkLatched && !dictating && somethingToStop
    }

    /// The stop says so: a short falling tone, and "Stopped" in the island's
    /// left ear for `stoppedShownSeconds`. Before this a stop only made the
    /// island go away, and 51 of 110 stops on the owner's Mac came within
    /// 6 s of another double-tap — tapping again because nothing said the
    /// first had worked.
    func confirmStopped() {
        chime.play(.halt)
        showingStopped = true
        stoppedShownTask?.cancel()
        stoppedShownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stoppedShownSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.showingStopped = false
        }
    }

    private static func captureIsOpen(_ s: VoiceEngine.State) -> Bool {
        switch s {
        case .attending, .capturing, .followUp, .deciding: return true
        default: return false
        }
    }

    /// Put down everything a turn was holding, without waiting for a turn
    /// that is never going to finish to put it down for us.
    ///
    /// `acting` is the one that mattered: it goes true on the first tool step
    /// and was only ever cleared by `turnFinished` or an error, and the
    /// island's travelling light runs on `mode == .thinking || acting`. So a
    /// stopped turn left the light going for the rest of the session — and
    /// pressing the key again could not put it out, because a press only
    /// touches `mode`. That is the whole of "I'm pressing to cancel and it
    /// doesn't cancel": the stop worked every time, and nothing on screen
    /// ever said so.
    ///
    /// The rest is bookkeeping that would otherwise leak into the next turn:
    /// a half-written reply left marked as still streaming, tool chips from
    /// work that was abandoned, and an offset into text that no longer
    /// exists — which would have sent the next reply to the synthesiser from
    /// the wrong character.
    private func abandonTurnState() {
        acting = false
        lastToolDetail = ""
        currentStepPhrase = nil
        workingStep = nil
        workingSince = nil
        drivingApp = nil
        browsing = false
        lastSpokenStep = ""
        runningTools.removeAll()
        runningToolNames.removeAll()
        confirmWaiting = nil
        speechStall?.cancel(); speechStall = nil
        progressTimer?.invalidate(); progressTimer = nil
        // A reply still on its way keeps its turn. The × dismisses the
        // island; it does not throw the answer away, and it is called with
        // `awaitingReply` still set. Only a stop that has already given up on
        // the turn takes the transcript apart.
        guard !awaitingReply else { return }
        pendingTools.removeAll()
        pendingLinks.removeAll()
        pendingThinking = ""
        spokenUpTo = ""
        quietWork.reset()
        workingSilently = false
        pointParser = PointTagParser()
        continuationBase = nil
        if let id = streamingTurnID, let idx = turns.firstIndex(where: { $0.id == id }) {
            turns[idx].isStreaming = false
            // A continuation that never came leaves only the paragraph
            // break it opened on the end of the reply.
            turns[idx].text = turns[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty one is the placeholder made at `submit` time for a
            // reply that never arrived; leaving it puts a blank Moe bubble
            // in the transcript for good.
            if turns[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turns.remove(at: idx)
            }
        }
        streamingTurnID = nil
    }

    /// Hand the recent conversation back to a freshly started Claude.
    ///
    /// Restarting the CLI is the only way to interrupt it, and a new process
    /// remembers nothing. Without this, one accidental double-tap turned
    /// "what did Maryann say?" into "I don't know anyone called Maryann".
    private func restoreContext() {
        // The selection lives in `ContextReplay`, with tests. It was inline
        // and wrong — `suffix(8).filter { … }` took the window before
        // dropping the turns with nothing in them, so an interruption's empty
        // turn spent a slot, and on 2026-09-04 a five-part request fell out
        // of the back of a window full of them. `ContextReplay` explains it.
        let script = ContextReplay.script(turns.compactMap { turn in
            guard turn.role != .system else { return nil }
            return ContextReplay.Line(who: turn.role == .you ? .them : .us, text: turn.text)
        })
        guard !script.isEmpty else { return }
        bridge.send(Self.restoreNote(script), silent: true, starter: .background)
    }

    /// The same conversation, kept back to travel with the next turn.
    ///
    /// Provider-agnostic on purpose: any brain that cannot cancel a turn has
    /// to be restarted to interrupt it, and any restarted brain has to be
    /// told what it missed. Whether that costs a process spawn (the Claude
    /// Code child) or only a round trip (a plain API brain, which keeps no
    /// process), sending it as its own message puts one more request in
    /// front of the person's question. Carrying it with them costs nothing
    /// anywhere.
    private func stageContextRestore() {
        let script = ContextReplay.script(turns.compactMap { turn in
            guard turn.role != .system else { return nil }
            return ContextReplay.Line(who: turn.role == .you ? .them : .us, text: turn.text)
        })
        stagedContext = script.isEmpty ? nil : Self.restoreNote(script)
    }

    /// The transcript rides in a tag pair: it holds Moe's own lines as well as
    /// the person's, and whatever reads a turn for the person's words
    /// (moe-screen `persons_words`) leaves a tagged block out by its shape.
    static func restoreNote(_ script: String) -> String {
        """
        (Background note, not from the user. Your process was restarted and you \
        lost the thread. Here is the conversation so far, so you can carry on \
        as if nothing happened. Do not reply to this message.)

        <earlier-conversation>
        \(sealed(script, in: "earlier-conversation"))
        </earlier-conversation>
        """
    }

    /// `text` made safe to carry inside `<tag>…</tag>`: a closing tag of that
    /// name inside it (a web page a helper read, a line somebody typed) would
    /// end the block early, and what followed would read as outside it — to
    /// the brain, and to `persons_words` as the person talking. The same
    /// reason `BrainPrompt.briefBlock` strips `</brief>`.
    static func sealed(_ text: String, in tag: String) -> String {
        text.replacingOccurrences(of: "</\(tag)>", with: "</\(tag)\u{200B}>", options: .caseInsensitive)
    }

    /// Deliberately end the conversation (Esc, the × on the island).
    func endConversation() {
        voice.stopAll()
        inConversation = false
        partial = ""
    }

    /// Change the global shortcut. Takes effect on the next launch, because the
    /// Carbon hotkey is registered once at startup.
    func setHotKeyModifiers(_ mods: UInt32) {
        config = Config.update { $0.hotKeyModifiers = mods }
        statusLine = "shortcut saved — restart Memoe to use it"
    }

    /// The language Moe listens for. Warms the engine that language needs in
    /// the background; progress lands on the status line via `onLoadProgress`.
    func setLanguage(_ locale: String) {
        guard locale != config.locale else { return }
        config = Config.update { $0.locale = locale }
        Task { await voice.useLanguage(locale) }
    }

    func setAlwaysListening(_ on: Bool) {
        alwaysListening = on
        config = Config.update { $0.wakeWordEnabled = on }
        voice.apply(config: config)
        if on {
            // Mid-meeting: remembered, and started when the meeting ends.
            guard !meetingOwnsMic else { return }
            voice.setWakeWord(true)
        } else {
            voice.setWakeWord(false)
            partial = ""
        }
    }

    /// After a reply, keep listening: no name, no key. VOICE-PLAN.md §2.1.
    func setConversationMode(_ on: Bool) {
        config = Config.update { $0.conversationMode = on }
        voice.apply(config: config)
    }

    func setHoldOpensConversation(_ on: Bool) {
        config = Config.update { $0.holdOpensConversation = on }
        voice.apply(config: config)
    }

    func setFollowUpSeconds(_ seconds: Double) {
        config = Config.update { $0.followUpSeconds = seconds }
        voice.apply(config: config)
    }

    func setCloseOffer(_ how: String) {
        config = Config.update { $0.closeOffer = how }
        voice.apply(config: config)
    }

    func setBargeIn(_ on: Bool) {
        config = Config.update { $0.bargeIn = on }
        voice.apply(config: config)
    }

    /// Settings › Voice › "Use and preview". Through here rather than
    /// straight to the engine, so the published config — which the Voice and
    /// Away panes read — carries the new engine and voice. Before 2026-09-22
    /// nothing in the Conductor ever re-read `ttsEngine`, so reopening the
    /// pane showed the engine loaded at launch (Kokoro) while the premium
    /// voice was the one speaking.
    @discardableResult
    func useVoice(engine: TtsEngineKind, voice v: String) async -> VoiceFallback? {
        let fallback = await voice.useVoice(engine: engine, voice: v)
        config = Config.load()
        return fallback
    }

    /// Settings › Voice › Talking to Moe: the cloud voice and ears. Read
    /// per socket by `CloudVoice`, so nothing here has to be re-applied.
    func setCloudVoice(_ on: Bool) {
        config = Config.update { $0.cloudVoice = on }
        Log.write("cloud voice: \(on ? "on" : "off")")
    }

    /// Settings › Privacy › "Report without saying who I am" (docs/DEFAULTS.md
    /// row 28 d). moe-ticket.py reads it out of config.json on every report,
    /// so saving the file is the whole of applying it.
    func setProblemReportsAnonymous(_ on: Bool) {
        config = Config.update { $0.problemReportsAnonymous = on }
        Log.write("problem reports: without saying who \(on ? "on" : "off")")
    }

    /// The Away welcome has been put away, for this plan. Stored as the tier
    /// so that a later upgrade is welcomed again — what the plan gives you
    /// changed, and so did the first things worth doing about it.
    func setAwayWelcomeSeen(_ tier: String) {
        config = Config.update { $0.awayWelcomeSeen = tier }
        Log.write("away: welcome dismissed for \(tier)")
    }

    /// Settings asks whether interrupting works on this Mac's microphone
    /// and speakers; the engine measures it (VOICE-PLAN.md §7).
    /// Keep the conversation open (the tick).
    func keepConversationOpen() {
        offeringToClose = false
        voice.keepListening()
    }

    /// Close it (the cross).
    func closeConversation() {
        offeringToClose = false
        voice.dismissConversation()
    }

    func runEchoTest() async -> EchoTest.Verdict {
        await voice.runEchoTest()
    }

    // The owner's voice: a soft signal for "is this follow-up for Moe"
    // (VOICE-PLAN.md §4.5). Enrolled passively from wake turns; these are
    // the Settings prompts that seed it faster, and the way to erase it.
    func ownerVoiceState() async -> (turns: Int, enrolled: Bool) {
        await voice.ownerVoiceState()
    }
    func enrolOwnerVoice(onListening: @escaping @MainActor () -> Void) async -> VoiceEngine.EnrolResult {
        await voice.enrolOwnerVoice(onListening: onListening)
    }
    func openWakeTeach(level: @escaping @MainActor (Float) -> Void) async -> VoiceEngine.WakeTeachResult? {
        await voice.openWakeTeach(level: level)
    }
    func recordWakeClip(_ prompt: WakeRecorder.Prompt, number: Int, session: String,
                        onSpeech: @escaping @MainActor () -> Void) async -> VoiceEngine.WakeClip? {
        await voice.recordWakeClip(prompt, number: number, session: session, onSpeech: onSpeech)
    }
    func closeWakeTeach() {
        voice.closeWakeTeach()
    }
    func measureWakeTeach(progress: @escaping @MainActor (Int, Int) -> Void) async -> VoiceEngine.WakeTeachResult {
        await voice.measureWakeTeach(progress: progress)
    }
    func forgetWakeRecordings() async {
        await voice.forgetWakeRecordings()
    }
    func forgetOwnerVoice() async {
        await voice.forgetOwnerVoice()
    }

    func cancelEverything() {
        dropQueued()
        // Dismissing means the microphone goes down, even if always-listening
        // is switched on. It comes back when you next trigger Moe.
        speechStall?.cancel(); speechStall = nil
        voice.stopAll()
        partial = ""
        statusLine = ""
        mode = .idle
        abandonTurnState()
        onWantsIsland?(false)
    }

    /// Say what's taking so long, rather than going silent.
    ///
    /// Long jobs — searching mail, reading the web — used to produce nothing at
    /// all until the answer arrived, so there was no way to tell whether Moe
    /// was working or had died.
    private func startProgressNarration() {
        progressTimer?.invalidate()
        var ticks = 0
        let timer = Timer(timeInterval: 7, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.awaitingReply else { t.invalidate(); return }
                ticks += 1
                self.narrateStillWorking()
                guard ticks <= 3 else { return }          // don't nag forever
                // The sheet's own line stays up while it waits.
                guard self.confirmWaiting == nil else { return }
                // Shown, never spoken, and never invented: this is the step
                // Hermes says is running right now, in Hermes's own words.
                // Nothing here makes up a line to fill the gap — the account
                // of a long job is the model's to give, and BrainPrompt asks
                // it for one; this is the visible half of the same truth.
                self.statusLine = self.lastToolDetail.isEmpty
                    ? "still working…"
                    : "\(self.lastToolDetail)…"
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    /// Write every exchange to ~/.moe/history/, one markdown file per day.
    ///
    /// Kept as plain files for the same reason memory is: you can read them,
    /// search them, back them up, or delete them, without the app's help.
    private func recordHistory(_ turn: Turn) {
        guard turn.role != .system,
              !turn.text.trimmingCharacters(in: .whitespaces).isEmpty || !turn.attachments.isEmpty
        else { return }
        let dir = Paths.home.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        let url = dir.appendingPathComponent("\(day.string(from: turn.at)).md")
        let who = turn.role == .you ? "You" : "Moe"
        let attached = turn.attachments.isEmpty ? ""
            : " _(attached: \(turn.attachments.map(\.name).joined(separator: ", ")))_"
        let line = "**\(clock.string(from: turn.at)) · \(who)** — \(turn.text)\(attached)\n\n"

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            let header = "# \(day.string(from: turn.at))\n\n"
            try? (header + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `memoryChangedAt` and `reloadMemory` are gone with the prompt blocks
    /// they served. Both existed because Moe baked memory into the system
    /// prompt at session start, so an edit to a memory file could only be
    /// picked up by throwing the session away and starting another. Hermes
    /// reads its own store per turn, so an edit is live on the next question
    /// and there is nothing left to reload.

    /// Hand a finished answer to whoever is listening. Nil is the ordinary
    /// case — a background turn, or a second terminal event for a turn that
    /// has already been reported — and means nothing happens.
    private func announce(_ reply: Reply?) {
        guard let reply else { return }
        // An answer Moe is not going to say has no sound of its own. Typed in,
        // text out is the right default — but it means a question asked into
        // the notch and then forgotten about arrives with nothing to notice,
        // and a person who has gone back to their work misses it entirely.
        // One soft note, the same engine as the dictation chimes, and only
        // ever when speech will not do the announcing.
        // `!meeting.isRecording` of its own, and not merely `!replySpeaks`.
        // Those are two different silences and only one of them wants a
        // sound: mid-meeting `replySpeaks` is false *because the room must
        // not hear Moe*, and quietly asking "what did they just say" would
        // have put a tone out of the speakers and into the call — the exact
        // thing the meeting rule exists to prevent, and the opposite of what
        // Settings › Replies promises in so many words.
        if config.replyChime, !replySpeaks, !meeting.isRecording { chime.play(.reply) }
        onReply?(reply)
    }

    /// Send typed or transcribed text.
    ///
    /// - Parameter origin: how this reached Moe. It decides whether the answer
    ///   is spoken (`replySpeaks`) and whether the model is asked to write it
    ///   for a reader rather than a listener. Defaulted to `.typed` because
    ///   that is the quiet answer, and a caller that forgets to say should
    ///   cost silence rather than an unexpected voice.
    /// `continuation`: the person paused mid-request, the first half went to
    /// the brain and was withdrawn when they went on; `text` is both halves.
    /// The brain is told the fragment was never the request, and the
    /// fragment's turn — and the answer it never got — leave the transcript,
    /// so what the person sees is what they said.
    /// `starter` is who started it, for Hermes (`TurnStarter`): `.person` for
    /// what someone typed or said, `.background` for a turn Moe raises itself
    /// (a handed-off result, a pickup after a relaunch). No default: a caller
    /// that forgets must not become the person.
    func submit(_ text: String, origin: TurnOrigin = .typed, starter: TurnStarter, continuation: Bool = false,
                attachments: [ChatAttachment] = [], outgoing outgoingOverride: String? = nil) {
        // `turnOrigin` is deliberately NOT set here. Three guards below return
        // without starting a turn — an empty transcript, a meeting Moe handles
        // itself, and one already in flight — and every one of them can be
        // reached while a *previous* turn is still streaming, because neither
        // island field is disabled while Moe is answering. Setting it on the
        // way in meant that typing anything during a spoken reply re-routed
        // the reply already in progress: every remaining gate read
        // `replySpeaks == false` and Moe went mute mid-sentence, then chimed
        // and opened the panel because it believed the answer was never said.
        //
        // This is the same rule the line below states for `takeTurnStart` —
        // a turn Moe handles itself must not leave a mark behind for the next
        // thing typed to pick up — and it is set where `turnBeganAt` is, past
        // the last of those returns.
        // Talking is an answer to "anything else?" — the prompt goes as
        // soon as there is something to answer it with.
        offeringToClose = false
        // Read on the way in, whatever this turn turns out to be: every path
        // out of here consumes the mark, so a turn Moe handles itself ("start
        // a meeting") can't leave it behind for the next thing typed into the
        // chat window to pick up and answer aloud.
        let spokenTurnBeganAt = voice.takeTurnStart()
        // Same for the interruption note: it belongs to the next thing
        // said to the brain, not to the first question after a turn Moe
        // handled itself.
        // Built here, not at the interruption, because what it has to say
        // depends on the words that follow: an interruption amends the
        // standing request unless it plainly withdraws it. `Interruption`
        // holds that rule and its cue list.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String
        if continuation {
            note = interruptedHeard != nil ? Interruption.continuationNote() : ""
            withdrawFragment()
        } else {
            note = interruptedHeard.map { Interruption.note(heard: $0, saying: trimmed) }
                ?? interruptionNote ?? ""
        }
        interruptionNote = nil
        interruptedHeard = nil
        stagedContext = nil
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            // Back to whatever was happening before the key went down.
            // `holdBegan` writes `.listening` over it the instant the key
            // moves, so a stray press during a reply — and mashing the key
            // because nothing seems to be happening is exactly when that
            // occurs — used to leave the island idle with the answer still
            // on its way.
            if mode == .listening { mode = awaitingReply ? .thinking : .idle }
            // A press that produced no words leaves no screenshot behind:
            // otherwise it would ride along with whatever is typed next.
            screen.discard()
            // No brain turn, so nothing will ever report one finished — and
            // the microphone would stay held open waiting for it. Unless a
            // real turn is in flight: that one owns `replyPending`, and
            // clearing it here let the audio graph go down underneath the
            // reply that was still coming.
            if !awaitingReply { voice.replyFinished() }
            return
        }
        // "Start a meeting" never reaches the brain: Moe handles it here,
        // on an exact phrase, so recording other people is never a model's
        // guess — and never a tool call (BrainPrompt says so for paraphrases).
        if attachments.isEmpty,
           let intent = MeetingIntent.match(trimmed), intent != .repeatLast || meeting.isRecording {
            screen.discard()
            voice.replyFinished()      // handled here; no brain turn is owed
            turns.append(Turn(role: .you, text: trimmed))
            switch intent {
            case .start:
                // `requestMeeting` is a toggle, which is right for the
                // hotkey and the menu item and wrong here: "start a
                // meeting" typed into the island mid-meeting stopped the
                // one that was recording. An explicit verb is not a toggle.
                // The `.stop` branch below already reads this way.
                if meeting.isRecording {
                    turns.append(Turn(role: .system, text: "Already recording — \(meetingClock) so far."))
                } else {
                    requestMeeting()
                }
            case .stop:
                if meeting.isRecording { stopMeeting() }
                else { turns.append(Turn(role: .system, text: "No meeting is being recorded.")) }
            case .repeatLast:
                // Local and instant: the last thing they said, from the live
                // transcript — no brain round-trip for "what did he say".
                turns.append(Turn(role: .moe, text: TranscriptRecall.answer(meetingTimeline, now: meetingSession?.elapsed ?? 0)))
                if mode == .listening || mode == .thinking { mode = .idle }
            }
            return
        }
        guard !awaitingReply else {
            if origin == .typed, starter == .person, !continuation {
                // Held, not dropped: it goes when this turn finishes. Two
                // typed while waiting go together, in order.
                queuedTyped = [queuedTyped, trimmed].compactMap { $0 }.joined(separator: "\n\n")
                queuedAttachments += attachments
            } else {
                turns.append(Turn(role: .system, text: "Still working on the last one — one sec."))
            }
            screen.discard()
            // The turn already in flight owns the device; this one is
            // dropped. It can only be a typed turn here — a spoken one
            // would have been abandoned by the key-down that let this
            // utterance in — so the machine must not sit owed a reply
            // that this dropped turn will never bring.
            voice.replyFinished()
            return
        }

        // There used to be a reset here when ~/.moe/memory changed under the
        // prompt. Moe no longer puts memory in the prompt — Hermes reads its
        // own store on every turn — so there is nothing to go stale, and a
        // session no longer gets thrown away to pick up an edit.

        voice.stopSpeaking()

        // Past every early return, so this turn is certainly the one that will
        // be answered. See the note at the top of this method.
        turnOrigin = origin
        // A turn the person (or the app) started: the stall guard's one
        // continuation is available to it again.
        stallContinuationSent = false
        continuationBase = nil
        // The mark is nil for a turn typed into the chat window, so the budget
        // only ever measures someone actually waiting to hear something.
        turnBeganAt = spokenTurnBeganAt
        // Who started it, and a count of the person's own: a grant's carry-on
        // is superseded by anything newer they said (`GrantWatch`).
        turnStarter = starter
        if starter == .person { personTurns += 1 }
        awaitingFirstToken = true
        // A new ask: last turn's Fix cards go, and each cause may be offered
        // once again. An interruption's continuation is the same ask.
        if !continuation {
            fixCodesThisTurn = []
            fixOffers = []
        }
        awaitingFirstAudio = true

        spokenUpTo = ""
        replyAbandoned = false
        replayingTurnID = nil
        // "Work silently" was for the last turn; this one is talked through.
        quietWork.reset()
        workingSilently = false
        speechStall?.cancel(); speechStall = nil
        lastNarrationAt = Date()
        lastSpokenStep = ""
        currentStepPhrase = nil
        confirmWaiting = nil
        drivingApp = nil
        browsing = false
        let yours = Turn(role: .you, text: trimmed, attachments: attachments)
        turns.append(yours)
        recordHistory(yours)
        let streaming = Turn(role: .moe, text: "", isStreaming: true)
        streamingTurnID = streaming.id
        turns.append(streaming)
        mode = .thinking
        statusLine = "thinking"
        workingStep = nil
        workingSince = Date()
        armReply()
        startProgressNarration()
        acknowledgeNow(trimmed)
        pointParser = PointTagParser()
        pointer.hide()
        // A question asked quietly mid-meeting gets the live transcript
        // behind it, so "what did they just say" is answered from what was
        // heard, not guessed. The user's words stay the last thing the
        // model reads.
        let context = liveTranscriptContext
        let base = context.isEmpty ? trimmed : """
        (You are in a meeting with the user; the live transcript so far is below, \
        newest last. Answer their question from it, briefly. Your reply is shown, \
        not spoken, while the meeting is being recorded.)

        <live-transcript>
        \(context)
        </live-transcript>

        \(trimmed)
        """
        // A typed turn says so, so the model writes for a reader: markdown,
        // lists, links, and the length the question needs, instead of the one
        // or two spoken sentences the rest of the prompt asks for. In the
        // user message rather than the system prompt on purpose — see
        // `BrainPrompt.typedTurnMarker`.
        //
        // Never during a meeting: the meeting block above already tells the
        // model its reply is shown and not spoken, and says it in more detail
        // than this does. Two instructions about the same thing is how one of
        // them gets ignored.
        let readable = origin == .typed && config.typedRepliesReadAsText && context.isEmpty
        var shaped = readable ? BrainPrompt.typedTurnMarker + "\n\n" + base : base
        // The delivery rules ride with every turn, not once at spawn. They
        // used to live at the end of the system prompt, which Hermes bakes
        // into its child when it starts — so by turn ten they were forty
        // kilobytes and ten turns behind the words they govern, and the
        // measurement said so: 42 of 44 turns with three or more tool calls
        // ran silent to the end. Constant text, so it does not respawn the
        // child the way a changing brief would.
        //
        // In full once per brain session, then the short form: the full text
        // stays in the transcript, and forty copies of it were the context
        // (see `BrainPrompt.deliveryReminderShort`).
        shaped += "\n\n" + deliveryReminderLedger.reminder(for: bridge.currentSessionID)
        // How much to say, when the person has chosen something other than
        // the default. After the reminder so it is the last word on length,
        // and never in a meeting, whose block already says "briefly".
        if context.isEmpty, let length = ReplyLength(configValue: config.replyLength).turnLine(readable: readable) {
            shaped += "\n\n" + length
        }
        // And so does the brief, for a harder reason than the rules above:
        // a system prompt that changes does not just get buried, it restarts
        // the model. `BrainPrompt.briefBlock()` has the measurement. Read
        // fresh here, so what the model sees is never older than the file —
        // where the system prompt only ever held whatever the brief said when
        // the child was last spawned.
        //
        // Whole the first time a session sees it; after that only the parts
        // whose words changed, and nothing when only `sync.sh`'s stamps moved
        // (`BriefLedger`). Sending it unconditionally was the first version
        // of this: 8.8 KB per turn, kept in the transcript, so turn ten
        // carried ten copies. Sending it whole "when it changed" was the
        // second, and it changes every ten minutes by its timestamp alone:
        // 288 whole copies over 1,325 measured turns, 16% of what those
        // conversations re-read on every turn after.
        if let text = try? String(contentsOf: Paths.brief, encoding: .utf8) {
            let block: String?
            switch briefLedger.next(brief: text, session: bridge.currentSessionID) {
            case .nothing:          block = nil
            case .full(let all):    block = BrainPrompt.briefBlock(all)
            case .update(let some): block = BrainPrompt.briefUpdateBlock(some)
            }
            if let block {
                // Sent with its age: the brief's times are as of when sync.sh
                // wrote it, and the Now line at the top of this turn is the
                // clock (ticket #9).
                shaped = BrainPrompt.dated(block, gathered: BrainPrompt.briefWrittenAt(),
                                           now: TurnClock.now(), zone: TurnClock.zone())
                    + "\n\n---\n\n" + shaped
            }
        }
        // A restarted brain is told what it missed *with* the question, not
        // in a message before it. Order is preserved — the note reads first.
        if let staged = stagedContext {
            stagedContext = nil
            shaped = staged + "\n\n---\n\n" + shaped
        }
        // The answer to a nudge: the card's words and its handle in front of
        // what was typed, so the model knows what "stop reminding me" is
        // about. The note reads first, the person's words last.
        if let replying = nudgeReplyNote {
            nudgeReplyNote = nil
            shaped = replying + "\n\n---\n\n" + shaped
            // An inbox item they opened a reply to is answered now.
            if let id = replyingTo { replyingTo = nil; answeredNotice(id, with: text) }
        }
        // Where the last reply was cut off, if it was: the model must not
        // believe the user heard the half it never said.
        // `outgoing` overrides what the brain is sent while `text` stays what
        // the person sees: a finished helper's turn shows one line in the
        // chat and hands the brain the result with instructions.
        let outgoing = outgoingOverride ?? (note + shaped)
        // An offer's send request running now (not when it was queued): the
        // send gate asks for it however this conversation was granted.
        offerRequestRuns(outgoing)
        // The screenshot from the key-down, if this turn has one (typed
        // turns and dictation never do). It is still encoding for a few
        // tens of milliseconds after a press; wait for it here rather than
        // send the words without their picture.
        // A picture costs about 2.5 s of time-to-first-token (measured on the
        // local gateway: the same question warm answered in 0.78 s and 2.86 s
        // without one, 3.37 s and 5.36 s with). Over 217 real spoken turns
        // from the log, five in six never referred to the screen at all, and
        // every one of them was paying it. Send it when the words point at
        // the display; otherwise the model still has `computer_use capture`
        // if it turns out it needed to look.
        let wantsScreen = ScreenContext.mightBeAboutTheScreen(trimmed)
        if !wantsScreen {
            screen.discard()
            // Logged, so the rule can be judged on real turns rather than on
            // the 217 it was written against.
            if screen.enabled { Log.write("screen: not asked about — no picture sent") }
        }

        let pictureCandidates = Array(attachments.filter { $0.kind == .image }
            .prefix(ChatAttachment.pictureLimit))

        Task { [weak self] in
            guard let self else { return }
            let capture = wantsScreen ? await self.screen.take() : nil
            // Photos are decoded and shrunk off the main thread: a HEIC
            // straight off an iPhone is 12 MP, and the model reads 1568 px.
            let pictures = await AttachmentIntake.pictures(for: pictureCandidates)
            // A reset or a new conversation while the capture was still
            // encoding already threw this turn away; don't send it into
            // the fresh session.
            guard self.awaitingReply, self.streamingTurnID == streaming.id else { return }
            self.lastCapture = capture
            if let capture { Log.write("screen: attached \(capture.summary)") }
            var images = capture.map { [$0.attachment] } ?? []
            images += pictures.map(\.image)
            // Every file is named to the model by path — it is on this Mac —
            // and the ones that decoded are also said to be pictures it can see.
            let note = ChatAttachment.brainNote(attachments, pictured: Set(pictures.map(\.id)))
            if !attachments.isEmpty {
                Log.write("attachments: \(attachments.count) sent, \(pictures.count) as pictures")
            }
            // Logged as the person's own words. `outgoing` also carries the
            // brief, the delivery rules and any interruption note — none of
            // which anybody said, and all of which made the log unreadable.
            let logged = attachments.isEmpty ? trimmed
                : "\(trimmed) [+\(attachments.count) attached]".trimmingCharacters(in: .whitespaces)
            self.bridge.send(note.isEmpty ? outgoing : note + "\n\n" + outgoing,
                             images: images, silent: false, logAs: logged, starter: starter,
                             // Said aloud by the person, who is now waiting to
                             // hear something: the brain may open it quickly.
                             // Never a typed turn, never one Moe raised itself.
                             spoken: origin == .spoken && starter == .person
                                 && self.config.spokenTurnsOpenQuick)
        }
    }

    /// Start a fresh thread. The one on screen is filed, not destroyed —
    /// this used to be `turns.removeAll()` and nothing else, which made ⌘N
    /// silent, permanent data loss.
    func newConversation() {
        dropQueued()
        saveConversation()
        grantWatch.cancelAll("a new conversation")
        fixesByPane = [:]
        panesOpened = [:]
        awaitingReply = false
        replySignal.abandoned()
        replyAbandoned = true      // a delta already queued must not seed the new thread
        interruptionNote = nil
        interruptedHeard = nil
        stagedContext = nil
        voice.stopAll()
        partial = ""
        turns.removeAll()
        // The transcript that held the warning is gone, so the warning is
        // gone. Without this, "you are nearly out" is said once for the life
        // of the app: the engine re-emits the identical sentence every turn,
        // the de-duplication swallows all of them, and a fresh conversation
        // shows nothing until the percentage happens to change. Going quiet
        // is the one failure this feature exists to prevent.
        lastNotice = ""
        conversationID = UUID().uuidString
        conversationStartedAt = Date()
        streamingTurnID = nil
        spokenUpTo = ""
        connected = false
        restartAttempts = 0
        lastStartAt = Date()
        mode = .idle
        statusLine = "starting a fresh conversation"
        applyChatBrain()
        // Like reset(), but on the session id this thread will keep — so
        // reopening it later resumes rather than replays.
        bridge.resume(conversationLedger.resume(
            thread: conversationID, brain: bridge.brainFingerprint,
            startedAt: conversationStartedAt))
    }

    /// The island's panel is showing (peek or open), as `NotchIsland` last
    /// applied it.
    var islandOpen = false

    /// An hour untouched: file this conversation in Chat and start a fresh
    /// one, so the next question does not re-send the whole thread
    /// (`ConversationFreshness`). Checked on the minute by the presence
    /// timer, against the wall clock, so it holds across sleep. The fresh
    /// session's warm-up runs now, while nobody waits on it.
    func startFreshIfIdle() {
        let busy = awaitingReply || mode != .idle || inConversation || dictation != .off
            || meeting.isRecording || replyingTo != nil || noticeReturn != nil
            || queuedTyped != nil || !partial.isEmpty
        let situation = ConversationFreshness.Situation(
            lastActivity: turns.last?.at, now: Date(), busy: busy,
            watched: islandOpen || NSApp.isActive)
        guard ConversationFreshness.shouldStartFresh(situation) else { return }
        let idle = Int(Date().timeIntervalSince(turns.last?.at ?? Date()) / 60)
        Log.write("conversation: untouched \(idle) min; filed in Chat, starting a fresh one")
        newConversation()
    }

    // MARK: - A turn Moe was closed on

    private var leftoverTurnChecked = false

    /// A Moe quit — or killed — while answering left `~/.moe/turns/
    /// inflight.json` behind (`TurnKeeper`; `HermesBrain.stop` keeps it on
    /// purpose). On the first `.ready` after launch, if that record is
    /// recent and belongs to the thread now on screen, the ask goes again
    /// with a note saying why. The record is consumed first, so this happens
    /// once whatever comes of it. A record for another thread, or an old
    /// one, is dropped: an answer to a question from another conversation,
    /// or from an hour ago, arriving unasked is noise.
    private func pickUpLeftoverTurn() {
        guard !leftoverTurnChecked else { return }
        leftoverTurnChecked = true
        guard let record = TurnKeeper.leftover(TurnKeeper.read()) else {
            TurnKeeper.clear()
            return
        }
        TurnKeeper.clear()
        // The record names its conversation; the session id it also carries
        // is derived per process and is different in every launch, so it
        // was never the thing to compare (this compared it, and never once
        // matched — review, 2026-09-18). Open the thread first: that resumes
        // the brain on the session derived from it, priming and all, and the
        // pickup queues behind the priming like any turn.
        guard !record.thread.isEmpty, conversationStore.load(id: record.thread) != nil else {
            Log.write("turn keeper: a turn was left on a thread this Mac no longer has; not picked up")
            return
        }
        let words = record.logAs ?? record.text
        let go = { [self] in
            Log.write("turn keeper: picking up a turn Moe was closed on: \(words.prefix(80))")
            openConversation(id: record.thread)
            turns.append(Turn(role: .system, text: "Picking up where Moe left off."))
            // The chat shows the person's words again; the brain gets exactly
            // what it was sent the first time (brief, rules and all), behind
            // the note that says why it is seeing it twice.
            // `.background`: this can go out long after the crash, with nobody at the Mac.
            submit(words, origin: .typed, starter: .background, outgoing: TurnKeeper.relaunchNote + "\n\n" + record.text)
        }
        guard !record.task.isEmpty else { go(); return }
        // Who holds it now? Moe may have been closed for long enough that
        // the cloud took the ask; then the answer is on its way and a second
        // one from here would be the doubled work the whole design refuses.
        // (`CloudLink.mayResume` closes the old ask with `reissued` before
        // saying yes: the re-issue gets a fresh id, and a row left `claimed`
        // by this Mac for a day would read as an ask still running.)
        cloud.mayResume(task: record.task, thread: record.thread) { [weak self] mayResume in
            guard let self else { return }
            if mayResume {
                go()
            } else {
                Log.write("turn keeper: the cloud holds the ask Moe was closed on; not picked up here")
                self.turns.append(Turn(role: .system, text: "Moe carried on with your last question in the "
                                       + "cloud while it was closed. The answer lands on the chat you last "
                                       + "spoke to Moe from."))
            }
        }
    }

    // MARK: - Conversations

    /// Which thread is on screen, so the session list can mark it.
    var currentConversationID: String { conversationID }

    /// Every saved thread, newest activity first. For the Chat session list.
    func conversations(matching query: String = "") -> [ConversationStore.Conversation] {
        conversationStore.search(query)
    }

    /// The buttons under a turn (`ReplyActions`): only on the newest one,
    /// and none while Moe is working on something.
    func actions(for turn: Turn) -> [ReplyAction] {
        guard !isWorking else { return [] }
        return ReplyActions.of(text: turn.text, isAnswer: turn.role == .moe && !turn.isStreaming,
                               failed: turn.failed, latest: turns.last?.id == turn.id)
    }

    /// Send and Yes: the person's own answer, as a turn, so anything that
    /// goes out still meets the send gate's confirmation.
    func answer(_ action: ReplyAction) {
        guard let words = action.words else { return }
        submit(words, origin: .typed, starter: .person)
    }

    /// Retry under an error: the question that failed, asked again. The
    /// note goes; your message is sent again as the same message, under
    /// the id the history already knows it by, so the thread does not
    /// gain a copy of it.
    func retry(failed id: UUID) {
        guard !isWorking, let at = turns.firstIndex(where: { $0.id == id && $0.failed }),
              let askedAt = turns[..<at].lastIndex(where: { $0.role == .you }) else { return }
        let asked = turns[askedAt]
        turns.remove(at: at)
        turns.remove(at: askedAt)
        submit(asked.text, origin: .typed, starter: .person, attachments: asked.attachments)
        if let again = turns.lastIndex(where: { $0.role == .you }), turns[again].text == asked.text {
            turns[again].storedID = asked.storedID ?? asked.id.uuidString
        }
    }

    // MARK: Model per chat

    /// The model this chat is set to, when it is not the default (the
    /// owner's answer 9): kept per thread, on the provider it was chosen
    /// from, and gone back to the default when the provider changes.
    @Published private(set) var chatModel: String?

    /// The brain for the conversation on screen: the person's choice in
    /// Settings, with this chat's own model when it has one.
    func chatSelection() -> BrainSelection {
        var s = BrainSelection(config: config)
        if let model = conversationStore.marks()[conversationID]?.model(on: s.provider.rawValue) {
            s.model = model
        }
        return s
    }

    /// The models the person's own provider offers, for the chat's picker:
    /// that provider's list (`BrainProviderKind.curatedModels`, the same one
    /// Settings › Brain offers), with the default and this chat's model
    /// always in it. A custom or local endpoint has no list, so it offers
    /// only what is set.
    var chatModelChoices: [String] {
        var ids = config.brainProvider.curatedModels
        for m in [chatModel, config.brainModel].compactMap({ $0 }) where !m.isEmpty && !ids.contains(m) {
            ids.insert(m, at: 0)
        }
        return ids
    }

    /// The default model's id, as Settings › Brain has it.
    var defaultChatModel: String { config.brainModel }

    /// What the picker says about a model, from the provider's own captions.
    func chatModelCaption(_ id: String) -> String { config.brainProvider.modelCaption(id) }

    /// Set this chat's model; nil or the default goes back to the default.
    func setChatModel(_ model: String?) {
        let pick = model.flatMap { $0 == config.brainModel || $0.isEmpty ? nil : $0 }
        do { try conversationStore.setModel(pick, provider: config.brainProvider.rawValue, for: conversationID) }
        catch { Log.write("conversations: could not set the model: \(error.localizedDescription)") }
        let before = bridge.brainFingerprint
        applyChatBrain()
        if bridge.brainFingerprint != before {
            // The same conversation, on a session of the new model's — what
            // a model change in Settings does, for this chat only.
            settleForBrainChange()
            bridge.resume(conversationLedger.resume(
                thread: conversationID, brain: bridge.brainFingerprint,
                knownTurns: storedTurns(), startedAt: conversationStartedAt))
        }
    }

    /// Hand the brain this chat's selection. Before every resume onto a
    /// thread, since the session id is derived from the thread and the model.
    private func applyChatBrain() {
        let s = chatSelection()
        chatModel = s.model == config.brainModel ? nil : s.model
        bridge.apply(brain: s)
        chatForgets = conversationStore.marks()[conversationID]?.forget ?? false
        bridge.remember(!chatForgets)
        screen.enabled = config.screenContext
            && (chatModel == nil ? brainSupportsVision : s.provider.capabilities(for: s.model).mayAttachImages)
    }

    // MARK: Don't remember this chat

    /// The chat on screen is one the person asked not to be remembered:
    /// every turn of it goes as `X-Hermes-No-Memory`, so nothing in it is
    /// learned or written to memory, and it is never tagged.
    @Published private(set) var chatForgets = false

    /// Turn "Don't remember this chat" on or off for the chat on screen.
    /// From the next turn: what was already learned stays, and the Memory
    /// page is where to take it out.
    func setChatForgets(_ forget: Bool) {
        do { try conversationStore.setForget(forget, for: conversationID) }
        catch { Log.write("conversations: could not set don't-remember: \(error.localizedDescription)") }
        chatForgets = conversationStore.marks()[conversationID]?.forget ?? false
        bridge.remember(!chatForgets)
        NotificationCenter.default.post(name: .moeConversationsChanged, object: nil)
    }

    /// Pinned and archived, for the Chat list.
    func conversationMarks() -> [String: ConversationStore.Marks] { conversationStore.marks() }

    func pinConversation(id: String, _ pinned: Bool) {
        do { try conversationStore.setPinned(pinned, for: id) }
        catch { Log.write("conversations: could not pin: \(error.localizedDescription)") }
    }

    func archiveConversation(id: String, _ archived: Bool) {
        do { try conversationStore.setArchived(archived, for: id) }
        catch { Log.write("conversations: could not archive: \(error.localizedDescription)") }
    }

    /// A name you gave a thread. It takes the place of the AI's, which is
    /// never asked for again once a thread has one.
    func renameConversation(id: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        storeTitle(String(clean.prefix(80)), for: id)
    }

    /// Reopen an earlier thread: its turns come back on screen, and anything
    /// said from here is appended to it.
    ///
    /// The brain follows. The thread's session id is derived from the thread,
    /// so a session Hermes still holds simply continues; a thread it has
    /// never served — every thread older than the ledger — is sent to it
    /// first, as its own memory of the conversation rather than as a
    /// transcript. See MoeLedger's `BrainResume` and docs/ONE-AGENT.md §2.4.
    func openConversation(id: String) {
        guard id != conversationID else { return }
        guard let convo = conversationStore.load(id: id) else { return }
        saveConversation()
        grantWatch.cancelAll("another conversation was opened")
        fixesByPane = [:]
        panesOpened = [:]

        awaitingReply = false
        replySignal.abandoned()
        replyAbandoned = true
        interruptionNote = nil
        interruptedHeard = nil
        stagedContext = nil
        voice.stopAll()
        partial = ""
        streamingTurnID = nil
        spokenUpTo = ""
        mode = .idle

        conversationID = convo.id
        conversationStartedAt = convo.startedAt
        turns = convo.turns.map {
            Turn(role: Self.role(from: $0.role), text: $0.text,
                 at: $0.at, tools: $0.tools ?? [], storedID: $0.id,
                 attachments: $0.attachments ?? [])
        }
        statusLine = ""
        applyChatBrain()
        bridge.resume(conversationLedger.resume(
            thread: convo.id, brain: bridge.brainFingerprint,
            knownTurns: convo.turns, startedAt: convo.startedAt))
    }

    func deleteConversation(id: String) {
        // Through the ledger, or the next projection would bring it back.
        try? conversationLedger.delete(id: id)
        // And the wrapped copies of its key this Mac left at the edge, so a
        // device that has not collected them yet never does. The tombstone
        // itself travels with the next push.
        cloud.threadDeleted(id)
        cloud.ledgerSaved()
        // Deleting the thread you are looking at leaves you on a fresh one
        // rather than on turns with nowhere to be saved.
        if id == conversationID {
            turns.removeAll()
            conversationID = UUID().uuidString
            conversationStartedAt = Date()
            // And take the brain off the deleted thread's session, or the
            // next thing said continues the conversation you just deleted.
            applyChatBrain()
            bridge.resume(conversationLedger.resume(
                thread: conversationID, brain: bridge.brainFingerprint,
                startedAt: conversationStartedAt))
        }
    }

    /// File the current thread. Called on every finished turn and on the way
    /// out — an app that is force-quit should still have yesterday's threads.
    ///
    /// `delivered` says a reply has just come back, which is the brain
    /// confirming it holds this thread; without it nothing is recorded as
    /// told. `flush` waits for the write, which only the way out needs.
    func saveConversation(delivered: Bool = false, flush: Bool = false) {
        let stored = storedTurns()
        let convo = ConversationStore.Conversation(
            id: conversationID, startedAt: conversationStartedAt,
            updatedAt: Date(), turns: stored)
        // Record first, project second: a crash between the two costs the
        // file, which the projector rebuilds, never the fact. Off this
        // thread, because the work grows with the length of the history.
        conversationLedger.save(convo, session: delivered ? bridge.currentSessionID : "",
                                flush: flush) { error in
            Log.write("conversations: save failed: \(error.localizedDescription)")
        }
        // The cloud, if this Mac has one, gets whatever that wrote — after
        // it, off this thread, coalesced with whatever else is saved soon.
        cloud.ledgerSaved()
        if delivered {
            nameIfNeeded(id: conversationID, turns: stored)
            tagIfNeeded(id: conversationID, turns: stored)
        }
    }

    /// Chats whose tagging call failed this launch: not asked again until the
    /// next, so a provider that is down costs one call a chat, not one a turn.
    private var tagTried: Set<String> = []

    /// The one tagging call (`TitleNamer.tag`); a test stands in its own.
    typealias TagCall = (_ thread: String, _ exchanges: [(you: String, answer: String)],
                         _ existing: [String], _ done: @escaping ([String]?, Bool) -> Void) -> Void
    lazy var tagCall: TagCall = { [unowned self] thread, exchanges, existing, done in
        self.titleNamer.tag(thread: thread, exchanges: exchanges, existing: existing, done: done)
    }

    /// Tag a chat once it has `TagRules.minExchanges` answered exchanges:
    /// one call at the cheapest model of the person's provider, never
    /// repeated (`Marks.tagged`), never for a chat marked "Don't remember
    /// this chat".
    func tagIfNeeded(id: String, turns: [ConversationStore.StoredTurn]) {
        let marks = conversationStore.marks()
        let mark = marks[id] ?? .init()
        let exchanges = TagRules.exchanges(of: turns)
        guard !tagTried.contains(id),
              TagRules.wants(forget: mark.forget, tagged: mark.tagged,
                             answeredExchanges: exchanges.count) else { return }
        tagTried.insert(id)
        tagCall(id, exchanges, TagRules.vocabulary(marks)) { [weak self] tags, answered in
            guard let self, answered || tags != nil else { return }
            do {
                // Marked "Don't remember this chat" while the call was out:
                // `setTags` keeps it untagged.
                try self.conversationStore.setTags(tags ?? [], for: id)
                Log.write("tags: \(id.prefix(8)) \((tags ?? []).joined(separator: ", "))")
                NotificationCenter.default.post(name: .moeConversationsChanged, object: nil)
            } catch {
                Log.write("tags: could not save: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Edit and resend

    /// Whether `id` is one of your messages that can be changed and sent
    /// again: not while Moe is working, and not a message still waiting.
    func canEdit(_ id: UUID) -> Bool {
        !isWorking && turns.contains { $0.id == id && $0.role == .you }
    }

    /// Change one of your messages and send it again (the owner's answer,
    /// 2026-11-13: a fresh session, no fork). The chat is cut at that message
    /// and goes on as a new thread: the turns before it are carried over and
    /// told to a fresh brain session the way reopening an old chat tells
    /// them, the old thread is deleted through the ledger — a `thread.delete`
    /// every device already honours, Away and the edge included, and its key
    /// destroyed — and the changed message is sent. Its name, pin, model,
    /// "Don't remember" and tags carry over. The only records written are
    /// the two kinds every device already reads: turns and a thread delete.
    func resend(editing id: UUID, to text: String, attachments: [ChatAttachment]? = nil) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(id), let at = turns.firstIndex(where: { $0.id == id }),
              !words.isEmpty || !(attachments ?? turns[at].attachments).isEmpty else { return }
        let files = attachments ?? turns[at].attachments
        let old = conversationID
        saveConversation(flush: true)

        grantWatch.cancelAll("a message was edited")
        awaitingReply = false
        replySignal.abandoned()
        replyAbandoned = true
        interruptionNote = nil
        interruptedHeard = nil
        stagedContext = nil
        voice.stopAll()
        partial = ""
        streamingTurnID = nil
        spokenUpTo = ""
        mode = .idle

        turns.removeSubrange(at...)
        let kept = storedTurns()
        let new = UUID().uuidString
        do { try conversationStore.carrySideEntries(from: old, to: new) }
        catch { Log.write("conversations: could not carry the chat's name and marks: \(error.localizedDescription)") }
        conversationID = new
        applyChatBrain()
        // A thread the ledger has never seen: `resume` records the kept turns
        // into it and primes a fresh session with them.
        bridge.resume(conversationLedger.resume(
            thread: new, brain: bridge.brainFingerprint,
            knownTurns: kept, startedAt: conversationStartedAt))
        try? conversationLedger.delete(id: old)
        cloud.threadDeleted(old)
        cloud.ledgerSaved()
        Log.write("conversations: \(old.prefix(8)) edited at turn \(at); continues as \(new.prefix(8)) with \(kept.count) turn(s)")
        NotificationCenter.default.post(name: .moeConversationsChanged, object: nil)
        submit(words, origin: .typed, starter: .person, attachments: files)
    }

    /// Take a tag off a chat, from the list's menu.
    func removeConversationTag(_ tag: String, id: String) {
        try? conversationStore.removeTag(tag, for: id)
        NotificationCenter.default.post(name: .moeConversationsChanged, object: nil)
    }

    /// The turns on screen, as the thread's file keeps them.
    private func storedTurns() -> [ConversationStore.StoredTurn] {
        turns.compactMap { turn -> ConversationStore.StoredTurn? in
            guard !turn.text.trimmingCharacters(in: .whitespaces).isEmpty || !turn.attachments.isEmpty
            else { return nil }
            return ConversationStore.StoredTurn(
                id: turn.storedID ?? turn.id.uuidString, role: Self.role(from: turn.role),
                text: turn.text, at: turn.at,
                tools: turn.tools.isEmpty ? nil : turn.tools,
                attachments: turn.attachments.isEmpty ? nil : turn.attachments)
        }
    }

    /// Give a thread its short AI name once Moe has answered in it
    /// (`TitleRules`, `TitleNamer`), and tell the Chat list.
    private func nameIfNeeded(id: String, turns: [ConversationStore.StoredTurn]) {
        let first = turns.first(where: { $0.role == .you && !$0.text.isEmpty })?.text
        let answered = turns.contains { $0.role == .moe && !$0.text.isEmpty }
        guard TitleRules.wants(hasTitle: conversationStore.titles()[id] != nil,
                               firstMessage: first, answered: answered),
              let first else { return }
        titleNamer.name(thread: id, firstMessage: first) { [weak self] title in
            guard let self, let title else { return }
            self.storeTitle(title, for: id)
        }
    }

    private func storeTitle(_ title: String, for id: String) {
        do {
            try conversationStore.setTitle(title, for: id)
            Log.write("titles: named \(id.prefix(8)) \"\(title)\"")
            NotificationCenter.default.post(name: .moeConversationsChanged, object: nil)
        } catch {
            Log.write("titles: could not save a name: \(error.localizedDescription)")
        }
    }

    /// The Chat list opened: name up to twenty of the newest threads that have
    /// none yet, one after another — never twenty calls at once.
    func nameUntitledConversations() {
        guard !titleBackfillStarted else { return }
        titleBackfillStarted = true
        let names = conversationStore.titles()
        titleBackfill = conversationStore.all().prefix(20).compactMap { convo in
            guard names[convo.id] == nil,
                  convo.turns.contains(where: { $0.role == .moe && !$0.text.isEmpty }),
                  let first = convo.turns.first(where: { $0.role == .you && !$0.text.isEmpty })?.text
            else { return nil }
            return (convo.id, first)
        }
        nameNextInBackfill()
    }

    private func nameNextInBackfill() {
        guard !titleBackfill.isEmpty else { return }
        let next = titleBackfill.removeFirst()
        titleNamer.name(thread: next.id, firstMessage: next.first) { [weak self] title in
            guard let self else { return }
            if let title { self.storeTitle(title, for: next.id) }
            self.nameNextInBackfill()
        }
    }

    /// Records another device wrote have been applied and re-projected.
    ///
    /// The list refreshes through `.moeConversationsChanged`. The thread on
    /// screen is reloaded from its file only when nothing is in flight here:
    /// a reply mid-stream must not be replaced by a projection that does not
    /// have it yet, and the next save will reconcile the two anyway.
    func threadsArrived(_ threads: [String]) {
        NotificationCenter.default.post(name: .moeConversationsChanged, object: nil)
        guard threads.contains(conversationID), !awaitingReply, mode == .idle,
              let convo = conversationStore.load(id: conversationID)
        else { return }
        let shown = turns.filter {
            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty || !$0.attachments.isEmpty
        }
        let projected = convo.turns.map {
            Turn(role: Self.role(from: $0.role), text: $0.text, at: $0.at,
                 tools: $0.tools ?? [], storedID: $0.id, attachments: $0.attachments ?? [])
        }
        // Only when the other device added something: the same turns in the
        // same order are the projection of what is already on screen.
        guard projected.count > shown.count,
              zip(projected, shown).allSatisfy({ $0.text == $1.text && $0.role == $1.role })
        else { return }
        turns = projected
    }

    /// The relay dial's inputs moved. `RelayTrigger` holds the decision and
    /// the reasoning; this is the wiring to the gateway Moe actually owns.
    func relayDialMayHaveMoved(_ why: String) {
        RelayTrigger.dialMayHaveMoved(why) { [weak self] reason in
            (self?.bridge as? HermesBrain)?.reloadGateway(reason: reason)
        }
    }

    /// Re-run configure-hermes and come back when it has finished — for the
    /// one caller that must not proceed until `.env` is current: the
    /// Connections screen, after a sign-in has just put a Composio key in the
    /// Keychain (CLOUD-PLAN §19.11). Serialised with every other run by
    /// `RelayTrigger`; if one is in flight this waits for the coalesced re-run.
    func reconfigureHermes(_ why: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RelayTrigger.dialMayHaveMoved(why, reload: { [weak self] reason in
                (self?.bridge as? HermesBrain)?.reloadGateway(reason: reason)
            }, done: { continuation.resume() })
        }
    }

    /// `done(true)` once a gateway of Moe's own is up — the only state in
    /// which `HermesUpgrade` may rewrite the tree it runs from and then
    /// restart it. A brain that is not Hermes has no such gateway: `false`.
    /// Main thread.
    func whenOwnGatewayUp(_ done: @escaping (Bool, String) -> Void) {
        guard let hermes = bridge as? HermesBrain else { done(false, "the brain is not Hermes"); return }
        hermes.whenOwnGatewayUp(done)
    }

    /// Something the gateway reads only at boot has changed under it — the
    /// checkout it runs from, after `HermesUpgrade` moved it. Same restart
    /// the relay dial uses; a no-op for a brain that is not Hermes. Main thread.
    func reloadGateway(reason: String) {
        (bridge as? HermesBrain)?.reloadGateway(reason: reason)
    }

    private static func role(from role: Turn.Role) -> ConversationStore.StoredTurn.Role {
        switch role {
        case .you: return .you
        case .moe: return .moe
        case .system: return .system
        }
    }

    private static func role(from role: ConversationStore.StoredTurn.Role) -> Turn.Role {
        switch role {
        case .you: return .you
        case .moe: return .moe
        case .system: return .system
        }
    }

    // MARK: - Meetings

    /// The explicit action — menu item, hotkey, spoken command. Recording:
    /// stops. Off: asks first (Settings › Meetings, on by default), then
    /// starts. Never starts on its own.
    /// The model's marker, acted on. Everything a meeting needs still
    /// happens here — the consent sheet when the user has it on, the ring,
    /// the recorder — so a paraphrase reaches the same machinery the menu
    /// item does. What it never does is start a second recording over one
    /// already running, or stop one that is not.
    private func handleMeetingMarker(_ marker: MeetingIntent.Marker) {
        switch marker.intent {
        case .start:
            guard !meeting.isRecording else {
                turns.append(Turn(role: .system, text: "Already recording — \(meetingClock) so far."))
                return
            }
            Log.write("meeting: start asked for by the model's marker")
            requestMeeting()
        case .stop:
            guard meeting.isRecording else {
                turns.append(Turn(role: .system, text: "No meeting is being recorded."))
                return
            }
            Log.write("meeting: stop asked for by the model's marker")
            stopMeeting()
        case .repeatLast:
            break
        }
    }

    func requestMeeting() {
        switch meeting {
        case .recording: stopMeeting()
        case .starting, .stopping: break
        case .off, .done:
            guard let ask = onMeetingConsent else {
                Log.write("meeting: no consent handler; refusing to start")
                return
            }
            if config.meetingAskBeforeStart {
                meeting = .starting
                ask { [weak self] yes in
                    guard let self else { return }
                    if yes { self.startMeeting() } else { self.meeting = .off }
                }
            } else {
                startMeeting()
            }
        }
    }

    /// Menu title: "Start meeting" or "● Recording 12:34 · Stop".
    var meetingMenuTitle: String {
        switch meeting {
        case .recording:
            let state = meetingPaused ? "Off the record" : "Recording"
            return "● \(state) \(meetingClock)" + (meetingHealth.isEmpty ? "" : " · \(meetingHealth)") + " · Stop"
        case .starting: return "Starting meeting…"
        case .stopping: return "Writing your notes…"
        case .off, .done: return "Start meeting"
        }
    }

    private func startMeeting() {
        meeting = .starting
        meetingStatus = ""
        meetingTimeline = []
        meetingOutcome = nil
        meetingHealth = ""
        meetingTapFault = nil
        // A meeting's brain sessions are its own. Without this the action
        // scan opens its first call still holding the last meeting's hour
        // of transcript — slower, and a way for one meeting's content to
        // turn up in another's notes.
        meetingBrains = [:]
        meetingBrainID = UUID().uuidString.lowercased()
        meetingPaused = false
        meetingBookmarks = 0
        meetingLiveActions = []
        meetingCatchUp = nil
        meetingMention = nil
        meetingDelivery = ""
        meetingScanCursor = LiveCursor()
        meetingMentionCursor = 0
        meetingAway = CatchUp()
        meetingOwnerName = MeetingSession.ownerName()
        meetingCaptures = []
        meetingClip = false
        meetingCaptureStatus = ""
        captureScheduler = CaptureScheduler()
        captureCueCursor = 0
        // A caption that hung in the last meeting must not leave this one
        // unable to take a screenshot; a refusal warned about then is worth
        // saying once more if it is still refused now.
        captureBusy = false
        capturePermissionWarned = false
        meetingOffer = nil
        meetingEndOffer = nil
        offerTimer?.invalidate(); offerTimer = nil
        // Started by hand while a call is on: the detector must not offer
        // that same call a moment later. Whether the offer was taken or
        // the menu used, the meeting is now accounted for.
        if meetingCallApp == nil { meetingCallApp = watcher?.current }
        watcher?.acknowledge()
        Task { [weak self] in
            guard let self else { return }
            // The mic grant first, the way every other capture does; the
            // System Audio Recording prompt comes from the tap itself.
            guard await VoiceEngine.requestMicrophone() else {
                self.meeting = .off
                self.onMeetingProblem?("Moe can't record the meeting: microphone access is off. "
                                       + "Turn it on in System Settings › Privacy & Security › Microphone.", false)
                return
            }
            // One engine on the microphone: take the voice's down (wake-word
            // standby included) before the meeting's goes up, and keep it
            // down for the whole meeting. Attaching here rather than at the
            // first whisper is the point: until this, `speak` (a nudge, the
            // voice preview in Settings) and `startListening` would happily
            // build a second AVAudioEngine on the input device the meeting
            // already owns.
            self.quietVoiceForMeeting()
            self.voice.attachExternalInput()
            let asr = SpeechModels(router: self.voice.stt, locale: self.config.locale)
            let session: MeetingSession
            do {
                session = try MeetingSession(base: Paths.meetings, asr: asr, diarizer: FluidDiarizer())
                session.onTimeline = { [weak self] segments in
                    self?.meetingTimeline = segments
                    self?.noticeMentions(in: segments)
                    self?.noticeCaptureCues(in: segments)
                }
                session.onHealth = { [weak self] line in self?.meetingHealth = line }
                // Nothing could bring the call audio back. This is not one
                // status line among status lines — it is the difference
                // between a transcript of a conversation and a transcript
                // of one person talking to themselves — so it takes the
                // island's notice bar and stays until it is dismissed.
                session.onTapDead = { [weak self] in
                    guard let self else { return }
                    self.meetingTapFault = TapWatch.deadNotice
                    self.onWantsIsland?(true)
                }
                try session.start()
            } catch {
                Log.write("meeting: start failed: \(error)")
                self.meeting = .off
                // No meeting, no meeting mic: the voice must not stay muted
                // because a start failed.
                self.voice.detachExternalInput()
                self.restoreVoiceAfterMeeting()
                // Not `\(error)`: that is a Swift value printed raw — an
                // enum case with an OSStatus in it, or an NSError dump —
                // put in a modal in front of somebody who is trying to
                // start a meeting. The log above already has it.
                self.onMeetingProblem?(
                    "Moe couldn't start recording the call's audio. "
                    + "If macOS asked about System Audio Recording and it was declined, allow it "
                    + "under Privacy & Security › Screen & System Audio Recording.", true)
                return
            }
            self.meetingSession = session
            session.callApp = self.meetingCallApp?.name
            let since = session.recorder.epoch
            self.meeting = .recording(since: since)
            // Only now is it once: burning the one-time hint on a meeting
            // that never started (the mic grant refused, the tap failed)
            // meant the user never saw it.
            if !self.config.meetingHintShown {
                self.meetingHint = Self.meetingHintText(self.config.talkKey)
                self.config = Config.update { $0.meetingHintShown = true }
            }
            self.meetingClock = "00:00"
            self.onWantsIsland?(true)
            self.startMeetingClock(since: since)
            self.watchMeetingTap(session)
            self.startMeetingScan()
            self.startMeetingAwayWatch()
            // Who is on the invite (MEETING-MODE.md, Phase B). Last, and off
            // the main thread, because it must not be able to delay or fail a
            // recording: it reads the calendar only if access has already
            // been granted, never prompts, and no event, no attendees or no
            // grant all leave the meeting exactly as it was before.
            let invite = await Task.detached(priority: .utility) { MeetingInvite.invite() }.value
            guard let invite, self.meetingSession === session else { return }
            session.attendees = invite.attendees
            let others = SpeakerNaming.nameable(attendees: invite.attendees,
                                                youName: self.meetingOwnerName).count
            Log.write("meeting: calendar event \u{201C}\(invite.title)\u{201D}, "
                      + "\(others) other \(others == 1 ? "person" : "people") invited")
        }
    }

    // MARK: Minute scan, catch-me-up, mentions

    // The ring used to breathe with the room: a second timer drained the
    // level meters ten times a second and drove the ring's line width and
    // blur. The ring is a consent indicator and is now simply steady red,
    // so that timer is gone — and with it its race with the session's own
    // health tick over one meter. `MeetingSession` is the only drainer now,
    // and the levels it reads go to the log every 15 s.
    //
    // What that race actually was, because the first version of this
    // comment said it halved the audio each drainer saw and that is wrong.
    // `LevelMeter.drain` accumulates and resets: every sample went to
    // exactly one drain and none was lost. What the second drainer took
    // away was any relationship between a reading and a *known* interval —
    // the health tick's one-second window became whatever was left since
    // the ring's last 100 ms drain.
    //
    // It is also the wrong direction to explain "mic silent". The ring's
    // timer called `health.observe` too, so health got eleven readings a
    // second instead of one, each over a shorter window — and a shorter
    // window is louder, because it averages a 100 ms word into less
    // silence. `observe` only ever records that a channel sounded; it never
    // takes it back. More readings, each louder, can only have made the
    // health check *more* likely to see sound. The reason a meeting looked
    // healthy while its windows were being thrown away is the speech gate,
    // not this.

    /// Every two minutes the lines heard since the last time go to Hermes on
    /// the meeting's scan session, on the provider's cheapest model, with a
    /// tiny "any action items?" prompt; the count
    /// shows on the island and the items are confirmed by the summary at
    /// the end. Off with the summarise switch — nothing leaves the Mac then.
    private func startMeetingScan() {
        meetingScanTimer?.invalidate()
        guard config.meetingSummarise else { return }
        let t = Timer(timeInterval: ActionItemScan.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanForActionItems() }
        }
        RunLoop.main.add(t, forMode: .common)
        meetingScanTimer = t
    }

    /// The brain for one of a meeting's jobs, on that job's own session.
    ///
    /// It used to be one brain, cached, for all five — and one brain is one
    /// session is one conversation. The action scan asks "reply with
    /// {actions:…}" sixty times an hour, and by the end the notes request
    /// got answered in the scan's shape: measured at 11.6 s against 64.7 s
    /// on a clean session, which is exactly the fifteen seconds the 16:10
    /// meeting on 2026-09-08 took to fail. See `HermesMeetingBrain`.
    private func liveBrain(_ purpose: HermesMeetingBrain.Purpose) -> HermesMeetingBrain {
        if let b = meetingBrains[purpose] { return b }
        let b = HermesMeetingBrain(config: config, purpose: purpose, meetingID: meetingBrainID)
        meetingBrains[purpose] = b
        return b
    }

    private func scanForActionItems() {
        guard meeting.isRecording, config.meetingSummarise, connected, !meetingScanBusy, !meetingPaused else { return }
        let fresh = meetingScanCursor.take(meetingTimeline)
        guard !fresh.isEmpty else { return }
        meetingScanBusy = true
        let brain = liveBrain(.scan)
        let lines = Timeline.format(fresh)
        Task { [weak self] in
            defer { Task { @MainActor in self?.meetingScanBusy = false } }
            guard let reply = try? await brain.complete(system: ActionItemScan.system, user: ActionItemScan.user(newLines: lines)) else { return }
            let found = ActionItemScan.parse(reply)
            guard !found.isEmpty else { return }
            await MainActor.run {
                guard let self, self.meeting.isRecording else { return }
                let before = self.meetingLiveActions.count
                self.meetingLiveActions = ActionItemScan.merge(self.meetingLiveActions, found)
                if self.meetingLiveActions.count > before {
                    Log.write("meeting: \(self.meetingLiveActions.count) action item(s) so far")
                    self.captureCue(.actionItem)
                }
            }
        }
    }

    /// Away > 3 min (no input, the screen locked, the Mac asleep) and back:
    /// a two-sentence recap of the span, from Hermes on the meeting session.
    private func startMeetingAwayWatch() {
        meetingAwayTimer?.invalidate()
        for o in meetingAwayObservers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        meetingAwayObservers = []
        guard config.meetingSummarise else { return }
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        meetingAwayObservers = [
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.meetingAwayLock() }
            },
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.meetingAway.unlock() }
            },
            wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.meetingAwayLock() }
            },
            wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.meetingAway.unlock() }
            },
        ]
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.meeting.isRecording, let session = self.meetingSession else { return }
                if let span = self.meetingAway.observe(idleSeconds: Self.secondsSinceInput(), at: session.elapsed) {
                    self.catchUp(span)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        meetingAwayTimer = t
    }

    private func meetingAwayLock() {
        guard let session = meetingSession else { return }
        meetingAway.lock(at: session.elapsed)
    }

    /// Seconds since the last keyboard or mouse event, whichever is newest.
    static func secondsSinceInput() -> Double {
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private func catchUp(_ span: CatchUp.Span) {
        guard connected else { return }
        let missed = CatchUp.missed(meetingTimeline, in: span)
        guard !missed.isEmpty else {
            meetingCatchUp = "You were away \(Timeline.clock(span.start))–\(Timeline.clock(span.end)); nothing was said."
            return
        }
        Log.write("meeting: catch-up for \(Timeline.clock(span.start))–\(Timeline.clock(span.end)) (\(missed.count) lines)")
        meetingCatchUp = "Catching you up…"
        let brain = liveBrain(.recap)
        Task { [weak self] in
            let reply = try? await brain.complete(system: CatchUp.system, user: CatchUp.user(missed: missed, span: span))
            await MainActor.run {
                guard let self, self.meeting.isRecording else { return }
                let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.meetingCatchUp = text.isEmpty ? "Couldn't get a recap — the transcript is in the panel." : "While you were away: \(text)"
                self.onWantsIsland?(true)
            }
        }
    }

    func dismissMeetingCatchUp() { meetingCatchUp = nil }
    func dismissMeetingMention() { meetingMention = nil }
    func dismissMeetingHint() { meetingHint = nil }

    /// The user's first name in a new `them` line: the ring flashes twice
    /// and the panel shows the sentence. Local — no AI involved.
    private func noticeMentions(in segments: [Segment]) {
        guard let name = meetingOwnerName, meeting.isRecording else { return }
        if segments.count < meetingMentionCursor { meetingMentionCursor = 0 }
        let hits = NameMention.mentions(name: name, in: segments, from: meetingMentionCursor)
        meetingMentionCursor = segments.count
        guard let last = hits.last else { return }
        meetingMention = "\(Timeline.clock(last.start)) · \(NameMention.sentence(name: name, in: last.text))"
        meetingFlash += 1
        onWantsIsland?(true)
        captureCue(.nameMention)
    }

    private func stopMeetingWatchers() {
        // The clock is a watcher too. `stopMeeting` invalidated it by hand
        // and `shutDown` did not, so quitting mid-meeting left a 1 s timer
        // ticking over a meeting that no longer existed.
        meetingClockTimer?.invalidate(); meetingClockTimer = nil
        meetingTapCheck?.cancel(); meetingTapCheck = nil
        meetingScanTimer?.invalidate(); meetingScanTimer = nil
        meetingAwayTimer?.invalidate(); meetingAwayTimer = nil
        captureStatusTimer?.invalidate(); captureStatusTimer = nil
        for o in meetingAwayObservers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        meetingAwayObservers = []
        if meetingWhisper {
            meetingSession?.recorder.forwardMic(nil)
            meetingWhisper = false
            voice.cancelHold()
        }
        holdBeganAt = nil
    }

    private func quietVoiceForMeeting() {
        voice.stopAll()
        voice.setWakeWord(false)
        partial = ""
        if mode == .listening || mode == .speaking { mode = .idle }
    }

    private func restoreVoiceAfterMeeting() {
        guard alwaysListening, !meetingOwnsMic else { return }
        voice.setWakeWord(true)
    }

    private func startMeetingClock(since: Date) {
        meetingClockTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.meeting.isRecording else { return }
                self.meetingClock = Timeline.clock(Date().timeIntervalSince(since))
                self.captureTick()
                self.pollMeetingCommand()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        meetingClockTimer = t
    }

    /// A tap without the System Audio Recording grant delivers nothing and
    /// no error (MEETING-MODE.md). Eight seconds in, no buffer at all while
    /// the IO proc ticks is either that or a call that has been silent
    /// since it started; say so once, with the deep link, and keep
    /// recording — the mic side is still good.
    private func watchMeetingTap(_ session: MeetingSession) {
        meetingTapCheck?.cancel()
        meetingTapCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.meeting.isRecording,
                  self.meetingSession === session, !session.recorder.tapIsDelivering else { return }
            Log.write("meeting: tap delivered nothing in 8 s (\(session.recorder.tapCallbacks) IO callbacks)")
            self.meetingStatus = "No call audio yet. If the meeting app is playing sound, "
                               + "allow System Audio Recording for Moe."
            self.onMeetingProblem?(
                "Moe is recording your microphone, but no audio has arrived from the call. If the "
                + "other people are talking and you can hear them, macOS is not letting Moe hear "
                + "the call: allow it under System Settings › Privacy & Security › Screen & System "
                + "Audio Recording (\u{201C}System Audio Recording Only\u{201D}), then stop and start the meeting again.", true)
        }
    }

    /// Stop → "Writing your notes…" → done, with the folder for "Open notes".
    func stopMeeting() {
        guard case .recording = meeting, let session = meetingSession else { return }
        stopMeetingWatchers()
        meeting = .stopping
        meetingStatus = "Writing your notes…"
        statusLine = "Writing your notes…"
        let summarise = config.meetingSummarise && connected
        let brain: MeetingBrain? = config.meetingSummarise ? liveBrain(.notes) : nil
        let deleteRecordings = config.meetingDeleteRecordings
        let liveActions = meetingLiveActions
        let summariseSetting = config.meetingSummarise
        // Measured off the recording, not a constant: diarization is the
        // one part of `finish` whose cost is proportional to the meeting,
        // so a flat deadline that fits a five-minute call truncates an
        // hour-long one (MeetingSession.finishDeadline).
        let deadline = MeetingSession.finishDeadline(recorded: session.elapsed)
        meetingEndOffer = nil
        meetingCallApp = nil
        Task { [weak self] in
            // A clip still running ends with the meeting, before the notes
            // are written, so its record is in them.
            if let self, self.clipRecorder.isRunning { await self.finishClip() }
            if let self { session.captures = self.meetingCaptures }
            // A deadline, because nothing inside `finish` has one: the model
            // load, the recognition of the tail and the diarization can all
            // hang, and when they do the meeting parks at `.stopping` and
            // the panel says "Writing your notes…" forever. Missing it falls
            // back to the transcript the live pass already wrote.
            let finished = await Deadline.run(seconds: deadline) {
                await session.finish(brain: summarise ? brain : nil, summarise: summariseSetting,
                                     deleteRecordings: deleteRecordings, liveActions: liveActions)
            }
            guard let self else { return }
            let outcome = finished ?? session.transcriptOnlyOutcome(
                reason: "writing the notes did not finish within \(Int(deadline)) s")
            if finished == nil {
                Log.write("meeting: finish missed its \(Int(deadline)) s deadline")
            }
            // `finish` stops the recorder, so the input device is free from
            // here — not from the top of this function, where the meeting's
            // engine still had it. (The fallback stops it too.)
            self.voice.detachExternalInput()
            self.meetingSession = nil
            self.meetingOutcome = outcome
            // With the record's names, so a transcript written as "Dan:"
            // reads back as the voice it belongs to rather than being
            // skipped as an unparseable line.
            self.meetingTimeline = Timeline.parse(
                (try? String(contentsOf: session.transcriber.transcriptURL, encoding: .utf8)) ?? "",
                names: outcome.record.nameBook)
            self.meeting = .done(url: outcome.summaryURL ?? session.transcriber.transcriptURL)
            self.meetingStatus = outcome.message
            self.statusLine = ""
            self.meetingHint = nil
            // Not the folder path. A conversation is somewhere a person reads
            // sentences, and "/Users/…/.moe/meetings/2026-08-30-2118" is not
            // one — the island's own "Open notes" is how you reach the files.
            self.turns.append(Turn(role: .system, text: outcome.message))
            // The notes are written: whatever Moe was thinking about before
            // the meeting ended, it is not thinking now. A question asked
            // mid-meeting left `mode` at `.thinking` (see `speakRemainder`),
            // and nothing on this path ever brought it back — so the island
            // sat on the cyan working arc after "Notes ready".
            self.settleMode()
            self.offerCalendarNamesIfUseful(outcome.record)
            if outcome.record.summarised, let url = outcome.summaryURL {
                self.rememberMeeting(at: url, record: outcome.record)
            }
            self.deliverNotesToTelegram(summaryURL: outcome.summaryURL)
            self.restoreVoiceAfterMeeting()
        }
    }

    /// Back to idle unless something is genuinely in flight. `.thinking` is
    /// set by `submit` and cleared when the reply is spoken; with spoken
    /// replies off — and they are always off during a meeting — nothing
    /// cleared it.
    private func settleMode() {
        guard !awaitingReply, mode == .thinking else { return }
        mode = .idle
    }

    /// The notes to the user's own Telegram — only when the user asked for
    /// it. One turn on the meeting session that calls `send_message` with
    /// `telegram:<own id>`; the confirm-send hook lets that one recipient
    /// through without a dialog (moe-home/hermes/hooks), because the user
    /// is the one recipient that needs no asking. Anything else Hermes
    /// might try still gets the dialog.
    ///
    /// Two things were wrong with this. It fired on nothing more than
    /// Hermes happening to have a `TELEGRAM_ALLOWED_USERS` entry — a
    /// configuration detail, not a decision to send meeting notes off the
    /// Mac — so it is now behind `Config.meetingSendTelegram`, off by
    /// default. And when it failed it said "FAILED", which told the user
    /// nothing: the real reason is that Hermes does not expose its
    /// messaging tools to the `claude-code` profile, so the model is asked
    /// to call a tool it does not have.
    /// True from the moment the notes are handed to the brain for Telegram
    /// until it answers, sent or not. A quit that was waiting for the notes
    /// waits for this too (`QuitDuringMeeting.next`): it used to go the
    /// moment the notes were on disk, with the send still in the air.
    private(set) var meetingDeliveryInFlight = false

    private func deliverNotesToTelegram(summaryURL: URL?) {
        let gate = TelegramSelf.gate(enabled: config.meetingSendTelegram,
                                     target: MeetingSession.telegramSelfTarget(),
                                     connected: connected)
        guard case .send(let target) = gate else {
            meetingDelivery = gate.message
            if !gate.message.isEmpty { Log.write("meeting: telegram skipped — \(gate.message)") }
            return
        }
        guard let summaryURL, let notes = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            meetingDelivery = "Notes not sent — there are no notes to send."
            return
        }
        meetingDelivery = gate.message
        meetingDeliveryInFlight = true
        let brain = liveBrain(.delivery)
        Task { [weak self] in
            let reply = (try? await brain.complete(system: TelegramSelf.system,
                                                   user: TelegramSelf.user(target: target, notes: notes))) ?? ""
            await MainActor.run {
                guard let self else { return }
                let (sent, message) = TelegramSelf.outcome(reply: reply)
                self.meetingDelivery = message
                self.meetingDeliveryInFlight = false
                Log.write("meeting: telegram \(sent ? "sent" : "not sent") — \(message)")
                // The delivery turn is the last thing a finished meeting
                // does; settle the island once it has.
                self.settleMode()
            }
        }
    }

    /// A reminder for an action item, through the app's own EventKit
    /// entry point (`Moe --add-reminder`), so nothing launches Reminders.app.
    /// Local, no confirmation: the user ticked the box.
    nonisolated static func addReminder(title: String, due: String?) async -> Bool {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--add-reminder", title] + (due.map { [$0] } ?? [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return await withCheckedContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus == 0) }
        }
    }

    /// Hermes decides what of a meeting is worth keeping: a normal, silent
    /// turn pointing at the notes, in the agent's own first person — it was
    /// in the room taking them. Moe never writes USER.md/MEMORY.md itself.
    // Internal, not private, so TurnStarterConductorTests can drive it.
    func rememberMeeting(at url: URL, record: MeetingRecord) {
        guard connected else { return }
        var noted = ""
        var lines: [String] = []
        // Who the voices were, when they are known. The per-meeting record
        // in meeting.json is the machine-readable copy; this is the one
        // sentence that puts the people into the agent's own memory, so
        // "what did Dan agree to" has a name to find.
        let named = record.speakerNames.compactMap(\.name)
        if !named.isEmpty {
            lines.append("Who was speaking, besides the user: " + named.joined(separator: ", ") + ".")
        }
        if let notes = record.notes {
            if !notes.decisions.isEmpty { lines.append("Decisions I noted: " + notes.decisions.joined(separator: "; ")) }
            if !notes.actionItems.isEmpty {
                lines.append("Action items I noted: " + notes.actionItems.map {
                    "\($0.who.isEmpty ? "someone" : $0.who) — \($0.what)\($0.when.isEmpty ? "" : " by \($0.when)")"
                }.joined(separator: "; "))
            }
        }
        noted = lines.joined(separator: "\n")
        bridge.send("""
        (Background note, not from the user. I — the user's assistant — sat in on a \
        meeting that just ended and took the notes; they are at \(url.path), with \
        the transcript in transcript.txt beside them. \(noted.isEmpty ? "" : "\n" + noted + "\n")\
        Remember the decisions and action items that matter for the user, so I can \
        answer "what did we agree" later. Do not reply to this message.)
        """, silent: true, starter: .background)
    }

    /// Back to `off` after the notes were seen, so the menu says "Start meeting".
    func dismissMeetingOutcome() {
        if case .done = meeting { meeting = .off }
        meetingDelivery = ""
    }

    /// An action item from the just-finished meeting, ticked on the island:
    /// a Reminder, and the record updated so the Meetings tab agrees.
    func remindMeetingAction(_ index: Int) {
        guard var outcome = meetingOutcome, var notes = outcome.record.notes, notes.actionItems.indices.contains(index),
              notes.actionItems[index].reminded != true else { return }
        let item = notes.actionItems[index]
        notes.actionItems[index].reminded = true
        outcome.record.notes = notes
        meetingOutcome = outcome
        let recordURL = outcome.recordURL
        let record = outcome.record
        Task {
            // "when" is as spoken ("Friday"), not a date: it rides in the title.
            _ = await Self.addReminder(title: item.when.isEmpty ? item.what : "\(item.what) (by \(item.when))", due: nil)
            if let data = try? record.json() { try? data.write(to: recordURL) }
        }
    }

    /// The same tick, on a meeting that finished earlier — from the
    /// Meetings tab, where the record is read back off disk rather than
    /// held in memory. Returns the record as it now stands.
    @discardableResult
    nonisolated static func tickActionItem(in record: MeetingRecord, index: Int) async -> MeetingRecord {
        var record = record
        guard var notes = record.notes, notes.actionItems.indices.contains(index),
              notes.actionItems[index].reminded != true else { return record }
        let item = notes.actionItems[index]
        notes.actionItems[index].reminded = true
        record.notes = notes
        // "when" is as spoken ("Friday"), not a date: it rides in the title.
        _ = await addReminder(title: item.when.isEmpty ? item.what : "\(item.what) (by \(item.when))", due: nil)
        let url = URL(fileURLWithPath: record.folder, isDirectory: true).appendingPathComponent("meeting.json")
        if let data = try? record.json() { try? data.write(to: url) }
        return record
    }

    /// Give one of a finished meeting's voices a name, or take its name
    /// away again ("not sure"). From the Meetings tab.
    ///
    /// The correction is the user's, so it wins over anything the calendar
    /// suggested and it applies to the whole meeting at once: the
    /// transcript is rewritten line by line, the notes' owners and any
    /// "speaker N" left in the text follow, and the record remembers the
    /// name and that a person confirmed it. `SpeakerRename.apply` does all
    /// of that purely; this reads and writes the three files.
    @discardableResult
    nonisolated static func renameSpeaker(in record: MeetingRecord, speaker: Int, to name: String?) async -> MeetingRecord {
        let folder = URL(fileURLWithPath: record.folder, isDirectory: true).standardizedFileURL
        // The same guard `deleteMeeting` uses: `folder` comes out of a file
        // on disk, and this function overwrites files under it.
        guard folder.deletingLastPathComponent().path == Paths.meetings.standardizedFileURL.path else {
            Log.write("meeting: refused to rename a speaker in \(folder.path) — not a meeting folder")
            return record
        }
        let transcriptURL = folder.appendingPathComponent(TranscriptFile.safeName(record.transcriptFile))
        // The whole file, not `TranscriptFile.read`: that one stops at
        // 256 KB for the view's sake, and writing back what it returned
        // would throw away the rest of a long meeting.
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let summaryURL = record.summaryFile.map { folder.appendingPathComponent(TranscriptFile.safeName($0)) }
        let summary = summaryURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        let result = SpeakerRename.apply(record: record, transcript: transcript, summary: summary,
                                         speaker: speaker, to: name)
        if !transcript.isEmpty, result.transcript != transcript {
            try? result.transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
        }
        if let summaryURL, let text = result.summary, text != summary {
            try? text.write(to: summaryURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
        }
        let url = folder.appendingPathComponent("meeting.json")
        if let data = try? result.record.json() {
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        Log.write("meeting: speaker \(speaker) is now \(name ?? "unnamed") in \(folder.lastPathComponent)")
        return result.record
    }

    /// "Note this": the agent key tapped once while recording.
    func addMeetingBookmark() {
        guard meeting.isRecording, let session = meetingSession else { return }
        if let last = lastBookmarkAt, Date().timeIntervalSince(last) < 0.5 { return }
        lastBookmarkAt = Date()
        session.addBookmark()
        meetingBookmarks = session.bookmarks.count
        statusLine = "Bookmarked \(meetingClock)"
    }

    /// Off the record / back on.
    func toggleMeetingPause() {
        guard meeting.isRecording, let session = meetingSession else { return }
        let paused = !session.isPaused
        session.setPaused(paused)
        meetingPaused = paused
        if paused { meetingHealth = "" }
    }

    /// Per-meeting delete: the whole folder, from the done state or the list.
    func deleteMeeting(folder: URL) {
        // The path comes from `folder` inside meeting.json, which is a plain
        // file on disk the user (or anything else) can edit. Delete only a
        // meeting folder: one directory directly inside ~/.moe/meetings.
        // Without this a hand-edited or corrupt record aimed the Delete
        // button at whatever path it named.
        let target = folder.standardizedFileURL
        let base = Paths.meetings.standardizedFileURL
        guard target.deletingLastPathComponent().path == base.path,
              !target.lastPathComponent.isEmpty, target.lastPathComponent != ".." else {
            Log.write("meeting: refused to delete \(target.path) — not a meeting folder")
            return
        }
        try? FileManager.default.removeItem(at: target)
        Log.write("meeting: deleted \(target.lastPathComponent)")
        if case .done(let url) = meeting, url.path.hasPrefix(folder.path) {
            meeting = .off
            meetingOutcome = nil
            meetingTimeline = []
            meetingStatus = "Meeting deleted."
            meetingDelivery = ""
        }
    }

    /// The announcement for the call's chat, on the clipboard. The consent
    /// sheet's button is the one people press; this is the same write.
    func copyMeetingAnnouncement() {
        MeetingConsentSheet.copy(MeetingOwner.announcement(userName: MeetingSession.ownerName()))
        statusLine = "Announcement copied — paste it into the call's chat"
    }

    /// The last 40 lines of the live transcript, for a question asked
    /// quietly mid-meeting ("what did they just say"). Empty when not
    /// recording — and empty when "Summarise with your AI" is off, which is
    /// the promise both site/privacy.html and Settings › Meetings › Advanced
    /// make in so many words: off, nothing about the meeting leaves this
    /// Mac. The question itself is an ordinary turn the user typed and still
    /// goes; what other people said in the room does not. "What did they
    /// just say" is answered locally either way (MeetingIntent.repeatLast).
    private var liveTranscriptContext: String {
        guard meeting.isRecording, config.meetingSummarise, !meetingTimeline.isEmpty else { return "" }
        return TranscriptTail.context(meetingTimeline)
    }

    func setSpeakReplies(_ on: Bool) { config = Config.update { $0.speakReplies = on } }

    // MARK: - How Moe answers (Settings › Replies)

    func setSpeakTypedReplies(_ on: Bool) { config = Config.update { $0.speakTypedReplies = on } }
    func setSpeakSpokenReplies(_ on: Bool) { config = Config.update { $0.speakSpokenReplies = on } }
    func setTypedRepliesReadAsText(_ on: Bool) { config = Config.update { $0.typedRepliesReadAsText = on } }
    func setPanelOnReply(_ how: PanelReveal) { config = Config.update { $0.panelOnReply = how.rawValue } }
    func setReplyReadingSeconds(_ s: Double) { config = Config.update { $0.replyReadingSeconds = s } }
    func setInstantAck(_ on: Bool) { config = Config.update { $0.instantAck = on } }
    func setSpokenProgress(_ on: Bool) { config = Config.update { $0.spokenProgress = on } }
    func setReplyChime(_ on: Bool) { config = Config.update { $0.replyChime = on } }
    func setTypedAnswersOpenChat(_ on: Bool) { config = Config.update { $0.typedAnswersOpenChat = on } }
    func setNotchHoverOpens(_ on: Bool) { config = Config.update { $0.notchHoverOpens = on } }

    /// The notch reads this every turn. The chat channels read it from
    /// Hermes's `platform_hints`, which configure-hermes.py writes from
    /// config.json — so it runs again now, off the main thread. A chat
    /// session already open keeps its hint until Hermes starts its next one.
    func setReplyLength(_ length: ReplyLength) {
        config = Config.update { $0.replyLength = length.rawValue }
        guard HermesConfigure.wanted else { return }
        DispatchQueue.global(qos: .utility).async { HermesConfigure.runAndLog() }
    }

    /// One note, so "a small tone when an answer lands" can be heard rather
    /// than imagined. The pane's Test button.
    func previewReplyChime() { chime.play(.reply) }

    func setMeetingAskBeforeStart(_ on: Bool) { config = Config.update { $0.meetingAskBeforeStart = on } }
    func setMeetingSummarise(_ on: Bool) {
        config = Config.update { $0.meetingSummarise = on }
        // Mid-meeting: the minute scan and catch-up follow the switch at once.
        if meeting.isRecording { startMeetingScan(); startMeetingAwayWatch() }
    }
    func setMeetingDeleteRecordings(_ on: Bool) { config = Config.update { $0.meetingDeleteRecordings = on } }
    func setMeetingSendTelegram(_ on: Bool) { config = Config.update { $0.meetingSendTelegram = on } }
    /// `telegram:<own id>` if Hermes has a bot and an allowed user, else
    /// nil — the Settings switch is disabled and explains itself when so.
    var meetingTelegramTarget: String? { MeetingSession.telegramSelfTarget() }
    func setMeetingHotkey(_ on: Bool) {
        config = Config.update { $0.meetingHotkey = on }
        onMeetingHotkeyChanged?(on)
    }
    func setMeetingCaptureHotkeys(_ on: Bool) { config = Config.update { $0.meetingCaptureHotkeys = on } }
    func setMeetingAutoStopOnCallEnd(_ on: Bool) {
        config = Config.update { $0.meetingAutoStopOnCallEnd = on }
    }

    func setMeetingAutoDetect(_ mode: DetectMode) {
        config = Config.update { $0.meetingAutoDetect = mode }
        if mode == .off {
            watcher?.stop(); watcher = nil
            meetingOffer = nil
            offerTimer?.invalidate(); offerTimer = nil
        } else {
            startMeetingWatcher()
        }
    }
    func setMeetingCapture(_ change: (inout CapturePolicy) -> Void) {
        config = Config.update { change(&$0.meetingCapture) }
    }
    func forgetIgnoredCallApp(_ bundleID: String) {
        config = Config.update { $0.meetingDetectIgnored.removeAll { $0 == bundleID } }
    }

    // MARK: - Noticing a call

    /// On unless the setting is off. The watcher is cheap (one property
    /// read per audio process every four seconds) and it is what makes
    /// "record it?" appear without anyone remembering to press anything.
    private func startMeetingWatcher() {
        guard config.meetingAutoDetect != .off else { return }
        if watcher == nil {
            let w = MeetingWatcher()
            w.ignored = { [weak self] in Set(self?.config.meetingDetectIgnored ?? []) }
            w.onVerdict = { [weak self] v in self?.callNoticed(v) }
            watcher = w
        }
        watcher?.start()
    }

    private var meetingIsIdle: Bool {
        switch meeting {
        case .off, .done: return true
        case .starting, .recording, .stopping: return false
        }
    }

    private func callNoticed(_ v: MeetingDetector.Verdict) {
        switch v.kind {
        case .started:
            // Already recording (started by hand): nothing to offer.
            guard meetingIsIdle else { watcher?.acknowledge(); return }
            guard meetingOffer == nil else { return }
            let mode = config.meetingAutoDetect
            meetingOffer = MeetingOffer(app: v.app, countdown: mode == .auto ? 5 : nil)
            onWantsIsland?(true)
            if mode == .auto { startOfferCountdown() }
        case .ended:
            if meetingOffer?.app == v.app {
                // The call ended before anyone answered: withdraw the offer.
                meetingOffer = nil
                offerTimer?.invalidate(); offerTimer = nil
                return
            }
            // The call that ended is the one being recorded, or the meeting
            // was started by hand and this is the only call there was.
            //
            // `meetingCallApp` is only set when the recording began from an
            // offer. Requiring it to match meant a meeting you started
            // yourself never noticed its own call ending — which is exactly
            // what happened on 2026-09-08: a Telegram call recorded by hand
            // ran for sixty-one minutes and stopped when the user did.
            guard meeting.isRecording, meetingCallApp == v.app || meetingCallApp == nil else { return }
            // Stopping is not the same decision as starting. Starting is
            // consent; stopping a recording already agreed to is only
            // housekeeping, and leaving it to a prompt means the file keeps
            // growing while nobody is talking into it.
            if config.meetingAutoStopOnCallEnd {
                Log.write("meeting: \(v.app.name) released the microphone; stopping and writing the notes")
                stopMeeting()
            } else {
                meetingEndOffer = MeetingOfferText.ended(v.app)
                onWantsIsland?(true)
            }
        }
    }

    private func startOfferCountdown() {
        offerTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, var offer = self.meetingOffer, let n = offer.countdown else {
                    self?.offerTimer?.invalidate(); self?.offerTimer = nil
                    return
                }
                if n <= 1 {
                    self.offerTimer?.invalidate(); self.offerTimer = nil
                    self.acceptMeetingOffer()
                } else {
                    offer.countdown = n - 1
                    self.meetingOffer = offer
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        offerTimer = t
    }

    /// Start — through `requestMeeting`, so the consent sheet still applies
    /// when it is on. The offer is one click, never a recording by itself.
    func acceptMeetingOffer() {
        guard let offer = meetingOffer else { return }
        offerTimer?.invalidate(); offerTimer = nil
        meetingOffer = nil
        meetingCallApp = offer.app
        Log.write("meeting: offer accepted for \(offer.app.name)")
        if meeting.isRecording { return }
        if case .done = meeting { dismissMeetingOutcome() }
        requestMeeting()
    }

    func dismissMeetingOffer() {
        guard let offer = meetingOffer else { return }
        offerTimer?.invalidate(); offerTimer = nil
        meetingOffer = nil
        watcher?.dismiss()
        Log.write("meeting: offer declined for \(offer.app.name)")
    }

    /// "Never for Slack": the app goes on the ignore list (Settings ›
    /// Meetings lists it with a way back).
    func neverOfferForApp() {
        guard let offer = meetingOffer else { return }
        config = Config.update { c in
            if !c.meetingDetectIgnored.contains(offer.app.bundleID) { c.meetingDetectIgnored.append(offer.app.bundleID) }
        }
        dismissMeetingOffer()
    }

    func acceptMeetingEndOffer() {
        meetingEndOffer = nil
        stopMeeting()
    }
    func dismissMeetingEndOffer() { meetingEndOffer = nil }

    /// The meeting just ended with voices Moe could only number, and it has
    /// never been allowed to read who was invited. Ask now, once — this is
    /// the moment the answer means something, and the Meetings pane, where
    /// the offer has always lived, is not where anyone goes to wonder who
    /// "speaker 4" was.
    private func offerCalendarNamesIfUseful(_ record: MeetingRecord) {
        let unnamed = CalendarNameOffer.unnamedVoices(record)
        guard CalendarNameOffer.shouldOffer(unnamedVoices: unnamed,
                                            accessUndecided: MeetingInvite.access == .notDetermined,
                                            alreadyAsked: config.meetingCalendarOfferShown) else { return }
        meetingCalendarOffer = CalendarNameOffer.text(unnamedVoices: unnamed)
    }

    /// "Use my calendar": the system sheet, raised by a person who pressed a
    /// button, and never again whichever way they answer.
    func acceptCalendarNameOffer() {
        meetingCalendarOffer = nil
        config = Config.update { $0.meetingCalendarOfferShown = true }
        Task { @MainActor in
            let granted = await MeetingInvite.requestAccess()
            self.meetingStatus = granted
                ? "Thanks — Moe will name the voices it can from now on."
                : "No problem. Voices stay numbered; you can change this in Settings › Meetings."
        }
    }

    func dismissCalendarNameOffer() {
        meetingCalendarOffer = nil
        config = Config.update { $0.meetingCalendarOfferShown = true }
    }

    /// "I know" — the notice goes, the meeting carries on recording the one
    /// side it can hear. Deliberately not a stop: half a recording is worth
    /// more than none, and the user may be on a call where it does not
    /// matter.
    func dismissMeetingTapFault() { meetingTapFault = nil }

    /// The likeliest thing standing in the way, from the notice's button.
    func openAudioCaptureSettings() {
        MeetingSession.openAudioCaptureSettings()
    }

    // MARK: - Screenshots and clips

    private var capturePreferredApps: [String] {
        if let app = meetingCallApp { return [app.bundleID] }
        if let app = watcher?.current { return [app.bundleID] }
        return []
    }

    /// Only raised once per meeting, so a refusal does not re-pop the banner
    /// on every cue for the rest of the call.
    private var capturePermissionWarned = false

    /// The screen-recording grant. The system dialog is only ever raised for
    /// a `user` trigger — a click or a hotkey, a moment a person is looking;
    /// an automatic cue or the agent never pops it (the module's contract).
    /// Once refused it points at Settings, at most once a meeting.
    private func ensureScreenPermission(trigger: CaptureTrigger) -> Bool {
        if ScreenPermission.granted { return true }
        // Auto and agent: never raise the dialog on a timer or a tool call.
        if trigger == .user, ScreenPermission.request() { return true }
        if !capturePermissionWarned {
            capturePermissionWarned = true
            onMeetingCaptureProblem?(
                "Memoe needs Screen Recording to take pictures of the meeting. Allow it under "
                + "System Settings › Privacy & Security › Screen & System Audio Recording, then try again.", true)
        }
        return false
    }

    /// The outcome of one screenshot, so the agent's command line can report
    /// what actually happened rather than a guess made before it did.
    enum ShotOutcome {
        case done(CaptureRecord)
        case skipped(String)
        case failed(String)
    }

    /// One still, now — fire and forget. `reason` is a cue's slug, or what
    /// the user or the agent said.
    func captureScreenshot(trigger: CaptureTrigger, reason: String = "") {
        Task { [weak self] in _ = await self?.takeScreenshot(trigger: trigger, reason: reason) }
    }

    /// The awaitable core. Writes the file and returns the record before the
    /// caption is fetched (the caption is best-effort and runs on after this
    /// returns), so the agent's reply names a file that exists.
    @discardableResult
    func takeScreenshot(trigger: CaptureTrigger, reason: String) async -> ShotOutcome {
        guard meeting.isRecording, let session = meetingSession else {
            if trigger == .user { showCaptureStatus("No meeting is being recorded.") }
            return .skipped("no meeting is being recorded")
        }
        guard config.meetingCapture.screenshots != .off || trigger == .user else {
            return .skipped("screenshots are off in Settings › Meeting Capture")
        }
        guard !captureBusy else { return .skipped("another screenshot is being taken") }
        guard ensureScreenPermission(trigger: trigger) else {
            return .skipped("Screen Recording is not allowed for Moe")
        }
        captureBusy = true
        let policy = config.meetingCapture
        let at = session.elapsed
        let index = meetingCaptures.filter { $0.kind == .screenshot }.count + 1
        let relative = CaptureFile.name(index: index, at: at, kind: .screenshot, reason: reason)
        let folder = session.folder
        let apps = capturePreferredApps
        let context = Timeline.format(Array(meetingTimeline.suffix(6)))
        let record: CaptureRecord
        let image: CGImage
        do {
            let shot = try await MeetingScreenshot.take(scope: policy.scope, region: policy.region, preferredApps: apps)
            image = shot.image
            guard let data = await Task.detached(priority: .userInitiated, operation: { MeetingScreenshot.jpeg(image) }).value else {
                throw MeetingSessionError("could not encode the picture")
            }
            _ = try MeetingScreenshot.write(data, to: folder, relative: relative)
            record = CaptureRecord(file: relative, kind: .screenshot, at: at, trigger: trigger, reason: reason)
            meetingCaptures.append(record)
            captureScheduler.tookScreenshot(at: at, trigger: trigger)
            showCaptureStatus("Screenshot saved" + (shot.note.isEmpty ? "" : " — \(shot.note)"))
            Log.write("meeting: screenshot \(relative) (\(trigger.rawValue)\(reason.isEmpty ? "" : ", \(reason)")"
                      + "\(shot.note.isEmpty ? "" : "; \(shot.note)"))")
            // On disk; the next screenshot may go now. The caption below is
            // best-effort and can take up to two minutes, so it must not hold
            // the one-at-a-time lock.
            captureBusy = false
        } catch {
            captureBusy = false
            Log.write("meeting: screenshot failed: \(error)")
            // `localizedDescription` on a ScreenCaptureKit error is
            // "The operation couldn't be completed. (SCStreamErrorDomain
            // error -3801.)" — a sentence with nothing in it for the person
            // holding the shortcut. The log has the real one.
            Log.write("meeting: screenshot failed: \(error)")
            showCaptureStatus("Couldn't take that screenshot.")
            return .failed(error.localizedDescription)
        }
        // The caption: what the AI saw, one line, on the meeting session with
        // the picture attached. Only with summarising on — otherwise nothing
        // of the meeting leaves the Mac. Detached so the caller (the agent's
        // command) gets its answer without waiting on the round-trip.
        if policy.caption, config.meetingSummarise, connected {
            let brain = liveBrain(.caption)
            Task { [weak self] in
                let small = await Task.detached(priority: .utility) {
                    MeetingScreenshot.jpeg(image, maxSide: ScreenContext.maxSide, quality: 0.75)
                }.value
                guard let small,
                      let reply = try? await brain.complete(system: CaptureCaption.system,
                                                            user: CaptureCaption.user(reason: reason, recentLines: context),
                                                            image: ImageAttachment(data: small, mediaType: "image/jpeg")),
                      let caption = CaptureCaption.clean(reply) else { return }
                await MainActor.run {
                    guard let self else { return }
                    if let i = self.meetingCaptures.firstIndex(where: { $0.file == relative }) {
                        self.meetingCaptures[i].caption = caption
                    }
                    Log.write("meeting: caption for \(relative): \(caption)")
                }
            }
        }
        return .done(record)
    }

    /// The hotkey, the menu item, the panel button: start a clip, or stop
    /// the one running.
    func toggleMeetingClip(trigger: CaptureTrigger, reason: String = "") {
        if clipRecorder.isRunning { Task { await finishClip() } }
        else { startClip(trigger: trigger, reason: reason) }
    }

    private func startClip(trigger: CaptureTrigger, reason: String) {
        // `meetingClip` is set synchronously below and stays true for the
        // whole clip, so it also closes the ~1 s async-start window: a second
        // start (an auto cue and ⌃⌥R landing together) sees it and bails,
        // rather than racing a second SCStream against the first.
        guard meeting.isRecording, let session = meetingSession, !clipRecorder.isRunning, !meetingClip else { return }
        guard config.meetingCapture.recording != .off || trigger == .user else { return }
        guard ensureScreenPermission(trigger: trigger) else { return }
        let policy = config.meetingCapture
        let at = session.elapsed
        let index = meetingCaptures.filter { $0.kind == .recording }.count + 1
        let relative = CaptureFile.name(index: index, at: at, kind: .recording, reason: reason)
        let url = session.folder.appendingPathComponent(relative)
        let apps = capturePreferredApps
        captureScheduler.startedClip(at: at, reason: reason, trigger: trigger)
        meetingClip = true
        clipRecorder.onDied = { [weak self] in
            guard let self, self.clipRecorder.isRunning else { return }
            Log.write("meeting: clip stream stopped on its own; finishing")
            Task { await self.finishClip() }
        }
        Task { [weak self] in
            do {
                try await self?.clipRecorder.start(to: url, scope: policy.scope, region: policy.region, preferredApps: apps)
                guard let self else { return }
                self.meetingCaptures.append(CaptureRecord(file: relative, kind: .recording, at: at, trigger: trigger, reason: reason))
                self.showCaptureStatus("Recording the screen" + (self.clipRecorder.note.isEmpty ? "" : " — \(self.clipRecorder.note)"))
                Log.write("meeting: clip started \(relative) (\(trigger.rawValue)\(reason.isEmpty ? "" : ", \(reason)"))")
            } catch {
                guard let self else { return }
                self.captureScheduler.stoppedClip()
                self.meetingClip = false
                self.meetingCaptures.removeAll { $0.file == relative }
                Log.write("meeting: clip failed to start: \(error)")
                Log.write("meeting: screen recording failed: \(error)")
                self.showCaptureStatus("Couldn't start recording the screen.")
            }
        }
    }

    private func finishClip() async {
        guard clipRecorder.isRunning, let url = clipRecorder.url else { return }
        let seconds = await clipRecorder.stop()
        captureScheduler.stoppedClip()
        meetingClip = false
        let relative = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        if let seconds {
            if let i = meetingCaptures.firstIndex(where: { $0.file == relative }) {
                meetingCaptures[i].durationSeconds = seconds
            }
            showCaptureStatus("Clip saved · \(Timeline.clock(seconds))")
            Log.write("meeting: clip saved \(relative), \(Timeline.clock(seconds))")
        } else {
            meetingCaptures.removeAll { $0.file == relative }
            Log.write("meeting: clip discarded — \(clipRecorder.failure ?? "nothing recorded")")
            // `failure` may be an AVFoundation `localizedDescription`.
            if let why = clipRecorder.failure { Log.write("meeting: clip discarded: \(why)") }
            showCaptureStatus("Clip discarded — nothing was recorded.")
        }
    }

    /// New transcript lines: the cue phrases, and "stop sharing".
    private func noticeCaptureCues(in segments: [Segment]) {
        guard meeting.isRecording, config.meetingCapture.isAutomatic else { captureCueCursor = segments.count; return }
        if segments.count < captureCueCursor { captureCueCursor = 0 }
        let fresh = Array(segments[captureCueCursor...])
        captureCueCursor = segments.count
        guard let session = meetingSession else { return }
        for s in fresh where CaptureCueScan.endsShare(s.text) {
            if let d = captureScheduler.shareEnded(at: session.elapsed) { act(on: d) }
        }
        var seen = Set<CaptureCue>()
        for hit in CaptureCueScan.scan(fresh, from: 0) where !seen.contains(hit.cue) {
            seen.insert(hit.cue)
            captureCue(hit.cue)
        }
    }

    /// One cue, from wherever it came: the scheduler decides.
    private func captureCue(_ cue: CaptureCue) {
        guard meeting.isRecording, let session = meetingSession, config.meetingCapture.isAutomatic else { return }
        for d in captureScheduler.cue(cue, at: session.elapsed, policy: config.meetingCapture) { act(on: d) }
    }

    private func captureTick() {
        guard let session = meetingSession else { return }
        if let d = captureScheduler.tick(at: session.elapsed, policy: config.meetingCapture) { act(on: d) }
    }

    private func act(on d: CaptureScheduler.Decision) {
        switch d {
        case .screenshot(let reason): captureScreenshot(trigger: .auto, reason: reason)
        case .startClip(let reason):
            // The scheduler already holds the clip; the recorder catches up.
            captureScheduler.stoppedClip()
            startClip(trigger: .auto, reason: reason)
        case .stopClip: Task { await finishClip() }
        }
    }

    private func showCaptureStatus(_ text: String) {
        meetingCaptureStatus = text
        captureStatusTimer?.invalidate()
        let t = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.meetingCaptureStatus = "" }
        }
        RunLoop.main.add(t, forMode: .common)
        captureStatusTimer = t
    }

    /// Drag a rectangle; it becomes the capture area and the scope.
    func chooseCaptureRegion() {
        guard ensureScreenPermission(trigger: .user) else { return }
        regionPicker.pick { [weak self] region in
            guard let self, let region else { return }
            self.config = Config.update { $0.meetingCapture.region = region; $0.meetingCapture.scope = .region }
            Log.write("meeting: capture area \(Int(region.width))×\(Int(region.height)) at \(Int(region.x)),\(Int(region.y))")
        }
    }

    // MARK: - The agent's way in

    /// `~/.moe/meeting-command.json`, written by `Moe --meeting-capture`
    /// (which the agent runs through `mac.sh`): a screenshot or a clip on
    /// the agent's say-so, while a meeting runs. Never a start or a stop —
    /// recording other people stays the user's own act.
    nonisolated static let commandURL = Paths.home.appendingPathComponent("meeting-command.json")
    nonisolated static let commandResultURL = Paths.home.appendingPathComponent("meeting-command.result.json")

    private func pollMeetingCommand() {
        guard let data = try? Data(contentsOf: Self.commandURL) else { return }
        try? FileManager.default.removeItem(at: Self.commandURL)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else { return }
        let reason = ((obj["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        func reply(_ result: [String: Any]) {
            if let out = try? JSONSerialization.data(withJSONObject: result) {
                try? out.write(to: Self.commandResultURL, options: .atomic)
            }
        }

        switch action {
        case "screenshot":
            // Awaited to its real outcome: the reply names a file only when
            // one was written, with the stamp it actually got — not a path
            // guessed before the capture that could fail or be off by a second.
            Task { [weak self] in
                guard let self else { return }
                switch await self.takeScreenshot(trigger: .agent, reason: reason) {
                case .done(let record):
                    reply(["ok": true, "message": "screenshot taken",
                           "file": (self.meetingSession?.folder.appendingPathComponent(record.file).path) ?? record.file])
                case .skipped(let why), .failed(let why):
                    reply(["ok": false, "message": why])
                }
            }
        case "record":
            var result: [String: Any] = ["ok": true]
            if config.meetingCapture.recording == .off {
                result = ["ok": false, "message": "screen recording is off in Settings › Meeting Capture"]
            } else {
                let start = (obj["start"] as? Bool) ?? !clipRecorder.isRunning
                if start, clipRecorder.isRunning { result["message"] = "a clip is already recording" }
                else if !start, !clipRecorder.isRunning { result["message"] = "no clip is recording" }
                else {
                    toggleMeetingClip(trigger: .agent, reason: reason)
                    result["message"] = start ? "clip started" : "clip stopped"
                }
            }
            reply(result)
        case "status":
            reply(["ok": true, "message": "recording \(meetingClock)", "captures": meetingCaptures.map(\.file)])
        default:
            reply(["ok": false, "message": "unknown action \(action)"])
        }
    }

    // MARK: - Speaking the reply as it streams

    /// Speak whole sentences as soon as they're complete, so the first words
    /// come out while the rest is still generating.
    private func speakReadySentences() {
        // Never aloud while a meeting is recorded: the room would hear it,
        // and the call's mic would carry it to everyone else.
        guard replySpeaks, !replyAbandoned, quietWork.speaks(.interim), let id = streamingTurnID,
              let turn = turns.first(where: { $0.id == id }) else { return }
        let full = turn.text
        guard full.count > spokenUpTo.count else { return }

        var pending = String(full.dropFirst(spokenUpTo.count))
        // Only the first thing out of the speaker may break at a clause. Once
        // Moe is talking, the rest of the reply is generating faster than it
        // is being spoken, so there is nothing left to save and whole
        // sentences read better.
        //
        // Not for the premium (cloud) voice, whose first audio lands in
        // 80–300 ms: a half-sentence flushed on its own is generated on its
        // own, with end-of-sentence intonation on a comma. It breaks at a
        // clause only once the opening sentence has run long (120
        // characters), so a long first sentence still starts about as soon
        // as it did.
        let cloud = voice.engineKind.isCloud
        while let sentence = Self.popSentence(&pending, orClause: spokenUpTo.isEmpty,
                                              clauseAfter: cloud ? 120 : 30) {
            spokenUpTo += sentence
            lastNarrationAt = Date()
            voice.speak(sentence, replyEnd: spokenUpTo.count)
        }
    }

    /// Say what is buffered now, without waiting for a boundary.
    ///
    /// `popSentence` will not break on a terminator it cannot see past: mid-
    /// stream a chunk can end at "It's 3." with the "5" still on its way, and
    /// breaking there gives "It's three." followed by "five degrees out". That
    /// rule is right for as long as text is arriving. It is badly wrong the
    /// moment the model stops writing to go and run something, because then
    /// the next character is a tool call away — and the one line the prompt
    /// works hardest to get is exactly the line that lands there. Measured on
    /// the disk-space turn:
    ///
    ///     17:54:05  first token — "Let me check what's taking up space…"
    ///     17:54:58  first word spoken, 53 s later
    ///
    /// The sentence was complete and sitting in the buffer for the whole of
    /// it. To the user that is a minute of a hang with no sign of life, which
    /// is the precise thing the opener exists to prevent.
    private func flushPendingSpeech() {
        guard replySpeaks, !replyAbandoned, quietWork.speaks(.interim), let id = streamingTurnID,
              let turn = turns.first(where: { $0.id == id }) else { return }
        let rest = String(turn.text.dropFirst(spokenUpTo.count))
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastNarrationAt = Date()
        speakToEnd(of: turn.text)
    }

    /// Say what Moe is doing, from the step Hermes reports.
    ///
    /// The model's own words always win. When it writes a line before it goes
    /// quiet — which is what BrainPrompt asks of it — that line is the whole
    /// account and this stays out of the way. But it does not always write
    /// one, and a turn where it went straight to work read like this:
    ///
    ///     19:53:42  → What did I ship on the pulse repos today?
    ///     19:54:41  turn: first token 59.3 s after the mic closed
    ///
    /// Fifty-nine seconds with the first token already being the answer. So
    /// the first step of a turn the model has said nothing about is spoken at
    /// once — that is the "let me look at your GitHub" beat, and it is true,
    /// because Hermes is telling us that is what is happening. After that a
    /// step is only spoken into a real silence.
    /// Which app a step is driving, if it is driving one.
    ///
    /// Reads the same label the spoken step reads — Hermes sends "click
    /// (953, 59) in Freeform", "menu Insert > Media… in Freeform" — plus the
    /// AppleScript route, which is screen driving through the terminal tool
    /// and was invisible to every control until tonight.
    /// The browser tools, by Hermes's own names: `browser_exec` (the Browser
    /// Use CLI) and every `browser_*` — navigate, click, type, the vault.
    /// Matched on the prefix, not a list, so the next tool Hermes adds under
    /// that name is covered without anyone remembering to come here.
    static func isBrowserTool(_ tool: String) -> Bool {
        tool == "browser_exec" || tool.hasPrefix("browser_")
    }

    static func appBeingDriven(tool: String, detail: String) -> String? {
        if tool == "computer_use" {
            if let r = detail.range(of: " in ", options: .backwards) {
                let app = detail[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !app.isEmpty { return app }
            }
            return "your Mac"
        }
        // `osascript -e 'tell application "Freeform" to activate'` and the
        // System Events forms of typing and clicking.
        guard tool == "terminal" || tool == "execute_code" else { return nil }
        let lower = detail.lowercased()
        guard lower.contains("osascript") || lower.contains("open -a") else { return nil }
        guard lower.contains("activate") || lower.contains("keystroke")
                || lower.contains("key code") || lower.contains("click menu item")
                || lower.contains("open -a") else { return nil }
        if let m = detail.range(of: #"application[ ]+"([^"]+)""#, options: .regularExpression) {
            let inner = detail[m]
            if let q = inner.range(of: #""([^"]+)""#, options: .regularExpression) {
                return String(inner[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return "your Mac"
    }

    private func narrateStep(_ phrase: String) {
        guard replySpeaks, config.spokenProgress, awaitingReply, !replyAbandoned,
              quietWork.speaks(.step) else { return }
        guard phrase != lastSpokenStep else { return }
        // Only when the model has said nothing at all this turn. This used to
        // be "or it has been quiet for five seconds", which let the table keep
        // chiming in underneath the model's own account for the whole of a
        // long job — and the owner heard the result: "Running something on
        // your Mac" sixty-seven times in one log, "Searching your files"
        // forty-nine.
        //
        // Since the narration prompt landed the model speaks about three times
        // as often as this table does (170 against 58 in the same stretch), so
        // the table's job is now only the opener the model did not write. Once
        // the model has spoken, the residual-gap backstop is
        // `narrateStillWorking`, which is what a backstop should be: one line,
        // twelve seconds apart, and honest that it has no news.
        guard spokenUpTo.isEmpty else { return }
        // Not spoken. The owner's ruling, 2026-09-16, after "Still handing
        // part of this off" every twelve seconds for ten minutes: nothing
        // deterministic and hard-coded is said to the person, anywhere.
        // What is running still shows on the island as text; what Moe SAYS
        // about a long job is the model's own account (BrainPrompt asks for
        // one line before a wait and another when something changes), and
        // silence from the model is silence.
        _ = phrase
    }

    /// Nothing at all has been heard for a while and a step is still running:
    /// say the same true thing again rather than let it read as a crash.
    private func narrateStillWorking() {
        guard replySpeaks, config.spokenProgress, awaitingReply, !replyAbandoned,
              Date().timeIntervalSince(lastNarrationAt) >= Self.stillWorkingGap else { return }
        // A sheet is waiting on the person. The running step is the send, and
        // "still getting that ready to send" is exactly the wrong thing to
        // say: it is ready, and it is theirs. One reminder, then quiet.
        if var waiting = confirmWaiting {
            guard !waiting.reminded,
                  Date().timeIntervalSince(waiting.since) >= ConfirmWait.reminderAfter else { return }
            guard quietWork.speaks(.confirmReminder) else { return }
            waiting.reminded = true
            confirmWaiting = waiting
            say(ConfirmWait.reminder(kind: waiting.kind))
            return
        }
        // Nothing else is said here. This used to repeat "Still <step>" or
        // one of three stock lines every twelve seconds of silence; on
        // 2026-09-16 that was "Still handing part of this off" dozens of
        // times over one ten-minute job, and the owner's ruling was that
        // nothing deterministic is spoken, anywhere. A long silence from the
        // model is the model's to fill (BrainPrompt), and the island shows
        // the running step as text the whole time.
    }

    /// Listen for the confirmation sheet saying it is up, and answered.
    ///
    /// The sheet is the only thing that knows. Hermes reported the send step
    /// before its hook opened the dialog, the hook then blocks until the
    /// person answers, and neither the model nor this file is told anything in
    /// between — so Moe used to spend that wait saying "still getting that
    /// ready to send" to someone who was expected to press Send.
    private func watchForConfirm() {
        guard confirmObservers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        confirmObservers = [
            dnc.addObserver(forName: ConfirmSignal.waiting, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let kind = ConfirmWait.Kind(wire: info[ConfirmSignal.kindKey] as? String)
                let editable = (info[ConfirmSignal.editableKey] as? String) == "yes"
                let pid = info[ConfirmSignal.pidKey] as? String ?? ""
                Task { @MainActor in self?.confirmSheetUp(kind: kind, editable: editable, pid: pid) }
            },
            dnc.addObserver(forName: ConfirmSignal.answered, object: nil, queue: .main) { [weak self] note in
                let pid = note.userInfo?[ConfirmSignal.pidKey] as? String ?? ""
                Task { @MainActor in self?.confirmSheetAnswered(pid: pid) }
            },
            // A card that left because nobody was waiting on it any more
            // (ConfirmLifecycle). What was not sent is already in the inbox
            // — the card writes it there, so it reaches the island whether or
            // not a turn here was watching; this only keeps the log honest
            // and stops a waiting turn saying "press Send" to an empty screen.
            dnc.addObserver(forName: ConfirmSignal.withdrawn, object: nil, queue: .main) { [weak self] note in
                let pid = note.userInfo?[ConfirmSignal.pidKey] as? String ?? ""
                let noted = (note.userInfo?[ConfirmSignal.notedKey] as? String) == "yes"
                Task { @MainActor in
                    Log.write("confirm: a card withdrew unanswered (pid \(pid)) — nothing was sent; "
                              + (noted ? "the note is in the inbox" : "log only, no inbox note"))
                    self?.confirmSheetAnswered(pid: pid)
                }
            },
        ]
    }

    private func confirmSheetUp(kind: ConfirmWait.Kind, editable: Bool, pid: String) {
        // Only a sheet raised inside a turn this Moe is running, with a step
        // in flight. Anything else — a background job's send, a sheet from
        // Moe Dev on the same Mac — is not this conversation's to talk about.
        guard awaitingReply, !replyAbandoned, !runningTools.isEmpty else {
            Log.write("confirm: a sheet is up, but no turn here is waiting on it")
            return
        }
        Log.write("confirm: sheet up (\(kind), \(editable ? "editable" : "read-only")) — waiting on the person")
        confirmWaiting = ConfirmWaiting(kind: kind, pid: pid, since: Date())
        statusLine = ConfirmWait.status(kind: kind)
        // Not gated on spoken progress: this is not narration of a step, it
        // is the one thing the person has to do for the job to go on.
        guard replySpeaks else { return }
        let line = ConfirmWait.announcement(kind: kind, editable: editable)
        lastNarrationAt = Date()
        lastSpokenStep = line
        Log.write("narrate: \"\(line)\"")
        // `speak`, not `speakAside`: an aside is dropped while anything else
        // is being said, and this line must not be — it is likely to arrive
        // while "Getting that ready to send" is still playing.
        voice.speak(line)
    }

    private func confirmSheetAnswered(pid: String) {
        guard let waiting = confirmWaiting, pid.isEmpty || waiting.pid == pid else { return }
        Log.write("confirm: sheet answered")
        confirmWaiting = nil
        // The result is the model's to report ("sent", "cancelled"), and it
        // is about to; a "still on it" in front of that would be noise.
        lastNarrationAt = Date()
        if let current = runningTools.values.first {
            statusLine = current
        } else if awaitingReply {
            statusLine = "thinking"
        }
    }

    /// Say "yeah, on it" now — before the gateway has been asked anything.
    ///
    /// The whole of the wait in front of a reply belongs to somebody else's
    /// network: measured warm on this Mac, a persistent `claude -p` child
    /// answers in 0.72 s and the same turn through Hermes takes 1.15–1.89 s,
    /// and the log put the first *spoken* word at 5.2 s. An opener written by
    /// the model cannot arrive before the model does, so it can never fill
    /// that gap — the only opener that can is one said from here.
    ///
    /// `InstantAck` restates the user's own request and never predicts an
    /// outcome, so this stays true even when the work fails. A turn it cannot
    /// describe from the user's words says nothing at all.
    ///
    /// Only when this turn is going to be spoken at all: an ack is speech,
    /// and it exists to fill the gap in front of speech. `replySpeaks` is now
    /// what says so — it was `turnBeganAt != nil`, which happened to mean
    /// "spoken" because the latency mark is nil for typed turns. That read
    /// the right answer off the wrong thing, and it stopped being right the
    /// moment somebody could ask for their *typed* replies to be spoken too.
    private func acknowledgeNow(_ request: String) {
        guard replySpeaks, config.instantAck,
              let line = InstantAck.phrase(for: request, variant: ackVariant) else { return }
        ackVariant += 1
        // Not `say`: an ack is not a step, and letting it set `lastSpokenStep`
        // would make the first real step look like a repeat and go unsaid.
        lastNarrationAt = Date()
        Log.write("ack: \"\(line)\"")
        // `speak`, not `speakAside`: the machine has to see this as speech.
        // An ack you can't interrupt would be the one bit of Moe that talks
        // over you, and the follow-up window's "Moe just spoke" clock has to
        // start here or the window opens in the wrong place.
        //
        // A turn the addressee gate dropped never reaches this method — the
        // engine hands back an empty transcript for those and `submit`
        // returns above — so an ack can only ever follow speech Moe has
        // already decided was addressed to it.
        Task { await voice.speak(line) }
    }

    /// Rotated so two turns in a row are not acknowledged in the same words.
    private var ackVariant = 0

    /// How long Moe must have been silent before a new step is worth saying.
    ///
    /// Was 12 s, which is most of a minute-long job spent in silence. The
    /// ack now covers the first beat, so a step line is the *second* thing
    /// heard rather than the first, and it can come sooner without stepping
    /// on an opener that no longer has to wait for the model.

    /// And before repeating the step that is still running.
    private static let stillWorkingGap: TimeInterval = 12

    /// One place that sends words to the voice mid-turn, so the clock the
    /// narration reads is never left behind by the thing it is measuring.
    /// `speakAside` is skipped outright while Moe is mid-sentence, which is
    /// what keeps a step line from ever cutting across an answer.
    private func say(_ line: String) {
        lastNarrationAt = Date()
        lastSpokenStep = line.hasSuffix(".") ? String(line.dropLast()) : line
        Log.write("narrate: \"\(line)\"")
        voice.speakAside(line)
    }

    /// The safety net under `flushPendingSpeech`: the model went quiet with no
    /// tool step to mark it — a provider that reports no progress, a pause
    /// between messages, a step Hermes filters off the wire.
    ///
    /// Only ever a finished sentence. A pause in the middle of one is a slow
    /// connection rather than the model going away, and half a clause read
    /// aloud is worse than the wait — so the cheap check happens here, before
    /// a task is made, and most deltas arm nothing at all.
    private func armSpeechStall() {
        speechStall?.cancel(); speechStall = nil
        guard replySpeaks, quietWork.speaks(.interim),
              let id = streamingTurnID,
              let turn = turns.first(where: { $0.id == id }),
              turn.text.count > spokenUpTo.count,
              let last = turn.text.last(where: { !$0.isWhitespace }),
              ".!?".contains(last) else { return }
        speechStall = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.awaitingReply, !self.replyAbandoned else { return }
            self.flushPendingSpeech()
        }
    }

    /// The end of a turn: speak whatever of the reply has not been spoken
    /// yet, and — whether or not anything is spoken — stop looking busy.
    ///
    /// The `mode = .idle` used to live on one path only: the one where
    /// there was nothing left to say. Every early return above it left
    /// `mode` at `.thinking`, and two of them are ordinary states, not
    /// edge cases — spoken replies switched off, and a meeting being
    /// recorded (replies are text-only then, by design). So a question
    /// asked mid-meeting left the island on the cyan working arc for the
    /// rest of the meeting and past the end of it: "Moe was stuck in
    /// thinking after the meeting saved".
    private func speakRemainder() {
        guard replySpeaks, !replyAbandoned,
              let id = streamingTurnID ?? turns.last?.id,
              let turn = turns.first(where: { $0.id == id }),
              // `turns.last` is a fallback for a reply that streamed nothing,
              // and a system turn can now be the last one — an engine notice
              // appended mid-turn. Speaking it would have Moe read "heads up
              // — 93% of your five hour limit used" aloud as if it were the
              // answer to what was asked. System turns are never spoken.
              turn.role != .system else { settleMode(); return }
        let rest = String(turn.text.dropFirst(spokenUpTo.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { spokenUpTo = turn.text; settleMode(); return }
        speakToEnd(of: turn.text)
    }

    /// Everything after `spokenUpTo`, sentence by sentence so each piece
    /// carries its own offset: a barge-in late in a long remainder then
    /// resumes from the sentence heard, not from the start of it.
    private func speakToEnd(of full: String) {
        var pending = String(full.dropFirst(spokenUpTo.count))
        while let sentence = Self.popSentence(&pending) {
            spokenUpTo += sentence
            voice.speak(sentence, replyEnd: spokenUpTo.count)
        }
        spokenUpTo = full
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voice.speak(pending, replyEnd: full.count)
        }
    }

    /// Split off one complete sentence, keeping the trailing space so the
    /// offset bookkeeping stays exact.
    ///
    /// `orClause` also breaks at a comma, dash, colon or semicolon once there
    /// is enough text to be worth saying. It is passed only for the first
    /// thing spoken in a reply, and it is the difference between Moe starting
    /// to talk and Moe waiting.
    ///
    /// Measured on a real turn: the first token arrived 2.2 s after the
    /// microphone closed and the first word was spoken at 4.1 s. The whole
    /// 173-character answer was one sentence, so there was no terminator to
    /// break on until generation had finished — 1.9 s of sitting on text that
    /// could have been coming out of the speaker. The prompt asks for one or
    /// two short sentences, which makes that the normal shape of a reply, not
    /// an edge case. A comma is a place a person pauses anyway, so breaking
    /// there costs nothing to listen to.
    private static func popSentence(_ buf: inout String, orClause: Bool = false,
                                    clauseAfter: Int = 30) -> String? {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–"]
        /// Short enough to still be a saving, long enough not to be a blurt.
        ///
        /// It governs a short opening *sentence* as much as a clause. A reply
        /// that began "Read it. It's the rollout call with…" was sending
        /// "Read it." to the synthesiser on its own: eight characters, its own
        /// render, and two words with no prosodic context to speak them in.
        /// Rendering costs roughly a fixed 100 ms plus 4 ms a character, so a
        /// chunk that small is nearly all overhead, and waiting for the rest
        /// of the line costs under 200 ms at the rate text arrives.
        let minFirst = 30
        let minClause = max(minFirst, clauseAfter)

        var idx = buf.startIndex
        var seen = 0
        while idx < buf.endIndex {
            let c = buf[idx]
            let longEnough = !orClause || seen >= minFirst
            let isTerminator = longEnough && terminators.contains(c)
            let isClause = orClause && seen >= minClause && clauseBreaks.contains(c)
            if isTerminator || isClause {
                let next = buf.index(after: idx)
                // "3.5" and "1,200" are not the end of anything.
                if isTerminator, c == ".", next < buf.endIndex, buf[next].isNumber { idx = next; seen += 1; continue }
                if isClause, next < buf.endIndex, buf[next].isNumber { idx = next; seen += 1; continue }
                // Only break on something we can see past. Mid-stream the
                // buffer ends the instant a chunk does, so a bare "It's 3."
                // waiting on its "5" looked exactly like a finished sentence
                // — and Moe said "It's three." and then "five degrees out".
                // The true end of a reply is spoken by `speakRemainder`, so
                // nothing is lost by waiting for one more character.
                if next < buf.endIndex, buf[next].isWhitespace {
                    let cut = next < buf.endIndex ? buf.index(after: next) : buf.endIndex
                    let s = String(buf[buf.startIndex..<cut])
                    buf = String(buf[cut...])
                    return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
                }
            }
            idx = buf.index(after: idx)
            seen += 1
        }
        return nil
    }

    // MARK: - Fix cards

    /// A failed tool's fix, as a card — once per code per turn.
    func offerFix(_ fix: ToolFix) {
        // Remembered before any card decision: `moe_open_settings` names only
        // a pane, and the watch needs this failure's subject and path.
        if let pane = fix.pane, case .grant = PermissionGuide.forCode(fix.code, pane: pane) {
            fixesByPane[pane] = (fix, personTurns)
        }
        guard !fixCodesThisTurn.contains(fix.code) else { return }
        // Recorded only once a card is made: a failure that gets none (the
        // screen helper Hermes already restarted, `retry`) must not stop a
        // later one in the same turn (the restart failed) from getting its card.
        guard let offer = FixOffer(fix) else { return }
        // Automation is read from a script's output, which a script can
        // forge: only macOS's own answer for the named app makes a card.
        if fix.code == .tccAutomation {
            let answer = fix.subject.map(automationConsent) ?? .unknown
            guard answer.isRefusal else {
                Log.write("fix card: tcc_automation not shown — macOS says \(answer) for that app")
                return
            }
        }
        fixCodesThisTurn.insert(fix.code)
        fixOffers.removeAll { $0.id == offer.id }
        fixOffers.append(offer)
        Log.write("fix card: \(fix.code.rawValue)" + (offer.settingsURL.map { " → \($0.absoluteString)" } ?? ""))
    }

    /// The card's button: open the pane (or sign in, or Connections), and the
    /// card goes.
    func performFix(_ offer: FixOffer) {
        fixOffers.removeAll { $0.id == offer.id }
        fixActions.perform(offer, self)
    }

    func dismissFix(_ offer: FixOffer) {
        fixOffers.removeAll { $0.id == offer.id }
    }

    // MARK: - Watch the grant, then carry on (slice 4)

    /// Start watching the grant that fixes `fix`, once its pane is open.
    /// False when it is not a grant, cannot be watched, or already is.
    /// A grant already on when the pane opens is not watched: there is no
    /// switch to wait for, and a "now on" note would be false.
    @discardableResult
    func watchGrant(for fix: ToolFix) async -> Bool {
        guard case .grant(let guide) = PermissionGuide.forCode(fix.code, pane: fix.pane) else { return false }
        return await grantWatch.start(fix: fix, guide: guide, conversationID: conversationID,
                                      personTurn: personTurns)
    }

    /// The flip. One background note, only to the conversation that failed
    /// and only while nothing newer the person said has superseded it.
    private func grantTurnedOn(_ watch: GrantWatch.Watch) -> GrantWatch.Outcome {
        fixOffers.removeAll { $0.fix.code == watch.fix.code }
        guard !shuttingDown else { return .dropped("the app is quitting") }
        guard watch.conversationID == conversationID else { return .dropped("another conversation is open") }
        guard watch.personTurn == personTurns else { return .dropped("the person has asked something newer") }
        guard !awaitingReply else { return .later }
        let note = Self.carryOnNote(watch.guide, fix: watch.fix)
        submit("\(watch.guide.name) is on now.", origin: turnOrigin, starter: .background, outgoing: note)
        return .sent
    }

    /// The words the brain gets when a grant it was waiting on flips.
    static func carryOnNote(_ guide: PermissionGuide, fix: ToolFix, app: String = BuildInfo.hostAppName) -> String {
        // CuaDriver's guides already say whose they are: "Accessibility (CuaDriver)".
        var what = guide.owner == .driver ? guide.name : "\(guide.name) for \(app)"
        if fix.code == .tccAutomation, let target = FixSubject.known(fix.subject, for: .tccAutomation) {
            what += " (to control \(target))"
        }
        return "(Background note, not from the person: \(what) is on now. Carry on with what you were doing.)"
    }

    /// `moe_open_settings`: the brain asks for a pane, by id. Nil when it was
    /// opened and watched; otherwise why not. The plugin already refused a
    /// turn nobody is at; this is the app's own check, and the one that
    /// counts, because the signal is a distributed notification any process
    /// on this Mac can post. So every condition is something only this turn
    /// can have produced:
    /// - a turn the person started, in flight, with a `moe_open_settings`
    ///   step running in it (osascript or the model's shell is another step);
    /// - a real failure for this pane, from Hermes's own `fix` field, in this
    ///   person turn or the one before it (the one where Moe offered: the
    ///   yes is the next turn);
    /// - not already opened this turn, and not already watched;
    /// - the grant not already on (checked before anything opens).
    @discardableResult
    func openSettingsForBrain(pane: String) async -> String? {
        func no(_ why: String) -> String {
            Log.write("open settings: refused \(pane.prefix(40)) — \(why)")
            return why
        }
        guard awaitingReply, !replyAbandoned, turnStarter == .person else {
            return no("no turn of the person's is in flight")
        }
        guard runningToolNames.values.contains(where: Self.isOpenSettingsTool) else {
            return no("no moe_open_settings step is running")
        }
        guard ToolFix.knownPanes.contains(pane) else { return no("not an allowlisted pane") }
        guard let failed = fixesByPane[pane],
              failed.personTurn == personTurns || failed.personTurn == personTurns - 1 else {
            return no("no tool failed for that pane in this conversation just now")
        }
        let fix = failed.fix
        guard panesOpened[pane] != personTurns else { return no("already opened this turn") }
        guard grantWatch.watches[fix.code] == nil else { return no("already watched") }
        guard case .grant(let guide) = PermissionGuide.forCode(fix.code, pane: pane),
              let url = guide.settingsURL else { return no("no pane for that") }
        panesOpened[pane] = personTurns
        guard await grantWatch.isOff(fix: fix, guide: guide) else {
            return no("\(guide.name) is already on")
        }
        openSettingsURL(url)
        await watchGrant(for: fix)
        Log.write("open settings: the brain opened \(pane) for \(fix.code.rawValue)")
        return nil
    }

    static func isOpenSettingsTool(_ name: String) -> Bool {
        name == "moe_open_settings" || name.hasSuffix("__moe_open_settings")
    }

    /// The plugin's signal (moe-screen open_settings.py): a distributed
    /// notification whose object is the pane id. Anything on this Mac can
    /// post one, which is why `openSettingsForBrain` checks everything again.
    private func watchForOpenSettings() {
        guard openSettingsObserver == nil else { return }
        openSettingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.openSettingsSignal, object: nil, queue: .main) { [weak self] note in
            guard let pane = note.object as? String else { return }
            Task { @MainActor in await self?.openSettingsForBrain(pane: pane) }
        }
    }

    /// Kept equal to SIGNAL in moe-home/hermes-plugins/moe-screen/open_settings.py.
    static let openSettingsSignal = Notification.Name("com.moe.openSettings")

    /// `moe_location` answers only while a turn the person started is in
    /// flight with that step running in it — the same test, and the same
    /// reason, as `openSettingsForBrain`.
    var locationStepRunning: Bool {
        awaitingReply && !replyAbandoned && turnStarter == .person
            && runningToolNames.values.contains(where: LocationBridge.isLocationTool)
    }

    func watchForLocation() {
        location.stepRunning = { [weak self] in self?.locationStepRunning ?? false }
        location.watch()
    }

    /// Memoe's own settings for the brain (docs/SETTINGS-ASSISTANT.md): the
    /// catalogue is published now and again after every change, and a change
    /// or an open is answered only while a turn the person started is in
    /// flight with that step running — the same test as `moe_location`.
    var settingsStepRunning: Bool {
        awaitingReply && !replyAbandoned && turnStarter == .person
            && runningToolNames.values.contains(where: SettingsBridge.isSettingsTool)
    }

    func watchForSettings() {
        // Live values (the ten-minute job, the learning consents) are read off
        // the main thread first, so the published file never carries nil-guesses.
        Task { @MainActor [weak self] in
            await SettingsCatalogue.Live.refresh()
            if let self { SettingsCatalogue.publish(self) }
        }
        settingsPublish = $config
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await SettingsCatalogue.Live.refresh()
                    if let self { SettingsCatalogue.publish(self) }
                }
            }
        settingsBridge.stepRunning = { [weak self] in self?.settingsStepRunning ?? false }
        settingsBridge.open = { [weak self] page, title in
            guard let self else { return }
            SettingsWindow.show(conductor: self, at: page, spotlight: title)
        }
        settingsBridge.watch(self)
    }

    // MARK: - Transcript

    private func appendToStreamingTurn(_ chunk: String) {
        if let id = streamingTurnID, let idx = turns.firstIndex(where: { $0.id == id }) {
            turns[idx].text += chunk
        } else {
            let t = Turn(role: .moe, text: chunk, isStreaming: true)
            streamingTurnID = t.id
            turns.append(t)
        }
    }

    private func finishStreamingTurn(_ full: String) {
        let steps = pendingTools
        pendingTools = []
        let links = pendingLinks
        pendingLinks = []
        let thinking = pendingThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingThinking = ""
        let took = steps.isEmpty && thinking.isEmpty ? nil : workingSince.map { Date().timeIntervalSince($0) }
        workingStep = nil
        guard let id = streamingTurnID, let idx = turns.firstIndex(where: { $0.id == id }) else {
            if !full.isEmpty {
                turns.append(Turn(role: .moe, text: full, tools: steps, took: took, links: links,
                                  thinking: thinking))
            }
            return
        }
        if !full.isEmpty { turns[idx].text = full }
        turns[idx].tools = steps
        turns[idx].took = took
        turns[idx].links = links
        turns[idx].thinking = thinking
        turns[idx].isStreaming = false
        recordHistory(turns[idx])
        if turns[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns.remove(at: idx)
        }
    }
}

extension Conductor {
    /// The budget the user set covers a normal sentence; a rewrite takes
    /// about as long as the text it produces, so a 600-character dictation
    /// timed out and silently got the rules-only version. Scale with length,
    /// capped at 2.5x. Waiting longer costs nothing on the happy path — a
    /// gateway that is down still fails in milliseconds.
    static func polishBudget(for text: String, base: TimeInterval) -> TimeInterval {
        let scaled = base * (1 + Double(text.count) / 300)
        return min(scaled, base * 2.5)
    }

    /// The first System Events call from the gateway pops macOS's Automation
    /// prompt (attributed to Memoe.app). Left to chance it lands mid-click, in
    /// the middle of a task; asked here — a read-only call the first time the
    /// user talks to Moe — it lands while they are already engaging with it.
    static func primeAutomationOnce() {
        let key = "automationPrimed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to return name of first application process whose frontmost is true"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            Log.write("automation: primed (status \(p.terminationStatus))")
        }
    }
}

#if DEBUG
// MARK: - The snapshot seam (docs/PANEL-FINDINGS.md §9)
//
// `Moe --panel-snapshot` draws the island's *real* views, and those views read
// the published properties above. Every one of them is `private(set)`, which
// in Swift means "settable from this file", so the only place a state can be
// posed for a picture is here.
//
// Nothing below is compiled into a release build. Nothing below opens a
// device, starts a brain, touches a meeting or writes a file: it assigns
// stored properties and stops. That is the whole of §9's "no device is opened
// and nothing of the user's is touched".
extension Conductor {

    /// A state to pose the island in. Every field defaults to the resting
    /// value, so a shot names only what it is about.
    struct SnapshotState {
        var mode: Mode = .idle
        /// A brain turn in flight: what a message typed now has to wait on.
        var awaitingReply = false
        var dictation: DictationState = .off
        var dictationLatched = false
        var talkLatched = false
        var dictationPartial = ""
        var turns: [Turn] = []
        var partial = ""
        var statusLine = ""
        var level: Float = 0
        var alwaysListening = false
        var inConversation = false
        /// The follow-up window, nobody speaking (`betweenTurns`).
        var betweenTurns = false
        var pendingNudge: String?
        var pendingNudgeWhen: String?
        var pendingNudgeHandle: NudgeHandle?
        var notices: [InboxItem] = []
        var showingInbox = false
        var noticePeek: InboxItem?
        var noticeReturn: NoticeReturn?
        var reminderTick: ReminderTick?
        var replyingTo: String?
        var acting = false
        var meeting: MeetingState = .off
        var meetingClock = "00:00"
        var meetingStatus = ""
        var meetingTimeline: [Segment] = []
        var meetingOutcome: MeetingSummary.Outcome?
        var meetingHealth = ""
        var meetingPaused = false
        var meetingWhisper = false
        var meetingLiveActions: [MeetingNotes.ActionItem] = []
        var meetingCatchUp: String?
        var meetingMention: String?
        var meetingFlash = 0
        var meetingHint: String?
        var meetingDelivery = ""
        /// A spoken turn at work, so the island offers "Work silently".
        var working = false
        var workingSilently = false
        /// The working row's words and clock (`WorkingRow`).
        var workingStep: String?
        var workingSince: Date?
        /// The microphone muted mid-conversation.
        var micMuted = false
        /// The answer whose voice is out, by its index in `turns`, and
        /// whether it is held.
        var voicedTurn: Int?
        var replyPaused = false
        /// Fix cards on show (`FixOffer`).
        var fixes: [ToolFix] = []
        /// Moe has the screen, in this app (`drivingApp`), or the browser.
        var drivingApp: String?
        var browsing = false
        /// A message typed while the turn in flight works (`queuedTyped`).
        var queuedTyped: String?
    }

    /// Whether a reply is owed — for the tests that drive a turn through.
    var isAwaitingReplyForTests: Bool { awaitingReply }

    /// Put the Conductor into a posed state. Assignment only.
    func pose(_ s: SnapshotState) {
        // First: the last pose's held message must not be sent by this one
        // ending its turn (`awaitingReply`'s didSet).
        queuedTyped = nil
        mode = s.mode
        dictation = s.dictation
        dictationLatched = s.dictationLatched
        talkLatched = s.talkLatched
        dictationPartial = s.dictationPartial
        turns = s.turns
        partial = s.partial
        statusLine = s.statusLine
        level = s.level
        alwaysListening = s.alwaysListening
        inConversation = s.inConversation
        betweenTurns = s.betweenTurns
        pendingNudge = s.pendingNudge
        pendingNudgeWhen = s.pendingNudgeWhen
        pendingNudgeHandle = s.pendingNudgeHandle
        notices = s.notices
        showingInbox = s.showingInbox
        noticePeek = s.noticePeek
        reminderTick = s.reminderTick
        // The way back belongs to the conversation on screen, whatever its id.
        replyingTo = s.replyingTo
        noticeReturn = s.noticeReturn.map { NoticeReturn(from: $0.from, fromTitle: $0.fromTitle, to: conversationID) }
        acting = s.acting
        meeting = s.meeting
        meetingClock = s.meetingClock
        meetingStatus = s.meetingStatus
        meetingTimeline = s.meetingTimeline
        meetingOutcome = s.meetingOutcome
        meetingHealth = s.meetingHealth
        meetingPaused = s.meetingPaused
        meetingWhisper = s.meetingWhisper
        meetingLiveActions = s.meetingLiveActions
        meetingCatchUp = s.meetingCatchUp
        meetingMention = s.meetingMention
        meetingFlash = s.meetingFlash
        meetingHint = s.meetingHint
        meetingDelivery = s.meetingDelivery
        // Posed rather than set through `turnOrigin`, which is assigned in
        // exactly one place (ReplyRoutingWiringTests).
        posedWorking = s.working
        awaitingReply = s.awaitingReply
        quietWork = WorkSilently()
        if s.workingSilently { quietWork.toggle() }
        workingSilently = s.workingSilently
        workingStep = s.workingStep
        workingSince = s.workingSince
        micMuted = s.micMuted
        voicedTurnID = s.voicedTurn.flatMap { s.turns.indices.contains($0) ? s.turns[$0].id : nil }
        replyHeldByKey = s.replyPaused
        fixOffers = s.fixes.compactMap { FixOffer($0) }
        drivingApp = s.drivingApp
        browsing = s.browsing
        queuedTyped = s.queuedTyped
    }
}
#endif

/// Where a reply's voice is: not out, playing, or held where it stopped.
enum ReplyVoice: Equatable { case silent, playing, paused }

// MARK: - The inbox (docs/INBOX.md)

/// Everything Moe brings up on its own is a `InboxItem` in one list. It arrives
/// as a line under the notch and an amber glow, waits in the island's inbox
/// and the app's Inbox page, and is finished there — Done, Got it, an
/// answer, a send — which tells whatever raised it. Acting on one loads it
/// into the old one-card fields (`pendingNudge` and its handle) for exactly
/// as long as the action takes, so every rule those actions already keep —
/// the send gate on an offer's draft, a held send's expiry, the note that
/// lets the brain close a follow-up — still holds, unchanged.
extension Conductor {

    // MARK: What is waiting

    /// On the island's list, newest first.
    var islandNotices: [InboxItem] {
        let now = Date()
        return notices.filter { $0.onIsland(now: now) }.sorted { $0.at > $1.at }
    }

    /// Waiting anywhere (the app's count): hidden ones included.
    var waitingNotices: [InboxItem] {
        let now = Date()
        return notices.filter { $0.isWaiting(now: now) }.sorted { $0.at > $1.at }
    }

    /// Something arrived that the person has not looked at: the amber glow.
    var hasUnseenNotice: Bool { islandNotices.contains { !$0.seen } }

    func notice(_ id: String) -> InboxItem? { notices.first { $0.id == id } }

    func loadNotices() {
        notices = NoticeStore.load()
        archiveBacklogOnce()
    }

    private func saveNotices() {
        NoticeStore.save(notices)
    }

    private func update(_ id: String, _ change: (inout InboxItem) -> Void) {
        guard let i = notices.firstIndex(where: { $0.id == id }) else { return }
        change(&notices[i])
        saveNotices()
    }

    // MARK: Arriving

    /// An inbox file, with everything its writer said about it.
    func receive(_ m: ReminderChannels.Message) {
        guard !MachineryNotice.isJobFailure(m.text) else {
            Log.write("job failure notice dropped, not shown: \(m.text.prefix(80))")
            return
        }
        var input = NoticeInput(text: m.text, at: m.at)
        input.title = m.title
        input.summary = m.summary
        input.kind = m.kind
        input.options = m.options
        input.source = m.source
        input.job = m.job
        input.jobID = m.jobID
        input.loops = m.loops
        input.said = m.said
        input.instruction = m.instruction
        input.offer = m.offer
        input.expiredText = m.expiredText
        input.subject = m.subject
        let handle = NudgeHandle.forInbox(m)
        receiveNotice(input, expiresAt: handle.expiresAt,
                      origin: InboxGate.Origin(writer: m.writer, timeCritical: m.timeCritical))
    }

    /// The one door into the inbox. A notice about something that already
    /// has an open card (the same `subject`) updates that card in place and
    /// raises it; the same words already waiting are not a second notice
    /// either: the first is brought back to the top instead.
    func receiveNotice(_ input: NoticeInput, expiresAt: Date? = nil,
                       origin: InboxGate.Origin = InboxGate.Origin()) {
        // A turn that said nothing ("noop", "[SILENT]", empty) is not a
        // notice. 2026-09-30: a resumed chat's silent warm-up became a
        // Heads-up card reading "noop".
        guard !MachineryNotice.isSilence(input.text) else {
            Log.write("inbox: a silent reply dropped, not shown: \(input.text.prefix(40))")
            return
        }
        // A note a confirmation card left is said once. Three cards for the
        // same send, withdrawn one after another, used to pull the same
        // "That WhatsApp send … was withdrawn" back to the top three times.
        // Dismissed counts: ✕ finishes a card now, and a dismissed note must
        // not come back as a new one.
        if input.source == ConfirmLifecycle.noteSource,
           notices.contains(where: { $0.body == input.text }) {
            Log.write("inbox: the same confirmation note again — logged, not raised: \(input.text.prefix(60))")
            return
        }
        // Every card carries a do-it (docs/INBOX-QUIET.md decision 1). One
        // that does not is kept under Done where it can be found, and
        // nothing glows: `InboxGate` is the rule and its table of examples.
        if case .quiet(let why) = InboxGate.decide(input, origin: origin) {
            if let kept = InboxGate.kept(input, among: notices) {
                notices.insert(kept, at: 0)
                saveNotices()
            }
            Log.write("inbox: kept quiet (\(why.logged)) — under Done, not shown: \(input.text.prefix(60))")
            return
        }
        var n = NoticeMaker.make(input)
        n.expiresAt = expiresAt
        // One card per real-world thing (docs/INBOX-QUIET.md decision 8): a
        // reworded repeat about the same situation, follow-up or meeting
        // updates the card that is already open rather than adding one.
        if let i = InboxLifecycle.openCard(about: n.subject, in: notices) {
            InboxLifecycle.absorb(n, into: &notices[i])
            notices[i].expiresAt = expiresAt
            saveNotices()
            Log.write("inbox: \(n.subject) again — its card updated in place: \(n.title)")
            showPeek(notices[i])
            return
        }
        // The same words with no subject to go by: the fallback.
        if let i = notices.firstIndex(where: { $0.status == .open && $0.body == input.text }) {
            notices[i].seen = false
            notices[i].hidden = false
            saveNotices()
            Log.write("inbox: the same message again, raised back up: \(input.text.prefix(60))")
            return
        }
        notices.insert(n, at: 0)
        saveNotices()
        Log.write("inbox: \(n.kind.rawValue) — \(n.title)")
        showPeek(n)
    }

    /// The app's own card at 80 % of a plan's allowance, with the one button
    /// that buys the pack (docs/PLANS-AND-CAPS-2026-11-13.md §7 D7). Not
    /// through `InboxGate`: that rule is about files other writers leave, and
    /// this card's do-it is the button. One per pack — a second call for the
    /// same pack while one is open raises that card instead of adding one.
    func postAllowanceCard(pack: String, title: String, summary: String, button: String) {
        let subject = "allowance:\(pack)"
        if let i = notices.firstIndex(where: { $0.status == .open && $0.subject == subject }) {
            notices[i].seen = false
            notices[i].hidden = false
            saveNotices()
            return
        }
        var n = InboxItem(kind: .headsUp, title: title, summary: summary, body: summary, at: Date())
        n.subject = subject
        n.source = "Away"
        n.buy = pack
        n.buyTitle = button
        notices.insert(n, at: 0)
        saveNotices()
        Log.write("inbox: allowance card — \(pack)")
        showPeek(n)
    }

    /// The card's button: open the pack's checkout in the browser and finish
    /// the card. Paying is Stripe's page; nothing is charged by the tap.
    func buyNoticePack(_ id: String) {
        guard let n = notice(id), !n.buy.isEmpty else { return }
        cloud.buyPack(n.buy)
        update(id) { $0.status = .done; $0.doneAt = Date(); $0.outcome = "Opened checkout"; $0.seen = true }
    }

    /// The line under the notch, for a few seconds, then the glow alone.
    /// Never during a meeting (the island is the meeting's then) and never
    /// over a conversation in progress — it waits in the inbox either way.
    private func showPeek(_ n: InboxItem) {
        guard meeting == .off else { return }
        noticePeek = n
        onWantsIsland?(true)
        peekTimer?.invalidate()
        let t = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.noticePeek = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        peekTimer = t
    }

    /// Snoozes that have come due glow again; held sends past their day are
    /// finished as expired, with a heads-up saying nothing was sent.
    func tidyNotices(now: Date = Date()) {
        var changed = false
        for i in notices.indices where notices[i].status == .open {
            if let until = notices[i].snoozedUntil, until <= now {
                notices[i].snoozedUntil = nil
                notices[i].seen = false
                changed = true
                showPeek(notices[i])
            }
            if let expires = notices[i].expiresAt, expires <= now, !notices[i].expiredText.isEmpty {
                let text = notices[i].expiredText
                notices[i].status = .done
                notices[i].doneAt = now
                notices[i].outcome = "Expired"
                changed = true
                receiveNotice(NoticeInput(text: text, at: now), origin: InboxGate.Origin(consequence: true))
            }
        }
        if changed { saveNotices() }
        if now.timeIntervalSince(lastSourceSweep) >= 60 || now < lastSourceSweep {
            lastSourceSweep = now
            closeResolvedNotices(now: now)
        }
    }

    // MARK: Closed by their source

    /// Cards whose source has resolved are finished (docs/INBOX-QUIET.md
    /// slice 1): an offer whose situation settled, was waved away or went
    /// stale; a follow-up the ledger has closed; a meeting heads-up once the
    /// meeting has started. They go to Done with what closed them, and
    /// nothing is told — the source is the one that already knows.
    func closeResolvedNotices(now: Date = Date(), sources: InboxLifecycle.Sources? = nil) {
        guard notices.contains(where: { $0.status == .open }) else { return }
        let gone = InboxLifecycle.resolved(notices, now: now, sources: sources ?? Self.liveSources(now: now))
        guard !gone.isEmpty else { return }
        for (id, outcome) in gone {
            guard let i = notices.firstIndex(where: { $0.id == id }) else { continue }
            InboxLifecycle.archive(&notices[i], now: now, outcome: outcome)
            Log.write("inbox: closed by its source (\(outcome.lowercased())) — \(notices[i].title)")
        }
        saveNotices()
    }

    /// What the sweep reads: the situations file and the follow-up ledger,
    /// each once per sweep. A file that will not read is nil, and closes
    /// nothing.
    nonisolated static func liveSources(situations: Data? = try? Data(contentsOf: SituationOffer.situationsURL),
                                        ledger: Data? = try? Data(contentsOf: openLoopsURL),
                                        now: Date = Date()) -> InboxLifecycle.Sources {
        let readable = situations.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } != nil
        let offerLive: (String) -> Bool? = { id in
            guard readable, let situations else { return nil }
            return SituationOffer.load(id: id, from: situations, now: now) != nil
        }
        return InboxLifecycle.Sources(offerLive: offerLive, openLoops: openLoops(ledger))
    }

    nonisolated static var openLoopsURL: URL { Paths.home.appendingPathComponent("proactive/open.json") }

    /// The slugs open in the ledger (deliver.py `read_open`: `{"open": {slug: …}}`),
    /// or nil when there is no such file or it is not that shape.
    nonisolated static func openLoops(_ data: Data?) -> Set<String>? {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let open = obj["open"] as? [String: Any] else { return nil }
        return Set(open.keys)
    }

    // MARK: The backlog, archived once

    /// The flag that says the backlog was archived on this home. Beside
    /// notices.json, never under `inbox/`, where writers drop their files.
    nonisolated static var backlogFlagURL: URL { Paths.home.appendingPathComponent("notices-backlog-archived") }

    /// Once per home, the first launch with this version: every open card is
    /// archived to Done except ready work from the last two days, which is
    /// the live signal (docs/INBOX-QUIET.md decision 10). Quiet: nothing is
    /// told, no follow-up is closed and the learner hears nothing — this is
    /// tidying, not the person's answer to any of them.
    @discardableResult
    func archiveBacklogOnce(now: Date = Date(), flag: URL = Conductor.backlogFlagURL) -> Int {
        guard !FileManager.default.fileExists(atPath: flag.path) else { return 0 }
        let ids = Set(InboxLifecycle.backlog(notices, now: now))
        for i in notices.indices where ids.contains(notices[i].id) {
            InboxLifecycle.archive(&notices[i], now: now)
        }
        if !ids.isEmpty { saveNotices() }
        try? FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = "archived \(ids.count) card(s) at \(ISO8601DateFormatter().string(from: now))\n"
        FileManager.default.createFile(atPath: flag.path, contents: Data(stamp.utf8))
        Log.write("inbox: the backlog archived once — \(ids.count) card(s) moved to Done")
        return ids.count
    }

    // MARK: The island's inbox

    func toggleInbox() {
        if showingInbox { closeInbox() } else { openInbox() }
    }

    func closeInbox() {
        if showingInbox { showingInbox = false }
    }

    /// Looking at the list is seeing what is on it: the glow stops.
    func openInbox() {
        showingInbox = true
        noticePeek = nil
        var changed = false
        for i in notices.indices where notices[i].onIsland() && !notices[i].seen {
            notices[i].seen = true
            changed = true
        }
        if changed { saveNotices() }
    }

    /// "Later" on a finished helper's heads-up: off the island's list, still
    /// in the app's.
    func hideNotice(_ id: String) {
        update(id) { $0.hidden = true; $0.seen = true }
    }

    /// ✕, and "Not now" on a card that is not an offer: it is finished and
    /// leaves the count (docs/INBOX-QUIET.md). It used to only hide the card
    /// from the island, so the app's Inbox count kept every one for good —
    /// 43 of the owner's 74 on 2026-10-06. An offer is declined through its
    /// own action, so the learner hears "not now"; an away reminder is put
    /// off; a held send is not sent; anything else is finished quietly and a
    /// follow-up behind it is held, like Done.
    func dismissNotice(_ id: String) {
        guard let n = notice(id), n.status == .open else { return }
        if !n.offer.isEmpty {
            declineNotice(id, kind: false)
        } else if !n.awayCarry.isEmpty {
            awayNotice(id, "later")
        } else if !n.expiredText.isEmpty {
            finishNotice(id, outcome: "Not sent")
        } else {
            finishNotice(id, outcome: "Dismissed")
        }
    }

    // MARK: Many at once (the Inbox page)

    /// Mark all read: nothing waiting glows any more.
    func markAllNoticesRead() {
        var changed = false
        for i in notices.indices where notices[i].status == .open && !notices[i].seen {
            notices[i].seen = true
            changed = true
        }
        noticePeek = nil
        if changed { saveNotices() }
    }

    /// Archive all, or the ones selected: each finished and kept under Done
    /// for the week. Quiet — no brain note, no learner line — but a
    /// follow-up behind one is still held through the ledger, so what was
    /// archived does not come straight back on the next pass.
    func archiveNotices(_ ids: [String], now: Date = Date()) {
        let wanted = Set(ids)
        var held: [InboxItem] = []
        var archived = 0
        for i in notices.indices where wanted.contains(notices[i].id) && notices[i].status == .open {
            let n = notices[i]
            archived += 1
            ReminderChannels.markAnsweredOnScreen(n.said)
            if n.offer.isEmpty, n.expiredText.isEmpty, !n.loops.isEmpty || n.job == "moe-proactive" { held.append(n) }
            InboxLifecycle.archive(&notices[i], now: now)
        }
        guard archived > 0 else { return }
        saveNotices()
        Log.write("inbox: archived \(archived) card(s)")
        if let ledger = loopLedger, !held.isEmpty {
            Task {
                for n in held {
                    let text = NoticeWords.oneLine(n.said.isEmpty ? n.body : n.said, max: 600)
                    let r = await ledger.done(loops: n.loops, text: text)
                    Log.write("inbox: archived, loop done \(n.loops.joined(separator: ",")) → exit \(r.map { String($0.exit) } ?? "none")")
                }
            }
        }
    }

    // MARK: Finishing one

    /// Done (a reminder), Got it (a brief, a heads-up): finished, and its
    /// source told. A follow-up Moe is keeping is closed through the brain,
    /// which owns that ledger (`moe_followups`); the copy on a phone is
    /// settled; an away reminder is quieted for good.
    func finishNotice(_ id: String, outcome: String = "Done") {
        guard let n = notice(id), n.status == .open else { return }
        ReminderChannels.markAnsweredOnScreen(n.said)
        if !n.awayCarry.isEmpty { cloud.carryReminderAnswered(n.awayCarry, never: false) }
        // Done on an offer is "handled it myself", never "not wanted": it
        // used to be recorded as not-now, so every offer the person acted on
        // their own taught the learner to offer less (docs/INBOX-QUIET.md).
        // "handled" carries no weight there (lib/learner.py WEIGHTS).
        if !n.offer.isEmpty { SituationOffer.record(n.offer, "handled") }
        if !n.expiredText.isEmpty {
            // A send held for their yes, answered no: never its replay
            // instruction, only that it is not to go.
            noteToBrain("""
            (Background note, not from the user. They declined a send you held for their yes: \
            "\(NoticeWords.oneLine(n.body, max: 400))" It is not sent — do not send it. \
            Do not reply to this message.)
            """)
        } else if n.offer.isEmpty, !n.loops.isEmpty || n.job == "moe-proactive" {
            holdFollowUp(n, outcome: outcome)
        }
        update(id) {
            $0.status = .done
            $0.doneAt = Date()
            $0.outcome = outcome
            $0.seen = true
        }
        Log.write("inbox: \(outcome.lowercased()) — \(n.title)")
    }

    /// Done, Skip or Got it on something the background pass raised: its
    /// loops closed and its subject held quiet until the thing it came from
    /// changes (`deliver.py loop done`). Always the words too — most of the
    /// Miriam nags carried no loop, so the words are what the hold is built
    /// from. An older deliver.py without the command falls back to asking
    /// the brain, as before.
    private func holdFollowUp(_ n: InboxItem, outcome: String) {
        let text = NoticeWords.oneLine(n.said.isEmpty ? n.body : n.said, max: 600)
        let ledger = loopLedger
        Task {
            let r = await ledger?.done(loops: n.loops, text: text)
            Log.write("inbox: loop done \(n.loops.joined(separator: ",")) → exit \(r.map { String($0.exit) } ?? "none")"
                      + (r?.reminder.isEmpty == false ? ", reminder “\(r!.reminder)”" : ""))
            if LoopLedger.unheard(r), !n.loops.isEmpty {
                self.closeThroughBrain(n)
            }
            if let r, !r.reminder.isEmpty, outcome == "Done" || outcome == "Got it" {
                self.reminderTick = ReminderTick(noticeID: n.id, title: r.reminder)
            }
        }
    }

    private func closeThroughBrain(_ n: InboxItem) {
        noteToBrain("""
        (Background note, not from the user. They marked this done on the island: \
        "\(NoticeWords.oneLine(n.body, max: 400))" Close follow-up \(n.loops.joined(separator: ", ")) \
        with the moe_followups tool (action close). Do not reply to this message.)
        """)
    }

    private func snoozeThroughBrain(_ n: InboxItem, until: Date) {
        let f = ISO8601DateFormatter()
        noteToBrain("""
        (Background note, not from the user. They snoozed this on the island until \
        \(f.string(from: until)): "\(NoticeWords.oneLine(n.body, max: 400))" Snooze follow-up \
        \(n.loops.joined(separator: ", ")) to then with the moe_followups tool. Do not reply to this message.)
        """)
    }

    /// Yes to "Also mark it done in Reminders?": the one write to their
    /// Reminders, and only on this tap.
    func tickReminder() {
        guard let t = reminderTick else { return }
        reminderTick = nil
        Task {
            let outcome = await RemindersTick.complete(t.title)
            Log.write("inbox: reminders tick “\(t.title)” → \(outcome)")
            if outcome != .done {
                self.showTickTrouble(outcome == .noAccess
                    ? "Moe can't reach Reminders. Allow it in System Settings › Privacy & Security › Reminders."
                    : "Couldn't find “\(t.title)” open in Reminders.")
            }
        }
    }

    func dismissReminderTick() { reminderTick = nil }

    private func showTickTrouble(_ text: String) {
        tickTrouble = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.tickTrouble == text { self?.tickTrouble = nil }
        }
    }

    /// A quiet note for the brain; in tests, to `dismissalNoteForTests`.
    private func noteToBrain(_ note: String) {
        if let hook = dismissalNoteForTests { hook(note) } else {
            bridge.send(note, silent: true, starter: .background)
        }
    }

    /// Later: off the list until then, back with a glow when it is due. A
    /// follow-up's own raise time moves too, so the pass that raised it does
    /// not raise it again in the meantime.
    func snoozeNotice(_ id: String, until: Date) {
        guard let n = notice(id), n.status == .open else { return }
        if !n.loops.isEmpty {
            let ledger = loopLedger
            Task {
                var fallback = ledger == nil
                for slug in n.loops {
                    let r = await ledger?.snooze(slug, until: until)
                    Log.write("inbox: loop snooze \(slug) → exit \(r.map { String($0.exit) } ?? "none")")
                    if LoopLedger.unheard(r) { fallback = true }
                }
                if fallback { self.snoozeThroughBrain(n, until: until) }
            }
        }
        update(id) { $0.snoozedUntil = until; $0.seen = true }
        Log.write("inbox: snoozed until \(until) — \(n.title)")
    }

    /// The snooze menu's choices, as a person says them.
    static func snoozeChoices(now: Date = Date(), calendar: Calendar = .current) -> [(label: String, until: Date)] {
        var out: [(String, Date)] = [("15 minutes", now.addingTimeInterval(15 * 60)),
                                     ("1 hour", now.addingTimeInterval(3600))]
        let hour = calendar.component(.hour, from: now)
        if hour < 17, let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) {
            out.append(("This evening", evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            out.append(("Tomorrow morning", morning))
        }
        return out
    }

    // MARK: Reading one

    /// Open: the reading card on screen, wherever the person is.
    func openNotice(_ id: String) {
        update(id) { $0.seen = true }
        noticePeek = nil
        onOpenNoticeCard?(id)
    }

    /// Hear it: spoken, and the brain told, as Play always did.
    func playNotice(_ id: String) {
        guard let n = notice(id) else { return }
        activate(n)
        playNudge()
        update(id) { $0.seen = true }
    }

    // MARK: Answering one

    /// A reply, a chip, or "Continue in island" with nothing typed yet.
    ///
    /// The owner, 2026-09-29: a reply to a card went into whatever thread was
    /// open. It goes to a new conversation now, named after the card with the
    /// card at the top — unless the card is about what is being talked about
    /// right now (`NoticeThread.continuesHere`). The conversation it left is
    /// kept, one tap away (`noticeReturn`).
    func replyToNotice(_ id: String, text: String) {
        guard let n = notice(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !awaitingReply || trimmed.isEmpty else {
            turns.append(Turn(role: .system, text: "Still working on the last one — one sec."))
            return
        }
        moveToNoticeConversation(n)
        showingInbox = false
        let shown = Self.shownInChat(n)
        if trimmed.isEmpty {
            // Nothing typed yet (the owner, 2026-09-29: "Do I have to write
            // something, or how do I exit out?"). Moe says it in the
            // conversation, as Moe; the island says above the field what the
            // field is for, with Cancel; the item is finished only when an
            // answer is sent.
            turns.append(Turn(role: .moe, text: shown))
            let handle = handle(for: n)
            let note = handleNote(handle)
            nudgeReplyNote = """
            (Background note, not from the user. You put this on the island and they opened a \
            conversation about it: \"\(n.body)\" The message below is about it. \
            \(note.inline) Act on their answer, then reply briefly.)
            """ + (note.after.isEmpty ? "" : "\n\n" + note.after)
            replyingTo = id
            update(id) { $0.seen = true }
            onOpenIsland?()
            return
        }
        activate(n)
        replyToNudge(trimmed, shownAs: shown)
        answeredNotice(id, with: trimmed)
        onWantsIsland?(true)
    }

    /// What the chat shows for an item: a short one as Moe saying it, a long
    /// one as a card with its title and summary (the whole is in the inbox).
    static func shownInChat(_ n: InboxItem) -> String {
        if n.body.count <= NoticeMaker.briefLength { return n.body }
        return "> **\(n.title)**" + (n.summary.isEmpty ? "" : "\n> \(n.summary)")
    }

    private func answeredNotice(_ id: String, with answer: String) {
        guard let n = notice(id), n.status == .open else { return }
        ReminderChannels.markAnsweredOnScreen(n.said)
        update(id) {
            $0.status = .done
            $0.doneAt = Date()
            $0.outcome = "Answered: \(NoticeWords.oneLine(answer, max: 40))"
            $0.seen = true
        }
    }

    /// Cancel on "Replying to…": nothing is sent, the item waits in the inbox
    /// as it was, and the island goes back where it came from.
    func cancelNoticeReply() {
        guard let id = replyingTo else { return }
        replyingTo = nil
        nudgeReplyNote = nil
        if let n = notice(id), let last = turns.last, last.role == .moe, last.text == Self.shownInChat(n) {
            turns.removeLast()
        }
        if let r = noticeReturn, r.to == currentConversationID, turns.isEmpty {
            returnFromNotice()
        }
        openInbox()
    }

    private func moveToNoticeConversation(_ n: InboxItem) {
        let recent = turns.suffix(6).map(\.text)
        let last = turns.last?.at
        guard !turns.isEmpty,
              !NoticeThread.continuesHere(notice: n, recent: recent, lastActivity: last) else { return }
        let from = currentConversationID
        let fromTitle = conversationStore.load(id: from)?.title ?? "your last conversation"
        newConversation()
        noticeReturn = NoticeReturn(from: from, fromTitle: fromTitle, to: currentConversationID)
    }

    /// "↩ Back to …": the conversation the reply left.
    func returnFromNotice() {
        guard let r = noticeReturn else { return }
        noticeReturn = nil
        openConversation(id: r.from)
    }

    /// Whether the island should offer the way back: only from the
    /// conversation the reply started.
    var showsNoticeReturn: Bool {
        guard let r = noticeReturn else { return false }
        return r.to == currentConversationID
    }

    /// "Open it" on a finished helper's heads-up: that conversation on
    /// screen, where its result is answered (`deliverFinishedHelper`).
    func openNoticeThread(_ id: String) {
        guard let n = notice(id), !n.openThread.isEmpty else { return }
        update(id) { $0.status = .done; $0.doneAt = Date(); $0.outcome = "Opened"; $0.seen = true }
        showingInbox = false
        openConversation(id: n.openThread)
        drainInbox()
    }

    /// Load an item as the one being acted on, and its offer as the card
    /// always loaded it (off the main thread). The offer tests drive the
    /// offer's own actions through this.
    func focusNotice(_ id: String) {
        guard let n = notice(id) else { return }
        activate(n)
        refreshOffer()
    }

    // MARK: Offers and away reminders, through their own actions

    /// Use draft / See it / Not now on an offer, and Show me / Not now /
    /// Don't remind me on an away reminder: loaded as the current card, then
    /// the action that always did it, so the send gate and the learner see
    /// exactly what they always saw.
    func useNoticeDraft(_ id: String, offer: SituationOffer) {
        guard let n = notice(id) else { return }
        activate(n, offer: offer)
        useOfferDraft()
        update(id) { $0.status = .done; $0.doneAt = Date(); $0.outcome = "Sent"; $0.seen = true }
    }

    func declineNotice(_ id: String, kind: Bool) {
        guard let n = notice(id) else { return }
        activate(n)
        declineOffer(kind: kind)
        update(id) { $0.status = .done; $0.doneAt = Date(); $0.outcome = kind ? "Not this kind" : "Not now"; $0.seen = true }
    }

    func awayNotice(_ id: String, _ action: String) {
        guard let n = notice(id) else { return }
        activate(n)
        switch action {
        case "show": openAwayCarry()
        case "never": awayCarryNever()
        default: awayCarryNotNow()
        }
        update(id) { $0.status = .done; $0.doneAt = Date(); $0.outcome = action == "show" ? "Opened" : "Not now"; $0.seen = true }
    }

    // MARK: The old card's fields, for the length of one action

    func handle(for n: InboxItem) -> NudgeHandle {
        var h = NudgeHandle(job: n.job, jobID: n.jobID, loops: n.loops, said: n.said,
                            note: n.instruction, offer: n.offer)
        h.awayCarry = n.awayCarry
        h.openThread = n.openThread
        h.expiresAt = n.expiresAt
        h.expiredText = n.expiredText
        return h
    }

    private func activate(_ n: InboxItem, offer: SituationOffer? = nil) {
        pendingNudge = n.body
        pendingNudgeWhen = nil
        pendingNudgeHandle = handle(for: n)
        if let offer, offer.id == n.offer {
            currentOffer = offer
            offerCard = .current
        } else {
            currentOffer = nil
            offerCard = n.offer.isEmpty ? .none : .gone
        }
    }
}
