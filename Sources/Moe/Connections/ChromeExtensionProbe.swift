import AppKit
import Foundation

/// What the app can see for itself about Moe in your Chrome, beside what
/// `configure-hermes.py --chrome-extension-status` reports: the host manifest
/// Chrome reads, the host's own note that the extension reached it, and which
/// Chrome profiles have the extension. Everything here reads, except
/// `ChromeHostManifest.heal`, which only ever adds the missing origins to a
/// manifest that already exists.

/// `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/app.memoe.chrome_bridge.json`.
///
/// Every install before the store id was known wrote it with the dev id
/// alone, and Chrome refuses `connectNative` from an extension not in
/// `allowed_origins` — silently, on both ends. So the app rewrites it with
/// both origins at launch and whenever the Chrome row is looked at: an
/// existing install heals on its next launch, whatever Hermes it runs.
enum ChromeHostManifest {
    static let name = "app.memoe.chrome_bridge"

    static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(name).json")
    }

    struct Status: Equatable, Sendable {
        var present: Bool
        /// Of `ChromeExtension.ids`, the ones `allowed_origins` does not list.
        var missingIDs: [String]
        /// Its `path` exists and can be run.
        var launcherOK: Bool

        static let absent = Status(present: false, missingIDs: ChromeExtension.ids, launcherOK: false)
    }

    enum Heal: Equatable, Sendable {
        /// No manifest: nothing to heal (Set up writes one).
        case absent
        /// Already lists every id.
        case ok
        /// Rewritten with the missing origins added.
        case healed(added: [String])
        /// Not ours, not JSON, or could not be written.
        case untouched(String)
    }

    static func read(_ url: URL = defaultURL()) -> Status {
        guard let data = FileManager.default.contents(atPath: url.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .absent }
        let origins = obj["allowed_origins"] as? [String] ?? []
        let missing = ChromeExtension.ids.filter { !origins.contains(ChromeExtension.origin($0)) }
        let launcher = obj["path"] as? String
        let runnable = launcher.map { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) } ?? false
        return Status(present: true, missingIDs: missing, launcherOK: runnable)
    }

    /// Add whichever of the store and dev origins `allowed_origins` lacks,
    /// keeping every other key and origin as it was. Never creates the file
    /// or its folder (no Chrome, or never set up: nothing to heal), never
    /// touches a manifest whose `name` is not ours, and swaps by rename.
    @discardableResult
    static func heal(_ url: URL = defaultURL()) -> Heal {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .absent }
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { return .untouched("a symlink") }
        guard let data = fm.contents(atPath: url.path),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .untouched("not JSON") }
        guard obj["name"] as? String == name else { return .untouched("not Memoe's host") }
        var origins = obj["allowed_origins"] as? [String] ?? []
        let added = ChromeExtension.ids.filter { !origins.contains(ChromeExtension.origin($0)) }
        guard !added.isEmpty else { return .ok }
        // Ours first, in order (store, dev), then anything else it listed.
        let ours = ChromeExtension.ids.map(ChromeExtension.origin)
        origins = ours + origins.filter { !ours.contains($0) }
        obj["allowed_origins"] = origins
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return .untouched("could not encode") }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(name).\(getpid()).tmp")
        do {
            try (out + Data("\n".utf8)).write(to: tmp)
            // Chrome reads it as the person; keep it readable the way the fork writes it.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
            if rename(tmp.path, url.path) != 0 {
                try? fm.removeItem(at: tmp)
                return .untouched("rename failed (errno \(errno))")
            }
        } catch {
            try? fm.removeItem(at: tmp)
            return .untouched(error.localizedDescription)
        }
        return .healed(added: added)
    }
}

/// The native host's own note, `<hermes home>/chrome-bridge/seen.json`,
/// written on every hello (fork, `browser_chrome_bridge.write_seen`): the
/// extension is installed and reached the host at `at`, even if it is not
/// connected now.
struct ChromeSeen: Equatable, Sendable {
    let extensionID: String
    let at: Date

    static func dir(hermesHome: URL = HermesUpgrade.hermesHome) -> URL {
        hermesHome.appendingPathComponent("chrome-bridge", isDirectory: true)
    }

    /// `seen.json`; failing that, a live host's `bridge.json` (a Hermes from
    /// before seen.json, whose relay may still refuse the store build's
    /// origin — the host it started is proof enough that it is installed).
    static func read(_ dir: URL = dir()) -> ChromeSeen? {
        func obj(_ name: String) -> [String: Any]? {
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if let o = obj("seen.json"), let origin = o["extension_origin"] as? String,
           let id = ChromeExtension.id(fromOrigin: origin) {
            return ChromeSeen(extensionID: id, at: Date(timeIntervalSince1970: o["at"] as? Double ?? 0))
        }
        if let o = obj("bridge.json"), let origin = o["extension_origin"] as? String,
           let id = ChromeExtension.id(fromOrigin: origin),
           let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0 || errno == EPERM {
            return ChromeSeen(extensionID: id, at: Date(timeIntervalSince1970: o["started_at"] as? Double ?? 0))
        }
        return nil
    }
}

/// Which Chrome profiles hold the extension, from Chrome's own files.
///
/// Best effort, and honest about it: on macOS 26 Chrome's data folder can be
/// closed to other apps (measured 2026-11-12 on the owner's Mac: `Local
/// State` is "Operation not permitted" even outside the sandbox, while
/// `NativeMessagingHosts` beside it reads fine). A scan that cannot read
/// says `unknown`, never "not installed".
enum ChromeProfiles {
    struct Profile: Equatable, Sendable {
        let dir: String
        let name: String
        /// Chrome lists it as open (`profile.last_active_profiles`).
        let open: Bool
        let ids: [String]
    }

    enum Scan: Equatable, Sendable {
        case unknown
        case read([Profile])

        /// Profiles that have either id.
        var withExtension: [Profile]? {
            guard case .read(let all) = self else { return nil }
            return all.filter { !$0.ids.isEmpty }
        }
    }

    static func defaultRoot(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    static func scan(_ root: URL = defaultRoot()) -> Scan {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: root.appendingPathComponent("Local State").path),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = state["profile"] as? [String: Any] else { return .unknown }
        let cache = profile["info_cache"] as? [String: Any] ?? [:]
        let open = Set(profile["last_active_profiles"] as? [String] ?? [])
        var out: [Profile] = []
        for dir in cache.keys.sorted() {
            let base = root.appendingPathComponent(dir, isDirectory: true)
            var ids: [String] = []
            for id in ChromeExtension.ids {
                // A store install unpacks under Extensions/<id>; an unpacked
                // load lives only in the profile's (Secure) Preferences.
                if fm.fileExists(atPath: base.appendingPathComponent("Extensions/\(id)").path)
                    || inPreferences(id, base) { ids.append(id) }
            }
            let name = (cache[dir] as? [String: Any])?["name"] as? String ?? dir
            out.append(Profile(dir: dir, name: name, open: open.contains(dir), ids: ids))
        }
        return .read(out)
    }

    private static func inPreferences(_ id: String, _ base: URL) -> Bool {
        for file in ["Secure Preferences", "Preferences"] {
            guard let data = FileManager.default.contents(atPath: base.appendingPathComponent(file).path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = (obj["extensions"] as? [String: Any])?["settings"] as? [String: Any]
            else { continue }
            if settings[id] != nil { return true }
        }
        return false
    }
}

/// Everything the row's state is decided from, gathered in one place so a
/// test (and `--settings-snapshot`) can hand in each combination.
struct ChromeLaneFacts: Equatable, Sendable {
    var host: ChromeHostManifest.Status
    var seen: ChromeSeen?
    var profiles: ChromeProfiles.Scan
    var chromeRunning: Bool

    /// Nothing known beyond the status line: what a demo or a test without
    /// facts sees.
    static let none = ChromeLaneFacts(host: .absent, seen: nil, profiles: .unknown, chromeRunning: false)

    /// Evidence the extension is in this Chrome at all: the host saw it, or a
    /// profile holds it.
    var installed: Bool { seen != nil || !(profiles.withExtension ?? []).isEmpty }

    /// It is installed, but only in profiles Chrome does not have open.
    var onlyInClosedProfiles: Bool {
        guard chromeRunning, let found = profiles.withExtension, !found.isEmpty,
              case .read(let all) = profiles, all.contains(where: \.open) else { return false }
        return !found.contains(where: \.open)
    }

    static func live() -> ChromeLaneFacts {
        ChromeLaneFacts(host: ChromeHostManifest.read(), seen: ChromeSeen.read(), profiles: ChromeProfiles.scan(),
                        chromeRunning: !NSRunningApplication.runningApplications(
                            withBundleIdentifier: ChromeExtension.chromeBundleID).isEmpty)
    }
}
