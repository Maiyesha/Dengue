import Foundation

/// One video frame's ROI colour statistics, taken from the uncompressed camera buffer (before HEVC).
///
/// A frame without a usable ROI (no face for more than `FaceROITracker.holdSeconds`, or an empty ROI) stays in the
/// trace with `roiValid == false` and zero means, so frame timing remains complete; the quality gate excludes it
/// from the pulse check and counts it towards DS_QG_003.
public struct FrameSample: Codable, Equatable {
    /// Presentation timestamp, seconds.
    public var pts: Double
    /// Channel means over the ROI pixels, 0-255.
    public var meanR: Double, meanG: Double, meanB: Double
    /// Population standard deviation of BT.601 luma over the ROI pixels.
    public var lumaStdDev: Double
    /// Fraction of ROI pixels whose red channel is saturated (== 255).
    public var fractionRClipped: Double
    /// False when the frame had no usable ROI (encoded as `roi_valid`; absent in older traces means true).
    public var roiValid: Bool

    public init(pts: Double, meanR: Double, meanG: Double, meanB: Double, lumaStdDev: Double, fractionRClipped: Double,
                roiValid: Bool = true) {
        self.pts = pts; self.meanR = meanR; self.meanG = meanG; self.meanB = meanB
        self.lumaStdDev = lumaStdDev; self.fractionRClipped = fractionRClipped; self.roiValid = roiValid
    }

    /// A frame with no usable ROI.
    public static func invalid(pts: Double) -> FrameSample {
        FrameSample(pts: pts, meanR: 0, meanG: 0, meanB: 0, lumaStdDev: 0, fractionRClipped: 0, roiValid: false)
    }

    enum CodingKeys: String, CodingKey {
        case pts, meanR = "mean_r", meanG = "mean_g", meanB = "mean_b"
        case lumaStdDev = "luma_std", fractionRClipped = "frac_r_clipped", roiValid = "roi_valid"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pts = try c.decode(Double.self, forKey: .pts)
        meanR = try c.decode(Double.self, forKey: .meanR)
        meanG = try c.decode(Double.self, forKey: .meanG)
        meanB = try c.decode(Double.self, forKey: .meanB)
        lumaStdDev = try c.decode(Double.self, forKey: .lumaStdDev)
        fractionRClipped = try c.decode(Double.self, forKey: .fractionRClipped)
        roiValid = try c.decodeIfPresent(Bool.self, forKey: .roiValid) ?? true
    }

    public var stats: FrameStats {
        FrameStats(meanR: meanR, meanG: meanG, meanB: meanB, lumaStdDev: lumaStdDev, fractionRClipped: fractionRClipped)
    }
}

/// Builds `FrameSample`s from ROI pixels. The app passes the forehead/cheek ROI pixels for the face step and the
/// (sub-sampled) full frame for the fingertip step.
public enum ROITraceBuilder {
    /// Red values at or above this count as clipped.
    public static let clipLevel: UInt8 = 255

    public static func faceSample(pixels: some Collection<(r: UInt8, g: UInt8, b: UInt8)>, pts: Double) -> FrameSample {
        sample(pixels, pts: pts)
    }

    public static func fingertipSample(pixels: some Collection<(r: UInt8, g: UInt8, b: UInt8)>, pts: Double) -> FrameSample {
        sample(pixels, pts: pts)
    }

    /// One pass: channel sums, luma sum and sum of squares (BT.601: Y = 0.299 R + 0.587 G + 0.114 B), clip count.
    static func sample(_ pixels: some Collection<(r: UInt8, g: UInt8, b: UInt8)>, pts: Double) -> FrameSample {
        var n = 0
        var sr = 0, sg = 0, sb = 0, clipped = 0
        var sy = 0.0, syy = 0.0
        for p in pixels {
            n += 1
            sr += Int(p.r); sg += Int(p.g); sb += Int(p.b)
            if p.r >= clipLevel { clipped += 1 }
            let y = 0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)
            sy += y; syy += y * y
        }
        guard n > 0 else { return .invalid(pts: pts) }
        let d = Double(n)
        let my = sy / d
        let variance = max(0, syy / d - my * my)
        return FrameSample(pts: pts, meanR: Double(sr) / d, meanG: Double(sg) / d, meanB: Double(sb) / d,
                           lumaStdDev: variance.squareRoot(), fractionRClipped: Double(clipped) / d)
    }
}

/// Keeps the last good face ROI rects across missed detections for up to `holdSeconds`.
public struct FaceROITracker {
    public static let holdSeconds = 1.5
    private var last: [PixelRect] = []
    private var lastGoodAt: Double?

    public init() {}

    /// A detection result at `pts`; empty means the face was missed (the previous rects are kept).
    public mutating func detected(_ rects: [PixelRect], at pts: Double) {
        guard !rects.isEmpty else { return }
        last = rects
        lastGoodAt = pts
    }

    /// The rects to use at `pts`, or nil when there was no good detection within `holdSeconds`.
    public func rects(at pts: Double) -> [PixelRect]? {
        guard let t = lastGoodAt, pts - t <= Self.holdSeconds + 1e-9 else { return nil }
        return last
    }
}

/// Integer pixel rectangle, top-left origin.
public struct PixelRect: Equatable, Codable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Forehead and cheek regions derived from a face bounding box (top-left origin, pixels).
public enum FaceROI {
    /// Forehead: middle 50% of the face width, 10-25% of its height from the top.
    /// Cheeks: 15-40% and 60-85% of the width, 50-70% of the height. All clipped to the image.
    public static func rects(faceBox f: PixelRect, imageWidth: Int, imageHeight: Int) -> [PixelRect] {
        func r(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> PixelRect {
            let fx = Double(f.width), fy = Double(f.height)
            let left = max(0, f.x + Int((x0 * fx).rounded()))
            let top = max(0, f.y + Int((y0 * fy).rounded()))
            let right = min(imageWidth, f.x + Int((x1 * fx).rounded()))
            let bottom = min(imageHeight, f.y + Int((y1 * fy).rounded()))
            return PixelRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        }
        return [r(0.25, 0.75, 0.10, 0.25), r(0.15, 0.40, 0.50, 0.70), r(0.60, 0.85, 0.50, 0.70)]
            .filter { $0.width > 0 && $0.height > 0 }
    }
}

/// Read-only view of the pixels of a locked 32BGRA buffer inside `rects`, every `step`-th pixel in x and y.
/// Valid only while `base` is valid (i.e. between CVPixelBufferLock/UnlockBaseAddress).
public struct BGRAPixelRegion: RandomAccessCollection {
    public typealias Element = (r: UInt8, g: UInt8, b: UInt8)
    private let base: UnsafeRawBufferPointer
    private let bytesPerRow: Int
    private let step: Int
    /// Clipped rects with their sampled column/row counts and the running start index.
    private let spans: [(rect: PixelRect, cols: Int, rows: Int, start: Int)]
    public let startIndex = 0
    public let endIndex: Int

    public init(base: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, rects: [PixelRect], step: Int) {
        self.base = base
        self.bytesPerRow = bytesPerRow
        self.step = Swift.max(1, step)
        var spans: [(PixelRect, Int, Int, Int)] = []
        var total = 0
        for r in rects {
            let x0 = Swift.max(0, r.x), y0 = Swift.max(0, r.y)
            let x1 = Swift.min(width, r.x + r.width), y1 = Swift.min(height, r.y + r.height)
            guard x1 > x0, y1 > y0 else { continue }
            let cols = (x1 - x0 + self.step - 1) / self.step
            let rows = (y1 - y0 + self.step - 1) / self.step
            spans.append((PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cols, rows, total))
            total += cols * rows
        }
        self.spans = spans
        self.endIndex = total
    }

    public subscript(i: Int) -> Element {
        var s = spans[0]
        for candidate in spans where candidate.start <= i { s = candidate }
        let local = i - s.start
        let x = s.rect.x + (local % s.cols) * step
        let y = s.rect.y + (local / s.cols) * step
        let o = y * bytesPerRow + x * 4
        return (r: base[o + 2], g: base[o + 1], b: base[o])
    }
}

/// Lossless per-step ROI colour trace (uploaded as the `roi_trace` artefact).
public struct ROITrace: Codable, Equatable {
    public var step: CaptureStep
    /// Nominal frame rate the trace was recorded at.
    public var fps: Double
    public var samples: [FrameSample]

    public init(step: CaptureStep, fps: Double, samples: [FrameSample]) {
        self.step = step; self.fps = fps; self.samples = samples
    }

    public var rgb: [RGBSample] { samples.map { RGBSample(r: $0.meanR, g: $0.meanG, b: $0.meanB) } }
    public var timestamps: [Double] { samples.map { $0.pts } }
    /// RGB of the samples with a valid ROI only (pulse-check input).
    public var validRGB: [RGBSample] {
        samples.filter { $0.roiValid }.map { RGBSample(r: $0.meanR, g: $0.meanG, b: $0.meanB) }
    }
    /// Fraction of samples without a valid ROI (0 for an empty trace).
    public var invalidFraction: Double {
        samples.isEmpty ? 0 : Double(samples.filter { !$0.roiValid }.count) / Double(samples.count)
    }

    /// Per-field median over all samples (used for fingertip coverage).
    public var medianStats: FrameStats {
        func median(_ v: [Double]) -> Double {
            guard !v.isEmpty else { return 0 }
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        return FrameStats(meanR: median(samples.map { $0.meanR }), meanG: median(samples.map { $0.meanG }),
                          meanB: median(samples.map { $0.meanB }), lumaStdDev: median(samples.map { $0.lumaStdDev }),
                          fractionRClipped: median(samples.map { $0.fractionRClipped }))
    }

    /// Lossless JSON (doubles are written in shortest round-trip form; keys sorted).
    ///
    /// Size estimate: about 150-200 bytes per frame (six doubles of up to ~18 digits plus short keys), so a
    /// 45 s face step at 30 fps (1,350 frames) is ~0.25 MB and a full two-step session ~0.4 MB, well under the
    /// 2 MB/session budget even with every recapture attempt kept. Non-finite values cannot occur
    /// (means of UInt8 pixels), and would make encoding throw rather than lose data.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ROITrace {
        try JSONDecoder().decode(ROITrace.self, from: data)
    }
}

/// On-device provisional verdict for one recorded attempt. Order: frame timing (DS_QG_004, over all frames), ROI
/// occlusion (DS_QG_003 when more than 10% of frames have no valid ROI), pulse plausibility on the valid frames
/// only (face and fingertip), fingertip coverage (fingertip only, on the median FrameStats). Every failing reason is
/// collected; the first is the one shown to the nurse. No pulse rate is ever produced (spec section 8).
public struct StepQualityInput {
    public static let maxInvalidROIFraction = 0.10
    public var trace: ROITrace
    public var config: StepConfig

    public init(trace: ROITrace, config: StepConfig) { self.trace = trace; self.config = config }

    /// What the pulse gate sees: valid-ROI samples only.
    var pulseInput: [RGBSample] { trace.validRGB }

    public func verdict() -> StepVerdict {
        var reasons: [ReasonCode] = []
        let timing = FrameTimingQC.evaluate(timestamps: trace.timestamps, nominalFPS: trace.fps,
                                            minimumSeconds: config.minimumSeconds)
        if let r = timing.reason { reasons.append(r) }
        if trace.invalidFraction > Self.maxInvalidROIFraction { reasons.append(.dsQG003) }
        if config.step == .neutralFace || config.step == .fingertipPPG {
            let pulse = PulsePlausibility.evaluate(trace: pulseInput, fps: trace.fps)
            if let r = pulse.reason { reasons.append(r) }
        }
        if config.step == .fingertipPPG {
            let cover = FingertipCoverage.evaluate(trace.medianStats)
            if let r = cover.reason { reasons.append(r) }
        }
        return reasons.isEmpty ? .accept : .recapture(reasons)
    }
}

/// distance_cm / angle_deg / lighting_lux for the capture metadata: medians over the face-step observations.
/// Non-finite values and missing depth are ignored; a field is nil when nothing usable was observed.
public struct PositioningSummary: Codable, Equatable {
    public var distanceCm: Double?
    /// Median yaw, degrees.
    public var angleDeg: Double?
    public var lux: Double?

    public init(distanceCm: Double?, angleDeg: Double?, lux: Double?) {
        self.distanceCm = distanceCm; self.angleDeg = angleDeg; self.lux = lux
    }

    public static func from(_ obs: [FaceObservation]) -> PositioningSummary {
        PositioningSummary(distanceCm: median(obs.compactMap { $0.distanceCm }),
                           angleDeg: median(obs.map { $0.yawDeg }),
                           lux: median(obs.map { $0.estimatedLux }))
    }

    static func median(_ values: [Double]) -> Double? {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }
}

/// Provisional scene illuminance from the camera exposure (reflected-light meter equation).
///
/// L = K * N^2 / (t * S) * (Y_lin / 0.18), with K = 12.5 cd/m^2 and Y_lin the sRGB-linearised mean ROI luma;
/// E = pi * L / rho with an assumed reflectance rho = 0.18. An estimate for the >= 200 lx gate, not a lux meter.
public enum LuxEstimator {
    public static let k = 12.5
    public static let reflectance = 0.18

    public static func estimate(meanLuma: Double, exposureSeconds: Double, iso: Double, aperture: Double) -> Double? {
        guard meanLuma.isFinite, meanLuma > 0, exposureSeconds.isFinite, exposureSeconds > 0,
              iso.isFinite, iso > 0, aperture.isFinite, aperture > 0 else { return nil }
        let v = min(meanLuma, 255) / 255
        let linear = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        let luminance = k * aperture * aperture / (exposureSeconds * iso) * (linear / 0.18)
        return Double.pi * luminance / reflectance
    }
}

public extension CaptureMetadata {
    /// Applies measured positioning values (the fingertip step reuses the face step's summary).
    func withPositioning(_ s: PositioningSummary) -> CaptureMetadata {
        var m = self
        m.distanceCm = s.distanceCm; m.angleDeg = s.angleDeg; m.lux = s.lux
        return m
    }
}
