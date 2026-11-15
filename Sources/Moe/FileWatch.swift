import CoreServices
import Foundation

/// Told when files in one directory change, instead of asking every few
/// seconds.
///
/// Until 2026-11-12 the app asked three questions on a timer for as long as
/// it ran: has the noted log changed (a stat every 3 s), is anything in the
/// inbox (a directory read and a parse every 5 s), is there a `nudge.json`
/// (a read every 20 s). An idle Mac was woken some 2,000 times an hour to be
/// told no. This is those three, turned round: the file system says when.
///
/// Three things it has to get right, each of which a plain watcher gets
/// wrong on this app's own home:
///
/// - **The path goes through a symlink.** `~/.moe` is a link to
///   `~/Library/Application Support/Moe`, and events are reported for the
///   real path. The directory is resolved (`realpath`) before it is watched,
///   and events are matched against the resolved path.
/// - **The directory can be replaced.** A wipe, a restore or a migration
///   removes it and makes another; a watcher on the old one hears nothing
///   again, for ever, and says so to nobody. Every `safety` seconds the path
///   is resolved again and its identity (device and inode) compared; a
///   different directory is watched afresh.
/// - **A watcher can miss an event.** So the same tick also calls `onChange`,
///   which is the old poll at a twentieth of the rate: the worst case is
///   late, never lost.
///
/// A burst (a job writing eleven files, an atomic write's temp file and its
/// rename) is one call: events inside `coalesce` seconds of each other are
/// folded together.
final class FileWatch: @unchecked Sendable {

    /// The directory, as the app spells it. May be, or pass through, a link.
    let directory: URL
    private let accepts: (@Sendable (String) -> Bool)?
    private let coalesce: TimeInterval
    private let safety: TimeInterval
    private let retry: TimeInterval
    private let createIfMissing: Bool
    private let deliverOn: DispatchQueue
    /// Returns true to be asked again in `retry` seconds: there is work that
    /// is waiting on something other than a file (the app being busy).
    private let onChange: @Sendable () -> Bool

    // Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "moe.filewatch")
    private var stream: FSEventStreamRef?
    private var armed: Identity?
    private var timer: DispatchSourceTimer?
    private var firePending = false
    private var retryPending = false
    private var running = false

    /// Which directory is being watched: its real path, and which directory
    /// that is. Two directories at one path, one after the other, differ.
    struct Identity: Equatable {
        let path: String
        let device: UInt64
        let inode: UInt64

        init?(of url: URL) {
            guard let real = realpath(url.path, nil) else { return nil }
            defer { free(real) }
            var st = stat()
            guard stat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            path = String(cString: real)
            device = UInt64(bitPattern: Int64(st.st_dev))
            inode = UInt64(st.st_ino)
        }
    }

    /// - Parameters:
    ///   - directory: watched for changes to the files directly inside it.
    ///   - accepting: a file's name; nil for every file. Sub-directories'
    ///     contents never count.
    ///   - coalesce: events this close together are one call.
    ///   - safety: how often to check the directory is still the same one,
    ///     and to call `onChange` regardless.
    ///   - retry: how soon to call again when `onChange` returns true.
    ///   - createIfMissing: make the directory (0700) so there is something
    ///     to watch before its first writer has run.
    init(directory: URL, accepting: (@Sendable (String) -> Bool)? = nil,
         coalesce: TimeInterval = 0.25, safety: TimeInterval = 60, retry: TimeInterval = 5,
         createIfMissing: Bool = false, deliverOn: DispatchQueue = .main,
         onChange: @escaping @Sendable () -> Bool) {
        self.directory = directory
        self.accepts = accepting
        self.coalesce = coalesce
        self.safety = safety
        self.retry = retry
        self.createIfMissing = createIfMissing
        self.deliverOn = deliverOn
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
        if let stream { Self.end(stream) }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            arm()
            // Once at the start: whatever was written before anyone watched.
            scheduleFire()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + safety, repeating: safety, leeway: .milliseconds(Int(safety * 100)))
            t.setEventHandler { [weak self] in self?.safetyTick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            disarm()
        }
    }

    /// The directory being watched right now, or nil when there is none.
    var watching: Identity? { queue.sync { armed } }

    // MARK: Arming

    private func arm() {
        disarm()
        if createIfMissing, !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        guard let id = Identity(of: directory) else { return }
        let box = Unmanaged.passRetained(Box(self))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
        let made = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            guard let watch = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().watch else { return }
            let names = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let bits = Array(UnsafeBufferPointer(start: flags, count: count))
            watch.heard(names, bits)
        }, &context, [id.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
           min(coalesce, 0.1), FSEventStreamCreateFlags(flags))
        // The stream holds the box now (its `retain` ran); ours is given back.
        box.release()
        guard let made else { return }
        FSEventStreamSetDispatchQueue(made, queue)
        guard FSEventStreamStart(made) else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            return
        }
        stream = made
        armed = id
    }

    private func disarm() {
        if let stream { Self.end(stream) }
        stream = nil
        armed = nil
    }

    private static func end(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// The stream's callback, on `queue`.
    private func heard(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        guard running, let root = armed?.path else { return }
        var relevant = false
        var rootMoved = false
        for (i, path) in paths.enumerated() {
            let bits = i < flags.count ? Int(flags[i]) : 0
            if bits & kFSEventStreamEventFlagRootChanged != 0 { rootMoved = true; continue }
            // The kernel or the daemon dropped events: anything may have
            // happened, so ask.
            if bits & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped
                       | kFSEventStreamEventFlagUserDropped) != 0 {
                relevant = true
                continue
            }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().path == root else { continue }
            if let accepts, !accepts(url.lastPathComponent) { continue }
            relevant = true
        }
        if rootMoved {
            // Moved, deleted or replaced. Watch whatever is there now; when
            // nothing is, the safety tick arms it once it is back.
            arm()
            relevant = true
        }
        if relevant { scheduleFire() }
    }

    private func safetyTick() {
        guard running else { return }
        if Identity(of: directory) != armed || stream == nil { arm() }
        scheduleFire()
    }

    // MARK: Telling

    private func scheduleFire() {
        guard !firePending else { return }
        firePending = true
        queue.asyncAfter(deadline: .now() + coalesce) { [weak self] in
            guard let self else { return }
            self.firePending = false
            guard self.running else { return }
            self.deliverOn.async { [weak self] in
                guard let self, self.onChange() else { return }
                self.queue.async { [weak self] in self?.scheduleRetry() }
            }
        }
    }

    private func scheduleRetry() {
        guard running, !retryPending else { return }
        retryPending = true
        queue.asyncAfter(deadline: .now() + retry) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            if self.running { self.scheduleFire() }
        }
    }

    /// What the stream keeps: a weak way back, so a stream that outlives its
    /// watcher by one callback finds nothing rather than freed memory.
    private final class Box {
        weak var watch: FileWatch?
        init(_ watch: FileWatch) { self.watch = watch }
    }
}
