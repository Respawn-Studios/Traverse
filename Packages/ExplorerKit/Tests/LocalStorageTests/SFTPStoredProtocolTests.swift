import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPStoredProtocolTests: XCTestCase {
    private let session = UUID(), generation = UUID(), request = UUID()
    private func body(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data()) throws -> Data {
        var data = try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: .catalog); data.append(payload); return data
    }
    private func summary(_ count: UInt64 = 0, revision: UInt64 = 0, state: UInt8 = 0, folders: UInt64 = 0) -> Data {
        var data = Data(); for value in [1, revision, count, folders] { SFTPWire.number(value, bytes: 8, into: &data) }; data.append(state); return data
    }
    private func ready() throws -> SFTPWorkerDecoder {
        var value = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: .catalog)
        var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        var data = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &data); SFTPWire.number(22, bytes: 2, into: &data)
        try SFTPWire.field(key, into: &data); try SFTPWire.field(Data(), into: &data)
        guard case .challenge(let challenge) = try value.consume(body(0, 100, data)) else { throw SFTPProtocolFailure.phase }
        try value.noteApproval(.connectOnce, challenge: challenge)
        _ = try value.consume(body(1, 101)); _ = try value.consume(body(2, 102)); _ = try value.consume(body(3, 109)); return value
    }
    private func opened() throws -> SFTPWorkerDecoder {
        var value = try ready(); try value.beginDirectory(generation)
        var data = SFTPWire.token(generation); try SFTPWire.field(Data("/generated".utf8), into: &data); data.append(summary())
        _ = try value.consume(body(4, 110, data)); return value
    }
    private func observed(_ count: UInt64) throws -> (SFTPWorkerDecoder, SFTPStoredSnapshot) {
        var value = try opened(); try value.beginNext(generation)
        var data = SFTPWire.token(generation); data.append(summary(count, revision: 1))
        guard case .storedProgress(_, let snapshot) = try value.consume(body(5, 111, data)) else { throw SFTPProtocolFailure.phase }
        return (value, snapshot)
    }
    private func begin(_ value: inout SFTPWorkerDecoder, _ snapshot: SFTPStoredSnapshot) throws {
        try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 256)
        var data = SFTPWire.token(request); data.append(SFTPWire.token(generation)); data.append(summary(snapshot.count, revision: snapshot.revision))
        SFTPWire.number(0, bytes: 8, into: &data); _ = try value.consume(body(6, 114, data))
    }
    private func row(_ sequence: UInt64, _ name: String, observation: UInt64 = 1, flags: UInt8 = 1, size: UInt64 = .max, find: UUID? = nil) throws -> Data {
        var data = SFTPWire.token(request); if let find { data.append(SFTPWire.token(find)) }
        SFTPWire.number(observation, bytes: 8, into: &data); data.append(flags)
        SFTPWire.number(size, bytes: 8, into: &data); SFTPWire.number(0, bytes: 4, into: &data); SFTPWire.number(0, bytes: 4, into: &data)
        try SFTPWire.field(Data(name.utf8), into: &data); return try body(sequence, find == nil ? 115 : 175, data)
    }
    private func commit(_ sequence: UInt64, _ count: UInt64) throws -> Data {
        var data = SFTPWire.token(request); SFTPWire.number(count, bytes: 4, into: &data); return try body(sequence, 116, data)
    }
    func testPagedVersionRefusesBatchFramesInBothDirections() throws {
        var value = try ready(), other = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22)
        XCTAssertThrowsError(try value.consume(SFTPWire.body(session: session, sequence: 4, kind: 107)))
        XCTAssertThrowsError(try other.consume(body(0, 107)))
    }
    func testPagePublishesOnlyOnExactCommitWithFullUnsignedAndUnknownMetadata() throws {
        var (value, snapshot) = try observed(3); try begin(&value, snapshot)
        XCTAssertNil(try value.consume(row(7, "é"))); XCTAssertNil(try value.consume(row(8, "e\u{301}", observation: 2, flags: 0, size: 0)))
        XCTAssertNil(try value.consume(row(9, "back\\slash\n", observation: 3)))
        guard case .storedPage(let page) = try value.consume(commit(10, 3)) else { return XCTFail() }
        XCTAssertEqual(page.rows.count, 3); XCTAssertEqual(page.snapshot, snapshot); XCTAssertEqual(page.rows[0].entry.logicalBytes, .max)
        XCTAssertNil(page.rows[1].entry.logicalBytes); XCTAssertNil(page.rows[1].entry.isDirectory)
        XCTAssertNotEqual(page.rows[0].entry.name, page.rows[1].entry.name)
        XCTAssertEqual(page.rows[2].entry.name.displayName, "back\\\\slash\\u{a}")
        XCTAssertFalse(String(reflecting: SFTPWorkerEvent.storedPage(page)).contains("back"))
    }
    func testStaleAndUnsolicitedPageAuthorityNeverPublishesRows() throws {
        var (value, snapshot) = try observed(1)
        XCTAssertThrowsError(try value.beginPage(request, generation: UUID(), snapshot: snapshot, offset: 0, limit: 256))
        for limit in [0, 257] { XCTAssertThrowsError(try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: limit)) }
        XCTAssertThrowsError(try value.beginPage(request, generation: generation, snapshot: snapshot, offset: .max, limit: 1))
        try begin(&value, snapshot); var wrong = try row(7, "generated"); wrong[33] ^= 1
        XCTAssertThrowsError(try value.consume(wrong)); XCTAssertThrowsError(try value.consume(row(7, "generated")))
    }
    func testDuplicatesAndTruncatedCommitRefuseTheWholePage() throws {
        for duplicateObservation in [true, false] {
            var (value, snapshot) = try observed(2); try begin(&value, snapshot)
            _ = try value.consume(row(7, "first"))
            XCTAssertThrowsError(try value.consume(row(8, duplicateObservation ? "second" : "first", observation: duplicateObservation ? 1 : 2)))
        }
        var (value, snapshot) = try observed(2); try begin(&value, snapshot); _ = try value.consume(row(7, "first"))
        XCTAssertThrowsError(try value.consume(commit(8, 1)))
    }
    func testWorstCase256NamesRemainBoundedAndExact() throws {
        var (value, snapshot) = try observed(256); try begin(&value, snapshot)
        for n in 0..<256 { XCTAssertNil(try value.consume(row(UInt64(n + 7), String(repeating: "x", count: 8100) + String(n), observation: UInt64(n + 1)))) }
        guard case .storedPage(let page) = try value.consume(commit(263, 256)) else { return XCTFail() }
        XCTAssertEqual(page.rows.count, 256); XCTAssertLessThan(page.rows.reduce(0) { $0 + $1.entry.name.wireUTF8.count }, 3 << 20)
    }
    func testImpossibleProgressAndFalseCompletionAreRefused() throws {
        for data in [summary(1025, revision: 1), summary(1, revision: 0), summary(1, revision: 1, state: 2), summary(.max, revision: 1)] {
            var value = try opened(); try value.beginNext(generation)
            XCTAssertThrowsError(try value.consume(body(5, 111, SFTPWire.token(generation) + data)))
        }
    }
    func testStaleReplyClearsOnlyThatQueryAndCanBeRetried() throws {
        var (value, snapshot) = try observed(1)
        try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 256)
        guard case .stalePage(let actual) = try value.consume(body(6, 117, SFTPWire.token(request))) else { return XCTFail() }
        XCTAssertEqual(actual, request); XCTAssertNoThrow(try value.beginNext(generation))
    }
    func testFindCountsTheOriginalSnapshotAndFilteredPagesKeepExactObservationIDs() throws {
        var (value, snapshot) = try observed(768)
        let query = try RemoteDirectoryFindQuery(text: "Needle%_")
        try value.beginFind(query, generation: generation, snapshot: snapshot)
        var found = SFTPWire.token(query.id); found.append(SFTPWire.token(generation)); found.append(summary(768, revision: 1))
        SFTPWire.number(2, bytes: 8, into: &found); SFTPWire.number(0, bytes: 8, into: &found)
        guard case .found(let result) = try value.consume(body(6, 118, found)) else { return XCTFail() }
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result.snapshot.count, 768)
        XCTAssertFalse(String(reflecting: result).contains(query.text))
        try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 256, find: result)
        var start = SFTPWire.token(request); start.append(SFTPWire.token(query.id)); start.append(SFTPWire.token(generation))
        start.append(summary(768, revision: 1)); SFTPWire.number(0, bytes: 8, into: &start)
        SFTPWire.number(2, bytes: 8, into: &start); SFTPWire.number(0, bytes: 8, into: &start)
        XCTAssertNil(try value.consume(body(7, 174, start)))
        XCTAssertNil(try value.consume(row(8, "Needle%_", observation: 258, find: query.id)))
        XCTAssertNil(try value.consume(row(9, "UnloadedNeedle%_", observation: 701, find: query.id)))
        var end = SFTPWire.token(request); end.append(SFTPWire.token(query.id)); SFTPWire.number(2, bytes: 4, into: &end)
        guard case .storedPage(let page) = try value.consume(body(10, 176, end)) else { return XCTFail() }
        var cache = SFTPDirectoryPageCache(); cache.observe(generation, snapshot: snapshot); try cache.setFindResult(result)
        try cache.accept(page, sort: .name, descending: false)
        XCTAssertEqual(cache.displayCount, 2); XCTAssertEqual(cache.snapshot?.count, 768)
        XCTAssertEqual(cache.entry(at: 1)?.observation, 701)
        try cache.setFindResult(nil); XCTAssertEqual(cache.retainedCount, 0)
        XCTAssertThrowsError(try cache.accept(page, sort: .name, descending: false))
    }
    func testBoundedFindRefusalLeavesTheAuthenticatedDecoderUsable() throws {
        var (value, snapshot) = try observed(1)
        let query = try RemoteDirectoryFindQuery(text: "Generated")
        try value.beginFind(query, generation: generation, snapshot: snapshot)
        guard case .findUnavailable(let id) = try value.consume(body(6, 124, SFTPWire.token(query.id) + Data([1]))) else { return XCTFail() }
        XCTAssertEqual(id, query.id)
        XCTAssertNoThrow(try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 256))
        let sameID = UUID()
        XCTAssertNotEqual(try RemoteDirectoryFindQuery(id: sameID, text: "Café"), try RemoteDirectoryFindQuery(id: sameID, text: "Cafe\u{301}"))
        XCTAssertThrowsError(try RemoteDirectoryFindQuery(text: String(repeating: "x", count: 2049)))
    }
    func testFolderSizeOnMetadataOnlySessionKeepsSelectionBindingAndDoesNotEnableTransfers() throws {
        var value = try opened(); try value.beginNext(generation)
        let sealed = summary(1, revision: 1, state: 1, folders: 1)
        guard case .storedProgress(_, let snapshot) = try value.consume(body(5, 111, SFTPWire.token(generation) + sealed)) else { return XCTFail() }
        let row = SFTPStoredRow(observation: 1, entry: .init(name: try .init(Data("Folder".utf8)), logicalBytes: nil, modifiedSeconds: 0, permissions: 0o040755))
        let selected = try SFTPFolderSizeSelection(generation: generation, snapshot: snapshot, row: row)
        try value.beginFolderSize(selected)
        XCTAssertThrowsError(try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 1))
        var result = SFTPWire.token(selected.request); result.append(SFTPWire.token(generation)); result.append(sealed)
        SFTPWire.number(row.observation, bytes: 8, into: &result)
        SFTPWire.number(8 << 30, bytes: 8, into: &result)
        for count in [UInt64(2_049), 1, 1] { SFTPWire.number(count, bytes: 4, into: &result) }
        guard case .folderSize(selected.request, let measured) = try value.consume(body(6, 220, result)) else { return XCTFail() }
        XCTAssertEqual(measured.logicalBytes, 8 << 30); XCTAssertEqual(measured.files, 2_049); XCTAssertEqual(measured.excludedLinks, 1)
        XCTAssertFalse(String(reflecting: selected).contains("Folder")); XCTAssertFalse(String(reflecting: measured).contains("8589934592"))
        XCTAssertNoThrow(try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 1))
        XCTAssertThrowsError(try RemoteFolderSizeSummary(logicalBytes: 1, files: 0, folders: 0, excludedLinks: 0))
        XCTAssertNoThrow(try RemoteFolderSizeSummary(logicalBytes: 0, files: 0, folders: 32_767, excludedLinks: 0))
        XCTAssertThrowsError(try RemoteFolderSizeSummary(logicalBytes: 0, files: 0, folders: 32_767, excludedLinks: 1))
    }
    func testAcknowledgedFolderSizeRefusalsKeepTheAuthenticatedSessionUsable() throws {
        var value = try opened(); try value.beginNext(generation)
        let sealed = summary(1, revision: 1, state: 1, folders: 1)
        guard case .storedProgress(_, let snapshot) = try value.consume(body(5, 111, SFTPWire.token(generation) + sealed)) else { return XCTFail() }
        let row = SFTPStoredRow(observation: 1, entry: .init(name: try .init(Data("Folder".utf8)), logicalBytes: nil, modifiedSeconds: 0, permissions: 0o040755))
        for code in UInt8(1)...7 {
            let selected = try SFTPFolderSizeSelection(generation: generation, snapshot: snapshot, row: row)
            try value.beginFolderSize(selected)
            guard case .folderSizeUnavailable(selected.request, let failure) = try value.consume(body(UInt64(code) + 5, 221, SFTPWire.token(selected.request) + Data([code]))) else { return XCTFail() }
            XCTAssertEqual(failure, RemoteFolderSizeFailure(wireReason: code))
        }
        XCTAssertNoThrow(try value.beginPage(request, generation: generation, snapshot: snapshot, offset: 0, limit: 1))
    }
    func testTerminalDiscardsPendingPageAndRequiresWriterStatus() throws {
        var (value, snapshot) = try observed(1); try begin(&value, snapshot); _ = try value.consume(row(7, "pending"))
        var data = Data([0, 1, 1]); SFTPWire.number(0, bytes: 8, into: &data); SFTPWire.number(0, bytes: 8, into: &data)
        var truncated = value; XCTAssertThrowsError(try truncated.consume(body(8, 107, data)))
        data.append(1)
        guard case .closed(let terminal) = try value.consume(body(8, 107, data)) else { return XCTFail() }
        XCTAssertEqual(terminal.catalogWriterEnd, .closed); XCTAssertTrue(terminal.runtimeDisposed)
        XCTAssertThrowsError(try value.consume(commit(9, 1)))
    }
}
