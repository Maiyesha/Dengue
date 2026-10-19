import Foundation

/// Mirrors GET /v1/scans/:id/experimental.
public struct ExperimentalResponse: Decodable, Equatable {
    public enum Domain: String, Decodable, Equatable {
        case rppgFace = "rppg_face"
        case rppgFingertip = "rppg_fingertip"
    }

    public struct Item: Decodable, Equatable {
        public var domain: Domain
        /// The API sends a whole number; Double is accepted so the presenter rounds defensively.
        public var pulseRateBpm: Double
        public var label: String
        public var notice: String

        public init(domain: Domain, pulseRateBpm: Double,
                    label: String = NurseCopy.experimentalChip,
                    notice: String = NurseCopy.experimentalNotice) {
            self.domain = domain
            self.pulseRateBpm = pulseRateBpm
            self.label = label
            self.notice = notice
        }

        enum CodingKeys: String, CodingKey {
            case domain, label, notice
            case pulseRateBpm = "pulse_rate_bpm"
        }
    }

    public var enabled: Bool
    public var items: [Item]

    public init(enabled: Bool, items: [Item]) {
        self.enabled = enabled
        self.items = items
    }
}

public struct ExperimentalPulseView: Equatable {
    public let label: String
    public let text: String
    public let notice: String
}

public enum ExperimentalPulsePresenter {
    /// Monitor value first; experimental values only when enabled. The notice is always the policy text.
    public static func present(_ r: ExperimentalResponse, monitorHR: Int?)
        -> (monitor: String?, experimental: [ExperimentalPulseView]) {
        let monitor = monitorHR.map { NurseCopy.monitorLine($0) }
        guard r.enabled else { return (monitor, []) }
        let views: [ExperimentalPulseView] = r.items.compactMap { item in
            guard item.pulseRateBpm.isFinite, abs(item.pulseRateBpm) < 1000 else { return nil }
            let bpm = Int(item.pulseRateBpm.rounded())
            guard (20...300).contains(bpm) else { return nil }
            return ExperimentalPulseView(
                label: NurseCopy.experimentalChip,
                text: NurseCopy.cameraPulseLine(fingertip: item.domain == .rppgFingertip, bpm: bpm),
                notice: NurseCopy.experimentalNotice)
        }
        return (monitor, views)
    }
}
