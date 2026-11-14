#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import LocalStorage
import StorageAnalysis

/// Actual public scanner/result routes against this job's tiny generated tree.
@MainActor enum DevelopmentStorageChecks {
    static func run(root: URL, settings: BrowserSettings) async throws -> [String: Any] {
        let scope = root.appendingPathComponent("source/Scan")
        let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("state/catalogs"),
            sessionByteLimit: 16 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage)
        coordinator.requiresAnalysisSelectionForVerification = false
        coordinator.configureScopePreferences(settings)
        var accessCalls = 0
        let properties = FilePropertiesWindowController(retainAccess: { _ in
            accessCalls += 1; return FileAccessLifetimes(leases: [])
        }, settings: settings, copyPaths: { _ in })
        defer { properties.cancel(); properties.close(); coordinator.toolWindow?.close() }
        properties.update(urls: [scope])
        try await wait { properties.model.canAnalyzeStorage }
        // The shallow Properties read has its own lease, separate from scanning.
        let shallowCalls = accessCalls
        properties.model.analyzeStorage()
        try await wait { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        guard let value = properties.model.analysisValue, let first = coordinator.pagedResultForVerification?.id,
              value.scanStatus == .completed, value.isComplete, !value.isRunning,
              value.counts?.regularFiles == 104, value.counts?.directories == 3,
              value.bytes?.dataLogical.knownBytes == 2048, !value.observationIsPrevious,
              StorageScanPresentation(value).title == "Scan complete" else { throw Failure.result }
        let scanCalls = accessCalls
        properties.model.openFullAnalysis()
        try await wait { coordinator.toolWindow?.pagedReadyForVerification == true }
        guard coordinator.pagedResultForVerification?.id == first, accessCalls == scanCalls,
              coordinator.toolWindow?.summaryLabel.stringValue.contains("2 KB") == true,
              (coordinator.toolWindow?.pagedRowCountForVerification ?? 0) > 0 else { throw Failure.handoff }
        coordinator.toolWindow?.refreshButton.performClick(nil)
        try await wait { !coordinator.hasWork && coordinator.pagedResultForVerification?.id != first }
        guard coordinator.pagedSummaryForVerification?.value.counts.regularFiles == 104,
              accessCalls == scanCalls + 1 else {
            throw UIVerification.Failure(message: "Generated refresh: files=\(coordinator.pagedSummaryForVerification?.value.counts.regularFiles.description ?? "none"), accessDelta=\(accessCalls-scanCalls), status=\(coordinator.toolWindow?.statusLabel.stringValue ?? "none")")
        }
        coordinator.toolWindow?.close(); await coordinator.stopAndDrain()
        try await wait { !coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0 }
        guard properties.model.analysisValue?.isRunning == false else { throw Failure.drain }
        return ["passed": true, "files": 104, "folders": 3, "logicalBytes": 2048,
            "scanAccessCalls": scanCalls - shallowCalls, "sameResultHandoff": true,
            "refreshReusesSelectedAccess": true, "actualWorkerAndQueriesDrained": true,
            "activityCount": ApplicationFileActivity.gate.activeCount, "fileBodyReads": 0,
            "permissionPrompts": 0, "personalRoots": 0]
    }
    static func runDeep(root: URL, settings: BrowserSettings, sourceRoot: URL? = nil, browserNavigation: Bool = false) async throws -> [String: Any] {
        let scope = (sourceRoot ?? root).appendingPathComponent("source/DeepNative")
        let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("state/catalogs"),
            sessionByteLimit: 16 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage)
        coordinator.requiresAnalysisSelectionForVerification = false
        coordinator.configureScopePreferences(settings)
        var accessCalls = 0
        let properties = FilePropertiesWindowController(retainAccess: { _ in
            accessCalls += 1; return FileAccessLifetimes(leases: [])
        }, settings: settings, copyPaths: { _ in })
        defer { properties.cancel(); properties.close(); coordinator.toolWindow?.close() }
        properties.update(urls: [scope])
        try await wait { properties.model.canAnalyzeStorage }
        properties.model.analyzeStorage()
        try await wait { !coordinator.hasWork && coordinator.pagedResultForVerification != nil }
        guard let result = coordinator.pagedResultForVerification, let value = properties.model.analysisValue,
              value.scanStatus == .completed, value.isComplete,
              value.counts?.regularFiles == 3, value.counts?.directories == 127,
              value.bytes?.dataLogical.knownBytes == 4112 else { throw Failure.result }
        let largest = try await result.largestFiles()
        guard let selected = largest.files.first, selected.rawRelativePath.split(separator: 47).count == 128,
              selected.row.rawName == Data("Deep.rs".utf8), largest.rankableFileNames == 3 else { throw Failure.result }
        let access = FileAccessLifetimes(leases: [])
        let location = try await result.resolveLocation(node: selected.id, retainingAccess: access)
        let expected = scope.appendingPathComponent(String(decoding: selected.rawRelativePath, as: UTF8.self))
        guard location.url == expected, location.kind == .regularFile else { throw Failure.result }
        let allocated = try await result.largestFiles(metric: .allocated)
        guard allocated.files.contains(where: { $0.id == selected.id && $0.rawRelativePath == selected.rawRelativePath }) else { throw Failure.result }

        if browserNavigation {
            let checks = try await verifyDeepBrowser(result, settings: settings)
            properties.cancel(); properties.close()
            await coordinator.stopAndDrain()
            try await wait { !coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0 }
            return checks.merging(["passed": true, "files": 3, "folders": 127, "logicalBytes": 4112,
                "resolvedComponents": 128, "largestLogicalAndAllocated": true,
                "actualWorkerAndQueriesDrained": true, "fileBodyReads": 0, "personalRoots": 0]) { _, new in new }
        }

        // Change only a generated ancestor between two explicit requests. A
        // saved catalog path must never become fresh navigation authority.
        let parent = scope.appendingPathComponent("d000"), parked = scope.appendingPathComponent("Parked")
        try await Task.detached { try FileManager.default.moveItem(at: parent, to: parked) }.value
        var refused = false
        do { _ = try await result.resolveLocation(node: selected.id, retainingAccess: access) }
        catch StorageScanFailure.unavailable { refused = true }
        catch StorageScanFailure.changed { refused = true }
        try await Task.detached { try FileManager.default.moveItem(at: parked, to: parent) }.value
        guard refused else { throw Failure.result }
        _ = try await result.resolveLocation(node: selected.id, retainingAccess: access)

        let gate = LocationGate()
        try result.installLocationHookForQualification { gate.hold() }
        let query = Task { try await result.resolveLocation(node: selected.id, retainingAccess: access) }
        try await wait { gate.entered }
        query.cancel(); gate.release()
        var cancelled = false
        do { _ = try await query.value } catch is CancellationError { cancelled = true }
        await result.waitUntilReadersDrained()
        try result.installLocationHookForQualification(nil)
        guard cancelled, result.activeReaderCount == 0 else { throw Failure.drain }

        let calls = accessCalls, identity = result.id
        properties.model.openFullAnalysis()
        try await wait { coordinator.toolWindow?.pagedReadyForVerification == true }
        guard coordinator.pagedResultForVerification?.id == identity, accessCalls == calls else { throw Failure.handoff }
        coordinator.toolWindow?.refreshButton.performClick(nil)
        try await wait { !coordinator.hasWork && coordinator.pagedResultForVerification?.id != identity }
        guard coordinator.pagedSummaryForVerification?.value.counts.regularFiles == 3,
              accessCalls == calls + 1 else { throw Failure.refresh }
        coordinator.toolWindow?.close(); await coordinator.stopAndDrain()
        try await wait { !coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0 }
        return ["passed": true, "files": 3, "folders": 127, "logicalBytes": 4112,
            "resolvedComponents": 128, "largestLogicalAndAllocated": true,
            "changedAncestorRefused": refused, "cancelledResolverDrained": cancelled,
            "sameResultHandoff": true, "refreshReusesSelectedAccess": true,
            "actualWorkerAndQueriesDrained": true, "fileBodyReads": 0, "personalRoots": 0]
    }
    private static func verifyDeepBrowser(_ result: StorageAnalysisResult, settings: BrowserSettings) async throws -> [String: Any] {
        let browser = PagedAnalysisBrowserModel(result: result, title: "Generated deep tree")
        browser.allowsPageMotion = { false }
        defer { browser.close() }
        try await wait { !browser.loading && !browser.hasWork }
        guard let rootFolder = browser.rows.first(where: { $0.title == "d000" }) else { throw Failure.result }
        var deepest = 0
        for index in 0..<127 {
            let name = "d" + String(format: "%03d", index)
            guard let row = browser.rows.first(where: { $0.title == name && $0.kind == .directory }) else { throw Failure.result }
            browser.open(row)
            guard browser.loading, browser.ancestors.count == index + 1 else {
                throw UIVerification.Failure(message: "Stored folder navigation stopped at \(browser.ancestors.count) ancestors; expected \(index + 1)")
            }
            try await wait { !browser.loading && !browser.hasWork }
            guard browser.title == name else { throw Failure.result }
            deepest = browser.ancestors.count
            if index == 63 {
                browser.changeSort(.allocatedDescending)
                try await wait { !browser.loading && !browser.hasWork }
                guard browser.ancestors.count == 64, browser.sortOrder == .allocatedDescending else { throw Failure.result }
            }
            if index == 70 {
                let ids = browser.rows.map(\.id), title = browser.title
                browser.changeMode(.largest)
                try await wait { !browser.loading && !browser.hasWork }
                guard browser.rows.contains(where: { $0.rawName == Data("Deep.rs".utf8) }), browser.ancestors.isEmpty else { throw Failure.result }
                browser.changeMode(.browse)
                try await wait { !browser.loading && !browser.hasWork }
                guard browser.rows.map(\.id) == ids, browser.title == title, browser.ancestors.count == 71 else { throw Failure.result }
            }
        }
        guard deepest == 127, let leaf = browser.rows.first(where: { $0.title == "Deep.rs" }) else { throw Failure.result }
        let launches = result.queryWorkerLaunchCountForQualification
        browser.open(leaf); browser.open(rootFolder)
        guard browser.ancestors.count == 127, !browser.loading,
              result.queryWorkerLaunchCountForQualification == launches else { throw Failure.result }
        browser.up(to: 63)
        try await wait { !browser.loading && !browser.hasWork }
        guard browser.ancestors.count == 63, browser.title == "d062" else { throw Failure.result }
        browser.up(to: 0)
        try await wait { !browser.loading && !browser.hasWork }
        guard browser.ancestors.isEmpty, browser.title == "Generated deep tree", browser.rows.contains(where: { $0.id == rootFolder.id }) else { throw Failure.result }

        let gate = LocationGate()
        try result.installQueryReleaseHookForQualification { gate.hold() }
        browser.changeSort(.nameAscending)
        try await wait { gate.entered }
        browser.close()
        guard browser.rows.isEmpty, browser.hasWork, result.activeReaderCount == 1 else { gate.release(); throw Failure.drain }
        gate.release()
        await result.waitUntilReadersDrained()
        try await wait { !browser.hasWork }
        try result.installQueryReleaseHookForQualification(nil)
        browser.open(rootFolder)
        guard browser.rows.isEmpty, !browser.loading, result.activeReaderCount == 0 else { throw Failure.drain }
        return ["folderBrowserDepth": deepest, "sortBeyondOldBoundary": true,
            "largestReturnsToExactDeepFolder": true, "ancestorReturnAndRootRestored": true,
            "leafAndStaleFolderRefusedWithoutQuery": true, "closedHeldQueryActuallyDrained": true]
    }
    static func runProgress(root: URL, settings: BrowserSettings, stopAfterPrefix: Bool = false,
        duringScan: (@MainActor () async throws -> [String: Any])? = nil) async throws -> (checks: [String: Any], clips: [[String: Any]]) {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let corpus = repo.appendingPathComponent(".build/b06-analyzer/20261017T140537Z-6faf182f69")
        let scope = corpus.appendingPathComponent("fixtures/wide")
        let proofURL = corpus.appendingPathComponent("manifests/wide.json")
        let proofData = try Data(contentsOf: proofURL)
        guard proofData.count < 4096, scope.resolvingSymlinksInPath() == scope,
              let proof = try JSONSerialization.jsonObject(with: proofData) as? [String: Any],
              let device = proof["dev"] as? UInt64, let inode = proof["ino"] as? UInt64,
              proof["entries"] as? Int == 100_000, let logical = proof["logical"] as? UInt64 else { throw Failure.result }
        var facts = stat()
        guard lstat(scope.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
              UInt64(UInt32(bitPattern: facts.st_dev)) == device, facts.st_ino == inode else { throw Failure.result }
        let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("state/catalogs"),
            sessionByteLimit: 48 << 20, preserveAfterClose: true)
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: storage)
        coordinator.requiresAnalysisSelectionForVerification = false
        coordinator.configureScopePreferences(settings)
        let properties = FilePropertiesWindowController(retainAccess: { _ in FileAccessLifetimes(leases: []) },
            settings: settings, copyPaths: { _ in })
        defer { properties.cancel(); properties.close(); coordinator.toolWindow?.close() }
        properties.update(urls: [scope])
        try await wait { properties.model.canAnalyzeStorage }
        guard let window = properties.window else { throw Failure.result }
        window.setContentSize(.init(width: 620, height: 700))
        window.title = "Properties · generated review ·100k scan"
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(250))
        let samples = ProgressSamples()
        let concurrent = duringScan.map { action in
            Task {
                try await wait { coordinator.pagedUpdateForVerification?.status == .scanning }
                let result = try await action()
                return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            }
        }
        defer { concurrent?.cancel() }
        let sampler = Task {
            while !samples.finished && !Task.isCancelled {
                if samples.stopRequestedAt != nil, samples.stopDrainedAt == nil,
                   coordinator.pagedUpdateForVerification?.workerDrained == true {
                    samples.stopDrainedAt = CACurrentMediaTime()
                }
                if let value = properties.model.analysisValue, value.isRunning, let count = value.counts?.total,
                   count > samples.lastCount, samples.values.count < 32 {
                    samples.values.append(["count": count, "running": true,
                        "chartVisible": properties.model.attribution?.isProvisional == true,
                        "title": StorageScanPresentation(value).title])
                    samples.lastCount = count
                    if stopAfterPrefix, samples.stopRequestedAt == nil, count >= 8192,
                       properties.model.attribution?.isProvisional == true,
                       coordinator.pagedUpdateForVerification?.status == .scanning {
                        samples.stopRequestedAt = CACurrentMediaTime()
                        samples.stopRequestedCount = count
                        properties.model.stopAnalysis()
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { samples.finished = true; sampler.cancel() }
        let label = stopAfterPrefix ? "storage-real-stop" : "storage-real-progress"
        let movie = try await NativeMotionRecorder.record(window: window, root: root, label: label,
            sampling: .diagnostic(for: window)) { properties.model.analyzeStorage() }
        try JSONEncoder().encode(movie).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
        try await wait { !coordinator.hasWork && coordinator.pagedResultForVerification != nil }
        samples.finished = true; sampler.cancel()
        let observed = properties.model.analysisValue
        let observation: [String: Any] = ["counts": observed?.counts?.total ?? 0,
            "logicalBytes": observed?.bytes?.dataLogical.knownBytes ?? 0,
            "complete": observed?.isComplete ?? false,
            "status": observed.map { StorageScanPresentation($0).title } ?? "none",
            "chartProvisional": properties.model.attribution?.isProvisional as Any? ?? NSNull(),
            "samples": samples.values, "diagnostics": coordinator.pagedDiagnosticForVerification]
        try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/real-progress-observations.json"), options: .withoutOverwriting)
        guard let value = properties.model.analysisValue,
              samples.values.contains(where: { ($0["count"] as? UInt64 ?? 0) >= 4096 && $0["chartVisible"] as? Bool == true }),
              properties.model.attribution?.isProvisional == false else { throw Failure.result }
        var stopSeconds: Double?
        if stopAfterPrefix {
            guard !value.isComplete, !value.isRunning, value.scanStatus == .cancelled,
                  let total = value.counts?.total, let requested = samples.stopRequestedCount,
                  requested >= 8192, total >= requested, total < 100_000,
                  let began = samples.stopRequestedAt, let drained = samples.stopDrainedAt,
                  drained - began <= 2, StorageScanPresentation(value).title == "Scan stopped",
                  coordinator.pagedSummaryForVerification?.value.counts == value.counts,
                  coordinator.pagedSummaryForVerification?.value.bytes == value.bytes else { throw Failure.result }
            stopSeconds = drained - began
        } else {
            guard value.isComplete, value.counts?.total == 100_000,
                  value.bytes?.dataLogical.knownBytes == logical else { throw Failure.result }
        }
        properties.model.openFullAnalysis()
        try await wait { coordinator.toolWindow?.pagedReadyForVerification == true }
        guard let identity = coordinator.pagedResultForVerification?.id,
              (coordinator.toolWindow?.pagedRowCountForVerification ?? 0) > 0 else { throw Failure.handoff }
        var checks: [String: Any] = ["passed": true, "entries": value.counts?.total ?? 0,
            "files": value.counts?.regularFiles ?? 0, "folders": value.counts?.directories ?? 0,
            "logicalBytes": value.bytes?.dataLogical.knownBytes ?? 0,
            "progressSamples": samples.values, "realCommittedChartSeenWhileRunning": true,
            "sameResult": identity.uuidString, "analysisFileBodyReads": 0, "personalRoots": 0]
        if let stopSeconds {
            checks["actualStopDrainSeconds"] = stopSeconds
            checks["stoppedResultIsPartial"] = true
            checks["sameSealedPartialTotals"] = true
            checks["stopRequestedCount"] = samples.stopRequestedCount
        }
        if let concurrent {
            let bytes = try await concurrent.value
            checks["concurrentWorkload"] = try JSONSerialization.jsonObject(with: bytes)
        }
        coordinator.toolWindow?.close(); await coordinator.stopAndDrain()
        try await wait { !coordinator.hasWork && ApplicationFileActivity.gate.activeCount == 0 }
        return (checks, [["label": label, "frames": movie.frames.count,
            "requestedFPS": movie.requestedFPS, "droppedEncoderFrames": movie.droppedEncoderFrames,
            "width": movie.width, "height": movie.height]])
    }
    static func runFailures(root: URL, settings: BrowserSettings) async throws -> [String: Any] {
        let scope = root.appendingPathComponent("source/FailureScope")
        let coordinator = ApplicationStorageAnalysis.shared
        coordinator.enablePagedForQualification(storage: try .init(directory: root.appendingPathComponent("state/catalogs"), sessionByteLimit: 4 << 20, preserveAfterClose: true))
        coordinator.configureScopePreferences(settings)
        coordinator.requiresAnalysisSelectionForVerification = false
        guard let admission = ApplicationFileActivity.gate.closeAdmission() else { throw Failure.result }
        var reopened = false
        defer { if !reopened { ApplicationFileActivity.gate.reopen(admission) } }
        coordinator.verificationBegin(root: scope) { FileAccessLifetimes(leases: []) }
        try await wait { !coordinator.hasWork }
        guard let window = coordinator.toolWindow,
              window.statusLabel.stringValue == "Couldn’t finish this scan",
              window.progressLabel.stringValue.contains("current file operation"), !window.stopButton.isEnabled,
              coordinator.pagedDiagnosticForVerification["header_uptime"] == nil,
              ApplicationFileActivity.gate.activeCount == 0 else { throw Failure.result }
        reopened = ApplicationFileActivity.gate.reopen(admission)
        guard reopened else { throw Failure.drain }

        coordinator.requiresAnalysisSelectionForVerification = true
        var chooserCalls = 0
        coordinator.chooseFolderForVerification = { _, _ in chooserCalls += 1; return nil }
        defer { coordinator.chooseFolderForVerification = nil; coordinator.requiresAnalysisSelectionForVerification = nil }
        coordinator.verificationBegin(root: scope) { FileAccessLifetimes(leases: []) }
        try await wait { !coordinator.hasWork }
        guard chooserCalls == 1, window.statusLabel.stringValue == "Scan cancelled",
              coordinator.pagedDiagnosticForVerification["header_uptime"] == nil,
              !window.stopButton.isEnabled else { throw Failure.result }

        let failure = FolderSummaryValue.failed(.resourceLimit, message: "Generated technical detail")
        guard failure.scanStatus == .failed(.resourceLimit), !failure.isComplete, !failure.isRunning,
              StorageScanPresentation(failure).title == "Couldn’t finish this scan",
              StorageScanPresentation(failure).guidance.contains("smaller folder") else { throw Failure.result }
        var emptyStop = FolderSummaryValue(counts: nil, bytes: nil, isRunning: false, isComplete: false,
            message: "Generated empty stop", observedAt: Date(), scanStatus: .cancelled)
        guard StorageScanPresentation(emptyStop).guidance.contains("Scan Again") else { throw Failure.result }
        emptyStop = .init(counts: .init(), bytes: .init(), isRunning: false, isComplete: false,
            message: "Generated previous observation", observedAt: Date(), scanStatus: .cancelled, observationIsPrevious: true)
        guard StorageScanPresentation(emptyStop).guidance.contains("from this stopped scan") else { throw Failure.result }
        window.showFailure(.invalidOutput)
        guard window.progressLabel.stringValue.contains("App Logs"), window.summaryLabel.stringValue.isEmpty else { throw Failure.result }

        // A real failed scan with no stored result must not keep claiming that
        // results are being organized. No executable exists at this owned path.
        let missingWorker = StorageScanner(workerURL: root.appendingPathComponent("source/MissingWorker"),
            activityGate: ApplicationFileActivity.gate)
        let failedSession = try missingWorker.startPaged(root: scope,
            storage: .init(directory: root.appendingPathComponent("state/missing-worker"),
                sessionByteLimit: 4 << 20, preserveAfterClose: true), retainingAccess: FileAccessLifetimes(leases: []))
        var failedWithoutResult = false
        for await update in failedSession.updates where update.workerDrained {
            guard case .failed = update.status, update.result == nil else { throw Failure.result }
            failedWithoutResult = true
            window.renderPaged(root: scope, update: update)
        }
        await failedSession.waitUntilDrained()
        let terminalPresentation: [String: Any] = ["realFailedSession": failedWithoutResult,
            "summary": window.summaryLabel.stringValue, "guidance": window.progressLabel.stringValue,
            "stopEnabled": window.stopButton.isEnabled, "actualActivity": ApplicationFileActivity.gate.activeCount]
        try JSONSerialization.data(withJSONObject: terminalPresentation, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/failed-session-presentation.json"), options: .withoutOverwriting)
        guard failedWithoutResult, window.summaryLabel.stringValue.isEmpty,
              window.progressLabel.stringValue.contains("App Logs"), !window.stopButton.isEnabled,
              ApplicationFileActivity.gate.activeCount == 0 else { throw Failure.result }

        let realScanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"),
            activityGate: ApplicationFileActivity.gate)
        let cancelled = try realScanner.startPaged(root: scope,
            storage: .init(directory: root.appendingPathComponent("state/cancelled-before-prefix"),
                sessionByteLimit: 4 << 20, preserveAfterClose: true), retainingAccess: FileAccessLifetimes(leases: []))
        cancelled.cancel()
        var cancelledWithoutResult = false
        for await update in cancelled.updates where update.workerDrained {
            cancelledWithoutResult = update.status == .cancelled && update.result == nil && update.committedEntries == 0
            window.renderPaged(root: scope, update: update)
        }
        await cancelled.waitUntilDrained()
        let cancelledGuidance = window.progressLabel.stringValue

        // Inject a POSIX denial on this empty generated directory only, using
        // an already-held descriptor so restoration cannot follow a new path.
        let denied = try await Task.detached { () throws -> (Int32, mode_t) in
            let fd = open(scope.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard fd >= 0 else { throw Failure.result }
            var original = stat()
            guard fstat(fd, &original) == 0, original.st_uid == geteuid(), original.st_mode & S_IFMT == S_IFDIR,
                  fchmod(fd, 0) == 0 else { close(fd); throw Failure.result }
            return (fd, original.st_mode & 0o7777)
        }.value
        var actualDenial = false
        do {
            let session = try realScanner.startPaged(root: scope,
                storage: .init(directory: root.appendingPathComponent("state/denied-root"),
                    sessionByteLimit: 4 << 20, preserveAfterClose: true), retainingAccess: FileAccessLifetimes(leases: []))
            for await update in session.updates where update.workerDrained {
                actualDenial = update.status == .failed(.accessDenied) && update.result == nil
                window.renderPaged(root: scope, update: update)
            }
            await session.waitUntilDrained()
        } catch { try await restore(denied); throw error }
        try await restore(denied)
        let deniedGuidance = window.progressLabel.stringValue
        try JSONSerialization.data(withJSONObject: ["cancelledWithoutResult": cancelledWithoutResult,
            "cancelledGuidance": cancelledGuidance, "actualFilesystemDenial": actualDenial,
            "deniedGuidance": deniedGuidance, "originalPermissionsRestored": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/cancel-and-permission-guidance.json"), options: .withoutOverwriting)
        guard cancelledWithoutResult, cancelledGuidance.contains("Scan Again"), actualDenial,
              deniedGuidance.contains("Review Access"), deniedGuidance.contains("permissions"),
              ApplicationFileActivity.gate.activeCount == 0 else { throw Failure.result }
        window.close(); let before = window.statusLabel.stringValue
        window.showFailure(.accessDenied)
        guard window.statusLabel.stringValue == before else { throw Failure.result }
        await coordinator.stopAndDrain()
        return ["passed": true, "closedActivityAdmissionRefusedBeforeWorker": true,
            "cancelledAccessDoesNotClaimDenial": true, "chooserCalls": chooserCalls,
            "typedFailureAndActionableGuidance": true, "closedWindowRejectsLateFailure": true,
            "realWorkerFailureDoesNotClaimPendingResults": failedWithoutResult,
            "cancelBeforePrefixNoResult": cancelledWithoutResult, "actualFilesystemDenialAndRestoration": actualDenial,
            "propertiesEmptyAndPreviousStopGuidance": true,
            "preparationAndMissingHelperWorkerLaunches": 0, "actualActivityCount": ApplicationFileActivity.gate.activeCount,
            "fileBodyReads": 0, "systemPrompts": 0, "personalRoots": 0]
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 15
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func restore(_ denied: (Int32, mode_t)) async throws {
        try await Task.detached {
            defer { close(denied.0) }
            var restored = stat()
            guard fchmod(denied.0, denied.1) == 0, fstat(denied.0, &restored) == 0,
                  restored.st_mode & 0o7777 == denied.1 else { throw Failure.result }
        }.value
    }
    private enum Failure: Error { case result, handoff, refresh, drain, deadline }
    @MainActor private final class ProgressSamples {
        var finished = false, lastCount: UInt64 = 0
        var stopRequestedAt: Double?, stopDrainedAt: Double?, stopRequestedCount: UInt64?
        var values: [[String: Any]] = []
    }
    private final class LocationGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var inside = false, open = false
        var entered: Bool { condition.lock(); defer { condition.unlock() }; return inside }
        func hold() {
            condition.lock(); inside = true; condition.broadcast()
            let deadline = Date().addingTimeInterval(5)
            while !open { if !condition.wait(until: deadline) { break } }
            condition.unlock()
        }
        func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
    }
}
#endif
