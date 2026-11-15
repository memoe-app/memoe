import AppKit
import MoeBrain
import MoeDesign
import MoeMeeting
import MoeVoice
import SwiftUI

/// `Moe --settings-snapshot <dir>`: every Settings pane, plus Memory and
/// Connections from the main window, rendered to PNG at the window's real
/// size in light and dark — so a redesign can be looked at without
/// launching the app, and a later change can be diffed against it.
///
/// Rendered once, synchronously: whatever a pane loads in the background
/// (the brain's status, the connections list, the memory files) is not
/// waited for, so these show the layout and the copy, not live data. A
/// scratch home keeps the render from reading or writing anything real.
@MainActor
enum SettingsSnapshot {
    static let window = CGSize(width: 720, height: 540)
    static let main = CGSize(width: 840, height: 560)

    /// - Parameter only: render just the panes whose name contains this, or
    ///   everything when empty. It exists because the wait above is per
    ///   image: 64 images × a 25-second settle is half an hour to look at
    ///   one pane, so without a filter "photograph it before you believe it"
    ///   costs more than skipping the photograph, and people skip it.
    static func run(_ directory: String, only: String = "") -> Int32 {
        let scratch = (directory as NSString).appendingPathComponent(".moe-home")
        setenv("MOE_HOME", scratch, 1)
        setenv("HERMES_HOME", scratch, 1)

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot write to \(directory): \(error)\n".utf8))
            return 1
        }

        // AppKit's text stack wants an application object. This creates one;
        // it starts no run loop, opens no window and activates nothing.
        _ = NSApplication.shared

        var config = Config()
        config.hermesKey = "settings-snapshot"
        config.dictationContactsNames = false
        config.wakeWordEnabled = false
        let conductor = Conductor(config: config)

        var written = 0
        var failed = 0
        func shoot(_ name: String, size: CGSize, _ view: some View) {
            guard only.isEmpty || name.contains(only) else { return }
            for dark in [false, true] {
                let v = view
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let path = (directory as NSString).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                if write(v, to: path, size: size, appearance: dark ? .darkAqua : .aqua) {
                    written += 1
                    if !dark { print(name) }
                } else {
                    failed += 1
                    FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                }
            }
        }

        let panes: [(String, MainWindow.Section)] = [
            ("settings-01-brain", .brain),
            ("settings-02-voice", .voice),
            ("settings-03-meeting-capture", .meetingCapture), ("settings-04-permissions", .permissions),
            ("settings-04b-reminders", .reminders),
            ("settings-05-background", .background),
            ("settings-05b-activity", .activity), ("settings-05c-chats", .chats),
            ("settings-05d-skills", .skills), ("settings-05e-usage", .usage),
            ("settings-06-away", .away), ("settings-07-privacy", .privacy),
            ("settings-08-about", .licenses),
        ]
        for (name, section) in panes {
            shoot(name, size: window,
                  SettingsView(conductor: conductor, selection: SettingsWindow.Selection(section)))
        }
        let pane = CGSize(width: window.width - 172 - 6, height: window.height - 12)
        // Every pane on its own, tall enough to see the whole page — the
        // window's height hides everything below the fold. "tall-" so
        // `… tall-` renders just these.
        for (name, section) in panes + [("settings-09-history-usage", .usage), ("settings-09-history-chats", .chats),
                                        ("settings-09-background-reminders", .reminders), ("settings-09-brain-skills", .skills)] {
            let short = name.replacingOccurrences(of: "settings-", with: "")
            shoot("tall-\(short)", size: CGSize(width: window.width, height: 1800),
                  SettingsView(conductor: conductor, selection: SettingsWindow.Selection(section)))
        }
        // Settings › Voice (design D, 2026-09-25): the page as a fresh
        // install sees it, then with every switch that opens something on
        // and "More" open. "final-" so `… final` renders just these.
        shoot("final-voice-window", size: window,
              SettingsView(conductor: conductor, selection: SettingsWindow.Selection(.voice)))
        shoot("final-voice-default", size: pane,
              VoicePane(conductor: conductor).background(Theme.raised))
        shoot("final-voice-default-tall", size: CGSize(width: pane.width, height: 1000),
              VoicePane(conductor: conductor).background(Theme.raised))
        var opened = config
        opened.wakeWordEnabled = true
        opened.bargeIn = true
        opened.conversationMode = true
        let openConductor = Conductor(config: opened)
        shoot("final-voice-open-tall", size: CGSize(width: pane.width, height: 2000),
              VoicePane(conductor: openConductor, posed: .init(moreOpen: true)).background(Theme.raised))
        // "Teach Moe its name", the card, in every step it has: each pose
        // is reached by sending the flow the events that lead there.
        for pose in WakeTeachFlow.poses() {
            let intro = pose.name.hasSuffix("intro")
            shoot(pose.name, size: WakeTeachCard.size,
                  WakeTeachCard(model: WakeTeachModel(flow: pose.flow, driver: InertWakeTeachDriver(), level: pose.level),
                                clipsOnMac: intro || pose.name.hasSuffix("result") ? 20 : 0,
                                previous: intro
                                    ? "Last taught on 20 September: Moe caught 10 of your 12 “Hey Moe”s and 1 of the 8 near misses."
                                    : nil))
        }
        // The chat thread: both sides, a note, what went with a message, and
        // what is waiting in the box. `Conductor.turns` cannot be posed, so
        // the rows are drawn directly — the same `TurnRow` the window uses.
        shoot("main-chat-turns", size: CGSize(width: main.width - 172, height: 820),
              VStack(spacing: 0) {
                  ChatCopyBar(selecting: .constant(false)) {}
                  ChatTurnsPose()
              }.background(Theme.raised))
        // The whole window on the Chat page, in every conversation state
        // (`ChatPoses`), in a *titled* window built the way AppDelegate
        // builds the real one: full-size content under a transparent
        // titlebar, with the traffic lights drawn. A borderless window has
        // no titlebar, so the greeting clipped under it (deep dive §2.1)
        // could not be seen in any shot. "main-chat-window" draws just these.
        #if DEBUG
        for pose in ChatPoses.all {
            let name = "main-chat-window-\(pose.name)"
            guard only.isEmpty || name.contains(only) else { continue }
            conductor.pose(pose.state)
            for dark in [false, true] {
                let path = (directory as NSString).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                if writeTitled(MainWindow(conductor: conductor, section: .chat)
                                .environment(\.colorScheme, dark ? .dark : .light),
                               to: path, size: CGSize(width: 900, height: 600),
                               appearance: dark ? .darkAqua : .aqua) {
                    written += 1
                    if !dark { print(name) }
                } else {
                    failed += 1
                    FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                }
            }
        }
        conductor.pose(Conductor.SnapshotState())
        #endif
        shoot("main-chat-selecting", size: CGSize(width: main.width - 172, height: 60),
              VStack(spacing: 0) {
                  ChatCopyBar(selecting: .constant(true)) {}
                  Spacer(minLength: 0)
              }.background(Theme.raised))
        // The Fix card in Chat (docs/FIXABLE-FAILURES.md slice 3): ticket
        // #8's Chrome data, CuaDriver's own row, and one with nothing to press.
        shoot("main-chat-fix-cards", size: CGSize(width: main.width - 172, height: 220),
              VStack(spacing: 0) {
                  ForEach([ToolFix(code: .tccAppData, owner: .app, pane: "Privacy_AllFiles", subject: "Google Chrome"),
                           ToolFix(code: .tccDriverAccessibility, owner: .driver, pane: "Privacy_Accessibility",
                                   subject: "CuaDriver", restart: "driver"),
                           ToolFix(code: .profileLocked, subject: "Google Chrome")]
                            .compactMap { FixOffer($0) }) { offer in
                      ChatFixBanner(offer: offer, perform: {}, dismiss: {})
                  }
                  Spacer(minLength: 0)
              }.background(Theme.raised))
        // Settings › Background › Noticed: the situations engine's monitor
        // (docs/PROACTIVE-MEMORY.md §9), posed with the demo report.
        // `NoticedReport.demo` is DEBUG-only, so this shot is too: without
        // the guard the release build — every install and every ship —
        // failed to compile.
        #if DEBUG
        // The inbox (docs/INBOX.md): the reading card over the desktop, a
        // Ready-for-you card with its draft, and the app's Inbox page.
        // "inbox-" so `… inbox` renders just these.
        InboxSamples.writeOffer()
        var inboxState = Conductor.SnapshotState()
        inboxState.notices = InboxSamples.items()
        conductor.pose(inboxState)
        let posedOffer = SituationOffer.load(id: "sit_demo")
        shoot("inbox-card-brief", size: NoticeCardWindow.size,
              NoticeCardView(conductor: conductor, noticeID: "sample-3")
                  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        shoot("inbox-card-ready", size: NoticeCardWindow.size,
              NoticeCardView(conductor: conductor, noticeID: "sample-1", posedOffer: posedOffer)
                  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        shoot("inbox-card-reminder", size: CGSize(width: NoticeCardWindow.size.width, height: 360),
              NoticeCardView(conductor: conductor, noticeID: "sample-0")
                  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        shoot("inbox-page", size: CGSize(width: 1040, height: 680),
              InboxPane(conductor: conductor, selected: "sample-3").background(Theme.raised))
        conductor.pose(Conductor.SnapshotState())
        #endif
        #if DEBUG
        shoot("settings-05f-background-noticed", size: CGSize(width: pane.width, height: 900),
              ScrollView { NoticedTab(demo: .demo).padding(.horizontal, Theme.Space.wide)
                               .padding(.vertical, Theme.Space.roomy) }.background(Theme.raised))
        #endif
        // The engine that is not in the app, before it has been fetched:
        // the Download row is a button here, not a size.
        shoot("settings-02d-voice-pocket-download", size: CGSize(width: pane.width, height: 1000),
              VoicePane(conductor: conductor,
                        posed: .init(engine: .pocket, pocketDownloaded: false)).background(Theme.raised))
        shoot("settings-02e-voice-pocket-downloading", size: CGSize(width: pane.width, height: 1000),
              VoicePane(conductor: conductor,
                        posed: .init(engine: .pocket, pocketDownloaded: false, downloading: true,
                                     downloadFraction: 0.38, downloadNote: "Downloading — 2 of 6 files so far."))
              .background(Theme.raised))
        // Settings › Away in every state, Privacy paid and free, and the
        // consent screens — the closed half's pages, when this build has one
        // (`CloudLink.settingsShots`). Nothing there reaches the edge.
        for shot in Cloud.link.settingsShots(conductor, paneWidth: pane.width) {
            shoot(shot.name, size: shot.size, shot.view)
        }
        // The other half of Reminders: the new-reminder form, which no
        // list state can reach on its own.
        shoot("settings-04c-reminders-new", size: pane,
              RemindersPane(conductor: conductor, composing: true).background(Theme.raised))
        shoot("settings-04d-reminders-form", size: pane,
              RemindersPane(conductor: conductor, template: "custom-reminder").background(Theme.raised))
        // The halves of Activity and Chats no scroll position can reach:
        // the upkeep rows and the raw log are both folded away by default,
        // and Chats opens on a list rather than on a transcript or a
        // search. Every one of those is a layout that ships unlooked-at
        // otherwise.
        shoot("settings-05b2-activity-open", size: pane,
              ActivityPane(conductor: conductor, showingUpkeep: true, showingLog: true)
                .background(Theme.raised))
        shoot("settings-05c2-chats-search", size: pane,
              ChatsPane(conductor: conductor, searching: "meeting").background(Theme.raised))
        // And the transcript, on whichever conversation is newest —
        // whatever the scratch home happens to hold, which on a home with
        // nothing in it is the "couldn't open that" state and is itself
        // worth looking at.
        shoot("settings-05c3-chats-reading", size: pane,
              ChatsPane(conductor: conductor,
                        opening: Chats.library().threads.first?.id ?? "none")
                .background(Theme.raised))
        // The halves of Skills and Usage no scroll position can reach: the
        // pane opens on everything, and the three filtered lists — the one
        // that matters most among them, "can't run" — are each a different
        // layout with a different empty state. Usage's day-by-day list is
        // folded away for the same reason Activity's raw log is.
        //
        // **Rendered TALL**, and that is not a stylistic choice. Both of
        // these panes run to several screens, and a 528pt canvas shows
        // their first section and nothing else — so every row below the
        // fold would ship unlooked-at, which is exactly the failure
        // rendering exists to catch. `tall` is a canvas, not a window
        // size: nothing in the app is ever this shape.
        let tall = CGSize(width: pane.width, height: 2200)
        shoot("settings-05d2-skills-trouble", size: tall,
              SkillsPane(conductor: conductor, filter: .trouble).background(Theme.raised))
        shoot("settings-05d3-skills-off", size: tall,
              SkillsPane(conductor: conductor, filter: .off).background(Theme.raised))
        shoot("settings-05e2-usage-days", size: tall,
              UsagePane(conductor: conductor, showingDays: true).background(Theme.raised))
        // Meetings: the list, and one meeting whose notes were never written
        // — "Write the notes" before, during, and after it failed.
        shoot("main-meetings-list", size: CGSize(width: main.width - 172, height: main.height),
              MeetingsPane(conductor: conductor))
        var noNotes = MeetingRecord(startedAt: Date(timeIntervalSince1970: 1_762_900_000), durationSeconds: 2520,
                                    folder: scratch + "/meetings/2026-11-11-1706",
                                    summaryFailure: "writing the notes did not finish within 240 s")
        noNotes.incomplete = false
        let notesPoses: [(String, MeetingNotesWriter.State)] = [
            ("idle", .idle), ("writing", .writing),
            ("failed", .failed(MeetingNotesRewrite.Failure.brain("").sentence)),
        ]
        for (name, state) in notesPoses {
            shoot("main-meeting-no-notes-\(name)", size: CGSize(width: main.width - 172, height: 400),
                  MeetingsPane(conductor: conductor, posed: .init(record: noNotes, notes: state)))
        }
        shoot("main-memory", size: main, MemoryPane(conductor: conductor, demo: .init(tab: .you)))
        // The same page with something in it. The scratch home is empty, so
        // the render above is the empty state; these write a small, invented
        // profile — people, events, questions, an unsure line, past lines,
        // Hermes lines — and draw it as it is, mid-edit, under the mouse,
        // and with the past open.
        //
        // `MOE_SNAPSHOT_MEMORY_FROM=<a Moe home>` draws a real profile
        // instead: its memory/profile and $HERMES_HOME/memories
        // (`MOE_SNAPSHOT_HERMES_FROM`, default ~/.hermes) are COPIED into the
        // scratch home first, so the render reads them and never writes them.
        if only.isEmpty || "main-memory-filled".contains(only) || only.hasPrefix("main-memory-") {
            let home = URL(fileURLWithPath: scratch, isDirectory: true)
            if let from = ProcessInfo.processInfo.environment["MOE_SNAPSHOT_MEMORY_FROM"], !from.isEmpty {
                let hermes = ProcessInfo.processInfo.environment["MOE_SNAPSHOT_HERMES_FROM"]
                    ?? NSHomeDirectory() + "/.hermes"
                MemoryFixture.copy(home: home, from: URL(fileURLWithPath: from, isDirectory: true),
                                   hermes: URL(fileURLWithPath: hermes, isDirectory: true))
            } else {
                MemoryFixture.write(home: home)
            }
        }
        // Design B: one picture per section, and the states a mouse or a
        // keyboard would make — a line under the pointer, a line mid-edit,
        // the add field open. `memoryTall` fits a long real People list.
        let memoryTall = CGSize(width: main.width, height: 900)
        let memoryShots: [(String, MemoryPane.Demo)] = [
            ("main-memory-filled", .init(tab: .you)),
            ("main-memory-you-hover", .init(tab: .you, state: .hover)),
            ("main-memory-editing", .init(tab: .you, state: .editing)),
            ("main-memory-you-adding", .init(tab: .you, state: .adding)),
            ("main-memory-people", .init(tab: .people)),
            ("main-memory-people-hover", .init(tab: .people, state: .hover)),
            ("main-memory-now", .init(tab: .now)),
            ("main-memory-now-adding", .init(tab: .now, state: .adding)),
            ("main-memory-people-discuss", .init(tab: .people, state: .discuss)),
            // To check, one card at a time: each card in turn, "Something
            // else…" open on the first and on a line, and all caught up.
            ("main-memory-check", .init(tab: .check)),
            ("main-memory-check-card-2", .init(tab: .check, state: .card(1))),
            ("main-memory-check-card-3", .init(tab: .check, state: .card(2))),
            ("main-memory-check-card-4", .init(tab: .check, state: .card(3))),
            ("main-memory-check-card-5", .init(tab: .check, state: .card(4))),
            ("main-memory-check-other", .init(tab: .check, state: .card(0, other: true))),
            ("main-memory-check-other-line", .init(tab: .check, state: .card(4, other: true))),
            ("main-memory-check-done", .init(tab: .check, state: .caughtUp)),
            ("main-memory-chats", .init(tab: .chats)),
            ("main-memory-chats-hover", .init(tab: .chats, state: .hover)),
            ("main-memory-past", .init(tab: .past, state: .hover)),
        ]
        for (name, demo) in memoryShots {
            shoot(name, size: memoryTall, MemoryPane(conductor: conductor, demo: demo))
        }
        // The window at its narrowest, where the card's buttons once broke
        // mid-word ("Ye / s"): the yes-or-no card and the open question.
        let memoryNarrow = CGSize(width: 600, height: 700)
        shoot("main-memory-check-narrow", size: memoryNarrow,
              MemoryPane(conductor: conductor, demo: .init(tab: .check, state: .card(1))))
        shoot("main-memory-check-open-narrow", size: memoryNarrow,
              MemoryPane(conductor: conductor, demo: .init(tab: .check, state: .card(4))))
        shoot("main-connections", size: main,
              ConnectionsView(conductor: conductor, mode: .services).background(Theme.raised))
        // The brokered services, with their marks. They sit hundreds of rows
        // down a scroll view, so the only way to look at them is to arrive
        // with something typed — and looking at them is the point: whether
        // each one drew its company's logo or a coloured letter is a fact no
        // JSON dump can report.
        shoot("main-connections-brokered", size: main,
              ConnectionsView(conductor: conductor, mode: .services, searching: "zoho")
                .background(Theme.raised))
        // Connections › Chrome (ticket #13), one picture per state. The
        // reports are the ones measured against a throwaway Chrome for
        // Testing (ChromeExtensionTests quotes them); a demo model never
        // polls or runs a script.
        func chromeReport(host: Bool, on: Bool, connected: Bool, fileAccess: Bool = false,
                          stale: Bool = false) -> ChromeLaneReport {
            let w = fileAccess ? #"[{"code": "file_access_on", "text": "Moe's Chrome extension is allowed to open files on this Mac. Moe never uses that; turn it off in Chrome › Extensions › Memoe › \"Allow access to file URLs\"."}]"# : "[]"
            return ChromeLaneReport.parse(#"{"host_installed": \#(host), "enabled": \#(on), "connected": \#(connected), "warnings": \#(w), "error": null, "source": "\#(stale ? ChromeExtensionModel.demoStale : "demo")"}"#)!
        }
        // The facts are what the app reads for itself (ChromeExtensionProbe):
        // one picture per way the extension can be there and not working.
        let goodHost = ChromeHostManifest.Status(present: true, missingIDs: [], launcherOK: true)
        let seen = ChromeSeen(extensionID: ChromeExtension.storeID, at: .distantPast)
        let elsewhere = ChromeProfiles.Scan.read([
            .init(dir: "Default", name: "Personal", open: true, ids: []),
            .init(dir: "Profile 1", name: "Work", open: false, ids: [ChromeExtension.storeID])])
        let chromeFacts: [(String, ChromeLaneReport, ChromeLaneFacts?)] = [
            ("not-installed", chromeReport(host: false, on: false, connected: false), nil),
            ("added", chromeReport(host: true, on: true, connected: false),
             ChromeLaneFacts(host: goodHost, seen: nil, profiles: .unknown, chromeRunning: true)),
            ("waiting", chromeReport(host: true, on: true, connected: false),
             ChromeLaneFacts(host: goodHost, seen: seen, profiles: .unknown, chromeRunning: false)),
            ("waiting-chrome-open", chromeReport(host: true, on: true, connected: false),
             ChromeLaneFacts(host: goodHost, seen: seen, profiles: .unknown, chromeRunning: true)),
            ("cant-reach", chromeReport(host: true, on: true, connected: false),
             ChromeLaneFacts(host: .init(present: true, missingIDs: [ChromeExtension.storeID], launcherOK: true),
                             seen: seen, profiles: .unknown, chromeRunning: true)),
            ("wrong-profile", chromeReport(host: true, on: true, connected: false),
             ChromeLaneFacts(host: goodHost, seen: nil, profiles: elsewhere, chromeRunning: true)),
            ("connected", chromeReport(host: true, on: true, connected: true), nil),
            ("connected-file-access", chromeReport(host: true, on: true, connected: true, fileAccess: true), nil),
            ("off", chromeReport(host: true, on: false, connected: false), nil),
            ("update", chromeReport(host: true, on: true, connected: true, stale: true), nil)]
        for (name, r, f) in chromeFacts {
            shoot("main-connections-chrome-\(name)", size: main,
                  ConnectionsView(conductor: conductor, mode: .services, selecting: ChromeExtension.rowID,
                                  chrome: ChromeExtensionModel(demo: r, facts: f)).background(Theme.raised))
        }
        shoot("main-reach", size: main,
              ConnectionsView(conductor: conductor, mode: .reach).background(Theme.raised))

        posedConnections(conductor, only: only) { name, size, view in shoot(name, size: size, view) }

        print("\n\(written) written to \(directory)\(failed == 0 ? "" : ", \(failed) failed")")
        return failed == 0 ? 0 : 1
    }

    /// The window's smallest size, the size in the owner's report of
    /// 2026-11-12, and a large one.
    static let windowSizes: [(name: String, size: CGSize)] = [
        ("min", CGSize(width: 820, height: 560)),
        ("1190x790", CGSize(width: 1190, height: 790)),
        ("large", CGSize(width: 1600, height: 1000)),
    ]

    /// The whole main window on Connections, with invented rows
    /// (`ConnectionsPose`), at each of `windowSizes` — "posed-" renders just
    /// these. The whole window and not the pane, because what went wrong was
    /// the window's: a detail side taller than the glass pushed everything,
    /// the list and the sidebar included, off the top and the bottom. Each
    /// line printed after a name is the least height that window's pane asks
    /// for; over the window's own height is the fault, in a number.
    ///
    /// Last in the run: the list stays posed afterwards, so nothing after
    /// this may want the real one.
    private static func posedConnections(_ conductor: Conductor, only: String,
                                         shoot: (String, CGSize, AnyView) -> Void) {
        let checked = Date()
        for pose in ConnectionsPose.all {
            for (sizeName, size) in windowSizes {
                let name = "posed-connections-\(pose.name)-\(sizeName)"
                guard only.isEmpty || name.contains(only) else { continue }
                ConnectionsModel.shared.pose(ConnectionsPose.rows(pose.name))
                let window = MainWindow(conductor: conductor, section: .connections,
                                        selectingConnection: pose.select, connectionsChecked: checked)
                shoot(name, size, AnyView(window))
                report(window.content, in: CGSize(width: size.width - 186, height: size.height))
            }
        }
        // The other panes the window draws, at its smallest: built the same
        // way or not, each has to fit.
        ConnectionsModel.shared.pose(ConnectionsPose.rows(ConnectionsPose.gmailThree))
        for section in MainWindow.Section.sidebarItems where section != .connections {
            let name = "posed-min-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
            guard only.isEmpty || name.contains(only) else { continue }
            let window = MainWindow(conductor: conductor, section: section)
            shoot(name, windowSizes[0].size, AnyView(window))
            report(window.content, in: CGSize(width: windowSizes[0].size.width - 186, height: windowSizes[0].size.height))
        }
        // And every Settings pane at that window's smallest (640 × 460).
        let settingsMin = CGSize(width: 640, height: 460)
        for section in MainWindow.Section.allCases
        where section.place == .settings && SettingsWindow.Selection.listed(section) {
            let name = "posed-settings-min-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
            guard only.isEmpty || name.contains(only) else { continue }
            let window = SettingsView(conductor: conductor, selection: SettingsWindow.Selection(section))
            shoot(name, settingsMin, AnyView(window))
            report(window.content, in: CGSize(width: settingsMin.width - 172, height: settingsMin.height))
        }
        // The sheet, in the steps this change is about: an "Add another" that
        // failed (the words are the script's — here a certificate failure),
        // one account going, gone, and a removal that failed.
        guard let gmail = ConnectionsPose.rows(ConnectionsPose.gmailThree).first(where: { $0.id == "composio/gmail" }),
              let account = gmail.accounts.dropFirst().first else { return }
        let label = gmail.accountLabel(account)
        let steps: [(String, ConnectFlow.Phase, Bool)] = [
            ("add-failed", .failed("Couldn't reach the sign-in service: the secure connection could not be checked (SSL: CERTIFICATE_VERIFY_FAILED)."), false),
            ("remove-working", .working("Removing \(label)…"), true),
            ("remove-done", .done("\(label) is removed. The others stay connected."), true),
            ("remove-failed", .failed("couldn't remove your gmail account at Composio just now (no answer) — nothing was disconnected; try again"), true),
        ]
        for (step, phase, removing) in steps {
            let flow = ConnectFlow()
            flow.pose(gmail, phase: phase, removing: removing)
            shoot("posed-sheet-\(step)", CGSize(width: 460, height: 240),
                  AnyView(ConnectSheet(flow: flow).background(Theme.raised)))
        }
    }

    /// Prints the least height `pane` asks for beside the height it gets.
    /// More than it gets is the fault, in a number: SwiftUI draws it at that
    /// height anyway, centred, with both ends outside the window.
    private static func report(_ pane: some View, in size: CGSize) {
        let least = minimumSize(of: pane, width: size.width).height.rounded(.up)
        print("  least height \(Int(least)) of \(Int(size.height))" + (least > size.height ? "  DOES NOT FIT" : ""))
    }

    /// The smallest size a view accepts at `width`: what SwiftUI reports as
    /// its minimum, read through AppKit the way a window reads it. A pane
    /// whose least height is more than the window gives it does not shrink —
    /// it is drawn at that height, centred, with both ends cut off.
    static func minimumSize(of view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 0))
    }

    /// How long the run loop is pumped before the picture is taken.
    ///
    /// Two seconds settles layout and lets a pane's own `Task`s finish, which
    /// is right for every pane that draws from files. Connections is not one
    /// of those: it shells out to `hermes-catalog.py`, which reads the whole
    /// Hermes checkout, so at two seconds its photograph is of a spinner
    /// saying "Looking at what is already set up on this Mac" — a real
    /// screenshot of nothing, and one you would happily paste into a report
    /// believing you had looked at the list.
    ///
    /// `MOE_SNAPSHOT_SETTLE=<seconds>` waits longer. Not a longer default:
    /// 64 images × the wait is the cost of every other pane, and they do not
    /// need it.
    static var settle: TimeInterval {
        guard let s = ProcessInfo.processInfo.environment["MOE_SNAPSHOT_SETTLE"],
              let v = Double(s), v > 0, v <= 120 else { return 2.0 }
        return v
    }

    /// Drawn in a real, never-shown window rather than `ImageRenderer`:
    /// the renderer skips anything AppKit-backed — every scroll view, text
    /// field and spinner — which on these panes is the whole page. The
    /// run loop is pumped for a moment so layout settles and the loads a
    /// pane starts on appearing (`Task`s on the main actor) get to finish.
    static func write(_ view: some View, to path: String, size: CGSize,
                      appearance: NSAppearance.Name) -> Bool {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }

        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.isReleasedWhenClosed = false
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        window.close()
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

extension SettingsSnapshot {
    /// The main window as the app makes it (`AppDelegate.showWindow`): a
    /// titled window with full-size content and a transparent, hidden
    /// title. The picture is taken of the window's frame view, not its
    /// content view, so the traffic lights are in it.
    static func writeTitled(_ view: some View, to path: String, size: CGSize,
                            appearance: NSAppearance.Name) -> Bool {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }

        let hosting = NSHostingController(rootView: AnyView(view))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        let frameView = window.contentView?.superview ?? hosting.view
        frameView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        frameView.layoutSubtreeIfNeeded()

        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        window.close()
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// An invented profile for the Memory snapshots: nobody real, every shape
/// the page draws — people, events, a low-confidence line, questions,
/// archived lines, Hermes lines.
enum MemoryFixture {
    /// A real profile, copied — never linked — into the scratch home, so the
    /// render reads it and cannot write it.
    static func copy(home: URL, from moeHome: URL, hermes: URL) {
        let fm = FileManager.default
        let pairs = [(moeHome.appendingPathComponent("memory/profile"), home.appendingPathComponent("memory/profile")),
                     (hermes.appendingPathComponent("memories"), home.appendingPathComponent("memories"))]
        for (src, dst) in pairs {
            try? fm.removeItem(at: dst)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src.resolvingSymlinksInPath(), to: dst)
        }
    }

    static func write(home: URL) {
        let profile = home.appendingPathComponent("memory/profile", isDirectory: true)
        let hermes = home.appendingPathComponent("memories", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        let files: [String: String] = [
            "summary.md": """
            # What Moe knows about you

            You run a small studio building websites for local businesses, mostly with Dana, and you are
            launching a second product this autumn. You work late, write short messages, and prefer a
            phone call to a long email.

            Family comes first on Fridays. You are learning Spanish and training for a half marathon in October.
            """,
            "identity.md": """
            # About you

            - Runs a two-person web studio with Dana [gmail, 2026-09-18, high]
            - Training for a half marathon in October [calendar, 2026-09-20, med]
            - Works from the studio on Tuesdays [calendar, 2026-09-10, med]
            - Works from home on Tuesdays [gmail, 2026-09-12, med]
            """,
            "people.md": """
            # People

            - **Dana Reyes** — co-founder of your studio; you talk most days [whatsapp, 2026-09-21, high]
            - **Sam Okafor** — client at the bakery on Main St; redesign in progress [gmail, 2026-09-19, high]
            - **Priya** — the user's sister; Sunday calls [imessage, 2026-09-20, high]
            - **Tom Keller** — accountant; files your quarterly taxes [gmail, 2026-09-02, med]
            - **Leah** — running partner, Tuesday and Thursday mornings [imessage, 2026-09-17, med]
            - **Marco** — landlord of the studio space [gmail, 2026-08-30, low]
            - **Ines** — Spanish tutor [calendar, 2026-09-16, med]
            """,
            "threads.md": """
            # Threads

            - Launching the booking product at the end of October [github, 2026-09-21, high]
            - Half marathon on October 12 [calendar, 2026-09-20, high]
            """,
            "archive.md": """
            # Archive

            ## Threads
            - Moved the studio to a new office in March [gmail, 2026-03-10, high]
            - Ran the spring bake sale for the school [imessage, 2026-04-02, med]

            ## People
            - **Jonah** — old flatmate; moved to Lisbon [gmail, 2026-02-11, low]
            """,
            "questions.md": """
            # Questions for you

            - Which is right: "Works from the studio on Tuesdays" or "Works from home on Tuesdays"?
            - Is "Half marathon on October 12" still on?
            - Is Marco still your landlord, or did that change with the move?
            - Are you still doing the Spanish lessons on Mondays?
            - One line reads "he ran one part of it and ran the other" — unclear who "he" is or what it refers to.
            """,
        ]
        for (name, text) in files {
            try? text.write(to: profile.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try? "Prefers to be called Alex.\n§\nLikes answers short, with the decision first.\n"
            .write(to: hermes.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try? "The studio's invoices go out on the 1st.\n§\nNever sends anything on Alex's behalf without reading it back first.\n"
            .write(to: hermes.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
    }
}
