import Foundation
import SQLite3

/// Issues `PRAGMA wal_checkpoint(TRUNCATE)` against a store file. SwiftData exposes no checkpoint
/// API, and the raw-file ciphertext test must see the main database, not just a
/// fresh write still sitting in `-wal`.
enum SQLiteCheckpoint {
    static func run(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw TouchpointError.persistenceFailure("could not open store for checkpoint")
        }
        defer { sqlite3_close(db) }
        var logFrames: Int32 = 0, checkpointed: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed)
        guard rc == SQLITE_OK else {
            throw TouchpointError.persistenceFailure("wal_checkpoint failed: \(rc)")
        }
    }
}
