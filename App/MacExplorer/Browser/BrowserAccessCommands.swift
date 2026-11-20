import AppKit

/// Presentation metadata only. Saved roots have no expandable children: merely
/// displaying the group must never enumerate protected or unavailable folders.
@MainActor
final class RememberedFolderSidebar {
    private var identities: [ObjectIdentifier: UUID] = [:]

    func group(for references: [FolderAccessRestoreResult]) -> SidebarNode {
        identities = [:]
        let children = references.map { reference -> SidebarNode in
            let name = reference.url.map { $0.path == "/" ? "/" : $0.lastPathComponent } ?? "Unavailable saved folder"
            let title: String
            let icon: String
            switch reference.state {
            case .resolvedUnverified: title = name; icon = "folder.badge.person.crop"
            case .needsRenewal: title = reference.url == nil ? "Choose folder again…" : name + " — choose again"; icon = "folder.badge.questionmark"
            case .unavailable: title = reference.url == nil ? "Folder needs access" : name + " — unavailable"; icon = "exclamationmark.folder"
            }
            let node = SidebarNode(title, icon: icon, children: [])
            identities[ObjectIdentifier(node)] = reference.id
            return node
        }
        if children.isEmpty { return SidebarNode("Remembered Folders", group: true, children: []) }
        return SidebarNode("Remembered Folders", group: true, children: children)
    }

    func referenceID(for node: SidebarNode) -> UUID? { identities[ObjectIdentifier(node)] }
}

struct FileAccessLifetimes: Sendable {
    let leases: [FolderAccessLease]

    func covers(_ url: URL) -> Bool {
        leases.contains { url.standardizedFileURL.pathComponents.starts(with: $0.url.standardizedFileURL.pathComponents) }
    }
}

@MainActor extension FolderAccessController {
    func retainAccess(for urls: [URL]) async -> FileAccessLifetimes {
        var leases: [FolderAccessLease] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            if !FileAccessLifetimes(leases: leases).covers(url), let lease = await acquireAccess(to: url) {
                leases.append(lease)
            }
        }
        return .init(leases: leases)
    }
}

@MainActor
extension BrowserViewController {
    /// A denied operation offers access selection, never an automatic retry.
    /// The chooser supplies real authority; Full Disk Access is not inferred.
    func requestOperationFolderAccess(initialDirectory: URL?) {
        guard !isBrowserSuspended, !isReadOnlyFileSession, canRunExclusiveFileCommand,
              operationTask == nil, operationPreparationTask == nil,
              operationCoordinator.activeOwner == nil, operationCoordinator.preparationOwner == nil,
              operationCoordinator.copyPreviewOwner == nil,
              let window = view.window, window.attachedSheet == nil else { return }
        #if DEBUG
        if isVerificationSession, let request = operationFolderAccessRequestForVerification {
            request(initialDirectory); return
        }
        #endif
        Task { [weak self, weak window] in
            guard let self, let window, !self.isBrowserSuspended else { return }
            guard let choice = await self.folderAccess.chooseFolder(in: window,
                initialDirectory: initialDirectory ?? self.location.directoryURL,
                remember: true, purpose: .fileOperation) else {
                if !self.isBrowserSuspended { self.status.stringValue = "Folder access unchanged. No operation was retried." }
                return
            }
            guard !self.isBrowserSuspended, self.view.window === window else { return }
            if case .failed = choice.remembering {
                self.status.stringValue = "Folder selected for this session, but it could not be remembered. Try the operation again when ready."
            } else {
                self.status.stringValue = "Folder access selected. Try the operation again when ready; another source or destination may also need access."
            }
            await self.refreshRememberedFolderReferences()
            withExtendedLifetime(choice) {}
        }
    }

    var isVerificationSession: Bool { ProcessInfo.processInfo.arguments.contains("--verify-ui") }

    var isMetadataAccessQualification: Bool {
        #if DEBUG
        isVerificationSession && ProcessInfo.processInfo.arguments.contains("--qualify-permission-retry")
        #else
        false
        #endif
    }

    var isReadOnlyFileSession: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        if GeneratedSandboxReview.retainedEditorReadOnlyAdmitted { return true }
        if GeneratedSandboxReview.containerReviewRequested {
            return !(GeneratedSandboxReview.localFileReviewAdmitted
                || GeneratedSandboxReview.nativeTARCreateAdmitted
                || GeneratedSandboxReview.publicQuarantineDownloadAdmitted
                || GeneratedSandboxReview.smbPublicQuarantineDownloadAdmitted
                || GeneratedSandboxReview.zipOneFileExtractionAdmitted
                || GeneratedSandboxReview.archiveInternalAdmitted
                || GeneratedSandboxReview.publicationOnlyReviewAdmitted)
        }
        #endif
        #if DEBUG
        return isMetadataAccessQualification || ProcessInfo.processInfo.arguments.contains("--appearance-prototype")
        #else
        return false
        #endif
    }

    var developmentStateDirectory: URL? {
        #if TRAVERSE_SFTP_EDITOR_QA
        // Read-only SMB/metadata visits keep browser persistence transient.
        // The SMB editor supplies its history root only at the engine seam;
        // received-file visits need the ordinary private Download journal.
        if GeneratedSandboxReview.containerReviewRequested
            && !GeneratedSandboxReview.localFileReviewAdmitted
            && !GeneratedSandboxReview.nativeTARCreateAdmitted
            && !GeneratedSandboxReview.publicQuarantineDownloadAdmitted
            && !GeneratedSandboxReview.smbPublicQuarantineDownloadAdmitted
            && !GeneratedSandboxReview.zipOneFileExtractionAdmitted
            && !GeneratedSandboxReview.publicationOnlyReviewAdmitted {
            return nil
        }
        #endif
        return AppStorageLocations.stateDirectory
    }

    func accessLifetime(for urls: [URL]) async -> FileAccessLifetimes {
        await folderAccess.retainAccess(for: urls)
    }

    func presentFolderChooser(remember: Bool, replacingReference: UUID? = nil) {
        guard let window = view.window else { return }
        let initial = replacingReference.flatMap { id in rememberedFolders.first(where: { $0.id == id })?.url } ?? location.directoryURL
        Task { [weak self] in
            guard let self, let choice = await self.folderAccess.chooseFolder(in: window, initialDirectory: initial,
                remember: remember, replacingReference: replacingReference) else { return }
            if case .failed(let diagnostic) = choice.remembering {
                let alert = NSAlert()
                alert.messageText = "Folder reference could not be remembered"
                alert.informativeText = diagnostic.message
                _ = await alert.beginSheetModal(for: window)
            }
            self.navigate(to: .directory(choice.selection.url))
            self.focusBrowserContent()
            if case .saved = choice.remembering { await self.refreshRememberedFolderReferences() }
        }
    }

    func refreshRememberedFolderReferences() async {
        rememberedFolders = await folderAccess.resolveRememberedFolders()
        rebuildSidebar()
    }

    func openRememberedFolderReference(_ id: UUID) {
        guard let reference = rememberedFolders.first(where: { $0.id == id }) else { return }
        switch reference.state {
        case .resolvedUnverified:
            guard let url = reference.url else { return }
            navigate(to: .directory(url))
            focusBrowserContent()
        case .needsRenewal, .unavailable:
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Saved folder reference needs attention"
            alert.informativeText = "Choose a folder to replace this saved access reference, or forget the reference. The folder you explicitly choose may have a different location. macOS privacy controls still apply."
            alert.addButton(withTitle: "Choose Folder…")
            alert.addButton(withTitle: "Forget Reference")
            alert.addButton(withTitle: "Cancel")
            Task { [weak self] in
                let response = await alert.beginSheetModal(for: window)
                guard let self else { return }
                if response == .alertFirstButtonReturn { self.presentFolderChooser(remember: true, replacingReference: id) }
                if response == .alertSecondButtonReturn { await self.forgetRememberedFolderReference(id) }
            }
        }
    }

    func forgetRememberedFolderReference(_ id: UUID) async {
        if let diagnostic = await folderAccess.forget(id: id) { status.stringValue = diagnostic.message }
        await refreshRememberedFolderReferences()
    }

    @objc func rememberFolder(_ sender: Any?) { presentFolderChooser(remember: true) }

    @objc func manageFolderAccess(_ sender: Any?) {
        guard let window = view.window else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshRememberedFolderReferences()
            let references = self.rememberedFolders
            let alert = NSAlert()
            alert.messageText = "Remembered folders"
            alert.informativeText = "These are saved folder references. macOS privacy controls and filesystem permissions still apply. Forgetting a reference does not revoke a macOS permission."
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Remember Another Folder…")
            let forget = alert.addButton(withTitle: "Forget Selected Reference")
            let renew = alert.addButton(withTitle: "Choose Folder for Selected Reference…")
            let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
            for item in references {
                let suffix: String
                switch item.state {
                case .resolvedUnverified: suffix = ""
                case .needsRenewal: suffix = " — choose again to renew"
                case .unavailable: suffix = " — unavailable"
                }
                chooser.addItem(withTitle: (item.url?.path ?? "Unavailable saved reference") + suffix)
            }
            if references.isEmpty { chooser.addItem(withTitle: "No remembered folders") }
            forget.isEnabled = !references.isEmpty
            renew.isEnabled = !references.isEmpty
            alert.accessoryView = chooser
            let response = await alert.beginSheetModal(for: window)
            if response == .alertSecondButtonReturn { self.presentFolderChooser(remember: true) }
            if references.indices.contains(chooser.indexOfSelectedItem) {
                let id = references[chooser.indexOfSelectedItem].id
                if response == .alertThirdButtonReturn { await self.forgetRememberedFolderReference(id) }
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                    self.presentFolderChooser(remember: true, replacingReference: id)
                }
            }
        }
    }

    @objc func openPrivacySettings(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Review folder access"
        alert.informativeText = FolderAccessController.privacySettingsInstructions
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { _ = self.folderAccess.openPrivacySettings() }
        }
    }

    @objc func showProperties(_ sender: Any?) {
        if isArchiveLocation { showObservedArchiveProperties(); return }
        if isRemoteLocation { showObservedRemoteProperties(); return }
        let urls = orderedSelectedURLs.isEmpty ? location.directoryURL.map { [$0] } ?? [] : orderedSelectedURLs
        guard !urls.isEmpty else { return }
        ApplicationStorageAnalysis.shared.configurePicker(from: self)
        propertiesController.show(urls: urls, relativeTo: view.window)
    }
}
