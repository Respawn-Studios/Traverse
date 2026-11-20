#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage
import ObjectiveC

/// Existing native Details owner with generated observations and held failures.
@MainActor enum DriveStorageStatusVerification {
    private enum Failure: Error { case scope, check(UInt), wait(String) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws {
        if !value { throw Failure.check(line) }
    }
    private static func wait(_ stage: String? = nil, _ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            if let stage, ContinuousClock.now >= end { throw Failure.wait(stage) }
            try require(.now < end); try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run() async {
        var area: URL?, owner: ApplicationDriveDetails?, held: Reader?, healthReader: HealthReader?
        var checks: [String] = [], clips: [[String: Any]] = [], failure: UInt?, texts: [String] = []
        var failureKind: String?
        var waitStage: String?, liveFailureFacts: [String: Any] = [:]
        var actualHealth: ApplicationDriveDetails?, nativeHealth: [String: Any] = [:]
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let root = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
                && marker?["action"] as? String == "native-drive-storage-status"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            area = root
            try await verifyAPFSRequestPermission()
            checks.append("Shared APFS request permission tracks pre-submission cancellation, exact drained owner and post-submission refusal without native requests")
            let large = ProcessInfo.processInfo.arguments.contains("--large-interface")
            let record = ProcessInfo.processInfo.arguments.contains("--record-storage-status")
            let review = ProcessInfo.processInfo.arguments.contains("--review-storage-status")
            let settings = BrowserSettings(persist: false)
            settings.driveHealthLiveUpdates = false // This flow checks explicit one-shot lifetime; live sampling is exercised separately.
            settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.appearance = large ? .light : .dark; settings.interfaceSize = .init(large ? 150 : 100)
            settings.motion.mode = large ? .reduced : .full; InterfacePresentation.shared.bind(settings)
            let reader = Reader(); held = reader
            var handoffs = 0
            let model = ApplicationDriveDetails(reader: reader, utilityHandoff: { handoffs += 1; return true }); owner = model
            let a = volume("Generated SSD", internalDisk: true), b = volume("Generated other drive"), c = volume("Generated unmounted media", mounted: false)
            model.show(a, settings: settings)
            try await wait { !model.isReading && model.inspection != nil }
            guard let window = model.window, let original = model.inspection else { throw Failure.scope }
            window.title = "Drive Details · generated review · storage status"
            window.setContentSize(.init(width: large ? 780 : 620, height: large ? 710 : 610)); window.center()
            checks.append("Initial Details uses only the generated verified observation; no device or external action")

            reader.arm(.unavailable); model.refresh(); try await wait { reader.isHeld }
            // Exact red: the old model clears its useful observation here.
            try require(model.inspection?.capturedAt == original.capturedAt && model.isReading)
            checks.append("Same-target Refresh retains the previous observation while the actual reader is held")
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)); try require(model.isReading) }
            if record {
                let capture = try await NativeMotionRecorder.record(window: window, root: root, label: "drive-status-refresh",
                    sampling: .diagnostic(for: window)) { reader.release() }
                try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/drive-status-refresh.json"), options: .withoutOverwriting)
                clips.append(["label": "drive-status-refresh", "frames": capture.frames.count, "dropped": capture.droppedEncoderFrames])
            } else { reader.release() }
            await model.drain()
            try require(model.inspection?.capturedAt == original.capturedAt && !model.notice.isEmpty && !model.isReading)
            try await wait { visibleTexts(window).joined(separator: " ").contains("Previous check") }
            reader.wrongTarget = b; model.refresh(); await model.drain()
            try require(model.inspection?.capturedAt == original.capturedAt && !model.notice.isEmpty)
            reader.wrongTarget = nil
            checks.append("Failed Refresh keeps useful facts visibly marked Previous check; failure never becomes current")

            model.refresh(); await model.drain()
            try require(model.inspection?.volume == a && model.inspection?.capturedAt != original.capturedAt && model.notice.isEmpty)
            try await wait { !visibleTexts(window).joined(separator: " ").contains("Previous check") }
            checks.append("Successful retry installs new facts and clears the stale notice")

            reader.writable = nil; reader.arm(nil); model.show(b, settings: settings)
            try require(model.inspection == nil)
            try await wait { reader.isHeld }; reader.release(); await model.drain()
            try require(model.inspection?.volume == b && model.inspection?.fields.writable == nil)
            try await wait { let value = visibleTexts(window).joined(separator: " "); return value.contains("Storage status") && value.contains("Not reported") && value.contains("Not measured") }
            checks.append("A different target clears old facts; unknown media capability is not reported as writable or healthy")

            reader.writable = false; model.show(c, settings: settings); await model.drain()
            try require(model.inspection?.volume == c && reader.maximumConcurrent == 1 && handoffs == 0)
            window.title = "Drive Details · generated review · storage status"
            try await wait { let value = visibleTexts(window).joined(separator: " "); return value.contains("Not mounted") && value.contains("Read-only media") && value.contains("Not measured") }
            texts = visibleTexts(window)
            checks.append("Mount state, media capability and unmeasured hardware health remain distinct in the native view")

            if review {
                try Data("generated storage status ready".utf8).write(to: root.appendingPathComponent("state/Ready"), options: .withoutOverwriting)
                let end = ContinuousClock.now + .seconds(90)
                while window.isVisible && .now < end { try await Task.sleep(for: .milliseconds(30)) }
            }
            if model.window == nil { model.show(c, settings: settings); await model.drain() }
            let unsupported = HealthReader()
            unsupported.next = .init(outcome: .unavailable(.unsupported), childReaped: true, nativeCleanupConfirmed: true)
            model.healthCheckForVerification = { selected in await unsupported.check(selected) }
            model.checkHardwareHealth(); await model.drainHealth()
            try require(unsupported.calls == 1 && model.health == .unavailable(.unsupported) && model.healthMeasurements == nil
                && model.healthReadingSummary == nil)
            checks.append("An external candidate uses the same bounded reader; unsupported connection does not become a healthy reading")
            let hardware = HealthReader(); healthReader = hardware
            model.healthCheckForVerification = { selected in await hardware.check(selected) }
            model.show(a, settings: settings); await model.drain()
            window.title = "Drive Details · generated review · storage status"
            if record { hardware.hold = true }
            model.checkHardwareHealth()
            if record {
                try await wait { hardware.isHeld }
                let capture = try await NativeMotionRecorder.record(window: window, root: root, label: "drive-health-readings",
                    sampling: .diagnostic(for: window)) { hardware.release() }
                try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/drive-health-readings.json"), options: .withoutOverwriting)
                clips.append(["label": "drive-health-readings", "frames": capture.frames.count, "dropped": capture.droppedEncoderFrames])
            }
            await model.drainHealth()
            try require(hardware.calls == 1 && model.health == hardware.next.outcome && !model.isCheckingHealth
                && model.healthMeasurements == hardware.next.nvmeMeasurements)
            try await wait {
                let text = visibleTexts(window).joined(separator: " ")
                return text.contains("No critical warning reported") && text.contains("37 °C")
                    && text.contains("97%") && text.contains("12%") && text.contains("Media/data errors")
            }
            let retainedHealth = model.health
            let summary = model.healthReadingSummary
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try require(summary?.contains("SMART reading (NVMe)") == true && summary?.contains("Captured ") == true
                && summary?.contains("Temperature 37 °C") == true && summary?.contains("Spare capacity 97%") == true
                && summary?.contains("Endurance used 12%") == true && summary?.contains("Previous reading") == false
                && model.copyHealthReading(to: board) && board.string(forType: .string) == summary && hardware.calls == 1)
            model.refresh(); await model.drain()
            try require(model.health == retainedHealth && hardware.calls == 1
                && model.healthMeasurements == hardware.next.nvmeMeasurements)
            checks.append("Explicit health readings retain precise NVMe measurements and their own capture time; metadata Refresh performs no second health read")
            let childReading = hardware.next
            hardware.next = .init(outcome: childReading.outcome, transport: .serviceReply(settled: true),
                nativeCleanupConfirmed: true, nvmeMeasurements: childReading.nvmeMeasurements)
            model.checkHardwareHealth(); await model.drainHealth()
            try require(!hardware.next.childReaped && hardware.next.transportSettled
                && model.healthMeasurements == childReading.nvmeMeasurements && !model.hasPendingHealthCheck
                && !model.hasUncertainHealthState && ApplicationFileActivity.gate.activeCount == 0)
            hardware.next = .init(outcome: .unavailable(.stale), transport: .serviceReply(settled: true),
                nativeCleanupConfirmed: true, nvmeMeasurements: childReading.nvmeMeasurements)
            model.checkHardwareHealth(); await model.drainHealth()
            try require(model.health == retainedHealth && model.healthMeasurements == childReading.nvmeMeasurements && model.healthIsStale
                && !model.hasPendingHealthCheck && ApplicationFileActivity.gate.activeCount == 0)
            try require(model.healthReadingSummary?.contains("Previous reading") == true)
            try await wait { visibleTexts(window).contains("Previous reading") }
            checks.append("A settled service reply releases activity without child-reap evidence; a failed refresh preserves the dated previous reading and pauses live sampling")
            hardware.next = childReading
            model.checkHardwareHealth(); await model.drainHealth()
            hardware.hold = true; model.checkHardwareHealth()
            try await wait { hardware.isHeld }
            try require(model.health == retainedHealth && model.healthMeasurements == hardware.next.nvmeMeasurements)
            model.window?.close()
            try require(model.hasPendingHealthCheck && ApplicationFileActivity.gate.activeCount > 0 && model.health == nil)
            hardware.release(); await model.drainHealth()
            try require(!model.hasPendingHealthCheck && model.health == nil && model.healthMeasurements == nil && model.healthReadingSummary == nil
                && !model.copyHealthReading(to: board) && board.string(forType: .string) == summary
                && ApplicationFileActivity.gate.activeCount == 0)
            checks.append("Closing suppresses stale health publication and keeps actual work/activity owned through its return")
            let liveBaseline = hardware.calls
            hardware.hold = true
            model.healthCheckForVerification = { selected in
                let result = await hardware.check(selected)
                return .init(outcome: .warning(kind: .nvme, rawByte: 0, capturedAt: Date()),
                    transport: result.transport, nativeCleanupConfirmed: result.nativeCleanupConfirmed,
                    nvmeMeasurements: result.nvmeMeasurements)
            }
            settings.driveHealthLiveUpdates = true
            model.show(a, settings: settings); await model.drain()
            guard let liveWindow = model.window else { throw Failure.scope }
            // Closing the only window can leave the app behind the controller.
            // Establish the generated window's real visibility, rather than
            // weakening the product's occlusion/non-overlap admission checks.
            liveWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("health-live-window-visible") {
                NSApp.isActive && liveWindow.isVisible && !liveWindow.isMiniaturized && liveWindow.occlusionState.contains(.visible)
            }
            try await wait("health-live-first-read-held") { hardware.isHeld }
            try await Task.sleep(for: .milliseconds(1_100))
            try require(hardware.calls == liveBaseline + 1 && model.hasPendingHealthCheck)
            hardware.release()
            try await wait("health-live-next-sample") { hardware.calls >= liveBaseline + 2 && model.healthHistory.count >= 2 }
            if let live = model.window {
                try await UIVerification.snapshot(live, to: root.appendingPathComponent("evidence/drive-health-live.png"))
            }
            model.window?.orderOut(nil); await model.drainHealth()
            let hiddenCount = hardware.calls
            try await Task.sleep(for: .milliseconds(1_100))
            try require(hardware.calls == hiddenCount)
            settings.driveHealthLiveUpdates = false; model.pauseHealthMonitoring()
            model.healthCheckForVerification = { selected in await hardware.check(selected) }
            checks.append("Visible one-second live readings reuse one native owner, never overlap a held read and stop admitting work while hidden")
            model.show(a, settings: settings); await model.drain()
            hardware.next = .init(outcome: .unavailable(.uncertain), childReaped: true, nativeCleanupConfirmed: false)
            model.checkHardwareHealth(); await model.drainHealth()
            try require(model.hasUncertainHealthState && !model.canCheckHealth && !model.hasPendingHealthCheck
                && ApplicationFileActivity.gate.activeCount == 0)
            checks.append("An abnormal reaped health result fences further checks while releasing only its ended process lifetime")

            reader.arm(nil); model.refresh(); try await wait { reader.isHeld }
            model.window?.close()
            var drained = false
            let task = Task { await model.drain(); drained = true }
            try await Task.sleep(for: .milliseconds(40))
            try require(!drained && model.isReading && model.window == nil && model.inspection == nil)
            reader.release(); await task.value
            try require(!model.isReading && model.inspection == nil && reader.maximumConcurrent == 1 && handoffs == 0)
            checks.append("Closing retires the window but retains and drains the actual held reader without stale publication")
            if ProcessInfo.processInfo.arguments.contains("--sample-selected-internal-health") {
                try require(marker?["healthSamplesMaximum"] as? Int == 5)
                let backend = VolumeLifecycle.shared
                var target: ManagedVolume?
                for _ in 0..<50 {
                    target = await backend.observationsForQualification().first { $0.isInternal == true && $0.url?.path == "/" && $0.mediaID != nil }
                    if target != nil { break }
                    try await Task.sleep(for: .milliseconds(40))
                }
                guard let target else { throw Failure.scope }
                let actual = ApplicationDriveDetails(reader: backend, utilityHandoff: { false }); actualHealth = actual
                let live = BrowserSettings(persist: false); live.navigationStyle = .glass; live.appearance = .dark
                live.driveHealthLiveUpdates = true; live.driveHealthIntervalSeconds = 1
                actual.show(target, settings: live); actual.window?.title = "Drive Health · actual read-only cadence check"
                await actual.drain()
                let end = ContinuousClock.now + .seconds(20)
                while actual.healthRequestsStarted < 5 && ContinuousClock.now < end {
                    if case .unavailable = actual.health { break }
                    try await Task.sleep(for: .milliseconds(15))
                }
                live.driveHealthLiveUpdates = false; actual.pauseHealthMonitoring(); await actual.drainHealth()
                try require(actual.healthRequestsStarted > 0 && actual.healthRequestsStarted <= 5
                    && !actual.hasPendingHealthCheck && !actual.hasUncertainHealthState)
                if case .warning = actual.health { try require(actual.healthHistory.count == 5) }
                let dates = actual.healthHistory.map(\.capturedAt)
                let intervals = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) * 1000 }
                nativeHealth = ["requestedIntervalSeconds": 1, "requests": actual.healthRequestsStarted,
                    "successfulSamples": dates.count, "sampleIntervalsMilliseconds": intervals,
                    "actualSamplingQualified": dates.count == 5,
                    "nvmeMeasurementsAvailable": actual.healthMeasurements != nil,
                    "actualProcessDrained": !actual.hasPendingHealthCheck]
                if let window = actual.window, CGPreflightScreenCaptureAccess() {
                    try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/actual-health-cadence.png"))
                }
                await actual.closeAndDrain()
                checks.append("Actual selected internal-drive cadence uses the same one-shot owner, at most five read-only requests and confirmed process cleanup; unavailable is not healthy")
            }
        } catch {
            if case let Failure.check(line) = error { failure = line; failureKind = "check" }
            else if case let Failure.wait(stage) = error {
                failure = 0; failureKind = "wait"; waitStage = stage
                liveFailureFacts = ["appActive": NSApp.isActive, "windowVisible": owner?.window?.isVisible == true,
                    "windowMiniaturized": owner?.window?.isMiniaturized == true,
                    "windowOcclusionVisible": owner?.window?.occlusionState.contains(.visible) == true,
                    "readerEligible": owner?.healthReaderAvailable == true, "canCheckHealth": owner?.canCheckHealth == true,
                    "hasPendingHealthCheck": owner?.hasPendingHealthCheck == true,
                    "generatedReaderCalls": healthReader?.calls ?? 0, "historyCount": owner?.healthHistory.count ?? 0]
            }
            else if let motion = error as? NativeMotionRecorder.Failure { failure = 0; failureKind = "motion." + motion.rawValue }
            else { failure = 0; failureKind = "native-flow" }
        }
        held?.release(); healthReader?.release(); await owner?.closeAndDrain(); await actualHealth?.closeAndDrain()
        if let area {
            let report: [String: Any] = ["passed": failure == nil, "checks": checks, "clips": clips, "visibleTexts": texts,
                "line": failure.map { $0 as Any } ?? NSNull(), "failure": failureKind.map { $0 as Any } ?? NSNull(), "deviceActions": 0,
                "waitStage": waitStage as Any? ?? NSNull(), "liveFailureFacts": liveFailureFacts,
                "hardwareSamples": nativeHealth["successfulSamples"] ?? 0, "nativeHealth": nativeHealth,
                "externalApplications": 0, "fileBodyReads": 0, "drained": owner?.isReading != true]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: area.appendingPathComponent("evidence/native-storage-status.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    @MainActor private final class HealthReader {
        var next = DriveHealthReport(outcome: .warning(kind: .nvme, rawByte: 0,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)), childReaped: true, nativeCleanupConfirmed: true,
            nvmeMeasurements: NVMeHealthMeasurements(temperatureKelvin: 310, availableSpare: 97,
                spareThreshold: 10, percentageUsed: 12,
                counters: [1_000_000, 2_000_000, 500, 600, 70, 121, 2_000, 3, 0, 4]))
        var hold = false
        private var continuation: CheckedContinuation<DriveHealthReport, Never>?
        private(set) var calls = 0
        var isHeld: Bool { continuation != nil }
        func check(_ selected: ManagedVolume) async -> DriveHealthReport {
            calls += 1
            if hold { return await withCheckedContinuation { continuation = $0 } }
            return next
        }
        func release() { hold = false; let old = continuation; continuation = nil; old?.resume(returning: next) }
    }
    private static func verifyAPFSRequestPermission() async throws {
        let gate = FileActivityGate()
        let permission = NativeAPFSRequestPermission(activity: gate)
        try require(!permission.allowed && !permission.wasSubmitted)
        permission.start()
        try require(permission.allowed && permission.cancelBeforeSubmission() && !permission.allowed)

        permission.start()
        var lease: FileActivityGate.Lease? = try gate.begin()
        guard let token = gate.closeAdmission() else { throw Failure.check(#line) }
        permission.requireDrained(token, protectionCurrent: { true })
        try withExtendedLifetime(lease) { try require(!permission.allowed) }
        lease = nil
        try require(gate.activeCount == 0 && permission.allowed)
        await Task.detached { permission.markSubmitted() }.value
        try require(permission.wasSubmitted && !permission.cancelBeforeSubmission()
            && permission.wasSubmitted && permission.allowed)
        permission.reset()
        try require(!permission.allowed && !permission.wasSubmitted && gate.reopen(token))

        let foreignGate = FileActivityGate()
        guard let foreignToken = foreignGate.closeAdmission() else { throw Failure.check(#line) }
        permission.start()
        permission.requireDrained(foreignToken, protectionCurrent: { true })
        try require(!permission.allowed && permission.cancelBeforeSubmission())
        try require(foreignGate.reopen(foreignToken))

        permission.start()
        guard let nextToken = gate.closeAdmission() else { throw Failure.check(#line) }
        permission.requireDrained(nextToken, protectionCurrent: { false })
        try require(!permission.allowed)
        permission.reset()
        try require(gate.reopen(nextToken))
        permission.start()
        try require(permission.allowed && !permission.wasSubmitted)
        permission.reset()
    }
    private static func volume(_ name: String, mounted: Bool = true, internalDisk: Bool = false) -> ManagedVolume {
        .init(id: UUID(), name: name, url: mounted ? URL(fileURLWithPath: "/Generated/StorageStatus/" + name) : nil,
              isInternal: internalDisk, canMount: !mounted, canUnmount: mounted, canEject: !internalDisk, fileSystemID: 42, group: 43, mediaID: 44)
    }
    private final class Reader: VolumeInspecting, @unchecked Sendable {
        private let queue = DispatchQueue(label: "local.traverse.generated-status-reader")
        private let condition = NSCondition()
        private var armed = false, held = false, released = false
        private var error: VolumeLifecycleFailure?, writeCapability: Bool? = true, wrong: ManagedVolume?
        private var concurrent = 0, maximum = 0
        var maximumConcurrent: Int { condition.withLock { maximum } }
        var isHeld: Bool { condition.withLock { held } }
        var writable: Bool? { get { condition.withLock { writeCapability } } set { condition.withLock { writeCapability = newValue } } }
        var wrongTarget: ManagedVolume? { get { condition.withLock { wrong } } set { condition.withLock { wrong = newValue } } }
        func arm(_ failure: VolumeLifecycleFailure?) { condition.withLock { armed = true; held = false; released = false; error = failure } }
        func release() { condition.withLock { released = true; condition.broadcast() } }
        func inspect(_ target: ManagedVolume) async throws -> VolumeInspection {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    condition.lock(); concurrent += 1; maximum = max(maximum, concurrent)
                    if armed { armed = false; held = true; condition.broadcast(); while !released { condition.wait() } }
                    let failure = error, writable = writeCapability, actual = wrong ?? target; error = nil; concurrent -= 1; condition.unlock()
                    if let failure { continuation.resume(throwing: failure) }
                    else { continuation.resume(returning: .init(volume: actual, deviceName: "generated-disk",
                        fields: .init(fileSystem: "apfs", model: "Generated device", vendor: "Fixture", transport: "USB",
                            mediaBytes: 256 << 30, outerDeviceBytes: 512 << 30, blockBytes: 4096, writable: writable, removable: true))) }
                }
            }
        }
    }
    private static func visibleTexts(_ window: NSWindow) -> [String] {
        guard let content = window.contentView else { return [] }
        func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector), method_getNumberOfArguments(method) == 2 else { return nil }
            let encoding = method_copyReturnType(method); defer { free(encoding) }
            guard String(cString: encoding).hasPrefix("@") else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var seen = Set<ObjectIdentifier>(), count = 0
        func walk(_ item: Any, _ depth: Int) -> [String] {
            guard depth < 24, count < 4096, let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            count += 1
            let role = value(object, "accessibilityRole") as? String
            let own = role == NSAccessibility.Role.staticText.rawValue || role == "AXHeading"
                ? [value(object, "accessibilityLabel"), value(object, "accessibilityValue")].compactMap { $0 as? String } : []
            var children = value(object, "accessibilityChildren") as? [Any] ?? []
            if let view = item as? NSView { children += view.subviews }
            return own + children.flatMap { walk($0, depth + 1) }
        }
        return walk(content, 0)
    }
}
#endif
