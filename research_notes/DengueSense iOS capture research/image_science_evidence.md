# Smartphone camera-based physiological and haematological estimation for dengue: evidence and image-science constraints (as of Oct 2026)

Evidence grading used throughout: **[RCT]** randomised trial; **[PV]** prospective clinical validation against a reference standard; **[PO]** prospective observational/derivation cohort; **[RETRO]** retrospective/public-dataset benchmark; **[PILOT]** small pilot / bench / thesis / student project; **[VENDOR]** non-independent manufacturer report; **[SECONDARY]** figure seen only via press release or another paper's citation, not the primary text. I found **no RCTs** for any of the capabilities below.

## 1. Smartphone rPPG accuracy vs reference (HR, HRV, SpO2, BP) and skin-tone bias

### Takeaway
Resting heart rate from a smartphone is the only camera vital sign with reasonably consistent evidence. Contact PPG (finger over the lens) correlates strongly with ECG, while face-video rPPG is typically within a few bpm under controlled light. Error rises measurably in Fitzpatrick V–VI skin, in low light and at high heart rates. Camera BP does not meet AAMI/BHS standards in independent studies. Camera SpO2 lacks clinical validation across skin tones. Facial-video HRV and "AC/DC perfusion" have no validated clinical accuracy that I could find, and should be treated as exploratory.

### Cited Findings
- **Contact smartphone PPG vs ECG (HR):** a 2024 systematic review/meta-analysis update (Mather et al.) found r = 0.98–1.0 across 8 articles and 9 datasets. It reported correlations rather than limits of agreement and concluded agreement was "established under highly controlled conditions" and needs replication in clinical populations [systematic review of mostly PO/RETRO studies] — [Frontiers Digital Health 2024](https://www.frontiersin.org/journals/digital-health/articles/10.3389/fdgth.2024.1326511/pdf)
- A 2018 JMIR Cardio review of smartphone HR apps (Bland-Altman 95% LoA as an outcome) found no significant mean difference vs validated methods, in resting sinus rhythm — [JMIR Cardio 2018](https://cardio.jmir.org/2018/1/e4/PDF)
- A pooled limits-of-agreement meta-analysis of smartphone PPG vs ECG (including device type and OS) is still only a protocol, with results expected Q1 2027. **No pooled LoA exists yet** — [JMIR Res Protoc 2026](https://www.researchprotocols.org/2026/1/e84837); [PMC12867510](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12867510/)
- **Face rPPG HR under different illuminations:** in a benchmark, traditional methods (e.g., CHROM) were more robust than deep-learning methods under fluctuating light, and brightness augmentation improved the DL models. The paper's versions disagree on n and error (35 subjects / CHROM 1.04 bpm vs 12 subjects / 1.5 bpm) [RETRO/PILOT] — [arXiv 2107.13193](https://arxiv.org/pdf/2107.13193)
- An ~90-patient rPPG benchmark reported MAE ≈ 3 bpm with "no significant performance decrease for any skin tone group" [PO, small] — [Cureus 2023](https://assets.cureus.com/uploads/original_article/pdf/150278/20230912-4180-vpq056.pdf)
- Acharya et al. (npj Digital Medicine 2025) report reduced reliability of AI rPPG under **low illumination and elevated heart rates**. I saw only the press summary [SECONDARY]. This matters because febrile and pre-shock dengue patients are tachycardic — [AlphaGalileo summary](https://www.alphagalileo.org/fr-fr/Item-Display-fr-FR/ItemId/266427)
- A Google Research passive selfie-video HR system reports MAPE < 10% vs ECG, with deliberate oversampling of darker skin (≥33% of participants) [SECONDARY, news report; primary paper not verified] — [NeuronFeed](https://neuronfeed.com/news/google-research-unveils-passive-heart-monitoring-via-smartphone-camera)
- **Skin-tone bias: Nowara, McDuff & Veeraraghavan (CVPRW 2020)** ran a meta-analysis over 3 datasets (73 people, >400 videos). Average performance "drops significantly for the darkest skin type", and skin type does not affect all methods equally [RETRO] — [CVF Open Access](https://openaccess.thecvf.com/content_CVPRW_2020/html/w19/Nowara_A_Meta-Analysis_of_the_Impact_of_Skin_Tone_and_Gender_CVPRW_2020_paper.html)
- **Dasari et al.** (figures as cited in a 2025 npj Digital Medicine audit): chrominance methods had MAE 5.2 bpm in Fitzpatrick I–III vs **14.1 bpm in V–VI** (p < 0.01), and deep-learning models went from 6.0 to 9.5 bpm [SECONDARY; original not verified] — [npj Digit Med 2025, PMC12491395](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12491395/)
- The same npj Digital Medicine 2025 audit of 100 rPPG studies found that public datasets underrepresent darker skin and are gender-imbalanced. Mechanism: very dark (high absorption) or very light (high reflectance) skin can exceed RGB sensor dynamic range, which lowers chrominance-signal SNR — [PMC12491395](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12491395/); [DOAJ](https://doaj.org/article/d5ce85512e22454bbb8b485ebd378267)
- **Chari et al. (UCLA), "Diverse R-PPG":** a physics-driven method improves performance on darker skin, evaluated on 54 subjects / 432 videos (~864 min). The authors state it "does not obviate skin tone bias" but mitigates it [RETRO] — [arXiv 2010.12769](https://arxiv.org/pdf/2010.12769); [UCLA project page](https://visual.ee.ucla.edu/diverse_rppg.htm)
- The UCLA camera + radar fusion reduced the skin-tone bias (not applicable to a phone-only app) — [TechXplore 2022](https://techxplore.com/news/2022-08-remote-heart-sensors-biased-darker.amp)
- **PhysFlow** (skin-tone transfer via conditional normalising flows) augments darker-skin training data and reduces HR error, particularly in dark skin [RETRO] — [arXiv 2407.21519](https://arxiv.org/pdf/2407.21519)
- A 2026 study of 15 facial ROIs × 4 algorithms (described in search results as npj Cardiovascular Health) notes rPPG "remains highly susceptible to ambient lighting variations". **Citation unverified:** the link returned was an MDPI Sensors 2025 page, and I did not confirm which paper it is — [MDPI Sensors 25(2):501](https://www.mdpi.com/1424-8220/25/2/501)
- In low light, pulsatile amplitude falls until noise dominates. Chrominance methods are additionally hurt by their skin-tone assumption in the dark — [Image Enhancement for rPPG in Low Light](https://sotaverified.org/papers/image-enhancement-for-remote)
- **BP:** a Singapore General Hospital study (n = 200 pre-op) found systolic MAPE 9.52% and diastolic MAPE 7.52% (DBP mean diff 0.16 ± 3.22 mmHg) [PV] — [JMIR Formative 2025](https://formative.jmir.org/2025/1/e60455)
- **BP:** a 127-participant smartphone PPG study found random-forest SBP MAE 7.34 and DBP 5.79 mmHg, which "barely meet" standards. The arXiv version (SBP MAE 2.61–15.21) concluded they did **not** meet AAMI/BHS [PO] — [BioMed Eng OnLine 2025](https://biomedical-engineering-online.biomedcentral.com/articles/10.1186/s12938-025-01365-w); [arXiv 2401.11117](https://www.arxiv.org/abs/2401.11117)
- **BP vendor report (Binah.ai SDK 5.9.1):** 87.9% of systolic and 82.9% of diastolic readings were within the vendor's stated accuracy targets [VENDOR] — [Binah.ai](https://www.binah.ai/wp-content/uploads/2025/03/MED-000025-Blood-Pressure-Accuracy-Report-of-SDK-5.9.1_Rev2-Final.pdf)
- **SpO2:** ReViSe reported MAE 1.64% on the PURE public dataset [RETRO, healthy, narrow SpO2 range]. A Czech finger-on-camera pilot reported MAE 1.1% on 50 records [PILOT] — [arXiv 2206.08748](https://arxiv.org/pdf/2206.08748); [VUT](https://vut.cz/vav/vysledky/detail/164168)
- A smartphone SpO2 adapter with skin-tone consideration was tested only on synthetic skin and sheep blood [PILOT/bench] — [JMIR Biomed Eng 2022](https://biomedeng.jmir.org/2022/1/e34934)
- **Contact-pulse-oximetry precedent:** occult hypoxaemia occurred in 18.9% of observations in dark-skinned vs 6.6% in light-skinned participants (unverified preprint provenance) — [arXiv 2608.21782](https://arxiv.org/pdf/2608.21782)
- **Counterpoint (wrist PPG, not camera):** a Galaxy Watch4 study (n = 48, Fitzpatrick II–IV only) found no systematic pigmentation bias. It does not cover V–VI — [CinC 2026](https://cinc.org/2026/Program/accepted/479.html)

### Inferences
- In Malaysia's mixed population (Malay, Chinese, Indian; many Fitzpatrick III–V), skin-tone-stratified validation is mandatory. Report MAE per Fitzpatrick/Monk group and pre-register an acceptable gap.
- Prefer POS/CHROM plus a DL model trained on augmented darker-skin data. Log a per-segment SNR / signal-quality index, and reject low-SNR segments rather than output a number.
- Do not output BP or SpO2 to users. At most, collect them as research endpoints against reference cuff/oximeter readings.
- Tachycardia is a dengue-relevant signal, yet rPPG reliability degrades at elevated HR. Validation must deliberately include febrile and tachycardic patients.
- Facial "AC/DC perfusion" is an uncalibrated quantity. It is confounded by melanin, illumination and exposure, so it should be treated only as within-subject relative trend data. The OUCRU volume-status paper itself excluded absolute-amplitude features to avoid skin-tone bias (see Section 3).

### Gaps
- I did not access the primary Dasari et al. paper. Its numbers are second-hand.
- I found no published validation of **facial-video HRV** (RMSSD/SDNN) against ECG in clinical or febrile populations, and no pooled MAE for face rPPG.
- I found no camera-SpO2 validation across Fitzpatrick V–VI in desaturated patients.
- The primary text of Google's smartphone HR study was not verified.

## 2. Smartphone estimation of haemoglobin / anaemia, haematocrit and platelets

### Takeaway
Smartphone Hb estimation from fingernail and conjunctival images works as a coarse anaemia screen. Independent prospective validation shows only moderate sensitivity (~54–73%) and wide Hb limits of agreement (about ±4.8 g/dL), with performance best at severe anaemia. That precision is far too low to detect the few-percentage-point Hct rise of dengue haemoconcentration. I found **no** validated camera method for haematocrit or platelet count. Dengue warning-sign labs (rising Hct with falling platelets) therefore cannot be replaced by the camera.

### Cited Findings
- **Mannino et al., Nature Communications 2018 (fingernail-bed app):** n = 337 (237 discovery, 100 validation) vs CBC. Hb accuracy was ±2.4 g/dL with sensitivity up to 97% for anaemia without calibration, and ±0.92 g/dL with personalised calibration (n = 4 or 16, conflicting reports). Developers framed it as screening, not diagnosis, and authors hold a financial interest [PO; SECONDARY via press] — [Georgia Tech news](https://www.news.gatech.edu/2018/12/10/no-bleeding-required-anemia-detection-smartphone); [HealthDay](https://www.healthday.com/healthpro-news/blood-disorders/smartphone-app-uses-fingernail-bed-images-to-detect-anemia-740281.html)
- The nail-bed approach is claimed to be skin-tone independent because nail beds lack melanin. This comes from press, not independent testing — [Georgia Tech news](https://www.news.gatech.edu/2018/12/10/no-bleeding-required-anemia-detection-smartphone)
- **Jay et al. / Brown, derivation (ED, smartphone conjunctiva):** n = 344 total. Accuracy was ~83% in derivation and ~73% in validation, and sensitivity fell from 90.7% to 72.8% [PO] — [PMC8279386](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8279386/); [Healio](https://www.healio.com/news/hematology-oncology/20210729/algorithm-enables-detection-of-anemia-from-smartphone-photos-of-the-inner-eyelid)
- **Zhao, Vidwans, Bearnot … Jay, PLoS One 2024;19(5):e0302883 (prospective ED validation):** 426 of 435 enrolled were analysed.
  - Sensitivity 54.3% (95% CI 46.9–61.8) and specificity 89.7% (86.0–93.5).
  - AUROC 0.79 for men and 0.74 for women. Accuracy 75.4%.
  - Bland-Altman bias was 0.10 g/dL with **LoA −4.73 to +4.93 g/dL**.
  - AUC was 0.92 at the restrictive transfusion threshold (<7 g/dL). Skin tone was not reported [PV] — [HCPLive](https://www.hcplive.com/view/smartphone-app-accurate-anemia-detection-conjunctival-images)
- **Collings et al., PLoS One 2016 (conjunctival erythema index, compact camera, haemato-oncology):** for Hb < 110 g/L, sensitivity was 93% in training but **57% in internal validation**, with specificity 78% and 83% [PO] — [PMC4829242](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4829242/)
- **Appiahene et al. 2023:** an ML app on a public set of 710 conjunctiva images reported sensitivity 90% and specificity 95% [RETRO; dataset-internal] — [DOAJ](https://doaj.org/article/7b3241113c2440369500e4f6f8afc45c)
- **NiADA v3 (Kolkata, 2024–25):** a comparative study of 2,476 participants vs venous Hb. Headline metrics were not captured in my search. A multicentre prospective trial (AnemiAI, NCT07678762) is active and not recruiting, with no results yet — [PMC12367197](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12367197/); [Tundra Space listing](https://tundraspace.com/directory/studies/nct07678762)
- A 2020 systematic mapping study described the field as very active but heterogeneous, and I found no completed meta-analysis — [Uniba repository](https://ricerca.uniba.it/handle/11586/307490)
- **Smartphone Hb (Marquette dissertation, Aziz):** n = 167, MAPE 5% vs lab Hb, not dengue-specific [PILOT/thesis] — [Marquette ePublications](https://epublications.marquette.edu/dissertations_mu/1591/)
- **Dengue Hct context:** serial Hct is the guideline tool for tracking plasma leakage, but "the precise relationship between haematocrit values and vascular leakage remains unclear". Venepuncture carries bleeding risk in thrombocytopenia — [Lyle et al. PLOS Digit Health 2025, PMC12273927](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12273927/)
- **Multi-wavelength PPG (lab-grade wearable, not phone) for Hct in dengue (Imperial thesis):** correlation > 0.7 between PPG features and changes in invasive Hct in 83% of suitable patients, and CNN severe-vs-uncomplicated accuracy 0.76 [PILOT/thesis] — [Imperial Spiral](https://spiral.imperial.ac.uk/entities/publication/c0b721d6-4ac4-44b1-a2ff-0e0ffbe8986a)
- **OUCRU D-SCAPE:** the first bespoke PPG wearable prototype "tracked haematocrit trends that aligned with lab results", and a v3 device is planned for larger validation. This is a project-page claim, not peer-reviewed — [OUCRU D-SCAPE](https://www.oucru.org/project/75dx/)

### Inferences
- Taking the 2024 PV study's LoA of about ±4.8 g/dL for Hb, the implied Hct uncertainty is about ±14 percentage points (using Hct ≈ 3 × Hb, an approximation). A clinically meaningful dengue Hct rise of ~20% from baseline cannot be resolved by current conjunctival methods. Conjunctival pallor/redness features should be framed as exploratory correlates, not Hct surrogates.
- Within-subject trending against the patient's own baseline is the only plausible route to Hct-trend signals. It would require fixed capture geometry, colour calibration (Section 5) and paired lab Hct for validation.
- Platelet count cannot be estimated optically from surface images. At most, bleeding manifestations (petechiae, conjunctival/gum haemorrhage) can be documented.

### Gaps
- I found no study of smartphone estimation of **haematocrit** or **platelet count** in any population.
- I could not locate primary validation figures for "Eyenaemia" or the "Selfie Anemia" app (Dimauro/Suner were not confirmed in results).
- NiADA v3's headline accuracy was not retrieved.
- Skin-tone and eyelid-pigmentation effects on conjunctival methods have not been systematically reported.

## 3. Published work on camera/smartphone or wearable dengue detection, severity, plasma leakage, petechiae, tourniquet test, facial/tongue AI

### Takeaway
There is **no peer-reviewed, clinically validated smartphone-camera method for dengue detection or severity**. The serious evidence is from OUCRU/Imperial wrist/finger PPG wearables in hospitalised Vietnamese patients. That work is prospective, single-centre and with modest performance: shock AUROC 0.72 and AUPRC 0.15, and severity with clinical data AUROC 0.83. Rash/petechiae, fingertip-video and tongue-image dengue claims are student projects, datasets or nonexistent.

### Cited Findings
- **Kenyon/Imperial–OUCRU, npj Digital Medicine Nov 2024 ("Predicting deterioration in dengue using a low cost wearable"):** a prospective observational study at the Hospital for Tropical Diseases, HCMC, Jan 2020 – Oct 2022.
  - Of 250 enrolled, 153 were analysed (132 train / 21 hold-out). 96/152 had severe dengue, and the dataset covered 1,353 h.
  - Device: SmartCare wrist unit with transmissive finger probe, red/IR PPG at 100 Hz, ~USD 100, ~18 h battery.
  - **2-h-ahead shock:** AUROC 0.72 ± 0.03, AUPRC 0.15 ± 0.03 (prevalence 10.4%), precision 0.16, recall 0.97.
  - **Low-risk state (NEWS2 < 6 and mSOFA < 6):** PPG-only AUROC 0.58. **PPG + clinical data AUROC 0.83 ± 0.07, AUPRC 0.67 ± 0.12.**
  - Only ~43% of recorded data was usable. 38.8% of enrolled patients were excluded for PPG quality or data availability. Vital-sign ground truth was recorded only every 1–6 h. NEWS2/mSOFA are not dengue-validated. Outpatients were not studied, and clinicians were uncertain of the device's added value [PO] — [PMC11531560](https://pmc.ncbi.nlm.nih.gov/articles/PMC11531560/)
- **Lyle et al., PLOS Digital Health 2025;4(7):e0000924 (volume status from wearable PPG, same cohort):** 90 patients analysed (16 in an "empty" state).
  - A vision transformer reached sensitivity 0.81 and specificity 0.70 for "empty" (2 h pre-shock) vs "full" (post-fluid) states. Random forest reached ~67% accuracy, with the LF/HF ratio and mean HR as top features.
  - Only ~13% of 20-s segments passed quality filtering. The cohort was single-centre with homogeneous ethnicity and skin tone, and labels were retrospective and imprecise.
  - **Absolute-amplitude features were excluded to reduce artefact and skin-tone bias** [PO, small] — [PMC12273927](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12273927/)
- Trieu et al. (2022): a proprietary PPG compensatory reserve index predicted recurrent shock in DSS before hypotension (cited within the papers above) — [PMC12273927](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12273927/)
- Karolcik et al.: a multi-site PPG platform / commercial wearable for risk stratification in Vietnamese dengue — [DOAJ](https://doaj.org/article/cb4b3c9ceff44b998ac19afd183c2091)
- **OUCRU D-SCAPE** (LifeArc-funded; PIs Yacoub, Trieu, Chanh, Georgiou) is building a bespoke dengue PPG wearable — [OUCRU](https://www.oucru.org/project/75dx/)
- A UKRI-funded low-cost PPG sensor module aims to predict dengue complications — [UKRI GtR](https://gtr.ukri.org/project/49E62113-1A90-4ACA-9E72-0217C24E1DD9)
- **Smartphone fingertip-video dengue dataset (IEEE DataPort):** 170 participants (90 normal, 80 dengue). It is a dataset with no peer-reviewed clinical validation found — [IEEE DataPort](https://ieee-dataport.org/node/14339)
- **"DengueScreen" rash-image CNN (Society for Science high-school abstract):** 300 dermatological images and 99.62% accuracy. Not clinically validated, almost certainly overfit [PILOT] — [Society for Science abstract](https://abstracts.societyforscience.org/Home/PrintPdf/25639)
- **Singapore retinal imaging:** retinal vessel characteristics differ in severe dengue, using a specialised retinal camera rather than a smartphone — [HealthXchange SG](https://www.healthxchange.sg/news/researchers-eye-new-way-to-detect-dengue)
- A 2016 smartphone reader for dengue antibody assay images (an RDT reader, not physiological imaging) — [RSC Analytical Methods 2016](https://pubs.rsc.org/en/Content/ArticleLanding/2016/AY/C6AY01262K)
- **Tongue-image AI:** deep-learning tongue studies target TCM syndromes or general multi-disease labels, e.g., VGG-19 + RF at 93.7% across 11 classes (preprint). **No dengue or infectious-fever tongue study was found** — [Preprints.org 202404.0565](https://www.preprints.org/manuscript/202404.0565); [Digital Health 2023 survey](https://doaj.org/article/ed0c0757e3614b99a0b95ff3559eb933)

### Inferences
- The best dengue-specific evidence uses **contact, transmissive red/IR PPG at 100 Hz**, which is a far stronger signal than reflectance face rPPG at 30 fps. Even so, PPG alone gave a severity AUROC of only 0.58, and performance depended on clinical data. Face-video-only deterioration prediction should be expected to perform worse until shown otherwise.
- DengueSense's face/conjunctiva/tongue data would be **novel** for dengue. That supports framing it as a hypothesis-generating research dataset, not a validated tool.
- Petechiae and positive tourniquet tests are non-specific. Image documentation of them is plausible, but no automated tourniquet-test or petechiae-counting validation was found.

### Gaps
- I found no published automated **tourniquet test** or **capillary refill time** smartphone studies in dengue. CRT smartphone work exists in other contexts but was not searched in depth.
- I found no facial-colour or conjunctival-redness study in dengue.
- No external (multi-site) validation of the OUCRU wearable models has been published yet.

## 4. Dengue clinical background and what claims are defensible

### Takeaway
Dengue diagnosis requires laboratory confirmation by NS1/RT-PCR early, then IgM. Severity is triaged on clinical warning signs plus lab Hct/platelet trends. A camera cannot detect virus, NS1 or antibodies, so it can never "diagnose" dengue. Defensible claims are limited to (a) research-grade vital-sign and visual-sign capture, (b) trend monitoring adjunctive to clinical care, and (c) eventually, deterioration-risk triage validated against outcomes such as shock.

### Cited Findings
- **WHO 2009 classification:** dengue without warning signs, dengue with warning signs, and severe dengue.
  - Warning signs are abdominal pain, persistent vomiting, clinical fluid accumulation, mucosal bleeding, lethargy, hepatomegaly > 2 cm, and **an increase in Hct concurrent with a rapid decrease in platelet count**.
  - WHO recommended hospitalisation for observation for any warning sign — [BMC Infect Dis 2013;13:498](https://bmcinfectdis.biomedcentral.com/track/pdf/10.1186/1471-2334-13-498)
- Lab confirmation in that cohort was by RT-PCR or NS1 strip — [BMC Infect Dis 2013](https://link.springer.com/doi/10.1186/1471-2334-13-498)
- **Testing windows:** in days 0–7 of illness, NAAT + IgM or NS1 + IgM. After day 7, IgM is primary. The critical phase begins with plasma leakage around defervescence and lasts ~24–48 h — [Kansas KDHE Dengue Investigation Guideline](https://www.kdhe.ks.gov/DocumentCenter/View/7215/Dengue-Disease-Investigation-Guideline-PDF)
- PAHO describes RT-PCR as rapid, sensitive and reproducible, and NS1 ELISA as highly sensitive — [PAHO Dengue](https://www.paho.org/en/dengue)
- The DSS ground truth itself is clinical and can be modified by treatment, which complicates any label for deterioration models — [PMC11531560](https://pmc.ncbi.nlm.nih.gov/articles/PMC11531560/)
- Most Vietnamese dengue cases are outpatients, but the wearable evidence comes only from inpatients — [PMC11531560](https://pmc.ncbi.nlm.nih.gov/articles/PMC11531560/)

### Inferences
- **Diagnosis/screening claim (consumer "do I have dengue?"):** indefensible. Fever with rash, petechiae or tachycardia is shared with chikungunya, Zika, COVID-19, influenza, leptospirosis and others. No camera study shows discrimination, and the IEEE fingertip dataset and the student rash CNN do not count.
- **Defensible RUO claims:**
  - Standardised capture of rPPG HR, facial, conjunctival and tongue images.
  - Exploratory association with lab Hct, platelets and WHO warning signs.
  - Signal-quality-gated HR trend.
- **Possible future regulated claim (needs prospective multi-site validation with skin-tone stratification):** "an adjunct to clinician monitoring that flags rising HR/perfusion change trends during days 3–7, prompting earlier clinical review and lab tests". Any consumer self-screening mode should at most direct users to seek testing based on symptoms and warning-sign questionnaires. Camera-derived outputs should not serve as reassurance, since false negatives are the main harm.
- In Malaysia, a consumer screening or diagnostic claim would make the app a medical device (MDA registration), with SaMD clinical-evidence expectations. This regulatory point comes from general knowledge and is not sourced here; see Gaps.

### Gaps
- I did not retrieve the WHO 2009 / 2012 / 2024 guideline documents directly. Warning-sign wording comes from secondary sources.
- The Malaysian MDA SaMD classification for this use case was not researched here.

## 5. Image-science constraints: colour calibration, illuminant, glare, tongue standardisation, ambient light and 50 Hz flicker

### Takeaway
Uncalibrated smartphone skin colour is clinically unusable (ΔE ≈ 7–8 vs reference). Per-device ColorChecker colour-correction matrices cut error by roughly 65–77%, typically to ΔE ≈ 2–4. However, derived skin indices (e.g., ITA) can still disagree across devices ("colour-clinical decoupling"), so the app must lock camera settings, include a reference target in frame, and validate biomarkers per device. Malaysian 50 Hz mains produces 100 Hz flicker. At exactly 25/50 fps it locks in phase, but at 30 fps it aliases (100 mod 30 = 10 Hz, which folds to 10 Hz) and with exposure-time beating can create low-frequency banding. The safest mitigation is exposure times that are integer multiples of 10 ms.

### Cited Findings
- **Kang (arXiv 2512.21988, 2025, Korean facial skin, multi-device) [PILOT/preprint]** — [arXiv 2512.21988](https://arxiv.org/html/2512.21988v2)
  - Raw images showed mean ΔE 6.99 (smartphone) and 8.26 (tablet) vs DSLR, with **0%** of images meeting ΔE < 2.
  - A linear CCM reduced error by 67–77%.
  - Even after calibration, **ITA inter-device ICC was 0.46 (poor) while the melanin index ICC was 0.77 (good)**. The authors call this "colour-clinical decoupling"; region-specific calibration improved reliability.
- **Teledermoscopy with ColorChecker (canine skin):** per-phone calibrated ΔE was 1.8–6.6 (CIE76) or 1.1–4.5 (CIE94). Intra-phone variability was ΔE 0.1 and inter-phone variability 2.0–3.9, so per-device models were needed [PILOT] — [PMC7662536](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7662536/)
- **Dermatology imaging across devices:** significant colour discrepancies between phones, DSLRs and mirrorless cameras, worsened by inadequate lighting — [PMC12027704](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12027704/)
- **Viewing angle and lighting:** ΔE rose by up to 64% at oblique angles, and chart-based matrix correction reduced inter-device and lighting variation by 65–70% — [Strathprints 93830](https://strathprints.strath.ac.uk/id/eprint/93830)
- **TCM tongue imaging:** generalisation fails mainly because of poor colour reproducibility and non-standard capture. A TDA-1 device with TIFF output and ICC-profile correction made objective tongue-colour classification feasible [PO] — [PMC5168476](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5168476/)
- Kernel PLS tongue colour correction reached a mean ΔE of 0.821 per patch, beating polynomial and SVR baselines — [BJUT repository](https://ir.bjut.edu.cn/item/3288)
- A two-phase deep colour correction network (TDCCN) maps tongue images to standard illuminant values — [Applied Sciences 2020](https://doaj.org/article/3f2ef4e92fa349c8af54d2f8ea5f602d)
- A complete tongue pipeline combines a fixed-environment hardware device, U2-Net segmentation, a colour-correction module and feature fusion — [Frontiers Physiol 2025](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2025.1559389/full)
- A tongue-image-quality CNN can gate captures — [PMC8097848](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8097848/)
- A 2021 review covers tongue acquisition hardware, segmentation, colour correction and classification — [PMC10388765](https://pmc.ncbi.nlm.nih.gov/articles/PMC10388765)
- **Smartphone PPG cross-device consistency:** camera parameters and component differences interfere with PPG consistency across devices — [JMIR mHealth 2021](https://mhealth.jmir.org/2021/4/e16806/PDF)
- **Flicker physics:**
  - Mains-driven lamps flicker at twice the supply frequency (100 Hz for 50 Hz mains).
  - Frame rates that divide the flicker frequency (50, 25 fps for 100 Hz) lock the flicker phase, so it becomes a static offset.
  - Non-divisor rates produce rolling bands. At low frame rates the flicker aliases into slow beats, e.g., a band every 5–6 frames at 15 fps.
  - Exposure times that are integer multiples of the flicker period suppress it.
  - Under fast shutter, flicker is non-sinusoidal and harder to model — [US Patent 10104309](https://patents.google.com/patent/US10104309); [US20050157203A1](https://patents.google.com/patent/US20050157203A1/ko); [USPTO 7248289](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7248289)
- rPPG papers list flickering room lights, screen reflections and mains-frequency noise as interferers, and propose subtracting a background (non-skin) ROI signal — [HKU Optima paper](https://www.eee.hku.hk/optima/pub/journal/2606_CH.pdf); [USPTO 9615749](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9615749)

### Inferences (iOS capture design requirements)
- **Lock everything after a metering pass:**
  - Use AVCaptureDevice to lock exposure, ISO, white balance (`setWhiteBalanceModeLocked` with fixed gains), and focus.
  - Disable HDR/Smart HDR/Deep Fusion, video stabilisation crops and tone-mapping.
  - Capture RAW/ProRAW (DNG) for still conjunctiva and tongue frames.
  - For video, use the highest-bit-depth, least-processed format (e.g., 10-bit HEVC or BGRA without filters) and log all camera metadata.
- **Flicker for 50 Hz Malaysia:**
  - Set exposure duration to 10 ms or 20 ms (a multiple of 1/100 s), so each frame integrates whole flicker cycles.
  - Run at 30 fps if needed: with 10 ms exposure, residual flicker is mostly cancelled.
  - Alternatively, capture at 25/50 fps, where flicker is phase-locked.
  - Add a background-ROI or spectral notch check for 10 Hz aliased components, which sit outside the 0.7–3.5 Hz HR band but can leak via harmonics and beat with LED PWM drivers. PWM LEDs at arbitrary frequencies can alias into the HR band.
  - Compute a flicker-detection metric before accepting a recording.
- **Colour:**
  - Put a small reference card (ColorChecker Nano/Passport or a custom matte card with skin-relevant patches plus neutral greys) in frame for every conjunctiva and tongue capture.
  - Fit a per-capture CCM, and report residual ΔE00 as a QC metric (e.g., reject if > 3–4).
  - Because of colour-clinical decoupling, also validate the derived features (pallor index, redness, tongue colour class) per device model.
- **Glare/specular:** use cross-polarisation where hardware allows; otherwise use multi-frame specular masking, since the tongue and moist conjunctiva are highly specular. Avoid the flash torch for colour, or always use it so the illuminant is fixed and known.
- **Skin tone:** record Monk/Fitzpatrick (and ideally a colorimeter-measured ITA or melanin index) for every participant so bias can be audited. Prefer melanin index over ITA (better cross-device ICC).
- **Lighting floor:** enforce a minimum scene luminance and a maximum ISO via a pre-capture gate. Low light reduces pulsatile amplitude below the noise floor, especially for darker skin.

### Gaps
- I found no rPPG study that specifically quantifies 50/60 Hz mains-flicker error. The flicker guidance is derived from camera-engineering patents and physics, not rPPG trials.
- I found no published ΔE benchmark for current iPhone models (ProRAW vs processed) with ColorChecker on skin, conjunctiva or tongue.
- I found no published cross-polarised smartphone conjunctiva or tongue protocol with validation data.
- I found no standard ΔE acceptance threshold for clinical skin imaging beyond the ΔE < 2 benchmark cited by Kang.
