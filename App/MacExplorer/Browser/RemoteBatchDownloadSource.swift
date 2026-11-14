import AppKit
@_spi(ArchiveProduction) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage

/// The two concrete browser owners keep their own identity and receive rules.
/// Only their local destination, progress and publication presentation is shared.
@MainActor enum RemoteBatchDownloadSource {
    case sftp(SFTPTabController, SFTPDownloadBatchPlan, SFTPDownloadStorage)
    case smb(SMBTabController, SMBDownloadBatchPlan, SMBDownloadStorage)

    init?(_ owner: SFTPTabController) {
        guard RemoteDownloadPublicationFeature.groupAvailable, SFTPDownloadFeature.available, let plan = owner.sealedBatchDownload,
              let storage = owner.downloads else { return nil }
        self = .sftp(owner, plan, storage)
    }
    init?(_ owner: SMBTabController) {
        guard RemoteDownloadPublicationFeature.groupAvailable, SMBDownloadFeature.available, let plan = owner.sealedBatchDownload,
              let storage = owner.downloads else { return nil }
        self = .smb(owner, plan, storage)
    }
    var files: [(id: UUID, name: String)] {
        switch self {
        case .sftp(_, let plan, _): plan.items.map { ($0.selection.request, $0.localName) }
        case .smb(_, let plan, _): plan.items.map { ($0.selection.request, $0.localName) }
        }
    }
    var logicalBytes: UInt64 {
        switch self { case .sftp(_, let plan, _): plan.logicalBytes; case .smb(_, let plan, _): plan.logicalBytes }
    }
    var protocolName: String { switch self { case .sftp: "SFTP"; case .smb: "SMB" } }
    var usesPublicQuarantine: Bool { RemoteDownloadPublicationFeature.qualifiesPublicQuarantineGroupDownload }
    func matchesSFTP(_ expected: SFTPDownloadBatchPlan) -> Bool {
        guard case .sftp(_, let plan, _) = self else { return false }
        return plan.generation == expected.generation && plan.snapshot == expected.snapshot
            && plan.items.map(\.selection.row) == expected.items.map(\.selection.row)
    }
    func matchesSMB(_ expected: SMBDownloadBatchPlan) -> Bool {
        guard case .smb(_, let plan, _) = self else { return false }
        return plan.connection == expected.connection && plan.snapshot == expected.snapshot
            && plan.items.map(\.selection.observation) == expected.items.map(\.selection.observation)
    }
    var rows: NSView { switch self { case .sftp(let owner, _, _): owner.rows; case .smb(let owner, _, _): owner.rows } }
    var failed: Bool {
        switch self { case .sftp(let owner, _, _): owner.session.latest.failure != nil; case .smb(let owner, _, _): owner.session.latest.failure != nil }
    }
    func isCurrent(in browser: BrowserViewController) -> Bool {
        switch self {
        case .sftp(let owner, let plan, _):
            guard browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, !owner.hasPendingPages,
                  let current = owner.sealedBatchDownload else { return false }
            return current.generation == plan.generation && current.snapshot == plan.snapshot
                && current.items.map(\.selection.row) == plan.items.map(\.selection.row)
        case .smb(let owner, let plan, _):
            guard browser.smbTabs[browser.activeID] === owner, !owner.isClosing, !owner.hasPendingPages,
                  let current = owner.sealedBatchDownload else { return false }
            return current.connection == plan.connection && current.snapshot == plan.snapshot
                && current.items.map(\.selection.observation) == plan.items.map(\.selection.observation)
        }
    }
    func receive(progress: @escaping @Sendable (RemoteBatchDownloadProgress) -> Void) async throws -> [RemoteReceivedFile] {
        switch self {
        case .sftp(let owner, let plan, let storage):
            return try await owner.session.downloadBatch(plan, storage: storage, progress: {
                progress(.init(completedFiles: $0.completedFiles, totalFiles: $0.totalFiles, receivedBytes: $0.receivedBytes))
            }).items.map { .sftp($0.download) }
        case .smb(let owner, let plan, let storage):
            return try await owner.session.downloadBatch(plan, storage: storage, progress: {
                progress(.init(completedFiles: $0.completedFiles, totalFiles: $0.totalFiles, receivedBytes: $0.receivedBytes))
            }).items.map { .smb($0.download) }
        }
    }
    func drain(diagnostic: RemoteTransferDiagnostics) async {
        switch self {
        case .sftp(let owner, _, _): diagnostic.drained(await owner.close().value)
        case .smb(let owner, _, _): diagnostic.drained(await owner.close().value)
        }
    }
}

struct RemoteBatchDownloadProgress: Sendable {
    let completedFiles: Int, totalFiles: Int, receivedBytes: UInt64
}

/// Wrapping a sealed concrete receipt adds no new read or mutation authority.
enum RemoteReceivedFile: Sendable {
    case sftp(SFTPReceivedDownload), smb(SMBReceivedDownload)
    func preparePublication(using engine: RecoverableFileOperations, parent: URL, name: String,
                            observing: FileOperationSelection, publicQuarantine: Bool = false) async throws -> ReceivedFilePlan {
        if publicQuarantine {
            switch self {
            case .sftp(let file): return try await file.preparePublicQuarantineCandidate(using: engine,
                parent: parent, name: name, observing: observing)
            case .smb(let file): return try await file.preparePublicQuarantineCandidate(using: engine,
                parent: parent, name: name, observing: observing)
            }
        }
        switch self {
        case .sftp(let file): return try await file.preparePublication(using: engine, parent: parent, name: name, observing: observing)
        case .smb(let file): return try await file.preparePublication(using: engine, parent: parent, name: name, observing: observing)
        }
    }
    func finishPublication(_ outcome: RecoverableOperationResult) async -> Bool {
        switch self { case .sftp(let file): await file.finishPublication(outcome); case .smb(let file): await file.finishPublication(outcome) }
    }
    /// Shares the native single-file handoff without changing batch or folder
    /// publication. The concrete sealed receipt still owns adoption eligibility.
    @MainActor func publishSingleFile(using engine: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection, progress: (@Sendable (OperationProgress) -> Void)?,
        expectedDestination: URL? = nil, revalidating: @MainActor () throws -> Void = {}) async throws
        -> (RecoverableOperationResult, Bool) {
        @MainActor func validatePreparedDestination(_ actual: URL) throws {
            try Task.checkCancellation()
            if let expectedDestination,
               !actual.path.utf8.elementsEqual(expectedDestination.path.utf8) {
                throw FileOperationFailure.destinationChanged
            }
            try revalidating()
        }
        try Task.checkCancellation(); try revalidating()
        let publicQuarantine: Bool
        switch self {
        case .sftp: publicQuarantine = RemoteDownloadPublicationFeature.qualifiesPublicQuarantineDownload
        case .smb: publicQuarantine = RemoteDownloadPublicationFeature.qualifiesSMBPublicQuarantineDownload
        }
        if publicQuarantine {
            let plan = try await preparePublication(using: engine, parent: parent, name: name,
                observing: destination, publicQuarantine: true)
            try validatePreparedDestination(plan.destination)
            let outcome = await engine.performReceivedFile(plan, progress: progress)
            return (outcome, await finishPublication(outcome))
        }
        if RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption {
            let plan: AdoptedReceivedFilePlan
            switch self {
            case .sftp(let file): plan = try await file.prepareAdoption(using: engine, parent: parent, name: name, observing: destination)
            case .smb(let file): plan = try await file.prepareAdoption(using: engine, parent: parent, name: name, observing: destination)
            }
            try validatePreparedDestination(plan.destination)
            let outcome = await engine.performReceivedFile(plan, progress: progress)
            let retired: Bool
            switch self {
            case .sftp(let file): retired = await file.finishAdoption(outcome)
            case .smb(let file): retired = await file.finishAdoption(outcome)
            }
            return (outcome, retired)
        }
        let plan = try await preparePublication(using: engine, parent: parent, name: name, observing: destination)
        try validatePreparedDestination(plan.destination)
        let outcome = await engine.performReceivedFile(plan, progress: progress)
        return (outcome, await finishPublication(outcome))
    }
    func retainForReview() async {
        switch self { case .sftp(let file): await file.retainForReview(); case .smb(let file): await file.retainForReview() }
    }
}
