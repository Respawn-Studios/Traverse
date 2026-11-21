import AppKit
import Combine
import LocalStorage
import SwiftUI

enum DriveBenchmarkFeature {
    static var available: Bool {
        AppFeatureAvailability.allows(.fileBenchmarks)
    }
}

/// One explicit file workload, independent of topology/SMART observations.
/// The concrete reader owns all writes and guarded cleanup in LocalStorage.
@MainActor final class ApplicationDriveBenchmark: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ApplicationDriveBenchmark()
    @Published var configuration = DriveBenchmarkConfiguration()
    @Published private(set) var folder: URL?
    @Published private(set) var volumeName = "Choose a folder on the drive to test"
    @Published private(set) var progress: DriveBenchmarkProgress?
    @Published private(set) var result: DriveBenchmarkResult?
    @Published private(set) var samples: [DriveBenchmarkSample] = []
    @Published private(set) var history: [DriveBenchmarkRun] = []
    @Published private(set) var selectedRun: DriveBenchmarkRun?
    @Published var comparisonRunID: UUID? {
        didSet { if comparisonRunID != nil { comparisonSuiteID = nil } }
    }
    @Published var comparisonSuiteID: UUID? {
        didSet { if comparisonSuiteID != nil { comparisonRunID = nil } }
    }
    @Published private(set) var notice = ""
    @Published private(set) var isWorking = false
    @Published private(set) var isChoosing = false
    @Published private(set) var isStopping = false
    @Published private(set) var activeWorkload: DriveBenchmarkWorkload?
    private let reader = DriveFileBenchmark()
    private var controller: NSWindowController?
    private weak var embeddedWindow: NSWindow?
    private weak var browser: BrowserViewController?
    private weak var health: ApplicationDriveDetails?
    private var access: FolderAccessController?
    private var operations: ApplicationOperationCoordinator?
    private var selectedLease: FolderAccessLease?
    private var selection: DriveBenchmarkDirectory?
    private var selectionID: UUID?
    private var selectedVolumeGroup: UInt64?
    private var selectedDevice: Int64? { selection?.fileSystemID }
    private var target: ManagedVolume?
    private var work: Task<Void, Never>?
    private var runID: UUID?
    private var choosing: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var closeWhenDrained = false
    var window: NSWindow? { controller?.window ?? embeddedWindow }
    var isPresentedInWorkspace: Bool { embeddedWindow != nil }
    func isEmbedded(in parent: NSWindow) -> Bool { embeddedWindow === parent }
    var hasPendingWork: Bool { work != nil || choosing != nil }
    var canRun: Bool {
        !hasPendingWork && folder != nil && selectedLease != nil && selectionIsCurrent
    }
    enum CopyFormat { case summary, json, metricsTable, suiteSummary, suiteJSON, suiteMetricsTable, comparisonSummary }
    var canCopyResults: Bool { !hasPendingWork && !isWorking && !isChoosing && selectedRun != nil }
    var canCopyComparison: Bool { canCopyResults && (suiteComparison != nil || comparison != nil) }
    func copyResults(_ format: CopyFormat) {
        guard canCopyResults, let run = selectedRun else { return }
        let text: String
        do {
            switch format {
            case .summary, .json, .metricsTable:
                let report = try DriveBenchmarkReport(result: run.result, recordedAt: run.date)
                switch format {
                case .summary: text = report.summary
                case .metricsTable: text = report.metricsTable
                default: text = try report.json()
                }
            case .suiteSummary, .suiteJSON, .suiteMetricsTable:
                guard let suite = selectedSuite else { return }
                let report = try suite.report()
                switch format {
                case .suiteSummary: text = report.summary
                case .suiteMetricsTable: text = report.metricsTable
                default: text = try report.json()
                }
            case .comparisonSummary:
                guard let summary = suiteComparison?.copySummary ?? comparison?.copySummary else { return }
                text = summary
            }
            guard !text.isEmpty else { throw DriveBenchmarkReport.Failure.invalidDate }
        } catch {
            notice = "The selected result could not be prepared for copying."
            return
        }
        // Explicit Copy replaces existing Cut intent only after formatting has
        // succeeded. Invalid output leaves both Cut and the clipboard alone.
        browser?.clearCutSelection()
        let publication = browser.map { $0.clipboardWriter(text, []) } ?? BrowserClipboard.publish(text, urls: [])
        if case .text = publication {
            switch format {
            case .summary, .suiteSummary: notice = "Copied benchmark summary."
            case .json, .suiteJSON: notice = "Copied benchmark JSON."
            case .metricsTable, .suiteMetricsTable: notice = "Copied benchmark metrics table."
            case .comparisonSummary: notice = "Copied benchmark comparison."
            }
        }
        else { notice = "The clipboard could not be updated. Try again." }
    }
    #if DEBUG
    var chooseForVerification: ((NSWindow) async -> FolderAccessChoice?)?
    var stageFinishedForVerification: ((DriveBenchmarkWorkload) -> Void)?
    func addRecordedComparisonsForVerification(_ runs: [DriveBenchmarkRun]) {
        precondition(!hasPendingWork && history.count + runs.count <= 8)
        history.append(contentsOf: runs)
    }
    #endif

    func show(from browser: BrowserViewController, target: ManagedVolume? = nil, health: ApplicationDriveDetails = .shared) {
        guard DriveBenchmarkFeature.available, !browser.isBrowserSuspended else { return }
        if embeddedWindow != nil { reveal(); return }
        if !hasPendingWork {
            self.health = health
            self.browser = browser; access = browser.folderAccess; operations = browser.operationCoordinator
            if self.target != target {
                clearSelection()
                volumeName = target?.name ?? "Choose a folder on the drive to test"
            }
            self.target = target
            observeDrives(browser.operationCoordinator.drives)
        }
        if controller == nil {
            let host = InterfaceHostingController(rootView: DriveBenchmarkView(model: self, settings: browser.settings))
            let window = ToolWindowChrome.makeWindow(title: "Drive Benchmark", size: .init(width: 900, height: 700),
                minimumSize: .init(width: 640, height: 520), content: host)
            ToolWindowChrome.install(in: window, settings: browser.settings)
            ToolWindowChrome.position(window, relativeTo: browser.view.window)
            window.delegate = self; controller = NSWindowController(window: window)
            window.makeKeyAndOrderFront(nil); ToolContentMotion.reveal(window.contentView!, effect: .windows)
        } else { reveal() }
    }
    @discardableResult
    func attach(from browser: BrowserViewController, to parent: NSWindow, target: ManagedVolume?, health: ApplicationDriveDetails = .shared) -> Bool {
        guard DriveBenchmarkFeature.available, !browser.isBrowserSuspended else { return false }
        if hasPendingWork { return embeddedWindow === parent }
        if let separate = controller?.window { separate.close() }
        embeddedWindow = parent
        self.health = health
        self.browser = browser; access = browser.folderAccess; operations = browser.operationCoordinator
        if self.target != target {
            clearSelection()
            volumeName = target?.name ?? "Choose a folder on the drive to test"
        }
        self.target = target
        observeDrives(browser.operationCoordinator.drives)
        return true
    }
    func detach(from parent: NSWindow) {
        guard embeddedWindow === parent else { return }
        windowWillClose(Notification(name: NSWindow.willCloseNotification, object: parent))
    }
    func reveal() { window?.makeKeyAndOrderFront(nil) }

    private func observeDrives(_ drives: ApplicationVolumeCoordinator) {
        subscriptions.removeAll()
        drives.startDiscovery()
        drives.$protectionRevision.combineLatest(drives.$volumes).sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            if self.isWorking, !self.selectionIsCurrent {
                self.notice = "The selected drive or its protection changed. The benchmark is stopping; choose the folder again after reviewing the current drive."
                self.stop()
            }
        }.store(in: &subscriptions)
    }
    private var selectionIsCurrent: Bool {
        guard let device = selectedDevice, let drives = operations?.drives,
              let volume = drives.volumes.first(where: { $0.fileSystemID == device && $0.url != nil }),
              volume.group == selectedVolumeGroup,
              matchesSelectedDrive(volume, current: drives.volumes) else { return false }
        return permitsBenchmark(device)
    }
    private func permitsBenchmark(_ device: Int64) -> Bool {
        guard let drives = operations?.drives, drives.protectionReady, !drives.isEditingProtection else { return false }
        let volumes = drives.volumes.filter { $0.fileSystemID == device && $0.url != nil }
        guard !volumes.isEmpty else { return false }
        // An explicit protection rule on another member of the same physical
        // group protects this workload too. System-removal restrictions do not
        // become a claim that ordinary files on the startup volume are unwritable.
        return volumes.allSatisfy { $0.group != nil && drives.permitsRemoval($0, action: .eject) }
    }
    private func matchesSelectedDrive(_ volume: ManagedVolume, current: [ManagedVolume]) -> Bool {
        guard let target else { return true }
        guard current.contains(target) else { return false }
        if target.fileSystemID == volume.fileSystemID { return true }
        // A selected APFS/System volume may share its observed storage group
        // with the writable Data volume. The user's explicit folder still
        // seals the actual filesystem; a different or stale group is refused.
        guard let group = target.group, volume.group == group else { return false }
        return true
    }

    func chooseFolder() {
        guard !hasPendingWork, let native = window, native.attachedSheet == nil, let access else { return }
        isChoosing = true; notice = ""; closeWhenDrained = false
        choosing = Task { [self] in
            defer {
                isChoosing = false; choosing = nil
                finishDeferredClose()
            }
            let choice: FolderAccessChoice?
            #if DEBUG
            if let chooseForVerification { choice = await chooseForVerification(native) }
            else { choice = await access.chooseFolder(in: native, initialDirectory: target?.url ?? folder, remember: false, purpose: .fileOperation) }
            #else
            choice = await access.chooseFolder(in: native, initialDirectory: target?.url ?? folder, remember: false, purpose: .fileOperation)
            #endif
            guard let choice, !Task.isCancelled else { return }
            let url = choice.selection.url
            let selected: DriveBenchmarkDirectory
            do { selected = try await DriveFileBenchmark.prepareDirectory(url) }
            catch {
                notice = "Choose an available writable folder on a local volume. Shortcuts, network locations and read-only volumes cannot be tested here."
                return
            }
            let device = selected.fileSystemID
            guard !Task.isCancelled, window != nil else { return }
            guard let drives = operations?.drives,
                  let volume = drives.volumes.first(where: { $0.fileSystemID == device && $0.url != nil }),
                  matchesSelectedDrive(volume, current: drives.volumes) else {
                notice = "Choose a writable folder on this drive. Network locations, shortcuts and read-only volumes cannot be tested here."
                return
            }
            guard permitsBenchmark(device) else {
                notice = "This drive is protected, or its protection settings are not ready. Review it in Drives before starting a benchmark."
                return
            }
            folder = url; selection = selected; selectedLease = choice.lease; volumeName = volume.name
            selectionID = UUID()
            selectedVolumeGroup = volume.group; clearResult()
            if case .failed = choice.remembering { notice = "Folder chosen for this session. Its access could not be remembered." }
        }
    }

    private var repeatableRun: DriveBenchmarkRun? {
        guard canRun, let selectedRun, let target = selectedRun.repeatTarget,
              target.selection == selectionID, selectedRun.result.outcome == .completed,
              selectedRun.result.scratchURL == nil else { return nil }
        if target.configuration.preset == .quickMix {
            guard let selectedSuite, selectedSuite.sequential.result.outcome == .completed,
                  selectedSuite.sequential.result.scratchURL == nil,
                  selectedSuite.random4K?.result.outcome == .completed,
                  selectedSuite.random4K?.result.scratchURL == nil else { return nil }
        }
        return selectedRun
    }

    var canRepeat: Bool { repeatableRun != nil }

    func repeatSelected() {
        guard let reference = repeatableRun, let input = reference.repeatTarget else { return }
        run(input.configuration, comparingTo: reference)
    }

    func run() { run(configuration, comparingTo: nil) }

    private func run(_ requested: DriveBenchmarkConfiguration, comparingTo reference: DriveBenchmarkRun?) {
        guard canRun, let selection, let selectionID, let lease = selectedLease,
              let operations else { return }
        let owner = UUID()
        guard operations.begin(owner: owner) else {
            notice = "Finish the current file or drive task before starting a benchmark."; return
        }
        let activity: any Sendable
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch { operations.finish(owner: owner); notice = "A drive task is finishing. Try again when it completes."; return }
        let volumeName = volumeName, group = selectedVolumeGroup
        let steps = requested.steps
        let suiteID: UUID? = requested.preset == .quickMix ? owner : nil
        let diagnostic = ApplicationDiagnostics.shared.workflow(.driveBenchmark, context: .init(.driveBenchmark))
        runID = owner
        configuration = requested
        isWorking = true; isStopping = false; notice = ""; clearResult(); closeWhenDrained = false
        work = Task { [self] in
            defer {
                withExtendedLifetime(lease) {}; withExtendedLifetime(activity) {}
                operations.finish(owner: owner)
                runID = nil; activeWorkload = nil; isWorking = false; isStopping = false; work = nil
                finishDeferredClose()
            }
            diagnostic.event(.admitted, context: .init(.driveBenchmark))
            var lastResult: DriveBenchmarkResult?
            var completedSteps = 0
            for (index, step) in steps.enumerated() {
                // One owner and activity lease span the pair. The previous
                // guarded cleanup must return before the next stage starts.
                if index > 0 {
                    if Task.isCancelled { break }
                    guard selectionIsCurrent else {
                        notice = "The selected drive or its protection changed. Quick Mix stopped before the next test file was created."
                        stop()
                        break
                    }
                }
                activeWorkload = step.workload; progress = nil; samples = []
                let started = Date()
                let updates = AsyncStream.makeStream(of: DriveBenchmarkProgress.self, bufferingPolicy: .bufferingNewest(1))
                let presentation = Task { @MainActor [weak self] in
                    for await update in updates.stream {
                        guard !Task.isCancelled, self?.runID == owner else { break }
                        self?.progress = update
                        if let rate = update.megabytesPerSecond, rate.isFinite,
                           update.phase == .writing || update.phase == .reading {
                            if self?.samples.count == 600 {
                                self?.samples = self?.samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil } ?? []
                            }
                            self?.samples.append(.init(phase: update.phase, elapsedSeconds: update.elapsedSeconds, megabytesPerSecond: rate))
                        }
                    }
                }
                let measured = await reader.run(in: selection, size: step.size, workload: step.workload,
                                                sequentialBlockSize: step.block, cacheMode: requested.cacheMode) {
                    // Record semantic boundaries before UI coalescing, not a
                    // log record per chunk. No file inputs enter this seam.
                    if $0.completedBytes == 0 || $0.phase == .flushing {
                        let phase: DiagnosticPhase
                        switch $0.phase {
                        case .preparing: phase = .preparing
                        case .writing: phase = .transferring
                        case .flushing: phase = .committing
                        case .reading: phase = .verifying
                        case .cleaningUp: phase = .cleaning
                        }
                        diagnostic.event(phase, context: .init(.driveBenchmark))
                    }
                    updates.continuation.yield($0)
                }
                updates.continuation.finish()
                await presentation.value
                lastResult = measured; completedSteps += 1
                result = measured; samples = measured.samples
                let matchesHealth = health?.target?.fileSystemID == selection.fileSystemID
                    || group != nil && health?.target?.group == group
                let captured = matchesHealth
                    ? health?.healthHistory.filter { $0.capturedAt >= started } ?? [] : []
                let record = DriveBenchmarkRun(date: started, volumeName: volumeName, fileSystemID: selection.fileSystemID,
                    result: measured, healthSamples: captured, suiteID: suiteID,
                    repeatTarget: .init(selection: selectionID, configuration: requested))
                selectedRun = record
                comparisonRunID = nil; comparisonSuiteID = nil
                history.insert(record, at: 0)
                if history.count > 8 { history.removeLast(history.count - 8) }
                #if DEBUG
                stageFinishedForVerification?(step.workload)
                #endif
                guard measured.outcome == .completed, measured.scratchURL == nil else { break }
            }
            let phase: DiagnosticPhase = Task.isCancelled || lastResult?.outcome == .cancelled ? .cancelled
                : completedSteps == steps.count && lastResult?.outcome == .completed ? .completed : .failed
            if phase == .completed, let reference {
                if let baseline = reference.suiteID, suiteComparisonCandidates.contains(where: { $0.sequential.suiteID == baseline }) {
                    comparisonSuiteID = baseline
                } else if reference.suiteID == nil, comparisonCandidates.contains(where: { $0.id == reference.id }) {
                    comparisonRunID = reference.id
                }
            }
            diagnostic.event(phase, context: .init(.driveBenchmark),
                error: lastResult?.failure.map { .init(domain: .benchmark, code: Self.failureCode($0)) })
        }
    }
    private static func failureCode(_ value: DriveBenchmarkFailure) -> Int64 {
        switch value {
        case .busy: 1; case .invalidDirectory: 2; case .insufficientSpace: 3; case .preparation: 4
        case .write: 5; case .read: 6; case .verification: 7; case .changed: 8; case .cleanup: 9
        case .timedOut: 10; case .close: 11
        }
    }
    func stop() {
        guard work != nil, !isStopping else { return }
        isStopping = true; work?.cancel()
    }
    func review(_ run: DriveBenchmarkRun) {
        guard !hasPendingWork, recentRuns.contains(where: { $0.id == run.id }) else { return }
        result = run.result; samples = run.result.samples; selectedRun = run
        comparisonRunID = nil; comparisonSuiteID = nil
    }
    private func clearResult() {
        result = nil; selectedRun = nil; comparisonRunID = nil; comparisonSuiteID = nil
        progress = nil; samples = []; activeWorkload = nil
    }
    private func clearSelection() {
        folder = nil; selectedLease = nil; selection = nil; selectionID = nil; selectedVolumeGroup = nil
        clearResult()
    }
    var recentRuns: [DriveBenchmarkRun] { history.filter { $0.fileSystemID == selectedDevice } }
    var selectedSuite: DriveBenchmarkSuite? {
        guard let suiteID = selectedRun?.suiteID,
              let first = recentRuns.first(where: { $0.suiteID == suiteID && $0.result.workload == .sequential }) else { return nil }
        let second = recentRuns.first { $0.suiteID == suiteID && $0.result.workload == .random4K }
        return .init(sequential: first, random4K: second)
    }
    var comparisonCandidates: [DriveBenchmarkRun] {
        guard let selectedRun else { return [] }
        return history.filter { DriveBenchmarkComparison(selected: selectedRun, reference: $0, acrossVolumes: true) != nil }
    }
    var comparison: DriveBenchmarkComparison? {
        guard let selectedRun, let reference = comparisonCandidates.first(where: { $0.id == comparisonRunID }) else { return nil }
        return .init(selected: selectedRun, reference: reference, acrossVolumes: true)
    }
    var suiteComparisonCandidates: [DriveBenchmarkSuite] {
        guard let selectedSuite else { return [] }
        let runs = history
        return runs.filter { $0.suiteID != nil && $0.result.workload == .sequential }.compactMap { first in
            let second = runs.first { $0.suiteID == first.suiteID && $0.result.workload == .random4K }
            let candidate = DriveBenchmarkSuite(sequential: first, random4K: second)
            return DriveBenchmarkSuiteComparison(selected: selectedSuite, reference: candidate, acrossVolumes: true) == nil ? nil : candidate
        }
    }
    var suiteComparison: DriveBenchmarkSuiteComparison? {
        guard let selectedSuite,
              let reference = suiteComparisonCandidates.first(where: { $0.sequential.suiteID == comparisonSuiteID }) else { return nil }
        return .init(selected: selectedSuite, reference: reference, acrossVolumes: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if choosing != nil { closeWhenDrained = true; choosing?.cancel(); return false }
        guard isWorking else { return true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "Stop the benchmark before closing?"
        alert.informativeText = "Traverse finishes the current read or write and removes its test file before closing. A drive that stops responding may take longer."
        alert.addButton(withTitle: "Stop and Close"); alert.addButton(withTitle: "Keep Running")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closeWhenDrained = true; self?.stop()
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard let native = notification.object as? NSWindow, native === window else { return }
        if hasPendingWork {
            // Internal close() bypasses windowShouldClose. Cancel, retaining
            // access and the native controller until the real worker returns.
            closeWhenDrained = true; choosing?.cancel(); stop(); return
        }
        releasePresentation()
    }
    private func finishDeferredClose() {
        guard closeWhenDrained, !hasPendingWork else { return }
        if window?.isVisible == true { window?.performClose(nil) }
        else { releasePresentation() }
    }
    private func releasePresentation() {
        subscriptions.removeAll(); clearSelection(); target = nil
        access = nil; browser = nil; health = nil; operations = nil; controller = nil; embeddedWindow = nil; closeWhenDrained = false
    }
    func drain() async { if let choosing { await choosing.value }; if let work { await work.value } }
}

struct DriveBenchmarkView: View {
    @ObservedObject var model: ApplicationDriveBenchmark
    @ObservedObject var settings: BrowserSettings
    var health: ApplicationDriveDetails? = nil
    @State private var details = false
    @State private var recent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
          ScrollViewReader { scroll in
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.isPresentedInWorkspace {
                    Label("Drive Benchmark", systemImage: "speedometer").interfaceFont(.title2.bold())
                }
                Text("Measure file transfers with a temporary write, flush and verified read.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.volumeName).interfaceFont(.headline)
                        if let folder = model.folder {
                            Text(folder.path).interfaceFont(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(folder.path)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(model.folder == nil ? "Choose Test Folder…" : "Change Folder…", action: model.chooseFolder)
                        .disabled(model.hasPendingWork)
                }
                Picker("Run", selection: $model.configuration.preset) {
                    Text("Selected workload").tag(DriveBenchmarkPreset.selected)
                    Text("Quick Mix · sequential + random 4 KiB").tag(DriveBenchmarkPreset.quickMix)
                }.disabled(model.hasPendingWork)
                if model.configuration.preset == .selected {
                    AdaptiveToolColumns(settings: settings, minimumWidth: 480) {
                        Picker("Workload", selection: $model.configuration.workload) {
                            Text("Sequential · large transfers").tag(DriveBenchmarkWorkload.sequential)
                            Text("Random · 4 KiB access").tag(DriveBenchmarkWorkload.random4K)
                        }.disabled(model.hasPendingWork)
                    } trailing: {
                        Picker("Test size", selection: $model.configuration.size) {
                            Text("Compact · 16 MiB").tag(DriveBenchmarkSize.compact)
                            Text("Quick · 64 MiB").tag(DriveBenchmarkSize.quick)
                            Text("Standard · 256 MiB").tag(DriveBenchmarkSize.standard)
                            Text("Extended · 1 GiB").tag(DriveBenchmarkSize.extended)
                        }.disabled(model.hasPendingWork)
                    }
                    AdaptiveToolColumns(settings: settings, minimumWidth: 480) {
                        Picker("Sequential block", selection: $model.configuration.sequentialBlockSize) {
                            ForEach(DriveSequentialBlockSize.allCases, id: \.self) { block in
                                Text(block.title).tag(block)
                            }
                        }.disabled(model.hasPendingWork || model.configuration.workload == .random4K)
                    } trailing: { cachePicker }
                } else { cachePicker }
                Text(model.configuration.preset == .quickMix
                    ? "One click: 64 MiB sequential at 1 MiB, then 16 MiB random at 4 KiB and one outstanding I/O. Each stage flushes, verifies and removes its own test file; random preparation writes another 16 MiB."
                    : model.configuration.workload == .random4K
                        ? "4 KiB blocks · one operation at a time · preparation writes one extra test-file size."
                        : "\(model.configuration.sequentialBlockSize.title) blocks · large sequential transfers · every byte verified.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Text("Cache choice applies only to the generated test file. Neither mode clears macOS caches or measures a cold raw device.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                if let suite = model.selectedSuite {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Quick Mix results", systemImage: "chart.bar.xaxis").interfaceFont(.headline)
                        suiteRow("Sequential · 64 MiB", run: suite.sequential)
                        if let random = suite.random4K {
                            suiteRow("Random 4 KiB · 16 MiB", run: random)
                        } else {
                            Text("Random 4 KiB was not started. The sequential stage did not complete or Stop was requested.")
                                .interfaceFont(.callout).foregroundStyle(.secondary)
                        }
                        Text("Each row is a separate generated-file run. Select an individual run below to inspect or compare matching measurements.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                if !model.isWorking, !model.suiteComparisonCandidates.isEmpty {
                    Picker("Compare Quick Mix with", selection: $model.comparisonSuiteID) {
                        Text("No suite comparison").tag(nil as UUID?)
                        ForEach(model.suiteComparisonCandidates, id: \.sequential.id) { suite in
                            Text(suite.sequential.comparisonLabel).tag(suite.sequential.suiteID)
                        }
                    }.disabled(model.hasPendingWork)
                }
                if !model.isWorking, !model.comparisonCandidates.isEmpty {
                    Picker("Compare selected run with", selection: $model.comparisonRunID) {
                        Text("No comparison").tag(nil as UUID?)
                        ForEach(model.comparisonCandidates) { run in
                            Text(run.comparisonLabel).tag(Optional(run.id))
                        }
                    }.disabled(model.hasPendingWork)
                }
                if let suiteComparison = model.suiteComparison {
                    DriveBenchmarkSuiteComparisonView(comparison: suiteComparison)
                        .transition(.identity)
                        .id("benchmark-suite-comparison")
                    if let health {
                        DriveHealthTrend(model: health, recordedPoints: model.selectedRun?.healthSamples)
                    }
                } else if let comparison = model.comparison {
                    DriveBenchmarkComparisonView(comparison: comparison, settings: settings)
                        .transition(.identity)
                    if let health {
                        DriveHealthTrend(model: health, recordedPoints: model.selectedRun?.healthSamples)
                    }
                } else {
                  VStack(alignment: .leading, spacing: 16) {
                  HStack(spacing: 14) {
                    metric("Write & flush", writing: true)
                    metric("Read & verify", writing: false)
                }
                if let health {
                    AdaptiveToolColumns(settings: settings, minimumWidth: 620) {
                        DriveBenchmarkChart(samples: model.samples, workload: workload)
                    } trailing: {
                        DriveHealthTrend(model: health, recordedPoints: model.selectedRun?.healthSamples)
                    }
                  } else { DriveBenchmarkChart(samples: model.samples, workload: workload) }
                  }
                  .transition(.identity)
                }
                if model.isWorking {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: fraction)
                        Text(model.isStopping ? "Stopping · finishing the current step…" : phaseTitle)
                            .interfaceFont(.callout).foregroundStyle(.secondary)
                    }
                } else if let result = model.result {
                    if let run = model.selectedRun {
                        Text("\(run.volumeName) · \(run.result.workload == .random4K ? "Random 4 KiB" : "Sequential") · \(FileSizeText.string(run.result.bytesWritten)) · \(run.displayTimestamp)")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    let suiteComplete = model.selectedSuite.map { $0.sequential.result.outcome == .completed && $0.random4K?.result.outcome == .completed } ?? true
                    Label(result.outcome == .completed && suiteComplete ? "Benchmark complete" : result.outcome == .cancelled ? "Benchmark stopped" : "Benchmark incomplete",
                          systemImage: result.outcome == .completed && suiteComplete ? "checkmark.circle" : "exclamationmark.circle")
                        .interfaceFont(.headline)
                    if let failure = result.failure { Text(failureText(failure)).interfaceFont(.callout).foregroundStyle(.secondary) }
                    if let residue = result.scratchURL {
                        Text("The test folder was kept because cleanup could not be confirmed. Review this exact folder before removing it:")
                            .interfaceFont(.callout)
                        Text(residue.path).interfaceFont(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("Measurement details", isExpanded: $details) {
                        VStack(alignment: .leading, spacing: 6) {
                            DriveBenchmarkResultMetrics(result: result)
                            Divider().padding(.vertical, 6)
                            Text("\(result.workload == .random4K ? "Random" : "Sequential") · \(result.blockBytes.formatted())-byte blocks · one outstanding I/O")
                            Text("Written: \(FileSizeText.string(result.bytesWritten)) · Read: \(FileSizeText.string(result.bytesRead))")
                            if result.preparationBytesWritten > 0 {
                                Text("Preparation wrote \(FileSizeText.string(result.preparationBytesWritten)) in \(result.preparationSeconds.formatted(.number.precision(.fractionLength(2)))) s, outside the measured phases.")
                            }
                            Text("Flush: \(result.flushSeconds.formatted(.number.precision(.fractionLength(3)))) s. I/O latency covers the block's read/write calls; transfer rates also include validation and other file-workload overhead.")
                            Text(result.cacheMode == .normal ? "Normal system caching was selected; no cache bypass was requested."
                                : result.cacheBypass == .enabled ? "No-cache was requested for the test file."
                                : result.cacheBypass == .unavailable ? "No-cache was requested but unavailable."
                                : "The no-cache request was not reached.")
                            Text(result.flush == .fullSync ? "The operating system acknowledged a full flush request." : result.flush == .fileSyncOnly ? "The filesystem acknowledged a flush; a full device flush was unavailable." : "A flush was not completed.")
                        }.interfaceFont(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                if !model.recentRuns.isEmpty {
                    DisclosureGroup("Recent benchmarks · this session", isExpanded: $recent) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.recentRuns) { run in
                                Button { model.review(run) } label: {
                                    HStack {
                                        Text(run.displayTimestamp)
                                        if run.suiteID != nil { Text("Quick Mix ·").foregroundStyle(.secondary) }
                                        Text(run.result.workload == .random4K ? "Random 4 KiB" : "Sequential")
                                        Spacer()
                                        Text(run.result.outcome == .completed ? "Completed" : run.result.outcome == .cancelled ? "Stopped" : "Failed")
                                    }.interfaceFont(.caption)
                                }.disabled(model.hasPendingWork)
                            }
                        }.padding(.top, 8)
                    }
                }
                if !model.notice.isEmpty { Text(model.notice).interfaceFont(.callout).foregroundStyle(.secondary) }
                Text("Only generated test data is used. Results include filesystem overhead and may be affected by drive caches and other activity; they do not measure drive health.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
          }
          .onChange(of: model.comparisonSuiteID) { _, selected in
              guard selected != nil, model.suiteComparison != nil else { return }
              withAnimation(reduceMotion || !settings.motion.allows(.pages) ? nil
                  : .easeOut(duration: 0.16 * settings.motion.mode.durationScale)) {
                  scroll.scrollTo("benchmark-suite-comparison", anchor: .top)
              }
          }
          }
          Divider()
          HStack {
              Menu("Copy Results") {
                  Button("Selected run summary") { model.copyResults(.summary) }
                  Button("Selected run JSON") { model.copyResults(.json) }
                  Button("Selected run metrics table") { model.copyResults(.metricsTable) }
                  if model.selectedSuite != nil {
                      Divider()
                      Button("Quick Mix summary") { model.copyResults(.suiteSummary) }
                      Button("Quick Mix JSON") { model.copyResults(.suiteJSON) }
                      Button("Quick Mix metrics table") { model.copyResults(.suiteMetricsTable) }
                  }
                  if model.canCopyComparison {
                      Divider()
                      Button("Comparison table") { model.copyResults(.comparisonSummary) }
                  }
              }.disabled(!model.canCopyResults).fixedSize()
                  .help("Copy individual or Quick Mix generated-file results without volume names, paths or hardware identifiers.")
              Spacer()
              if model.selectedRun != nil {
                  Button("Repeat Benchmark", systemImage: "arrow.clockwise", action: model.repeatSelected)
                      .disabled(!model.canRepeat)
                      .help("Repeat this result’s settings in the current selected folder.")
              }
              if model.isWorking { Button("Stop", action: model.stop).disabled(model.isStopping) }
              else { Button(model.configuration.preset == .quickMix ? "Run Quick Mix" : "Run Benchmark", action: model.run).buttonStyle(.borderedProminent).disabled(!model.canRun) }
          }.padding(.horizontal, 24).padding(.vertical, 14)
        }.animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeOut(duration: 0.16 * settings.motion.mode.durationScale), value: model.isWorking)
            // Interpolating the replacement's geometry moves lower labels
            // through the new cards. Blend the committed native page instead.
            .animation(nil, value: model.comparisonRunID)
            .animation(nil, value: model.comparisonSuiteID)
            .toolPageCrossfade(model.comparisonRunID, motion: settings.motion)
    }
    private var fraction: Double {
        guard let p = model.progress, p.totalBytes > 0 else {
            return model.configuration.preset == .quickMix && model.activeWorkload == .random4K ? 0.5 : 0
        }
        let part = Double(p.completedBytes) / Double(p.totalBytes)
        let stage: Double
        switch p.phase { case .preparing: stage = 0; case .writing: stage = part * 0.45; case .flushing: stage = 0.45; case .reading: stage = 0.5 + part * 0.48; case .cleaningUp: stage = 0.99 }
        return model.configuration.preset == .quickMix ? (model.activeWorkload == .random4K ? 0.5 : 0) + stage * 0.5 : stage
    }
    private var phaseTitle: String {
        let stage = model.configuration.preset == .quickMix ? (model.activeWorkload == .random4K ? "Random 4 KiB · " : "Sequential · ") : ""
        switch model.progress?.phase {
        case .preparing, nil: return stage + "Preparing test file…"
        case .writing: return stage + "Writing test data…"
        case .flushing: return stage + "Flushing writes…"
        case .reading: return stage + "Reading and verifying…"
        case .cleaningUp: return stage + "Removing test file…"
        }
    }
    private var cachePicker: some View {
        Picker("File caching", selection: $model.configuration.cacheMode) {
            Text("Normal system caching").tag(DriveBenchmarkCacheMode.normal)
            Text("Try no cache for test file").tag(DriveBenchmarkCacheMode.tryNoCache)
        }.disabled(model.hasPendingWork)
    }
    private var workload: DriveBenchmarkWorkload {
        model.activeWorkload ?? model.result?.workload
            ?? (model.configuration.preset == .quickMix ? .sequential : model.configuration.workload)
    }

    private func suiteRow(_ title: String, run: DriveBenchmarkRun) -> some View {
        let result = run.result
        let metric = result.workload.primaryMetric
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title).interfaceFont(.callout.bold()).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Write + flush").interfaceFont(.caption).foregroundStyle(.secondary)
                Text("\(metric.displayValue(metric.completedRate(result, writing: true))) \(metric.unit)")
                    .monospacedDigit().interfaceFont(.callout)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("Read + verify").interfaceFont(.caption).foregroundStyle(.secondary)
                Text("\(metric.displayValue(metric.completedRate(result, writing: false))) \(metric.unit)")
                    .monospacedDigit().interfaceFont(.callout)
            }
        }
    }
    private func metric(_ title: String, writing: Bool) -> some View {
        let metric = workload.primaryMetric
        let result = model.isWorking ? nil : model.result
        let value = result.flatMap { metric.completedRate($0, writing: writing) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).interfaceFont(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(metric.displayValue(value)).interfaceFont(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(metric.unit).interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(metric.accessibilityValue(value))
    }
    private func failureText(_ value: DriveBenchmarkFailure) -> String {
        switch value {
        case .busy: "Another benchmark is still finishing."
        case .invalidDirectory: "Choose an available writable folder on this drive."
        case .insufficientSpace: "There is not enough available space for this test. Choose a smaller size."
        case .preparation: "The test file could not be prepared. Check folder access and try again."
        case .write: "The drive could not finish writing or flushing the test file."
        case .read: "The drive could not finish reading the test file."
        case .verification: "The test data did not match. No speed result is reported."
        case .changed: "The selected folder or test file changed. The benchmark stopped."
        case .cleanup: "The benchmark stopped because its test folder could not be removed safely."
        case .timedOut: "The benchmark reached its three-minute limit. Partial work was stopped and cleaned up where possible."
        case .close: "The drive reported an error while closing the test file. No speed result is reported."
        }
    }
}

@MainActor extension BrowserViewController {
    @objc func showDriveBenchmark(_ sender: Any?) {
        guard !isBrowserSuspended, !isReadOnlyFileSession else { return }
        openDrives(.benchmark)
    }
}
