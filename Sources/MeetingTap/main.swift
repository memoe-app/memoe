import AVFoundation
import FluidAudio
import Foundation
import MoeComponents
import MoeMeeting

// Meeting-mode spike for Moe (PRODUCT.md §4.2).
//
//   MeetingTap list                                   audio-producing processes
//   MeetingTap record <bundle-id|all> <seconds> <dir> system.wav + mic.wav, 16 kHz mono
//   MeetingTap transcribe <dir>                       ASR on both, diarize system, timeline
//
// Mic = you. System (process tap) = them. Diarization splits "them".

func line() { print(String(repeating: "─", count: 62)) }

func usage() -> Never {
    print("""
    usage:
      MeetingTap list
      MeetingTap record <bundle-id|all> <seconds> <out-dir>
      MeetingTap transcribe <out-dir>
    """)
    exit(64)
}

func mmss(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - list

func list() throws {
    let processes = try ProcessList.all()
    print("\n\(processes.count) processes known to Core Audio")
    line()
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    print("\(pad("objID", 6)) \(pad("pid", 7)) \(pad("out", 4)) \(pad("in", 3)) bundle id / name")
    for p in processes.sorted(by: { ($0.isRunningOutput ? 0 : 1, $0.pid) < ($1.isRunningOutput ? 0 : 1, $1.pid) }) {
        let label = p.bundleID.isEmpty ? "(\(ProcessList.name(forPID: p.pid)))" : p.bundleID
        print("\(pad(String(p.objectID), 6)) \(pad(String(p.pid), 7)) \(pad(p.isRunningOutput ? "yes" : "-", 4)) \(pad(p.isRunningInput ? "yes" : "-", 3)) \(label)")
    }
    print("\n'out' = currently producing output audio. Tap one with `record <bundle-id> …`, or `record all …`.")
}

// MARK: - record

func record(target: String, seconds: Double, outDir: String) async throws {
    let dir = URL(fileURLWithPath: outDir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    print("\nMoe — meeting tap spike")
    line()
    print("Machine: \(ProcessInfo.processInfo.operatingSystemVersionString)")

    // Mic permission first, the way AudioGate does it.
    guard await MicCapture.requestPermission() else {
        print("✗ microphone access denied — grant it to your terminal in Privacy & Security › Microphone")
        exit(2)
    }
    print("✓ microphone permission granted")

    let tapTarget: TapTarget
    if target == "all" {
        tapTarget = .allExceptSelf
        print("  tapping: all processes (excluding this one)")
    } else {
        let matches = try ProcessList.find(bundleID: target)
        guard !matches.isEmpty else {
            print("✗ no audio process with bundle id \(target) — run `MeetingTap list`")
            exit(3)
        }
        tapTarget = .processes(matches.map(\.objectID))
        print("  tapping: \(target) (pids \(matches.map { String($0.pid) }.joined(separator: ", ")))")
    }

    // One epoch for both streams: each file is padded with silence up to
    // its first buffer, so [mm:ss] in the timeline means the same instant on
    // both. Set before anything starts.
    let epoch = Date()
    let systemSink = try SampleSink(url: dir.appendingPathComponent("system.wav"), epoch: epoch)
    let micSink = try SampleSink(url: dir.appendingPathComponent("mic.wav"), epoch: epoch)
    let tap = ProcessTap(target: tapTarget, sink: systemSink)
    // `MEETINGTAP_AEC=0` turns echo cancellation off for A/B runs.
    let mic = MicCapture(sink: micSink, echoCancel: ProcessInfo.processInfo.environment["MEETINGTAP_AEC"] != "0")

    // Start order matters: enabling voice processing on the mic engine
    // reconfigures the hardware device, which kills a tap aggregate that is
    // already running on it. So mic first, then tap.
    let micFirst = ProcessInfo.processInfo.environment["MEETINGTAP_TAP_FIRST"] != "1"
    if micFirst {
        try mic.start()
        if let f = mic.inputFormat {
            print("✓ mic engine started — input \(Int(f.sampleRate)) Hz, \(f.channelCount) ch, AEC \(mic.echoCancel ? "on" : "off")")
        }
    }
    let t0 = Date()
    do {
        try tap.start()
    } catch {
        print("""

        ✗ system tap failed: \(error)

          If this is a permission failure, the grant lives under
          System Settings › Privacy & Security › Screen & System Audio Recording
          › "System Audio Recording Only" for whatever app launched this
          (your terminal). See MEETING-MODE.md.
        """)
        exit(1)
    }
    let tapReady = Date().timeIntervalSince(t0)
    if let f = tap.tapFormat {
        print("✓ system tap up in \(Int(tapReady * 1000)) ms — tap format \(Int(f.sampleRate)) Hz, \(f.channelCount) ch, \(f.isInterleaved ? "interleaved" : "non-interleaved") Float32")
    }
    if !micFirst {
        try mic.start()
        if let f = mic.inputFormat {
            print("✓ mic engine started — input \(Int(f.sampleRate)) Hz, \(f.channelCount) ch, AEC \(mic.echoCancel ? "on" : "off")")
        }
    }
    let startedAt = epoch

    line()
    print("Recording \(Int(seconds)) s. Levels per second (dBFS):\n")
    print("  sec   system (them)              mic (you)")
    let cpuStart = cpuSeconds()
    var firstSystemLatency: Double?
    for sec in 1...Int(seconds) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let s = systemSink.meter.drain()
        let m = micSink.meter.drain()
        if firstSystemLatency == nil, let t = systemSink.firstBufferAt {
            firstSystemLatency = t.timeIntervalSince(startedAt)
        }
        print(String(format: "  %-4d  rms %6.1f  peak %6.1f  rms %6.1f  peak %6.1f   (%d / %d frames)",
                     sec, s.rms, s.peak, m.rms, m.peak, s.frames, m.frames))
    }
    let cpuUsed = cpuSeconds() - cpuStart
    tap.stop()
    mic.stop()
    systemSink.close()
    micSink.close()

    line()
    print(String(format: "system.wav  %6.2f s  (%d samples, %d buffers, %d IO callbacks)", Double(systemSink.count) / 16_000, systemSink.count, systemSink.buffers, tap.ioCallbacks))
    print(String(format: "mic.wav     %6.2f s  (%d samples, %d buffers)", Double(micSink.count) / 16_000, micSink.count, micSink.buffers))
    if let l = firstSystemLatency {
        print(String(format: "first system buffer %.0f ms after start (both files padded to the same epoch)", l * 1000))
    } else {
        print("first system buffer: never — the tap delivered nothing (silence in, or permission denied without error)")
    }
    print(String(format: "CPU during capture: %.2f s over %.0f s wall = %.1f%% of one core", cpuUsed, seconds, cpuUsed / seconds * 100))
    print("wrote \(dir.path)/system.wav and mic.wav")
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + sys
}

// MARK: - transcribe

struct Utterance {
    let start: Double
    let end: Double
    let who: String   // "you" or "them (speaker N)"
    let text: String
}

/// Joins SentencePiece tokens into words, splitting into utterances on
/// pauses (`gap`) or when the speaker attribution changes.
func utterances(from timings: [TokenTiming], who: (Double) -> String, gap: Double = 0.8) -> [Utterance] {
    var out: [Utterance] = []
    var text = ""
    var start = 0.0, end = 0.0
    var speaker = ""
    func flush() {
        // A sentence-final "." token lands at the start of the next
        // utterance when the split falls on a pause; drop it.
        let t = text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        if !t.isEmpty { out.append(Utterance(start: start, end: end, who: speaker, text: t)) }
        text = ""
    }
    for tok in timings {
        let mid = (tok.startTime + tok.endTime) / 2
        let s = who(mid)
        if text.isEmpty {
            start = tok.startTime; speaker = s
        } else if s != speaker || tok.startTime - end > gap {
            flush()
            start = tok.startTime; speaker = s
        }
        var piece = tok.token
        if piece.hasPrefix("▁") { piece = " " + piece.dropFirst() }
        text += piece
        end = tok.endTime
    }
    flush()
    return out
}

func transcribe(outDir: String) async throws {
    let dir = URL(fileURLWithPath: outDir)
    let system = try Wav.read(dir.appendingPathComponent("system.wav"))
    let mic = try Wav.read(dir.appendingPathComponent("mic.wav"))
    print("\nsystem.wav \(String(format: "%.1f", Double(system.count) / 16_000)) s, mic.wav \(String(format: "%.1f", Double(mic.count) / 16_000)) s")

    // ASR, exactly as the Moe target uses it (UnifiedAsrManager = Parakeet).
    var t = Date()
    let asr = UnifiedAsrManager()
    try await asr.loadModels()
    print(String(format: "ASR models loaded in %.1f s", Date().timeIntervalSince(t)))

    t = Date()
    let you = try await asr.transcribeWithTimings(mic)
    let them = try await asr.transcribeWithTimings(system)
    print(String(format: "ASR on both streams: %.2f s", Date().timeIntervalSince(t)))

    // Diarization on the system stream only — "them" may be several people.
    t = Date()
    let diarizer = DiarizerManager(config: DiarizerConfig(minSpeechDuration: 0.5))
    try await ComponentFetcher.shared.ensure(ComponentCatalog.speakerDiarization,
                                             in: ComponentCatalog.modelsRoot)
    diarizer.initialize(models: try await DiarizerModels.downloadIfNeeded())
    print(String(format: "Diarizer models loaded in %.1f s", Date().timeIntervalSince(t)))
    t = Date()
    let diarization = try diarizer.performCompleteDiarization(system, sampleRate: 16_000)
    print(String(format: "Diarization: %.2f s, %d segments, speakers %@",
                 Date().timeIntervalSince(t), diarization.segments.count,
                 Set(diarization.segments.map(\.speakerId)).sorted().joined(separator: ", ")))

    // Map speaker ids to "speaker 1, 2, …" in order of first appearance.
    var order: [String: Int] = [:]
    for seg in diarization.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
        if order[seg.speakerId] == nil { order[seg.speakerId] = order.count + 1 }
    }
    func speaker(at time: Double) -> String {
        let hit = diarization.segments.first {
            Double($0.startTimeSeconds) <= time && time <= Double($0.endTimeSeconds)
        } ?? diarization.segments.min {
            abs(Double($0.startTimeSeconds + $0.endTimeSeconds) / 2 - time)
                < abs(Double($1.startTimeSeconds + $1.endTimeSeconds) / 2 - time)
        }
        guard let hit, let n = order[hit.speakerId] else { return "them" }
        return "them (speaker \(n))"
    }

    let timeline = (utterances(from: you.tokenTimings, who: { _ in "you" })
                    + utterances(from: them.tokenTimings, who: speaker))
        .sorted { $0.start < $1.start }

    line()
    print("Timeline")
    line()
    if timeline.isEmpty { print("(nothing recognised on either stream)") }
    for u in timeline {
        print("[\(mmss(u.start))] \(u.who): \(u.text)")
    }
    line()
    print("raw — you:  \(you.text)")
    print("raw — them: \(them.text)")

    // Persist alongside the audio so the app-side integration has a fixture.
    let transcript = timeline.map { "[\(mmss($0.start))] \($0.who): \($0.text)" }.joined(separator: "\n")
    try transcript.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
}

// MARK: - main

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else { usage() }
do {
    switch command {
    case "list":
        try list()
    case "record":
        guard args.count == 4, let seconds = Double(args.dropFirst(2).first!), seconds >= 1 else { usage() }
        try await record(target: args.dropFirst().first!, seconds: seconds, outDir: args.last!)
    case "transcribe":
        guard args.count == 2 else { usage() }
        try await transcribe(outDir: args.last!)
    default:
        usage()
    }
} catch {
    print("✗ \(error)")
    exit(1)
}
exit(0)
