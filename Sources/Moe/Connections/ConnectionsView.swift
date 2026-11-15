import AppKit
import MoeDesign
import SwiftUI

// The Connections screen: a list down the left, and on the right everything
// about the one you picked — what Moe can do with it, which account, when
// it was last checked, and the buttons that act on it.
//
// It used to be one long list with a small outlined pill on each row and,
// for the connected ones, a grid of cards whose whole face was the button
// and whose Disconnect lived behind a right-click. People could not tell
// what to press, and there was no way to see anything about a connection
// beyond its one status line. Now the list only chooses; the right side
// shows and acts, with full-size buttons that stay where they are.

struct ConnectionsView: View {
    /// Which half of the list this screen is. One view, two screens: every
    /// sheet, every connect flow and the whole detail side are identical
    /// for a platform and for a service, so the split is a filter and a
    /// change of words, not a second 1,800-line file.
    enum Mode {
        /// Things Moe reaches out to while answering you.
        case services
        /// Places you can reach Moe from.
        case reach
    }

    @ObservedObject var conductor: Conductor
    var mode: Mode = .services
    @ObservedObject private var model = ConnectionsModel.shared
    @StateObject private var flow = ConnectFlow()
    @State private var search = ""

    /// Opens with something already typed. Only `--settings-snapshot` passes
    /// it, the way ChatsPane takes `searching:` — this list is a scroll view
    /// eighty rows long, so a photograph of the top of it is a photograph of
    /// the Mac rows and nothing else, and the part of the screen this change
    /// is about is the part no picture could reach.
    init(conductor: Conductor, mode: Mode = .services, searching: String = "",
         selecting: String? = nil, chrome: ChromeExtensionModel? = nil, checked: Date? = nil) {
        self.conductor = conductor
        self.mode = mode
        _search = State(initialValue: searching)
        _selectedID = State(initialValue: selecting)
        // Only `--settings-snapshot` passes it: a posed list was never
        // checked, and the "Checked" line is part of the page being drawn.
        _checkedAt = State(initialValue: checked)
        _chrome = ObservedObject(wrappedValue: chrome ?? ChromeExtensionModel.shared)
    }
    /// Connections › Chrome (ticket #13). A parameter only so
    /// `--settings-snapshot` can draw each of its states.
    @ObservedObject private var chrome: ChromeExtensionModel
    @State private var setupNote = ""
    @State private var removing: Connection?
    /// One sign-in of a row with several, waiting for its "are you sure".
    @State private var removingAccount: AccountRemoval?
    @State private var fullDiskRow: Connection?
    @State private var terminalRow: Connection?
    @State private var advancedOpen = false
    @State private var addingMCP = false
    /// The row whose "What's needed" was pressed.
    @State private var explaining: Connection?
    /// A source just connected for the first time, while its learn answers
    /// are all still unset: "Let Moe read it back and learn about you?"
    /// (docs/DEFAULTS.md row 25, BackgroundLearning.ConnectAsk).
    @State private var learnAsk: BackgroundLearning.Row?
    /// Which row the right side shows: a connection's id, or `brainID`.
    @State private var selectedID: String?
    /// When the list was last read, for the "checked" line.
    @State private var checkedAt: Date?
    /// The last hard brain failure, if it has not been fixed yet. Same
    /// record the Brain pane reads — one file, so the two screens cannot
    /// disagree about whether Moe can think.
    @State private var brainTrouble: BrainTrouble.Record?

    private static let brainID = "\u{1}brain"

    /// The plan this screen is describing. `cloudStatus.tier` is
    /// `TierCache.honoured` — the same answer the Composio gate acts on — so
    /// the screen never calls a Mac paid that the gate calls free. "free"
    /// until the sync has said otherwise, which is the safe direction: the
    /// worst case is a paying person told less than they have for a second,
    /// rather than a free one promised a schedule that will not run.
    private var tier: String { conductor.cloudSnapshot?.tier ?? "free" }

    private var groups: ConnectionsCatalog.Sections {
        ConnectionsCatalog.sections(model.connections, search: search, excludingInbound: true)
    }

    private var reachGroups: ConnectionsCatalog.Reach {
        ConnectionsCatalog.reach(model.connections, search: search)
    }

    /// How many services the search covers, rounded down to something a
    /// person reads as "lots" rather than as a promise. Zero while the list
    /// is still being read, which is why the prompt falls back.
    ///
    /// Every row, including the ones the list does not show until you type —
    /// because this number is the search box's own promise, and search does
    /// reach them. Counting only what is on screen would have quietly told
    /// people 200 while typing "Firecrawl" found it anyway.
    private var serviceCount: Int {
        let n = model.connections.filter { !$0.isInbound }.count
        return n >= 10 ? (n / 10) * 10 : n
    }

    /// Services that exist and are not listed until someone types their
    /// name. Zero for everyone before Composio is in the picture, which is
    /// why the line below it is conditional rather than always printed.
    private var searchOnlyCount: Int { groups.searchOnly.count }

    /// Every row this screen is responsible for, in the order it shows
    /// them. `selectFirst` and the detail lookup both need it, and neither
    /// should know which mode it is in.
    private var visibleRows: [Connection] {
        if mode == .reach {
            let g = reachGroups
            return g.attention + g.connected + g.available + g.advanced
        }
        return groups.inOrder
    }

    /// The row the right side shows. Resolved against **what this screen is
    /// actually listing**, not against every row Moe knows: the two screens
    /// share one model, and looking up globally meant the detail pane could
    /// keep showing a row the list beside it no longer contains — type a
    /// search that excludes the selection and the pane goes on offering
    /// Connect for something invisible.
    ///
    /// Alternates are searched too, and only the alternates of rows this
    /// screen lists, because that is how a row's own sheet addresses them.
    private var selected: Connection? {
        guard let selectedID, selectedID != Self.brainID, selectedID != ChromeExtension.rowID else { return nil }
        let rows = visibleRows
        return rows.first { $0.id == selectedID }
            ?? rows.flatMap(\.alternates).first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Rectangle().fill(Theme.rule).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: BrainTrouble.changed)) { _ in
            brainTrouble = BrainTrouble.current(for: conductor.config.brainProvider)
        }
        .onAppear {
            // This screen's whole promise is that it says what works, and its
            // brain row read `conductor.connected` — which means "the gateway
            // is up". That is true, and green, with a revoked key, a
            // cancelled plan or an account with no credit left, none of which
            // can answer a question. So it reads the same record the Brain
            // pane does: not a second opinion, the same one, from one file.
            brainTrouble = BrainTrouble.current(for: conductor.config.brainProvider)
            flow.model = model
            // The one restart hook the app exposes: re-applying the current
            // brain with restartGateway brings the gateway back on the new
            // .env. It is not free — Conductor.rebuildBrain clears the
            // conversation and rotates the dictation session — so the flow
            // calls it once, only after a clean exit that asked for it.
            flow.restartGateway = { [conductor] in
                let cfg = conductor.config
                conductor.applyBrain(BrainSelection(config: cfg), baseURL: cfg.brainExtras["baseURL"] ?? "",
                                     polishModel: cfg.dictationPolishModel, restartGateway: true)
            }
            // CLOUD-PLAN §19.11: a brokered service needs this Mac's own
            // Composio project, which needs an account — the official
            // build's sign-in (`CloudLink.wireConnect`). Without one, a
            // brokered service takes the key Hermes's env file carries.
            conductor.cloud.wireConnect(flow, conductor: conductor)
            // The Chrome row's word on the list, before anyone opens it
            // (only the detail polls).
            if mode == .services { Task { await chrome.refresh() } }
            if !model.loadedOnce { model.reload() }
            else {
                if selectedID == nil { selectFirst() }
                // A list read minutes ago is a guess about now: a check
                // that did not answer in time on the last visit — the Mac
                // busy right after launch — stayed on screen as "not
                // connected" until somebody pressed Check again.
                if let checkedAt, Date().timeIntervalSince(checkedAt) > 120 { model.reload() }
            }
        }
        // The Fix card for `browser_extension_missing` lands here, on this row.
        .onReceive(chrome.$focusRequested) { wanted in
            guard wanted, mode == .services else { return }
            search = ""
            selectedID = ChromeExtension.rowID
            chrome.focusRequested = false
        }
        .onChange(of: model.checkingLive) { _, live in
            if !live { checkedAt = Date() }
        }
        .onChange(of: model.loadedOnce) { _, loaded in
            if loaded, selectedID == nil { selectFirst() }
        }
        // Row 25 for a macOS permission: the grant happens in System
        // Settings, so coming back to Moe is when to read the list again,
        // and a row that now reads connected gets the same ask as a sign-in.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !flow.awaitingPermission.isEmpty { model.reload() }
        }
        .onChange(of: model.connections) { _, rows in
            flow.permissionsChecked(rows)
            if !flow.presented { askToLearn() }
        }
        // Leaving the pane takes the sheet with it: stop the poll and the script.
        .onDisappear { if flow.presented { flow.cancel() } }
        // `refreshBrainContext` before `reload`: the pane redrawing itself is
        // not the same as Moe knowing, and it was the half that was missing.
        .sheet(isPresented: $flow.presented,
               onDismiss: {
                   if flow.changed { ConnectionsModel.refreshBrainContext(); model.reload() }
                   // Row 26: a chat app just connected, or a phone let in —
                   // look for a reminders chat now, not in ten minutes.
                   if flow.changed || !flow.approved.isEmpty, flow.connection?.kind == .platform {
                       conductor.chatAppConnected()
                   }
                   askToLearn()
               }) {
            ConnectSheet(flow: flow)
        }
        .sheet(item: $learnAsk) { row in
            ConnectLearnAskSheet(row: row) { learnAsk = nil }
        }
        .sheet(item: $explaining) { row in
            UnavailableSheet(row: row) { explaining = nil }
        }
        .sheet(item: $fullDiskRow) { row in FullDiskAccessSheet(row: row) { fullDiskRow = nil } }
        .sheet(isPresented: $addingMCP) {
            AddMCPServerSheet { name, address, auth in
                addingMCP = false
                flow.startCustomMCP(name: name, address: address, auth: auth)
            } cancel: {
                addingMCP = false
            }
        }
        .sheet(item: $terminalRow) { row in
            TerminalSetupSheet(row: row,
                               command: Self.terminalCommand(for: row),
                               open: { runInTerminal(row.kind == .mac ? row.setupScript : "connect.sh",
                                                     args: row.kind == .mac ? [] : [row.connectName]) },
                               close: { terminalRow = nil })
        }
        .alert("Disconnect \(removing?.label ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Disconnect", role: .destructive) { if let c = removing { flow.remove(c) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moe forgets the sign-in and stops reading it. Nothing at \(removing?.label ?? "the service") itself changes, and you can connect it again here whenever you like.")
        }
        // One account of several. The title names it — the address, or
        // whatever the person called it — because "Remove" beside three rows
        // is only a confirmation if it says which row it heard.
        .alert(removingAccount?.title ?? "", isPresented: Binding(get: { removingAccount != nil },
                                                                    set: { if !$0 { removingAccount = nil } }),
               presenting: removingAccount) { ask in
            Button("Remove", role: .destructive) { flow.removeAccount(ask.connection, ask.account) }
            Button("Cancel", role: .cancel) {}
        } message: { ask in
            Text(ask.message)
        }
    }

    /// Remove pressed on one account's row. The last one left is the whole
    /// connection, so it takes Disconnect…'s road — the same alert, the same
    /// script call, the same cleanup of dead sign-ins behind it. Any other
    /// goes by its id and leaves the rest alone.
    private func beginRemoveAccount(_ c: Connection, _ acct: Connection.Account) {
        if AccountRemoval.isLast(c, acct) { beginRemove(c); return }
        removingAccount = AccountRemoval(connection: c, account: acct)
    }

    /// docs/DEFAULTS.md row 25: the first time a source is connected, ask
    /// whether Moe may read it back and learn about the person — once per
    /// source, and only while every answer it has is unset. Asked after the
    /// connect sheet has gone, so one sheet never sits on another. The
    /// marker goes down when the question is shown, whatever the answer.
    private func askToLearn() {
        guard let c = flow.justConnected else { return }
        flow.justConnected = nil
        let names = [c.name, c.connectName]
        Task {
            guard let row = await ScriptRunner.offMain({ BackgroundLearning.ConnectAsk.check(names: names) })
            else { return }
            BackgroundLearning.ConnectAsk.markAsked(row.id)
            learnAsk = row
        }
    }

    /// The first thing worth looking at: something that needs you, else
    /// something of yours, else — on the services screen only — the brain.
    /// The reach screen has no brain row, so it falls back to the first
    /// thing a person could set up rather than to nothing.
    private func selectFirst() {
        if mode == .reach {
            let g = reachGroups
            selectedID = g.attention.first?.id ?? g.connected.first?.id ?? g.available.first?.id
            return
        }
        let g = groups
        selectedID = g.attention.first?.id ?? g.connected.first?.id ?? Self.brainID
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            PaneHeader(mode == .reach ? "Ways to reach Moe" : "Connections")
            // Counted, not remembered: the number was written when one list
            // held everything, and the platforms leaving made it wrong the
            // same day. A number on screen that nothing recomputes is a
            // number that goes stale silently.
            PaneSearch(prompt: mode == .reach ? "Search apps" : "Search \(serviceCount) services",
                       text: $search, width: 210)
                .padding(.horizontal, Theme.Space.cosy)
                .padding(.vertical, Theme.Space.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // Said once, at the top, rather than on eleven rows: Moe
                    // runs here. Nothing here answers while the Mac is asleep,
                    // and people should be told that rather than find it out.
                    // The reach screen says it the other way round, because
                    // there the consequence is a message that goes unanswered
                    // rather than a source Moe cannot read.
                    //
                    // Both lines follow the plan, because the free one read to
                    // somebody who had just paid for Away as though they had
                    // bought nothing. `AwayCopy` holds the words and the
                    // reasons; the tier is the gate's own (`cloudStatus.tier`
                    // is `TierCache.honoured`), so this line and the Composio
                    // gate can never disagree about what is being paid for.
                    Text(Cloud.connectionsBlurb(reach: mode == .reach, tier: tier))
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.small)
                        .padding(.bottom, Theme.Space.small)

                    if mode == .services, search.isEmpty {
                        heading("Thinking")
                        brainRow
                        heading("Your browser")
                        ChromeExtensionRow(model: chrome, selected: selectedID == ChromeExtension.rowID) {
                            selectedID = ChromeExtension.rowID
                        }
                    }
                    // A pending pairing is someone trying to reach Moe right
                    // now, so it belongs on the screen about reaching Moe.
                    // It used to sit above eighty services, where the one
                    // thing on this screen that is time-sensitive read as a
                    // footnote.
                    if mode == .reach, !model.pairings.isEmpty { pairingRows }
                    if !model.warning.isEmpty {
                        Label(model.warning, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typo.ui(11, weight: .medium)).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.Space.small)
                            .padding(.vertical, Theme.Space.small)
                    }
                    if !model.loadedOnce {
                        HStack(spacing: Theme.Space.small) {
                            ProgressView().controlSize(.small)
                            Text("Looking at what is already set up on this Mac. A few seconds.")
                                .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Theme.Space.small)
                    } else if mode == .reach {
                        reachList
                    } else {
                        let g = groups
                        if !g.attention.isEmpty {
                            heading(g.attention.count == 1 ? "1 needs you" : "\(g.attention.count) need you", tone: Theme.warn)
                            ForEach(g.attention) { row($0) }
                        }
                        if !g.connected.isEmpty || search.isEmpty {
                            heading("Yours")
                            if g.connected.isEmpty {
                                note("Nothing connected yet. Pick something below — Moe answers better the more of your world it can see.")
                            }
                            ForEach(g.connected) { row($0) }
                        }
                        // docs/DEFAULTS.md row 34: the Mac's own four
                        // first, then Google (the head of Popular), then
                        // the rest of the Mac — `Sections.inOrder`.
                        if !g.macFirst.isEmpty {
                            heading("Your Mac")
                            ForEach(g.macFirst) { row($0) }
                        }
                        if search.isEmpty, !g.popular.isEmpty {
                            heading("Popular")
                            ForEach(g.popular) { row($0) }
                        }
                        if !g.macMore.isEmpty {
                            heading(g.macFirst.isEmpty ? "Your Mac" : "More on your Mac")
                            ForEach(g.macMore) { row($0) }
                        }
                        if search.isEmpty, !g.work.isEmpty {
                            heading("Popular at work")
                            ForEach(g.work) { row($0) }
                        }
                        if !g.rest.isEmpty || !search.isEmpty {
                            heading(search.isEmpty ? "Everything else" : "Results")
                            if g.rest.isEmpty {
                                note("Nothing here is called “\(search)”. Try a shorter word, or the name of the app itself.")
                            }
                            ForEach(g.rest) { row($0) }
                        }
                        // The stockroom, said out loud. Without this line the
                        // list looks like the whole catalogue and a person
                        // whose tool is not on it concludes Moe cannot reach
                        // it — which is the failure the old 1,378-row list
                        // avoided by being unreadable instead.
                        if search.isEmpty, searchOnlyCount > 0 {
                            note("\(searchOnlyCount) more can be connected — type a name to find it. "
                                 + "These are the ones where the service asks you to set up the sign-in yourself.")
                        }
                        advancedRows(g.advanced)
                    }
                }
                .padding(.horizontal, Theme.Space.small)
                .padding(.bottom, Theme.Space.base)
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: Theme.Space.small) {
                PaneButton(title: "Check again", symbol: "arrow.clockwise") { model.reload() }
                    .disabled(model.loading)
                    .opacity(model.loading ? 0.5 : 1)
                if model.loading || model.checkingLive { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.cosy)
            .padding(.vertical, Theme.Space.small)
        }
        .background(Theme.paper)
    }

    /// The reach screen's groups. Its own words throughout: on this screen a
    /// row is not a source Moe reads, it is a place a person types.
    @ViewBuilder
    private var reachList: some View {
        let g = reachGroups
        if !g.attention.isEmpty {
            // The specific case worth shouting about: a platform that is set
            // up but has nobody allowed to talk to it. It looks connected and
            // answers nobody, which is the one failure a person cannot guess.
            heading(g.attention.count == 1 ? "1 needs you" : "\(g.attention.count) need you", tone: Theme.warn)
            ForEach(g.attention) { row($0) }
        }
        if !g.connected.isEmpty {
            heading("You can reach Moe here")
            ForEach(g.connected) { row($0) }
        }
        if !g.available.isEmpty {
            heading(search.isEmpty
                    ? (g.connected.isEmpty ? "Pick how you want to reach Moe" : "Also possible")
                    : "Results")
            if g.connected.isEmpty, search.isEmpty {
                note("Set one of these up and you can message Moe from your phone — a text, and Moe replies.")
            }
            ForEach(g.available) { row($0) }
        }
        advancedRows(g.advanced)
        // "Nothing is called that" belongs under an empty screen, not under
        // the row that matched. Saying it while a Telegram row sits above it
        // is a contradiction the reader has to resolve.
        if g.isEmpty {
            note(search.isEmpty
                 ? "Moe could not read the list of apps it can be messaged from. Press Check again."
                 : "Nothing here is called “\(search)”. Try the name of the app itself.")
        }
    }

    private func heading(_ title: String, tone: Color = Theme.ink3) -> some View {
        Text(title)
            .font(Theme.Typo.label(9))
            .tracking(Theme.tracking)
            .foregroundStyle(tone)
            .padding(.horizontal, Theme.Space.small)
            .padding(.top, Theme.Space.cosy)
            .padding(.bottom, Theme.Space.tight)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(11))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, Theme.Space.tight)
    }

    /// One row: icon, name, and a word about its state. Choosing it fills
    /// the right side; nothing on the row itself acts.
    private func row(_ c: Connection) -> some View {
        let on = selectedID == c.id
        return Button {
            selectedID = c.id
        } label: {
            HStack(spacing: Theme.Space.small) {
                ServiceIcon(name: c.name, label: c.label,
                            macSymbol: c.kind == .mac ? ServiceIcons.macSymbol(for: c.name) : nil,
                            size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.label)
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: needsSignIn(c) ? "Sign in with Google to connect" : Self.stateWord(c))
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Self.stateColour(c))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(on ? Theme.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A brokered service on a Mac that has no account yet: the first
    /// click signs in with Google (ConnectFlow.needsAccount), and the row
    /// says so before the click rather than after it. Before 2026-09-07
    /// these rows were not listed at all until a key existed, so a
    /// stranger saw no Gmail, no Calendar and no Drive — only the
    /// app-password mailbox — and nothing said signing in would change it.
    private func needsSignIn(_ c: Connection) -> Bool {
        Cloud.isInstalled && c.kind == .composio && c.state == .notConnected
            && conductor.cloudSnapshot?.enrolled != true
    }

    /// The row for the thing that thinks. It names the account you chose,
    /// never the machinery behind it.
    /// Whether the brain is genuinely answering. A live gateway is not the
    /// same question: `conductor.connected` stays true, and green, through a
    /// revoked key or an empty account.
    private var brainStateGood: Bool { conductor.connected && brainTrouble == nil }

    /// The one line under the brain's name, on the list. Short enough for a
    /// sidebar; `brainDetail` carries the whole sentence and the way out.
    private var brainStateWord: String {
        if let t = brainTrouble {
            switch t.kind {
            case .credentialRejected:
                return conductor.config.brainProvider.access == .apiKey
                    ? "The key was turned down" : "The sign-in was turned down"
            case .outOfCredit:         return "No credit left"
            case .modelRefused:        return "Won't serve this model"
            case .endpointUnreachable: return "Nothing at that address"
            }
        }
        if conductor.connected { return "Working" }
        return conductor.needsSignIn ? "Needs a sign-in" : "Starting…"
    }

    private var brainRow: some View {
        let on = selectedID == Self.brainID
        let p = conductor.config.brainProvider
        return Button {
            selectedID = Self.brainID
        } label: {
            HStack(spacing: Theme.Space.small) {
                ServiceIcon(name: p.iconName, label: p.shortName, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.accountTitle)
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(brainStateWord)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(brainStateGood ? Theme.good : Theme.warn)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(on ? Theme.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Someone messaged Moe's bot and is waiting to be let in.
    private var pairingRows: some View {
        Group {
            heading("Waiting to be let in", tone: Theme.warn)
            ForEach(model.pairings) { p in
                VStack(alignment: .leading, spacing: Theme.Space.small) {
                    Text(verbatim: p.question)
                        .font(Theme.Typo.ui(12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: p.isSlackInstall
                         ? "Confirm only if that is you, or someone you're adding on purpose — until you do, nothing written there reaches Moe."
                         : (p.when.isEmpty ? p.name : "\(p.name) · \(p.when)"))
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Space.small) {
                        PaneButton(title: p.isSlackInstall ? "Confirm" : "Approve", prominent: true) { flow.approve(p) }
                        PaneButton(title: "Not now") { model.forget(p) }
                    }
                }
                .padding(Theme.Space.small)
            }
        }
    }

    /// Always rendered, even with nothing in `rows`: "Add a server by address"
    /// lives here, and a catalogue that happens to cover everything the user
    /// has heard of must not be the reason there is no way to add the one it
    /// does not. Moe is Hermes — anything Hermes can reach belongs here.
    @ViewBuilder
    private func advancedRows(_ rows: [Connection]) -> some View {
        // On the services screen the disclosure is worth showing even when
        // empty, because "Add a server by address…" lives inside it and is
        // the only way to reach a server nobody has heard of. On the reach
        // screen there is no such button, so an empty disclosure would open
        // onto one line of apology.
        if !rows.isEmpty || (search.isEmpty && mode == .services) {
            Button {
                advancedOpen.toggle()
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: advancedOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                    Text("Advanced")
                        .font(Theme.Typo.label(9))
                        .tracking(Theme.tracking)
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.small)
                .padding(.top, Theme.Space.cosy)
                .padding(.bottom, Theme.Space.tight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if advancedOpen {
                note("Other ways in, for people who know they need them.")
                ForEach(rows) { row($0) }
                if mode == .services {
                Button {
                    addingMCP = true
                } label: {
                    HStack(spacing: Theme.Space.small) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add a server by address\u{2026}")
                                .font(Theme.Typo.ui(13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text("Your company's own, or one nobody has heard of.")
                                .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.small)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                }
            }
        }
    }

    static func stateWord(_ c: Connection) -> String {
        switch c.state {
        case .connected:      return "Working"
        case .needsAttention: return c.detail.isEmpty ? "Needs you" : c.detail
        case .unavailable:    return c.couldNotCheck ? "Couldn't check" : (c.unavailableWords ?? "Not available yet")
        case .notConnected:   return c.blurb
        }
    }

    static func stateColour(_ c: Connection) -> Color {
        switch c.state {
        case .connected:      return Theme.good
        case .needsAttention: return Theme.warn
        default:              return Theme.ink3
        }
    }

    // MARK: - The right side

    /// Start a removal. More than one sign-in behind the row means the first
    /// question is WHICH — the chooser's own buttons are the confirmation,
    /// and each names the account it will remove. One sign-in keeps the
    /// alert, because then "are you sure" is the only question left.
    private func beginRemove(_ c: Connection) {
        if c.kind == .composio, c.liveAccounts > 1 { flow.remove(c); return }
        if c.kind == .mac, c.name == "gmail" { flow.remove(c); return }
        removing = c
    }

    @ViewBuilder
    private var detail: some View {
        if selectedID == Self.brainID {
            brainDetail
        } else if selectedID == ChromeExtension.rowID {
            ChromeExtensionDetail(model: chrome)
        } else if let c = selected {
            ConnectionDetail(connection: c, checkedAt: checkedAt,
                             action: { act(on: c) },
                             disconnect: { beginRemove(c) },
                             disconnectOther: { beginRemove($0) },
                             removeAccount: { beginRemoveAccount(c, $0) },
                             pressed: { flow.pressPlace = $0 },
                             alternate: { alt in flow.start(alt) },
                             explain: { explaining = c },
                             check: { model.reload() },
                             checkAgain: { model.checkAgain(c) },
                             checking: model.loading || model.checkingLive,
                             note: setupNote,
                             needsAccount: needsSignIn(c))
        } else if mode == .reach {
            PaneEmpty(title: "Pick a way in",
                      detail: "Choose an app on the left to see how to message Moe there, who is allowed to, and how to stop it.")
        } else {
            PaneEmpty(title: "Pick a service",
                      detail: "Choose anything on the left to see what Moe can do with it, which account it uses, and how to connect or disconnect it.")
        }
    }

    /// What is doing the thinking, and — only when it is actually wanted —
    /// the way to sign in. The button is gated on `needsSignIn`, the same
    /// flag the menu bar uses, and the name comes from the configured
    /// provider: a working brain must never show a sign-in button, because
    /// on a screen about what works that reads as "something is wrong".
    private var brainDetail: some View {
        let p = conductor.config.brainProvider
        return PaneDetail {
          VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            HStack(alignment: .center, spacing: Theme.Space.cosy) {
                ServiceIcon(name: p.iconName, label: p.shortName, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.accountTitle)
                        .font(Theme.Typo.heading(22))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: Theme.Space.small) {
                        Circle().fill(brainStateGood ? Theme.good : Theme.warn).frame(width: 7, height: 7)
                        Text(brainStateGood ? "Working"
                             : (brainTrouble != nil ? brainStateWord
                                : (conductor.needsSignIn ? "Waiting for a sign-in" : "Starting…")))
                            .font(Theme.Typo.ui(12, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            // The whole sentence, and the one next thing to do — the same
            // words Settings › Brain shows, from the same record.
            if let t = brainTrouble {
                Text(BrainTrouble.settingsRow(t.kind, conductor.config.brainProvider))
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                settingsLabel("What it does")
                Text("This is what lets Moe answer you. Moe doesn't charge for it and has no account of its own — it borrows yours. Which model it uses, and how hard it thinks, are in Settings.")
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            if !setupNote.isEmpty {
                Text(setupNote).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
          }
        } bar: {
            PaneActionBar {
                if conductor.needsSignIn {
                    // The brain's own Claude Code child signs in with a
                    // setup-token, not your interactive login; the script runs
                    // `claude setup-token` and keeps the result in the keychain
                    // (HERMES-PLAN.md, "Revised after review"). It runs in a
                    // Terminal because that is where the sign-in prints its code.
                    PaneButton(title: "Sign in…", prominent: true, large: true) { runInTerminal("hermes-signin.sh") }
                }
                PaneButton(title: "Change in Settings…", large: true) {
                    SettingsWindow.show(conductor: conductor, at: .brain)
                }
            } trailing: {
                EmptyView()
            }
        }
    }

    /// The one button's meaning per row.
    private func act(on c: Connection) {
        switch c.authKind {
        case .consent:
            // Chrome browsing: nothing to sign in to and nothing to grant in
            // System Settings — the only question is whether the user wants
            // it read at all, and that answer is recorded and revocable.
            //
            // Except when the row is in "Needs attention". An opt-in row that
            // is merely off reads as not-connected (MacSources.connection),
            // so the only thing that leaves one here is a macOS grant the
            // switch cannot give — Chrome's history sits inside another app's
            // folder, which is Full Disk Access. Granting consent again would
            // report success and change nothing.
            if c.state == .needsAttention {
                if c.needsFullDiskAccess { fullDiskRow = c }
                else if let url = c.settingsPaneURL { NSWorkspace.shared.open(url) }
            } else {
                flow.setConsent(c, on: true)
            }
        case .macPermission:
            flow.awaitPermission(c)
            if c.needsFullDiskAccess { fullDiskRow = c }
            else if let url = c.settingsPaneURL { NSWorkspace.shared.open(url) }
        case .terminal:
            // WhatsApp used to land here — both rows of it — and be sent to a
            // Terminal. It does not any more: it pairs by a QR code the sheet
            // draws (.scan), from Hermes's own bundled bridge. What is left
            // here is Telegram's phone login, which asks for a texted code.
            flow.start(c)
        default:
            flow.start(c)
        }
    }

    /// The command a Terminal flow runs, in the form a person can retype.
    static func terminalCommand(for c: Connection) -> String {
        c.kind == .mac ? "~/.moe/scripts/\(c.setupScript)"
                       : "~/.moe/scripts/connect.sh \(c.connectName)"
    }

    /// The flows that are interactive by nature — the WhatsApp bridge's QR
    /// pairing, the brain's sign-in — run in Terminal where you can see them.
    /// Returns the line to show, so a sheet can show it too.
    @discardableResult
    private func runInTerminal(_ script: String, args: [String] = []) -> String {
        guard let target = ScriptRunner.scriptPath(script) else {
            setupNote = "Moe couldn't find its own setup file for this. Reinstalling Memoe puts it back."
            return setupNote
        }
        var err: NSDictionary?
        NSAppleScript(source: Terminal.script(running: target, args: args))?.executeAndReturnError(&err)
        if err != nil {
            // Moe isn't allowed to open Terminal for you — don't fail
            // silently, hand over the command instead.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(([target] + args).joined(separator: " "), forType: .string)
            setupNote = "Moe isn't allowed to open Terminal for you, so the command is copied — open Terminal yourself and press ⌘V, then Return."
        } else {
            setupNote = "Opened in Terminal. Follow it there, then come back."
        }
        return setupNote
    }
}

// MARK: - One account of several

extension Connection {
    /// What the screen calls one sign-in: the name it was given (for Google,
    /// the address), or its place in the list when nobody has named it. One
    /// function, because the row, the confirmation and the sheet afterwards
    /// must all say the same words about the same account.
    func accountLabel(_ acct: Account) -> String {
        if !acct.who.isEmpty { return acct.who }
        let index = accounts.firstIndex { $0.id == acct.id } ?? 0
        return "Account \(index + 1)"
    }

    /// The sign-ins the detail lists: the live ones, or — only when nothing
    /// is live — the dead ones, which then explain why the row is not working.
    var shownAccounts: [Account] {
        accounts.filter { $0.live || liveAccounts == 0 }
    }
}

/// "Remove this one account?" — what is being asked, and the words for it.
struct AccountRemoval: Equatable {
    let connection: Connection
    let account: Connection.Account

    var label: String { connection.accountLabel(account) }

    /// Whether removing `acct` leaves the row with no account to show. Then
    /// it is not "one of several" and the question is Disconnect's.
    static func isLast(_ c: Connection, _ acct: Connection.Account) -> Bool {
        c.shownAccounts.allSatisfy { $0.id == acct.id }
    }

    var title: String { "Remove \(label) from \(connection.label)?" }

    var message: String {
        let others = connection.shownAccounts.filter { $0.id != account.id }.count
        let stay = others == 1 ? "Your other \(connection.label) account stays connected"
                               : "Your other \(others) \(connection.label) accounts stay connected"
        return "Moe forgets this sign-in and stops using it. \(stay), and nothing at \(connection.label) itself changes."
    }

    /// What connect.sh is asked to do: this account's id, never the bare
    /// service. `connect.sh --remove <service>` with no id removes every
    /// account, so an empty id is refused here rather than sent — nil means
    /// "do not launch anything".
    static func arguments(_ c: Connection, _ acct: Connection.Account) -> [String]? {
        let id = acct.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.kind == .composio, !c.connectName.isEmpty, !id.isEmpty,
              c.accounts.contains(where: { $0.id == acct.id }) else { return nil }
        return ["--remove", c.connectName, id]
    }
}

// MARK: - The detail

/// Everything about one connection, and the buttons that act on it. The
/// buttons are full size and always in the same place at the bottom, so
/// nobody has to hunt for Disconnect or guess whether a card is a button.
struct ConnectionDetail: View {
    let connection: Connection
    let checkedAt: Date?
    let action: () -> Void
    let disconnect: () -> Void
    /// The account being renamed, and the row it belongs to.
    @State private var renamingAccount: (Connection, Connection.Account)?
    @State private var renameText = ""
    /// Remove something OTHER than this row — a folded alternative. The
    /// existing `disconnect` closes over the parent row, so a connected
    /// alternate had nothing that could remove it.
    var disconnectOther: (Connection) -> Void = { _ in }
    /// Remove ONE sign-in and leave the others. The screen asks first, by
    /// name (`ConnectionsView.beginRemoveAccount`).
    var removeAccount: (Connection.Account) -> Void = { _ in }
    /// D9.14: where the button that was just pressed is, said before its
    /// action runs — so the press that leads to a sign-in is judged against
    /// that button's own rectangle and not against the whole window.
    var pressed: (HumanPressPlace) -> Void = { _ in }
    var alternate: (Connection) -> Void = { _ in }
    var explain: () -> Void = {}
    var check: () -> Void = {}
    /// Ask the cloud again whether a row it said was not available is now
    /// (`offersCheckAgain`). Moe's own Slack app only, today.
    var checkAgain: () -> Void = {}
    var checking = false
    var note = ""
    /// This Mac has no Memoe account yet, and this row needs one: the button
    /// signs in first, and the panel says why before it is pressed.
    var needsAccount = false

    private var c: Connection { connection }
    private var isBlocked: Bool { c.state == .unavailable }

    /// **A "not available yet" that can change without this Mac doing anything**
    /// (fourth review of slice G1): Moe's own Slack app reads unavailable while
    /// Moe's cloud has no Google web client, and the owner adding one fixes it
    /// for every Mac at once. "What's needed" only explained; this asks again
    /// (`connect.sh --status platform/slack`, which rereads the cloud) and
    /// reloads. In `Moe --connections-json` as `checkAgain`, so the suite reads
    /// the binary's own answer.
    /// The connected Email Moe row's own buttons, beside Check now (slice G3):
    /// copy the address, and change it (which opens the choose-a-name step).
    /// The view draws exactly these; `Moe --connections-json` carries them as
    /// `emailActions`, and `MoeEmailRowTests` reads them.
    static func emailActions(_ c: Connection) -> [String] {
        guard c.kind == .platform, c.name == "moemail", c.state == .connected else { return [] }
        return ["Copy address", "Change address…"]
    }

    static func offersCheckAgain(_ c: Connection) -> Bool {
        c.state == .unavailable && c.kind == .platform && (c.name == "slack" || c.name == "moemail")
            && c.authKind == .oneClick
    }

    /// Why the first connect starts with a Google sign-in — said here,
    /// because the alternative is a second Google screen appearing with no
    /// warning and no reason.
    static let signInFirst = "Your connections belong to your Memoe account, so they follow you to your other Macs and can be switched off in one place. Sign in with Google once, and this connects right after."

    /// Whether the bar under the page has anything in it.
    static func hasActions(_ c: Connection, needsAccount: Bool) -> Bool {
        c.state == .connected || needsAccount || primaryTitle(c) != nil
            || c.state == .unavailable || canDisconnect(c)
    }

    /// `PaneDetail`: the page scrolls inside the pane and the buttons are
    /// pinned under it. This was one stack with a `Spacer` above the buttons
    /// and no scroll view, so its minimum height was everything in it: three
    /// accounts and the app-password row made the pane taller than the
    /// window, and the window's content was centred with its top and bottom
    /// outside the glass (the owner's report, 2026-11-12).
    var body: some View {
        PaneDetail(showsBar: Self.hasActions(c, needsAccount: needsAccount)) {
            page
        } bar: {
            actions
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            header
            canDo
            if needsAccount { signInFirstNote }
            if c.state == .connected || c.state == .needsAttention { account }
            // The sign-ins themselves, when there is more than one or when
            // one has been named. Defined and never rendered is how a
            // feature ships as dead code — this is the line that shows it.
            accountList
                .sheet(isPresented: Binding(
                    get: { renamingAccount != nil },
                    set: { if !$0 { renamingAccount = nil } })) {
                    renameSheet
                }
            if !c.alternates.isEmpty { alternates }
            if !note.isEmpty {
                Text(note).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The Telegram bot, connected: which chat is the owner's, confirmed
            // with a code shown only here — the cloud's (`CloudLink`).
            if let panel = Cloud.link.connectionPanel(for: c) { panel }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.cosy) {
            ServiceIcon(name: c.name, label: c.label,
                        macSymbol: c.kind == .mac ? ServiceIcons.macSymbol(for: c.name) : nil,
                        size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.label)
                    .font(Theme.Typo.heading(22))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.small) {
                    Circle().fill(ConnectionsView.stateColour(c)).frame(width: 7, height: 7)
                    Text(stateLine)
                        .font(Theme.Typo.ui(12, weight: .medium))
                        .foregroundStyle(c.state == .needsAttention ? Theme.warn : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stateLine: String {
        switch c.state {
        case .connected:
            if let checkedAt {
                let mins = Int(Date().timeIntervalSince(checkedAt) / 60)
                return "Working · checked " + (mins < 1 ? "just now" : "\(mins) min ago")
            }
            return "Working"
        case .needsAttention: return c.detail.isEmpty ? "Needs you" : c.detail
        case .unavailable:    return c.couldNotCheck ? c.detail : (c.unavailableWords ?? "Not available yet")
        case .notConnected:   return "Not connected"
        }
    }

    private var signInFirstNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            settingsLabel("Sign in first")
            Text(Self.signInFirst)
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    /// The catalog's sentence about what Moe does with it. An unavailable
    /// row's detail is the *reason* it cannot work ("no Call Recordings
    /// folder in Notes"), the most useful sentence on the screen, so it is
    /// shown in full and in the warning colour.
    private var canDo: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            settingsLabel("What Moe can do with it")
            // Catalog text: plain Text, never Markdown.
            Text(verbatim: c.blurb)
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
            if isBlocked, !c.detail.isEmpty {
                Text(verbatim: c.detail)
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            if !c.docs.isEmpty, let url = URL(string: c.docs) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: Theme.Space.tight) {
                        // A brokered service has no key anywhere: the whole
                        // point is that the person never meets one. Offering
                        // to show them where to get it is a promise the page
                        // on the other end does not keep.
                        Text(c.kind == .composio ? "About \(c.label)"
                                                 : "About \(c.label), and where to get a key")
                            .font(Theme.Typo.ui(12, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accentDeep)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Every sign-in behind this connection, one line each.
    ///
    /// A row used to carry a single yes/no, so a person with a personal and a
    /// work Google saw exactly what a person with one saw. The button said
    /// "Add another account" and adding one changed nothing on screen, which
    /// is a worse failure than not offering it: it looks like the click was
    /// ignored.
    ///
    /// Composio records no identity on an account — every obvious field is
    /// absent and the OIDC token comes back empty — so an unnamed account is
    /// shown by when it was added rather than by a guess. `who` is filled in
    /// when the person has named it.
    @ViewBuilder
    private var accountList: some View {
        // Shown whenever there is an account at all. It was gated on "more
        // than one, or named", which meant the commonest case — one unnamed
        // account — showed nothing, and a person could not see WHICH account
        // was connected. That is the first question anyone asks of a row
        // that says Working.
        if !c.accounts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                // No heading: this sits directly under the "Account" section
                // and repeating the word made the pane read as two Account
                // sections stacked, which is what a screenshot showed.
                EmptyView()
                VStack(spacing: 0) {
                    ForEach(Array(c.accounts.enumerated()), id: \.element.id) { index, acct in
                        // A dead sign-in is worth showing only when it is the
                        // ONLY thing there — then it explains why the row is
                        // not working. Beside a live account it is a record
                        // of something that already got replaced, and three
                        // of them made a working Gmail look broken.
                        if acct.live || c.liveAccounts == 0 {
                            accountRow(acct, words: accountWords(acct, index: index))
                        }
                    }
                }
                .frame(maxWidth: Theme.measure, alignment: .leading)
            }
        }
    }

    /// One sign-in: what it is called, and Rename and Remove for it.
    ///
    /// On one line when the pane is wide enough to hold the whole address
    /// beside the buttons. When it is not — at the window's smallest this
    /// column is about 270pt — the buttons go under the address, because the
    /// alternative is the address squeezed into what is left and broken
    /// every five letters.
    private func accountRow(_ acct: Connection.Account, words: String) -> some View {
        let name = acct.live ? "Signed in" : "Not working"
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
                kvName(name)
                Text(verbatim: words)
                    .font(Theme.Typo.ui(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: Theme.Space.small)
                accountButtons(acct)
            }
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
                    kvName(name)
                    Text(verbatim: words)
                        .font(Theme.Typo.ui(13))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: Theme.Space.base) {
                    Color.clear.frame(width: 96, height: 1)
                    accountButtons(acct)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, Theme.Space.small)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    @ViewBuilder
    private func accountButtons(_ acct: Connection.Account) -> some View {
        // Naming is the only way to tell two accounts of one service apart:
        // Composio records no identity, and where we can ask the service
        // (Google) it answers for one account, not whichever the person meant.
        Button("Rename") { renameAccount(c, acct) }
            .buttonStyle(.plain)
            .font(Theme.Typo.ui(11, weight: .semibold))
            .foregroundStyle(Theme.accentDeep)
            .fixedSize()
        // One account, not the service: Disconnect… below is all of them,
        // and until this was here the only way to drop one address was to
        // find that out from a chooser behind a button that says it
        // disconnects Gmail.
        Button("Remove") { removeAccount(acct) }
            .buttonStyle(.plain)
            .font(Theme.Typo.ui(11, weight: .semibold))
            .foregroundStyle(Theme.bad)
            .fixedSize()
            .accessibilityLabel("Remove \(c.accountLabel(acct))")
    }

    private func kvName(_ name: String) -> some View {
        Text(name)
            .font(Theme.Typo.label(9))
            .tracking(Theme.tracking)
            .foregroundStyle(Theme.ink3)
            .frame(width: 96, alignment: .leading)
    }

    /// What to call an account that Composio gave no name for.
    private func accountWords(_ acct: Connection.Account, index: Int) -> String {
        let name = c.accountLabel(acct)
        if acct.live { return name }
        // "Expired" and "half-finished" are different problems with different
        // fixes, and lumping them under "not connected" is what sent Izzy to
        // sign in again for something that was already signed in.
        switch acct.status {
        case "EXPIRED", "REVOKED": return "\(name) — the sign-in ran out"
        case "INITIATED", "PENDING": return "\(name) — sign-in never finished"
        case "FAILED": return "\(name) — the sign-in failed"
        default: return "\(name) — \(acct.status.lowercased())"
        }
    }

    /// Which account, in whatever words the connection has for it.
    private var account: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            settingsLabel("Account")
            VStack(spacing: 0) {
                if c.state == .connected, !c.detail.isEmpty {
                    kv("Using", c.detail)
                }
                if c.liveAccounts > 1 {
                    kv("Signed in", "\(c.liveAccounts) accounts")
                }
                if !c.envKeys.isEmpty {
                    kv("Signed in with", c.envKeys.map { c.prompts[$0] ?? Connection.humanKey($0) }
                                                  .joined(separator: ", "))
                }
                if c.kind == .mac {
                    kv("Where", "On this Mac, read directly. Nothing leaves it unless you ask Moe something about it.")
                }
                if let checkedAt {
                    kv("Checked", checkedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    private func kv(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
            kvName(name)
            Text(verbatim: value)
                .font(Theme.Typo.ui(13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.small)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    /// Other ways to connect the same brand ("Also read my Telegram chats").
    private var alternates: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            settingsLabel("Also")
            ForEach(c.alternates) { alt in
                HStack(spacing: Theme.Space.base) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alt.label)
                            .font(Theme.Typo.ui(13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Text(verbatim: alt.blurb)
                            .font(Theme.Typo.ui(11))
                            .foregroundStyle(Theme.ink3)
                            // No lineLimit: this is the only place the
                            // difference between the two routes is explained,
                            // and it was being cut off mid-word ("rather t…"),
                            // which loses exactly the part that matters.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.small)
                    if alt.state == .connected {
                        // A connected alternate used to be a dead end: the
                        // word "Connected" and nothing to press. Folding the
                        // local Gmail in here made that visible — it was
                        // connected, and there was no way to remove it from
                        // anywhere on the screen.
                        HStack(spacing: Theme.Space.small) {
                            Text("Connected")
                                .font(Theme.Typo.label(9)).tracking(Theme.tracking)
                                .foregroundStyle(Theme.good)
                            PaneButton(title: "Remove", danger: true) { disconnectAlternate(alt) }
                        }
                    } else {
                        ConnectPressButton(title: "Connect", large: false, pressed: pressed) { alternate(alt) }
                    }
                }
                .padding(.vertical, Theme.Space.small)
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    /// A button says what will happen when you press it, not what state the
    /// row is in. "Fix" said nothing; "Show me how" is a promise the sheet
    /// keeps.
    static func primaryTitle(_ c: Connection) -> String? {
        switch (c.authKind, c.state) {
        case (.macPermission, .needsAttention): return c.settingsPaneURL == nil ? nil : "Show me how"
        case (.macPermission, _): return nil
        case (.terminal, .unavailable): return nil
        case (.terminal, _): return c.name == "whatsapp" ? "Link my phone…" : "Connect"
        case (.consent, .unavailable): return nil    // no Chrome on this Mac: nothing to turn on
        case (.consent, .needsAttention): return "Show me how"
        case (.consent, _): return "Turn on"
        case (.oneClick, .needsAttention): return "Try again"
        // Not available yet — the cloud cannot offer it from here — is not
        // a thing a click fixes, so no Add to Slack / Choose my address:
        // the row falls through to Check again and What's needed
        // (`offersCheckAgain`). Until 2026-09-16 the `(.oneClick, _)` arm
        // below caught this state first and drew the connect button over
        // a row that said not available.
        case (.oneClick, .unavailable): return nil
        // One click, two brands: Telegram makes you a bot, Slack adds Moe to
        // a workspace. The button says which.
        case (.oneClick, _):
            return c.name == "slack" ? "Add to Slack"
                : c.name == "moemail" ? "Choose my address" : "Create my Telegram bot"
        case (.appPassword, .needsAttention): return "Enter a new app password"
        case (.appPassword, _): return "Add a mailbox"
        case (_, .needsAttention): return "Reconnect"
        case (_, .unavailable): return c.kind == .mac ? nil : "Reconnect"
        // A brokered service already signed in: clicking again adds a SECOND
        // account, which most people eventually want (a personal Google and a
        // work one). "Sign in" there was worse than useless — the connector
        // refuses a duplicate, so the button did nothing and looked broken.
        // Always on: nothing to sign in to, so nothing to press.
        case (.none, _) where c.isAlwaysOn: return nil
        case (.oauth, .connected) where c.kind == .composio: return "Add another"
        case (.apiKey, .connected) where c.kind == .composio: return "Add another"
        case (.oauth, _): return "Sign in"
        case (.apiKey, _) where c.kind == .composio: return "Paste a key"
        default: return "Connect"
        }
    }

    /// Anything Moe has on file for this connection can be forgotten —
    /// whether it is working or not. Disconnect used to appear only on a
    /// working row, which left a connection whose own message said "remove
    /// it and connect again" with nothing to press. A macOS permission has
    /// nothing on file; it is taken back in System Settings. A brokered row
    /// with cleanup still pending at the broker keeps it too, connected or
    /// not: pressing it is how that cleanup is retried, and composio.py's
    /// message after a give-up tells the person to press it.
    nonisolated static func canDisconnect(_ c: Connection) -> Bool {
        guard c.state != .notConnected || c.cleanupPending, c.authKind != .macPermission, !c.isAlwaysOn else { return false }
        return c.authKind == .consent || c.authKind == .oneClick || !c.connectName.isEmpty
    }

    @ViewBuilder
    private var renameSheet: some View {
        if let (conn, acct) = renamingAccount {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("What should Moe call this \(conn.label) account?")
                    .font(Theme.Typo.heading(15))
                Text("Composio does not record which account a sign-in belongs to, "
                     + "so this is the only way to tell two of them apart. The name "
                     + "is stored with the account, so your other devices see it too.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Work, personal, the address…", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingAccount = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        renamingAccount = nil
                        guard !name.isEmpty else { return }
                        Task { await applyRename(conn, acct, name) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(Theme.Space.roomy)
            .frame(width: 380)
            .onAppear { renameText = acct.who }
        }
    }

    private func applyRename(_ c: Connection, _ acct: Connection.Account, _ name: String) async {
        guard let script = ScriptRunner.scriptPath("connect.sh") else { return }
        _ = await ScriptRunner.offMain {
            ScriptRunner.connect(["--name", c.connectName, acct.id, name],
                                 answers: nil, timeout: 30, started: { _ in })
        }
        _ = script
        await MainActor.run { check() }
    }

    /// Ask for a name for one account, then set it.
    private func renameAccount(_ c: Connection, _ acct: Connection.Account) {
        renamingAccount = (c, acct)
    }

    /// Remove one folded alternative without touching the row it sits in.
    private func disconnectAlternate(_ alt: Connection) {
        disconnectOther(alt)
    }

    /// The bar under the page. Every button that can start a connect is a
    /// `ConnectPressButton`, so it tells the flow where it is (D9.14).
    private var actions: some View {
        PaneActionBar {
            if c.state == .connected {
                if c.authKind == .appPassword {
                    ConnectPressButton(title: "Add a mailbox", pressed: pressed, action: action)
                } else if c.kind == .composio && !c.isAlwaysOn {
                    // A connected row never reaches primaryTitle — this branch
                    // returns before it — so putting "Add another account"
                    // there made it dead code, and the button simply did not
                    // exist. Which is what Izzy saw, and said twice.
                    ConnectPressButton(title: "Add another", pressed: pressed, action: action)
                } else if c.name == "slack" && c.authKind == .oneClick {
                    // The same dead-code shape as the Composio branch above:
                    // Self.primaryTitle(c) computes "Add to Slack" for the
                    // one-click case (a second workspace on the same
                    // account, CHANNELS-ONE-CLICK §3), but a connected row
                    // never reaches primaryTitle — this `if c.state ==
                    // .connected` block returns before it. The button
                    // existed in the title logic and nowhere on screen.
                    ConnectPressButton(title: "Add to Slack", pressed: pressed, action: action)
                } else if c.name == "moemail" {
                    // Moe's own email address (slice G3): the address is the
                    // thing a person wants from this row -- to put in their
                    // contacts or hand out -- so it can be copied, and changed.
                    // Drawn from `emailActions`, the one list the tests read.
                    ForEach(Self.emailActions(c), id: \.self) { title in
                        if title == "Copy address" {
                            PaneButton(title: title, large: true) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(c.address, forType: .string)
                            }
                            .disabled(c.address.isEmpty)
                        } else {
                            ConnectPressButton(title: title, pressed: pressed, action: action)
                        }
                    }
                }
                PaneButton(title: "Check now", symbol: "arrow.clockwise", large: true, action: check)
                    .disabled(checking)
                    .opacity(checking ? 0.5 : 1)
            } else if needsAccount {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    ConnectPressButton(title: "Sign in with Google to connect", prominent: true,
                                       pressed: pressed, action: action)
                    // D9.4: under every Google sign-in button.
                    if let line = Cloud.link.signInTermsLine() { line }
                }
            } else if let title = Self.primaryTitle(c) {
                ConnectPressButton(title: title, prominent: true, pressed: pressed, action: action)
            } else if isBlocked {
                if Self.offersCheckAgain(c) {
                    PaneButton(title: "Check again", symbol: "arrow.clockwise", large: true, action: checkAgain)
                        .disabled(checking)
                        .opacity(checking ? 0.5 : 1)
                }
                // Without this the row was a dead end: a grey "Not available
                // yet" and no way to find out what would change it.
                PaneButton(title: "What's needed", large: true, action: explain)
            }
        } trailing: {
            if Self.canDisconnect(c) {
                PaneButton(title: c.authKind == .consent ? "Turn off" : "Disconnect…", large: true, danger: true, action: disconnect)
            }
        }
    }
}

/// A button that starts a connect, and says where it is when it is pressed
/// (D9.14). The Google sign-in a first connect leads to answers only to a
/// person's press, and that press is this button's — but it was being judged
/// against the whole window (`HumanPressPlace.windowOfCurrentEvent`), because
/// the button had no place of its own: a live click anywhere in the window
/// would have done. The probe behind it is AppKit's own rectangle for it,
/// read at the moment of the press; `pressed` hands that to the flow before
/// the action runs, in the same event.
struct ConnectPressButton: View {
    let title: String
    var prominent = false
    var large = true
    let pressed: (HumanPressPlace) -> Void
    let action: () -> Void
    @State private var place: HumanPressPlace

    /// `place` is a parameter only so a test can hold the one the probe
    /// fills in; the screen never passes it.
    @MainActor
    init(title: String, prominent: Bool = false, large: Bool = true, place: HumanPressPlace? = nil,
         pressed: @escaping (HumanPressPlace) -> Void, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.large = large
        _place = State(initialValue: place ?? HumanPressPlace())
        self.pressed = pressed
        self.action = action
    }

    var body: some View {
        PaneButton(title: title, prominent: prominent, large: large) {
            Self.press(place, pressed: pressed, action: action)
        }
        .background(HumanPressProbe(place))
    }

    /// The press: where first, then what. The flow reads the place
    /// synchronously inside `action` (`ConnectFlow.needsAccount`), so the
    /// order is the whole point.
    static func press(_ place: HumanPressPlace, pressed: (HumanPressPlace) -> Void, action: () -> Void) {
        pressed(place)
        action()
    }
}

// MARK: - The flows that genuinely need a Terminal

/// Said plainly, before anyone is dropped into a black window: which flows
/// need one, why, and the exact command — so it can be run by hand if Moe
/// isn't allowed to open Terminal.
struct TerminalSetupSheet: View {
    let row: Connection
    let command: String
    let open: () -> String
    let close: () -> Void
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(row.label).font(.title3.weight(.semibold))
                if let g = SetupGuide.find(row.id) {
                    SetupGuideView(guide: g)
                } else {
                    Text(verbatim: row.blurb).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("The command, if you would rather type it yourself:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Copy the command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        note = "Copied. Open Terminal, press ⌘V, then Return."
                    }
                    Spacer()
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                    Button("Open Terminal for me") { note = open() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        .frame(maxHeight: 520)
    }
}

// MARK: - Full Disk Access

/// One sentence, the pane, and the relaunch macOS needs before it honours
/// the grant.
struct FullDiskAccessSheet: View {
    let row: Connection
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.label).font(.title3.weight(.semibold))
            // The words come from PermissionGuide, so this sheet, the
            // Permissions screen and onboarding cannot drift apart.
            PermissionExplainer(
                guide: .fullDiskAccess,
                lead: "\(row.label) is locked away by macOS until you let Moe read it.")
            Text("If Memoe isn't in the list, drag it in from the Finder window “Reveal Memoe” opens.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reveal Memoe") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Row

struct ConnectionRow: View {
    let connection: Connection
    let action: () -> Void
    let disconnect: () -> Void
    var alternate: (Connection) -> Void = { _ in }
    /// Shown for a row that cannot work yet, so "Unavailable" is a sentence
    /// with a next step rather than a red word.
    var explain: () -> Void = {}
    var checkAgain: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            monogram
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.snug) {
                    Text(connection.label)
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    statePill
                }

                // Catalog text: plain Text, never Markdown.
                //
                // An unavailable row's detail is the *reason* it cannot work
                // ("no Call Recordings folder in Notes"), which is the most
                // useful sentence on the row — so it is not clamped to two
                // lines and greyed out like a blurb.
                Text(verbatim: connection.detail.isEmpty ? connection.blurb : connection.detail)
                    .font(isBlocked ? Theme.Typo.ui(11, weight: .medium) : Theme.Typo.ui(11))
                    .foregroundStyle(isBlocked ? Theme.warn : Theme.ink3)
                    .lineLimit(isBlocked ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(connection.alternates) { alt in
                    Button(alt.state == .connected ? "\(alt.label) — connected" : alt.label) { alternate(alt) }
                        .buttonStyle(.plain)
                        .font(Theme.Typo.ui(11, weight: .semibold))
                        .foregroundStyle(alt.state == .connected ? Theme.ink3 : Theme.accentDeep)
                        .disabled(alt.state == .connected)
                }
            }

            Spacer(minLength: Theme.Space.small)

            if connection.state == .connected {
                PaneButton(title: "Disconnect", action: disconnect)
            } else if let title = buttonTitle {
                PaneButton(title: title, action: action)
            } else if isBlocked {
                if ConnectionDetail.offersCheckAgain(connection) {
                    PaneButton(title: "Check again", action: checkAgain)
                }
                // Every path above declined to offer a button. Without this
                // the row was a dead end: a red "Unavailable" and no way to
                // find out what would change it.
                PaneButton(title: "What's needed", action: explain)
            }
        }
        .padding(.vertical, Theme.Space.small)
    }

    private var isBlocked: Bool { connection.state == .unavailable }

    /// A button says what will happen when you press it, not what state the
    /// row is in. "Fix" said nothing; "Show me how" is a promise the sheet
    /// keeps.
    private var buttonTitle: String? {
        switch (connection.authKind, connection.state) {
        case (.macPermission, .needsAttention): return connection.settingsPaneURL == nil ? nil : "Show me how"
        case (.macPermission, _): return nil
        case (.terminal, .unavailable): return nil
        case (.terminal, _): return connection.name == "whatsapp" ? "Link my phone…" : "Connect"
        case (.consent, .unavailable): return nil    // no Chrome on this Mac: nothing to turn on
        case (.consent, .needsAttention): return "Show me how"
        case (.consent, _): return "Turn on"
        case (.oneClick, .needsAttention): return "Try again"
        // One click, two brands: Telegram makes you a bot, Slack adds Moe to
        // a workspace. The button says which.
        case (.oneClick, _):
            return connection.name == "slack" ? "Add to Slack"
                : connection.name == "moemail" ? "Choose my address" : "Create my Telegram bot"
        case (.appPassword, .needsAttention): return "Enter a new app password"
        case (.appPassword, _): return "Add a mailbox"
        case (_, .needsAttention): return "Reconnect"
        case (_, .unavailable): return connection.kind == .mac ? nil : "Reconnect"
        // A brokered service already signed in: clicking again adds a SECOND
        // account, which most people eventually want (a personal Google and a
        // work one). "Sign in" there was worse than useless — the connector
        // refuses a duplicate, so the button did nothing and looked broken.
        // Always on: nothing to sign in to, so nothing to press.
        case (.none, _) where connection.isAlwaysOn: return nil
        case (.oauth, .connected) where connection.kind == .composio: return "Add another"
        case (.apiKey, .connected) where connection.kind == .composio: return "Add another"
        case (.apiKey, _) where connection.kind == .composio: return "Paste a key"
        case (.oauth, _): return "Sign in"
        default: return "Connect"
        }
    }

    @ViewBuilder
    private var statePill: some View {
        switch connection.state {
        case .connected:
            pill("Connected", Theme.good)
        case .needsAttention:
            pill(connection.authKind == .macPermission ? "Needs your permission" : "Needs attention", Theme.warn)
        // Not red. Nothing is broken and nothing needs fixing — this is a
        // source that is not here yet, and red says "error" about a state
        // that is closer to "not applicable".
        //
        // "Not available yet" is about the service: it is not out for this
        // account. A Mac source is out — it is on this Mac — and what it
        // says is about this minute (the sentence underneath says which),
        // so the pill above a freshly scanned WhatsApp must not read as
        // "Moe does not do WhatsApp yet".
        case .unavailable:
            pill(connection.unavailableWords == nil ? "Not available yet" : "Not ready yet", Theme.ink3)
        case .notConnected:
            EmptyView()
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.Typo.label(9))
            .tracking(Theme.tracking)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    /// Bundled art where we have it, an SF Symbol for the Mac's own sources,
    /// and a monogram in the service's own colour for the long tail. See
    /// ServiceIcon — the point is that two adjacent rows never look the same.
    private var monogram: some View {
        ServiceIcon(name: connection.name,
                    label: connection.label,
                    macSymbol: connection.kind == .mac
                        ? ServiceIcons.macSymbol(for: connection.name) : nil)
    }
}

// MARK: - The connect flow

/// One connect (or disconnect) at a time, driven from the sheet. All the
/// script work runs detached; only the phase is published.
///
/// Every script speaks the same few machine lines (`MachineLine`), so one
/// driver serves them all: a sign-in page opens the browser, `NEED=<field>`
/// shows one field and writes the answer to the still-open stdin,
/// `QR=` draws a code, `NEEDS_RESTART=gateway` restarts the brain after a
/// clean exit. The sheet only ever shows one thing to do.
@MainActor
final class ConnectFlow: ObservableObject {
    enum Phase: Equatable {
        case keys                      // the paste sheet
        case signingIn(url: String)    // browser open, waiting for the callback
        case chooseMailbox([String])   // which Gmail mailbox to disconnect
        case field(String)             // NEED=<field>: one thing to type
        case confirming(String)        // must be dismissed before anything starts
        case qr(String)                // scan this from the phone
        case pairing                   // the bot is up; waiting for the phone to say hello
        case working(String)           // a sentence and a spinner
        case done(String)
        case failed(String)
    }

    @Published var presented = false
    @Published var phase: Phase = .working("")
    @Published var connection: Connection?
    /// Field values, by env key. Cleared when the sheet closes.
    @Published var values: [String: String] = [:]
    @Published var pastedAddress = ""
    /// The one answer a NEED= step is waiting for.
    @Published var fieldValue = ""
    /// A failed one-click flow can fall back to pasting a key by hand.
    @Published var offerKeys = false
    /// A brokered service that takes a key: what to paste, in the service's
    /// own terms, asked of Composio's record just before the sheet draws
    /// (`askForKey`). Empty for every other row.
    @Published var pasteFields: [KeyField] = []
    @Published var pasteHelpURL = ""
    /// Who has said hello to the bot while the pairing step is open.
    @Published var waiting: [Pairing] = []
    @Published var approved: Set<String> = []
    /// Set when something was connected or removed, so the list reloads.
    private(set) var changed = false
    /// The connection this flow just connected, for the screen's "learn
    /// about you?" question once the sheet has gone (docs/DEFAULTS.md row
    /// 25). The screen reads it and clears it.
    var justConnected: Connection?

    /// Set by the screen: the model (pairings) and the brain restart hook.
    weak var model: ConnectionsModel?
    var restartGateway: (() -> Void)?
    /// CLOUD-PLAN §19.11: whether this Mac has an account yet, and how to get
    /// one. A brokered (Composio) service needs this Mac's own Composio
    /// project, which needs a tenant, which since 2026-09-06 comes from Sign
    /// in with Google. Set by the screen, like `restartGateway`; nil means
    /// "never ask" (a test, or a build with no cloud).
    var needsAccount: (() -> Bool)?
    /// Signs in, founds or joins the tenant, stores the Composio key, and
    /// returns when `.env` carries it. Returns the address signed in with.
    var signInToAccount: (() async throws -> String)?
    /// D9.14: where the button that is starting this flow is, set by that
    /// button in its own action (`ConnectPressButton`) and good for exactly
    /// one `start` — `takePressPlace` hands it over and forgets it, so a
    /// later start from somewhere else (the sheet's "Also" link) is never
    /// judged against a button in another window.
    var pressPlace: HumanPressPlace?
    func takePressPlace() -> HumanPressPlace? {
        defer { pressPlace = nil }
        return pressPlace
    }
    /// True while the sheet is about taking something away. The done and
    /// failed steps read it: "what just became possible" and "the sign-in
    /// page can time out" are sentences about connecting.
    @Published private(set) var removing = false

    /// The sheet in one of its steps without anything having run, for
    /// `--settings-snapshot`.
    func pose(_ c: Connection, phase: Phase, removing: Bool = false) {
        connection = c
        self.phase = phase
        self.removing = removing
    }

    private var child: ScriptRunner.Child?
    private var pollTask: Task<Void, Never>?
    private var needsRestart = false

    // MARK: What this flow may launch

    /// Every script the connect, scan and disconnect paths start, and every
    /// "is it connected?" they ask, goes through these three. The app never
    /// sets them. Tests/MoeAppTests replaces all three, so no test can start
    /// connect.sh — which for Signal would download 180 MB and ask a real
    /// phone to link, on whichever Mac ran the suite.
    typealias Launch = @Sendable (_ script: String, _ args: [String], _ answers: [String: String]?,
                                  _ timeout: TimeInterval, _ keepStdinOpen: Bool, _ extraEnv: [String: String],
                                  _ started: ((ScriptRunner.Child) -> Void)?, _ onLine: ((String) -> Void)?)
        -> ScriptRunner.Result
    var locateScript: (String) -> String? = { ScriptRunner.scriptPath($0) }
    var launchScript: Launch = {
        ScriptRunner.runScript($0, $1, answers: $2, timeout: $3, keepStdinOpen: $4, extraEnv: $5,
                               started: $6, onLine: $7)
    }
    var checkConnected: @Sendable (String) -> Bool = { ScriptRunner.isConnected($0) }
    /// learn/consent.sh `grant|revoke NAME`, for an opt-in source's switch.
    /// Replaced by tests the same way, so none of them writes a consent file.
    var runConsent: @Sendable (_ verb: String, _ name: String) -> ScriptRunner.Result = { verb, name in
        ScriptRunner.run(Paths.home.appendingPathComponent("learn/consent.sh").path, [verb, name], timeout: 30)
    }

    /// macOS-permission rows (Calendar, Reminders, Notes…) this screen sent
    /// the person to System Settings for. There is no script to finish and
    /// no sheet to close: the grant is known only when the list is read
    /// again and the row reads connected (`permissionsChecked`).
    private(set) var awaitingPermission: Set<String> = []

    nonisolated static let signInTimeout: TimeInterval = 180
    /// connect-whatsapp-bot.sh waits 180 s for a scan by default; the app
    /// must outlast it, or the sheet says "nobody scanned" while the script
    /// is still showing a live code.
    nonisolated static let scanTimeout: TimeInterval = 240
    /// Signal's first connect downloads Signal support before there is a code
    /// to show (~180 MB, once — scripts/fetch-signal-cli.sh), and then waits
    /// the same 180 s for the scan. The app's clock must outlast both.
    nonisolated static let signalScanTimeout: TimeInterval = 900
    /// Choosing documents takes longer than clicking Allow: the page that
    /// opens is a whole file browser, and the script waits for the user to
    /// finish before it can do anything. Comfortably past the script's own
    /// 180-second ceiling, so the sentence the user reads when nobody
    /// finishes is the script's own, not "That took too long."
    nonisolated static let pickTimeout: TimeInterval = 300

    func start(_ c: Connection) {
        // Whatever this start does with the press, the next one gets its own.
        defer { pressPlace = nil }
        removing = false
        connection = c
        values = [:]
        pastedAddress = ""
        fieldValue = ""
        offerKeys = false
        pasteFields = []
        pasteHelpURL = ""
        waiting = []
        approved = []
        needsRestart = false
        changed = false
        presented = true
        if c.kind == .mac {
            startMac(c)
            return
        }
        switch c.authKind {
        // A brokered service Composio holds no sign-in for: the key goes to
        // Composio, so this Mac needs its account first, same as a sign-in.
        case .apiKey where c.kind == .composio: withAccount(c) { self.askForKey(c) }
        case .apiKey, .appPassword: phase = .keys
        // A QR code: nothing is typed and nothing is pasted. The
        // script emits QR=<payload> and `handle(_:)` puts the sheet
        // into its .qr phase, replacing the code each time WhatsApp
        // rotates one — so the spinner below is only what is shown
        // while the bridge starts.
        case .scan:
            // Signal is the one linked device that hands over the WHOLE
            // account — every chat and group, not just what is sent to
            // Moe — and the row's blurb is read at whatever pace someone
            // scrolls at, same as every other warning here. That is fine
            // for WhatsApp's ban-risk note; it is not enough for handing
            // over an entire account, so this one has to be dismissed
            // before the phone is even asked for a code.
            if c.name == "signal" {
                phase = .confirming(
                    "Linking gives this Mac your whole Signal account — every chat and group Signal shows you, not only what is sent to Moe. Moe answers only in Note to Self; it does not act on anything else. You can unlink from Signal › Settings › Linked devices at any time.")
            } else {
                scan(c)
            }
        case .oauth:
            if c.kind == .composio { withAccount(c) { self.signIn(c) } } else { signIn(c) }
        case .oneClick: oneClick(c)
        case .none, .terminal: plain(c)
        case .consent: setConsent(c, on: true)
        case .macPermission:
            awaitPermission(c)
            presented = false
        }
    }

    /// The person was sent to System Settings to grant `c`.
    func awaitPermission(_ c: Connection) {
        guard c.state != .connected else { return }
        awaitingPermission.insert(c.id)
    }

    /// The list was read again. A permission row the person was sent to
    /// grant that now reads connected is a first successful connect, the
    /// same as `succeed()` for a sign-in: it sets `justConnected`, so the
    /// "learn about you?" question comes for it (docs/DEFAULTS.md row 25).
    func permissionsChecked(_ rows: [Connection]) {
        guard !awaitingPermission.isEmpty else { return }
        for row in rows where awaitingPermission.contains(row.id) && row.state == .connected {
            awaitingPermission.remove(row.id)
            justConnected = row
        }
    }

    /// A brokered service needs this Mac's own Composio project, which needs
    /// an account: sign in first, then do the thing. Two Google screens at
    /// first connect — ours for who this is, Composio's for Gmail — is the
    /// honest price of a tenant, and it is paid once. With an account
    /// already (or no way to make one: a test, a build with no cloud) the
    /// thing is done at once.
    private func withAccount(_ c: Connection, then: @escaping () -> Void) {
        guard needsAccount?() == true, let signInToAccount else { then(); return }
        phase = .working("Signing you in with Google, so your connections stay yours…")
        Task { @MainActor [weak self] in
            do {
                let address = try await signInToAccount()
                Log.write("connect: signed in (\(address.isEmpty ? "no address" : "an address")); on to \(c.name)")
                guard self?.presented == true else { return }
                then()
            } catch {
                self?.phase = .failed(CertificateFailure.matches("\(error)")
                    ? CertificateFailure.sentence
                    : "Couldn't sign you in: \(error). Nothing was connected; try again.")
            }
        }
    }

    /// Ask Composio's record of the service what it wants pasted — its own
    /// field names, and where each one is found — and only then draw the
    /// sheet. Nothing here knows what Firecrawl calls its key; a table in
    /// this app would be wrong for some of 1,200 services and nobody would
    /// notice until a paste landed in a field the service never reads.
    private func askForKey(_ c: Connection) {
        phase = .working("Asking what \(c.label) needs…")
        let name = c.connectName
        Task {
            let result = await ScriptRunner.offMain { ScriptRunner.connect(["--fields", name], timeout: 45) }
            await MainActor.run {
                guard self.presented, self.connection?.id == c.id else { return }
                let parsed = KeyField.parse(ConnectionsModel.jsonPart(of: result.output))
                if parsed.fields.isEmpty {
                    self.phase = .failed(parsed.managed
                        ? "\(c.label) signs in with a page rather than a key. Try Sign in instead."
                        : (result.lastHumanLine.isEmpty
                           ? "Couldn't find out what \(c.label) needs. Check the connection and try again."
                           : result.lastHumanLine))
                    return
                }
                self.pasteFields = parsed.fields
                self.pasteHelpURL = parsed.helpURL
                self.values = [:]
                self.phase = .keys
            }
        }
    }

    func cancel() {
        child?.cancel()
        child = nil
        pollTask?.cancel()
        pollTask = nil
        presented = false
    }

    func close() {
        pollTask?.cancel()
        pollTask = nil
        child?.cancel()      // done or failed: nothing left to wait for
        child = nil
        presented = false
    }

    // MARK: The generic driver

    /// Run a script, react to its machine lines, and settle the phase when
    /// it exits. `statusName` is what `connect.sh --status` checks after;
    /// empty means exit 0 is the verdict (the Mac-side scripts).
    private func drive(script: String, args: [String], answers: [String: String]?, keepStdinOpen: Bool,
                       extraEnv: [String: String] = [:], statusName: String, brand: String, timeout: TimeInterval) {
        let launch = launchScript
        Task {
            let result = await ScriptRunner.offMain {
                launch(script, args, answers, timeout, keepStdinOpen, extraEnv,
                       { child in Task { @MainActor in self.child = child } },
                       { line in
                    guard let m = MachineLine.parse(line) else { return }
                    Task { @MainActor in self.handle(m, statusName: statusName) }
                })
            }
            await self.finishAfterScript(result, connectName: statusName)
        }
    }

    private func handle(_ m: MachineLine, statusName: String) {
        switch m {
        case .signInURL(let url):
            guard case .working = phase else { return }
            // The one place opening a browser is right: the user just clicked.
            NSWorkspace.shared.open(url)
            phase = .signingIn(url: url.absoluteString)
            if !statusName.isEmpty { startPolling(statusName) }
        case .need(let field):
            fieldValue = ""
            phase = .field(field)
        case .qr(let payload):
            phase = .qr(payload)
        case .linked:
            // The scan worked. The code on screen is dead the moment the
            // phone accepts it, and the script then spends minutes fetching
            // the history and asking for a restart — so this is the only
            // point at which the person can be told, and until 2026-09-20
            // nothing told them: the sheet held the used code until the
            // script exited. Only ever from the waiting phases; a flow that
            // has already settled is not reopened by a late line.
            switch phase {
            case .qr, .working: phase = .working("Linked. Getting your chats…")
            default: break
            }
        case .needsRestart:
            needsRestart = true
        }
    }

    /// The NEED= step's answer goes down the still-open stdin.
    func submitField() {
        guard case .field(let field) = phase, let child else { return }
        let value = fieldValue
        fieldValue = ""
        phase = .working("Checking…")
        child.send(field.uppercased(), value)
    }

    /// The Continue button: the first field starts the Mac-side script;
    /// later ones answer a script that is already waiting.
    func continueField() {
        if child == nil, connection?.name == "moemail" { chooseEmailName(); return }
        if child == nil, connection?.kind == .mac { submitMac() } else { submitField() }
    }

    /// Wording for the field the script is waiting for.
    var fieldLabel: String {
        guard case .field(let f) = phase else { return "" }
        if f == "moemail_name" {
            return "A name for your address. Mail to it at @in.moebot.app reaches your Moe."
        }
        return Connection.promptLabel(field: f, brand: brand)
    }

    /// What to do next after a failure. Every failure path ends on one of
    /// these, so the sheet never leaves someone holding an error and no idea
    /// what to do with it.
    var nextStep: String {
        // A connection that could not be made securely is never the key or
        // the page: the advice below would send someone to paste it again.
        if case .failed(let text) = phase, text == CertificateFailure.sentence {
            return CertificateFailure.nextStep
        }
        guard let c = connection else { return "Close this and try again. Nothing was changed." }
        // A removal that failed has none of the connect advice below to
        // offer: there was no page to time out and no key to copy again.
        if removing { return "Close this and try again in a moment. Press Check now first if the list looks out of date." }
        switch c.authKind {
        case .appPassword:
            return "Check the address is right, and that all 16 letters came across. If Google says the password is wrong, delete that one on Google's app passwords page, create a fresh one, and paste that instead."
        case .oauth:
            return "Try again — the page can time out if it is left open. If \(c.label) says Moe isn't allowed, whoever runs your \(c.label) account may have to approve it."
        case .apiKey:
            return "Check the key was copied whole, with no spaces at either end, and that it is a key for the right account. Then try again."
        case .oneClick where c.name == "moemail":
            return "Try another name. A name is 3 to 31 letters, digits, dots, hyphens or underscores, and a name somebody gave up in the last thirty days can't be taken yet."
        case .oneClick:
            return "Try again. If it keeps failing, you can make the bot yourself in Telegram and paste its key here instead."
        case .scan:
            if c.name == "signal" {
                return "The code expires quickly — start it again and scan it as soon as it appears. Signal limits how many devices one account can link; if your phone says it cannot link another, remove an old one first: Signal › Settings › Linked devices."
            }
            return "The code expires quickly — start it again and scan it as soon as it appears. If your phone says it cannot link another device, remove an old one first: WhatsApp › Settings › Linked Devices."
        case .terminal:
            // Telegram used to share this auth kind with WhatsApp and they
            // did not share a failure. WhatsApp has moved to .scan; what is
            // left here is Telegram's phone login, where the code is texted
            // and there is nothing to scan.
            if c.name == "telegram" {
                return "If Telegram would not accept the api_id and api_hash, copy both again from my.telegram.org/apps — the api_hash is exactly 32 characters, and pasting it twice is the usual cause. Otherwise check the number is the one Telegram is registered to, with its country code."
            }
            return "The code expires quickly — start it again and scan it as soon as it appears."
        case .consent:
            return "Try again. If it still won't switch on, Moe may not be allowed to read that app's files yet — Settings › Permissions explains how to fix that."
        case .macPermission, .none:
            return "Try again, or click “Check again” at the bottom of this screen."
        }
    }

    var brand: String {
        guard let c = connection else { return "It" }
        switch c.name {
        case "telegram": return "Telegram"
        case "whatsapp": return "WhatsApp"
        case "signal": return "Signal"
        case "gmail": return "Google"
        default: return c.label
        }
    }

    // MARK: Sign in (browser)

    private func signIn(_ c: Connection, timeout: TimeInterval? = nil) {
        phase = .working("Getting the sign-in page ready…")
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        // A brokered service that is already signed in means "add another
        // account". Without --another the connector answers "already
        // connected" and exits 0, so the button appears to do nothing —
        // which is exactly what it did before this line existed.
        var args = [c.connectName]
        if c.kind == .composio, c.state == .connected { args.append("--another") }
        drive(script: script, args: args, answers: [:], keepStdinOpen: false,
              statusName: c.connectName, brand: c.label, timeout: timeout ?? Self.signInTimeout)
    }

    private func startPolling(_ name: String) {
        pollTask?.cancel()
        let check = checkConnected
        let model = self.model
        pollTask = Task {
            let deadline = Date().addingTimeInterval(Self.signInTimeout)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let ok = await ScriptRunner.offMain { check(name) }
                if Task.isCancelled { return }
                if ok {
                    await MainActor.run { self.succeed() }
                    return
                }
                // Moe's own Slack app, on a cloud that could not ask for the
                // Google sign-in: the install finished in the browser and now
                // waits for THIS Mac's word. The status poll above has just
                // written it into the marker, so ask for it here rather than
                // spin until the sheet times out (second review of slice G1).
                // The same for Telegram: the bot is made, the phone has said
                // hello, and the status reads "waiting to be let in" — never
                // "connected" until someone approves. Polling only for
                // connected spun the sheet on "Finish in Telegram…" until it
                // timed out, with the person's own hello unanswered behind it
                // (owner, 2026-11-13).
                if name == "platform/slack" || name == "platform/telegram", let model {
                    let slack = name == "platform/slack"
                    let found = await model.refreshPairings().filter { $0.isSlackInstall == slack }
                    if Task.isCancelled { return }
                    if !found.isEmpty {
                        await MainActor.run { self.waiting = found; self.startPairing() }
                        return
                    }
                }
            }
        }
    }

    /// The script has exited: connected, or here is why not.
    private func finishAfterScript(_ result: ScriptRunner.Result, connectName: String) async {
        // Cancelled (sheet closed, pane left): no one is looking; skip the check.
        guard presented else { child = nil; return }
        child?.closeInput()
        child = nil
        // NEEDS_RESTART=gateway after a clean exit: the gateway only reads
        // .env and config.yaml at start, so without this the new platform is
        // dead until the next launch. Once, and before any early return —
        // the status poll may already have declared success (a token in
        // .env reads as connected before the gateway has picked it up).
        if needsRestart, result.status == 0 {
            needsRestart = false
            // Settled means the sheet has already told the person how this
            // ended. A QR code is not that: the script exits with one still
            // on screen, and treating it as settled left the sheet showing a
            // used code, restarted the brain behind it, and returned —
            // never calling `succeed()`, so `changed` stayed false and the
            // pane behind never reloaded either. That is exactly what the
            // owner saw on 2026-09-20: "in real time, it wasn't showing
            // 'connecting' or 'connected'."
            let settled: Bool
            switch phase {
            case .working, .qr: settled = false
            default: settled = true
            }
            if !settled { phase = .working("Restarting Moe's brain so it picks this up…") }
            restartGateway?()
            if settled { return }
            let name = connectName
            let check = checkConnected
            let ok = await ScriptRunner.offMain { () -> Bool in
                let deadline = Date().addingTimeInterval(90)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 3)
                    if name.isEmpty || check(name) { return true }
                }
                return false
            }
            guard presented else { return }
            if ok { succeed() } else { phase = .failed("Moe is taking a while to come back. Wait a minute, then click “Check again” at the bottom of this screen.") }
            return
        }
        if case .done = phase { return }
        if case .pairing = phase { return }
        let ok: Bool
        if connectName.isEmpty { ok = result.status == 0 }
        else {
            let check = checkConnected
            ok = await ScriptRunner.offMain { check(connectName) }
        }
        guard presented else { return }
        if ok { succeed(); return }
        if case .done = phase { return }
        if result.timedOut { phase = .failed("That took too long. Try again."); return }
        phase = .failed(result.lastHumanLine.isEmpty ? "Didn't connect." : result.lastHumanLine)
    }

    private func succeed() {
        guard presented else { return }
        pollTask?.cancel()
        changed = true
        justConnected = connection
        if connection?.authKind == .oneClick {
            startPairing()
        } else {
            phase = .done("\(connection?.label ?? "It") is connected.")
        }
    }

    private static let missingConnect = "Couldn't find connect.sh (expected in ~/.moe/scripts)."

    // MARK: One click (the Telegram bot)

    private func oneClick(_ c: Connection) {
        // Moe's own email address (slice G3): one thing to type, a name, and
        // then `connect.sh platform/moemail <name>`. The sheet's one-field step
        // asks it; `continueField` sends it (`chooseEmailName`).
        if c.name == "moemail" {
            fieldValue = ""
            phase = .field("moemail_name")
            return
        }
        phase = .working(c.name == "slack" ? "Opening Slack…" : "Creating your Telegram bot…")
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        // connect.sh's dispatch: a bare `telegram` is the Mac-side chats
        // login (connect-telegram.sh, which would wait for a phone number);
        // `platform/telegram` is the bot — managed by default, `--token`
        // (submitKeys) to paste one from BotFather.
        drive(script: script, args: ["platform/\(c.name)"], answers: [:], keepStdinOpen: false,
              statusName: "platform/\(c.name)", brand: c.label, timeout: Self.signInTimeout)
        offerKeys = true
    }

    /// Moe's own email address: the name typed in the one-field step, handed to
    /// `connect.sh platform/moemail <name>` as one argument. connect.sh checks
    /// its shape and Moe's cloud decides whether it is free; success is the
    /// row reading connected (`--status platform/moemail`).
    private func chooseEmailName() {
        let name = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return }
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        fieldValue = ""
        phase = .working("Choosing \(name)@in.moebot.app…")
        drive(script: script, args: ["platform/moemail", name], answers: [:], keepStdinOpen: false,
              statusName: "platform/moemail", brand: "Email", timeout: 60)
    }

    /// The one-click flow didn't work out: paste the key from BotFather instead.
    func fallBackToKeys() {
        offerKeys = false
        values = [:]
        phase = .keys
    }

    // MARK: Pairing (the phone says hello, the user lets it in)

    private func startPairing() {
        phase = .pairing
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let model {
                    let found = await model.refreshPairings()
                    if Task.isCancelled { return }
                    // The Slack sheet waits for its own install, the Telegram
                    // sheet for a phone saying hello — never each other's.
                    let slack = self.connection?.name == "slack"
                    self.waiting = found.filter { $0.isSlackInstall == slack }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// From the banner or the pairing step.
    func approve(_ p: Pairing) {
        if !presented {
            connection = nil
            changed = false
            presented = true
            phase = .working("Letting \(p.name) in…")
        }
        Task {
            let r = await ScriptRunner.offMain { ScriptRunner.approvePairing(p) }
            await MainActor.run {
                if r.status == 0 {
                    self.approved.insert(p.id)
                    self.model?.forget(p)
                    self.waiting.removeAll { $0.id == p.id }
                    if case .working = self.phase {
                        self.phase = .done(p.isSlackInstall ? "Moe is in Slack now." : "\(p.name) can talk to Moe on \(p.platformLabel) now.")
                    }
                } else if case .working = self.phase {
                    self.phase = .failed(r.lastHumanLine.isEmpty ? "Couldn't let them in." : r.lastHumanLine)
                }
            }
        }
    }

    // MARK: Keys

    func submitKeys() {
        guard let c = connection else { return }
        phase = .working("Saving…")
        let answers = values
        values = [:]
        let name = c.authKind == .oneClick ? "platform/\(c.name)" : c.connectName
        // A pasted key for the one-click bot: `--token` tells connect.sh to
        // take it from stdin instead of creating a bot. For a brokered
        // service, `--key`: the answers go to Composio as the account, and
        // it is live the moment connect.sh exits.
        var args = [name]
        if c.authKind == .oneClick { args.append("--token") }
        if c.kind == .composio {
            args.append("--key")
            // "Add another" on a connected key row. Without --another the
            // connector answers "already connected" and makes nothing, and
            // this sheet used to close on that as though it had worked —
            // the same silent no-op signIn(_:) fixed for the link rows.
            if c.state == .connected { args.append("--another") }
        }
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        drive(script: script, args: args, answers: answers, keepStdinOpen: false,
              statusName: name, brand: c.label, timeout: 120)
    }

    // MARK: Plain

    /// "Add an MCP server": any server Hermes can reach, by address.
    /// `connect.sh --url` is the same road the catalogue rows take, one step
    /// earlier — Hermes learns the server, and whatever tools it turns out to
    /// carry arrive with it. Nothing here names a service, and nothing here
    /// picks which of its tools Moe may use: that curation is exactly what
    /// made a connected server invisible to the brain once already.
    ///
    /// A server that wants a sign-in prints `SIGNIN=` and the generic driver
    /// opens the browser, same as every catalogue row.
    func startCustomMCP(name: String, address: String, auth: String) {
        connection = nil
        values = [:]
        pastedAddress = ""
        fieldValue = ""
        offerKeys = false
        waiting = []
        approved = []
        needsRestart = false
        changed = false
        removing = false
        presented = true
        phase = .working("Adding \(name)\u{2026}")
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        // AUTH is the one thing connect.sh asks for on the way through
        // (`ask_value auth AUTH`); answering it here keeps the sheet from
        // bouncing the user into a bare NEED= text field.
        drive(script: script, args: ["--url", name, address], answers: ["AUTH": auth], keepStdinOpen: false,
              statusName: name, brand: name, timeout: Self.signInTimeout)
    }

    /// A QR code, drawn here. Runs connect.sh for the platform, which drives
    /// Hermes's bundled bridge and prints QR=<payload> lines; `handle(_:)`
    /// swaps the sheet into its .qr phase on each. Until 2026-09-11 this
    /// case set the spinner text and launched nothing — "Getting a code for
    /// you…" spun until Cancel, on every Mac, from the day WhatsApp moved to
    /// .scan (59a95548). The app's timeout is deliberately looser than the
    /// script's own (180 s): a backstop tighter than what it backs reports
    /// "nobody scanned" over a scan in flight.
    private func scan(_ c: Connection) {
        phase = .working("Getting a code for you…")
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        drive(script: script, args: [c.connectName], answers: [:], keepStdinOpen: false,
              statusName: c.connectName, brand: c.label,
              timeout: c.name == "signal" ? Self.signalScanTimeout : Self.scanTimeout)
    }

    /// The far side of `.confirming`: only reachable by tapping Continue on
    /// the whole-account warning, never by re-entering `start(_:)`.
    func confirmedScan(_ c: Connection) {
        scan(c)
    }

    private func plain(_ c: Connection) {
        phase = .working(c.name == "whatsapp" ? "Getting WhatsApp ready to pair…" : "Setting up…")
        guard let script = locateScript("connect.sh") else { phase = .failed(Self.missingConnect); return }
        drive(script: script, args: [c.connectName], answers: [:], keepStdinOpen: false,
              statusName: c.connectName, brand: c.label, timeout: Self.signInTimeout)
    }

    // MARK: The Mac-side scripts (Gmail app password, Telegram chats)

    private func startMac(_ c: Connection) {
        // An opt-in source has no setup script to run; the switch is the flow.
        if c.authKind == .consent { setConsent(c, on: true); return }
        switch c.name {
        case "gmail": phase = .keys
        // Was `.field("phone")`: one bare box, and then the script died on a
        // missing application pair with an error naming environment
        // variables. The sheet asks for everything it actually needs, with
        // the guide above it.
        case "telegram": phase = .keys
        case "drive-docs":
            // No sheet: there is nothing for the user to type. The script
            // prints the address, the app opens it, and the script then
            // blocks until the browser comes back with what was picked — so
            // its own exit code is the verdict, and there is nothing to poll.
            signIn(c, timeout: Self.pickTimeout)
        case "drive-docs-pick":
            // The same script, asked to reopen the picker and merge whatever
            // comes back into the list that is already there.
            guard let script = ScriptRunner.scriptPath(c.setupScript) else {
                phase = .failed("Couldn't find \(c.setupScript)."); return
            }
            phase = .working("Getting the page ready…")
            drive(script: script, args: ["pick"], answers: [:], keepStdinOpen: false,
                  statusName: "", brand: c.label, timeout: Self.pickTimeout)
        default:
            // `locateScript`, not ScriptRunner.scriptPath: the same seam
            // every other path here goes through, so a test can drive this
            // one without a connect script installed on the Mac running it.
            guard !c.setupScript.isEmpty, let script = locateScript(c.setupScript) else {
                phase = .failed("Couldn't find \(c.setupScript)."); return
            }
            phase = .working(c.authKind == .scan ? "Getting a code for you…" : "Setting up…")
            // A scanned Mac source (WhatsApp) is the one row here whose
            // script exits before the thing it set up is working: the link
            // is made, the brain restarts, and the bridge reaches WhatsApp
            // a few seconds later. So this one is verified against its own
            // connector — `mac/<key>`, which ScriptRunner.isConnected runs —
            // rather than against the script's exit code, which was 0 while
            // the row still read "the link to your phone has dropped".
            // Everything else here keeps exit 0 as the verdict.
            //
            // WhatsApp's script waits 180 s for the phone; 120 here cut it off
            // with a code still on screen.
            drive(script: script, args: [], answers: [:], keepStdinOpen: false,
                  statusName: c.authKind == .scan ? "mac/\(c.name)" : "", brand: c.label,
                  timeout: c.authKind == .scan ? Self.scanTimeout : 120)
        }
    }

    /// Gmail: the two fields go down at once. Telegram chats: the phone
    /// number first, then whatever the script asks (a code, a password).
    func submitMac() {
        guard let c = connection, let script = ScriptRunner.scriptPath(c.setupScript) else {
            phase = .failed("Couldn't find \(connection?.setupScript ?? "the setup script")."); return
        }
        switch c.name {
        case "gmail":
            let answers = ["EMAIL": values["EMAIL"] ?? "", "PASSWORD": values["PASSWORD"] ?? ""]
            values = [:]
            phase = .working("Checking with Google…")
            drive(script: script, args: [], answers: answers, keepStdinOpen: false, statusName: "", brand: "Google", timeout: 120)
        case "telegram":
            // The pair goes down with the phone number: connect-telegram.sh
            // reads API_ID=/API_HASH= before it breaks on PHONE=, and stores
            // them, so this is asked once and never again. A pair the app
            // already has wins over anything typed.
            let pair = TelegramAppKeys.resolved
            // Normalised, not as typed: the script takes `+` and digits and
            // nothing else, and what a person types has spaces and brackets
            // in it.
            let phone = TelegramAppKeys.normalisedPhone(values["PHONE"] ?? fieldValue)
            var answers = ["PHONE": phone]
            let typedID = (values["API_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let typedHash = (values["API_HASH"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answers["API_ID"] = pair?.id ?? typedID
            answers["API_HASH"] = pair?.hash ?? typedHash
            values = [:]
            fieldValue = ""
            phase = .working("Asking Telegram to send you a code…")
            drive(script: script, args: [], answers: answers, keepStdinOpen: true, statusName: "", brand: "Telegram",
                  timeout: Self.signInTimeout * 2)
        default: break
        }
    }

    /// The Gmail sheet's two fields, in the paste sheet's shape.
    /// The fields the sheet shows for a Mac connector, before the script
    /// starts. Telegram's depend on whether this copy of Memoe already has an
    /// application pair: with one, a phone number is genuinely all we need.
    var macKeys: [(key: String, label: String, secret: Bool)] {
        switch connection?.name {
        case "telegram":
            var fields: [(key: String, label: String, secret: Bool)] = []
            if TelegramAppKeys.resolved == nil {
                fields.append(("API_ID", "api_id (the number Telegram showed you)", false))
                fields.append(("API_HASH", "api_hash (the long code underneath it)", false))
            }
            fields.append(("PHONE", "Your phone number, with the country code — like +15551234567", false))
            return fields
        default:
            return [("EMAIL", "Your Gmail address", false),
                    ("PASSWORD", "The 16 letters Google gave you", true)]
        }
    }

    /// Nil when the fields on screen would be accepted. The script checks all
    /// of this too, but it checks it after spawning a Python environment and
    /// asking Telegram — which is how "api_id must be a number" became a
    /// dialog rather than a hint under a field.
    var macKeysProblem: String? {
        guard connection?.name == "telegram" else { return nil }
        if TelegramAppKeys.resolved == nil {
            let id = values["API_ID"] ?? ""
            if !id.isEmpty, !TelegramAppKeys.isValidID(id) { return "The api_id is just digits — no spaces or letters." }
            let hash = (values["API_HASH"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty, !TelegramAppKeys.isValidHash(hash) {
                // The doubled paste is the common one, and it is invisible:
                // the field shows the first 32 characters and scrolls the
                // rest away, so "it looks right" and Telegram still says no.
                return hash.count > 32
                    ? "That api_hash is \(hash.count) characters — it should be 32. It looks like it was pasted twice; clear the box and paste once."
                    : "The api_hash is 32 letters and digits — that one is \(hash.count). Copy it whole from Telegram."
            }
        }
        let phone = values["PHONE"] ?? ""
        if !phone.isEmpty, !TelegramAppKeys.isValidPhone(phone) {
            return "That does not look like a full phone number. It needs the country code too — like +15551234567. Spaces and dashes are fine."
        }
        return nil
    }


    /// The words for this flow — what it is, why, the numbered steps, what
    /// happens if you skip it. A hand-written guide where the flow has one
    /// (SetupGuide.swift), else the same five things built from what the row
    /// already knows. Nil only for a row that is a macOS permission, which
    /// PermissionGuide explains instead.
    var guide: SetupGuide? {
        guard let c = connection else { return nil }
        // Telegram has two: the flow as it should be (a phone number and a
        // code) and the flow on a build that ships no application pair, which
        // has to send the user to Telegram for one first.
        if c.id == "mac/telegram", TelegramAppKeys.resolved == nil {
            return SetupGuide.find("mac/telegram+keys")
        }
        if let g = SetupGuide.find(c.id) { return g }
        if c.authKind == .macPermission { return nil }
        return SetupGuide.generic(label: c.label, blurb: c.blurb,
                                  signsIn: c.authKind == .oauth,
                                  pastesKey: c.authKind == .apiKey || c.authKind == .appPassword)
    }

    // MARK: Remove

    func remove(_ c: Connection) {
        connection = c
        presented = true
        removing = true
        if c.authKind == .consent { setConsent(c, on: false); return }
        let name = c.authKind == .oneClick ? "platform/\(c.name)" : c.connectName
        // A row with nothing to forget (a macOS permission) has no name for
        // connect.sh. Say what to do instead of running `--remove ""`, which
        // is what used to leave the sheet on "Couldn't disconnect."
        guard !name.isEmpty else {
            phase = .failed("There is nothing to disconnect here. \(c.label) is a permission you give in System Settings — take it back there.")
            return
        }
        // Gmail can hold several mailboxes behind one row. Asking which one
        // is the difference between disconnecting work and disconnecting
        // everything.
        // A brokered service can hold several sign-ins behind one row, the
        // same way Gmail holds several mailboxes. Removing "Gmail" when two
        // Google accounts are connected has to ask which — otherwise the
        // only available answer is "both", and someone loses their work
        // account trying to remove their personal one.
        if c.kind == .composio, c.liveAccounts > 1 {
            phase = .chooseMailbox(c.accounts.filter(\.live).map { c.accountLabel($0) })
            return
        }
        if c.kind == .mac, c.name == "gmail" {
            phase = .working("Looking at your mailboxes…")
            Task {
                let boxes = await ScriptRunner.offMain { Self.gmailMailboxes() }
                await MainActor.run {
                    // ALWAYS the chooser, even for one mailbox. The `else`
                    // that used to be here removed it immediately, with no
                    // confirmation anywhere in the path: the alert had been
                    // skipped on the way in so the chooser could come first,
                    // and with a single mailbox the chooser was skipped too.
                    // Izzy pressed Disconnect, pressed Cancel, pressed
                    // Disconnect again, and lost both mailboxes without ever
                    // confirming anything. A one-item chooser is not a
                    // pointless step: its button NAMES the address it is
                    // about to forget, which is a better confirmation than
                    // the generic alert it replaced.
                    if boxes.isEmpty {
                        self.phase = .failed("There is no mailbox here to disconnect.")
                    } else {
                        self.phase = .chooseMailbox(boxes)
                    }
                }
            }
            return
        }
        phase = .working("Disconnecting \(c.label)…")
        let launch = launchScript
        let script = locateScript("connect.sh")
        let missing = Self.missingConnect
        Task {
            let r = await ScriptRunner.offMain { () -> ScriptRunner.Result in
                guard let script else { return ScriptRunner.Result(status: -1, output: missing, timedOut: false) }
                return launch(script, ["--remove", name], nil, 60, false, [:],
                              { child in Task { @MainActor in self.child = child } }, nil)
            }
            await MainActor.run {
                self.child = nil
                self.changed = true
                guard r.status == 0 else {
                    self.phase = .failed(r.lastHumanLine.isEmpty ? "Couldn't disconnect." : r.lastHumanLine)
                    return
                }
                // A chat platform's removal prints NEEDS_RESTART=gateway, and
                // it means it: the gateway read that platform's keys at start
                // and keeps answering on it until it starts again. This used
                // to be read only by `drive`, so Disconnect on Signal deleted
                // the keys, said "disconnected", and Moe went on answering in
                // Note to Self until the next launch. Same hook as a connect.
                if Self.asksForGatewayRestart(r.output) {
                    self.restartGateway?()
                    self.phase = .done("\(c.label) is disconnected. Moe's brain is restarting so it stops answering there.")
                } else {
                    self.phase = .done("\(c.label) is disconnected.")
                }
            }
        }
    }

    /// Whether a script's output carries `NEEDS_RESTART=gateway` — the same
    /// machine line `handle(_:)` reacts to on the connect side.
    nonisolated static func asksForGatewayRestart(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains {
            if case .needsRestart("gateway") = MachineLine.parse(String($0)) { return true }
            return false
        }
    }

    /// An opt-in source, on or off. Both directions go through
    /// learn/consent.sh, so the answer lands in the one consent file a
    /// person can read — the same file the terminal prompt writes.
    func setConsent(_ c: Connection, on: Bool) {
        connection = c
        presented = true
        removing = !on
        phase = .working(on ? "Turning \(c.label) on…" : "Turning \(c.label) off…")
        let run = runConsent
        let verb = on ? "grant" : "revoke"
        let name = c.name
        Task {
            let r = await ScriptRunner.offMain { run(verb, name) }
            await MainActor.run {
                self.changed = true
                if r.status == 0 {
                    // Switched on is a first connect for the row 25 ask,
                    // the same as `succeed()`; switched off is not.
                    if on { self.justConnected = c }
                    self.phase = .done(on
                        ? "\(c.label) is on. Moe picks it up on the next sync."
                        : "\(c.label) is off. Moe stops reading it, and what it already read is dropped.")
                } else {
                    self.phase = .failed(r.lastHumanLine.isEmpty ? "Couldn't change that." : r.lastHumanLine)
                }
            }
        }
    }

    /// The connected Gmail addresses, from the connector rather than from
    /// parsing a sentence meant for a person.
    nonisolated static func gmailMailboxes() -> [String] {
        let script = Paths.home.appendingPathComponent("connectors/gmail.py").path
        guard FileManager.default.isExecutableFile(atPath: script) else { return [] }
        return ScriptRunner.run(script, ["accounts"], timeout: 12).output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : nil
            }
    }

    /// One mailbox, or the only one there is. An empty address means "the
    /// only one" — connect.sh refuses to guess when there are several.
    /// The chooser hands back a LABEL, because that is what a person picked.
    /// Which of the two routes it means depends on the row it came from: a
    /// Gmail mailbox is addressed by its address, a brokered account by an
    /// id the person never sees.
    func removeChosen(_ label: String) {
        guard let c = connection else { return }
        guard c.kind == .composio else { removeGmail(label); return }
        guard let account = c.accounts.first(where: { $0.live && c.accountLabel($0) == label }) else {
            // Never fall through to removing everything. A label that does
            // not resolve is a bug in this file, and the cost of guessing is
            // someone's other account.
            phase = .failed("Couldn't tell which account that was, so nothing was removed.")
            return
        }
        removeAccount(c, account)
    }

    /// One sign-in of a brokered service, by its id; the others stay. This
    /// is `connect.sh --remove composio/<service> <account-id>`, which is
    /// `composio.py disconnect <service> <id>` — it deletes that one
    /// connected account at Composio and touches no other. Reached from the
    /// account's own Remove (after the alert that names it) and from the
    /// Disconnect… chooser.
    func removeAccount(_ c: Connection, _ account: Connection.Account) {
        connection = c
        presented = true
        removing = true
        changed = false
        let label = c.accountLabel(account)
        guard let call = AccountRemoval.arguments(c, account) else {
            // No id is not "all of them". Say so and launch nothing.
            phase = .failed("Couldn't tell which account that was, so nothing was removed.")
            return
        }
        phase = .working("Removing \(label)…")
        let launch = launchScript
        let script = locateScript("connect.sh")
        let missing = Self.missingConnect
        Task {
            let r = await ScriptRunner.offMain { () -> ScriptRunner.Result in
                guard let script else { return ScriptRunner.Result(status: -1, output: missing, timedOut: false) }
                return launch(script, call, nil, 60, false, [:],
                              { child in Task { @MainActor in self.child = child } }, nil)
            }
            await MainActor.run {
                self.child = nil
                // The list is read again either way: a removal that failed
                // half-way is exactly when the screen's idea of the accounts
                // is least to be trusted.
                self.changed = true
                self.phase = r.status == 0
                    ? .done(c.shownAccounts.count == 2
                            ? "\(label) is removed. The other account stays connected."
                            : "\(label) is removed. The others stay connected.")
                    : .failed(r.lastHumanLine.isEmpty ? "Couldn't remove \(label)." : r.lastHumanLine)
            }
        }
    }

    func removeGmail(_ address: String) {
        guard let c = connection else { return }
        removing = true
        phase = .working(address.isEmpty ? "Disconnecting \(c.label)…" : "Disconnecting \(address)…")
        var args = ["--remove", "gmail"]
        if !address.isEmpty { args.append(address) }
        let call = args
        Task {
            let r = await ScriptRunner.offMain { ScriptRunner.connect(call, answers: nil, timeout: 60,
                                              started: { child in Task { @MainActor in self.child = child } }) }
            await MainActor.run {
                self.child = nil
                self.changed = true
                self.phase = r.status == 0 ? .done(r.lastHumanLine.isEmpty ? "\(c.label) is disconnected." : r.lastHumanLine)
                                           : .failed(r.lastHumanLine.isEmpty ? "Couldn't disconnect." : r.lastHumanLine)
            }
        }
    }
}

// MARK: - Sheet

struct ConnectSheet: View {
    @ObservedObject var flow: ConnectFlow

    var body: some View {
        // Scrolls: a flow that explains itself properly can be taller than a
        // sheet, and a step nobody can reach is a step nobody reads.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let c = flow.connection {
                    Text(c.label).font(.title3.weight(.semibold))
                }
                switch flow.phase {
                case .keys: keys
                case .signingIn: signingIn
                case .chooseMailbox(let boxes): chooseMailbox(boxes)
                case .field: field
                case .confirming(let text): confirming(text)
                case .qr(let payload): qr(payload)
                case .pairing: pairing
                case .working(let text):
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text) }
                    HStack { Spacer(); Button("Cancel") { flow.cancel() } }
                case .done(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    // One line saying what just became possible, so "connected"
                    // means something.
                    if let g = flow.guide, !flow.removing {
                        Text(g.afterConnected).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !g.awake.isEmpty {
                            Text(g.awake).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !flow.removing { alternates }
                    HStack { Spacer(); Button("Done") { flow.close() }.keyboardShortcut(.defaultAction) }
                case .failed(let text):
                    Label { Text(verbatim: text).fixedSize(horizontal: false, vertical: true) }
                          icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn) }
                    // Never an error on its own: what to do about it.
                    Text(flow.nextStep).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Not said of a removal: one that failed part-way may
                    // have changed something, and the list is read again.
                    if !flow.removing {
                        Text("Nothing was changed, and you can close this and carry on.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        if flow.offerKeys { Button("Make the bot yourself instead…") { flow.fallBackToKeys() } }
                        Spacer()
                        Button("Close") { flow.close() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .frame(maxHeight: 560)
    }

    /// "Also read my Telegram chats", offered once the main way is in.
    @ViewBuilder
    private var alternates: some View {
        if let c = flow.connection, !c.alternates.isEmpty {
            ForEach(c.alternates) { alt in
                Button(alt.label) { flow.start(alt) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    /// A step that exists to be READ, not to move the flow along on its
    /// own: nothing behind it starts until the person taps Continue. Unlike
    /// every other warning on this screen (a blurb on the row, at whatever
    /// pace someone scrolls past it), this one blocks — because handing
    /// over a whole account is a different kind of yes than pasting a key.
    private func confirming(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { flow.cancel() }
                Spacer()
                Button("Continue") {
                    if let c = flow.connection { flow.confirmedScan(c) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = flow.connection {
                // What it is, why, the numbered steps with the exact pages to
                // open, and what happens if you skip — all of it above the
                // fields, so nobody has to go and find out elsewhere.
                if let g = flow.guide { SetupGuideView(guide: g) } else {
                    Text(verbatim: c.blurb).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if c.kind == .mac {
                    ForEach(flow.macKeys, id: \.key) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.label).font(.caption)
                            if f.secret { SecureField("Paste it here", text: binding(f.key)).textFieldStyle(.roundedBorder) }
                            else { TextField("", text: binding(f.key)).textFieldStyle(.roundedBorder) }
                        }
                    }
                } else if c.kind == .composio, !flow.pasteFields.isEmpty {
                    ForEach(flow.pasteFields) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.label).font(.caption)
                            if f.secret { SecureField("Paste it here", text: binding(f.key)).textFieldStyle(.roundedBorder) }
                            else { TextField("", text: binding(f.key)).textFieldStyle(.roundedBorder) }
                            if !f.help.isEmpty {
                                Text(verbatim: f.help).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let url = URL(string: flow.pasteHelpURL), url.scheme == "https" {
                        Link("Where do I find this?", destination: url).font(.caption)
                    }
                } else {
                    ForEach(c.askedKeys, id: \.self) { key in
                        let label = c.fieldLabel(key)
                        let optional = key == c.allowedUsersKey
                        VStack(alignment: .leading, spacing: 3) {
                            Text(optional ? "\(label) (optional — empty means only you, after pairing)" : label)
                                .font(.caption)
                            if Connection.isSecret(key) {
                                SecureField("Paste it here", text: binding(key)).textFieldStyle(.roundedBorder)
                            } else {
                                TextField("", text: binding(key)).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    if !c.docs.isEmpty, let url = URL(string: c.docs), url.scheme == "https" {
                        Link("Where do I find this?", destination: url).font(.caption)
                    }
                }
                if let problem = flow.macKeysProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Kept on this Mac, readable only by you. Never shown here again.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { flow.cancel() }.keyboardShortcut(.cancelAction)
                    Button("Connect") { c.kind == .mac ? flow.submitMac() : flow.submitKeys() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!requiredFilled(c) || flow.macKeysProblem != nil)
                }
            }
        }
    }

    private func requiredFilled(_ c: Connection) -> Bool {
        let keys: [String]
        if c.kind == .mac { keys = flow.macKeys.map(\.key) }
        else if c.kind == .composio, !flow.pasteFields.isEmpty { keys = flow.pasteFields.map(\.key) }
        else { keys = c.askedKeys.filter { $0 != c.allowedUsersKey } }
        return keys.allSatisfy { !(flow.values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Telegram's three fields tidy themselves as you type.
    ///
    /// The alternative — take whatever arrives and complain about it — put an
    /// orange line reading "the api_id is just digits" under a box showing
    /// nothing but digits. my.telegram.org stacks the api_id and the api_hash,
    /// so selecting them brings a newline and a second line along, and
    /// trimming the ends does nothing for a newline in the middle: the reason
    /// for the refusal was below the fold, in a one-line field.
    ///
    /// A field that cannot show what is wrong with it must not be the thing
    /// that refuses. What the box shows is now exactly what goes to the
    /// script.
    private func binding(_ key: String) -> Binding<String> {
        let clean: (String) -> String
        switch key {
        case "API_ID": clean = TelegramAppKeys.normalisedID
        case "API_HASH": clean = TelegramAppKeys.normalisedHash
        case "PHONE": clean = TelegramAppKeys.normalisedPhone
        default: clean = { $0 }
        }
        return Binding(get: { flow.values[key] ?? "" }, set: { flow.values[key] = clean($0) })
    }

    /// One thing to type: the script said what it needs.
    private var field: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The first field is where a flow begins, so it is where the
            // explanation belongs. Later fields are mid-conversation and the
            // label alone is enough.
            if case .field("phone") = flow.phase, let g = flow.guide {
                SetupGuideView(guide: g)
                Divider()
            }
            Text(flow.fieldLabel).font(.caption)
            if case .field(let f) = flow.phase, Connection.isSecret(f.uppercased()) {
                SecureField("", text: $flow.fieldValue).textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: $flow.fieldValue).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { flow.cancel() }.keyboardShortcut(.cancelAction)
                Button("Continue") { flow.continueField() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.fieldValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func qr(_ payload: String) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Text(flow.connection?.name == "signal"
                 ? "On your phone: Signal › Settings › Linked devices › +, then point it at this. Afterwards, talk to Moe in Note to Self."
                 : "On your phone: WhatsApp › Settings › Linked devices › Link a device, then point it at this.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let img = QRImage.make(payload) {
                Image(nsImage: img).interpolation(.none).frame(width: 240, height: 240)
            } else {
                Text("Couldn't draw the code.").foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { flow.cancel() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 10) {
            let slack = flow.connection?.name == "slack"
            Label(slack ? "Slack is added — one more step." : "Your Telegram bot is ready.",
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(slack
                 ? "Confirm it's you. Moe on this Mac has to say yes before anything written in that Slack reaches Moe. Say yes only to a workspace and name you recognise."
                 : "Now pair your phone: open the bot Telegram just showed you and send it any message. It appears here — approve it and you are done.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if flow.waiting.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(slack ? "Waiting for Slack…" : "Waiting for your message…").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(flow.waiting) { p in
                HStack {
                    Text(verbatim: p.name)
                    Spacer()
                    Button(p.isSlackInstall ? "Confirm" : "Approve") { flow.approve(p) }
                }
            }
            if !flow.approved.isEmpty {
                Text(slack ? "Confirmed. Write to Moe under Apps in Slack." : "Approved. Say hello to Moe from your phone.").font(.caption).foregroundStyle(.green)
            }
            alternates
            HStack {
                Spacer()
                Button(flow.approved.isEmpty ? "Later" : "Done") { flow.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Several mailboxes behind one Gmail row: which one is going.
    private func chooseMailbox(_ boxes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(boxes.count == 1 ? "Forget this mailbox?" : "Which mailbox should Moe forget?")
                .font(.caption)
            ForEach(boxes, id: \.self) { box in
                HStack {
                    Text(verbatim: box)
                    Spacer()
                    Button("Disconnect") { flow.removeChosen(box) }
                }
            }
            Text(boxes.count == 1
                 ? "Moe forgets the app password and stops reading it. Nothing at Google changes."
                 : "The others stay connected.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { flow.cancel() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var signingIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.connection?.authKind == .oneClick
                     ? (flow.connection?.name == "slack" ? "Finish in Slack…" : "Finish in Telegram…")
                     : "Finish signing in in your browser…")
            }
            Text(flow.connection?.authKind != .oneClick
                 ? "Approve Moe on the page that opened. This closes on its own when it is done."
                 : flow.connection?.name == "slack"
                 ? "Slack opened its own page. Pick the workspace you want Moe in and choose Allow; then find Moe under Apps and write to it there. This closes on its own."
                 : "Telegram opened a Create bot screen for @MoeSetupBot, with the name Moe filled in. Tap Create; Moe collects the new bot and this closes on its own.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .signingIn(let url) = flow.phase, let u = URL(string: url) {
                Link("Page didn't open? Open it again", destination: u).font(.caption)
            }
            HStack { Spacer(); Button("Cancel") { flow.cancel() }.keyboardShortcut(.cancelAction) }
        }
    }

}
