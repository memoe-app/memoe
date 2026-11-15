import AppKit
import MoeDesign
import MoeMeeting
import SwiftUI

/// Settings › Meetings.
///
/// Simple by default: what is happening now, then the meetings you have
/// had — a name, how long, one line about it. Click one and you get the
/// summary, the action items as things you can tick, and the transcript
/// folded away. No paths, no file names, no switches you have to
/// understand: those live under Advanced, for the people who want them.
struct MeetingsPane: View {
    @ObservedObject var conductor: Conductor
    @State private var past: [MeetingRecord] = []
    /// The folder of the meeting whose detail is open, if any. Held as the
    /// folder rather than the record so a reload keeps the right one open.
    @State private var openFolder: String?
    /// The offer to read the invite, when the calendar is not readable yet.
    /// Held in state so pressing the button can refresh it.
    @State private var calendarOffer: String?
    @State private var calendarRefused = false
    /// A snapshot's pose: one meeting open, with "Write the notes" as it
    /// stands in that state. Nothing is read from disk for it.
    struct Posed {
        var record: MeetingRecord
        var notes: MeetingNotesWriter.State
    }
    var posed: Posed?

    var body: some View {
        Group {
            if let posed {
                MeetingDetail(conductor: conductor, record: posed.record, onBack: {}, onChanged: {},
                              posedNotes: posed.notes)
            } else if let folder = openFolder, let record = past.first(where: { $0.folder == folder }) {
                MeetingDetail(conductor: conductor, record: record,
                              onBack: { openFolder = nil },
                              onChanged: { reload() })
            } else {
                list
            }
        }
        // The pane draws its own header now.
        .onAppear(perform: reload)
        .onChange(of: conductor.meeting) { _, _ in reload() }
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Meetings") {
                if conductor.meeting.isRecording {
                    PaneButton(title: "Note this") { conductor.addMeetingBookmark() }
                        .help("Bookmark this moment (⌃⌥Space, or a tap of the hold key, does the same)")
                    PaneButton(title: conductor.meetingPaused ? "Back on the record" : "Off the record") {
                        conductor.toggleMeetingPause()
                    }
                    .help("Pause: nothing said while paused is recorded or transcribed")
                }
                startButton
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.roomy) {
                    nowStrip
                    meetingList
                    MeetingAdvanced(conductor: conductor)
                }
                .padding(.horizontal, Theme.Space.wide)
                .padding(.vertical, Theme.Space.roomy)
            }
        }
        .background(Theme.raised)
    }

    /// The one filled button in the pane. Stop is red — it is the only
    /// control here whose effect a person needs to find in a hurry.
    private var startButton: some View {
        Button { conductor.requestMeeting() } label: {
            Text(conductor.meeting.isRecording ? "Stop" : "Start meeting")
                .font(Theme.Typo.ui(12, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, Theme.Space.cosy)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .fill(conductor.meeting.isRecording ? Theme.bad : Theme.accent)
                )
        }
        .buttonStyle(.plain)
        .disabled(conductor.meeting.isBusy)
        .opacity(conductor.meeting.isBusy ? 0.5 : 1)
    }

    private var nowStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            HStack(spacing: Theme.Space.small) {
                Circle()
                    .fill(conductor.meeting.isRecording && !conductor.meetingPaused
                          ? Theme.bad : Theme.ink3.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(nowText)
                    .font(Theme.Typo.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if !conductor.meetingHealth.isEmpty {
                    Text(conductor.meetingHealth)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.warn)
                }
                Spacer()
            }

            if !conductor.meetingStatus.isEmpty {
                Text(conductor.meetingStatus)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
            }

            Text("""
            Moe records your microphone and the call's audio, writes the transcript \
            and the notes, and answers you in text while it listens — hold \(conductor.config.talkKey.inSentence) and \
            whisper, or click the notch and type. Everyone in the meeting should \
            know: it is \(MeetingOwner.assistantLabel(userName: MeetingSession.ownerName())) \
            in the room, and the announcement is one click away when you start.
            """)
            .font(Theme.Typo.prose(13))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)

            // Names in the notes come from the invite. Offered, never
            // insisted on: a meeting records and reads exactly the same
            // without it, so this is an improvement to accept and not a
            // problem to fix.
            if let calendarOffer {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                    Text(calendarOffer)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: Theme.Space.small)
                    PaneButton(title: calendarRefused ? "Open Settings" : "Use my calendar") {
                        Task {
                            _ = await MeetingInvite.requestAccess()
                            refreshCalendarOffer()
                        }
                    }
                }
                .padding(.top, Theme.Space.tight)
            }

            HStack(spacing: Theme.Space.tight) {
                Text("Screenshots, screen recording and call detection are configured in")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                Button("Settings \u{203A} Meeting Capture") {
                    SettingsWindow.show(conductor: conductor, at: .meetingCapture)
                }
                .buttonStyle(.link)
                .font(Theme.Typo.ui(11))
            }
            .padding(.top, Theme.Space.tight)

            Toggle("Ask before starting", isOn: Binding(
                get: { conductor.config.meetingAskBeforeStart },
                set: { conductor.setMeetingAskBeforeStart($0) }))
                .toggleStyle(.switch)
                .font(Theme.Typo.ui(12))
                .padding(.top, Theme.Space.tight)
        }
        .padding(Theme.Space.cosy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.edge)
        )
    }

    @ViewBuilder
    private var meetingList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text("Your meetings")
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)

            if past.isEmpty {
                Text("None yet. Start one above, and the notes land here when it ends.")
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
            }

            ForEach(past, id: \.folder) { record in
                Button { openFolder = record.folder } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MeetingListing.title(record))
                                .font(Theme.Typo.ui(13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(MeetingListing.blurb(record))
                                .font(Theme.Typo.ui(11))
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: Theme.Space.small)
                        Text(Timeline.clock(record.durationSeconds))
                            .font(Theme.Typo.data(10))
                            .foregroundStyle(Theme.ink3)
                            .accessibilityLabel(MeetingsPane.spokenLength(record.durationSeconds))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, Theme.Space.base)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.rule).frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this meeting's notes")
            }
        }
    }

    /// "42:07" on screen; "42 minutes" aloud.
    static func spokenLength(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "Under a minute" }
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        let h = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? h : "\(h) \(rest) minute\(rest == 1 ? "" : "s")"
    }

    private var nowText: String {
        switch conductor.meeting {
        case .off: return "Not recording"
        case .starting: return "Starting…"
        case .recording: return conductor.meetingPaused ? "Off the record · \(conductor.meetingClock)" : "Recording · \(conductor.meetingClock)"
        case .stopping: return "Writing your notes…"
        case .done: return "Notes ready"
        }
    }

    private func reload() {
        // `MeetingListing.load` keys each record on the folder it was read
        // from and keeps a meeting whose `meeting.json` is missing or
        // corrupt in the list, saying so. Reading the records straight out
        // of the JSON dropped those folders silently: a directory full of
        // recordings under a heading that said "None yet."
        past = MeetingListing.load(directory: Paths.meetings)
        if let open = openFolder, !past.contains(where: { $0.folder == open }) { openFolder = nil }
        refreshCalendarOffer()
    }

    private func refreshCalendarOffer() {
        calendarOffer = MeetingInvite.offer
        calendarRefused = MeetingInvite.access == .denied
    }
}

// MARK: - One meeting

/// The summary, the action items, the transcript folded away, Delete.
private struct MeetingDetail: View {
    @ObservedObject var conductor: Conductor
    let record: MeetingRecord
    let onBack: () -> Void
    let onChanged: () -> Void

    @State private var transcript = ""
    @State private var transcriptOpen = false
    @State private var confirmingDelete = false
    /// Items whose Reminder is being created. `record` is a value read off
    /// disk, so it still says `reminded == false` until the reload lands —
    /// without this a second click on the same box makes a second Reminder.
    @State private var ticking: Set<Int> = []
    /// The voice whose name is being typed by hand, and what has been typed.
    @State private var typingFor: Int?
    @State private var typed = ""
    /// Voices whose rename is still being written to disk.
    @State private var renaming: Set<Int> = []
    /// "Write the notes": whether this meeting is one it is offered on (no
    /// notes, and a transcript to write them from), and how it is going.
    @State private var notesOffered: Bool
    @State private var notesWriting: MeetingNotesWriter.State
    private let isPosed: Bool

    /// `posedNotes` is for a snapshot, which runs no task and waits for
    /// nothing: the button as it stands in that state.
    init(conductor: Conductor, record: MeetingRecord, onBack: @escaping () -> Void,
         onChanged: @escaping () -> Void, posedNotes: MeetingNotesWriter.State? = nil) {
        self.conductor = conductor
        self.record = record
        self.onBack = onBack
        self.onChanged = onChanged
        isPosed = posedNotes != nil
        _notesOffered = State(initialValue: posedNotes != nil)
        _notesWriting = State(initialValue: posedNotes ?? .idle)
    }

    private var folder: URL { URL(fileURLWithPath: record.folder, isDirectory: true) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.roomy) {
                    title
                    audioNotes
                    summary
                    writeNotes
                    screens
                    decisions
                    speakerNames
                    actionItems
                    todos
                    openQuestions
                    transcriptSection
                }
                .padding(.horizontal, Theme.Space.wide)
                .padding(.vertical, Theme.Space.roomy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.raised)
        .task(id: record.folder + (record.summarised ? "+" : "-")) {
            guard !isPosed, notesWriting == .idle else { return }
            let record = record
            notesOffered = await Task.detached { MeetingNotesWriter.isOffered(for: record) }.value
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                conductor.deleteMeeting(folder: folder)
                onBack()
                onChanged()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The recording, the transcript and the notes all go. This cannot be undone.")
        }
    }

    /// Back belongs at the top left, where every other Mac app puts it — it
    /// was at the bottom of a form, under the transcript, which is the last
    /// place someone looks for the way out.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.base) {
                Button(action: onBack) {
                    HStack(spacing: Theme.Space.tight) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("All meetings")
                            .font(Theme.Typo.ui(12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to all meetings")

                Spacer()

                Button { confirmingDelete = true } label: {
                    HStack(spacing: Theme.Space.snug) {
                        Image(systemName: "trash").font(.system(size: 10, weight: .medium))
                            .accessibilityHidden(true)
                        Text("Delete").font(Theme.Typo.ui(12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.bad)
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                            .strokeBorder(Theme.bad.opacity(0.4), lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete this meeting")
            }
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.base)
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(MeetingListing.title(record))
                .font(Theme.Typo.display(26))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Text("\(MeetingListing.dateLabel(record.startedAt)) · \(Timeline.clock(record.durationSeconds))")
                .font(Theme.Typo.data(11))
                .foregroundStyle(Theme.ink3)
        }
    }

    /// The one place a person can find out that this meeting's audio is still
    /// on disk although the setting said delete it — and the other way round.
    /// `recordingsKeptReason` used to be written into meeting.json and read by
    /// nothing: the only telling was a sentence on the island's status line,
    /// gone the moment the panel was dismissed. Recordings of other people
    /// outliving the setting that promised to delete them has to be
    /// discoverable later, not only in passing.
    @ViewBuilder private var audioNotes: some View {
        if let why = record.recordingsKeptReason {
            noteRow(why, symbol: "waveform.circle", tint: Theme.warn)
        }
        if let why = record.recordingsDeletedNote {
            noteRow(why, symbol: "waveform.slash", tint: Theme.ink3)
        }
    }

    private func noteRow(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.small) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.base)
        .frame(maxWidth: Theme.measure, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.sunk)
        )
    }

    @ViewBuilder private var summary: some View {
        if let notes = record.notes, !notes.summary.isEmpty {
            Text(notes.summary)
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        } else {
            Text(MeetingListing.blurb(record))
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    /// A meeting with no notes and a transcript: write them now. The notes
    /// failed, or the meeting was stopped early, and that used to be final.
    @ViewBuilder private var writeNotes: some View {
        if notesOffered {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                HStack(alignment: .top, spacing: Theme.Space.small) {
                    if notesWriting == .writing {
                        ProgressView().controlSize(.small)
                            .accessibilityHidden(true)
                    } else if case .failed = notesWriting {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warn)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                    }
                    Text(MeetingNotesWriter.line(notesWriting))
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if notesWriting != .writing {
                    PaneButton(title: MeetingNotesWriter.buttonTitle(notesWriting), prominent: true) { startWritingNotes() }
                        .help("Your AI reads the saved transcript and writes the notes")
                }
            }
            .padding(Theme.Space.base)
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.sunk)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notes for this meeting")
        }
    }

    private func startWritingNotes() {
        guard notesWriting != .writing else { return }
        notesWriting = .writing
        let folder = folder
        let brain = HermesMeetingBrain(config: conductor.config, purpose: .notes, meetingID: "rewrite")
        Task {
            let result = await MeetingNotesWriter.write(folder: folder, brain: brain)
            notesWriting = result
            if result == .idle {
                notesOffered = false
                onChanged()
            }
        }
    }

    /// The pictures: a strip of thumbnails, each opening the file. Clips
    /// show as a film icon with their length.
    @ViewBuilder private var screens: some View {
        let shots = record.captures.filter { CaptureFile.isSafe($0.file) }
        if !shots.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Screens")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Space.base) {
                        ForEach(shots, id: \.file) { c in
                            CaptureThumb(capture: c, url: folder.appendingPathComponent(c.file))
                        }
                    }
                    .padding(.vertical, Theme.Space.tight)
                }
                Text("\(shots.count) \(shots.count == 1 ? "capture" : "captures"), in the meeting's folder under shots/ and clips/. Click one to open it.")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    @ViewBuilder private var decisions: some View {
        if let notes = record.notes, !notes.decisions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Decisions")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                ForEach(notes.decisions, id: \.self) { decision in
                    HStack(alignment: .top, spacing: Theme.Space.small) {
                        Text("—")
                            .font(Theme.Typo.prose(15))
                            .foregroundStyle(Theme.ink3)
                        Text(decision)
                            .font(Theme.Typo.prose(15))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    @ViewBuilder private var actionItems: some View {
        if let notes = record.notes, !notes.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Action items")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)

                ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { i, item in
                    let done = item.reminded == true || ticking.contains(i)
                    Toggle(isOn: Binding(get: { done }, set: { if $0 { tick(i) } })) {
                        Text(label(item))
                            .font(Theme.Typo.prose(14))
                            .foregroundStyle(done ? Theme.ink3 : Theme.ink2)
                    }
                    .toggleStyle(.switch)
                    .disabled(done)
                    .padding(.vertical, Theme.Space.snug)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.rule).frame(height: 1)
                    }
                }

                Text("Ticking one puts it in your Reminders. Unticking is done in Reminders.")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, Theme.Space.tight)
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    /// Work the meeting said needs doing that nobody took on. Separate from
    /// action items and deliberately below them: there is no owner to tick
    /// it off against, so it gets no Reminders toggle — it is a list to read
    /// and decide about, not a list to close.
    @ViewBuilder private var todos: some View {
        if let notes = record.notes, !notes.todos.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("To do")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                ForEach(notes.todos, id: \.self) { todo in
                    HStack(alignment: .top, spacing: Theme.Space.small) {
                        Text("—")
                            .font(Theme.Typo.prose(15))
                            .foregroundStyle(Theme.ink3)
                        Text(todo)
                            .font(Theme.Typo.prose(15))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Nobody put their name to these.")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, Theme.Space.tight)
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    /// What the meeting asked and nobody answered. summary.md has carried
    /// this heading since the notes gained the field, and until 2026-09-16
    /// this page drew every other heading in the file and not this one —
    /// so a question was on disk and nowhere on the screen. Same shape as
    /// Decisions: a dash a line, only when there is something to show.
    @ViewBuilder private var openQuestions: some View {
        if let notes = record.notes, !notes.openQuestions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Open questions")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                ForEach(notes.openQuestions, id: \.self) { question in
                    HStack(alignment: .top, spacing: Theme.Space.small) {
                        Text("—")
                            .font(Theme.Typo.prose(15))
                            .foregroundStyle(Theme.ink3)
                        Text(question)
                            .font(Theme.Typo.prose(15))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    private var transcriptSection: some View {
        DisclosureGroup(isExpanded: $transcriptOpen) {
            Group {
                if transcript.isEmpty {
                    Text("The transcript is empty.")
                        .font(Theme.Typo.prose(14))
                        .foregroundStyle(Theme.ink3)
                } else {
                    ScrollView {
                        Text(transcript)
                            .font(Theme.Typo.data(11))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.base)
                    }
                    .frame(height: 260)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .fill(Theme.sunk)
                    )
                }
            }
            .padding(.top, Theme.Space.small)
        } label: {
            Text("Transcript")
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
        }
        .onChange(of: transcriptOpen) { _, open in if open { loadTranscript() } }
    }

    /// Who was speaking, and where a name gets corrected.
    ///
    /// From main, moved out of its `Form` `Section` into the pane's own
    /// register. A voice is "Dan", or it is "Speaker 2" until somebody says —
    /// nothing here says cluster or diarizer.
    @ViewBuilder private var speakerNames: some View {
        if !voices.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Who was speaking")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)

                ForEach(voices, id: \.speaker) { entry in
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        HStack {
                            Text(entry.label)
                                .font(Theme.Typo.ui(13))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: Theme.Space.small)
                            Menu(entry.name == nil ? "Give this voice a name" : "Change") {
                                ForEach(choices(for: entry), id: \.self) { name in
                                    Button(name) { rename(entry.speaker, to: name) }
                                }
                                Button("Someone else…") {
                                    typed = entry.name ?? ""
                                    typingFor = entry.speaker
                                }
                                if entry.name != nil {
                                    Divider()
                                    Button("Not sure who this was") { rename(entry.speaker, to: nil) }
                                }
                            }
                            .fixedSize()
                            .disabled(renaming.contains(entry.speaker))
                        }
                        if typingFor == entry.speaker {
                            HStack {
                                TextField("Their name", text: $typed)
                                    .onSubmit { saveTyped(entry.speaker) }
                                Button("Save") { saveTyped(entry.speaker) }
                                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { typingFor = nil }
                            }
                            .font(Theme.Typo.ui(12))
                        }
                    }
                    .padding(.vertical, Theme.Space.tight)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.rule).frame(height: 1)
                    }
                }

                let hint = SpeakerNaming.explanation(SpeakerNameBook(names: voices))
                if !hint.isEmpty {
                    Text(hint)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    private func label(_ item: MeetingNotes.ActionItem) -> String {
        (item.who.isEmpty ? "" : "\(item.who): ") + item.what + (item.when.isEmpty ? "" : " — by \(item.when)")
    }

    /// One row per voice heard. Taken from the record's names *and* from
    /// the plain speaker numbers, so a meeting recorded before there were
    /// names — or one whose notes timed out — can still be named by hand.
    private var voices: [SpeakerName] {
        let book = record.nameBook
        let numbers = Set(record.speakers).union(book.names.map(\.speaker)).sorted()
        return numbers.map { book.entry(for: $0) ?? SpeakerName(speaker: $0) }
    }

    /// The names to offer for a voice: whoever was invited (the candidates
    /// the invite gave this meeting), plus anything already typed for
    /// another voice, minus this voice's current name.
    private func choices(for entry: SpeakerName) -> [String] {
        var out: [String] = []
        for name in entry.candidates + record.speakerNames.compactMap(\.name)
            + SpeakerNaming.nameable(attendees: record.attendees, youName: MeetingSession.ownerName()) {
            guard name != entry.name, !out.contains(name) else { continue }
            out.append(name)
        }
        return out
    }

    private func saveTyped(_ speaker: Int) {
        let name = typed.trimmingCharacters(in: .whitespaces)
        typingFor = nil
        guard !name.isEmpty else { return }
        rename(speaker, to: name)
    }

    /// One name, everywhere in this meeting: the transcript, the notes and
    /// the record. `Conductor.renameSpeaker` does the writing.
    private func rename(_ speaker: Int, to name: String?) {
        guard !renaming.contains(speaker) else { return }
        renaming.insert(speaker)
        Task {
            _ = await Conductor.renameSpeaker(in: record, speaker: speaker, to: name)
            transcript = ""
            if transcriptOpen { loadTranscript() }
            renaming.remove(speaker)
            onChanged()
        }
    }

    private func tick(_ index: Int) {
        guard !ticking.contains(index) else { return }
        ticking.insert(index)
        Task {
            await Conductor.tickActionItem(in: record, index: index)
            onChanged()
            // Kept until the reloaded record says `reminded`, so the box
            // never flicks back to empty and invites a second click.
        }
    }

    /// Bounded on both counts: the name is taken as a file name inside this
    /// meeting's folder and nothing else, and only the first
    /// `TranscriptFile.maxBytes` are read — a whole day's transcript in one
    /// `Text` lays out on the main thread and hangs the window.
    private func loadTranscript() {
        guard transcript.isEmpty else { return }
        let url = folder.appendingPathComponent(TranscriptFile.safeName(record.transcriptFile))
        transcript = TranscriptFile.read(url)
    }
}
// MARK: - Capture

/// One thumbnail in the Screens strip.
private struct CaptureThumb: View {
    let capture: CaptureRecord
    let url: URL
    @State private var image: NSImage?

    /// "Screenshot at 12:40. <what the AI saw in it>."
    private var spoken: String {
        let what = capture.kind == .recording ? "Clip" : "Screenshot"
        let caption = capture.caption.map { $0.isEmpty ? "" : ". \($0)" } ?? ""
        return "\(what) at \(Timeline.clock(capture.at))\(caption)"
    }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.sunk)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 160, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: capture.kind == .recording ? "film" : "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.ink3)
                                .accessibilityHidden(true)
                            if capture.kind == .recording, let d = capture.durationSeconds {
                                Text(Timeline.clock(d)).font(Theme.Typo.data(10)).foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                }
                .frame(width: 160, height: 100)
                Text("\(Timeline.clock(capture.at)) · \(capture.reason.isEmpty ? (capture.kind == .recording ? "clip" : "screenshot") : capture.reason.replacingOccurrences(of: "-", with: " "))")
                    .font(Theme.Typo.data(10))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                if let caption = capture.caption, !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                        .frame(width: 160, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { NSWorkspace.shared.open(url) }
        .onAppear {
            guard capture.kind == .screenshot, image == nil else { return }
            let u = url
            Task.detached(priority: .utility) {
                let img = NSImage(contentsOf: u)
                await MainActor.run { image = img }
            }
        }
    }
}

// MARK: - Advanced

/// Everything the simple pane deliberately leaves out: where the files are,
/// whether the audio is kept, the shortcut, and whether the transcript goes
/// to your AI at all.
private struct MeetingAdvanced: View {
    @ObservedObject var conductor: Conductor
    @State private var open = false

    var body: some View {
        // Outside a `Form` now, so the toggles need to be asked for as
        // switches — a bare macOS Toggle draws a checkbox.
        Group {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: Theme.Space.base) {
                Toggle("Summarise with your AI", isOn: Binding(
                    get: { conductor.config.meetingSummarise },
                    set: { conductor.setMeetingSummarise($0) }))
                Text("""
                While the meeting runs, the new lines go to your connected AI once a \
                minute so it can spot action items and answer you; at the end the whole \
                transcript goes once for the title, summary and decisions. Off, nothing \
                leaves this Mac and only the transcript is written.
                """)
                .font(.caption).foregroundStyle(.secondary)

                Toggle("Keep the audio after the notes are written", isOn: Binding(
                    get: { !conductor.config.meetingDeleteRecordings },
                    set: { conductor.setMeetingDeleteRecordings(!$0) }))
                Text("""
                Off by default: the recordings are deleted once the notes exist, and the \
                transcript and notes stay. The audio is kept anyway when the notes could not \
                be written — or when almost nothing was transcribed and the meeting was \
                under \(Int(CaptureCheck.keepCeilingSeconds / 60)) minutes, because then the \
                recording is the only evidence of why and it is small enough to be worth \
                keeping. Past that the recordings are deleted as asked; each meeting's page \
                says which happened.
                """)
                    .font(.caption).foregroundStyle(.secondary)

                let telegramTarget = conductor.meetingTelegramTarget
                // The stored setting, never `stored && configured`.
                //
                // It was the second of those, and a control that shows
                // something other than what is stored is a control that
                // lies about what will happen. Disconnect the bot and this
                // switch went to off while `meetingSendTelegram` stayed
                // true — so the user, believing they had turned it off (or
                // never turned it on), reconnected the bot later and
                // sending silently re-armed itself. The setting sends a
                // meeting's notes off the Mac; it is not one to be wrong
                // about in that direction.
                //
                // `.disabled` is the right way to say "not now": it greys
                // the switch without changing what it reads, and the
                // caption underneath says what is missing.
                Toggle("Send the notes to my Telegram when a meeting ends", isOn: Binding(
                    get: { conductor.config.meetingSendTelegram },
                    set: { conductor.setMeetingSendTelegram($0) }))
                .disabled(telegramTarget == nil)
                Text(TelegramSelf.switchExplanation(target: telegramTarget,
                                                    on: conductor.config.meetingSendTelegram))
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("⌃⌥M starts and stops a meeting", isOn: Binding(
                    get: { conductor.config.meetingHotkey },
                    set: { conductor.setMeetingHotkey($0) }))
                Text("Off by default: a global shortcut that records other people is one you should have switched on yourself.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("⌃⌥S takes a screenshot and ⌃⌥R records the screen, while a meeting is on", isOn: Binding(
                    get: { conductor.config.meetingCaptureHotkeys },
                    set: { conductor.setMeetingCaptureHotkeys($0) }))
                Text("The two shortcuts exist only while Moe is recording a meeting; the rest of the time they are nobody's.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Folder") {
                    HStack {
                        Text(Paths.meetings.path).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Open folder") {
                            try? FileManager.default.createDirectory(at: Paths.meetings, withIntermediateDirectories: true,
                                                                     attributes: [.posixPermissions: 0o700])
                            NSWorkspace.shared.open(Paths.meetings)
                        }
                    }
                }
                Text("One folder per meeting: system.wav, mic.wav, transcript.txt, summary.md, meeting.json, and shots/ and clips/ for what was captured. Readable only by your account.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, Theme.Space.small)
                .frame(maxWidth: Theme.measure, alignment: .leading)
            } label: {
                Text("Advanced")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
            }
            .toggleStyle(.switch)
        }
    }
}
