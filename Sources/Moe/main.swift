import AppKit
import AVFoundation
import FluidAudio
import Foundation
import MoeBrain
import MoeChat
import MoeComponents
import MoeDesign
import MoeLedger
import MoeVoice

let args = CommandLine.arguments

// Erase Memoe from this Mac (docs/CLOUD-REMAINING.md D9.12) — FIRST, before
// anything below can create or write the home it is about to remove. The app
// starts this only after it has quit; `--erase-plan` lists and deletes
// nothing. Sources/Moe/MacErase.swift.
if args.count > 1, ["--erase-mac", "--erase-plan", "--erase-mac-spawn"].contains(args[1]) {
    MacEraseRun.main(args)
}

// A development build's children land in ITS home. `Paths.home` honours the
// MoeHome stamped into a dev bundle, so the app itself keeps to
// ~/Library/Application Support/Moe Dev — but sync.sh, learn.sh, every
// connector and every Hermes job spell their home `${MOE_HOME:-$HOME/.moe}`,
// and the app spawned them with no MOE_HOME. Measured on the owner's Mac,
// 2026-09-11 08:19: Moe Dev's own LaunchAgent (`Memoe Dev.app --sync`, every
// ten minutes) ran the real ~/.moe/sync.sh under the Dev binary's
// permissions — no Calendar, no Reminders — and, finding them "unreachable",
// deleted the real Moe's calendar and tasks copies every other run; the
// proactive pass then told the owner his brief had lost its calendar. Twenty-
// three spawn sites copy the process environment, so the one honest place
// to say where home is, is the process environment itself. Set once, here,
// before anything is spawned, and only for a build that carries a MoeHome:
// the release app's scripts find ~/.moe by the symlink, and its home path
// carries a space that not every script quotes — leave that as it is.
if let dev = Bundle.main.object(forInfoDictionaryKey: "MoeHome") as? String,
   !dev.trimmingCharacters(in: .whitespaces).isEmpty,
   ProcessInfo.processInfo.environment["MOE_HOME"] == nil {
    setenv("MOE_HOME", Paths.home.path, 1)
}

// Memoe's cloud, when this build has one — now that the home is settled and
// before any verb or the app itself can ask for it (Sources/Moe/Edition).
Cloud.install()

// `Moe --sync [digest]` runs the ingestion pass.
//
// This exists so the LaunchAgents can point at the app *binary* rather than at
// /bin/bash. macOS attributes Full Disk Access and Automation to the process
// that launched the work, so a bash-launched job is asking permission on
// behalf of Apple's own shell — which has no usage strings and which you
// cannot meaningfully grant. Going through the bundle means the grant the user
// gives to Memoe.app is the grant the connectors actually run under.
// `Moe --install-payload` lays ~/.moe down from inside the bundle and says
// what it did. It is what the app does at launch anyway, exposed as a verb for
// two reasons: it is the repair when a file in ~/.moe has been deleted ("Moe
// couldn't find its own setup file for this"), and it is how
// scripts/test-payload.sh checks the real binary against a scratch HOME rather
// than checking a Swift-shaped copy of the same logic.
// `Moe --fetch-models` warms every model a release bundles, which downloads
// them into FluidAudio's cache. scripts/fetch-models.sh runs this and then
// copies that cache into the repo's Models/ — so which files each repo needs
// comes from FluidAudio itself and cannot drift from what the app loads.
if args.count > 1, args[1] == "--fetch-models" {
    // A download of ~800 MB, so it runs to completion rather than racing the
    // run loop: the Task does the work and calls exit() itself.
    Task {
        let failures = await Models.fetchAll()
        print(failures == 0 ? "all models present" : "\(failures) model(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}

// `Moe --link-models` points FluidAudio's cache at the models inside this
// bundle. The app does it at launch; as a verb it is the repair, and it is
// how scripts/test-models.sh checks the real binary.
// `Moe --verify-models` loads every bundled model with downloads disabled —
// the only check that answers "does this app work on a Mac that has never
// downloaded anything". scripts/test-models.sh runs it with the real caches
// moved aside, which is the closest thing to a stranger's Mac this machine has.
// `Moe --bootstrap-json` reports what of Moe is on this Mac and where the
// app would find its own installer. It is the first question support has to
// ask ("is the thinking part even installed?") and the thing
// scripts/test-bootstrap.sh asserts on.
if args.count > 1, args[1] == "--bootstrap-json" {
    let st = Bootstrap.state()
    let obj: [String: Any] = [
        "hermes": st.hermes,
        "claudeCLI": st.claudeCLI,
        "canThink": st.canThink,
        "installer": Bootstrap.installerPath() ?? "",
        "payload": Payload.bundlePayload?.path ?? "",
        "models": Models.bundleModels?.path ?? "",
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

if args.count > 1, args[1] == "--verify-models" {
    Task {
        let failures = await Models.verifyOffline()
        print(failures == 0 ? "every bundled model loaded offline"
                            : "\(failures) model(s) could not load offline")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}

// `Moe --fetch-component <id> <root>`: fetch one on-demand component into a
// directory of your choosing, through the same fetcher the app uses, and say
// what happened. For proving the pinned download against the real host
// without touching this Mac's model caches. docs/SLIM-DOWNLOAD.md §7.
if args.count > 1, args[1] == "--fetch-component" {
    guard args.count > 3, let component = ComponentCatalog.named(args[2]) else {
        print("usage: Moe --fetch-component <\(ComponentCatalog.all.map(\.id).joined(separator: "|"))> <root>")
        exit(2)
    }
    let root = URL(fileURLWithPath: (args[3] as NSString).expandingTildeInPath, isDirectory: true)
    Task {
        do {
            let outcome = try await ComponentFetcher.shared.ensure(component, in: root)
            print(outcome == .fetched
                  ? "fetched \(component.id): \(component.files.count) files, \(component.size), every sha256 verified"
                  : "\(component.id) was already there; nothing fetched")
            exit(0)
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// `Moe --launch-models <dir>`: what a launch of this build does to the model
// caches, done to `<dir>/appsupport` and `<dir>/cache` instead. A directory is
// required — with none this would be the real caches, which is `--link-models`.
// Exit 0 when both on-demand models are present afterwards, 1 when not.
if args.count > 1, args[1] == "--launch-models" {
    guard args.count > 2 else {
        print("usage: Moe --launch-models <dir>")
        exit(2)
    }
    setvbuf(stdout, nil, _IONBF, 0)
    exit(OnDemandModels.rehearseLaunch(under: URL(
        fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)))
}

// `Moe --load-components <dir>`: load both on-demand models out of
// `<dir>/appsupport` through FluidAudio — Core ML actually opening them —
// with every download refused. The question the slim update turns on: are
// the models a `prepare` build left behind ones the next build can use?
if args.count > 1, args[1] == "--load-components" {
    guard args.count > 2 else {
        print("usage: Moe --load-components <dir>")
        exit(2)
    }
    setvbuf(stdout, nil, _IONBF, 0)
    let root = Models.Root.appSupport.url(under: URL(
        fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true))
    Task {
        ModelHub.offlineMode = true
        var failures = 0
        do {
            let dir = root.appendingPathComponent(ComponentCatalog.vocabularyBoost.folder, isDirectory: true)
            _ = try await CtcModels.downloadAndLoad(to: dir)
            _ = try await CtcTokenizer.load(from: dir)
            print("✓ vocabulary-boost loaded from \(dir.path), network off")
        } catch {
            failures += 1
            print("✗ vocabulary-boost: \(error)")
        }
        do {
            let dir = root.appendingPathComponent(ComponentCatalog.speakerDiarization.folder, isDirectory: true)
            _ = try await DiarizerModels.downloadIfNeeded(to: dir)
            print("✓ speaker-diarization loaded from \(dir.path), network off")
        } catch {
            failures += 1
            print("✗ speaker-diarization: \(error)")
        }
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}

if args.count > 1, args[1] == "--link-models" {
    if args.count > 2 {
        let base = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath,
                       isDirectory: true)
        print(Models.linkIfNeeded(rootsUnder: base))
    } else {
        print(Models.linkIfNeeded())
    }
    exit(0)
}

if args.count > 1, args[1] == "--install-payload" {
    // An explicit destination, not $HOME: FileManager.homeDirectoryForCurrentUser
    // ignores the environment for a non-sandboxed process, so a test that
    // exported HOME would silently write into the real ~/.moe instead — which
    // is exactly what happened the first time this was tried.
    if args.count > 2 {
        let dir = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath,
                      isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print(Payload.installIfNeeded(into: dir))
    } else {
        FirstRun.installHomeIfNeeded()
        print(Payload.installIfNeeded())
    }
    exit(0)
}

// `Moe --install-hermes-seed <dir>` lays the bundled Hermes down at <dir>,
// exactly as first run does, and says what happened.
//
// It exists for the same reason `--install-payload` does: without it, the only
// way to check 200 lines of code that `rm -rf`s and rewrites things inside a
// person's ~/.hermes was to reimplement the substitution in the test and check
// *that* — which proves the seed is relocatable and says nothing about whether
// Moe relocates it correctly. The two can drift, and the drift is invisible.
//
// An explicit destination, never $HOME: `homeDirectoryForCurrentUser` ignores
// the environment for a non-sandboxed process, so a test that merely exported
// HOME would operate on the real ~/.hermes.
// `Moe --hermes-pin [script]` prints the HERMES_COMMIT this build ships, read
// from install-hermes.sh the way the launch check reads it — so a test can
// hold Moe's reading against `sed`'s and go red the day the two disagree.
if args.count > 1, args[1] == "--hermes-pin" {
    let path = args.count > 2 ? args[2] : HermesUpgrade.installerPath()
    guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("no installer"); exit(5)
    }
    guard let pin = HermesPin.parse(script: text) else { print("no pin"); exit(5) }
    print(pin)
    exit(0)
}

// `Moe --hermes-upgrade-check <hermes-home>` says what the launch check would
// decide about the Hermes at <hermes-home>/hermes-agent; `--hermes-upgrade`
// decides and, when the answer is "move it", does — through the same code the
// app runs at launch, against an explicit directory that is never $HOME.
// Exit codes are HermesUpgradeDecision.exitCode; a move that failed is 1.
// Banners are quiet here (the receipt line says whether one would have shown).
// `Moe --hermes-gateway-gate` drives HermesBrain.whenOwnGatewayUp against a
// real HermesSupervisor that has been stopped — the shape that trapped
// libdispatch when the gate read `standing` inside a `whenReady` callback.
// Exit 0 with a printed verdict is the whole test; a trap is exit 133.
if args.count > 1, args[1] == "--hermes-gateway-gate" {
    let config = Config.load()
    let supervisor = HermesSupervisor(config: config)
    supervisor.stop()
    let brain = HermesBrain(config: config, supervisor: supervisor)
    let done = DispatchSemaphore(value: 0)
    var verdict = "(no answer)"
    brain.whenOwnGatewayUp { ok, why in verdict = "gateway gate: \(ok) — \(why)"; done.signal() }
    if done.wait(timeout: .now() + 5) == .timedOut { print("gateway gate: HUNG — the callback never returned"); exit(3) }
    print(verdict)
    exit(0)
}

if args.count > 2, args[1] == "--hermes-upgrade-check" || args[1] == "--hermes-upgrade" {
    HermesUpgrade.quietBanners = true
    let home = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    // A check is read-only: no lock, no tidying, no venv moved. Only the
    // upgrade repairs first, the way the launch path does.
    if args[1] == "--hermes-upgrade" {
        for note in HermesUpgrade.tidy(home: home) { print("tidy: \(note)") }
    }
    let decision = HermesUpgrade.decide(home: home)
    print(decision.line)
    var move: (from: String, to: String)?
    var isSeed = false
    switch decision {
    case .upgrade(_, let from, let to): move = (from, to)
    case .repair(_, let head):          move = (head, head)
    case .seedRefresh(_, let from, let to): move = (from, to); isSeed = true
    default:                            break
    }
    if args[1] == "--hermes-upgrade", let (from, to) = move,
       let installer = HermesUpgrade.installerPath() {
        // Quitting mid-move is the app's applicationWillTerminate; here it is
        // SIGTERM/SIGINT. Either way the installer is stopped and the
        // rollback runs before the process exits. The source lives on a
        // global queue because the main thread is about to block in perform.
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let quit = { (sig: Int32) in
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                FileHandle.standardError.write(Data("signal \(sig): stopping the installer and putting Hermes back\n".utf8))
                HermesUpgrade.cancelForShutdown(wait: 30)
            }
            src.resume()
            return src
        }
        let sources = [quit(SIGTERM), quit(SIGINT)]
        let onLine: (String) -> Void = { print("  \($0)") }
        let outcome = isSeed
            ? HermesUpgrade.performSeedRefresh(home: home, from: from, to: to, installer: installer, onLine: onLine)
            : HermesUpgrade.perform(home: home, from: from, to: to, installer: installer, onLine: onLine)
        sources.forEach { $0.cancel() }
        let notified = HermesUpgrade.receipt(outcome.line, notify: outcome.notify)
        print(outcome.line)
        print("notify: \(notified ? "yes" : "no")")
        let now = HermesUpgrade.commitOnDisk(home: home, isSeed: isSeed)
        let stale = HermesUpgrade.gatewayIsStale(moved: outcome.moved, bootedOn: from, onDisk: now)
        print("gateway: \(stale ? "would restart — the tree is now \(now.map(HermesPin.short) ?? "unreadable")" : "left alone")")
        Log.flush()
        exit(outcome.moved ? 0 : 1)
    }
    let notified = HermesUpgrade.record(decision)
    print("notify: \(notified ? "yes" : "no")")
    Log.flush()
    exit(decision.exitCode)
}

if args.count > 1, args[1] == "--install-hermes-seed" {
    guard args.count > 2 else {
        FileHandle.standardError.write(Data("usage: Moe --install-hermes-seed <dir>\n".utf8))
        exit(2)
    }
    let dir = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    print(HermesSeed.installIfNeeded(into: dir))
    exit(0)
}

// `Moe --launchable <path>…` prints yes/no per path: would Moe treat it as a
// runnable Hermes? scripts/test-hermes-launchable.sh holds the dead-wrapper
// case that kept a fresh download from ever installing its brain.
if args.count > 1, args[1] == "--launchable" {
    for path in args.dropFirst(2) {
        print("\(Paths.isLaunchable(path) ? "yes" : "no")\t\(path)")
    }
    exit(0)
}

// `Moe --jobs-ailment <launchctl-print-file> [0|1]` — what Moe makes of a
// background agent in that state, without touching launchd. The second
// argument stands in for "the job description is on disk" (1 by default).
// scripts/test-background-jobs.sh drives it with a real `launchctl print` of
// the job that had parked itself on the owner's Mac.
if args.count > 1, args[1] == "--jobs-ailment" {
    guard args.count > 2 else {
        FileHandle.standardError.write(Data("usage: Moe --jobs-ailment <file> [0|1]\n".utf8))
        exit(2)
    }
    let text = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
    let plist = args.count > 3 ? args[3] != "0" : true
    print(MainActor.assumeIsolated { Launchd.jobsAilment(printOutput: text, plistExists: plist) } ?? "ok")
    exit(0)
}

if args.count > 1, args[1] == "--sync" {
    var script = Paths.home.appendingPathComponent("sync.sh")
    if !FileManager.default.isExecutableFile(atPath: script.path) {
        // A LaunchAgent runs this every ten minutes and it is the only thing
        // that fills ~/.moe/context, so a missing sync.sh is a silent, endless
        // failure. The app carries its own copy, so lay the payload down and
        // look again rather than giving up — this is the entry point most
        // likely to be running on a home that was never populated.
        FirstRun.installHomeIfNeeded()
        if !FileManager.default.isExecutableFile(atPath: script.path),
           let b = Payload.bundlePayload {
            script = b.appendingPathComponent("sync.sh")
        }
    }
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
        FileHandle.standardError.write(Data("no sync.sh at \(script.path)\n".utf8))
        exit(1)
    }
    // This used to elect an hourly "digest" — a `claude -p` call that was to
    // distil the brief into memory/*.md — on one run in six. That call never
    // worked (its prompt sat after `--add-dir`, which swallows it) and went
    // around Hermes besides. The work is Hermes's `moe-proactive` cron job
    // now (moe-home/hermes-jobs/), on its own clock, in Hermes's own memory;
    // every sync is a plain context refresh.
    let syncArgs = Array(args.dropFirst(2))

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path] + syncArgs
    p.currentDirectoryURL = Paths.home
    var env = ProcessInfo.processInfo.environment
    env["USER"] = NSUserName()
    env["HOME"] = NSHomeDirectory()
    env["PATH"] = BrainSetup.pathWithMoePython(
        "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
        + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"))
    p.environment = env
    do { try p.run() } catch {
        FileHandle.standardError.write(Data("could not run sync: \(error)\n".utf8))
        exit(1)
    }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

// `Moe --calendar` / `--reminders` / `--add-reminder` / `--add-event`: the
// Calendar and Reminders connectors, through EventKit rather than
// AppleScript, so nothing launches Calendar.app or Reminders.app on the sync
// timer. Text shapes and flags: Sources/Moe/Connectors/EventKitBridge.swift.
if args.count > 1 {
    switch args[1] {
    case "--calendar":     await EventKitBridge.calendar(args.dropFirst(2))
    case "--reminders":    await EventKitBridge.reminders(args.dropFirst(2))
    case "--add-reminder": await EventKitBridge.addReminder(args.dropFirst(2))
    case "--add-event":    await EventKitBridge.addEvent(args.dropFirst(2))
    case "--eventkit-request": await EventKitBridge.request()
    // Contacts, the same way: Sources/Moe/Connectors/ContactsBridge.swift.
    case "--contacts":     await ContactsBridge.run(args.dropFirst(2))
    default: break
    }
}

// `Moe --meeting-capture screenshot [reason]` / `record start|stop [reason]`
// / `status`: the agent's way to a picture during a meeting. Writes
// ~/.moe/meeting-command.json for the running app and waits for its answer.
// Never starts or stops a meeting. Sources/Moe/Meeting/MeetingCapture.swift.
if args.count > 2, args[1] == "--meeting-capture" {
    exit(MeetingCaptureCLI.run(Array(args.dropFirst(2))))
}

// `Moe --capture-test <out-dir> [live]`: the meeting screenshot and clip
// writers over a synthetic frame (no permission needed), and with `live`
// real captures of this screen. scripts/test-meeting-capture.sh.
if args.count > 2, args[1] == "--capture-test" {
    let code: Int32 = await MeetingCaptureSmokeTest.run(Array(args.dropFirst(2)))
    Log.flush()
    exit(code)
}

// `Moe --transcribe <file>` prints what an audio file says, using the same
// on-device model that hears you. Used for WhatsApp voice notes.
if args.count > 2, args[1] == "--transcribe" {
    let path = args[2]
    guard FileManager.default.fileExists(atPath: path) else {
        FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
        exit(1)
    }
    let text = await Transcriber.transcribe(path: path)
    print(text)
    exit(text.isEmpty ? 1 : 0)
}

// `Moe --stt-test` runs the synthetic loop; `Moe --stt-test <audio> <locale>`
// transcribes one file the way that language would be, printing load and
// transcription times.
if args.count > 1, args[1] == "--stt-test" {
    let code = args.count > 3
        ? await SttSelfTest.run(file: args[2], locale: args[3])
        : await SttSelfTest.run()
    exit(code)
}

// `Moe --stt-bench <dir> [locale]` scores every clip in a directory against
// its reference and prints pooled totals — the "did this change help" run.
// Models load once for the whole set. See SttBench.
if args.count > 2, args[1] == "--stt-bench" {
    exit(await SttBench.run(directory: args[2], locale: args.count > 3 ? args[3] : "en-US"))
}

// `Moe --tts-bench [engine…]` times every speech engine on *this* Mac: how
// long until the first sample exists, and how long the whole utterance takes.
// The two are the same number for every backend but PocketTTS, which is the
// finding. Named engines only, or all four. See TtsBench.
if args.count > 1, args[1] == "--tts-bench" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "tts-bench.log"
    exit(await TtsBench.run(engines: Array(args.dropFirst(2))))
}

// `Moe --tts-samples <dir> [engine…]` renders the same two sentences with
// each engine to WAVs, because how a voice *sounds* is the half of the
// choice no benchmark answers. See TtsBench.auditionLines.
if args.count > 2, args[1] == "--tts-samples" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "tts-bench.log"
    exit(await TtsBench.writeSamples(to: args[2], engines: Array(args.dropFirst(3))))
}

// `Moe --tts-ladder <dir> [engine…]` renders one engine at several tunings
// and reports the pace each one actually achieved — the settings half of
// "make it sound human", which a single sample cannot answer. See TtsTuning.
// `Moe --tts-say "<sentence>" [engine…] [speed]` renders your own words with
// each engine at the tuning Moe would use and plays them back, announced. The
// only test that answers "do I want to listen to this". See TtsBench.
if args.count > 2, args[1] == "--tts-say" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "tts-bench.log"
    exit(await TtsBench.sayAloud(args[2], engines: Array(args.dropFirst(3))))
}

// `Moe --tts-audition <dir> [engine…]` renders the same five sentences
// through the engines Moe does not ship, so they can be listened to before
// one is chosen. Nothing here is wired into TtsEngineKind; see TtsAudition.
if args.count > 2, args[1] == "--tts-audition" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "tts-bench.log"
    exit(await TtsAudition.run(outDir: args[2], engines: Array(args.dropFirst(3))))
}

if args.count > 2, args[1] == "--tts-ladder" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "tts-bench.log"
    exit(await TtsBench.writeLadder(to: args[2], engines: Array(args.dropFirst(3))))
}

// `Moe --context-terms [seconds]` counts down, then prints what the screen
// harvest would hand the dictation in front of you — and how long it took to
// read. The one way to see a feature whose whole job is to be invisible.
if args.count > 1, args[1] == "--context-terms" {
    exit(await ContextTermsSelfTest.run(after: args.count > 2 ? Int(args[2]) ?? 5 : 5))
}

// `Moe --wake-score <dir> <file.f32>…` scores raw 16 kHz float32 windows
// with the wake head in <dir> (melspectrogram.onnx, embedding_model.onnx,
// hey-moe.onnx) and prints one score per file — the check of the Swift
// port against the reference runtime's numbers (VOICE-PLAN.md §4.1).
if args.count > 3, args[1] == "--wake-score" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "wake-cli.log"
    let head = WakeHead()
    do {
        try await head.load(from: URL(fileURLWithPath: args[2]))
    } catch {
        print("load failed: \(error)"); exit(2)
    }
    for path in args[3...] {
        guard let data = FileManager.default.contents(atPath: path) else { print("\(path): unreadable"); continue }
        let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let began = Date()
        do {
            let score = try await head.score(samples)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            print("\(URL(fileURLWithPath: path).lastPathComponent) \(score) (\(ms) ms)")
        } catch {
            print("\(path): \(error)")
        }
    }
    exit(0)
}

// `Moe --turn-score <wav>…`: Smart Turn's probability for each file as it
// is (the last 8 s, nothing trimmed), through the app's own features and
// session — the parity check against the Python scores for a model. Which
// model: the one the app would load, or `MOE_TURN_MODEL=<name or path>`.
if args.count > 2, args[1] == "--turn-score" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "turn-score.log"
    let detector = SmartTurnDetector()
    do { try await detector.load() } catch { print("load failed: \(error)"); exit(2) }
    print("model: \(await detector.modelName ?? "?")")
    for path in args.dropFirst(2) {
        guard let (mono, rate) = WakeBench.decode(URL(fileURLWithPath: path)), rate == AudioPipeline.rate else {
            print("\(path): unreadable or not 16 kHz"); continue
        }
        let audio = Array(mono.suffix(WhisperFeatures.samples))
        if let p = (try? await detector.probabilityComplete(audio)) ?? nil {
            print(String(format: "%@ %.6f", URL(fileURLWithPath: path).lastPathComponent, p))
        }
    }
    exit(0)
}

// `Moe --turn-bench <corpus-dir> <tapes.json> [tail…] [--limit n]`: every
// file of an unpacked eot-bench corpus (scripts/turnbench/eot_prep.py)
// through the real pipeline and Smart Turn, written as replayable tapes.
// `Moe --turn-replay <tapes.json> [options]`: the policy over those tapes —
// cut-offs against latency, for the shipped tuning or a sweep. TurnBench.
// `Moe --turn-bench --corpus <dir> [options]`: Tier 1 over the noisy
// conversation corpus (scripts/turnbench/mix.py) — cut-offs, endpoint
// latency, false and missed barge-ins, stop latency, per SNR. TurnBenchCorpus.
if args.count > 3, args[1] == "--turn-bench", args[2] == "--corpus" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "turn-bench.log"
    exit(await TurnBench.corpus(Array(args.dropFirst(2))))
}
if args.count > 3, args[1] == "--turn-bench" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "turn-bench.log"
    var rest = Array(args.dropFirst(4))
    var limit: Int?
    if let i = rest.firstIndex(of: "--limit"), i + 1 < rest.count {
        limit = Int(rest[i + 1]); rest.removeSubrange(i...(i + 1))
    }
    let keeps = rest.compactMap(Double.init)
    exit(await TurnBench.record(dir: URL(fileURLWithPath: args[2]), out: URL(fileURLWithPath: args[3]),
                                keeps: keeps.isEmpty ? [TurnAudio.pauseTheModelWasTrainedOn] : keeps,
                                limit: limit))
}
// `Moe --turn-semantics <texts.txt> <out.json>`: Apple's on-device model
// asked "finished, or more coming?" about each line, timed — the table the
// turn bench replays the semantic vote from (`--model-table`).
// `Moe --turn-read <texts.txt>`: the word rules' reading of each line
// (`TurnSemantics.read`), tab-separated after it — for scoring the rules on
// transcripts outside the app (eot-bench's word timings).
if args.count > 2, args[1] == "--turn-read" {
    guard let input = try? String(contentsOfFile: args[2], encoding: .utf8) else { print("unreadable \(args[2])"); exit(2) }
    for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
        print("\(TurnSemantics.read(String(line)).rawValue)\t\(line)")
    }
    exit(0)
}
if args.count > 3, args[1] == "--turn-semantics" {
    setvbuf(stdout, nil, _IONBF, 0)
    exit(await TurnSemanticJudge.measure(Array(args.dropFirst(2))))
}
if args.count > 2, args[1] == "--turn-replay" {
    setvbuf(stdout, nil, _IONBF, 0)
    exit(TurnBench.replay(Array(args.dropFirst(2))))
}

// `Moe --wake-bench <dir> <audio or directory>…`: the false-accept and
// recall measurement (VOICE-PLAN.md §4.1, §7). Every file goes through the
// real pipeline — VAD gating, stride-aligned windows, the policy — and
// each detection is printed with its time. Files under a path containing
// "positive" count towards recall; everything else towards false accepts
// per hour. WAV, FLAC, AIFF, anything AVAudioFile reads.
if args.count > 3, args[1] == "--wake-bench" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "wake-cli.log"
    let head = WakeHead()
    do { try await head.load(from: URL(fileURLWithPath: args[2])) } catch { print("load failed: \(error)"); exit(2) }
    var policy = await head.policy
    let vad: VadManager
    do { vad = try await VadManager() } catch { print("VAD failed: \(error)"); exit(2) }

    // `--threshold t`: the head at another threshold (the run length and the
    // emphatic window stay the sidecar's). `--confirm`: every hit is read by
    // the local recogniser and counts only if the name is in it — the second
    // stage the app runs (`WakeConfirm`).
    var rest = Array(args[3...])
    if let i = rest.firstIndex(of: "--threshold"), i + 1 < rest.count, let t = Float(rest[i + 1]) {
        policy = policy.withThreshold(t)
        rest.removeSubrange(i...(i + 1))
    }
    var confirmer: ParakeetBackend?
    if let i = rest.firstIndex(of: "--confirm") {
        rest.remove(at: i)
        let p = ParakeetBackend()
        do { try await p.warmUp(progress: nil) } catch { print("recogniser failed: \(error)"); exit(2) }
        confirmer = p
    }
    let spotter = WakeSpotter(phrases: WakeSpotter.defaultPhrases)
    var refusedByConfirm = 0, confirmMs: [Double] = []

    var files: [URL] = []
    for arg in rest {
        let url = URL(fileURLWithPath: arg)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            files.append(contentsOf: WakeBench.files(under: url))
        } else {
            files.append(url)
        }
    }
    files.sort { $0.path < $1.path }
    let positiveCount = files.filter { WakeRecordings.isPositive($0) }.count
    print("wake bench: \(files.count) files (\(positiveCount) positive), threshold \(policy.threshold), strong \(policy.strongThreshold), hits \(policy.requiredHits)\(confirmer == nil ? "" : ", every hit confirmed by the recogniser")")

    var negativeSeconds = 0.0, negativeHits = 0
    var positives = 0, positivesHit = 0
    var misses: [String] = []
    var falseFiles: [String] = []
    let trace = ProcessInfo.processInfo.environment["MOE_WAKE_TRACE"] != nil
    for file in files {
        guard let (mono, rate) = WakeBench.decode(file) else {
            print("  \(file.lastPathComponent): unreadable"); continue
        }
        let seconds = Double(mono.count) / rate
        // The same replay Settings runs over the person's own clips
        // (`VoiceEngine.measureWakeTeach`): one measurement, two readers.
        var replay = await WakeBench.replay(mono, rate: rate, head: head, vad: vad, policy: policy)
        if let confirmer {
            let before = replay.hits.count
            let t0 = Date()
            replay.hits = await WakeBench.confirmed(replay.hits, mono: mono, rate: rate, asr: confirmer, spotter: spotter)
            if before > 0 { confirmMs.append(Date().timeIntervalSince(t0) * 1000 / Double(before)) }
            refusedByConfirm += before - replay.hits.count
        }
        // Times are file times: the replay's clock includes its lead-in.
        let hits = replay.hits.map { (time: $0.time - WakeBench.leadSeconds, score: $0.score) }

        let isPositive = WakeRecordings.isPositive(file)
        let stamps = hits.map { String(format: "%.2fs=%.2f", $0.time, $0.score) }.joined(separator: " ")
        let peak = String(format: "peak %.2f", replay.peak)
        if isPositive {
            positives += 1
            if hits.isEmpty { misses.append(file.lastPathComponent) } else { positivesHit += 1 }
            print("  \(hits.isEmpty ? "MISS" : "hit ") \(file.lastPathComponent) \(peak)\(stamps.isEmpty ? "" : " @ " + stamps)")
        } else {
            negativeSeconds += seconds
            negativeHits += hits.count
            if !hits.isEmpty {
                falseFiles.append(file.lastPathComponent)
                print("  FALSE \(file.lastPathComponent) \(peak) @ \(stamps)")
            } else if trace {
                print("  ok    \(file.lastPathComponent) \(peak)")
            }
        }
        if trace {
            // Four decimals: the sweep replays the policy on these numbers
            // and a threshold sits exactly on a two-decimal boundary.
            print("        " + replay.trace.map { String(format: "%.2f:%.4f", $0.time - WakeBench.leadSeconds, $0.score) }.joined(separator: " "))
        }
    }
    print(String(repeating: "─", count: 62))
    if confirmer != nil {
        let ms = confirmMs.isEmpty ? 0 : confirmMs.reduce(0, +) / Double(confirmMs.count)
        print(String(format: "second stage: %d head hit(s) refused, %.0f ms a check", refusedByConfirm, ms))
    }
    if positives > 0 {
        print(String(format: "recall: %d/%d (%.1f%%)", positivesHit, positives, 100.0 * Double(positivesHit) / Double(positives)))
        if !misses.isEmpty { print("  missed: \(misses.joined(separator: ", "))") }
    }
    if negativeSeconds > 0 {
        let hours = negativeSeconds / 3600
        print(String(format: "false accepts: %d in %.2f h = %.2f/h", negativeHits, hours, Double(negativeHits) / hours))
    }
    exit(0)
}

// `Moe --wake-pick <dir> <recordings>`: what Settings › Voice › "Teach Moe
// its name" does after the recording, from the Terminal and without
// writing anything — every clip under <recordings> through the bench,
// then the threshold WakeCalibration picks for it and the sentence the
// pane would show. Positives are the files under a "positive" directory,
// as for --wake-bench. Prints the number; apply it in the app.
if args.count > 3, args[1] == "--wake-pick" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "wake-cli.log"
    let head = WakeHead()
    do { try await head.load(from: URL(fileURLWithPath: args[2])) } catch { print("load failed: \(error)"); exit(2) }
    let vad: VadManager
    do { vad = try await VadManager() } catch { print("VAD failed: \(error)"); exit(2) }
    let shipped = await head.shippedPolicy
    let current = await head.policy
    var positives: [[WakeCalibration.Sample]] = []
    var others: [[WakeCalibration.Sample]] = []
    for file in WakeBench.files(under: URL(fileURLWithPath: args[3])) {
        guard let (mono, rate) = WakeBench.decode(file) else { print("  \(file.lastPathComponent): unreadable"); continue }
        let replay = await WakeBench.replay(mono, rate: rate, head: head, vad: vad, policy: current)
        if WakeRecordings.isPositive(file) { positives.append(replay.trace) } else { others.append(replay.trace) }
        print(String(format: "  %@ %@ peak %.2f", WakeRecordings.isPositive(file) ? "name " : "other", file.lastPathComponent, replay.peak))
    }
    guard let pick = WakeCalibration.pick(positives: positives, confusables: others, shipped: shipped, current: current) else {
        print("nothing to measure: no clip under a positive/ directory"); exit(1)
    }
    print(String(repeating: "─", count: 62))
    print(String(format: "threshold %.2f (running %.2f, shipped %.2f)", pick.threshold, current.threshold, shipped.threshold))
    print(WakeCalibration.summary(pick, changed: pick.threshold != current.threshold))
    exit(0)
}

// `Moe --wake-record [dir]`: record the wake word in the room it has to
// work in. Prints a line, waits until you say it, saves a 16 kHz WAV where
// `--wake-bench` and the trainer already look, and moves on.
//
// The shipped head was trained on synthesised speech alone, and its errors
// are the errors that comes with: 56/72 recall, 6 false accepts in 48
// confusable phrases. That is a data problem, and the missing data is one
// person's voice in one room — ten minutes of it. It stayed missing while
// the ask was a paragraph of instructions, so this is the paragraph made
// into something you can sit down and do.
if args.count > 1, args[1] == "--wake-record" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "wake-cli.log"
    let outDir = URL(fileURLWithPath: args.count > 2 ? args[2]
                     : NSString(string: "~/.moe/voice/recordings").expandingTildeInPath)

    guard await VoiceEngine.requestMicrophone() else {
        print("Moe cannot reach the microphone. Grant it in System Settings › Privacy & Security › Microphone.")
        exit(2)
    }

    // Speech boundaries come from the VAD, off the pipeline's sink. No
    // recogniser and no wake head: nothing here needs to know what was
    // said, only when it started and stopped.
    let speech = SpeechGate()
    let pipeline = AudioPipeline(sink: { out in
        switch out {
        case .speechStarted: Task { await speech.set(true) }
        case .speechEnded: Task { await speech.set(false) }
        default: break
        }
    })
    do {
        let vad = try await VadManager()
        await pipeline.attach(vad: vad)
    } catch {
        print("The voice activity detector failed to load: \(error)")
        exit(2)
    }
    let frontEnd = await MainActor.run { AudioFrontEnd(pipeline: pipeline) }
    do { try await MainActor.run { try frontEnd.start() } } catch {
        print("The microphone is unavailable: \(error.localizedDescription)")
        exit(2)
    }
    await pipeline.setCapture(true, prerollSeconds: 0.5)

    let script = WakeRecorder.script()
    let counts = Dictionary(grouping: script, by: { $0.folder }).mapValues { $0.count }
    print("")
    print("Moe — recording the wake word")
    print(String(repeating: "─", count: 62))
    print("\(script.count) short clips: \(counts["positive"] ?? 0) with the name, "
          + "\(counts["confusable"] ?? 0) near misses, \(counts["negative"] ?? 0) ordinary speech.")
    print("Say each line when it appears. It saves on its own when you stop talking.")
    print("Silence for 25 seconds skips a line. Ctrl-C stops — what is recorded is kept.")
    print("Saving to \(outDir.path)")
    print("")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    var saved = 0, skipped = 0, quiet = 0
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    let session = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")

    for (i, prompt) in script.enumerated() {
        print(String(format: "  %3d/%d  %@", i + 1, script.count, prompt.say))
        print("          (\(prompt.note))")
        // A moment to read the line, then everything before "go" is thrown
        // away — including the tail of the previous clip.
        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = await pipeline.takeCapture()

        // Wait for the person to begin, noting where in the capture that
        // was. The capture runs continuously, so without the marks a clip
        // is the phrase plus however long it took to read the line —
        // "Hey Moe" arrives as five seconds of mostly room. Silence around
        // the phrase is not neutral padding: it is most of what a two
        // second window sees, and a head trained on it learns the silence.
        var waited = 0.0
        while await !speech.on, waited < 25 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard await speech.on else {
            print("          skipped\n")
            skipped += 1
            continue
        }
        let began = await pipeline.captureSeconds
        var speaking = 0.0
        while await speech.on, speaking < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            speaking += 0.1
        }
        let ended = await pipeline.captureSeconds
        // The 0.4 s is the VAD's own lag plus a little tail, so the last
        // consonant is inside the clip rather than clipped off it — a head
        // trained on truncated words learns truncated words.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let whole = await pipeline.takeCapture()
        let samples = WakeRecorder.trim(whole, from: began, to: ended,
                                        head: 0.35, tail: 0.45)
        let seconds = Double(samples.count) / AudioPipeline.rate
        let peak = WakeRecorder.peak(samples)

        // Two ways a clip is worse than nothing. Too quiet and it teaches
        // the model that the name sounds like the room; clipped and it
        // teaches it that the name sounds like distortion. Neither is
        // visible later, in a folder of six hundred files.
        guard seconds > 0.3 else {
            print("          too short, skipped\n"); skipped += 1; continue
        }
        if peak < 0.02 {
            print(String(format: "          too quiet (peak %.3f) — not saved, move closer\n", peak))
            quiet += 1
            continue
        }
        let folder = outDir.appendingPathComponent(prompt.folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%@-%03d.wav", session, i + 1)
        do {
            try WakeRecorder.write(samples, to: folder.appendingPathComponent(name))
            saved += 1
            let clipped = peak > 0.99 ? "  ⚠︎ clipping — move back a little" : ""
            print(String(format: "          saved %.1f s, peak %.2f%@\n", seconds, peak, clipped))
        } catch {
            print("          could not save: \(error.localizedDescription)\n")
        }
    }

    await pipeline.setCapture(false, prerollSeconds: 0)
    await MainActor.run { frontEnd.stop() }
    print(String(repeating: "─", count: 62))
    print("\(saved) saved, \(skipped) skipped, \(quiet) too quiet — in \(outDir.path)")
    print("")
    print("What to do with them:")
    print("  Measure the head you have against your own voice —")
    print("    \(Bundle.main.bundlePath)/Contents/MacOS/Moe --wake-bench \\")
    print("      \(Bundle.main.bundlePath)/Contents/Resources/WakeWord \\")
    print("      \(outDir.path)")
    print("  Then retrain with them folded in: scripts/wakeword/README.md")
    print("  Or, in the app: Settings › Voice › Teach Moe its name scores every clip in")
    print("  this folder and picks the threshold for this Mac — no retrain needed.")
    Log.flush()
    exit(0)
}

// `Moe --wake-slide <dir> <file.f32>`: slide a two-second window over a
// longer float32 file one stride at a time, scoring each position both
// ways — full run and incremental — and report the largest difference
// and the cost of each. The incremental path must be exact.
if args.count == 4, args[1] == "--wake-slide" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "wake-cli.log"
    let head = WakeHead()
    let full = WakeHead()
    do {
        try await head.load(from: URL(fileURLWithPath: args[2]))
        try await full.load(from: URL(fileURLWithPath: args[2]))
    } catch { print("load failed: \(error)"); exit(2) }
    guard let data = FileManager.default.contents(atPath: args[3]) else { print("unreadable"); exit(2) }
    let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    var maxDiff: Float = 0
    var incMs = 0.0, fullMs = 0.0, n = 0
    var end = WakeHead.windowSamples
    var contiguous = false
    var peak: Float = 0
    while end <= samples.count {
        let window = Array(samples[(end - WakeHead.windowSamples) ..< end])
        var t = Date()
        let a = (try? await head.score(window, contiguous: contiguous)) ?? -1
        incMs += Date().timeIntervalSince(t) * 1000
        t = Date()
        let b = (try? await full.score(window)) ?? -1
        fullMs += Date().timeIntervalSince(t) * 1000
        maxDiff = max(maxDiff, abs(a - b))
        peak = max(peak, b)
        n += 1
        contiguous = true
        end += WakeHead.strideSamples
    }
    print("\(n) positions: max |incremental − full| = \(maxDiff), peak score \(peak)")
    print(String(format: "incremental %.1f ms, full %.1f ms per score", incMs / Double(max(n, 1)), fullMs / Double(max(n, 1))))
    exit(maxDiff < 1e-5 ? 0 : 1)
}

// `Moe --ai-check` says whether Apple's on-device model is usable here.
// Moe leans on it for the judgements that must work in any language —
// "was that for me", "are we done" — and when it is off those fall back
// to English rules, silently. This is how you find that out.
// `Moe --build-info` says what is in this binary and what is staged beside
// it, by running each thing rather than claiming it. Exits non-zero when a
// model the app expects to carry is missing. See BuildInfo — it exists
// because two of us diagnosed a live log without checking which binary
// wrote it, and both got it wrong.
if args.count > 1, args[1] == "--app-menus" {
    // Enumerating a menu bar needs Accessibility and nothing else — no
    // driver, no screenshot, no window. It is the cheapest question in the
    // whole computer-use area and the answer `invoke_menu` needs.
    await MainActor.run { AppMenus.main(args.dropFirst(2)) }
}

if args.count > 1, args[1] == "--build-info" {
    setvbuf(stdout, nil, _IONBF, 0)
    exit(BuildInfo.run())
}

if args.count > 1, args[1] == "--ai-check" {
    setvbuf(stdout, nil, _IONBF, 0)
    let status = await AppleOnDevicePolish().status()
    print(status.ready ? "on-device model: ready" : "on-device model: NOT available")
    print("  \(status.detail)")
    exit(status.ready ? 0 : 1)
}

// `Moe --read <audio>…` times the accurate re-read — the leg between "you
// stopped talking" and "Moe has your words", which the turn traces measure
// but nothing could reproduce on demand. Any file AVAudioFile reads.
if args.count > 2, args[1] == "--read" {
    setvbuf(stdout, nil, _IONBF, 0)
    Log.fileName = "voice-cli.log"
    let router = await MainActor.run { SpeechRouter.forUser() }
    let locale = Config.load().locale
    var warmed = Date()
    do {
        try await router.warmUp(locale: locale) { print("  \($0)") }
        print(String(format: "warm-up: %.1f s (%@)", Date().timeIntervalSince(warmed), locale))
    } catch {
        print("warm-up failed: \(error)")
    }
    for path in args[2...] {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let ch = buffer.floatChannelData else {
            print("\(path): unreadable"); continue
        }
        let n = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: n)
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels { for i in 0..<n { mono[i] += ch[c][i] / Float(channels) } }
        let rate = file.processingFormat.sampleRate
        let samples = rate == 16_000 ? mono : SpeechRouter.resample(mono, from: rate)
        warmed = Date()
        let text = (try? await router.transcribe(samples16k: samples, locale: locale)) ?? "<failed>"
        let seconds = Double(samples.count) / 16_000
        print(String(format: "%@  %.1f s audio → %.2f s  \"%@\"",
                     URL(fileURLWithPath: path).lastPathComponent, seconds,
                     Date().timeIntervalSince(warmed), text))
    }
    Log.flush()
    exit(0)
}

// `Moe --voice-test` proves the local voice loop before any UI exists:
// downloads the CoreML models, speaks a sentence so you can judge the voice,
// then listens and prints what it heard.
if args.count > 1, args[1] == "--voice-test" {
    // stdout is fully buffered when piped, which hides every print()
    // behind FluidAudio's unbuffered os_log output.
    setvbuf(stdout, nil, _IONBF, 0)
    FirstRun.installHomeIfNeeded()
    let engine = await MainActor.run { VoiceEngine(config: Config.load()) }

    await MainActor.run {
        engine.onLoadProgress = { if !$0.isEmpty { print("  \($0)") } }
        engine.onError = { print("  error: \($0)") }
        engine.onPartial = { if !$0.isEmpty { print("  …\($0)", terminator: "\r"); fflush(stdout) } }
        engine.onUtterance = { text in
            print("\n  heard: \"\(text)\"")
            Task { @MainActor in
                engine.speak("You said: \(text)")
            }
        }
    }

    print("\nMoe — voice test")
    print(String(repeating: "─", count: 62))
    print("First run downloads the models; that takes a few minutes.\n")

    await engine.loadModels()

    print("\nSpeaking a test sentence — listen to the voice quality.\n")
    engine.speak("Hi, this is Moe. This is what I sound like now, "
                     + "running entirely on your Mac.")
    try? await Task.sleep(nanoseconds: 6_000_000_000)

    print("Now listening. Say something, then wait a moment.")
    print("It keeps listening until you press Ctrl-C.\n")
    await MainActor.run {
        // The window closes after 8 s of nothing; in a test that is just an
        // ended run. Open it again so the person can take their time.
        engine.onConversationEnded = {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                print("  (still listening)")
                engine.toggle()
            }
        }
    }
    engine.toggle()

    // Not `RunLoop.main.run()`: this is an async context, and blocking the
    // main thread here starves the main actor — the engine's timers and
    // callbacks never run, and the process falls through into the full
    // app below when the loop returns.
    while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
}

// `Moe --ask "question"` runs one turn through the same brain the GUI uses —
// whichever config.json names — prints the answer, and exits. Good for
// checking auth and wiring without bringing up the panel.
if args.count > 1, args[1] == "--ask" {
    let question = args.dropFirst(2).joined(separator: " ")
    guard !question.isEmpty else {
        FileHandle.standardError.write(Data("usage: Moe --ask \"your question\"\n".utf8))
        exit(2)
    }
    FirstRun.installHomeIfNeeded()
    let bridge = BrainFactory.make(config: Config.load())
    var failed = false
    // Every exit goes through here so a brain that owns a child process (the
    // Hermes gateway) gets to take it down first.
    // Debug-only hooks for scripts/test-hermes-supervisor.sh:
    // `MOE_ASK_LINGER=<seconds>` keeps Moe alive after the answer so the child
    // can be watched being supervised; `MOE_ASK_RETRY_ONCE=1` answers the
    // first failed launch with what New Conversation does — a reset — and
    // asks again. `MOE_ASK_RELAY_TRIGGER=<n>` fires the Away-enrolment relay
    // trigger n times once the gateway is up — the same call Settings › Away
    // makes — so the restart it does (or does not) do can be watched against a
    // real supervisor rather than argued about (CLOUD-PLAN 4a.2).
    func finish(_ code: Int32) -> Never {
        bridge.stop()
        exit(code)
    }
    /// The answer's exit. With the linger hook it is *scheduled* and this
    /// returns, so the outer run loop keeps delivering main-queue events —
    /// sleeping or spinning a nested run loop here, inside a main-queue
    /// block, would hold every later event (a supervisor failure, say)
    /// until exit.
    func finishAfterLinger(_ code: Int32) {
        guard let secs = TestHooks.env("MOE_ASK_LINGER").flatMap(Double.init), secs > 0 else { finish(code) }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { finish(code) }
    }
    var retried = false

    /// The debug hook above. Runs the real `RelayTrigger` against whatever
    /// `MOE_HERMES_CONFIGURE_SCRIPT` points at, n times in a row: once proves
    /// the restart happens, several times proves it is not counted as a crash
    /// (the give-up threshold is five).
    func fireRelayTriggerIfAsked(_ bridge: BrainProvider) {
        guard let times = TestHooks.env("MOE_ASK_RELAY_TRIGGER").flatMap(Int.init), times > 0
        else { return }
        // Spaced, not fired at once: a person clicks Away once, and six
        // simultaneous configure runs would be measuring a thundering herd
        // rather than the thing under test (that N restarts in a row do not
        // spend the crash budget).
        for i in 1...times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i - 1) * 3) {
                RelayTrigger.dialMayHaveMoved("test trigger \(i)") { reason in
                    (bridge as? HermesBrain)?.reloadGateway(reason: reason)
                }
            }
        }
    }

    var stallSent = false
    bridge.onEvent = { event in
        switch event {
        case .ready(let sid, let tools, let servers):
            let line = "session \(sid.prefix(8)) · \(tools.count) tools · connections: "
                     + "\(servers.isEmpty ? "none" : servers.joined(separator: ", "))\n"
            FileHandle.standardError.write(Data(line.utf8))
        case .textDelta(let t):
            FileHandle.standardOutput.write(Data(t.utf8))
        case .reasoningDelta:
            break
        case .toolStarted(_, _, let emoji, let d, _):
            FileHandle.standardError.write(Data("  \(emoji ?? "·") \(d)\n".utf8))
        case .toolFinished:
            break
        case .status(let line):
            FileHandle.standardError.write(Data("  status: \(line)\n".utf8))
        case .turnFinished(let answer, _):
            // Debug-only, for scripts/test-now-line.sh: `MOE_ASK_STALL_GUARD=1`
            // does what Conductor.continueIfStalled does — one continuation,
            // through the same send, when the answer ended on a promise.
            if TestHooks.env("MOE_ASK_STALL_GUARD") != nil, !stallSent,
               let promise = StallGuard.promise(in: answer) {
                stallSent = true
                FileHandle.standardError.write(Data("  stall guard: carrying on\n".utf8))
                bridge.send(StallGuard.note(for: promise), images: [], silent: false,
                            logAs: "(stall guard: carry on)", starter: .background)
                return
            }
            FileHandle.standardOutput.write(Data("\n".utf8))
            fireRelayTriggerIfAsked(bridge)
            finishAfterLinger(failed ? 1 : 0)
        case .error(let m):
            FileHandle.standardError.write(Data("error: \(m)\n".utf8))
            failed = true
        case .failedToLaunch(let m):
            FileHandle.standardError.write(Data("error: \(m)\n".utf8))
            if TestHooks.env("MOE_ASK_RETRY_ONCE") != nil, !retried {
                retried = true
                FileHandle.standardError.write(Data("retrying once (reset)\n".utf8))
                bridge.reset()
                bridge.send(question, starter: .person)
                return
            }
            // `MOE_ASK_RETRY_AFTER=<seconds>`: ask again after a wait, with
            // NO reset — so what answers is a supervisor that recovered on
            // its own, or nothing.
            if let secs = TestHooks.env("MOE_ASK_RETRY_AFTER").flatMap(Double.init), !retried {
                retried = true
                FileHandle.standardError.write(Data("asking again in \(Int(secs))s (no reset)\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                    // Only the send, as the Conductor does it. This used
                    // to call `bridge.start()` first "because that is what a
                    // next turn does after a failure" — nothing in the app
                    // did, so the check passed on a path no person takes
                    // while every real question got "Moe isn't connected".
                    bridge.send(question, starter: .person)
                }
                return
            }
            finish(1)
        case .exited(let c):
            FileHandle.standardError.write(Data("brain exited (\(c))\n".utf8))
            finish(c == 0 ? (failed ? 1 : 0) : c)
        case .notice(let m):
            // stderr, not stdout: `Moe --ask` is piped into other things, and
            // "93% of your limit used" is not part of the answer. But it is
            // the reason the next answer may not come, so it is not dropped.
            FileHandle.standardError.write(Data("notice: \(m)\n".utf8))
        }
    }

    // Debug-only, for scripts/test-turn-keeper.sh: `MOE_ASK_THREAD=<id>`
    // puts the turn on a thread (so the brain reports the open ask, which
    // it does for a thread and never for a bare session); `MOE_ASK_TASK_LOG`
    // is where those reports go, one JSON line each, in place of CloudSync;
    // `MOE_ASK_ARBITER=deny` answers "who holds it?" with "not you", the
    // way the edge does once the cloud has taken an ask.
    if let hermes = bridge as? HermesBrain {
        if let log = TestHooks.env("MOE_ASK_TASK_LOG") {
            hermes.onTask = { e in
                let line = "{\"op\":\"\(e.op.rawValue)\",\"task\":\"\(e.task)\",\"thread\":\"\(e.thread)\","
                         + "\"portable\":\(e.portable),\"status\":\"\(e.status)\"}\n"
                if let h = FileHandle(forWritingAtPath: log) ?? {
                    FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log)
                }() {
                    h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
                }
            }
        }
        if TestHooks.env("MOE_ASK_ARBITER") == "deny" {
            hermes.taskArbiter = { _, done in done(false) }
        }
    }
    // `MOE_TEST_AWAY_NOTIFICATIONS=<prefix>`: the same watcher the app runs,
    // so a `<prefix>.sleep` posted by the test (`Moe --post-notification`)
    // reaches the brain the way a real lid does — through
    // `PresenceWatcher`, not a flag set in `pumpLocked`.
    var askWatcher: PresenceWatcher?
    if PresenceWatcher.testPrefix != nil, let hermes = bridge as? HermesBrain {
        askWatcher = PresenceWatcher { event in
            switch event {
            case .willSleep: hermes.noteSystemSleep()
            case .didWake: hermes.noteSystemWake()
            default: break
            }
        }
        askWatcher?.start()
    }
    // `MOE_ASK_INTERRUPT_AFTER=<seconds>`: interrupt the turn (what a tap or
    // ⌘N does) and ask something else — to see what a re-issue waiting on a
    // sleep does when the person has moved on.
    if let secs = TestHooks.env("MOE_ASK_INTERRUPT_AFTER").flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            FileHandle.standardError.write(Data("  interrupting, then asking something else\n".utf8))
            bridge.abandonTurn()
            bridge.send("what time is it", starter: .person)
        }
    }
    if let thread = TestHooks.env("MOE_ASK_THREAD") { (bridge as? HermesBrain)?.threadForTests = thread }
    bridge.start()
    // Debug-only, for scripts/test-now-line.sh: `MOE_ASK_PRIME=<text>` resumes
    // a thread with that priming before the question — the path a reopened
    // conversation takes, which sends straight from inside the brain.
    if let prime = TestHooks.env("MOE_ASK_PRIME"), let hermes = bridge as? HermesBrain {
        hermes.resume(BrainResume(threadID: "now-line-test", sessionID: "now-line-test-session", priming: prime))
    }
    // Send immediately: the CLI stays silent — no init, nothing — until it
    // receives a first message, so waiting for "ready" deadlocks both sides.
    bridge.send(question, starter: .person)

    // Never hang forever in a script or a pipeline.
    DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
        FileHandle.standardError.write(Data("timed out after 5 minutes\n".utf8))
        bridge.stop()
        exit(124)
    }
    RunLoop.main.run()
}

// `Moe --screen-test [live] ["question"]` sends one turn the way a spoken one
// goes out — with a screenshot attached as an image_url data URL when
// config.json's screenContext is on — prints the reply, and exits. The
// image is synthetic (a drawn bitmap through the real downscale + JPEG
// path) so scripts/test-screen-context.sh needs no Screen Recording grant;
// `live` captures the real display under the mouse instead and reports its
// size. Never a click, never a file. Exit 0 on a finished turn.
if args.count > 1, args[1] == "--screen-test" {
    let live = args.contains("live")
    let question = args.dropFirst(2).filter { $0 != "live" }.joined(separator: " ")
    let config = Config.load()
    let bridge = BrainFactory.make(config: config)
    func finish(_ code: Int32) -> Never { Log.flush(); bridge.stop(); exit(code) }

    func synthetic() -> ScreenCapture? {
        // Photo-like noise so the JPEG is a realistic size, not a flat fill.
        let w = 2940, h = 1912
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        var rng = SystemRandomNumberGenerator()
        for i in stride(from: 0, to: 4000, by: 1) {
            let x = CGFloat(i % 80) * 36, y = CGFloat(i / 80) * 38
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 36, height: 38))
        }
        guard let image = ctx.makeImage() else { return nil }
        return ScreenContext.encode(image, displayFrame: CGRect(x: 0, y: 0, width: 1470, height: 956))
    }

    Task { @MainActor in
        var capture: ScreenCapture?
        let t0 = Date()
        if config.screenContext {
            if live {
                guard ScreenContext.hasPermission else {
                    FileHandle.standardError.write(Data("screen-test: no Screen Recording permission for this process\n".utf8))
                    finish(3)
                }
                capture = await ScreenContext.capture()
            } else {
                capture = synthetic()
            }
            guard let cap = capture else {
                FileHandle.standardError.write(Data("screen-test: capture failed\n".utf8))
                finish(4)
            }
            let payload = cap.attachment.dataURL.utf8.count
            let f = cap.displayFrame
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let line = "screen-test: \(cap.summary), data URL \(payload / 1024) KB, "
                     + "display \(Int(f.width))×\(Int(f.height)) pt at \(Int(f.origin.x)),\(Int(f.origin.y)), "
                     + "\(live ? "capture+encode" : "encode") \(ms) ms\n"
            FileHandle.standardError.write(Data(line.utf8))
            Log.write("screen: attached \(cap.summary)")
        } else {
            FileHandle.standardError.write(Data("screen-test: screenContext is off; sending text only\n".utf8))
        }
        var failed = false
        bridge.onEvent = { event in
            switch event {
            case .textDelta(let t): FileHandle.standardOutput.write(Data(t.utf8))
            case .turnFinished:
                FileHandle.standardOutput.write(Data("\n".utf8))
                finish(failed ? 1 : 0)
            case .error(let m), .failedToLaunch(let m):
                FileHandle.standardError.write(Data("error: \(m)\n".utf8)); failed = true
                if case .failedToLaunch = event { finish(1) }
            case .exited(let c): finish(c == 0 ? (failed ? 1 : 0) : c)
            case .ready, .toolStarted, .toolFinished, .status, .notice, .reasoningDelta: break
            }
        }
        bridge.start()
        bridge.send(question.isEmpty ? "What is on my screen?" : question,
                    images: capture.map { [$0.attachment] } ?? [], silent: false, logAs: nil,
                    starter: .person)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
        FileHandle.standardError.write(Data("timed out\n".utf8))
        bridge.stop(); exit(124)
    }
    // Everything above lands on the main queue; this drains it.
    dispatchMain()
}

// `Moe --polish-test "<text>" [bundle-id] [before-cursor]` runs one transcript
// through the dictation polisher — config.json's port, key and polish
// settings, a fake front app if a bundle id is given, and a fake
// text-before-the-cursor if one is given (the live path reads that through
// Accessibility, which no test can) — prints what would be pasted, and
// exits. For scripts/test-dictation-polish.sh; nothing is pasted anywhere.
// Exit 0 either way: the fallback to rules is a success too. stderr says
// which it was.
if args.count > 2, args[1] == "--polish-test" {
    let text = args[2]
    let app = args.count > 3
        ? PolishPrompt.FrontApp(bundleID: args[3], name: args[3].split(separator: ".").last.map(String.init) ?? args[3])
        : nil
    let before = args.count > 4 ? CursorContext.tidy(args[4]) : nil
    let config = Config.load()
    var out = text
    var how = "rules"
    if config.dictationPolish {
        let polisher = DictationPolisher(config: config, vocabulary: Conductor.vocabularyTerms)
        if let polished = await polisher.polish(text, app: app, before: before,
                                                budget: config.dictationPolishBudget) {
            out = polished
            how = "polished"
        }
    } else {
        how = "disabled"
    }
    FileHandle.standardError.write(Data("\(how)\n".utf8))
    FileHandle.standardOutput.write(Data((out + "\n").utf8))
    Log.flush()
    exit(0)
}

// `Moe --meeting-test <dir> [out-dir]` runs the meeting pipeline on a
// recorded pair — <dir>/system.wav + mic.wav, 16 kHz mono — exactly as the
// end of a live meeting does: 30 s windows through the app's recogniser,
// diarization of the system stream, the timeline, then the summary
// through config.json's brain (scripts/test-meeting.sh points that at
// fake-hermes). Writes transcript.txt, summary.md and meeting.json to
// out-dir (default: <dir>), prints the timeline, and exits 0 when the
// pipeline finished — even without notes, which stderr reports. No audio
// device is opened and nothing is played.
// `Moe --ax-dump-meeting [seconds] [out.json]`: what a live call's window
// actually says about who is speaking, recorded so that a parser can be
// written against a measurement rather than a guess. Reads only — no audio
// device is opened and no picture is taken. See ActiveSpeakerProbe.swift.
if args.count > 1, args[1] == "--ax-dump-meeting" {
    setvbuf(stdout, nil, _IONBF, 0)
    let seconds = args.count > 2 ? (Double(args[2]) ?? 60) : 60
    let out = URL(fileURLWithPath: args.count > 3 ? args[3]
                  : NSHomeDirectory() + "/.moe/logs/ax-meeting-dump.json")
    let code = ActiveSpeakerProbe.run(seconds: seconds, out: out)
    Log.flush()
    exit(code)
}

if args.count > 2, args[1] == "--meeting-test" {
    setvbuf(stdout, nil, _IONBF, 0)
    let src = URL(fileURLWithPath: args[2], isDirectory: true)
    let out = args.count > 3 ? URL(fileURLWithPath: args[3], isDirectory: true) : src
    let code: Int32 = await MeetingPipelineTest.run(source: src, out: out)
    Log.flush()
    exit(code)
}

// `Moe --signin-test [away]` runs the in-app Claude sign-in headless: `claude
// setup-token` from PATH under a pty, the URL it prints reported on stderr
// (not opened), the token stored through the keychain tool (a stub, in
// scripts/test-signin.sh). Prints "stored" on success; never the token.
//
// `away` is the Away brain sheet's destination — the real one, from
// `AwayBrainSetup.signInDestination`, not a lookalike built here. The token
// goes to `moe-brain-away.py` on stdin and this Mac's keychain is never
// called at all, which is what the test asserts: an empty stub log is the
// evidence that the away machine got a token of its own. Prints "sent".
//
// An argument that is not `away` is a **refusal**, not a fallback: `awya` used
// to select `.thisMac` silently, which is the destination that writes a
// keychain item — a typo choosing the more dangerous of two paths.
// The closed half's verbs (`--cloud-…`, `--away-…`, `--signin-landing`,
// `--signin-test away`, `--problem-reports`, `--privacy-rows`), when this
// build has one. Returns only when `args` is none of them.
Cloud.commandLine(args)

if args.count > 1, args[1] == "--signin-test" {
    // `away` (the away machine's destination) is the closed half's, above.
    guard args.count == 2 else {
        FileHandle.standardError.write(Data("usage: Moe --signin-test\n".utf8))
        exit(2)
    }
    exit(ClaudeSignIn.runHeadless(destination: .thisMac))
}

// `Moe --service-icon-check` reads service names on stdin, one per line, and
// prints `<name><TAB>art|symbol|monogram<TAB><width>x<height>` for each.
//
// It exists because "the file is in Resources/ServiceIcons" and "the row
// draws that company's logo" are different claims, and the first was passing
// while a rendered pane showed 119 coloured letters — the marks were on disk
// and no binary outside an .app bundle could find them. A file-existence
// test cannot see that, and neither can a person reading JSON. This asks the
// same `ServiceIcons.art` the screen asks and reports what came back.
if args.count > 1, args[1] == "--service-icon-check" {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    var out = ""
    for line in text.split(whereSeparator: \.isNewline) {
        let name = line.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        if let art = ServiceIcons.art(for: name) {
            out += "\(name)\tart\t\(Int(art.size.width))x\(Int(art.size.height))\n"
        } else if !ServiceIcons.macSymbol(for: name).isEmpty {
            out += "\(name)\tsymbol\t0x0\n"
        } else {
            out += "\(name)\tmonogram\t0x0\n"
        }
    }
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
}

// `Moe --connections-json` prints what the Connections screen would show —
// catalog rows with their connected state — as JSON, and exits. For
// scripts/test-connections-ui.sh, which points MOE_HOME/HERMES_HOME at a
// scratch world. The Mac-native checks are left out: they would read the
// real Calendar and Messages.
if args.count > 1, args[1] == "--connections-json" {
    print(ConnectionsModel.dumpJSON(Array(args.dropFirst(2))))
    exit(0)
}

// `Moe --permissions-json` prints the permission guide — the one place every
// macOS permission is explained (PermissionGuide.swift) — as JSON, and exits.
// scripts/test-connections-ui.sh uses it to prove no entry ships with an
// empty field: an unexplained permission is the whole failure mode this file
// exists to prevent.
if args.count > 1, args[1] == "--permissions-json" {
    print(PermissionGuide.dumpJSON())
    exit(0)
}

// `Moe --onboarding-json` prints the first-launch flow — the screens and
// their skip paths, the four ways to give Moe something to think with, and
// every provider's words (BrainGuide) — as JSON, and exits.
// scripts/test-onboarding.sh uses it to prove no provider ships without an
// explanation and a next step, and that no screen is a dead end.
if args.count > 1, args[1] == "--onboarding-json" {
    print(Onboarding.dumpJSON())
    exit(0)
}

// `Moe --relaunch-script <pid> <bundle-id>` prints the shell "Quit and
// reopen Moe" runs, so scripts/test-onboarding.sh can run it against a
// process of its own and prove it waits for that process to be gone.
if args.count > 3, args[1] == "--relaunch-script", let pid = Int32(args[2]) {
    print(Relaunch.script(pid: pid, bundleID: args[3]))
    exit(0)
}

// `Moe --panel-snapshot <dir> [prefix]` renders the island's real views to PNG at real
// point sizes, over a stand-in notch and a stand-in video call, and exits.
// docs/PANEL-FINDINGS.md §9. No microphone, no meeting, no brain, no window,
// and MOE_HOME is repointed at a scratch directory inside <dir>: nothing of
// the user's is opened or written. Debug builds only.
#if DEBUG
if args.count > 2, args[1] == "--panel-snapshot" {
    exit(MainActor.assumeIsolated { PanelSnapshot.run(args[2], only: args.count > 3 ? args[3] : nil) })
}
if args.count > 1, args[1] == "--panel-snapshot" {
    FileHandle.standardError.write(Data("usage: Moe --panel-snapshot <dir>\n".utf8))
    exit(2)
}
// `Moe --learn-step <ticked,...|-> yes|no`: what the first-run learn step
// writes when its button is pressed, with no screen in the way — the rows
// come from the home's own `consent.sh list --quick`, the answers are worked
// out by BackgroundLearning.stepWrites and recorded through the same
// consent.sh verbs Settings › Background uses. Prints each write as
// `name=yes|no`, or `nothing` when the step would leave the file alone.
// scripts/test-onboarding-learn.sh holds the file this leaves against the
// one Settings leaves for the same switches, and proves Skip writes nothing.
if args.count > 3, args[1] == "--learn-step" {
    let ticked = Set(args[2] == "-" ? [] : args[2].split(separator: ",").map(String.init))
    let pass = args[3] == "yes"
    let rows = BackgroundLearning.rows(BackgroundLearning.sources(quick: true))
    let unknown = ticked.subtracting(rows.map(\.id))
    if !unknown.isEmpty {
        FileHandle.standardError.write(Data("not on the list: \(unknown.sorted().joined(separator: ", ")) (have: \(rows.map(\.id).joined(separator: ", ")))\n".utf8))
        exit(2)
    }
    let writes = BackgroundLearning.stepWrites(rows: rows, ticked: ticked, pass: pass,
                                               passState: BackgroundLearning.state())
    if writes.isEmpty { print("nothing"); exit(0) }
    for w in writes { print("\(w.name)=\(w.on ? "yes" : "no")") }
    exit(BackgroundLearning.record(writes) ? 0 : 1)
}
if args.count > 1, args[1] == "--learn-step" {
    FileHandle.standardError.write(Data("usage: Moe --learn-step <ticked,...|-> yes|no\n".utf8))
    exit(2)
}
// `Moe --onboarding-snapshot <dir>`: every first-launch screen, posed in every
// state, as PNGs — light and dark. Sources/Moe/Onboarding/OnboardingSnapshot.swift.
if args.count > 2, args[1] == "--onboarding-snapshot" {
    exit(MainActor.assumeIsolated { OnboardingSnapshot.run(args[2]) })
}
if args.count > 1, args[1] == "--onboarding-snapshot" {
    FileHandle.standardError.write(Data("usage: Moe --onboarding-snapshot <dir>\n".utf8))
    exit(2)
}
// `Moe --settings-snapshot <dir> [name]`: every Settings pane, plus Memory and
// Connections, as PNGs — light and dark. `name` renders only the panes whose
// file name contains it ("connections"), which matters when
// MOE_SNAPSHOT_SETTLE is turned up for a pane that loads slowly.
// Sources/Moe/Settings/SettingsSnapshot.swift.
if args.count > 2, args[1] == "--settings-snapshot" {
    let only = args.count > 3 ? args[3] : ""
    exit(MainActor.assumeIsolated { SettingsSnapshot.run(args[2], only: only) })
}
if args.count > 1, args[1] == "--settings-snapshot" {
    FileHandle.standardError.write(Data("usage: Moe --settings-snapshot <dir> [name]\n".utf8))
    exit(2)
}
// `Moe --migrate-home <old> <new>`: the first-launch home migration on two
// paths of the caller's choosing, for scripts/test-moe-home.sh — the real one
// reads FileManager.homeDirectoryForCurrentUser, which ignores $HOME, so the
// shell could not drive it. Prints what the launch would log.
if args.count > 3, args[1] == "--migrate-home" {
    print(Paths.migrateLegacyHome(old: URL(fileURLWithPath: args[2], isDirectory: true),
                                  new: URL(fileURLWithPath: args[3], isDirectory: true),
                                  honourMoeHome: false))
    exit(0)
}

// `Moe --onboarding-rehearsal`: walk the real onboarding window, posed as a
// fresh Mac, with every side effect faked. scripts/rehearse-onboarding.sh.
if args.count > 1, args[1] == "--onboarding-rehearsal" {
    exit(MainActor.assumeIsolated { OnboardingSnapshot.rehearse() })
}
#endif

// `Moe --dmg-background <png>`: the picture behind the disk image's Finder
// window — the arrow and the three Gatekeeper steps. scripts/release.sh runs
// it on the BUILT app, so this lives outside the DEBUG block above: the
// first 0.3.13 build had it inside, the release binary had no such flag,
// started as the app, and RunningFromHere refused it from dist/.
if args.count > 2, args[1] == "--dmg-background" {
    exit(MainActor.assumeIsolated { DmgBackground.write(to: args[2]) } ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
