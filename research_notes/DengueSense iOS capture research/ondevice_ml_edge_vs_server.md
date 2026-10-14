# On-device ML on iOS vs GPU-server inference for DengueSense capture (as of Oct 2026)

Scope: which DengueSense pipeline stages should run on iPhone/iPad and which on a GPU server. The stages are capture guidance, the 9-check quality gate, feature extraction, and the locked risk engine (6-decimal reproducibility, p95 <= 5 s, result <= 30 s after the session ends). Research budget was about 15 tool calls. Some questions could only be partly sourced, and each section's Gaps list says which.

## Q1. Core ML / ANE capabilities, quantisation, conversion, and YOLO segmentation export (2025-2026)

### Takeaway
Ultralytics now exports YOLOv8, YOLO11 and YOLO26 detect and segment models to Core ML with embedded NMS (dynamic=False), using a new `quantize=` argument. Its own iPhone 17 Pro figures show segmentation in about 5 ms on the Neural Engine, so on-device ocular and tongue segmentation is cheap for the quality gate. The platform itself is changing: at WWDC26 Apple announced **Core AI** as the "official successor to Core ML", with its own PyTorch converter. Any iOS ML code written now should plan for that migration.

### Cited Findings
- Ultralytics Core ML export: the `quantize` argument takes `16` (FP16), `8` (INT8), `"w8a16"`, or `32`/unset, and "Replaces the deprecated `half`/`int8` flags". NMS ML Programs use FP16, which segment and pose require. — [Ultralytics Core ML integration docs](https://docs.ultralytics.com/integrations/coreml/)
- `nms`: `None` (default) gives raw output, `True` embeds NMS, `False` selects the NMS-free head. Embedded NMS is supported for detect, segment and pose when `dynamic=False`. Supported tasks are detect, segment, classify, pose and OBB for YOLOv8, YOLO11 and YOLO26. Semantic and depth heads exist only in YOLO26. — [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/)
- Published iPhone 17 Pro latencies, YOLO26n INT8 on `.cpuAndNeuralEngine`: detect 3.2 ms, **segment 4.8 ms**, semantic 4.6 ms, classify 1.9 ms, pose 3.9 ms. CPU-only detect is 9.2 ms. These are "single-image burst latencies", and the docs say "Sustained real-time camera operation runs higher." — [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/)
- Ultralytics has added a `format="coreai"` export for Apple's Core AI (`.aimodel`, iOS/macOS 27 generation), but Core ML "remains the default format" in the Ultralytics iOS and Flutter SDKs, which load Core AI only as an opt-in. — [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/)
- Older segmentation export bugs (late 2024 to 2025), flagged as outdated. One user reported a YOLO11n-seg Core ML export returning all-zero mask prototypes and lacking NMS. Earlier, `nms=True` worked only for Detect models. v8.3.207 added padding of class scores to a multiple of 80 for CoreML NMS stability on non-80-class detection models. — [Ultralytics community thread](https://community.ultralytics.com/t/yolo-11-segmentation-on-coreml-returns-all-0-mask-prototypes/1119); [v8.3.207 release](https://community.ultralytics.com/t/new-release-ultralytics-v8-3-207/1539); [v8.3.194 release](https://community.ultralytics.com/t/new-release-ultralytics-v8-3-194/1442)
- Core AI (WWDC26) is described as "the official successor to Core ML". It runs across CPU, GPU and Neural Engine "under one API", "can only run on Apple Silicon", and supports quantisation and palettisation. PyTorch models are converted through `torch.export.ExportedProgram` and Apple's Core AI PyTorch converter (`TorchConverter().add_exported_program(ep).to_coreai()`, apple.github.io/coreai-torch). On first load, the model is specialised to the current hardware and OS and cached (`AICacheModel`, `SpecializationOptions`). InfoQ does not say Core ML is deprecated, and suggests Core ML for classic ML and Core AI for neural networks. — [InfoQ, June 2026](https://infoq.com/news/2026/06/apple-core-ai-wwdc)
- Before WWDC, AppleInsider reported Core AI as a Core ML replacement but said "both frameworks could exist in tandem for some time". — [AppleInsider, Mar 2026](https://appleinsider.com/articles/26/03/01/wwdc-2026-to-introduce-core-ai-as-replacement-for-core-ml)
- Quantisation guidance from third-party sources (not Apple docs, so unverified):
  - 4-bit palettisation is recommended for the ANE. Per-block INT4 linear quantisation (iOS 18+) mainly targets the GPU.
  - W8A8 is listed as the ANE option for compute-bound models on A17 Pro and M4.
  - Per-grouped-channel palettisation is iOS 18+.
  - Sources disagree on whether INT4 is useful on the ANE.
  — [swift-ios-skills coreml-optimization reference](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/apple-on-device-ai/references/coreml-optimization.md); [coreml-optimizer skill](https://skills.sh/ckorhonen/claude-skills/coreml-optimizer)
- Neural Network-format models run at FP32 on CPU but FP16 on GPU and ANE. ML Program models can run FP32 on GPU but not on the ANE. — [Hugging Face forum](https://discuss.huggingface.co/t/converting-clip-to-coreml/31345/5)

### Inferences
- The quality-gate segmentation for the ocular check (IoU >= 0.6) and the tongue check (IoU >= 0.7) can run on-device at a few ms per frame on recent iPhones. Running it on every frame is not needed: segmenting at 2-5 Hz is enough for a live "conjunctiva/tongue visible" prompt.
- Export with `nms=True`, `dynamic=False`, and `quantize=16` or `w8a16` for the on-device preview model. Keep the FP32 PyTorch or ONNX model on the server as the authoritative segmenter that produces the IoU and colour measurements logged for the audit trail.
- Use Core ML now, but treat model packaging as replaceable, since Core AI (iOS 27+) is the forward path. Don't build regulated logic around Core ML-specific features.

### Gaps
- I did not retrieve Apple's own coremltools 8/9 release notes or the Core ML docs on ANE op support. The ANE op-support matrix and the INT4-on-ANE claims are unverified.
- No published iPhone latency numbers for YOLO11-seg specifically. Only YOLO26n numbers are given, and those are burst figures, not sustained.
- Core AI minimum OS, `.aimodel` encryption support, and whether coremltools continues to be developed were not confirmed from Apple primary docs.
- App size limits: the only figure found is the 4 GB main-bundle limit mentioned in WWDC25 session 325 ([WWDC25-325](https://developer.apple.com/videos/play/wwdc2025/325)). The cellular-download threshold was not verified.

## Q2. Vision framework for capture guidance (face rect, landmarks, roll/yaw/pitch, segmentation) at 30 fps

### Takeaway
Vision provides face boxes, landmarks and roll/yaw/pitch (in radians, with pitch added later), which cover the head-pose and face-stability checks on-device. I found no authoritative 30 fps benchmark, so frame rate has to be measured in-house.

### Cited Findings
- `VNFaceObservation.yaw` and `.roll` are optional `NSNumber` values in radians, nil if the request didn't compute them. Roll is positive counterclockwise, range [-π, π). — [Apple docs: roll](https://developer.apple.com/documentation/vision/vnfaceobservation/roll.md); [Apple docs: yaw](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw.md); [Apple docs: init(roll:yaw:)](https://developer.apple.com/documentation/vision/vnfaceobservation/init(requestrevision:boundingbox:roll:yaw:).md)
- Pitch was added in a later API revision through an overload that takes roll, yaw and pitch. — [apisof.net catalog](https://apisof.net/catalog/3423ddea45b59ba84324a61667f623f6)
- Landmarks are populated only when a landmarks request runs. A face-rectangles request alone leaves them empty. — [Kodeco Vision face detection tutorial](https://www.kodeco.com/1163620-face-detection-tutorial-using-the-vision-framework-for-ios?page=3)

### Inferences
- On-device guidance can use `VNDetectFaceRectanglesRequest` on every frame (box, roll/yaw/pitch, stability) and `VNDetectFaceLandmarksRequest` at a lower rate (eye and mouth ROIs for the ocular and tongue prompts). Distance can come from the face-box size and lighting from frame luminance statistics. None of these needs a server.
- Real-time viability is plausible because Ultralytics measured sub-5 ms ANE segmentation (Q1), but Vision request timings at 30 fps need on-device profiling.

### Gaps
- No primary source found for Vision face landmarks or person segmentation fps. I did not retrieve docs or performance figures for `VNGeneratePersonSegmentationRequest` or `VNGenerateForegroundInstanceMaskRequest`, and the WWDC Vision sessions were not fetched.

## Q3. Real-time rPPG on iPhone (POS/CHROM vs PhysNet/TS-CAN/EfficientPhys)

### Takeaway
Lightweight deep rPPG models were designed for on-device use: MTTS-CAN reports more than 150 fps on an ARM CPU, and EfficientPhys claims a further 33% efficiency gain. Classical POS/CHROM is cheap signal processing. On-device rPPG for a live SNR preview is feasible, but I found no published iPhone latency or energy benchmark for POS/CHROM.

### Cited Findings
- MTTS-CAN: "evaluate[d] … on an Advanced RISC Machine (ARM) CPU and achieve state-of-the-art accuracy while running at over 150 frames per second which enables real-time applications." — [MTTS-CAN, NeurIPS 2020](https://proceedings.neurips.cc/paper/2020/file/e1228be46de6a0234ac22ded31417bc7-Paper.pdf); [arXiv 2006.03790](https://alphaxiv.org/abs/2006.03790)
- EfficientPhys: "our most lightweight network also achieves a 33% improvement in efficiency". It takes raw frames, whereas DeepPhys and MTTS-CAN need difference-frame and normalisation preprocessing. Its Transformer variant is aimed at real-time on-device inference. — [EfficientPhys, arXiv 2110.04447 / WACV 2023](https://arxiv.org/pdf/2110.04447); [UbiComp lab page](https://ubicomplab.cs.washington.edu/publications/efficientphys)
- A 2025 Oulu system runs a real-time rPPG pipeline (HR, RR, SpO2) at 30 fps with a multithreaded design aimed at low-power devices. — [arXiv 2508.18787](https://arxiv.org/html/2508.18787v1)
- The RhythmEdge demo (2022, older) profiled computation time, memory and power on three resource-limited edge devices and concluded real-time HR estimation is feasible. — [arXiv 2208.06572](https://arxiv.org/pdf/2208.06572)
- Passive smartphone rPPG during everyday use met the consumer HR accuracy standard (MAPE <= 10%) across skin-tone groups. — [arXiv 2503.03783](https://arxiv.org/pdf/2503.03783)
- The commercial Binah.ai SDK has validation reports on iPhone 11 Pro and iPhone 13 (proprietary algorithm). — [Binah HRV validation report](https://www.binah.ai/wp-content/uploads/2022/06/HRV-validation-report.pdf)

### Inferences
- On-device: run POS or CHROM over a rolling 8-10 s window to compute a provisional SNR and spectral-plausibility (HR band 40-180 bpm) indicator for live feedback. This is mainly per-frame ROI mean RGB plus a small FFT, which is negligible next to the camera pipeline.
- Server: run the authoritative rPPG HR/HRV/AC-DC extraction (deep or classical) on the uploaded raw or lightly compressed video, so HRV and other features are computed in one controlled numeric environment.
- Compression matters: rPPG is sensitive to codec artefacts, so the upload format (high-bitrate HEVC or ROI-cropped near-lossless video) is an architectural decision.

### Gaps
- I could not extract EfficientPhys's per-device latency table (the PDF text could not be parsed in this environment). A third-party leaderboard figure of "371 ms frame latency, Mobile/ARM" is unverified and should not be used.
- No published POS/CHROM latency or energy figures on iPhone. A short in-house benchmark is needed.

## Q4. Determinism and reproducibility of Core ML / ANE outputs

### Takeaway
Core ML/ANE inference is **not** bitwise reproducible across devices or compute units. The ANE computes in FP16 with non-IEEE rounding, and the OS chooses the compute unit per SoC and OS version. A risk engine locked and reproducible to 6 decimal places must therefore run on a pinned server stack, with the device verdict treated as advisory.

### Cited Findings
- Cross-platform FP16 measurements: CPUs and GPUs mostly follow IEEE 754 round-to-nearest-ties-to-even, but NPUs differ. Apple's NPU appears to round add/sub ties away from zero, and multiplication and reciprocal are not strictly IEEE 754. The paper says quantisation-based solutions "fail to produce deterministic results across diverse hardware platforms" and adopts a design that works "without requiring bit-exact arithmetic". — [MLVC, arXiv 2606.28027 (ECCV 2026)](https://arxiv.org/pdf/2606.28027); [abstract](https://arxiv.org/abs/2606.28027)
- The ANE appears to compute in FP16 throughout (community reverse engineering). — [neural-engine docs, 16-bit](https://github.com/michaelbernstein/neural-engine/blob/master/docs/16-bit.md)
- ANE FP16 max of 65,504 causes silent overflow or underflow in softplus, logsumexp and log_softmax (single 2026 forum poster, unverified). — [Apple Developer Forums, Core ML topic](https://developer.apple.com/forums/topics/machine-learning-and-ai/machine-learning-topic-core-ml)
- The same FP16 model ran on the NPU on most iPhones but fell back to CPU on iPhone 11 (A13). Apple staff attributed compute-unit assignment to the SoC, OS version and model ops. — [Apple Developer Forums 763368](https://developer.apple.com/forums/thread/763368)
- Developers report the "same model, wildly different results per platform". — [Apple Developer Forums 95775](https://developer.apple.com/forums/thread/95775)
- Core AI specialises a model "to the current hardware and OS" on first load, so compiled artefacts are device- and OS-specific. — [InfoQ](https://infoq.com/news/2026/06/apple-core-ai-wwdc)

### Inferences
- **Server-side authoritative inference is strongly indicated** for feature extraction and the risk engine. Pin the container image, library versions, CPU (or deterministic GPU) kernels and model hash. Penalised LR and gradient boosting on CPU in FP64 are easily reproducible to 1e-6. Deep models need deterministic flags and a fixed hardware class.
- Even forcing `.cpuOnly` on device would not give cross-OS-version guarantees, because Apple controls the runtime and kernels change with OS updates. Device outputs cannot be part of the audited result.
- Recommended pattern: the device sends raw media plus provisional quality-gate values. The server recomputes all 9 checks and features. The audit record stores server values, model version or hash, and the device's provisional verdict for concordance monitoring.

### Gaps
- I found no Apple statement on Core ML determinism, either guaranteeing or denying it. The evidence is a preprint plus anecdotes.

## Q5. Model protection and IP (Core ML encryption, extraction risk)

### Takeaway
Core ML offers Apple-managed encryption of compiled `.mlmodelc` models: AES-128 per a security write-up, with a FairPlay-backed key fetched at first load. The model is decrypted only in memory, which still leaves a jailbroken-device memory-dump risk. Keeping the risk engine on the server avoids exposing it at all.

### Cited Findings
- Xcode generates a model encryption key tied to the developer team and encrypts the compiled model. Core ML decrypts at load time. — [Apple: Generating a model encryption key](https://developer.apple.com/documentation/coreml/generating-a-model-encryption-key.md); [Apple: Encrypting a model in your app](https://developer.apple.com/documentation/coreml/encrypting-a-model-in-your-app.md)
- Analysis says the encryption uses AES-128 and FairPlay, and the decrypted model exists only in memory. — [SecuRing: From .mlmodel to encrypted .mlmodelc](https://www.securing.pl/en/from-mlmodel-to-mlmodelc-how-apple-encrypts-and-delivers-ml-models/)
- Apple engineers say the key is fetched securely and stored locally at model load. Apps need network access on first load, so offline-first apps must plan for load failure. — [Apple Developer Forums 650089](https://developer.apple.com/forums/thread/650089)
- Encryption can be combined with Core ML cloud model deployment. — [Apple Developer Forums 651467](https://developer.apple.com/forums/thread/651467)
- Reported failures: "failed to invoke mremap_encrypted" when loading encrypted models from cloud collections or third-party frameworks. — [Apple Developer Forums 695471](https://developer.apple.com/forums/thread/695471); [695807](https://developer.apple.com/forums/thread/695807)

### Inferences
- On-device models should be low-value commodity components (face, eye and tongue segmenters, quality heuristics). The proprietary risk engine, its coefficients and the feature-engineering code stay server-side, which also removes an extraction or adversarial-probing surface.
- If an on-device model is encrypted, the first launch must happen online. Clinic deployments with poor connectivity need to account for this.

### Gaps
- Whether Core AI `.aimodel` supports equivalent encryption was not confirmed.

## Q6. Offline operation: on-device preliminary ACCEPT/RECAPTURE vs authoritative server verdict

### Takeaway
Most of the 9 checks can be approximated on-device in real time, which gives immediate RECAPTURE prompts. The final verdict and all features should come from the server. A fixed policy is needed for cases where the two disagree.

### Cited Findings
- On-device feasibility building blocks: sub-5 ms ANE segmentation (YOLO26n-seg on iPhone 17 Pro) — [Ultralytics](https://docs.ultralytics.com/integrations/coreml/). Vision face pose angles — [Apple docs](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw.md). Real-time rPPG on low-power hardware — [arXiv 2508.18787](https://arxiv.org/html/2508.18787v1).
- Device-specific numerical differences and compute-unit fallback mean device values will differ from server values. — [Apple Forums 763368](https://developer.apple.com/forums/thread/763368); [MLVC](https://arxiv.org/pdf/2606.28027)

### Inferences
Proposed split, based on the evidence above:

| Check | On-device (offline, live) | Server (authoritative) |
|---|---|---|
| 1. Face detection stability | Vision face rects per frame | Recompute |
| 2. Motion / head pose | Vision roll/yaw/pitch + IMU | Recompute |
| 3. Exposure / lighting | Luminance histogram, clipping | Recompute |
| 4. Frame rate / compression | AVCapture timestamps, dropped frames | Verify on received file |
| 5. rPPG SNR & spectral plausibility | POS/CHROM rolling-window estimate | Authoritative |
| 6. Occlusion | Landmark confidence / segmentation | Recompute |
| 7. Ocular IoU >= 0.6 | Core ML seg (FP16, preview) | Authoritative FP32 |
| 8. Tongue IoU >= 0.7 + Brenner + colour-card ΔE | Seg + Brenner (cheap); card detection can be provisional | Authoritative (ΔE needs calibrated pipeline) |
| 9. Duration / missing frames | Timer, frame counter | Verify |

- Reconciliation policy:
  - Device thresholds can be set slightly stricter than server thresholds, so that a device ACCEPT rarely becomes a server RECAPTURE. Tune the margin on paired data.
  - If the server returns RECAPTURE after the patient has left, the session is non-evaluable. A server verdict within 30 s, while the patient is still present, lowers this cost.
  - Offline: queue the media, mark the session "pending verification", and show no risk output until the server returns.
  - Log device-vs-server concordance per check as a post-market performance metric.

### Gaps
- No published concordance data between on-device and server quality checks in rPPG or clinical capture apps.

## Q7. Battery and thermal cost of vision + ML during a 60-100 s capture

### Takeaway
I found no direct published measurement. The available evidence is that per-frame ML costs are small (single-digit ms on the ANE) and the ANE is far more efficient than CPU. Ultralytics notes that sustained camera operation runs slower than burst figures, so thermal throttling should be tested in-house.

### Cited Findings
- ANE vs CPU latency gap: YOLO26n detect takes 3.2 ms on ANE vs 9.2 ms CPU-only, and pose 3.9 vs 11.9 ms. "Sustained real-time camera operation runs higher." — [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/)
- Core AI says compression (quantisation and palettisation) can reduce memory footprint, latency and power. — [InfoQ](https://infoq.com/news/2026/06/apple-core-ai-wwdc)
- RhythmEdge profiled power on edge devices for real-time rPPG (not iPhone). — [arXiv 2208.06572](https://arxiv.org/pdf/2208.06572)

### Inferences
- A 60-100 s session with 30 fps capture, Vision face tracking, low-rate segmentation and POS is unlikely to trigger throttling on recent iPhones. Throttling is more likely on older devices, in hot clinic environments (dengue-endemic tropics), or with the torch on.
- Mitigations: run segmentation at reduced rate, keep the preview at 30 fps, and watch `ProcessInfo.thermalState` to drop optional on-device models when it rises. Thermal-induced frame-rate changes also affect check 4 and rPPG quality.

### Gaps
- No published iPhone energy (mJ/frame) or thermal data for Vision + Core ML camera pipelines. An in-house benchmark is needed with Instruments' Energy Log and thermal state, across devices and ambient temperatures of 30-35 °C.

## Q8. Federated / on-device personalisation for regulated models

### Takeaway
It is not appropriate for the locked risk engine. FDA's PCCP framework, finalised in Dec 2024, allows pre-specified, validated modifications with defined methodology and impact assessment. That is incompatible with uncontrolled per-device learning. Federated learning could at most feed centralised, versioned retraining.

### Cited Findings
- FDA final guidance on PCCPs for AI-enabled device software functions was issued in early December 2024 (Dec 3 or 4, depending on source). PCCPs allow preapproved modifications "in lieu of" separate submissions, across PMA, 510(k) and De Novo, but not Special 510(k). — [Foley, Jan 2025](https://www.foley.com/insights/publications/2025/01/fda-final-guidance-ai-device-software-predetermined-change-control-plan/); [McDermott](https://www.mwe.com/?p=297431)
- A PCCP should contain the planned modifications, a methodology to develop, validate and implement them, and an impact assessment. — [Foley](https://www.foley.com/insights/publications/2025/01/fda-final-guidance-ai-device-software-predetermined-change-control-plan/)
- One source dates a final guidance to Aug 18, 2025, which conflicts with the Dec 2024 date. This may be a different or revised document and was not verified. — [Data Privacy and Security Insider](https://www.dataprivacyandsecurityinsider.com/2025/08/fda-final-guidance-on-pccp-streamlining-fda-approval-for-ai-enabled-medical-devices/)

### Inferences
- DengueSense is Research-Use-Only now, but designing for a future SaMD submission favours this setup:
  - A single locked server model with version and hash.
  - Changes delivered only through centrally retrained, validated releases, which are describable within a future PCCP.
  - No on-device personalisation of risk outputs.
- On-device adaptation is acceptable only for non-diagnostic UX, such as guidance-prompt timing.

### Gaps
- I did not fetch the FDA guidance text or the IMDRF documents on locked vs adaptive algorithms. The FDA URL I tried returned 404.

## Q9. Model update delivery (Background Assets, versioning, App Review)

### Takeaway
Apple-hosted Background Assets (WWDC25) let on-device models ship as versioned asset packs. These are reviewed by App Review, but separately from the app binary, and once approved a pack version replaces the old one for all installed app versions. That speed is useful for the preview models but needs version pinning in the app. Server-side models avoid App Review entirely, which strongly favours keeping the regulated model on the server.

### Cited Findings
- Asset packs are uploaded to App Store Connect separately from the app binary and submitted for review for TestFlight and App Store. "If you submit an asset pack version and an app version together, the App Review team will use your selected asset pack version to review your app." — [WWDC25 session 325](https://developer.apple.com/videos/play/wwdc2025/325)
- Asset packs are versioned independently of app builds, and "Only one version of the asset pack can be live for each context". A new approved version means "all versions of your app downloaded from the App Store will automatically be switched over to using asset pack version 2, including older versions that are still installed". — [WWDC25-325](https://developer.apple.com/videos/play/wwdc2025/325)
- Download policies are Essential (part of install), Prefetch, and On-demand. The developer membership includes 200 GB of Apple hosting. Apple advises migrating from On-Demand Resources to Background Assets. — [WWDC25-325](https://developer.apple.com/videos/play/wwdc2025/325); [WWDC Notes](https://wwdcnotes.com/documentation/wwdc25-325-discover-applehosted-background-assets/)
- The session mentions Background Assets being used to "update on device machine learning models with an accelerated submission process". — [WWDC25-325](https://developer.apple.com/videos/play/wwdc2025/325)
- WWDC26 session 378 covers further Background Assets updates. — [WWDC26-378](https://developer.apple.com/videos/play/wwdc2026/378)
- App Review Guideline 2.5.2 bars downloading code that changes app functionality. An Apple DTS engineer said updating ML models after install is, as far as DTS knows, not in conflict with the guidelines and other apps rely on it, but recommended confirming with App Review. — [Apple Developer Forums 793131](https://developer.apple.com/forums/thread/793131); [793267](https://developer.apple.com/forums/thread/793267)
- In 2026 Apple has been actively enforcing 2.5.2 against apps that generate and run code after install (Replit, Vibecode). — [Implicator](https://www.implicator.ai/apple-blocks-replit-and-vibecode-updates-over-how-generated-apps-run-inside-ios)
- Core ML model deployment (cloud model collections) also exists and can be combined with encryption. — [Apple Forums 651467](https://developer.apple.com/forums/thread/651467)

### Inferences
- Because asset packs switch all installed app versions to the new version, the app must check a pack-manifest model version or hash against an allow-list, and the server must log which on-device model produced each provisional verdict.
- Server-side updates of the risk engine and authoritative extractors need no App Review. Locking, versioning and audit live in the organisation's own MLOps and QMS: a model registry, hashes, and validation reports. This is another reason to make the server authoritative.

### Gaps
- Asset-pack size limits and minimum iOS version for Apple-hosted packs were not stated in the session transcript.
- I found no written App Review ruling on ML model downloads, only DTS's informal position.
