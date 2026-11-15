import Foundation
import MoeChat

/// What the app talks to: append the turn, then project it.
///
/// The order is the whole point (§2.4). A turn is a ledger record first and a
/// file second, so a crash between the two loses the file — which the
/// projector rebuilds — rather than the fact. Nothing else writes
/// `~/.moe/conversations/`.
public final class ConversationLedger {

    public let ledger: Ledger
    public let projector: ConversationProjector
    private let store: ConversationStore
    private let sessions: BrainSessionState
    /// Reading and writing the ledger happens here, never on the caller's
    /// thread. The caller is the main actor and this work grows with the
    /// length of a person's history: it is a parse, a topological sort and
    /// two file writes at the end of every reply, and none of that belongs
    /// in front of the UI. Serial, so saves and resumes stay in order.
    let queue = DispatchQueue(label: "moe.ledger.conversations")

    /// The keys the threads are sealed with. Beside the ledger, never in it.
    public let keyring: ThreadKeyring

    /// `note` is how this says something a person needs to know — a keyring
    /// that cannot be read, threads that cannot be opened. It is not for
    /// errors, which come back to the caller.
    public convenience init(directory: URL, store: ConversationStore,
                            note: @escaping (String) -> Void = { _ in }) {
        self.init(ledger: Ledger(directory: directory), store: store, note: note)
    }

    public init(ledger: Ledger, store: ConversationStore,
                note: @escaping (String) -> Void = { _ in }) {
        self.ledger = ledger
        self.store = store
        self.keyring = ThreadKeyring(
            url: ledger.directory.appendingPathComponent("thread-keys.json"), note: note)
        self.projector = ConversationProjector(ledger: ledger, store: store, keyring: keyring)
        self.sessions = BrainSessionState(url: ledger.directory.appendingPathComponent("brain-sessions.json"))
    }

    // MARK: - The ask in flight (docs/AWAY-HANDOFF.md)

    /// The document the machine's pickup reads: `moeledger.documents.NAME_ASK`.
    public static let askDocument = "task/inflight"

    /// Seal what Moe is working on onto the ledger at turn START, or withdraw
    /// it (`text` nil) at the end — so a machine covering a shut Mac has the
    /// words, not only the edge's row. Under `moe:memory`, like every other
    /// Mac document; an un-enrolled Mac holds no such key and publishes
    /// nothing, which is right: it has no machine to cover it. Returns
    /// whether a record was appended.
    @discardableResult
    public func publishAsk(_ text: String?) throws -> Bool {
        guard let key = keyring.key(for: ThreadKeyring.memoryKeyID) else { return false }
        try DocumentRecord.append(name: Self.askDocument, text: text, to: ledger, key: key)
        return true
    }

    // MARK: - Writing

    /// Record whatever is new in this thread, then write the thread's file
    /// from the ledger.
    ///
    /// A ledger failure must never cost the person the conversation they just
    /// had, so the file is written either way — the projection when there is
    /// one, the caller's own copy when nothing reached the ledger at all.
    ///
    /// "Nothing reached the ledger" is the only case that falls back. A
    /// thread the ledger holds but will not project is deleted or unreadable,
    /// and writing the caller's plaintext copy of it would undo a deletion
    /// and put the words back on disk in the clear.
    ///
    /// `session` is passed only when a reply has just come back, and is then
    /// the brain's *current* session, asked for at that moment rather than
    /// remembered from the resume. A reply is the brain confirming what it
    /// holds: it answered on that session, so that session has the thread.
    ///
    /// Both halves of that matter. A save with no reply behind it — quitting,
    /// or filing a thread on the way to another — proves nothing and records
    /// nothing. And anything that rotates the session, such as stopping a
    /// turn mid-thought or reloading memory, means what followed landed
    /// somewhere else and a resume must send it on. Guessing either way is
    /// how a thread comes back half-remembered.
    public func save(_ conversation: ConversationStore.Conversation,
                     session: String = "") throws {
        try queue.sync { try performSave(conversation, session: session) }
    }

    private func performSave(_ conversation: ConversationStore.Conversation,
                             session: String) throws {
        do {
            try record(conversation)
        } catch {
            try store.save(conversation)
            throw error
        }
        if !session.isEmpty {
            sessions.markSeen(projector.turnRecords(thread: conversation.id).map(\.id),
                              session: session)
        }
        if try projector.write(thread: conversation.id) == nil,
           projector.records(thread: conversation.id).isEmpty {
            try store.save(conversation)
        }
    }

    /// The app's way in: the same save, off the caller's thread.
    ///
    /// `flush` waits for it, which the way out of the app needs — an async
    /// save the process does not outlive is a lost conversation, and losing
    /// one is worse than every bug this slice fixes. Everything else is
    /// fire-and-forget, ordered behind whatever is already queued.
    public func save(_ conversation: ConversationStore.Conversation,
                     session: String = "", flush: Bool,
                     onError: (@Sendable (any Error) -> Void)? = nil) {
        let work = { [self] in
            do { try performSave(conversation, session: session) }
            catch { onError?(error) }
        }
        if flush { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Append the turns of `conversation` the ledger does not have. Returns
    /// the ids of the records written.
    @discardableResult
    public func record(_ conversation: ConversationStore.Conversation,
                       source: String = "live") throws -> [String] {
        let missing = projector.missingTurns(of: conversation)
        guard !missing.isEmpty else { return [] }
        // The thread's key, minted here on its first turn. Writing a turn is
        // the only thing that creates one — a thread nobody ever spoke in
        // never gets a key, and there is nothing to destroy.
        let key = try keyring.key(creatingFor: conversation.id)
        // `after` is what this author had already seen: the head of the
        // thread as it stood when the turn was written.
        var head = projector.head(thread: conversation.id)
        var written: [String] = []
        for turn in missing {
            let body = try ConversationProjector.turnBody(
                thread: conversation.id, startedAt: conversation.startedAt,
                turn: turn, source: source, key: key)
            let record = try ledger.append(kind: LedgerRecord.Kind.turn, body: body, after: head)
            head = [record.id]
            written.append(record.id)
        }
        return written
    }

    /// Forget a thread: the record says so, and the file goes.
    ///
    /// A reserved id (LEDGER-WIRE §13.2, `moe:memory`) is not a thread and cannot be
    /// deleted: no record is written, no key is touched, no file goes.
    public func delete(id: String) throws {
        guard !ThreadKeyring.isReserved(id) else { return }
        try queue.sync { try deleteLocked(id: id) }
    }

    private func deleteLocked(id: String) throws {
        if !projector.turnRecords(thread: id).isEmpty {
            let head = projector.head(thread: id)
            try ledger.append(kind: LedgerRecord.Kind.threadDelete,
                              body: .of(["thread": .string(id)]), after: head)
        }
        // The record first — it is what other records point at, and once it
        // is written the thread is hidden however the rest of this goes.
        // Then the key, which is the deletion itself, and then the file.
        //
        // The last two are both attempted even if one fails, because a thread
        // still listed after the person deleted it is the worst of the
        // available outcomes. A key left behind by a failure here is dropped
        // by `rebuild`, which sweeps keys for threads the ledger says are
        // deleted. The first failure is what the caller hears about.
        var failure: (any Error)?
        do { try keyring.destroy(thread: id) } catch { failure = error }
        do { try store.delete(id: id) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    // MARK: - Resuming

    /// What to hand the brain so it can carry on this thread.
    ///
    /// `knownTurns` is what the app has on screen. For a thread that predates
    /// the ledger that is the only copy there is, so it is imported here —
    /// per thread, on the person's own action of opening it, adding records
    /// and destroying nothing. A thread nobody reopens is never touched.
    public func resume(thread: String, brain: String,
                       knownTurns: [ConversationStore.StoredTurn] = [],
                       startedAt: Date? = nil, now: Date = Date()) -> BrainResume {
        // On the queue, so a resume sees every save queued before it — the
        // thread being left is filed before the thread being opened is read.
        queue.sync {
            resumeLocked(thread: thread, brain: brain, knownTurns: knownTurns,
                         startedAt: startedAt, now: now)
        }
    }

    private func resumeLocked(thread: String, brain: String,
                              knownTurns: [ConversationStore.StoredTurn],
                              startedAt: Date?, now: Date) -> BrainResume {
        if projector.turnRecords(thread: thread).isEmpty, !knownTurns.isEmpty {
            let backfilled = ConversationStore.Conversation(
                id: thread, startedAt: startedAt ?? knownTurns.first?.at ?? now,
                updatedAt: now, turns: knownTurns)
            // A failed backfill is not fatal: the turns are still on screen
            // and still in their file, and priming falls back to them below.
            try? record(backfilled, source: "backfill")
        }

        let session = BrainSession.id(thread: thread, brain: brain)
        let records = projector.turnRecords(thread: thread)
        let unseen = sessions.unseen(records.map(\.id), session: session)

        guard !unseen.isEmpty else {
            return BrainResume(threadID: thread, sessionID: session, priming: nil)
        }
        // Only the part this session has not already been told is worth
        // spending context on; a session that has served the thread all along
        // gets nothing at all and simply carries on.
        let unseenIDs = Set(records.filter { unseen.contains($0.id) }
            .compactMap { $0.body["turn_id"]?.stringValue })
        let projected = projector.project(thread: thread)
        let toPrime: [ConversationStore.StoredTurn]
        if let projected {
            toPrime = projected.turns.filter { unseenIDs.contains($0.id) }
        } else if records.isEmpty {
            // Nothing recorded — the backfill above did not land. What is on
            // screen is all there is, and the person can still be answered.
            toPrime = knownTurns
        } else {
            // The ledger holds this thread and will not open it: deleted, or
            // unreadable. Either way the model must not be told it. Sending
            // the caller's copy here would put a deleted conversation back in
            // front of the very thing that would then remember it.
            toPrime = []
        }
        guard let priming = PrimingTranscript.text(
            for: toPrime, resuming: projected?.startedAt ?? startedAt, now: now)
        else { return BrainResume(threadID: thread, sessionID: session, priming: nil) }

        // Nothing is recorded as told until the brain says it arrived. The
        // state is captured rather than `self`, so the callback can safely
        // run on whichever queue the brain finishes its turn on — its only
        // shared state takes a lock.
        let state = sessions
        let delivered = records.map(\.id)
        return BrainResume(
            threadID: thread, sessionID: session, priming: priming,
            onDelivered: { state.markSeen(delivered, session: session) })
    }

    // MARK: - Records that arrived from elsewhere

    /// Re-project threads whose records another device wrote — the cloud
    /// sync adopts them straight into `ledger`, and this is how they reach
    /// the screen. Runs on the ledger's own queue, behind whatever save is
    /// in flight, so a projection never races a write.
    ///
    /// A thread that arrived deleted is treated as `rebuild` treats one: its
    /// file goes (the projector does that) and its key goes with it, because
    /// a key for a thread the ledger says was destroyed is exactly the copy
    /// §12 says must not survive. Returns the threads that were touched.
    @discardableResult
    public func reproject(threads: [String]) throws -> [String] {
        try queue.sync {
            var touched: [String] = []
            for thread in Set(threads) {
                try projector.write(thread: thread)
                if projector.isDeleted(thread: thread) {
                    _ = try keyring.forget(threads: [thread])
                }
                touched.append(thread)
            }
            return touched
        }
    }

    /// Threads the ledger says were deleted — what a courier must be told to
    /// skip, so a deleted thread's key is never re-installed from a replayed
    /// envelope (§15.6). The courier has a keyring, not a ledger, and cannot
    /// answer this itself.
    ///
    /// Never a reserved id: `isDeleted` says no for those, so a
    /// `thread.delete` naming `moe:memory` cannot make the courier drop the
    /// memory key's envelopes (LEDGER-WIRE §13.2).
    public func deletedThreads() -> Set<String> {
        queue.sync {
            Set(projector.threads().filter { projector.isDeleted(thread: $0) })
        }
    }

    /// Rebuild every projected thread from records. The supported repair for
    /// a lost or corrupted `conversations/` directory (§8).
    @discardableResult
    public func rebuild() throws -> Int {
        try queue.sync {
            // A key for a thread the ledger says was deleted is an orphan
            // from a process that died mid-delete. Dropping it only ever
            // removes, so it can never bring a conversation back.
            let deleted = projector.threads().filter { projector.isDeleted(thread: $0) }
            try keyring.forget(threads: deleted)
            keyring.noteUnreadable(threads: projector.unreadableThreads().count)
            return try projector.rebuildAll()
        }
    }
}

/// Which records each brain session has actually been given.
///
/// Projector bookkeeping, not truth — deleting this file costs at most one
/// re-primed thread. It is kept beside the ledger rather than inside it
/// because it is about this runtime's state, and the ledger is about the
/// person's.
final class BrainSessionState: @unchecked Sendable {
    private let url: URL
    private var seen: [String: Set<String>]
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        var loaded: [String: Set<String>] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessions = obj["sessions"] as? [String: [String]] {
            loaded = sessions.mapValues(Set.init)
        }
        seen = loaded
    }

    func unseen(_ ids: [String], session: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let known = seen[session] ?? []
        return Set(ids).subtracting(known)
    }

    func markSeen(_ ids: [String], session: String) {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return }
        seen[session, default: []].formUnion(ids)
        persistLocked()
    }

    private func persistLocked() {
        let body: [String: Any] = ["version": 1, "sessions": seen.mapValues { Array($0).sorted() }]
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
