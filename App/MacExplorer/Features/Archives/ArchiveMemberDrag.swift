import AppKit
import FileOperations
import LocalStorage

enum ArchiveMemberDragActivation {
    static let enabled = true
    static var available: Bool {
        guard AppFeatureAvailability.allows(.archiveInternalTransfers) else { return false }
        #if DEBUG
        return enabled || ProcessInfo.processInfo.arguments.contains("--check-archive-member-drag")
        #else
        return enabled
        #endif
    }
}

/// Concrete directory intent and already-held access from the receiving browser.
/// The operation worker must still compare the observed directory at preparation.
struct ArchiveExtractionDestination {
    let directory: URL
    let observation: FileOperationSelection
    let access: FileAccessLifetimes
    /// A UI directory URL can omit the trailing slash that the engine's
    /// canonical directory observation includes. Compare the exact path here;
    /// the engine still revalidates the observed filesystem identity at use.
    var matchesObservedDirectory: Bool {
        guard directory.isFileURL, observation.urls.count == 1,
              let observed = observation.urls.first, observed.isFileURL else { return false }
        return directory.path.utf8.elementsEqual(observed.path.utf8)
    }
}

enum ArchivePreparedSelection {
    case zipMembers(ZIPExtractionSelection)
    case zipRoot(ZIPRootExportSelection)
    case tar(TARExtractionSelection)
}

/// Both explicit extraction and native file promises prepare one selected ZIP
/// root through the same operation owner. Each route supplies only the public
/// contracts it independently admits; this does not grant destination access.
enum ZIPRootExtractionPreparation {
    static func prepare(_ root: ZIPRootExportSelection, engine: RecoverableFileOperations,
                        parent: URL, name: String, observing destination: FileOperationSelection,
                        publicFile: Bool, publicTree: Bool) async throws -> ZIPRootExportPlan {
        if root.kind == .file && publicFile {
            return try await engine.prepareZIPRootFilePublicExtraction(root,
                parent: parent, name: name, observing: destination)
        }
        return try await engine.prepareZIPRootExport(root, parent: parent, name: name,
            observing: destination, publicQuarantineTreeV16: publicTree)
    }
}

/// One ordinary clipboard destination, shared by ZIP and TAR. The source
/// model owns and drains the task; this value only binds its destination visit.
@MainActor struct ArchiveLocalPaste {
    private let context: ScopedItemPaste
    private let target: BrowserViewController
    private let tab: UUID, visit: UUID, directory: URL
    private let engine: RecoverableFileOperations

    init?(_ context: ScopedItemPaste, to target: BrowserViewController) {
        guard ArchiveMemberDragActivation.available,
              context.intent.operation == .copy, context.isCurrent(), target.canPasteArchiveIntoLocalFolder,
              let directory = target.location.directoryURL, let engine = target.recoverableFileOperations else { return nil }
        self.context = context; self.target = target; self.directory = directory; self.engine = engine
        tab = target.activeID; visit = target.sessionID
        target.status.stringValue = "Checking the archive and destination…"
    }

    private var destinationIsCurrent: Bool {
        !Task.isCancelled && target.activeID == tab && target.sessionID == visit && target.location.directoryURL == directory
            && target.canPasteArchiveIntoLocalFolder && target.recoverableFileOperations === engine
    }

    func present(_ selection: ArchivePreparedSelection, source: URL, from origin: BrowserViewController) async throws {
        guard destinationIsCurrent else { return }
        guard context.isCurrent(), !origin.isBrowserSuspended else { staleSource(); return }
        let sourceAccess = await origin.accessLifetime(for: [source])
        let access = await target.accessLifetime(for: [directory])
        let observation = try await engine.observeSelection([directory])
        guard destinationIsCurrent else { return }
        guard context.isCurrent(), !origin.isBrowserSuspended else { staleSource(); return }
        let destination = ArchiveExtractionDestination(directory: directory, observation: observation, access: access)
        if ApplicationArchiveExtraction.shared.showSelection(source: source, from: target, selection: selection,
            destination: destination, sourceAccess: sourceAccess, presentation: .paste) {
            target.status.stringValue = "Checking the copy destination…"
        } else { target.status.stringValue = "The destination is no longer ready. Paste into its current folder again." }
    }

    private func staleSource() { target.status.stringValue = "The copied archive selection changed. Copy the items again." }

    func report(_ error: Error) {
        if destinationIsCurrent { target.status.stringValue = ArchiveExtractionModel.message(error) }
    }
}

/// No paths or contents are serialized. This capture remains local to one native
/// archive owner, whose current selection/page must survive every async handoff.
@MainActor final class ArchiveMemberDragOffer {
    enum Members: Equatable {
        case zip(Set<ZIPItemID>)
        case tar(Set<TARItemID>)
        var count: Int { switch self { case .zip(let ids): ids.count; case .tar(let ids): ids.count } }
    }
    let token = UUID()
    weak var model: ArchiveBrowserModel?
    weak var tarModel: TARBrowserModel?
    let generation: UUID, page: UUID
    let members: Members
    /// ZIP's existing authoring commands also use this offer. A TAR offer has
    /// no ZIP IDs or ZIP owner and cannot become a Move within a ZIP archive.
    var ids: Set<ZIPItemID> { if case .zip(let ids) = members { ids } else { [] } }
    var tarIDs: Set<TARItemID> { if case .tar(let ids) = members { ids } else { [] } }
    let externalExport: ArchivePromiseExport?
    fileprivate(set) var admitted = false
    init(model: ArchiveBrowserModel, generation: UUID, page: UUID, ids: Set<ZIPItemID>, externalExport: ArchivePromiseExport? = nil) {
        self.model = model; self.generation = generation; self.page = page; members = .zip(ids)
        self.externalExport = externalExport
    }
    init(tar: TARBrowserModel, generation: UUID, page: UUID, ids: Set<TARItemID>) {
        tarModel = tar; self.generation = generation; self.page = page; members = .tar(ids); externalExport = nil
    }
    var isCurrent: Bool { model?.isCurrentMemberDrag(self) == true || tarModel?.isCurrentMemberDrag(self) == true }
    var canStart: Bool { model?.canStartMemberDrag(ids) == true || tarModel?.canStartMemberDrag(tarIDs) == true }
    var canExtract: Bool { model?.canExtractSelection(ids) == true || tarModel?.canStartMemberDrag(tarIDs) == true }
    func copy(to browser: BrowserViewController, destination: ArchiveExtractionDestination,
        isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        if let model { return model.extractDropped(self, to: browser, destination: destination, isCurrent: isCurrent) }
        return tarModel?.extractDropped(self, to: browser, destination: destination, isCurrent: isCurrent) == true
    }
}

/// One native table source. A marker alone is never authority: the receiver also
/// requires this actual table, active native sequence and original live capture.
@MainActor final class ArchiveMemberDragSource {
    enum Purpose { case extract, moveWithinArchive }
    nonisolated static let pasteboardType = NSPasteboard.PasteboardType("com.respawnstudios.traverse.archive-member-selection")
    static let maximumItems = 128
    private weak var model: ArchiveBrowserModel?
    private weak var tarModel: TARBrowserModel?
    private weak var table: ArchiveMetadataTable?
    private var draft: ArchiveMemberDragOffer?
    private var active: (sequence: Int, board: NSPasteboard.Name, revision: Int,
        types: [[NSPasteboard.PasteboardType]], offer: ArchiveMemberDragOffer)?
    #if DEBUG
    private(set) var writerRequestsForVerification = 0
    private(set) var beginCountForVerification = 0
    private(set) var endCountForVerification = 0
    static private(set) var lastCaptureReasonForVerification = "none"
    static private(set) var lastSourceKindForVerification = "none"
    static private(set) var captureCallsForVerification = 0
    static private(set) var lastMaskForVerification: UInt = 0
    static func resetDiagnosticsForVerification() { captureCallsForVerification = 0; lastCaptureReasonForVerification = "none"; lastSourceKindForVerification = "none" }
    #endif
    init(model: ArchiveBrowserModel, table: ArchiveMetadataTable) { self.model = model; self.table = table }
    init(tar: TARBrowserModel, table: ArchiveMetadataTable) { tarModel = tar; self.table = table }
    func writer(ids: Set<ZIPItemID>, item: ZIPArchiveItem? = nil) -> NSPasteboardWriting? {
        #if DEBUG
        writerRequestsForVerification += 1
        #endif
        guard let model, let table, table.window != nil,
              (1...Self.maximumItems).contains(ids.count), ids == model.selection,
              model.canStartMemberDrag(ids) else { return nil }
        if draft?.admitted == true || draft?.ids != ids || (draft.map({ !model.isCurrentMemberDrag($0) }) ?? true)
            || (ArchivePromiseExportFeature.available && draft?.externalExport == nil && model.externalExportReady) {
            draft = model.captureMemberDrag(ids)
        }
        guard let draft else { return nil }
        if let item, let provider = draft.externalExport?.provider(for: item, marker: draft.token) { return provider }
        return opaqueWriter(draft)
    }
    func writer(tarIDs ids: Set<TARItemID>) -> NSPasteboardWriting? {
        guard let tarModel, table?.window != nil, tarModel.canStartMemberDrag(ids) else { return nil }
        if draft?.admitted == true || draft?.members != .tar(ids) || draft?.isCurrent != true {
            draft = tarModel.captureMemberDrag(ids)
        }
        return draft.map(opaqueWriter)
    }
    private func opaqueWriter(_ offer: ArchiveMemberDragOffer) -> NSPasteboardItem {
        let item = NSPasteboardItem(); item.setString(offer.token.uuidString, forType: Self.pasteboardType)
        return item
    }
    func begin(sequence: Int, ids: Set<ZIPItemID>, board: NSPasteboard) {
        begin(sequence: sequence, members: .zip(ids), board: board)
    }
    func begin(sequence: Int, tarIDs: Set<TARItemID>, board: NSPasteboard) {
        begin(sequence: sequence, members: .tar(tarIDs), board: board)
    }
    private func begin(sequence: Int, members: ArchiveMemberDragOffer.Members, board: NSPasteboard) {
        #if DEBUG
        beginCountForVerification += 1
        #endif
        guard let draft, draft.members == members, draft.isCurrent, draft.canStart,
              table?.window != nil else { active = nil; return }
        guard let items = board.pasteboardItems, items.count == members.count,
              items.allSatisfy({ $0.types.contains(Self.pasteboardType) }) else { active = nil; return }
        active = (sequence,board.name,board.changeCount,items.map(\.types),draft)
        ApplicationDiagnostics.shared.event(.drag, .admitted, trace: draft.token, count: UInt64(members.count), context: .init(.dragSession))
        if draft.externalExport?.handOff(diagnosticTrace: draft.token) == true { model?.memberDragDidHandOff(draft) }
    }
    func end(sequence: Int, operation: NSDragOperation = .copy) {
        #if DEBUG
        endCountForVerification += 1
        #endif
        guard let active, active.sequence == sequence else { return }
        if operation.isEmpty { active.offer.externalExport?.retireUncalled() }
        active.offer.model?.memberDragDidEnd(active.offer)
        self.active = nil; draft = nil
    }
    func retire() {
        active?.offer.externalExport?.retireUncalled(); draft?.externalExport?.retireUnlessHanded()
        active = nil; draft = nil
    }
    static func capture(_ info: NSDraggingInfo, for purpose: Purpose = .extract) -> ArchiveMemberDragOffer? {
        #if DEBUG
        captureCallsForVerification += 1; lastMaskForVerification = info.draggingSourceOperationMask.rawValue
        lastSourceKindForVerification = info.draggingSource.map { String(String(describing:type(of:$0)).prefix(64)) } ?? "none"
        lastCaptureReasonForVerification = "copy-mask"
        #endif
        let enabled = switch purpose {
        case .extract: ArchiveMemberDragActivation.available && info.draggingSourceOperationMask.contains(.copy)
        case .moveWithinArchive: (ZIPOriginalUpdateFeature.available || TARArchiveEditingFeature.available)
            && info.draggingSourceOperationMask.contains(.move)
        }
        guard enabled else { return nil }
        #if DEBUG
        lastCaptureReasonForVerification = "native-source"
        #endif
        guard let source = info.draggingSource as? ArchiveMetadataTable,
              let owner = source.memberDragSource, owner.table === source else { return nil }
        #if DEBUG
        lastCaptureReasonForVerification = "native-sequence"
        #endif
        guard let active = owner.active, active.sequence == info.draggingSequenceNumber,
              !active.offer.admitted else { return nil }
        #if DEBUG
        lastCaptureReasonForVerification = "source-snapshot"
        #endif
        guard active.offer.isCurrent else { return nil }
        #if DEBUG
        lastCaptureReasonForVerification = "source-command-state"
        #endif
        func eligible() -> Bool {
            switch purpose {
            case .extract: active.offer.canExtract
            case .moveWithinArchive: active.offer.model?.canMoveMembers(active.offer.ids) == true
                || active.offer.tarModel?.canMoveMembers(active.offer.tarIDs) == true
            }
        }
        guard eligible() else { return nil }
        let board = info.draggingPasteboard
        #if DEBUG
        lastCaptureReasonForVerification = "board-metadata"
        #endif
        // The source object and native sequence authorize the captured IDs.
        // Never load pasteboard representations in synchronous hover callbacks:
        // even an opaque marker could be replaced with an unbounded payload.
        guard board.name == active.board, board.changeCount == active.revision, let items = board.pasteboardItems,
              items.count == active.offer.members.count, items.map(\.types) == active.types,
              items.allSatisfy({ $0.types.contains(pasteboardType) }),
              board.changeCount == active.revision, !active.offer.admitted,
              active.offer.isCurrent, eligible() else { return nil }
        #if DEBUG
        lastCaptureReasonForVerification = "accepted-capture"
        #endif
        return active.offer
    }
    /// Reserve once before entering a callback which may synchronously reenter.
    static func admit(_ offer: ArchiveMemberDragOffer, perform: () -> Bool) -> Bool {
        guard !offer.admitted else { return false }
        offer.admitted = true
        offer.externalExport?.retireUncalled()
        guard perform() else { offer.admitted = false; return false }
        return true
    }
}
