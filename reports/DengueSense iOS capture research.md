# Lock the sensor, let the server decide

DengueSense can be built as a native Swift app, but only if the iPhone is treated as a tightly controlled scientific sensor and not as a camera. In practice that means three things. First, use a custom AVFoundation pipeline with every automatic correction switched off and read back after each change. Second, put a colour reference in every conjunctival and tongue frame. Third, keep a locked server stack as the only place where audited features and risk scores are computed. The device's job is live capture guidance and a provisional ACCEPT/RECAPTURE verdict. The science imposes hard limits. No peer-reviewed, clinically validated smartphone-camera method exists for dengue detection or severity. Resting heart rate is the only camera vital sign with reasonably consistent evidence, and that evidence degrades in Fitzpatrick V–VI skin and at elevated heart rates. Conjunctival haemoglobin estimates carry limits of agreement of roughly ±4.8 g/dL, far too coarse to track dengue haemoconcentration. Those limits shape the regulatory position. The Research-Use-Only clinician mode is achievable now. It needs a legal-entity Apple account, TestFlight distribution, MREC approval, an MDA clinical-research exemption, and PDPA-grade security. A consumer "scan for dengue" mode would almost certainly be rejected by Apple under Guideline 1.4.1 without regulatory clearance. It would also likely be a Class C device in Malaysia and a De Novo submission at FDA, backed by prospective, multi-site, skin-tone-stratified validation that no one has yet produced.

## Seven automatic camera features must be switched off and verified

The capture pipeline has to be built on `AVCaptureSession` with `AVCaptureVideoDataOutput`, not `UIImagePickerController` or the Camera app. Every default Apple applies to make video look good corrupts either the pulsatile signal or the colour measurement. AVFoundation exposes all the controls needed:

- **Frame rate:** set `activeVideoMinFrameDuration` equal to `activeVideoMaxFrameDuration`, within the active format's supported ranges. Choosing a new session preset silently resets this value ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration)).
- **Session preset:** use `.inputPriority` so the session stops auto-configuring the format ([Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)).
- **Exposure:** `setExposureModeCustom(duration:iso:)` locks duration and ISO. Apple warns that changing exposure duration **can change the active frame duration**, so exposure must stay at or below the frame period. If an `AVCapturePhotoOutput` shares the session, its default `.balanced` prioritisation can override the locked exposure for multi-frame fusion ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))). The simplest fix is to attach no photo output during rPPG capture.
- **White balance:** `setWhiteBalanceModeLocked(with:)` freezes the gains. Each gain must lie between 1.0 and `maxWhiteBalanceGain`, and gains are device-specific, not portable between phone models ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:))).

The seven features that need active suppression are:

- **Video HDR/EDR.** It is on by default and needs `automaticallyAdjustsVideoHDREnabled = false` followed by `isVideoHDREnabled = false` ([WWDC21 10047](https://developer.apple.com/wwdc21/10047)).
- **Local adaptive tone mapping.** This is the default and should be replaced with global tone mapping where the format supports it. Global tone mapping **resets to false whenever the format, input or preset changes** ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isglobaltonemappingenabled)).
- **Center Stage.** It pans and crops digitally, caps capture at 30 fps and 1920×1440, and requires the app to switch `centerStageControlMode` to `.app` before it can be disabled ([WWDC21 10047](https://developer.apple.com/wwdc21/10047)).
- **Portrait blur.** It applies only if the app adds `NSCameraPortraitEffectEnabled` to Info.plist, so the key must never be added ([WWDC21 10047](https://developer.apple.com/wwdc21/10047)).
- **Video stabilisation.**
- **Later Control-Center effects such as Studio Light.**
- **Wide-colour auto-configuration.**

The notes flag the last three, along with focus-lock API details, as needing confirmation against the target iOS version before release. Because several of these properties silently reset, the module must apply them in a fixed order after the input is added. It must then **read every value back, write it into session metadata, and abort on any mismatch**. Completion-handler timestamps arrive on the device clock and must be converted to the session's `synchronizationClock` to mark the exact frame where a lock took effect ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))).

### Extract traces on-device, archive video at high bitrate

Format choice comes down to bit depth versus convenience. iPhone capture formats offer 8-bit `420v`/`420f` and 10-bit `x420`/`x422`, and **nothing above 10 bits or at 4:4:4** ([Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)). The rPPG pulse sits at roughly 0.1–1% of skin intensity, so 10-bit gives meaningfully finer quantisation. The 4:2:0 chroma subsampling is harmless, because ROI averaging over thousands of pixels discards spatial chroma detail anyway. The colour space should be forced to sRGB. HLG and Apple Log are non-linear HDR curves that change channel ratios.

Compression is the bigger threat. In one benchmark, mean absolute error for cross-dataset heart rate rose from **1.66 bpm at H.264 CRF 0 to 12.82 bpm at CRF 20**. The same review notes that only videos of at least 10 Mb/s kept reasonable rPPG SNR ([Comas et al. 2024](https://ar5iv.labs.arxiv.org/html/2405.02652)). McDuff and colleagues found noticeable blood-volume-pulse degradation even at low compression, and found x265 more robust under head motion ([Microsoft Research](https://microsoft.com/en-us/research/?p=707122)). Compression hits the red and blue channels hardest ([Zhao et al. 2018](https://openaccess.thecvf.com/content_cvpr_2018_workshops/papers/w27/Zhao_A_Novel_Framework_CVPR_2018_paper.pdf)), and those are exactly the channels that matter for pallor and redness.

The right architecture extracts per-ROI RGB traces on-device from the uncompressed `CVPixelBuffer` at the full frame rate. Ten ROIs over 100 s with per-frame metadata come to about 1–2 MB (computed), and this trace file should be the **primary rPPG artefact**. Video is archived for audit as HEVC at 20–50 Mb/s, about 250–625 MB per 100 s. ProRes 422 is an optional reference-grade mode, but it is available only on the iPhone 13 Pro through 17 Pro, is limited to 1080p30 on 128 GB models, and produces files **up to 30× larger than HEVC** ([Apple](https://support.apple.com/109041)). The Video Data Output plus `AVAssetWriter` path is the one that lets the app process every buffer before writing ([Apple TN3104](https://developer.apple.com/documentation/technotes/tn3104-recording-video-in-apple-prores)).

The two research notes disagree on how to capture conjunctival and tongue stills. One recommends DNG/ProRAW. The other warns that adding a photo output can override locked exposure. A safe compromise is a separate still-capture step with its own locks, or lossless PNG/TIFF frames pulled from the locked video buffer.

### AVCaptureSession beats ARKit for pose and distance

`ARFaceTrackingConfiguration` gives head pose and distance directly, but **ARKit owns the camera**. Frame rate is chosen only by picking from `supportedVideoFormats` ([Apple](https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class)). Since iOS 16 the underlying device can be partly configured ([Apple](https://developer.apple.com/documentation/arkit/configuration-objects)), but Unity's documentation says advanced configuration requires an ultra-wide camera ([Unity](https://docs.unity.cn/Packages/com.unity.xr.arkit@6.0/manual/arkit-camera.html)). The conflict-free design stays in AVCaptureSession. It pairs the TrueDepth video and depth outputs, takes distance from median face-box depth, and takes pose from Vision's `VNFaceObservation` roll/yaw/pitch ([Apple](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw.md)). Center Stage requires depth delivery to be off, so enabling depth conveniently rules it out ([WWDC21 10047](https://developer.apple.com/wwdc21/10047)).

For frame integrity, keep `alwaysDiscardsLateVideoFrames = true`. With `false`, memory use "may increase significantly" ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes)). With `true`, overload shows up as measurable drops rather than a crash. The delegate should stay under about 10 ms per frame. The app should store the raw presentation-timestamp array so the server can resample on true timing. It should also **abort and retry instead of lowering fps** when system pressure rises, since a mid-capture rate change breaks the fixed-rate contract.

The back-camera torch is the only repeatable illuminant for close-range eye and tongue shots. It needs its own white-balance calibration and a card in frame. The notes found no published data on iPhone torch spectrum or PWM behaviour.

Independent smartphone face-video evidence sets realistic expectations. Google's 2026 study of about 700 participants found resting-HR MAE of **4.39 bpm** against Fitbit. Free-living heart-rate MAPE was 6.09% overall, but **7.84% in the darkest skin group versus about 5% in the lighter groups**. The authors suggest that exposure optimisation could help darker skin ([Google Research](https://research.google/blog/towards-passive-heart-health-monitoring-via-smartphone-camera/)).

## Uncalibrated phone colour misses clinical tolerance by roughly 3–4×

Colour is where most published smartphone-imaging work fails to generalise. In a multi-device facial-skin study, raw smartphone images differed from a DSLR reference by a **mean ΔE of 6.99, and 0% of images met ΔE < 2**. A linear colour-correction matrix cut that error by 67–77%. Even after calibration, the **ITA skin index agreed poorly across devices (ICC 0.46)**, while the melanin index held up (ICC 0.77). The authors call this "colour-clinical decoupling" ([Kang 2025](https://arxiv.org/html/2512.21988v2)). A ColorChecker teledermoscopy study found intra-phone variability of ΔE 0.1 but inter-phone variability of 2.0–3.9, so per-device models are required ([PMC7662536](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7662536/)). Oblique viewing angles raised ΔE by up to 64%, and chart-based correction removed 65–70% of the inter-device and lighting variation ([Strathprints](https://strathprints.strath.ac.uk/id/eprint/93830)). Tongue-imaging research reaches the same conclusion: generalisation fails mainly because of colour reproducibility and non-standard capture ([PMC5168476](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5168476/)). Fixed-environment pipelines therefore combine segmentation, a colour-correction module and quality gating ([Frontiers Physiol 2025](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2025.1559389/full); [PMC8097848](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8097848/)).

These findings set four engineering requirements:

- **A reference card in every conjunctiva and tongue frame**, with a CCM fitted per capture and residual ΔE00 logged as a QC metric. A rejection threshold of around 3–4 is reasonable, though no clinical standard exists beyond the ΔE < 2 benchmark.
- **Validation of derived features per device model.** Calibrated pixels do not guarantee calibrated biomarkers.
- **A preference for melanin index over ITA** when recording skin tone.
- **Specular masking** for the wet, glossy tongue and conjunctiva.

### Skin tone degrades rPPG, and dengue's tachycardia makes it worse

The bias evidence is consistent in direction. A meta-analysis across three datasets found that average rPPG performance "drops significantly for the darkest skin type" ([Nowara et al., CVPRW 2020](https://openaccess.thecvf.com/content_CVPRW_2020/html/w19/Nowara_A_Meta-Analysis_of_the_Impact_of_Skin_Tone_and_Gender_CVPRW_2020_paper.html)). A 2025 audit of 100 rPPG studies found public datasets underrepresent darker skin. It cites chrominance-method MAE of **5.2 bpm in Fitzpatrick I–III versus 14.1 bpm in V–VI**, a figure the notes saw only second-hand. The audit attributes the gap to very dark or very light skin exceeding RGB dynamic range ([npj Digit Med 2025](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12491395/)). Physics-based methods ([Chari et al.](https://arxiv.org/pdf/2010.12769)) and skin-tone-transfer augmentation ([PhysFlow](https://arxiv.org/pdf/2407.21519)) reduce the gap. Neither removes it.

Reliability also falls under low illumination and at **elevated heart rates** ([summary of Acharya et al. 2025](https://www.alphagalileo.org/fr-fr/Item-Display-fr-FR/ItemId/266427)). Febrile and pre-shock dengue patients are tachycardic by definition. For Malaysia's Malay, Chinese and Indian population, much of it Fitzpatrick III–V, the app therefore needs to do four things:

- Record Monk/Fitzpatrick type and ideally a colorimeter melanin index for every participant.
- Set exposure per subject during a warm-up to target unclipped face-ROI luma, then lock it.
- Enforce a lighting floor and an ISO ceiling.
- **Reject low-SNR segments rather than emit a number.**

The OUCRU dengue volume-status work went further and **excluded absolute-amplitude PPG features specifically to avoid skin-tone bias** ([Lyle et al. 2025](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12273927/)). That argues for treating facial "AC/DC perfusion" as a within-subject trend only.

### Malaysia's 50 Hz mains aliases into 30 fps video

Mains lighting on 50 Hz supply flickers at 100 Hz. Frame rates that divide 100 Hz (25 or 50 fps) lock the flicker into a static offset. Other rates produce rolling bands and slow beats. **Exposure times that are integer multiples of the flicker period suppress it** ([US Patent 10104309](https://patents.google.com/patent/US10104309); [US 7248289](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7248289)). At 30 fps the residual folds to about 10 Hz. That is outside the 0.7–3.5 Hz heart-rate band, but it can leak through harmonics and LED PWM beats. The practical rule for a fixed 30 fps capture is a **10 ms or 20 ms exposure**, which fits under the 33 ms frame period. Add a background-ROI or spectral flicker check before accepting a recording ([HKU Optima](https://www.eee.hku.hk/optima/pub/journal/2606_CH.pdf)). This guidance comes from camera-engineering physics. No rPPG study has quantified mains-flicker error, so the team should measure it in its own clinics.

## No camera method yet detects dengue or tracks haematocrit

The evidence base sets what DengueSense can claim, and it is thin.

**Wearable PPG, the strongest analogue.** The best dengue-specific work is not camera-based. It uses contact, transmissive red/IR PPG at 100 Hz from a wrist-and-finger wearable in hospitalised Vietnamese patients. Of 250 enrolled, 153 were analysed. Two-hour-ahead shock prediction reached **AUROC 0.72 and AUPRC 0.15**. In the low-risk state, PPG alone managed **AUROC 0.58, rising to 0.83 only when clinical data were added**. Only about 43% of recorded data was usable, and 38.8% of enrolled patients were excluded for signal quality or data availability ([Kenyon et al., npj Digit Med 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11531560/)). The volume-status follow-up kept only about 13% of 20-second segments after quality filtering ([Lyle et al. 2025](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12273927/)). Reflectance face video at 30 fps is a weaker signal than transmissive finger PPG at 100 Hz. Face-only deterioration prediction should therefore be expected to underperform these figures until proven otherwise, and the quality gate will reject a large share of captures.

**Haemoglobin and haematocrit.** A prospective emergency-department validation of a conjunctival smartphone app analysed 426 patients. It found **sensitivity 54.3%, specificity 89.7%, and Bland-Altman limits of agreement of −4.73 to +4.93 g/dL**, and did not report skin tone ([Zhao et al., PLoS One 2024](https://www.hcplive.com/view/smartphone-app-accurate-anemia-detection-conjunctival-images)). An earlier conjunctival erythema-index study fell from 93% sensitivity in training to **57% in internal validation** ([Collings et al. 2016](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4829242/)). Using the rough approximation Hct ≈ 3 × Hb, ±4.8 g/dL implies about ±14 haematocrit points. That cannot resolve the ~20% Hct rise that marks plasma leakage. The notes found **no smartphone method for haematocrit or platelet count in any population**. Even the guideline relationship between Hct and leakage is described as unclear ([Lyle et al. 2025](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12273927/)).

**Direct dengue-imaging claims.** The remaining claims do not hold up:

- A fingertip-video dengue dataset of 170 participants exists but has no clinical validation ([IEEE DataPort](https://ieee-dataport.org/node/14339)).
- A "99.62% accurate" rash CNN is a high-school abstract ([Society for Science](https://abstracts.societyforscience.org/Home/PrintPdf/25639)).
- Tongue AI targets TCM syndromes, and the notes found **no dengue or febrile-illness tongue study** ([Preprints.org](https://www.preprints.org/manuscript/202404.0565)).

**Other vital signs.** Camera blood pressure does not meet AAMI/BHS standards in independent work ([BioMed Eng OnLine 2025](https://biomedical-engineering-online.biomedcentral.com/articles/10.1186/s12938-025-01365-w)). Camera SpO2 has only healthy-dataset and pilot validation ([arXiv 2206.08748](https://arxiv.org/pdf/2206.08748)).

**What the app can defensibly claim.** WHO's warning sign of "increase in Hct concurrent with a rapid decrease in platelet count" still requires a blood test ([BMC Infect Dis 2013](https://bmcinfectdis.biomedcentral.com/track/pdf/10.1186/1471-2334-13-498)). Diagnosis requires NS1, RT-PCR or IgM. Defensible RUO claims are therefore limited to three:

- Standardised capture.
- Signal-quality-gated HR trend.
- Exploratory association of facial, conjunctival and tongue features with lab Hct, platelets and outcomes.

DengueSense's dataset would be genuinely novel, which is its scientific value. It is not yet evidence of clinical utility.

## The device guides capture, a pinned server computes the verdict

The edge-versus-server split follows from one fact: **Core ML on the Neural Engine is not bitwise reproducible**. Measurements show Apple's NPU rounds FP16 ties away from zero and departs from IEEE 754 on multiply and reciprocal. Quantised inference "fail[s] to produce deterministic results across diverse hardware" ([MLVC, arXiv 2606.28027](https://arxiv.org/pdf/2606.28027)). The OS assigns compute units by SoC, OS version and model ops, and the same model fell back to CPU on an A13 ([Apple Forums 763368](https://developer.apple.com/forums/thread/763368)). Apple's new Core AI framework, announced at WWDC26 as "the official successor to Core ML", specialises each model to the current hardware and OS on first load ([InfoQ](https://infoq.com/news/2026/06/apple-core-ai-wwdc)). A risk engine that must reproduce to six decimal places therefore belongs on a pinned server stack, with a fixed container image, library versions, CPU or deterministic GPU kernels, a model hash, and FP64 where feasible. Device outputs serve as advisory guidance and concordance data.

On-device ML is cheap enough for live guidance. Ultralytics exports YOLO segmentation to Core ML with embedded NMS and a `quantize=` argument. It reports **4.8 ms segmentation on an iPhone 17 Pro's Neural Engine**, though these are burst figures and "sustained real-time camera operation runs higher" ([Ultralytics](https://docs.ultralytics.com/integrations/coreml/)). Ocular and tongue segmentation at 2–5 Hz, Vision face pose on every frame, and a rolling 8–10 s POS/CHROM window for a provisional SNR readout all fit within the thermal budget of a 60–100 s session. Lightweight deep rPPG models were designed for edge hardware: MTTS-CAN exceeds 150 fps on an ARM CPU ([NeurIPS 2020](https://proceedings.neurips.cc/paper/2020/file/e1228be46de6a0234ac22ded31417bc7-Paper.pdf)). The authoritative extraction should still run server-side. No published iPhone latency, energy or tropical-ambient thermal data exist for any of these, so an in-house benchmark at 30–35 °C is required.

| Quality check | On-device (offline, live) | Server (authoritative) |
|---|---|---|
| Face stability, head pose | Vision face rects, roll/yaw/pitch, IMU | Recompute |
| Exposure/lighting, flicker | Luma histogram, clipping, flicker metric | Recompute |
| Frame rate, missing frames, duration | PTS deltas, `didDrop` reasons, timer | Verify on received file |
| rPPG SNR and spectral plausibility | POS/CHROM rolling window | Authoritative extraction |
| Occlusion | Landmark confidence, segmentation | Recompute |
| Ocular IoU ≥ 0.6 / tongue IoU ≥ 0.7, sharpness | FP16 Core ML segmenter, Brenner | FP32 segmenter |
| Colour-card ΔE | Provisional card detection | Authoritative CCM and ΔE |

The reconciliation policy matters more than the split. Device thresholds should be set slightly stricter than the server's, so that a device ACCEPT rarely becomes a server RECAPTURE after the patient has left. When offline, sessions are marked "pending verification" and show no risk output. Per-check device–server concordance should be logged as a performance metric.

Keeping the proprietary model on the server also settles IP and update questions. Core ML encryption decrypts the model only in memory, which still leaves a dump risk on a jailbroken device ([SecuRing](https://www.securing.pl/en/from-mlmodel-to-mlmodelc-how-apple-encrypts-and-delivers-ml-models/)). It also needs a **network fetch of the key on first load** ([Apple Forums 650089](https://developer.apple.com/forums/thread/650089)), which is awkward for offline clinics. Apple-hosted Background Assets can ship versioned on-device models. However, an approved pack version switches **every installed app version** to it ([WWDC25-325](https://developer.apple.com/videos/play/wwdc2025/325)), so the app must check the model hash against an allow-list. Server-side model updates bypass App Review entirely. They also fit FDA's December 2024 PCCP framework of pre-specified, validated changes, which rules out per-device personalisation of risk outputs ([Foley](https://www.foley.com/insights/publications/2025/01/fda-final-guidance-ai-device-software-predetermined-change-control-plan/)).

## Research mode is achievable now, consumer mode needs clearance first

### Apple's rules

Apple's Guideline 1.4.1 is the main obstacle for any consumer mode. It says apps must "clearly disclose data and methodology to support accuracy claims relating to health measurements, and if the level of accuracy or methodology cannot be validated, we will reject your app". It names blood pressure and blood oxygen "using only the sensors on the device" as **not permitted**, and invites developers to submit regulatory clearance documentation ([Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)).

For the RUO study, the binding rules are these:

- **5.1.1(ix):** submission by a legal entity, so reAInmaker SDN BHD, not an individual.
- **5.1.3(iii):** research consent covering five specified elements: purpose and duration, risks and benefits, data handling, a contact point, and withdrawal.
- **5.1.3(iv):** independent ethics approval, producible on request.
- **5.1.3(ii):** no personal health information in iCloud.
- **5.1.2(vi):** no data-mining of facial-mapping data.
- **2.5.14:** a visible recording indicator.

All are listed in the [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

### Distributing to study sites

Distribution points to TestFlight. It allows **10,000 external testers**, requires Beta App Review only for the first external build, and **expires every build after 90 days** ([Apple](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)). The protocol should therefore state that a rebuild with no algorithm change is not an amendment. The Enterprise Program is effectively unavailable. It requires 100+ employees and is a last resort behind the App Store, custom apps, Ad Hoc and TestFlight ([Apple](https://developer.apple.com/programs/enterprise/enroll/)). Enterprise apps are also limited to employees, so hospital clinicians could not receive one ([MacPaw](https://macpaw.com/how-to/apple-developer-enterprise-program)). Study-owned, supervised devices under MDM also control camera-hardware variability, which the colour evidence shows is necessary.

### Malaysian approvals

Malaysia requires three parallel tracks:

- **MDA exemption.** Act 737 requires registration before marketing. Clinical research is exempt under the **Medical Device (Exemption) Order 2024**, in force March 2024. For some categories the Order replaced notification with an exemption application through Medcast, with a fee ([MDA](https://portal.mda.gov.my/index.php/industry/exemption/announcement); [Skrine](https://www.skrine.com/insights/alerts/march-2024/government-issues-new-medical-device-exemption-ord)). MDA/GD/0016 describes how a No Restriction Letter permits supply of an unregistered device for clinical research ([MDA](https://portal.mda.gov.my/index.php/documents/guideline-documents/556-mdagd0016-notification-for-clinical-research-or-performance-evaluation/file)).
- **NMRR registration and MREC approval.** MOH-facility studies need both. Ethics review takes about 50 business days, run in parallel with roughly 30 for regulatory review ([ClinicalResearch.my](https://clinicalresearch.my/establishing-clear-procedures-and-improving-start-up-timeline-in-malaysias-clinical-research-ecosystem/)). Submission is advised 4–6 months before data collection ([UKM/MOH guideline](https://www.ukm.my/spsfper/wp-content/uploads/2025/07/GUIDELINES-ON-MASTERS-CLINICAL-RESEARCH-CONDUCTED-IN-THE-MINISTRY-OF-HEALTH-MALAYSIA-FACILITIES.pdf)). The MREC letter doubles as Apple's 5.1.3(iv) evidence.
- **PDPA compliance.** The PDPA amendments are fully in force. Processors have a direct security duty from 1 April 2025. DPO appointment and mandatory breach notification apply from 1 June 2025 ([Baker McKenzie](https://insightplus.bakermckenzie.com/bm/data-technology/malaysia-personal-data-protection-amendment-act-2024-to-come-into-force)). The breach guideline requires notice to the Commissioner **within 72 hours** and to affected individuals within 7 days of that notice ([DLA Piper](https://privacymatters.dlapiper.com/2025/03/malaysia-guidelines-issued-on-data-breach-notification-and-data-protection-officer-appointment/)).

The notes could not confirm whether a "capture-only, results-blinded" design needs the MDA filing. Filing anyway is the safe course.

### What a consumer self-screening mode would require

FDA's guidance shifted on 6 January 2026. The new General Wellness guidance lets non-invasive physiological estimates be wellness products, but **only without disease claims or clinical thresholds**. The new CDS guidance still treats any software that analyses images or signals as a device ([Faegre Drinker](https://www.faegredrinker.com/en/insights/publications/2026/1/key-updates-in-fdas-2026-general-wellness-and-clinical-decision-support-software-guidance)). Naming dengue therefore forecloses the wellness route, and a 2025 warning letter to WHOOP shows the risk of drifting toward medical positioning ([Jones Day](https://www.jonesday.com/en/insights/2026/01/a-relaxing-2026-fda-updates-general-wellness-and-clinical-decision-support-software-guidance)). The regulatory precedents are narrow. Camera-only clearances so far cover **pulse and respiratory rate only**: PanopticAI ([Cardiology Innovations](https://cardiologyinnovation.com/cardiology-advancements/imaging-technologies/fda-clears-mobile-app-contactless-pulse-rate-measurement/)) and Presage's K254169 in July 2026 ([PR Newswire](https://www.prnewswire.com/news-releases/presage-technologies-earns-fda-clearance-for-contactless-vital-signs-makes-them-available-for-free-302818692.html)). The notes found no regulator-cleared dengue app anywhere. In the EU, Rule 11 starts diagnostic software at Class IIa. The June 2025 MDCG revision pushes predictive, illness-preventing AI toward IIb ([OpenRegulatory](https://openregulatory.com/mdcg/mdcg-2019-11); [Osborne Clarke](https://www.osborneclarke.com/insights/eu-confirms-app-stores-and-developers-are-subject-medical-device-laws)).

| Claim | Malaysia (MDA) | FDA | EU MDR |
|---|---|---|---|
| Wellness check, no disease named | Possibly not a device | General wellness | Not a device |
| Aid to clinician dengue assessment | Likely Class B–C | Likely De Novo, Class II | IIa–IIb |
| Predicts deterioration / severe dengue | Likely Class C | De Novo with special controls | IIb |
| Consumer "scan to help detect dengue" | Highest scrutiny | Lay-user labelling and human factors raise the bar | As above |

The Malaysian classes are inferred from the GHTF/ASEAN risk scheme. The notes did not verify them, and MDA has no standalone SaMD guidance; it ran a SaMD/AI training course in July 2025 ([MDA](https://portal.mda.gov.my/index.php/announcement/1584-youre-invited-to-our-upcoming-training-session-fundamentals-of-software-as-a-medical-device-samd)).

A consumer mode would therefore need all of the following:

- A prospective multi-site performance study against NS1/RT-PCR/serology, stratified by skin tone, age, illness day and device model.
- Lay-user usability validation.
- Cybersecurity documentation.
- A PCCP or equivalent change plan.
- Post-market monitoring.
- MDA Class B/C registration through a Conformity Assessment Body.
- A clearance link supplied to Apple.

Even then, false reassurance is the dominant harm. A defensible consumer mode would route users to testing based on symptoms and a warning-sign questionnaire, and would never present a camera output as reassurance.

## Security rests on file-protection classes, envelope encryption and App Attest

### Encryption at rest

Data Protection classes determine what the app can do while the phone is locked:

- **Class B (CompleteUnlessOpen)** lets a file be created and written while the device is locked. The per-file key is wiped as soon as the file closes ([Apple Platform Security](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)). That suits in-progress `AVAssetWriter` output.
- **Class C (CompleteUntilFirstUserAuthentication)** keeps its key in memory after first unlock. It is needed for a sealed artefact that the background-transfer daemon must read on a locked phone ([Apple Platform Security](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)).

Class C is weaker, so the sealed file should carry an app-layer envelope: a random per-artefact AES-GCM key, chunked into ~4 MB segments for files of hundreds of MB, wrapped via a Secure Enclave P-256 key agreement or HPKE to a server public key. The Secure Enclave offers only P-256 signing and key agreement, with no symmetric API ([CryptoKit SE reference](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/swift-security/references/secure-enclave.md)). Because flash wear-levelling defeats overwriting ([Apple fed-talk](https://lists.apple.com/archives/fed-talk/2012/Sep/msg00116.html)), **secure deletion means destroying the key, not the bytes**.

### Background upload

Uploads should use a background `URLSession` with file-based upload tasks only. Force-quit cancels its tasks ([Apple DTS](https://developer.apple.com/forums/thread/14855)). The transfer itself should be S3 multipart with per-part pre-signed URLs. Parts range from 5 MiB to 5 GiB, with up to 10,000 parts ([AWS](https://docs.aws.amazon.com/us_en/AmazonS3/latest/userguide/qfacts.html)). Expiry is checked only at request start, so a transfer that has begun completes, but **any retry after expiry fails** ([AWS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url)). URLs should therefore be minted lazily per part. iOS 26's `BGContinuedProcessingTask` is meant for user-initiated work such as sealing artefacts with visible progress, not for sync ([WWDC25-227](https://developer.apple.com/la/videos/play/wwdc2025/227/)).

A SQLite outbox (GRDB) should be the single source of truth, with two rules:

- Every intent gets an idempotency key that is persisted once and reused on retry.
- Every timestamp is stored as wall clock plus monotonic uptime plus a server offset, with `feature_availability_timestamp` set at quality ACCEPT.

The uptime APIs fall under Apple's required-reason rules and must be declared in the privacy manifest ([Nutrient](https://www.nutrient.io/blog/privacy-manifests-on-ios/)).

### Device trust and clinician sign-in

**App Attest** gives each install a hardware-backed key. Call `attestKey` once per install, staying under about 100 requests per second globally ([Apple](https://developer.apple.com/documentation/devicecheck/preparing-to-use-the-app-attest-service.md); [Apple Forums 759285](https://developer.apple.com/forums/thread/759285)). After that, use challenge-based assertions to refresh a 24-hour device-trust token rather than re-attesting daily. Jailbreak checks are defence in depth only, because instrumentation tools bypass them ([OWASP MASTG](https://mas.owasp.org/MASTG/knowledge/ios/MASVS-RESILIENCE/MASTG-KNOW-0087/)).

Clinicians should sign in through OIDC via `ASWebAuthenticationSession`, which picks up MDM-pushed Enterprise SSO extensions automatically ([Microsoft Learn](https://learn.microsoft.com/entra/identity-platform/apple-sso-plugin)). Shared iPad temporary sessions **delete the user's volume at sign-out** ([Apple Platform Security](https://support.apple.com/guide/security/secd99f373ef)), which could destroy pending uploads. Single-user supervised devices with an in-app clinician switch and a device-scoped upload credential are the safer design.

### Network and screen protection

`NSPinnedDomains` pins CA SPKIs declaratively and covers background sessions. It has no user override, and re-signing a modified app strips the pins ([OWASP MASTG](https://mas.owasp.org/MASTG/tests/ios/MASVS-NETWORK/MASTG-TEST-0385/); [Apple Forums 731368](https://developer.apple.com/forums/thread/731368)). The app should pin its API and auth hosts and leave the object-store host unpinned. iOS offers **no supported way to block screenshots**. Apple recommends detecting recording through `sceneCaptureState`, then shielding the content and logging the event ([Apple Forums 838583](https://developer.apple.com/forums/thread/838583)).

## Conclusion

The research changes where the effort belongs. The hard part of DengueSense is not Swift camera code or on-device ML, which are both mature and cheap. The hard part is turning an iPhone into a reproducible measurement instrument, and then producing evidence that its measurements mean something in dengue. Each layer of the design points the same way:

- Locked, read-back camera settings.
- On-device trace extraction ahead of compression.
- A colour card in every frame.
- Server-side deterministic inference.
- Hash-pinned models.

That design is valuable mainly because it is also what a future MDA Class C, FDA De Novo and PCCP submission would demand. Building the RUO app to regulated-device discipline now costs little extra and preserves the option of a later submission.

The evidence gaps define the study, not just the app. The two biggest unknowns are face-video signals at 30 fps, which are much weaker than the contact PPG behind the best dengue results (a severity AUROC of only 0.58 without clinical data), and data from darker-skinned, tachycardic, febrile patients, which barely exists. The first study should therefore be powered to answer three questions:

- What fraction of captures pass quality gating in real Malaysian wards?
- Does rPPG error stay acceptable across Fitzpatrick groups at high heart rates?
- Do within-patient trends in facial or conjunctival features track paired lab Hct and platelets?

A consumer self-screening mode should stay off the roadmap until those answers exist. Even then, its likely form is a symptom-and-warning-sign triage tool that directs users to testing, not a camera that tells them they are fine.
