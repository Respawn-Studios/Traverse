import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPFolderUploadProtocolTests: XCTestCase {
    private let session = UUID(), generation = UUID(), request = UUID()
    private let fileDigest = Data(SHA256.hash(data: Data("abc".utf8)))
    private func selection(long: Bool = false) throws -> SFTPFolderUploadSelection {
        var nodes: [SFTPFolderUploadManifest.Node] = [.init(kind: .directory, components: [], size: 0)]
        if long { for index in 0..<1024 { nodes.append(.init(kind: .file, components: [Data((String(format: "%04d", index) + String(repeating: "x", count: 60)).utf8)], size: 0)) } }
        else { nodes.append(.init(kind: .file, components: [Data("Member".utf8)], size: 3)) }
        return try .init(request: request, generation: generation, revision: 1, directory: "/generated", name: SFTPRemoteName(Data("Folder".utf8)), manifest: .init(nodes: nodes))
    }
    private func frame(_ sequence: UInt64, _ tag: UInt8, _ payload: Data = Data(), mode: SFTPWireMode = .freshFolderUploadCatalog) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: tag, mode: mode) + payload
    }
    private func summary(_ complete: Bool) -> Data {
        var bytes = Data(); for value: UInt64 in [1, complete ? 1 : 0, complete ? 2 : 0, 0] { SFTPWire.number(value, bytes: 8, into: &bytes) }; bytes.append(complete ? 1 : 0); return bytes
    }
    private func opened(mode: SFTPWireMode = .freshFolderUploadCatalog) throws -> SFTPWorkerDecoder {
        var value = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        var hello = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &hello); SFTPWire.number(22, bytes: 2, into: &hello); try SFTPWire.field(key, into: &hello); try SFTPWire.field(Data(), into: &hello)
        guard case .challenge(let challenge) = try value.consume(frame(0, 100, hello, mode: mode)) else { throw SFTPProtocolFailure.phase }
        try value.noteApproval(.connectOnce, challenge: challenge)
        for (sequence, tag) in [(UInt64(1), UInt8(101)), (2, 102), (3, 109)] { _ = try value.consume(frame(sequence, tag, mode: mode)) }
        try value.beginDirectory(generation); var directory = SFTPWire.token(generation); try SFTPWire.field(Data("/generated".utf8), into: &directory); directory.append(summary(false))
        _ = try value.consume(frame(4, 110, directory, mode: mode)); try value.beginNext(generation)
        _ = try value.consume(frame(5, 111, SFTPWire.token(generation) + summary(true), mode: mode)); return value
    }
    private func numbers(_ values: [(UInt64, Int)]) -> Data { var bytes = Data(); for (value, width) in values { SFTPWire.number(value, bytes: width, into: &bytes) }; return bytes }
    private func start(_ decoder: inout SFTPWorkerDecoder, long: Bool = false) throws -> SFTPFolderUploadSelection {
        let selected = try selection(long: long); try decoder.beginFolderUpload(selected)
        var bytes = SFTPWire.token(request) + SFTPWire.token(generation); bytes.append(numbers([(UInt64(selected.manifest.encoded.count),4)])); bytes.append(selected.manifest.digest)
        bytes.append(numbers([(UInt64(selected.manifest.files),4),(UInt64(selected.manifest.folders),4),(selected.manifest.logicalBytes,8)])); try SFTPWire.field(selected.rootPath, into: &bytes)
        _ = try decoder.consume(frame(6, 160, bytes)); return selected
    }
    private func manifest(_ decoder: inout SFTPWorkerDecoder, selected: SFTPFolderUploadSelection, sequence: inout UInt64) throws {
        var offset = 0
        while offset < selected.manifest.encoded.count {
            let count = min(32768, selected.manifest.encoded.count - offset), value = SFTPWire.token(request) + numbers([(UInt64(offset),4),(UInt64(count),4)])
            _ = try decoder.consume(frame(sequence, 161, value)); sequence += 1
            let reply = try decoder.noteFolderUploadReply(request: request, .manifest(offset: offset, bytes: selected.manifest.encoded.subdata(in: offset..<(offset + count))))
            XCTAssertEqual(reply.0, 24); XCTAssertLessThanOrEqual(reply.1.count + 33, SFTPWorkerDecoder.maximumFrameBytes); offset += count
        }
    }
    private func ready(_ decoder: inout SFTPWorkerDecoder, sequence: inout UInt64) throws -> SFTPFolderUploadSelection {
        let selected = try start(&decoder); try manifest(&decoder, selected: selected, sequence: &sequence)
        _ = try decoder.consume(frame(sequence, 164, SFTPWire.token(request))); sequence += 1
        XCTAssertEqual(try decoder.noteFolderUploadReply(request: request, .rootAcknowledged).0, 27); return selected
    }
    private func member(_ decoder: inout SFTPWorkerDecoder, sequence: inout UInt64) throws {
        _ = try decoder.consume(frame(sequence, 162, SFTPWire.token(request) + numbers([(1,4),(0,8),(3,4)]))); sequence += 1
        _ = try decoder.noteFolderUploadReply(request: request, .source(node: 1, offset: 0, bytes: Data("abc".utf8)))
        _ = try decoder.consume(frame(sequence, 163, SFTPWire.token(request) + numbers([(1,4)]) + fileDigest)); sequence += 1
        _ = try decoder.noteFolderUploadReply(request: request, .filePermit(node: 1, digest: fileDigest))
        _ = try decoder.consume(frame(sequence, 165, SFTPWire.token(request) + numbers([(1,4),(1,4),(3,8)]))); sequence += 1
        _ = try decoder.noteFolderUploadReply(request: request, .progress(node: 1, files: 1, bytes: 3))
    }
    private func treeDigest(_ selected: SFTPFolderUploadSelection) -> Data { var hash = SHA256(); hash.update(data: selected.manifest.encoded); hash.update(data: fileDigest); return Data(hash.finalize()) }
    func testGAndReadOnlyConsentCannotBecomeFolderMutation() throws {
        XCTAssertEqual(SFTPWireMode.freshFolderUploadCatalog.magic, Data("MEXSFTPH".utf8)); XCTAssertEqual(SFTPWireMode.freshFolderUploadCatalog.magic.count, 8)
        for mode in [SFTPWireMode.exclusiveUploadCatalog, .folderCatalog, .interactiveCatalog, .folderUploadCatalog] {
            XCTAssertFalse(mode.allowsFolderUploads); var decoder = try opened(mode: mode); XCTAssertThrowsError(try decoder.beginFolderUpload(selection()))
        }
        var decoder = try opened(); _ = try start(&decoder); XCTAssertThrowsError(try decoder.beginDirectory(UUID()))
        XCTAssertThrowsError(try decoder.beginUpload(.init(request: UUID(), generation: generation, revision: 1, directory: "/generated", name: SFTPRemoteName(Data("Other".utf8)), logicalBytes: 0)))
    }
    func testCompleteTypedManifestSourcePermitProgressAndFinalProof() throws {
        var decoder = try opened(), sequence: UInt64 = 7; let selected = try ready(&decoder, sequence: &sequence); try member(&decoder, sequence: &sequence)
        let digest = treeDigest(selected), final = SFTPWire.token(request) + numbers([(1,4),(3,8)]) + digest
        _ = try decoder.consume(frame(sequence, 166, final)); sequence += 1
        XCTAssertEqual(try decoder.noteFolderUploadReply(request: request, .finalPermit(digest)).0, 29)
        guard case .folderUploadComplete(let receipt) = try decoder.consume(frame(sequence, 167, final + Data([1,1,1]))) else { return XCTFail() }
        XCTAssertEqual(receipt.selection, selected); XCTAssertEqual(receipt.digest, digest); XCTAssertNoThrow(try decoder.beginDirectory(UUID()))
        XCTAssertFalse(String(reflecting: SFTPWorkerEvent.folderUploadComplete(receipt)).contains("Folder"))
    }
    func testLargeManifestUsesRequested32KiBChunksWithinExistingFrames() throws {
        var decoder = try opened(), sequence: UInt64 = 7; let selected = try start(&decoder, long: true)
        XCTAssertGreaterThan(selected.manifest.encoded.count, 65536); try manifest(&decoder, selected: selected, sequence: &sequence)
        _ = try decoder.consume(frame(sequence, 164, SFTPWire.token(request))); XCTAssertEqual(try decoder.noteFolderUploadReply(request: request, .rootAcknowledged).0, 27)
    }
    func testWrongNodeOffsetCountOrDuplicateRequestPoisonDecoder() throws {
        for (node, offset, count): (UInt64, UInt64, UInt64) in [(0,0,3),(2,0,3),(1,1,2),(1,0,0),(1,0,32769)] {
            var decoder = try opened(), sequence: UInt64 = 7; _ = try ready(&decoder, sequence: &sequence)
            XCTAssertThrowsError(try decoder.consume(frame(sequence, 162, SFTPWire.token(request) + numbers([(node,4),(offset,8),(count,4)]))))
            XCTAssertThrowsError(try decoder.consume(frame(sequence, 162, SFTPWire.token(request) + numbers([(1,4),(0,8),(3,4)]))))
        }
        var decoder = try opened(), sequence: UInt64 = 7; _ = try ready(&decoder, sequence: &sequence)
        let valid = SFTPWire.token(request) + numbers([(1,4),(0,8),(3,4)]); _ = try decoder.consume(frame(sequence, 162, valid))
        XCTAssertThrowsError(try decoder.consume(frame(sequence + 1, 162, valid)))
    }
    func testRootMustBeAcknowledgedBeforeBodiesAndWrongReplyCannotRetry() throws {
        var decoder = try opened(), sequence: UInt64 = 7; let selected = try start(&decoder); try manifest(&decoder, selected: selected, sequence: &sequence)
        _ = try decoder.consume(frame(sequence, 164, SFTPWire.token(request))); sequence += 1
        XCTAssertThrowsError(try decoder.consume(frame(sequence, 162, SFTPWire.token(request) + numbers([(1,4),(0,8),(3,4)]))))
        var other = try opened(); sequence = 7; _ = try ready(&other, sequence: &sequence)
        _ = try other.consume(frame(sequence, 162, SFTPWire.token(request) + numbers([(1,4),(0,8),(3,4)])))
        XCTAssertThrowsError(try other.noteFolderUploadReply(request: request, .source(node: 1, offset: 0, bytes: Data([1]))))
        XCTAssertThrowsError(try other.noteFolderUploadReply(request: request, .source(node: 1, offset: 0, bytes: Data("abc".utf8))))
    }
    func testForgedAggregateAndMissingFinalAcknowledgementsCannotComplete() throws {
        for variant in 0..<3 {
            var decoder = try opened(), sequence: UInt64 = 7; let selected = try ready(&decoder, sequence: &sequence); try member(&decoder, sequence: &sequence)
            let digest = treeDigest(selected), final = SFTPWire.token(request) + numbers([(1,4),(3,8)]) + digest
            if variant == 0 { XCTAssertThrowsError(try decoder.consume(frame(sequence, 166, SFTPWire.token(request) + numbers([(1,4),(3,8)]) + Data(repeating: 0, count: 32)))) }
            else {
                _ = try decoder.consume(frame(sequence, 166, final)); sequence += 1
                if variant == 1 { XCTAssertThrowsError(try decoder.consume(frame(sequence, 167, final + Data([1,1,1])))) }
                else { _ = try decoder.noteFolderUploadReply(request: request, .finalPermit(digest)); XCTAssertThrowsError(try decoder.consume(frame(sequence, 167, final + Data([1,1,0])))) }
            }
        }
    }
}
