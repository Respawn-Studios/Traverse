import AppKit
import Combine
import ExplorerCore
import FileMemory
import LocalStorage
import Search
import UniformTypeIdentifiers

enum PrivateNameChange { case changed, yielding, forget(RememberedItemID?), access(RememberedItemID), closed }
enum PrivateNameSources: String, CaseIterable, Codable { case files = "Files", saved = "Saved Names", both = "Both" }
enum PrivateNameImportActivation { static let enabled = true }

/// One explicit app-profile owner. All catalog/native I/O stays in FileMemory;
/// views own only drafts, admitted display lifetimes and their own generations.
@MainActor
final class ApplicationPrivateNames: ObservableObject {
    static let shared = ApplicationPrivateNames()
    @Published private(set) var status = ""
    @Published private(set) var isSaving = false
    @Published private(set) var storageStatus = NameStoreStatus.absent
    @Published private(set) var pendingForget: RememberedItemID?
    @Published private(set) var pendingAccessRemoval: RememberedItemID?
    @Published private(set) var pendingForgetAll = false
    @Published private(set) var management: NameStoreManagement?
    @Published private(set) var managementNotice = ""
    @Published private(set) var importInProgress = false
    private var managementGeneration = UUID()
    private var importGeneration = UUID()
    private var importer: NameImportSession?
    private var retiringImporters: [Task<Void, Never>] = []
    @Published var moveAttention = false
    @Published var moveContinuityAvailable = false
    @Published var moveMembersAvailable = false
    @Published var moveCoverageNotice = ""
    @Published var moveNotice = ""
    let enablesMoveContinuity: Bool
    let enablesImport: Bool
    var moveGaps = Set<RememberedItemID>()
    private(set) var directory: URL?
    private weak var settings: BrowserSettings?
    private var store: PersistentNameStore?
    private var writable = false
    private var opening: Task<PersistentNameStore?, Error>?
    private var writerOpening: Task<PersistentNameStore, Error>?
    private var transitioning = false
    private var shuttingDown = false
    private var labelSaveActive = false
    private var labelSaveWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    var beforeLabelApplyForVerification: (@MainActor () async -> Void)?
    #endif
    private var observers: [UUID: @MainActor (PrivateNameChange) -> Void] = [:]
    private let reader = PrivateNameEntryReader()
    private var libraryWindow: PrivateNamesWindowController?
    var visibleLibraryWindow: NSWindow? { libraryWindow?.window?.isVisible == true ? libraryWindow?.window : nil }

    init(directory: URL? = nil, settings: BrowserSettings? = nil,
         enablesMoveContinuity: Bool = PrivateMoveActivation.enabled, enablesImport: Bool = PrivateNameImportActivation.enabled) {
        self.directory = directory; self.settings = settings; self.enablesMoveContinuity = enablesMoveContinuity
        self.enablesImport = enablesImport
    }
    func configure(_ browser: BrowserViewController) {
        let state = browser.developmentStateDirectory
        let selectedState = GeneratedArchiveDriveReview.selection?.journalDirectory.deletingLastPathComponent()
        let generatedArchiveReview = GeneratedArchiveDriveReview.archiveAdmitted
            && state != nil && state?.standardizedFileURL == selectedState?.standardizedFileURL
        guard directory == nil, !browser.isReadOnlyFileSession,
              (!browser.isVerificationSession || generatedArchiveReview) else { return }
        directory = state?.appendingPathComponent("private-names", isDirectory: true)
        settings = browser.settings
    }
    func observe(_ id: UUID, _ body: @escaping @MainActor (PrivateNameChange) -> Void) { observers[id] = body }
    func stopObserving(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify(_ value: PrivateNameChange) {
        switch value {
        case .forget(let id):
            cancelNameImport()
            if let id { moveGaps.remove(id) } else { moveGaps.removeAll(); moveCoverageNotice = "" }
        case .access(let id): moveGaps.remove(id)
        case .closed: cancelNameImport()
        default: break
        }
        for callback in Array(observers.values) { callback(value) }
    }
    func moveReferencesChanged() { notify(.changed) }
    func moveStorageNeedsRecovery() {
        storageStatus = .recoveryRequired
        status = "Saved names need an explicit recovery action. File-operation results are unchanged."
    }
    func recordMoveStorageFailure(_ error: Error) {
        guard let failure = error as? NameStoreFailure else { return }
        switch failure {
        case .uncertainCommit, .recoveryRequired, .initializationIncomplete, .changed:
            moveStorageNeedsRecovery()
        case .unsafe:
            storageStatus = .unsafe; status = "Saved-name storage could not be verified. Existing records are preserved."
        case .unsupported:
            storageStatus = .unsupported; status = "This saved-name catalog requires a compatible app version."
        default: break // Busy, revocation, quota and Relink have separate actions.
        }
    }

    func readableStore() async throws -> PersistentNameStore? {
        guard !shuttingDown, !transitioning else { throw NameStoreFailure.busy }
        if let store { return store }
        if let opening { return try await finishOpening(opening) }
        guard let directory else { throw NameStoreFailure.unavailable }
        let task = Task<PersistentNameStore?, Error> {
            let inspection = await PersistentNameStore.inspect(directory: directory, activity: ApplicationFileActivity.gate)
            self.storageStatus = inspection.status
            if inspection.status != .absent && inspection.status != .ready {
                self.status = "Saved names need attention. Use the explicit storage action below; existing information is preserved."
            }
            guard inspection.status != .absent else { return nil }
            switch inspection.status {
            case .ready, .forgetPending, .accessRemovalPending, .referenceUpdateRequired, .indexUpdateRequired:
                return try await PersistentNameStore.open(directory: directory, activity: ApplicationFileActivity.gate)
            default: throw NameStoreFailure.recoveryRequired
            }
        }
        opening = task
        return try await finishOpening(task)
    }
    private func finishOpening(_ task: Task<PersistentNameStore?, Error>) async throws -> PersistentNameStore? {
        defer { opening = nil }
        do {
            let value = try await task.value
            guard !shuttingDown else { if let value { await value.close() }; throw NameStoreFailure.closed }
            guard !transitioning else { throw NameStoreFailure.busy }
            if let store { return store }
            if let value {
                if pendingForgetAll { _ = try await value.prepareForgetAfterExports() }
                else if let pendingForget { _ = try value.prepareForget(pendingForget) }
                if let pendingAccessRemoval { _ = try value.prepareRemoveAccess(pendingAccessRemoval) }
            }
            store = value
            if let value { await refreshMoveAttention(in: value) }
            return value
        }
        catch { status = "Saved names need attention. Open Remembered Items to review storage."; throw error }
    }
    func writer() async throws -> PersistentNameStore? {
        guard pendingForget == nil, !pendingForgetAll, pendingAccessRemoval == nil else { throw NameStoreFailure.recoveryRequired }
        _ = try await readableStore()
        if writable { return store }
        guard let directory else { throw NameStoreFailure.unavailable }
        transitioning = true; notify(.yielding)
        defer { transitioning = false }
        if let store { await store.close(); self.store = nil }
        let inspection = await PersistentNameStore.inspect(directory: directory, activity: ApplicationFileActivity.gate)
        guard !shuttingDown else { throw NameStoreFailure.closed }
        if inspection.status == .absent { return nil }
        guard inspection.status == .ready else { storageStatus = inspection.status; status = "Saved names need an explicit storage action in Remembered Items."; throw NameStoreFailure.recoveryRequired }
        let task = Task { try await PersistentNameStore.open(directory: directory, action: .edit, activity: ApplicationFileActivity.gate) }
        writerOpening = task; defer { writerOpening = nil }
        let opened = try await task.value
        guard !shuttingDown else { await opened.close(); throw NameStoreFailure.closed }
        store = opened; writable = true; await refreshMoveAttention(in: opened); return opened
    }
    func lookup(_ source: URL, retaining access: (any Sendable)?) async throws -> (StoredNameSnapshot, RememberedNameUse)? {
        guard let store = try await readableStore(), let snapshot = try await store.lookup(source: source, retaining: access) else { return nil }
        return (snapshot, try store.beginUse(snapshot))
    }
    /// Admission observation only. This never remembers an object, creates a
    /// bookmark or reads a saved document body, including in owned recovery.
    func hasCurrentBoundReference(at source: URL, retaining access: (any Sendable)?) async throws -> Bool {
        guard let store = try await readableStore() else { return false }
        return try await store.hasCurrentBoundReference(at: source, retaining: access)
    }
    func save(_ names: AuthoredNames, source: URL?, id: RememberedItemID?, revision: UInt64?,
              access: (any Sendable)?, allowFollowing: Bool) async throws -> RememberedItemID {
        try await ApplicationDiagnostics.shared.perform(.privateNames) {
            try await self.performSave(names, source: source, id: id, revision: revision, access: access, allowFollowing: allowFollowing)
        }
    }
    private func performSave(_ names: AuthoredNames, source: URL?, id: RememberedItemID?, revision: UInt64?,
                             access: (any Sendable)?, allowFollowing: Bool) async throws -> RememberedItemID {
        guard !isSaving, !shuttingDown else { throw NameStoreFailure.busy }
        isSaving = true; defer { isSaving = false }
        let operationOwner = UUID(), operations = ApplicationOperationCoordinator.shared
        if id == nil {
            guard operations.beginPreparation(owner: operationOwner) else { throw NameStoreFailure.busy }
        }
        defer { if id == nil { operations.finishPreparation(owner: operationOwner) } }
        let result: RememberedItemID
        if let store = try await writer() {
            if let id {
                let current = try await store.snapshot(id)
                guard current.revision == revision else { throw NameIndexFailure.staleEdit }
                result = try await store.apply(store.prepareEdit(current, names: names))
            } else {
                guard let source else { throw RememberedReferenceFailure.unavailable }
                let edit = try await store.prepareRemembering(names, source: source, retaining: access, allowDocumentFollowing: allowFollowing)
                result = try await store.apply(edit)
            }
        } else {
            guard id == nil, let directory, let source else { throw NameIndexFailure.missingRecord }
            try await AppStoragePreparation.owner(for: directory.deletingLastPathComponent()).prepare()
            let created = try await PersistentNameStore.createRemembering(directory: directory, first: names, source: source,
                retaining: access, activity: ApplicationFileActivity.gate, allowDocumentFollowing: allowFollowing)
            store = created; writable = true; result = try await created.firstItemID()
            settings?.privateNamesSources = .both
        }
        storageStatus = .ready; status = ""; notify(.changed); return result
    }
    func addPrivateLabels(_ expected: [PrivateLabelSelection], labels: [String],
                          isCurrent: @MainActor @Sendable () -> Bool) async throws -> NameLabelAdditionResult {
        try await ApplicationDiagnostics.shared.perform(.privateNames) {
            try await self.performLabelAddition(expected, labels: labels, isCurrent: isCurrent)
        }
    }
    private func performLabelAddition(_ expected: [PrivateLabelSelection], labels: [String],
                                      isCurrent: @MainActor @Sendable () -> Bool) async throws -> NameLabelAdditionResult {
        guard !isSaving, !shuttingDown else { throw NameStoreFailure.busy }
        guard (1...64).contains(expected.count), Set(expected.map(\.id)).count == expected.count else { throw NameIndexFailure.invalidInput }
        isSaving = true; labelSaveActive = true
        defer {
            isSaving = false; labelSaveActive = false
            let waiters = labelSaveWaiters; labelSaveWaiters = []; waiters.forEach { $0.resume() }
        }
        guard let store = try await writer() else { throw NameIndexFailure.missingRecord }
        try Task.checkCancellation()
        guard !shuttingDown, isCurrent() else { throw CancellationError() }
        let preview = try await store.prepareLabelAddition(expected, labels: labels)
        do {
            #if DEBUG
                if let beforeLabelApplyForVerification { await beforeLabelApplyForVerification() }
            #endif
            try Task.checkCancellation()
            guard !shuttingDown, isCurrent() else { throw CancellationError() }
            let result = try await store.applyLabelAddition(preview)
            storageStatus = .ready
            status = result.changedItems == 0 ? "These labels are already saved on every selected item."
                : "Labels added to \(result.changedItems) remembered item\(result.changedItems == 1 ? "" : "s")."
            if result.changedItems > 0 { notify(.changed) }
            return result
        } catch {
            await store.cancelLabelAddition(preview)
            switch error {
            case NameStoreFailure.uncertainCommit, NameStoreFailure.recoveryRequired, NameStoreFailure.changed:
                storageStatus = .recoveryRequired
                status = "The label Save needs a storage check. Recover Saved Names before another change; it may already have completed."
            default: break
            }
            throw error
        }
    }

    func list(query: String = "", labelOnly: Bool = false) async throws -> (StoredNamePage, RememberedNameUse)? {
        guard let store = try await readableStore() else { return nil }
        let page: StoredNamePage
        if query.trimmingCharacters(in: .whitespaces).isEmpty { page = try await store.library() }
        else { page = try await store.query(RememberedNameQuery(text: query,
            match: labelOnly ? .exact : .prefixAndWords, separatorTolerant: settings?.symbolTolerantNames ?? true,
            fields: labelOnly ? [.label] : Set(RememberedNameField.allCases))) }
        return (page, try store.beginUse(page))
    }
    func snapshot(_ id: RememberedItemID) async throws -> (StoredNameSnapshot, RememberedNameUse) {
        guard let store = try await readableStore() else { throw NameIndexFailure.missingRecord }
        let value = try await store.snapshot(id); return (value, try store.beginUse(value))
    }
    func next(_ cursor: RememberedNameCursor) async throws -> (StoredNamePage, RememberedNameUse)? {
        guard let store = try await readableStore() else { return nil }
        let page = try await store.nextPage(cursor); return (page, try store.beginUse(page))
    }
    func search(_ query: RememberedNameQuery) async throws -> (StoredNamePage, RememberedNameUse)? {
        guard let store = try await readableStore() else { return nil }
        let page = try await store.query(query); return (page, try store.beginUse(page))
    }
    func availability(_ id: RememberedItemID) async throws -> RememberedReferenceDisplay {
        guard let store = try await readableStore() else { throw NameIndexFailure.missingRecord }
        let handle = try await store.resolveReference(id)
        var display: RememberedReferenceDisplay?
        guard handle.publish({ display = $0 }), let display else { throw RememberedReferenceFailure.stale }
        if display.availability == .available, moveGaps.remove(id) != nil {
            await refreshMoveAttention(in: store)
        }
        return display
    }
    func entry(_ id: RememberedItemID, scope: SearchScope? = nil, includeExternal: Bool = true, showHidden: Bool = true) async throws -> FileEntry {
        guard let store = try await readableStore() else { throw NameIndexFailure.missingRecord }
        let reader = reader
        return try await store.withVerifiedReference(id) { url in
            let entry = try await reader.read(url, scope: scope, includeExternal: includeExternal, showHidden: showHidden)
            let checked = try await store.resolveReference(id)
            var location: URL?
            guard checked.publish({ if $0.availability == .available { location = $0.location } }), location == entry.url else {
                throw RememberedReferenceFailure.changed
            }
            return entry
        }
    }
    func use<T: Sendable>(_ id: RememberedItemID, perform: @escaping @Sendable (URL) async throws -> T) async throws -> T {
        guard let store = try await readableStore() else { throw NameIndexFailure.missingRecord }
        return try await store.withVerifiedReference(id, perform: perform)
    }
    func forget(_ id: RememberedItemID) async throws -> RememberedForgetOutcome {
        try await ApplicationDiagnostics.shared.perform(.forget, outcome: { $0 == .forgotten ? .completed : .partial }) {
            try await self.performForget(id)
        }
    }
    private func performForget(_ id: RememberedItemID) async throws -> RememberedForgetOutcome {
        guard !isSaving else { throw NameStoreFailure.busy }
        isSaving = true; defer { isSaving = false }
        guard let store = try await writer() else { throw NameIndexFailure.missingRecord }
        notify(.forget(id))
        let request = try await store.prepareForgetAfterExports(id)
        let outcome: RememberedForgetOutcome
        do { outcome = try await store.finishForget(request) }
        catch {
            pendingForget = id; storageStatus = .recoveryRequired
            status = "Forget could not finish. Information is hidden only in this session; use Retry Forget before quitting."
            throw error
        }
        recordForget(outcome, id: id)
        await refreshMoveAttention(in: store)
        notify(.changed); return outcome
    }
    private func recordForget(_ outcome: RememberedForgetOutcome, id: RememberedItemID) {
        pendingForget = outcome == .forgotten ? nil : id
        switch outcome {
        case .forgotten: status = ""; storageStatus = .ready
        case .hiddenPending: status = "Forget is saved but incomplete. Information stays hidden; use Retry Forget to finish."; storageStatus = .forgetPending
        case .sessionHiddenOnly: status = "Forget was not saved. Information is hidden only in this session. Retry Forget before quitting."; storageStatus = .recoveryRequired
        }
    }
    func retryForget() async throws {
        guard let id = pendingForget, !isSaving, !transitioning, let directory else { throw NameStoreFailure.busy }
        isSaving = true; transitioning = true; notify(.yielding)
        defer { isSaving = false; transitioning = false }
        if let store { await store.close(); self.store = nil }
        let reopened = try await PersistentNameStore.open(directory: directory, action: .recover, activity: ApplicationFileActivity.gate)
        store = reopened; writable = true
        let request = try reopened.prepareForget(id); notify(.forget(id))
        recordForget(try await reopened.finishForget(request), id: id); notify(.changed)
        await refreshMoveAttention(in: reopened)
    }
    func removeAccess(_ id: RememberedItemID) async throws {
        try await ApplicationDiagnostics.shared.perform(.removeAccess) { try await self.performRemoveAccess(id) }
    }
    private func performRemoveAccess(_ id: RememberedItemID) async throws {
        guard !isSaving else { throw NameStoreFailure.busy }
        isSaving = true; defer { isSaving = false }
        guard let store = try await writer() else { throw NameIndexFailure.missingRecord }
        let request = try store.prepareRemoveAccess(id); notify(.access(id))
        let outcome: RememberedAccessRemovalOutcome
        do { outcome = try await store.finishRemoveAccess(request) }
        catch {
            pendingAccessRemoval = id; storageStatus = .recoveryRequired
            status = "Remove Access could not finish. Access is disabled only in this session; retry before quitting."
            throw NameStoreFailure.recoveryRequired
        }
        guard outcome == .removed else {
            pendingAccessRemoval = id; storageStatus = .accessRemovalPending
            status = outcome == .sessionDisabledOnly ? "Remove Access was not saved. Access is disabled only in this session; retry before quitting."
                : "Access removal is saved but incomplete. Use Retry Remove Access to finish."
            throw NameStoreFailure.recoveryRequired
        }
        pendingAccessRemoval = nil; status = ""; storageStatus = .ready
        await refreshMoveAttention(in: store)
        notify(.changed)
    }
    func retryAccessRemoval() async throws {
        guard let id = pendingAccessRemoval, !isSaving, !transitioning, let directory else { throw NameStoreFailure.busy }
        isSaving = true; transitioning = true; notify(.yielding)
        defer { isSaving = false; transitioning = false }
        if let store { await store.close(); self.store = nil }
        let reopened = try await PersistentNameStore.open(directory: directory, action: .recover, activity: ApplicationFileActivity.gate)
        store = reopened; writable = true
        let pending = try await reopened.pendingMaintenance()
        if pending.access { try await reopened.finishPendingAccessRemoval() }
        else {
            let request = try reopened.prepareRemoveAccess(id); notify(.access(id))
            guard try await reopened.finishRemoveAccess(request) == .removed else { throw NameStoreFailure.recoveryRequired }
        }
        pendingAccessRemoval = nil; storageStatus = .ready; status = ""; notify(.changed)
        await refreshMoveAttention(in: reopened)
    }
    func relink(_ id: RememberedItemID, source: URL, access: (any Sendable)?, allowFollowing: Bool) async throws {
        try await ApplicationDiagnostics.shared.perform(.relink) {
            try await self.performRelink(id, source: source, access: access, allowFollowing: allowFollowing)
        }
    }
    private func performRelink(_ id: RememberedItemID, source: URL, access: (any Sendable)?, allowFollowing: Bool) async throws {
        guard !isSaving else { throw NameStoreFailure.busy }
        isSaving = true; defer { isSaving = false }
        let owner = UUID(), operations = ApplicationOperationCoordinator.shared
        guard operations.beginPreparation(owner: owner) else { throw NameStoreFailure.busy }
        defer { operations.finishPreparation(owner: owner) }
        guard let store = try await writer() else { throw NameIndexFailure.missingRecord }
        let request = try await store.prepareRelink(id, source: source, retaining: access, allowDocumentFollowing: allowFollowing)
        _ = try await store.apply(request); moveGaps.remove(id); await refreshMoveAttention(in: store); notify(.changed)
    }
    func storageAction(_ action: NameStoreOpenAction) async throws {
        try await ApplicationDiagnostics.shared.perform(.recovery) { try await self.performStorageAction(action) }
    }
    private func performStorageAction(_ action: NameStoreOpenAction) async throws {
        guard !isSaving, !transitioning, let directory else { throw NameStoreFailure.busy }
        guard pendingForget == nil, !pendingForgetAll, pendingAccessRemoval == nil else { throw NameStoreFailure.recoveryRequired }
        let operationOwner = UUID(), operations = ApplicationOperationCoordinator.shared
        if action == .upgradeMoveContinuity || action == .upgradeMoveMembers {
            guard enablesMoveContinuity, operations.beginPreparation(owner: operationOwner) else { throw NameStoreFailure.busy }
        }
        defer { if action == .upgradeMoveContinuity || action == .upgradeMoveMembers { operations.finishPreparation(owner: operationOwner) } }
        isSaving = true; transitioning = true; notify(.yielding)
        defer { isSaving = false; transitioning = false }
        if let store { await store.close(); self.store = nil }
        let opened = try await PersistentNameStore.open(directory: directory, action: action, activity: ApplicationFileActivity.gate)
        store = opened; writable = action != .readOnly
        if action == .recover {
            let pending = try await opened.pendingMaintenance()
            if pending.forget { _ = try await opened.finishPendingForget() }
            if pending.access { try await opened.finishPendingAccessRemoval() }
        }
        storageStatus = try await opened.maintenanceStatus()
        await refreshMoveAttention(in: opened)
        status = storageStatus == .ready ? "" : "Saved names need another explicit storage action. Existing information is preserved."
        notify(.changed)
    }
    func showLibrary(browser: BrowserViewController) {
        configure(browser)
        if libraryWindow == nil { libraryWindow = PrivateNamesWindowController(owner: self) }
        libraryWindow?.show(browser: browser)
    }
    func close() async {
        shuttingDown = true; notify(.closed)
        if labelSaveActive { await withCheckedContinuation { labelSaveWaiters.append($0) } }
        await drainNameImports()
        if let opening, let opened = try? await opening.value { await opened.close() }
        if let writerOpening, let opened = try? await writerOpening.value { await opened.close() }
        if let store { await store.close(); self.store = nil }
        writable = false
    }
    static func message(_ error: Error) -> String {
        switch error {
        case RememberedReferenceFailure.followingRequired: "Document following is needed for this item. Review the explanation before remembering it."
        case RememberedReferenceFailure.accessNeeded: "macOS denied access. Choose the item explicitly to grant access, then try again."
        case RememberedReferenceFailure.alreadyRemembered: "This item already has saved names. Reopen its editor to review the existing record."
        case RememberedReferenceFailure.unsupported: "This item cannot be linked here. The first version supports eligible local APFS files and folders."
        case NameIndexFailure.invalidInput, NameIndexFailure.emptyInput, NameIndexFailure.projectionLimit: "Check your names and labels. Names allow 512 UTF-8 bytes; labels allow 128, with up to 16 of each list."
        case NameIndexFailure.staleEdit, RememberedReferenceFailure.stale, RememberedReferenceFailure.changed: "This item or its saved names changed. Reload before saving; your current draft has been kept."
        case NameStoreFailure.busy: "Wait for current work to finish, then try again."
        case NameStoreFailure.referenceUpdateRequired, NameStoreFailure.indexUpdateRequired, NameStoreFailure.continuityUpdateRequired, NameStoreFailure.recoveryRequired: "Saved names need an explicit storage action in Remembered Items. Existing information was preserved."
        default: "The request could not be completed. Existing saved information was preserved; refresh or review storage before retrying."
        }
    }
}

extension ApplicationPrivateNames {
    func refreshManagement() async {
        let token = UUID(); managementGeneration = token
        do {
            guard let store = try await readableStore() else {
                guard token == managementGeneration, !shuttingDown else { return }
                management = nil; managementNotice = "No saved-name catalog has been created."; return
            }
            let value = try await store.management()
            guard token == managementGeneration, !shuttingDown else { return }
            management = value; managementNotice = ""
        } catch {
            guard token == managementGeneration, !shuttingDown else { return }
            management = nil; managementNotice = "Storage is unavailable or needs an explicit recovery action in Remembered Items."
        }
    }
    func prepareNameExport(locations: Bool) async throws -> PreparedNameExport {
        try await ApplicationDiagnostics.shared.perform(.exportNames) { try await self.performPrepareNameExport(locations: locations) }
    }
    private func performPrepareNameExport(locations: Bool) async throws -> PreparedNameExport {
        guard !isSaving, !shuttingDown else { throw NameStoreFailure.busy }
        // Explicit export obtains the existing writer once, so Forget can share
        // that owner without closing a read-only preview session midway.
        guard let store = try await writer() else { throw NameExportFailure.empty }
        return try await store.prepareExport(includeLocations: locations)
    }
    func cancelNameExport(_ preview: PreparedNameExport) { store?.cancelExport(preview) }
    func publishNameExport(_ preview: PreparedNameExport, to url: URL,
                           cancellation: RememberedNameCancellation) async -> NameExportOutcome {
        await ApplicationDiagnostics.shared.perform(.exportNames, outcome: { result in
            switch result { case .saved: .completed; case .createdButIncomplete: .partial
            case .notCreated(let failure): failure == .cancelled ? .cancelled : .failed }
        }, failure: { result in
            switch result { case .saved: nil; case .createdButIncomplete(let failure), .notCreated(let failure): DiagnosticErrors.project(failure) }
        }) { await self.performPublishNameExport(preview, to: url, cancellation: cancellation) }
    }
    private func performPublishNameExport(_ preview: PreparedNameExport, to url: URL,
                                          cancellation: RememberedNameCancellation) async -> NameExportOutcome {
        guard let store, !shuttingDown else { return .notCreated(.stalePreview) }
        if let state = settings?.storageStateDirectory?.standardizedFileURL,
           url.standardizedFileURL == state || url.standardizedFileURL.path.hasPrefix(state.path + "/") {
            store.cancelExport(preview); return .notCreated(.invalidDestination)
        }
        return await store.export(preview, to: url, cancellation: cancellation)
    }
    func forgetAllNames() async throws -> RememberedForgetOutcome {
        try await ApplicationDiagnostics.shared.perform(.forget, outcome: { $0 == .forgotten ? .completed : .partial }) {
            try await self.performForgetAllNames()
        }
    }
    private func performForgetAllNames() async throws -> RememberedForgetOutcome {
        guard !isSaving else { throw NameStoreFailure.busy }
        cancelNameImport()
        isSaving = true; defer { isSaving = false }
        await drainNameImports()
        guard let store = try await writer() else {
            notify(.forget(nil)); management = nil; status = "Saved names forgotten. No catalog has been created."; return .forgotten
        }
        notify(.forget(nil)); status = "Hiding saved names and finishing current work…"
        let request = try await store.prepareForgetAfterExports()
        let outcome: RememberedForgetOutcome
        do { outcome = try await store.finishForget(request) }
        catch { pendingForgetAll = true; storageStatus = .recoveryRequired; status = "Forget All is incomplete. Retry before quitting; earlier exports and backups are separate copies."; throw error }
        pendingForgetAll = outcome != .forgotten
        storageStatus = outcome == .forgotten ? .ready : outcome == .hiddenPending ? .forgetPending : .recoveryRequired
        status = outcome == .forgotten ? "Saved names forgotten. Source files and older backups/exports are unchanged."
            : outcome == .hiddenPending ? "Forget is saved; cleanup or work drain needs Retry Forget All."
            : "Forget was not saved. Names are hidden only in this session; retry before quitting."
        await refreshMoveAttention(in: store); notify(.changed); await refreshManagement(); return outcome
    }
    func retryForgetAllNames() async throws {
        guard pendingForgetAll, !isSaving, !transitioning, let directory else { throw NameStoreFailure.busy }
        isSaving = true; transitioning = true; defer { isSaving = false; transitioning = false }
        notify(.yielding)
        if let store { await store.close(); self.store = nil }
        let reopened = try await PersistentNameStore.open(directory: directory, action: .recover, activity: ApplicationFileActivity.gate)
        let request = try await reopened.prepareForgetAfterExports(); notify(.forget(nil))
        store = reopened; writable = true
        let result = try await reopened.finishForget(request)
        pendingForgetAll = result != .forgotten
        storageStatus = result == .forgotten ? .ready : .forgetPending
        status = result == .forgotten ? "Saved names forgotten." : "Forget All needs another retry. Information stays hidden."
        notify(.changed); await refreshManagement()
    }
}

extension ApplicationPrivateNames {
    func cancelNameImport() {
        importGeneration = UUID()
        guard let importer else { return }
        self.importer = nil; importer.cancel()
        retiringImporters.append(Task { await importer.close() })
    }
    private func drainNameImports() async {
        while !retiringImporters.isEmpty {
            let tasks = retiringImporters; retiringImporters = []
            for task in tasks { await task.value }
        }
    }
    func prepareNameImport(_ file: URL, retaining access: (any Sendable)? = nil) async throws -> PreparedNameImport {
        try await ApplicationDiagnostics.shared.perform(.importNames) { try await self.performPrepareNameImport(file, retaining: access) }
    }
    private func performPrepareNameImport(_ file: URL, retaining access: (any Sendable)?) async throws -> PreparedNameImport {
        guard !isSaving, !shuttingDown, let directory else { throw NameStoreFailure.busy }
        cancelNameImport(); let token = importGeneration
        await drainNameImports()
        guard importGeneration == token, !isSaving, !shuttingDown else { throw NameImportFailure.stalePreview }
        let existing = try await writer()
        guard importGeneration == token, !isSaving, !shuttingDown else { throw NameImportFailure.stalePreview }
        let session = NameImportSession(target: existing.map(NameImportTarget.existing) ?? .newCatalog(directory: directory), activity: ApplicationFileActivity.gate)
        importer = session
        do {
            let preview = try await session.preview(selectedFile: file, retaining: access)
            guard importGeneration == token, !shuttingDown else { session.cancel(); throw NameImportFailure.stalePreview }
            return preview
        } catch {
            if importer === session { cancelNameImport() }
            await session.close(); throw error
        }
    }
    func applyNameImport(_ preview: PreparedNameImport) async -> NameImportOutcome {
        await ApplicationDiagnostics.shared.perform(.importNames, outcome: { result in
            switch result { case .imported: .completed; case .committedButHidden, .uncertain: .partial
            case .notImported(let failure): failure == .cancelled ? .cancelled : .failed }
        }, failure: { result in
            if case .notImported(let failure) = result { DiagnosticErrors.project(failure) } else { nil }
        }) { await self.performApplyNameImport(preview) }
    }
    private func performApplyNameImport(_ preview: PreparedNameImport) async -> NameImportOutcome {
        guard !isSaving, !shuttingDown, let session = importer else { return .notImported(.stalePreview) }
        isSaving = true; defer { isSaving = false }
        let result = await session.apply(preview)
        guard !shuttingDown else { return result }
        if let created = await session.takeCreatedStore() { store = created; writable = true; settings?.privateNamesSources = .both }
        switch result {
        case .imported(let attempt):
            storageStatus = .ready; status = "Imported \(attempt.records) descriptions. Open Remembered Items to Relink them; no file access was imported."
            await refreshManagement(); notify(.changed)
        case .committedButHidden:
            storageStatus = .forgetPending; status = "The import committed while Forget was finishing. Information stays hidden; finish Forget in Remembered Items."
        case .uncertain:
            storageStatus = .recoveryRequired; status = "Import may have completed. Recover and review Remembered Items before importing again. Nothing will retry automatically."
            notify(.changed)
        case .notImported(let failure): status = Self.importMessage(failure)
        }
        if importer === session { importer = nil }
        await session.close(); return result
    }
    func chooseNameImport(in window: NSWindow) {
        guard enablesImport, !isSaving, !importInProgress, !shuttingDown else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        panel.message = "Choose a Traverse saved-name export. A preview follows; source files and exported paths will not be opened."
        panel.prompt = "Preview Import"
        importInProgress = true
        Task {
            defer { importInProgress = false }
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url, !shuttingDown else { return }
            do {
                let preview = try await prepareNameImport(url, retaining: FolderAccessLease(url: url, backend: SystemFolderAccessBackend()))
                guard window.isVisible, !shuttingDown else { cancelNameImport(); return }
                guard await reviewNameImport(preview, in: window), !shuttingDown else { cancelNameImport(); return }
                _ = await applyNameImport(preview)
            } catch { status = Self.importMessage(error); cancelNameImport() }
        }
    }
    func reviewNameImport(_ preview: PreparedNameImport, in window: NSWindow) async -> Bool {
        let alert = NSAlert(); alert.messageText = "Import \(preview.recordCount) new descriptions?"
        var details = "Adds nicknames, alternate names and labels as separate items. Existing descriptions stay unchanged. Every imported item needs Relink before file actions are available."
        if preview.matchingDescriptions + preview.repeatedDescriptions + preview.matchingSourceIDs > 0 {
            details += "\n\nPossible duplicates: \(preview.matchingDescriptions) matching descriptions, \(preview.repeatedDescriptions) repeated descriptions in this file, \(preview.matchingSourceIDs) matching exported IDs. Matching text is not file identity; nothing is merged."
        }
        if preview.discardedLocations > 0 { details += "\n\n\(preview.discardedLocations) exported locations will be discarded. No access tokens or native identities are imported." }
        details += "\n\nThis explicit import can reintroduce descriptions from an older export, including previously forgotten names."
        alert.informativeText = details; alert.addButton(withTitle: "Import \(preview.recordCount) Descriptions"); alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
    static func importMessage(_ error: Error) -> String {
        switch error {
        case NameImportFailure.invalidDocument, NameImportFailure.unsupportedVersion: "This is not a complete supported saved-name export. No descriptions were imported."
        case NameImportFailure.tooLarge, NameImportFailure.quota: "The import exceeds its size, record or processing limit. No descriptions were imported."
        case NameImportFailure.stalePreview, NameExportFailure.stalePreview: "Saved information changed or was forgotten. Choose the file again to review a new import."
        case NameImportFailure.cancelled: "Import cancelled."
        case NameImportFailure.changedFile: "The selected export changed while being read. Choose it again; nothing was imported."
        case NameImportFailure.unsupportedFile: "Choose an ordinary local APFS JSON export outside cloud/provider or protected locations."
        case NameImportFailure.inaccessibleFile: "The selected export could not be read. No descriptions were imported."
        default: "Import could not finish. Review saved-name storage before trying again."
        }
    }
}
