import CryptoKit
import Foundation
import SwiftData

// MARK: - Schema v1. Versioned from the first schema because it cannot be retrofitted.

public enum TouchpointSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [PersistedConversation.self, PersistedMessage.self] }

    @Model
    public final class PersistedConversation {
        @Attribute(.unique) public var contactID: String
        public var modality: String
        public var lastSequence: Int
        /// Monotonic composition counter for this conversation's local echoes. Device
        /// clocks can jump; this cannot.
        public var nextLocalOrder: Int = 0
        /// The participant set — a correctness requirement, not a convenience.
        public var participantsJSON: Data
        /// Denormalised so the suspend-by-default decision is taken before the blob is decoded.
        public var humanAgentPresent: Bool
        public var lastActivity: Date
        @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.conversation)
        public var messages: [PersistedMessage]

        public init(contactID: String, modality: String, lastSequence: Int = 0, participantsJSON: Data, humanAgentPresent: Bool = false, lastActivity: Date = Date()) {
            self.contactID = contactID
            self.modality = modality
            self.lastSequence = lastSequence
            self.participantsJSON = participantsJSON
            self.humanAgentPresent = humanAgentPresent
            self.lastActivity = lastActivity
            self.messages = []
        }
    }

    @Model
    public final class PersistedMessage {
        @Attribute(.unique) public var clientMessageID: UUID
        public var serverMessageID: String?
        public var sequence: Int?
        /// Composition order among this conversation's local echoes; assigned on append. Orders the
        /// unreconciled tail, where `createdAt` must not.
        public var localOrder: Int = 0
        /// Encrypted. Metadata stays in the clear so the store is queryable.
        public var bodyCiphertext: Data
        public var direction: String
        public var participantRole: String
        public var participantID: String?
        public var createdAt: Date
        public var deliveryState: String
        public var interactiveJSON: Data?
        public var citationsJSON: Data?
        public var isStreaming: Bool
        public var conversation: PersistedConversation?

        public init(clientMessageID: UUID, serverMessageID: String?, sequence: Int?, bodyCiphertext: Data, direction: String, participantRole: String, participantID: String? = nil, createdAt: Date, deliveryState: String, interactiveJSON: Data?, citationsJSON: Data?, isStreaming: Bool) {
            self.clientMessageID = clientMessageID
            self.serverMessageID = serverMessageID
            self.sequence = sequence
            self.bodyCiphertext = bodyCiphertext
            self.direction = direction
            self.participantRole = participantRole
            self.participantID = participantID
            self.createdAt = createdAt
            self.deliveryState = deliveryState
            self.interactiveJSON = interactiveJSON
            self.citationsJSON = citationsJSON
            self.isStreaming = isStreaming
        }
    }
}

public enum TouchpointMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [TouchpointSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: - Store

/// The durable store. Everything SwiftData-specific lives here; the rest of Core sees
/// value types. **Never throws from `init` for a bad store**: migration or open failure drops and
/// rebuilds, because the server is the transcript authority and a crash on launch must never happen.
public actor ConversationStore {
    public enum OpenOutcome: Sendable, Equatable {
        case opened
        case rebuiltAfterFailure
        case resetAfterKeyLoss
    }

    public static let encryptionKeyKeychainKey = "store.fieldkey.v1"
    private static let keyFingerprintFile = "fieldkey.fingerprint"

    public private(set) var lastOpenOutcome: OpenOutcome = .opened
    /// Rows skipped on the most recent transcript read — whole or paged — because their stored body
    /// could not be opened (corruption, bit rot). Per read, not cumulative. Diagnostics.
    public private(set) var undecryptableRowsSkipped = 0

    private let containerURL: URL
    private let keychain: any KeychainStore
    private let retention: TimeInterval
    private var container: ModelContainer
    private var key: SymmetricKey

    /// - Parameters:
    ///   - containerURL: Directory the SDK owns. Namespaced by the caller so the host app's own
    ///     stores are never touched.
    ///   - retention: Conversations idle longer than this are pruned on `pruneExpired()`. Default 30 days.
    public init(containerURL: URL, keychain: any KeychainStore, retention: TimeInterval = 30 * 86_400) async throws {
        self.containerURL = containerURL
        self.keychain = keychain
        self.retention = retention
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)

        // Key custody is the SDK's. Loss means the ciphertext is unreadable, so the store resets.
        let (key, keyOutcome) = try await Self.loadOrCreateKey(keychain: keychain, dir: containerURL)
        self.key = key
        if keyOutcome == .resetAfterKeyLoss { Self.wipeFiles(in: containerURL) }

        do {
            container = try Self.makeContainer(at: containerURL)
            lastOpenOutcome = keyOutcome
            // Touch the store so a corrupted file fails here, inside the rebuild guard, not on first use.
            let ctx = ModelContext(container)
            _ = try ctx.fetchCount(FetchDescriptor<TouchpointSchemaV1.PersistedConversation>())
        } catch {
            Self.wipeFiles(in: containerURL)
            container = try Self.makeContainer(at: containerURL)
            lastOpenOutcome = .rebuiltAfterFailure
        }
    }

    // MARK: Conversations

    public func upsertConversation(contactID: String, modality: Modality, lastActivity: Date = Date()) throws {
        let ctx = ModelContext(container)
        if let existing = try fetchConversation(contactID, ctx) {
            existing.modality = modality.rawValue
            existing.lastActivity = lastActivity
        } else {
            let empty = try JSONEncoder().encode(ParticipantSet())
            ctx.insert(TouchpointSchemaV1.PersistedConversation(contactID: contactID, modality: modality.rawValue, participantsJSON: empty, lastActivity: lastActivity))
        }
        try ctx.save()
    }

    public func conversation(contactID: String) throws -> ConversationRecord? {
        let ctx = ModelContext(container)
        guard let c = try fetchConversation(contactID, ctx) else { return nil }
        return try record(c)
    }

    public func setParticipants(contactID: String, _ set: ParticipantSet) throws {
        let ctx = ModelContext(container)
        guard let c = try fetchConversation(contactID, ctx) else { throw TouchpointError.contactNotFound }
        c.participantsJSON = try JSONEncoder().encode(set)
        c.humanAgentPresent = set.humanAgentPresent
        c.lastActivity = Date()
        try ctx.save()
    }

    /// The fast path for resume: reads the denormalised flag without decoding the participant blob.
    public func humanAgentPresent(contactID: String) throws -> Bool {
        let ctx = ModelContext(container)
        return try fetchConversation(contactID, ctx)?.humanAgentPresent ?? false
    }

    public func deleteConversation(contactID: String) throws {
        let ctx = ModelContext(container)
        if let c = try fetchConversation(contactID, ctx) {
            ctx.delete(c)
            try ctx.save()
        }
    }

    /// Full wipe, including the field-encryption key.
    public func deleteAllConversations() async throws {
        let ctx = ModelContext(container)
        // Per-object delete so the .cascade relationship fires; the batch `delete(model:)` form
        // bypasses relationship rules and would orphan every PersistedMessage row.
        for c in try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedConversation>()) { ctx.delete(c) }
        try ctx.save()
        // Mint and store the replacement key, switching to it only once it is safely in the
        // Keychain. A mint that fails — a locked device, or a cancellation — leaves the rows
        // gone but the old key still valid for whatever is written next, never the store keyless:
        // `mintKey`'s `set` overwrites the existing item, so no separate delete is needed, and a
        // delete-then-mint order would be exactly the window that strands the store without a key.
        key = try await Self.mintKey(keychain: keychain, dir: containerURL)
    }

    /// Removes conversations idle longer than the retention window. Returns their contact ids so
    /// the caller can reap anything keyed on them elsewhere (persisted credentials).
    @discardableResult
    public func pruneExpired(now: Date = Date()) throws -> [String] {
        let ctx = ModelContext(container)
        let cutoff = now.addingTimeInterval(-retention)
        let stale = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedConversation>(predicate: #Predicate { $0.lastActivity < cutoff }))
        let ids = stale.map(\.contactID)
        for c in stale { ctx.delete(c) }
        try ctx.save()
        return ids
    }

    /// Every stored contact id. Used by the full wipe to reap persisted credentials too.
    public func allContactIDs() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<TouchpointSchemaV1.PersistedConversation>()).map(\.contactID)
    }

    // MARK: Messages

    /// What `append` did with a message.
    public enum AppendOutcome: Sendable, Equatable {
        /// A new row.
        case appended
        /// Nothing written: a row with this `serverMessageID` already exists (our own echo, a
        /// replayed frame, a reconciled page).
        case duplicate
        /// Nothing new written: an **outbound** message from the server matched an unacknowledged
        /// local echo with the same body — the send whose acknowledgement was lost after the server
        /// accepted it. That echo now carries the server id, sequence and `.sent`; the host must be
        /// told its `.sending` bubble advanced. Body is the only correlation key until the
        /// server-side `clientToken` lands.
        case adopted(clientMessageID: UUID)

        public var isNew: Bool { self == .appended }
    }

    @discardableResult
    public func append(contactID: String, message: StoredMessage) throws -> AppendOutcome {
        let ctx = ModelContext(container)
        guard let c = try fetchConversation(contactID, ctx) else { throw TouchpointError.contactNotFound }
        if let sid = message.serverMessageID {
            if try fetchMessage(contactID: contactID, serverMessageID: sid, ctx) != nil { return .duplicate }
            if message.direction == .outbound, let echo = try unacknowledgedEcho(in: c, body: message.body) {
                echo.serverMessageID = sid
                echo.sequence = message.sequence
                echo.deliveryState = DeliveryState.sent.rawValue
                if let seq = message.sequence, seq > c.lastSequence { c.lastSequence = seq }
                try ctx.save()
                return .adopted(clientMessageID: echo.clientMessageID)
            }
        }
        let row = TouchpointSchemaV1.PersistedMessage(
            clientMessageID: message.clientMessageID,
            serverMessageID: message.serverMessageID,
            sequence: message.sequence,
            bodyCiphertext: try encrypt(message.body, clientMessageID: message.clientMessageID),
            direction: message.direction.rawValue,
            participantRole: message.participantRole.rawValue,
            participantID: message.participantID,
            createdAt: message.createdAt,
            deliveryState: message.deliveryState.rawValue,
            interactiveJSON: try sealField(message.interactiveJSON, clientMessageID: message.clientMessageID, field: Self.interactiveField),
            citationsJSON: try sealField(message.citationsJSON, clientMessageID: message.clientMessageID, field: Self.citationsField),
            isStreaming: message.isStreaming
        )
        // A conversation written before this column existed backfills to 0; seed past its rows once
        // so new echoes never collide with old ones. Indexed fetch, computed before the row joins.
        if c.nextLocalOrder == 0 {
            var d = FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.conversation?.contactID == contactID })
            d.sortBy = [SortDescriptor(\.localOrder, order: .reverse)]; d.fetchLimit = 1
            if let top = try ctx.fetch(d).first { c.nextLocalOrder = top.localOrder + 1 }
        }
        row.localOrder = c.nextLocalOrder
        c.nextLocalOrder += 1
        row.conversation = c
        ctx.insert(row)
        if let seq = message.sequence, seq > c.lastSequence { c.lastSequence = seq }
        // Activity advances to the message's own time, never backwards: a replayed old message must
        // not resurrect a conversation that retention is about to prune.
        if message.createdAt > c.lastActivity { c.lastActivity = message.createdAt }
        try ctx.save()
        return .appended
    }

    /// Applies a receipt from the other side to a message in `contactID`. Returns the message's
    /// client id when a row changed, `nil` when there is nothing to do: unknown server id, or a
    /// receipt that would move the state backwards (retransmitted or out of order). Receipts are
    /// advisory, so neither case throws.
    @discardableResult
    public func applyReceipt(contactID: String, serverMessageID: String, _ kind: ReceiptKind) throws -> UUID? {
        let ctx = ModelContext(container)
        guard let row = try fetchMessage(contactID: contactID, serverMessageID: serverMessageID, ctx),
              let current = DeliveryState(rawValue: row.deliveryState) else { return nil }
        let next = kind.deliveryState
        guard current.canTransition(to: next) else { return nil }
        row.deliveryState = next.rawValue
        try ctx.save()
        return row.clientMessageID
    }

    /// One page of transcript, **oldest-first within the page**, walking backwards from `before`
    /// (exclusive) or from the newest message when `before` is nil. `hasMore` reports whether
    /// anything older exists, so a UI can hide its "load earlier" affordance exactly once.
    public func messages(contactID: String, before: UUID?, limit: Int) throws -> TranscriptSlice {
        let ctx = ModelContext(container)
        let limit = max(limit, 1)
        undecryptableRowsSkipped = 0   // per read, like the full-transcript path

        // Cursor → the (sequence, client id) to page back from. A cursor that is an unreconciled
        // echo (no sequence) means "everything the server has acknowledged", and a cursor that no
        // longer exists is reported as exhausted rather than silently restarting at the newest page.
        // The client id is part of the cursor so two rows sharing a server sequence are paged across
        // in a stable order and neither is skipped.
        var upperBound: (seq: Int, id: UUID)?
        if let before {
            guard let cursor = try fetchMessage(contactID: contactID, clientMessageID: before, ctx) else {
                return TranscriptSlice(messages: [], hasMore: false)
            }
            upperBound = cursor.sequence.map { ($0, cursor.clientMessageID) }
            let tail = cursor.sequence == nil ? try unsequencedRows(contactID: contactID, ctx) : []
            if cursor.sequence == nil, tail.first?.clientMessageID != before {
                // An echo that is not the first of the tail: older rows are the echoes before it.
                let end = tail.firstIndex { $0.clientMessageID == before } ?? tail.count
                // Fill from readable rows only, like the sequenced path: bounding by index would
                // return an empty page when a window of echoes is unreadable, and the pager's
                // cursor would not move.
                var page: [StoredMessage] = []
                var index = end
                while index > 0, page.count < limit {
                    index -= 1
                    do { page.append(try stored(tail[index])) }
                    catch is CryptoKitError { undecryptableRowsSkipped += 1; continue }
                }
                page.reverse()
                let olderSequenced = try sequencedCount(contactID: contactID, ctx)
                // An entirely unreadable echo window would hand back an empty page and the pager's
                // cursor would not move, so fall through to the sequenced region instead of
                // stalling on it.
                if !page.isEmpty || olderSequenced == 0 {
                    return TranscriptSlice(messages: page, hasMore: index > 0 || olderSequenced > 0)
                }
                upperBound = nil   // cross into the sequenced rows
            }
        }

        // Indexed, bounded fetch — never materialises the whole relationship. Over-fetch and keep
        // going while rows are unreadable: a window of damaged rows must not hand back an empty
        // page (the pager's cursor would not move and it would stall there).
        // Collect `limit + 1` *readable* rows: the extra one is the only signal needed for
        // `hasMore`, and stopping at a fixed index would return an empty page when a whole window
        // happens to be unreadable.
        // The unsequenced tail is the *newest* content — the outbox — and belongs on the newest
        // page. Reserve its space first: filling with sequenced rows and appending whatever fits
        // would drop a pending message from a cold open entirely.
        var tail: [StoredMessage] = []
        var tailOverflowed = false
        if before == nil {
            let all = try decrypted(unsequencedRows(contactID: contactID, ctx))
            tail = Array(all.suffix(limit))
            tailOverflowed = all.count > tail.count   // an outbox larger than one page
        }
        let sequencedWanted = max(0, limit - tail.count)

        // Collect one more readable row than needed: the extra one is the only signal `hasMore`
        // requires, and stopping at a fixed index would return an empty page when a whole window
        // happens to be unreadable. Decrypted once, here.
        let batchSize = max(2, (sequencedWanted + 1) * 2)
        var kept: [StoredMessage] = []
        var cursor = upperBound
        while kept.count <= sequencedWanted {
            let batch = try sequencedRows(contactID: contactID, below: cursor, limit: batchSize, ctx)
            if batch.isEmpty { break }
            cursor = batch.last.map { ($0.sequence ?? 0, $0.clientMessageID) }
            for row in batch {
                let message: StoredMessage
                // Only an unreadable body is skipped; anything else is a real failure to propagate.
                do { message = try stored(row) }
                catch is CryptoKitError { undecryptableRowsSkipped += 1; continue }
                kept.append(message)
                if kept.count > sequencedWanted { break }
            }
            if batch.count < batchSize { break }   // the transcript is exhausted
        }
        // `hasMore` must also be true when the outbox itself overflowed the page, or a UI that pages
        // only while it is true could never reach the older unsent messages.
        let hasMore = kept.count > sequencedWanted || tailOverflowed
        let page = Array(kept.prefix(sequencedWanted)).reversed() + tail   // fetch is newest-first
        return TranscriptSlice(messages: Array(page), hasMore: hasMore)
    }

    /// Rows the server has ordered, newest first, optionally strictly below the `(sequence, client
    /// id)` cursor. Paging on the pair, not the sequence alone, is what keeps two rows that share a
    /// server sequence from being skipped across a page boundary: the boundary group — rows
    /// at the cursor's own sequence with a smaller client id, which a strict `< sequence` bound would
    /// drop — is read separately and merged in front, and it is tiny by construction.
    private func sequencedRows(contactID: String, below cursor: (seq: Int, id: UUID)?, limit: Int, _ ctx: ModelContext) throws -> [TouchpointSchemaV1.PersistedMessage] {
        guard let cursor else {
            var d = FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
                predicate: #Predicate { $0.conversation?.contactID == contactID && $0.sequence != nil }
            )
            d.sortBy = [SortDescriptor(\.sequence, order: .reverse), SortDescriptor(\.clientMessageID, order: .reverse)]
            d.fetchLimit = limit
            return try ctx.fetch(d)
        }
        let cseq = cursor.seq
        var below = FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { row in
                row.conversation?.contactID == contactID && row.sequence != nil && (row.sequence ?? 0) < cseq
            }
        )
        below.sortBy = [SortDescriptor(\.sequence, order: .reverse), SortDescriptor(\.clientMessageID, order: .reverse)]
        below.fetchLimit = limit
        let belowRows = try ctx.fetch(below)
        // The boundary group: same sequence as the cursor, smaller client id. Few by construction
        // (a server-millisecond collision), so the id comparison runs in memory after the fetch.
        let boundaryFetch = FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { row in
                row.conversation?.contactID == contactID && row.sequence != nil && (row.sequence ?? 0) == cseq
            }
        )
        let cid = cursor.id.uuidString
        let boundary = try ctx.fetch(boundaryFetch)
            .filter { $0.clientMessageID.uuidString < cid }
            .sorted { $0.clientMessageID.uuidString > $1.clientMessageID.uuidString }
        return Array((boundary + belowRows).prefix(limit))
    }

    /// The unreconciled tail, in composition order. Few by construction: it is the outbox.
    private func unsequencedRows(contactID: String, _ ctx: ModelContext) throws -> [TouchpointSchemaV1.PersistedMessage] {
        var d = FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { $0.conversation?.contactID == contactID && $0.sequence == nil }
        )
        // The same comparator as the full-transcript path, including the id tiebreaker: rows
        // written before `localOrder` existed share one value, and two orders for one tail would
        // put the paged and the whole read in disagreement.
        d.sortBy = [SortDescriptor(\.localOrder), SortDescriptor(\.createdAt), SortDescriptor(\.clientMessageID)]
        return try ctx.fetch(d)
    }

    /// Throws rather than reporting zero: a failed count that read as "nothing older" would have
    /// the pager hide every delivered message in the conversation.
    private func sequencedCount(contactID: String, _ ctx: ModelContext) throws -> Int {
        try ctx.fetchCount(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { $0.conversation?.contactID == contactID && $0.sequence != nil }
        ))
    }

    private func fetchMessage(contactID: String, clientMessageID: UUID, _ ctx: ModelContext) throws -> TouchpointSchemaV1.PersistedMessage? {
        try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { $0.clientMessageID == clientMessageID && $0.conversation?.contactID == contactID }
        )).first
    }

    /// Decrypt a transcript page, skipping and counting rows whose body can no longer be read.
    private func decrypted(_ rows: [TouchpointSchemaV1.PersistedMessage]) throws -> [StoredMessage] {
        var out: [StoredMessage] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            do { out.append(try stored(row)) }
            catch is CryptoKitError {
                undecryptableRowsSkipped += 1
                continue
            }
        }
        return out
    }

    /// The outbox: outbound messages the server has not acknowledged, in composition order. These
    /// are what a flush sends, one at a time, stopping at the first failure so order holds. A row
    /// whose body can no longer be read is skipped here and failed by the caller — it can never be
    /// sent, and leaving it in the queue would block everything behind it.
    public func pendingOutbox(contactID: String) throws -> [StoredMessage] {
        try outbox(contactID: contactID).readable
    }

    /// The outbox in one read: the rows that can be sent, in composition order, and the ids of the
    /// rows whose body can no longer be read, which the caller fails. One actor-isolated call so the
    /// two lists describe the same snapshot — a message appended between two separate reads would
    /// be in the id list but not the readable one, and look unreadable.
    public func outbox(contactID: String) throws -> (readable: [StoredMessage], unreadable: [UUID]) {
        var readable: [StoredMessage] = [], unreadable: [UUID] = []
        for row in try pendingRows(contactID: contactID, ModelContext(container)) {
            do { readable.append(try stored(row)) }
            catch is CryptoKitError { unreadable.append(row.clientMessageID) }
        }
        return (readable, unreadable)
    }

    /// Client ids of every pending outbound row, decrypted or not. The contact-end sweep uses this
    /// to fail every row, a row whose body can no longer be read included.
    public func pendingClientIDs(contactID: String) throws -> [UUID] {
        try pendingRows(contactID: contactID, ModelContext(container)).map(\.clientMessageID)
    }

    /// `true` while `clientMessageID` is still an unacknowledged outbound row. The flush asks this
    /// immediately before each send so a row adopted by reconciliation, or acknowledged since the
    /// outbox snapshot was taken, is never sent twice.
    public func isPending(clientMessageID: UUID) throws -> Bool {
        let sending = DeliveryState.sending.rawValue, outbound = Direction.outbound.rawValue
        let ctx = ModelContext(container)
        return try ctx.fetchCount(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { $0.clientMessageID == clientMessageID && $0.direction == outbound && $0.deliveryState == sending && $0.serverMessageID == nil }
        )) > 0
    }

    /// Transcript order: server sequence first, then unreconciled echoes pinned to the tail. One
    /// predicate so the pager and the full read can never disagree.
    static func transcriptOrder(_ a: TouchpointSchemaV1.PersistedMessage, _ b: TouchpointSchemaV1.PersistedMessage) -> Bool {
        switch (a.sequence, b.sequence) {
        // Two rows sharing a server sequence (the same server millisecond) are ordered by client id,
        // the same final tiebreak the pager uses, so the whole read and the paged read never
        // disagree and neither drops a row.
        case let (x?, y?): return x != y ? x < y : a.clientMessageID.uuidString < b.clientMessageID.uuidString
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return echoOrder(a, b)
        }
    }

    /// Composition order for local echoes: `localOrder`, then — only for rows written before that
    /// column existed, which all read 0 — `createdAt` and the id, so the order is deterministic
    /// and the outbox sends in exactly the order the transcript shows.
    private static func echoOrder(_ a: TouchpointSchemaV1.PersistedMessage, _ b: TouchpointSchemaV1.PersistedMessage) -> Bool {
        if a.localOrder != b.localOrder { return a.localOrder < b.localOrder }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.clientMessageID.uuidString < b.clientMessageID.uuidString
    }

    /// Indexed: a predicate fetch, not a fault of the whole `messages` relationship. The pending set
    /// is small, so the full comparator runs in memory after the fetch.
    private func pendingRows(contactID: String, _ ctx: ModelContext) throws -> [TouchpointSchemaV1.PersistedMessage] {
        let sending = DeliveryState.sending.rawValue, outbound = Direction.outbound.rawValue
        let d = FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { $0.conversation?.contactID == contactID && $0.direction == outbound && $0.deliveryState == sending && $0.serverMessageID == nil }
        )
        return try ctx.fetch(d).sorted(by: Self.echoOrder)
    }

    /// Messages in transcript order: by server sequence, then local echoes (no sequence) pinned to
    /// the tail in composition order. `createdAt` is never the ordering key.
    public func messages(contactID: String) throws -> [StoredMessage] {
        undecryptableRowsSkipped = 0   // per read: reset before any early return
        let ctx = ModelContext(container)
        guard let c = try fetchConversation(contactID, ctx) else { return [] }
        let rows = c.messages.sorted(by: Self.transcriptOrder)
        // One damaged row must not take the whole transcript down: skip it and count it, matching
        // the fail-safe posture of the participant blob. The server holds the authoritative copy.
        var out: [StoredMessage] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            do { out.append(try stored(r)) } catch is CryptoKitError { undecryptableRowsSkipped += 1 }
        }
        return out
    }

    /// Returns `false` when the row was already in `next` (a retransmitted receipt, or an ack that
    /// arrives after the server echo already adopted the row): nothing changed, so emit nothing.
    @discardableResult
    public func updateDeliveryState(clientMessageID: UUID, to next: DeliveryState, serverMessageID: String? = nil, sequence: Int? = nil) throws -> Bool {
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == clientMessageID }))
        guard let row = rows.first else { throw TouchpointError.contactNotFound }
        guard let current = DeliveryState(rawValue: row.deliveryState) else {
            throw TouchpointError.malformedPayload("unknown delivery state \(row.deliveryState)")
        }
        if current == next { return false }   // idempotent no-op (m3)
        guard current.canTransition(to: next) else {
            throw TouchpointError.malformedPayload("illegal delivery transition \(row.deliveryState) → \(next.rawValue)")
        }
        row.deliveryState = next.rawValue
        if let serverMessageID { row.serverMessageID = serverMessageID }
        if let sequence {
            row.sequence = sequence
            if let c = row.conversation, sequence > c.lastSequence { c.lastSequence = sequence }
        }
        try ctx.save()
        return true
    }

    /// Forces the SQLite write-ahead log into the main file. Tests need it so the raw-file
    /// ciphertext assertion is not fooled by a fresh write still sitting in the WAL.
    public func checkpoint() throws {
        let ctx = ModelContext(container)
        try ctx.save()
        guard let url = container.configurations.first?.url else { return }
        // Opening a second connection and issuing a passive checkpoint through SQLite is what the
        // WAL needs; SwiftData exposes no API for it, so go through sqlite3 directly.
        try SQLiteCheckpoint.run(at: url)
    }

    // MARK: Internals

    private func fetchConversation(_ id: String, _ ctx: ModelContext) throws -> TouchpointSchemaV1.PersistedConversation? {
        try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedConversation>(predicate: #Predicate { $0.contactID == id })).first
    }

    /// Indexed lookup — never decrypts, never faults the whole relationship.
    private func fetchMessage(contactID: String, serverMessageID sid: String, _ ctx: ModelContext) throws -> TouchpointSchemaV1.PersistedMessage? {
        try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(
            predicate: #Predicate { $0.serverMessageID == sid && $0.conversation?.contactID == contactID }
        )).first
    }

    /// The oldest outbound row still `.sending` with no server id whose body matches. Decrypts only
    /// the unacknowledged outbound rows, which are few.
    private func unacknowledgedEcho(in c: TouchpointSchemaV1.PersistedConversation, body: String) throws -> TouchpointSchemaV1.PersistedMessage? {
        guard let ctx = c.modelContext else { return nil }
        for r in try pendingRows(contactID: c.contactID, ctx) where (try? decrypt(r.bodyCiphertext, clientMessageID: r.clientMessageID)) == body { return r }
        return nil
    }

    private func record(_ c: TouchpointSchemaV1.PersistedConversation) throws -> ConversationRecord {
        var participants = (try? JSONDecoder().decode(ParticipantSet.self, from: c.participantsJSON))
        if participants == nil {
            // Fail SAFE (C7): a corrupt blob must not read as "no agent present", because the dispatch gate
            // dispatch gate keys off it. Reconstruct the one fact we still have from the flag.
            var reconstructed = ParticipantSet()
            if c.humanAgentPresent {
                reconstructed.join(Participant(id: "unknown-agent", role: .agent, displayName: ""))
            }
            participants = reconstructed
        }
        return ConversationRecord(
            contactID: c.contactID,
            modality: Modality(rawValue: c.modality) ?? .chat,
            lastSequence: c.lastSequence,
            participants: participants ?? ParticipantSet(),
            humanAgentPresent: c.humanAgentPresent,
            lastActivity: c.lastActivity
        )
    }

    /// Test seam: scribble one row's ciphertext so the skip-and-count path can be exercised.
    func corruptCiphertextForTesting(clientMessageID: UUID) throws {
        let ctx = ModelContext(container)
        guard let row = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == clientMessageID })).first else {
            throw TouchpointError.contactNotFound
        }
        row.bodyCiphertext = Data(repeating: 0xAB, count: 40)
        try ctx.save()
    }

    /// Test seam: relocate one row's body ciphertext onto another row, so the AAD binding can
    /// be proven to reject a body that was sealed under a different client id.
    func moveCiphertextForTesting(from: UUID, to: UUID) throws {
        let ctx = ModelContext(container)
        guard let src = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == from })).first,
              let dst = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == to })).first else {
            throw TouchpointError.contactNotFound
        }
        dst.bodyCiphertext = src.bodyCiphertext
        try ctx.save()
    }

    /// Test seam: write a body sealed WITHOUT associated data, exactly as rows predating the
    /// client-id binding were, so the legacy read path can be exercised.
    func writeLegacyCiphertextForTesting(clientMessageID: UUID, body: String) throws {
        let ctx = ModelContext(container)
        guard let row = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == clientMessageID })).first else {
            throw TouchpointError.contactNotFound
        }
        guard let combined = try AES.GCM.seal(Data(body.utf8), using: key).combined else {
            throw TouchpointError.persistenceFailure("seal produced no combined box")
        }
        row.bodyCiphertext = combined
        try ctx.save()
    }

    /// Test seam (I1): write the interactive and citations columns as raw plaintext JSON, exactly as
    /// rows predating the field sealing did, so the legacy read path can be exercised.
    func writeLegacyFieldsForTesting(clientMessageID: UUID, interactive: Data?, citations: Data?) throws {
        let ctx = ModelContext(container)
        guard let row = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == clientMessageID })).first else {
            throw TouchpointError.contactNotFound
        }
        row.interactiveJSON = interactive
        row.citationsJSON = citations
        try ctx.save()
    }

    /// Test seam (I1): relocate one row's sealed interactive blob onto another row, so the per-field
    /// AAD binding can be proven to reject a field sealed under a different client id.
    func moveInteractiveForTesting(from: UUID, to: UUID) throws {
        let ctx = ModelContext(container)
        guard let src = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == from })).first,
              let dst = try ctx.fetch(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>(predicate: #Predicate { $0.clientMessageID == to })).first else {
            throw TouchpointError.contactNotFound
        }
        dst.interactiveJSON = src.interactiveJSON
        try ctx.save()
    }

    /// Test seam: total message rows regardless of conversation, to prove cascade behaviour.
    func totalMessageRowCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<TouchpointSchemaV1.PersistedMessage>())
    }

    /// Test seam: scribble the participant blob so the fail-safe path can be exercised.
    func corruptParticipantsBlobForTesting(contactID: String) throws {
        let ctx = ModelContext(container)
        guard let c = try fetchConversation(contactID, ctx) else { throw TouchpointError.contactNotFound }
        c.participantsJSON = Data([0xFF, 0x00, 0x13])
        try ctx.save()
    }

    private func stored(_ r: TouchpointSchemaV1.PersistedMessage) throws -> StoredMessage {
        StoredMessage(
            clientMessageID: r.clientMessageID,
            serverMessageID: r.serverMessageID,
            body: try decrypt(r.bodyCiphertext, clientMessageID: r.clientMessageID),
            direction: Direction(rawValue: r.direction) ?? .inbound,
            participantRole: ParticipantRole(rawValue: r.participantRole) ?? .system,
            participantID: r.participantID,
            sequence: r.sequence,
            createdAt: r.createdAt,
            deliveryState: DeliveryState(rawValue: r.deliveryState) ?? .failed,
            interactiveJSON: openField(r.interactiveJSON, clientMessageID: r.clientMessageID, field: Self.interactiveField),
            citationsJSON: openField(r.citationsJSON, clientMessageID: r.clientMessageID, field: Self.citationsField),
            isStreaming: r.isStreaming
        )
    }

    /// The associated data each body is bound to: the row's own client id. A body moved
    /// onto a different row — a tampered or relocated ciphertext — then fails to open under the new
    /// row's id, so it can never be read as another message's content.
    private static func bodyAAD(_ clientMessageID: UUID) -> Data { Data(clientMessageID.uuidString.utf8) }

    private func encrypt(_ s: String, clientMessageID: UUID) throws -> Data {
        guard let box = try AES.GCM.seal(Data(s.utf8), using: key, authenticating: Self.bodyAAD(clientMessageID)).combined else {
            throw TouchpointError.persistenceFailure("seal produced no combined box")
        }
        return box
    }

    private func decrypt(_ d: Data, clientMessageID: UUID) throws -> String {
        let box = try AES.GCM.SealedBox(combined: d)
        do {
            // The bound form: rows written since the binding carry the client id as associated data.
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.bodyAAD(clientMessageID))
            return String(decoding: plain, as: UTF8.self)
        } catch {
            // Legacy fallback: rows written before the binding sealed without associated data. No schema
            // migration bridges the two — the open is simply tried bound first, then unbound. A row
            // whose ciphertext was relocated fails both (its tag still carries the original id), so
            // this does not weaken the binding for rows that have it.
            let plain = try AES.GCM.open(box, using: key)
            return String(decoding: plain, as: UTF8.self)
        }
    }

    // MARK: At-rest field sealing (I1)

    // The interactive and citations JSON columns were stored in the clear while only the body was
    // sealed (open issue I1); both are now sealed at rest with a per-field AAD. The Android SDK does
    // NOT seal these fields — it writes `interactive_json`/`citations_json` as plaintext columns
    // (`ConversationStore.kt` insert + `row(...)` read), and carries no `fieldAad`, so there is no
    // Android format to mirror. This uses the AAD format named in the issue:
    // "<clientMessageID>:interactive" / "<clientMessageID>:citations" — a deliberate deviation
    // (iOS seals, Android does not; the Android parity claim in the issue is inaccurate).
    private static let interactiveField = "interactive"
    private static let citationsField = "citations"

    /// Leading byte marking a sealed field blob. Legacy rows stored the JSON produced by
    /// `JSONEncoder` (always a `{`/`[` object or array, i.e. 0x7B/0x5B), so a byte that is neither
    /// tells a sealed blob from legacy plaintext with no schema change (the columns stay `Data?`).
    private static let sealedFieldMarker: UInt8 = 0x01

    /// Per-field associated data (I1): the row's client id joined to the column name, so a sealed
    /// blob relocated onto a different row — or swapped between the interactive and citations
    /// columns of one row — fails to open, exactly as the body's AAD binds it.
    private static func fieldAAD(_ clientMessageID: UUID, _ field: String) -> Data {
        Data("\(clientMessageID.uuidString):\(field)".utf8)
    }

    /// Seals an optional at-rest JSON field. `nil` stays `nil` so an absent field is never forced to
    /// a box. The stored form is `marker | combined-GCM-box`.
    private func sealField(_ plaintext: Data?, clientMessageID: UUID, field: String) throws -> Data? {
        guard let plaintext else { return nil }
        guard let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.fieldAAD(clientMessageID, field)).combined else {
            throw TouchpointError.persistenceFailure("seal produced no combined box")
        }
        var out = Data([Self.sealedFieldMarker])
        out.append(box)
        return out
    }

    /// Opens a field sealed by `sealField`. The legacy-unsealed fallback mirrors the body's intent —
    /// rows written before I1 must still read — but adapts to this field's legacy form: that form is
    /// plaintext JSON, not a sealed-without-AAD box, so a blob without the marker is returned
    /// unchanged rather than run through an unbound open. A marked blob whose AAD does not match (a
    /// relocated or column-swapped ciphertext) reads as absent — the same unreadable posture the
    /// body takes, scoped to the field so the message itself still renders.
    private func openField(_ stored: Data?, clientMessageID: UUID, field: String) -> Data? {
        guard let stored, stored.first == Self.sealedFieldMarker else { return stored }
        guard let box = try? AES.GCM.SealedBox(combined: stored.dropFirst()),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Self.fieldAAD(clientMessageID, field)) else {
            return nil
        }
        return plain
    }

    /// Core Data generates each entity's SQL triggers into a dictionary shared by every coordinator
    /// on the model, without a lock: two stores loading at once crashed in
    /// `-[NSSQLEntity_DerivedAttributesExtension _generateTriggerSQL]` (SIGSEGV, seen under parallel
    /// tests). Loading is serialised process-wide; it happens once per store, so nothing waits long.
    private static let containerLoadLock = NSLock()

    private static func makeContainer(at dir: URL) throws -> ModelContainer {
        let url = dir.appendingPathComponent("touchpoint.store")
        let config = ModelConfiguration("Touchpoint", schema: Schema(versionedSchema: TouchpointSchemaV1.self), url: url, allowsSave: true)
        let container = try containerLoadLock.withLock {
            try ModelContainer(for: Schema(versionedSchema: TouchpointSchemaV1.self), migrationPlan: TouchpointMigrationPlan.self, configurations: [config])
        }
        #if os(iOS)
        // File protection (layer 1). Not available on macOS; the unit tier covers layer 2.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return container
    }

    /// Loads the field key, or creates one. A fingerprint file beside the store detects the case
    /// where the Keychain item is gone but the ciphertext remains — that is key loss, and the only
    /// honest response is a reset.
    private static func loadOrCreateKey(keychain: any KeychainStore, dir: URL) async throws -> (SymmetricKey, OpenOutcome) {
        let fp = dir.appendingPathComponent(keyFingerprintFile)
        let storedFingerprint = try? Data(contentsOf: fp)
        if let data = try await keychain.get(encryptionKeyKeychainKey), data.count == 32 {
            let key = SymmetricKey(data: data)
            let fresh = fingerprint(of: key)
            // A fingerprint on disk that does not match the key we were handed means the ciphertext
            // was written under a different key: unreadable, so reset rather than fail on every read.
            if let storedFingerprint, storedFingerprint != fresh {
                try fresh.write(to: fp)
                return (key, .resetAfterKeyLoss)
            }
            try fresh.write(to: fp)
            return (key, .opened)
        }
        let hadStore = storedFingerprint != nil
        let key = try await Self.mintKey(keychain: keychain, dir: dir)
        return (key, hadStore ? .resetAfterKeyLoss : .opened)
    }

    private static func mintKey(keychain: any KeychainStore, dir: URL) async throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try await keychain.set(key.withUnsafeBytes { Data($0) }, for: encryptionKeyKeychainKey, accessibility: .whenUnlockedThisDeviceOnly)
        try fingerprint(of: key).write(to: dir.appendingPathComponent(keyFingerprintFile))
        return key
    }

    private static func fingerprint(of key: SymmetricKey) -> Data {
        Data(SHA256.hash(data: key.withUnsafeBytes { Data($0) }))
    }

    private static func wipeFiles(in dir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != keyFingerprintFile {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
