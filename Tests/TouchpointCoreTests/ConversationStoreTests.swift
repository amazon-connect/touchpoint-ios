import Foundation
import Testing
@testable import TouchpointCore

@Suite("ConversationStore", .serialized)
struct ConversationStoreTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(_ dir: URL, keychain: InMemoryKeychainStore = InMemoryKeychainStore(), retention: TimeInterval = 30 * 86_400) async throws -> ConversationStore {
        try await ConversationStore(containerURL: dir, keychain: keychain, retention: retention)
    }

    @Test("Round-trips a conversation and its messages across a simulated restart")
    func roundTrip() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        do {
            let store = try await makeStore(dir, keychain: keychain)
            try await store.upsertConversation(contactID: "c1", modality: .chat)
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "hello", direction: .outbound, participantRole: .customer, deliveryState: .sending))
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "hi there", direction: .inbound, participantRole: .agent, sequence: 1, deliveryState: .delivered))
        }
        let reopened = try await makeStore(dir, keychain: keychain)
        let msgs = try await reopened.messages(contactID: "c1")
        // Server sequence orders the transcript; the unreconciled local echo pins to the tail.
        #expect(msgs.map(\.body) == ["hi there", "hello"])
        #expect(try await reopened.conversation(contactID: "c1")?.modality == .chat)
    }

    @Test("Participant set is persisted as a set keyed on ParticipantId, and humanAgentPresent is denormalised")
    func participantSet() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        var set = ParticipantSet()
        set.join(Participant(id: "p-bot", role: .assistant, displayName: "Bot"))
        set.join(Participant(id: "p-agent", role: .agent, displayName: "Sam"))
        try await store.setParticipants(contactID: "c1", set)
        let conv = try await store.conversation(contactID: "c1")
        #expect(conv?.humanAgentPresent == true)
        #expect(conv?.participants.contains("p-agent") == true)
        set.leave("p-agent")
        try await store.setParticipants(contactID: "c1", set)
        #expect(try await store.conversation(contactID: "c1")?.humanAgentPresent == false)
    }

    @Test("Five delivery states round-trip; failed is only reachable from sending")
    func deliveryStates() async throws {
        #expect(DeliveryState.allCases == [.sending, .sent, .delivered, .read, .failed])
        #expect(DeliveryState.sending.canTransition(to: .failed))
        #expect(!DeliveryState.sent.canTransition(to: .failed))
        #expect(!DeliveryState.delivered.canTransition(to: .failed))
        #expect(DeliveryState.sending.canTransition(to: .sent))
        #expect(DeliveryState.sent.canTransition(to: .delivered))
        #expect(DeliveryState.delivered.canTransition(to: .read))
        #expect(!DeliveryState.read.canTransition(to: .sent))
    }

    @Test("Message bodies never appear in plaintext in the database file, including WAL/SHM")
    func ciphertextOnDisk() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        let secret = "THE-QUICK-BROWN-FOX-\(UUID().uuidString)"
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: secret, direction: .outbound, participantRole: .customer, deliveryState: .sent))
        try await store.checkpoint()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for f in files {
            let data = try Data(contentsOf: f)
            #expect(!data.contains(Data(secret.utf8)), "plaintext body found in \(f.lastPathComponent)")
        }
        // and the read path still decrypts
        #expect(try await store.messages(contactID: "c1").first?.body == secret)
    }

    @Test("A corrupted store is dropped and rebuilt rather than crashing, and the integrator is told")
    func corruptRebuild() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        do {
            let s = try await makeStore(dir, keychain: keychain)
            try await s.upsertConversation(contactID: "c1", modality: .chat)
            try await s.checkpoint()
        }
        // Corrupt the database files only; the key fingerprint stays valid so this is store
        // corruption, not key loss.
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where f.lastPathComponent.hasPrefix("touchpoint.store") {
            try Data(repeating: 0xFF, count: 4096).write(to: f)
        }
        let rebuilt = try await makeStore(dir, keychain: keychain)
        #expect(await rebuilt.lastOpenOutcome == .rebuiltAfterFailure)
        #expect(try await rebuilt.conversation(contactID: "c1") == nil)
        try await rebuilt.upsertConversation(contactID: "c2", modality: .voice)
        #expect(try await rebuilt.conversation(contactID: "c2") != nil)
    }

    @Test("Losing the encryption key resets the store cleanly")
    func keyLossResets() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        do {
            let s = try await makeStore(dir, keychain: keychain)
            try await s.upsertConversation(contactID: "c1", modality: .chat)
            try await s.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "x", direction: .outbound, participantRole: .customer, deliveryState: .sent))
        }
        let fresh = try await makeStore(dir, keychain: InMemoryKeychainStore())
        #expect(await fresh.lastOpenOutcome == .resetAfterKeyLoss)
        #expect(try await fresh.messages(contactID: "c1").isEmpty)
    }

    @Test("A present-but-wrong key is detected by fingerprint and resets the store (M3)")
    func wrongKeyResets() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        do {
            let s = try await makeStore(dir, keychain: keychain)
            try await s.upsertConversation(contactID: "c1", modality: .chat)
            try await s.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "x", direction: .outbound, participantRole: .customer, deliveryState: .sent))
        }
        // Swap the Keychain item for a different 32-byte key: ciphertext on disk no longer matches.
        try await keychain.set(Data(repeating: 0x42, count: 32), for: ConversationStore.encryptionKeyKeychainKey, accessibility: .whenUnlockedThisDeviceOnly)
        let reopened = try await makeStore(dir, keychain: keychain)
        #expect(await reopened.lastOpenOutcome == .resetAfterKeyLoss)
        #expect(try await reopened.messages(contactID: "c1").isEmpty)
    }

    @Test("A corrupt participants blob fails SAFE: humanAgentPresent stays true (C7)")
    func corruptParticipantsFailsSafe() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        var set = ParticipantSet(); set.join(Participant(id: "a", role: .agent, displayName: "Sam"))
        try await store.setParticipants(contactID: "c1", set)
        try await store.corruptParticipantsBlobForTesting(contactID: "c1")
        let rec = try await store.conversation(contactID: "c1")
        #expect(rec?.humanAgentPresent == true)
        #expect(rec?.participants.humanAgentPresent == true)   // reconstructed from the flag
    }

    @Test("Writes after deleteAll survive a reopen (C2: key must be regenerated)")
    func writeAfterDeleteAll() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        let store = try await makeStore(dir, keychain: keychain)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.deleteAllConversations()
        try await store.upsertConversation(contactID: "c2", modality: .chat)
        try await store.append(contactID: "c2", message: StoredMessage(clientMessageID: UUID(), body: "after wipe", direction: .outbound, participantRole: .customer, deliveryState: .sent))
        let reopened = try await makeStore(dir, keychain: keychain)
        #expect(await reopened.lastOpenOutcome == .opened)
        #expect(try await reopened.messages(contactID: "c2").first?.body == "after wipe")
    }

    @Test("A duplicate receipt (same state) is an idempotent no-op, not an error (m3)")
    func idempotentReceipt() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let id = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: id, body: "x", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        try await store.updateDeliveryState(clientMessageID: id, to: .sent, serverMessageID: "s1")
        try await store.updateDeliveryState(clientMessageID: id, to: .sent, serverMessageID: "s1")
        #expect(try await store.messages(contactID: "c1").first?.deliveryState == .sent)
    }

    @Test("One undecryptable row does not take the whole transcript down")
    func badRowSkipped() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let bad = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "ok-1", direction: .inbound, participantRole: .agent, sequence: 1, deliveryState: .delivered))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: bad, body: "doomed", direction: .inbound, participantRole: .agent, sequence: 2, deliveryState: .delivered))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "ok-3", direction: .inbound, participantRole: .agent, sequence: 3, deliveryState: .delivered))
        try await store.corruptCiphertextForTesting(clientMessageID: bad)
        let msgs = try await store.messages(contactID: "c1")
        #expect(msgs.map(\.body) == ["ok-1", "ok-3"])
        #expect(await store.undecryptableRowsSkipped == 1)
        _ = try await store.messages(contactID: "c1")
        #expect(await store.undecryptableRowsSkipped == 1)   // per read, not cumulative
        _ = try await store.messages(contactID: "no-such-contact")
        #expect(await store.undecryptableRowsSkipped == 0)   // early-return path resets too
    }

    @Test("deleteAll removes message rows too, not just conversations")
    func deleteAllCascades() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        let store = try await makeStore(dir, keychain: keychain)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "x", direction: .outbound, participantRole: .customer, deliveryState: .sent))
        try await store.deleteAllConversations()
        #expect(try await store.totalMessageRowCount() == 0)
    }

    @Test("Retention pruning removes old conversations; cascade removes their messages")
    func pruningAndCascade() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir, retention: 60)
        try await store.upsertConversation(contactID: "old", modality: .chat, lastActivity: Date().addingTimeInterval(-120))
        try await store.append(contactID: "old", message: StoredMessage(clientMessageID: UUID(), body: "a", direction: .outbound, participantRole: .customer, createdAt: Date().addingTimeInterval(-110), deliveryState: .sent))
        try await store.upsertConversation(contactID: "new", modality: .chat)
        let pruned = try await store.pruneExpired()
        #expect(pruned == ["old"])
        #expect(try await store.conversation(contactID: "old") == nil)
        #expect(try await store.messages(contactID: "old").isEmpty)
        #expect(try await store.conversation(contactID: "new") != nil)
        try await store.deleteConversation(contactID: "new")
        #expect(try await store.conversation(contactID: "new") == nil)
    }

    @Test("deleteAll wipes conversations and rotates the encryption key")
    func deleteAll() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        let store = try await makeStore(dir, keychain: keychain)
        let before = try await keychain.get(ConversationStore.encryptionKeyKeychainKey)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.deleteAllConversations()
        #expect(try await store.conversation(contactID: "c1") == nil)
        let after = try await keychain.get(ConversationStore.encryptionKeyKeychainKey)
        #expect(after != nil && after != before)   // old key destroyed with the data; a fresh one minted
    }

    @Test("Schema v1 is a VersionedSchema inside a migration plan from day one")
    func versionedSchema() {
        #expect(TouchpointSchemaV1.versionIdentifier == .init(1, 0, 0))
        #expect(TouchpointMigrationPlan.schemas.first == TouchpointSchemaV1.self)
    }

    @Test("Resume with a human agent in the persisted set reports dispatch must stay suspended")
    func resumeAgentPresent() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        try await store.upsertConversation(contactID: "c1", modality: .voice)
        var set = ParticipantSet(); set.join(Participant(id: "a", role: .agent, displayName: "Sam"))
        try await store.setParticipants(contactID: "c1", set)
        #expect(try await store.humanAgentPresent(contactID: "c1") == true)
    }

    // MARK:

    @Test("append deduplicates on serverMessageID within a conversation and reports it")
    func appendDedupsByServerID() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let first = try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "a", direction: .inbound, participantRole: .agent, sequence: 10, deliveryState: .delivered))
        let dup = try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "a", direction: .inbound, participantRole: .agent, sequence: 10, deliveryState: .delivered))
        #expect(first == .appended && dup == .duplicate)
        #expect(try await store.messages(contactID: "c1").count == 1)
        // Same server id in a *different* conversation is a different message.
        try await store.upsertConversation(contactID: "c2", modality: .chat)
        #expect(try await store.append(contactID: "c2", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "a", direction: .inbound, participantRole: .agent, sequence: 10, deliveryState: .delivered)) == .appended)
    }

    @Test("Receipts update delivery state by server id; backward or unknown receipts are ignored, not thrown")
    func receiptByServerID() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let id = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: id, body: "hi", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        try await store.updateDeliveryState(clientMessageID: id, to: .sent, serverMessageID: "s9", sequence: 5)
        #expect(try await store.applyReceipt(contactID: "c1", serverMessageID: "s9", .read) == id)
        #expect(try await store.messages(contactID: "c1").first?.deliveryState == .read)
        #expect(try await store.applyReceipt(contactID: "c1", serverMessageID: "s9", .delivered) == nil)   // backward: ignored
        #expect(try await store.messages(contactID: "c1").first?.deliveryState == .read)
        #expect(try await store.applyReceipt(contactID: "c1", serverMessageID: "nope", .delivered) == nil) // unknown: ignored
        #expect(try await store.applyReceipt(contactID: "other", serverMessageID: "s9", .delivered) == nil) // scoped per conversation
    }

    @Test("Reconcile adopts an unacknowledged outbound echo instead of duplicating it (ack lost after the server accepted)")
    func reconcileAdoptsUnackedEcho() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let local = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: local, body: "pay my bill", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        // The server has it under srv-7; our ack never arrived. The transcript page brings it back as a fresh row.
        let fromServer = StoredMessage(clientMessageID: UUID(), serverMessageID: "srv-7", body: "pay my bill", direction: .outbound, participantRole: .customer, sequence: 70, deliveryState: .sent)
        #expect(try await store.append(contactID: "c1", message: fromServer) == .adopted(clientMessageID: local))
        let rows = try await store.messages(contactID: "c1")
        #expect(rows.count == 1)
        #expect(rows[0].clientMessageID == local && rows[0].serverMessageID == "srv-7" && rows[0].sequence == 70 && rows[0].deliveryState == .sent)
        // A different body is a different message.
        #expect(try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "srv-8", body: "other", direction: .outbound, participantRole: .customer, sequence: 80, deliveryState: .sent)) == .appended)
        #expect(try await store.messages(contactID: "c1").count == 2)
    }

    @Test("participantID round-trips through the store")
    func participantIDPersists() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s", body: "x", direction: .inbound, participantRole: .agent, participantID: "p-9", sequence: 1, deliveryState: .delivered))
        #expect(try await store.messages(contactID: "c1").first?.participantID == "p-9")
    }

    @Test("Paging: messages(before:limit:) walks backwards through the transcript and reports when it is exhausted")
    func paging() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        for i in 1...25 {
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(i)", body: "m\(i)", direction: .inbound, participantRole: .agent, sequence: i, deliveryState: .delivered))
        }
        let newest = try await store.messages(contactID: "c1", before: nil, limit: 10)
        #expect(newest.messages.map(\.body) == (16...25).map { "m\($0)" })
        #expect(newest.hasMore)
        let middle = try await store.messages(contactID: "c1", before: newest.messages.first?.clientMessageID, limit: 10)
        #expect(middle.messages.map(\.body) == (6...15).map { "m\($0)" })
        #expect(middle.hasMore)
        let oldest = try await store.messages(contactID: "c1", before: middle.messages.first?.clientMessageID, limit: 10)
        #expect(oldest.messages.map(\.body) == (1...5).map { "m\($0)" })
        #expect(!oldest.hasMore)
    }

    @Test("A page whose rows are all undecryptable does not wedge the pager: it keeps walking back")
    func pagingSkipsUndecryptableRows() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        var ids: [UUID] = []
        for i in 1...9 {
            let id = UUID(); ids.append(id)
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: id, serverMessageID: "s\(i)", body: "m\(i)", direction: .inbound, participantRole: .agent, sequence: i, deliveryState: .delivered))
        }
        // Scribble the middle three: a naive pager would hand back an empty page and stall there.
        for id in ids[3..<6] { try await store.corruptCiphertextForTesting(clientMessageID: id) }
        let newest = try await store.messages(contactID: "c1", before: nil, limit: 3)
        #expect(newest.messages.map(\.body) == ["m7", "m8", "m9"])
        #expect(newest.hasMore)
        // The next page skips the three damaged rows and still returns three readable ones.
        let next = try await store.messages(contactID: "c1", before: newest.messages.first?.clientMessageID, limit: 3)
        #expect(next.messages.map(\.body) == ["m1", "m2", "m3"])
        #expect(!next.hasMore)
        // Corruption stays observable on the paged path, not only the full read.
        #expect(await store.undecryptableRowsSkipped == 3)
        // Reading the outbox must not pollute that transcript diagnostic.
        _ = try await store.pendingOutbox(contactID: "c1")
        #expect(await store.undecryptableRowsSkipped == 3)
    }

    @Test("One outbox read splits sendable rows from unreadable ones, in composition order")
    func outboxSplitsUnreadableRows() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: id, body: "o\(i)", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        }
        try await store.corruptCiphertextForTesting(clientMessageID: ids[1])
        let outbox = try await store.outbox(contactID: "c1")
        #expect(outbox.readable.map(\.body) == ["o0", "o2"])
        #expect(outbox.unreadable == [ids[1]])
        // The outbox's unreadable rows are the flush's to fail, not a transcript diagnostic.
        #expect(await store.undecryptableRowsSkipped == 0)
    }

    @Test("The newest page always carries the unsent outbox, even when delivered messages would fill it")
    func newestPageKeepsTheOutbox() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        for i in 1...60 {
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(i)", body: "delivered \(i)", direction: .inbound, participantRole: .agent, sequence: i, deliveryState: .delivered))
        }
        let pendingA = UUID(), pendingB = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: pendingA, body: "unsent one", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: pendingB, body: "unsent two", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        let newest = try await store.messages(contactID: "c1", before: nil, limit: 50)
        #expect(newest.messages.count == 50)
        #expect(newest.messages.suffix(2).map(\.clientMessageID) == [pendingA, pendingB], "the outbox must be on the newest page")
        #expect(newest.messages.first?.body == "delivered 13")   // 48 delivered + 2 unsent
        #expect(newest.hasMore)
    }

    // MARK: Field encryption bound to the row's client id

    @Test("A body moved onto another row's client id fails to open; a legacy no-AAD row still reads")
    func aadBindsBodyToClientID() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let a = UUID(), b = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: a, serverMessageID: "s1", body: "alpha", direction: .inbound, participantRole: .agent, sequence: 1, deliveryState: .delivered))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: b, serverMessageID: "s2", body: "bravo", direction: .inbound, participantRole: .agent, sequence: 2, deliveryState: .delivered))
        // Relocate alpha's ciphertext onto b's row. Its tag still carries a's id, so under b's id it
        // can be opened by neither the bound nor the legacy path: the row is skipped, not misread.
        try await store.moveCiphertextForTesting(from: a, to: b)
        #expect(try await store.messages(contactID: "c1").map(\.body) == ["alpha"])
        #expect(await store.undecryptableRowsSkipped == 1)
        // A legacy row (sealed before the binding, no associated data) still reads through the fallback.
        try await store.writeLegacyCiphertextForTesting(clientMessageID: b, body: "legacy")
        #expect(try await store.messages(contactID: "c1").map(\.body) == ["alpha", "legacy"])
        #expect(await store.undecryptableRowsSkipped == 0)
    }

    // MARK: Pager cursor on (sequence, client id)

    @Test("Two messages sharing a server sequence are never skipped when paging across them")
    func pagingTiebreaksOnSharedSequence() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        // seq 1, then two rows sharing seq 2, then seq 3 — the server-millisecond collision.
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "m1", direction: .inbound, participantRole: .agent, sequence: 1, deliveryState: .delivered))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s2a", body: "m2a", direction: .inbound, participantRole: .agent, sequence: 2, deliveryState: .delivered))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s2b", body: "m2b", direction: .inbound, participantRole: .agent, sequence: 2, deliveryState: .delivered))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s3", body: "m3", direction: .inbound, participantRole: .agent, sequence: 3, deliveryState: .delivered))
        // Canonical order from the full read: the two seq-2 rows are ordered by client id.
        let all = try await store.messages(contactID: "c1")
        let twins = all.filter { $0.sequence == 2 }
        #expect(twins.count == 2)
        let later = twins[1]                       // the twin that sorts after the other
        // Paging strictly before the later twin must still return the earlier twin — the sequence
        // alone would drop it, since both share sequence 2.
        let page = try await store.messages(contactID: "c1", before: later.clientMessageID, limit: 10)
        #expect(page.messages.contains { $0.clientMessageID == twins[0].clientMessageID }, "the earlier twin must not be skipped")
        // And walking the whole transcript one page at a time visits every row exactly once.
        var collected: [UUID] = []
        var before: UUID? = nil
        for _ in 0..<10 {
            let slice = try await store.messages(contactID: "c1", before: before, limit: 2)
            collected = slice.messages.map(\.clientMessageID) + collected
            before = slice.messages.first?.clientMessageID
            if !slice.hasMore { break }
        }
        #expect(collected == all.map(\.clientMessageID))
    }

    // MARK: Never leave the store keyless if the replacement mint fails

    /// Keychain double that can be told to fail every `set`, to simulate a locked device during the
    /// replacement-key mint. The prior value is left intact, as the real Keychain leaves it.
    private actor FailableKeychainStore: KeychainStore {
        private var items: [String: Data] = [:]
        private var failSet = false
        func failNextSets(_ on: Bool) { failSet = on }
        func get(_ key: String) async throws -> Data? { items[key] }
        func set(_ value: Data, for key: String, accessibility: KeychainAccessibility) async throws {
            if failSet { throw TouchpointError.persistenceFailure("keychain locked") }
            items[key] = value
        }
        func delete(_ key: String) async throws { items[key] = nil }
    }

    @Test("deleteAll that cannot mint the replacement key leaves the old key intact, not the store keyless")
    func deleteAllKeepsKeyWhenMintFails() async throws {
        let dir = try tempDir(); let keychain = FailableKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), body: "x", direction: .outbound, participantRole: .customer, deliveryState: .sent))
        await keychain.failNextSets(true)
        await #expect(throws: (any Error).self) { try await store.deleteAllConversations() }
        await keychain.failNextSets(false)
        // The old key must still be in the Keychain, so a reopen opens cleanly rather than resetting
        // the store because it found data but no key.
        let reopened = try await ConversationStore(containerURL: dir, keychain: keychain)
        #expect(await reopened.lastOpenOutcome == .opened)
    }

    // MARK: I1 — interactive and citations sealed at rest, bound per field to the client id

    @Test("interactive and citations round-trip through the store unchanged (I1)")
    func interactiveAndCitationsRoundTrip() async throws {
        let dir = try tempDir(); let keychain = InMemoryKeychainStore()
        let interactive = Data("INTERACTIVE-MARKER-\(UUID().uuidString)".utf8)
        let citations = Data("CITATIONS-MARKER-\(UUID().uuidString)".utf8)
        let id = UUID()
        do {
            let store = try await makeStore(dir, keychain: keychain)
            try await store.upsertConversation(contactID: "c1", modality: .chat)
            try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: id, serverMessageID: "s1", body: "hi", direction: .inbound, participantRole: .assistant, sequence: 1, deliveryState: .delivered, interactiveJSON: interactive, citationsJSON: citations))
        }
        let reopened = try await makeStore(dir, keychain: keychain)
        let msg = try #require(try await reopened.messages(contactID: "c1").first)
        #expect(msg.interactiveJSON == interactive)
        #expect(msg.citationsJSON == citations)
        // A message with neither field keeps them nil rather than sealing an empty box.
        try await reopened.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s2", body: "plain", direction: .inbound, participantRole: .agent, sequence: 2, deliveryState: .delivered))
        let plain = try #require(try await reopened.messages(contactID: "c1").last)
        #expect(plain.interactiveJSON == nil && plain.citationsJSON == nil)
    }

    @Test("Neither the interactive nor the citations JSON appears in the store files after a checkpoint (I1)")
    func interactiveAndCitationsCiphertextOnDisk() async throws {
        let dir = try tempDir()
        let store = try await makeStore(dir)
        let interactiveMarker = "INTERACTIVE-SECRET-\(UUID().uuidString)"
        let citationsMarker = "CITATIONS-SECRET-\(UUID().uuidString)"
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "body", direction: .inbound, participantRole: .assistant, sequence: 1, deliveryState: .delivered, interactiveJSON: Data(interactiveMarker.utf8), citationsJSON: Data(citationsMarker.utf8)))
        try await store.checkpoint()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for f in files {
            let data = try Data(contentsOf: f)
            #expect(!data.contains(Data(interactiveMarker.utf8)), "plaintext interactive JSON found in \(f.lastPathComponent)")
            #expect(!data.contains(Data(citationsMarker.utf8)), "plaintext citations JSON found in \(f.lastPathComponent)")
        }
        // The read path still returns the plaintext.
        let msg = try #require(try await store.messages(contactID: "c1").first)
        #expect(msg.interactiveJSON == Data(interactiveMarker.utf8))
        #expect(msg.citationsJSON == Data(citationsMarker.utf8))
    }

    @Test("A legacy row with plaintext interactive and citations JSON still reads (I1)")
    func legacyPlaintextFieldsStillRead() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let id = UUID()
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: id, serverMessageID: "s1", body: "hi", direction: .inbound, participantRole: .assistant, sequence: 1, deliveryState: .delivered))
        let interactive = Data(#"{"template":"legacy"}"#.utf8)
        let citations = Data(#"[{"title":"legacy"}]"#.utf8)
        try await store.writeLegacyFieldsForTesting(clientMessageID: id, interactive: interactive, citations: citations)
        let msg = try #require(try await store.messages(contactID: "c1").first)
        #expect(msg.interactiveJSON == interactive)
        #expect(msg.citationsJSON == citations)
    }

    @Test("A sealed interactive blob moved onto another row fails to open and reads as absent (I1 AAD binding)")
    func interactiveAADBindsToClientID() async throws {
        let store = try await makeStore(try tempDir())
        try await store.upsertConversation(contactID: "c1", modality: .chat)
        let a = UUID(), b = UUID()
        let interactiveA = Data(#"{"template":"alpha"}"#.utf8)
        let interactiveB = Data(#"{"template":"bravo"}"#.utf8)
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: a, serverMessageID: "s1", body: "alpha", direction: .inbound, participantRole: .assistant, sequence: 1, deliveryState: .delivered, interactiveJSON: interactiveA))
        try await store.append(contactID: "c1", message: StoredMessage(clientMessageID: b, serverMessageID: "s2", body: "bravo", direction: .inbound, participantRole: .assistant, sequence: 2, deliveryState: .delivered, interactiveJSON: interactiveB))
        // Relocate a's sealed interactive blob onto b's row. Its tag carries a's field AAD, so under
        // b's id it cannot be opened: the field reads as absent, while the message itself still shows.
        try await store.moveInteractiveForTesting(from: a, to: b)
        let rows = try await store.messages(contactID: "c1")
        #expect(rows.map(\.body) == ["alpha", "bravo"])   // the swap does not take the row down
        let bravo = try #require(rows.first { $0.clientMessageID == b })
        #expect(bravo.interactiveJSON == nil, "a blob sealed under another row's id must not open")
    }
}
