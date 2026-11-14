#if DEBUG
import Foundation

/// Generated native qualification only. String encodings retain every UInt64
/// exactly across the separate-process JSON boundary without logging paths.
enum RetainedNativeQualificationSnapshot {
    private static func value(_ value: StoredAnalysisValue) -> [String: Any] {
        let counts = value.counts
        let kinds = [counts.regularFiles, counts.directories, counts.symbolicLinks,
                     counts.other, counts.unknown].map { String($0) }
        let bytes = AnalysisByteMetric.allCases.map { metric -> [String] in
            let part = value.bytes[metric]
            return [part.knownBytes.map { String($0) } ?? "overflow", String(part.notReturnedCount),
                    String(part.failedCount), part.overflowed ? "true" : "false"]
        }
        return ["counts": kinds, "bytes": bytes]
    }
    static func capture(_ result: StorageAnalysisResult) async throws -> [String: Any] {
        let summary = try await result.summary()
        let sources: [[String: Any]] = summary.sources.map {
            ["id": String($0.id), "value": value($0.value), "finished": $0.traversalFinished]
        }
        var facets = [[String: Any]]()
        for facet in StoredAnalysisFacet.allCases {
            let groups = try await result.groups(facet)
            facets.append(["facet": facet.rawValue, "groupCount": String(groups.groupCount),
                "projectCount": String(groups.projectCount), "remainder": value(groups.remainder),
                "groups": groups.groups.map { group -> [String: Any] in
                    ["id": String(group.id), "value": value(group.value)]
                }])
        }
        return ["summary": value(summary.value), "complete": summary.complete,
                "classificationReady": summary.classificationReady,
                "verifiedAliases": String(summary.verifiedAliases),
                "unresolvedAliases": String(summary.unresolvedAliases),
                "sources": sources, "facets": facets]
    }
}
#endif
