import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor extension BrowserViewController {
    @objc func showSMBConnectionActivity(_ sender: Any?) {
        connectionService.presentActivity(in: self, isSFTP: false)
    }
    @objc func showSFTPConnectionActivity(_ sender: Any?) {
        connectionService.presentActivity(in: self, isSFTP: true)
    }
    func installSMBTab(_ owner: SMBTabController, reconnect: WorkspaceReconnectTarget? = nil, initialComponents: [SMBRemoteName] = []) {
        saveViewState()
        if let reconnect {
            guard reconnect.isCurrent, let index = tabs.firstIndex(where: { $0.id == reconnect.tabID }),
                  let parts = try? WorkspaceConnectionBinding.smbComponents(reconnect.bookmark),
                  let location = try? owner.directoryLocation(components: parts),
                  (try? tabs[index].replaceDisconnectedConnection(with: .smb(location), bookmark: owner.bookmark(for: location))) != nil else {
                _ = owner.close(); status.stringValue = WorkspaceReconnectFailure.stale.message; return
            }
            smbTabs[reconnect.tabID] = owner; smbClosedUploadNotices.removeValue(forKey: reconnect.tabID); activeID = reconnect.tabID
            loadLocation(animatingTab: true); focusBrowserContent(); return
        }
        guard let initial = try? owner.directoryLocation(components: initialComponents) else {
            _ = owner.close(); status.stringValue = "This starting folder is unavailable. Connect again to choose a folder."; return
        }
        let tab = BrowserTab(location: .smb(initial))
        smbTabs[tab.id] = owner; tabs.append(tab); activeID = tab.id
        loadLocation(animatingTab: true); focusBrowserContent()
    }
    func loadSMBLocation(_ value: SMBBrowserLocation, refresh: Bool = false) {
        guard isViewLoaded else { return }
        overlay.isHidden = true; loadingIndicator.stopAnimation(nil)
        if let owner = smbTabs[activeID], owner.connectionID == value.connectionID {
            for view in smbHost.subviews where view !== owner.rows { view.removeFromSuperview() }
            if owner.rows.superview !== smbHost { owner.rows.removeFromSuperview(); pin(owner.rows, inside: smbHost) }
            owner.attach(to: self, location: value, refresh: refresh)
        } else {
            if let bookmark = tabs[activeIndex].connectionBookmark, bookmark.kind == .smbServer {
                showSavedNetworkLocation(bookmark, in: smbHost, uploadNotice: smbClosedUploadNotices[activeID]); renderSMBStatus(nil); return
            }
            smbHost.subviews.forEach { $0.removeFromSuperview() }
            let notice = smbClosedUploadNotices[activeID]
            let text = notice.map { $0.message + "\n\nThis connection is closed. Connect again to continue browsing." }
                ?? "This SMB connection is closed. Use Connect to Server to browse again."
            showClosedNetworkLocation(in: smbHost, message: text, notice: notice,
                historyAction: #selector(showSMBUploadOutcomes(_:)), historyTitle: "Upload Outcomes…", historyIdentifier: "smb-closed-upload-history")
        }
        renderSMBStatus(smbTabs[activeID]?.session.latest)
    }
    @discardableResult func updateSMBBreadcrumbs() -> Bool {
        guard case .smb(let value) = location else { return false }
        let components = smbTabs[activeID]?.breadcrumbs(for: value) ?? [(value.displayHint, .smb(value))]
        breadcrumbLocations = components.map(\.1)
        let items = components.enumerated().map { index, component in
            let item = NSPathControlItem(); item.title = component.0
            if index == 0, let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "SMB share")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                let icon = symbol.copy() as! NSImage; icon.size = NSSize(width: 16, height: 16); icon.isTemplate = true; item.image = icon
            }
            return item
        }
        pathControl.setBreadcrumbs(items: items, locations: breadcrumbLocations); pathControl.placeholderString = nil
        pathControl.toolTip = "SMB · Click an ancestor to navigate, or enter a folder path. Connection Properties controls this connection’s options."
        return true
    }
    func renderSMBStatus(_ update: SMBBrowserUpdate?) {
        defer { updateConnectionStatusIndicator() }
        guard isSMBLocation else { return }
        overlay.isHidden = true
        if smbTabs[activeID] == nil, tabs[activeIndex].connectionBookmark?.kind == .smbServer {
            loadingIndicator.stopAnimation(nil); status.stringValue = smbClosedUploadNotices[activeID]?.message ?? "Saved SMB location · Not connected"
            status.toolTip = smbClosedUploadNotices[activeID]?.message
                ?? "Open this saved server to connect. Saved layouts do not reconnect or resume transfers automatically."
            validateNavigationButtons(); return
        }
        if let rows = smbTabs[activeID]?.rows, rows.cache.retainedCount > 0 || rows.cache.snapshot?.state == .complete && rows.cache.snapshot?.count == 0 { updateCanvasTransition() }
        if update?.directoryRejection != nil { updateCanvasTransition() }
        if let owner = smbTabs[activeID], owner.isClosing {
            loadingIndicator.stopAnimation(nil)
            status.stringValue = owner.operationNotice?.footerMessage(isIdle: false, connectionHasProblem: true)
                ?? (owner.drain == nil ? "Closing SMB connection…" : "SMB closure needs attention")
            status.toolTip = status.stringValue
            validateNavigationButtons(); return
        }
        if update?.snapshot?.state == .loading, update?.idle == false, update?.failure == nil { loadingIndicator.startAnimation(nil) }
        else { loadingIndicator.stopAnimation(nil) }
        let state: String
        if let failure = update?.failure {
            state = switch failure {
            case .stopped: "Stopped"
            case .authentication: "Sign-in failed"
            case .denied: "Access denied"
            case .security: "Secure connection unavailable"
            case .storage, .quota: "Local storage unavailable"
            case .deadline: "Connection timed out"
            case .invalidInput, .invalidOutput, .busy, .unavailable, .containment, .remote, .preflightRefused: "Disconnected"
            }
        }
        else if let rejection = update?.directoryRejection {
            state = switch rejection { case .denied: "Folder access denied · Connection available"; case .missing: "Folder not found · Connection available"; case .unavailable: "Folder unavailable · Connection available" }
        } else if let snapshot = update?.snapshot {
            let prefix = snapshot.state == .complete ? "" : "Observed so far · "
            state = "\(prefix)\(snapshot.count.formatted()) items" + (snapshot.state == .loading ? " · Reading…" : snapshot.state == .stopped ? " · Stopped" : "")
        } else { state = smbTabs[activeID] == nil ? "Connection closed" : "Preparing directory…" }
        let uploads = smbTabs[activeID]?.uploads != nil
        status.stringValue = "SMB · \(uploads ? "Write access" : "Read only") · \(state)"
        if update?.failure == nil, update?.directoryRejection == nil, let find = smbTabs[activeID]?.rows.findStatusText {
            status.stringValue = "SMB · \(uploads ? "Write access" : "Read only") · " + find
        }
        if let notice = smbTabs[activeID]?.operationNotice?.footerMessage(isIdle: update?.idle == true,
            connectionHasProblem: update?.failure != nil || update?.directoryRejection != nil) { status.stringValue = notice }
        if smbTabs[activeID] == nil, let notice = smbClosedUploadNotices[activeID] { status.stringValue = notice.message }
        status.toolTip = smbTabs[activeID]?.downloads != nil
            ? "Browse without reading file contents. Download reads only a selected regular file into a chosen local destination. Remote changes, preview and remote saved names are unavailable."
            : "Remote names and metadata only. File contents, preview, transfers, Trash and remote saved names are unavailable."
        if uploads { status.toolTip = "Upload verifies each working server copy before publishing it. Existing names are kept. If a group stops, Upload Outcomes shows the items already verified and any work needing review." }
        if smbTabs[activeID] != nil, update?.failure == nil, update?.directoryRejection == nil,
           let reason = RemoteDownloadPublicationFeature.versionHoldExplanation(featureAvailable: SMBDownloadFeature.available) {
            status.toolTip = (status.toolTip ?? "") + " " + reason
        }
        if let message = smbTabs[activeID]?.operationNotice?.footerMessage(isIdle: update?.idle == true,
            connectionHasProblem: update?.failure != nil || update?.directoryRejection != nil) {
            status.toolTip = message
        } else if smbTabs[activeID] == nil, let notice = smbClosedUploadNotices[activeID] { status.toolTip = notice.message }
        validateNavigationButtons()
    }
    func renderCurrentSMBStatus() { renderSMBStatus(smbTabs[activeID]?.session.latest) }
    @objc func disconnectSMBConnection(_ sender: Any?) {
        guard let owner = smbTabs[activeID], !owner.isClosing else { return }
        Task { [self, owner] in
            guard await ApplicationRemoteTextEditors.shared.prepareForDisconnect(owner), !owner.isClosing else { return }
            owner.close()
            owner.rows.disconnected("Closing connection… Waiting for its local work to finish.")
            if smbTabs[activeID] === owner { status.stringValue = "Closing SMB connection…" }
        }
    }
    func finishSMBDisconnect(_ owner: SMBTabController, result: SMBBrowserDrainResult) {
        defer { refreshConnectedLocations() }
        guard let id = smbTabs.first(where: { $0.value === owner })?.key else { return }
        defer { completeConnectionReconnect(afterClosing: id) }
        if result.actualExit && result.pipeDrained && result.ownerReleased {
            if owner.uploads != nil || owner.operationNotice?.needsAttention == true {
                let prior = smbClosedUploadNotices[id]
                let notice = owner.operationNotice
                let history = notice?.showsUploadHistory == false ? nil : owner.showUploadHistory ?? prior?.showHistory
                smbClosedUploadNotices[id] = .init(message: notice?.needsAttention == true ? notice!.message
                    : "SMB connection closed." + (history == nil ? "" : " Upload outcomes remain available."),
                    showHistory: history)
            }
            smbTabs.removeValue(forKey: id)
            if activeID == id {
                loadSMBLocation(owner.root)
                if (!result.socketAndCatalogDrained || result.temporaryCatalogRemoved == false), owner.operationNotice?.needsAttention != true {
                    status.stringValue = "Connection closed · temporary browsing data needs review in Connection Storage"
                }
            }
        } else if activeID == id {
            owner.rows.disconnected("Connection closure could not be verified. Its local work and data remain protected.")
            status.stringValue = "SMB closure needs attention"
        }
    }
    func recordClosedSMBUpload(_ tab: UUID, message: String, showHistory: RemoteUploadHistoryAction?) {
        guard tabs.contains(where: { $0.id == tab }), smbTabs[tab] == nil else { return }
        smbClosedUploadNotices[tab] = .init(message: message, showHistory: showHistory)
        if activeID == tab, case .smb(let value) = location { loadSMBLocation(value) }
    }
    func smbRejectsLocalAction(_ action: Selector?) -> Bool {
        [#selector(focusLocation(_:)), #selector(toggleLocationEditing(_:)), #selector(focusFilter(_:)), #selector(selectAllBrowserFiles(_:)),
         #selector(copyPath(_:)), #selector(copyFileURLs(_:)), #selector(cutFileURLs(_:)), #selector(pasteFileURLs(_:)),
         #selector(pasteWithOptions(_:)), #selector(moveCopiedFiles(_:)), #selector(pasteIntoSelection(_:)),
         #selector(moveToOtherPane(_:)),
         #selector(uploadToSFTPPane(_:)),
         #selector(createFolder(_:)), #selector(newFolderWithSelection(_:)), #selector(renameSelection(_:)), #selector(trashSelection(_:)), #selector(duplicateSelection(_:)),
         #selector(showProperties(_:)), #selector(revealInFinder(_:)), #selector(showQuickLook(_:)), #selector(openWithSelection(_:)),
         #selector(shareSelection(_:)), #selector(sendViaAirDrop(_:)), #selector(browseZIP(_:)),
         #selector(extractArchive(_:)), #selector(extractArchiveDirect(_:)), #selector(createZIP(_:)), #selector(compressSelection(_:)),
         #selector(batchRenameSelection(_:)), #selector(openSelectionInNewTab(_:)), #selector(changeSort(_:)), #selector(toggleAscending(_:)), #selector(changeViewMode(_:))]
            .contains { $0 == action }
    }
}
