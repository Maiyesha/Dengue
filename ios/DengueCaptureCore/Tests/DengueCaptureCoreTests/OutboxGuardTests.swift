import XCTest
@testable import DengueCaptureCore

final class OutboxGuardTests: XCTestCase {
    var dir: URL!
    var clock: TestClock!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        clock = TestClock()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    func make() throws -> Outbox { Outbox(store: try FileOutboxStore(directory: dir), clock: clock) }

    func testLateCallbacksDoNotReviveFrozenItems() throws {
        let ob = try make()
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        try ob.quarantine(sessionId: s, keys: InMemoryKeyStore(), sealedPaths: [])
        try ob.markRetry(a.id); try ob.markDone(a.id); try ob.markInFlight(a.id)
        XCTAssertEqual(try ob.item(a.id)?.status, .quarantined)
        XCTAssertEqual(try ob.item(a.id)?.attempts, 0)
        clock.wallNow = clock.wallNow.addingTimeInterval(5000)
        XCTAssertNil(try ob.nextReady())

        let b = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)
        try ob.apply(.invalid(code: "X"), to: b.id)
        try ob.markDone(b.id)
        XCTAssertEqual(try ob.item(b.id)?.status, .failed)
    }

    func testFailureCascadesToTransitiveDependents() throws {
        let ob = try make()
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        let b = try ob.enqueue(.declareArtefact, sessionId: s, payload: Data(), dependsOn: a.id)
        let c = try ob.enqueue(.uploadArtefact, sessionId: s, payload: Data(), dependsOn: b.id)
        try ob.apply(.invalid(code: "DS_VALIDATION_001"), to: a.id)
        for x in [b, c] {
            let got = try XCTUnwrap(ob.item(x.id))
            XCTAssertEqual(got.status, .failed)
            XCTAssertEqual(got.failureReason, "dependency failed")
        }
        XCTAssertNil(try ob.nextReady())
    }

    func testRecoverInFlightKeepsIdempotencyKey() throws {
        let ob = try make()
        let a = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)
        try ob.markInFlight(a.id)
        XCTAssertNil(try ob.nextReady())
        let reopened = try make()
        try reopened.recoverInFlight()
        let got = try XCTUnwrap(reopened.item(a.id))
        XCTAssertEqual(got.status, .pending)
        XCTAssertEqual(got.idempotencyKey, a.idempotencyKey)
        XCTAssertEqual(try reopened.nextReady()?.id, a.id)
    }

    func testStopAndQuarantineBlocksSessionImmediately() throws {
        let ob = try make()
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        let b = try ob.enqueue(.clinicalData, sessionId: s, payload: Data(), dependsOn: nil)
        let other = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)
        XCTAssertEqual(try ob.apply(.stopAndQuarantine(code: "DS_REG_001"), to: a.id),
                       .quarantineRequired(sessionId: s))
        XCTAssertEqual(try ob.item(a.id)?.status, .quarantinePending)
        XCTAssertEqual(try ob.item(b.id)?.status, .quarantinePending)
        XCTAssertEqual(try ob.nextReady()?.id, other.id)
        try ob.markRetry(a.id)
        XCTAssertEqual(try ob.item(a.id)?.status, .quarantinePending)
        try ob.quarantine(sessionId: s, keys: InMemoryKeyStore(), sealedPaths: [])
        XCTAssertEqual(try ob.item(a.id)?.status, .quarantined)
        XCTAssertEqual(try ob.item(b.id)?.status, .quarantined)
    }

    func testFailDoesNotOverwriteFrozenAndCascadeSkipsQuarantinePending() throws {
        let ob = try make()
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        let d = try ob.enqueue(.uploadArtefact, sessionId: s, payload: Data(), dependsOn: a.id)
        try ob.apply(.stopAndQuarantine(code: "DS_REG_001"), to: a.id)
        for e in [APIError.invalid(code: "X"), .unauthorized, .reEnrol] {
            XCTAssertEqual(try ob.apply(e, to: a.id), .ignoredFrozen)
            XCTAssertEqual(try ob.item(a.id)?.status, .quarantinePending)
        }
        // A failing item elsewhere whose dependent is quarantinePending is not touched by the cascade.
        let root = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)
        let dep = try ob.enqueue(.uploadArtefact, sessionId: s, payload: Data(), dependsOn: root.id)
        try ob.apply(.stopAndQuarantine(code: "DS_REG_001"), to: dep.id)
        XCTAssertEqual(try ob.item(dep.id)?.status, .quarantinePending)
        try ob.apply(.invalid(code: "X"), to: root.id)
        XCTAssertEqual(try ob.item(root.id)?.status, .failed)
        XCTAssertEqual(try ob.item(dep.id)?.status, .quarantinePending)
        XCTAssertEqual(try ob.item(d.id)?.status, .quarantinePending)
    }

    func testRetryableOnFrozenItemIsIgnored() throws {
        let ob = try make()
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        try ob.quarantine(sessionId: s, keys: InMemoryKeyStore(), sealedPaths: [])
        XCTAssertEqual(try ob.apply(.retryable, to: a.id), .ignoredFrozen)
        XCTAssertEqual(try ob.item(a.id)?.status, .quarantined)
        XCTAssertEqual(try ob.item(a.id)?.attempts, 0)
    }

    func testPendingQuarantineSessionsSurvivesReopen() throws {
        let ob = try make()
        let s1 = UUID(), s2 = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s1, payload: Data(), dependsOn: nil)
        _ = try ob.enqueue(.clinicalData, sessionId: s1, payload: Data(), dependsOn: nil)
        _ = try ob.enqueue(.createScan, sessionId: s2, payload: Data(), dependsOn: nil)
        try ob.apply(.stopAndQuarantine(code: "DS_REG_001"), to: a.id)
        let reopened = try make()
        XCTAssertEqual(try reopened.pendingQuarantineSessions(), [s1])
        try reopened.quarantine(sessionId: s1, keys: InMemoryKeyStore(), sealedPaths: [])
        XCTAssertEqual(try reopened.pendingQuarantineSessions(), [])
    }
}
