import CryptoKit
import Darwin
import Foundation

/// The existing durable failure stage also owns one closed, path-free
/// diagnostic phase. Neither representation changes operation authority.
private enum DownloadAdoptionFailureStage: String {
    case admission = "download-adoption-admission"
    case area = "download-adoption-area"
    case intent = "download-adoption-intent"
    case move = "download-adoption-move"
    case stage = "download-adoption-stage"
    case publication = "download-adoption-publication"
    case commit = "download-adoption-commit"

    var checkpoint: OperationDiagnosticCheckpoint {
        switch self {
        case .admission: .downloadAdoptionAdmission
        case .area: .downloadAdoptionArea
        case .intent: .downloadAdoptionIntent
        case .move: .downloadAdoptionMove
        case .stage: .downloadAdoptionStage
        case .publication: .downloadAdoptionPublication
        case .commit: .downloadAdoptionCommit
        }
    }
}

/// A sealed single-file Download only. The ordinary received-file producer and
/// all native app composition remain on their existing, held publication path.
@_spi(ArchiveProduction) public final class AdoptedReceivedFilePlan: @unchecked Sendable {
    public let destination: URL
    public let logicalBytes: UInt64
    internal let parent: URL
    internal let parentIdentity: EntrySnapshot
    internal let source: any SealedDownloadAdoptionSource
    internal let engine: UUID
    private let lock = NSLock()
    private var consumed = false

    internal init(parent: URL, parentIdentity: EntrySnapshot, destination: URL,
                  source: any SealedDownloadAdoptionSource, engine: UUID) {
        self.parent = parent; self.parentIdentity = parentIdentity; self.destination = destination
        logicalBytes = source.logicalBytes; self.source = source; self.engine = engine
    }
    internal func consume(by engine: UUID) -> Bool {
        lock.withLock { guard self.engine == engine, !consumed else { return false }; consumed = true; return true }
    }
    deinit {
        let source = source
        DispatchQueue.global(qos: .utility).async { source.finished() }
    }
}

extension RecoverableFileOperations {
    public enum DownloadAdoptionColdLocation: Sendable, Equatable {
        case spoolRetained, recoveryRetained, publishedUncommitted, committed, undone, uncertain
    }

    /// Read-only pre-body rejection for an ordinary single-file download. If
    /// the pool has not yet been created, its existing parent is the best
    /// available volume observation; sealed-source admission checks the actual
    /// pool again before any rename.
    @_spi(ArchiveProduction) public func checkReceivedFileAdoptionDestination(parent: URL, name: String,
        stagingDirectory: URL, observing expectedParent: FileOperationSelection? = nil) async throws -> FileOperationSelection {
        guard case .sourceQualification = downloadAdoptionPolicy,
              case .closed = copyExecutionAuthorization,
              stagingDirectory.isFileURL, stagingDirectory == stagingDirectory.standardizedFileURL else {
            throw FileOperationFailure.unsupported
        }
        let observed = try await checkReceivedFileDestination(parent: parent, name: name, observing: expectedParent)
        return try await worker { cancellation in
            guard observed.urls.count == 1, observed.identities.count == 1 else {
                throw FileOperationFailure.destinationChanged
            }
            let target = try DirectoryAnchor(observed.urls[0], resolve: false)
            guard
                  target.identity.sameObject(as: observed.identities[0]),
                  let targetVolume = try NativeRenameVolume.qualified(in: target) else {
                throw FileOperationFailure.destinationChanged
            }
            let sourceParent: DirectoryAnchor
            do { sourceParent = try DirectoryAnchor(stagingDirectory, resolve: false) }
            catch FileOperationFailure.notFound {
                sourceParent = try DirectoryAnchor(stagingDirectory.deletingLastPathComponent(), resolve: false)
            }
            guard try NativeRenameVolume.qualified(in: sourceParent) == targetVolume else {
                throw FileOperationFailure.unsupported
            }
            try target.validate(); try sourceParent.validate(); try cancellation.check()
            return observed
        }
    }

    /// Passive, bounded classification only. It does not replay either rename,
    /// retire the pool shell or grant Undo authority.
    @_spi(ArchiveProduction) public func inspectAdoptedDownload(recordID: UUID) async throws -> DownloadAdoptionColdLocation {
        try await worker { cancellation in
            let catalog = try OperationHistoryInspector.record(self.directory, id: recordID, cancellation: cancellation)
            guard case .downloadAdoptionV7(let record) = catalog else { throw FileOperationFailure.invalidRequest }
            return try self.classifyAdoptedDownload(record, cancellation: cancellation)
        }
    }

    private func classifyAdoptedDownload(_ record: JournalRecord,
        cancellation: OperationCancellation) throws -> DownloadAdoptionColdLocation {
        guard let adoption = record.downloadAdoption else { return .uncertain }
        try adoption.validate()
        let target = try DirectoryAnchor(adoption.destination.deletingLastPathComponent(), resolve: false)
        guard let volume = try NativeRenameVolume.qualified(in: target), volume == adoption.volume,
              try record.matchesPersisted(adoption.destinationParent, target.identity, in: target),
              let bound = record.persistentVolumes?.binding(for: adoption.destinationParent.device),
              bound.uuid == volume.uuid else { return .uncertain }
        let area = try DirectoryAnchor(adoption.area, resolve: false)
        guard try NativeRenameVolume.qualified(in: area) == volume,
              try record.matchesPersisted(adoption.areaIdentity, area.identity, in: area) else { return .uncertain }
        func observed(_ url: URL) throws -> VerifiedTree? {
            do {
                return try verifiedTree(url, cancellation: cancellation,
                    expectedFileContents: ["": adoption.bodyDigest])
            } catch FileOperationFailure.notFound { return nil }
        }
        let spool: VerifiedTree?, recovery: VerifiedTree?, final: VerifiedTree?
        do {
            spool = try observed(adoption.source)
            recovery = try observed(adoption.area.appendingPathComponent("payload"))
            final = try observed(adoption.destination)
        } catch { return .uncertain }
        let occupied = [spool, recovery, final].compactMap { $0 }.count
        guard occupied == 1 else { return .uncertain }
        let markerURL = adoption.source.deletingLastPathComponent().appendingPathComponent("adoption.intent")
        let markerPresent: Bool
        let markerFD = open(markerURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if markerFD >= 0 {
            defer { close(markerFD) }
            var facts = stat()
            guard fstat(markerFD, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
                  facts.st_size > 0, facts.st_size <= 160,
                  (try EntrySnapshot(fd: markerFD)).sameObject(as: adoption.markerIdentity) else { return .uncertain }
            var bytes = Data(count: Int(facts.st_size)); let count = bytes.count
            guard bytes.withUnsafeMutableBytes({ read(markerFD, $0.baseAddress, count) }) == count,
                  let marker = try? DownloadAdoptionMarker(bytes: bytes), marker.job == record.id,
                  marker.spool == adoption.spoolID,
                  marker.area == UUID(uuidString: String(adoption.area.lastPathComponent.dropFirst(".mac-explorer-recovery-".count))) else {
                return .uncertain
            }
            markerPresent = true
        } else if errno == ENOENT { markerPresent = false }
        else { return .uncertain }
        let url = spool != nil ? adoption.source : recovery != nil ? adoption.area.appendingPathComponent("payload") : adoption.destination
        let current = spool ?? recovery ?? final!
        let mode = current.identity.mode & 0o7777
        let allowedMode = spool != nil ? mode == 0o600 : recovery != nil ? (mode == 0o600 || mode == 0o644) : mode == 0o644
        guard current.identity.sameObject(as: adoption.sourceIdentity),
              current.identity.size >= 0, UInt64(current.identity.size) == adoption.length,
              allowedMode else { return .uncertain }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .uncertain }
        defer { close(fd) }
        do { try adoption.security.require(fd, at: url) } catch { return .uncertain }
        if spool != nil {
            guard let from = try? DirectoryAnchor(adoption.source.deletingLastPathComponent(), resolve: false),
                  (try? NativeRenameVolume.qualified(in: from)) == volume,
                  (try? record.matchesPersisted(adoption.sourceParent, from.identity, in: from)) == true else {
                return .uncertain
            }
            return markerPresent && record.steps.isEmpty ? .spoolRetained : .uncertain
        }
        if recovery != nil {
            if record.state == "undone", record.steps.count == 1,
               record.steps[0].undone, record.steps[0].after != nil { return .undone }
            return markerPresent && (record.steps.isEmpty || record.steps.count == 1 && record.steps[0].after == nil)
                ? .recoveryRetained : .uncertain
        }
        if record.state == "committed", record.steps.count == 1,
           record.steps[0].after != nil, !record.steps[0].undone { return .committed }
        return markerPresent && record.steps.count == 1 ? .publishedUncommitted : .uncertain
    }

    @_spi(ArchiveProduction) public func prepareReceivedFileAdoption(parent: URL, name: String,
        observing destination: FileOperationSelection? = nil,
        makeSource: @escaping @Sendable () throws -> any SealedDownloadAdoptionSource) async throws -> AdoptedReceivedFilePlan {
        try await worker { cancellation in
            guard case .sourceQualification = self.downloadAdoptionPolicy,
                  case .closed = self.copyExecutionAuthorization else { throw FileOperationFailure.unsupported }
            try validateName(name)
            let target = try DirectoryAnchor(parent)
            if let destination {
                guard destination.urls.count == 1, destination.identities.count == 1,
                      destination.urls[0] == target.url, destination.identities[0].isDirectory,
                      target.identity.sameObject(as: destination.identities[0]) else {
                    throw FileOperationFailure.destinationChanged
                }
            }
            guard let volume = try NativeRenameVolume.qualified(in: target),
                  target.url.path.utf8.count + max(name.utf8.count + 2, 74) < PATH_MAX else {
                throw FileOperationFailure.unsupported
            }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.requireEntry(parent: target, name: name); try requireAbsent(name, in: target.fd)
            let source = try makeSource()
            do {
                guard source.logicalBytes <= 1 << 30, source.digest.count == 32 else { throw FileOperationFailure.unsupported }
                let pin = try source.adoptionPin()
                let from = try DirectoryAnchor(pin.url.deletingLastPathComponent(), resolve: false)
                guard try NativeRenameVolume.qualified(in: from) == volume else { throw FileOperationFailure.unsupported }
                guard pin.url.lastPathComponent == "payload",
                      from.url.lastPathComponent == "download-" + source.spoolID.uuidString,
                      try EntrySnapshot(fd: pin.descriptor) == EntrySnapshot(parent: from.fd, name: "payload") else {
                    throw FileOperationFailure.sourceChanged
                }
                _ = try DownloadAdoptionSecurity.observe(descriptor: pin.descriptor, url: pin.url)
                try from.validate(); try target.validate(); try cancellation.check()
                return AdoptedReceivedFilePlan(parent: target.url, parentIdentity: target.identity,
                    destination: target.url.appendingPathComponent(name), source: source, engine: self.continuationSession)
            } catch { source.finished(); throw error }
        }
    }

    @_spi(ArchiveProduction) public func performReceivedFile(_ plan: AdoptedReceivedFilePlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                guard case .sourceQualification = self.downloadAdoptionPolicy,
                      plan.consume(by: self.continuationSession) else { throw FileOperationFailure.invalidRequest }
                defer { plan.source.finished() }
                try self.validateCopyExecutionSession(locations: [plan.destination], directories: [plan.parent])
                return self.createAdoptedDownload(plan, cancellation: cancellation)
            }
        } catch {
            result = .init(result: .init(items: [.init(source: nil, destination: plan.destination,
                status: operationStatus(error), recoveryURLs: [])], cancellationRequested: error is CancellationError), recordID: nil)
        }
        // A cancelled submission can fail before the worker consumes its plan.
        // Retire that unused lease on a worker, as the ordinary received path does.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                if plan.consume(by: continuationSession) { plan.source.finished() }
                continuation.resume()
            }
        }
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }

    private func createAdoptedDownload(_ plan: AdoptedReceivedFilePlan,
        cancellation: OperationCancellation) -> RecoverableOperationResult {
        var store: OperationJournal?, active: JournalEditSession?
        var stage: DownloadAdoptionFailureStage = .admission
        do {
            let target = try DirectoryAnchor(plan.parent, resolve: false)
            guard target.identity.sameObject(as: plan.parentIdentity),
                  let volume = try NativeRenameVolume.qualified(in: target) else { throw FileOperationFailure.destinationChanged }
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            try protection.requireEntry(parent: target, name: plan.destination.lastPathComponent)
            try requireAbsent(plan.destination.lastPathComponent, in: target.fd)
            let pin = try plan.source.adoptionPin()
            let from = try DirectoryAnchor(pin.url.deletingLastPathComponent(), resolve: false)
            guard pin.url.lastPathComponent == "payload",
                  from.url.lastPathComponent == "download-" + plan.source.spoolID.uuidString,
                  try NativeRenameVolume.qualified(in: from) == volume else { throw FileOperationFailure.unsupported }
            let sourceIdentity = try EntrySnapshot(fd: pin.descriptor)
            var sourceFacts = stat()
            guard sourceIdentity == (try EntrySnapshot(parent: from.fd, name: "payload")),
                  fstat(pin.descriptor, &sourceFacts) == 0, sourceFacts.st_nlink == 1,
                  sourceFacts.st_uid == geteuid(), sourceFacts.st_mode & 0o7777 == 0o600,
                  sourceFacts.st_size >= 0, UInt64(sourceFacts.st_size) == plan.logicalBytes else {
                throw FileOperationFailure.sourceChanged
            }
            let security = try DownloadAdoptionSecurity.observe(descriptor: pin.descriptor, url: pin.url)
            #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
            let privateProbeMark = try hooks.privateDownloadMarkProbe.map { _ in
                try security.capturedNativeMark(pin.descriptor, at: pin.url)
            }
            #endif
            let before = try verifiedTree(parent: from.fd, name: "payload", cancellation: cancellation,
                expectedFileContents: ["": plan.source.digest], expectedIdentities: ["": sourceIdentity])
            guard before.identity == sourceIdentity else { throw FileOperationFailure.sourceChanged }
            try security.require(pin.descriptor, at: pin.url)
            let journal = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation)
            store = journal
            try protection.historyOpened(journal.anchor); try journal.validateWritableCatalog()
            try journal.reserveCapacity(steps: 1, areas: 1, locations: 4, trashIntents: 0,
                estimatedBytes: 32_768 + pin.url.path.utf8.count * 8 + plan.destination.path.utf8.count * 8)
            let record = try journal.beginDownloadAdoptionEdit(); active = record
            stage = .area
            let area = try recoveryArea(in: target, record: record, journal: journal)
            guard let areaID = UUID(uuidString: String(area.url.lastPathComponent.dropFirst(".mac-explorer-recovery-".count))),
                  try NativeRenameVolume.qualified(in: area) == volume else { throw FileOperationFailure.unsupported }
            stage = .intent
            try plan.source.armAdoption(job: record.id, area: areaID)
            let markerIdentity = try EntrySnapshot(parent: from.fd, name: "adoption.intent")
            var adoption = JournalDownloadAdoption(spoolID: plan.source.spoolID, volume: volume, source: pin.url,
                sourceParent: from.identity, sourceIdentity: sourceIdentity, markerIdentity: markerIdentity,
                area: area.url, areaIdentity: area.identity, destination: plan.destination,
                destinationParent: target.identity, length: plan.logicalBytes,
                bodyDigest: plan.source.digest, security: security, adoptedStage: nil)
            try record.appendNewLocations([pin.url, plan.destination])
            try record.bindPersistentVolume(in: from)
            try record.setDownloadAdoption(adoption)
            record.setState("mutating"); try journal.save(record)
            try cancellation.check(); hooks.afterIntent?()
            try from.validate(); try area.validate(); try target.validate()
            try volume.validate(in: from); try volume.validate(in: area); try volume.validate(in: target)
            guard sourceIdentity == (try EntrySnapshot(parent: from.fd, name: "payload")),
                  sourceIdentity == (try EntrySnapshot(fd: pin.descriptor)) else { throw FileOperationFailure.sourceChanged }
            try security.require(pin.descriptor, at: pin.url)
            try requireAbsent("payload", in: area.fd)
            stage = .move
            hooks.beforeRename?(); try cancellation.beginMutation()
            try hooks.beforeExclusiveRename?(pin.url, area.url.appendingPathComponent("payload"))
            try exclusiveRename(from: from.fd, name: "payload", to: area.fd, name: "payload")
            plan.source.noteAdopted(job: record.id)
            hooks.afterRename?()
            let payload = area.url.appendingPathComponent("payload")
            guard (try EntrySnapshot(fd: pin.descriptor)).sameObject(as: sourceIdentity),
                  (try EntrySnapshot(parent: area.fd, name: "payload")).sameObject(as: sourceIdentity) else {
                throw FileOperationFailure.recoveryUncertain
            }
            #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
            if let report = hooks.privateDownloadMarkProbe {
                guard let privateProbeMark else { throw FileOperationFailure.copyMetadataMismatch }
                report(security.probePrivateSameInodeRestoration(pin.descriptor, at: payload,
                                                                 original: privateProbeMark))
                // This is an intentional private-only QA stop. The source
                // shell, marker and journal remain for independent review.
                throw FileOperationFailure.unavailable
            }
            #endif
            try security.require(pin.descriptor, at: payload)
            try hooks.afterAdoptionMove?({ cancellation.isCancelled })
            try hooks.beforeSync?(payload)
            try from.validate(); try area.validate(); try volume.validate(in: from)
            try volume.validate(in: area); try syncDirectory(from); try syncDirectory(area)
            stage = .stage
            guard fchmod(pin.descriptor, 0o644) == 0 else { throw posixFailure() }
            try security.require(pin.descriptor, at: payload)
            let adopted = try verifiedTree(parent: area.fd, name: "payload", cancellation: cancellation.draining(),
                expectedFileContents: ["": plan.source.digest])
            guard adopted.identity.sameObject(as: sourceIdentity), adopted.identity.mode & 0o7777 == 0o644 else {
                throw FileOperationFailure.recoveryUncertain
            }
            try syncTree(payload, cancellation: cancellation.draining())
            try syncDirectory(area); try syncDirectory(target)
            adoption.adoptedStage = adopted
            try record.setDownloadAdoption(adoption); try journal.save(record)
            try cancellation.check()
            try volume.validate(in: area); try volume.validate(in: target)
            stage = .publication
            try renameStep(payload, plan.destination, expectedTree: adopted, record: record,
                journal: journal, cancellation: cancellation, protection: protection)
            guard (try EntrySnapshot(fd: pin.descriptor)).sameObject(as: sourceIdentity),
                  (try EntrySnapshot(parent: target.fd, name: plan.destination.lastPathComponent)).sameObject(as: sourceIdentity) else {
                throw FileOperationFailure.recoveryUncertain
            }
            try security.require(pin.descriptor, at: plan.destination)
            try volume.validate(in: target)
            stage = .commit
            record.setState("committed"); try journal.save(record)
            // The catalog commit is the authority; shell cleanup is best effort.
            try? plan.source.retireCommittedShell(receipt: .init(job: record.id, spool: plan.source.spoolID))
            return .init(result: .init(items: [.init(source: nil, destination: plan.destination,
                status: .succeeded, recoveryURLs: [])], cancellationRequested: cancellation.isCancelled), recordID: record.id)
        } catch {
            FileOperationDiagnostics.caughtFailure(stage.checkpoint, error, recordID: active?.id)
            if let store, let active {
                active.setState("needsReview"); active.setFailureStage(stage.rawValue); try? store.save(active)
            }
            return .init(result: .init(items: [.init(source: nil, destination: plan.destination,
                status: operationStatus(error), recoveryURLs: active?.locations ?? [])],
                cancellationRequested: cancellation.isCancelled), recordID: active?.id)
        }
    }
}
