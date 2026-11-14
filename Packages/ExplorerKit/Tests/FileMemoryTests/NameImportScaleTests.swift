import Darwin
import Foundation
import Testing
@testable import FileMemory

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_B075_SCALE_ROOT"] != nil))
func b075ImportScaleWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(env["MAC_EXPLORER_B075_SCALE_ROOT"]))
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let countText = try #require(env["MAC_EXPLORER_B075_SCALE_COUNT"])
    let count = try #require(Int(countText))
    try #require([10_000, 100_000].contains(count))
    try #require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b07-integrated-acceptance"))
    try #require(UUID(uuidString: root.lastPathComponent) != nil && root.resolvingSymlinksInPath() == root)
    try #require(FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path))
    let clock = ContinuousClock(), allStart = clock.now
    func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let parts = (clock.now - start).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
    var timings: [String: Double] = [:]
    let session = NameImportSession(target: .newCatalog(directory: root.appendingPathComponent("catalog")))
    let previewStart = clock.now
    let preview = try await session.preview(selectedFile: root.appendingPathComponent("metadata/input.json"))
    timings["strictPreview"] = elapsed(previewStart)
    #expect(preview.recordCount == count && preview.discardedLocations == 0)
    let applyStart = clock.now
    guard case .imported(let attempt) = await session.apply(preview) else { Issue.record("Scale import did not commit"); await session.close(); return }
    timings["atomicInsertAndFullValidation"] = elapsed(applyStart)
    let store = try #require(await session.takeCreatedStore())
    await session.close()
    #expect(try await store.resolveImport(attempt) == .allPresent(records: count))
    let stats = try await store.management()
    #expect(stats.savedItems == count && stats.storedReferences == 0)
    await store.close()
    let coldStart = clock.now
    let reopened = try await PersistentNameStore.open(directory: root.appendingPathComponent("catalog"))
    timings["coldConnectionFullValidation"] = elapsed(coldStart)
    var queries: [[String: Any]] = []
    for (name, text) in [("exact", "Project 000333"), ("word", "000333"), ("common", "Project"), ("absent", "not-present-sentinel")] {
        var times: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            let page = try await reopened.query(RememberedNameQuery(text: text, match: name == "exact" ? .exact : .prefixAndWords))
            let matches = try storedMatches(page)
            times.append(elapsed(start))
            #expect(matches.count <= 64 && page.visitedPostings <= 8_192)
            if name == "exact" || name == "word" { #expect(matches.count == 1) }
            if name == "absent" { #expect(matches.isEmpty && page.coverage == .complete) }
        }
        #expect(times[0] <= 250 && (times.dropFirst().max() ?? 0) <= 100)
        queries.append(["kind": name, "milliseconds": times])
    }
    await reopened.close()
    var usage = rusage(); #expect(getrusage(RUSAGE_SELF, &usage) == 0)
    let passed = timings["strictPreview", default: 0] + timings["atomicInsertAndFullValidation", default: 0] <= 60_000
        && usage.ru_maxrss <= 256 * 1_024 * 1_024
    let report: [String: Any] = ["passed": passed, "records": count, "timingMilliseconds": timings,
        "queries": queries, "totalMilliseconds": elapsed(allStart), "peakRSSBytes": usage.ru_maxrss,
        "databaseBytes": stats.databaseLogicalBytes, "inputBytes": preview.encodedBytes,
        "coldDefinition": "Fresh connection with complete validation; OS caches unchanged", "noNativeAccess": stats.storedReferences == 0]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("evidence/metrics.json"), options: .withoutOverwriting)
    #expect(passed)
}
