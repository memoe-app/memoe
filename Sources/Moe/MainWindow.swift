import AppKit
import MoeDesign
import MoeErase
import SwiftUI

/// The actual app window.
///
/// The first version had none of this — it was a menu-bar-only agent with no
/// Dock icon, which meant no ⌘Q and no visible way to turn anything off or
/// even quit. Everything Moe can do is reachable from here, including
/// switching it all off and removing it.
///
/// The shell is a full-height sidebar with the traffic lights floating over
/// it, and the content in its own rounded panel inset from the window edge.
/// That is a deliberate move off `NavigationSplitView` + `List`: those gave
/// the app stock System Settings chrome, which is most of the reason a voice
/// assistant read as a control panel.
struct MainWindow: View {
    @ObservedObject var conductor: Conductor
    @State private var section: Section = .chat
    /// Connections opens on this row. Only `--settings-snapshot` passes it.
    private let selectingConnection: String?
    private let connectionsChecked: Date?

    /// `section` and the two after it exist for `--settings-snapshot`, which
    /// draws the whole window on a chosen pane at a chosen size — the only
    /// way to photograph what the window does when a pane does not fit.
    init(conductor: Conductor, section: Section = .chat,
         selectingConnection: String? = nil, connectionsChecked: Date? = nil) {
        self.conductor = conductor
        _section = State(initialValue: section)
        self.selectingConnection = selectingConnection
        self.connectionsChecked = connectionsChecked
    }

    /// Every screen the app has. `place` decides where it is reached from.
    ///
    /// The six you use daily live in the sidebar; the rest is configuration
    /// and belongs behind ⌘,. Keeping them in one flat list is how "Licenses"
    /// ended up sitting beside "Chat" as an equal.
    enum Section: String, CaseIterable, Identifiable {
        // Daily
        case chat = "Chat"
        case inbox = "Inbox"
        case dictation = "Dictation"
        case meetings = "Meetings"
        // Library
        case memory = "Memory"
        // Reach
        case connections = "Connections"
        case reachMoe = "Message Moe"
        // Configuration — the Settings window, never the sidebar.
        case brain = "Brain"
        case replies = "Replies"
        case voice = "Voice"
        case meetingCapture = "Meeting Capture"
        case permissions = "Permissions"
        // Next to Background on purpose: one is what Moe does on a
        // clock, the other is what it may read while doing it.
        case reminders = "Reminders"
        case background = "Background"
        // The two "what already happened" screens, kept together and kept
        // next to Background: one is what Moe did, the other is what was
        // said while it did it, and a row in the first opens the second.
        case activity = "Activity"
        case chats = "Chats"
        // What Moe can do, and what doing it has cost. Kept together and
        // kept after the two history screens: one answers "what is Moe
        // able to do", the other "what has that used up", and the second
        // is meaningless without the first.
        case skills = "Skills"
        case usage = "Usage"
        case away = "Away"
        // What leaves this Mac and whether it may, and the two ways out.
        // After Away because two of its rows only exist once Away does.
        case privacy = "Privacy"
        // No `licence` here. Moe is sold as a subscription — Settings › Away
        // is where a plan lives — and the licence-key screen it named had
        // nothing to say: a build with no `MoeLicencePublicKey` (every build
        // anybody has) drew "No licences in this build". A tab that can only
        // ever say nothing is worse than no tab. `MoeLicence` and
        // `LicenceStore` are untouched, so a screen can come back in one file
        // if we ever sell a key.
        case licenses = "Licenses"

        var id: String { rawValue }

        enum Place { case daily, library, reach, settings }

        var place: Place {
            switch self {
            case .chat, .inbox, .dictation, .meetings: return .daily
            case .memory: return .library
            case .connections, .reachMoe: return .reach
            case .brain, .replies, .voice, .meetingCapture, .permissions, .reminders,
                 .background, .activity, .chats, .skills, .usage, .away, .privacy,
                 .licenses: return .settings
            }
        }

        /// The header that introduces this row's group, when it opens one.
        var groupHeader: String? {
            switch self {
            case .memory: return "Library"
            case .connections: return "Reach"
            default: return nil
            }
        }

        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right"
            case .inbox: return "tray"
            case .dictation: return "keyboard"
            case .meetings: return "record.circle"
            case .memory: return "brain"
            case .connections: return "link"
            case .reachMoe: return "iphone.and.arrow.forward"
            case .brain: return "cpu"
            // A reply, not a microphone: this pane is about what comes back.
            case .replies: return "text.bubble"
            case .voice: return "waveform"
            case .meetingCapture: return "camera.viewfinder"
            case .permissions: return "lock.shield"
            // A bell, not a clock: the row below it is Background,
            // whose icon is the clock, and two clocks side by side
            // say nothing about which is which.
            case .reminders: return "bell"
            case .background: return "clock.arrow.circlepath"
            // A pulse, not another clock: this row is what already
            // happened, and the two rows above it are both about time
            // that has not happened yet.
            case .activity: return "clock"
            case .chats: return "bubble.left.and.text.bubble.right"
            // A book, not a wand: a skill is a page of instructions Moe
            // reads, and every "magic" mark in this set would promise
            // something the feature does not do.
            case .skills: return "book"
            case .usage: return "gauge.with.needle"
            case .away: return "cloud"
            case .privacy: return "hand.raised"
            case .licenses: return "doc.text"
            }
        }

        /// The daily rows, in order. Dictation's row exists only while the
        /// feature is offered (`Features.dictation`); the pane stays in code.
        static var sidebarItems: [Section] {
            allCases.filter { $0.place != .settings && ($0 != .dictation || Features.dictation) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .background(Theme.paper)
        .frame(minWidth: 820, minHeight: 560)
        // The menus and onboarding open a particular pane this way.
        .onReceive(NotificationCenter.default.publisher(for: .moeShowSection)) { n in
            guard let raw = n.userInfo?["section"] as? String,
                  let s = Section(rawValue: raw),
                  s != .dictation || Features.dictation else { return }
            // A configuration section asked for by a menu opens the Settings
            // window — the sidebar has no row to select for it.
            if s.place == .settings {
                SettingsWindow.show(conductor: conductor, at: s)
            } else {
                section = s
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Room for the traffic lights, which float over the sidebar
            // instead of sitting in a titlebar of their own.
            Color.clear.frame(height: 34)

            ForEach(Section.sidebarItems) { item in
                if let header = item.groupHeader {
                    Text(header)
                        .font(Theme.Typo.label(9))
                        .tracking(Theme.tracking)
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, Theme.Space.small)
                        .padding(.top, Theme.Space.cosy)
                        .padding(.bottom, Theme.Space.tight)
                }
                row(item)
            }

            Spacer(minLength: Theme.Space.cosy)

            // Settings is reachable from ⌘, and the app menu, but a person
            // should not have to find a menu to discover a whole window
            // exists. It sits below the divider because it is not one of the
            // daily surfaces — it opens the separate window, not a pane.
            settingsRow

            statusFooter
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.bottom, Theme.Space.small)
        .frame(width: 186)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func row(_ item: Section) -> some View {
        let on = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: Theme.Space.small) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(on ? Theme.accentDeep : Theme.ink3)
                Text(item.rawValue)
                    .font(Theme.Typo.ui(13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                Spacer(minLength: 0)
                if item == .inbox, !conductor.waitingNotices.isEmpty {
                    Text("\(conductor.waitingNotices.count)")
                        .font(Theme.Typo.ui(10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.Island.ground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.Island.amber))
                }
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
    }

    private var settingsRow: some View {
        Button {
            SettingsWindow.show(conductor: conductor)
        } label: {
            HStack(spacing: Theme.Space.small) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(Theme.ink3)
                Text("Settings")
                    .font(Theme.Typo.ui(13))
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 0)
                Text("⌘,")
                    .font(Theme.Typo.data(10))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Two dots that never lie. `doctor.sh` does real connection checks, and
    /// this is where that honesty surfaces.
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            statusDot(ok: conductor.connected, on: "Connected", off: "Connecting…")
            // The microphone as well as the models (`VoiceStatus`).
            statusDot(ok: conductor.voiceStatus.ok, on: conductor.voiceStatus.text, off: conductor.voiceStatus.text)
        }
        .padding(.horizontal, Theme.Space.small)
        .padding(.top, Theme.Space.small)
    }

    private func statusDot(ok: Bool, on: String, off: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ok ? Theme.good : Theme.warn)
                .frame(width: 6, height: 6)
            Text(ok ? on : off)
                .font(Theme.Typo.ui(11))
                .foregroundStyle(Theme.ink2)
        }
    }

    // MARK: - Content

    /// Not private: `--settings-snapshot` measures the least height this
    /// asks for (`SettingsSnapshot.minimumSize`). The window's own
    /// `minHeight` frame answers that question with its own number whatever
    /// is inside it, so the window cannot be asked.
    var content: some View {
        Group {
            switch section {
            case .chat:        ChatPane(conductor: conductor)
            case .inbox:       InboxPane(conductor: conductor)
            case .dictation:   DictationPane(conductor: conductor)
            case .meetings:    MeetingsPane(conductor: conductor)
            case .memory:      MemoryPane(conductor: conductor)
            case .connections: ConnectionsPane(conductor: conductor, selecting: selectingConnection,
                                               checked: connectionsChecked)
            case .reachMoe:    ReachMoePane(conductor: conductor)
            // Only reachable by a deep link that arrives before the Settings
            // window opens. Harmless, and better than a blank panel.
            case .brain:       BrainPane(conductor: conductor)
            case .replies, .voice: VoicePane(conductor: conductor)
            case .meetingCapture: MeetingCapturePane(conductor: conductor)
            case .permissions: PermissionsPane(conductor: conductor)
            case .reminders:   RemindersPane(conductor: conductor)
            case .background:  BackgroundPane(conductor: conductor)
            case .activity:    ActivityPane(conductor: conductor)
            case .chats:       ChatsPane(conductor: conductor)
            case .skills:      SkillsPane(conductor: conductor)
            case .usage:       UsagePane(conductor: conductor)
            case .away:        Cloud.link.awayPage(conductor) ?? AnyView(EmptyView())
            case .privacy:     Cloud.link.privacyPage(conductor) ?? AnyView(LocalPrivacyPane(conductor: conductor))
            case .licenses:    LicensesView()
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

// MARK: - Connections

struct ConnectionsPane: View {
    @ObservedObject var conductor: Conductor
    var selecting: String?
    var checked: Date?

    var body: some View {
        ConnectionsView(conductor: conductor, mode: .services, selecting: selecting, checked: checked)
    }
}

/// The other half of what used to be one list: the places a person can
/// reach Moe from, rather than the things Moe reaches. Same view, same
/// connect flows, different question — see `ConnectionsView.Mode`.
struct ReachMoePane: View {
    @ObservedObject var conductor: Conductor

    var body: some View {
        ConnectionsView(conductor: conductor, mode: .reach)
    }
}

/// Opens a script in Terminal.app. The path goes through two parsers on the
/// way — AppleScript's string literal, then the shell `do script` hands it
/// to — so it is quoted for both. A home directory with a space or a quote
/// in it would otherwise run the wrong thing, or nothing.
enum Terminal {
    static func script(running path: String, args: [String] = []) -> String {
        // Shell first: each word single-quoted, with any ' inside it closed,
        // escaped, and reopened. Then AppleScript: \ and " in the resulting
        // text are the only characters its string literal treats specially.
        let shell = ([path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let apple = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(apple)"
        end tell
        """
    }
}


struct FirstOpenNotice: View {
    @State private var open = false

    var body: some View {
        Section("The first time you open Memoe") {
            DisclosureGroup("Opening Memoe for the first time", isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Memoe is signed and notarized by Apple. The first time you "
                         + "open a copy you downloaded, macOS checks it and asks "
                         + "once:")
                    Text("“Memoe” is an app downloaded from the Internet. Are you sure "
                         + "you want to open it?")
                        .italic()
                        .padding(.leading, 10)
                    Text("Apple checked it for malicious software and none was "
                         + "detected.")
                        .italic()
                        .padding(.leading, 10)
                    Text("Click Open. That is all of it — there is no trip to System "
                         + "Settings and no Privacy & Security step.")
                    Text("After that, the welcome inside Memoe asks for the things it "
                         + "needs, one at a time: the microphone, so it can hear you, "
                         + "then permission to notice its talk key and to see your "
                         + "screen. You can skip any of them, and whatever you skip is "
                         + "asked for again the first time it is needed. Those are "
                         + "macOS asking on your behalf, not warnings about Memoe — it "
                         + "cannot hear you or act for you until you say yes.")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
    }
}

/// Small wrapper around launchctl so the UI can show and flip background jobs.
enum Launchd {
    /// The one background agent. Named `jobs` rather than `sync` because it
    /// is no longer only the sync.
    ///
    /// Derived from the bundle identifier, not written out, so a development
    /// build (`com.memoe.app.dev`) gets `com.memoe.app.dev.jobs` and
    /// cannot load, unload or overwrite the agent belonging to the Moe in
    /// daily use. launchd labels must be unique within a domain; two builds
    /// claiming one label is a collision that shows up as a job silently
    /// doing the wrong checkout's work.
    static let jobsLabel: String = {
        let id = Bundle.main.bundleIdentifier ?? MacEraseIdentity.releaseBundleID
        return id == MacEraseIdentity.releaseBundleID ? "com.moe.jobs" : id + ".jobs"
    }()

    /// Agents earlier versions wrote, which are booted out and deleted the
    /// first time a build carrying `jobsLabel` runs.
    ///
    /// They have to be named here rather than discovered: `loadedLabels()`
    /// only sees agents launchd currently has loaded, and an agent whose
    /// plist exists but failed to load is exactly the one worth removing.
    /// `com.moe.assistant` is the login item a pre-rename copy wrote. The
    /// bundle identifier moved to `com.memoe.app`, so nothing else names it
    /// any more: left alone it stays loaded and keeps opening a bundle that
    /// no longer exists, through an install and through Erase.
    static let supersededLabels = ["com.moe.sync", "com.moe.digest", "com.moe.assistant"]

    /// Removes the superseded agents. Returns how many are actually gone.
    ///
    /// The plist is deleted only when the agent is no longer loaded. Deleting
    /// it unconditionally — as this first did — turns a failed `bootout` into
    /// a *permanent* problem: the agent stays loaded with no file behind it,
    /// so it keeps running `Moe --sync` alongside the new agent until the next
    /// logout, and there is no longer a plist for anything to find or retry.
    /// `launchctl bootout` really does fail in the wild ("Boot-out failed:
    /// 36: Operation now in progress") while a job is on its way out.
    ///
    /// The count is what actually happened, not what was attempted, because
    /// `startBackgroundJobsOnce` writes its marker on the strength of it and
    /// would otherwise record a migration that did not occur.
    @discardableResult
    static func removeSuperseded() -> Int {
        let uid = getuid()
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        var removed = 0
        for label in supersededLabels {
            let plist = dir + "/\(label).plist"
            let existed = FileManager.default.fileExists(atPath: plist)
            let loaded = loadedLabels().contains(label)
            // Not loaded is success: nothing to boot out.
            let out = loaded ? run(["bootout", "gui/\(uid)/\(label)"]) : true
            guard out else { continue }
            try? FileManager.default.removeItem(atPath: plist)
            if existed && !FileManager.default.fileExists(atPath: plist) { removed += 1 }
        }
        return removed
    }

    /// True while any superseded agent is still installed or loaded.
    ///
    /// Both halves matter: a plist with no loaded job runs at the next login,
    /// and a loaded job with no plist runs until the next logout.
    static func supersededRemain() -> Bool {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let loaded = loadedLabels()
        return supersededLabels.contains {
            FileManager.default.fileExists(atPath: dir + "/\($0).plist") || loaded.contains($0)
        }
    }

    /// True when this process *is* one of the superseded agents' jobs.
    ///
    /// launchd sets XPC_SERVICE_NAME to the job's label in the environment of
    /// the process it spawns. It matters because `Moe --sync` reaches the
    /// migration: an old `com.moe.sync` agent that boots itself out is killed
    /// on the spot — measured — halfway through, before the new agent is
    /// written and before the marker. The Mac is then left with no sync at
    /// all, and repeats the same suicide after every login.
    static func runningAsSupersededJob() -> Bool {
        guard let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] else { return false }
        return supersededLabels.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// What is wrong with the background agent right now, or nil when it is
    /// fine. Read from launchd itself, not from what Moe last wrote.
    ///
    /// The owner's Mac, 2026-09-10: they removed Moe 0.3.16 and installed
    /// 0.3.17 at the same path. launchd tried the job while no app was there,
    /// logged *"Missing executable detected. Job: 'com.moe.jobs'"*, parked it
    /// with `last exit code = 78` (EX_CONFIG) — and never scheduled it again,
    /// not even once the new Moe was installed and running. Five hours with
    /// no sync. Nothing in Moe noticed, because `startBackgroundJobsOnce`
    /// keys its marker on the executable *path*, which had not changed.
    ///
    /// So: a state read, every launch, of the thing itself.
    static func jobsAilment(printOutput: String? = nil,
                            plistExists: Bool? = nil) -> String? {
        let label = jobsLabel
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        let exists = plistExists ?? FileManager.default.fileExists(atPath: plist)
        guard exists else { return "its job description is missing" }
        let text = printOutput ?? printJob(label)
        // `launchctl print` fails for a label launchd does not have.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "launchd is not holding it"
        }
        // EX_CONFIG. launchd's own word for "I could not spawn what this job
        // names", which is what a replaced app looks like from its side. A
        // job that merely *ran* and exited non-zero reports that under
        // `last exit status`, not `last exit code`, so this does not fire on
        // an ordinary failed sync.
        if text.contains("last exit code = 78") {
            return "launchd could not start it (the app it names was replaced)"
        }
        if text.lowercased().contains("missing executable") {
            return "launchd cannot find the app it names"
        }
        return nil
    }

    /// `launchctl print gui/<uid>/<label>`, or "" when there is no such job.
    private static func printJob(_ label: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Whether a label in `launchctl list` can be one of Moe's.
    ///
    /// Every label this app writes or removes: the `com.moe.*` ones the
    /// release has always used (`com.moe.jobs`, the superseded
    /// `com.moe.sync`/`.digest`/`.assistant`), and the ones derived from
    /// the bundle identifier — `com.memoe.app` itself (the open-at-login
    /// job) and Moe Dev's `com.memoe.app.dev.jobs`. Until 2026-09-23 this
    /// was `hasPrefix("com.moe.")` alone, which the rename (fcd320e9) left
    /// blind to both of those: Moe Dev's Settings › Background always read
    /// its job as not loaded.
    static func isOurs(label: some StringProtocol) -> Bool {
        label.hasPrefix("com.moe.")
            || label == MacEraseIdentity.releaseBundleID
            || label.hasPrefix(MacEraseIdentity.releaseBundleID + ".")
    }

    static func loadedLabels() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var found = Set<String>()
        for line in text.split(separator: "\n") {
            if let label = line.split(separator: "\t").last, isOurs(label: label) {
                found.insert(String(label))
            }
        }
        return found
    }

    /// Turn a background job on or off.
    ///
    /// Enabling has to WRITE the job description first. The previous version
    /// asked launchd to load a file that had never been created, which failed
    /// silently — so the switches in the UI did nothing at all.
    @discardableResult
    static func set(label: String, enabled: Bool) -> Bool {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let plist = dir + "/\(label).plist"
        let uid = getuid()

        if enabled {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            guard let job = jobDefinition(for: label) else { return false }
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: job, format: .xml, options: 0) else { return false }
            do { try data.write(to: URL(fileURLWithPath: plist)) } catch { return false }

            run(["bootout", "gui/\(uid)/\(label)"])          // clear any stale copy
            if run(["bootstrap", "gui/\(uid)", plist]) { return true }
            return run(["load", plist])                       // older fallback
        } else {
            _ = run(["bootout", "gui/\(uid)/\(label)"])
            try? FileManager.default.removeItem(atPath: plist)
            return true
        }
    }

    @discardableResult
    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The jobs Moe knows how to run.
    ///
    /// They launch through the app binary, not /bin/bash: macOS attributes Full
    /// Disk Access to the launching process, and a bash-launched job can never
    /// inherit the permission you granted to Memoe.app.
    private static func jobDefinition(for label: String) -> [String: Any]? {
        let exe = Bundle.main.executableURL?.path
            ?? "/Applications/Memoe.app/Contents/MacOS/Moe"
        let logs = NSHomeDirectory() + "/.moe/logs"
        var job: [String: Any] = [
            "Label": label,
            "RunAtLoad": true,
            "StandardErrorPath": "\(logs)/\(label).err",
        ]
        switch label {
        case Launchd.jobsLabel:
            // One agent, not two. `com.moe.sync` and `com.moe.digest` ran the
            // same binary on two timers, and System Settings lists every
            // LaunchAgent by name — so a product that is one app appeared in
            // "Allow in Background" three times, which reads like something
            // that has spread rather than something that was installed.
            //
            // Ten minutes is what the context refresh needs. The hourly
            // digest this timer used to elect is gone: Hermes's
            // `moe-proactive` cron job does that work on its own clock.
            job["ProgramArguments"] = [exe, "--sync"]
            job["StartInterval"] = 600
        case "com.memoe.app":
            job["ProgramArguments"] = ["/usr/bin/open", "-a", "/Applications/Memoe.app"]
            job["KeepAlive"] = false
        default:
            return nil
        }
        return job
    }
}


