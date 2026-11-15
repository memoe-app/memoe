import Foundation
import Testing
@testable import MoeComponents

// The real transport, against a stub server that behaves like one: it reads
// the Range header and answers 206 with Content-Range, or 200, or 416. The
// fetcher's tests use a fake transport; these are what prove the code that
// actually talks HTTP appends where it should and starts over where it must.

final class StubServer: URLProtocol, @unchecked Sendable {
    struct Behaviour {
        var body = Data()
        /// Answer 200 with everything even when a Range was asked for.
        var ignoresRange = false
        /// Answer 206 but from the wrong byte.
        var liesAboutRange = false
        var status: Int? = nil
        /// Send this many bytes of the answer, then drop the connection.
        var dropAfter: Int? = nil
        var offline = false
    }
    private static let lock = NSLock()
    private static var hosts: [String: Behaviour] = [:]
    private static var seen: [String: [String?]] = [:]

    static func set(_ host: String, _ b: Behaviour) { lock.withLock { hosts[host] = b } }
    /// The Range header of every request to this host, in order.
    static func ranges(_ host: String) -> [String?] { lock.withLock { seen[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".stub") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url!.host!
        let range = request.value(forHTTPHeaderField: "Range")
        let b = Self.lock.withLock { () -> Behaviour in
            Self.seen[host, default: []].append(range)
            return Self.hosts[host] ?? Behaviour()
        }
        if b.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var status = 200
        var headers: [String: String] = [:]
        var payload = b.body
        if let forced = b.status {
            status = forced
            payload = Data()
        } else if let range, !b.ignoresRange, let from = Int(range.dropFirst("bytes=".count).dropLast()) {
            if from >= b.body.count {
                status = 416
                payload = Data()
            } else {
                status = 206
                let start = b.liesAboutRange ? from + 1 : from
                payload = b.body.dropFirst(from)
                headers["Content-Range"] = "bytes \(start)-\(b.body.count - 1)/\(b.body.count)"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let drop = b.dropAfter {
            client?.urlProtocol(self, didLoad: Data(payload.prefix(drop)))
            // A moment later, as a real connection dies: bytes that have
            // arrived are delivered before the failure, where a failure in
            // the same breath lets URLSession drop them undelivered.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: Data(payload))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct URLSessionTransportTests {

    let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })

    func make() -> (transport: URLSessionComponentTransport, host: String, url: URL, part: URL) {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        let host = "\(UUID().uuidString.lowercased()).stub"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-transport-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (URLSessionComponentTransport(configuration: c), host,
                URL(string: "https://\(host)/repo/resolve/abc/weights/weight.bin")!,
                dir.appendingPathComponent("weight.bin.part"))
    }

    @Test func aFreshDownloadWritesTheWholeBody() async throws {
        let t = make(); defer { try? FileManager.default.removeItem(at: t.part.deletingLastPathComponent()) }
        StubServer.set(t.host, .init(body: body))
        let got = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
        #expect(got == .fresh)
        #expect(try Data(contentsOf: t.part) == body)
        #expect(StubServer.ranges(t.host) == [nil])      // nothing to resume, no Range sent
    }

    @Test func aDroppedConnectionKeepsWhatArrivedAndTheNextCallContinues() async throws {
        let t = make(); defer { try? FileManager.default.removeItem(at: t.part.deletingLastPathComponent()) }
        StubServer.set(t.host, .init(body: body, dropAfter: 100_000))
        do {
            _ = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
            Issue.record("a dropped connection must throw")
        } catch let e as ComponentTransportError {
            guard case .interrupted = e else { Issue.record("expected interrupted, got \(e)"); return }
        }
        #expect(try Data(contentsOf: t.part) == body.prefix(100_000))

        StubServer.set(t.host, .init(body: body))
        let got = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
        #expect(got == .resumed)
        #expect(try Data(contentsOf: t.part) == body)
        #expect(StubServer.ranges(t.host) == [nil, "bytes=100000-"])
    }

    @Test func aServerThatIgnoresRangeGetsACleanFile() async throws {
        let t = make(); defer { try? FileManager.default.removeItem(at: t.part.deletingLastPathComponent()) }
        try Data(repeating: 0xee, count: 70_000).write(to: t.part)   // not the file's bytes
        StubServer.set(t.host, .init(body: body, ignoresRange: true))
        let got = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
        #expect(got == .fresh)
        // Not appended to the old 70 000: replaced.
        #expect(try Data(contentsOf: t.part) == body)
    }

    @Test func aPartAsLongAsTheFileIsStartedAgain() async throws {
        let t = make(); defer { try? FileManager.default.removeItem(at: t.part.deletingLastPathComponent()) }
        try Data(repeating: 0xee, count: body.count).write(to: t.part)
        StubServer.set(t.host, .init(body: body))
        let got = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
        #expect(got == .fresh)
        #expect(try Data(contentsOf: t.part) == body)
        #expect(StubServer.ranges(t.host) == ["bytes=300000-", nil])   // 416, then from zero
    }

    @Test func aResumeFromTheWrongByteIsNotAppended() async throws {
        let t = make(); defer { try? FileManager.default.removeItem(at: t.part.deletingLastPathComponent()) }
        try body.prefix(50_000).write(to: t.part)
        StubServer.set(t.host, .init(body: body, liesAboutRange: true))
        do {
            _ = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
            Issue.record("a 206 from the wrong offset must throw")
        } catch let e as ComponentTransportError {
            guard case .interrupted = e else { Issue.record("expected interrupted, got \(e)"); return }
        }
        #expect(try Data(contentsOf: t.part) == body.prefix(50_000))
    }

    @Test func offlineIsUnreachableAndNotFoundIsAStatus() async throws {
        let t = make(); defer { try? FileManager.default.removeItem(at: t.part.deletingLastPathComponent()) }
        StubServer.set(t.host, .init(offline: true))
        do {
            _ = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
            Issue.record("offline must throw")
        } catch let e as ComponentTransportError {
            guard case .unreachable = e else { Issue.record("expected unreachable, got \(e)"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: t.part.path))

        StubServer.set(t.host, .init(status: 404))
        await #expect(throws: ComponentTransportError.status(404)) {
            _ = try await t.transport.download(t.url, to: t.part, allowExpensive: true) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: t.part.path))
    }

    @Test func theFetcherOverTheRealTransportResumesAndVerifies() async throws {
        // End to end: the fetcher's rules and the HTTP code together.
        let f = Fixture(); defer { f.cleanUp() }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        let host = "\(UUID().uuidString.lowercased()).stub"
        let big = f.contents[f.big]!
        let one = Component(id: "one", folder: "one-model", title: "the test model", without: "Nothing else changes.",
                            base: URL(string: "https://\(host)/repo/resolve/abc/")!,
                            files: [ComponentFile("weights/weight.bin", Int64(big.count), Fixture.hex(big))])
        let fetcher = ComponentFetcher(transport: URLSessionComponentTransport(configuration: c))

        StubServer.set(host, .init(body: big, dropAfter: 90_000))
        await #expect(throws: ComponentError.interrupted(component: "the test model", without: "Nothing else changes.")) {
            try await fetcher.ensure(one, in: f.root)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("one-model").path))

        StubServer.set(host, .init(body: big))
        #expect(try await fetcher.ensure(one, in: f.root) == .fetched)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("one-model/weights/weight.bin")) == big)
        #expect(StubServer.ranges(host) == [nil, "bytes=90000-"])

        StubServer.set(host, .init(offline: true))
        #expect(try await fetcher.ensure(one, in: f.root) == .alreadyPresent)
        #expect(StubServer.ranges(host).count == 2)
    }
}
