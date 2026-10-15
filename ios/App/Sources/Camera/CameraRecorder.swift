#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Vision
import Foundation
import DengueCaptureCore

enum RecorderError: Error {
    case permissionDenied
    case cameraUnavailable
    case unsupportedStep
    case notReady(String)
    case writerFailed(String)
    case noFrames
    case interrupted
    case cancelled
}

/// Real AVFoundation recorder (Task 13, fix round 1).
///
/// - One `AVCaptureSession` (preset `.inputPriority`), video only: no audio input, no photo output.
/// - Face step: front TrueDepth camera when present (depth output for distance), otherwise front wide camera.
///   Fingertip step: rear wide camera + torch. Settings applied and read back by the core `CameraConfigurator`
///   on the session queue with the session running.
/// - `AVCaptureVideoDataOutput` delivers 32BGRA on ONE serial queue. Each buffer is reduced to an ROI
///   `FrameSample` BEFORE compression (face: forehead/cheek rects from Vision, last good rects held for
///   `FaceROITracker.holdSeconds`, then `roiValid = false` samples; fingertip: sub-sampled full frame), then
///   appended to an `AVAssetWriter` (HEVC, average bit rate 25 Mb/s >= 20).
/// - Face-step `FaceObservation`s (Vision yaw/pitch/roll, TrueDepth distance, exposure-based lux) are summarised
///   into the metadata's distance_cm / angle_deg / lighting_lux; the fingertip step reuses the face summary.
/// - Every attempt carries a `RecordingSession` token; samples, appends and ticks happen only while it is current.
/// - Plaintext goes to `CaptureStorage.captureDirectory` (Class B, verified) or recording is refused.
/// - Sealing starts in the `finishWriting` completion (`StepRecording.sealing`).
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class CameraRecorder: NSObject, CaptureCameraProviding, AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    static let averageBitRate = 25_000_000
    static let exposureMs = 10.0              // 1/100 s: 50 Hz mains flicker
    static let faceDetectEveryNFrames = 15    // 0.5 s at 30 fps
    static let faceROIStride = 2
    static let fingertipStride = 4
    static let noFrameGraceSeconds = 10.0
    static let rotationDegrees = 90           // portrait buffers

    private let sessionQueue = DispatchQueue(label: "ai.reainmaker.denguecapture.camera.session")
    /// Serial: ROI extraction, depth sampling and writer appends.
    private let videoQueue = DispatchQueue(label: "ai.reainmaker.denguecapture.camera.video")
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()

    // sessionQueue state
    private var role: CameraRole?
    private var device: AVCaptureDevice?
    private var videoOutputAdded = false
    private var depthOutputAdded = false

    // videoQueue state
    private var active: ActiveRecording?
    private var latestDepth: AVDepthData?

    private struct Configured {
        let settings: AppliedCameraSettings
        let aperture: Double
    }

    private final class ActiveRecording {
        let rec: RecordingSession
        let token: UUID
        let seconds: Double
        let role: CameraRole
        let configured: Configured
        let url: URL
        let storage: CaptureStorage
        /// Face summary to reuse (fingertip step).
        let positioning: PositioningSummary?
        let onTick: (Double) -> Void
        var continuation: CheckedContinuation<StepRecording, Error>?
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var startPTS: CMTime?
        var width = 0, height = 0
        var frameIndex = 0
        var tracker = FaceROITracker()
        var observations: [FaceObservation] = []
        var lastValidLuma: Double?

        init(rec: RecordingSession, seconds: Double, role: CameraRole, configured: Configured, url: URL,
             storage: CaptureStorage, positioning: PositioningSummary?, onTick: @escaping (Double) -> Void,
             continuation: CheckedContinuation<StepRecording, Error>) {
            self.rec = rec; self.token = rec.token; self.seconds = seconds; self.role = role
            self.configured = configured; self.url = url; self.storage = storage; self.positioning = positioning
            self.onTick = onTick; self.continuation = continuation
        }
    }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
            self?.videoQueue.async { self?.failActive(RecorderError.interrupted) }
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.videoQueue.async { self?.failActive(RecorderError.interrupted) }
        }
    }

    /// T13 ruling: capture needs a front TrueDepth camera with a depth-capable 1080p30 format (distance_cm).
    /// Checked at capture-screen entry and fed into `Preflight.supportsDepthCapture`.
    static func supportsDepthCapture() -> Bool {
        guard let dev = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else { return false }
        return dev.formats.contains { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080 && !f.supportedDepthDataFormats.isEmpty
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
    }

    // MARK: CaptureCameraProviding

    func record(_ rec: RecordingSession, seconds: Double, positioning: PositioningSummary?,
                onTick: @escaping (Double) -> Void) async throws -> StepRecording {
        let role: CameraRole
        switch rec.step {
        case .neutralFace: role = .frontFace
        case .fingertipPPG: role = .rearFingertip
        case .ocularCapture, .dorsalTongue: throw RecorderError.unsupportedStep   // optional; off in Phase A
        }
        // Class B capture directory or no recording at all (no fallback location).
        guard let storage = CaptureStorage.shared else { throw RecorderError.notReady("captureStorage") }
        try await ensurePermission()
        let configured = try await configure(role: role)
        guard rec.isCurrent(token: rec.token) else { throw RecorderError.cancelled }   // paused while configuring
        let url = storage.captureDirectory.appendingPathComponent("\(rec.token.uuidString.lowercased()).mov")
        try? FileManager.default.removeItem(at: url)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<StepRecording, Error>) in
            videoQueue.async { [self] in
                guard rec.isCurrent(token: rec.token) else { cont.resume(throwing: RecorderError.cancelled); return }
                failActive(RecorderError.cancelled)   // never two attempts at once
                let a = ActiveRecording(rec: rec, seconds: seconds, role: role, configured: configured, url: url,
                                        storage: storage, positioning: positioning, onTick: onTick,
                                        continuation: cont)
                active = a
                latestDepth = nil
                videoQueue.asyncAfter(deadline: .now() + seconds + Self.noFrameGraceSeconds) { [weak self] in
                    guard let self, let cur = self.active, cur.token == a.token else { return }
                    self.failActive(cur.startPTS == nil ? RecorderError.noFrames : RecorderError.writerFailed("timeout"))
                }
            }
        }
    }

    /// Pause / interruption: discards the partial recording of exactly this attempt.
    func cancel(_ rec: RecordingSession) {
        rec.finish()
        videoQueue.async { [self] in
            guard let a = active, a.token == rec.token else { return }
            failActive(RecorderError.cancelled)
        }
    }

    func stop() {
        videoQueue.async { [self] in failActive(RecorderError.cancelled) }
        sessionQueue.async { [self] in
            torchOff()
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: setup (sessionQueue)

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
            throw RecorderError.permissionDenied
        default: throw RecorderError.permissionDenied
        }
    }

    private func configure(role: CameraRole) async throws -> Configured {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Configured, Error>) in
            sessionQueue.async { [self] in
                do { cont.resume(returning: try configureOnSessionQueue(role: role)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func configureOnSessionQueue(role: CameraRole) throws -> Configured {
        if self.role != role || device == nil {
            torchOff()
            let dev: AVCaptureDevice?
            if role == .frontFace {
                // Devices without TrueDepth are blocked before capture (Preflight.supportsDepthCapture).
                dev = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            } else {
                dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
            guard let dev else { throw RecorderError.cameraUnavailable }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            for input in session.inputs { session.removeInput(input) }
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else { throw RecorderError.cameraUnavailable }
            session.addInput(input)
            if !videoOutputAdded {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = false
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                guard session.canAddOutput(videoOutput) else { throw RecorderError.cameraUnavailable }
                session.addOutput(videoOutput)
                videoOutputAdded = true
            }
            let wantsDepth = role == .frontFace && dev.deviceType == .builtInTrueDepthCamera
            if wantsDepth, !depthOutputAdded, session.canAddOutput(depthOutput) {
                depthOutput.isFilteringEnabled = true
                depthOutput.alwaysDiscardsLateDepthData = true
                depthOutput.setDelegate(self, callbackQueue: videoQueue)
                session.addOutput(depthOutput)
                depthOutputAdded = true
            } else if !wantsDepth, depthOutputAdded {
                session.removeOutput(depthOutput)
                depthOutputAdded = false
            }
            try selectFormat(dev, wantsDepth: wantsDepth)
            if let conn = videoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(CGFloat(Self.rotationDegrees)) {
                conn.videoRotationAngle = CGFloat(Self.rotationDegrees)   // portrait buffers for Vision + ROI
            }
            device = dev
            self.role = role
        }
        if !session.isRunning { session.startRunning() }
        guard let dev = device else { throw RecorderError.cameraUnavailable }
        let control = AVCaptureDeviceControl(device: dev, connection: videoOutput.connection(with: .video))
        do {
            let settings = try CameraConfigurator().configure(control, role: role, preferExposureMs: Self.exposureMs)
            return Configured(settings: settings, aperture: Double(dev.lensAperture))
        } catch {
            throw RecorderError.notReady(String(describing: error))
        }
    }

    /// 1920x1080 at 30 fps, preferring formats with depth (TrueDepth face) and full-range 420; sRGB (no HLG).
    private func selectFormat(_ dev: AVCaptureDevice, wantsDepth: Bool) throws {
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            if wantsDepth && !f.supportedDepthDataFormats.isEmpty { s += 2 }
            if CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { s += 1 }
            return s
        }
        guard let format = candidates.max(by: { score($0) < score($1) }) else { throw RecorderError.notReady("format") }
        try dev.lockForConfiguration()
        defer { dev.unlockForConfiguration() }
        dev.activeFormat = format
        if format.supportedColorSpaces.contains(.sRGB) { dev.activeColorSpace = .sRGB }
        if wantsDepth {
            let depthFormats = format.supportedDepthDataFormats.filter {
                let t = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return t == kCVPixelFormatType_DepthFloat32 || t == kCVPixelFormatType_DepthFloat16
            }
            if let best = depthFormats.max(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                    < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }) {
                dev.activeDepthDataFormat = best
            }
        }
    }

    private func torchOff() {
        guard let dev = device, dev.hasTorch, dev.torchMode != .off else { return }
        if (try? dev.lockForConfiguration()) != nil {
            dev.torchMode = .off
            dev.unlockForConfiguration()
        }
    }

    // MARK: depth (videoQueue)

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        latestDepth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    /// Median depth (cm) in a 5x5 patch at a normalised point of the ROTATED video frame.
    private func depthCm(atRotatedU u: Double, v: Double) -> Double? {
        guard let depth = latestDepth else { return nil }
        let map = depth.depthDataMap
        let p = SensorGeometry.sensorPoint(rotatedU: u, rotatedV: v, rotationDegrees: Self.rotationDegrees)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
        var values: [Float] = []
        for y in max(0, cy - 2)...min(h - 1, cy + 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in max(0, cx - 2)...min(w - 1, cx + 2) { values.append(row[x]) }
        }
        return SensorGeometry.medianDepthCm(meters: values)
    }

    // MARK: frames (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput, let a = active, a.rec.isCurrent(token: a.token),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)

        if a.writer == nil {
            do { try startWriter(a, width: width, height: height, at: pts) }
            catch { failActive(error); return }
        }
        guard let start = a.startPTS else { return }
        let seconds = CMTimeGetSeconds(pts)

        // 1. Face detection (every 15th frame) -> ROI tracker + positioning observation.
        if a.role == .frontFace, a.frameIndex % Self.faceDetectEveryNFrames == 0 {
            let face = detectFace(pixels, width: width, height: height)
            a.tracker.detected(face?.rects ?? [], at: seconds)
            if let face { a.observations.append(observation(face, a)) }
        }
        a.frameIndex += 1

        // 2. ROI sample from the uncompressed buffer (before HEVC).
        let sample: FrameSample
        if a.role == .frontFace, a.tracker.rects(at: seconds) == nil {
            sample = .invalid(pts: seconds)   // no face for > 1.5 s
        } else {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
                let raw = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
                if a.role == .frontFace {
                    let region = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                                 rects: a.tracker.rects(at: seconds) ?? [], step: Self.faceROIStride)
                    sample = ROITraceBuilder.faceSample(pixels: region, pts: seconds)
                } else {
                    let region = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                                 rects: [PixelRect(x: 0, y: 0, width: width, height: height)],
                                                 step: Self.fingertipStride)
                    sample = ROITraceBuilder.fingertipSample(pixels: region, pts: seconds)
                }
            } else {
                sample = .invalid(pts: seconds)
            }
        }
        if sample.roiValid {
            a.lastValidLuma = 0.299 * sample.meanR + 0.587 * sample.meanG + 0.114 * sample.meanB
        }
        a.rec.accept(sample: sample)

        // 3. Compressed video.
        if let input = a.input, input.isReadyForMoreMediaData { _ = input.append(sampleBuffer) }

        // 4. ~1 Hz tick (monitor-HR prompt), then stop once the target window is covered.
        if let e = a.rec.tickDue() { a.onTick(e) }
        if CMTimeGetSeconds(CMTimeSubtract(pts, start)) >= a.seconds {
            finishActive(a)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // A dropped frame leaves a gap in the trace timestamps; FrameTimingQC judges it.
    }

    private func startWriter(_ a: ActiveRecording, width: Int, height: Int, at pts: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: a.url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.averageBitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("canAdd") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error.map { String(describing: type(of: $0)) } ?? "startWriting")
        }
        writer.startSession(atSourceTime: pts)
        a.writer = writer; a.input = input; a.startPTS = pts
        a.width = width; a.height = height
    }

    private struct DetectedFace {
        let rects: [PixelRect]
        let bbox: CGRect   // normalised, bottom-left origin
        let yawDeg: Double, pitchDeg: Double, rollDeg: Double
    }

    /// Largest face -> forehead + cheek rects (top-left pixel coordinates) and head pose. nil = missed.
    private func detectFace(_ pixels: CVPixelBuffer, width: Int, height: Int) -> DetectedFace? {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3   // yaw, pitch, roll
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                                    < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let bb = face.boundingBox
        let box = PixelRect(x: Int(bb.minX * CGFloat(width)), y: Int((1 - bb.maxY) * CGFloat(height)),
                            width: Int(bb.width * CGFloat(width)), height: Int(bb.height * CGFloat(height)))
        let rects = FaceROI.rects(faceBox: box, imageWidth: width, imageHeight: height)
        guard !rects.isEmpty else { return nil }
        func deg(_ n: NSNumber?) -> Double { n.map { $0.doubleValue * 180 / .pi } ?? .nan }
        return DetectedFace(rects: rects, bbox: bb, yawDeg: deg(face.yaw), pitchDeg: deg(face.pitch),
                            rollDeg: deg(face.roll))
    }

    private func observation(_ f: DetectedFace, _ a: ActiveRecording) -> FaceObservation {
        let u = Double(f.bbox.midX), v = 1 - Double(f.bbox.midY)   // top-left origin
        let lux = a.lastValidLuma.flatMap {
            LuxEstimator.estimate(meanLuma: $0, exposureSeconds: a.configured.settings.exposureMs / 1000,
                                  iso: Double(a.configured.settings.iso), aperture: a.configured.aperture)
        } ?? .nan
        return FaceObservation(yawDeg: f.yawDeg, pitchDeg: f.pitchDeg, rollDeg: f.rollDeg,
                               faceWidthFraction: Double(f.bbox.width), distanceCm: depthCm(atRotatedU: u, v: v),
                               estimatedLux: lux, landmarkJitter: 0)
    }

    private func finishActive(_ a: ActiveRecording) {
        active = nil
        let trace = a.rec.finish()
        guard let writer = a.writer, let input = a.input, let cont = a.continuation else { return }
        a.continuation = nil
        input.markAsFinished()
        let role = a.role
        let summary = role == .frontFace ? PositioningSummary.from(a.observations) : nil
        writer.finishWriting { [weak self] in
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: a.url)
                cont.resume(throwing: RecorderError.writerFailed(
                    writer.error.map { String(describing: type(of: $0)) } ?? "finish"))
                return
            }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                                   ofItemAtPath: a.url.path)
            let duration = (trace.timestamps.last ?? 0) - (trace.timestamps.first ?? 0)
            let s = a.configured.settings
            let positioning = summary ?? a.positioning ?? PositioningSummary(distanceCm: nil, angleDeg: nil, lux: nil)
            let metadata = CaptureMetadata(
                deviceModel: Self.deviceModel(), step: a.rec.step, attempt: a.rec.attempt, cameraRole: role,
                fps: s.fps, resolution: "\(a.width)x\(a.height)", exposureDurationMs: s.exposureMs,
                iso: s.iso, torchLevel: s.torch, distanceCm: nil, angleDeg: nil, lux: nil,
                mount: "holder",                                   // checklist item "holder fitted" is mandatory
                lightingType: "overhead",                          // checklist item "overhead light on" is mandatory
                ambientTempC: nil, ambientHumidityPct: nil,        // optional; no entry UI
                durationSeconds: duration, frameCount: trace.samples.count,
                videoCodec: "hevc", videoAverageBitRate: Self.averageBitRate).withPositioning(positioning)
            // Seal starts here, independently of the verdict (rejected attempts are destroyed afterwards).
            let rec = a.rec, url = a.url, storage = a.storage
            let sealing = Task.detached {
                await storage.seal(token: rec.token, step: rec.step, attempt: rec.attempt, video: url,
                                   trace: trace, metadata: metadata)
            }
            if role == .rearFingertip { self?.sessionQueue.async { self?.torchOff() } }
            cont.resume(returning: StepRecording(token: rec.token, step: rec.step, attempt: rec.attempt,
                                                 trace: trace, duration: duration, metadata: metadata,
                                                 positioning: summary, sealing: sealing))
        }
    }

    /// Ends the current attempt with `error`: partial video discarded, samples ignored from now on.
    private func failActive(_ error: Error) {
        guard let a = active else { return }
        active = nil
        a.rec.finish()
        a.writer?.cancelWriting()
        try? FileManager.default.removeItem(at: a.url)
        a.continuation?.resume(throwing: error)
        a.continuation = nil
        if a.role == .rearFingertip { sessionQueue.async { [weak self] in self?.torchOff() } }
    }

    static func deviceModel() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
