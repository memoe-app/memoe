import AppKit
import MoeDesign
import SwiftUI

/// ⌘, — which until now just raised the main window.
///
/// The sidebar used to carry ten peers, so "Licenses" and "Background" sat at
/// the same level as "Chat". Configuration lives here instead, and the sidebar
/// keeps only the screens you open because you want to do something.
///
/// One window, reused: asking for a pane while it is already open switches to
/// that pane rather than stacking a second window.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindow?

    private let conductor: Conductor
    private let selection: Selection
    private var window: NSWindow?

    /// Shared so an already-open window can be re-pointed from a menu.
    final class Selection: ObservableObject {
        @Published var section: MainWindow.Section
        /// The page that was asked for when it now lives as a tab inside
        /// another (`landing`), so the host opens on that tab.
        @Published var sub: MainWindow.Section?
        /// A row's title to light up and scroll to — Moe opening Settings on
        /// a setting (`SettingsBridge`). Cleared a few seconds later.
        @Published var spotlight: String?
        private var spotlightClear: Task<Void, Never>?
        init(_ section: MainWindow.Section) {
            self.section = Self.landing(section)
            self.sub = section
        }

        func go(_ section: MainWindow.Section) {
            sub = section
            self.section = Self.landing(section)
        }

        @MainActor
        func light(_ title: String?, for seconds: Double = 6) {
            spotlight = title
            spotlightClear?.cancel()
            guard title != nil else { return }
            spotlightClear = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.spotlight = nil
            }
        }

        /// Pages folded into others. Replies is part of Settings › Voice
        /// since 2026-09-25; on 2026-09-28 the owner asked for fewer pages,
        /// so Reminders is a tab of Running in the background, Activity,
        /// Usage and Chats are History, and Skills is a tab of Brain. A link
        /// that still asks for one lands on its host, never a blank pane.
        static func landing(_ section: MainWindow.Section) -> MainWindow.Section {
            switch section {
            case .replies: return .voice
            case .reminders: return .background
            case .usage, .chats: return .activity
            case .skills: return .brain
            default: return section
            }
        }

        /// Hosts only: the pages the sidebar lists.
        static func listed(_ section: MainWindow.Section) -> Bool {
            // A build with no cloud (a community build of the open source)
            // has no Away to offer, so the page is not listed at all.
            if section == .away && !Cloud.isPresent { return false }
            return landing(section) == section
        }
    }

    private init(conductor: Conductor, at section: MainWindow.Section) {
        self.conductor = conductor
        self.selection = Selection(section)
    }

    /// Open Settings, on `section`. Defaults to the brain because that is the
    /// one thing a new install must set before anything else works.
    static func show(conductor: Conductor, at section: MainWindow.Section = .brain,
                     spotlight: String? = nil) {
        if let existing = shared {
            existing.selection.go(section)
            existing.selection.light(spotlight)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindow(conductor: conductor, at: section)
        controller.open()
        controller.selection.light(spotlight)
        shared = controller
    }

    private func open() {
        let view = SettingsView(conductor: conductor, selection: selection)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Settings"
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.setContentSize(NSSize(width: 720, height: 540))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Self.shared = nil
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var conductor: Conductor
    @ObservedObject var selection: SettingsWindow.Selection

    private var items: [MainWindow.Section] {
        MainWindow.Section.allCases.filter { $0.place == .settings && SettingsWindow.Selection.listed($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .background(Theme.paper)
        .frame(minWidth: 640, minHeight: 460)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Clearance for the traffic lights, as in the main window.
            Color.clear.frame(height: 34)
            ForEach(items) { item in
                row(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.bottom, Theme.Space.small)
        .frame(width: 172)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func row(_ item: MainWindow.Section) -> some View {
        let on = selection.section == item
        return Button {
            selection.go(item)
        } label: {
            HStack(spacing: Theme.Space.small) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(on ? Theme.accentDeep : Theme.ink3)
                    .accessibilityHidden(true)
                Text(label(item))
                    .font(Theme.Typo.ui(13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(on ? Theme.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.easeOut, value: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Settings names things by what they do, not by what they are inside.
    /// "Brain" is the one place the engine metaphor is allowed to show,
    /// because that screen is where you choose it.
    private func label(_ item: MainWindow.Section) -> String {
        Self.label(item, awayTier: conductor.cloudSnapshot?.tier)
    }

    /// The same, with the one live input handed in, so a test can read the
    /// names without a conductor.
    static func label(_ item: MainWindow.Section, awayTier: String?) -> String {
        switch item {
        // "& Dictation" only while typing by voice is offered at all
        // (`Features.dictation`): a name that promises a tab that is not
        // there is the kind of label docs/DEFAULTS.md's wording rule bans.
        case .voice: return Features.dictation ? "Voice & Dictation" : "Voice"
        case .background: return "Running in the background"
        // "Upgrade" until they have one, then the name of the thing they
        // have — the cloud's word, from the live status or, before the sync
        // has published one, the gate's own read (`CloudLink`).
        case .away: return Cloud.link.awaySidebarLabel(tier: awayTier)
        // The third-party attribution LICENSES.md requires us to show. It
        // used to sit next to a "Your Licence" tab and the two were easy to
        // mistake for each other; that one is gone, and this one stays.
        case .licenses: return "About & Licences"
        case .activity: return "History"
        default: return item.rawValue
        }
    }

    /// Not private: `--settings-snapshot` measures the least height this
    /// asks for (`SettingsSnapshot.minimumSize`). The window's own
    /// `minHeight` frame answers that question with its own number whatever
    /// is inside it, so the window cannot be asked.
    var content: some View {
        ScrollViewReader { proxy in
            pane
                .environment(\.settingSpotlight, selection.spotlight)
                .onChange(of: selection.spotlight) { _, title in
                    guard let title else { return }
                    // After a "More" or a tab the row is in has opened.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        withAnimation(Theme.Motion.easeOut) {
                            proxy.scrollTo(SettingSpotlight.anchor(title), anchor: .center)
                        }
                    }
                }
        }
    }

    private var pane: some View {
        Group {
            switch selection.section {
            case .brain, .skills: BrainPane(conductor: conductor, start: selection.sub)
            case .replies, .voice: VoicePane(conductor: conductor)
            case .meetingCapture: MeetingCapturePane(conductor: conductor)
            case .permissions: PermissionsPane(conductor: conductor)
            case .background, .reminders: BackgroundPane(conductor: conductor, start: selection.sub)
            case .activity, .chats, .usage: HistoryPane(conductor: conductor, start: selection.sub)
            case .away:        Cloud.link.awayPage(conductor) ?? AnyView(EmptyView())
            case .privacy:     Cloud.link.privacyPage(conductor) ?? AnyView(LocalPrivacyPane(conductor: conductor))
            case .licenses:    LicensesView()
            default:           BrainPane(conductor: conductor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hair)
        )
        .padding(Theme.Space.snug)
        .padding(.leading, 0)
    }
}

// MARK: - Spotlight

/// The row Moe opened Settings on (`SettingsBridge`): rows compare their own
/// title with it, light up, and carry an id the window scrolls to. A pane
/// that hides rows behind "More" or a tab opens the one it is in.
enum SettingSpotlight {
    static func anchor(_ title: String) -> String { "setting:" + title }

    /// Where the lit row sits under its page — its catalogue entry's `under`.
    @MainActor
    static func under(_ title: String?) -> String? {
        guard let title else { return nil }
        return SettingsCatalogue.all.first { $0.title == title }?.under
    }
}

private struct SettingSpotlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingSpotlight: String? {
        get { self[SettingSpotlightKey.self] }
        set { self[SettingSpotlightKey.self] = newValue }
    }
}

extension View {
    /// Lights a settings row when Moe opened Settings on it, and gives it the
    /// id the window scrolls to.
    func settingSpotlight(_ title: String, lit: Bool) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.selected)
                    .padding(.horizontal, -8)
                    .opacity(lit ? 1 : 0)
                    .animation(Theme.Motion.easeOut, value: lit)
            )
            .id(SettingSpotlight.anchor(title))
    }
}
