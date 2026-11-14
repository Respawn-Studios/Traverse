import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(ArchiveProduction) @testable import FileOperations
@_spi(Qualification) @testable import LocalStorage

struct FolderFixture {
    let root: URL, parent: URL, pool: URL
    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_FOLDER_DOWNLOAD_TEST_ROOT"] else {
            root = try LocalStorageTestFixtures.directory().appendingPathComponent("folder-contracts", isDirectory: true)
            parent = root.appendingPathComponent("Destination", isDirectory: true)
            pool = root.appendingPathComponent("downloads", isDirectory: true)
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
            return
        }
        let admitted = URL(fileURLWithPath: raw)
        guard admitted.resolvingSymlinksInPath() == admitted,
              admitted.deletingLastPathComponent().lastPathComponent == "traverse-development",
              UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent,
              #filePath.hasPrefix(admitted.path + "/source/package/"),
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "sftp-folder-contracts" else { throw FileOperationFailure.invalidRequest }
        root = admitted.appendingPathComponent("source/FolderFixtures/" + UUID().uuidString)
        parent = root.appendingPathComponent("Destination"); pool = root.appendingPathComponent("downloads")
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func engine(_ hooks: RecoveryHooks = .init(), publicTree: Bool = false) -> RecoverableFileOperations {
        .init(journalDirectory: root.appendingPathComponent("history"), hooks: hooks, protecting: [pool],
            receivedFolderPublicQuarantinePolicy: publicTree ? .sourceQualification : .held)
    }
    static func node(_ parts: [String], size: UInt64? = 0, directory: Bool = false) -> SFTPFolderManifest.Node {
        .init(components: parts.map { Data($0.utf8) }, size: size, modified: 19, permissions: directory ? 0o040755 : 0o100644)
    }
    static func manifest(empty: Bool = false) throws -> SFTPFolderManifest {
        try .init(nodes: [node([], size: 4096, directory: true)] + (empty ? [] : [node(["Empty"], directory: true),
            node(["Café"], directory: true), node(["Café", "Report.txt"], size: 7), node(["Zero\\file"], size: 0)]))
    }
    static func prepared(_ manifest: SFTPFolderManifest) throws -> SFTPPreparedFolderDownload {
        let first = manifest.nodes[0]
        let selected = try SFTPFolderDownloadSelection(generation: UUID(), snapshot: .init(read: 7, revision: 9, count: 1, folders: 1, state: .complete),
            row: .init(observation: 2, entry: .init(name: SFTPRemoteName(Data("Generated".utf8)), logicalBytes: first.size,
                modifiedSeconds: first.modified, permissions: first.permissions)))
        return try .init(selection: selected, manifest: manifest)
    }
    func received(empty: Bool = false, hooks: DownloadIOHooks = .init()) async throws -> RemoteDownloadedTree {
        let value = try Self.prepared(Self.manifest(empty: empty)), tree = try await RemoteDownloadStore(directory: pool, hooks: hooks).reserveTree(value)
        for (ordinal, node) in value.manifest.nodes.enumerated() where !node.directory {
            try tree.beginMember(request: value.selection.request, ordinal: ordinal)
            if node.size == 7 { try tree.appendOnSessionExecutor(request: value.selection.request, ordinal: ordinal, offset: 0, bytes: Data("Fixture".utf8)) }
            try tree.endMember(request: value.selection.request, ordinal: ordinal, receivedBytes: node.size!)
        }
        try await tree.seal(request: value.selection.request, receivedBytes: value.logicalBytes, receivedFiles: value.files)
        return tree
    }
    func folder(_ id: UUID) -> URL { pool.appendingPathComponent("download-" + id.uuidString) }
}

final class SFTPFolderDownloadTests: XCTestCase, @unchecked Sendable {
    func testV16ReceivedTreeRequiresOwnPolicyAndColdUndoChecksEveryPublicMark() async throws {
        let f = try FolderFixture(), tree = try await f.received()
        let held = f.engine()
        let observed = try await held.checkReceivedDirectoryDestination(parent: f.parent, name: "Public")
        do {
            _ = try await tree.preparePublication(using: held, parent: f.parent, name: "Public",
                observing: observed, publicQuarantineTreeV16: true)
            XCTFail("held tree policy admitted publication")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.parent.appendingPathComponent("Public").path))
        try await tree.removeAfterDrain()

        let qualifiedTree = try await f.received(), engine = f.engine(publicTree: true)
        let plan = try await qualifiedTree.preparePublication(using: engine, parent: f.parent,
            name: "Public", observing: observed, publicQuarantineTreeV16: true)
        let made = await engine.performReceivedDirectory(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
            f.root.appendingPathComponent("history"), id: id, cancellation: .init()) {
            XCTAssertEqual(record.producedTreeV16, .receivedFolder)
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.nodeCount, 5)
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.requiresEveryNode, true)
        } else { XCTFail("received tree did not retain its typed v16 purpose") }
        for path in ["", "Café", "Café/Report.txt", "Empty", "Zero\\file"] {
            let url = path.isEmpty ? plan.destination : plan.destination.appendingPathComponent(path)
            XCTAssertNotNil(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        }
        let history = try await f.engine(publicTree: true).inspectExistingHistory()
        XCTAssertTrue(history.records.contains { $0.id == id && $0.canUndo })
        let heldHistory = try await f.engine().inspectExistingHistory()
        XCTAssertFalse(heldHistory.records.first(where: { $0.id == id })?.canUndo ?? true)
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        try await qualifiedTree.removeAfterDrain()
    }

    func testV16ColdUndoRefusesLostDescendantMarkAndKeepsPublishedTree() async throws {
        let f = try FolderFixture(), engine = f.engine(publicTree: true)
        let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Public")
        let tree = try await f.received()
        let plan = try await tree.preparePublication(using: engine, parent: f.parent,
            name: "Public", observing: observed, publicQuarantineTreeV16: true)
        let made = await engine.performReceivedDirectory(plan)
        let id = try XCTUnwrap(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded, "\(made.result.items.map(\.status))")
        let child = plan.destination.appendingPathComponent("Café/Report.txt")
        XCTAssertEqual(removexattr(child.path, "com.apple.quarantine", 0), 0)
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertNotEqual(inverse.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: child), Data("Fixture".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination.path))
        await tree.abandon()
    }
    private func preallocate(_ bytes: Int64, at url: URL) throws {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC); XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { throw RemoteDownloadStorageFailure.unavailable }; defer { close(fd) }
        var allocation = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: Int32(F_PEOFPOSMODE), fst_offset: 0, fst_length: bytes, fst_bytesalloc: 0)
        XCTAssertEqual(fcntl(fd, F_PREALLOCATE, &allocation), 0)
        var facts = stat(); XCTAssertEqual(fstat(fd, &facts), 0); XCTAssertGreaterThanOrEqual(Int64(facts.st_blocks) * 512, bytes)
    }
    func testObservedFileAllocationRoundingDoesNotRefuseACompleteSafeCopy() async throws {
        let f = try FolderFixture(), store = try RemoteDownloadStore(directory: f.pool), size = 65_553
        let selected = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: UInt64(size), modifiedSeconds: 19, permissions: 0o100644)))
        let file = try await store.reserve(selected)
        // Exact allocation shape observed in AA73C983's slow native receipt.
        try preallocate(131_072, at: f.folder(file.id).appendingPathComponent("payload"))
        for offset in stride(from: 0, to: size, by: 32_768) {
            try await file.append(request: selected.request, offset: UInt64(offset), bytes: Data(repeating: 7, count: min(32_768, size - offset)))
        }
        _ = try await file.seal(.init(selection: selected, receivedBytes: UInt64(size)))
        await file.abandon(); let records = try await store.inspect()
        XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active); try await store.discardIncomplete(file.id)
    }
    func testUnexpectedAllocationStopsWritesButRemainsInspectableAndExplicitlyDiscardable() async throws {
        let f = try FolderFixture(), store = try RemoteDownloadStore(directory: f.pool)
        let selected = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: 1, modifiedSeconds: 19, permissions: 0o100644)))
        let file = try await store.reserve(selected)
        try preallocate(2 << 20, at: f.folder(file.id).appendingPathComponent("payload"))
        do { try await file.append(request: selected.request, offset: 0, bytes: Data([7])); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .capacity) }
        await file.abandon(); let records = try await store.inspect()
        XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active); XCTAssertGreaterThanOrEqual(records[0].observedBytes, 2 << 20)
        try await store.discardIncomplete(file.id)
    }
    func testRegularFileAllocationRoundingRemainsWithinTheSharedPoolAndDiscardable() async throws {
        for size in [65_553, 131_073, (1 << 20) + 17] {
            let f = try FolderFixture(), store = try RemoteDownloadStore(directory: f.pool)
            let selected = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
                entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: UInt64(size), modifiedSeconds: 19, permissions: 0o100644)))
            let file = try await store.reserve(selected)
            let body = Data((0..<size).map { UInt8($0 % 251) })
            for offset in stride(from: 0, to: size, by: 32_768) {
                try await file.append(request: selected.request, offset: UInt64(offset), bytes: body.subdata(in: offset..<min(size, offset + 32_768)))
            }
            _ = try await file.seal(.init(selection: selected, receivedBytes: UInt64(size)))
            let source = try await file.verifiedSource(); XCTAssertEqual(try Data(contentsOf: source), body)
            await file.abandon(); let records = try await store.inspect()
            XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active); XCTAssertFalse(records[0].isFolder)
            XCTAssertLessThanOrEqual(records[0].observedBytes, RemoteDownloadStore.maximumPoolBytes)
            try await store.discardIncomplete(file.id)
        }
    }
    func testManifestKeepsExactNamesCountsEmptyFoldersAndOffsets() throws {
        let value = try FolderFixture.manifest()
        XCTAssertEqual(value.files, 2); XCTAssertEqual(value.folders, 2); XCTAssertEqual(value.logicalBytes, 7)
        let sealed = try value.sealed(hashes: [nil, nil, nil, Data(SHA256.hash(data: Data("Fixture".utf8))), Data(SHA256.hash(data: Data()))])
        XCTAssertEqual(sealed.0.nodes[4].offset, 7); XCTAssertEqual(sealed.0.nodes[4].node.relative, "Zero\\file")
        XCTAssertEqual(try JSONDecoder().decode(SFTPFolderManifest.Sealed.self, from: sealed.1).nodes.count, 5)
    }
    func testUnsafeDuplicateCanonicalAndUnorderedManifestsRefuse() throws {
        let root = FolderFixture.node([], directory: true)
        let invalid: [[SFTPFolderManifest.Node]] = [[], [FolderFixture.node(["file"])],
            [root, FolderFixture.node(["missing", "file"])], [root, FolderFixture.node(["A"]), FolderFixture.node(["a"])],
            [root, FolderFixture.node(["Café"]), FolderFixture.node(["Cafe\u{301}"])],
            [root, FolderFixture.node(["..", "file"])], [root, FolderFixture.node(["colon:name"])],
            [root, FolderFixture.node(["line\nname"])], [root, FolderFixture.node(["\u{202e}name"])],
            [root, FolderFixture.node([String(repeating: "x", count: 256)])], [root, FolderFixture.node(["x"], size: (1 << 30) + 1)],
            [root, .init(components: [Data("link".utf8)], size: 0, modified: 19, permissions: 0o120777)]]
        for nodes in invalid { XCTAssertThrowsError(try SFTPFolderManifest(nodes: nodes)) }
        XCTAssertThrowsError(try SFTPFolderManifest(nodes: [root] + (0...1_024).map { FolderFixture.node(["f\($0)"]) }))
    }
    func testTypedSelectionRequiresCompleteKnownDirectoryAndRootAgreement() throws {
        for permissions: UInt32? in [nil, 0o100644, 0o120777] {
            XCTAssertThrowsError(try SFTPFolderDownloadSelection(generation: UUID(), snapshot: .init(read: 1, revision: 1, count: 1, folders: 0, state: .complete),
                row: .init(observation: 1, entry: .init(name: SFTPRemoteName(Data("Generated".utf8)), logicalBytes: 0, modifiedSeconds: 19, permissions: permissions))))
        }
        let good = try FolderFixture.prepared(FolderFixture.manifest())
        XCTAssertThrowsError(try SFTPPreparedFolderDownload(selection: good.selection, manifest: .init(nodes: [FolderFixture.node([], size: 7, directory: true)])))
    }
    func testNestedReceiptPublishesOneQuarantinedTreeAndColdUndo() async throws {
        let f = try FolderFixture(), engine = f.engine()
        let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received")
        let tree = try await f.received(), plan = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed)
        let result = await engine.performReceivedDirectory(plan), id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded); XCTAssertNil(result.result.items[0].source)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Café/Report.txt")), Data("Fixture".utf8))
        for path in ["", "Café", "Café/Report.txt", "Empty", "Zero\\file"] {
            let url = path.isEmpty ? plan.destination : plan.destination.appendingPathComponent(path)
            XCTAssertNotNil(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            let facts = try FileManager().attributesOfItem(atPath: url.path)
            XCTAssertEqual((facts[.posixPermissions] as? NSNumber)?.intValue, path == "Café/Report.txt" || path == "Zero\\file" ? 0o644 : 0o755)
        }
        let history = try await engine.inspectExistingHistory(); XCTAssertEqual(history.records.first?.operation, "Download Folder")
        let undo = await f.engine().undo(recordID: id); XCTAssertEqual(undo.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        try await tree.removeAfterDrain(); let remaining = try await RemoteDownloadStore(directory: f.pool).inspect(); XCTAssertTrue(remaining.isEmpty)
    }
    func testEmptyRootIsPublishedAndUndoableWithoutBodyChunks() async throws {
        let f = try FolderFixture(), engine = f.engine(), tree = try await f.received(empty: true)
        let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Empty")
        let plan = try await tree.preparePublication(using: engine, parent: f.parent, name: "Empty", observing: observed)
        let result = await engine.performReceivedDirectory(plan)
        XCTAssertEqual(result.result.disposition, .succeeded); XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: plan.destination.path), [])
        let undone = await engine.undo(recordID: try XCTUnwrap(result.recordID)); XCTAssertEqual(undone.result.disposition, .succeeded)
        try await tree.removeAfterDrain()
    }
    func testWrongMemberRequestOffsetAndEarlyEndRetainOneIncompleteRecord() async throws {
        for variant in 0..<5 {
            let f = try FolderFixture(), prepared = try FolderFixture.prepared(FolderFixture.manifest()), store = try RemoteDownloadStore(directory: f.pool)
            let tree = try await store.reserveTree(prepared)
            if variant == 0 { XCTAssertThrowsError(try tree.beginMember(request: prepared.selection.request, ordinal: 4)) }
            else {
                try tree.beginMember(request: prepared.selection.request, ordinal: 3)
                if variant == 4 { XCTAssertThrowsError(try tree.endMember(request: prepared.selection.request, ordinal: 3, receivedBytes: 7)) }
                else { XCTAssertThrowsError(try tree.appendOnSessionExecutor(request: variant == 1 ? UUID() : prepared.selection.request,
                    ordinal: 3, offset: variant == 2 ? 1 : 0, bytes: Data(repeating: 7, count: variant == 3 ? 8 : 7))) }
            }
            do { try await tree.seal(request: prepared.selection.request, receivedBytes: 7, receivedFiles: 2); XCTFail() } catch {}
            await tree.abandon(); let records = try await store.inspect(); XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active)
            try await store.discardIncomplete(tree.id)
        }
    }
    func testWriteAndSyncFailuresPublishNothingAndStayDiscardable() async throws {
        for write in [true, false] {
            let f = try FolderFixture()
            do { _ = try await f.received(hooks: .init(failWriteAfterBytes: write ? 3 : nil, failSync: !write)); XCTFail() } catch {}
            let store = try RemoteDownloadStore(directory: f.pool)
            var records = try await store.inspect()
            for _ in 0..<100 where records.first?.active == true { try await Task.sleep(for: .milliseconds(5)); records = try await store.inspect() }
            XCTAssertEqual(records.count, 1); XCTAssertFalse(records[0].active)
            XCTAssertTrue(try FileManager().contentsOfDirectory(atPath: f.parent.path).isEmpty)
            try await store.discardIncomplete(records[0].id)
        }
    }
    func testMixedPoolSharesTwoActiveLimitAndPreservesLegacyMarker() async throws {
        let f = try FolderFixture(), store = try RemoteDownloadStore(directory: f.pool)
        let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("File".utf8)), logicalBytes: 0, modifiedSeconds: 19, permissions: 0o100644)))
        let file = try await store.reserve(selection), marker = f.folder(file.id).appendingPathComponent("session.meta")
        let before = try Data(contentsOf: marker), prepared = try FolderFixture.prepared(FolderFixture.manifest(empty: true))
        let tree = try await store.reserveTree(prepared)
        do { _ = try await store.reserveTree(prepared); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .capacity) }
        XCTAssertEqual(try Data(contentsOf: marker), before)
        await tree.abandon(); await file.abandon(); try await store.discardIncomplete(tree.id); try await store.discardIncomplete(file.id)
    }
    func testManifestOrPayloadSubstitutionCannotPublishAndUnknownSidecarCannotDiscard() async throws {
        for manifest in [true, false] {
            let f = try FolderFixture(), engine = f.engine(), tree = try await f.received()
            let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received")
            let altered = f.folder(tree.id).appendingPathComponent(manifest ? "manifest" : "payload")
            let fd = open(altered.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC); XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(pwrite(fd, [UInt8(255)], 1, 0), 1); close(fd)
            do { _ = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed); XCTFail() } catch {}
            await tree.abandon()
            let unknown = f.folder(tree.id).appendingPathComponent("unknown"); try Data([7]).write(to: unknown)
            do { try await RemoteDownloadStore(directory: f.pool).discardIncomplete(tree.id); XCTFail() } catch {}
            XCTAssertEqual(try Data(contentsOf: unknown), Data([7])); XCTAssertFalse(FileManager().fileExists(atPath: f.parent.appendingPathComponent("Received").path))
        }
    }
    func testEarlyParentReplacementAndLateConflictPreserveExistingData() async throws {
        for replacement in [true, false] {
            let f = try FolderFixture(), engine = f.engine(), tree = try await f.received()
            let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received")
            if replacement {
                try FileManager().moveItem(at: f.parent, to: f.root.appendingPathComponent("Original"))
                try FileManager().createDirectory(at: f.parent, withIntermediateDirectories: false)
                do { _ = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received", observing: observed); XCTFail() }
                catch { XCTAssertEqual(error as? FileOperationFailure, .destinationChanged) }
                do { _ = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed); XCTFail() }
                catch { XCTAssertEqual(error as? FileOperationFailure, .destinationChanged) }
            } else {
                let plan = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed)
                try Data("Keep existing".utf8).write(to: plan.destination)
                let refused = await engine.performReceivedDirectory(plan); XCTAssertNotEqual(refused.result.disposition, .succeeded)
                XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Keep existing".utf8))
            }
            await tree.abandon()
        }
    }
    func testWholeTreeReservationChargesSharedPoolBeforeAnyBodyWrite() async throws {
        let f = try FolderFixture(), store = try RemoteDownloadStore(directory: f.pool)
        let manifest = try SFTPFolderManifest(nodes: [FolderFixture.node([], directory: true), FolderFixture.node(["Huge"], size: 1 << 30)])
        let prepared = try FolderFixture.prepared(manifest), first = try await store.reserveTree(prepared)
        do { _ = try await store.reserveTree(prepared); XCTFail() } catch { XCTAssertEqual(error as? RemoteDownloadStorageFailure, .capacity) }
        let records = try await store.inspect(); XCTAssertEqual(records.count, 1); XCTAssertTrue(records[0].isFolder)
        XCTAssertLessThan(records[0].observedBytes, 64 << 10)
        await first.abandon(); let next = try await store.reserveTree(prepared); await next.abandon()
        try await store.discardIncomplete(first.id); try await store.discardIncomplete(next.id)
    }
    func testProducerPinsReceiptUntilUnusedPlanOrCancelledWorkerActuallyRetires() async throws {
        for cancelled in [false, true] {
            let f = try FolderFixture(), engine = f.engine(), tree = try await f.received()
            let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received")
            var plan: ReceivedDirectoryPlan? = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed)
            XCTAssertEqual(plan?.files, 2); await tree.abandon()
            let active = try await RemoteDownloadStore(directory: f.pool).inspect(); XCTAssertTrue(active[0].active)
            if cancelled {
                let pinned = try XCTUnwrap(plan)
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await engine.performReceivedDirectory(pinned)
                }
                let result = await task.value; XCTAssertNotEqual(result.result.disposition, .succeeded)
            }
            plan = nil
            var records = try await RemoteDownloadStore(directory: f.pool).inspect()
            for _ in 0..<100 where records[0].active { try await Task.sleep(for: .milliseconds(5)); records = try await RemoteDownloadStore(directory: f.pool).inspect() }
            XCTAssertFalse(records[0].active); XCTAssertFalse(FileManager().fileExists(atPath: f.parent.appendingPathComponent("Received").path))
        }
    }
    func testProductionTamperAndSyncFailureKeepRecordedReviewWithoutPublicFolder() async throws {
        for tamper in [false, true] {
            let f = try FolderFixture(); var hooks = RecoveryHooks()
            if tamper {
                hooks.archiveProduction.stage = { stage, payload in
                    if stage == .produced { try Data("Changed".utf8).write(to: payload.appendingPathComponent("Café/Report.txt")) }
                }
            } else { hooks.beforeSync = { _ in throw FileOperationFailure.ioFailure } }
            let engine = f.engine(hooks), tree = try await f.received(), observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received")
            let plan = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed), result = await engine.performReceivedDirectory(plan)
            XCTAssertNotNil(result.recordID); XCTAssertNotEqual(result.result.disposition, .succeeded)
            XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
            let cold = try await f.engine().inspectExistingHistory(); XCTAssertEqual(cold.records.count, 1); XCTAssertFalse(cold.records[0].canUndo)
            await tree.abandon()
        }
    }
    func testRegularFileReceiptStillUsesVersionOneAndExactUndo() async throws {
        let f = try FolderFixture(), store = try RemoteDownloadStore(directory: f.pool), engine = f.engine()
        let selected = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("File.txt".utf8)), logicalBytes: 7, modifiedSeconds: 19, permissions: 0o100644)))
        let file = try await store.reserve(selected); try await file.append(request: selected.request, offset: 0, bytes: Data("Fixture".utf8))
        _ = try await file.seal(.init(selection: selected, receivedBytes: 7))
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: f.folder(file.id).appendingPathComponent("session.meta"))) as? [String: Any]
        XCTAssertEqual(marker?["version"] as? Int, 1); XCTAssertNil(marker?["treeReservation"])
        let observed = try await engine.checkReceivedFileDestination(parent: f.parent, name: "File.txt")
        let plan = try await file.preparePublication(using: engine, parent: f.parent, name: "File.txt", observing: observed), result = await engine.performReceivedFile(plan)
        XCTAssertEqual(result.result.disposition, .succeeded); XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Fixture".utf8))
        let undone = await f.engine().undo(recordID: try XCTUnwrap(result.recordID)); XCTAssertEqual(undone.result.disposition, .succeeded)
        try await file.removeAfterDrain()
    }
    func testZIPDirectorySourceValidationAndExactExtractionUndoStillHold() async throws {
        let f = try FolderFixture(), engine = f.engine(), original = f.root.appendingPathComponent("Original.txt")
        try Data("Keep original".utf8).write(to: original)
        let selected = try await engine.observeSelection([original])
        let creation = try await engine.prepareZIPCreation(sources: [original], parent: f.parent, name: "Generated.zip", observing: selected)
        let made = await engine.performArchiveCreation(creation); XCTAssertEqual(made.result.disposition, .succeeded)
        let archive = try await engine.observeSelection([creation.destination])
        let plan = try await engine.prepareZIPExtraction(source: creation.destination, parent: f.parent, name: "Extracted", observing: archive)
        let result = await engine.performArchiveExtraction(plan); XCTAssertEqual(result.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Original.txt")), Data("Keep original".utf8))
        let undone = await f.engine().undo(recordID: try XCTUnwrap(result.recordID)); XCTAssertEqual(undone.result.disposition, .succeeded)
        let changed = try await engine.prepareZIPExtraction(source: creation.destination, parent: f.parent, name: "Changed", observing: archive)
        let handle = try FileHandle(forWritingTo: creation.destination); try handle.seek(toOffset: 0); try handle.write(contentsOf: Data([255])); try handle.close()
        let refused = await engine.performArchiveExtraction(changed); XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: original), Data("Keep original".utf8))
    }
    func testForeignEngineReplayAndChangedTreeUndoRefuse() async throws {
        let f = try FolderFixture(), engine = f.engine(), tree = try await f.received()
        let observed = try await engine.checkReceivedDirectoryDestination(parent: f.parent, name: "Received")
        let plan = try await tree.preparePublication(using: engine, parent: f.parent, name: "Received", observing: observed)
        let foreign = RecoverableFileOperations(journalDirectory: f.root.appendingPathComponent("Other history"))
        let wrong = await foreign.performReceivedDirectory(plan); XCTAssertNotEqual(wrong.result.disposition, .succeeded)
        let result = await engine.performReceivedDirectory(plan); XCTAssertEqual(result.result.disposition, .succeeded)
        let replay = await engine.performReceivedDirectory(plan); XCTAssertNotEqual(replay.result.disposition, .succeeded)
        try Data("Changed".utf8).write(to: plan.destination.appendingPathComponent("Café/Report.txt"))
        let changedUndo = await engine.undo(recordID: try XCTUnwrap(result.recordID)); XCTAssertNotEqual(changedUndo.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Café/Report.txt")), Data("Changed".utf8))
        try await tree.removeAfterDrain()
    }
}
