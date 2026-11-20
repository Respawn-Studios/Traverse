import AppKit
import Combine
import Foundation
import LocalStorage
import SwiftUI
import UniformTypeIdentifiers

/// The queue owns every store/engine reference, including lifetime leases.
/// Only immutable projections cross back to the main actor.
private final class CrashReportWorker: @unchecked Sendable {
    struct State: Sendable {
        let reports: [CrashReport]
        let message: String
        let recovered: Bool
        var canDiscardPending = false
        var failureCheckpoint: DiagnosticCheckpoint?
        var error: DiagnosticErrorCode?
    }
    private let queue = DispatchQueue(label: "com.respawnstudios.traverse.crash-reports", qos: .utility)
    private var store: CrashReportStore?
    private var capture: NativeCrashCapture?
    private var message = "Local crash capture is unavailable."

    func start(directory: URL, identifier: String, enabled: Bool) async -> State {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var recovered = false
                var checkpoint: DiagnosticCheckpoint = .crashStorage
                var failure: DiagnosticErrorCode?
                do {
                    let store = try CrashReportStore(directory: directory)
                    self.store = store
                    let capture = try NativeCrashCapture(store: store, applicationIdentifier: identifier)
                    self.capture = capture
                    checkpoint = .crashRecovery
                    recovered = try capture.recoverPending()
                    if enabled && !NativeCrashCapture.debuggerAttached {
                        checkpoint = .crashCapture
                        try capture.enable()
                        message = "Crash capture is on for this session. Reports stay on this Mac until you share them."
                    } else {
                        message = enabled ? "Crash capture is paused while a debugger is attached."
                            : "Crash capture is off. Previously retained reports stay available."
                    }
                } catch {
                    failure = DiagnosticErrors.project(error)
                    switch checkpoint {
                    case .crashStorage:
                        message = "Private crash storage is unavailable. Existing data is kept; capture is paused."
                    case .crashRecovery:
                        message = capture?.hasUnrecoveredPendingDiscardCandidate == true
                            ? "An unreadable crash capture is kept. You can discard that capture after confirmation; earlier reports stay available."
                            : "The pending capture could not be retained or confirmed. Remove an older report if storage is full, then restart Traverse. Existing data is kept."
                    case .crashCapture where error as? CrashReportFailure == .capacity:
                        message = "Crash capture is paused because storage has no room for another report. Remove an older report, then restart Traverse."
                    default:
                        message = "Crash capture could not start on this Mac. Retained reports stay available; App Logs has the technical checkpoint."
                    }
                }
                continuation.resume(returning: State(reports: store?.reports ?? [], message: message, recovered: recovered,
                    canDiscardPending: capture?.hasUnrecoveredPendingDiscardCandidate == true,
                    failureCheckpoint: failure == nil ? nil : checkpoint, error: failure))
            }
        }
    }

    func remove(_ id: UUID) async -> State {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let store else { throw CrashReportFailure.unavailable }
                    try store.remove(id)
                    continuation.resume(returning: State(reports: store.reports,
                        message: "Removed this app's local copy. If capture was paused, restart Traverse to resume it. macOS reports are managed separately.", recovered: false,
                        canDiscardPending: capture?.hasUnrecoveredPendingDiscardCandidate == true))
                } catch {
                    continuation.resume(returning: State(reports: store?.reports ?? [],
                        message: "Removal could not be confirmed. Existing crash data may remain.", recovered: false))
                }
            }
        }
    }

    func discardUnreadablePending() async -> State {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let capture else { throw CrashReportFailure.unavailable }
                    try capture.discardUnrecoveredPending()
                    continuation.resume(returning: State(reports: store?.reports ?? [],
                        message: "Discarded that unreadable capture. Restart Traverse to resume local capture; retained reports remain available.", recovered: false))
                } catch {
                    continuation.resume(returning: State(reports: store?.reports ?? [],
                        message: "Discard could not be confirmed. No other report was changed; restart to review the current capture state.", recovered: false,
                        failureCheckpoint: .crashDiscard, error: DiagnosticErrors.project(error)))
                }
            }
        }
    }

    func redact(_ text: String, prefixes: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: try? CrashReportRedaction.hidePrivateDetails(in: text, privatePrefixes: prefixes))
            }
        }
    }

    func githubDraft(_ text: String, title: String) async -> GitHubIssueDraft? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: try? GitHubIssueDraft(report: text, title: title))
            }
        }
    }

    func deviceDetails(_ snapshot: @escaping @Sendable () -> String) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: snapshot()) }
        }
    }

    func export(_ text: String, to url: URL, protectedDirectories: [URL]) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard text.utf8.count <= CrashReportRedaction.maximumBytes, url.isFileURL,
                          !protectedDirectories.contains(where: { url == $0 || url.path.hasPrefix($0.path + "/") }) else {
                        throw CrashReportFailure.invalid
                    }
                    let bytes = Data(text.utf8)
                    let file = BrowserSnapshotFile(directory: url.deletingLastPathComponent(), name: url.lastPathComponent,
                        maximumBytes: CrashReportRedaction.maximumBytes)
                    try file.write(bytes, replacing: .absent) { actual in
                        guard actual == bytes else { throw CrashReportFailure.changed }
                    }
                    continuation.resume(returning: true)
                } catch { continuation.resume(returning: false) }
            }
        }
    }
}

@MainActor final class ApplicationCrashReports: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ApplicationCrashReports()
    @Published private(set) var reports: [CrashReport] = []
    @Published var selected: UUID?
    @Published var document = "" {
        didSet {
            guard !document.utf8.elementsEqual(oldValue.utf8) else { return }
            reviewRevision &+= 1
            hasCurrentDeviceInfo = document.contains(CurrentDeviceDetails.heading)
        }
    }
    @Published private(set) var notice = "Starting local crash reporting…"
    @Published private(set) var working = false
    @Published private(set) var preparingReport = false
    @Published private(set) var canDiscardPending = false
    @Published var includeOtherThreads = false
    @Published private(set) var hasCurrentDeviceInfo = false
    private let worker = CrashReportWorker()
    private var controller: NSWindowController?
    private var started = false
    private struct ReviewDraft {
        let text: String
        let devicePrepared: Bool
    }
    private var drafts: [UUID: ReviewDraft] = [:]
    private var devicePrepared = false
    private var settings: BrowserSettings?
    private var exportPanel: NSSavePanel?
    private var presentation: IdleBrowserPresentation?
    private var recoveredReportWaiting = false
    private var startupCheckFinished = false
    private var recoveredAtLaunch = false
    private let clipboard: (String) -> Bool
    private let openURL: (URL) -> Bool
    private let deviceDetails: @Sendable () -> String
    private var reviewRevision: UInt64 = 0
    private var reportPreparation = UUID()
    var window: NSWindow? { controller?.window }
    var allowsOptionalStartupMessage: Bool { startupCheckFinished && !recoveredAtLaunch }
    private var current: CrashReport? { reports.first { $0.id == selected } }

    init(clipboard: @escaping (String) -> Bool = {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString($0, forType: .string)
    }, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         deviceDetails: @escaping @Sendable () -> String = { CurrentDeviceDetails.text() }) {
        self.clipboard = clipboard; self.openURL = openURL; self.deviceDetails = deviceDetails
        super.init()
    }

    func start(settings: BrowserSettings, browser: BrowserViewController? = nil) {
        if let browser, presentation == nil {
            presentation = IdleBrowserPresentation(browser: browser) { [weak self] browser in
                guard let self, recoveredReportWaiting else { return }
                recoveredReportWaiting = false
                show(settings: browser.settings)
            }
        }
        guard !started else { return }
        guard let root = AppStorageLocations.stateDirectory, let identifier = Bundle.main.bundleIdentifier else {
            started = true
            notice = "Local crash storage is unavailable. You can still prepare a bug report."
            return
        }
        load(directory: root.appendingPathComponent("crash-reports", isDirectory: true), identifier: identifier,
            enabled: settings.crashCaptureEnabled)
    }

    private func load(directory: URL, identifier: String, enabled: Bool) {
        guard !started else { return }
        started = true
        Task { [weak self] in
            guard let self else { return }
            let state = await worker.start(directory: directory, identifier: identifier, enabled: enabled)
            reports = state.reports; notice = state.message; canDiscardPending = state.canDiscardPending
            startupCheckFinished = true
            recoveredAtLaunch = state.recovered || state.failureCheckpoint != nil
            if let checkpoint = state.failureCheckpoint {
                ApplicationDiagnostics.shared.event(.diagnostics, .paused, level: .warning,
                    error: state.error, context: .init(checkpoint))
            }
            if selected == nil && document.isEmpty { select(reports.first?.id) }
            // This opens no window and makes no request. The Help item and its
            // count remain available without interrupting setup or file work.
            if state.recovered {
                notice = "A crash report was recovered. Review it here before choosing whether to share. " + notice
                recoveredReportWaiting = true
                presentation?.consider()
            }
            ApplicationCommunitySupport.shared.reconsider()
        }
    }

    #if DEBUG
    /// Called only by the already-admitted generated support flow. It exercises
    /// real storage, with capture disabled; no production path override exists.
    func startForVerification(directory: URL, identifier: String) {
        load(directory: directory, identifier: identifier, enabled: false)
    }
    #endif

    func show(settings: BrowserSettings, newBug: Bool = false, offscreen: Bool = false) {
        self.settings = settings
        start(settings: settings)
        if let window = controller?.window, window.attachedSheet != nil {
            if !offscreen { window.makeKeyAndOrderFront(nil) }
            return
        }
        if newBug || (selected == nil && document.isEmpty) { prepareBugReport(settings: settings) }
        else if !document.isEmpty, !devicePrepared, !preparingReport { prepareDocument(document) }
        if let window = controller?.window {
            ToolWindowChrome.install(in: window, settings: settings)
            if !offscreen { window.makeKeyAndOrderFront(nil) }; return
        }
        let owner = NSApp.keyWindow
        let host = InterfaceHostingController(rootView: CrashReportsView(owner: self))
        host.sizingOptions = []
        let window = ToolMotionWindow(contentViewController: host)
        window.title = "Crash Reports & Feedback"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(.init(width: 820, height: 650))
        window.contentMinSize = .init(width: 640, height: 500)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed; window.delegate = self
        controller = NSWindowController(window: window)
        ToolWindowChrome.install(in: window, settings: settings)
        if offscreen { window.setFrameOrigin(.init(x: -12000, y: -12000)) }
        else {
            ToolWindowChrome.position(window, relativeTo: owner)
            window.makeKeyAndOrderFront(nil)
            ToolContentMotion.reveal(host.view, effect: .windows)
        }
    }

    func select(_ id: UUID?) {
        if let selected { drafts[selected] = .init(text: document, devicePrepared: devicePrepared) }
        selected = id; includeOtherThreads = false
        reportPreparation = UUID(); preparingReport = false
        if let report = current {
            if let draft = drafts[report.id], draft.devicePrepared {
                document = draft.text; devicePrepared = true
            } else if let draft = drafts[report.id] { prepareDocument(draft.text) }
            else { prepareDocument((try? report.text()) ?? "") }
        }
    }

    func prepareBugReport(settings: BrowserSettings) {
        if let selected { drafts[selected] = .init(text: document, devicePrepared: devicePrepared) }
        selected = nil; includeOtherThreads = false
        prepareDocument("## What happened\n\n## Steps to reproduce\n\n## Expected behavior\n\n## App details\n\n"
            + SupportDetailsSnapshot.current(settings: settings).text)
    }

    /// Device facts belong in the first editable draft, before any sharing
    /// action. Never append hidden fields when copying, exporting or opening a
    /// GitHub draft: those actions still use exactly the text the user reviewed.
    private func prepareDocument(_ body: String) {
        let ticket = UUID(); reportPreparation = ticket
        document = body; devicePrepared = false; preparingReport = true
        Task {
            let details = await worker.deviceDetails(deviceDetails)
            guard reportPreparation == ticket else { return }
            preparingReport = false
            guard document.utf8.count + details.utf8.count + 2 <= CrashReportRedaction.maximumBytes else {
                notice = "Device details could not fit in this report. Review the text before sharing."; return
            }
            document += "\n\n" + details
            devicePrepared = true
        }
    }

    func addOtherThreads() {
        guard let report = current, !includeOtherThreads, !preparingReport else { return }
        guard let trace = try? report.text(includeOtherThreads: true) else { return }
        document += "\n\n## Extended crash trace\n\n" + trace
        includeOtherThreads = true
    }

    func redact() {
        guard !working, !preparingReport else { return }
        let original = document, selection = selected
        let prefixes = [FileManager.default.homeDirectoryForCurrentUser.path]
        working = true
        Task {
            let result = await worker.redact(original, prefixes: prefixes)
            working = false
            guard document == original, selected == selection else {
                notice = "The report changed while the privacy helper ran. Review it and run the helper again if needed."
                return
            }
            if let result {
                document = result
                notice = "Common paths, URLs, email and IPv4 addresses hidden. Check the full text yourself; this cannot detect every private detail."
            } else { notice = "This report exceeds the privacy helper's size limit. Shorten it and try again." }
        }
    }

    func copyReport() {
        guard !working, !preparingReport, !document.isEmpty, document.utf8.count <= CrashReportRedaction.maximumBytes else {
            notice = "Keep the reviewed report below 512 KiB before sharing."; return
        }
        guard clipboard(document) else {
            notice = "Could not copy the report. Select and copy the text yourself."; return
        }
        notice = "Copied the displayed text. Share it only where you intend."
    }

    func openGitHubDraft() {
        guard !working, !preparingReport, !document.isEmpty, document.utf8.count <= CrashReportRedaction.maximumBytes else {
            notice = "Keep the reviewed report below 512 KiB before opening a draft."; return
        }
        let reviewed = document, selection = selected, revision = reviewRevision
        let sourceWindow = controller?.window
        let title = current.flatMap { try? $0.githubIssueTitle() } ?? "Bug report: Traverse"
        working = true
        Task {
            let draft = await worker.githubDraft(reviewed, title: title)
            working = false
            guard revision == reviewRevision, selected == selection, controller?.window === sourceWindow else {
                notice = "The report changed or closed while preparing the draft. Review it and open a new draft when ready."
                return
            }
            guard let draft else { notice = "The draft could not be prepared. Copy or save the reviewed report instead."; return }
            let description = draft.includesFullReport ? "The full displayed text is in the GitHub draft."
                : "The GitHub draft is explicitly abbreviated because the report exceeds the browser URL limit. Copy Report or Save Report keeps the full displayed text."
            notice = openURL(draft.url) ? description + " Submit it on GitHub when ready; nothing was submitted by Traverse."
                : "The browser could not open the draft. Copy or save the reviewed report instead."
        }
    }

    func saveReport() {
        guard !working, !preparingReport, document.utf8.count <= CrashReportRedaction.maximumBytes,
              let window = controller?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]; panel.canCreateDirectories = false
        panel.nameFieldStringValue = "Traverse-Report-" + String(UUID().uuidString.prefix(8)) + ".txt"
        panel.message = "Save exactly the reviewed text. Choose a new filename; existing files are kept. No native crash bytes are included."
        exportPanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            exportPanel = nil
            guard response == .OK, let url = panel.url else { return }
            let reviewed = document
            working = true
            Task {
                let saved = await worker.export(reviewed, to: url, protectedDirectories: AppStorageLocations.protectedDirectories)
                working = false
                notice = saved ? "Saved the reviewed text. No report was sent."
                    : "The export could not be confirmed. The chosen file may exist; existing files were not replaced."
            }
        }
    }

    func removeSelected() {
        guard !working, let selected, let window = controller?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this local crash report?"
        alert.informativeText = "This removes Traverse's retained native capture and shareable copy. It does not delete any macOS report or GitHub issue."
        alert.addButton(withTitle: "Remove Local Copy"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            working = true
            Task {
                let state = await worker.remove(selected)
                working = false; reports = state.reports; notice = state.message; canDiscardPending = state.canDiscardPending
                if !reports.contains(where: { $0.id == selected }) {
                    drafts.removeValue(forKey: selected); self.selected = nil; document = ""
                    select(reports.first?.id)
                    if reports.isEmpty, let settings { prepareBugReport(settings: settings) }
                }
            }
        }
    }

    func discardUnreadableCapture() {
        guard !working, canDiscardPending, let window = controller?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the unreadable crash capture?"
        alert.informativeText = "This removes one incomplete or unreadable local capture. Retained crash reports stay available. Restart Traverse afterward to resume capture."
        alert.addButton(withTitle: "Keep Capture"); alert.addButton(withTitle: "Discard Capture")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            working = true
            Task {
                let state = await worker.discardUnreadablePending()
                working = false; notice = state.message; canDiscardPending = state.canDiscardPending
                if let checkpoint = state.failureCheckpoint {
                    ApplicationDiagnostics.shared.event(.diagnostics, .failed, level: .warning,
                        error: state.error, context: .init(checkpoint))
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        reviewRevision &+= 1
        reportPreparation = UUID(); preparingReport = false
        exportPanel?.cancel(nil); exportPanel = nil
        if let selected { drafts[selected] = .init(text: document, devicePrepared: devicePrepared) }
        controller = nil; settings = nil
    }
}

@MainActor extension BrowserViewController {
    @objc func showCrashReports(_ sender: Any?) { ApplicationCrashReports.shared.show(settings: settings) }
    @objc func openTraverseSource(_ sender: Any?) {
        if let url = CommunitySupportLinks.source { NSWorkspace.shared.open(url) }
    }
    @objc func openTraverseDiscord(_ sender: Any?) {
        if let url = CommunitySupportLinks.discord { NSWorkspace.shared.open(url) }
    }
}
