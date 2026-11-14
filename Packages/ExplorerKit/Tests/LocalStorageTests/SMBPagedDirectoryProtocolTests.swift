import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBPagedDirectoryProtocolTests: XCTestCase {
    func testFindPagesBindCountsAndObservationIdentityWithoutChangingTheOriginalSnapshot() throws {
        var decoder = SMBDirectoryCatalogDecoder(session: session, read: read)
        let state = try snapshot(&decoder, count: 768), query = try RemoteDirectoryFindQuery(text: "Needle%_")
        try decoder.request(SMBDirectoryFindRequest(query: query, snapshot: state))
        guard case .found(let result) = try decoder.consume(line(1, "find \(query.id.uuidString) \(read.uuidString) 1 768 0 0 2 0")) else { return XCTFail() }
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result.snapshot, state)
        let request = try SMBDirectoryPageRequest(snapshot: state, offset: 0, find: result)
        try decoder.request(request)
        for (index, observation) in [258, 701].enumerated() {
            XCTAssertNil(try decoder.consume(line(index + 2, "findRow \(request.token.uuidString) \(query.id.uuidString) \(observation) 0 1 0 0 0 \(index == 0 ? "0041" : "0042")")))
        }
        guard case .page(let page) = try decoder.consume(line(4, "findPage \(request.token.uuidString) \(query.id.uuidString) \(read.uuidString) 1 0 2 0 2")) else { return XCTFail() }
        var cache = SMBDirectoryPageCache(); cache.observe(state); try cache.setFindResult(result); try cache.accept(page)
        XCTAssertEqual(cache.displayCount, 2); XCTAssertEqual(cache.snapshot?.count, 768); XCTAssertEqual(cache.entry(at: 1)?.id, 701)
        try cache.setFindResult(nil); XCTAssertThrowsError(try cache.accept(page)); XCTAssertEqual(cache.retainedCount, 0)
    }
    private let session = UUID(), read = UUID()
    private func line(_ n: Int, _ payload: String) -> Data { Data("MEXSMBC1 \(session.uuidString) \(n) \(payload)".utf8) }
    private func snapshot(_ decoder: inout SMBDirectoryCatalogDecoder, revision: Int = 1, count: Int = 2) throws -> SMBDirectorySnapshot {
        let event = try decoder.consume(line(0, "snapshot \(read.uuidString) \(revision) \(count) 0 loading"))
        guard case .snapshot(let result) = event else { throw SMBDirectoryFailure.invalidOutput }; return result
    }
    func testPagePublishesOnlyAtExactTerminalAndRetainsWireIdentity() throws {
        var decoder = SMBDirectoryCatalogDecoder(session: session, read: read)
        let state = try snapshot(&decoder), request = try SMBDirectoryPageRequest(snapshot: state, offset: 0)
        try decoder.request(request)
        for (n, wire) in ["00430061006600e9", "00430061006600650301"].enumerated() {
            XCTAssertNil(try decoder.consume(line(n + 1, "row \(request.token.uuidString) \(n + 1) 0 128 0 \(wire)")))
        }
        let event = try decoder.consume(line(3, "page \(request.token.uuidString) \(read.uuidString) 1 0 2"))
        guard case .page(let page) = event else { return XCTFail() }
        XCTAssertEqual(page.entries.count, 2); XCTAssertNotEqual(page.entries[0].name, page.entries[1].name)
        XCTAssertNil(decoder.pending)
    }
    func testNewRevisionDrainsAndRejectsOldPageInsteadOfSubstitutingItsSelection() throws {
        var decoder = SMBDirectoryCatalogDecoder(session: session, read: read)
        let old = try snapshot(&decoder, count: 1), request = try SMBDirectoryPageRequest(snapshot: old, offset: 0)
        try decoder.request(request)
        _ = try decoder.consume(line(1, "snapshot \(read.uuidString) 2 2 0 loading"))
        _ = try decoder.consume(line(2, "row \(request.token.uuidString) 1 0 1 0 0041"))
        guard case .stale(let token) = try decoder.consume(line(3, "page \(request.token.uuidString) \(read.uuidString) 1 0 1")) else { return XCTFail() }
        XCTAssertEqual(token, request.token); XCTAssertThrowsError(try decoder.request(request))
    }
    func testWrongGenerationSequenceCountsAndDuplicateIdentityRefuse() throws {
        for fault in ["sequence", "token", "duplicate", "count", "wire", "closed"] {
            var decoder = SMBDirectoryCatalogDecoder(session: session, read: read)
            let state = try snapshot(&decoder), request = try SMBDirectoryPageRequest(snapshot: state, offset: 0); try decoder.request(request)
            let token = fault == "token" ? UUID() : request.token
            let row = "row \(token.uuidString) 1 0 1 0 \(fault == "wire" ? "d800" : "0041")"
            if ["sequence", "token", "wire"].contains(fault) { XCTAssertThrowsError(try decoder.consume(line(fault == "sequence" ? 2 : 1, row))); continue }
            _ = try decoder.consume(line(1, row))
            if fault == "duplicate" { XCTAssertThrowsError(try decoder.consume(line(2, row))); continue }
            if fault == "count" { XCTAssertThrowsError(try decoder.consume(line(2, "page \(token.uuidString) \(read.uuidString) 1 0 1"))); continue }
            _ = try decoder.consume(line(2, "closed stopped")); XCTAssertThrowsError(try decoder.consume(line(3, row)))
        }
    }
    func testOnlyTwoPagesAreRetainedAndRevisionChangeClearsThem() throws {
        let state = SMBDirectorySnapshot(readID: read, revision: 1, count: 100000, folders: 0, state: .complete)
        var cache = SMBDirectoryPageCache(); cache.observe(state)
        for offset in [0,256,512] {
            let request = try SMBDirectoryPageRequest(snapshot: state, offset: Int64(offset))
            let rows = try (0..<256).map { index in
                SMBDirectoryObservation(id: Int64(offset + index + 1), name: try SMBRemoteName("Generated \(offset + index)"), attributes: 0, logicalBytes: 0, modifiedFileTime: 0)
            }
            try cache.accept(SMBDirectoryPage(request: request, entries: rows))
        }
        XCTAssertEqual(cache.retainedCount, 512); XCTAssertNil(cache.entry(at: 0)); XCTAssertEqual(cache.entry(at: 512)?.id, 513)
        cache.observe(SMBDirectorySnapshot(readID: read, revision: 2, count: 100000, folders: 0, state: .complete))
        XCTAssertEqual(cache.retainedCount, 0)
        cache.clear(); XCTAssertNil(cache.snapshot)
    }
    func testQuotaClosureRetainsHonestPrefixInsteadOfInventingEmptyCompletion() throws {
        var decoder = SMBDirectoryCatalogDecoder(session: session, read: read)
        let state = try snapshot(&decoder, count: 17)
        guard case .closed(let reason) = try decoder.consume(line(1, "closed quota")) else { return XCTFail() }
        XCTAssertEqual(reason, "quota"); XCTAssertEqual(decoder.snapshot, state)
        XCTAssertEqual(decoder.snapshot?.state, .loading); XCTAssertTrue(decoder.closed)
        XCTAssertThrowsError(try decoder.consume(line(2, "snapshot \(read.uuidString) 2 0 0 complete")))
    }
}
