import Darwin
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

private final class LabelProcessCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
/// Exact generated-only process lane. A test bundle cannot self-terminate from
/// ordinary unit execution, and no fault API enters the production module.
@Test func privateLabelsProcessQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let text = environment["MAC_EXPLORER_LABEL_PROCESS_ROOT"],
          let phase = environment["MAC_EXPLORER_LABEL_PROCESS_PHASE"],
          let scenario = environment["MAC_EXPLORER_LABEL_PROCESS_SCENARIO"] else { return }
    let root = URL(fileURLWithPath: text), source = root.appendingPathComponent("source"), catalog = source.appendingPathComponent("catalog")
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-release").path,
          root.resolvingSymlinksInPath().path == root.path, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
          let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
          marker["action"] as? String == "traverse-private-labels",
          ["firstRow", "lastRow", "committed", "journalSync", "databaseWrite"].contains(scenario) else { throw NameStoreFailure.unsafe }
    func receipt(_ values: [String: Any]) throws {
        var value = values; value["pid"] = getpid(); value["phase"] = phase
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("evidence/process-" + phase + ".json"), options: .withoutOverwriting)
    }
    if phase == "seed" {
        let store = try await PersistentNameStore.create(directory: catalog, first: AuthoredNames(nickname: "Generated 0", labels: ["before"]))
        for index in 1..<3 {
            let edit = try await store.prepareNew(AuthoredNames(nickname: "Generated \(index)", labels: ["before"]))
            _ = try await store.apply(edit)
        }
        await store.close(); try receipt(["passed": true, "records": 3]); return
    }
    if phase == "write" {
        let count = LabelProcessCounter(), crashing = ["firstRow","lastRow","committed"].contains(scenario)
        if !crashing { #expect(menames_fault_register(source.path) == SQLITE_OK) }
        let store = try await PersistentNameStore.open(directory: catalog, action: .edit, probe: { boundary in
            let selected = scenario == "committed" ? boundary == .saveCommit
                : boundary == .saveRows && count.next() == (scenario == "firstRow" ? 1 : 3)
            if crashing && selected {
                let report: [String: Any] = ["passed": true, "phase": phase, "pid": getpid(), "terminationCode": 86,
                    "rowsBoundary": scenario == "committed" ? 3 : scenario == "firstRow" ? 1 : 3, "afterCommit": scenario == "committed"]
                let path = root.appendingPathComponent("evidence/process-write.json")
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw NameStoreFailure.unsafe }
                try data.withUnsafeBytes { bytes in
                    guard write(fd, bytes.baseAddress, bytes.count) == bytes.count, fsync(fd) == 0 else { throw NameStoreFailure.unavailable }
                }
                close(fd); _exit(86)
            }
        }, vfs: crashing ? nil : "menames-generated-faults")
        try await store.qualificationCachePages(1)
        let page = try await store.library(), ids = extractLabelProcessIDs(page)
        guard ids.count == 3 else { throw NameIndexFailure.missingRecord }
        var snapshots: [StoredNameSnapshot] = []
        for id in ids { snapshots.append(try await store.snapshot(id)) }
        let preview = try await store.prepareLabelAddition(snapshots.map { NameLabelTarget(id: $0.id, revision: $0.revision) }, labels: ["after"])
        if !crashing { menames_fault_arm(scenario == "journalSync" ? 2 : 1, 1, scenario == "journalSync" ? 2 : 1) }
        var failed = false
        do { _ = try await store.applyLabelAddition(preview) } catch { failed = true }
        if crashing { Issue.record("Requested process boundary was not reached"); await store.close(); return }
        #expect(failed && menames_fault_hits() == 1)
        let hits = menames_fault_hits(); await store.close()
        try receipt(["passed": failed && hits == 1, "faultHits": hits, "savedAcknowledged": false]); return
    }
    guard phase == "recover" || phase == "cold" else { throw NameStoreFailure.unsafe }
    let store = try await PersistentNameStore.open(directory: catalog, action: phase == "recover" ? .recover : .readOnly)
    let page = try await store.library(), ids = extractLabelProcessIDs(page)
    var old = 0, new = 0
    for id in ids {
        let snapshot = try await store.snapshot(id)
        var labels: [String] = []
        #expect(snapshot.publish { labels = $0.names.labels })
        if labels == ["before"] { old += 1 }
        if labels == ["before","after"] { new += 1 }
    }
    #expect(ids.count == 3 && (old == 3 || new == 3))
    if scenario == "committed" { #expect(new == 3) }
    else { #expect(old == 3) }
    await store.close()
    try receipt(["passed": ids.count == 3 && (scenario == "committed" ? new == 3 : old == 3), "old": old, "new": new, "partial": old > 0 && new > 0])
}
private func extractLabelProcessIDs(_ page: StoredNamePage) -> [RememberedItemID] {
    var ids: [RememberedItemID] = []
    _ = page.publish { ids = $0.map { $0.item.id } }
    return ids
}
