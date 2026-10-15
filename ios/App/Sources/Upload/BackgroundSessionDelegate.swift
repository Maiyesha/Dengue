import Foundation
import DengueCaptureCore

/// Background-`URLSession` implementation of the core `PartUploader`.
///
/// - One `uploadTask(with:fromFile:)` per part. The part's byte range is first copied to its own temp file
///   (background sessions upload only from files), written with `.completeUntilFirstUserAuthentication`
///   (Class C: readable by the transfer daemon while the phone is locked after first unlock) and excluded
///   from backup. The bytes are already sealed ciphertext.
/// - `taskDescription` = core part id (`<artefact id>/<n>`), so completions map back to the waiting call,
///   or — after a relaunch, when nobody is waiting — are stored on disk and handed to the engine through
///   `existingOutcome(partId:)`.
/// - The pre-signed URL carries its own authorisation: no bearer token is ever attached to the S3 PUT.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml. Exercise on a real device
/// launched from the Home screen (the debugger prevents suspension).
final class BackgroundPartUploader: NSObject, PartUploader, URLSessionTaskDelegate, URLSessionDelegate {
    static let identifier = UploadEngine.backgroundSessionIdentifier

    private let partsDir: URL
    private let finishedFile: URL
    private let lock = NSLock()
    /// Live callers keyed by task identifier (not part id, so a cancelled stale task never wakes a new caller).
    private var waiters: [Int: [CheckedContinuation<PartUploadOutcome, Never>]] = [:]
    /// Completions nobody was waiting for (background relaunch). Persisted; consumed by `existingOutcome`.
    private var finished: [String: Outcome] = [:]
    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    private var eventsCompletionHandler: (() -> Void)?
    /// Called after a part completes (also when nobody waits), so the app can drain in a background wake.
    var onPartFinished: (() -> Void)?

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = UploadEngine.backgroundSessionIdentifier + ".delegate"
        return q
    }()

    /// Created exactly once at the end of `init` (it needs `self` as delegate) and never reassigned, so reads
    /// from any thread after init are race-free. Creating it at init also reconnects iOS's pending events.
    private var session: URLSession!

    /// Codable mirror of `PartUploadOutcome` for the on-disk map.
    private enum Outcome: Codable, Equatable {
        case success, http(Int), transport
        init(_ o: PartUploadOutcome) {
            switch o {
            case .success: self = .success
            case .httpStatus(let c): self = .http(c)
            case .transportError: self = .transport
            }
        }
        var value: PartUploadOutcome {
            switch self {
            case .success: return .success
            case .http(let c): return .httpStatus(c)
            case .transport: return .transportError
            }
        }
    }

    init(baseDirectory: URL) throws {
        partsDir = baseDirectory.appendingPathComponent("UploadParts", isDirectory: true)
        finishedFile = partsDir.appendingPathComponent("finished.json")
        super.init()
        try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var dir = partsDir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try dir.setResourceValues(rv)
        if let d = try? Data(contentsOf: finishedFile),
           let m = try? JSONDecoder().decode([String: Outcome].self, from: d) {
            finished = m
        }
        let cfg = URLSessionConfiguration.background(withIdentifier: UploadEngine.backgroundSessionIdentifier)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.allowsCellularAccess = true
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }

    /// AppDelegate: store the handler; it is called from `urlSessionDidFinishEvents`.
    func handleEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else { completionHandler(); return }
        lock.lock(); eventsCompletionHandler = completionHandler; lock.unlock()
    }

    // MARK: PartUploader

    func upload(file: URL, part: UploadPart, to url: URL, partId: String) async -> PartUploadOutcome {
        // A stale task for the same part (old URL) must not race the new one.
        for t in await session.allTasks where t.taskDescription == partId { t.cancel() }
        lock.lock(); finished[partId] = nil; persistFinishedLocked(); lock.unlock()

        let partFile: URL
        do { partFile = try writePartFile(from: file, part: part, partId: partId) } catch { return .transportError }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: req, fromFile: partFile)
        task.taskDescription = partId
        task.countOfBytesClientExpectsToSend = part.length
        task.countOfBytesClientExpectsToReceive = 1024
        return await withCheckedContinuation { cont in
            lock.lock()
            waiters[task.taskIdentifier, default: []].append(cont)
            lock.unlock()
            task.resume()
        }
    }

    func existingOutcome(partId: String) async -> PartUploadOutcome? {
        lock.lock()
        if let o = finished.removeValue(forKey: partId) {
            persistFinishedLocked()
            lock.unlock()
            return o.value
        }
        lock.unlock()
        guard let running = await session.allTasks.first(where: {
            $0.taskDescription == partId && ($0.state == .running || $0.state == .suspended)
        }) else { return nil }
        return await withCheckedContinuation { cont in
            lock.lock()
            if let o = finished.removeValue(forKey: partId) {   // finished between the two checks
                persistFinishedLocked()
                lock.unlock()
                cont.resume(returning: o.value)
                return
            }
            waiters[running.taskIdentifier, default: []].append(cont)
            lock.unlock()
            if running.state == .suspended { running.resume() }
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let partId = task.taskDescription else { return }
        let outcome: PartUploadOutcome
        if let e = error as NSError?, e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled,
           e.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] == nil {
            // Cancelled by us (superseded task): wake its own waiters, store nothing for the part.
            resume(task.taskIdentifier, partId, .transportError, storeIfNoWaiter: false)
            return
        }
        if error != nil {
            outcome = .transportError
        } else if let http = task.response as? HTTPURLResponse {
            outcome = (200..<300).contains(http.statusCode) ? .success : .httpStatus(http.statusCode)
        } else {
            outcome = .transportError
        }
        try? FileManager.default.removeItem(at: partFileURL(partId))
        resume(task.taskIdentifier, partId, outcome, storeIfNoWaiter: true)
        onPartFinished?()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = eventsCompletionHandler
        eventsCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    // MARK: helpers

    private func resume(_ taskId: Int, _ partId: String, _ outcome: PartUploadOutcome, storeIfNoWaiter: Bool) {
        lock.lock()
        let ws = waiters.removeValue(forKey: taskId) ?? []
        if ws.isEmpty && storeIfNoWaiter {
            finished[partId] = Outcome(outcome)
            persistFinishedLocked()
        }
        lock.unlock()
        for w in ws { w.resume(returning: outcome) }
    }

    private func persistFinishedLocked() {
        guard let d = try? JSONEncoder().encode(finished) else { return }
        try? d.write(to: finishedFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func partFileURL(_ partId: String) -> URL {
        partsDir.appendingPathComponent(partId.replacingOccurrences(of: "/", with: "_") + ".part")
    }

    /// Copies the part's byte range of the sealed file into its own Class C, backup-excluded file.
    private func writePartFile(from file: URL, part: UploadPart, partId: String) throws -> URL {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(part.offset))
        let data = try h.read(upToCount: Int(part.length)) ?? Data()
        guard data.count == Int(part.length) else { throw CocoaError(.fileReadCorruptFile) }
        var dest = partFileURL(partId)
        try data.write(to: dest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: dest.path)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try dest.setResourceValues(rv)
        return dest
    }
}
