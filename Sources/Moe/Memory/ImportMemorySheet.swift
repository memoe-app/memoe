import AppKit
import MoeDesign
import SwiftUI

/// Memory › Import from ChatGPT or Claude (status #9; the owner, 2026-09-29:
/// "copy a prompt, paste the answer"; "keep it, show it under To check").
/// Two steps on one sheet: copy the question into the other assistant, paste
/// its answer here. `learn/import_memory.py` distils it with its own prompt
/// and merges it under the source `chatgpt` or `claude` — every fact marked
/// where it came from, anything that disagrees with what Moe knows asked
/// under To check, nothing the person settled themselves touched.
struct ImportMemorySheet: View {
    let done: (_ imported: Bool) -> Void

    enum From: String, CaseIterable, Identifiable {
        case chatgpt, claude
        var id: String { rawValue }
        var name: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    }

    @State private var from: From = .chatgpt
    @State private var pasted = ""
    @State private var copied = false
    @State private var working = false
    @State private var result: String?
    @State private var problem: String?

    /// The question for the other assistant. The same words as
    /// import_memory.py `PROMPT` (ImportMemoryTests holds them equal). No
    /// parentheses in it: the test's parser reads it out of the Python.
    static let prompt = "Please list everything you remember about me: your saved memories, and any details about me you have kept from our past conversations. Write it as a plain list, one fact per line, as it is stored, with a date where you have one. No commentary, no headings."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            Text("Bring in what another assistant knows about you")
                .font(Theme.Typo.display(22))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $from) {
                ForEach(From.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Text("1. Ask \(from.name) this, in a new chat:")
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
            HStack(alignment: .top, spacing: Theme.Space.small) {
                Text(Self.prompt)
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.small)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.sunk))
                PaneButton(title: copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.prompt, forType: .string)
                    copied = true
                }
            }

            Text("2. Paste its whole answer here:")
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
            TextEditor(text: $pasted)
                .font(Theme.Typo.prose(13))
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.sunk))

            Text("Each fact is kept marked as from \(from.name). Anything that disagrees with what Moe already knows is asked under To check, and nothing you told Moe yourself is changed.")
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let result {
                Text(result).font(Theme.Typo.ui(13)).foregroundStyle(Theme.ink)
            }
            if let problem {
                Text(problem).font(Theme.Typo.ui(12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                PaneButton(title: result == nil ? "Cancel" : "Done") { done(result != nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                if result == nil {
                    PaneButton(title: working ? "Reading…" : "Import", prominent: true) { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || pasted.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                }
            }
        }
        .padding(Theme.Space.generous)
        .frame(width: 560)
        .background(Theme.paper)
    }

    private func run() {
        guard let script = Self.script() else {
            problem = "Moe can't find its import step. Run the installer again."
            return
        }
        working = true
        problem = nil
        let text = pasted
        let source = from.rawValue
        Task {
            let r = await ScriptRunner.offMain {
                ScriptRunner.run(BrainSetup.python(), [script, source], stdin: text, timeout: 900)
            }
            working = false
            let answer = Self.parse(r.output)
            if r.timedOut {
                // Some of it may already be saved; never claim nothing was.
                problem = "That took too long and was stopped. Anything Moe had saved is under Memory; try again with a shorter answer."
            } else if let e = answer["error"] as? String {
                problem = e
            } else if r.status == 0 {
                result = Self.summary(answer)
            } else {
                problem = "Moe couldn't read it just now. Nothing was changed."
            }
        }
    }

    /// The JSON line import_memory.py prints (stderr is merged in).
    static func parse(_ output: String) -> [String: Any] {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                return obj
            }
        }
        return [:]
    }

    /// What happened, in the person's terms: kept, already known, waiting
    /// to be checked, left alone because they said otherwise, left out.
    static func summary(_ r: [String: Any]) -> String {
        func n(_ k: String) -> Int { (r[k] as? Int) ?? 0 }
        let added = n("added"), known = n("refreshed") + n("replaced")
        let check = max(n("questions"), n("conflicts")), skipped = n("skipped"), left = n("left_out")
        var parts: [String] = []
        if added > 0 { parts.append("\(added) new thing\(added == 1 ? "" : "s") kept.") }
        if known > 0 { parts.append("\(known) Moe already knew.") }
        if check > 0 { parts.append("\(check) disagree\(check == 1 ? "s" : "") with what Moe knows, under To check.") }
        if skipped > 0 { parts.append("\(skipped) left alone because you'd already said otherwise.") }
        if left > 0 { parts.append("\(left) left out: private details or instructions to the other assistant.") }
        return parts.isEmpty ? "Nothing to keep in it." : parts.joined(separator: " ")
    }

    static func script() -> String? {
        var candidates = [Paths.home.appendingPathComponent("learn/import_memory.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("learn/import_memory.py").path)
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }
}
