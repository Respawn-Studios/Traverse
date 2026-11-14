import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBInPlaceSourceTests: XCTestCase, @unchecked Sendable {
    private func baseline(size: UInt64 = 3, attributes: UInt32 = 32) -> SMBRemoteFileSnapshot {
        .init(size: size, allocated: 4096, created: 11, modified: 12, changed: 13,
              attributes: attributes, links: 1, index: 17, volumeCreated: 18, volumeSerial: 19)
    }
    func testPrivateEditOpenAndSourceReleaseHaveSeparateBoundedWire() throws {
        let connection = UUID(), source = UUID()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 2, count: 1, folders: 0, state: .complete)
        let selected = try SMBDownloadSelection(connection: connection, snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("File.txt"), attributes: 32,
                               logicalBytes: 3, modifiedFileTime: 12, objectID: 17, parentID: 16), request: source)
        XCTAssertTrue(selected.command(ordinal: 1, number: 1).hasPrefix("PREPARE_DOWNLOAD "))
        XCTAssertTrue(selected.command(ordinal: 1, number: 1, retainingEditSource: true)
            .hasPrefix("PREPARE_EDIT_OPEN "))
        XCTAssertTrue(selected.command(ordinal: 1, number: 1, retainingEditSource: true)
            .hasSuffix(" 17 16\n"))
        var retained = try SMBDownloadConversation(selection: selected, ordinal: 1, retainingEditSource: true)
        guard case .sourceFull(let refused) = try retained.text(["downloadSourceFull", source.uuidString, "1"]),
              refused == source else {
            return XCTFail("Expected a definite source capacity refusal")
        }
        XCTAssertEqual(retained.phase, .complete)
        var ordinary = try SMBDownloadConversation(selection: selected, ordinal: 1)
        XCTAssertThrowsError(try ordinary.text(["downloadSourceFull", source.uuidString, "1"]))
        let digest = Data(repeating: 1, count: 32)
        for contract in [SMBOriginalEditAttributeContract.exactV1, .archiveWriteV2,
                         .archiveWriteCreationApproxV3] {
            let request = try SMBOriginalEditRequest(id: UUID(), selection: selected, before: baseline(),
                beforeDigest: digest, editedLength: 3, editedDigest: digest,
                attributeContract: contract, sourceToken: source)
            let command = request.command(ordinal: 2, number: 7)
            XCTAssertTrue(command.hasPrefix(contract.prepareVerb.replacingOccurrences(
                of: "PREPARE_EDIT", with: "PREPARE_EDIT_SOURCE") + " "))
            XCTAssertTrue(command.hasSuffix(" " + source.uuidString + "\n"))
        }
        XCTAssertThrowsError(try SMBOriginalEditRequest(id: UUID(), selection: selected, before: baseline(),
            beforeDigest: digest, editedLength: 3, editedDigest: digest, sourceToken: UUID()))
        var decoder = SMBBrowserDecoder(session: connection, requireEncryption: true, mode: .selectedUpload)
        _ = try decoder.consume(Data("MEXSMBU1 \(connection.uuidString) 0 connected encrypted".utf8))
        XCTAssertEqual(try decoder.releaseEditSource(source), "RELEASE_EDIT_SOURCE \(source.uuidString)\n")
        guard case .editSourceReleased(let released)? = try decoder.consume(Data(
            "MEXSMBU1 \(connection.uuidString) 1 editSourceReleased \(source.uuidString)".utf8)),
              released == source else {
            return XCTFail("Expected exact source release acknowledgement")
        }
        XCTAssertEqual(try decoder.releaseEditSource(source), "RELEASE_EDIT_SOURCE \(source.uuidString)\n")
    }
    func testCapturedEditorSaveKeepsAdmissionAfterRefreshAndNavigation() throws {
        let connection = UUID()
        var decoder = SMBBrowserDecoder(session: connection, requireEncryption: true, mode: .selectedUpload)
        var sequence: UInt64 = 0
        func receive(_ body: String) throws {
            _ = try decoder.consume(Data("MEXSMBU1 \(connection.uuidString) \(sequence) \(body)".utf8))
            sequence += 1
        }
        func completeRead(_ components: [SMBRemoteName], number: UInt64, count: Int64) throws {
            let read = try decoder.navigate(components: components)
            XCTAssertEqual(read.number, number)
            try receive("began \(number) \(read.id.uuidString)")
            try receive("snapshot \(number) \(read.id.uuidString) 1 \(count) 0 1")
            try receive("idle \(number) complete")
        }
        try receive("connected encrypted")
        try completeRead([], number: 1, count: 1)
        let opened = try XCTUnwrap(decoder.snapshot)
        let selection = try SMBDownloadSelection(connection: connection, snapshot: opened,
            observation: .init(id: 1, name: SMBRemoteName("File.txt"), attributes: 32,
                               logicalBytes: 3, modifiedFileTime: 12, objectID: 17, parentID: 16))
        let digest = Data(repeating: 1, count: 32)
        let request = try SMBOriginalEditRequest(id: UUID(), selection: selection, before: baseline(),
            beforeDigest: digest, editedLength: 3, editedDigest: digest,
            attributeContract: .archiveWriteCreationApproxV3, sourceToken: selection.request)
        let legacy = try SMBOriginalEditRequest(id: UUID(), selection: selection, before: baseline(),
            beforeDigest: digest, editedLength: 3, editedDigest: digest)
        try completeRead([], number: 2, count: 1)
        var old = decoder
        XCTAssertThrowsError(try old.prepareEdit(legacy))
        var afterRefresh = decoder
        XCTAssertTrue(try afterRefresh.prepareEdit(request).contains("PREPARE_EDIT_SOURCE_V3 "))
        try completeRead([try SMBRemoteName("Elsewhere")], number: 3, count: 0)
        old = decoder
        XCTAssertThrowsError(try old.prepareEdit(legacy))
        XCTAssertTrue(try decoder.prepareEdit(request).contains("PREPARE_EDIT_SOURCE_V3 "))
    }
    func testEditOnlyExposureDoesNotGrantReceivedDownloadOrOtherWrites() throws {
        let root = try LocalStorageTestFixtures.directory()
        let address = try SMBConnectionAddress("smb://127.0.0.1:15445/Shared")
        let request = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "",
                                         security: .encrypted, transferPreference: .normal)
        let endpoint = try SMBPreparedConnection.select(address, candidates: [.init(family: .ipv4,
            addressBytes: Data([127, 0, 0, 1]), scopeID: 0, interfaceIndex: 0)])
        let owner = try SMBBrowserOwner(bundle: root.appendingPathComponent("Absent.app"), request: request,
            endpoint: endpoint, storage: SMBTemporaryStorage(directory: root.appendingPathComponent("catalogs")),
            activity: FileActivityGate(maximumActivities: 1), password: SMBPassword("generated-control-only"),
            selectedDownloads: false, textReads: true, freshUploads: true)
        let browser = SMBBrowserSession(owner, exposedSelectedDownloads: false, exposedFolderDownloads: false,
            exposedTextReads: true, exposedInPlaceTextEdits: true, exposedSelectedUploads: false,
            exposedFolderUploads: false, exposedSelectedActions: false)
        XCTAssertTrue(browser.allowsInPlaceTextEdit)
        XCTAssertTrue(browser.allowsTextRead)
        XCTAssertFalse(browser.allowsSelectedDownloads)
        XCTAssertFalse(browser.allowsSelectedUploads)
        XCTAssertFalse(browser.allowsFolderUploads)
        XCTAssertFalse(browser.allowsSelectedActions)
    }
    func testEditConversationRequiresEntireBodyBeforeAuthorizationAndCheckedCompletion() throws {
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: try SMBRemoteName("File.txt"), attributes: 32,
                               logicalBytes: 3, modifiedFileTime: 12))
        let request = try SMBOriginalEditRequest(id: UUID(), selection: selection, before: baseline(),
            beforeDigest: Data(repeating: 1, count: 32), editedLength: 3,
            editedDigest: Data(repeating: 2, count: 32))
        var conversation = try SMBOriginalEditConversation(request: request, ordinal: 1)
        XCTAssertThrowsError(try conversation.authorize())
        guard case .need = try conversation.text(["editNeed", request.id.uuidString, "1", "0", "0", "3"]) else {
            return XCTFail("Expected bounded body request")
        }
        let frame = try conversation.data(sequence: 0, offset: 0, bytes: Data("abc".utf8))
        XCTAssertEqual(frame.prefix(4), Data([0, 0, 0, 76]))
        XCTAssertEqual(frame[4], 5)
        XCTAssertEqual(frame.suffix(3), Data("abc".utf8))
        guard case .ready = try conversation.text(["editReady", request.id.uuidString, "1"]) else {
            return XCTFail("Expected prepare acknowledgement")
        }
        XCTAssertEqual(try conversation.authorize(), "AUTHORIZE_EDIT \(request.id.uuidString) 1\n")
        var fault = conversation
        guard case .fault(let faultID, let checkpoint) = try fault.text(
            ["editFault", request.id.uuidString, "1", "6"]) else {
            return XCTFail("Expected fixed postwrite diagnostic")
        }
        XCTAssertEqual(faultID, request.id)
        XCTAssertEqual(checkpoint, 6)
        XCTAssertEqual(fault.phase, .failed)
        var attributeFault = conversation
        guard case .fault(_, let attributeCheckpoint) = try attributeFault.text(
            ["editFault", request.id.uuidString, "1", "26"]) else {
            return XCTFail("Expected fixed attribute diagnostic")
        }
        XCTAssertEqual(attributeCheckpoint, 26)
        var invalidFault = conversation
        XCTAssertThrowsError(try invalidFault.text(["editFault", request.id.uuidString, "1", "2"]))
        var outsideFault = conversation
        XCTAssertThrowsError(try outsideFault.text(["editFault", request.id.uuidString, "1", "30"]))
        let after = baseline()
        let fields = ["editComplete", request.id.uuidString, "1", String(after.size), String(after.allocated),
            String(after.created), String(after.modified), String(after.changed), String(after.attributes),
            String(after.links), String(after.index), String(after.volumeCreated), String(after.volumeSerial)]
        guard case .complete(_, let completed) = try conversation.text(fields) else {
            return XCTFail("Expected checked completion")
        }
        XCTAssertEqual(completed, after)
    }
    func testEditConversationRejectsEarlyReadyAndInvalidCompletionIdentity() throws {
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: try SMBRemoteName("File.txt"), attributes: 32,
                               logicalBytes: 3, modifiedFileTime: 12))
        let request = try SMBOriginalEditRequest(id: UUID(), selection: selection, before: baseline(),
            beforeDigest: Data(repeating: 1, count: 32), editedLength: 3,
            editedDigest: Data(repeating: 2, count: 32))
        var early = try SMBOriginalEditConversation(request: request, ordinal: 1)
        XCTAssertThrowsError(try early.text(["editReady", request.id.uuidString, "1"]))
        var wrong = try SMBOriginalEditConversation(request: request, ordinal: 1)
        _ = try wrong.text(["editNeed", request.id.uuidString, "1", "0", "0", "3"])
        _ = try wrong.data(sequence: 0, offset: 0, bytes: Data("abc".utf8))
        _ = try wrong.text(["editReady", request.id.uuidString, "1"])
        _ = try wrong.authorize()
        let after = baseline()
        XCTAssertThrowsError(try wrong.text(["editComplete", request.id.uuidString, "1", "3", "4096", "11", "12", "13",
                                              "32", "1", "999", String(after.volumeCreated), String(after.volumeSerial)]))
    }
    func testV2AttributePredicateAndReceiptCannotBeUsedForV1() throws {
        let v1 = SMBOriginalEditAttributeContract.exactV1
        let v2 = SMBOriginalEditAttributeContract.archiveWriteV2
        let v3 = SMBOriginalEditAttributeContract.archiveWriteCreationApproxV3
        XCTAssertFalse(v1.permitsFirstPostwrite(before: 0x80, after: 0x20))
        for (before, after) in [(UInt32(0x80), UInt32(0x20)), (0x02, 0x22), (0x02, 0x02), (0x20, 0x20)] {
            XCTAssertTrue(v2.permitsFirstPostwrite(before: before, after: after))
            XCTAssertTrue(v3.permitsFirstPostwrite(before: before, after: after))
        }
        for (before, after) in [(UInt32(0x80), UInt32(0xa0)), (0x22, 0x02), (0x02, 0x20),
                                (0x00, 0x20), (0x01, 0x02), (0x20, 0x00)] {
            XCTAssertFalse(v2.permitsFirstPostwrite(before: before, after: after))
            XCTAssertFalse(v3.permitsFirstPostwrite(before: before, after: after))
        }
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: try SMBRemoteName("File.txt"), attributes: 0x80,
                               logicalBytes: 3, modifiedFileTime: 12))
        func request(_ contract: SMBOriginalEditAttributeContract) throws -> SMBOriginalEditRequest {
            try SMBOriginalEditRequest(id: UUID(), selection: selection, before: baseline(attributes: 0x80),
                beforeDigest: Data(repeating: 1, count: 32), editedLength: 3,
                editedDigest: Data(repeating: 2, count: 32), attributeContract: contract)
        }
        func authorized(_ request: SMBOriginalEditRequest) throws -> SMBOriginalEditConversation {
            var conversation = try SMBOriginalEditConversation(request: request, ordinal: 1)
            _ = try conversation.text(["editNeed", request.id.uuidString, "1", "0", "0", "3"])
            _ = try conversation.data(sequence: 0, offset: 0, bytes: Data("abc".utf8))
            _ = try conversation.text(["editReady", request.id.uuidString, "1"])
            _ = try conversation.authorize()
            return conversation
        }
        let strict = try request(.exactV1), archive = try request(.archiveWriteV2)
        let creationApprox = try request(.archiveWriteCreationApproxV3)
        XCTAssertTrue(strict.command(ordinal: 1, number: 1).hasPrefix("PREPARE_EDIT "))
        XCTAssertTrue(archive.command(ordinal: 1, number: 1).hasPrefix("PREPARE_EDIT_V2 "))
        XCTAssertTrue(creationApprox.command(ordinal: 1, number: 1).hasPrefix("PREPARE_EDIT_V3 "))
        func receipt(_ verb: String, _ request: SMBOriginalEditRequest, _ attributes: UInt32,
                     created: UInt64 = 11, volumeCreated: UInt64 = 18, index: UInt64 = 17,
                     volumeSerial: UInt32 = 19, links: UInt32 = 1) -> [String] {
            let after = baseline(attributes: attributes)
            return [verb, request.id.uuidString, "1", String(after.size), String(after.allocated),
                String(created), String(after.modified), String(after.changed), String(after.attributes),
                String(links), String(index), String(volumeCreated), String(volumeSerial)]
        }
        var strictConversation = try authorized(strict)
        XCTAssertThrowsError(try strictConversation.text(receipt("editCompleteV2", strict, 0x20)))
        strictConversation = try authorized(strict)
        XCTAssertThrowsError(try strictConversation.text(receipt("editComplete", strict, 0x20)))
        var archiveConversation = try authorized(archive)
        XCTAssertThrowsError(try archiveConversation.text(receipt("editComplete", archive, 0x20)))
        archiveConversation = try authorized(archive)
        guard case .complete(_, let after) = try archiveConversation.text(receipt("editCompleteV2", archive, 0x20)) else {
            return XCTFail("Expected versioned v2 completion")
        }
        XCTAssertEqual(after.attributes, 0x20)
        archiveConversation = try authorized(archive)
        XCTAssertThrowsError(try archiveConversation.text(receipt("editCompleteV2", archive, 0x20,
                                                                    created: 23, volumeCreated: 24)))
        var v3Conversation = try authorized(creationApprox)
        XCTAssertThrowsError(try v3Conversation.text(receipt("editCompleteV2", creationApprox, 0x20)))
        v3Conversation = try authorized(creationApprox)
        guard case .complete(_, let v3After) = try v3Conversation.text(receipt("editCompleteV3", creationApprox,
            0x20, created: 23, volumeCreated: 24)) else { return XCTFail("Expected v3 creation approximation") }
        XCTAssertEqual(v3After.created, 23)
        XCTAssertEqual(v3After.volumeCreated, 24)
        v3Conversation = try authorized(creationApprox)
        XCTAssertThrowsError(try v3Conversation.text(receipt("editCompleteV3", creationApprox, 0x20, index: 18)))
        v3Conversation = try authorized(creationApprox)
        XCTAssertThrowsError(try v3Conversation.text(receipt("editCompleteV3", creationApprox, 0x20, volumeSerial: 20)))
        v3Conversation = try authorized(creationApprox)
        XCTAssertThrowsError(try v3Conversation.text(receipt("editCompleteV3", creationApprox, 0x20, links: 2)))
    }
    func testJournalKeepsCanonicalV1AndVersionedV2RecordsDistinct() throws {
        let before = SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 1, count: 32))
        let edited = SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 2, count: 32))
        let original = SMBInPlaceRecord(id: UUID(), session: UUID(), editorGeneration: UUID(),
            fileName: "File.txt", server: "smb://example.invalid/Share", account: "owner",
            before: before, edited: edited, baseline: baseline(attributes: 0x80))
        var v1 = SMBInPlaceJournalDocument(); v1.records = [original]
        let legacy = try v1.encoded()
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("attributeContract"))
        XCTAssertEqual(try SMBInPlaceJournalDocument.decode(legacy).encoded(), legacy)
        var v2record = SMBInPlaceRecord(id: UUID(), session: UUID(), editorGeneration: UUID(),
            fileName: "Next.txt", server: "smb://example.invalid/Share", account: "owner",
            before: SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 3, count: 32)),
            edited: SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 4, count: 32)),
            baseline: baseline(attributes: 0x80))
        v2record.attributeContract = .archiveWriteV2
        v2record.after = baseline(attributes: 0x20)
        v2record.outcome = .verified
        XCTAssertNoThrow(try v2record.validate())
        var strictVerified = original
        strictVerified.after = baseline(attributes: 0x20); strictVerified.outcome = .verified
        XCTAssertThrowsError(try strictVerified.validate())
        v1.records.append(v2record)
        XCTAssertThrowsError(try v1.encoded())
        v1.format = 2; v1.protocolIdentity = "smb-original-inplace-save-v2"
        let mixed = try v1.encoded()
        let reopened = try SMBInPlaceJournalDocument.decode(mixed)
        XCTAssertEqual(reopened.records[0].attributeContract, nil)
        XCTAssertEqual(reopened.records[1].attributeContract, .archiveWriteV2)
        XCTAssertEqual(try reopened.encoded(), mixed)
        var v3record = SMBInPlaceRecord(id: UUID(), session: UUID(), editorGeneration: UUID(),
            fileName: "Third.txt", server: "smb://example.invalid/Share", account: "owner",
            before: SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 5, count: 32)),
            edited: SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 6, count: 32)),
            baseline: baseline(attributes: 0x80))
        v3record.attributeContract = .archiveWriteCreationApproxV3
        v3record.after = .init(size: 3, allocated: 4096, created: 23, modified: 12, changed: 13,
                               attributes: 0x20, links: 1, index: 17, volumeCreated: 24, volumeSerial: 19)
        v3record.outcome = .verified
        XCTAssertNoThrow(try v3record.validate())
        var oldV2 = v2record; oldV2.after = v3record.after
        XCTAssertThrowsError(try oldV2.validate())
        v1.records.append(v3record)
        XCTAssertThrowsError(try v1.encoded())
        v1.format = 3; v1.protocolIdentity = "smb-original-inplace-save-v3"
        let upgraded = try v1.encoded()
        let v3Reopened = try SMBInPlaceJournalDocument.decode(upgraded)
        XCTAssertEqual(v3Reopened.records.map(\.attributeContract), [nil, .archiveWriteV2, .archiveWriteCreationApproxV3])
        XCTAssertEqual(try v3Reopened.encoded(), upgraded)
    }
    func testProtocolSpecificJournalRejectsDuplicateRecoveryReferences() throws {
        let source = baseline()
        let before = SMBInPlaceBodyReference(id: UUID(), logicalBytes: 3, digest: Data(repeating: 1, count: 32))
        let edited = SMBInPlaceBodyReference(id: UUID(), logicalBytes: 0, digest: Data(repeating: 2, count: 32))
        let record = SMBInPlaceRecord(id: UUID(), session: UUID(), editorGeneration: UUID(),
            fileName: "File.txt", server: "smb://example.invalid/Share", account: "owner",
            before: before, edited: edited, baseline: source)
        var document = SMBInPlaceJournalDocument(); document.revision = 1; document.records = [record]
        let bytes = try document.encoded()
        XCTAssertEqual(try SMBInPlaceJournalDocument.decode(bytes).records, [record])
        document.records.append(record)
        XCTAssertThrowsError(try document.encoded())
        let otherEdited = SMBInPlaceBodyReference(id: UUID(), logicalBytes: 1,
                                                  digest: Data(repeating: 3, count: 32))
        let second = SMBInPlaceRecord(id: UUID(), session: UUID(), editorGeneration: UUID(),
            fileName: "Other.txt", server: "smb://example.invalid/Share", account: "owner",
            before: before, edited: otherEdited, baseline: source)
        document.records = [record, second]
        XCTAssertThrowsError(try document.encoded())
    }
    func testV4UpgradeBindsExactV3RecordAndPreservesItsGraph() throws {
        let identity = ConnectionWorkspaceIdentity(stat(), volume: UUID())
        var v3 = ConnectionWorkspaceRecord()
        v3.format = 3; v3.protocolIdentity = "traverse-persistent-connections-v3"
        v3.revision = 2; v3.phase = .active; v3.activationID = UUID(); v3.budgetID = UUID()
        v3.locationDigest = Data(repeating: 3, count: 32)
        v3.earlier = identity; v3.earlierLock = identity
        v3.graph = Dictionary(uniqueKeysWithValues: ConnectionWorkspaceDisk.graphKeys.map { ($0, identity) })
        let oldBytes = try v3.encoded()
        XCTAssertEqual(try ConnectionWorkspaceRecord.decode(oldBytes).format, 3)
        var v4 = v3
        v4.format = 4; v4.protocolIdentity = "traverse-persistent-connections-v4"; v4.revision = 3
        v4.smbUpgradeSourceDigest = Data(SHA256.hash(data: oldBytes))
        for key in ConnectionWorkspaceDisk.smbGraphKeys.subtracting(ConnectionWorkspaceDisk.graphKeys) {
            v4.graph[key] = identity
        }
        XCTAssertTrue(try ConnectionWorkspaceSMBUpgradeDisk.successor(v3, v4))
        XCTAssertEqual(try ConnectionWorkspaceRecord.decode(v4.encoded()).format, 4)
        var changed = v4; changed.smbUpgradeSourceDigest = Data(repeating: 9, count: 32)
        XCTAssertFalse(try ConnectionWorkspaceSMBUpgradeDisk.successor(v3, changed))
        changed = v4; changed.graph.removeValue(forKey: "smbJournalLock")
        XCTAssertThrowsError(try changed.encoded())
    }
    func testLocalPreAndPostAuthorizationInterruptionsRemainColdReadable() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let layout = try ApplicationStorageLayout(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Cache", isDirectory: true),
            bundleIdentifier: "generated.smb-inplace")
        let workspace = try ConnectionWorkspace(layout: layout)
        let address = try SMBConnectionAddress("smb://127.0.0.1:15445/Shared")
        let server = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "",
                                        security: .encrypted, transferPreference: .normal)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: try SMBRemoteName("File.txt"), attributes: 32,
                               logicalBytes: 7, modifiedFileTime: 12))
        let before = try TextDocumentValue.original(Data("before\n".utf8))
        let initial = baseline(size: 7)
        do {
            _ = try await workspace.prepareForConnect()
            let admission = try await workspace.prepareSMBInPlaceEdits()
            let storage = try SMBInPlaceWorkingCopyStorage(metadataStorage: admission.metadataStorage)
            XCTAssertEqual(storage.originalSaveAttributePolicy, .exactV1)
            let first = try await storage.prepareSave(selection: selection, session: UUID(), generation: UUID(),
                baseline: initial, before: before,
                edited: TextDocumentValue.original(Data("first\n".utf8)), server: server)
            let firstDocument = try await storage.journal.inspect()
            XCTAssertEqual(firstDocument.format, 1)
            await first.endAfterActualDrain()
            let v2Storage = try SMBInPlaceWorkingCopyStorage(metadataStorage: admission.metadataStorage,
                originalSaveAttributePolicy: .sourceQualification)
            XCTAssertEqual(v2Storage.originalSaveAttributePolicy, .sourceQualification)
            let second = try await v2Storage.prepareSave(selection: selection, session: UUID(), generation: UUID(),
                baseline: initial, before: before,
                edited: TextDocumentValue.original(Data("second\n".utf8)), server: server)
            XCTAssertEqual(second.request.attributeContract, .archiveWriteV2)
            XCTAssertEqual(second.record.attributeContract, .archiveWriteV2)
            let mixed = try await v2Storage.journal.inspect()
            XCTAssertEqual(mixed.format, 2)
            XCTAssertEqual(mixed.records.map(\.attributeContract), [nil, .archiveWriteV2])
            try await Task.detached { try second.authorizeOnSessionExecutor() }.value
            await second.endAfterActualDrain()
            let v3Storage = try SMBInPlaceWorkingCopyStorage(metadataStorage: admission.metadataStorage,
                originalSaveAttributePolicy: .creationApproximationQualification)
            let third = try await v3Storage.prepareSave(selection: selection, session: UUID(), generation: UUID(),
                baseline: initial, before: before,
                edited: TextDocumentValue.original(Data("third\n".utf8)), server: server)
            XCTAssertEqual(third.request.attributeContract, .archiveWriteCreationApproxV3)
            XCTAssertEqual(third.record.attributeContract, .archiveWriteCreationApproxV3)
            let upgraded = try await v3Storage.journal.inspect()
            XCTAssertEqual(upgraded.format, 3)
            XCTAssertEqual(upgraded.records.map(\.attributeContract), [nil, .archiveWriteV2,
                                                                .archiveWriteCreationApproxV3])
            await third.endAfterActualDrain()
        } catch { await workspace.stopAndDrain(); throw error }
        await workspace.stopAndDrain()

        let cold = try ConnectionWorkspace(layout: layout)
        do {
            let choices = try await cold.smbRecoveryChoicesAfterExplicitRequest()
            XCTAssertEqual(choices.count, 3)
            if choices.count == 3 {
                XCTAssertEqual(choices.map(\.outcome), [.notStarted, .needsReview, .notStarted])
                let firstBefore = try await choices[0].readVersion(.before).encoded
                let firstEdited = try await choices[0].readVersion(.edited).encoded
                let secondBefore = try await choices[1].readVersion(.before).encoded
                let secondEdited = try await choices[1].readVersion(.edited).encoded
                XCTAssertEqual(firstBefore, before.encoded)
                XCTAssertEqual(firstEdited, Data("first\n".utf8))
                XCTAssertEqual(secondBefore, before.encoded)
                XCTAssertEqual(secondEdited, Data("second\n".utf8))
                let thirdBefore = try await choices[2].readVersion(.before).encoded
                let thirdEdited = try await choices[2].readVersion(.edited).encoded
                XCTAssertEqual(thirdBefore, before.encoded)
                XCTAssertEqual(thirdEdited, Data("third\n".utf8))
            }
        } catch { await cold.stopAndDrain(); throw error }
        await cold.stopAndDrain()
    }
    func testUnjournaledBodyBlocksNewOriginalSave() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let layout = try ApplicationStorageLayout(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Cache", isDirectory: true),
            bundleIdentifier: "generated.smb-orphan")
        let workspace = try ConnectionWorkspace(layout: layout)
        do {
            _ = try await workspace.prepareForConnect()
            let admission = try await workspace.prepareSMBInPlaceEdits()
            let storage = try SMBInPlaceWorkingCopyStorage(metadataStorage: admission.metadataStorage)
            let orphan = try await storage.bodies.stage(Data("unbound\n".utf8))
            let drained = await orphan.spool.abandon()
            XCTAssertTrue(drained)
            let address = try SMBConnectionAddress("smb://127.0.0.1:15445/Shared")
            let server = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "",
                                            security: .encrypted, transferPreference: .normal)
            let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
            let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
                observation: .init(id: 1, name: try SMBRemoteName("File.txt"), attributes: 32,
                                   logicalBytes: 7, modifiedFileTime: 12))
            do {
                _ = try await storage.prepareSave(selection: selection, session: UUID(), generation: UUID(),
                    baseline: baseline(size: 7), before: TextDocumentValue.original(Data("before\n".utf8)),
                    edited: TextDocumentValue.original(Data("edited\n".utf8)), server: server)
                XCTFail("Unjournaled body was admitted")
            } catch RemoteSettingsFailure.recoveryRequired { }
            let records = try await storage.journal.inspect().records
            XCTAssertTrue(records.isEmpty)
        } catch { await workspace.stopAndDrain(); throw error }
        await workspace.stopAndDrain()
    }
}
