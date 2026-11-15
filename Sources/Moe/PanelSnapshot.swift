#if DEBUG
import AppKit
import MoeBrain
import MoeIsland
import MoeMeeting
import SwiftUI

/// `Moe --panel-snapshot <dir>` — docs/PANEL-FINDINGS.md §9.
///
/// The panel had been called ugly twice, and both times it was written
/// **without anyone seeing it**: running Moe opens a microphone and needs a
/// real meeting, so "does this look right?" was an expensive enough question
/// that it never got asked. This makes it a cheap one.
///
/// `ImageRenderer` draws *the same views the app draws* — `IslandView`, at the
/// real point sizes `NotchIsland` gives it, hanging off a stand-in notch, over
/// a stand-in video call. The call matters: judging a dark panel against a
/// white page is how you get one that vanishes over a face.
///
/// **Nothing of the user's is touched.** No microphone, no meeting, no brain,
/// no window. `MOE_HOME` is repointed at a scratch directory before `Config`
/// is first read, and `hermesKey` is filled in so nothing goes looking in
/// `~/.hermes/.env`. The Conductor is constructed and posed (see
/// `Conductor.SnapshotState`) and never started.
///
/// Two accommodations, both `ImageRenderer` facts rather than design opinions,
/// both in IslandSnapshotSeam.swift: a `TextField` rasterises as a blank hole,
/// so a snapshot draws its own text in the same box; and a macOS `ScrollView`
/// rasterises empty, so a snapshot lays the same rows over a `Color.clear`
/// which claims height the same way the real one does.
@MainActor
enum PanelSnapshot {

    // MARK: - The stand-in Mac

    /// A 14-inch MacBook Pro's cutout, near enough: the island's whole layout
    /// hangs off `notchSize`, so it has to be a plausible one.
    static let notch = CGSize(width: 200, height: 32)
    /// The screen the shots are taken on. Wide enough that the 604 pt window
    /// sits in a real context rather than filling the frame.
    static let screen = CGSize(width: 1000, height: 620)

    // MARK: - Entry

    /// - Parameter only: a name prefix; when given, only the shots whose
    ///   names start with it are drawn (`i` is the folded island's states).
    static func run(_ directory: String, only: String? = nil) -> Int32 {
        // Before anything reads `Config.homeDir`, which is a lazy `static let`:
        // every path this tool touches goes to a scratch directory.
        let scratch = (directory as NSString).appendingPathComponent(".moe-home")
        setenv("MOE_HOME", scratch, 1)
        setenv("HERMES_HOME", scratch, 1)

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot write to \(directory): \(error)\n".utf8))
            return 1
        }

        // AppKit's text stack wants an application object. This creates one;
        // it starts no run loop, opens no window and activates nothing.
        _ = NSApplication.shared

        var config = Config()
        // So `HermesKey.resolve` never reads the user's ~/.hermes/.env.
        config.hermesKey = "panel-snapshot"
        config.dictationContactsNames = false
        config.wakeWordEnabled = false
        let conductor = Conductor(config: config)
        // Only ever asked for `snapshotContentSize`; it builds no panel,
        // because nothing here calls `show`, `reveal` or `apply`.
        let island = NotchIsland(conductor: conductor)

        var written = 0
        var failed = 0
        for shot in shots where only.map({ shot.name.hasPrefix($0) }) ?? true {
            conductor.pose(shot.state)
            let content: CGSize
            let view: AnyView
            var canvas = screen
            if let size = shot.window {
                content = size
                canvas = CGSize(width: max(screen.width, size.width + 260), height: max(screen.height, size.height + 120))
                view = AnyView(floatingFrame(shot: shot, size: size, canvas: canvas, conductor: conductor))
            } else {
                content = island.snapshotContentSize(for: shot.presentation, notch: shot.notch,
                                                     accessibility: shot.accessibility,
                                                     trayOpen: shot.trayOpen)
                view = AnyView(frame(shot: shot, content: content, conductor: conductor))
            }
            let path = (directory as NSString).appendingPathComponent("\(shot.name).png")
            if write(view, to: path, appearance: shot.light ? .aqua : .darkAqua, canvas: canvas) {
                written += 1
                print("\(shot.name).png  \(shot.presentation)  \(Int(content.width))×\(Int(content.height))pt  — \(shot.note)")
            } else {
                failed += 1
                FileHandle.standardError.write(Data("could not render \(shot.name)\n".utf8))
            }
        }

        print("\n\(written) written to \(directory)\(failed == 0 ? "" : ", \(failed) failed")")
        return failed == 0 ? 0 : 1
    }

    // MARK: - One shot

    struct Shot {
        let name: String
        let note: String
        var presentation: NotchIsland.Presentation = .expanded
        var light = false
        /// Off for the control shot that shows *why* §9's two accommodations
        /// exist: with it off the field and the transcript are blank.
        var accommodations = true
        /// The talk-key row, when the shot poses Accessibility as off.
        var accessibility: String?
        /// The dropdown's ⋯ tray slid open.
        var trayOpen = false
        /// The Mac it is taken on. Most shots use the stand-in; the machine
        /// shots (30–) take each real cutout in turn.
        var notch: CGSize = PanelSnapshot.notch
        /// A floating camera capsule inside `notch` (which is then only the
        /// box macOS reports). Nil is every Mac before it.
        var capsule: NotchGeometry.CapsuleCutout?
        /// Trace the hardware capsule in magenta over the shot, so whether
        /// the island sits on it can be seen: black on black shows nothing.
        var outlineHardware = false
        /// macOS's own microphone indicator beside a capsule
        /// (`NotchGeometry.SystemIndicator`), drawn over the island because
        /// that is where the system draws it.
        var system: SystemPose = .auto
        /// The chat out of the notch, in its window at this size
        /// (`FloatingChatWindow`). Nil is the notch.
        var window: CGSize?
        var state: Conductor.SnapshotState
    }

    enum SystemPose {
        /// The pill whenever the posed state has Memoe's own microphone
        /// open, nothing otherwise: the worst case for every such state.
        case auto
        /// No app has the microphone.
        case none
        /// The microphone is open and the indicator is at rest: its dot.
        case dot
        /// The microphone has just opened, or the pointer is near: the pill.
        case pill
    }

    /// The island in its window, over the stand-in call, on the stand-in
    /// screen. The window geometry is `NotchIsland.windowFrame`'s: 460 pt of
    /// panel plus 120 pt of margin either side (the folded island's ears
    /// reach into it), pinned to the top edge.
    private static func frame(shot: Shot, content: CGSize, conductor: Conductor) -> some View {
        let windowWidth: CGFloat = 460 + 120 * 2
        let windowHeight: CGFloat = shot.notch.height + 420 + 120
        let system: SystemPose = shot.capsule == nil ? .none
            : shot.system == .auto ? (IslandView.usesMicrophone(conductor) ? .pill : .none)
            : shot.system

        return ZStack(alignment: .top) {
            // A Mac without a notch still has a menu bar: 25 pt, drawn so the
            // panel can be seen covering it.
            CallBackdrop(light: shot.light, menuBar: shot.notch.height > 0 ? shot.notch.height : 25)
            // The notch: a hole in the glass, drawn as the black it is.
            if shot.capsule == nil { NotchCutout(size: shot.notch) }
            IslandView(conductor: conductor,
                       presentation: shot.presentation,
                       notchSize: shot.notch,
                       capsule: shot.capsule,
                       micOpenSomewhere: system != .none,
                       contentSize: content,
                       draft: draft(for: shot),
                       takesFocus: false,
                       onTap: {}, onHover: { _ in }, onClose: {})
                .frame(width: windowWidth, height: windowHeight, alignment: .top)
            // A floating capsule is glass, not pixels: whatever the island
            // draws there is not seen, so it goes on top of everything.
            if let capsule = shot.capsule {
                CapsuleHardware(capsule: capsule, outlined: shot.outlineHardware)
                if system != .none {
                    SystemMicIndicator(indicator: capsule.indicator, pill: system == .pill)
                }
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .top)
        .environment(\.islandSnapshot, shot.accommodations)
        .environment(\.islandPosedAccessibility, shot.accessibility)
        .environment(\.islandPosedTrayOpen, shot.trayOpen)
        .environment(\.islandPosedSnoozeOpen, shot.name.contains("snooze") ? "sample-0" : nil)
        .environment(\.colorScheme, shot.light ? .light : .dark)
    }

    /// The ask field's contents for a shot. One state is deliberately
    /// half-typed: the reading clock treats a draft as "in use" (§7), so what
    /// that looks like is worth a picture.
    private static func draft(for shot: Shot) -> IslandDraft {
        let d = IslandDraft()
        if shot.name.contains("half-typed") { d.text = "what did she say the deadline was" }
        d.trayOpen = shot.trayOpen
        return d
    }

    // MARK: - Writing

    private static func write(_ view: some View, to path: String,
                              appearance: NSAppearance.Name, canvas: CGSize = screen) -> Bool {
        // The island is drawn by SwiftUI, but the AppKit controls inside it
        // (`Toggle(.checkbox)` on the notes panel) follow the *app's*
        // appearance, not the environment's — which is exactly §8's
        // complaint, so the light shot has to set it for real.
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: canvas.width, height: canvas.height)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - The states worth covering (§9)

    private static var shots: [Shot] {
        [
            Shot(name: "01-tab-recording",
                 note: "the tab: recording, nothing found yet — the strip is deliberately invisible",
                 presentation: .collapsed,
                 state: recording()),

            Shot(name: "02-tab-action-items",
                 note: "the tab: two action items spotted, the only time it says anything",
                 presentation: .collapsed,
                 state: recording(actions: 2)),

            Shot(name: "03-recording-nothing-yet",
                 note: "clicked open in the first thirty seconds: no transcript, no chat",
                 state: recording()),

            Shot(name: "04-recording-transcript",
                 note: "recording with a transcript running",
                 state: recording(timeline: sampleTimeline)),

            Shot(name: "05-reply-just-arrived",
                 note: "the state the panel exists for: a question asked mid-call and answered",
                 state: recording(timeline: sampleTimeline, turns: sampleTurns)),

            Shot(name: "06-reply-half-typed",
                 note: "the same, with a half-typed question — what the reading clock calls in use",
                 state: recording(timeline: sampleTimeline, turns: sampleTurns)),

            Shot(name: "07-notice",
                 note: "a notice bar: your name came up",
                 state: recording(timeline: sampleTimeline, mention: "Dan asked whether you had the numbers")),

            Shot(name: "08-paused",
                 note: "off the record, beside the three controls that used to truncate",
                 state: recording(timeline: sampleTimeline, paused: true)),

            Shot(name: "09-writing-notes",
                 note: "stop pressed; the notes are being written",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.meeting = .stopping
                     s.meetingTimeline = sampleTimeline
                     s.meetingStatus = "Writing your notes…"
                     return s
                 }()),

            Shot(name: "10-notes-ready",
                 note: "the summary, the decisions, the tickable action items",
                 state: notesReady()),

            Shot(name: "11-hover-strip",
                 note: "the hover peek, no meeting: the conversation panel at 420 pt",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = [Turn(role: .you, text: "remind me what the rate limit is"),
                                Turn(role: .moe, text: "Sixty requests a minute per key, and the burst allowance is another twenty on top.")]
                     return s
                 }()),

            Shot(name: "12-light-mode",
                 note: "notes ready with the Mac set to light — §8's checkbox and the panel's own dark",
                 light: true,
                 state: notesReady()),

            Shot(name: "13-light-mode-recording",
                 note: "the reply state in light mode, over a bright call",
                 light: true,
                 state: recording(timeline: sampleTimeline, turns: sampleTurns)),

            Shot(name: "14-notes-short",
                 note: "short notes, so the tickable action items are in frame at all",
                 state: notesReady(short: true)),

            Shot(name: "15-notes-short-light",
                 note: "the same in light mode — §8's AppKit checkbox on a black panel",
                 light: true,
                 state: notesReady(short: true)),

            Shot(name: "16-notes-overfull",
                 note: "more notes than the tallest panel holds — the fade and the words that say so",
                 state: notesReady(long: true)),

            // The amber pulse, opened. It is not a meeting state, but it is
            // the one card the panel shows that the person did not ask for,
            // and it sits UNDER the panel's own ✕ and ⌃ — which is how it
            // came to have a second ✕ four points from the first.
            Shot(name: "17-nudge-waiting",
                 note: "a reminder waiting on the amber pulse, idle — one way out, one action",
                 state: nudge()),

            // The owner's screenshot, 2026-09-25: a three-line reminder over a
            // long conversation. The conversation was not capped with the
            // panel, so the card went up under the notch and the field fell
            // out of the bottom. The conversation gives way now.
            Shot(name: "17b-nudge-over-a-long-conversation",
                 note: "a long reminder over a long conversation: the card and the field stay inside, the chat scrolls",
                 state: nudge(long: true, turns: [
                    Turn(role: .you, text: "go research press, blogs and podcasts for the launch and set up many many things. things that don't need me do yourself and things that do send me a message on telegram"),
                    Turn(role: .moe, text: "Kicking off a long research-and-draft run now. Since Telegram isn't connected yet on this Mac, I'll message you on WhatsApp instead when there's something ready for your yes or when it wraps.\n\nSet: it'll run in about a minute, spend real time researching more press, blog and podcast targets, draft everything in your voice without sending anything, and text you on WhatsApp with a short list of what's ready for your yes plus where to find the full drafts.")])),

            // The owner's screenshot, 2026-09-25: a drafted email arrived as a
            // column of ">" down the left edge. A quote is a card now.
            Shot(name: "26b-email-draft",
                 note: "an answer holding a drafted email as a markdown quote: a card, not '>' lines",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = [Turn(role: .you, text: "draft the pitch to the indie mac blog"),
                                Turn(role: .moe, text: "Here it is, ready to check:\n\n> **To:** reviewer@example.com\n> **Subject:** Memoe, a free Mac assistant\n>\n> Hi,\n>\n> I built Memoe and I think your audience would want to know about it. It lives in the notch, reads your mail and calendar, and works the Mac itself.\n>\n> Thanks,\n> Jordan\n\nSend it, or change anything first?")]
                     return s
                 }()),

            Shot(name: "18-nudge-while-thinking",
                 note: "the same while Moe is working: BOTH chrome buttons are up, and the card must clear them",
                 state: nudge(thinking: true)),

            // The owner's screenshot, 2026-09-14: a two-line reminder and the
            // talk-key row on the hover panel, and the ask field hanging off
            // the bottom of it.
            Shot(name: "19-nudge-and-accessibility-hover",
                 note: "hover panel: a two-line reminder above the talk-key row — the field must stay inside",
                 presentation: .peek,
                 accessibility: staleAccessibility,
                 state: nudge(long: true, turns: [])),

            Shot(name: "20-nudge-and-accessibility-open",
                 note: "the same, opened, with a conversation underneath the card",
                 accessibility: staleAccessibility,
                 state: nudge(long: true)),

            Shot(name: "21-accessibility-alone",
                 note: "the talk-key row with nothing above it: it must clear the ✕ and ⌃",
                 presentation: .peek,
                 accessibility: staleAccessibility,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = [Turn(role: .you, text: "remind me what the rate limit is"),
                                Turn(role: .moe, text: "Sixty requests a minute per key, and the burst allowance is another twenty on top.")]
                     return s
                 }()),

            // "Work silently" (2026-09-16): hovering a spoken turn that is
            // working — a browser job, several steps in.
            Shot(name: "22-working-hover",
                 note: "hover while a spoken turn works: one row — the step, the clock, quiet, Stop (WorkingRow)",
                 presentation: .peek,
                 state: working(silently: false)),

            Shot(name: "23-working-silently",
                 note: "the same after pressing quiet: the speaker icon flips",
                 presentation: .peek,
                 state: working(silently: true)),

            Shot(name: "24-working-between-steps",
                 note: "nothing running, the model writing: the row says Thinking",
                 presentation: .peek,
                 state: {
                     var s = working(silently: false)
                     s.workingStep = nil
                     s.statusLine = "thinking"
                     return s
                 }()),

            Shot(name: "25-working-with-a-reminder",
                 note: "a reminder held over a job still sits above the row",
                 presentation: .peek,
                 state: {
                     var s = working(silently: false)
                     s.pendingNudge = "Eli’s waiting for your help with Rite Care."
                     s.pendingNudgeWhen = "Earlier, at 8:11 AM"
                     return s
                 }()),

            Shot(name: "26-answered-with-steps",
                 note: "the answer, with what it did folded under it",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     var answer = Turn(role: .moe, text: "Table for two at Nopa, Friday at 7:00 — it’s under your name. Want the confirmation in your calendar?")
                     answer.tools = ["Looking at your calendar", "Reading something on opentable", "Working through the page"]
                     answer.took = 48
                     s.turns = [Turn(role: .you, text: "book me a table for two somewhere near the office on Friday at seven"), answer]
                     return s
                 }()),

            // docs/PROACTIVE-MEMORY.md §3.4: what per-turn learning kept, under
            // the answer it followed, with Undo (owner, 2026-09-24).
            Shot(name: "26b-answered-noted",
                 note: "the answer, and under it what Moe noted from what you said, with Undo",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     var answer = Turn(role: .moe, text: "Got it — I won't send Acme anything until you've checked with Dana.")
                     answer.noted = [NotedFact(claim: "a1b2c3d4e5f6", target: "user",
                                               note: "Dana is your business partner", at: Date()),
                                     NotedFact(claim: "0123456789ab", target: "memory",
                                               note: "Acme delivered 250 of the 700 birds you ordered", at: Date())]
                     s.turns = [Turn(role: .you, text: "hold off on Acme, I need to check with my partner Dana first — they only delivered 250 of the 700"), answer]
                     return s
                 }()),

            // docs/PROACTIVE-MEMORY.md §4.8: an offer — the work is ready.
            Shot(name: "26c-offer",
                 note: "an offer from the situations engine: the line, Use draft, See it, Not now",
                 presentation: .peek,
                 state: {
                     let sits = """
                     {"sit_demo": {"title": "Chicken order payment", "thread_name": "Mordecai", "source": "native/whatsapp",
                      "prepared": {"offer": "x", "options": ["a"], "research": [], "draft": "Hi Mordecai, we agreed the price on Sept 22."}}}
                     """
                     let dir = Paths.home.appendingPathComponent("proactive")
                     try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                     try? Data(sits.utf8).write(to: dir.appendingPathComponent("situations.json"))
                     var s = Conductor.SnapshotState()
                     s.pendingNudge = "Mordecai is trying to reopen the Sept 22 price after you sent $3,453. A reply that holds the deal is ready."
                     s.pendingNudgeHandle = Conductor.NudgeHandle(job: "moe-situations", jobID: "", loops: [], said: "",
                                                                  offer: "sit_demo")
                     return s
                 }()),

            // While your Mac is off (2026-09-25): WhatsApp is not on the
            // cloud computer, and one code would put it there.
            Shot(name: "26d-away-carry",
                 note: "a While-your-Mac-is-off reminder: Don't remind me, Not now, Show me",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.pendingNudge = "Your cloud computer can't reach your WhatsApp while your Mac is off. It takes one code from your phone."
                     s.pendingNudgeHandle = Conductor.NudgeHandle(job: "", jobID: "", loops: [], said: "",
                                                                  awayCarry: "whatsapp")
                     return s
                 }()),

            // docs/FIXABLE-FAILURES.md bugs 10 and 11: mute for the whole
            // conversation, and ▶ ↺ ⋯ on every answer.
            Shot(name: "27-speaking-in-conversation",
                 note: "Moe speaking its answer mid-conversation: ⏸ ↺ on the answer, and mute on the speaking row",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .speaking
                     s.inConversation = true
                     var answer = Turn(role: .moe, text: "The cheapest Hanoi to Kunming on the 30th is VietJet at $142, leaving 10:05 and landing 12:15.")
                     answer.tools = ["Opening Google Flights", "Working through the page"]
                     answer.took = 41
                     s.turns = [Turn(role: .moe, text: "Morning. Hanoi's 27° and clear."),
                                Turn(role: .you, text: "find me a flight from Hanoi to Kunming around October 30th"),
                                answer]
                     s.voicedTurn = 2
                     return s
                 }()),

            // The owner's screenshot, 2026-09-24: speaking while muted, the
            // red pill left "speaking" no width and it ran one letter a line.
            Shot(name: "27b-speaking-muted",
                 note: "Moe speaking while muted: ⏸ ↺ and the red pill on one line, the word 'speaking' gives way",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .speaking
                     s.inConversation = true
                     s.micMuted = true
                     var answer = Turn(role: .moe, text: "The cheapest Hanoi to Kunming on the 30th is VietJet at $142, leaving 10:05 and landing 12:15.")
                     answer.tools = ["Opening Google Flights"]
                     answer.took = 8
                     s.turns = [Turn(role: .you, text: "find me a flight from Hanoi to Kunming around October 30th"),
                                answer]
                     s.voicedTurn = 1
                     return s
                 }()),

            // The dropdown's ⋯ opened (Dropdown / IslandTray, 2026-09-24):
            // the icons in their fixed order, mic first, the main action last.
            Shot(name: "27c-speaking-tray-open",
                 note: "speaking, ⋯ opened: mic, start over, pause as small icons",
                 trayOpen: true,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .speaking
                     s.inConversation = true
                     s.turns = [Turn(role: .you, text: "book me a table for two near the office, Friday at seven"),
                                Turn(role: .moe, text: "Nopa, Friday at 7:00, under your name.")]
                     s.voicedTurn = 1
                     return s
                 }()),
            Shot(name: "27d-working-tray-open",
                 note: "working, ⋯ opened: mic and stop",
                 presentation: .peek,
                 trayOpen: true,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .thinking
                     s.working = true
                     s.acting = true
                     s.inConversation = true
                     s.turns = [Turn(role: .you, text: "book me a table for two near the office, Friday at seven")]
                     return s
                 }()),

            Shot(name: "28-follow-up-muted",
                 note: "the follow-up window after the answer, muted: the conversation row keeps the unmute",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .listening
                     s.inConversation = true
                     s.micMuted = true
                     s.turns = [Turn(role: .you, text: "find me a flight from Hanoi to Kunming around October 30th"),
                                Turn(role: .moe, text: "The cheapest on the 30th is VietJet at $142, leaving 10:05. Want me to hold it?")]
                     return s
                 }()),

            // Sticky mute (the owner, 2026-09-24): after the answer the island
            // folds, and muted must still be unmistakable — the red tab.
            Shot(name: "28b-muted-collapsed",
                 note: "muted, island folded after the answer: the red 'Muted' tab under the notch",
                 presentation: .collapsed,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .listening
                     s.inConversation = true
                     s.micMuted = true
                     return s
                 }()),

            // "When muted it still tracks my voice" (the owner, 2026-09-25):
            // the same muted states with the microphone loud, which must not
            // move the halo or anything else on the island.
            Shot(name: "28d-muted-collapsed-loud",
                 note: "muted and folded, talking loudly: the halo stays still and red",
                 presentation: .collapsed,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .listening
                     s.inConversation = true
                     s.micMuted = true
                     s.level = 0.95
                     return s
                 }()),
            Shot(name: "28e-muted-open-loud",
                 note: "muted, the panel opened by hand, talking loudly: still halo, the Unmute pill",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .listening
                     s.inConversation = true
                     s.micMuted = true
                     s.level = 0.95
                     s.turns = [Turn(role: .you, text: "find me a flight from Hanoi to Kunming around October 30th"),
                                Turn(role: .moe, text: "The cheapest on the 30th is VietJet at $142, leaving 10:05. Want me to hold it?")]
                     return s
                 }()),
            Shot(name: "28f-muted-open-tray-loud",
                 note: "muted, ⋯ opened, talking loudly",
                 trayOpen: true,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .listening
                     s.inConversation = true
                     s.micMuted = true
                     s.level = 0.95
                     s.turns = [Turn(role: .you, text: "find me a flight from Hanoi to Kunming around October 30th"),
                                Turn(role: .moe, text: "The cheapest on the 30th is VietJet at $142, leaving 10:05. Want me to hold it?")]
                     return s
                 }()),
            Shot(name: "28g-listening-open-loud",
                 note: "NOT muted, talking loudly: the halo follows the voice (control)",
                 presentation: .collapsed,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .listening
                     s.inConversation = true
                     s.level = 0.95
                     return s
                 }()),

            Shot(name: "28c-muted-working",
                 note: "muted while Moe works: the working row carries the red pill",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.mode = .thinking
                     s.working = true
                     s.acting = true
                     s.inConversation = true
                     s.micMuted = true
                     s.turns = [Turn(role: .you, text: "put the TinyLaunch listing on the free plan and schedule it")]
                     return s
                 }()),

            // docs/FIXABLE-FAILURES.md slice 3: a tool failed for a reason the
            // person can fix, and said which. Ticket #8's own failure first.
            Shot(name: "29a-fix-chrome-data",
                 note: "Fix card: Memoe can't read Chrome's data — Open Settings (Full Disk Access) or Dismiss",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = [Turn(role: .you, text: "find me a flight from Hanoi to Kunming around October 30th"),
                                Turn(role: .moe, text: "I can't open Chrome's data yet — macOS is keeping me out of it.")]
                     s.fixes = [ToolFix(code: .tccAppData, owner: .app, pane: "Privacy_AllFiles",
                                        subject: "Google Chrome", retry: true)]
                     return s
                 }()),

            Shot(name: "29b-fix-driver-screen",
                 note: "Fix card for CuaDriver's own row: it names CuaDriver, not Memoe",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = [Turn(role: .you, text: "what's on my screen in Keynote?"),
                                Turn(role: .moe, text: "I can't see your screen right now.")]
                     s.fixes = [ToolFix(code: .tccDriverScreen, owner: .driver, pane: "Privacy_ScreenCapture",
                                        subject: "CuaDriver", retry: true, restart: "driver")]
                     return s
                 }()),

            Shot(name: "29c-fix-two-causes",
                 note: "two causes in one turn: Automation for Notes, and a connection to sign in again",
                 presentation: .peek,
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = [Turn(role: .you, text: "put my Linear tickets in a note"),
                                Turn(role: .moe, text: "I couldn't reach Linear or Notes.")]
                     s.fixes = [ToolFix(code: .tccAutomation, owner: .app, pane: "Privacy_Automation",
                                        subject: "Notes", retry: true, consent: "denied"),
                                ToolFix(code: .mcpNeedsReauth, subject: "Linear", retry: true)]
                     return s
                 }()),

        ] + inboxShots + machineShots + islandShots + capsuleShots + floatingShots + chatStateShots + [
            Shot(name: "99-control-no-accommodations",
                 note: "the same shot as 05 with §9's two accommodations off — this is why they exist",
                 accommodations: false,
                 state: recording(timeline: sampleTimeline, turns: sampleTurns)),
        ]
    }

    // MARK: - The folded island: its ears (2026-10-15, `IslandEars`)

    /// Every state the folded island can be in, on the stand-in notch and on
    /// a Mac without one. `Moe --panel-snapshot <dir> i` draws just these.
    private static var islandShots: [Shot] {
        func pose(_ f: (inout Conductor.SnapshotState) -> Void) -> Conductor.SnapshotState {
            var s = Conductor.SnapshotState()
            f(&s)
            return s
        }
        let states: [(String, String, Conductor.SnapshotState)] = [
            ("idle", "one dim dot in a small right ear", pose { _ in }),
            ("listening", "white level bars in the left ear, moved by your voice",
             pose { $0.mode = .listening; $0.inConversation = true; $0.level = 0.7 }),
            ("muted", "\"Muted\" in the left ear — no red",
             pose { $0.mode = .listening; $0.inConversation = true; $0.micMuted = true; $0.level = 0.9 }),
            ("thinking", "the crisp white running light; the ears tuck away",
             pose { $0.mode = .thinking; $0.working = true; $0.acting = true }),
            ("speaking", "the bars, moving gently",
             pose { $0.mode = .speaking; $0.inConversation = true }),
            ("paused", "a held reply: \"Paused\"",
             pose { $0.mode = .speaking; $0.inConversation = true; $0.replyPaused = true }),
            ("notice", "something arrived: the right ear widens to hold its line",
             inbox(peek: true)),
            ("waiting", "something waiting: the dot at full white, still",
             inbox()),
            ("driving", "Moe has the screen: \"Using Safari · Stop\", and the light runs",
             pose { $0.mode = .thinking; $0.acting = true; $0.working = true; $0.drivingApp = "Safari" }),
            ("dictation", "dictating: a text cursor and the bars",
             pose { $0.dictation = .listening; $0.level = 0.6 }),
            ("meeting", "a meeting recorded: the one red dot, and \"Recording\"",
             recording()),
            ("meeting-paused", "off the record: the dot greys",
             recording(paused: true)),
            ("meeting-actions", "Recording on the left, the action items on the right",
             recording(actions: 2)),
            ("meeting-done", "notes written",
             pose { $0.meeting = .done(url: URL(fileURLWithPath: "/tmp/notes")) }),
        ]
        let notched = states.enumerated().map { i, st in
            Shot(name: String(format: "i%02d-%@", i + 1, st.0), note: st.1,
                 presentation: .collapsed, state: st.2)
        }
        let bare = ["idle", "notice", "thinking", "muted"].compactMap { name in
            states.first { $0.0 == name }.map { st in
                Shot(name: "i5-no-notch-\(name)", note: "no notch: \(st.1), off the stand-in tab",
                     presentation: .collapsed, notch: .zero, state: st.2)
            }
        }
        let open = Shot(name: "i60-open-speaking",
                        note: "opened: the panel with its drop shadow and no light behind it",
                        state: pose { s in
                            s.mode = .speaking; s.inConversation = true
                            s.turns = [Turn(role: .you, text: "What's on this afternoon?"),
                                       Turn(role: .moe, text: "Two things: the design review at 2, and a call with Dana at 4:30.")]
                            s.voicedTurn = 1
                        })
        return notched + bare + [open]
    }

    // MARK: - Every conversation state (`ChatPoses`, 2026-11-13)

    /// The notch card, opened, and the floating window, in every state
    /// `ChatPoses` lists: the same poses the Chat page is photographed in
    /// (`--settings-snapshot … main-chat-window`). `x` draws just these.
    private static var chatStateShots: [Shot] {
        ChatPoses.all.flatMap { pose in
            [Shot(name: "x-\(pose.name)", note: "notch card: \(pose.note)", state: pose.state),
             Shot(name: "xw-\(pose.name)", note: "floating window: \(pose.note)",
                  window: FloatingChatFrame.initialSize, state: pose.state)]
        }
    }

    // MARK: - The chat out of the notch (`FloatingChatWindow`, 2026-11-13)

    /// The notch card with its pop-out, on each kind of Mac; then the window
    /// itself, small, default and large, light and dark, in the states that
    /// change what is in it. `Moe --panel-snapshot <dir> f` draws just these.
    private static var floatingShots: [Shot] {
        let conversation = [
            Turn(role: .you, text: "What's on today?"),
            Turn(role: .moe, text: "Agent onboarding at 11:30, the daily call at 1, and a 3 o'clock. Two cancellation reminders are overdue."),
            Turn(role: .you, text: "Move the 3 o'clock to tomorrow and tell them why"),
            Turn(role: .moe, text: "Done. I moved it to 3 tomorrow and sent this:\n\n> Hi Sam, something came up this afternoon. I've moved us to the same time tomorrow; I hope that still works."),
        ]
        func pose(_ f: (inout Conductor.SnapshotState) -> Void) -> Conductor.SnapshotState {
            var s = inbox(turns: conversation)
            f(&s)
            return s
        }
        let small = CGSize(width: 320, height: 300)
        let standard = FloatingChatFrame.initialSize
        let large = CGSize(width: 760, height: 820)
        return [
            Shot(name: "f01-notch-card-pop-out",
                 note: "the notch card on a 14-inch: inbox, new conversation, then the pop-out beside the fold",
                 notch: CGSize(width: 185, height: 32), state: inbox()),
            Shot(name: "f02-capsule-card-pop-out",
                 note: "the same card on a floating capsule (the owner's Mac)",
                 notch: capsuleBox, capsule: capsule, state: inbox()),
            Shot(name: "f03-pro-16-card-pop-out",
                 note: "a 16-inch's narrow band: the pop-out stays, a new conversation gives way",
                 notch: CGSize(width: 220, height: 38), state: inbox()),
            Shot(name: "f04-no-notch-card-pop-out",
                 note: "no notch: the header has a row of its own",
                 notch: .zero, state: inbox()),
            Shot(name: "f05-notch-card-working",
                 note: "mid-job: the clock, then the pop-out",
                 state: working(silently: false)),
            Shot(name: "f06-notch-at-rest-while-out",
                 note: "the chat is out: the notch at rest draws nothing past the camera",
                 presentation: .collapsed, state: inbox()),
            Shot(name: "f10-window-default-dark",
                 note: "the window, first time out: 420 × 540, a dark desktop",
                 window: standard, state: pose { _ in }),
            Shot(name: "f11-window-default-light",
                 note: "the same over a light desktop: the card is the notch card's black in both",
                 light: true, window: standard, state: pose { _ in }),
            Shot(name: "f12-window-small-dark",
                 note: "small, 320 × 300: the conversation scrolls, the field and the tray stay",
                 window: small, state: pose { _ in }),
            Shot(name: "f13-window-small-light",
                 note: "the smallest over a light desktop",
                 light: true, window: small, state: pose { _ in }),
            Shot(name: "f14-window-large-dark",
                 note: "widened to 760 × 820: bubbles widen with it",
                 window: large, state: pose { _ in }),
            Shot(name: "f15-window-large-light",
                 note: "large, light desktop",
                 light: true, window: large, state: pose { _ in }),
            Shot(name: "f16-window-working",
                 note: "Moe working: Working and the clock in the header, the step, Stop in the tray",
                 window: standard, state: working(silently: false)),
            Shot(name: "f17-window-speaking-tray-open",
                 note: "speaking, the ⋯ open: the same tray as the notch card",
                 trayOpen: true, window: standard,
                 state: pose { $0.mode = .speaking; $0.inConversation = true; $0.voicedTurn = 3 }),
            Shot(name: "f18-window-muted",
                 note: "muted: the Unmute pill stays in view",
                 window: standard,
                 state: pose { $0.mode = .listening; $0.inConversation = true; $0.micMuted = true }),
            Shot(name: "f19-window-inbox",
                 note: "the inbox in the window",
                 window: standard, state: inbox(open: true)),
            Shot(name: "f20-window-cold-start",
                 note: "nothing said yet: the greeting and the field",
                 window: standard, state: Conductor.SnapshotState()),
            Shot(name: "f21-window-half-typed",
                 note: "a half-typed question: the same draft the notch holds",
                 window: small, state: pose { _ in }),
            Shot(name: "f22-window-long-answer",
                 note: "a long answer: scrolls inside the window",
                 window: standard, state: inbox(turns: longAnswer)),
        ]
    }

    /// The chat window over a stand-in desktop, with the folded notch at
    /// the top — which, while the chat is out, is only ever the notch.
    /// The window's own corners and shadow are the system's in the app;
    /// they are drawn here so the picture reads as a window.
    private static func floatingFrame(shot: Shot, size: CGSize, canvas: CGSize,
                                      conductor: Conductor) -> some View {
        var chrome = FloatingChrome()
        chrome.keepOnTop = true
        let window = IslandView(conductor: conductor, presentation: .expanded, notchSize: .zero,
                                contentSize: size, draft: draft(for: shot), takesFocus: false,
                                onTap: {}, onHover: { _ in }, floating: chrome)
        return ZStack(alignment: .topTrailing) {
            CallBackdrop(light: shot.light, menuBar: notch.height)
            NotchCutout(size: notch)
                .frame(maxWidth: .infinity, alignment: .center)
            window
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .padding(.top, notch.height + 24)
                .padding(.trailing, 40)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .environment(\.islandSnapshot, shot.accommodations)
        .environment(\.islandPosedTrayOpen, shot.trayOpen)
        .environment(\.colorScheme, shot.light ? .light : .dark)
    }

    // MARK: - The floating capsule (2026-11-12, `CapsuleIsland`)

    /// What macOS reports for the owner's MacBook Pro (Mac17,13, 1512 × 993
    /// pt, measured 2026-11-12): `safeAreaInsets.top` 40 and two 726.5 pt
    /// strips, so a 59 × 40 pt box. The capsule inside it is 58 × 31 pt,
    /// 8.5 pt down — `NotchGeometry.measuredCapsules`.
    static let capsuleBox = CGSize(width: 59, height: 40)
    static let capsule = NotchGeometry.capsule(reported: capsuleBox, model: "Mac17,13")

    /// The island on a floating capsule: every folded state, the open card
    /// with several things in it, and the four states of the approved design
    /// again with the hardware traced. `Moe --panel-snapshot <dir> c` draws
    /// just these.
    private static var capsuleShots: [Shot] {
        func pose(_ f: (inout Conductor.SnapshotState) -> Void) -> Conductor.SnapshotState {
            var s = Conductor.SnapshotState()
            f(&s)
            return s
        }
        let conversation = [Turn(role: .you, text: "What's on today?"),
                            Turn(role: .moe, text: "Agent onboarding at 11:30, the daily call at 1, and a 3 o'clock. Two cancellation reminders are overdue.")]
        let folded: [(String, String, Conductor.SnapshotState)] = [
            ("rest", "at rest: the hardware's capsule and nothing else; the strip above stays lit", pose { _ in }),
            ("listening", "listening: the capsule grows sideways, bars left of the camera, the dot right",
             pose { $0.mode = .listening; $0.inConversation = true; $0.level = 0.7 }),
            ("working", "working: the ring left of the camera, the word right",
             pose { $0.mode = .thinking; $0.working = true; $0.acting = true }),
            ("speaking", "speaking: the bars, and the dot",
             pose { $0.mode = .speaking; $0.inConversation = true }),
            ("muted", "muted: the word left of the camera",
             pose { $0.mode = .listening; $0.inConversation = true; $0.micMuted = true; $0.level = 0.9 }),
            ("notice", "something arrived: the capsule grows right to hold its line", inbox(peek: true)),
            ("waiting", "something waiting, at rest: the hardware's capsule and nothing else (the card says it)", inbox()),
            ("driving", "Moe has the screen: the ring left, \"Using Safari · Stop\" right",
             pose { $0.mode = .thinking; $0.acting = true; $0.working = true; $0.drivingApp = "Safari" }),
            ("dictation", "dictating: a text cursor and the bars",
             pose { $0.dictation = .listening; $0.level = 0.6 }),
            ("meeting-actions", "Recording left of the camera, the action items right", recording(actions: 2)),
            ("between-turns", "a conversation open between turns, nobody speaking: rest, nothing out",
             pose { $0.mode = .listening; $0.inConversation = true; $0.betweenTurns = true }),
        ]
        let open: [(String, String, NotchIsland.Presentation, Conductor.SnapshotState)] = [
            ("open", "opened: a floating card from the capsule's top edge, the camera in its top band",
             .expanded, pose { $0.turns = conversation }),
            ("open-hover", "the hover panel, the same card at 420 pt", .peek, pose { $0.turns = conversation }),
            ("open-working", "opened while Moe works: the word and the clock beside the camera",
             .expanded, working(silently: false)),
            ("open-inbox", "the inbox in the card", .expanded, inbox(open: true)),
            ("open-meeting", "a meeting with a transcript and a reply", .expanded,
             recording(timeline: sampleTimeline, turns: sampleTurns)),
            ("open-notes", "notes ready", .expanded, notesReady(short: true)),
            ("open-dictation", "the dictation strip on hover", .peek,
             pose { $0.dictation = .listening; $0.level = 0.6 }),
        ]
        var shots: [Shot] = []
        for (i, st) in folded.enumerated() {
            shots.append(Shot(name: String(format: "c%02d-capsule-%@", i + 1, st.0), note: st.1,
                              presentation: .collapsed, notch: capsuleBox, capsule: capsule, state: st.2))
        }
        for (i, st) in open.enumerated() {
            shots.append(Shot(name: String(format: "c%02d-capsule-%@", i + 20, st.0), note: st.1,
                              presentation: st.2, notch: capsuleBox, capsule: capsule, state: st.3))
        }
        // The same over a bright call and a light menu bar.
        shots.append(Shot(name: "c30-capsule-listening-light", note: "listening over a light menu bar",
                          presentation: .collapsed, light: true, notch: capsuleBox, capsule: capsule,
                          state: folded[1].2))
        shots.append(Shot(name: "c31-capsule-open-light", note: "the open card over a light menu bar",
                          light: true, notch: capsuleBox, capsule: capsule, state: open[0].3))
        // The approved design's four states with the hardware traced.
        for (name, presentation, state) in [("rest", NotchIsland.Presentation.collapsed, folded[0].2),
                                            ("listening", .collapsed, folded[1].2),
                                            ("working", .collapsed, folded[2].2),
                                            ("open", .expanded, open[0].3)] {
            shots.append(Shot(name: "c4-capsule-\(name)-outlined",
                              note: "\(name), with the real capsule traced in magenta",
                              presentation: presentation, light: true, notch: capsuleBox, capsule: capsule,
                              outlineHardware: true, state: state))
        }
        // macOS's microphone indicator (found 2026-11-12, the owner's
        // photographs): the states above that have no microphone of
        // Memoe's own, with another app's — or the wake word's — open, the
        // indicator both as its pill and as its resting dot; and the card
        // in the state that was photographed.
        let thinking = pose { $0.mode = .thinking }
        let system: [(String, String, NotchIsland.Presentation, SystemPose, Conductor.SnapshotState)] = [
            ("working-mic-pill", "working with the microphone open: ring and word either side of the system's pill",
             .collapsed, .pill, folded[2].2),
            ("working-mic-dot", "the same with the system's indicator at rest", .collapsed, .dot, folded[2].2),
            ("thinking-mic-pill", "the photographed state: thinking, the pill out", .collapsed, .pill, thinking),
            ("listening-mic-dot", "listening, the indicator at rest", .collapsed, .dot, folded[1].2),
            ("notice-mic-pill", "a notice while the microphone is open", .collapsed, .pill, folded[5].2),
            ("waiting-mic-dot", "something waiting, the wake word listening: nothing out (IMG_0629)", .collapsed, .dot, folded[6].2),
            ("driving-mic-pill", "driving while the microphone is open", .collapsed, .pill, folded[7].2),
            ("rest-mic-pill", "at rest with the pill out: the island adds nothing", .collapsed, .pill, folded[0].2),
            ("rest-mic-dot", "at rest, the wake word listening", .collapsed, .dot, folded[0].2),
            ("open-thinking-mic-pill", "the photographed card: thinking, nothing said yet, the pill out",
             .peek, .pill, thinking),
            ("open-thinking-quiet", "the same with no microphone open", .peek, .none, thinking),
            ("open-working-mic-pill", "opened while Moe works, the pill out", .expanded, .pill, open[2].3),
            ("open-mic-pill", "the open card with the pill out", .expanded, .pill, open[0].3),
            ("open-inbox-mic-dot", "the inbox, the indicator at rest", .expanded, .dot, open[3].3),
            ("open-driving-mic-pill", "a long status word stays on its side of the pill", .peek, .pill,
             pose { $0.mode = .thinking; $0.acting = true; $0.working = true; $0.drivingApp = "Google Chrome Canary" }),
            ("waiting-mic-pill", "something waiting with the pill out: only the system's pill (IMG_0630)",
             .collapsed, .pill, folded[6].2),
            ("between-turns-mic-dot", "between turns, the indicator at rest: nothing out", .collapsed, .dot,
             folded[10].2),
            ("listening-waiting-mic-dot", "somebody speaking with something waiting: bars left, the white dot right",
             .collapsed, .dot, { var s = folded[6].2; s.mode = .listening; s.inConversation = true; s.level = 0.7; return s }()),
        ]
        for (i, st) in system.enumerated() {
            shots.append(Shot(name: String(format: "c%02d-capsule-%@", i + 60, st.0), note: st.1,
                              presentation: st.2, notch: capsuleBox, capsule: capsule, system: st.3, state: st.4))
        }
        // The compact card (`IslandView.trayInHeader`): working with nothing
        // in the conversation. The ⋯ is in the band; its controls take a
        // row only while out. Then the same state on a notch and with no
        // cutout, where the "Thinking" row is still drawn and nothing moved.
        var clocked = working(silently: false)
        clocked.turns = []
        let talking = pose { $0.mode = .thinking; $0.inConversation = true }
        shots.append(Shot(name: "c80-capsule-compact-thinking", note: "thinking, nothing said: band, then the field",
                          presentation: .peek, notch: capsuleBox, capsule: capsule, system: .pill, state: thinking))
        shots.append(Shot(name: "c81-capsule-compact-clock", note: "the same with the clock running",
                          presentation: .peek, notch: capsuleBox, capsule: capsule, system: .pill, state: clocked))
        shots.append(Shot(name: "c82-capsule-compact-tray-open", note: "its ⋯ pressed: the controls take a row",
                          presentation: .peek, trayOpen: true, notch: capsuleBox, capsule: capsule,
                          system: .pill, state: talking))
        shots.append(Shot(name: "c83-capsule-compact-quiet", note: "the compact card with no microphone open",
                          presentation: .peek, notch: capsuleBox, capsule: capsule, system: .none, state: clocked))
        shots.append(Shot(name: "c84-notch-thinking-nothing-said", note: "the same state under a notch: unchanged",
                          presentation: .peek, state: thinking))
        shots.append(Shot(name: "c85-no-notch-thinking-nothing-said", note: "and with no cutout: unchanged",
                          presentation: .peek, notch: .zero, state: thinking))
        // A scaled resolution on a capsule Mac nobody has measured: the box
        // is ESTIMATED (the measured box at 1512 pt, scaled to 1800 pt wide,
        // "More Space") and the capsule inside it is the fallback's.
        let scaledBox = CGSize(width: 50, height: 34)
        let scaled = NotchGeometry.capsule(reported: scaledBox, model: nil)
        shots.append(Shot(name: "c50-capsule-unmeasured-scaled-listening",
                          note: "an unmeasured capsule Mac at a scaled resolution (estimated 50×34 box): listening",
                          presentation: .collapsed, notch: scaledBox, capsule: scaled,
                          outlineHardware: true, state: folded[1].2))
        shots.append(Shot(name: "c51-capsule-unmeasured-scaled-open",
                          note: "the same, opened",
                          notch: scaledBox, capsule: scaled, outlineHardware: true, state: open[0].3))
        return shots
    }

    // MARK: - The inbox (docs/INBOX.md)

    private static func inbox(open: Bool = false, peek: Bool = false, empty: Bool = false,
                              turns: [Turn]? = nil) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        s.notices = empty ? [] : InboxSamples.items()
        s.showingInbox = open
        s.noticePeek = peek ? s.notices.first { $0.kind == .brief } : nil
        s.turns = turns ?? [Turn(role: .you, text: "Yeah, it looks like a terrible slideshow. No flowing storyline at all"),
                            Turn(role: .moe, text: "That line is still in the input box of your other coding session, the one on the launch film. Press Enter there if you want it to see the note.")]
        return s
    }

    private static let longAnswer: [Turn] = [
        Turn(role: .you, text: "Walk me through what changed in the launch plan this week"),
        Turn(role: .moe, text: (1...14).map { "Point \($0): the launch plan moved this item, and the reason is written out in full so the answer runs long enough to need more room than the hover panel has." }.joined(separator: " ")),
    ]

    private static var inboxShots: [Shot] {
        [
            Shot(name: "40-inbox-arrives",
                 note: "something arrives: its line slides out beside the notch for six seconds",
                 presentation: .collapsed,
                 state: inbox(peek: true)),
            Shot(name: "41-inbox-chat-with-count",
                 note: "opened: the conversation as always, and the inbox icon with its count",
                 state: inbox()),
            Shot(name: "42-inbox-open",
                 note: "the inbox in the chat's place: Needs you, then For your information, each kind's buttons",
                 state: inbox(open: true)),
            Shot(name: "42b-inbox-open-while-working",
                 note: "the inbox open mid-job: the clock has the corner, and ‹ Chat in the header is still the way back",
                 state: {
                     var s = inbox(open: true)
                     s.mode = .thinking; s.working = true
                     s.workingSince = Date(timeIntervalSinceNow: -42)
                     return s
                 }()),
            Shot(name: "42c-long-answer-hover",
                 note: "a long answer on hover: the panel at its hover height (a snapshot draws a scroll box from its end; where the live one rests is checked in the app)",
                 presentation: .peek,
                 state: inbox(turns: longAnswer)),
            Shot(name: "42d-long-answer-open",
                 note: "the same answer clicked open: 200 pt taller, all of it given to the conversation",
                 state: inbox(turns: longAnswer)),
            Shot(name: "43-inbox-snooze",
                 note: "Snooze on the reminder: the choices in the row",
                 state: inbox(open: true)),
            Shot(name: "44-inbox-reply-new-chat",
                 note: "a reply to the brief: its own conversation, the card on top, the way back",
                 state: {
                     var s = inbox(turns: [
                        Turn(role: .moe, text: "> **Marketing brief** · One Reddit reply ready to post, three launch tasks overdue, Show HN due this week."),
                        Turn(role: .you, text: "Make the r/mac one shorter and drop the second sentence"),
                        Turn(role: .moe, text: "Done. It now reads: “Not a big-name app, but talking to my mail and calendar from whatever window I'm in. Was skeptical it'd stick and it did.”"),
                     ])
                     s.notices = s.notices.filter { $0.kind != .brief }
                     s.noticeReturn = Conductor.NoticeReturn(from: "x", fromTitle: "Launch film", to: "")
                     return s
                 }()),
            Shot(name: "46-inbox-replying",
                 note: "Reply with nothing typed: Moe says it, the strip says what the field is for, Cancel",
                 state: {
                     var s = inbox(turns: [Turn(role: .moe, text: "Andrew Wilson Follow Up Discussion is tomorrow at 3 PM (Teams meeting). Want me to pull your recent work on the Andrew agent?")])
                     s.replyingTo = "sample-0"
                     return s
                 }()),
            Shot(name: "47-inbox-reminders-tick",
                 note: "Done on a nag from an Apple Reminder: one tap marks it done there too, and nothing happens without it",
                 state: {
                     var s = inbox(open: true)
                     s.reminderTick = ReminderTick(noticeID: "x", title: "Deal with Miriam's Portfolio Command access issue")
                     return s
                 }()),
            Shot(name: "48-inbox-reminders-tick-last",
                 note: "the same, when it was the last thing waiting",
                 state: {
                     var s = inbox(open: true, empty: true)
                     s.reminderTick = ReminderTick(noticeID: "x", title: "Deal with Miriam's Portfolio Command access issue")
                     return s
                 }()),
            Shot(name: "45-inbox-empty",
                 note: "nothing waiting",
                 state: inbox(open: true, empty: true)),
        ]
    }

    // MARK: - Every Mac

    /// The cutouts the island has to fit, in points at each Mac's default
    /// scaled resolution. Only the first was measured off `NSScreen` on a
    /// real machine (Mac15,12, 2026-09-14: strips 646 and 645 pt wide on a
    /// 1470 pt screen, safe area 32); the Pros are published figures, and the
    /// 16-inch's is for its "More Space" setting, which makes it the tallest
    /// cutout in the range. "No notch" is the MacBook Neo, the M1 Air, every
    /// iMac and every external display.
    static let machines: [(slug: String, notch: CGSize)] = [
        ("air-13",      CGSize(width: 179, height: 32)),
        ("pro-14",      CGSize(width: 185, height: 32)),
        ("pro-16",      CGSize(width: 220, height: 38)),
        ("no-notch",    .zero),
    ]

    /// Each Mac twice: the busiest the conversation panel gets — the
    /// screenshot's reminder and talk-key row over a conversation — and the
    /// resting island while Moe works, where the light has to trace the
    /// cutout it is actually given.
    private static var machineShots: [Shot] {
        machines.enumerated().flatMap { i, m in [
            Shot(name: "3\(i)a-\(m.slug)-open",
                 note: "\(m.slug): \(Int(m.notch.width))×\(Int(m.notch.height)) — reminder, talk-key row and a conversation",
                 accessibility: staleAccessibility,
                 notch: m.notch,
                 state: nudge(long: true)),
            Shot(name: "3\(i)b-\(m.slug)-working",
                 note: "\(m.slug): the resting island while Moe works",
                 presentation: .collapsed,
                 notch: m.notch,
                 state: { var s = Conductor.SnapshotState(); s.mode = .thinking; s.acting = true; return s }()),
        ] }
    }

    // MARK: - Stand-in content

    private static func working(silently: Bool) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        s.mode = .thinking
        s.acting = true
        s.working = true
        s.workingSilently = silently
        s.statusLine = "\u{1F310} find a table for two on Friday"
        s.workingStep = "Working through the page"
        s.workingSince = Date(timeIntervalSinceNow: -42)
        s.turns = [Turn(role: .you, text: "book me a table for two somewhere near the office on Friday at seven"),
                   Turn(role: .moe, text: "Let me look at what's open near you. Opening OpenTable now.", isStreaming: true)]
        return s
    }

    private static func recording(timeline: [Segment] = [],
                                  turns: [Turn] = [],
                                  actions: Int = 0,
                                  paused: Bool = false,
                                  mention: String? = nil) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        s.meeting = .recording(since: Date(timeIntervalSinceNow: -763))
        s.meetingClock = "12:43"
        s.meetingTimeline = timeline
        s.turns = turns
        s.meetingPaused = paused
        s.meetingMention = mention
        s.meetingLiveActions = (0..<actions).map {
            MeetingNotes.ActionItem(who: $0 == 0 ? "You" : "Dan",
                                    what: $0 == 0 ? "send the revised pricing sheet" : "book the follow-up",
                                    when: $0 == 0 ? "Friday" : "")
        }
        return s
    }

    /// The amber pulse with something on it. `earlier` is the late-delivery
    /// case, which is the one in the wild: a reminder that came due while
    /// the Mac was shut carries when it was for, and that used to be glued
    /// onto the front of the sentence.
    private static func nudge(thinking: Bool = false, long: Bool = false,
                              turns: [Turn]? = nil) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        s.mode = thinking ? .thinking : .idle
        if long {
            s.pendingNudge = "The deck you promised Sam was due today. Want me to check whether it went out, or help you finish and send it?"
            s.pendingNudgeWhen = nil
        } else {
            s.pendingNudge = "Eli\u{2019}s waiting for your help with Rite Care."
            s.pendingNudgeWhen = "Earlier, at 8:11 AM"
        }
        s.turns = turns ?? [Turn(role: .you, text: "what\u{2019}s he waiting on?"),
                            Turn(role: .moe, text: "The intake form for Rite Care — he needs the signed consent page before Thursday.")]
        if thinking { s.statusLine = "thinking\u{2026}" }
        return s
    }

    /// `long` is an hour's worth of notes: more than the tallest panel can
    /// hold, which is the case the measurement cannot fix and the fade and
    /// the "SCROLL FOR THE REST" line exist for. It is here so that the state
    /// where content is *deliberately* off the bottom can be looked at, the
    /// same way every other state can.
    private static func notesReady(short: Bool = false,
                                   long: Bool = false) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        let notes = MeetingNotes(
            title: short ? "Pricing review" : "Pricing review — what we are changing before the launch",
            summary: short
                ? "The per-seat price holds and the volume break moves to 25 seats."
                : long
                ? "We agreed the per-seat price holds at nineteen and the volume break moves from fifty seats to twenty-five, which brings the mid-market accounts we are actually closing inside it for the first time. Dan will redo the sheet against the new break and circulate it before Friday, and Priya will take the enterprise tier back to legal because the discount schedule in the contract template still names the old break."
                : "We agreed the per-seat price holds at nineteen and the volume break moves from fifty seats to twenty-five. Dan will redo the sheet against the new break and circulate it before Friday.",
            decisions: short ? ["Volume break moves to 25 seats."]
                             : long
                             ? ["Per-seat price stays at $19.",
                                "Volume break moves to 25 seats.",
                                "The launch date does not move.",
                                "The enterprise tier keeps its own schedule until legal has read it.",
                                "No grandfathering for accounts signed after the first of the month."]
                             : ["Per-seat price stays at $19.",
                                "Volume break moves to 25 seats.",
                                "The launch date does not move."],
            actionItems: long
                ? [
                    MeetingNotes.ActionItem(who: "You", what: "send the revised pricing sheet", when: "Friday"),
                    MeetingNotes.ActionItem(who: "Dan", what: "check the volume break against last quarter's invoices", when: "Wednesday"),
                    MeetingNotes.ActionItem(who: "Priya", what: "take the discount schedule back to legal", when: "next week"),
                    MeetingNotes.ActionItem(who: "Marcus", what: "update the pricing page and the two ads that quote the old break", when: ""),
                  ]
                : [
                    MeetingNotes.ActionItem(who: "You", what: "send the revised pricing sheet", when: "Friday"),
                    MeetingNotes.ActionItem(who: "Dan", what: "check the volume break against last quarter's invoices", when: "Wednesday"),
                  ])
        var record = MeetingRecord(startedAt: Date(timeIntervalSinceNow: -3600),
                                   durationSeconds: 1122,
                                   folder: "2026-08-31-pricing-review",
                                   notes: notes)
        record.summarised = true
        let url = URL(fileURLWithPath: "/tmp/panel-snapshot/notes.md")
        s.meeting = .done(url: url)
        s.meetingOutcome = MeetingSummary.Outcome(record: record, summaryURL: url,
                                                  recordURL: url, message: "Notes written")
        s.meetingStatus = "Notes written"
        s.meetingDelivery = "Sent to your notes folder and mailed to you."
        return s
    }

    private static let sampleTimeline: [Segment] = [
        Segment(start: 512, end: 519, speaker: .them(2),
                text: "So the number we landed on last time was nineteen a seat, and I do not think we should move it."),
        Segment(start: 519, end: 524, speaker: .you,
                text: "Agreed — the churn we saw at twenty-four was the whole reason we came down."),
        Segment(start: 524, end: 533, speaker: .them(3),
                text: "The part I want to revisit is the volume break. Fifty seats is too high for the mid-market accounts we are actually closing."),
        Segment(start: 533, end: 540, speaker: .them(2),
                text: "Twenty-five, then. That is where most of them sit anyway."),
        Segment(start: 540, end: 548, speaker: .you,
                text: "Fine by me. Can somebody redo the sheet against that before Friday?"),
    ]

    /// `AccessibilityWatch.problem`'s stale-grant sentence, the longer of
    /// its two, which is the one in the screenshot.
    /// Named from the posed config's talk key (`Config()`, the conductor
    /// above), as `AccessibilityWatch.problem(for:)` names it in the app.
    private static let staleAccessibility = "\(Config().talkKey.label) can't start me yet. If Memoe is already switched on in Accessibility, macOS is holding on to an older copy — Fix clears it, then switch Memoe on again."

    private static let sampleTurns: [Turn] = [
        Turn(role: .you, text: "what did we agree the volume break was last quarter"),
        Turn(role: .moe, text: "Fifty seats, set in the March review — the note says it was picked to match the enterprise tier and nobody revisited it. Two of the five deals you closed since were under thirty."),
    ]
}

// MARK: - The stand-in Mac, drawn

/// A video call to put the panel over.
///
/// The point is not realism, it is contrast: a face is a bright, warm,
/// medium-value thing, and a dark panel judged against a white page is how you
/// get one that disappears over somebody's chin. So there are light tiles and
/// dark ones, and the panel hangs over the join.
private struct CallBackdrop: View {
    let light: Bool
    var menuBar: CGFloat = PanelSnapshot.notch.height

    var body: some View {
        ZStack {
            (light ? Color(white: 0.90) : Color(white: 0.10))
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    tile(hue: 0.07, bright: true, name: "Dan")
                    tile(hue: 0.55, bright: false, name: "Priya")
                }
                HStack(spacing: 8) {
                    tile(hue: 0.10, bright: true, name: "You")
                    tile(hue: 0.62, bright: false, name: "Marcus")
                }
                // The call's own toolbar, so the bottom of the frame is not
                // empty space pretending to be a window.
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                    .frame(height: 40)
                    .overlay(
                        HStack(spacing: 14) {
                            ForEach(0..<5, id: \.self) { _ in
                                Circle().fill(Color.white.opacity(0.35)).frame(width: 16, height: 16)
                            }
                        }
                    )
            }
            .padding(.horizontal, 24)
            .padding(.top, 52)
            .padding(.bottom, 16)

            // The menu bar strip the notch is cut out of.
            VStack {
                Rectangle()
                    .fill(light ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                    .frame(height: menuBar)
                Spacer()
            }
        }
    }

    private func tile(hue: Double, bright: Bool, name: String) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                RadialGradient(colors: bright
                               ? [Color(hue: hue, saturation: 0.35, brightness: 0.92),
                                  Color(hue: hue, saturation: 0.45, brightness: 0.45)]
                               : [Color(hue: hue, saturation: 0.30, brightness: 0.42),
                                  Color(hue: hue, saturation: 0.40, brightness: 0.14)],
                               center: .init(x: 0.5, y: 0.38),
                               startRadius: 8, endRadius: 190)
            )
            .overlay(alignment: .bottomLeading) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(6)
            }
    }
}

/// The cutout itself: black, square-shouldered against the top of the screen,
/// rounded only where it meets the glass below.
private struct NotchCutout: View {
    let size: CGSize

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 9,
                               bottomTrailingRadius: 9, topTrailingRadius: 0)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
    }
}

/// A floating camera capsule: black glass with a lens in it, 8.5 pt below the
/// top of the screen on the Mac it was measured on. Drawn over the island,
/// because that is where the hardware is.
private struct CapsuleHardware: View {
    let capsule: NotchGeometry.CapsuleCutout
    var outlined = false

    var body: some View {
        ZStack {
            Capsule(style: .circular).fill(Color.black)
            Circle().fill(Color(red: 0.11, green: 0.13, blue: 0.19)).frame(width: 5, height: 5)
            if outlined {
                Capsule(style: .circular).strokeBorder(Color(red: 1, green: 0.2, blue: 0.7), lineWidth: 0.75)
            }
        }
        .frame(width: capsule.size.width, height: capsule.size.height)
        .offset(y: capsule.topGap)
        .allowsHitTesting(false)
    }
}

/// macOS's microphone indicator beside a floating capsule, as photographed
/// on the owner's Mac (`NotchGeometry.SystemIndicator`): an orange dot right
/// of the camera, or an outlined pill round the camera with the dot and an
/// orange microphone in its right end. Drawn last, over the island, because
/// the system draws it over every window.
private struct SystemMicIndicator: View {
    let indicator: NotchGeometry.SystemIndicator
    let pill: Bool

    private static let orange = Color(red: 1, green: 0.62, blue: 0.04)

    var body: some View {
        ZStack(alignment: .top) {
            if pill {
                Capsule(style: .circular).fill(Color.black)
                    .overlay(Capsule(style: .circular).strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                    .frame(width: indicator.pill.width, height: indicator.pill.height)
                    .offset(x: indicator.pill.midX, y: indicator.pill.minY)
                // 21 pt right of the dot in the photograph.
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Self.orange)
                    .frame(width: 14, height: 16)
                    .offset(x: indicator.dot.x + 21, y: indicator.dot.y - 8)
            }
            Circle().fill(Self.orange)
                .frame(width: 5, height: 5)
                .offset(x: indicator.dot.x, y: indicator.dot.y - 2.5)
        }
        .allowsHitTesting(false)
    }
}
#endif
