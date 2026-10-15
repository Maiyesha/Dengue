import Foundation
import DeviceCheck
import DengueCaptureCore

/// DCAppAttestService adapter for the core `AppAttestProviding` protocol (used by `DeviceEnrolment`).
/// UNVERIFIED: App Attest is unavailable on the simulator (`isSupported == false`).
public struct AppAttestService: AppAttestProviding {
    private let service = DCAppAttestService.shared
    public init() {}

    public var isSupported: Bool { service.isSupported }

    public func generateKey() async throws -> String {
        try await service.generateKey()
    }

    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyId, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}
