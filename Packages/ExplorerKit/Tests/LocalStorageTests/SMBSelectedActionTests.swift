import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBSelectedActionTests: XCTestCase, @unchecked Sendable {
    func testCopyBindsOneRegularFileDestinationAndProgressBeforeCompletion() throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let row = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("Source.txt"), attributes: 0x20,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let snapshot = try XCTUnwrap(decoder.snapshot)
        let request = try SMBSelectedActionRequest(connection: peer.session, snapshot: snapshot, directory: [],
            observation: row, copyTo: [], as: "Source copy.txt")
        XCTAssertTrue(try decoder.prepareAction(request).hasSuffix(" copy -;0053006f007500720063006500200063006f00700079002e007400780074\n"))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: peer.session, snapshot: snapshot,
            directory: [], observation: row, copyTo: [], as: "source.TXT"))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: peer.session, snapshot: snapshot,
            directory: [], observation: row, copyTo: [], as: ".traverse-smb-copy-occupied.part"))
        let tooLarge = SMBDirectoryObservation(id: row.id, name: row.name, attributes: row.attributes,
            logicalBytes: SMBSelectedActionRequest.maximumCopyBytes + 1,
            modifiedFileTime: row.modifiedFileTime, objectID: row.objectID, parentID: row.parentID)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: peer.session, snapshot: snapshot,
            directory: [], observation: tooLarge, copyTo: [], as: "Large copy.txt"))
        let atLimit = SMBDirectoryObservation(id: row.id, name: row.name, attributes: row.attributes,
            logicalBytes: SMBSelectedActionRequest.maximumCopyBytes,
            modifiedFileTime: row.modifiedFileTime, objectID: row.objectID, parentID: row.parentID)
        XCTAssertNoThrow(try SMBSelectedActionRequest(connection: peer.session, snapshot: snapshot,
            directory: [], observation: atLimit, copyTo: [], as: "Large copy.txt"))
        _ = try decoder.consume(peer.line("actionReady \(request.request.uuidString) 1 32 8 9 42 7 0053006f0075007200630065002e007400780074"))
        _ = try decoder.beginAction(request.request)
        var premature = decoder, sender = peer
        XCTAssertThrowsError(try premature.consume(sender.line("actionComplete \(request.request.uuidString) 1")))
        guard case .action(.progress(let id, 4, 8)) = try decoder.consume(peer.line(
            "actionProgress \(request.request.uuidString) 1 4 8")) else { return XCTFail() }
        XCTAssertEqual(id, request.request)
        var replay = decoder, replayPeer = peer
        XCTAssertThrowsError(try replay.consume(replayPeer.line("actionProgress \(id.uuidString) 1 4 8")))
        guard case .action(.progress(_, 8, 8)) = try decoder.consume(peer.line(
            "actionProgress \(id.uuidString) 1 8 8")) else { return XCTFail() }
        guard case .action(.complete) = try decoder.consume(peer.line("actionComplete \(id.uuidString) 1"))
        else { return XCTFail() }
        var counts = [String](repeating: "0", count: 19)
        counts[11] = "2"
        for index in [10, 15, 18] {
            var forbidden = decoder, forbiddenPeer = peer, forbiddenCounts = counts
            forbiddenCounts[index] = "1"
            XCTAssertThrowsError(try forbidden.consume(forbiddenPeer.line(
                "profile " + forbiddenCounts.joined(separator: ","))))
        }
        guard case .profile(let acceptedCounts) = try decoder.consume(peer.line(
            "profile " + counts.joined(separator: ","))) else { return XCTFail() }
        XCTAssertEqual(acceptedCounts[11], 2)
        _ = try decoder.consume(peer.line("networkDrained 4 0 0"))
        guard case .closed("close") = try decoder.consume(peer.line("closed close 1 0"))
        else { return XCTFail() }
        XCTAssertTrue(decoder.closed)
    }
    func testCopyIOCTLProfileRequiresTypedBeginAndRejectsPreBeginStop() throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let row = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("Source.txt"), attributes: 0x20,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let request = try SMBSelectedActionRequest(connection: peer.session,
            snapshot: XCTUnwrap(decoder.snapshot), directory: [], observation: row,
            copyTo: [], as: "Source copy.txt")
        let counts = [String](repeating: "0", count: 19)
        var ioctlCounts = counts
        ioctlCounts[11] = "1"
        let ioctlProfile = "profile " + ioctlCounts.joined(separator: ",")
        _ = try decoder.prepareAction(request)
        var prepared = decoder, preparedPeer = peer
        XCTAssertThrowsError(try prepared.consume(preparedPeer.line(ioctlProfile)))
        var refused = decoder, refusedPeer = peer
        _ = try refused.consume(refusedPeer.line("actionRefused \(request.request.uuidString) 1 4"))
        XCTAssertThrowsError(try refused.consume(refusedPeer.line(ioctlProfile)))
        _ = try decoder.consume(peer.line(
            "actionReady \(request.request.uuidString) 1 32 8 9 42 7 0053006f0075007200630065002e007400780074"))
        XCTAssertThrowsError(try decoder.beginAction(UUID()))
        var unbegun = decoder, unbegunPeer = peer
        XCTAssertThrowsError(try unbegun.consume(unbegunPeer.line(ioctlProfile)))
        var stopped = decoder, stoppedPeer = peer
        _ = try stopped.consume(stoppedPeer.line("profile " + counts.joined(separator: ",")))
        _ = try stopped.consume(stoppedPeer.line("networkDrained 4 0 0"))
        guard case .closed("stopped") = try stopped.consume(stoppedPeer.line("closed stopped 1 0"))
        else { return XCTFail() }
        XCTAssertTrue(stopped.closed)
    }
    func testRenameAndUploadStillRefuseCopyIOCTLProfile() throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let snapshot = try XCTUnwrap(decoder.snapshot)
        var counts = [String](repeating: "0", count: 19)
        counts[11] = "1"
        let ioctlProfile = "profile " + counts.joined(separator: ",")

        var upload = decoder, uploadPeer = peer
        let uploadRequest = try SMBRequestedUpload(connection: peer.session, snapshot: snapshot,
            directory: [], generatedEmptyName: "Generated.txt")
        _ = try upload.prepareUpload(uploadRequest)
        _ = try upload.consume(uploadPeer.line("uploadReady \(uploadRequest.request.uuidString) 1"))
        _ = try upload.beginUpload(uploadRequest.request)
        XCTAssertThrowsError(try upload.consume(uploadPeer.line(ioctlProfile)))

        let row = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("Source.txt"), attributes: 0x20,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let rename = try SMBSelectedActionRequest(connection: peer.session, snapshot: snapshot,
            directory: [], observation: row, renameTo: "Renamed.txt")
        _ = try decoder.prepareAction(rename)
        _ = try decoder.consume(peer.line(
            "actionReady \(rename.request.uuidString) 1 32 8 9 42 7 0053006f0075007200630065002e007400780074"))
        _ = try decoder.beginAction(rename.request)
        _ = try decoder.consume(peer.line("actionComplete \(rename.request.uuidString) 1"))
        XCTAssertThrowsError(try decoder.consume(peer.line(ioctlProfile)))
    }
    func testCopyCollisionStatesAreDurableAndDistinct() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let storage = SMBActionStorage(directory: root.appendingPathComponent("copy-history"))
        let id = UUID()
        let record = SMBActionRecord(id: id, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", createdAt: Date(), directory: [], source: try SMBRemoteName("Source.txt"),
            target: try SMBRemoteName("Source copy.txt"), operation: .copy, object: 42, parent: 7,
            outcome: .prepared, destinationDirectory: [])
        try await storage.ledger.prepare(record)
        try await offMain { try storage.ledger.requestMutation(id) }
        try await offMain { try storage.ledger.copyCollision(id, stage: false) }
        let history = try await storage.inspect()
        XCTAssertEqual(history.records.first?.outcome, .finalCollision)
        XCTAssertEqual(history.records.first?.destinationDirectory, [])
        XCTAssertEqual(history.records.first?.target?.displayName, "Source copy.txt")
        XCTAssertEqual(history.records.first?.temporaryCopyName,
            ".traverse-smb-copy-\(id.uuidString.lowercased()).part")
        let closed = await storage.close()
        XCTAssertTrue(closed)
    }
    private struct Peer {
        let session = UUID()
        var sequence = 0
        mutating func line(_ payload: String) -> Data {
            defer { sequence += 1 }
            return Data("MEXSMBU1 \(session.uuidString) \(sequence) \(payload)".utf8)
        }
    }
    private func offMain(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result(catching: work)) }
        }
    }
    func testCurrentClass37WitnessesAndDurableBeginBarrier() throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let page = try SMBDirectoryPageRequest(snapshot: XCTUnwrap(decoder.snapshot), offset: 0)
        _ = try decoder.request(page)
        _ = try decoder.consume(peer.line("row \(page.token.uuidString) 1 5 0 8 9 42 7 0041"))
        guard case .page(_, let result) = try decoder.consume(peer.line("page \(page.token.uuidString) 1 \(read.id.uuidString) 1 0 1"))
        else { return XCTFail() }
        let row = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(row.objectID, 42); XCTAssertEqual(row.parentID, 7)
        var forged = decoder, forgedPeer = peer
        let falseRow = SMBDirectoryObservation(id: row.id, name: try SMBRemoteName("C"),
            attributes: row.attributes, logicalBytes: row.logicalBytes,
            modifiedFileTime: row.modifiedFileTime, objectID: row.objectID, parentID: row.parentID)
        let falseRequest = try SMBSelectedActionRequest(connection: peer.session, snapshot: page.snapshot,
            directory: [], observation: falseRow, renameTo: "B")
        _ = try forged.prepareAction(falseRequest)
        XCTAssertThrowsError(try forged.consume(forgedPeer.line("actionReady \(falseRequest.request.uuidString) 1 0 8 9 42 7 0041")))
        let request = try SMBSelectedActionRequest(connection: peer.session, snapshot: page.snapshot,
            directory: [], observation: row, renameTo: "B")
        let command = try decoder.prepareAction(request)
        XCTAssertTrue(command.hasSuffix(" 5 rename 0042\n"))
        XCTAssertThrowsError(try decoder.beginAction(request.request))
        XCTAssertThrowsError(try decoder.navigate(components: []))
        guard case .action(.ready(let id)) = try decoder.consume(peer.line("actionReady \(request.request.uuidString) 1 0 8 9 42 7 0041"))
        else { return XCTFail() }
        XCTAssertEqual(id, request.request)
        XCTAssertEqual(try decoder.beginAction(id), "BEGIN_ACTION \(id.uuidString) 1\n")
        var faultedRename = decoder, faultPeer = peer
        XCTAssertThrowsError(try faultedRename.consume(faultPeer.line("actionFault \(id.uuidString) 1 3")))
        guard case .action(.complete(let completed)) = try decoder.consume(peer.line("actionComplete \(id.uuidString) 1"))
        else { return XCTFail() }
        XCTAssertEqual(completed, id)
        XCTAssertNoThrow(try decoder.navigate(components: []))
    }
    func testMissingIdentityAndUnconfirmedPermanentDeleteAreRefused() throws {
        let session = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let name = try SMBRemoteName("Source.txt")
        let missing = SMBDirectoryObservation(id: 1, name: name, attributes: 0, logicalBytes: 1, modifiedFileTime: 2)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: missing, renameTo: "Other.txt"))
        let row = SMBDirectoryObservation(id: 1, name: name, attributes: 0, logicalBytes: 1,
            modifiedFileTime: 2, objectID: 3, parentID: 4)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: row, permanentlyDelete: false))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: row, renameTo: "source.txt")) {
            XCTAssertEqual($0 as? SMBActionFailure, .caseOnlyRename)
        }
        XCTAssertNoThrow(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: row, permanentlyDelete: true))
    }
    func testPreflightRefusalIsBoundToPreparingActionAndTerminalReason() throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let row = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("Source.txt"), attributes: 0,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let request = try SMBSelectedActionRequest(connection: peer.session, snapshot: XCTUnwrap(decoder.snapshot),
            directory: [], observation: row, renameTo: "Target.txt")
        _ = try decoder.prepareAction(request)
        func refuses(_ payload: String) {
            var copy = decoder, sender = peer
            XCTAssertThrowsError(try copy.consume(sender.line(payload)))
        }
        refuses("actionRefused \(UUID().uuidString) 1 4")
        refuses("actionRefused \(request.request.uuidString) 2 4")
        refuses("actionRefused \(request.request.uuidString) 1 0")
        refuses("actionRefused \(request.request.uuidString) 1 11")
        refuses("actionFault \(request.request.uuidString) 1 3")
        refuses("actionDestinationUnavailable \(request.request.uuidString) 1")
        var noDiagnostic = decoder, noDiagnosticPeer = peer
        _ = try noDiagnostic.consume(noDiagnosticPeer.line("profile " + Array(repeating: "0", count: 19).joined(separator: ",")))
        _ = try noDiagnostic.consume(noDiagnosticPeer.line("networkDrained 4 0 0"))
        XCTAssertThrowsError(try noDiagnostic.consume(noDiagnosticPeer.line("closed actionRefused 1 0")))
        guard case .action(.refused(let id, let code)) = try decoder.consume(peer.line("actionRefused \(request.request.uuidString) 1 4"))
        else { return XCTFail() }
        XCTAssertEqual(id, request.request); XCTAssertEqual(code, .modified)
        XCTAssertThrowsError(try decoder.beginAction(request.request))
        _ = try decoder.consume(peer.line("profile " + Array(repeating: "0", count: 19).joined(separator: ",")))
        _ = try decoder.consume(peer.line("networkDrained 4 0 0"))
        guard case .closed("actionRefused") = try decoder.consume(peer.line("closed actionRefused 1 0"))
        else { return XCTFail() }
    }
    func testPreBeginRefusalRecordsNotStartedAfterDrain() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let storage = SMBActionStorage(directory: root.appendingPathComponent("smb-action-history"))
        let id = UUID()
        let record = SMBActionRecord(id: id, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", createdAt: Date(), directory: [], source: try SMBRemoteName("Source.txt"),
            target: try SMBRemoteName("Target.txt"), operation: .rename, object: 3, parent: 4,
            outcome: .prepared)
        try await storage.ledger.prepare(record)
        try await storage.ledger.endAfterDrain(id, noMutation: true)
        let history = try await storage.inspect()
        XCTAssertEqual(history.records.first?.outcome, .notStarted)
        let closed = await storage.close()
        XCTAssertTrue(closed)
    }
    func testUnansweredMutationStaysReviewRequiredAfterReopen() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let location = root.appendingPathComponent("smb-action-history")
        let storage = SMBActionStorage(directory: location)
        let id = UUID()
        let createdAt = Date()
        let record = SMBActionRecord(id: id, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", createdAt: createdAt, directory: [], source: try SMBRemoteName("Source.txt"),
            target: try SMBRemoteName("Target.txt"), operation: .rename, object: 3, parent: 4,
            outcome: .prepared)
        try await storage.ledger.prepare(record)
        try await offMain { try storage.ledger.requestMutation(id) }
        let requested = try await storage.inspect()
        XCTAssertEqual(requested.records.first?.outcome, .mutationRequested)
        try await storage.ledger.endAfterDrain(id, noMutation: false)
        let reviewed = try await storage.inspect()
        XCTAssertEqual(reviewed.records.first?.outcome, .needsReview)
        let closed = await storage.close()
        XCTAssertTrue(closed)
        let reopened = SMBActionStorage(directory: location)
        let persisted = try await reopened.inspect()
        XCTAssertEqual(persisted.records.first?.outcome, .needsReview)
        XCTAssertEqual(persisted.records.first?.createdAt, createdAt)
        let reopenedClosed = await reopened.close()
        XCTAssertTrue(reopenedClosed)
    }
    func testDirectoryRequestsKeepFileOperationsDistinctAndBindNotEmptyToDelete() throws {
        let session = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 1, state: .complete)
        let directory = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("Folder"), attributes: 0x10,
            logicalBytes: 0, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let file = SMBDirectoryObservation(id: 6, name: try SMBRemoteName("File"), attributes: 0x20,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 43, parentID: 7)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: directory, renameTo: "Other"))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: file, renameDirectoryTo: "Other"))
        let zeroObject = SMBDirectoryObservation(id: 7, name: try SMBRemoteName("Zero"), attributes: 0x10,
            logicalBytes: 0, modifiedFileTime: 9, objectID: 0, parentID: 7)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: zeroObject, renameDirectoryTo: "Other"))
        let zeroParent = SMBDirectoryObservation(id: 8, name: try SMBRemoteName("ZeroParent"), attributes: 0x10,
            logicalBytes: 0, modifiedFileTime: 9, objectID: 42, parentID: 0)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: zeroParent, permanentlyDeleteEmptyDirectory: true))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: directory, permanentlyDeleteEmptyDirectory: false))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: directory, renameDirectoryTo: "folder")) {
            XCTAssertEqual($0 as? SMBActionFailure, .caseOnlyRename)
        }
        let reparse = SMBDirectoryObservation(id: 7, name: try SMBRemoteName("Link"), attributes: 0x410,
            logicalBytes: 0, modifiedFileTime: 9, objectID: 44, parentID: 7)
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [], observation: reparse, permanentlyDeleteEmptyDirectory: true))

        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 1 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let request = try SMBSelectedActionRequest(connection: peer.session, snapshot: XCTUnwrap(decoder.snapshot),
            directory: [], observation: directory, permanentlyDeleteEmptyDirectory: true)
        XCTAssertTrue(try decoder.prepareAction(request).hasSuffix(" deleteEmptyDirectory -\n"))
        var premature = decoder, prematurePeer = peer
        XCTAssertThrowsError(try premature.consume(prematurePeer.line("actionNotEmpty \(request.request.uuidString) 1")))
        _ = try decoder.consume(peer.line("actionReady \(request.request.uuidString) 1 16 0 9 42 7 0046006f006c006400650072"))
        _ = try decoder.beginAction(request.request)
        guard case .action(.notEmpty(let id)) = try decoder.consume(peer.line("actionNotEmpty \(request.request.uuidString) 1"))
        else { return XCTFail() }
        XCTAssertEqual(id, request.request)
        XCTAssertNoThrow(try decoder.navigate(components: []))
    }
    func testDefiniteNonEmptyIsDurableAndOldRecordEncodingIsRetained() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let location = root.appendingPathComponent("smb-directory-action-history")
        let storage = SMBActionStorage(directory: location)
        let id = UUID(), createdAt = Date()
        let record = SMBActionRecord(id: id, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", createdAt: createdAt, directory: [], source: try SMBRemoteName("Folder"),
            target: nil, operation: .deleteEmptyDirectory, object: 42, parent: 7, outcome: .prepared)
        var impossible = record
        impossible.outcome = .collision
        XCTAssertThrowsError(try impossible.validate())
        try await storage.ledger.prepare(record)
        try await offMain { try storage.ledger.requestMutation(id); try storage.ledger.notEmpty(id) }
        let current = try await storage.inspect()
        XCTAssertEqual(current.records.first?.operation, .deleteEmptyDirectory)
        XCTAssertEqual(current.records.first?.outcome, .notEmpty)
        let closed = await storage.close()
        XCTAssertTrue(closed)
        let reopened = SMBActionStorage(directory: location)
        let cold = try await reopened.inspect()
        XCTAssertEqual(cold.records.first?.outcome, .notEmpty)
        XCTAssertEqual(cold.records.first?.createdAt, createdAt)
        let reopenedClosed = await reopened.close()
        XCTAssertTrue(reopenedClosed)

        var prior = SMBActionDocument()
        prior.records = [SMBActionRecord(id: UUID(), server: record.server, account: "generated",
            createdAt: createdAt, directory: [], source: try SMBRemoteName("File"),
            target: try SMBRemoteName("Other"), operation: .rename, object: 43, parent: 7, outcome: .confirmed)]
        let encoded = try prior.encoded()
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"operation\":\"rename\""))
        XCTAssertEqual(try SMBActionDocument.decode(encoded).records.first?.operation, .rename)
        var impossibleFile = try XCTUnwrap(prior.records.first)
        impossibleFile.outcome = .notEmpty
        XCTAssertThrowsError(try impossibleFile.validate())
    }

    func testMoveKeepsTheLeafAndRefusesSameParentDescendantsAndUnsupportedPaths() throws {
        let session = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let source = try SMBRemoteName("Report.txt"), parent = try SMBRemoteName("Inbox")
        let row = SMBDirectoryObservation(id: 5, name: source, attributes: 0,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let destination = try SMBMoveDestination(field: "/Work/2026/")
        XCTAssertEqual(destination.path, "/Work/2026")
        let move = try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [parent], observation: row, moveTo: destination.components)
        XCTAssertEqual(move.operation, .move)
        XCTAssertNil(move.target)
        XCTAssertEqual(move.destinationDirectory, destination.components)
        XCTAssertTrue(move.command(ordinal: 1, number: 1).hasSuffix(" 5 move 0057006f0072006b,0032003000320036\n"))
        let toRoot = try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [parent], observation: row, moveTo: [])
        XCTAssertTrue(toRoot.command(ordinal: 2, number: 1).hasSuffix(" move -\n"))
        XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [parent], observation: row, moveTo: [parent]))
        let folder = SMBDirectoryObservation(id: 6, name: try SMBRemoteName("Project"), attributes: 0x10,
            logicalBytes: 0, modifiedFileTime: 9, objectID: 43, parentID: 7)
        for path in [[parent, folder.name], [parent, folder.name, try SMBRemoteName("Child")]] {
            XCTAssertThrowsError(try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
                directory: [parent], observation: folder, moveTo: path))
        }
        let folderMove = try SMBSelectedActionRequest(connection: session, snapshot: snapshot,
            directory: [parent], observation: folder, moveTo: [])
        XCTAssertEqual(folderMove.operation, .moveDirectory)
        for path in ["relative", "//", "/../Work", "/Work//Child", "/Bad:name", "/Trailing. ", "/" + String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try SMBMoveDestination(field: path), path)
        }
        XCTAssertThrowsError(try SMBMoveDestination(components: Array(repeating: parent, count: 33)))
        XCTAssertThrowsError(try SMBMoveDestination(components: Array(repeating: try SMBRemoteName(String(repeating: "x", count: 255)), count: 8)))
        XCTAssertEqual(try SMBMoveDestination(field: "/").components, [])
        XCTAssertEqual(try SMBMoveDestination(field: "/100% complete").path, "/100% complete")
        // No normalization of canonically equivalent server names.
        XCTAssertNotEqual(try SMBMoveDestination(field: "/\u{e9}").components,
            try SMBMoveDestination(field: "/e\u{301}").components)
    }

    func testMoveUsesTheExistingPermitAndKeepsCollisionAfterBegin() throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let row = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("A"), attributes: 0,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let request = try SMBSelectedActionRequest(connection: peer.session, snapshot: XCTUnwrap(decoder.snapshot),
            directory: [], observation: row, moveTo: [try SMBRemoteName("Target")])
        _ = try decoder.prepareAction(request)
        XCTAssertThrowsError(try decoder.beginAction(request.request))
        XCTAssertThrowsError(try decoder.navigate(components: []))
        var unknown = decoder, unknownPeer = peer
        XCTAssertThrowsError(try unknown.consume(unknownPeer.line("actionRefused \(request.request.uuidString) 1 11")))
        var premature = decoder, prematurePeer = peer
        XCTAssertThrowsError(try premature.consume(prematurePeer.line("actionCollision \(request.request.uuidString) 1")))
        _ = try decoder.consume(peer.line("actionReady \(request.request.uuidString) 1 0 8 9 42 7 0041"))
        _ = try decoder.beginAction(request.request)
        var faulted = decoder, faultPeer = peer
        var staleFault = decoder, stalePeer = peer
        XCTAssertThrowsError(try staleFault.consume(stalePeer.line("actionFault \(UUID().uuidString) 1 3")))
        guard case .action(.fault(let faultRequest, let checkpoint)) = try faulted.consume(
            faultPeer.line("actionFault \(request.request.uuidString) 1 3")) else { return XCTFail() }
        XCTAssertEqual(faultRequest, request.request)
        XCTAssertEqual(checkpoint, 3)
        var replay = faulted, replayPeer = faultPeer
        XCTAssertThrowsError(try replay.consume(replayPeer.line("actionFault \(request.request.uuidString) 1 3")))
        var falseSuccess = faulted, successPeer = faultPeer
        XCTAssertThrowsError(try falseSuccess.consume(successPeer.line("actionComplete \(request.request.uuidString) 1")))
        _ = try faulted.consume(faultPeer.line("profile " + Array(repeating: "0", count: 19).joined(separator: ",")))
        _ = try faulted.consume(faultPeer.line("networkDrained 4 0 0"))
        _ = try faulted.consume(faultPeer.line("closed remote 1 0"))
        XCTAssertTrue(faulted.closed)
        var lateRefusal = decoder, latePeer = peer
        XCTAssertThrowsError(try lateRefusal.consume(latePeer.line("actionRefused \(request.request.uuidString) 1 4")))
        guard case .action(.collision(let collision)) = try decoder.consume(peer.line("actionCollision \(request.request.uuidString) 1"))
        else { return XCTFail() }
        XCTAssertEqual(collision, request.request)
        XCTAssertNoThrow(try decoder.navigate(components: []))
    }

    func testMoveColdHistoryRetainsBothParentsAndLegacyCanonicalBytes() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let location = root.appendingPathComponent("smb-move-history")
        let storage = SMBActionStorage(directory: location)
        let source = try SMBRemoteName("Source"), destination = [try SMBRemoteName("Destination")]
        let record = SMBActionRecord(id: UUID(), server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", createdAt: Date(), directory: [], source: source, target: nil,
            operation: .moveDirectory, object: 42, parent: 7, outcome: .prepared, destinationDirectory: destination)
        try await storage.ledger.prepare(record)
        try await offMain { try storage.ledger.requestMutation(record.id) }
        try await storage.ledger.endAfterDrain(record.id, noMutation: false)
        let closed = await storage.close()
        XCTAssertTrue(closed)
        let reopened = SMBActionStorage(directory: location)
        let history = try await reopened.inspect()
        XCTAssertEqual(history.records.first?.outcome, .needsReview)
        XCTAssertEqual(history.records.first?.directory, [])
        XCTAssertEqual(history.records.first?.destinationDirectory, destination)
        XCTAssertEqual(history.records.first?.source, source)
        let reopenedClosed = await reopened.close()
        XCTAssertTrue(reopenedClosed)

        var prior = SMBActionDocument()
        prior.records = [SMBActionRecord(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            server: record.server, account: "generated", createdAt: Date(timeIntervalSinceReferenceDate: 0),
            directory: [], source: try SMBRemoteName("File"), target: try SMBRemoteName("Other"),
            operation: .rename, object: 43, parent: 7, outcome: .confirmed)]
        let legacy = #"{"format":1,"protocolIdentity":"smb-selected-file-actions","records":[{"account":"generated","createdAt":0,"directory":[],"id":"11111111-1111-4111-8111-111111111111","object":43,"operation":"rename","outcome":"confirmed","parent":7,"server":"smb://generated.invalid/Shared","source":"RgBpAGwAZQA=","target":"TwB0AGgAZQByAA=="}],"revision":0}"# + "\n"
        XCTAssertEqual(try prior.encoded(), Data(legacy.utf8))
        XCTAssertEqual(try SMBActionDocument.decode(Data(legacy.utf8)).records.first?.destinationDirectory, nil)
    }

    func testUnavailableMoveDestinationKeepsTheConnectionAndDurableNotStartedOutcome() async throws {
        var peer = Peer()
        var decoder = SMBBrowserDecoder(session: peer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 1 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let row = SMBDirectoryObservation(id: 5, name: try SMBRemoteName("A"), attributes: 0,
            logicalBytes: 8, modifiedFileTime: 9, objectID: 42, parentID: 7)
        let request = try SMBSelectedActionRequest(connection: peer.session, snapshot: XCTUnwrap(decoder.snapshot),
            directory: [], observation: row, moveTo: [SMBRemoteName("Missing")])
        _ = try decoder.prepareAction(request)
        for payload in ["actionDestinationUnavailable \(UUID().uuidString) 1",
                        "actionDestinationUnavailable \(request.request.uuidString) 2"] {
            var copy = decoder, sender = peer
            XCTAssertThrowsError(try copy.consume(sender.line(payload)))
        }
        var late = decoder, latePeer = peer
        _ = try late.consume(latePeer.line("actionReady \(request.request.uuidString) 1 0 8 9 42 7 0041"))
        _ = try late.beginAction(request.request)
        XCTAssertThrowsError(try late.consume(latePeer.line("actionDestinationUnavailable \(request.request.uuidString) 1")))
        guard case .action(.destinationUnavailable(let id)) = try decoder.consume(peer.line("actionDestinationUnavailable \(request.request.uuidString) 1"))
        else { return XCTFail("Expected the definite pre-BEGIN refusal") }
        XCTAssertEqual(id, request.request)
        XCTAssertThrowsError(try decoder.beginAction(id))
        let next = try SMBSelectedActionRequest(connection: peer.session, snapshot: XCTUnwrap(decoder.snapshot),
            directory: [], observation: row, moveTo: [SMBRemoteName("Other")])
        XCTAssertTrue(try decoder.prepareAction(next).contains(" \(next.request.uuidString) 2 "))
        _ = try decoder.consume(peer.line("actionReady \(next.request.uuidString) 2 0 8 9 42 7 0041"))
        _ = try decoder.beginAction(next.request)
        _ = try decoder.consume(peer.line("actionCollision \(next.request.uuidString) 2"))
        XCTAssertNoThrow(try decoder.navigate(components: []))

        let root = try LocalStorageTestFixtures.directory()
        let location = root.appendingPathComponent("smb-missing-destination-history")
        let storage = SMBActionStorage(directory: location)
        let record = SMBActionRecord(id: UUID(), server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", createdAt: Date(), directory: [], source: row.name, target: nil,
            operation: .move, object: 42, parent: 7, outcome: .prepared,
            destinationDirectory: request.destinationDirectory)
        let attempt = SMBActionAttempt(request: request, record: record, ledger: storage.ledger)
        // A failed durable update must not tell the session it can safely continue.
        do {
            try await offMain { try attempt.destinationUnavailableOnExecutor() }
            XCTFail("An unprepared history cannot confirm a refusal")
        } catch { XCTAssertFalse(attempt.finished) }
        try await storage.ledger.prepare(record)
        XCTAssertTrue(attempt.admit())
        try await offMain { try attempt.destinationUnavailableOnExecutor() }
        XCTAssertTrue(attempt.finished); XCTAssertFalse(attempt.mutationRequested)
        let current = try await storage.inspect()
        XCTAssertEqual(current.records.first?.outcome, .notStarted)
        XCTAssertEqual(current.records.first?.active, false)
        let closed = await storage.close()
        XCTAssertTrue(closed)
        let reopened = SMBActionStorage(directory: location)
        let cold = try await reopened.inspect()
        XCTAssertEqual(cold.records.first?.outcome, .notStarted)
        XCTAssertEqual(cold.records.first?.destinationDirectory, request.destinationDirectory)
        let coldClosed = await reopened.close()
        XCTAssertTrue(coldClosed)
    }

    func testMovedFolderInvalidatesOnlyItsOldDescendantLocations() throws {
        var references = SMBDirectoryReferences(connectionID: UUID(), share: try SMBRemoteName("Shared"))
        let parent = try SMBRemoteName("Source"), folder = try SMBRemoteName("Project")
        let parentLocation = try references.location(for: [parent])
        let old = try references.location(for: [parent, folder])
        let child = try references.location(for: [parent, folder, try SMBRemoteName("Child")])
        let unrelated = try references.location(for: [try SMBRemoteName("Destination")])
        references.invalidateDescendants(of: [parent, folder])
        XCTAssertNil(references.resolve(old)); XCTAssertNil(references.resolve(child))
        XCTAssertEqual(references.resolve(parentLocation), [parent])
        XCTAssertNotNil(references.resolve(unrelated)); XCTAssertEqual(references.resolve(references.root), [])
        XCTAssertFalse(references.recentPaths().contains([parent, folder]))
        let fresh = try references.location(for: [parent, folder])
        XCTAssertNotEqual(fresh.directoryID, old.directoryID)
    }
}
