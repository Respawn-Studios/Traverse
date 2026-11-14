import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private struct FolderWire {
    let session = UUID(), generation = UUID(), outer = UUID()
    var mode: SFTPWireMode = .folderCatalog
    var sequence: UInt64 = 0
    mutating func frame(_ kind: UInt8, _ payload: Data = Data(), mode: SFTPWireMode? = nil) throws -> Data {
        defer { sequence += 1 }; return try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode ?? self.mode) + payload
    }
    func snapshot(complete: Bool) -> Data {
        var data = Data(); for n: UInt64 in [1, complete ? 1 : 0, complete ? 1 : 0, complete ? 1 : 0] { SFTPWire.number(n, bytes: 8, into: &data) }
        data.append(complete ? 1 : 0); return data
    }
    mutating func ready(mode requestedMode: SFTPWireMode = .folderCatalog) throws -> SFTPWorkerDecoder {
        mode = requestedMode
        var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode,
            jump: mode.isJump ? .init(nonce: outer, host: "jump.example", port: 2200, previous: nil) : nil)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        if mode.isJump {
            var hello = SFTPWire.token(outer); hello.append(1)
            try SFTPWire.field(Data("jump.example".utf8), into: &hello); SFTPWire.number(2200, bytes: 2, into: &hello)
            try SFTPWire.field(key, into: &hello); try SFTPWire.field(Data(), into: &hello)
            guard case .jumpChallenge(let challenge) = try decoder.consume(frame(142, hello)) else { throw SFTPProtocolFailure.phase }
            try decoder.noteJumpApproval(.connectOnce, challenge: challenge)
            _ = try decoder.consume(frame(143, SFTPWire.token(outer)))
            try decoder.noteJumpAuthentication(key: false, interactive: false)
            _ = try decoder.consume(frame(145, SFTPWire.token(outer)))
        }
        var hello = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &hello); SFTPWire.number(22, bytes: 2, into: &hello)
        try SFTPWire.field(key, into: &hello); try SFTPWire.field(Data(), into: &hello)
        guard case .challenge(let challenge) = try decoder.consume(frame(100, hello, mode: mode)) else { throw SFTPProtocolFailure.phase }
        try decoder.noteApproval(.connectOnce, challenge: challenge)
        for kind: UInt8 in [101, 102, 109] { _ = try decoder.consume(frame(kind, mode: mode)) }
        try decoder.beginDirectory(generation)
        var payload = SFTPWire.token(generation); try SFTPWire.field(Data("/Generated".utf8), into: &payload); payload.append(snapshot(complete: false))
        _ = try decoder.consume(frame(110, payload, mode: mode)); try decoder.beginNext(generation)
        _ = try decoder.consume(frame(111, SFTPWire.token(generation) + snapshot(complete: true), mode: mode)); return decoder
    }
    func selection() throws -> SFTPFolderDownloadSelection {
        try .init(generation: generation, snapshot: .init(read: 1, revision: 1, count: 1, folders: 1, state: .complete),
            row: .init(observation: 2, entry: .init(name: SFTPRemoteName(Data("Selected".utf8)), logicalBytes: 4096, modifiedSeconds: 19, permissions: 0o040755)))
    }
    mutating func prepare(_ decoder: inout SFTPWorkerDecoder, manifest: SFTPFolderManifest? = nil) throws -> SFTPPreparedFolderDownload {
        let selected = try selection(), manifest = try manifest ?? FolderFixture.manifest()
        try decoder.beginFolder(selected); _ = try decoder.consume(frame(150, selected.command()))
        for (ordinal, node) in manifest.nodes.enumerated() {
            var data = SFTPWire.token(selected.request); SFTPWire.number(UInt64(ordinal), bytes: 4, into: &data); data.append(UInt8(node.components.count))
            for part in node.components { try SFTPWire.field(part, into: &data) }
            data.append(node.size == nil ? 0 : 1); SFTPWire.number(node.size ?? 0, bytes: 8, into: &data)
            SFTPWire.number(UInt64(node.modified), bytes: 4, into: &data); SFTPWire.number(UInt64(node.permissions), bytes: 4, into: &data)
            _ = try decoder.consume(frame(152, data))
        }
        var final = SFTPWire.token(selected.request)
        for value in [manifest.nodes.count, manifest.files, manifest.folders] { SFTPWire.number(UInt64(value), bytes: 4, into: &final) }
        SFTPWire.number(manifest.logicalBytes, bytes: 8, into: &final); SFTPWire.number(UInt64(manifest.longestPathBytes), bytes: 4, into: &final)
        guard case .folderPrepared(let prepared) = try decoder.consume(frame(153, final)) else { throw SFTPProtocolFailure.phase }; return prepared
    }
    func member(_ request: UUID, ordinal: Int, offset: UInt64? = nil, bytes: Data? = nil, length: UInt64? = nil) throws -> Data {
        var data = SFTPWire.token(request); SFTPWire.number(UInt64(ordinal), bytes: 4, into: &data)
        if let offset { SFTPWire.number(offset, bytes: 8, into: &data) }; if let bytes { try SFTPWire.field(bytes, into: &data) }
        if let length { SFTPWire.number(length, bytes: 8, into: &data) }; return data
    }
    func completed(_ request: UUID, bytes: UInt64 = 7, files: UInt64 = 2, ack: UInt8 = 1) -> Data {
        var data = SFTPWire.token(request); SFTPWire.number(bytes, bytes: 8, into: &data); SFTPWire.number(files, bytes: 4, into: &data); data.append(contentsOf: [1, ack]); return data
    }
}

final class SFTPFolderProtocolTests: XCTestCase {
    func testExplicitModeSnapshotAndExclusiveReviewRequired() throws {
        for mode: SFTPWireMode in [.catalog, .transferCatalog, .interactiveTransferCatalog] {
            var wire = FolderWire(), decoder = try wire.ready(mode: mode)
            XCTAssertThrowsError(try decoder.beginFolder(wire.selection()))
        }
        var wire = FolderWire(), decoder = try wire.ready(); let prepared = try wire.prepare(&decoder)
        XCTAssertEqual(prepared.files, 2); XCTAssertFalse(String(reflecting: prepared).contains("Selected"))
        XCTAssertThrowsError(try decoder.beginDirectory(UUID())); XCTAssertThrowsError(try decoder.beginFolder(wire.selection()))
        try decoder.releaseFolder(prepared.selection.request)
        _ = try decoder.consume(wire.frame(159, SFTPWire.token(prepared.selection.request))); XCTAssertNoThrow(try decoder.beginDirectory(UUID()))
    }
    func testExactTwoFileReceiptThenBrowsingCanResume() throws {
        for mode: SFTPWireMode in [.folderCatalog, .routedFolderCatalog] {
        var wire = FolderWire(), decoder = try wire.ready(mode: mode); let prepared = try wire.prepare(&decoder), request = prepared.selection.request
        try decoder.receiveFolder(prepared); _ = try decoder.consume(wire.frame(154, SFTPWire.token(request)))
        for (ordinal, data) in [(3, Data("Fixture".utf8)), (4, Data())] {
            _ = try decoder.consume(wire.frame(155, wire.member(request, ordinal: ordinal)))
            if !data.isEmpty { _ = try decoder.consume(wire.frame(156, wire.member(request, ordinal: ordinal, offset: 0, bytes: data))) }
            _ = try decoder.consume(wire.frame(157, wire.member(request, ordinal: ordinal, length: UInt64(data.count))))
        }
        guard case .folderComplete(_, 7, 2) = try decoder.consume(wire.frame(158, wire.completed(request))) else { return XCTFail() }
        XCTAssertNoThrow(try decoder.beginDirectory(UUID()))
        }
    }
    func testRoutedReviewCancelAndUploadRefusalPreserveIndependentBrowsing() throws {
        var wire = FolderWire(), decoder = try wire.ready(mode: .routedFolderCatalog)
        XCTAssertThrowsError(try decoder.uploadDirectory(wire.generation, revision: 1))
        let prepared = try wire.prepare(&decoder)
        XCTAssertThrowsError(try decoder.beginDirectory(UUID()))
        try decoder.releaseFolder(prepared.selection.request)
        _ = try decoder.consume(wire.frame(159, SFTPWire.token(prepared.selection.request)))
        XCTAssertNoThrow(try decoder.beginDirectory(UUID()))
        XCTAssertFalse(SFTPWireMode.routedFolderCatalog.allowsUploads)
        for legacy: SFTPWireMode in [.jumpCatalog, .rememberedJumpCatalog, .folderCatalog] {
            var wrong = FolderWire(), old = try wrong.ready(mode: legacy == .folderCatalog ? .folderCatalog : legacy)
            let poison = try wrong.frame(150, Data(), mode: .routedFolderCatalog)
            XCTAssertThrowsError(try old.consume(poison))
        }
    }
    func testEarlyCompletionWrongOrdinalOffsetAndSizePoisonTheChannel() throws {
        for variant in 0..<5 {
            var wire = FolderWire(), decoder = try wire.ready(); let prepared = try wire.prepare(&decoder), request = prepared.selection.request
            try decoder.receiveFolder(prepared); _ = try decoder.consume(wire.frame(154, SFTPWire.token(request)))
            if variant == 0 { XCTAssertThrowsError(try decoder.consume(wire.frame(158, wire.completed(request)))) }
            else if variant == 1 { XCTAssertThrowsError(try decoder.consume(wire.frame(155, wire.member(request, ordinal: 4)))) }
            else {
                _ = try decoder.consume(wire.frame(155, wire.member(request, ordinal: 3)))
                XCTAssertThrowsError(try decoder.consume(wire.frame(156, wire.member(variant == 2 ? UUID() : request, ordinal: 3,
                    offset: variant == 3 ? 1 : 0, bytes: Data(repeating: 7, count: variant == 4 ? 8 : 1)))))
            }
            XCTAssertThrowsError(try decoder.consume(wire.frame(158, wire.completed(request))))
        }
    }
    func testEmptyRootStillNeedsExplicitReceiveAndAcknowledgedCompletion() throws {
        for ack: UInt8 in [0, 1, 2] {
            var wire = FolderWire(), decoder = try wire.ready(); let prepared = try wire.prepare(&decoder, manifest: FolderFixture.manifest(empty: true))
            try decoder.receiveFolder(prepared); _ = try decoder.consume(wire.frame(154, SFTPWire.token(prepared.selection.request)))
            let frame = try wire.frame(158, wire.completed(prepared.selection.request, bytes: 0, files: 0, ack: ack))
            if ack == 1 { XCTAssertNoThrow(try decoder.consume(frame)) } else { XCTAssertThrowsError(try decoder.consume(frame)) }
        }
    }
    func testUnsolicitedAndTrailingEventsRefuseRatherThanBecomeProgress() throws {
        var wire = FolderWire(), decoder = try wire.ready(); XCTAssertThrowsError(try decoder.consume(wire.frame(154, SFTPWire.token(UUID()))))
        var other = FolderWire(), value = try other.ready(); let prepared = try other.prepare(&value)
        try value.releaseFolder(prepared.selection.request)
        XCTAssertThrowsError(try value.consume(other.frame(159, SFTPWire.token(prepared.selection.request) + Data([0]))))
    }
}
