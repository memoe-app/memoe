import Foundation
import MoeDesign
import MoeIsland

/// The bar a notice has to clear to become a card (docs/INBOX-QUIET.md,
/// decision 1 and slice 2): **every card carries a do-it.** If Moe cannot
/// offer to act, it stays quiet.
///
/// The week that doc measured had 97 cards, 18% of which offered anything.
/// `Conductor.receiveNotice` dropped silence, job failures and repeats, and
/// then inserted whatever was left, so a sentence with nothing behind it was
/// a card with one button: Got it.
///
/// The decision is made on what the notice *carries*, never on its words: a
/// regular expression over a sentence is how the first machinery filter was
/// walked past by a prefix. A notice clears the bar when it has something a
/// tap does, or when the person is the reason it exists.
///
/// A notice that fails is not thrown away. It is kept under Done in the
/// Inbox page for the usual week, marked "Kept quiet", with no glow and no
/// line under the notch, and the log says why. Nothing the person might go
/// looking for is destroyed by this file.
enum InboxGate {

    /// What the app knows about where a notice came from that the notice's
    /// own fields do not say.
    struct Origin: Equatable {
        /// The inbox file's `source`: who wrote it (`reach_owner`, `confirm`,
        /// `cron`, a job's name). Empty for the app's own notices.
        var writer = ""
        /// The writer flagged it `time_critical`: a scam in progress, a
        /// booking cancelled for tomorrow. The one way a pure FYI gets in.
        var timeCritical = false
        /// A moment (decision 7): meeting soon, a missed call, "X messaged
        /// you". Owed to the island as a glow that clears itself; until that
        /// exists it is still shown, because a heads-up nobody sees is worse
        /// than a card.
        var moment = false
        /// Something of theirs did not happen and they may be counting on
        /// it: a send held for their yes expired unanswered, so nothing was
        /// sent. Said once, by the app, when the held card is retired.
        var consequence = false
    }

    /// Why a notice is a card.
    enum Pass: String, Equatable {
        /// An offer: the work is prepared and one tap sends it.
        case preparedWork
        /// The writer gave answers to tap.
        case answers
        /// A send held for a yes.
        case heldSend
        /// A finished job of theirs: Open it.
        case openIt
        /// A carry-over to their cloud computer: Show me.
        case showMe
        /// A follow-up Moe is keeping: Done closes it, Snooze moves it.
        case followUp
        /// Their own reminder or routine. They asked for it.
        case askedFor
        /// The brain reached for them on purpose (`reach_owner`), here or
        /// from their cloud computer while this Mac was shut.
        case reachedFor
        /// The scheduler delivered it and named no job (`deliver: moe` from
        /// a cron process outside the gateway, `hermes send --to moe`). It
        /// may be their own reminder, and the app cannot tell: shown.
        case unattributed
        case timeCritical
        case moment
        case consequence
    }

    /// Why a notice stays quiet.
    enum Quiet: String, Equatable {
        /// Moe talking about Moe: its own job's report, a withdrawn send.
        case moeAboutMoe
        /// Nothing to tap, and nobody asked for it.
        case nothingToTap

        var logged: String {
            switch self {
            case .moeAboutMoe: return "Moe talking about itself"
            case .nothingToTap: return "nothing to tap and nobody asked for it"
            }
        }
    }

    enum Verdict: Equatable {
        case card(Pass)
        case quiet(Quiet)
    }

    /// What finished a notice that was kept quiet, as the Done list says it.
    static let outcome = "Kept quiet"

    /// The brain's own tool for putting words in front of the person
    /// (moe-screen `reach.py`): its answer to the brain is "it is on the
    /// island", so it has to be. And `away`: what their cloud computer held
    /// for this Mac (`moe-drain-intents`), which was promised "held, never
    /// dropped". Either counts only with no job behind it; a job's own
    /// report is judged as that job's.
    static let reachWriters: Set<String> = ["reach_owner", "away"]
    /// The scheduler's own name for itself in an inbox file.
    static let schedulerWriter = "cron"
    /// The background pass: everything it says is a follow-up the ledger
    /// knows, by its slug or, when it named none, by its words (four of the
    /// seven Miriam raises of 2026-09-30 carried no slug). Done closes it.
    static let followUpJobs: Set<String> = ["moe-proactive"]
    /// The calendar heads-up is a moment by its job, whoever delivered it.
    static let momentJobs: Set<String> = ["moe-calendar-heads-up"]

    static func decide(_ m: NoticeInput, origin: Origin = Origin()) -> Verdict {
        // A send that expired or was withdrawn is Moe reporting on its own
        // card, whatever else the file says (the doc's "withdrawn sends").
        if origin.writer == ConfirmLifecycle.noteSource || m.source == ConfirmLifecycle.noteSource {
            return .quiet(.moeAboutMoe)
        }
        // Something a tap does.
        if !m.offer.isEmpty { return .card(.preparedWork) }
        if !m.options.isEmpty { return .card(.answers) }
        if !m.expiredText.isEmpty { return .card(.heldSend) }
        if !m.openThread.isEmpty { return .card(.openIt) }
        if !m.awayCarry.isEmpty { return .card(.showMe) }
        // Not `instruction`: that is a note for the brain about what was
        // said, and the weekly digest ("I learned 22 things about you")
        // carries one. It tells Moe what to do if answered; it gives the
        // person nothing to tap.
        let job = m.job.trimmingCharacters(in: .whitespaces)
        if m.loops.contains(where: { !$0.isEmpty }) || followUpJobs.contains(job.lowercased()) {
            return .card(.followUp)
        }
        // The person is the reason it exists, or may be: quiet is only for
        // what is known to be Moe's own. A reminder that was asked for and
        // never shown is the worse mistake.
        let moes = NoticeMaker.isMoeJob(job)
        if !moes, !job.isEmpty || !m.jobID.isEmpty { return .card(.askedFor) }
        if job.isEmpty, reachWriters.contains(origin.writer) { return .card(.reachedFor) }
        if job.isEmpty, origin.writer == schedulerWriter { return .card(.unattributed) }
        // The exceptions.
        if origin.timeCritical { return .card(.timeCritical) }
        if origin.moment || momentJobs.contains(job.lowercased()) { return .card(.moment) }
        if origin.consequence { return .card(.consequence) }
        return .quiet(moes ? .moeAboutMoe : .nothingToTap)
    }

    /// The notice as it is kept when it fails the bar: finished, read, and
    /// findable under Done. Nil when the same words are already there, so a
    /// job that says one thing every five minutes leaves one row, not 300.
    static func kept(_ m: NoticeInput, among notices: [InboxItem], now: Date = Date()) -> InboxItem? {
        guard !notices.contains(where: { $0.body == m.text && $0.outcome == outcome }) else { return nil }
        var n = NoticeMaker.make(m)
        n.status = .done
        n.doneAt = now
        n.outcome = outcome
        n.seen = true
        return n
    }
}
