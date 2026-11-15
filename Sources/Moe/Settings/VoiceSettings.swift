import MoeBrain
import MoeDesign
import MoeIsland
import SwiftUI

// Settings › Voice, the page the owner picked on 2026-09-25 (design D of
// ~/moe-voice-notes/voice-settings-proposal.md): independent, plainly named
// choices in three short sections, each main switch opening its own one or
// two controls when it is on, and everything rarely touched behind one
// "More". It replaced three screens — Voice › Talking to Moe, Voice › How
// Moe sounds, and Settings › Replies — thirty-two controls between them.
//
// This file is the part a test can hold: every control's binding, the key
// it writes, and which inline controls a switch reveals. `VoicePane` draws
// it and nothing else decides either.

@MainActor
struct VoiceSettingsModel {
    let conductor: Conductor
    private var config: Config { conductor.config }

    /// Every control on the page, by the config key it writes. A control
    /// added to the page without a case here — or a case without a test —
    /// fails `VoiceSettingsTests`.
    enum Control: String, CaseIterable {
        // Starting
        case talkKey, heyMoe
        // The conversation
        case keepListening, waitsFor, whenQuiet, interrupt
        // Moe's answers
        case answersOutLoud, voice, replyLength
        // More
        case shortcut, language, alsoAfterHold, sayOnIt, tellProgress, ding,
             speakSpoken, speakTyped, typedReadAsText, panelOpens, panelStays,
             typedOpensChat, hoverOpens, premium

        /// The key in config.json this control writes.
        var configKey: String {
            switch self {
            case .talkKey: return "talkKey"
            case .heyMoe: return "wakeWordEnabled"
            case .keepListening: return "conversationMode"
            case .waitsFor: return "followUpSeconds"
            case .whenQuiet: return "closeOffer"
            case .interrupt: return "bargeIn"
            case .answersOutLoud: return "speakReplies"
            case .voice: return "ttsVoice"
            case .replyLength: return "replyLength"
            case .shortcut: return "hotKeyModifiers"
            case .language: return "locale"
            case .alsoAfterHold: return "holdOpensConversation"
            case .sayOnIt: return "instantAck"
            case .tellProgress: return "spokenProgress"
            case .ding: return "replyChime"
            case .speakSpoken: return "speakSpokenReplies"
            case .speakTyped: return "speakTypedReplies"
            case .typedReadAsText: return "typedRepliesReadAsText"
            case .panelOpens: return "panelOnReply"
            case .panelStays: return "replyReadingSeconds"
            case .typedOpensChat: return "typedAnswersOpenChat"
            case .hoverOpens: return "notchHoverOpens"
            case .premium: return "cloudVoice"
            }
        }

        /// Behind "More" rather than on the page.
        var inMore: Bool {
            switch self {
            case .talkKey, .heyMoe, .keepListening, .waitsFor, .whenQuiet, .interrupt,
                 .answersOutLoud, .voice, .replyLength: return false
            default: return true
            }
        }
    }

    // MARK: - What a switch opens

    /// The inline controls under a main switch, shown only while it is on.
    enum Reveal: Hashable, CaseIterable {
        /// Under "Or just say “Hey Moe”": Teach Moe how you say it.
        case teachName
        /// Under "Keep listening after Moe answers": Waits for, When you go quiet.
        case listeningWindow
        /// Under "Let me interrupt Moe by talking": Check my microphone and speakers.
        case interruptCheck
        /// Under "Answers": the voice, only when they are out loud.
        case voice
    }

    /// Which reveals are open for this configuration. The page draws
    /// exactly these; nothing else decides whether a sub-control shows.
    static func reveals(heyMoe: Bool, config: Config) -> Set<Reveal> {
        var open: Set<Reveal> = []
        if heyMoe { open.insert(.teachName) }
        if config.conversationMode { open.insert(.listeningWindow) }
        if config.bargeIn { open.insert(.interruptCheck) }
        if config.speakReplies { open.insert(.voice) }
        return open
    }

    var reveals: Set<Reveal> { Self.reveals(heyMoe: conductor.alwaysListening, config: config) }

    // MARK: - The bindings

    var talkKey: Binding<TalkKey> {
        let c = conductor
        return Binding(get: { c.config.talkKey }, set: { c.setTalkKey($0) })
    }
    /// The live flag, which `setAlwaysListening` keeps with the saved one.
    var heyMoe: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.alwaysListening }, set: { c.setAlwaysListening($0) })
    }
    var keepListening: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.conversationMode }, set: { c.setConversationMode($0) })
    }
    /// Seconds, as a string for the segments.
    var waitsFor: Binding<String> {
        let c = conductor
        return Binding(get: { String(Int(c.config.followUpSeconds)) },
                       set: { if let s = Double($0) { c.setFollowUpSeconds(s) } })
    }
    var whenQuiet: Binding<String> {
        let c = conductor
        return Binding(get: { c.config.closeOffer }, set: { c.setCloseOffer($0) })
    }
    var interrupt: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.bargeIn }, set: { c.setBargeIn($0) })
    }
    /// "loud" or "screen": the master switch for speech.
    var answers: Binding<String> {
        let c = conductor
        return Binding(get: { c.config.speakReplies ? "loud" : "screen" },
                       set: { c.setSpeakReplies($0 == "loud") })
    }
    var replyLength: Binding<String> {
        let c = conductor
        return Binding(get: { ReplyLength(configValue: c.config.replyLength).rawValue },
                       set: { if let l = ReplyLength(rawValue: $0) { c.setReplyLength(l) } })
    }
    var shortcut: Binding<UInt32> {
        let c = conductor
        return Binding(get: { c.config.hotKeyModifiers }, set: { c.setHotKeyModifiers($0) })
    }
    var language: Binding<String> {
        let c = conductor
        return Binding(get: { SpeechLanguages.entry(for: c.config.locale)?.locale ?? c.config.locale },
                       set: { c.setLanguage($0) })
    }
    var alsoAfterHold: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.holdOpensConversation }, set: { c.setHoldOpensConversation($0) })
    }
    var sayOnIt: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.instantAck }, set: { c.setInstantAck($0) })
    }
    var tellProgress: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.spokenProgress }, set: { c.setSpokenProgress($0) })
    }
    var ding: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.replyChime }, set: { c.setReplyChime($0) })
    }
    var speakSpoken: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.speakSpokenReplies }, set: { c.setSpeakSpokenReplies($0) })
    }
    var speakTyped: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.speakTypedReplies }, set: { c.setSpeakTypedReplies($0) })
    }
    var typedReadAsText: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.typedRepliesReadAsText }, set: { c.setTypedRepliesReadAsText($0) })
    }
    var panelOpens: Binding<PanelReveal> {
        let c = conductor
        return Binding(get: { PanelReveal(configValue: c.config.panelOnReply) }, set: { c.setPanelOnReply($0) })
    }
    var panelStays: Binding<Double> {
        let c = conductor
        return Binding(get: { c.config.replyReadingSeconds }, set: { c.setReplyReadingSeconds($0) })
    }
    var typedOpensChat: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.typedAnswersOpenChat }, set: { c.setTypedAnswersOpenChat($0) })
    }
    var hoverOpens: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.notchHoverOpens }, set: { c.setNotchHoverOpens($0) })
    }
    var premium: Binding<Bool> {
        let c = conductor
        return Binding(get: { c.config.cloudVoice }, set: { c.setCloudVoice($0) })
    }

    // MARK: - Choices

    /// The listening window's lengths. A saved value outside the list (the
    /// file allows 2–120) is offered too, so opening the page never
    /// silently changes it.
    nonisolated static func waitChoices(current: Double) -> [Int] {
        var all = [8, 12, 16, 20, 30]
        let now = Int(current)
        if !all.contains(now) { all.append(now); all.sort() }
        return all
    }

    /// Zero is the one that is not a duration: the panel waits to be
    /// dismissed (`ReplyReveal.readingTime(seconds:)` reads below one
    /// second that way).
    nonisolated static let readingChoices: [Double] = [6, 12, 30, 0]

    nonisolated static func readingLabel(_ seconds: Double) -> String {
        seconds == 0 ? "Until I dismiss it" : "\(Int(seconds)) seconds"
    }
}

// MARK: - The page's quieter pieces

/// Rows without dividers, pill segments rather than outlined chips, and an
/// accent hairline for what a switch opens — the calmer look of design D.
enum Calm {
    /// Words on the left, the control on the right.
    struct Row<Control: View>: View {
        let title: String
        var detail = ""
        @ViewBuilder var control: Control
        @Environment(\.settingSpotlight) var spotlight

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Space.base) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Typo.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                    if !detail.isEmpty {
                        Text(detail).font(Theme.Typo.prose(12.5)).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Theme.measure, alignment: .leading)
                    }
                }
                Spacer(minLength: Theme.Space.base)
                control.padding(.top, 1)
            }
            .padding(.vertical, 9)
            .settingSpotlight(title, lit: spotlight == title)
        }
    }

    /// A pill track with the chosen answer raised.
    struct Segments<ID: Hashable>: View {
        let options: [(ID, String)]
        @Binding var selection: ID

        var body: some View {
            HStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let on = option.0 == selection
                    Button { selection = option.0 } label: {
                        Text(option.1)
                            .font(Theme.Typo.ui(12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.ink : Theme.ink2)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Theme.raised : Color.clear)
                                .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.sidebar))
            .fixedSize()
        }
    }

    /// What a switch opens: indented under it, a hairline in the accent.
    struct Reveal<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Space.base) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.35)).frame(width: 2)
                VStack(alignment: .leading, spacing: 0) { content }
            }
            .padding(.leading, 2)
            .padding(.bottom, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A section's name: sentence case, not the uppercase label.
    static func header(_ text: String) -> some View {
        Text(text).font(Theme.Typo.heading(15)).foregroundStyle(Theme.ink)
            .padding(.bottom, 2)
    }

    /// "More" as a line with a chevron.
    struct MoreToggle: View {
        @Binding var open: Bool
        let hint: String

        var body: some View {
            Button { open.toggle() } label: {
                HStack(spacing: Theme.Space.small) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 12)
                        .accessibilityLabel(open ? "Expanded" : "Collapsed")
                    Text("More").font(Theme.Typo.ui(13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(hint).font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
    }
}
