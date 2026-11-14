import AppKit
@_spi(Qualification) import LocalStorage

/// The native source and sequence authorize a sealed selection. The marker is
/// only a dragged type for AppKit negotiation and is never decoded on hover.
@MainActor final class RemoteDownloadDragOffer {
    enum Selection {
        case single(SFTPFilePromiseExport)
        case batch(SFTPDownloadBatchPlan)
        case folder(SFTPFolderDownloadSelection)
        case smbFile(SMBDownloadSelection)
        case smbFiles(SMBDownloadBatchPlan)
        case smbFolder(SMBFolderDownloadSelection)
    }
    let token: UUID, rows: IndexSet, selection: Selection
    weak var browser: BrowserViewController?, owner: SFTPTabController?, table: RemoteFileTableView?
    private weak var smbOwner: SMBTabController?
    private(set) var admitted = false
    private var writtenRows = Set<Int>()
    var wroteEveryRow: Bool {
        switch selection {
        case .single(let job): rows.count == 1 && job.hasPreparedWriter
        case .batch, .folder, .smbFile, .smbFiles, .smbFolder: writtenRows == Set(rows)
        }
    }

    init(browser: BrowserViewController, owner: SFTPTabController, rows: IndexSet,
         selection: Selection, token: UUID = UUID()) {
        self.browser = browser; self.owner = owner; table = owner.rows.table
        self.rows = rows; self.selection = selection; self.token = token
    }
    init(browser: BrowserViewController, owner: SMBTabController, rows: IndexSet, selection: Selection) {
        self.browser = browser; smbOwner = owner; table = owner.rows.table
        self.rows = rows; self.selection = selection; token = UUID()
    }
    func markerWriter(for row: Int) -> NSPasteboardItem {
        writtenRows.insert(row)
        let item = NSPasteboardItem()
        item.setString(token.uuidString, forType: RemoteDownloadDrag.pasteboardType)
        return item
    }
    func isCurrent() -> Bool {
        guard !admitted, let browser, let table, table.window != nil,
              table.selectedRowIndexes == rows, !browser.isBrowserSuspended,
              !ApplicationFileActivity.gate.isClosed else { return false }
        if let owner {
            guard SFTPFilePromiseFeature.internalAvailable, owner.rows.table === table,
                  browser.sftpTabs[browser.activeID] === owner, !owner.isClosing,
                  owner.session.latest.failure == nil else { return false }
        switch selection {
        case .single(let job):
            return rows.count == 1 && job.canReceiveInternal
                && job.candidate.matches(owner.rows.selectedDownload)
        case .batch(let plan):
            return (2...SFTPDownloadBatchPlan.maximumFiles).contains(rows.count)
                && RemoteBatchDownloadSource(owner)?.matchesSFTP(plan) == true
                && browser.remoteBatchDownload.canRequest(from: owner)
        case .folder(let selected):
            return rows.count == 1
                && Self.matchesFolder(selected, owner.rows.selectedFolderDownload)
                && browser.sftpFolderDownload.canRequest(from: owner)
        case .smbFile, .smbFiles, .smbFolder: return false
        }
        }
        guard RemoteDownloadDrag.smbAvailable, let owner = smbOwner, owner.rows.table === table,
              browser.smbTabs[browser.activeID] === owner, !owner.isClosing,
              owner.session.latest.failure == nil else { return false }
        switch selection {
        case .smbFile(let selected):
            return rows.count == 1 && Self.matchesFile(selected, owner.selectedDownload)
                && browser.smbDownload.canRequest(from: owner)
        case .smbFiles(let plan):
            return RemoteBatchDownloadSource(owner)?.matchesSMB(plan) == true
                && browser.remoteBatchDownload.canRequest(from: owner)
        case .smbFolder(let selected):
            return rows.count == 1 && Self.matchesFolder(selected, owner.selectedFolderDownload)
                && browser.smbFolderDownload.canRequest(from: owner)
        case .single, .batch, .folder: return false
        }
    }
    static func matchesFolder(_ selected: SFTPFolderDownloadSelection,
        _ current: SFTPFolderDownloadSelection?) -> Bool {
        current?.generation == selected.generation && current?.read == selected.read
            && current?.revision == selected.revision && current?.row == selected.row
    }
    static func matchesFile(_ selected: SMBDownloadSelection, _ current: SMBDownloadSelection?) -> Bool {
        current?.connection == selected.connection && current?.snapshot == selected.snapshot
            && current?.observation == selected.observation
    }
    static func matchesFolder(_ selected: SMBFolderDownloadSelection, _ current: SMBFolderDownloadSelection?) -> Bool {
        current?.connection == selected.connection && current?.snapshot == selected.snapshot
            && current?.observation == selected.observation
    }
    /// Reserve before entering the operation owner; native callbacks can
    /// reenter synchronously. A rejected admission leaves the offer retryable.
    func admit(to destination: ArchiveExtractionDestination,
        current: @escaping @MainActor () -> Bool) -> Bool {
        guard isCurrent(), let browser, current() else { return false }
        admitted = true
        let accepted: Bool
        switch selection {
        case .single(let job): accepted = job.requestInternal(to: destination, current: current)
        case .batch(let plan):
            guard let owner else { admitted = false; return false }
            accepted = browser.remoteBatchDownload.requestDropped(from: owner, expected: plan,
                destination: destination, current: current)
        case .folder(let selected):
            guard let owner else { admitted = false; return false }
            accepted = browser.sftpFolderDownload.requestDropped(from: owner, expected: selected,
                destination: destination, current: current)
        case .smbFile(let selected):
            guard let owner = smbOwner else { admitted = false; return false }
            accepted = browser.smbDownload.requestDropped(from: owner, expected: selected,
                destination: destination, current: current)
        case .smbFiles(let plan):
            guard let owner = smbOwner else { admitted = false; return false }
            accepted = browser.remoteBatchDownload.requestDropped(from: owner, expected: plan,
                destination: destination, current: current)
        case .smbFolder(let selected):
            guard let owner = smbOwner else { admitted = false; return false }
            accepted = browser.smbFolderDownload.requestDropped(from: owner, expected: selected,
                destination: destination, current: current)
        }
        if !accepted { admitted = false }
        return accepted
    }
}

@MainActor enum RemoteDownloadDrag {
    static let smbEnabledInPreview = true
    static var smbAvailable: Bool {
        guard RemoteDownloadPublicationFeature.smbSingleFileAvailable, SMBDownloadFeature.available else { return false }
        #if DEBUG
        if SMBDownloadFeature.qualifying { return true }
        #endif
        return smbEnabledInPreview
    }
    nonisolated static let pasteboardType = NSPasteboard.PasteboardType("com.respawnstudios.traverse.remote-selected-download")
    private final class Active {
        weak var table: RemoteFileTableView?, offer: RemoteDownloadDragOffer?
        let sequence: Int, board: NSPasteboard.Name, revision: Int
        let types: [[NSPasteboard.PasteboardType]]
        init(table: RemoteFileTableView, offer: RemoteDownloadDragOffer,
             sequence: Int, board: NSPasteboard.Name, revision: Int,
             types: [[NSPasteboard.PasteboardType]]) {
            self.table = table; self.offer = offer; self.sequence = sequence
            self.board = board; self.revision = revision; self.types = types
        }
    }
    private static var active: [ObjectIdentifier: Active] = [:]
    static func begin(_ offer: RemoteDownloadDragOffer, session: NSDraggingSession) -> Bool {
        guard offer.isCurrent(), offer.wroteEveryRow, let table = offer.table else { return false }
        let board = session.draggingPasteboard
        guard let items = board.pasteboardItems, items.count == offer.rows.count,
              items.allSatisfy({ $0.types.contains(pasteboardType) }) else { return false }
        active[ObjectIdentifier(table)] = Active(table: table, offer: offer,
            sequence: session.draggingSequenceNumber, board: board.name,
            revision: board.changeCount, types: items.map(\.types))
        return true
    }
    static func end(table: RemoteFileTableView, sequence: Int) {
        let key = ObjectIdentifier(table)
        if active[key]?.sequence == sequence { active[key] = nil }
    }
    static func capture(_ info: NSDraggingInfo) -> RemoteDownloadDragOffer? {
        guard info.draggingSourceOperationMask.contains(.copy),
              let table = info.draggingSource as? RemoteFileTableView,
              let source = active[ObjectIdentifier(table)], source.table === table,
              source.sequence == info.draggingSequenceNumber, let offer = source.offer,
              offer.table === table, offer.isCurrent() else { return nil }
        let board = info.draggingPasteboard
        // Inspect bounded type metadata only. No untrusted pasteboard string,
        // URL, or lazy file-promise representation is read during negotiation.
        guard board.name == source.board, board.changeCount == source.revision,
              let items = board.pasteboardItems, items.count == offer.rows.count,
              items.map(\.types) == source.types,
              items.allSatisfy({ $0.types.contains(pasteboardType) }),
              board.changeCount == source.revision, offer.isCurrent() else { return nil }
        return offer
    }
}

