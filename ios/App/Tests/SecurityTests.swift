import XCTest
import DengueCaptureCore
@testable import DengueCapture

/// UNVERIFIED on Windows; runs in ios.yml. Pure session/enrolment/monitor logic is tested in the core package
/// (SecurityPolicyTests, ScreenCaptureMonitorTests); these cover the Apple-framework adapters.
final class SecurityTests: XCTestCase {
    private final class Clock: OutboxClock {
        var wallNow = Date(); var monotonicNanos: UInt64 = 1; var serverOffset: TimeInterval = 0
        func advance(_ s: TimeInterval) { wallNow += s; monotonicNanos += UInt64(s * 1e9) }
    }

    func testIdle10MinRequiresReauth() {
        let c = Clock(); let p = SessionPolicy(clock: c)
        p.signedIn(); c.advance(601)
        XCTAssertEqual(p.evaluate(), .reauthRequired)
    }

    func testOfflineSessionOlderThan12hIsInvalid() {
        let c = Clock(); let p = SessionPolicy(clock: c)
        p.signedIn(); c.advance(12 * 3600 + 1)
        XCTAssertEqual(p.evaluate(), .expired)
    }

    func testSecureEnclaveKeyStoreDestroyMakesKeyThrow() throws {
        let store = SecureEnclaveKeyStore(service: "test.\(UUID().uuidString)")
        #if targetEnvironment(simulator)
        XCTAssertFalse(store.usesSecureEnclave, "simulator must use the software fallback")
        #endif
        let (id, key) = try store.newKey()
        let again = try store.key(id: id)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, again.withUnsafeBytes { Data($0) })
        try store.destroy(id: id)
        XCTAssertThrowsError(try store.key(id: id))
    }

    @MainActor
    func testCapturedScreenSetsBlurredViaMonitor() {
        final class Sink: DeviceEventSink {
            var n = 0
            func record(event: String, detail: [String: String], at: Date) { n += 1 }
        }
        let sink = Sink()
        let m = ScreenCaptureMonitor(sink: sink, clock: Clock())
        m.captureStateChanged(isCaptured: true)
        XCTAssertTrue(m.blurred)
        XCTAssertEqual(sink.n, 1)
    }

    func testManagedConfigRequiresHTTPSIssuer() {
        let d = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        d.set(["oidc_issuer": "http://idp.example", "oidc_client_id": "x"], forKey: "com.apple.configuration.managed")
        XCTAssertNil(OIDCConfig.fromManagedConfig(d))
        d.set(["oidc_issuer": "https://idp.example", "oidc_client_id": "x"], forKey: "com.apple.configuration.managed")
        XCTAssertEqual(OIDCConfig.fromManagedConfig(d)?.clientId, "x")
    }
}
