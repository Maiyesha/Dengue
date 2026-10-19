#if canImport(GRDB)
import Foundation
import GRDB

/// SQLite-backed store (non-Windows). Items are stored as JSON blobs keyed by id, with an
/// autoincrement sequence preserving insertion order. Verified on macOS CI only.
public final class GRDBOutboxStore: OutboxStore {
    private let queue: DatabaseQueue

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS outbox (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    json BLOB NOT NULL)
                """)
        }
    }

    public func loadAll() throws -> [OutboxItem] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT json FROM outbox ORDER BY seq").map {
                try JSONDecoder().decode(OutboxItem.self, from: $0["json"] as Data)
            }
        }
    }

    public func upsert(_ item: OutboxItem) throws {
        let data = try JSONEncoder().encode(item)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO outbox (id, json) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET json = excluded.json
                """, arguments: [item.id.uuidString, data])
        }
    }

    public func delete(id: UUID) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id.uuidString])
        }
    }
}

extension Outbox {
    public convenience init(dbPath: String, clock: OutboxClock) throws {
        self.init(store: try GRDBOutboxStore(path: dbPath), clock: clock)
    }
}
#endif
