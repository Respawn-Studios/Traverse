import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBDirectoryPageDemandTests: XCTestCase {
    private let read = UUID()
    private func key(_ offset: Int64 = 0, revision: UInt64 = 1) throws -> SMBDirectoryPageDemand.Key {
        try .init(snapshot: .init(readID: read, revision: revision, count: 50000, folders: 16, state: .loading), offset: offset, sort: .name, descending: false)
    }
    func testRepeatedRedrawsIssueOnlyOneRequestForTheSameMissingPage() throws {
        var demand = SMBDirectoryPageDemand(); let page = try key()
        demand.request(page, alreadyCached: false); XCTAssertEqual(demand.take(), page)
        for _ in 0..<100 { demand.request(page, alreadyCached: false) }
        XCTAssertNil(demand.take()); XCTAssertFalse(demand.hasQueued)
        demand.finish(page); XCTAssertNil(demand.take())
        demand.request(page, alreadyCached: true); XCTAssertNil(demand.take())
    }
    func testFastScrollRetainsOnlyLatestDemandAndWaitsForActualCompletion() throws {
        var demand = SMBDirectoryPageDemand(); let first = try key()
        demand.request(first, alreadyCached: false); XCTAssertEqual(demand.take(), first)
        for offset: Int64 in [256, 512, 768] { demand.request(try key(offset), alreadyCached: false) }
        XCTAssertNil(demand.take()); demand.finish(first)
        XCTAssertEqual(demand.take(), try key(768)); XCTAssertFalse(demand.hasQueued)
    }
    func testNewRevisionAndClearNeverReviveRetiredWork() throws {
        var demand = SMBDirectoryPageDemand(); let first = try key(), next = try key(revision: 2)
        demand.request(first, alreadyCached: false); XCTAssertEqual(demand.take(), first)
        demand.request(next, alreadyCached: false); demand.clear(); demand.finish(first)
        XCTAssertNil(demand.take()); demand.request(next, alreadyCached: false); XCTAssertEqual(demand.take(), next)
        XCTAssertThrowsError(try key(-1))
    }
}
