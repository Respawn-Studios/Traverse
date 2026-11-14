import Foundation

/// Exact temporary-result contracts; an adaptive maximum is not an alignment.
/// No clock, filesystem or connection work enters native frame validation.
struct AnalysisCheckpointContract: Sendable {
    let rows: UInt64
    let classification: AnalysisClassificationRevision
    var adaptive: Bool { rows == 16384 }
    init(rows: UInt64, classification: AnalysisClassificationRevision) throws {
        guard [1024, 4096, 16384].contains(rows), classification == .v2 || rows != 1024,
              rows != 16384 || classification.supportsApplicationRules,
              classification != .v4 || rows == 16384 else { throw StorageScanFailure.invalidOutput }
        self.rows = rows; self.classification = classification
    }
    var progressRevision: String {
        classification == .v4 ? "committed-totals-data-v4" : adaptive ? "committed-totals-adaptive-v1" : classification == .v3 ? "committed-totals-classification-v3"
            : rows == 1024 ? "committed-totals-v1" : "committed-totals-4096-v1"
    }
    var prefixRevision: Int { classification == .v4 ? 5 : adaptive ? 4 : classification == .v3 ? 3 : rows == 1024 ? 1 : 2 }
    func acceptsSchema(_ schema: Int) -> Bool {
        classification == .v4 ? [17,18].contains(schema) : adaptive ? [15, 16].contains(schema) : (classification == .v3 ? [11, 12, 13, 14] : [9, 10]).contains(schema)
    }
    func acceptsSnapshotCount(_ count: UInt64) -> Bool {
        count > 0 && count < UInt64(Int64.max) && (adaptive ? count >= 4096 : count % rows == 0)
    }
    func acceptsProgress(_ count: UInt64, previous: UInt64, crossedSource: Bool) -> Bool {
        guard count < UInt64(Int64.max), count >= previous else { return false }
        guard adaptive else { return count % rows == 0 }
        guard count > previous else { return false }
        if previous == 0 { return count >= 4096 && count <= (crossedSource ? 4096 + rows : 4096) }
        let delta = count - previous
        // The one verified source transition may commit an unreported tail,
        // including an exact final batch. It cannot grant an arbitrary gap
        // or a reset of cumulative data.
        return delta >= 4096 && delta <= rows + (crossedSource ? rows : 0)
    }
}
