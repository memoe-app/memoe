import Foundation
import Testing
@testable import Moe

/// docs/MASTER-PLAN-2026-11-12.md, W1-C — the welcome's small fixes:
///
///   2   a closed, unfinished welcome is not a finished one: it resumes
///   3   every sign-in moves on the same way, whoever it was with
///   4   a failed download says so
///   5   "Say hello" leads with something that works right now
///   6   no "Quit and reopen" on the Accessibility card
///   7   a question with no AI connected is answered out loud
///   8   "Say hello" moves on after the answer, not at the first word
///   12  failures in plain words
///   13  the warm-up line on the screen as well as the island
///   14  the About box names the AI that was chosen

private func scratchHome() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("moe-first-run-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Sentences a person reads must not carry what only a developer can use.
private func developerWords(in sentence: String) -> [String] {
    ["~/", ".log", ".sh", "/logs", "exit ", "stderr", "errno", "NSError", "Error Domain", "install-hermes"]
        .filter { sentence.contains($0) }
}

struct OnboardingFirstRunTests {

    // MARK: 2 — closing is not finishing

    @Test("closing the welcome part-way does not mark it done, and the next launch resumes there")
    func closedEarlyResumes() {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        Onboarding.record(.closed(at: .brain), in: home)

        #expect(!Onboarding.done(in: home))
        #expect(Onboarding.resumeScreen(in: home) == .brain)
        let launch = Onboarding.atLaunch(done: Onboarding.done(in: home),
                                         resume: Onboarding.resumeScreen(in: home),
                                         firstRun: false, signedIn: true)
        #expect(launch == .welcome(at: .brain))
    }

    @Test("finishing marks it done and clears the place to resume")
    func finishedIsDone() {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        Onboarding.markResume(at: .learn, in: home)
        Onboarding.record(.completed, in: home)

        #expect(Onboarding.done(in: home))
        #expect(Onboarding.resumeScreen(in: home) == nil)
        #expect(Onboarding.atLaunch(done: true, resume: nil, firstRun: false, signedIn: false) == .mainWindow)
    }

    @Test("Show welcome again, closed early on a finished Mac, changes nothing")
    func replayClosedEarly() {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        Onboarding.record(.completed, in: home)
        Onboarding.record(.closed(at: .microphone), replay: true, in: home)

        #expect(Onboarding.done(in: home))
        #expect(Onboarding.resumeScreen(in: home) == nil)
    }

    @Test("what a launch does about the welcome")
    func launchDecision() {
        // Done wins: a stale marker cannot pin a finished Mac to the welcome.
        #expect(Onboarding.atLaunch(done: true, resume: .tryIt, firstRun: false, signedIn: true) == .mainWindow)
        // Unfinished, with a sign-in stored mid-flow: still the welcome.
        #expect(Onboarding.atLaunch(done: false, resume: .tryIt, firstRun: false, signedIn: true) == .welcome(at: .tryIt))
        #expect(Onboarding.atLaunch(done: false, resume: nil, firstRun: true, signedIn: true) == .welcome(at: .welcome))
        #expect(Onboarding.atLaunch(done: false, resume: nil, firstRun: false, signedIn: false) == .welcome(at: .welcome))
        #expect(Onboarding.atLaunch(done: false, resume: nil, firstRun: false, signedIn: true) == .markDoneThenMainWindow)
    }

    @Test("the sign-in is only asked about when nothing else decides")
    func launchAsksTheKeychainLast() {
        var asked = 0
        func signedIn() -> Bool { asked += 1; return true }
        _ = Onboarding.atLaunch(done: true, resume: nil, firstRun: false, signedIn: signedIn())
        _ = Onboarding.atLaunch(done: false, resume: .brain, firstRun: false, signedIn: signedIn())
        _ = Onboarding.atLaunch(done: false, resume: nil, firstRun: true, signedIn: signedIn())
        #expect(asked == 0)
        _ = Onboarding.atLaunch(done: false, resume: nil, firstRun: false, signedIn: signedIn())
        #expect(asked == 1)
    }

    // MARK: 3 — one way forward for every sign-in

    @Test("every sign-in row moves on to Say hello and names its own account",
          arguments: [BrainPath.claude, BrainPath.chatgpt])
    func signInAdvances(path: BrainPath) {
        var state = Onboarding.SignIn()
        #expect(!state.signedIn)
        #expect(state.finished(path, ok: true) == .tryIt)
        #expect(state.signedIn)
        #expect(state.line == "Signed in with \(path.accountName).")
        #expect(!path.accountName.isEmpty && !path.accountName.contains("Sign in"))
    }

    @Test("a sign-in that did not happen stays where it is",
          arguments: [BrainPath.claude, BrainPath.chatgpt])
    func signInCancelledStays(path: BrainPath) {
        var state = Onboarding.SignIn()
        #expect(state.finished(path, ok: false) == nil)
        #expect(!state.signedIn)
    }

    @Test("a stored sign-in that could not be made the choice is undone")
    func signInUndone() {
        var state = Onboarding.SignIn()
        _ = state.finished(.chatgpt, ok: true)
        state.undo()
        #expect(!state.signedIn)
    }

    // MARK: 5, 6 — Say hello

    @Test("without Accessibility the lead names what works now, never the held key")
    func leadWithoutAccessibility() {
        let lead = Onboarding.sayHelloLead(accessibility: false, holdKey: "right ⌥",
                                           whereItIs: "right of the space bar", shortcut: "⌃⌥Space")
        #expect(!lead.contains("Hold"))
        #expect(!lead.contains("right ⌥"))
        #expect(lead.contains("Talk to me"))
        #expect(lead.contains("⌃⌥Space"))
    }

    @Test("with Accessibility the lead is the held key")
    func leadWithAccessibility() {
        let lead = Onboarding.sayHelloLead(accessibility: true, holdKey: "right ⌥",
                                           whereItIs: "right of the space bar", shortcut: "⌃⌥Space")
        #expect(lead.hasPrefix("Hold right ⌥"))
    }

    @Test("the Accessibility card waits; it does not ask for a restart")
    func accessibilityWaits() throws {
        let waiting = Onboarding.accessibilityWaiting(holdKey: "right ⌥")
        #expect(waiting.contains("Waiting"))
        #expect(waiting.contains("nothing to restart"))
        // …and the screen's source no longer draws the button.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Moe/Onboarding/OnboardingWindow.swift"), encoding: .utf8)
        #expect(!source.contains("PillButton(title: \"Quit and reopen"))
        #expect(!source.contains("Relaunch.now()"))
    }

    // MARK: 8 — after the answer, not at the first word

    @Test("Say hello is not finished at the first word, nor while the answer plays")
    func sayHelloWaitsForTheAnswer() {
        #expect(!Onboarding.sayHelloFinished(roles: [], mode: .idle))
        #expect(!Onboarding.sayHelloFinished(roles: [.you], mode: .idle))
        #expect(!Onboarding.sayHelloFinished(roles: [.you], mode: .thinking))
        #expect(!Onboarding.sayHelloFinished(roles: [.you, .moe], mode: .thinking))
        #expect(!Onboarding.sayHelloFinished(roles: [.you, .moe], mode: .speaking))
        // A greeting from Moe with nothing said back is not trying it.
        #expect(!Onboarding.sayHelloFinished(roles: [.moe], mode: .idle))
    }

    @Test("Say hello is finished once the answer has been heard")
    func sayHelloFinishes() {
        #expect(Onboarding.sayHelloFinished(roles: [.you, .moe], mode: .idle))
        // No AI connected: the line that stood in for an answer counts.
        #expect(Onboarding.sayHelloFinished(roles: [.you, .system], mode: .idle))
        // A conversation that stays open for the next thing is past it too.
        #expect(Onboarding.sayHelloFinished(roles: [.you, .moe], mode: .listening))
    }

    // MARK: 13 — the warm-up line

    @Test("the warm-up line shows while the models load, and only then")
    func warmUp() {
        #expect(Onboarding.warmUpLine(status: "Getting my ears on…", voiceReady: false, mode: .idle) == "Getting my ears on…")
        #expect(Onboarding.warmUpLine(status: "Getting my ears on…", voiceReady: true, mode: .idle) == nil)
        #expect(Onboarding.warmUpLine(status: "", voiceReady: false, mode: .idle) == nil)
        #expect(Onboarding.warmUpLine(status: "Getting my ears on…", voiceReady: false, mode: .listening) == nil)
    }

    // MARK: 7 — a question with no AI connected

    @Test("no AI connected: one short spoken line, whatever the error said")
    func spokenWithoutAnAI() {
        #expect(SpokenError.line(for: "Moe isn't connected.", needsSignIn: true) == SpokenError.connectAnAI)
        #expect(SpokenError.line(for: HermesKey.needSignInPrefix + " — sign in", needsSignIn: false) == SpokenError.connectAnAI)
        #expect(SpokenError.line(for: "claude turn failed: weekly limit", needsSignIn: false)
                == SpokenError.line(for: "claude turn failed: weekly limit"))
        #expect(SpokenError.connectAnAI.count < 80)
        #expect(SpokenError.connectAnAI.contains("Connect an AI"))
        // Provider-agnostic: no vendor is named.
        for vendor in ["Claude", "ChatGPT", "OpenAI", "Anthropic"] {
            #expect(!SpokenError.connectAnAI.contains(vendor))
        }
    }

    // MARK: 4, 12 — failures in plain words

    @Test("failure sentences carry no paths, script names or raw errors",
          arguments: [Onboarding.signInToolFailed,
                      Bootstrap.Failure.damaged, Bootstrap.Failure.tookTooLong, Bootstrap.Failure.didNotFinish,
                      ChatGPTSignInFlow.couldNotStart, ChatGPTSignInFlow.didNotFinish])
    func plainFailures(sentence: String) {
        #expect(developerWords(in: sentence).isEmpty, "\(sentence)")
        // A sentence, and what to do.
        #expect(sentence.count > 30)
        #expect(["try again", "Try again", "try once more", "Download Memoe again"].contains { sentence.contains($0) },
                "\(sentence)")
    }

    @Test("the voice engine's three load failures say nothing a person cannot use")
    func voiceLoadFailures() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Moe/Voice/VoiceEngine.swift"), encoding: .utf8)
        // The line after each of the three "… LOAD FAILED" log lines.
        let lines = source.components(separatedBy: "\n")
        let errors = ["VOICE LOAD FAILED: ", "ACCURATE MODEL LOAD FAILED: ", "(\"MODEL LOAD FAILED: "].compactMap { mark in
            lines.firstIndex { $0.contains(mark) }.map { lines[$0 + 1] }
        }
        #expect(errors.count == 3)
        for line in errors {
            #expect(line.contains("onError?("), "\(line)")
            #expect(!line.contains("localizedDescription"), "\(line)")
            #expect(line.lowercased().contains("quit memoe and open it again"), "\(line)")
        }
    }

    // MARK: 14 — the About box

    @Test("the About box names the AI that was chosen, not one vendor's plan")
    func about() {
        let chatgpt = AppDelegate.aboutText(brain: "ChatGPT", shortcut: "⌃⌥Space")
        #expect(chatgpt.contains("ChatGPT"))
        #expect(!chatgpt.contains("Claude"))
        #expect(!chatgpt.contains("subscription"))
        #expect(!chatgpt.contains("~/"))
        #expect(chatgpt.contains("⌃⌥Space"))
    }
}
