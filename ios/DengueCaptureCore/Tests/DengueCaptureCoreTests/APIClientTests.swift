import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DengueCaptureCore

/// URLProtocol stub. Tests run sequentially, so a static handler is safe.
final class StubProtocol: URLProtocol {
    struct Captured { var request: URLRequest; var body: Data? }
    nonisolated(unsafe) static var handler: ((Captured) -> (Int, Data))?
    nonisolated(unsafe) static var captured: [Captured] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            body = data
        }
        let cap = Captured(request: request, body: body)
        StubProtocol.captured.append(cap)
        let (status, data) = StubProtocol.handler?(cap) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    let uid = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    func makeAPI(tokens: @escaping @Sendable (AuthKind) async -> String? = { $0 == .user ? "U" : "D" }) -> URLSessionDengueAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSessionDengueAPI(baseURL: URL(string: "https://api.test")!,
                                   session: URLSession(configuration: cfg), tokenProvider: tokens)
    }

    override func setUp() {
        StubProtocol.handler = nil
        StubProtocol.captured = []
    }

    func envelope(_ code: String, detail: String = "{}") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"m","detail":\#(detail),"request_id":"r","trace_id":"t","timestamp":"2026-01-01T00:00:00Z"}}"#.utf8)
    }

    func scanRequest() -> CreateScanRequest {
        CreateScanRequest(
            clientSessionId: uid, patientId: uid, capturedAt: "2026-01-01T00:00:00Z", offline: false,
            protocolVersion: "1", captureSteps: [.neutralFace, .fingertipPPG],
            deviceAttempts: [DeviceAttempt(step: .neutralFace, attempt: 1, deviceVerdict: .accept, reasonCodes: [])],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: 28,
                                   ambientHumidityPct: 70, mount: "handheld", lightingType: "led",
                                   exposureDurationMs: 10))
    }

    func assertError(_ status: Int, _ body: Data, _ expected: APIError, line: UInt = #line) async {
        StubProtocol.handler = { _ in (status, body) }
        do {
            _ = try await makeAPI().createScan(scanRequest(), idempotencyKey: "k")
            XCTFail("expected throw", line: line)
        } catch {
            XCTAssertEqual(error as? APIError, expected, line: line)
        }
    }

    // MARK: brief tests

    func testDSREG002With422StillMapsToStopAndQuarantine() async {
        await assertError(422, envelope("DS_REG_002"), .stopAndQuarantine(code: "DS_REG_002"))
    }

    func testDSREG001With451MapsToStopAndQuarantine() async {
        await assertError(451, envelope("DS_REG_001"), .stopAndQuarantine(code: "DS_REG_001"))
    }

    func testDSAUD001403MapsToRetryable() async {
        await assertError(403, envelope("DS_AUD_001"), .retryable)
    }

    func testPostIncludesIdempotencyKeyAndTraceparent() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"scan":{"id":"11111111-1111-4111-8111-111111111111","status":"capture_pending","client_session_id":"11111111-1111-4111-8111-111111111111"}}"#.utf8)) }
        _ = try await makeAPI().createScan(scanRequest(), idempotencyKey: "key-123")
        let r = try XCTUnwrap(StubProtocol.captured.first).request
        XCTAssertEqual(r.value(forHTTPHeaderField: "Idempotency-Key"), "key-123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer U")
        let tp = try XCTUnwrap(r.value(forHTTPHeaderField: "traceparent"))
        XCTAssertNotNil(tp.range(of: "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$", options: .regularExpression))
        XCTAssertNotEqual(tp, URLSessionDengueAPI.makeTraceparent())
    }

    func testDecodesExperimentalEnabledFalse() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"enabled":false,"items":[]}"#.utf8)) }
        let r = try await makeAPI().experimental(scanId: uid)
        XCTAssertFalse(r.enabled)
        XCTAssertTrue(r.items.isEmpty)
    }

    // MARK: error dispatch

    func testNonJSONErrorBodiesMapByStatus() async {
        await assertError(502, Data("<html>bad gateway</html>".utf8), .retryable)
        await assertError(401, Data("nope".utf8), .unauthorized)
        await assertError(400, Data("nope".utf8), .invalid(code: ""))
    }

    func testQG099ParsesRecaptureExhaustedDetail() async {
        await assertError(422, envelope("DS_QG_099", detail: #"{"unable_to_acquire":["neutral_face"],"recaptured":["fingertip_ppg"],"status":"partial"}"#),
                          .recaptureExhausted(unableToAcquire: ["neutral_face"], recaptured: ["fingertip_ppg"], status: "partial"))
        await assertError(422, envelope("DS_QG_001"), .needsRepeat([.dsQG001]))
    }

    func testMalformedDetailDoesNotBlockCode() async {
        await assertError(451, Data(#"{"error":{"code":"DS_REG_001","detail":[1,2,"x"]}}"#.utf8), .stopAndQuarantine(code: "DS_REG_001"))
        await assertError(451, Data(#"{"error":{"code":"DS_REG_001","detail":"str","message":5}}"#.utf8), .stopAndQuarantine(code: "DS_REG_001"))
        await assertError(451, Data(#"{"error":{"code":"DS_REG_001"}}"#.utf8), .stopAndQuarantine(code: "DS_REG_001"))
    }

    func testIdempotencyCodes() async {
        await assertError(409, envelope("DS_IDEMPOTENCY_003"), .retryable)
        await assertError(409, envelope("DS_IDEMPOTENCY_001"), .invalid(code: "DS_IDEMPOTENCY_001"))
        await assertError(400, envelope("DS_IDEMPOTENCY_002"), .invalid(code: "DS_IDEMPOTENCY_002"))
    }

    func testUndecodable2xxIsRetryable() async {
        StubProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do { _ = try await makeAPI().getScan(id: uid); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .retryable)
        }
    }

    func testRequestBodyUUIDsAreLowercase() async throws {
        let hexy = UUID(uuidString: "ABCDEF12-ABCD-4BCD-8BCD-ABCDEF123456")!
        let low = "abcdef12-abcd-4bcd-8bcd-abcdef123456"
        StubProtocol.handler = { c in
            let p = c.request.url!.path
            if p.hasSuffix("/v1/scans") { return (201, Data(#"{"scan":{"id":"\#(low)","status":"capture_pending","client_session_id":"\#(low)"}}"#.utf8)) }
            if p.hasSuffix("clinical-data") { return (201, Data(#"{"accepted":1,"duplicates":0,"invalid":[]}"#.utf8)) }
            if p.hasSuffix("/review") { return (201, Data(#"{"review_id":"\#(low)","scan_id":"\#(low)","status":"reviewed","push":"sent"}"#.utf8)) }
            if p.hasSuffix("assert") { return (200, Data(#"{"device_token":"t","expires_in":86400}"#.utf8)) }
            return (204, Data())
        }
        let api = makeAPI()
        var req = scanRequest()
        req.clientSessionId = hexy; req.patientId = hexy
        _ = try await api.createScan(req, idempotencyKey: "k")
        let obs = VitalObservation(observationId: hexy, vital: .hr, value: 80, sourceDeviceType: "m", measuredAt: Date(timeIntervalSince1970: 0), scanClientSessionId: hexy)
        let lab = LabResult(id: hexy, test: .haemoglobin, value: 12, collectedAt: Date(timeIntervalSince1970: 0), methodology: "x")
        _ = try await api.postClinicalData(patientId: hexy, request: ClinicalDataRequest(observations: [obs], labs: [lab]), idempotencyKey: "k")
        _ = try await api.review(scanId: hexy, challengeId: hexy, action: .confirm, reasonCode: nil, note: nil, webauthnAssertion: [:], idempotencyKey: "k")
        try await api.registerPushToken(deviceId: hexy, apnsToken: String(repeating: "a", count: 64), idempotencyKey: "k")
        _ = try await api.assert(deviceId: hexy, assertion: "AAAA", challenge: "AAAA")
        XCTAssertEqual(StubProtocol.captured.count, 5)
        for c in StubProtocol.captured {
            let text = String(decoding: try XCTUnwrap(c.body), as: UTF8.self)
            XCTAssertFalse(text.contains("ABCDEF12"), text)
            XCTAssertTrue(text.contains(low), text)
            XCTAssertFalse(c.request.url!.path.contains("ABCDEF"))
        }
    }

    func testAssertAuthEnrolmentVsRenewal() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"device_token":"t","expires_in":86400}"#.utf8)) }
        let api = makeAPI()
        _ = try await api.assert(deviceId: uid, assertion: "AAAA", challenge: "AAAA", asUser: true)
        _ = try await api.assert(deviceId: uid, assertion: "AAAA", challenge: "AAAA", asUser: false)
        XCTAssertEqual(StubProtocol.captured[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer U")
        XCTAssertNil(StubProtocol.captured[1].request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGetScanDeviceAuth() async throws {
        StubProtocol.handler = { _ in (200, self.fixture(for: "/v1/scans/{id}", method: "GET")) }
        let api = makeAPI()
        _ = try await api.getScan(id: uid, auth: .device)
        _ = try await api.getScan(id: uid)
        XCTAssertEqual(StubProtocol.captured[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer D")
        XCTAssertEqual(StubProtocol.captured[1].request.value(forHTTPHeaderField: "Authorization"), "Bearer U")
    }

    func testWireDateFormat() {
        XCTAssertEqual(WireDate.string(from: Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(WireDate.string(from: Date(timeIntervalSince1970: 1_800_000_000.5)), "2027-01-15T08:00:00.500Z")
        XCTAssertEqual(WireDate.date(from: "2026-01-01T00:00:00Z"), Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertNotNil(WireDate.date(from: "2026-01-01T00:00:00.123Z"))
        let req = CreateScanRequest(clientSessionId: uid, patientId: uid, capturedAt: Date(timeIntervalSince1970: 0), offline: false,
                                    protocolVersion: "1", captureSteps: [.neutralFace], deviceAttempts: [], metadata: scanRequest().metadata)
        XCTAssertEqual(req.capturedAt, "1970-01-01T00:00:00.000Z")
    }

    func testOtherCodes() async {
        await assertError(409, envelope("DS_SCAN_001"), .duplicateRecent)
        await assertError(409, envelope("DS_UPLOAD_001"), .uploadHashMismatch)
        await assertError(409, envelope("DS_UPLOAD_005"), .uploadIncomplete)
        await assertError(429, envelope("DS_RATE_001"), .retryable)
        await assertError(401, envelope("DS_DEVICE_001"), .reEnrol)
        await assertError(500, envelope("DS_INTERNAL_001"), .retryable)
    }

    func testTransportFailureIsRetryable() async {
        final class Failing: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Failing.self]
        let api = URLSessionDengueAPI(baseURL: URL(string: "https://api.test")!,
                                      session: URLSession(configuration: cfg), tokenProvider: { _ in nil })
        do { _ = try await api.getScan(id: uid); XCTFail() } catch {
            XCTAssertEqual(error as? APIError, .retryable)
        }
    }

    // MARK: exempt routes and auth

    func testIdempotencyExemptRoutesSendNoKeyAndAuthMatchesContract() async throws {
        StubProtocol.handler = { c in
            let p = c.request.url!.path
            if p.hasSuffix("/url") { return (200, Data(#"{"url":"https://s3/x","expires_in":900}"#.utf8)) }
            if p.hasSuffix("renewal-challenge") { return (200, Data(#"{"challenge":"AAAA"}"#.utf8)) }
            return (200, Data(#"{"device_token":"t","expires_in":86400}"#.utf8))
        }
        let api = makeAPI()
        _ = try await api.partURL(artefactId: uid, part: 3)
        _ = try await api.renewalChallenge(deviceId: uid)
        _ = try await api.assert(deviceId: uid, assertion: "AAAA", challenge: "AAAA")
        for c in StubProtocol.captured { XCTAssertNil(c.request.value(forHTTPHeaderField: "Idempotency-Key")) }
        XCTAssertEqual(StubProtocol.captured[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer D")
        XCTAssertNil(StubProtocol.captured[1].request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(StubProtocol.captured[2].request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(StubProtocol.captured[0].request.url?.path, "/v1/artefacts/\(uid.uuidString.lowercased())/parts/3/url")
    }

    func testClinicalDataUsesFixedUnits() throws {
        let o = VitalObservation(observationId: uid, vital: .tempC, value: 37, sourceDeviceType: "monitor", measuredAt: "2026-01-01T00:00:00Z")
        XCTAssertEqual(o.unit, "\u{00B0}C")
        XCTAssertEqual(VitalObservation(observationId: uid, vital: .hr, value: 80, sourceDeviceType: "m", measuredAt: "x").unit, "/min")
        XCTAssertEqual(VitalObservation(observationId: uid, vital: .sbp, value: 80, sourceDeviceType: "m", measuredAt: "x").unit, "mmHg")
        XCTAssertEqual(VitalObservation(observationId: uid, vital: .crtS, value: 2, sourceDeviceType: "m", measuredAt: "x").unit, "s")
        XCTAssertEqual(VitalObservation(observationId: uid, vital: .spo2, value: 97, sourceDeviceType: "m", measuredAt: "x").unit, "%")
    }

    // MARK: contract conformance

    func contract() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("contracts/openapi-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Fixtures derived from the contract's response schemas (every required field present).
    func fixture(for path: String, method: String) -> Data {
        let u = "11111111-1111-4111-8111-111111111111"
        let consent = #"{"primary_research":true,"consent_version":"1","current_version":"2","withdrawn":false,"capture_allowed":false,"block_code":"DS_REG_002","checked_at":"2026-01-01T00:00:00Z"}"#
        let scan = #"{"id":"\#(u)","status":"quality_failed","steps":[{"step":"neutral_face","attempt":1,"device_verdict":"ACCEPT","server_verdict":null,"reason_codes":["DS_QG_001"]}],"recaptures_remaining":{"neutral_face":2}}"#
        switch (method, path) {
        case ("GET", "/v1/patients/lookup"): return Data(#"{"patient_id":"\#(u)","participant_code":"DS-SG-00123","bed_label":null,"ward_id":"W1","last_captured_at":null}"#.utf8)
        case ("GET", "/v1/wards/{wardId}/roster"): return Data(#"{"items":[{"patient_id":"\#(u)","participant_code":"DS-SG-00123","bed_label":"B1","consent":\#(consent)}],"generated_at":"2026-01-01T00:00:00Z"}"#.utf8)
        case ("GET", "/v1/patients/{id}/consent-status"): return Data(consent.utf8)
        case ("POST", "/v1/scans"): return Data(#"{"scan":{"id":"\#(u)","status":"capture_pending","client_session_id":"\#(u)"}}"#.utf8)
        case ("GET", "/v1/scans/{id}"), ("POST", "/v1/scans/{id}/recapture"): return Data(#"{"scan":\#(scan)}"#.utf8)
        case ("POST", "/v1/scans/{id}/artefacts"): return Data(#"{"artefact_id":"\#(u)","upload_id":null}"#.utf8)
        case ("POST", "/v1/artefacts/{id}/parts/{n}/url"): return Data(#"{"url":"https://s3/x","expires_in":900}"#.utf8)
        case ("POST", "/v1/artefacts/{id}/complete"): return Data(#"{"status":"received_verified"}"#.utf8)
        case ("POST", "/v1/patients/{id}/clinical-data"): return Data(#"{"accepted":1,"duplicates":0,"invalid":["\#(u)"]}"#.utf8)
        case ("GET", "/v1/scans/{id}/experimental"): return Data(#"{"enabled":true,"items":[{"domain":"rppg_face","pulse_rate_bpm":88,"label":"EXPERIMENTAL","notice":"n"}]}"#.utf8)
        case ("POST", "/v1/scans/{id}/review-challenge"): return Data(#"{"challenge_id":"\#(u)","challenge":"abc","expires_in":300}"#.utf8)
        case ("POST", "/v1/scans/{id}/review"): return Data(#"{"review_id":"\#(u)","scan_id":"\#(u)","status":"reviewed","push":"skipped"}"#.utf8)
        case ("POST", "/v1/devices/push-token"): return Data()
        case ("POST", "/v1/devices/challenge"), ("POST", "/v1/devices/{id}/renewal-challenge"): return Data(#"{"challenge":"AAAA"}"#.utf8)
        case ("POST", "/v1/devices/attest"): return Data(#"{"device_id":"\#(u)"}"#.utf8)
        case ("POST", "/v1/devices/assert"): return Data(#"{"device_token":"t","expires_in":86400}"#.utf8)
        default: return Data()
        }
    }

    /// Map a concrete request path back to the contract's template.
    func template(for path: String, in paths: [String: Any]) -> String? {
        for tpl in paths.keys {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: tpl)
                .replacingOccurrences(of: "\\{", with: "{").replacingOccurrences(of: "\\}", with: "}")
                .replacingOccurrences(of: #"\{[A-Za-z]+\}"#, with: "[^/]+", options: .regularExpression) + "$"
            if path.range(of: pattern, options: .regularExpression) != nil { return tpl }
        }
        return nil
    }

    func testEveryCalledOperationExistsInContractAndBodiesConform() async throws {
        let paths = try XCTUnwrap(try contract()["paths"] as? [String: Any])
        StubProtocol.handler = { c in
            let tpl = self.template(for: c.request.url!.path, in: paths) ?? ""
            let status = (tpl == "/v1/devices/push-token") ? 204 : 200
            return (status, self.fixture(for: tpl, method: c.request.httpMethod ?? ""))
        }
        let api = makeAPI()
        let obs = VitalObservation(observationId: uid, vital: .hr, value: 80, sourceDeviceType: "monitor", measuredAt: "2026-01-01T00:00:00Z")
        let lab = LabResult(id: uid, test: .plateletCount, value: 100, collectedAt: "2026-01-01T00:00:00Z", methodology: "x")

        let consent = try await api.lookup(participantCode: "DS-SG-00123")
        XCTAssertEqual(consent.participantCode, "DS-SG-00123")
        let roster = try await api.roster(wardId: "W1")
        XCTAssertEqual(roster.items.first?.consent.blockCode, "DS_REG_002")
        let cs = try await api.consentStatus(patientId: uid)
        XCTAssertFalse(cs.captureAllowed)
        XCTAssertEqual(cs.blockCode, "DS_REG_002")
        _ = try await api.createScan(scanRequest(), idempotencyKey: "k1")
        let sc = try await api.getScan(id: uid)
        XCTAssertEqual(sc.scan.recapturesRemaining["neutral_face"], 2)
        XCTAssertEqual(sc.scan.steps.first?.reasonCodes, ["DS_QG_001"])
        _ = try await api.recapture(scanId: uid, steps: [.neutralFace], reason: "DS_QG_001", idempotencyKey: "k2")
        let d = try await api.declareArtefact(
            scanId: uid, request: DeclareArtefactRequest(step: .neutralFace, attempt: 1, kind: .video,
                                                         sizeBytes: 10, sha256: String(repeating: "a", count: 64),
                                                         deviceVerdict: .accept,
                                                         wrappedKey: WrappedKey(wrappedKeyB64: "QUJD", kmsKeyId: "kms")),
            idempotencyKey: "k3")
        XCTAssertNil(d.uploadId)
        _ = try await api.partURL(artefactId: uid, part: 1)
        let comp = try await api.completeArtefact(id: uid, idempotencyKey: "k4")
        XCTAssertEqual(comp.status, "received_verified")
        let cd = try await api.postClinicalData(patientId: uid, request: ClinicalDataRequest(observations: [obs], labs: [lab]), idempotencyKey: "k5")
        XCTAssertEqual(cd.invalid, [uid])
        let ex = try await api.experimental(scanId: uid)
        XCTAssertEqual(ex.items.first?.pulseRateBpm, 88)
        let ch = try await api.reviewChallenge(scanId: uid, action: .requestRepeat, reasonCode: "x", note: nil)
        XCTAssertEqual(ch.expiresIn, 300)
        let rv = try await api.review(scanId: uid, challengeId: ch.challengeId, action: .confirm, reasonCode: nil,
                                      note: "n", webauthnAssertion: ["id": .string("a"), "n": .number(1)], idempotencyKey: "k6")
        XCTAssertEqual(rv.push, .skipped)
        try await api.registerPushToken(deviceId: uid, apnsToken: String(repeating: "a", count: 64), idempotencyKey: "k7")
        _ = try await api.deviceChallenge(idempotencyKey: "k8")
        _ = try await api.attest(keyId: "kid", attestation: "AAAA", challenge: "AAAA", wardId: "W1", idempotencyKey: "k9")
        let tok = try await api.assert(deviceId: uid, assertion: "AAAA", challenge: "AAAA")
        XCTAssertEqual(tok.expiresIn, 86400)
        _ = try await api.renewalChallenge(deviceId: uid)

        XCTAssertEqual(StubProtocol.captured.count, 18)
        for c in StubProtocol.captured {
            let method = (c.request.httpMethod ?? "").lowercased()
            let path = c.request.url!.path
            let tpl = try XCTUnwrap(template(for: path, in: paths), "no contract path for \(path)")
            let op = try XCTUnwrap((paths[tpl] as? [String: Any])?[method] as? [String: Any], "no \(method) \(tpl)")
            // request body keys must be within the schema's properties and include its required keys
            if let rb = op["requestBody"] as? [String: Any],
               let schema = ((rb["content"] as? [String: Any])?["application/json"] as? [String: Any])?["schema"] as? [String: Any],
               let props = schema["properties"] as? [String: Any] {
                let body = try XCTUnwrap(c.body, "\(tpl) missing body")
                let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertTrue(Set(obj.keys).isSubset(of: Set(props.keys)), "\(tpl) extra keys \(Set(obj.keys).subtracting(props.keys))")
                let req = Set((schema["required"] as? [String]) ?? [])
                XCTAssertTrue(req.isSubset(of: Set(obj.keys)), "\(tpl) missing \(req.subtracting(obj.keys))")
            }
            // idempotency header present iff the contract operation declares the parameter
            let params = (op["parameters"] as? [[String: Any]]) ?? []
            let wantsKey = params.contains { ($0["$ref"] as? String)?.hasSuffix("IdempotencyKey") == true }
            XCTAssertEqual(c.request.value(forHTTPHeaderField: "Idempotency-Key") != nil, wantsKey, "\(method) \(tpl)")
        }
    }
}
