import AppKit
import MoeBrain
import MoeLedger
import SwiftUI

// The app's one door to Memoe's cloud.
//
// This repository's open half is the local-only Mac app. Everything that
// talks to our cloud — the account and sign-in, the sync, Away and its
// hand-off, the plan, tickets and problem reports, the usage beacon, the
// cloud-minted voice — is closed, lives outside `Sources/`, and is compiled
// in only by the official build (`MOE_CLOUD`). It reaches the app through the
// protocol below and nothing else, and it plugs itself in once, at launch,
// from `Cloud.install()`.
//
// A build without it gets `LocalOnly`: every hook does nothing, every page
// and row that only means something with an account is not drawn, and the
// plan is "free". Nothing is hidden behind a switch a person could find; it
// is simply not in the program.

/// What the screens show of the cloud's state, pushed by the closed half.
struct CloudSnapshot: Equatable {
    /// The plan as the gate honours it ("free", "away", "away_plus").
    var tier: String?
    /// This Mac holds an account credential.
    var enrolled = false
    /// A copy of what Moe knows is being kept in the cloud.
    var syncing = false
}

/// What became of keeping the away machine's brain in step with this Mac's.
struct BrainFollowed {
    let note: AwayBrainFollowNote?
    let step: AwayBrainFollow.Step
    /// The row the away brain sheet opens on when the note has a button.
    let sheetStart: String
}

/// The problem-report switch (onboarding and Settings › Privacy): the words
/// and the one call that turns it, which records the yes with the Moe team.
@MainActor
protocol ProblemReportsLink {
    func isOn() -> Bool
    var disclosure: String { get }
    var disclosureLabel: String { get }
    var anonymousTitle: String { get }
    var anonymousDetail: String { get }
    func anonymousBinding(_ conductor: Conductor, posed: Bool) -> Binding<Bool>
    /// Turn reports on or off; what the switch ends up as, and why not.
    func turn(_ on: Bool, conductor: Conductor) async -> (on: Bool, problem: String?)
}

/// The closed half, seen from the open one. Every member has a do-nothing
/// default, which is the whole of a build without a cloud.
@MainActor
protocol CloudLink: AnyObject {
    // MARK: The conductor's life
    /// Once, as the conductor is built: wire the brain's task hooks and
    /// anything else that needs the conductor itself.
    func attach(_ conductor: Conductor)
    /// After the conductor has started everything of its own.
    func launched()
    /// The app is quitting; bounded, never hangs.
    func quitting()

    // MARK: Presence (lock, sleep, wake)
    func presenceStarted()
    /// Synchronously, inside the sleep notification, before the local file.
    func macWillSleep()
    func macDidWake()
    /// After the local presence has been written for `event`. For
    /// `.willSleep` this waits, briefly, for the cloud to hear it.
    func presence(_ event: PresenceEvent)
    /// Once a minute while the app runs.
    func stillHere(asleep: Bool)

    // MARK: The open ask (docs/AWAY-HANDOFF.md)
    func task(_ report: BrainTaskReport)
    func taskClaim(_ task: String, done: @escaping (Bool) -> Void)
    /// A turn left by a quit: may this Mac answer it, or did the cloud?
    func mayResume(task: String, thread: String, _ done: @escaping (Bool) -> Void)

    // MARK: The ledger
    func ledgerSaved()
    func threadDeleted(_ id: String)

    // MARK: Everything else the conductor reports
    func brainChanged(_ why: String)
    func spokenTurnAnswered()
    /// A turn a person started, spoken or typed, got a real answer.
    func personTurnAnswered()
    /// A card for the island about carrying a connection to the cloud.
    func carryReminderDue(now: Date) -> (id: String, text: String)?
    func carryReminderAnswered(_ id: String, never: Bool)
    /// Open the checkout for a pack (`voice`, `hours`) a card's button names.
    func buyPack(_ pack: String)
    /// A `moe://` link the app was opened with; true when it was the cloud's.
    func open(_ url: URL, conductor: Conductor) -> Bool

    // MARK: Screens
    /// Settings › Away; nil leaves the page out of the sidebar.
    func awayPage(_ conductor: Conductor) -> AnyView?
    func awaySidebarLabel(tier: String?) -> String
    /// Settings › Privacy with the account's rows; nil draws the local page.
    func privacyPage(_ conductor: Conductor) -> AnyView?
    func awayBrainSheet(onDone: @escaping (String?) -> Void, startOn: String,
                        provider: BrainProviderKind, model: String) -> AnyView
    /// Extra panel under a connection's detail (Telegram › Confirm it's you).
    func connectionPanel(for connection: Connection) -> AnyView?
    /// The line under every Google sign-in button.
    func signInTermsLine() -> AnyView?
    /// What Connections needs to sign a person in for a brokered service.
    func wireConnect(_ flow: ConnectFlow, conductor: Conductor)
    /// `--settings-snapshot`: the closed pages, in every state.
    func settingsShots(_ conductor: Conductor, paneWidth: CGFloat) -> [(name: String, size: CGSize, view: AnyView)]
    /// Memory › the line about the cloud copy.
    func keepsACopy() async -> Bool
    var problemReports: ProblemReportsLink? { get }

    // MARK: Erasing this Mac (Settings › Privacy)
    func accountSignedIn() async -> Bool
    /// Prove it is the account (and delete it first when asked).
    func proveForErase(deleteAccount: Bool) async throws
    /// A sentence for an error from `proveForErase`, when it is the cloud's.
    func eraseFailure(_ error: Error) -> String?
}

extension CloudLink {
    func attach(_ conductor: Conductor) {}
    func buyPack(_ pack: String) {}
    func launched() {}
    func quitting() {}
    func presenceStarted() {}
    func macWillSleep() {}
    func macDidWake() {}
    func presence(_ event: PresenceEvent) {}
    func stillHere(asleep: Bool) {}
    func task(_ report: BrainTaskReport) {}
    func taskClaim(_ task: String, done: @escaping (Bool) -> Void) { done(true) }
    func mayResume(task: String, thread: String, _ done: @escaping (Bool) -> Void) { done(true) }
    func ledgerSaved() {}
    func threadDeleted(_ id: String) {}
    func brainChanged(_ why: String) {}
    func spokenTurnAnswered() {}
    func personTurnAnswered() {}
    func carryReminderDue(now: Date) -> (id: String, text: String)? { nil }
    func carryReminderAnswered(_ id: String, never: Bool) {}
    func open(_ url: URL, conductor: Conductor) -> Bool { false }
    func awayPage(_ conductor: Conductor) -> AnyView? { nil }
    func awaySidebarLabel(tier: String?) -> String { "Away" }
    func privacyPage(_ conductor: Conductor) -> AnyView? { nil }
    func awayBrainSheet(onDone: @escaping (String?) -> Void, startOn: String,
                        provider: BrainProviderKind, model: String) -> AnyView { AnyView(EmptyView()) }
    func connectionPanel(for connection: Connection) -> AnyView? { nil }
    func signInTermsLine() -> AnyView? { nil }
    func wireConnect(_ flow: ConnectFlow, conductor: Conductor) {}
    func settingsShots(_ conductor: Conductor, paneWidth: CGFloat) -> [(name: String, size: CGSize, view: AnyView)] { [] }
    func keepsACopy() async -> Bool { false }
    var problemReports: ProblemReportsLink? { nil }
    func accountSignedIn() async -> Bool { false }
    func proveForErase(deleteAccount: Bool) async throws {}
    func eraseFailure(_ error: Error) -> String? { nil }
}

/// A build with no cloud.
@MainActor
final class LocalOnly: CloudLink {}

/// The plan this Mac is on, off disk and with no network, as the closed half
/// reads it. Nonisolated: the voice, the CLI and Connections' JSON dump ask
/// from any thread. "free" in a build without a cloud.
protocol PlanReader: Sendable {
    /// The plan the gate honours now.
    func honoured() -> String
    /// The cached plan, if one has been read at all.
    func cached() -> String?
    func isPaid(_ tier: String) -> Bool
    /// The line at the top of Connections (`reach`: the Reach tab).
    func connectionsBlurb(reach: Bool, tier: String) -> String
}

enum Cloud {
    /// The closed half once `install()` has run, else `LocalOnly`.
    @MainActor static var link: CloudLink = LocalOnly()
    /// True when the closed half is installed and has an edge to talk to.
    /// Set once by `install()`, before anything reads it. (An official tree
    /// built with no edge address has the closed half and no edge: its pages
    /// exist, as they always did, and Away is not listed.)
    static var isPresent: Bool { isInstalled && Config.load().hasCloud }
    /// The closed half is compiled in and registered (`install()`).
    nonisolated(unsafe) private(set) static var isInstalled = false

    nonisolated(unsafe) static var plan: (any PlanReader)?

    /// The closed half's command-line verbs (`Moe --cloud-…`, `--away-…`).
    /// Returns only when `args` is not one of them.
    nonisolated(unsafe) static var commandLine: ([String]) -> Void = { _ in }

    /// Keep the away machine's brain in step with this Mac's. Blocking;
    /// off the main thread. Nil without a cloud: there is no away machine.
    nonisolated(unsafe) static var followBrain: (@Sendable (AwayBrainFollow.Here, String) -> BrainFollowed)?

    /// Once, first thing in `main.swift`. The official build compiles its
    /// closed half in and registers it here; any other build has nothing to
    /// register, and this does nothing.
    static func install() {
        #if MOE_CLOUD
        CloudEdition.install()
        isInstalled = MainActor.assumeIsolated { !(link is LocalOnly) }
        #endif
    }
}

extension Cloud {
    static func honouredTier() -> String { plan?.honoured() ?? "free" }
    static func isPaid(_ tier: String?) -> Bool { tier.map { plan?.isPaid($0) ?? false } ?? false }

    /// The line at the top of Connections. Without a cloud, Moe lives on
    /// this Mac and nowhere else.
    static func connectionsBlurb(reach: Bool, tier: String) -> String {
        if let plan { return plan.connectionsBlurb(reach: reach, tier: tier) }
        return reach
            ? "Moe lives on this Mac. Message it from anywhere below and it answers while the Mac is awake — asleep, your message waits."
            : "Moe lives on this Mac. Everything below works while the Mac is awake — asleep, Moe is asleep too."
    }
}
