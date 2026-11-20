#if DEBUG
    import AppKit
    import Darwin
    import ExplorerCore
    import LocalStorage
    @preconcurrency import CrashReporter

    @MainActor enum SupportDetailsVerification {
        static func run(root: URL, browser: BrowserViewController, capture: Bool = false,
                        evidenceDirectory: URL? = nil) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            try check(
                [".build/overnight-foundation", ".build/traverse-development"].contains(where: {
                    root.deletingLastPathComponent() == repo.appendingPathComponent($0)
                })
                    && root.resolvingSymlinksInPath() == root
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Support QA requires an exact generated foundation case")
            let admitted = try await Task.detached {
                guard
                    let bytes = try BrowserSnapshotFile(directory: root, name: "reservation.json", maximumBytes: 4096)
                        .read(),
                    let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                else { return false }
                return fields["action"] as? String == "support-details"
            }.value
            try check(admitted, "Support QA reservation differs")
            guard let identifier = Bundle.main.bundleIdentifier else {
                throw UIVerification.Failure(message: "Support QA application identity unavailable")
            }
            try await Task.detached {
                try verifyCrashStorage(root: root.appendingPathComponent("source/crash-reports", isDirectory: true),
                    identifier: identifier)
            }.value
            let evidence = evidenceDirectory ?? root.appendingPathComponent("evidence")
            try check(evidence.resolvingSymlinksInPath() == evidence
                && (evidence == root.appendingPathComponent("evidence")
                    || (evidence.deletingLastPathComponent() == root.appendingPathComponent("evidence")
                        && ["support-followup-1", "support-followup-2"].contains(evidence.lastPathComponent))),
                "Support evidence must use its bounded generated run")
            var checks = 0
            for value in [
                nil, "", "/Users/Generated/Private.txt", "1.0\npassword", "1.2.3.4", "1.-2", "1..2", "1/2", "𝟙.0",
                String(repeating: "1", count: 33),
            ] as [String?] {
                try check(
                    SupportDetailsSnapshot.numericVersion(value) == "Unavailable",
                    "Invalid build text entered support report")
                checks += 1
            }
            for value in ["1", "0.1", "123.4.567"] {
                try check(SupportDetailsSnapshot.numericVersion(value) == value, "Valid numeric version refused")
                checks += 1
            }
            try check(
                SupportDetailsSnapshot.channel("smb://generated-private-server") == .unknown
                    && SupportDetailsSnapshot.channel("qualification") == .qualification
                && SupportDetailsSnapshot.channel("app-store").rawValue == "App Store / TestFlight"
                && SupportDetailsSnapshot.channel("developer-id").rawValue == "Direct download (Developer ID)"
                && SupportDetailsSnapshot.channel("candidate") == .candidate
                && SupportDetailsSnapshot.channel("development-preview") == .preview,
                "Unknown channel did not stay bounded")
            checks += 1
            var copied: [String] = []
            var permitsCopy = true
            let support = ApplicationSupportDetails { text in
                copied.append(text)
                return permitsCopy
            }
            let settings = browser.settings
            settings.interfaceSize = .init(100)
            settings.keyboardProfile = .explorer
            InterfacePresentation.shared.bind(settings)
            settings.navigationStyle = .glass
            settings.appearance = .dark
            settings.glassFileContent = true
            settings.motion.mode = .reduced
            // Generated sensitive-looking preference values must not become
            // report fields. No personal record or filesystem is inspected.
            settings.rememberAnalysisPolicy(
                .applicationData,
                for: URL(fileURLWithPath: "/Users/Generated/Private-Marker"), remember: true)
            support.show(settings: settings, offscreen: !capture)
            guard let window = support.window else { throw UIVerification.Failure(message: "Support window absent") }
            let first = support.documentForVerification
            if capture {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                try await GlassVerification.captureOwnedWindow(window,
                    to: evidence.appendingPathComponent("support-native.png"))
            }
            try check(
                copied.isEmpty && first.utf8.count < 4096 && first.contains("Reduced Animations")
                    && first.contains("Translucent file content: On") && !first.contains("Private-Marker")
                    && first.contains("Interface size: 100%") && first.contains("Keyboard preset: Explorer")
                    && first.contains("Explorer Control shortcuts: On")
                    && !first.contains(root.path) && !first.contains("/Users/") && !first.contains("smb://"),
                "Support report includes an unreviewed value or copied on open")
            checks += 1
            support.copyForVerification()
            try check(
                copied == [first] && support.statusForVerification?.hasPrefix("Copied.") == true,
                "Explicit Copy did not match the reviewed report")
            checks += 1
            settings.motion.mode = .off
            settings.interfaceSize = .init(150)
            settings.keyboardProfile = .mac
            try check(support.documentForVerification == first, "An unreviewed report silently replaced the preview")
            try check(support.reportFontSizeForVerification == 18,
                "Support report text ignored the live interface size preference")
            support.refresh(nil)
            let refreshed = support.documentForVerification
            try check(
                refreshed.contains("Animation mode: Off") && refreshed != first && copied == [first]
                    && refreshed.contains("Interface size: 150%") && refreshed.contains("Keyboard preset: Mac")
                    && refreshed.contains("Explorer Control shortcuts: Off"),
                "Explicit Refresh failed or wrote the clipboard")
            if capture {
                settings.appearance = .light
                // The system appearance change has its own compositor
                // transition. Inspect the settled layout, not that blend.
                try await Task.sleep(for: .seconds(1))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await GlassVerification.captureOwnedWindow(window,
                    to: evidence.appendingPathComponent("support-native-large.png"))
            }
            permitsCopy = false
            support.copyForVerification()
            try check(
                copied == [first, refreshed] && support.statusForVerification?.hasPrefix("Could not copy.") == true,
                "Clipboard refusal was reported as success")
            checks += 2
            settings.navigationStyle = .solid
            try await Task.sleep(for: .milliseconds(30))
            try check(
                (window.contentViewController as? ToolWindowChrome)?.surface.isGlassEnabled == false
                    && (window.contentViewController as? ToolWindowChrome)?.motion.mode == .off,
                "Open Support Details ignored shared style/motion")
            checks += 1
            support.show(settings: settings, offscreen: true)
            try check(
                support.window === window && copied.count == 2, "Reopen duplicated a support window or copied data")
            checks += 1
            if let content = window.contentView {
                content.layoutSubtreeIfNeeded()
                let pdf = content.dataWithPDF(inside: content.bounds)
                try check(pdf.count <= 2 << 20, "Support view render exceeded bound")
                try await Task.detached {
                    try pdf.write(
                        to: evidence.appendingPathComponent("support-content.pdf"), options: .withoutOverwriting)
                }.value
            }
            guard
                let close = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)
            else {
                throw UIVerification.Failure(message: "Generated support close event unavailable")
            }
            try check(
                window.performKeyEquivalent(with: close) && support.window == nil
                    && support.documentForVerification.isEmpty && copied.count == 2,
                "Closing Support Details did not discard its snapshot")
            checks += 1
            try await verifyCrashReview(root: root.appendingPathComponent("source/crash-reports/ui-kept", isDirectory: true),
                identifier: identifier, settings: settings, evidence: evidence, capture: capture)
            return [
                "passed": true, "controls": checks, "explicitCopyAndRefusal": true,
                "onlyAllowlistedValues": true, "automaticCopies": 0, "actualClipboardWrites": 0,
                "clipboardBackend": "injected recording sink; system clipboard not exercised",
                "viewContentRender": true, "compositorCapture": capture, "physicalInput": false,
                "personalFiles": 0, "networkRequests": 0, "keychainQueries": 0,
                "crashNativeProjectionAndColdStorage": true, "crashPendingDiscard": true, "crashCapacityAdmission": true,
                "crashReviewAndCancelConfirm": true, "crashPrivateClipboardAndURLSink": true,
                "realCrashHandler": "NOT EXERCISED; live self-report only, no fault or OS crash report",
            ]
        }

        private enum CrashCheckFailure: Error { case liveReport, recovery, privacy, coldRead, refusal, discard, changedLeaf, capacity }

        /// One normal storage journey in the existing support flow. All native
        /// data describes this generated app process; no handler is registered,
        /// no crash is induced and no operating-system report is collected.
        nonisolated private static func verifyCrashStorage(root: URL, identifier: String) throws {
            func engineLeaf(_ store: CrashReportStore) throws -> URL {
                let base = try store.prepareEngineDirectory(applicationIdentifier: identifier)
                return base.appendingPathComponent("com.plausiblelabs.crashreporter.data", isDirectory: true)
                    .appendingPathComponent(identifier, isDirectory: true).appendingPathComponent("live_report.plcrash")
            }
            func write(_ data: Data, at url: URL) throws {
                let file = BrowserSnapshotFile(directory: url.deletingLastPathComponent(), name: url.lastPathComponent,
                    maximumBytes: 2 << 20, requiresPrivateDurability: true)
                try file.write(data, replacing: .absent) { actual in
                    guard actual == data else { throw CrashCheckFailure.changedLeaf }
                }
            }
            func successfulCapture() throws -> (CrashReport, Data) {
                let store = try CrashReportStore(directory: root.appendingPathComponent("successful", isDirectory: true))
                let leaf = try engineLeaf(store)
                let base = leaf.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                guard let config = PLCrashReporterConfig(signalHandlerType: .mach, symbolicationStrategy: [],
                    shouldRegisterUncaughtExceptionHandler: false, basePath: base.path,
                    maxReportBytes: UInt(CrashReportStore.maximumNativeBytes)),
                      let reporter = PLCrashReporter(configuration: config) else { throw CrashCheckFailure.liveReport }
                let bytes = try reporter.generateLiveReportAndReturnError()
                guard !bytes.isEmpty,
                      bytes.count <= CrashReportStore.maximumNativeBytes else { throw CrashCheckFailure.liveReport }
                try write(bytes, at: leaf)
                let capture = try NativeCrashCapture(store: store, applicationIdentifier: identifier)
                guard try capture.recoverPending(), let report = store.reports.first,
                      !FileManager.default.fileExists(atPath: leaf.path),
                      !capture.hasUnrecoveredPendingDiscardCandidate else { throw CrashCheckFailure.recovery }
                let shared = try report.text(includeOtherThreads: true)
                guard !shared.contains(root.path), !shared.contains(NSHomeDirectory()),
                      !shared.contains(Bundle.main.executablePath ?? "\0"),
                      !shared.contains("Registers:"), !shared.contains("Exception reason:") else { throw CrashCheckFailure.privacy }
                return (report, bytes)
            }
            let (report, nativeData) = try successfulCapture()
            func coldReadAndRemove() throws {
                let store = try CrashReportStore(directory: root.appendingPathComponent("successful", isDirectory: true))
                guard store.reports == [report] else { throw CrashCheckFailure.coldRead }
                try store.remove(report.id)
                guard store.reports.isEmpty else { throw CrashCheckFailure.coldRead }
            }
            try coldReadAndRemove()
            do {
                let store = try CrashReportStore(directory: root.appendingPathComponent("successful", isDirectory: true))
                guard store.reports.isEmpty else { throw CrashCheckFailure.coldRead }
            }

            func requirePaused(_ store: CrashReportStore) throws {
                do { try store.requireCaptureSpace(); throw CrashCheckFailure.capacity }
                catch CrashReportFailure.capacity {}
            }
            func fixtureReport() throws -> CrashReport {
                try CrashReport(capturedAt: nil, version: "0.3.0", build: "99", systemVersion: nil,
                    systemBuild: nil, architecture: .arm64, signal: .abort, images: [], threads: [])
            }
            let countRoot = root.appendingPathComponent("count-capacity", isDirectory: true)
            do {
                let store = try CrashReportStore(directory: countRoot)
                for index in 0..<5 {
                    try store.requireCaptureSpace()
                    try store.retain(Data([UInt8(index)]), report: fixtureReport())
                }
                try requirePaused(store)
                let leaf = try engineLeaf(store)
                try write(nativeData, at: leaf)
                let capture = try NativeCrashCapture(store: store, applicationIdentifier: identifier)
                do { _ = try capture.recoverPending(); throw CrashCheckFailure.capacity }
                catch CrashReportFailure.capacity {}
                guard try Data(contentsOf: leaf) == nativeData, !capture.hasUnrecoveredPendingDiscardCandidate,
                      store.reports.count == 5, let oldest = store.reports.last else { throw CrashCheckFailure.capacity }
                try store.remove(oldest.id)
            }
            do {
                let store = try CrashReportStore(directory: countRoot)
                let capture = try NativeCrashCapture(store: store, applicationIdentifier: identifier)
                guard try capture.recoverPending(),
                      try store.readPending(applicationIdentifier: identifier) == nil,
                      store.reports.count == 5 else { throw CrashCheckFailure.capacity }
                try requirePaused(store)
                guard let oldest = store.reports.last else { throw CrashCheckFailure.capacity }
                try store.remove(oldest.id)
                try store.requireCaptureSpace()
            }
            do {
                let store = try CrashReportStore(directory: root.appendingPathComponent("byte-capacity", isDirectory: true))
                for value in 0..<3 {
                    try store.requireCaptureSpace()
                    try store.retain(Data(repeating: UInt8(value), count: 7 * CrashReportStore.maximumNativeBytes / 8),
                        report: fixtureReport())
                }
                try requirePaused(store)
                guard let oldest = store.reports.last else { throw CrashCheckFailure.capacity }
                try store.remove(oldest.id)
                try store.requireCaptureSpace()
            }

            for kind in ["empty", "oversized", "symlink", "changed"] {
                let store = try CrashReportStore(directory: root.appendingPathComponent(kind, isDirectory: true))
                let leaf = try engineLeaf(store)
                let target = root.appendingPathComponent(kind + "-canary.txt")
                let canary = Data("Generated canary stays unchanged.\n".utf8)
                try write(canary, at: target)
                if kind == "symlink" {
                    try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
                } else {
                    let bytes = kind == "oversized" ? Data(repeating: 65, count: CrashReportStore.maximumNativeBytes + 1) : Data()
                    // Snapshot documents intentionally reject empty data. A
                    // generated empty native leaf uses a new, exclusive file.
                    if bytes.isEmpty {
                        let descriptor = open(leaf.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard descriptor >= 0 else { throw CrashCheckFailure.liveReport }
                        close(descriptor)
                    } else { try write(bytes, at: leaf) }
                }
                let capture = try NativeCrashCapture(store: store, applicationIdentifier: identifier)
                do { _ = try capture.recoverPending(); throw CrashCheckFailure.refusal }
                catch is CrashCheckFailure { throw CrashCheckFailure.refusal }
                catch { /* expected: invalid generated pending data remains */ }
                guard capture.hasUnrecoveredPendingDiscardCandidate else { throw CrashCheckFailure.refusal }
                if kind == "changed" {
                    let old = leaf.deletingLastPathComponent().appendingPathComponent("preserved-empty.plcrash")
                    try FileManager.default.moveItem(at: leaf, to: old)
                    try write(Data("New generated arrival".utf8), at: leaf)
                    do { try capture.discardUnrecoveredPending(); throw CrashCheckFailure.changedLeaf }
                    catch is CrashCheckFailure { throw CrashCheckFailure.changedLeaf }
                    catch { /* an arriving replacement must be preserved */ }
                    guard try Data(contentsOf: leaf) == Data("New generated arrival".utf8) else { throw CrashCheckFailure.changedLeaf }
                } else {
                    try capture.discardUnrecoveredPending()
                    guard !FileManager.default.fileExists(atPath: leaf.path) else { throw CrashCheckFailure.discard }
                }
                guard try Data(contentsOf: target) == canary else { throw CrashCheckFailure.discard }
                guard !capture.hasUnrecoveredPendingDiscardCandidate else { throw CrashCheckFailure.discard }
            }
            let kept = try CrashReportStore(directory: root.appendingPathComponent("ui-kept", isDirectory: true))
            try kept.retain(nativeData, report: report)
            let pending = try engineLeaf(kept)
            let descriptor = open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CrashCheckFailure.liveReport }
            close(descriptor)
        }

        private static func verifyCrashReview(root: URL, identifier: String, settings: BrowserSettings,
            evidence: URL, capture: Bool) async throws {
            var copied: [String] = [], opened: [URL] = []
            let owner = ApplicationCrashReports(clipboard: { copied.append($0); return true },
                openURL: { opened.append($0); return true }, deviceDetails: {
                    Thread.sleep(forTimeInterval: 0.08)
                    return "## Current device info (not crash-time)\n\nCPU: Apple M2 Pro\nLogical processor count: 12\nInstalled RAM: 32 GB\nCurrent app resident memory: 128 MB"
                })
            owner.startForVerification(directory: root, identifier: identifier)
            owner.show(settings: settings, offscreen: !capture)
            defer { owner.window?.close() }
            for _ in 0..<100 {
                if owner.reports.count == 1 && owner.canDiscardPending { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(owner.reports.count == 1 && owner.canDiscardPending,
                "Crash review did not retain the earlier report beside an unreadable pending capture")
            try check(copied.isEmpty && opened.isEmpty, "Opening crash review shared data")
            owner.select(owner.reports.first?.id)
            let retainedText = try owner.reports[0].text()
            for _ in 0..<100 {
                if !owner.preparingReport { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let retainedAfterDevice = try owner.reports[0].text()
            try check(!owner.preparingReport && owner.hasCurrentDeviceInfo && owner.document.contains("CPU: Apple M2 Pro")
                && owner.document.contains("not crash-time") && retainedAfterDevice == retainedText
                && copied.isEmpty && opened.isEmpty, "Default device info changed capture data or shared text")
            let withDevice = owner.document
            owner.select(owner.reports.first?.id)
            try check(owner.document == withDevice, "Device details were appended repeatedly")
            owner.prepareBugReport(settings: settings)
            for _ in 0..<100 {
                if !owner.preparingReport { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(!owner.preparingReport && owner.document.contains("CPU: Apple M2 Pro")
                && owner.document.contains("Installed RAM: 32 GB") && copied.isEmpty && opened.isEmpty,
                "A new bug report omitted default device details or shared automatically")
            owner.select(owner.reports.first?.id)
            owner.document += "\nGenerated comment: /Users/Generated/Taxes_2026.pdf person@example.invalid\n"
            owner.redact()
            for _ in 0..<100 {
                if !owner.working { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(!owner.working && !owner.document.contains("Taxes_2026.pdf")
                && !owner.document.contains("person@example.invalid"), "Crash privacy helper did not update the reviewed text")
            owner.openGitHubDraft()
            for _ in 0..<100 {
                if !owner.working { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(!owner.working, "Crash draft worker did not finish")
            try check(copied.isEmpty, "Opening a crash draft wrote the clipboard")
            try check(opened.count == 1, "Crash draft did not open: " + owner.notice)
            try check(opened[0].host == "github.com", "Crash draft used a different destination")
            try check(URLComponents(url: opened[0], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "body" })?.value == owner.document,
                "Crash draft did not contain the full reviewed text")
            try check(owner.notice.contains("nothing was submitted"), "Crash draft submission disclosure was missing")
            owner.copyReport()
            try check(copied == [owner.document] && opened.count == 1, "Copy Report opened a browser or copied different text")
            let reviewed = owner.document
            owner.document = String(repeating: "Generated report detail.\n", count: 1000)
            owner.openGitHubDraft()
            for _ in 0..<100 {
                if !owner.working { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(opened.count == 2 && copied == [reviewed] && owner.notice.contains("abbreviated")
                && URLComponents(url: opened[1], resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "body" })?.value?.hasPrefix(GitHubIssueDraft.abbreviatedHeading) == true,
                "Oversized draft omitted its marker, copied text, or claimed complete prefill")
            owner.document = reviewed
            owner.openGitHubDraft()
            owner.document += "\nEdited while preparing the URL."
            for _ in 0..<100 {
                if !owner.working { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(opened.count == 2 && copied == [reviewed] && owner.notice.contains("changed"),
                "A stale draft opened or wrote the clipboard")
            owner.document = reviewed

            guard let window = owner.window else { throw UIVerification.Failure(message: "Crash review window missing") }
            window.setContentSize(.init(width: 640, height: 640))
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = window.contentView {
                let pdf = content.dataWithPDF(inside: content.bounds)
                try check(pdf.count < 2 << 20, "Crash review render exceeded its bound")
                try await Task.detached { try pdf.write(to: evidence.appendingPathComponent("crash-review-large.pdf"), options: .withoutOverwriting) }.value
            }
            if capture {
                try await GlassVerification.captureOwnedWindow(window, to: evidence.appendingPathComponent("crash-review-large.png"))
            }
            owner.discardUnreadableCapture()
            guard let cancelled = window.attachedSheet else { throw UIVerification.Failure(message: "Crash discard confirmation missing") }
            window.endSheet(cancelled, returnCode: .alertFirstButtonReturn)
            for _ in 0..<100 {
                if window.attachedSheet == nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(window.attachedSheet == nil, "Crash discard sheet did not finish cancelling")
            try check(owner.canDiscardPending && !owner.working, "Cancel consumed or discarded the pending capture")
            owner.discardUnreadableCapture()
            guard let confirmed = window.attachedSheet else { throw UIVerification.Failure(message: "Crash discard confirmation did not reopen") }
            window.endSheet(confirmed, returnCode: .alertSecondButtonReturn)
            for _ in 0..<100 {
                if !owner.canDiscardPending && !owner.working { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(!owner.working && !owner.canDiscardPending && owner.reports.count == 1
                && owner.notice.hasPrefix("Discarded"), "Confirmed pending discard lost the retained report or failed")
            owner.prepareBugReport(settings: settings)
            owner.document += "\nGenerated note kept across a quick close."
            owner.window?.close()
            try check(owner.window == nil, "Report preparation prevented ordinary close")
            owner.show(settings: settings, offscreen: !capture)
            for _ in 0..<100 {
                if !owner.preparingReport { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(!owner.preparingReport && owner.document.contains("Generated note kept across a quick close.")
                && owner.document.components(separatedBy: CurrentDeviceDetails.heading).count == 2
                && owner.document.contains("CPU: Apple M2 Pro") && opened.count == 2 && copied == [reviewed],
                "Closing during device preparation lost a draft, omitted/duplicated device facts or shared automatically")
        }
        private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw UIVerification.Failure(message: message) }
        }
    }
#endif
