import Foundation

/// The caller's cancellation is visible between roots immediately, without
/// waiting for a new actor Task. Started work still requires actual owner drain;
/// cancelling a merely queued group must leave its connection usable.
final class SFTPUploadBatchControl: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false, began = false
    func cancel() { lock.withLock { stopped = true } }
    var cancelled: Bool { lock.withLock { stopped } }
    var started: Bool { lock.withLock { began } }
    func begin() throws {
        try lock.withLock { guard !stopped else { throw SFTPBrowserFailure.stopped }; began = true }
    }
}

@_spi(Qualification) public enum SFTPUploadBatchIssue: String, Error, Sendable {
    case invalidSelection, overlappingSources, duplicateNames, tooLarge, historyFull
}

@_spi(Qualification) public struct SFTPUploadBatchItem: Sendable {
    public enum Kind: Sendable, Equatable { case file, folder }
    public let name: String, kind: Kind, files: Int, folders: Int, logicalBytes: UInt64
}

/// Bounded metadata observations. The native caller separately retains the
/// actual selected URLs/access leases; each worker attempt reopens and checks
/// its source. Constructing a plan neither reads bodies nor creates history.
@_spi(Qualification) public struct SFTPUploadBatchPlan: Sendable, CustomDebugStringConvertible {
    enum Root: Sendable {
        case file(SFTPUploadSourceReview), folder(SFTPFolderUploadSourceReview)
        var url: URL { switch self { case .file(let value): value.url; case .folder(let value): value.url } }
        var item: SFTPUploadBatchItem {
            switch self {
            case .file(let value): .init(name: value.name, kind: .file, files: 1, folders: 0, logicalBytes: value.logicalBytes)
            case .folder(let value): .init(name: value.name, kind: .folder, files: value.files, folders: value.folders + 1, logicalBytes: value.logicalBytes)
            }
        }
        var identity: String {
            switch self {
            case .file(let value): "\(value.observation.device):\(value.observation.inode):\(value.observation.generation)"
            case .folder(let value): "\(value.snapshot.observation.device):\(value.snapshot.observation.inode):\(value.snapshot.observation.generation)"
            }
        }
    }
    static let maximumRoots = 128, maximumNodes = 2048, maximumFiles = 1024
    static let maximumBytes: UInt64 = 1 << 30
    let roots: [Root]
    public let items: [SFTPUploadBatchItem]
    public let files: Int, folders: Int, logicalBytes: UInt64
    public var debugDescription: String { "<SFTP reviewed upload group>" }

    init(reviewed roots: [Root]) throws {
        try Self.validateURLs(roots.map(\.url))
        for root in roots {
            if case .folder(let value) = root {
                guard (0...Self.maximumFiles).contains(value.files), (0..<Self.maximumNodes).contains(value.folders) else { throw SFTPUploadBatchIssue.tooLarge }
            }
        }
        var names = Set<Data>(), identities = Set<String>(), files = 0, folders = 0, bytes: UInt64 = 0
        let items = roots.map(\.item)
        for (root, item) in zip(roots, items) {
            let name = try SFTPRemoteName(Data(item.name.utf8))
            guard name.wireUTF8.count <= 255, Data(root.url.lastPathComponent.utf8) == name.wireUTF8 else { throw SFTPUploadBatchIssue.invalidSelection }
            guard names.insert(name.wireUTF8).inserted else { throw SFTPUploadBatchIssue.duplicateNames }
            guard identities.insert(root.identity).inserted else { throw SFTPUploadBatchIssue.overlappingSources }
            guard item.files >= 0, item.folders >= 0, item.files <= Self.maximumFiles - files,
                  item.folders <= Self.maximumNodes - folders, item.logicalBytes <= Self.maximumBytes - bytes else { throw SFTPUploadBatchIssue.tooLarge }
            files += item.files; folders += item.folders; bytes += item.logicalBytes
            guard files <= Self.maximumNodes - folders else { throw SFTPUploadBatchIssue.tooLarge }
        }
        self.roots = roots; self.items = items; self.files = files; self.folders = folders; logicalBytes = bytes
    }

    static func validateURLs(_ urls: [URL]) throws {
        guard (1...maximumRoots).contains(urls.count) else { throw SFTPUploadBatchIssue.invalidSelection }
        var paths: [Data] = []
        for url in urls {
            let bytes = Data(url.path.utf8)
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), !bytes.contains(0), bytes.count <= 8192,
                  // Foundation may canonicalize Unicode while standardizing a
                  // local URL. Use this comparison only for lexical safety;
                  // identities/names/overlaps below still use exact input bytes.
                  url.path == url.standardizedFileURL.path, bytes != Data([47]) else { throw SFTPUploadBatchIssue.invalidSelection }
            for prior in paths {
                if prior == bytes || bytes.starts(with: prior + Data([47])) || prior.starts(with: bytes + Data([47])) {
                    throw SFTPUploadBatchIssue.overlappingSources
                }
            }
            paths.append(bytes)
        }
    }

    public static func inspect(_ urls: [URL], excluding roots: [URL], allowsFolders: Bool) async throws -> Self {
        try validateURLs(urls)
        var reviewed: [Root] = []
        for url in urls {
            try Task.checkCancellation()
            do { reviewed.append(.file(try await SFTPUploadSourceReview.inspect(url, excluding: roots))) }
            catch let issue as SFTPUploadLocalIssue where issue == .unsupportedSource || issue == .sourceUnavailable {
                // The concrete file inspector intentionally masks a non-file
                // open as unavailable. A second metadata-only inspection of
                // this exact URL may prove a folder; it supplies no new access
                // and still applies every folder privacy/source check.
                guard allowsFolders else { throw SFTPUploadLocalIssue.unsupportedSource }
                reviewed.append(.folder(try await SFTPFolderUploadSourceReview.inspect(url, excluding: roots)))
            }
            // Refuse a known aggregate excess before inspecting further roots.
            _ = try Self(reviewed: reviewed)
        }
        try Task.checkCancellation()
        return try .init(reviewed: reviewed)
    }

    static func requireHistoryHeadroom(roots: Int, retained: Int) throws {
        guard retained >= 0, retained <= 64, roots > 0, roots <= 64 - retained else { throw SFTPUploadBatchIssue.historyFull }
    }
    public func checkHistory(_ storage: SFTPUploadStorage) async throws {
        do { try Self.requireHistoryHeadroom(roots: items.count, retained: try await storage.inspect().records.count) }
        catch let failure as RemoteSettingsFailure { throw SFTPUploadLocalIssue(failure) }
    }
}

@_spi(Qualification) public struct SFTPUploadBatchCompletedItem: Sendable {
    public let index: Int, id: UUID, logicalBytes: UInt64
}
@_spi(Qualification) public struct SFTPUploadBatchResult: Sendable, CustomDebugStringConvertible {
    public let completed: [SFTPUploadBatchCompletedItem]
    public var debugDescription: String { "<SFTP completed upload group>" }
}
@_spi(Qualification) public struct SFTPUploadBatchProgress: Sendable {
    public let index: Int, completedRoots: Int, totalRoots: Int, sentBytes: UInt64
}
@_spi(Qualification) public struct SFTPUploadBatchInterruption: Error, Sendable, CustomDebugStringConvertible {
    public let completed: [SFTPUploadBatchCompletedItem], totalRoots: Int
    public let currentMayHaveStarted: Bool, cause: any Error
    let connectionFailed: Bool
    public var notSubmitted: Int { totalRoots - completed.count - (currentMayHaveStarted ? 1 : 0) }
    public var debugDescription: String { "<SFTP interrupted upload group>" }
}

/// Called once by the existing serial pump, never as a second queue. Waiting
/// navigation/pages cannot run between these roots; Stop/close can still drain.
enum SFTPUploadBatchRunner {
    static func run(_ plan: SFTPUploadBatchPlan, generation: UUID, snapshot: SFTPStoredSnapshot,
                    transport: any SFTPDirectoryTransport, storage: SFTPUploadStorage, excluding roots: [URL],
                    requireCurrent: @Sendable () async throws -> Void,
                    progress: (@Sendable (SFTPUploadBatchProgress) -> Void)?) async throws -> SFTPUploadBatchResult {
        var completed: [SFTPUploadBatchCompletedItem] = [], sent: UInt64 = 0
        do { try await requireCurrent(); try await plan.checkHistory(storage) }
        catch { throw interrupted(error, completed: completed, total: plan.items.count, attempted: false, failed: false) }
        for (index, root) in plan.roots.enumerated() {
            do { try await requireCurrent() }
            catch { throw interrupted(error, completed: completed, total: plan.items.count, attempted: false, failed: false) }
            let before = sent, item = plan.items[index]
            let report: @Sendable (UInt64) -> Void = { bytes in
                progress?(.init(index: index, completedRoots: index, totalRoots: plan.items.count, sentBytes: before + min(bytes, item.logicalBytes)))
            }
            progress?(.init(index: index, completedRoots: completed.count, totalRoots: plan.items.count, sentBytes: sent))
            do {
                let id: UUID, bytes: UInt64
                switch root {
                case .file(let source):
                    let request = try SFTPRequestedUpload(generation: generation, reviewed: source, name: item.name)
                    let result = try await transport.upload(request, snapshot: snapshot, storage: storage, excluding: roots, progress: report)
                    id = result.id; bytes = result.logicalBytes
                case .folder(let source):
                    let request = try SFTPRequestedFolderUpload(generation: generation, reviewed: source, name: item.name)
                    let result = try await transport.uploadFolder(request, snapshot: snapshot, storage: storage, excluding: roots, progress: { amount, _ in report(amount) })
                    id = result.id; bytes = result.logicalBytes
                }
                guard bytes == item.logicalBytes else { throw SFTPBrowserFailure.security }
                completed.append(.init(index: index, id: id, logicalBytes: bytes)); sent += bytes
                progress?(.init(index: index, completedRoots: completed.count, totalRoots: plan.items.count, sentBytes: sent))
            } catch {
                let admission = error as? SFTPUploadAdmissionFailure
                let refused = error is SFTPUploadOpenRefusal
                throw interrupted(admission?.cause ?? error, completed: completed, total: plan.items.count,
                    attempted: admission == nil && !refused, failed: admission == nil && !refused)
            }
        }
        return .init(completed: completed)
    }
    static func interrupted(_ error: any Error, completed: [SFTPUploadBatchCompletedItem], total: Int,
                            attempted: Bool, failed: Bool) -> SFTPUploadBatchInterruption {
        let cause: any Error
        if let value = error as? SFTPUploadSourceFailure { cause = SFTPUploadLocalIssue(value) }
        else if let value = error as? RemoteSettingsFailure { cause = SFTPUploadLocalIssue(value) }
        else { cause = error }
        return .init(completed: completed, totalRoots: total, currentMayHaveStarted: attempted, cause: cause, connectionFailed: failed)
    }
}
