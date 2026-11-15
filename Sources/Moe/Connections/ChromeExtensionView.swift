import AppKit
import MoeDesign
import SwiftUI

/// The Chrome row on the Connections list, beside the brain's.
struct ChromeExtensionRow: View {
    @ObservedObject var model: ChromeExtensionModel
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let state = model.state
        Button(action: select) {
            HStack(spacing: Theme.Space.small) {
                ServiceIcon(name: "chrome", label: "Chrome", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ChromeExtension.Copy.title)
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(model.word)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(state.good && model.fileAccessWarning == nil && !model.needsUpdate ? Theme.good
                                         : (state.warn || model.fileAccessWarning != nil || model.needsUpdate
                                            ? Theme.warn : Theme.ink3))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(selected ? Theme.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The right side for the Chrome row: the state, what it does in plain
/// words, and the one next thing — Set up, the three steps, or the switch.
struct ChromeExtensionDetail: View {
    @ObservedObject var model: ChromeExtensionModel

    var body: some View {
        let state = model.state
        // `PaneDetail`: the page scrolls and the buttons stay under it. The
        // three steps of the waiting state are the tallest thing this side
        // ever shows, and they used to push the buttons out of the window.
        PaneDetail {
          VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            HStack(alignment: .center, spacing: Theme.Space.cosy) {
                ServiceIcon(name: "chrome", label: "Chrome", size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ChromeExtension.Copy.title)
                        .font(Theme.Typo.heading(22))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: Theme.Space.small) {
                        Circle().fill(state.good ? Theme.good : (state.warn ? Theme.warn : Theme.ink3))
                            .frame(width: 7, height: 7)
                        Text(state.word)
                            .font(Theme.Typo.ui(12, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            if model.needsUpdate {
                Label(ChromeExtension.Copy.update, systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            if let why = model.why {
                Label(why, systemImage: state == .cantReach ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            if let warning = model.fileAccessWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                settingsLabel("What it does")
                prose(ChromeExtension.Copy.whatItDoes)
                prose(ChromeExtension.Copy.why, tone: Theme.ink3)
            }
            if state == .notInstalled, ChromeExtension.storeURL != nil, model.report?.hostInstalled == true,
               model.report?.enabled == true {
                // Add to Chrome was clicked: the listing is open in Chrome.
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    settingsLabel("In Chrome")
                    ForEach(Array(ChromeExtension.Copy.storeSteps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                            Text("\(i + 1)").font(Theme.Typo.ui(12, weight: .semibold)).foregroundStyle(Theme.ink3)
                            prose(step)
                        }
                    }
                    Text(ChromeExtension.Copy.storeFallback)
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state == .waiting, ChromeExtension.storeURL == nil {
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    settingsLabel("In Chrome's Extensions page")
                    ForEach(Array(ChromeExtension.Copy.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                            Text("\(i + 1)").font(Theme.Typo.ui(12, weight: .semibold)).foregroundStyle(Theme.ink3)
                            prose(step)
                        }
                    }
                    Text(ChromeExtension.Copy.pageFallback)
                        .font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state == .off {
                prose(ChromeExtension.Copy.offNote, tone: Theme.ink3)
            } else if !model.note.isEmpty {
                Text(model.note).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
          }
        } bar: {
            PaneActionBar {
                if model.needsUpdate {
                    PaneButton(title: model.busy ? "Updating…" : "Update", prominent: true, large: true) {
                        Task { await model.setUp() }
                    }
                }
                switch state {
                case .notInstalled:
                    PaneButton(title: model.busy ? "Setting up…"
                                   : (ChromeExtension.storeURL == nil ? "Set up" : "Add to Chrome"),
                               prominent: true, large: true) {
                        Task { await model.setUp() }
                    }
                case .waiting:
                    if ChromeExtension.storeURL == nil {
                        PaneButton(title: "Show folder", symbol: "folder", prominent: true, large: true) { model.showFolder() }
                        PaneButton(title: "Open Chrome's Extensions page", large: true) { model.openExtensionsPage() }
                    } else {
                        PaneButton(title: "Open Chrome", prominent: true, large: true) { model.openChromeExtensions() }
                    }
                    PaneButton(title: "Turn off", large: true) { Task { await model.setEnabled(false) } }
                case .cantReach:
                    PaneButton(title: model.busy ? "Repairing…" : "Repair", prominent: true, large: true) {
                        Task { await model.setUp(openChrome: false) }
                    }
                    PaneButton(title: "Turn off", large: true) { Task { await model.setEnabled(false) } }
                case .wrongProfile:
                    PaneButton(title: "Add to this profile", prominent: true, large: true) { model.openExtensionsPage() }
                    PaneButton(title: "Turn off", large: true) { Task { await model.setEnabled(false) } }
                case .connected:
                    PaneButton(title: "Turn off", large: true) { Task { await model.setEnabled(false) } }
                case .off:
                    PaneButton(title: "Turn on", prominent: true, large: true) { Task { await model.setEnabled(true) } }
                }
            } trailing: {
                EmptyView()
            }
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private func prose(_ text: String, tone: Color = Theme.ink2) -> some View {
        Text(text)
            .font(Theme.Typo.prose(13))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)
    }
}
