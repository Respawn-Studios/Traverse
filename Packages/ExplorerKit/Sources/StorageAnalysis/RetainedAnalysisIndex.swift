import Foundation

// Pure format2 state machine. No filesystem publication/deletion is performed.
struct RetainedAnalysisIndex: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumEncodedBytes = 64 << 10
    struct PendingCleanup: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let catalog: RetainedAnalysisRecord.Catalog
        let requestedAtEpoch: String
        fileprivate init(_ catalog: RetainedAnalysisRecord.Catalog, epoch: UInt64) {
            self.catalog = catalog; requestedAtEpoch = String(epoch)
        }
        fileprivate func validate(currentEpoch: UInt64) throws {
            try catalog.validate()
            guard let value = UInt64(requestedAtEpoch), String(value) == requestedAtEpoch,
                  value > 0, value <= currentEpoch else { throw RetainedAnalysisFailure.invalid }
        }
        var description: String { "<pending analysis catalog cleanup>" }
        var debugDescription: String { description }
    }
    private struct Wire: Codable {
        let version: Int
        let epoch: String
        let records: [RetainedAnalysisRecord]
        let retiring: PendingCleanup?
        let pendingForget: [PendingCleanup]
    }
    private(set) var epoch: UInt64
    private var records: [RetainedAnalysisRecord]
    private(set) var retiring: PendingCleanup?
    private(set) var pendingForget: [PendingCleanup]
    init() { epoch = 0; records = []; retiring = nil; pendingForget = [] }
    var visibleRecords: [RetainedAnalysisRecord] { records }

    // Caller captures expectedEpoch at job admission, not after its work ends.
    // Never refresh a stale job's token to salvage a late publication.
    func publishing(_ record: RetainedAnalysisRecord, expectedEpoch: UInt64) throws -> Self {
        try requireEpoch(expectedEpoch)
        guard pendingForget.isEmpty else { throw RetainedAnalysisFailure.forgetPending }
        try record.validate()
        guard !knownCatalogIDs.contains(record.catalogID),
              !records.contains(where: { $0.scope.sameRetentionScope(as: record.scope) }) else { throw RetainedAnalysisFailure.invalid }
        guard records.count < 2 else { throw RetainedAnalysisFailure.capacity }
        var next = self; try next.bumpEpoch(); next.records.append(record); try next.validate(); return next
    }
    func replacing(_ oldCatalogID: UUID, with record: RetainedAnalysisRecord, expectedEpoch: UInt64) throws -> Self {
        try requireEpoch(expectedEpoch)
        guard pendingForget.isEmpty else { throw RetainedAnalysisFailure.forgetPending }
        guard retiring == nil else { throw RetainedAnalysisFailure.capacity }
        try record.validate()
        guard let position = records.firstIndex(where: { $0.catalogID == oldCatalogID }),
              !knownCatalogIDs.contains(record.catalogID), records[position].scope.sameRetentionScope(as: record.scope) else {
            throw RetainedAnalysisFailure.invalid
        }
        var next = self; try next.bumpEpoch()
        // One index image contains BOTH the new visible record and exact old
        // cleanup evidence. Persisting only the record would lose the old owner.
        next.retiring = PendingCleanup(records[position].catalog, epoch: next.epoch)
        next.records[position] = record; try next.validate(); return next
    }
    func beginningForget(_ ids: Set<UUID>, expectedEpoch: UInt64) throws -> Self {
        try requireEpoch(expectedEpoch)
        guard !ids.isEmpty, ids.isSubset(of: Set(records.map(\.catalogID))) else { throw RetainedAnalysisFailure.invalid }
        return try hiding(ids)
    }
    // Even an empty cache must fence in-flight publishers on Forget All.
    func beginningForgetAll(expectedEpoch: UInt64) throws -> Self {
        try requireEpoch(expectedEpoch); return try hiding(Set(records.map(\.catalogID)))
    }
    private func hiding(_ ids: Set<UUID>) throws -> Self {
        var next = self; try next.bumpEpoch()
        for record in records where ids.contains(record.catalogID) {
            next.pendingForget.append(PendingCleanup(record.catalog, epoch: next.epoch))
        }
        next.records.removeAll { ids.contains($0.catalogID) }
        // Existing retiring evidence remains hidden/known and must also drain
        // before a store can report Forget All cleanup complete.
        try next.validate(); return next
    }
    func acknowledgingRetirement(_ evidence: RetainedAnalysisRecord.Catalog, expectedEpoch: UInt64) throws -> Self {
        try requireEpoch(expectedEpoch)
        guard retiring?.catalog == evidence else { throw RetainedAnalysisFailure.invalid }
        var next = self; try next.bumpEpoch(); next.retiring = nil; try next.validate(); return next
    }
    func acknowledgingForget(_ evidence: RetainedAnalysisRecord.Catalog, expectedEpoch: UInt64) throws -> Self {
        try requireEpoch(expectedEpoch)
        guard let position = pendingForget.firstIndex(where: { $0.catalog == evidence }) else { throw RetainedAnalysisFailure.invalid }
        var next = self; try next.bumpEpoch(); next.pendingForget.remove(at: position); try next.validate(); return next
    }
    // Both acknowledgments are pure value transitions. The store may persist
    // them only after actual owned reader drain and verified deletion succeeds.
    func encoded() throws -> Data {
        try validate()
        let value = Wire(version: 2, epoch: String(epoch), records: records, retiring: retiring, pendingForget: pendingForget)
        let data = try Self.encoder().encode(value)
        guard data.count <= Self.maximumEncodedBytes else { throw RetainedAnalysisFailure.capacity }; return data
    }
    static func decodeCanonical(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else { throw RetainedAnalysisFailure.capacity }
        let value = try JSONDecoder().decode(Wire.self, from: data)
        guard value.version == 2 else { throw RetainedAnalysisFailure.unsupported }
        guard let epoch = UInt64(value.epoch), String(epoch) == value.epoch else { throw RetainedAnalysisFailure.invalid }
        var result = Self(); result.epoch = epoch; result.records = value.records
        result.retiring = value.retiring; result.pendingForget = value.pendingForget; try result.validate()
        guard try result.encoded() == data else { throw RetainedAnalysisFailure.invalid }; return result
    }
    private var knownCatalogIDs: Set<UUID> {
        Set(records.map(\.catalogID) + pendingForget.map { $0.catalog.catalogID } + (retiring.map { [$0.catalog.catalogID] } ?? []))
    }
    private func requireEpoch(_ expected: UInt64) throws {
        guard expected == epoch else { throw RetainedAnalysisFailure.stale }
    }
    private mutating func bumpEpoch() throws {
        let next = epoch.addingReportingOverflow(1)
        guard !next.overflow else { throw RetainedAnalysisFailure.overflow }; epoch = next.partialValue
    }
    private func validate() throws {
        // Forget tombstones occupy the same two normal slots they hid. One
        // additional retiring generation bounds the total known catalogs at3.
        guard records.count <= 2, records.count + pendingForget.count <= 2,
              knownCatalogIDs.count == records.count + pendingForget.count + (retiring == nil ? 0 : 1) else {
            throw RetainedAnalysisFailure.invalid
        }
        for (position, record) in records.enumerated() {
            try record.validate()
            guard !records.prefix(position).contains(where: { $0.scope.sameRetentionScope(as: record.scope) }) else {
                throw RetainedAnalysisFailure.invalid
            }
        }
        try retiring?.validate(currentEpoch: epoch)
        for value in pendingForget { try value.validate(currentEpoch: epoch) }
    }
    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return value
    }
    var description: String { "<retained analysis index>" }
    var debugDescription: String { description }
}
