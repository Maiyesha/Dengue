import Foundation

/// One sealed artefact of one recorded attempt.
public struct SealedStepArtefact: Codable, Equatable {
    public var step: CaptureStep
    public var attempt: Int
    public var kind: ArtefactKind
    public var sealed: SealedArtefact
    public init(step: CaptureStep, attempt: Int, kind: ArtefactKind, sealed: SealedArtefact) {
        self.step = step; self.attempt = attempt; self.kind = kind; self.sealed = sealed
    }
}

/// Why a hand-off could not be enqueued (all recoverable: the hand-off is HELD, never shredded).
public enum CaptureHandoffError: Error, Equatable {
    case noAttempts
    /// createScan metadata fields the contract requires but that were not measured (wire names).
    case metadataIncomplete([String])
    /// Measured values outside the server's physical sanity ranges (would be a permanent 400); wire names.
    case metadataOutOfRange([String])
    case patientUnknown
    /// No upload engine (e.g. MDM `api_base_url` not provisioned yet).
    case uploadNotConfigured
    /// Local outbox write failed; carries only the error's type name.
    case enqueueFailed(String)
    /// No server KMS public key (Managed App Config `kms_public_key_pem` / `kms_key_id`): artefact data keys
    /// cannot be wrapped for the server, so nothing is uploaded yet (C1).
    case kmsKeyMissing

    /// PHI-free diagnostic for logs and the outbox screen's engineering detail.
    public var diagnostic: String {
        switch self {
        case .noAttempts: return "HANDOFF_NO_ATTEMPTS"
        case .metadataIncomplete(let f): return "HANDOFF_METADATA_INCOMPLETE:" + f.joined(separator: ",")
        case .metadataOutOfRange(let f): return "HANDOFF_METADATA_OUT_OF_RANGE:" + f.joined(separator: ",")
        case .patientUnknown: return "HANDOFF_PATIENT_UNKNOWN"
        case .uploadNotConfigured: return "HANDOFF_UPLOAD_NOT_CONFIGURED"
        case .enqueueFailed(let t): return "HANDOFF_ENQUEUE_FAILED:" + t
        case .kmsKeyMissing: return "KMS_KEY_MISSING"
        }
    }

    /// Only the error's type name: never its description, which could echo payload content.
    public static func enqueueFailed(_ error: Error) -> CaptureHandoffError {
        .enqueueFailed(String(describing: type(of: error)))
    }
}

/// What one finished capture session hands to the upload engine (enqueued by `CaptureHandoffService`).
public struct CaptureSessionPlan {
    public var sessionId: UUID
    public var patientId: UUID
    /// Carries `device_attempts` for every attempt, including offline recaptures with verdicts and reasons.
    public var createScan: CreateScanRequest
    /// Reference vitals (nil when none were entered).
    public var clinicalData: ClinicalDataRequest?
    /// declare / upload / complete per artefact of each ACCEPTED attempt (whatever kinds were sealed).
    public var artefacts: [ArtefactUpload]
    /// Accepted steps with fewer than three sealed artefacts (e.g. a seal failed): uploaded as partial.
    public var incompleteSteps: [CaptureStepName]
    /// Sealed artefacts of attempts that were not accepted. Not uploaded: the caller destroys their keys and files.
    public var discarded: [SealedArtefact]
}

/// Maps a finished capture (attempt log, vitals, sealed artefacts) onto the `UploadEngine` enqueue API.
public struct CaptureHandoff {
    private let makeId: () -> UUID

    public init(makeId: @escaping () -> UUID = UUID.init) { self.makeId = makeId }

    public static let artefactKinds: [ArtefactKind] = [.video, .roiTrace, .metadata]

    public func makeSessionPlan(sessionId: UUID, patientId: UUID, capturedAt: Date, offline: Bool,
                                protocolVersion: String, metadata: ScanMetadata, attempts: [AttemptRecord],
                                vitals: [VitalRecord], artefacts: [SealedStepArtefact]) throws -> CaptureSessionPlan {
        guard !attempts.isEmpty else { throw CaptureHandoffError.noAttempts }

        var steps: [CaptureStepName] = []
        for a in attempts where !steps.contains(Self.name(a.step)) { steps.append(Self.name(a.step)) }
        let createScan = CreateScanRequest(
            clientSessionId: sessionId, patientId: patientId, capturedAt: capturedAt, offline: offline,
            protocolVersion: protocolVersion, captureSteps: steps,
            deviceAttempts: attempts.map(Self.deviceAttempt), metadata: metadata)

        let accepted = attempts.filter { $0.verdict == .accept }
        var uploads: [ArtefactUpload] = []
        var incomplete: [CaptureStepName] = []
        for a in accepted {
            for kind in Self.artefactKinds {
                guard let s = artefacts.first(where: { $0.step == a.step && $0.attempt == a.attempt && $0.kind == kind })
                else {
                    if !incomplete.contains(Self.name(a.step)) { incomplete.append(Self.name(a.step)) }
                    continue
                }
                uploads.append(ArtefactUpload(localId: makeId(), step: Self.name(a.step), attempt: a.attempt,
                                              kind: kind, deviceVerdict: .accept, sealed: s.sealed))
            }
        }
        let uploadedPaths = Set(uploads.map { $0.sealed.path })
        let discarded = artefacts.map { $0.sealed }.filter { !uploadedPaths.contains($0.path) }

        let observations = vitals.map {
            VitalObservation(observationId: makeId(), vital: Self.kind($0.field), value: $0.value,
                             sourceDeviceType: $0.source.rawValue, measuredAt: $0.measuredAt,
                             scanClientSessionId: sessionId)
        }
        return CaptureSessionPlan(
            sessionId: sessionId, patientId: patientId, createScan: createScan,
            clinicalData: observations.isEmpty ? nil : ClinicalDataRequest(observations: observations),
            artefacts: uploads, incompleteSteps: incomplete, discarded: discarded)
    }

    public static func deviceAttempt(_ r: AttemptRecord) -> DeviceAttempt {
        switch r.verdict {
        case .accept:
            return DeviceAttempt(step: name(r.step), attempt: r.attempt, deviceVerdict: .accept, reasonCodes: [])
        case .recapture(let codes):
            return DeviceAttempt(step: name(r.step), attempt: r.attempt, deviceVerdict: .recapture,
                                 reasonCodes: codes.map { $0.rawValue })
        case .unableToAcquire(let codes):
            return DeviceAttempt(step: name(r.step), attempt: r.attempt, deviceVerdict: .unableToAcquire,
                                 reasonCodes: codes.map { $0.rawValue })
        }
    }

    /// createScan `metadata` from a recorded attempt's capture metadata. The contract requires the measured
    /// distance, angle and lux; any that were not measured are reported (the hand-off is then held), never
    /// invented. Ambient temperature/humidity are optional (only when entered).
    /// Mirrors backend/src/routes/scans.ts CaptureMetadata (T13 ruling: physical sanity, not the guidance spec).
    public static let sanityDistanceCm: ClosedRange<Double> = 5...300
    public static let sanityAngleDeg: ClosedRange<Double> = -90...90
    public static let sanityMinLux = 0.0

    public static func scanMetadata(from m: CaptureMetadata) throws -> ScanMetadata {
        var missing: [String] = []
        if m.distanceCm == nil { missing.append("distance_cm") }
        if m.angleDeg == nil { missing.append("angle_deg") }
        if m.lux == nil { missing.append("lighting_lux") }
        guard missing.isEmpty, let d = m.distanceCm, let a = m.angleDeg, let l = m.lux else {
            throw CaptureHandoffError.metadataIncomplete(missing)
        }
        // Server sanity ranges (backend CaptureMetadata): outside them createScan would 400 permanently.
        var outOfRange: [String] = []
        if !(d.isFinite && sanityDistanceCm.contains(d)) { outOfRange.append("distance_cm") }
        if !(a.isFinite && sanityAngleDeg.contains(a)) { outOfRange.append("angle_deg") }
        if !(l.isFinite && l >= sanityMinLux) { outOfRange.append("lighting_lux") }
        guard outOfRange.isEmpty else { throw CaptureHandoffError.metadataOutOfRange(outOfRange) }
        return ScanMetadata(cameraModel: m.deviceModel, frameRate: m.fps, resolution: m.resolution,
                            exposure: m.exposureDurationMs / 1000, distanceCm: d, angleDeg: a, lightingLux: l,
                            ambientTempC: m.ambientTempC, ambientHumidityPct: m.ambientHumidityPct, mount: m.mount,
                            lightingType: m.lightingType, exposureDurationMs: m.exposureDurationMs)
    }

    /// Seals `input` to `output` and deletes the plaintext on success. On failure the plaintext is left for the
    /// caller to delete (the sealer removes its own partial output).
    public static func sealAndRemovePlaintext(input: URL, output: URL, sealer: ArtefactSealer) throws -> SealedArtefact {
        let s = try sealer.seal(input: input, output: output)
        try FileManager.default.removeItem(at: input)
        return s
    }

    static func name(_ s: CaptureStep) -> CaptureStepName {
        switch s {
        case .neutralFace: return .neutralFace
        case .fingertipPPG: return .fingertipPPG
        case .ocularCapture: return .ocularCapture
        case .dorsalTongue: return .dorsalTongue
        }
    }

    static func kind(_ f: VitalField) -> VitalKind {
        switch f {
        case .hr: return .hr
        case .spo2: return .spo2
        case .sbp: return .sbp
        case .dbp: return .dbp
        case .tempC: return .tempC
        case .rr: return .rr
        case .crtS: return .crtS
        }
    }
}
