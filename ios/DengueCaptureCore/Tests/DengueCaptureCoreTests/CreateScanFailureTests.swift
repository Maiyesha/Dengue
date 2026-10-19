import XCTest
import Foundation
@testable import DengueCaptureCore

/// R-1: only DS_SCAN_001, DS_VALIDATION_* and DS_NOT_FOUND on createScan may close a session and destroy its
/// data. A captive portal, WAF or proxy response (no DengueSense error envelope), an unrecognised DS_* code and
/// any local error keep the data and retry with the same idempotency key.
final class CreateScanFailureTests: XCTestCase {
    var dir: URL!
    var clock: TestClock!
    var outbox: Outbox!
    var log: EventLog!
    var api: FakeUploadAPI!
    var keys: InMemoryKeyStore!
    var sessions: InMemoryUploadSessionStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("r1-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = TestClock()
        outbox = Outbox(store: try! FileOutboxStore(directory: dir.appendingPathComponent("ob")), clock: clock)
        log = EventLog()
        api = FakeUploadAPI(log: log)
        keys = InMemoryKeyStore()
        sessions = InMemoryUploadSessionStore()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeEngine() -> UploadEngine {
        UploadEngine(outbox: outbox, api: api, sessions: sessions, keys: keys, uploader: FakePartUploader(log: log),
                     notifier: FakeNotifier(), partSize: 1000, now: { [clock] in clock!.wallNow })
    }

    func artefact() throws -> ArtefactUpload {
        let (keyId, _) = try keys.newKey()
        let path = dir.appendingPathComponent("\(UUID().uuidString).sealed")
        try Data(count: 300).write(to: path)
        let sealed = SealedArtefact(keyId: keyId, path: path, sha256OfPlaintext: "p", sizeBytes: 260,
                                    sha256OfCiphertext: String(repeating: "c", count: 64), sealedSizeBytes: 300,
                                    wrappedKey: WrappedKey(wrappedKeyB64: "V1JBUA==", kmsKeyId: "kms"))
        return ArtefactUpload(step: .neutralFace, attempt: 1, kind: .video, deviceVerdict: .accept, sealed: sealed)
    }

    func enqueue(_ e: UploadEngine, _ arts: [ArtefactUpload]) throws -> UUID {
        let s = UUID()
        try e.enqueueSession(sessionId: s, participantCode: "DS-2026-00417", createScan: request(s), scanId: nil,
                             artefacts: arts)
        return s
    }

    func request(_ s: UUID) -> CreateScanRequest {
        CreateScanRequest(
            clientSessionId: s, patientId: UUID(), capturedAt: clock.wallNow, offline: false, protocolVersion: "1",
            captureSteps: [.neutralFace], deviceAttempts: [],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: nil,
                                   ambientHumidityPct: nil, mount: "holder", lightingType: "overhead",
                                   exposureDurationMs: 10))
    }

    func alive(_ a: ArtefactUpload) -> Bool {
        FileManager.default.fileExists(atPath: a.sealed.path.path) && (try? keys.key(id: a.sealed.keyId)) != nil
    }

    func envelope(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"m","detail":{},"request_id":"r","trace_id":"t","timestamp":"2026-01-01T00:00:00Z"}}"#.utf8)
    }

    static let portalHTML = Data("<html><body><form action=\"/login\">Hospital Wi-Fi sign in</form></body></html>".utf8)

    func createItem(_ s: UUID) throws -> OutboxItem {
        try XCTUnwrap(outbox.items(sessionId: s).first { $0.kind == .createScan })
    }

    // MARK: regression tests

    func testCaptivePortalHTML403OnCreateScanKeepsKeysAndFilesAndSchedulesRetry() async throws {
        let e = makeEngine()
        let a = try artefact()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: Self.portalHTML, status: 403)]
        let s = try enqueue(e, [a])
        await e.drain()
        XCTAssertTrue(alive(a), "a Wi-Fi login page must never delete the only copy of a recording")
        let rec = try XCTUnwrap(e.record(s))
        XCTAssertEqual(rec.verdict, .uploading)
        XCTAssertFalse(rec.localDataDestroyed)
        let item = try createItem(s)
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.attempts, 1)
        XCTAssertGreaterThan(item.nextAttemptAt, clock.wallNow, "outbox backoff")
        XCTAssertEqual(e.status(s), .queued)
    }

    func testOtherNonEnvelopeResponsesKeepData() async throws {
        for status in [400, 403, 404, 413, 422, 429, 302] {
            let e = makeEngine()
            let a = try artefact()
            api.createScanErrors = [URLSessionDengueAPI.decodeError(data: Self.portalHTML, status: status)]
            let s = try enqueue(e, [a])
            await e.drain()
            XCTAssertTrue(alive(a), "status \(status)")
            XCTAssertEqual(try createItem(s).status, .pending, "status \(status)")
            XCTAssertNotEqual(e.record(s)?.verdict, .closed, "status \(status)")
        }
    }

    func testUnrecognisedDSCodeKeepsDataAndRetries() async throws {
        let e = makeEngine()
        let a = try artefact()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_FOO_999"), status: 400)]
        let s = try enqueue(e, [a])
        await e.drain()
        XCTAssertTrue(alive(a))
        XCTAssertEqual(try createItem(s).status, .pending)
        XCTAssertEqual(e.record(s)?.verdict, .uploading)
    }

    func testDuplicateWithin30MinStillClosesWithNotice() async throws {
        let e = makeEngine()
        let a = try artefact()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_SCAN_001"), status: 409)]
        let s = try enqueue(e, [a])
        await e.drain()
        XCTAssertEqual(e.status(s), .closed(notice: NurseCopy.recentScan))
        XCTAssertFalse(alive(a))
    }

    func testValidationAndNotFoundEnvelopesStillClose() async throws {
        for (code, status) in [("DS_VALIDATION_001", 422), ("DS_VALIDATION_002", 400), ("DS_NOT_FOUND", 404)] {
            let e = makeEngine()
            let a = try artefact()
            api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope(code), status: status)]
            let s = try enqueue(e, [a])
            await e.drain()
            XCTAssertEqual(e.status(s), .closed(notice: NurseCopy.uploadRejected), code)
            XCTAssertFalse(alive(a), code)
        }
    }

    func testRetriesReuseTheSameIdempotencyKeyAndThenUpload() async throws {
        let e = makeEngine()
        let a = try artefact()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: Self.portalHTML, status: 403),
                                URLSessionDengueAPI.decodeError(data: envelope("DS_FOO_999"), status: 400)]
        let s = try enqueue(e, [a])
        let key = try createItem(s).idempotencyKey.uuidString
        await e.drain()
        clock.wallNow = clock.wallNow.addingTimeInterval(Outbox.maxBackoff + 1)
        await e.drain()
        clock.wallNow = clock.wallNow.addingTimeInterval(Outbox.maxBackoff + 1)
        await e.drain()
        XCTAssertEqual(api.createScanKeys, [key, key, key])
        XCTAssertEqual(e.status(s), .sent)
    }

    func testLocalErrorOnCreateScanKeepsData() async throws {
        let e = makeEngine()
        let a = try artefact()
        let s = UUID()
        try e.enqueueSession(sessionId: s, participantCode: "DS-2026-00417",
                             createScan: request(s),
                             scanId: nil, artefacts: [a])
        // Corrupt the createScan payload: the engine fails locally with LOCAL_BAD_PAYLOAD.
        var item = try createItem(s)
        item.payload = Data("{".utf8)
        try FileOutboxStore(directory: dir.appendingPathComponent("ob")).upsert(item)
        await e.drain()
        XCTAssertTrue(alive(a))
        XCTAssertNotEqual(e.record(s)?.verdict, .closed)
    }

    // MARK: policy table

    func testCreateScanFailurePolicyTable() {
        let table: [(APIError, CreateScanFailurePolicy.Decision)] = [
            (.duplicateRecent, .closeAndDestroy(notice: NurseCopy.recentScan)),
            (.invalid(code: "DS_VALIDATION_001"), .closeAndDestroy(notice: NurseCopy.uploadRejected)),
            (.invalid(code: "DS_VALIDATION_002"), .closeAndDestroy(notice: NurseCopy.uploadRejected)),
            (.invalid(code: "DS_NOT_FOUND"), .closeAndDestroy(notice: NurseCopy.uploadRejected)),
            (.networkRestricted(httpStatus: 403), .retry),
            (.networkRestricted(httpStatus: 200), .retry),
            (.networkRestricted(httpStatus: 302), .retry),
            (.retryable, .retry),
            (.unauthorized, .retry),
            (.uploadIncomplete, .retry),
            (.invalid(code: "DS_FOO_999"), .retry),
            (.invalid(code: ""), .retry),
            (.invalid(code: "DS_VALIDATION_"), .retry),
            (.invalid(code: "LOCAL_BAD_PAYLOAD"), .retry),
            (.invalid(code: "KMS_KEY_MISSING"), .retry),
            (.invalid(code: "DS_SCAN_002"), .hold(diagnostic: "DS_SCAN_002")),
            (.invalid(code: "DS_AUTH_002"), .hold(diagnostic: "DS_AUTH_002")),
            (.invalid(code: "DS_IDEMPOTENCY_001"), .hold(diagnostic: "DS_IDEMPOTENCY_001")),
            (.uploadHashMismatch, .hold(diagnostic: "DS_UPLOAD_001")),
            (.reEnrol, .hold(diagnostic: "DS_DEVICE_001")),
            // Round 2 (I3): only the consent stops are a server directive on createScan.
            (.stopAndQuarantine(code: "DS_REG_001"), .serverDirective),
            (.stopAndQuarantine(code: "DS_REG_002"), .serverDirective),
            (.stopAndQuarantine(code: "DS_REG_901"), .hold(diagnostic: "DS_REG_901")),
            (.needsRepeat([.dsQG001]), .hold(diagnostic: "DS_QG_001")),
            (.needsRepeat([]), .hold(diagnostic: "DS_QG_UNNAMED")),   // e.g. DS_QG_123, DS_SEG_9, DS_RPPG_42
            (APIError.from(code: "DS_QG_123", httpStatus: 422), .hold(diagnostic: "DS_QG_UNNAMED")),
            (APIError.from(code: "DS_SEG_9", httpStatus: 422), .hold(diagnostic: "DS_QG_UNNAMED")),
            (APIError.from(code: "DS_REG_977", httpStatus: 451), .hold(diagnostic: "DS_REG_977")),
            (.recaptureExhausted(unableToAcquire: [], recaptured: [], status: "partial"), .hold(diagnostic: "DS_QG_099")),
        ]
        for (error, expected) in table {
            let d = CreateScanFailurePolicy.decide(error: error)
            XCTAssertEqual(d, expected, "\(error)")
            if case .closeAndDestroy = d {
                XCTAssertTrue(CreateScanFailurePolicy.permitsDestroy(error), "\(error)")
            } else if case .serverDirective = d {
                XCTAssertTrue(CreateScanFailurePolicy.permitsDestroy(error), "consent stop \(error)")
            } else {
                XCTAssertFalse(CreateScanFailurePolicy.permitsDestroy(error), "guard must refuse \(error)")
            }
        }
    }

    func testRecognisedNonDestroyCodeIsHeldWithDiagnosticAndKept() async throws {
        let e = makeEngine()
        let a = try artefact()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_SCAN_002"), status: 409)]
        let s = try enqueue(e, [a])
        await e.drain()
        XCTAssertTrue(alive(a))
        XCTAssertEqual(e.record(s)?.diagnostic, "DS_SCAN_002")
        XCTAssertEqual(try createItem(s).status, .pending)
        clock.wallNow = clock.wallNow.addingTimeInterval(Outbox.maxBackoff + 1)
        await e.drain()
        XCTAssertNil(e.record(s)?.diagnostic)
        XCTAssertEqual(e.status(s), .sent)
    }

    // MARK: captive-portal signal

    func testNonEnvelopeResponseMarksNetworkRestrictedUntilASuccess() async throws {
        let e = makeEngine()
        var changes: [Bool] = []
        e.onNetworkRestrictedChange = { changes.append($0) }
        let a = try artefact()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: Self.portalHTML, status: 403)]
        let s = try enqueue(e, [a])
        await e.drain()
        XCTAssertTrue(e.isNetworkRestricted)
        XCTAssertNotEqual(e.record(s)?.verdict, .closed, "never treated as a failure")
        clock.wallNow = clock.wallNow.addingTimeInterval(Outbox.maxBackoff + 1)
        await e.drain()
        XCTAssertFalse(e.isNetworkRestricted)
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(e.status(s), .sent)
    }

    func testEnvelopeErrorsDoNotSignalNetworkRestricted() async throws {
        let e = makeEngine()
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_FOO_999"), status: 400)]
        _ = try enqueue(e, [try artefact()])
        await e.drain()
        XCTAssertFalse(e.isNetworkRestricted)
    }

    func testNetworkNeedsSignInCopyIsLinted() {
        XCTAssertEqual(NurseCopy.networkNeedsSignIn, "Network needs sign-in \u{2014} recordings are kept on the phone")
        XCTAssertTrue(NurseCopy.allStrings.contains(NurseCopy.networkNeedsSignIn))
        XCTAssertTrue(NurseCopy.forbiddenTerms(in: NurseCopy.networkNeedsSignIn).isEmpty)
    }

    // MARK: response classification (URLSessionDengueAPI)

    func testResponseClassification() {
        let host = "api.denguesense.test"
        let apiURL = URL(string: "https://api.denguesense.test/v1/scans")!
        let portal = URL(string: "http://login.hospital-wifi.example/portal")!
        let json = "application/json; charset=utf-8"
        // Redirected to a portal: restricted whatever the status.
        XCTAssertEqual(URLSessionDengueAPI.responseError(status: 200, data: Self.portalHTML, finalURL: portal,
                                                         contentType: "text/html", apiHost: host),
                       .networkRestricted(httpStatus: 200))
        XCTAssertEqual(URLSessionDengueAPI.responseError(status: 403, data: envelope("DS_NOT_FOUND"), finalURL: portal,
                                                         contentType: json, apiHost: host),
                       .networkRestricted(httpStatus: 403), "an envelope from another host is not ours")
        // 2xx HTML from the API host (transparent proxy): restricted. 2xx JSON / empty: fine.
        XCTAssertEqual(URLSessionDengueAPI.responseError(status: 200, data: Self.portalHTML, finalURL: apiURL,
                                                         contentType: "text/html", apiHost: host),
                       .networkRestricted(httpStatus: 200))
        XCTAssertNil(URLSessionDengueAPI.responseError(status: 201, data: Data("{}".utf8), finalURL: apiURL,
                                                       contentType: json, apiHost: host))
        XCTAssertNil(URLSessionDengueAPI.responseError(status: 204, data: Data(), finalURL: apiURL,
                                                       contentType: nil, apiHost: host))
        // Unfollowed redirect / non-envelope 4xx: restricted. Envelope wins. Bare 5xx / 401 keep their meaning.
        XCTAssertEqual(URLSessionDengueAPI.responseError(status: 302, data: Data(), finalURL: apiURL,
                                                         contentType: nil, apiHost: host),
                       .networkRestricted(httpStatus: 302))
        for status in [400, 403, 404, 413, 429] {
            XCTAssertEqual(URLSessionDengueAPI.decodeError(data: Self.portalHTML, status: status),
                           .networkRestricted(httpStatus: status))
        }
        XCTAssertEqual(URLSessionDengueAPI.decodeError(data: Data(#"{"error":{"code":"Forbidden"}}"#.utf8), status: 403),
                       .networkRestricted(httpStatus: 403), "a WAF's JSON is not a DengueSense envelope")
        XCTAssertEqual(URLSessionDengueAPI.decodeError(data: envelope("DS_SCAN_001"), status: 409), .duplicateRecent)
        XCTAssertEqual(URLSessionDengueAPI.decodeError(data: envelope("DS_RATE_001"), status: 429), .retryable)
        XCTAssertEqual(URLSessionDengueAPI.decodeError(data: Self.portalHTML, status: 502), .retryable)
        XCTAssertEqual(URLSessionDengueAPI.decodeError(data: Data(), status: 401), .unauthorized)
    }

    func testOutboxReschedulesNetworkRestrictedLikeRetryable() throws {
        let item = try outbox.enqueue(.createScan, sessionId: UUID(), payload: Data())
        XCTAssertEqual(try outbox.apply(.networkRestricted(httpStatus: 403), to: item.id), .retryScheduled)
        XCTAssertEqual(try outbox.item(item.id)?.idempotencyKey, item.idempotencyKey)
    }
}
