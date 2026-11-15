import Foundation

/// Whether the owner's voice enrolment is still believed at the wake word —
/// kept on disk, so the answer survives a restart.
///
/// An enrolment built from the wrong audio refuses its own owner as
/// confidently as it refuses a stranger. `VoiceEngine` notices by counting:
/// three refusals in a row and it stops asking the enrolment about wakes.
/// That decision used to live in memory, so every launch believed the bad
/// enrolment afresh: three more ignored "Hey Moe"s and the same error, after
/// every restart, for as long as the enrolment stood.
///
/// Now the doubt is written down beside the enrolment and lasts exactly as
/// long as the enrolment it is about: teaching Moe the voice again (or
/// forgetting it) clears it.
///
/// A file that cannot be read is trust — the check is "a soft signal, never
/// a gate on its own", and an unreadable note must not silently switch off
/// the thing that keeps other people's voices from waking Moe.
public struct WakeOwnerTrust: Sendable {

    public struct Record: Codable, Equatable, Sendable {
        /// Refusals in a row that led to the doubt.
        public var refusals: Int
        public var since: Date
    }

    public let file: URL

    public init(file: URL) { self.file = file }

    /// The standing doubt, if there is one.
    public var record: Record? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// False once the enrolment has been doubted and not re-taught since.
    public var trusted: Bool { record == nil }

    /// Stop believing the enrolment at the wake word, from now on and after
    /// a restart. True when it was written.
    @discardableResult
    public func distrust(refusals: Int, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Record(refusals: refusals, since: now)) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// The enrolment was re-taught or forgotten: believe it again.
    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
