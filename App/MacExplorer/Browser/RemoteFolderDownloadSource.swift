import AppKit
@_spi(Qualification) import LocalStorage

enum SFTPFolderDownloadFeature {
    static let enabled = true
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var available: Bool {
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            return GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted
        }
        return RemoteDownloadPublicationFeature.folderAvailable && (qualifying || enabled)
    }
    #else
    static var available: Bool {
        enabled && (GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted
            || RemoteDownloadPublicationFeature.folderAvailable)
    }
    #endif
}

@MainActor enum SMBFolderDownloadFeature {
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            return GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted
        }
        guard RemoteDownloadPublicationFeature.folderAvailable else { return false }
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverDownloads)
    }
}

/// A captured selection uses the existing serial session for every round trip.
/// Only the local review, progress and verified publication are shared.
@MainActor enum RemoteFolderDownloadSource {
    enum Kind: Equatable {
        case sftp, smb
        var stale: any Error {
            switch self { case .sftp: SFTPBrowserFailure.stale; case .smb: SMBDirectoryFailure.stale }
        }
        var busy: any Error {
            switch self { case .sftp: SFTPBrowserFailure.busy; case .smb: SMBDirectoryFailure.busy }
        }
    }
    case sftp(SFTPTabController, SFTPFolderDownloadSelection, SFTPDownloadStorage)
    case smb(SMBTabController, SMBFolderDownloadSelection, SMBDownloadStorage)

    init?(_ owner: SFTPTabController) {
        guard SFTPFolderDownloadFeature.available, !owner.hasPendingPages,
              owner.session.allowsRequestedFolderDownloads, let storage = owner.downloads,
              let selection = owner.rows.selectedFolderDownload else { return nil }
        self = .sftp(owner, selection, storage)
    }

    init?(_ owner: SMBTabController) {
        guard SMBFolderDownloadFeature.available, !owner.hasPendingPages,
              owner.session.allowsFolderDownloads, let storage = owner.downloads,
              let selection = owner.selectedFolderDownload else { return nil }
        self = .smb(owner, selection, storage)
    }

    var kind: Kind { if case .sftp = self { return .sftp }; return .smb }
    var rows: NSView { switch self { case .sftp(let owner, _, _): owner.rows; case .smb(let owner, _, _): owner.rows } }
    var name: String? {
        switch self { case .sftp(_, let selection, _): selection.proposedLocalName
                      case .smb(_, let selection, _): selection.proposedLocalName }
    }
    var requiresReview: Bool {
        switch self { case .sftp(let owner, _, _): owner.reviewsUploads; case .smb(let owner, _, _): owner.reviewsUploads }
    }
    var failed: Bool {
        switch self {
        case .sftp(let owner, _, _): owner.session.latest.failure != nil
        case .smb(let owner, _, _): owner.session.latest.failure != nil
        }
    }
    func isCurrent(in browser: BrowserViewController) -> Bool {
        switch self {
        case .sftp(let owner, let selection, _):
            return browser.sftpTabs[browser.activeID] === owner && !owner.isClosing
                && RemoteDownloadDragOffer.matchesFolder(selection, owner.rows.selectedFolderDownload)
        case .smb(let owner, let selection, _):
            return browser.smbTabs[browser.activeID] === owner && !owner.isClosing
                && RemoteDownloadDragOffer.matchesFolder(selection, owner.folderSelectionIncludingPreparation)
        }
    }
    func prepare(progress: @escaping @Sendable (RemoteFolderDownloadProgress) -> Void) async throws -> RemotePreparedFolderDownload {
        switch self {
        case .sftp(let owner, let selection, let storage):
            let session = owner.session
            let prepared = try await session.prepareFolderDownload(selection, progress: { progress(.init($0)) })
            return .init(summary: .init(prepared: prepared), longestPathBytes: prepared.longestPathBytes,
                release: { try await session.releaseFolderDownload(prepared) },
                receive: { receiveProgress in
                    try await session.downloadFolder(prepared, storage: storage, progress: { receiveProgress(.init($0)) })
                })
        case .smb(let owner, let selection, let storage):
            let session = owner.session
            let prepared = try await session.prepareFolderDownload(selection)
            return .init(summary: .init(prepared: prepared), longestPathBytes: prepared.longestPathBytes,
                release: { try await session.releaseFolderDownload(prepared) },
                receive: { receiveProgress in
                    try await session.downloadFolder(prepared, storage: storage, progress: { receiveProgress(.receiving($0)) })
                })
        }
    }
    func drain(diagnostic: RemoteTransferDiagnostics) async {
        switch self {
        case .sftp(let owner, _, _): diagnostic.drained(await owner.close().value)
        case .smb(let owner, _, _): diagnostic.drained(await owner.close().value)
        }
    }
}

/// The release and receive closures share the same typed manifest and
/// connection. A later selection cannot accidentally supply a different plan.
@MainActor struct RemotePreparedFolderDownload {
    let summary: SFTPFolderPreviewSummary
    let longestPathBytes: Int
    let release: () async throws -> Void
    let receive: (@escaping @Sendable (RemoteFolderDownloadProgress) -> Void) async throws -> RemoteReceivedFolderDownload
}

enum RemoteFolderDownloadProgress: Sendable {
    case checkingFolders(Int), receiving(UInt64), checkingCopy(UInt64)

    init(_ value: SFTPFolderDownloadProgress) {
        switch value.phase {
        case .checkingFolders: self = .checkingFolders(value.checkedEntries)
        case .receiving: self = .receiving(value.receivedBytes)
        case .checkingCopy: self = .checkingCopy(value.receivedBytes)
        }
    }
}
