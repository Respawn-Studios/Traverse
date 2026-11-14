import AppKit
import Combine
import ExplorerCore
import LocalStorage
#if TRAVERSE_PRIVATE_UPDATER && TRAVERSE_PUBLIC_UPDATER
#error("Private and public updater modes are mutually exclusive")
#endif
#if TRAVERSE_LOCAL_USER_DIRECT && !TRAVERSE_PUBLIC_UPDATER
#error("The local-user edition requires its dedicated public updater composition")
#endif
#if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
import DirectUpdates
import Sparkle
#endif

/// The app owner of update consent and lifecycle. Private invitations remain
/// exclusive to the private-beta composition.
/// Sparkle owns signature verification and installation in the direct edition.
@MainActor final class ApplicationUpdates: NSObject, ObservableObject {
    static let shared = ApplicationUpdates()
    @Published private(set) var working = false
    @Published private(set) var hasInvitation = false
    @Published private(set) var notice = ""
    @Published private(set) var credentialNotice = ""
    @Published private(set) var lastChecked: Date?
    @Published private(set) var retryRestartAvailable = false
    private var settings: BrowserSettings?
    private var observation: AnyCancellable?
    private var setupObservation: AnyCancellable?
    private var task: Task<Void,Never>?
    private var shuttingDown = false
    #if DEBUG
    var availabilityForVerification: Bool?
    var requiresInvitationForVerification: Bool?
    #endif
    #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
    private var controller: SPUStandardUpdaterController?
    #if TRAVERSE_PRIVATE_UPDATER
    private let vault = UpdateInvitationStore()
    private var invitation: PrivateUpdateInvitation?
    #endif
    private var restartHandler: (() -> Void)?
    private var trace = UUID()
    private var started = false
    private var installationAdmitted = false
    #endif
    var requiresInvitation: Bool {
        #if DEBUG
        if let requiresInvitationForVerification { return requiresInvitationForVerification }
        #endif
        #if TRAVERSE_PUBLIC_UPDATER
        return false
        #else
        return true
        #endif
    }
    var hasUpdateAccess: Bool { directUpdatesAvailable && (!requiresInvitation || hasInvitation) }
    private var automaticChecksEnabled: Bool {
        requiresInvitation ? settings?.automaticUpdateChecks == true : settings?.publicAutomaticUpdateChecks == true
    }
    var directUpdatesAvailable: Bool {
        #if DEBUG
        if let availabilityForVerification { return availabilityForVerification }
        #endif
        #if TRAVERSE_PUBLIC_UPDATER
        #if TRAVERSE_LOCAL_USER_DIRECT
        return AppFeatureAvailability.policy.edition == .directPublic
        #else
        return AppFeatureAvailability.policy.edition == .publicRelease
        #endif
        #elseif TRAVERSE_PRIVATE_UPDATER
        return true
        #else
        return false
        #endif
    }
    var editionMessage: String {
        let channel = Bundle.main.object(forInfoDictionaryKey:"MacExplorerDistributionChannel") as? String
        if channel == "app-store" { return "Updates for this edition are delivered by TestFlight or the App Store." }
        if channel == "development-preview" { return "This is a local preview. New preview builds are installed separately from your beta." }
        if !requiresInvitation { return "Free, signed updates. You choose when to check, download and install." }
        return "Private updates are available in the updater-enabled direct beta. Local development builds are installed separately."
    }
    func start(settings: BrowserSettings) {
        guard self.settings == nil else { return }; self.settings = settings
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        lastChecked = requiresInvitation ? controller?.updater.lastUpdateCheckDate : settings.publicLastUpdateCheck
        let checks = requiresInvitation ? settings.$automaticUpdateChecks : settings.$publicAutomaticUpdateChecks
        observation = checks.dropFirst().sink { [weak self] enabled in
            guard let self, started, !shuttingDown else { return }
            controller?.updater.automaticallyChecksForUpdates = enabled && hasUpdateAccess && settings.initialSetupCompleted
        }
        if settings.pendingUpdateBuild > 0 {
            let actual = UInt64(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "") ?? 0
            if actual >= settings.pendingUpdateBuild {
                notice = "Traverse updated successfully. See What's New for the changes."
                ApplicationDiagnostics.shared.event(.updates,.completed,count:actual)
                settings.pendingUpdateBuild = 0
            } else { notice = "A previous update did not finish. Your current version is still available."; ApplicationDiagnostics.shared.event(.updates,.interrupted) }
        }
        setupObservation = settings.$initialSetupCompleted.removeDuplicates().sink { [weak self] complete in
            guard complete, let self else { return }
            #if TRAVERSE_PRIVATE_UPDATER
            restoreInvitationIfRequested()
            #else
            configureAndStart(headers: [:])
            #endif
            if started {
                controller?.updater.automaticallyChecksForUpdates = automaticChecksEnabled && hasUpdateAccess
                becameActive()
            }
        }
        #endif
    }
    func becameActive() {
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        guard !shuttingDown, settings?.initialSetupCompleted == true, automaticChecksEnabled,
              hasUpdateAccess, started, controller?.updater.canCheckForUpdates == true,
              controller?.updater.sessionInProgress == false,
              lastChecked.map({ Date().timeIntervalSince($0) >= 21600 }) ?? true else { return }
        controller?.updater.resetUpdateCycleAfterShortDelay()
        #endif
    }
    func check() {
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        guard !shuttingDown, hasUpdateAccess, settings?.initialSetupCompleted == true, !working else { return }
        beginCheck(userInitiated:true)
        #endif
    }
    func useInvitation(_ text: String, remember: Bool, checkImmediately: Bool = true) {
        #if TRAVERSE_PRIVATE_UPDATER
        guard !shuttingDown, !working else { return }
        let value: PrivateUpdateInvitation
        do { value = try .init(text) } catch { notice = "Enter the invitation password supplied with your beta."; return }
        working = true; notice = "Checking beta access…"
        trace = ApplicationDiagnostics.shared.begin(.updates)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: PrivateUpdateEndpoint.production.feed)
                request.setValue(value.authorization, forHTTPHeaderField:"Authorization")
                request.setValue(PrivateUpdateTransport.markerValue, forHTTPHeaderField:PrivateUpdateTransport.marker)
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [PrivateUpdateTransport.self]; config.urlCache = nil; config.httpCookieStorage = nil
                let session = URLSession(configuration:config)
                defer { session.invalidateAndCancel() }
                _ = try await session.data(for:request)
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                invitation = value; hasInvitation = true
                if remember {
                    do { try await vault.save(value); settings?.updateInvitationSaved = true; credentialNotice = "Beta access is saved in Keychain." }
                    catch {
                        credentialNotice = settings?.updateInvitationSaved == true
                            ? "This session uses your new invitation, but Keychain was not updated. A previous saved password may remain."
                            : "Beta access works for this session. The password could not be saved in Keychain."
                        ApplicationDiagnostics.shared.event(.credentials,.partial,error:DiagnosticErrors.project(error))
                    }
                } else if settings?.updateInvitationSaved == true {
                    do { try await vault.forget(); settings?.updateInvitationSaved = false; credentialNotice = "Beta access is available for this session only." }
                    catch { credentialNotice = "This session uses your invitation. The previously saved password could not be removed."; ApplicationDiagnostics.shared.event(.credentials,.partial,error:DiagnosticErrors.project(error)) }
                } else { credentialNotice = "Beta access is available for this session only." }
                try Task.checkCancellation()
                guard !shuttingDown else { throw CancellationError() }
                configureAndStart(headers: ["Authorization": value.authorization])
                working = false; task = nil
                if checkImmediately, settings?.initialSetupCompleted == true { beginCheck(userInitiated:true) }
                else { notice = "Beta update access is ready. You choose when to install an update." }
            } catch {
                working = false; task = nil
                let code = error as NSError
                if code.domain == "Traverse.PrivateUpdate", code.code == 8 {
                    notice = "Too many recent access attempts. Wait 15 minutes before trying again."
                } else if code.domain == "Traverse.PrivateUpdate", code.code == 5 {
                    notice = "The update service is busy. Try again in a moment."
                } else { notice = "Beta access could not be checked. Check your connection and invitation password, then try again." }
                ApplicationDiagnostics.shared.event(.updates,Task.isCancelled ? .cancelled : .failed,trace:trace,error:DiagnosticErrors.project(error))
            }
        }
        #endif
    }
    func forgetInvitation() {
        #if TRAVERSE_PRIVATE_UPDATER
        guard !shuttingDown, !working, controller?.updater.sessionInProgress != true, PrivateUpdateTransport.activeRequests == 0 else {
            notice = "Finish or cancel the current update before forgetting beta access."; return
        }
        working = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await vault.forget()
                invitation = nil; hasInvitation = false; settings?.updateInvitationSaved = false
                controller?.updater.httpHeaders = [:]; controller?.updater.automaticallyChecksForUpdates = false
                notice = "Saved beta access removed. Enter an invitation password to check again."
                credentialNotice = ""
                ApplicationDiagnostics.shared.event(.credentials,.completed)
            } catch { notice = "Saved beta access could not be removed. Try again when Keychain is available."; ApplicationDiagnostics.shared.event(.credentials,.failed) }
            working = false; task = nil
        }
        #endif
    }
    func enterDifferentInvitation() {
        #if TRAVERSE_PRIVATE_UPDATER
        guard !shuttingDown, !working, controller?.updater.sessionInProgress != true else {
            notice = "Finish or cancel the current update before changing beta access."; return
        }
        invitation = nil; hasInvitation = false
        controller?.updater.automaticallyChecksForUpdates = false; controller?.updater.httpHeaders = [:]
        notice = "Enter the invitation password you want to use."
        credentialNotice = settings?.updateInvitationSaved == true ? "A saved invitation remains until you replace or forget it." : ""
        #endif
    }
    func retryRestart() {
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        guard let restartHandler, !shuttingDown else { return }
        self.restartHandler = nil; retryRestartAvailable = false; restartHandler()
        #endif
    }
    static var unsavedNamesWindow: NSWindow? {
        NSApplication.shared.windows.first { window in
            guard window.isVisible else { return false }
            if let properties = window.windowController as? FilePropertiesWindowController {
                return properties.namesEditor?.hasChanges == true
            }
            return (window.windowController as? PrivateNamesSheet)?.model.hasChanges == true
        }
    }
    func prepareWorkspaceForRestart(_ controller: BrowserWindowController) async -> Bool {
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        guard installationAdmitted, let target = settings?.pendingUpdateBuild, target > 0 else { return true }
        do {
            let source = UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
            let record = try controller.workspace.updateResumeRecord(targetBuild: target, sourceBuild: source)
            try await controller.workspace.updateResumeStore.save(record)
            ApplicationDiagnostics.shared.event(.updates, .preparing, trace: trace)
            return true
        } catch {
            notice = "Your windows could not be saved for this update. Traverse remains open; try restarting the update again."
            ApplicationDiagnostics.shared.event(.updates, .failed, trace: trace, error: DiagnosticErrors.project(error))
            return false
        }
        #else
        return true
        #endif
    }
    func closeAndDrain() async -> Bool {
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        // Sparkle exposes cancellation through its maintained update window,
        // not a public force-cancel API. Do not call an active native download
        // drained merely because our separate invitation request has ended.
        if controller?.updater.sessionInProgress == true, !installationAdmitted {
            notice = "Finish or cancel the update check or download before quitting."
            controller?.checkForUpdates(nil)
            return false
        }
        #endif
        shuttingDown = true; task?.cancel(); await task?.value
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        controller?.updater.automaticallyChecksForUpdates = false
        #endif
        #if TRAVERSE_PRIVATE_UPDATER
        return await PrivateUpdateTransport.closeAndDrain()
        #else
        return true
        #endif
    }
    func resumeAfterCancelledTermination() {
        shuttingDown = false
        #if TRAVERSE_PRIVATE_UPDATER
        PrivateUpdateTransport.resume()
        #endif
        #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
        if started { controller?.updater.automaticallyChecksForUpdates = automaticChecksEnabled && hasUpdateAccess }
        #endif
    }
    #if TRAVERSE_PRIVATE_UPDATER
    private func restoreInvitationIfRequested() {
        guard settings?.updateInvitationSaved == true, !working, !hasInvitation, !shuttingDown else { return }
        working = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let value = try await vault.read(), !shuttingDown {
                    invitation = value; hasInvitation = true; configureAndStart(headers: ["Authorization": value.authorization])
                    credentialNotice = "Beta access was restored from Keychain."
                } else { notice = "Enter your beta invitation password to check for updates." }
            } catch { notice = "Saved beta access is unavailable. You can enter the invitation password again." }
            working = false; task = nil
            if settings?.automaticUpdateChecks == true { becameActive() }
        }
    }
    #endif
    #if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
    private func configureAndStart(headers: [String: String]) {
        guard hasUpdateAccess, let controller else { return }
        controller.updater.httpHeaders = headers
        // Sparkle remembers this separately from BrowserSettings. Apply the
        // selected edition's choice before start can schedule its first cycle.
        controller.updater.automaticallyChecksForUpdates = settings?.initialSetupCompleted == true && automaticChecksEnabled && hasUpdateAccess
        if !started {
            do { try controller.updater.start(); started = true }
            catch { notice = "Updates could not start. Your installed app is unchanged."; ApplicationDiagnostics.shared.event(.updates,.failed,error:DiagnosticErrors.project(error)); return }
        }
        controller.updater.automaticallyChecksForUpdates = settings?.initialSetupCompleted == true && automaticChecksEnabled && hasUpdateAccess
    }
    private func beginCheck(userInitiated: Bool) {
        guard started, let controller, controller.updater.canCheckForUpdates else { return }
        trace = ApplicationDiagnostics.shared.begin(.updates)
        notice = "Checking for updates…"; recordCheck()
        if userInitiated { controller.checkForUpdates(nil) } else { controller.updater.checkForUpdatesInBackground() }
    }
    #endif
    private func recordCheck() {
        let date = Date()
        lastChecked = date
        if !requiresInvitation { settings?.publicLastUpdateCheck = date }
    }
}

#if TRAVERSE_PRIVATE_UPDATER || TRAVERSE_PUBLIC_UPDATER
extension ApplicationUpdates: SPUUpdaterDelegate {
    #if TRAVERSE_PUBLIC_UPDATER
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if TRAVERSE_LOCAL_USER_DIRECT
        PublicUpdateEndpoint.directProduction.feed.absoluteString
        #else
        PublicUpdateEndpoint.production.feed.absoluteString
        #endif
    }
    #endif
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !shuttingDown, hasUpdateAccess, settings?.initialSetupCompleted == true else { throw NSError(domain:"Traverse.Update",code:1) }
        installationAdmitted = false
        ApplicationDiagnostics.shared.event(.updates,.reading,trace:trace)
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let url = item.fileURL, permits(url), url.path.hasSuffix(".dmg"),
              item.contentLength > 0, item.contentLength <= 128 << 20,
              item.releaseNotesURL.map(permits) ?? requiresInvitation,
              UInt64(item.versionString) != nil, !item.isInformationOnlyUpdate else {
            throw NSError(domain:"Traverse.PrivateUpdate",code:1)
        }
        #if TRAVERSE_PUBLIC_UPDATER
        guard item.isMacOsUpdate, item.minimumSystemVersion == "15.0.0",
              item.minimumOperatingSystemVersionIsOK, item.maximumOperatingSystemVersionIsOK,
              item.hardwareRequirements.count == 1, item.hardwareRequirements.contains("arm64"),
              item.arm64HardwareRequirementIsOK,
              item.versionString.range(of: #"^[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil,
              item.releaseNotesURL?.lastPathComponent == item.versionString + ".html",
              item.fullReleaseNotesURL == nil || item.fullReleaseNotesURL == item.releaseNotesURL else {
            throw NSError(domain: "Traverse.Update", code: 1)
        }
        #endif
    }
    private func permits(_ url: URL) -> Bool {
        #if TRAVERSE_PUBLIC_UPDATER
        #if TRAVERSE_LOCAL_USER_DIRECT
        return PublicUpdateEndpoint.directProduction.permits(url)
        #else
        return PublicUpdateEndpoint.production.permits(url)
        #endif
        #else
        return PrivateUpdateEndpoint.production.permits(url)
        #endif
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        notice = "An update is available. Review its changes before installing."
        ApplicationDiagnostics.shared.event(.updates,.presenting,trace:trace,count:UInt64(item.versionString))
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        notice = reason == 1 || reason == 2 ? "You're up to date." : "No compatible update is available for this Mac."
        recordCheck(); ApplicationDiagnostics.shared.event(.updates,.completed,trace:trace)
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        ApplicationDiagnostics.shared.event(.updates,.transferring,trace:trace)
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { ApplicationDiagnostics.shared.event(.updates,.verifying,trace:trace) }
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) { ApplicationDiagnostics.shared.event(.updates,.preparing,trace:trace) }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationAdmitted = true
        settings?.pendingUpdateBuild = UInt64(item.versionString) ?? 0
        ApplicationDiagnostics.shared.event(.updates,.committing,trace:trace,count:UInt64(item.versionString))
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard ApplicationOperationCoordinator.shared.liveBrowsers.contains(where: \.hasPendingFileOperation)
                || ApplicationPrivateNames.shared.isSaving || Self.unsavedNamesWindow != nil else { return false }
        restartHandler = installHandler; retryRestartAvailable = true
        notice = "Finish the current file work, then choose Restart to Update."
        ApplicationDiagnostics.shared.event(.updates,.waiting,trace:trace); return true
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            installationAdmitted = false; settings?.pendingUpdateBuild = 0
            restartHandler = nil; retryRestartAvailable = false
            ApplicationDiagnostics.shared.event(.updates,.cancelled,trace:trace)
        }
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { ApplicationDiagnostics.shared.event(.updates,.restarting,trace:trace) }
    func userDidCancelDownload(_ updater: SPUUpdater) { notice = "Update download cancelled. Your installed app is unchanged."; ApplicationDiagnostics.shared.event(.updates,.cancelled,trace:trace) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationAdmitted = false
        notice = requiresInvitation
            ? "The update couldn't finish. Check your connection or beta access and try again. If Traverse cannot restart, use the latest manual installer."
            : "The update couldn't finish. Check your connection and try again. If Traverse cannot restart, use the latest manual installer."
        ApplicationDiagnostics.shared.event(.updates,.failed,trace:trace,error:.init(domain:.updater,code:Int64((error as NSError).code)))
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        recordCheck()
        if error == nil { ApplicationDiagnostics.shared.event(.updates,.finished,trace:trace) }
    }
}
#endif
