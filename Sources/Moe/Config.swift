import CoreGraphics
import Foundation
import MoeMeeting
import MoeBrain
import MoeIsland

/// Everything Moe reads from ~/.moe/config.json
struct Config: Codable {
    /// Which AI is behind Moe. See PRODUCT.md §3 and `BrainKind`. Only
    /// `hermes` exists; which model Hermes talks to is set in
    /// ~/.hermes/config.yaml (configure-hermes.py writes it).
    var brain: BrainKind = .hermes
    /// Port the Hermes gateway's `api_server` platform listens on (127.0.0.1).
    var hermesPort: Int = 8642
    /// Bearer key for that server (`API_SERVER_KEY`). Empty means: read it
    /// from ~/.hermes/.env, and if it isn't there either, talk to Hermes
    /// without one — which Hermes only allows statelessly, so each turn
    /// forgets the last.
    var hermesKey: String = ""
    /// Path to the `hermes` executable Moe launches the gateway with. Empty
    /// means the usual places (~/.hermes/hermes-agent/.venv/bin/hermes,
    /// ~/.local/bin/hermes, PATH). `MOE_HERMES_BIN` in the environment wins.
    var hermesBinary: String = ""
    var voice: String = "Ava"
    var speechRate: Float = 0.52
    /// The language Moe hears and speaks. A fresh install starts in the
    /// Mac's own language when Moe can hear it (docs/DEFAULTS.md row 38),
    /// and in English otherwise; `SpeechLanguages.systemDefault` decides.
    var locale: String = SpeechLanguages.systemDefault

    // MARK: - How Moe answers
    //
    // `speakReplies` is the master: off, nothing is ever spoken. The two
    // switches under it say what happens when it is on, and they are separate
    // because "I said this out loud" and "I typed this" are separate
    // questions with different right answers. Until they existed, a question
    // typed quietly into the island was answered aloud across the room.

    /// Speech at all. The master switch; the two below are read only when
    /// this is on.
    var speakReplies: Bool = true

    /// Speak the answer to something you typed.
    ///
    /// Off by default: typed in, text out. Somebody at a keyboard has chosen
    /// the quiet way to ask, and the island's own field says "Ask Moe —
    /// quietly". On, a typed question is answered aloud as well as shown.
    var speakTypedReplies: Bool = false

    /// Speak the answer to something you said out loud. On: this is Moe.
    var speakSpokenReplies: Bool = true

    /// Write a typed answer to be read rather than heard.
    ///
    /// Moe's whole system prompt is addressed to a listener — "you are being
    /// spoken aloud", "one or two short spoken sentences", no markdown, no
    /// lists. That is right for a voice assistant and wrong for the answer to
    /// something you typed, which arrives in a panel with nobody listening to
    /// it: clipped to two sentences, unformatted, and with the addresses
    /// spelled out in prose because the prompt forbade URLs.
    ///
    /// On, a typed turn carries a marker (`BrainPrompt.typedTurnMarker`) that
    /// switches the model to the reading rules. The marker rides in the *user*
    /// message rather than the system prompt on purpose: Hermes bakes the
    /// system prompt into its Claude Code child at spawn and respawns the
    /// child whenever it changes — measured at 6.8 s — so a prompt that
    /// differed between typed and spoken turns would pay that on every switch
    /// between them.
    var typedRepliesReadAsText: Bool = true

    /// When the island opens itself to show an answer: "always", "silent"
    /// (only an answer Moe will not speak — the default), or "never".
    /// Parsed through `PanelReveal(configValue:)`.
    var panelOnReply: String = PanelReveal.silent.rawValue

    /// How much Moe says: "short", "balanced" (the default, and the rules
    /// Moe always had) or "detailed". Parsed through
    /// `ReplyLength(configValue:)`. Read by `Conductor.submit` for the notch
    /// and by configure-hermes.py for the chat channels.
    var replyLength: String = ReplyLength.short.rawValue   // docs/DEFAULTS.md row 5

    /// How long a self-opened panel stays before it folds. Zero means it
    /// waits to be dismissed, and zero is the default: a silent answer should
    /// not vanish on a timer (docs/DEFAULTS.md row 7). The 6/12/30 choices
    /// remain in Settings › Replies; `ReplyReveal.readingTime` is the middle
    /// one. See `ReplyReveal.readingTime(seconds:)`.
    var replyReadingSeconds: Double = 0

    /// "Yeah, on it", said before the gateway has been asked anything.
    ///
    /// It exists because the whole wait in front of a reply belongs to
    /// somebody else's network and an opener written by the model cannot
    /// arrive before the model does. Only ever on a turn Moe is going to
    /// speak — there is nobody listening to a typed one.
    /// **Off by default since 2026-09-06**, at the owner's request. He had
    /// asked three times for Moe to stop saying words nobody wrote, and this
    /// is the one he heard most — it is the first thing spoken on almost
    /// every turn. The research backs taking it out on its own terms too:
    /// measured, a filler does nothing for a gap under about 1.5 s, and a
    /// warm turn here reaches its first token in 2.7 s.
    ///
    /// Kept rather than deleted because the case for it is real and only
    /// testable by living with the silence: a cold turn was 9.7 s on this
    /// Mac, and nine seconds of nothing after you stop talking is
    /// indistinguishable from a crash. If that is how it feels, this is one
    /// switch in Settings › Replies rather than a rebuild.
    var instantAck: Bool = false

    /// Say what Moe is doing while a long job runs ("checking your calendar").
    /// Off, a spoken turn is silent between the acknowledgement and the
    /// answer; the island's status line still shows the step either way.
    var spokenProgress: Bool = true

    /// A small tone when an answer lands that Moe is not going to speak, so
    /// you know it arrived without watching for it. Uses the dictation
    /// chime's engine and its own note.
    var replyChime: Bool = true

    /// A question typed into the island shows its answer on the Chat page.
    ///
    /// Off by default (docs/DEFAULTS.md row 14): the answer stays in the
    /// panel under the notch, on whichever page you were reading. On, which
    /// is what the island used to do, the chat page opens for it.
    var typedAnswersOpenChat: Bool = false

    /// Hovering the notch opens its peek, or, while the chat is popped out,
    /// brings that window forward. Off, a hover does nothing and only a
    /// click opens it (the owner asked for the switch, 2026-11-14).
    var notchHoverOpens: Bool = true

    /// Which speech engine speaks Moe's replies.
    /// "kokoro" (ANE, one voice), "pocket" (many voices + cloning),
    /// "supertonic" (fastest, 31 languages), "apple" (system voices, no
    /// download). The default is whichever engine's model actually ships in
    /// the app — see `TtsEngineKind.shipped`, which is the only place that
    /// decides it.
    var ttsEngine: String = TtsEngineKind.shipped.rawValue
    /// Voice within that engine. Empty means the engine's default.
    var ttsVoice: String = ""
    var hotKeyCode: UInt32 = 49          // space
    /// Carbon modifier mask. Default ⌃⌥Space (controlKey 4096 + optionKey 2048).
    ///
    /// Not plain ⌥Space: dictation tools like Wispr Flow and superwhisper
    /// commonly bind that, and when they win the race you get their behaviour
    /// — including a clipboard paste — instead of Moe.
    var hotKeyModifiers: UInt32 = 6144
    /// Start Moe when the Mac signs in. On by default (docs/DEFAULTS.md
    /// row 30) — a menu-bar assistant should be there when the Mac is. Read
    /// by `LoginItem`, which registers the app with macOS once and after
    /// that leaves System Settings › Login Items as the person's own switch.
    var launchAtLogin: Bool = true
    /// Settings › Privacy › "Report without saying who I am" (docs/DEFAULTS.md
    /// row 28 d). Off by default: a report names its account and device,
    /// because that is how the reply and the fix reach the person. On, it
    /// carries neither, and the edge files it where no account can be found.
    /// Not a Hermes setting — `moe-ticket.py` reads this key straight out of
    /// config.json on every report, so the name is load-bearing.
    var problemReportsAnonymous: Bool = false

    /// Put the microphone into voice-processing mode for echo cancellation.
    ///
    /// On by default, and measured to be so (docs/DEFAULTS.md row 17; an
    /// older version of this comment said "off", and the value never was).
    /// It exists so Moe does not hear its own voice when the microphone is
    /// open while it speaks — barge-in, the wake word, and the mic-open-until-
    /// first-audio turn-taking all need it. The cost is real: voice processing
    /// switches the audio device into duplex VPIO mode, which applies automatic
    /// gain control and ducks everything else the Mac plays; see
    /// `AudioGate` for why it is held off while a call app has the mic.
    var echoCancellation: Bool = true

    /// The key you hold to talk (docs/DEFAULTS.md row 8). Right ⌥ to start
    /// with — the key beside the space bar that almost nothing else uses —
    /// and Settings › Voice offers right ⌘, right ⌃ and fn instead.
    var talkKey: TalkKey = .rightOption

    /// Always-on listening: no hotkey, just say the wake phrase.
    var wakeWordEnabled: Bool = false
    var wakePhrases: [String] = ["hey moe", "hey mo", "heymo", "hey mow"]
    /// After a reply, keep listening for a while: you can just talk, no
    /// name and no key. VOICE-PLAN.md §2.1.
    ///
    /// On for a **new install** (docs/DEFAULTS.md row 9, the owner,
    /// 2026-09-25: "keeping Moe listening after it answers is better").
    /// Every config.json written before then saved `false` — the old
    /// default was written out with everything else — so an existing
    /// person keeps what they had. A file that somehow lacks the key is
    /// read as the old default, `conversationModeBeforeDefaultOn`, never
    /// this one: an existing install must not change behaviour under them.
    var conversationMode: Bool = true
    static let conversationModeBeforeDefaultOn = false
    /// The same after a turn held on the key.
    var holdOpensConversation: Bool = false
    /// How long that window stays open after Moe *stops speaking* — the
    /// last buffer heard, not the last character received.
    var followUpSeconds: Double = 8
    /// How long Moe waits for you to start after it wakes.
    var attendSeconds: Double = 8
    /// How Moe offers to close a conversation that has gone quiet, rather
    /// than letting the window time out with the light still on:
    /// "off" (time out silently), "shown" (a line on the island),
    /// "spoken" (Moe asks), "both".
    var closeOffer: String = "shown"
    /// Seconds of quiet in the window before that offer. Zero, or anything
    /// past `followUpSeconds`, never offers.
    var closeOfferAfter: Double = 4
    /// Your voice interrupts Moe mid-sentence. Needs echo cancellation.
    var bargeIn: Bool = false
    /// Keep short audio clips of the moments the voice loop got wrong or
    /// nearly wrong — a sound it refused as an interruption, a capture with
    /// no words, a turn ended by the stall clock or a ceiling — under
    /// `voice/debug/` in Moe's home, capped at 200 MB, oldest first out.
    /// For building a noise dataset. Off unless turned on by hand; nothing
    /// in it ever leaves the Mac.
    var voiceDebugAudio: Bool = false
    /// "Hey Moe" is confirmed by the local recogniser before Moe wakes:
    /// the head listens at `wakeConfirmThreshold` rather than its own
    /// (stricter) line, and a hit wakes Moe only when the recogniser hears
    /// the name in the two seconds it fired on (`WakeConfirm`). Only where
    /// the local recogniser reads the language; elsewhere the head's own
    /// threshold stands.
    ///
    /// Off: measured 2026-09-23 it halves the head's false fires on the
    /// Inworld set (117 → 1 at 0.7) but costs the owner's own recordings
    /// recall (41/65 → 32/65) — the recogniser writes his "Hey Moe" as
    /// "Hey Moon", "Hello", "Hey no". voice-turns-impl.md, Slice G.
    var wakeConfirm: Bool = false
    /// The head's threshold while every hit is confirmed. Lower hears more
    /// of the owner and lets more lookalikes through to the recogniser.
    var wakeConfirmThreshold: Double = 0.7
    /// Plan the wait after the turn model answers from its evidence — the
    /// score, the words, the pause so far (`EndpointPolicy.fitted`): start
    /// the brain early and hold the reply. Off is the three fixed waits and
    /// the 0.8 s floor that shipped before 2026-09-23.
    var turnEvidence: Bool = true
    /// Ask Apple's on-device model, at a pause, whether the words so far are
    /// finished (`TurnSemanticJudge`) — only where the word rules have no
    /// opinion, and never waited for past 300 ms. Off: on the Mac it was
    /// built on the model was still downloading, so its latency and its
    /// effect on the turn bench are unmeasured (turn-semantics.md). The word
    /// rules run either way.
    var turnSemanticModel: Bool = false
    /// Learn how long *you* pause mid-turn (the holds and continuations on
    /// your own turn traces, `OwnerPauses`) and never release a reply sooner
    /// than that. Off, and with it on nothing changes until 50 of your
    /// pauses have been logged.
    var turnOwnerPauses: Bool = false
    /// Let the owner-voice gate drop a turn in a voice that is clearly not
    /// yours. Off: until then it only writes down its score and what it
    /// would have done (the turn trace, the log, the debug clips), because
    /// its line has not been measured on your own voice yet.
    var ownerGateEnforce: Bool = false
    /// Read the turn back the moment you stop, not the moment Moe decides
    /// you have finished. The accurate model starts on the VAD's edge; if
    /// nothing but quiet follows before the turn is taken, that read stands
    /// and the read's whole cost — 150 ms p50, 392 ms p90 on the owner's
    /// turns, measured 2026-09-06 — leaves the gap between your last word
    /// and the brain. Say anything more and the whole turn is read again, as
    /// before. Local engine only (`ProgressiveRead`).
    var earlyRead: Bool = true

    /// Hold-to-dictate: speech typed at the cursor, never sent to the brain.
    /// A separate key from the agent hold on purpose — "type what I said" and
    /// "do what I said" must never be guessed between (PRODUCT.md §4.1).
    ///
    /// Starts as `Features.dictation` — off while the feature is hidden
    /// (docs/DEFAULTS.md row 4). The default is not the gate: an old
    /// config.json can still say true, so `Conductor.effectiveDictationKey`
    /// is where a hidden feature is actually refused.
    var dictationEnabled: Bool = Features.dictation
    var dictationKey: DictationKey = .rightCommand

    /// After the rule cleaner, send the transcript through the connected
    /// brain for a rewrite (punctuation, false starts, register for the app
    /// in front). Off means the text never leaves the Mac for any reason.
    var dictationPolish: Bool = true
    /// How long that rewrite may take before the rule-cleaned text is pasted
    /// instead. Dictation is never slower than today by more than this.
    var dictationPolishBudget: Double = 4.0   // warm Hermes turns measure 1.6–2.4 s
    /// Hermes session the polish turns go to. Its own, stable UUID: it must
    /// never share a transcript with the conversation, and a session that
    /// stays the same stays warm (Hermes keeps one claude child per session).
    /// Empty until the first polish mints one.
    var dictationSessionID: String = ""

    /// Show the polish pass the text already in the field ahead of the
    /// cursor, so a dictation continues what you were writing instead of
    /// starting fresh — capitalisation, an existing full stop, a name spelled
    /// earlier in the same message. At most `CursorContext.limit` characters,
    /// never from a password field, never logged.
    ///
    /// On by default, but only ever consulted when `dictationPolish` is on:
    /// it goes to the same brain, in the same request, as the transcript
    /// itself. Off means the field's contents never leave the Mac.
    var dictationCursorContext: Bool = true

    /// Read the names, identifiers and jargon visible in the window you are
    /// dictating into, and use them to spell that one utterance. The words
    /// are gathered when the key goes down, ride along with the transcript,
    /// and are thrown away when it is pasted — nothing is stored, and no
    /// standing rule is ever created from them. See `ScreenText` and
    /// `ContextTerms`.
    ///
    /// On by default. It needs no permission Moe does not already hold, and
    /// unlike `dictationCursorContext` it never sends a sentence — only a
    /// short list of words that were already on your screen. Off means the
    /// window is not read at all.
    var dictationScreenVocabulary: Bool = true

    /// Let the model deliberate before rewriting a dictation.
    ///
    /// Off by default, because a dictation rewrite is mechanical and thinking
    /// about it is a third of the wait for nothing. Measured on the Claude
    /// Code child, twice: 3178/3523 ms with, 2262/2243 ms without, identical
    /// output — and the swing (2.2-4.7 s) disappears. On by default would be
    /// paying for deliberation nobody asked for.
    var dictationPolishThinking: Bool = false

    /// A spoken turn opens at the lowest reasoning effort the brain has.
    ///
    /// Somebody who has just stopped talking hears nothing until the first
    /// words are written, and over 519 measured turns the model thought
    /// before them on 56% — +0.8 to +3.0 s each, more the longer the
    /// conversation (docs/SPEED-FINDINGS-2026-11-12.md §3). Moe only says
    /// that the turn was spoken (`X-Hermes-Voice-Turn`); which level is
    /// "lowest" is the brain's own answer per provider — off where the
    /// provider allows off, its weakest level where it does not, and on the
    /// plan route the opening of the turn only, with the person's own effort
    /// back for whatever work follows a tool call. Typed turns are never
    /// marked. Off here sends no mark and every turn thinks as it always did.
    var spokenTurnsOpenQuick: Bool = true

    /// Which tier rewrites a dictation, when more than one is available.
    ///
    /// Empty means "whatever is fastest that works" — the ladder in
    /// `PolishTier`, which prefers on-device. A value here moves that tier to
    /// the front without removing the rest, so a machine that loses its
    /// preferred tier still gets a rewrite. `rulesOnly` is the exception: it
    /// means no model ever, and is honoured absolutely.
    var dictationPolishTier: String = ""

    /// Send the dictation rewrite to a different provider than the
    /// conversation uses. Empty means the same one.
    ///
    /// The conversation wants an agent runtime; a dictation polish is a
    /// mechanical rewrite on a hard time budget, and that runtime is pure
    /// overhead on it. Measured here: `haiku` through `claude-code-cli`
    /// (Hermes spawning a `claude` child) costs 2.1-2.5 s, against 125 ms for
    /// the speech engines ahead of it, and sometimes overruns
    /// `dictationPolishBudget` entirely — which silently drops the rewrite.
    /// Naming a plain API provider here routes the same model without the
    /// child process.
    ///
    /// Whichever provider is named must have a key Hermes can find, and it
    /// will see your dictation text. Empty by default: changing which vendor
    /// reads what you dictate is a decision, not a default.
    var dictationPolishProvider: String = ""

    /// Feed the names in Contacts into the dictation vocabulary. Off by
    /// default: reading Contacts is a permission prompt, and Moe never
    /// prompts for what nobody asked for. See `ContactsVocabulary`.
    var dictationContactsNames: Bool = false
    /// After a paste, notice a word the user typed over and, once it has
    /// happened twice, add the spelling to vocabulary-learned.txt. Needs
    /// nothing beyond the Accessibility grant the paste already has. See
    /// `CorrectionWatcher`.
    var dictationLearnCorrections: Bool = true
    /// A small chime as dictation starts and stops (and a tick when it is
    /// cancelled), so you know the microphone opened without looking up.
    var dictationSounds: Bool = true
    /// Keep each dictation in ~/.moe/dictation-history.jsonl, owner-readable
    /// only, so a sentence pasted into the wrong place is not lost.
    var dictationHistory: Bool = true

    /// Let Moe get your attention: the notch glows amber when the background
    /// pass finds something time-sensitive (a meeting about to start, a
    /// missed call, a message from someone in memory/people.md).
    ///
    /// On by default, and switchable in Settings › Background. Two places
    /// read it, on purpose: `moe-home/nudge.sh` exits before deciding
    /// anything, so nothing is looked at while this is off, and
    /// `Conductor.watchForNudges` stops polling, so a nudge.json left over
    /// from before the switch was flipped never surfaces. Moe never speaks a
    /// nudge unprompted — the glow waits to be tapped (`playNudge`).
    var nudges: Bool = true

    /// Settings › Background › "Background thinking": whether Moe may spend
    /// the person's own model on work nobody asked for right now — the
    /// proactive pass and the daily learning pass. Off, the free checks
    /// (`moe-loop-check`, the calendar heads-up) and any reminder the person
    /// asked for keep running, and open loops keep accruing; they are just
    /// not spoken. Read by `moe-brief-monitor.sh` (prints `paused`) and
    /// `moe-learn-deep.sh`. docs/LOOPS.md §3.
    var backgroundThinking: Bool = true

    /// Settings › Background › Noticed: whether the situations engine OFFERS
    /// the work it prepared (docs/PROACTIVE-MEMORY.md §4.8) — the island's
    /// card, Use draft / See it / Not now. Off (the default), it still
    /// notices and prepares, and shows it only in the Noticed tab. Read by
    /// hermes-jobs/moe-situations.py (`offers_on`), on a Mac only.
    var situationOffers: Bool = false
    /// …and whether an offer also goes to the chats ticked for reminders
    /// when the person is away from the Mac. Off by default: the reminder
    /// channels alone are not consent to drafts and amounts from other
    /// conversations arriving there (the offer-path review, 2026-09-25).
    var situationOffersToChats: Bool = false

    /// Settings › Away › Cloud browser: the sites the cloud computer's own
    /// browser may stay signed in to while the Mac is off (docs/AWAY-BROWSER.md).
    /// Opt-in per site: empty by default, so a sign-in made there lasts for
    /// one job until the person adds its site. Always written, so the machine
    /// can tell this Mac's choice (a list, enforced exactly) from an older
    /// Mac's silence (no key: it prunes nothing). It travels sealed, as part
    /// of `settings/background`; the edge never reads it.
    var cloudBrowserSites: [String] = []

    /// Quiet hours, 22:00–08:00 in the person's own zone: what Moe raises
    /// on its own waits for the morning before it reaches their phone (the
    /// island still gets it, silently). Applied only while the zone is
    /// known fresh from this Mac (`Paths.timeZone`, under a day old);
    /// otherwise there are no quiet hours, because a guess about where
    /// somebody is in the world is how a nudge lands at 3 a.m. Read by
    /// `moe-screen/deliver.py`. docs/LOOPS.md §5.
    var quietHours: Bool = true

    /// Where a reminder goes besides this screen: the bare names of Hermes
    /// chat platforms ("telegram", "whatsapp", …) the person ticked in
    /// Settings › Background. The screen is always on and is not listed. A
    /// Hermes cron job addressed to `moe` — every reminder Moe makes — is
    /// spoken and shown here and forwarded to each of these through Hermes's
    /// own `hermes send`, which only ever reaches the home channel the person
    /// set up (their own phone). Read at delivery time by the moe-screen
    /// plugin, so a change here takes effect on the next reminder without
    /// touching any job.
    var reminderChannels: [String] = []

    /// Whether a chat has ever been picked for reminders — by Moe, which
    /// ticks the first chat app that becomes ready (docs/DEFAULTS.md row
    /// 26, `ReminderChannels.adopt`), or by the person ticking or unticking
    /// one (`Conductor.setReminderChannel`). Once true Moe never ticks a
    /// chat by itself again, so one the person unticked stays unticked and
    /// a second chat app is always their choice.
    ///
    /// A config.json written before this existed decodes as true: that
    /// person has already had the list in front of them, and what they left
    /// unticked is their answer, not a gap for Moe to fill.
    var reminderChannelsAutoPicked: Bool = false

    /// How many minutes before something in the calendar Moe says so, or 0
    /// for not at all. Read by `hermes-jobs/moe-calendar-heads-up.py`, which
    /// runs every two minutes off the copy of the calendar the sync already
    /// keeps — no model, no cost, and exact, which the half-hourly proactive
    /// pass cannot be. Off until asked for: nothing new should start
    /// speaking to someone who did not ask it to.
    ///
    /// While this is set, `nudge.sh`'s older fixed twenty-minute rule stands
    /// down, so one meeting is one heads-up.
    /// Ten minutes to start with (docs/DEFAULTS.md row 21); 0 is "Don't".
    var calendarHeadsUpMinutes: Int = 10

    /// Moe sees your screen when you talk to it: a screenshot of the display
    /// under the cursor, taken as the agent key goes down, rides with the
    /// words to the AI provider. Never for dictation. See ScreenContext.
    var screenContext: Bool = true
    /// When Moe points at something (`[POINT:x,y:label]` in a reply), also
    /// move the real mouse pointer there. Off: the ring alone.
    var screenPointerMovesMouse: Bool = false

    /// Whether Moe may take the screen over when it cannot do a thing quietly.
    ///
    /// Driving the Mac is background-first: input is posted straight into the
    /// target window, so the pointer does not move, focus does not change, and
    /// the person can keep typing somewhere else. That is the normal path and
    /// it is not affected by this setting.
    ///
    /// Some things cannot be done that way. macOS refuses background input to
    /// a window on another Space or a minimized one, and a menu item only
    /// fires for the app that is actually frontmost. Today Moe escalates
    /// automatically — it fronts the window, which on a full-screen app means
    /// pulling the person's desktop somewhere else mid-sentence.
    ///
    /// On (the default) keeps that, because turning it off silently would
    /// make working features stop working. Off means Moe stays out of the way
    /// and says what it could not do, instead of taking the screen to do it.
    var computerUseMayTakeOver: Bool = true

    // MARK: Meetings (PRODUCT.md §4.2, MEETING-MODE.md)

    /// Show the consent sheet before every meeting. Off means "Start
    /// meeting" starts at once — the indicator still shows, always.
    var meetingAskBeforeStart: Bool = true
    /// At the end, send the transcript to the connected AI once for the
    /// notes. Off: transcript only, nothing leaves the Mac.
    var meetingSummarise: Bool = true
    /// ⌃⌥M starts and stops a meeting. Off by default: a global shortcut
    /// that records other people should be something you switched on.
    var meetingHotkey: Bool = false
    /// Delete system.wav and mic.wav once summary.md is written; keep the
    /// transcript and notes. On by default: the audio has done its job,
    /// and a folder of recordings of other people is a liability.
    var meetingDeleteRecordings: Bool = true
    /// Send the finished notes to the user's own Telegram when a meeting
    /// ends. **Off by default.** This was not a setting: the notes went out
    /// whenever Hermes happened to have a `TELEGRAM_ALLOWED_USERS` entry,
    /// which is a configuration detail, not consent. Sending a meeting's
    /// notes off the Mac is a decision, and it is made here.
    var meetingSendTelegram: Bool = false
    /// The "Hold ⌥ and whisper, or click to type" hint has been shown once.
    var meetingHintShown: Bool = false
    /// Notice a call (Zoom, Meet, Teams… holding the microphone) and offer
    /// to record it — or, on `auto`, start after a short countdown. Asks by
    /// default: the offer is one click and never records on its own.
    var meetingAutoDetect: DetectMode = .ask
    /// When the call ends, stop the recording, save it and write the notes,
    /// without asking.
    ///
    /// On by default, and deliberately not the same decision as
    /// `meetingAutoDetect`. Starting a recording is a consent question and
    /// belongs to the person; *stopping* one they already said yes to is
    /// not a question at all — the call is over, there is nothing left to
    /// record, and everything after it is silence in the file behind a
    /// prompt waiting to be dismissed. The two were bundled together, so
    /// anyone who wanted to be asked before recording started was also
    /// asked before it stopped.
    var meetingAutoStopOnCallEnd: Bool = true
    /// The "let Moe read who was invited" offer has been put once, after a
    /// meeting whose voices it could have named. Once is the whole point:
    /// a permission asked twice is nagging, and "no" is an answer.
    var meetingCalendarOfferShown: Bool = false
    /// Bundle ids the user said "never" for ("Never for Slack").
    var meetingDetectIgnored: [String] = []
    /// Screenshots and clips during a meeting: Settings › Meeting Capture.
    var meetingCapture: CapturePolicy = CapturePolicy()
    /// ⌃⌥S takes a screenshot and ⌃⌥R starts/stops a clip — only while a
    /// meeting is being recorded, so the shortcuts never exist otherwise.
    var meetingCaptureHotkeys: Bool = true

    // MARK: Away (docs/CLOUD-PLAN.md, docs/LEDGER-WIRE.md §11)

    /// The edge this Mac talks to — sign-in, the plan, the Composio key,
    /// and the ledger sync once there is a credential. Moe's own edge unless
    /// a developer points it elsewhere (the Developer group of Settings ›
    /// Away, `.dev` builds only). It used to default to empty and mean "no
    /// cloud at all", which on a downloaded Moe meant: Google consented,
    /// Moe threw the token away with "set the edge address first", and the
    /// person had no field to set it in — 2026-09-07, four times in a row.
    /// An empty value in the file reads back as the default for the same
    /// reason. Only the address lives here; the credential is a 0600 file
    /// under Moe's home (`CloudSync`).
    var cloudEdge: String = Config.defaultCloudEdge
    ///
    /// The address is a build setting, not a constant in the source: build.sh
    /// stamps it into Info.plist as `MoeCloudEdge` from `cloud/release.env`
    /// (the official build) or leaves it empty (a community build of the open
    /// source, which has no cloud). Empty means off — Away, Google sign-in and
    /// the cloud voice hide themselves — and a config.json that names an edge
    /// still wins, which is how a developer points a build at their own.
    static let defaultCloudEdge: String =
        (Bundle.main.object(forInfoDictionaryKey: "MoeCloudEdge") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    /// Whether this build has a cloud at all: the official build always
    /// does; a community build only when someone typed an edge in config.json.
    var hasCloud: Bool { !cloudEdge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Hear and speak through the cloud when the plan includes it.
    ///
    /// On the paid tiers Moe's ears are AssemblyAI and its voice is Inworld,
    /// on credentials the edge mints per socket and meters per month; at the
    /// cap or on any error the voices on this Mac carry on. On the free tier
    /// this switch changes nothing and nothing is sent — the tier decides,
    /// not the switch (`CloudVoice.mayUse`). On by default because it is
    /// what a paying person paid for; off is for someone who would rather
    /// their audio never left the Mac even so.
    var cloudVoice: Bool = true

    /// Developer only, config.json by hand: mint the vendor tokens on this
    /// Mac from keys in the login keychain (`DeveloperVoiceCredentials`)
    /// instead of asking the edge. Stands in for a paid tier and meters
    /// nothing. For testing the two backends before the edge route exists.
    var cloudVoiceDeveloperKeys: Bool = false

    /// The plan whose welcome card has been put away, or "" for none.
    ///
    /// The tier and not a `Bool`, so an upgrade from Away to Away+ is
    /// welcomed too: what the plan gives you changed, and the three things
    /// worth doing about it changed with it. Nothing is shown for `free`,
    /// which is why a fresh install's "" is safe.
    var awayWelcomeSeen: String = ""

    /// ~/.moe, or (debug builds only) `MOE_HOME`, so a test suite gets a
    /// config, log and vocabulary of its own — the same override
    /// `Vocabulary` honours.
    static let homeDir: URL = {
        if let env = TestHooks.env("MOE_HOME") { return URL(fileURLWithPath: env, isDirectory: true) }
        // A development build keeps its own everything. `build.sh dev`
        // stamps MoeHome into the bundle, and honouring it here is what
        // makes the separation real rather than cosmetic: notes, memory,
        // consent answers and connector tokens all hang off this one path,
        // so a build someone is working on cannot write the Moe in daily
        // use — however it was started, installed or not.
        if let dev = Bundle.main.object(forInfoDictionaryKey: "MoeHome") as? String,
           !dev.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (dev as NSString).expandingTildeInPath, isDirectory: true)
        }
        // ~/Library/Application Support/Moe, not ~/.moe.
        //
        // This is where macOS puts an application's data, which matters for
        // more than tidiness: it is where a person looks when they want to
        // find, back up or delete what an app has kept about them, and a
        // dotfile at the top of the home directory is not somewhere anyone
        // thinks to look. Moe keeps memories, meeting transcripts and a
        // ledger; those should not be hidden by convention.
        //
        // `Paths.migrateLegacyHome()` moves an existing ~/.moe here on first
        // launch. Note the space in "Application Support": every shell script
        // that builds a path from this must quote it.
        return legacyHomeMigrationTarget
    }()

    /// The new location, computed without touching the filesystem so that both
    /// the migration and every reader agree on it.
    static let legacyHomeMigrationTarget: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Moe", isDirectory: true)

    /// Where Moe kept its home before 0.3.5.
    static let legacyHome: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moe", isDirectory: true)
    static let configURL: URL = homeDir.appendingPathComponent("config.json")

    init() {}

    /// Hand-written so a partial config still works.
    ///
    /// Swift's synthesized `Decodable` ignores property defaults — a single
    /// missing key throws, and with a `try?` around it the user's *entire*
    /// config silently reverts to defaults. Since the menu invites people to
    /// edit this file by hand, and since adding a field in a later build would
    /// otherwise reset everyone, decode each key independently.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        // Decoded as a string so a legacy name ("claudeCode", "geminiCli" —
        // brains that moved into Hermes) or a typo falls back to the default
        // instead of throwing — but never quietly, so a config.json written
        // for an older build is seen to have been reinterpreted.
        let rawBrain     = try c.decodeIfPresent(String.self,   forKey: .brain)
        brain            = rawBrain.flatMap(BrainKind.init(rawValue:))                 ?? d.brain
        if let raw = rawBrain, BrainKind(rawValue: raw) == nil {
            Log.write("config.json: brain \"\(raw)\" is no longer a Moe brain (providers live in "
                      + "~/.hermes/config.yaml now); using \(d.brain.rawValue)")
        }
        hermesPort       = try c.decodeIfPresent(Int.self,      forKey: .hermesPort)       ?? d.hermesPort
        hermesKey        = try c.decodeIfPresent(String.self,   forKey: .hermesKey)        ?? d.hermesKey
        hermesBinary     = try c.decodeIfPresent(String.self,   forKey: .hermesBinary)     ?? d.hermesBinary
        voice            = try c.decodeIfPresent(String.self,   forKey: .voice)            ?? d.voice
        speechRate       = try c.decodeIfPresent(Float.self,    forKey: .speechRate)       ?? d.speechRate
        locale           = try c.decodeIfPresent(String.self,   forKey: .locale)           ?? d.locale
        speakReplies     = try c.decodeIfPresent(Bool.self,     forKey: .speakReplies)     ?? d.speakReplies
        speakTypedReplies = try c.decodeIfPresent(Bool.self, forKey: .speakTypedReplies) ?? d.speakTypedReplies
        speakSpokenReplies = try c.decodeIfPresent(Bool.self, forKey: .speakSpokenReplies) ?? d.speakSpokenReplies
        typedRepliesReadAsText = try c.decodeIfPresent(Bool.self, forKey: .typedRepliesReadAsText) ?? d.typedRepliesReadAsText
        panelOnReply     = try c.decodeIfPresent(String.self,   forKey: .panelOnReply)     ?? d.panelOnReply
        // Normalised rather than merely defaulted, so what the pane shows and
        // what the island does can never disagree over a typo.
        panelOnReply     = PanelReveal(configValue: panelOnReply).rawValue
        replyLength      = ReplyLength(configValue: try c.decodeIfPresent(String.self, forKey: .replyLength) ?? d.replyLength).rawValue
        replyReadingSeconds = try c.decodeIfPresent(Double.self, forKey: .replyReadingSeconds) ?? d.replyReadingSeconds
        // Zero is "until I dismiss it" and is kept. A negative number, a NaN
        // or a week is not a choice anybody made.
        if !replyReadingSeconds.isFinite || replyReadingSeconds < 0 || replyReadingSeconds > 3600 {
            replyReadingSeconds = d.replyReadingSeconds
        }
        // A fraction of a second is not a reading time anybody chose, and
        // `ReplyReveal.readingTime(seconds:)` reads it as "until I dismiss
        // it" — which is the opposite of what a small number looks like it
        // asks for. Say what it means instead.
        if replyReadingSeconds > 0, replyReadingSeconds < 1 { replyReadingSeconds = 0 }
        instantAck       = try c.decodeIfPresent(Bool.self,     forKey: .instantAck)       ?? d.instantAck
        spokenProgress   = try c.decodeIfPresent(Bool.self,     forKey: .spokenProgress)   ?? d.spokenProgress
        replyChime       = try c.decodeIfPresent(Bool.self,     forKey: .replyChime)       ?? d.replyChime
        typedAnswersOpenChat = try c.decodeIfPresent(Bool.self, forKey: .typedAnswersOpenChat) ?? d.typedAnswersOpenChat
        notchHoverOpens = try c.decodeIfPresent(Bool.self, forKey: .notchHoverOpens) ?? d.notchHoverOpens
        ttsEngine        = try c.decodeIfPresent(String.self,   forKey: .ttsEngine)        ?? d.ttsEngine
        ttsVoice         = try c.decodeIfPresent(String.self,   forKey: .ttsVoice)         ?? d.ttsVoice
        hotKeyCode       = try c.decodeIfPresent(UInt32.self,   forKey: .hotKeyCode)       ?? d.hotKeyCode
        hotKeyModifiers  = try c.decodeIfPresent(UInt32.self,   forKey: .hotKeyModifiers)  ?? d.hotKeyModifiers
        launchAtLogin    = try c.decodeIfPresent(Bool.self,     forKey: .launchAtLogin)    ?? d.launchAtLogin
        problemReportsAnonymous = try c.decodeIfPresent(Bool.self, forKey: .problemReportsAnonymous)
            ?? d.problemReportsAnonymous
        // A string, like `dictationKey`: an unknown key name falls back to
        // right ⌥ rather than taking the whole config down with it.
        let rawTalkKey   = try c.decodeIfPresent(String.self,   forKey: .talkKey)
        talkKey          = rawTalkKey.flatMap(TalkKey.init(rawValue:))                  ?? d.talkKey
        echoCancellation = try c.decodeIfPresent(Bool.self,     forKey: .echoCancellation) ?? d.echoCancellation
        wakeWordEnabled  = try c.decodeIfPresent(Bool.self,     forKey: .wakeWordEnabled)  ?? d.wakeWordEnabled
        wakePhrases      = try c.decodeIfPresent([String].self, forKey: .wakePhrases)      ?? d.wakePhrases
        if wakePhrases.isEmpty { wakePhrases = d.wakePhrases }
        conversationMode = try c.decodeIfPresent(Bool.self, forKey: .conversationMode)
            ?? Config.conversationModeBeforeDefaultOn
        holdOpensConversation = try c.decodeIfPresent(Bool.self, forKey: .holdOpensConversation) ?? d.holdOpensConversation
        followUpSeconds  = try c.decodeIfPresent(Double.self,   forKey: .followUpSeconds)  ?? d.followUpSeconds
        if !(2...120).contains(followUpSeconds) { followUpSeconds = d.followUpSeconds }
        attendSeconds    = try c.decodeIfPresent(Double.self,   forKey: .attendSeconds)    ?? d.attendSeconds
        if !(2...60).contains(attendSeconds) { attendSeconds = d.attendSeconds }
        bargeIn          = try c.decodeIfPresent(Bool.self,     forKey: .bargeIn)          ?? d.bargeIn
        voiceDebugAudio  = try c.decodeIfPresent(Bool.self,     forKey: .voiceDebugAudio)  ?? d.voiceDebugAudio
        wakeConfirm      = try c.decodeIfPresent(Bool.self,     forKey: .wakeConfirm)      ?? d.wakeConfirm
        turnEvidence     = try c.decodeIfPresent(Bool.self,     forKey: .turnEvidence)     ?? d.turnEvidence
        turnSemanticModel = try c.decodeIfPresent(Bool.self,    forKey: .turnSemanticModel) ?? d.turnSemanticModel
        turnOwnerPauses  = try c.decodeIfPresent(Bool.self,     forKey: .turnOwnerPauses)  ?? d.turnOwnerPauses
        ownerGateEnforce = try c.decodeIfPresent(Bool.self,     forKey: .ownerGateEnforce) ?? d.ownerGateEnforce
        wakeConfirmThreshold = try c.decodeIfPresent(Double.self, forKey: .wakeConfirmThreshold) ?? d.wakeConfirmThreshold
        if !(0.05...0.99).contains(wakeConfirmThreshold) { wakeConfirmThreshold = d.wakeConfirmThreshold }
        earlyRead        = try c.decodeIfPresent(Bool.self,     forKey: .earlyRead)        ?? d.earlyRead
        closeOffer       = try c.decodeIfPresent(String.self,   forKey: .closeOffer)       ?? d.closeOffer
        if !["off", "shown", "spoken", "both"].contains(closeOffer) { closeOffer = d.closeOffer }
        closeOfferAfter  = try c.decodeIfPresent(Double.self,   forKey: .closeOfferAfter)  ?? d.closeOfferAfter
        closeOfferAfter  = min(max(closeOfferAfter, 0), 60)
        dictationEnabled = try c.decodeIfPresent(Bool.self,     forKey: .dictationEnabled) ?? d.dictationEnabled
        // A string, like `brain`: an unknown key name falls back rather than
        // taking the whole config down with it.
        let rawKey       = try c.decodeIfPresent(String.self,   forKey: .dictationKey)
        dictationKey     = rawKey.flatMap(DictationKey.init(rawValue:))                 ?? d.dictationKey
        dictationPolish  = try c.decodeIfPresent(Bool.self,     forKey: .dictationPolish)  ?? d.dictationPolish
        dictationPolishBudget = try c.decodeIfPresent(Double.self, forKey: .dictationPolishBudget) ?? d.dictationPolishBudget
        // A zero or absurd budget would make the pass pointless or unbounded.
        if !(0.5...15).contains(dictationPolishBudget) { dictationPolishBudget = d.dictationPolishBudget }
        dictationSessionID = try c.decodeIfPresent(String.self, forKey: .dictationSessionID) ?? d.dictationSessionID
        dictationPolishProvider = try c.decodeIfPresent(String.self, forKey: .dictationPolishProvider) ?? d.dictationPolishProvider
        dictationPolishTier = try c.decodeIfPresent(String.self, forKey: .dictationPolishTier) ?? d.dictationPolishTier
        dictationPolishThinking = try c.decodeIfPresent(Bool.self, forKey: .dictationPolishThinking) ?? d.dictationPolishThinking
        spokenTurnsOpenQuick = try c.decodeIfPresent(Bool.self, forKey: .spokenTurnsOpenQuick) ?? d.spokenTurnsOpenQuick
        dictationContactsNames = try c.decodeIfPresent(Bool.self, forKey: .dictationContactsNames) ?? d.dictationContactsNames
        dictationCursorContext = try c.decodeIfPresent(Bool.self, forKey: .dictationCursorContext) ?? d.dictationCursorContext
        dictationScreenVocabulary = try c.decodeIfPresent(Bool.self, forKey: .dictationScreenVocabulary) ?? d.dictationScreenVocabulary
        dictationLearnCorrections = try c.decodeIfPresent(Bool.self, forKey: .dictationLearnCorrections) ?? d.dictationLearnCorrections
        dictationSounds  = try c.decodeIfPresent(Bool.self,     forKey: .dictationSounds)  ?? d.dictationSounds
        dictationHistory = try c.decodeIfPresent(Bool.self,     forKey: .dictationHistory) ?? d.dictationHistory
        nudges           = try c.decodeIfPresent(Bool.self,     forKey: .nudges)           ?? d.nudges
        backgroundThinking = try c.decodeIfPresent(Bool.self,   forKey: .backgroundThinking) ?? d.backgroundThinking
        situationOffers = try c.decodeIfPresent(Bool.self, forKey: .situationOffers) ?? d.situationOffers
        situationOffersToChats = try c.decodeIfPresent(Bool.self, forKey: .situationOffersToChats)
            ?? d.situationOffersToChats
        cloudBrowserSites = try c.decodeIfPresent([String].self, forKey: .cloudBrowserSites)
            ?? d.cloudBrowserSites
        quietHours       = try c.decodeIfPresent(Bool.self,     forKey: .quietHours)       ?? d.quietHours
        reminderChannels = try c.decodeIfPresent([String].self, forKey: .reminderChannels) ?? d.reminderChannels
        reminderChannelsAutoPicked = try c.decodeIfPresent(Bool.self, forKey: .reminderChannelsAutoPicked)
            ?? (c.contains(.reminderChannels) ? true : d.reminderChannelsAutoPicked)
        // Clamped rather than refused: someone who typed 240 wants warning,
        // not silence, and the job clamps the same way.
        calendarHeadsUpMinutes = min(120, max(0, try c.decodeIfPresent(Int.self, forKey: .calendarHeadsUpMinutes)
                                                  ?? d.calendarHeadsUpMinutes))
        screenContext    = try c.decodeIfPresent(Bool.self,     forKey: .screenContext)    ?? d.screenContext
        screenPointerMovesMouse = try c.decodeIfPresent(Bool.self, forKey: .screenPointerMovesMouse) ?? d.screenPointerMovesMouse
        computerUseMayTakeOver = try c.decodeIfPresent(Bool.self, forKey: .computerUseMayTakeOver) ?? d.computerUseMayTakeOver
        // Brain: a string, like `brain` — an unknown provider id falls back
        // rather than taking the whole config down with it.
        let rawProvider  = try c.decodeIfPresent(String.self,   forKey: .brainProvider)
        brainProvider    = rawProvider.flatMap(BrainProviderKind.init(rawValue:))     ?? d.brainProvider
        let unknownProvider = rawProvider != nil && BrainProviderKind(rawValue: rawProvider!) == nil
        if let raw = rawProvider, unknownProvider {
            Log.write("config.json: brainProvider \"\(raw)\" is not a provider Moe offers; "
                      + "using \(d.brainProvider.rawValue) on \(d.brainProvider.defaultModel)")
        }
        // The model has to fall back with the provider, not survive it.
        //
        // An older Moe reading a config a newer one wrote — the app was
        // replaced by an older copy, or a downgrade — dropped the provider it
        // did not recognise and kept the model that belonged to it. That
        // pairs claude-code-cli with, say, deepseek-v4-pro: a combination
        // that cannot work, and whose failure ("There's an issue with the
        // selected model") points at the model rather than at the swap that
        // caused it, while the pane cheerfully says Claude. A fallback has to
        // land somewhere that runs.
        let savedModel   = try c.decodeIfPresent(String.self,   forKey: .brainModel)       ?? d.brainModel
        brainModel       = unknownProvider ? brainProvider.defaultModel : savedModel
        brainExtras      = try c.decodeIfPresent([String: String].self, forKey: .brainExtras) ?? d.brainExtras
        // One of the four or nil, and `try?`: a hand-edited 45 or a string
        // is no choice at all, never a decode failure that resets every
        // setting.
        let rawWorkLimit = try? c.decodeIfPresent(Int.self, forKey: .workLimitMinutes)
        workLimitMinutes = WorkLimit.chosen(rawWorkLimit)
        browseAsProfile  = try? c.decodeIfPresent(String.self, forKey: .browseAsProfile)
        brainCapabilitiesCache = try? c.decodeIfPresent(BrainCapabilityCache.self, forKey: .brainCapabilitiesCache)
        dictationPolishModel = try c.decodeIfPresent(String.self, forKey: .dictationPolishModel) ?? d.dictationPolishModel
        meetingAskBeforeStart = try c.decodeIfPresent(Bool.self, forKey: .meetingAskBeforeStart) ?? d.meetingAskBeforeStart
        meetingSummarise = try c.decodeIfPresent(Bool.self, forKey: .meetingSummarise) ?? d.meetingSummarise
        meetingHotkey = try c.decodeIfPresent(Bool.self, forKey: .meetingHotkey) ?? d.meetingHotkey
        meetingDeleteRecordings = try c.decodeIfPresent(Bool.self, forKey: .meetingDeleteRecordings) ?? d.meetingDeleteRecordings
        meetingHintShown = try c.decodeIfPresent(Bool.self, forKey: .meetingHintShown) ?? d.meetingHintShown
        meetingSendTelegram = try c.decodeIfPresent(Bool.self, forKey: .meetingSendTelegram) ?? d.meetingSendTelegram
        meetingAutoDetect = (try? c.decodeIfPresent(DetectMode.self, forKey: .meetingAutoDetect)) ?? d.meetingAutoDetect
        meetingAutoStopOnCallEnd = try c.decodeIfPresent(Bool.self, forKey: .meetingAutoStopOnCallEnd)
            ?? d.meetingAutoStopOnCallEnd
        meetingCalendarOfferShown = try c.decodeIfPresent(Bool.self, forKey: .meetingCalendarOfferShown)
            ?? d.meetingCalendarOfferShown
        meetingDetectIgnored = try c.decodeIfPresent([String].self, forKey: .meetingDetectIgnored) ?? d.meetingDetectIgnored
        meetingCapture = (try? c.decodeIfPresent(CapturePolicy.self, forKey: .meetingCapture)) ?? d.meetingCapture
        meetingCaptureHotkeys = try c.decodeIfPresent(Bool.self, forKey: .meetingCaptureHotkeys) ?? d.meetingCaptureHotkeys
        let edge = (try c.decodeIfPresent(String.self, forKey: .cloudEdge) ?? d.cloudEdge)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cloudEdge = edge.isEmpty ? Config.defaultCloudEdge : edge
        cloudVoice = try c.decodeIfPresent(Bool.self, forKey: .cloudVoice) ?? d.cloudVoice
        cloudVoiceDeveloperKeys = try c.decodeIfPresent(Bool.self, forKey: .cloudVoiceDeveloperKeys) ?? d.cloudVoiceDeveloperKeys
        awayWelcomeSeen = try c.decodeIfPresent(String.self, forKey: .awayWelcomeSeen) ?? d.awayWelcomeSeen
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.write("config.json could not be read (\(error)); using defaults")
            return Config()
        }
    }

    func save() { save(to: Config.configURL) }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: url)
    }

    /// Write `config` to `url` only when nothing is there yet. True when it
    /// wrote. The launch calls this so a fresh install's defaults reach the
    /// scripts that read config.json (AppDelegate says which); an existing
    /// file — the person's — is never touched.
    @discardableResult
    static func writeIfAbsent(_ config: Config, at url: URL = Config.configURL) -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        config.save(to: url)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Change one or more settings without clobbering anyone else's.
    ///
    /// Several objects hold their own `Config` — it's a struct, so each gets a
    /// copy. Calling `save()` on a stale copy silently reverts every setting
    /// changed elsewhere since it was loaded. That is exactly how
    /// "always listening" turned itself off when the voice was changed. Always
    /// re-read from disk, apply the change, then write.
    @discardableResult
    static func update(_ change: (inout Config) -> Void) -> Config {
        var latest = Config.load()
        change(&latest)
        latest.save()
        return latest
    }

    // MARK: Brain (see BrainProviderKind, BrainSettings)

    /// Which Hermes provider runs the conversation. Hermes's own id
    /// ("claude-code-cli", "openai-codex", "anthropic", …). Mirrored into
    /// ~/.hermes/config.yaml by configure-hermes.py --set-provider; sent
    /// with every request too, so the two can't disagree for a turn.
    var brainProvider: BrainProviderKind = .claudeCode
    /// The model id for that provider ("sonnet", "gpt-5.5", "vendor/model").
    /// Sent in every request; empty means Hermes's config.yaml default.
    /// Sonnet for a new person, not Opus (docs/DEFAULTS.md row 2): lighter
    /// on the plan's allowance. Anyone who picked a model keeps it.
    var brainModel: String = "sonnet"
    /// Provider-specific extras. Keys in use: "reasoningEffort" (none…xhigh,
    /// API providers only), "baseURL" (local servers).
    var brainExtras: [String: String] = [:]
    /// Settings › Brain › "How long Moe may work on one thing", in minutes:
    /// 5, 15, 30 or 60 (docs/DEFAULTS.md row 32). Hermes's
    /// `claude_code.turn_timeout`; configure-hermes.py reads it from here on
    /// every launch. See `WorkLimit`. Nil until the person picks one: the
    /// key is then left out of config.json, and a `turn_timeout` hand-set in
    /// Hermes's config.yaml is left alone. The pane shows 30 for nil.
    var workLimitMinutes: Int? = nil
    /// Settings › Permissions › "Browse as": which browser profile Moe's own
    /// browser carries the logins of — a Chrome profile directory name
    /// ("Default", "Profile 4"), "" for "whichever I used last", nil until
    /// the person picks. configure-hermes.py turns it into Hermes's
    /// `browser.real_profile_pin` on every launch; the names and accounts
    /// the picker shows come from `BrowseAs`. See ticket #5: Hermes copies
    /// the profile Chrome used LAST, so on a Mac with seven profiles Moe
    /// browsed as whoever was clicked into most recently.
    var browseAsProfile: String? = nil
    /// Model for the dictation polish pass, same provider. Empty = brainModel.
    /// A cheaper model here keeps dictation quick without touching the
    /// conversation.
    var dictationPolishModel: String = ""
    /// What the brain can do, as last worked out on Apply (the table, then
    /// Hermes's answer over it — `Conductor.applyBrain`,
    /// `refreshBrainCapabilities`). Kept with the provider and model it was
    /// worked out for, so a hand-edited config.json never wears stale
    /// answers; read through `brainCapabilities`.
    var brainCapabilitiesCache: BrainCapabilityCache?

    /// The brain's capabilities: the cache when it is for this very
    /// provider and model, else the table's answer for them.
    var brainCapabilities: BrainCapabilities {
        if let c = brainCapabilitiesCache, c.provider == brainProvider.rawValue, c.model == brainModel {
            return c.capabilities
        }
        return brainProvider.capabilities(for: brainModel)
    }
}

/// `Config.brainCapabilitiesCache`: an answer and who it was for.
struct BrainCapabilityCache: Codable, Equatable {
    var provider: String
    var model: String
    var capabilities: BrainCapabilities
}

/// Which bare modifier starts dictation when held on its own.
///
/// Only right-hand keys: the left ones are in every shortcut on the keyboard.
/// Identified by the device-dependent bits of `CGEventFlags`, which is the
/// only place macOS says which side was pressed (IOLLEvent.h, NX_DEVICE*).
enum DictationKey: String, Codable, CaseIterable, Identifiable {
    case rightCommand, rightControl, fn, off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .fn:           return "fn / 🌐"
        case .off:          return "Off"
        }
    }

    /// The device-dependent flag bit for this key, or nil for `.off`.
    var flagBit: UInt64? {
        switch self {
        case .rightCommand: return 0x0000_0010     // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x0000_2000     // NX_DEVICERCTLKEYMASK
        case .fn:           return 0x0080_0000     // NX_SECONDARYFNMASK
        case .off:          return nil
        }
    }

    /// The side-agnostic modifier this key also sets, so a chord check can
    /// exclude "its own" modifier when asking whether anything else is held.
    var genericFlag: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .fn:           return .maskSecondaryFn
        case .off:          return []
        }
    }
}

/// Which bare modifier you hold to talk to Moe (docs/DEFAULTS.md row 8).
///
/// Right-hand keys and fn only, for the reason `DictationKey` gives: the left
/// ones are in every shortcut on the keyboard. The bits are the same
/// device-dependent ones `DictationKey` reads, plus right ⌥ — which is why a
/// talk key and a dictation key can be compared bit for bit.
enum TalkKey: String, Codable, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    /// For a picker or the start of a sentence.
    var label: String {
        switch self {
        case .rightOption:  return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .fn:           return "fn / 🌐"
        }
    }

    /// For the middle of a sentence: "Hold right ⌥ and talk".
    var inSentence: String {
        switch self {
        case .rightOption:  return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        case .fn:           return "fn / 🌐"
        }
    }

    /// Where the key is, for someone who has never looked for it.
    var whereItIs: String {
        switch self {
        case .rightOption:  return "the Option key to the right of the space bar"
        case .rightCommand: return "the Command key just to the right of the space bar"
        case .rightControl: return "the Control key on the right of your keyboard"
        case .fn:           return "the fn or 🌐 key in the bottom corner of your keyboard"
        }
    }

    /// The device-dependent flag bit PushToTalk tests for this key.
    var flagBit: UInt64 {
        switch self {
        case .rightOption:  return 0x0000_0040     // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x0000_0010     // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x0000_2000     // NX_DEVICERCTLKEYMASK
        case .fn:           return 0x0080_0000     // NX_SECONDARYFNMASK
        }
    }

    /// The side-agnostic modifier this key also sets, so "is anything else
    /// held" can leave the key's own modifier out.
    var genericFlag: CGEventFlags {
        switch self {
        case .rightOption:  return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .fn:           return .maskSecondaryFn
        }
    }

    /// Whether a dictation key is this very key. One physical key cannot
    /// mean both "do what I said" and "type what I said", and talking wins
    /// (`Conductor.effectiveDictationKey`).
    func collides(with key: DictationKey) -> Bool {
        key.flagBit == flagBit
    }
}

enum Paths {
    static var home: URL { Config.homeDir }

    /// Whether the person is at this Mac, for the delivery path. Written by
    /// `Conductor.writePresence`; read by `moe-screen/deliver.py at_mac()`,
    /// which treats a stamp older than three minutes as "not here".
    static var presence: URL { home.appendingPathComponent("presence.json") }

    /// Where the person is, in time: this Mac's zone, written by
    /// `Conductor.writeTimeZone` on launch, wake and every zone change. It
    /// travels to the cloud copy as the `tz` document (docs/LOOPS.md §5).
    static var timeZone: URL { home.appendingPathComponent("tz.json") }
    /// The one turn Moe is working on for the person, written when it
    /// starts and removed when it ends — so a Mac that slept, or a Moe that
    /// was quit, mid-answer can pick it up instead of losing it (`TurnKeeper`).
    static var inflightTurn: URL { home.appendingPathComponent("turns/inflight.json") }

    /// Moves a pre-0.3.5 `~/.moe` to `~/Library/Application Support/Moe`.
    ///
    /// Returns a line for the log, always; never throws. A migration that
    /// fails must not stop Moe from starting — the worst case is that the
    /// user's memories are still at the old path, which is recoverable, while
    /// a Moe that will not launch is not.
    ///
    /// Deliberately conservative:
    ///
    ///   * it only ever runs when the new home does **not** exist. If both
    ///     exist, something else has already made one, and merging two homes
    ///     automatically is how a person loses notes. It says so and stops.
    ///   * it is a `moveItem`, which on one volume is a rename: atomic, no
    ///     window where the data is in neither place, and no second copy of a
    ///     1 GB directory on a disk that may not have room for one.
    ///   * a symlink is left behind at `~/.moe`. 300-odd shell scripts, the
    ///     user's own aliases, and anything a person has wired up themselves
    ///     still name the old path, and this is what keeps every one of them
    ///     working through the change rather than only the ones we found.
    ///
    /// `MOE_HOME` short-circuits it: a test or a scratch home has nothing to
    /// migrate and must not touch the real one.
    @discardableResult
    static func migrateLegacyHome(old: URL = Config.legacyHome,
                                  new: URL = Config.legacyHomeMigrationTarget,
                                  honourMoeHome: Bool = true) -> String {
        if honourMoeHome, TestHooks.env("MOE_HOME") != nil { return "MOE_HOME is set; no migration" }

        let fm = FileManager.default

        var oldIsDir: ObjCBool = false
        let oldExists = fm.fileExists(atPath: old.path, isDirectory: &oldIsDir)
        // A symlink means this already ran. `fileExists` follows links, so ask
        // separately — otherwise every launch after the first would report the
        // old home as still present and try again.
        let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
        guard oldExists, oldIsDir.boolValue, !oldIsLink else {
            // Nothing to move — but a *new* install has no ~/.moe at all, and
            // the 300-odd scripts that still name that path would then create
            // a second, parallel home there and quietly write half the user's
            // data into it. The link has to exist either way.
            return ensureLegacyLink(old: old, new: new)
        }

        if fm.fileExists(atPath: new.path) {
            // Both exist. When the old one holds nothing of the person's —
            // only what tooling leaves behind before Moe has ever run — it is
            // folded into the new home and the link made. Measured on
            // 2026-09-07: a developer Mac's worktree-snapshot job had written
            // ~/.moe/bin and ~/.moe/logs within five minutes of a wipe, the
            // first launch found "both exist", refused, and every payload
            // path spelling $HOME/.moe then wrote into an empty second home
            // (ledger, inbox, memory, context) — the exact split the link
            // exists to prevent, on the first day of the product. Anything
            // that could be a person's — a memory, a note, a config — keeps
            // the refusal: no rule can know which of two homes to keep.
            if let stray = strayContents(of: old) {
                do {
                    try fold(stray, from: old, into: new)
                    try fm.removeItem(at: old)
                    try fm.createSymbolicLink(at: old, withDestinationURL: new)
                } catch {
                    return "\(old.path) held only \(stray.joined(separator: ", ")) but could not be folded "
                         + "into \(new.path): \(error.localizedDescription) — leaving both alone"
                }
                return "\(old.path) held only \(stray.joined(separator: ", ")) — nothing of yours; "
                     + "folded it into \(new.path) and linked ~/.moe to it"
            }
            return "both \(old.path) and \(new.path) exist; leaving them alone — "
                 + "move what you want to keep by hand"
        }

        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
        } catch {
            return "could not move \(old.path): \(error.localizedDescription)"
        }

        // The compatibility link. Failing to make it is not fatal — the data
        // is safely at the new path either way — but it is worth saying,
        // because it is what everything still naming ~/.moe depends on.
        do {
            try fm.createSymbolicLink(at: old, withDestinationURL: new)
        } catch {
            return "moved to \(new.path), but could not link \(old.path) to it: "
                 + error.localizedDescription
        }
        return "moved ~/.moe to \(new.path), and linked the old path to it"
    }

    /// The top-level names in a legacy home that holds nothing of the
    /// person's, or nil when anything else is there. Only what tooling
    /// writes before Moe runs is stray: `bin`, `logs`, Finder's `.DS_Store`,
    /// and directories with nothing in them. A memory, a note, a config, a
    /// ledger — any file outside those — makes it a home, and a home is not
    /// folded.
    static func strayContents(of dir: URL) -> [String]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names {
            if name == ".DS_Store" || name == "bin" || name == "logs" { continue }
            var isDir: ObjCBool = false
            let path = dir.appendingPathComponent(name).path
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true else { return nil }
        }
        return names.sorted()
    }

    /// Move the stray entries across. A file that already exists at the
    /// destination is a conflict, and a conflict is an error rather than a
    /// choice — nothing here is ever overwritten.
    private static func fold(_ names: [String], from old: URL, into new: URL) throws {
        let fm = FileManager.default
        for name in names {
            let src = old.appendingPathComponent(name)
            let dst = new.appendingPathComponent(name)
            var srcIsDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &srcIsDir)
            if !fm.fileExists(atPath: dst.path) {
                try fm.moveItem(at: src, to: dst)
            } else if srcIsDir.boolValue {
                for child in try fm.contentsOfDirectory(atPath: src.path) {
                    let s = src.appendingPathComponent(child), d = dst.appendingPathComponent(child)
                    if fm.fileExists(atPath: d.path) {
                        throw NSError(domain: "Moe.Home", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "\(name)/\(child) exists in both homes"])
                    }
                    try fm.moveItem(at: s, to: d)
                }
                try fm.removeItem(at: src)
            } else {
                throw NSError(domain: "Moe.Home", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(name) exists in both homes"])
            }
        }
    }

    /// Makes `~/.moe` a symlink to the real home, when nothing is there.
    ///
    /// This is the compatibility shim the move rests on. Moe's own Swift now
    /// reads `~/Library/Application Support/Moe`, but the payload's ~317
    /// references to `$HOME/.moe` — across every connector, tool and hook, and
    /// in whatever the user has wired up themselves — do not. Rewriting all of
    /// them at once is how a connector breaks silently; the link makes both
    /// spellings the same directory, so they can be moved over one at a time
    /// and the shim retired when none are left.
    ///
    /// Never replaces anything that already exists, including a real
    /// directory: that would be the merge case, and it belongs to a person.
    @discardableResult
    static func ensureLegacyLink(old: URL = Config.legacyHome,
                                 new: URL = Config.legacyHomeMigrationTarget) -> String {
        let fm = FileManager.default

        // A link that already points at the right place is the steady state.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: old.path) {
            let resolved = dest.hasPrefix("/") ? dest
                : old.deletingLastPathComponent().appendingPathComponent(dest).path
            return resolved == new.path
                ? "nothing to migrate"
                : "~/.moe points at \(resolved), not \(new.path); leaving it alone"
        }
        // Anything else already at ~/.moe is not ours to remove.
        if fm.fileExists(atPath: old.path) { return "nothing to migrate" }
        guard fm.fileExists(atPath: new.path) else { return "nothing to migrate" }

        do {
            try fm.createSymbolicLink(at: old, withDestinationURL: new)
            return "linked ~/.moe to \(new.path)"
        } catch {
            return "could not link ~/.moe to \(new.path): \(error.localizedDescription)"
        }
    }
    static var memory: URL { home.appendingPathComponent("memory", isDirectory: true) }
    static var context: URL { home.appendingPathComponent("context", isDirectory: true) }
    static var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    /// Moe's own system prompt — "who you are", as the person can edit it.
    ///
    /// Named for no vendor. Moe runs on whatever is behind Hermes: a Claude
    /// Code sign-in, a ChatGPT sign-in, or a plain API key for any provider.
    /// It was `CLAUDE.md` until 2026-09-04, which told a Codex user something
    /// false about a file in their own directory, and `AGENTS.md` is the
    /// cross-vendor convention several agents already read natively.
    ///
    /// Nothing auto-discovered the old name — the Claude Code workspace is
    /// `~/.hermes/claude-code/workspace`, not `~/.moe` — so this was never a
    /// functional dependency, only a misleading one. `BrainPrompt` reads this
    /// file and injects it, which is why the persona reaches every provider.
    static var agentsMd: URL { home.appendingPathComponent("AGENTS.md") }

    /// Where the persona lived before 2026-09-04. Kept as a constant because
    /// the migration and the read-fallback both need to name it.
    static var legacyPersonaFile: URL { home.appendingPathComponent("CLAUDE.md") }

    @available(*, deprecated, renamed: "agentsMd")
    static var claudeMd: URL { agentsMd }

    /// Move a pre-2026-09-04 `CLAUDE.md` to `AGENTS.md`, leaving a symlink.
    ///
    /// The link matters for the same reason `~/.moe` itself is one: people
    /// wire their own things up to these paths, and a rename that breaks a
    /// person's script to win an argument about vendor neutrality is a bad
    /// trade. Both files existing is not merged — that is how someone loses
    /// what they wrote — the new name simply wins and the old one is left
    /// exactly as it is.
    static func migratePersonaFile() -> String {
        let fm = FileManager.default
        let old = legacyPersonaFile
        let new = agentsMd

        if let dest = try? fm.destinationOfSymbolicLink(atPath: old.path) {
            let resolved = dest.hasPrefix("/") ? dest
                : old.deletingLastPathComponent().appendingPathComponent(dest).path
            return resolved == new.path
                ? "nothing to migrate"
                : "CLAUDE.md points at \(resolved), not \(new.path); leaving it alone"
        }
        guard fm.fileExists(atPath: old.path) else { return "nothing to migrate" }
        if fm.fileExists(atPath: new.path) {
            return "both AGENTS.md and CLAUDE.md exist; using AGENTS.md and leaving CLAUDE.md alone"
        }
        do {
            try fm.moveItem(at: old, to: new)
            try? fm.createSymbolicLink(at: old, withDestinationURL: new)
            return "persona: CLAUDE.md → AGENTS.md (old name kept as a link)"
        } catch {
            return "could not rename CLAUDE.md: \(error.localizedDescription)"
        }
    }
    static var brief: URL { context.appendingPathComponent("_brief.md") }
    /// What is connected, refreshed by sync.sh beside the brief.
    static var connections: URL { context.appendingPathComponent("_connections.md") }
    /// Where meetings land: one folder per meeting, 0700 (MeetingRecorder).
    static var meetings: URL { home.appendingPathComponent("meetings", isDirectory: true) }
    static var dictationHistory: URL { home.appendingPathComponent("dictation-history.jsonl") }
    /// The licence key, as the customer pasted it, 0600 (LicenceFile). Absent
    /// on every install that has not bought anything, which is all of them
    /// today — nothing is gated.
    static var licence: URL { home.appendingPathComponent("licence.txt") }
    /// One JSON file per chat thread, 0700 (ConversationStore). Written only
    /// by the projector now — it is derived from `ledger`, not truth.
    static var conversations: URL { home.appendingPathComponent("conversations", isDirectory: true) }
    /// The append-only record of what was said, one JSONL file per device,
    /// 0700 (MoeLedger, docs/ONE-AGENT.md §1.5).
    static var ledger: URL { home.appendingPathComponent("ledger", isDirectory: true) }
    /// What this Mac is to the cloud: its device key pair, the peers it has
    /// authenticated, its credential and where it had got to — 0700, each
    /// file 0600 (`CloudSync`, docs/LEDGER-WIRE.md §3, §6.10).
    static var cloud: URL { home.appendingPathComponent("cloud", isDirectory: true) }

    /// config.json's `hermesBinary`, else (debug builds only) `MOE_HERMES_BIN`,
    /// else the venv Hermes's installer creates, else the usual places. Not
    /// cached — the override is what the supervisor's tests rely on — and
    /// never called from the main thread (see the note below).
    static func hermesBinary() -> String {
        let configured = Config.load().hermesBinary
        if !configured.isEmpty { return configured }
        if let env = TestHooks.env("MOE_HERMES_BIN") { return env }
        return resolveBinary("hermes", candidates: ["\(NSHomeDirectory())/.hermes/hermes-agent/.venv/bin/hermes"])
    }

    /// Executable, **and** whatever it hands itself to exists.
    ///
    /// `isExecutableFile` alone was fooled on 2026-09-10: a Mac whose
    /// `~/.hermes` had been deleted kept its `~/.local/bin/hermes` — a uv
    /// trampoline, `'''exec' '…/.hermes/hermes-agent/.venv/bin/python'` —
    /// and a wrapper naming a Python that is gone is a well-formed identifier
    /// that resolves to nothing. Moe called Hermes installed, skipped the
    /// bundled seed, and spawned it for ever: exit 126, "the part of Moe that
    /// thinks kept stopping", on a fresh download. So read the first lines
    /// and require the interpreter they name.
    static func isLaunchable(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else { return false }
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 1024)) ?? Data(), as: UTF8.self)
        guard head.hasPrefix("#!") else { return true }        // a binary: nothing to follow
        return interpreters(in: head).allSatisfy { fm.isExecutableFile(atPath: $0) }
    }

    /// The absolute interpreter paths a script's first lines name: the
    /// shebang (unless it is `env`, which searches PATH), and the
    /// `'''exec' '<python>'` line pip and uv write when that path is too
    /// long for a shebang.
    static func interpreters(in head: String) -> [String] {
        var out: [String] = []
        if let first = head.split(separator: "\n", maxSplits: 1).first {
            let exe = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            if exe.hasPrefix("/"), !exe.hasSuffix("/env") { out.append(exe) }
        }
        if let r = head.range(of: #"'''exec' '[^']+'"#, options: .regularExpression) {
            out.append(String(head[r].dropFirst("'''exec' '".count).dropLast()))
        }
        return out
    }

    /// Returns the bare `name` if nothing is found, so that spawning it fails
    /// with a clear error instead of a crash.
    private static func resolveBinary(_ name: String, candidates extra: [String]) -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ] + extra
        for c in candidates where isLaunchable(c) { return c }

        // Last resort: ask a login shell. This sources the user's whole profile
        // and can take seconds, which is why the supervisor resolves it on its
        // own queue rather than during launch.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return name
        }
        // Close our copy of the write end, or readToEnd() waits for an EOF
        // that never arrives and hangs whatever thread we're on.
        try? pipe.fileHandleForWriting.close()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? name : out
    }
}

/// Environment overrides that exist for scripts/test-*.sh and are compiled
/// out of release builds, so a shipped Moe can't be pointed at a different
/// binary or keychain item by whatever launched it.
enum TestHooks {
    static func env(_ name: String) -> String? {
        #if DEBUG
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
        #else
        return nil
        #endif
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "moe.log")
    private static var lastHeard = ""
    /// The file under ~/.moe/logs. CLI modes (`--wake-bench` and friends)
    /// point this elsewhere so a bench run does not read as the app's own
    /// activity in moe.log.
    static var fileName = "moe.log"

    /// What the microphone is transcribing while waiting for the wake phrase.
    /// Throttled to changes only — without this there is no way to tell the
    /// difference between "it can't hear you" and "it heard you and didn't
    /// match".
    static func heard(_ text: String) {
        let tail = String(text.suffix(90))
        queue.async {
            guard tail != lastHeard else { return }
            lastHeard = tail
        }
        guard !tail.isEmpty else { return }
        write("heard: \(tail)")
    }
    /// Wait for everything queued so far to reach the file. For the CLI
    /// paths that `exit()` right after their last line.
    static func flush() {
        queue.sync {}
    }
    static func write(_ line: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
            let url = Paths.logs.appendingPathComponent(fileName)
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                let end = (try? h.seekToEnd()) ?? 0
                guard end + UInt64(data.count) <= limit else {
                    try? h.close()
                    rotate(url)
                    try? data.write(to: url)
                    return
                }
                defer { try? h.close() }
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// moe.log gets a `heard:` line per utterance and used to grow for ever.
    /// Same bound as the gateway log: 5 MiB and one previous generation
    /// (`moe.log.1`), so the pair never passes ~10 MiB.
    static let limit: UInt64 = 5 * 1024 * 1024

    static func rotate(_ url: URL) {
        let fm = FileManager.default
        let old = URL(fileURLWithPath: url.path + ".1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
}
