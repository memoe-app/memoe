import EventKit
import Foundation

/// The follow-up ledger, as the inbox's buttons reach it: moe-screen's
/// `deliver.py loop …` (stdlib Python, under the ledger lock). Done is
/// `loop done`, which closes the loops *and* holds the subject quiet until
/// the thing it came from changes — a plain close does not stop a nag the
/// next pass re-derives from an overdue Reminder (the Miriam case,
/// 2026-09-30: seven raises in two days, four of them with no loop at all).
struct LoopLedger {
    struct Reply: Equatable {
        var exit: Int32
        /// It printed its JSON line. A deliver.py from before the `loop`
        /// command imports, does nothing and exits 0 silently — measured on
        /// this Mac 2026-09-30 — so exit 0 alone proves nothing.
        var answered = false
        var ok = false
        /// The loops that were open and are now closed.
        var closed: [String] = []
        /// A hold on the subject was written.
        var held = false
        var reminder = ""
        var next = ""
    }

    /// Runs `deliver.py` with these arguments; nil when it could not start.
    var run: ([String]) async -> Reply?

    /// Nothing that understood the call answered: ask the brain instead.
    static func unheard(_ r: Reply?) -> Bool { r == nil || r?.exit == 2 || r?.answered == false }

    func done(loops: [String], text: String) async -> Reply? {
        await run(["loop", "done"] + loops.filter(Self.isSlug) + ["--text", text])
    }

    /// deliver.py refuses the whole call (exit 2) over one bad follow-up
    /// name, so a bad one is left out rather than losing the hold.
    static func isSlug(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40
            && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    func snooze(_ slug: String, until: Date) async -> Reply? {
        await run(["loop", "snooze", slug, ISO8601DateFormatter().string(from: until)])
    }

    static var script: URL {
        HermesUpgrade.hermesHome.appendingPathComponent("plugins/moe-screen/deliver.py")
    }

    /// Unit tests never reach this Mac's real ledger: a test that wants one
    /// hands the conductor its own.
    static var underTest: Bool {
        let name = ProcessInfo.processInfo.processName
        return name.contains("xctest") || name.contains("swiftpm-testing-helper")
            || NSClassFromString("XCTestCase") != nil
    }

    static let live = LoopLedger { args in
        let script = LoopLedger.script
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return await Task.detached { () -> Reply? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: BrainSetup.python())
            p.arguments = [script.path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return LoopLedger.parse(data, exit: p.terminationStatus)
        }.value
    }

    /// One JSON line on stdout, every time; exit 0 did it, 1 nothing to do
    /// (still with its line, and not a failure), 2 a bad call.
    static func parse(_ data: Data, exit: Int32) -> Reply {
        var r = Reply(exit: exit)
        let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return r }
        r.answered = true
        r.ok = obj["ok"] as? Bool ?? false
        r.closed = obj["closed"] as? [String] ?? []
        r.held = obj["held"] as? Bool ?? false
        r.reminder = obj["reminder"] as? String ?? ""
        r.next = obj["next"] as? String ?? ""
        return r
    }
}

/// "Also mark it done in Reminders?" — offered after Done on a notice that
/// came from an Apple Reminder. Nothing is written to Reminders unless the
/// person taps (owner decision 2026-09-30).
struct ReminderTick: Equatable {
    let noticeID: String
    /// The reminder's exact name, as the ledger found it in the brief.
    let title: String
}

enum RemindersTick {
    enum Outcome: Equatable { case done, notFound, noAccess }

    /// Marks the first open reminder with exactly this name complete. Never
    /// prompts: access was granted during setup or it was not.
    static func complete(_ title: String) async -> Outcome {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return .noAccess }
        let store = EKEventStore()
        let open = await EventKitBridge.fetch(
            store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil),
            store: store)
        guard let r = open.first(where: { ($0.title ?? "") == title })
                ?? open.first(where: { ($0.title ?? "").caseInsensitiveCompare(title) == .orderedSame })
        else { return .notFound }
        r.isCompleted = true
        do { try store.save(r, commit: true) } catch { return .notFound }
        return .done
    }
}
