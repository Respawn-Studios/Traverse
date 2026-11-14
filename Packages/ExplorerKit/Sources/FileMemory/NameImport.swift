import ExplorerCore
import Foundation
import LocalStorage

public final class PreparedNameImport: Sendable {
    internal let token = UUID(), owner: UUID, epoch: UInt64
    internal let authority: NamePublicationAuthority
    public let recordCount: Int, encodedBytes: Int, discardedLocations: Int
    public let repeatedDescriptions: Int, matchingDescriptions: Int, matchingSourceIDs: Int
    internal init(authority: NamePublicationAuthority, owner: UUID, epoch: UInt64, value: NameImportPayload) {
        self.authority = authority; self.owner = owner; self.epoch = epoch
        recordCount = value.names.count; encodedBytes = value.encodedBytes; discardedLocations = value.locationCount
        repeatedDescriptions = value.repeatedDescriptions; matchingDescriptions = value.matchingDescriptions; matchingSourceIDs = value.matchingSourceIDs
    }
    deinit { authority.cancelImport(self) }
}
public struct NameImportAttempt: Sendable, Equatable {
    internal let catalog: UUID, nonce: UUID
    public let records: Int
}
public enum NameImportOutcome: Sendable, Equatable {
    case imported(NameImportAttempt)
    case committedButHidden(NameImportAttempt)
    case notImported(NameImportFailure)
    case uncertain
}
public enum NameImportResolution: Sendable, Equatable { case allPresent(records: Int), unknown }
public enum NameImportTarget: Sendable { case existing(PersistentNameStore), newCatalog(directory: URL) }

/// One selected-file lifecycle, including the pre-catalog state. Imported values
/// never escape as a raw array to a view, and cancellation retains actual work.
public actor NameImportSession {
    private let target: NameImportTarget
    private let activity: FileActivityGate?
    private nonisolated let authority: NamePublicationAuthority
    private nonisolated let owner = UUID()
    private nonisolated let cancellation = RememberedNameCancellation()
    private var preparation: Task<PreparedNameImport, Error>?
    private var applying: Task<NameImportOutcome, Never>?
    private var created: PersistentNameStore?
    private var closed = false

    public init(target: NameImportTarget, activity: FileActivityGate? = nil) {
        self.target = target; self.activity = activity
        switch target { case .existing(let store): authority = store.publication; case .newCatalog: authority = .init() }
    }
    public func preview(selectedFile: URL, retaining access: (any Sendable)? = nil) async throws -> PreparedNameImport {
        try await preview(selectedFile: selectedFile, retaining: access, probe: nil)
    }
    internal func preview(selectedFile: URL, retaining access: (any Sendable)? = nil, probe: NameImportProbe?) async throws -> PreparedNameImport {
        guard !closed, preparation == nil, applying == nil, created == nil else { throw NameImportFailure.stalePreview }
        try PortableNameInput.check(cancellation)
        authority.cancelImport(owner: owner)
        let owner = self.owner, authority = self.authority, cancellation = self.cancellation, activity = self.activity
        let target = self.target
        let task = Task<PreparedNameImport, Error> {
            switch target {
            case .existing(let store): return try await store.prepareImport(selectedFile, owner: owner, access: access, cancellation: cancellation, probe: probe)
            case .newCatalog(let directory):
                let inspection = await PersistentNameStore.inspect(directory: directory, activity: activity)
                guard inspection.status == .absent else { throw NameImportFailure.stalePreview }
                return try await Task.detached(priority: .utility) {
                    let lease = try activity?.begin(), reading = try authority.beginImportRead(owner)
                    defer { authority.endImportRead(owner); withExtendedLifetime(lease) {}; withExtendedLifetime(reading.use) {}; withExtendedLifetime(access) {} }
                    let epoch = reading.epoch
                    var payload = try PortableNameInput.read(selectedFile, cancellation: cancellation,
                        current: { try authority.checkExportEpoch(epoch) }, probe: probe)
                    try NameImportDuplicates.within(&payload, cancellation: cancellation)
                    try PortableNameInput.check(cancellation); try authority.checkExportEpoch(epoch)
                    return try authority.captureImport(payload, owner: owner, epoch: epoch)
                }.value
            }
        }
        preparation = task
        defer { preparation = nil }
        let result = try await task.value
        guard !closed, !cancellation.isCancelled else { authority.cancelImport(result); throw NameImportFailure.cancelled }
        return result
    }
    public func apply(_ preview: PreparedNameImport) async -> NameImportOutcome { await apply(preview, probe: nil) }
    internal func apply(_ preview: PreparedNameImport, probe: NameImportProbe?) async -> NameImportOutcome {
        guard !closed, applying == nil, preparation == nil, preview.owner == owner, !cancellation.isCancelled else { return .notImported(.stalePreview) }
        let target = self.target, cancellation = self.cancellation, authority = self.authority, activity = self.activity
        let task = Task<NameImportOutcome, Never> {
            switch target {
            case .existing(let store): return await store.applyImport(preview, cancellation: cancellation, probe: probe)
            case .newCatalog(let directory):
                let result = await PersistentNameStore.createImported(directory: directory, preview: preview,
                    publication: authority, activity: activity, cancellation: cancellation, probe: probe)
                if let store = result.store { self.created = store }
                return result.outcome
            }
        }
        applying = task; defer { applying = nil }; return await task.value
    }
    /// Only the app-profile owner adopts a new catalog after successful creation.
    public func takeCreatedStore() -> PersistentNameStore? { let result = created; created = nil; return result }
    public nonisolated func cancel() { cancellation.cancel(); authority.cancelImport(owner: owner) }
    public func close() async {
        closed = true; cancel()
        if let preparation, let preview = try? await preparation.value { authority.cancelImport(preview) }
        if let applying { _ = await applying.value }
        if let created { await created.close(); self.created = nil }
        await authority.waitForImportRetirement(owner)
    }
}

extension PersistentNameStore {
    internal func prepareImport(_ file: URL, owner: UUID, access: (any Sendable)?, cancellation: RememberedNameCancellation,
                                probe: NameImportProbe?) async throws -> PreparedNameImport {
        try requireWrite()
        let lease = try activity?.begin(), reading = try publication.beginImportRead(owner), epoch = reading.epoch
        defer { publication.endImportRead(owner); withExtendedLifetime(lease) {}; withExtendedLifetime(reading.use) {}; withExtendedLifetime(access) {} }
        let authority = publication
        var payload = try await Task.detached(priority: .utility) {
            try PortableNameInput.read(file, cancellation: cancellation, current: { try authority.checkExportEpoch(epoch) }, probe: probe)
        }.value
        try requireWrite(); try publication.checkExportEpoch(epoch)
        guard try database.statistics().records + payload.names.count <= NameStoreFormat.maximumRecords else { throw NameImportFailure.quota }
        try catalog.validate()
        try database.importDuplicates(&payload, cancellation: cancellation) { try self.publication.checkExportEpoch(epoch) }
        try catalog.validate(); try PortableNameInput.check(cancellation)
        return try publication.captureImport(payload, owner: owner, epoch: epoch)
    }
    internal func applyImport(_ preview: PreparedNameImport, cancellation: RememberedNameCancellation,
                              probe: NameImportProbe?) -> NameImportOutcome {
        var committed = false, began = false
        var actualUse: RememberedNameUse?, activityLease: FileActivityGate.Lease?
        defer { publication.endCommit(preview.token); withExtendedLifetime(actualUse) {}; withExtendedLifetime(activityLease) {} }
        do {
            try requireWrite(); try PortableNameInput.check(cancellation)
            let work = try publication.beginImport(preview)
            actualUse = work.use; activityLease = try activity?.begin()
            guard try database.statistics().records + work.value.names.count <= NameStoreFormat.maximumRecords else { throw NameImportFailure.quota }
            let nonce = UUID()
            try catalog.beginWrite(); began = true
            try database.transaction(beforeCommit: {
                try probe?(.beforeCommit); try PortableNameInput.check(cancellation)
                try self.publication.beginImportCommit(preview.token, epoch: work.epoch)
                try probe?(.commitAdmitted)
            }) {
                for names in work.value.names {
                    try PortableNameInput.check(cancellation); try self.publication.checkExportEpoch(work.epoch)
                    try database.save(id: RememberedItemID(UUID()), names: names, expected: nil, nonce: nonce, withinTransaction: true)
                }
                try probe?(.rows)
            }
            committed = true; try probe?(.committed)
            try catalog.synchronize(); try catalog.endWrite(); try core.invalidate(); try probe?(.acknowledged)
            let attempt = NameImportAttempt(catalog: catalog.storeID, nonce: nonce, records: work.value.names.count)
            return publication.hasPending ? .committedButHidden(attempt) : .imported(attempt)
        } catch {
            if committed || database.commitUncertain { suspended = true }
            if began { do { try catalog.endWrite() } catch { suspended = true } }
            return suspended ? .uncertain : .notImported(Self.importFailure(error))
        }
    }
    public func resolveImport(_ attempt: NameImportAttempt) throws -> NameImportResolution {
        try requireOpen(); try catalog.validate()
        guard attempt.catalog == catalog.storeID, !publication.hasPending, try database.pendingForgetCount() == 0 else { return .unknown }
        let count = try database.importPresence(nonce: attempt.nonce)
        try catalog.validate(); return count == attempt.records ? .allPresent(records: count) : .unknown
    }
    private static func importFailure(_ error: Error) -> NameImportFailure {
        if let value = error as? NameImportFailure { return value }
        if error as? NameStoreFailure == .quota || error as? NameIndexFailure == .resourceLimit { return .quota }
        if error as? NameExportFailure == .stalePreview || error as? NameStoreFailure == .forgetPending { return .stalePreview }
        return .storageUnavailable
    }
    internal static func createImported(directory: URL, preview: PreparedNameImport, publication: NamePublicationAuthority,
        activity: FileActivityGate?, cancellation: RememberedNameCancellation, probe: NameImportProbe?) async -> (outcome: NameImportOutcome, store: PersistentNameStore?) {
        await Task.detached(priority: .utility) {
            var namespaceCreated = false
            do {
                try PortableNameInput.check(cancellation)
                let work = try publication.beginImport(preview)
                defer { publication.endCommit(preview.token); withExtendedLifetime(work.use) {} }
                let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
                try await PrivateStateDirectory(directory: directory, activity: activity, requireNew: true).prepare()
                namespaceCreated = true
                let catalog = try OwnedNameCatalog.create(directory)
                do {
                    let database = try NameIndexDatabase(catalog: catalog, action: .edit, creating: true, vfs: nil)
                    do {
                        try database.transaction(beforeCommit: {
                            try probe?(.beforeCommit); try PortableNameInput.check(cancellation)
                            try publication.beginImportCommit(preview.token, epoch: work.epoch)
                            try probe?(.commitAdmitted)
                        }) {
                            try PortableNameInput.check(cancellation); try publication.checkExportEpoch(work.epoch)
                            try database.initializeRows(catalog, first: work.value.names[0])
                            for names in work.value.names.dropFirst() {
                                try PortableNameInput.check(cancellation); try publication.checkExportEpoch(work.epoch)
                                try database.save(id: RememberedItemID(UUID()), names: names, expected: nil, nonce: catalog.firstNonce, withinTransaction: true)
                            }
                            try probe?(.rows)
                        }
                        try probe?(.committed); try catalog.synchronize()
                        try database.validateRows(verifyIndex: true); try catalog.publishReady(); try catalog.sealReadState()
                        let store = try PersistentNameStore(catalog: catalog, database: database, activity: activity, compatible: true, publication: publication)
                        try probe?(.acknowledged)
                        return (.imported(NameImportAttempt(catalog: catalog.storeID, nonce: catalog.firstNonce, records: work.value.names.count)), store)
                    } catch { database.close(); throw error }
                } catch { catalog.release(); throw error }
            } catch { return (namespaceCreated ? .uncertain : .notImported(importFailure(error)), nil) }
        }.value
    }
}
