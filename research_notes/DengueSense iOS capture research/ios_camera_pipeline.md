# iOS Camera Capture Pipeline for rPPG and Facial/Ocular/Tongue Colour Imaging (beAIve DengueSense, RUO)

Scope note: Researched 2026-10-13. Apple doc pages were fetched directly where cited. Items marked **[unverified, from background knowledge]** were not confirmed against a fetched source in this session and should be checked by the engineer before relying on them. Arithmetic storage estimates are computed, not sourced.

## 1. Locking frame rate, exposure, white balance and focus; which cameras support it; auto-processing that corrupts rPPG/colour signals

### Takeaway
AVFoundation exposes everything needed for a fixed, signal-grade capture: frame rate is fixed by setting `activeVideoMinFrameDuration` = `activeVideoMaxFrameDuration` within the active format's `videoSupportedFrameRateRanges`. Exposure is fixed with `setExposureModeCustom(duration:iso:)`, white balance with `setWhiteBalanceModeLocked(with:)`, and focus with lens-position lock. Video HDR/EDR is on by default and must be turned off explicitly. Local adaptive tone mapping is the default and can be replaced by global tone mapping where the format supports it. Center Stage must be opted out of on supported front cameras. Every one of these settings can be reset by format/preset changes, so the module has to re-apply and verify them after configuration.

### Cited Findings
**Frame rate**
- `activeVideoMinFrameDuration` is the reciprocal of max frame rate. Setting a value not in the active format's `videoSupportedFrameRateRanges` raises `invalidArgumentException`. You must call `lockForConfiguration()` first. Choosing a new session preset resets it to the default. The property is KVO-observable. — [Apple: activeVideoMinFrameDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration)
- To get full manual control of the format, set the session preset to `.inputPriority` so the session does not auto-configure inputs/outputs. Apple uses this pattern for ProRes. — [Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)

**Exposure**
- `setExposureModeCustom(duration:iso:completionHandler:)` "locks exposure duration and ISO at explicit values". It throws if values are outside supported ranges. **Changing the exposure duration "may result in changes to activeVideoMinFrameDuration or activeVideoMaxFrameDuration"**, so the exposure duration must be ≤ the frame duration (e.g. ≤ 1/30 s at 30 fps) or the frame rate will drift. — [Apple: setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))
- The completion handler returns the timestamp of the first buffer with the new settings applied, on the device clock. It must be converted to the session's `synchronizationClock` before comparing with `AVCaptureVideoDataOutput` buffer timestamps. This lets the module mark exactly which frame the lock became effective on. — [Apple: setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))
- If an `AVCapturePhotoOutput` is in the same session, the default `.balanced` photo quality prioritisation can temporarily override custom/locked exposure for multi-image fusion. Apple says to set `photoQualityPrioritization = .speed` to make the system honour locked values. Simpler: do not attach a photo output during rPPG capture. — [Apple: setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))

**White balance**
- `setWhiteBalanceModeLocked(with:completionHandler:)` locks WB to specified device gains (iOS 8+). Pass `currentWhiteBalanceGains` to freeze the current value. The completion handler timestamps follow the same device-clock rule as exposure. — [Apple: setWhiteBalanceModeLocked](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:))
- `isLockingWhiteBalanceWithCustomDeviceGainsSupported` must be checked. Each gain must be in [1.0, `maxWhiteBalanceGain`]. — [Apple: setWhiteBalanceModeLocked](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:)); [Microsoft .NET binding of AVCaptureDevice API listing](https://learn.microsoft.com/en-us/dotnet/api/avfoundation.avcapturedevice)
- **[unverified, from background knowledge]** AVCaptureDevice provides `temperatureAndTintValues(for:)` and `deviceWhiteBalanceGains(for:)` to convert between gains and CCT/tint, plus `grayWorldDeviceWhiteBalanceGains`. Together these give a practical way to meet the "±300 K of calibration" requirement. Calibrate against a grey card under the clinic's lighting, store the gains, re-apply them with `setWhiteBalanceModeLocked`, and log `temperatureAndTintValues(for: deviceWhiteBalanceGains)` per session. Note that gains are device-specific: "device gains" are not portable between phone models.

**Focus**
- **[unverified, from background knowledge]** `setFocusModeLocked(lensPosition:completionHandler:)` (lens position 0.0–1.0) locks focus. Check `isLockingFocusWithCustomLensPositionSupported`. The front TrueDepth camera on many iPhones was historically fixed-focus or had limited AF, so the module should gate on `isFocusModeSupported(.locked)`.
- `minimumFocusDistance` (iOS 15+) reports the closest sharp-focus distance. Apple cites 15 cm for the iPhone 12 Pro Max Wide camera vs 12 cm for the iPhone 12 Pro. This is relevant to close-range tongue/conjunctiva shots with the back camera, so use it to warn "too close". — [WWDC21 "What's new in camera capture" (10047)](https://developer.apple.com/wwdc21/10047)

**Video HDR / EDR**
- `automaticallyAdjustsVideoHDREnabled` defaults to true, and the device turns on `isVideoHDREnabled` (EDR) automatically when the format supports it. To disable it, set `automaticallyAdjustsVideoHDREnabled = false`, then `isVideoHDREnabled = false`. — [WWDC21 10047](https://developer.apple.com/wwdc21/10047); [Apple: automaticallyAdjustsVideoHDREnabled](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/automaticallyadjustsvideohdrenabled.md)

**Tone mapping**
- By default "the active camera uses adaptive, local tone curves… and adapt quickly to changing lighting conditions". With `isGlobalToneMappingEnabled = true`, a single tone map applies to all pixels. It can only be enabled if the active format's `isGlobalToneMappingSupported` is true. It **resets to false** when you change the active format, add the device input to a session, or change the session preset. KVO-observe it. (iOS 13+) — [Apple: isGlobalToneMappingEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isglobaltonemappingenabled)

**Center Stage (front ultra-wide on iPad and newer iPhones)**
- `AVCaptureDevice.isCenterStageEnabled` is a per-app class property. The default `centerStageControlMode = .user` throws if the app sets it. To opt out, set `centerStageControlMode = .app` and then `isCenterStageEnabled = false`. Apple discourages this except where Center Stage is incompatible, which digital pan/zoom cropping is for ROI tracking and pixel-scale stability. When active, Center Stage caps at 30 fps and 1920×1440 and locks zoom at 1. — [WWDC21 10047](https://developer.apple.com/wwdc21/10047)

**Portrait / video effects**
- Portrait (background blur) is user-controlled in Control Center, front camera only. Non-VoIP iOS apps get it **only if they add `NSCameraPortraitEffectEnabled` to Info.plist**. Do not add this key. Monitor `isPortraitEffectActive`. — [WWDC21 10047](https://developer.apple.com/wwdc21/10047)
- **[unverified, from background knowledge]** Later iOS releases added more Control-Center video effects (Studio Light, reactions/gestures in iOS 17, Background replacement in iOS 18). Studio Light brightens and relights the face, which would directly corrupt colour and rPPG. Like Portrait, these are gated by app opt-in Info.plist keys / `AVCaptureDevice.isStudioLightEnabled` / `reactionEffectsEnabled`. Verify that the app does not opt in, and log `isStudioLightActive` if the API exists on the target OS.

**Stabilisation**
- **[unverified, from background knowledge]** Video stabilisation is set per connection via `AVCaptureConnection.preferredVideoStabilizationMode`. Set it to `.off`, since cinematic/standard modes crop and warp frames and add latency. Deep Fusion, Smart HDR and Photographic Styles apply to still photo capture (AVCapturePhotoOutput) and the Camera app. They are not applied to `AVCaptureVideoDataOutput` buffers in a custom session. They matter only if a photo output is added. Photographic Styles (iOS 18 "Styles") are baked into Camera-app captures, so never use `UIImagePickerController` or the Camera app for research capture.

### Inferences
- Recommended lock sequence (once, after `session.beginConfiguration()`/`commitConfiguration()` and after the input is added, because several properties reset on input add / format change): preset `.inputPriority` → choose format → `activeFormat` → disable auto-HDR and HDR → global tone mapping if supported → min = max frame duration (1/30) → custom exposure (duration ≤ 1/30 s, e.g. 1/60–1/30 s; ISO chosen during a 1–2 s auto-exposure warm-up then frozen) → WB locked to calibrated gains → focus locked → stabilisation off → Center Stage off. Then **read back** every value and write it into session metadata. Abort or flag the capture if any read-back mismatches.
- Using exposure durations that are integer multiples of the mains-flicker half-period (1/100 s at 50 Hz in Bangladesh/India/SE Asia, 1/120 s at 60 Hz) reduces fluorescent/LED flicker aliasing into the rPPG band. Standard practice, not sourced here.
- Back wide camera: better sensor, AF, torch available, more formats. Front TrueDepth: lets the patient/operator see a preview and gives depth/face tracking. For face rPPG with a clinician holding the device, the back camera with a clinician-facing preview is viable. For self-capture, use the front camera.

### Gaps
- No fetched Apple source in this session confirms per-model support for custom exposure/WB lock on the **front** camera. Engineers must query `isExposureModeSupported(.custom)`, `isWhiteBalanceModeSupported(.locked)` and `isLockingWhiteBalanceWithCustomDeviceGainsSupported` at runtime per device.
- Could not confirm the iOS 26 status/names of Studio Light/Background effects opt-in keys.

## 2. Pixel formats and colour space

### Takeaway
Capture in 8-bit 420f (full-range bi-planar YCbCr) or 10-bit x420/x422 and set `activeColorSpace = .sRGB`. Avoid HLG_BT2020 and Apple Log for rPPG/colour work unless you also store the transfer function, because these non-linear HDR curves change channel ratios. BGRA conversion is convenient but is a lossy, display-referred conversion done by the ISP.

### Cited Findings
- Capture formats on an iPhone 13 Pro expose four pixel formats: `420v` (8-bit video range), `420f` (8-bit full range), `x420` (10-bit 4:2:0) and `x422` (10-bit 4:2:2). None exceed 10 bits per channel and none are 4:4:4. — [Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)
- `AVCaptureDevice.activeColorSpace` / `AVCaptureColorSpace` control the colour space. HDR (`isVideoHDREnabled`) and global tone mapping live under the same "Color" topic group. — [Apple: Capture device color](https://developer.apple.com/documentation/avfoundation/capture-device-color)
- Apple Log recording requires iPhone 15 Pro or later. Apple Log 2 requires iPhone 17 Pro or later. — [Apple Final Cut Camera guide](https://support.apple.com/bg-bg/guide/final-cut-camera/dev14d309a3f/ios)
- The `supportedColorSpaces` list includes `.appleLog` on supporting devices. This comes from a third-party blog, so treat it as secondary. — [Blake Crosley: AVFoundation HDR and Apple Log](https://blakecrosley.com/blog/avfoundation-hdr-apple-log)
- **[unverified, from background knowledge]** `AVCaptureColorSpace` cases: `.sRGB`, `.P3_D65`, `.HLG_BT2020` (iOS 14.1+), `.appleLog` (iOS 17+), `.appleLog2` (iOS 26). `AVCaptureSession.automaticallyConfiguresCaptureDeviceForWideColor` defaults to true and may select P3 when a photo output is present. Set it to false and set `activeColorSpace = .sRGB` explicitly.
- Compression degrades the blue and red channels most; green is least affected. — [Zhao et al., CVPRW 2018, via Comas et al. 2024](https://ar5iv.labs.arxiv.org/html/2405.02652); [Zhao et al. CVPRW 2018 PDF](https://openaccess.thecvf.com/content_cvpr_2018_workshops/papers/w27/Zhao_A_Novel_Framework_CVPR_2018_paper.pdf)

### Inferences
- For rPPG, 4:2:0 chroma subsampling is acceptable because ROI spatial averaging over thousands of pixels makes chroma resolution irrelevant. Bit depth matters more: rPPG pulsatile amplitude is around 0.1–1% of skin intensity, so 10-bit (x420) gives about 4× finer quantisation than 8-bit. Spatial averaging partly compensates for 8-bit.
- For colour measurement (conjunctival pallor, tongue colour), use sRGB with locked WB and a colour reference card in frame. Convert YCbCr→RGB yourself with the documented matrix (BT.601 vs BT.709 is indicated by the buffer's `kCVImageBufferYCbCrMatrixKey` attachment) rather than relying on BGRA output. Log the attachments (`kCVImageBufferColorPrimariesKey`, `TransferFunctionKey`, `YCbCrMatrixKey`) per session.
- Requesting `kCVPixelFormatType_32BGRA` from `AVCaptureVideoDataOutput.videoSettings` makes the ISP convert. This is fine for on-device ROI extraction, but it costs bandwidth (4 B/px vs 1.5 B/px).

### Gaps
- No peer-reviewed study was found comparing 8-bit vs 10-bit iPhone capture for rPPG SNR.

## 3. Compression effects on rPPG SNR; recommended storage strategy and sizes

### Takeaway
Lossy compression measurably degrades rPPG even at visually lossless settings. The literature consensus is that ≥ about 10 Mb/s preserves usable SNR, and errors grow sharply beyond CRF about 20 (H.264). The best design is to (a) extract ROI RGB traces on-device from uncompressed buffers at full frame rate and store them losslessly (KB-scale), and (b) store the video either as ProRes 422 (on Pro models) or as high-bitrate HEVC/H.264 (≥ 20–50 Mb/s at 720p/1080p) for audit/re-processing.

### Cited Findings
- McDuff, Blackford & Estepp (IEEE FG 2017) tested x264/x265 across Constant Rate Factor settings. They found noticeable blood volume pulse SNR degradation even at low compression, but the BVP signal was not destroyed even at bitrate reductions of over 1000×. x265 performed better under large head motion. — [Microsoft Research page](https://microsoft.com/en-us/research/?p=707122); [AFRL summary](https://www.mobilityengineeringtech.com/component/content/article/27648-afrl-0256)
- Per Comas et al. 2024 summarising prior work: "only videos with a bit rate of at least 10 Mb/s maintained an rPPG signal with reasonable SNR". — [Comas, Ruiz & Sukno, arXiv 2405.02652](https://ar5iv.labs.arxiv.org/html/2405.02652)
- Comas et al. 2024, baseline MAE (bpm) vs H.264 CRF on UCLA-rPPG (intra-dataset) / UBFC (cross-dataset). The authors put CRF 20 at about 450 kb/s for their data.

  | CRF | 0 | 5 | 10 | 15 | 20 | 25 |
  |---|---|---|---|---|---|---|
  | Intra (UCLA) MAE | 1.02 | 1.12 | 1.18 | 1.26 | 1.94 | 2.98 |
  | Cross (UBFC) MAE | 1.66 | 3.14 | 4.57 | 6.75 | 12.82 | 14.44 |

  — [arXiv 2405.02652](https://ar5iv.labs.arxiv.org/html/2405.02652)
- Benchmark dataset bitrates: AFRL 310 Mb/s (raw Bayer), UCLA-rPPG 295 Mb/s (raw), PURE 222 Mb/s (PNG), UBFC-rPPG 215 Mb/s (raw), VicarPPG 34 Mb/s (H.264), OBF 20 Mb/s, PFF 10 Mb/s, MAHNOB-HCI 4.2 Mb/s, BP4D 3.5 Mb/s, COHFACE 0.25 Mb/s. — [arXiv 2405.02652](https://ar5iv.labs.arxiv.org/html/2405.02652)
- Nowara/McDuff: training networks at the same or higher compression as test data gives up to 3 dB SNR and up to 6 BPM MAE improvements. Mismatched compression hurts generalisation. — [NSF PAR listing](https://par.nsf.gov/search/author:"Nowara, Ewa_M"); [arXiv 2405.02652](https://ar5iv.labs.arxiv.org/html/2405.02652)
- Yu et al. 2019 (STVEN + rPPGNet) reconstructs uncompressed video from compressed video before pulse extraction. Zhao et al. 2018 proposed green-only extraction for highly compressed video. — [arXiv 2405.02652](https://ar5iv.labs.arxiv.org/html/2405.02652)
- ProRes files are "up to 30 times larger than HEVC files". — [Apple: About ProRes on iPhone](https://support.apple.com/109041)

### Inferences
- **Storage estimates per session**, assuming 30 fps and computed by arithmetic:
  - On-device ROI traces: 10 ROIs × 3 channels × float32 × 30 fps × 100 s ≈ 360 KB. With per-frame metadata (PTS, ISO, exposure, WB gains, head pose, distance, lux estimate) it stays under 1–2 MB. **This is the recommended primary rPPG artefact.**
  - Uncompressed 640×480 420f (1.5 B/px): about 13.8 MB/s, so ≈ 0.8 GB per 60 s or 1.4 GB per 100 s. At 1280×720 420f: about 41 MB/s, so ≈ 4.1 GB per 100 s. Feasible only as a temporary buffer.
  - **[unverified, from Apple ProRes white paper figures in background knowledge]** ProRes 422 at 1080p30 is about 122 Mb/s (≈ 15 MB/s), so ≈ 0.9 GB per 60 s or 1.5 GB per 100 s. ProRes 422 HQ is about 184 Mb/s, so ≈ 2.3 GB per 100 s. Reducing to 720p scales roughly with pixel count (about 0.45×).
  - HEVC/H.264 at 20 Mb/s: 2.5 MB/s, so ≈ 250 MB per 100 s. At 50 Mb/s: ≈ 625 MB per 100 s. Set it via `AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: …]` on AVAssetWriterInput **[unverified API detail]**. Prefer HEVC (better under motion per McDuff).
- Pragmatic recipe for the RUO platform: on-device trace extraction plus HEVC ≥ 20–30 Mb/s video (all devices), with ProRes 422 as an optional "reference-grade" mode on Pro iPhones. For conjunctiva/tongue colour, also save a few lossless still frames (PNG/TIFF from the locked video buffer, or a DNG still via `AVCapturePhotoOutput` RAW with the same locked WB) rather than relying on compressed video.

### Gaps
- Could not extract exact CRF/bitrate/SNR numbers from the McDuff 2017 PDF (binary PDF not parseable in this environment).
- Could not access Nowara, McDuff & Veeraraghavan, Biomedical Optics Express (2020/2021) directly.
- No study was found specific to iPhone hardware-encoder (VideoToolbox) HEVC vs rPPG SNR.

## 4. ProRAW / Bayer RAW for video; ProRes availability per device

### Takeaway
ProRes 422 video capture via AVFoundation is available on iPhone 13 Pro through iPhone 17 Pro (Pro/Pro Max only), using 10-bit `x422` formats. ProRAW and Bayer RAW are still-photo features, not video features in AVFoundation's standard pipeline. RAW video is not a practical path for this app.

### Cited Findings
- ProRes recording is supported on iPhone 13 Pro/Pro Max, 14 Pro/Pro Max, 15 Pro/Pro Max, 16 Pro/Pro Max, and 17 Pro/Pro Max, and requires iOS 15.1+. On 128 GB models it is limited to 1080p at 30/25 fps. 4K and 60 fps require ≥ 256 GB. — [Apple: About ProRes on iPhone](https://support.apple.com/109041)
- The 15 Pro, 16 Pro and 17 Pro can record ProRes directly to external USB-C storage. The 16 Pro and 17 Pro support ProRes in HDR or Log. — [Apple: About ProRes on iPhone](https://support.apple.com/109041)
- A developer report says 4K60 ProRes Log on the iPhone 15 Pro Max errors with "supported only on external storage device". This is an anecdotal report. — [Apple Developer Forums thread 769888](https://developer.apple.com/forums/thread/769888)
- To capture ProRes: there is no session preset for it. Use `.inputPriority`, pick an `x422` format, then check `AVCaptureMovieFileOutput.availableVideoCodecTypes` contains `.proRes422` (this list is dynamic and depends on the active format). Alternatively use `AVCaptureVideoDataOutput` + `AVAssetWriter` with `recommendedVideoSettings(forVideoCodecType: .proRes422, assetWriterOutputFileType: .mov)` and `expectsMediaDataInRealTime = true`. ProRes 4444 is not supported from camera because there are no 4:4:4 or >10-bit formats. — [Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)
- The Video Data Output + AVAssetWriter path lets the app inspect/process every sample buffer (ROI extraction) before writing. This is the architecture needed here. — [Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)

### Inferences
- iPads and non-Pro iPhones do not support ProRes capture per Apple's list, so the module needs an HEVC high-bitrate fallback path. Gate on `availableVideoCodecTypes` / `recommendedVideoSettings` returning ProRes.
- Whether the **front** camera offers `x422` formats is device-dependent. Apple says ProRes works "using any of its cameras" in the Camera app, but this was not confirmed for AVFoundation third-party apps. Query `formats` at runtime.

### Gaps
- **[unverified, from background knowledge]** Apple announced ProRes RAW and genlock support with the iPhone 17 Pro (2025) for pro video apps. I could not confirm the API surface or whether it is exposed to third-party AVFoundation apps. Treat this as unconfirmed.
- No fetched source confirms that Bayer RAW (`AVCapturePhotoOutput.availableRawPhotoPixelFormatTypes`) is still-only. This rests on background knowledge.

## 5. TrueDepth / ARKit face tracking for distance and head pose; conflicts with AVCaptureSession settings

### Takeaway
ARKit face tracking (`ARFaceTrackingConfiguration`) gives head pose (yaw/pitch/roll from `ARFaceAnchor.transform`) and face distance directly. However, ARKit owns the camera, so an `AVCaptureSession` cannot run on the same camera simultaneously. Since iOS 16, ARKit exposes the underlying `AVCaptureDevice` (`configurableCaptureDeviceForPrimaryCamera`) for limited manual exposure/WB/focus. A lighter, conflict-free alternative is to stay in AVCaptureSession and get pose/distance from Vision (`VNDetectFaceRectanglesRequest` yaw/pitch/roll) plus TrueDepth `AVCaptureDepthDataOutput`.

### Cited Findings
- ARKit frame rate/resolution are set only by choosing `configuration.videoFormat` from `supportedVideoFormats`. Apple advises against hard-coding resolution/fps because the array is ordered best-first. — [Apple: ARConfiguration.VideoFormat](https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class); [Apple: supportedVideoFormats](https://developer.apple.com/documentation/arkit/arconfiguration/supportedvideoformats)
- iOS 16 added 4K and HDR video formats in ARKit, and `configurableCaptureDeviceForPrimaryCamera` lets apps customise the underlying AV capture device. Some formats support HDR (`isVideoHDRSupported`, enabled with `videoHDRAllowed`). — [Apple: ARKit configuration objects](https://developer.apple.com/documentation/arkit/configuration-objects); [Apple: ARConfiguration](https://developer.apple.com/documentation/arkit/arconfiguration)
- Unity's ARKit plugin docs describe this iOS 16 feature: lock the camera, then set exposure (duration + ISO), white balance gains (R/G/B) and focus (lens position). They state that "advanced camera hardware configuration also requires a device with an ultra-wide camera". This is a third-party wrapper doc, so the ultra-wide requirement should be verified for the front TrueDepth camera. — [Unity ARKit camera manual](https://docs.unity.cn/Packages/com.unity.xr.arkit@6.0/manual/arkit-camera.html)
- Switching between face and world tracking at runtime does not preserve session state. — [Apple: ARKit configuration objects](https://developer.apple.com/documentation/arkit/configuration-objects)
- Center Stage requires depth delivery to be off. Conversely, enabling depth means Center Stage is unavailable, which is acceptable here. — [WWDC21 10047](https://developer.apple.com/wwdc21/10047)

### Inferences
- **[unverified, from background knowledge]** ARFaceTrackingConfiguration typically runs at 60 fps on TrueDepth devices, with 30 fps formats also listed. `ARFrame.capturedImage` is 420f YCbCr. ARKit applies its own auto-exposure unless overridden via the configurable device. ARKit does not support a custom fixed exposure duration inconsistent with its tracking needs, so test that locks persist (KVO the device's `exposureMode`/`whiteBalanceMode`).
- Recommended architecture: **AVCaptureSession (not ARKit)** with front TrueDepth `builtInTrueDepthCamera`, `AVCaptureVideoDataOutput` + `AVCaptureDepthDataOutput` synchronised by `AVCaptureDataOutputSynchronizer`. Distance comes from median depth in the face box, and pose from Vision face landmarks (yaw/pitch/roll in `VNFaceObservation`, with pitch available since iOS 15). This keeps full control of fps/exposure/WB. Run Vision at a reduced rate (e.g. 10 Hz) to save thermal budget. Use ARKit only if 3D-mesh-based ROI tracking is essential.
- For back-camera capture (no TrueDepth), estimate distance from inter-pupillary pixel distance (≈ 63 mm adult average) with the camera intrinsics (`cameraCalibrationData` / `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`), or use LiDAR depth on Pro models.

### Gaps
- No Apple source fetched in this session documents exactly which `AVCaptureDevice` properties may be changed through `configurableCaptureDeviceForPrimaryCamera` without breaking tracking (the doc page body did not load).
- No source was found on whether `AVCaptureDepthDataOutput` at 30 fps alongside 30 fps video introduces frame drops on older devices.

## 6. Thermal throttling, frame drops, timestamps

### Takeaway
Set `alwaysDiscardsLateVideoFrames` deliberately and keep the delegate callback cheap (ROI averaging only, using vImage/Metal). Detect gaps by differencing `CMSampleBufferGetPresentationTimeStamp` and by the `captureOutput(_:didDrop:from:)` callback, and monitor `ProcessInfo.thermalState` and `AVCaptureDevice.systemPressureState`.

### Cited Findings
- `alwaysDiscardsLateVideoFrames` defaults to true. When true, frames captured while the delegate queue is blocked in `captureOutput(_:didOutput:from:)` are discarded immediately. When false, delegates get more time but "application memory usage may increase significantly". — [Apple: alwaysDiscardsLateVideoFrames](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes)
- Completion-handler timestamps for exposure/WB changes are on the device clock and must be converted to `AVCaptureSession.synchronizationClock` before comparing with video data output buffer timestamps. — [Apple: setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))
- **[unverified, from background knowledge]** `AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didDrop:from:)` reports dropped frames with the attachment `kCMSampleBufferAttachmentKey_DroppedFrameReason` (`FrameWasLate`, `OutOfBuffers`, `Discontinuity`). `AVCaptureDevice.systemPressureState` (iOS 11.1+) reports `.nominal/.fair/.serious/.critical/.shutdown` with factors (`systemTemperature`, `peakPower`, `depthModuleTemperature`). Apple's guidance is to reduce frame rate at `.serious`, and the system may stop the session at `.shutdown`. `ProcessInfo.thermalState` gives the app-wide view.

### Inferences
- QC rules mapping to the spec: compute ΔPTS between consecutive buffers. A gap > 0.5 s means fail. Missing-frame % = 1 − (frames received / (duration × target fps)), with < 5% required. Log every `didDrop` reason. Because the frame rate is fixed at 30 fps, any ΔPTS ≈ 66.7 ms signals one dropped frame. Store the raw PTS array with the traces, since rPPG pipelines should resample on true timestamps, not assume uniform spacing.
- Keep the delegate under about 10 ms per frame at 30 fps. Hand off encoding to AVAssetWriter (hardware encoder) and do ROI means with vImage/Accelerate or a Metal compute kernel on the `CVPixelBuffer` directly (zero-copy via `CVMetalTextureCache`).
- With `alwaysDiscardsLateVideoFrames = true` (recommended), overload shows up as measurable drops rather than memory blow-up. Do not adapt by lowering fps mid-capture (this breaks "fixed fps"). Instead, abort and retry if pressure reaches `.serious`.
- 30–45 s face + 10 s eye + 15 s tongue captures are short. Thermal throttling is unlikely to be the limiting factor except on hot ambient days (tropical dengue clinics) or with torch + ARKit + ProRes concurrently.

### Gaps
- No published measurements were found of iPhone frame-drop rates during 60–100 s fixed-30 fps capture under tropical ambient temperatures.

## 7. Torch/flash for tongue/ocular illumination

### Takeaway
The back-camera torch provides a stable, repeatable illuminant for conjunctiva/tongue close-ups, but it needs its own WB calibration. Its colour temperature differs from ambient light, so WB gains should be calibrated with torch on and locked. Ambient light mixing will still shift colour, which argues for an in-frame colour reference card.

### Cited Findings
- **[unverified, from background knowledge]** `AVCaptureDevice.setTorchModeOn(level:)` (level 0–1, max `AVCaptureDevice.maxAvailableTorchLevel`) sets torch brightness. `isTorchAvailable` / `hasTorch` gate it. The torch is a back-camera LED only. The front camera has no torch; the "Retina Flash" screen flash is for stills only. Torch level may be reduced automatically under thermal pressure, which would change illumination mid-capture. KVO `torchLevel`/`isTorchActive` and log it.
- No peer-reviewed source was found in this session quantifying the spectrum/CCT of iPhone torch LEDs or their effect on conjunctival pallor estimation.

### Inferences
- For the face rPPG (front camera) protocol, rely on ambient ≥ 200 lux with locked exposure. Estimate lux from the device's EXIF-like metadata: brightness value from `kCGImagePropertyExifBrightnessValue` in the sample-buffer metadata dictionary, or ISO × exposure. Device ambient-light-sensor readings are not available to third-party iOS apps.
- For conjunctiva/tongue (back camera, torch at a fixed level such as 0.3–0.5 to avoid saturation and specular glare), fix the torch level, lock WB after a calibration frame on a grey/colour card under torch, and include the card in frame. Using a torch for face rPPG is not advised: the LED can have PWM flicker and specular reflections, and patient discomfort is a concern.

### Gaps
- No source was found on iPhone torch PWM frequency or stability at partial levels.

## 8. Existing iOS rPPG apps/SDKs and feasible accuracy

### Takeaway
Commercial SDKs (Binah.ai, NuraLogix Anura, Philips VitalSigns Camera, Cardiio historically) demonstrate that heart rate from iPhone face video is feasible under controlled conditions. Vendor-reported accuracy is high (Binah: |error| ≤ 3 bpm in 99.8% of measurements), while independent large-scale smartphone face-video studies (Google, 2026) report RHR MAE of about 4.4 bpm, HR MAPE of about 6%, and worse performance for darker skin tones.

### Cited Findings
- Binah.ai SDK 5.9.1 pulse-rate accuracy report (vendor, 2025): within the accuracy target (AE ≤ 3 bpm) in 99.8% of measurements on iOS and Android, against finger pulse oximeters. This is industry-sponsored. — [Binah.ai MED-000026 report](https://www.binah.ai/wp-content/uploads/2025/03/MED-000026-Pulse-Rate-Accuracy-Report-of-SDK-5.9.1-Final-Rev2-Final.pdf)
- Google Research (2026): passive front-camera HR from 8-second clips after face unlock, over 350,000 clips from about 700 participants. Daily RHR MAE vs Fitbit Charge 6 was 4.39 bpm (bias −0.1, LoA −9.1 to 9.2). HR vs ECG in free living had MAPE 6.09% after confidence gating (5.04% / 5.12% / 7.84% across skin-tone groups 1/2/3). The darkest skin group reached RHR MAE < 5 bpm only from day three. The authors suggest optimising camera exposure could help darker skin. Processing is on-device with a confidence score. — [Google Research blog](https://research.google/blog/towards-passive-heart-health-monitoring-via-smartphone-camera/)
- Yan et al., JMIR mHealth uHealth 2017: Cardiio iPhone app, front-camera face and rear-camera fingertip modes, vs 12-lead ECG in 40 adults during treadmill exercise. Accuracy criterion RMSE ≤ 5 bpm or ≤ 10%. Exact numbers were not retrieved. — [JMIR mHealth 2017;5(3):e33](https://mhealth.jmir.org/2017/3/e33/); [PMC5368348](https://pmc.ncbi.nlm.nih.gov/articles/PMC5368348)

### Inferences
- An 8 s clip suffices for HR in Google's pipeline. The spec's 30–45 s face capture gives margin for HR, and is a minimum for HRV/respiration-type features, which need longer windows.
- Skin-tone performance gaps are directly relevant to South/Southeast Asian dengue cohorts. Prioritise exposure optimisation per subject (set ISO/duration during warm-up to target face-ROI mean luma around 50–60% without clipping, then lock).
- **[unverified, from background knowledge]** Open-source references: rPPG-Toolbox (Python; algorithms CHROM, POS, PhysNet, EfficientPhys, etc.) for offline validation, and pyVHR. Few maintained open-source native-Swift rPPG apps exist. Expect to port POS/CHROM (simple linear algebra on ROI RGB traces) to Swift/Accelerate.

### Gaps
- Could not retrieve independent validation numbers for NuraLogix Anura or Philips VitalSigns Camera on iPhone in this session.
- Could not retrieve Yan et al. 2017 front-camera RMSE values.
- No source was found on rPPG validated in febrile/dengue or hypovolaemic patients on smartphones.
