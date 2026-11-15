import CoreServices
import Darwin
import Foundation

/// The default remains exact source inheritance. The native-stage profile is
/// an explicit qualification candidate, not an ordinary app activation.
public enum AuthoredZIPMetadataPolicy: Sendable, Equatable {
    case exactSource
    /// Off-by-default qualification of a private APFS clone as the ZIP stage.
    /// The produced ZIP retains exact source metadata; a separately recorded
    /// native mark addition to the displaced original remains guarded.
    case exactSourceCloneQualification
    case nativeStageQualification
    /// Create-only: accept the fresh stage's native security observation.
    /// A marked source cannot supply a missing stage mark through raw rewriting.
    case nativeCreate
}

/// An authored archive's format is bound to its one-use production plan.
/// Received files have no authored format.
@_spi(ArchiveProduction) public enum AuthoredArchiveFormat: Sendable, Equatable {
    case zip
    /// Local regular files and directories. The encoder may use standard local
    /// PAX path/mtime records; this tag grants no ZIP native-mark treatment.
    case strictPortableTAR
    /// A gzip-encoded portable TAR; it has independent creation admission.
    case strictPortableTARGzip
    /// A bzip2-encoded portable TAR, independently admitted from gzip.
    case strictPortableTARBzip2

    public func acceptsFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return switch self {
        case .zip: lower.hasSuffix(".zip")
        case .strictPortableTAR: lower.hasSuffix(".tar")
        case .strictPortableTARGzip: lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
        case .strictPortableTARBzip2: lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2")
        }
    }
}

/// A separate, default-held engine admission for the development TAR route.
public enum StrictPortableTARCreationPolicy: Sendable, Equatable {
    case held
    case developmentExactSource
    /// Candidate only. Keep the fresh TAR stage's OS-created security mark;
    /// a marked input requires a marked stage, without copying raw input xattrs.
    case nativeCreateQualification
}

/// Local authored gzip-TAR only. It grants no received-data or compressed
/// original-update authority and remains held in ordinary engine composition.
public enum TARGzipCreationPolicy: Sendable, Equatable { case held, developmentNativeCreate }
/// Distinct from plain TAR updates and gzip creation; v19 alone can reverse
/// the native compressed-original replacement protocol.
public enum AuthoredTARGzipOriginalUpdatePolicy: Sendable, Equatable { case held, developmentNativeStage }
public enum TARBzip2CreationPolicy: Sendable, Equatable { case held, developmentNativeCreate }
/// v20 carries its own inverse authority; gzip and plain TAR cannot borrow it.
public enum AuthoredTARBzip2OriginalUpdatePolicy: Sendable, Equatable { case held, developmentNativeStage }

/// An independent, default-held extension for newly authored local ZIP/TAR.
/// It may initialize a fresh private Create stage from a marked-source fact;
/// it never copies source quarantine bytes or changes ZIP member Copy/Update.
public enum NativeAuthoredCreatePublicMarkPolicy: Sendable, Equatable {
    case held, sourceQualification
}

/// Independent qualification for an authored Update's empty private payload.
/// Create admission cannot authorize this route, and received data never uses it.
public enum NativeAuthoredUpdatePublicMarkPolicy: Sendable, Equatable { case held, sourceQualification }

/// Independent from Create/Copy so one engine can retain its accepted native
/// authoring contract while a new Original Update record remains off by default.
public enum AuthoredZIPOriginalUpdateNativePolicy: Sendable, Equatable {
    case held
    /// Off-by-default v13 candidate: use the fresh replacement stage's native
    /// security and keep the displaced original for guarded cold Undo.
    case qualifiedNativeStage
}

/// TAR original replacement is a separate development qualification. Enabling
/// ZIP updates never admits this format or its inverse history records.
public enum AuthoredTAROriginalUpdatePolicy: Sendable, Equatable {
    case held, developmentNativeStage
}

/// Transient raw security data from one owned authored-archive payload. It is never stored
/// in the operation journal or sent to diagnostics.
@_spi(ArchiveProduction) public struct AuthoredZIPSecurityWitness: Equatable, Sendable {
    public let quarantine: Data?
    public let provenance: Data?
    public init(quarantine: Data?, provenance: Data?) {
        self.quarantine = quarantine; self.provenance = provenance
    }
    internal static func observe(_ fd: Int32) throws -> Self {
        let metadata = try ArchiveOriginalRootMetadata.observe(fd)
        return .init(quarantine: metadata.quarantine, provenance: metadata.provenance)
    }
    internal static func observe(_ url: URL) throws -> Self {
        let metadata = try ArchiveOriginalRootMetadata.observe(url)
        return .init(quarantine: metadata.quarantine, provenance: metadata.provenance)
    }
    internal func requireMatch(_ fd: Int32) throws {
        guard try Self.observe(fd) == self else { throw FileOperationFailure.copyMetadataMismatch }
    }
    internal func requireMatch(_ url: URL) throws {
        guard try Self.observe(url) == self else { throw FileOperationFailure.copyMetadataMismatch }
    }
    internal func requirePublished(parent: Int32, name: String, identity: EntrySnapshot) throws {
        let before = try EntrySnapshot(parent: parent, name: name)
        guard before.sameObject(as: identity) else { throw FileOperationFailure.recoveryUncertain }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileOperationFailure.recoveryUncertain }
        defer { close(fd) }
        guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.recoveryUncertain }
        try requireMatch(fd)
        guard try EntrySnapshot(fd: fd) == before,
              try EntrySnapshot(parent: parent, name: name) == before else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}

@_spi(ArchiveProduction) public struct AuthoredZIPProducedFile: Sendable {
    public let node: ArchiveProducedNode
    public let security: AuthoredZIPSecurityWitness
    public init(node: ArchiveProducedNode, security: AuthoredZIPSecurityWitness) {
        self.node = node; self.security = security
    }
}

/// Concrete local ZIP/TAR edit producers implement this path. Generic
/// producers, received files and extraction retain their existing policy.
@_spi(ArchiveProduction) public protocol NativeAuthoredArchiveFileProducer: ArchiveFileProducer {
    var authoredArchiveFormat: AuthoredArchiveFormat { get }
    var hasMarkedSource: Bool { get }
    func produceNativeArchive(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness,
        allowSourceMarkInheritance: Bool, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> AuthoredZIPProducedFile
    func requirePublicQuarantineRecognition(_ descriptor: Int32, at url: URL) throws
}

@_spi(ArchiveProduction) public protocol AuthoredZIPFileProducer: NativeAuthoredArchiveFileProducer {
    func produceAuthoredZIP(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness,
        allowSourceMarkInheritance: Bool,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> AuthoredZIPProducedFile
    func requirePublicQuarantineRecognition(_ descriptor: Int32, at url: URL) throws
}

@_spi(ArchiveProduction) public extension AuthoredZIPFileProducer {
    var authoredArchiveFormat: AuthoredArchiveFormat { .zip }
    func produceNativeArchive(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness,
        allowSourceMarkInheritance: Bool, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> AuthoredZIPProducedFile {
        try produceAuthoredZIP(into: descriptor, stageSecurity: stageSecurity,
            allowSourceMarkInheritance: allowSourceMarkInheritance, check: check, progress: progress)
    }
}

@_spi(ArchiveProduction) public protocol ArchiveFileProducer: Sendable {
    var preview: ArchiveProductionPreview { get }
    func validate(check: @Sendable () throws -> Void) throws
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode
    /// After a consumed worker drains, or an unused received plan is retired.
    func finished()
}
@_spi(ArchiveProduction) public extension ArchiveFileProducer { func finished() {} }

/// Concrete local TAR creation producers opt in to the strict TAR route.
@_spi(ArchiveProduction) public protocol StrictPortableTARFileProducer: ArchiveFileProducer {}

/// Separate source-only received Download candidate. Its private stage is
/// marked through documented URL resource values before body publication.
@_spi(ArchiveProduction) public protocol PublicQuarantineReceivedFileProducer: ArchiveFileProducer {
    func producePublicQuarantined(into descriptor: Int32, at stageURL: URL,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode
}

/// Concrete archive-member producers share the private file stage and guarded
/// rename worker. Each format keeps its own source policy and journal version.
@_spi(ArchiveProduction) public protocol PublicQuarantineArchiveExtractionFileProducer: ArchiveFileProducer {
    func producePublicExtracted(into descriptor: Int32, at stageURL: URL,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode
}
@_spi(ArchiveProduction) public protocol PublicQuarantineZIPExtractionFileProducer:
    PublicQuarantineArchiveExtractionFileProducer {}
@_spi(ArchiveProduction) public protocol PublicQuarantineTARExtractionFileProducer:
    PublicQuarantineArchiveExtractionFileProducer {}

/// Existing prepared local Create producer reports only whether an observed
/// source mark requires a native mark on its fresh stage.
@_spi(ArchiveProduction) public protocol NativeZIPCreationSourceWitness: ArchiveFileProducer {
    var hasMarkedSource: Bool { get }
}

/// The TAR writer shares the local inventory, but its admission is independent
/// of ZIP's native Create policy.
@_spi(ArchiveProduction) public protocol TARCreationSourceWitness: StrictPortableTARFileProducer {
    var hasMarkedSource: Bool { get }
    var authoredArchiveFormat: AuthoredArchiveFormat { get }
}
@_spi(ArchiveProduction) public extension TARCreationSourceWitness {
    var authoredArchiveFormat: AuthoredArchiveFormat { .strictPortableTAR }
}

/// Native callers receive a one-use plan, never a staging descriptor.
public final class ArchiveCreationPlan: @unchecked Sendable {
    public let sources: [URL], destination: URL
    /// Observed root kinds for the review; this is not a current access grant.
    public let directorySources: [URL]
    public let files: Int, folders: Int
    public let logicalBytes: UInt64
    public var addedItems: [ArchiveAddedItemPreview] { producer.preview.addedItems }
    internal let parent: URL
    internal let parentIdentity: EntrySnapshot
    /// Every selected root keeps its own parent witness. A ZIP and added
    /// local items need not live in the same directory or on the same drive.
    internal let sourceParents: [URL: EntrySnapshot]
    internal let sourcesIdentity: [EntrySnapshot]
    internal let producer: any ArchiveFileProducer
    internal let authoredFormat: AuthoredArchiveFormat?
    internal let engine: UUID
    internal let receivedFile: Bool
    internal let publicQuarantineReceivedFile: Bool
    internal let publicZIPExtractionFile: Bool
    internal let publicTARExtractionFile: Bool
    internal let receivedOrigin: ReceivedItemOrigin
    private let lock = NSLock()
    private var consumed = false
    internal init(sources: [URL], destination: URL, sourcesIdentity: [EntrySnapshot], sourceParents: [URL: EntrySnapshot],
                  parentIdentity: EntrySnapshot, producer: any ArchiveFileProducer, engine: UUID,
                  authoredFormat: AuthoredArchiveFormat?, receivedFile: Bool = false,
                  receivedOrigin: ReceivedItemOrigin = .download, publicQuarantineReceivedFile: Bool = false,
                  publicZIPExtractionFile: Bool = false, publicTARExtractionFile: Bool = false) {
        self.sources = sources; self.destination = destination; self.sourcesIdentity = sourcesIdentity
        directorySources = zip(sources, sourcesIdentity).compactMap { $0.1.isDirectory ? $0.0 : nil }
        parent = destination.deletingLastPathComponent()
        self.sourceParents = sourceParents; self.parentIdentity = parentIdentity
        self.producer = producer; self.engine = engine; self.authoredFormat = authoredFormat
        self.receivedFile = receivedFile
        self.receivedOrigin = receivedOrigin
        self.publicQuarantineReceivedFile = publicQuarantineReceivedFile
        self.publicZIPExtractionFile = publicZIPExtractionFile
        self.publicTARExtractionFile = publicTARExtractionFile
        files = producer.preview.files; folders = producer.preview.folders; logicalBytes = producer.preview.logicalBytes
    }
    internal func consume(by engine: UUID) -> Bool {
        lock.withLock { guard self.engine == engine, !consumed else { return false }; consumed = true; return true }
    }
}

extension RecoverableFileOperations {
    /// Open a pinned authored ZIP and clone it into the absent, private payload
    /// name. A native clone is the only admissible stage in this qualification:
    /// a fresh-file fallback would recreate the metadata transition it tests.
    internal func exactSourceCloneStage(source url: URL, identity: EntrySnapshot,
        parentIdentity: EntrySnapshot, in area: DirectoryAnchor,
        requireCopyMode: Bool) throws -> (descriptor: Int32, metadata: ArchiveOriginalRootMetadata,
                                         identity: EntrySnapshot) {
        let sourceParent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        guard sourceParent.identity.sameObject(as: parentIdentity),
              let sourceVolume = try NativeRenameVolume.qualified(in: sourceParent),
              let stageVolume = try NativeRenameVolume.qualified(in: area),
              sourceVolume == stageVolume, identity.device == area.identity.device else {
            throw FileOperationFailure.unsupported
        }
        try sourceParent.validate(); try area.validate()
        let source = openat(sourceParent.fd, url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw posixFailure() }
        defer { close(source) }
        guard try EntrySnapshot(fd: source) == identity,
              try EntrySnapshot(parent: sourceParent.fd, name: url.lastPathComponent) == identity else {
            throw FileOperationFailure.sourceChanged
        }
        let metadata = try ArchiveOriginalRootMetadata.observe(source)
        // A cloned tracked file can inherit a native document ID. Its proper
        // distinct-ID transition needs separate qualification.
        guard metadata.flags == 0, !requireCopyMode || metadata.mode == 0o644 else {
            throw FileOperationFailure.unsupported
        }
        try requireAbsent("payload", in: area.fd)
        guard fclonefileat(source, area.fd, "payload", 0) == 0 else { throw posixFailure() }
        let payload = openat(area.fd, "payload", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard payload >= 0 else { throw posixFailure() }
        do {
            let stage = try EntrySnapshot(fd: payload)
            guard stage == (try EntrySnapshot(parent: area.fd, name: "payload")),
                  stage.type == S_IFREG, stage.device == identity.device,
                  stage.inode != identity.inode else {
                throw FileOperationFailure.copyMetadataMismatch
            }
            try metadata.requireMatch(payload)
            guard ftruncate(payload, 0) == 0 else { throw posixFailure() }
            try metadata.requireMatch(payload)
            guard try EntrySnapshot(fd: source) == identity,
                  try EntrySnapshot(parent: sourceParent.fd, name: url.lastPathComponent) == identity else {
                throw FileOperationFailure.sourceChanged
            }
            try metadata.requireMatch(source)
            try sourceParent.validate(); try area.validate()
            return (payload, metadata, try EntrySnapshot(fd: payload))
        } catch {
            close(payload)
            throw error
        }
    }

    /// Foundation's quarantine view is path based. Bracket that observation
    /// with the pinned descriptor, exact raw mark and parent-relative identity.
    internal func requireAuthoredZIPPublicQuarantine(_ security: AuthoredZIPSecurityWitness,
        producer: any NativeAuthoredArchiveFileProducer, descriptor: Int32,
        parent: DirectoryAnchor, name: String, identity: EntrySnapshot) throws {
        try parent.validate()
        let before = try EntrySnapshot(parent: parent.fd, name: name)
        guard before.sameObject(as: identity), try EntrySnapshot(fd: descriptor) == before else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        try security.requireMatch(descriptor)
        do {
            try producer.requirePublicQuarantineRecognition(descriptor,
                at: parent.url.appendingPathComponent(name))
        } catch { throw FileOperationFailure.copyMetadataMismatch }
        try parent.validate()
        guard try EntrySnapshot(fd: descriptor) == before,
              try EntrySnapshot(parent: parent.fd, name: name) == before else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        try security.requireMatch(descriptor)
    }

    /// Generic local Create has no authored-source ZIP producer. Its fresh
    /// payload still needs a pinned raw/public native-mark observation.
    internal func requireNativeCreatePublicQuarantine(_ security: AuthoredZIPSecurityWitness,
        descriptor: Int32, parent: DirectoryAnchor, name: String,
        identity: EntrySnapshot) throws {
        try parent.validate()
        let before = try EntrySnapshot(parent: parent.fd, name: name)
        guard before.sameObject(as: identity), try EntrySnapshot(fd: descriptor) == before else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        try security.requireMatch(descriptor)
        let properties = try parent.url.appendingPathComponent(name)
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        guard (security.quarantine != nil) == (properties != nil),
              try EntrySnapshot(fd: descriptor) == before,
              try EntrySnapshot(parent: parent.fd, name: name) == before else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        try security.requireMatch(descriptor)
    }

    /// A new authored archive is a different object from every selected input.
    /// For an independently qualified Create or Update, initialize only its empty private
    /// stage when a marked input needs protection and the OS left it unmarked.
    internal func prepareNativeAuthoredPublicStageMark(_ descriptor: Int32,
        parent: DirectoryAnchor, name: String) throws {
        try parent.validate()
        var directoryFacts = stat(), stageFacts = stat()
        guard fstat(parent.fd, &directoryFacts) == 0,
              directoryFacts.st_mode & S_IFMT == S_IFDIR,
              directoryFacts.st_uid == geteuid(),
              directoryFacts.st_mode & 0o7777 == 0o700,
              fstat(descriptor, &stageFacts) == 0,
              stageFacts.st_mode & S_IFMT == S_IFREG,
              stageFacts.st_uid == geteuid(), stageFacts.st_nlink == 1,
              stageFacts.st_size == 0, stageFacts.st_mode & 0o7777 == 0o600 else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        let before = try EntrySnapshot(fd: descriptor)
        guard try EntrySnapshot(parent: parent.fd, name: name) == before else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        let existing = try AuthoredZIPSecurityWitness.observe(descriptor)
        try requireNativeCreatePublicQuarantine(existing, descriptor: descriptor,
            parent: parent, name: name, identity: before)
        let stageURL = parent.url.appendingPathComponent(name)
        if existing.quarantine == nil {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "Traverse",
                kLSQuarantineTimeStampKey as String: Date()
            ]
            var target = stageURL
            do { try target.setResourceValues(values) }
            catch { throw FileOperationFailure.copyMetadataMismatch }
        }
        // A path-based public setter can change ctime. Bind the post-write
        // security and full identity as the producer's new stage baseline.
        try parent.validate()
        guard fstat(parent.fd, &directoryFacts) == 0,
              directoryFacts.st_mode & S_IFMT == S_IFDIR,
              directoryFacts.st_uid == geteuid(),
              directoryFacts.st_mode & 0o7777 == 0o700,
              fstat(descriptor, &stageFacts) == 0,
              stageFacts.st_mode & S_IFMT == S_IFREG,
              stageFacts.st_uid == geteuid(), stageFacts.st_nlink == 1,
              stageFacts.st_size == 0, stageFacts.st_mode & 0o7777 == 0o600 else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        let after = try EntrySnapshot(fd: descriptor)
        guard after.sameObject(as: before),
              try EntrySnapshot(parent: parent.fd, name: name) == after else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        let security = try AuthoredZIPSecurityWitness.observe(descriptor)
        // Public marking may also create opaque OS metadata on an unmarked
        // object. An existing native mark takes no setter and stays exact.
        guard security.quarantine != nil,
              existing.quarantine == nil || (security.quarantine == existing.quarantine
                  && security.provenance == existing.provenance) else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        try requireNativeCreatePublicQuarantine(security, descriptor: descriptor,
            parent: parent, name: name, identity: after)
        if existing.quarantine == nil {
            let properties = try URL(fileURLWithPath: stageURL.path)
                .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            guard properties?[kLSQuarantineAgentNameKey as String] as? String == "Traverse",
                  properties?[kLSQuarantineTimeStampKey as String] is Date,
                  try EntrySnapshot(fd: descriptor) == after,
                  try EntrySnapshot(parent: parent.fd, name: name) == after else {
                throw FileOperationFailure.copyMetadataMismatch
            }
            try security.requireMatch(descriptor)
        }
    }

    @_spi(ArchiveProduction) public func prepareArchiveCreation(sources: [URL], parent: URL, name: String,
        observing selection: FileOperationSelection, authoredFormat: AuthoredArchiveFormat = .zip,
        makeProducer: @escaping @Sendable (@Sendable () throws -> Void) throws -> any ArchiveFileProducer) async throws -> ArchiveCreationPlan {
        try await worker { cancellation in
            if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
            if authoredFormat == .strictPortableTAR {
                switch self.strictPortableTARCreationPolicy {
                case .held: throw FileOperationFailure.unsupported
                case .developmentExactSource:
                    guard self.authoredZIPMetadataPolicy == .exactSource else { throw FileOperationFailure.unsupported }
                case .nativeCreateQualification: break
                }
            }
            if authoredFormat == .strictPortableTARGzip, self.tarGzipCreationPolicy != .developmentNativeCreate {
                throw FileOperationFailure.unsupported
            }
            if authoredFormat == .strictPortableTARBzip2, self.tarBzip2CreationPolicy != .developmentNativeCreate {
                throw FileOperationFailure.unsupported
            }
            guard !sources.isEmpty, sources.count <= 512, sources.count == selection.urls.count,
                  sources.count == selection.identities.count else { throw FileOperationFailure.invalidRequest }
            try validateName(name)
            let target = try DirectoryAnchor(parent)
            guard try NativeRenameVolume.qualified(in: target) != nil,
                  target.url.path.utf8.count + max(name.utf8.count + 2, 74) < PATH_MAX else { throw FileOperationFailure.unsupported }
            let observed = try sources.map { try cancellation.check(); return try observeObject($0) }
            guard observed.map(\.url) == selection.urls, observed.map(\.snapshot) == selection.identities,
                  Set(observed.map(\.url)).count == sources.count,
                  observed.allSatisfy({ [S_IFREG, S_IFDIR].contains($0.snapshot.type) }) else { throw FileOperationFailure.sourceChanged }
            var sourceParents: [URL: EntrySnapshot] = [:]
            for source in observed {
                let parentURL = source.url.deletingLastPathComponent()
                if sourceParents[parentURL] == nil {
                    let anchor = try DirectoryAnchor(parentURL, resolve: false)
                    sourceParents[parentURL] = anchor.identity
                    try anchor.validate()
                }
            }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            for source in observed {
                try cancellation.check(); try protection.requireEntry(source.url)
                if source.snapshot.isDirectory, target.url.path == source.url.path || target.url.path.hasPrefix(source.url.path + "/") {
                    throw FileOperationFailure.invalidRequest
                }
            }
            try protection.requireEntry(parent: target, name: name); try requireAbsent(name, in: target.fd)
            let producer = try makeProducer({ try cancellation.check() }), preview = producer.preview
            guard preview.files >= 0, preview.folders >= 0, preview.files <= 10_000, preview.folders < 20_000,
                  preview.files + preview.folders < 20_000, preview.logicalBytes <= 1_024 * 1_024 * 1_024 else { throw FileOperationFailure.unsupported }
            let plan = ArchiveCreationPlan(sources: observed.map(\.url), destination: target.url.appendingPathComponent(name),
                sourcesIdentity: observed.map(\.snapshot), sourceParents: sourceParents, parentIdentity: target.identity,
                producer: producer, engine: self.continuationSession, authoredFormat: authoredFormat)
            try self.validateArchiveCreation(plan, cancellation: cancellation)
            return plan
        }
    }
    public func performArchiveCreation(_ plan: ArchiveCreationPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
                guard plan.consume(by: self.continuationSession) else { throw FileOperationFailure.invalidRequest }
                defer { plan.producer.finished() }
                try self.validateCopyExecutionSession(locations: plan.sources + [plan.destination], directories: [plan.parent] + Array(plan.sourceParents.keys))
                try self.validateArchiveCreation(plan, cancellation: cancellation)
                return self.createArchive(plan, cancellation: cancellation).result
            }
        } catch { result = archiveCreationFailure(error, plan: plan, record: nil) }
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }
    internal func validateArchiveCreation(_ plan: ArchiveCreationPlan, cancellation: OperationCancellation) throws {
        try cancellation.check()
        switch plan.authoredFormat {
        case .zip:
            guard !plan.receivedFile, !(plan.producer is any StrictPortableTARFileProducer) else {
                throw FileOperationFailure.unsupported
            }
        case .strictPortableTAR, .strictPortableTARGzip, .strictPortableTARBzip2:
            let tarSource = plan.producer as? any TARCreationSourceWitness
            let admitted: Bool
            if plan.authoredFormat == .strictPortableTARGzip {
                admitted = tarGzipCreationPolicy == .developmentNativeCreate && tarSource != nil
            } else if plan.authoredFormat == .strictPortableTARBzip2 {
                admitted = tarBzip2CreationPolicy == .developmentNativeCreate && tarSource != nil
            } else { switch strictPortableTARCreationPolicy {
            case .held: admitted = false
            case .developmentExactSource:
                admitted = authoredZIPMetadataPolicy == .exactSource && tarSource?.hasMarkedSource == false
            case .nativeCreateQualification: admitted = tarSource != nil
            } }
            guard !plan.receivedFile, !plan.publicQuarantineReceivedFile,
                  !plan.publicZIPExtractionFile, !plan.publicTARExtractionFile,
                  admitted, tarSource?.authoredArchiveFormat == plan.authoredFormat,
                  plan.producer is any StrictPortableTARFileProducer,
                  !(plan.producer is any AuthoredZIPFileProducer),
                  !(plan.producer is any NativeZIPCreationSourceWitness) else {
                throw FileOperationFailure.unsupported
            }
        case nil:
            guard plan.receivedFile, !(plan.producer is any StrictPortableTARFileProducer) else {
                throw FileOperationFailure.unsupported
            }
        }
        if plan.publicQuarantineReceivedFile {
            guard plan.receivedFile, plan.receivedOrigin == .download,
                  receivedDownloadPublicQuarantinePolicy == .sourceQualification,
                  plan.producer is any PublicQuarantineReceivedFileProducer else {
                throw FileOperationFailure.unsupported
            }
        }
        if plan.publicZIPExtractionFile {
            guard !plan.publicQuarantineReceivedFile, !plan.publicTARExtractionFile, plan.receivedFile,
                  plan.receivedOrigin == .zipExtraction,
                  zipOneFilePublicExtractionPolicy == .sourceQualification,
                  plan.producer is any PublicQuarantineZIPExtractionFileProducer else {
                throw FileOperationFailure.unsupported
            }
        }
        if plan.publicTARExtractionFile {
            guard !plan.publicQuarantineReceivedFile, !plan.publicZIPExtractionFile, plan.receivedFile,
                  plan.receivedOrigin == .tarExtraction,
                  tarOneFilePublicExtractionPolicy == .sourceQualification,
                  plan.producer is any PublicQuarantineTARExtractionFileProducer else {
                throw FileOperationFailure.unsupported
            }
        }
        let target = try DirectoryAnchor(plan.parent, resolve: false)
        guard target.identity.sameObject(as: plan.parentIdentity), try NativeRenameVolume.qualified(in: target) != nil else { throw FileOperationFailure.destinationChanged }
        let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
        if !plan.sourceParents.isEmpty {
            guard !plan.receivedFile, !plan.sources.isEmpty, plan.sources.count == plan.sourcesIdentity.count,
                  Set(plan.sourceParents.keys) == Set(plan.sources.map { $0.deletingLastPathComponent() }) else { throw FileOperationFailure.invalidRequest }
            var anchors: [URL: DirectoryAnchor] = [:]
            for (url, identity) in plan.sourceParents {
                let source = try DirectoryAnchor(url, resolve: false)
                guard source.identity.sameObject(as: identity) else { throw FileOperationFailure.sourceChanged }
                anchors[url] = source
            }
            for (url, snapshot) in zip(plan.sources, plan.sourcesIdentity) {
                try cancellation.check(); try protection.requireEntry(url)
                guard let source = anchors[url.deletingLastPathComponent()] else { throw FileOperationFailure.invalidRequest }
                guard try EntrySnapshot(parent: source.fd, name: url.lastPathComponent) == snapshot else { throw FileOperationFailure.sourceChanged }
            }
            for source in anchors.values { try source.validate() }
        } else {
            guard plan.receivedFile, plan.sources.isEmpty, plan.sourcesIdentity.isEmpty else { throw FileOperationFailure.invalidRequest }
        }
        try protection.requireEntry(parent: target, name: plan.destination.lastPathComponent)
        try requireAbsent(plan.destination.lastPathComponent, in: target.fd)
        try plan.producer.validate(check: { try cancellation.check() })
        try target.validate()
    }
    internal func createArchive(_ plan: ArchiveCreationPlan, cancellation: OperationCancellation) -> OneFileProductionExecution {
        var store: OperationJournal?, active: JournalEditSession?
        var publicationAttempted = false
        let label = plan.receivedFile ? plan.receivedOrigin.diagnosticPrefix
            : plan.authoredFormat == .strictPortableTAR ? "tar"
            : plan.authoredFormat == .strictPortableTARGzip ? "tar-gzip"
            : plan.authoredFormat == .strictPortableTARBzip2 ? "tar-bzip2" : "archive"
        var failureStage = label + "-admission"
        do {
            try hooks.archiveProduction.stage?(.admitted, plan.parent)
            let target = try DirectoryAnchor(plan.parent, resolve: false)
            guard target.identity.sameObject(as: plan.parentIdentity), try NativeRenameVolume.qualified(in: target) != nil else { throw FileOperationFailure.destinationChanged }
            try requireAbsent(plan.destination.lastPathComponent, in: target.fd)
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            for source in plan.sources { try cancellation.check(); try protection.requireEntry(source) }
            try protection.requireEntry(parent: target, name: plan.destination.lastPathComponent); try target.validate()
            let journal = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation); store = journal
            try protection.historyOpened(journal.anchor); try journal.validateWritableCatalog()
            try journal.reserveCapacity(steps: 1, areas: 1, locations: plan.sources.count + 3, trashIntents: 0,
                estimatedBytes: 24_576 + plan.sources.reduce(0, { $0 + $1.path.utf8.count * 4 }) + plan.parent.path.utf8.count * 16)
            try cancellation.check()
            let record: JournalEditSession
            if plan.publicQuarantineReceivedFile { record = try journal.beginReceivedPublicDownloadEdit() }
            else if plan.publicZIPExtractionFile { record = try journal.beginPublicZIPExtractionEdit() }
            else if plan.publicTARExtractionFile { record = try journal.beginPublicTARExtractionEdit() }
            else { record = try journal.beginEdit(operation: plan.receivedFile ? plan.receivedOrigin.fileHistoryTitle
                : plan.authoredFormat == .strictPortableTAR ? "Create TAR"
                : plan.authoredFormat == .strictPortableTARGzip ? "Create TAR.gz"
                : plan.authoredFormat == .strictPortableTARBzip2 ? "Create TAR.bz2" : "Create ZIP") }
            active = record
            for source in plan.sources { try record.appendLocation(source) }; try journal.save(record)
            failureStage = label + "-staging"
            let area = try recoveryArea(in: target, record: record, journal: journal)
            let exactClone: (descriptor: Int32, metadata: ArchiveOriginalRootMetadata,
                             identity: EntrySnapshot)?
            if plan.authoredFormat == .zip,
               case .exactSourceCloneQualification = authoredZIPMetadataPolicy,
               !plan.receivedFile, plan.producer is any AuthoredZIPFileProducer {
                guard plan.sources.count == 1, plan.sourcesIdentity.count == 1,
                      let source = plan.sources.first,
                      let parentIdentity = plan.sourceParents[source.deletingLastPathComponent()] else {
                    throw FileOperationFailure.invalidRequest
                }
                exactClone = try exactSourceCloneStage(source: source, identity: plan.sourcesIdentity[0],
                    parentIdentity: parentIdentity, in: area, requireCopyMode: true)
            } else { exactClone = nil }
            let descriptor = exactClone?.descriptor ?? openat(area.fd, "payload",
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixFailure() }; defer { close(descriptor) }
            let payload = area.url.appendingPathComponent("payload")
            try hooks.archiveProduction.stage?(.payloadCreated, payload)
            try exactClone?.metadata.requireMatch(descriptor)
            if let exactClone {
                guard try EntrySnapshot(fd: descriptor).sameObject(as: exactClone.identity),
                      try EntrySnapshot(parent: area.fd, name: "payload").sameObject(as: exactClone.identity) else {
                    throw FileOperationFailure.copyMetadataMismatch
                }
            }
            let authoredZIP: (any AuthoredZIPFileProducer)?
            let nativeCreate = plan.authoredFormat == .zip && {
                if case .nativeCreate = authoredZIPMetadataPolicy { return true }
                return false
            }()
            let nativeTARCreate = plan.authoredFormat == .strictPortableTAR
                && strictPortableTARCreationPolicy == .nativeCreateQualification
                || plan.authoredFormat == .strictPortableTARGzip && tarGzipCreationPolicy == .developmentNativeCreate
                || plan.authoredFormat == .strictPortableTARBzip2 && tarBzip2CreationPolicy == .developmentNativeCreate
            let nativeArchiveCreate = nativeCreate || nativeTARCreate
            if plan.authoredFormat == .zip && (authoredZIPMetadataPolicy == .nativeStageQualification || nativeCreate) {
                authoredZIP = plan.producer as? any AuthoredZIPFileProducer
            } else { authoredZIP = nil }
            let nativeCreateMarkedSource: Bool
            if nativeTARCreate {
                guard let source = plan.producer as? any TARCreationSourceWitness else {
                    throw FileOperationFailure.unsupported
                }
                nativeCreateMarkedSource = source.hasMarkedSource
            } else if nativeCreate && authoredZIP == nil {
                let source = plan.producer as? any NativeZIPCreationSourceWitness
                if nativeAuthoredCreatePublicMarkPolicy == .sourceQualification && source == nil {
                    throw FileOperationFailure.unsupported
                }
                nativeCreateMarkedSource = source?.hasMarkedSource == true
            } else { nativeCreateMarkedSource = false }
            if nativeArchiveCreate, authoredZIP == nil, nativeCreateMarkedSource,
               nativeAuthoredCreatePublicMarkPolicy == .sourceQualification {
                try prepareNativeAuthoredPublicStageMark(descriptor, parent: area, name: "payload")
            }
            let stageIdentity: EntrySnapshot?
            if let exactClone { stageIdentity = exactClone.identity }
            else if authoredZIP != nil || nativeArchiveCreate || plan.publicQuarantineReceivedFile
                || plan.publicZIPExtractionFile || plan.publicTARExtractionFile {
                stageIdentity = try EntrySnapshot(fd: descriptor)
            }
            else { stageIdentity = nil }
            let stageSecurity: AuthoredZIPSecurityWitness?
            if authoredZIP != nil || nativeArchiveCreate { stageSecurity = try AuthoredZIPSecurityWitness.observe(descriptor) }
            else { stageSecurity = nil }
            if let authoredZIP, let stageIdentity, let stageSecurity {
                try requireAuthoredZIPPublicQuarantine(stageSecurity, producer: authoredZIP,
                    descriptor: descriptor, parent: area, name: "payload", identity: stageIdentity)
            }
            if nativeArchiveCreate, authoredZIP == nil, let stageIdentity, let stageSecurity {
                if nativeCreateMarkedSource && stageSecurity.quarantine == nil {
                    throw FileOperationFailure.copyMetadataMismatch
                }
                try requireNativeCreatePublicQuarantine(stageSecurity, descriptor: descriptor,
                    parent: area, name: "payload", identity: stageIdentity)
            }
            if let exactClone, let producer = plan.producer as? any AuthoredZIPFileProducer {
                let security = AuthoredZIPSecurityWitness(
                    quarantine: exactClone.metadata.quarantine, provenance: exactClone.metadata.provenance)
                try requireAuthoredZIPPublicQuarantine(security, producer: producer,
                    descriptor: descriptor, parent: area, name: "payload", identity: exactClone.identity)
            }
            failureStage = label + "-production"
            cancellation.progress?.begin(.copying, destination: plan.destination, bytes: Int64(plan.logicalBytes), items: plan.files + plan.folders)
            let receipt: ArchiveProducedNode
            let producedSecurity: AuthoredZIPSecurityWitness?
            if let authoredZIP, let stageSecurity {
                let produced = try authoredZIP.produceAuthoredZIP(into: descriptor, stageSecurity: stageSecurity,
                    allowSourceMarkInheritance: !nativeCreate,
                    check: { try cancellation.check() },
                    progress: { bytes, items in cancellation.progress?.advance(bytes: Int64(bytes), items: items) })
                receipt = produced.node; producedSecurity = produced.security
                try produced.security.requireMatch(descriptor)
            } else if plan.publicQuarantineReceivedFile,
                      let producer = plan.producer as? any PublicQuarantineReceivedFileProducer {
                receipt = try producer.producePublicQuarantined(into: descriptor, at: payload,
                    check: { try cancellation.check() },
                    progress: { bytes, items in cancellation.progress?.advance(bytes: Int64(bytes), items: items) })
                producedSecurity = nil
            } else if (plan.publicZIPExtractionFile || plan.publicTARExtractionFile),
                      let producer = plan.producer as? any PublicQuarantineArchiveExtractionFileProducer {
                receipt = try producer.producePublicExtracted(into: descriptor, at: payload,
                    check: { try cancellation.check() },
                    progress: { bytes, items in cancellation.progress?.advance(bytes: Int64(bytes), items: items) })
                producedSecurity = nil
            } else {
                receipt = try plan.producer.produce(into: descriptor, check: { try cancellation.check() },
                    progress: { bytes, items in cancellation.progress?.advance(bytes: Int64(bytes), items: items) })
                producedSecurity = nativeArchiveCreate ? stageSecurity : nil
                try producedSecurity?.requireMatch(descriptor)
            }
            try exactClone?.metadata.requireMatch(descriptor)
            try hooks.archiveProduction.stage?(.produced, payload)
            failureStage = label + "-verification"
            cancellation.progress?.begin(.verifying, destination: plan.destination)
            let actual = try EntrySnapshot(parent: area.fd, name: "payload"), pinned = try EntrySnapshot(fd: descriptor)
            var facts = stat()
            guard actual == pinned, stageIdentity.map({ $0.sameObject(as: actual) }) ?? true,
                  receipt.relative.isEmpty, actual.type == S_IFREG, receipt.kind == S_IFREG,
                  fstat(descriptor, &facts) == 0, facts.st_nlink == 1, facts.st_uid == geteuid(),
                  actual.mode & 0o7777 == 0o644, actual.size >= 0, actual.size <= 1_024 * 1_024 * 1_024,
                  receipt.device == actual.device, receipt.inode == actual.inode, receipt.size == actual.size,
                  receipt.birthSeconds == actual.birthSeconds, receipt.birthNanoseconds == actual.birthNanos,
                  receipt.changedSeconds == actual.changedSeconds, receipt.changedNanoseconds == actual.changedNanos,
                  let digest = receipt.contentSHA256, digest.count == 32,
                  receipt.publicQuarantineV1 == (plan.publicQuarantineReceivedFile ? true : nil),
                  (plan.publicZIPExtractionFile == (receipt.publicZIPExtractionMarkRequired != nil)),
                  (plan.publicTARExtractionFile == (receipt.publicTARExtractionMarkRequired != nil)),
                  (!(plan.publicQuarantineReceivedFile || plan.publicZIPExtractionFile || plan.publicTARExtractionFile)
                      || receipt.expectedQuarantineSHA256 == nil),
                  receipt.expectedQuarantineSHA256.map({ $0.count == 32 }) ?? true else { throw FileOperationFailure.sourceChanged }
            let markRequired = plan.publicQuarantineReceivedFile || receipt.publicZIPExtractionMarkRequired == true
                || receipt.publicTARExtractionMarkRequired == true
            if markRequired {
                try requireReceivedPublicQuarantine(parent: area, name: "payload", descriptor: descriptor, identity: actual)
            }
            let expectedQuarantines: [String: Data]? = receipt.expectedQuarantineSHA256.map { ["": $0] }
            try hooks.archiveProduction.stage?(.receiptsChecked, payload)
            let tree = try verifiedTree(payload, cancellation: cancellation, expectedFileContents: ["": digest],
                expectedIdentities: ["": actual], expectedQuarantines: expectedQuarantines,
                osManagedSecurityV1: plan.publicQuarantineReceivedFile || plan.publicZIPExtractionFile
                    || plan.publicTARExtractionFile)
            try hooks.archiveProduction.stage?(.validated, payload)
            failureStage = label + "-sync"
            try hooks.beforeSync?(payload); try syncTree(payload, cancellation: cancellation)
            try syncDirectory(area); try syncDirectory(target)
            try hooks.archiveProduction.stage?(.synced, payload)
            if markRequired {
                try requireReceivedPublicQuarantine(parent: area, name: "payload", descriptor: descriptor, identity: pinned)
            }
            try producedSecurity?.requireMatch(descriptor)
            try exactClone?.metadata.requireMatch(descriptor)
            if let authoredZIP, let producedSecurity {
                try requireAuthoredZIPPublicQuarantine(producedSecurity, producer: authoredZIP,
                    descriptor: descriptor, parent: area, name: "payload", identity: pinned)
            }
            if nativeArchiveCreate, authoredZIP == nil, let producedSecurity {
                try requireNativeCreatePublicQuarantine(producedSecurity, descriptor: descriptor,
                    parent: area, name: "payload", identity: pinned)
            }
            if let exactClone, let producer = plan.producer as? any AuthoredZIPFileProducer {
                let security = AuthoredZIPSecurityWitness(
                    quarantine: exactClone.metadata.quarantine, provenance: exactClone.metadata.provenance)
                try requireAuthoredZIPPublicQuarantine(security, producer: producer,
                    descriptor: descriptor, parent: area, name: "payload", identity: pinned)
            }
            try self.validateArchiveCreation(plan, cancellation: cancellation)
            failureStage = label + "-publication"
            cancellation.progress?.begin(.publishing, destination: plan.destination)
            publicationAttempted = true
            try renameStep(payload, plan.destination, expectedTree: tree, expectedQuarantines: expectedQuarantines,
                record: record, journal: journal,
                cancellation: cancellation, protection: protection,
                osManagedSecurityV1: plan.publicQuarantineReceivedFile || plan.publicZIPExtractionFile
                    || plan.publicTARExtractionFile,
                publicZIPExtractionMarkRequired: receipt.publicZIPExtractionMarkRequired,
                publicTARExtractionMarkRequired: receipt.publicTARExtractionMarkRequired)
            if markRequired {
                do {
                    try requireReceivedPublicQuarantine(parent: target, name: plan.destination.lastPathComponent,
                        descriptor: descriptor, identity: pinned)
                } catch { throw FileOperationFailure.recoveryUncertain }
            }
            if let producedSecurity {
                do {
                    try producedSecurity.requirePublished(parent: target.fd,
                        name: plan.destination.lastPathComponent, identity: pinned)
                    if let authoredZIP {
                        try requireAuthoredZIPPublicQuarantine(producedSecurity, producer: authoredZIP,
                            descriptor: descriptor, parent: target,
                            name: plan.destination.lastPathComponent, identity: pinned)
                    }
                    if nativeArchiveCreate, authoredZIP == nil {
                        try requireNativeCreatePublicQuarantine(producedSecurity, descriptor: descriptor,
                            parent: target, name: plan.destination.lastPathComponent, identity: pinned)
                    }
                } catch { throw FileOperationFailure.recoveryUncertain }
            }
            if let exactClone {
                do {
                    try exactClone.metadata.requireMatch(descriptor)
                    try exactClone.metadata.requireMatch(plan.destination)
                    if let producer = plan.producer as? any AuthoredZIPFileProducer {
                        let security = AuthoredZIPSecurityWitness(
                            quarantine: exactClone.metadata.quarantine,
                            provenance: exactClone.metadata.provenance)
                        try requireAuthoredZIPPublicQuarantine(security, producer: producer,
                            descriptor: descriptor, parent: target,
                            name: plan.destination.lastPathComponent, identity: pinned)
                    }
                } catch { throw FileOperationFailure.recoveryUncertain }
            }
            failureStage = label + "-completion"
            record.setState("committed"); try journal.save(record)
            let materialization = try? OneFileMaterializationReceipt(descriptor: descriptor, record: record.snapshot)
            try hooks.archiveProduction.stage?(.committed, plan.destination)
            return OneFileProductionExecution(result: .init(result: .init(items: [.init(source: plan.sources.count == 1 ? plan.sources[0] : nil,
                destination: plan.destination, status: .succeeded, recoveryURLs: [])], cancellationRequested: cancellation.isCancelled), recordID: record.id),
                materialization: materialization, publicationAttempted: publicationAttempted)
        } catch {
            if let store, let active { active.setState("needsReview"); active.setFailureStage(failureStage); try? store.save(active) }
            return OneFileProductionExecution(result: archiveCreationFailure(error, plan: plan, record: active?.snapshot, cancelled: cancellation.isCancelled), materialization: nil, publicationAttempted: publicationAttempted)
        }
    }
    private func archiveCreationFailure(_ error: Error, plan: ArchiveCreationPlan, record: JournalRecord?, cancelled: Bool? = nil) -> RecoverableOperationResult {
        .init(result: .init(items: [.init(source: plan.sources.count == 1 ? plan.sources[0] : nil, destination: plan.destination,
            status: operationStatus(error), recoveryURLs: record?.locations ?? [])], cancellationRequested: cancelled ?? (error is CancellationError)), recordID: record?.id)
    }
}
