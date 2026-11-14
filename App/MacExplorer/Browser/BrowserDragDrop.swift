import AppKit
import FileOperations
import LocalStorage

/// A native local-file offer only. It carries no remote path or file promise;
/// consumers still perform their own source/destination admission and checks.
struct LocalFileDropKey: Hashable {
    let sequence: Int, board: NSPasteboard.Name, changeCount: Int
}
struct LocalFileDropSource {
    let key: LocalFileDropKey, urls: [URL], access: FileAccessLifetimes
}

/// Acceptance means an async recoverable job was admitted, never that a native
/// drag callback completed a transfer. All mutations remain in FileOperations.
struct BrowserDropRequest: Sendable {
    let sources: [URL]
    let destination: URL
    let move: Bool
    let observation: FileOperationSelection
    let access: FileAccessLifetimes
    let metadataPolicy: TransferMetadataPolicy
    let copyExecution: CopyExecutionRequest

    init(sources: [URL], destination: URL, move: Bool, observation: FileOperationSelection,
         access: FileAccessLifetimes, metadataPolicy: TransferMetadataPolicy,
         copyExecution: CopyExecutionRequest = .standard) {
        self.sources = sources; self.destination = destination; self.move = move
        self.observation = observation; self.access = access; self.metadataPolicy = metadataPolicy
        self.copyExecution = move ? .standard : copyExecution
    }
}

/// A captured external Copy is admitted for checking, without claiming that
/// its source identities have already been observed.
struct BrowserPendingExternalDropRequest: Sendable {
    let sources: [URL]
    let destination: URL
    let targetObservation: FileOperationSelection?
    let access: FileAccessLifetimes
    let metadataPolicy: TransferMetadataPolicy
    let copyExecution: CopyExecutionRequest

    @MainActor
    func enqueue(in browser: BrowserViewController) -> UUID? {
        guard let engine = browser.recoverableFileOperations else { return nil }
        return browser.operationCoordinator.transfers.enqueue(sources: sources, destination: destination,
            move: false, title: "Copying dropped items…", origin: browser, engine: engine,
            observation: targetObservation, retaining: access, metadataPolicy: metadataPolicy, copyExecution: copyExecution,
            validateAdmission: {
                try await DragFileURLReader.shared.validate(sources)
                try await DragFileURLReader.shared.validate([destination])
            })
    }
}

@MainActor
struct BrowserDragDropHooks {
    var admit: ((BrowserDropRequest) -> Bool)?
    var admitPendingExternal: ((BrowserPendingExternalDropRequest) -> Bool)?
    var observeTarget: (@Sendable (URL) async throws -> FileOperationSelection)?
}

private actor DragFileURLReader {
    static let shared = DragFileURLReader()
    func validate(_ urls: [URL]) throws {
        let activity = try ApplicationFileActivity.beginOperation()
        defer { withExtendedLifetime(activity) {} }
        guard BrowserDragDropController.validURLs(urls) else { throw FileOperationFailure.invalidRequest }
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey,
                                                         .isRegularFileKey, .isDirectoryKey])
            guard values.isAliasFile != true, values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw FileOperationFailure.unsupported
            }
        }
    }
}

@MainActor
final class BrowserDragDropController {
    nonisolated static let maximumItems = 128
    private static let maximumTargets = 64
    private struct Context: Equatable {
        let tab: UUID
        let visit: UUID
        let window: ObjectIdentifier?
        let fileView: ObjectIdentifier
        let presentation: UUID
        let sources: [URL]
        let directory: URL?
        let targets: [URL]
        let navigationTargets: [URL]
        let loading: Bool
    }
    private struct PreparedSource {
        let token = UUID()
        let selection: FileOperationSelection
        let access: FileAccessLifetimes
    }
    private struct PreparedTarget {
        let observation: FileOperationSelection
        let access: FileAccessLifetimes
    }
    private final class ActiveSource {
        weak var view: NSView?
        weak var owner: BrowserDragDropController?
        let prepared: PreparedSource
        let sequence: Int
        let tab: UUID
        let visit: UUID
        let presentation: UUID
        let diagnosticTrace: UUID?
        init(view: NSView, owner: BrowserDragDropController, prepared: PreparedSource, sequence: Int,
             tab: UUID, visit: UUID, presentation: UUID, diagnosticTrace: UUID? = nil) {
            self.view = view; self.owner = owner; self.prepared = prepared; self.sequence = sequence
            self.tab = tab; self.visit = visit; self.presentation = presentation
            self.diagnosticTrace = diagnosticTrace
        }
    }
    // Actual in-process source identity plus native sequence, never pasteboard strings.
    private static var activeSources: [ObjectIdentifier: ActiveSource] = [:]
    private struct ExternalKey: Equatable {
        let sequence: Int
        let board: NSPasteboard.Name
        let changeCount: Int
        let urls: [URL]
    }
    private struct ExternalSource {
        let key: ExternalKey
        let source: PreparedSource
    }
    private struct NativeDropKey: Hashable {
        let sequence: Int
        let board: NSPasteboard.Name
    }
    private struct NativeDropRequest {
        enum Payload {
            case prepared(BrowserDropRequest)
            case pendingExternal(BrowserPendingExternalDropRequest)
            case archive(ArchiveMemberDragOffer, ArchiveExtractionDestination)
            case sftp(RemoteDownloadDragOffer, ArchiveExtractionDestination)
        }
        let payload: Payload
        let context: Context
        let revision: UUID
        var operation: NSDragOperation {
            if case .prepared(let request) = payload { return request.move ? .move : .copy }
            return .copy
        }
    }
    private weak var browser: BrowserViewController?
    private var context: Context?
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    private var writerDiagnosticState: String?
    private var preparationDiagnosticTrace: UUID?
    private var externalPreparation: Task<Void, Never>?
    private var targetPreparation: Task<Void, Never>?
    private var preparingTarget: URL?
    private var targetPreparationID = UUID()
    private var failedTargets = Set<URL>()
    private var navigationPreparedTargets = Set<URL>()
    private var navigationObservations: [BrowserNotificationObservation] = []
    private var destinationViewsConfigured = false
    private var externalGeneration = UUID()
    private var externalKey: ExternalKey?
    private var externalSource: ExternalSource?
    private var objects: [URL: FileOperationSelection] = [:]
    private var cacheAccess = FileAccessLifetimes(leases: [])
    private var targets: [URL: PreparedTarget] = [:]
    private weak var observedClipView: NSClipView?
    private var visibleRowsObservation: BrowserNotificationObservation?
    private var admittedNativeDrops: [NativeDropKey] = []
    private var admittingNativeDrops = Set<NativeDropKey>()
    private var destinationActivationID = UUID()
    private var destinationActivationObservations: [BrowserNotificationObservation] = []
    var hooks = BrowserDragDropHooks()
    #if DEBUG
    var permitsVerification = false
    var sourcePreparationWaitForVerification: (@MainActor () async -> Void)?
    private(set) var targetPreparationCompletionCountForVerification = 0
    #endif

    init(browser: BrowserViewController) {
        self.browser = browser
        browser.table.registerForDraggedTypes([.fileURL, ArchiveMemberDragSource.pasteboardType,
            RemoteDownloadDrag.pasteboardType])
        browser.table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        browser.table.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.table.onDragVisibleRowsChanged = { [weak self] in self?.selectionDidChange() }
        browser.table.onFileDragExited = { [weak self] in self?.draggingExited() }
    }

    /// Registration and view-bound observations only. Sidebar/drive filesystem
    /// access begins for the hovered destination, never merely by showing it.
    func configureDestinationViews() {
        guard let browser, !destinationViewsConfigured else { return }
        destinationViewsConfigured = true
        // Resignation after admission revokes the deferred focus transition.
        // Observe the current attached window at delivery time: configuration
        // can run before attachment, and inactive windows can accept drops.
        destinationActivationObservations = [
            BrowserNotificationObservation(name: NSWindow.didResignKeyNotification) { [weak self] notification in
                let resignedWindowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let browser = self.browser, browser.isViewLoaded,
                          let resignedWindowID, let window = browser.view.window,
                          resignedWindowID == ObjectIdentifier(window) else { return }
                    self.destinationActivationID = UUID()
                }
            },
            BrowserNotificationObservation(name: NSApplication.didResignActiveNotification) { [weak self] _ in
                MainActor.assumeIsolated { self?.destinationActivationID = UUID() }
            },
        ]
        browser.outline.registerForDraggedTypes([.fileURL, ArchiveMemberDragSource.pasteboardType,
            RemoteDownloadDrag.pasteboardType])
        browser.iconBrowser.onPasteboardWriter = { [weak self] url in self?.pasteboardWriter(for: url) }
        browser.iconBrowser.onDragWillBegin = { [weak self, weak browser] session, urls in
            guard let browser else { return }
            self?.willBegin(session, urls: urls, sourceView: browser.iconBrowser.collectionView)
        }
        browser.iconBrowser.onDragEnded = { [weak self, weak browser] session in
            guard let browser else { return }
            self?.ended(session, sourceView: browser.iconBrowser.collectionView)
        }
        browser.iconBrowser.onValidateDrop = { [weak self] info, destination in self?.validateFileDrop(info, destination: destination) ?? [] }
        browser.iconBrowser.onAcceptDrop = { [weak self] info, destination in self?.acceptFileDrop(info, destination: destination) ?? false }
        browser.iconBrowser.onDragExited = { [weak self] in self?.draggingExited() }
        browser.iconBrowser.onVisibleEntriesChanged = { [weak self] in self?.selectionDidChange() }
        browser.outline.onFileDragExited = { [weak self] in self?.draggingExited() }
        browser.volumeBrowser.onValidateDrop = { [weak self] info, url in
            self?.validateDestinationDrop(info, destination: url) ?? []
        }
        browser.volumeBrowser.onAcceptDrop = { [weak self] info, url in
            self?.acceptDestinationDrop(info, destination: url) ?? false
        }
        browser.volumeBrowser.onDragExited = { [weak self] in self?.draggingExited() }
        browser.volumeBrowser.onVisibleDestinationsChanged = { [weak self] in self?.destinationsChanged() }
        if let clip = browser.outline.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            navigationObservations.append(BrowserNotificationObservation(name: NSView.boundsDidChangeNotification, object: clip) { [weak self] _ in
                MainActor.assumeIsolated { self?.destinationsChanged() }
            })
        }
        for name in [NSOutlineView.itemDidExpandNotification, NSOutlineView.itemDidCollapseNotification] {
            navigationObservations.append(BrowserNotificationObservation(name: name, object: browser.outline) { [weak self] _ in
                MainActor.assumeIsolated { self?.destinationsChanged() }
            })
        }
    }

    func destinationsChanged() { selectionDidChange() }

    /// Presentation metadata only; groups and unresolved saved grants have no
    /// destination. Expanding or drawing a saved folder never probes its target.
    func sidebarDestination(for item: Any?) -> URL? {
        guard let browser, let node = item as? SidebarNode, !node.group else { return nil }
        let row = browser.outline.row(forItem: node)
        guard row >= 0, browser.outline.rect(ofRow: row).intersects(browser.outline.visibleRect) else { return nil }
        let url: URL?
        if let id = browser.rememberedFolderSidebar.referenceID(for: node) {
            guard let reference = browser.rememberedFolders.first(where: { $0.id == id }),
                  case .resolvedUnverified = reference.state else { return nil }
            url = reference.url
        } else { url = node.location?.directoryURL }
        guard let url, browser.volumes.first(where: { $0.url == url })?.isReadOnly != true else { return nil }
        return url
    }

    private func navigationTargetURLs() -> [URL] {
        guard let browser else { return [] }
        var seen = Set<URL>()
        let rows = browser.outline.rows(in: browser.outline.visibleRect)
        let lower = rows.location == NSNotFound ? 0 : max(0, rows.location)
        let upper = min(browser.outline.numberOfRows, lower + min(rows.length, Self.maximumTargets))
        let sidebar = lower < upper ? (lower..<upper).compactMap { sidebarDestination(for: browser.outline.item(atRow: $0)) } : []
        let drives = browser.showsComputerVolumes ? browser.volumeBrowser.visibleDropURLs : []
        return Array((sidebar + drives).filter { seen.insert($0).inserted }.prefix(Self.maximumTargets))
    }

    private func cancelTargetPreparation() {
        targetPreparationID = UUID()
        targetPreparation?.cancel(); targetPreparation = nil; preparingTarget = nil
    }

    private func prepareDestination(_ url: URL) {
        guard enabled, let browser, let context, context == captureContext(),
              context.navigationTargets.contains(url), targets[url] == nil,
              !failedTargets.contains(url), preparingTarget != url else { return }
        cancelTargetPreparation()
        preparingTarget = url
        let revision = generation, targetRevision = targetPreparationID
        let observeTarget = hooks.observeTarget
        targetPreparation = Task { [weak self, fileOperations = browser.fileOperations] in
            guard let self else { return }
            defer {
                #if DEBUG
                self.targetPreparationCompletionCountForVerification += 1
                #endif
                if self.generation == revision && self.targetPreparationID == targetRevision && self.preparingTarget == url {
                    self.targetPreparation = nil; self.preparingTarget = nil
                }
            }
            let access = await browser.accessLifetime(for: [url])
            do {
                try await DragFileURLReader.shared.validate([url])
                let observed: FileOperationSelection
                if let observeTarget { observed = try await observeTarget(url) }
                else { observed = try await fileOperations.observeDirectory(url) }
                guard self.isCurrent(context, revision: revision), self.targetPreparationID == targetRevision,
                      self.preparingTarget == url else { return }
                self.targets[url] = PreparedTarget(observation: observed, access: access)
                self.navigationPreparedTargets.insert(url)
            } catch {
                guard self.isCurrent(context, revision: revision), self.targetPreparationID == targetRevision,
                      self.preparingTarget == url else { return }
                self.failedTargets.insert(url)
            }
        }
    }

    func validateDestinationDrop(_ info: NSDraggingInfo, destination: URL) -> NSDragOperation {
        // Collection visibility may settle after its parent's layout callback.
        // Recapture bounded presentation metadata before negotiating this hover.
        selectionDidChange()
        guard acceptsDrop, context?.navigationTargets.contains(destination) == true else { return [] }
        guard let expectedContext = context else { return [] }
        let expectedRevision = generation
        let preparedInput = input(info)
        guard preparedInput != nil || externalKey?.sequence == info.draggingSequenceNumber
            || ArchiveMemberDragSource.capture(info) != nil
            || RemoteDownloadDrag.capture(info) != nil else { return [] }
        guard isCurrent(expectedContext, revision: expectedRevision) else { return [] }
        prepareDestination(destination)
        let request = nativeRequest(info, destination: destination)
        guard isCurrent(expectedContext, revision: expectedRevision) else { return [] }
        return request?.operation ?? []
    }

    func acceptDestinationDrop(_ info: NSDraggingInfo, destination: URL) -> Bool {
        guard acceptsDrop, context?.navigationTargets.contains(destination) == true,
              let request = nativeRequest(info, destination: destination) else { return false }
        return admitNative(request, info: info)
    }

    nonisolated static func validURLs(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.count <= maximumItems && Set(urls).count == urls.count
            && urls.allSatisfy { $0.isFileURL && $0.query == nil && $0.fragment == nil
                && ($0.host == nil || $0.host == "" || $0.host == "localhost") && $0.path.hasPrefix("/") }
    }

    /// Pure negotiation over cached observations. An explicit unsupported intent
    /// refuses the drop rather than silently changing Move/Link into Copy.
    nonisolated static func operation(internalSource: Bool, sameFileSystem: Bool,
                                     modifiers: NSEvent.ModifierFlags, allowed: NSDragOperation) -> NSDragOperation {
        operation(internalSource: internalSource, sameFileSystem: sameFileSystem,
            modifiers: modifiers, allowed: allowed, controlAliases: false)
    }

    nonisolated static func operation(internalSource: Bool, sameFileSystem: Bool,
                                     modifiers: NSEvent.ModifierFlags, allowed: NSDragOperation,
                                     controlAliases: Bool) -> NSDragOperation {
        var keys = modifiers.intersection([.option, .command, .control])
        if keys.contains(.control) {
            // Explorer's Control-drag requests Copy. Control-Shift remains
            // unsupported Link intent; never silently reinterpret it as Copy.
            guard BrowserPointerSelection.isControlCopyDrag(modifiers, controlAliases: controlAliases) else { return [] }
            keys = .option
        }
        guard keys != [.option, .command] else { return [] }
        let desired: NSDragOperation
        if !internalSource {
            guard !keys.contains(.command) else { return [] }
            desired = .copy
        } else if keys.contains(.option) { desired = .copy }
        else if keys.contains(.command) { desired = .move }
        else { desired = sameFileSystem ? .move : .copy }
        return allowed.contains(desired) ? desired : []
    }

    private var enabled: Bool {
        guard let browser, !browser.isBrowserSuspended, !browser.isReadOnlyFileSession,
              !browser.isArchiveLocation, !browser.isRemoteLocation,
              !browser.isLoading, !browser.isOfflineCurrentFolder,
              !browser.metadataSearch.isShowingResults, browser.view.window != nil else { return false }
        #if DEBUG
        if browser.isVerificationSession && !permitsVerification { return false }
        #endif
        return true
    }
    private var acceptsDrop: Bool {
        guard enabled, let browser, !browser.hasExclusiveBrowserOperation,
              browser.operationCoordinator.transfers.canAdmit,
              browser.cutPreparationTask == nil, browser.view.window?.attachedSheet == nil,
              !(browser.view.window?.firstResponder is NSTextView), context == captureContext() else { return false }
        return browser.recoverableFileOperations != nil || hooks.admit != nil || hooks.admitPendingExternal != nil
    }

    private func captureContext() -> Context? {
        guard let browser else { return nil }
        let visible = Array(browser.visibleFileEntries.prefix(Self.maximumItems))
        let directory = browser.location.directoryURL
        var seen = Set<URL>()
        let folders = ([directory].compactMap { $0 } + visible.filter { $0.kind == .directory }
            .prefix(Self.maximumTargets).map(\.url)).filter { seen.insert($0).inserted }
        let selected = browser.selectedItemCount <= Self.maximumItems ? browser.orderedSelectedURLs : []
        let safeSelection = selected.count <= Self.maximumItems && selected.allSatisfy { url in
            guard let row = browser.rowsByURL[url], browser.displayedEntries.indices.contains(row) else { return false }
            return [.file, .directory, .package].contains(browser.displayedEntries[row].kind)
        }
        seen.removeAll()
        let visibleObjects = visible.filter { [.file, .directory, .package].contains($0.kind) }.map(\.url)
        let required = safeSelection ? selected : []
        let requiredSet = Set(required)
        let speculative = visibleObjects.filter { !requiredSet.contains($0) }.prefix(Self.maximumItems - required.count)
        let admitted = requiredSet.union(speculative)
        // Keep visible ordering stable when membership is unchanged. Simply
        // moving selection to the front would invalidate a warm cache on each
        // mouse-down, just before AppKit requests its synchronous drag writer.
        let pool = (visibleObjects + required).filter { admitted.contains($0) && seen.insert($0).inserted }
        return Context(tab: browser.activeID, visit: browser.sessionID,
                       window: browser.view.window.map(ObjectIdentifier.init),
                       fileView: ObjectIdentifier(browser.activeFileView), presentation: browser.filePresentationID,
                       sources: pool,
                       directory: directory, targets: folders, navigationTargets: navigationTargetURLs(), loading: browser.isLoading)
    }

    /// Call after a visit/selection/listing change and after visible rows scroll.
    /// Repeated status notifications with the same context do not cancel work.
    func selectionDidChange() {
        configureDestinationViews()
        observeVisibleRows()
        let next = captureContext()
        guard context != next else { return }
        context = next
        writerDiagnosticState = nil
        preparationDiagnosticTrace = nil
        generation = UUID(); preparation?.cancel(); preparation = nil
        cancelTargetPreparation(); failedTargets.removeAll()
        objects.removeAll(); cacheAccess = FileAccessLifetimes(leases: []); targets.removeAll(); draggingExited()
        guard enabled, let browser, let next else { return }
        let revision = generation
        let selected = Set(browser.orderedSelectedURLs)
        let sourceOrder = next.sources.filter { selected.contains($0) } + next.sources.filter { !selected.contains($0) }
        let diagnostic = ApplicationDiagnostics.shared.workflow(.drag, context: .init(.dragSources))
        preparationDiagnosticTrace = diagnostic.trace
        preparation = Task { [weak self, fileOperations = browser.fileOperations] in
            guard let self else { return }
            var checkpoint = DiagnosticCheckpoint.dragSources
            var ready = 0, failures = 0
            var firstError: DiagnosticErrorCode?, causes: [DiagnosticErrorCode]?
            var terminal = DiagnosticPhase.cancelled
            diagnostic.event(.preparing, context: .init(checkpoint), count: UInt64(sourceOrder.count))
            defer {
                diagnostic.event(terminal, context: .init(checkpoint), error: firstError, causes: causes, count: UInt64(ready))
                if self.generation == revision { self.preparation = nil }
            }
            let access = await browser.accessLifetime(for: next.sources + next.targets)
            guard self.isCurrent(next, revision: revision) else { return }
            self.cacheAccess = access
            // Prepare visible objects before selection changes enter AppKit's
            // synchronous mouse tracking loop. One unsupported row cannot
            // disable every other row in the viewport.
            for url in sourceOrder {
                guard self.isCurrent(next, revision: revision) else { return }
                #if DEBUG
                if browser.isVerificationSession { await self.sourcePreparationWaitForVerification?() }
                #endif
                guard self.isCurrent(next, revision: revision) else { return }
                do {
                    try await DragFileURLReader.shared.validate([url])
                    let observed = try await fileOperations.observeSelection([url])
                    guard self.isCurrent(next, revision: revision) else { return }
                    self.objects[url] = observed
                    ready += 1
                } catch {
                    guard self.isCurrent(next, revision: revision) else { return }
                    failures += 1
                    if firstError == nil { firstError = DiagnosticErrors.project(error); causes = DiagnosticErrors.causes(error) }
                }
            }
            diagnostic.event(failures == 0 ? .completed : ready == 0 ? .failed : .partial,
                context: .init(checkpoint), error: firstError, causes: causes, count: UInt64(ready))
            checkpoint = .dragTargets; ready = 0; failures = 0; firstError = nil; causes = nil
            diagnostic.event(.preparing, context: .init(checkpoint), count: UInt64(next.targets.count))
            for url in next.targets {
                guard self.isCurrent(next, revision: revision) else { return }
                do {
                    try await DragFileURLReader.shared.validate([url])
                    let observed = try await fileOperations.observeDirectory(url)
                    guard self.isCurrent(next, revision: revision) else { return }
                    self.targets[url] = PreparedTarget(observation: observed, access: access)
                    ready += 1
                } catch {
                    guard self.isCurrent(next, revision: revision) else { return }
                    failures += 1
                    if firstError == nil { firstError = DiagnosticErrors.project(error); causes = DiagnosticErrors.causes(error) }
                }
            }
            terminal = failures == 0 ? .completed : ready == 0 ? .failed : .partial
        }
    }

    private func observeVisibleRows() {
        guard let browser, !browser.isBrowserSuspended, browser.view.window != nil else { return }
        let clip = browser.activeFileScrollView.contentView
        guard observedClipView !== clip || visibleRowsObservation == nil else { return }
        visibleRowsObservation = nil
        observedClipView = clip
        clip.postsBoundsChangedNotifications = true
        visibleRowsObservation = BrowserNotificationObservation(name: NSView.boundsDidChangeNotification, object: clip) { [weak self] _ in
            // The observation wrapper delivers on OperationQueue.main. Keep cache
            // invalidation synchronous; its filesystem preparation remains async.
            MainActor.assumeIsolated { self?.selectionDidChange() }
        }
    }

    private func isCurrent(_ value: Context, revision: UUID) -> Bool {
        !Task.isCancelled && generation == revision && enabled && context == value && captureContext() == value
    }

    func pasteboardWriter(for row: Int) -> NSPasteboardWriting? {
        guard let browser, browser.activeFileView === browser.table,
              browser.displayedEntries.indices.contains(row) else {
            recordWriter(reason: [.wrongPresentation], count: 0); return nil
        }
        return pasteboardWriter(for: browser.displayedEntries[row].url)
    }

    private func recordWriter(reason: [DiagnosticStateFlag], count: UInt64) {
        let key = reason.map(\.rawValue).joined(separator: ",")
        guard writerDiagnosticState != key else { return }
        writerDiagnosticState = key
        ApplicationDiagnostics.shared.event(.drag, reason.isEmpty ? .admitted : .blocked, trace: preparationDiagnosticTrace,
            count: count, context: .init(.dragWriter, flags: reason.isEmpty ? [.sourceObserved] : reason))
    }

    func pasteboardWriter(for url: URL) -> NSPasteboardWriting? {
        guard let browser else { return nil }
        var reason: [DiagnosticStateFlag] = []
        if !enabled {
            if browser.isBrowserSuspended { reason.append(.browserSuspended) }
            if browser.isLoading { reason.append(.browserLoading) }
            if browser.isOfflineCurrentFolder { reason.append(.offline) }
            if browser.metadataSearch.isShowingResults { reason.append(.searchResults) }
            if reason.isEmpty { reason.append(.wrongPresentation) }
        } else if browser.location.directoryURL == nil { reason = [.computerView] }
        else if browser.hasExclusiveBrowserOperation { reason = [.exclusiveOperation] }
        else if browser.selectedItemCount == 0 { reason = [.selectionUnavailable] }
        else if browser.selectedItemCount > Self.maximumItems { reason = [.selectionTooLarge] }
        else if context != captureContext() { reason = [.contextChanged] }
        else if browser.rowsByURL[url] == nil || !browser.orderedSelectedURLs.contains(url) { reason = [.selectionUnavailable] }
        else if preparedSource(for: browser.orderedSelectedURLs) == nil {
            reason = [.sourceNotPrepared]; if preparation != nil { reason.append(.preparationPending) }
        }
        recordWriter(reason: reason, count: UInt64(browser.selectedItemCount))
        guard reason.isEmpty else { return nil }
        return url as NSURL
    }

    private func preparedSource(for urls: [URL]) -> PreparedSource? {
        guard Self.validURLs(urls), let firstURL = urls.first, var combined = objects[firstURL] else { return nil }
        for url in urls.dropFirst() {
            guard let object = objects[url] else { return nil }
            combined = combined.combining(object)
        }
        return PreparedSource(selection: combined, access: cacheAccess)
    }

    func willBegin(_ session: NSDraggingSession, rows: IndexSet) {
        guard let browser, rows.allSatisfy({ browser.displayedEntries.indices.contains($0) }) else { return }
        willBegin(session, urls: rows.map { browser.displayedEntries[$0].url }, sourceView: browser.table)
    }

    func willBegin(_ session: NSDraggingSession, urls: [URL], sourceView: NSView) {
        ApplicationDiagnostics.shared.event(.drag, .requested, trace: preparationDiagnosticTrace, count: UInt64(urls.count), context: .init(.dragSession))
        let sameContext = context == captureContext()
        let sameView = browser?.activeFileView === sourceView
        guard let browser, enabled, browser.location.directoryURL != nil, context == captureContext(),
              browser.activeFileView === sourceView, urls.count == browser.selectedItemCount,
              let source = preparedSource(for: urls),
              Set(source.selection.urls) == Set(browser.orderedSelectedURLs) else {
            ApplicationDiagnostics.shared.event(.drag, .blocked, trace: preparationDiagnosticTrace,
                count: UInt64(urls.count), context: .init(.dragSession,
                    flags: !sameContext ? [.contextChanged] : !sameView ? [.wrongPresentation] : [.sourceNotPrepared])); return
        }
        Self.activeSources = Self.activeSources.filter { $0.value.view != nil && $0.value.owner != nil }
        guard Self.activeSources.count < 16 else {
            ApplicationDiagnostics.shared.event(.drag, .blocked, trace: preparationDiagnosticTrace,
                context: .init(.dragSession, queueDepth: Self.activeSources.count)); return
        }
        Self.activeSources[ObjectIdentifier(sourceView)] = ActiveSource(view: sourceView, owner: self,
            prepared: source, sequence: session.draggingSequenceNumber, tab: browser.activeID,
            visit: browser.sessionID, presentation: browser.filePresentationID, diagnosticTrace: preparationDiagnosticTrace)
        ApplicationDiagnostics.shared.event(.drag, .admitted, trace: preparationDiagnosticTrace,
            count: UInt64(urls.count), context: .init(.dragSession, flags: [.sourceObserved]))
    }

    func ended(_ session: NSDraggingSession, sourceView: NSView? = nil) {
        let view = sourceView ?? browser?.table
        let active = view.flatMap { Self.activeSources[ObjectIdentifier($0)] }
        let trace = active?.owner === self && active?.sequence == session.draggingSequenceNumber ? active?.diagnosticTrace : nil
        ApplicationDiagnostics.shared.event(.drag, .finished, trace: trace, context: .init(.dragSession))
        endSource(sequence: session.draggingSequenceNumber, sourceView: sourceView)
    }

    private func endSource(sequence: Int, sourceView: NSView?) {
        guard let sourceView = sourceView ?? browser?.table,
              let entry = Self.activeSources[ObjectIdentifier(sourceView)], entry.owner === self,
              entry.sequence == sequence else { return }
        Self.activeSources.removeValue(forKey: ObjectIdentifier(sourceView))
        draggingExited()
        // Never move/delete based on the target's reported native operation.
    }

    private func sourceIsCurrent(_ active: ActiveSource) -> Bool {
        guard let browser, let view = active.view else { return false }
        return !browser.isBrowserSuspended && browser.view.window != nil
            && browser.activeFileView === view && browser.activeID == active.tab
            && browser.sessionID == active.visit && browser.filePresentationID == active.presentation
    }

    /// Snapshot the actual native local-source offer, never a remote row,
    /// archive token, promise or plain string. Acceptance later retains these
    /// leases; each receiving engine independently reopens/revalidates sources.
    static func captureLocalFileDropSource(_ info: NSDraggingInfo) -> LocalFileDropSource? {
        guard info.draggingSourceOperationMask.contains(.copy) else { return nil }
        let board = info.draggingPasteboard, change = board.changeCount
        let key = LocalFileDropKey(sequence: info.draggingSequenceNumber, board: board.name, changeCount: change)
        if let view = info.draggingSource as? NSView, let active = activeSources[ObjectIdentifier(view)] {
            guard active.view === view, let owner = active.owner, owner.sourceIsCurrent(active),
                  active.sequence == info.draggingSequenceNumber else { return nil }
            return .init(key: key, urls: active.prepared.selection.urls, access: active.prepared.access)
        }
        guard info.draggingSource == nil, let items = board.pasteboardItems, (1...maximumItems).contains(items.count),
              items.allSatisfy({ $0.types.contains(.fileURL) }),
              let objects = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]), objects.count == items.count else { return nil }
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        var seen = Set<Data>()
        guard urls.count == items.count, urls.allSatisfy({ url in
            let bytes = Data(url.path.utf8)
            return url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") && url.query == nil && url.fragment == nil
                && url.path.hasPrefix("/") && bytes.count <= 8192 && !bytes.contains(0) && url.path == url.standardizedFileURL.path && seen.insert(bytes).inserted
        }), board.changeCount == change else { return nil }
        return .init(key: key, urls: urls, access: .init(leases: []))
    }

    func windowWillClose() {
        destinationActivationID = UUID()
        destinationActivationObservations.removeAll()
        visibleRowsObservation = nil; observedClipView = nil
        navigationObservations.removeAll(); destinationViewsConfigured = false
        generation = UUID(); preparation?.cancel(); preparation = nil
        writerDiagnosticState = nil
        preparationDiagnosticTrace = nil
        cancelTargetPreparation(); failedTargets.removeAll()
        objects.removeAll(); cacheAccess = FileAccessLifetimes(leases: []); targets.removeAll(); context = nil; draggingExited()
        Self.activeSources = Self.activeSources.filter { $0.value.owner !== self && $0.value.view != nil && $0.value.owner != nil }
    }

    func draggingExited() {
        externalGeneration = UUID(); externalPreparation?.cancel(); externalPreparation = nil
        externalKey = nil; externalSource = nil
        cancelTargetPreparation()
        for url in navigationPreparedTargets where context?.targets.contains(url) != true { targets.removeValue(forKey: url) }
        navigationPreparedTargets.removeAll(); failedTargets.removeAll()
    }

    private func destination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        guard let browser else { return nil }
        if operation == .on && browser.displayedEntries.indices.contains(row) {
            let entry = browser.displayedEntries[row]
            return entry.kind == .directory ? entry.url : nil
        }
        return browser.location.directoryURL
    }

    private func input(_ info: NSDraggingInfo) -> (PreparedSource, Bool)? {
        if let view = info.draggingSource as? NSView,
           let active = Self.activeSources[ObjectIdentifier(view)] {
            guard active.view === view, let owner = active.owner, owner.sourceIsCurrent(active),
                  active.sequence == info.draggingSequenceNumber else { return nil }
            return (active.prepared, true)
        }
        if info.draggingSource is FileTableView || info.draggingSource is FileIconCollectionView
            || info.draggingSource is RemoteFileTableView { return nil }
        guard let key = readExternalKey(info) else { return nil }
        if let externalSource, externalSource.key == key { return (externalSource.source, false) }
        prepareExternal(key)
        return nil
    }

    private func readExternalKey(_ info: NSDraggingInfo) -> ExternalKey? {
        let board = info.draggingPasteboard
        if let externalKey, externalKey.sequence == info.draggingSequenceNumber,
           externalKey.board == board.name, externalKey.changeCount == board.changeCount { return externalKey }
        let changeCount = board.changeCount
        guard let items = board.pasteboardItems, !items.isEmpty, items.count <= Self.maximumItems,
              items.allSatisfy({ $0.types.contains(.fileURL) }),
              let objects = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              objects.count == items.count else { return nil }
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        guard Self.validURLs(urls), board.changeCount == changeCount else { return nil }
        return ExternalKey(sequence: info.draggingSequenceNumber, board: board.name, changeCount: changeCount, urls: urls)
    }

    private func prepareExternal(_ key: ExternalKey) {
        guard externalKey != key, let browser else { return }
        draggingExited(); externalKey = key
        let revision = externalGeneration, visit = browser.sessionID, tab = browser.activeID
        externalPreparation = Task { [weak self, fileOperations = browser.fileOperations] in
            guard let self else { return }
            defer { if self.externalGeneration == revision { self.externalPreparation = nil } }
            let access = await browser.accessLifetime(for: key.urls)
            do {
                try await DragFileURLReader.shared.validate(key.urls)
                let observed = try await fileOperations.observeSelection(key.urls)
                guard !Task.isCancelled, self.externalGeneration == revision, self.externalKey == key,
                      self.enabled, browser.sessionID == visit, browser.activeID == tab else { return }
                self.externalSource = ExternalSource(key: key, source: PreparedSource(selection: observed, access: access))
            } catch { /* Reject, preserving external sources. No private/body diagnostics. */ }
        }
    }

    private func request(source: PreparedSource, internalSource: Bool, destination: URL,
                         allowed: NSDragOperation, modifiers: NSEvent.ModifierFlags) -> BrowserDropRequest? {
        guard acceptsDrop, let target = targets[destination],
              source.selection.urls.allSatisfy({ url in
                  destination != url && !destination.path.hasPrefix(url.path.hasSuffix("/") ? url.path : url.path + "/")
              }) else { return nil }
        let operation = Self.operation(internalSource: internalSource,
            sameFileSystem: source.selection.sharesFileSystem(with: target.observation), modifiers: modifiers, allowed: allowed,
            controlAliases: browser?.settings.behavior.controlAliasesEnabled == true)
        guard !operation.isEmpty, operation != .move || source.selection.urls.allSatisfy({ $0.deletingLastPathComponent() != destination }) else { return nil }
        return BrowserDropRequest(sources: source.selection.urls, destination: destination, move: operation == .move,
            observation: source.selection.combining(target.observation),
            access: FileAccessLifetimes(leases: source.access.leases + target.access.leases),
            metadataPolicy: browser?.settings.transferMetadata.policy ?? .strict,
            copyExecution: operation == .move ? .standard : browser?.settings.copyExecutionRequest ?? .standard)
    }

    private func nativeRequest(_ info: NSDraggingInfo, destination: URL) -> NativeDropRequest? {
        guard let expectedContext = context else { return nil }
        let expectedRevision = generation
        if let offer = RemoteDownloadDrag.capture(info) {
            guard Self.operation(internalSource: false, sameFileSystem: false,
                    modifiers: NSEvent.modifierFlags, allowed: info.draggingSourceOperationMask,
                    controlAliases: browser?.settings.behavior.controlAliasesEnabled == true) == .copy,
                  expectedContext.targets.contains(destination) || expectedContext.navigationTargets.contains(destination),
                  let target = targets[destination], isCurrent(expectedContext, revision: expectedRevision) else { return nil }
            return NativeDropRequest(payload: .sftp(offer,.init(directory: destination,
                observation: target.observation,access: target.access)),
                context: expectedContext,revision: expectedRevision)
        }
        if let offer = ArchiveMemberDragSource.capture(info) {
            guard let browser, browser.canStartArchiveExtraction, ApplicationArchiveExtraction.shared.canAcceptPreparedSelection,
                  expectedContext.targets.contains(destination) || expectedContext.navigationTargets.contains(destination),
                  let target = targets[destination], isCurrent(expectedContext, revision: expectedRevision) else { return nil }
            return NativeDropRequest(payload: .archive(offer,.init(directory: destination,observation: target.observation,access: target.access)),
                context: expectedContext,revision: expectedRevision)
        }
        if let (source, internalSource) = input(info),
           let prepared = request(source: source, internalSource: internalSource, destination: destination,
               allowed: info.draggingSourceOperationMask, modifiers: NSEvent.modifierFlags) {
            guard isCurrent(expectedContext, revision: expectedRevision) else { return nil }
            return NativeDropRequest(payload: .prepared(prepared), context: expectedContext, revision: expectedRevision)
        }
        // No in-process source may bypass its authenticated prepared snapshot.
        guard info.draggingSource == nil, let browser, let context,
              context.targets.contains(destination) || context.navigationTargets.contains(destination),
              !failedTargets.contains(destination), let key = readExternalKey(info),
              Self.operation(internalSource: false, sameFileSystem: false,
                  modifiers: NSEvent.modifierFlags, allowed: info.draggingSourceOperationMask,
                  controlAliases: browser.settings.behavior.controlAliasesEnabled) == .copy,
              key.urls.allSatisfy({ destination != $0 && !destination.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }),
              isCurrent(expectedContext, revision: expectedRevision) else { return nil }
        let target = targets[destination]
        return NativeDropRequest(payload: .pendingExternal(BrowserPendingExternalDropRequest(sources: key.urls, destination: destination,
            targetObservation: target?.observation, access: target?.access ?? FileAccessLifetimes(leases: []),
            metadataPolicy: browser.settings.transferMetadata.policy, copyExecution: browser.settings.copyExecutionRequest)),
            context: expectedContext, revision: expectedRevision)
    }

    func validateFileDrop(_ info: NSDraggingInfo, destination: URL?) -> NSDragOperation {
        selectionDidChange()
        guard let browser, browser.activeFileView === browser.iconBrowser.collectionView,
              acceptsDrop, let destination = destination ?? browser.location.directoryURL,
              context?.targets.contains(destination) == true,
              let request = nativeRequest(info, destination: destination) else { return [] }
        return request.operation
    }

    func acceptFileDrop(_ info: NSDraggingInfo, destination: URL?) -> Bool {
        guard let browser, browser.activeFileView === browser.iconBrowser.collectionView,
              acceptsDrop, let destination = destination ?? browser.location.directoryURL,
              context?.targets.contains(destination) == true,
              let request = nativeRequest(info, destination: destination) else { return false }
        return admitNative(request, info: info)
    }

    func validateDrop(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let browser, browser.activeFileView === browser.table,
              acceptsDrop, let destination = destination(row: row, operation: operation),
              let request = nativeRequest(info, destination: destination) else { return [] }
        browser.table.setDropRow(operation == .on && row >= 0 ? row : -1, dropOperation: .on)
        return request.operation
    }

    func acceptDrop(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> Bool {
        guard let browser, browser.activeFileView === browser.table,
              acceptsDrop, let destination = destination(row: row, operation: operation),
              let request = nativeRequest(info, destination: destination) else { return false }
        return admitNative(request, info: info)
    }

    private func admitNative(_ request: NativeDropRequest, info: NSDraggingInfo) -> Bool {
        let diagnostic = ApplicationDiagnostics.shared.begin(.drop)
        var accepted = false
        defer { ApplicationDiagnostics.shared.event(.drop, accepted ? .admitted : .blocked, trace: diagnostic) }
        let key = NativeDropKey(sequence: info.draggingSequenceNumber,
                                board: info.draggingPasteboard.name)
        guard isCurrent(request.context, revision: request.revision), acceptsDrop else { return false }
        guard !admittedNativeDrops.contains(key), admittingNativeDrops.insert(key).inserted else { return false }
        // Admission may synchronously re-enter native callbacks. Reserve before
        // invoking the queue/hook, but release a refused admission for a retry.
        // Lazy pasteboard materialization may change its revision; the native
        // session still gets only one admission with its first captured input.
        defer { admittingNativeDrops.remove(key) }
        switch request.payload {
        case .prepared(let request): guard admit(request) else { return false }
        case .pendingExternal(let request): guard admitPendingExternal(request) else { return false }
        case .archive(let offer,let destination):
            guard let browser, ArchiveMemberDragSource.admit(offer,perform: {
                offer.copy(to: browser,destination: destination) { [weak self] in
                    self?.isCurrent(request.context,revision: request.revision) == true && self?.acceptsDrop == true
                }
            }) else { return false }
            activateDestinationForAdmission()
        case .sftp(let offer, let destination):
            guard offer.admit(to: destination, current: { [weak self] in
                self?.isCurrent(request.context, revision: request.revision) == true && self?.acceptsDrop == true
            }) else { return false }
            activateDestinationForAdmission()
        }
        admittedNativeDrops.append(key)
        accepted = true
        if admittedNativeDrops.count > 32 { admittedNativeDrops.removeFirst(admittedNativeDrops.count - 32) }
        return true
    }

    private func admitPendingExternal(_ request: BrowserPendingExternalDropRequest) -> Bool {
        guard acceptsDrop, let browser else { return false }
        #if DEBUG
        if browser.isVerificationSession && hooks.admitPendingExternal == nil { return false }
        #endif
        if let callback = hooks.admitPendingExternal { return callback(request) }
        guard request.enqueue(in: browser) != nil else { return false }
        activateDestinationForAdmission()
        return true
    }

    private func admit(_ request: BrowserDropRequest) -> Bool {
        guard acceptsDrop, let browser else { return false }
        #if DEBUG
        if browser.isVerificationSession && hooks.admit == nil { return false }
        #endif
        if let callback = hooks.admit { return callback(request) }
        guard let engine = browser.recoverableFileOperations else { return false }
        guard browser.operationCoordinator.transfers.enqueue(sources: request.sources, destination: request.destination,
            move: request.move, title: request.move ? "Moving dropped items…" : "Copying dropped items…",
            origin: browser, engine: engine, observation: request.observation, retaining: request.access,
            metadataPolicy: request.metadataPolicy, copyExecution: request.copyExecution) != nil else { return false }
        activateDestinationForAdmission()
        return true
    }

    private func activateDestinationForAdmission() {
        guard let browser, let window = browser.view.window else { return }
        let tab = browser.activeID, visit = browser.sessionID, presentation = browser.filePresentationID
        let pane = browser.workspace?.activePaneID
        let precedingResponder = window.firstResponder
        destinationActivationID = UUID()
        let activation = destinationActivationID
        // Native drag tracking keeps its source until the callback returns.
        // Transition pane ownership and file focus together on the default
        // run loop, rather than exposing an active pane with another responder.
        RunLoop.main.perform(inModes: [.default]) { [weak self, weak window, weak precedingResponder] in
            MainActor.assumeIsolated {
                guard let self, let browser = self.browser, let window,
                      self.destinationActivationID == activation, !browser.isBrowserSuspended,
                      browser.view.window === window, browser.activeID == tab, browser.sessionID == visit,
                      browser.filePresentationID == presentation, browser.workspace?.activePaneID == pane,
                      window.attachedSheet == nil,
                      window.firstResponder === precedingResponder || window.firstResponder === browser.activeFileView else { return }
                browser.workspace?.activate(browser, focus: true)
                if browser.workspace == nil { browser.focusBrowserContent() }
                if !browser.isControlledVerification { window.makeKeyAndOrderFront(nil) }
            }
        }
    }

    #if DEBUG
    var verificationState: (preparing: Bool, readySource: Bool, readyTargets: Int, external: Bool) {
        (preparation != nil || externalPreparation != nil || targetPreparation != nil,
         browser.map { $0.selectedItemCount <= Self.maximumItems && preparedSource(for: $0.orderedSelectedURLs) != nil } ?? false,
         targets.count, externalSource != nil)
    }
    func hasPreparedObjectForVerification(_ url: URL) -> Bool { objects[url] != nil }
    func hasPreparedDestinationForVerification(_ url: URL) -> Bool { targets[url] != nil }
    func preparedDestinationForVerification(_ url: URL) -> ArchiveExtractionDestination? {
        guard let target = targets[url] else { return nil }
        return .init(directory: url, observation: target.observation, access: target.access)
    }
    var navigationCandidatesForVerification: [URL] { context?.navigationTargets ?? [] }
    func registerSourceForVerification(sequence: Int) -> Bool {
        guard let browser, browser.selectedItemCount <= Self.maximumItems,
              let source = preparedSource(for: browser.orderedSelectedURLs) else { return false }
        let view = browser.activeFileView
        Self.activeSources[ObjectIdentifier(view)] = ActiveSource(view: view, owner: self,
            prepared: source, sequence: sequence, tab: browser.activeID, visit: browser.sessionID,
            presentation: browser.filePresentationID)
        return true
    }
    func endSourceForVerification() {
        Self.activeSources = Self.activeSources.filter { $0.value.owner !== self }
    }
    func endSourceForVerification(sequence: Int) { endSource(sequence: sequence, sourceView: browser?.activeFileView) }
    func hasSourceAuthorityForVerification(sequence: Int) -> Bool {
        guard let view = browser?.activeFileView, let active = Self.activeSources[ObjectIdentifier(view)],
              active.owner === self, active.sequence == sequence else { return false }
        return sourceIsCurrent(active)
    }
    /// Exercises only the exact production context/focus transition. No job is
    /// enqueued and normal --verify-ui native mutation admission remains denied.
    func activateDestinationForAdmissionForVerification(from sourceController: BrowserDragDropController,
                                                        ownedFixtureRoot: URL) async -> Bool {
        guard permitsVerification, let browser, browser.isVerificationSession,
              let sourceView = sourceController.browser?.activeFileView,
              let active = Self.activeSources[ObjectIdentifier(sourceView)], sourceController.sourceIsCurrent(active),
              let destination = browser.location.directoryURL,
              let captured = request(source: active.prepared, internalSource: true, destination: destination,
                                     allowed: [.copy, .move], modifiers: []),
              let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { return false }
        let revision = generation
        let allowed = await Task.detached { () -> Bool in
            let declaredRoot = URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL
            let root = ownedFixtureRoot.standardizedFileURL
            guard declaredRoot == declaredRoot.resolvingSymlinksInPath(), root == ownedFixtureRoot,
                  root == root.resolvingSymlinksInPath(), root.path.hasPrefix(declaredRoot.path + "/"),
                  (captured.sources + [captured.destination]).allSatisfy({ url in
                      url.isFileURL && url == url.standardizedFileURL && url == url.resolvingSymlinksInPath()
                        && url.path.hasPrefix(root.path + "/")
                  }) else { return false }
            let marker = root.appendingPathComponent(".fixture-owner")
            guard marker == marker.resolvingSymlinksInPath(),
                  let size = try? marker.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64,
                  let data = try? Data(contentsOf: marker) else { return false }
            return data == Data("mac-explorer-workspace-transfer-v1".utf8)
        }.value
        guard allowed, permitsVerification, browser.isVerificationSession, generation == revision,
              acceptsDrop, sourceController.sourceIsCurrent(active) else { return false }
        activateDestinationForAdmission()
        return true
    }
    func dropForVerification(from sourceController: BrowserDragDropController?, urls: [URL], destination: URL,
                             moveModifier: NSEvent.ModifierFlags = [], allowed: NSDragOperation = [.copy, .move]) async -> Bool {
        let prepared: PreparedSource
        if let sourceController {
            guard let view = sourceController.browser?.activeFileView,
                  let active = Self.activeSources[ObjectIdentifier(view)], sourceController.sourceIsCurrent(active) else { return false }
            prepared = active.prepared
        } else {
            guard let browser else { return false }
            do {
                try await DragFileURLReader.shared.validate(urls)
                let observation = try await browser.fileOperations.observeSelection(urls)
                prepared = PreparedSource(selection: observation, access: await browser.accessLifetime(for: urls))
            } catch { return false }
        }
        guard let value = request(source: prepared, internalSource: sourceController != nil, destination: destination,
                                  allowed: allowed, modifiers: moveModifier) else { return false }
        return admit(value)
    }
    #endif
}
