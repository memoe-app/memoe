import AppKit

/// Quitting while a meeting is on the record.
///
/// ⌘Q used to go straight to `Conductor.shutDown`, which abandons the
/// meeting: the recording is closed and kept, and no notes are ever written
/// — without a word, an hour into a call. Quit asks first now.
///
/// The decision and the words are here, away from AppKit, so they can be
/// tested; `AppDelegate.applicationShouldTerminate` shows the alert and acts
/// on the answer.
enum QuitDuringMeeting {
    /// What is at stake when Quit is chosen.
    enum Question: Equatable {
        /// A meeting is being recorded: quitting leaves it without notes.
        case recording
        /// The meeting has ended and its notes are being written: quitting
        /// leaves them unfinished.
        case writingNotes
    }

    enum Decision: Equatable {
        case quit
        case ask(Question)
    }

    enum Answer: Equatable {
        /// Write the notes (stopping the meeting first if it is still on),
        /// then quit by itself.
        case notesThenQuit
        case quitAnyway
        case cancel
    }

    /// Whether Quit may go ahead as it is. Anything other than a meeting on
    /// the record, or one whose notes are mid-write, quits as it always did.
    static func decide(meeting: Conductor.MeetingState) -> Decision {
        switch meeting {
        case .recording: return .ask(.recording)
        case .stopping: return .ask(.writingNotes)
        case .off, .starting, .done: return .quit
        }
    }

    /// Whether a quit that was waiting on the notes can go now.
    static func notesAreSettled(_ meeting: Conductor.MeetingState) -> Bool {
        decide(meeting: meeting) == .quit
    }

    struct Wording: Equatable {
        let title: String
        let detail: String
        /// In the order they are added: the default, the alternative, Cancel.
        let buttons: [String]
    }

    static func wording(_ question: Question) -> Wording {
        switch question {
        case .recording:
            return Wording(
                title: "Memoe is recording a meeting",
                detail: "If you quit now, the recording and the transcript so far are kept, but no notes are written.",
                buttons: ["Stop and Write Notes", "Quit Anyway", "Cancel"])
        case .writingNotes:
            return Wording(
                title: "Memoe is still writing your meeting notes",
                detail: "If you quit now, the notes are left unfinished. The recording and the transcript so far are kept.",
                buttons: ["Quit When They're Done", "Quit Anyway", "Cancel"])
        }
    }

    /// The answer for the button pressed, by its position in `buttons`.
    static func answer(buttonIndex: Int) -> Answer {
        switch buttonIndex {
        case 0: return .notesThenQuit
        case 1: return .quitAnyway
        default: return .cancel
        }
    }

    // MARK: - After "write the notes, then quit"

    /// How long a quit waits for the notes to reach Telegram once they are
    /// written. The send is one turn of the brain; past this it is not
    /// coming back in time to matter, and the notes are on the Mac either way.
    static let deliveryLimit: TimeInterval = 20

    /// What the wait remembers between looks.
    struct Waiting: Equatable {
        /// When the notes were down and the send was first seen in the air.
        var deliverySince: Date?
    }

    enum Next: Equatable {
        /// Not yet: what it is waiting for, for the person.
        case wait(String)
        /// Go: why, for the log.
        case quit(String)
    }

    /// One look at a quit that is waiting. The notes first; then, if they
    /// are on their way to Telegram (`Config.meetingSendTelegram`), the
    /// send — until it finishes, fails, or `deliveryLimit` has passed.
    ///
    /// Quit used to go the moment the notes were on disk, which is the same
    /// moment the send starts: the person chose "Stop and Write Notes",
    /// the notes were written, and the copy they asked to be sent was cut
    /// off by the quit they had been promised would wait.
    static func next(meeting: Conductor.MeetingState, delivering: Bool,
                     waiting: inout Waiting, now: Date = Date()) -> Next {
        guard notesAreSettled(meeting) else {
            waiting.deliverySince = nil
            return .wait("Writing your meeting notes. Memoe quits when they are done.")
        }
        guard delivering else {
            return .quit(waiting.deliverySince == nil
                         ? "the meeting notes are settled"
                         : "the meeting notes are settled and the Telegram send has finished")
        }
        let since = waiting.deliverySince ?? now
        waiting.deliverySince = since
        let left = deliveryLimit - now.timeIntervalSince(since)
        guard left > 0 else {
            return .quit("the notes are written; the Telegram send had not finished after "
                         + "\(Int(deliveryLimit)) s, so it may not have gone")
        }
        let seconds = max(1, Int(left.rounded(.up)))
        return .wait("Your notes are written. Sending them to Telegram; Memoe quits when that is done, "
                     + "or in \(seconds) second\(seconds == 1 ? "" : "s").")
    }

    @MainActor
    static func ask(_ question: Question) -> Answer {
        let words = wording(question)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = words.title
        alert.informativeText = words.detail
        for title in words.buttons { alert.addButton(withTitle: title) }
        NSApp.activate(ignoringOtherApps: true)
        let pressed = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answer(buttonIndex: pressed)
    }
}

/// The small window a waiting quit shows: what it is waiting for, and a way
/// to stop waiting. Without it the alert closes, nothing visible happens for
/// up to a few minutes, and the app looks as if it ignored ⌘Q.
@MainActor
final class QuitWaitPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private let onQuitNow: () -> Void

    init(onQuitNow: @escaping () -> Void) {
        self.onQuitNow = onQuitNow
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Quitting Memoe"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        spinner.setAccessibilityElement(false)
        let button = NSButton(title: "Quit Now", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded

        let content = NSView()
        content.addSubview(spinner)
        content.addSubview(label)
        content.addSubview(button)
        panel.contentView = content
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        button.target = self
        button.action = #selector(quitNow)
    }

    func say(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        if !panel.isVisible {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() { panel.orderOut(nil) }

    @objc private func quitNow() { onQuitNow() }
}
