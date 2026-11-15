import Darwin
import Foundation

/// One observed original and one producer-owned replacement. The App never
/// receives a staging URL or descriptor, and a plan is consumed only once.
public final class ArchiveUpdatePlan: @unchecked Sendable {
    public let sources: [URL]
    public let destination: URL
    public let directorySources: [URL]
    public let files: Int, folders: Int
    public let logicalBytes: UInt64
    public var addedItems: [ArchiveAddedItemPreview] { producer.preview.addedItems }
    internal let parent: URL
    internal let parentIdentity: EntrySnapshot
    internal let sourcesIdentity: [EntrySnapshot]
    internal let sourceParents: [URL: EntrySnapshot]
    internal let rootMetadata: ArchiveOriginalRootMetadata
    internal let producer: any ArchiveFileProducer
    internal let authoredFormat: AuthoredArchiveFormat
    internal let engine: UUID
    private let lock = NSLock()
    private var consumed = false

    internal init(sources: [URL], original: URL, identities: [EntrySnapshot],
                  sourceParents: [URL: EntrySnapshot], parentIdentity: EntrySnapshot,
                  rootMetadata: ArchiveOriginalRootMetadata, producer: any ArchiveFileProducer,
                  engine: UUID, authoredFormat: AuthoredArchiveFormat) {
        self.sources = sources; destination = original
        directorySources = zip(sources, identities).compactMap { $0.1.isDirectory ? $0.0 : nil }
        files = producer.preview.files; folders = producer.preview.folders
        logicalBytes = producer.preview.logicalBytes
        parent = original.deletingLastPathComponent()
        self.parentIdentity = parentIdentity; sourcesIdentity = identities
        self.sourceParents = sourceParents; self.rootMetadata = rootMetadata
        self.producer = producer; self.engine = engine; self.authoredFormat = authoredFormat
    }
    internal func consume(by candidate: UUID) -> Bool {
        lock.withLock {
            guard candidate == engine, !consumed else { return false }
            consumed = true; return true
        }
    }
}

/// The first update profile refuses root metadata that the ZIP producer cannot
/// preserve. A guarded native rename may add security metadata to the retained
/// old inode; the produced ZIP continues to require its own selected policy.
internal struct ArchiveOriginalRootMetadata: Equatable, Sendable {
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let flags: UInt32
    let quarantine: Data?
    let provenance: Data?

    static func observe(_ url: URL) throws -> Self {
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        let fd = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        let result = try observe(fd)
        try parent.validate()
        return result
    }

    static func observe(_ fd: Int32) throws -> Self {
        var facts = stat()
        guard fstat(fd, &facts) == 0 else { throw posixFailure() }
        let mode = facts.st_mode & 0o7777
        guard facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1,
              facts.st_uid == geteuid(),
              facts.st_flags == 0 || facts.st_flags == UInt32(UF_TRACKED),
              mode == 0o600 || mode == 0o644 else { throw FileOperationFailure.unsupported }
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            throw FileOperationFailure.copyMetadataMismatch
        }
        guard errno == ENOENT else { throw FileOperationFailure.copyMetadataMismatch }
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0, size <= 4_096 else { throw FileOperationFailure.copyMetadataMismatch }
        var names = [CChar](repeating: 0, count: max(1, size))
        guard flistxattr(fd, &names, size, 0) == size else { throw FileOperationFailure.sourceChanged }
        let allowed = Set(["com.apple.quarantine", "com.apple.provenance"])
        let observed = try names.prefix(size).split(separator: 0).map { bytes -> String in
            guard let value = String(data: Data(bytes.map { UInt8(bitPattern: $0) }), encoding: .utf8),
                  allowed.contains(value) else { throw FileOperationFailure.copyMetadataMismatch }
            return value
        }
        guard Set(observed).count == observed.count else { throw FileOperationFailure.copyMetadataMismatch }
        return Self(mode: mode, owner: facts.st_uid, group: facts.st_gid, flags: facts.st_flags,
                    quarantine: try attribute(fd, "com.apple.quarantine"),
                    provenance: try attribute(fd, "com.apple.provenance"))
    }

    func requireMatch(_ url: URL) throws {
        guard try Self.observe(url) == self else { throw FileOperationFailure.copyMetadataMismatch }
    }
    func requireMatch(_ fd: Int32) throws {
        guard try Self.observe(fd) == self else { throw FileOperationFailure.copyMetadataMismatch }
    }
    func requireAccessAndExistingMarkMatch(_ other: Self) throws {
        guard other.mode == mode, other.owner == owner, other.group == group,
              other.flags == flags,
              quarantine.map({ other.quarantine == $0 }) ?? true else {
            throw FileOperationFailure.copyMetadataMismatch
        }
    }
    func requireNewOutput(_ fd: Int32, security: AuthoredZIPSecurityWitness) throws {
        let output = try Self.observe(fd)
        guard output.mode == mode, output.owner == owner, output.group == group,
              output.flags == flags, output.quarantine == security.quarantine,
              output.provenance == security.provenance else {
            throw FileOperationFailure.copyMetadataMismatch
        }
    }
    func requireNewOutput(_ url: URL, security: AuthoredZIPSecurityWitness) throws {
        let output = try Self.observe(url)
        guard output.mode == mode, output.owner == owner, output.group == group,
              output.flags == flags, output.quarantine == security.quarantine,
              output.provenance == security.provenance else {
            throw FileOperationFailure.copyMetadataMismatch
        }
    }
    private static func attribute(_ fd: Int32, _ name: String) throws -> Data? {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        if size < 0 && errno == ENOATTR { return nil }
        guard size > 0, size <= 4_096 else { throw FileOperationFailure.copyMetadataMismatch }
        var bytes = Data(count: size)
        guard bytes.withUnsafeMutableBytes({
            fgetxattr(fd, name, $0.baseAddress, size, 0, 0)
        }) == size else { throw FileOperationFailure.sourceChanged }
        return bytes
    }
}

extension RecoverableFileOperations {
    internal func nativeArchiveUpdateEnabled(for format: AuthoredArchiveFormat) -> Bool {
        switch format {
        case .zip: authoredZIPOriginalUpdateNativePolicy == .qualifiedNativeStage
        case .strictPortableTAR: authoredTAROriginalUpdatePolicy == .developmentNativeStage
        }
    }

    internal func nativeArchiveUpdateEnabled(version: Int) -> Bool {
        switch version {
        case 13: nativeArchiveUpdateEnabled(for: .zip)
        case 18: nativeArchiveUpdateEnabled(for: .strictPortableTAR)
        default: false
        }
    }

    /// The original is the first observed source. Additional Add-to-ZIP roots
    /// retain their own parent observations and may live on other local volumes.
    @_spi(ArchiveProduction) public func prepareArchiveOriginalUpdate(
        sources: [URL], original: URL, observing selection: FileOperationSelection,
        authoredFormat: AuthoredArchiveFormat = .zip,
        makeProducer: @escaping @Sendable (@Sendable () throws -> Void) throws -> any ArchiveFileProducer
    ) async throws -> ArchiveUpdatePlan {
        try await worker { cancellation in
            if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
            guard !sources.isEmpty, sources.count <= 512, sources.first == original,
                  sources.count == selection.urls.count, sources.count == selection.identities.count,
                  original.pathExtension.lowercased() == (authoredFormat == .zip ? "zip" : "tar"),
                  Set(sources).count == sources.count else { throw FileOperationFailure.invalidRequest }
            if authoredFormat == .strictPortableTAR {
                guard self.authoredTAROriginalUpdatePolicy == .developmentNativeStage else {
                    throw FileOperationFailure.unsupported
                }
            }
            try validateName(original.lastPathComponent)
            let target = try DirectoryAnchor(original.deletingLastPathComponent())
            guard try NativeRenameVolume.qualified(in: target) != nil,
                  target.url.path.utf8.count + max(original.lastPathComponent.utf8.count + 2, 74) < PATH_MAX else {
                throw FileOperationFailure.unsupported
            }
            let observed = try sources.map { try cancellation.check(); return try observeObject($0) }
            guard observed.map(\.url) == selection.urls, observed.map(\.snapshot) == selection.identities,
                  observed[0].snapshot.type == S_IFREG,
                  observed.allSatisfy({ [S_IFREG, S_IFDIR].contains($0.snapshot.type) }) else {
                throw FileOperationFailure.sourceChanged
            }
            var sourceParents: [URL: EntrySnapshot] = [:]
            let protection = try HistoryProtection(self.directory, cancellation: cancellation,
                                                   protecting: self.protectedLocations)
            for source in observed {
                try cancellation.check()
                let parentURL = source.url.deletingLastPathComponent()
                if sourceParents[parentURL] == nil {
                    let parent = try DirectoryAnchor(parentURL, resolve: false)
                    sourceParents[parentURL] = parent.identity
                    try parent.validate()
                }
                try protection.requireEntry(source.url)
                if source.snapshot.isDirectory,
                   original.path == source.url.path || original.path.hasPrefix(source.url.path + "/") {
                    throw FileOperationFailure.invalidRequest
                }
            }
            try protection.requireEntry(original)
            let metadata = try ArchiveOriginalRootMetadata.observe(original)
            // Refuse tracked originals before offering Update in the UI. The
            // mutation path repeats this check against the current file state.
            if self.nativeArchiveUpdateEnabled(for: authoredFormat),
               metadata.flags & UInt32(UF_TRACKED) != 0 {
                throw FileOperationFailure.unsupported
            }
            let producer = try makeProducer({ try cancellation.check() })
            if authoredFormat == .strictPortableTAR {
                guard let native = producer as? any NativeAuthoredArchiveFileProducer,
                      native.authoredArchiveFormat == authoredFormat,
                      producer is any StrictPortableTARFileProducer,
                      !(producer is any AuthoredZIPFileProducer) else { throw FileOperationFailure.unsupported }
            }
            let preview = producer.preview
            guard preview.files >= 0, preview.folders >= 0, preview.files <= 10_000,
                  preview.folders < 20_000, preview.files + preview.folders < 20_000,
                  preview.logicalBytes <= 1_024 * 1_024 * 1_024 else {
                throw FileOperationFailure.unsupported
            }
            let plan = ArchiveUpdatePlan(sources: observed.map(\.url), original: original,
                identities: observed.map(\.snapshot), sourceParents: sourceParents,
                parentIdentity: target.identity, rootMetadata: metadata, producer: producer,
                engine: self.continuationSession, authoredFormat: authoredFormat)
            try self.validateArchiveOriginalUpdate(plan, cancellation: cancellation)
            return plan
        }
    }

    public func performArchiveOriginalUpdate(_ plan: ArchiveUpdatePlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
                guard plan.consume(by: self.continuationSession) else { throw FileOperationFailure.invalidRequest }
                defer { plan.producer.finished() }
                try self.validateCopyExecutionSession(locations: plan.sources,
                    directories: [plan.parent] + Array(plan.sourceParents.keys))
                try self.validateArchiveOriginalUpdate(plan, cancellation: cancellation)
                return self.updateOriginalArchive(plan, cancellation: cancellation)
            }
        } catch { result = archiveUpdateFailure(error, plan: plan, record: nil) }
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }

    /// Observational locations for App-owned saved-reference checks before a
    /// later Undo or recovery. An absent candidate is normal; no URL grants
    /// mutation authority, and the journal is revalidated during the action.
    public func archiveUpdateReferenceLocations(recordID: UUID) async throws -> [URL]? {
        try await worker { cancellation in
            try cancellation.check()
            let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks,
                                               cancellation: cancellation)
            guard let record = try journal.inspectRecord(recordID), [5, 6, 13, 18].contains(record.version),
                  let first = record.steps.first, let area = record.areas.first else { return nil }
            return [first.source, area.url.appendingPathComponent("displaced"),
                    area.url.appendingPathComponent("payload")]
        }
    }

    internal func validateArchiveOriginalUpdate(_ plan: ArchiveUpdatePlan,
                                                cancellation: OperationCancellation) throws {
        try cancellation.check()
        if plan.authoredFormat == .strictPortableTAR {
            guard authoredTAROriginalUpdatePolicy == .developmentNativeStage,
                  (plan.producer as? any NativeAuthoredArchiveFileProducer)?.authoredArchiveFormat == .strictPortableTAR else {
                throw FileOperationFailure.unsupported
            }
        }
        let target = try DirectoryAnchor(plan.parent, resolve: false)
        guard target.identity.sameObject(as: plan.parentIdentity),
              try NativeRenameVolume.qualified(in: target) != nil,
              plan.sources.first == plan.destination,
              plan.sources.count == plan.sourcesIdentity.count,
              Set(plan.sourceParents.keys) == Set(plan.sources.map { $0.deletingLastPathComponent() }) else {
            throw FileOperationFailure.destinationChanged
        }
        let protection = try HistoryProtection(directory, cancellation: cancellation,
                                               protecting: protectedLocations)
        var parents: [URL: DirectoryAnchor] = [:]
        for (url, expected) in plan.sourceParents {
            let parent = try DirectoryAnchor(url, resolve: false)
            guard parent.identity.sameObject(as: expected) else { throw FileOperationFailure.sourceChanged }
            parents[url] = parent
        }
        for (source, expected) in zip(plan.sources, plan.sourcesIdentity) {
            try cancellation.check()
            guard let parent = parents[source.deletingLastPathComponent()],
                  try EntrySnapshot(parent: parent.fd, name: source.lastPathComponent) == expected else {
                throw FileOperationFailure.sourceChanged
            }
            try protection.requireEntry(source)
        }
        try plan.rootMetadata.requireMatch(plan.destination)
        try plan.producer.validate(check: { try cancellation.check() })
        for parent in parents.values { try parent.validate() }
        try target.validate()
    }

    private func updateOriginalArchive(_ plan: ArchiveUpdatePlan,
                                       cancellation: OperationCancellation) -> RecoverableOperationResult {
        var store: OperationJournal?, active: JournalEditSession?
        var failureStage = "archive-update-admission"
        do {
            try hooks.archiveProduction.stage?(.admitted, plan.parent)
            let target = try DirectoryAnchor(plan.parent, resolve: false)
            guard target.identity.sameObject(as: plan.parentIdentity),
                  try NativeRenameVolume.qualified(in: target) != nil else {
                throw FileOperationFailure.destinationChanged
            }
            let protection = try HistoryProtection(directory, cancellation: cancellation,
                                                   protecting: protectedLocations)
            for source in plan.sources { try protection.requireEntry(source) }
            let originalTree = try verifiedTree(plan.destination, cancellation: cancellation)
            guard originalTree.identity == plan.sourcesIdentity[0] else {
                throw FileOperationFailure.sourceChanged
            }
            try plan.rootMetadata.requireMatch(plan.destination)
            // A tracked ZIP can transfer its logical document identity when a
            // replacement appears at the old path. Hold that native case until
            // a signed Update/Undo contract covers both inodes and their flags.
            if nativeArchiveUpdateEnabled(for: plan.authoredFormat),
               plan.rootMetadata.flags & UInt32(UF_TRACKED) != 0 {
                throw FileOperationFailure.unsupported
            }
            let journal = try OperationJournal(directory, hooks: hooks.journalHooks,
                                               cancellation: cancellation)
            store = journal
            try protection.historyOpened(journal.anchor)
            try journal.validateWritableCatalog()
            try journal.reserveCapacity(steps: 2, areas: 1, locations: plan.sources.count + 5,
                trashIntents: 0, estimatedBytes: 32_768 + plan.sources.reduce(0) {
                    $0 + $1.path.utf8.count * 8
                })
            // Each authored Update profile mints its own journal protocol. The
            // native replacement candidate cannot borrow v5/v6 inverse authority.
            let strictClone: Bool
            if case .exactSourceCloneQualification = authoredZIPMetadataPolicy,
               plan.producer is any AuthoredZIPFileProducer { strictClone = true }
            else { strictClone = false }
            let nativeOriginalUpdate = nativeArchiveUpdateEnabled(for: plan.authoredFormat)
            guard !nativeOriginalUpdate || (plan.producer as? any NativeAuthoredArchiveFileProducer)?.authoredArchiveFormat == plan.authoredFormat else {
                throw FileOperationFailure.unsupported
            }
            let protocolKind: OperationCatalogProtocol = plan.authoredFormat == .strictPortableTAR ? .tarNativeUpdateV18
                : nativeOriginalUpdate ? .archiveNativeUpdateV13
                : strictClone ? .archiveStrictCloneV6 : .archiveUpdateV5
            let record = try journal.beginArchiveUpdateEdit(protocolKind: protocolKind); active = record
            for source in plan.sources { try record.appendLocation(source) }
            try journal.save(record)
            failureStage = "archive-update-staging"
            let area = try recoveryArea(in: target, record: record, journal: journal)
            let exactClone: (descriptor: Int32, metadata: ArchiveOriginalRootMetadata,
                             identity: EntrySnapshot)?
            if strictClone {
                guard let parentIdentity = plan.sourceParents[plan.parent] else {
                    throw FileOperationFailure.invalidRequest
                }
                let clone = try exactSourceCloneStage(source: plan.destination,
                    identity: plan.sourcesIdentity[0], parentIdentity: parentIdentity,
                    in: area, requireCopyMode: false)
                guard clone.metadata == plan.rootMetadata else {
                    close(clone.descriptor)
                    throw FileOperationFailure.copyMetadataMismatch
                }
                exactClone = clone
            } else { exactClone = nil }
            let fd = exactClone?.descriptor ?? openat(area.fd, "payload",
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixFailure() }
            defer { close(fd) }
            let payload = area.url.appendingPathComponent("payload")
            try hooks.archiveProduction.stage?(.payloadCreated, payload)
            try exactClone?.metadata.requireMatch(fd)
            if let exactClone {
                guard try EntrySnapshot(fd: fd).sameObject(as: exactClone.identity),
                      try EntrySnapshot(parent: area.fd, name: "payload").sameObject(as: exactClone.identity) else {
                    throw FileOperationFailure.copyMetadataMismatch
                }
            }
            let authoredZIP: (any NativeAuthoredArchiveFileProducer)?
            if authoredZIPMetadataPolicy == .nativeStageQualification || nativeOriginalUpdate {
                authoredZIP = plan.producer as? any NativeAuthoredArchiveFileProducer
            } else { authoredZIP = nil }
            // The native displacement proof applies to the old inode only.
            // Strict-clone production still uses the ordinary exact-mark path.
            let displacedZIP: (any NativeAuthoredArchiveFileProducer)? = strictClone
                ? plan.producer as? any AuthoredZIPFileProducer : authoredZIP
            let stageIdentity = try exactClone?.identity ?? authoredZIP.map { _ in try EntrySnapshot(fd: fd) }
            let stageSecurity = try authoredZIP.map { _ in try AuthoredZIPSecurityWitness.observe(fd) }
            if let authoredZIP, let stageIdentity, let stageSecurity {
                try requireAuthoredZIPPublicQuarantine(stageSecurity, producer: authoredZIP,
                    descriptor: fd, parent: area, name: "payload", identity: stageIdentity)
            }
            if let exactClone, let producer = plan.producer as? any AuthoredZIPFileProducer {
                let security = AuthoredZIPSecurityWitness(
                    quarantine: exactClone.metadata.quarantine, provenance: exactClone.metadata.provenance)
                try requireAuthoredZIPPublicQuarantine(security, producer: producer,
                    descriptor: fd, parent: area, name: "payload", identity: exactClone.identity)
            }
            // Tracking a copied file assigns it a fresh native document ID. Pin
            // the unchanged original and mark the new payload before production
            // so the producer's receipt includes the flag-induced ctime change.
            do {
                let sourceFD = openat(target.fd, plan.destination.lastPathComponent,
                                      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard sourceFD >= 0 else { throw posixFailure() }
                defer { close(sourceFD) }
                guard try EntrySnapshot(fd: sourceFD) == plan.sourcesIdentity[0],
                      try EntrySnapshot(parent: target.fd, name: plan.destination.lastPathComponent) == plan.sourcesIdentity[0] else {
                    throw FileOperationFailure.sourceChanged
                }
                try plan.rootMetadata.requireMatch(sourceFD)
                try exactClone?.metadata.requireMatch(fd)
                try preserveCopiedDocumentTracking(source: sourceFD, destination: fd)
                var payloadFacts = stat()
                guard fstat(fd, &payloadFacts) == 0,
                      payloadFacts.st_flags == plan.rootMetadata.flags,
                      try EntrySnapshot(fd: sourceFD) == plan.sourcesIdentity[0] else {
                    throw FileOperationFailure.copyMetadataMismatch
                }
                try stageSecurity?.requireMatch(fd)
                try plan.rootMetadata.requireMatch(sourceFD)
                try target.validate()
            }
            failureStage = "archive-update-production"
            cancellation.progress?.begin(.copying, source: plan.destination, destination: plan.destination,
                bytes: Int64(plan.logicalBytes), items: plan.files + plan.folders)
            let receipt: ArchiveProducedNode
            let producedSecurity: AuthoredZIPSecurityWitness?
            if let authoredZIP, let stageSecurity {
                let produced = try authoredZIP.produceNativeArchive(into: fd, stageSecurity: stageSecurity,
                    allowSourceMarkInheritance: !nativeOriginalUpdate,
                    check: { try cancellation.check() },
                    progress: { bytes, items in cancellation.progress?.advance(bytes: Int64(bytes), items: items) })
                receipt = produced.node; producedSecurity = produced.security
            } else {
                receipt = try plan.producer.produce(into: fd, check: { try cancellation.check() },
                    progress: { bytes, items in cancellation.progress?.advance(bytes: Int64(bytes), items: items) })
                producedSecurity = nil
            }
            try exactClone?.metadata.requireMatch(fd)
            try hooks.archiveProduction.stage?(.produced, payload)
            failureStage = "archive-update-verification"
            cancellation.progress?.begin(.verifying, destination: plan.destination)
            let actual = try EntrySnapshot(parent: area.fd, name: "payload")
            let pinned = try EntrySnapshot(fd: fd)
            var facts = stat()
            guard actual == pinned, stageIdentity.map({ $0.sameObject(as: actual) }) ?? true,
                  receipt.relative.isEmpty, actual.type == S_IFREG,
                  receipt.kind == S_IFREG, fstat(fd, &facts) == 0,
                  facts.st_nlink == 1, facts.st_uid == geteuid(),
                  actual.size >= 0, actual.size <= 1_024 * 1_024 * 1_024,
                  receipt.device == actual.device, receipt.inode == actual.inode,
                  receipt.size == actual.size, receipt.birthSeconds == actual.birthSeconds,
                  receipt.birthNanoseconds == actual.birthNanos,
                  receipt.changedSeconds == actual.changedSeconds,
                  receipt.changedNanoseconds == actual.changedNanos,
                  let digest = receipt.contentSHA256, digest.count == 32,
                  receipt.expectedQuarantineSHA256.map({ $0.count == 32 }) ?? true else {
                throw FileOperationFailure.sourceChanged
            }
            if let producedSecurity {
                try plan.rootMetadata.requireNewOutput(fd, security: producedSecurity)
            } else { try plan.rootMetadata.requireMatch(fd) }
            try hooks.archiveProduction.stage?(.receiptsChecked, payload)
            let expectedQuarantines: [String: Data]? = nativeOriginalUpdate
                ? receipt.expectedQuarantineSHA256.map { ["": $0] } : nil
            let staged = try verifiedTree(payload, cancellation: cancellation,
                expectedFileContents: ["": digest], expectedIdentities: ["": actual],
                expectedQuarantines: expectedQuarantines)
            try hooks.archiveProduction.stage?(.validated, payload)
            failureStage = "archive-update-sync"
            try hooks.beforeSync?(payload)
            try syncTree(payload, cancellation: cancellation)
            try syncDirectory(area); try syncDirectory(target)
            try hooks.archiveProduction.stage?(.synced, payload)
            try exactClone?.metadata.requireMatch(fd)
            if let producedSecurity {
                try plan.rootMetadata.requireNewOutput(fd, security: producedSecurity)
                if let authoredZIP {
                    try requireAuthoredZIPPublicQuarantine(producedSecurity, producer: authoredZIP,
                        descriptor: fd, parent: area, name: "payload", identity: pinned)
                }
            }
            if let exactClone, let producer = plan.producer as? any AuthoredZIPFileProducer {
                let security = AuthoredZIPSecurityWitness(
                    quarantine: exactClone.metadata.quarantine, provenance: exactClone.metadata.provenance)
                try requireAuthoredZIPPublicQuarantine(security, producer: producer,
                    descriptor: fd, parent: area, name: "payload", identity: pinned)
            }
            try validateArchiveOriginalUpdate(plan, cancellation: cancellation)
            guard originalTree.matches(try verifiedTree(plan.destination, cancellation: cancellation)),
                  staged.matches(try verifiedTree(payload, cancellation: cancellation)) else {
                throw FileOperationFailure.sourceChanged
            }
            failureStage = "archive-update-publication"
            let segment = cancellation.segment()
            try renameStep(plan.destination, area.url.appendingPathComponent("displaced"),
                expectedTree: originalTree, record: record, journal: journal,
                cancellation: segment, protection: protection)
            if let displacedZIP {
                // renameStep proved this old object and its contents unchanged
                // apart from its bounded native root security transition, and
                // durably recorded the complete after-image. Recheck that image
                // before the new payload can replace the original pathname.
                guard record.steps.count == 1, record.steps[0].before.matches(originalTree),
                      let displacedImage = record.steps[0].after,
                      displacedImage.identity.sameObject(as: originalTree.identity),
                      displacedImage.identity.size == originalTree.identity.size,
                      displacedImage == (try verifiedTree(parent: area.fd, name: "displaced",
                          cancellation: segment.draining())) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                let displacedFD = openat(area.fd, "displaced",
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard displacedFD >= 0 else { throw FileOperationFailure.recoveryUncertain }
                defer { close(displacedFD) }
                guard try EntrySnapshot(fd: displacedFD) == displacedImage.identity else {
                    throw FileOperationFailure.recoveryUncertain
                }
                try plan.rootMetadata.requireAccessAndExistingMarkMatch(
                    try ArchiveOriginalRootMetadata.observe(displacedFD))
                let displacedSecurity = try AuthoredZIPSecurityWitness.observe(displacedFD)
                try requireAuthoredZIPPublicQuarantine(displacedSecurity, producer: displacedZIP,
                    descriptor: displacedFD, parent: area, name: "displaced",
                    identity: displacedImage.identity)
            } else {
                try plan.rootMetadata.requireMatch(area.url.appendingPathComponent("displaced"))
            }
            // The old inode's native metadata change never authorizes a change
            // to the cloned replacement waiting in the same recovery area.
            try exactClone?.metadata.requireMatch(fd)
            if nativeOriginalUpdate {
                // The first rename's complete after-image is durably saved. A
                // second save attests that its existing mark and public native
                // recognition passed too. A generated failure here leaves only
                // that acknowledged and qualified first step.
                try record.qualifyRetainedArchiveOriginal()
                try journal.save(record)
                try hooks.archiveProduction.stage?(.originalRetained,
                    area.url.appendingPathComponent("displaced"))
            }
            try renameStep(payload, plan.destination, expectedTree: staged,
                expectedQuarantines: expectedQuarantines,
                record: record, journal: journal, cancellation: segment, protection: protection)
            if let producedSecurity {
                do {
                    try producedSecurity.requirePublished(parent: target.fd,
                        name: plan.destination.lastPathComponent, identity: pinned)
                    try plan.rootMetadata.requireNewOutput(plan.destination, security: producedSecurity)
                    if let authoredZIP {
                        try requireAuthoredZIPPublicQuarantine(producedSecurity, producer: authoredZIP,
                            descriptor: fd, parent: target,
                            name: plan.destination.lastPathComponent, identity: pinned)
                    }
                } catch { throw FileOperationFailure.recoveryUncertain }
            } else {
                try plan.rootMetadata.requireMatch(plan.destination)
                if let exactClone, let producer = plan.producer as? any AuthoredZIPFileProducer {
                    do {
                        let security = AuthoredZIPSecurityWitness(
                            quarantine: exactClone.metadata.quarantine,
                            provenance: exactClone.metadata.provenance)
                        try requireAuthoredZIPPublicQuarantine(security, producer: producer,
                            descriptor: fd, parent: target,
                            name: plan.destination.lastPathComponent, identity: pinned)
                    } catch { throw FileOperationFailure.recoveryUncertain }
                }
            }
            guard staged.matches(try verifiedTree(plan.destination, cancellation: segment)) else {
                throw FileOperationFailure.recoveryUncertain
            }
            if nativeOriginalUpdate {
                // Publication may change the retained inode's native metadata,
                // including document flags. Do not commit an Undo image that
                // no longer matches the old original in the recovery area.
                guard let retained = record.steps.first?.after,
                      retained.matches(try verifiedTree(parent: area.fd, name: "displaced",
                          cancellation: segment.draining())) else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
            failureStage = "archive-update-completion"
            record.setState("committed"); try journal.save(record)
            try hooks.archiveProduction.stage?(.committed, plan.destination)
            return .init(result: .init(items: [.init(source: nil, destination: plan.destination,
                status: .succeeded, recoveryURLs: [])], cancellationRequested: cancellation.isCancelled),
                recordID: record.id)
        } catch {
            if let store, let active {
                active.setState("needsReview"); active.setFailureStage(failureStage)
                try? store.save(active)
            }
            return archiveUpdateFailure(error, plan: plan, record: active?.snapshot,
                                        cancelled: cancellation.isCancelled)
        }
    }

    private func archiveUpdateFailure(_ error: Error, plan: ArchiveUpdatePlan,
        record: JournalRecord?, cancelled: Bool? = nil) -> RecoverableOperationResult {
        .init(result: .init(items: [.init(source: nil, destination: plan.destination,
            status: operationStatus(error), recoveryURLs: record?.locations ?? [])],
            cancellationRequested: cancelled ?? (error is CancellationError)), recordID: record?.id)
    }
}
