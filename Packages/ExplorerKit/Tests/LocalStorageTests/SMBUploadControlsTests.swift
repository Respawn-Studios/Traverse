import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBUploadControlsTests: XCTestCase, @unchecked Sendable {
    private final class GroupCalls: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
        var count: Int { lock.withLock { value } }
    }
    private struct U1Peer {
        let session: UUID
        var sequence: UInt64 = 0
        mutating func line(_ event: String) -> Data {
            defer { sequence += 1 }
            return Data("MEXSMBU1 \(session.uuidString) \(sequence) \(event)".utf8)
        }
    }
    private func request(_ fixture: UploadFoundationFixture, bytes: Data = Data([1, 2, 3])) async throws -> SMBRequestedUpload {
        try bytes.write(to: fixture.file, options: .withoutOverwriting)
        let review = try await SFTPUploadSourceReview.inspect(fixture.file, excluding: [])
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        return try SMBRequestedUpload(connection: UUID(), snapshot: snapshot, directory: [], reviewed: review, name: "Final.bin")
    }
    private func offMain(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result(catching: work)) }
        }
    }
    private func record(_ request: SMBRequestedUpload) throws -> SMBUploadRecord {
        .init(id: request.request, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
              account: "generated", directory: request.directory, remoteName: request.name,
              sourceName: "Generated.bin", logicalBytes: request.logicalBytes, outcome: .prepared, digest: nil)
    }

    private func group(_ root: URL) async throws -> SMBUploadGroupPlan {
        let urls = ["First.bin", "Second.bin", "Third.bin"].map { root.appendingPathComponent($0) }
        for (index, url) in urls.enumerated() {
            try Data(repeating: UInt8(index + 1), count: index + 1).write(to: url, options: .withoutOverwriting)
        }
        return try await SMBUploadGroupPlan.inspect(urls, excluding: [])
    }

    private func folder(_ root: URL) throws -> URL {
        let folder = root.appendingPathComponent("Tree")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested"),
                                                withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("One.bin"), options: .withoutOverwriting)
        try Data([4, 5]).write(to: folder.appendingPathComponent("Nested/Two.bin"), options: .withoutOverwriting)
        return folder
    }

    func testSyntheticEmptySMBItemsUseExistingU1F2BarriersAndDurableOutcomes() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let server = try SMBServerDraft(name: "Generated", address: SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", domain: "", security: .encrypted, transferPreference: .normal)
        let connection = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        let partial = SMBDirectorySnapshot(readID: snapshot.readID, revision: 1, count: 0, folders: 0, state: .partial)
        XCTAssertThrowsError(try SMBRequestedNewItem(connection: connection, snapshot: partial,
            directory: [], kind: .textFile, name: "Untitled.txt"))
        XCTAssertThrowsError(try SMBRequestedNewItem(connection: connection, snapshot: snapshot,
            directory: [], kind: .folder, name: "Bad:name"))
        let file = try SMBRequestedNewItem(connection: connection, snapshot: snapshot,
            directory: [], kind: .textFile, name: "Untitled.txt")
        guard case .file(let fileRequest) = file.payload else { return XCTFail("Wrong U1 source") }
        XCTAssertEqual(fileRequest.logicalBytes, 0)
        let emptyDigest = Data(SHA256.hash(data: Data()))
        let fileHex = emptyDigest.map { String(format: "%02x", $0) }.joined()
        var u1 = try SMBUploadConversation(request: fileRequest, ordinal: 1)
        let fileID = fileRequest.request.uuidString
        _ = try u1.text(["uploadReady", fileID, "1"]); _ = try u1.begin()
        XCTAssertThrowsError(try u1.text(["uploadNeed", fileID, "1", "0", "0", "1"]))
        var validU1 = try SMBUploadConversation(request: fileRequest, ordinal: 1)
        _ = try validU1.text(["uploadReady", fileID, "1"]); _ = try validU1.begin()
        _ = try validU1.text(["uploadSourceDigest", fileID, "1"])
        _ = try validU1.supplyDigest(emptyDigest)
        _ = try validU1.text(["uploadStageVerified", fileID, "1", fileHex]); _ = try validU1.commit()
        _ = try validU1.text(["uploadComplete", fileID, "1", fileHex])
        let fileAttempt = try await SMBUploadAttempt.prepare(fileRequest, server: server, storage: storage,
            excluding: [root], progress: nil)
        try await offMain {
            XCTAssertEqual(try fileAttempt.digestOnExecutor(), emptyDigest)
            try fileAttempt.requestStageOnExecutor()
            try fileAttempt.confirmStageOnExecutor()
            try fileAttempt.requestPublicationOnExecutor(emptyDigest)
            XCTAssertEqual(try fileAttempt.completeOnExecutor(emptyDigest).id, fileRequest.request)
        }
        let live = try await storage.inspect()
        XCTAssertEqual(live.records.map(\.outcome), [.verified])
        let foreignReader = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        do {
            _ = try await foreignReader.inspect()
            XCTFail("A foreign reader must not bypass the live writer lease")
        } catch {
            XCTAssertEqual(error as? RemoteSettingsFailure, .busy)
        }
        _ = await foreignReader.close()

        let folder = try SMBRequestedNewItem(connection: connection, snapshot: snapshot,
            directory: [], kind: .folder, name: "New Folder")
        guard case .folder(let folderRequest) = folder.payload else { return XCTFail("Wrong F2 source") }
        XCTAssertEqual(folderRequest.files, 0); XCTAssertEqual(folderRequest.folders, 1)
        XCTAssertEqual(folderRequest.logicalBytes, 0); XCTAssertEqual(folderRequest.manifest.nodes.count, 1)
        let manifest = folderRequest.manifest.encoded, folderID = folderRequest.request.uuidString
        let treeDigest = Data(SHA256.hash(data: manifest))
        let treeHex = treeDigest.map { String(format: "%02x", $0) }.joined()
        var f2 = try SMBFolderUploadConversation(request: folderRequest, ordinal: 1)
        _ = try f2.text(["folderUploadManifestNeed", folderID, "1", "0", String(manifest.count)])
        _ = try f2.manifest(offset: 0, bytes: manifest)
        _ = try f2.text(["folderUploadReady", folderID, "1"]); _ = try f2.begin()
        XCTAssertThrowsError(try f2.text(["folderUploadStageVerified", folderID, "1", treeHex]))
        var validF2 = try SMBFolderUploadConversation(request: folderRequest, ordinal: 1)
        _ = try validF2.text(["folderUploadManifestNeed", folderID, "1", "0", String(manifest.count)])
        _ = try validF2.manifest(offset: 0, bytes: manifest)
        _ = try validF2.text(["folderUploadReady", folderID, "1"]); _ = try validF2.begin()
        _ = try validF2.text(["folderUploadRootCreated", folderID, "1"]); _ = try validF2.acknowledgeRoot()
        _ = try validF2.text(["folderUploadStageVerified", folderID, "1", treeHex])
        _ = try validF2.commit(treeDigest)
        _ = try validF2.text(["folderUploadComplete", folderID, "1", treeHex])
        let folderAttempt = try await SMBFolderUploadAttempt.prepare(folderRequest, server: server,
            storage: storage, excluding: [root], progress: nil)
        try await offMain {
            XCTAssertThrowsError(try folderAttempt.requestPublicationOnExecutor(treeDigest))
            try folderAttempt.requestStageOnExecutor()
            try folderAttempt.acknowledgeRootOnExecutor()
            try folderAttempt.requestPublicationOnExecutor(treeDigest)
            XCTAssertEqual(try folderAttempt.completeOnExecutor(treeDigest).id, folderRequest.request)
        }
        let history = try await storage.inspect()
        XCTAssertEqual(history.records.map(\.outcome), [.verified, .verified])
        XCTAssertEqual(history.records[1].folder?.files, 0)
        XCTAssertEqual(history.records[1].folder?.folders, 1)
        let stopped = try SMBRequestedNewItem(connection: connection, snapshot: snapshot,
            directory: [], kind: .textFile, name: "Stopped.txt")
        guard case .file(let stoppedRequest) = stopped.payload else { return XCTFail("Wrong stopped source") }
        let stoppedAttempt = try await SMBUploadAttempt.prepare(stoppedRequest, server: server,
            storage: storage, excluding: [root], progress: nil)
        stoppedAttempt.stop()
        try await offMain {
            XCTAssertThrowsError(try stoppedAttempt.digestOnExecutor()) {
                XCTAssertEqual($0 as? SMBUploadFailure, .stopped)
            }
        }
        try await stoppedAttempt.finishAfterDrain(noRemoteMutation: true)
        let closed = await storage.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 1)
    }

    func testNormalLocalSMBU1F2SourcesStillPinAndDrain() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let server = try SMBServerDraft(name: "Generated", address: SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", domain: "", security: .encrypted, transferPreference: .normal)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        let fileURL = root.appendingPathComponent("Local.bin")
        try Data([1, 2, 3]).write(to: fileURL, options: .withoutOverwriting)
        let reviewedFile = try await SFTPUploadSourceReview.inspect(fileURL, excluding: [])
        let file = try SMBRequestedUpload(connection: UUID(), snapshot: snapshot, directory: [],
            reviewed: reviewedFile, name: "Local.bin")
        let fileAttempt = try await SMBUploadAttempt.prepare(file, server: server, storage: storage,
            excluding: [], progress: nil)
        try await fileAttempt.finishAfterDrain(noRemoteMutation: true)
        let tree = try folder(root)
        let reviewedFolder = try await SMBFolderUploadPlan.inspect(tree, excluding: [])
        let folderRequest = try SMBRequestedFolderUpload(connection: UUID(), snapshot: snapshot,
            directory: [], reviewed: reviewedFolder, name: "Tree")
        let folderAttempt = try await SMBFolderUploadAttempt.prepare(folderRequest, server: server,
            storage: storage, excluding: [], progress: nil)
        try await folderAttempt.finishAfterDrain(noRemoteMutation: true)
        let history = try await storage.inspect()
        XCTAssertEqual(history.records.map(\.outcome), [.notStarted, .notStarted])
        XCTAssertEqual(try Data(contentsOf: fileURL), Data([1, 2, 3]))
        let closed = await storage.close()
        XCTAssertTrue(closed)
    }

    func testFolderPlanReviewsExactTreeAndMixedRootsWithoutRemoteMutation() async throws {
        let root = try LocalStorageTestFixtures.directory(), tree = try folder(root)
        let single = try await SMBFolderUploadPlan.inspect(tree, excluding: [])
        XCTAssertEqual(single.name, "Tree")
        XCTAssertEqual(single.files, 2); XCTAssertEqual(single.folders, 2)
        XCTAssertEqual(single.logicalBytes, 5)
        XCTAssertEqual(single.remoteNodes.count, 5)
        let file = root.appendingPathComponent("Other.bin")
        try Data([6]).write(to: file, options: .withoutOverwriting)
        let one = try await SMBUploadGroupPlan.inspect([file], excluding: [], allowsFolders: true)
        XCTAssertEqual(one.singleFileReview?.name, "Other.bin")
        let group = try await SMBUploadGroupPlan.inspect([file, tree], excluding: [], allowsFolders: true)
        XCTAssertEqual(group.items.map(\.kind), [.file, .folder])
        XCTAssertEqual(group.items.map(\.files), [1, 2])
        XCTAssertEqual(group.files, 3); XCTAssertEqual(group.folders, 3)
        XCTAssertEqual(group.logicalBytes, 6)
        XCTAssertNil(group.singleFileReview)
        do { _ = try await SMBUploadGroupPlan.inspect([tree], excluding: []); XCTFail("Folder passed file-only gate") }
        catch { XCTAssertTrue([SFTPUploadLocalIssue.unsupportedSource, .sourceUnavailable].contains(error as? SFTPUploadLocalIssue ?? .stopped)) }
    }

    func testFolderPlanRejectsSMBUnsafeChildBeforeStageIntent() async throws {
        let root = try LocalStorageTestFixtures.directory(), tree = try folder(root)
        try Data([7]).write(to: tree.appendingPathComponent("Bad:name"), options: .withoutOverwriting)
        do { _ = try await SMBFolderUploadPlan.inspect(tree, excluding: []); XCTFail("SMB-unsafe member accepted") }
        catch { XCTAssertEqual(error as? SMBUploadGroupIssue, .invalidSelection) }
    }

    func testFolderHistoryHasOneRootRecordAndRequiresVerifiedMembersBeforePublication() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let id = UUID()
        let record = SMBUploadRecord(id: id, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
            account: "generated", directory: [], remoteName: try SMBRemoteName("Tree"), sourceName: "Tree",
            logicalBytes: 5, outcome: .prepared, digest: nil,
            folder: .init(manifestDigest: Data(repeating: 1, count: 32), files: 2, folders: 3))
        try await storage.ledger.prepare(record)
        try storage.ledger.requestStage(id)
        try storage.ledger.confirmFolderRoot(id)
        try storage.ledger.checkpointFolder(id, files: 1, bytes: 3)
        XCTAssertThrowsError(try storage.ledger.requestPublication(id))
        let middle = try await storage.inspect()
        XCTAssertEqual(middle.records.count, 1)
        XCTAssertEqual(middle.records[0].folder?.verifiedFiles, 1)
        XCTAssertEqual(middle.records[0].folder?.verifiedBytes, 3)
        try storage.ledger.checkpointFolder(id, files: 2, bytes: 5)
        try storage.ledger.requestPublication(id)
        try storage.ledger.verify(id, digest: Data(repeating: 2, count: 32))
        let finished = try await storage.inspect()
        XCTAssertEqual(finished.records.count, 1)
        XCTAssertEqual(finished.records[0].outcome, .verified)
        XCTAssertEqual(finished.records[0].folder?.verifiedFiles, 2)
        let closed = await storage.close()
        XCTAssertTrue(closed)
    }

    func testMixedGroupSubmitsOneFolderRootSeriallyAndStopsBeforeTailOnFolderCollision() async throws {
        let root = try LocalStorageTestFixtures.directory(), tree = try folder(root)
        let first = root.appendingPathComponent("First.bin"), tail = root.appendingPathComponent("Tail.bin")
        try Data([8]).write(to: first, options: .withoutOverwriting)
        try Data([9]).write(to: tail, options: .withoutOverwriting)
        let plan = try await SMBUploadGroupPlan.inspect([first, tree, tail], excluding: [], allowsFolders: true)
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let connection = UUID(), calls = GroupCalls()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: {},
                submit: { request, _ in
                    _ = calls.next()
                    return .init(id: request.request, logicalBytes: request.logicalBytes)
                }, submitFolder: { request, _ in
                    _ = calls.next()
                    XCTAssertEqual(request.files, 2)
                    XCTAssertEqual(request.folders, 3)
                    throw SMBUploadFailure.finalCollision
                }, inspectCurrent: { .recorded(id: $0, outcome: .finalCollision) }, sessionID: connection)
            XCTFail("Folder collision accepted")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertEqual(result.completed.map(\.index), [0])
            XCTAssertEqual(result.currentIndex, 1)
            XCTAssertEqual(result.notSubmitted, 1)
            XCTAssertEqual(calls.count, 2)
        }
        let success = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
            directory: [], storage: storage, requireCurrent: {},
            submit: { request, _ in .init(id: request.request, logicalBytes: request.logicalBytes) },
            submitFolder: { request, report in
                report(request.logicalBytes)
                return .init(id: request.request, logicalBytes: request.logicalBytes)
            }, inspectCurrent: { .uncertain(id: $0) }, sessionID: connection)
        XCTAssertEqual(success.completed.map(\.index), [0, 1, 2])
        XCTAssertEqual(success.completed.map(\.logicalBytes), [1, 5, 1])
        let closed = await storage.close(); XCTAssertTrue(closed)
    }

    func testFolderConversationRequiresManifestRootAndEveryFileAckBeforePublication() async throws {
        let root = try LocalStorageTestFixtures.directory(), tree = try folder(root)
        let plan = try await SMBFolderUploadPlan.inspect(tree, excluding: [])
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        let request = try SMBRequestedFolderUpload(connection: UUID(), snapshot: snapshot, directory: [],
                                                   reviewed: plan, name: "Tree")
        let id = request.request.uuidString, encoded = plan.manifest.encoded
        var protocolState = try SMBFolderUploadConversation(request: request, ordinal: 1)
        XCTAssertThrowsError(try protocolState.begin())
        guard case .manifestNeed(0, let count) = try protocolState.text(
            ["folderUploadManifestNeed", id, "1", "0", "\(encoded.count)"]) else { return XCTFail() }
        XCTAssertEqual(count, encoded.count)
        let frame = try protocolState.manifest(offset: 0, bytes: encoded)
        XCTAssertEqual(frame.count, encoded.count + 81)
        guard case .ready = try protocolState.text(["folderUploadReady", id, "1"]) else { return XCTFail() }
        XCTAssertEqual(try protocolState.begin(), "BEGIN_FOLDER_UPLOAD \(id) 1\n")
        guard case .rootCreated = try protocolState.text(["folderUploadRootCreated", id, "1"]) else { return XCTFail() }
        XCTAssertEqual(try protocolState.acknowledgeRoot(), "FOLDER_ROOT_ACK \(id) 1\n")
        var verifiedFiles = 0, verifiedBytes: UInt64 = 0
        var treeDigest = SHA256(); treeDigest.update(data: encoded)
        for (node, member) in plan.manifest.nodes.enumerated() where !member.directory {
            let name = String(data: member.components.last!, encoding: .utf8)
            let bytes = name == "One.bin" ? Data([1, 2, 3]) : Data([4, 5])
            guard case .need(let actual, 0, 0, let amount) = try protocolState.text(
                ["folderUploadNeed", id, "1", "\(node)", "0", "0", "\(bytes.count)"]),
                actual == node, amount == bytes.count else { return XCTFail() }
            XCTAssertEqual(try protocolState.data(node: node, sequence: 0, offset: 0, bytes: bytes).count, bytes.count + 81)
            guard case .sourceDigest(let digestNode) = try protocolState.text(["folderUploadSourceDigest", id, "1", "\(node)"]),
                  digestNode == node else { return XCTFail() }
            let digest = Data(SHA256.hash(data: bytes)); treeDigest.update(data: digest)
            XCTAssertTrue(try protocolState.supplyDigest(node: node, value: digest).hasPrefix("FOLDER_FILE_DIGEST"))
            verifiedFiles += 1; verifiedBytes += UInt64(bytes.count)
            guard case .fileVerified(let verifiedNode, let files, let received) = try protocolState.text(
                ["folderUploadFileVerified", id, "1", "\(node)", "\(verifiedFiles)", "\(verifiedBytes)"]),
                verifiedNode == node, files == verifiedFiles, received == verifiedBytes else { return XCTFail() }
            XCTAssertTrue(try protocolState.acknowledgeFile(node: node, files: verifiedFiles, bytes: verifiedBytes).hasPrefix("FOLDER_FILE_ACK"))
        }
        let digest = Data(treeDigest.finalize()), hex = digest.map { String(format: "%02x", $0) }.joined()
        guard case .stageVerified(let stageDigest) = try protocolState.text(["folderUploadStageVerified", id, "1", hex]),
              stageDigest == digest else { return XCTFail() }
        XCTAssertTrue(try protocolState.commit(digest).hasPrefix("COMMIT_FOLDER_UPLOAD"))
        guard case .complete(let finalDigest) = try protocolState.text(["folderUploadComplete", id, "1", hex]),
              finalDigest == digest else { return XCTFail() }

        var interrupted = try SMBFolderUploadConversation(request: request, ordinal: 2)
        _ = try interrupted.text(["folderUploadManifestNeed", id, "2", "0", "\(encoded.count)"])
        _ = try interrupted.manifest(offset: 0, bytes: encoded)
        _ = try interrupted.text(["folderUploadReady", id, "2"])
        _ = try interrupted.begin()
        XCTAssertThrowsError(try interrupted.text(["folderUploadStageVerified", id, "2", hex]))
    }

    func testFolderFailureDiagnosticKeepsOnlyFixedWorkerCoordinates() async throws {
        let root = try LocalStorageTestFixtures.directory(), tree = try folder(root)
        let plan = try await SMBFolderUploadPlan.inspect(tree, excluding: [])
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        let request = try SMBRequestedFolderUpload(connection: UUID(), snapshot: snapshot, directory: [],
                                                   reviewed: plan, name: "Tree")
        var conversation = try SMBFolderUploadConversation(request: request, ordinal: 1)
        let id = request.request.uuidString, encoded = plan.manifest.encoded
        _ = try conversation.text(["folderUploadManifestNeed", id, "1", "0", "\(encoded.count)"])
        _ = try conversation.manifest(offset: 0, bytes: encoded)
        _ = try conversation.text(["folderUploadReady", id, "1"])
        _ = try conversation.begin()
        _ = try conversation.text(["folderUploadRootCreated", id, "1"])
        _ = try conversation.acknowledgeRoot()
        guard case .failure(let diagnostic) = try conversation.text(
            ["folderUploadFailure", id, "1", "4", "denied", "5", "3221225506"]) else { return XCTFail() }
        XCTAssertEqual(diagnostic.boundary, 4)
        XCTAssertEqual(diagnostic.cause, 7)
        XCTAssertEqual(diagnostic.command, 5)
        XCTAssertEqual(diagnostic.status, 0xC0000022)
        XCTAssertEqual(conversation.phase, .failed)
        for fields in [["11", "denied", "5", "3221225506"], ["4", "secret", "5", "3221225506"],
                       ["4", "denied", "19", "3221225506"], ["4", "denied", "255", "3221225506"],
                       ["4", "denied", "5", "0"]] {
            XCTAssertNil(SMBFolderUploadDiagnostic.parse(fields))
        }
    }

    func testBrowserDecoderAcceptsFolderFailureBeforeNormalDrain() async throws {
        let root = try LocalStorageTestFixtures.directory(), tree = try folder(root)
        let plan = try await SMBFolderUploadPlan.inspect(tree, excluding: [])
        let session = UUID(); var peer = U1Peer(session: session)
        var decoder = SMBBrowserDecoder(session: session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 0 0 0 0"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 0 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let request = try SMBRequestedFolderUpload(connection: session, snapshot: XCTUnwrap(decoder.snapshot),
                                                   directory: [], reviewed: plan, name: "Tree")
        let id = request.request.uuidString
        _ = try decoder.prepareFolderUpload(request)
        _ = try decoder.consume(peer.line("folderUploadManifestNeed \(id) 1 0 \(plan.manifest.encoded.count)"))
        _ = try decoder.folderUploadManifest(request.request, offset: 0, bytes: plan.manifest.encoded)
        _ = try decoder.consume(peer.line("folderUploadReady \(id) 1"))
        _ = try decoder.beginFolderUpload(request.request)
        _ = try decoder.consume(peer.line("folderUploadRootCreated \(id) 1"))
        _ = try decoder.acknowledgeFolderUploadRoot(request.request)
        guard case .folderUpload(.failure(let failure)) = try decoder.consume(
            peer.line("folderUploadFailure \(id) 1 4 denied 5 3221225506")) else { return XCTFail() }
        XCTAssertEqual(failure.boundary, 4); XCTAssertEqual(failure.status, 0xC0000022)
        _ = try decoder.consume(peer.line("profile " + [String](repeating: "0", count: 19).joined(separator: ",")))
        _ = try decoder.consume(peer.line("networkDrained 4 0 0"))
        _ = try decoder.consume(peer.line("closed denied 1 0"))
        XCTAssertTrue(decoder.closed)
    }

    func testGroupPreflightIsBoundedAndRejectsDuplicateSources() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let plan = try await group(root)
        XCTAssertEqual(plan.items.map(\.name), ["First.bin", "Second.bin", "Third.bin"])
        XCTAssertEqual(plan.logicalBytes, 6)
        XCTAssertEqual(DiagnosticErrorCode(domain: .network, code: 461).symbol, "smb.upload.invalidInput")
        XCTAssertEqual(DiagnosticErrorCode(domain: .network, code: 471).symbol, "smb.group.invalidSelection")
        XCTAssertEqual(DiagnosticErrorCode(domain: .network, code: 476).symbol, "smb.group.historyBusy")
        XCTAssertThrowsError(try SMBUploadGroupPlan.requireHistoryHeadroom(files: 3, retained: 62, active: false)) {
            XCTAssertEqual($0 as? SMBUploadGroupIssue, .historyFull)
        }
        XCTAssertThrowsError(try SMBUploadGroupPlan.requireHistoryHeadroom(files: 1, retained: 0, active: true)) {
            XCTAssertEqual($0 as? SMBUploadGroupIssue, .historyBusy)
        }
        let duplicate = [root.appendingPathComponent("First.bin"), root.appendingPathComponent("First.bin")]
        do { _ = try await SMBUploadGroupPlan.inspect(duplicate, excluding: []); XCTFail("Duplicate source accepted") }
        catch { XCTAssertEqual(error as? SMBUploadGroupIssue, .overlappingSources) }

        let unsupported = root.appendingPathComponent("Notes:2026.txt")
        try Data([10]).write(to: unsupported, options: .withoutOverwriting)
        let renameReview = try await SMBUploadGroupPlan.inspect([unsupported], excluding: [])
        XCTAssertEqual(renameReview.singleFileReview?.name, "Notes:2026.txt")
        let connection = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        XCTAssertNoThrow(try SMBRequestedUpload(connection: connection, snapshot: snapshot, directory: [],
                                                 reviewed: try XCTUnwrap(renameReview.singleFileReview), name: "Notes-2026.txt"))
        do { _ = try await SMBUploadGroupPlan.inspect([unsupported, root.appendingPathComponent("First.bin")], excluding: []);
            XCTFail("Multi-root unsupported basename accepted") }
        catch { XCTAssertEqual(error as? SMBUploadGroupIssue, .invalidSelection) }
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("unsupported-history"))
        let calls = GroupCalls()
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(renameReview, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: {}, submit: { request, _ in
                    _ = calls.next(); return .init(id: request.request, logicalBytes: request.logicalBytes)
                }, inspectCurrent: { _ in nil }, sessionID: connection)
            XCTFail("Direct runner accepted an unreviewed remote basename")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertEqual(result.cause as? SMBUploadFailure, .invalidInput)
            XCTAssertFalse(result.currentMayHaveStarted)
        }
        XCTAssertEqual(calls.count, 0)
        let history = try await storage.inspect()
        XCTAssertTrue(history.records.isEmpty)
        let closed = await storage.close()
        XCTAssertTrue(closed)
    }

    func testGroupStopsAfterFirstFailedMemberWithVerifiedPrefixAndUntouchedTail() async throws {
        let root = try LocalStorageTestFixtures.directory(), plan = try await group(root)
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let calls = GroupCalls(), connection = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: {}, submit: { request, report in
                    let index = calls.next()
                    if index == 1 { throw SMBUploadFailure.finalCollision }
                    report(request.logicalBytes)
                    return .init(id: request.request, logicalBytes: request.logicalBytes)
                }, inspectCurrent: { .recorded(id: $0, outcome: .finalCollision) }, sessionID: connection)
            XCTFail("Second member should stop the group")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertEqual(result.completed.map(\.index), [0])
            XCTAssertEqual(result.currentIndex, 1)
            if case .some(.recorded(_, .finalCollision)) = result.current { } else { XCTFail("Current outcome lost") }
            XCTAssertTrue(result.currentMayHaveStarted)
            XCTAssertEqual(result.notSubmitted, 1)
            XCTAssertEqual(calls.count, 2)
        }
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: {},
                submit: { _, _ in throw SMBUploadFailure.reviewRequired },
                inspectCurrent: { .recorded(id: $0, outcome: .verified) }, sessionID: connection)
            XCTFail("Late completion was not reported")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertEqual(result.completed.map(\.index), [0])
            XCTAssertNil(result.current); XCTAssertNil(result.currentIndex)
            XCTAssertFalse(result.currentMayHaveStarted)
            XCTAssertEqual(result.notSubmitted, 2)
        }
        let history = try await storage.inspect()
        let closed = await storage.close()
        XCTAssertTrue(history.records.isEmpty); XCTAssertTrue(closed)
    }

    func testGroupQueuedRefusalAndLaterHeadroomRaceNeverSubmitTail() async throws {
        let root = try LocalStorageTestFixtures.directory(), plan = try await group(root)
        let storage = SMBUploadStorage(directory: root.appendingPathComponent("upload-history"))
        let calls = GroupCalls(), connection = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete)
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: { throw CancellationError() },
                submit: { request, _ in _ = calls.next(); return .init(id: request.request, logicalBytes: request.logicalBytes) },
                inspectCurrent: { _ in nil }, sessionID: connection)
            XCTFail("Queued cancellation accepted")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertTrue(result.completed.isEmpty); XCTAssertNil(result.current)
            XCTAssertEqual(result.notSubmitted, 3); XCTAssertEqual(calls.count, 0)
        }
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: {}, submit: { request, _ in
                    if calls.next() == 1 { throw SMBUploadGroupIssue.historyFull }
                    return .init(id: request.request, logicalBytes: request.logicalBytes)
                }, inspectCurrent: { .recorded(id: $0, outcome: .notStarted) }, sessionID: connection)
            XCTFail("Later local admission refusal accepted")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertEqual(result.completed.map(\.index), [0])
            XCTAssertNil(result.current); XCTAssertEqual(result.notSubmitted, 2)
            XCTAssertEqual(calls.count, 2)
        }
        do {
            _ = try await SMBUploadGroupRunner.runWithSubmission(plan, connection: connection, snapshot: snapshot,
                directory: [], storage: storage, requireCurrent: {},
                submit: { _, _ in throw SMBUploadFailure.reviewRequired },
                inspectCurrent: { _ in nil }, sessionID: connection)
            XCTFail("Unobserved current member accepted")
        } catch let result as SMBUploadGroupInterruption {
            XCTAssertTrue(result.completed.isEmpty); XCTAssertEqual(result.currentIndex, 0)
            if case .some(.uncertain(_)) = result.current { } else { XCTFail("Unknown current was marked not submitted") }
            XCTAssertEqual(result.notSubmitted, 2)
        }
        let closed = await storage.close(); XCTAssertTrue(closed)
    }

    func testFullPathIsRejectedBeforeAStageIntentCanBeCreated() async throws {
        let fixture = try UploadFoundationFixture(), request = try await request(fixture)
        let long = try SMBRemoteName(String(repeating: "a", count: 255))
        let tail = try SMBRemoteName(String(repeating: "b", count: 110))
        let directory = Array(repeating: long, count: 7) + [tail]
        XCTAssertTrue(directory.allSatisfy(SMBUploadName.safe))
        XCTAssertFalse(SMBRequestedUpload.fitsWorkerPath(directory: directory, name: long,
            temporaryName: ".traverse-smb-upload-" + String(repeating: "0", count: 32) + ".part"))
        let review = try await SFTPUploadSourceReview.inspect(fixture.file, excluding: [])
        XCTAssertThrowsError(try SMBRequestedUpload(connection: request.connection, snapshot: request.snapshot,
            directory: directory, reviewed: review, name: long.displayName)) { error in
            XCTAssertEqual(error as? SMBUploadFailure, .invalidInput)
        }
    }

    func testU1RequiresEachBarrierAndExactBoundedBody() async throws {
        let fixture = try UploadFoundationFixture(), request = try await request(fixture)
        let id = request.request.uuidString, digest = Data(SHA256.hash(data: Data([1, 2, 3])))
        var transfer = try SMBUploadConversation(request: request, ordinal: 1)
        XCTAssertThrowsError(try transfer.begin())
        guard case .ready = try transfer.text(["uploadReady", id, "1"]) else { return XCTFail() }
        XCTAssertEqual(try transfer.begin(), "BEGIN_UPLOAD \(id) 1\n")
        guard case .need(sequence: 0, offset: 0, count: 3) = try transfer.text(["uploadNeed", id, "1", "0", "0", "3"]) else { return XCTFail() }
        XCTAssertThrowsError(try transfer.supplyDigest(digest))
        XCTAssertThrowsError(try transfer.data(sequence: 1, offset: 0, bytes: Data([1, 2, 3])))
        let frame = try transfer.data(sequence: 0, offset: 0, bytes: Data([1, 2, 3]))
        XCTAssertEqual(frame.count, 4 + 73 + 3)
        XCTAssertEqual(Array(frame.suffix(3)), [1, 2, 3])
        guard case .written(3) = try transfer.text(["uploadWritten", id, "1", "3"]) else { return XCTFail() }
        guard case .sourceDigest = try transfer.text(["uploadSourceDigest", id, "1"]) else { return XCTFail() }
        _ = try transfer.supplyDigest(digest)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard case .stageVerified = try transfer.text(["uploadStageVerified", id, "1", hex]) else { return XCTFail() }
        XCTAssertEqual(try transfer.commit(), "COMMIT_UPLOAD \(id) 1\n")
        guard case .complete = try transfer.text(["uploadComplete", id, "1", hex]) else { return XCTFail() }
        XCTAssertThrowsError(try transfer.text(["uploadComplete", id, "1", hex]))

        var forged = try SMBUploadConversation(request: request, ordinal: 2)
        _ = try forged.text(["uploadReady", id, "2"]); _ = try forged.begin()
        XCTAssertThrowsError(try forged.text(["uploadStageVerified", id, "2", hex]))
        XCTAssertThrowsError(try forged.text(["uploadNeed", id, "2", "0", "0", "3"]))
    }

    func testBrowserDecoderBindsU1ToTheCurrentCompleteEncryptedRead() async throws {
        let fixture = try UploadFoundationFixture()
        try Data([1, 2, 3]).write(to: fixture.file, options: .withoutOverwriting)
        let review = try await SFTPUploadSourceReview.inspect(fixture.file, excluding: [])
        let session = UUID(), digest = Data(SHA256.hash(data: Data([1, 2, 3])))
        var peer = U1Peer(session: session)
        var decoder = SMBBrowserDecoder(session: session, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(peer.line("connected encrypted"))
        let read = try decoder.navigate(components: [])
        _ = try decoder.consume(peer.line("began 1 \(read.id.uuidString)"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 0 0 0 0"))
        _ = try decoder.consume(peer.line("snapshot 1 \(read.id.uuidString) 1 0 0 1"))
        _ = try decoder.consume(peer.line("idle 1 complete"))
        let request = try SMBRequestedUpload(connection: session, snapshot: XCTUnwrap(decoder.snapshot),
                                              directory: [], reviewed: review, name: "Final.bin")
        let id = request.request.uuidString
        XCTAssertTrue(try decoder.prepareUpload(request).hasPrefix("PREPARE_UPLOAD \(id) 1 1 "))
        guard case .upload(.ready) = try decoder.consume(peer.line("uploadReady \(id) 1")) else { return XCTFail() }
        _ = try decoder.beginUpload(request.request)
        guard case .upload(.need(sequence: 0, offset: 0, count: 3)) = try decoder.consume(peer.line("uploadNeed \(id) 1 0 0 3")) else { return XCTFail() }
        XCTAssertEqual(try decoder.uploadData(request.request, sequence: 0, offset: 0, bytes: Data([1, 2, 3])).count, 80)
        _ = try decoder.consume(peer.line("uploadWritten \(id) 1 3"))
        _ = try decoder.consume(peer.line("uploadSourceDigest \(id) 1"))
        _ = try decoder.uploadDigest(request.request, value: digest)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        _ = try decoder.consume(peer.line("uploadStageVerified \(id) 1 \(hex)"))
        _ = try decoder.commitUpload(request.request)
        guard case .upload(.complete) = try decoder.consume(peer.line("uploadComplete \(id) 1 \(hex)")) else { return XCTFail() }
        var counts = [String](repeating: "0", count: 19)
        counts[9] = "1"; counts[17] = "1"
        _ = try decoder.consume(peer.line("profile " + counts.joined(separator: ",")))
        _ = try decoder.consume(peer.line("networkDrained 4 0 0"))
        _ = try decoder.consume(peer.line("closed stopped 1 0"))
        XCTAssertTrue(decoder.closed)

        var forgedPeer = U1Peer(session: UUID())
        var forged = SMBBrowserDecoder(session: forgedPeer.session, requireEncryption: true, mode: .selectedUpload)
        XCTAssertThrowsError(try forged.consume(forgedPeer.line("connected signed")))
        forgedPeer = U1Peer(session: UUID())
        forged = SMBBrowserDecoder(session: forgedPeer.session, requireEncryption: true, mode: .selectedUpload)
        _ = try forged.consume(forgedPeer.line("connected encrypted"))
        XCTAssertThrowsError(try forged.consume(forgedPeer.line("uploadReady \(id) 1")))
    }

    func testDurableStageAndPublicationUncertaintySurviveColdInspection() async throws {
        let fixture = try UploadFoundationFixture(), request = try await request(fixture)
        let ledger = SMBUploadLedger(directory: fixture.history), first = try record(request)
        let empty = try await ledger.inspect()
        XCTAssertTrue(empty.records.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.history.path))
        try await ledger.prepare(first)
        let activeClose = await ledger.close(); XCTAssertFalse(activeClose)
        try await offMain { try ledger.requestStage(first.id) }
        try await ledger.endAfterDrain(first.id, noRemoteMutation: false)
        let firstClose = await ledger.close(); XCTAssertTrue(firstClose)
        var cold = try await ledger.inspect()
        XCTAssertEqual(cold.records.first?.outcome, .stageMayExist)
        XCTAssertTrue(cold.active.isEmpty)
        do { try await ledger.forget(first.id, revision: 1); XCTFail("Stale history revision accepted") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .staleRevision) }
        try await ledger.forget(first.id, revision: cold.revision)

        let next = try record(request)
        try await ledger.prepare(next)
        try await offMain {
            try ledger.requestStage(next.id)
            try ledger.confirmStage(next.id)
            try ledger.requestPublication(next.id)
        }
        try await ledger.endAfterDrain(next.id, noRemoteMutation: false)
        let nextClose = await ledger.close(); XCTAssertTrue(nextClose)
        cold = try await ledger.inspect()
        XCTAssertEqual(cold.records.first?.outcome, .reviewPublication)
        XCTAssertTrue(cold.active.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data([1, 2, 3]))
        let finalClose = await ledger.close(); XCTAssertTrue(finalClose)
    }

    func testUncertainLocalPrepareCannotAdvanceARemoteStage() async throws {
        let fixture = try UploadFoundationFixture(), request = try await request(fixture)
        let ledger = SMBUploadLedger(directory: fixture.history, probe: { stage in
            if stage == .renamed { throw RemoteSettingsFailure.unavailable }
        })
        do { try await ledger.prepare(try record(request)); XCTFail("Expected uncertain local rename") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .durabilityUncertain) }
        let firstClose = await ledger.close(); XCTAssertTrue(firstClose)
        let cold = try await ledger.inspect()
        XCTAssertEqual(cold.records.first?.coldOutcome, .notStarted)
        XCTAssertTrue(cold.active.isEmpty)
        do { try await offMain { try ledger.requestStage(request.request) }; XCTFail("Unadmitted stage advanced") }
        catch { XCTAssertEqual(error as? RemoteSettingsFailure, .invalidRecord) }
        let finalClose = await ledger.close(); XCTAssertTrue(finalClose)
    }

    func testLegacySavedServerStaysReadOnlyAndExplicitOptInSurvivesPresentationEdit() async throws {
        let fixture = try UploadFoundationFixture()
        let store = SMBSavedServerStore(directory: fixture.root.appendingPathComponent("saved-smb"))
        let address = try SMBConnectionAddress("smb://generated.invalid/Shared")
        let legacy = try SMBServerDraft(name: "Generated", address: address, account: "generated",
                                        domain: "", security: .encrypted)
        XCTAssertNil(legacy.transferPreference)
        XCTAssertEqual(legacy.effectiveTransferPreference, .readOnly)
        var result = try await store.openForExplicitWrite()
        result = try await store.apply(.saveServer(legacy, id: nil, credentialID: nil), expectedRevision: result.snapshot.revision)
        let id = try XCTUnwrap(result.serverID)
        await store.close()

        let reopened = SMBSavedServerStore(directory: fixture.root.appendingPathComponent("saved-smb"))
        result = try await reopened.openForExplicitWrite()
        XCTAssertEqual(result.snapshot.visibleServers.first?.details.effectiveTransferPreference, .readOnly)
        let optedIn = try SMBServerDraft(name: "Generated", address: address, account: "generated",
                                         domain: "", security: .encrypted, transferPreference: .normal)
        result = try await reopened.apply(.saveServer(optedIn, id: id, credentialID: nil), expectedRevision: result.snapshot.revision)
        result = try await reopened.apply(.updatePresentation(id, label: "Renamed", components: []),
                                          expectedRevision: result.snapshot.revision)
        XCTAssertEqual(result.snapshot.visibleServers.first?.details.transferPreference, .normal)
        await reopened.close()
        let cold = try await SMBSavedServerStore(directory: fixture.root.appendingPathComponent("saved-smb")).inspect()
        XCTAssertEqual(cold?.visibleServers.first?.details.transferPreference, .normal)
        XCTAssertEqual(cold?.visibleServers.first?.details.name, "Renamed")
    }

    func testConfirmedCollisionsAndVerifiedSignalHaveDistinctColdOutcomes() async throws {
        let fixture = try UploadFoundationFixture(), request = try await request(fixture)
        let ledger = SMBUploadLedger(directory: fixture.history)
        func newRecord(_ id: UUID) throws -> SMBUploadRecord {
            .init(id: id, server: try SMBConnectionAddress("smb://generated.invalid/Shared"),
                  account: "generated", directory: [], remoteName: request.name,
                  sourceName: "Generated.bin", logicalBytes: request.logicalBytes, outcome: .prepared, digest: nil)
        }
        let stage = UUID(), final = UUID(), verified = UUID()
        try await ledger.prepare(try newRecord(stage))
        try await offMain { try ledger.requestStage(stage); try ledger.stageCollision(stage) }
        try await ledger.prepare(try newRecord(final))
        try await offMain {
            try ledger.requestStage(final); try ledger.confirmStage(final)
            try ledger.requestPublication(final); try ledger.finalCollision(final)
        }
        try await ledger.prepare(try newRecord(verified))
        let digest = Data(SHA256.hash(data: Data([1, 2, 3])))
        try await offMain {
            try ledger.requestStage(verified); try ledger.confirmStage(verified)
            try ledger.requestPublication(verified); try ledger.verify(verified, digest: digest)
        }
        let closed = await ledger.close(); XCTAssertTrue(closed)
        let cold = try await ledger.inspect()
        XCTAssertEqual(cold.records.map(\.outcome), [.stageCollision, .finalCollision, .verified])
        XCTAssertEqual(cold.records.last?.digest, digest)
        XCTAssertTrue(cold.active.isEmpty)
        let finalClose = await ledger.close(); XCTAssertTrue(finalClose)
    }
}
