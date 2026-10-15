import Foundation

/// Outbox payloads written by `UploadEngine.enqueueSession` and read back by `drain()`.
public enum UploadPayload {
    /// declareArtefact / uploadArtefact / completeArtefact: which artefact of the session record.
    public struct Artefact: Codable, Equatable {
        public let artefactLocalId: UUID
        public init(artefactLocalId: UUID) { self.artefactLocalId = artefactLocalId }
    }
    public struct ClinicalData: Codable, Equatable {
        public let patientId: UUID
        public let request: ClinicalDataRequest
        public init(patientId: UUID, request: ClinicalDataRequest) { self.patientId = patientId; self.request = request }
    }
    public struct Recapture: Codable, Equatable {
        public let steps: [CaptureStepName]
        public let reason: String
        public init(steps: [CaptureStepName], reason: String) { self.steps = steps; self.reason = reason }
    }
}

/// What is uploaded for one artefact, plus its upload progress.
public struct ArtefactUpload: Codable, Equatable {
    public enum Status: String, Codable, Equatable { case pending, declared, uploaded, verified, failed
        /// Never uploaded (server took no more attempts for its step); key and file destroyed.
        case abandoned
    }

    public let localId: UUID
    public let step: CaptureStepName
    public let attempt: Int
    public let kind: ArtefactKind
    public let deviceVerdict: DeviceVerdict?
    public let sealed: SealedArtefact
    public var serverArtefactId: UUID?
    /// 1-based part numbers confirmed uploaded (2xx from object storage).
    public var uploadedParts: [Int] = []
    public var status: Status = .pending

    public init(localId: UUID = UUID(), step: CaptureStepName, attempt: Int, kind: ArtefactKind,
                deviceVerdict: DeviceVerdict? = nil, sealed: SealedArtefact) {
        self.localId = localId; self.step = step; self.attempt = attempt; self.kind = kind
        self.deviceVerdict = deviceVerdict; self.sealed = sealed
    }
}

/// Per-session upload state kept beside the outbox. Holds only the MASKED participant code (`••123`).
public struct UploadSessionRecord: Codable, Equatable {
    public enum Verdict: String, Codable, Equatable {
        /// Uploads still running.
        case uploading
        /// Every artefact received_verified; waiting for the server quality verdict.
        case awaitingVerdict
        case accepted
        case needsRepeat
        /// The server ended the session without further attempts (DS_QG_099); never ask for a repeat.
        case closed
        case quarantined
    }

    public let sessionId: UUID
    public let maskedCode: String
    public var scanId: UUID?
    public var artefacts: [ArtefactUpload]
    /// Keys destroyed and local sealed files deleted.
    public var localDataDestroyed = false
    public var verdict: Verdict = .uploading
    public var repeatReasons: [ReasonCode] = []
    /// Steps the nurse must record again (with `.needsRepeat`).
    public var repeatSteps: [CaptureStepName] = []
    /// Nurse-facing copy for a closed session (e.g. `NurseCopy.acquisitionFailure`).
    public var notice: String?
    /// createScan `captured_at` (drives the 2 h repeat window and the 7-day unsent flag). nil = unknown.
    public var capturedAt: Date?
    /// Highest attempt per step the server reported (GET /scans); recapture attempts follow it.
    public var serverAttempts: [String: Int]?

    public init(sessionId: UUID, maskedCode: String, scanId: UUID?, artefacts: [ArtefactUpload]) {
        self.sessionId = sessionId; self.maskedCode = maskedCode; self.scanId = scanId; self.artefacts = artefacts
    }
}

public protocol UploadSessionStore: AnyObject {
    func load(_ sessionId: UUID) throws -> UploadSessionRecord?
    func loadAll() throws -> [UploadSessionRecord]
    func save(_ record: UploadSessionRecord) throws
}

public final class InMemoryUploadSessionStore: UploadSessionStore {
    private var records: [UUID: UploadSessionRecord] = [:]
    private var order: [UUID] = []
    private let lock = NSLock()
    public init() {}
    public func load(_ sessionId: UUID) throws -> UploadSessionRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[sessionId]
    }
    public func loadAll() throws -> [UploadSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { records[$0] }
    }
    public func save(_ record: UploadSessionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        if records[record.sessionId] == nil { order.append(record.sessionId) }
        records[record.sessionId] = record
    }
}

/// One JSON file per session, written atomically (temp file + move).
public final class FileUploadSessionStore: UploadSessionStore {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString.lowercased()).json") }

    public func load(_ sessionId: UUID) throws -> UploadSessionRecord? {
        lock.lock(); defer { lock.unlock() }
        let u = url(sessionId)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try JSONDecoder().decode(UploadSessionRecord.self, from: Data(contentsOf: u))
    }

    public func loadAll() throws -> [UploadSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try JSONDecoder().decode(UploadSessionRecord.self, from: Data(contentsOf: $0)) }
    }

    public func save(_ record: UploadSessionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let dest = url(record.sessionId)
        let tmp = directory.appendingPathComponent("\(UUID().uuidString).tmp")
        try JSONEncoder().encode(record).write(to: tmp)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                #if os(Windows)
                try fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                #else
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                #endif
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
