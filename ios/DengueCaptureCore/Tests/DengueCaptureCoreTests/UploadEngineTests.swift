import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DengueCaptureCore

/// Shared ordered event log so tests can assert interleaving of API and uploader calls.
final class EventLog {
    var events: [String] = []
}

final class FakeUploadAPI: DengueAPI {
    struct Unexpected: Error {}
    let log: EventLog
    var artefactIds: [UUID] = []
    var declares: [(scanId: UUID, request: DeclareArtefactRequest, key: String)] = []
    var completeKeys: [UUID: [String]] = [:]
    var partURLCalls: [(UUID, Int)] = []
    var getScanAuth: [AuthKind] = []
    /// Per-call scripted errors, consumed in order.
    var declareErrors: [APIError?] = []
    /// Scripted complete results in call order (nil = success).
    var completeErrorQueue: [APIError?] = []
    var recaptureErrors: [APIError?] = []
    var createScanErrors: [APIError?] = []
    var scanResponse: ScanResponse?
    let scanId = UUID()

    init(log: EventLog) { self.log = log }

    func createScan(_ request: CreateScanRequest, idempotencyKey: String) async throws -> CreateScanResponse {
        log.events.append("createScan")
        if !createScanErrors.isEmpty, let e = createScanErrors.removeFirst() { throw e }
        let json = #"{"scan":{"id":"\#(scanId.uuidString)","status":"capture_pending","client_session_id":"\#(request.clientSessionId.uuidString)"}}"#
        return try JSONDecoder().decode(CreateScanResponse.self, from: Data(json.utf8))
    }
    func getScan(id: UUID, auth: AuthKind) async throws -> ScanResponse {
        log.events.append("getScan")
        getScanAuth.append(auth)
        guard let r = scanResponse else { throw APIError.retryable }
        return r
    }
    func recapture(scanId: UUID, steps: [CaptureStepName], reason: String, idempotencyKey: String) async throws -> ScanResponse {
        log.events.append("recapture")
        if !recaptureErrors.isEmpty, let e = recaptureErrors.removeFirst() { throw e }
        guard let r = scanResponse else { throw APIError.retryable }
        return r
    }
    func declareArtefact(scanId: UUID, request: DeclareArtefactRequest, idempotencyKey: String) async throws -> DeclareArtefactResponse {
        log.events.append("declare")
        if !declareErrors.isEmpty, let e = declareErrors.removeFirst() { throw e }
        declares.append((scanId, request, idempotencyKey))
        let id = UUID()
        artefactIds.append(id)
        return try JSONDecoder().decode(DeclareArtefactResponse.self,
            from: Data(#"{"artefact_id":"\#(id.uuidString)","upload_id":"u"}"#.utf8))
    }
    func partURL(artefactId: UUID, part: Int) async throws -> PartURLResponse {
        partURLCalls.append((artefactId, part))
        let n = partURLCalls.filter { $0.0 == artefactId && $0.1 == part }.count
        log.events.append("mint \(part)")
        return try JSONDecoder().decode(PartURLResponse.self,
            from: Data(#"{"url":"https://s3.test/\#(artefactId.uuidString)/\#(part)?v=\#(n)","expires_in":900}"#.utf8))
    }
    func completeArtefact(id: UUID, idempotencyKey: String) async throws -> CompleteArtefactResponse {
        log.events.append("complete")
        completeKeys[id, default: []].append(idempotencyKey)
        if !completeErrorQueue.isEmpty, let e = completeErrorQueue.removeFirst() { throw e }
        return CompleteArtefactResponse(status: "received_verified")
    }

    func lookup(participantCode: String) async throws -> PatientLookup { throw Unexpected() }
    func roster(wardId: String) async throws -> Roster { throw Unexpected() }
    func consentStatus(patientId: UUID) async throws -> ConsentStatus { throw Unexpected() }
    func postClinicalData(patientId: UUID, request: ClinicalDataRequest, idempotencyKey: String) async throws -> ClinicalDataResponse { throw Unexpected() }
    func experimental(scanId: UUID) async throws -> ExperimentalResponse { throw Unexpected() }
    func reviewChallenge(scanId: UUID, action: ReviewAction, reasonCode: String?, note: String?) async throws -> ReviewChallengeResponse { throw Unexpected() }
    func review(scanId: UUID, challengeId: UUID, action: ReviewAction, reasonCode: String?, note: String?,
                webauthnAssertion: [String: JSONValue], idempotencyKey: String) async throws -> ReviewResponse { throw Unexpected() }
    func registerPushToken(deviceId: UUID, apnsToken: String, idempotencyKey: String) async throws { throw Unexpected() }
    func deviceChallenge(idempotencyKey: String) async throws -> DeviceChallengeResponse { throw Unexpected() }
    func attest(keyId: String, attestation: String, challenge: String, wardId: String, idempotencyKey: String) async throws -> AttestResponse { throw Unexpected() }
    func assert(deviceId: UUID, assertion: String, challenge: String, asUser: Bool) async throws -> AssertResponse { throw Unexpected() }
    func renewalChallenge(deviceId: UUID) async throws -> DeviceChallengeResponse { throw Unexpected() }
}

final class FakePartUploader: PartUploader {
    struct Call: Equatable { let file: URL; let part: UploadPart; let url: URL; let partId: String }
    let log: EventLog
    var calls: [Call] = []
    /// Scripted outcomes per part number, consumed in order; default success.
    var outcomes: [Int: [PartUploadOutcome]] = [:]
    var existing: [String: PartUploadOutcome] = [:]
    var bytesSeen: [Int: Data] = [:]
    /// When set, every upload waits on it (to hold a drain mid-flight).
    var gate: Gate?

    init(log: EventLog) { self.log = log }

    func upload(file: URL, part: UploadPart, to url: URL, partId: String) async -> PartUploadOutcome {
        log.events.append("upload \(part.number)")
        calls.append(Call(file: file, part: part, url: url, partId: partId))
        if let gate { await gate.wait() }
        if let h = try? FileHandle(forReadingFrom: file) {
            try? h.seek(toOffset: UInt64(part.offset))
            bytesSeen[part.number] = (try? h.read(upToCount: Int(part.length))) ?? Data()
            try? h.close()
        }
        if var o = outcomes[part.number], !o.isEmpty {
            let r = o.removeFirst()
            outcomes[part.number] = o
            return r
        }
        return .success
    }
    func existingOutcome(partId: String) async -> PartUploadOutcome? { existing[partId] }
}

final class FakeNotifier: RepeatNotifier {
    var texts: [String] = []
    func postRepeatNotice(_ text: String) { texts.append(text) }
}

final class UploadEngineTests: XCTestCase {
    var dir: URL!
    var clock: TestClock!
    var outbox: Outbox!
    var log: EventLog!
    var api: FakeUploadAPI!
    var uploader: FakePartUploader!
    var notifier: FakeNotifier!
    var keys: InMemoryKeyStore!
    var sessions: InMemoryUploadSessionStore!
    let participantCode = "DS-2026-00417"

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = TestClock()
        outbox = Outbox(store: try! FileOutboxStore(directory: dir.appendingPathComponent("ob")), clock: clock)
        log = EventLog()
        api = FakeUploadAPI(log: log)
        uploader = FakePartUploader(log: log)
        notifier = FakeNotifier()
        keys = InMemoryKeyStore()
        sessions = InMemoryUploadSessionStore()
        StubProtocol.handler = nil
        StubProtocol.captured = []
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeEngine(api: DengueAPI? = nil, partSize: Int64 = 1000) -> UploadEngine {
        UploadEngine(outbox: outbox, api: api ?? self.api, sessions: sessions, keys: keys,
                     uploader: uploader, notifier: notifier, partSize: partSize, now: { [clock] in clock!.wallNow })
    }

    /// A "sealed" file of `size` random bytes with a real key in the key store.
    func makeArtefact(size: Int, step: CaptureStepName = .neutralFace, kind: ArtefactKind = .video) throws -> ArtefactUpload {
        let (keyId, _) = try keys.newKey()
        let path = dir.appendingPathComponent("\(UUID().uuidString).sealed")
        var bytes = Data(count: size)
        for i in 0..<size { bytes[i] = UInt8.random(in: 0...255) }
        try bytes.write(to: path)
        let sealed = SealedArtefact(keyId: keyId, path: path, sha256OfPlaintext: "plain-sha", sizeBytes: Int64(size) - 40,
                                    sha256OfCiphertext: String(repeating: "c", count: 64), sealedSizeBytes: Int64(size),
                                    wrappedKey: WrappedKey(wrappedKeyB64: "d3JhcHBlZA==", kmsKeyId: "kms-test"))
        return ArtefactUpload(step: step, attempt: 1, kind: kind, deviceVerdict: .accept, sealed: sealed)
    }

    func createScanRequest(_ session: UUID) -> CreateScanRequest {
        CreateScanRequest(
            clientSessionId: session, patientId: UUID(), capturedAt: WireDate.string(from: clock.wallNow), offline: true,
            protocolVersion: "1", captureSteps: [.neutralFace, .fingertipPPG],
            deviceAttempts: [DeviceAttempt(step: .neutralFace, attempt: 1, deviceVerdict: .accept, reasonCodes: [])],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: 28,
                                   ambientHumidityPct: 70, mount: "handheld", lightingType: "led",
                                   exposureDurationMs: 10))
    }

    @discardableResult
    func enqueue(_ engine: UploadEngine, _ artefacts: [ArtefactUpload], session: UUID = UUID()) throws -> UUID {
        try engine.enqueueSession(sessionId: session, participantCode: participantCode,
                                  createScan: createScanRequest(session), scanId: nil, artefacts: artefacts)
        return session
    }

    func fileExists(_ a: ArtefactUpload) -> Bool { FileManager.default.fileExists(atPath: a.sealed.path.path) }
    func keyExists(_ a: ArtefactUpload) -> Bool { (try? keys.key(id: a.sealed.keyId)) != nil }

    func scan(status: ScanStatus, steps: [(String, String?, [String])]) throws -> ScanResponse {
        let stepsJSON = steps.map { s in
            let v = s.1.map { "\"\($0)\"" } ?? "null"
            let rc = s.2.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"step":"\#(s.0)","attempt":1,"device_verdict":"ACCEPT","server_verdict":\#(v),"reason_codes":[\#(rc)]}"#
        }.joined(separator: ",")
        let json = #"{"scan":{"id":"\#(api.scanId.uuidString)","status":"\#(status.rawValue)","steps":[\#(stepsJSON)],"recaptures_remaining":{"neutral_face":2}}}"#
        return try JSONDecoder().decode(ScanResponse.self, from: Data(json.utf8))
    }

    // MARK: part planning

    func testPartSplittingAt8MiBWithNonMultipleTail() {
        let mib: Int64 = 1024 * 1024
        XCTAssertEqual(UploadPart.defaultSize, 8 * mib)
        let parts = UploadPart.plan(totalSize: 2 * 8 * mib + 12_345)
        XCTAssertEqual(parts, [
            UploadPart(number: 1, offset: 0, length: 8 * mib),
            UploadPart(number: 2, offset: 8 * mib, length: 8 * mib),
            UploadPart(number: 3, offset: 16 * mib, length: 12_345),
        ])
        XCTAssertEqual(UploadPart.plan(totalSize: 8 * mib).count, 1)
        XCTAssertEqual(UploadPart.plan(totalSize: 1), [UploadPart(number: 1, offset: 0, length: 1)])
        XCTAssertEqual(UploadPart.plan(totalSize: 0), [])
    }

    func testEngineUsesDefault8MiBParts() async throws {
        let engine = UploadEngine(outbox: outbox, api: api, sessions: sessions, keys: keys,
                                  uploader: uploader, notifier: notifier)
        let a = try makeArtefact(size: 10)
        try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(uploader.calls.map { $0.part }, [UploadPart(number: 1, offset: 0, length: 10)])
    }

    func testPartsCoverTheWholeSealedFileInOrder() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 2500)
        let original = try Data(contentsOf: a.sealed.path)
        try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(uploader.calls.map { $0.part.length }, [1000, 1000, 500])
        let joined = (1...3).reduce(Data()) { $0 + (uploader.bytesSeen[$1] ?? Data()) }
        XCTAssertEqual(joined, original)
        XCTAssertTrue(uploader.calls.allSatisfy { $0.file == a.sealed.path })
    }

    // MARK: brief tests

    func testPartURLMintedLazilyPerPart() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 2500)
        try enqueue(engine, [a])
        await engine.drain()
        let tail = log.events.drop { $0 != "mint 1" }
        XCTAssertEqual(Array(tail), ["mint 1", "upload 1", "mint 2", "upload 2", "mint 3", "upload 3", "complete"])
        let artefactId = try XCTUnwrap(api.artefactIds.first)
        XCTAssertEqual(uploader.calls.map { $0.partId },
                       (1...3).map { "\(artefactId.uuidString.lowercased())/\($0)" })
        XCTAssertEqual(uploader.calls.map { $0.url.absoluteString },
                       (1...3).map { "https://s3.test/\(artefactId.uuidString)/\($0)?v=1" })
    }

    func testExpiredPartURL403ReMintedAndRetriedOnce() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 1500)
        uploader.outcomes[2] = [.httpStatus(403)]
        try enqueue(engine, [a])
        await engine.drain()
        let tail = log.events.drop { $0 != "mint 1" }
        XCTAssertEqual(Array(tail), ["mint 1", "upload 1", "mint 2", "upload 2", "mint 2", "upload 2", "complete"])
        XCTAssertTrue(uploader.calls[2].url.absoluteString.hasSuffix("/2?v=2"), "retry uses the fresh URL")
        XCTAssertEqual(try sessions.loadAll().first?.artefacts.first?.status, .verified)
    }

    func testSecond403IsNotRetriedAgainAndItemIsRescheduled() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 500)
        uploader.outcomes[1] = [.httpStatus(403), .httpStatus(403)]
        let s = try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(log.events.filter { $0 == "upload 1" }.count, 2, "exactly one retry")
        XCTAssertFalse(log.events.contains("complete"))
        let up = try XCTUnwrap(outbox.items(sessionId: s).first { $0.kind == .uploadArtefact })
        XCTAssertEqual(up.status, .pending)
        XCTAssertEqual(up.attempts, 1)
        XCTAssertTrue(fileExists(a))
        // Next drain (after backoff) resumes and only uploads what is missing.
        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        XCTAssertEqual(engine.record(s)?.artefacts.first?.status, .verified)
    }

    func testResumesOnlyMissingPartsAfterFailure() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 3000)
        uploader.outcomes[2] = [.transportError]
        let s = try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(engine.record(s)?.artefacts.first?.uploadedParts, [1])
        log.events = []
        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        XCTAssertEqual(log.events, ["mint 2", "upload 2", "mint 3", "upload 3", "complete"])
    }

    func testExistingBackgroundCompletionIsReusedWithoutMinting() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 2000)
        let s = try enqueue(engine, [a])
        // Part 1 fails in this process; then pretend its background task finished while the app was dead.
        uploader.outcomes[1] = [.transportError]
        await engine.drain()
        let artefactId = try XCTUnwrap(api.artefactIds.first)
        uploader.existing["\(artefactId.uuidString.lowercased())/1"] = .success
        log.events = []
        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        XCTAssertEqual(log.events, ["mint 2", "upload 2", "complete"])
        XCTAssertEqual(engine.record(s)?.artefacts.first?.status, .verified)
    }

    func testHashMismatchMarksArtefactFailedAndKeepsLocalFile() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 500)
        api.completeErrorQueue = [.uploadHashMismatch]
        let s = try enqueue(engine, [a])
        let localId = a.localId
        await engine.drain()
        let rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.artefacts.first { $0.localId == localId }?.status, .failed)
        XCTAssertEqual(try outbox.items(sessionId: s).first { $0.kind == .completeArtefact }?.status, .failed)
        XCTAssertTrue(fileExists(a), "local sealed file kept")
        XCTAssertTrue(keyExists(a), "key kept")
        XCTAssertFalse(rec.localDataDestroyed)
    }

    func testLocalFilesDeletedOnlyAfterAllArtefactsVerified() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 500, step: .neutralFace)
        let b = try makeArtefact(size: 700, step: .fingertipPPG)
        api.completeErrorQueue = [nil, .retryable]
        let s = try enqueue(engine, [a, b])
        await engine.drain()
        var rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.artefacts.map { $0.status }, [.verified, .uploaded])
        XCTAssertTrue(fileExists(a) && fileExists(b), "nothing deleted while one artefact is unverified")
        XCTAssertTrue(keyExists(a) && keyExists(b))
        XCTAssertEqual(rec.verdict, .uploading)

        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.artefacts.map { $0.status }, [.verified, .verified])
        XCTAssertFalse(fileExists(a) || fileExists(b))
        XCTAssertFalse(keyExists(a) || keyExists(b))
        XCTAssertTrue(rec.localDataDestroyed)
        XCTAssertEqual(rec.verdict, .awaitingVerdict)
    }

    func testUploadsUseDeviceTokenNotUserToken() async throws {
        let realAPI: URLSessionDengueAPI = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [StubProtocol.self]
            return URLSessionDengueAPI(baseURL: URL(string: "https://api.test")!,
                                       session: URLSession(configuration: cfg),
                                       tokenProvider: { $0 == .user ? "USER" : ($0 == .device ? "DEVICE" : nil) })
        }()
        let scanId = UUID()
        let artefactId = UUID()
        StubProtocol.handler = { cap in
            let p = cap.request.url!.path
            if p.hasSuffix("/artefacts") {
                return (201, Data(#"{"artefact_id":"\#(artefactId.uuidString)","upload_id":"u"}"#.utf8))
            }
            if p.contains("/parts/") { return (200, Data(#"{"url":"https://s3.test/p","expires_in":900}"#.utf8)) }
            if p.hasSuffix("/complete") { return (200, Data(#"{"status":"received_verified"}"#.utf8)) }
            if p.hasPrefix("/v1/scans/") {
                return (200, Data(#"{"scan":{"id":"\#(scanId.uuidString)","status":"quality_passed","steps":[],"recaptures_remaining":{}}}"#.utf8))
            }
            return (500, Data())
        }
        let engine = makeEngine(api: realAPI, partSize: 400)
        let a = try makeArtefact(size: 1000)
        let s = UUID()
        try engine.enqueueSession(sessionId: s, participantCode: participantCode, createScan: nil,
                                  scanId: scanId, artefacts: [a])
        await engine.drain()
        await engine.refreshVerdicts()
        let reqs = StubProtocol.captured.map { $0.request }
        XCTAssertEqual(reqs.filter { $0.url!.path.hasSuffix("/artefacts") }.count, 1)
        XCTAssertEqual(reqs.filter { $0.url!.path.contains("/parts/") }.count, 3)
        XCTAssertEqual(reqs.filter { $0.url!.path.hasSuffix("/complete") }.count, 1)
        XCTAssertEqual(reqs.filter { $0.httpMethod == "GET" }.count, 1, "verdict poll")
        for r in reqs {
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer DEVICE", r.url!.path)
        }
        XCTAssertEqual(engine.record(s)?.verdict, .accepted)
    }

    func testServerFailVerdictMarksNeedsRepeatAndNotificationShowsOnlyLast3() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(engine.record(s)?.verdict, .awaitingVerdict)

        // Still quality_pending: nothing happens, keep polling.
        api.scanResponse = try scan(status: .qualityPending, steps: [("neutral_face", nil, [])])
        await engine.refreshVerdicts()
        XCTAssertEqual(engine.record(s)?.verdict, .awaitingVerdict)
        XCTAssertTrue(notifier.texts.isEmpty)

        api.scanResponse = try scan(status: .qualityFailed, steps: [
            ("neutral_face", "fail", ["DS_QG_002"]), ("fingertip_ppg", "pass", [])])
        await engine.refreshVerdicts()
        let rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.verdict, .needsRepeat)
        XCTAssertEqual(rec.repeatReasons, [.dsQG002])
        XCTAssertEqual(api.getScanAuth, [.device, .device])
        XCTAssertEqual(notifier.texts, ["A recording for ••417 needs repeating"])
        let text = notifier.texts[0]
        XCTAssertFalse(text.contains("DS-2026"))
        XCTAssertFalse(text.contains("00417"))
        XCTAssertTrue(NurseCopy.forbiddenTerms(in: text).isEmpty)
        XCTAssertFalse(try JSONEncoder().encode(rec).contains(Data(participantCode.utf8)),
                       "record stores only the masked code")

        // Polling again does not re-notify.
        await engine.refreshVerdicts()
        XCTAssertEqual(notifier.texts.count, 1)
    }

    func testOutboxNeedsRepeatAppliedToUnfinishedItems() async throws {
        // Server gate reply on complete (422 DS_QG_*) → outbox needsRepeat + notice.
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        api.completeErrorQueue = [.needsRepeat([.dsQG001])]
        let s = try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(try outbox.items(sessionId: s).first { $0.kind == .completeArtefact }?.status, .needsRepeat)
        XCTAssertEqual(engine.record(s)?.verdict, .needsRepeat)
        XCTAssertEqual(notifier.texts, ["A recording for ••417 needs repeating"])
    }

    // MARK: additional behaviour

    func testDeclareUsesSealedShaAndSize() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 321, step: .fingertipPPG, kind: .roiTrace)
        try enqueue(engine, [a])
        await engine.drain()
        let d = try XCTUnwrap(api.declares.first)
        XCTAssertEqual(d.scanId, api.scanId)
        XCTAssertEqual(d.request.sha256, a.sealed.sha256OfCiphertext)
        XCTAssertEqual(d.request.sizeBytes, 321)
        XCTAssertNotEqual(d.request.sizeBytes, a.sealed.sizeBytes)
        XCTAssertEqual(d.request.step, .fingertipPPG)
        XCTAssertEqual(d.request.kind, .roiTrace)
        XCTAssertEqual(d.request.attempt, 1)
        XCTAssertEqual(d.request.deviceVerdict, .accept)
    }

    func testUploadIncompleteReuploadsPartsThenCompletesWithSameKey() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 1800)
        api.completeErrorQueue = [.uploadIncomplete]
        let s = try enqueue(engine, [a])
        await engine.drain()
        let artefactId = try XCTUnwrap(api.artefactIds.first)
        XCTAssertEqual(Array(log.events.drop { $0 != "mint 1" }), ["mint 1", "upload 1", "mint 2", "upload 2", "complete",
                                    "mint 1", "upload 1", "mint 2", "upload 2", "complete"])
        let keys = try XCTUnwrap(api.completeKeys[artefactId])
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1], "same idempotency key")
        let item = try XCTUnwrap(outbox.items(sessionId: s).first { $0.kind == .completeArtefact })
        XCTAssertEqual(keys[0], item.idempotencyKey.uuidString)
        XCTAssertEqual(engine.record(s)?.artefacts[0].status, .verified)
    }

    func testUploadIncompleteTwiceSchedulesRetryKeepingKey() async throws {
        let engine = makeEngine(partSize: 1000)
        let a = try makeArtefact(size: 900)
        api.completeErrorQueue = [.uploadIncomplete, .uploadIncomplete]
        let s = try enqueue(engine, [a])
        await engine.drain()
        let artefactId = try XCTUnwrap(api.artefactIds.first)
        let item = try XCTUnwrap(outbox.items(sessionId: s).first { $0.kind == .completeArtefact })
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.attempts, 1)
        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        let used = try XCTUnwrap(api.completeKeys[artefactId])
        XCTAssertEqual(Set(used), [item.idempotencyKey.uuidString])
        XCTAssertEqual(engine.record(s)?.artefacts[0].status, .verified)
    }

    func testStopAndQuarantineDestroysKeysAndFiles() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let b = try makeArtefact(size: 300, step: .fingertipPPG)
        api.declareErrors = [.stopAndQuarantine(code: "DS_REG_001")]
        let s = try enqueue(engine, [a, b])
        await engine.drain()
        XCTAssertFalse(fileExists(a) || fileExists(b))
        XCTAssertFalse(keyExists(a) || keyExists(b))
        let items = try outbox.items(sessionId: s)
        XCTAssertTrue(items.filter { $0.kind != .createScan }.allSatisfy { $0.status == .quarantined })
        XCTAssertEqual(try outbox.pendingQuarantineSessions(), [])
        XCTAssertEqual(engine.record(s)?.verdict, .quarantined)
        XCTAssertTrue(engine.record(s)?.localDataDestroyed ?? false)
        XCTAssertFalse(log.events.contains { $0.hasPrefix("upload") })
    }

    func testRefetchScanUsesDeviceAuth() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        await engine.drain()
        api.recaptureErrors = [.recaptureExhausted(unableToAcquire: ["neutral_face"], recaptured: [], status: "partial")]
        api.scanResponse = try scan(status: .partial, steps: [("neutral_face", nil, [])])
        try engine.enqueueRecapture(sessionId: s, steps: [.neutralFace], reason: "DS_QG_002", artefacts: [])
        await engine.drain()
        XCTAssertTrue(log.events.contains("recapture"))
        XCTAssertEqual(log.events.last, "getScan")
        XCTAssertEqual(api.getScanAuth, [.device])
        XCTAssertEqual(try outbox.items(sessionId: s).first { $0.kind == .recapture }?.status, .done)
        XCTAssertTrue(notifier.texts.isEmpty, "never tell the nurse to repeat after DS_QG_099")
    }

    func testLaunchRecoversInFlightAndFinishesPendingQuarantine() async throws {
        let engine = makeEngine()
        // Session 1: interrupted quarantine (quarantinePending, files still on disk).
        let q = try makeArtefact(size: 300)
        let s1 = try enqueue(engine, [q])
        let declare1 = try XCTUnwrap(outbox.items(sessionId: s1).first { $0.kind == .declareArtefact })
        _ = try outbox.apply(.stopAndQuarantine(code: "DS_REG_002"), to: declare1.id)
        XCTAssertEqual(try outbox.pendingQuarantineSessions(), [s1])
        // Session 2: an item left inFlight by a crash.
        let a = try makeArtefact(size: 300)
        let s2 = try enqueue(engine, [a])
        let create2 = try XCTUnwrap(outbox.items(sessionId: s2).first { $0.kind == .createScan })
        try outbox.markInFlight(create2.id)

        await engine.launch()

        XCTAssertFalse(fileExists(q))
        XCTAssertFalse(keyExists(q))
        XCTAssertEqual(try outbox.pendingQuarantineSessions(), [])
        XCTAssertEqual(engine.record(s1)?.verdict, .quarantined)
        XCTAssertEqual(try outbox.item(create2.id)?.status, .done, "recovered and drained")
        XCTAssertEqual(engine.record(s2)?.verdict, .awaitingVerdict)
    }

    func testLaunchFinishesCleanupInterruptedAfterAllVerified() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        await engine.drain()
        // Simulate a crash before destruction: restore a record that says verified but not destroyed.
        var rec = try XCTUnwrap(sessions.load(s))
        rec.localDataDestroyed = false
        rec.verdict = .uploading
        try sessions.save(rec)
        try Data("x".utf8).write(to: a.sealed.path)
        await engine.launch()
        XCTAssertFalse(fileExists(a))
        XCTAssertTrue(engine.record(s)?.localDataDestroyed ?? false)
        XCTAssertEqual(engine.record(s)?.verdict, .awaitingVerdict)
    }

    func testDeviceAuthFailureDoesNotFailUploadAndStopsDrain() async throws {
        let engine = makeEngine()
        var reported: [APIError] = []
        engine.onDeviceAuthFailure = { reported.append($0) }
        let a = try makeArtefact(size: 300)
        api.declareErrors = [.unauthorized]
        let s = try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(reported, [.unauthorized])
        let d = try XCTUnwrap(outbox.items(sessionId: s).first { $0.kind == .declareArtefact })
        XCTAssertEqual(d.status, .pending, "kept for retry once the device token is renewed")
        XCTAssertTrue(fileExists(a))
    }

    func testUserTokenExpiryKeepsCreateScanForRetryAndOtherSessionsContinue() async throws {
        final class FailingCreate: DengueAPI {
            let inner: FakeUploadAPI
            var failFirst = true
            init(_ i: FakeUploadAPI) { inner = i }
            func createScan(_ r: CreateScanRequest, idempotencyKey: String) async throws -> CreateScanResponse {
                if failFirst { failFirst = false; throw APIError.unauthorized }
                return try await inner.createScan(r, idempotencyKey: idempotencyKey)
            }
            func getScan(id: UUID, auth: AuthKind) async throws -> ScanResponse { try await inner.getScan(id: id, auth: auth) }
            func recapture(scanId: UUID, steps: [CaptureStepName], reason: String, idempotencyKey: String) async throws -> ScanResponse { try await inner.recapture(scanId: scanId, steps: steps, reason: reason, idempotencyKey: idempotencyKey) }
            func declareArtefact(scanId: UUID, request: DeclareArtefactRequest, idempotencyKey: String) async throws -> DeclareArtefactResponse { try await inner.declareArtefact(scanId: scanId, request: request, idempotencyKey: idempotencyKey) }
            func partURL(artefactId: UUID, part: Int) async throws -> PartURLResponse { try await inner.partURL(artefactId: artefactId, part: part) }
            func completeArtefact(id: UUID, idempotencyKey: String) async throws -> CompleteArtefactResponse { try await inner.completeArtefact(id: id, idempotencyKey: idempotencyKey) }
            func lookup(participantCode: String) async throws -> PatientLookup { try await inner.lookup(participantCode: participantCode) }
            func roster(wardId: String) async throws -> Roster { try await inner.roster(wardId: wardId) }
            func consentStatus(patientId: UUID) async throws -> ConsentStatus { try await inner.consentStatus(patientId: patientId) }
            func postClinicalData(patientId: UUID, request: ClinicalDataRequest, idempotencyKey: String) async throws -> ClinicalDataResponse { try await inner.postClinicalData(patientId: patientId, request: request, idempotencyKey: idempotencyKey) }
            func experimental(scanId: UUID) async throws -> ExperimentalResponse { try await inner.experimental(scanId: scanId) }
            func reviewChallenge(scanId: UUID, action: ReviewAction, reasonCode: String?, note: String?) async throws -> ReviewChallengeResponse { try await inner.reviewChallenge(scanId: scanId, action: action, reasonCode: reasonCode, note: note) }
            func review(scanId: UUID, challengeId: UUID, action: ReviewAction, reasonCode: String?, note: String?, webauthnAssertion: [String: JSONValue], idempotencyKey: String) async throws -> ReviewResponse { try await inner.review(scanId: scanId, challengeId: challengeId, action: action, reasonCode: reasonCode, note: note, webauthnAssertion: webauthnAssertion, idempotencyKey: idempotencyKey) }
            func registerPushToken(deviceId: UUID, apnsToken: String, idempotencyKey: String) async throws { try await inner.registerPushToken(deviceId: deviceId, apnsToken: apnsToken, idempotencyKey: idempotencyKey) }
            func deviceChallenge(idempotencyKey: String) async throws -> DeviceChallengeResponse { try await inner.deviceChallenge(idempotencyKey: idempotencyKey) }
            func attest(keyId: String, attestation: String, challenge: String, wardId: String, idempotencyKey: String) async throws -> AttestResponse { try await inner.attest(keyId: keyId, attestation: attestation, challenge: challenge, wardId: wardId, idempotencyKey: idempotencyKey) }
            func assert(deviceId: UUID, assertion: String, challenge: String, asUser: Bool) async throws -> AssertResponse { try await inner.assert(deviceId: deviceId, assertion: assertion, challenge: challenge, asUser: asUser) }
            func renewalChallenge(deviceId: UUID) async throws -> DeviceChallengeResponse { try await inner.renewalChallenge(deviceId: deviceId) }
        }
        let engine = makeEngine(api: FailingCreate(api))
        var userFailures = 0
        engine.onUserAuthFailure = { userFailures += 1 }
        let a = try makeArtefact(size: 300)
        let s1 = try enqueue(engine, [a])
        let b = try makeArtefact(size: 300)
        let s2 = UUID()
        try engine.enqueueSession(sessionId: s2, participantCode: participantCode, createScan: nil,
                                  scanId: UUID(), artefacts: [b])
        await engine.drain()
        XCTAssertEqual(userFailures, 1)
        XCTAssertEqual(try outbox.items(sessionId: s1).map { $0.status }, [.pending, .pending, .pending, .pending],
                       "nothing failed; waits for sign-in")
        XCTAssertEqual(engine.record(s2)?.verdict, .awaitingVerdict, "other session still uploaded")
        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        XCTAssertEqual(engine.record(s1)?.verdict, .awaitingVerdict)
    }

    func testMissingLocalFileFailsArtefactWithoutLooping() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        try FileManager.default.removeItem(at: a.sealed.path)
        let s = try enqueue(engine, [a])
        await engine.drain()
        XCTAssertEqual(try outbox.items(sessionId: s).first { $0.kind == .uploadArtefact }?.status, .failed)
        XCTAssertEqual(engine.record(s)?.artefacts[0].status, .failed)
        XCTAssertFalse(log.events.contains("complete"))
    }

    // MARK: fix round 1

    /// I1: partial DS_QG_099 - only artefacts of steps the server did NOT recapture are abandoned.
    func testPartialRecaptureExhaustedKeepsRecapturedArtefacts() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        await engine.drain()
        let rFace = try makeArtefact(size: 400, step: .neutralFace)
        let rEye = try makeArtefact(size: 500, step: .ocularCapture)
        api.recaptureErrors = [.recaptureExhausted(unableToAcquire: ["ocular_capture"], recaptured: ["neutral_face"],
                                                   status: "capture_pending")]
        api.scanResponse = try scan(status: .capturePending, steps: [("neutral_face", nil, [])])
        api.completeErrorQueue = [.retryable]   // rFace's first complete
        try engine.enqueueRecapture(sessionId: s, steps: [.neutralFace, .ocularCapture], reason: "DS_QG_002",
                                    artefacts: [rFace, rEye])
        await engine.drain()
        var rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.artefacts.first { $0.localId == rEye.localId }?.status, .abandoned)
        XCTAssertFalse(fileExists(rEye) || keyExists(rEye), "exhausted step data destroyed")
        XCTAssertEqual(rec.artefacts.first { $0.localId == rFace.localId }?.status, .uploaded)
        XCTAssertTrue(fileExists(rFace) && keyExists(rFace), "recaptured step data kept")
        XCTAssertEqual(api.declares.filter { $0.request.step == .neutralFace }.count, 2, "recaptured artefact declared")
        XCTAssertEqual(api.declares.filter { $0.request.step == .ocularCapture }.count, 0)
        XCTAssertEqual(rec.verdict, .uploading)
        XCTAssertTrue(notifier.texts.isEmpty)

        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        await engine.drain()
        rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.artefacts.first { $0.localId == rFace.localId }?.status, .verified)
        XCTAssertFalse(fileExists(rFace) || keyExists(rFace), "destroyed once everything left is verified")
        XCTAssertTrue(rec.localDataDestroyed)
        XCTAssertEqual(rec.verdict, .awaitingVerdict)
    }

    /// I2: drain reports when to wake for the earliest retry.
    func testDrainReturnsNextWakeAtForBackoffAndNilWhenDone() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        uploader.outcomes[1] = [.transportError]
        try enqueue(engine, [a])
        let wake = await engine.drain()
        XCTAssertEqual(wake, .done(nextWakeAt: clock.wallNow.addingTimeInterval(Outbox.backoff(attempts: 1))))
        clock.wallNow = clock.wallNow.addingTimeInterval(3600)
        let wake2 = await engine.drain()
        XCTAssertEqual(wake2, .done(nextWakeAt: nil))
    }

    func testNextWakeIgnoresFrozenSessions() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        let create = try XCTUnwrap(outbox.items(sessionId: s).first { $0.kind == .createScan })
        XCTAssertEqual(try outbox.nextWakeAt(), clock.wallNow)
        try outbox.markInFlight(create.id)
        _ = try outbox.apply(.needsRepeat([]), to: create.id)   // freezes the whole session
        XCTAssertNil(try outbox.nextWakeAt())
    }

    /// I5 (core part): drain stops starting new items once told to.
    func testDrainStopsStartingItemsWhenShouldContinueTurnsFalse() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        try enqueue(engine, [a])
        var checks = 0
        let result = await engine.drain(shouldContinue: { checks += 1; return checks <= 1 })
        XCTAssertEqual(log.events, ["createScan"])
        guard case .done(let wake) = result else { return XCTFail("expected .done") }
        let w = try XCTUnwrap(wake, "remaining work is due now")
        XCTAssertLessThanOrEqual(w, clock.wallNow)
    }

    /// I3: concurrent callers share one in-flight operation.
    func testSingleFlightRunsOperationOnceForConcurrentCallers() async throws {
        let flight = SingleFlight<Int>()
        let counter = Counter()
        let gate = Gate()
        let results = await withTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<5 {
                group.addTask {
                    await flight.run {
                        counter.increment()
                        await gate.wait()
                        return 42
                    }
                }
            }
            while flight.joinedCount < 5 { await Task.yield() }
            gate.open()
            var out: [Int] = []
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(results, [42, 42, 42, 42, 42])
        // A later call starts a fresh operation.
        let again = await flight.run { counter.increment(); return 7 }
        XCTAssertEqual(again, 7)
        XCTAssertEqual(counter.value, 2)
    }

    /// I4 + R1: verdict table.
    func testVerdictTable() async throws {
        let engine = makeEngine()
        func verdict(_ status: ScanStatus, _ steps: [(String, String?, [String])]) async throws -> UploadSessionRecord {
            let sid = UUID()
            var rec = UploadSessionRecord(sessionId: sid, maskedCode: "\u{2022}\u{2022}417", scanId: api.scanId, artefacts: [])
            rec.verdict = .awaitingVerdict
            try sessions.save(rec)
            api.scanResponse = try scan(status: status, steps: steps)
            await engine.refreshVerdicts()
            return try XCTUnwrap(engine.record(sid))
        }
        var r = try await verdict(.qualityFailed, [("neutral_face", "RECAPTURE", ["DS_QG_001"]), ("fingertip_ppg", "pass", [])])
        XCTAssertEqual(r.verdict, .needsRepeat)
        XCTAssertEqual(r.repeatSteps, [.neutralFace])
        XCTAssertEqual(r.repeatReasons, [.dsQG001])

        r = try await verdict(.qualityFailed, [("neutral_face", "pass", []), ("fingertip_ppg", nil, [])])
        XCTAssertEqual(r.verdict, .needsRepeat, "quality_failed without a failing step: repeat all core steps")
        XCTAssertEqual(r.repeatSteps, [.neutralFace, .fingertipPPG])
        XCTAssertEqual(notifier.texts.count, 2)

        r = try await verdict(.acquisitionFailure, [])
        XCTAssertEqual(r.verdict, .closed)
        XCTAssertEqual(r.notice, NurseCopy.acquisitionFailure)

        let accepted: [ScanStatus] = [.qualityPassed, .featurePending, .featureComplete, .reviewPending, .reviewed,
                                      .flagged, .excluded, .archived]
        for st in accepted {
            r = try await verdict(st, [])
            XCTAssertEqual(r.verdict, .accepted, st.rawValue)
            XCTAssertNil(r.notice)
        }
        let closed: [ScanStatus] = [.partial, .revoked]
        for st in closed {
            r = try await verdict(st, [])
            XCTAssertEqual(r.verdict, .closed, st.rawValue)
            XCTAssertNil(r.notice)
        }
        XCTAssertEqual(notifier.texts.count, 2, "only the two repeat rows notify")
    }

    // MARK: fix round 2

    /// N1: a drain started while another runs reports `.skipped`, not "nothing pending".
    func testConcurrentDrainReturnsSkipped() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        try enqueue(engine, [a])
        let gate = Gate()
        uploader.gate = gate
        let first = Task { await engine.drain() }
        while !gate.hasWaiter { await Task.yield() }
        let second = await engine.drain()
        XCTAssertEqual(second, .skipped)
        gate.open()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .done(nextWakeAt: nil))
    }

    /// R1 (round 2): full DS_QG_099 (nothing recaptured) leaves only verified + abandoned artefacts: destroyed.
    func testFullRecaptureExhaustedMarksSessionDestroyed() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        await engine.drain()
        let rFace = try makeArtefact(size: 400, step: .neutralFace)
        api.recaptureErrors = [.recaptureExhausted(unableToAcquire: ["neutral_face"], recaptured: [], status: "partial")]
        api.scanResponse = try scan(status: .partial, steps: [("neutral_face", nil, [])])
        try engine.enqueueRecapture(sessionId: s, steps: [.neutralFace], reason: "DS_QG_002", artefacts: [rFace])
        XCTAssertEqual(engine.record(s)?.localDataDestroyed, false)
        await engine.drain()
        let rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.artefacts.map { $0.status }, [.verified, .abandoned])
        XCTAssertTrue(rec.localDataDestroyed)
        XCTAssertFalse(fileExists(rFace) || keyExists(rFace))
        XCTAssertEqual(rec.verdict, .closed)
        XCTAssertTrue(notifier.texts.isEmpty)
    }

    /// R2: item-level needsRepeat on a non-artefact item repeats all core steps.
    func testItemNeedsRepeatOnNonArtefactItemFallsBackToCoreSteps() async throws {
        let engine = makeEngine()
        let a = try makeArtefact(size: 300)
        let s = try enqueue(engine, [a])
        await engine.drain()
        api.recaptureErrors = [.needsRepeat([.dsQG003])]
        try engine.enqueueRecapture(sessionId: s, steps: [.neutralFace], reason: "DS_QG_002", artefacts: [])
        await engine.drain()
        let rec = try XCTUnwrap(engine.record(s))
        XCTAssertEqual(rec.verdict, .needsRepeat)
        XCTAssertEqual(rec.repeatSteps, [.neutralFace, .fingertipPPG])
        XCTAssertEqual(rec.repeatReasons, [.dsQG003])
        XCTAssertEqual(notifier.texts, ["A recording for \u{2022}\u{2022}417 needs repeating"])
    }

    func testFileSessionStoreSurvivesReopen() throws {
        let d = dir.appendingPathComponent("sessions")
        let a = try makeArtefact(size: 10)
        var rec = UploadSessionRecord(sessionId: UUID(), maskedCode: "••417", scanId: UUID(), artefacts: [a])
        try FileUploadSessionStore(directory: d).save(rec)
        rec.artefacts[0].uploadedParts = [1, 2]
        try FileUploadSessionStore(directory: d).save(rec)
        let back = try FileUploadSessionStore(directory: d).loadAll()
        XCTAssertEqual(back, [rec])
    }

    func testMaskedStudyID() {
        XCTAssertEqual(NurseCopy.maskedStudyID("DS-2026-00417"), "••417")
        XCTAssertEqual(NurseCopy.maskedStudyID("17"), "••17")
        XCTAssertEqual(NurseCopy.repeatNotification(maskedStudyID: "••417"), "A recording for ••417 needs repeating")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// One-shot async gate.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasWaiter: Bool { lock.lock(); defer { lock.unlock() }; return !waiters.isEmpty }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); isOpen = true; let ws = waiters; waiters = []; lock.unlock()
        ws.forEach { $0.resume() }
    }
}
