import Darwin
import Foundation
import Testing
@testable import FileMemory

private func milliseconds(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

/// Explicit opt-in keeps the 100k measurement out of ordinary correctness runs.
/// This is the real module/SQLite/actor path with no synthetic query surrogate.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_SCALE"] == "1"))
func nameIndexQualificationScale() async throws {
    for count in [10_000, 100_000] {
        let index = try SessionNameIndex()
        let ingestionStart = DispatchTime.now().uptimeNanoseconds
        var target: RememberedItemID?
        var sourceBytes = 0
        for i in 0..<count {
            let names = try AuthoredNames(nickname: "Project \(String(format: "%06d", i))",
                alternateNames: ["Release \(String(format: "%06d", i))"], labels: [i % 2 == 0 ? "work" : "personal"])
            sourceBytes += names.nickname!.utf8.count + names.alternateNames[0].utf8.count + names.labels[0].utf8.count
            let capture = try await index.prepareNew(names)
            let id = try await index.apply(capture)
            if i == 333 { target = id }
        }
        let ingestionMilliseconds = milliseconds(ingestionStart)
        #expect(sourceBytes < 64 * 1_024 * 1_024)
        let requests: [(String, RememberedNameQuery)] = [
            ("exact", try RememberedNameQuery(text: "Project 000333", match: .exact)),
            ("prefix", try RememberedNameQuery(text: "Project 0003")),
            ("word", try RememberedNameQuery(text: "000333")),
            ("absent", try RememberedNameQuery(text: "absent-sentinel")),
            ("common", try RememberedNameQuery(text: "Project")),
            ("label", try RememberedNameQuery(text: "work", match: .exact, fields: [.label])),
        ]
        var samples: [[String: Any]] = []
        for (kind, request) in requests {
            let start = DispatchTime.now().uptimeNanoseconds
            let first = try await index.query(request)
            let firstMilliseconds = milliseconds(start)
            #expect(firstMilliseconds <= 250)
            #expect(first.matches.count <= 64)
            if kind == "exact" || kind == "word" { #expect(first.matches.map(\.item.id) == [target!]) }
            if kind == "absent" { #expect(first.matches.isEmpty && first.coverage == .complete) }
            if kind == "prefix" { #expect(first.coverage == .complete) }
            if kind == "common" { #expect(first.coverage == .candidateLimit) }
            if kind == "label", count == 100_000 { #expect(first.coverage == .candidateLimit) }
            var warm: [Double] = []
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                let page = try await index.query(request)
                warm.append(milliseconds(start))
                #expect(page.matches.map(\.item.id) == first.matches.map(\.item.id))
                #expect(page.coverage == first.coverage)
            }
            warm.sort()
            let p95 = warm[Int(ceil(Double(warm.count) * 0.95)) - 1]
            #expect(p95 <= 100)
            samples.append(["kind": kind, "first_ms": firstMilliseconds, "warm_p95_ms": p95,
                "warm_median_ms": warm[warm.count / 2], "coverage": first.coverage.rawValue,
                "postings": first.visitedPostings, "rows": first.matches.count])
            for plan in try await index.qualificationPlans(request) {
                #expect(plan.contains { $0.contains("SEARCH k USING PRIMARY KEY") })
                #expect(!plan.contains { $0.contains("SCAN ") || $0.contains("TEMP B-TREE") })
            }
        }
        let statistics = try await index.qualificationStatistics()
        #expect(statistics.records == count)
        #expect(statistics.names == count * 3)
        #expect(statistics.bytes <= 512 * 1_024 * 1_024)
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let metric: [String: Any] = ["records": count, "names": statistics.names, "keys": statistics.postings,
            "sqlite_bytes": statistics.bytes, "sqlite_version": statistics.sqliteVersion, "source_bytes": sourceBytes,
            "ingestion_ms": ingestionMilliseconds, "process_max_rss_bytes": usage.ru_maxrss, "queries": samples,
            "storage": "memory-only", "normalizer_version": RememberedNameNormalization.version]
        let bytes = try JSONSerialization.data(withJSONObject: metric, options: [.sortedKeys])
        print("B07_METRIC " + String(decoding: bytes, as: UTF8.self))
        await index.close()
    }
}
