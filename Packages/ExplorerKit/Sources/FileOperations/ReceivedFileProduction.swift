import Darwin
import Foundation

/// A concrete one-file import plan. Source bytes/authority stay in its qualified
/// adapter, separate from generic private-state Copy access and native views.
public final class ReceivedFilePlan: Sendable {
    public var destination: URL { production.destination }
    public var logicalBytes: UInt64 { production.logicalBytes }
    internal let production: ArchiveCreationPlan
    internal init(_ production: ArchiveCreationPlan) { self.production = production }
}

extension RecoverableFileOperations {
    /// Capture the directory chosen before receiving any bytes. The observation
    /// has no access authority; final preparation still repeats all checks.
    @discardableResult public func checkReceivedFileDestination(parent: URL, name: String,
        observing expectedParent: FileOperationSelection? = nil) async throws -> FileOperationSelection {
        try await checkReceivedFileDestinations(parent: parent, names: [name], observing: expectedParent)
    }
    /// A single observed parent for a bounded group. Check the entire target
    /// namespace before receiving bodies; every final publication still repeats
    /// its own absent-name and live-parent checks and has independent Undo.
    @discardableResult public func checkReceivedFileDestinations(parent: URL, names: [String],
        observing expectedParent: FileOperationSelection? = nil) async throws -> FileOperationSelection {
        try await worker { cancellation in
            guard !names.isEmpty, names.count <= 16 else { throw FileOperationFailure.invalidRequest }
            let target = try DirectoryAnchor(parent)
            if let expectedParent {
                guard expectedParent.urls.count == 1, expectedParent.identities.count == 1,
                      expectedParent.urls[0] == target.url, expectedParent.identities[0].isDirectory else { throw FileOperationFailure.invalidRequest }
                guard target.identity.sameObject(as: expectedParent.identities[0]) else { throw FileOperationFailure.destinationChanged }
            }
            guard try NativeRenameVolume.qualified(in: target) != nil else { throw FileOperationFailure.unsupported }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            // APFS treats canonically equivalent names as the same entry even
            // on a case-sensitive volume. Match this held destination's policy.
            let sensitive = fpathconf(target.fd, _PC_CASE_SENSITIVE) == 1
            var reserved = Set<String>()
            for name in names {
                try cancellation.check(); try validateName(name)
                let normalized = name.precomposedStringWithCanonicalMapping
                let key = sensitive ? normalized : normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                guard reserved.insert(key).inserted else { throw FileOperationFailure.conflict }
                guard target.url.path.utf8.count + max(name.utf8.count + 2, 74) < PATH_MAX else { throw FileOperationFailure.unsupported }
                try protection.requireEntry(parent: target, name: name); try requireAbsent(name, in: target.fd)
            }
            try target.validate(); try cancellation.check()
            return .init(urls: [target.url], identities: [target.identity])
        }
    }
    @_spi(ArchiveProduction) public func prepareReceivedFile(parent: URL, name: String,
        observing destination: FileOperationSelection? = nil,
        origin: ReceivedItemOrigin = .download,
        publicQuarantineV1: Bool = false,
        publicZIPExtractionV1: Bool = false,
        publicTARExtractionV17: Bool = false,
        makeProducer: @escaping @Sendable (@Sendable () throws -> Void) throws -> any ArchiveFileProducer) async throws -> ReceivedFilePlan {
        try await worker { cancellation in
            if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
            if publicQuarantineV1 {
                guard origin == .download,
                      self.receivedDownloadPublicQuarantinePolicy == .sourceQualification else {
                    throw FileOperationFailure.unsupported
                }
            }
            if publicZIPExtractionV1 {
                guard !publicQuarantineV1, !publicTARExtractionV17, origin == .zipExtraction,
                      self.zipOneFilePublicExtractionPolicy == .sourceQualification else {
                    throw FileOperationFailure.unsupported
                }
            }
            if publicTARExtractionV17 {
                guard !publicQuarantineV1, !publicZIPExtractionV1, origin == .tarExtraction,
                      self.tarOneFilePublicExtractionPolicy == .sourceQualification else {
                    throw FileOperationFailure.unsupported
                }
            }
            try validateName(name)
            let target = try DirectoryAnchor(parent)
            if let destination {
                guard destination.urls.count == 1, destination.identities.count == 1,
                      destination.urls[0] == target.url, destination.identities[0].isDirectory else {
                    throw FileOperationFailure.invalidRequest
                }
                guard target.identity.sameObject(as: destination.identities[0]) else {
                    throw FileOperationFailure.destinationChanged
                }
            }
            guard try NativeRenameVolume.qualified(in: target) != nil,
                  target.url.path.utf8.count + max(name.utf8.count + 2, 74) < PATH_MAX else { throw FileOperationFailure.unsupported }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.requireEntry(parent: target, name: name); try requireAbsent(name, in: target.fd); try cancellation.check()
            let producer = try makeProducer({ try cancellation.check() }), preview = producer.preview
            if publicQuarantineV1 && !(producer is any PublicQuarantineReceivedFileProducer) {
                throw FileOperationFailure.unsupported
            }
            if publicZIPExtractionV1 && !(producer is any PublicQuarantineZIPExtractionFileProducer) {
                throw FileOperationFailure.unsupported
            }
            if publicTARExtractionV17 && !(producer is any PublicQuarantineTARExtractionFileProducer) {
                throw FileOperationFailure.unsupported
            }
            guard preview.files == 1, preview.folders == 0, preview.longestPathBytes == 0,
                  preview.logicalBytes <= 1 << 30 else { throw FileOperationFailure.unsupported }
            let plan = ArchiveCreationPlan(sources: [], destination: target.url.appendingPathComponent(name), sourcesIdentity: [],
                sourceParents: [:], parentIdentity: target.identity, producer: producer, engine: self.continuationSession,
                authoredFormat: nil, receivedFile: true, receivedOrigin: origin,
                publicQuarantineReceivedFile: publicQuarantineV1, publicZIPExtractionFile: publicZIPExtractionV1,
                publicTARExtractionFile: publicTARExtractionV17)
            try self.validateArchiveCreation(plan, cancellation: cancellation); return ReceivedFilePlan(plan)
        }
    }
    public func performReceivedFile(_ plan: ReceivedFilePlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let result = await performArchiveCreation(plan.production, progress: progress)
        // Cancellation/capacity can refuse submission before the worker consumes
        // its plan. Retire only this engine's still-unused receipt off-main;
        // foreign-engine attempts cannot release another engine's source.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                if plan.production.consume(by: self.continuationSession) { plan.production.producer.finished() }
                continuation.resume()
            }
        }
        return result
    }
}
