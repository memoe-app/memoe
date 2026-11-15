import AppKit
import Foundation
import MachO

/// A Memoe opened from its disk image, or from the temporary copy macOS runs
/// a downloaded app out of until it is moved, offers to move itself into
/// Applications — and does it only on the person's click.
///
/// Until 2026-11-12 that launch was unhandled, and worse than unhandled:
/// `RunningFromHere.enforce` — written to stop a developer's `dist/` build
/// passing for the installed app — met it first and showed a stranger "This
/// is not the installed Moe … To test a change, install Moe Dev:
/// ./scripts/install.sh", then quit. `Payload.startBackgroundJobsOnce` was
/// the only code that knew the two paths at all.
///
/// **Where this can act.** Only a release-identifier bundle, in a release
/// build, running from `/Volumes/…` or `…/AppTranslocation/…`. That leaves
/// alone, by construction:
///
///   * Memoe Dev and every debug build — the first two things `decide`
///     checks, before any path is looked at;
///   * a test process (`underTest`), and the tests themselves, which hand in
///     their own destination and file operations and never the real ones;
///   * the installed app. Sparkle replaces `/Applications/Memoe.app` in
///     place and relaunches it from there; `scripts/install.sh` and
///     `scripts/catch-up.sh` copy beside it and swap by rename. All three
///     end with Memoe running from Applications, which is `.elsewhere` here
///     and decides `.nothing`.
///
/// **Why "Quit" and not "Not now".** `RunningFromHere` refuses any release
/// bundle that is not at the installed path, for the reason at the top of
/// that file. A Memoe that stays on the disk image cannot run, so the offer
/// does not pretend it can.
enum MoveToApplications {

    // MARK: - Where this copy is running from

    enum Origin: Equatable {
        /// `/Volumes/…`: double-clicked inside the mounted disk image.
        case diskImage
        /// `…/AppTranslocation/…`: Gatekeeper's randomised read-only copy of
        /// a downloaded app that was never moved by hand.
        case translocated
        /// Anywhere else — Applications included.
        case elsewhere
    }

    static func origin(ofPath path: String) -> Origin {
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        return .elsewhere
    }

    // MARK: - The decision

    /// Everything the decision reads, handed in — so a test poses a disk
    /// image without one, and nothing here looks at the real Mac by itself.
    struct Situation {
        var bundlePath: String
        var bundleIdentifier: String?
        var releaseIdentifier: String
        var debugBuild: Bool
        var underTest: Bool
        /// No one to click: `MOE_HEADLESS`, or a deliberate
        /// `MOE_ALLOW_UNINSTALLED` run. `RunningFromHere` has those.
        var unattended: Bool
        /// Asked only once everything above says this is a real person's
        /// downloaded copy — never for a dev build, a test or the installed app.
        var destinationExists: () -> Bool
        var destinationRunning: () -> Bool
    }

    enum Decision: Equatable {
        /// Not this code's business. The reason goes to the log.
        case nothing(String)
        case offerMove(Origin)
        /// There is already a Memoe in Applications: ask before replacing.
        case askReplace(Origin)
        /// …and it is open right now: switch to it, replace nothing.
        case alreadyOpen
    }

    static func decide(_ s: Situation) -> Decision {
        if s.debugBuild { return .nothing("a debug build") }
        if s.underTest { return .nothing("a test process") }
        guard s.bundleIdentifier == s.releaseIdentifier else { return .nothing("not the release app") }
        if s.unattended { return .nothing("nobody to ask") }
        guard s.bundlePath.hasSuffix(".app") else { return .nothing("not an app bundle") }
        let from = origin(ofPath: s.bundlePath)
        guard from != .elsewhere else { return .nothing("not on a disk image or a temporary copy") }
        if s.destinationRunning() { return .alreadyOpen }
        return s.destinationExists() ? .askReplace(from) : .offerMove(from)
    }

    // MARK: - The move

    /// The file operations, injectable: the tests run the whole move against
    /// a temporary folder, and the real `/Applications` is only ever reached
    /// through `Files.real`, from `atLaunch`, after a click.
    struct Files {
        var exists: (String) -> Bool
        var copy: (_ from: String, _ to: String) throws -> Void
        var rename: (_ from: String, _ to: String) throws -> Void
        /// The copy being replaced goes to the Trash, not to nothing.
        var trash: (String) throws -> Void
        var remove: (String) -> Void
        /// Take the downloaded-from-the-Internet mark off the new copy:
        /// with it, macOS would run that copy from a temporary one too. The
        /// person already answered Gatekeeper for this app to get here.
        var clearQuarantine: (String) -> Void

        static let real = Files(
            exists: { FileManager.default.fileExists(atPath: $0) },
            copy: { try FileManager.default.copyItem(atPath: $0, toPath: $1) },
            rename: { try FileManager.default.moveItem(atPath: $0, toPath: $1) },
            trash: { try FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) },
            remove: { try? FileManager.default.removeItem(atPath: $0) },
            clearQuarantine: { path in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                p.arguments = ["-dr", "com.apple.quarantine", path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            })
    }

    enum Failure: Error, Equatable {
        /// Could not copy into the folder (a standard account, a full disk).
        case couldNotCopy(String)
        /// The copy is missing its insides; nothing was replaced.
        case incomplete
        /// Something is at the destination and replacing it was not agreed.
        case occupied
        /// The copy already there could not be moved to the Trash.
        case couldNotReplace(String)
        /// The new copy could not be put in place.
        case couldNotPlace(String)

        /// For the log. The person gets `Words.failed`.
        var detail: String {
            switch self {
            case .couldNotCopy(let why): return "copy failed: \(why)"
            case .incomplete: return "the copy has no Info.plist or no executable folder"
            case .occupied: return "the destination exists and replacing it was not agreed"
            case .couldNotReplace(let why): return "could not move the existing copy to the Trash: \(why)"
            case .couldNotPlace(let why): return "could not rename the new copy into place: \(why)"
            }
        }
    }

    /// Where the copy is built before it takes the name: beside the
    /// destination, so the last step is a rename and an interrupted move
    /// leaves whatever was there untouched (the shape `scripts/install.sh`
    /// uses, for the reason CLAUDE.md gives: a half-copied bundle with no
    /// Info.plist once stood in for the app).
    static func stagingPath(for destination: String, tag: String) -> String {
        let url = URL(fileURLWithPath: destination)
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).moving-\(tag)").path
    }

    /// Copy `bundle` to `destination`. Nothing at `destination` is touched
    /// until a complete copy is sitting beside it, and never without
    /// `replacing`. Nil when it is in place; otherwise what stopped it.
    static func move(bundle: String, to destination: String, replacing: Bool,
                     files: Files, tag: String = "\(ProcessInfo.processInfo.processIdentifier)") -> Failure? {
        let staging = stagingPath(for: destination, tag: tag)
        files.remove(staging)   // a leftover from a move that was interrupted
        do {
            try files.copy(bundle, staging)
        } catch {
            files.remove(staging)
            return .couldNotCopy("\(error)")
        }
        guard files.exists(staging + "/Contents/Info.plist"), files.exists(staging + "/Contents/MacOS") else {
            files.remove(staging)
            return .incomplete
        }
        if files.exists(destination) {
            guard replacing else {
                files.remove(staging)
                return .occupied
            }
            do {
                try files.trash(destination)
            } catch {
                files.remove(staging)
                return .couldNotReplace("\(error)")
            }
        }
        do {
            try files.rename(staging, destination)
        } catch {
            files.remove(staging)
            return .couldNotPlace("\(error)")
        }
        files.clearQuarantine(destination)
        return nil
    }

    /// Opens the moved copy once this process has gone — the same wait
    /// `Relaunch.script` does, by path rather than by identifier, because
    /// two copies share the identifier at this moment and `open -b` may pick
    /// the one being left. `MOE_OPEN` stands in for `open` under test.
    static func relaunchScript(pid: Int32, destination: String) -> String {
        let quoted = "'" + destination.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "i=0; while kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt 300 ]; do sleep 0.2; i=$((i+1)); done; "
            + "\"${MOE_OPEN:-/usr/bin/open}\" \(quoted)"
    }

    // MARK: - Words

    enum Words {
        static let title = "Move Memoe to your Applications folder?"
        static func why(_ origin: Origin) -> String {
            let whereItIs = origin == .translocated
                ? "macOS is running Memoe from a temporary copy — it does that with a downloaded app that hasn't been put in Applications yet."
                : "Memoe is running from the disk image it came in."
            return whereItIs + " It needs to live in Applications: that is where it keeps itself up to date, and where the things it does in the background can find it.\n\nI'll copy it there and open it from there. Nothing else on your Mac changes."
        }
        static let move = "Move to Applications"
        static let quit = "Quit"

        static let replaceTitle = "There is already a Memoe in Applications"
        static func replaceWhy(existing: String?, this: String?) -> String {
            let versions: String
            switch (existing, this) {
            case let (old?, new?) where old == new: versions = "It is the same version as this one (\(new))."
            case let (old?, new?): versions = "That one is version \(old); this one is \(new)."
            default: versions = ""
            }
            return ["Replacing it moves the one in Applications to the Trash and puts this one in its place. Your notes, memory and settings are kept somewhere else and are not touched.", versions]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        static let replace = "Replace it"
        static let openExisting = "Open the one in Applications"

        static let alreadyOpenTitle = "Memoe is already open"
        static let alreadyOpenWhy = "It is running from your Applications folder. This copy isn't needed — you can eject the disk image."
        static let switchToIt = "Switch to it"

        static let failedTitle = "I couldn't put Memoe in Applications"
        static let failed = "Nothing was changed. Drag Memoe into the Applications folder yourself — the disk image's window shows both — then open it from there."
    }

    // MARK: - At launch

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// True inside a test runner, whatever built it. The environment and
    /// the bundle name cover Xcode's runner; under the Command Line Tools,
    /// which is how this project is tested, neither is set — measured, the
    /// first version of this returned false inside its own test — so the
    /// loaded images are what is asked: a process with a testing framework
    /// in it is a test.
    static func underTest(environment: [String: String] = ProcessInfo.processInfo.environment,
                          bundlePath: String = Bundle.main.bundlePath) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return true }
        if bundlePath.hasSuffix(".xctest") { return true }
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let image = String(cString: name)
            if image.contains("/Testing.framework/") || image.contains("/XCTest.framework/") { return true }
        }
        return false
    }

    /// Called first thing in `applicationDidFinishLaunching`, before
    /// `RunningFromHere.enforce` and before the instance lock. Returns in
    /// every case that is not a downloaded copy outside Applications; in
    /// that one case it asks, and the process ends here whatever is chosen
    /// — moved and reopened from Applications, or quit.
    @MainActor
    static func atLaunch(destination: String = RunningFromHere.installedPath) {
        let env = ProcessInfo.processInfo.environment
        let bundle = Bundle.main.bundleURL.path
        let identifier = Bundle.main.bundleIdentifier
        let situation = Situation(
            bundlePath: bundle,
            bundleIdentifier: identifier,
            releaseIdentifier: RunningFromHere.releaseIdentifier,
            debugBuild: isDebugBuild,
            underTest: underTest(environment: env, bundlePath: bundle),
            unattended: env["MOE_HEADLESS"] == "1" || !(env["MOE_ALLOW_UNINSTALLED"] ?? "").isEmpty,
            destinationExists: { FileManager.default.fileExists(atPath: destination) },
            destinationRunning: {
                let there = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
                return NSRunningApplication.runningApplications(withBundleIdentifier: identifier ?? "")
                    .contains { $0.bundleURL?.resolvingSymlinksInPath().path == there }
            })

        switch decide(situation) {
        case .nothing:
            return
        case .alreadyOpen:
            Log.write("move to Applications: the installed Memoe is already open; switching to it")
            _ = ask(Words.alreadyOpenTitle, Words.alreadyOpenWhy, [Words.switchToIt])
            let there = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier ?? "")
                .first { $0.bundleURL?.resolvingSymlinksInPath().path == there }?.activate()
            leave()
        case .offerMove(let from):
            Log.write("move to Applications: running from \(bundle); asking")
            guard ask(Words.title, Words.why(from), [Words.move, Words.quit]) == 0 else { leave() }
            finish(move(bundle: bundle, to: destination, replacing: false, files: .real), destination: destination)
        case .askReplace(let from):
            Log.write("move to Applications: running from \(bundle), and \(destination) exists; asking")
            let text = Words.why(from).components(separatedBy: "\n\n")[0] + "\n\n"
                + Words.replaceWhy(existing: version(ofBundleAt: destination), this: version(ofBundleAt: bundle))
            switch ask(Words.replaceTitle, text, [Words.replace, Words.openExisting, Words.quit]) {
            case 0:
                finish(move(bundle: bundle, to: destination, replacing: true, files: .real), destination: destination)
            case 1:
                Log.write("move to Applications: opening the copy already there instead")
                reopen(destination)
            default:
                leave()
            }
        }
    }

    @MainActor
    private static func finish(_ failure: Failure?, destination: String) -> Never {
        guard let failure else {
            Log.write("move to Applications: moved to \(destination); reopening from there")
            reopen(destination)
        }
        Log.write("move to Applications: \(failure.detail)")
        _ = ask(Words.failedTitle, Words.failed, [Words.quit])
        leave()
    }

    private static func reopen(_ destination: String) -> Never {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", relaunchScript(pid: ProcessInfo.processInfo.processIdentifier, destination: destination)]
        try? p.run()
        leave()
    }

    private static func leave() -> Never {
        Log.flush()
        exit(0)
    }

    /// The index of the button pressed, in the order given.
    @MainActor
    private static func ask(_ title: String, _ text: String, _ buttons: [String]) -> Int {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    private static func version(ofBundleAt path: String) -> String? {
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        return plist?["CFBundleShortVersionString"] as? String
    }
}
