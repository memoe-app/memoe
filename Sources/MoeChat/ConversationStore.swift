import Foundation

/// Conversations that survive ⌘N.
///
/// Chat used to keep its turns in one in-memory array that `newConversation()`
/// emptied. There was no session list and no way back: starting a new
/// conversation destroyed the previous one, permanently. The daily markdown in
/// `~/.moe/history/` recorded the text, but nothing could reopen a thread.
///
/// One JSON file per conversation under `conversations/`, rather than one
/// combined log: adding a turn rewrites a single small file instead of the
/// whole history, and a file that goes bad takes only its own thread down.
/// Files are 0600 and the directory 0700 — a conversation is at least as
/// private as a dictation.
public struct ConversationStore {

    // MARK: - Model

    /// One turn, as stored. Deliberately not the app's `Turn`: that carries
    /// `isStreaming`, which is a live-UI concern and has no business on disk.
    public struct StoredTurn: Codable, Equatable, Identifiable {
        public var id: String
        public var role: Role
        public var text: String
        public var at: Date
        /// What Moe did to answer, in plain language. Optional so threads
        /// written before this existed still decode.
        public var tools: [String]?
        /// Photos and files handed over with the message. Optional for the
        /// same reason as `tools`.
        public var attachments: [ChatAttachment]?

        public enum Role: String, Codable {
            case you, moe, system
        }

        public init(id: String = UUID().uuidString, role: Role, text: String,
                    at: Date = Date(), tools: [String]? = nil,
                    attachments: [ChatAttachment]? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.at = at
            self.tools = tools
            self.attachments = attachments
        }

        /// A turn with no words can still be a turn: a photo sent on its own.
        public var hasContent: Bool {
            !text.isEmpty || !(attachments ?? []).isEmpty
        }
    }

    public struct Conversation: Codable, Equatable, Identifiable {
        public var id: String
        public var startedAt: Date
        public var updatedAt: Date
        public var turns: [StoredTurn]

        public init(id: String = UUID().uuidString,
                    startedAt: Date = Date(),
                    updatedAt: Date = Date(),
                    turns: [StoredTurn] = []) {
            self.id = id
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.turns = turns
        }

        /// A short name a small model gave the thread (`TitleNamer`), kept
        /// beside the threads in `titles.idx` and merged in on reading, so a
        /// re-projection of the thread from the ledger cannot lose it.
        public var aiTitle: String? = nil

        /// What the session list shows: the AI name when there is one, else
        /// the first thing *you* said, because that is what you will
        /// recognise — Moe's opening line is usually a restatement of it and
        /// reads the same across every thread.
        public var title: String {
            if let ai = aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty { return ai }
            return firstLine
        }

        /// The first thing you said, one line, as a title.
        public var firstLine: String {
            let first = turns.first(where: { $0.role == .you && !$0.text.isEmpty })
                ?? turns.first(where: { !$0.text.isEmpty })
            guard let text = first?.text else { return "New conversation" }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return "New conversation" }
            return clean.count <= 48 ? clean : String(clean.prefix(47)) + "…"
        }

        /// A conversation nobody said anything in is not worth keeping.
        public var isEmpty: Bool {
            !turns.contains { $0.role != .system && $0.hasContent }
        }
    }

    // MARK: - Store

    public let directory: URL
    /// Oldest threads beyond this are pruned on save. Generous: a conversation
    /// is a few kilobytes and people look further back than they expect to.
    public let cap: Int

    public init(directory: URL, cap: Int = 400) {
        self.directory = directory
        self.cap = cap
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Reading

    /// Every readable conversation, newest activity first. A file that does
    /// not parse is skipped rather than fatal — one bad thread must not take
    /// the list down.
    public func all() -> [Conversation] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = titles()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Conversation? in
                guard let data = try? Data(contentsOf: url),
                      var convo = try? Self.decoder.decode(Conversation.self, from: data) else { return nil }
                convo.aiTitle = names[convo.id]
                return convo
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Titles

    /// `titles.idx`: thread id → the short name `TitleNamer` gave it. Not
    /// `.json`, so `all()` never mistakes it for a thread.
    private var titlesURL: URL { directory.appendingPathComponent("titles.idx") }

    public func titles() -> [String: String] {
        guard let data = try? Data(contentsOf: titlesURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public func setTitle(_ title: String, for id: String) throws {
        var map = titles()
        map[id] = title
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(map)
        try data.write(to: titlesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: titlesURL.path)
    }

    // MARK: Pinned and archived

    /// How the person has filed a thread in the Chat list. Kept beside the
    /// threads in `marks.idx`, like the titles, so a re-projection of a
    /// thread from the ledger cannot lose it.
    public struct Marks: Codable, Equatable, Sendable {
        public var pinned: Bool
        public var archived: Bool
        /// The model this chat was set to, and the provider it was chosen
        /// from: a choice made on one provider means nothing on another.
        public var model: String?
        public var provider: String?
        /// "Don't remember this chat": nothing said in it is learned or
        /// written to memory, and it is never tagged.
        public var forget: Bool
        /// Short topic tags for the list's filter, named once by the cheap
        /// model (`ChatTags`). `tagged` says that call was made, so it is
        /// never made again for this chat, whatever it answered.
        public var tags: [String]
        public var tagged: Bool
        public init(pinned: Bool = false, archived: Bool = false,
                    model: String? = nil, provider: String? = nil,
                    forget: Bool = false, tags: [String] = [], tagged: Bool = false) {
            self.pinned = pinned
            self.archived = archived
            self.model = model
            self.provider = provider
            self.forget = forget
            self.tags = tags
            self.tagged = tagged
        }

        private enum CodingKeys: String, CodingKey {
            case pinned, archived, model, provider, forget, tags, tagged
        }

        /// Every field optional on the way in: a marks.idx written before a
        /// field existed still reads, rather than losing every pin with it.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
                      archived: try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false,
                      model: try c.decodeIfPresent(String.self, forKey: .model),
                      provider: try c.decodeIfPresent(String.self, forKey: .provider),
                      forget: try c.decodeIfPresent(Bool.self, forKey: .forget) ?? false,
                      tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
                      tagged: try c.decodeIfPresent(Bool.self, forKey: .tagged) ?? false)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pinned, forKey: .pinned)
            try c.encode(archived, forKey: .archived)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(provider, forKey: .provider)
            if forget { try c.encode(true, forKey: .forget) }
            if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
            if tagged { try c.encode(true, forKey: .tagged) }
        }

        /// The model for this chat on `provider`, or nil for the person's
        /// default there.
        public func model(on provider: String) -> String? {
            guard let model, !model.isEmpty, self.provider == provider else { return nil }
            return model
        }
    }

    private var marksURL: URL { directory.appendingPathComponent("marks.idx") }

    public func marks() -> [String: Marks] {
        guard let data = try? Data(contentsOf: marksURL),
              let map = try? JSONDecoder().decode([String: Marks].self, from: data) else { return [:] }
        return map
    }

    /// Pinning takes a thread out of the archive; archiving unpins it.
    public func setPinned(_ pinned: Bool, for id: String) throws {
        try mark(id) { $0.pinned = pinned; if pinned { $0.archived = false } }
    }

    /// nil goes back to the person's default model.
    public func setModel(_ model: String?, provider: String, for id: String) throws {
        try mark(id) {
            $0.model = model
            $0.provider = model == nil ? nil : provider
        }
    }

    public func setArchived(_ archived: Bool, for id: String) throws {
        try mark(id) { $0.archived = archived; if archived { $0.pinned = false } }
    }

    /// "Don't remember this chat". Turning it on also takes away any tags the
    /// chat was given and keeps it from ever being tagged.
    public func setForget(_ forget: Bool, for id: String) throws {
        try mark(id) {
            $0.forget = forget
            if forget { $0.tags = [] }
        }
    }

    /// The tags the cheap model named for this chat; also records that it
    /// was asked, so it never is again. A chat marked "Don't remember this
    /// chat" is never tagged, even by a call that was already in flight.
    public func setTags(_ tags: [String], for id: String) throws {
        try mark(id) {
            $0.tagged = true
            $0.tags = $0.forget ? [] : tags
        }
    }

    /// A chat's name and marks, carried to the id it continues under: an
    /// edited message starts the chat again on a new thread (`Conductor.resend`)
    /// and its pin, name, model, switch and tags go with it.
    public func carrySideEntries(from old: String, to new: String) throws {
        if let title = titles()[old] { try setTitle(title, for: new) }
        var map = marks()
        guard let m = map.removeValue(forKey: old) else { return }
        map[new] = m
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(map).write(to: marksURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marksURL.path)
    }

    /// Take one tag off a chat, by hand.
    public func removeTag(_ tag: String, for id: String) throws {
        try mark(id) { $0.tags.removeAll { $0 == tag } }
    }

    private func mark(_ id: String, _ change: (inout Marks) -> Void) throws {
        var map = marks()
        var m = map[id] ?? Marks()
        change(&m)
        map[id] = m == Marks() ? nil : m
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(map).write(to: marksURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marksURL.path)
    }

    /// Newest first, narrowed to threads whose title or any turn contains
    /// `query` (case- and diacritic-insensitive). An empty query is all.
    public func search(_ query: String) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all() }
        return all().filter { convo in
            convo.title.localizedStandardContains(q)
                || convo.turns.contains { $0.text.localizedStandardContains(q) }
        }
    }

    public func load(id: String) -> Conversation? {
        guard let data = try? Data(contentsOf: url(for: id)),
              var convo = try? Self.decoder.decode(Conversation.self, from: data) else { return nil }
        convo.aiTitle = titles()[id]
        return convo
    }

    // MARK: Writing

    /// Write one conversation, then prune. An empty thread is deleted instead
    /// of saved, so ⌘N on an untouched window leaves nothing behind.
    public func save(_ conversation: Conversation) throws {
        guard !conversation.isEmpty else {
            try? delete(id: conversation.id)
            return
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let data = try Self.encoder.encode(conversation)
        try data.write(to: url(for: conversation.id), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url(for: conversation.id).path)

        try prune()
    }

    public func delete(id: String) throws {
        // A deleted thread's name goes with it.
        var map = titles()
        if map.removeValue(forKey: id) != nil, let data = try? JSONEncoder().encode(map) {
            try? data.write(to: titlesURL, options: .atomic)
        }
        var marked = marks()
        if marked.removeValue(forKey: id) != nil, let data = try? JSONEncoder().encode(marked) {
            try? data.write(to: marksURL, options: .atomic)
        }
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    public func deleteAll() throws {
        for convo in all() { try delete(id: convo.id) }
        try? FileManager.default.removeItem(at: titlesURL)
        try? FileManager.default.removeItem(at: marksURL)
    }

    /// Drop the least-recently-touched threads once past the cap.
    private func prune() throws {
        let convos = all()
        guard convos.count > cap else { return }
        for convo in convos.dropFirst(cap) {
            try delete(id: convo.id)
        }
    }

    /// Ids come from `UUID()`, but a hand-edited or hostile id must never
    /// escape the directory — so anything that is not a plain filename
    /// component is rejected by construction.
    private func url(for id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safe.isEmpty ? "untitled" : safe)
            .appendingPathExtension("json")
    }
}
