import AppKit
import MoeDesign
import SwiftUI

/// What Moe asks macOS for, and — the part that was missing — whether macOS
/// has actually said yes.
///
/// The old pane listed every permission with its explanation and a "How do
/// I?" disclosure, and never showed a single piece of state. That made it
/// documentation rather than a status screen: you could read it top to bottom
/// and still not know which grants were live. `PermissionStatus` answers that
/// now, and the row leads with the answer.
struct PermissionsPane: View {
    /// Nil only for the two places that show the pane without a conductor
    /// in reach; the "Browse as" group needs one and hides itself otherwise.
    var conductor: Conductor? = nil
    @State private var open: String?
    @State private var states: [String: PermissionStatus.State] = [:]
    @State private var browseAs: BrowseAs? = nil
    @State private var browseBusy = false
    @State private var browseVerdict: (tone: PaneBanner.Tone, text: String)? = nil

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Permissions") {
                PaneButton(title: "Re-check", symbol: "arrow.clockwise", action: refresh)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    // One line each, what is missing first (owner, 2026-09-28).
                    VStack(alignment: .leading, spacing: 0) {
                        Calm.header("What Moe may use")
                        Text("None is required — without one, that one thing is off and Moe says so.")
                            .font(Theme.Typo.prose(12.5)).foregroundStyle(Theme.ink3)
                            .padding(.bottom, 4)
                        ForEach(ordered) { guide in
                            PermRow(guide: guide,
                                    state: states[guide.id] ?? .unknown,
                                    expanded: open == guide.id,
                                    toggle: { open = open == guide.id ? nil : guide.id })
                        }
                        // Location: asked the first time a question needs
                        // it, so it is not in the welcome's list (`all`).
                        PermRow(guide: .location,
                                state: states[PermissionGuide.location.id] ?? .unknown,
                                expanded: open == PermissionGuide.location.id,
                                toggle: { open = open == PermissionGuide.location.id ? nil : PermissionGuide.location.id })
                    }

                    screenGroup

                    browseAsGroup

                    rules
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.raised)
        .onAppear(perform: refresh)
    }

    /// Not allowed, then can't tell, then allowed — the rows that need
    /// something first.
    private var ordered: [PermissionGuide] {
        func rank(_ g: PermissionGuide) -> Int {
            switch states[g.id] ?? .unknown {
            case .denied: return 0
            case .notAsked: return 1
            case .unknown: return 2
            case .granted: return 3
            }
        }
        return PermissionGuide.all.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    // MARK: - Moe and your screen
    //
    // These three lived on Settings › Voice › Talking to Moe until
    // 2026-09-25, which is a page about talking. They are about what Moe may
    // see and touch on the screen, so they sit with the other grants.

    /// Its own view so it observes the Conductor: this pane holds an
    /// optional one and would not redraw when a switch flips.
    @ViewBuilder private var screenGroup: some View {
        if let conductor { ScreenControls(conductor: conductor) }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("What Moe may do without asking")
            SettingRow(title: "Anything read-only",
                       detail: "Sending mail or messages, sharing files and deleting are denied unless you allow them.") {
                PaneButton(title: "Edit the rules") {
                    NSWorkspace.shared.open(Paths.home.appendingPathComponent(".claude/settings.json"))
                }
            }
        }
    }

    // MARK: - Browse as

    /// Which of the person's browser profiles Moe's own browser carries the
    /// logins of. Hermes copies the profile Chrome used LAST unless one is
    /// pinned; with several profiles that is a different identity every
    /// time they switch windows, and on 2026-09-18 it left a daily X job
    /// signed out (ticket #5). The list is what configure-hermes.py found
    /// with Hermes's own detector (`BrowseAs`), so it cannot name a profile
    /// Hermes would not open.
    @ViewBuilder
    private var browseAsGroup: some View {
        if let conductor, let browseAs, browseAs.browser != nil, browseAs.profiles.count > 1 {
            SettingGroup(title: "Browse as") {
                VStack(alignment: .leading, spacing: Theme.Space.base) {
                    if let v = browseVerdict { PaneBanner(tone: v.tone, text: v.text, busy: browseBusy) }
                    SettingRow(title: "Moe's browser signs in as",
                               detail: browseAs.summary,
                               note: browseAs.problem,
                               last: true) {
                        SettingMenu(value: browseAs.profile(conductor.config.browseAsProfile)?.label
                                        ?? "Whichever I used last") {
                            Picker("", selection: Binding(
                                get: { browseAs.profile(conductor.config.browseAsProfile)?.dir ?? BrowseAs.followLastUsed },
                                set: { choose(browseAs: $0, conductor: conductor) })) {
                                Text("Whichever I used last").tag(BrowseAs.followLastUsed)
                                ForEach(browseAs.profiles) { Text($0.label).tag($0.dir) }
                            }
                            .labelsHidden().pickerStyle(.inline)
                        }
                        .disabled(browseBusy)
                    }
                    Text("Takes effect the next time Moe opens its browser. Moe's browser is its own private copy; your \(browseAs.browserName) windows are never touched.")
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                }
            }
        }
    }

    /// Save the choice and hand it to Hermes by the road every brain setting
    /// takes (`BrainSetup.run`, off the main thread). A refusal — the script
    /// will not pin a name that is not a profile — puts the old choice back.
    private func choose(browseAs dir: String, conductor: Conductor) {
        let before = conductor.config.browseAsProfile
        guard before != dir else { return }
        conductor.config = Config.update { $0.browseAsProfile = dir }
        browseBusy = true
        browseVerdict = (.neutral, "Saving…")
        Task {
            let written = await Task.detached(priority: .userInitiated) {
                BrainSetup.setBrowseAs(profileDir: dir)
            }.value
            browseBusy = false
            switch written {
            case .failure(let f):
                conductor.config = Config.update { $0.browseAsProfile = before }
                browseVerdict = (.bad, f.message)
            case .success:
                browseAs = BrowseAs.read(home: Paths.home)
                let who = browseAs?.profile(dir)?.label ?? "whichever profile you used last"
                browseVerdict = (.good, "Saved. Moe browses as \(who) from its next browser session.")
            }
        }
    }

    /// Full Disk Access touches the disk, so this is on demand and on appear
    /// rather than on every redraw.
    private func refresh() {
        var next: [String: PermissionStatus.State] = [:]
        for guide in PermissionGuide.all {
            next[guide.id] = PermissionStatus.current(guide.id)
        }
        next[PermissionGuide.location.id] = LocationPermission.state()
        states = next
        browseAs = BrowseAs.read(home: Paths.home)
    }
}

// MARK: - One permission

struct PermRow: View {
    let guide: PermissionGuide
    let state: PermissionStatus.State
    let expanded: Bool
    let toggle: () -> Void

    /// The row's one line (owner, 2026-09-28: "one line each"). The full
    /// sentence is under Details.
    static let shortLines: [String: String] = [
        "microphone": "To hear you while you hold the talk key.",
        "speech-recognition": "To turn what you say into words on this Mac.",
        "accessibility": "To notice the talk key while you're in another app.",
        "input-monitoring": "The same as Accessibility, on some Macs.",
        "full-disk-access": "To read Messages, call history and Chrome history.",
        "automation": "To ask Notes, Calendar and Messages, and drive the Mac.",
        "contacts": "To know who you mean when you say a name.",
        "calendar": "To know what you have on today.",
        "reminders": "To know what you still owe people.",
        "screen-recording": "To see your screen when you ask, and record calls.",
        "files-and-folders": "To open the files you point it at.",
        "driver-accessibility": "So Moe's helper can click and type for you.",
    ]

    static func short(_ what: String, id: String = "") -> String {
        if let line = shortLines[id] { return line }
        guard let end = what.range(of: ". ") else { return what }
        return String(what[..<end.lowerBound]) + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: guide.name, detail: Self.short(guide.what, id: guide.id)) {
                HStack(spacing: Theme.Space.base) {
                    Text(state.label)
                        .font(Theme.Typo.ui(12, weight: .medium))
                        .foregroundStyle(colour)
                    // A granted permission needs no fix-it button; the click
                    // path is still one tap away for anyone who wants to revoke.
                    PaneButton(title: expanded ? "Hide" : (state == .granted ? "Details" : "How do I?"),
                               prominent: state == .denied && !expanded, action: toggle)
                }
            }
            if expanded {
                Calm.Reveal {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        PermissionExplainer(guide: guide, compact: true, showWhat: true)
                        if let url = guide.settingsURL {
                            PaneButton(title: "Open the settings pane", symbol: "arrow.up.forward.app") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        // "Not allowed" while System Settings shows Moe switched
                        // on is a stale entry from an earlier copy of Memoe.
                        if guide.id == "accessibility", state != .granted {
                            Text("Memoe is switched on in System Settings and this still says Not allowed? That switch belongs to an older copy of Memoe. Reset it, then switch Memoe on again.")
                                .font(Theme.Typo.prose(12.5))
                                .foregroundStyle(Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: Theme.measure, alignment: .leading)
                            PaneButton(title: "Reset and ask again", symbol: "arrow.counterclockwise") {
                                PushToTalk.resetAccessibilityAndAsk()
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var colour: Color {
        switch state {
        case .granted:  return Theme.good
        case .denied:   return Theme.warn
        case .notAsked: return Theme.ink3
        case .unknown:  return Theme.ink3
        }
    }
}

/// Settings › Permissions › "Moe and your screen".
struct ScreenControls: View {
    @ObservedObject var conductor: Conductor

    var body: some View {
            SettingGroup(title: "Moe and your screen") {
                SettingRow(
                    title: "Moe sees my screen when I ask",
                    detail: "A picture of the screen goes with your words, so “what do I do here” just works. Never saved."
                ) {
                    VoicePane.lever(Binding(get: { conductor.config.screenContext },
                                            set: { conductor.setScreenContext($0) }))
                }
                SettingRow(
                    title: "Move my mouse to what Moe points at",
                    detail: "Off, Moe only draws a ring around the thing it means. It never clicks."
                ) {
                    VoicePane.lever(Binding(get: { conductor.config.screenPointerMovesMouse },
                                            set: { conductor.setScreenPointerMovesMouse($0) }),
                                    enabled: conductor.config.screenContext)
                }
                SettingRow(
                    title: "Let Moe bring a window to the front when it has to",
                    detail: "For a window on another desktop, a minimised one, or a menu "
                          + "in an app that is not in front. Off, Moe leaves your screen "
                          + "alone and tells you what it could not reach.",
                    last: true
                ) {
                    VoicePane.lever(Binding(get: { conductor.config.computerUseMayTakeOver },
                                            set: { conductor.setComputerUseMayTakeOver($0) }))
                }
            }
    }
}
