import AppKit
import LocalStorage

@MainActor
extension BrowserViewController {
    func cancelDirectoryObservation() {
        directoryObservation?.cancel()
        directoryObservation = nil
        directoryRefreshTask?.cancel()
        directoryRefreshTask = nil
        directoryRefreshPending = false
    }

    func startDirectoryObservation(for url: URL, retaining lease: FolderAccessLease?, token: UUID) async {
        guard settings.autoRefreshFolders, sessionID == token, !Task.isCancelled else { return }
        let observation = directoryMonitor.observe(url, retaining: lease) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == token, self.settings.autoRefreshFolders else { return }
                switch event {
                case .changed, .invalidated:
                    self.directoryRefreshPending = true
                    self.consumePendingDirectoryRefresh()
                case .unavailable:
                    // Enumeration supplies the truthful access/error state;
                    // unavailable monitoring never prevents manual refresh.
                    break
                }
            }
        }
        directoryObservation = observation
        _ = await observation.waitUntilStarted()
        if sessionID != token || Task.isCancelled {
            observation.cancel()
            if directoryObservation === observation { directoryObservation = nil }
        }
    }

    func consumePendingDirectoryRefresh() {
        guard directoryRefreshPending, settings.autoRefreshFolders, location.directoryURL != nil else { return }
        directoryRefreshTask?.cancel()
        let token = sessionID
        directoryRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.sessionID == token, self.directoryRefreshPending,
                  !self.isLoading, self.orderingTask == nil, self.operationTask == nil, self.operationPreparationTask == nil,
                  self.pathField.currentEditor() == nil, self.folderFilter.displayedField.currentEditor() == nil,
                  self.metadataSearch.view.isHidden, !self.folderFilter.hasUnsubmittedDraft else { return }
            self.saveViewState()
            self.loadLocation(preservingVisibleRows: true)
        }
    }

    func updateDirectoryObservationPreference(_ enabled: Bool) {
        if !enabled { cancelDirectoryObservation(); return }
        guard location.directoryURL != nil else { return }
        saveViewState()
        loadLocation(preservingVisibleRows: true)
    }
}
