import XCTest
import Crypto
@testable import DengueCaptureCore

final class FakeClock: OutboxClock {
    var wallNow: Date
    var monotonicNanos: UInt64 = 1_000_000_000
    var serverOffset: TimeInterval = 0
    init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000)) { wallNow = wall }
    func advance(_ s: TimeInterval) {
        wallNow = wallNow.addingTimeInterval(s)
        monotonicNanos += UInt64(s * 1_000_000_000)
    }
}

final class SessionPolicyTests: XCTestCase {
    /// Advance time in 5-minute steps with user activity so the idle limit is never hit.
    func stay(_ c: FakeClock, _ p: SessionPolicy, _ total: TimeInterval) {
        var left = total
        while left > 0 { let d = min(300, left); c.advance(d); p.recordActivity(); left -= d }
    }

    func testIdle10MinRequiresReauth() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        c.advance(9 * 60 + 59)
        XCTAssertEqual(p.evaluate(), .active)
        c.advance(1)
        XCTAssertEqual(p.evaluate(), .reauthRequired)
        p.reauthenticated()
        XCTAssertEqual(p.evaluate(), .active)
    }

    func testActivityResetsIdle() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        c.advance(8 * 60); p.recordActivity()
        c.advance(8 * 60)
        XCTAssertEqual(p.evaluate(), .active)
    }

    func testOfflineSessionOlderThan12hIsInvalid() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        stay(c, p, 12 * 3600)   // exactly 12h, user stays active
        XCTAssertEqual(p.evaluate(), .active)
        c.advance(1)
        XCTAssertEqual(p.evaluate(), .expired)
    }

    func testServerValidationRefreshesOfflineWindow() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        stay(c, p, 11 * 3600); p.validatedWithServer()
        stay(c, p, 2 * 3600)
        XCTAssertEqual(p.evaluate(), .active)
    }

    func testWallClockMovedBackwardsFailsClosed() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        c.wallNow = c.wallNow.addingTimeInterval(-3600)
        XCTAssertEqual(p.evaluate(), .expired)
    }

    func testNotSignedInIsExpired() {
        XCTAssertEqual(SessionPolicy(clock: FakeClock()).evaluate(), .expired)
    }

    func testExpiredBeatsReauth() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn()
        c.advance(13 * 3600)
        XCTAssertEqual(p.evaluate(), .expired)
    }

    func testSignOutExpires() {
        let c = FakeClock()
        let p = SessionPolicy(clock: c)
        p.signedIn(); p.signedOut()
        XCTAssertEqual(p.evaluate(), .expired)
    }
}

final class DeviceTokenStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRenewsAt20hBeforeExpiry() {
        let s = DeviceTokenState(issuedAt: t0, expiresIn: 86400)
        XCTAssertFalse(s.needsRenewal(at: t0.addingTimeInterval(20 * 3600 - 1)))
        XCTAssertTrue(s.needsRenewal(at: t0.addingTimeInterval(20 * 3600)))
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(24 * 3600)))
    }

    func testReEnrolOnDeviceError() {
        var s = DeviceTokenState(issuedAt: t0, expiresIn: 86400)
        s.recordFailure(.reEnrol, at: t0)
        XCTAssertTrue(s.reEnrolRequired)
        XCTAssertFalse(s.canAttemptRenewal(at: t0.addingTimeInterval(99999)))
    }

    func testRateLimitBacksOffExponentially() {
        var s = DeviceTokenState(issuedAt: t0, expiresIn: 86400)
        let now = t0.addingTimeInterval(21 * 3600)
        XCTAssertTrue(s.canAttemptRenewal(at: now))
        s.recordFailure(.retryable, at: now)
        XCTAssertFalse(s.reEnrolRequired)
        XCTAssertFalse(s.canAttemptRenewal(at: now.addingTimeInterval(29)))
        XCTAssertTrue(s.canAttemptRenewal(at: now.addingTimeInterval(30)))
        s.recordFailure(.retryable, at: now.addingTimeInterval(30))
        XCTAssertFalse(s.canAttemptRenewal(at: now.addingTimeInterval(30 + 59)))
        XCTAssertTrue(s.canAttemptRenewal(at: now.addingTimeInterval(30 + 60)))
        for _ in 0..<20 { s.recordFailure(.retryable, at: now) }
        XCTAssertFalse(s.canAttemptRenewal(at: now.addingTimeInterval(899)))
        XCTAssertTrue(s.canAttemptRenewal(at: now.addingTimeInterval(900)))   // capped at 15 min
    }
}

// MARK: - Enrolment fakes

final class FakeAttest: AppAttestProviding {
    var isSupported = true
    var log: [String] = []
    var hashes: [Data] = []
    func generateKey() async throws -> String { log.append("generateKey"); return "KEY1" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        log.append("attest"); hashes.append(clientDataHash); return Data([1, 2, 3])
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        log.append("assertion"); hashes.append(clientDataHash)
        return Data([4, 5, 6])
    }
}

final class FakeEnrolAPI: DengueAPI {
    var log: [String] = []
    var challenge = Data((0..<32).map { UInt8($0) }).base64EncodedString()
    var assertError: Error?
    var renewalError: Error?
    var assertCalls: [(UUID, String, String, Bool)] = []
    let deviceId = UUID()
    func deviceChallenge(idempotencyKey: String) async throws -> DeviceChallengeResponse {
        log.append("deviceChallenge"); return try decode("{\"challenge\":\"\(challenge)\"}")
    }
    func attest(keyId: String, attestation: String, challenge: String, wardId: String, idempotencyKey: String) async throws -> AttestResponse {
        log.append("attest:\(keyId):\(attestation):\(wardId)")
        return try decode("{\"device_id\":\"\(deviceId.uuidString)\"}")
    }
    func assert(deviceId: UUID, assertion: String, challenge: String, asUser: Bool) async throws -> AssertResponse {
        log.append("assert"); assertCalls.append((deviceId, assertion, challenge, asUser))
        if let e = assertError { throw e }
        return try decode("{\"device_token\":\"TOK\",\"expires_in\":86400}")
    }
    func renewalChallenge(deviceId: UUID) async throws -> DeviceChallengeResponse {
        log.append("renewalChallenge")
        if let e = renewalError { throw e }
        return try decode("{\"challenge\":\"\(challenge)\"}")
    }
    private func decode<T: Decodable>(_ s: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(s.utf8)) }

    // Unused
    func lookup(participantCode: String) async throws -> PatientLookup { fatalError() }
    func roster(wardId: String) async throws -> Roster { fatalError() }
    func consentStatus(patientId: UUID) async throws -> ConsentStatus { fatalError() }
    func createScan(_ request: CreateScanRequest, idempotencyKey: String) async throws -> CreateScanResponse { fatalError() }
    func getScan(id: UUID, auth: AuthKind) async throws -> ScanResponse { fatalError() }
    func recapture(scanId: UUID, steps: [CaptureStepName], reason: String, idempotencyKey: String) async throws -> ScanResponse { fatalError() }
    func declareArtefact(scanId: UUID, request: DeclareArtefactRequest, idempotencyKey: String) async throws -> DeclareArtefactResponse { fatalError() }
    func partURL(artefactId: UUID, part: Int) async throws -> PartURLResponse { fatalError() }
    func completeArtefact(id: UUID, idempotencyKey: String) async throws -> CompleteArtefactResponse { fatalError() }
    func postClinicalData(patientId: UUID, request: ClinicalDataRequest, idempotencyKey: String) async throws -> ClinicalDataResponse { fatalError() }
    func experimental(scanId: UUID) async throws -> ExperimentalResponse { fatalError() }
    func reviewChallenge(scanId: UUID, action: ReviewAction, reasonCode: String?, note: String?) async throws -> ReviewChallengeResponse { fatalError() }
    func review(scanId: UUID, challengeId: UUID, action: ReviewAction, reasonCode: String?, note: String?, webauthnAssertion: [String: JSONValue], idempotencyKey: String) async throws -> ReviewResponse { fatalError() }
    func registerPushToken(deviceId: UUID, apnsToken: String, idempotencyKey: String) async throws {}
}

final class DeviceEnrolmentTests: XCTestCase {
    func makeSut() -> (DeviceEnrolment, FakeEnrolAPI, FakeAttest, FakeClock) {
        let api = FakeEnrolAPI(), att = FakeAttest(), clock = FakeClock()
        return (DeviceEnrolment(api: api, attest: att, clock: clock), api, att, clock)
    }

    func testEnrolmentSequenceAndClientDataHash() async throws {
        let (sut, api, att, clock) = makeSut()
        let r = try await sut.enrol(wardId: "W1")
        XCTAssertEqual(api.log, ["deviceChallenge", "attest:KEY1:\(Data([1, 2, 3]).base64EncodedString()):W1", "assert"])
        XCTAssertEqual(att.log, ["generateKey", "attest", "assertion"])
        let raw = Data((0..<32).map { UInt8($0) })
        let expected = Data(SHA256.hash(data: raw))
        XCTAssertEqual(att.hashes, [expected, expected])
        XCTAssertEqual(api.assertCalls.count, 1)
        XCTAssertEqual(api.assertCalls[0].0, api.deviceId)
        XCTAssertTrue(api.assertCalls[0].3, "enrolment assert is sent as the user")
        XCTAssertEqual(api.assertCalls[0].1, Data([4, 5, 6]).base64EncodedString())
        XCTAssertEqual(r.deviceId, api.deviceId)
        XCTAssertEqual(r.keyId, "KEY1")
        XCTAssertEqual(r.deviceToken, "TOK")
        XCTAssertEqual(r.state.issuedAt, clock.wallNow)
    }

    func testUnsupportedDeviceFailsBeforeAnyCall() async {
        let (sut, api, att, _) = makeSut()
        att.isSupported = false
        do { _ = try await sut.enrol(wardId: "W1"); XCTFail() }
        catch { XCTAssertEqual(error as? DeviceEnrolmentError, .attestationUnsupported) }
        XCTAssertTrue(api.log.isEmpty)
    }

    func testBadChallengeEncodingRejected() async {
        let (sut, api, _, _) = makeSut()
        api.challenge = "!!!not base64!!!"
        do { _ = try await sut.enrol(wardId: "W1"); XCTFail() }
        catch { XCTAssertEqual(error as? DeviceEnrolmentError, .invalidChallenge) }
        XCTAssertEqual(api.log, ["deviceChallenge"])
    }

    func testRenewalSequenceUsesNoUserAuth() async throws {
        let (sut, api, att, clock) = makeSut()
        let id = UUID()
        let r = try await sut.renew(deviceId: id, keyId: "KEY1")
        XCTAssertEqual(api.log, ["renewalChallenge", "assert"])
        XCTAssertEqual(att.log, ["assertion"])
        XCTAssertFalse(api.assertCalls[0].3)
        XCTAssertEqual(api.assertCalls[0].0, id)
        XCTAssertEqual(r.deviceToken, "TOK")
        XCTAssertEqual(r.state.issuedAt, clock.wallNow)
    }

    func testRenewal401DeviceErrorMapsToReEnrol() async {
        let (sut, api, _, _) = makeSut()
        api.assertError = APIError.reEnrol
        do { _ = try await sut.renew(deviceId: UUID(), keyId: "K"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .reEnrol) }
    }

    func testRenewIfDueSkipsWhenNotDueAndBacksOffOn429() async throws {
        let (sut, api, _, clock) = makeSut()
        var state = DeviceTokenState(issuedAt: clock.wallNow, expiresIn: 86400)
        var out = try await sut.renewIfDue(state: &state, deviceId: UUID(), keyId: "K")
        XCTAssertNil(out)
        XCTAssertTrue(api.log.isEmpty)

        clock.advance(20 * 3600)
        api.renewalError = APIError.retryable
        out = try await sut.renewIfDue(state: &state, deviceId: UUID(), keyId: "K")
        XCTAssertNil(out)
        XCTAssertEqual(api.log, ["renewalChallenge"])
        // within backoff: no call
        out = try await sut.renewIfDue(state: &state, deviceId: UUID(), keyId: "K")
        XCTAssertNil(out)
        XCTAssertEqual(api.log, ["renewalChallenge"])
        // after backoff, success
        clock.advance(30)
        api.renewalError = nil
        out = try await sut.renewIfDue(state: &state, deviceId: UUID(), keyId: "K")
        XCTAssertEqual(out?.deviceToken, "TOK")
        XCTAssertEqual(state.issuedAt, clock.wallNow)
        XCTAssertFalse(state.needsRenewal(at: clock.wallNow))
    }

    func testRenewIfDueMarksReEnrolOnDeviceError() async throws {
        let (sut, api, _, clock) = makeSut()
        var state = DeviceTokenState(issuedAt: clock.wallNow, expiresIn: 86400)
        clock.advance(21 * 3600)
        api.assertError = APIError.reEnrol
        let out = try await sut.renewIfDue(state: &state, deviceId: UUID(), keyId: "K")
        XCTAssertNil(out)
        XCTAssertTrue(state.reEnrolRequired)
    }
}
