import AppKit
import MoeChat
import PhotosUI
import UniformTypeIdentifiers

/// Where the photos and files a person hands Moe come from, and how they are
/// made ready for the brain.
///
/// Everything ends as a path. A file from Finder is referenced where it
/// already is; anything without a file of its own — a photo out of the
/// library, a pasted image, a screenshot — is written under Moe's home first,
/// so the brain can open every attachment the same way and erasing Moe erases
/// these too.
@MainActor
enum AttachmentIntake {

    nonisolated static var inbox: URL {
        Paths.home.appendingPathComponent("attachments", isDirectory: true)
    }

    /// The pasteboard types a drop on the notch is offered in.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    // MARK: - From a path

    nonisolated static func attachment(for url: URL) -> ChatAttachment? {
        let url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ChatAttachment(path: url.path, byteCount: size)
    }

    /// A fresh folder per item, so two things both called "image.png" never
    /// overwrite each other and every name stays the one the person saw.
    nonisolated private static func freshFolder() throws -> URL {
        let dir = inbox.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased(),
                                               isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    nonisolated private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attachment" : cleaned
    }

    nonisolated static func keep(_ data: Data, named name: String) -> ChatAttachment? {
        do {
            let url = try freshFolder().appendingPathComponent(safeName(name))
            try data.write(to: url, options: .atomic)
            return attachment(for: url)
        } catch {
            Log.write("attachments: could not keep \(name): \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func keep(copyOf source: URL, named name: String) -> ChatAttachment? {
        do {
            let url = try freshFolder().appendingPathComponent(safeName(name))
            try FileManager.default.copyItem(at: source, to: url)
            return attachment(for: url)
        } catch {
            Log.write("attachments: could not keep \(name): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Pasteboard (Paste, and drops on the notch)

    static func canTake(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// Whether ⌘V in the box should attach rather than paste words: a file
    /// copied in Finder (whose name also rides along as text), or a picture
    /// with no text beside it — a screenshot, "Copy Image". Copied text that
    /// happens to carry a picture as well still pastes as text.
    static func pasteAttaches(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self],
                                    options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        guard pasteboard.availableType(from: [.png, .tiff]) != nil else { return false }
        return pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    static func take(from pasteboard: NSPasteboard) -> [ChatAttachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap(attachment(for:))
        }
        if let png = pasteboard.data(forType: .png) {
            return keep(png, named: "Pasted image \(stamp()).png").map { [$0] } ?? []
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return keep(png, named: "Pasted image \(stamp()).png").map { [$0] } ?? []
        }
        return []
    }

    // MARK: - Item providers (drops on the window, the photo picker)

    static func take(_ providers: [NSItemProvider]) async -> [ChatAttachment] {
        var taken: [ChatAttachment] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(from: provider),
               let item = attachment(for: url) {
                taken.append(item)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let item = await keepRepresentation(of: provider, as: .image) {
                taken.append(item)
            }
        }
        return taken
    }

    nonisolated private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
        }
    }

    nonisolated private static func keepRepresentation(of provider: NSItemProvider,
                                                       as type: UTType) async -> ChatAttachment? {
        await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The system deletes this file the moment the handler
                // returns, so it is copied now or never.
                guard let url else { done.resume(returning: nil); return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty {
                    name += "." + url.pathExtension
                }
                done.resume(returning: keep(copyOf: url, named: name))
            }
        }
    }

    // MARK: - The sources in the + menu

    static func chooseFiles() async -> [ChatAttachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose what to give Moe."
        // Moe is usually not the active app — the + is often pressed on the
        // island — and an open panel that appears behind the frontmost window
        // looks like a button that did nothing.
        //
        // Activating is not enough on its own. The popped-out chat floats
        // (`FloatingChatWindow.applyLevel`, `.floating`) on every desktop and
        // over full-screen apps, and an ordinary open panel opened from it
        // came up underneath it, or on another desktop than the full-screen
        // app in front — the owner pressed + there and nothing happened
        // (2026-11-14). So the panel sits above the chat and below the
        // island, and comes to the desktop the person is on.
        Self.raise(panel)
        NSApp.activate()
        let response = await withCheckedContinuation { done in
            panel.begin { done.resume(returning: $0) }
        }
        guard response == .OK else { return [] }
        return panel.urls.compactMap(attachment(for:))
    }

    /// Above the floating chat (`.floating`), below the island
    /// (status-window level), on the desktop in front — full-screen ones too.
    static func raise(_ panel: NSWindow) {
        panel.level = .modalPanel
        panel.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
    }

    /// `screencapture -i`: the same crosshair as ⇧⌘4, and Escape cancels.
    static func screenshot() async -> [ChatAttachment] {
        guard let dir = try? freshFolder() else { return [] }
        let url = dir.appendingPathComponent("Screenshot \(stamp()).png")
        let finished: Bool = await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", url.path]
            process.terminationHandler = { _ in done.resume(returning: true) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
        guard finished, let item = attachment(for: url) else {
            try? FileManager.default.removeItem(at: dir)
            return []
        }
        return [item]
    }

    /// The system photo picker. It runs outside Moe, so choosing photos needs
    /// no Photos permission and Moe never sees the rest of the library.
    static func pickPhotos() async -> [ChatAttachment] {
        let providers = await withCheckedContinuation { done in
            PhotoPickSession.present { done.resume(returning: $0) }
        }
        return await take(providers)
    }

    /// The newest few files in Downloads and on the Desktop — where the thing
    /// somebody means by "this" usually just landed.
    nonisolated static func recent(limit: Int) async -> [ChatAttachment] {
        await Task.detached(priority: .utility) { () -> [ChatAttachment] in
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey,
                                          .addedToDirectoryDateKey, .contentModificationDateKey]
            var found: [(date: Date, url: URL, size: Int)] = []
            for folder in ["Downloads", "Desktop"] {
                let dir = home.appendingPathComponent(folder, isDirectory: true)
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles])
                else { continue }
                for url in items {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    let date = values.addedToDirectoryDate ?? values.contentModificationDate ?? .distantPast
                    found.append((date, url, values.fileSize ?? 0))
                }
            }
            return found.sorted { $0.date > $1.date }.prefix(limit)
                .map { ChatAttachment(path: $0.url.path, byteCount: $0.size) }
        }.value
    }

    // MARK: - Pictures

    nonisolated static func downscaled(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The pictures that go to the model with a turn, as JPEG no longer than
    /// 1568 px on a side — the most the vision models read before they scale
    /// it down themselves, so anything larger is upload time for nothing.
    /// Those that do not decode are left out, and `brainNote` is told which
    /// did.
    static func pictures(for attachments: [ChatAttachment]) async -> [(id: String, image: ImageAttachment)] {
        guard !attachments.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [(id: String, image: ImageAttachment)] in
            attachments.compactMap { item -> (id: String, image: ImageAttachment)? in
                guard let cg = downscaled(item.url, maxPixel: 1568),
                      let jpeg = NSBitmapImageRep(cgImage: cg)
                        .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                else { return nil }
                return (item.id, ImageAttachment(data: jpeg, mediaType: "image/jpeg"))
            }
        }.value
    }

    /// A small image of an attachment: the photo itself, or the icon Finder
    /// shows for the file.
    static func thumbnail(for item: ChatAttachment, maxPixel: Int) async -> NSImage? {
        if item.kind == .image {
            let url = item.url
            let cg = await Task.detached(priority: .utility) { downscaled(url, maxPixel: maxPixel) }.value
            if let cg { return NSImage(cgImage: cg, size: .zero) }
        }
        return NSWorkspace.shared.icon(forFile: item.path)
    }

    nonisolated private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}

/// The system photo picker in a window of its own.
///
/// `PHPickerViewController` wants a view controller to present from, and the
/// + that asks for it is as often on the island — a borderless panel with no
/// controller — as in the chat window. A window of its own serves both.
@MainActor
private final class PhotoPickSession: NSObject, PHPickerViewControllerDelegate, NSWindowDelegate {
    /// Kept alive while the window is up; the picker holds its delegate weakly.
    private static var live: PhotoPickSession?
    private var window: NSWindow?
    private var done: (([NSItemProvider]) -> Void)?

    static func present(_ done: @escaping ([NSItemProvider]) -> Void) {
        live?.finish([])
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 0
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        let session = PhotoPickSession()
        session.done = done
        picker.delegate = session

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Choose Photos for Moe"
        window.contentViewController = picker
        window.isReleasedWhenClosed = false
        window.delegate = session
        window.center()
        session.window = window
        live = session
        AttachmentIntake.raise(window)      // above the floating chat, as the file panel
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        finish(results.map(\.itemProvider))
    }

    /// Closed with the red button: the picker never reports, so this does.
    func windowWillClose(_ notification: Notification) {
        finish([])
    }

    private func finish(_ providers: [NSItemProvider]) {
        guard let done else { return }
        self.done = nil
        done(providers)
        window?.delegate = nil
        window?.close()
        window = nil
        Self.live = nil
    }
}
