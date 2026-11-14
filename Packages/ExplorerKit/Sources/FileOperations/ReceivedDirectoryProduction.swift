import Darwin
import Foundation

/// One sealed received tree. No remote path, private spool descriptor or source
/// grant escapes its adapter; publication and Undo stay in the local engine.
public final class ReceivedDirectoryPlan: Sendable {
    public var destination: URL { production.destination }
    public var files: Int { production.files }
    public var folders: Int { production.folders }
    public var logicalBytes: UInt64 { production.logicalBytes }
    internal let production: DirectoryProductionPlan
    internal init(_ production: DirectoryProductionPlan) { self.production = production }
}

extension RecoverableFileOperations {
    /// Capture the chosen parent before any body receipt; observation does not
    /// replace the caller's access grant or later object/absence checks.
    @discardableResult public func checkReceivedDirectoryDestination(parent: URL, name: String,
        observing expectedParent: FileOperationSelection? = nil, longestPathBytes: Int = 0) async throws -> FileOperationSelection {
        guard longestPathBytes >= 0, longestPathBytes < PATH_MAX else { throw FileOperationFailure.unsupported }
        let selected = try await checkReceivedFileDestination(parent: parent, name: name, observing: expectedParent)
        guard let chosen = selected.urls.first,
              max(chosen.path.utf8.count + 74, chosen.path.utf8.count + name.utf8.count + 2)
                + longestPathBytes < PATH_MAX else { throw FileOperationFailure.unsupported }
        return selected
    }
    @_spi(ArchiveProduction) public func prepareReceivedDirectory(parent: URL, name: String,
        observing destination: FileOperationSelection,
        origin: ReceivedItemOrigin = .download,
        publicQuarantineTreeV16: Bool = false,
        makeProducer: @escaping @Sendable (@Sendable () throws -> Void) throws -> any ArchiveDirectoryProducer) async throws -> ReceivedDirectoryPlan {
        try await worker { cancellation in
            if case .generatedFixture = self.copyExecutionAuthorization { throw FileOperationFailure.unsupported }
            try validateName(name)
            let target = try DirectoryAnchor(parent)
            guard destination.urls.count == 1, destination.identities.count == 1,
                  destination.urls[0] == target.url, destination.identities[0].isDirectory else {
                throw FileOperationFailure.invalidRequest
            }
            guard target.identity.sameObject(as: destination.identities[0]) else { throw FileOperationFailure.destinationChanged }
            guard try NativeRenameVolume.qualified(in: target) != nil else { throw FileOperationFailure.unsupported }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.requireEntry(parent: target, name: name); try requireAbsent(name, in: target.fd); try cancellation.check()
            let producer = try makeProducer({ try cancellation.check() })
            do {
                if publicQuarantineTreeV16 {
                    guard origin == .download, producer.publicProducedTreeV16 == .receivedFolder,
                          self.receivedFolderPublicQuarantinePolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                } else if producer.publicProducedTreeV16 != nil { throw FileOperationFailure.invalidRequest }
                let preview = producer.preview
                guard preview.files >= 0, preview.files <= 1_024, preview.folders >= 0,
                      preview.files + preview.folders < 2_048, preview.logicalBytes <= 1 << 30,
                      preview.longestPathBytes >= 0, preview.longestPathBytes < PATH_MAX,
                      max(target.url.path.utf8.count + 74, target.url.path.utf8.count + name.utf8.count + 2)
                        + preview.longestPathBytes < PATH_MAX else { throw FileOperationFailure.unsupported }
                let plan = DirectoryProductionPlan(source: nil, destination: target.url.appendingPathComponent(name),
                    sourceIdentity: nil, parentIdentity: target.identity, producer: producer, engine: self.continuationSession,
                    receivedOrigin: origin, publicProducedTreeV16: producer.publicProducedTreeV16)
                try self.validateArchiveExtraction(plan, cancellation: cancellation)
                return ReceivedDirectoryPlan(plan)
            } catch { producer.finished(); throw error }
        }
    }
    public func performReceivedDirectory(_ plan: ReceivedDirectoryPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await performDirectoryProduction(plan.production, progress: progress)
    }
}
