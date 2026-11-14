import AppKit
import Combine
import Darwin
import ExplorerCore
import LocalStorage

/// This diagnosis describes evidence from an error, never a TCC authorization query.
struct FolderAccessDiagnostic: Sendable, Equatable {
    enum Kind: String, Sendable {
        case permissionOrACL, policyOrOtherRestriction, deniedCauseUnknown
        case missing, notFolder, unavailable, staleBookmark, cancelled, other
    }
    let kind: Kind
    let message: String

    static func describe(_ error: Error) -> Self {
        if error is CancellationError {
            return Self(kind: .cancelled, message: "The request was cancelled.")
        }
        if let local = error as? LocalStorageError {
            switch local {
            case .accessDenied:
                // LocalStorage currently combines EACCES and EPERM. Do not
                // invent the original cause or equate this observation with TCC.
                return Self(kind: .deniedCauseUnknown, message: "Access was denied. The cause could be folder permissions or a macOS privacy restriction.")
            case .notFound: return missing
            case .notDirectory: return notFolder
            case .unavailable: return unavailable
            case .busy: return Self(kind: .other, message: local.userMessage)
            case .other: return Self(kind: .other, message: "The folder could not be read.")
            }
        }
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain, let code = Int32(exactly: current.code) {
                switch code {
                case EACCES:
                    return Self(kind: .permissionOrACL, message: "Folder permissions or an access control list denied access.")
                case EPERM:
                    return Self(kind: .policyOrOtherRestriction, message: "A system policy or another restriction denied access. The error does not identify a specific privacy permission.")
                case ENOENT: return missing
                case ENOTDIR: return notFolder
                case ENODEV, ENXIO, ESTALE, ENOTCONN, ETIMEDOUT, EIO: return unavailable
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            switch cocoa.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return missing
            case NSFileReadNoPermissionError:
                return Self(kind: .deniedCauseUnknown, message: "Access was denied. The error does not identify whether permissions or a macOS privacy restriction caused it.")
            default: break
            }
        }
        return Self(kind: .other, message: "The request could not be completed. You can try choosing the folder again.")
    }

    static let missing = Self(kind: .missing, message: "The folder could not be found. It may have moved or its volume may be unavailable.")
    static let notFolder = Self(kind: .notFolder, message: "This location is not a folder.")
    static let unavailable = Self(kind: .unavailable, message: "The location is unavailable or could not be read. Check its connection and try again.")
    static let stale = Self(kind: .staleBookmark, message: "The saved folder reference needs renewal. Choose the folder again to remember it.")
}

struct FolderBookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

/// Narrow injectable boundary for controlled tests. No permissions are inferred
/// from a successful bookmark resolution or from startAccess returning false.
protocol FolderAccessBackend: Sendable {
    func startAccess(to url: URL) -> Bool
    func stopAccess(to url: URL)
    func bookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution
}

struct SystemFolderAccessBackend: FolderAccessBackend {
    let policy: FileAccessPolicy
    init(policy: FileAccessPolicy = .selectedFolders) { self.policy = policy }
    func startAccess(to url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccess(to url: URL) { url.stopAccessingSecurityScopedResource() }

    func bookmark(for url: URL) throws -> Data {
        // Remember the scope macOS actually issued for this explicit selection.
        // Do not narrow it to read-only now that the app supports authorized writes.
        // A bookmark still cannot override folder permissions or privacy policy.
        try url.bookmarkData(options: policy == .selectedFolders ? [.withSecurityScope] : [.withoutImplicitSecurityScope],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: policy == .selectedFolders ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return FolderBookmarkResolution(url: url, isStale: stale)
    }
}

/// Retain this exact object in the actual filesystem worker, including its
/// cancellation/unwind path. Releasing a UI stream consumer is not worker drain.
/// URL and backend are immutable; the lock makes close/deinit idempotent across
/// tasks and worker threads. Each successful start receives exactly one stop.
final class FolderAccessLease: @unchecked Sendable {
    let url: URL
    let securityScopeStarted: Bool
    private let backend: any FolderAccessBackend
    private let lock = NSLock()
    private var closed = false

    init(url: URL, backend: any FolderAccessBackend) {
        self.url = url // Preserve the scope-bearing URL; never rebuild from its path.
        self.backend = backend
        securityScopeStarted = backend.startAccess(to: url)
    }

    /// Call only once all work using this lease has completed. Usually let the
    /// final worker reference deinitialize it instead of closing from the UI.
    func close() {
        lock.lock()
        let shouldStop = !closed && securityScopeStarted
        closed = true
        lock.unlock()
        if shouldStop { backend.stopAccess(to: url) }
    }

    deinit { close() }
}

struct FolderAccessSelection: Identifiable, Sendable {
    let id: UUID
    let url: URL
}

struct FolderAccessChoice: Sendable {
    enum Remembering: Sendable {
        case notRequested, saved, failed(FolderAccessDiagnostic)
    }
    let selection: FolderAccessSelection
    let lease: FolderAccessLease
    let remembering: Remembering
}

struct FolderAccessRestoreResult: Identifiable, Sendable {
    enum State: Sendable {
        /// The reference resolved; directory existence and readability have NOT
        /// been probed. The explicit navigation task supplies that evidence.
        case resolvedUnverified, needsRenewal, unavailable(FolderAccessDiagnostic)
    }
    let id: UUID
    let url: URL?
    let state: State
}

struct FolderAccessLocation: Identifiable, Sendable {
    enum State: Sendable { case session, remembered, needsReselection, unavailable }
    let id: UUID
    let url: URL?
    let state: State
    var isRemembered: Bool { if case .session = state { return false }; return true }
    var title: String { url.map { $0.path == "/" ? "Macintosh HD" : $0.lastPathComponent } ?? "Unavailable saved location" }
    var status: String {
        switch state {
        case .session: "This session"
        case .remembered: "Remembered on this Mac"
        case .needsReselection: "Choose again to renew"
        case .unavailable: "Saved location unavailable"
        }
    }
}

/// Immutable retained-grant preparation for native tracking loops. Selecting
/// roots uses only the controller's cached grants; scope work stays off-main.
/// Publication must check the originating controller's generation afterward.
/// App-session grant identity, independent of cancellation of a chooser.
/// It is a matching fence, never a grant or proof of native readability.
struct FolderAnalysisAccessIdentity: Equatable, Sendable {
    let controller: UUID
    let revision: UUID
    let selectedGrant: UUID?
}

struct FolderAccessPreparation: Sendable {
    fileprivate let generation: UUID
    fileprivate let roots: [URL]
    fileprivate let backend: any FolderAccessBackend

    func acquire() throws -> [FolderAccessLease] {
        try roots.map { url in
            try Task.checkCancellation()
            return FolderAccessLease(url: url, backend: backend)
        }
    }
}

/// Main-actor command orchestration only. Blocking bookmark/storage work runs
/// through a serial worker; no protected folder is probed automatically.
@MainActor
final class FolderAccessController: ObservableObject {
    enum Purpose { case browsing, setup, analysis, fileOperation, undoFileOperation, archiveExport }
    static var requiresAnalysisSelection: Bool {
        TraverseAccessPolicy.requiresFolderSelection
    }
    private let worker = FolderAccessWorker()
    private let backend: any FolderAccessBackend
    private let store: FolderBookmarkStore?
    private var grants: [UUID: FolderAccessSelection] = [:]
    // Metadata only: stale references must never be placed in `grants`.
    // The ID denotes a saved access reference, not a filesystem object or an
    // annotation. Explicit reselection authorizes its current URL occupant.
    private var referenceURLs: [UUID: URL] = [:]
    private var referenceIDs: Set<UUID> = []
    private var restored: [UUID: FolderAccessRestoreResult] = [:]
    @Published private(set) var locations: [FolderAccessLocation] = []
    @Published private(set) var storageIssue: String?
    private var panel: NSOpenPanel?
    #if TRAVERSE_SFTP_EDITOR_QA
    /// Read-only observation of the exact pending Undo request in a counted
    /// signed QA visit. It cannot select a folder or grant access.
    private(set) var pendingUndoDirectoryForQualification: URL?
    #endif
    private var generation = UUID()
    private let analysisControllerID = UUID()
    private var analysisGrantRevision = UUID()
    #if DEBUG
    var rememberedCommitHookForQualification: (@Sendable () -> Void)?
    #endif

    /// Pass only the app-owned state directory. nil disables all persistence.
    /// Neither initialization nor folder selection without remember writes data.
    init(stateDirectory: URL? = nil, backend: (any FolderAccessBackend)? = nil, policy: FileAccessPolicy? = nil) {
        // Preserve the development reference format; distribution editions have
        // separate state bases and an explicitly bound bookmark policy.
        #if MAC_EXPLORER_DISTRIBUTION
        let selectedPolicy = policy ?? TraverseAccessPolicy.current ?? .selectedFolders
        #else
        let selectedPolicy = policy ?? .selectedFolders
        #endif
        self.backend = backend ?? SystemFolderAccessBackend(policy: selectedPolicy)
        store = stateDirectory.map { FolderBookmarkStore($0, policy: selectedPolicy) }
    }

    func diagnostic(for error: Error) -> FolderAccessDiagnostic { .describe(error) }
    var canRememberFolders: Bool { store != nil }

    /// Explicit OS-delivered folder URL, already freshly checked by the
    /// incoming worker. Keep its original grant; never save a bookmark here.
    func acceptOpenedFolder(_ url:URL, retaining lease:FolderAccessLease) -> Bool {
        guard url.isFileURL, lease.url.absoluteString == url.absoluteString else { return false }
        if grants.values.contains(where: { $0.url.absoluteString == url.absoluteString }) { return true }
        guard grants.count < 128 else { return false }
        let selection = FolderAccessSelection(id:UUID(),url:url)
        grants[selection.id] = selection
        publishLocations()
        return true
    }

    func invalidatePendingRequests() {
        generation = UUID()
        panel?.cancel(nil)
    }

    /// Only call from an explicit Choose Folder action. `remember` must reflect
    /// the user's explicit choice; it is false by default.
    func chooseFolder(in window: NSWindow, initialDirectory: URL? = nil,
                      remember: Bool = false, replacingReference: UUID? = nil,
                      purpose: Purpose = .browsing, requiredDirectory: URL? = nil) async -> FolderAccessChoice? {
        let token = UUID(), trace = ApplicationDiagnostics.shared.workflow(.folderAccess, context: .init(.folderPicker))
        guard panel == nil, !Task.isCancelled else {
            trace.event(Task.isCancelled ? .cancelled : .blocked, context: .init(.folderPicker, flags: panel == nil ? [] : [.waitingForOS]))
            return nil
        }
        if let replacingReference {
            guard remember && referenceIDs.contains(replacingReference) else { trace.event(.blocked, context: .init(.folderPicker)); return nil }
        }
        generation = token
        let picker = NSOpenPanel()
        picker.title = "Choose a Folder"
        picker.prompt = "Choose Folder"
        picker.message = "Choose a folder to browse. Press Shift-Command-G to enter a folder path."
        if purpose != .browsing {
            picker.title = "Grant Folder Access"; picker.prompt = "Grant Folder Access"
            picker.message = purpose == .analysis
                ? "Choose the folder or drive you want to analyze. Traverse checks file names and sizes without changing your files. macOS may restrict some protected folders."
                : "Select a folder or drive to use in Traverse. Nothing will be scanned or changed here; macOS can still restrict protected items."
        }
        var rememberControl: NSButton?
        if purpose == .browsing && replacingReference == nil {
            let control = NSButton(checkboxWithTitle: "Remember folder access on this Mac", target: nil, action: nil)
            control.state = remember && store != nil ? .on : .off
            control.isEnabled = store != nil
            control.toolTip = "Reopen this folder and finish its file operations after restarting Traverse without choosing it again. Manage or forget remembered access in Settings."
            control.setAccessibilityIdentifier("remember-folder-access")
            picker.accessoryView = control; rememberControl = control
        }
        if purpose == .fileOperation || purpose == .undoFileOperation {
            picker.title = "Allow Folder Access"; picker.prompt = "Allow Folder Access"
            picker.message = purpose == .undoFileOperation
                ? "Choose the displayed destination folder to undo this operation. Traverse will check the saved file before changing anything. Cancel leaves it in place."
                : "Choose a containing folder or drive to allow file changes. The source and destination may each need access. No operation will be retried automatically."
            let control = NSButton(checkboxWithTitle: "Remember this selection on this Mac", target: nil, action: nil)
            control.state = remember && store != nil ? .on : .off
            control.isEnabled = store != nil
            control.setAccessibilityIdentifier("operation-remember-folder-access")
            picker.accessoryView = control; rememberControl = control
        }
        if purpose == .archiveExport {
            picker.title = "Allow Archive Export"; picker.prompt = "Allow Export Here"
            picker.message = "Allow Traverse to save the dragged items in this folder. Keep the displayed destination selected. Existing files will not be replaced."
        }
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = false
        picker.resolvesAliases = true
        picker.directoryURL = initialDirectory
        panel = picker
        #if TRAVERSE_SFTP_EDITOR_QA
        if case .undoFileOperation = purpose {
            pendingUndoDirectoryForQualification = requiredDirectory
        } else { pendingUndoDirectoryForQualification = nil }
        defer { pendingUndoDirectoryForQualification = nil }
        #endif
        trace.event(.presenting, context: .init(.folderPicker, flags: [.waitingForOS]))
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                picker.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == token { self?.panel?.cancel(nil) }
            }
        }
        panel = nil
        guard response == .OK, generation == token, !Task.isCancelled else {
            trace.event(.cancelled, context: .init(.folderPicker, flags: Task.isCancelled || generation != token ? [.cancellationRequested] : []))
            return nil
        }
        guard let url = picker.url, url.isFileURL else { trace.event(.blocked, context: .init(.folderPicker)); return nil }
        // A path match only constrains this explicit selection. The operation
        // worker still verifies the recorded parent and file identities. Check
        // before accepting or remembering the URL, preserving its native scope.
        if let requiredDirectory,
           url.standardizedFileURL.pathComponents != requiredDirectory.standardizedFileURL.pathComponents {
            trace.event(.blocked, context: .init(.folderPicker)); return nil
        }
        let save = rememberControl.map { $0.state == .on } ?? remember
        return await acceptChosenFolder(url, remember: save, replacingReference: replacingReference, token: token, trace: trace)
    }

    /// Separate from panel presentation so a controlled backend can exercise
    /// balancing/persistence without showing a panel or opening protected files.
    func acceptChosenFolder(_ url: URL, remember: Bool = false, replacingReference: UUID? = nil) async -> FolderAccessChoice? {
        let trace = ApplicationDiagnostics.shared.workflow(.folderAccess, context: .init(.folderScope))
        guard url.isFileURL, !Task.isCancelled else {
            trace.event(Task.isCancelled ? .cancelled : .blocked, context: .init(.folderScope)); return nil
        }
        if let replacingReference {
            guard remember && referenceIDs.contains(replacingReference) else { trace.event(.blocked, context: .init(.folderScope)); return nil }
        }
        let token = UUID()
        generation = token
        return await acceptChosenFolder(url, remember: remember, replacingReference: replacingReference, token: token, trace: trace)
    }

    private func acceptChosenFolder(_ url: URL, remember: Bool, replacingReference: UUID?, token: UUID, trace: DiagnosticWorkflowBinding) async -> FolderAccessChoice? {
        let backend = backend
        trace.event(.admitted, context: .init(.folderScope, flags: [.selectedScope]))
        do {
            let lease = try await worker.run {
                trace.event(.resolving, context: .init(.folderScope, flags: [.selectedScope]))
                return FolderAccessLease(url: url, backend: backend)
            }
            guard generation == token, !Task.isCancelled else {
                lease.close(); trace.event(.cancelled, context: .init(.folderScope, flags: [.cancellationRequested])); return nil
            }
            trace.event(.retaining, context: .init(.folderScope, flags: lease.securityScopeStarted ? [.retainedScope] : [.selectedScope]))
            // Do not normalize, resolve symlinks, or use path-prefix matching:
            // renewal applies only to the exact resolved reference URL the
            // user explicitly selected. This does not prove object identity.
            let rememberedID = referenceURLs.first { $0.value.absoluteString == url.absoluteString }?.key
            let grantedID = grants.values.first { $0.url.absoluteString == url.absoluteString }?.id
            // Explicit replacement renews a saved access reference, including
            // an unresolved one. It is never an object-identity annotation.
            let selection = FolderAccessSelection(id: replacingReference ?? rememberedID ?? grantedID ?? UUID(), url: url)
            guard grants[selection.id] != nil || grants.count < 128 else {
                lease.close(); trace.event(.blocked, context: .init(.folderAccessPublication)); return nil
            }
            var remembering: FolderAccessChoice.Remembering = .notRequested
            var rememberingError: DiagnosticErrorCode?, rememberingCauses: [DiagnosticErrorCode]?
            if remember {
                if let store {
                    #if DEBUG
                    let commitHook = rememberedCommitHookForQualification
                    #endif
                    do {
                        try await worker.run {
                            // The lease remains alive while bookmark creation is
                            // using its original, scope-bearing URL.
                            trace.event(.committing, context: .init(.folderBookmark))
                            do {
                                let bookmark = try backend.bookmark(for: lease.url)
                                try store.upsert(FolderBookmarkRecord(id: selection.id, bookmark: bookmark))
                                trace.event(.completed, context: .init(.folderBookmark))
                                #if DEBUG
                                commitHook?()
                                #endif
                            } catch {
                                trace.event(.failed, context: .init(.folderBookmark), error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
                                throw error
                            }
                            withExtendedLifetime(lease) {}
                        }
                        remembering = .saved
                    } catch {
                        remembering = .failed(.describe(error)); rememberingError = DiagnosticErrors.project(error); rememberingCauses = DiagnosticErrors.causes(error)
                    }
                } else {
                    trace.event(.blocked, context: .init(.folderBookmark))
                    remembering = .failed(FolderAccessDiagnostic(kind: .other,
                        message: "Remembering folders is unavailable for this session. You can still try browsing the chosen folder."))
                }
            }
            guard generation == token, !Task.isCancelled else {
                lease.close(); trace.event(.cancelled, context: .init(.folderAccessPublication, flags: [.cancellationRequested])); return nil
            }
            grants[selection.id] = selection
            if case .saved = remembering {
                referenceURLs[selection.id] = url
                referenceIDs.insert(selection.id)
                restored[selection.id] = FolderAccessRestoreResult(id: selection.id, url: url, state: .resolvedUnverified)
                storageIssue = nil
            }
            publishLocations()
            let phase: DiagnosticPhase
            if case .failed = remembering { phase = .partial } else { phase = .completed }
            trace.event(phase, context: .init(.folderAccessPublication), error: rememberingError, causes: rememberingCauses)
            return FolderAccessChoice(selection: selection, lease: lease, remembering: remembering)
        } catch {
            trace.event(error is CancellationError ? .cancelled : .failed, context: .init(.folderScope), error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
            return nil
        }
    }

    /// Call explicitly when restoring app-owned references. Resolution cannot
    /// mount volumes or display UI. A stale reference is retained on disk but
    /// NOT activated; the owner must choose the folder again.
    func resolveRememberedFolders() async -> [FolderAccessRestoreResult] {
        guard let store, !Task.isCancelled else { return [] }
        let token = generation
        let backend = backend
        do {
            let results = try await worker.run {
                try store.load().map { record -> FolderAccessRestoreResult in
                    do {
                        let resolution = try backend.resolve(record.bookmark)
                        guard resolution.url.isFileURL else {
                            return FolderAccessRestoreResult(id: record.id, url: nil, state: .unavailable(.unavailable))
                        }
                        return FolderAccessRestoreResult(id: record.id, url: resolution.url,
                            state: resolution.isStale ? .needsRenewal : .resolvedUnverified)
                    } catch {
                        return FolderAccessRestoreResult(id: record.id, url: nil, state: .unavailable(.describe(error)))
                    }
                }
            }
            guard generation == token, !Task.isCancelled else { return [] }
            // Replace saved-reference metadata as a snapshot; transient grants
            // remain independent. Unresolved references have no matching URL.
            let previousReferences = referenceIDs
            referenceURLs = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                result.url.map { (result.id, $0) }
            })
            referenceIDs = Set(results.map(\.id))
            restored = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            for id in previousReferences { grants.removeValue(forKey: id) }
            for result in results {
                grants.removeValue(forKey: result.id)
                if case .resolvedUnverified = result.state, let url = result.url {
                    grants[result.id] = FolderAccessSelection(id: result.id, url: url)
                }
            }
            storageIssue = nil
            publishLocations()
            return results
        } catch {
            guard generation == token, !Task.isCancelled else { return [] }
            storageIssue = "Remembered locations could not be loaded. Existing records have been preserved."
            return [FolderAccessRestoreResult(id: UUID(), url: nil, state: .unavailable(.describe(error)))]
        }
    }

    /// Root matching only selects a retained grant; it is not an authorization
    /// boundary. macOS and the real read determine access, including symlinks.
    func acquireAccess(to target: URL) async -> FolderAccessLease? {
        guard target.isFileURL, !Task.isCancelled else { return nil }
        let components = target.standardizedFileURL.pathComponents
        let grant = grants.values.filter {
            components.starts(with: $0.url.standardizedFileURL.pathComponents)
        }.max { $0.url.pathComponents.count < $1.url.pathComponents.count }
        guard let grant else { return nil }
        let token = generation
        let backend = backend
        guard let lease = try? await worker.run({ FolderAccessLease(url: grant.url, backend: backend) }) else { return nil }
        guard generation == token, grants[grant.id] != nil, !Task.isCancelled else {
            lease.close()
            return nil
        }
        return lease
    }

    func prepareAccess(to targets: [URL]) -> FolderAccessPreparation {
        var roots: [URL] = []
        for target in targets where target.isFileURL {
            let components = target.standardizedFileURL.pathComponents
            let grant = grants.values.filter {
                components.starts(with: $0.url.standardizedFileURL.pathComponents)
            }.max { $0.url.pathComponents.count < $1.url.pathComponents.count }
            if let grant, !roots.contains(grant.url) { roots.append(grant.url) }
        }
        return FolderAccessPreparation(generation: generation, roots: roots, backend: backend)
    }
    func analysisReuseIdentity(for target: URL, requiringSelection: Bool) -> FolderAnalysisAccessIdentity? {
        guard target.isFileURL else { return nil }
        let grant = grants.values.filter {
            target.standardizedFileURL.pathComponents.starts(with: $0.url.standardizedFileURL.pathComponents)
        }.max { $0.url.pathComponents.count < $1.url.pathComponents.count }
        guard !requiringSelection || grant != nil else { return nil }
        return .init(controller: analysisControllerID, revision: analysisGrantRevision, selectedGrant: grant?.id)
    }

    func hasSelectedAccess(to target: URL) -> Bool {
        selectedRootCovering(target) != nil
    }
    func selectedRootCovering(_ target: URL) -> URL? {
        guard target.isFileURL else { return nil }
        return grants.values.filter {
            target.standardizedFileURL.pathComponents.starts(with: $0.url.standardizedFileURL.pathComponents)
        }.max { $0.url.pathComponents.count < $1.url.pathComponents.count }?.url
    }

    func isCurrent(_ preparation: FolderAccessPreparation) -> Bool {
        preparation.generation == generation && preparation.roots.allSatisfy { root in
            grants.values.contains { $0.url == root }
        }
    }

    /// Forget removes only app-owned references. Existing worker leases remain
    /// valid until their work finishes; this does not revoke macOS privacy grants.
    func forget(id: UUID) async -> FolderAccessDiagnostic? {
        invalidatePendingRequests()
        let wasRemembered = referenceIDs.contains(id)
        grants.removeValue(forKey: id)
        referenceURLs.removeValue(forKey: id)
        referenceIDs.remove(id)
        restored.removeValue(forKey: id)
        guard wasRemembered, let store else { publishLocations(); return nil }
        do { try await worker.run { try store.remove(id: id) }; storageIssue = nil; publishLocations(); return nil }
        catch {
            storageIssue = "Forget did not finish. The saved reference may return after reopening; reselect or retry Forget."
            referenceIDs.insert(id)
            restored[id] = FolderAccessRestoreResult(id: id, url: nil, state: .unavailable(.describe(error)))
            publishLocations()
            return .describe(error)
        }
    }

    private func publishLocations() {
        analysisGrantRevision = UUID()
        let ids = Set(grants.keys).union(referenceIDs)
        locations = ids.map { id in
            let reference = restored[id]
            let state: FolderAccessLocation.State
            if let reference {
                switch reference.state {
                case .resolvedUnverified: state = .remembered
                case .needsRenewal: state = .needsReselection
                case .unavailable: state = .unavailable
                }
            } else { state = .session }
            return FolderAccessLocation(id: id, url: reference?.url ?? grants[id]?.url, state: state)
        }.sorted { lhs, rhs in
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
        }
    }

    func retry(_ url: URL, using action: (URL) -> Void) {
        guard url.isFileURL else { return }
        action(url)
    }

    static var privacySettingsInstructions: String {
        "In System Settings → Privacy & Security, review Files & Folders for selected locations, Full Disk Access for optional protected-data analysis, or Local Network for SMB/SFTP servers. macOS may require quitting and reopening Traverse after a change. "
            + (TraverseAccessPolicy.requiresFolderSelection ? "Choose the folder or drive you want to use in Traverse as well. " : "")
            + "Some files may remain unavailable."
    }

    /// Opens System Settings using its registered app URL. There is no public
    /// TCC request/reset API here and no promise of an undocumented pane URL.
    @discardableResult
    func openPrivacySettings() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Documented in the macOS SDK's EndpointSecurity/ESClient.h. Using its
    /// Settings URL does not use Endpoint Security or request any entitlement.
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
    @discardableResult
    func openFullDiskAccessSettings() -> Bool {
        if NSWorkspace.shared.open(Self.fullDiskAccessSettingsURL) { return true }
        return openPrivacySettings()
    }

    /// Reveal this running copy so the person can drag it into System Settings
    /// when macOS has not already listed it. No privacy permission is changed.
    func revealApplication() {
        let application = Bundle.main.bundleURL
        guard application.isFileURL, application.pathExtension == "app" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([application])
    }
}

private struct FolderBookmarkRecord: Codable, Sendable {
    let id: UUID
    let bookmark: Data
}

private enum FolderBookmarkStoreError: Error {
    case unsafeLocation, invalidStore, limitExceeded
}

/// Used only on FolderAccessWorker's serial queue. Never cleans up user paths.
private struct FolderBookmarkStore: Sendable {
    let directory: URL
    let policy: FileAccessPolicy
    init(_ directory: URL, policy: FileAccessPolicy) { self.directory = directory; self.policy = policy }
    private var file: URL { directory.appendingPathComponent("folder-access-bookmarks-v1.json") }
    private struct Document: Codable { let version: Int; let accessPolicy: String?; var records: [FolderBookmarkRecord] }

    func load() throws -> [FolderBookmarkRecord] {
        try validateLocation()
        let manager = FileManager()
        guard manager.fileExists(atPath: file.path) else { return [] }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
            throw FolderBookmarkStoreError.invalidStore
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard (document.version == 1 && document.accessPolicy == nil && policy == .selectedFolders
            || document.version == 2 && document.accessPolicy == policy.rawValue), document.records.count <= 32,
              Set(document.records.map(\.id)).count == document.records.count else {
            throw FolderBookmarkStoreError.invalidStore
        }
        return document.records
    }

    func upsert(_ record: FolderBookmarkRecord) throws {
        var records = try load()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try save(records)
    }

    func remove(id: UUID) throws {
        var records = try load()
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        try save(records)
    }

    private func save(_ records: [FolderBookmarkRecord]) throws {
        guard records.count <= 32 else { throw FolderBookmarkStoreError.limitExceeded }
        let data = try JSONEncoder().encode(Document(version: 2, accessPolicy: policy.rawValue, records: records))
        guard data.count <= 1_048_576 else { throw FolderBookmarkStoreError.limitExceeded }
        try validateLocation()
        let manager = FileManager()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateLocation()
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateLocation() throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.standardizedFileURL.path != "/" else {
            throw FolderBookmarkStoreError.unsafeLocation
        }
        // Reject existing symlinks in the declared app-owned state path and
        // destination. Missing directories are created only by explicit save.
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        let parts = Array(directory.standardizedFileURL.pathComponents.dropFirst()) + [file.lastPathComponent]
        for (index, part) in parts.enumerated() {
            candidate.appendPathComponent(part)
            var facts = stat()
            guard lstat(candidate.path, &facts) == 0 else {
                if errno == ENOENT { break }
                throw FolderBookmarkStoreError.unsafeLocation
            }
            let last = index == parts.count - 1
            guard facts.st_mode & S_IFMT == (last ? S_IFREG : S_IFDIR) else {
                throw FolderBookmarkStoreError.unsafeLocation
            }
            if last || candidate.path == directory.path {
                guard facts.st_uid == getuid(), facts.st_mode & 0o077 == 0,
                      !last || facts.st_nlink == 1 else { throw FolderBookmarkStoreError.unsafeLocation }
            }
        }
    }
}

private final class FolderAccessWorker: @unchecked Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MacExplorer.FolderAccess"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let cancellation = FolderAccessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    // Finish the throwing scope (including destruction of an
                    // acquired-but-cancelled lease) before resuming the caller.
                    let result: Result<Value, Error> = Result {
                        try cancellation.check()
                        let activity = try ApplicationFileActivity.gate.begin()
                        defer { withExtendedLifetime(activity) {} }
                        let value = try work()
                        try cancellation.check()
                        return value
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class FolderAccessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
