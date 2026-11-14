import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

@MainActor enum RemoteTextViewFeature {
    #if DEBUG
    static var qualifying = false
    static var qualifyingSMB = false
    #endif
    // Private SMB text reads have their own acceptance. This never enables
    // binary Download or an existing-file Save transaction.
    static var smbAvailable: Bool {
        #if DEBUG
        if qualifyingSMB { return true }
        #endif
        return false
    }
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.routedEditor)
    }
}

/// Explicit, bounded current-server snapshots. A viewer holds no remote write
/// token or generic download/publication handle; pending reads own their drain.
@MainActor final class ApplicationRemoteTextViews {
    static let shared = ApplicationRemoteTextViews()
    private struct Key: Equatable {
        let connection: UUID, generation: UUID, observation: UInt64
        let protocolKind: ExplorerConnectionProtocol
    }
    /// Two actual adapters share the viewer lifetime, not their file authority.
    @MainActor private enum Source {
        case sftp(SFTPTabController, SFTPDownloadSelection, SFTPTextReadStorage)
        case smb(SMBTabController, SMBDownloadSelection, SMBTextReadStorage)
        var key: Key {
            switch self {
            case .sftp(let owner, let selected, _):
                .init(connection: owner.connectionID, generation: selected.generation,
                    observation: selected.row.observation, protocolKind: .sftp)
            case .smb(let owner, let selected, _):
                .init(connection: owner.connectionID, generation: selected.snapshot.readID,
                    observation: UInt64(selected.observation.id), protocolKind: .smb)
            }
        }
        var name: String {
            switch self { case .sftp(_, let selected, _): selected.row.entry.name.displayName
            case .smb(_, let selected, _): selected.observation.name.displayName }
        }
        var isConnected: Bool {
            switch self { case .sftp(let owner, _, _): !owner.isClosing && owner.session.latest.failure == nil
            case .smb(let owner, _, _): !owner.isClosing && owner.session.latest.failure == nil }
        }
        func isCurrent(in browser: BrowserViewController) -> Bool {
            switch self { case .sftp(let owner, _, _): browser.sftpTabs[browser.activeID] === owner
            case .smb(let owner, _, _): browser.smbTabs[browser.activeID] === owner }
        }
        func location(captured: Date) -> EditorLocationContext? {
            switch self {
            case .sftp(let owner, let selected, _):
                guard case .sftp(let location) = owner.currentBrowserLocation,
                      let directory = owner.navigationDirectory(location) else { return nil }
                let path = (directory.root == .home ? "~/" : "/")
                    + (directory.components + [selected.row.entry.name]).map(\.displayName).joined(separator: "/")
                return .remoteSnapshot(server: owner.root.displayHint, path: path, captured: captured)
            case .smb(let owner, let selected, _):
                guard case .smb(let location) = owner.currentBrowserLocation,
                      let directory = owner.navigationComponents(location) else { return nil }
                return .remoteSnapshot(server: owner.root.displayHint,
                    path: "/" + (directory + [selected.observation.name]).map(\.displayName).joined(separator: "/"), captured: captured)
            }
        }
        func open() async throws -> Lease {
            switch self { case .sftp(let owner, let selected, let storage):
                .sftp(try await owner.session.openText(selected: selected, storage: storage))
            case .smb(let owner, let selected, let storage):
                .smb(try await owner.session.openText(selected: selected, storage: storage)) }
        }
    }
    private enum Lease: Sendable {
        case sftp(SFTPTextReadLease), smb(SMBTextReadLease)
        func read() async throws -> TextDocumentValue {
            switch self { case .sftp(let value): try await value.read()
            case .smb(let value): try await value.read() }
        }
        func close() async -> Bool {
            switch self { case .sftp(let value):
                if case .retainedForReview = await value.closeForViewer() { return true }
            case .smb(let value):
                if case .retainedForReview = await value.closeForViewer() { return true }
            }
            return false
        }
    }
    private struct Entry { let key: Key; let document: RemoteTextSnapshotController }
    private var documents: [UUID: Entry] = [:]
    private var pending: [UUID: (key: Key, task: Task<Void, Never>)] = [:]
    private var terminating = false
    var reservationCount: Int { documents.count + pending.count }
    var hasManagedWork: Bool { reservationCount != 0 }

    private func source(from browser: BrowserViewController) -> Source? {
        guard !terminating, !browser.isBrowserSuspended, browser.hasFileCommandFocus,
              browser.view.window?.attachedSheet == nil,
              !(browser.view.window?.firstResponder is NSTextView) else { return nil }
        switch browser.location {
        case .sftp:
            guard RemoteTextViewFeature.available, let owner = browser.sftpTabs[browser.activeID],
                  !owner.isClosing, owner.session.latest.failure == nil, owner.session.allowsTextRead,
                  ApplicationRemoteTextEditors.shared.permitsSnapshotRead(on: owner.connectionID),
                  let storage = owner.textReads, let selected = owner.sealedEditorSelection else { return nil }
            return .sftp(owner, selected, storage)
        case .smb:
            guard RemoteTextViewFeature.smbAvailable, let owner = browser.smbTabs[browser.activeID],
                  !owner.isClosing, owner.session.latest.failure == nil, owner.session.allowsTextRead,
                  ApplicationRemoteTextEditors.shared.permitsSnapshotRead(on: owner.connectionID),
                  let storage = owner.textReads, let selected = owner.selectedTextRead else { return nil }
            return .smb(owner, selected, storage)
        default: return nil
        }
    }
    func canOpen(from browser: BrowserViewController) -> Bool { source(from: browser) != nil }
    func open(from browser: BrowserViewController, visible: Bool = true) {
        guard let source = source(from: browser) else { return }
        let key = source.key
        if let existing = documents.values.first(where: { $0.key == key }) {
            existing.document.show(visible: visible); return
        }
        guard !pending.values.contains(where: { $0.key == key }) else { return }
        guard reservationCount < 2,
              ApplicationRemoteTextEditors.shared.allTextReservationCount
                + ApplicationLocalTextEditors.shared.documentReservationCount < 4 else {
            browser.status.stringValue = "Close another text window before opening this snapshot."; return
        }
        let ticket = UUID(), settings = browser.settings
        let context = source.location(captured: Date())
        ApplicationDiagnostics.shared.event(.fileOperation, .requested, trace: ticket, context: .init(.remoteEditorOpen))
        let task = Task { [self, source, browser] in
            var inspection: UUID?, lease: Lease?, privateCopyRetained = false
            defer {
                pending.removeValue(forKey: ticket)
                if let inspection { ApplicationOperationCoordinator.shared.finishInspection(inspection) }
            }
            do {
                guard !Task.isCancelled, !terminating, source.isConnected,
                      ApplicationRemoteTextEditors.shared.permitsSnapshotRead(on: key.connection),
                      let token = ApplicationOperationCoordinator.shared.beginInspection() else { throw CancellationError() }
                inspection = token
                ApplicationDiagnostics.shared.event(.fileOperation, .reading, trace: ticket, context: .init(.remoteEditorOpen))
                let read = try await source.open(); lease = read
                let contents = try await read.read()
                let retained = await read.close(); lease = nil
                privateCopyRetained = retained
                guard !Task.isCancelled, !terminating, source.isConnected,
                      ApplicationRemoteTextEditors.shared.permitsSnapshotRead(on: key.connection),
                      !browser.isBrowserSuspended, browser.view.window != nil else { throw CancellationError() }
                let document = RemoteTextSnapshotController(contents: contents, name: source.name,
                    connection: key.connection, location: context, settings: settings, retainedCopy: retained, protocolKind: key.protocolKind)
                document.didClose = { [weak self] id in self?.documents.removeValue(forKey: id) }
                documents[document.id] = .init(key: key, document: document)
                document.show(visible: visible)
                if source.isCurrent(in: browser) {
                    browser.status.stringValue = retained
                        ? "Read-only snapshot opened. Temporary text data was kept because cleanup could not be confirmed."
                        : "Read-only snapshot opened. The server file is unchanged."
                }
                ApplicationDiagnostics.shared.event(.fileOperation, .completed, trace: ticket,
                    context: .init(.remoteEditorOpen), relatedTrace: document.id)
            } catch {
                if let lease, await lease.close() { privateCopyRetained = true }
                if error as? SMBTextFailure == .reviewRequired { privateCopyRetained = true }
                let cancelled = Task.isCancelled || error is CancellationError
                ApplicationDiagnostics.shared.event(.fileOperation, cancelled ? .cancelled : .failed,
                    trace: ticket, error: DiagnosticErrors.project(error), context: .init(.remoteEditorOpen),
                    causes: DiagnosticErrors.causes(error))
                if !browser.isBrowserSuspended, source.isConnected, source.isCurrent(in: browser) {
                    browser.status.stringValue = privateCopyRetained
                        ? "This snapshot could not be opened. Temporary text data was kept because cleanup could not be confirmed."
                        : cancelled ? "Opening cancelled. The server file is unchanged."
                        : "This file could not be opened as text. The server file is unchanged."
                }
            }
        }
        pending[ticket] = (key, task)
    }
    func connectionWillClose(_ connection: UUID) {
        for item in pending.values where item.key.connection == connection { item.task.cancel() }
        for entry in documents.values where entry.key.connection == connection { entry.document.connectionClosed() }
    }
    func cancelPendingReadsAndDrain(on connection: UUID) async {
        let tasks = pending.values.filter { $0.key.connection == connection }.map(\.task)
        tasks.forEach { $0.cancel() }; for task in tasks { await task.value }
    }
    func prepareForTermination() async -> Bool {
        terminating = true
        let tasks = pending.values.map(\.task); tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        for entry in Array(documents.values) { await entry.document.closeAndDrain() }
        return !hasManagedWork
    }
    func resumeAfterCancelledTermination() { terminating = false }
}
