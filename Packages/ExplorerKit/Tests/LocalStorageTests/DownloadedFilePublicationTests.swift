import CryptoKit
import CoreServices
import Darwin
import Foundation
import XCTest
@_spi(ArchiveProduction) @_spi(Qualification) @testable import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) @testable import LocalStorage

private struct ReceivedFixture {
    let root: URL, target: URL, journal: URL, pool: URL, protectedNames: [URL]
    init(privateSource: Bool = false) throws {
        if let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_B12_SOURCE"] {
            let source = URL(fileURLWithPath: path)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let caseRoot = source.deletingLastPathComponent()
            let legacy = caseRoot.deletingLastPathComponent() == repo.appendingPathComponent(".build/b12-download-qualification")
            let destinationPacket = caseRoot.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
                && ((try? Data(contentsOf: caseRoot.appendingPathComponent("reservation.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["action"] as? String == "traverse-received-destination"
            guard source.lastPathComponent == "source", legacy || destinationPacket,
                  UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) != nil, source.resolvingSymlinksInPath() == source else { throw RemoteDownloadStorageFailure.unsafe }
            root = source.appendingPathComponent(UUID().uuidString)
            try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } else {
            root = try LocalStorageTestFixtures.directory()
        }
        target = root.appendingPathComponent("Destination")
        let storageRoot = privateSource ? root.appendingPathComponent("Private", isDirectory: true) : root
        if privateSource {
            try FileManager().createDirectory(at: storageRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        journal = storageRoot.appendingPathComponent("journal")
        pool = storageRoot.appendingPathComponent(privateSource ? "remote-downloads" : "downloads")
        protectedNames = privateSource ? [storageRoot, pool] : [pool]
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func engine(_ hooks: RecoveryHooks = .init(), adoption: DownloadAdoptionPolicy = .held,
        publicQuarantine: ReceivedDownloadPublicQuarantinePolicy = .held,
        publicZIP: ZIPOneFilePublicExtractionPolicy = .held) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks, protecting: protectedNames,
            downloadAdoptionPolicy: adoption, receivedDownloadPublicQuarantinePolicy: publicQuarantine,
            zipOneFilePublicExtractionPolicy: publicZIP)
    }
    func received(_ bytes: Data, publicQuarantine: Bool = false) async throws -> RemoteDownloadedFile {
        let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 2,
            entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: UInt64(bytes.count), modifiedSeconds: 19, permissions: 0o100644)))
        let store = try RemoteDownloadStore(directory: pool)
        let file = try await publicQuarantine
            ? store.reservePublicQuarantineCandidate(selection) : store.reserve(selection)
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 32768)
            try await file.append(request: selection.request, offset: UInt64(offset), bytes: bytes.subdata(in: offset..<end)); offset = end
        }
        _ = try await file.seal(.init(selection: selection, receivedBytes: UInt64(bytes.count))); return file
    }
}
private final class ReceivedBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}
private final class AdoptionDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OperationDiagnosticStage] = []
    func receive(_ value: OperationDiagnosticStage) { lock.withLock { values.append(value) } }
    var snapshot: [OperationDiagnosticStage] { lock.withLock { values } }
}
private final class BadReceivedProducer: ArchiveFileProducer, @unchecked Sendable {
    let preview = ArchiveProductionPreview(files: 1, folders: 0, logicalBytes: 1, longestPathBytes: 0)
    private let lock = NSLock(); private(set) var finishCount = 0
    func validate(check: @Sendable () throws -> Void) throws { try check() }
    func produce(into fd: Int32, check: @Sendable () throws -> Void, progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try check(); guard write(fd, [UInt8(7)], 1) == 1, fchmod(fd, 0o644) == 0 else { throw FileOperationFailure.ioFailure }
        var facts = stat(); guard fstat(fd, &facts) == 0 else { throw FileOperationFailure.ioFailure }
        // Structurally valid local identity; deliberately false content hash.
        return .init(relative: "", device: facts.st_dev, inode: facts.st_ino, kind: S_IFREG,
            birthSeconds: facts.st_birthtimespec.tv_sec, birthNanoseconds: facts.st_birthtimespec.tv_nsec,
            changedSeconds: facts.st_ctimespec.tv_sec, changedNanoseconds: facts.st_ctimespec.tv_nsec, size: 1,
            contentSHA256: Data(repeating: 0, count: 32))
    }
    func finished() { lock.withLock { finishCount += 1 } }
}
final class DownloadedFilePublicationTests: XCTestCase, @unchecked Sendable {
    func testInterruptedPublicDownloadKeepsDirectRecoveryHeld() async throws {
        let fixture = try ReceivedFixture()
        let bytes = Data("Generated public Download".utf8)
        let destination = fixture.target.appendingPathComponent("Downloaded.bin")
        let file = try await fixture.received(bytes, publicQuarantine: true)
        var hooks = RecoveryHooks()
        hooks.beforeSync = { url in
            if url == destination { throw FileOperationFailure.ioFailure }
        }
        let engine = fixture.engine(hooks, publicQuarantine: .sourceQualification)
        let plan = try await file.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "Downloaded.bin")
        let interrupted = await engine.performReceivedFile(plan)
        let id = try XCTUnwrap(interrupted.recordID)
        XCTAssertNotEqual(interrupted.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)

        let cold = fixture.engine(publicQuarantine: .sourceQualification)
        let before = try await cold.inspectExistingHistory()
        XCTAssertEqual(before.records.first(where: { $0.id == id })?.state, "needsReview")
        XCTAssertFalse(before.records.first(where: { $0.id == id })?.canRecover ?? true)
        let revision = try XCTUnwrap(OperationJournal(fixture.journal).inspectRecord(id)?.revision)
        let recovery = await cold.recover(recordID: id)
        XCTAssertEqual(recovery.result.items.first?.status, .failed(.unsupported))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let after = try await cold.inspectExistingHistory()
        XCTAssertEqual(after.records.first(where: { $0.id == id })?.state, "needsReview")
        XCTAssertEqual(try OperationJournal(fixture.journal).inspectRecord(id)?.revision, revision)
    }

    func testPublicMarkCandidateIsHeldByDefaultAndV14ColdUndoKeepsTheMarkedObject() async throws {
        let fixture = try ReceivedFixture(), bytes = Data((0..<65_537).map { UInt8($0 % 251) })
        let file = try await fixture.received(bytes, publicQuarantine: true)
        do {
            _ = try await file.preparePublicQuarantineCandidate(using: fixture.engine(),
                parent: fixture.target, name: "Candidate.bin")
            XCTFail("The default engine must hold v14 publication")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let engine = fixture.engine(publicQuarantine: .sourceQualification)
        let plan = try await file.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "Candidate.bin")
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        let record = try XCTUnwrap(OperationJournal(fixture.journal).inspectRecord(id))
        XCTAssertEqual(record.version, 14)
        XCTAssertEqual(record.steps.first?.before.osManagedSecurityV1, true)
        XCTAssertEqual(record.steps.first?.after?.osManagedSecurityV1, true)
        let typed = try await engine.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(typed.version, 14)
        XCTAssertEqual(typed.purpose, "receivedFile")
        XCTAssertEqual(typed.state, "committed")
        XCTAssertTrue(typed.requiresPublicQuarantine)
        XCTAssertNotNil(try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        try await file.removeAfterDrain()
        do {
            _ = try await fixture.engine().undoAccessRequirement(recordID: id)
            XCTFail("Held public Download must not offer an Undo access lead")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        do {
            _ = try await fixture.engine(publicZIP: .sourceQualification).undoAccessRequirement(recordID: id)
            XCTFail("ZIP policy must not admit a Download Undo access lead")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let coldEngine = fixture.engine(publicQuarantine: .sourceQualification)
        let access = try await coldEngine.undoAccessRequirement(recordID: id)
        XCTAssertEqual(access?.recordID, id)
        XCTAssertEqual(access?.directory.standardizedFileURL.pathComponents,
            fixture.target.standardizedFileURL.pathComponents)
        // A cancelled or denied folder choice happens before Undo is submitted.
        // Reading this lead alone must leave the output and committed record intact.
        XCTAssertEqual(try OperationJournal(fixture.journal).inspectRecord(id)?.state, "committed")
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        let resumedAccess = try await coldEngine.undoAccessRequirement(recordID: id)
        XCTAssertEqual(resumedAccess, access)
        let defaultHistory = try await fixture.engine().inspectExistingHistory()
        XCTAssertFalse(try XCTUnwrap(defaultHistory.records.first { $0.id == id }).canUndo)
        let zipOnlyHistory = try await fixture.engine(publicZIP: .sourceQualification).inspectExistingHistory()
        XCTAssertFalse(try XCTUnwrap(zipOnlyHistory.records.first { $0.id == id }).canUndo)
        let optedHistory = try await engine.inspectExistingHistory()
        XCTAssertTrue(try XCTUnwrap(optedHistory.records.first { $0.id == id }).canUndo)
        let writableHistory = try await engine.recoveryRecords()
        XCTAssertTrue(try XCTUnwrap(writableHistory.records.first { $0.id == id }).canUndo)
        let held = await fixture.engine().undo(recordID: id)
        XCTAssertNotEqual(held.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        let beforeDenied = try XCTUnwrap(OperationJournal(fixture.journal).inspectRecord(id))
        guard chmod(fixture.target.path, 0o000) == 0 else { XCTFail("Could not deny generated destination access"); return }
        defer { _ = chmod(fixture.target.path, 0o700) }
        let denied = await coldEngine.undo(recordID: id)
        guard chmod(fixture.target.path, 0o700) == 0 else { XCTFail("Could not restore generated destination access"); return }
        XCTAssertEqual(denied.result.items.first?.status, .failed(.accessDenied))
        let afterDenied = try XCTUnwrap(OperationJournal(fixture.journal).inspectRecord(id))
        XCTAssertEqual(afterDenied.state, "committed")
        XCTAssertEqual(afterDenied.revision, beforeDenied.revision)
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        let renewedAccess = try await coldEngine.undoAccessRequirement(recordID: id)
        XCTAssertEqual(renewedAccess, access)
        let undone = await coldEngine.undo(recordID: id)
        XCTAssertEqual(undone.result.disposition, .succeeded)
        let after = try await coldEngine.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(after.state, "undone")
        XCTAssertEqual(after.purpose, typed.purpose)
        XCTAssertEqual(after.requiresPublicQuarantine, typed.requiresPublicQuarantine)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        do {
            _ = try await coldEngine.undoAccessRequirement(recordID: id)
            XCTFail("An undone record must not offer an Undo access lead")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .recoveryUncertain) }
    }

    func testPublicMarkCandidateRefusesColdUndoIfDestinationLosesMark() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([7, 8, 9]), publicQuarantine: true)
        let engine = fixture.engine(publicQuarantine: .sourceQualification)
        let plan = try await file.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "Candidate.bin")
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded)
        try await file.removeAfterDrain()
        XCTAssertEqual(removexattr(plan.destination.path, "com.apple.quarantine", 0), 0)
        let refused = await fixture.engine(publicQuarantine: .sourceQualification).undo(recordID: id)
        XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data([7, 8, 9]))
    }

    func testPublicMarkCandidateDoesNotOverwriteAnOccupiedDestination() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([7]), publicQuarantine: true)
        let engine = fixture.engine(publicQuarantine: .sourceQualification)
        let plan = try await file.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "Candidate.bin")
        try Data("Keep".utf8).write(to: plan.destination)
        let result = await engine.performReceivedFile(plan)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Keep".utf8))
        let source = try await file.verifiedSource()
        XCTAssertEqual(try Data(contentsOf: source), Data([7]))
        try await file.removeAfterDrain()
    }

    func testPublicMarkCandidatePostRenameMarkLossRetainsReviewAndRefusesColdRecovery() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([7, 8]), publicQuarantine: true)
        let published = fixture.target.appendingPathComponent("Candidate.bin")
        var hooks = RecoveryHooks()
        hooks.afterRename = { _ = removexattr(published.path, "com.apple.quarantine", 0) }
        let engine = fixture.engine(hooks, publicQuarantine: .sourceQualification)
        let plan = try await file.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "Candidate.bin")
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: published), Data([7, 8]))
        let record = try XCTUnwrap(OperationJournal(fixture.journal).inspectRecord(id))
        XCTAssertEqual(record.version, 14)
        XCTAssertEqual(record.state, "needsReview")
        XCTAssertNil(record.steps.first?.after)
        let recovery = await fixture.engine(publicQuarantine: .sourceQualification).recover(recordID: id)
        XCTAssertNotEqual(recovery.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: published), Data([7, 8]))
        try await file.removeAfterDrain()
    }

    func testPublicCandidateSpoolAndLegacyPublicationCannotBeCrossed() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(publicQuarantine: .sourceQualification)
        let candidate = try await fixture.received(Data([1]), publicQuarantine: true)
        let legacy = try await fixture.received(Data([2]))
        let markerURL = fixture.pool.appendingPathComponent("download-" + candidate.id.uuidString)
            .appendingPathComponent("session.meta")
        let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: Data(contentsOf: markerURL))
        XCTAssertEqual(marker.version, 4)
        do {
            _ = try await candidate.preparePublication(using: engine, parent: fixture.target, name: "Wrong.bin")
            XCTFail("V4 must not borrow legacy publication")
        } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .unsafe) }
        do {
            _ = try await legacy.preparePublicQuarantineCandidate(using: engine,
                parent: fixture.target, name: "Wrong.bin")
            XCTFail("V1 must not borrow the public-witness publication")
        } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .unsafe) }
        try await candidate.removeAfterDrain(); try await legacy.removeAfterDrain()
    }

    func testSFTPStorageAndReceivedWrapperReachHeldV14SourcePath() async throws {
        let fixture = try ReceivedFixture(), bytes = Data([1, 2, 3])
        let storage = try SFTPDownloadStorage(directory: fixture.pool,
            publicQuarantinePolicy: .sourceQualification)
        let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 2,
            entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)),
                logicalBytes: UInt64(bytes.count), modifiedSeconds: 19, permissions: 0o100644)))
        let file = try await storage.reserveSelected(selection)
        try await file.append(request: selection.request, offset: 0, bytes: bytes)
        _ = try await file.seal(.init(selection: selection, receivedBytes: UInt64(bytes.count)))
        let received = SFTPReceivedDownload(file)
        let engine = fixture.engine(publicQuarantine: .sourceQualification)
        let parent = try await engine.checkReceivedFileDestination(parent: fixture.target, name: "SFTP.bin")
        let plan = try await received.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "SFTP.bin", observing: parent)
        let result = await engine.performReceivedFile(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        let retired = await received.finishPublication(result)
        XCTAssertTrue(retired)
    }

    func testSMBStorageAndReceivedWrapperReachHeldV14SourcePath() async throws {
        let fixture = try ReceivedFixture(), bytes = Data([4, 5, 6])
        let storage = try SMBDownloadStorage(directory: fixture.pool,
            publicQuarantinePolicy: .sourceQualification)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1,
            folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Generated.bin"),
                attributes: 32, logicalBytes: UInt64(bytes.count), modifiedFileTime: 1))
        let file = try await storage.reserveSelected(selection)
        try await file.append(request: selection.request, offset: 0, bytes: bytes)
        _ = try await file.seal(.init(selection: selection, receivedBytes: UInt64(bytes.count)))
        let received = SMBReceivedDownload(file)
        let engine = fixture.engine(publicQuarantine: .sourceQualification)
        let parent = try await engine.checkReceivedFileDestination(parent: fixture.target, name: "SMB.bin")
        let plan = try await received.preparePublicQuarantineCandidate(using: engine,
            parent: fixture.target, name: "SMB.bin", observing: parent)
        let result = await engine.performReceivedFile(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        let retired = await received.finishPublication(result)
        XCTAssertTrue(retired)
    }
    private func rawQuarantine(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); guard descriptor >= 0 else { throw FileOperationFailure.notFound }; defer { close(descriptor) }
        let count = fgetxattr(descriptor, "com.apple.quarantine", nil, 0, 0, 0); guard count > 0, count < 4096 else { throw FileOperationFailure.copyMetadataMismatch }
        var data = Data(count: count)
        guard data.withUnsafeMutableBytes({ fgetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, count, 0, 0) }) == count else { throw FileOperationFailure.ioFailure }
        return data
    }
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    func testPrivateMarkProbeFixtureUsesSealedOwnedSpoolWithoutSession() async throws {
        let fixture = try ReceivedFixture(privateSource: true)
        let storage = try SFTPDownloadStorage(directory: fixture.pool)
        let received = try await storage.makeGeneratedPrivateMarkProbeSource()
        let rows = try await storage.inspect()
        let row = try XCTUnwrap(rows.first { $0.id == received.id })
        XCTAssertEqual(row.expectedBytes, 7)
        XCTAssertGreaterThanOrEqual(row.observedBytes, 7)
        XCTAssertLessThanOrEqual(row.observedBytes, 16_384)
        let payload = fixture.pool.appendingPathComponent("download-" + received.id.uuidString)
            .appendingPathComponent("payload")
        XCTAssertEqual(try Data(contentsOf: payload), Data("PROBEv1".utf8))
        XCTAssertTrue(row.active)
        await received.retainForReview()
        let inactive = try await storage.inspect()
        XCTAssertFalse(try XCTUnwrap(inactive.first { $0.id == received.id }).active)
    }
    #endif
    func testProtectedCachePublishesExactQuarantineAndColdUndoAfterCacheRemoval() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), bytes = Data((0..<65_537).map { UInt8($0 % 251) })
        let file = try await fixture.received(bytes), source = try await file.verifiedSource()
        let expectedRawSecurity = try rawQuarantine(source)
        let expectedSecurity = try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        let selected = try await engine.observeSelection([source])
        do { _ = try await engine.prepareTransfer(sources: [source], destinationDirectory: fixture.target, move: false, observing: selected); XCTFail() }
        catch { XCTAssertEqual(error as? FileOperationFailure, .protectedLocation) }
        let plan = try await file.preparePublication(using: engine, parent: fixture.target, name: "Downloaded.bin")
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded); XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        XCTAssertNil(result.result.items.first?.source)
        let actualSecurity = try URL(fileURLWithPath: plan.destination.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(try rawQuarantine(plan.destination), expectedRawSecurity)
        XCTAssertEqual(actualSecurity?[kLSQuarantineAgentNameKey as String] as? String, expectedSecurity?[kLSQuarantineAgentNameKey as String] as? String)
        var facts = stat(); XCTAssertEqual(lstat(plan.destination.path, &facts), 0); XCTAssertEqual(facts.st_mode & 0o7777, 0o644)
        try await file.removeAfterDrain()
        let history = try await fixture.engine().inspectExistingHistory()
        XCTAssertEqual(history.records.first?.operation, "Download")
        let undone = await fixture.engine().undo(recordID: id)
        XCTAssertEqual(undone.result.disposition, .succeeded); XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
    }
    func testForeignEngineAndReplayCannotConsumeOrReleaseTheValidPlan() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), file = try await fixture.received(Data([7]))
        let plan = try await file.preparePublication(using: engine, parent: fixture.target, name: "Received.bin")
        do { try await file.removeAfterDrain(); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .busy) }
        let wrong = await fixture.engine().performReceivedFile(plan); XCTAssertEqual(wrong.result.items.first?.status, .failed(.invalidRequest))
        do { try await file.removeAfterDrain(); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .busy) }
        let good = await engine.performReceivedFile(plan); XCTAssertEqual(good.result.disposition, .succeeded)
        let replay = await engine.performReceivedFile(plan); XCTAssertEqual(replay.result.items.first?.status, .failed(.invalidRequest))
        try await file.removeAfterDrain()
    }
    func testOccupiedChangedAndProtectedDestinationsNeverOverwrite() async throws {
        for mode in ["occupied", "changed", "protected"] {
            let fixture = try ReceivedFixture(), engine = fixture.engine(), file = try await fixture.received(Data([7]))
            let destination = mode == "protected" ? fixture.pool : fixture.target, name = "Received.bin"
            if mode == "protected" {
                do { try await engine.checkReceivedFileDestination(parent: destination, name: name); XCTFail() }
                catch { XCTAssertEqual(error as? FileOperationFailure, .protectedLocation) }
                do { _ = try await file.preparePublication(using: engine, parent: destination, name: name); XCTFail() }
                catch { XCTAssertEqual(error as? FileOperationFailure, .protectedLocation) }
            } else {
                try await engine.checkReceivedFileDestination(parent: destination, name: name)
                let plan = try await file.preparePublication(using: engine, parent: destination, name: name)
                if mode == "occupied" { try Data("Keep existing".utf8).write(to: plan.destination) }
                else {
                    try FileManager().moveItem(at: destination, to: fixture.root.appendingPathComponent("Retained destination"))
                    try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
                }
                let outcome = await engine.performReceivedFile(plan); XCTAssertNotEqual(outcome.result.disposition, .succeeded)
                if mode == "occupied" {
                    XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Keep existing".utf8))
                    do { try await engine.checkReceivedFileDestination(parent: destination, name: name); XCTFail() } catch {}
                }
                else { XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)) }
            }
            try await file.removeAfterDrain()
        }
    }
    func testSourceChangesAfterPreparationPreventPublicOutput() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), file = try await fixture.received(Data([7]))
        let source = try await file.verifiedSource(), plan = try await file.preparePublication(using: engine, parent: fixture.target, name: "Received.bin")
        let descriptor = open(source.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(pwrite(descriptor, [UInt8(8)], 1, 0), 1); close(descriptor)
        let result = await engine.performReceivedFile(plan); XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)); XCTAssertEqual(try Data(contentsOf: source), Data([8]))
        await file.abandon()
    }
    func testSharedZIPCreationPathStillPublishesAndColdUndoes() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), source = fixture.root.appendingPathComponent("Generated.txt")
        try Data("Generated ZIP body".utf8).write(to: source)
        let selection = try await engine.observeSelection([source])
        let plan = try await engine.prepareZIPCreation(sources: [source], parent: fixture.target, name: "Generated.zip", observing: selection)
        let result = await engine.performArchiveCreation(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded)
        let signature = try Data(contentsOf: plan.destination).prefix(4); XCTAssertEqual(signature, Data([0x50, 0x4b, 3, 4]))
        let undo = await fixture.engine().undo(recordID: id); XCTAssertEqual(undo.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: source), Data("Generated ZIP body".utf8))
    }
    func testFalseReceiptHashRefusesPublicationAndFinishesTheActualWorkerOnce() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), producer = BadReceivedProducer()
        let plan = try await engine.prepareReceivedFile(parent: fixture.target, name: "Bad.bin") { _ in producer }
        let result = await engine.performReceivedFile(plan)
        XCTAssertEqual(result.result.items.first?.status, .failed(.copyContentMismatch)); XCTAssertNotNil(result.recordID)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)); XCTAssertEqual(producer.finishCount, 1)
        let repeated = await engine.performReceivedFile(plan); XCTAssertEqual(repeated.result.items.first?.status, .failed(.invalidRequest)); XCTAssertEqual(producer.finishCount, 1)
    }
    func testCancellationRetainsTheSourceLeaseUntilTheActualWorkerDrains() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data(repeating: 7, count: 65_537)), barrier = ReceivedBarrier()
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, _ in if stage == .produced { barrier.entered.signal(); _ = barrier.release.wait(timeout: .now() + 5) } }
        let engine = fixture.engine(hooks), plan = try await file.preparePublication(using: engine, parent: fixture.target, name: "Cancelled.bin")
        let work = Task { await engine.performReceivedFile(plan) }
        let entered = await Task.detached { barrier.waitForEntry() }.value
        XCTAssertTrue(entered)
        let releasedEarly = await file.abandon(); XCTAssertFalse(releasedEarly)
        do { try await file.removeAfterDrain(); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .busy) }
        work.cancel(); barrier.release.signal(); let result = await work.value
        XCTAssertNotEqual(result.result.disposition, .succeeded); XCTAssertTrue(result.result.cancellationRequested)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)); XCTAssertTrue(engine.isIdleForCopyPreview)
        let store = try RemoteDownloadStore(directory: fixture.pool), records = try await store.inspect()
        XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active); try await store.discardIncomplete(file.id)
    }
    func testPostProductionAndSyncFaultsLeaveNoPublicOutputAndReleaseOnlySourceUse() async throws {
        for stage in [ArchiveProductionHooks.Stage.produced, .synced] {
            let fixture = try ReceivedFixture(), file = try await fixture.received(Data([7])); var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { actual, _ in if actual == stage { throw FileOperationFailure.ioFailure } }
            let engine = fixture.engine(hooks), plan = try await file.preparePublication(using: engine, parent: fixture.target, name: "Failed.bin")
            let result = await engine.performReceivedFile(plan)
            XCTAssertEqual(result.result.items.first?.status, .failed(.ioFailure)); XCTAssertNotNil(result.recordID)
            XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
            let source = try await file.verifiedSource(); XCTAssertEqual(try Data(contentsOf: source), Data([7]))
            try await file.removeAfterDrain()
        }
    }
    func testSharedZIPPlanStillChecksSourcesAndOneUse() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), source = fixture.root.appendingPathComponent("Input.txt")
        try Data([7]).write(to: source); let selected = try await engine.observeSelection([source])
        let plan = try await engine.prepareZIPCreation(sources: [source], parent: fixture.target, name: "Input.zip", observing: selected)
        let wrong = await fixture.engine().performArchiveCreation(plan); XCTAssertEqual(wrong.result.items.first?.status, .failed(.invalidRequest))
        try Data([8, 9]).write(to: source)
        let stale = await engine.performArchiveCreation(plan); XCTAssertEqual(stale.result.items.first?.status, .failed(.sourceChanged))
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
    }
    func testCancelledBeforeAdmissionRetiresOnlyItsOwnUnusedSourcePlan() async throws {
        let fixture = try ReceivedFixture(), engine = fixture.engine(), file = try await fixture.received(Data([7]))
        let plan = try await file.preparePublication(using: engine, parent: fixture.target, name: "Cancelled.bin")
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.performReceivedFile(plan)
        }
        let result = await operation.value
        XCTAssertNotEqual(result.result.disposition, .succeeded); XCTAssertTrue(result.result.cancellationRequested)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)); try await file.removeAfterDrain()
    }

    func testAdoptionIsInactiveByDefaultAndCrossVolumePreflightKeepsSpool() async throws {
        let fixture = try ReceivedFixture()
        let storage = try SFTPDownloadStorage(directory: fixture.pool)
        do { _ = try await storage.checkAdoptionDestination(using: fixture.engine(),
            parent: fixture.target, name: "Held.bin"); XCTFail() }
        catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let file = try await fixture.received(Data([7]))
        do { _ = try await file.prepareAdoption(using: fixture.engine(), parent: fixture.target, name: "Held.bin"); XCTFail() }
        catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let other = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        var here = stat(), there = stat()
        guard stat(fixture.target.path, &here) == 0, stat(other.path, &there) == 0,
              here.st_dev != there.st_dev else { throw XCTSkip("No separate read-only APFS preflight volume") }
        do { _ = try await storage.checkAdoptionDestination(using: fixture.engine(adoption: .sourceQualification),
            parent: other, name: UUID().uuidString + ".bin"); XCTFail() }
        catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        do { _ = try await file.prepareAdoption(using: fixture.engine(adoption: .sourceQualification),
            parent: other, name: UUID().uuidString + ".bin"); XCTFail() }
        catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let retainedSource = try await file.verifiedSource()
        XCTAssertEqual(try Data(contentsOf: retainedSource), Data([7]))
        try await file.removeAfterDrain()
    }

    func testAdoptedSingleFileKeepsExactInodeMarkAndColdUndoReturnsToArea() async throws {
        let fixture = try ReceivedFixture(privateSource: true), bytes = Data((0..<65_537).map { UInt8($0 % 251) })
        let engine = fixture.engine(adoption: .sourceQualification)
        let storage = try SFTPDownloadStorage(directory: fixture.pool)
        let destination = try await storage.checkAdoptionDestination(using: engine,
            parent: fixture.target, name: "Adopted.bin")
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.pool.path))
        let file = try await fixture.received(bytes), source = try await file.verifiedSource()
        let received = SFTPReceivedDownload(file)
        let genericSelection = try await engine.observeSelection([source])
        do { _ = try await engine.prepareTransfer(sources: [source], destinationDirectory: fixture.target,
            move: false, observing: genericSelection); XCTFail() }
        catch { XCTAssertEqual(error as? FileOperationFailure, .protectedLocation) }
        let mark = try rawQuarantine(source)
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(source.path, &before), 0)
        let plan = try await received.prepareAdoption(using: engine, parent: fixture.target,
            name: "Adopted.bin", observing: destination)
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        let retired = await received.finishAdoption(result)
        XCTAssertEqual(result.result.disposition, .succeeded)
        XCTAssertTrue(retired)
        XCTAssertEqual(try Data(contentsOf: plan.destination), bytes)
        XCTAssertEqual(lstat(plan.destination.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev); XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mode & 0o7777, 0o644)
        XCTAssertEqual(try rawQuarantine(plan.destination), mark)
        XCTAssertFalse(FileManager().fileExists(atPath: source.path))
        XCTAssertFalse(FileManager().fileExists(atPath: source.deletingLastPathComponent().path))
        let remainingSpools = try await RemoteDownloadStore(directory: fixture.pool).inspect()
        XCTAssertFalse(remainingSpools.contains { $0.id == file.id })
        let coldCommitted = try await fixture.engine(adoption: .sourceQualification).inspectAdoptedDownload(recordID: id)
        XCTAssertEqual(coldCommitted, .committed)
        let qualifiedHistory = try await fixture.engine(adoption: .sourceQualification).inspectExistingHistory()
        let qualifiedHint = try XCTUnwrap(qualifiedHistory.records.first { $0.id == id })
        XCTAssertTrue(qualifiedHint.canUndo); XCTAssertFalse(qualifiedHint.canRecover)
        let heldHistory = try await fixture.engine().inspectExistingHistory()
        let heldHint = try XCTUnwrap(heldHistory.records.first { $0.id == id })
        XCTAssertFalse(heldHint.canUndo); XCTAssertFalse(heldHint.canRecover)
        let heldUndo = await fixture.engine().undo(recordID: id)
        XCTAssertNotEqual(heldUndo.result.disposition, .succeeded)
        let undo = await fixture.engine(adoption: .sourceQualification).undo(recordID: id)
        XCTAssertEqual(undo.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        let coldUndone = try await fixture.engine(adoption: .sourceQualification).inspectAdoptedDownload(recordID: id)
        XCTAssertEqual(coldUndone, .undone)
        let undoneHistory = try await fixture.engine(adoption: .sourceQualification).inspectExistingHistory()
        let undoneHint = try XCTUnwrap(undoneHistory.records.first { $0.id == id })
        XCTAssertFalse(undoneHint.canUndo); XCTAssertFalse(undoneHint.canRecover)
    }

    func testAdoptionCollisionLeavesNamedSpoolAndExistingDestination() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([7, 8]))
        let source = try await file.verifiedSource(), engine = fixture.engine(adoption: .sourceQualification)
        let plan = try await file.prepareAdoption(using: engine, parent: fixture.target, name: "Occupied.bin")
        try Data([9]).write(to: plan.destination)
        let result = await engine.performReceivedFile(plan)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: source), Data([7, 8]))
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data([9]))
        try await file.removeAfterDrain()
    }

    func testAdoptionMetadataRefusalReportsClosedComponentAndPhase() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([7]))
        var hooks = RecoveryHooks()
        hooks.beforeSync = { url in
            guard url.lastPathComponent == "payload",
                  url.deletingLastPathComponent().lastPathComponent.hasPrefix(".mac-explorer-recovery-") else { return }
            guard removexattr(url.path, "com.apple.quarantine", 0) == 0 else {
                throw FileOperationFailure.ioFailure
            }
        }
        let engine = fixture.engine(hooks, adoption: .sourceQualification)
        let plan = try await file.prepareAdoption(using: engine, parent: fixture.target, name: "Marked.bin")
        let diagnostics = AdoptionDiagnosticCapture()
        FileOperationDiagnostics.install { diagnostics.receive($0) }
        defer { FileOperationDiagnostics.install(nil) }
        let result = await engine.performReceivedFile(plan)
        XCTAssertEqual(result.result.items.first?.status, .failed(.copyMetadataMismatch))
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        let checkpoints = diagnostics.snapshot.compactMap(\.checkpoint)
        XCTAssertTrue(checkpoints.contains(.downloadAdoptionRawQuarantine))
        XCTAssertTrue(checkpoints.contains(.downloadAdoptionStage))
        XCTAssertFalse(checkpoints.contains(.downloadAdoptionPublication))
        XCTAssertNotNil(result.recordID)
        XCTAssertEqual(diagnostics.snapshot.first { $0.checkpoint == .downloadAdoptionStage }?.recordID,
                       result.recordID)
    }

    func testAdoptionPlanCannotBeConsumedByForeignEngineOrReplayed() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([5, 6]))
        let owner = fixture.engine(adoption: .sourceQualification)
        let plan = try await file.prepareAdoption(using: owner, parent: fixture.target, name: "OneUse.bin")
        let foreign = await fixture.engine(adoption: .sourceQualification).performReceivedFile(plan)
        XCTAssertNotEqual(foreign.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        let first = await owner.performReceivedFile(plan)
        XCTAssertEqual(first.result.disposition, .succeeded)
        let replay = await owner.performReceivedFile(plan)
        XCTAssertNotEqual(replay.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data([5, 6]))
    }

    func testAdoptionAfterFirstRenameRetainsColdAreaAndBlocksPoolDiscard() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([1, 2, 3]))
        let received = SFTPReceivedDownload(file)
        let source = try await file.verifiedSource(), mark = try rawQuarantine(source)
        var hooks = RecoveryHooks()
        hooks.beforeSync = { url in
            if url.lastPathComponent == "payload", url.deletingLastPathComponent().lastPathComponent.hasPrefix(".mac-explorer-recovery-") {
                throw FileOperationFailure.ioFailure
            }
        }
        let engine = fixture.engine(hooks, adoption: .sourceQualification)
        let destination = try await engine.checkReceivedFileDestination(parent: fixture.target, name: "Interrupted.bin")
        let plan = try await received.prepareAdoption(using: engine, parent: fixture.target,
            name: "Interrupted.bin", observing: destination)
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: source.path))
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        let area = try XCTUnwrap(result.result.items.first?.recoveryURLs.first { $0.lastPathComponent.hasPrefix(".mac-explorer-recovery-") })
        let held = area.appendingPathComponent("payload")
        XCTAssertEqual(try Data(contentsOf: held), Data([1, 2, 3]))
        XCTAssertEqual(try rawQuarantine(held), mark)
        let retired = await received.finishAdoption(result)
        XCTAssertFalse(retired)
        // Inventory must use only pool metadata. Hide the owned area body
        // briefly: both connection summaries still expose the durable marker.
        let hidden = area.appendingPathComponent("payload-hidden-for-inventory")
        guard rename(held.path, hidden.path) == 0 else { throw FileOperationFailure.ioFailure }
        defer { if FileManager().fileExists(atPath: hidden.path) { _ = rename(hidden.path, held.path) } }
        let sftpRows = try await SFTPDownloadStorage(directory: fixture.pool).inspect()
        let smbRows = try await SMBDownloadStorage(directory: fixture.pool).inspect()
        let sftpRow = try XCTUnwrap(sftpRows.first { $0.id == file.id })
        let smbRow = try XCTUnwrap(smbRows.first { $0.id == file.id })
        XCTAssertFalse(sftpRow.active); XCTAssertTrue(sftpRow.publicationProtected)
        XCTAssertFalse(smbRow.active); XCTAssertTrue(smbRow.publicationProtected)
        XCTAssertEqual(rename(hidden.path, held.path), 0)
        let coldRetained = try await fixture.engine(adoption: .sourceQualification).inspectAdoptedDownload(recordID: id)
        XCTAssertEqual(coldRetained, .recoveryRetained)
        do { try await RemoteDownloadStore(directory: fixture.pool).discardIncomplete(file.id); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .busy) }
        XCTAssertEqual(try Data(contentsOf: held), Data([1, 2, 3]))
    }

    func testAdoptionCheckpointObservesTaskStopBeforePublicRename() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([3, 1, 4]))
        let source = try await file.verifiedSource(), mark = try rawQuarantine(source)
        let barrier = ReceivedBarrier()
        var hooks = RecoveryHooks()
        hooks.afterAdoptionMove = { cancelled in
            barrier.entered.signal()
            guard barrier.release.wait(timeout: .now() + 5) == .success, cancelled() else {
                throw FileOperationFailure.unavailable
            }
        }
        let engine = fixture.engine(hooks, adoption: .sourceQualification)
        let plan = try await file.prepareAdoption(using: engine, parent: fixture.target, name: "Stopped.bin")
        let task = Task { await engine.performReceivedFile(plan) }
        guard barrier.waitForEntry() else {
            task.cancel(); barrier.release.signal(); XCTFail("first rename checkpoint not reached"); return
        }
        task.cancel()
        barrier.release.signal()
        let result = await task.value, id = try XCTUnwrap(result.recordID)
        XCTAssertTrue(result.result.cancellationRequested)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        let area = try XCTUnwrap(result.result.items.first?.recoveryURLs.first {
            $0.lastPathComponent.hasPrefix(".mac-explorer-recovery-")
        })
        let retained = area.appendingPathComponent("payload")
        XCTAssertEqual(try Data(contentsOf: retained), Data([3, 1, 4]))
        XCTAssertEqual(try rawQuarantine(retained), mark)
        let cold = try await fixture.engine(adoption: .sourceQualification).inspectAdoptedDownload(recordID: id)
        XCTAssertEqual(cold, .recoveryRetained)
    }

    func testAdoptionAfterFinalRenameRequiresReviewAndRefusesUndo() async throws {
        let fixture = try ReceivedFixture(), file = try await fixture.received(Data([8, 9]))
        let source = try await file.verifiedSource(), mark = try rawQuarantine(source)
        var hooks = RecoveryHooks()
        hooks.beforeSync = { url in
            if url.lastPathComponent == "Published.bin" { throw FileOperationFailure.ioFailure }
        }
        let engine = fixture.engine(hooks, adoption: .sourceQualification)
        let plan = try await file.prepareAdoption(using: engine, parent: fixture.target, name: "Published.bin")
        let result = await engine.performReceivedFile(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data([8, 9]))
        XCTAssertEqual(try rawQuarantine(plan.destination), mark)
        let cold = try await fixture.engine(adoption: .sourceQualification).inspectAdoptedDownload(recordID: id)
        XCTAssertEqual(cold, .publishedUncommitted)
        let undo = await fixture.engine(adoption: .sourceQualification).undo(recordID: id)
        XCTAssertNotEqual(undo.result.disposition, .succeeded)
        await file.abandon()
        do { try await RemoteDownloadStore(directory: fixture.pool).discardIncomplete(file.id); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .busy) }
    }
}
