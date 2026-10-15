import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession-backed client. `tokenProvider` returns the bearer for the requested kind (nil = no header).
public final class URLSessionDengueAPI: DengueAPI {
    public typealias TokenProvider = @Sendable (AuthKind) async -> String?

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProvider

    public init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping TokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    /// W3C trace context: 00-<32 hex trace id>-<16 hex span id>-01, never all-zero.
    static func makeTraceparent() -> String {
        func hex(_ n: Int) -> String {
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255) }
            if bytes.allSatisfy({ $0 == 0 }) { bytes[0] = 1 }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return "00-\(hex(16))-\(hex(8))-01"
    }

    // MARK: core

    private func send(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      auth: AuthKind, idempotencyKey: String? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = comps.percentEncodedPath.hasSuffix("/")
            ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        comps.percentEncodedPath = basePath + path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.makeTraceparent(), forHTTPHeaderField: "traceparent")
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key = idempotencyKey { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if auth != .none, let token = await tokenProvider(auth) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.retryable   // transport failure: safe to retry with the same key
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.retryable }
        if let e = Self.responseError(status: http.statusCode, data: data, finalURL: http.url,
                                      contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                      apiHost: baseURL.host) {
            throw e
        }
        return data
    }

    /// Classifies a finished HTTP exchange; nil = a usable API response.
    /// R-1:
    /// - redirected away from the API host (captive portal) → `.networkRestricted`, whatever the status;
    /// - 2xx with a non-JSON body type (e.g. a portal's HTML login page served as 200) → `.networkRestricted`;
    /// - non-2xx → `decodeError`.
    static func responseError(status: Int, data: Data, finalURL: URL?, contentType: String?, apiHost: String?) -> APIError? {
        if let final = finalURL?.host?.lowercased(), let api = apiHost?.lowercased(), final != api {
            return .networkRestricted(httpStatus: status)
        }
        if (200..<300).contains(status) {
            if !data.isEmpty, let ct = contentType?.lowercased(), !ct.contains("json") {
                return .networkRestricted(httpStatus: status)
            }
            return nil
        }
        return decodeError(data: data, status: status)
    }

    /// The DengueSense error envelope's code wins. A response WITHOUT a parseable envelope did not come from the
    /// API's error handler (every API error carries one): R-1 maps it to `.networkRestricted` (captive portal,
    /// WAF/CDN, proxy, gateway rate limit), except a bare 5xx (gateway/server outage: `.retryable`) and a bare 401
    /// (`.unauthorized`, kept for retry and sign-in). None of these ever lets the client destroy data.
    static func decodeError(data: Data, status: Int) -> APIError {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), env.error.code.hasPrefix("DS_") {
            var detail: [String: JSONValue]?
            if case .object(let o)? = env.error.detail { detail = o }
            return APIError.from(code: env.error.code, httpStatus: status, detail: detail)
        }
        if (500...599).contains(status) { return .retryable }
        if status == 401 { return .unauthorized }
        return .networkRestricted(httpStatus: status)
    }

    private func call<T: Decodable>(_ type: T.Type, method: String, path: String, query: [URLQueryItem] = [],
                                    body: Encodable? = nil, auth: AuthKind,
                                    idempotencyKey: String? = nil) async throws -> T {
        let data = try body.map { try JSONEncoder().encode(AnyEncodable($0)) }
        let out = try await send(method: method, path: path, query: query, body: data, auth: auth,
                                 idempotencyKey: idempotencyKey)
        do { return try JSONDecoder().decode(T.self, from: out) } catch { throw APIError.retryable }  // same key replays the stored response
    }

    private struct AnyEncodable: Encodable {
        let value: Encodable
        init(_ v: Encodable) { value = v }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
    private struct Empty: Encodable {}

    private static func id(_ u: UUID) -> String { u.uuidString.lowercased() }

    // MARK: routes

    public func lookup(participantCode: String) async throws -> PatientLookup {
        try await call(PatientLookup.self, method: "GET", path: "/v1/patients/lookup",
                       query: [URLQueryItem(name: "participant_code", value: participantCode)], auth: .user)
    }

    public func roster(wardId: String) async throws -> Roster {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let w = wardId.addingPercentEncoding(withAllowedCharacters: allowed) ?? wardId
        return try await call(Roster.self, method: "GET", path: "/v1/wards/\(w)/roster", auth: .user)
    }

    public func consentStatus(patientId: UUID) async throws -> ConsentStatus {
        try await call(ConsentStatus.self, method: "GET",
                       path: "/v1/patients/\(Self.id(patientId))/consent-status", auth: .user)
    }

    public func createScan(_ request: CreateScanRequest, idempotencyKey: String) async throws -> CreateScanResponse {
        try await call(CreateScanResponse.self, method: "POST", path: "/v1/scans", body: request, auth: .user,
                       idempotencyKey: idempotencyKey)
    }

    public func getScan(id: UUID, auth: AuthKind) async throws -> ScanResponse {
        try await call(ScanResponse.self, method: "GET", path: "/v1/scans/\(Self.id(id))", auth: auth)
    }

    public func recapture(scanId: UUID, steps: [CaptureStepName], reason: String,
                          idempotencyKey: String) async throws -> ScanResponse {
        struct Body: Encodable { let steps: [CaptureStepName]; let trigger_reason_code: String }
        return try await call(ScanResponse.self, method: "POST", path: "/v1/scans/\(Self.id(scanId))/recapture",
                              body: Body(steps: steps, trigger_reason_code: reason), auth: .user,
                              idempotencyKey: idempotencyKey)
    }

    public func declareArtefact(scanId: UUID, request: DeclareArtefactRequest,
                                idempotencyKey: String) async throws -> DeclareArtefactResponse {
        try await call(DeclareArtefactResponse.self, method: "POST",
                       path: "/v1/scans/\(Self.id(scanId))/artefacts",
                       body: request, auth: .device, idempotencyKey: idempotencyKey)
    }

    public func partURL(artefactId: UUID, part: Int) async throws -> PartURLResponse {
        try await call(PartURLResponse.self, method: "POST",
                       path: "/v1/artefacts/\(Self.id(artefactId))/parts/\(part)/url", auth: .device)
    }

    public func completeArtefact(id: UUID, idempotencyKey: String) async throws -> CompleteArtefactResponse {
        try await call(CompleteArtefactResponse.self, method: "POST",
                       path: "/v1/artefacts/\(Self.id(id))/complete", auth: .device, idempotencyKey: idempotencyKey)
    }

    public func postClinicalData(patientId: UUID, request: ClinicalDataRequest,
                                 idempotencyKey: String) async throws -> ClinicalDataResponse {
        try await call(ClinicalDataResponse.self, method: "POST",
                       path: "/v1/patients/\(Self.id(patientId))/clinical-data",
                       body: request, auth: .user, idempotencyKey: idempotencyKey)
    }

    public func experimental(scanId: UUID) async throws -> ExperimentalResponse {
        try await call(ExperimentalResponse.self, method: "GET",
                       path: "/v1/scans/\(Self.id(scanId))/experimental", auth: .user)
    }

    public func reviewChallenge(scanId: UUID, action: ReviewAction, reasonCode: String?,
                                note: String?) async throws -> ReviewChallengeResponse {
        struct Body: Encodable { let action: ReviewAction; let reason_code: String?; let note: String? }
        return try await call(ReviewChallengeResponse.self, method: "POST",
                              path: "/v1/scans/\(Self.id(scanId))/review-challenge",
                              body: Body(action: action, reason_code: reasonCode, note: note), auth: .user)
    }

    public func review(scanId: UUID, challengeId: UUID, action: ReviewAction, reasonCode: String?, note: String?,
                       webauthnAssertion: [String: JSONValue], idempotencyKey: String) async throws -> ReviewResponse {
        struct Body: Encodable {
            let challenge_id: String; let action: ReviewAction; let reason_code: String?; let note: String?
            let webauthn_assertion: [String: JSONValue]
        }
        return try await call(ReviewResponse.self, method: "POST", path: "/v1/scans/\(Self.id(scanId))/review",
                              body: Body(challenge_id: Self.id(challengeId), action: action, reason_code: reasonCode,
                                         note: note, webauthn_assertion: webauthnAssertion),
                              auth: .user, idempotencyKey: idempotencyKey)
    }

    public func registerPushToken(deviceId: UUID, apnsToken: String, idempotencyKey: String) async throws {
        struct Body: Encodable { let device_id: String; let apns_token: String }
        let data = try JSONEncoder().encode(Body(device_id: Self.id(deviceId), apns_token: apnsToken))
        _ = try await send(method: "POST", path: "/v1/devices/push-token", body: data, auth: .device,
                           idempotencyKey: idempotencyKey)
    }

    public func deviceChallenge(idempotencyKey: String) async throws -> DeviceChallengeResponse {
        try await call(DeviceChallengeResponse.self, method: "POST", path: "/v1/devices/challenge", body: Empty(),
                       auth: .user, idempotencyKey: idempotencyKey)
    }

    public func attest(keyId: String, attestation: String, challenge: String, wardId: String,
                       idempotencyKey: String) async throws -> AttestResponse {
        struct Body: Encodable { let key_id: String; let attestation: String; let challenge: String; let ward_id: String }
        return try await call(AttestResponse.self, method: "POST", path: "/v1/devices/attest",
                              body: Body(key_id: keyId, attestation: attestation, challenge: challenge, ward_id: wardId),
                              auth: .user, idempotencyKey: idempotencyKey)
    }

    public func assert(deviceId: UUID, assertion: String, challenge: String, asUser: Bool) async throws -> AssertResponse {
        struct Body: Encodable { let device_id: String; let assertion: String; let challenge: String }
        return try await call(AssertResponse.self, method: "POST", path: "/v1/devices/assert",
                              body: Body(device_id: Self.id(deviceId), assertion: assertion, challenge: challenge),
                              auth: asUser ? .user : .none)
    }

    public func renewalChallenge(deviceId: UUID) async throws -> DeviceChallengeResponse {
        try await call(DeviceChallengeResponse.self, method: "POST",
                       path: "/v1/devices/\(Self.id(deviceId))/renewal-challenge", body: Empty(), auth: .none)
    }
}
