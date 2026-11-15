import Foundation
import Testing
import MoeBrain
@testable import Moe

/// Connections › Chrome (ticket #13). The reports below are what
/// `configure-hermes.py --chrome-extension-status` printed on 2026-09-24
/// against a throwaway Chrome for Testing 154 with the Memoe extension
/// loaded unpacked and a scratch Hermes home — measured, then quoted.
@MainActor
@Suite(.serialized)
struct ChromeExtensionTests {
    static let measuredNotInstalled = #"{"connected": false, "enabled": false, "error": null, "extension": null, "host_installed": false, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": []}"#
    static let measuredOff = #"{"connected": false, "enabled": false, "error": null, "extension": null, "host_installed": true, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": []}"#
    static let measuredWaiting = #"{"connected": false, "enabled": true, "error": null, "extension": null, "host_installed": true, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": []}"#
    static let measuredConnected = #"{"connected": true, "enabled": true, "error": null, "extension": {"extensionId": "ljblhmlmgflmbffbfelamefleikodmjh", "fileAccess": true, "protocol": 1, "version": "0.2.1"}, "host_installed": true, "source": "/Users/x/.hermes/hermes-agent/extensions/chrome", "warnings": [{"code": "file_access_on", "text": "Moe's Chrome extension is allowed to open files on this Mac. Moe never uses that; turn it off in Chrome › Extensions › Memoe › \"Allow access to file URLs\"."}]}"#

    nonisolated static let goodHost = ChromeHostManifest.Status(present: true, missingIDs: [], launcherOK: true)
    nonisolated static let seenStore = ChromeSeen(extensionID: ChromeExtension.storeID, at: .distantPast)
    nonisolated static func facts(host: ChromeHostManifest.Status = goodHost, seen: ChromeSeen? = seenStore,
                      profiles: ChromeProfiles.Scan = .unknown, running: Bool = true) -> ChromeLaneFacts {
        ChromeLaneFacts(host: host, seen: seen, profiles: profiles, chromeRunning: running)
    }

    @Test func theRowSaysOneOfItsStatesFromTheStatusLineAndWhatTheAppSees() throws {
        func state(_ json: String, _ f: ChromeLaneFacts = Self.facts()) -> ChromeLaneState {
            ChromeLaneState.from(ChromeLaneReport.parse("written: noise\n" + json), facts: f)
        }
        #expect(state(Self.measuredNotInstalled, .none) == .notInstalled)
        #expect(state(Self.measuredOff) == .off)
        #expect(state(Self.measuredWaiting) == .waiting)
        #expect(state(Self.measuredConnected) == .connected)
        #expect(state(Self.measuredConnected, .none) == .connected, "connected wins whatever the app reads")
        // Set up and on, but nothing says the extension is in Chrome: not installed, Add to Chrome.
        #expect(state(Self.measuredWaiting, Self.facts(seen: nil)) == .notInstalled)
        // In Chrome, but the host is missing / lets in only the dev id / has no launcher: can't reach.
        #expect(state(Self.measuredNotInstalled, Self.facts(host: .absent)) == .cantReach,
                "installed from the store before Memoe ever wrote a host")
        #expect(state(Self.measuredWaiting, Self.facts(host: .init(present: true, missingIDs: [ChromeExtension.storeID],
                                                                launcherOK: true))) == .cantReach)
        #expect(state(Self.measuredWaiting, Self.facts(host: .init(present: true, missingIDs: [], launcherOK: false))) == .cantReach)
        // Only in a profile that is not open, while Chrome is.
        let elsewhere = ChromeProfiles.Scan.read([.init(dir: "Default", name: "Me", open: true, ids: []),
                                                  .init(dir: "Profile 1", name: "Work", open: false, ids: [ChromeExtension.storeID])])
        #expect(state(Self.measuredWaiting, Self.facts(seen: nil, profiles: elsewhere)) == .wrongProfile)
        #expect(state(Self.measuredWaiting, Self.facts(seen: nil, profiles: elsewhere, running: false)) == .waiting,
                "Chrome closed: no profile is open, so none is the wrong one")
        #expect(ChromeLaneState.from(nil, facts: Self.facts()) == .notInstalled)
        #expect(ChromeLaneState.waiting.word == "Installed, not connected")
        #expect(ChromeLaneState.cantReach.word == "Installed, can't reach Memoe")
        #expect(ChromeLaneState.wrongProfile.word == "In another Chrome profile")
        #expect(ChromeLaneState.connected.word == "Connected")
        #expect(ChromeLaneState.notInstalled.word == "Not installed")
    }

    @Test func eachStateThatIsNotWorkingSaysWhyInWords() throws {
        func why(_ json: String, _ f: ChromeLaneFacts) -> String? {
            ChromeExtensionModel(demo: ChromeLaneReport.parse(json)!, facts: f).why
        }
        #expect(why(Self.measuredWaiting, Self.facts(running: false)) == ChromeExtension.Copy.waitingChromeClosed)
        #expect(why(Self.measuredWaiting, Self.facts())?.contains("different") == false)
        #expect(why(Self.measuredWaiting, Self.facts())?.contains("profile") == true)
        #expect(why(Self.measuredWaiting, Self.facts(host: .init(present: true, missingIDs: [ChromeExtension.storeID],
                                                                   launcherOK: true))) == ChromeExtension.Copy.hostOutdated)
        #expect(why(Self.measuredNotInstalled, Self.facts(host: .absent)) == ChromeExtension.Copy.hostMissing)
        let elsewhere = ChromeProfiles.Scan.read([.init(dir: "Default", name: "Me", open: true, ids: []),
                                                  .init(dir: "Profile 1", name: "Work", open: false, ids: [ChromeExtension.extensionID])])
        #expect(why(Self.measuredWaiting, Self.facts(seen: nil, profiles: elsewhere))?.contains("“Work”") == true)
        #expect(why(Self.measuredConnected, Self.facts()) == nil)
    }

    @Test func theFileAccessWarningIsShownOnlyWhenConnectedAndPresent() throws {
        let on = ChromeExtensionModel(demo: try #require(ChromeLaneReport.parse(Self.measuredConnected)))
        #expect(on.fileAccessWarning?.contains("Allow access to file URLs") == true)
        let clean = Self.measuredConnected.replacingOccurrences(
            of: #"[{"code": "file_access_on""#, with: #"[{"code": "other""#)
        #expect(ChromeExtensionModel(demo: try #require(ChromeLaneReport.parse(clean))).fileAccessWarning == nil)
    }

    final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var opened: [URL] = []
        var revealed: [URL] = []
        var failInstall = false
        var chrome = true
        var matches = true
        var status = ChromeExtensionTests.measuredWaiting
        var facts = ChromeExtensionTests.facts()
        var heals = 0
        let lock = NSLock()
    }

    static func model(_ r: Recorder) -> ChromeExtensionModel {
        ChromeExtensionModel(seams: .init(
            configure: { args in
                r.lock.lock(); defer { r.lock.unlock() }
                r.calls.append(args)
                if args.first == "--install-chrome-extension", r.failInstall {
                    return .failure(.init(message: "this Hermes has no extensions/chrome"))
                }
                return .success(args == ["--chrome-extension-status"] ? r.status : "written: ok")
            },
            stagedExists: { true },
            chromeInstalled: { r.chrome },
            stagedMatches: { _ in r.matches },
            openInChrome: { r.opened.append($0); return true },
            revealInFinder: { r.revealed.append($0) },
            healHost: { r.lock.lock(); defer { r.lock.unlock() }; r.heals += 1; return .ok },
            facts: { r.lock.lock(); defer { r.lock.unlock() }; return r.facts }))
    }

    @Test func addToChromeWritesTheHostHealsItTurnsTheFlagOnAndOpensTheListing() async throws {
        let r = Recorder()
        r.facts = Self.facts(seen: nil)          // not in Chrome yet
        let m = Self.model(r)
        await m.setUp()
        #expect(r.calls == [
            ["--install-chrome-extension", ChromeExtension.stagedFolder.path],
            ["--set-chrome-extension", "on"],
            ["--chrome-extension-status"],
        ])
        #expect(r.heals == 2, "after install-host (which may write the dev id alone), and before the status read")
        #expect(r.opened == [URL(string: "https://chromewebstore.google.com/detail/nmdhnfjfpipnjbfbiligpbdnpfdkojjn")!])
        #expect(r.revealed.isEmpty, "no folder: the store installs it")
        #expect(m.state == .notInstalled)
        // The person clicks Add to Chrome; the host sees its hello.
        r.facts = Self.facts()
        await m.refresh()
        #expect(m.state == .waiting)
        // The extension says hello: the next poll turns the row green.
        r.status = Self.measuredConnected
        await m.refresh()
        #expect(m.state == .connected)
    }

    @Test func aFailedInstallNeverTurnsTheLaneOn() async throws {
        let r = Recorder()
        r.failInstall = true
        let m = Self.model(r)
        await m.setUp()
        #expect(r.calls == [["--install-chrome-extension", ChromeExtension.stagedFolder.path]])
        #expect(r.opened.isEmpty)
        #expect(m.note.contains("extensions/chrome"))
    }

    @Test func turningItOffWritesTheFlagOffAndSaysWhereToRemoveIt() async throws {
        let r = Recorder()
        r.status = Self.measuredOff
        let m = Self.model(r)
        await m.setEnabled(false)
        #expect(r.calls == [["--set-chrome-extension", "off"], ["--chrome-extension-status"]])
        #expect(m.state == .off)
        #expect(m.note.contains("remove it there"))
        await m.setEnabled(true)
        #expect(r.calls.dropFirst(2).first == ["--set-chrome-extension", "on"])
    }

    /// Review, 2026-09-24: install-host's mkdir(parents=True) made Chrome's own
    /// folder on a Mac with no Chrome. Nothing may run before the check.
    @Test func withoutChromeSetUpDoesNothingAndSaysInstallChromeFirst() async {
        let r = Recorder()
        r.chrome = false
        let m = Self.model(r)
        await m.setUp()
        #expect(r.calls.isEmpty, "no install-host, no flag, no status")
        #expect(r.opened.isEmpty && r.revealed.isEmpty)
        #expect(m.note.hasPrefix("Install Google Chrome first"))
    }

    @Test func repairRewritesTheHostAndOpensNothing() async {
        let r = Recorder()
        r.facts = Self.facts(host: .init(present: true, missingIDs: [ChromeExtension.storeID], launcherOK: true))
        let m = Self.model(r)
        await m.refresh()
        #expect(m.state == .cantReach)
        await m.setUp(openChrome: false)
        #expect(r.calls.contains(["--install-chrome-extension", ChromeExtension.stagedFolder.path]))
        #expect(r.opened.isEmpty && r.revealed.isEmpty)
        #expect(r.heals >= 3)
    }

    /// With the store, Chrome keeps the extension current itself: a staged
    /// folder that differs from the pin is no reason to say Update.
    @Test func withTheStoreAStagedFolderThatDiffersIsNotAnUpdate() async {
        let r = Recorder()
        r.status = Self.measuredConnected
        r.matches = false
        let m = Self.model(r)
        await m.refresh()
        #expect(m.state == .connected)
        #expect(!m.needsUpdate)
        #expect(m.word == "Connected · one thing to check")
    }

    @Test func theConnectedBuildIsNamedByItsId() throws {
        let dev = ChromeExtensionModel(demo: try #require(ChromeLaneReport.parse(Self.measuredConnected)))
        #expect(dev.connectedBuild == "dev")
        let store = ChromeExtensionModel(demo: try #require(ChromeLaneReport.parse(
            Self.measuredConnected.replacingOccurrences(of: ChromeExtension.extensionID, with: ChromeExtension.storeID))))
        #expect(store.connectedBuild == "store")
    }

    @Test func theDigestSeesAChangedFileAndIgnoresWhereTheFolderIs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("chrome-digest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func tree(_ name: String, _ bg: String) throws -> URL {
            let d = root.appendingPathComponent(name)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(#"{"version": "0.2.1"}"#.utf8).write(to: d.appendingPathComponent("manifest.json"))
            try Data(bg.utf8).write(to: d.appendingPathComponent("background.js"))
            return d
        }
        let a = try tree("a", "one"), b = try tree("b", "one"), c = try tree("c", "two")
        #expect(ChromeExtension.treeDigest(a) != nil)
        #expect(ChromeExtension.treeDigest(a) == ChromeExtension.treeDigest(b))
        #expect(ChromeExtension.treeDigest(a) != ChromeExtension.treeDigest(c))
        #expect(ChromeExtension.treeDigest(root.appendingPathComponent("missing")) == nil)
    }

    @Test func theStoreURLPointsAtTheStoreIdAndBothIdsAreKnown() {
        #expect(ChromeExtension.storeURL?.absoluteString
                == "https://chromewebstore.google.com/detail/nmdhnfjfpipnjbfbiligpbdnpfdkojjn")
        #expect(ChromeExtension.extensionID == "ljblhmlmgflmbffbfelamefleikodmjh")
        #expect(ChromeExtension.storeID == "nmdhnfjfpipnjbfbiligpbdnpfdkojjn")
        #expect(ChromeExtension.ids == [ChromeExtension.storeID, ChromeExtension.extensionID])
        #expect(ChromeExtension.id(fromOrigin: "chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/") == ChromeExtension.storeID)
        #expect(ChromeExtension.id(fromOrigin: "chrome-extension://ljblhmlmgflmbffbfelamefleikodmjh") == ChromeExtension.extensionID)
        #expect(ChromeExtension.id(fromOrigin: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/") == nil)
    }

    // MARK: What the app reads for itself

    static func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// What every install before 2026-11-12 wrote (measured on the owner's
    /// Mac that day: `allowed_origins` held the dev id alone).
    static let measuredDevOnlyHost = #"""
    {
      "name": "app.memoe.chrome_bridge",
      "description": "Memoe: lets Moe work in its own tab group in this browser",
      "path": "/Users/x/.hermes/chrome-bridge/memoe-chrome-host",
      "type": "stdio",
      "allowed_origins": [
        "chrome-extension://ljblhmlmgflmbffbfelamefleikodmjh/"
      ]
    }
    """#

    @Test func healingAddsTheStoreOriginToAnOldHostAndKeepsEverythingElse() throws {
        let d = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: d) }
        let url = d.appendingPathComponent("app.memoe.chrome_bridge.json")
        try Data(Self.measuredDevOnlyHost.utf8).write(to: url)
        #expect(ChromeHostManifest.read(url).missingIDs == [ChromeExtension.storeID])
        #expect(ChromeHostManifest.heal(url) == .healed(added: [ChromeExtension.storeID]))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(obj["allowed_origins"] as? [String] == ["chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/",
                                                         "chrome-extension://ljblhmlmgflmbffbfelamefleikodmjh/"])
        #expect(obj["path"] as? String == "/Users/x/.hermes/chrome-bridge/memoe-chrome-host")
        #expect(obj["name"] as? String == "app.memoe.chrome_bridge" && obj["type"] as? String == "stdio")
        #expect(obj["description"] as? String == "Memoe: lets Moe work in its own tab group in this browser")
        #expect(ChromeHostManifest.read(url).missingIDs.isEmpty)
        #expect(ChromeHostManifest.heal(url) == .ok, "a second launch changes nothing")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: d.path)
        #expect(leftovers == ["app.memoe.chrome_bridge.json"], "no temp file left beside it")
    }

    @Test func healingNeverCreatesAHostAndNeverTouchesAnotherOne() throws {
        let d = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: d) }
        let url = d.appendingPathComponent("NativeMessagingHosts/app.memoe.chrome_bridge.json")
        #expect(ChromeHostManifest.heal(url) == .absent)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
                "no Chrome folder made on a Mac that was never set up")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = Self.measuredDevOnlyHost.replacingOccurrences(of: "\"app.memoe.chrome_bridge\"", with: "\"com.other.host\"")
        try Data(foreign.utf8).write(to: url)
        #expect(ChromeHostManifest.heal(url) == .untouched("not Memoe's host"))
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign)
        try Data("not json".utf8).write(to: url)
        #expect(ChromeHostManifest.heal(url) == .untouched("not JSON"))
    }

    @Test func theHostsNoteRecognisesEitherIdAndNoOther() throws {
        let d = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: d) }
        func seen(_ origin: String) throws -> ChromeSeen? {
            try Data(#"{"extension_origin": "\#(origin)", "extension_id": "x", "version": "0.2.2", "at": 1763000000.5, "pid": 1}"#.utf8)
                .write(to: d.appendingPathComponent("seen.json"))
            return ChromeSeen.read(d)
        }
        #expect(try seen("chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/")?.extensionID == ChromeExtension.storeID)
        #expect(try seen("chrome-extension://ljblhmlmgflmbffbfelamefleikodmjh/")?.extensionID == ChromeExtension.extensionID)
        #expect(try seen("chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/")?.at == Date(timeIntervalSince1970: 1763000000.5))
        #expect(try seen("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/") == nil)
        // An older Hermes writes no seen.json, only a live bridge.json.
        try FileManager.default.removeItem(at: d.appendingPathComponent("seen.json"))
        try Data(#"{"extension_origin": "chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/", "pid": \#(getpid()), "started_at": 5}"#.utf8)
            .write(to: d.appendingPathComponent("bridge.json"))
        #expect(ChromeSeen.read(d)?.extensionID == ChromeExtension.storeID)
        try Data(#"{"extension_origin": "chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/", "pid": 999999, "started_at": 5}"#.utf8)
            .write(to: d.appendingPathComponent("bridge.json"))
        #expect(ChromeSeen.read(d) == nil, "a dead host's bridge is no evidence")
    }

    @Test func theProfileScanFindsEitherIdAndSaysUnknownWhenChromeIsClosedToIt() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ChromeProfiles.scan(root) == .unknown, "no Local State (or not readable): unknown, not 'not installed'")
        let fm = FileManager.default
        try Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}, "Profile 2": {"name": "Kids"}}, "last_active_profiles": ["Default"]}}"#.utf8)
            .write(to: root.appendingPathComponent("Local State"))
        // Store install: unpacked under Extensions/<id>. Dev: only in Secure Preferences.
        try fm.createDirectory(at: root.appendingPathComponent("Profile 1/Extensions/\(ChromeExtension.storeID)/0.2.2_0"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)
        try Data(#"{"extensions": {"settings": {"ljblhmlmgflmbffbfelamefleikodmjh": {"location": 4}}}}"#.utf8)
            .write(to: root.appendingPathComponent("Profile 2/Secure Preferences"))
        let scan = ChromeProfiles.scan(root)
        #expect(scan == .read([.init(dir: "Default", name: "Personal", open: true, ids: []),
                               .init(dir: "Profile 1", name: "Work", open: false, ids: [ChromeExtension.storeID]),
                               .init(dir: "Profile 2", name: "Kids", open: false, ids: [ChromeExtension.extensionID])]))
        let f = ChromeLaneFacts(host: Self.goodHost, seen: nil, profiles: scan, chromeRunning: true)
        #expect(f.installed && f.onlyInClosedProfiles)
    }
}
