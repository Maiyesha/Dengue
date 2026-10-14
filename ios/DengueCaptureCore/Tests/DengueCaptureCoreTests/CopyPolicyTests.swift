import XCTest
@testable import DengueCaptureCore

final class CopyPolicyTests: XCTestCase {
    func testNoForbiddenTermInAnyNurseStringExceptTheTwoAllowlisted() {
        for s in NurseCopy.allStrings where !NurseCopy.allowlisted.contains(s) {
            XCTAssertEqual(NurseCopy.forbiddenTerms(in: s), [], "forbidden term in: \(s)")
        }
        XCTAssertEqual(NurseCopy.allowlisted, [NurseCopy.banner, NurseCopy.experimentalNotice])
        XCTAssertEqual(NurseCopy.allowlisted.count, 2)
    }

    func testLintCatchesForbiddenTermsWholeWordCaseInsensitive() {
        XCTAssertEqual(NurseCopy.forbiddenTerms(in: "This is SAFE"), ["safe"])
        XCTAssertEqual(NurseCopy.forbiddenTerms(in: "Detect  Dengue now"), ["detect dengue"])
        XCTAssertEqual(NurseCopy.forbiddenTerms(in: "Risk, result."), ["risk", "result"])
        XCTAssertEqual(NurseCopy.forbiddenTerms(in: "Unsafe safety riskless normalise"), [],
                       "stems match whole words plus listed inflections only, not substrings")
    }

    func testLintCatchesInflections() {
        let cases: [(String, String)] = [
            ("Results saved", "results"), ("Two risks", "risks"), ("positives", "positives"),
            ("diagnosed", "diagnosed"), ("diagnostic", "diagnostic"), ("diagnoses", "diagnoses"),
            ("It was negatively", "negatively"), ("Severe", "severe"), ("normally", "normally"),
            ("abnormal", "abnormal"), ("safely", "safely"), ("resulting", "resulting"),
        ]
        for (text, word) in cases {
            XCTAssertEqual(NurseCopy.forbiddenTerms(in: text), [word], text)
        }
        for t in ["detects dengue", "Detected Dengue", "detecting dengue"] {
            XCTAssertEqual(NurseCopy.forbiddenTerms(in: t), ["detect dengue"], t)
        }
        XCTAssertEqual(NurseCopy.forbiddenTerms(in: "detect the fever, dengue ward"), [])
    }

    func testRegulatoryCopyIsDistinct() {
        XCTAssertEqual(ReasonCode.dsREG001.nurseInstruction, NurseCopy.consentBlocked)
        XCTAssertEqual(ReasonCode.dsREG002.nurseInstruction,
                       "Study consent needs renewing before recording. Contact the study coordinator.")
        XCTAssertEqual(NurseCopy.regulatoryHold,
                       "Recordings for this patient are on hold. Contact the study coordinator.")
        XCTAssertNotEqual(ReasonCode.dsREG001.nurseInstruction, ReasonCode.dsREG002.nurseInstruction)
        XCTAssertEqual(ReasonCode.dsQG005.nurseInstruction, NurseCopy.fingertipGuidance)
        for s in [NurseCopy.holdStillPatient, NurseCopy.fingertipGuidance, NurseCopy.cameraNotReady,
                  NurseCopy.showColourCard, NurseCopy.comeBackLater, NurseCopy.patientDeclined,
                  NurseCopy.disinfectReminder, NurseCopy.phoneWarm, NurseCopy.consentRenewal,
                  NurseCopy.regulatoryHold] {
            XCTAssertTrue(NurseCopy.allStrings.contains(s), s)
        }
    }

    func testInterpolatedHelpers() {
        XCTAssertEqual(NurseCopy.recordStepAgain(2), "Please record step 2 again")
        XCTAssertEqual(NurseCopy.repeatNotice(maskedStudyID: "••417", reason: "lighting"),
                       "Recording for study ID ••417 needs repeating (lighting).")
    }

    func testImplausibleBpmDropped() {
        let r = ExperimentalResponse(enabled: true, items: [
            .init(domain: .rppgFace, pulseRateBpm: 0), .init(domain: .rppgFace, pulseRateBpm: -40),
            .init(domain: .rppgFace, pulseRateBpm: 19.4), .init(domain: .rppgFace, pulseRateBpm: 301),
            .init(domain: .rppgFingertip, pulseRateBpm: 20), .init(domain: .rppgFace, pulseRateBpm: 300)])
        let out = ExperimentalPulsePresenter.present(r, monitorHR: nil).experimental.map { $0.text }
        XCTAssertEqual(out, ["Camera pulse (fingertip): 20 bpm", "Camera pulse (face): 300 bpm"])
    }

    func testAllStringsContainsEveryDeclaredConstantAndInstruction() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DengueCaptureCore/NurseCopy.swift").path
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"public static let \w+(?::\s*String)?\s*=\s*"(.*)""#)
        let ns = source as NSString
        let literals = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        XCTAssertGreaterThan(literals.count, 20)
        for l in literals { XCTAssertTrue(NurseCopy.allStrings.contains(l), "missing from allStrings: \(l)") }
        for c in ReasonCode.allCases {
            XCTAssertTrue(NurseCopy.allStrings.contains(c.nurseInstruction))
        }
        for cue in NurseCopy.allCues {
            XCTAssertTrue(NurseCopy.allStrings.contains(NurseCopy.text(for: cue)))
        }
        XCTAssertEqual(NurseCopy.allStrings.count, Set(NurseCopy.allStrings).count,
                       "duplicate strings in allStrings")
    }

    func testExactSpecStrings() {
        XCTAssertEqual(NurseCopy.banner, "Research Use Only — not for diagnosis or treatment decisions. Continue standard care and blood tests.")
        XCTAssertEqual(NurseCopy.saved, "Recording saved for research")
        XCTAssertEqual(NurseCopy.experimentalNotice, "Not validated — do not use for care decisions. Use the monitor value.")
        XCTAssertEqual(NurseCopy.text(for: .tooDark), "Too dark — turn on overhead light")
    }

    func testReasonCodeRawValuesAndInstructions() {
        XCTAssertEqual(ReasonCode.allCases.count, 11)
        XCTAssertEqual(ReasonCode.dsQG001.rawValue, "DS_QG_001")
        XCTAssertEqual(ReasonCode.dsRPPG002.rawValue, "DS_RPPG_002")
        XCTAssertEqual(ReasonCode.dsSEG001.rawValue, "DS_SEG_001")
        XCTAssertEqual(ReasonCode.dsREG002.rawValue, "DS_REG_002")
        for c in ReasonCode.allCases { XCTAssertFalse(c.nurseInstruction.isEmpty, c.rawValue) }
    }

    func testExperimentalDisabledYieldsEmpty() {
        let r = ExperimentalResponse(enabled: false,
            items: [.init(domain: .rppgFace, pulseRateBpm: 92)])
        let out = ExperimentalPulsePresenter.present(r, monitorHR: 88)
        XCTAssertTrue(out.experimental.isEmpty)
        XCTAssertEqual(out.monitor, "Monitor pulse: 88 bpm")
    }

    func testExperimentalBpmRoundedAndMonitorListedFirst() {
        let r = ExperimentalResponse(enabled: true, items: [
            .init(domain: .rppgFace, pulseRateBpm: 91.6),
            .init(domain: .rppgFingertip, pulseRateBpm: 90)])
        let out = ExperimentalPulsePresenter.present(r, monitorHR: 88)
        XCTAssertEqual(out.monitor, "Monitor pulse: 88 bpm")
        XCTAssertEqual(out.experimental.map { $0.text },
                       ["Camera pulse (face): 92 bpm", "Camera pulse (fingertip): 90 bpm"])
        XCTAssertEqual(out.experimental[0].label, "EXPERIMENTAL")
        XCTAssertEqual(out.experimental[0].notice, NurseCopy.experimentalNotice)
        XCTAssertNil(ExperimentalPulsePresenter.present(r, monitorHR: nil).monitor)
    }

    func testExperimentalDecodesFromWireAndDropsNonFinite() throws {
        let json = #"{"enabled":true,"items":[{"domain":"rppg_face","pulse_rate_bpm":92,"label":"EXPERIMENTAL","notice":"x"}]}"#
        let r = try JSONDecoder().decode(ExperimentalResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.items.first?.domain, .rppgFace)
        XCTAssertEqual(ExperimentalPulsePresenter.present(r, monitorHR: nil).experimental.first?.text,
                       "Camera pulse (face): 92 bpm")
        let bad = ExperimentalResponse(enabled: true, items: [.init(domain: .rppgFace, pulseRateBpm: .nan)])
        XCTAssertTrue(ExperimentalPulsePresenter.present(bad, monitorHR: nil).experimental.isEmpty)
    }
}
