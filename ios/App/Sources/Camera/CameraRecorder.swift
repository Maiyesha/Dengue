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

/// Real AVFoundation recorder (Task 13).
///
/// - One `AVCaptureSession` (preset `.inputPriority`), video only: no audio input, no photo output.
/// - Front wide camera for the face step, rear wide camera + torch for the fingertip step. Settings are applied
///   and read back by the core `CameraConfigurator` (T9) on the session queue with the session running.
/// - `AVCaptureVideoDataOutput` delivers 32BGRA buffers on ONE serial queue. Each buffer is first reduced to an
///   ROI `FrameSample` (forehead/cheek rects from Vision for the face; sub-sampled full frame for the
///   fingertip) BEFORE compression, then appended to an `AVAssetWriter` (HEVC, average bit rate 25 Mb/s >= 20).
/// - Every attempt carries a `RecordingSession` token; samples, writer appends and ticks only happen while
///   that token is current, so a paused attempt can never write into a later one.
/// - The plaintext video is written into a Class B (`completeUnlessOpen`) directory excluded from backup.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class CameraRecorder: NSObject, CaptureCameraProviding, AVCaptureVideoDataOutputSampleBufferDelegate,
                            @unchecked Sendable {
    static let averageBitRate = 25_000_000
    static let exposureMs = 10.0              // 1/100 s: 50 Hz mains flicker
    static let faceDetectEveryNFrames = 15    // 0.5 s at 30 fps
    static let faceROIStride = 2
    static let fingertipStride = 4
    static let noFrameGraceSeconds = 10.0

    private let sessionQueue = DispatchQueue(label: "ai.reainmaker.denguecapture.camera.session")
    /// Serial: ROI extraction and writer appends for every frame.
    private let videoQueue = DispatchQueue(label: "ai.reainmaker.denguecapture.camera.video")
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureDirectory: URL

    // sessionQueue state
    private var role: CameraRole?
    private var device: AVCaptureDevice?
    private var outputAdded = false

    // videoQueue state
    private var active: ActiveRecording?

    private final class ActiveRecording {
        let rec: RecordingSession
        let token: UUID
        let seconds: Double
        let role: CameraRole
        let settings: AppliedCameraSettings
        let url: URL
        let onTick: (Double) -> Void
        var continuation: CheckedContinuation<StepRecording, Error>?
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var startPTS: CMTime?
        var width = 0, height = 0
        var frameIndex = 0
        var written = 0
        var faceRects: [PixelRect] = []

        init(rec: RecordingSession, seconds: Double, role: CameraRole, settings: AppliedCameraSettings, url: URL,
             onTick: @escaping (Double) -> Void, continuation: CheckedContinuation<StepRecording, Error>) {
            self.rec = rec; self.token = rec.token; self.seconds = seconds; self.role = role
            self.settings = settings; self.url = url; self.onTick = onTick; self.continuation = continuation
        }
    }

    override init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        var dir = base.appendingPathComponent("DengueSense/capture", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: dir.path)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        captureDirectory = dir
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
            self?.videoQueue.async { self?.failActive(RecorderError.interrupted) }
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.videoQueue.async { self?.failActive(RecorderError.interrupted) }
        }
    }

    // MARK: CaptureCameraProviding

    func record(_ rec: RecordingSession, seconds: Double,
                onTick: @escaping (Double) -> Void) async throws -> StepRecording {
        let role: CameraRole
        switch rec.step {
        case .neutralFace: role = .frontFace
        case .fingertipPPG: role = .rearFingertip
        case .ocularCapture, .dorsalTongue: throw RecorderError.unsupportedStep   // optional; off in Phase A
        }
        try await ensurePermission()
        let settings = try await configure(role: role)
        guard rec.isCurrent(token: rec.token) else { throw RecorderError.cancelled }   // paused while configuring
        let url = captureDirectory.appendingPathComponent("\(rec.token.uuidString.lowercased()).mov")
        try? FileManager.default.removeItem(at: url)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<StepRecording, Error>) in
            videoQueue.async { [self] in
                guard rec.isCurrent(token: rec.token) else { cont.resume(throwing: RecorderError.cancelled); return }
                failActive(RecorderError.cancelled)   // never two attempts at once
                let a = ActiveRecording(rec: rec, seconds: seconds, role: role, settings: settings, url: url,
                                        onTick: onTick, continuation: cont)
                active = a
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

    private func configure(role: CameraRole) async throws -> AppliedCameraSettings {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AppliedCameraSettings, Error>) in
            sessionQueue.async { [self] in
                do { cont.resume(returning: try configureOnSessionQueue(role: role)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func configureOnSessionQueue(role: CameraRole) throws -> AppliedCameraSettings {
        if self.role != role || device == nil {
            torchOff()
            let position: AVCaptureDevice.Position = role == .frontFace ? .front : .back
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                throw RecorderError.cameraUnavailable
            }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .inputPriority
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            for input in session.inputs { session.removeInput(input) }
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else { throw RecorderError.cameraUnavailable }
            session.addInput(input)
            if !outputAdded {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = false
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                guard session.canAddOutput(videoOutput) else { throw RecorderError.cameraUnavailable }
                session.addOutput(videoOutput)
                outputAdded = true
            }
            try selectFormat(dev)
            if let conn = videoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90   // portrait buffers (Vision + ROI in upright coordinates)
            }
            device = dev
            self.role = role
        }
        if !session.isRunning { session.startRunning() }
        guard let dev = device else { throw RecorderError.cameraUnavailable }
        // T9: must run here (session queue, session running, preset .inputPriority); reads every value back.
        let control = AVCaptureDeviceControl(device: dev, connection: videoOutput.connection(with: .video))
        do {
            return try CameraConfigurator().configure(control, role: role, preferExposureMs: Self.exposureMs)
        } catch {
            throw RecorderError.notReady(String(describing: error))
        }
    }

    /// 1920x1080 at 30 fps, preferring full-range 420 (the output converts to BGRA); sRGB colour space (no HLG).
    private func selectFormat(_ dev: AVCaptureDevice) throws {
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        let pick = candidates.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        } ?? candidates.first
        guard let format = pick else { throw RecorderError.notReady("format") }
        try dev.lockForConfiguration()
        defer { dev.unlockForConfiguration() }
        dev.activeFormat = format
        if format.supportedColorSpaces.contains(.sRGB) { dev.activeColorSpace = .sRGB }
    }

    private func torchOff() {
        guard let dev = device, dev.hasTorch, dev.torchMode != .off else { return }
        if (try? dev.lockForConfiguration()) != nil {
            dev.torchMode = .off
            dev.unlockForConfiguration()
        }
    }

    // MARK: frames (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let a = active, a.rec.isCurrent(token: a.token),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)

        if a.writer == nil {
            do { try startWriter(a, width: width, height: height, at: pts) }
            catch { failActive(error); return }
        }
        guard let start = a.startPTS else { return }

        // 1. ROI sample from the uncompressed buffer (before HEVC).
        if a.role == .frontFace, a.frameIndex % Self.faceDetectEveryNFrames == 0 {
            a.faceRects = detectFaceRects(pixels, width: width, height: height)
        }
        a.frameIndex += 1
        let seconds = CMTimeGetSeconds(pts)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
            let raw = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
            let sample: FrameSample
            if a.role == .frontFace {
                let region = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                             rects: a.faceRects, step: Self.faceROIStride)
                sample = ROITraceBuilder.faceSample(pixels: region, pts: seconds)
            } else {
                let region = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                             rects: [PixelRect(x: 0, y: 0, width: width, height: height)],
                                             step: Self.fingertipStride)
                sample = ROITraceBuilder.fingertipSample(pixels: region, pts: seconds)
            }
            a.rec.accept(sample: sample)
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)

        // 2. Compressed video.
        if let input = a.input, input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            a.written += 1
        }

        // 3. ~1 Hz tick (monitor-HR prompt), then stop once the target window is covered.
        if let e = a.rec.tickDue() { a.onTick(e) }
        if CMTimeGetSeconds(CMTimeSubtract(pts, start)) >= a.seconds {
            finishActive(a)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Dropped frames simply leave a gap in the trace timestamps; FrameTimingQC judges them.
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
            throw RecorderError.writerFailed(writer.error.map { String(describing: $0) } ?? "startWriting")
        }
        writer.startSession(atSourceTime: pts)
        a.writer = writer; a.input = input; a.startPTS = pts
        a.width = width; a.height = height
    }

    /// Largest face -> forehead + cheek rects (top-left pixel coordinates). No face -> no ROI (zero sample).
    private func detectFaceRects(_ pixels: CVPixelBuffer, width: Int, height: Int) -> [PixelRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                                    < $1.boundingBox.width * $1.boundingBox.height }) else { return [] }
        let bb = face.boundingBox   // normalised, bottom-left origin
        let box = PixelRect(x: Int(bb.minX * CGFloat(width)), y: Int((1 - bb.maxY) * CGFloat(height)),
                            width: Int(bb.width * CGFloat(width)), height: Int(bb.height * CGFloat(height)))
        return FaceROI.rects(faceBox: box, imageWidth: width, imageHeight: height)
    }

    private func finishActive(_ a: ActiveRecording) {
        active = nil
        let trace = a.rec.finish()
        guard let writer = a.writer, let input = a.input, let cont = a.continuation else { return }
        a.continuation = nil
        input.markAsFinished()
        let role = a.role
        writer.finishWriting { [weak self] in
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: a.url)
                cont.resume(throwing: RecorderError.writerFailed(writer.error.map { String(describing: $0) } ?? "finish"))
                return
            }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                                   ofItemAtPath: a.url.path)
            let duration = (trace.timestamps.last ?? 0) - (trace.timestamps.first ?? 0)
            let metadata = CaptureMetadata(
                deviceModel: Self.deviceModel(), step: a.rec.step, attempt: a.rec.attempt, cameraRole: role,
                fps: a.settings.fps, resolution: "\(a.width)x\(a.height)", exposureDurationMs: a.settings.exposureMs,
                iso: a.settings.iso, torchLevel: a.settings.torch,
                distanceCm: nil, angleDeg: nil, lux: nil,          // no positioning pipeline wired yet
                mount: "holder",                                   // checklist item "holder fitted" is mandatory
                lightingType: "overhead",                          // checklist item "overhead light on" is mandatory
                ambientTempC: nil, ambientHumidityPct: nil,        // no entry UI yet
                durationSeconds: duration, frameCount: trace.samples.count,
                videoCodec: "hevc", videoAverageBitRate: Self.averageBitRate)
            if role == .rearFingertip { self?.sessionQueue.async { self?.torchOff() } }
            cont.resume(returning: StepRecording(token: a.token, step: a.rec.step, attempt: a.rec.attempt,
                                                 trace: trace, duration: duration, videoURL: a.url,
                                                 metadata: metadata))
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
