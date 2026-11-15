import Foundation
import MoeBrain
import MoeIsland
import MoeMeeting

/// The entries themselves, page by page, in the order the pages show them.
/// Read SettingsCatalogue.swift for what each field means; the tests in
/// SettingsCatalogueTests hold every title to its page's source.
extension SettingsCatalogue {

    /// Sidebar order: Brain, Voice, Meeting Capture, Permissions, Running in
    /// the background (with its Reminders tab), Privacy.
    static let all: [Entry] = brain + voice + meetingCapture + permissions + background + privacy

    /// A choice from a fixed list, applied through a Conductor setter and
    /// read back to say whether it took.
    static func pick(_ id: String, _ title: String, _ page: MainWindow.Section, under: String? = nil,
                     does: String, says: [String], who: Who,
                     options: [(value: String, label: String)],
                     get: @escaping @MainActor @Sendable (Conductor) -> String,
                     set: @escaping @MainActor @Sendable (Conductor, String) -> Void) -> Entry {
        Entry(id: id, title: title, page: page, under: under, does: does, says: says, who: who,
              kind: .choice(options),
              read: get,
              write: { c, v in
                  set(c, v)
                  return get(c) == v
              })
    }

    // MARK: - Brain

    /// The brain's three rows go through `BrainSetup` (writes Hermes's own
    /// config, off the main thread) and then a probe that proves the new
    /// brain answers — there is no Conductor setter to call, and all three
    /// are the person's to change, so `write` never applies anything; the
    /// bridge opens Settings on the row instead.
    static let brain: [Entry] = [
        // Choices are whatever the person's own provider offers, read live
        // on the page — never a list written here — so none are published.
        Entry(id: "brainModel", title: "Model", page: .brain,
              does: "Which of your AI service's models Moe thinks with. Bigger models are smarter and slower; smaller ones are quicker and cost less.",
              says: ["use a smarter model", "use a cheaper model", "it's not smart enough", "it's too slow",
                     "change the model", "costs too much", "switch the AI", "use a faster model"],
              who: .person,
              kind: .choice([]),
              read: { $0.config.brainModel },
              write: { _, _ in false }),
        // id: the value lives at brainExtras.reasoningEffort in config.json.
        // The page offers only the levels the chosen model takes; this is
        // every level any provider takes, plus the default.
        Entry(id: "reasoningEffort", title: "How hard it thinks", page: .brain,
              does: "How long Moe thinks before answering. Higher is slower and more thorough; lower is quicker.",
              says: ["think harder", "it's too slow", "answers are careless", "takes forever to answer",
                     "be more thorough", "answer faster", "it doesn't think things through"],
              who: .person,
              kind: .choice([("", "Default")] + ["none", "minimal", "low", "medium", "high", "xhigh", "max"].map {
                  ($0, "\($0) — \(BrainProviderKind.effortCaption($0))")
              }),
              read: { $0.config.brainExtras["reasoningEffort"] ?? "" },
              write: { _, _ in false }),
        // Shown only on the Claude plan.
        Entry(id: "workLimitMinutes", title: "Longest it works on one thing", page: .brain,
              does: "How long Moe may keep working on one task before it stops and tells you.",
              says: ["it gave up too soon", "it stopped in the middle", "it ran out of time",
                     "it works on things for too long", "let it keep going", "it timed out"],
              who: .person,
              kind: .choice(WorkLimit.choices.map { (String($0), $0 == 60 ? "1 hour" : "\($0) min") }),
              read: { String(WorkLimit.normalised($0.config.workLimitMinutes)) },
              write: { _, _ in false }),
    ]

    // MARK: - Voice

    static let voice: [Entry] = [
        // Starting
        pick("talkKey", "Hold a key to talk", .voice,
             does: "The key you hold down anywhere to talk to Moe, then let go.",
             says: ["change the talk key", "wrong key", "I keep pressing it by accident", "use a different key",
                    "the key gets in the way", "which key do I hold"],
             who: .moe,
             options: TalkKey.allCases.map { ($0.rawValue, $0.label) },
             get: { $0.config.talkKey.rawValue },
             set: { c, v in if let k = TalkKey(rawValue: v) { c.setTalkKey(k) } }),
        toggle("wakeWordEnabled", "Or just say “Hey Moe”", .voice,
               does: "Moe listens for its name so you can start talking without touching a key. Only its name is listened for.",
               says: ["hey moe", "always listening", "it wakes up by itself", "it hears me when I'm not talking to it",
                      "turn on the wake word", "talk without pressing anything", "is it listening to me"],
               who: .person,
               get: { $0.alwaysListening }, set: { $0.setAlwaysListening($1) }),

        // The conversation
        toggle("conversationMode", "Keep listening after Moe answers", .voice,
               does: "After an answer, you can just carry on talking without pressing a key or saying its name.",
               says: ["it keeps listening", "it won't stop listening", "let me just keep talking",
                      "I have to press the key every time", "it heard what I said to someone else",
                      "back and forth conversation"],
               who: .person,
               get: { $0.config.conversationMode }, set: { $0.setConversationMode($1) }),
        pick("followUpSeconds", "Waits for", .voice, under: "Keep listening after Moe answers",
             does: "How long Moe keeps listening for you to carry on after it answers.",
             says: ["stops listening too fast", "it doesn't give me time to answer", "waits too long",
                    "it keeps listening for too long", "give me more time"],
             who: .moe,
             options: VoiceSettingsModel.waitChoices(current: 8).map { (String($0), "\($0) s") },
             get: { String(Int($0.config.followUpSeconds)) },
             set: { c, v in if let s = Double(v) { c.setFollowUpSeconds(s) } }),
        pick("closeOffer", "When you go quiet", .voice, under: "Keep listening after Moe answers",
             does: "What Moe does when you stop talking: ask on the island whether you're done, ask out loud, both, or simply stop listening.",
             says: ["stop asking if I'm done", "it keeps asking me", "just stop listening",
                    "annoying question at the end", "don't ask out loud"],
             who: .moe,
             options: [("shown", "Ask on the island"), ("spoken", "Ask out loud"),
                       ("both", "Both"), ("off", "Just stop listening")],
             get: { $0.config.closeOffer }, set: { $0.setCloseOffer($1) }),
        toggle("bargeIn", "Let me interrupt Moe by talking", .voice,
               does: "Talking over Moe stops it, the way you'd interrupt a person. Off, only the key stops it.",
               says: ["it keeps stopping mid-sentence", "it cuts itself off", "it stops when I cough",
                      "I can't interrupt it", "let me talk over it", "it stops talking for no reason"],
               who: .person,
               get: { $0.config.bargeIn }, set: { $0.setBargeIn($1) }),

        // Moe's answers
        pick("speakReplies", "Answers", .voice,
             does: "Whether Moe ever speaks its answers, or keeps every answer on screen.",
             says: ["stop talking", "be quiet", "don't speak", "I don't want it to talk out loud",
                    "just show me the answer", "talk to me", "answer out loud", "too noisy"],
             who: .moe,
             options: [("loud", "Out loud"), ("screen", "On screen only")],
             get: { $0.config.speakReplies ? "loud" : "screen" },
             set: { $0.setSpeakReplies($1 == "loud") }),
        // Shown while answers are out loud. The voices depend on the language
        // and on what is downloaded, and picking one is applied in the
        // background (and the Premium ones need a paid plan), so no choices
        // are published and the person picks it on the page.
        Entry(id: "ttsVoice", title: "Voice", page: .voice, under: "Answers",
              does: "The voice Moe speaks with. You can hear each one before you choose.",
              says: ["I don't like the voice", "change the voice", "sounds robotic", "a different voice",
                     "male voice", "female voice", "the voice is annoying"],
              who: .person,
              kind: .choice([]),
              read: { $0.config.ttsVoice },
              write: { _, _ in false }),
        Entry(id: "replyLength", title: "How much Moe says", page: .voice,
              does: "How long Moe's answers are: Short, Balanced or Detailed. Asking for more always gets more.",
              says: ["too long", "talks too much", "too chatty", "rambles", "shorter answers",
                     "more detail", "answers are too short", "get to the point"],
              who: .moe,
              kind: .choice(ReplyLength.allCases.map { ($0.rawValue, $0.label) }),
              read: { $0.config.replyLength },
              write: { c, v in
                  guard let length = ReplyLength(rawValue: v) else { return false }
                  c.setReplyLength(length)
                  return c.config.replyLength == v
              }),

        // More › Starting
        pick("hotKeyModifiers", "Shortcut to ask", .voice, under: "More",
             does: "The key combination that opens Moe to ask something. Takes effect when Moe restarts.",
             says: ["the shortcut doesn't work", "shortcut clashes with another app", "change the shortcut",
                    "control option space", "it pastes instead", "keyboard shortcut"],
             who: .moe,
             options: [("6144", "⌃⌥Space"), ("2048", "⌥Space"), ("2304", "⌘⌥Space"), ("4096", "⌃Space")],
             get: { String($0.config.hotKeyModifiers) },
             set: { c, v in if let m = UInt32(v) { c.setHotKeyModifiers(m) } }),
        toggle("holdOpensConversation", "Keep listening after a held-key turn too", .voice, under: "More",
               does: "After a question asked by holding the key, Moe keeps listening for you to carry on, as it does otherwise.",
               says: ["keep listening after I hold the key", "it stops listening after I let go",
                      "it keeps listening after I let go of the key", "one question at a time"],
               who: .person,
               get: { $0.config.holdOpensConversation }, set: { $0.setHoldOpensConversation($1) }),
        // .person: a wrong language can leave Moe unable to understand the
        // request to put it back, and some need a large download.
        pick("locale", "Language", .voice, under: "More",
             does: "The language Moe listens for. Some languages download a large file the first time.",
             says: ["speak Spanish", "it doesn't understand my language", "change the language",
                    "it hears the wrong language", "talk to it in French", "Hebrew"],
             who: .person,
             options: SpeechLanguages.all.map { ($0.locale, $0.label) },
             get: { SpeechLanguages.entry(for: $0.config.locale)?.locale ?? $0.config.locale },
             set: { $0.setLanguage($1) }),

        // More › While Moe works
        toggle("instantAck", "Say “on it” as soon as I ask", .voice, under: "More",
               does: "A quick spoken \"on it\" the moment you ask, when Moe is going to answer out loud.",
               says: ["stop saying on it", "on it on it", "it says on it every time",
                      "let me know you heard me", "annoying acknowledgement"],
               who: .moe,
               get: { $0.config.instantAck }, set: { $0.setInstantAck($1) }),
        toggle("spokenProgress", "Tell me what it’s doing while it works", .voice, under: "More",
               does: "When something takes a while, Moe says once what it is doing, like \"checking your calendar\".",
               says: ["stop narrating", "too much commentary", "it tells me every step",
                      "I don't know what it's doing", "say what you're doing", "it goes quiet for ages"],
               who: .moe,
               get: { $0.config.spokenProgress }, set: { $0.setSpokenProgress($1) }),
        toggle("replyChime", "Ding when a written answer is ready", .voice, under: "More",
               does: "One soft note when a written answer is ready and Moe is not saying it out loud.",
               says: ["stop dinging", "the ding", "that sound", "the chime", "beeping", "noise when it answers"],
               who: .moe,
               get: { $0.config.replyChime }, set: { $0.setReplyChime($1) }),

        // More › Answers
        toggle("speakSpokenReplies", "Answer questions I ask out loud, out loud", .voice, under: "More",
               does: "When you ask by talking, Moe answers by talking. Off, it answers on screen.",
               says: ["don't answer out loud when I talk", "talk back to me", "just write the answer",
                      "I asked out loud and it didn't speak"],
               who: .moe,
               get: { $0.config.speakSpokenReplies }, set: { $0.setSpeakSpokenReplies($1) }),
        toggle("speakTypedReplies", "Answer typed questions out loud too", .voice, under: "More",
               does: "When you type a question, Moe also says the answer out loud. Off, typed in, text out.",
               says: ["it talks when I type", "stop reading answers out loud", "read typed answers to me",
                      "I typed so I don't want it to talk", "speaks when I'm typing"],
               who: .moe,
               get: { $0.config.speakTypedReplies }, set: { $0.setSpeakTypedReplies($1) }),
        toggle("typedRepliesReadAsText", "Write typed answers to be read", .voice, under: "More",
               does: "Typed answers come with headings and short lists where they help, rather than a sentence or two.",
               says: ["answers are too short when I type", "use bullet points", "format the answers",
                      "no headings", "write it like a document", "too much formatting"],
               who: .moe,
               get: { $0.config.typedRepliesReadAsText }, set: { $0.setTypedRepliesReadAsText($1) }),
        pick("panelOnReply", "Open the island panel by itself", .voice, under: "More",
             does: "Whether the panel under the notch opens when an answer arrives: always, only when Moe isn't speaking, or never.",
             says: ["the panel keeps popping up", "stop opening the notch", "show me the answer",
                    "it pops open every time", "the panel gets in the way", "I can't see the answer"],
             who: .moe,
             options: PanelReveal.allCases.map { ($0.rawValue, $0.label) },
             get: { PanelReveal(configValue: $0.config.panelOnReply).rawValue },
             set: { c, v in if let r = PanelReveal(rawValue: v) { c.setPanelOnReply(r) } }),
        pick("replyReadingSeconds", "How long the panel stays", .voice, under: "More",
             does: "How long an answer stays open under the notch before it closes by itself.",
             says: ["the answer disappears too fast", "it closes before I can read it", "it stays open too long",
                    "keep the answer up", "the panel won't go away"],
             who: .moe,
             options: VoiceSettingsModel.readingChoices.map {
                 (String(Int($0)), VoiceSettingsModel.readingLabel($0))
             },
             get: { String(Int($0.config.replyReadingSeconds)) },
             set: { c, v in if let s = Double(v) { c.setReplyReadingSeconds(s) } }),
        toggle("typedAnswersOpenChat", "Typed questions open the Chat window", .voice, under: "More",
               does: "On, every typed question opens Chat. Off, the answer stays in the small panel under the notch.",
               says: ["chat window keeps opening", "don't open the chat", "show answers in chat",
                      "answer in the big window"],
               who: .moe,
               get: { $0.config.typedAnswersOpenChat }, set: { $0.setTypedAnswersOpenChat($1) }),
        toggle("notchHoverOpens", "Hovering the notch opens it", .voice, under: "More",
               does: "Resting the pointer on the notch opens its panel, or brings the popped-out chat forward. Off, only a click does.",
               says: ["notch keeps opening", "pops open when I move the mouse", "hover", "opens by itself at the top",
                      "annoying when I go near the notch"],
               who: .moe,
               get: { $0.config.notchHoverOpens }, set: { $0.setNotchHoverOpens($1) }),

        // More › Your voice and Premium
        toggle("cloudVoice", "Premium hearing and voice", .voice, under: "More",
               does: "On a paid plan, Moe hears and speaks through online speech services for sharper hearing and a better voice. Off keeps your voice on this Mac.",
               says: ["better voice", "it mishears me", "premium voice", "keep my voice on my Mac",
                      "don't send my voice anywhere", "it doesn't understand me", "is my voice sent online"],
               who: .person,
               get: { $0.config.cloudVoice }, set: { $0.setCloudVoice($1) }),
    ]

    // MARK: - Meeting Capture

    static let meetingCapture: [Entry] = [
        pick("meetingAutoDetect", "When a call starts", .meetingCapture,
             does: "What Moe does when a Zoom, Teams, FaceTime, Slack or Meet call starts: nothing, offer to record it, or start recording.",
             says: ["stop asking to record my calls", "why is it recording", "record my meetings automatically",
                    "it keeps offering to record", "don't record calls", "notice when I'm on a call"],
             who: .person,
             options: DetectMode.allCases.map { ($0.rawValue, $0.label) },
             get: { $0.config.meetingAutoDetect.rawValue },
             set: { c, v in if let m = DetectMode(rawValue: v) { c.setMeetingAutoDetect(m) } }),
        toggle("meetingAutoStopOnCallEnd", "When the call ends", .meetingCapture,
               does: "When a call ends, Moe stops the recording, saves it and writes the notes without asking. Off, it offers to stop and waits.",
               says: ["it kept recording after the call", "stop recording when the call ends",
                      "it keeps asking whether to stop", "the recording didn't stop", "don't stop on its own"],
               who: .moe,
               get: { $0.config.meetingAutoStopOnCallEnd }, set: { $0.setMeetingAutoStopOnCallEnd($1) }),
        // id: nested at meetingCapture.screenshots in config.json.
        pick("meetingCapture.screenshots", "Screenshots", .meetingCapture,
             does: "Whether Moe takes pictures of the screen during a meeting: never, only when you ask, or by itself when something is shown.",
             says: ["stop taking screenshots", "why is it taking pictures of my screen", "screenshots in meetings",
                    "capture the slides", "don't take pictures"],
             who: .person,
             options: CaptureMode.allCases.map { ($0.rawValue, $0.label) },
             get: { $0.config.meetingCapture.screenshots.rawValue },
             set: { c, v in if let m = CaptureMode(rawValue: v) { c.setMeetingCapture { $0.screenshots = m } } }),
        // id: nested at meetingCapture.recording in config.json.
        pick("meetingCapture.recording", "Screen recordings", .meetingCapture,
             does: "Whether Moe records short clips of the screen during a meeting: never, only when you ask, or by itself.",
             says: ["stop recording my screen", "why is it recording my screen", "record the screen in meetings",
                    "screen recording", "don't record the screen"],
             who: .person,
             options: CaptureMode.allCases.map { ($0.rawValue, $0.label) },
             get: { $0.config.meetingCapture.recording.rawValue },
             set: { c, v in if let m = CaptureMode(rawValue: v) { c.setMeetingCapture { $0.recording = m } } }),
        // id: nested at meetingCapture.scope in config.json.
        pick("meetingCapture.scope", "What the pictures show", .meetingCapture,
             does: "What meeting pictures cover: the whole screen, just the meeting window, or an area you choose.",
             says: ["it captured my whole screen", "only the meeting window", "it saw my other windows",
                    "just capture the shared screen", "too much in the screenshots"],
             who: .person,
             options: CaptureScope.allCases.map { ($0.rawValue, $0.label) },
             get: { $0.config.meetingCapture.scope.rawValue },
             set: { c, v in if let s = CaptureScope(rawValue: v) { c.setMeetingCapture { $0.scope = s } } }),
        // id: nested at meetingCapture.caption in config.json. In the sheet
        // behind the "By itself means" row, which shows only while
        // Screenshots or Screen recordings is Automatically.
        toggle("meetingCapture.caption", "Ask my AI what each picture shows", .meetingCapture,
               under: "By itself means › Choose…",
               does: "Each meeting picture gets a one-line caption in the notes, written by your AI from the picture.",
               says: ["don't send my screenshots to the AI", "caption the screenshots", "what's in the picture",
                      "describe the slides", "it sends pictures to the AI"],
               who: .person,
               get: { $0.config.meetingCapture.caption },
               set: { c, on in c.setMeetingCapture { $0.caption = on } }),
        // Show-only: the area is drawn on screen with the picker, so Moe can
        // say what it is and open the row, never set it. Shown while "What
        // the pictures show" is an area of the screen.
        Entry(id: "meetingCapture.region", title: "The area", page: .meetingCapture,
              under: "What the pictures show",
              does: "The part of the screen meeting pictures take, when they take an area rather than a window or the whole screen.",
              says: ["the screenshots cut off", "it captured the wrong part of the screen", "change the capture area",
                     "the pictures miss the slides", "only capture part of my screen"],
              who: .person,
              kind: .choice([]),
              read: { c in c.config.meetingCapture.region.map { "\(Int($0.width)) × \(Int($0.height)) pixels" } ?? "not chosen" },
              write: { _, _ in false }),
    ]

    // MARK: - Permissions (Memoe's own switches; the macOS grants are not here)

    static let permissions: [Entry] = [
        toggle("screenContext", "Moe sees my screen when I ask", .permissions,
               does: "A picture of your screen goes with your question, so \"what do I do here\" just works. It is never saved.",
               says: ["don't look at my screen", "can it see my screen", "look at what I'm doing",
                      "what's on my screen", "it can't see my screen", "privacy of my screen"],
               who: .person,
               get: { $0.config.screenContext }, set: { $0.setScreenContext($1) }),
        toggle("screenPointerMovesMouse", "Move my mouse to what Moe points at", .permissions,
               does: "When Moe points at something on screen, your mouse moves there. Off, it only draws a ring around it.",
               says: ["stop moving my mouse", "it moved my cursor", "the mouse jumps around",
                      "show me where to click", "don't touch my mouse"],
               who: .person,
               get: { $0.config.screenPointerMovesMouse }, set: { $0.setScreenPointerMovesMouse($1) }),
        toggle("computerUseMayTakeOver", "Let Moe bring a window to the front when it has to", .permissions,
               does: "Moe may switch desktops or bring a hidden window forward to finish something. Off, it leaves your screen alone and tells you what it couldn't reach.",
               says: ["stop switching my windows", "it took over my screen", "it changed my desktop",
                      "windows keep jumping to the front", "it couldn't reach the window", "leave my screen alone"],
               who: .person,
               get: { $0.config.computerUseMayTakeOver }, set: { $0.setComputerUseMayTakeOver($1) }),
        // Shown only when the browser has more than one profile. The list is
        // the person's own profiles, read live on the page, so none are
        // published; whose logins Moe carries is theirs to pick.
        Entry(id: "browseAsProfile", title: "Moe's browser signs in as", page: .permissions, under: "Browse as",
              does: "Which of your browser profiles Moe's own browser carries the logins of. Unset, it follows whichever you used last.",
              says: ["it's signed in as the wrong account", "it used my work account", "it's not logged in",
                     "use my personal profile", "the browser is signed out", "wrong google account"],
              who: .person,
              kind: .choice([]),
              read: { $0.config.browseAsProfile ?? "" },
              write: { _, _ in false }),
    ]

    // MARK: - Running in the background (Speaking up, Reminders, Keeping up)

    static let background: [Entry] = [
        // Speaking up
        toggle("nudges", "Let Moe bring things up on its own", .background,
               does: "The notch glows when something is about to matter, like a meeting, a missed call or a message from someone you know. Reminders you set arrive either way.",
               says: ["stop glowing", "the notch keeps lighting up", "stop interrupting me", "too many alerts",
                      "leave me alone", "stop bugging me", "tell me when something comes up"],
               who: .moe,
               get: { $0.config.nudges }, set: { $0.setNudges($1) }),
        pick("calendarHeadsUpMinutes", "Before something in my calendar", .background,
             under: "Let Moe bring things up on its own",
             does: "How long before a calendar event Moe gives you a heads-up, or not at all.",
             says: ["stop telling me about meetings", "warn me earlier", "too early", "remind me before meetings",
                    "calendar alerts", "I missed my meeting"],
             who: .moe,
             options: [("0", "Don't")] + [2, 5, 10, 15, 30, 60].map { (String($0), "\($0) minutes before") },
             get: { String($0.config.calendarHeadsUpMinutes) },
             set: { c, v in if let m = Int(v) { c.setCalendarHeadsUp(m) } }),
        toggle("quietHours", "Quiet hours, 10 pm to 8 am", .background,
               does: "What Moe brings up overnight waits for the morning before it reaches your phone. Reminders you set still go when you said.",
               says: ["it messaged me at night", "don't bother me at night", "woke me up",
                      "quiet at night", "messages in the middle of the night", "do not disturb"],
               who: .moe,
               get: { $0.config.quietHours }, set: { $0.setQuietHours($1) }),

        // Keeping up
        toggle("backgroundThinking", "Let Moe think on its own, on my AI plan", .background, under: "Keeping up",
               does: "Moe looks over your mail, calendar and follow-ups every half hour and reads back once a day, using your AI plan. Off, none of your plan is spent on it.",
               says: ["it's using up my plan", "costs too much", "stop working in the background",
                      "I'm running out of usage", "my limit ran out", "what is it doing when I'm not using it"],
               who: .person,
               get: { $0.config.backgroundThinking }, set: { $0.setBackgroundThinking($1) }),
        // Consents, recorded by learn/consent.sh, read from `Live` (never on
        // the main thread). The person's own answers: Moe opens the row.
        Entry(id: "learning", title: BackgroundLearning.Words.pass, page: .background, under: "Keeping up",
              does: "Once a day Moe reads back over the things you've allowed and writes down what it works out, like who matters and what you're working on, on this Mac.",
              says: ["stop learning about me", "what does it know about me", "it knows too much",
                     "learn about me", "stop reading my things", "it doesn't know who people are"],
              who: .person, kind: .toggle,
              read: { _ in Live.learning.map(toggleValue) ?? "unknown" },
              write: { _, _ in false }),
        Entry(id: "memorySeeding", title: "Keep what it learns as Moe's memory", page: .background,
              under: "Keeping up › \(BackgroundLearning.Words.pass)",
              does: "What the daily read-back works out is kept in Moe's memory, so it remembers it in every conversation.",
              says: ["don't remember what you learn", "forget what you found", "it remembered something it read",
                     "remember what you learn about me", "it doesn't remember"],
              who: .person, kind: .toggle,
              read: { _ in Live.seeding.map(toggleValue) ?? "unknown" },
              write: { _, _ in false }),
        // The one launchd agent (Launchd.jobsLabel). Off is only less; on
        // asks through the send gate like every other widening.
        Entry(id: "tenMinuteCheck", title: "Look at what's connected every 10 minutes", page: .background,
              under: "Keeping up",
              does: "Every ten minutes Moe looks at your calendar, mail and the rest of what's connected, so it knows what's on today without going to look.",
              says: ["stop checking my mail", "it's always running in the background", "stop polling",
                     "it doesn't know what's on today", "it's out of date", "battery drain"],
              who: .moe, kind: .toggle,
              read: { _ in Live.jobLoaded.map(toggleValue) ?? "unknown" },
              write: { _, v in
                  guard let on = parseToggle(v), Launchd.set(label: Launchd.jobsLabel, enabled: on) else { return false }
                  Live.jobLoaded = on
                  return true
              }),
        // Keeping up › More, in the "Noticed" section (Noticed.swift).
        toggle("situationOffers", "Offer what's ready", .background, under: "Keeping up › More",
               does: "When Moe has work ready for something in your chats, like a draft reply, the notch glows with one line to use it. Off, it's only shown in Settings. Nothing is sent without you confirming.",
               says: ["stop offering drafts", "the notch keeps glowing with offers", "stop suggesting replies",
                      "I don't want drafts", "show me what's ready"],
               who: .moe,
               get: { $0.config.situationOffers }, set: { $0.setSituationOffers($1) }),
        toggle("situationOffersToChats", "Also send offers to my chats when I'm away", .background,
               under: "Keeping up › More",
               does: "When you're away from the Mac, those offers also go to the chats you get reminders in, with the draft written out.",
               says: ["stop messaging me drafts", "don't send offers to my phone", "too many messages on Telegram",
                      "send it to my phone when I'm away", "it texts me suggestions"],
               who: .person,
               get: { $0.config.situationOffersToChats }, set: { $0.setSituationOffersToChats($1) }),
    ]

    // MARK: - Privacy

    /// Nothing yet. This build's page (LocalPrivacyPane) has only "Erase
    /// Memoe from this Mac", an action; the official build's Privacy page
    /// is not part of this source tree.
    static let privacy: [Entry] = []
}
