import XCTest
import Foundation
@testable import DengueCaptureCore

/// C2 core: DengueAPI-backed consent (online lookup + consent status; roster cache offline, 24 h rule),
/// the session gate (sign-in / idle lock / expiry), and the outbox store factory.
final class ProductionWiringTests: XCTestCase {
    final class ConsentAPI: DengueAPI {
        struct Unexpected: Error {}
        var lookupResult: Result<PatientLookup, APIError> = .failure(.retryable)
        var consentResult: Result<ConsentStatus, APIError> = .failure(.retryable)
        var rosterResult: Result<Roster, APIError> = .failure(.retryable)
        var rosterWards: [String] = []
        func lookup(participantCode: String) async throws -> PatientLookup { try lookupResult.get() }
        func roster(wardId: String) async throws -> Roster { rosterWards.append(wardId); return try rosterResult.get() }
        func consentStatus(patientId: UUID) async throws -> ConsentStatus { try consentResult.get() }
        func createScan(_ request: CreateScanRequest, idempotencyKey: String) async throws -> CreateScanResponse { throw Unexpected() }
        func getScan(id: UUID, auth: AuthKind) async throws -> ScanResponse { throw Unexpected() }
        func recapture(scanId: UUID, steps: [CaptureStepName], reason: String, idempotencyKey: String) async throws -> ScanResponse { throw Unexpected() }
        func declareArtefact(scanId: UUID, request: DeclareArtefactRequest, idempotencyKey: String) async throws -> DeclareArtefactResponse { throw Unexpected() }
        func partURL(artefactId: UUID, part: Int) async throws -> PartURLResponse { throw Unexpected() }
        func completeArtefact(id: UUID, idempotencyKey: String) async throws -> CompleteArtefactResponse { throw Unexpected() }
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

    let pid = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func status(allowed: Bool, block: String? = nil) -> ConsentStatus {
        ConsentStatus(primaryResearch: allowed, consentVersion: "v2", currentVersion: "v2", withdrawn: !allowed,
                      captureAllowed: allowed, blockCode: block, checkedAt: WireDate.string(from: now))
    }

    func lookup(_ code: String) -> PatientLookup {
        try! JSONDecoder().decode(PatientLookup.self, from: Data(
            #"{"patient_id":"\#(pid.uuidString)","participant_code":"\#(code)","bed_label":"B4"}"#.utf8))
    }

    func roster(at generated: Date, allowed: Bool = true) -> Roster {
        Roster(items: [RosterItem(patientId: pid, participantCode: "DS-2026-00417", bedLabel: "B4",
                                  consent: status(allowed: allowed))],
               generatedAt: WireDate.string(from: generated))
    }

    func service(_ api: ConsentAPI, cache: ConsentCache = ConsentCache()) -> ConsentService {
        ConsentService(api: api, cache: cache, wardId: "W1", now: { [unowned self] in self.now })
    }

    // MARK: consent

    func testOnlineLookupThenConsentStatus() async {
        let api = ConsentAPI()
        api.lookupResult = .success(lookup("DS-2026-00417"))
        api.consentResult = .success(status(allowed: true))
        let r = await service(api).resolve(participantCode: "DS-2026-00417")
        XCTAssertEqual(r.patientId, pid)
        XCTAssertTrue(r.online)
        XCTAssertEqual(r.snapshotAt, now)
        XCTAssertTrue(r.status.captureAllowed)
        XCTAssertEqual(r.outcome, .ok)
    }

    func testOnlineBlockedConsentIsPassedThrough() async {
        let api = ConsentAPI()
        api.lookupResult = .success(lookup("DS-1"))
        api.consentResult = .success(status(allowed: false, block: "DS_REG_002"))
        let r = await service(api).resolve(participantCode: "DS-1")
        XCTAssertFalse(r.status.captureAllowed)
        XCTAssertEqual(r.status.blockCode, "DS_REG_002")
    }

    func testUnknownParticipantIsBlocked() async {
        let api = ConsentAPI()
        api.lookupResult = .failure(.invalid(code: "DS_NOT_FOUND"))
        let r = await service(api).resolve(participantCode: "DS-404")
        XCTAssertFalse(r.status.captureAllowed)
        XCTAssertNil(r.patientId)
        XCTAssertEqual(r.outcome, .unknownParticipant)
    }

    func testSignInRequiredIsReportedAndBlocks() async {
        let api = ConsentAPI()
        api.lookupResult = .failure(.unauthorized)
        let r = await service(api).resolve(participantCode: "DS-1")
        XCTAssertFalse(r.status.captureAllowed)
        XCTAssertEqual(r.outcome, .signInRequired)
    }

    func testOfflineUsesRosterSnapshotWithin24h() async {
        let api = ConsentAPI()
        let cache = ConsentCache()
        api.rosterResult = .success(roster(at: now))
        let svc = service(api, cache: cache)
        await svc.refreshRoster()
        XCTAssertEqual(api.rosterWards, ["W1"])
        now = now.addingTimeInterval(23 * 3600)
        let r = await svc.resolve(participantCode: "DS-2026-00417")   // lookup fails: offline
        XCTAssertFalse(r.online)
        XCTAssertEqual(r.patientId, pid)
        XCTAssertTrue(r.status.captureAllowed)
        XCTAssertEqual(r.snapshotAt, now.addingTimeInterval(-23 * 3600))
        XCTAssertEqual(r.outcome, .ok)
    }

    /// R-1: behind a captive portal the lookup is treated like being offline (roster snapshot), never "unknown".
    func testCaptivePortalLookupUsesRosterSnapshot() async {
        let api = ConsentAPI()
        let cache = ConsentCache()
        cache.update(roster(at: now), fetchedAt: now)
        api.lookupResult = .failure(.networkRestricted(httpStatus: 403))
        let r = await service(api, cache: cache).resolve(participantCode: "DS-2026-00417")
        XCTAssertFalse(r.online)
        XCTAssertEqual(r.patientId, pid)
        XCTAssertEqual(r.outcome, .ok)
    }

    func testOfflineSnapshotOlderThan24hIsNotUsed() async {
        let api = ConsentAPI()
        let cache = ConsentCache()
        cache.update(roster(at: now), fetchedAt: now)
        now = now.addingTimeInterval(24 * 3600 + 1)
        let r = await service(api, cache: cache).resolve(participantCode: "DS-2026-00417")
        XCTAssertFalse(r.status.captureAllowed)
        XCTAssertEqual(r.outcome, .offlineNoSnapshot)
        XCTAssertNil(cache.entry(participantCode: "DS-2026-00417", now: now))
    }

    func testFutureDatedSnapshotIsNotUsed() {
        let cache = ConsentCache()
        cache.update(roster(at: now.addingTimeInterval(600)), fetchedAt: now)
        XCTAssertNil(cache.entry(participantCode: "DS-2026-00417", now: now))
    }

    func testOfflineUnknownCodeInRosterIsNotAllowed() async {
        let cache = ConsentCache()
        cache.update(roster(at: now), fetchedAt: now)
        let r = await service(ConsentAPI(), cache: cache).resolve(participantCode: "DS-OTHER")
        XCTAssertFalse(r.status.captureAllowed)
        XCTAssertEqual(r.outcome, .offlineNoSnapshot)
    }

    func testCachePersistsThroughStorage() {
        final class Mem: ConsentCacheStorage {
            var data: Data?
            func load() -> Data? { data }
            func save(_ d: Data) { data = d }
        }
        let m = Mem()
        ConsentCache(storage: m).update(roster(at: now), fetchedAt: now)
        XCTAssertNotNil(ConsentCache(storage: m).entry(participantCode: "DS-2026-00417", now: now))
    }

    // MARK: session gate

    final class Clock: OutboxClock {
        var wallNow = Date(timeIntervalSince1970: 1_800_000_000)
        var monotonicNanos: UInt64 = 1
        var continuousNanos: UInt64 = 1
        var serverOffset: TimeInterval = 0
        func advance(_ s: TimeInterval) { wallNow += s; monotonicNanos += UInt64(s * 1e9); continuousNanos += UInt64(s * 1e9) }
    }

    func testGateNoTokensRequiresSignIn() {
        let p = SessionPolicy(clock: Clock())
        XCTAssertEqual(SessionGate.evaluate(hasTokens: false, policy: p), .signInRequired(clearTokens: false))
    }

    func testGateOpenLockedExpired() {
        let c = Clock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        XCTAssertEqual(SessionGate.evaluate(hasTokens: true, policy: p), .open)
        c.advance(SessionPolicy.idleLimit)
        XCTAssertEqual(SessionGate.evaluate(hasTokens: true, policy: p), .locked)
        p.reauthenticated()
        XCTAssertEqual(SessionGate.evaluate(hasTokens: true, policy: p), .open)
        c.advance(SessionPolicy.offlineLimit + 1)
        XCTAssertEqual(SessionGate.evaluate(hasTokens: true, policy: p), .signInRequired(clearTokens: true),
                       "12 h without server validation: sign out and delete tokens")
    }

    func testGateTokensButNoSessionThisProcessRequiresRefreshOrSignIn() {
        // After a relaunch the policy has no session: the stored tokens cannot be trusted offline.
        let p = SessionPolicy(clock: Clock())
        XCTAssertEqual(SessionGate.evaluate(hasTokens: true, policy: p), .signInRequired(clearTokens: true))
    }

    // MARK: outbox factory (compile-risk fix 5)

    func testOutboxFactoryCreatesAWorkingStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("obf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ob = try Outbox.makeDefault(directory: dir, clock: TestClock())
        let it = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data())
        XCTAssertEqual(try Outbox.makeDefault(directory: dir, clock: TestClock()).item(it.id)?.id, it.id, "persists")
    }
}
