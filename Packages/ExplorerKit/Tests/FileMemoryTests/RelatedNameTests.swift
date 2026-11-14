import Foundation
import Testing
@testable import FileMemory

@Suite struct RelatedNameTests {
    private func item(_ number: Int, nickname: String, labels: [String] = []) throws -> RememberedNamesSnapshot {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        return .init(id: RememberedItemID(id), revision: 1, names: try AuthoredNames(nickname: nickname, labels: labels))
    }
    private func input() throws -> RelatedNameInput {
        try .init(items: [item(2, nickname: "east", labels: ["same east"]), item(1, nickname: "north")], scope: UUID(), epoch: 3)
    }
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var closes = 0
        private var entered = false
        private let pause = DispatchSemaphore(value: 0)
        var shouldPause = false // Set once before worker construction.
        func call() { lock.withLock { count += 1 }; if shouldPause && calls == 1 { lock.withLock { entered = true }; pause.wait() } }
        func close() { lock.withLock { closes += 1 } }
        var calls: Int { lock.withLock { count } }
        var closed: Int { lock.withLock { closes } }
        var waiting: Bool { lock.withLock { entered } }
        func release() { pause.signal() }
    }
    private final class Encoder: RelatedNameEncoder {
        let model = try! RelatedNameModel(identifier: "generated-unit-v1", revision: 1, language: "en", dimension: 2, maximumSequenceLength: 32)
        let probe: Probe
        let invalid: Bool
        init(_ probe: Probe, invalid: Bool = false) { self.probe = probe; self.invalid = invalid }
        func vector(for text: String, cancelled: @Sendable () -> Bool) throws -> [Double] {
            probe.call(); if cancelled() { throw RelatedNameFailure.stopped }
            if invalid { return [Double.nan, 0] }
            return text.contains("east") ? [1, 0] : [0, 1]
        }
        func close() { probe.close() }
    }
    @Test func typedProjectionLimitsAndNoImplicitFilename() throws {
        let snapshot = try item(1, nickname: "A deliberate name", labels: ["local"])
        let admitted = try RelatedNameInput(items: [snapshot], scope: UUID(), epoch: 1)
        #expect(admitted.rows.map(\.text) == ["A deliberate name", "local"])
        #expect(admitted.rows.map(\.field) == [.nickname, .label])
        #expect(throws: RelatedNameFailure.limited) { try RelatedNameInput(items: [snapshot, snapshot], scope: UUID(), epoch: 1) }
        #expect(throws: RelatedNameFailure.limited) { try RelatedNameInput(items: [item(2, nickname: String(repeating: "x", count: 129))], scope: UUID(), epoch: 1) }
        let many = try (1...513).map { try item($0, nickname: "Authored \($0)") }
        #expect(throws: RelatedNameFailure.limited) { try RelatedNameInput(items: many, scope: UUID(), epoch: 1) }
        #expect(throws: RelatedNameFailure.invalidInput) { try RelatedNameQuery("\n", threshold: 0.8) }
        #expect(throws: RelatedNameFailure.invalidInput) { try RelatedNameQuery("name", threshold: .nan) }
        #expect(throws: RelatedNameFailure.unsupported) { try RelatedNameModel(identifier: "wrong", revision: 1, language: "en", dimension: 2049, maximumSequenceLength: 256) }
    }
    @Test func vectorArithmeticRejectsInvalidAndHandlesLargeFiniteValues() throws {
        #expect(try RelatedNameVectors.normalized([3, 4], dimension: 2) == [0.6, 0.8])
        let large = try RelatedNameVectors.normalized([Double.greatestFiniteMagnitude, 0], dimension: 2)
        #expect(large == [1, 0])
        for vector in [[0.0, 0], [.infinity, 1], [.nan, 1], [1]] {
            #expect(throws: RelatedNameFailure.invalidVector) { try RelatedNameVectors.normalized(vector, dimension: 2) }
        }
        let rows = try input().rows
        let entries = rows.map { RelatedNameVectors.Entry(row: $0, vector: [1, 0]) }
        let ranked = try RelatedNameVectors.rank(entries, query: [1, 0], threshold: 0.8, cancelled: { false })
        #expect(ranked.count == 2 && ranked[0].id.rawValue.uuidString.hasSuffix("000000000001"))
        #expect(ranked[1].field == .nickname) // Equal-score provenance is stable.
        #expect(try RelatedNameVectors.rank(entries, query: [-1, 0], threshold: 0, cancelled: { false }).isEmpty)
    }
    @Test func resultsAreRevocableAndWarmQueriesUseNoLabelReencoding() async throws {
        let probe = Probe(), session = RelatedNameSession(input: try input()) { _ in Encoder(probe) }
        let first = try await session.query(.init("east", threshold: 0.8))
        var values: [RelatedNameCandidate] = []
        #expect(first.publish { values = $0 }); #expect(values.count == 1 && values[0].field == .nickname)
        #expect(first.observedRows == 3 && first.epoch == 3 && probe.calls == 4)
        let second = try await session.query(.init("north", threshold: 0.8))
        #expect(!first.publish { _ in Issue.record("Old query published") })
        #expect(second.publish { values = $0 }); #expect(values.count == 1 && probe.calls == 5)
        session.withdraw(); #expect(!second.publish { _ in Issue.record("Withdrawn query published") })
        await session.drain(); #expect(probe.closed == 1)
        await #expect(throws: RelatedNameFailure.stopped) { try await session.query(.init("east", threshold: 0.8)) }
    }
    @Test func encoderFailureIsTypedAndDoesNotSilentlyRetry() async throws {
        let probe = Probe(), session = RelatedNameSession(input: try input()) { _ in Encoder(probe, invalid: true) }
        await #expect(throws: RelatedNameFailure.invalidVector) { try await session.query(.init("east", threshold: 0.8)) }
        await #expect(throws: RelatedNameFailure.invalidVector) { try await session.query(.init("east", threshold: 0.8)) }
        #expect(probe.calls == 1 && probe.closed == 1); session.withdraw(); await session.drain()
    }
    @Test func actualBlockedOwnerDrainsAfterImmediateWithdrawal() async throws {
        let probe = Probe(); probe.shouldPause = true
        let session = RelatedNameSession(input: try input()) { _ in Encoder(probe) }
        let task = Task { try await session.query(.init("east", threshold: 0.8)) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !probe.waiting && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        #expect(probe.waiting); session.withdraw()
        let drainState = Probe()
        let drain = Task { await session.drain(); drainState.close() }
        await Task.yield(); #expect(drainState.closed == 0 && probe.closed == 0)
        probe.release(); await #expect(throws: RelatedNameFailure.stopped) { try await task.value }
        await drain.value; #expect(probe.closed == 1 && drainState.closed == 1)
    }
    @Test func latestPendingAndOneHundredRevocationRaces() async throws {
        for _ in 0..<100 {
            let probe = Probe(); probe.shouldPause = true
            let session = RelatedNameSession(input: try input()) { _ in Encoder(probe) }
            let first = Task { try await session.query(.init("east", threshold: 0.8)) }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !probe.waiting && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
            #expect(probe.waiting)
            let next = Task { try await session.query(.init("north", threshold: 0.8)) }
            session.withdraw(); probe.release()
            await #expect(throws: RelatedNameFailure.stopped) { try await first.value }
            await #expect(throws: RelatedNameFailure.stopped) { try await next.value }
            await session.drain(); #expect(probe.closed == 1)
        }
    }
    @Test func cancelledBeforeAdmissionDoesNotConstructEncoder() async throws {
        let probe = Probe(), session = RelatedNameSession(input: try input()) { _ in Encoder(probe) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.query(.init("east", threshold: 0.8))
        }
        await #expect(throws: RelatedNameFailure.stopped) { try await task.value }
        session.withdraw(); await session.drain(); #expect(probe.calls == 0 && probe.closed == 0)
    }
    @Test func directSearchRemainsIndependentOfBlockedOptionalWork() async throws {
        let direct = try SessionNameIndex()
        let edit = try await direct.prepareNew(AuthoredNames(nickname: "east")), id = try await direct.apply(edit)
        let probe = Probe(); probe.shouldPause = true
        let session = RelatedNameSession(input: try input()) { _ in Encoder(probe) }
        let delayed = Task { try await session.query(.init("east", threshold: 0.8)) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !probe.waiting && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        #expect(probe.waiting)
        let page = try await direct.query(RememberedNameQuery(text: "east"))
        #expect(page.matches.map(\.item.id) == [id] && probe.closed == 0)
        session.withdraw(); probe.release()
        await #expect(throws: RelatedNameFailure.stopped) { try await delayed.value }
        await session.drain(); await direct.close()
    }
}
