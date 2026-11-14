#if DEBUG
import AppKit
import Darwin
import ExplorerCore

/// Human toggles the app-specific Downloads control. This helper never changes
/// TCC, requests Full Disk Access, opens file bodies, or captures a window.
@MainActor
enum PermissionRetryVerification {
    private struct AccessObservation: Encodable, Sendable {
        let listingComplete: Bool
        let readable: Bool
        let shallowEntryCount: Int
        let metadataIssueCount: Int
        let failureKind: String?
        let denialDiagnosticPresent: Bool
        let retryOverlayVisible: Bool
        let retryActionAvailable: Bool
        let rawPOSIXErrno: Int? = nil
        let errnoEvidence = "LocalStorage combines EACCES and EPERM into accessDenied; raw errno is unavailable here. No specific TCC cause is inferred."
    }

    private struct Receipt: Encodable, Sendable {
        let mode = "foreground-human-permission-retry"
        var status = "prepared-awaiting-human-off"
        var qualified = false
        var humanOffObservation: String?
        var humanOnObservation: String?
        var deniedAttempt: AccessObservation?
        var retryAttempt: AccessObservation?
        var retryAction = "not-invoked"
        var returnedToOwnedFixture = false
        let captureBoundary = "No screenshots, desktop capture, personal filenames, file bodies, bookmark bytes or Downloads child paths. Human toggle instructions/requests are recorded separately from backend error evidence."
        let notExercised = ["Automated TCC state inspection or changes", "Full Disk Access", "Other protected folders",
                            "Permission behavior after required app restart", "Consent retention across rebuilds", "Physical click on the browser Retry button"]
    }

    static func run(_ browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String: Any] {
        let args = ProcessInfo.processInfo.arguments
        let otherModes = ["--offscreen", "--qualify-permissions", "--qualify-folder-access", "--qualify-trash",
                          "--qualify-trash-fixture", "--restore-trash-fixture", "--qualify-glass", "--qualify-folder-reopen",
                          "--resume-folder-access", "--check-presentation", "--check-chrome", "--check-workspace"]
        try require(args.contains("--verify-ui") && args.contains("--qualify-permission-retry")
            && !otherModes.contains(where: args.contains), "Permission retry requires its separate explicit foreground mode")
        try require(!browser.settings.restoresSession, "Permission retry requires in-memory session state")
        guard let window = browser.view.window, NSApplication.shared.isActive, window.isKeyWindow else {
            throw UIVerification.Failure(message: "Permission retry requires the active native browser window")
        }
        let receiptURL = output.appendingPathComponent("permission-retry-qualification.json")
        try await Task.detached {
            try validateRoots(fixture: fixture, output: output)
            try reserve(receiptURL)
        }.value
        var receipt = Receipt()
        try await write(receipt, to: receiptURL)
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

        do {
            let off = await prompt(window, title: "Turn this app’s Downloads access off",
                message: "1. In System Settings > Privacy & Security > Files & Folders > Mac Explorer, turn Downloads OFF.\n2. Return here and choose Check Denied Access.\n3. If macOS asks whether Mac Explorer may access Downloads, choose Don’t Allow for this denial step. Choosing Allow makes the folder readable again.\n\nThis check lists shallow metadata only; no filenames enter evidence and no window is captured. You will turn Downloads ON afterward. If macOS requires quitting, cancel this check and restore the toggle manually; this process cannot qualify that restart.",
                buttons: ["Check Denied Access", "Cancel and Return to Fixture"])
            guard off == .alertFirstButtonReturn else {
                receipt.humanOffObservation = "human-cancelled-off-step"
                receipt.status = "human-cancelled-not-qualified"
                try await returnToFixture(browser, fixture: fixture, receipt: &receipt, receiptURL: receiptURL)
                _ = await prompt(window, title: "Finish without permission qualification",
                    message: "If you changed this development app’s Downloads toggle, turn it ON again in Files & Folders before finishing. No permission was changed or reset automatically. The browser has returned to the generated fixture.",
                    buttons: ["Downloads Is On — Finish Check"])
                receipt.humanOnObservation = "human-finished-after-cancellation-restore-on-instructions; system toggle state not programmatically verified"
                try await write(receipt, to: receiptURL)
                return try result(receipt)
            }
            receipt.humanOffObservation = "human-requested-check-after-off-instructions; system toggle state not programmatically verified"
            receipt.status = "checking-effective-access-after-human-off"
            try await write(receipt, to: receiptURL)
            browser.navigate(to: .directory(downloads))
            let deniedCompleted = await waitForListing(browser, at: downloads)
            let denied = observation(browser, complete: deniedCompleted)
            receipt.deniedAttempt = denied
            let retryButton = browser.overlayActions.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
            guard deniedCompleted && denied.denialDiagnosticPresent && denied.retryOverlayVisible
                    && denied.retryActionAvailable && denied.shallowEntryCount == 0, let retryButton else {
                receipt.status = denied.readable ? "access-remained-readable-denial-not-qualified" : "expected-denied-overlay-not-qualified"
                try await returnToFixture(browser, fixture: fixture, receipt: &receipt, receiptURL: receiptURL)
                _ = await prompt(window, title: "Denied access was not qualified",
                    message: "This process did not expose the expected denied-folder state and Retry action. Choosing Allow in a macOS prompt can make Downloads readable again; a readable listing or another error does not qualify denial. Turn Downloads ON again for this app before finishing. If System Settings requires an app restart, reopen a fresh development app for a later check. Nothing was reset or changed automatically.",
                    buttons: ["Downloads Is On — Finish Check"])
                receipt.humanOnObservation = "human-finished-after-restore-on-instructions; system toggle state not programmatically verified"
                try await write(receipt, to: receiptURL)
                return try result(receipt)
            }

            receipt.status = "denied-overlay-observed-awaiting-human-on"
            try await write(receipt, to: receiptURL)
            let on = await prompt(window, title: "Turn this app’s Downloads access on",
                message: "The browser reported denied access and exposed Retry.\n\n1. In System Settings > Privacy & Security > Files & Folders > Mac Explorer, turn Downloads ON again.\n2. Return here and choose Retry Access.\n3. If macOS asks for Downloads access now, choose Allow for this recovery step.\n\nThe check invokes the existing Retry action and waits for the metadata listing. The error alone does not identify TCC as its cause. If macOS requires quitting, finish without qualifying this same-process retry.",
                buttons: ["Retry Access", "Finish Without Retry"])
            guard on == .alertFirstButtonReturn else {
                receipt.humanOnObservation = "human-finished-without-retry-after-on-instructions"
                receipt.status = "denied-observed-retry-not-qualified"
                try await returnToFixture(browser, fixture: fixture, receipt: &receipt, receiptURL: receiptURL)
                return try result(receipt)
            }
            receipt.humanOnObservation = "human-requested-retry-after-on-instructions; system toggle state not programmatically verified"
            let previousVisit = browser.sessionID
            receipt.retryAction = "actual-overlay-Retry-performClick-action; physical browser-button input not qualified"
            receipt.status = "retrying-effective-access-after-human-on"
            try await write(receipt, to: receiptURL)
            retryButton.performClick(nil)
            let actionStartedNewVisit = browser.sessionID != previousVisit
            let listingFinished = await waitForListing(browser, at: downloads)
            let retryCompleted = actionStartedNewVisit && listingFinished
            let retried = observation(browser, complete: retryCompleted)
            receipt.retryAttempt = retried
            receipt.qualified = retryCompleted && retried.readable && !retried.denialDiagnosticPresent && retried.metadataIssueCount == 0
            receipt.status = receipt.qualified ? "denied-overlay-and-same-process-Retry-metadata-qualified"
                : "denied-observed-retry-not-recovered-restart-may-be-required"
            try await returnToFixture(browser, fixture: fixture, receipt: &receipt, receiptURL: receiptURL)
            if !receipt.qualified {
                _ = await prompt(window, title: "Same-process retry was not qualified",
                    message: "The real Retry action did not produce a complete readable metadata listing. Ensure Downloads is ON for this development app. If macOS says it must quit and reopen, that is a separate fresh-process check; no restart or permission reset was performed here. The browser has returned to the owned fixture.",
                    buttons: ["Finish Check"])
            }
            return try result(receipt)
        } catch {
            // Never let a parent capture/end while personal Downloads rows remain
            // visible. Even an aborted check must first return to the fixture.
            receipt.qualified = false
            receipt.status = "aborted-not-qualified"
            browser.navigate(to: .directory(fixture))
            receipt.returnedToOwnedFixture = await waitForListing(browser, at: fixture)
            try? await write(receipt, to: receiptURL)
            throw UIVerification.Failure(message: receipt.returnedToOwnedFixture
                ? "Permission retry aborted; browser returned to owned fixture. Review the sanitized receipt and ensure Downloads is ON."
                : "Permission retry aborted; owned fixture restoration did not complete. Do not capture this window. Ensure Downloads is ON.")
        }
    }

    private static func observation(_ browser: BrowserViewController, complete: Bool) -> AccessObservation {
        let kind = browser.accessDiagnostic?.kind
        let denial = kind.map { [.permissionOrACL, .policyOrOtherRestriction, .deniedCauseUnknown].contains($0) } ?? false
        let button = browser.overlayActions.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
        return AccessObservation(listingComplete: complete, readable: complete && browser.loadError == nil,
            shallowEntryCount: browser.rawEntries.count, metadataIssueCount: browser.issueCount,
            failureKind: kind?.rawValue, denialDiagnosticPresent: denial,
            retryOverlayVisible: !browser.overlay.isHidden && !browser.overlayActions.isHidden,
            retryActionAvailable: button.map { !$0.isHidden && $0.isEnabled } ?? false)
    }

    private static func waitForListing(_ browser: BrowserViewController, at url: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !Task.isCancelled {
            guard browser.location == .directory(url) else { return false }
            if !browser.isLoading && browser.orderingTask == nil { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    private static func returnToFixture(_ browser: BrowserViewController, fixture: URL, receipt: inout Receipt, receiptURL: URL) async throws {
        browser.navigate(to: .directory(fixture))
        receipt.returnedToOwnedFixture = await waitForListing(browser, at: fixture)
        try require(receipt.returnedToOwnedFixture && browser.loadError == nil, "Owned fixture restoration did not complete; do not capture this window")
        try await write(receipt, to: receiptURL)
    }

    private static func result(_ receipt: Receipt) throws -> [String: Any] {
        let data = try JSONEncoder().encode(receipt)
        let detail = try JSONSerialization.jsonObject(with: data)
        return ["passed": receipt.qualified, "qualified": receipt.qualified, "mode": receipt.mode,
                "status": receipt.status, "permissionRetry": detail, "captureBoundary": receipt.captureBoundary,
                "checks": receipt.qualified ? ["Human off/on requests, real denied diagnostic and overlay Retry action, then complete same-process metadata recovery"] : [],
                "notExercised": receipt.notExercised]
    }

    private static func prompt(_ window: NSWindow, title: String, message: String, buttons: [String]) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return await alert.beginSheetModal(for: window)
    }

    private static func write(_ receipt: Receipt, to url: URL) async throws {
        try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(to: url, options: .atomic)
        }.value
    }

    nonisolated private static func reserve(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1 }
        try require(descriptor >= 0, "Permission retry receipt already exists or cannot be reserved")
        close(descriptor)
    }

    nonisolated private static func validateRoots(fixture: URL, output: URL) throws {
        let build = fixture.deletingLastPathComponent().deletingLastPathComponent()
        try require(fixture.isFileURL && output.isFileURL && build.lastPathComponent == ".build"
            && fixture.deletingLastPathComponent().lastPathComponent == "fixtures"
            && output.deletingLastPathComponent() == build.appendingPathComponent("evidence", isDirectory: true)
            && output.lastPathComponent.hasPrefix("ui-")
            && fixture.standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL
            && output.standardizedFileURL == output.resolvingSymlinksInPath().standardizedFileURL,
            "Permission retry requires unredirected owned fixture/evidence roots")
        let marker = fixture.appendingPathComponent(".mac-explorer-fixture.json")
        let descriptor = marker.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        try require(descriptor >= 0, "Owned permission fixture marker is unavailable")
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var statValue = stat()
        try require(fstat(descriptor, &statValue) == 0 && statValue.st_mode & S_IFMT == S_IFREG && statValue.st_size > 0 && statValue.st_size <= 65_536,
                    "Owned permission fixture marker is not a bounded regular file")
        guard let data = try handle.read(upToCount: 65_537), data.count == Int(statValue.st_size),
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["generator"] as? String == "mac-explorer-dev", metadata["complete"] as? Bool == true else {
            throw UIVerification.Failure(message: "Permission retry refused an unowned fixture")
        }
    }

    nonisolated private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw UIVerification.Failure(message: message) }
    }
}
#endif
