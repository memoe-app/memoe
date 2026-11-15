import Foundation

/// The app's half of `moe_location` (moe-home/hermes-plugins/moe-screen/location.py).
///
/// The plugin makes a named pipe only this user can open, and posts a
/// distributed notification whose object is `{"reply": <pipe>, "precise": bool}`.
/// The app answers down the pipe. A pipe, not a file: the answer goes from
/// this process's memory to the tool's and is never on disk.
///
/// Any process on this Mac can post that notification, so — as with
/// `openSettingsForBrain` — the app's own check is the one that counts: a
/// turn the person started must be in flight with a `moe_location` step
/// running in it. Anything else gets the refusal sentence and no place, and
/// macOS's question is never raised for it.
@MainActor
final class LocationBridge {
    /// Kept equal to SIGNAL in moe-home/hermes-plugins/moe-screen/location.py.
    static let signal = Notification.Name("com.moe.location")

    /// Made on first use; replaced in tests so CoreLocation is never touched.
    lazy var service = LocationService(provider: CoreLocationProvider())
    /// Whether the person's own turn has a `moe_location` step running.
    var stepRunning: () -> Bool = { false }
    var log: (String) -> Void = { Log.write($0) }
    /// The step event and the plugin's signal travel separately and the
    /// signal can win. How long to give the step to show up.
    var stepGrace: TimeInterval = 2
    private var observer: NSObjectProtocol?

    static func isLocationTool(_ name: String) -> Bool {
        name == "moe_location" || name.hasSuffix("__moe_location")
    }

    func watch() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.signal, object: nil, queue: .main) { [weak self] note in
            guard let request = note.object as? String else { return }
            Task { @MainActor in await self?.handle(request: request) }
        }
    }

    struct Request: Equatable {
        var reply: String
        var precise: Bool

        init?(_ raw: String) {
            guard raw.utf8.count <= 2048,
                  let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let reply = obj["reply"] as? String, reply.hasPrefix("/") else { return nil }
            self.reply = reply
            self.precise = obj["precise"] as? Bool ?? false
        }
    }

    /// The answer for a request, gate included. What `handle` writes.
    func answer(precise: Bool) async -> LocationAnswer {
        var waited: TimeInterval = 0
        while !stepRunning(), waited < stepGrace {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard stepRunning() else {
            log("location: refused — no moe_location step in a turn of the person's")
            return .refused
        }
        return await service.answer(precise: precise)
    }

    func handle(request raw: String) async {
        guard let request = Request(raw) else {
            log("location: refused — not a request")
            return
        }
        let answer = await answer(precise: request.precise)
        guard var data = try? JSONSerialization.data(withJSONObject: answer.json, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !Self.write(data, toPipe: request.reply) {
            log("location: nobody was reading the reply")
        }
    }

    /// Writes only into a FIFO this user owns and nobody else can open —
    /// never creates anything, never follows a link, never a regular file.
    static func write(_ data: Data, toPipe path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFIFO,
              st.st_uid == getuid(),
              st.st_mode & 0o077 == 0 else { return false }
        return data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count
    }
}
