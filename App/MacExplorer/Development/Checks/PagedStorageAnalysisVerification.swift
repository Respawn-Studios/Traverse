#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import StorageAnalysis
import SwiftUI

/// Controllers admit stores/captures before these focused native checks.
/// Personal startup metadata is a separate explicit qualification mode.
@MainActor
enum PagedStorageAnalysisVerification {
    /// Completed Properties -> full view -> close: no personal scan or refresh.
    static func completionControls() async throws -> [String: Any] {
        let root = try await StorageAnalysisScaleVerification.admittedSource("wide")
        var repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repo.deleteLastPathComponent() }
        let storage = try AnalysisResultStorage(directory: repo.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"),
            sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage)
        coordinator.requiresAnalysisSelectionForVerification = false
        let properties = FilePropertiesWindowController(retainAccess: { _ in FileAccessLifetimes(leases: []) }, copyPaths: { _ in })
        defer { properties.cancel(); properties.close(); coordinator.toolWindow?.close() }
        properties.update(urls: [root])
        try await wait("Completed Properties shallow read") { properties.model.canAnalyzeStorage }
        properties.model.analyzeStorage()
        try await wait("Completed Properties final presentation") {
            coordinator.pagedSummaryForVerification != nil && !coordinator.hasWork
        }
        let completed = properties.model.analysisValue
        try UIVerification.require(completed?.isRunning == false && completed?.isComplete == true
            && completed?.counts?.total == 100000 && completed?.message.contains("Preparing") == false,
            "Completed Properties retained a preparing state")
        let id = coordinator.pagedResultForVerification?.id
        properties.model.openFullAnalysis()
        try await wait("Completed Properties full handoff") { coordinator.toolWindow?.pagedReadyForVerification == true }
        let handedOff = properties.model.analysisValue
        try UIVerification.require(handedOff?.isRunning == false && handedOff?.message.contains("Continues") == true
            && coordinator.pagedResultForVerification?.id == id, "Completed handoff retained preparing or rescanned")
        coordinator.toolWindow?.close(); await coordinator.stopAndDrain()
        try UIVerification.require(!coordinator.hasWork && properties.model.analysisValue?.isRunning == false
            && properties.model.analysisValue?.message.contains("Preparing") == false,
            "Closed full view left Properties preparing")
        properties.model.openFullAnalysis()
        try UIVerification.require(properties.model.analysisValue?.message.contains("no longer available") == true,
            "Closed full result retained browse authority")
        properties.cancel(); properties.close(); await coordinator.stopAndDrain()
        return ["passed": true, "checks": ["Final Properties counts and idle state", "Same-result full handoff",
            "Close/drain leaves no preparing state", "Closed full result requires Analyze Again"],
            "completedMessage": completed?.message ?? "", "handoffMessage": handedOff?.message ?? "",
            "sourceEntries": 100000, "personalScans": 0, "activityCount": ApplicationFileActivity.gate.activeCount]
    }

    @MainActor private final class PolicyAccessHold {
        var calls = 0, holdNext = false
        var pending: CheckedContinuation<FileAccessLifetimes, Never>?
        func acquire() async -> FileAccessLifetimes {
            calls += 1
            if holdNext {
                holdNext = false
                return await withCheckedContinuation { pending = $0 }
            }
            return FileAccessLifetimes(leases: [])
        }
        func release() { pending?.resume(returning: FileAccessLifetimes(leases: [])); pending = nil }
    }

    /// Actual Properties binding and native tool controls on an already
    /// admitted generated root. No real Containers or broader personal roots.
    static func policyControls() async throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        let root = try await StorageAnalysisScaleVerification.admittedSource("wide")
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 64 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared, access = PolicyAccessHold()
        coordinator.enablePagedForQualification(storage: storage)
        try UIVerification.require(coordinator.applicationDataControlsQualified, "The ordinary app-data controls are not activated")
        let properties = FilePropertiesWindowController(retainAccess: { _ in await access.acquire() }, copyPaths: { _ in })
        defer { access.release(); properties.cancel(); properties.close(); coordinator.toolWindow?.close() }
        properties.update(urls: [root])
        try await wait("Policy controls shallow Properties") { !properties.model.isLoading }
        try UIVerification.require(properties.model.canAnalyzeStorage && !properties.model.includeApplicationData
            && properties.model.analysisMetadataPolicy == nil && !coordinator.hasWork, "Properties broadened or scanned on opening")
        let shallowAccessCalls = access.calls
        properties.model.includeApplicationData = true
        properties.model.analyzeStorage()
        try UIVerification.require(!properties.model.includeApplicationData && properties.model.analysisMetadataPolicy == .applicationData
            && coordinator.currentMetadataPolicy == .applicationData, "Properties failed to capture/reset its next-request policy")
        try await wait("Broader generated Properties result") { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        func current(_ policy: AnalysisMetadataPolicy) throws -> (UUID, StoredAnalysisValue) {
            guard let result = coordinator.pagedResultForVerification, let summary = coordinator.pagedSummaryForVerification else {
                throw UIVerification.Failure(message: "Policy-control result unavailable")
            }
            try UIVerification.require(result.classificationRevision == .v3 && result.metadataPolicy == policy && summary.complete && summary.value.counts.total == 100000,
                "Captured request/result policy or generated accounting changed")
            return (result.id, summary.value)
        }
        let first = try current(.applicationData)
        let captureRoot = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018")
        let propertyCapture = captureRoot.appendingPathComponent("policy-properties-" + UUID().uuidString + ".png")
        if let native = properties.window { native.setContentSize(.init(width: 580, height: 800)); try await UIVerification.snapshot(native, to: propertyCapture) }
        try UIVerification.require(properties.model.analysisValue?.counts?.total == 100000 && access.calls == shallowAccessCalls + 1,
            "Properties lost its broader request summary")
        properties.model.openFullAnalysis()
        try await wait("Policy-preserving full handoff") { coordinator.toolWindow?.pagedReadyForVerification == true }
        guard let tool = coordinator.toolWindow, let native = tool.window, let content = native.contentView else { throw StorageScanFailure.invalidOutput }
        try UIVerification.require(try current(.applicationData).0 == first.0 && access.calls == shallowAccessCalls + 1
            && tool.includeApplicationDataButton.state == .off && tool.includeApplicationDataButton.isEnabled
            && tool.metadataPolicyLabel.stringValue.contains(AnalysisMetadataPolicy.applicationData.title),
            "Handoff rescanned, broadened the next request or lost its scope label")
        tool.includeApplicationDataButton.performClick(nil)
        try UIVerification.require(tool.includeApplicationDataButton.state == .on && !coordinator.hasWork
            && coordinator.currentMetadataPolicy == .applicationData, "Changing next-request scope launched work")
        access.holdNext = true
        tool.refreshButton.performClick(nil)
        try await wait("Held policy request access") { access.pending != nil }
        try UIVerification.require(tool.includeApplicationDataButton.state == .off
            && coordinator.currentMetadataPolicy == .applicationData, "Refresh did not consume one explicit choice")
        // A later control edit must not rewrite the request waiting for access.
        tool.includeApplicationDataButton.performClick(nil)
        tool.includeApplicationDataButton.performClick(nil)
        access.release()
        try await wait("Captured broader refresh") { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        let second = try current(.applicationData)
        try UIVerification.require(second.0 != first.0 && second.1 == first.1 && access.calls == shallowAccessCalls + 2,
            "Broader refresh failed the captured-policy/accounting contract")
        let fullCapture = captureRoot.appendingPathComponent("policy-full-" + UUID().uuidString + ".png")
        native.setContentSize(.init(width: 960, height: 780)); try await UIVerification.snapshot(native, to: fullCapture)
        native.setContentSize(.init(width: 740, height: 448)); content.layoutSubtreeIfNeeded()
        try UIVerification.require(content.bounds.contains(tool.includeApplicationDataButton.convert(tool.includeApplicationDataButton.bounds, to: content))
            && content.bounds.contains(tool.metadataPolicyLabel.convert(tool.metadataPolicyLabel.bounds, to: content))
            && tool.compactBreakdownForVerification, "Compact tool window clipped controls or a partial chart")
        let compactCapture = captureRoot.appendingPathComponent("policy-compact-" + UUID().uuidString + ".png")
        try await UIVerification.snapshot(native, to: compactCapture)
        tool.expandBreakdownButton.performClick(nil)
        try UIVerification.require(!tool.compactBreakdownForVerification && content.bounds.height >= 650
            && !coordinator.hasWork && access.calls == shallowAccessCalls + 2, "Showing the compact chart rescanned or failed to expand")
        tool.refreshButton.performClick(nil)
        try UIVerification.require(coordinator.currentMetadataPolicy == .standard && tool.includeApplicationDataButton.state == .off,
            "A new Refresh silently retained the broader policy")
        try await wait("Default standard refresh") { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        let third = try current(.standard)
        try UIVerification.require(third.0 != second.0 && third.1 == first.1 && access.calls == shallowAccessCalls + 3
            && tool.metadataPolicyLabel.stringValue.contains(AnalysisMetadataPolicy.standard.title), "Standard refresh changed coverage or retained a broader label")
        properties.model.openFullAnalysis()
        try UIVerification.require(properties.model.analysisValue?.message.contains("Choose Analyze Again") == true
            && coordinator.currentMetadataPolicy == .standard && access.calls == shallowAccessCalls + 3,
            "Stale Properties silently handed off a result with another policy")
        properties.model.includeApplicationData = true; properties.update(urls: [root])
        try await wait("New Properties selection defaults") { !properties.model.isLoading }
        try UIVerification.require(!properties.model.includeApplicationData && properties.model.analysisMetadataPolicy == nil
            && !coordinator.hasWork, "Reopening a Properties selection retained consent or started scanning")
        tool.appStorageButton.performClick(nil)
        try await wait("Unavailable app-state reset/drain") { !coordinator.hasWork }
        try UIVerification.require(coordinator.currentRoot == nil && coordinator.currentMetadataPolicy == .standard
            && !tool.includeApplicationDataButton.isEnabled && tool.includeApplicationDataButton.state == .off
            && !tool.pagedReadyForVerification && tool.pagedRowCountForVerification == 0,
            "Unavailable app-owned state retained a previous scope or pending choice")
        tool.setRequestPolicy(.standard, available: false)
        tool.includeApplicationDataButton.state = .on
        try UIVerification.require(!tool.includeApplicationDataButton.isEnabled && tool.takeNextMetadataPolicy() == .standard,
            "An unavailable or app-state control broadened the next request")
        tool.close(); await coordinator.stopAndDrain()
        try UIVerification.require(!coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0,
            "Policy controls left work running after close")
        return ["passed": true, "scope": "Generated immutable corpus only; actual Properties model and native tool controls",
            "checks": ["off-by-default Properties", "single-use choice", "immutable pending request", "same-result policy handoff",
                "native checkbox and Refresh", "standard default on next Refresh", "policy-bound stale handoff refusal", "equal four-metric accounting", "new selection reset", "compact layout", "unavailable app-state reset/drain", "close/drain"],
            "captures": [propertyCapture.lastPathComponent, fullCapture.lastPathComponent, compactCapture.lastPathComponent],
            "actual_private_application_data_scanned": false, "access_calls": access.calls,
            "ordinary_classification_revision": 3,
            "retained_generated_stores": 3, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began]
    }

    static func explicitDriveInterface(startup: Bool, deeper: Bool = false) async throws -> [String: Any] {
        try UIVerification.require(startup, "Historical external-drive qualification is retired; use a generated fixture.")
        try UIVerification.require(!deeper || startup, "Deeper personal qualification admits only the approved internal drive")
        let began = ProcessInfo.processInfo.systemUptime
        let policy: AnalysisMetadataPolicy = deeper ? .applicationData : .standard
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let coordinator = ApplicationStorageAnalysis(), owner = UUID()
        let storage = try await UIVerification.isolatedAnalysisStorage()
        var ownedID: UUID?, accessCalls = 0
        func observe() async throws -> [String: Any] {
            var reported: FolderSummaryValue?
            coordinator.analyzeProperties(owner: owner, root: root, metadataPolicy: policy, access: {
                accessCalls += 1; return "Explicit approved-drive metadata qualification"
            }, onChange: { value, _ in reported = value })
            try await wait("Actual approved-drive Properties presentation", seconds: 180) {
                coordinator.pagedSummaryForVerification != nil && !coordinator.hasWork
            }
            guard let result = coordinator.pagedResultForVerification, let summary = coordinator.pagedSummaryForVerification,
                  let terminal = coordinator.pagedUpdateForVerification else { throw StorageScanFailure.invalidOutput }
            ownedID = result.id
            try UIVerification.require((startup ? summary.sources.count == 2 && summary.sources.allSatisfy(\.traversalFinished)
                && summary.verifiedAliases > 0 && summary.unresolvedAliases == 0 : summary.sources.isEmpty)
                && summary.classificationReady
                && reported?.counts == summary.value.counts && reported?.isRunning == false,
                "Actual drive Properties coverage/summary gate failed; entries=\(summary.value.counts.total); classification=\(summary.classificationReady); gap=\(String(describing: terminal.coverage.terminalReason))")
            let presentedAt = ProcessInfo.processInfo.systemUptime
            try UIVerification.require(result.metadataPolicy == policy && coordinator.openFullAnalysis(owner: owner, root: root, metadataPolicy: policy), "Startup full-analysis scope/handoff refused")
            try await wait("Startup stored native page") { coordinator.toolWindow?.pagedReadyForVerification == true }
            try UIVerification.require(coordinator.pagedResultForVerification?.id == result.id && accessCalls == 1
                && coordinator.activePagedSession == nil && coordinator.toolWindow?.preparedFolderCount == 0
                && (startup ? coordinator.toolWindow?.pagedRowCountForVerification == 2 : (coordinator.toolWindow?.pagedRowCountForVerification ?? 0) > 0),
                "Startup handoff rescanned or rebuilt a snapshot")
            coordinator.toolWindow?.openFirstPagedFolderForVerification()
            try await wait("Data source stored page") { coordinator.toolWindow?.pagedReadyForVerification == true }
            let visible = coordinator.toolWindow?.pagedRowCountForVerification ?? 0
            try UIVerification.require(visible > 0 && visible <= 256, "Data source page missing or unbounded")
            let pageAt = ProcessInfo.processInfo.systemUptime
            var groupSeconds: [String: Double] = [:]
            var groupAmounts: [String: [String: UInt64]] = [:]
            for (name, facet) in [("types", StoredAnalysisFacet.fileTypes), ("roles", .storageRoles), ("projects", .projects)] {
                let started = ProcessInfo.processInfo.systemUptime
                let groups = try await result.groups(facet)
                groupSeconds[name] = ProcessInfo.processInfo.systemUptime - started
                groupAmounts[name] = Dictionary(uniqueKeysWithValues: groups.groups.map { (String($0.id), $0.value.bytes.dataLogical.knownBytes ?? 0) })
            }
            let usage = try await storeUsage(storage, id: result.id)
            let report: [String: Any] = ["passed": true, "scope": startup ? "Explicit startup metadata; actual Properties-to-Full-Analysis no-rescan handoff and native Data-page navigation" : "Explicit Workspace metadata; actual Properties-to-Full-Analysis no-rescan handoff and native folder-page navigation",
                "entries": summary.value.counts.total, "terminal_status": String(describing: terminal.status),
                "metadata_policy": policy.rawValue, "ready_seconds": presentedAt - began,
                "handoff_page_seconds": pageAt - presentedAt, "group_seconds": groupSeconds, "group_logical_bytes_by_key": groupAmounts,
                "worker_phase_seconds": coordinator.pagedDiagnosticForVerification.filter { $0.key.hasSuffix("_uptime") }.mapValues { (Double($0) ?? began) - began },
                "coverage_terminal_reason": terminal.coverage.terminalReason.map { String(describing: $0) } as Any? ?? NSNull(),
                "source_entries": summary.sources.map { $0.value.counts.total }, "phase_finished": summary.sources.map(\.traversalFinished),
                "logical_bytes": summary.value.bytes.dataLogical.knownBytes as Any? ?? NSNull(),
                "source_logical_bytes": summary.sources.map { $0.value.bytes.dataLogical.knownBytes as Any? ?? NSNull() },
                "classification_ready": summary.classificationReady, "scan_complete": summary.complete,
                "verified_aliases": summary.verifiedAliases, "unresolved_aliases": summary.unresolvedAliases,
                "temporary_store": usage, "worker_peak_bytes": terminal.workerPeakResidentBytes as Any? ?? NSNull(),
                "parent_process_peak_bytes": resources()["peak_rss"] ?? 0,
                "coverage_notices": Dictionary(uniqueKeysWithValues: AnalysisScanCoverageReason.allCases.map { (String(describing: $0), terminal.coverage[$0]) }),
                "total_coverage_notices": terminal.coverage.workerNotices as Any? ?? NSNull(),
                "visible_rows": visible, "same_handle_handoff": true, "access_calls": accessCalls]
            coordinator.toolWindow?.close(); await coordinator.stopAndDrain(); await result.waitUntilReadersDrained()
            try UIVerification.require(!coordinator.hasWork && result.activeReaderCount == 0
                && coordinator.pagedResultForVerification == nil && ApplicationFileActivity.gate.activeCount == 0,
                "Startup close retained work or released a live reader")
            return report
        }
        let report: [String: Any]
        do { report = try await observe() }
        catch { coordinator.closeProperties(owner: owner); await coordinator.stopAndDrain(); throw error }
        guard let ownedID else { throw StorageScanFailure.invalidOutput }
        let folder = storage.directory.appendingPathComponent("session-" + ownedID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try await waitForDisposal(folder)
        var final = report; final["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - began
        final["owned_store_disposed"] = true
        return final
    }
    static func startup(stop: Bool, diagnostic: Bool) async throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        let gate = FileActivityGate(), discovery = StartupVolumeDiscovery(activityGate: gate)
        let plan = try await discovery.discover()
        let storage = try await UIVerification.isolatedAnalysisStorage()
        var ownedID: UUID?
        func observe() async throws -> [String: Any] {
            let scanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"), activityGate: gate)
            let session = try scanner.startStartup(plan: plan, discovery: discovery, storage: storage, retainingAccess: "Explicit read-only startup metadata qualification")
            let deadline = Task { try await Task.sleep(for: .seconds(diagnostic ? 8 : 180)); session.cancel() }
            defer { deadline.cancel() }
            var terminal: PagedStorageScanUpdate?, requestedStop = false
            for await update in session.updates {
                if stop, update.committedEntries >= 1024, !requestedStop { requestedStop = true; session.cancel() }
                if update.workerDrained { terminal = update }
            }
            await session.waitUntilDrained()
            guard let terminal, let result = terminal.result else { throw UIVerification.Failure(message: "Startup metadata qualification produced no sealed observation: " + String(describing: terminal?.status)
                + "; committed=" + String(terminal?.committedEntries ?? 0) + "; gap=" + String(describing: terminal?.coverage.terminalReason)
                + "; topologyChanged=" + String(!plan.isTopologyUnchanged) + "; seconds=" + String(ProcessInfo.processInfo.systemUptime - began)
                + "; diagnostic=" + String(describing: scanner.qualificationPagedDiagnostic)) }
            let summary = try await result.summary(), roots = try await result.page()
            let storedBytes = try await storeUsage(storage, id: result.id)
            try UIVerification.require(summary.sources.count == 2 && summary.sources[0].value.counts.total > 0
                && roots.map(\.id) == [1, 2] && terminal.isStartupPair && gate.activeCount == 0,
                "Startup source identity, Data coverage or actual worker drain failed")
            if stop { try UIVerification.require(requestedStop && !summary.complete && terminal.status == .cancelled, "Native startup Stop lost its committed prefix") }
            ownedID = result.id
            return ["passed": true, "scope": "Explicit startup filename/metadata only; no bodies or source changes; owned temporary catalog released after readers drain",
                "stop": stop, "scan_complete": summary.complete, "phase_finished": summary.sources.map(\.traversalFinished),
                "stop_reason": scanner.qualificationPagedDiagnostic["worker_reason"] ?? "unknown",
                "terminal_status": String(describing: terminal.status), "topology_changed": !plan.isTopologyUnchanged,
                "temporary_store_limit": storage.sessionByteLimit,
                "temporary_store": storedBytes, "classification_ready": summary.classificationReady,
                "coverage_notices": Dictionary(uniqueKeysWithValues: AnalysisScanCoverageReason.allCases.map { (String(describing: $0), terminal.coverage[$0]) }),
                "total_coverage_notices": terminal.coverage.workerNotices as Any? ?? NSNull(),
                "source_entries": summary.sources.map { $0.value.counts.total }, "logical_bytes": summary.value.bytes.dataLogical.knownBytes as Any? ?? NSNull(),
                "source_logical_bytes": summary.sources.map { $0.value.bytes.dataLogical.knownBytes as Any? ?? NSNull() },
                "verified_aliases": summary.verifiedAliases, "unresolved_aliases": summary.unresolvedAliases,
                "worker_peak_bytes": terminal.workerPeakResidentBytes as Any? ?? NSNull(), "gate_active": gate.activeCount,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began]
        }
        let report = try await observe()
        guard let ownedID else { throw UIVerification.Failure(message: "Missing exact owned result identity") }
        let ownedFolder = storage.directory.appendingPathComponent("session-" + ownedID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try await waitForDisposal(ownedFolder)
        try UIVerification.require(gate.activeCount == 0,
            "Startup owned-store disposal did not finish after actual reader/worker drain")
        var final = report; final["owned_store_disposed"] = true; return final
    }

    static func classification(path: String, interactive: Bool = false) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let root = URL(fileURLWithPath: path), name = root.lastPathComponent
        let prefix = "classification-fixture-", token = name.dropFirst(prefix.count)
        try UIVerification.require(root.path == root.standardizedFileURL.path && root.deletingLastPathComponent().path == repository.appendingPathComponent(".build/b06-analyzer").path
            && name.hasPrefix(prefix) && token.count == 32 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "Only the exact generated classification fixture is admitted")
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 512 << 20, preserveAfterClose: true)
        let scanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"), activityGate: FileActivityGate())
        let session = try scanner.startPaged(root: root, storage: storage, retainingAccess: "Generated classification fixture")
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates { if update.workerDrained { terminal = update } }
        await session.waitUntilDrained()
        guard let result = terminal?.result else { throw UIVerification.Failure(message: "Classification result unavailable") }
        let summary = try await result.summary()
        guard let report = try await result.attribution(scopeName: name, summary: summary) else { throw UIVerification.Failure(message: "Classification report unavailable") }
        try UIVerification.require(summary.complete && report.projectCount == 0 && report.categories.first { $0.storedTarget == .steamLibraries }?.bytes.dataLogical.knownBytes == 70,
            "Native stored classification did not match the generated layout")
        let drill = StorageBreakdownChartModel(); drill.configure(result)
        drill.open(.steamLibraries, title: "Steam & games")
        try await wait("Steam stored chart") { drill.current != nil && !drill.loading }
        guard let installed = drill.current?.value.rows.first(where: { $0.hint == 1 }), let folder = installed.folder else { throw UIVerification.Failure(message: "Steam installed directory unavailable") }
        drill.open(.folder(folder), title: installed.title)
        try await wait("Nested installed-items chart") { drill.levels.count == 2 && !drill.loading }
        try UIVerification.require(drill.current?.value.rows.first?.title == "Game" && drill.parent != nil, "Nested chart lost its recorded parent or directory")
        var filteredSeconds: [String: Double] = [:]
        for (name, facet, key) in [("Other", StoredAnalysisFacet.fileTypes, UInt64(0)), ("Steam role", .storageRoles, 9), ("Unassigned", .projects, 0)] {
            let started = ProcessInfo.processInfo.systemUptime
            let filtered = try await result.breakdown(.filtered(folder: 0, facet: facet, key: key))
            filteredSeconds[name] = ProcessInfo.processInfo.systemUptime - started
            try UIVerification.require(filtered.value.bytes.dataLogical.knownBytes == 70 && filtered.value.counts.regularFiles == 2,
                "Filtered chart failed the exact generated oracle")
            if let child = filtered.rows.first?.folder {
                let nested = try await result.breakdown(filtered.target(for: child))
                try UIVerification.require(nested.value.bytes.dataLogical.knownBytes == filtered.rows.first?.value.bytes.dataLogical.knownBytes,
                    "Filtered child lost its category")
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Storage breakdown · generated sample"
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: StorageAttributionView.verificationView(report: report, drill: drill).padding(20))
        defer { window.contentView = nil; window.close(); drill.close() }
        if interactive {
            StorageDimensionalChartProbe.enabled = true; StorageDimensionalChartProbe.hoverCount = 0; StorageDimensionalChartProbe.clickCount = 0
            defer { StorageDimensionalChartProbe.enabled = false }
            drill.reset()
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            print("MAC_EXPLORER_CHART_REVIEW_READY"); fflush(stdout)
            let deadline = ProcessInfo.processInfo.systemUptime + 300
            var maximumDepth = 0
            while window.isVisible && ProcessInfo.processInfo.systemUptime < deadline {
                maximumDepth = max(maximumDepth, drill.levels.count)
                try await Task.sleep(for: .milliseconds(50))
            }
            try UIVerification.require(!window.isVisible, "Chart review time limit; clicks=\(StorageDimensionalChartProbe.clickCount), hover=\(StorageDimensionalChartProbe.hoverCount), depth=\(maximumDepth). Close the generated chart after review.")
            try UIVerification.require(StorageDimensionalChartProbe.clickCount >= 3 && maximumDepth >= 3,
                "The actual ring gesture did not exercise three nested chart levels")
            return ["passed": true, "renderer": "native-dimensional", "ring_clicks": StorageDimensionalChartProbe.clickCount, "maximum_depth": maximumDepth,
                "hover_events": StorageDimensionalChartProbe.hoverCount, "hover_verified": StorageDimensionalChartProbe.hoverCount > 0,
                "checks": ["three actual ring drill activations", "native close without selection-state warning"]]
        }
        let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/native-drill-" + UUID().uuidString + ".png")
        try await UIVerification.snapshot(window, to: capture)
        drill.back(); drill.setMetric(.allForkAllocated)
        try await wait("Chart Back and allocation ranking") { drill.levels.count == 1 && drill.current?.value.rankingMetric == .allForkAllocated && !drill.loading }
        drill.open(.folder(0), title: "Old request"); drill.reset(); drill.open(.steamLibraries, title: "Latest request")
        try await wait("Latest chart query replaces cancelled intent") { drill.current?.title == "Latest request" && !drill.loading }
        drill.close(); await result.waitUntilReadersDrained()
        try UIVerification.require(drill.levels.isEmpty && !drill.canBrowse && result.activeReaderCount == 0, "Chart close retained a query or stale level")
        return ["passed": true, "checks": ["native Rust result classification", "Steam nested chart", "filtered types/roles/projects and child totals", "Back", "allocated ranking", "stale query rejection", "close/read drain"], "filtered_seconds": filteredSeconds, "capture": capture.lastPathComponent]
    }
    private static func wait(_ description: String, seconds: TimeInterval = 15, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: "Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func storeUsage(_ storage: AnalysisResultStorage, id: UUID) async throws -> [String: UInt64] {
        let name = "session-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return try await Task.detached(priority: .utility) {
            let parent = open(storage.directory.appendingPathComponent(name).path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parent >= 0 else { throw StorageScanFailure.unavailable }; defer { close(parent) }
            var value = stat()
            guard fstatat(parent, "result.sqlite", &value, AT_SYMLINK_NOFOLLOW) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == geteuid(),
                  value.st_size >= 0, value.st_blocks >= 0 else { throw StorageScanFailure.changed }
            return ["database_bytes": UInt64(value.st_size), "database_allocated": UInt64(value.st_blocks) * 512]
        }.value
    }
    private static func waitForDisposal(_ folder: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let absent = await Task.detached(priority: .utility) {
                var value = stat(); return lstat(folder.path, &value) != 0 && errno == ENOENT
            }.value
            if absent { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw UIVerification.Failure(message: "Exact owned temporary catalog was not disposed after actual drain")
    }
    static func contracts() async throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        let root = try await StorageAnalysisScaleVerification.admittedSource("wide")
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 512 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis()
        coordinator.enablePagedForQualification(storage: storage)
        var checks: [String] = []
        do {
            let owner = UUID(); var accessCalls = 0, reported: FolderSummaryValue?, sawPrefix = false, prefixSafe = true
            coordinator.analyzeProperties(owner: owner, root: root, access: {
                accessCalls += 1; return "Generated corpus only"
            }, onChange: { value, report in
                reported = value
                if report?.isProvisional == true {
                    sawPrefix = true
                    prefixSafe = prefixSafe && value.isRunning && !value.isComplete && value.counts != nil
                        && coordinator.resultForProperties(owner: owner) == nil
                        && report?.hasLayoutAttribution == false && report?.fileTypes.allSatisfy({ $0.storedTarget == nil }) == true
                }
            })
            try await wait("Paged Properties summary") {
                coordinator.pagedSummaryForVerification != nil && !coordinator.hasWork
            }
            guard let result = coordinator.pagedResultForVerification else { throw UIVerification.Failure(message: "Stored Properties result unavailable") }
            try UIVerification.require(reported?.counts?.total == 100000 && reported?.isComplete == true && sawPrefix && prefixSafe,
                "Properties lost its stored summary")
            try UIVerification.require(coordinator.openFullAnalysis(owner: owner, root: root), "Stored handoff refused")
            try await UIVerification.waitUntil("Handed-off stored native page") { coordinator.toolWindow?.pagedReadyForVerification == true }
            try UIVerification.require(coordinator.pagedResultForVerification?.id == result.id && accessCalls == 1
                && coordinator.activePagedSession == nil && coordinator.toolWindow?.preparedFolderCount == 0,
                "Properties handoff rescanned, reacquired access or rebuilt the full tree")
            let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/native-full-capture-" + UUID().uuidString + ".png")
            if let window = coordinator.toolWindow?.window { try await UIVerification.snapshot(window, to: capture) }
            let read = Task { try await result.groups(.projects) }
            coordinator.toolWindow?.close()
            await coordinator.stopAndDrain(); _ = try? await read.value
            await result.waitUntilReadersDrained()
            try UIVerification.require(!coordinator.hasWork && result.activeReaderCount == 0
                && coordinator.pagedResultForVerification == nil && ApplicationFileActivity.gate.activeCount == 0,
                "Close released a live reader or retained stale analysis work")
            checks += ["Properties committed-prefix counts/types without drill authority", "Properties summary", "same-handle no-rescan handoff", "native page bound", "close and actual reader drain"]
        }
        do {
            let owner = UUID()
            coordinator.analyzeProperties(owner: owner, root: root, access: { "Generated corpus only" }, onChange: { _, _ in })
            try await wait("First stored progress before Stop") {
                coordinator.pagedUpdateForVerification?.provisionalFileTypes != nil
            }
            let stopped = ProcessInfo.processInfo.systemUptime
            coordinator.stopProperties(owner: owner)
            try await wait("Stopped stored summary", seconds: 3) {
                coordinator.pagedSummaryForVerification != nil && !coordinator.hasWork
            }
            try UIVerification.require(coordinator.pagedUpdateForVerification?.status == .cancelled
                && coordinator.pagedSummaryForVerification?.complete == false
                && ProcessInfo.processInfo.systemUptime - stopped <= 2, "Stop lost or mislabelled its committed prefix")
            coordinator.closeProperties(owner: owner); await coordinator.stopAndDrain()
            checks += ["Stop retains incomplete committed prefix", "Properties close drains without a hidden queue"]
        }
        do {
            // Exercise real owned-store disposal; previous failed/test stores
            // remain untouched. This small catalog deliberately reaches quota.
            let ephemeral = try AnalysisResultStorage(directory: storage.directory, sessionByteLimit: 4 << 20)
            let scanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"), activityGate: ApplicationFileActivity.gate)
            var discarded: URL?
            weak var released: StorageAnalysisResult?
            var retainedClosedBrowser: PagedAnalysisBrowserModel?
            do {
                let session = try scanner.startPaged(root: root, storage: ephemeral, retainingAccess: "Generated corpus only")
                var terminal: PagedStorageScanUpdate?
                for await update in session.updates { if update.workerDrained { terminal = update } }
                await session.waitUntilDrained()
                guard let result = terminal?.result else { throw UIVerification.Failure(message: "Disposable quota result unavailable") }
                released = result
                discarded = storage.directory.appendingPathComponent("session-" + result.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
                let summary = try await result.summary()
                try UIVerification.require(!summary.complete && summary.value.counts.total > 0, "Quota result was not an honest committed prefix")
                retainedClosedBrowser = PagedAnalysisBrowserModel(result: result, title: "Generated retained closed view")
                retainedClosedBrowser?.close()
                await result.waitUntilReadersDrained()
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var removed = false
            while !removed, ProcessInfo.processInfo.systemUptime < deadline {
                let path = discarded!
                removed = await Task.detached(priority: .utility) {
                    var value = stat(); return lstat(path.path, &value) != 0 && errno == ENOENT
                }.value
                if !removed { try await Task.sleep(for: .milliseconds(10)) }
            }
            try UIVerification.require(removed && released == nil && retainedClosedBrowser != nil && ApplicationFileActivity.gate.activeCount == 0,
                "Last-view result disposal did not verify, drain and remove its exact owned store")
            checks.append("last-handle verified disposal while a closed browser model remains retained")
        }
        do {
            let shared = ApplicationStorageAnalysis.shared
            shared.enablePagedForQualification(storage: storage)
            let properties = FilePropertiesWindowController(retainAccess: { _ in "Generated corpus only" }, copyPaths: { _ in })
            properties.model.update(urls: [root])
            try await wait("Real Properties metadata") { properties.model.canAnalyzeStorage }
            properties.model.analyzeStorage()
            try await wait("Real Properties progressive File Types") { properties.model.attribution?.isProvisional == true }
            let session = shared.activePagedSession?.id
            try UIVerification.require(session != nil && properties.model.analysisValue?.counts != nil
                && properties.model.analysisValue?.isComplete == false && !properties.model.chartDrill.canBrowse,
                "Properties did not present bounded provisional values before sealing")
            properties.model.openFullAnalysis()
            try UIVerification.require(shared.activePagedSession?.id == session
                && shared.toolWindow?.provisionalBreakdownForVerification == true
                && shared.toolWindow?.chartCanBrowseForVerification == false
                && properties.model.attribution == nil, "Live handoff rescanned or retained stale provisional authority")
            let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/native-progressive-product-" + UUID().uuidString + ".png")
            if let window = shared.toolWindow?.window { try await UIVerification.snapshot(window, to: capture) }
            properties.close()
            try await wait("Handed-off scan finished") { shared.pagedSummaryForVerification != nil && !shared.hasWork }
            try UIVerification.require(shared.pagedResultForVerification?.id == session
                && shared.toolWindow?.provisionalBreakdownForVerification == false
                && shared.toolWindow?.chartCanBrowseForVerification == true,
                "Closing old Properties stopped the shared scan or final totals stayed provisional")
            shared.toolWindow?.close(); await shared.stopAndDrain()
            checks += ["real Properties early File Types", "live same-session handoff", "old Properties close preserves continuation", "sealed result replaces provisional chart"]
        }
        do {
            let mixed = try await StorageAnalysisScaleVerification.admittedSource("mixed")
            let firstOwner = UUID(), nextOwner = UUID()
            var switched = false, latePrefix = false
            coordinator.analyzeProperties(owner: firstOwner, root: root, access: { "Generated corpus only" }, onChange: { _, report in
                if switched && report?.isProvisional == true { latePrefix = true }
            })
            try await wait("First session prefix before replacement") { coordinator.pagedUpdateForVerification?.provisionalFileTypes != nil }
            let firstSession = coordinator.activePagedSession?.id
            switched = true
            coordinator.analyzeProperties(owner: nextOwner, root: mixed, access: { "Generated corpus only" }, onChange: { _, _ in })
            try await wait("Replacement session sealed") { coordinator.currentRoot == mixed && coordinator.pagedSummaryForVerification != nil && !coordinator.hasWork }
            try UIVerification.require(!latePrefix && coordinator.pagedUpdateForVerification?.session != firstSession
                && coordinator.pagedSummaryForVerification?.value.counts.total == 99392,
                "A retired prefix overwrote the replacement source or session")
            coordinator.closeProperties(owner: nextOwner); await coordinator.stopAndDrain()
            checks.append("replaced session rejects stale provisional reports")
        }
        checks += try await StoragePrefixVerification.ordinaryCompatibility(root: root, storage: storage)
        return ["passed": true, "checks": checks, "gate_active": ApplicationFileActivity.gate.activeCount,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began]
    }
    static func topology() async throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        let gate = FileActivityGate(), discovery = StartupVolumeDiscovery(activityGate: gate)
        let plan = try await discovery.discover()
        try await discovery.revalidate(plan)
        try UIVerification.require(plan.systemRoot.path == "/" && plan.dataRoot != plan.systemRoot
            && gate.activeCount == 0, "Startup root observation or actual-tool drain changed")
        return ["passed": true, "scope": "Read-only Apple topology and two native root metadata inquiries; no traversal or personal result catalog",
            "source_roots": 2, "active_snapshot": plan.snapshotBased, "fresh_native_root_checks": true,
            "fresh_tool_membership_checks": true, "gate_active": gate.activeCount,
            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began]
    }
    static func run(name: String, lane: String, stop: Bool, appData: Bool = false) async throws -> [String: Any] {
        try UIVerification.require(["wide", "mixed"].contains(name) && ["paged", "memory"].contains(lane), "Invalid analysis case")
        let root = try await StorageAnalysisScaleVerification.admittedSource(name)
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        try UIVerification.require(!appData || lane == "paged", "Application-data qualification requires stored results")
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 64 << 20, preserveAfterClose: !appData)
        let scanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"), activityGate: ApplicationFileActivity.gate)
        let window = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        window.showWindow(nil)
        defer { window.close() }
        let began = ProcessInfo.processInfo.systemUptime
        var memoryStages: [String: [String: UInt64]] = ["before_scan": resources()]
        var first: Double?, workerPeak: UInt64 = 0, entries: UInt64 = 0
        var heartbeat: [Double] = [], lastTick = began
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                if heartbeat.count < 10000 { heartbeat.append(now - lastTick) }; lastTick = now
            }
        }
        defer { timer.invalidate() }
        var finalComplete = false, stopAt: Double?, extra: [String: Any] = [:], ownedID: UUID?
        if lane == "paged" {
            let session = try scanner.startPaged(root: root, storage: storage, metadataPolicy: appData ? .applicationData : .standard, retainingAccess: "Generated corpus only")
            var terminal: PagedStorageScanUpdate?
            for await update in session.updates {
                if update.committedEntries > 0 && first == nil { first = ProcessInfo.processInfo.systemUptime - began }
                if stop && update.committedEntries > 0 && stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime; session.cancel() }
                window.renderPaged(root: root, update: update)
                if update.workerDrained { terminal = update }
            }
            await session.waitUntilDrained()
            guard let terminal, let result = terminal.result else { throw UIVerification.Failure(message: "Paged session produced no sealed result: \(String(describing: terminal?.status))") }
            memoryStages["after_worker"] = resources()
            let summary = try await result.summary()
            ownedID = result.id
            try UIVerification.require(result.metadataPolicy == (appData ? .applicationData : .standard), "Result policy changed after scan")
            extra["metadata_policy"] = result.metadataPolicy.rawValue
            memoryStages["after_summary"] = resources()
            let report = try await result.attribution(scopeName: root.lastPathComponent, summary: summary)
            entries = summary.value.counts.total; workerPeak = terminal.workerPeakResidentBytes ?? 0; finalComplete = summary.complete
            memoryStages["after_attribution"] = resources()
            window.renderPaged(root: root, update: terminal, summary: summary, report: report)
            try await UIVerification.waitUntil("First bounded native page") { window.pagedReadyForVerification }
            try UIVerification.require(window.pagedRowCountForVerification <= 256 && window.preparedFolderCount == 0,
                "Paged UI rebuilt a complete snapshot or exceeded its visible-page bound")
            let displaySeconds = ProcessInfo.processInfo.systemUptime - began
            memoryStages["after_native_display"] = resources()
            if stop {
                try UIVerification.require(terminal.status == .cancelled && !summary.complete && entries % 1024 == 0,
                    "Stop did not preserve the committed incomplete prefix")
            } else {
                try UIVerification.require(entries == (name == "wide" ? 100000 : 99392) && summary.complete == (name == "wide"), "Stored source coverage changed")
                window.openFirstPagedFolderForVerification()
                try await UIVerification.waitUntil("Stored folder page") { window.pagedReadyForVerification && window.pagedRowCountForVerification == 256 }
                window.nextPagedForVerification()
                try await UIVerification.waitUntil("Second stored page") { window.pagedReadyForVerification && window.pagedRowCountForVerification == 256 }
                let read = Task { try await result.page(parent: 0) }
                read.cancel(); _ = try? await read.value
                await result.waitUntilReadersDrained()
                try UIVerification.require(result.activeReaderCount == 0 && ApplicationFileActivity.gate.activeCount == 0,
                    "Stored reader released actual process ownership too soon")
                extra["navigation_and_reader_drain"] = true
            }
            extra["display_seconds"] = displaySeconds
            extra["temporary_store"] = try await storeUsage(storage, id: result.id)
            extra["visible_rows"] = window.pagedRowCountForVerification
            extra["snapshot_folders"] = window.preparedFolderCount
        } else {
            let session = try scanner.start(root: root, retainingAccess: "Generated corpus only")
            var terminal: StorageScanUpdate?
            for await update in session.updates {
                if (update.progress?.acceptedCounts.total ?? 0) > 0 && first == nil { first = ProcessInfo.processInfo.systemUptime - began }
                window.render(root: root, update: update)
                if update.workerDrained { terminal = update }
            }
            await session.waitUntilDrained()
            guard let terminal, let snapshot = terminal.snapshot else { throw UIVerification.Failure(message: "Memory reference did not finish") }
            let report = try await Task.detached(priority: .utility) { try AnalysisAttributionReport.make(snapshot, scopePath: root.path) }.value
            window.showAttribution(report)
            try await UIVerification.waitUntil("Reference native folder rows") { !window.isPreparingRows && window.preparedFolderCount == snapshot.folders.count }
            entries = snapshot.root.counts.total; workerPeak = terminal.workerPeakResidentBytes ?? 0; finalComplete = snapshot.isComplete
            extra["display_seconds"] = ProcessInfo.processInfo.systemUptime - began
            extra["visible_rows"] = window.allocatedFolderItemCount
        }
        window.window?.contentView?.layoutSubtreeIfNeeded(); window.window?.displayIfNeeded()
        timer.invalidate()
        let sorted = heartbeat.sorted(), ended = ProcessInfo.processInfo.systemUptime
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        var record: [String: Any] = ["passed": true, "case": name, "lane": lane, "stop": stop,
            "entries": entries, "complete": finalComplete, "worker_peak_bytes": workerPeak,
            "parent_process_peak_bytes": usage.ru_maxrss,
            "elapsed_seconds": ended - began,
            "first_observation_seconds": first as Any? ?? NSNull(),
            "stop_seconds": stopAt.map { ended - $0 } as Any? ?? NSNull(),
            "heartbeat_samples": sorted.count, "heartbeat_max_seconds": sorted.last ?? 0,
            "heartbeat_p99_seconds": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99))],
            "gate_active": ApplicationFileActivity.gate.activeCount]
        memoryStages["after_navigation"] = resources()
        record["memory_stages"] = memoryStages
        record.merge(extra) { _, new in new }
        if appData, let ownedID {
            let ownedFolder = storage.directory.appendingPathComponent("session-" + ownedID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
            let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/native-policy-" + UUID().uuidString + ".png")
            if let native = window.window { try await UIVerification.snapshot(native, to: capture); record["capture"] = capture.lastPathComponent }
            window.close()
            try await waitForDisposal(ownedFolder)
            record["owned_store_disposed"] = true
            record["actual_private_application_data_scanned"] = false
        }
        return record
    }
    private static func resources() -> [String: UInt64] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        return ["current_rss": result == KERN_SUCCESS ? info.resident_size : 0, "peak_rss": UInt64(usage.ru_maxrss)]
    }

}
#endif
