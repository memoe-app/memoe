import Foundation

/// The brain screen's three ways in that are finished in Settings › Brain —
/// a key, the free start, a model on this Mac — and how the welcome waits
/// for them instead of ending.
///
/// Until 2026-11-12 "Use a key" and "Set this up" closed the welcome for
/// good and opened Settings › Brain: a person without a subscription never
/// saw Say hello, the two permission cards, the learn screen or Connections,
/// and nothing brought them back. Now the welcome stays open, says exactly
/// what to do in the other window, watches for the choice to land, asks it
/// one question, and carries on at Say hello.
///
/// The fields stay in Settings › Brain — one copy of them, with its Test
/// button and its own verdict — rather than a second copy in here.
extension Onboarding {

    struct BrainHandoff: Equatable {
        /// Which row was pressed. It only changes the words on the card.
        enum Way: String, Equatable, CaseIterable {
            case key, free, onThisMac
        }

        enum Phase: Equatable {
            /// Settings › Brain is open; nothing has been chosen there yet.
            case waiting
            /// A choice landed and the brain is back: asking it one question.
            case checking
            /// It did not answer. The sentence is the one Settings shows.
            case problem(String)
        }

        /// What was chosen when the person left, to tell a change from none.
        struct Brain: Equatable {
            var provider: BrainProviderKind
            var model: String
            var baseURL: String
        }

        let way: Way
        private(set) var phase: Phase = .waiting
        private let before: Brain
        private var wasConnected: Bool
        /// The brain went away and came back since the person left — what a
        /// new key for the same company looks like from here.
        private var restarted = false

        init(way: Way, brain: Brain, connected: Bool) {
            self.way = way
            self.before = brain
            self.wasConnected = connected
        }

        /// Something about the brain moved. True when it is time to ask it
        /// a question: a choice was made in Settings since the person left,
        /// the brain is up, and it has something to think with.
        ///
        /// Never true for a brain that is merely still there: "Show welcome
        /// again" on a Mac that already has a key waits for a real change
        /// rather than bouncing the person straight past the screen.
        ///
        /// - Parameter usable: false only for the plan sign-in with nothing
        ///   stored — a restart there is not a choice.
        mutating func observe(_ now: Brain, connected: Bool, usable: Bool) -> Bool {
            if wasConnected, !connected { restarted = true }
            wasConnected = connected
            guard phase != .checking else { return false }
            guard now != before || restarted, connected, usable else { return false }
            phase = .checking
            restarted = false
            return true
        }

        /// The question came back. Nil — it answered: the welcome moves on.
        /// Otherwise the card says why, and the next change is checked again.
        mutating func checked(problem: String?) -> Bool {
            guard let problem else { return true }
            phase = .problem(problem)
            return false
        }

        // MARK: Words

        static let title = "Finish this in Settings › Brain"

        /// What to do in the other window, by the row that was pressed.
        /// "Change account…" and "Use …" are the pane's own button names
        /// (BrainPane, BrainAccountSheet).
        var steps: String {
            switch way {
            case .key:
                return "It's open in the other window. Press Change account…, pick the company your key is from, paste the key, and press Use."
            case .free:
                return "It's open in the other window. Get a key from aistudio.google.com with a Google account — free up to Google's daily allowance, then pennies a question. Then press Change account…, pick Google Gemini, paste the key, and press Use."
            case .onThisMac:
                return "It's open in the other window. Load a model in LM Studio or Ollama first. Then press Change account…, pick the one you use, and press Use."
            }
        }

        static let waiting = "Waiting for you there. The moment it's connected, I carry on here — nothing to restart."
        static let checking = "Connected. Asking it one question to make sure it answers…"
        static func failed(_ problem: String) -> String {
            "It didn't answer: \(problem) Fix it in Settings › Brain and I'll check again."
        }
    }

    /// A brain set up outside the plan sign-ins is already something to
    /// think with: a welcome resumed on the brain screen — closed or quit
    /// while Settings › Brain was open — shows the tick, not four rows of
    /// things already done.
    static func alreadyThinking(with provider: BrainProviderKind) -> Bool {
        switch provider.access {
        case .apiKey, .localServer: return true
        case .claudeSignIn, .codexSignIn: return false
        }
    }

    // MARK: - No plan

    /// The row for a person who pays for no AI at all. Only what is true
    /// (BrainGuide: Gemini's key is free up to Google's daily allowance; a
    /// model on this Mac is free for good) — Memoe has no free AI of its own
    /// and does not say it has.
    static let freeStartTitle = "No AI plan?"
    static let freeStartWhat = "A Google Gemini key is free up to Google's daily allowance; a model on this Mac is free for good."
    static let freeStartAction = "Start free"
    static let freeStartLink = "https://aistudio.google.com/"
}
