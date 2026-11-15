import AppKit
import MoeChat
import SwiftUI

/// The box you type into, in Chat and on the island: it grows with what you
/// write up to `maxLines`, then scrolls — with the trackpad, like any text.
///
/// Both used to be `TextField`s. A vertical one grows to its line limit and
/// then will not scroll with a trackpad or mouse at all, so a pasted email
/// could only be read by walking the caret down it with the arrow keys (the
/// owner, 2026-09-25); the island's was a single line, worse still.
/// `TextEditor` is an `NSTextView` in a scroll view and scrolls the way text
/// does everywhere else on the Mac.
///
/// Return sends; Shift-Return (or Option-Return) starts a new line, as in
/// Messages and every chat app.
struct ComposerEditor: View {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 13
    var lineHeight: CGFloat = 17
    var maxLines = 6
    var ink: Color = .primary
    var placeholderInk: Color = .secondary
    var focus: FocusState<Bool>.Binding?
    /// ⌘V with a picture or a copied file attaches it here instead of
    /// pasting its name as text; nil leaves Paste as plain text.
    var attach: (([ChatAttachment]) -> Void)? = nil
    let onSubmit: () -> Void

    @State private var paste = PasteWatch()

    /// NSTextView's own inset from the left edge of its text container.
    private let lead: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the box: the text itself, invisible, one line at least.
            Text(text.isEmpty ? " " : text + " ")
                .font(.system(size: size))
                .lineSpacing(lineHeight - size - 3)
                .padding(.leading, lead)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .accessibilityHidden(true)
            editor
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: size))
                    .foregroundStyle(placeholderInk)
                    .padding(.leading, lead)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: lineHeight, maxHeight: lineHeight * CGFloat(maxLines))
        .fixedSize(horizontal: false, vertical: true)
        .background(PasteAnchor(watch: paste))
        .onAppear { if let attach { paste.start(attach) } }
        .onDisappear { paste.stop() }
    }

    @ViewBuilder
    private var editor: some View {
        let base = TextEditor(text: $text)
            .font(.system(size: size))
            .foregroundStyle(ink)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .background(Color.clear)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                    return .ignored
                }
                onSubmit()
                return .handled
            }
        if let focus { base.focused(focus) } else { base }
    }

    /// How tall the box draws for `text`, for the island's height arithmetic.
    static func height(_ text: String, size: CGFloat = 13, lineHeight: CGFloat = 17,
                       maxLines: Int, width: Double,
                       wraps: (String, Double, Double) -> Int) -> CGFloat {
        let lines = text.isEmpty ? 1 : max(wraps(text, width - 10, Double(size)),
                                          text.components(separatedBy: "\n").count)
        return lineHeight * CGFloat(min(max(lines, 1), maxLines))
    }
}

/// ⌘V in a composer, read before the text view takes it. `TextEditor` is a
/// plain-text `NSTextView`: a pasted screenshot did nothing and a file copied
/// in Finder pasted its name (deep dive §2.12). Paste reaches the text view
/// through the Edit menu's key equivalent, which a SwiftUI key handler never
/// sees, so this watches the key itself — only in this composer's window,
/// only while the text being typed into is this composer's.
@MainActor
final class PasteWatch {
    weak var anchor: NSView?
    private var monitor: Any?

    func start(_ attach: @escaping ([ChatAttachment]) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPaste(event), self.owns(event),
                  AttachmentIntake.pasteAttaches(.general) else { return event }
            let taken = AttachmentIntake.take(from: .general)
            guard !taken.isEmpty else { return event }
            attach(taken)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// The key went to a text view that sits where this composer is drawn.
    private func owns(_ event: NSEvent) -> Bool {
        guard let anchor, let window = anchor.window, event.window === window,
              let typing = window.firstResponder as? NSTextView else { return false }
        let mine = anchor.convert(anchor.bounds, to: nil)
        let theirs = typing.enclosingScrollView.map { $0.convert($0.bounds, to: nil) }
            ?? typing.convert(typing.visibleRect, to: nil)
        return mine.intersects(theirs)
    }
}

/// An empty view behind the composer that tells `PasteWatch` where it is.
private struct PasteAnchor: NSViewRepresentable {
    let watch: PasteWatch
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        watch.anchor = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { watch.anchor = nsView }
}

/// A ⌘-key for one window: the key goes to whatever has focus there (a text
/// view, usually), which never passes on a ⌘-key it has no use for, so a
/// SwiftUI key handler above it never hears it. This hears it first, only
/// when it was pressed in the window `KeyWatchAnchor` sits in.
@MainActor
final class KeyWatch {
    weak var anchor: NSView?
    private var monitor: Any?

    func start(key: String, _ action: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.anchor?.window, event.window === window,
                  KeyWatch.matches(event, key: key) else { return event }
            action()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func matches(_ event: NSEvent, key: String) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == key
    }
}

struct KeyWatchAnchor: NSViewRepresentable {
    let watch: KeyWatch
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        watch.anchor = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { watch.anchor = nsView }
}
