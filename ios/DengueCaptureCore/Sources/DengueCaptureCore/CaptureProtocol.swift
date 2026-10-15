public enum CaptureStep: String, Codable, Equatable {
    case neutralFace = "neutral_face"
    case fingertipPPG = "fingertip_ppg"
    case ocularCapture = "ocular_capture"
    case dorsalTongue = "dorsal_tongue"
}

public struct StepConfig: Codable, Equatable {
    public var step: CaptureStep
    public var isCore: Bool
    public var targetSeconds: Double
    public var minimumSeconds: Double

    public init(step: CaptureStep, isCore: Bool, targetSeconds: Double, minimumSeconds: Double) {
        self.step = step
        self.isCore = isCore
        self.targetSeconds = targetSeconds
        self.minimumSeconds = minimumSeconds
    }
}

public struct CaptureProtocol: Codable, Equatable {
    public var version: String
    public var steps: [StepConfig]
    public var maxRecapturesPerStep: Int
    public var showExperimentalAtBedside: Bool

    public init(version: String, steps: [StepConfig], maxRecapturesPerStep: Int = 2,
                showExperimentalAtBedside: Bool = false) {
        self.version = version
        self.steps = steps
        self.maxRecapturesPerStep = maxRecapturesPerStep
        self.showExperimentalAtBedside = showExperimentalAtBedside
    }

    /// Phase A: core steps only. Optional steps are disabled by default.
    public static let phaseADefault = CaptureProtocol(
        version: "phase-a-1",
        steps: [
            StepConfig(step: .neutralFace, isCore: true, targetSeconds: 40, minimumSeconds: 30),
            StepConfig(step: .fingertipPPG, isCore: true, targetSeconds: 30, minimumSeconds: 30),
        ],
        maxRecapturesPerStep: 2,
        showExperimentalAtBedside: false)
}

extension CaptureProtocol {
    /// I2: a server-requested repeat records only `steps` (same durations and recapture rules as Phase A).
    public static func repeatProtocol(steps: [CaptureStepName], base: CaptureProtocol = .phaseADefault) -> CaptureProtocol {
        let wanted = Set(steps.map { $0.rawValue })
        return CaptureProtocol(version: base.version, steps: base.steps.filter { wanted.contains($0.step.rawValue) },
                               maxRecapturesPerStep: base.maxRecapturesPerStep,
                               showExperimentalAtBedside: base.showExperimentalAtBedside)
    }
}
