#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) import LocalStorage
import SwiftUI

@MainActor enum DriveDetailsVerification {
    /// One complete ordinary UI/workload check in the existing App target.
    /// The generated chooser supplies no real sandbox-grant acceptance.
    static func runBenchmark() async {
        let model = ApplicationDriveBenchmark.shared
        let quickMix = ProcessInfo.processInfo.arguments.contains("--quick-mix-benchmark")
        var owner: BrowserWindowController?, area: URL?, failure: String?, checks: [String] = []
        var generatedBytes: Int64 = 0, motionFrames = 0
        var clips: [[String: String]] = []
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw UIVerification.Failure(message: "scope") }
            let root = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(root.resolvingSymlinksInPath() == root && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-drive-benchmark" && Bundle.main.bundleIdentifier == "local.macexplorer.development", "Exact generated benchmark scope")
            area = root
            let folder = root.appendingPathComponent("source/Generated Benchmark")
            let device = try await Task.detached {
                try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
                try Data("Generated benchmark sentinel.\n".utf8).write(to: folder.appendingPathComponent("Sentinel.txt"), options: .withoutOverwriting)
                var stat = stat(); guard lstat(folder.path, &stat) == 0 else { throw UIVerification.Failure(message: "Generated directory unavailable") }
                return Int64(stat.st_dev)
            }.value
            let settings = BrowserSettings(persist: false)
            settings.folderSummariesEnabled = false; settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            if ProcessInfo.processInfo.arguments.contains("--large-interface") { settings.interfaceSize = .init(150); settings.appearance = .light }
            InterfacePresentation.shared.bind(settings)
            let logs = root.appendingPathComponent("state/App Logs")
            ApplicationDiagnostics.shared.start(settings: settings, layout: try ApplicationStorageLayout(developmentState: logs, legacyAnalysis: logs))
            let created = BrowserWindowController(settings: settings); owner = created
            let browser = created.browser; browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.readVolumesForVerification = { [] }
            let operations = browser.operationCoordinator, oldDrives = operations.drives
            let volume = ManagedVolume(id: UUID(), name: "Generated Test Volume", url: folder, isInternal: false,
                canMount: false, canUnmount: false, canEject: false, fileSystemID: device, group: 999, mediaID: nil)
            let sibling = ManagedVolume(id: UUID(), name: "Generated Sibling Volume", url: root.appendingPathComponent("source/Other Volume"), isInternal: false,
                canMount: false, canUnmount: false, canEject: false, fileSystemID: device + 1, group: 999, mediaID: nil)
            let discovery = AsyncStream.makeStream(of: [ManagedVolume].self, bufferingPolicy: .bufferingNewest(1))
            defer { discovery.continuation.finish() }
            discovery.continuation.yield([volume, sibling])
            let drives = ApplicationVolumeCoordinator(operations: operations, backend: DiscoveryOnly(updates: discovery.stream))
            operations.drives = drives
            defer { operations.drives = oldDrives }
            drives.startDiscovery(); try await wait { drives.protectionReady && !drives.volumes.isEmpty }
            created.showWindow(nil); created.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            model.show(from: browser, target: sibling)
            model.window?.title = "Drive Benchmark · generated review"
            model.chooseForVerification = { _ in await browser.folderAccess.acceptChosenFolder(folder) }
            defer { model.chooseForVerification = nil }
            model.chooseFolder(); await model.drain()
            try require(model.folder == folder && model.canRun, "Chosen generated folder did not admit benchmark")
            discovery.continuation.yield([volume])
            try await wait { drives.volumes == [volume] }
            try require(!model.canRun, "A vanished selected sibling admitted its previously chosen folder")
            model.run(); try require(!model.hasPendingWork, "Stale selected-drive run began a workload")
            discovery.continuation.yield([volume, sibling])
            try await wait { drives.volumes.count == 2 }
            try require(model.canRun, "Restored exact selected-drive observation did not restore admission")
            drives.setProtection(.keepMounted, for: volume)
            try require(!model.canRun, "Protected drive admitted benchmark")
            model.run(); try require(!model.hasPendingWork, "Protected run began a workload")
            drives.setProtection(.none, for: volume)
            try require(model.canRun, "Cleared generated protection did not restore admission")
            checks.append("Actual folder selection seals its filesystem and accepts an observed sibling volume in the selected storage group; stale selected-drive discovery and protection refuse before the workload")
            model.size = .quick
            model.workload = ProcessInfo.processInfo.arguments.contains("--random-benchmark") ? .random4K : .sequential
            model.preset = quickMix ? .quickMix : .selected
            let active = ApplicationFileActivity.gate.activeCount
            let oldClipboardWriter = browser.clipboardWriter
            var copiedResults: [String] = []
            browser.clipboardWriter = { text, urls in
                guard let text, urls.isEmpty else { return .failed }
                copiedResults.append(text)
                return .text
            }
            defer { browser.clipboardWriter = oldClipboardWriter }
            func startChecked() throws {
                model.run()
                try require(model.isWorking && operations.activeOwner != nil && ApplicationFileActivity.gate.activeCount == active + 1,
                    "Benchmark did not retain actual file/volume activity")
                try require(!model.canCopyResults, "An active workload offered unfinished results for copying")
                if let delegate = NSApp.delegate as? ApplicationDelegate {
                    try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit did not retain the actual benchmark owner")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--record-drive-benchmark"), let window = model.window, CGPreflightScreenCaptureAccess() {
                window.makeKeyAndOrderFront(nil)
                let clip = try await NativeMotionRecorder.record(window: window, root: root,
                    label: "drive-benchmark-run", sampling: .diagnostic(for: window), action: startChecked)
                try JSONEncoder().encode(clip).write(to: root.appendingPathComponent("evidence/drive-benchmark-motion.json"), options: .withoutOverwriting)
                motionFrames = clip.frames.count
                clips.append(["label": "drive-benchmark-run"])
            } else {
                try startChecked()
            }
            await model.drain()
            guard let result = model.result else { throw UIVerification.Failure(message: "Missing benchmark result") }
            let expectedBytes: Int64 = quickMix ? 16 << 20 : 64 << 20
            let expectedWorkload: DriveBenchmarkWorkload = quickMix ? .random4K : model.workload
            try require(result.outcome == .completed && result.bytesWritten == expectedBytes && result.bytesRead == expectedBytes
                && result.workload == expectedWorkload && result.preparationBytesWritten == (expectedWorkload == .random4K ? expectedBytes : 0)
                && result.scratchURL == nil && !model.isWorking && operations.activeOwner == nil
                && ApplicationFileActivity.gate.activeCount == active, "Actual bounded benchmark did not complete and drain")
            try requireLatencyDistributions(result)
            if CGPreflightScreenCaptureAccess() {
                try await captureLatencyDetails(result, settings: settings,
                    to: root.appendingPathComponent("evidence/drive-benchmark-latency-150.png"))
            }
            checks.append("Completed write/read block latencies yield fixed bounded distributions without another workload")
            generatedBytes += result.bytesWritten + result.preparationBytesWritten
            if quickMix {
                guard let suite = model.selectedSuite, let random = suite.random4K else {
                    throw UIVerification.Failure(message: "Quick Mix did not retain both individual runs")
                }
                try requireLatencyDistributions(suite.sequential.result)
                try require(suite.sequential.result.outcome == .completed
                    && suite.sequential.result.bytesWritten == 64 << 20 && suite.sequential.result.bytesRead == 64 << 20
                    && suite.sequential.result.blockBytes == 1 << 20 && suite.sequential.result.scratchURL == nil
                    && random.id == model.selectedRun?.id && random.result.blockBytes == 4096,
                    "Quick Mix stages did not retain exact separate measurements")
                generatedBytes += suite.sequential.result.bytesWritten
                checks.append("Quick Mix retained distinct 64 MiB sequential and 16 MiB random 4 KiB results after each guarded cleanup")
            }
            let clean = try await Task.detached {
                try FileManager().contentsOfDirectory(atPath: folder.path) == ["Sentinel.txt"]
                    && Data(contentsOf: folder.appendingPathComponent("Sentinel.txt")) == Data("Generated benchmark sentinel.\n".utf8)
            }.value
            try require(clean, "Benchmark changed sentinel or retained a scratch file")
            checks.append("Generated workload preserves the sentinel and releases exclusive/activity owners only after cleanup")
            try require(model.canCopyResults, "A completed selected result could not be copied")
            model.copyResults(.summary); model.copyResults(.json)
            try require(copiedResults.count == 2, "Summary/JSON did not publish exactly two text results")
            let copiedJSON = try JSONSerialization.jsonObject(with: Data(copiedResults[1].utf8)) as? [String: Any]
            let copiedWrite = copiedJSON?["writeAndFlush"] as? [String: Any]
            let copiedRead = copiedJSON?["readAndVerify"] as? [String: Any]
            let copiedWriteBuckets = (copiedWrite?["ioLatency"] as? [String: Any])?["distribution"] as? [[String: Any]]
            let copiedReadBuckets = (copiedRead?["ioLatency"] as? [String: Any])?["distribution"] as? [[String: Any]]
            let copiedWriteCounts = copiedWriteBuckets?.compactMap { $0["count"] as? Int }
            let copiedReadCounts = copiedReadBuckets?.compactMap { $0["count"] as? Int }
            try require(copiedResults[0].hasPrefix("Traverse file benchmark")
                && copiedResults[0].contains("I/O latency distribution")
                && copiedJSON?["schemaVersion"] as? Int == 3
                && copiedJSON?["cacheMode"] as? String == DriveBenchmarkCacheMode.tryNoCache.rawValue
                && copiedWriteCounts?.count == 9 && copiedWriteCounts?.reduce(0, +) == result.writeLatency.operations
                && copiedReadCounts?.count == 9 && copiedReadCounts?.reduce(0, +) == result.readLatency.operations
                && !copiedResults.contains(where: { $0.contains(folder.path) || $0.contains(volume.name) }),
                "Copied benchmark output lost distribution, skipped the shared text publisher or retained selection identity")
            if quickMix {
                model.copyResults(.suiteSummary); model.copyResults(.suiteJSON)
                try require(copiedResults.count == 4 && copiedResults[2].hasPrefix("Traverse Quick Mix file benchmark"),
                    "Quick Mix summary was not copied through the shared publisher")
                let paired = try JSONSerialization.jsonObject(with: Data(copiedResults[3].utf8)) as? [String: Any]
                try require(paired?["schemaVersion"] as? Int == 1
                    && (paired?["sequential"] as? [String: Any])?["schemaVersion"] as? Int == 3
                    && (paired?["random4K"] as? [String: Any])?["schemaVersion"] as? Int == 3
                    && (paired?["sequential"] as? [String: Any])?["workload"] as? String == "sequential"
                    && (paired?["random4K"] as? [String: Any])?["workload"] as? String == "random4K"
                    && !copiedResults[3].contains(folder.path) && !copiedResults[3].contains(volume.name),
                    "Quick Mix JSON lost separate workloads or included selection identity")
                checks.append("Quick Mix summary/JSON copy both reports without folder or volume identity")
            }
            checks.append("Explicit Summary/JSON copies use the shared text publisher on a private test sink, omit the chosen folder/volume identity and remain disabled during work")
            guard let reference = model.selectedRun else { throw UIVerification.Failure(message: "Missing recorded run") }
            let referenceSuite = model.selectedSuite
            model.run(); await model.drain()
            guard let selected = model.selectedRun else { throw UIVerification.Failure(message: "Missing second recorded run") }
            generatedBytes += selected.result.bytesWritten + selected.result.preparationBytesWritten
            if quickMix {
                guard let first = referenceSuite, let second = model.selectedSuite,
                      let firstRandom = first.random4K, let secondRandom = second.random4K else {
                    throw UIVerification.Failure(message: "Second Quick Mix pair was not retained")
                }
                generatedBytes += second.sequential.result.bytesWritten
                try require(DriveBenchmarkComparison(selected: second.sequential, reference: first.sequential) != nil
                    && DriveBenchmarkComparison(selected: secondRandom, reference: firstRandom) != nil
                    && DriveBenchmarkComparison(selected: secondRandom, reference: first.sequential) == nil,
                    "Quick Mix comparison crossed workloads or rejected matching stages")
                let pair = DriveBenchmarkSuiteComparison(selected: second, reference: first)
                try require(pair != nil
                    && pair?.sequential.write.selectedRate?.isFinite == true
                    && pair?.sequential.read.selectedRate?.isFinite == true
                    && pair?.random4K.write.selectedIOPS?.isFinite == true
                    && pair?.random4K.read.selectedIOPS?.isFinite == true
                    && model.suiteComparisonCandidates.contains(where: { $0.sequential.suiteID == first.sequential.suiteID })
                    && DriveBenchmarkSuiteComparison(selected: second,
                        reference: .init(sequential: first.sequential, random4K: secondRandom)) == nil,
                    "Quick Mix suite comparison crossed workloads, paired a foreign stage or lost measured rates")
                let scrollBefore = model.window.flatMap { benchmarkScrollOffset($0) }
                model.comparisonSuiteID = first.sequential.suiteID
                try require(model.suiteComparison != nil && model.comparisonRunID == nil,
                    "Quick Mix suite selection did not project the completed pair")
                if let window = model.window, CGPreflightScreenCaptureAccess() {
                    guard let scrollBefore else {
                        throw UIVerification.Failure(message: "Quick Mix comparison scroll view is unavailable")
                    }
                    try await wait(seconds: 3) {
                        benchmarkScrollOffset(window).map { $0 > scrollBefore + 100 } == true
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    try await GlassVerification.captureOwnedWindow(window,
                        to: root.appendingPathComponent("evidence/drive-benchmark-suite-comparison.png"))
                }
                checks.append("Two complete Quick Mix pairs compare four named phases; a foreign stage is refused and no new workload starts")
            }
            try require(selected.result.outcome == .completed && model.comparisonCandidates.contains(where: { $0.id == reference.id }),
                "Two completed matching workloads were not comparable")
            if ProcessInfo.processInfo.arguments.contains("--record-drive-benchmark"), let window = model.window, CGPreflightScreenCaptureAccess() {
                let clip = try await NativeMotionRecorder.record(window: window, root: root,
                    label: "drive-benchmark-comparison", sampling: .diagnostic(for: window)) {
                    model.comparisonRunID = reference.id
                }
                motionFrames += clip.frames.count; clips.append(["label": "drive-benchmark-comparison"])
            } else { model.comparisonRunID = reference.id }
            try require(model.suiteComparison == nil
                && model.comparison?.selected.id == selected.id && model.comparison?.reference.id == reference.id
                && model.comparison?.write.selectedRate?.isFinite == true && model.comparison?.read.selectedRate?.isFinite == true,
                "Comparison lost the selected/reference result or finite measured rates")
            let otherVolume = DriveBenchmarkRun(date: reference.date, volumeName: "Other generated volume",
                fileSystemID: device + 1, result: reference.result, healthSamples: [])
            try require(DriveBenchmarkComparison(selected: selected, reference: otherVolume) == nil
                && DriveBenchmarkComparison(selected: selected, reference: selected) == nil,
                "Comparison admitted another volume or the same run")
            checks.append("Two real matching runs can be compared without a new read; self/foreign-volume comparisons are refused and phase rates remain finite")
            if let window = model.window, CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .milliseconds(350))
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/drive-benchmark.png"))
                if ProcessInfo.processInfo.arguments.contains("--record-drive-benchmark") {
                    let clip = try await NativeMotionRecorder.record(window: window, root: root,
                        label: "drive-benchmark-comparison-size", sampling: .diagnostic(for: window)) {
                        settings.interfaceSize = .init(150); settings.appearance = .light
                    }
                    motionFrames += clip.frames.count; clips.append(["label": "drive-benchmark-comparison-size"])
                } else { settings.interfaceSize = .init(150); settings.appearance = .light }
                try await Task.sleep(for: .milliseconds(350))
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/drive-benchmark-comparison-150.png"))
                settings.interfaceSize = .init(100); settings.appearance = .dark
            }
            if quickMix {
                model.stageFinishedForVerification = { stage in
                    if stage == .sequential { model.stop() }
                }
                model.run()
            } else {
                model.run(); model.stop()
            }
            try require(model.hasPendingWork, "Stop released the actual worker early")
            await model.drain()
            model.stageFinishedForVerification = nil
            try require((quickMix ? model.selectedSuite?.sequential.result.outcome == .completed
                                 && model.selectedSuite?.random4K == nil
                                 && model.selectedSuite?.sequential.result.scratchURL == nil
                                 : model.result?.outcome == .cancelled && model.result?.scratchURL == nil)
                && !model.hasPendingWork
                && operations.activeOwner == nil && ApplicationFileActivity.gate.activeCount == active, "Stopped native benchmark did not drain")
            generatedBytes += (model.result?.bytesWritten ?? 0) + (model.result?.preparationBytesWritten ?? 0)
            if quickMix { checks.append("Stop between Quick Mix stages prevents random admission after sequential cleanup and holds the owner until drain") }
            if quickMix {
                let paired = try model.selectedSuite?.report()
                try require(paired?.outcome == .partial && model.comparisonRunID == nil
                    && model.suiteComparisonCandidates.isEmpty && model.comparisonSuiteID == nil
                    && model.comparisonCandidates.allSatisfy { $0.result.workload == .sequential },
                    "Stopped Quick Mix mislabeled the missing stage or crossed comparison workloads")
            } else {
                try require(model.comparisonCandidates.isEmpty && model.comparisonRunID == nil,
                    "Partial result remained eligible for speed comparison")
            }
            checks.append("Actual Quit refuses during work; Stop retains the worker until cancellation and cleanup drain")
            if quickMix {
                model.stageFinishedForVerification = { stage in
                    if stage == .sequential { drives.setProtection(.keepMounted, for: volume) }
                }
                model.run(); await model.drain()
                model.stageFinishedForVerification = nil
                try require(model.selectedSuite?.sequential.result.outcome == .completed
                    && model.selectedSuite?.random4K == nil && !model.canRun
                    && operations.activeOwner == nil && ApplicationFileActivity.gate.activeCount == active,
                    "Changed physical-group protection admitted the random stage")
                generatedBytes += model.selectedSuite?.sequential.result.bytesWritten ?? 0
                drives.setProtection(.none, for: volume)
                try require(model.canRun, "Cleared protection did not restore benchmark admission")
                checks.append("Protection changed after sequential cleanup prevents Quick Mix random admission without retaining the operation owner")
            }
            model.run(); model.window?.close()
            try require(model.hasPendingWork && model.isStopping, "Direct native close released work early")
            await model.drain()
            try require(model.window == nil && !model.hasPendingWork && operations.activeOwner == nil
                && ApplicationFileActivity.gate.activeCount == active, "Direct native close did not drain and release presentation")
            generatedBytes += (model.result?.bytesWritten ?? 0) + (model.result?.preparationBytesWritten ?? 0)
            checks.append("Direct NSWindow.close cancels while retaining ownership, then releases the hidden controller after actual drain")
            if let recorder = ApplicationDiagnostics.shared.recorder {
                await recorder.flush()
                let page = try await recorder.page(limit: 100)
                let events = page.events.filter { $0.action == .driveBenchmark }
                try require(events.contains { $0.phase == .transferring } && events.contains { $0.phase == .verifying }
                    && events.contains { $0.phase == .completed } && events.contains { $0.phase == .cancelled }, "Benchmark semantic logs incomplete")
                _ = await recorder.export(to: root.appendingPathComponent("evidence/app-logs.json"), retainingAccess: ())
            }

        } catch { failure = (error as? UIVerification.Failure)?.message ?? "Generated benchmark flow failed" }
        model.stop(); await model.drain(); model.window?.performClose(nil)
        owner?.browser.suspendBrowser(); owner?.window?.performClose(nil)
        if let area {
            let report: [String: Any] = ["passed": failure == nil, "failure": failure as Any? ?? NSNull(), "checks": checks,
                "generatedBytes": generatedBytes, "nativeSandboxGrant": false, "rawDeviceRequests": 0,
                "networkRequests": 0, "keychainCalls": 0, "motionFrames": motionFrames, "clips": clips, "actualOwnerDrain": !model.hasPendingWork,
                "workload": quickMix ? "quickMix" : model.workload.rawValue]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: area.appendingPathComponent("evidence/native-drive-benchmark.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        var repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repo.deleteLastPathComponent() }
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b04-drive-details")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Details requires its generated packet")
        let reader = Reader(); defer { reader.release() }
        var handoffs = 0
        let model = ApplicationDriveDetails(reader: reader, utilityHandoff: { handoffs += 1; return true })
        let settings = BrowserSettings(persist: false); settings.navigationStyle = .glass; settings.appearance = .dark
        let a = volume("Generated USB"), b = volume("Superseded drive"), c = volume("Latest drive")
        let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
        reader.arm(); model.show(a, settings: settings, offscreen: offscreen)
        try await wait { reader.isHeld }
        model.show(b, settings: settings, offscreen: offscreen)
        model.show(c, settings: settings, offscreen: offscreen)
        try require(reader.calls == [a.id] && model.isReading, "New targets queued concurrent readers")
        reader.release(); await model.drain()
        try require(reader.calls == [a.id, c.id] && reader.maximumConcurrent == 1 && model.inspection?.volume == c,
                    "Latest-target coalescing or stale rejection failed")
        reader.arm(); model.refresh(); try await wait { reader.isHeld }
        model.window?.close()
        var drained = false
        let draining = Task { await model.drain(); drained = true }
        try await Task.sleep(for: .milliseconds(50))
        try require(!drained && model.isReading && model.window == nil, "Close released the actual reader or retained the native window")
        reader.release(); await draining.value
        try require(model.inspection == nil && !model.isReading, "Closed window received stale details")
        model.show(a, settings: settings, offscreen: offscreen); await model.drain()
        reader.wrongTarget = b
        model.refresh(); await model.drain()
        try require(model.inspection?.volume == a && model.observationIsStale && !model.notice.isEmpty, "Mismatched reader replaced the last verified observation or lost its stale state")
        reader.wrongTarget = nil
        model.refresh(); await model.drain()
        try require(model.inspection?.volume == a && handoffs == 0, "Reading details launched an external app")
        model.openDiskUtility(); try require(handoffs == 1, "Explicit utility handoff was not isolated")
        model.refresh(); await model.drain(); handoffs = 0
        if let window = model.window {
            window.title = "Generated Drive Details · no device actions"
            try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/drive-details.png"))
        }
        let actualInput = ProcessInfo.processInfo.arguments.contains("--drive-details-input")
        if actualInput {
            let count = reader.calls.count
            try Data("generated-drive-details-ready".utf8).write(to: root.appendingPathComponent("evidence/ready.txt"), options: .withoutOverwriting)
            // Manual acceptance may arrive while the owner is multitasking.
            // Keep the same input assertions with a bounded ten-minute window.
            try await wait(seconds: 600) { reader.calls.count > count && !model.isReading && handoffs == 1 }
        }
        await model.closeAndDrain()
        try require(model.window == nil && !model.isReading && reader.maximumConcurrent == 1, "Final detail lifecycle did not drain")
        let backend = VolumeLifecycle.shared
        var observations: [ManagedVolume] = []
        for _ in 0..<100 {
            observations = await backend.observationsForQualification()
            if !observations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        var native = false
        if let real = observations.first(where: { $0.mediaID != nil && $0.url != nil }) {
            let result = try await backend.inspect(real)
            try require(result.volume == real && !result.deviceName.isEmpty, "Native read returned a different observation")
            let operations = browser.operationCoordinator, original = operations.drives
            let displayOnly = ApplicationVolumeCoordinator(operations: operations, backend: DiscoveryOnly(values: [real]))
            operations.drives = displayOnly
            defer { operations.drives = original }
            displayOnly.startDiscovery()
            try await wait { !displayOnly.volumes.isEmpty && displayOnly.protectionReady }
            if let url = real.url {
                try require(browser.driveMenu(for: url)?.items.contains { $0.title == "Drive Details…" } == true,
                            "Shared drive menu omitted Details")
            }
            native = true
        }
        var refused = false
        do { _ = try await backend.inspect(a) } catch VolumeLifecycleFailure.changed { refused = true }
        try require(refused, "A fabricated native media observation was accepted")
        return ["passed": true, "nativeFactsObserved": native, "actualInputRequired": actualInput,
            "nativeDeviceActions": 0, "externalAppsOpened": 0,
            "checks": ["One real reader and one latest target; superseded target never submitted; stale results rejected",
                "Close and Quit retain actual held reader ownership; no late publication or native-window cycle",
                "Wrong-target results refuse; explicit Refresh recovers; utility handoff is explicit and injected",
                "Common Glass native controls and shared context menu; actual discovered-device metadata only",
                "Fabricated/stale native identity refuses without a device action"]]
    }
    private static func volume(_ name: String) -> ManagedVolume {
        .init(id: UUID(), name: name, url: URL(fileURLWithPath: "/generated/" + name), isInternal: false,
              canMount: false, canUnmount: true, canEject: true, fileSystemID: 42, group: 43, mediaID: 44)
    }
    private struct DiscoveryOnly: VolumeLifecycleManaging {
        let updates: AsyncStream<[ManagedVolume]>
        init(updates: AsyncStream<[ManagedVolume]>) { self.updates = updates }
        init(values: [ManagedVolume]) { updates = AsyncStream { $0.yield(values); $0.finish() } }
        func prepare(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL], removalProtection: VolumeRemovalProtection) async throws -> PreparedVolumeAction {
            throw VolumeLifecycleFailure.unsupported
        }
        func perform(_ prepared: PreparedVolumeAction) async -> VolumeActionResult { .init(unmounted: false, ejected: false, failure: .unsupported) }
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw UIVerification.Failure(message: message) }
    }
    private static func requireLatencyDistributions(_ result: DriveBenchmarkResult) throws {
        for latency in [result.writeLatency, result.readLatency] {
            guard let buckets = latency.distribution?.buckets else {
                throw UIVerification.Failure(message: "Completed benchmark has unavailable I/O latency distribution")
            }
            try require(buckets.count == 9 && buckets.reduce(0) { $0 + $1.count } == latency.operations
                && buckets.first?.upperBoundMilliseconds == 0.125
                && buckets.last?.lowerBoundMilliseconds == 16
                && buckets.last?.upperBoundMilliseconds == nil,
                "Completed benchmark lost fixed I/O latency bucket accounting")
        }
    }
    private static func captureLatencyDetails(_ result: DriveBenchmarkResult, settings: BrowserSettings,
                                              to destination: URL) async throws {
        let priorSize = settings.interfaceSize, priorAppearance = settings.appearance
        defer { settings.interfaceSize = priorSize; settings.appearance = priorAppearance }
        settings.interfaceSize = .init(150); settings.appearance = .light
        let window = NSWindow(contentRect: .init(x: 250, y: 100, width: 920, height: 820),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "I/O latency · generated benchmark review"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: InterfaceRoot(content:
            DriveBenchmarkResultMetrics(result: result)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        try await GlassVerification.captureOwnedWindow(window, to: destination)
    }
    private static func benchmarkScrollOffset(_ window: NSWindow) -> CGFloat? {
        window.contentView?.layoutSubtreeIfNeeded()
        var pending = [window.contentView].compactMap { $0 }, inspected = 0
        while let view = pending.popLast(), inspected < 512 {
            inspected += 1
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height + 300 {
                return scroll.contentView.bounds.minY
            }
            pending += view.subviews
        }
        return nil
    }
    private static func wait(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Generated details check timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private final class Reader: VolumeInspecting, @unchecked Sendable {
        private let queue = DispatchQueue(label: "MacExplorer.GeneratedDriveInspector", attributes: .concurrent)
        private let condition = NSCondition()
        private var armed = false, held = false, released = false
        private var count = 0, maximum = 0
        private var ids: [UUID] = []
        private var wrong: ManagedVolume?
        var calls: [UUID] { condition.lock(); defer { condition.unlock() }; return ids }
        var maximumConcurrent: Int { condition.lock(); defer { condition.unlock() }; return maximum }
        var isHeld: Bool { condition.lock(); defer { condition.unlock() }; return held }
        var wrongTarget: ManagedVolume? {
            get { condition.lock(); defer { condition.unlock() }; return wrong }
            set { condition.lock(); wrong = newValue; condition.unlock() }
        }
        func arm() { condition.lock(); armed = true; held = false; released = false; condition.unlock() }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        func inspect(_ target: ManagedVolume) async throws -> VolumeInspection {
            await withCheckedContinuation { continuation in queue.async { [self] in
                condition.lock(); ids.append(target.id); count += 1; maximum = max(maximum, count)
                if armed { armed = false; held = true; condition.broadcast(); while !released { condition.wait() } }
                let actual = wrong ?? target; count -= 1; condition.unlock()
                continuation.resume(returning: .init(volume: actual, deviceName: "generated-disk",
                    fields: .init(fileSystem: "apfs", model: "Generated removable media", vendor: "Fixture", transport: "USB",
                        mediaBytes: 256 << 30, outerDeviceBytes: 512 << 30, blockBytes: 4096, writable: true, removable: true)))
            } }
        }
    }
}
#endif

#if TRAVERSE_SFTP_EDITOR_QA
import AppKit
import Darwin
@_spi(Qualification) import LocalStorage

/// The retained six-argument role performs one explicit read. Its exact
/// seven-argument continuation may add one Live read. An exact eight-argument
/// continuation observes one external USB unsupported reply. These roles use
/// the ordinary selected-drive owner without modifying a device.
@MainActor enum DriveHealthSignedVerification {
    private enum Refusal: Error { case invalid }
    // DriveHealthNative.THNativeUnsupported in THAcquisition.h. Only the
    // native diagnostic plus a settled service reply can qualify this result.
    private static let nativeUnsupportedStatus: UInt32 = 2

    static func run() async {
        let liveMode = GeneratedSandboxReview.driveHealthLiveReadAdmitted
        let externalMode = GeneratedSandboxReview.driveHealthExternalSelectorDigest != nil
        let sharedMode = liveMode || externalMode
        // The Live continuation uses the app's shutdown-owned reader. A lost
        // service settlement must keep its activity fence alive through Quit.
        let model = sharedMode ? ApplicationDriveDetails.shared
            : ApplicationDriveDetails(reader: VolumeLifecycle.shared)
        var stage = "admission", qualified = false, outcome = "notRequested"
        var liveContinuationQualified: Bool?, externalUnsupportedQualified: Bool?
        var finalDiagnostic: DriveHealthDiagnostic?
        var ownsModel = !sharedMode
        defer { if sharedMode { GeneratedSandboxReview.disarmDriveHealthReview() } }
        do {
            guard GeneratedSandboxReview.driveHealthReadAdmitted,
                  GeneratedSandboxReview.reviewFixtureID != nil,
                  !sharedMode || (model.window == nil && model.target == nil
                    && model.healthRequestsStarted == 0 && !model.hasPendingHealthCheck) else { throw Refusal.invalid }
            ownsModel = true
            stage = "statePreparation"
            let fixture = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let marker = fixture.appendingPathComponent("attempt.json")
            try await Task.detached {
                let format = externalMode ? "drive-health-external-unsupported-v1"
                    : liveMode ? "drive-health-live-two-read-v1" : "drive-health-one-read-v1"
                try Data("{\"format\":\"\(format)\"}\n".utf8)
                    .write(to: marker, options: .withoutOverwriting)
            }.value
            stage = "discovery"
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            var selected: ManagedVolume?
            repeat {
                let observed = await VolumeLifecycle.shared.observationsForQualification()
                if externalMode {
                    let matching = observed.filter(GeneratedSandboxReview.driveHealthExternalSelectorMatches)
                    guard matching.count <= 1 else { throw Refusal.invalid }
                    selected = matching.first
                } else {
                    selected = observed.first {
                        $0.isInternal == true && $0.deviceKind == .internalDisk
                            && $0.url?.path == "/" && $0.mediaID != nil
                    }
                }
                if selected == nil { try await Task.sleep(for: .milliseconds(50)) }
            } while selected == nil && ContinuousClock.now < end
            guard let selected else { throw Refusal.invalid }
            let settings = BrowserSettings(persist: false)
            settings.driveHealthLiveUpdates = false
            model.show(selected, settings: settings)
            await model.drain()
            stage = "selectedInspection"
            guard model.target == selected, model.inspection?.volume == selected,
                  model.healthRequestsStarted == 0, model.canCheckHealth else { throw Refusal.invalid }
            if liveMode {
                guard GeneratedSandboxReview.armDriveHealthLiveReview(for: selected) else { throw Refusal.invalid }
            } else if externalMode {
                stage = "externalAdmission"
                guard model.inspection?.fields.transport == "USB",
                      await mountIdentityMatches(selected) else { throw Refusal.invalid }
                let prepared = try await VolumeLifecycle.shared.prepareHealthSelection(selected)
                guard prepared.selected == selected,
                      GeneratedSandboxReview.armDriveHealthExternalReview(for: selected) else { throw Refusal.invalid }
            }
            stage = "manualReading"
            model.checkHardwareHealth()
            await model.drainHealth()
            guard model.healthRequestsStarted == 1,
                  (liveMode || !model.hasPendingHealthCheck),
                  (liveMode || !model.hasUncertainHealthState), model.target == selected,
                  model.inspection?.volume == selected else { throw Refusal.invalid }
            switch model.health {
            case .warning(let kind, _, _):
                outcome = kind == .nvme ? "nvmeReading" : "ataReading"
                qualified = kind != .nvme || model.healthMeasurements != nil
            case .unavailable(let reason):
                switch reason {
                case .denied: outcome = "denied"
                case .busy: outcome = "busy"
                case .disconnected: outcome = "disconnected"
                case .unsupported: outcome = "unsupported"
                case .stale: outcome = "stale"
                case .unavailable: outcome = "unavailable"
                case .uncertain: outcome = "uncertain"
                }
            case nil: throw Refusal.invalid
            }
            stage = "drained"
            let receipt = fixture.appendingPathComponent("result.json")
            var result: [String: Any] = [
                "format": "drive-health-one-read-v1", "readingQualified": qualified,
                "outcome": outcome, "requests": model.healthRequestsStarted,
                "automaticMonitoring": false, "nativeDeviceActions": 0,
                "childDrained": model.lastHealthCompletion?.childReaped == true,
                "transportSettled": model.lastHealthCompletion?.transportSettled == true,
                "nativeCleanupConfirmed": model.lastHealthCompletion?.nativeCleanupConfirmed == true,
                "uncertainNativeState": model.hasUncertainHealthState
            ]
            switch model.lastHealthCompletion?.transport {
            case .notStarted: result["transport"] = "notStarted"
            case .ownedChild: result["transport"] = "ownedChild"
            case .serviceReply: result["transport"] = "serviceReply"
            case nil: result["transport"] = "notRecorded"
            }
            if let diagnostic = model.healthDiagnostic {
                result["diagnostic"] = diagnosticFields(diagnostic)
            }
            if externalMode {
                stage = "externalValidation"
                let diagnostic = model.healthDiagnostic
                finalDiagnostic = diagnostic
                let serviceSettled = model.lastHealthCompletion?.transport == .serviceReply(settled: true)
                    && model.lastHealthCompletion?.nativeCleanupConfirmed == true
                let nativeUnsupported = diagnostic?.stage == .native && diagnostic?.requestSent == true
                    && diagnostic?.native?.status == nativeUnsupportedStatus
                let sampleCount = model.healthHistory.count
                let measurementsAbsent = model.healthMeasurements == nil
                let noSamples = sampleCount == 0 && measurementsAbsent
                let observedUnsupported = model.health == .unavailable(.unsupported) && !model.healthIsStale
                let mountStillBound = await mountIdentityMatches(selected)
                let preparedAfter = try? await VolumeLifecycle.shared.prepareHealthSelection(selected)
                let attachmentStillBound = preparedAfter.map { $0.selected == selected } == true
                    && mountStillBound && model.target == selected
                    && model.inspection?.volume == selected && model.inspection?.fields.transport == "USB"
                settings.driveHealthLiveUpdates = false
                model.pauseHealthMonitoring()
                stage = "closeDrain"
                await model.closeAndDrain()
                let closedDrained = !model.hasPendingHealthCheck && !model.hasUncertainHealthState
                    && ApplicationFileActivity.gate.activeCount == 0
                let complete = outcome == "unsupported" && observedUnsupported
                    && serviceSettled && nativeUnsupported && noSamples && attachmentStillBound
                    && model.healthRequestsStarted == 1 && model.automaticHealthRequestsStarted == 0
                    && closedDrained
                externalUnsupportedQualified = complete
                result["format"] = "drive-health-external-unsupported-v1"
                result["passed"] = complete
                result["externalUnsupportedQualified"] = complete
                result["selectionBoundBefore"] = true
                result["selectionBoundAfter"] = attachmentStillBound
                result["usbTransportObserved"] = true
                result["serviceSettled"] = serviceSettled
                result["nativeUnsupported"] = nativeUnsupported
                result["healthSamples"] = sampleCount
                result["healthMeasurementsAbsent"] = measurementsAbsent
                result["requests"] = model.healthRequestsStarted
                result["automaticRequests"] = model.automaticHealthRequestsStarted
                result["closedAndDrained"] = closedDrained
                result["uncertainNativeState"] = model.hasUncertainHealthState
            } else if liveMode {
                // The exact signed continuation has one process-wide manual+
                // automatic request budget. Capture the first result before
                // Live can replace the model's latest completion/diagnostic.
                let manualQualified = qualified
                let manualServiceSettled = model.lastHealthCompletion?.transport == .serviceReply(settled: true)
                    && model.lastHealthCompletion?.nativeCleanupConfirmed == true
                result["format"] = "drive-health-live-two-read-v1"
                result["requestLimit"] = 2
                result["manualReadingQualified"] = manualQualified
                result["manualServiceSettled"] = manualServiceSettled
                var visible = false, liveStarted = false, liveQualified = false, hiddenStableUnderCap = false
                if manualQualified && manualServiceSettled && model.healthHistory.count == 1,
                   let window = model.window {
                    stage = "liveVisibility"
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    let visibleDeadline = ContinuousClock.now + .seconds(2)
                    while !Task.isCancelled && ContinuousClock.now < visibleDeadline
                        && !(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)) {
                        try? await Task.sleep(for: .milliseconds(15))
                    }
                    visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
                    if visible && !Task.isCancelled
                        && GeneratedSandboxReview.armDriveHealthLiveAutomaticRead(for: selected) {
                        settings.driveHealthIntervalSeconds = 2
                        settings.driveHealthLiveUpdates = true
                        stage = "liveRequest"
                        let requestDeadline = ContinuousClock.now + .seconds(7)
                        while !Task.isCancelled && model.healthRequestsStarted < 2 && ContinuousClock.now < requestDeadline {
                            try? await Task.sleep(for: .milliseconds(15))
                        }
                        liveStarted = model.healthRequestsStarted == 2 && model.automaticHealthRequestsStarted == 1
                        if liveStarted {
                            // Hide while the request still belongs to its one
                            // service owner. No new request can pass the QA cap.
                            window.orderOut(nil)
                            await model.drainHealth()
                            let completion = model.lastHealthCompletion
                            let serviceSettled = completion?.transport == .serviceReply(settled: true)
                            let nativeCleanup = completion?.nativeCleanupConfirmed == true
                            liveQualified = serviceSettled && nativeCleanup && !model.hasUncertainHealthState
                                && !model.hasPendingHealthCheck && !model.healthIsStale
                                && model.target == selected && model.inspection?.volume == selected
                                && model.healthHistory.count == 2
                                && model.healthHistory.last?.requestedIntervalSeconds == 2
                                && (model.healthHistory.last?.kind != .nvme || model.healthMeasurements != nil)
                            if !liveQualified {
                                settings.driveHealthLiveUpdates = false
                                model.pauseHealthMonitoring()
                            }
                            result["liveTransportSettled"] = serviceSettled
                            result["liveNativeCleanupConfirmed"] = nativeCleanup
                            switch completion?.transport {
                            case .notStarted: result["liveTransport"] = "notStarted"
                            case .ownedChild: result["liveTransport"] = "ownedChild"
                            case .serviceReply: result["liveTransport"] = "serviceReply"
                            case nil: result["liveTransport"] = "notRecorded"
                            }
                            if let diagnostic = model.healthDiagnostic {
                                result["liveDiagnostic"] = diagnosticFields(diagnostic)
                            }
                            stage = "hidden"
                            do { try await Task.sleep(for: .milliseconds(2_300)) }
                            catch { /* Keep the original result and report the incomplete observation. */ }
                            hiddenStableUnderCap = !Task.isCancelled && !window.isVisible
                                && model.healthRequestsStarted == 2
                        }
                    }
                }
                settings.driveHealthLiveUpdates = false
                model.pauseHealthMonitoring()
                stage = "closeDrain"
                await model.closeAndDrain()
                let closedDrained = !model.hasPendingHealthCheck && !model.hasUncertainHealthState
                    && ApplicationFileActivity.gate.activeCount == 0
                let complete = manualQualified && manualServiceSettled && visible && liveStarted
                    && liveQualified && hiddenStableUnderCap && closedDrained
                liveContinuationQualified = complete
                result["liveContinuationQualified"] = complete
                result["passed"] = complete
                result["requests"] = model.healthRequestsStarted
                result["automaticRequests"] = model.automaticHealthRequestsStarted
                result["automaticMonitoring"] = liveStarted
                result["liveReadingQualified"] = liveQualified
                result["visibleBeforeLive"] = visible
                result["hiddenStableUnderExhaustedRequestCap"] = hiddenStableUnderCap
                result["hiddenSuppressionIndependentlyQualified"] = false
                result["closedAndDrained"] = closedDrained
                result["uncertainNativeState"] = model.hasUncertainHealthState
            }
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            try await Task.detached { try bytes.write(to: receipt, options: .withoutOverwriting) }.value
        } catch {
            fputs("TRAVERSE_DRIVE_HEALTH stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        let diagnostic = finalDiagnostic ?? (ownsModel ? model.healthDiagnostic : nil)
        if ownsModel { await model.closeAndDrain() }
        var details = ""
        if let diagnostic {
            details = " diagnosticStage=\(diagnostic.stage.rawValue) childStarted=\(diagnostic.childStarted) requestSent=\(diagnostic.requestSent)"
            if let admission = diagnostic.admissionFailure { details += " admissionFailure=\(admission.rawValue)" }
            if let failure = diagnostic.transportFailure { details += " transportFailure=\(failure.rawValue)" }
            if let native = diagnostic.native {
                details += " nativeStatus=\(native.status) nativeStage=\(native.stage) nativeDomain=\(native.domain) nativeCode=\(native.code) nativeDestroyCode=\(native.destroyCode)"
            }
        }
        if let liveContinuationQualified { details += " liveContinuationQualified=\(liveContinuationQualified)" }
        if let externalUnsupportedQualified { details += " externalUnsupportedQualified=\(externalUnsupportedQualified)" }
        let requests = ownsModel ? model.healthRequestsStarted : 0
        let drained = ownsModel && !model.hasPendingHealthCheck
        fputs("TRAVERSE_DRIVE_HEALTH stage=\(stage) outcome=\(outcome) readingQualified=\(qualified) requests=\(requests) drained=\(drained) pid=\(getpid())\(details)\n", stderr)
        // An admission refusal must not close or terminate someone else's
        // existing shared Details owner just to finish this QA visit.
        if sharedMode && !ownsModel { return }
        NSApplication.shared.terminate(nil)
    }

    /// Recheck the mount's filesystem identity off the main actor. The
    /// lifecycle owner separately revalidates media/whole registry scope.
    private static func mountIdentityMatches(_ selected: ManagedVolume) async -> Bool {
        guard let url = selected.url, url.isFileURL,
              let fileSystemID = selected.fileSystemID, fileSystemID > 0,
              url.standardizedFileURL.path == url.path else { return false }
        let path = url.path
        return await Task.detached(priority: .utility) {
            var link = stat(), mounted = stat()
            guard lstat(path, &link) == 0, link.st_mode & S_IFMT == S_IFDIR,
                  stat(path, &mounted) == 0, mounted.st_mode & S_IFMT == S_IFDIR else { return false }
            return Int64(mounted.st_dev) == fileSystemID
        }.value
    }

    private static func diagnosticFields(_ diagnostic: DriveHealthDiagnostic) -> [String: Any] {
        var fields: [String: Any] = ["stage": diagnostic.stage.rawValue,
            "childStarted": diagnostic.childStarted, "requestSent": diagnostic.requestSent]
        if let admission = diagnostic.admissionFailure { fields["admissionFailure"] = admission.rawValue }
        if let failure = diagnostic.transportFailure { fields["transportFailure"] = failure.rawValue }
        if let native = diagnostic.native {
            fields["native"] = ["status": native.status, "stage": native.stage,
                "domain": native.domain, "code": native.code, "destroyCode": native.destroyCode]
        }
        return fields
    }
}
#endif
