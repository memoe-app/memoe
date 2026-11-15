import Foundation
import Testing
@testable import Moe

/// Nothing in the app launches the system `python3`.
///
/// On a Mac without Apple's developer tools `/usr/bin/python3` is a stub: it
/// puts up "install the command line developer tools?" and prints nothing.
/// Ten readers launched it until 2026-11-12, so the Memory page drew that
/// dialog and then "Nothing about you yet" over a full memory. Every launch
/// goes through `BrainSetup.python()` now, and this reads the sources so the
/// eleventh cannot arrive unnoticed.
struct NoSystemPythonTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift file under Sources/, through the `Sources/Moe/Closed`
    /// symlink too — the cloud half is compiled into the same app.
    static func sources() throws -> [(path: String, lines: [String])] {
        let fm = FileManager.default
        var out: [(String, [String])] = []
        func walk(_ dir: URL, _ shown: String) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() {
                let url = dir.appendingPathComponent(name).resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { try walk(url, shown + "/" + name) }
                else if name.hasSuffix(".swift") {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    out.append((shown + "/" + name, text.components(separatedBy: "\n")))
                }
            }
        }
        try walk(root.appendingPathComponent("Sources"), "Sources")
        return out
    }

    /// Code, not prose: a comment may name the path to say why it is not used.
    static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    @Test func noSourceLaunchesTheSystemPython() throws {
        let files = try Self.sources()
        // The walk has to have found the app, or this passes on nothing.
        #expect(files.count > 200, "only \(files.count) Swift files found under Sources/")
        // Only where the closed half is present: the open-source tree has no
        // Sources/Moe/Closed link at all, and that is not a walk that failed.
        if FileManager.default.fileExists(
            atPath: Self.root.appendingPathComponent("Sources/Moe/Closed").resolvingSymlinksInPath().path) {
            #expect(files.contains { $0.path.hasSuffix("Closed/ChannelMigration.swift") },
                    "the Closed symlink was not followed")
        }

        // `"python3"` as a string is how `env python3` is spelled; the one
        // place it is a word and not a launch is the list of interpreters
        // SpokenStep recognises in a command somebody else ran.
        let wordNotLaunch = ["Sources/MoeBrain/SpokenStep.swift"]
        var found: [String] = []
        for file in files {
            for (i, line) in file.lines.enumerated() where !Self.isComment(line) {
                if line.contains("\"/usr/bin/python3\"") || line.contains("\"/usr/bin/python\"") {
                    found.append("\(file.path):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
                if line.contains("\"python3\"") || line.contains("\"python\""),
                   !wordNotLaunch.contains(file.path) {
                    found.append("\(file.path):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(found.isEmpty, "the system python3 is launched here — use BrainSetup.python():\n\(found.joined(separator: "\n"))")
    }

    /// The resolver itself: whatever it answers, it is not the stub.
    @Test func theResolverNeverAnswersWithTheStub() {
        let py = BrainSetup.python()
        #expect(py != "/usr/bin/python3")
        #expect(!BrainSetup.developerPythons.contains("/usr/bin/python3"))
        #expect(BrainSetup.bundledPython.hasSuffix("/.hermes/hermes-agent/.venv/bin/python"))
        // Either Moe's own, a test's stand-in, or a real one in the tools.
        #expect(py == BrainSetup.bundledPython || py != "/usr/bin/python3")
    }

    /// "Could not look" is its own answer, with its own words.
    @Test func couldntLookIsNotNothing() {
        #expect(MemoryReader.couldntLookLine != MemoryTab.you.empty)
        #expect(MemoryReader.couldntLookLine.contains("couldn't look"))
        #expect(MemoryReader.Reading().couldntLook == false)
    }
}
