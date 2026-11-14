import Foundation
import CryptoKit
import XCTest
@_spi(Qualification) @testable import LocalStorage

/// A real two-role decoder conversation, then the existing exclusive-file
/// exchange. No socket, credential backend or filesystem is involved here.
final class SFTPRoutedUploadProtocolTests: XCTestCase {
    private let session = UUID(), jump = UUID(), generation = UUID(), request = UUID()
    private let digest = Data(repeating: 9, count: 32)
    private func key(_ byte: UInt8) throws -> Data {
        var data = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &data)
        try SFTPWire.field(Data(repeating: byte, count: 32), into: &data); return data
    }
    private func frame(_ sequence: UInt64, _ tag: UInt8, _ payload: Data = Data(), mode: SFTPWireMode = .routedExclusiveUploadCatalog) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: tag, mode: mode) + payload
    }
    private func decoder(_ mode: SFTPWireMode = .routedExclusiveUploadCatalog) throws -> SFTPWorkerDecoder {
        try .init(session: session, canonicalHost: "target.invalid", port: 2222, mode: mode,
                  jump: .init(nonce: jump, host: "jump.invalid", port: 2200))
    }
    private func challenge(_ outer: Bool) throws -> Data {
        var data = outer ? SFTPWire.token(jump) : Data(); data.append(1)
        try SFTPWire.field(Data((outer ? "jump.invalid" : "target.invalid").utf8), into: &data)
        SFTPWire.number(outer ? 2200 : 2222, bytes: 2, into: &data)
        try SFTPWire.field(key(outer ? 1 : 2), into: &data); try SFTPWire.field(Data(), into: &data); return data
    }
    private func summary(_ complete: Bool) -> Data {
        var data = Data(); for value in [UInt64(1), complete ? 1 : 0, 0, 0] { SFTPWire.number(value, bytes: 8, into: &data) }
        data.append(complete ? 1 : 0); return data
    }
    private func opened(_ mode: SFTPWireMode = .routedExclusiveUploadCatalog) throws -> SFTPWorkerDecoder {
        var value = try decoder(mode)
        guard case .jumpChallenge(let outer) = try value.consume(frame(0, 142, challenge(true), mode: mode)) else { throw SFTPProtocolFailure.phase }
        try value.noteJumpApproval(.connectOnce, challenge: outer)
        _ = try value.consume(frame(1, 143, SFTPWire.token(jump), mode: mode))
        try value.noteJumpAuthentication(key: false, interactive: false)
        _ = try value.consume(frame(2, 145, SFTPWire.token(jump), mode: mode))
        guard case .challenge(let target) = try value.consume(frame(3, 100, challenge(false), mode: mode)) else { throw SFTPProtocolFailure.phase }
        XCTAssertNotEqual(outer.current, target.current)
        try value.noteApproval(.connectOnce, challenge: target)
        for (sequence, tag) in [(UInt64(4), UInt8(101)), (5, 102), (6, 109)] { _ = try value.consume(frame(sequence, tag, mode: mode)) }
        try value.beginDirectory(generation); var directory = SFTPWire.token(generation)
        try SFTPWire.field(Data("/generated".utf8), into: &directory); directory.append(summary(false))
        _ = try value.consume(frame(7, 110, directory, mode: mode)); try value.beginNext(generation)
        _ = try value.consume(frame(8, 111, SFTPWire.token(generation) + summary(true), mode: mode)); return value
    }
    private func selection(revision: UInt64 = 1, directory: String = "/generated", generation: UUID? = nil) throws -> SFTPUploadSelection {
        try .init(request: request, generation: generation ?? self.generation, revision: revision, directory: directory,
                  name: SFTPRemoteName(Data("Generated.bin".utf8)), logicalBytes: 3)
    }
    private func started() throws -> Data {
        var data = SFTPWire.token(request) + SFTPWire.token(generation); SFTPWire.number(3, bytes: 8, into: &data)
        try SFTPWire.field(Data(), into: &data); try SFTPWire.field(selection().finalPath, into: &data); return data
    }
    func testExactFileOnlyModeKeepsExistingContractsAndRequiresTwoRoleDecoder() throws {
        let mode = SFTPWireMode.routedExclusiveUploadCatalog
        XCTAssertEqual(mode.magic, Data("MEXSFTPI".utf8)); XCTAssertTrue(mode.isJump && mode.hasRouteBinding && mode.allowsDownloads && mode.allowsFolderDownloads && mode.allowsUploads)
        XCTAssertFalse(mode.allowsFolderUploads)
        for old in [SFTPWireMode.jumpCatalog, .rememberedJumpCatalog, .routedFolderCatalog] { XCTAssertFalse(old.allowsUploads) }
        for direct in [SFTPWireMode.exclusiveUploadCatalog, .freshFolderUploadCatalog] { XCTAssertFalse(direct.isJump); XCTAssertThrowsError(try decoder(direct)) }
        XCTAssertThrowsError(try SFTPWorkerDecoder(session: session, canonicalHost: "target.invalid", port: 2222, mode: mode))
        for old in [SFTPWireMode.jumpCatalog, .rememberedJumpCatalog, .routedFolderCatalog] {
            var value = try opened(old); XCTAssertThrowsError(try value.beginUpload(selection()))
        }
    }
    func testBothVerifiedRolesThenExactFileSourcePermitAndComplete() throws {
        var value = try opened(); try value.beginUpload(selection()); _ = try value.consume(frame(9, 130, started()))
        var source = SFTPWire.token(request); SFTPWire.number(0, bytes: 8, into: &source); SFTPWire.number(3, bytes: 4, into: &source)
        _ = try value.consume(frame(10, 131, source)); _ = try value.noteUploadSource(request, offset: 0, bytes: Data([1, 2, 3]))
        var permit = SFTPWire.token(request); SFTPWire.number(3, bytes: 8, into: &permit); permit.append(digest)
        _ = try value.consume(frame(11, 132, permit)); _ = try value.noteUploadPublication(request, digest: digest)
        var complete = permit; complete.append(contentsOf: [1, 1, 1, 1])
        guard case .uploadComplete(let receipt) = try value.consume(frame(12, 133, complete)) else { return XCTFail() }
        XCTAssertEqual(receipt.selection, try selection()); XCTAssertEqual(receipt.digest, digest)
        XCTAssertNoThrow(try value.beginDirectory(UUID()))
    }
    func testStaleLocationOrConcurrentReadCannotBecomeUploadAuthority() throws {
        for bad in [try selection(revision: 0), try selection(directory: "/elsewhere"), try selection(generation: UUID())] {
            var value = try opened(); XCTAssertThrowsError(try value.beginUpload(bad))
        }
        var value = try opened(); try value.beginUpload(selection())
        XCTAssertThrowsError(try value.beginDirectory(UUID())); XCTAssertThrowsError(try value.beginNext(generation))
        let row = SFTPStoredRow(observation: 1, entry: .init(name: try .init(Data("Other.bin".utf8)), logicalBytes: 3, modifiedSeconds: 1, permissions: 0o100644))
        XCTAssertThrowsError(try value.beginDownload(.init(generation: generation, row: row)))
    }
    func testMissingOuterProofAndCrossModeFramesPoisonTheDecoder() throws {
        var value = try decoder(); XCTAssertThrowsError(try value.consume(frame(0, 100, challenge(false))))
        XCTAssertThrowsError(try value.consume(frame(0, 142, challenge(true))))
        var old = try decoder(.routedFolderCatalog); XCTAssertThrowsError(try old.consume(frame(0, 142, challenge(true))))
        var wrongNonce = try challenge(true); wrongNonce.replaceSubrange(0..<16, with: SFTPWire.token(session))
        var nonce = try decoder(); XCTAssertThrowsError(try nonce.consume(frame(0, 142, wrongNonce)))
    }
    func testTruncatedOrSubstitutedUploadStartPoisonsOnlyThisConversation() throws {
        let body = try frame(9, 130, started())
        for count in 0..<body.count {
            var value = try opened(); try value.beginUpload(selection())
            XCTAssertThrowsError(try value.consume(Data(body.prefix(count)))); XCTAssertThrowsError(try value.consume(body))
        }
        var data = try started(); data.replaceSubrange(0..<16, with: SFTPWire.token(UUID()))
        var wrong = try opened(); try wrong.beginUpload(selection()); XCTAssertThrowsError(try wrong.consume(frame(9, 130, data)))
    }
    func testTerminalMustRetainTheOuterTaskFactAndClearLiveUpload() throws {
        var payload = Data([15, 0, 0]); SFTPWire.number(2, bytes: 8, into: &payload); SFTPWire.number(0, bytes: 8, into: &payload); payload.append(1)
        var missing = try opened(); try missing.beginUpload(selection()); XCTAssertThrowsError(try missing.consume(frame(9, 107, payload)))
        payload.append(0); var value = try opened(); try value.beginUpload(selection())
        guard case .closed(let end) = try value.consume(frame(9, 107, payload)) else { return XCTFail() }
        XCTAssertTrue(end.runtimeDisposed); XCTAssertEqual(end.jumpTaskEndedBeforeRuntimeDrop, false)
        XCTAssertFalse(end.sshTaskEndedBeforeRuntimeDrop); XCTAssertEqual(end.catalogWriterEnd, .closed)
        XCTAssertThrowsError(try value.beginUpload(selection()))
    }
    private func folderSelection(empty: Bool = false, revision: UInt64 = 1, directory: String = "/generated") throws -> SFTPFolderUploadSelection {
        var nodes: [SFTPFolderUploadManifest.Node] = [.init(kind: .directory, components: [], size: 0)]
        if !empty { nodes.append(.init(kind: .file, components: [Data("Member".utf8)], size: 3)) }
        return try .init(request: request, generation: generation, revision: revision, directory: directory,
                         name: SFTPRemoteName(Data("Folder".utf8)), manifest: .init(nodes: nodes))
    }
    private func numbers(_ values: [(UInt64, Int)]) -> Data {
        var data = Data(); for (value,width) in values { SFTPWire.number(value, bytes: width, into: &data) }; return data
    }
    func testJHasDistinctFolderAuthorityWithoutWideningReadOnlyOrFileOnlyRoutes() throws {
        let mode = SFTPWireMode.routedFreshFolderUploadCatalog
        XCTAssertEqual(mode.magic, Data("MEXSFTPJ".utf8))
        XCTAssertTrue(mode.isJump && mode.hasRouteBinding && mode.allowsFolderDownloads && mode.allowsUploads && mode.allowsFolderUploads)
        XCTAssertThrowsError(try SFTPWorkerDecoder(session: session, canonicalHost: "target.invalid", port: 2222, mode: mode))
        for old in [SFTPWireMode.rememberedJumpCatalog,.routedFolderCatalog,.routedExclusiveUploadCatalog] {
            XCTAssertFalse(old.allowsFolderUploads); var value = try opened(old)
            XCTAssertThrowsError(try value.beginFolderUpload(folderSelection()))
        }
    }
    func testJCompletesEmptyAndNonemptyTreesAfterBothRolesAndEveryTypedAcknowledgment() throws {
        let mode = SFTPWireMode.routedFreshFolderUploadCatalog, body = Data("abc".utf8)
        for empty in [false,true] {
            var value = try opened(mode), sequence: UInt64 = 9; let selected = try folderSelection(empty: empty)
            try value.beginFolderUpload(selected)
            var started = SFTPWire.token(request) + SFTPWire.token(generation) + numbers([(UInt64(selected.manifest.encoded.count),4)])
            started.append(selected.manifest.digest); started.append(numbers([(UInt64(selected.manifest.files),4),(0,4),(empty ? 0 : 3,8)]))
            try SFTPWire.field(selected.rootPath,into: &started)
            _ = try value.consume(frame(sequence,160,started,mode: mode)); sequence += 1
            _ = try value.consume(frame(sequence,161,SFTPWire.token(request) + numbers([(0,4),(UInt64(selected.manifest.encoded.count),4)]),mode: mode)); sequence += 1
            XCTAssertEqual(try value.noteFolderUploadReply(request: request,.manifest(offset: 0,bytes: selected.manifest.encoded)).0,24)
            _ = try value.consume(frame(sequence,164,SFTPWire.token(request),mode: mode)); sequence += 1
            _ = try value.noteFolderUploadReply(request: request,.rootAcknowledged)
            var hash = SHA256(); hash.update(data: selected.manifest.encoded)
            if !empty {
                let file = Data(SHA256.hash(data: body)); hash.update(data: file)
                _ = try value.consume(frame(sequence,162,SFTPWire.token(request) + numbers([(1,4),(0,8),(3,4)]),mode: mode)); sequence += 1
                _ = try value.noteFolderUploadReply(request: request,.source(node: 1,offset: 0,bytes: body))
                _ = try value.consume(frame(sequence,163,SFTPWire.token(request) + numbers([(1,4)]) + file,mode: mode)); sequence += 1
                _ = try value.noteFolderUploadReply(request: request,.filePermit(node: 1,digest: file))
                _ = try value.consume(frame(sequence,165,SFTPWire.token(request) + numbers([(1,4),(1,4),(3,8)]),mode: mode)); sequence += 1
                _ = try value.noteFolderUploadReply(request: request,.progress(node: 1,files: 1,bytes: 3))
            }
            let aggregate = Data(hash.finalize()), final = SFTPWire.token(request) + numbers([(empty ? 0 : 1,4),(empty ? 0 : 3,8)]) + aggregate
            _ = try value.consume(frame(sequence,166,final,mode: mode)); sequence += 1
            _ = try value.noteFolderUploadReply(request: request,.finalPermit(aggregate))
            guard case .folderUploadComplete(let receipt) = try value.consume(frame(sequence,167,final + Data([1,1,1]),mode: mode)) else { return XCTFail() }
            XCTAssertEqual(receipt.selection,selected); XCTAssertEqual(receipt.digest,aggregate)
            XCTAssertNoThrow(try value.beginDirectory(UUID()))
        }
    }
    func testJStaleDirectoryAndConcurrentWorkCannotBecomeFolderAuthority() throws {
        let mode = SFTPWireMode.routedFreshFolderUploadCatalog
        for selected in [try folderSelection(revision: 2),try folderSelection(directory: "/elsewhere")] {
            var value = try opened(mode); XCTAssertThrowsError(try value.beginFolderUpload(selected))
        }
        var value = try opened(mode); try value.beginFolderUpload(folderSelection())
        XCTAssertThrowsError(try value.beginDirectory(UUID())); XCTAssertThrowsError(try value.beginUpload(selection()))
        XCTAssertThrowsError(try value.beginFolderUpload(folderSelection()))
    }
    func testJRejectsMissingOuterProofAndEveryCrossModeChallenge() throws {
        let mode = SFTPWireMode.routedFreshFolderUploadCatalog
        var missing = try decoder(mode); XCTAssertThrowsError(try missing.consume(frame(0,100,challenge(false),mode: mode)))
        for other in [SFTPWireMode.routedFolderCatalog,.routedExclusiveUploadCatalog,.freshFolderUploadCatalog] {
            var value = try decoder(mode); XCTAssertThrowsError(try value.consume(frame(0,142,challenge(true),mode: other)))
            XCTAssertThrowsError(try value.consume(frame(0,142,challenge(true),mode: mode)))
        }
        var wrong = try challenge(true); wrong.replaceSubrange(0..<16,with: SFTPWire.token(session))
        var value = try decoder(mode); XCTAssertThrowsError(try value.consume(frame(0,142,wrong,mode: mode)))
    }
    func testJTerminalRequiresAnExplicitOuterTaskFactDuringFolderWork() throws {
        let mode = SFTPWireMode.routedFreshFolderUploadCatalog
        var payload = Data([0,0,0]); SFTPWire.number(2,bytes: 8,into: &payload); SFTPWire.number(0,bytes: 8,into: &payload); payload.append(1)
        var missing = try opened(mode); try missing.beginFolderUpload(folderSelection())
        XCTAssertThrowsError(try missing.consume(frame(9,107,payload,mode: mode)))
        payload.append(0); var value = try opened(mode); try value.beginFolderUpload(folderSelection())
        guard case .closed(let end) = try value.consume(frame(9,107,payload,mode: mode)) else { return XCTFail() }
        XCTAssertTrue(end.runtimeDisposed); XCTAssertEqual(end.jumpTaskEndedBeforeRuntimeDrop,false)
        XCTAssertThrowsError(try value.beginFolderUpload(folderSelection()))
    }
}
