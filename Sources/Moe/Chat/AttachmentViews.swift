import AppKit
import MoeChat
import MoeDesign
import SwiftUI

/// The photo itself, or the file's Finder icon, at a small size.
struct AttachmentThumbnail: View {
    let attachment: ChatAttachment
    var size: CGSize
    var corner: CGFloat = Theme.Radius.row
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: attachment.kind == .image ? .fill : .fit)
            } else {
                Theme.sunk
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: attachment.path) {
            image = await AttachmentIntake.thumbnail(
                for: attachment, maxPixel: Int(max(size.width, size.height) * 2))
        }
    }
}

// MARK: - Chat window

/// The + beside the message box: every place on this Mac a thing can come from.
struct AddAttachmentButton: View {
    let add: ([ChatAttachment]) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(open ? 45 : 0))
                .foregroundStyle(open ? Theme.onAccent : Theme.ink2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(open ? Theme.accent : hovering ? Theme.sunk : Theme.raised))
                .overlay(Circle().strokeBorder(open ? Theme.accent : Theme.ruleStrong,
                                               lineWidth: Theme.Stroke.hair))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.easeOut, value: open)
        .help("Add photos and files")
        .popover(isPresented: $open, arrowEdge: .top) {
            AttachmentSourceMenu { work in
                // The popover goes first: a file panel or the crosshair
                // opening underneath it would be half hidden.
                open = false
                Task {
                    let got = await work()
                    if !got.isEmpty { add(got) }
                }
            }
        }
    }
}

struct AttachmentSourceMenu: View {
    let run: (@escaping () async -> [ChatAttachment]) -> Void
    @State private var recent: [ChatAttachment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SourceRow(icon: "photo.on.rectangle", title: "Photos…", detail: "From your library") {
                run { await AttachmentIntake.pickPhotos() }
            }
            SourceRow(icon: "doc", title: "Files…", detail: "Anything on this Mac") {
                run { await AttachmentIntake.chooseFiles() }
            }
            SourceRow(icon: "camera.viewfinder", title: "Take a Screenshot",
                      detail: "Drag across what Moe should see") {
                run { await AttachmentIntake.screenshot() }
            }
            SourceRow(icon: "doc.on.clipboard", title: "Paste from Clipboard", detail: nil) {
                run { AttachmentIntake.take(from: .general) }
            }
            .disabled(!AttachmentIntake.canTake(.general))

            if !recent.isEmpty {
                Rectangle().fill(Theme.rule).frame(height: 1)
                    .padding(.vertical, Theme.Space.tight)
                    .padding(.horizontal, Theme.Space.snug)
                Text("Recent on this Mac")
                    .font(ChatType.section)
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, Theme.Space.small)
                    .padding(.bottom, Theme.Space.tight)
                ForEach(recent) { item in
                    RecentRow(item: item) { run { [item] } }
                }
            }
        }
        .padding(Theme.Space.snug)
        .frame(width: 290)
        .task { recent = await AttachmentIntake.recent(limit: 3) }
    }
}

private struct SourceRow: View {
    let icon: String
    let title: String
    let detail: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.base) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Typo.ui(13)).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, Theme.Space.snug)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(hovering && enabled ? Theme.selected : Color.clear))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let item: ChatAttachment
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.small) {
                AttachmentThumbnail(attachment: item, size: CGSize(width: 22, height: 22), corner: 4)
                    .frame(width: 20)
                Text(item.name)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.small)
                Text(item.url.deletingLastPathComponent().lastPathComponent)
                    .font(Theme.Typo.data(10))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, Theme.Space.tight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(hovering ? Theme.selected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.path)
    }
}

/// What is waiting to be sent, above the message box.
struct AttachmentTray: View {
    @Binding var attachments: [ChatAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.small) {
                ForEach(attachments) { item in
                    HStack(spacing: Theme.Space.small) {
                        AttachmentThumbnail(attachment: item, size: CGSize(width: 36, height: 36))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(Theme.Typo.ui(11, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(item.typeLabel) · \(item.sizeLabel)")
                                .font(Theme.Typo.data(10))
                                .foregroundStyle(Theme.ink3)
                        }
                        .frame(maxWidth: 140, alignment: .leading)
                        Button { attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.ink2)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Theme.sunk))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(item.name)")
                    }
                    .padding(Theme.Space.snug)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hair))
                }
            }
        }
    }
}

/// What went with a message, above its bubble. Click one to open it.
struct SentAttachments: View {
    let attachments: [ChatAttachment]

    var body: some View {
        let pictures = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind == .file }
        VStack(alignment: .trailing, spacing: Theme.Space.snug) {
            if !pictures.isEmpty {
                HStack(spacing: Theme.Space.snug) {
                    ForEach(pictures.prefix(3)) { picture in
                        Button { NSWorkspace.shared.open(picture.url) } label: {
                            AttachmentThumbnail(attachment: picture,
                                                size: pictures.count == 1
                                                    ? CGSize(width: 220, height: 165)
                                                    : CGSize(width: 132, height: 99),
                                                corner: Theme.Radius.control)
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hair))
                        }
                        .buttonStyle(.plain)
                        .help(picture.name)
                    }
                    if pictures.count > 3 {
                        Text("+\(pictures.count - 3)")
                            .font(Theme.Typo.ui(12, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.sunk))
                    }
                }
            }
            ForEach(files) { file in
                Button { NSWorkspace.shared.open(file.url) } label: {
                    HStack(spacing: Theme.Space.small) {
                        AttachmentThumbnail(attachment: file, size: CGSize(width: 30, height: 34), corner: 0)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .font(Theme.Typo.ui(12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(file.typeLabel) · \(file.sizeLabel)")
                                .font(Theme.Typo.data(10))
                                .foregroundStyle(Theme.ink3)
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    .padding(.vertical, Theme.Space.snug)
                    .padding(.leading, Theme.Space.snug)
                    .padding(.trailing, Theme.Space.base)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hair))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.path)
            }
        }
    }
}

// MARK: - Island

/// The island's +. A system menu rather than a popover: the island is a
/// borderless panel over the notch, and a menu is the one surface that sits
/// correctly on top of it and gives the pointer back where it found it.
struct IslandAddButton: View {
    @ObservedObject var draft: IslandDraft

    var body: some View {
        Menu {
            Button("Photos…") { run { await AttachmentIntake.pickPhotos() } }
            Button("Files…") { run { await AttachmentIntake.chooseFiles() } }
            Button("Take a Screenshot") { run { await AttachmentIntake.screenshot() } }
            Button("Paste from Clipboard") { run { AttachmentIntake.take(from: .general) } }
                .disabled(!AttachmentIntake.canTake(.general))
        } label: {
            IslandAddGlyph()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add photos and files")
    }

    private func run(_ work: @escaping () async -> [ChatAttachment]) {
        Task {
            let got = await work()
            if !got.isEmpty { draft.attachments.append(contentsOf: got) }
        }
    }
}

struct IslandAddGlyph: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.Island.ink)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.white.opacity(0.12)))
    }
}

/// What is waiting in the island's field, as chips above it.
struct IslandAttachmentChips: View {
    @ObservedObject var draft: IslandDraft

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(draft.attachments) { item in
                    HStack(spacing: 6) {
                        AttachmentThumbnail(attachment: item, size: CGSize(width: 18, height: 18), corner: 3)
                        Text(item.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Island.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150, alignment: .leading)
                        Button { draft.attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Theme.Island.ink3)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(item.name)")
                    }
                    .padding(.leading, 3)
                    .padding(.trailing, 5)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.10)))
                }
            }
        }
    }
}

/// A posed thread for `Moe --settings-snapshot <dir> main-chat`.
struct ChatTurnsPose: View {
    private let deck = ChatAttachment(path: "/Users/you/Desktop/Launch deck v4.key", byteCount: 18_400_000)
    private let notes = ChatAttachment(path: "/Users/you/Documents/Standup notes.pages", byteCount: 184_000)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            TurnRow(turn: Turn(role: .you, text: "What's on tomorrow before noon?"))
            TurnRow(turn: Turn(role: .moe,
                               text: "Two things.\nStandup with Dana at 9:30 — twenty minutes, on Zoom.\nThe dentist at 11:15. Route 4 is slow in the mornings, so leave by **10:50**.",
                               tools: ["Read your calendar", "Checked travel time"]))
            TurnRow(turn: Turn(role: .you, text: "Send Dana the decisions from these.",
                               attachments: [notes, deck]))
            TurnRow(turn: Turn(role: .system, text: "Still working on the last one — one sec."))
            TurnRow(turn: Turn(role: .moe,
                               text: "Drafted, not sent — it's in Mail waiting for you. I kept it to the three decisions and left the budget thread out."))
            Spacer(minLength: 0)
            AttachmentTray(attachments: .constant([deck, notes]))
                .padding(Theme.Space.base)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.edge))
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.wide)
    }
}
