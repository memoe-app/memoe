import AppKit
import MoeDesign
import SwiftUI

/// Settings › Running in the background: what Moe does on its own while
/// you work, in the words of what it does.
///
/// Three groups. "Speaking up" is the one switch for Moe getting your
/// attention. "Reminders" is where a reminder goes besides this screen —
/// the chats Moe can send to (`ReminderChannels`). "Keeping up" is the
/// ten-minute copy of today, and "Learning about you" is the daily read
/// back — two different clocks, which is why they are two groups.
///
/// Every connected thing appears in three of those groups, once each, and
/// the three answers are separate: may Moe MENTION it, may Moe KEEP a copy
/// of today's, may Moe READ IT BACK and learn. They were one switch, and a
/// person who had switched their chats off under "what it may read" still
/// heard Moe talk about a message from them — that row is about learning,
/// and speaking up had no per-source control at all. A new connection
/// appears in all three; a disconnected one leaves. Nothing is named in
/// code: the list is whatever `consent.sh list` reports.
///
/// What left this pane: "Refresh now" and the log paths (nobody should
/// need either; the ten-minute job says when it last looked), and
/// Uninstall, which went altogether: *Erase Memoe from this Mac* in Privacy is
/// the one way out (docs/DEFAULTS.md row 41).
struct BackgroundPane: View {
    @ObservedObject var conductor: Conductor
    @State private var jobLoaded = false
    @State private var lastSync: String = "—"
    /// The daily learn pass's recorded answer. Not a Config key: it lives in
    /// the same consent file every other "yes, read this" answer lives in,
    /// and the job itself reads that file — see BackgroundLearning.
    @State private var learning: BackgroundLearning.State = .unset
    @State private var lastPass: BackgroundLearning.LastPass?
    @State private var learningBusy = false
    @State private var jobNote = ""
    /// The chats a reminder can go to besides this screen. Nil until asked;
    /// empty when nothing is connected.
    @State private var channels: [ReminderChannels.Platform]?
    @State private var channelsAsked = false
    /// What the daily pass may read, one answer per source, and whether what
    /// it learns becomes Moe's memory.
    @State private var sources: [BackgroundLearning.Source]?
    @State private var seeding: BackgroundLearning.State = .unset
    /// Answers flipped on this screen that a list still being built must
    /// not undo. A switch is the whole truth the moment it is touched; the
    /// file is written behind it, and a list that started before the flip
    /// (they take up to ten seconds) carries the answer from before. Each
    /// entry remembers which flip it was, so the first list that started
    /// after it can let it go.
    @State private var flipped: [String: Flip] = [:]
    @State private var flips = 0
    @State private var lastFull: Date = .distantPast

    struct Flip { let state: BackgroundLearning.State; let seq: Int }
    /// The same idea for the clock answers, which are not consent: a switch
    /// moves now, the file is written behind it, and a list that started
    /// first cannot drag it back. Keyed source+key ("whatsapp/speak").

    /// Which subject is on screen. See `tabs`.
    @State private var tab = 0
    /// What the background jobs have done and cost. Nil until asked, and
    /// nil again if the reader could not run — which the tab says, rather
    /// than drawing zeros that read as "nothing has ever happened".
    @State private var activity: [JobActivity.Job]?
    @State private var activityAsked = false
    /// When each of Moe's own jobs last ran and last worked (`JobHealth`).
    @State private var health: JobHealth.Snapshot?

    /// The Activity tab: one block per background job, in the words of
    /// what it did rather than the job's own name.
    ///
    /// Two things here are deliberately not merged into one number. A job
    /// that runs on a subscription has no price at all, and a job on an
    /// API key has an estimate from published rates rather than a bill; a
    /// single "spent this month" figure would be a lie in one direction or
    /// the other. So each job says its own basis, in its own words.
    @ViewBuilder
    private var activityTab: some View {
        SettingGroup(title: "What has been running") {
            if activity == nil, !activityAsked {
                checking("Looking at what has run…")
            }
            if let activity {
                ForEach(Array(activity.enumerated()), id: \.element.id) { i, j in
                    SettingRow(
                        title: j.title,
                        detail: [j.state, occurrence(j),
                                 health?.jobs[j.name].flatMap { JobHealth.line($0) } ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " "),
                        note: j.cost.basis == "none" ? nil
                            : "\(j.cost.tokens), \(j.cost.summary). \(j.cost.label)",
                        last: i == activity.count - 1
                    ) {
                        Text(j.enabled ? (j.isTrouble ? "needs a look" : "on") : "off")
                            .font(Theme.Typo.ui(12))
                            .foregroundStyle(j.isTrouble ? Theme.warn : Theme.ink3)
                    }
                }
                if let stale = health.flatMap({ JobHealth.staleLine($0) }) {
                    Text(stale)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if activity.isEmpty {
                    Text("Nothing is scheduled yet.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if activityAsked {
                Text("Couldn't read the run history. Moe's thinking part keeps it; it may be starting up.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Text("A plan you subscribe to has no separate charge; a key you pay per use is priced from published rates, an estimate and not your bill.")
            .font(Theme.Typo.prose(12.5))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    /// "45 times in the last 7 days, 24 of them failed" — the sentence a
    /// person can act on, and the failure count only when there is one.
    private func occurrence(_ j: JobActivity.Job) -> String {
        if j.runs == 0 { return "" }
        let times = j.runs == 1 ? "Once" : "\(j.runs) times"
        let window = j.windowDays == 1 ? "today" : "in the last \(j.windowDays) days"
        return j.failures == 0
            ? "\(times) \(window)."
            : "\(times) \(window), \(j.failures) of them failed."
    }

    /// A row is the connection, and its switch sets every answer the
    /// connection has — BackgroundLearning.Row, shared with the first-run
    /// step and the Memory page's sheet so all three draw the same list.
    typealias Row = BackgroundLearning.Row

    private func state(of s: BackgroundLearning.Source) -> BackgroundLearning.State {
        flipped[s.name]?.state ?? s.state
    }

    private var seedingState: BackgroundLearning.State {
        flipped[BackgroundLearning.seeding]?.state ?? seeding
    }

    /// Every connected source, merged by connection — BackgroundLearning.rows,
    /// with a switch the person just moved winning over the file.
    private var rows: [Row] { BackgroundLearning.rows(sources, state: state(of:)) }

    /// Three tabs since 2026-09-28 (it was six; the owner asked for three,
    /// "voice style"): what Moe may bring up and where reminders go, the
    /// reminders themselves (Settings › Reminders until then), and what it
    /// keeps up with and learns — with the run history and the Noticed
    /// monitor folded under More there.
    static let tabs = ["Speaking up", "Reminders", "Keeping up"]

    init(conductor: Conductor, start: MainWindow.Section? = nil) {
        self.conductor = conductor
        _tab = State(initialValue: start == .reminders ? 1 : 0)
    }

    @State private var moreOpen = false
    @Environment(\.settingSpotlight) private var spotlight

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Running in the background")
            HStack {
                PaneTabs(tabs: Array(Self.tabs.enumerated()).map { ($0.offset, $0.element) },
                         selection: $tab)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, Theme.Space.base)
            if tab == 1 {
                RemindersPane(conductor: conductor, embedded: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if tab == 0 { speakingUp; deliveries } else { keepingUp; learningGroup; more }
                        if !jobNote.isEmpty {
                            Text(jobNote)
                                .font(Theme.Typo.ui(12))
                                .foregroundStyle(Theme.warn)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                }
            }
        }
        .background(Theme.raised)
        // Moe opened Settings on a row under "Keeping up" (or its More).
        .onChange(of: spotlight, initial: true) { _, title in
            guard let under = SettingSpotlight.under(title) else { return }
            if under.hasPrefix("Keeping up") { tab = 2 }
            if under.hasSuffix("More") { moreOpen = true }
        }
        .onAppear { reload(full: true) }
        // The rows come from Hermes's own connection list. A person connects
        // Supabase in the Connections pane, comes back to this window — still
        // open, still showing the list from before — and cannot find it.
        // Re-read whenever the app comes to the front. The quick list is
        // enough for that (a new sign-in is a file, and the quick list reads
        // files); the Mac sources are asked again only if it has been a
        // couple of minutes, so clicking in and out of Moe is not a probe
        // of every source each time.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload(full: Date().timeIntervalSince(lastFull) > 120)
        }
    }

    // MARK: - Speaking up

    private var speakingUp: some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("Speaking up")
            SettingRow(title: "Let Moe bring things up on its own",
                       detail: "The notch glows when something is about to matter — a meeting, a missed call, a message from someone you know. Moe never speaks first; reminders you set arrive either way.") {
                VoicePane.lever(Binding(get: { conductor.config.nudges },
                                        set: { conductor.setNudges($0) }))
            }
            if conductor.config.nudges {
                Calm.Reveal {
                    // Its own small job off the calendar copy the sync
                    // already keeps — no model, so no cost.
                    SettingRow(title: "Before something in my calendar") {
                        SettingMenu(value: conductor.config.calendarHeadsUpMinutes == 0
                                    ? "Don't" : "\(conductor.config.calendarHeadsUpMinutes) min") {
                            Button("Don't") { conductor.setCalendarHeadsUp(0) }
                            ForEach([2, 5, 10, 15, 30, 60], id: \.self) { m in
                                Button("\(m) minutes before") { conductor.setCalendarHeadsUp(m) }
                            }
                        }
                    }
                }
            }
            SettingRow(title: "Quiet hours, 10 pm to 8 am",
                       detail: "What Moe brings up waits for the morning before it reaches your phone. Reminders you set go when you said."
                        + (conductor.quietHoursArmed ? "" : " Waiting for a reading of your time zone.")) {
                VoicePane.lever(Binding(get: { conductor.config.quietHours },
                                        set: { conductor.setQuietHours($0) }))
            }
        }
    }

    /// Where a reminder goes besides this Mac.
    private var deliveries: some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("Where reminders reach you")
            SettingRow(title: "On this Mac", detail: "Always — spoken, and shown on the island.") {
                VoicePane.lever(.constant(true), enabled: false)
            }
            if channels == nil, !channelsAsked {
                checking("Looking at which chats Moe can send to…")
            }
            if let channels {
                ForEach(channels) { ch in
                    SettingRow(title: ch.title,
                               detail: ch.ready ? "" : "Message Moe there once, then come back.") {
                        // A platform with no home chat cannot be sent to.
                        VoicePane.lever(Binding(
                            get: { ch.ready && conductor.config.reminderChannels.contains(ch.name) },
                            set: { conductor.setReminderChannel(ch.name, on: $0) }),
                                        enabled: ch.ready)
                    }
                }
                if channels.isEmpty {
                    SettingRow(title: "Your phone",
                               detail: "Connect Telegram or WhatsApp under Connections and it appears here.") {
                        EmptyView()
                    }
                }
            } else if channelsAsked {
                Text("Couldn't find out which chats Moe can reach. Is Moe's thinking part running?")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    // MARK: - Keeping up

    /// One switch per source, the only one it has (owner, 2026-09-29):
    /// learn from it, keep it ready, watch it for things you'd want help
    /// with, mention what happens there. Off, Moe reaches it only when you
    /// ask. Every answer the source has goes with the switch (`set`), the
    /// same answer the question at connect writes.
    private var learnAndWatch: some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header(BackgroundLearning.Words.section)
            if sources == nil { checking("Looking at what's connected…") }
            if sources != nil, rows.isEmpty {
                Text("Nothing is connected yet. Connect something and Moe asks about it right then.")
                    .font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink3)
                    .padding(.vertical, 6)
            }
            ForEach(rows) { r in
                SettingRow(title: BackgroundLearning.Words.row(r.label),
                           detail: r.awaitingRecipe
                            ? "Tell Moe what you want to know about from \(r.label) first."
                            : r.detail,
                           note: r.on && r.profile.seed
                            ? (r.profile.seeded.map { "Last read back \($0)." } ?? "Not read back yet.")
                            : nil) {
                    VoicePane.lever(Binding(get: { r.on }, set: { set(r.names, on: $0) }),
                                    enabled: learning != .unavailable)
                }
            }
        }
    }

    private var keepingUp: some View {
        VStack(alignment: .leading, spacing: 0) {
            learnAndWatch
                .padding(.bottom, Theme.Space.section)
            Calm.header("Keeping up")
            SettingRow(title: "Look at what's connected every 10 minutes",
                       detail: "So Moe knows what is on today without going to look. Last looked: \(lastSync).") {
                VoicePane.lever(Binding(get: { jobLoaded }, set: { on in toggleJob(on) }))
            }
        }
    }

    private var learningGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Calm.header("Learning about you")
            // Model spend, and only that: whether Moe may THINK unprompted
            // on the person's own plan.
            SettingRow(title: "Let Moe think on its own, on my AI plan",
                       detail: "For the half-hourly look over your mail, calendar and follow-ups, and the daily read-back below. Off, none of your plan is spent on it.") {
                VoicePane.lever(Binding(get: { conductor.config.backgroundThinking },
                                        set: { conductor.setBackgroundThinking($0) }))
            }
            SettingRow(title: BackgroundLearning.Words.pass,
                       detail: "It keeps a short list of what it works out — who matters, what you're working on — on this Mac, in plain writing you can change."
                        + (conductor.config.backgroundThinking ? "" : " Paused while thinking on its own is off."),
                       note: lastPass?.words) {
                VoicePane.lever(Binding(get: { learning == .granted }, set: { setLearning($0) }),
                                enabled: !learningBusy && learning != .unavailable)
            }
            if learning == .granted {
                Calm.Reveal {
                    SettingRow(title: "Keep what it learns as Moe's memory") {
                        VoicePane.lever(Binding(get: { seedingState == .granted },
                                                set: { set([BackgroundLearning.seeding], on: $0) }),
                                        enabled: learning != .unavailable)
                    }
                }
            }
            if learning == .unavailable {
                Text("Moe can't find the file it records this in. Run the installer again.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
            }
            PaneLink(title: "See what Moe knows") {
                NotificationCenter.default.post(
                    name: .moeShowSection, object: nil,
                    userInfo: ["section": MainWindow.Section.memory.rawValue])
            }
            .padding(.top, Theme.Space.small)
        }
    }

    /// The run history and the Noticed monitor: looked at rarely, so under
    /// More, as Settings › Voice keeps its rarely-touched rows.
    private var more: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1).padding(.bottom, 4)
            Calm.MoreToggle(open: $moreOpen, hint: "what has been running, and what Moe noticed")
            if moreOpen {
                VStack(alignment: .leading, spacing: 26) {
                    activityTab
                    NoticedTab(conductor: conductor)
                }
                .padding(.leading, 20)
                .padding(.top, 10)
            }
        }
    }

    /// A quiet row holding the place of a list that is still being asked
    /// for, so the page does not jump when it arrives.
    private func checking(_ what: String) -> some View {
        HStack(spacing: Theme.Space.small) {
            ProgressView().controlSize(.small)
            Text(what)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
        }
        .padding(.top, Theme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload(full: Bool) {
        // One row, because there is now one agent (com.moe.jobs). When this
        // listed the two agents it replaced, both switches read *off* while
        // the job went on running; a consent control that lies about what is
        // running is worse than no control.
        jobLoaded = Launchd.loadedLabels().contains(Launchd.jobsLabel)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.brief.path),
           let date = attrs[.modificationDate] as? Date {
            let mins = Int(Date().timeIntervalSince(date) / 60)
            lastSync = mins < 1 ? "just now" : (mins < 60 ? "\(mins) min ago" : "\(mins / 60) h ago")
        } else {
            lastSync = "never"
        }

        // The run history reads two of Hermes's databases, so it is asked
        // for once per visit rather than on every switch flip.
        Task {
            let a = await ScriptRunner.offMain { JobActivity.all() }
            let h = await ScriptRunner.offMain { JobHealth.read() }
            await MainActor.run { activity = a; health = h; activityAsked = true }
        }
        Task {
            let s = await ScriptRunner.offMain { BackgroundLearning.state() }
            let l = await ScriptRunner.offMain { BackgroundLearning.lastPass() }
            await MainActor.run { learning = s; lastPass = l }
        }
        Task {
            let c = await ScriptRunner.offMain { ReminderChannels.available() }
            await MainActor.run {
                // Row 26: the first chat app ready is ticked before the
                // switches draw, so the list shows it on.
                if let c { conductor.adoptFirstReminderChannel(from: c) }
                channels = c; channelsAsked = true
            }
        }
        loadSources(full: full)
    }

    /// Two passes. The quick list (no probe: the files, and the last known
    /// answer for the Mac sources) is on screen in well under a second; the
    /// full one, which asks every Mac source whether it is really there,
    /// replaces it when it lands — a few seconds, sometimes ten. Before
    /// this the page was blank for that whole time, and a person reads a
    /// blank settings page as broken.
    private func loadSources(full: Bool) {
        let started = flips
        Task {
            let q = await ScriptRunner.offMain { BackgroundLearning.sources(quick: true) }
            let m = await ScriptRunner.offMain { BackgroundLearning.state(of: BackgroundLearning.seeding) }
            await MainActor.run { apply(q, seeding: m, startedAt: started) }
            guard full else { return }
            let s = await ScriptRunner.offMain { BackgroundLearning.sources() }
            await MainActor.run {
                apply(s, seeding: nil, startedAt: started)
                if s != nil { lastFull = Date() }
            }
        }
    }

    /// A list that started after the last flip already carries every
    /// flipped answer, so the overrides can go. One that started before it
    /// keeps the flips made since it began: its answers for those are
    /// from before the person touched the switch.
    private func apply(_ list: [BackgroundLearning.Source]?, seeding m: BackgroundLearning.State?, startedAt: Int) {
        if let list { sources = list }
        if let m { seeding = m }
        if startedAt == flips {
            flipped = [:]
        } else {
            flipped = flipped.filter { $0.value.seq > startedAt }
        }
    }

    /// Every answer a row has on or off, through consent.sh — the same file
    /// the terminal prompt writes, so the daily pass and a hand-run
    /// `learn.sh` see the same answer. The switch moves now; the writes
    /// (a third of a second each) happen behind it, and only a failed one
    /// puts it back.
    private func set(_ names: [String], on: Bool) {
        flips += 1
        let seq = flips
        let state: BackgroundLearning.State = on ? .granted : .refused
        for n in names { flipped[n] = Flip(state: state, seq: seq) }
        Task {
            var failed: [String] = []
            for n in names {
                let ok = await ScriptRunner.offMain { BackgroundLearning.set(n, on: on) }
                if !ok { failed.append(n) }
            }
            await MainActor.run {
                jobNote = failed.isEmpty ? "" : "Couldn't record that. Nothing changed."
                for n in failed { flipped[n] = nil }
                if !failed.isEmpty { loadSources(full: false) }
            }
        }
    }

    /// Both directions go through learn/consent.sh, so the answer lands in
    /// the one file the daily job reads — turning this off really stops it.
    private func setLearning(_ on: Bool) {
        learningBusy = true
        learning = on ? .granted : .refused
        Task {
            let ok = await ScriptRunner.offMain { BackgroundLearning.set(on) }
            let s = await ScriptRunner.offMain { BackgroundLearning.state() }
            await MainActor.run {
                learningBusy = false
                learning = s
                jobNote = ok ? "" : "Couldn't record that. Nothing changed."
            }
        }
    }

    private func toggleJob(_ on: Bool) {
        let ok = Launchd.set(label: Launchd.jobsLabel, enabled: on)
        jobNote = ok ? "" : "Couldn't \(on ? "start" : "stop") the ten-minute check."
        reload(full: false)
    }
}
