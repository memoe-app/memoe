import Foundation
import Testing
@testable import Moe
import MoeBrain
import MoeIsland

/// Settings › Voice, the one page that replaced Voice › Talking, Voice ›
/// How Moe sounds and Settings › Replies (design D, 2026-09-25).
@MainActor
struct VoiceSettingsTests {

    // MARK: - Every control writes its key

    /// The three that are not flipped here, and why. Each goes through a
    /// Conductor path this change did not touch.
    static let notFlipped: [VoiceSettingsModel.Control: String] = [
        .voice: "Conductor.useVoice loads a speech engine",
        .language: "Conductor.setLanguage warms (and may download) a recogniser",
        .replyLength: "Conductor.setReplyLength runs configure-hermes.py, which a test must not point at ~/.hermes",
    ]

    /// Flip one control through the page's own binding.
    private func flip(_ control: VoiceSettingsModel.Control, _ m: VoiceSettingsModel) {
        switch control {
        case .talkKey: m.talkKey.wrappedValue = .rightCommand
        // Off, never on: on asks macOS for the microphone.
        case .heyMoe: m.heyMoe.wrappedValue = false
        case .keepListening: m.keepListening.wrappedValue = false
        case .waitsFor: m.waitsFor.wrappedValue = "20"
        case .whenQuiet: m.whenQuiet.wrappedValue = "spoken"
        case .interrupt: m.interrupt.wrappedValue = true
        case .answersOutLoud: m.answers.wrappedValue = "screen"
        case .shortcut: m.shortcut.wrappedValue = 2304
        case .alsoAfterHold: m.alsoAfterHold.wrappedValue = true
        case .sayOnIt: m.sayOnIt.wrappedValue = true
        case .tellProgress: m.tellProgress.wrappedValue = false
        case .ding: m.ding.wrappedValue = false
        case .speakSpoken: m.speakSpoken.wrappedValue = false
        case .speakTyped: m.speakTyped.wrappedValue = true
        case .typedReadAsText: m.typedReadAsText.wrappedValue = false
        case .panelOpens: m.panelOpens.wrappedValue = .always
        case .panelStays: m.panelStays.wrappedValue = 30
        case .typedOpensChat: m.typedOpensChat.wrappedValue = true
        case .hoverOpens: m.hoverOpens.wrappedValue = false
        case .premium: m.premium.wrappedValue = false
        case .voice, .language, .replyLength: break
        }
    }

    private static func savedJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: Config.configURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func everyControlWritesItsKey() throws {
        try StallGuardConductorTests.requireScratchHome()
        var seed = Config()
        seed.hermesKey = "voice-settings-test"
        seed.wakeWordEnabled = true   // so flipping it is "off", which needs no microphone
        seed.save()
        let conductor = Conductor(config: seed)
        let model = VoiceSettingsModel(conductor: conductor)

        for control in VoiceSettingsModel.Control.allCases where Self.notFlipped[control] == nil {
            let before = try Self.savedJSON()[control.configKey].map { "\($0)" }
            flip(control, model)
            let after = try Self.savedJSON()[control.configKey].map { "\($0)" }
            #expect(after != nil, "\(control) wrote no \(control.configKey)")
            #expect(before != after, "\(control) did not change \(control.configKey) (still \(after ?? "nil"))")
        }
        // A control added without a flip, or a flip for a control that is gone.
        #expect(VoiceSettingsModel.Control.allCases.count == 23)
    }

    /// The page must bind through the model, or the test above tests
    /// something the page does not use. Read off the pane's source.
    @Test func thePageBindsEveryControlThroughTheModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pane = try String(contentsOf: root.appendingPathComponent("Sources/Moe/Settings/VoicePane.swift"), encoding: .utf8)
        let binding: [VoiceSettingsModel.Control: String] = [
            .talkKey: "model.talkKey", .heyMoe: "model.heyMoe", .keepListening: "model.keepListening",
            .waitsFor: "model.waitsFor", .whenQuiet: "model.whenQuiet", .interrupt: "model.interrupt",
            .answersOutLoud: "model.answers", .voice: "conductor.useVoice", .replyLength: "model.replyLength",
            .shortcut: "model.shortcut", .language: "languageMenu", .alsoAfterHold: "model.alsoAfterHold",
            .sayOnIt: "model.sayOnIt", .tellProgress: "model.tellProgress", .ding: "model.ding",
            .speakSpoken: "model.speakSpoken", .speakTyped: "model.speakTyped",
            .typedReadAsText: "model.typedReadAsText", .panelOpens: "model.panelOpens",
            .panelStays: "model.panelStays", .typedOpensChat: "model.typedOpensChat",
            .hoverOpens: "model.hoverOpens", .premium: "model.premium",
        ]
        for control in VoiceSettingsModel.Control.allCases {
            let needle = try #require(binding[control], "\(control) has no binding named here")
            #expect(pane.contains(needle), "the Voice page does not use \(needle) for \(control)")
        }
        // The screen rows left this page for Permissions, and nothing was lost.
        for gone in ["setScreenContext", "setScreenPointerMovesMouse", "setComputerUseMayTakeOver"] {
            #expect(!pane.contains(gone), "\(gone) is back on the Voice page")
        }
        let perms = try String(contentsOf: root.appendingPathComponent("Sources/Moe/Settings/PermissionsPane.swift"), encoding: .utf8)
        for moved in ["setScreenContext", "setScreenPointerMovesMouse", "setComputerUseMayTakeOver"] {
            #expect(perms.contains(moved), "\(moved) has no switch anywhere in Settings")
        }
        // "How easily" under Interrupt has no setting behind it yet.
        #expect(!pane.contains("How easily"))
    }

    // MARK: - A switch shows its controls only when it is on

    @Test func eachSwitchRevealsOnlyItsOwnControlsWhenOn() {
        var c = Config()
        c.conversationMode = false
        c.bargeIn = false
        c.speakReplies = false
        #expect(VoiceSettingsModel.reveals(heyMoe: false, config: c).isEmpty)

        #expect(VoiceSettingsModel.reveals(heyMoe: true, config: c) == [.teachName])
        c.conversationMode = true
        #expect(VoiceSettingsModel.reveals(heyMoe: false, config: c) == [.listeningWindow])
        c.conversationMode = false
        c.bargeIn = true
        #expect(VoiceSettingsModel.reveals(heyMoe: false, config: c) == [.interruptCheck])
        c.bargeIn = false
        c.speakReplies = true
        #expect(VoiceSettingsModel.reveals(heyMoe: false, config: c) == [.voice])

        c.conversationMode = true
        c.bargeIn = true
        #expect(VoiceSettingsModel.reveals(heyMoe: true, config: c) == Set(VoiceSettingsModel.Reveal.allCases))
    }

    /// A fresh install: the listening window is open, nothing else that
    /// needs a switch is.
    @Test func aFreshInstallShowsTheListeningWindowAndTheVoice() {
        #expect(VoiceSettingsModel.reveals(heyMoe: false, config: Config()) == [.listeningWindow, .voice])
    }

    // MARK: - Existing people keep what they had

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func anExistingInstallKeepsItsValue() throws {
        #expect(Config().conversationMode, "a new install listens after answering")
        #expect(try decode(#"{"conversationMode": false}"#).conversationMode == false)
        #expect(try decode(#"{"conversationMode": true}"#).conversationMode == true)
        // A file from before the key existed is an existing install: the
        // old default, never the new one.
        #expect(try decode("{}").conversationMode == false)
        // And a save carries it through untouched.
        var old = try decode(#"{"conversationMode": false, "bargeIn": true, "followUpSeconds": 12}"#)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        old.replyChime = false
        old.save(to: url)
        let back = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        #expect(!back.conversationMode && back.bargeIn && back.followUpSeconds == 12)
    }

    /// A value the file allows but the page does not list is offered, so
    /// opening the page never changes it.
    @Test func anUnlistedWaitIsKept() {
        #expect(VoiceSettingsModel.waitChoices(current: 8) == [8, 12, 16, 20, 30])
        #expect(VoiceSettingsModel.waitChoices(current: 45) == [8, 12, 16, 20, 30, 45])
    }

    // MARK: - Replies lives here now

    @Test func aLinkToRepliesLandsOnVoice() {
        #expect(SettingsWindow.Selection(.replies).section == .voice)
        #expect(SettingsWindow.Selection.landing(.brain) == .brain)
    }
}
