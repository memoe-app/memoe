// swift-tools-version:6.0
import PackageDescription
import Foundation

// The closed half. The public repo is the local-only Mac app; everything
// that talks to our cloud lives in a directory the public export drops, and
// that directory describes its own targets in `targets.json` beside it. This
// manifest names none of them: when the file is here its targets (and what
// the app links and compiles from it) are added; when it is not, nothing is,
// and the tree still resolves, builds and tests.
//
// SwiftPM caches an evaluated manifest by its *contents*, not by what is on
// disk, so deleting that directory inside a checkout that already built with
// it needs `--manifest-cache none` once (build.sh passes it then). A fresh
// clone has nothing cached and needs nothing.
struct ClosedHalf: Decodable {
    struct Target: Decodable {
        let name: String
        let kind: String            // "library", "executable" or "test"
        let path: String
        let dependencies: [String]
    }
    /// What the app target takes from the closed half: modules it links and
    /// compilation conditions. Its Swift is compiled into the app through
    /// `Sources/Moe/Closed`, a link into the closed directory that resolves
    /// to nothing — and so adds nothing — in a tree without it.
    struct App: Decodable {
        var dependencies: [String] = []
        var defines: [String] = []
    }
    var targets: [Target] = []
    var app = App()
}
let closedHalf: ClosedHalf = {
    let spec = URL(fileURLWithPath: Context.packageDirectory)
        .appendingPathComponent("cloud").appendingPathComponent("targets.json")
    guard let data = try? Data(contentsOf: spec) else { return ClosedHalf() }
    do { return try JSONDecoder().decode(ClosedHalf.self, from: data) }
    catch { fatalError("\(spec.path) does not parse: \(error)") }
}()

let package = Package(
    name: "Moe",
    // macOS 15, not 26.
    //
    // 26 was never a requirement anybody chose. Two stored properties named
    // `LanguageModelSession` — Apple's on-device model, an optional tier —
    // and Swift refuses a stored property marked `@available`, so the type
    // in those two declarations set the floor for the whole app. Every call
    // site was already behind `if #available(macOS 26.0, *)`. The result was
    // that an M1 Air on macOS 15 was told it could not run Moe.
    //
    // They are `Any?` behind an `@available` accessor now, and this builds
    // clean at 15.0. Lower is possible but not free: 14.2 for
    // AudioHardwareCreateProcessTap (meeting capture) and then 15.0 again
    // for the macOS 15 atomics in Sources/Moe/Voice/AudioFrontEnd.swift.
    // Keep this in step with LSMinimumSystemVersion in build.sh.
    platforms: [.macOS("15.0")],
    dependencies: [
        // Parakeet ASR + PocketTTS/Kokoro TTS + Silero VAD, all CoreML on the
        // Neural Engine. Apache-2.0, no other SPM dependencies, no Python.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.1"),
        // Whisper for the languages Parakeet v3 lacks (Arabic, Hebrew, Hindi,
        // CJK…) and for long-form audio. MIT, CoreML, no other SPM
        // dependencies, so it coexists with FluidAudio. PRODUCT.md §4.1.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // Auto-updates (docs/RELEASING.md §3, DISTRIBUTION.md §3.4). MIT.
        // Pinned exactly, not `from:`: the framework is a *binary* artifact
        // that ships inside Moe.app and gets Moe's own Developer ID signature
        // put on it, so which bytes we ship must be a decision, not a
        // resolver's mood. Bumping it is a deliberate commit.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        // ONNX Runtime, for Smart Turn (VOICE-PLAN.md §4.2): the 8 MB
        // end-of-turn model is an int8 ONNX graph that CoreML's converters
        // refuse, so the runtime comes along. MIT. Pinned exactly: a binary
        // artifact (52 MB xcframework, static, macOS 14+) that ships inside
        // Moe.app under Moe's signature. Linked from the executable target
        // on purpose — a library re-exporting it hits missing training
        // symbols (upstream issue #27).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 exact: "1.24.2"),
    ],
    targets: [
        .executableTarget(
            name: "Moe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "MoeComponents",
                "MoeDictation",
                "MoeScreen",
                "MoeBrain",
                "MoeAudio",
                "MoeConnectors",
                "MoeMeeting",
                "MoeChat",
                "MoeDesign",
                "MoeLicence",
                "MoeLedger",
                "MoeVoice",
                "MoeIsland",
                // Erase Moe from this Mac (CLOUD-REMAINING D9.12): the engine
                // that deletes a person's data, in its own module so every
                // rule of what it may and may not touch is a unit test.
                "MoeErase",
                "MoeObjC",
            ] + closedHalf.app.dependencies.map { .byName(name: $0) },
            path: "Sources/Moe",
            swiftSettings: [.swiftLanguageMode(.v5)]
                + closedHalf.app.defines.map { .define($0) }
        ),
        // The design system — every colour, size, radius and duration in the
        // product, plus the service marks. A module rather than a file inside
        // the app because the send-confirmation dialog is its own process
        // (Sources/MoeConfirm) and has to look like Moe without being Moe.
        // One palette, two binaries.
        .target(
            name: "MoeDesign",
            path: "Sources/MoeDesign",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The dialog in front of every send (moe-home/tools/confirm.sh).
        //
        // A separate executable, not a window in the app, for one reason: the
        // gate must be able to ask even when Moe is not running — Hermes's
        // hook and the connectors call confirm.sh from a shell, and a gate
        // that needs the app up is a gate with an off switch. It takes the
        // message on stdin, shows it, and answers with its exit status:
        // 0 approved, 1 cancelled, anything else "I could not ask", which
        // sends confirm.sh back to its AppleScript dialog.
        .executableTarget(
            name: "MoeConfirm",
            dependencies: ["MoeDesign"],
            path: "Sources/MoeConfirm",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Its own bundle identity, embedded in the Mach-O. A helper in
            // Contents/MacOS with no plist of its own inherits the app's, so
            // this dialog registered as a second instance of Moe: `quit Moe`,
            // logging out or restarting addressed it too, and AppKit's answer
            // to a quit is exit(0) — which is this program's word for "the
            // human clicked Send". main.swift refuses that now; this makes it
            // unaddressable in the first place.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/MoeConfirm/Info.plist",
            ])]
        ),
        // Conversations that survive ⌘N: one JSON file per thread. Pure
        // Foundation, split out so the tests can reach it — losing a
        // conversation is silent and permanent, so this wants real coverage.
        .target(
            name: "MoeChat",
            path: "Sources/MoeChat",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Licence keys (CLOUD.md §14.2): the payload, the key string, and
        // Ed25519 verification against the public key the app is built with.
        // CryptoKit and Foundation only. Split out because locking out a
        // paying customer is the one unforgivable failure here, so every
        // branch of it wants a test.
        .target(
            name: "MoeLicence",
            path: "Sources/MoeLicence",
        ),
        // The append-only ledger and the projector that rebuilds the stores
        // from it (docs/ONE-AGENT.md §1). Pure Foundation + CryptoKit, split
        // out so the tests can reach it: everything a person would call "my
        // conversations" is now derived from these records.
        .target(
            name: "MoeLedger",
            dependencies: ["MoeChat"],
            path: "Sources/MoeLedger",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Erase Moe from this Mac (docs/CLOUD-REMAINING.md D9.12). Pure
        // Foundation and fully injected — home directory, keychain, launchctl,
        // tccutil, relaunch — because this is the code that deletes a
        // person's data, and a rule about what it must never touch that lives
        // only in an executable target is a rule nobody can test.
        .target(
            name: "MoeErase",
            path: "Sources/MoeErase",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-Foundation dictation text pipeline, split out so the tests can
        // `@testable import` it — an executable target can't be imported.
        .target(
            name: "MoeDictation",
            path: "Sources/MoeDictation",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The voice state machine and the pure pieces around it (wake phrase
        // matching, sentence splitting, the level meter, the turn trace).
        // VOICE-PLAN.md §2.2. Pure Foundation, split out so every rule of
        // turn-taking is a test rather than a night of pressing keys.
        .target(
            name: "MoeVoice",
            path: "Sources/MoeVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-Foundation screen-context pieces (the `[POINT:x,y:label]`
        // tag parser), split out for the same reason.
        .target(
            name: "MoeScreen",
            path: "Sources/MoeScreen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The island's gesture and self-opening rules, and the "a turn ended
        // with an answer" signal (docs/PANEL-FINDINGS.md §1–§5, §7). Pure
        // Foundation, split out for the same reason as the two above: every
        // one of these rules fixes a bug that is invisible in the view code,
        // and none of them can be tested from inside an executable target.
        .target(
            name: "MoeIsland",
            // Pure too: the reply's blocks (ReplyBlocks), so the island
            // measures a drafted email the way it draws it.
            dependencies: ["MoeChat"],
            path: "Sources/MoeIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // What a provider+model can do (PRODUCT.md §3.4a); pure Foundation,
        // split out for the same reason.
        .target(
            name: "MoeBrain",
            path: "Sources/MoeBrain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Sample-level repair of Moe's own voice. Its own target because a
        // filter that runs over every sample the app speaks has to be
        // testable, and Moe is an executable that no test can import.
        .target(
            name: "MoeAudio",
            path: "Sources/MoeAudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The text shapes of the Calendar/Reminders connectors (pure
        // Foundation); the EventKit reads live in Sources/Moe/Connectors.
        .target(
            name: "MoeConnectors",
            path: "Sources/MoeConnectors",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Meeting mode (PRODUCT.md §4.2, MEETING-MODE.md): system audio via a
        // Core Audio process tap, the mic with echo cancellation, both to
        // 16 kHz WAVs; windows transcribed with the app's ASR; diarization,
        // timeline and summary. Split out so the pure parts (segment merge,
        // timeline, drift, JSON) are unit-tested and the CLI reuses the capture.
        // The one thing Swift cannot do: catch an Objective-C exception.
        // `installTapOnBus:` raises on a format mismatch after a microphone
        // change, and one raised through Swift concurrency frames corrupted
        // the executor record and crashed the app later, in SwiftUI
        // (2026-09-30). Every installTap goes through `MoeObjC.catchException`.
        .target(
            name: "MoeObjC",
            path: "Sources/MoeObjC"
        ),
        // The parts of Memoe a slim build fetches on demand: the pinned
        // manifest, the one fetcher, its HTTP transport. Pure Foundation and
        // CryptoKit, and its own target so the rules — a wrong hash is
        // refused, a cut download resumes — are testable without the app.
        // docs/SLIM-DOWNLOAD.md.
        .target(
            name: "MoeComponents",
            path: "Sources/MoeComponents",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeComponentsTests",
            dependencies: ["MoeComponents"],
            path: "Tests/MoeComponentsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MoeMeeting",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "MoeObjC", "MoeComponents"],
            path: "Sources/MoeMeeting",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Swift Testing, not XCTest: the Command Line Tools ship the former
        // only. Run with scripts/test.sh, which tells SwiftPM where to find it.
        .testTarget(
            name: "MoeChatTests",
            dependencies: ["MoeChat"],
            path: "Tests/MoeChatTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeLedgerTests",
            dependencies: ["MoeLedger", "MoeChat"],
            path: "Tests/MoeLedgerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Runs only against a temporary home and a throwaway keychain; see
        // the header of Tests/MoeEraseTests/MacEraseTests.swift.
        .testTarget(
            name: "MoeEraseTests",
            dependencies: ["MoeErase"],
            path: "Tests/MoeEraseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeDictationTests",
            dependencies: ["MoeDictation"],
            path: "Tests/MoeDictationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeVoiceTests",
            dependencies: ["MoeVoice"],
            path: "Tests/MoeVoiceTests",
            // Reference log-mel features from Pipecat's numpy recipe, so the
            // Swift port is checked against the model's real input.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeScreenTests",
            dependencies: ["MoeScreen"],
            path: "Tests/MoeScreenTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeConnectorsTests",
            dependencies: ["MoeConnectors"],
            path: "Tests/MoeConnectorsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeMeetingTests",
            dependencies: ["MoeMeeting"],
            path: "Tests/MoeMeetingTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeLicenceTests",
            dependencies: ["MoeLicence"],
            path: "Tests/MoeLicenceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeIslandTests",
            dependencies: ["MoeIsland"],
            path: "Tests/MoeIslandTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeBrainTests",
            dependencies: ["MoeBrain"],
            path: "Tests/MoeBrainTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app target itself: the Connections sheet's state machine and
        // the in-app licence notice. Nothing here may launch a process —
        // ConnectFlow's script launcher is replaced in every test.
        .testTarget(
            name: "MoeAppTests",
            dependencies: ["Moe"],
            path: "Tests/MoeAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeObjCTests",
            dependencies: ["MoeObjC"],
            path: "Tests/MoeObjCTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MoeAudioTests",
            dependencies: ["MoeAudio"],
            path: "Tests/MoeAudioTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Standalone check that echo cancellation actually works on this Mac.
        .executableTarget(
            name: "AudioGate",
            dependencies: ["MoeObjC"],
            path: "Sources/AudioGate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Meeting-mode spike: system audio via Core Audio process taps + mic,
        // both to 16 kHz mono, then FluidAudio ASR + diarization. See
        // MEETING-MODE.md.
        // Re-derives summary.md and meeting.json notes from a transcript
        // already on disk, with today's prompt and today's dedupe — so a fix
        // to either reaches the meetings already recorded, not only the next
        // one. Never touches transcript.txt.
        .executableTarget(
            name: "MeetingNotesRedo",
            dependencies: ["MoeMeeting"],
            path: "Sources/MeetingNotesRedo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MeetingTap",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "MoeMeeting"],
            path: "Sources/MeetingTap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

for t in closedHalf.targets {
    let deps = t.dependencies.map { Target.Dependency.byName(name: $0) }
    let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
    switch t.kind {
    case "library":
        package.targets.append(.target(name: t.name, dependencies: deps, path: t.path,
                                       swiftSettings: settings))
    case "executable":
        package.targets.append(.executableTarget(name: t.name, dependencies: deps, path: t.path,
                                                 swiftSettings: settings))
    case "test":
        package.targets.append(.testTarget(name: t.name, dependencies: deps, path: t.path,
                                           swiftSettings: settings))
    default:
        fatalError("closed target \(t.name): unknown kind \(t.kind)")
    }
}
