import Foundation

// Hand-written Codable mirrors of contracts/openapi-v1.json. Wire format is snake_case (explicit CodingKeys).
// Date-time fields stay ISO-8601 strings: the caller formats requests and the server formats responses.

public enum CaptureStepName: String, Codable, Equatable {
    case neutralFace = "neutral_face"
    case fingertipPPG = "fingertip_ppg"
    case ocularCapture = "ocular_capture"
    case dorsalTongue = "dorsal_tongue"
}

public enum DeviceVerdict: String, Codable, Equatable {
    case accept = "ACCEPT"
    case recapture = "RECAPTURE"
    case unableToAcquire = "UNABLE_TO_ACQUIRE"
}

public enum ScanStatus: String, Codable, Equatable {
    case capturePending = "capture_pending", qualityPending = "quality_pending"
    case qualityPassed = "quality_passed", qualityFailed = "quality_failed"
    case featurePending = "feature_pending", featureComplete = "feature_complete"
    case acquisitionFailure = "acquisition_failure", partial
    case reviewPending = "review_pending", reviewed, flagged, excluded, archived, revoked
}

public enum ArtefactKind: String, Codable, Equatable { case video, roiTrace = "roi_trace", metadata }

public struct ConsentStatus: Codable, Equatable {
    public var primaryResearch: Bool
    public var consentVersion: String
    public var currentVersion: String
    public var withdrawn: Bool
    /// True only when `blockCode` is nil (the server's capture gate rule).
    public var captureAllowed: Bool
    /// "DS_REG_001" / "DS_REG_002" or nil.
    public var blockCode: String?
    public var checkedAt: String
    enum CodingKeys: String, CodingKey {
        case primaryResearch = "primary_research", consentVersion = "consent_version"
        case currentVersion = "current_version", withdrawn
        case captureAllowed = "capture_allowed", blockCode = "block_code", checkedAt = "checked_at"
    }
}

public struct PatientLookup: Codable, Equatable {
    public var patientId: UUID
    public var participantCode: String
    public var bedLabel: String?
    public var wardId: String?
    public var lastCapturedAt: String?
    enum CodingKeys: String, CodingKey {
        case patientId = "patient_id", participantCode = "participant_code"
        case bedLabel = "bed_label", wardId = "ward_id", lastCapturedAt = "last_captured_at"
    }
}

public struct RosterItem: Codable, Equatable {
    public var patientId: UUID
    public var participantCode: String
    public var bedLabel: String?
    public var consent: ConsentStatus
    enum CodingKeys: String, CodingKey {
        case patientId = "patient_id", participantCode = "participant_code", bedLabel = "bed_label", consent
    }
}

public struct Roster: Codable, Equatable {
    public var items: [RosterItem]
    public var generatedAt: String
    enum CodingKeys: String, CodingKey { case items, generatedAt = "generated_at" }
}

public struct DeviceAttempt: Codable, Equatable {
    public var step: CaptureStepName
    public var attempt: Int
    public var deviceVerdict: DeviceVerdict
    public var reasonCodes: [String]
    public init(step: CaptureStepName, attempt: Int, deviceVerdict: DeviceVerdict, reasonCodes: [String]) {
        self.step = step; self.attempt = attempt; self.deviceVerdict = deviceVerdict; self.reasonCodes = reasonCodes
    }
    enum CodingKeys: String, CodingKey {
        case step, attempt, deviceVerdict = "device_verdict", reasonCodes = "reason_codes"
    }
}

public struct ScanMetadata: Codable, Equatable {
    public var cameraModel: String
    public var frameRate: Double
    public var resolution: String
    public var exposure: Double
    public var distanceCm: Double
    public var angleDeg: Double
    public var lightingLux: Double
    public var ambientTempC: Double
    public var ambientHumidityPct: Double
    public var mount: String
    public var lightingType: String
    public var exposureDurationMs: Double
    public init(cameraModel: String, frameRate: Double, resolution: String, exposure: Double, distanceCm: Double,
                angleDeg: Double, lightingLux: Double, ambientTempC: Double, ambientHumidityPct: Double,
                mount: String, lightingType: String, exposureDurationMs: Double) {
        self.cameraModel = cameraModel; self.frameRate = frameRate; self.resolution = resolution
        self.exposure = exposure; self.distanceCm = distanceCm; self.angleDeg = angleDeg
        self.lightingLux = lightingLux; self.ambientTempC = ambientTempC
        self.ambientHumidityPct = ambientHumidityPct; self.mount = mount; self.lightingType = lightingType
        self.exposureDurationMs = exposureDurationMs
    }
    enum CodingKeys: String, CodingKey {
        case cameraModel = "camera_model", frameRate = "frame_rate", resolution, exposure
        case distanceCm = "distance_cm", angleDeg = "angle_deg", lightingLux = "lighting_lux"
        case ambientTempC = "ambient_temp_c", ambientHumidityPct = "ambient_humidity_pct"
        case mount, lightingType = "lighting_type", exposureDurationMs = "exposure_duration_ms"
    }
}

public struct CreateScanRequest: Codable, Equatable {
    public var clientSessionId: UUID
    public var patientId: UUID
    public var capturedAt: String
    public var offline: Bool
    public var protocolVersion: String
    public var captureSteps: [CaptureStepName]
    public var deviceAttempts: [DeviceAttempt]
    public var metadata: ScanMetadata
    public init(clientSessionId: UUID, patientId: UUID, capturedAt: String, offline: Bool, protocolVersion: String,
                captureSteps: [CaptureStepName], deviceAttempts: [DeviceAttempt], metadata: ScanMetadata) {
        self.clientSessionId = clientSessionId; self.patientId = patientId; self.capturedAt = capturedAt
        self.offline = offline; self.protocolVersion = protocolVersion; self.captureSteps = captureSteps
        self.deviceAttempts = deviceAttempts; self.metadata = metadata
    }
    enum CodingKeys: String, CodingKey {
        case clientSessionId = "client_session_id", patientId = "patient_id", capturedAt = "captured_at"
        case offline, protocolVersion = "protocol_version", captureSteps = "capture_steps"
        case deviceAttempts = "device_attempts", metadata
    }
}

public struct ScanSummary: Codable, Equatable {
    public var id: UUID
    public var status: ScanStatus
    public var clientSessionId: UUID
    enum CodingKeys: String, CodingKey { case id, status, clientSessionId = "client_session_id" }
}
public struct CreateScanResponse: Codable, Equatable { public var scan: ScanSummary }

public struct ScanStepState: Codable, Equatable {
    public var step: String
    public var attempt: Int
    public var deviceVerdict: DeviceVerdict
    public var serverVerdict: String?
    public var reasonCodes: [String]
    enum CodingKeys: String, CodingKey {
        case step, attempt, deviceVerdict = "device_verdict", serverVerdict = "server_verdict"
        case reasonCodes = "reason_codes"
    }
}

public struct ScanDetail: Codable, Equatable {
    public var id: UUID
    public var status: ScanStatus
    public var steps: [ScanStepState]
    public var recapturesRemaining: [String: Int]
    enum CodingKeys: String, CodingKey { case id, status, steps, recapturesRemaining = "recaptures_remaining" }
}
/// Response of GET /v1/scans/{id} and POST /v1/scans/{id}/recapture.
public struct ScanResponse: Codable, Equatable { public var scan: ScanDetail }

public struct DeclareArtefactRequest: Codable, Equatable {
    public var step: CaptureStepName
    public var attempt: Int
    public var kind: ArtefactKind
    /// Size of the SEALED (uploaded) bytes.
    public var sizeBytes: Int64
    /// Lowercase hex SHA-256 of the SEALED (uploaded) bytes.
    public var sha256: String
    public var deviceVerdict: DeviceVerdict?
    public init(step: CaptureStepName, attempt: Int, kind: ArtefactKind, sizeBytes: Int64, sha256: String,
                deviceVerdict: DeviceVerdict? = nil) {
        self.step = step; self.attempt = attempt; self.kind = kind
        self.sizeBytes = sizeBytes; self.sha256 = sha256; self.deviceVerdict = deviceVerdict
    }
    enum CodingKeys: String, CodingKey {
        case step, attempt, kind, sizeBytes = "size_bytes", sha256, deviceVerdict = "device_verdict"
    }
}

public struct DeclareArtefactResponse: Codable, Equatable {
    public var artefactId: UUID
    public var uploadId: String?
    enum CodingKeys: String, CodingKey { case artefactId = "artefact_id", uploadId = "upload_id" }
}

public struct PartURLResponse: Codable, Equatable {
    public var url: String
    public var expiresIn: Int
    enum CodingKeys: String, CodingKey { case url, expiresIn = "expires_in" }
}

public struct CompleteArtefactResponse: Codable, Equatable { public var status: String }

public enum VitalKind: String, Codable, Equatable {
    case hr, spo2, sbp, dbp, rr
    case tempC = "temp_c"
    case crtS = "crt_s"
    /// Fixed unit string required by the contract.
    public var unit: String {
        switch self {
        case .hr, .rr: return "/min"
        case .spo2: return "%"
        case .sbp, .dbp: return "mmHg"
        case .tempC: return "\u{00B0}C"
        case .crtS: return "s"
        }
    }
}

public enum LabKind: String, Codable, Equatable {
    case haemoglobin, haematocrit
    case wbcCount = "wbc_count"
    case plateletCount = "platelet_count"
    public var unit: String {
        switch self {
        case .haemoglobin: return "g/dL"
        case .haematocrit: return "%"
        case .wbcCount, .plateletCount: return "10^9/L"
        }
    }
}

public struct VitalObservation: Codable, Equatable {
    public var observationId: UUID
    public var vital: VitalKind
    public var value: Double
    public var unit: String
    public var sourceDeviceType: String
    public var measuredAt: String
    public var scanClientSessionId: UUID?
    /// The unit is always derived from `vital` so it cannot drift from the contract.
    public init(observationId: UUID, vital: VitalKind, value: Double, sourceDeviceType: String,
                measuredAt: String, scanClientSessionId: UUID? = nil) {
        self.observationId = observationId; self.vital = vital; self.value = value; self.unit = vital.unit
        self.sourceDeviceType = sourceDeviceType; self.measuredAt = measuredAt
        self.scanClientSessionId = scanClientSessionId
    }
    enum CodingKeys: String, CodingKey {
        case observationId = "observation_id", vital, value, unit
        case sourceDeviceType = "source_device_type", measuredAt = "measured_at"
        case scanClientSessionId = "scan_client_session_id"
    }
}

public struct LabResult: Codable, Equatable {
    public var id: UUID
    public var test: LabKind
    public var value: Double
    public var unit: String
    public var collectedAt: String
    public var methodology: String
    public init(id: UUID, test: LabKind, value: Double, collectedAt: String, methodology: String) {
        self.id = id; self.test = test; self.value = value; self.unit = test.unit
        self.collectedAt = collectedAt; self.methodology = methodology
    }
    enum CodingKeys: String, CodingKey {
        case id, test, value, unit, collectedAt = "collected_at", methodology
    }
}

public struct ClinicalDataRequest: Codable, Equatable {
    public var observations: [VitalObservation]
    public var labs: [LabResult]?
    public init(observations: [VitalObservation], labs: [LabResult]? = nil) {
        self.observations = observations; self.labs = labs
    }
}

public struct ClinicalDataResponse: Codable, Equatable {
    public var accepted: Int
    public var duplicates: Int
    public var invalid: [UUID]
}

public enum ReviewAction: String, Codable, Equatable {
    case confirm, flag, exclude
    case requestRepeat = "request_repeat"
}

public struct ReviewChallengeResponse: Codable, Equatable {
    public var challengeId: UUID
    /// base64url, no padding; the WebAuthn challenge to sign.
    public var challenge: String
    public var expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id", challenge, expiresIn = "expires_in"
    }
}

/// Minimal JSON value for opaque objects (WebAuthn assertion) and error detail.
public enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public struct ReviewResponse: Codable, Equatable {
    public enum Push: String, Codable, Equatable { case sent, failed, skipped }
    public var reviewId: UUID
    public var scanId: UUID
    public var status: ScanStatus
    public var push: Push
    enum CodingKeys: String, CodingKey { case reviewId = "review_id", scanId = "scan_id", status, push }
}

public struct DeviceChallengeResponse: Codable, Equatable { public var challenge: String }

public struct AttestResponse: Codable, Equatable {
    public var deviceId: UUID
    enum CodingKeys: String, CodingKey { case deviceId = "device_id" }
}

public struct AssertResponse: Codable, Equatable {
    public var deviceToken: String
    public var expiresIn: Int
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token", expiresIn = "expires_in" }
}

/// Server error envelope: {"error":{"code",...}}.
public struct ErrorEnvelope: Decodable {
    public struct Body: Decodable {
        public var code: String
        public var message: String?
        public var detail: [String: JSONValue]?
        public var requestId: String?
        public var traceId: String?
        enum CodingKeys: String, CodingKey {
            case code, message, detail, requestId = "request_id", traceId = "trace_id"
        }
    }
    public var error: Body
}
