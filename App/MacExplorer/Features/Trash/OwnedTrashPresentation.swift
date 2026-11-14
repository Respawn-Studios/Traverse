import Foundation

/// Display values only. An ID or path from this window never grants a file action.
struct OwnedTrashItemPresentation: Identifiable {
    let id: Int
    let originalURL: URL
    let isDirectory: Bool
    let recordedByteCount: UInt64?
    let stateTitle: String
}

struct OwnedTrashGroupPresentation: Identifiable {
    let id: UUID
    let createdAt: Date
    let entries: [OwnedTrashItemPresentation]
    let canRestore: Bool
    let canDelete: Bool
    let needsReview: Bool
    let explanation: String

    var title: String {
        if entries.count == 1 { return entries[0].originalURL.lastPathComponent }
        let parents = Set(entries.map { $0.originalURL.deletingLastPathComponent() })
        if parents.count == 1, let parent = parents.first {
            return "\(entries.count.formatted()) items from \(parent.lastPathComponent)"
        }
        return "\(entries.count.formatted()) items from multiple folders"
    }
    var recordedBytes: UInt64? {
        var total: UInt64 = 0
        for entry in entries {
            guard let size = entry.recordedByteCount else { return nil }
            let next = total.addingReportingOverflow(size)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
