import AppKit
import Combine
import LocalStorage
import SwiftUI

/// Data/lifetime and owner-assisted actual-input/appearance checks pass.
/// This enables read-only observations, never device-action authority.
enum DriveDetailsFeature { static let ordinaryEnabled = true }

enum DriveHealthFeature {
    static var available: Bool {
        // QA roles are route-specific. The helper still checks its exact
        // identity, rights and selected attachment for any product edition.
        if GeneratedSandboxReview.admitted { return GeneratedSandboxReview.driveHealthReadAdmitted }
        return AppFeatureAvailability.allows(.driveHealth)
    }
    static var liveUpdatesAvailable: Bool {
        if GeneratedSandboxReview.admitted { return GeneratedSandboxReview.driveHealthLiveReadAdmitted }
        return AppFeatureAvailability.allows(.driveHealthLiveUpdates)
    }
    static var requiresLiveOptIn: Bool {
        !GeneratedSandboxReview.admitted && AppFeatureAvailability.policy.edition.isDeveloperID
    }
    static func liveUpdatesAvailable(for target: ManagedVolume?) -> Bool {
        guard liveUpdatesAvailable else { return false }
        // Developer ID Live requires an internal selected drive and explicit
        // opt-in. Preview and the signed QA continuation keep their own scopes.
        return !requiresLiveOptIn || target?.deviceKind == .internalDisk && target?.isInternal == true
    }
    static var liveUpdatesHelp: String {
        if liveUpdatesAvailable { return "Read the selected drive while Drives is visible. Slow readings never overlap." }
        return available ? "Use Read SMART now for a single reading."
            : "SMART readings are unavailable in this edition."
    }
}

/// One native presentation owner, one real reader and one latest pending target.
/// Closing cancels publication, not the actual worker lifetime.
@MainActor final class ApplicationDriveDetails: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ApplicationDriveDetails(reader: VolumeLifecycle.shared)
    @Published private(set) var target: ManagedVolume?
    @Published private(set) var inspection: VolumeInspection?
    @Published private(set) var isReading = false
    @Published private(set) var observationIsStale = false
    @Published private(set) var notice = ""
    @Published private(set) var health: DriveHealthOutcome?
    @Published private(set) var healthMeasurements: NVMeHealthMeasurements?
    private(set) var healthDiagnostic: DriveHealthDiagnostic?
    private(set) var lastHealthCompletion: DriveHealthDrain?
    @Published private(set) var isCheckingHealth = false
    private(set) var isAutomaticHealthCheck = false
    private(set) var healthRequestsStarted = 0
    #if TRAVERSE_SFTP_EDITOR_QA
    private(set) var automaticHealthRequestsStarted = 0
    #endif
    @Published private(set) var healthIsStopping = false
    @Published private(set) var healthNotice = ""
    @Published private(set) var healthHistory: [DriveHealthTrendPoint] = []
    private var healthHistoryInterrupted = false
    @Published private(set) var healthIsStale = false
    private weak var healthSettings: BrowserSettings?
    private var monitor: Task<Void, Never>?
    private var monitorPreferences: AnyCancellable?
    private var sleepObservations: [BrowserNotificationObservation] = []
    private var healthSleeping = false, automaticHealthBlocked = false
    /// A reaped helper does not prove a native call cleaned up. The separate
    /// fence prevents device actions without making ordinary browsing depend
    /// on a dead process or holding an I/O lease after its actual lifetime.
    private(set) var hasUncertainHealthState = false
    private let reader: any VolumeInspecting
    private let healthSession = DriveHealthSession()
    private var healthWork: Task<Void, Never>?
    private var healthInvalidation: Task<Void, Never>?
    private var healthStopRequested = false
    private var undrainedHealthActivity: (any Sendable)?
    private var healthGeneration = UUID()
    private let utilityHandoff: @MainActor () -> Bool
    private var controller: NSWindowController?
    private weak var embeddedWindow: NSWindow?
    private var pending: ManagedVolume?
    private var generation = UUID()
    private var work: Task<Void, Never>?
    var window: NSWindow? { controller?.window ?? embeddedWindow }
    var hasPendingHealthCheck: Bool { healthWork != nil || healthInvalidation != nil || undrainedHealthActivity != nil }
    /// Presentation eligibility for the reader actually composed in this build.
    /// The signed helper still performs all signature, entitlement and device
    /// admission; recognizing Preview here does not establish hardware access.
    var healthReaderUnavailableReason: String? {
        guard DriveHealthFeature.available else { return "Detailed SMART readings are unavailable in this edition." }
        #if DEBUG
        if healthCheckForVerification != nil { return nil }
        #endif
        guard DriveHealthSession.isReaderComposed else {
            return "Detailed drive health is not available in this version of Traverse."
        }
        return nil
    }
    var healthReaderAvailable: Bool { healthReaderUnavailableReason == nil }
    var canSelectLiveHealth: Bool {
        target != nil && DriveHealthFeature.liveUpdatesAvailable(for: target)
            && healthReaderAvailable && !hasUncertainHealthState
    }
    var healthTitle: String {
        if !healthReaderAvailable && !hasUncertainHealthState { return "SMART unavailable in this version" }
        guard let health else {
            return target?.deviceKind == .internalDisk || target?.deviceKind == .externalDisk
                ? "Waiting for reading" : "SMART not available on this connection"
        }
        switch health {
        case .warning(let kind, let raw, _):
            return kind == .ata ? (raw == 0 ? "No threshold warning reported" : "Threshold warning reported")
                : (raw == 0 ? "No critical warning reported" : "Critical warning reported")
        case .unavailable(let reason):
            switch reason {
            case .denied: return "Access not allowed"
            case .busy: return "Drive is busy"
            case .disconnected: return "Drive disconnected"
            case .unsupported: return "SMART not available on this connection"
            case .stale: return "Drive changed · check again"
            case .unavailable: return "Reading unavailable"
            case .uncertain: return "Hardware check needs review"
            }
        }
    }
    var lastHealthDate: Date? {
        if case .warning(_, _, let date) = health { return date }
        return nil
    }
    var healthWarning: UInt8? {
        if case .warning(_, let raw, _) = health { return raw }
        return nil
    }
    var canCheckHealth: Bool {
        healthReaderAvailable
            && target.map({ $0.deviceKind == .internalDisk || $0.deviceKind == .externalDisk && $0.isInternal == false }) == true
            && inspection?.volume == target
            && !observationIsStale && !isReading && !hasPendingHealthCheck && !hasUncertainHealthState
            && !ApplicationFileActivity.gate.isClosed
    }
    #if DEBUG
    var healthCheckForVerification: (@MainActor (ManagedVolume) async -> DriveHealthReport)? {
        didSet { objectWillChange.send(); restartHealthMonitoring() }
    }
    #endif
    init(reader: any VolumeInspecting, utilityHandoff: @escaping @MainActor () -> Bool = { DriveDiskUtilityHandoff.open() }) {
        self.reader = reader; self.utilityHandoff = utilityHandoff; super.init()
    }

    func show(_ volume: ManagedVolume, settings: BrowserSettings, offscreen: Bool = false) {
        embeddedWindow = nil
        if controller == nil {
            let host = InterfaceHostingController(rootView: DriveDetailsView(model: self, settings: settings))
            let window = ToolWindowChrome.makeWindow(title: "Drive Details", size: .init(width: 620, height: 620),
                minimumSize: .init(width: 520, height: 480), content: host)
            _ = ToolWindowChrome.install(in: window, settings: settings)
            if offscreen { window.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
            else { ToolWindowChrome.position(window, relativeTo: NSApp.mainWindow) }
            window.delegate = self; controller = NSWindowController(window: window)
            window.makeKeyAndOrderFront(nil); ToolContentMotion.reveal(window.contentView!, effect: .windows)
        } else { controller?.window?.makeKeyAndOrderFront(nil) }
        if target != volume { stopHealthCheck(); health = nil; healthMeasurements = nil; healthDiagnostic = nil; healthNotice = ""; healthHistory = []; healthIsStale = false; automaticHealthBlocked = false }
        target = volume; window?.title = "Drive Details · " + volume.name
        configureHealthMonitoring(settings: settings)
        request(volume)
    }
    /// Reuse the same inspection/health owner inside Drives. Device work stays
    /// registered with the app's existing quiescence and shutdown owners.
    func attach(_ volume: ManagedVolume, to parent: NSWindow, settings: BrowserSettings? = nil) {
        if let separate = controller?.window { separate.close() }
        embeddedWindow = parent
        if target != volume { stopHealthCheck(); health = nil; healthMeasurements = nil; healthDiagnostic = nil; healthNotice = ""; healthHistory = []; healthIsStale = false; automaticHealthBlocked = false }
        target = volume
        if let settings { configureHealthMonitoring(settings: settings) }
        request(volume)
    }
    func detach(from parent: NSWindow) {
        guard embeddedWindow === parent else { return }
        windowWillClose(Notification(name: NSWindow.willCloseNotification, object: parent))
    }
    func refresh() { automaticHealthBlocked = false; if let target { request(target) } }
    private func request(_ volume: ManagedVolume) {
        generation = UUID(); pending = volume
        if inspection?.volume != volume { inspection = nil }
        observationIsStale = inspection != nil
        notice = ""; startNext()
    }
    private func startNext() {
        guard work == nil, let next = pending, window != nil else { return }
        pending = nil; isReading = true; let ticket = generation
        work = Task { [self] in
            defer { isReading = false; work = nil; startNext() }
            do {
                let result = try await reader.inspect(next)
                guard !Task.isCancelled, generation == ticket, window != nil else { return }
                guard result.volume == next else { throw VolumeLifecycleFailure.changed }
                inspection = result; observationIsStale = false
            } catch {
                guard !Task.isCancelled, generation == ticket, window != nil else { return }
                notice = (error as? VolumeLifecycleFailure)?.userMessage ?? "Drive details could not be verified. Refresh the drive observation and reopen Details."
            }
        }
    }
    func openDiskUtility() {
        notice = utilityHandoff() ? "Disk Utility opens separately. No device action was requested." : "Disk Utility could not be opened."
    }
    func checkHardwareHealth() { startHealthCheck(automatic: false) }
    private func startHealthCheck(automatic: Bool) {
        guard canCheckHealth, let selected = target else { return }
        guard !automatic || DriveHealthFeature.liveUpdatesAvailable(for: selected) else { return }
        guard GeneratedSandboxReview.claimDriveHealthReviewRequest(for: selected, automatic: automatic) else { return }
        if !automatic { automaticHealthBlocked = false }
        let activity: any Sendable
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch { healthNotice = "A drive task is finishing. Try again when it completes."; return }
        let token = UUID(); healthGeneration = token
        let requestedInterval = healthSettings?.driveHealthIntervalSeconds ?? 1
        healthRequestsStarted += 1
        #if TRAVERSE_SFTP_EDITOR_QA
        if automatic { automaticHealthRequestsStarted += 1 }
        #endif
        let diagnostic = ApplicationDiagnostics.shared.workflow(.driveHealth, trace: token, context: .init(.driveHealth))
        if !automatic { diagnostic.event(.requested, context: .init(.driveHealth)) }
        // Keep the dated snapshot visible while a same-device check runs.
        // Selection changes and terminal failures still clear stale readings.
        isCheckingHealth = true; isAutomaticHealthCheck = automatic; healthIsStopping = false; healthNotice = ""; healthDiagnostic = nil
        lastHealthCompletion = nil
        healthWork = Task { [self] in
            defer { withExtendedLifetime(activity) {}; healthWork = nil; isCheckingHealth = false; isAutomaticHealthCheck = false; healthIsStopping = false }
            if !automatic { diagnostic.event(.reading, context: .init(.driveHealth)) }
            let report: DriveHealthReport
            #if DEBUG
            if let healthCheckForVerification { report = await healthCheckForVerification(selected) }
            else { report = await healthSession.check(selected) }
            #else
            report = await healthSession.check(selected)
            #endif
            lastHealthCompletion = report.drain
            if !report.transportSettled { undrainedHealthActivity = activity }
            let terminal: DiagnosticPhase
            var failure: DiagnosticErrorCode?
            switch report.outcome {
            case .warning: terminal = report.nativeCleanupConfirmed && report.transportSettled ? .completed : .failed
            case .unavailable(let reason):
                let code: Int64
                switch reason {
                case .denied: terminal = .blocked; code = 1
                case .busy: terminal = .blocked; code = 2
                case .disconnected: terminal = .failed; code = 3
                case .unsupported: terminal = .blocked; code = 4
                case .stale: terminal = .cancelled; code = 5
                case .unavailable: terminal = .failed; code = 6
                case .uncertain: terminal = .failed; code = 7
                }
                let errorCode: Int64
                switch report.diagnostic?.transportFailure {
                case .peerIdentity: errorCode = 101
                case .connectionEnded: errorCode = 102
                case .malformedReply: errorCode = 103
                case .deadline: errorCode = 104
                case nil: errorCode = code
                }
                failure = .init(domain: .security, code: errorCode)
            }
            if !automatic || terminal == .failed || terminal == .blocked {
                diagnostic.event(terminal, context: .init(.driveHealth), error: failure)
            }
            if !report.nativeCleanupConfirmed || !report.transportSettled {
                healthHistoryInterrupted = true
                hasUncertainHealthState = true
                automaticHealthBlocked = true
                healthIsStale = true
                if window != nil {
                    if healthGeneration == token, target == selected { healthDiagnostic = report.diagnostic }
                    health = .unavailable(.uncertain)
                    healthMeasurements = nil
                    healthNotice = "The hardware check could not finish cleanly. Further health checks and drive removal in Traverse are unavailable for this session."
                }
                return
            }
            guard healthGeneration == token, target == selected, window != nil else {
                if window != nil && healthIsStopping { healthNotice = "Hardware check stopped." }
                return
            }
            healthDiagnostic = report.diagnostic
            if case .warning = report.outcome {
                health = report.outcome; healthMeasurements = report.nvmeMeasurements; healthIsStale = false
                if let sample = DriveHealthTrendPoint(report: report, requestedIntervalSeconds: requestedInterval,
                    previous: healthHistory.last, interrupted: healthHistoryInterrupted) {
                    healthHistory.append(sample); healthHistoryInterrupted = false
                } else { healthHistoryInterrupted = true }
                if healthHistory.count > 300 { healthHistory.removeFirst(healthHistory.count - 300) }
            } else {
                healthHistoryInterrupted = true
                healthIsStale = health != nil
                if health == nil { health = report.outcome }
                automaticHealthBlocked = true
                let reason: String
                switch report.outcome {
                case .unavailable(.denied): reason = "macOS did not allow access."
                case .unavailable(.busy): reason = "The drive is busy."
                case .unavailable(.disconnected): reason = "The drive disconnected."
                case .unavailable(.unsupported): reason = "SMART is not available on this connection."
                case .unavailable(.stale): reason = "The selected drive changed."
                case .unavailable(.unavailable):
                    switch report.diagnostic?.stage {
                    case .helperAdmission, .installation: reason = "The health reader could not be verified."
                    case .launch: reason = "The health reader could not start."
                    case .selection, .revalidation: reason = "The selected drive’s hardware connection could not be verified."
                    default: reason = "The drive did not supply a verified reading."
                    }
                case .unavailable(.uncertain): reason = "The hardware check needs review."
                case .warning: reason = "The reading could not be verified."
                }
                healthNotice = reason + " Live readings are paused. Use Read SMART now to retry."
            }
        }
    }
    func stopHealthCheck(interrupt: Bool = false) {
        if !healthHistory.isEmpty { healthHistoryInterrupted = true }
        healthGeneration = UUID()
        guard healthWork != nil else { return }
        healthIsStopping = true
        healthStopRequested = healthStopRequested || interrupt
        healthNotice = interrupt ? "Stopping the hardware check…" : "Waiting for the hardware check to finish. No new check will start."
        // Keep the native task, I/O lease and exact selection through its real
        // return. Cancelling a displayed request cannot free a live plugin call.
        if healthInvalidation == nil {
            healthInvalidation = Task { [self] in
                repeat {
                    let stopping = healthStopRequested; healthStopRequested = false
                    if stopping { await healthSession.stop() }
                    else { await healthSession.invalidate() }
                } while healthStopRequested
                healthInvalidation = nil
            }
        }
    }
    func drainHealth() async {
        await healthInvalidation?.value
        await healthWork?.value
        let drained = await healthSession.drain()
        if drained.transportSettled { undrainedHealthActivity = nil }
        if !drained.nativeCleanupConfirmed || !drained.transportSettled { hasUncertainHealthState = true }
    }
    func prepareForVolumeQuiescence() { pauseHealthMonitoring(); stopHealthCheck() }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        generation = UUID(); pending = nil; inspection = nil; observationIsStale = false; target = nil; work?.cancel(); controller = nil; embeddedWindow = nil
        stopHealthCheck(); health = nil; healthMeasurements = nil; healthDiagnostic = nil
        pauseHealthMonitoring(); monitorPreferences = nil; healthSettings = nil; sleepObservations = []
    }
    func drain() async { while let work { await work.value } }
    func closeAndDrain() async { window?.close(); await drain(); await drainHealth() }

    /// Visible selected-drive sampling uses the same single native child owner.
    /// There is no queued catch-up and no second sampler on the Benchmark page.
    func configureHealthMonitoring(settings: BrowserSettings) {
        guard healthSettings !== settings || monitor == nil else { return }
        healthSettings = settings
        monitorPreferences = settings.$driveHealthLiveUpdates.combineLatest(settings.$driveHealthIntervalSeconds)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.restartHealthMonitoring() }
        if sleepObservations.isEmpty {
            sleepObservations = [
                BrowserNotificationObservation(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification) { [weak self] _ in
                    MainActor.assumeIsolated { self?.healthSleeping = true; self?.stopHealthCheck() }
                },
                BrowserNotificationObservation(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification) { [weak self] _ in
                    MainActor.assumeIsolated { self?.healthSleeping = false }
                }
            ]
        }
        restartHealthMonitoring()
    }
    func pauseHealthMonitoring() {
        monitor?.cancel(); monitor = nil
        if !healthHistory.isEmpty { healthHistoryInterrupted = true }
    }
    func resumeHealthMonitoring() {
        guard monitor == nil, window != nil else { return }
        restartHealthMonitoring()
    }
    private func restartHealthMonitoring() {
        pauseHealthMonitoring()
        guard DriveHealthFeature.liveUpdatesAvailable(for: target),
              healthSettings?.driveHealthLiveUpdatesSelected == true, healthReaderAvailable else { return }
        automaticHealthBlocked = false
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let settings = healthSettings, window != nil else { return }
                let tick = ContinuousClock.now
                if !healthSleeping, !automaticHealthBlocked,
                   window?.isVisible == true, window?.isMiniaturized == false,
                   window?.occlusionState.contains(.visible) == true, canCheckHealth {
                    startHealthCheck(automatic: true)
                    // Await actual return; a slow native call cannot overlap
                    // the next tick or make the displayed cadence a promise.
                    await healthWork?.value
                }
                let seconds = [1, 2, 5, 10, 30, 60].contains(settings.driveHealthIntervalSeconds) ? settings.driveHealthIntervalSeconds : 1
                let next = tick.advanced(by: .seconds(seconds))
                do {
                    // Short reads keep the requested cadence. A missed tick
                    // starts a new interval, without queued catch-up requests.
                    if ContinuousClock.now < next {
                        try await ContinuousClock().sleep(until: next, tolerance: .milliseconds(40))
                    } else { try await Task.sleep(for: .seconds(seconds)) }
                } catch { return }
            }
        }
    }
}

struct DriveDetailsView: View {
    @ObservedObject var model: ApplicationDriveDetails
    @ObservedObject var settings: BrowserSettings
    var embedded = false
    @Environment(\.colorScheme) private var inheritedColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                if !embedded {
                    Image(systemName: model.target?.isInternal == true ? "internaldrive" : "externaldrive")
                        .interfaceFont(.system(size: 34)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(embedded ? "Volume details" : model.target?.name ?? "Drive Details")
                        .interfaceFont(embedded ? .headline : .title2.bold()).textSelection(.enabled)
                    if !embedded { Text("Connection, format and availability").interfaceFont(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(embedded ? "Refresh Details" : "Refresh", action: model.refresh).disabled(model.isReading)
            }
            HStack {
                if model.isReading {
                    ProgressView().controlSize(.small)
                    Text(model.inspection == nil ? "Reading drive details…" : "Refreshing drive details…")
                } else { Text(model.notice.isEmpty ? " " : model.notice) }
            }.interfaceFont(.callout).foregroundStyle(.secondary).frame(minHeight: 22, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let value = model.inspection {
                        GroupBox("Storage status") {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                                row("Volume", value.volume.url == nil ? "Not mounted" : "Mounted")
                                row("Write support", value.fields.writable.map {
                                    $0 ? "Supports writing" : value.volume.url == nil ? "Read-only media" : "Read-only volume"
                                } ?? "Not reported")
                                    .help("Reported for this volume or media. A read-only macOS system volume does not mean the whole drive is read-only. Folder access and file permissions can impose further limits.")
                                if !embedded {
                                    row("Hardware health", healthTitle)
                                        .help("Hardware warnings are separate from mount status and capacity. Check time is shown below; a warning-free reading does not predict reliability.")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        HStack(spacing: 6) {
                            if model.observationIsStale {
                                Image(systemName: "clock.badge.exclamationmark")
                                Text("Previous check")
                            }
                            Text(value.capturedAt.formatted(date: .abbreviated, time: .standard))
                        }.interfaceFont(.caption).foregroundStyle(.secondary)
                            .help(model.observationIsStale ? "These facts are from the previous successful check. Refresh to try again." : "Time of the latest successful check.")
                        if DriveHealthFeature.available {
                            GroupBox(embedded ? "SMART details" : "Hardware health") {
                                VStack(alignment: .leading, spacing: 10) {
                                    if !embedded {
                                        HStack(spacing: 8) {
                                            if model.isCheckingHealth { ProgressView().controlSize(.small) }
                                            Text(model.isCheckingHealth && !model.isAutomaticHealthCheck ? (model.healthIsStopping ? "Finishing hardware check…" : "Checking hardware…") : model.healthIsStale ? "Previous reading" : healthTitle)
                                                .interfaceFont(.headline).foregroundStyle(model.healthIsStale ? Color.orange : Color.primary)
                                            Spacer()
                                            if model.isCheckingHealth && !model.isAutomaticHealthCheck {
                                                Button("Stop") { model.stopHealthCheck(interrupt: true) }.disabled(model.healthIsStopping)
                                            } else {
                                                Button("Check Hardware Health", action: model.checkHardwareHealth).disabled(!model.canCheckHealth)
                                            }
                                        }
                                    }
                                    if case .warning(let kind, let raw, let date) = model.health {
                                        Text("\(model.healthIsStale || model.isCheckingHealth ? "Previous reading · " : "")\(kind == .ata ? "ATA threshold status" : "NVMe critical warnings") · \(date.formatted(date: .abbreviated, time: .standard))")
                                            .interfaceFont(.caption).foregroundStyle(.secondary)
                                        if raw != 0 { Text("Reported warning: \(String(format: "0x%02X", raw))").interfaceFont(.caption).foregroundStyle(.orange) }
                                        if let readings = model.healthMeasurements {
                                            NVMeHealthReadings(value: readings, showsOverview: !embedded).transition(.opacity)
                                        }
                                    }
                                    if !model.healthNotice.isEmpty {
                                        Text(model.healthNotice).interfaceFont(.callout).foregroundStyle(.secondary)
                                    }
                                    if !embedded, let reason = model.healthReaderUnavailableReason {
                                        Text(reason).interfaceFont(.callout).foregroundStyle(.secondary)
                                    }
                                    DriveHealthTrend(model: model)
                                    Text("A read-only snapshot reported by the drive. Support depends on the drive and its connection; a warning-free reading does not predict reliability.")
                                        .interfaceFont(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                        GroupBox("Volume") {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                                row("Mount point", value.volume.url?.path ?? "Not mounted")
                                row("Filesystem", value.fields.fileSystem)
                                row("Device identifier", value.deviceName)
                                row("Reported media size", bytes(value.fields.mediaBytes))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        GroupBox("Device") {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                                row("Model", value.fields.model); row("Vendor", value.fields.vendor)
                                row("Connection", value.fields.transport)
                                row("Outer device size", bytes(value.fields.outerDeviceBytes))
                                row("Block size", value.fields.blockBytes.map { "\($0) bytes" })
                                row("Removable media", yesNo(value.fields.removable))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    } else if !model.isReading {
                        ContentUnavailableView("Details unavailable", systemImage: "externaldrive.badge.questionmark",
                            description: Text("The device may have changed or macOS may not supply these facts. Refresh its location and reopen Details."))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Volumes can share space. See Properties for used and available capacity.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help("APFS volumes can share a container. Media and device sizes describe different levels of that storage. No partition or format action occurs here.")
            HStack {
                Button("Open Disk Utility…", action: model.openDiskUtility)
                    .help("Opens Apple's Disk Utility without selecting a device or requesting an action.")
                Spacer(); Text("No file contents read").interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(minWidth: embedded ? 0 : 480, minHeight: embedded ? 0 : 400)
            .animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeOut(duration: 0.16 * settings.motion.mode.durationScale), value: model.observationIsStale)
            .animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeOut(duration: 0.16 * settings.motion.mode.durationScale), value: model.health)
            .animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeOut(duration: 0.16 * settings.motion.mode.durationScale), value: model.isCheckingHealth)
            .environment(\.colorScheme, settings.appearance == .system ? inheritedColorScheme : settings.appearance == .dark ? .dark : .light)
    }
    private func bytes(_ value: UInt64?) -> String? {
        value.map { $0 <= UInt64(Int64.max) ? FileSizeText.string(Int64($0)) : "\($0) bytes" }
    }
    private var healthTitle: String {
        model.health == nil ? "Not measured" : model.healthTitle
    }
    private func yesNo(_ value: Bool?) -> String? { value.map { $0 ? "Yes" : "No" } }
    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).frame(width: 148, alignment: .leading)
            Text(value ?? "Unavailable").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.interfaceFont(.callout)
    }
}
