import Foundation
import Testing
@testable import Moe

/// The `python3` a helper gets is Moe's own, and it can verify a certificate.
///
/// 123 files under `moe-home/` start `#!/usr/bin/env python3` and their shell
/// scripts say `python3` 183 times more. All of them are found through the
/// PATH `ScriptRunner.environment()` builds, which began `~/.local/bin:
/// /opt/homebrew/bin:/usr/local/bin`. On 2026-11-11 a python.org Python 3.15
/// landed in `/usr/local/bin` on the owner's Mac; that build's OpenSSL has no
/// trust store until its "Install Certificates" step is run, and the next day
/// Gmail's "Add another" answered
///
///     could not start the sign-in: URLError: <urlopen error [SSL:
///     CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get
///     local issuer certificate (_ssl.c:1147)>
///
/// Measured on that Mac, same request, three interpreters: `/usr/local/bin/
/// python3` (3.15.2, cafile None) failed with exactly that; `/usr/bin/python3`
/// and Moe's own (3.14.7, cafile `/private/etc/ssl/cert.pem`) passed.
///
/// These run the real environment builders and then the interpreter they
/// lead to. Take `BrainSetup.pathWithMoePython` out of either and the tests
/// below go red on any Mac whose first `python3` is not Moe's.
struct HelperPythonTests {

    static let fm = FileManager.default

    /// What `/usr/bin/env python3` would start: the first runnable `python3`
    /// along `path`.
    static func firstPython3(on path: String?) -> String? {
        (path ?? "").split(separator: ":").map { "\($0)/python3" }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static func scratch(_ name: String) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("moe-helper-python-\(UUID().uuidString)/\(name)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func plantPython(in dir: URL) throws {
        let file = dir.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static let moeHasItsPython = fm.isExecutableFile(atPath: BrainSetup.bundledPython)
    static let moeBin = (BrainSetup.bundledPython as NSString).deletingLastPathComponent

    // MARK: the rule, on directories made for it

    /// The failure itself, in miniature: some other Python sits in a
    /// directory that comes first, and Moe's still wins.
    @Test func moePythonIsFoundBeforeAnotherOneEarlierOnThePath() throws {
        let theirs = try Self.scratch("usr-local-bin"), ours = try Self.scratch("moe venv/bin")
        try Self.plantPython(in: theirs)
        try Self.plantPython(in: ours)
        let before = "\(theirs.path):/usr/bin:/bin"
        #expect(Self.firstPython3(on: before) == theirs.path + "/python3")

        let after = BrainSetup.pathWithMoePython(before, python: ours.path + "/python")
        #expect(Self.firstPython3(on: after) == ours.path + "/python3")
        #expect(after == "\(ours.path):\(theirs.path):/usr/bin:/bin")
    }

    @Test func aPathThatAlreadyHasItIsNotGivenItTwice() throws {
        let ours = try Self.scratch("bin")
        try Self.plantPython(in: ours)
        let after = BrainSetup.pathWithMoePython("/usr/bin:\(ours.path):/bin", python: ours.path + "/python")
        #expect(after == "\(ours.path):/usr/bin:/bin")
    }

    /// A directory with no `python3` in it is not put on the PATH. The
    /// gateway named `~/.hermes/python/python/bin` for ten weeks after the
    /// interpreter left it, and nothing could tell.
    @Test func aDirectoryWithNoPythonInItIsNotAdded() throws {
        let empty = try Self.scratch("bin")
        #expect(BrainSetup.pathWithMoePython("/usr/bin:/bin", python: empty.path + "/python") == "/usr/bin:/bin")
        #expect(BrainSetup.pathWithMoePython("/usr/bin:/bin", python: "/nowhere/at/all/python") == "/usr/bin:/bin")
    }

    // MARK: the two environments Moe really builds

    @Test(.enabled(if: HelperPythonTests.moeHasItsPython,
                   "SKIPPED — Moe's own Python is not installed on this Mac, so there is nothing to lead the PATH"))
    func aHelperIsStartedWithMoesPython() {
        let path = ScriptRunner.environment()["PATH"]
        #expect(Self.firstPython3(on: path) == Self.moeBin + "/python3",
                "a helper's `#!/usr/bin/env python3` would start \(Self.firstPython3(on: path) ?? "nothing")")
    }

    @Test(.enabled(if: HelperPythonTests.moeHasItsPython,
                   "SKIPPED — Moe's own Python is not installed on this Mac, so there is nothing to lead the PATH"))
    func theGatewaysChildrenAreStartedWithMoesPython() {
        let path = HermesSupervisor.childEnvironment(token: "")["PATH"] ?? ""
        #expect(Self.firstPython3(on: path) == Self.moeBin + "/python3",
                "a hook's `python3` would be \(Self.firstPython3(on: path) ?? "nothing")")
        // test-hermes-supervisor.sh reads the head of this PATH; it stays.
        #expect(path.hasPrefix(NSHomeDirectory() + "/.hermes/bin:"))
        #expect(!path.contains("/.hermes/python/python/bin"), "the interpreter has not been there since September")
    }

    // MARK: and what that interpreter can do

    /// Asked of the interpreter itself, through the same launch a connector
    /// gets. No network: this is whether there is anything to verify WITH.
    @Test func thePythonAHelperGetsHasCertificatesToTrust() {
        let probe = """
        import os, ssl, sys
        p = ssl.get_default_verify_paths()
        f = os.environ.get("SSL_CERT_FILE") or p.cafile
        d = os.environ.get("SSL_CERT_DIR") or p.capath
        ok = bool(f and os.path.isfile(f) and os.path.getsize(f) > 0)
        n = len(ssl.create_default_context().get_ca_certs())
        print("TRUST file=%s usable=%s dir=%s loaded=%d exe=%s" % (f, ok, d, n, sys.executable))
        """
        let r = ScriptRunner.run("/usr/bin/env", ["python3", "-c", probe], timeout: 30)
        let line = r.output.split(separator: "\n").last { $0.hasPrefix("TRUST ") }.map(String.init) ?? ""
        #expect(r.status == 0, "could not ask: \(r.output)")
        #expect(line.contains("usable=True") || !line.contains("loaded=0"),
                "the python3 a helper gets has no certificate authorities: \(line.isEmpty ? r.output : line)")
    }

    /// Whether this Mac can reach Composio at all — asked by URLSession, which
    /// uses the system's trust and none of Python's. When it cannot, the test
    /// below is skipped out loud; a refused certificate with the network up
    /// is then never mistaken for "no network".
    static let composioIsReachable: Bool = {
        var req = URLRequest(url: URL(string: "https://backend.composio.dev/")!, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answered = false
        URLSession(configuration: .ephemeral).dataTask(with: req) { _, resp, _ in
            answered = resp is HTTPURLResponse
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return answered
    }()

    /// The request that failed, without a key and without starting anything:
    /// one HEAD to the host composio.py calls, through the launch it gets.
    @Test(.enabled(if: HelperPythonTests.composioIsReachable,
                   "SKIPPED — backend.composio.dev cannot be reached from this Mac, so the certificate check DID NOT RUN"))
    func aHelperCanVerifyComposiosCertificate() {
        let probe = """
        import urllib.request, urllib.error
        req = urllib.request.Request("https://backend.composio.dev/", method="HEAD")
        try:
            urllib.request.urlopen(req, timeout=15)
            print("VERIFIED")
        except urllib.error.HTTPError:
            print("VERIFIED")
        except Exception as e:
            print("REFUSED %s: %s" % (type(e).__name__, e))
        """
        let r = ScriptRunner.run("/usr/bin/env", ["python3", "-c", probe], timeout: 40)
        #expect(r.output.contains("VERIFIED"), "\(r.output)")
    }
}
