import XCTest
import Foundation
@testable import DengueCaptureCore

/// Held store wrapper: count saves, inject save failures, run a hook during a save.
final class TestHeldStore: HeldHandoffStoring {
    let inner: FileHeldHandoffStore
    var failSave = false
    var saves = 0
    var onSave: (() -> Void)?
    struct SaveFailed: Error {}
    init(_ inner: FileHeldHandoffStore) { self.inner = inner }
    func save(_ p: PendingHandoff) throws {
        saves += 1
        let hook = onSave
        onSave = nil
        hook?()
        if failSave { throw SaveFailed() }
        try inner.save(p)
    }
    func load(_ id: UUID) throws -> PendingHandoff? { try inner.load(id) }
    func loadEach() throws -> HeldLoadResult { try inner.loadEach() }
    func remove(_ id: UUID) throws { try inner.remove(id) }
    func recordRefs() throws -> [SealedArtefact] { try inner.recordRefs() }
}

final class RecordingFix2Tests: XCTestCase {
    var dir: URL!
    var keys: InMemoryKeyStore!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("t13fix2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: helpers

    private func meta() -> CaptureMetadata {
        CaptureMetadata(deviceModel: "iPhone15,2", step: .neutralFace, attempt: 1, cameraRole: .frontFace, fps: 30,
                        resolution: "1080x1920", exposureDurationMs: 10, iso: 200, torchLevel: 0, distanceCm: 45,
                        angleDeg: 3, lux: 320, mount: "holder", lightingType: "overhead", ambientTempC: nil,
                        ambientHumidityPct: nil, durationSeconds: 40, frameCount: 1200, videoCodec: "hevc",
                        videoAverageBitRate: 25_000_000)
    }

    private func sealed(_ step: CaptureStep) throws -> [SealedStepArtefact] {
        try FileManager.default.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        let sealer = ArtefactSealer(keys: keys)
        return try [ArtefactKind.video, .roiTrace, .metadata].map { kind in
            let plain = dir.appendingPathComponent("\(UUID().uuidString).plain")
            try Data("\(step.rawValue)-\(kind.rawValue)".utf8).write(to: plain)
            let s = try CaptureHandoff.sealAndRemovePlaintext(
                input: plain, output: sealedDir.appendingPathComponent("\(UUID().uuidString).sealed"), sealer: sealer)
            return SealedStepArtefact(step: step, attempt: 1, kind: kind, sealed: s)
        }
    }

    private func pending(_ artefacts: [SealedStepArtefact]) -> PendingHandoff {
        PendingHandoff(
            sessionId: UUID(), patientId: UUID(), maskedCode: NurseCopy.maskedStudyID("DS-2026-00417"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), offline: true, protocolVersion: "phase-a-1",
            attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept),
                       AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .accept)],
            vitals: [VitalRecord(field: .hr, value: 80, source: .bedsideMonitor,
                                 measuredAt: Date(timeIntervalSince1970: 1_800_000_000), isInvalid: false)],
            artefacts: artefacts, metadata: meta(), isOpen: false)
    }

    private func plan(for p: PendingHandoff) throws -> CaptureSessionPlan {
        try CaptureHandoff().makeSessionPlan(
            sessionId: p.sessionId, patientId: p.patientId!, capturedAt: p.capturedAt, offline: p.offline,
            protocolVersion: p.protocolVersion, metadata: try CaptureHandoff.scanMetadata(from: meta()),
            attempts: p.attempts, vitals: p.vitals, artefacts: p.artefacts)
    }

    private func engine(_ store: FlakyOutboxStore) -> (UploadEngine, Outbox) {
        let ob = Outbox(store: store, clock: TestClock())
        return (UploadEngine(outbox: ob, api: FakeUploadAPI(log: EventLog()), sessions: InMemoryUploadSessionStore(),
                             keys: keys, uploader: FakePartUploader(log: EventLog()), notifier: FakeNotifier()), ob)
    }

    private func counts(_ ob: Outbox, _ session: UUID) throws -> [OutboxKind: Int] {
        var c: [OutboxKind: Int] = [:]
        for i in try ob.items(sessionId: session) { c[i.kind, default: 0] += 1 }
        return c
    }

    private func alive(_ a: SealedStepArtefact) -> Bool {
        FileManager.default.fileExists(atPath: a.sealed.path.path) && (try? keys.key(id: a.sealed.keyId)) != nil
    }

    private func store() throws -> TestHeldStore { TestHeldStore(try FileHeldHandoffStore(directory: heldDir, keys: keys)) }

    // MARK: 1. ensureSessionItems

    func testEnsureSessionItemsAfterCrashAfterRecordSave() throws {
        let p = pending(try sealed(.neutralFace) + sealed(.fingertipPPG))
        let pl = try plan(for: p)
        let obStore = FlakyOutboxStore()
        obStore.failKinds = [.createScan]   // "crash" right after the session record was saved
        let (e, ob) = engine(obStore)
        XCTAssertThrowsError(try e.enqueueSession(sessionId: p.sessionId, participantCode: p.maskedCode,
                                                  createScan: pl.createScan, scanId: nil, artefacts: pl.artefacts))
        XCTAssertNotNil(e.record(p.sessionId))
        XCTAssertEqual(try counts(ob, p.sessionId), [:])

        obStore.failKinds = []
        let replanned = try plan(for: p)   // fresh local ids: identity must come from the sealed artefact
        try e.ensureSessionItems(replanned, participantCode: p.maskedCode)
        try e.ensureSessionItems(replanned, participantCode: p.maskedCode)   // idempotent
        let expected: [OutboxKind: Int] = [.createScan: 1, .declareArtefact: 6, .uploadArtefact: 6,
                                           .completeArtefact: 6, .clinicalData: 1]
        XCTAssertEqual(try counts(ob, p.sessionId), expected)
        XCTAssertEqual(e.record(p.sessionId)?.artefacts.count, 6)

        // Chains: declare -> createScan, upload -> declare, complete -> upload, per artefact.
        let items = try ob.items(sessionId: p.sessionId)
        let create = try XCTUnwrap(items.first { $0.kind == .createScan })
        XCTAssertTrue(items.filter { $0.kind == .declareArtefact }.allSatisfy { $0.dependsOn == create.id })
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for u in items where u.kind == .uploadArtefact {
            XCTAssertEqual(byId[u.dependsOn!]?.kind, .declareArtefact)
            XCTAssertEqual(byId[u.dependsOn!]?.payload, u.payload)
        }
        for c in items where c.kind == .completeArtefact {
            XCTAssertEqual(byId[c.dependsOn!]?.kind, .uploadArtefact)
            XCTAssertEqual(byId[c.dependsOn!]?.payload, c.payload)
        }
    }

    func testEnsureFillsPartialChains() throws {
        let p = pending(try sealed(.neutralFace))
        let pl = try plan(for: p)
        let obStore = FlakyOutboxStore()
        obStore.failKinds = [.completeArtefact]   // createScan, 1st declare and 1st upload were written
        let (e, ob) = engine(obStore)
        XCTAssertThrowsError(try e.enqueueSession(sessionId: p.sessionId, participantCode: p.maskedCode,
                                                  createScan: pl.createScan, scanId: nil, artefacts: pl.artefacts))
        let before = try ob.items(sessionId: p.sessionId)
        XCTAssertEqual(before.count, 3)
        obStore.failKinds = []
        try e.ensureSessionItems(try plan(for: p), participantCode: p.maskedCode)
        XCTAssertEqual(try counts(ob, p.sessionId), [.createScan: 1, .declareArtefact: 3, .uploadArtefact: 3,
                                                    .completeArtefact: 3, .clinicalData: 1])
        let upload1 = try XCTUnwrap(before.first { $0.kind == .uploadArtefact })
        let after = try ob.items(sessionId: p.sessionId)
        XCTAssertEqual(after.filter { $0.kind == .completeArtefact && $0.payload == upload1.payload }.first?.dependsOn,
                       upload1.id)
    }

    func testServiceUsesEnsureWhenRecordExists() throws {
        let a = try sealed(.neutralFace) + sealed(.fingertipPPG)
        let p = pending(a)
        let obStore = FlakyOutboxStore()
        obStore.failKinds = [.createScan]
        let (e, ob) = engine(obStore)
        let st = try store()
        let svc = CaptureHandoffService(store: st, keys: keys)
        XCTAssertEqual(svc.submit(p, engine: e), .held(.enqueueFailed("Injected")))
        XCTAssertNotNil(e.record(p.sessionId))
        let held = try XCTUnwrap(try st.load(p.sessionId))
        XCTAssertEqual(held.stage, .engineOwned)

        // A nurse discard of an engine-owned held record must not shred what the engine will upload.
        obStore.failKinds = []
        XCTAssertEqual(svc.retryHeld(engine: e), [p.sessionId: .enqueued])
        XCTAssertEqual(try counts(ob, p.sessionId)[.createScan], 1)
        XCTAssertEqual(try counts(ob, p.sessionId)[.declareArtefact], 6)
        XCTAssertEqual(try counts(ob, p.sessionId)[.clinicalData], 1)
        XCTAssertTrue(a.allSatisfy(alive))
    }

    func testDiscardOfEngineOwnedRecordKeepsArtefacts() throws {
        let a = try sealed(.neutralFace)
        let p = pending(a)
        let obStore = FlakyOutboxStore()
        obStore.failKinds = [.clinicalData]
        let (e, _) = engine(obStore)
        let svc = CaptureHandoffService(store: try store(), keys: keys)
        XCTAssertEqual(svc.submit(p, engine: e), .held(.enqueueFailed("Injected")))
        try svc.discard(sessionId: p.sessionId, reason: .nurseDiscard)
        XCTAssertTrue(a.allSatisfy(alive))
    }

    // MARK: 4. hold save failure

    func testHoldSaveFailureReportsHoldFailedAndKeepsDataReferenced() throws {
        let a = try sealed(.neutralFace)
        let p = pending(a)
        let st = try store()
        st.failSave = true
        let svc = CaptureHandoffService(store: st, keys: keys)
        XCTAssertEqual(svc.submit(p, engine: nil), .holdFailed(.uploadNotConfigured))
        let (e, ob) = engine(FlakyOutboxStore())
        let report = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir,
                               engine: e)
        XCTAssertEqual(report.deletedSealed, 0)
        XCTAssertTrue(a.allSatisfy(alive))   // in-memory hold is referenced
        st.failSave = false
        XCTAssertEqual(svc.retryHeld(engine: e), [p.sessionId: .enqueued])
        XCTAssertEqual(try counts(ob, p.sessionId)[.createScan], 1)
    }

    func testSweepDuringSubmitTreatsSessionAsReferenced() throws {
        let a = try sealed(.neutralFace)
        let p = pending(a)
        let st = try store()
        let svc = CaptureHandoffService(store: st, keys: keys)
        let (e, _) = engine(FlakyOutboxStore())
        var report: SweepReport?
        st.onSave = {   // the first save inside submit: nothing is persisted or engine-owned yet
            report = svc.sweep(captureDirectory: self.dir.appendingPathComponent("capture"),
                               sealedDirectory: self.sealedDir, engine: e)
        }
        XCTAssertEqual(svc.submit(p, engine: e), .enqueued)
        XCTAssertEqual(report?.deletedSealed, 0)
        XCTAssertTrue(a.allSatisfy(alive))
    }

    // MARK: 5. unreadable records

    func testUnreadableRecordIsSkippedListedAndDiscardable() throws {
        let st = try store()
        let svc = CaptureHandoffService(store: st, keys: keys)
        let good = pending(try sealed(.neutralFace))
        let bad = pending(try sealed(.fingertipPPG))
        XCTAssertEqual(svc.submit(good, engine: nil), .held(.uploadNotConfigured))
        XCTAssertEqual(svc.submit(bad, engine: nil), .held(.uploadNotConfigured))
        let badRef = try XCTUnwrap(try st.recordRefs().first { $0.path.lastPathComponent.hasPrefix(bad.sessionId.uuidString.lowercased()) })
        try keys.destroy(id: badRef.keyId)   // record can no longer be opened

        let summaries = try svc.heldSummaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first { $0.sessionId == bad.sessionId }?.isUnreadable, true)
        XCTAssertEqual(summaries.first { $0.sessionId == good.sessionId }?.isUnreadable, false)

        let (e, _) = engine(FlakyOutboxStore())
        XCTAssertEqual(svc.retryHeld(engine: e), [good.sessionId: .enqueued])

        // While an unreadable record exists, sealed files it may reference are kept.
        let r1 = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertTrue(r1.sealedSweepSkipped)
        XCTAssertEqual(r1.unreadableRecords, 1)
        XCTAssertTrue(bad.artefacts.allSatisfy(alive))

        try svc.discard(sessionId: bad.sessionId, reason: .nurseDiscard)
        XCTAssertEqual(try svc.heldSummaries().count, 0)
        let r2 = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertFalse(r2.sealedSweepSkipped)
        XCTAssertTrue(bad.artefacts.allSatisfy { !alive($0) })   // now provably orphaned
        XCTAssertTrue(good.artefacts.allSatisfy(alive))          // engine-owned
    }

    // MARK: 6. no re-seal when unchanged

    func testRetryDoesNotResealUnchangedHold() throws {
        let st = try store()
        let svc = CaptureHandoffService(store: st, keys: keys)
        _ = svc.submit(pending(try sealed(.neutralFace)), engine: nil)
        XCTAssertEqual(st.saves, 1)
        _ = svc.retryHeld(engine: nil)
        _ = svc.retryHeld(engine: nil)
        XCTAssertEqual(st.saves, 1)
    }

    // MARK: 3. unsupported device

    func testUnsupportedDeviceBlocksBeforeCapture() {
        let pf = Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8, supportsDepthCapture: false)
        XCTAssertEqual(pf.blockReason, .unsupportedDevice)
        XCTAssertFalse(pf.canStartCapture)
        XCTAssertNil(Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8).blockReason)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let f = CaptureFlow(preflight: Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8))
        f.selectPatient(participantCode: "DS-417", bedLabel: "B3")
        f.submitConsent(ConsentStatus(primaryResearch: true, consentVersion: "v1", currentVersion: "v1",
                                      withdrawn: false, captureAllowed: true, blockCode: nil,
                                      checkedAt: "2026-10-15T00:00:00Z"), snapshotAt: now, online: true, now: now)
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        f.updatePreflight(pf)   // detected at capture-screen entry
        f.submitVitals([.hr: VitalEntry(text: "88")], now: now)
        XCTAssertEqual(f.screen, .blocked)
        XCTAssertEqual(f.blockingMessage, NurseCopy.cameraNotReady)
    }
}
