import Foundation

public enum OutboxKind: String, Codable, Equatable {
    case createScan, clinicalData, declareArtefact, uploadArtefact, completeArtefact, recapture
}

public struct OutboxItem: Codable, Equatable {
    public enum Status: String, Codable, Equatable {
        case pending, inFlight, done, failed, quarantined, needsRepeat
    }
    public var id: UUID
    public var sessionId: UUID
    public var kind: OutboxKind
    public var payload: Data
    /// Fixed at enqueue; never regenerated across retries.
    public let idempotencyKey: UUID
    public var status: Status
    public var attempts: Int
    public var nextAttemptAt: Date
    public var dependsOn: UUID?
    public var createdWall: Date
    public var createdMonotonicNanos: UInt64
    public var serverOffset: TimeInterval
    /// Step-level reasons when status == .needsRepeat.
    public var reasons: [ReasonCode] = []
    /// Error code or description when status == .failed / .quarantined.
    public var failureReason: String?
}

public protocol OutboxStore {
    /// All items in insertion order.
    func loadAll() throws -> [OutboxItem]
    func upsert(_ item: OutboxItem) throws
    func delete(id: UUID) throws
}

/// JSON file store with atomic writes (temp file + replace). Safe for a single process.
public final class FileOutboxStore: OutboxStore {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("outbox.json")
    }

    public func loadAll() throws -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }

    public func upsert(_ item: OutboxItem) throws {
        lock.lock(); defer { lock.unlock() }
        var items = try read()
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        try write(items)
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try write(try read().filter { $0.id != id })
    }

    private func read() throws -> [OutboxItem] {
        var source = fileURL
        if !FileManager.default.fileExists(atPath: source.path) {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { return [] }
            source = backupURL
        }
        let data = try Data(contentsOf: source)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([OutboxItem].self, from: data)
    }

    private func write(_ items: [OutboxItem]) throws {
        let data = try JSONEncoder().encode(items)
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent("outbox.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        do {
            try replace(fileURL, with: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    private func replace(_ dest: URL, with tmp: URL) throws {
        let fm = FileManager.default
        #if os(Windows)
        // Foundation on Windows lacks replaceItemAt. Keep the old file as .bak until the new
        // one is in place; read() falls back to .bak if a crash lands between the two steps.
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: dest, to: backupURL)
        }
        try fm.moveItem(at: tmp, to: dest)
        try? fm.removeItem(at: backupURL)
        #else
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
        #endif
    }
}
