import Foundation
import Testing
@testable import ExplorerCore

@Test func visitHistoryIsBoundedExpiresAndRejectsForgedRecords() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let policy = DirectoryVisitPolicy(maximumEntries: 10, retentionDays: 30)
    var history = DirectoryVisitHistory()
    for i in 0..<25 { history.record(URL(fileURLWithPath: "/Generated/\(i)"), policy: policy, now: now.addingTimeInterval(Double(i))) }
    #expect(history.visits.count == 10)
    let recent = URL(fileURLWithPath: "/Generated/24")
    history.record(recent, policy: policy, now: now.addingTimeInterval(30))
    #expect(history.counts(policy: policy, now: now.addingTimeInterval(30))[recent.path] == 2)
    #expect(history.counts(policy: policy, now: now.addingTimeInterval(31 * 86_400)).isEmpty)
    history.record(URL(string: "https://example.com/path")!, policy: policy, now: now)
    #expect(history.visits.count == 10)
    let roundTrip = try JSONDecoder().decode(DirectoryVisitHistory.self, from: JSONEncoder().encode(history))
    try roundTrip.validate()
    #expect(roundTrip == history)
    let invalid = try JSONSerialization.data(withJSONObject: ["visits": [["path": "../relative", "count": 1, "lastVisit": 1]]])
    let forged = try JSONDecoder().decode(DirectoryVisitHistory.self, from: invalid)
    #expect(throws: AddressCompletionError.self) { try forged.validate() }
}
