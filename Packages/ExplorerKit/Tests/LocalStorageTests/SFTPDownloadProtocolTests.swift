import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPDownloadProtocolTests: XCTestCase {
    private let session = UUID(), generation = UUID(), request = UUID()
    private func row(size: UInt64? = 65_537, modified: UInt32? = 19, mode: UInt32? = 0o100644,
                     observation: UInt64 = 2, name: String = "Cafe\u{301}.bin") throws -> SFTPStoredRow {
        .init(observation: observation, entry: .init(name: try SFTPRemoteName(Data(name.utf8)), logicalBytes: size,
            modifiedSeconds: modified, permissions: mode))
    }
    private func selection(size: UInt64 = 65_537) throws -> SFTPDownloadSelection {
        try .init(generation: generation, row: row(size: size), request: request)
    }
    private func frame(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data(), mode: SFTPWireMode = .transferCatalog) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
    }
    private func snapshot(_ count: UInt64, complete: Bool) -> Data {
        var data = Data(); for n in [1, count == 0 ? 0 : 1, count, 0] { SFTPWire.number(n, bytes: 8, into: &data) }
        data.append(complete ? 1 : 0); return data
    }
    private func opened(complete: Bool = true, mode: SFTPWireMode = .transferCatalog) throws -> SFTPWorkerDecoder {
        var value = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        var hello = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &hello); SFTPWire.number(22, bytes: 2, into: &hello)
        try SFTPWire.field(key, into: &hello); try SFTPWire.field(Data(), into: &hello)
        guard case .challenge(let challenge) = try value.consume(frame(0, 100, hello, mode: mode)) else { throw SFTPProtocolFailure.phase }
        try value.noteApproval(.connectOnce, challenge: challenge)
        _ = try value.consume(frame(1, 101, mode: mode)); _ = try value.consume(frame(2, 102, mode: mode)); _ = try value.consume(frame(3, 109, mode: mode))
        try value.beginDirectory(generation); var payload = SFTPWire.token(generation)
        try SFTPWire.field(Data("/generated".utf8), into: &payload); payload.append(snapshot(0, complete: false))
        _ = try value.consume(frame(4, 110, payload, mode: mode))
        try value.beginNext(generation); _ = try value.consume(frame(5, 111, SFTPWire.token(generation) + snapshot(2, complete: complete), mode: mode))
        return value
    }
    private func start(_ value: inout SFTPWorkerDecoder, selected: SFTPDownloadSelection? = nil, name: String? = nil) throws {
        let selection = try selected ?? self.selection(); try value.beginDownload(selection)
        _ = try value.consume(startFrame(selection, name: name))
    }
    private func startFrame(_ selection: SFTPDownloadSelection, name: String? = nil, mode: SFTPWireMode = .transferCatalog) throws -> Data {
        var data = SFTPWire.token(selection.request); data.append(SFTPWire.token(selection.generation)); SFTPWire.number(selection.row.observation, bytes: 8, into: &data)
        SFTPWire.number(selection.logicalBytes, bytes: 8, into: &data); SFTPWire.number(UInt64(selection.row.entry.modifiedSeconds!), bytes: 4, into: &data)
        SFTPWire.number(UInt64(selection.row.entry.permissions!), bytes: 4, into: &data)
        try SFTPWire.field(name.map { Data($0.utf8) } ?? selection.row.entry.name.wireUTF8, into: &data); return try frame(6, 120, data, mode: mode)
    }
    func testRegularFileCheckpointsRequireTheNewVersionAndAnExactActiveRequest() throws {
        for mode: SFTPWireMode in [.folderCatalog, .folderUploadCatalog] {
            var value = try opened(mode: mode); let selected = try selection(size: 0)
            try value.beginDownload(selected); _ = try value.consume(startFrame(selected, mode: mode))
            guard case .downloadCheckpoint(let id) = try value.consume(frame(7, 123, SFTPWire.token(request), mode: mode)) else { return XCTFail() }
            XCTAssertEqual(id, request)
            var completion = SFTPWire.token(request); SFTPWire.number(0, bytes: 8, into: &completion); completion.append(contentsOf: [1, 1])
            guard case .downloadComplete = try value.consume(frame(8, 122, completion, mode: mode)) else { return XCTFail() }
            XCTAssertThrowsError(try value.consume(frame(9, 123, SFTPWire.token(request), mode: mode)))
        }
        for variant in 0..<5 {
            let mode: SFTPWireMode = variant == 0 ? .transferCatalog : variant == 1 ? .interactiveTransferCatalog : .folderCatalog
            var value = try opened(mode: mode); let selected = try selection(size: 0)
            if variant != 2 { try value.beginDownload(selected) }
            if variant != 2 && variant != 3 { _ = try value.consume(startFrame(selected, mode: mode)) }
            let sequence: UInt64 = variant == 2 || variant == 3 ? 6 : 7
            XCTAssertThrowsError(try value.consume(frame(sequence, 123, SFTPWire.token(variant == 4 ? UUID() : request), mode: mode)))
            XCTAssertThrowsError(try value.consume(frame(sequence + 1, 123, SFTPWire.token(request), mode: mode)))
        }
    }
    private func bytes(_ sequence: UInt64, offset: UInt64, count: Int, id: UUID? = nil) throws -> Data {
        var data = SFTPWire.token(id ?? request); SFTPWire.number(offset, bytes: 8, into: &data)
        try SFTPWire.field(Data(repeating: 7, count: count), into: &data); return try frame(sequence, 121, data)
    }
    private func finish(_ sequence: UInt64, count: UInt64, ack: UInt8 = 1, shutdown: UInt8 = 1) throws -> Data {
        var data = SFTPWire.token(request); SFTPWire.number(count, bytes: 8, into: &data); data.append(contentsOf: [ack, shutdown])
        return try frame(sequence, 122, data)
    }
    func testSelectionRequiresKnownRegularBoundedObservationAndRedactsDiagnostics() throws {
        let valid = try selection(); XCTAssertEqual(valid.logicalBytes, 65_537)
        XCTAssertFalse(String(reflecting: valid).contains("Cafe")); XCTAssertEqual(valid.command().count, 40)
        XCTAssertEqual(valid.command().prefix(16), SFTPWire.token(request))
        for bad in [try row(size: nil), try row(size: 1 << 30 + 1), try row(modified: nil), try row(mode: nil),
                    try row(mode: 0o120777), try row(mode: 0o040755), try row(observation: 0), try row(observation: .max)] {
            XCTAssertThrowsError(try SFTPDownloadSelection(generation: generation, row: bad))
        }
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertThrowsError(try SFTPDownloadSelection(generation: zero, row: row()))
        XCTAssertThrowsError(try SFTPDownloadSelection(generation: generation, row: row(), request: zero))
        for name in ["Cafe\u{301}.bin", "Café.bin", "normal_name-1.txt", "literal\\name.txt", String(repeating: "a", count: 255)] {
            let value = try SFTPDownloadSelection(generation: generation, row: row(name: name))
            XCTAssertEqual(value.proposedLocalName.map { Data($0.utf8) }, Data(name.utf8))
        }
        for name in ["line\nbreak", "bidirectional\u{202e}.txt", "colon:name", String(repeating: "a", count: 256)] {
            let value = try SFTPDownloadSelection(generation: generation, row: row(name: name))
            XCTAssertNil(value.proposedLocalName); XCTAssertEqual(value.row.entry.name.wireUTF8, Data(name.utf8))
        }
    }
    func testExplicitVersionAndSealedDirectoryAreRequiredWithoutOverlappingReads() throws {
        var old = try opened(mode: .catalog), loading = try opened(complete: false), current = try opened()
        XCTAssertThrowsError(try old.beginDownload(selection())); XCTAssertThrowsError(try loading.beginDownload(selection()))
        XCTAssertThrowsError(try current.beginDownload(.init(generation: UUID(), row: row())))
        try current.beginDownload(selection())
        XCTAssertThrowsError(try current.beginDownload(selection())); XCTAssertThrowsError(try current.beginDirectory(UUID()))
        XCTAssertThrowsError(try current.beginNext(generation))
        XCTAssertThrowsError(try current.beginPage(UUID(), generation: generation, snapshot: .init(read: 1, revision: 1, count: 2, folders: 0, state: .complete), offset: 0, limit: 1))
        XCTAssertThrowsError(try old.consume(frame(6, 120)))
    }
    func testByteExactChunksAndAcknowledgedCompletionAllowBrowsingAgain() throws {
        var value = try opened(); try start(&value)
        var offset: UInt64 = 0
        for (index, count) in [32_768, 32_768, 1].enumerated() {
            guard case .downloadBytes(let id, let at, let data) = try value.consume(bytes(UInt64(index + 7), offset: offset, count: count)) else { return XCTFail() }
            XCTAssertEqual(id, request); XCTAssertEqual(at, offset); XCTAssertEqual(data.count, count); offset += UInt64(count)
            XCTAssertFalse(String(reflecting: SFTPWorkerEvent.downloadBytes(id, at, data)).contains("65537"))
        }
        guard case .downloadComplete(let receipt) = try value.consume(finish(10, count: offset)) else { return XCTFail() }
        XCTAssertEqual(receipt.receivedBytes, 65_537); XCTAssertEqual(receipt.selection, try selection())
        XCTAssertNoThrow(try value.beginDirectory(UUID()))
    }
    func testWrongRequestOffsetsOversizeAndExtraDataPoisonTheTransfer() throws {
        for bad in [try bytes(7, offset: 0, count: 1, id: UUID()), try bytes(7, offset: 1, count: 1),
                    try bytes(7, offset: 0, count: 0), try bytes(7, offset: 0, count: 32_769)] {
            var value = try opened(); try start(&value); XCTAssertThrowsError(try value.consume(bad)); XCTAssertThrowsError(try value.consume(bytes(7, offset: 0, count: 1)))
        }
        var value = try opened(); try start(&value, selected: selection(size: 1))
        XCTAssertThrowsError(try value.consume(bytes(7, offset: 0, count: 2)))
        var unsolicited = try opened(); XCTAssertThrowsError(try unsolicited.consume(bytes(6, offset: 0, count: 1)))
    }
    func testCompletionCannotPrecedeAllBytesOrMissingCloseAndShutdownEvidence() throws {
        var early = try opened(); try start(&early); XCTAssertThrowsError(try early.consume(finish(7, count: 65_537)))
        for bad in [try finish(7, count: 0, ack: 0), try finish(7, count: 0, shutdown: 0), try finish(7, count: 0, ack: 2)] {
            var value = try opened(); try start(&value, selected: selection(size: 0)); XCTAssertThrowsError(try value.consume(bad))
        }
    }
    func testZeroLengthFileStillNeedsStartAndAcknowledgment() throws {
        var value = try opened(); try start(&value, selected: selection(size: 0))
        guard case .downloadComplete(let receipt) = try value.consume(finish(7, count: 0)) else { return XCTFail() }
        XCTAssertEqual(receipt.receivedBytes, 0)
        var noStart = try opened(); try noStart.beginDownload(selection(size: 0)); XCTAssertThrowsError(try noStart.consume(finish(6, count: 0)))
    }
    func testCanonicalEquivalentButByteDifferentNameIsNotTheRequestedSelection() throws {
        var value = try opened(); try value.beginDownload(selection())
        XCTAssertThrowsError(try value.consume(startFrame(selection(), name: "Café.bin")))
    }
    func testChangedSourceTerminalDiscardsPendingBodyAndRequiresNewSession() throws {
        var value = try opened(); try start(&value); _ = try value.consume(bytes(7, offset: 0, count: 1))
        var terminal = Data([10, 1, 1]); SFTPWire.number(0, bytes: 8, into: &terminal); SFTPWire.number(0, bytes: 8, into: &terminal); terminal.append(1)
        guard case .closed(let ended) = try value.consume(frame(8, 107, terminal)) else { return XCTFail() }
        XCTAssertEqual(ended.outcome, 10); XCTAssertEqual(ended.catalogWriterEnd, .closed); XCTAssertThrowsError(try value.consume(finish(9, count: 65_537)))
        var old = try opened(mode: .catalog); XCTAssertThrowsError(try old.consume(frame(6, 107, terminal, mode: .catalog)))
    }
}
