import Darwin
import Foundation
@testable import FileOperations
import Testing

@Suite(.serialized) struct OperationDiagnosticsTests {
    @Test func stageHistoryIsIndependentOfUIProgressCoalescing() throws {
        let values = DiagnosticStageProbe()
        let job = UUID()
        FileOperationDiagnostics.install { if $0.jobID == job { values.receive($0) } }
        defer { FileOperationDiagnostics.install(nil) }
        let reporter = OperationProgressReporter(jobID: job, callback: nil)
        reporter.begin(.planning)
        reporter.transition(.copying)
        for _ in 0..<1000 { reporter.advance(bytes: 1) }
        reporter.transition(.verifying); reporter.transition(.publishing)
        let next = reporter.next(callback: nil)
        next.transition(.retaining); next.requestStop(); next.finish(success: false)
        #expect(values.snapshot.map(\.phase) == [.planning,.copying,.verifying,.publishing,.retaining,.stopping,.completed])
        #expect(values.snapshot.allSatisfy { $0.jobID == job })
        #expect(values.snapshot.map(\.ordinal) == Array(1...7).map(UInt64.init))
        #expect(values.snapshot.last?.success == false)
        FileOperationDiagnostics.install(nil)
        OperationProgressReporter(jobID: job, callback: nil).begin(.planning)
        #expect(values.snapshot.count == 7)
    }
    @Test func nativeFailureCodesKeepTheirExactSynchronousJobAndRestoreNestedScopes() throws {
        enum GeneratedFailure: Error { case stop }
        let outerID = UUID(), innerID = UUID(), values = DiagnosticStageProbe()
        FileOperationDiagnostics.install { if $0.jobID == outerID || $0.jobID == innerID { values.receive($0) } }
        defer { FileOperationDiagnostics.install(nil) }
        let outer = OperationProgressReporter(jobID: outerID, callback: nil)
        let inner = OperationProgressReporter(jobID: innerID, callback: nil)
        FileOperationDiagnostics.withScope(outer) {
            #expect(posixFailure(EACCES) == .accessDenied)
            for _ in 0..<1000 { _ = posixFailure(EACCES) }
            do {
                try FileOperationDiagnostics.withScope(inner) {
                    #expect(posixFailure(EROFS) == .accessDenied)
                    throw GeneratedFailure.stop
                }
            } catch {}
            #expect(posixFailure(ENOSPC) == .outOfSpace)
        }
        _ = posixFailure(EPERM)
        #expect(values.snapshot.map(\.jobID) == [outerID,innerID,outerID])
        #expect(values.snapshot.map(\.nativeError) == [EACCES,EROFS,ENOSPC].map(Optional.some))
        #expect(values.snapshot.map(\.ordinal) == [1,1,2])
    }
    @Test func firstTextRecordTransactionFailureKeepsItsClosedDiagnosticBoundary() async throws {
        let base = try FileOperationTestFixtures.base()
        let root = base.appendingPathComponent("text-record-diagnostic-" + UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Editor.txt")
        let before = Data("Generated before\n".utf8)
        try before.write(to: file, options: .withoutOverwriting)
        let history = state.appendingPathComponent("operation-recovery", isDirectory: true)
        let normal = RecoverableFileOperations(journalDirectory: history, protecting: [state])
        let upgrade = await normal.upgradeLocalTextHistory()
        #expect(upgrade.status == .succeeded && upgrade.catalogVersion == 10)

        var hooks = RecoveryHooks()
        hooks.journalHooks.beforeSaveCommit = { throw FileOperationFailure.recoveryUncertain }
        let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks, protecting: [state])
        let opened = try await engine.readLocalTextDocument(at: file)
        let plan = try await engine.prepareLocalTextSave(from: opened.token,
            bytes: Data("Generated after\n".utf8), generation: UUID())
        let values = DiagnosticStageProbe()
        FileOperationDiagnostics.install { values.receive($0) }
        defer { FileOperationDiagnostics.install(nil) }
        _ = await engine.performLocalTextSave(plan)
        let observed = values.snapshot.contains { stage in
            guard stage.checkpoint == .textRecordTransaction else { return false }
            if case .operation(.recoveryUncertain)? = stage.failure { return true }
            return false
        }
        #expect(observed)
        #expect(try Data(contentsOf: file) == before)
    }
    @Test(arguments: [false, true])
    func failedCopyDistinguishesMetadataAndReceiptWithoutChangingRefusal(_ receiptChanged: Bool) async throws {
        let root = try FileOperationTestFixtures.base().appendingPathComponent("copy-diagnostic-" + UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager().removeItem(at: root) }
        let source = root.appendingPathComponent("Generated-private-name.txt")
        let destination = root.appendingPathComponent("Destination")
        try Data("Generated private bytes\n".utf8).write(to: source, options: .withoutOverwriting)
        try FileManager().setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
        let original = try verifiedTree(source, cancellation: .init())
        let values = DiagnosticStageProbe()
        FileOperationDiagnostics.install { values.receive($0) }
        defer { FileOperationDiagnostics.install(nil) }
        let hooks = CopyFaultHooks(afterNativeCopy: { _, target in
            if !receiptChanged {
                guard fchmod(target, 0o600) == 0 else { throw posixFailure() }
            }
        }, afterSecurityReceipt: { _, target in
            if receiptChanged {
                let mark = Data("0083;67000000;GeneratedDiagnosticFixture;00000000-0000-0000-0000-000000000001".utf8)
                guard mark.withUnsafeBytes({ fsetxattr(target, "com.apple.quarantine", $0.baseAddress, mark.count, 0, 0) }) == 0
                else { throw posixFailure() }
            }
        })
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("History"),
            hooks: .init(copyFaults: hooks))
        let result = await engine.perform(.copy(sources: [source], destinationDirectory: destination))
        let checkpoint: OperationDiagnosticCheckpoint = receiptChanged ? .copyReceiptValidation : .copyMetadataComparison
        #expect(result.result.items.contains { $0.status == .failed(.copyMetadataMismatch) })
        #expect(original.matches(try verifiedTree(source, cancellation: .init())))
        #expect(!FileManager().fileExists(atPath: destination.appendingPathComponent(source.lastPathComponent).path))
        let caught = values.snapshot.filter { $0.checkpoint == checkpoint }
        #expect(caught.count == 1)
        if case .operation(.copyMetadataMismatch)? = caught.first?.failure {}
        else { Issue.record("Failed copy lost its closed diagnostic category") }
        #expect(caught.first?.phase == .verifying)
    }
    @Test func inverseDirectoryStagesCarryOnlyClosedFamiliesAndRecordIdentity() {
        let values = DiagnosticStageProbe()
        let job = UUID(), record = UUID()
        FileOperationDiagnostics.install { if $0.jobID == job { values.receive($0) } }
        defer { FileOperationDiagnostics.install(nil) }
        let reporter = OperationProgressReporter(jobID: job, callback: nil)
        reporter.begin(.verifying)
        reporter.observeNativeTrashInverseChange(
            .complete(nativeChanged: [.quarantine], osAccessAttributeChanged: true), recordID: record)
        reporter.observeCaughtFailure(.nativeTrashInverseJournal, error: FileOperationFailure.ioFailure,
            recordID: record, nativeTrashFinding: .unavailable)
        let accepted = values.snapshot.first { $0.checkpoint == .nativeTrashInverseObservedChange }
        #expect(accepted?.success == true && accepted?.recordID == record)
        #expect(accepted?.nativeTrashFinding == .complete(nativeChanged: [.quarantine],
            osAccessAttributeChanged: true))
        let refused = values.snapshot.first { $0.checkpoint == .nativeTrashInverseJournal }
        #expect(refused?.recordID == record && refused?.nativeTrashFinding == .unavailable)
        if case .operation(.ioFailure)? = refused?.failure {} else { Issue.record("closed inverse failure missing") }
    }
    @Test func deleteStageRefusalCarriesOnlyClosedFamilyAndRecordIdentity() {
        let values = DiagnosticStageProbe()
        let job = UUID(), record = UUID()
        FileOperationDiagnostics.install { if $0.jobID == job { values.receive($0) } }
        defer { FileOperationDiagnostics.install(nil) }
        let reporter = OperationProgressReporter(jobID: job, callback: nil)
        reporter.begin(.retaining)
        reporter.observeCaughtFailure(.nativeTrashDeleteStageTransition,
            error: FileOperationFailure.recoveryUncertain, recordID: record,
            nativeTrashFinding: .complete(nativeChanged: [.otherXattrs], osAccessAttributeChanged: false))
        let stage = values.snapshot.first { $0.checkpoint == .nativeTrashDeleteStageTransition }
        #expect(stage?.recordID == record)
        #expect(stage?.nativeTrashFinding == .complete(nativeChanged: [.otherXattrs],
            osAccessAttributeChanged: false))
        if case .operation(.recoveryUncertain)? = stage?.failure {} else {
            Issue.record("closed Delete-stage failure missing")
        }
    }
}
private final class DiagnosticStageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OperationDiagnosticStage] = []
    var snapshot: [OperationDiagnosticStage] { lock.withLock { values } }
    func receive(_ value: OperationDiagnosticStage) { lock.withLock { values.append(value) } }
}
