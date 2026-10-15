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

    public func enrol(wardId: String) async throws -> DeviceCredential {
        guard attest.isSupported else { throw DeviceEnrolmentError.attestationUnsupported }
        let challenge = try await api.deviceChallenge(idempotencyKey: UUID().uuidString).challenge
        let hash = try Self.clientDataHash(challenge)
        let keyId = try await attest.generateKey()
        let attestation = try await attest.attestKey(keyId, clientDataHash: hash)
        let device = try await api.attest(keyId: keyId, attestation: attestation.base64EncodedString(),
                                          challenge: challenge, wardId: wardId, idempotencyKey: UUID().uuidString)
        let assertion = try await attest.generateAssertion(keyId, clientDataHash: hash)
        let tok = try await api.assert(deviceId: device.deviceId, assertion: assertion.base64EncodedString(),
                                       challenge: challenge, asUser: true)
        return DeviceCredential(deviceId: device.deviceId, keyId: keyId, deviceToken: tok.deviceToken,
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
            case .reEnrol, .unauthorized: state.recordFailure(.reEnrol, at: now)
            default: state.recordFailure(.retryable, at: now)
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
