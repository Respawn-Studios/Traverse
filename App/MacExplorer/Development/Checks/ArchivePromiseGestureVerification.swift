#if DEBUG
import AppKit
import CoreServices
import Darwin
@_spi(Qualification) import FileOperations
import LocalStorage

/// The ordinary archive table/provider/owner with an independent receiver.
/// This development app is not a sandbox-distribution qualification.
@MainActor enum ArchivePromiseGestureVerification {
    @MainActor private enum Catalog {
        case zip(ArchiveBrowserModel), tar(TARBrowserModel)
        var ready: Bool {
            switch self {
            case .zip(let model): !model.isLoading && !model.isPaging && model.viewIsCurrent
            case .tar(let model): !model.busy && model.current
            }
        }
        var export: ArchivePromiseExport? {
            switch self {
            case .zip(let model): model.lastHandedExportForVerification
            case .tar(let model): model.lastHandedExportForVerification
            }
        }
        func onHandoff(_ action: @escaping (ArchivePromiseExport) -> Void) {
            switch self {
            case .zip(let model): model.memberDragHandoffForVerification = action
            case .tar(let model): model.memberDragHandoffForVerification = action
            }
        }
        func enterFolder() async throws {
            try await wait { ready }
            switch self {
            case .zip(let model):
                guard let folder = model.visibleItems.first(where: { $0.name == "Archive" })?.folder else { throw ZIPArchiveFailure.invalidFolder }
                model.navigate(folder)
                try await wait { ready && model.breadcrumbs.count == 2 }
            case .tar(let model):
                guard let folder = model.items.first(where: { $0.name == "Archive" })?.folder else { throw TARArchiveFailure.invalidSelection }
                model.visit(folder)
                try await wait { ready && model.breadcrumbs.count == 2 }
            }
        }
        func select(_ kind: String) async throws {
            let name = kind == "file" ? "Generated Promise.txt" : "Generated Folder"
            switch self {
            case .zip(let model):
                guard let item = model.visibleItems.first(where: { $0.name == name }) else { throw ZIPArchiveFailure.invalidFolder }
                model.selection = [item.id]
                try await wait { model.externalExportReady && model.rowsForVerification?.selectedIDs == [item.id] }
            case .tar(let model):
                guard let item = model.items.first(where: { $0.name == name }) else { throw TARArchiveFailure.invalidSelection }
                model.selection = [item.id]
                try await wait { model.externalExportReady && model.selection == [item.id] }
            }
        }
    }
    static func report(_ event: String, _ values: [String: Any] = [:]) {
        guard let value = try? JSONSerialization.data(withJSONObject: ["event": event, "values": values], options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("TRAVERSE_PROMISE ".utf8) + value + Data([10]))
    }
    private static func verifyColdUndo(root: URL, destination: URL, engine: RecoverableFileOperations,
                                       format: String, prefix: UUID? = nil) async {
        var failure: [String: Any] = [:], undone: [String] = []
        do {
            let ids: [UUID], kinds: [String]
            if let prefix { ids = [prefix]; kinds = ["file"] }
            else {
                let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf:
                    root.appendingPathComponent("evidence/native-archive-promise-gesture.json"))) as? [String: Any]
                let raw = receipt?["recordIDs"] as? [String] ?? []
                kinds = receipt?["completedKinds"] as? [String] ?? []
                ids = raw.compactMap(UUID.init(uuidString:))
                guard receipt?["passed"] as? Bool == true, receipt?["archiveFormat"] as? String == format,
                      raw.count == ids.count, [["file"], ["folder"], ["file", "folder"]].contains(kinds),
                      ids.count == kinds.count, Set(ids).count == ids.count else { throw FileOperationFailure.invalidRequest }
            }
            let history = try await engine.inspectExistingHistory()
            for index in ids.indices.reversed() {
                let id = ids[index], kind = kinds[index]
                guard history.records.contains(where: { $0.id == id && $0.operation == (format == "zip" ? "Extract ZIP" : "Extract TAR") }) else {
                    throw FileOperationFailure.invalidRequest
                }
                let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                guard catalog.version == (kind == "file" ? (format == "zip" ? 15 : 17) : 16), catalog.requiresPublicQuarantine else {
                    throw FileOperationFailure.invalidRequest
                }
                let result = await engine.undo(recordID: id)
                guard result.result.disposition == .succeeded else { throw FileOperationFailure.ioFailure }
                let leaf = destination.appendingPathComponent(kind == "file" ? "Generated Promise.txt" : "Generated Folder")
                guard await Task.detached(operation: {
                    var facts = stat()
                    return Darwin.lstat(leaf.path, &facts) == -1 && errno == ENOENT
                }).value else {
                    throw FileOperationFailure.destinationChanged
                }
                undone.append(kind)
                report("undo-completed", ["recordID": id.uuidString, "kind": kind, "coldProcess": true, "succeeded": true])
            }
        } catch {
            let error = error as NSError
            failure = ["domain": error.domain, "code": error.code]
        }
        let spoolsDrained = await ApplicationCompressedArchives.shared.closeAndDrain()
        let drained = spoolsDrained && ApplicationFileActivity.gate.activeCount == 0
        let name = prefix == nil ? "native-archive-promise-cold.json" : "native-archive-promise-prefix-undo.json"
        let fields: [String: Any] = ["passed": failure.isEmpty && drained, "archiveFormat": format,
            "drained": drained, "spoolsDrained": spoolsDrained, "coldProcess": true, "undoneKinds": undone, "failure": failure]
        try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/" + name), options: .withoutOverwriting)
        report("cold-finished", fields)
    }
    static func run() async {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development", isDirectory: true),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              ["native-archive-promise-gesture", "native-archive-promise-finder", "native-archive-export-finder"].contains(marker["action"] as? String ?? ""),
              let inputs = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("inputs.json"))) as? [String: Any],
              let kind = inputs["kind"] as? String, ["file", "folder", "both"].contains(kind) else { exit(2) }
        let format = inputs["archiveFormat"] as? String ?? "zip"
        guard ["zip", "tar", "tar.gz", "tar.bz2"].contains(format) else { exit(2) }
        TARPromiseExportFeature.qualifying = format != "zip"
        let destinationName = inputs["destinationName"] as? String ?? "Destination"
        guard destinationName == "Destination" || destinationName == "Finder Destination " + root.lastPathComponent.prefix(8) else { exit(2) }
        let destination = root.appendingPathComponent("source/" + destinationName, isDirectory: true)
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false; settings.navigationStyle = .glass; settings.glassFileContent = true
        ArchivePromiseExportFeature.qualifying = true
        let requiresGrant = inputs["directAccess"] as? Bool != true
        ArchivePromiseExportFeature.requiresParentGrantForVerification = requiresGrant
        let publicPublication = inputs["publicPublication"] as? Bool == true
        guard format == "zip" || publicPublication else { exit(2) }
        ArchivePromiseExportFeature.qualifyingPublications = publicPublication
        ApplicationCompressedArchives.shared.cacheDirectoryForVerification = root.appendingPathComponent("cache")
        ArchivePromiseExportFeature.expectedParentForGestureVerification = destination
        let owner = BrowserWindowController(settings: settings), browser = owner.browser
        let journal = root.appendingPathComponent("state/history", isDirectory: true)
        let engine = RecoverableFileOperations(journalDirectory: journal, activity: ApplicationFileActivity.beginOperation,
            zipOneFilePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
            tarOneFilePublicExtractionPolicy: format != "zip" ? .sourceQualification : .held,
            zipTreePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
            tarTreePublicExtractionPolicy: format != "zip" ? .sourceQualification : .held)
        browser.recoverableFileOperations = engine; browser.permitsBackgroundVerification = true
        browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        browser.folderAccess = FolderAccessController()
        let arguments = ProcessInfo.processInfo.arguments
        var prefix: UUID?
        if let index = arguments.firstIndex(of: "--archive-export-undo-prefix") {
            guard arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) else { exit(2) }
            prefix = id
        }
        if prefix != nil || arguments.contains("--archive-export-cold-undo") {
            await verifyColdUndo(root: root, destination: destination, engine: engine, format: format, prefix: prefix)
            owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
            NSApp.terminate(nil); return
        }
        var passed = false, stage = "open-source", identifier: UUID?, completedKinds: [String] = [], recordIDs: [UUID] = []
        do {
            let source = root.appendingPathComponent("source/Source/Generated." + format)
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
            let model: Catalog, window: NSWindow
            if format == "zip" {
                ApplicationZIPBrowser.shared.show(source, from: browser)
                guard let archive = ApplicationZIPBrowser.shared.controller, let current = archive.window else { throw FileOperationFailure.unavailable }
                model = .zip(archive.model); window = current
            } else {
                ApplicationTARBrowser.shared.show(source, from: browser)
                guard let archive = ApplicationTARBrowser.shared.controller, let current = archive.window else { throw FileOperationFailure.unavailable }
                if format != "tar" { archive.model.open(source, from: browser, preparesCompressed: true) }
                model = .tar(archive.model); window = current
            }
            model.onHandoff { export in
                report("gesture-admitted", ["providers": export.rootCount, "ordinaryArchiveRows": true])
                var reported = false
                export.onSettledForVerification = { [weak export] in
                    guard !reported, let export else { return }; reported = true
                    if export.completedForVerification == 1, let record = export.outcomesForVerification.first?.recordID {
                        report("write-completed", ["ordinaryArchiveRows": true, "recordID": record.uuidString,
                            "parentChoices": export.parentChoicesForVerification, "nativeCallback": true])
                    } else {
                        var failure: [String: Any] = ["stage": "promise-request", "completed": export.completedForVerification,
                            "callbacks": export.callbacksForVerification, "checkpoint": export.checkpointForVerification,
                            "callbackShape": export.callbackShapeForVerification]
                        if let issue = export.failureForVerification { failure["issue"] = issue }
                        if let operation = export.nativeDragEndOperationForVerification { failure["nativeEndOperation"] = operation }
                        if let point = export.nativeDragEndPointForVerification { failure["nativeEndPoint"] = point }
                        report("failed", failure)
                    }
                }
            }
            try await model.enterFolder()
            let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1_440, height: 900)
            window.setFrame(.init(x: screen.minX + 24, y: screen.midY - 310,
                width: min(860, screen.width * 0.62), height: min(620, screen.height - 80)), display: true)
            window.title = "Generated " + format.uppercased() + " drag-out · " + root.lastPathComponent.prefix(8)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for kind in kind == "both" ? ["file", "folder"] : [kind] {
                try await model.select(kind)
                stage = "waiting-for-human-drag"
                report("ready", ["source": true, "ordinaryArchiveRows": true, "kind": kind, "exactDestinationGrantAfterDrop": requiresGrant,
                    "screen": window.screen?.localizedName ?? "Unavailable",
                    "windowFrame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                    "screenFrame": window.screen.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? []])
                // The parent sends one bounded control per drag. Reading never blocks
                // the UI actor, and the actual child task is awaited before exit.
                let control = await Task.detached(priority: .utility) {
                    try? FileHandle.standardInput.read(upToCount: 7)
                }.value
                guard control == Data("finish\n".utf8) else { throw CancellationError() }
                stage = "actual-export-drain"
                guard let export = model.export else { throw FileOperationFailure.invalidRequest }
                await export.drain()
                if let inspection = browser.recoveryInspectionTask { await inspection.value }
                try await wait { browser.operationCoordinator.inspectionCount == 0 }
                guard export.drainedForVerification, export.completedForVerification == 1,
                      export.outcomesForVerification.count == 1, export.parentChoicesForVerification == (requiresGrant ? 1 : 0),
                      let outcome = export.outcomesForVerification.first, outcome.result.disposition == .succeeded,
                      let id = outcome.recordID else { throw FileOperationFailure.ioFailure }
                identifier = id
                let history = try await engine.inspectExistingHistory()
                guard history.records.first(where: { $0.id == id })?.operation == (format == "zip" ? "Extract ZIP" : "Extract TAR") else { throw FileOperationFailure.invalidRequest }
                if publicPublication {
                    let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                    guard catalog.version == (kind == "file" ? (format == "zip" ? 15 : 17) : 16), catalog.requiresPublicQuarantine else {
                        throw FileOperationFailure.invalidRequest
                    }
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
                report("publication-acknowledged", ["recordID": id.uuidString, "parentChoices": export.parentChoicesForVerification, "ordinaryArchiveRows": true])
                recordIDs.append(id)
                completedKinds.append(kind)
            }
            passed = true
        } catch {
            let value = error as NSError
            var fields: [String: Any] = ["stage": stage, "domain": value.domain, "code": value.code]
            if let value = error as? FileOperationFailure { fields["failure"] = value.rawValue }
            report("failed", fields)
        }
        await ApplicationArchiveExports.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        await ApplicationTARBrowser.shared.closeAndDrain()
        let spoolsDrained = await ApplicationCompressedArchives.shared.closeAndDrain()
        ApplicationCompressedArchives.shared.cacheDirectoryForVerification = nil
        owner.suspendBrowsing(); if let listing = browser.listingTask { await listing.value }
        await owner.flushSession(); owner.window?.close()
        ArchivePromiseExportFeature.qualifying = false; ArchivePromiseExportFeature.requiresParentGrantForVerification = false
        TARPromiseExportFeature.qualifying = false
        ArchivePromiseExportFeature.qualifyingPublications = false
        ArchivePromiseExportFeature.expectedParentForGestureVerification = nil
        let drained = spoolsDrained && ApplicationArchiveExports.shared.countForVerification == 0 && ApplicationFileActivity.gate.activeCount == 0
        var fields: [String: Any] = ["passed": passed && drained, "drained": drained,
            "ordinaryArchiveRows": true, "sandboxDistribution": false, "kind": kind, "publicPublication": publicPublication,
            "archiveFormat": format, "spoolsDrained": spoolsDrained, "completedKinds": completedKinds,
            "recordIDs": recordIDs.map(\.uuidString), "retainedForColdUndo": true]
        if let identifier { fields["recordID"] = identifier.uuidString }
        if !passed { fields["failureStage"] = stage }
        try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/native-archive-promise-gesture.json"), options: .withoutOverwriting)
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
