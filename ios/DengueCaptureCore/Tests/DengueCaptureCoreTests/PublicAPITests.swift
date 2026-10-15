import XCTest
import DengueCaptureCore  // deliberately NOT @testable: proves the app-facing API is public.

final class PublicAPITests: XCTestCase {
    func testAppFacingTypesAreConstructibleFromAnotherModule() {
        let consent = ConsentStatus(primaryResearch: true, consentVersion: "v1", currentVersion: "v1",
                                    withdrawn: false, captureAllowed: true, blockCode: nil,
                                    checkedAt: "2026-10-15T00:00:00Z")
        XCTAssertTrue(consent.captureAllowed)
        let flow = CaptureFlow(preflight: Preflight(freeBytes: 5_000_000_000, batteryLevel: 0.5))
        flow.selectPatient(participantCode: "DS-1", bedLabel: nil)
        flow.submitConsent(consent, snapshotAt: Date(), online: true, now: Date())
        XCTAssertEqual(flow.screen, .assent)
        _ = ExperimentalResponse(enabled: false, items: [])
        _ = VitalEntry(text: "1")
    }
}
