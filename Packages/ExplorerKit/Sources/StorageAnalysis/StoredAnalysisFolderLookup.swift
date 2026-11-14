import Foundation

extension StorageAnalysisResult {
    /// Reads a descendant's existing rollup through bounded catalog pages.
    /// Names are byte-exact; symlinks are never traversed. This reads no source
    /// directory or file body. A miss or exhausted hover budget is not a zero.
    func recordedFolderValue(relativeComponents: [Data]) async throws -> StoredAnalysisValue? {
        guard !relativeComponents.isEmpty, relativeComponents.count <= 64,
              relativeComponents.allSatisfy(StoredAnalysisPage.validName),
              relativeComponents.reduce(0, { $0 + $1.count + 1 }) <= 8192 else { return nil }
        let deadline = ContinuousClock.now + .seconds(2)
        var parent: UInt64 = 0, pagesRemaining = 32
        var visited = Set<UInt64>()
        for (index, component) in relativeComponents.enumerated() {
            var cursor: UInt64 = 0
            var found: StoredAnalysisRow?
            while found == nil {
                try Task.checkCancellation()
                guard pagesRemaining > 0, ContinuousClock.now < deadline else { return nil }
                pagesRemaining -= 1
                let rows = try await page(parent: parent, after: cursor)
                guard ContinuousClock.now < deadline else { return nil }
                if let match = rows.first(where: { $0.rawName == component }) {
                    guard match.kind == .directory, visited.insert(match.id).inserted else { return nil }
                    found = match
                } else {
                    guard rows.count == 256, let next = rows.last?.id, next != cursor else { return nil }
                    cursor = next
                }
            }
            guard let found else { return nil }
            parent = found.id
            if index == relativeComponents.count - 1 {
                try Task.checkCancellation()
                return found.value
            }
        }
        return nil
    }
}
