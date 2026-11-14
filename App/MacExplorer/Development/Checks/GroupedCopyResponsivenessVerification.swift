#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import CryptoKit
import Combine
import Darwin
import FileOperations

/// Separate generated-only diagnostic population. No worker delays or fault hooks.
private final class GroupedResponsivenessTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [UInt64] = []
    private var firstCopy: UInt64?
    private var overflow = false
    private var wrongThread = false
    func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            if !Thread.isMainThread { wrongThread = true }
            if ticks.count == 20_000 { overflow = true; return }
            ticks.append(now)
        }
    }
    func progress(_ progress: OperationProgress) {
        guard progress.phase == .copying else { return }
        lock.withLock { if firstCopy == nil { firstCopy = DispatchTime.now().uptimeNanoseconds } }
    }
    var snapshot: (ticks: [UInt64], firstCopy: UInt64?, overflow: Bool, wrongThread: Bool) {
        lock.withLock { (ticks, firstCopy, overflow, wrongThread) }
    }
}

private struct GroupedResponsivenessUsage {
    let user: Double, system: Double, peakRSS: Int64
    let userSecondsPart: Int64, userMicrosecondsPart: Int64
    let systemSecondsPart: Int64, systemMicrosecondsPart: Int64
    init() throws {
        var value = rusage()
        guard getrusage(RUSAGE_SELF, &value) == 0 else { throw UIVerification.Failure(message: "usage") }
        userSecondsPart = Int64(value.ru_utime.tv_sec); userMicrosecondsPart = Int64(value.ru_utime.tv_usec)
        systemSecondsPart = Int64(value.ru_stime.tv_sec); systemMicrosecondsPart = Int64(value.ru_stime.tv_usec)
        user = Double(userSecondsPart) + Double(userMicrosecondsPart) / 1_000_000
        system = Double(systemSecondsPart) + Double(systemMicrosecondsPart) / 1_000_000
        peakRSS = Int64(value.ru_maxrss) // macOS bytes; lifetime high-water mark.
    }
    var raw: [String: Any] {
        ["userTimeSeconds": userSecondsPart, "userTimeMicroseconds": userMicrosecondsPart,
         "systemTimeSeconds": systemSecondsPart, "systemTimeMicroseconds": systemMicrosecondsPart,
         "userCPUSeconds": user, "systemCPUSeconds": system, "processLifetimePeakRSSBytes": peakRSS]
    }
    func interval(from before: Self, duration: Double) -> [String: Any] {
        let cpu = (user - before.user) + (system - before.system)
        return ["before": before.raw, "after": raw, "userCPUSeconds": user - before.user, "systemCPUSeconds": system - before.system,
            "totalCPUSeconds": cpu, "CPUSecondsPerWallSecond": cpu / duration,
            "processLifetimePeakRSSBytes": peakRSS, "wallSeconds": duration]
    }
}

@MainActor
extension UIVerification {
    static func verifyGroupedCopyResponsiveness(_ browser: BrowserViewController, in root: URL,
        output: URL, inheritedLease: Int32) async -> [String: Any] {
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func seconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1_000_000_000 }
        let queue = browser.operationCoordinator.transfers
        var stage = "controlledSetup", jobID: UUID?, recordID: UUID?
        var commands: [[String: Any]] = [], windows: [[String: Any]] = []
        var report: [String: Any] = ["passed": false, "sufficient": false,
            "mode": "grouped-copy-responsiveness-controlled", "population": "separate-native-ui-diagnostic",
            "pooledWithPrimaryPerformance": false, "requestedTimerSeconds": 0.01, "timerToleranceSeconds": 0,
            "viewMode": "details", "keyboardProfile": browser.settings.keyboardProfile.rawValue,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "maximumTicks": 20_000, "maximumCommands": 64, "groupSize": 16, "metadataPolicy": "strict",
            "notExercised": ["Physical input", "Compositor latency", "VoiceOver", "Energy", "Main-thread-only CPU",
                "Hardware power loss", "Universal provider support", "Owner grouped-copy activation"]]
        let recorder = GroupedResponsivenessTicks()
        var timer: Timer?
        var stateObservation: AnyCancellable?
        let oldSink = queue.progressForVerification
        var retainedEngine: RecoverableFileOperations?
        var bootstrapWorkspace: BrowserWorkspaceController?
        let board = NSPasteboard.withUniqueName()
        defer {
            timer?.invalidate(); stateObservation?.cancel(); queue.progressForVerification = oldSink
            bootstrapWorkspace?.willStartBrowserForVerification = nil
            board.releaseGlobally()
            withExtendedLifetime(retainedEngine) {}
        }
        func writeFailureBeforeDrain() {
            // Constant stages/counts only: no arbitrary error/path/body rendering.
            report["failureStage"] = stage; report["workerDrained"] = !queue.hasOutstandingWork
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("responsiveness-failure-before-drain.json"), options: .withoutOverwriting)
        }
        func pauseUntil(_ deadline: UInt64) async throws {
            while now() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        func wait(_ condition: () -> Bool, seconds bound: Double) async throws {
            let deadline = now() + UInt64(bound * 1_000_000_000)
            while !condition() {
                try require(now() < deadline, "boundedObservation")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        do {
            try require(browser.isControlledVerification && inheritedLease > 2
                && !queue.hasOutstandingWork && queue.results.isEmpty
                && browser.operationCoordinator.activeOwner == nil && browser.operationCoordinator.preparationOwner == nil,
                "controlledSetup")
            guard let workspace = browser.workspace, let window = browser.view.window else {
                throw Failure(message: "controlledWorkspace")
            }
            bootstrapWorkspace = workspace
            stage = "paneBootstrap"
            var finishedBegins = Set<UUID>()
            workspace.willStartBrowserForVerification = { pane in
                pane.permitsBackgroundVerification = true
                pane.didFinishBeginForVerification = { _ = finishedBegins.insert(pane.paneID) }
            }
            workspace.begin()
            try await wait({ finishedBegins.contains(browser.paneID) }, seconds: 60)
            await browser.recoveryInspectionTask?.value
            try require(workspace.browsers.count == 1, "freshWorkspace")
            workspace.activate(browser)
            try require(workspace.splitActive(at: .trailing) && workspace.splitActive(at: .bottom), "paneSetup")
            workspace.activate(browser); try require(workspace.splitActive(at: .bottom), "paneSetup")
            let panes = workspace.layout.paneIDs.compactMap { workspace.browsers[$0] }
            try require(panes.count == 4, "paneSetup")
            try await wait({ panes.allSatisfy { finishedBegins.contains($0.paneID) } }, seconds: 60)
            for pane in panes { await pane.recoveryInspectionTask?.value; pane.didFinishBeginForVerification = nil }
            workspace.willStartBrowserForVerification = nil
            try await wait({ !workspace.hasInitialVolumeBootstrapForVerification }, seconds: 60)
            stage = "fixtureAuthority"
            let engine = try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(
                in: root, inheritingFixtureLeaseDescriptor: inheritedLease)
            retainedEngine = engine
            try require(engine.copyPreviewAvailability == .available, "fixtureAuthority")
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let history = root.appendingPathComponent("history", isDirectory: true)
            let inputs = (0..<1024).map { source.appendingPathComponent("generated-\($0).dat") }
            stage = "sourceBefore"
            let originalSource = try await Task.detached { try responsivenessSourceFingerprint(source) }.value
            stage = "paneNavigation"
            for (index, pane) in panes.enumerated() {
                pane.recoverableFileOperations = engine; pane.permitsBackgroundVerification = true
                pane.operationResultPresenter = { _ in }; pane.operationErrorPresenter = { _ in }
                pane.transferPasteboard = board
                pane.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
                pane.setPaneViewMode(.details)
                pane.navigate(to: .directory(index == 1 ? destination : source)); try await settled(pane)
                pane.newTab(nil); pane.navigate(to: .directory(history)); try await settled(pane)
                pane.cycleTab(backward: false); try await settled(pane)
                try require(pane.tabs.count == 2, "tabSetup")
            }
            try require(Set(panes[0].displayedEntries.map(\.url)) == Set(inputs), "sourcePaneInputs")
            stage = "nativeCopySelection"
            let sourcePane = panes[0]
            var copiedInputOrder: [URL] = []
            sourcePane.clipboardWriter = { text, urls in
                copiedInputOrder = urls
                return BrowserClipboard.publish(text, urls: urls, to: board)
            }
            workspace.activate(sourcePane); sourcePane.table.selectAll(nil)
            sourcePane.copyFileURLs(nil)
            report["inputCapture"] = ["selectedCount": sourcePane.selectedItemCount,
                "clipboardReferenceCount": board.pasteboardItems?.count ?? 0,
                "nativeOrderMatchesNumericSeed": sourcePane.orderedSelectedURLs == inputs,
                "capturedOrderMatchesNativeSelection": copiedInputOrder == sourcePane.orderedSelectedURLs]
            try require(sourcePane.selectedItemCount == 1024 && board.pasteboardItems?.count == 1024
                && copiedInputOrder == sourcePane.orderedSelectedURLs, "nativeCopyInputCap")
            stage = "nativeInputOrdering"
            // The unchanged cold helper binds member ordinal to generated-N.
            // Refuse a different UI sort order; never rewrite the board/manifest
            // or weaken that independent association oracle to make it pass.
            try require(copiedInputOrder == inputs, "nativeInputOrdering")
            let commandPane = panes[2]
            let fixedTabs = commandPane.tabs.map(\.id)
            let origin = panes[1]
            let originalOriginTab = origin.activeID
            var sequenceOrdinal = 0
            var lastActivePane: BrowserViewController?
            var lastActiveTab: UUID?
            var lastActiveResponder: NSResponder?
            func active() -> Bool { jobID != nil && queue.state.active?.id == jobID }
            func command(_ kind: String, interval: String, paneIndex: Int = 2, perform: () throws -> Bool,
                         settled condition: () -> Bool) async throws {
                try require(commands.count < 64, "commandBound")
                let requested = now(), activeAtRequest = active()
                let accepted = try perform(), acceptedAt = now(), activeAtAcceptance = active()
                try require(accepted, "commandAcceptance")
                let acceptedPane = workspace.activePaneID, acceptedTab = workspace.activeBrowser.activeID
                let acceptedFileFocus = window.firstResponder === workspace.activeBrowser.activeFileView
                if interval == "active" && activeAtAcceptance {
                    lastActivePane = workspace.activeBrowser
                    lastActiveTab = workspace.activeBrowser.activeID
                    lastActiveResponder = window.firstResponder
                }
                try await wait(condition, seconds: 5)
                let settledAt = now()
                commands.append(["kind": kind, "interval": interval, "sequence": sequenceOrdinal, "paneIndex": paneIndex,
                    "acceptedPaneID": acceptedPane.uuidString, "acceptedTabID": acceptedTab.uuidString,
                    "acceptedFileFocus": acceptedFileFocus, "requestNanoseconds": requested,
                    "acceptanceNanoseconds": acceptedAt, "settledNanoseconds": settledAt,
                    "activeAtRequest": activeAtRequest, "activeAtAcceptance": activeAtAcceptance,
                    "activeAtSettle": active(), "accepted": accepted,
                    "settleSeconds": seconds(requested, settledAt)])
            }
            func sequence(_ interval: String) async throws -> Bool {
                sequenceOrdinal += 1
                let first = commands.count
                if interval == "active" && !active() { return false }
                workspace.activate(commandPane)
                // Each sequence returns to the same first tab/source visit.
                // Idle/active/post therefore execute the same folder workloads.
                try require(commandPane.activeID == fixedTabs[0], "sequenceTabOrigin")
                for target in [history, source] {
                    if interval == "active" && !active() { return false }
                    try await command("address", interval: interval, perform: {
                        commandPane.focusLocation(nil)
                        let editing = !commandPane.pathField.isHidden
                            && (window.firstResponder === commandPane.pathField
                                || window.firstResponder === commandPane.pathField.currentEditor())
                        commandPane.pathField.stringValue = target.path
                        commandPane.locationEntered(commandPane.pathField)
                        return editing && commandPane.location.directoryURL == target
                    }, settled: {
                        !commandPane.isLoading && commandPane.orderingTask == nil
                            && commandPane.location.directoryURL == target && commandPane.pathField.isHidden
                            && commandPane.displayedEntries.count == (target == source ? 1024 : 0)
                            && window.firstResponder === commandPane.activeFileView
                    })
                }
                for _ in 0..<2 {
                    if interval == "active" && !active() { return false }
                    let nextIndex = (commandPane.activeIndex + 1) % 2
                    let nextID = fixedTabs[nextIndex], nextLocation = commandPane.tabs[nextIndex].location
                    try await command("tab", interval: interval, perform: {
                        commandPane.cycleTab(backward: false)
                        return commandPane.activeID == nextID && commandPane.location == nextLocation
                    }, settled: { !commandPane.isLoading && commandPane.orderingTask == nil
                        && commandPane.activeID == nextID && commandPane.location == nextLocation
                        && commandPane.displayedEntries.count == (nextLocation.directoryURL == source ? 1024 : 0) })
                }
                for (index, pane) in panes.enumerated() {
                    if interval == "active" && !active() { return false }
                    try await command("paneFocus", interval: interval, paneIndex: index, perform: {
                        workspace.activate(pane); pane.focusBrowserContent()
                        return workspace.activeBrowser === pane && window.firstResponder === pane.activeFileView
                    }, settled: { workspace.activeBrowser === pane && window.firstResponder === pane.activeFileView })
                }
                try require(commandPane.tabs.map(\.id) == fixedTabs && origin.activeID == originalOriginTab
                    && panes.reduce(0, { $0 + $1.tabs.count }) == 8, "stableTabs")
                return commands[first...].allSatisfy {
                    $0["activeAtRequest"] as? Bool == true && $0["activeAtAcceptance"] as? Bool == true
                        && $0["activeAtSettle"] as? Bool == true
                }
            }
            stage = "idleBaseline"
            timer = Timer(timeInterval: 0.01, repeats: true) { _ in recorder.tick() }
            timer?.tolerance = 0
            RunLoop.main.add(timer!, forMode: .common)
            let idleStart = now(), idleUsage = try GroupedResponsivenessUsage()
            _ = try await sequence("idle")
            try await pauseUntil(idleStart + 3_000_000_000)
            let idleEnd = now(), idleEndUsage = try GroupedResponsivenessUsage()
            windows.append(["name": "idle", "startNanoseconds": idleStart, "endNanoseconds": idleEnd,
                "usage": idleEndUsage.interval(from: idleUsage, duration: seconds(idleStart, idleEnd))])
            stage = "queuePreparation"
            queue.pause(); workspace.activate(origin)
            browser.settings.transferMetadata = .strict; browser.settings.groupedCopyPreview = true
            let preparationStart = now()
            origin.pasteFileURLs(nil)
            try require(queue.state.waiting.count == 1 && queue.state.outstandingCount == 1, "oneQueuedJob")
            jobID = queue.state.waiting[0].id
            browser.settings.groupedCopyPreview = false
            try await wait({ queue.state.waiting.first?.id == jobID && queue.state.waiting.first?.phase == .ready }, seconds: 60)
            let prepared = now()
            try require(queue.copyExecutionForVerification(jobID!)?.request == .previewIfAvailable, "capturedPreview")
            queue.progressForVerification = { progress in recorder.progress(progress) }
            origin.showTransferQueue(nil)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let resume = descendants(origin.transferQueueDetails).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Resume Queue" }) else { throw Failure(message: "resumeControl") }
            let exposed = NSAccessibility.unignoredDescendant(of: resume) as? any NSAccessibilityProtocol
            try require(resume.isEnabled && exposed?.accessibilityRole() == .button
                && (exposed?.accessibilityLabel() ?? exposed?.accessibilityTitle()) == "Resume Queue"
                && window.firstResponder === resume, "resumeControl")
            var seenActive = false
            var terminalObserved: UInt64?
            var terminalUsage: GroupedResponsivenessUsage?
            stateObservation = queue.$revision.sink { _ in
                if queue.state.active?.id == jobID { seenActive = true }
                else if seenActive && !queue.hasOutstandingWork && terminalObserved == nil {
                    terminalObserved = now()
                    terminalUsage = try? GroupedResponsivenessUsage()
                }
            }
            let resumeAt = now(); resume.performClick(nil)
            try await wait({ active() || !queue.hasOutstandingWork }, seconds: 60)
            let activeObserved = now()
            try require(active(), "insufficientWorkerOverlap")
            try await wait({ recorder.snapshot.firstCopy != nil || !active() }, seconds: 60)
            guard let firstCopy = recorder.snapshot.firstCopy, active() else { throw Failure(message: "insufficientCopyProgress") }
            try require(queue.copyExecutionForVerification(jobID!)?.decision == .groupedCopy(maximumMembersPerGroup: 16), "actualGroup16")
            origin.transferQueueDetails.onClose?()
            stage = "activeBrowsing"
            let activeStart = now(), activeUsage = try GroupedResponsivenessUsage()
            var overlappingSequences = 0
            while active() && commands.count + 16 <= 64 {
                if try await sequence("active") { overlappingSequences += 1 }
            }
            try await wait({ !queue.hasOutstandingWork }, seconds: 180)
            guard let activeEnd = terminalObserved, let activeEndUsage = terminalUsage,
                  activeEnd > activeStart else { throw Failure(message: "terminalObservation") }
            stateObservation?.cancel(); stateObservation = nil
            windows.append(["name": "active", "startNanoseconds": activeStart, "endNanoseconds": activeEnd,
                "usage": activeEndUsage.interval(from: activeUsage, duration: seconds(activeStart, activeEnd))])
            report["queueJobID"] = jobID!.uuidString
            report["queuePreparation"] = ["startNanoseconds": preparationStart, "readyNanoseconds": prepared,
                "resumeNanoseconds": resumeAt, "activeObservedNanoseconds": activeObserved,
                "firstCopyProgressNanoseconds": firstCopy, "terminalObservedNanoseconds": activeEnd,
                "preparationSeconds": seconds(preparationStart, prepared), "completeOverlappingSequences": overlappingSequences]
            stage = "postBaseline"
            for pane in panes { try await settled(pane) }
            stage = "completionFocusOwnership"
            guard let expectedPane = lastActivePane, let expectedTab = lastActiveTab,
                  let expectedResponder = lastActiveResponder else { throw Failure(message: "noActiveFocusReceipt") }
            let focusPreserved = workspace.activeBrowser === expectedPane && expectedPane.activeID == expectedTab
                && window.firstResponder === expectedResponder
            report["completionFocus"] = ["preserved": focusPreserved, "expectedPaneWasOrigin": expectedPane === origin,
                "originTabPreserved": origin.activeID == originalOriginTab]
            try require(focusPreserved && origin.activeID == originalOriginTab, "completionFocusOwnership")
            // A naturally partial last sequence may finish on either precreated
            // tab. Rebind for post baseline outside the active interval, openly.
            workspace.activate(commandPane); commandPane.selectTab(fixedTabs[0]); try await settled(commandPane)
            commandPane.navigate(to: .directory(source)); try await settled(commandPane)
            stage = "postBaseline"
            let postStart = now(), postUsage = try GroupedResponsivenessUsage()
            _ = try await sequence("post")
            try await pauseUntil(postStart + 3_000_000_000)
            let postEnd = now(), postEndUsage = try GroupedResponsivenessUsage()
            timer?.invalidate(); timer = nil
            windows.append(["name": "post", "startNanoseconds": postStart, "endNanoseconds": postEnd,
                "usage": postEndUsage.interval(from: postUsage, duration: seconds(postStart, postEnd))])
            stage = "exactOutcome"
            guard queue.results.count == 1, let result = queue.results.first, result.id == jobID,
                  let id = result.outcome.recordID else { throw Failure(message: "exactOutcome") }
            recordID = id
            try require(result.outcome.result.disposition == .succeeded && !result.outcome.result.cancellationRequested
                && result.copyExecution == .previewIfAvailable && result.executionDecision == .groupedCopy(maximumMembersPerGroup: 16)
                && result.engine === engine && result.sources == inputs && result.destination == destination
                && result.outcome.result.items.count == 1024
                && result.outcome.result.items.allSatisfy { item in
                    item.role == .transfer && item.status == .succeeded
                        && item.source.map { item.destination == destination.appendingPathComponent($0.lastPathComponent) } == true
                }
                && Set(result.outcome.result.items.compactMap(\.source)) == Set(inputs)
                && Set(result.outcome.result.items.compactMap(\.destination)) == Set(inputs.map { destination.appendingPathComponent($0.lastPathComponent) })
                && !queue.hasOutstandingWork && browser.operationCoordinator.activeOwner == nil
                && browser.operationCoordinator.preparationOwner == nil, "exactOutcome")
            stage = "sourceAfter"
            let preserved = try await Task.detached { try responsivenessSourceFingerprint(source) }.value
            try require(originalSource == preserved, "sourcePreserved")
            stage = "readOnlyHistory"
            let records = try await engine.recoveryRecords(limit: 2)
            let review = try await engine.prepareGroupedRecovery(recordID: id)
            let secondReview = try await engine.prepareGroupedRecovery(recordID: id)
            try require(records.records.count == 1 && records.nextCursor == nil && records.refusedEntries.isEmpty
                && review.items.count == 1024 && review.items.allSatisfy { $0.state == .copied }
                && review.revision == secondReview.revision && review.state == secondReview.state
                && RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal")).copyPreviewAvailability == .qualificationPending,
                "readOnlyHistory")
            let raw = recorder.snapshot
            report["rawTickNanoseconds"] = raw.ticks; report["commands"] = commands; report["intervals"] = windows
            report["recordID"] = id.uuidString; report["workerDrained"] = true; report["sourcePreserved"] = true
            report["returnedTransferCount"] = 1024; report["recordRevision"] = review.revision
            let statistics = windows.map { responsivenessStatistics(raw.ticks, start: $0["startNanoseconds"] as! UInt64,
                end: $0["endNanoseconds"] as! UInt64) }
            report["tickStatistics"] = statistics
            let idleP99 = statistics[0]["p99Milliseconds"] as! Double
            let activeStats = statistics[1]
            let enough = (activeStats["sampleCount"] as! Int) >= 100 && overlappingSequences >= 1
            report["sufficient"] = enough
            report["acceptance"] = ["activeP99LimitMilliseconds": max(50, 2 * idleP99), "activeMaxLimitMilliseconds": 250,
                "minimumActiveTicks": 100, "requiredCompleteOverlappingSequences": 1, "navigationSettleLimitSeconds": 5]
            stage = "acceptance"
            try require(!raw.overflow && !raw.wrongThread
                && (statistics[0]["sampleCount"] as! Int) >= 100 && (statistics[2]["sampleCount"] as! Int) >= 100, "recorderIntegrity")
            try require(enough, "insufficientSample")
            try require(commands.filter { $0["interval"] as? String == "active" }.allSatisfy {
                $0["activeAtRequest"] as? Bool == true && $0["activeAtAcceptance"] as? Bool == true
            }, "activeCommandOverlap")
            try require((activeStats["p99Milliseconds"] as! Double) <= max(50, 2 * idleP99)
                && (activeStats["maxMilliseconds"] as! Double) <= 250
                && (activeStats["maxBoundarySilenceMilliseconds"] as! Double) <= 250, "runLoopThreshold")
            report["passed"] = true
        } catch {
            report["failureStage"] = stage; report["recordID"] = recordID.map { $0.uuidString as Any } ?? NSNull()
            report["rawTickNanoseconds"] = recorder.snapshot.ticks; report["commands"] = commands; report["intervals"] = windows
            timer?.invalidate(); timer = nil
            queue.pause()
            if let jobID { _ = queue.cancelWaiting(jobID) }
            if queue.state.active?.id == jobID { queue.stopActive() }
            writeFailureBeforeDrain()
            // Never release engine/lease while its worker runs. Parent's declared
            // App timeout kills+waits only this child if actual drain is stuck.
            while queue.hasOutstandingWork { try? await Task.sleep(for: .milliseconds(30)) }
            report["workerDrained"] = true
            report["recordID"] = queue.results.first?.outcome.recordID.map { $0.uuidString as Any } ?? NSNull()
            report["failedRunReturnedDisposition"] = queue.results.first?.outcome.result.disposition.rawValue ?? "noResult"
        }
        return report
    }

    nonisolated private static func responsivenessStatistics(_ ticks: [UInt64], start: UInt64, end: UInt64) -> [String: Any] {
        let samples = ticks.filter { $0 >= start && $0 <= end }
        let gaps = zip(samples, samples.dropFirst()).map { Double($1 - $0) / 1_000_000 }.sorted()
        func percentile(_ p: Double) -> Double {
            guard !gaps.isEmpty else { return 0 }
            return gaps[max(0, Int(ceil(Double(gaps.count) * p)) - 1)]
        }
        let leading = samples.first.map { Double($0 - start) / 1_000_000 } ?? Double(end - start) / 1_000_000
        let trailing = samples.last.map { Double(end - $0) / 1_000_000 } ?? Double(end - start) / 1_000_000
        return ["maxBoundarySilenceMilliseconds": max(leading, trailing), "sampleCount": samples.count, "gapCount": gaps.count, "durationSeconds": Double(end - start) / 1_000_000_000,
            "p50Milliseconds": percentile(0.5), "p95Milliseconds": percentile(0.95), "p99Milliseconds": percentile(0.99),
            "maxMilliseconds": gaps.last ?? 0, "above50Milliseconds": gaps.filter { $0 > 50 }.count,
            "above100Milliseconds": gaps.filter { $0 > 100 }.count, "above250Milliseconds": gaps.filter { $0 > 250 }.count,
            "missed10msIntervals": gaps.reduce(0) { $0 + max(0, Int(floor($1 / 10)) - 1) },
            "percentileRule": "Nearest rank ceil(p*N), adjacent callbacks wholly within interval"]
    }

    /// Own generated files only, off main actor, bounded to original1024x256B.
    nonisolated private static func responsivenessSourceFingerprint(_ source: URL) throws -> String {
        let expectedNames = Set((0..<1024).map { "generated-\($0).dat" })
        let root = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard root >= 0 else { throw Failure(message: "sourceOpen") }; defer { close(root) }
        let listing = dup(root)
        guard listing >= 0 else { throw Failure(message: "sourceListing") }
        guard let cursor = fdopendir(listing) else { close(listing); throw Failure(message: "sourceListing") }
        defer { closedir(cursor) }
        var names = Set<String>()
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(cursor) else {
                guard errno == 0 else { throw Failure(message: "sourceListing") }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw Failure(message: "sourceName") }
            if name == "." || name == ".." { continue }
            guard names.count < 1024, names.insert(name).inserted else { throw Failure(message: "sourceBound") }
        }
        guard names == expectedNames else { throw Failure(message: "sourceInventory") }
        var hasher = SHA256()
        for ordinal in 0..<1024 {
            try Task.checkCancellation()
            let fd = openat(root, "generated-\(ordinal).dat", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure(message: "sourceFile") }; defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
                  before.st_uid == geteuid(), before.st_mode & 0o077 == 0, before.st_size == 256 else { throw Failure(message: "sourceShape") }
            var data = [UInt8](repeating: 0, count: 257)
            let count = Darwin.read(fd, &data, data.count)
            guard count == 256, fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure(message: "sourceStable") }
            hasher.update(data: Data("\(ordinal):\(before.st_dev):\(before.st_ino):\(before.st_mode):\(before.st_uid):\(before.st_gid):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec)".utf8))
            hasher.update(data: Data(data.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
