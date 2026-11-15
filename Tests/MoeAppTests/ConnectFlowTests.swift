import Foundation
import Testing
@testable import Moe

/// ConnectFlow, the Connections sheet's state machine, with its launcher
/// replaced: nothing here can start connect.sh. On a real Mac that would, for
/// Signal, download 180 MB and ask a phone to link.

/// Records every launch the flow asks for. Launches happen off the main
/// thread, so it locks.
final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ call: [String]) { lock.lock(); recorded.append(call); lock.unlock() }
}

private func row(_ name: String, auth: Connection.AuthKind = .scan,
                 state: Connection.State = .notConnected) -> Connection {
    Connection(id: "platform/\(name)", kind: .platform, name: name, label: name.capitalized, blurb: "",
               authKind: auth, state: state, detail: "", envKeys: [], allowedUsersKey: "", prompts: [:],
               docs: "", connectName: "platform/\(name)", setupScript: "")
}

@MainActor
private func isolatedFlow(output: String = "", status: Int32 = 0) -> (ConnectFlow, LaunchRecorder) {
    let flow = ConnectFlow()
    let recorder = LaunchRecorder()
    flow.locateScript = { "/nonexistent/moe-app-tests/\($0)" }
    flow.launchScript = { script, args, _, _, _, _, _, onLine in
        recorder.record([script] + args)
        for line in output.split(separator: "\n") { onLine?(String(line)) }
        return ScriptRunner.Result(status: status, output: output, timedOut: false)
    }
    flow.checkConnected = { _ in false }
    return (flow, recorder)
}

/// Returns as soon as `condition` holds, so the ceiling costs nothing when
/// things are quick. It is a minute because the flow launches on GCD's global
/// queue, and in the full parallel run (2,200 tests, keychain and PostgreSQL
/// suites blocking threads) a 5 s ceiling ran out before the queue reached
/// the launch — six false failures, 2026-09-14.
@MainActor
private func eventually(_ seconds: TimeInterval = 60, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// A pause before checking that nothing was launched. Under load a launch can
/// take longer than this to be recorded, so it is never the only check: every
/// "nothing launched" test also asserts the phase synchronously, and `scan`
/// leaves `.confirming` before it launches anything.
private let settle: UInt64 = 300_000_000

@MainActor
private func isConfirming(_ flow: ConnectFlow) -> Bool {
    if case .confirming = flow.phase { return true }
    return false
}

@MainActor
struct SignalWarningTests {
    /// Signal hands over the whole account, so its warning must be dismissed
    /// before anything starts — not a line in a blurb scrolled past.
    @Test func connectingSignalStopsAtTheWarningAndLaunchesNothing() async {
        let (flow, launches) = isolatedFlow()
        flow.start(row("signal"))
        #expect(flow.presented)
        guard case .confirming(let text) = flow.phase else {
            Issue.record("Signal went to \(flow.phase), not the warning")
            return
        }
        #expect(text.contains("whole Signal account"))
        // The path Signal itself shows, the same as everywhere else in Moe.
        #expect(text.contains("Signal › Settings › Linked devices"), "\(text)")
        #expect(!text.contains("Linked Devices"), "\(text)")
        try? await Task.sleep(nanoseconds: settle)
        #expect(launches.calls.isEmpty, "a script was launched before the warning was answered: \(launches.calls)")
    }

    @Test func cancellingTheWarningLeavesNothingPresentedOrRunning() async {
        let (flow, launches) = isolatedFlow()
        flow.start(row("signal"))
        #expect(isConfirming(flow), "Signal went to \(flow.phase), not the warning")
        flow.cancel()
        #expect(!flow.presented)
        try? await Task.sleep(nanoseconds: settle)
        #expect(launches.calls.isEmpty, "cancelling the warning still launched \(launches.calls)")
    }

    /// docs/SIGNAL.md marks the five-device limit UNCONFIRMED; the sheet
    /// must not state it as fact.
    @Test func theSignalFailureAdviceDoesNotStateAnUnconfirmedLimit() {
        let (flow, _) = isolatedFlow()
        flow.connection = row("signal")
        #expect(!flow.nextStep.contains("five"), "\(flow.nextStep)")
        #expect(flow.nextStep.contains("Signal › Settings › Linked devices"), "\(flow.nextStep)")
    }

    @Test func onlyContinueGoesOnToTheScan() async {
        let (flow, launches) = isolatedFlow()
        let signal = row("signal")
        flow.start(signal)
        #expect(isConfirming(flow), "Signal went to \(flow.phase), not the warning")
        try? await Task.sleep(nanoseconds: settle)
        #expect(launches.calls.isEmpty)
        flow.confirmedScan(signal)
        #expect(!isConfirming(flow), "Continue left the sheet on the warning")
        #expect(await eventually { launches.calls.count == 1 })
        #expect(launches.calls.first == ["/nonexistent/moe-app-tests/connect.sh", "platform/signal"])
    }

    /// The control: the gate is Signal's alone, and the recorder does see a
    /// launch — without this, "nothing was launched" could be a blind spot.
    @Test func whatsAppStillGoesStraightToItsCode() async {
        let (flow, launches) = isolatedFlow()
        flow.start(row("whatsapp"))
        #expect(await eventually { launches.calls.count == 1 })
        if case .confirming = flow.phase { Issue.record("WhatsApp was sent through Signal's warning") }
    }
}

/// The WhatsApp row after the code is scanned.
///
/// The owner's report, 2026-09-20: *"I connected WhatsApp on the Mac, and I
/// did the QR code. On my WhatsApp, it says it's active… and it still says
/// it's not linked. Now it shows connected only a couple minutes later, but
/// in real time, it wasn't showing 'connecting' or 'connected.'"*
///
/// Two defects behind that, both here. `connect-whatsapp.sh` exits with a QR
/// code still on screen and `NEEDS_RESTART=gateway` after it, and the restart
/// path treated every phase that was not `.working` as settled — so the sheet
/// kept the used code, the brain was restarted behind it, and `succeed()` was
/// never reached, which left `changed` false and the pane behind it unread.
/// And nothing was said at all between the scan and the script's exit, which
/// is minutes: the script waits for the phone's history first.
@MainActor
struct WhatsAppScanSettlesTests {
    /// The Mac's own WhatsApp row: kind `.mac`, no connectName, its setup
    /// script rather than connect.sh (ConnectionsCatalog.specs).
    private func whatsAppRow() -> Connection {
        Connection(id: "mac/whatsapp", kind: .mac, name: "whatsapp", label: "WhatsApp on this Mac",
                   blurb: "", authKind: .scan, state: .notConnected, detail: "", envKeys: [],
                   allowedUsersKey: "", prompts: [:], docs: "", connectName: "",
                   setupScript: "connect-whatsapp.sh")
    }

    /// What the script really prints: two codes, the scan, then the restart.
    private static let scanOutput = """
        Open WhatsApp › Settings › Linked Devices › Link a Device, then scan the code.
        QR=2@FIRSTCODE
        QR=2@SECONDCODE
        LINKED=1
        Linked. Saving your recent chats…
        ✓ Linked to A Person.
        NEEDS_RESTART=gateway
        """

    @Test func aScannedCodeEndsOnConnectedAndTellsThePaneToReload() async {
        let (flow, _) = isolatedFlow(output: Self.scanOutput)
        flow.checkConnected = { _ in true }
        var restarts = 0
        flow.restartGateway = { restarts += 1 }
        flow.start(whatsAppRow())
        #expect(await eventually { if case .done = flow.phase { return true }; return false },
                "the sheet stopped at \(flow.phase) — a scanned code that never says it worked")
        #expect(restarts == 1)
        // Without this the pane behind the sheet is never read again:
        // ConnectionsView's onDismiss reloads only when `changed` is set.
        #expect(flow.changed, "the sheet settled without telling the pane to read the row again")
    }

    /// The link is not made by the script exiting: the bridge starts with the
    /// brain and reaches WhatsApp a few seconds later. So the verdict is the
    /// Mac connector's own status line, asked for by name.
    @Test func theVerdictIsTheMacConnectorNotTheExitCode() async {
        let asked = LaunchRecorder()
        let (flow, _) = isolatedFlow(output: Self.scanOutput)
        flow.checkConnected = { name in asked.record([name]); return true }
        flow.restartGateway = {}
        flow.start(whatsAppRow())
        #expect(await eventually { if case .done = flow.phase { return true }; return false })
        #expect(asked.calls.contains(["mac/whatsapp"]),
                "the sheet settled without asking WhatsApp's own connector: \(asked.calls)")
    }

    /// The seconds after the scan, which used to show a code the phone had
    /// already accepted.
    @Test func theCodeIsReplacedTheMomentThePhoneScansIt() async {
        // The script is held open after LINKED=1 rather than exiting,
        // because that is what the real one does: it spends up to three
        // minutes taking the phone's history before it returns. Those
        // minutes are what the person was watching a used QR code through.
        let flow = ConnectFlow()
        let release = DispatchSemaphore(value: 0)
        flow.locateScript = { "/nonexistent/moe-app-tests/\($0)" }
        flow.launchScript = { _, _, _, _, _, _, _, onLine in
            onLine?("QR=2@FIRSTCODE")
            onLine?("LINKED=1")
            release.wait()
            return ScriptRunner.Result(status: 0, output: "", timedOut: false)
        }
        flow.checkConnected = { _ in false }
        flow.start(whatsAppRow())
        let saidLinked = await eventually {
            if case .working(let words) = flow.phase { return words.contains("Linked") }
            return false
        }
        let seen = flow.phase
        release.signal()
        #expect(saidLinked, "with the scan done and the history arriving, the sheet was on \(seen)")
    }

    @Test func aLinkedLineIsAMachineLineAndNeverReachesThePerson() {
        #expect(MachineLine.parse("LINKED=1") == .linked)
        #expect(MachineLine.parse("LINKED=") == nil)
        #expect(MachineLine.isMachine("LINKED=1"))
        // The sheet's failure text is the last line written for a person.
        let r = ScriptRunner.Result(status: 1, output: "✗ Nobody scanned the code in time.\nLINKED=1\n", timedOut: false)
        #expect(r.lastHumanLine == "✗ Nobody scanned the code in time.")
    }

    /// A Mac source's `unavailable:` sentence is about this minute. The row
    /// printed "Not available yet" over it, which about WhatsApp reads as
    /// "Moe does not do that yet".
    @Test func aMacSourceSaysWhatIsHappeningRatherThanNotAvailableYet() {
        let spec = MacSources.Spec(key: "whatsapp", label: "WhatsApp on this Mac", blurb: "",
                                           setupScript: "connect-whatsapp.sh")
        let starting = MacSources.connection(
            for: spec,
            statusLine: "unavailable: linked — Moe is starting your WhatsApp link now, which takes a few seconds")
        #expect(starting.state == .unavailable)
        #expect(starting.unavailableWords?.contains("starting your WhatsApp link") == true,
                "\(String(describing: starting.unavailableWords))")
        // A check that did not answer keeps its own words, and a service this
        // account cannot have keeps the generic line.
        let late = MacSources.connection(for: spec, statusLine: "timeout: " + Connection.couldNotCheckWords)
        #expect(late.unavailableWords == nil)
        #expect(row("linear", auth: .oauth, state: .unavailable).unavailableWords == nil)
    }
}

@MainActor
struct DisconnectRestartTests {
    /// connect.sh --remove prints NEEDS_RESTART=gateway for a chat platform.
    /// Until 2026-09-14 only the connect path read it, so Disconnect on
    /// Signal said "disconnected" and Moe went on answering in Note to Self.
    @Test func disconnectingAChatPlatformRestartsTheGateway() async {
        let (flow, launches) = isolatedFlow(output: """
            ✓ Signal unlinked on this Mac.
            ✓ signal token removed from .env.
            NEEDS_RESTART=gateway
            """)
        var restarts = 0
        flow.restartGateway = { restarts += 1 }
        flow.remove(row("signal", state: .connected))
        #expect(await eventually { if case .done = flow.phase { return true }; return false })
        #expect(restarts == 1)
        #expect(launches.calls.first == ["/nonexistent/moe-app-tests/connect.sh", "--remove", "platform/signal"])
    }

    @Test func aRemovalThatAsksForNoRestartGetsNone() async {
        let (flow, _) = isolatedFlow(output: "✓ linear removed (config and any OAuth token).\n")
        var restarts = 0
        flow.restartGateway = { restarts += 1 }
        flow.remove(row("linear", auth: .oauth, state: .connected))
        #expect(await eventually { if case .done = flow.phase { return true }; return false })
        #expect(restarts == 0)
    }

    @Test func aFailedRemovalRestartsNothing() async {
        let (flow, _) = isolatedFlow(output: "✗ nothing called 'signal' is connected.\nNEEDS_RESTART=gateway\n", status: 1)
        var restarts = 0
        flow.restartGateway = { restarts += 1 }
        flow.remove(row("signal", state: .connected))
        #expect(await eventually { if case .failed = flow.phase { return true }; return false })
        #expect(restarts == 0)
    }
}


/// Moe's own email address, the Email Moe row (slice G3): choosing a name is a
/// step of its own that launches nothing until the name is typed; the name
/// reaches connect.sh as one plain argument; and a connected row offers Copy
/// address and Change address, and no other row does.
@MainActor
struct MoeEmailRowTests {
    @Test func chooseMyAddressStopsAtTheNameStepAndLaunchesNothing() async {
        let (flow, launches) = isolatedFlow()
        flow.start(row("moemail", auth: .oneClick))
        if case .field(let field) = flow.phase {
            #expect(field == "moemail_name")
        } else {
            Issue.record("Choose my address did not stop at the name step: \(flow.phase)")
        }
        #expect(flow.fieldLabel.contains("@in.moebot.app"))
        try? await Task.sleep(nanoseconds: settle)
        #expect(launches.calls.isEmpty)
    }

    @Test func theNameReachesConnectShAsOnePlainArgument() async {
        let (flow, launches) = isolatedFlow(output: "✓ Your Moe email address is sam.smith@in.moebot.app\n")
        flow.start(row("moemail", auth: .oneClick))
        flow.fieldValue = " Sam.Smith "
        flow.continueField()
        #expect(await eventually { !launches.calls.isEmpty })
        #expect(launches.calls.first == ["/nonexistent/moe-app-tests/connect.sh", "platform/moemail", "sam.smith"])
    }

    @Test func aConnectedEmailRowOffersCopyAndChangeAndNoOtherRowDoes() {
        var connected = row("moemail", auth: .oneClick, state: .connected)
        connected.address = "sam@in.moebot.app"
        #expect(ConnectionDetail.emailActions(connected) == ["Copy address", "Change address…"])
        #expect(ConnectionDetail.emailActions(row("moemail", auth: .oneClick)) == [])
        #expect(ConnectionDetail.emailActions(row("telegram", auth: .oneClick, state: .connected)) == [])
        #expect(ConnectionDetail.primaryTitle(row("moemail", auth: .oneClick)) == "Choose my address")
    }

    /// A one-click row the cloud cannot offer from here reads "Not
    /// available yet", and its buttons are Check again and What's needed —
    /// not the connect button, which used to win because `(.oneClick, _)`
    /// matched before the unavailable arm.
    @Test func anUnavailableOneClickRowOffersCheckAgainAndNotTheConnectButton() {
        for name in ["slack", "moemail"] {
            let blocked = row(name, auth: .oneClick, state: .unavailable)
            #expect(ConnectionDetail.primaryTitle(blocked) == nil, "\(name) drew a connect button over a row that said not available")
            #expect(ConnectionDetail.offersCheckAgain(blocked))
        }
        // Telegram's one-click has no cloud half to ask again, so it gets
        // What's needed alone — still not "Create my Telegram bot".
        let telegram = row("telegram", auth: .oneClick, state: .unavailable)
        #expect(ConnectionDetail.primaryTitle(telegram) == nil)
        #expect(!ConnectionDetail.offersCheckAgain(telegram))
        // And the ordinary states are untouched.
        #expect(ConnectionDetail.primaryTitle(row("slack", auth: .oneClick)) == "Add to Slack")
        #expect(ConnectionDetail.primaryTitle(row("slack", auth: .oneClick, state: .needsAttention)) == "Try again")
        #expect(!ConnectionDetail.offersCheckAgain(row("slack", auth: .oneClick)))
    }
}

/// A certificate failure reaches the sheet as one plain sentence and advice
/// that fits it — never the raw SSL line, never a traceback's neighbour, and
/// never "check the key was copied whole". Measured 2026-11-12: a python.org
/// Python 3.15 with an empty trust store made every helper fail like this.
@MainActor
struct CertificateFailureWordsTests {
    static let traceback = """
    Opening Gmail's sign-in page…
    Traceback (most recent call last):
      File "/x/connect.py", line 12, in <module>
        urllib.request.urlopen(url)
    ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate (_ssl.c:1032)
    """
    static let folded = "✗ Couldn't reach Composio: <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate (_ssl.c:1032)>\n"

    @Test func everySpellingOfACertificateFailureBecomesThePlainSentence() {
        for output in [Self.traceback, Self.folded,
                       "curl: (60) SSL certificate problem: unable to get local issuer certificate\n",
                       "Error: requests.exceptions.SSLError: HTTPSConnectionPool(host='backend.composio.dev')\n",
                       "✗ The certificate for this server is invalid.\n"] {
            let r = ScriptRunner.Result(status: 1, output: output, timedOut: false)
            #expect(r.lastHumanLine == CertificateFailure.sentence, "\(output)")
            #expect(!r.lastHumanLine.contains("SSL") && !r.lastHumanLine.contains("_ssl"))
        }
    }

    @Test func anyOtherFailureKeepsItsOwnWords() {
        for line in ["✗ That key was refused by Firecrawl.", "✗ Nobody scanned the code in time.",
                     "✗ The database URL needs sslmode=require."] {
            let r = ScriptRunner.Result(status: 1, output: line + "\n", timedOut: false)
            #expect(r.lastHumanLine == line)
        }
        #expect(CertificateFailure.plain("Didn't connect.") == "Didn't connect.")
    }

    /// Through the real flow: the sheet's failed text AND the line under it.
    @Test func theSheetSaysItPlainlyAndTellsThemWhatToDo() async {
        let (flow, launches) = isolatedFlow(output: Self.traceback, status: 1)
        flow.start(row("moemail", auth: .oneClick))
        flow.fieldValue = "sam"
        flow.continueField()
        #expect(await eventually { if case .failed = flow.phase { return true }; return false })
        #expect(!launches.calls.isEmpty)
        #expect(flow.phase == .failed(CertificateFailure.sentence))
        #expect(flow.nextStep == CertificateFailure.nextStep)
        #expect(!flow.nextStep.lowercased().contains("key"))
    }
}
