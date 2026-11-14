import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

struct ConnectionReconnectIntent {
    let tab: UUID, visit: UUID
    let bookmark: WorkspaceConnectionBookmark
}

@MainActor extension BrowserViewController {
    func updateConnectionStatusIndicator() {
        guard isViewLoaded, !isBrowserSuspended else { return }
        guard isRemoteLocation else {
            connectionIndicator.configure(nil, detail: "", motion: settings.motion); return
        }
        let bookmark = tabs[activeIndex].connectionBookmark
        let progress = bookmark.flatMap { savedServerLocations.connectingPhase(for: $0) }
        let phase: ConnectionIndicatorPhase
        let protocolName: String
        if isSFTPLocation {
            protocolName = "SFTP"
            if progress != nil || sftpTabs[activeID]?.isClosing == true { phase = .connecting }
            else if let owner = sftpTabs[activeID] {
                phase = owner.session.latest.failure == .storage ? .attention
                    : owner.session.latest.failure == nil ? .connected : .disconnected
            } else { phase = .disconnected }
        } else {
            protocolName = "SMB"
            if progress != nil || smbTabs[activeID]?.isClosing == true { phase = .connecting }
            else if let owner = smbTabs[activeID] {
                let failure = owner.session.latest.failure
                phase = failure == .storage ? .attention : failure == nil || failure == .stopped ? .connected : .disconnected
            } else { phase = .disconnected }
        }
        var lines = ["\(protocolName) · \(progress ?? phase.title)"]
        if let owner = sftpTabs[activeID] {
            let update = owner.session.latest
            lines.append(owner.savedConnection?.title ?? owner.root.displayHint)
            lines.append("Folder: " + owner.currentBrowserLocation.displayName)
            lines.append("Security: SSH encrypted")
            lines.append("Access: " + (owner.session.allowsFreshUploads ? "Read and write" : "Read only"))
            if let count = update.snapshot?.count { lines.append("Items: " + count.formatted()) }
            lines += directoryTimingDetails(update.lastDirectoryReadMilliseconds,
                at: update.lastDirectoryResponseAt, title: "Latest directory read")
            lines.append("Connected: " + connectionObservationDate(owner.connectedAt))
            if owner.session.allowsInPlaceEditing { lines.append("Text editing with checked Save") }
            if owner.remoteActions != nil { lines.append("Rename and permanent Delete available") }
        } else if let owner = smbTabs[activeID] {
            lines.append(owner.savedConnection?.title ?? owner.root.displayHint)
            lines.append("Folder: " + owner.currentBrowserLocation.displayName)
            let update = owner.session.latest
            lines.append("Security: " + (update.security == .encrypted ? "SMB 3.1.1 encrypted" : update.security == .signed ? "SMB 3.1.1 signed" : "Not established"))
            lines.append("Access: " + (owner.uploads != nil ? "Read and write" : "Read only"))
            if let count = update.snapshot?.count { lines.append("Items: " + count.formatted()) }
            lines += directoryTimingDetails(owner.lastDirectoryListingMilliseconds,
                at: owner.lastDirectoryListingAt, title: "Latest complete listing")
            lines.append("Connected: " + connectionObservationDate(owner.connectedAt))
        } else if let bookmark { lines.append(bookmark.title) }
        if phase == .disconnected {
            lines.append(bookmark == nil ? "Click to sign in to this server." : "Click to reconnect using saved sign-in details.")
            lines.append("Interrupted transfers are kept for review.")
        } else if phase == .attention {
            lines.append("Status: " + status.stringValue)
        }
        connectionIndicator.configure(phase, detail: String(lines.joined(separator: "\n").prefix(2048)), motion: settings.motion)
    }

    private func directoryTimingDetails(_ milliseconds: Double?, at date: Date?, title: String) -> [String] {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0, let date else { return [] }
        let value = milliseconds < 1 ? "<1" : milliseconds.formatted(.number.precision(.fractionLength(0)))
        return ["\(title): \(value) ms", "Includes server response and local processing; not a network ping.",
            "Measured at " + connectionObservationDate(date, time: .standard)]
    }

    private func connectionObservationDate(_ date: Date, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: time)
    }

    @objc func reconnectFromConnectionStatus(_ sender: Any?) {
        guard !isBrowserSuspended, isActiveCommandPane, isRemoteLocation,
              view.window?.attachedSheet == nil else { return }
        guard let bookmark = tabs[activeIndex].connectionBookmark else { showSMBConnections(sender); return }
        if let target = WorkspaceReconnectTarget(browser: self), target.isCurrent {
            _ = startSavedServerConnection(bookmark, reconnect: target, allowsFormFallback: false)
            updateConnectionStatusIndicator(); return
        }
        guard commandEnabled(#selector(disconnectCurrentConnection(_:))) else { return }
        reconnectAfterDisconnect = .init(tab: activeID, visit: sessionID, bookmark: bookmark)
        disconnectCurrentConnection(sender)
        updateConnectionStatusIndicator()
    }
    func completeConnectionReconnect(afterClosing tab: UUID) {
        guard let intent = reconnectAfterDisconnect, intent.tab == tab else { return }
        reconnectAfterDisconnect = nil
        guard activeID == intent.tab, sessionID == intent.visit,
              tabs[activeIndex].connectionBookmark == intent.bookmark,
              let target = WorkspaceReconnectTarget(browser: self), target.isCurrent else { return }
        _ = startSavedServerConnection(intent.bookmark, reconnect: target, allowsFormFallback: false)
    }
}
