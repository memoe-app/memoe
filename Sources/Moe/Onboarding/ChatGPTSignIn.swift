import AppKit
import MoeDesign
import SwiftUI

/// Signing Moe's brain in to ChatGPT, inside Moe.
///
/// This used to open Terminal (`hermes-codex-signin.sh`): the only way to
/// see the code OpenAI's device sign-in shows was a terminal window, and a
/// person who picked "Sign in with ChatGPT" landed in a black box full of
/// text (owner, 2026-09-10: "There shouldn't be any terminals. It should go
/// straight to the web."). Nothing about the flow needs a terminal —
/// `hermes auth add openai-codex` asks for no input; it prints a page and a
/// code, then waits for the approval. So Moe runs it with pipes, shows the
/// code and the link itself, opens the page, and copies the code so the
/// person only has to paste.
///
/// Hermes does the sign-in and keeps the credential (`~/.hermes/auth.json`),
/// exactly as before: this changes where the code is shown, not who holds
/// the token.
@MainActor
final class ChatGPTSignInFlow: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case approving(url: URL, code: String)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// True once the code has been put on the clipboard for the person.
    @Published private(set) var codeCopied = false

    var onStored: (() -> Void)?

    /// What a failed sign-in says. The system's own error text and the
    /// sign-in tool's last line go to the log.
    nonisolated static let couldNotStart = "I couldn't start the sign-in. Quit Memoe, open it again and try once more."
    nonisolated static let didNotFinish = "The sign-in didn't finish. Try again — and approve it in the browser page that opens."
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var rehearsal = false

    private var handle = ChatGPTSignIn.Handle()
    private var generation = 0

    /// OpenAI's own device-code limit is fifteen minutes.
    static let timeout: TimeInterval = 16 * 60

    func begin() {
        if case .starting = phase { return }
        if case .approving = phase { return }
        generation += 1
        let gen = generation
        codeCopied = false
        phase = .starting
        if rehearsal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.show(url: URL(string: "https://auth.openai.com/codex/device")!, code: "ABCD-12345", open: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, gen == self.generation, case .approving = self.phase else { return }
                self.phase = .done
            }
            return
        }
        let weakSelf = FlowRef(self)
        let h = ChatGPTSignIn.Handle()
        handle = h
        Task.detached(priority: .userInitiated) {
            let result = ChatGPTSignIn.run(handle: h, prompt: { url, code in
                Task { @MainActor in
                    guard let s = weakSelf.value, gen == s.generation else { return }
                    s.show(url: url, code: code, open: true)
                }
            })
            await MainActor.run {
                guard let s = weakSelf.value, gen == s.generation else { return }
                switch result {
                case .success:
                    s.phase = .done
                    s.onStored?()
                case .failure(let message):
                    s.phase = .failed(message)
                }
            }
        }
    }

    private func show(url: URL, code: String, open: Bool) {
        phase = .approving(url: url, code: code)
        copy(code)
        codeCopied = true
        if open { openURL(url) }
    }

    func cancel() {
        generation += 1
        handle.cancel()
        phase = .idle
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class FlowRef: @unchecked Sendable {
    weak var value: ChatGPTSignInFlow?
    init(_ v: ChatGPTSignInFlow) { value = v }
}

enum ChatGPTSignIn {
    enum Outcome: Sendable { case success, failure(String) }

    /// The running sign-in, so Cancel can stop it from the main thread.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func attach(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { p.terminate(); return false }
            process = p
            return true
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            process?.terminate()
        }
    }

    /// Runs `hermes auth add openai-codex` with pipes. Blocking; call it off
    /// the main thread. `prompt` is called once, with the page and the code.
    static func run(handle: Handle, prompt: @escaping @Sendable (URL, String) -> Void) -> Outcome {
        let hermes = Paths.hermesBinary()
        guard Paths.isLaunchable(hermes) else {
            return .failure("The part of Moe that thinks isn't set up on this Mac yet. Give it a moment after opening Moe, or use Settings › Brain › Set it up, then try again.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hermes)
        p.arguments = ["auth", "add", "openai-codex"]
        var env = ProcessInfo.processInfo.environment
        // Piped, Python holds its prints until exit — the code would arrive
        // after the sign-in it is needed for.
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        // The supervisor's rules for the same credential: Hermes keeps its
        // own ChatGPT sign-in and never adopts the Codex CLI's.
        env["HERMES_CODEX_CLI_CREDENTIALS"] = "0"
        env["NO_PROXY"] = "*"
        env["no_proxy"] = "*"
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "CODEX_HOME")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        let parser = Parser()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            if let found = parser.feedOnce(String(decoding: data, as: UTF8.self)) {
                prompt(found.url, found.code)
            }
        }
        do { try p.run() } catch {
            Log.write("chatgpt sign-in: could not start: \(error)")
            return .failure(ChatGPTSignInFlow.couldNotStart)
        }
        guard handle.attach(p) else { p.waitUntilExit(); return .failure("Cancelled.") }
        let deadline = Date().addingTimeInterval(ChatGPTSignInFlow.timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            return .failure("The code expired before it was approved. Try again — it takes a minute.")
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        let last = parser.last
        if p.terminationReason == .uncaughtSignal { return .failure("Cancelled.") }
        if p.terminationStatus == 0 {
            Log.write("chatgpt sign-in: stored by hermes")
            return .success
        }
        Log.write("chatgpt sign-in: hermes exited \(p.terminationStatus): \(last)")
        // What it printed last is in the log line above; the person gets
        // a sentence they can act on.
        return .failure(ChatGPTSignInFlow.didNotFinish)
    }

    /// Reads Hermes's prompt out of its output — measured from
    /// `hermes_cli/auth.py` `_codex_device_code_login`:
    ///
    ///       1. Open this URL in your browser:
    ///          https://auth.openai.com/codex/device
    ///       2. Enter this code:
    ///          ABCD-EFGH
    final class Parser: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var url: URL?
        private var expectCode = false
        private var prompted = false
        private(set) var lastLine = ""

        var last: String { lock.lock(); defer { lock.unlock() }; return lastLine }

        /// The prompt, the first time it is complete; nil every other time.
        func feedOnce(_ chunk: String) -> (url: URL, code: String)? {
            lock.lock(); defer { lock.unlock() }
            guard let found = feed(chunk), !prompted else { return nil }
            prompted = true
            return found
        }

        func feed(_ chunk: String) -> (url: URL, code: String)? {
            buffer += chunk
            var result: (URL, String)?
            while let nl = buffer.firstIndex(of: "\n") {
                let raw = String(buffer[..<nl])
                buffer.removeSubrange(...nl)
                let line = Self.plain(raw)
                guard !line.isEmpty else { continue }
                lastLine = line
                if url == nil, let r = line.range(of: #"https://auth\.openai\.com/\S+"#, options: .regularExpression) {
                    url = URL(string: String(line[r]))
                    continue
                }
                if line.lowercased().contains("enter this code") { expectCode = true; continue }
                if expectCode, let u = url {
                    expectCode = false
                    result = (u, line)
                }
            }
            return result.map { (url: $0.0, code: $0.1) }
        }

        static func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - The sheet

struct ChatGPTSignInSheet: View {
    @ObservedObject var flow: ChatGPTSignInFlow
    var onClose: (_ signedIn: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text(title)
                .font(Theme.Typo.heading(24))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if case .approving(let url, let code) = flow.phase {
                HStack(spacing: Theme.Space.base) {
                    Text(code)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                    PaneButton(title: flow.codeCopied ? "Copied" : "Copy code", symbol: "doc.on.doc") {
                        flow.copy(code)
                    }
                }
                .padding(.vertical, Theme.Space.small)
                SignInLinkBlock(url: url, open: { flow.openURL(url) })
            }
            HStack(spacing: Theme.Space.cosy) {
                if flow.phase == .starting { ProgressView().controlSize(.small) }
                if case .approving = flow.phase { ProgressView().controlSize(.small) }
                Spacer()
                buttons
            }
            .padding(.top, Theme.Space.small)
        }
        .padding(Theme.Space.section)
        .frame(width: 440)
        .background(Theme.raised)
        .onAppear { if flow.phase == .idle { flow.begin() } }
    }

    private var title: String {
        switch flow.phase {
        case .idle, .starting, .approving: return "Sign in with ChatGPT"
        case .done:                        return "Done"
        case .failed:                      return "That didn't work"
        }
    }

    private var subtitle: String {
        switch flow.phase {
        case .idle, .starting: return "Getting a code from OpenAI…"
        case .approving:
            return "A ChatGPT page opened in your browser. Sign in there and enter this code — it's already copied, so just paste it."
        case .done:            return "Signed in. Moe is getting ready to think."
        case .failed(let m):   return m
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch flow.phase {
        case .idle, .starting, .approving:
            quiet("Cancel") { flow.cancel(); onClose(false) }.keyboardShortcut(.cancelAction)
        case .done:
            PillButton(title: "Done") { flow.cancel(); onClose(true) }.keyboardShortcut(.defaultAction)
        case .failed:
            quiet("Not now") { flow.cancel(); onClose(false) }.keyboardShortcut(.cancelAction)
            PillButton(title: "Try again") { flow.begin() }.keyboardShortcut(.defaultAction)
        }
    }

    private func quiet(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Typo.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        }
        .buttonStyle(.plain)
    }
}

/// "The page didn't open?" — the link itself, selectable, with Copy and Open
/// again. Shared by the Claude and ChatGPT sign-ins: a browser that did not
/// come forward, or a person who wants the page in a different browser,
/// must never be left with nothing to paste.
struct SignInLinkBlock: View {
    let url: URL
    let open: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Page didn't open? Copy this link into your browser:")
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
            Text(url.absoluteString)
                .font(Theme.Typo.ui(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: Theme.Space.base) {
                PaneLink(title: copied ? "Copied" : "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                }
                PaneLink(title: "Open the page again", action: open)
            }
        }
    }
}
