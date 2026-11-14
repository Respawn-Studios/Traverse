#if DEBUG
import AppKit
import FileOperations
import StorageAnalysis

@MainActor enum StorageSortedPagingVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run(browser: BrowserViewController, ordinary: Bool) async throws -> [String: Any] {
        let root = try await StorageAnalysisScaleVerification.admittedSource("wide")
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"),
            sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared, owner = UUID()
        coordinator.enablePagedForQualification(storage: storage, workerURL: ordinary ? nil
            : repository.appendingPathComponent(".build/b06-consumer-profile-build/compact-sorted-pages/worker"))
        coordinator.configurePicker(from: browser)
        var accesses = 0, copied: String?
        let oldWriter = browser.clipboardWriter
        browser.clipboardWriter = { text, _ in copied = text; return .text }
        StoredAnalysisTableProbe.enabled = true
        defer { browser.clipboardWriter = oldWriter; StoredAnalysisTableProbe.enabled = false; coordinator.toolWindow?.close() }
        coordinator.analyzeProperties(owner: owner, root: root, access: { accesses += 1; return FileAccessLifetimes(leases: []) }, onChange: { _, _ in })
        try await wait("Sorted generated result") { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        guard let result = coordinator.pagedResultForVerification else { throw StorageScanFailure.invalidOutput }
        try require(result.supportsSortedPages && coordinator.pagedSummaryForVerification?.value.counts.total == 100000, "Sorted capability/source oracle mismatch")
        do { _ = try await result.sortedPage() }
        catch { throw UIVerification.Failure(message: "Direct sorted decoder: \(String(describing: error))") }
        let started = ProcessInfo.processInfo.systemUptime
        try require(coordinator.openFullAnalysis(owner: owner, root: root), "Sorted full-analysis handoff refused")
        guard let tool = coordinator.toolWindow else { throw StorageScanFailure.invalidOutput }
        do { try await wait("Sorted native root page") { tool.pagedReadyForVerification && tool.pagedRowCountForVerification == 100 && StoredAnalysisTableProbe.latest?.window === tool.window } }
        catch {
            throw UIVerification.Failure(message: "Sorted native root page: loading=\(tool.pagedModelForVerification?.loading == true), rows=\(tool.pagedRowCountForVerification), message=\(tool.pagedModelForVerification?.message ?? "no model")")
        }
        guard let model = tool.pagedModelForVerification, let table = StoredAnalysisTableProbe.latest else { throw StorageScanFailure.invalidOutput }
        try require(!model.hasNext, "A short root page offered a nonexistent next page")
        guard let block = model.rows.first(where: { $0.title == "block-000" && $0.kind == .directory }) else { throw StorageScanFailure.invalidOutput }
        model.open(block)
        try await wait("Sorted generated child page") { !model.loading && model.rows.count == 256 }
        try await wait("Sorted native rows installed") { table.installedRowIDsForQualification == model.rows.map(\.id) && result.activeReaderCount == 0 }
        let firstSeconds = ProcessInfo.processInfo.systemUptime - started, original = model.rows.map(\.id), lastName = model.rows.last!.rawName
        // The retained wide corpus is100 folders with999 files each, not one
        //100k-child directory. block-000 contains indices0,100,...99800, with
        //64 bytes at multiples of16 and zero at the other generated names.
        let allNames = (0..<999).map { String(format: "item-%06d.txt", $0 * 100) }
        let largestNames = (0..<999).sorted {
            let left = $0 % 4 == 0, right = $1 % 4 == 0
            return left == right ? $0 < $1 : left
        }.map { allNames[$0] }
        try require(model.sortOrder == .logicalDescending && model.canSort && model.hasNext
            && model.rows.allSatisfy { $0.kind == .regularFile }
            && model.rows.map(\.title) == Array(largestNames.prefix(256)), "Largest-size native page or tie order differs")
        model.next()
        try await wait("Sorted next page") { !model.loading && table.installedRowIDsForQualification == model.rows.map(\.id) && result.activeReaderCount == 0 }
        try require(model.cursor == original.last && model.rows.count == 256 && model.canGoBack
            && lastName.lexicographicallyPrecedes(model.rows.first!.rawName)
            && model.rows.map(\.title) == Array(largestNames[256..<512]), "Sorted cursor skipped/repeated its boundary")
        let queries = result.queryWorkerLaunchCountForQualification, secondPage = model.rows.map(\.id)
        model.back()
        try await wait("Cached sorted Previous") { !model.loading && result.activeReaderCount == 0 }
        try require(model.rows.map(\.id) == original && result.queryWorkerLaunchCountForQualification == queries, "Sorted Previous spawned a new query or changed its exact page")
        // Simulated presentation notifications only. This immutable corpus is
        // never submitted to Trash; the real mutation/Undo path has its own
        // small generated-fixture integration check.
        let presentationEngine = RecoverableFileOperations(journalDirectory: repository.appendingPathComponent(".build/unused-page-presentation-history"))
        let hiddenTail = UUID()
        model.recordTrash(node: original.last!, recordID: hiddenTail, browser: browser, engine: presentationEngine)
        try await wait("Hidden page tail installed") { table.installedRowIDsForQualification == model.rows.map(\.id) && model.rows.count == 255 }
        model.next()
        try await wait("Next after hidden recorded tail") { !model.loading && result.activeReaderCount == 0 }
        try require(model.cursor == original.last && model.rows.map(\.id) == secondPage, "Hidden tail repeated/skipped the next stored page")
        model.back()
        try await wait("Previous retains its known hidden tail") { !model.loading && model.rows.count == 255 }
        model.recordUndo(recordID: hiddenTail)
        let knownChanges = original.map { (id: UUID(), node: $0) }
        for change in knownChanges { model.recordTrash(node: change.node, recordID: change.id, browser: browser, engine: presentationEngine) }
        try require(model.rows.isEmpty && model.hasNext, "A fully hidden page lost its recorded continuation")
        model.next()
        try await wait("Next after an entirely hidden page") { !model.loading && result.activeReaderCount == 0 }
        try require(model.cursor == original.last && model.rows.map(\.id) == secondPage, "An empty visible page lost/repeated stored observations")
        model.back()
        try await wait("Previous to the entirely hidden page") { !model.loading && model.rows.isEmpty }
        for change in knownChanges { model.recordUndo(recordID: change.id) }
        try await wait("Presentation-only Undo restores original page") { table.installedRowIDsForQualification == original }
        try require(result.queryWorkerLaunchCountForQualification == queries, "Known changes bypassed or invalidated the existing page cache")
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        try await wait("Native header sort") { model.sortOrder == .nameDescending && !model.loading && table.installedRowIDsForQualification == model.rows.map(\.id) }
        try require(model.cursor == 0 && !model.canGoBack && model.rows.map(\.title) == Array(allNames.reversed().prefix(256)), "Header did not change whole-parent order/reset position")
        model.select(model.rows[0].id)
        model.act(.copyPath)
        try await wait("Sorted row Copy Path") { !model.actionRunning && !coordinator.hasWork }
        try require(copied == root.appendingPathComponent("block-000/" + model.rows[0].title).path, "Sorted menu changed its originating row")
        let scanAccesses = accesses
        model.changeSort(.allocatedDescending); model.changeSort(.nameAscending)
        try await wait("Superseded sort") { !model.loading && result.activeReaderCount == 0 && table.installedRowIDsForQualification == model.rows.map(\.id) }
        try require(model.sortOrder == .nameAscending && model.rows.map(\.title) == Array(allNames.prefix(256)) && model.cursor == 0 && model.selectedID == nil,
            "Superseded sort restored old rows/cursor/selection")
        // Old ordinal and new sorted requests have distinct cache identities.
        let ordinal = try await result.page(parent: block.id)
        let sorted = try await result.sortedPage(parent: block.id, order: .logicalDescending)
        try require(ordinal.count == 256 && zip(ordinal, ordinal.dropFirst()).allSatisfy({ $0.id < $1.id })
            && sorted.rows.map(\.id) == original && sorted.hasMore, "Legacy/sorted cache responses were conflated")
        try require(accesses == scanAccesses && coordinator.pagedResultForVerification?.id == result.id && !coordinator.hasWork,
            "Sorting acquired source access or rescanned")
        tool.close(); await coordinator.stopAndDrain(); await result.waitUntilReadersDrained()
        try require(!model.hasWork && result.activeReaderCount == 0 && ApplicationFileActivity.gate.activeCount == 0,
            "Sorted close retained query work")
        return ["passed": true, "checks": ["largest logical default", "global size/name tie order", "opaque next cursor", "cached Previous without child", "native header changes sort", "cursor reset", "sorted row target", "superseded sort rejection", "legacy/sorted cache isolation", "no source rescan/access", "close and actual query drain"],
            "presentation_checks": ["hidden tail retains exact opaque continuation", "entire hidden page can continue", "Previous retains removals", "known restoration uses recorded rows without a query"],
            "first_page_seconds": firstSeconds, "sorted_parent_entries": 999, "source_corpus_entries": 100000,
            "ordinary_helper": ordinary, "source_body_reads": false, "activity_count": ApplicationFileActivity.gate.activeCount]
    }
}
#endif
