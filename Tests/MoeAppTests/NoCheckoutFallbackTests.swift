import Foundation
import Testing
@testable import Moe

/// No helper lookup ends at `~/moe/…`.
///
/// Sixteen did. On the owner's Mac that directory was a checkout 1,409
/// commits behind `main` on 2026-11-12, and a Moe missing a script would have
/// run the nine-week-old one from there without a word. The only checkout a
/// build may read is the one it was compiled from, in a debug build
/// (`Payload.checkoutPath`).
struct NoCheckoutFallbackTests {

    @Test func noSourceNamesTheHomeCheckout() throws {
        var found: [String] = []
        for file in try NoSystemPythonTests.sources() {
            for (i, line) in file.lines.enumerated() where !NoSystemPythonTests.isComment(line) {
                // A path built onto the home directory. (`"~/moe/scripts/"`
                // as text to strip out of a script's words is not one.)
                if line.contains("\"/moe/") || line.contains("\"moe/moe-home") {
                    found.append("\(file.path):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(found.isEmpty, "a lookup falls back to ~/moe — use Payload.checkoutPath:\n\(found.joined(separator: "\n"))")
    }

    /// In this (debug) test build it resolves into the tree being tested,
    /// and only for something that is there.
    @Test func theDebugCheckoutIsThisOne() throws {
        let here = NoSystemPythonTests.root.standardizedFileURL.path
        let found = try #require(Payload.checkoutPath("moe-home/hermes/configure-hermes.py"))
        #expect(URL(fileURLWithPath: found).standardizedFileURL.path
                == here + "/moe-home/hermes/configure-hermes.py")
        #expect(Payload.checkoutPath("moe-home/no-such-file.py") == nil)
    }
}
