import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPRemoteActionTests: XCTestCase, @unchecked Sendable {
    func testActionProtocolRequiresPrepareThenPermitAndInvalidatesConfirmedCatalog() throws {
        let session = UUID(), generation = UUID(), mode = SFTPWireMode.remoteActionCatalog
        func body(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data()) throws -> Data {
            try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
        }
        func summary(_ state: UInt8) -> Data {
            var data = Data(); for value in [UInt64(1), 0, 0, 0] { SFTPWire.number(value, bytes: 8, into: &data) }
            data.append(state); return data
        }
        var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.invalid", port: 22,
                                             mode: mode, inPlaceTransfers: .all)
        let context = try context(); var challenge = Data([1])
        try SFTPWire.field(Data("generated.invalid".utf8), into: &challenge)
        SFTPWire.number(22, bytes: 2, into: &challenge)
        try SFTPWire.field(context.key.bytes, into: &challenge)
        try SFTPWire.field(Data(), into: &challenge)
        guard case .challenge(let review) = try decoder.consume(body(0, 100, challenge)) else { return XCTFail() }
        try decoder.noteApproval(.connectOnce, challenge: review)
        _ = try decoder.consume(body(1, 101)); _ = try decoder.consume(body(2, 102)); _ = try decoder.consume(body(3, 109))
        try decoder.beginDirectory(generation)
        var opened = SFTPWire.token(generation); try SFTPWire.field(Data("/generated".utf8), into: &opened); opened.append(summary(0))
        _ = try decoder.consume(body(4, 110, opened)); try decoder.beginNext(generation)
        guard case .storedProgress(_, let snapshot) = try decoder.consume(body(5, 111, SFTPWire.token(generation) + summary(1))) else { return XCTFail() }
        XCTAssertEqual(snapshot.revision, 0)
        let directoryRename = try SFTPRemoteActionIntent.renameDirectory(generation: generation,
            snapshot: snapshot, row: directoryRow("Directory"), newName: .init(Data("Renamed".utf8)))
        XCTAssertEqual(try decoder.remoteActionDirectory(directoryRename), "/generated")
        let first = try SFTPRemoteActionIntent.newFolder(generation: generation, snapshot: snapshot,
                                                         name: .init(Data("New Folder".utf8)))
        XCTAssertEqual(try decoder.remoteActionDirectory(first), "/generated")
        try decoder.beginRemoteAction(first)
        XCTAssertThrowsError(try decoder.permitRemoteAction(first.request))
        guard case .remoteActionPrepared(let prepared) = try decoder.consume(body(6, 210, SFTPWire.token(first.request))) else { return XCTFail() }
        XCTAssertEqual(prepared, first.request); try decoder.permitRemoteAction(first.request)
        guard case .remoteActionRefused(let refused, let reason) = try decoder.consume(body(7, 212, SFTPWire.token(first.request) + Data([1]))) else { return XCTFail() }
        XCTAssertEqual(refused, first.request); XCTAssertEqual(reason, .targetExists)
        let directory = try SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: generation,
            snapshot: snapshot, row: directoryRow("Empty"))
        try decoder.beginRemoteAction(directory)
        guard case .remoteActionRefused(let emptyID, let emptyReason) = try decoder.consume(body(8, 212,
            SFTPWire.token(directory.request) + Data([6]))) else { return XCTFail() }
        XCTAssertEqual(emptyID, directory.request); XCTAssertEqual(emptyReason, .notEmpty)
        let second = try SFTPRemoteActionIntent.newFolder(generation: generation, snapshot: snapshot,
                                                          name: .init(Data("Another Folder".utf8)))
        try decoder.beginRemoteAction(second)
        _ = try decoder.consume(body(9, 210, SFTPWire.token(second.request)))
        try decoder.permitRemoteAction(second.request)
        guard case .remoteActionConfirmed(let confirmed) = try decoder.consume(body(10, 211, SFTPWire.token(second.request))) else { return XCTFail() }
        XCTAssertEqual(confirmed, second.request)
        XCTAssertThrowsError(try decoder.remoteActionDirectory(second))
    }
    private func context() throws -> SFTPVerifiedSessionContext {
        var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes)
        try SFTPWire.field(Data(repeating: 1, count: 32), into: &bytes)
        return .init(host: "generated.invalid", port: 22, requestedScopeID: 0, account: "generated",
                     key: try SFTPHostKey(bytes), previous: nil, permitsRememberingHost: false)
    }
    private func row(_ name: String) throws -> SFTPStoredRow {
        try .init(observation: 7, entry: .init(name: .init(Data(name.utf8)), logicalBytes: 1,
                                                  modifiedSeconds: 2, permissions: 0o100644))
    }
    private func directoryRow(_ name: String, mode: UInt32 = 0o040755) throws -> SFTPStoredRow {
        try .init(observation: 7, entry: .init(name: .init(Data(name.utf8)), logicalBytes: 0,
                                                  modifiedSeconds: 2, permissions: mode))
    }
    func testCopyIntentHasDistinctCodeAndRejectsUnsupportedSelection() throws {
        let fixed = try XCTUnwrap(UUID(uuidString: "07070707-0707-0707-0707-070707070707"))
        XCTAssertEqual(SFTPRemoteActionRecord.stageName(for: fixed),
                       ".mac-explorer-copy-07070707070707070707070707070707.part")
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0,
            count: 1, folders: 0, state: .complete)
        let parent = try SFTPDefaultDirectory(field: "/generated/Other", root: .server)
        let newName = try SFTPRemoteName(Data("copy.txt".utf8))
        let intent = try SFTPRemoteActionIntent.copyFile(generation: generation, snapshot: snapshot,
            row: row("file.txt"), destinationDirectory: parent, newName: newName)
        let command = try intent.command()
        XCTAssertEqual(command[48], 8)
        XCTAssertEqual(command.suffix(parent.pathUTF8.count), parent.pathUTF8)
        XCTAssertEqual(intent.destination, "copy.txt")
        XCTAssertThrowsError(try SFTPRemoteActionIntent.copyFile(generation: generation,
            snapshot: snapshot, row: directoryRow("folder"), destinationDirectory: parent, newName: newName))
        let privileged = try SFTPStoredRow(observation: 7, entry: .init(name: .init(Data("file.txt".utf8)),
            logicalBytes: 1, modifiedSeconds: 2, permissions: 0o104755))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.copyFile(generation: generation,
            snapshot: snapshot, row: privileged, destinationDirectory: parent, newName: newName))
        let tooLarge = try SFTPStoredRow(observation: 7, entry: .init(name: .init(Data("file.txt".utf8)),
            logicalBytes: (64 << 30) + 1, modifiedSeconds: 2, permissions: 0o100644))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.copyFile(generation: generation,
            snapshot: snapshot, row: tooLarge, destinationDirectory: parent, newName: newName))
        let atLimit = try SFTPStoredRow(observation: 7, entry: .init(name: .init(Data("file.txt".utf8)),
            logicalBytes: 64 << 30, modifiedSeconds: 2, permissions: 0o100644))
        XCTAssertNoThrow(try SFTPRemoteActionIntent.copyFile(generation: generation,
            snapshot: snapshot, row: atLimit, destinationDirectory: parent, newName: newName))
    }
    func testCopyColdReceiptRetainsExactStageAndUncertainOutcome() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let path = root.appendingPathComponent("sftp-remote-actions")
        let store = SFTPRemoteActionStore(directory: path)
        let snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 0, state: .complete)
        let old = try SFTPRemoteActionIntent.newFolder(generation: UUID(), snapshot: snapshot,
            name: .init(Data("Older".utf8)))
        _ = try await store.prepare(old, context: context(), directory: "/generated")
        _ = try await store.update(old.request, outcome: .failedSafe, refusal: .targetExists)
        let intent = try SFTPRemoteActionIntent.copyFile(generation: UUID(), snapshot: snapshot,
            row: row("file.txt"), destinationDirectory: .init(field: "/generated/Other", root: .server),
            newName: .init(Data("copy.txt".utf8)))
        let prepared = try await store.prepare(intent, context: context(), directory: "/generated")
        let stage = ".mac-explorer-copy-\(intent.request.uuidString.replacingOccurrences(of: "-", with: "")).part"
        XCTAssertEqual(prepared.record.copyStageName, stage)
        _ = try await store.update(intent.request, outcome: .needsReview)
        await store.releaseAfterDrain(intent.request)
        let closed = await store.close(); XCTAssertTrue(closed)
        let cold = SFTPRemoteActionStore(directory: path)
        let records = try await cold.inspect().records
        XCTAssertEqual(records.first { $0.id == old.request }?.outcome, .failedSafe)
        let copy = try XCTUnwrap(records.first { $0.id == intent.request })
        XCTAssertEqual(copy.kind, .copyFile)
        XCTAssertEqual(copy.outcome, .needsReview)
        XCTAssertEqual(copy.remoteDirectory, "/generated")
        XCTAssertEqual(copy.remoteName, "file.txt")
        XCTAssertEqual(copy.destinationDirectory, "/generated/Other")
        XCTAssertEqual(copy.destinationName, "copy.txt")
        XCTAssertEqual(copy.copyStageName, stage)
        var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as? [String: Any])
        altered["copyStageName"] = "other.part"
        let corrupted = try JSONDecoder().decode(SFTPRemoteActionRecord.self, from: JSONSerialization.data(withJSONObject: altered))
        XCTAssertThrowsError(try corrupted.validate())
        let coldClosed = await cold.close(); XCTAssertTrue(coldClosed)
    }
    func testCopyCapabilityIsSingleAuthenticatedPreReadyFact() throws {
        let session = UUID(), mode = SFTPWireMode.remoteActionCatalog
        func body(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data()) throws -> Data {
            try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
        }
        var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.invalid", port: 22,
                                             mode: mode, inPlaceTransfers: .all)
        let context = try context(); var challenge = Data([1])
        try SFTPWire.field(Data("generated.invalid".utf8), into: &challenge)
        SFTPWire.number(22, bytes: 2, into: &challenge)
        try SFTPWire.field(context.key.bytes, into: &challenge)
        try SFTPWire.field(Data(), into: &challenge)
        guard case .challenge(let review) = try decoder.consume(body(0, 100, challenge)) else { return XCTFail() }
        try decoder.noteApproval(.connectOnce, challenge: review)
        _ = try decoder.consume(body(1, 101)); _ = try decoder.consume(body(2, 102))
        XCTAssertFalse(decoder.supportsServerCopy)
        XCTAssertNil(try decoder.consume(body(3, 214, Data([1]))))
        XCTAssertTrue(decoder.supportsServerCopy)
        _ = try decoder.consume(body(4, 109))
        XCTAssertThrowsError(try decoder.consume(body(5, 214, Data([1]))))
    }
    func testEmptyDirectoryDeleteHasDistinctKindAndFileActionsRejectDirectoryOrLink() throws {
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 1, state: .complete)
        let directory = try directoryRow("Empty")
        let intent = try SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: generation,
            snapshot: snapshot, row: directory)
        XCTAssertEqual(intent.kind, .deleteEmptyDirectoryPermanently)
        XCTAssertThrowsError(try SFTPRemoteActionIntent.deleteFilePermanently(generation: generation,
            snapshot: snapshot, row: directory))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.renameFile(generation: generation,
            snapshot: snapshot, row: directory, newName: .init(Data("Other".utf8))))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: generation,
            snapshot: snapshot, row: row("file.txt")))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: generation,
            snapshot: snapshot, row: directoryRow("link", mode: 0o120777)))
    }
    func testDirectoryRenameHasDistinctDirectActionKindAndRefusesFileLinkOrSameName() throws {
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0,
            count: 1, folders: 1, state: .complete)
        let source = try directoryRow("e\u{301}")
        let destination = try SFTPRemoteName(Data("é".utf8))
        let intent = try SFTPRemoteActionIntent.renameDirectory(generation: generation,
            snapshot: snapshot, row: source, newName: destination)
        XCTAssertEqual(intent.kind, .renameDirectory)
        XCTAssertEqual(try intent.command()[48], 5)
        XCTAssertNotEqual(source.entry.name.wireUTF8, destination.wireUTF8)
        XCTAssertThrowsError(try SFTPRemoteActionIntent.renameDirectory(generation: generation,
            snapshot: snapshot, row: source, newName: source.entry.name))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.renameDirectory(generation: generation,
            snapshot: snapshot, row: row("file.txt"), newName: destination))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.renameDirectory(generation: generation,
            snapshot: snapshot, row: directoryRow("link", mode: 0o120777), newName: destination))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.renameFile(generation: generation,
            snapshot: snapshot, row: source, newName: destination))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.deleteFilePermanently(generation: generation,
            snapshot: snapshot, row: source))
    }
    func testFileMoveUsesDistinctBoundedAbsoluteParentAndPreservesLegacyCommandBytes() throws {
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0,
            count: 1, folders: 0, state: .complete)
        let selected = try row("file.txt")
        let parent = try SFTPDefaultDirectory(field: "/generated/Other", root: .server)
        let intent = try SFTPRemoteActionIntent.moveFile(generation: generation,
            snapshot: snapshot, row: selected, destinationDirectory: parent)
        let bytes = try intent.command()
        XCTAssertEqual(intent.kind, .moveFile)
        XCTAssertEqual(bytes[48], 6)
        XCTAssertEqual(bytes.suffix(parent.pathUTF8.count), parent.pathUTF8)
        XCTAssertThrowsError(try SFTPRemoteActionIntent.moveFile(generation: generation,
            snapshot: snapshot, row: selected, destinationDirectory: .init(root: .home)))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.moveFile(generation: generation,
            snapshot: snapshot, row: directoryRow("folder"), destinationDirectory: parent))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.moveFile(generation: generation,
            snapshot: snapshot, row: directoryRow("link", mode: 0o120777), destinationDirectory: parent))
        let old = try SFTPRemoteActionIntent.renameFile(generation: generation,
            snapshot: snapshot, row: selected, newName: .init(Data("renamed.txt".utf8)))
        XCTAssertEqual(try old.command().count, 100)
    }
    func testFileMoveColdReceiptKeepsBothParentsAndRejectsSameParent() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let path = root.appendingPathComponent("sftp-remote-actions")
        let store = SFTPRemoteActionStore(directory: path)
        let snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 0, state: .complete)
        let selected = try row("file.txt")
        let same = try SFTPRemoteActionIntent.moveFile(generation: UUID(), snapshot: snapshot,
            row: selected, destinationDirectory: .init(field: "/generated", root: .server))
        do { _ = try await store.prepare(same, context: context(), directory: "/generated"); XCTFail("Same parent accepted") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .invalidRecord) }
        let move = try SFTPRemoteActionIntent.moveFile(generation: UUID(), snapshot: snapshot,
            row: selected, destinationDirectory: .init(root: .server, components: [
                .init(Data("generated".utf8)), .init(Data("\u{202e}Other".utf8))]))
        _ = try await store.prepare(move, context: context(), directory: "/generated")
        _ = try await store.update(move.request, outcome: .needsReview)
        await store.releaseAfterDrain(move.request)
        let closed = await store.close(); XCTAssertTrue(closed)
        let cold = SFTPRemoteActionStore(directory: path)
        let snapshotAfterRestart = try await cold.inspect()
        let record = try XCTUnwrap(snapshotAfterRestart.records.first)
        XCTAssertEqual(record.kind, .moveFile)
        XCTAssertEqual(record.remoteDirectory, "/generated")
        XCTAssertEqual(record.remoteName, "file.txt")
        XCTAssertNil(record.destinationName)
        XCTAssertEqual(record.destinationDirectory, "/generated/\u{202e}Other")
        XCTAssertEqual(record.displayDestinationDirectory, "/generated/\\u{202e}Other")
        XCTAssertEqual(record.outcome, .needsReview)
        let coldClosed = await cold.close(); XCTAssertTrue(coldClosed)
    }
    func testDirectoryMoveUsesDistinctKindAndRefusesFileLinkOrHomeParent() throws {
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0,
            count: 1, folders: 1, state: .complete)
        let folder = try directoryRow("Folder")
        let parent = try SFTPDefaultDirectory(field: "/generated/Other", root: .server)
        let intent = try SFTPRemoteActionIntent.moveDirectory(generation: generation,
            snapshot: snapshot, row: folder, destinationDirectory: parent)
        let bytes = try intent.command()
        XCTAssertEqual(intent.kind, .moveDirectory)
        XCTAssertEqual(bytes[48], 7)
        XCTAssertEqual(bytes.suffix(parent.pathUTF8.count), parent.pathUTF8)
        XCTAssertThrowsError(try SFTPRemoteActionIntent.moveDirectory(generation: generation,
            snapshot: snapshot, row: folder, destinationDirectory: .init(root: .home)))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.moveDirectory(generation: generation,
            snapshot: snapshot, row: row("file.txt"), destinationDirectory: parent))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.moveDirectory(generation: generation,
            snapshot: snapshot, row: directoryRow("link", mode: 0o120777), destinationDirectory: parent))
    }
    func testDirectoryMoveColdReceiptKeepsBothParentsAndRejectsSelfOrDescendant() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let path = root.appendingPathComponent("sftp-remote-actions")
        let store = SFTPRemoteActionStore(directory: path)
        let snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 1, state: .complete)
        let selected = try directoryRow("Folder")
        for refused in ["/generated", "/generated/Folder", "/generated/Folder/Child"] {
            let intent = try SFTPRemoteActionIntent.moveDirectory(generation: UUID(), snapshot: snapshot,
                row: selected, destinationDirectory: .init(field: refused, root: .server))
            do { _ = try await store.prepare(intent, context: context(), directory: "/generated"); XCTFail("Unsafe parent accepted") }
            catch { XCTAssertEqual(error as? RemoteSettingsFailure, .invalidRecord) }
        }
        let sibling = try SFTPRemoteActionIntent.moveDirectory(generation: UUID(), snapshot: snapshot,
            row: selected, destinationDirectory: .init(field: "/generated/Folder2", root: .server))
        _ = try await store.prepare(sibling, context: context(), directory: "/generated")
        _ = try await store.update(sibling.request, outcome: .needsReview)
        await store.releaseAfterDrain(sibling.request)
        let closed = await store.close(); XCTAssertTrue(closed)
        let cold = SFTPRemoteActionStore(directory: path)
        let coldSnapshot = try await cold.inspect()
        let record = try XCTUnwrap(coldSnapshot.records.first)
        XCTAssertEqual(record.kind, .moveDirectory)
        XCTAssertEqual(record.remoteDirectory, "/generated")
        XCTAssertEqual(record.remoteName, "Folder")
        XCTAssertEqual(record.destinationDirectory, "/generated/Folder2")
        XCTAssertEqual(record.outcome, .needsReview)
        let coldClosed = await cold.close(); XCTAssertTrue(coldClosed)
    }
    func testMoveColdHistoryKeepsByteDistinctUnicodeParentsAndFolderPrefixes() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let path = root.appendingPathComponent("sftp-remote-actions")
        let store = SFTPRemoteActionStore(directory: path)
        let composed = "/é", decomposed = "/e\u{301}"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let fileSnapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 0, state: .complete)
        let file = try SFTPRemoteActionIntent.moveFile(generation: UUID(), snapshot: fileSnapshot,
            row: row("file.txt"), destinationDirectory: .init(field: decomposed, root: .server))
        _ = try await store.prepare(file, context: context(), directory: composed)
        _ = try await store.update(file.request, outcome: .failedSafe, refusal: .targetExists)

        let folderSnapshot = SFTPStoredSnapshot(read: 2, revision: 0, count: 1, folders: 1, state: .complete)
        let folderDestination = "/generated/e\u{301}/Child"
        let folder = try SFTPRemoteActionIntent.moveDirectory(generation: UUID(), snapshot: folderSnapshot,
            row: directoryRow("é"), destinationDirectory: .init(field: folderDestination, root: .server))
        _ = try await store.prepare(folder, context: context(), directory: "/generated")
        _ = try await store.update(folder.request, outcome: .needsReview)
        await store.releaseAfterDrain(folder.request)
        let closed = await store.close(); XCTAssertTrue(closed)

        let cold = SFTPRemoteActionStore(directory: path)
        let records = try await cold.inspect().records
        let fileRecord = try XCTUnwrap(records.first { $0.id == file.request })
        let folderRecord = try XCTUnwrap(records.first { $0.id == folder.request })
        let fileDestination = try XCTUnwrap(fileRecord.destinationDirectory)
        let restoredFolderDestination = try XCTUnwrap(folderRecord.destinationDirectory)
        XCTAssertEqual(Data(fileRecord.remoteDirectory.utf8), Data(composed.utf8))
        XCTAssertEqual(Data(fileDestination.utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(folderRecord.remoteName.utf8), Data("é".utf8))
        XCTAssertEqual(Data(restoredFolderDestination.utf8), Data(folderDestination.utf8))
        let coldClosed = await cold.close(); XCTAssertTrue(coldClosed)
    }
    func testDirectoryDeleteReceiptPreservesOldHistoryAndColdUncertainty() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let store = SFTPRemoteActionStore(directory: root.appendingPathComponent("sftp-remote-actions"))
        let snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 1, state: .complete)
        let old = try SFTPRemoteActionIntent.newFolder(generation: UUID(), snapshot: snapshot,
                                                       name: .init(Data("Older".utf8)))
        _ = try await store.prepare(old, context: context(), directory: "/generated")
        _ = try await store.update(old.request, outcome: .failedSafe, refusal: .targetExists)
        let deletion = try SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: UUID(),
            snapshot: snapshot, row: directoryRow("Empty"))
        _ = try await store.prepare(deletion, context: context(), directory: "/generated")
        _ = try await store.update(deletion.request, outcome: .needsReview)
        await store.releaseAfterDrain(deletion.request)
        let rename = try SFTPRemoteActionIntent.renameDirectory(generation: UUID(), snapshot: snapshot,
            row: directoryRow("Directory"), newName: .init(Data("Renamed".utf8)))
        _ = try await store.prepare(rename, context: context(), directory: "/generated")
        _ = try await store.update(rename.request, outcome: .needsReview)
        await store.releaseAfterDrain(rename.request)
        let closed = await store.close(); XCTAssertTrue(closed)
        let cold = SFTPRemoteActionStore(directory: root.appendingPathComponent("sftp-remote-actions"))
        let records = try await cold.inspect().records
        XCTAssertEqual(records.first(where: { $0.id == old.request })?.outcome, .failedSafe)
        XCTAssertEqual(records.first(where: { $0.id == deletion.request })?.kind, .deleteEmptyDirectoryPermanently)
        XCTAssertEqual(records.first(where: { $0.id == deletion.request })?.outcome, .needsReview)
        XCTAssertEqual(records.first(where: { $0.id == rename.request })?.kind, .renameDirectory)
        XCTAssertEqual(records.first(where: { $0.id == rename.request })?.destinationName, "Renamed")
        XCTAssertEqual(records.first(where: { $0.id == rename.request })?.outcome, .needsReview)
        let coldClosed = await cold.close(); XCTAssertTrue(coldClosed)
    }
    func testZeroRevisionAndByteDistinctRenameAreAccepted() throws {
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 0, state: .complete)
        let decomposed = try row("e\u{301}.txt"), composed = try SFTPRemoteName(Data("é.txt".utf8))
        let intent = try SFTPRemoteActionIntent.renameFile(generation: generation, snapshot: snapshot,
                                                            row: decomposed, newName: composed)
        XCTAssertEqual(intent.kind, .renameFile)
        XCTAssertEqual(intent.snapshot.revision, 0)
        XCTAssertNotEqual(Data(intent.remoteName.utf8), Data(intent.destination!.utf8))
        XCTAssertThrowsError(try SFTPRemoteActionIntent.renameFile(generation: generation, snapshot: snapshot,
                                                                    row: decomposed, newName: decomposed.entry.name))
    }
    func testActionReceiptEscapesNamesAndDirectoryOnlyForPresentation() throws {
        let snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 0, state: .complete)
        let source = "\u{202e}source.txt", destination = "new\nname.txt", directory = "/generated/\u{202e}folder"
        let intent = try SFTPRemoteActionIntent.renameFile(generation: UUID(), snapshot: snapshot,
                                                            row: row(source), newName: .init(Data(destination.utf8)))
        let receipt = try SFTPRemoteActionRecord(intent: intent, context: context(), directory: directory)
        XCTAssertEqual(receipt.remoteName, source)
        XCTAssertEqual(receipt.destinationName, destination)
        XCTAssertEqual(receipt.remoteDirectory, directory)
        XCTAssertEqual(receipt.displayRemoteName, "\\u{202e}source.txt")
        XCTAssertEqual(receipt.displayDestinationName, "new\\u{a}name.txt")
        XCTAssertEqual(receipt.displayRemoteDirectory, "/generated/\\u{202e}folder")
    }
    func testDurableHistoryAndOneCommitClearRetainUncertainAndActive() async throws {
        let root = try LocalStorageTestFixtures.directory(), store = SFTPRemoteActionStore(directory: root.appendingPathComponent("sftp-remote-actions"))
        let generation = UUID(), snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 1, folders: 0, state: .complete)
        let folder = try SFTPRemoteActionIntent.newFolder(generation: generation, snapshot: snapshot,
                                                            name: .init(Data("New Folder".utf8)))
        let prepared = try await store.prepare(folder, context: context(), directory: "/generated")
        XCTAssertEqual(prepared.record.outcome, .prepared)
        XCTAssertEqual(prepared.record.serverDisplay, "generated.invalid:22")
        let initial = try await store.inspect()
        XCTAssertTrue(initial.active.contains(folder.request))
        do { try await store.forgetReviewed(folder.request, revision: initial.revision); XCTFail("Active record forgotten") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .busy) }
        let confirmed = try await store.update(folder.request, outcome: .needsReview)
        XCTAssertEqual(confirmed.record.outcome, .needsReview)
        _ = try await store.update(folder.request, outcome: .confirmed)
        let uncertain = try SFTPRemoteActionIntent.deleteFilePermanently(generation: generation, snapshot: snapshot,
                                                                         row: row("Keep.txt"))
        _ = try await store.prepare(uncertain, context: context(), directory: "/generated")
        _ = try await store.update(uncertain.request, outcome: .needsReview)
        let active = try SFTPRemoteActionIntent.renameFile(generation: generation, snapshot: snapshot,
                                                           row: row("e\u{301}.txt"), newName: .init(Data("é.txt".utf8)))
        _ = try await store.prepare(active, context: context(), directory: "/generated")
        let before = try await store.inspect()
        try await store.forgetCompleted(revision: before.revision)
        let after = try await store.inspect()
        XCTAssertEqual(Set(after.records.map(\.id)), Set([uncertain.request, active.request]))
        XCTAssertEqual(after.active, Set([uncertain.request, active.request]))
        let activeClose = await store.close(); XCTAssertFalse(activeClose)
        await store.releaseAfterDrain(uncertain.request)
        let partial = try await store.inspect()
        XCTAssertEqual(partial.active, Set([active.request]))
        do { try await store.forgetReviewed(active.request, revision: partial.revision); XCTFail("Active record forgotten") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .busy) }
        _ = try await store.update(active.request, outcome: .failedSafe, refusal: .targetExists)
        let closed = await store.close(); XCTAssertTrue(closed)
        let cold = SFTPRemoteActionStore(directory: root.appendingPathComponent("sftp-remote-actions"))
        let reopened = try await cold.inspect()
        XCTAssertEqual(Set(reopened.records.map(\.id)), Set([uncertain.request, active.request]))
        XCTAssertEqual(reopened.records.first(where: { $0.id == uncertain.request })?.outcome, .needsReview)
        XCTAssertEqual(reopened.records.first(where: { $0.id == active.request })?.refusal, .targetExists)
        let coldClosed = await cold.close(); XCTAssertTrue(coldClosed)
    }
    func testPoisonedSafeWriteReleasesOnlyAfterProvenDrainAndKeepsPreparedReceipt() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let directory = root.appendingPathComponent("sftp-remote-actions")
        let store = SFTPRemoteActionStore(directory: directory)
        let snapshot = SFTPStoredSnapshot(read: 1, revision: 0, count: 0, folders: 0, state: .complete)
        let intent = try SFTPRemoteActionIntent.newFolder(generation: UUID(), snapshot: snapshot,
                                                          name: .init(Data("Generated Folder".utf8)))
        _ = try await store.prepare(intent, context: context(), directory: "/generated")
        let pending = directory.appendingPathComponent("pending.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: pending.path, contents: Data("generated interrupted stage".utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        do { _ = try await store.update(intent.request, outcome: .failedSafe); XCTFail("Interrupted metadata was promoted") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
        let stillPinned = await store.close()
        XCTAssertFalse(stillPinned)
        await store.releaseAfterDrain(intent.request) // Only after actual worker drain in production.
        let closed = await store.close()
        XCTAssertTrue(closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        let cold = SFTPRemoteActionStore(directory: directory)
        do { _ = try await cold.inspect(); XCTFail("Interrupted stage silently recovered") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .recoveryRequired) }
        try await cold.recoverUncommittedLocalStage()
        let recovered = try await cold.inspect()
        XCTAssertEqual(recovered.records.map(\.id), [intent.request])
        XCTAssertEqual(recovered.records.first?.outcome, .prepared)
        XCTAssertTrue(recovered.active.isEmpty)
        let coldClosed = await cold.close()
        XCTAssertTrue(coldClosed)
    }
}
