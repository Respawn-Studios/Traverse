import Darwin
import Foundation

/// Presentation vocabulary for a received producer, never access authority or
/// an alternate recovery protocol. Existing download callers keep their title.
@_spi(ArchiveProduction) public enum ReceivedItemOrigin: Sendable {
    case download, zipExtraction, tarExtraction, textSaveAs
    internal var fileHistoryTitle: String {
        switch self {
        case .download: "Download"
        case .zipExtraction: "Extract ZIP"
        case .tarExtraction: "Extract TAR"
        case .textSaveAs: "Save Text As"
        }
    }
    internal var directoryHistoryTitle: String { self == .download ? "Download Folder" : fileHistoryTitle }
    internal var diagnosticPrefix: String { self == .textSaveAs ? "text-save-as" : self == .download ? "download" : "archive" }
}

/// Concrete archive adapters import this SPI; native views never receive
/// a staging descriptor or a callback that populates a public folder.
@_spi(ArchiveProduction) public enum ArchiveSourceFormat: Sendable {
    case zip, tar
    internal var historyTitle:String { self == .zip ? "Extract ZIP":"Extract TAR" }
}

/// V16 has concrete producers with one staged-tree/Undo protocol. The
/// archive's source-mark fact is recorded; a received folder always requires
/// a public quarantine property on every produced node.
@_spi(ArchiveProduction) public enum PublicProducedTreePurposeV16: Codable, Equatable, Sendable {
    case receivedFolder
    case zipExtraction(sourceMarked: Bool)
    case tarExtraction(sourceMarked: Bool)

    internal var isTARExtraction: Bool {
        if case .tarExtraction = self { return true }
        return false
    }

    internal var requiresMarkOnEveryNode: Bool {
        switch self {
        case .receivedFolder: true
        case .zipExtraction(let sourceMarked): sourceMarked
        case .tarExtraction(let sourceMarked): sourceMarked
        }
    }
    internal var historyTitle: String {
        switch self {
        case .receivedFolder: "Download Folder"
        case .zipExtraction: "Extract ZIP"
        case .tarExtraction: "Extract TAR"
        }
    }
}

/// Final archive member names for the existing Add review. These are display
/// facts from a prepared producer, not filesystem paths or permissions.
public struct ArchiveAddedItemPreview: Sendable, Equatable {
    public let originalName: String, archivePath: String
    public let isDirectory: Bool
    public let replacesExistingFile: Bool

    @_spi(ArchiveProduction) public init(originalName: String, archivePath: String, isDirectory: Bool,
                                       replacesExistingFile: Bool = false) {
        self.originalName = originalName; self.archivePath = archivePath; self.isDirectory = isDirectory
        self.replacesExistingFile = replacesExistingFile
    }

    public var finalName: String { archivePath.split(separator: "/").last.map(String.init) ?? originalName }
    public var renamed: Bool { !finalName.utf8.elementsEqual(originalName.utf8) }
}

@_spi(ArchiveProduction) public struct ArchiveProductionPreview: Sendable {
    public let files: Int, folders: Int, longestPathBytes: Int
    public let logicalBytes: UInt64
    /// Present only when a concrete producer has counted each source file.
    /// The signed TAR fixture rejects an absent fact before production.
    public let largestFileBytes: UInt64?
    public let addedItems: [ArchiveAddedItemPreview]
    public init(files: Int, folders: Int, logicalBytes: UInt64, longestPathBytes: Int,
                addedItems: [ArchiveAddedItemPreview] = [], largestFileBytes: UInt64? = nil) {
        self.files = files; self.folders = folders; self.logicalBytes = logicalBytes; self.longestPathBytes = longestPathBytes
        self.addedItems = addedItems; self.largestFileBytes = largestFileBytes
    }
}
@_spi(ArchiveProduction) public struct ArchiveProducedNode: Sendable {
    public let relative: String
    public let device: Int32
    public let inode: UInt64
    public let kind: UInt16
    public let birthSeconds: Int, birthNanoseconds: Int
    public let changedSeconds: Int, changedNanoseconds: Int
    public let size: Int64
    public let contentSHA256: Data?
    /// Optional source-bound mark for a produced archive node. The raw value
    /// stays in the producer; this digest is never persisted in the journal.
    public let expectedQuarantineSHA256: Data?
    /// Only the v14 received Download path may set this receipt.
    public let publicQuarantineV1: Bool?
    /// V15 one-file ZIP extraction only. The public property must remain
    /// present when the marked source or the OS marked the private member.
    public let publicZIPExtractionMarkRequired: Bool?
    /// V17 one-file TAR extraction only. The source is always the original
    /// TAR or compressed TAR, never its temporary decoded spool.
    public let publicTARExtractionMarkRequired: Bool?
    public init(relative: String, device: Int32, inode: UInt64, kind: UInt16, birthSeconds: Int,
                birthNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int, size: Int64, contentSHA256: Data?,
                expectedQuarantineSHA256: Data? = nil, publicQuarantineV1: Bool? = nil,
                publicZIPExtractionMarkRequired: Bool? = nil,
                publicTARExtractionMarkRequired: Bool? = nil) {
        self.relative = relative; self.device = device; self.inode = inode; self.kind = kind
        self.birthSeconds = birthSeconds; self.birthNanoseconds = birthNanoseconds; self.size = size; self.contentSHA256 = contentSHA256
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
        self.expectedQuarantineSHA256 = expectedQuarantineSHA256
        self.publicQuarantineV1 = publicQuarantineV1
        self.publicZIPExtractionMarkRequired = publicZIPExtractionMarkRequired
        self.publicTARExtractionMarkRequired = publicTARExtractionMarkRequired
    }
}
@_spi(ArchiveProduction) public protocol ArchiveDirectoryProducer: Sendable {
    var preview: ArchiveProductionPreview { get }
    var publicProducedTreeV16: PublicProducedTreePurposeV16? { get }
    func validate(check: @Sendable () throws -> Void) throws
    func produce(in directory: Int32, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode]
    /// Called after a consumed worker drains, or its own unused plan retires.
    func finished()
}
/// V16 alone receives its engine-owned private stage URL so public Foundation
/// resource-property calls can be bound to the already opened node descriptors.
@_spi(ArchiveProduction) public protocol PublicQuarantineTreeProducerV16: ArchiveDirectoryProducer {
    func produce(in directory: Int32, at privateStage: URL, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode]
}
@_spi(ArchiveProduction) public extension ArchiveDirectoryProducer {
    var publicProducedTreeV16: PublicProducedTreePurposeV16? { nil }
    func finished() {}
}

public final class ArchiveExtractionPlan: Sendable {
    public let source: URL
    public var destination: URL { production.destination }
    public var files: Int { production.files }
    public var folders: Int { production.folders }
    public var logicalBytes: UInt64 { production.logicalBytes }
    internal let production: DirectoryProductionPlan
    internal init(_ production: DirectoryProductionPlan, source: URL) {
        self.production = production; self.source = source
    }
}

/// A ZIP source and a sealed received tree share publication mechanics, never
/// source authority. Received trees have no invented local archive/source URL.
internal final class DirectoryProductionPlan: @unchecked Sendable {
    internal let source: URL?, destination: URL
    public let files: Int, folders: Int
    public let logicalBytes: UInt64
    internal let parent: URL
    internal let sourceIdentity: EntrySnapshot?, parentIdentity: EntrySnapshot
    internal let producer: any ArchiveDirectoryProducer
    internal let engine: UUID
    internal let receivedOrigin: ReceivedItemOrigin
    internal let archiveFormat: ArchiveSourceFormat
    internal let publicProducedTreeV16: PublicProducedTreePurposeV16?
    private let lock = NSLock()
    private var consumed = false
    internal init(source: URL?, destination: URL, sourceIdentity: EntrySnapshot?, parentIdentity: EntrySnapshot,
                  producer: any ArchiveDirectoryProducer, engine: UUID, receivedOrigin: ReceivedItemOrigin = .download,
                  archiveFormat: ArchiveSourceFormat = .zip,
                  publicProducedTreeV16: PublicProducedTreePurposeV16? = nil) {
        self.source = source; self.destination = destination; parent = destination.deletingLastPathComponent()
        self.sourceIdentity = sourceIdentity; self.parentIdentity = parentIdentity; self.producer = producer; self.engine = engine
        self.receivedOrigin = receivedOrigin
        self.archiveFormat = archiveFormat
        self.publicProducedTreeV16 = publicProducedTreeV16
        files = producer.preview.files; folders = producer.preview.folders; logicalBytes = producer.preview.logicalBytes
    }
    internal func consume(by engine: UUID) -> Bool {
        lock.withLock { guard self.engine == engine, !consumed else { return false }; consumed = true; return true }
    }
}
internal struct ArchiveProductionHooks: Sendable {
    internal enum Stage: String, Sendable { case admitted, payloadCreated, produced, receiptsChecked, validated, synced, originalRetained, committed }
    var stage: (@Sendable (Stage, URL) throws -> Void)?
}

extension RecoverableFileOperations {
    @_spi(ArchiveProduction) public func prepareArchiveExtraction(source: URL, parent: URL, name: String,
        observing selection: FileOperationSelection, observingParent expectedParent: FileOperationSelection? = nil,
        format: ArchiveSourceFormat = .zip, publicQuarantineTreeV16: Bool = false,
        makeProducer: @escaping @Sendable (@Sendable () throws -> Void) throws -> any ArchiveDirectoryProducer) async throws -> ArchiveExtractionPlan {
        let tarPublic = format == .tar && publicQuarantineTreeV16
        return try await worker(archiveAction: tarPublic ? .tarRead : nil) { cancellation in
            if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
            try self.requireArchiveFixturePaths([source, parent.appendingPathComponent(name)])
            try validateName(name)
            let target = try DirectoryAnchor(parent)
            if let expectedParent {
                guard expectedParent.urls.count == 1, expectedParent.identities.count == 1,
                      expectedParent.urls[0] == target.url, expectedParent.identities[0].isDirectory else {
                    throw FileOperationFailure.invalidRequest
                }
                guard target.identity.sameObject(as: expectedParent.identities[0]) else {
                    throw FileOperationFailure.destinationChanged
                }
            }
            guard try NativeRenameVolume.qualified(in: target) != nil else { throw FileOperationFailure.unsupported }
            let selected = try observeObject(source)
            guard selected.snapshot.type == S_IFREG, selection.urls.count == 1, selection.identities.count == 1,
                  selection.urls[0] == selected.url, selection.identities[0] == selected.snapshot else { throw FileOperationFailure.sourceChanged }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.requireEntry(source); try protection.requireEntry(parent: target, name: name)
            try requireAbsent(name, in: target.fd); try cancellation.check()
            let producer = try makeProducer({ try cancellation.check() }), preview = producer.preview
            if tarPublic {
                do { try self.requireTARFixturePreview(preview) }
                catch { producer.finished(); throw error }
            }
            if publicQuarantineTreeV16 {
                let qualified: Bool
                switch (format, producer.publicProducedTreeV16) {
                case (.zip, .zipExtraction): qualified = self.zipTreePublicExtractionPolicy == .sourceQualification
                case (.tar, .tarExtraction): qualified = self.tarTreePublicExtractionPolicy == .sourceQualification
                default: qualified = false
                }
                guard qualified else {
                    producer.finished(); throw FileOperationFailure.unsupported
                }
            } else if producer.publicProducedTreeV16 != nil {
                producer.finished(); throw FileOperationFailure.invalidRequest
            }
            guard preview.files >= 0, preview.folders >= 0, preview.files <= 10_000, preview.folders < 20_000,
                  preview.files + preview.folders < 20_000, preview.logicalBytes <= 1_024 * 1_024 * 1_024,
                  preview.longestPathBytes >= 0, preview.longestPathBytes < PATH_MAX,
                  max(target.url.path.utf8.count + 74, target.url.path.utf8.count + name.utf8.count + 2)
                    + preview.longestPathBytes < PATH_MAX else { throw FileOperationFailure.unsupported }
            let plan = DirectoryProductionPlan(source: selected.url, destination: target.url.appendingPathComponent(name),
                sourceIdentity: selected.snapshot, parentIdentity: target.identity, producer: producer, engine: self.continuationSession,
                archiveFormat: format, publicProducedTreeV16: producer.publicProducedTreeV16)
            try self.validateArchiveExtraction(plan, cancellation: cancellation)
            return ArchiveExtractionPlan(plan, source: selected.url)
        }
    }
    public func performArchiveExtraction(_ plan: ArchiveExtractionPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await performDirectoryProduction(plan.production, progress: progress)
    }
    internal func performDirectoryProduction(_ plan: DirectoryProductionPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            let tarPublic = plan.archiveFormat == .tar && plan.publicProducedTreeV16?.isTARExtraction == true
            result = try await worker(progress: reporter,
                archiveAction: tarPublic ? .tarForward : nil) { cancellation in
                if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
                try self.requireArchiveFixturePaths([plan.source, plan.destination].compactMap { $0 })
                guard plan.consume(by: self.continuationSession) else { throw FileOperationFailure.invalidRequest }
                defer { plan.producer.finished() }
                try self.validateCopyExecutionSession(locations: [plan.source, plan.destination].compactMap { $0 }, directories: [plan.parent])
                try self.validateArchiveExtraction(plan, cancellation: cancellation)
                if tarPublic { try self.reserveTARFixturePreview(plan.producer.preview) }
                return self.extractArchive(plan, cancellation: cancellation)
            }
        } catch { result = archiveFailure(error, plan: plan, record: nil) }
        // A cancelled/capacity-refused admission never entered the worker. Only
        // the creating engine can retire its still-unused producer off-main.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                if plan.consume(by: self.continuationSession) { plan.producer.finished() }
                continuation.resume()
            }
        }
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }
    internal func validateArchiveExtraction(_ plan: DirectoryProductionPlan, cancellation: OperationCancellation) throws {
        try cancellation.check()
        try requireArchiveFixturePaths([plan.source, plan.destination].compactMap { $0 })
        if plan.archiveFormat == .tar && plan.publicProducedTreeV16?.isTARExtraction == true {
            try requireTARFixturePreview(plan.producer.preview)
        }
        guard plan.publicProducedTreeV16 == plan.producer.publicProducedTreeV16 else { throw FileOperationFailure.invalidRequest }
        if let purpose = plan.publicProducedTreeV16 {
            guard plan.producer is any PublicQuarantineTreeProducerV16 else { throw FileOperationFailure.invalidRequest }
            switch purpose {
            case .receivedFolder:
                guard plan.source == nil, plan.sourceIdentity == nil, plan.receivedOrigin == .download,
                      receivedFolderPublicQuarantinePolicy == .sourceQualification else { throw FileOperationFailure.unsupported }
            case .zipExtraction:
                guard plan.source != nil, plan.sourceIdentity?.type == S_IFREG, plan.archiveFormat == .zip,
                      zipTreePublicExtractionPolicy == .sourceQualification else { throw FileOperationFailure.unsupported }
            case .tarExtraction:
                guard plan.source != nil, plan.sourceIdentity?.type == S_IFREG, plan.archiveFormat == .tar,
                      tarTreePublicExtractionPolicy == .sourceQualification else { throw FileOperationFailure.unsupported }
            }
        }
        let target = try DirectoryAnchor(plan.parent, resolve: false)
        guard target.identity.sameObject(as: plan.parentIdentity), try NativeRenameVolume.qualified(in: target) != nil else { throw FileOperationFailure.destinationChanged }
        let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
        if let source = plan.source, let identity = plan.sourceIdentity {
            let sourceParent = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            guard try EntrySnapshot(parent: sourceParent.fd, name: source.lastPathComponent) == identity else { throw FileOperationFailure.sourceChanged }
            try protection.requireEntry(source); try sourceParent.validate()
        } else {
            guard plan.source == nil, plan.sourceIdentity == nil else { throw FileOperationFailure.invalidRequest }
        }
        try protection.requireEntry(parent: target, name: plan.destination.lastPathComponent)
        try requireAbsent(plan.destination.lastPathComponent, in: target.fd)
        try plan.producer.validate(check: { try cancellation.check() })
        try target.validate()
    }
    private func extractArchive(_ plan: DirectoryProductionPlan, cancellation: OperationCancellation) -> RecoverableOperationResult {
        var store: OperationJournal?, active: JournalEditSession?
        let label = plan.source == nil && plan.receivedOrigin == .download ? "folder-download" : "archive"
        var failureStage = label + "-admission"
        do {
            try hooks.archiveProduction.stage?(.admitted, plan.parent)
            let target = try DirectoryAnchor(plan.parent, resolve: false)
            guard target.identity.sameObject(as: plan.parentIdentity), try NativeRenameVolume.qualified(in: target) != nil else {
                throw FileOperationFailure.destinationChanged
            }
            try requireAbsent(plan.destination.lastPathComponent, in: target.fd)
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            if let source = plan.source { try protection.requireEntry(source) }
            try protection.requireEntry(parent: target, name: plan.destination.lastPathComponent)
            try target.validate(); try cancellation.check()
            let journal = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation); store = journal
            try protection.historyOpened(journal.anchor); try journal.validateWritableCatalog()
            try journal.reserveCapacity(steps: 1, areas: 1, locations: 4, trashIntents: 0,
                estimatedBytes: 24_576 + plan.parent.path.utf8.count * 16 + plan.destination.lastPathComponent.utf8.count * 8)
            try cancellation.check()
            let record = try plan.publicProducedTreeV16.map { try journal.beginProducedTreeV16Edit(purpose: $0) }
                ?? journal.beginEdit(operation: plan.source == nil ? plan.receivedOrigin.directoryHistoryTitle : plan.archiveFormat.historyTitle)
            active = record
            if let source = plan.source { try record.appendLocation(source) }; try journal.save(record)
            failureStage = label + "-staging"
            let area = try recoveryArea(in: target, record: record, journal: journal)
            guard mkdirat(area.fd, "payload", 0o700) == 0 else { throw posixFailure() }
            let payload = area.url.appendingPathComponent("payload", isDirectory: true)
            let descriptor = openat(area.fd, "payload", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw posixFailure() }; defer { close(descriptor) }
            try hooks.archiveProduction.stage?(.payloadCreated, payload)
            failureStage = label + "-production"
            cancellation.progress?.begin(.copying, source: plan.source, destination: plan.destination,
                bytes: Int64(plan.logicalBytes), items: plan.files + plan.folders)
            let check: @Sendable () throws -> Void = { try cancellation.check() }
            let progress: @Sendable (UInt64, Int) -> Void = { bytes, items in
                cancellation.progress?.advance(bytes: Int64(bytes), items: items)
            }
            let receipts: [ArchiveProducedNode]
            if plan.publicProducedTreeV16 != nil {
                guard let producer = plan.producer as? any PublicQuarantineTreeProducerV16 else {
                    throw FileOperationFailure.invalidRequest
                }
                receipts = try producer.produce(in: descriptor, at: payload, check: check, progress: progress)
            } else { receipts = try plan.producer.produce(in: descriptor, check: check, progress: progress) }
            try hooks.archiveProduction.stage?(.produced, payload)
            failureStage = label + "-verification"
            cancellation.progress?.begin(.verifying, destination: plan.destination)
            let proof = try validateArchiveReceipts(receipts, plan: plan, area: area, cancellation: cancellation)
            try hooks.archiveProduction.stage?(.receiptsChecked, payload)
            let tree = try verifiedTree(payload, cancellation: cancellation, expectedFileContents: proof.contents,
                expectedIdentities: proof.identities, expectedQuarantines: plan.publicProducedTreeV16 == nil ? proof.quarantines : nil,
                osManagedSecurityV1: plan.publicProducedTreeV16 != nil,
                publicTreeRequiresEveryNode: plan.publicProducedTreeV16?.requiresMarkOnEveryNode)
            try hooks.archiveProduction.stage?(.validated, payload)
            failureStage = label + "-sync"
            try hooks.beforeSync?(payload); try syncTree(payload, cancellation: cancellation)
            try syncDirectory(area); try syncDirectory(target)
            try hooks.archiveProduction.stage?(.synced, payload)
            try self.validateArchiveExtraction(plan, cancellation: cancellation)
            failureStage = label + "-publication"
            cancellation.progress?.begin(.publishing, destination: plan.destination)
            try renameStep(payload, plan.destination, expectedTree: tree,
                expectedQuarantines: plan.publicProducedTreeV16 == nil ? proof.quarantines : nil,
                record: record, journal: journal,
                cancellation: cancellation, protection: protection,
                osManagedSecurityV1: plan.publicProducedTreeV16 != nil,
                publicProducedTreeV16: plan.publicProducedTreeV16)
            failureStage = label + "-completion"
            record.setState("committed"); try journal.save(record)
            try hooks.archiveProduction.stage?(.committed, plan.destination)
            return .init(result: .init(items: [.init(source: plan.source, destination: plan.destination, status: .succeeded, recoveryURLs: [])],
                cancellationRequested: cancellation.isCancelled), recordID: record.id)
        } catch {
            if let store, let active { active.setState("needsReview"); active.setFailureStage(failureStage); try? store.save(active) }
            return archiveFailure(error, plan: plan, record: active?.snapshot, cancelled: cancellation.isCancelled)
        }
    }
    private func validateArchiveReceipts(_ receipts: [ArchiveProducedNode], plan: DirectoryProductionPlan, area: DirectoryAnchor,
                                         cancellation: OperationCancellation) throws -> (contents: [String: Data], identities: [String: EntrySnapshot],
                                            quarantines: [String: Data]) {
        guard receipts.count == plan.files + plan.folders + 1, receipts.count <= 20_000 else { throw FileOperationFailure.recoveryUncertain }
        let actual = try snapshotTree(parent: area.fd, name: "payload", cancellation: cancellation)
        guard actual.count == receipts.count else { throw FileOperationFailure.sourceChanged }
        var paths = Set<String>(), contents: [String: Data] = [:], identities: [String: EntrySnapshot] = [:],
            quarantines: [String: Data] = [:]
        var totalBytes: UInt64 = 0
        for receipt in receipts {
            try cancellation.check()
            guard plan.publicProducedTreeV16 == nil || receipt.expectedQuarantineSHA256 == nil
                && receipt.publicQuarantineV1 == nil && receipt.publicZIPExtractionMarkRequired == nil
                && receipt.publicTARExtractionMarkRequired == nil else {
                throw FileOperationFailure.copyMetadataMismatch
            }
            guard paths.insert(receipt.relative).inserted, let node = actual[receipt.relative], node.linkTarget == nil,
                  node.snapshot.device == receipt.device, node.snapshot.inode == receipt.inode, node.snapshot.type == receipt.kind,
                  node.snapshot.birthSeconds == receipt.birthSeconds, node.snapshot.birthNanos == receipt.birthNanoseconds,
                  node.snapshot.changedSeconds == receipt.changedSeconds, node.snapshot.changedNanos == receipt.changedNanoseconds,
                  [S_IFREG, S_IFDIR].contains(receipt.kind) else { throw FileOperationFailure.sourceChanged }
            if receipt.kind == S_IFREG {
                guard receipt.size == node.snapshot.size, receipt.size >= 0,
                      UInt64(receipt.size) <= plan.logicalBytes, totalBytes <= plan.logicalBytes - UInt64(receipt.size),
                      let digest = receipt.contentSHA256, digest.count == 32,
                      node.snapshot.mode & 0o7777 == 0o644 else { throw FileOperationFailure.copyContentMismatch }
                totalBytes += UInt64(receipt.size)
                contents[receipt.relative] = digest
            } else {
                guard receipt.contentSHA256 == nil, node.snapshot.mode & 0o7777 == 0o755 else { throw FileOperationFailure.sourceChanged }
            }
            if let expected = receipt.expectedQuarantineSHA256 {
                guard plan.publicProducedTreeV16 == nil else { throw FileOperationFailure.copyMetadataMismatch }
                guard expected.count == 32 else { throw FileOperationFailure.copyMetadataMismatch }
                quarantines[receipt.relative] = expected
            }
            identities[receipt.relative] = node.snapshot
        }
        guard contents.count == plan.files, totalBytes == plan.logicalBytes,
              actual[""]?.snapshot.isDirectory == true,
              plan.publicProducedTreeV16 == nil || quarantines.isEmpty else { throw FileOperationFailure.sourceChanged }
        return (contents, identities, quarantines)
    }
    private func archiveFailure(_ error: Error, plan: DirectoryProductionPlan, record: JournalRecord?, cancelled: Bool? = nil) -> RecoverableOperationResult {
        .init(result: .init(items: [.init(source: plan.source, destination: plan.destination, status: operationStatus(error), recoveryURLs: record?.locations ?? [])],
            cancellationRequested: cancelled ?? (error is CancellationError)), recordID: record?.id)
    }
}
