import Darwin
import Foundation

internal struct JournalNameRename: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, forwardIntent, forwardApplied, reverseIntent, reversed, notApplied
    }
    let protocolVersion: Int
    let parent: URL
    let parentIdentity: EntrySnapshot
    let volume: NativeRenameVolume
    let entry: NativeRenameEntry
    let oldName: Data
    let newName: Data
    var phase: Phase

    var source: URL { parent.appendingPathComponent(String(decoding: oldName, as: UTF8.self)) }
    var destination: URL { parent.appendingPathComponent(String(decoding: newName, as: UTF8.self)) }

    func validate(state: String) throws {
        try OperationJournal.validateLocation(parent)
        try volume.validateRepresentation(); try entry.validateRepresentation()
        for bytes in [oldName, newName] {
            guard let name = String(data: bytes, encoding: .utf8), Data(name.utf8) == bytes else { throw FileOperationFailure.recoveryUncertain }
            try validateName(name)
        }
        guard protocolVersion == 1, oldName != newName, oldName == entry.nameBytes,
              parentIdentity.isDirectory, parentIdentity.device == volume.device,
              entry.identity.device == volume.device, entry.parentID == UInt64(parentIdentity.inode) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let states: [String]
        switch phase {
        case .prepared: states = ["preparing", "needsReview"]
        case .forwardIntent: states = ["mutating", "needsReview"]
        case .forwardApplied: states = ["mutating", "committed", "needsReview"]
        case .reverseIntent: states = ["undoing", "needsReview"]
        case .reversed: states = ["undoing", "undone", "needsReview"]
        case .notApplied: states = ["undone", "needsReview"]
        }
        guard states.contains(state) else { throw FileOperationFailure.recoveryUncertain }
    }

    func recoveryAnchor() throws -> (DirectoryAnchor, NativeRenameVolume) {
        let anchor = try DirectoryAnchor(parent, resolve: false)
        guard let currentVolume = try NativeRenameVolume.qualified(in: anchor),
              currentVolume.uuid == volume.uuid,
              matchesStored(parentIdentity, anchor.identity, currentVolume: currentVolume) else {
            throw FileOperationFailure.destinationChanged
        }
        return (anchor, currentVolume)
    }

    /// After the durable UUID comparison, keep the current mount identity exact
    /// throughout this live reverse operation.
    func validateVolume(in parent: DirectoryAnchor, currentVolume: NativeRenameVolume) throws {
        guard try NativeRenameVolume.qualified(in: parent) == currentVolume else {
            throw FileOperationFailure.destinationChanged
        }
    }

    private func matchesStored(_ stored: EntrySnapshot, _ current: EntrySnapshot,
                               currentVolume: NativeRenameVolume?) -> Bool {
        guard let currentVolume else { return stored.sameObject(as: current) }
        return currentVolume.uuid == volume.uuid && current.device == currentVolume.device &&
            stored.inode == current.inode && stored.type == current.type &&
            stored.birthSeconds == current.birthSeconds && stored.birthNanos == current.birthNanos
    }

    private func matchesStored(_ current: NativeRenameEntry, currentVolume: NativeRenameVolume?) -> Bool {
        matchesStored(entry.identity, current.identity, currentVolume: currentVolume) &&
            entry.fileID == current.fileID && entry.linkID == current.linkID &&
            entry.parentID == current.parentID
    }

    /// Both lookups may resolve on an insensitive filesystem. Actual spelling
    /// identifies the state; object equality alone cannot grant conflict consent.
    func requireLocation(_ bytes: Data, other: Data, in parent: DirectoryAnchor,
                         currentVolume: NativeRenameVolume? = nil) throws -> NativeRenameEntry {
        let current = try NativeRenameEntry.observe(parent: parent, name: String(decoding: bytes, as: UTF8.self))
        guard matchesStored(current, currentVolume: currentVolume), current.nameBytes == bytes else {
            throw FileOperationFailure.sourceChanged
        }
        if let occupied = try NativeRenameEntry.optional(parent: parent, name: String(decoding: other, as: UTF8.self)) {
            guard occupied.sameEntry(as: current), occupied.nameBytes == bytes else { throw FileOperationFailure.conflict }
        }
        return current
    }

    enum Location { case old, new }
    func location(in parent: DirectoryAnchor, currentVolume: NativeRenameVolume? = nil) throws -> Location {
        let old = try NativeRenameEntry.optional(parent: parent, name: String(decoding: oldName, as: UTF8.self))
        let new = try NativeRenameEntry.optional(parent: parent, name: String(decoding: newName, as: UTF8.self))
        if let old, matchesStored(old, currentVolume: currentVolume), old.nameBytes == oldName,
           new == nil || (new!.sameEntry(as: old) && new!.nameBytes == oldName) { return .old }
        if let new, matchesStored(new, currentVolume: currentVolume), new.nameBytes == newName,
           old == nil || (old!.sameEntry(as: new) && old!.nameBytes == newName) { return .new }
        throw FileOperationFailure.recoveryUncertain
    }
}

extension RecoverableFileOperations {
    /// Nil is exclusively a pre-mutation, known-unqualified-volume fallback.
    /// Once admitted, failures never retry through the legacy tree protocol.
    internal func sameParentRename(source: URL, name: String, observing selection: FileOperationSelection?,
                                   cancellation: OperationCancellation) -> RecoverableOperationResult? {
        var journal: OperationJournal?
        var recordID: UUID?
        var known: [URL] = []
        var activeParent: DirectoryAnchor?
        var pinnedSource: Int32 = -1
        var pinnedIdentity: EntrySnapshot?
        defer { if pinnedSource >= 0 { close(pinnedSource) } }
        do {
            try cancellation.check(); try validateName(name)
            let parent = try DirectoryAnchor(source.deletingLastPathComponent())
            activeParent = parent
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            try protection.requireEntry(parent: parent, name: source.lastPathComponent)
            try protection.requireEntry(parent: parent, name: name)
            guard let volume = try NativeRenameVolume.qualified(in: parent) else { return nil }
            let entry = try NativeRenameEntry.observe(parent: parent, name: source.lastPathComponent)
            if let selection {
                guard selection.urls.count == selection.identities.count else { throw FileOperationFailure.invalidRequest }
                var matchedSource = false
                for (url, snapshot) in zip(selection.urls, selection.identities) {
                    if Data(url.path.utf8) == Data(source.path.utf8) {
                        // Preserve the forward selection contract: editing during the
                        // inline editor still requires a new selection observation.
                        guard snapshot == entry.identity else { throw FileOperationFailure.sourceChanged }
                        matchedSource = true
                    } else if Data(url.path.utf8) == Data(parent.url.path.utf8) {
                        guard snapshot.sameObject(as: parent.identity) else { throw FileOperationFailure.destinationChanged }
                    } else { throw FileOperationFailure.invalidRequest }
                }
                guard matchedSource else { throw FileOperationFailure.invalidRequest }
            }
            let pinned = try pinEntry(parent: parent.fd, name: entry.name, matching: entry.identity)
            pinnedSource = pinned; pinnedIdentity = entry.identity
            if entry.nameBytes == Data(name.utf8) {
                try parent.validate(); try volume.validate(in: parent); try cancellation.check()
                let final = try NativeRenameEntry.observe(parent: parent, name: name)
                guard final.sameEntry(as: entry), final.nameBytes == entry.nameBytes else { throw FileOperationFailure.sourceChanged }
                return renameResult(source: source, destination: parent.url.appendingPathComponent(name), status: .succeeded,
                                    id: nil, locations: [], cancellation: cancellation)
            }
            let guardValue = JournalNameRename(protocolVersion: 1, parent: parent.url, parentIdentity: parent.identity,
                volume: volume, entry: entry, oldName: entry.nameBytes, newName: Data(name.utf8), phase: .prepared)
            _ = try guardValue.requireLocation(guardValue.oldName, other: guardValue.newName, in: parent)
            try parent.validate(); try cancellation.check()
            let store = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation)
            journal = store
            try protection.historyOpened(store.anchor)
            try store.reserveCapacity(steps: 0, areas: 0, locations: 2, trashIntents: 0,
                estimatedBytes: 16_384 + parent.url.path.utf8.count * 16 + name.utf8.count * 8)
            let record = try store.beginEdit(operation: "Rename", nameRename: guardValue)
            try record.bindPersistentVolume(in: parent)
            known = [guardValue.source, guardValue.destination]
            // appendLocations preserves distinct Unicode byte spellings that URL
            // equality may consider equivalent; these are private recovery paths.
            try record.appendLocations(known)
            recordID = record.id // Also identifies a commit with an unknown acknowledgement.
            try store.save(record)
            cancellation.progress?.begin(.planning, source: guardValue.source, destination: guardValue.destination)
            try record.setNameRenamePhase(.forwardIntent); record.setState("mutating"); try store.save(record)
            hooks.afterIntent?()
            try performNameRename(guardValue, forward: true, parent: parent, pinned: pinned, cancellation: cancellation, protection: protection)
            try record.setNameRenamePhase(.forwardApplied); try store.save(record)
            record.setState("committed"); try store.save(record)
            return renameResult(source: guardValue.source, destination: guardValue.destination, status: .succeeded,
                                id: record.id, locations: [], cancellation: cancellation)
        } catch {
            if let current = activeParent?.currentURL {
                known += [current.appendingPathComponent(source.lastPathComponent), current.appendingPathComponent(name)]
            }
            if pinnedSource >= 0, let identity = pinnedIdentity, let current = entryURL(for: pinnedSource, matching: identity) {
                known.append(current)
            }
            if let journal, let candidateID = recordID {
                do {
                    if let durable = try journal.openEdit(candidateID) {
                        try? durable.appendNewLocations(known)
                        durable.setState("needsReview"); try? journal.save(durable)
                    } else { recordID = nil } // A confirmed absent first commit has no recovery record.
                } catch { /* Preserve the ID when the durable acknowledgement is unknown. */ }
            }
            return renameResult(source: source, destination: source.deletingLastPathComponent().appendingPathComponent(name),
                                status: operationStatus(error), id: recordID, locations: recordID == nil ? [] : known, cancellation: cancellation)
        }
    }

    internal func reverseNameRename(_ record: JournalEditSession, journal: OperationJournal, recovering: Bool,
                                    cancellation: OperationCancellation) -> RecoverableOperationResult {
        guard let rename = record.nameRename else {
            return renameResult(source: nil, destination: nil, status: .failed(.recoveryUncertain), id: record.id,
                                locations: record.locations, cancellation: cancellation)
        }
        var known = record.locations
        var activeParent: DirectoryAnchor?
        var pinned: Int32 = -1
        var pinnedIdentity: EntrySnapshot?
        defer { if pinned >= 0 { close(pinned) } }
        do {
            guard recovering ? ["preparing", "mutating", "needsReview", "undoing"].contains(record.state) : record.state == "committed" else {
                throw FileOperationFailure.recoveryUncertain
            }
            try cancellation.check()
            let (parent, currentVolume) = try rename.recoveryAnchor()
            activeParent = parent
            let location: JournalNameRename.Location
            if recovering { location = try rename.location(in: parent, currentVolume: currentVolume) }
            else {
                _ = try rename.requireLocation(rename.newName, other: rename.oldName, in: parent,
                                               currentVolume: currentVolume)
                location = .new
            }
            if recovering {
                switch rename.phase {
                case .prepared:
                    guard location == .old else { throw FileOperationFailure.recoveryUncertain }
                case .forwardIntent:
                    break // The syscall may or may not have happened.
                case .forwardApplied:
                    guard location == .new else { throw FileOperationFailure.recoveryUncertain }
                case .reverseIntent:
                    break // The reverse syscall may or may not have happened.
                case .reversed, .notApplied:
                    guard location == .old else { throw FileOperationFailure.recoveryUncertain }
                }
                if location == .old {
                    // Re-sync an observed effect when its former acknowledgement
                    // is unknown; never infer durable completion from lookup alone.
                    try parent.validate(); try hooks.beforeSync?(rename.source); try syncDirectory(parent)
                    try parent.validate(); try rename.validateVolume(in: parent, currentVolume: currentVolume)
                    _ = try rename.requireLocation(rename.oldName, other: rename.newName, in: parent,
                                                   currentVolume: currentVolume)
                    try record.setNameRenamePhase(rename.phase == .prepared || rename.phase == .forwardIntent || rename.phase == .notApplied ? .notApplied : .reversed)
                    record.setState("undone"); try journal.save(record)
                    return renameResult(source: rename.destination, destination: rename.source, status: .succeeded,
                                        id: record.id, locations: [], cancellation: cancellation)
                }
                // Sync the observed forward namespace before recording reverse intent.
                try parent.validate(); try hooks.beforeSync?(rename.destination); try syncDirectory(parent)
                try parent.validate(); try rename.validateVolume(in: parent, currentVolume: currentVolume)
                _ = try rename.requireLocation(rename.newName, other: rename.oldName, in: parent,
                                               currentVolume: currentVolume)
            } else {
                guard rename.phase == .forwardApplied, location == .new else { throw FileOperationFailure.recoveryUncertain }
            }
            let liveEntry = try rename.requireLocation(rename.newName, other: rename.oldName, in: parent,
                                                       currentVolume: currentVolume)
            pinnedIdentity = liveEntry.identity
            pinned = try pinEntry(parent: parent.fd, name: String(decoding: rename.newName, as: UTF8.self),
                                  matching: liveEntry.identity)
            try record.bindPersistentVolume(in: parent)
            try record.setNameRenamePhase(.reverseIntent); record.setState("undoing"); try journal.save(record)
            hooks.afterIntent?()
            try performNameRename(rename, forward: false, parent: parent, pinned: pinned,
                                  currentVolume: currentVolume, pinnedIdentity: liveEntry.identity,
                                  cancellation: cancellation)
            try record.setNameRenamePhase(.reversed); try journal.save(record)
            record.setState("undone"); try journal.save(record)
            return renameResult(source: rename.destination, destination: rename.source, status: .succeeded,
                                id: record.id, locations: [], cancellation: cancellation)
        } catch {
            if let current = activeParent?.currentURL {
                known += [current.appendingPathComponent(String(decoding: rename.oldName, as: UTF8.self)),
                          current.appendingPathComponent(String(decoding: rename.newName, as: UTF8.self))]
            }
            if pinned >= 0, let pinnedIdentity,
               let current = entryURL(for: pinned, matching: pinnedIdentity) { known.append(current) }
            // Reopen the durable revision after failed/unknown commits. Do not save
            // a stale candidate or let a failed acknowledgement imply rollback.
            if let durable = try? journal.openEdit(record.id) {
                try? durable.appendNewLocations(known)
                durable.setState("needsReview"); try? journal.save(durable)
            }
            return renameResult(source: rename.destination, destination: rename.source, status: operationStatus(error),
                                id: record.id, locations: known, cancellation: cancellation)
        }
    }

    private func performNameRename(_ rename: JournalNameRename, forward: Bool, parent: DirectoryAnchor,
                                   pinned: Int32, currentVolume: NativeRenameVolume? = nil,
                                   pinnedIdentity: EntrySnapshot? = nil, cancellation: OperationCancellation,
                                   protection: HistoryProtection? = nil) throws {
        let from = forward ? rename.oldName : rename.newName, to = forward ? rename.newName : rename.oldName
        let source = forward ? rename.source : rename.destination, destination = forward ? rename.destination : rename.source
        let expectedPinned = pinnedIdentity ?? rename.entry.identity
        func validateVolume() throws {
            if let currentVolume { try rename.validateVolume(in: parent, currentVolume: currentVolume) }
            else { try rename.volume.validate(in: parent) }
        }
        hooks.beforeRename?(); try hooks.beforeExclusiveRename?(source, destination)
        try cancellation.check(); try parent.validate(); try validateVolume()
        let before = try rename.requireLocation(from, other: to, in: parent, currentVolume: currentVolume)
        guard try EntrySnapshot(fd: pinned).sameObject(as: expectedPinned),
              before.identity.sameObject(as: expectedPinned) else { throw FileOperationFailure.sourceChanged }
        try protection?.requireEntry(parent: parent, name: String(decoding: from, as: UTF8.self))
        try protection?.requireEntry(parent: parent, name: String(decoding: to, as: UTF8.self))
        cancellation.progress?.begin(.publishing, source: source, destination: destination)
        try cancellation.beginMutation()
        // A descriptor-relative pathname syscall is not atomic compare-and-rename.
        // The postcondition detects uncertainty; it never authorizes blind rollback.
        try exclusiveRename(from: parent.fd, name: String(decoding: from, as: UTF8.self),
                            to: parent.fd, name: String(decoding: to, as: UTF8.self))
        hooks.afterRename?()
        let moved = try rename.requireLocation(to, other: from, in: parent, currentVolume: currentVolume)
        guard try EntrySnapshot(fd: pinned).sameObject(as: expectedPinned),
              moved.identity.sameObject(as: expectedPinned) else { throw FileOperationFailure.recoveryUncertain }
        cancellation.progress?.begin(.syncing, source: source, destination: destination)
        try parent.validate(); try validateVolume()
        try hooks.beforeSync?(destination); try syncDirectory(parent)
        try parent.validate(); try validateVolume()
        let final = try rename.requireLocation(to, other: from, in: parent, currentVolume: currentVolume)
        guard try EntrySnapshot(fd: pinned).sameObject(as: final.identity) else {
            throw FileOperationFailure.recoveryUncertain
        }
        // No cancellation check after mutation: validation, sync and both journal
        // commits drain before Stop is reported alongside the completed outcome.
    }

    private func renameResult(source: URL?, destination: URL?, status: FileOperationStatus, id: UUID?,
                              locations: [URL], cancellation: OperationCancellation) -> RecoverableOperationResult {
        RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: source, destination: destination,
            status: status, recoveryURLs: locations)], cancellationRequested: cancellation.isCancelled), recordID: id)
    }
}
