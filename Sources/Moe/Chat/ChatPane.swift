import AppKit
import MoeChat
import MoeIsland
import MoeVoice
import MoeDesign
import SwiftUI
import UniformTypeIdentifiers

/// Chat.
///
/// The old version was a `LazyVStack` of plain `Text` — no markdown, no
/// timestamps, no way back to a finished conversation, and no sign of what
/// Moe had actually done. All the interesting telemetry already existed on
/// `Conductor` and simply was not rendered.
///
/// Three things changed. Conversations persist and are listed, so ⌘N files a
/// thread rather than destroying it. Replies render markdown, with code in its
/// own well. And tool activity appears as chips in the plain language
/// `describeTool` already writes — collapsed by default, opened on click,
/// never a function name.
struct ChatPane: View {
    @ObservedObject var conductor: Conductor

    @State private var typed = ""
    /// Photos and files waiting to go with the next message.
    @State private var attachments: [ChatAttachment] = []
    @State private var dropTargeted = false
    @State private var threads = ConversationList(pinned: [], recent: [], archived: [])
    /// The search field at the top of the list.
    @State private var query = ""
    @State private var showArchived = false
    /// The tag the list is narrowed to, and every tag in use (`TagRules`).
    @State private var tagFilter: String?
    @State private var tags: [String] = []
    @State private var marks: [String: ConversationStore.Marks] = [:]
    /// The thread whose name is being edited in place, and the words so far.
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var openTools: Set<UUID> = []
    /// One of your messages, being changed in the box; sending it cuts the
    /// chat there and sends it again (`Conductor.resend`).
    @State private var editing: UUID?
    @State private var confirmDelete: String?
    /// The conversation as one page a drag can run across (`Transcript`).
    @State private var selecting = false
    @ObservedObject private var ax = AccessibilityWatch.shared

    init(conductor: Conductor) {
        self.conductor = conductor
        // Filled now, not on appear, so the list is never drawn empty first.
        let marks = conductor.conversationMarks()
        _threads = State(initialValue: ConversationList.arrange(
            conductor.conversations(), marks: marks, searching: false))
        _marks = State(initialValue: marks)
        _tags = State(initialValue: TagRules.vocabulary(marks))
    }

    var body: some View {
        HStack(spacing: 0) {
            sessions
            Rectangle().fill(Theme.rule).frame(width: 1)
            thread
        }
        .background(Theme.raised)
        .onAppear {
            reloadThreads()
            // Older threads get their short AI names, a few at a time.
            conductor.nameUntitledConversations()
        }
        // A thread is filed when a reply lands, so the list refreshes then.
        .onChange(of: conductor.turns.count) { _, _ in reloadThreads() }
        // And when another device's turns arrive through the cloud.
        .onReceive(NotificationCenter.default.publisher(for: .moeConversationsChanged)) { _ in
            reloadThreads()
        }
    }

    // MARK: - Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(ChatType.section)
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button {
                    conductor.newConversation()
                    reloadThreads()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Start a fresh conversation (⌘N)")
            }
            .padding(.horizontal, Theme.Space.base)
            .padding(.top, Theme.Space.cosy)
            .padding(.bottom, Theme.Space.small)

            searchField
                .padding(.horizontal, Theme.Space.small)
                .padding(.bottom, Theme.Space.tight)

            if !tags.isEmpty { tagBar }

            if threads.pinned.isEmpty, threads.recent.isEmpty,
               threads.archived.isEmpty || !query.isEmpty || tagFilter != nil {
                Text(query.isEmpty && tagFilter == nil ? "Nothing yet" : "No conversation has that in it")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.top, Theme.Space.small)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !threads.pinned.isEmpty {
                        listHeading("Pinned")
                        ForEach(threads.pinned) { convo in threadRow(convo, pinned: true) }
                    }
                    ForEach(grouped, id: \.0) { day, items in
                        listHeading(day)
                        ForEach(items) { convo in
                            threadRow(convo)
                        }
                    }
                    if !threads.archived.isEmpty {
                        Button {
                            showArchived.toggle()
                        } label: {
                            HStack(spacing: Theme.Space.snug) {
                                Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Archived · \(threads.archived.count)")
                                    .font(ChatType.section)
                            }
                            .foregroundStyle(Theme.ink3)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Theme.Space.small)
                        .padding(.top, Theme.Space.base)
                        if showArchived {
                            ForEach(threads.archived) { convo in threadRow(convo, archived: true) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.snug)
                .padding(.bottom, Theme.Space.base)
            }
        }
        .frame(width: 172)
        .background(Theme.paper)
        .confirmationDialog("Delete this conversation?",
                            isPresented: .init(get: { confirmDelete != nil },
                                               set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete { conductor.deleteConversation(id: id) }
                confirmDelete = nil
                reloadThreads()
            }
        } message: {
            Text("The daily log in your history folder keeps the text either way.")
        }
    }

    private func listHeading(_ title: String) -> some View {
        Text(title)
            .font(ChatType.section)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, Theme.Space.small)
            .padding(.top, Theme.Space.base)
            .padding(.bottom, Theme.Space.tight)
    }

    /// Looks through every conversation's name and words, the archive too.
    private var searchField: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink)
                .onExitCommand { query = "" }
                .accessibilityLabel("Search conversations")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, Theme.Space.small)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.sunk))
        .onChange(of: query) { _, _ in reloadThreads() }
    }

    /// The tags in use, as chips: one narrows the list to its chats, and
    /// the same chip again shows them all.
    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.tight) {
                ForEach(tags, id: \.self) { tag in
                    let on = tag == tagFilter
                    Button {
                        tagFilter = on ? nil : tag
                        reloadThreads()
                    } label: {
                        Text(tag)
                            .font(Theme.Typo.ui(11, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.accentDeep : Theme.ink2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(on ? Theme.selected : Theme.sunk))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Show every conversation" : "Show only conversations tagged \(tag)")
                    .accessibilityLabel("Tag \(tag)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Space.small)
        }
        .padding(.bottom, Theme.Space.tight)
    }

    @ViewBuilder
    private func threadRow(_ convo: ConversationStore.Conversation,
                           pinned: Bool = false, archived: Bool = false) -> some View {
        if renaming == convo.id {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .font(Theme.Typo.ui(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .focused($renameFocused)
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, Theme.Space.snug)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1))
                .onSubmit {
                    conductor.renameConversation(id: convo.id, to: renameText)
                    renaming = nil
                    reloadThreads()
                }
                .onExitCommand { renaming = nil }
                .onAppear { renameFocused = true }
        } else {
            threadButton(convo, pinned: pinned, archived: archived)
        }
    }

    private func threadButton(_ convo: ConversationStore.Conversation,
                              pinned: Bool, archived: Bool) -> some View {
        let on = convo.id == conductor.currentConversationID
        let mark = marks[convo.id] ?? .init()
        return Button {
            conductor.openConversation(id: convo.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(convo.title)
                        .font(Theme.Typo.ui(12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if mark.forget {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                            .help("Not remembered")
                            .accessibilityLabel("Not remembered")
                    }
                }
                if !mark.tags.isEmpty {
                    Text(mark.tags.joined(separator: " · "))
                        .font(Theme.Typo.ui(10.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
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
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") {
                conductor.pinConversation(id: convo.id, !pinned)
                reloadThreads()
            }
            Button("Rename…") {
                renameText = convo.title
                renaming = convo.id
            }
            Button(archived ? "Move out of the archive" : "Archive") {
                conductor.archiveConversation(id: convo.id, !archived)
                reloadThreads()
            }
            if !mark.tags.isEmpty {
                Menu("Remove tag") {
                    ForEach(mark.tags, id: \.self) { tag in
                        Button(tag) {
                            conductor.removeConversationTag(tag, id: convo.id)
                            reloadThreads()
                        }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = convo.id }
        }
        .accessibilityAction(named: pinned ? "Unpin" : "Pin") {
            conductor.pinConversation(id: convo.id, !pinned)
            reloadThreads()
        }
        .accessibilityAction(named: "Rename") {
            renameText = convo.title
            renaming = convo.id
        }
    }

    // MARK: - Thread

    private var thread: some View {
        VStack(spacing: 0) {
            // Always there, empty or not, so the thread starts at the same
            // place in both and the greeting never sits higher than a
            // conversation would (deep dive §2.1).
            copyBar
            ScrollViewReader { proxy in
                ScrollView {
                    if selecting {
                        // One text, so a selection can run from any message
                        // to any other; ⌘A takes the lot.
                        Text(Transcript.styled(conductor.turns))
                            .font(Theme.Typo.prose(14))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.section)
                            .padding(.vertical, Theme.Space.wide)
                        // The same anchor as the list, so toggling Select
                        // keeps the reader where they were: at the end.
                        Color.clear.frame(height: 1).id("bottom")
                    } else {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.roomy) {
                        if conductor.turns.isEmpty { greeting }
                        ForEach(conductor.turns.filter(Self.drawn)) { turn in
                            TurnRow(turn: turn,
                                    expanded: openTools.contains(turn.id),
                                    toggle: { toggleTools(turn.id) },
                                    play: canPlay(turn) ? { conductor.playPauseReply(turn.id) } : nil,
                                    restart: { conductor.restartReply() },
                                    voiceState: conductor.voiceState(of: turn.id),
                                    readFromTop: canPlay(turn) ? { conductor.playReply(turn.id) } : nil,
                                    forgetNoted: { conductor.forgetNoted(turnID: turn.id, claim: $0) },
                                    copyAll: { Transcript.copy(Transcript.plain(conductor.turns)) },
                                    actions: conductor.actions(for: turn),
                                    perform: { perform($0, on: turn) },
                                    edit: turn.role == .you && conductor.canEdit(turn.id)
                                        ? { startEditing(turn) } : nil,
                                    beingEdited: editing == turn.id)
                                .id(turn.id)
                        }
                        if !conductor.partial.isEmpty {
                            TurnRow(turn: Turn(role: .you, text: conductor.partial),
                                    expanded: false, toggle: {})
                                .opacity(0.45)
                        }
                        if let queued = conductor.queuedTyped {
                            ChatQueuedBubble(text: queued,
                                             sendNow: { conductor.sendQueuedNow() },
                                             edit: takeBackQueued,
                                             cancel: { conductor.cancelQueued() })
                        }
                        if let label = workingLabel {
                            ChatWorkingLine(label: label, since: conductor.workingSince,
                                            stop: { conductor.stopEverything() })
                                .id("working")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, Theme.Space.section)
                    .padding(.vertical, Theme.Space.wide)
                    }
                }
                .onChange(of: conductor.turns.count) { _, _ in
                    withAnimation(Theme.Motion.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: conductor.isWorking) { was, now in
                    proxy.scrollTo("bottom", anchor: .bottom)
                    // VoiceOver hears the answer arrive instead of having
                    // to go looking for it.
                    if was, !now, let last = conductor.turns.last, last.role == .moe, !last.text.isEmpty {
                        AccessibilityNotification.Announcement(TurnRow.spoken(last)).post()
                    }
                }
                .onChange(of: conductor.queuedTyped) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                // Swapping the list for the page rebuilds the scroll content,
                // which lands at the top; send it back to the latest message.
                .onChange(of: selecting) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if !ax.granted { talkKeyBanner }
            ForEach(conductor.fixOffers) { offer in
                ChatFixBanner(offer: offer,
                              perform: { conductor.performFix(offer) },
                              dismiss: { conductor.dismissFix(offer) })
            }
            if conductor.inConversation { liveBar }
            composer
        }
        // Anywhere on the thread, not only the box: a drop target the size
        // of a text field is one a drag has to be aimed at.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { attachments.append(contentsOf: await AttachmentIntake.take(providers)) }
            return true
        }
        .overlay { if dropTargeted { dropHint } }
    }

    private var copyBar: some View {
        ChatCopyBar(selecting: $selecting, title: currentTitle, actions: !conductor.turns.isEmpty,
                    model: AnyView(HStack(spacing: Theme.Space.snug) {
                        ChatModelMenu(conductor: conductor)
                        ChatForgetToggle(conductor: conductor)
                    })) {
            Transcript.copy(Transcript.plain(conductor.turns))
        }
    }

    /// The open conversation's name, as the list shows it.
    private var currentTitle: String {
        (threads.pinned + threads.recent + threads.archived)
            .first { $0.id == conductor.currentConversationID }?.title
            ?? (conductor.turns.isEmpty ? "New conversation" : "This conversation")
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.raised.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: Theme.Stroke.edge, dash: [6, 4]))
            )
            .overlay {
                VStack(spacing: Theme.Space.snug) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("Drop to give it to Moe")
                        .font(Theme.Typo.heading(20))
                        .foregroundStyle(Theme.ink)
                    Text("Photos, PDFs, documents — anything on your Mac")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink2)
                }
            }
            .padding(Theme.Space.base)
            .allowsHitTesting(false)
    }

    /// The talk key is dead until Accessibility is on, and chat is one of the
    /// places a person looks when it is. Gone the moment the grant lands.
    private var talkKeyBanner: some View {
        HStack(alignment: .center, spacing: Theme.Space.base) {
            Image(systemName: "keyboard")
                .foregroundStyle(Theme.warn)
            Text(ax.problem(for: conductor.config.talkKey))
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.small)
            PaneButton(title: "Fix") { ax.fix() }
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.warn.opacity(0.08))
    }

    /// The shortcut as configured, never a hard-coded one: the default is
    /// ⌃⌥Space (Config.hotKeyModifiers) and this said ⌥Space.
    private var talkKey: String {
        HotKey.describe(keyCode: conductor.config.hotKeyCode, modifiers: conductor.config.hotKeyModifiers)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text("Hey. What's up?")
                .font(Theme.Typo.display(30))
                .foregroundStyle(Theme.ink)
            Text("Press \(talkKey) and talk, or type below. Ask about your calendar, notes, tasks, files — anything.")
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
        .padding(.top, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.small)
    }

    /// Only while a spoken conversation is open — it says whose turn it is,
    /// which is the thing you cannot tell from a microphone being on.
    private var liveBar: some View {
        HStack(spacing: Theme.Space.small) {
            // Muted mirrors the island's red pill: the same value
            // (`Conductor.micMuted`), the same words, the same colour.
            if conductor.micMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.bad)
            } else {
                Circle()
                    .fill(conductor.mode == .listening ? Theme.bad : Theme.ink3)
                    .frame(width: 6, height: 6)
            }
            Text(conductor.micMuted
                 ? ConversationControls.mutedLine
                 : conductor.mode == .listening
                 ? "Your turn — just talk, no wake word needed"
                 : conductor.mode == .thinking ? "Thinking…" : "Speaking…")
                .font(Theme.Typo.ui(11, weight: conductor.micMuted ? .semibold : .regular))
                .foregroundStyle(conductor.micMuted ? Theme.bad : Theme.ink2)
            Spacer()
            // One direction per label: the word on the button is what it
            // does, even if the state moved under the click.
            Button(conductor.micMuted ? "Unmute" : "Mute") { [muted = conductor.micMuted] in
                conductor.setMicMuted(!muted, from: "chat's \(muted ? "Unmute" : "Mute") button")
            }
                .buttonStyle(.plain)
                .font(Theme.Typo.ui(11, weight: .semibold))
                .foregroundStyle(conductor.micMuted ? Theme.bad : Theme.accentDeep)
                .help(conductor.micMuted ? ConversationControls.unmuteHelp
                                         : ConversationControls.muteHelp)
            Button("End conversation") { conductor.endConversation() }
                .buttonStyle(.plain)
                .font(Theme.Typo.ui(11, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.accentTint)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
        if editing != nil { EditingBar(cancel: cancelEditing) }
        if !attachments.isEmpty { AttachmentTray(attachments: $attachments) }
        HStack(spacing: Theme.Space.base) {
            AddAttachmentButton { attachments.append(contentsOf: $0) }

            // Grows to six lines, then scrolls with the trackpad
            // (`ComposerEditor`); Return sends, Shift-Return is a new line.
            ComposerEditor(text: $typed,
                           placeholder: conductor.meeting.isRecording ? "Ask Moe — quietly" : "Ask Moe",
                           size: 13, lineHeight: 18, maxLines: 6,
                           ink: Theme.ink, placeholderInk: Theme.ink3,
                           attach: { attachments.append(contentsOf: $0) },
                           onSubmit: send)
                // Another screen handed over something to say (Memory's
                // "Answer"): it lands in the box, unsent, for the person
                // to finish or change.
                .onAppear { takeDraft() }
                .onChange(of: conductor.chatDraft) { _, _ in takeDraft() }
                .onChange(of: conductor.chatDraftAttachments) { _, _ in takeDraft() }

            Button(action: { conductor.toggle() }) {
                Image(systemName: conductor.mode == .listening ? "waveform.circle.fill" : "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(conductor.mode == .listening ? Theme.accent : Theme.ink3)
            }
            .buttonStyle(.plain)
            .help("Talk to Moe (\(talkKey))")

            switch ComposerAction.of(working: conductor.isWorking, hasDraft: sendable) {
            case .stop:
                Button { conductor.stopEverything() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .help("Stop: Moe drops this job (esc)")
                .accessibilityLabel("Stop")
            case .send(let enabled):
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(enabled ? Theme.accent : Theme.ink3))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(conductor.isWorking ? "Send when Moe finishes" : "Send")
                .accessibilityLabel(conductor.isWorking ? "Send when Moe finishes" : "Send")
            }
        }
        }
        .padding(.leading, Theme.Space.base)
        .padding(.trailing, Theme.Space.cosy)
        .padding(.vertical, Theme.Space.base)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.edge)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.paper)
        )
        .padding(.horizontal, Theme.Space.section)
        .padding(.bottom, Theme.Space.roomy)
        .padding(.top, Theme.Space.small)
    }

    private var sendable: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: - Actions

    /// A reply that has not begun is a placeholder with no words; the
    /// working line says what is happening instead of an empty "Moe 6:31".
    static func drawn(_ turn: Turn) -> Bool {
        !(turn.role == .moe && turn.isStreaming && turn.text.isEmpty)
    }

    /// The live line's words while Moe works, the same rule as the notch
    /// card's working row (`IslandView.chatRows`): not while the answer is
    /// already streaming in, which says the same thing better.
    private var workingLabel: String? {
        guard conductor.isWorking else { return nil }
        let answering = conductor.turns.last.map { $0.role == .moe && $0.isStreaming && !$0.text.isEmpty } ?? false
        guard !answering else { return nil }
        return WorkingRow.label(step: conductor.workingStep)
    }

    private func takeBackQueued() {
        guard let held = conductor.takeBackQueued() else { return }
        typed = typed.isEmpty ? held.text : held.text + "\n" + typed
        attachments = held.attachments + attachments
    }

    /// A button under the newest turn (`ReplyActions`).
    private func perform(_ action: ReplyAction, on turn: Turn) {
        switch action {
        case .send, .accept: conductor.answer(action)
        case .retry: conductor.retry(failed: turn.id)
        case .copy: Transcript.copy(ReplyActions.draft(in: turn.text) ?? turn.text)
        case .edit:
            if let d = ReplyActions.draft(in: turn.text) { typed = ReplyActionRow.editPrefix + d }
        }
    }

    private func takeDraft() {
        if !conductor.chatDraftAttachments.isEmpty {
            attachments += conductor.chatDraftAttachments
            conductor.chatDraftAttachments = []
        }
        guard let draft = conductor.chatDraft, !draft.isEmpty else { return }
        typed = typed.isEmpty ? draft : typed + " " + draft
        conductor.chatDraft = nil
    }

    private func send() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !t.isEmpty || !files.isEmpty else { return }
        if let id = editing {
            guard conductor.canEdit(id) else { return }
            editing = nil
            typed = ""
            attachments = []
            conductor.resend(editing: id, to: t, attachments: files)
            return
        }
        typed = ""
        attachments = []
        conductor.submit(t, origin: .typed, starter: .person, attachments: files)
    }

    /// Your message, back in the box to change; what you had typed is set
    /// aside for nothing — the box shows the message, as asked.
    private func startEditing(_ turn: Turn) {
        editing = turn.id
        typed = turn.text
        attachments = turn.attachments
    }

    private func cancelEditing() {
        editing = nil
        typed = ""
        attachments = []
    }

    /// ▶ on a finished reply of Moe's, and not while a turn is being worked
    /// on: that reply owns the voice (`Conductor.playReply` refuses too).
    /// One rule for the chat and the island (`Conductor.canPlayReply`).
    private func canPlay(_ turn: Turn) -> Bool { conductor.canPlayReply(turn) }

    private func toggleTools(_ id: UUID) {
        if openTools.contains(id) { openTools.remove(id) } else { openTools.insert(id) }
    }

    private func reloadThreads() {
        marks = conductor.conversationMarks()
        tags = TagRules.vocabulary(marks)
        if let t = tagFilter, !tags.contains(t) { tagFilter = nil }
        threads = ConversationList.arrange(conductor.conversations(matching: query),
                                           marks: marks,
                                           searching: !query.isEmpty, tag: tagFilter)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var grouped: [(String, [ConversationStore.Conversation])] {
        var order: [String] = []
        var byDay: [String: [ConversationStore.Conversation]] = [:]
        for convo in threads.recent {
            let key = Self.day.string(from: convo.updatedAt)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(convo)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }
}

// MARK: - Turn

struct TurnRow: View {
    let turn: Turn
    var expanded: Bool = false
    var toggle: () -> Void = {}
    /// Read this reply out; nil where nothing may be played (a turn still
    /// being written, the live partial).
    var play: (() -> Void)? = nil
    /// From the top again — offered only on the reply whose voice is out.
    var restart: () -> Void = {}
    /// This reply's voice: ▶ when silent or paused, ⏸ while it plays.
    var voiceState: ReplyVoice = .silent
    /// The ⋯ menu's "Read it from the top"; nil where nothing may be played.
    var readFromTop: (() -> Void)? = nil
    /// Undo on a "Noted" line under this answer: forget that claim.
    var forgetNoted: (String) -> Void = { _ in }
    /// Right-click › Copy conversation.
    var copyAll: (() -> Void)? = nil
    /// Send · Edit · Copy, Yes or Retry, on the newest turn only.
    var actions: [ReplyAction] = []
    var perform: (ReplyAction) -> Void = { _ in }
    /// Change this message of yours and send it again; nil where it cannot be.
    var edit: (() -> Void)? = nil
    /// This message is the one in the box being changed.
    var beingEdited = false

    /// Two sides. Every turn used to sit on the left in the same serif and the
    /// same ink, told apart only by a nine-point "YOU" or "MOE" above it, so
    /// finding where you had asked something meant reading labels.
    var body: some View {
        Group {
            switch turn.role {
            case .you: yours
            case .moe: moes
            case .system: note
            }
        }
        // Every message copies, yours as well as Moe's (2026-09-29).
        .contextMenu {
            if !turn.text.isEmpty {
                Button("Copy message") { Transcript.copy(turn.text) }
            }
            if let copyAll { Button("Copy conversation", action: copyAll) }
            if let edit { Button("Edit message", action: edit) }
        }
        // One message is one stop for VoiceOver, "Moe, 6:31 PM: …", with
        // what its buttons do as actions — not a name, a time, two glyphs
        // and then each paragraph as stops of their own (deep dive §2.11).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(turn))
        .accessibilityActions {
            if !turn.text.isEmpty {
                Button("Copy") { Transcript.copy(turn.text) }
            }
            if let edit { Button("Edit", action: edit) }
            if let play, turn.role == .moe {
                Button(voiceState == .playing ? "Pause" : "Read aloud", action: play)
            }
            if !turn.tools.isEmpty || !turn.thinking.isEmpty {
                Button(expanded ? "Hide the steps" : "Show the steps", action: toggle)
            }
            ForEach(turn.links, id: \.url) { link in
                if let url = URL(string: link.url) {
                    Button("Open \(link.label)") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    /// What VoiceOver says for a message: who, when, and the words without
    /// their markdown.
    static func spoken(_ turn: Turn) -> String {
        let words = String(ReplyMarkdown.inline(turn.text).characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let files = turn.attachments.count
        let extra = files == 0 ? "" : files == 1 ? " With 1 attachment." : " With \(files) attachments."
        switch turn.role {
        case .system: return words
        case .you: return "You, \(ChatTime.clock(turn.at)): \(words)\(extra)"
        case .moe: return "Moe, \(ChatTime.clock(turn.at)): \(words)\(extra)"
        }
    }

    /// Yours: on the right, on the accent's tint, in the sans you typed it in.
    private var yours: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.snug) {
            if !turn.attachments.isEmpty { SentAttachments(attachments: turn.attachments) }
            if !turn.text.isEmpty {
                let lines = TextDirection.preparedLines(turn.text)
                Text(MarkdownText.styled(lines.text))
                    .font(Theme.Typo.ui(14))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .reads(lines.direction)
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, Theme.Space.small)
                    .background(bubble.fill(Theme.bubble))
                    .overlay(bubble.strokeBorder(beingEdited ? Theme.accent : Theme.bubbleRule,
                                                 lineWidth: beingEdited ? Theme.Stroke.edge : Theme.Stroke.hair))
            }
            HStack(spacing: Theme.Space.tight) {
                if let edit {
                    Button(action: edit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit this message and send it again")
                    .accessibilityHidden(true)   // an action on the message (`accessibilityActions`)
                }
                Text(ChatTime.clock(turn.at))
                    .font(Theme.Typo.ui(10.5).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
            }
        }
        .frame(maxWidth: 460, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The corner nearest the edge it came from is the tight one.
    private var bubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card,
                               bottomLeadingRadius: Theme.Radius.card,
                               bottomTrailingRadius: Theme.Radius.row / 2,
                               topTrailingRadius: Theme.Radius.card,
                               style: .continuous)
    }

    /// Moe's: on the left, its mark and name, the reading serif at full ink.
    private var moes: some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            Text("M")
                .font(Theme.Typo.heading(13))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.accent))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                HStack(spacing: Theme.Space.small) {
                    Text("Moe")
                        .font(Theme.Typo.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(ChatTime.clock(turn.at))
                        .font(Theme.Typo.ui(10.5).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                    if let play {
                        replyButton(voiceState == .playing ? "pause.fill" : "play.fill",
                                    lit: voiceState != .silent,
                                    help: voiceState == .playing ? "Pause — ▶ carries on from here"
                                        : voiceState == .paused ? "Carry on from where it paused"
                                        : "Read this aloud",
                                    action: play)
                        if voiceState != .silent {
                            replyButton("arrow.counterclockwise", lit: false,
                                        help: "Start it again from the top", action: restart)
                        }
                    }
                    if !turn.isStreaming, !turn.text.isEmpty {
                        Menu {
                            ReplyMenuItems(text: turn.text, readFromTop: readFromTop)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.ink3)
                                .frame(width: 20, height: 18)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                        .strokeBorder(Theme.rule, lineWidth: 1)
                                )
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                        .accessibilityLabel("More for this answer")
                    }
                }
                .frame(height: 24)

                if !turn.tools.isEmpty || !turn.thinking.isEmpty { chips }

                MarkdownText(turn.text)
                    .font(Theme.Typo.prose(15))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: Theme.measure, alignment: .leading)

                if !turn.links.isEmpty { sources }

                if !turn.noted.isEmpty {
                    NotedLines(facts: turn.noted, style: .chat, forget: forgetNoted)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                }

                if !actions.isEmpty {
                    ReplyActionRow(actions: actions, style: .page, perform: perform)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Neither side's: centred, small and quiet.
    private var note: some View {
        VStack(spacing: Theme.Space.small) {
            noteText
            if !actions.isEmpty {
                ReplyActionRow(actions: actions, style: .page, perform: perform).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var noteText: some View {
        Text(MarkdownText.styled(turn.text))
            .font(Theme.Typo.ui(12))
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, Theme.Space.tight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.sunk))
            .frame(maxWidth: Theme.measure)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Hear it. A typed conversation is read on a screen, and sometimes the
    /// answer is better heard — so every reply can be played in Moe's voice,
    /// and paused and carried on with a tap of the talk key like any other.
    private func replyButton(_ symbol: String, lit: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(lit ? Theme.accent : Theme.ink3)
                .frame(width: 20, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: 1)
                )
                // Drawn at 20 × 18, pressable across 24 × 24.
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Collapsed by default. One line each, in the words `describeTool`
    /// already produces — the expansion shows the same list, not raw output.
    private var chips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button(action: toggle) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                    Text(summary)
                        .font(Theme.Typo.ui(11.5, weight: .medium))
                }
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What Moe did: \(summary)")
            .accessibilityValue(expanded ? "Shown" : "Folded")
            .accessibilityHint(expanded ? "Folds the steps" : "Shows the steps")

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(turn.tools.enumerated()), id: \.offset) { _, step in
                        Text(step)
                            .font(Theme.Typo.data(10))
                            .foregroundStyle(Theme.ink3)
                    }
                    if !turn.thinking.isEmpty { ThinkingFold(text: turn.thinking) }
                }
                .padding(Theme.Space.small)
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.sunk)
                )
            }
        }
        .animation(Theme.Motion.easeOut, value: expanded)
    }

    /// "3 steps · 48 s", the line the notch card folds to as well.
    private var summary: String {
        WorkingRow.summary(steps: turn.tools.count, took: turn.took, thought: !turn.thinking.isEmpty) ?? ""
    }

    /// The pages this answer came from, as links you can click. Read off
    /// the tool calls Moe made, so this is where it went — not where it
    /// says it went. Always shown when there are any: a source you have to
    /// ask for twice is the bug this fixes.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(ChatType.section)
                .foregroundStyle(Theme.ink3)
            ForEach(turn.links, id: \.url) { link in
                if let url = URL(string: link.url) {
                    Link(destination: url) {
                        Text(link.label)
                            .font(Theme.Typo.ui(11))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help(link.url)
                }
            }
        }
        .padding(.top, Theme.Space.tight)
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }
}

// MARK: - Markdown

/// Replies arrive as markdown and used to render as literal asterisks.
///
/// Inline styling goes through `AttributedString`; the blocks come from
/// `ReplyBlocks`, the same split the island draws from. Fenced code gets its
/// own well, because a monospaced block inside justified serif prose is the
/// one case where the text really is a different kind of thing. A quote —
/// almost always a draft Moe wrote for you, an email or a message — is a
/// card, the way a mail client shows a message, rather than a column of ">"
/// down the page (the owner, 2026-09-25).
struct MarkdownText: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    /// The one renderer every surface shares (`ReplyView`), in the page's style.
    var body: some View {
        ReplyView(text, style: .page)
    }

    /// Inline only, and whitespace preserved: full markdown parsing collapses
    /// the line breaks that make a list a list.
    ///
    /// `BareLinks.autolink` runs first so a bare `https://example.com` — far
    /// and away the commonest shape a model writes — arrives at the parser as
    /// markdown it already knows how to make clickable. Without it the
    /// renderer links `[label](href)` and leaves every bare address as flat
    /// prose you have to select and copy by hand.
    static func styled(_ s: String) -> AttributedString {
        ReplyMarkdown.inline(s)
    }
}

/// What the ⋯ on one of Moe's answers offers — in the chat window and on the
/// island alike, so the two menus are one menu.
struct ReplyMenuItems: View {
    let text: String
    /// Nil where nothing may be played (`Conductor.canPlayReply`).
    var readFromTop: (() -> Void)?

    var body: some View {
        Button("Copy") { Self.copy(text) }
        if let readFromTop {
            Button("Read it from the top", action: readFromTop)
        }
    }

    /// The answer as written, markdown and all — what was said, not a
    /// rendering of it.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A tool failed for a reason the person can fix (`FixOffer`): the same card
/// the island shows, where the talk-key row sits in Chat.
struct ChatFixBanner: View {
    let offer: FixOffer
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.base) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(Theme.warn)
            Text(offer.why)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.small)
            if let title = offer.actionTitle {
                PaneButton(title: title, prominent: true, action: perform)
            }
            PaneButton(title: FixOffer.dismiss, action: dismiss)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.warn.opacity(0.08))
    }
}

/// Select (the conversation as one page to drag across) and Copy all — a
/// slim bar of its own above the thread, never floating over the text.
struct ChatCopyBar: View {
    @Binding var selecting: Bool
    /// The conversation's name, on the left. Nil leaves it out.
    var title: String? = nil
    /// Select and Copy all, when there is something to select.
    var actions = true
    /// This chat's model, beside its name.
    var model: AnyView? = nil
    let copyAll: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            if let title, !selecting {
                Text(title)
                    .font(Theme.Typo.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
            }
            if let model, !selecting { model }
            if selecting {
                Text("Drag across any messages, or press ⌘A, then ⌘C.")
                    .font(Theme.Typo.ui(11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if actions {
                PaneButton(title: selecting ? "Done" : "Select",
                           symbol: selecting ? "checkmark" : "text.cursor") { selecting.toggle() }
                    .help(selecting ? "Back to the conversation"
                                    : "Show the conversation as one page, to select across messages")
                PaneButton(title: "Copy all", symbol: "doc.on.doc", action: copyAll)
                    .help("Copy the whole conversation")
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, 6)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}
