import MoeDictation
import SwiftUI

/// Everything dictated, newest first — a sentence pasted into the wrong
/// window is one click from being pasted into the right one.
struct DictationHistoryView: View {
    @ObservedObject var conductor: Conductor
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var entries: [DictationHistory.Entry] = []
    @State private var expanded: Set<String> = []
    @State private var confirmClear = false

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dictation history").font(.headline)
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Clear all", role: .destructive) { confirmClear = true }
                    .disabled(entries.isEmpty && search.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "Nothing dictated yet" : "No matches",
                    systemImage: "keyboard",
                    description: Text(search.isEmpty
                        ? "Each dictation is kept here, on this Mac only."
                        : "Nothing you've dictated contains \u{201C}\(search)\u{201D}."))
            } else {
                List(entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420, idealHeight: 520)
        .onAppear(perform: reload)
        .onChange(of: search) { _, _ in reload() }
        .confirmationDialog("Delete every dictation in the history?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                conductor.clearDictationHistory()
                reload()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func row(_ entry: DictationHistory.Entry) -> some View {
        let open = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.when.string(from: entry.at))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Text(entry.appName ?? "—")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                    .lineLimit(1)
                Text(open ? entry.text : entry.firstLine)
                    .font(.system(size: 12))
                    .lineLimit(open ? nil : 1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityLabel(open ? "Expanded" : "Collapsed")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }

            if open {
                HStack(spacing: 8) {
                    Text("\(entry.chars) characters\(entry.polished ? ", polished" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                    Button("Paste again") {
                        // Closing the sheet leaves Moe's own window in front,
                        // and the ⌘V would land in it. Hiding Moe hands focus
                        // back to the app that had it before, which is where
                        // the text is wanted.
                        dismiss()
                        NSApp.hide(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            conductor.pasteAgain(entry.text)
                        }
                    }
                    Button("Delete", role: .destructive) {
                        conductor.deleteDictationHistory(id: entry.id)
                        expanded.remove(entry.id)
                        reload()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        entries = conductor.dictationHistoryEntries(matching: search)
    }
}
