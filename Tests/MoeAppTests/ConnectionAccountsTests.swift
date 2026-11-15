import AppKit
import Foundation
import MoeScreen
import SwiftUI
import Testing
@testable import Moe

/// The Connections detail side, after the owner's report of 2026-11-12: it
/// was cut off at the top and the bottom and did not scroll, one account of
/// several could not be removed, and the Connect button's press was judged
/// against its whole window. Invented rows throughout (`ConnectionsPose`);
/// nothing here launches a script or reads this Mac's connections.

@MainActor
private func gmail(_ pose: String) -> Connection {
    ConnectionsPose.rows(pose).first { $0.id == "composio/gmail" }!
}

@MainActor
private func detail(_ c: Connection, needsAccount: Bool = false,
                    pressed: @escaping (HumanPressPlace) -> Void = { _ in },
                    action: @escaping () -> Void = {}) -> ConnectionDetail {
    ConnectionDetail(connection: c, checkedAt: Date(), action: action, disconnect: {},
                     pressed: pressed, needsAccount: needsAccount)
}

// MARK: - It fits

@MainActor
struct ConnectionDetailFitsTests {
    /// The measurement behind the fix. The detail used to be one stack with
    /// no scroll view, so its least height was everything in it — 9 accounts
    /// made it over a thousand points tall, and a window shorter than that
    /// drew it centred with both ends cut off. Now the page scrolls, so the
    /// least height is the bar's and does not move with what the page holds.
    @Test func theLeastHeightDoesNotGrowWithTheAccounts() {
        _ = NSApplication.shared
        // 320: the detail side's width at the window's smallest (820 wide).
        let one = SettingsSnapshot.minimumSize(of: detail(gmail("gmail-one")), width: 320).height
        let three = SettingsSnapshot.minimumSize(of: detail(gmail(ConnectionsPose.gmailThree)), width: 320).height
        let many = SettingsSnapshot.minimumSize(of: detail(gmail("gmail-many")), width: 320).height
        #expect(one > 0)
        #expect(three == one, "three accounts need \(three), one needs \(one)")
        #expect(many == one, "nine long addresses need \(many), one needs \(one)")
    }

    /// Every pose, at the narrowest and at a wide pane: under the height the
    /// window's smallest size leaves a pane (560, less 12 of inset).
    @Test func everyPoseFitsThePaneAtTheWindowsSmallest() {
        _ = NSApplication.shared
        for pose in ConnectionsPose.all {
            let c = gmail(pose.name)
            for width in [CGFloat(320), 700] {
                for needsAccount in [false, true] {
                    let least = SettingsSnapshot.minimumSize(of: detail(c, needsAccount: needsAccount), width: width)
                    #expect(least.height <= 548, "\(pose.name) at \(width) needs \(least.height)")
                    #expect(least.height < 200, "\(pose.name) at \(width): the bar alone should not need \(least.height)")
                }
            }
        }
    }

    /// The bar folds rather than running off the side: at 320 the detail must
    /// not ask for more width than it is given. (PaneButton never wraps or
    /// truncates its title, so three in one row need about 350.)
    @Test func theBarDoesNotAskForMoreWidthThanThePane() {
        _ = NSApplication.shared
        for pose in ConnectionsPose.all {
            let least = NSHostingController(rootView: detail(gmail(pose.name)))
                .sizeThatFits(in: CGSize(width: 0, height: 548))
            #expect(least.width > 0 && least.width <= 320, "\(pose.name) needs \(least.width) across")
        }
    }
}

// MARK: - One account of several

@MainActor
private func flowRecording(status: Int32 = 0, output: String = "") -> (ConnectFlow, LaunchRecorder) {
    let flow = ConnectFlow()
    let recorder = LaunchRecorder()
    flow.locateScript = { "/nonexistent/moe-app-tests/\($0)" }
    flow.launchScript = { script, args, _, _, _, _, _, _ in
        recorder.record([script] + args)
        return ScriptRunner.Result(status: status, output: output, timedOut: false)
    }
    flow.checkConnected = { _ in false }
    return (flow, recorder)
}

@MainActor
private func until(_ seconds: TimeInterval = 60, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
struct RemoveOneAccountTests {
    @Test func theConfirmationNamesTheAddressAndSaysTheOthersStay() {
        let c = gmail(ConnectionsPose.gmailThree)
        let ask = AccountRemoval(connection: c, account: c.accounts[1])
        #expect(ask.title == "Remove ada.lovelace@work.example.com from Gmail?")
        #expect(ask.message.contains("other 2 Gmail accounts stay connected"), "\(ask.message)")
        let two = gmail("gmail-unnamed")
        let second = AccountRemoval(connection: two, account: two.accounts[1])
        #expect(second.title == "Remove Account 2 from Gmail?")
        #expect(second.message.contains("other Gmail account stays connected"), "\(second.message)")
    }

    /// The whole point: one id goes to the script, and it is the id of the
    /// row that was pressed — never the bare service, which removes them all.
    @Test func removingOneAccountAsksTheScriptForThatIdOnly() async {
        let c = gmail(ConnectionsPose.gmailThree)
        let (flow, launches) = flowRecording(output: "disconnected gmail (1 account)\n")
        flow.removeAccount(c, c.accounts[1])
        #expect(flow.presented)
        #expect(flow.removing)
        #expect(flow.phase == .working("Removing ada.lovelace@work.example.com…"))
        #expect(await until { if case .done = flow.phase { return true }; return false }, "\(flow.phase)")
        #expect(launches.calls == [["/nonexistent/moe-app-tests/connect.sh", "--remove", "composio/gmail", "ca_pose_2"]])
        #expect(flow.phase == .done("ada.lovelace@work.example.com is removed. The others stay connected."))
        // What makes the list and the "N accounts" line read again when the
        // sheet closes (`ConnectionsView`'s onDismiss reloads on `changed`).
        #expect(flow.changed)
    }

    /// `connect.sh --remove composio/gmail ""` is `--remove composio/gmail`:
    /// every account. An account with no id is refused before anything runs.
    @Test func anAccountWithNoIdLaunchesNothing() async {
        var c = gmail(ConnectionsPose.gmailThree)
        let blank = Connection.Account(id: " ", who: "nobody@example.com", status: "ACTIVE")
        c.accounts.append(blank)
        #expect(AccountRemoval.arguments(c, blank) == nil)
        let (flow, launches) = flowRecording()
        flow.removeAccount(c, blank)
        guard case .failed(let text) = flow.phase else { Issue.record("went to \(flow.phase)"); return }
        #expect(text.contains("nothing was removed"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(launches.calls.isEmpty, "\(launches.calls)")
    }

    /// An account that is not this row's is not removed from this row.
    @Test func anAccountOfAnotherRowIsRefused() {
        let c = gmail(ConnectionsPose.gmailThree)
        let stranger = Connection.Account(id: "ca_elsewhere", who: "x@example.com", status: "ACTIVE")
        #expect(AccountRemoval.arguments(c, stranger) == nil)
        #expect(AccountRemoval.arguments(c, c.accounts[0]) == ["--remove", "composio/gmail", "ca_pose_1"])
    }

    /// The last one is the whole connection: the screen sends it down
    /// Disconnect…'s road instead (`beginRemoveAccount`).
    @Test func theLastAccountIsDisconnectsQuestion() {
        let one = gmail("gmail-one")
        #expect(AccountRemoval.isLast(one, one.accounts[0]))
        let three = gmail(ConnectionsPose.gmailThree)
        #expect(!three.accounts.contains { AccountRemoval.isLast(three, $0) })
        // One live beside a dead one: the dead one is not on screen, so the
        // live one is the last a person can see.
        var mixed = one
        mixed.accounts.append(Connection.Account(id: "ca_dead", who: "", status: "EXPIRED"))
        #expect(mixed.shownAccounts.map(\.id) == ["ca_pose_1"])
        #expect(AccountRemoval.isLast(mixed, mixed.accounts[0]))
        // Nothing live: both dead ones show, and neither is the last.
        let expired = gmail("gmail-expired")
        #expect(expired.shownAccounts.count == 2)
        #expect(!AccountRemoval.isLast(expired, expired.accounts[0]))
    }

    /// The Disconnect… chooser goes the same road, by label.
    @Test func theChooserRemovesTheAccountItNamed() async {
        let c = gmail(ConnectionsPose.gmailThree)
        let (flow, launches) = flowRecording()
        flow.remove(c)
        #expect(flow.phase == .chooseMailbox(["ada@example.com", "ada.lovelace@work.example.com", "family@example.com"]))
        flow.removeChosen("family@example.com")
        #expect(await until { if case .done = flow.phase { return true }; return false }, "\(flow.phase)")
        #expect(launches.calls == [["/nonexistent/moe-app-tests/connect.sh", "--remove", "composio/gmail", "ca_pose_3"]])
    }

    /// A removal that failed says the script's own sentence, and none of the
    /// advice written for a sign-in that failed.
    @Test func aFailedRemovalDoesNotGiveSignInAdvice() async {
        let c = gmail(ConnectionsPose.gmailThree)
        let (flow, _) = flowRecording(status: 1, output: "couldn't remove your gmail account at Composio just now (no answer) — nothing was disconnected; try again\n")
        flow.removeAccount(c, c.accounts[0])
        #expect(await until { if case .failed = flow.phase { return true }; return false }, "\(flow.phase)")
        guard case .failed(let text) = flow.phase else { return }
        #expect(text.contains("nothing was disconnected"), "\(text)")
        #expect(!flow.nextStep.contains("page can time out"), "\(flow.nextStep)")
        // And the next connect is a connect again.
        flow.cancel()
        flow.start(c)
        #expect(!flow.removing)
        #expect(flow.nextStep.contains("page can time out"), "\(flow.nextStep)")
        flow.cancel()
    }
}

// MARK: - The Connect press (D9.14)

/// Every view of `type` under `root`.
@MainActor
private func descendants<T: NSView>(of root: NSView, _ type: T.Type) -> [T] {
    root.subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + descendants(of: $0, type) }
}

@MainActor
struct ConnectPressProbeTests {
    private func hosted(_ view: some View, size: CGSize = CGSize(width: 700, height: 500))
        -> (NSWindow, NSHostingView<AnyView>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// Every button on the detail side that can start a connect has a probe
    /// behind it, and each probe is the size of a button — none is the pane.
    @Test func theConnectButtonsHaveProbesTheSizeOfAButton() {
        for (pose, needsAccount, atLeast) in [("gmail-none", true, 2), ("gmail-none", false, 2),
                                              (ConnectionsPose.gmailThree, false, 2)] {
            let (window, host) = hosted(detail(gmail(pose), needsAccount: needsAccount))
            defer { window.close() }
            let probes = descendants(of: host, HumanPressProbe.Probe.self)
            // The main button and the "Also" row's Connect.
            #expect(probes.count >= atLeast, "\(pose): \(probes.count) probe(s)")
            for probe in probes {
                let rect = probe.convert(probe.bounds, to: nil)
                #expect(rect.width > 20 && rect.width < 320 && rect.height > 10 && rect.height < 60,
                        "\(pose): a probe of \(rect) is not a button")
            }
        }
    }

    /// The place the button hands the flow is its own rectangle, read from
    /// the probe AppKit laid out behind it — not the window's — and it is
    /// handed over before the action runs, in the same press.
    @Test func theButtonHandsOverItsOwnRectangleBeforeItActs() throws {
        let place = HumanPressPlace()
        let button = ConnectPressButton(title: "Sign in with Google to connect", prominent: true, place: place,
                                        pressed: { _ in }, action: {})
        let (window, host) = hosted(VStack { Spacer(); HStack { button; Spacer() } }.padding(24))
        defer { window.close() }

        let read = try #require(place.read(), "the probe never gave the place a view")
        #expect(read.windowNumber == window.windowNumber)
        let whole = host.convert(host.bounds, to: nil)
        #expect(read.rectInWindow.width < 320 && read.rectInWindow.height < 60,
                "judged against \(read.rectInWindow), which is not a button")
        #expect(whole.contains(read.rectInWindow) && read.rectInWindow != whole)

        // What that buys: a live click on the button is on the control, and a
        // live click elsewhere in the same window — which the window-wide
        // place accepted — is not.
        let on = CGPoint(x: read.rectInWindow.midX, y: read.rectInWindow.midY)
        let off = CGPoint(x: whole.midX, y: whole.maxY - 10)
        #expect(HumanEventRule.insideControl(click: on, eventWindow: window.windowNumber, place: read))
        #expect(!HumanEventRule.insideControl(click: off, eventWindow: window.windowNumber, place: read))
        #expect(HumanEventRule.insideControl(
            click: off, eventWindow: window.windowNumber,
            place: ControlPlace(windowNumber: window.windowNumber, rectInWindow: whole)),
                "the control for this test: the whole window does accept that click")

        // Where, then what: the flow reads the place inside the action.
        var order: [String] = []
        var handed: HumanPressPlace?
        ConnectPressButton.press(place, pressed: { handed = $0; order.append("where") },
                                 action: { order.append(handed === place ? "act, knowing where" : "act, blind") })
        #expect(order == ["where", "act, knowing where"])
    }

    /// The place answers for one start. A later start from somewhere else is
    /// not judged against a button it did not come from.
    @Test func thePlaceIsGoodForOneStart() {
        let (flow, _) = flowRecording()
        let place = HumanPressPlace()
        flow.pressPlace = place
        #expect(flow.takePressPlace() === place)
        #expect(flow.takePressPlace() == nil)

        flow.pressPlace = place
        flow.start(gmail("gmail-none"))     // no account needed in a test: nothing reads it
        #expect(flow.pressPlace == nil, "a place left behind would judge the next press")
        flow.cancel()
    }

    // The official build reading this place first is tested with the closed
    // half's own tests (ConnectPressPlaceTests): OfficialCloud is closed, and
    // the open tree must build and test without it.
}
