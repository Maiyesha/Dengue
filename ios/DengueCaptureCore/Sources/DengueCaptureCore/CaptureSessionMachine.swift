public enum StepVerdict: Codable, Equatable {
    case accept
    case recapture([ReasonCode])
    case unableToAcquire([ReasonCode])
}

/// One consumed attempt and its effective device verdict (an exhausted recapture is logged as unableToAcquire).
/// Paused / interrupted attempts are not consumed and not logged.
public struct AttemptRecord: Codable, Equatable {
    public var step: CaptureStep
    public var attempt: Int
    public var verdict: StepVerdict
    public init(step: CaptureStep, attempt: Int, verdict: StepVerdict) {
        self.step = step; self.attempt = attempt; self.verdict = verdict
    }
}

public enum SessionOutcome: Equatable {
    case accepted
    case partial(failedCore: [CaptureStep])
    case acquisitionFailure
}

public enum BlockReason: Equatable {
    case lowStorage, lowBattery, consentInvalid, cameraPermissionDenied
    /// No depth-capable TrueDepth front camera format (spec section 17): blocked before capture.
    case unsupportedDevice
}

public enum SessionState: Equatable {
    case positioning(CaptureStep)
    case recording(CaptureStep, attempt: Int)
    case reviewingStep(CaptureStep, attempt: Int)
    case completed(SessionOutcome)
    case blocked(BlockReason)
}

public enum PreflightWarning: Equatable { case lowBattery }

public struct Preflight: Equatable {
    public static let minimumFreeBytes: Int64 = 2_000_000_000
    public static let minimumBattery: Double = 0.05
    /// I5: below this the capture screen warns (capture still allowed).
    public static let warnBattery: Double = 0.15

    public var freeBytes: Int64
    public var batteryLevel: Double
    /// `UIDevice.batteryLevel` (0...1); negative = unknown (monitoring off, simulator): never low.
    /// The front camera offers a depth-capable TrueDepth format (needed for distance_cm).
    public var supportsDepthCapture: Bool

    public init(freeBytes: Int64, batteryLevel: Double, supportsDepthCapture: Bool = true) {
        self.freeBytes = freeBytes
        self.batteryLevel = batteryLevel
        self.supportsDepthCapture = supportsDepthCapture
    }

    public var blockReason: BlockReason? {
        if freeBytes < Preflight.minimumFreeBytes { return .lowStorage }
        if batteryLevel >= 0, batteryLevel < Preflight.minimumBattery { return .lowBattery }
        if !supportsDepthCapture { return .unsupportedDevice }
        return nil
    }

    public var canStartCapture: Bool { blockReason == nil }

    public var warning: PreflightWarning? {
        if batteryLevel >= 0, batteryLevel < Preflight.warnBattery { return .lowBattery }
        return nil
    }
}

public final class CaptureSessionMachine {
    public private(set) var state: SessionState
    /// Latest recapture / unable-to-acquire reasons per step (for the quality screen).
    public private(set) var lastReasons: [CaptureStep: [ReasonCode]] = [:]
    /// Every consumed attempt in order, for createScan `device_attempts`.
    public private(set) var attemptLog: [AttemptRecord] = []

    private let captureProtocol: CaptureProtocol
    private var index = 0
    private var attemptCounts: [CaptureStep: Int] = [:]
    private var failedSteps: [CaptureStep] = []
    private var acceptedSteps: [CaptureStep] = []

    public init(protocol captureProtocol: CaptureProtocol, preflight: Preflight) {
        self.captureProtocol = captureProtocol
        if let reason = preflight.blockReason {
            state = .blocked(reason)
        } else if let first = captureProtocol.steps.first {
            state = .positioning(first.step)
        } else {
            state = .completed(.acquisitionFailure)
        }
    }

    /// Completed (consumed) attempts for a step.
    public func attempts(for step: CaptureStep) -> Int { attemptCounts[step] ?? 0 }

    public func positioned() {
        guard case .positioning(let step) = state else { return }
        state = .recording(step, attempt: attempts(for: step) + 1)
    }

    public func stepRecorded(duration: Double) {
        guard case .recording(let step, let attempt) = state else { return }
        attemptCounts[step] = attempt
        let minimum = config(for: step)?.minimumSeconds ?? 0
        state = .reviewingStep(step, attempt: attempt)
        if duration < minimum {
            verdict(.recapture([.dsQG004]))
        }
    }

    /// Discards the partial recording; the attempt is not consumed.
    public func interrupted() {
        guard case .recording(let step, _) = state else { return }
        state = .positioning(step)
    }

    public func verdict(_ v: StepVerdict) {
        guard case .reviewingStep(let step, let attempt) = state else { return }
        switch v {
        case .accept:
            attemptLog.append(AttemptRecord(step: step, attempt: attempt, verdict: v))
            lastReasons[step] = nil
            acceptedSteps.append(step)
            advance()
        case .recapture(let reasons):
            lastReasons[step] = reasons
            if attempt <= captureProtocol.maxRecapturesPerStep {
                attemptLog.append(AttemptRecord(step: step, attempt: attempt, verdict: v))
                state = .positioning(step)
            } else {
                verdict(.unableToAcquire(reasons))
            }
        case .unableToAcquire(let reasons):
            attemptLog.append(AttemptRecord(step: step, attempt: attempt, verdict: v))
            lastReasons[step] = reasons
            failedSteps.append(step)
            advance()
        }
    }

    private func config(for step: CaptureStep) -> StepConfig? {
        captureProtocol.steps.first { $0.step == step }
    }

    private func advance() {
        index += 1
        if index < captureProtocol.steps.count {
            state = .positioning(captureProtocol.steps[index].step)
            return
        }
        let failedCore = captureProtocol.steps
            .filter { $0.isCore && failedSteps.contains($0.step) }.map { $0.step }
        let acceptedCore = captureProtocol.steps
            .contains { $0.isCore && acceptedSteps.contains($0.step) }
        if failedCore.isEmpty {
            state = .completed(.accepted)
        } else if acceptedCore {
            state = .completed(.partial(failedCore: failedCore))
        } else {
            state = .completed(.acquisitionFailure)
        }
    }
}
