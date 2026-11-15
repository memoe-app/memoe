#if DEBUG
import AppKit
import SwiftUI

/// `Moe --onboarding-snapshot <dir>` — every first-launch screen, in every
/// state it can be in, as a PNG. Light and dark.
///
/// The onboarding was rewritten twice without anyone looking at it, because
/// seeing it meant a fresh ~/.moe and a launch. This is the same idea as
/// `PanelSnapshot`: `ImageRenderer` draws the real `OnboardingView` at the
/// real window size, posed (`OnboardingView.Pose`) rather than asked, so no
/// permission is touched and nothing is installed.
///
/// **Nothing of the user's is touched.** `MOE_HOME` and `HERMES_HOME` are
/// repointed at a scratch directory before `Config` is first read, the
/// Conductor is constructed and never started, and no window is opened.
///
/// scripts/test-onboarding.sh runs this and fails if any screen does not
/// render — a crash in a view body is otherwise only found on somebody
/// else's first launch.
@MainActor
enum OnboardingSnapshot {

    static func run(_ directory: String) -> Int32 {
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
        config.hermesKey = "onboarding-snapshot"
        config.dictationContactsNames = false
        config.wakeWordEnabled = false
        let conductor = Conductor(config: config)

        var written = 0
        var failed = 0
        for shot in shots {
            for dark in [false, true] {
                let view = OnboardingView(conductor: conductor,
                                          openConnections: {}, openSection: { _ in }, finish: {},
                                          pose: shot.pose)
                    .environment(\.onboardingSnapshot, true)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let name = "\(shot.name)-\(dark ? "dark" : "light")"
                let path = (directory as NSString).appendingPathComponent("\(name).png")
                if write(view, to: path, appearance: dark ? .darkAqua : .aqua) {
                    written += 1
                    if !dark { print("\(shot.name)  — \(shot.note)") }
                } else {
                    failed += 1
                    FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                }
            }
        }
        print("\n\(written) written to \(directory)\(failed == 0 ? "" : ", \(failed) failed")")
        return failed == 0 ? 0 : 1
    }

    /// `Moe --onboarding-rehearsal`: the real window, live, posed as a
    /// fresh Mac, with every side effect faked (`OnboardingView.Pose.rehearsal`).
    /// Closing the window ends the process. Same scratch home as the
    /// snapshots, so the key picker and the meeting switch write nowhere real.
    static func rehearse() -> Int32 {
        let scratch = NSTemporaryDirectory() + "moe-onboarding-rehearsal"
        setenv("MOE_HOME", scratch, 1)
        setenv("HERMES_HOME", scratch, 1)
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        var config = Config()
        config.hermesKey = "onboarding-rehearsal"
        config.dictationContactsNames = false
        config.wakeWordEnabled = false
        let conductor = Conductor(config: config)

        let window = OnboardingWindow(conductor: conductor)
        window.onOpenConnections = {
            print("rehearsal: this is where the main window opens on Connections")
        }
        window.onOpenSection = { print("rehearsal: this is where Settings › \($0.rawValue) opens") }
        window.onFinished = { app.terminate(nil) }
        window.show(pose: .freshMac)
        print("rehearsal: nothing here is real — close the window to stop")
        app.run()
        return 0
    }

    struct Shot {
        let name: String
        let note: String
        let pose: OnboardingView.Pose
    }

    private static func pose(_ step: Onboarding.Screen,
                             _ edit: (inout OnboardingView.Pose) -> Void = { _ in }) -> OnboardingView.Pose {
        // The machine's own answers are posed away so the pictures are the
        // same on every Mac: nothing granted, nothing installed.
        var p = OnboardingView.Pose()
        p.step = step
        p.bootstrapDone = true
        p.claudeReady = true
        p.accessibility = true
        p.screenRecording = true
        edit(&p)
        return p
    }

    /// Every screen, then every state a screen can be in. The dictation
    /// screen's two shots are only taken while it is in the flow
    /// (`Onboarding.Screen.shown`).
    static var shots: [Shot] {
        all.filter { $0.pose.step != .dictate || Features.dictation }
    }

    private static var all: [Shot] {
        [
            Shot(name: "01-welcome", note: Features.dictation ? "the five things" : "the four things", pose: pose(.welcome)),
            Shot(name: "02-microphone", note: "before asking", pose: pose(.microphone)),
            Shot(name: "02-microphone-granted", note: "said yes", pose: pose(.microphone) { $0.micAsked = true }),
            Shot(name: "02-microphone-denied", note: "said no: explained, not re-asked",
                 pose: pose(.microphone) { $0.micAsked = true; $0.micDenied = true }),
            Shot(name: "03-brain", note: "the four ways in", pose: pose(.brain)),
            Shot(name: "03-brain-getting-ready", note: "a downloaded copy: the bundled Hermes is being laid down, nothing to press",
                 pose: pose(.brain) { $0.bootstrapDone = false; $0.seeding = true }),
            Shot(name: "03-brain-not-installed", note: "no seed in this build (or it failed): the download card, one button",
                 pose: pose(.brain) { $0.bootstrapDone = false }),
            Shot(name: "03-brain-installing", note: "the install running",
                 pose: pose(.brain) { $0.bootstrapDone = false; $0.installing = true; $0.installLine = "✓ Python installed: Python 3.14" }),
            Shot(name: "03-brain-signed-in", note: "signed in with Claude",
                 pose: pose(.brain) { $0.signedIn = true }),
            Shot(name: "03-brain-signed-in-chatgpt", note: "signed in with ChatGPT: the same tick, the same Next",
                 pose: pose(.brain) { $0.signedIn = true; $0.signedInAccount = BrainPath.chatgpt.accountName }),
            Shot(name: "03-brain-sign-in-tool-failed", note: "the sign-in tool's download failed: said, with Try again",
                 pose: pose(.brain) { $0.claudeReady = false; $0.signInToolFailed = true }),
            Shot(name: "03-brain-handoff-key", note: "Use a key pressed: Settings › Brain is open, the welcome waits",
                 pose: pose(.brain) { $0.handoff = .key }),
            Shot(name: "03-brain-handoff-free", note: "Start free pressed: where the free key comes from, and waiting",
                 pose: pose(.brain) { $0.handoff = .free }),
            Shot(name: "03-brain-handoff-local", note: "Run a model on this Mac pressed: waiting",
                 pose: pose(.brain) { $0.handoff = .onThisMac }),
            Shot(name: "03-brain-handoff-problem", note: "the key was set and did not answer: said on the card, checked again on the next try",
                 pose: pose(.brain) { $0.handoff = .key; $0.handoffProblem = "That key was refused. Check it was copied whole, or make a new one." }),
            Shot(name: "03-brain-connected-key", note: "a key set in Settings › Brain answered: the same tick, the same Next",
                 pose: pose(.brain) { $0.signedIn = true; $0.signedInAccount = "Google Gemini"; $0.signedInViaSettings = true }),
            Shot(name: "04-try-it", note: "signed in, key allowed",
                 pose: pose(.tryIt) { $0.signedIn = true }),
            Shot(name: "04-try-it-no-brain", note: "nothing thinking yet: said before the first question",
                 pose: pose(.tryIt) { $0.bootstrapDone = false }),
            Shot(name: "04-try-it-no-accessibility", note: "Accessibility and Screen Recording not yet allowed: one button each, both skippable",
                 pose: pose(.tryIt) { $0.signedIn = true; $0.accessibility = false; $0.screenRecording = false }),
            Shot(name: "04-try-it-waiting-for-accessibility", note: "Allow pressed: waiting for the switch, nothing to quit and reopen",
                 pose: pose(.tryIt) { $0.signedIn = true; $0.accessibility = false; $0.accessibilityAsked = true }),
            Shot(name: "05-dictate", note: "the other key", pose: pose(.dictate)),
            Shot(name: "05-dictate-no-accessibility", note: "clipboard instead, until allowed",
                 pose: pose(.dictate) { $0.accessibility = false }),
            Shot(name: "06-meetings", note: "notes, consent, the red ring", pose: pose(.meetings)),
            Shot(name: "07-learn", note: "what Moe may read: three of the Mac's own sources and the daily pass, all recommended on",
                 pose: pose(.learn) { $0.learnSources = OnboardingView.posedLearnSources }),
            Shot(name: "07-learn-nothing", note: "nothing connected yet: says where the list lives",
                 pose: pose(.learn) { $0.learnSources = [] }),
            Shot(name: "08-connect", note: "the last screen: the Mac's apps, then Google; start with the Mac; problem reports", pose: pose(.connect)),
        ]
    }

    private static func write(_ view: some View, to path: String,
                              appearance: NSAppearance.Name) -> Bool {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = OnboardingWindow.size
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
#endif
