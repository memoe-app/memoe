import Foundation
import Testing
@testable import Moe

/// What Settings › Brain shows when the script behind it fails is a sentence
/// for the person, chosen by what they asked for — never the script's output.
struct BrainSetupSaidTests {

    @Test func theSentenceFollowsWhatWasAsked() {
        typealias Said = BrainSetup.Said
        #expect(Said.failure(of: ["--show"]) == Said.couldNotRead)
        #expect(Said.failure(of: ["--codex-models"]) == Said.couldNotRead)
        #expect(Said.failure(of: ["--set-provider", "anthropic", "--set-model", "x", "--set-key", "ANTHROPIC_API_KEY"])
                == Said.keyNotSaved)
        #expect(Said.failure(of: ["--set-browse-as", "Profile 1"]) == Said.profileNotUsed)
        #expect(Said.failure(of: ["--set-turn-timeout", "1800"]) == Said.notSaved)
        #expect(Said.failure(of: ["--install-chrome-extension"]) == Said.notSaved)
    }

    @Test func noneOfThemIsEngineering() {
        typealias Said = BrainSetup.Said
        for s in [Said.missing, Said.wouldNotStart, Said.couldNotRead, Said.keyNotSaved,
                  Said.profileNotUsed, Said.notSaved] {
            for word in [".py", "exited", "config.yaml", "Hermes", "stderr", "~/", "--"] {
                #expect(!s.contains(word), "\"\(s)\" contains \(word)")
            }
            #expect(s.hasSuffix("."))
        }
    }

    /// A real failing run: a script that writes what configure-hermes.py
    /// writes and exits 1. What comes back is the sentence; none of the
    /// script's words reach it.
    @MainActor @Test func aFailingRunReturnsTheSentenceNotTheOutput() throws {
        try StallGuardConductorTests.requireScratchHome()   // the detail goes to the log under the home
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brain-said-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("configure-hermes.py")
        try "import sys\nsys.stderr.write('config.yaml does not parse; fix it and re-run:\\nmapping values are not allowed here\\n')\nsys.exit(1)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        setenv("MOE_HERMES_CONFIGURE_SCRIPT", script.path, 1)
        defer { unsetenv("MOE_HERMES_CONFIGURE_SCRIPT") }
        guard BrainSetup.scriptPath() == script.path else {
            Issue.record("the debug hook did not take: \(BrainSetup.scriptPath() ?? "nil")"); return
        }
        guard case .failure(let f) = BrainSetup.run(["--set-turn-timeout", "1800"]) else {
            Issue.record("a script that exits 1 was reported as a success"); return
        }
        #expect(f.message == BrainSetup.Said.notSaved)
        #expect(!f.message.contains("config.yaml"))
        Log.flush()
        let log = (try? String(contentsOf: Paths.logs.appendingPathComponent("moe.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("config.yaml does not parse"), "the detail did not reach the log")
    }
}
