# Regulatory and App-Distribution Constraints: DengueSense iOS Camera Capture App (reAInmaker SDN BHD, Malaysia)

Research date: 13 Oct 2026. Malaysia is the primary jurisdiction; FDA and EU are comparators. Every fact below has an inline source. Anything from background knowledge that I could not verify this session is labelled as such under Inferences or Gaps.

---

## Q1. Apple App Store Review Guidelines: which rules apply to a camera-based dengue assessment app

### Takeaway
Guideline 1.4.1 is the main obstacle for a consumer "scan to detect dengue" mode. Apple rejects health-measurement claims based only on device sensors when accuracy cannot be validated, and asks for proof of regulatory clearance. Guidelines 5.1.1(ix) and 5.1.3 require the app to be submitted by a legal entity (reAInmaker SDN BHD, not an individual), to collect research consent with specified elements, and to have independent ethics board approval that can be produced on request.

### Cited Findings
- **1.4.1 (verbatim):** "Medical apps that could provide inaccurate data or information, or that could be used for diagnosing or treating patients may be reviewed with greater scrutiny." — [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **1.4.1:** "Apps must clearly disclose data and methodology to support accuracy claims relating to health measurements, and if the level of accuracy or methodology cannot be validated, we will reject your app. For example, apps that claim to take x-rays, measure blood pressure, body temperature, blood glucose levels, or blood oxygen levels using only the sensors on the device are not permitted." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **1.4.1:** "Apps should remind users to check with a doctor in addition to using the app and before making medical decisions. If your medical app has received regulatory clearance, please submit a link to that documentation with your app." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **2.5.1:** apps must use APIs for their intended purposes; "HealthKit should be used for health and fitness purposes and integrate with the Health app." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **2.5.14:** "Apps must request explicit user consent and provide a clear visual and/or audible indication when recording, logging, or otherwise making a record of user activity. This includes any use of the device camera…" — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.1(ix):** apps in highly regulated fields "(such as… healthcare…) or that require sensitive user information should be submitted by a legal entity that provides the services, and not by an individual developer." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.2(i):** the app must obtain permission before using or sharing personal data, and must "clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before doing so." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.2(vi):** data from HealthKit, or from "depth and/or facial mapping tools (e.g. ARKit, Camera APIs, or Photo APIs) may not be used for marketing, advertising or use-based data mining, including by third parties." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.3(i):** data gathered in a health research context, including "health-related human subject research", may not be used for advertising or data mining other than to improve health management or for health research, "and then only with permission". The app "must disclose the specific health data that you are collecting from the device." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.3(ii):** apps must not write false or inaccurate data into HealthKit, and "may not store personal health information in iCloud." — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.3(iii):** research consent must cover "(a) nature, purpose, and duration of the research; (b) procedures, risks, and benefits to the participant; (c) information about confidentiality and handling of data (including any sharing with third parties); (d) a point of contact for participant questions; and (e) the withdrawal process." For minors, consent comes from a parent or guardian. — [Apple](https://developer.apple.com/app-store/review/guidelines/)
- **5.1.3(iv):** "Apps conducting health-related human subject research must secure approval from an independent ethics review board. Proof of such approval must be provided upon request." — [Apple](https://developer.apple.com/app-store/review/guidelines/)

### Inferences
- **Hospital RUO mode.** For distribution through TestFlight external testing or the App Store, Apple will expect the following:
  - The MREC approval letter, which satisfies 5.1.3(iv).
  - An in-app consent flow, or a documented paper consent process, that covers elements (a) to (e).
  - App Store Connect metadata stating "investigational / research use only, not for diagnosis".
  - No HealthKit write-back of outputs, and no storage of photos or results in iCloud.
  - Camera-in-use indicators (2.5.14).
- **Consumer "scan to detect dengue" mode.**
  - Apple's examples of prohibited sensor-only measurements (blood pressure, SpO2, temperature, glucose) do not name dengue. However, dengue inference from camera images (for example skin, petechiae, conjunctival pallor, or rPPG vitals) is a health measurement whose accuracy has to be validated.
  - In practice Apple will ask for a regulatory clearance link (MDA registration, FDA 510(k)/De Novo, or CE certificate) together with published validation data. Without them, rejection under 1.4.1 is the likely outcome.
  - If any vital-sign estimate (heart rate, SpO2, temperature) is shown to consumers, the explicit "not permitted" examples apply. Showing SpO2 or blood pressure without clearance is a high-risk choice.
- **Third-party AI.** If images are sent to a cloud AI model (including any third-party LLM or vision API), the explicit consent rule for "third-party AI" in 5.1.2(i) applies.

### Gaps
- I did not see Apple's last-updated date for the guidelines because the fetched text was truncated. The version numbering should be checked on the live page.
- I found no documented public precedent of an App Store rejection for a specific camera-based vital-sign or diagnostic app. Third-party cleared SDKs (Presage, PanopticAI; see Q6) suggest that cleared camera vital-sign apps do get approved, but I found no source that confirms their App Store review history.

---

## Q2. Ways to distribute an investigational app to clinical study sites (TestFlight, Ad Hoc, custom apps, Enterprise, unlisted)

### Takeaway
TestFlight is the simplest compliant route for a multi-site Malaysian study. It allows up to 10,000 external testers, but each build expires after 90 days, so a release cadence of rebuilding at least every 90 days is needed. The first build sent to external testers goes through Beta App Review, where the 5.1.3 ethics-approval requirement can be raised. reAInmaker almost certainly cannot use the Enterprise Program: it requires 100 or more employees and is a last resort that Apple grants only when the App Store, custom apps, Ad Hoc and TestFlight cannot meet the need.

### Cited Findings
- **TestFlight testers:** up to 10,000 external testers, and up to 100 internal testers (App Store Connect users). — [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- **TestFlight build expiry:** "You can test a build for up to 90 days… Your build becomes unavailable for testers after 90 days." — [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- **Beta App Review:** when the first build is added to an external group, "the build gets sent to App Review to make sure it follows the App Review Guidelines. A review is required only for the first build. Subsequent builds may not require a full review." — [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- **TestFlight public links:** public links can carry criteria that limit who can join as an external tester. — [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- **Enterprise Program purpose:** it is "only for the internal use and distribution of proprietary apps in specific use cases that are not adequately addressed with public apps on the App Store, custom apps through Apple Business Manager or Ad Hoc distribution, or beta testing through TestFlight." — [Apple Developer Enterprise Program](https://developer.apple.com/programs/enterprise/enroll/)
- **Enterprise Program eligibility:**
  - 100 or more employees.
  - A legal entity; DBAs, trade names and branches are not accepted.
  - A D-U-N-S Number.
  - A public website on the organisation's own domain.
  - A separate Apple Account from the one used for App Store distribution.
  - Source: [Apple Developer Enterprise Program](https://developer.apple.com/programs/enterprise/enroll/)
- **Enterprise apps for employees only:** a third-party summary says enterprise apps may be distributed only to the organisation's own employees, and that controls must restrict downloads to employees. — [MacPaw summary](https://macpaw.com/how-to/apple-developer-enterprise-program)

### Inferences
- **Recommended study set-up:**
  - Use an organisation Apple Developer Program account in the name of reAInmaker SDN BHD (needs a D-U-N-S Number, consistent with 5.1.1(ix)).
  - Use TestFlight external groups per hospital site, with the MREC approval letter attached in the Beta App Review notes.
  - Use MDM-managed, study-owned iPhones, so device model and camera hardware are controlled. This matters for algorithm validity.
- **The 90-day TestFlight build limit conflicts with protocol design freeze.** The usual mitigations are:
  - Re-upload the identical locked algorithm version with a new build number every 90 days or less.
  - Document in the protocol that a build number change with no algorithm change is not a protocol amendment.
- **Enterprise is effectively unavailable.** The employee-only restriction also means that hospital clinicians, who are not reAInmaker employees, could not lawfully receive an enterprise-signed app.
- **Custom apps through Apple Business Manager** (private distribution to specific organisations, such as each hospital's Apple Business Manager account) are a reasonable fit for a longer post-study or clinician-only deployment, but they still require full App Review (1.4.1 applies). The following come from background knowledge and were **not verified** this session:
  - Ad Hoc distribution is limited to 100 registered devices per device type per membership year.
  - Unlisted App Store apps also go through full review.

### Gaps
- I did not fetch Apple's pages on custom apps, unlisted apps, or Ad Hoc limits. These should be verified at developer.apple.com/custom-apps and developer.apple.com/support/unlisted-app-distribution.
- ResearchKit was not researched this session. It is an open-source framework that provides consent and survey modules and could support the 5.1.3(iii) consent flow, but I did not source it.

---

## Q3. Malaysia: Medical Device Act 2012 (Act 737), MDA classification of SaMD, and the clinical-research exemption

### Takeaway
Under Act 737, a medical device must be registered (s.5) before it can be placed on the market. Use in clinical research is exempt from registration under the **Medical Device (Exemption) Order 2024** (P.U.(A) 78/2024, in force 5 or 6 March 2024). For some categories this order moved from notification to an exemption **application** through the MDA's Medcast system, with an administrative fee. MDA/GD/0016 (2017) describes how a No Restriction Letter permits supply of an unregistered device for clinical research or performance evaluation. MDA does not appear to have a standalone SaMD classification guidance. Classification follows the First Schedule rules, as elaborated in MDA/GD/0009, the definition guidance MDA/GD/0006 (2nd ed., 30 Mar 2026) and the product-classification guideline MDA/GL/06 (5th ed., Nov 2025). MDA ran a dedicated SaMD/AI training course in July 2025.

### Cited Findings
- **Exemption Order 2024:**
  - It replaced the 2016 Order and took effect on 5 March 2024 (MDA announcement); Skrine says 6 March 2024.
  - Clinical research is one of the exemption categories.
  - Applications go through the Medcast Online System or a Google Form, with an administrative fee.
  - Sources: [MDA announcement](https://portal.mda.gov.my/index.php/industry/exemption/announcement); [Skrine](https://www.skrine.com/insights/alerts/march-2024/government-issues-new-medical-device-exemption-ord)
- **Move from notification to application:**
  - Several categories that previously needed only notification now need an application for exemption.
  - Exemptions granted under the 2016 Order remain in force.
  - Sources: [Skrine](https://www.skrine.com/insights/alerts/march-2024/government-issues-new-medical-device-exemption-ord); [RAPS discussion](https://connect.raps.org/discussion/malaysia-promulgated-medical-device-exemption-order)
- **MDA definition of clinical research:** "any systematic investigation or study that determines the safety and effectiveness of… devices, diagnostic products… in or on one or more human subjects". The MDA clinical research page links to the Medcast notification form and a device study (DS) notification guide. — [MDA Clinical Research page](https://portal.mda.gov.my/index.php/industry/exemption/clinical-research-performance-evaluation)
- **MDA/GD/0016 (April 2017), "Notification for Clinical Research or Performance Evaluation":**
  - It covers all classes of unregistered medical devices, excluding IVDs used on human specimens.
  - An MDA-issued No Restriction Letter permits lawful supply for the specific defined use.
  - Source (via search summary): [MDA/GD/0016](https://portal.mda.gov.my/index.php/documents/guideline-documents/556-mdagd0016-notification-for-clinical-research-or-performance-evaluation/file)
- **Review timelines (secondary source, undated practice):**
  - Investigational-use device notifications go to the Technical Committee of Medical Device Clinical Evaluation, and the No Restriction Letter is issued about 7 working days after committee evaluation.
  - The non-investigational route takes about 14 working days.
  - Another secondary source cites about 30 working days for investigational use.
  - Sources: [ClinicalResearch.my](https://clinicalresearch.my/establishing-clear-procedures-and-improving-start-up-timeline-in-malaysias-clinical-research-ecosystem/); [Journal for Clinical Studies](https://journalforclinicalstudies.com/?p=24841)
- **Classification guidance:** MDA/GD/0009 "Classification of General Medical Device" (2nd ed., 1 Apr 2022) elaborates the First Schedule classification rules of the Medical Device Regulations 2012. — [MDA/GD/0009](https://portal.mda.gov.my/index.php/doclink/mda-gd0009-classification-of-general-medical-device-2nd-edition-pdf/eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJtZGEtZ2QwMDA5LWNsYXNzaWZpY2F0aW9uLW9mLWdlbmVyYWwtbWVkaWNhbC1kZXZpY2UtMm5kLWVkaXRpb24tcGRmIiwiaWF0IjoxNzAzNzUzNTI4LCJleHAiOjE3MDM4Mzk5Mjh9._LoyHEhSTtqwGJoFQ4nKc5Nu7P5nvdTU_7mrfTIOhYo)
- **MDA guidance index:** it lists MDA/GD/0006 "Definition of Medical Device", 2nd ed., 30 March 2026. — [MDA guidance list](https://www.mda.gov.my/index.php/doc-list/guidance-document)
- **Product classification guideline:** MDA/GL/06, 5th ed. dated November 2025, is used to decide borderline products (whether a product is a medical device at all). — [MDA/GL/06 5th ed.](https://mda.gov.my/index.php/documents/ukk/3918-gd-of-product-classification-5th-ver-2025/file)
- **SaMD training:** MDA ran "Fundamentals of Software as a Medical Device (SaMD)" in Cyberjaya on 24 July 2025. It covered the SaMD definition, SaMD vs SiMD, risk classification of SaMD and AI-based devices, software validation, and post-market surveillance. — [MDA announcement](https://portal.mda.gov.my/index.php/announcement/1584-youre-invited-to-our-upcoming-training-session-fundamentals-of-software-as-a-medical-device-samd)
- **Fees:** the RM 300 fee found applies to the special-access and custom-made exemption categories. I found no confirmed fee for clinical research. — [MDA Special Access](https://www.mda.gov.my/index.php/industry/exemption/special-access-medical-device)

### Inferences
- **Does RUO capture need MDA involvement?** If the study app only captures images and data, and no output is shown to clinicians or used to manage patients, it may arguably not meet the device definition during the study. However, the software is intended to become a diagnostic device, and the study evaluates its performance, so it falls within MDA's "clinical research / performance evaluation" scope. The safe course is to file the clinical-research exemption application through Medcast, alongside the MREC application, and obtain a No Restriction Letter. Confirm with MDA whether a "capture only, results blinded from clinicians" design needs it.
- **Likely Malaysian class for a commercial product.** Malaysia's rules follow the GHTF/ASEAN Medical Device Directive risk-based scheme. On that basis (background knowledge, **not verified** this session):
  - Software that drives diagnosis of a potentially serious acute infection such as dengue, or that predicts deterioration to severe dengue, would most likely be **Class B or C**.
  - Class C is more likely where a missed severe-dengue warning could lead to death or serious deterioration.
  - Classes B to D require conformity assessment by an MDA-registered Conformity Assessment Body (CAB) before registration through MeDC@St, plus a local Authorised Representative and an establishment licence. reAInmaker, as a Malaysian manufacturer, would hold the licence itself.

### Gaps
- I could not extract the full text of MDA/GD/0016; PDF parsing failed. I therefore did not confirm the required document list, fees, labelling ("for clinical research only"), adverse-event reporting duties, or whether GD/0016 has been revised after the 2024 Order.
- I did not obtain the exact First Schedule rule text that applies to standalone software. I found no MDA-specific SaMD/AI guidance document; there may be one, and the MDA guidance index should be checked.
- I found no source for registration costs, CAB costs, or total timelines for Class B/C registration.

---

## Q4. NMRR registration and MREC ethics approval

### Takeaway
Studies in Ministry of Health facilities must be registered in the NMRR and approved by MREC. Registration and ethics approval are separate requests that produce separate identifiers. Ethics review takes roughly 50 business days, with MDA regulatory review running in parallel (about 30 business days), and planning guidance advises submitting 4 to 6 months before data collection.

### Cited Findings
- **NMRR's role:** NMRR is the online gateway that routes applications to MREC. Registration and ethics approval are separate steps with distinct identifiers. — [CASRAI NMRR guide](https://www.casrai.org/guides/nmrr-malaysia-national-medical-research-register)
- **Review timelines:** regulatory and ethics submissions run in parallel. Regulatory approval takes about 30 business days and MREC ethics approval about 50 business days. — [ClinicalResearch.my](https://clinicalresearch.my/establishing-clear-procedures-and-improving-start-up-timeline-in-malaysias-clinical-research-ecosystem/)
- **Lead time:** submit to NMRR and MREC "at least 4-6 months prior to study data collection" (guidance for studies in MOH facilities). — [UKM/MOH Masters research guideline](https://www.ukm.my/spsfper/wp-content/uploads/2025/07/GUIDELINES-ON-MASTERS-CLINICAL-RESEARCH-CONDUCTED-IN-THE-MINISTRY-OF-HEALTH-MALAYSIA-FACILITIES.pdf)

### Inferences
- The MREC approval letter is the "independent ethics review board" proof that Apple 5.1.3(iv) requires. Keep an English copy ready for Beta App Review.
- University hospitals (for example UMMC, HUKM, HUSM) have their own institutional ethics committees. MREC covers MOH facilities. The ethics route therefore depends on the site mix. This is background knowledge and was not verified this session.

### Gaps
- I did not find official MREC fees, MREC requirements specific to device or AI studies, or current NMRR v2 timelines on nmrr.gov.my.

---

## Q5. PDPA 2010 and the Personal Data Protection (Amendment) Act 2024

### Takeaway
The amendments are now fully in force:
- **From 1 April 2025:** processors have a direct duty to comply with the security principle, the cross-border transfer rules changed, the definitions of personal and sensitive data were revised, and penalties increased.
- **From 1 June 2025:** a Data Protection Officer (DPO) must be appointed, breach notification is mandatory, and the right to data portability applies.

The Commissioner's Data Breach Notification guideline (25 Feb 2025) sets the deadlines: notify the Commissioner within 72 hours, and notify affected individuals within 7 days of that notice where significant harm is likely.

### Cited Findings
- **Phased commencement:** 1 April 2025 (processor security duty, cross-border transfer changes, revised definitions, higher penalties) and 1 June 2025 (DPO appointment, mandatory breach notification, data portability). — [Baker McKenzie](https://insightplus.bakermckenzie.com/bm/data-technology/malaysia-personal-data-protection-amendment-act-2024-to-come-into-force)
- **DPO and breach notification under the Act:**
  - Both data controllers and data processors must appoint at least one DPO.
  - The Commissioner must be notified "as soon as practicable".
  - Data subjects must be notified without unnecessary delay where a breach is likely to cause significant harm.
  - The portability right is subject to technical feasibility.
  - Sources: [Baker McKenzie](https://insightplus.bakermckenzie.com/bm/data-technology/malaysia-personal-data-protection-amendment-act-2024-to-come-into-force); [Sidley](https://www.sidley.com/en/insights/newsupdates/2024/08/important-changes-to-malaysias-data-protection-laws)
- **Breach Notification Guideline (25 Feb 2025):**
  - Notify the Commissioner no later than 72 hours.
  - Notify affected individuals no later than 7 days after the initial notification to the Commissioner.
  - Notification is triggered by "significant harm", which includes compromise of sensitive data.
  - For the Commissioner, a breach affecting more than 1,000 data subjects also triggers notification.
  - Sources disagree on when the 72-hour clock starts (when the breach occurs, or when the controller detects it).
  - Sources: [DLA Piper](https://privacymatters.dlapiper.com/2025/03/malaysia-guidelines-issued-on-data-breach-notification-and-data-protection-officer-appointment/); [CMS](https://cms.law/en/sgp/legal-updates/new-guidelines-on-mandatory-breach-notifications-under-malaysia-s-personal-data-protection-act-2010); [Securiti](https://securiti.ai/malaysia-data-protection-guidelines-dpo-appointment-and-breach-notification)
- **Consultation draft:** the earlier draft used a threshold of 500 or more affected data subjects. Check the final text on pdp.gov.my. — [Securiti](https://securiti.ai/malaysia-data-protection-guidelines-dpo-appointment-and-breach-notification)

### Inferences
- Health data and facial images are "sensitive personal data" under the PDPA (background knowledge). Processing them requires explicit consent, which aligns with the MREC consent form and Apple 5.1.3(iii).
- Facial or skin images combined with dengue status will often meet the "significant harm" test for notification. reAInmaker should have a 72-hour breach playbook and an appointed DPO.
- Cloud hosting outside Malaysia (for example AWS Singapore) falls under the amended cross-border transfer rules (s.129 as amended). Document an adequacy or safeguards basis, or keep data in Malaysian regions.

### Gaps
- I did not retrieve the text of the cross-border transfer guideline or the DPO guideline, including DPO thresholds such as data volume or whether health data triggers the requirement.
- I did not research Malaysian health-record rules specific to MOH (for example MOH data-sharing policies and the Telemedicine Act's successor provisions).

---

## Q6. Comparators: FDA SaMD / CDS / general wellness / PCCP, cleared camera vital-sign apps, IMDRF, and EU MDR Rule 11

### Takeaway
On **6 January 2026**, FDA replaced both its 2019 General Wellness guidance and its 2022 Clinical Decision Support (CDS) guidance:
- **General wellness:** non-invasive products that estimate physiologic parameters (for example BP, HR, glucose) can now be wellness products if they make no disease claims, use no clinical thresholds, and do not drive clinical action.
- **CDS:** software that analyses images or signals still fails the first non-device CDS criterion and remains a device.

A camera-based dengue tool therefore cannot qualify as non-device CDS. A dengue-specific claim also takes it outside wellness, so FDA would most likely require a De Novo (no obvious predicate) or a 510(k), with a PCCP for model updates. Comparable camera-only products have been cleared for pulse rate and respiratory rate only (PanopticAI, Presage). In the EU, Rule 11 places diagnostic decision-support software at Class IIa or higher.

### Cited Findings
- **Jan 2026 guidance:** the 2026 General Wellness guidance supersedes the 2019 version, and the 2026 CDS guidance supersedes the 2022 version. Both were issued 6 Jan 2026. — [Faegre Drinker](https://www.faegredrinker.com/en/insights/publications/2026/1/key-updates-in-fdas-2026-general-wellness-and-clinical-decision-support-software-guidance); [Covington](https://www.cov.com/en/news-and-insights/insights/2026/01/fda-issues-revised-guidance-on-general-wellness-products)
- **Non-device CDS criteria:** the four criteria still apply. Criterion 1 excludes software that "acquire[s], process[es], or analyze[s] medical images… or signal-acquisition patterns or signals". Software that relies on image analysis or real-time predictions, or that effectively drives diagnosis, remains under FDA oversight. — [Faegre Drinker](https://www.faegredrinker.com/en/insights/publications/2026/1/key-updates-in-fdas-2026-general-wellness-and-clinical-decision-support-software-guidance)
- **New CDS enforcement discretion:** FDA will exercise enforcement discretion when software gives a single clinically appropriate recommendation and the other criteria are met. — [Faegre Drinker](https://www.faegredrinker.com/en/insights/publications/2026/1/key-updates-in-fdas-2026-general-wellness-and-clinical-decision-support-software-guidance)
- **Wellness and non-invasive sensing:**
  - The product must be intended solely for wellness, be low risk, and have consistent labelling and marketing.
  - Notifications may suggest professional evaluation only if they do not reference specific diseases or diagnostic thresholds.
  - Disease references move a product out of the wellness category.
  - Sources: [Faegre Drinker](https://www.faegredrinker.com/en/insights/publications/2026/1/key-updates-in-fdas-2026-general-wellness-and-clinical-decision-support-software-guidance); [Ropes & Gray](https://www.ropesgray.com/en/insights/alerts/2026/01/fda-adapts-with-the-times-on-digital-health-updated-guidances-on-general-wellness-products)
- **Enforcement risk:** a 2025 FDA warning letter to WHOOP shows the risk when wellness products drift toward "medical-grade" positioning. — [Jones Day](https://www.jonesday.com/en/insights/2026/01/a-relaxing-2026-fda-updates-general-wellness-and-clinical-decision-support-software-guidance)
- **PCCP final guidance:** "Marketing Submission Recommendations for a Predetermined Change Control Plan for AI-Enabled Device Software Functions" was finalised in early December 2024 (sources say 3 or 4 Dec).
  - Components: data management, retraining, performance evaluation, and update procedures including transparency and real-world monitoring.
  - Usable in 510(k), De Novo and PMA submissions, but not in a Special 510(k).
  - Sources: [Foley](https://www.foley.com/insights/publications/2025/01/fda-final-guidance-ai-device-software-predetermined-change-control-plan/); [Ropes & Gray](https://ropesgray.com/en/insights/alerts/2024/12/fda-finalizes-guidance-on-predetermined-change-control-plans-for-ai-enabled-device)
- **Cleared camera-based apps:**
  - **PanopticAI:** 510(k) clearance for iPhone/iPad camera pulse rate, then a second Class II clearance for respiratory rate. — [Cardiology Innovations](https://cardiologyinnovation.com/cardiology-advancements/imaging-technologies/fda-clears-mobile-app-contactless-pulse-rate-measurement/); [Respiratory Therapy](https://respiratory-therapy.com/products-treatment/monitoring-treatment/patient-monitoring-products/fda-clears-panopticai-respiratory-rate-monitoring/)
  - **Presage SmartSpectra Vital Signs Monitor 1.0 SDK:** 510(k) K254169 for contactless pulse and respiration, announced 7 Jul 2026. Other metrics are not cleared. — [PR Newswire](https://www.prnewswire.com/news-releases/presage-technologies-earns-fda-clearance-for-contactless-vital-signs-makes-them-available-for-free-302818692.html)
  - **Diitect:** claims 510(k) clearance for HR and RR, with BP "clearance pending" (vendor claim). — [Diitect](https://diitect.com/clinical-evidence)
- **Lifelight (UK):**
  - Described as a CE-marked Class IIa device for BP and pulse, and pursuing FDA clearance. — [ERGO interview Jul 2026](https://www.ergo.com/en/radar-magazine/digitalisation-and-technology/2026/lifelight-start-up-health-monitoring-blood-pressure-measurement-smartphone); [Dealroom](https://dealroom.co/companies/lifelight/)
  - An older Health Technology Wales report says CE/UKCA Class I with Class IIa pending. — [HTW TER540](https://healthtechnology.wales/wp-content/uploads/TER540-Lifelight.pdf)
- **Binah.ai and Nuralogix/Anura:** company profiles describe them as video-based health and wellness platforms (BP, HR, SpO2) delivered as SDKs. I found no FDA clearance. — [PitchBook – Binah](https://pitchbook.com/profiles/company/221632-57); [CB Insights – Nuralogix](https://www.cbinsights.com/company/nuralogix/alternatives-competitors)
- **EU MDR Rule 11:**
  - Software that provides information for diagnostic or therapeutic decisions is Class IIa.
  - It rises to IIb where a wrong decision could cause serious deterioration or surgery, and to III where it could cause death or irreversible deterioration.
  - Software that monitors physiological processes is IIa, or IIb for vital parameters where variation could create immediate danger.
  - Source: [OpenRegulatory MDCG 2019-11](https://openregulatory.com/mdcg/mdcg-2019-11)
- **MDCG 2019-11 Rev.1 (June 2025):**
  - Adds IMDRF references.
  - Extends Rule 11 to software that prevents illness, pushing predictive AI toward IIb.
  - AI medical devices may also be "high-risk AI systems" under the EU AI Act.
  - Sources: [Osborne Clarke](https://www.osborneclarke.com/insights/eu-confirms-app-stores-and-developers-are-subject-medical-device-laws); [GMP Insiders](https://gmpinsiders.com/mdcg-2019-11-rev1-mdr-ivdr/)

### Inferences
- **Claim language and likely class:**

| Claim | Malaysia | FDA | EU MDR |
|---|---|---|---|
| (a) "Wellness / general health check" with no disease named | Possibly not a device (MDA/GL/06 borderline decision) | Wellness | Not a device |
| (b) "Helps clinicians assess dengue probability / aid in diagnosis" | Likely Class B–C | Likely Class II via De Novo (no predicate) | IIa–IIb |
| (c) "Predicts deterioration / severe dengue warning signs" | Likely Class C | Class II De Novo with special controls, possibly higher | IIb |
| (d) Consumer self-screening, "scan to help detect dengue" | Highest scrutiny | Lay-user labelling raises risk; human-factors evidence (IEC 62366-1) is essential | Same as (b)/(c) |

- Option (a) is incompatible with a dengue use case: any mention of dengue, fever, or thresholds removes wellness status.
- **IMDRF SaMD framework (N12, 2014; background knowledge, not fetched):** it grades risk on two axes, the significance of the information (treat or diagnose / drive clinical management / inform clinical management) and the healthcare situation (critical / serious / non-serious). On that matrix:
  - "Drive clinical management" in a "serious" situation gives category III.
  - Dengue warning signs and deterioration could be argued as "critical", giving category IV.
- **RUO wording.** RUO should carry wording such as "Investigational device – for research use only. Not for diagnostic use. Results are not to be used for patient management." Results should be blinded from clinicians, or displayed only under the protocol. Marketing materials must not make performance claims. This is standard practice, not sourced this session.
- **Evidence for a consumer mode:**
  - A prospective, multi-site clinical performance study against RT-PCR/NS1 and serology reference standards, with sensitivity and specificity CIs and subgroups by skin tone (Fitzpatrick), age, illness day, and device model.
  - A lay-user human-factors (usability) validation.
  - Cybersecurity documentation.
  - A PCCP, or a Malaysian change-notification plan, for model updates.
  - Post-market performance monitoring.
- **Standards expected by MDA CABs, notified bodies and FDA** (background knowledge; not individually sourced this session):

| Standard | Covers |
|---|---|
| ISO 13485 | QMS; mandatory for MDA conformity assessment |
| ISO 14971 | Risk management |
| IEC 62304 | Software lifecycle; a dengue app would likely be software safety class B or C |
| IEC 62366-1 | Usability |
| IEC 81001-5-1 | Health software security lifecycle |
| IEC 82304-1 | Health software product safety |
| ISO/IEC 27001 | Information security management |
| AAMI TIR34971 / ISO 24971 | AI risk |

- **Apple security practices for this app:** use Keychain and Data Protection (NSFileProtectionComplete), keep images out of the camera roll and iCloud, use ATS/TLS, and do on-device processing where possible.

### Gaps
- I did not verify any K-numbers in the FDA 510(k) database except Presage's self-reported K254169. I found no confirmed FDA clearance for Binah.ai, Nuralogix or Philips camera vital-sign apps.
- I found no regulator-cleared smartphone app for dengue specifically, in any jurisdiction.
- I did not fetch the IMDRF N12 text or the standards' publication details.
- I did not confirm the FDA cybersecurity premarket guidance version (section 524B "cyber device" requirements).
