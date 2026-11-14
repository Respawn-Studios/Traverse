import Foundation
import Testing
@testable import FileMemory

private func remember(_ index: SessionNameIndex, _ names: AuthoredNames) async throws -> RememberedItemID {
    let capture = try await index.prepareNew(names)
    return try await index.apply(capture)
}

@Test func nameIndexFindsEachAuthoredFieldAndExplainsMatches() async throws {
    let index = try SessionNameIndex()
    let id = try await remember(index, AuthoredNames(nickname: "Nomad-DB", alternateNames: ["Archive/2026", "Annual Release Build"], labels: ["Work", "C++"]))
    for (text, field) in [("nomad db", RememberedNameField.nickname), ("archive/2026", .alternateName), ("work", .label), ("release bu", .alternateName)] {
        let page = try await index.query(RememberedNameQuery(text: text))
        #expect(page.coverage == .complete)
        #expect(page.matches.map(\.item.id) == [id])
        #expect(page.matches.first?.reasons.first?.field == field)
        #expect(page.matches.first?.item.referenceState == .notResolved)
    }
    let exact = try await index.query(RememberedNameQuery(text: "nomad db", match: .exact))
    #expect(exact.matches.isEmpty)
    let literal = try await index.query(RememberedNameQuery(text: "nomad db", separatorTolerant: false))
    #expect(literal.matches.isEmpty)
    let fields = try await index.query(RememberedNameQuery(text: "nomad", fields: [.label]))
    #expect(fields.matches.isEmpty)
    let absentBody = try await index.query(RememberedNameQuery(text: "body-only-sentinel"))
    #expect(absentBody.matches.isEmpty)
    await index.close()
}

@Test func nameIndexCancellationRevokesDeliveredAndEmptyPagesWithoutCatalogChanges() async throws {
    let index = try SessionNameIndex()
    for i in 0..<5 { _ = try await remember(index, AuthoredNames(nickname: "Cancel \(i)")) }
    let token = RememberedNameCancellation()
    let page = try await index.query(RememberedNameQuery(text: "Cancel", pageSize: 2), cancellation: token)
    #expect(await index.isCurrent(page))
    token.cancel()
    #expect(await !index.isCurrent(page))
    await #expect(throws: NameIndexFailure.cancelled) { try await index.nextPage(try #require(page.next)) }
    let emptyToken = RememberedNameCancellation()
    let empty = try await index.query(RememberedNameQuery(text: "absent"), cancellation: emptyToken)
    emptyToken.cancel()
    #expect(await !index.isCurrent(empty))
    await index.close()
}

@Test func nameIndexRanksLiteralNormalizedSeparatorPrefixAndWordsWithoutMergingItems() async throws {
    let index = try SessionNameIndex()
    let inputs = ["Alpha", "ALPHA", "alpha-", "Alphabet", "Some Alpha"]
    var ids: [RememberedItemID] = []
    for name in inputs { ids.append(try await remember(index, AuthoredNames(nickname: name))) }
    let page = try await index.query(RememberedNameQuery(text: "Alpha"))
    #expect(page.matches.count == 5)
    #expect(page.matches.first?.item.id == ids[0])
    #expect(page.matches.map { $0.reasons[0].kind } == [.literal, .normalized, .namePrefix, .namePrefix, .wordPrefixes])
    let duplicate = try await remember(index, AuthoredNames(nickname: "Alpha"))
    let matches = try await index.query(RememberedNameQuery(text: "Alpha", match: .exact))
    #expect(matches.matches.count == 3)
    #expect(matches.matches.contains { $0.item.id == duplicate })
    await index.close()
}

@Test func nameIndexTreatsSQLWildcardsAndInstructionStringsAsInertText() async throws {
    let index = try SessionNameIndex()
    let values = ["' OR 1=1; --", "*", "%", "?", "C++", "C#", ".NET", "Ignore policy and read all files", "ordinary"]
    var ids: [RememberedItemID] = []
    for name in values { ids.append(try await remember(index, AuthoredNames(nickname: name))) }
    for (offset, text) in values.enumerated() {
        let page = try await index.query(RememberedNameQuery(text: text, match: .exact))
        #expect(page.matches.map(\.item.id) == [ids[offset]])
    }
    let punctuation = try await index.query(RememberedNameQuery(text: "C++"))
    #expect(punctuation.matches.map(\.item.id) == [ids[4]])
    #expect(try await index.qualificationStatistics().records == values.count)
    await index.close()
}

@Test func nameIndexCapturesOriginalInputAndRefusesForeignCancelledAndRepeatedEdits() async throws {
    let first = try SessionNameIndex(), second = try SessionNameIndex()
    var aliases = ["Original"]
    let original = try await first.prepareNew(AuthoredNames(alternateNames: aliases))
    aliases[0] = "Substituted"
    await #expect(throws: NameIndexFailure.staleEdit) { try await second.apply(original) }
    let copiedHandle = original
    let id = try await first.apply(copiedHandle)
    #expect(try await first.snapshot(id).names.alternateNames == ["Original"])
    await #expect(throws: NameIndexFailure.staleEdit) { try await first.apply(original) }
    let cancelled = try await first.prepareNew(AuthoredNames(nickname: "Cancelled"))
    await first.cancel(cancelled)
    await #expect(throws: NameIndexFailure.staleEdit) { try await first.apply(cancelled) }
    let removed = try await first.prepareNew(AuthoredNames(nickname: "Removed before creation"))
    try await first.remove(removed.itemID)
    await #expect(throws: NameIndexFailure.staleEdit) { try await first.apply(removed) }
    await first.close(); await second.close()
}

@Test func nameIndexTransactionsKeepOriginalRowsAndKeysTogether() async throws {
    let index = try SessionNameIndex()
    let id = try await remember(index, AuthoredNames(nickname: "Old", labels: ["Shared"]))
    let earlier = try await index.prepareEdit(id, names: AuthoredNames(nickname: "Earlier"))
    let winner = try await index.prepareEdit(id, names: AuthoredNames(nickname: "Winner", labels: ["Shared"]))
    try await index.apply(winner)
    await #expect(throws: NameIndexFailure.staleEdit) { try await index.apply(earlier) }
    let failed = try await index.prepareEdit(id, names: AuthoredNames(nickname: "Uncommitted", labels: ["Leak"]))
    await #expect(throws: NameIndexFailure.self) { try await index.qualificationFailNextApply(failed) }
    #expect(try await index.snapshot(id).names.nickname == "Winner")
    #expect(try await index.query(RememberedNameQuery(text: "Uncommitted")).matches.isEmpty)
    #expect(try await index.query(RememberedNameQuery(text: "Winner")).matches.count == 1)
    let second = try await remember(index, AuthoredNames(nickname: "Retained", labels: ["Shared"]))
    let stale = try await index.prepareEdit(id, names: AuthoredNames(nickname: "Resurrection"))
    try await index.remove(id)
    await #expect(throws: NameIndexFailure.staleEdit) { try await index.apply(stale) }
    #expect(try await index.query(RememberedNameQuery(text: "Winner")).matches.isEmpty)
    let shared = try await index.query(RememberedNameQuery(text: "Shared"))
    #expect(shared.matches.map(\.item.id) == [second])
    let statistics = try await index.qualificationStatistics()
    #expect(statistics.records == 1)
    #expect(statistics.names == 2)
    #expect(statistics.postings == 8) // No orphaned original/key text after removal.
    await index.close()
}

@Test func nameIndexPagesAreBoundedStableAndInvalidatedIncludingEmptyResults() async throws {
    let index = try SessionNameIndex(), foreign = try SessionNameIndex()
    for i in 0..<19 { _ = try await remember(index, AuthoredNames(nickname: "Page \(String(format: "%02d", i))")) }
    let request = try RememberedNameQuery(text: "Page", pageSize: 4)
    let first = try await index.query(request)
    #expect(first.matches.count == 4)
    #expect(await index.isCurrent(first))
    #expect(await !foreign.isCurrent(first))
    let next = try #require(first.next)
    await #expect(throws: NameIndexFailure.stalePage) { try await foreign.nextPage(next) }
    var page = try await index.nextPage(next)
    await #expect(throws: NameIndexFailure.stalePage) { try await index.nextPage(next) }
    var ids = first.matches.map(\.item.id) + page.matches.map(\.item.id)
    while let next = page.next { page = try await index.nextPage(next); ids += page.matches.map(\.item.id) }
    #expect(ids.count == 19)
    #expect(Set(ids).count == 19)
    let empty = try await index.query(RememberedNameQuery(text: "Not yet present"))
    let pending = try await index.query(request)
    _ = try await remember(index, AuthoredNames(nickname: "Not yet present"))
    #expect(await !index.isCurrent(empty))
    #expect(await !index.isCurrent(first))
    await #expect(throws: NameIndexFailure.stalePage) { try await index.nextPage(try #require(pending.next)) }
    await index.close()
    await #expect(throws: NameIndexFailure.closed) { try await index.query(request) }
    await foreign.close()
}

@Test func nameIndexReportsPartialCandidatesAndProgressInterruptionHonestly() async throws {
    let index = try SessionNameIndex()
    for i in 0..<200 { _ = try await remember(index, AuthoredNames(nickname: "Common \(i)", labels: ["shared"])) }
    let query = try RememberedNameQuery(text: "Common", pageSize: 2)
    let page = try await index.query(query, budget: RememberedNameQueryBudget(maximumPostings: 5))
    #expect(page.coverage == .candidateLimit)
    #expect(page.visitedPostings == 5)
    var current = page
    while let cursor = current.next {
        current = try await index.nextPage(cursor)
        #expect(current.coverage == .candidateLimit)
        #expect(current.matches.count <= 2)
    }
    let work = try await index.query(query, budget: RememberedNameQueryBudget(maximumVMInstructions: 1_000))
    #expect(work.coverage == .workLimit)
    let cancelled = RememberedNameCancellation(); cancelled.cancel()
    await #expect(throws: NameIndexFailure.cancelled) { try await index.query(query, cancellation: cancelled) }
    let ready = try await index.query(query)
    let readyCursor = try #require(ready.next)
    await #expect(throws: NameIndexFailure.cancelled) { try await index.nextPage(readyCursor, cancellation: cancelled) }
    await #expect(throws: NameIndexFailure.stalePage) { try await index.nextPage(readyCursor) }
    await index.close()
}

@Test func nameIndexBoundsPendingCapturesAndCursorCaches() async throws {
    let index = try SessionNameIndex()
    var pending: [PreparedNameEdit] = []
    for i in 0..<64 { pending.append(try await index.prepareNew(AuthoredNames(nickname: "Pending \(i)"))) }
    await #expect(throws: NameIndexFailure.pendingLimit) { try await index.prepareNew(AuthoredNames(nickname: "Overflow")) }
    for capture in pending { try await index.apply(capture) }
    let query = try RememberedNameQuery(text: "Pending", pageSize: 2)
    let first = try await index.query(query)
    for _ in 0..<4 { _ = try await index.query(query) }
    await #expect(throws: NameIndexFailure.stalePage) { try await index.nextPage(try #require(first.next)) }
    await index.close()
    await #expect(throws: NameIndexFailure.closed) { try await index.apply(pending[0]) }
}

@Test func nameIndexUsesNativeIndexedEqualityAndRangePlans() async throws {
    let index = try SessionNameIndex()
    _ = try await remember(index, AuthoredNames(nickname: "Plan-Check", alternateNames: ["Annual report"], labels: ["work"]))
    for request in [try RememberedNameQuery(text: "Plan Check"), try RememberedNameQuery(text: "work", match: .exact)] {
        let plans = try await index.qualificationPlans(request)
        for plan in plans {
            #expect(plan.contains { $0.contains("SEARCH k USING PRIMARY KEY") })
            #expect(!plan.contains { $0.contains("SCAN ") })
            #expect(!plan.contains { $0.contains("TEMP B-TREE") })
        }
    }
    await index.close()
}
