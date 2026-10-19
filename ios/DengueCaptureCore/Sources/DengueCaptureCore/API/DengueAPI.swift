import Foundation

/// Which bearer a call needs, per the contract's `security`/`x-auth`.
public enum AuthKind: Equatable {
    case none
    /// User bearer token (nurse/clinician login).
    case user
    /// Device bearer token (from `assert`).
    case device
}

/// Async API surface. Auth per route (contract `x-auth`):
/// - user: lookup, roster, consentStatus, createScan, getScan (default; pass .device for verdict polling), recapture, postClinicalData, experimental,
///   reviewChallenge, review, deviceChallenge, attest
/// - device (route also accepts user): declareArtefact, partURL, completeArtefact
/// - device only: registerPushToken
/// - none: renewalChallenge; assert is user-bearer at enrolment (asUser: true) and unauthenticated for renewal
/// POSTs listed with an `Idempotency-Key` take a caller-supplied key; partURL, assert, renewalChallenge and
/// reviewChallenge are idempotency-exempt.
public protocol DengueAPI {
    func lookup(participantCode: String) async throws -> PatientLookup
    func roster(wardId: String) async throws -> Roster
    func consentStatus(patientId: UUID) async throws -> ConsentStatus
    func createScan(_ request: CreateScanRequest, idempotencyKey: String) async throws -> CreateScanResponse
    func getScan(id: UUID, auth: AuthKind) async throws -> ScanResponse
    func recapture(scanId: UUID, steps: [CaptureStepName], reason: String, idempotencyKey: String) async throws -> ScanResponse
    func declareArtefact(scanId: UUID, request: DeclareArtefactRequest, idempotencyKey: String) async throws -> DeclareArtefactResponse
    func partURL(artefactId: UUID, part: Int) async throws -> PartURLResponse
    func completeArtefact(id: UUID, idempotencyKey: String) async throws -> CompleteArtefactResponse
    func postClinicalData(patientId: UUID, request: ClinicalDataRequest, idempotencyKey: String) async throws -> ClinicalDataResponse
    func experimental(scanId: UUID) async throws -> ExperimentalResponse
    func reviewChallenge(scanId: UUID, action: ReviewAction, reasonCode: String?, note: String?) async throws -> ReviewChallengeResponse
    func review(scanId: UUID, challengeId: UUID, action: ReviewAction, reasonCode: String?, note: String?,
                webauthnAssertion: [String: JSONValue], idempotencyKey: String) async throws -> ReviewResponse
    func registerPushToken(deviceId: UUID, apnsToken: String, idempotencyKey: String) async throws
    func deviceChallenge(idempotencyKey: String) async throws -> DeviceChallengeResponse
    func attest(keyId: String, attestation: String, challenge: String, wardId: String, idempotencyKey: String) async throws -> AttestResponse
    /// `asUser: true` (enrolment, after attest) sends the user bearer; renewal (`false`) sends no Authorization.
    func assert(deviceId: UUID, assertion: String, challenge: String, asUser: Bool) async throws -> AssertResponse
    func renewalChallenge(deviceId: UUID) async throws -> DeviceChallengeResponse
}

public extension DengueAPI {
    func getScan(id: UUID) async throws -> ScanResponse { try await getScan(id: id, auth: .user) }
    func assert(deviceId: UUID, assertion: String, challenge: String) async throws -> AssertResponse {
        try await assert(deviceId: deviceId, assertion: assertion, challenge: challenge, asUser: false)
    }
}
