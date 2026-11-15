import Foundation
import Testing
@testable import MoeVoice

/// The doubt about a bad voice enrolment outlives the process, and ends when
/// the voice is taught again. In a temporary directory — never Moe's home.
struct WakeOwnerTrustTests {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-wake-trust-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent("wake-owner-distrust.json")
    }

    @Test func aFreshMacTrustsTheEnrolment() {
        #expect(WakeOwnerTrust(file: scratch()).trusted)
    }

    /// The bug: a new launch is a new value reading the same file, and it
    /// used to start from "trusted" every time.
    @Test func theDoubtSurvivesARestart() {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let when = Date(timeIntervalSince1970: 1_770_000_000)
        #expect(WakeOwnerTrust(file: file).distrust(refusals: 3, now: when))
        let nextLaunch = WakeOwnerTrust(file: file)
        #expect(!nextLaunch.trusted)
        #expect(nextLaunch.record == .init(refusals: 3, since: when))
    }

    @Test func teachingTheVoiceAgainClearsIt() {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let trust = WakeOwnerTrust(file: file)
        trust.distrust(refusals: 3)
        #expect(!trust.trusted)
        trust.clear()
        #expect(trust.trusted)
        #expect(WakeOwnerTrust(file: file).trusted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Clearing what is not there is not an error.
        trust.clear()
    }

    /// An unreadable note is trust: it must not switch the owner check off.
    @Test func aCorruptFileIsTrust() throws {
        let file = scratch()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(WakeOwnerTrust(file: file).trusted)
    }

    /// The home path has a space in it ("Application Support").
    @Test func aPathWithASpaceWorks() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe wake trust \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trust = WakeOwnerTrust(file: dir.appendingPathComponent("voice/wake-owner-distrust.json"))
        #expect(trust.distrust(refusals: 3))
        #expect(!trust.trusted)
    }
}
