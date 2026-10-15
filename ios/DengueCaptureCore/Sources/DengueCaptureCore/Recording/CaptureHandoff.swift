import Foundation

/// One sealed artefact of one recorded attempt.
public struct SealedStepArtefact: Equatable {
    public var step: CaptureStep
    public var attempt: Int
    public var kind: ArtefactKind
    public var sealed: SealedArtefact
    public init(step: CaptureStep, attempt: Int, kind: ArtefactKind, sealed: SealedArtefact) {
        self.step = step; self.attempt = attempt; self.kind = kind; self.sealed = sealed
    }
}

public enum CaptureHandoffError: Error, Equatable {
    /// An accepted attempt lacks one of video / roi_trace / metadata.
    case missingArtefact(step: CaptureStep, attempt: Int, kind: ArtefactKind)
    /// createScan metadata fields the contract requires but that were not measured or entered (wire names).
    case metadataIncomplete([String])
    case noAttempts
}

/// What one finished capture session hands to the upload engine.
public struct CaptureSessionPlan {
    public var sessionId: UUID
    public var patientId: UUID
    /// Carries `device_attempts` for every attempt, including offline recaptures with verdicts and reasons.
    public var createScan: CreateScanRequest
    /// Reference vitals (nil when none were entered).
    public var clinicalData: ClinicalDataRequest?
    /// declare / upload / complete per artefact: video, roi_trace and metadata of each ACCEPTED attempt.
    public var artefacts: [ArtefactUpload]
    /// Sealed artefacts of attempts that were not accepted. Not uploaded: the caller destroys their keys and files.
    public var discarded: [SealedArtefact]

    /// Registers the session (createScan first; every artefact's declare depends on it), then the clinical data.
    public func enqueue(on engine: UploadEngine, participantCode: String) throws {
        try engine.enqueueSession(sessionId: sessionId, participantCode: participantCode, createScan: createScan,
                                  scanId: nil, artefacts: artefacts)
        if let clinicalData {
            try engine.enqueueClinicalData(sessionId: sessionId, patientId: patientId, request: clinicalData)
        }
    }
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
        for a in accepted {
            for kind in Self.artefactKinds {
                guard let s = artefacts.first(where: { $0.step == a.step && $0.attempt == a.attempt && $0.kind == kind })
                else { throw CaptureHandoffError.missingArtefact(step: a.step, attempt: a.attempt, kind: kind) }
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
            artefacts: uploads, discarded: discarded)
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

    /// createScan `metadata` from a recorded attempt's capture metadata. The contract requires distance, angle,
    /// lux and ambient temperature/humidity; any that were not measured/entered are reported, never invented.
    public static func scanMetadata(from m: CaptureMetadata) throws -> ScanMetadata {
        var missing: [String] = []
        if m.distanceCm == nil { missing.append("distance_cm") }
        if m.angleDeg == nil { missing.append("angle_deg") }
        if m.lux == nil { missing.append("lighting_lux") }
        if m.ambientTempC == nil { missing.append("ambient_temp_c") }
        if m.ambientHumidityPct == nil { missing.append("ambient_humidity_pct") }
        guard missing.isEmpty, let d = m.distanceCm, let a = m.angleDeg, let l = m.lux,
              let t = m.ambientTempC, let h = m.ambientHumidityPct else {
            throw CaptureHandoffError.metadataIncomplete(missing)
        }
        return ScanMetadata(cameraModel: m.deviceModel, frameRate: m.fps, resolution: m.resolution,
                            exposure: m.exposureDurationMs / 1000, distanceCm: d, angleDeg: a, lightingLux: l,
                            ambientTempC: t, ambientHumidityPct: h, mount: m.mount, lightingType: m.lightingType,
                            exposureDurationMs: m.exposureDurationMs)
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
