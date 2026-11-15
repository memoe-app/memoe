import Foundation

/// How bytes reach a `.part` file. A protocol so the fetcher's rules can be
/// tested without a network; `URLSessionComponentTransport` is the real one,
/// and its own tests drive it against a stub server that honours `Range`.
public protocol ComponentTransport: Sendable {
    /// Brings `part` up to the whole of `url`.
    ///
    /// `part` may already hold the first bytes of an earlier attempt; the
    /// transport asks the server for the rest and appends. If the server
    /// will not resume, it starts the file again from nothing. Either way,
    /// on return `part` holds what the server sent and the result says which
    /// happened — the caller needs to know, because a hash mismatch after a
    /// resume may be the old half's fault and deserves one clean retry.
    ///
    /// `progress` is called with the number of bytes now in `part`.
    func download(_ url: URL, to part: URL, allowExpensive: Bool,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> ComponentDownload
}

public enum ComponentDownload: Sendable, Equatable {
    /// The file was written from byte 0.
    case fresh
    /// The server continued from where `part` left off.
    case resumed
}

/// What a transport throws. `ComponentFetcher` turns these into
/// `ComponentError`, which is what a person is shown.
public enum ComponentTransportError: Error, Equatable {
    /// No route: offline, DNS, captive portal, or a metered link the
    /// background top-up is not allowed to use.
    case unreachable(String)
    /// The connection dropped part-way. What arrived is still in `part`.
    case interrupted(String)
    /// The server answered, and not with the file.
    case status(Int)
}

/// The real transport: one `URLSession` data task per file, written to disk
/// as it arrives, `Range` when there is something to continue.
public final class URLSessionComponentTransport: ComponentTransport {
    private let configuration: URLSessionConfiguration

    /// `configuration` exists for the tests, which install a stub protocol.
    public init(configuration: URLSessionConfiguration? = nil) {
        let c = configuration ?? .ephemeral
        // Fail now when there is no network, rather than wait for one: the
        // caller's whole job is to say so honestly and carry on without.
        c.waitsForConnectivity = false
        // An idle limit, not a total: a 100 MB file on a slow link is fine,
        // a link that has gone silent for half a minute is not.
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        self.configuration = c
    }

    public func download(_ url: URL, to part: URL, allowExpensive: Bool,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> ComponentDownload {
        let have = Self.length(of: part)
        do {
            return try await attempt(url, to: part, from: have, allowExpensive: allowExpensive,
                                     progress: progress)
        } catch ComponentTransportError.status(416) where have > 0 {
            // "Range not satisfiable": the part file is as long as the whole
            // file, or longer. It is not something to continue; start again.
            try? FileManager.default.removeItem(at: part)
            return try await attempt(url, to: part, from: 0, allowExpensive: allowExpensive,
                                     progress: progress)
        }
    }

    private func attempt(_ url: URL, to part: URL, from offset: Int64, allowExpensive: Bool,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> ComponentDownload {
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = allowExpensive
        request.allowsConstrainedNetworkAccess = allowExpensive
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        // A model is opaque bytes; a transparently re-encoded body would
        // make Content-Range and the bytes on disk disagree.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let sink = Sink(part: part, offset: offset, progress: progress)
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<ComponentDownload, Error>) in
                sink.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func length(of file: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Writes the body to disk as it arrives. One per download; URLSession
    /// calls a delegate serially on its own queue, so the state needs no lock.
    private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let part: URL
        let offset: Int64
        let progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<ComponentDownload, Error>?
        private var handle: FileHandle?
        private var written: Int64 = 0
        private var outcome: ComponentDownload = .fresh
        private var failure: Error?

        init(part: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.part = part
            self.offset = offset
            self.progress = progress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            do {
                switch status {
                case 206 where offset > 0:
                    // The server continued. Trust it only if it says it
                    // continued from where this file ends: a range that
                    // starts anywhere else, appended, is a corrupt file.
                    let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard range.hasPrefix("bytes \(offset)-") else {
                        throw ComponentTransportError.interrupted("the server resumed at the wrong place (\(range))")
                    }
                    let h = try FileHandle(forWritingTo: part)
                    try h.seekToEnd()
                    handle = h
                    written = offset
                    outcome = .resumed
                case 200:
                    // The whole file — either nothing was asked to be
                    // skipped, or the server ignored the range. Start over.
                    try FileManager.default.createDirectory(at: part.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                    handle = try FileHandle(forWritingTo: part)
                    written = 0
                    outcome = .fresh
                default:
                    throw ComponentTransportError.status(status)
                }
                completionHandler(.allow)
            } catch {
                failure = error
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil, let handle else { return }
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                progress(written)
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close()
            handle = nil
            let c = continuation
            continuation = nil
            if let failure {
                c?.resume(throwing: failure)
            } else if let error {
                c?.resume(throwing: Self.translate(error, receivedAny: written > offset))
            } else {
                c?.resume(returning: outcome)
            }
        }

        static func translate(_ error: Error, receivedAny: Bool) -> Error {
            guard let e = error as? URLError else { return error }
            if e.code == .cancelled { return CancellationError() }
            let said = e.localizedDescription
            switch e.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
                return ComponentTransportError.unreachable(said)
            case .timedOut where !receivedAny:
                return ComponentTransportError.unreachable(said)
            default:
                return ComponentTransportError.interrupted(said)
            }
        }
    }
}
