import Foundation
import Crypto

/// Abstraction over DCAppAttestService so enrolment is testable off-device.
public protocol AppAttestProviding {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

public enum DeviceEnrolmentError: Error, Equatable {
    case attestationUnsupported
    case invalidChallenge
    /// Renewal was refused repeatedly (not a revoked device): surface to the user / support.
    case renewalRejected
}

/// What survives a failed enrolment after attest succeeded. Persist it so the assert can be retried
/// without a second attest (a key can be attested only once).
public struct EnrolmentProgress: Equatable, Codable {
    public let keyId: String
    public let deviceId: UUID
    public init(keyId: String, deviceId: UUID) { self.keyId = keyId; self.deviceId = deviceId }
}

public struct DeviceCredential: Equatable {
    public let deviceId: UUID
    public let keyId: String
    public let deviceToken: String
    public let state: DeviceTokenState
}

public struct RenewedToken: Equatable {
    public let deviceToken: String
    public let state: DeviceTokenState
}

/// Enrolment: deviceChallenge (user bearer) -> attest -> assert(asUser: true).
/// Renewal: renewalChallenge(deviceId) -> assert(asUser: false). clientDataHash = SHA256(raw challenge bytes).
public final class DeviceEnrolment {
    private let api: DengueAPI
    private let attest: AppAttestProviding
    private let clock: OutboxClock

    public init(api: DengueAPI, attest: AppAttestProviding, clock: OutboxClock) {
        self.api = api; self.attest = attest; self.clock = clock
    }

    /// The server consumes a challenge on attest, so the assertion needs a second one.
    /// `persist` is called after attest succeeds; pass the saved value as `resume` to retry only the assert.
    public func enrol(wardId: String, resume: EnrolmentProgress? = nil,
                      persist: (EnrolmentProgress) -> Void = { _ in }) async throws -> DeviceCredential {
        guard attest.isSupported else { throw DeviceEnrolmentError.attestationUnsupported }
        let progress: EnrolmentProgress
        if let resume {
            progress = resume
        } else {
            let c1 = try await api.deviceChallenge(idempotencyKey: UUID().uuidString).challenge
            let h1 = try Self.clientDataHash(c1)
            let keyId = try await attest.generateKey()
            let attestation = try await attest.attestKey(keyId, clientDataHash: h1)
            let device = try await api.attest(keyId: keyId, attestation: attestation.base64EncodedString(),
                                              challenge: c1, wardId: wardId, idempotencyKey: UUID().uuidString)
            progress = EnrolmentProgress(keyId: keyId, deviceId: device.deviceId)
            persist(progress)
        }
        let challenge = try await api.deviceChallenge(idempotencyKey: UUID().uuidString).challenge
        let hash = try Self.clientDataHash(challenge)
        let assertion = try await attest.generateAssertion(progress.keyId, clientDataHash: hash)
        let tok = try await api.assert(deviceId: progress.deviceId, assertion: assertion.base64EncodedString(),
                                       challenge: challenge, asUser: true)
        return DeviceCredential(deviceId: progress.deviceId, keyId: progress.keyId, deviceToken: tok.deviceToken,
                                state: DeviceTokenState(issuedAt: clock.wallNow, expiresIn: TimeInterval(tok.expiresIn)))
    }

    public func renew(deviceId: UUID, keyId: String) async throws -> RenewedToken {
        let challenge = try await api.renewalChallenge(deviceId: deviceId).challenge
        let hash = try Self.clientDataHash(challenge)
        let assertion = try await attest.generateAssertion(keyId, clientDataHash: hash)
        let tok = try await api.assert(deviceId: deviceId, assertion: assertion.base64EncodedString(),
                                       challenge: challenge, asUser: false)
        return RenewedToken(deviceToken: tok.deviceToken,
                            state: DeviceTokenState(issuedAt: clock.wallNow, expiresIn: TimeInterval(tok.expiresIn)))
    }

    /// Renews when due and allowed. Updates `state` on failure (re-enrol flag / backoff); returns nil
    /// when nothing was renewed. On success the caller stores the returned token; `state` is replaced.
    public func renewIfDue(state: inout DeviceTokenState, deviceId: UUID, keyId: String) async throws -> RenewedToken? {
        let now = clock.wallNow
        guard state.needsRenewal(at: now), state.canAttemptRenewal(at: now) else { return nil }
        do {
            let r = try await renew(deviceId: deviceId, keyId: keyId)
            state = r.state
            return r
        } catch let e as APIError {
            switch e {
            case .reEnrol, .invalid(code: "DS_NOT_FOUND"):   // DS_DEVICE_001, or revoked/unknown device (404)
                state.recordFailure(.reEnrol, at: now)
            case .unauthorized:   // DS_DEVICE_002/003/004: retry with backoff, then surface
                state.recordFailure(.unauthorized, at: now)
                if state.renewalRejected { throw DeviceEnrolmentError.renewalRejected }
            default:
                state.recordFailure(.retryable, at: now)
            }
            return nil
        } catch {
            state.recordFailure(.retryable, at: now)   // transport failure
            return nil
        }
    }

    /// The server issues 32 random bytes in standard base64; the hash covers the decoded bytes.
    static func clientDataHash(_ challenge: String) throws -> Data {
        guard let raw = Data(base64Encoded: challenge), !raw.isEmpty else { throw DeviceEnrolmentError.invalidChallenge }
        return Data(SHA256.hash(data: raw))
    }
}
