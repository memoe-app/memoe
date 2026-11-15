import Foundation

// Erase Memoe from this Mac — docs/CLOUD-REMAINING.md D9.12.
//
// **This file deletes a person's data.** Everything in it is arranged around
// one question — *what may this touch?* — and the answer is always a list
// somebody can read, never a pattern:
//
//   * paths are named one by one, and every one passes `refusal(for:)` —
//     inside the home directory, never `~/.claude`, `~/.codex`, the keychain
//     files, a `Moe-backup-*`, or the OTHER identity's home — at plan time
//     AND again at the moment of deletion;
//   * keychain items are an explicit allowlist of (service, account) pairs,
//     each with the file that creates it, and a test fails when the code
//     grows a service name that is in neither the allowlist nor the
//     not-ours list (Tests/MoeEraseTests/KeychainAllowlistGuardTests.swift);
//   * launchd jobs are an explicit list of labels, never a `com.moe.` prefix
//     — `com.moe.worktree-snapshot` is a developer's safety net and matches
//     that prefix;
//   * the scope is the bundle identifier. Moe Dev erases Moe Dev. Two things
//     on disk are NOT scoped by identifier and are shared by both builds —
//     `~/.hermes` (HermesSeed.destination) and the keychain service names
//     (`moe-child-oauth` and the rest) — so those belong to the release
//     identity and a Moe Dev erase leaves them, and says so;
//   * one thing outside `~` may go, and only for Moe: CuaDriver, the tool Moe
//     uses to work the screen (`MacEraseCuaDriver`, the owner's decision of
//     2026-09-11 — Moe installed it, and a person would not have it
//     otherwise). Exactly `<Applications>/CuaDriver.app`, a real folder and
//     not a link, whose Info.plist says `com.trycua.driver` — read when the
//     plan is made and again just before removal. Moe Dev never removes it:
//     like `~/.hermes`, it is shared with Moe.
//
// Nothing here reaches the real machine on its own: the home directory, the
// Applications folder, the keychain, launchctl, tccutil, defaults, the file
// removals and the relaunch are all handed in.
// `Sources/Moe/MacErase.swift` is the only place the real ones are chosen.

// MARK: - Who is being erased

public struct MacEraseIdentity: Equatable, Sendable {
    public enum Kind: String, Sendable { case release, dev }

    public static let releaseBundleID = "com.memoe.app"
    public static let devBundleID = "com.memoe.app.dev"

    public let bundleID: String
    public let kind: Kind

    /// Only the two identities build.sh makes. Anything else — a bare
    /// `swift build` binary with no bundle, a renamed copy — is refused: an
    /// erase that has to guess whose data it is must not run.
    public init?(bundleID: String?) {
        switch bundleID {
        case Self.releaseBundleID?: self.bundleID = Self.releaseBundleID; kind = .release
        case Self.devBundleID?: self.bundleID = Self.devBundleID; kind = .dev
        default: return nil
        }
    }

    /// The folder under `~/Library/Application Support` (build.sh: Moe's home
    /// is `…/Moe`; Moe Dev's `MoeHome` is `…/Moe Dev`).
    public var homeFolderName: String { kind == .release ? "Moe" : "Moe Dev" }

    /// `~/.hermes` and the keychain service names are the same for both
    /// builds. They are the release app's; Moe Dev borrows them.
    public var ownsSharedResources: Bool { kind == .release }

    /// Whether code running as `bundleID` may touch the keychain items whose
    /// names Moe and Moe Dev share. Only the release identity; an unknown one
    /// (a bare `swift build` binary) may not, because it cannot say whose they
    /// are. `CloudSync.deleteAccount` asks this before removing the Composio
    /// key, and the erase asks it through `ownsSharedResources`.
    public static func mayTouchSharedKeychain(bundleID: String?) -> Bool {
        MacEraseIdentity(bundleID: bundleID)?.ownsSharedResources ?? false
    }

    /// Every launchd label this identity has ever installed, named — never a
    /// prefix. Where each comes from:
    ///
    ///   com.moe.jobs, <id>.jobs   `Launchd.jobsLabel` (Sources/Moe/MainWindow.swift):
    ///                             "com.moe.jobs" for Moe, bundle id + ".jobs" otherwise
    ///   com.memoe.app             `Launchd.jobDefinition` — the open-at-login job
    ///   com.moe.sync, .digest,
    ///   com.moe.assistant         `Launchd.supersededLabels`, scripts/install.sh
    ///   com.moe.bot               scripts/install.sh — the pre-Hermes Telegram bot
    ///
    /// NOT here, on purpose: `com.moe.worktree-snapshot` (scripts/install-guards.sh,
    /// the developer's snapshot net) and anything Hermes installs for itself.
    public var launchdLabels: [String] {
        switch kind {
        case .release:
            return ["com.moe.jobs", "com.memoe.app", "com.moe.assistant",
                    "com.moe.sync", "com.moe.digest", "com.moe.bot"]
        case .dev:
            return [bundleID + ".jobs"]
        }
    }
}

// MARK: - The keychain allowlist

/// One kind of keychain item Moe creates or is handed. `account == nil` means
/// every account under the service — used only for services whose name is
/// Moe's alone (`moe-…`); a generic-looking service is always pinned to the
/// account Moe uses.
public struct MacEraseKeychainEntry: Equatable, Sendable {
    public let service: String
    public let account: String?
    /// The file that creates or reads it, so a reviewer can check the claim.
    public let source: String
}

public enum MacEraseKeychain {
    /// Every generic-password item Moe created, and nothing else. This list IS
    /// the erase: nothing outside it is ever deleted, and there is no
    /// wildcard, no class-wide delete, and no internet-password or identity
    /// query anywhere in this module.
    public static let allowlist: [MacEraseKeychainEntry] = [
        .init(service: "moe-child-oauth", account: "moe",
              source: "Sources/Moe/Onboarding/ClaudeSignIn.swift store(token:), scripts/hermes-signin.sh — Moe's own Claude setup-token"),
        .init(service: "moe-composio-scoped", account: "api-key",
              source: "ComposioKeychain (the cloud half) — the tenant's Composio project key"),
        .init(service: "moe-composio-scoped", account: "api-base",
              source: "ComposioKeychain (the cloud half) — the edge's Composio proxy address, beside the proxy token"),
        .init(service: "moe-composio", account: "api-key",
              source: "moe-home/connectors/composio.py KEYCHAIN_SERVICES, scripts/composio-api.sh — the older Composio key Moe reads"),
        .init(service: "moe-telegram-bot", account: nil,
              source: "moe-home/hermes/configure-hermes.py TELEGRAM_KEYCHAIN_SERVICE — the Telegram channel token"),
        .init(service: "moe-gmail", account: nil,
              source: "scripts/connect-gmail.sh, scripts/connect.sh, moe-home/connectors/gmail.py — account is the address"),
        .init(service: "moe-google-docs", account: nil,
              source: "scripts/connect-drive-docs.sh, moe-home/connectors/drive-docs.py — the Drive/Docs refresh token"),
        .init(service: "assemblyai-api-key", account: "moe",
              source: "Sources/Moe/Cloud/CloudVoice.swift DeveloperVoiceCredentials — an API key given to Moe"),
        .init(service: "inworld-api-key", account: "moe",
              source: "Sources/Moe/Cloud/CloudVoice.swift DeveloperVoiceCredentials — an API key given to Moe"),
        .init(service: "com.memoe.app.consent-key", account: "consent-signing-key",
              source: "ConsentKey.appStore (the cloud half) — this Mac's key for agreeing (D9.14); gone, it only means signing in with Google again. Moe Dev's is com.memoe.app.dev.consent-key, and Moe Dev's erase leaves the keychain alone"),
    ]

    /// Moe Dev's own items, and the only keychain items Moe Dev's erase may
    /// touch: its key for agreeing, named by its own bundle id. Every name on
    /// `allowlist` is shared with Moe (or is Moe's alone) and Moe Dev never
    /// deletes one.
    public static let devAllowlist: [MacEraseKeychainEntry] = [
        .init(service: "com.memoe.app.dev.consent-key", account: "consent-signing-key",
              source: "ConsentKey.appStore (the cloud half) under Moe Dev's bundle id — Moe Dev's own key for agreeing"),
    ]

    /// What an identity's erase may delete from the keychain: Moe's list for
    /// Moe, Moe Dev's own for Moe Dev.
    public static func entries(for identity: MacEraseIdentity) -> [MacEraseKeychainEntry] {
        identity.ownsSharedResources ? allowlist : devAllowlist
    }

    /// Service names that appear in the code and are deliberately NOT erased.
    /// The guard test accepts a name found in the code only if it is in the
    /// allowlist or here, so adding a keychain item anywhere forces a
    /// decision about it.
    public static let notOurs: [String: String] = [
        "Claude Code-credentials": "Claude Code's own sign-in; moe-home/doctor.sh only checks it exists. It belongs to Claude Code.",
        "https://sparkle-project.org": "the release-signing key. Never.",
        "moe-composio-org": "the operator's Composio org key (scripts/probe-composio-org.sh), a developer credential, not the person's.",
        "moe-admin-token": "the operator's edge admin token (scripts/tickets.sh), a developer credential, not the person's.",
    ]
}

// MARK: - CuaDriver

/// CuaDriver, the tool Moe uses to work the screen. Moe installs it —
/// scripts/install-hermes.sh step 6 runs `hermes computer-use install`, which
/// runs trycua's install.sh — and a person would not have it otherwise, so
/// Moe's erase removes it (the owner's decision, 2026-09-11). Moe Dev never
/// does: it is shared with Moe, like `~/.hermes`.
///
/// The app lives outside `~`, so it cannot pass `refusal(for:)`. It has its
/// own guard, `MacErase.cuaDriverRefusal(_:)`, and it is stricter.
/// Moe in your Chrome's native-messaging host (the fork's
/// tools/browser_chrome_extension.install_native_host, `--browser chrome`).
public enum MacEraseChromeHost {
    public static let name = "app.memoe.chrome_bridge"
    public static let manifest = "Library/Application Support/Google/Chrome/NativeMessagingHosts/\(name).json"
}

public enum MacEraseCuaDriver {
    public static let bundleID = "com.trycua.driver"
    public static let appName = "CuaDriver.app"
    /// The real Applications folder: the only place outside `~` an erase may
    /// name, and only for this one app. Handed in by Sources/Moe/MacErase.swift.
    public static let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    /// trycua's install.sh links its binary here. Removed only while it is a
    /// link into the app being removed.
    public static let commandLink = ".local/bin/cua-driver"
    /// What it writes under `~`, measured on this Mac on 2026-09-11 by
    /// listing, never deleting: `~/.cua-driver` (install records, a telemetry
    /// id), `~/Library/Caches/cua-driver` (its pid file and socket),
    /// `~/Library/Caches/CuaDriver` and `~/Library/Application Support/CuaDriver`
    /// (BrowserProfiles). `defaults read com.trycua.driver` found no domain and
    /// there was no Preferences plist; the bundle-id folders below are the
    /// ones macOS makes for any app, named in case a later version uses them.
    public static let data: [String] = [
        ".cua-driver",
        "Library/Caches/cua-driver",
        "Library/Caches/CuaDriver",
        "Library/Application Support/CuaDriver",
        "Library/Caches/\(bundleID)",
        "Library/HTTPStorages/\(bundleID)",
        "Library/HTTPStorages/\(bundleID).binarycookies",
        "Library/WebKit/\(bundleID)",
        "Library/Saved Application State/\(bundleID).savedState",
    ]
    public static let preferences = "Library/Preferences/\(bundleID).plist"
    /// The teams that sign official cua-driver releases: Hermes's own list,
    /// `_CUA_DRIVER_TEAM_IDS` in tools/computer_use/cua_backend_daemon.py at
    /// the pinned 1ef2655e (introduced in 6662b3618d, "accept current
    /// notarised CUA Driver"). Measured 2026-09-11, read-only:
    /// `codesign -dv /Applications/CuaDriver.app` reports
    /// `Identifier=com.trycua.driver` and `TeamIdentifier=YCK386LBJ7`. No
    /// "not set" escape: an unsigned or ad-hoc bundle is not CuaDriver,
    /// whatever its Info.plist says.
    public static let teamIDs: Set<String> = ["4YEC26S9KF", "YCK386LBJ7"]
}

// MARK: - The scope

public enum MacEraseKeychainTarget: Equatable, Sendable {
    /// The user's keychain search list — the login keychain. Release only.
    case searchList
    /// One keychain file, named explicitly. Tests and scratch runs.
    case file(URL)
    /// No keychain at all.
    case none
}

public struct MacEraseScopeError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Everything the plan needs, resolved once. Nothing in it is read from the
/// process — `resolve` is handed the bundle, the environment and the home.
public struct MacEraseScope: Equatable, Sendable {
    public let identity: MacEraseIdentity
    /// `~`. Every path this erase removes is inside it.
    public let userHome: URL
    public let moeHome: URL
    /// Nil when the Hermes home is not this identity's to erase.
    public let hermesHome: URL?
    public let keychain: MacEraseKeychainTarget
    /// A debug run against a scratch home: system commands are recorded and
    /// never executed, and the relaunch does nothing.
    public let scratch: Bool
    public let recordFile: URL?
    /// Where CuaDriver.app is looked for: `/Applications` from the real app,
    /// the scratch `~/Applications` in a scratch run, a folder inside the fake
    /// home in tests. Nil: no app is named at all. Whether it may be removed
    /// is the identity's question (`cuaDriverRefusal`), not this field's.
    public let applicationsDir: URL?
    /// A stand-in for /usr/bin/codesign. Scratch runs only, from inside the
    /// scratch ~ (scripts/test-privacy-erase.sh); nil everywhere else.
    public let codesignTool: URL?

    public init(identity: MacEraseIdentity, userHome: URL, moeHome: URL, hermesHome: URL?,
                keychain: MacEraseKeychainTarget, scratch: Bool, recordFile: URL? = nil,
                applicationsDir: URL? = nil, codesignTool: URL? = nil) {
        self.identity = identity
        self.userHome = userHome
        self.moeHome = moeHome
        self.hermesHome = hermesHome
        self.keychain = keychain
        self.scratch = scratch
        self.recordFile = recordFile
        self.applicationsDir = applicationsDir
        self.codesignTool = codesignTool
    }

    /// `/Applications` itself, or a folder strictly inside `~` (a test's or a
    /// scratch run's). Anything else is not a place an erase may look.
    static func acceptableApplications(_ url: URL, userHome: URL) -> Bool {
        MacErase.samePath(url, MacEraseCuaDriver.systemApplications) || MacErase.isStrictlyInside(url, userHome)
    }

    /// The same resolution `Config.homeDir` does, plus the rules only an
    /// erase needs.
    ///
    /// - A release build (no `MoeHome` in its Info.plist) erases
    ///   `~/Library/Application Support/Moe`, `~/.hermes` and the keychain.
    /// - A dev build must carry `MoeHome` = `~/Library/Application Support/Moe Dev`
    ///   exactly, and erases that and nothing shared.
    /// - A DEBUG build with `MOE_HOME` set is a scratch run and must also be
    ///   given `MOE_ERASE_USER_HOME` (which may not be the real home); its
    ///   Hermes home is `HERMES_HOME` or none, its keychain `MOE_ERASE_KEYCHAIN`
    ///   or none. A scratch home with no scratch `~` is refused outright:
    ///   the real `~/.moe`, FluidAudio and LaunchAgents would otherwise be in
    ///   reach of a test.
    ///
    /// `applications` is where CuaDriver.app is looked for. The real app
    /// passes `/Applications`; left out, no app is named at all — so a caller
    /// that forgets it cannot reach the real one. It must be `/Applications`
    /// or inside `~`. A scratch run ignores it and uses the scratch
    /// `~/Applications`.
    public static func resolve(bundleID: String?, infoMoeHome: String?,
                               environment env: [String: String],
                               realUserHome: URL, applications: URL? = nil,
                               debugBuild: Bool) throws -> MacEraseScope {
        func value(_ name: String) -> String? {
            guard let v = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let realHome = realUserHome.standardizedFileURL

        if debugBuild, let scratchHome = value("MOE_HOME") {
            guard let identity = MacEraseIdentity(bundleID: value("MOE_ERASE_BUNDLE_ID") ?? bundleID) else {
                throw MacEraseScopeError("not Moe or Moe Dev (bundle id \(bundleID ?? "none")); nothing is erased")
            }
            guard let fakeHome = value("MOE_ERASE_USER_HOME") else {
                throw MacEraseScopeError("MOE_HOME is set but MOE_ERASE_USER_HOME is not; a scratch erase needs a scratch ~")
            }
            let userHome = URL(fileURLWithPath: fakeHome, isDirectory: true).standardizedFileURL
            if MacErase.samePath(userHome, realHome) {
                throw MacEraseScopeError("MOE_ERASE_USER_HOME is the real home directory; refused")
            }
            // Apart from the real home in both directions. "/" or a parent of
            // the real home would put the real ~ — and, through the scratch
            // ~/Applications below, the real /Applications — in reach of a
            // test (the review, 2026-09-11: MOE_ERASE_USER_HOME=/ passed).
            if userHome.path == "/" || MacErase.isInside(realHome, userHome) || MacErase.isInside(userHome, realHome) {
                throw MacEraseScopeError("MOE_ERASE_USER_HOME (\(userHome.path)) is /, or holds or is inside "
                                         + "the real home \(realHome.path); a scratch ~ must be apart from it")
            }
            let scratchMoe = URL(fileURLWithPath: scratchHome, isDirectory: true).standardizedFileURL
            guard MacErase.isStrictlyInside(scratchMoe, userHome) else {
                throw MacEraseScopeError("MOE_HOME must be inside MOE_ERASE_USER_HOME")
            }
            if let h = value("HERMES_HOME"),
               !MacErase.isStrictlyInside(URL(fileURLWithPath: h).standardizedFileURL, userHome) {
                throw MacEraseScopeError("HERMES_HOME must be inside MOE_ERASE_USER_HOME")
            }
            let scratchApplications = userHome.appendingPathComponent("Applications", isDirectory: true)
            guard MacErase.isStrictlyInside(scratchApplications, userHome) else {
                throw MacEraseScopeError("the scratch Applications folder is not inside the scratch ~")
            }
            var codesignTool: URL?
            if let tool = value("MOE_ERASE_CODESIGN") {
                let url = URL(fileURLWithPath: tool).standardizedFileURL
                guard MacErase.isStrictlyInside(url, userHome) else {
                    throw MacEraseScopeError("MOE_ERASE_CODESIGN must be inside MOE_ERASE_USER_HOME")
                }
                codesignTool = url
            }
            let keychain: MacEraseKeychainTarget
            if let file = value("MOE_ERASE_KEYCHAIN") {
                let url = URL(fileURLWithPath: file).standardizedFileURL
                guard MacErase.isInside(url, userHome) else {
                    throw MacEraseScopeError("MOE_ERASE_KEYCHAIN must be inside MOE_ERASE_USER_HOME")
                }
                keychain = .file(url)
            } else {
                keychain = .none
            }
            return MacEraseScope(
                identity: identity, userHome: userHome,
                moeHome: scratchMoe,
                hermesHome: identity.ownsSharedResources
                    ? value("HERMES_HOME").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
                    : nil,
                keychain: keychain, scratch: true,
                recordFile: value("MOE_ERASE_RECORD").map { URL(fileURLWithPath: $0) },
                // Always the scratch ~'s own, whatever was passed. That keeps
                // the real /Applications out only because the scratch ~ was
                // required above to be neither / nor above nor inside the real
                // home, and this folder strictly inside it.
                applicationsDir: scratchApplications,
                codesignTool: codesignTool)
        }
        if let applications, !MacEraseScope.acceptableApplications(applications, userHome: realHome) {
            throw MacEraseScopeError("\(applications.path) is neither /Applications nor inside \(realHome.path); refused")
        }

        guard let identity = MacEraseIdentity(bundleID: bundleID) else {
            throw MacEraseScopeError("not Moe or Moe Dev (bundle id \(bundleID ?? "none")); nothing is erased")
        }
        let support = realHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        let stamped = infoMoeHome?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let moeHome: URL
        switch identity.kind {
        case .release:
            guard stamped.isEmpty else {
                throw MacEraseScopeError("a release build carrying MoeHome (\(stamped)) is not one build.sh makes; refused")
            }
            moeHome = support.appendingPathComponent("Moe", isDirectory: true)
        case .dev:
            let expanded = stamped.hasPrefix("~/")
                ? realHome.appendingPathComponent(String(stamped.dropFirst(2)), isDirectory: true)
                : URL(fileURLWithPath: stamped, isDirectory: true)
            let expected = support.appendingPathComponent("Moe Dev", isDirectory: true)
            guard !stamped.isEmpty, samePathStrict(expanded, expected) else {
                throw MacEraseScopeError("Moe Dev's home is \(stamped.isEmpty ? "unset" : stamped), "
                                         + "not \(expected.path); refused rather than guess")
            }
            moeHome = expected
        }
        var hermes: URL?
        if identity.ownsSharedResources {
            if debugBuild, let h = value("HERMES_HOME") {
                hermes = URL(fileURLWithPath: h, isDirectory: true).standardizedFileURL
            } else {
                hermes = realHome.appendingPathComponent(".hermes", isDirectory: true)
            }
        }
        return MacEraseScope(identity: identity, userHome: realHome, moeHome: moeHome.standardizedFileURL,
                             hermesHome: hermes,
                             // Moe Dev too, limited to its own items by
                             // `MacEraseKeychain.entries(for:)` in plan and run.
                             keychain: .searchList,
                             scratch: false,
                             // Moe Dev too: where the app is is a fact about
                             // the Mac. Whether it goes is the identity's
                             // question, asked in plan, guard and run.
                             applicationsDir: applications?.standardizedFileURL)
    }

    private static func samePathStrict(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}

// MARK: - The plan

public enum MacEraseItem: Equatable, Sendable {
    /// A file or folder, removed whole. Symlinks inside are removed as links,
    /// never followed.
    case path(URL, why: String)
    /// `~/.moe`, removed only while it is a link to the home being erased.
    case legacyLink(URL, to: URL)
    case keychain(MacEraseKeychainEntry)
    case launchd(label: String, plist: URL?, loaded: Bool)
    case defaults(domain: String)
    case tcc(bundleID: String)
    /// A process running from what is being erased — Moe's Hermes gateway
    /// (setsid'd, so it outlives the app), a job, a child. Stopped first.
    case process(pid: Int32, command: String)
    /// CuaDriver.app. Outside `~`, so never a `.path`: its own guard,
    /// `cuaDriverRefusal`, is checked when planned and again at removal.
    case cuaDriverApp(URL)
    /// `~/.local/bin/cua-driver`, removed only while it links into `to`.
    case cuaDriverLink(URL, to: URL)
    /// This app as a login item (System Settings › Login Items). Registered
    /// through ServiceManagement, not launchd, so it is its own step — the one
    /// the old Uninstall button took and the erase did not (DEFAULTS.md row 41).
    case loginItem(bundleID: String)

    public var kind: String {
        switch self {
        case .path: return "path"
        case .legacyLink, .cuaDriverLink: return "link"
        case .cuaDriverApp: return "app"
        case .keychain: return "keychain"
        case .launchd: return "launchd"
        case .defaults: return "defaults"
        case .tcc: return "tcc"
        case .loginItem: return "loginitem"
        case .process: return "process"
        }
    }

    public var target: String {
        switch self {
        case .path(let url, _): return url.path
        case .legacyLink(let url, _): return url.path
        case .cuaDriverApp(let url): return url.path
        case .cuaDriverLink(let url, _): return url.path
        case .keychain(let e): return e.account.map { "\(e.service) (\($0))" } ?? e.service
        case .launchd(let label, _, _): return label
        case .defaults(let domain): return domain
        case .tcc(let id): return id
        case .loginItem(let id): return id
        case .process(let pid, let command): return "\(pid) \(command)"
        }
    }

    public var why: String {
        switch self {
        case .path(_, let why): return why
        case .legacyLink(_, let to): return "the ~/.moe link to \(to.path)"
        case .cuaDriverApp: return "CuaDriver, the tool Moe uses to work your screen — Moe installed it"
        case .cuaDriverLink: return "the cua-driver command, a link into CuaDriver"
        case .keychain(let e): return e.source
        case .launchd(_, _, let loaded): return loaded ? "background job (running)" : "background job"
        case .defaults: return "Moe's preferences"
        case .tcc: return "the macOS permissions you gave Moe"
        case .loginItem: return "opening Moe when you log in (System Settings › Login Items)"
        case .process: return "running from what is being erased; stopped first"
        }
    }
}

public struct MacErasePlan: Equatable, Sendable {
    public let scope: MacEraseScope
    public let remove: [MacEraseItem]
    /// What is deliberately not touched, in words, for the second warning.
    public let left: [String]

    /// Whether this plan removes CuaDriver's app. The warnings read this, so
    /// they never promise a removal the plan will not make.
    public var removesCuaDriver: Bool {
        remove.contains { if case .cuaDriverApp = $0 { return true }; return false }
    }

    public func json() -> String {
        let object: [String: Any] = [
            "identity": scope.identity.bundleID,
            "home": scope.moeHome.path,
            "user_home": scope.userHome.path,
            "hermes_home": scope.hermesHome?.path ?? NSNull(),
            "applications": scope.applicationsDir?.path ?? NSNull(),
            "scratch": scope.scratch,
            "remove": remove.map { ["kind": $0.kind, "target": $0.target, "why": $0.why] },
            "left": left,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The seams

/// The keychain, as the erase sees it: ask whether an entry exists, and
/// delete every item matching it.
public protocol MacEraseKeychainAccess {
    func present(_ entry: MacEraseKeychainEntry) -> Bool
    /// How many items were deleted, or a description of why not.
    func deleteAll(_ entry: MacEraseKeychainEntry) -> Result<Int, MacEraseScopeError>
}

/// launchctl, tccutil, defaults. The exit status is all the erase reads.
public protocol MacEraseCommands {
    func run(_ executable: String, _ arguments: [String]) -> Int32
}

/// The app's own login item. ServiceManagement answers for the bundle of the
/// process asking, which is why the app hands in the real one and a test or
/// a scratch run hands in a stand-in or nothing.
public protocol MacEraseLoginItem {
    /// Registered to open at login — enabled, or waiting for approval.
    func isRegistered() -> Bool
    /// Take it out. Nil when it went; otherwise why not.
    func unregister() -> String?
}

/// Removing a file or folder: a link is removed as a link, never followed.
/// Handed in so a test can record what an erase tried to remove, not only
/// what is missing afterwards.
public protocol MacEraseFileOps {
    func removeItem(at url: URL) throws
}

public struct LocalFileOps: MacEraseFileOps {
    public init() {}
    public func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// Who signed an app, as `codesign -dv` reports it.
public struct MacEraseSigner: Equatable, Sendable {
    public let identifier: String
    public let team: String
    public init(identifier: String, team: String) {
        self.identifier = identifier
        self.team = team
    }
}

/// Reads an app's code signature. Handed in so no test needs the real
/// CuaDriver. Nil means it could not be read — a refusal.
public protocol MacEraseSignatureCheck {
    func signer(of app: URL) -> MacEraseSigner?
}

/// `codesign -dv <app>`: the question Hermes asks before it launches the
/// driver (`_validate_cua_driver_app_signature`). It only reads.
public struct CodesignSignature: MacEraseSignatureCheck {
    public let tool: String
    public init(tool: String = "/usr/bin/codesign") { self.tool = tool }

    public func signer(of app: URL) -> MacEraseSigner? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-dv", app.path]
        let errors = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = errors.fileHandleForReading.readDataToEndOfFile()   // codesign -dv reports on stderr
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    /// `Key=value` lines, the first of each key winning, as Hermes reads
    /// them. Both keys must be present.
    public static func parse(_ text: String) -> MacEraseSigner? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil {
                fields[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let identifier = fields["Identifier"], let team = fields["TeamIdentifier"] else { return nil }
        return MacEraseSigner(identifier: identifier, team: team)
    }
}

// MARK: - The engine

public enum MacEraseOutcome: Equatable, Sendable {
    case removed(String)
    case absent
    case refused(String)
    case failed(String)
    /// macOS would not let this process remove it: EPERM or EACCES, however
    /// Foundation wraps it (`outcome(ofRemovalError:)`). The person can, from
    /// Finder, and the note the erase leaves says so.
    case notAllowed(String)

    public var ok: Bool {
        switch self { case .removed, .absent: return true; case .refused, .failed, .notAllowed: return false }
    }
}

public struct MacEraseReport: Equatable, Sendable {
    public let outcomes: [(MacEraseItem, MacEraseOutcome)]
    public var failures: [(MacEraseItem, MacEraseOutcome)] { outcomes.filter { !$0.1.ok } }
    public var ok: Bool { failures.isEmpty }

    public static func == (a: MacEraseReport, b: MacEraseReport) -> Bool {
        a.outcomes.count == b.outcomes.count
            && zip(a.outcomes, b.outcomes).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public var text: String {
        outcomes.map { item, outcome in
            let what = "\(item.kind) \(item.target)"
            switch outcome {
            case .removed(let d): return "removed  \(what)\(d.isEmpty ? "" : " — \(d)")"
            case .absent: return "absent   \(what)"
            case .refused(let d): return "REFUSED  \(what) — \(d)"
            case .failed(let d): return "FAILED   \(what) — \(d)"
            case .notAllowed(let d): return "NOT ALLOWED \(what) — \(d)"
            }
        }.joined(separator: "\n")
    }
}

public struct MacErase {
    public let scope: MacEraseScope
    public let keychain: MacEraseKeychainAccess?
    public let commands: MacEraseCommands
    public let uid: UInt32
    /// Called once, after the erase, to start the app again. Onboarding
    /// follows on its own: `FirstRun` decides "first run" from whether the
    /// home's config.json exists, and the home is gone.
    public let relaunch: () -> Void
    /// The process table, for stopping what runs from the homes being erased.
    /// Nil: nothing is stopped (and a plan lists no processes).
    public let processes: MacEraseProcessTable?
    /// This process, which is never stopped.
    public let selfPID: Int32
    /// How long a SIGTERM'd process gets before SIGKILL.
    public var stopWait: TimeInterval = 5
    /// Every removal goes through this.
    public let files: MacEraseFileOps
    /// Reads CuaDriver's code signature. Unless one is handed in, the real
    /// `codesign` (or a scratch run's stand-in for it).
    public let signature: MacEraseSignatureCheck
    /// The app as a login item. Nil: nothing is unregistered (and a plan
    /// lists no login item) — every scratch run, and every test that does
    /// not hand one in.
    public let loginItem: MacEraseLoginItem?

    public init(scope: MacEraseScope, keychain: MacEraseKeychainAccess?, commands: MacEraseCommands,
                uid: UInt32, processes: MacEraseProcessTable? = nil, selfPID: Int32 = getpid(),
                files: MacEraseFileOps = LocalFileOps(), signature: MacEraseSignatureCheck? = nil,
                loginItem: MacEraseLoginItem? = nil,
                relaunch: @escaping () -> Void) {
        self.scope = scope
        self.keychain = keychain
        self.commands = commands
        self.uid = uid
        self.processes = processes
        self.selfPID = selfPID
        self.files = files
        self.signature = signature ?? CodesignSignature(tool: scope.codesignTool?.path ?? "/usr/bin/codesign")
        self.loginItem = loginItem
        self.relaunch = relaunch
    }

    /// The real adapters for a scope: `/usr/bin/security` against the target
    /// the scope names (none for Moe Dev), and launchctl/tccutil/defaults run
    /// for real — unless the scope is a scratch run, when they are recorded.
    public static func standard(scope: MacEraseScope, uid: UInt32, loginItem: MacEraseLoginItem? = nil,
                                relaunch: @escaping () -> Void) -> MacErase {
        let keychain: MacEraseKeychainAccess?
        switch scope.keychain {
        case .searchList: keychain = SecurityToolKeychain(keychainFile: nil)
        case .file(let url): keychain = SecurityToolKeychain(keychainFile: url)
        case .none: keychain = nil
        }
        let commands: MacEraseCommands = scope.scratch
            ? RecordingCommands(file: scope.recordFile)
            : ProcessCommands()
        // The real process table in a scratch run too: what it may stop is
        // decided by `processesToStop`, which only matches processes running
        // from the scratch homes.
        // A scratch run never reaches the real login item: ServiceManagement
        // would answer for the real app, whatever home the scope names.
        return MacErase(scope: scope, keychain: keychain, commands: commands, uid: uid,
                        processes: DarwinProcessTable(), loginItem: scope.scratch ? nil : loginItem,
                        relaunch: scope.scratch ? {} : relaunch)
    }

    // MARK: Locations

    private var library: URL { scope.userHome.appendingPathComponent("Library", isDirectory: true) }
    private var legacyLink: URL { scope.userHome.appendingPathComponent(".moe") }
    private func launchAgent(_ label: String) -> URL {
        library.appendingPathComponent("LaunchAgents/\(label).plist")
    }
    private var fluidAudioRoots: [URL] {
        [library.appendingPathComponent("Application Support/FluidAudio", isDirectory: true),
         scope.userHome.appendingPathComponent(".cache/fluidaudio", isDirectory: true)]
    }
    /// `<Applications>/CuaDriver.app`, or nil when the scope names no
    /// Applications folder.
    var cuaDriverAppURL: URL? {
        scope.applicationsDir?.appendingPathComponent(MacEraseCuaDriver.appName, isDirectory: true)
    }
    private var cuaDriverData: [URL] {
        MacEraseCuaDriver.data.map { scope.userHome.appendingPathComponent($0) }
    }

    /// Paths this identity must never delete, whatever it was asked: the
    /// other identity's home, Claude Code's and Codex's (and the `claude`
    /// command), the keychain files, and — for Moe Dev — everything it shares
    /// with Moe, CuaDriver included.
    var protectedRoots: [URL] {
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        var roots = [
            scope.userHome.appendingPathComponent(".claude", isDirectory: true),
            scope.userHome.appendingPathComponent(".codex", isDirectory: true),
            scope.userHome.appendingPathComponent(".local/bin/claude"),
            library.appendingPathComponent("Keychains", isDirectory: true),
        ]
        switch scope.identity.kind {
        case .release:
            roots.append(support.appendingPathComponent("Moe Dev", isDirectory: true))
        case .dev:
            roots.append(support.appendingPathComponent("Moe", isDirectory: true))
            roots.append(scope.userHome.appendingPathComponent(".hermes", isDirectory: true))
            roots.append(contentsOf: fluidAudioRoots)
            roots.append(contentsOf: cuaDriverData)
            roots.append(scope.userHome.appendingPathComponent(MacEraseCuaDriver.commandLink))
            if let app = cuaDriverAppURL { roots.append(app) }
        }
        return roots
    }

    // MARK: The guard

    /// Why `url` may not be deleted, or nil. Checked when the plan is made
    /// and again immediately before each deletion.
    ///
    /// The parent is resolved through symlinks and the last component is
    /// not, so `/var` vs `/private/var` compares correctly and a link is
    /// judged by where it sits, not where it points.
    public func refusal(for url: URL) -> String? {
        let candidate = Self.resolvedParent(url).path
        let home = Self.canonical(scope.userHome).path
        guard Self.within(candidate, home), candidate != home else {
            return "\(candidate) is not inside \(home)"
        }
        for component in candidate.split(separator: "/") where component.hasPrefix("Moe-backup") {
            return "\(candidate) is inside a backup (\(component))"
        }
        for root in protectedRoots {
            let r = Self.resolvedParent(root).path
            if Self.within(candidate, r) || Self.within(r, candidate) {
                return "\(candidate) is, or holds, \(r), which this erase must not touch"
            }
        }
        return nil
    }

    static func resolvedParent(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        guard std.path != "/" else { return std }
        return canonical(std.deletingLastPathComponent()).appendingPathComponent(std.lastPathComponent)
    }

    /// `realpath(3)` of the deepest part of `url` that exists, with the rest
    /// appended. Foundation's `resolvingSymlinksInPath` strips `/private`
    /// from paths that exist and may leave `/var` alone on paths that do not,
    /// so two spellings of one place could compare unequal — and the guard
    /// is a comparison. This gives every path one spelling.
    public static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        let fm = FileManager.default
        while existing.path != "/", (try? fm.attributesOfItem(atPath: existing.path)) == nil {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let base = realpath(existing.path, &buffer) != nil ? String(cString: buffer) : existing.path
        var out = URL(fileURLWithPath: base)
        for component in rest { out.appendPathComponent(component) }
        // NOT standardized again: `standardizedFileURL` strips `/private`
        // from a path that exists and keeps it on one that does not, which
        // is the inconsistency this function exists to remove.
        return out
    }

    /// `a` is `b` or below it, for two paths already in `canonical` form.
    static func within(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        canonical(a).path == canonical(b).path
    }

    /// `a` is `b` or below it.
    static func isInside(_ a: URL, _ b: URL) -> Bool {
        within(canonical(a).path, canonical(b).path)
    }

    static func isStrictlyInside(_ a: URL, _ b: URL) -> Bool {
        isInside(a, b) && !samePath(a, b)
    }

    /// Exists as anything — a file, a folder, or a link (even a dangling one).
    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func linkDestination(_ url: URL) -> URL? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let absolute = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
            : url.deletingLastPathComponent().appendingPathComponent(dest)
        return Self.canonical(absolute)
    }

    /// `~/.local/bin/hermes` is uv's console script copied out of the venv
    /// (scripts/install-hermes.sh): its shebang names the venv's python. It is
    /// Moe's only when that python is inside the Hermes home being erased.
    private func isOurChromeHost(_ url: URL, in hermes: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let data = FileManager.default.contents(atPath: url.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["name"] as? String == MacEraseChromeHost.name,
              let launcher = obj["path"] as? String, launcher.hasPrefix("/") else { return false }
        return Self.isStrictlyInside(Self.canonical(URL(fileURLWithPath: launcher)), Self.canonical(hermes))
    }

    private func isHermesWrapper(_ url: URL, in hermes: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 512), as: UTF8.self)
        guard head.hasPrefix("#!"), let first = head.split(separator: "\n").first else { return false }
        let interpreter = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        guard interpreter.hasPrefix("/") else { return false }
        let python = Self.canonical(URL(fileURLWithPath: interpreter))
        return Self.isStrictlyInside(python, Self.canonical(hermes))
    }

    // MARK: CuaDriver's guard

    /// Why `url` may not be removed as CuaDriver, or nil. Checked when the
    /// plan is made and again immediately before removal. Each rule refuses:
    ///
    ///   * Moe only. Moe Dev shares CuaDriver with Moe and never removes it;
    ///   * exactly `<Applications>/CuaDriver.app`, for an Applications folder
    ///     that is `/Applications` or inside `~` — never a similar name, never
    ///     one in a subfolder;
    ///   * the app, its Contents and its Info.plist are really there, not
    ///     links: a link is judged by where it sits and is never followed;
    ///   * its Info.plist says `com.trycua.driver`. Missing, unreadable, or
    ///     anything else is not CuaDriver;
    ///   * and its code signature says so too — identifier `com.trycua.driver`,
    ///     team one of `MacEraseCuaDriver.teamIDs`. An Info.plist is a text
    ///     file anyone can write; the signature is not.
    public func cuaDriverRefusal(_ url: URL) -> String? {
        guard scope.identity.ownsSharedResources else {
            return "CuaDriver is shared with Moe, and Moe Dev never removes it"
        }
        guard let expected = cuaDriverAppURL, let apps = scope.applicationsDir else {
            return "this erase was not told where Applications is"
        }
        guard url.standardizedFileURL.path == expected.standardizedFileURL.path else {
            return "\(url.path) is not \(expected.path)"
        }
        guard MacEraseScope.acceptableApplications(apps, userHome: scope.userHome) else {
            return "\(apps.path) is neither /Applications nor inside \(scope.userHome.path)"
        }
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        for (u, want) in [(url, S_IFDIR), (contents, S_IFDIR), (plist, S_IFREG)] {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { return "\(u.path) is not there" }
            let type = st.st_mode & S_IFMT
            if type == S_IFLNK { return "\(u.path) is a link, and CuaDriver is removed only where it really is" }
            guard type == want else { return "\(u.path) is not a \(want == S_IFDIR ? "folder" : "file")" }
        }
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any] else {
            return "its Info.plist cannot be read, so it cannot be shown to be CuaDriver"
        }
        let id = info["CFBundleIdentifier"] as? String ?? "none"
        guard id == MacEraseCuaDriver.bundleID else {
            return "its bundle identifier is \(id), not \(MacEraseCuaDriver.bundleID)"
        }
        guard let signer = signature.signer(of: url) else {
            return "its code signature cannot be read, so it cannot be shown to be CuaDriver"
        }
        guard signer.identifier == MacEraseCuaDriver.bundleID else {
            return "it is signed as \(signer.identifier), not \(MacEraseCuaDriver.bundleID)"
        }
        guard MacEraseCuaDriver.teamIDs.contains(signer.team) else {
            return "it is signed by team \(signer.team), not one of trycua's "
                + "(\(MacEraseCuaDriver.teamIDs.sorted().joined(separator: ", ")))"
        }
        return nil
    }

    /// The app, when it is there and passes the guard; otherwise nil.
    func verifiedCuaDriverApp() -> URL? {
        guard let app = cuaDriverAppURL, exists(app), cuaDriverRefusal(app) == nil else { return nil }
        return app
    }

    // MARK: Planning

    /// Exactly what `run` would remove, and nothing it would not. Reads the
    /// disk, asks the keychain whether each allowlisted entry exists
    /// (metadata only, no secret is read) and asks launchctl which labels are
    /// loaded. Deletes nothing. The UI's second warning shows this.
    public func plan() -> MacErasePlan {
        var remove: [MacEraseItem] = []
        var left: [String] = [
            "The Memoe app itself. It opens again at the welcome screen, like a new install.",
            "Claude Code and ChatGPT: their sign-ins (~/.claude, ~/.codex and Claude Code's keychain item) and the claude command (~/.local/bin/claude). Those belong to them.",
            "uv and the Python it downloaded (~/.local/share/uv), and Node in ~/.local/bin, which other programs may use.",
        ]
        let id = scope.identity.bundleID

        func add(_ url: URL, _ why: String) {
            guard exists(url) else { return }
            if let refused = refusal(for: url) {
                // Said, never silent: a home the guard will not let go of is
                // an erase that did not happen, and the person must know.
                left.append("Not removed: \(url.path) — \(refused).")
                return
            }
            remove.append(.path(url, why: why))
        }

        // Processes running from what is being erased: stopped before
        // anything is removed, so nothing writes into a home as it goes.
        if let processes {
            let (stop, shells) = processesToStop(processes.list())
            for p in stop { remove.append(.process(pid: p.pid, command: p.executable)) }
            for p in shells {
                left.append("A shell (\(p.executable), pid \(p.pid)) open inside what is being erased. Close it first.")
            }
        }

        // Background jobs next — a job firing mid-erase would write the home again.
        for label in scope.identity.launchdLabels {
            let plist = launchAgent(label)
            let hasPlist = exists(plist) && refusal(for: plist) == nil
            let loaded = commands.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]) == 0
            if hasPlist || loaded {
                remove.append(.launchd(label: label, plist: hasPlist ? plist : nil, loaded: loaded))
            }
        }
        // …and the login item, which is not a launchd label: left registered,
        // System Settings › Login Items keeps listing Moe, and the next login
        // opens the app the person just erased.
        if let loginItem, loginItem.isRegistered() {
            remove.append(.loginItem(bundleID: id))
        }

        if let keychain {
            for entry in MacEraseKeychain.entries(for: scope.identity) where keychain.present(entry) {
                remove.append(.keychain(entry))
            }
            if !scope.identity.ownsSharedResources {
                left.append("Moe's keychain items: their names are shared with Moe, and Moe Dev removes only its own key for agreeing.")
            }
        } else if !scope.identity.ownsSharedResources {
            left.append("Keychain items: their names are shared with Moe, and Moe Dev never touches Moe's.")
        }

        // ~/.moe: a link to THIS home goes first; anything else stays.
        if let dest = linkDestination(legacyLink) {
            let home = Self.canonical(scope.moeHome)
            if Self.samePath(dest, home), refusal(for: legacyLink) == nil {
                remove.append(.legacyLink(legacyLink, to: home))
            } else {
                left.append("~/.moe, which points at \(dest.path), not at the home being erased.")
            }
        } else if exists(legacyLink) {
            left.append("~/.moe, which is a real folder rather than Moe's link — look through it yourself.")
        }

        add(scope.moeHome, "Moe's home: memories, conversations, notes, meetings, connectors, logs, models")

        if let hermes = scope.hermesHome {
            add(hermes, "Moe's Hermes: its settings, channel sessions (Telegram, WhatsApp), skills and jobs")
            for name in ["hermes", "hermes-acp"] {
                let wrapper = scope.userHome.appendingPathComponent(".local/bin/\(name)")
                if isHermesWrapper(wrapper, in: hermes) { add(wrapper, "the hermes command, which ran Moe's Hermes") }
            }
            // Moe in your Chrome: the native-messaging host manifest Hermes's
            // install-host wrote beside Chrome's profiles. Its launcher lives in
            // ~/.hermes/chrome-bridge, removed with the Hermes home above; the
            // manifest would otherwise point Chrome at a file that is gone.
            // Only ours — one whose launcher is inside this Hermes home.
            let host = scope.userHome.appendingPathComponent(MacEraseChromeHost.manifest)
            if isOurChromeHost(host, in: hermes) { add(host, "the Memoe extension's link from Chrome to Moe") }
        } else {
            left.append("~/.hermes: it is shared with Moe, and Moe Dev never touches Moe's.")
        }

        // CuaDriver: Moe's to remove, Moe Dev's to leave. Its permissions go
        // first, while the app is still there (tccutil finds an app by its
        // bundle id), then the link into it, then the app, then its data.
        if scope.identity.ownsSharedResources {
            if let app = cuaDriverAppURL, exists(app) {
                if let why = cuaDriverRefusal(app) {
                    left.append("Not removed: \(app.path) — \(why).")
                } else {
                    remove.append(.tcc(bundleID: MacEraseCuaDriver.bundleID))
                    let link = scope.userHome.appendingPathComponent(MacEraseCuaDriver.commandLink)
                    let appReal = Self.canonical(app)
                    if let dest = linkDestination(link), Self.isStrictlyInside(dest, appReal),
                       refusal(for: link) == nil {
                        remove.append(.cuaDriverLink(link, to: appReal))
                    } else if exists(link) {
                        left.append("~/.local/bin/cua-driver, which is not a link into \(app.path).")
                    }
                    remove.append(.cuaDriverApp(app))
                }
            }
            // CuaDriver's data under ~ is removed even when the app is absent
            // or refused: those folders are named for CuaDriver, which Moe put
            // here, and a refused app is still told to the person in `left`.
            for url in cuaDriverData { add(url, "CuaDriver's data") }
            let cuaPrefs = scope.userHome.appendingPathComponent(MacEraseCuaDriver.preferences)
            if exists(cuaPrefs), refusal(for: cuaPrefs) == nil {
                remove.append(.defaults(domain: MacEraseCuaDriver.bundleID))
                remove.append(.path(cuaPrefs, why: "CuaDriver's preferences"))
            }
        } else {
            left.append("CuaDriver, the tool Moe uses to work your screen: it is shared with Moe, and Moe Dev never removes it.")
        }

        if scope.identity.ownsSharedResources {
            for root in fluidAudioRoots { add(root, "downloaded voice and speech models") }
        } else {
            left.append("Downloaded voice models in FluidAudio's folders: shared with Moe.")
        }

        add(library.appendingPathComponent("Application Support/\(id)", isDirectory: true), "app support")
        add(library.appendingPathComponent("Caches/\(id)", isDirectory: true), "caches")
        add(library.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true), "web storage")
        add(library.appendingPathComponent("HTTPStorages/\(id).binarycookies"), "web cookies")
        add(library.appendingPathComponent("WebKit/\(id)", isDirectory: true), "web storage")
        add(library.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true),
            "window state")
        let prefs = library.appendingPathComponent("Preferences/\(id).plist")
        if exists(prefs), refusal(for: prefs) == nil {
            remove.append(.defaults(domain: id))
            remove.append(.path(prefs, why: "preferences"))
        }
        remove.append(.tcc(bundleID: id))
        return MacErasePlan(scope: scope, remove: remove, left: left)
    }

    // MARK: Running

    /// Carry out `plan`, item by item, re-checking every path against the
    /// guard at the moment of deletion. Never throws partway: each item gets
    /// an outcome, so a person can be told exactly what did not go.
    public func run(_ plan: MacErasePlan) -> MacEraseReport {
        precondition(plan.scope == scope, "a plan made for another scope")
        var outcomes = stopProcesses(plan.remove.compactMap { item -> (Int32, String)? in
            if case .process(let pid, let command) = item { return (pid, command) }
            return nil
        })
        for item in plan.remove {
            if case .process = item { continue }
            outcomes.append((item, perform(item)))
        }
        return MacEraseReport(outcomes: outcomes)
    }

    /// Plan, run, relaunch. What `Moe --erase-mac` does once the app has quit.
    @discardableResult
    public func eraseAndRelaunch() -> MacEraseReport {
        let report = run(plan())
        // Before the relaunch, which reads it. The report goes nowhere else a
        // person could see: the app has quit, and the log lived in the home
        // this just removed.
        leaveNote(for: report)
        relaunch()
        return report
    }

    // MARK: Processes

    /// Executables that are a person's own shell or terminal: never stopped,
    /// only named, even with a working directory inside what is erased.
    static let interactive: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash",
                                           "login", "tmux", "screen", "Terminal", "iTerm2"]

    /// Which processes run from what this erase removes, matched by what they
    /// ARE — executable, working directory, `HERMES_HOME`/`MOE_HOME`, or a path
    /// argument inside Moe's home or its Hermes home — and never by name. Only
    /// this user's, never pid ≤ 1, never this process. Moe Dev has no Hermes
    /// home of its own, so a Moe Dev erase never stops the shared gateway.
    /// Returns (to stop, shells to name and leave).
    public func processesToStop(_ all: [MacEraseProcess]) -> (stop: [MacEraseProcess], shells: [MacEraseProcess]) {
        var roots = [Self.canonical(scope.moeHome).path]
        if let hermes = scope.hermesHome { roots.append(Self.canonical(hermes).path) }
        func under(_ path: String?) -> Bool {
            guard let path, path.hasPrefix("/") else { return false }
            let c = Self.canonical(URL(fileURLWithPath: path)).path
            return roots.contains { Self.within(c, $0) }
        }
        // CuaDriver's own binary, by where it is — never by its name, which
        // anyone's program may share — and only while the app passes the
        // guard, so Moe Dev, or a bundle that is not CuaDriver, stops nothing.
        let cuaRoot = verifiedCuaDriverApp().map { Self.canonical($0).path }
        func runsFromCuaDriver(_ exe: String) -> Bool {
            guard let cuaRoot, exe.hasPrefix("/") else { return false }
            return Self.within(Self.canonical(URL(fileURLWithPath: exe)).path, cuaRoot)
        }
        var stop: [MacEraseProcess] = [], shells: [MacEraseProcess] = []
        for p in all where p.uid == uid && p.pid > 1 && p.pid != selfPID {
            let byWhatItIs = under(p.executable) || under(p.environment["HERMES_HOME"])
                || under(p.environment["MOE_HOME"]) || p.arguments.dropFirst().contains(where: under)
                || runsFromCuaDriver(p.executable)
            let byWhereItIs = under(p.cwd)
            guard byWhatItIs || byWhereItIs else { continue }
            let name = (p.executable as NSString).lastPathComponent
            if !byWhatItIs, Self.interactive.contains(name) { shells.append(p) } else { stop.append(p) }
        }
        return (stop, shells)
    }

    /// SIGTERM each target that still matches (a pid seen at plan time may
    /// have gone, or been reused), wait up to `stopWait`, SIGKILL what is left.
    func stopProcesses(_ targets: [(Int32, String)]) -> [(MacEraseItem, MacEraseOutcome)] {
        guard !targets.isEmpty else { return [] }
        guard let processes else {
            return targets.map { (.process(pid: $0.0, command: $0.1), .refused("no process table")) }
        }
        let now = Dictionary(processesToStop(processes.list()).stop.map { ($0.pid, $0) },
                             uniquingKeysWith: { a, _ in a })
        var out: [(MacEraseItem, MacEraseOutcome)] = []
        var signalled: [(Int32, String)] = []
        for (pid, command) in targets {
            guard let p = now[pid], p.executable == command else {
                out.append((.process(pid: pid, command: command), .absent))
                continue
            }
            _ = processes.signal(pid, SIGTERM)
            signalled.append((pid, command))
        }
        let deadline = Date().addingTimeInterval(stopWait)
        while Date() < deadline, signalled.contains(where: { processes.alive($0.0) }) { usleep(100_000) }
        for (pid, command) in signalled {
            guard processes.alive(pid) else {
                out.append((.process(pid: pid, command: command), .removed("stopped")))
                continue
            }
            // Look again before SIGKILL: a process that exited during the wait
            // may have handed its pid to another program. Only this user's
            // process with the same executable is killed.
            guard processes.list().first(where: { $0.pid == pid })?.executable == command else {
                out.append((.process(pid: pid, command: command),
                            .removed("stopped; pid \(pid) now belongs to another program, which was left alone")))
                continue
            }
            _ = processes.signal(pid, SIGKILL)
            usleep(200_000)
            out.append((.process(pid: pid, command: command),
                        processes.alive(pid) ? .failed("still running after SIGKILL") : .removed("stopped")))
        }
        return out
    }

    private func removePath(_ url: URL) -> MacEraseOutcome {
        if let why = refusal(for: url) { return .refused(why) }
        guard exists(url) else { return .absent }
        do {
            try files.removeItem(at: url)
            return .removed("")
        } catch {
            return Self.outcome(ofRemovalError: error)
        }
    }

    private func perform(_ item: MacEraseItem) -> MacEraseOutcome {
        switch item {
        case .path(let url, _):
            return removePath(url)

        case .legacyLink(let url, let to):
            // Re-read the link: it must still point at the home being erased.
            guard let dest = linkDestination(url) else { return exists(url) ? .refused("~/.moe is no longer a link") : .absent }
            guard Self.samePath(dest, to) else { return .refused("~/.moe now points at \(dest.path)") }
            return removePath(url)

        case .cuaDriverApp(let url):
            // The guard again, now: still Moe, still exactly that path, still
            // a real folder, still com.trycua.driver.
            guard exists(url) else { return .absent }
            if let why = cuaDriverRefusal(url) { return .refused(why) }
            do {
                try files.removeItem(at: url)
                return .removed("")
            } catch {
                // Never swallowed: a CuaDriver that stays is named in the
                // note the next launch shows (MacEraseNote).
                return Self.outcome(ofRemovalError: error)
            }

        case .cuaDriverLink(let url, let to):
            // Re-read: still a link, still into the app, and that app still CuaDriver.
            guard let dest = linkDestination(url) else { return exists(url) ? .refused("no longer a link") : .absent }
            guard let app = verifiedCuaDriverApp(), Self.samePath(Self.canonical(app), to),
                  Self.isStrictlyInside(dest, to) else {
                return .refused("\(url.path) no longer points into CuaDriver")
            }
            return removePath(url)

        case .keychain(let entry):
            guard MacEraseKeychain.entries(for: scope.identity).contains(entry) else {
                return .refused("not on this identity's allowlist")
            }
            guard let keychain else { return .refused("no keychain for this scope") }
            switch keychain.deleteAll(entry) {
            case .success(let n): return n == 0 ? .absent : .removed("\(n) item\(n == 1 ? "" : "s")")
            case .failure(let e): return .failed(e.description)
            }

        case .launchd(let label, let plist, let loaded):
            guard scope.identity.launchdLabels.contains(label) else { return .refused("not one of this identity's labels") }
            var detail: [String] = []
            if loaded {
                let rc = commands.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                detail.append(rc == 0 ? "booted out" : "bootout exited \(rc)")
            }
            if let plist {
                switch removePath(plist) {
                case .removed: detail.append("plist removed")
                case .absent: break
                case .refused(let why): return .refused(why)
                case .failed(let why): return .failed(why)
                case .notAllowed(let why): return .notAllowed(why)
                }
            }
            return .removed(detail.joined(separator: ", "))

        case .loginItem(let bundleID):
            guard bundleID == scope.identity.bundleID else { return .refused("not this identity's login item") }
            guard let loginItem else { return .refused("no login item for this scope") }
            guard loginItem.isRegistered() else { return .absent }
            if let why = loginItem.unregister() { return .failed(why) }
            return .removed("")

        case .defaults(let domain):
            let cuaDriver = domain == MacEraseCuaDriver.bundleID && scope.identity.ownsSharedResources
            guard domain == scope.identity.bundleID || cuaDriver else { return .refused("not this identity's domain") }
            let rc = commands.run("/usr/bin/defaults", ["delete", domain])
            return rc == 0 ? .removed("") : .absent

        case .process:
            return .refused("processes are stopped by stopProcesses, before everything else")

        case .tcc(let bundleID):
            // CuaDriver's permissions: Moe only, and only while the app is
            // there and is CuaDriver — tccutil finds it by its bundle id.
            let cuaDriver = bundleID == MacEraseCuaDriver.bundleID && verifiedCuaDriverApp() != nil
            guard bundleID == scope.identity.bundleID || cuaDriver else { return .refused("not this identity") }
            let rc = commands.run("/usr/bin/tccutil", ["reset", "All", bundleID])
            return rc == 0 ? .removed("") : .failed("tccutil exited \(rc)")
        }
    }
}

// MARK: - What the person is told afterwards

/// What an erase leaves for the Moe that opens after it, in the fresh home:
/// every target that did not go, in words a person can act on, and whether
/// CuaDriver went. `eraseAndRelaunch` writes it before the relaunch; that
/// launch reads it (`take`) and shows the leftovers once.
///
/// Why, measured on the owner's Mac on 2026-09-11. The erase's report went
/// to NSLog from a child whose stderr was /dev/null, after the app had quit,
/// so a target that failed would have failed where nobody could see it. And
/// CuaDriver, which the erase DID remove (LaunchServices unregistered
/// com.trycua.driver at 13:15:34; no System Policy denial anywhere), was back
/// a minute later: the relaunched Moe's configure-hermes.py found no driver
/// and started `hermes computer-use install` in the background (~/.cua-driver
/// born 13:16:25, the new bundle's inode allocated after it, ctime 13:16:29;
/// its 04:55 mtime came out of the archive). `cuaDriverRemoved` stops that:
/// while it is set and onboarding has not been finished again, the launch
/// passes `skipDriverEnv` to configure-hermes.py.
public struct MacEraseNote: Codable, Equatable, Sendable {
    public struct Leftover: Codable, Equatable, Sendable {
        public let kind: String
        public let target: String
        /// One line, without the "One thing Moe couldn't remove:" in front.
        public let sentence: String
        /// A path to show in Finder, when one still exists.
        public let reveal: String?
    }

    public static let fileName = ".erase-note.json"
    /// configure-hermes.py's `SKIP_DRIVER_ENV`, spelled the same on purpose;
    /// MacEraseNoteTests reads the script and fails if the two drift apart.
    public static let skipDriverEnv = "MOE_SKIP_DRIVER_INSTALL"

    public let erasedAt: String
    public let identity: String
    public let cuaDriverRemoved: Bool
    public let leftovers: [Leftover]
    /// The whole report, for whoever looks later. Not shown to the person.
    public let report: String

    public static func url(in moeHome: URL) -> URL { moeHome.appendingPathComponent(fileName) }

    /// Nil when there is nothing to say: everything went, and CuaDriver was
    /// not among it. Every failure in the report becomes a leftover — the
    /// count is the same, so nothing that failed can go unmentioned.
    public static func from(_ report: MacEraseReport, scope: MacEraseScope, now: Date = Date()) -> MacEraseNote? {
        let leftovers = report.failures.map { leftover($0.0, $0.1, userHome: scope.userHome) }
        let cuaDriverRemoved = report.outcomes.contains { item, outcome in
            if case .cuaDriverApp = item, case .removed = outcome { return true }
            return false
        }
        guard cuaDriverRemoved || !leftovers.isEmpty else { return nil }
        return MacEraseNote(erasedAt: ISO8601DateFormatter().string(from: now),
                            identity: scope.identity.bundleID, cuaDriverRemoved: cuaDriverRemoved,
                            leftovers: leftovers, report: report.text)
    }

    static func leftover(_ item: MacEraseItem, _ outcome: MacEraseOutcome, userHome: URL) -> Leftover {
        let detail: String
        switch outcome {
        case .notAllowed(let d), .failed(let d), .refused(let d): detail = d
        case .removed, .absent: detail = "it went"   // only failures are handed in
        }
        func tilde(_ path: String) -> String {
            let home = userHome.standardizedFileURL.path
            return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
        }
        func existing(_ url: URL) -> String? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil ? url.path : nil
        }
        func removal(_ what: String, _ reveal: String?) -> String {
            switch outcome {
            case .notAllowed: return "\(what) — macOS only lets you do that. Drag it to the Bin."
            case .refused: return "\(what) — Moe left it, because \(detail)."
            default: return "\(what) (\(detail))." + (reveal != nil ? " Drag it to the Bin." : "")
            }
        }
        let sentence: String
        var reveal: String?
        switch item {
        case .cuaDriverApp(let url):
            reveal = existing(url)
            sentence = removal("CuaDriver, in your Applications folder", reveal)
        case .path(let url, _), .legacyLink(let url, _), .cuaDriverLink(let url, _):
            reveal = existing(url)
            sentence = removal(tilde(url.path), reveal)
        case .keychain(let e):
            sentence = "the keychain item \(e.service) (\(detail))."
        case .launchd(let label, let plist, _):
            reveal = plist.flatMap(existing)
            sentence = "the background job \(label) (\(detail))."
        case .defaults(let domain):
            sentence = "the preferences \(domain) (\(detail))."
        case .loginItem:
            sentence = "Memoe in System Settings › General › Login Items (\(detail)). Remove it there."
        case .tcc(let id):
            sentence = "the permissions given to \(id) (\(detail))."
        case .process(_, let command):
            sentence = "\((command as NSString).lastPathComponent), still running from what was erased (\(detail))."
        }
        return Leftover(kind: item.kind, target: item.target, sentence: sentence, reveal: reveal)
    }

    /// The note as a person reads it. Empty when nothing was left.
    public var text: String {
        switch leftovers.count {
        case 0: return ""
        case 1: return "One thing Moe couldn't remove: " + leftovers[0].sentence
        default:
            return "\(leftovers.count) things Moe couldn't remove:\n"
                + leftovers.map { "• " + $0.sentence }.joined(separator: "\n")
        }
    }

    /// What Show in Finder selects.
    public var reveal: [URL] { leftovers.compactMap(\.reveal).map { URL(fileURLWithPath: $0) } }

    public static func read(from moeHome: URL) -> MacEraseNote? {
        guard let data = try? Data(contentsOf: url(in: moeHome)) else { return nil }
        return try? JSONDecoder().decode(MacEraseNote.self, from: data)
    }

    /// The note as it was, for showing once. What stays on disk is only what
    /// a later launch still needs: the leftovers are shown once, and the
    /// CuaDriver hold lasts until onboarding is done — then the file goes.
    @discardableResult
    public static func take(from moeHome: URL, onboarded: Bool) -> MacEraseNote? {
        let file = url(in: moeHome)
        guard let note = read(from: moeHome) else {
            try? FileManager.default.removeItem(at: file)   // unreadable: it cannot hold anything
            return nil
        }
        if note.cuaDriverRemoved && !onboarded {
            let kept = MacEraseNote(erasedAt: note.erasedAt, identity: note.identity, cuaDriverRemoved: true,
                                    leftovers: [], report: note.report)
            if kept != note, let data = try? JSONEncoder().encode(kept) { try? data.write(to: file, options: .atomic) }
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        return note
    }

    /// Whether Moe's launch must hold off installing CuaDriver: the erase
    /// removed it, and the person has not been through setup again. Once they
    /// have, Moe installs its screen tool the way any new install does.
    public static func holdsDriverInstall(_ note: MacEraseNote?, onboarded: Bool) -> Bool {
        (note?.cuaDriverRemoved ?? false) && !onboarded
    }
}

extension MacErase {
    /// A removal that threw, as an outcome — never `.removed`. Permission is
    /// `.notAllowed`: the kernel's EPERM or EACCES, bare or under Foundation's
    /// NSFileWriteNoPermissionError. That shape was measured on 2026-09-11 by
    /// `FileManager.removeItem` on a folder holding a `chflags uchg` file:
    /// NSCocoaErrorDomain 513 over NSPOSIXErrorDomain 1. Anything else is
    /// `.failed`.
    public static func outcome(ofRemovalError error: Error) -> MacEraseOutcome {
        let e = error as NSError
        let permission: Set<Int> = [Int(EPERM), Int(EACCES)]
        let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError
        let notAllowed = (e.domain == NSPOSIXErrorDomain && permission.contains(e.code))
            || (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteNoPermissionError)
            || (underlying?.domain == NSPOSIXErrorDomain && permission.contains(underlying?.code ?? 0))
        return notAllowed ? .notAllowed(e.localizedDescription) : .failed(e.localizedDescription)
    }

    /// Write `MacEraseNote` into the fresh home for the launch that follows:
    /// only into this scope's own home, only where the guard lets this erase
    /// act, and never through a link. Nothing to say, nothing written — the
    /// home stays absent and the next launch is a plain first run.
    @discardableResult
    func leaveNote(for report: MacEraseReport, now: Date = Date()) -> URL? {
        guard let note = MacEraseNote.from(report, scope: scope, now: now) else { return nil }
        let home = scope.moeHome
        guard refusal(for: home) == nil else { return nil }
        var st = stat()
        if lstat(home.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR else { return nil }   // a link or a file is not a home
        } else {
            guard (try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)) != nil
            else { return nil }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = MacEraseNote.url(in: home)
        guard let data = try? encoder.encode(note), (try? data.write(to: file, options: .atomic)) != nil
        else { return nil }
        return file
    }
}

// MARK: - The real adapters

/// Generic-password items through `/usr/bin/security` — the same tool every
/// other keychain call in Moe uses (ComposioKeychain, HermesSupervisor), so
/// items it created are deletable without an access prompt.
///
/// Only `find-generic-password` (without `-w`: the secret is never read) and
/// `delete-generic-password`, always with an explicit `-s`, and with `-a`
/// whenever the entry names an account. With `keychainFile` set, that file is
/// passed as the last argument on every call and the search list is never
/// consulted — the tests' throwaway keychain.
public struct SecurityToolKeychain: MacEraseKeychainAccess {
    public let bin: String
    public let keychainFile: URL?
    /// `security` exits 44 (errSecItemNotFound) when nothing matches.
    static let notFound: Int32 = 44
    /// A service with more than this many items is not one Moe made.
    static let cap = 64

    public init(bin: String = "/usr/bin/security", keychainFile: URL?) {
        self.bin = bin
        self.keychainFile = keychainFile
    }

    func arguments(_ verb: String, _ entry: MacEraseKeychainEntry) -> [String] {
        precondition(!entry.service.isEmpty, "a keychain call with no service would match everything")
        var args = [verb, "-s", entry.service]
        if let account = entry.account { args += ["-a", account] }
        if let keychainFile { args.append(keychainFile.path) }
        return args
    }

    public func present(_ entry: MacEraseKeychainEntry) -> Bool {
        ProcessCommands.status(bin, arguments("find-generic-password", entry)) == 0
    }

    public func deleteAll(_ entry: MacEraseKeychainEntry) -> Result<Int, MacEraseScopeError> {
        var deleted = 0
        while deleted <= Self.cap {
            let rc = ProcessCommands.status(bin, arguments("delete-generic-password", entry))
            if rc == Self.notFound { return .success(deleted) }
            guard rc == 0 else { return .failure(.init("security exited \(rc) after \(deleted) deleted")) }
            deleted += 1
        }
        return .failure(.init("more than \(Self.cap) items under \(entry.service); stopped"))
    }
}

public struct ProcessCommands: MacEraseCommands {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) -> Int32 {
        Self.status(executable, arguments)
    }

    static func status(_ executable: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// A scratch run's stand-in for launchctl, tccutil and defaults: each call is
/// written to `file` (one line, tab-separated) and nothing is executed.
/// `launchctl print` answers 1 — "no such job" — so a scratch plan is driven
/// by the plists on disk alone; every other call answers 0, "done", so the
/// report of a scratch run reads like the real one would.
public final class RecordingCommands: MacEraseCommands {
    public let file: URL?
    public private(set) var calls: [[String]] = []

    public init(file: URL?) { self.file = file }

    public func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let call = [executable] + arguments
        calls.append(call)
        if let file {
            let line = call.joined(separator: "\t") + "\n"
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
        return executable.hasSuffix("launchctl") && arguments.first == "print" ? 1 : 0
    }
}


// MARK: - Processes

public struct MacEraseProcess: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let executable: String
    public let cwd: String?
    public let arguments: [String]
    public let environment: [String: String]

    public init(pid: Int32, uid: UInt32, executable: String, cwd: String?,
                arguments: [String] = [], environment: [String: String] = [:]) {
        self.pid = pid
        self.uid = uid
        self.executable = executable
        self.cwd = cwd
        self.arguments = arguments
        self.environment = environment
    }
}

public protocol MacEraseProcessTable {
    /// This user's processes. Another user's are never listed or signalled.
    func list() -> [MacEraseProcess]
    func signal(_ pid: Int32, _ signal: Int32) -> Bool
    func alive(_ pid: Int32) -> Bool
}

/// The real table, from libproc and `KERN_PROCARGS2`. Reads only this
/// user's processes (the kernel refuses another user's arguments anyway).
public struct DarwinProcessTable: MacEraseProcessTable {
    public init() {}

    public func list() -> [MacEraseProcess] {
        let me = getuid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var out: [MacEraseProcess] = []
        for pid in pids.prefix(min(Int(got), pids.count)) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let (arguments, environment) = Self.arguments(of: pid)
            out.append(MacEraseProcess(pid: pid, uid: info.pbi_uid, executable: String(cString: pathBuffer),
                                       cwd: Self.cwd(of: pid), arguments: arguments, environment: environment))
        }
        return out
    }

    public func signal(_ pid: Int32, _ signal: Int32) -> Bool {
        pid > 1 && kill(pid, signal) == 0
    }

    public func alive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// `KERN_PROCARGS2`: argc, the exec path, padding, argv, then environ.
    static func arguments(of pid: Int32) -> ([String], [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return ([], [:]) }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }          // the exec path
        while i < size, buffer[i] == 0 { i += 1 }          // padding
        var strings: [String] = []
        while i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            if i == start { break }                          // an empty string ends environ
            strings.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        let args = Array(strings.prefix(argc))
        var env: [String: String] = [:]
        for entry in strings.dropFirst(argc) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (args, env)
    }
}

// MARK: - The request that starts an erase

/// What the app hands `Moe --erase-mac` through the helper's stdin pipe —
/// never a file, never an argument. The helper accepts it only if its
/// PARENT is the app that wrote it: the pid in the request is the helper's
/// parent, neither is launchd or the kernel, and the parent's code satisfies
/// the app's own designated requirement (checked in Sources/Moe/MacErase.swift
/// with the Security framework; its answer arrives here as `parentIsThisApp`).
/// A shell, an agent or a script that runs the binary is the parent in that
/// case, and fails the signature check.
public struct MacEraseRequest: Codable, Equatable, Sendable {
    public let nonce: String
    public let bundleID: String
    public let moeHome: String
    public let pid: Int32

    public init(nonce: String, bundleID: String, moeHome: String, pid: Int32) {
        self.nonce = nonce
        self.bundleID = bundleID
        self.moeHome = moeHome
        self.pid = pid
    }

    /// Why this request must be refused, or nil. Pure: every fact about the
    /// process is handed in, so each rule is a unit test.
    public static func refusal(_ r: MacEraseRequest, scope: MacEraseScope, parentPID: Int32,
                               stdinIsPipe: Bool, parentIsThisApp: Bool) -> String? {
        guard stdinIsPipe else { return "the request did not come through a pipe from the app" }
        guard r.pid > 1, parentPID > 1 else { return "no parent to answer to (pid \(r.pid), parent \(parentPID))" }
        guard r.pid == parentPID else { return "the request names pid \(r.pid), but the parent is \(parentPID)" }
        guard r.nonce.count == 64, r.nonce.allSatisfy(\.isHexDigit) else { return "the request carries no nonce" }
        guard parentIsThisApp else { return "the process that started this is not Moe" }
        guard r.bundleID == scope.identity.bundleID else { return "the request is for \(r.bundleID)" }
        guard MacErase.canonical(URL(fileURLWithPath: r.moeHome, isDirectory: true)).path
                == MacErase.canonical(scope.moeHome).path else {
            return "the request is for a home at \(r.moeHome)"
        }
        return nil
    }
}
