import AppKit
import MoeDesign
import SwiftUI

/// First launch. Seven screens, one action each, every one skippable and
/// every one reversible (eight while typing by voice is offered —
/// `Features.dictation`, off since docs/DEFAULTS.md row 4 — when screen 5
/// below is shown between 4 and 6):
///   1. Welcome — the four things Moe does, one line each (five with dictation)
///   2. Microphone — the one permission asked at launch (PRODUCT.md §8.4)
///   3. Something to think with — install the thinking part if it is
///      missing, then four ways in: a Claude plan and a ChatGPT plan
///      recommended equally (docs/DEFAULTS.md row 1), a key, this Mac —
///      and a "start free" row for someone with no plan. The last three
///      are finished in Settings › Brain while this window waits
///      (`Onboarding.BrainHandoff`)
///   4. Say hello — the exact thing to say and a way to say it that works
///      right now (the held key once Accessibility is on), and Accessibility
///      and Screen Recording, one button each (row 33)
///   5. Type what I say — dictation (only while `Features.dictation`)
///   6. Notes in meetings — what it records, where it stays, who is told
///   7. What may I read to learn about you — the sources as switches and
///      the daily pass, one answer, recommended on (LearnStep.swift, row 24)
///   8. Connect your world → Connections: the Mac's apps first, then
///      Google (row 34); start with the Mac, and problem reports (rows 28, 30)
///
/// Row 40: every new ask is folded into a screen that was already here —
/// the count stays seven.
///
/// The rule for every sentence here: it has to be understood by someone who
/// has never heard of a subscription plan, a permission or a key. One short
/// paragraph, then the button. Anything longer belongs in the pane the
/// button leads to, where there is room and a reason to read it.
///
/// The screens are drawn with the app's own design system (MoeDesign.Theme):
/// paper ground, serif display titles, serif prose, pill buttons. They used
/// to be stock SwiftUI, which meant the first thing a person saw of Moe
/// looked like nothing else in it.
///
/// The amber "nudge" glow is named on screen 8, and only because it works:
/// `scripts/install.sh` copies `moe-home/nudge.sh` into ~/.moe and
/// `moe-home/sync.sh` runs it at the end of every sync, so ~/.moe/nudge.json
/// can actually be written. It has an off switch in Settings › Background
/// (`Config.nudges`), which the screen says. If any of that is ever undone,
/// scripts/test-onboarding.sh fails rather than letting the promise stand.
///
/// Nothing here blocks. Every screen has Back and Skip, a declined permission
/// is explained rather than re-asked, and closing the window at any point
/// lands on the main window rather than on nothing — with the welcome kept
/// for the next launch, at the screen it was closed on (`Onboarding.Ending`).
enum Onboarding {
    // TODO(Config.swift, owned elsewhere): an `onboardingDone` key. Until
    // then a file marker in ~/.moe.
    static var marker: URL { marker(in: Paths.home) }
    static func marker(in home: URL) -> URL { home.appendingPathComponent(".onboarded") }
    static var done: Bool { done(in: Paths.home) }
    static func done(in home: URL) -> Bool { FileManager.default.fileExists(atPath: marker(in: home).path) }
    static func markDone(in home: URL = Paths.home) {
        try? Data().write(to: marker(in: home))
        clearResume(in: home)
    }

    /// The screen an unfinished welcome is on, kept current as the person
    /// moves (`OnboardingWindow.stepChanged`) and removed when they finish.
    ///
    /// Until 2026-11-12 closing the window at any screen marked the welcome
    /// done for good: a person who shut it on screen two never saw the
    /// sign-in, and nothing in the app could bring it back. Now only the
    /// last screen's two ways out mark it done; a close anywhere else
    /// leaves this marker, and the next launch opens the welcome on that
    /// screen. (The brain screen's key and local-model rows used to end it
    /// too; they stay in the flow now — `BrainHandoff`.)
    ///
    /// Written on every step rather than at the close, so a Moe that is
    /// quit — or dies — mid-flow resumes too; `windowWillClose` is not
    /// called for a quit.
    static var resumeMarker: URL { resumeMarker(in: Paths.home) }
    static func resumeMarker(in home: URL) -> URL { home.appendingPathComponent(".onboarding-resume") }
    static var resumeScreen: Screen? { resumeScreen(in: Paths.home) }
    static func resumeScreen(in home: URL) -> Screen? {
        guard let raw = try? String(contentsOf: resumeMarker(in: home), encoding: .utf8),
              let screen = Screen(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // A marker from a build that still showed the dictation screen
        // lands on the screen after it, never on one that is not shown.
        return Screen.shown.contains(screen) ? screen : screen.next
    }
    static func markResume(at screen: Screen, in home: URL = Paths.home) {
        try? Data(screen.rawValue.utf8).write(to: resumeMarker(in: home))
    }
    static func clearResume(in home: URL = Paths.home) {
        try? FileManager.default.removeItem(at: resumeMarker(in: home))
    }

    /// How a welcome window ended.
    enum Ending: Equatable {
        /// The last screen was left forward (Take me to Connections, Not
        /// now).
        case completed
        /// The window was closed with screens still to come.
        case closed(at: Screen)
    }

    /// What an ending leaves on disk. `replay` is "Show welcome again" on a
    /// Mac that already finished: closing that one early changes nothing.
    static func record(_ ending: Ending, replay: Bool = false, in home: URL = Paths.home) {
        switch ending {
        case .completed:
            markDone(in: home)
        case .closed(let screen):
            guard !replay else { return }
            markResume(at: screen, in: home)
        }
    }

    /// What a launch does about the welcome.
    enum Launch: Equatable {
        case mainWindow
        /// Never finished: open the welcome here.
        case welcome(at: Screen)
        /// Never shown and not needed — a Mac that already has its sign-in.
        case markDoneThenMainWindow
    }

    /// Done wins over a resume marker, so a stale marker can never pin a
    /// finished Mac to the welcome.
    /// `signedIn` is only asked when nothing else decides it — it reads the
    /// keychain.
    static func atLaunch(done: Bool, resume: Screen?, firstRun: Bool,
                         signedIn: @autoclosure () -> Bool) -> Launch {
        if done { return .mainWindow }
        if let resume { return .welcome(at: resume) }
        if firstRun || !signedIn() { return .welcome(at: .welcome) }
        return .markDoneThenMainWindow
    }

    // MARK: - Words the tests hold

    /// "Say hello" (docs/DEFAULTS.md row 33): one plain line each, why.
    /// Only what this grant does. It used to end "and click for you when
    /// you ask", which Memoe's own Accessibility switch does not buy:
    /// clicking is CuaDriver's work, under CuaDriver's own two switches
    /// (docs/COMPUTER-USE.md) — said on the card, so the name is not a
    /// stranger when macOS asks about it (`screenHelperNote`).
    static let accessibilityWhy = "So Moe can hear the talk key in any app."
    /// Said once on "Say hello", under the two cards' own reasons. True
    /// whatever was allowed above: the helper's switches are separate.
    static let screenHelperNote = "Clicking and typing for you is a separate thing. A helper app called CuaDriver does that part, and macOS asks about it under that name — Accessibility and Screen Recording, once each — the first time you ask me to do something on your Mac."
    static let screenRecordingWhy = "So Moe can see your screen when you ask about it."
    /// The last screen's two rows (rows 30 and 28).
    static let launchAtLoginTitle = "Start Moe when my Mac starts"
    static let problemReportsTitle = "Let Moe send problem reports"

    // MARK: - Something to think with

    /// The brain screen once a sign-in is stored — whichever plan it was.
    /// One state and one way forward for every provider: until 2026-11-12
    /// the ChatGPT sign-in succeeded and left the person on the same four
    /// rows, while the Claude one moved on with a tick.
    struct SignIn: Equatable {
        /// Whose account, as the tick names it; nil until one is stored.
        private(set) var account: String?
        /// Set up in Settings › Brain (a key, a model on this Mac) rather
        /// than signed in to here: the tick says so in its own words.
        private(set) var viaSettings = false
        var signedIn: Bool { account != nil }
        var line: String {
            viaSettings ? "I'm thinking with \(account ?? "it") now."
                        : "Signed in with \(account ?? "your plan")."
        }

        init(account: String? = nil, viaSettings: Bool = false) {
            self.account = account
            self.viaSettings = viaSettings
        }

        /// A sign-in sheet closed. The screen to move to, or nil to stay.
        mutating func finished(_ path: BrainPath, ok: Bool) -> Screen? {
            guard ok else { return nil }
            account = path.accountName
            viaSettings = false
            return .tryIt
        }

        /// A brain chosen in Settings › Brain answered (`BrainHandoff`):
        /// the same tick and the same way forward as a sign-in.
        mutating func connected(_ provider: BrainProviderKind) -> Screen {
            account = provider.shortName
            viaSettings = true
            return .tryIt
        }

        /// The sign-in was stored but could not be made the choice.
        mutating func undo() { account = nil; viaSettings = false }
    }

    /// The download of the sign-in tool failed. Said in place, with Try
    /// again beside it; the installer's own last line goes to the log.
    static let signInToolFailed = "I couldn't download what the sign-in needs. Check your internet connection and try again — or pick another way in above."

    // MARK: - Say hello

    /// The first sentence of "Say hello": only ever something that works
    /// right now. The held key needs Accessibility (`PushToTalk.start`
    /// refuses without it); the shortcut and the button on the screen need
    /// nothing (`HotKey` is a Carbon hot key, the button calls
    /// `Conductor.toggle`).
    static func sayHelloLead(accessibility: Bool, holdKey: String, whereItIs: String, shortcut: String) -> String {
        accessibility
            ? "Hold \(holdKey) — \(whereItIs) — say “what can you do?”, and let go. I answer out loud."
            : "Press Talk to me below, or \(shortcut), and say “what can you do?”. I answer out loud."
    }

    /// The Accessibility card once Allow was pressed: the key arms the
    /// moment the grant lands (`AccessibilityWatch.onGranted`), so there is
    /// nothing to quit and reopen — only something to wait for.
    static func accessibilityWaiting(holdKey: String) -> String {
        "Waiting for you to switch Memoe on in System Settings. The moment you do, \(holdKey) works — nothing to restart."
    }

    /// "Say hello" is finished when the person has spoken *and* what came
    /// back has been heard — not at the first word, which used to change
    /// the screen underneath the answer. `roles` are the turns since the
    /// screen appeared.
    static func sayHelloFinished(roles: [Turn.Role], mode: Conductor.Mode) -> Bool {
        guard let said = roles.lastIndex(of: .you), said < roles.count - 1 else { return false }
        return mode != .thinking && mode != .speaking
    }

    /// The models' warm-up line ("Getting my ears on…"), for the screen as
    /// well as the island: nil once they are ready, or while Moe is busy
    /// with something that has a line of its own.
    static func warmUpLine(status: String, voiceReady: Bool, mode: Conductor.Mode) -> String? {
        guard !voiceReady, mode == .idle, !status.isEmpty else { return nil }
        return status
    }

    /// The screens, in order — named here rather than only inside the view
    /// so `Moe --onboarding-json` can prove every one has a way past it
    /// (scripts/test-onboarding.sh).
    enum Screen: String, CaseIterable, Identifiable {
        case welcome, microphone, brain, tryIt, dictate, meetings, learn, connect
        var id: String { rawValue }

        /// The screens a person actually sees, in order. `dictate` is in
        /// the flow only while dictation is a feature (`Features.dictation`);
        /// everything that walks the flow — Back, Skip, the dots, the JSON
        /// dump, the snapshot — reads this, never `allCases`.
        static var shown: [Screen] {
            allCases.filter { $0 != .dictate || Features.dictation }
        }

        /// The screen after this one in the shown flow, or nil at the end.
        /// Defined for a hidden screen too, so a stale marker can move on.
        var next: Screen? {
            let after = Screen.allCases.drop { $0 != self }.dropFirst()
            return after.first { Screen.shown.contains($0) }
        }

        /// What the Skip link says here. Every screen has one: skipping is
        /// never a dead end, and the last one's is "Not now".
        var skipLabel: String { self == .connect ? "Not now" : "Skip" }

        /// One line, for the dump: what this screen is for.
        var purpose: String {
            switch self {
            case .welcome:    return Features.dictation ? "What Moe does, all five of it." : "What Moe does, all four of it."
            case .microphone: return "The microphone, and what Moe does with it."
            case .brain:      return "Install the thinking part if it is missing, then choose whose account Moe borrows — a Claude or ChatGPT plan, recommended equally."
            case .tryIt:      return "Hold the key, say hello, hear an answer — and allow Accessibility and Screen Recording, both skippable."
            case .dictate:    return "Hold the other key and your words land in whatever app you are in."
            case .meetings:   return "Moe takes the notes, and everyone can see it is recording."
            case .learn:      return "What Moe may read to learn about you: the sources as switches, and the daily pass, recommended on."
            case .connect:    return "The Mac's own apps first, then Google, then everything else — and whether Moe starts with your Mac and may send problem reports."
            }
        }
    }

    /// For scripts/test-onboarding.sh: the screens with their skip paths,
    /// the four ways to give Moe a brain, and every provider's words.
    static func dumpJSON() -> String {
        let obj: [String: Any] = [
            "screens": Screen.shown.map {
                ["id": $0.rawValue, "purpose": $0.purpose, "skip": $0.skipLabel] as [String: Any]
            },
            // Where a relaunched Moe would pick the flow up, read from the
            // home the dump runs against — scripts/test-onboarding.sh
            // writes the marker and expects it back here.
            "resume": resumeScreen?.rawValue as Any,
            "paths": BrainPath.all.map(\.json),
            "providers": BrainGuide.all.map(\.json),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private let conductor: Conductor
    private var window: NSWindow?
    var onOpenConnections: (() -> Void)?
    /// Opens a Settings pane beside the welcome, which stays open and
    /// waits — the brain screen's key, free and local-model rows
    /// (`Onboarding.BrainHandoff`).
    var onOpenSection: ((MainWindow.Section) -> Void)?
    var onFinished: (() -> Void)?
    /// The person reached the end of the welcome: Take me to Connections or
    /// Not now on the last screen. Before `onFinished`; never for a close
    /// part-way through, and never in a rehearsal or a snapshot.
    var onCompleted: (() -> Void)?
    /// A way out that ends the welcome was taken (`OnboardingView.finish`).
    /// A close without it is the person shutting the window part-way.
    private var finished = false
    /// The screen showing now — where an unfinished welcome resumes.
    private var current: Onboarding.Screen = .welcome
    /// False in a rehearsal, and for "Show welcome again" on a Mac that has
    /// finished: neither writes a marker.
    private var persists = true

    /// Tall enough for the brain screen with its install card — the tallest
    /// of the seven — without scrolling. Every screen is top-aligned.
    static let size = NSSize(width: 640, height: 640)

    init(conductor: Conductor) {
        self.conductor = conductor
    }

    /// - Parameter replay: "Show welcome again" on a Mac that already
    ///   finished it — nothing about how it ends is recorded.
    func show(pose: OnboardingView.Pose? = nil, replay: Bool = false) {
        persists = !(pose?.rehearsal ?? false) && !replay
        finished = false
        stepChanged(pose?.step ?? .welcome)
        let view = OnboardingView(conductor: conductor,
                                  openConnections: { [weak self] in self?.onOpenConnections?() },
                                  openSection: { [weak self] in self?.onOpenSection?($0) },
                                  finish: { [weak self] in self?.finished = true; self?.close() },
                                  completed: { [weak self] in self?.onCompleted?() },
                                  stepChanged: { [weak self] in self?.stepChanged($0) },
                                  comeForward: { [weak self] in self?.bringToFront() },
                                  pose: pose)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Welcome to Memoe"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.setContentSize(Self.size)
        w.center()
        w.isReleasedWhenClosed = false
        // An ordinary window, not a floating one. The Claude sign-in opens a
        // browser page the person has to read, and a floating 640-point
        // window sat on top of it.
        w.level = .normal
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The marker follows the person from screen to screen, so a quit or a
    /// crash mid-flow resumes exactly as a closed window does.
    private func stepChanged(_ screen: Onboarding.Screen) {
        current = screen
        if persists, !finished { Onboarding.markResume(at: screen) }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let ending: Onboarding.Ending = finished ? .completed : .closed(at: current)
        if persists { Onboarding.record(ending) }
        Log.write("onboarding: \(finished ? "finished" : "closed at \(current.rawValue) — it resumes there")")
        onFinished?()
    }
}

/// True only while `ImageRenderer` is drawing a screen for
/// `Moe --onboarding-snapshot`: a macOS `ScrollView` rasterises empty, so
/// the snapshot lays the same content over a plain stack instead.
private struct OnboardingSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var onboardingSnapshot: Bool {
        get { self[OnboardingSnapshotKey.self] }
        set { self[OnboardingSnapshotKey.self] = newValue }
    }
}

struct OnboardingView: View {
    @ObservedObject var conductor: Conductor
    var openConnections: () -> Void
    var openSection: (MainWindow.Section) -> Void
    var finish: () -> Void
    /// Called just before `finish` when the last screen is left forward —
    /// the welcome finished, not abandoned (the login item, row 30).
    var completed: () -> Void

    /// Everything a screen's look depends on that is otherwise read from the
    /// machine — so `Moe --onboarding-snapshot` can pose each state without
    /// changing a permission or installing anything. The app passes nothing
    /// and reads the real answers.
    @MainActor
    struct Pose {
        var step: Onboarding.Screen = .welcome
        var micAsked = false
        var micDenied = false
        var signedIn = false
        /// Which plan `signedIn` was with, as the tick names it.
        var signedInAccount = BrainPath.claude.accountName
        /// …or a key or local model set up in Settings › Brain.
        var signedInViaSettings = false
        /// The sign-in tool's download failed (posed for a snapshot).
        var signInToolFailed = false
        /// A key or local-model row was pressed and Settings › Brain is
        /// open (posed for a snapshot), and how far that has got.
        var handoff: Onboarding.BrainHandoff.Way?
        var handoffProblem: String?
        /// Allow was pressed on the Accessibility card (posed for a snapshot).
        var accessibilityAsked = false
        var bootstrapDone = Bootstrap.hermesInstalled()
        var claudeReady = ClaudeSignIn.claudePath() != nil
        var accessibility = PushToTalk.hasAccessibility
        /// Screen Recording, asked on "Say hello" (docs/DEFAULTS.md row 33).
        var screenRecording = ScreenPermission.granted
        var installing = false
        var installLine = ""
        /// The bundled Hermes is being laid down (SeedInstall). Posed for a
        /// snapshot; the app reads it from `SeedInstall.shared`.
        var seeding = false
        /// `Moe --onboarding-rehearsal`: every real side effect — the
        /// permission prompts, the download, the sign-in, the Terminal, the
        /// relaunch — is replaced by a timed fake, so a person can walk the
        /// whole flow on their own Mac and see exactly what a stranger sees
        /// without any of it happening. The app never sets this.
        var rehearsal = false
        /// The learn screen's rows, posed: a snapshot or a rehearsal shows
        /// these instead of asking consent.sh what is connected.
        var learnSources: [BackgroundLearning.Source]?
        init() {}

        /// A fresh Mac: nothing granted, nothing installed.
        static var freshMac: Pose {
            var p = Pose()
            p.bootstrapDone = false
            p.seeding = true
            p.claudeReady = false
            p.accessibility = false
            p.screenRecording = false
            p.rehearsal = true
            p.learnSources = posedLearnSources
            return p
        }
    }

    /// Three of the Mac's own sources, as `consent.sh list` would report
    /// them on a Mac that has them: the labels are the manifests' own and
    /// the sentences are learn/consent_list.py's DESCRIBE table, verbatim —
    /// scripts/test-onboarding-learn.sh holds each against that file, so a
    /// picture of this screen can never say something the real one does not.
    static var posedLearnSources: [BackgroundLearning.Source] {
        [
            .init(name: "imessage", state: .unset, connected: true, label: "Messages (iMessage + SMS)",
                  reads: "your iMessage and SMS conversations: who wrote, when, and the full text"),
            .init(name: "calendar", state: .unset, connected: true, label: "Calendar",
                  reads: "your calendar events: titles, times, locations, attendees, and the invite's notes (its agenda, dial-in and any questions)"),
            .init(name: "notes", state: .unset, connected: true, label: "Apple Notes",
                  reads: "your Apple Notes: titles and full text of notes changed in the window"),
        ]
    }

    private typealias Step = Onboarding.Screen
    @State private var step: Step
    @State private var micAsked: Bool
    @State private var micDenied: Bool
    @State private var showSignIn = false
    @State private var signIn: Onboarding.SignIn
    private var signedIn: Bool { signIn.signedIn }
    @State private var signInToolFailed: Bool
    /// Settings › Brain is open for a key or a local model, and the welcome
    /// is waiting for it (`Onboarding.BrainHandoff`).
    @State private var handoff: Onboarding.BrainHandoff?
    /// How many turns the conversation held when "Say hello" appeared: only
    /// what is said after that counts as trying it.
    @State private var sayHelloBaseline: Int
    @State private var brainNote = ""
    @State private var bootstrapDone: Bool
    @State private var claudeReady: Bool
    @State private var installing: Bool
    @State private var installLine: String
    @State private var accessibility: Bool
    @State private var accessibilityAsked: Bool
    @State private var screenRecording: Bool
    @State private var screenAsked = false
    /// The last screen's two rows. Launch at login starts where the config
    /// has it (on — registered when the welcome is finished, row 30);
    /// problem reports where privacy.json has it (off).
    @State private var launchAtLogin: Bool
    @State private var reportsOn: Bool
    @State private var reportsWorking = false
    @State private var reportsNote = ""
    @State private var showReportsDetail = false
    @State private var rehearsalMode: Conductor.Mode = .idle
    @State private var posedSeeding: Bool
    @ObservedObject private var seed = SeedInstall.shared
    @ObservedObject private var ax = AccessibilityWatch.shared
    @StateObject private var flow = ClaudeSignInFlow()
    @StateObject private var chatgptFlow = ChatGPTSignInFlow()
    @StateObject private var learn: LearnStepModel
    @State private var showChatGPT = false
    @Environment(\.onboardingSnapshot) private var snapshot
    private let rehearsal: Bool

    /// Told every time the screen changes, so the window can keep the
    /// place an unfinished welcome resumes at.
    private let stepChanged: (Onboarding.Screen) -> Void
    /// Brings the welcome back in front of the main window, once the brain
    /// set up there answers.
    private let comeForward: () -> Void

    @MainActor
    init(conductor: Conductor,
         openConnections: @escaping () -> Void,
         openSection: @escaping (MainWindow.Section) -> Void,
         finish: @escaping () -> Void,
         completed: @escaping () -> Void = {},
         stepChanged: @escaping (Onboarding.Screen) -> Void = { _ in },
         comeForward: @escaping () -> Void = {},
         pose: Pose? = nil) {
        let pose = pose ?? Pose()
        self.conductor = conductor
        self.openConnections = openConnections
        self.openSection = openSection
        self.finish = finish
        self.completed = completed
        self.stepChanged = stepChanged
        self.comeForward = comeForward
        var posedHandoff = pose.handoff.map {
            Onboarding.BrainHandoff(way: $0, brain: .init(provider: .claudeCode, model: "", baseURL: ""),
                                    connected: true)
        }
        if let problem = pose.handoffProblem { _ = posedHandoff?.checked(problem: problem) }
        _handoff = State(initialValue: posedHandoff)
        _step = State(initialValue: pose.step)
        _micAsked = State(initialValue: pose.micAsked)
        _micDenied = State(initialValue: pose.micDenied)
        _signIn = State(initialValue: Onboarding.SignIn(account: pose.signedIn ? pose.signedInAccount : nil,
                                                             viaSettings: pose.signedIn && pose.signedInViaSettings))
        _signInToolFailed = State(initialValue: pose.signInToolFailed)
        _sayHelloBaseline = State(initialValue: conductor.turns.count)
        _accessibilityAsked = State(initialValue: pose.accessibilityAsked)
        _bootstrapDone = State(initialValue: pose.bootstrapDone)
        _claudeReady = State(initialValue: pose.claudeReady)
        _installing = State(initialValue: pose.installing)
        _installLine = State(initialValue: pose.installLine)
        _accessibility = State(initialValue: pose.accessibility)
        _screenRecording = State(initialValue: pose.screenRecording)
        _launchAtLogin = State(initialValue: conductor.config.launchAtLogin)
        _reportsOn = State(initialValue: pose.rehearsal ? false : (Cloud.link.problemReports?.isOn() ?? false))
        _posedSeeding = State(initialValue: pose.seeding)
        _learn = StateObject(wrappedValue: LearnStepModel(posed: pose.learnSources, recommend: true))
        rehearsal = pose.rehearsal
    }

    /// The bundled Hermes is on its way into ~/.hermes right now. Real in
    /// the app (SeedInstall, started at launch), posed in a snapshot or a
    /// rehearsal.
    private var seeding: Bool {
        if snapshot || rehearsal { return posedSeeding }
        return seed.phase == .running
    }

    /// Runs `body` after `seconds`, on the main actor. The rehearsal's fakes
    /// are all shaped like this: a pause about as long as the real thing
    /// takes, then the state the real thing would leave behind.
    private func later(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    /// The shortcut, as configured. It is a *toggle* (AppDelegate.registerHotKey
    /// hands it to Conductor.toggle), not a hold — the screen used to tell
    /// people to hold it and let go, which is a different key entirely.
    private var shortcut: String {
        HotKey.describe(keyCode: conductor.config.hotKeyCode, modifiers: conductor.config.hotKeyModifiers)
    }

    /// The hold key as configured (`Config.talkKey`, right ⌥ to start with),
    /// which is exactly what PushToTalk.isCleanPress tests for.
    private var holdKey: String { conductor.config.talkKey.inSentence }

    private var dictationKey: String { conductor.effectiveDictationKey.displayName }

    var body: some View {
        VStack(spacing: 0) {
            if snapshot {
                screen.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) { screen }
            }
            footer
        }
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
        .background(Theme.paper)
        .sheet(isPresented: $showSignIn) {
            ClaudeSignInSheet(flow: flow) { ok in
                showSignIn = false
                signInFinished(.claude, ok: ok)
            }
        }
        .onAppear {
            flow.rehearsal = rehearsal
            flow.onStored = { if !rehearsal { conductor.restartBrain() } }
        }
        // They said something and the answer has been heard: that screen
        // is done, move on. Both halves — a turn arriving, and Moe going
        // quiet — can be the last thing to happen.
        .onChange(of: conductor.turns.count) { _, _ in sayHelloMayBeDone() }
        .onChange(of: conductor.mode) { _, _ in sayHelloMayBeDone() }
        // A key or a local model being set up in Settings › Brain: the
        // choice landing, and the brain coming back up on it.
        .onChange(of: conductor.config.brainProvider) { _, _ in handoffMayBeDone() }
        .onChange(of: conductor.config.brainModel) { _, _ in handoffMayBeDone() }
        .onChange(of: conductor.config.brainExtras["baseURL"]) { _, _ in handoffMayBeDone() }
        .onChange(of: conductor.connected) { _, _ in handoffMayBeDone() }
        // Coming back from System Settings: the grant may have changed.
        .onChange(of: step) { _, now in
            stepChanged(now)
            if now == .tryIt { sayHelloBaseline = conductor.turns.count }
            if !snapshot { accessibility = PushToTalk.hasAccessibility }
            if !snapshot, !rehearsal { screenRecording = ScreenPermission.granted }
        }
        // …and while this screen is up: the card goes the moment it is on.
        .onChange(of: ax.granted) { _, now in if !snapshot, !rehearsal { accessibility = now } }
    }

    /// One way forward for every sign-in (`Onboarding.SignIn`).
    private func signInFinished(_ path: BrainPath, ok: Bool) {
        if let next = signIn.finished(path, ok: ok) {
            brainNote = ""
            signInToolFailed = false
            step = next
        }
    }

    // MARK: Settings › Brain, and back

    private var brainNow: Onboarding.BrainHandoff.Brain {
        let cfg = conductor.config
        return .init(provider: cfg.brainProvider, model: cfg.brainModel,
                     baseURL: cfg.brainExtras["baseURL"] ?? "")
    }

    /// A key, the free start, or a model on this Mac: Settings › Brain has
    /// the fields, so it opens — and the welcome stays, says what to do
    /// there, and waits. It used to close for good at this point.
    private func leaveForBrainPane(_ way: Onboarding.BrainHandoff.Way) {
        brainNote = ""
        signInToolFailed = false
        handoff = Onboarding.BrainHandoff(way: way, brain: brainNow,
                                          connected: rehearsal ? true : conductor.connected)
        if rehearsal {
            // The person pastes a key next door; a few seconds, then it
            // answers and the flow carries on.
            let provider: BrainProviderKind = way == .onThisMac ? .lmStudio : .gemini
            later(3.0) {
                guard var waiting = handoff else { return }
                _ = waiting.observe(.init(provider: provider, model: "", baseURL: ""),
                                    connected: true, usable: true)
                handoff = waiting
            }
            later(5.0) { guard handoff != nil else { return }; brainConnected(provider) }
            return
        }
        openSection(.brain)
    }

    private func handoffMayBeDone() {
        guard !rehearsal, !snapshot, var waiting = handoff else { return }
        let brain = brainNow
        let usable = brain.provider != .claudeCode || HermesKey.childOAuthTokenExists()
        let ask = waiting.observe(brain, connected: conductor.connected, usable: usable)
        handoff = waiting
        guard ask else { return }
        let config = conductor.config
        Task {
            // The same one-word question Settings › Brain asks, so "it
            // works" means the same thing on both sides of the hand-over.
            let problem = await BrainSetup.probe(config: config, brain: BrainSelection(config: config))
            guard var waiting = handoff else { return }
            if waiting.checked(problem: problem) {
                brainConnected(config.brainProvider)
            } else {
                Log.write("onboarding: the brain chosen in Settings did not answer: \(problem ?? "")")
                handoff = waiting
            }
        }
    }

    /// The brain chosen next door answers: the tick, Say hello, and this
    /// window back in front of the one the person was working in.
    private func brainConnected(_ provider: BrainProviderKind) {
        handoff = nil
        let next = signIn.connected(provider)
        // Skipped ahead while it was being set up: the tick is recorded,
        // and the person is left on the screen they chose to go to.
        guard step == .brain else { return }
        step = next
        comeForward()
    }

    private func sayHelloMayBeDone() {
        guard step == .tryIt, !rehearsal, !snapshot, sayHelloIsDone else { return }
        // A beat, then look again: between two sentences of one answer Moe
        // is quiet for a moment, and that is not the end of it.
        later(0.8) {
            guard step == .tryIt, sayHelloIsDone, let next = step.next else { return }
            step = next
        }
    }

    private var sayHelloIsDone: Bool {
        Onboarding.sayHelloFinished(roles: conductor.turns.dropFirst(sayHelloBaseline).map(\.role),
                                    mode: conductor.mode)
    }

    private var screen: some View {
        Group {
            switch step {
            case .welcome:    welcome
            case .microphone: microphone
            case .brain:      brain
            case .tryIt:      tryIt
            case .dictate:    dictate
            case .meetings:   meetings
            case .learn:      learnScreen
            case .connect:    connect
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.generous)
        .padding(.top, Theme.Space.generous + Theme.Space.small)
        .padding(.bottom, Theme.Space.cosy)
    }

    // MARK: - 1. Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Hi, I'm Moe.")
            prose("I live in the little pill at the top of your screen. Here is what I can do.")
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                bullet("bubble.left.and.bubble.right", "Answer out loud.", "Hold a key, ask, let go.")
                if Features.dictation {
                    bullet("text.cursor", "Type what you say.", "In any app, right where your cursor is.")
                }
                bullet("waveform.circle", "Take meeting notes.", "Both sides of the call, kept on this Mac.")
                bullet("brain", "Remember you.", "In plain writing you can read and change.")
                bullet("link", "Reach your things.", "Mail, calendar, files, apps — only what you connect.")
            }
            // You are early, said once, on the first screen — warmly, and
            // not again on the other six. A person who has just opened an
            // app has not earned a warning; what they have earned is
            // knowing where they stand and what to do when it wobbles.
            prose("One thing first: I'm in beta. You'll meet bugs and rough corners — and when you do, just tell me, out loud or in writing. It reaches the one person building me, and it is the most useful thing you can do.")
            small("\(Step.shown.count - 1 == 7 ? "Seven" : "Six") short steps. Skip any of them — nothing here is permanent.")
            primary("Let's go") { step = .microphone }
        }
    }

    // MARK: - 2. Microphone

    private var microphone: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Can I hear you?")
            prose("I listen only while you hold the talk key. Your voice is turned into words here on this Mac and is never sent anywhere.")
            if micDenied {
                card {
                    PermissionExplainer(guide: .microphone,
                                        lead: "You said no — that's fine, and Moe still works.",
                                        showWhat: false)
                }
                primary("Next") { step = .brain }
            } else if micAsked {
                done("The microphone is on.")
                primary("Next") { step = .brain }
            } else {
                small("macOS will ask you to confirm.")
                primary("Turn on the microphone") {
                    if rehearsal {
                        // Stands in for the macOS prompt: a beat, then yes.
                        later(1.2) { micAsked = true; step = .brain }
                        return
                    }
                    Task {
                        let ok = await VoiceEngine.requestMicrophone()
                        micAsked = true
                        micDenied = !ok
                        if ok { step = .brain }
                    }
                }
            }
        }
    }

    // MARK: - 3. Something to think with

    /// Four rows, not eleven: the question a person can answer is "what do
    /// you already pay for?" (BrainPath). A Claude plan and a ChatGPT plan
    /// are the recommendation, equally (docs/DEFAULTS.md row 1): the first
    /// two rows, both badged, both filled buttons. Keys and local models
    /// sit below them.
    private var brain: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Give me something to think with")
            prose("Moe costs you nothing and has no account of its own. Pick the one you already use — the account, and any bill, stay with them.")

            // Before any of the four paths can work, the part that runs them
            // has to exist. On a Mac that only downloaded Moe it does not —
            // so that is the whole screen until it does. One thing at a time:
            // four dimmed choices under an install button read as five things
            // to do, and did not fit the window.
            if !bootstrapDone, seeding {
                // A downloaded copy: the thinking part ships inside the app
                // and is being copied out since launch. Nothing to press.
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("Getting ready")
                        cardText("Setting up the part of me that thinks. It's already inside the app, so nothing is downloaded — this takes a few seconds. Then you'll pick whose account I borrow.")
                        progressLine("Almost there…")
                    }
                }
            } else if !bootstrapDone {
                // No seed in this build, or it failed: the network installer,
                // behind one button, with the honest size.
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("One thing first")
                        cardText("The part of me that does the thinking isn't on this Mac yet. Moe can download it — about a gigabyte, once — and you don't have to do anything while it runs. Then you'll pick whose account I borrow.")
                        if installing {
                            progressLine(installLine)
                        } else {
                            HStack(spacing: Theme.Space.base) {
                                PillButton(title: "Set it up", action: runBootstrap)
                                if !installLine.isEmpty { progressText(installLine) }
                            }
                        }
                    }
                }
            } else if signedIn {
                // The choice is made: the four cards would only be a list of
                // things not chosen, and with the confirmation and the
                // button they did not fit the window.
                done(signIn.line + " " + capabilityLine)
                small("Change this any time in Settings › Brain.")
                primary("Next") { step = .tryIt }
            } else if let handoff {
                // Settings › Brain is open beside this window. One card:
                // what to do there, and that this screen is waiting.
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle(Onboarding.BrainHandoff.title)
                        cardText(handoff.steps)
                        switch handoff.phase {
                        case .waiting:
                            progressLine(Onboarding.BrainHandoff.waiting)
                        case .checking:
                            progressLine(Onboarding.BrainHandoff.checking)
                        case .problem(let problem):
                            note(Onboarding.BrainHandoff.failed(problem))
                        }
                        HStack(spacing: Theme.Space.base) {
                            PaneButton(title: "Show Settings › Brain") {
                                if !rehearsal { openSection(.brain) }
                            }
                            if handoff.way == .free {
                                PaneButton(title: "Open aistudio.google.com", symbol: "arrow.up.forward.app") {
                                    if !rehearsal, let url = URL(string: Onboarding.freeStartLink) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            PaneButton(title: "Pick another way") { self.handoff = nil }
                        }
                        .padding(.top, Theme.Space.tight)
                    }
                }
                small("Rather do this later? Skip — Say hello will tell you nothing is thinking yet, and Settings › Brain is always there.")
            } else {
            VStack(spacing: Theme.Space.small) {
                pathRow(.claude, filled: true) { startClaudeSignIn() }
                pathRow(.chatgpt, filled: true) {
                    // In the app, not in Terminal: the sheet shows the code
                    // and the link, and opens the page itself.
                    chatgptFlow.rehearsal = rehearsal
                    // Signing in is choosing: the old Terminal flow ended on
                    // "back in Moe, choose ChatGPT and press Apply", a step
                    // onboarding never showed anyone.
                    chatgptFlow.onStored = {
                        Task {
                            let (written, sel) = await Task.detached(priority: .userInitiated) {
                                // A model this account offers, not a guess.
                                let sel = BrainSelection(provider: .codex,
                                                         model: BrainSetup.startingModel(for: .codex),
                                                         reasoningEffort: "")
                                return (BrainSetup.apply(sel, baseURL: "", key: nil), sel)
                            }.value
                            if case .failure(let f) = written {
                                // Stored, but not made the choice: back to
                                // the rows, with the reason.
                                signIn.undo()
                                brainNote = f.message
                                step = .brain
                                return
                            }
                            conductor.applyBrain(sel, baseURL: "", polishModel: "", restartGateway: true)
                        }
                    }
                    showChatGPT = true
                }
                .sheet(isPresented: $showChatGPT) {
                    ChatGPTSignInSheet(flow: chatgptFlow) { ok in
                        showChatGPT = false
                        signInFinished(.chatgpt, ok: ok)
                    }
                }
                pathRow(.key, filled: false) { leaveForBrainPane(.key) }
                pathRow(.onThisMac, filled: false) { leaveForBrainPane(.onThisMac) }
                // For someone who pays for no AI at all: its own row, not a
                // clause at the end of the key row's description.
                freeStartRow
            }
            .disabled(installing)
            .opacity(installing ? 0.45 : 1)

            if installing {
                progressLine(installLine)
            } else if signInToolFailed {
                // Said, with a way to try again: this used to be a spinner
                // that vanished and four rows that looked untouched.
                // In the skip line's place, on one row: with both, the screen
                // no longer fitted the window.
                HStack(alignment: .center, spacing: Theme.Space.base) {
                    note(Onboarding.signInToolFailed)
                    Spacer(minLength: 0)
                    PaneButton(title: "Try again") { startClaudeSignIn() }
                }
            } else if !brainNote.isEmpty {
                progressText(brainNote)
            }

            if !signInToolFailed {
                small(Features.dictation
                      ? "Not sure? Skip it. Dictation still types what you say and meetings still get their notes. Only answering a question needs this — Settings › Brain, whenever you like."
                      : "Not sure? Skip it. Meetings still get their notes. Only answering a question needs this.")
            }
            }
        }
        // The answer changes underneath this screen: the user may have set it
        // up from Settings, or come back after an install finished.
        .onAppear(perform: refreshBootstrap)
        // The seed landed while this screen was up: the card gives way to
        // the four choices without anyone pressing anything.
        .onChange(of: seed.phase) { _, phase in
            if phase == .done, !snapshot, !rehearsal { bootstrapDone = Bootstrap.hermesInstalled() }
        }
    }

    /// The Claude row: the sheet, once the tool that does the signing is
    /// here. Moe fetches it at the moment it is chosen; a download that
    /// fails says so and offers this again.
    private func startClaudeSignIn() {
        signInToolFailed = false
        if claudeReady {
            showSignIn = true
        } else if rehearsal {
            installing = true
            installLine = "Getting the sign-in tool…"
            later(1.5) { installLine = "✓ Claude Code installed" }
            later(2.5) { installing = false; claudeReady = true; showSignIn = true }
        } else {
            installing = true
            installLine = "Getting the sign-in tool…"
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = Bootstrap.installClaudeCLI { line in
                    DispatchQueue.main.async { installLine = line }
                }
                DispatchQueue.main.async {
                    installing = false
                    claudeReady = ClaudeSignIn.claudePath() != nil
                    if ok && claudeReady {
                        showSignIn = true
                    } else {
                        Log.write("onboarding: the sign-in tool did not install (ok=\(ok)): \(installLine)")
                        signInToolFailed = true
                    }
                }
            }
        }
    }

    /// Whether the Python side is on this Mac yet. Checked when the screen
    /// appears rather than held in a config value, because the answer changes
    /// underneath us. Not in a snapshot, which is posing a state on purpose.
    private func refreshBootstrap() {
        guard !snapshot else { return }
        if rehearsal {
            // A downloaded copy's first launch: the seed lands a few seconds
            // after the screen is reached, and the choices appear.
            if !bootstrapDone, posedSeeding {
                later(4.0) { posedSeeding = false; bootstrapDone = true }
            }
            return
        }
        bootstrapDone = Bootstrap.hermesInstalled()
        claudeReady = ClaudeSignIn.claudePath() != nil
        // Back on this screen with a key or a local model already chosen —
        // the welcome was closed while Settings › Brain was open: the tick,
        // not four rows of things already done.
        let provider = conductor.config.brainProvider
        if !signedIn, handoff == nil, Onboarding.alreadyThinking(with: provider) {
            signIn = Onboarding.SignIn(account: provider.shortName, viaSettings: true)
        }
    }

    /// Runs the installer the app carries, streaming its own ✓/✗ lines.
    /// Off the main thread: it is a download of about a gigabyte, and the
    /// window has to keep drawing. Skip stays on the screen throughout.
    private func runBootstrap() {
        installing = true
        installLine = "Starting…"
        if rehearsal {
            // The real thing prints these lines over about ninety seconds.
            let script = ["› Setting up the part of Moe that thinks. This takes a minute or two.",
                          "✓ uv 0.12.7 installed (sha256 verified)",
                          "✓ Python installed: Python 3.14",
                          "✓ hermes-agent cloned",
                          "✓ venv synced: 212 packages",
                          "✓ Ready. Now choose how Moe should think."]
            for (i, line) in script.enumerated() { later(Double(i) * 0.9) { installLine = line } }
            later(Double(script.count) * 0.9) { installing = false; bootstrapDone = true; installLine = "" }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Bootstrap.installHermes { line in
                DispatchQueue.main.async { installLine = line }
            }
            DispatchQueue.main.async {
                installing = false
                bootstrapDone = ok || Bootstrap.hermesInstalled()
                if bootstrapDone { installLine = "" }
            }
        }
    }

    /// What the chosen provider's own default model can and can't do, from
    /// the capability table rather than from an assumption that they are all
    /// the same (BrainCapabilityTable.lookup).
    private var capabilityLine: String {
        let cfg = conductor.config
        if let cost = BrainGuide.capabilityCost(provider: cfg.brainProvider, model: cfg.brainModel) {
            return cost
        }
        return "I can see your screen when you ask, and use everything you connect."
    }

    /// The no-plan row: one line of what is honestly free, and a button
    /// that stays in the flow like the two above it.
    private var freeStartRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.cosy) {
            // A strip, not a fifth card: the question in bold and the
            // answer after it, so the screen still fits its window.
            (Text(Onboarding.freeStartTitle)
                .font(Theme.Typo.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
             + Text(" " + Onboarding.freeStartWhat)
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.base)
            PaneButton(title: Onboarding.freeStartAction) { leaveForBrainPane(.free) }
        }
        .padding(.horizontal, Theme.Space.cosy)
        .padding(.vertical, Theme.Space.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.accentTint.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
        )
    }

    private func pathRow(_ path: BrainPath, filled: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.cosy) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.small) {
                    Text(path.title)
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if path.recommended {
                        Text("Recommended")
                            .font(Theme.Typo.label(9))
                            .tracking(Theme.tracking)
                            .foregroundStyle(Theme.accentDeep)
                            .padding(.horizontal, Theme.Space.small)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentTint))
                    }
                }
                Text(path.whatItIs)
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.base)
            // The two recommendations are the filled buttons on the screen —
            // that, the badge, and being first, is the whole of "recommended".
            if filled {
                PillButton(title: path.action, action: action)
            } else {
                PaneButton(title: path.action, action: action)
            }
        }
        // A little shallower than a card: five rows have to fit the window.
        .padding(.horizontal, Theme.Space.cosy)
        .padding(.vertical, Theme.Space.base - Theme.Space.hair)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(filled ? Theme.accent.opacity(0.5) : Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
        )
    }

    // MARK: - 4. Say hello

    /// True when a question asked right now would get an answer: the
    /// thinking part is installed, and — for the Claude path — a sign-in is
    /// stored. Anything else is told on the screen rather than discovered as
    /// a failed first question.
    private var brainReady: Bool {
        guard bootstrapDone else { return false }
        if conductor.config.brainProvider == .claudeCode {
            return signedIn || (!snapshot && HermesKey.childOAuthTokenExists())
        }
        return true
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Say hello")
            // Only ever a way that works right now: the held key is the
            // lead once macOS lets Moe see it, and not before.
            prose(Onboarding.sayHelloLead(accessibility: accessibility, holdKey: holdKey,
                                          whereItIs: conductor.config.talkKey.whereItIs, shortcut: shortcut))
            if accessibility {
                small("Or double-tap that key and just talk, nothing held — tap it again to send. Double-tap while I'm talking or working to stop me. \(shortcut) starts and stops me too.")
            }

            // First, while it is off: it is what the key in every other
            // sentence about Moe is waiting for.
            if !accessibility {
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("Accessibility")
                        cardText(Onboarding.accessibilityWhy)
                        small("Allow it and you can hold \(holdKey) — \(conductor.config.talkKey.whereItIs) — from any app instead. No rush: skip it and nothing breaks.")
                        if accessibilityAsked {
                            // No "Quit and reopen": the key arms the moment
                            // the grant lands, and this card goes with it.
                            progressLine(Onboarding.accessibilityWaiting(holdKey: holdKey))
                            PaneButton(title: "Open Accessibility settings") {
                                if !rehearsal { openPane(.accessibility) }
                            }
                            // Asked in an earlier launch and still off.
                            // Most often Moe is ON in System Settings — an
                            // entry left by an earlier copy, signed
                            // differently, that macOS shows and refuses. The
                            // owner met exactly this on 2026-09-10 and had no
                            // way out but a terminal.
                            if !rehearsal, !snapshot, ax.staleSuspected {
                                cardText("Already switched on, and still not working? macOS is remembering an older copy of Memoe. Reset clears it — then switch Memoe on once more.")
                                PaneButton(title: "Reset and ask again") { ax.fix() }
                            }
                        } else {
                            PillButton(title: "Allow it") {
                                accessibilityAsked = true
                                // In rehearsal the wait is a beat, then yes.
                                if rehearsal { later(2.5) { accessibility = true }; return }
                                // The system prompt adds Moe to the list and
                                // offers to open the pane itself — one click,
                                // no "+". macOS shows it once; if it was
                                // declined before, the button that opens the
                                // pane is on the next line.
                                PushToTalk.requestAccessibility()
                            }
                        }
                    }
                }
            }

            if !brainReady {
                note("I can hear you, but nothing is thinking for me yet, so I can't answer. Go back a step, or set it up later in Settings › Brain.")
            }

            // docs/DEFAULTS.md row 33: asked here, not on first use, so a
            // first "what's on my screen?" does not fail. One button, the
            // same ask-then-open-the-list path Settings › Permissions takes
            // (ScreenPermission.allow). Skippable; nothing waits on it.
            if !screenRecording {
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("Screen Recording")
                        cardText(Onboarding.screenRecordingWhy)
                        if screenAsked {
                            cardText("Switched it on? It takes effect the next time Moe opens. Rather not? Skip it — Moe asks again the first time you want it to look.")
                            PaneButton(title: "Open Screen Recording settings") {
                                if !rehearsal { ScreenPermission.openSettings() }
                            }
                        } else {
                            PillButton(title: "Allow it") {
                                screenAsked = true
                                if rehearsal { screenRecording = true; return }
                                // Asking is what puts Moe on the list at all.
                                // Only ask: CGRequestScreenCaptureAccess
                                // returns false while its own first-time
                                // alert is still on screen, and opening
                                // System Settings on that answer put the list
                                // on top of the alert. After a refusal the
                                // ask shows nothing — the card now offers
                                // the list, one press away.
                                if ScreenPermission.request() { screenRecording = true }
                            }
                        }
                    }
                }
            }

            // The helper's own switches are not asked for here — it may not
            // be on this Mac yet, and they are its to ask for. Named now,
            // so "CuaDriver" is not a stranger when macOS brings it up.
            small(Onboarding.screenHelperNote)

            HStack(spacing: Theme.Space.cosy) {
                primary("Talk to me") {
                    if rehearsal {
                        // Listen, think, answer, move on — the shape of a
                        // real first exchange, with nobody talking.
                        rehearsalMode = .listening
                        later(2.5) { rehearsalMode = .thinking }
                        later(4.0) { rehearsalMode = .speaking }
                        later(6.0) { rehearsalMode = .idle; if let next = step.next { step = next } }
                    } else {
                        conductor.toggle()
                    }
                }
                // A spinner that is always spinning tells you nothing. This
                // one runs only while Moe is actually doing something.
                if mode != .idle {
                    progressLine(listeningLine).padding(.top, Theme.Space.tight)
                } else if let warming = warmUpLine {
                    // The same line the island shows while the models load:
                    // a first press that seems to do nothing is explained
                    // where the person is looking.
                    progressLine(warming).padding(.top, Theme.Space.tight)
                }
            }
        }
    }

    private var mode: Conductor.Mode { rehearsal ? rehearsalMode : conductor.mode }

    private var warmUpLine: String? {
        guard !rehearsal, !snapshot else { return nil }
        return Onboarding.warmUpLine(status: conductor.statusLine,
                                     voiceReady: conductor.voice.isReady, mode: mode)
    }

    private var listeningLine: String {
        switch mode {
        case .listening: return "I'm listening — say anything."
        case .thinking:  return "Thinking…"
        case .speaking:  return "Answering…"
        case .idle:      return ""
        }
    }

    private func openPane(_ guide: PermissionGuide) {
        if let url = guide.settingsURL { NSWorkspace.shared.open(url) }
    }

    // MARK: - 5. Dictation

    /// Shown only while `Features.dictation` (docs/DEFAULTS.md row 4); kept
    /// whole for when it comes back. On by default then
    /// (Config.dictationEnabled), a different key from the talk key on
    /// purpose, and it needs the same Accessibility grant to put the words
    /// where the cursor is (TextInserter.insert).
    private var dictate: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("I'll type what you say")
            prose("Hold \(dictationKey) in any app, say your sentence, and let go. The words appear where your cursor is — tidied up, ums taken out, and I never answer them.")
            small("Double-tap the key to keep listening with nothing held down. Escape stops.")
            if conductor.config.dictationPolish {
                small("The last bit of tidying asks your AI to read the sentence. Turn that off in Settings › Voice if you'd rather nothing you dictate leaves this Mac.")
            }
            HStack(spacing: Theme.Space.base) {
                Text("Key to hold")
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if snapshot {
                    // An AppKit menu does not rasterise; the snapshot draws
                    // the value the way the menu's label draws it.
                    Text(conductor.config.dictationKey.displayName)
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                } else {
                    SettingMenu(value: conductor.config.dictationKey.displayName) {
                        Picker("", selection: Binding(
                            get: { conductor.config.dictationKey },
                            set: { conductor.setDictationKey($0) })) {
                                ForEach(DictationKey.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.inline)
                    }
                }
            }
            if !accessibility {
                note("Until you allow Accessibility (the step before this one), I can't put the words in for you. They go to your clipboard instead — press ⌘V.")
            }
            primary("Got it") { step = .meetings }
        }
    }

    // MARK: - 6. Meetings

    /// Checked against Sources/MoeMeeting: the consent sheet
    /// (AppDelegate.confirmMeeting, on by default via
    /// Config.meetingAskBeforeStart), the red ring (IslandView.meetingRing),
    /// the two audio streams (MicCapture and ProcessTap), the folder
    /// (Paths.meetings) and the audio deletion default
    /// (Config.meetingDeleteRecordings).
    private var meetings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("I'll take the notes")
            prose("Start a meeting from the Meetings tab. I hear both sides of the call, and when you stop I write the notes and the action items.")
            prose("It all stays on this Mac. I ask before I start, and the ring around the notch stays red the whole time — so tell the room.")
            HStack(spacing: Theme.Space.base) {
                if snapshot {
                    // An AppKit switch does not rasterise; a snapshot draws
                    // the off state it is in by default.
                    Capsule().fill(Theme.ruleStrong).frame(width: 26, height: 15)
                        .overlay(alignment: .leading) {
                            Circle().fill(Theme.raised).frame(width: 13, height: 13).padding(1)
                        }
                } else {
                    Toggle("", isOn: Binding(
                        get: { conductor.config.meetingHotkey },
                        set: { conductor.setMeetingHotkey($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start and stop a meeting with ⌃⌥M")
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("Off unless you switch it on — a key that records other people should be your choice.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            primary("Next") { step = .learn }
        }
    }

    // MARK: - 7. What may I read to learn about you

    /// The front door to the daily pass. The switches, the sentence and the
    /// writer are LearnStep.swift's; this screen is the chrome around them.
    /// Next records what was ticked and moves on; Skip (the footer) records
    /// nothing at all — see BackgroundLearning.stepWrites.
    private var learnScreen: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title(LearnStepCopy.title)
            prose(LearnStepCopy.lead)
            LearnStepBody(model: learn, snapshot: snapshot)
            small(LearnStepCopy.detail)
            primary(learn.hasChoice ? LearnStepCopy.save : LearnStepCopy.next) {
                if rehearsal || snapshot { step = .connect; return }
                Task {
                    // Wait for the file: the sheet that asks about the pass
                    // reads it two seconds after onboarding closes, and a
                    // write still in flight would read as "never asked".
                    if await learn.save() { step = .connect }
                }
            }
            .disabled(learn.saving)
        }
        .onAppear { learn.load() }
    }

    // MARK: - 8. Connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Connect your world")
            // Two screens now, and this used to promise both on one. It sent
            // people to Connections saying "messages", and the messaging apps
            // had moved to the screen below it — the only automatic way into
            // this part of the app, landing one row short of what it named.
            prose("Mail, files, the apps you work in — one button each on the next screen. Beside it, Message Moe: set up Telegram or WhatsApp and you can text me from your phone. Nothing is connected until you say so, and before I send anything for you I show you the words and wait for a yes.")
            // docs/DEFAULTS.md row 34 (slice 13): what to connect first, in
            // the order the Connections list now draws it
            // (ConnectionsCatalog.firstMac, then firstGoogle).
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                bullet("desktopcomputer", "Start with this Mac.",
                       ConnectionsCatalog.firstMacWords + " — the apps already here. macOS asks you once for each.")
                bullet("envelope", "Then Google.",
                       ConnectionsCatalog.firstGoogleWords + " — one sign-in covers all three.")
                bullet("ellipsis.circle", "Then anything else.",
                       "Messages and hundreds more are in the list under them.")
            }
            prose("When there's something worth knowing — a meeting soon, a message from someone you know — I glow amber. Tap the glow and I'll tell you. Settings › Background switches the nudge off.")
            small("What I remember about you is in the Memory tab, in plain writing. Change a line, or throw the lot out. And all of this runs on this Mac: while it sleeps, I sleep.")
            // Rows 30 and 28, folded into this screen (row 40). Above the
            // button, not under it: the button closes the welcome, so rows
            // drawn below it were rows most people never saw.
            Rectangle().fill(Theme.rule).frame(height: 1)
            switchRow(title: Onboarding.launchAtLoginTitle,
                      detail: "On, so I'm here under the notch when you sign in. System Settings › General › Login Items has the same switch.",
                      isOn: Binding(get: { launchAtLogin }, set: { on in
                          launchAtLogin = on
                          // The rehearsal and the snapshot touch no login item.
                          if !rehearsal, !snapshot { conductor.setLaunchAtLogin(on) }
                      }))
            problemReportsRow
            primary("Take me to Connections") {
                openConnections()
                completeWelcome()
                finish()
            }
        }
    }

    /// "Let Moe send problem reports": off, and the switch is the real one —
    /// the same call Settings › Privacy makes, which records the yes with the
    /// Moe team on a signed-in Mac and fails closed when it cannot. Reports
    /// go to Memoe's cloud, so a build without one has no row.
    @ViewBuilder
    private var problemReportsRow: some View {
        if let reports = Cloud.link.problemReports {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            switchRow(title: Onboarding.problemReportsTitle,
                      detail: "Off unless you switch it on. When something breaks and you ask me to report it, this is what lets the report reach the one person building me.",
                      isOn: Binding(get: { reportsOn }, set: { setReports($0) }),
                      enabled: !reportsWorking,
                      control: "onboarding-problem-reports")
            Button(action: { showReportsDetail.toggle() }) {
                Text(reportsDetailLabel)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.accentDeep)
            }
            .buttonStyle(.plain)
            if showReportsDetail {
                // The audited text, one copy, shared with Settings › Privacy.
                small(reports.disclosure)
            }
            switchRow(title: reports.anonymousTitle,
                      detail: reports.anonymousDetail,
                      isOn: reports.anonymousBinding(conductor, posed: rehearsal || snapshot))
            if !reportsNote.isEmpty { note(reportsNote) }
        }
        }
    }

    private var reportsDetailLabel: String {
        showReportsDetail ? "Hide what is sent" : (Cloud.link.problemReports?.disclosureLabel ?? "")
    }

    private func setReports(_ on: Bool) {
        guard !reportsWorking else { return }
        if rehearsal || snapshot { reportsOn = on; return }
        guard let reports = Cloud.link.problemReports else { return }
        reportsWorking = true
        reportsNote = ""
        Task {
            let outcome = await reports.turn(on, conductor: conductor)
            reportsOn = outcome.on
            reportsWorking = false
            reportsNote = outcome.problem ?? ""
        }
    }

    /// A switch with its title and one line under it. An AppKit switch does
    /// not rasterise, so a snapshot draws a still one in its state.
    /// `control` makes it a switch only a person can flip — the same
    /// `HumanLever` Settings › Privacy uses for the same setting, so an
    /// accessibility press or a posted event cannot turn problem reports on
    /// here either. A rehearsal records nothing, so it keeps a plain switch.
    private func switchRow(title: String, detail: String, isOn: Binding<Bool>,
                           enabled: Bool = true, control: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            Group {
                if snapshot {
                    Capsule().fill(isOn.wrappedValue ? Theme.accent : Theme.ruleStrong)
                        .frame(width: 26, height: 15)
                        .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                            Circle().fill(Theme.raised).frame(width: 13, height: 13).padding(1)
                        }
                } else if let control, !rehearsal {
                    HumanLever(control: control, value: isOn, enabled: enabled)
                } else {
                    Toggle("", isOn: isOn)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                        .disabled(!enabled)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    // MARK: - Chrome

    /// Back and Skip on every screen, and the dots. Nobody is ever stuck.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: Theme.Space.base) {
                Button("Back") { back() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .disabled(step == .welcome)
                    .opacity(step == .welcome ? 0 : 1)
                Spacer()
                dots
                Spacer()
                Button(step.skipLabel) { skip() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.base)
        }
        .background(Theme.sidebar)
    }

    /// The last screen's way out — Take me to Connections, or Not now. Tells
    /// the window the welcome was finished (the login item, row 30). Not for
    /// the brain screen's early exit, and never in a rehearsal or snapshot.
    private func completeWelcome() {
        guard !rehearsal, !snapshot else { return }
        completed()
    }

    private func back() {
        guard let i = Step.shown.firstIndex(of: step), i > 0 else { return }
        step = Step.shown[i - 1]
    }

    private func skip() {
        if step == .learn {
            // Skipped, not refused: nothing recorded, and the rows it
            // showed are asked about again in a week (LearnStepModel).
            learn.markShownOff(all: true)
        }
        guard let i = Step.shown.firstIndex(of: step), i + 1 < Step.shown.count else {
            if step == .connect { completeWelcome() }
            finish(); return
        }
        step = Step.shown[i + 1]
    }

    // MARK: - Pieces

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.display(30))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.prose(15))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(12))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    /// Something the person should know before pressing the button: shown
    /// in the warn colour, never as a blocker.
    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warn)
            Text(text)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    private func done(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.good)
            Text(text)
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: Theme.Space.small) {
            if snapshot {
                // A spinner does not rasterise; the snapshot draws a still one.
                Circle().stroke(Theme.ink3, lineWidth: 1.5).frame(width: 12, height: 12)
            } else {
                ProgressView().controlSize(.small)
            }
            progressText(text)
        }
    }

    private func progressText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(12))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(Theme.accentDeep)
            Text(lead)
                .font(Theme.Typo.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            + Text(" " + rest)
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.cosy)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
            )
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(13, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }

    private func cardText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.prose(13))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ label: String, action: @escaping () -> Void) -> some View {
        PillButton(title: label, large: true, action: action)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Theme.Space.tight)
    }

    private var dots: some View {
        HStack(spacing: Theme.Space.snug) {
            ForEach(Step.shown) { s in
                Circle()
                    .fill(s == step ? Theme.accent : Theme.ruleStrong)
                    .frame(width: 6, height: 6)
            }
        }
    }
}
