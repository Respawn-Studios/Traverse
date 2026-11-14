import Foundation

@_spi(Qualification) public enum SMBUploadGroupIssue: Error, Sendable, Equatable {
    case invalidSelection, duplicateNames, overlappingSources, tooLarge, historyFull, historyBusy
}

@_spi(Qualification) public struct SMBUploadGroupItem: Sendable {
    public enum Kind: Sendable { case file, folder }
    public let kind: Kind
    public let name: String, logicalBytes: UInt64
    public let files: Int, folders: Int
}

/// A bounded metadata review. The app retains the selected URLs and access
/// leases; each U1 attempt independently reopens and revalidates its own file.
@_spi(Qualification) public struct SMBUploadGroupPlan: Sendable, CustomDebugStringConvertible {
    enum Source: Sendable {
        case file(SFTPUploadSourceReview), folder(SMBFolderUploadPlan)
        var url: URL { switch self { case .file(let value): value.url; case .folder(let value): value.url } }
        var name: String { switch self { case .file(let value): value.name; case .folder(let value): value.name } }
        var identity: String {
            switch self {
            case .file(let value):
                let stamp = value.observation
                return "\(stamp.device):\(stamp.inode):\(stamp.generation)"
            case .folder(let value):
                let stamp = value.snapshot.observation
                return "\(stamp.device):\(stamp.inode):\(stamp.generation)"
            }
        }
        var item: SMBUploadGroupItem {
            switch self {
            case .file(let value): .init(kind: .file, name: value.name, logicalBytes: value.logicalBytes, files: 1, folders: 0)
            case .folder(let value): .init(kind: .folder, name: value.name, logicalBytes: value.logicalBytes,
                                           files: value.files, folders: value.folders + 1)
            }
        }
    }
    public static let maximumRoots = 64
    public static let maximumFiles = 64
    public static let maximumFileMembers = 1_024, maximumNodes = 2_048
    public static let maximumBytes: UInt64 = 1 << 30
    let reviewed: [Source]
    public let items: [SMBUploadGroupItem]
    public let files: Int, folders: Int
    public let logicalBytes: UInt64
    public var singleFileReview: SFTPUploadSourceReview? {
        guard reviewed.count == 1, case .file(let source) = reviewed[0] else { return nil }
        return source
    }
    public var debugDescription: String { "<SMB reviewed upload group>" }

    init(reviewed: [Source]) throws {
        guard (1...Self.maximumRoots).contains(reviewed.count) else { throw SMBUploadGroupIssue.invalidSelection }
        do { try SFTPUploadBatchPlan.validateURLs(reviewed.map(\.url)) }
        catch SFTPUploadBatchIssue.overlappingSources { throw SMBUploadGroupIssue.overlappingSources }
        catch { throw SMBUploadGroupIssue.invalidSelection }
        var names = Set<String>(), identities = Set<String>(), bytes: UInt64 = 0, files = 0, folders = 0
        var items: [SMBUploadGroupItem] = []
        for source in reviewed {
            let item = source.item
            guard Data(source.url.lastPathComponent.utf8) == Data(item.name.utf8) else {
                throw SMBUploadGroupIssue.invalidSelection
            }
            // The single-file review can ask for a safe remote name when the
            // local basename is unsupported. A group has no per-root rename
            // review, and the direct runner still validates the target before
            // creating a record or sending a frame.
            let singleFileReview = reviewed.count == 1 && {
                if case .file = source { return true }
                return false
            }()
            guard SMBRequestedUpload.isSupportedName(item.name) || singleFileReview else {
                throw SMBUploadGroupIssue.invalidSelection
            }
            // Servers differ in name folding; reject likely aliases locally.
            // U1's exclusive create/rename remains the final no-replace check.
            let folded = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                             locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
            guard names.insert(folded).inserted else { throw SMBUploadGroupIssue.duplicateNames }
            guard identities.insert(source.identity).inserted else { throw SMBUploadGroupIssue.overlappingSources }
            guard item.files <= Self.maximumFileMembers - files, item.folders <= Self.maximumNodes - folders,
                  item.logicalBytes <= Self.maximumBytes - bytes else { throw SMBUploadGroupIssue.tooLarge }
            files += item.files; folders += item.folders; bytes += item.logicalBytes
            guard files <= Self.maximumNodes - folders else { throw SMBUploadGroupIssue.tooLarge }
            items.append(item)
        }
        self.reviewed = reviewed; self.items = items; self.files = files; self.folders = folders; logicalBytes = bytes
    }

    public static func inspect(_ urls: [URL], excluding roots: [URL], allowsFolders: Bool = false) async throws -> Self {
        guard (1...maximumRoots).contains(urls.count) else { throw SMBUploadGroupIssue.invalidSelection }
        do { try SFTPUploadBatchPlan.validateURLs(urls) }
        catch SFTPUploadBatchIssue.overlappingSources { throw SMBUploadGroupIssue.overlappingSources }
        catch { throw SMBUploadGroupIssue.invalidSelection }
        var reviewed: [Source] = []
        for url in urls {
            try Task.checkCancellation()
            do { reviewed.append(.file(try await SFTPUploadSourceReview.inspect(url, excluding: roots))) }
            catch let issue as SFTPUploadLocalIssue where allowsFolders && (issue == .unsupportedSource || issue == .sourceUnavailable) {
                reviewed.append(.folder(try await SMBFolderUploadPlan.inspect(url, excluding: roots)))
            }
            _ = try Self(reviewed: reviewed) // Refuse aggregate excess before inspecting another source.
        }
        try Task.checkCancellation()
        return try Self(reviewed: reviewed)
    }

    static func requireHistoryHeadroom(files: Int, retained: Int, active: Bool) throws {
        guard !active else { throw SMBUploadGroupIssue.historyBusy }
        guard retained >= 0, retained <= 64, files > 0, files <= 64 - retained else {
            throw SMBUploadGroupIssue.historyFull
        }
    }
    public func checkHistory(_ storage: SMBUploadStorage) async throws {
        try await checkHistory(storage, remaining: items.count)
    }
    fileprivate func checkHistory(_ storage: SMBUploadStorage, remaining: Int) async throws {
        let history = try await storage.inspect()
        try Self.requireHistoryHeadroom(files: remaining, retained: history.records.count,
                                        active: history.records.contains(where: \.active))
    }
}

@_spi(Qualification) public struct SMBUploadGroupCompletedItem: Sendable {
    public let index: Int, id: UUID, logicalBytes: UInt64
}
@_spi(Qualification) public struct SMBUploadGroupProgress: Sendable {
    public let index: Int, completedFiles: Int, totalFiles: Int, sentBytes: UInt64
    public var completedRoots: Int { completedFiles }
    public var totalRoots: Int { totalFiles }
}
@_spi(Qualification) public struct SMBUploadGroupResult: Sendable, CustomDebugStringConvertible {
    public let completed: [SMBUploadGroupCompletedItem]
    public var completedRoots: Int { completed.count }
    public var debugDescription: String { "<SMB completed upload group>" }
}
@_spi(Qualification) public enum SMBUploadGroupCurrent: Sendable {
    case recorded(id: UUID, outcome: SMBUploadOutcome)
    case uncertain(id: UUID)
}
@_spi(Qualification) public struct SMBUploadGroupInterruption: Error, Sendable, CustomDebugStringConvertible {
    public let completed: [SMBUploadGroupCompletedItem]
    public let currentIndex: Int?
    public let current: SMBUploadGroupCurrent?
    public let totalFiles: Int
    public let cause: any Error
    public var totalRoots: Int { totalFiles }
    public var completedRoots: Int { completed.count }
    public var notSubmitted: Int { totalFiles - completed.count - (current == nil ? 0 : 1) }
    public var currentMayHaveStarted: Bool {
        switch current {
        case .uncertain: true
        case .recorded(_, let outcome): outcome != .notStarted && outcome != .prepared && outcome != .stageCollision
        case nil: false
        }
    }
    public var debugDescription: String { "<SMB interrupted upload group>" }
}

/// One serial group over the existing U1 owner. Every member has its own
/// durable outcome. A failure stops the group; it never retries, replaces,
/// cleans remote paths, or changes the local originals.
@_spi(Qualification) public enum SMBUploadGroupRunner {
    typealias Submit = @Sendable (SMBRequestedUpload, @escaping @Sendable (UInt64) -> Void) async throws -> SMBCompletedUpload
    typealias SubmitFolder = @Sendable (SMBRequestedFolderUpload, @escaping @Sendable (UInt64) -> Void) async throws -> SMBCompletedUpload
    typealias InspectCurrent = @Sendable (UUID) async -> SMBUploadGroupCurrent?
    private enum Request {
        case file(SMBRequestedUpload), folder(SMBRequestedFolderUpload)
        var id: UUID { switch self { case .file(let value): value.request; case .folder(let value): value.request } }
    }

    public static func run(_ plan: SMBUploadGroupPlan, connection: UUID, snapshot: SMBDirectorySnapshot,
                           directory: [SMBRemoteName], session: SMBBrowserSession, storage: SMBUploadStorage,
                           excluding roots: [URL], requireCurrent: @escaping @Sendable () async throws -> Void,
                           progress: (@Sendable (SMBUploadGroupProgress) -> Void)? = nil) async throws -> SMBUploadGroupResult {
        try await runWithSubmission(plan, connection: connection, snapshot: snapshot, directory: directory,
            storage: storage, requireCurrent: requireCurrent, progress: progress,
            submit: { request, report in
                try await session.upload(request, storage: storage, excluding: roots, progress: report)
            }, submitFolder: { request, report in
                let result = try await session.uploadFolder(request, storage: storage, excluding: roots, progress: report)
                return .init(id: result.id, logicalBytes: result.logicalBytes)
            }, inspectCurrent: { id in
                do {
                    let history = try await storage.inspect()
                    guard let record = history.records.first(where: { $0.id == id }) else { return .uncertain(id: id) }
                    return record.active ? .uncertain(id: id) : .recorded(id: id, outcome: record.outcome)
                } catch { return .uncertain(id: id) }
            }, sessionID: session.id)
    }

    /// The same orchestration with generated U1/F2 submission seams. It tests
    /// partial and cancellation accounting without opening a network reader.
    static func runWithSubmission(_ plan: SMBUploadGroupPlan, connection: UUID, snapshot: SMBDirectorySnapshot,
                                  directory: [SMBRemoteName], storage: SMBUploadStorage,
                                  requireCurrent: @escaping @Sendable () async throws -> Void,
                                  progress: (@Sendable (SMBUploadGroupProgress) -> Void)? = nil,
                                  submit: @escaping Submit, submitFolder: SubmitFolder? = nil,
                                  inspectCurrent: @escaping InspectCurrent,
                                  sessionID: UUID) async throws -> SMBUploadGroupResult {
        var completed: [SMBUploadGroupCompletedItem] = [], sent: UInt64 = 0
        let requests: [Request]
        do {
            try Task.checkCancellation(); guard sessionID == connection else { throw SMBUploadFailure.invalidInput }
            try await requireCurrent(); try await plan.checkHistory(storage)
            requests = try zip(plan.reviewed, plan.items).map { source, item in
                switch source {
                case .file(let file):
                    return .file(try SMBRequestedUpload(connection: connection, snapshot: snapshot, directory: directory,
                                                        reviewed: file, name: item.name))
                case .folder(let folder):
                    guard submitFolder != nil else { throw SMBUploadGroupIssue.invalidSelection }
                    return .folder(try SMBRequestedFolderUpload(connection: connection, snapshot: snapshot,
                                                                directory: directory, reviewed: folder, name: item.name))
                }
            }
            try Task.checkCancellation(); try await requireCurrent()
        } catch { throw interrupted(error, completed: completed, total: plan.items.count) }
        for (index, request) in requests.enumerated() {
            do {
                try Task.checkCancellation(); try await requireCurrent()
                try await plan.checkHistory(storage, remaining: requests.count - index)
            }
            catch { throw interrupted(error, completed: completed, total: plan.items.count) }
            let before = sent, item = plan.items[index]
            progress?(.init(index: index, completedFiles: completed.count, totalFiles: plan.items.count, sentBytes: sent))
            let report: @Sendable (UInt64) -> Void = { bytes in
                progress?(.init(index: index, completedFiles: index, totalFiles: plan.items.count,
                                sentBytes: before + min(bytes, item.logicalBytes)))
            }
            do {
                let result: SMBCompletedUpload
                switch request {
                case .file(let file): result = try await submit(file, report)
                case .folder(let folder):
                    guard let submitFolder else { throw SMBUploadGroupIssue.invalidSelection }
                    result = try await submitFolder(folder, report)
                }
                guard result.id == request.id, result.logicalBytes == item.logicalBytes else {
                    throw SMBUploadFailure.reviewRequired
                }
                completed.append(.init(index: index, id: result.id, logicalBytes: result.logicalBytes))
                sent += result.logicalBytes
                progress?(.init(index: index, completedFiles: completed.count, totalFiles: plan.items.count, sentBytes: sent))
            } catch {
                let observed = await inspectCurrent(request.id)
                var current: SMBUploadGroupCurrent? = .uncertain(id: request.id)
                if let observed {
                    switch observed {
                    case .recorded(let id, .verified) where id == request.id:
                        completed.append(.init(index: index, id: id, logicalBytes: item.logicalBytes))
                        current = nil
                    case .recorded(let id, .notStarted) where id == request.id:
                        current = nil
                    case .recorded(let id, _) where id != request.id:
                        current = .uncertain(id: request.id)
                    default: current = observed
                    }
                }
                throw interrupted(error, completed: completed, total: plan.items.count,
                                  currentIndex: current == nil ? nil : index, current: current)
            }
        }
        return .init(completed: completed)
    }

    private static func interrupted(_ cause: any Error, completed: [SMBUploadGroupCompletedItem], total: Int,
                                    currentIndex: Int? = nil, current: SMBUploadGroupCurrent? = nil) -> SMBUploadGroupInterruption {
        .init(completed: completed, currentIndex: currentIndex, current: current, totalFiles: total, cause: cause)
    }
}
