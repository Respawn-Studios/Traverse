import Foundation

internal enum RelatedNameVectors {
    static func normalized(_ values: [Double], dimension: Int) throws -> [Double] {
        guard values.count == dimension, values.allSatisfy(\.isFinite),
              let scale = values.map({ abs($0) }).max(), scale > 0 else { throw RelatedNameFailure.invalidVector }
        // Scaling first handles finite components near Double's overflow range.
        let scaled = values.map { $0 / scale }
        let length = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
        guard length.isFinite, length > 0 else { throw RelatedNameFailure.invalidVector }
        return scaled.map { $0 / length }
    }
    struct Entry: Sendable {
        let id: RememberedItemID
        let revision: UInt64
        let field: RememberedNameField
        let ordinal: Int
        let vector: [Double]
        init(row: RelatedNameInput.Row, vector: [Double]) {
            id = row.id; revision = row.revision; field = row.field; ordinal = row.ordinal; self.vector = vector
        }
    }
    static func rank(_ entries: [Entry], query: [Double], threshold: Double,
                     cancelled: @Sendable () -> Bool) throws -> [RelatedNameCandidate] {
        var best: [RememberedItemID: RelatedNameCandidate] = [:]
        for entry in entries {
            guard !cancelled() else { throw RelatedNameFailure.stopped }
            guard entry.vector.count == query.count else { throw RelatedNameFailure.invalidVector }
            let dot = zip(entry.vector, query).reduce(0) { $0 + $1.0 * $1.1 }
            guard dot.isFinite else { throw RelatedNameFailure.invalidVector }
            let score = min(1, max(-1, dot))
            guard score >= threshold else { continue }
            let candidate = RelatedNameCandidate(id: entry.id, revision: entry.revision, field: entry.field, ordinal: entry.ordinal, score: score)
            if let old = best[entry.id], !precedes(candidate, old) { continue }
            best[entry.id] = candidate
        }
        return Array(best.values.sorted(by: precedes).prefix(5))
    }
    private static func precedes(_ a: RelatedNameCandidate, _ b: RelatedNameCandidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.id != b.id { return a.id.rawValue.uuidString < b.id.rawValue.uuidString }
        if a.field != b.field { return a.field.rawValue < b.field.rawValue }
        return a.ordinal < b.ordinal
    }
}
