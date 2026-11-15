import CryptoKit
import Foundation

/// What a person is told when a component cannot be had. Whole sentences, in
/// their words: these reach meeting notes and the log as they are.
public enum ComponentError: LocalizedError, Equatable {
    /// No network (or only a metered one, for a background top-up).
    case offline(component: String, size: String, without: String)
    /// The connection dropped. What arrived is kept for the next attempt.
    case interrupted(component: String, without: String)
    /// A file was not the file this build pins. Nothing was installed.
    case hashMismatch(component: String, file: String)
    /// The host answered with something other than the file.
    case server(component: String, status: Int)
    /// The disk refused: full, read-only, permissions.
    case disk(component: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .offline(component, size, without):
            return "Memoe needs to download \(component) (\(size)) and this Mac is offline. \(without) Memoe will try again later."
        case let .interrupted(component, without):
            return "The download of \(component) was interrupted. \(without) What arrived is kept, and the download picks up from there next time."
        case let .hashMismatch(component, file):
            return "The download of \(component) did not match what this version of Memoe expects (\(file)), so it was thrown away and nothing was installed."
        case let .server(component, status):
            return "Memoe could not download \(component): the server answered \(status). Memoe will try again later."
        case let .disk(component, detail):
            return "Memoe could not save \(component) to this Mac: \(detail)"
        }
    }
}

/// Puts an on-demand component where the app looks for it: fetched over the
/// network, every file checked against its pinned sha256, resumable, and
/// never fetched when it is already there.
///
/// The one fetcher for every component. An actor so two callers wanting the
/// same component — a warm-up and a first use, a second apart — share one
/// download rather than racing two into the same files.
public actor ComponentFetcher {

    /// The fetcher the app uses.
    public static let shared = ComponentFetcher(transport: URLSessionComponentTransport())

    public enum Outcome: Sendable, Equatable {
        /// It was already complete on this Mac. Nothing was fetched.
        case alreadyPresent
        /// It was fetched, verified, and installed just now.
        case fetched
    }

    public enum Presence: Sendable, Equatable {
        /// Every file is there at its pinned size (a real folder, or a link
        /// into an app that carries it).
        case present
        /// Nothing at all.
        case absent
        /// A link to a model inside an app that no longer has it — what a
        /// full build leaves behind when a slim one replaces it.
        case danglingLink
        /// A folder (or a link to one) with files missing or the wrong size.
        case incomplete
    }

    public enum Reason: Sendable {
        /// Something the person is doing needs it now. Any network will do.
        case needed
        /// A quiet top-up in the background, so it is there before it is
        /// needed. Never on a metered or Low Data Mode connection.
        case topUp
    }

    private let transport: ComponentTransport
    private var inFlight: [String: Task<Outcome, Error>] = [:]

    public init(transport: ComponentTransport) {
        self.transport = transport
    }

    // MARK: - Is it there?

    /// Cheap: a stat per file, no hashing. Sizes rather than hashes because
    /// this runs before every use, and a 100 MB hash before each dictation
    /// is a tax nobody agreed to. Bytes are hashed once, when they arrive.
    public nonisolated static func presence(of component: Component, in root: URL) -> Presence {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(component.folder, isDirectory: true)
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil
        // fileExists follows links: false for a link whose target is gone.
        guard fm.fileExists(atPath: folder.path) else { return isLink ? .danglingLink : .absent }
        for file in component.files {
            let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(file.path).path)
            guard (attrs?[.size] as? NSNumber)?.int64Value == file.bytes else { return .incomplete }
        }
        return .present
    }

    // MARK: - Make it be there

    /// Returns once the component is complete under `root`, fetching what is
    /// missing. Throws a `ComponentError` — whose description is fit to show
    /// a person — when it cannot be.
    @discardableResult
    public func ensure(_ component: Component, in root: URL, why: Reason = .needed,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Outcome {
        // Already there: answer without a task, a lock or a network call.
        if Self.presence(of: component, in: root) == .present { return .alreadyPresent }

        let key = root.appendingPathComponent(component.folder).standardizedFileURL.path
        if let running = inFlight[key] { return try await running.value }
        let transport = transport
        let task = Task { try await Self.fetch(component, in: root, why: why,
                                               transport: transport, progress: progress) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Where a download is staged before it is installed. Beside the
    /// destination so the final move is a rename on one volume; a dot-name so
    /// FluidAudio, which lists this directory, never mistakes it for a model.
    public nonisolated static func staging(for component: Component, in root: URL) -> URL {
        root.appendingPathComponent(".memoe-fetch", isDirectory: true)
            .appendingPathComponent(component.folder, isDirectory: true)
    }

    private static func fetch(_ component: Component, in root: URL, why: Reason,
                              transport: ComponentTransport,
                              progress: (@Sendable (Double) -> Void)?) async throws -> Outcome {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(component.folder, isDirectory: true)
        let staging = staging(for: component, in: root)
        let title = component.title

        func disk(_ error: Error) -> ComponentError {
            .disk(component: title, detail: error.localizedDescription)
        }

        switch presence(of: component, in: root) {
        case .present:
            return .alreadyPresent
        case .danglingLink:
            // Removing a link removes the link, never a model. And nothing
            // can be downloaded "into" a link whose target is gone.
            do { try fm.removeItem(at: folder) } catch { throw disk(error) }
        case .absent, .incomplete:
            break
        }

        // An incomplete link into a live app is not ours to write through:
        // that would be writing inside a signed bundle. It cannot happen
        // with a bundle build.sh made; if it somehow does, the app's copy
        // is left alone and a real folder takes the link's place.
        if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil {
            do { try fm.removeItem(at: folder) } catch { throw disk(error) }
        }

        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { throw disk(error) }

        // 1. Every file, verified, in the staging folder — or already
        //    verified in the destination, which a half-finished install or
        //    FluidAudio's own earlier download may have left.
        let total = max(component.bytes, 1)
        var done: Int64 = 0
        var toInstall: [ComponentFile] = []
        for file in component.files {
            try Task.checkCancellation()
            let installed = folder.appendingPathComponent(file.path)
            let staged = staging.appendingPathComponent(file.path)
            if verified(installed, is: file) {
                done += file.bytes
                progress?(Double(done) / Double(total))
                continue
            }
            if !verified(staged, is: file) {
                let base = done
                try await download(file, of: component, to: staged, why: why, transport: transport) { got in
                    progress?(Double(base + min(got, file.bytes)) / Double(total))
                }
            }
            toInstall.append(file)
            done += file.bytes
            progress?(Double(done) / Double(total))
        }

        // 2. Install. Only now, with every byte checked, does anything
        //    appear where the app looks. When the destination does not exist
        //    it is one rename; otherwise the verified files are moved in over
        //    what is there and anything else in the folder is left alone.
        do {
            if !fm.fileExists(atPath: folder.path) && toInstall.count == component.files.count {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try fm.moveItem(at: staging, to: folder)
            } else {
                for file in toInstall {
                    let to = folder.appendingPathComponent(file.path)
                    try fm.createDirectory(at: to.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                    try fm.moveItem(at: staging.appendingPathComponent(file.path), to: to)
                }
                try? fm.removeItem(at: staging)
            }
        } catch { throw disk(error) }
        // The parent, when this was the last thing in it.
        let parent = staging.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? fm.removeItem(at: parent)
        }

        guard presence(of: component, in: root) == .present else {
            throw ComponentError.disk(component: title,
                                      detail: "the files were downloaded but are not all in place")
        }
        return .fetched
    }

    /// One file into `staged`, by way of `staged + ".part"`.
    private static func download(_ file: ComponentFile, of component: Component, to staged: URL,
                                 why: Reason, transport: ComponentTransport,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        let part = staged.appendingPathExtension("part")
        let title = component.title
        do { try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw ComponentError.disk(component: title, detail: error.localizedDescription) }

        // A part file longer than the file can only be wrong.
        if URLSessionComponentTransport.length(of: part) > file.bytes { try? fm.removeItem(at: part) }

        // Twice at most: a mismatch after a *resume* may be the fault of the
        // half that was already on disk, so that earns one clean download.
        // A mismatch on a clean download is the server's bytes being wrong,
        // and asking again would only be hoping.
        for attempt in 0..<2 {
            let how: ComponentDownload
            do {
                how = try await transport.download(component.url(for: file), to: part,
                                                   allowExpensive: why == .needed, progress: progress)
            } catch let e as ComponentTransportError {
                switch e {
                case .unreachable:
                    throw ComponentError.offline(component: title, size: component.size,
                                                 without: component.without)
                case .interrupted:
                    throw ComponentError.interrupted(component: title, without: component.without)
                case let .status(code):
                    try? fm.removeItem(at: part)
                    throw ComponentError.server(component: title, status: code)
                }
            } catch let e as CancellationError {
                throw e
            } catch {
                throw ComponentError.disk(component: title, detail: error.localizedDescription)
            }

            if verified(part, is: file) {
                do {
                    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                    try fm.moveItem(at: part, to: staged)
                } catch { throw ComponentError.disk(component: title, detail: error.localizedDescription) }
                return
            }
            // Wrong bytes never stay on disk, whatever happens next.
            try? fm.removeItem(at: part)
            if how == .resumed && attempt == 0 { continue }
            break
        }
        throw ComponentError.hashMismatch(component: title, file: file.path)
    }

    /// Size first (free), then the sha256 of every byte.
    nonisolated static func verified(_ url: URL, is file: ComponentFile) -> Bool {
        guard URLSessionComponentTransport.length(of: url) == file.bytes,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return sha256(of: url) == file.sha256
    }

    public nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` answers nil at the end of the file and
            // throws on a real error; `try?` would fold the two together and
            // make every finished file "unreadable".
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The release before the slim one

    public enum Kept: Sendable, Equatable {
        /// It was a link into this app and is now a real folder of its own.
        case copiedOut
        /// Already a real folder, or not there at all: nothing to do.
        case nothingToDo
        /// The app's copy did not match the manifest, so the link was left.
        case refused(String)
    }

    /// Turns a link into the app's own copy of a component into a real
    /// folder, so the component survives the app that carried it.
    ///
    /// This is what makes the move to a slim build lose nothing. A full
    /// build links the cache at models inside the bundle; a slim build has
    /// no such models, so after the update the link would point at nothing
    /// and the person would re-download what they already had. Run by the
    /// `prepare` release, this copies the model out first. On APFS the copy
    /// is a clone — no second copy of the bytes while the app still has them.
    ///
    /// Verified against the manifest before the link is touched: a folder
    /// that will never be fetched again has to be the right one.
    public nonisolated static func keep(_ component: Component, in root: URL) -> Kept {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(component.folder, isDirectory: true)
        guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil,
              fm.fileExists(atPath: folder.path) else { return .nothingToDo }
        let source = folder.resolvingSymlinksInPath()
        let copy = root.appendingPathComponent(".memoe-fetch", isDirectory: true)
            .appendingPathComponent(component.folder + ".keeping", isDirectory: true)
        // The staging parent goes when this was the last thing in it —
        // refused or not. A full disk used to leave an empty `.memoe-fetch`
        // behind at every launch (measured on a 10 MB volume, 2026-11-12).
        defer {
            let parent = copy.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? fm.removeItem(at: parent)
            }
        }
        do {
            try? fm.removeItem(at: copy)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: copy)
            for file in component.files where !verified(copy.appendingPathComponent(file.path), is: file) {
                try? fm.removeItem(at: copy)
                return .refused("\(file.path) in the app is not the pinned file")
            }
            // If this is interrupted between the two lines below, the folder
            // is simply absent: the next launch links it again and tries again.
            try fm.removeItem(at: folder)
            do {
                try fm.moveItem(at: copy, to: folder)
            } catch {
                // Not interrupted — refused. This run still needs the model,
                // and without the link a loader would go and download what
                // the app is carrying. Put back exactly what was there.
                try? fm.createSymbolicLink(at: folder, withDestinationURL: source)
                throw error
            }
        } catch {
            try? fm.removeItem(at: copy)
            return .refused(error.localizedDescription)
        }
        return .copiedOut
    }
}
