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
        XCTAssertEqual(NurseCopy.forbiddenTerms(in: "Unsafe resulting normalise"), [])
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
