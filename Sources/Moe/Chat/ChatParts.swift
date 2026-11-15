import AppKit
import MoeChat
import MoeDesign
import MoeIsland
import SwiftUI

/// The Chat page's live line while Moe works: a breathing dot, what it is
/// doing, how long it has been at it, and Stop. The island always said
/// "Thinking 0:43 · Opening OpenTable…"; the window, the bigger surface,
/// said nothing at all until words arrived (deep dive §2.4).
struct ChatWorkingLine: View {
    let label: String
    let since: Date?
    let stop: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
                .modifier(Breathing())
                .accessibilityHidden(true)
            Text(label)
                .font(Theme.Typo.ui(13))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            if let since {
                WorkingClock(since: since, ink: Theme.ink3, size: 12)
            }
            PaneButton(title: "Stop", symbol: "stop.fill", action: stop)
                .help("Stop: Moe drops this job (esc)")
        }
        .padding(.leading, 24 + Theme.Space.base)
        .frame(maxWidth: Theme.measure + 24 + Theme.Space.base, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Moe is working: \(label)")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// What you typed while Moe was still working, where you typed it: dimmed,
/// on your side, with what you can do about it. The page used to take it
/// out of the box and show it nowhere until the turn ended (deep dive §2.3).
struct ChatQueuedBubble: View {
    let text: String
    let sendNow: () -> Void
    let edit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.snug) {
            let lines = TextDirection.preparedLines(text)
            Text(MarkdownText.styled(lines.text))
                .font(Theme.Typo.ui(14))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .reads(lines.direction)
                .padding(.horizontal, Theme.Space.base)
                .padding(.vertical, Theme.Space.small)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.bubble))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.bubbleRule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .opacity(0.7)
            HStack(spacing: Theme.Space.small) {
                Text("Sends when Moe finishes")
                    .font(Theme.Typo.ui(11.5))
                    .foregroundStyle(Theme.ink3)
                ChatLinkButton(title: "Send now", action: sendNow)
                    .help("Stop what Moe is doing and send this now")
                ChatLinkButton(title: "Edit", action: edit)
                    .help("Put it back in the box")
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don't send it")
                .accessibilityLabel("Don't send it")
            }
        }
        .frame(maxWidth: 460, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A word that is a button, in the accent: for small actions in a line of text.
struct ChatLinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.Typo.ui(11.5, weight: .semibold))
            .foregroundStyle(Theme.accentDeep)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
    }
}

/// The composer's right-hand button: send, or ■ while Moe works and there
/// is nothing typed to send (the owner, 2026-11-13). What you type while it
/// works is held and sent when it finishes, so with words in the box the
/// arrow comes back and queues them.
enum ComposerAction: Equatable {
    case send(enabled: Bool)
    case stop

    static func of(working: Bool, hasDraft: Bool) -> ComposerAction {
        if working, !hasDraft { return .stop }
        return .send(enabled: hasDraft)
    }
}

/// Times the way this Mac shows them: "6:31 PM" on a 12-hour Mac, "18:31"
/// on a 24-hour one. It was always "HH:mm" (deep dive §2.11).
enum ChatTime {
    static let formatter = make(.current)

    static func make(_ locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }

    static func clock(_ date: Date) -> String { formatter.string(from: date) }
}

/// The chat's small type (deep dive §2.10): section labels were 9 pt,
/// letter-spaced, below what reads comfortably on a Retina screen; they are
/// 11 pt sentence case now.
enum ChatType {
    static let section = Theme.Typo.ui(11, weight: .semibold)
}

/// The model's thinking, inside the opened steps and folded again there
/// (the owner's answer 10): one line saying it is there, the whole of it a
/// click away. Only ever drawn when the provider streamed some.
struct ThinkingFold: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                    Text("Thinking")
                        .font(Theme.Typo.ui(11, weight: .medium))
                }
                .foregroundStyle(Theme.ink3)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide Moe's thinking" : "Show Moe's thinking")
            if open {
                let lines = TextDirection.preparedLines(text)
                Text(lines.text)
                    .font(Theme.Typo.ui(12).italic())
                    .foregroundStyle(Theme.ink3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .reads(lines.direction)
            }
        }
    }
}

/// Send · Edit · Copy, Yes, or Retry, under the newest turn, on the Chat
/// page and the notch card alike (`ReplyActions`).
struct ReplyActionRow: View {
    enum Style { case page, island }
    let actions: [ReplyAction]
    let style: Style
    let perform: (ReplyAction) -> Void
    @State private var copied = false

    /// What Edit puts in front of the draft in the box, so what comes back
    /// reads as a change to it rather than a new message.
    static let editPrefix = "Use this version instead:\n\n"

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions, id: \.self) { action in
                Button {
                    perform(action)
                    if action == .copy {
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    }
                } label: {
                    Text(action == .copy && copied ? "Copied" : action.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ink(action))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(fill(action)))
                        .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(action))
                .accessibilityLabel(help(action))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primary(_ a: ReplyAction) -> Bool { a == .send || a == .accept || a == .retry }

    private func ink(_ a: ReplyAction) -> Color {
        switch style {
        case .page: return primary(a) ? Theme.onAccent : Theme.ink2
        case .island: return primary(a) ? .black : .white.opacity(0.8)
        }
    }

    private func fill(_ a: ReplyAction) -> Color {
        switch style {
        case .page: return primary(a) ? Theme.accent : Color.clear
        case .island: return primary(a) ? .white.opacity(0.9) : .white.opacity(0.08)
        }
    }

    private var edge: Color { style == .page ? Theme.rule : .clear }

    private func help(_ a: ReplyAction) -> String {
        switch a {
        case .send: return "Tell Moe to send it — you still confirm before anything goes"
        case .edit: return "Put the draft in the box to change it"
        case .copy: return "Copy the draft"
        case .accept: return "Tell Moe yes"
        case .retry: return "Ask that again"
        }
    }
}

/// This chat's model (the owner's answer 9): a menu of what the person's
/// own provider offers, read from the provider, never a list written here.
/// The choice holds for this chat only; Settings › Brain keeps the default
/// for every other.
/// "Don't remember this chat", beside the chat's name: off, a quiet eye; on,
/// a labelled capsule so it is plain the chat is not being learned from.
struct ChatForgetToggle: View {
    @ObservedObject var conductor: Conductor

    var body: some View {
        let on = conductor.chatForgets
        Button {
            conductor.setChatForgets(!on)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: 10.5, weight: .semibold))
                if on {
                    Text("Not remembered")
                        .font(Theme.Typo.ui(11.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(on ? Theme.accentDeep : Theme.ink3)
            .padding(.horizontal, on ? 8 : 0)
            .frame(minWidth: 24, minHeight: 24)
            .background(Capsule().fill(on ? Theme.sunk : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(on ? "Memoe isn't learning from this chat. Click to let it remember again."
                 : "Don't remember this chat: nothing said here is saved to memory")
        .accessibilityLabel("Don't remember this chat")
        .accessibilityValue(on ? "On" : "Off")
    }
}

struct ChatModelMenu: View {
    @ObservedObject var conductor: Conductor

    var body: some View {
        let current = conductor.chatModel ?? conductor.defaultChatModel
        Menu {
            ForEach(conductor.chatModelChoices, id: \.self) { id in
                Button {
                    conductor.setChatModel(id)
                } label: {
                    if id == current { Label(label(id), systemImage: "checkmark") } else { Text(label(id)) }
                }
            }
            if conductor.chatModel != nil {
                Divider()
                Button("Back to the default (\(conductor.defaultChatModel))") { conductor.setChatModel(nil) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(current.isEmpty ? "Model" : current)
                    .font(Theme.Typo.ui(11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
            }
            .foregroundStyle(conductor.chatModel == nil ? Theme.ink3 : Theme.accentDeep)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Theme.sunk))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(conductor.isWorking || conductor.chatModelChoices.count < 2)
        .help(conductor.chatModel == nil
              ? "The model for this chat — your default, from Settings › Brain"
              : "This chat has its own model; the rest use your default")
        .accessibilityLabel("Model for this chat: \(current)")
    }

    private func label(_ id: String) -> String {
        let caption = conductor.chatModelCaption(id)
        let name = caption.isEmpty ? id : "\(id) — \(caption)"
        return id == conductor.defaultChatModel ? name + " (default)" : name
    }
}


/// Over the box while one of your messages is being changed: what sending
/// will do, and the way out.
struct EditingBar: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "pencil")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
                .accessibilityHidden(true)
            Text("Editing your message. Sending it starts the chat again from here.")
                .font(Theme.Typo.ui(11.5))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.plain)
                .font(Theme.Typo.ui(11.5, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
        }
    }
}
