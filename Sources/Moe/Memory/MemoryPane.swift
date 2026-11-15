import AppKit
import MoeDesign
import SwiftUI

// Memory, design B — "Sidebar" (owner, 2026-09-22, choosing from four
// mockups after calling the one-list page "incredibly ugly").
//
//   * A list of its own on the left, 220pt: "Memory", then You, People,
//     Right now, To check — each with its count, To check's as a small
//     accent pill — and, quietly at the foot, Past, Open folder, Your notes.
//     "From your chats" (Moe's own notes, MEMORY.md) joins the list only
//     when it has something in it.
//   * On the right, one section: its name, one line saying what it is, and
//     its lines — 16pt, hairline rules between them, no cards.
//   * **One click on a line edits it in place** (kept from the page before):
//     the line becomes a field in the same font with an accent border,
//     Return saves, Esc cancels, clicking away saves, an empty line is
//     forgotten with a few seconds of "Forgotten · Undo". ↑/↓ move, Return
//     edits, Delete forgets.
//   * On hover, a line says where it came from — on a line of its own under
//     the words, always there and only opaque on hover — and its actions
//     (Discuss, ×) sit in a trailing column of one fixed width. **Hover never
//     changes a row's size or wrapping** (owner, 2026-09-22: a hovered To
//     check row re-wrapped into ten lines).
//   * Under the lines, "+ Add something Moe should know" opens an empty
//     field; what is typed is the person's own line (profile.py add).
//   * To check is one card at a time (owner, 2026-09-22, mockup D): the
//     thing asked in "you" form, Yes / No / Something else…, a quiet Skip
//     and "1 of N"; Y, N, E, ← and → from the keyboard; "All caught up."
//   * Talking it through (owner, 2026-09-22): every section has "Go through
//     with Moe", every line "Discuss", and the list "Review everything with
//     Moe" — each puts a draft naming the files in Chat's box, unsent
//     (`MemoryTalk`). The brain can change what it is told: moe_profile's
//     confirm/correct/delete/add/answer/dismiss, and the memory tool for
//     USER.md and MEMORY.md.
//
// Writes are immediate and never ask a model (owner decision 2026-09-07,
// "the buttons write immediately") — except for the lines of Hermes's own
// memory when claimstore's cli.py cannot run, which are handed to Moe (see
// MemoryReader.swift).

struct MemoryPane: View {
    /// A state the snapshot renders without a mouse or a keyboard.
    struct Demo: Equatable {
        enum State: Equatable {
            case none, editing, hover, adding
            /// A hovered line with the pointer on its Discuss.
            case discuss
            /// To check: the n-th card, with "Something else…" open or not.
            case card(Int, other: Bool = false)
            /// To check with every card answered.
            case caughtUp
        }
        var tab: MemoryTab
        var state: State = .none
    }

    @ObservedObject var conductor: Conductor
    var demo: Demo? = nil

    /// The section last chosen, for as long as the app runs: leaving the
    /// page and coming back opens it where it was.
    @MainActor static var remembered: MemoryTab = .you

    @State private var tab: MemoryTab = MemoryPane.remembered
    @State private var lines: [MemoryLine] = []
    @State private var checkList: [MemoryCheck] = []
    @State private var loading = true
    /// Why the page is empty, when it is.
    @State private var why: String?
    /// The last load could not read what Moe has learned (`MemoryReader.Reading`).
    @State private var couldntLook = false
    @State private var note = ""
    @State private var choosing = false
    @State private var showNotes = false
    @State private var importing = false
    @State private var awayCopy = false

    // The line being edited, its draft, the keyboard's line, the mouse's.
    @State private var editing: String?
    @State private var draft = ""
    @State private var selected: String?
    @State private var hovered: String?
    // "+ Add": open, what is typed, and lines added but not yet read back.
    @State private var adding = false
    @State private var addDraft = ""
    @State private var added: [MemoryTab: [String]] = [:]
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case list, field, add, other }

    // To check, one card at a time: the cards answered or skipped this
    // visit (in order, for ←), and "Something else…" open with its words.
    @State private var done: [String] = []
    @State private var otherOpen = false
    @State private var otherDraft = ""
    /// The Discuss link drawn as if the pointer were on it (snapshot only).
    @State private var pointOnDiscuss = false

    /// A forget waiting out its Undo. Committed when the time is up, when
    /// another line is forgotten, or when the page goes away.
    @State private var forgetting: (item: MemoryItem, edit: MemoryEdit, ticket: UUID)?
    /// Lines already changed on screen, waiting for the reload that proves it.
    @State private var hidden: Set<String> = []
    /// Hermes lines handed to Moe: the text they will have.
    @State private var askedMoe: [String: String] = [:]

    static let undoSeconds: Double = 5
    static let lineFont = Theme.Typo.prose(16)
    static let listWidth: CGFloat = 220

    private var sections: [MemorySection] {
        MemoryReader.sections(lines: lines, checks: checkList).map { s in
            MemorySection(id: s.id, title: s.title, items: s.items.filter { !hidden.contains($0.id) })
        }
    }
    private var past: [MemoryItem] { MemoryReader.past(lines).filter { !hidden.contains($0.id) } }

    /// The sections the list shows: From your chats only with something in it.
    private var shownTabs: [MemoryTab] {
        sections.compactMap { s in
            guard let t = MemoryTab(rawValue: s.id) else { return nil }
            return t == .chats && s.items.isEmpty ? nil : t
        }
    }

    private func items(_ t: MemoryTab) -> [MemoryItem] {
        t == .past ? past : sections.first { $0.id == t.rawValue }?.items ?? []
    }

    private var cards: [CheckCard] { MemoryReader.cards(checkList, lines: lines) }
    /// The cards still to go, this visit.
    private var remaining: [CheckCard] { cards.filter { !done.contains($0.id) } }

    var body: some View {
        HStack(spacing: 0) {
            sectionList
            Rectangle().fill(Theme.rule).frame(width: 1)
            content
        }
        .background(Theme.paper)
        .overlay(alignment: .bottom) { if forgetting != nil { undoBar } }
        .onAppear(perform: reload)
        .onDisappear { commit(); commitAdd(); commitForget() }
        .onChange(of: focus) { old, new in
            // Every way out of a field saves it — Tab, a click elsewhere.
            if old == .field, new != .field, editing != nil { commit() }
            if old == .add, new != .add, adding { commitAdd() }
        }
        .sheet(isPresented: $choosing) {
            LearnStepSheet { recorded in
                choosing = false
                if recorded { reload() }
            }
        }
        .sheet(isPresented: $showNotes) { NotesSheet { showNotes = false } }
        .sheet(isPresented: $importing) {
            ImportMemorySheet { imported in
                importing = false
                if imported { reload() }
            }
        }
    }

    // MARK: The list on the left

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Memory")
                .font(Theme.Typo.display(24)).fontWeight(.regular)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.Space.base)
                .padding(.bottom, Theme.Space.roomy)
            ForEach(shownTabs, id: \.self) { t in
                SectionRow(title: t.title,
                           count: loading ? nil : t == .check ? remaining.count : items(t).count,
                           pill: t == .check,
                           on: tab == t) { choose(t) }
            }
            Spacer(minLength: Theme.Space.base)
            SectionRow(title: "Review everything with Moe", quiet: true, small: true, on: false) { talk(MemoryTalk.everything) }
                .help("Opens Chat with a draft: Moe goes through every memory file with you, one question at a time")
            SectionRow(title: "Past", quiet: true, on: tab == .past) { choose(.past) }
            SectionRow(title: "Open folder", quiet: true, on: false) {
                NSWorkspace.shared.open(MemoryReader.folderToOpen())
            }
            SectionRow(title: "Your notes", quiet: true, on: false) { showNotes = true }
            SectionRow(title: "Import from ChatGPT or Claude", quiet: true, small: true, on: false) { importing = true }
                .help("Bring in what another assistant remembers about you")
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.generous)
        .frame(width: Self.listWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Switching sections saves whatever is open first, as a click away does.
    private func choose(_ t: MemoryTab) {
        commit()
        commitAdd()
        tab = t
        Self.remembered = t
        selected = nil
        hovered = nil
        otherOpen = false
        focus = .list
    }

    /// Chat, with `draft` in its box — unsent, for the person to change
    /// or send. The same way in as the old "Answer" (Conductor.chatDraft).
    private func talk(_ draft: String) {
        commit()
        commitAdd()
        guard demo == nil else { return }
        conductor.chatDraft = draft
        NotificationCenter.default.post(name: .moeShowSection, object: nil,
                                        userInfo: ["section": MainWindow.Section.chat.rawValue])
    }

    // MARK: The section on the right

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
                        Text(tab.title)
                            .font(Theme.Typo.display(28)).fontWeight(.regular)
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        if let draft = MemoryTalk.draft(for: tab) {
                            QuietLink(title: "Go through with Moe",
                                      help: "Opens Chat with a draft: Moe asks about these one at a time and fixes them as you go") {
                                talk(draft)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.small)
                    Text(tab.subtitle)
                        .font(Theme.Typo.ui(14))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Theme.Space.wide)
                    if loading {
                        ProgressView().controlSize(.small).padding(.vertical, Theme.Space.base)
                    } else if tab == .check {
                        checkFlow
                    } else {
                        lineList
                    }
                    below
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, Theme.Space.vast)
                .padding(.top, 44)
                .padding(.bottom, Theme.Space.generous)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Clicking anywhere that is not a line saves the one open.
                .background(Color.clear.contentShape(Rectangle()).onTapGesture {
                    commit(); commitAdd()
                })
            }
            .focusable()
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(characters: CharacterSet(charactersIn: "ynesYNES12")) { press in
                guard tab == .check, !otherOpen, let card = remaining.first else { return .ignored }
                switch press.characters.lowercased() {
                case "y": if card.shape == .yesNo { answer(card, .yes) } else { return .ignored }
                case "n": if card.shape != .open { answer(card, .no) } else { return .ignored }
                case "e": openOther()
                case "s": skip(card)
                case "1", "2":
                    let i = Int(press.characters)! - 1
                    guard card.choices.indices.contains(i) else { return .ignored }
                    answer(card, .pick(i))
                default: return .ignored
                }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard tab == .check, !otherOpen, let card = remaining.first else { return .ignored }
                skip(card)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard tab == .check, !otherOpen else { return .ignored }
                back()
                return .handled
            }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.return) {
                guard editing == nil, !adding, let id = selected, let item = item(id) else { return .ignored }
                begin(item)
                return .handled
            }
            .onKeyPress(.delete) {
                guard editing == nil, !adding, let id = selected, let item = item(id), item.role != .past
                else { return .ignored }
                forget(item)
                return .handled
            }
        }
    }

    @ViewBuilder private var lineList: some View {
        let shown = items(tab)
        let pending = added[tab] ?? []
        if shown.isEmpty && pending.isEmpty && !adding {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                Text(couldntLook && tab != .chats ? MemoryReader.couldntLookLine
                     : tab == .you && lines.isEmpty && checkList.isEmpty ? (why ?? tab.empty) : tab.empty)
                    .font(Theme.Typo.prose(15))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if tab == .you && lines.isEmpty {
                    Button(LearnStepCopy.memoryButton) { choosing = true }
                        .buttonStyle(.plain)
                        .font(Theme.Typo.ui(14))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.vertical, Theme.Space.base)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row($0) }
                ForEach(pending, id: \.self) { text in
                    Text(verbatim: MemoryReader.plain(text))
                        .font(Self.lineFont).foregroundStyle(Theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                }
                if adding { addField }
            }
        }
    }

    /// "+ Add…", then the page's quiet lines: a problem, the cloud copy.
    private var below: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            if tab.addFile != nil && !adding && !loading {
                Button {
                    commit()
                    adding = true
                    addDraft = ""
                    DispatchQueue.main.async { focus = .add }
                } label: {
                    Text("+ Add something Moe should know")
                        .font(Theme.Typo.ui(14))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, Theme.Space.snug)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
            if !note.isEmpty {
                Text(note).font(Theme.Typo.ui(12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.small)
            }
            // Where it lives is about the lines, not the questions.
            if tab != .check, let cloud = MemoryReader.whereItLives(awayCopy: awayCopy) {
                Text(cloud).font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink3)
                    .padding(.top, Theme.Space.cosy)
            }
        }
    }

    // MARK: To check, one card at a time

    @ViewBuilder private var checkFlow: some View {
        if let card = remaining.first {
            CheckCardView(card: card,
                          position: done.count + 1,
                          total: done.count + remaining.count,
                          otherOpen: otherOpen,
                          otherDraft: $otherDraft,
                          focus: $focus,
                          answer: { answer(card, $0) },
                          openOther: openOther,
                          closeOther: { otherOpen = false; otherDraft = ""; focus = .list },
                          skip: { skip(card) })
                .id(card.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                        removal: .opacity))
        } else {
            Text("All caught up.")
                .font(Theme.Typo.prose(16))
                .foregroundStyle(Theme.ink3)
                .padding(.vertical, Theme.Space.base)
                .transition(.opacity)
        }
    }

    private func openOther() {
        otherOpen = true
        otherDraft = ""
        DispatchQueue.main.async { focus = .other }
    }

    /// Writes what the answer means (MemoryReader.plan) and moves on.
    private func answer(_ card: CheckCard, _ a: CardAnswer) {
        let edits = MemoryReader.plan(card, a)
        if case .other = a, edits.isEmpty { return }     // nothing typed: stay
        CalmMotion.animate(Theme.Motion.easeOut) {
            done.append(card.id)
            otherOpen = false
            otherDraft = ""
        }
        focus = .list
        guard !edits.isEmpty else { return }
        Task {
            let problem: String? = await ScriptRunner.offMain { MemoryReader.perform(all: edits) }
            await MainActor.run { note = problem ?? ""; reload() }
        }
    }

    /// Skip: on to the next; it is asked again next time.
    private func skip(_ card: CheckCard) {
        CalmMotion.animate(Theme.Motion.easeOut) {
            done.append(card.id)
            otherOpen = false
            otherDraft = ""
        }
        focus = .list
    }

    /// ←: back to the last card still unanswered (one skipped).
    private func back() {
        let open = Set(cards.map(\.id))
        guard let i = done.lastIndex(where: { open.contains($0) }) else { return }
        CalmMotion.animate(Theme.Motion.easeOut) { _ = done.remove(at: i) }
    }

    private var addField: some View {
        EditBox {
            TextField("", text: $addDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Self.lineFont)
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: .add)
                .onSubmit(commitAdd)
                .onExitCommand { adding = false; addDraft = ""; focus = .list }
                .background(alignment: .leading) {
                    if addDraft.isEmpty {
                        Text(tab.addPrompt).font(Self.lineFont).foregroundStyle(Theme.ink3)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func row(_ item: MemoryItem) -> some View {
        MemoryRowView(
            item: item,
            text: askedMoe[item.id] ?? item.text,
            meta: askedMoe[item.id] != nil ? "Moe is updating this" : item.line?.source ?? "",
            editing: editing == item.id,
            selected: selected == item.id && editing == nil,
            hovered: hovered == item.id,
            draft: $draft,
            focus: $focus,
            begin: { begin(item) },
            save: commit,
            cancel: cancel,
            forget: { forget(item) },
            confirm: { confirm(item) },
            restore: { restore(item) },
            discuss: { talk(MemoryTalk.discuss(item)) },
            pointOnDiscuss: pointOnDiscuss && hovered == item.id,
            hover: { inside in
                if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
            })
        .id(item.id)
    }

    private var undoBar: some View {
        HStack(spacing: Theme.Space.small) {
            Text("Forgotten").foregroundStyle(Theme.ink2)
            Text("·").foregroundStyle(Theme.ink3)
            Button("Undo", action: undoForget)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentDeep)
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(Theme.Typo.ui(12, weight: .medium))
        .padding(.horizontal, Theme.Space.cosy)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.sunk, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .padding(.bottom, Theme.Space.roomy)
        .padding(.leading, Self.listWidth)
        .transition(.opacity)
    }

    // MARK: Editing

    private func item(_ id: String) -> MemoryItem? {
        sections.flatMap(\.items).first { $0.id == id } ?? past.first { $0.id == id }
    }

    private func begin(_ item: MemoryItem) {
        guard item.role != .past else { selected = item.id; return }
        if editing == item.id { return }
        commit()
        commitAdd()
        editing = item.id
        selected = item.id
        draft = item.role == .question ? "" : (askedMoe[item.id] ?? item.text)
        DispatchQueue.main.async { focus = .field }
    }

    private func cancel() {
        editing = nil
        draft = ""
        focus = .list
    }

    /// Saves the open line, if there is one. Every way out of a field ends
    /// here — Return, a click elsewhere, the field losing focus — and it runs
    /// once: `editing` is cleared before anything is written.
    private func commit() {
        guard let id = editing, let item = item(id) else { editing = nil; return }
        let text = draft
        editing = nil
        draft = ""
        focus = .list
        let edit = MemoryReader.plan(item, draft: text)
        switch edit {
        case .nothing, .add, .undoTidy, .revive:
            return
        case .forget, .forgetMemory:
            forget(item)
        case .askMoe(let message):
            askedMoe[item.id] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if askedMoe[item.id]?.isEmpty == true { hidden.insert(item.id) }
            conductor.submit(message, origin: .typed, starter: .person)
        case .correctMemory(_, let new):
            // Shown at once; the reload after the write replaces it.
            askedMoe[item.id] = new
            write(edit, closing: item)
        case .correct, .answer, .dismiss, .confirm:
            write(edit, closing: item)
        }
    }

    /// Saves the "+ Add" field, if it is open and has words in it.
    private func commitAdd() {
        guard adding else { return }
        let edit = MemoryReader.planAdd(tab, draft: addDraft)
        adding = false
        addDraft = ""
        focus = .list
        guard case .add(_, let text) = edit else { return }
        let into = tab
        added[into, default: []].append(text)
        Task {
            let problem: String? = await ScriptRunner.offMain { MemoryReader.perform(edit) }
            await MainActor.run {
                note = problem ?? ""
                if problem != nil { added[into]?.removeAll { $0 == text } }
                reload()
            }
        }
    }

    private func write(_ edit: MemoryEdit, closing item: MemoryItem) {
        Task {
            let problem: String? = await ScriptRunner.offMain { MemoryReader.perform(edit) }
            await MainActor.run {
                note = problem ?? ""
                askedMoe[item.id] = nil
                reload()
            }
        }
    }

    private func forget(_ item: MemoryItem) {
        commitForget()
        let edit: MemoryEdit
        switch (item.role, item.line?.origin) {
        case (.question, _):
            edit = .dismiss(question: item.text)
        case (_, .claim(let id)?):
            edit = .forget(id: id)
        case (_, .hermes?):
            edit = MemoryReader.plan(item, draft: "")
        default:
            return
        }
        hidden.insert(item.id)
        let ticket = UUID()
        CalmMotion.animate(Theme.Motion.easeOut) { forgetting = (item, edit, ticket) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds) {
            if forgetting?.ticket == ticket { commitForget() }
        }
    }

    private func undoForget() {
        guard let f = forgetting else { return }
        hidden.remove(f.item.id)
        CalmMotion.animate(Theme.Motion.easeOut) { forgetting = nil }
    }

    private func commitForget() {
        guard let f = forgetting else { return }
        CalmMotion.animate(Theme.Motion.easeOut) { forgetting = nil }
        switch f.edit {
        case .askMoe(let message):
            conductor.submit(message, origin: .typed, starter: .person)
        default:
            write(f.edit, closing: f.item)
        }
    }

    /// "Yes": the line stands, in the person's own word.
    private func confirm(_ item: MemoryItem) {
        guard let line = item.line else { return }
        commit()
        hidden.insert(item.id)
        Task {
            let problem: String? = await ScriptRunner.offMain {
                guard let script = MemoryReader.profileScript(),
                      let argv = MemoryReader.confirmCommand(line, script: script)
                else { return "Moe can't find the file it keeps this in." }
                return MemoryReader.run(argv)
            }
            await MainActor.run { note = problem ?? ""; reload() }
        }
    }

    private func restore(_ item: MemoryItem) {
        guard let line = item.line else { return }
        hidden.insert(item.id)
        if let change = line.tidyChange {
            // A line the nightly tidy set aside: the whole change goes back
            // (a merge's other lines with it), as the person's own word.
            Task {
                let problem: String? = await ScriptRunner.offMain {
                    MemoryReader.perform(.undoTidy(change: change))
                }
                await MainActor.run { note = problem ?? ""; reload() }
            }
            return
        }
        Task {
            let problem: String? = await ScriptRunner.offMain {
                guard let script = MemoryReader.profileScript(),
                      let argv = MemoryReader.restoreCommand(line, script: script)
                else { return "Moe can't find the file it keeps this in." }
                return MemoryReader.run(argv)
            }
            await MainActor.run { note = problem ?? ""; reload() }
        }
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) {
        guard editing == nil, !adding else { return }
        let ids = items(tab).map(\.id)
        guard !ids.isEmpty else { return }
        let at = selected.flatMap { ids.firstIndex(of: $0) }
        let next = at.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        selected = ids[next]
        proxy.scrollTo(ids[next])
    }

    // MARK: Loading

    private func reload() {
        loading = lines.isEmpty && checkList.isEmpty
        Task {
            let (reading, q) = await ScriptRunner.offMain {
                (MemoryReader.read(), MemoryReader.checkList() ?? MemoryCheck.fallback(MemoryReader.questions()))
            }
            let l = reading.lines
            let w: String? = (l.isEmpty && q.isEmpty)
                ? await ScriptRunner.offMain { BackgroundLearning.explain() } : nil
            let keepsACopy = await conductor.cloud.keepsACopy()
            await MainActor.run {
                lines = l
                checkList = q
                why = w
                couldntLook = reading.couldntLook
                awayCopy = keepsACopy
                // A change the reload now shows is no longer pending; one a
                // line of Hermes's memory is still waiting on stays.
                let ids = Set(l.map(\.id) + q.map { "q:" + $0.text })
                hidden = hidden.filter { id in forgetting?.item.id == id || (askedMoe[id] != nil && ids.contains(id)) }
                added = [:]
                loading = false
                tab = MemoryReader.opening(demo?.tab ?? tab, shown: shownTabs)
                applyDemo()
            }
        }
    }

    /// The snapshot's states: a section, a line mid-edit, a line under the
    /// mouse, the add field open. Applied once the lines are in.
    private func applyDemo() {
        guard let demo else { return }
        let rows = items(tab)
        switch demo.state {
        case .none: break
        case .editing:
            if let item = rows.first(where: { $0.role == .line || $0.role == .check }) ?? rows.first {
                editing = item.id
                selected = item.id
                draft = item.role == .question ? "" : item.text.replacingOccurrences(of: "two-person", with: "three-person")
            }
        case .hover, .discuss:
            let lineRows = rows.filter { $0.role != .question }
            hovered = (lineRows.count > 2 ? lineRows[2] : lineRows.first)?.id
            pointOnDiscuss = demo.state == .discuss
        case .adding:
            adding = true
        case .card(let n, let other):
            done = Array(cards.prefix(n).map(\.id))
            if other { otherOpen = true; otherDraft = "" }
        case .caughtUp:
            done = cards.map(\.id)
        }
    }
}

// MARK: - The list's rows

/// One row of the Memory page's own list: a section with its count, or one
/// of the quiet words at its foot.
private struct SectionRow: View {
    let title: String
    var count: Int? = nil
    var pill = false
    var quiet = false
    /// One size down, on one line: the longest of the quiet words.
    var small = false
    let on: Bool
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.small) {
                Text(title)
                    .font(Theme.Typo.ui(small ? 13 : quiet ? 14 : 15, weight: on && !quiet ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(quiet && !on ? (over ? Theme.ink2 : Theme.ink3) : Theme.ink)
                Spacer(minLength: 0)
                if let count {
                    if pill {
                        if count > 0 {
                            Text("\(count)")
                                .font(Theme.Typo.ui(12, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(minWidth: 20)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.accent, in: Capsule())
                        }
                    } else if count > 0 {
                        Text("\(count)")
                            .font(Theme.Typo.ui(15))
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(on ? Theme.selected : over && !quiet ? Theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

// MARK: - One line

/// The field a line becomes: an accent border, the raised paper, the same
/// font — so the words do not move when the click lands.
struct EditBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1.5))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}

// MARK: - Your notes

/// The markdown notes in the memory folder, as they were on the old
/// Memory screen: a list, and the file as text. Moe reads them at the start
/// of a conversation and the ten-minute sync keeps them up to date.
struct NotesSheet: View {
    let close: () -> Void
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var text = ""
    /// The file as it was when opened, so Save only writes a real change.
    @State private var original = ""

    private var dirty: Bool { text != original }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.base) {
                Text("Your notes")
                    .font(Theme.Typo.heading(19))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if dirty, selected != nil {
                    Text("unsaved")
                        .font(Theme.Typo.label(9)).tracking(Theme.tracking)
                        .foregroundStyle(Theme.warn)
                    PaneButton(title: "Save", prominent: true, action: save)
                }
                PaneButton(title: "Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.base)
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(files, id: \.self) { url in
                            let on = url == selected
                            Button {
                                selected = url
                            } label: {
                                Text(name(url))
                                    .font(Theme.Typo.ui(12, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.Space.small)
                                    .padding(.vertical, Theme.Space.snug)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                            .fill(on ? Theme.selected : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.Space.snug)
                }
                .frame(width: 170)
                .background(Theme.paper)
                Rectangle().fill(Theme.rule).frame(width: 1)
                if selected != nil {
                    TextEditor(text: $text)
                        .font(Theme.Typo.data(12))
                        .scrollContentBackground(.hidden)
                        .background(Theme.raised)
                        .padding(Theme.Space.small)
                } else {
                    PaneEmpty(title: "Plain notes",
                              detail: "Pick a note. Moe reads these at the start of every conversation, and keeps them up to date as it learns — edit them freely.")
                }
            }
        }
        .frame(width: 720, height: 520)
        .background(Theme.raised)
        .onAppear { files = MemoryReader.notes() }
        .onChange(of: selected) { _, new in
            guard let new else { return }
            text = (try? String(contentsOf: new, encoding: .utf8)) ?? ""
            original = text
        }
    }

    /// "about-me" → "About me".
    private func name(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        return stem.prefix(1).uppercased() + stem.dropFirst()
    }

    private func save() {
        guard let selected else { return }
        try? text.write(to: selected, atomically: true, encoding: .utf8)
        original = text
    }
}
