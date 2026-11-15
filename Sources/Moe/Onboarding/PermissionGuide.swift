import AppKit
import MoeBrain
import MoeDesign
import SwiftUI

// Everything Moe knows how to say about a macOS permission, written once.
//
// PRODUCT.md §8.4 binds this file: ask for one permission at a time, always
// with a stated reason, deep-link to the exact pane, and never block on a
// missing one. That only holds together if the reason is written in one
// place and reused — otherwise onboarding, Settings › Permissions and a
// Connections row waiting on a grant each invent their own words, and two of
// the three are wrong.
//
// Every entry answers the four questions a person actually has, and none may
// be left empty (scripts/test-connections-ui.sh checks all four):
//
//   what        — what Moe does with it, in human words
//   ifDeclined  — what happens if they say no. Always: Moe keeps working.
//   steps       — the exact click path, written out
//   settings    — the deep link that opens that exact pane
//
// plus `needsRelaunch`, because macOS reads some grants only at launch and a
// person who is not told that concludes the permission did not work. It is
// true only where that is so: a "Quit and reopen" button on a grant that
// already took effect teaches people to restart for nothing.

struct PermissionGuide: Identifiable, Sendable {
    let id: String
    /// What macOS itself calls it, so the words on screen match the words in
    /// the list the person is about to look at.
    let name: String
    /// One sentence: what Moe does with it.
    let what: String
    /// What happens if they say no.
    let ifDeclined: String
    /// The click path, spelled out, arrows and all.
    let steps: String
    /// The pane that opens.
    let settings: String
    /// True when macOS only notices the grant on the next launch.
    let needsRelaunch: Bool
    /// The fixable-failure codes this grant is the fix for
    /// (docs/FIXABLE-FAILURES.md; `FixCode`). Empty for a grant no tool
    /// reports missing yet.
    var codes: [FixCode] = []
    /// Whose row it is in System Settings: Memoe's, or CuaDriver's.
    var owner: FixOwner = .app
    /// How to tell, without asking, that the grant is on. `GrantWatch`
    /// polls it after the pane is opened (`GrantWatch.liveProbe`).
    var probe: GrantProbe

    var settingsURL: URL? { URL(string: settings) }

    /// The one line a locked feature shows next to its Fix button.
    var oneLine: String { what }

    private static let pane = "x-apple.systempreferences:com.apple.preference.security?"

    // MARK: - The permissions Moe can ask for

    static let microphone = PermissionGuide(
        id: "microphone",
        name: "Microphone",
        what: "Moe hears you while you hold the talk key, and stops listening the moment you let go.",
        ifDeclined: "Moe keeps working — it just can't hear you, so you type to it instead. You can switch the microphone on any time.",
        steps: "System Settings → Privacy & Security → Microphone → switch Memoe on.",
        settings: pane + "Privacy_Microphone",
        needsRelaunch: false,
        codes: [.tccMicrophone],
        probe: .microphoneAuthorization)

    static let speechRecognition = PermissionGuide(
        id: "speech-recognition",
        name: "Speech Recognition",
        what: "macOS asks for this at the same time as the microphone. Moe does its own listening, here on this Mac — your voice is not sent to a speech service.",
        ifDeclined: "Nothing changes. Moe doesn't use Apple's dictation, so hearing you works either way.",
        steps: "System Settings → Privacy & Security → Speech Recognition → switch Memoe on.",
        settings: pane + "Privacy_SpeechRecognition",
        needsRelaunch: false,
        codes: [],
        probe: .none)

    static let accessibility = PermissionGuide(
        id: "accessibility",
        name: "Accessibility",
        // The dictation halves only while it is offered (Features.dictation).
        what: Features.dictation
            ? "So Moe notices you holding the talk key while you're in another app, and can type what you dictate straight into whatever you're writing in."
            : "So Moe notices you holding the talk key while you're in another app.",
        ifDeclined: Features.dictation
            ? "Moe keeps working. Holding the key won't start it — click the little pill under the notch instead — and dictated text is copied to your clipboard for you to paste with Command-V."
            : "Moe keeps working. Holding the key won't start it — click the little pill under the notch instead.",
        steps: "System Settings → Privacy & Security → Accessibility → switch Memoe on. If Memoe isn't in the list, click +, then pick Memoe from your Applications folder. It works the moment the switch is on — nothing to restart.",
        settings: pane + "Privacy_Accessibility",
        // No relaunch: `AccessibilityWatch` sees the grant within two
        // seconds and arms the key there and then (`onGranted`). This said
        // true until 2026-11-12, from when the watcher was armed once at
        // launch, and Settings › Permissions went on offering "Quit and
        // reopen" for a grant that had already taken effect.
        needsRelaunch: false,
        codes: [],
        probe: .accessibilityTrusted)

    static let inputMonitoring = PermissionGuide(
        id: "input-monitoring",
        name: "Input Monitoring",
        what: "The same job as Accessibility — noticing your talk key while you're in another app. Some Macs ask here instead.",
        ifDeclined: "Moe keeps working, and on most Macs Accessibility alone is enough. If holding the key does nothing and Accessibility is already on, this is the other place to look.",
        steps: "System Settings → Privacy & Security → Input Monitoring → switch Memoe on, then quit Memoe and open it again.",
        settings: pane + "Privacy_ListenEvent",
        needsRelaunch: true,
        codes: [],
        probe: .inputMonitoringAccess)

    static let fullDiskAccess = PermissionGuide(
        id: "full-disk-access",
        name: "Full Disk Access",
        what: "So Moe can read the things macOS keeps locked away even from you: your Messages and SMS, your call history, your Chrome history, and the Google Drive folder on this Mac.",
        ifDeclined: "Moe keeps working, and everything else still works. Messages, call history, Chrome and Drive stay switched off, and Moe will say so rather than pretending it looked.",
        steps: "System Settings → Privacy & Security → Full Disk Access → switch Memoe on. If Memoe isn't in the list, click +, then pick Memoe from your Applications folder. Then quit Memoe and open it again — macOS only notices this one at startup.",
        settings: pane + "Privacy_AllFiles",
        needsRelaunch: true,
        codes: [.tccAppData, .tccFiles],
        probe: .readablePath(PermissionGuide.fullDiskAccessProbePath))

    static let automation = PermissionGuide(
        id: "automation",
        name: "Automation",
        what: "So Moe can ask Notes, Calendar and Messages for what's in them — and, when you ask it to drive the Mac, click and type on your behalf.",
        ifDeclined: "Moe keeps working. The apps you didn't allow simply aren't readable, and Moe tells you that instead of guessing.",
        steps: "System Settings → Privacy & Security → Automation → find Memoe in the list and switch on each app you want it to reach. macOS also asks you the first time, one app at a time — saying yes there is the same thing.",
        settings: pane + "Privacy_Automation",
        needsRelaunch: false,
        codes: [.tccAutomation],
        probe: .automationTarget)

    static let contacts = PermissionGuide(
        id: "contacts",
        name: "Contacts",
        what: Features.dictation
            ? "So Moe knows who you mean when you say a name, and spells the people you talk about correctly when you dictate."
            : "So Moe knows who you mean when you say a name.",
        ifDeclined: "Moe keeps working. It won't know your people's names, so it may spell them the way they sound.",
        steps: "System Settings → Privacy & Security → Contacts → switch Memoe on.",
        settings: pane + "Privacy_Contacts",
        needsRelaunch: false,
        codes: [.tccContacts],
        probe: .contactsAuthorization)

    static let calendar = PermissionGuide(
        id: "calendar",
        name: "Calendar",
        what: "So Moe knows what you have on today — every calendar in Calendar.app, including any Google calendars you added there — and can add events when you ask.",
        ifDeclined: "Moe keeps working. It won't know your schedule, and it will say so rather than guess.",
        steps: "System Settings → Privacy & Security → Calendars → switch Memoe on.",
        settings: pane + "Privacy_Calendars",
        needsRelaunch: false,
        codes: [.tccCalendar],
        probe: .calendarAuthorization)

    static let reminders = PermissionGuide(
        id: "reminders",
        name: "Reminders",
        what: "So Moe knows what you still owe people, and can add a reminder when you ask it to.",
        ifDeclined: "Moe keeps working. Your reminders stay private to Reminders.app.",
        steps: "System Settings → Privacy & Security → Reminders → switch Memoe on.",
        settings: pane + "Privacy_Reminders",
        needsRelaunch: false,
        codes: [.tccReminders],
        probe: .remindersAuthorization)

    static let screenRecording = PermissionGuide(
        id: "screen-recording",
        name: "Screen & System Audio Recording",
        what: "Two things: Moe can see your screen when you ask it \"what do I do here\", and it can record the other side of a call when you start a meeting.",
        ifDeclined: "Moe keeps working. It answers without looking at your screen, and a meeting records only what your microphone hears.",
        steps: "System Settings → Privacy & Security → Screen & System Audio Recording → switch Memoe on, then quit Memoe and open it again.",
        settings: pane + "Privacy_ScreenCapture",
        needsRelaunch: true,
        codes: [],
        probe: .screenCapturePreflight)

    /// Files & Folders: Desktop, Documents and Downloads each have their own
    /// switch, which is the narrowest grant that fixes a `tcc_files` failure
    /// there (and the one macOS itself asks for).
    static let filesAndFolders = PermissionGuide(
        id: "files-and-folders",
        name: "Files & Folders",
        what: "So Moe can open what you keep on your Desktop, in Documents and in Downloads when you ask it to.",
        ifDeclined: "Moe keeps working. It can't open files in those folders, and it will say which folder rather than guess why.",
        steps: "System Settings → Privacy & Security → Files & Folders → find Memoe and switch on the folder it needs.",
        settings: pane + "Privacy_FilesAndFolders",
        needsRelaunch: false,
        codes: [.tccFiles],
        probe: .readablePath("~/Desktop"))

    // MARK: - CuaDriver's own two rows
    //
    // CuaDriver (com.trycua.driver) is the helper that sees and uses the
    // screen, and it asks macOS for its grants under its own name. Turning
    // Memoe on in Accessibility does nothing for it — which is the mistake a
    // card that says "Memoe" would lead a person into.

    static let driverAccessibility = PermissionGuide(
        id: "driver-accessibility",
        name: "Accessibility (CuaDriver)",
        what: "So CuaDriver, the screen helper Moe uses, can click and type for you when you ask Moe to do something on your Mac.",
        ifDeclined: "Moe keeps working. It can't use your screen for you, and it tells you so rather than trying.",
        steps: "System Settings → Privacy & Security → Accessibility → switch CuaDriver on. This is CuaDriver's own switch, not Memoe's.",
        settings: pane + "Privacy_Accessibility",
        needsRelaunch: false,
        codes: [.tccDriverAccessibility],
        owner: .driver,
        probe: .driverPermission("accessibility"))

    static let driverScreenRecording = PermissionGuide(
        id: "driver-screen-recording",
        name: "Screen & System Audio Recording (CuaDriver)",
        what: "So CuaDriver, the screen helper Moe uses, can see the window it is working in.",
        ifDeclined: "Moe keeps working. It can't look at your screen for you, and it tells you so rather than guessing what is there.",
        steps: "System Settings → Privacy & Security → Screen & System Audio Recording → switch CuaDriver on. This is CuaDriver's own switch, not Memoe's.",
        settings: pane + "Privacy_ScreenCapture",
        needsRelaunch: false,
        codes: [.tccDriverScreen],
        owner: .driver,
        probe: .driverPermission("screen_recording"))

    /// A folder only Full Disk Access opens: macOS's own privacy database.
    static let fullDiskAccessProbePath = "~/Library/Application Support/com.apple.TCC"

    /// Every permission Moe can ever ask a person for, in the order it tends
    /// to come up.
    ///
    /// No Speech Recognition. Moe hears with its own on-device models and
    /// never asks macOS for Apple's recogniser (`requestSpeechRecognition`
    /// has no caller), so Moe never appears in that System Settings list and
    /// the row sent people to a switch that does not exist for Moe (owner,
    /// 2026-09-10: "it doesn't show Moe over there… do we even use that?").
    static let all: [PermissionGuide] = [
        microphone, accessibility, inputMonitoring,
        automation, calendar, reminders, contacts, fullDiskAccess, screenRecording,
    ]

    /// Everything a failure can point at: what Moe asks for (`all`), plus the
    /// grants a tool can report missing that Moe never asks for itself —
    /// Files & Folders, and CuaDriver's two rows. Not shown in onboarding or
    /// Settings › Permissions (slice 5 adds the driver's rows there).
    static let catalogue: [PermissionGuide] = all + [filesAndFolders, driverAccessibility, driverScreenRecording]

    static func find(_ id: String) -> PermissionGuide? { catalogue.first { $0.id == id } }

    /// The guide a System Settings pane belongs to, so a Connections row that
    /// only knows its deep link can still show the right words. Memoe's own
    /// row: a pane CuaDriver shares (Accessibility) answers with Memoe's guide.
    static func forPane(_ url: URL?) -> PermissionGuide? {
        guard let url else { return nil }
        return all.first { $0.settings == url.absoluteString }
    }

    /// **The one lookup from a fixable failure to what fixes it.** The
    /// island, Chat and the brain's `moe_open_settings` all go
    /// through here, so they say the same thing.
    ///
    /// `pane`: the anchor the tool named, when it named one. It picks
    /// between two grants that fix the same code — `tcc_files` on the
    /// Desktop is Files & Folders, in iCloud Drive it is Full Disk Access —
    /// and never crosses owners: a pane on CuaDriver's row is not Memoe's.
    ///
    /// The switch is exhaustive on purpose: a code added to `FixCode` does
    /// not compile until it is given an answer here.
    static func forCode(_ code: FixCode, pane: String? = nil) -> FixRemedy {
        switch code {
        case .tccAppData, .tccFiles, .tccAutomation, .tccDriverAccessibility, .tccDriverScreen,
             .tccMicrophone, .tccCalendar, .tccReminders, .tccContacts:
            let fits = catalogue.filter { $0.codes.contains(code) }
            if let pane, let named = fits.first(where: { $0.settings == Self.pane + pane }) {
                return .grant(named)
            }
            // Every tcc_* code has a guide; `PermissionGuideFixCodeTests` holds that.
            return fits.first.map(FixRemedy.grant) ?? .explain
        case .driverNotRunning: return .restartScreenHelper
        case .mcpNeedsReauth, .mcpNotConnected: return .openConnections
        case .claudeLoginExpired: return .signInToBrain
        case .browserExtensionMissing: return .openChromeExtension
        case .claudeUsageCap, .browserMissing, .profileLocked: return .explain
        // Hermes already says "switch to it, or I can" and can do it itself.
        case .windowOtherSpace: return .noCard
        // The job's own report says the step is waiting for them; a card
        // with nothing to press would only repeat it.
        case .personNeeded: return .noCard
        }
    }

    var json: [String: Any] {
        ["id": id, "name": name, "what": what, "ifDeclined": ifDeclined,
         "steps": steps, "settings": settings, "needsRelaunch": needsRelaunch,
         "codes": codes.map(\.rawValue), "owner": owner.rawValue, "probe": probe.json]
    }

    /// `Moe --permissions-json`, for scripts/test-connections-ui.sh: proves
    /// every permission has all four fields and a pane that opens, and every
    /// setup flow has its five. The whole catalogue, so a grant only a
    /// failure points at is held to the same standard.
    static func dumpJSON() -> String {
        let obj: [String: Any] = ["permissions": catalogue.map(\.json), "setups": SetupGuide.all.map(\.json)]
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - How to tell a grant is on

/// How to tell, without prompting, that a grant is on. `GrantWatch` runs it
/// every 2 s after a pane is opened (docs/FIXABLE-FAILURES.md §4).
enum GrantProbe: Equatable, Sendable {
    /// `AXIsProcessTrusted()`.
    case accessibilityTrusted
    /// `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.
    case inputMonitoringAccess
    /// `CGPreflightScreenCaptureAccess()`.
    case screenCapturePreflight
    /// `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`.
    case microphoneAuthorization
    /// `EKEventStore.authorizationStatus(for: .event)` is full access.
    case calendarAuthorization
    /// `EKEventStore.authorizationStatus(for: .reminder)` is full access.
    case remindersAuthorization
    /// `CNContactStore.authorizationStatus(for: .contacts) == .authorized`.
    case contactsAuthorization
    /// An EPERM-free listing of this folder (`~` expanded). A failure's own
    /// `path` extra, when it has one, is the better folder to try.
    case readablePath(String)
    /// `AEDeterminePermissionToAutomateTarget` for the failure's subject app,
    /// with `askUserIfNeeded` false: never a prompt.
    case automationTarget
    /// `cua-driver permissions status --json`, this key true
    /// ("accessibility" or "screen_recording"). CuaDriver's own identity
    /// answers, which is the only one that counts for its rows.
    case driverPermission(String)
    /// Nothing to watch.
    case none

    var json: String {
        switch self {
        case .accessibilityTrusted: return "AXIsProcessTrusted"
        case .inputMonitoringAccess: return "IOHIDCheckAccess"
        case .screenCapturePreflight: return "CGPreflightScreenCaptureAccess"
        case .microphoneAuthorization: return "AVCaptureDevice.audio"
        case .calendarAuthorization: return "EKEventStore.event"
        case .remindersAuthorization: return "EKEventStore.reminder"
        case .contactsAuthorization: return "CNContactStore"
        case .readablePath(let p): return "readable:" + p
        case .automationTarget: return "AEDeterminePermissionToAutomateTarget"
        case .driverPermission(let key): return "cua-driver permissions status:" + key
        case .none: return "none"
        }
    }
}

/// What fixes a fixable failure: a grant to turn on, or something that is
/// not a System Settings pane at all.
enum FixRemedy {
    /// A switch in System Settings: open this guide's pane.
    case grant(PermissionGuide)
    /// The screen helper is not running: reopening Memoe starts it again.
    case restartScreenHelper
    /// A connection needs signing in again, or never started: Connections.
    case openConnections
    /// The AI's own sign-in lapsed: the existing sign-in flow.
    case signInToBrain
    /// Moe's Chrome extension is not connected: Connections › Chrome, which
    /// sets it up (ticket #13).
    case openChromeExtension
    /// Nothing to press; the card says what is going on, and Dismiss.
    case explain
    /// Say nothing: Moe handles it itself.
    case noCard
}

// MARK: - The one way a permission is ever explained on screen

/// The reusable block: what it's for, what happens if you don't, the click
/// path, and a button that opens the pane. Never a blocker — whatever is
/// showing this stays usable. Drawn in the app's own type (MoeDesign.Theme)
/// so it reads the same in onboarding, Settings › Permissions and a
/// Connections sheet.
struct PermissionExplainer: View {
    let guide: PermissionGuide
    /// Shown above the explanation when the caller has more to say.
    var lead: String = ""
    var compact = false
    /// Off where the caller has already shown the sentence itself.
    var showWhat = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            if !lead.isEmpty {
                Text(lead)
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showWhat {
                Text(guide.what)
                    .font(Theme.Typo.prose(compact ? 12 : 13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(guide.ifDeclined)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Text(guide.steps)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.base) {
                if let url = guide.settingsURL {
                    PaneButton(title: "Open \(guide.name) settings", symbol: "arrow.up.forward.app") {
                        // Screen Recording: ask macOS first. System Settings
                        // lists an app there only once it has asked, so a
                        // bare deep link sent the owner to a list with no
                        // Moe on it (2026-09-11). After a refusal the ask
                        // shows nothing and returns false; the list is the
                        // way back, and Moe is on it by then.
                        if guide.id == PermissionGuide.screenRecording.id, ScreenPermission.request() { return }
                        NSWorkspace.shared.open(url)
                    }
                }
                if guide.needsRelaunch {
                    PaneButton(title: "Quit and reopen \(BuildInfo.hostAppName)") { Relaunch.now() }
                }
            }
            .padding(.top, Theme.Space.tight)
        }
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }
}
