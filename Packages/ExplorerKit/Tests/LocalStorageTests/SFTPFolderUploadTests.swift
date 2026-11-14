import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage


final class SFTPFolderUploadLedgerTests: XCTestCase, @unchecked Sendable {
    private func refused(_ failure: RemoteSettingsFailure, _ work: () async throws -> Void) async {
        do { try await work(); XCTFail("Expected folder history refusal") } catch { XCTAssertEqual(error as? RemoteSettingsFailure, failure) }
    }
    func testPassiveStartupAndPreparedFolderKeepTypedMetadataOnly() async throws {
        let f = try FolderUploadFixture(), source = try await f.prepare(), ledger = SFTPUploadLedger(directory: f.history)
        let empty = try await ledger.inspect(); XCTAssertTrue(empty.records.isEmpty); XCTAssertFalse(FileManager().fileExists(atPath: f.history.path))
        let id = try await f.remember(ledger, source.snapshot); let snapshot = try await ledger.inspect(), record = try XCTUnwrap(snapshot.records.first)
        XCTAssertEqual(record.source, .folder(source.snapshot)); XCTAssertEqual(record.publication, .exclusiveFreshFolder); XCTAssertEqual(record.folderProgress, .init())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.history.appendingPathComponent("servers.json"))) as? [String: Any]); XCTAssertEqual(object["format"] as? Int, 3)
        await refused(.busy) { _ = try await ledger.forget(id, revision: snapshot.revision) }
        _ = try await ledger.endAfterDrain(id, noRemoteMutation: true); let closed = await ledger.close(); XCTAssertTrue(closed); await source.drain()
        let before = try f.image(), cold = try await ledger.inspect(); XCTAssertEqual(cold.records.first?.outcome, .notStarted); XCTAssertTrue(cold.active.isEmpty)
        XCTAssertEqual(try f.image(), before); _ = await ledger.close()
    }
    func testCreationBarrierAcknowledgementAndMonotonicPrefixSurviveColdOpen() async throws {
        let f = try FolderUploadFixture(); try f.file("A", Data([1])); try f.file("B", Data([2,3]))
        let source = try await f.prepare(), ledger = SFTPUploadLedger(directory: f.history), id = try await f.remember(ledger, source.snapshot)
        await refused(.invalidRecord) { try await Task.detached { try ledger.acknowledgeFolderRootOnSessionExecutor(id) }.value }
        _ = try await ledger.requestPublication(id)
        try await Task.detached { try ledger.requireFolderCreationRequestedOnSessionExecutor(id, manifestDigest: source.manifest.digest); try ledger.acknowledgeFolderRootOnSessionExecutor(id); try ledger.checkpointFolderOnSessionExecutor(id, files: 1, bytes: 1) }.value
        await refused(.invalidRecord) { try await Task.detached { try ledger.checkpointFolderOnSessionExecutor(id, files: 1, bytes: 1) }.value }
        await refused(.invalidRecord) { try await Task.detached { try ledger.checkpointFolderOnSessionExecutor(id, files: 3, bytes: 3) }.value }
        await refused(.invalidRecord) { try await Task.detached { try ledger.checkpointFolderOnSessionExecutor(id, files: 2, bytes: 0) }.value }
        _ = try await ledger.endAfterDrain(id); _ = await ledger.close(); await source.drain()
        let before = try f.image(), cold = try await ledger.inspect(); XCTAssertEqual(cold.records.first?.outcome, .reviewPublication)
        XCTAssertEqual(cold.records.first?.folderProgress, .init(rootAcknowledged: true, verifiedFiles: 1, verifiedBytes: 1)); XCTAssertEqual(try f.image(), before)
        await refused(.busy) { try await Task.detached { try ledger.checkpointFolderOnSessionExecutor(id, files: 2, bytes: 3) }.value }; _ = await ledger.close()
    }
    func testFileAndFolderCompletionCannotBeConfusedAndExactForgetIsLocal() async throws {
        let f = try FolderUploadFixture(); try f.file("Member", Data([1,2,3]))
        let source = try await f.prepare(), ledger = SFTPUploadLedger(directory: f.history), id = try await f.remember(ledger, source.snapshot)
        let digest = Data(repeating: 7, count: 32); _ = try await ledger.requestPublication(id)
        await refused(.invalidRecord) { try await Task.detached { try ledger.requireCreationRequestedOnSessionExecutor(id) }.value }
        await refused(.invalidRecord) { _ = try await ledger.verify(id, digest: digest) }
        await refused(.invalidRecord) { try await Task.detached { try ledger.verifyFolderOnSessionExecutor(id, digest: digest, files: 1, bytes: 3) }.value }
        try await Task.detached { try ledger.acknowledgeFolderRootOnSessionExecutor(id) }.value
        await refused(.invalidRecord) { try await Task.detached { try ledger.verifyFolderOnSessionExecutor(id, digest: digest, files: 1, bytes: 2) }.value }
        try await Task.detached { try ledger.verifyFolderOnSessionExecutor(id, digest: digest, files: 1, bytes: 3) }.value
        _ = try await ledger.endAfterDrain(id); _ = await ledger.close(); await source.drain()
        let cold = try await ledger.inspect(); XCTAssertEqual(cold.records.first?.outcome, .verified); XCTAssertEqual(cold.records.first?.folderProgress?.verifiedFiles, 1)
        _ = try await ledger.forget(id, revision: cold.revision); let forgotten = try await ledger.inspect(); XCTAssertTrue(forgotten.records.isEmpty); _ = await ledger.close()
        XCTAssertEqual(try Data(contentsOf: f.tree.appendingPathComponent("Member")), Data([1,2,3]))
    }
    func testCombinedActiveQuotaAndExplicitV2UpgradePreserveFileRecordEncoding() async throws {
        let f = try FolderUploadFixture(); try f.file("Member", Data([1]))
        let file = try await SFTPUploadSource.prepare(f.tree.appendingPathComponent("Member"), excluding: []), folder = try await f.prepare()
        let ledger = SFTPUploadLedger(directory: f.history)
        let first = try await ledger.prepare(host: .init(address: SFTPConnectionAddress("sftp://generated.invalid/")), account: "generated", key: f.key(), directory: "/generated", name: "Old File", source: file.snapshot, revision: 0)
        let fileID = try XCTUnwrap(first.record?.id); _ = try await ledger.endAfterDrain(fileID, noRemoteMutation: true); _ = await ledger.close()
        let fileBytes = try Data(contentsOf: f.history.appendingPathComponent("servers.json")), original = try XCTUnwrap(JSONSerialization.jsonObject(with: fileBytes) as? [String: Any])
        XCTAssertEqual(original["format"] as? Int, 2); let before = try f.image(), passive = try await ledger.inspect(); XCTAssertEqual(try f.image(), before)
        let a = try await f.remember(ledger, folder.snapshot, revision: passive.revision), b = try await f.remember(ledger, folder.snapshot, revision: passive.revision + 1)
        await refused(.capacity) { _ = try await f.remember(ledger, folder.snapshot, revision: passive.revision + 2) }
        let next = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.history.appendingPathComponent("servers.json"))) as? [String: Any])
        let oldRecords = try XCTUnwrap(original["records"] as? [[String: Any]]), newRecords = try XCTUnwrap(next["records"] as? [[String: Any]])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: oldRecords[0], options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: newRecords[0], options: [.sortedKeys]))
        _ = try await ledger.endAfterDrain(a, noRemoteMutation: true); _ = try await ledger.endAfterDrain(b, noRemoteMutation: true); _ = await ledger.close(); await file.drain(); await folder.drain()
    }
    func testFailedRootAcknowledgementRetainsConservativeRecoveryPrefix() async throws {
        final class Point: @unchecked Sendable {
            let lock = NSLock(); var commits = 0
            func observe(_ stage: SFTPUploadLedger.Stage) throws {
                let count = lock.withLock { if stage == .stagingWritten { commits += 1 }; return commits }
                if count == 3, stage == .stagingSynchronized { throw RemoteSettingsFailure.unavailable }
            }
        }
        let f = try FolderUploadFixture(), source = try await f.prepare(), point = Point()
        let ledger = SFTPUploadLedger(directory: f.history, probe: { try point.observe($0) }), id = try await f.remember(ledger, source.snapshot)
        _ = try await ledger.requestPublication(id)
        await refused(.unavailable) { try await Task.detached { try ledger.acknowledgeFolderRootOnSessionExecutor(id) }.value }
        do { _ = try await ledger.endAfterDrain(id); XCTFail() } catch {}; _ = await ledger.close(); await source.drain()
        let cold = SFTPUploadLedger(directory: f.history), before = try f.image()
        await refused(.recoveryRequired) { _ = try await cold.inspect() }; XCTAssertEqual(try f.image(), before)
        let durable = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(before["servers.json"])) as? [String: Any]), records = try XCTUnwrap(durable["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["outcome"] as? String, "publicationRequested"); XCTAssertNotNil(before["pending.json"]); _ = await cold.close()
    }
}

final class SFTPFolderUploadManifestTests: XCTestCase, @unchecked Sendable {
    typealias M = SFTPFolderUploadManifest
    private var root: M.Node { .init(kind: .directory, components: [], size: 0) }
    func testIndependentBinaryGoldenAndDigest() throws {
        // Same independently Python-packed cross-language oracle as the old
        // qualifier, now usable without a copied package or filesystem setup.
        let bytes = try XCTUnwrap(Data(base64Encoded: "VFJWRlVQMDEAAAAEAQAAAAAAAAAAAAEBAAAAAAAAAAAAAUECAgAAAAAAAAADAAFBAAhGaWxlLnR4dAIBAAAAAAAAAAAAAXo="))
        let value = try M(encoded: bytes)
        XCTAssertEqual(value.encoded, bytes); XCTAssertEqual(value.nodes.count, 4); XCTAssertEqual(value.files, 2); XCTAssertEqual(value.folders, 1); XCTAssertEqual(value.logicalBytes, 3)
        let expected = "6a7b1d545c9b2266ea0484464204800d0e792ed6aa1c2705ef6c1955578506ac"
        XCTAssertEqual(value.digest.map { String(format: "%02x", $0) }.joined(), expected)
    }
    func testEmptyFolderAndExactUTF8OrderingWithoutSearchNormalization() throws {
        XCTAssertEqual(try M(nodes: [root]).files, 0)
        let names = ["A", "a", "e\u{301}", "é", "色", "🧭"].map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        let value = try M(nodes: [root] + names.map { .init(kind: .file, components: [$0], size: 0) })
        XCTAssertEqual(try M(encoded: value.encoded), value); XCTAssertEqual(value.files, names.count)
    }
    func testMalformedMagicVersionTrailingTruncationKindAndCount() throws {
        let bytes = try M(nodes: [root]).encoded
        for length in 0..<bytes.count { XCTAssertThrowsError(try M(encoded: bytes.prefix(length))) }
        var variants = [bytes + Data([0]), Data(repeating: 0, count: bytes.count)]
        for (offset, byte) in [(7, UInt8(50)), (12, UInt8(3)), (13, UInt8(33)), (8, UInt8(255))] { var changed = bytes; changed[offset] = byte; variants.append(changed) }
        for value in variants { XCTAssertThrowsError(try M(encoded: value)) }
    }
    func testWholeManifestRejectsDuplicateUnorderedOrMissingParent() throws {
        let a = M.Node(kind: .directory, components: [Data("a".utf8)], size: 0)
        let b = M.Node(kind: .file, components: [Data("b".utf8)], size: 1)
        for nodes in [[], [b], [root, a, a], [root, b, a], [root, .init(kind: .file, components: [Data("a".utf8), Data("x".utf8)], size: 0)],
                      [root, b, .init(kind: .file, components: [Data("b".utf8), Data("x".utf8)], size: 0)]] { XCTAssertThrowsError(try M(nodes: nodes)) }
    }
    func testActualNameNodeFileDepthAndAggregateBounds() throws {
        for name in [Data(), Data([0]), Data([47]), Data([46]), Data([46,46]), Data([255]), Data(repeating: 65, count: 256)] {
            XCTAssertThrowsError(try M(nodes: [root, .init(kind: .file, components: [name], size: 0)]))
        }
        var files = [root] + (0..<M.maximumFiles).map { M.Node(kind: .file, components: [Data(String(format: "%04d", $0).utf8)], size: 0) }
        XCTAssertEqual(try M(nodes: files).files, M.maximumFiles); files.append(.init(kind: .file, components: [Data("z".utf8)], size: 0)); XCTAssertThrowsError(try M(nodes: files))
        var folders = [root]; for depth in 1...M.maximumDepth { folders.append(.init(kind: .directory, components: Array(repeating: Data([65]), count: depth), size: 0)) }
        XCTAssertNoThrow(try M(nodes: folders)); folders.append(.init(kind: .directory, components: Array(repeating: Data([65]), count: M.maximumDepth + 1), size: 0)); XCTAssertThrowsError(try M(nodes: folders))
        XCTAssertThrowsError(try M(nodes: [root, .init(kind: .directory, components: [Data([65])], size: 1)]))
        XCTAssertNoThrow(try M(nodes: [root, .init(kind: .file, components: [Data([65])], size: 1 << 30)]))
        XCTAssertThrowsError(try M(nodes: [root, .init(kind: .file, components: [Data([65])], size: 1 << 30), .init(kind: .file, components: [Data([66])], size: 1)]))
        XCTAssertThrowsError(try M(nodes: [root, .init(kind: .file, components: [Data([65])], size: UInt64.max)]))
    }
}

final class SFTPFolderUploadSourceTests: XCTestCase, @unchecked Sendable {
    func testMetadataInventoryHiddenEmptyNestedAndSequentialBytes() async throws {
        let f = try FolderUploadFixture(); try f.folder("Empty"); try f.folder("Nested"); try f.file(".hidden", Data()); try f.file("Nested/Member", Data([1,2,3]))
        let source = try await f.prepare(); XCTAssertEqual(source.manifest.files, 2); XCTAssertEqual(source.manifest.folders, 2)
        XCTAssertEqual(source.snapshot.logicalBytes, 3); try source.snapshot.validate(); try await source.validateBeforeMutation()
        let result = try await Task.detached {
            for (index, node) in source.manifest.nodes.enumerated() where !node.directory {
                var data = Data(); while UInt64(data.count) < node.size { data.append(try source.readOnSessionExecutor(node: index, offset: UInt64(data.count), maximum: 2)) }
                try source.finishFileOnSessionExecutor(node: index, digest: Data(SHA256.hash(data: data)))
            }
            return try source.finishOnSessionExecutor()
        }.value
        XCTAssertEqual(result.count, 32); XCTAssertEqual(try Data(contentsOf: f.tree.appendingPathComponent("Nested/Member")), Data([1,2,3])); await source.drain()
    }
    func testReviewDoesNotReadBodiesAndEmptyFolderRequiresFinalValidation() async throws {
        let f = try FolderUploadFixture(), source = try await f.prepare(probe: { XCTFail("Review read a body") })
        XCTAssertEqual(source.manifest.nodes.count, 1); try await source.validateBeforeMutation()
        let hash = try await Task.detached { try source.finishOnSessionExecutor() }.value; XCTAssertEqual(hash.count, 32); await source.drain()
    }
    func testEveryUnsupportedMemberRefusesWholeSelection() async throws {
        for variant in 0..<4 {
            let f = try FolderUploadFixture(); try f.file("Original", Data([1]))
            let path = f.tree.appendingPathComponent("Bad").path
            if variant == 0 { XCTAssertEqual(symlink("Original", path), 0) }
            if variant == 1 { XCTAssertEqual(link(f.tree.appendingPathComponent("Original").path, path), 0) }
            if variant == 2 { XCTAssertEqual(mkfifo(path, 0o600), 0) }
            if variant == 3 { let value = [UInt8(2)]; XCTAssertEqual(value.withUnsafeBytes { setxattr(f.tree.appendingPathComponent("Original").path, "com.apple.ResourceFork", $0.baseAddress, 1, 0, 0) }, 0) }
            do { let value = try await f.prepare(); await value.drain(); XCTFail("Unsupported selection admitted") } catch {}
            XCTAssertEqual(try Data(contentsOf: f.tree.appendingPathComponent("Original")), Data([1]))
        }
    }
    func testAdditionRemovalRenameAndSameBytesReplacementRefuseBeforeMutation() async throws {
        for variant in 0..<4 {
            let f = try FolderUploadFixture(); try f.file("Member", Data([1])); let source = try await f.prepare()
            let original = f.tree.appendingPathComponent("Member"), retained = f.root.appendingPathComponent("Retained")
            if variant == 0 { try f.file("Added", Data()) }
            else { try FileManager().moveItem(at: original, to: retained); if variant == 2 { try Data([1]).write(to: original, options: .withoutOverwriting) }; if variant == 3 { try FileManager().moveItem(at: retained, to: f.tree.appendingPathComponent("Renamed")) } }
            do { try await source.validateBeforeMutation(); XCTFail() } catch {}; await source.drain()
        }
    }
    func testSourceChangeAfterAdmissionAndFinalInventoryChangeRefuse() async throws {
        for variant in 0..<2 {
            let f = try FolderUploadFixture(); try f.file("Member", Data([1])); let source = try await f.prepare(); try await source.validateBeforeMutation()
            do {
                try await Task.detached {
                    if variant == 0 { let fd = open(f.tree.appendingPathComponent("Member").path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW); defer { close(fd) }; XCTAssertEqual(pwrite(fd, [UInt8(2)], 1, 0), 1) }
                    let data = try source.readOnSessionExecutor(node: 1, offset: 0, maximum: 1)
                    try source.finishFileOnSessionExecutor(node: 1, digest: Data(SHA256.hash(data: data)))
                    try f.file("Added", Data()); _ = try source.finishOnSessionExecutor()
                }.value; XCTFail()
            } catch {}; await source.drain()
        }
    }
    func testUnadmittedWrongNodeOffsetAndDigestPoisonRequest() async throws {
        for variant in 0..<4 {
            let f = try FolderUploadFixture(); try f.file("Member", Data([1])); let source = try await f.prepare()
            if variant != 0 { try await source.validateBeforeMutation() }
            do {
                try await Task.detached {
                    if variant == 3 { _ = try source.readOnSessionExecutor(node: 1, offset: 0, maximum: 1); try source.finishFileOnSessionExecutor(node: 1, digest: Data(repeating: 0, count: 32)) }
                    else { _ = try source.readOnSessionExecutor(node: variant == 1 ? 0 : 1, offset: variant == 2 ? 1 : 0, maximum: 1) }
                }.value; XCTFail()
            } catch {}
            do { _ = try await Task.detached { try source.readOnSessionExecutor(node: 1, offset: 0, maximum: 1) }.value; XCTFail() } catch {}; await source.drain()
        }
    }
    func testExcludedRootAndSymlinkRootNeverInventory() async throws {
        let f = try FolderUploadFixture(); try f.file("Member")
        let alias = f.root.appendingPathComponent("Link"); try FileManager().createSymbolicLink(at: alias, withDestinationURL: f.tree)
        for (url, exclusions) in [(f.tree, [f.root]), (alias, [])] {
            do { let source = try await SFTPFolderUploadSource.prepare(url, excluding: exclusions); await source.drain(); XCTFail() } catch {}
        }
    }
    func testStopAndDrainWaitForActualBodyReader() async throws {
        final class Gate: @unchecked Sendable {
            let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1)), release = DispatchSemaphore(value: 0)
            let lock = NSLock(); var didReturn = false
            func hold() throws { XCTAssertFalse(Thread.isMainThread); entered.continuation.yield(()); guard release.wait(timeout: .now() + 5) == .success else { throw SFTPUploadSourceFailure.unavailable }; lock.withLock { didReturn = true } }
        }
        let f = try FolderUploadFixture(); try f.file("Member"); let gate = Gate(), source = try await f.prepare(probe: { try gate.hold() }); try await source.validateBeforeMutation()
        let read = Task.detached { try source.readOnSessionExecutor(node: 1, offset: 0, maximum: 1) }; var events = gate.entered.stream.makeAsyncIterator(); _ = await events.next()
        source.requestStop(); let drain = Task { await source.drain() }; await Task.yield(); XCTAssertFalse(gate.lock.withLock { gate.didReturn }); gate.release.signal()
        do { _ = try await read.value; XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .stopped) }; await drain.value
        XCTAssertTrue(gate.lock.withLock { gate.didReturn })
    }
    func testActualWholeTreeFileAndDepthLimits() async throws {
        let files = try FolderUploadFixture()
        for index in 0...SFTPFolderUploadManifest.maximumFiles { try files.file(String(format: "%04d", index), Data()) }
        do { let source = try await files.prepare(); await source.drain(); XCTFail("Whole oversized selection admitted") } catch {}
        let deep = try FolderUploadFixture(); try deep.folder(Array(repeating: "d", count: SFTPFolderUploadManifest.maximumDepth + 1).joined(separator: "/"))
        do { let source = try await deep.prepare(); await source.drain(); XCTFail("Deep selection admitted") } catch {}
    }
    func testCancelledInventoryWaitsForRealMetadataUserAndReleasesAccess() async throws {
        final class Gate: @unchecked Sendable {
            let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1)), release = DispatchSemaphore(value: 0)
            let lock = NSLock(); var starts = 0, stops = 0, returned = false
            func hold() throws { XCTAssertFalse(Thread.isMainThread); entered.continuation.yield(()); guard release.wait(timeout: .now() + 5) == .success else { throw SFTPUploadSourceFailure.unavailable }; lock.withLock { returned = true } }
        }
        let f = try FolderUploadFixture(), gate = Gate()
        let task = Task { try await SFTPFolderUploadSource.prepare(f.tree, excluding: [], accessHooks: .init(start: { _ in gate.lock.withLock { gate.starts += 1 }; return true }, stop: { _ in gate.lock.withLock { gate.stops += 1 } }), inventoryProbe: { try gate.hold() }) }
        var events = gate.entered.stream.makeAsyncIterator(); _ = await events.next(); task.cancel()
        XCTAssertEqual(gate.lock.withLock { gate.stops }, 0); XCTAssertFalse(gate.lock.withLock { gate.returned }); gate.release.signal()
        do { let source = try await task.value; await source.drain(); XCTFail() } catch { XCTAssertEqual(error as? SFTPUploadSourceFailure, .stopped) }
        XCTAssertEqual(gate.lock.withLock { gate.starts }, 1); XCTAssertEqual(gate.lock.withLock { gate.stops }, 1); XCTAssertTrue(gate.lock.withLock { gate.returned })
    }
}
