import AppKit
import MoeDesign
import SwiftUI

/// The switch this page draws. The system `.switch` style takes its "on"
/// colour from the tint only when AppKit draws it live; rendered offscreen
/// (and so in every `--settings-snapshot` picture) an on switch came out the
/// same grey as an off one, and a consent switch whose two states cannot be
/// told apart at a glance is the one switch that must never look like that.
/// So the track is drawn: the accent when on, the rule colour when off, in
/// both appearances, and the knob sits on the side it means.
struct PrivacySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Theme.rule)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Theme.ink3.opacity(0.35),
                                                    lineWidth: 1))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .frame(width: 38, height: 22)
            .calmAnimation(Theme.Motion.easeOut, value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// A Settings › Privacy switch only a person can flip (D9.14). The set goes
/// through `.humanOnly`: a person's click inside the switch, or Return/Space
/// on it, flips it; an accessibility press or a posted event runs nothing and
/// asks the person to confirm with Touch ID or the login password. The probe
/// behind the switch is its place in the window, for the hit-test.
struct HumanLever: View {
    let control: String
    let value: Binding<Bool>
    var enabled = true
    @State private var place = HumanPressPlace()
    @State private var refused = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Toggle("", isOn: value.humanOnly(control, place: place, refused: $refused))
                .labelsHidden()
                .toggleStyle(PrivacySwitchStyle())
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
                .background(HumanPressProbe(place))
            if refused {
                Text(HumanOnly.note)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink2)
                    .accessibilityIdentifier("human-only-note")
            }
        }
    }
}
