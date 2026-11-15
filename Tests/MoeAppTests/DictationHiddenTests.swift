import Foundation
import Testing
@testable import Moe

/// docs/DEFAULTS.md row 4: dictation is hidden, not deleted. With
/// `Features.dictation` false nothing may offer it — no key, no tab, no
/// sidebar row, no welcome screen, no permission sentence about it — and an
/// old config.json that still says it is on must not bring the key back.
///
/// Every test is conditioned on the switch, so flipping it to true turns
/// these into "and it is all back" rather than into failures.
struct DictationHiddenTests {
    @Test("the switch is off, as the owner decided")
    func switchIsOff() {
        #expect(Features.dictation == false)
    }

    @Test("a fresh config starts with dictation off")
    func freshConfig() {
        #expect(Config().dictationEnabled == Features.dictation)
    }

    @Test("an old config.json that says dictation is on registers no key")
    func oldConfigIsIgnored() throws {
        let old = try JSONDecoder().decode(
            Config.self, from: Data(#"{"dictationEnabled": true, "dictationKey": "rightCommand"}"#.utf8))
        #expect(old.dictationEnabled)
        let key = Conductor.effectiveDictationKey(old)
        #expect(key == (Features.dictation ? .rightCommand : .off))
        #expect(Features.dictation || key.flagBit == nil)
    }

    @Test("the welcome is seven screens and none of them is dictation")
    func onboarding() throws {
        let shown = Onboarding.Screen.shown
        #expect(shown.contains(.dictate) == Features.dictation)
        #expect(shown.count == (Features.dictation ? 8 : 7))
        #expect(shown.first == .welcome && shown.last == .connect)
        // Skip from "Say hello" lands on the meetings screen, not a hidden one.
        #expect(Onboarding.Screen.tryIt.next == (Features.dictation ? .dictate : .meetings))
        // The dump scripts/test-onboarding.sh reads says the same.
        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(Onboarding.dumpJSON().utf8)) as? [String: Any])
        let ids = (json["screens"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(ids == shown.map(\.rawValue))
        // A resume marker from a build that still had the screen moves on.
        #expect(Onboarding.Screen.dictate.next == .meetings)
    }

    @Test("the snapshot takes no picture of a screen nobody sees")
    @MainActor func onboardingSnapshot() {
        let shots = OnboardingSnapshot.shots
        #expect(shots.contains { $0.pose.step == .dictate } == Features.dictation)
        // 24 since 2026-11-12: five more of the brain screen, for the key,
        // free and local-model rows that now wait on Settings › Brain.
        #expect(shots.count == (Features.dictation ? 26 : 24))
    }

    @Test("the main window's sidebar has no Dictation row")
    @MainActor func sidebar() {
        let items = MainWindow.Section.sidebarItems
        #expect(items.contains(.dictation) == Features.dictation)
        #expect(items.first == .chat)
        #expect(items.contains(.meetings))
    }

    @Test("Settings calls the pane Voice, and it has no typing tab")
    @MainActor func voicePane() {
        #expect(SettingsView.label(.voice, awayTier: "free") == (Features.dictation ? "Voice & Dictation" : "Voice"))
        #expect(VoicePane.title == SettingsView.label(.voice, awayTier: "free"))
        let tabs = VoicePane.tabs.map(\.0)
        #expect(tabs.contains(.typing) == Features.dictation)
        #expect(tabs.contains(.talking))
        // One page when dictation is hidden: no tab bar at all.
        #expect(tabs.count == (Features.dictation ? 2 : 1))
    }

    @Test("no permission sentence promises dictation")
    func permissionCopy() {
        guard !Features.dictation else { return }
        for guide in [PermissionGuide.accessibility, PermissionGuide.contacts] {
            #expect(!guide.what.lowercased().contains("dictat"), "\(guide.name): \(guide.what)")
            #expect(!guide.ifDeclined.lowercased().contains("dictat"), "\(guide.name): \(guide.ifDeclined)")
        }
    }
}
