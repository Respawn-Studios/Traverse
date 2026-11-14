#if DEBUG
import AppKit
import CoreServices
@_spi(Qualification) import FileOperations
import LocalStorage

/// The ordinary archive table/provider/owner with an independent receiver.
/// This development app is not a sandbox-distribution qualification.
@MainActor enum ArchivePromiseGestureVerification {
    static func report(_ event: String, _ values: [String: Any] = [:]) {
        guard let value = try? JSONSerialization.data(withJSONObject: ["event": event, "values": values], options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("TRAVERSE_PROMISE ".utf8) + value + Data([10]))
    }
    static func run() async {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development", isDirectory: true),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              ["native-archive-promise-gesture", "native-archive-promise-finder"].contains(marker["action"] as? String ?? ""),
              let inputs = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("inputs.json"))) as? [String: Any],
              let kind = inputs["kind"] as? String, ["file", "folder"].contains(kind) else { exit(2) }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false; settings.navigationStyle = .glass; settings.glassFileContent = true
        ArchivePromiseExportFeature.qualifying = true; ArchivePromiseExportFeature.requiresParentGrantForVerification = true
        let publicPublication = inputs["publicPublication"] as? Bool == true
        ArchivePromiseExportFeature.qualifyingPublications = publicPublication
        ArchivePromiseExportFeature.expectedParentForGestureVerification = root.appendingPathComponent("source/Destination", isDirectory: true)
        let owner = BrowserWindowController(settings: settings), browser = owner.browser
        let journal = root.appendingPathComponent("state/history", isDirectory: true)
        let engine = RecoverableFileOperations(journalDirectory: journal, activity: ApplicationFileActivity.beginOperation,
            zipOneFilePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
            zipTreePublicExtractionPolicy: publicPublication ? .sourceQualification : .held)
        browser.recoverableFileOperations = engine; browser.permitsBackgroundVerification = true
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        browser.folderAccess = FolderAccessController()
        var passed = false, stage = "open-source", identifier: UUID?
        do {
            let source = root.appendingPathComponent("source/Source/Generated.zip")
            if publicPublication {
                // Only this explicit disposable source gets a documented test
                // property. No raw flags are authored or compared.
                try await Task.detached {
                    var url = source, values = URLResourceValues()
                    values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Traverse generated fixture",
                        kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                        kLSQuarantineTimeStampKey as String: Date()]
                    try url.setResourceValues(values)
                    guard try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else {
                        throw FileOperationFailure.unsupported
                    }
                }.value
                report("source-property-observed", ["documentedPropertyPresent": true, "rawFlagsCompared": false])
            }
            let selected = await browser.folderAccess.acceptChosenFolder(source.deletingLastPathComponent()); selected?.lease.close()
            owner.window?.setFrameOrigin(.init(x: -12_000, y: -12_000))
            owner.beginBrowsing(); try await wait { owner.workspace.sessionReady }
            browser.navigate(to: .directory(source.deletingLastPathComponent()))
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            ApplicationZIPBrowser.shared.show(source, from: browser)
            guard let archive = ApplicationZIPBrowser.shared.controller, let window = archive.window else { throw FileOperationFailure.unavailable }
            let model = archive.model
            model.memberDragHandoffForVerification = { export in
                report("gesture-admitted", ["providers": export.roots.count, "ordinaryArchiveRows": true])
                var reported = false
                export.onSettledForVerification = { [weak export] in
                    guard !reported, let export else { return }; reported = true
                    if export.completedForVerification == 1, let record = export.outcomesForVerification.first?.recordID {
                        report("write-completed", ["ordinaryArchiveRows": true, "recordID": record.uuidString])
                    } else { report("failed", ["stage": "promise-request", "completed": export.completedForVerification]) }
                }
            }
            try await wait { !model.isLoading && !model.isPaging && model.viewIsCurrent }
            guard let folder = model.visibleItems.first(where: { $0.name == "Archive" })?.folder else { throw ZIPArchiveFailure.invalidFolder }
            model.navigate(folder)
            try await wait { !model.isPaging && model.viewIsCurrent && model.breadcrumbs.count == 2 }
            let name = kind == "file" ? "Generated Promise.txt" : "Generated Folder"
            guard let item = model.visibleItems.first(where: { $0.name == name }) else { throw ZIPArchiveFailure.invalidFolder }
            model.selection = [item.id]
            try await wait { model.externalExportReady && model.rowsForVerification?.selectedIDs == [item.id] }
            let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1_440, height: 900)
            window.setFrame(.init(x: screen.minX + 24, y: screen.midY - 310,
                width: min(860, screen.width * 0.62), height: min(620, screen.height - 80)), display: true)
            window.title = "Generated ZIP drag-out · " + root.lastPathComponent.prefix(8)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            stage = "waiting-for-human-drag"
            report("ready", ["source": true, "ordinaryArchiveRows": true, "kind": kind, "exactDestinationGrantAfterDrop": true])
            // The parent sends a closed control and EOF. Reading never blocks
            // the UI actor, and the actual child task is awaited before exit.
            let control = await Task.detached(priority: .utility) {
                try? FileHandle.standardInput.read(upToCount: 32)
            }.value
            guard control == Data("finish\n".utf8) else { throw CancellationError() }
            stage = "actual-export-drain"
            guard let export = model.lastHandedExportForVerification else { throw FileOperationFailure.invalidRequest }
            await export.drain()
            if let inspection = browser.recoveryInspectionTask { await inspection.value }
            try await wait { browser.operationCoordinator.inspectionCount == 0 }
            guard export.drainedForVerification, export.completedForVerification == 1,
                  export.outcomesForVerification.count == 1, export.parentChoicesForVerification == 1,
                  let outcome = export.outcomesForVerification.first, outcome.result.disposition == .succeeded,
                  let id = outcome.recordID else { throw FileOperationFailure.ioFailure }
            identifier = id
            let history = try await engine.inspectExistingHistory()
            guard history.records.first(where: { $0.id == id })?.operation == "Extract ZIP" else { throw FileOperationFailure.invalidRequest }
            if publicPublication {
                let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                guard catalog.version == (kind == "file" ? 15 : 16), catalog.requiresPublicQuarantine else {
                    throw FileOperationFailure.invalidRequest
                }
                let destination = root.appendingPathComponent("source/Destination", isDirectory: true)
                let count = try await Task.detached {
                    let nodes = kind == "file" ? ["Generated Promise.txt"] : ["Generated Folder", "Generated Folder/Report.txt",
                        "Generated Folder/Deep", "Generated Folder/Deep/More.txt", "Generated Folder/Empty"]
                    for node in nodes {
                        guard try destination.appendingPathComponent(node).resourceValues(forKeys: [.quarantinePropertiesKey])
                            .quarantineProperties?.isEmpty == false else { throw FileOperationFailure.unsupported }
                    }
                    return nodes.count
                }.value
                report("publication-contract", ["version": catalog.version, "requiresDocumentedProperty": true,
                    "observedNodes": count, "documentedPropertyPresent": true])
            }
            report("publication-acknowledged", ["recordID": id.uuidString, "oneParentChooser": true, "ordinaryArchiveRows": true])
            stage = "cold-undo"
            let cold = RecoverableFileOperations(journalDirectory: journal, activity: ApplicationFileActivity.beginOperation,
                zipOneFilePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
                zipTreePublicExtractionPolicy: publicPublication ? .sourceQualification : .held)
            let undone = await cold.undo(recordID: id)
            guard undone.result.disposition == .succeeded else { throw FileOperationFailure.ioFailure }
            passed = true
            report("undo-completed", ["succeeded": true, "coldEngine": true, "activity": ApplicationFileActivity.gate.activeCount])
        } catch {
            let value = error as NSError
            var fields: [String: Any] = ["stage": stage, "domain": value.domain, "code": value.code]
            if let value = error as? FileOperationFailure { fields["failure"] = value.rawValue }
            report("failed", fields)
        }
        await ApplicationArchiveExports.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing(); if let listing = browser.listingTask { await listing.value }
        await owner.flushSession(); owner.window?.close()
        ArchivePromiseExportFeature.qualifying = false; ArchivePromiseExportFeature.requiresParentGrantForVerification = false
        ArchivePromiseExportFeature.qualifyingPublications = false
        ArchivePromiseExportFeature.expectedParentForGestureVerification = nil
        let drained = ApplicationArchiveExports.shared.countForVerification == 0 && ApplicationFileActivity.gate.activeCount == 0
        var fields: [String: Any] = ["passed": passed && drained, "drained": drained,
            "ordinaryArchiveRows": true, "sandboxDistribution": false, "kind": kind, "publicPublication": publicPublication]
        if let identifier { fields["recordID"] = identifier.uuidString }
        report("source-finished", fields)
        NSApp.terminate(nil)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw FileOperationFailure.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
