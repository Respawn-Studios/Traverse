import Darwin
import Foundation

internal struct SelectionGroupTrashReturn: Sendable {
    let url: URL?
    var failure: FileOperationFailure? = nil
}

extension RecoverableFileOperations {
    internal func selectionEmptyCustody(_ record: SelectionGroupRecord, at location: URL? = nil,
        cancellation: OperationCancellation) throws -> SelectionGroupEmptyCustody {
        let state = try record.project(), url = location ?? record.manifest.area
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        try record.manifest.volume.validate(in: parent)
        let entry = try NativeRenameEntry.observe(parent: parent, name: url.lastPathComponent)
        guard let expected = state.area, entry.identity.sameObject(as: expected), entry.identity.isDirectory else { throw FileOperationFailure.sourceChanged }
        if let proof = state.cleanupCustody {
            guard entry.fileID == proof.area.fileID, entry.linkID == proof.area.linkID else { throw FileOperationFailure.sourceChanged }
        }
        let area = try DirectoryAnchor(url, resolve: false)
        guard area.identity.sameObject(as: expected) else { throw FileOperationFailure.sourceChanged }
        let marker = try NativeRenameEntry.observe(parent: area, name: "owner")
        guard state.marker.map({ marker.sameEntry(as: $0) && marker.nameBytes == $0.nameBytes }) == true,
              try OperationJournal.read(name: "owner", anchor: area) == Data((record.manifest.owner.uuidString + ":" + record.manifest.id.uuidString).utf8) else { throw FileOperationFailure.sourceChanged }
        var names = ["owner"], container: NativeRenameEntry?
        if [.privateCandidate, .retained].contains(state.container) {
            guard let expected = state.containerEntry else { throw FileOperationFailure.recoveryUncertain }
            container = try NativeRenameEntry.observe(parent: area, name: expected.name)
            guard container!.sameEntry(as: expected), container!.nameBytes == expected.nameBytes else { throw FileOperationFailure.sourceChanged }
            let child = try DirectoryAnchor(url.appendingPathComponent(expected.name), resolve: false)
            guard child.identity.sameObject(as: expected.identity), try selectionChildren(child, cancellation: cancellation).isEmpty else { throw FileOperationFailure.conflict }
            try child.validate(); names.append(expected.name)
        }
        guard Set(try selectionChildren(area, cancellation: cancellation)) == Set(names) else { throw FileOperationFailure.conflict }
        try area.validate(); try parent.validate()
        return SelectionGroupEmptyCustody(area: entry, marker: marker, container: container)
    }

    internal func selectionRetentionRecord(_ record: SelectionGroupRecord, cancellation: OperationCancellation) throws -> RecoveryRetentionRecord {
        let state = try record.project()
        var reason: String? = "Native obligations or uncertain cleanup remain protected."
        if state.pending == nil, [.completed, .undone, .membersRestored, .closedRetained].contains(state.state),
           record.maximumEvents - record.events.count >= 3 {
            do { _ = try selectionEmptyCustody(record, cancellation: cancellation); reason = nil }
            catch is CancellationError { throw CancellationError() }
            catch { reason = "Owned empty custody changed, is unavailable, or contains another item." }
        }
        if state.state == .cleaned { reason = "Recovery custody was moved to Trash; Undo has ended." }
        return RecoveryRetentionRecord(id: record.manifest.id, operation: "New Folder with Selection", createdAt: record.manifest.createdAt,
            state: state.state.rawValue, areas: [RecoveryRetentionArea(url: state.cleanupTarget ?? record.manifest.area,
                logicalBytes: nil, verified: reason == nil, protectionReason: reason)], logicalBytes: nil, canCleanup: reason == nil, protectionReason: reason)
    }

    internal func cleanupSelectionGroupRecord(_ initial: SelectionGroupRecord, journal: OperationJournal,
        cancellation: OperationCancellation) -> RecoverableOperationResult {
        var record = initial, known: [URL] = []
        do {
            let state = try record.project()
            guard state.pending == nil, [.completed, .undone, .membersRestored, .closedRetained].contains(state.state),
                  record.maximumEvents - record.events.count >= 3 else { throw FileOperationFailure.recoveryUncertain }
            let proof = try selectionEmptyCustody(record, cancellation: cancellation)
            try journal.reserveSelectionCapacity(record)
            try selectionCheckpoint("beforeCleanupIntent", record)
            guard try selectionEmptyCustody(record, cancellation: cancellation) == proof else { throw FileOperationFailure.sourceChanged }
            record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .cleanupIntent, custody: proof))
            let parent = try selectionParent(record)
            let pinned = try pinEntry(parent: parent.fd, name: record.manifest.areaName, matching: proof.area.identity)
            defer { close(pinned) }
            try selectionCheckpoint("beforeCleanupNative", record)
            try cancellation.check()
            guard try selectionEmptyCustody(record, cancellation: cancellation) == proof,
                  try EntrySnapshot(fd: pinned).sameObject(as: proof.area.identity) else { throw FileOperationFailure.sourceChanged }
            try journal.validateSelectionOwnership()
            let segment = cancellation.segment(); try segment.beginMutation()
            let result: SelectionGroupTrashReturn
            if let trash = hooks.selectionGroup.trash { result = try trash(record.manifest.area) }
            else {
                var target: NSURL?, failure: FileOperationFailure?
                do { try FileManager().trashItem(at: record.manifest.area, resultingItemURL: &target) }
                catch { failure = (error as? FileOperationFailure) ?? .ioFailure }
                result = SelectionGroupTrashReturn(url: target as URL?, failure: failure)
            }
            // Preserve returned location before any observer/postcondition can fail.
            if let target = result.url {
                known.append(target)
                record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .cleanupReturned, target: target))
            }
            try selectionCheckpoint("afterCleanupNative", record)
            if let failure = result.failure { throw failure }
            guard let target = result.url else { throw FileOperationFailure.recoveryUncertain }
            try requireAbsent(record.manifest.areaName, in: parent.fd)
            _ = try selectionEmptyCustody(record, at: target, cancellation: segment)
            let targetParent = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
            let targetArea = try DirectoryAnchor(target, resolve: false)
            try syncDirectory(targetArea); try syncDirectory(parent); try syncDirectory(targetParent)
            try selectionCheckpoint("afterCleanupSync", record)
            _ = try selectionEmptyCustody(record, at: target, cancellation: segment)
            try parent.validate(); try targetParent.validate(); try requireAbsent(record.manifest.areaName, in: parent.fd)
            guard try EntrySnapshot(fd: pinned).sameObject(as: proof.area.identity) else { throw FileOperationFailure.sourceChanged }
            record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .cleanupConfirmed))
            return RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: record.manifest.area,
                destination: target, status: .succeeded, recoveryURLs: [])], cancellationRequested: cancellation.isCancelled), recordID: record.manifest.id)
        } catch {
            return RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: record.manifest.area,
                destination: nil, status: operationStatus(error), recoveryURLs: known)], cancellationRequested: cancellation.isCancelled), recordID: record.manifest.id)
        }
    }
}
