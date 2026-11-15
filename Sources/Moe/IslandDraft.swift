import MoeChat
import SwiftUI

/// What is half-typed into the island's ask field.
///
/// It was `@State` on `IslandView`, which is the right place for it right up
/// until something outside the view has to know about it. The clock that
/// folds a self-opened panel does: a panel that took itself away while
/// somebody was part-way through typing a question into it would be worse
/// than one that never opened. docs/PANEL-FINDINGS.md §7.
///
/// A side effect worth having: the draft now survives the panel being rebuilt
/// — which it is, on every state change the island observes.
@MainActor
final class IslandDraft: ObservableObject {
    @Published var text = ""
    /// Photos and files waiting to go with it — added with the field's +, or
    /// dropped on the notch.
    @Published var attachments: [ChatAttachment] = []
    /// The ⋯ has slid its controls out. Here, not `@State` on the view, for
    /// the same reason as the text: on a floating capsule's compact card
    /// (`IslandView.trayInHeader`) the controls take a row only while they
    /// are out, so `NotchIsland` has to know to size the card for it.
    @Published var trayOpen = false
    /// Answers whose folded steps line has been opened, by row id. Here so
    /// `NotchIsland` sizes the card for the opened list.
    @Published var openSteps: Set<String> = []

    /// Something is waiting in the field, words or files. Holds a panel open.
    var inProgress: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}
