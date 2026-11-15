import Foundation
import Testing
@testable import Moe

/// docs/MASTER-PLAN-2026-11-12.md, "First-run M items":
///
///   1  a key or a local model keeps the welcome going, to Say hello
///   2  a visible, honest way in for someone with no AI plan
///   3  Memoe's Accessibility switch is not sold as "click for you"
///   4  a copy opened from its disk image offers the move to Applications
///   5  Settings › Permissions does not ask for a restart Accessibility
///      does not need
///   6  a language that will not load says so in plain words

private func source(_ path: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(path), encoding: .utf8)
}

/// The body of a Swift function, from its `func name(` to the next blank
/// line at the same depth — enough to ask what one function does.
private func body(of name: String, in text: String) -> String {
    guard let start = text.range(of: "func \(name)(") else { return "" }
    let rest = text[start.lowerBound...]
    let end = rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex
    return String(rest[..<end])
}

struct FirstRunBrainHandoffTests {
    typealias Handoff = Onboarding.BrainHandoff
    private let unset = Handoff.Brain(provider: .claudeCode, model: "", baseURL: "")
    private let gemini = Handoff.Brain(provider: .gemini, model: "gemini-2.5-flash", baseURL: "")

    // MARK: 1 — the flow, as a person makes it

    @Test("Use a key → a key lands in Settings › Brain → it answers → Say hello, with a tick",
          arguments: Handoff.Way.allCases)
    func keyRowReachesSayHello(way: Handoff.Way) {
        var handoff = Handoff(way: way, brain: unset, connected: false)
        var signIn = Onboarding.SignIn()

        // Settings › Brain is open; nothing chosen yet.
        do { let r = handoff.observe(unset, connected: false, usable: false); #expect(!r) }
        #expect(handoff.phase == .waiting)
        // The choice is written and the brain restarts on it…
        do { let r = handoff.observe(gemini, connected: false, usable: true); #expect(!r) }
        #expect(handoff.phase == .waiting)
        // …and comes back: now it is asked one question.
        do { let r = handoff.observe(gemini, connected: true, usable: true); #expect(r) }
        #expect(handoff.phase == .checking)
        // It answered. The welcome is not over: it is on Say hello.
        do { let r = handoff.checked(problem: nil); #expect(r) }
        do { let r = signIn.connected(gemini.provider); #expect(r == .tryIt) }
        #expect(signIn.signedIn)
        #expect(signIn.line == "I'm thinking with Google Gemini now.")
    }

    @Test("the key and local-model rows open Settings › Brain and do not end the welcome")
    func rowsDoNotFinish() throws {
        let window = try source("Sources/Moe/Onboarding/OnboardingWindow.swift")
        let leave = body(of: "leaveForBrainPane", in: window)
        #expect(leave.contains("openSection(.brain)"))
        // `finish()` closes the window and marks the welcome done.
        #expect(!leave.contains("finish()"))
        #expect(leave.contains("handoff = Onboarding.BrainHandoff("))
        // Every row that is not a plan sign-in goes through it.
        for way in ["leaveForBrainPane(.key)", "leaveForBrainPane(.onThisMac)", "leaveForBrainPane(.free)"] {
            #expect(window.contains(way), "\(way)")
        }
        // …and arriving moves to Say hello through the one function.
        let arrive = body(of: "brainConnected", in: window)
        #expect(arrive.contains("let next = signIn.connected(provider)"))
        #expect(arrive.contains("step = next"))
    }

    @Test("leaving for Settings is not finishing: the place is kept, and a relaunch comes back")
    func handoffKeepsThePlace() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-first-run-m-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // The window is closed while Settings › Brain is open.
        Onboarding.record(.closed(at: .brain), in: home)
        #expect(!Onboarding.done(in: home))
        #expect(Onboarding.atLaunch(done: false, resume: Onboarding.resumeScreen(in: home),
                                    firstRun: false, signedIn: false) == .welcome(at: .brain))
        // Back on that screen with the key already in: a tick, not the rows.
        #expect(Onboarding.alreadyThinking(with: .gemini))
        #expect(Onboarding.alreadyThinking(with: .lmStudio))
        #expect(!Onboarding.alreadyThinking(with: .claudeCode))
        #expect(!Onboarding.alreadyThinking(with: .codex))
    }

    @Test("a new key for the same company counts: the brain went away and came back")
    func sameProviderNewKey() {
        var handoff = Handoff(way: .key, brain: gemini, connected: true)
        do { let r = handoff.observe(gemini, connected: true, usable: true); #expect(!r) }
        do { let r = handoff.observe(gemini, connected: false, usable: true); #expect(!r) }
        do { let r = handoff.observe(gemini, connected: true, usable: true); #expect(r) }
    }

    @Test("a brain that is merely still there is not a choice")
    func nothingChangedNothingHappens() {
        var handoff = Handoff(way: .key, brain: gemini, connected: true)
        for _ in 0..<3 { let r = handoff.observe(gemini, connected: true, usable: true); #expect(!r) }
        #expect(handoff.phase == .waiting)
        // Down when the person left, up later: still not a choice.
        var down = Handoff(way: .key, brain: gemini, connected: false)
        do { let r = down.observe(gemini, connected: true, usable: true); #expect(!r) }
    }

    @Test("a restart with no sign-in stored is not something to think with")
    func planWithNoSignIn() {
        var handoff = Handoff(way: .key, brain: unset, connected: true)
        do { let r = handoff.observe(unset, connected: false, usable: false); #expect(!r) }
        do { let r = handoff.observe(unset, connected: true, usable: false); #expect(!r) }
    }

    @Test("a key that does not answer stays on the card, and the next try is checked again")
    func problemStaysAndRetries() {
        var handoff = Handoff(way: .key, brain: unset, connected: true)
        do { let r = handoff.observe(gemini, connected: true, usable: true); #expect(r) }
        // Asked once, however many times the brain is seen while checking.
        do { let r = handoff.observe(gemini, connected: true, usable: true); #expect(!r) }
        do { let r = handoff.checked(problem: "That key was refused."); #expect(!r) }
        #expect(handoff.phase == .problem("That key was refused."))
        #expect(Handoff.failed("That key was refused.").contains("Settings › Brain"))
        // A second key: the brain restarts, and it is asked again.
        do { let r = handoff.observe(gemini, connected: false, usable: true); #expect(!r) }
        do { let r = handoff.observe(gemini, connected: true, usable: true); #expect(r) }
        do { let r = handoff.checked(problem: nil); #expect(r) }
    }

    @Test("the card says what to press, in the pane's own words", arguments: Handoff.Way.allCases)
    func cardNamesTheButtons(way: Handoff.Way) throws {
        let handoff = Handoff(way: way, brain: unset, connected: true)
        #expect(handoff.steps.contains("Change account…"))
        #expect(handoff.steps.contains("press Use"))
        let pane = try source("Sources/Moe/Settings/BrainPane.swift")
        #expect(pane.contains("PaneButton(title: \"Change account…\")"))
        #expect(pane.contains("\"Use \\(chosen.shortName)\""))
        #expect(Handoff.waiting.contains("nothing to restart"))
    }

    // MARK: 2 — no plan

    @Test("someone with no AI plan has a row of their own, and it promises only what is true")
    func freeStart() throws {
        #expect(Onboarding.freeStartTitle.contains("No AI plan"))
        // What is free is Google's allowance and a local model — said as
        // theirs, with what comes after the allowance.
        #expect(Onboarding.freeStartWhat.contains("Google Gemini"))
        #expect(Onboarding.freeStartWhat.contains("Google's daily allowance"))
        // What comes after the allowance is said where the key is fetched.
        #expect(Handoff(way: .free, brain: unset, connected: true).steps.contains("then pennies a question"))
        #expect(Onboarding.freeStartWhat.contains("on this Mac"))
        #expect(Onboarding.freeStartAction == "Start free")
        // The same claim the provider's own entry makes; if that changes,
        // this row has to change with it.
        #expect(BrainGuide.find(.gemini).cost.contains("Free up to Google's daily allowance"))
        #expect(BrainGuide.find(.lmStudio).cost.hasPrefix("Free."))
        // Never "Memoe gives you a free AI".
        for claim in ["free AI", "free forever", "unlimited", "no card", "no limits"] {
            #expect(!Onboarding.freeStartWhat.localizedCaseInsensitiveContains(claim), "\(claim)")
        }
        // On the screen, and no longer a clause at the end of the key row.
        let window = try source("Sources/Moe/Onboarding/OnboardingWindow.swift")
        #expect(window.contains("freeStartRow\n"))
        #expect(window.contains("Text(Onboarding.freeStartTitle)"))
        #expect(!BrainPath.key.whatItIs.contains("free"))
        #expect(Handoff(way: .free, brain: unset, connected: true).steps.contains("aistudio.google.com"))
        #expect(URL(string: Onboarding.freeStartLink)?.host == "aistudio.google.com")
    }
}

struct FirstRunPermissionCopyTests {

    // MARK: 3 — whose switch does the clicking

    @Test("Memoe's Accessibility card promises the talk key, and not clicking")
    func accessibilityPromise() {
        #expect(Onboarding.accessibilityWhy.contains("talk key"))
        #expect(!Onboarding.accessibilityWhy.localizedCaseInsensitiveContains("click"))
        #expect(!PermissionGuide.accessibility.what.localizedCaseInsensitiveContains("click"))
    }

    @Test("clicking is named as the helper's, with the name macOS will use")
    func helperIsNamed() throws {
        let note = Onboarding.screenHelperNote
        #expect(note.contains("CuaDriver"))
        #expect(note.contains("helper app"))
        #expect(note.contains("Accessibility and Screen Recording"))
        #expect(note.contains("the first time you ask me"))
        // The switches it names are the helper's own two rows.
        #expect(PermissionGuide.driverAccessibility.owner == .driver)
        #expect(PermissionGuide.driverScreenRecording.owner == .driver)
        #expect(PermissionGuide.driverAccessibility.what.contains("click and type"))
        let window = try source("Sources/Moe/Onboarding/OnboardingWindow.swift")
        #expect(window.contains("small(Onboarding.screenHelperNote)"))
    }

    // MARK: 5 — no restart for Accessibility

    @Test("Accessibility needs no restart, says so, and draws no Quit and reopen button")
    func accessibilityNeedsNoRelaunch() throws {
        let guide = PermissionGuide.accessibility
        #expect(!guide.needsRelaunch)
        #expect(!guide.steps.localizedCaseInsensitiveContains("quit"))
        #expect(!guide.steps.contains("open it again"))
        #expect(guide.steps.contains("nothing to restart"))
        // The button is drawn from the flag and nothing else.
        let explainer = try source("Sources/Moe/Onboarding/PermissionGuide.swift")
        #expect(explainer.contains("if guide.needsRelaunch {\n                    PaneButton(title: \"Quit and reopen"))
        // What makes it true: the grant is watched and the key armed then.
        let watch = try source("Sources/Moe/Onboarding/AccessibilityWatch.swift")
        #expect(watch.contains("if now { onGranted.forEach { $0() } }"))
        // The grants macOS really does read only at launch still say so.
        for relaunch in [PermissionGuide.fullDiskAccess, .screenRecording, .inputMonitoring] {
            #expect(relaunch.needsRelaunch, "\(relaunch.id)")
            #expect(relaunch.steps.contains("again"), "\(relaunch.id)")
        }
    }

    // MARK: 6 — the language switch

    @Test("a language that will not load says nothing a person cannot use")
    func languageLoadFailure() throws {
        let lines = try source("Sources/Moe/Voice/VoiceEngine.swift").components(separatedBy: "\n")
        let mark = try #require(lines.firstIndex { $0.contains("LANGUAGE MODEL LOAD FAILED: ") })
        // The detail goes to the log…
        #expect(lines[mark].contains("Log.write(") && lines[mark].contains("\\(error)"))
        // …and the person gets a sentence and something to do.
        let said = lines[mark + 1]
        #expect(said.contains("onError?("))
        #expect(!said.contains("localizedDescription"))
        #expect(!said.contains("speech model"))
        #expect(said.contains("Check your internet connection"))
    }
}

/// Item 4. Every file operation here happens in a temporary folder made for
/// the test; nothing reads or writes the real Applications folder.
struct MoveToApplicationsTests {
    typealias Move = MoveToApplications

    // MARK: The decision

    private func situation(path: String = "/Volumes/Memoe/Memoe.app",
                           id: String? = "com.memoe.app",
                           debug: Bool = false, test: Bool = false, unattended: Bool = false,
                           exists: Bool = false, running: Bool = false,
                           asked: UnsafeMutablePointer<Int>? = nil) -> Move.Situation {
        Move.Situation(bundlePath: path, bundleIdentifier: id, releaseIdentifier: "com.memoe.app",
                       debugBuild: debug, underTest: test, unattended: unattended,
                       destinationExists: { asked?.pointee += 1; return exists },
                       destinationRunning: { asked?.pointee += 1; return running })
    }

    @Test("where a copy is running from")
    func origins() {
        #expect(Move.origin(ofPath: "/Volumes/Memoe/Memoe.app") == .diskImage)
        #expect(Move.origin(ofPath: "/Volumes/Memoe 1/Memoe.app/Contents/MacOS/Memoe") == .diskImage)
        #expect(Move.origin(ofPath: "/private/var/folders/ab/x/T/AppTranslocation/1C2D/d/Memoe.app") == .translocated)
        #expect(Move.origin(ofPath: "/Applications/Memoe.app") == .elsewhere)
        #expect(Move.origin(ofPath: "/Users/someone/Downloads/Memoe.app") == .elsewhere)
    }

    @Test("a downloaded copy on its disk image, or a temporary copy, is offered the move")
    func offered() {
        #expect(Move.decide(situation()) == .offerMove(.diskImage))
        #expect(Move.decide(situation(path: "/private/var/folders/ab/x/T/AppTranslocation/1C/d/Memoe.app"))
                == .offerMove(.translocated))
    }

    @Test("a Memoe already in Applications is asked about, never replaced unasked")
    func existingIsAsked() {
        #expect(Move.decide(situation(exists: true)) == .askReplace(.diskImage))
        #expect(Move.decide(situation(exists: true, running: true)) == .alreadyOpen)
    }

    @Test("inert in a debug build, in Memoe Dev, under test, unattended, and for the installed app")
    func inert() {
        var asked = 0
        let cases: [Move.Situation] = [
            situation(debug: true, asked: &asked),
            situation(test: true, asked: &asked),
            situation(id: "com.memoe.app.dev", asked: &asked),
            situation(id: "com.moe.assistant.dev", asked: &asked),
            situation(id: nil, asked: &asked),                       // a bare `swift build` binary
            situation(unattended: true, asked: &asked),
            situation(path: "/Applications/Memoe.app", asked: &asked),               // Sparkle, install.sh, catch-up.sh
            situation(path: "/Users/someone/moe/dist/Memoe.app", asked: &asked),     // RunningFromHere's case
            situation(path: "/Volumes/Memoe/Memoe.app/Contents/MacOS/Memoe", asked: &asked),
        ]
        for s in cases {
            guard case .nothing = Move.decide(s) else {
                Issue.record("should do nothing: \(s.bundlePath) \(s.bundleIdentifier ?? "nil")")
                continue
            }
        }
        // …and none of them so much as looked at the destination.
        #expect(asked == 0)
    }

    @Test("this test process is one the live entry point will not act in")
    func thisProcessIsUnderTest() {
        #expect(Move.underTest())
        #expect(Move.underTest(environment: ["XCTestConfigurationFilePath": "/x"], bundlePath: "/Volumes/M/Memoe.app"))
    }

    // MARK: The move, against a temporary folder

    private final class Box {
        let root: URL
        var trashed: [String] = []
        var cleared: [String] = []
        var failCopy = false
        var failTrash = false
        var failRename = false
        struct Refused: Error {}

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("moe-move-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("Applications"),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("Trash"),
                                                     withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var destination: String { root.appendingPathComponent("Applications/Memoe.app").path }

        /// A bundle with just enough inside to tell one from another.
        func bundle(_ place: String, version: String, complete: Bool = true) -> String {
            let app = root.appendingPathComponent(place).appendingPathComponent("Memoe.app")
            let fm = FileManager.default
            try? fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            if complete {
                try? Data(version.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
                try? Data("binary \(version)".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Memoe"))
            }
            return app.path
        }

        func version(at path: String) -> String? {
            try? String(contentsOfFile: path + "/Contents/Info.plist", encoding: .utf8)
        }

        var applications: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Applications").path)) ?? []).sorted()
        }

        var files: Move.Files {
            let fm = FileManager.default
            return Move.Files(
                exists: { fm.fileExists(atPath: $0) },
                copy: { [self] in if failCopy { throw Refused() }; try fm.copyItem(atPath: $0, toPath: $1) },
                rename: { [self] in if failRename { throw Refused() }; try fm.moveItem(atPath: $0, toPath: $1) },
                trash: { [self] path in
                    if failTrash { throw Refused() }
                    let to = root.appendingPathComponent("Trash/\(UUID().uuidString).app").path
                    try fm.moveItem(atPath: path, toPath: to)
                    trashed.append(to)
                },
                remove: { try? fm.removeItem(atPath: $0) },
                clearQuarantine: { [self] in cleared.append($0) })
        }
    }

    @Test("nothing there: the copy lands whole, under its own name, with nothing left beside it")
    func movesIn() {
        let box = Box()
        let from = box.bundle("Volumes", version: "0.3.25")
        let result = Move.move(bundle: from, to: box.destination, replacing: false, files: box.files, tag: "t")
        #expect(result == nil)
        #expect(box.version(at: box.destination) == "0.3.25")
        #expect(FileManager.default.fileExists(atPath: box.destination + "/Contents/MacOS/Memoe"))
        #expect(box.applications == ["Memoe.app"])
        #expect(box.cleared == [box.destination])
        #expect(box.trashed.isEmpty)
        // A copy, not a move: the disk image is read-only and stays as it was.
        #expect(box.version(at: from) == "0.3.25")
    }

    @Test("one already there, and no yes: it is left exactly as it was")
    func occupiedIsRefused() {
        let box = Box()
        let from = box.bundle("Volumes", version: "0.3.25")
        _ = box.bundle("Applications", version: "0.3.24")
        let result = Move.move(bundle: from, to: box.destination, replacing: false, files: box.files, tag: "t")
        #expect(result == .occupied)
        #expect(box.version(at: box.destination) == "0.3.24")
        #expect(box.applications == ["Memoe.app"])
        #expect(box.trashed.isEmpty && box.cleared.isEmpty)
    }

    @Test("Replace: the old one goes to the Trash, the new one takes its place")
    func replaces() throws {
        let box = Box()
        let from = box.bundle("Volumes", version: "0.3.25")
        _ = box.bundle("Applications", version: "0.3.24")
        let result = Move.move(bundle: from, to: box.destination, replacing: true, files: box.files, tag: "t")
        #expect(result == nil)
        #expect(box.version(at: box.destination) == "0.3.25")
        #expect(box.applications == ["Memoe.app"])
        #expect(box.version(at: try #require(box.trashed.first)) == "0.3.24")
    }

    @Test("a copy that fails changes nothing")
    func copyFails() {
        let box = Box()
        let from = box.bundle("Volumes", version: "0.3.25")
        _ = box.bundle("Applications", version: "0.3.24")
        box.failCopy = true
        guard case .couldNotCopy? = Move.move(bundle: from, to: box.destination, replacing: true,
                                                       files: box.files, tag: "t") else {
            Issue.record("expected couldNotCopy"); return
        }
        #expect(box.version(at: box.destination) == "0.3.24")
        #expect(box.applications == ["Memoe.app"])
        #expect(box.trashed.isEmpty)
    }

    @Test("a copy with no insides never takes the place of a working app")
    func incompleteCopy() {
        let box = Box()
        let from = box.bundle("Volumes", version: "", complete: false)
        _ = box.bundle("Applications", version: "0.3.24")
        let result = Move.move(bundle: from, to: box.destination, replacing: true, files: box.files, tag: "t")
        #expect(result == .incomplete)
        #expect(box.version(at: box.destination) == "0.3.24")
        #expect(box.applications == ["Memoe.app"])
        #expect(box.trashed.isEmpty)
    }

    @Test("the old one will not go to the Trash: it stays, and the new copy is cleared away")
    func trashFails() {
        let box = Box()
        let from = box.bundle("Volumes", version: "0.3.25")
        _ = box.bundle("Applications", version: "0.3.24")
        box.failTrash = true
        guard case .couldNotReplace? = Move.move(bundle: from, to: box.destination, replacing: true,
                                                          files: box.files, tag: "t") else {
            Issue.record("expected couldNotReplace"); return
        }
        #expect(box.version(at: box.destination) == "0.3.24")
        #expect(box.applications == ["Memoe.app"])
    }

    @Test("a leftover from an interrupted move is cleared, not tripped over")
    func leftoverStaging() throws {
        let box = Box()
        let from = box.bundle("Volumes", version: "0.3.25")
        let staging = Move.stagingPath(for: box.destination, tag: "t")
        #expect(staging.hasSuffix("/Applications/.Memoe.app.moving-t"))
        try FileManager.default.createDirectory(atPath: staging + "/Contents", withIntermediateDirectories: true)
        #expect(Move.move(bundle: from, to: box.destination, replacing: false, files: box.files, tag: "t") == nil)
        #expect(box.applications == ["Memoe.app"])
    }

    @Test("the reopen waits for this process and opens the moved copy by path")
    func relaunch() throws {
        let destination = "/tmp/It's here/Memoe.app"
        let script = Move.relaunchScript(pid: 2_000_000_000, destination: destination)
        #expect(script.contains("kill -0 2000000000"))
        // Run it with `echo` standing in for `open`: it must pass the path
        // as one argument, spaces, apostrophe and all.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["MOE_OPEN": "/bin/echo", "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == destination + "\n")
    }

    // MARK: Words

    @Test("the offer explains, in plain words, and never moves without a click")
    func words() throws {
        for origin in [Move.Origin.diskImage, .translocated] {
            let why = Move.Words.why(origin)
            #expect(why.contains("Applications"))
            #expect(why.contains("Nothing else on your Mac changes"))
            for word in ["translocat", "Gatekeeper", "quarantine", "bundle", "/Volumes", "install.sh", "launchd"] {
                #expect(!why.localizedCaseInsensitiveContains(word), "\(word)")
            }
        }
        #expect(Move.Words.why(.diskImage).contains("disk image"))
        #expect(Move.Words.why(.translocated).contains("temporary copy"))
        #expect(Move.Words.replaceWhy(existing: "0.3.24", this: "0.3.25").contains("0.3.24"))
        #expect(Move.Words.replaceWhy(existing: "0.3.24", this: "0.3.25").contains("Trash"))
        #expect(Move.Words.replaceWhy(existing: nil, this: nil).contains("not touched"))
        #expect(Move.Words.failed.contains("Nothing was changed"))
        // In the source, every move sits behind the answer to a question.
        let text = try source("Sources/Moe/Onboarding/MoveToApplications.swift")
        let live = body(of: "atLaunch", in: text)
        #expect(live.components(separatedBy: "move(bundle:").count - 1 == 2)
        #expect(live.contains("guard ask(Words.title, Words.why(from), [Words.move, Words.quit]) == 0 else { leave() }"))
        #expect(live.contains("case 0:\n                finish(move(bundle: bundle, to: destination, replacing: true"))
        // …and it runs before the developer's refusal, which a stranger must never meet.
        let delegate = try source("Sources/Moe/AppDelegate.swift")
        let offer = try #require(delegate.range(of: "MoveToApplications.atLaunch()"))
        let refusal = try #require(delegate.range(of: "RunningFromHere.enforce()"))
        #expect(offer.lowerBound < refusal.lowerBound)
    }
}
