import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor extension BrowserViewController {
    func installSFTPTab(_ owner: SFTPTabController, reconnect: WorkspaceReconnectTarget? = nil) {
        if let reconnect {
            guard reconnect.isCurrent, let index = tabs.firstIndex(where: { $0.id == reconnect.tabID }),
                  let parts = try? WorkspaceConnectionBinding.sftpComponents(reconnect.bookmark),
                  let location = try? owner.directoryLocation(components: parts, relativeToHome: reconnect.bookmark.relativeToHome),
                  (try? tabs[index].replaceDisconnectedConnection(with: .sftp(location), bookmark: owner.bookmark(for: location))) != nil else {
                _ = owner.close(); status.stringValue = WorkspaceReconnectFailure.stale.message; return
            }
            sftpTabs[reconnect.tabID] = owner; sftpClosedUploadNotices.removeValue(forKey: reconnect.tabID); activeID = reconnect.tabID
            loadLocation(animatingTab: true); focusBrowserContent(); return
        }
        saveViewState(); let initial = (try? owner.directoryLocation(components: owner.initialComponents)) ?? owner.root
        let tab = BrowserTab(location: .sftp(initial)); sftpTabs[tab.id] = owner; tabs.append(tab); activeID = tab.id
        loadLocation(animatingTab: true); focusBrowserContent()
    }
    func loadSFTPLocation(_ value: SFTPBrowserLocation, refresh: Bool = false) {
        guard isViewLoaded else { return }; overlay.isHidden = true; loadingIndicator.stopAnimation(nil)
        if let owner = sftpTabs[activeID], owner.connectionID == value.connectionID {
            for view in sftpHost.subviews where view !== owner.rows { view.removeFromSuperview() }
            if owner.rows.superview !== sftpHost { owner.rows.removeFromSuperview(); pin(owner.rows, inside: sftpHost) }
            owner.attach(to: self, location: value, refresh: refresh)
        } else {
            if let bookmark = tabs[activeIndex].connectionBookmark, bookmark.isSFTP {
                showSavedNetworkLocation(bookmark, in: sftpHost, uploadNotice: sftpClosedUploadNotices[activeID]); renderSFTPStatus(nil); return
            }
            sftpHost.subviews.forEach { $0.removeFromSuperview() }
            let notice = sftpClosedUploadNotices[activeID]
            let text = notice.map { $0.message + "\n\nThis connection is closed. Reconnect explicitly to browse again." }
                ?? "This SFTP connection is closed. Connect explicitly to browse again. Saved layouts do not reopen connections."
            showClosedNetworkLocation(in: sftpHost, message: text, notice: notice,
                historyAction: #selector(showClosedSFTPUploadHistory(_:)), historyTitle: "Connection Activity…", historyIdentifier: "sftp-closed-upload-history")
        }
        renderSFTPStatus(sftpTabs[activeID]?.session.latest)
    }
    @discardableResult func updateSFTPBreadcrumbs() -> Bool {
        guard case .sftp(let value) = location else { return false }
        let parts = sftpTabs[activeID]?.breadcrumbs(for: value) ?? [(value.displayHint, .sftp(value))]; breadcrumbLocations = parts.map(\.1)
        let items = parts.enumerated().map { index, part in
            let item = NSPathControlItem(); item.title = part.0
            if index == 0, let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "SFTP server")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                let icon = symbol.copy() as! NSImage; icon.size = NSSize(width: 16, height: 16); icon.isTemplate = true; item.image = icon
            }; return item
        }
        pathControl.setBreadcrumbs(items: items, locations: breadcrumbLocations); pathControl.placeholderString = nil
        pathControl.toolTip = "Encrypted SFTP · Metadata browsing. Click an ancestor to navigate. Explicit transfer capabilities are shown in the status bar."; return true
    }
    func renderSFTPStatus(_ update: SFTPBrowserUpdate?) {
        defer { updateConnectionStatusIndicator() }
        guard isSFTPLocation else { return }; overlay.isHidden = true
        if sftpTabs[activeID] == nil, tabs[activeIndex].connectionBookmark?.isSFTP == true {
            loadingIndicator.stopAnimation(nil)
            status.stringValue = sftpClosedUploadNotices[activeID]?.message ?? "Saved SFTP location · Not connected"
            status.toolTip = sftpClosedUploadNotices[activeID]?.message
                ?? "Open this saved server to connect. Saved layouts do not reconnect or resume transfers automatically."
            validateNavigationButtons(); return
        }
        if let rows = sftpTabs[activeID]?.rows, rows.cache.retainedCount > 0 || rows.cache.snapshot?.state == .complete && rows.cache.snapshot?.count == 0 { updateCanvasTransition() }
        if sftpTabs[activeID]?.isClosing == true {
            loadingIndicator.stopAnimation(nil)
            status.stringValue = sftpTabs[activeID]?.operationNotice?.footerMessage(isIdle: false, connectionHasProblem: true)
                ?? "Closing SFTP connection… Waiting for its actual worker and catalog drain."
            status.toolTip = status.stringValue
            validateNavigationButtons(); return
        }
        if update?.reading == true, update?.failure == nil { loadingIndicator.startAnimation(nil) } else { loadingIndicator.stopAnimation(nil) }
        let state: String
        if let rejected = update?.directoryRejection {
            state = rejected == .denied ? "Folder access denied · connection is open" : rejected == .missing ? "Folder not found · connection is open" : "Folder unavailable · connection is open"
        }
        else if let failure = update?.failure { state = failure == .storage ? "Browsing storage is unavailable · showing previously found items" : "Connection unavailable · connect again to continue" }
        else if let snapshot = update?.snapshot {
            state = "\(snapshot.count.formatted()) items" + (update?.paused == true ? update?.reading == true ? " · Pausing after current request…" : " · Reading paused" : snapshot.state == .loading ? " · Observed so far · Reading…" : "")
        } else { state = sftpTabs[activeID] == nil ? "Connection closed" : "Preparing directory…" }
        let uploads = sftpTabs[activeID]?.session.allowsFreshUploads == true
        let folderUploads = sftpTabs[activeID]?.session.allowsFreshFolderUploads == true
        let editing = sftpTabs[activeID]?.session.allowsInPlaceEditing == true
        let viewing = sftpTabs[activeID]?.textReads != nil
        let editorsBusy = sftpTabs[activeID]?.editorCapacityLimited == true
        let fileActions = sftpTabs[activeID]?.remoteActions != nil
        status.stringValue = "SFTP · \(uploads ? "Write access" : "Read only") · \(state)"
        if update?.failure == nil, update?.directoryRejection == nil, let find = sftpTabs[activeID]?.rows.findStatusText {
            status.stringValue = "SFTP · \(uploads ? "Write access" : "Read only") · " + find
        }
        if let notice = sftpTabs[activeID]?.operationNotice?.footerMessage(isIdle: update?.reading == false,
            connectionHasProblem: update?.failure != nil || update?.directoryRejection != nil) { status.stringValue = notice }
        if sftpTabs[activeID] == nil, let notice = sftpClosedUploadNotices[activeID] { status.stringValue = notice.message }
        status.toolTip = sftpTabs[activeID]?.downloads == nil
            ? "Exact remote names and optional metadata. " + (viewing
                ? "Open supported text as a read-only snapshot. Binary downloads, uploads and remote Trash are unavailable in this connection."
                : "File preview, transfers and remote Trash are unavailable in this connection.")
            : "Browsing reads metadata only. Use Download for one selected regular file up to 1 GiB. The remote file stays unchanged; links and remote Trash are unavailable."
        if uploads { status.toolTip = "Browsing reads metadata only. Upload File Here sends a selected local file. Uploads create new items and preserve existing names. Remote Trash is unavailable." }
        if sftpTabs[activeID]?.session.allowsRequestedFolderDownloads == true {
            status.toolTip = "Browsing reads metadata only. Download one selected file or review a folder before receiving it. The complete new copy is checked before publication; existing items and remote originals are preserved. Links, replacement, folder uploads and remote Trash are unavailable."
        }
        if folderUploads { status.toolTip = "Browsing reads metadata only. Upload File Here or Upload Folder Here creates a new copy and preserves existing names; interrupted folders may need review. Remote Trash is unavailable." }
        if editing {
            status.toolTip = (status.toolTip ?? "") + " Open supported text files in Traverse, or choose Edit in Traverse. Save checks for changes made on the server."
        } else if editorsBusy {
            status.toolTip = (status.toolTip ?? "") + " Editing was not enabled when this connection opened. Two connections can edit text at once; close one of those and reconnect here to edit text."
        }
        if viewing && !editing && sftpTabs[activeID]?.downloads != nil {
            status.toolTip = (status.toolTip ?? "") + " Open supported text as a read-only snapshot; it cannot change the server file."
        }
        if fileActions {
            let deletion = sftpTabs[activeID]?.allowsEmptyDirectoryDelete == true ? "a file or empty folder" : "a file"
            let rename = sftpTabs[activeID]?.allowsDirectoryRename == true ? "file/folder Rename" : "file Rename"
            status.toolTip = (status.toolTip ?? "") + " New Folder, \(rename) and permanent Delete for \(deletion) are available in the File and contextual menus. Delete asks once; it has no remote Trash or Undo."
        }
        if sftpTabs[activeID] != nil, update?.failure == nil, update?.directoryRejection == nil,
           let reason = RemoteDownloadPublicationFeature.versionHoldExplanation(featureAvailable: SFTPDownloadFeature.available) {
            status.toolTip = (status.toolTip ?? "") + " " + reason
        }
        if let message = sftpTabs[activeID]?.operationNotice?.footerMessage(isIdle: update?.reading == false,
            connectionHasProblem: update?.failure != nil || update?.directoryRejection != nil) {
            status.toolTip = message
        } else if sftpTabs[activeID] == nil, let notice = sftpClosedUploadNotices[activeID] { status.toolTip = notice.message }
        validateNavigationButtons()
    }
    func renderCurrentSFTPStatus() { renderSFTPStatus(sftpTabs[activeID]?.session.latest) }
    func recordClosedSFTPUpload(_ tab: UUID, message: String, showHistory: SFTPUploadHistoryAction?) {
        guard tabs.contains(where: { $0.id == tab }), sftpTabs[tab] == nil else { return }
        sftpClosedUploadNotices[tab] = .init(message: message, showHistory: showHistory)
        if activeID == tab, case .sftp(let value) = location { loadSFTPLocation(value) }
    }
    @objc func showClosedSFTPUploadHistory(_ sender: Any?) { sftpClosedUploadNotices[activeID]?.showHistory?(settings, view.window) }
    @objc func disconnectSFTPConnection(_ sender: Any?) {
        guard let owner = sftpTabs[activeID], !owner.isClosing else { return }
        Task { [self, owner] in
            guard await ApplicationRemoteTextEditors.shared.prepareForDisconnect(owner), !owner.isClosing else { return }
            owner.close(); owner.rows.disconnected("Closing connection… Waiting for its actual local work to finish.")
            renderSFTPStatus(owner.session.latest)
        }
    }
    func finishSFTPDisconnect(_ owner: SFTPTabController, result: SFTPWorkerClose) {
        defer { refreshConnectedLocations() }
        guard let id = sftpTabs.first(where: { $0.value === owner })?.key else { return }
        defer { completeConnectionReconnect(afterClosing: id) }
        if result.localResourcesEnded {
            if let notice = owner.operationNotice, notice.needsAttention {
                sftpClosedUploadNotices[id] = .init(message: notice.message,
                    showHistory: notice.showsUploadHistory ? owner.showUploadHistory : nil)
            }
            sftpTabs.removeValue(forKey: id)
            if activeID == id {
                loadSFTPLocation(owner.root)
                if result.temporaryStoreRemoved == false, owner.operationNotice?.needsAttention != true {
                    status.stringValue = "SFTP closed · temporary browsing data needs explicit review"
                }
            }
        } else if activeID == id { owner.rows.disconnected("Connection closure is uncertain. Its local work and data remain protected."); status.stringValue = "SFTP closure needs attention" }
    }
}
