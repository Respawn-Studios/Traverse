import CryptoKit
import Darwin
import Foundation

/// Observations, never authority to create seals or mutate filesystem entries.
internal enum GroupedCopyObservationFailure: String, Codable, Sendable {
    case changed, denied, unavailable, unsupported, invalidInventory
}
internal enum GroupedCopyObservedParent: Codable, Sendable {
    case matched(EntrySnapshot, NativeRenameVolume)
    case unavailable(GroupedCopyObservationFailure)
}
internal enum GroupedCopyObservedSlot: Codable, Sendable {
    case absent
    case verified(VerifiedTree, identityDigest: String)
    case occupied(EntrySnapshot)
    case unavailable(GroupedCopyObservationFailure)
}
internal enum GroupedCopyObservedArea: Codable, Sendable {
    case absent
    case present(EntrySnapshot, children: [Data])
    case unavailable(GroupedCopyObservationFailure)
}
internal enum GroupedCopyObservedMarker: String, Codable, Sendable {
    case matched, missing, changed, unavailable, notInspected
}
internal struct GroupedCopyGroupObservation: Codable, Sendable {
    let ordinal: Int
    let area: GroupedCopyObservedArea
    let marker: GroupedCopyObservedMarker
}
internal struct GroupedCopyMemberObservation: Codable, Sendable {
    let ordinal: Int
    /// Nil only for a never-declared member.
    let area: GroupedCopyObservedArea?
    let privateSlot: GroupedCopyObservedSlot?
    let publicSlot: GroupedCopyObservedSlot
}
internal struct GroupedCopyFilesystemSnapshot: Sendable {
    let owner: UUID
    let job: UUID
    let revision: Int
    let destinationParent: GroupedCopyObservedParent
    let groups: [GroupedCopyGroupObservation]
    let members: [GroupedCopyMemberObservation]
    /// Actual observations only; excludes revision and mutable journal state.
    let inventoryDigest: String
}

internal enum GroupedCopyFilesystemEvidence {
    static func inspect(_ record: GroupedCopyRecord, cancellation: OperationCancellation) throws -> GroupedCopyFilesystemSnapshot {
        try record.validate()
        try cancellation.check()
        let destination = record.members[0].manifest.destination
        let parent: DirectoryAnchor?
        let parentObservation: GroupedCopyObservedParent
        do {
            let opened = try checkedParent(destination)
            parent = opened
            parentObservation = .matched(opened.identity, destination.volume)
        } catch {
            parent = nil
            parentObservation = .unavailable(reason(error))
        }
        var groups: [GroupedCopyGroupObservation] = []
        var members: [GroupedCopyMemberObservation] = []
        for group in record.groups {
            try cancellation.check()
            let observed = try observeArea(group.areaURL, expected: group.areaIdentity,
                parent: parent, limit: group.members.count + 1, cancellation: cancellation)
            let marker: GroupedCopyObservedMarker
            if case .present = observed, group.areaIdentity != nil {
                do {
                    let area = try DirectoryAnchor(group.areaURL, resolve: false)
                    guard let identity = group.areaIdentity, area.identity.sameObject(as: identity) else { throw FileOperationFailure.sourceChanged }
                    let entry = try NativeRenameEntry.observe(parent: area, name: GroupedCopyGroup.markerName)
                    guard entry.nameBytes == Data(GroupedCopyGroup.markerName.utf8), entry.identity.size <= 256 else { throw FileOperationFailure.recoveryUncertain }
                    let bytes = try OperationJournal.read(name: GroupedCopyGroup.markerName, anchor: area)
                    try area.validate()
                    marker = bytes == group.marker ? .matched : .changed
                } catch FileOperationFailure.notFound { marker = .missing }
                catch { marker = .unavailable }
            } else { marker = .notInspected }
            groups.append(GroupedCopyGroupObservation(ordinal: group.ordinal, area: observed, marker: marker))
        }
        for member in record.members {
            try cancellation.check()
            let publicSlot = try observeSlot(parent: parent, name: member.manifest.destination.nameBytes,
                seal: member.progress.seal, cancellation: cancellation)
            var areaObservation: GroupedCopyObservedArea?
            var privateSlot: GroupedCopyObservedSlot?
            if let declaration = member.progress.declaration {
                let group = record.groups[declaration.groupOrdinal]
                let groupParent: DirectoryAnchor?
                if case .present = groups[group.ordinal].area, groups[group.ordinal].marker == .matched {
                    let candidate = try? DirectoryAnchor(group.areaURL, resolve: false)
                    groupParent = candidate.flatMap { candidate in
                        group.areaIdentity.map { candidate.identity.sameObject(as: $0) ? candidate : nil } ?? nil
                    }
                } else { groupParent = nil }
                areaObservation = try observeArea(declaration.areaURL, expected: member.progress.seal?.areaIdentity,
                    parent: groupParent, limit: 1, cancellation: cancellation)
                let privateParent: DirectoryAnchor?
                if case .present? = areaObservation, let seal = member.progress.seal {
                    let candidate = try? DirectoryAnchor(declaration.areaURL, resolve: false)
                    privateParent = candidate.flatMap { $0.identity.sameObject(as: seal.areaIdentity) ? $0 : nil }
                } else { privateParent = nil }
                if case .absent? = areaObservation { privateSlot = .absent }
                else { privateSlot = try observeSlot(parent: privateParent, name: declaration.payloadName,
                    seal: member.progress.seal, cancellation: cancellation) }
            }
            members.append(GroupedCopyMemberObservation(ordinal: member.ordinal, area: areaObservation,
                privateSlot: privateSlot, publicSlot: publicSlot))
        }
        try cancellation.check()
        // This second parent guard catches a moved/replaced anchor during the scan.
        var finalParent = parentObservation
        if let parent { do { try parent.validate(); try destination.volume.validate(in: parent) }
            catch { finalParent = .unavailable(reason(error)) } }
        struct Inventory: Encodable {
            let owner: UUID; let job: UUID
            let parent: GroupedCopyObservedParent
            let groups: [GroupedCopyGroupObservation]; let members: [GroupedCopyMemberObservation]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Inventory(owner: record.head.owner, job: record.head.id,
            parent: finalParent, groups: groups, members: members))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return GroupedCopyFilesystemSnapshot(owner: record.head.owner, job: record.head.id,
            revision: record.head.revision, destinationParent: finalParent, groups: groups, members: members, inventoryDigest: digest)
    }

    static func checkedParent(_ slot: GroupedCopySlot) throws -> DirectoryAnchor {
        try slot.validate()
        let parent = try DirectoryAnchor(slot.parent, resolve: false)
        guard parent.identity.sameObject(as: slot.parentIdentity) else { throw FileOperationFailure.destinationChanged }
        try slot.volume.validate(in: parent)
        return parent
    }

    /// DirectoryAnchor deliberately grants search-only access. Enumeration needs
    /// a separate readable descriptor pinned to that same directory incarnation.
    static func children(in anchor: DirectoryAnchor, cancellation: OperationCancellation, limit: Int) throws -> [String] {
        try cancellation.check(); try anchor.validate()
        let descriptor = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { close(descriptor) }
        let before = try EntrySnapshot(fd: descriptor)
        guard before.sameObject(as: anchor.identity) else { throw FileOperationFailure.destinationChanged }
        let names = try childNames(in: descriptor, cancellation: cancellation, limit: limit)
        guard try EntrySnapshot(fd: descriptor) == before else { throw FileOperationFailure.destinationChanged }
        try anchor.validate()
        return names
    }

    private static func observeSlot(parent: DirectoryAnchor?, name: Data, seal: GroupedCopySeal?,
                                    cancellation: OperationCancellation) throws -> GroupedCopyObservedSlot {
        try cancellation.check()
        guard let parent, let literal = String(data: name, encoding: .utf8) else { return .unavailable(.unavailable) }
        do {
            guard let entry = try NativeRenameEntry.optional(parent: parent, name: literal) else { return .absent }
            guard entry.nameBytes == name else { return .occupied(entry.identity) }
            guard let seal, seal.proof.payload.identity.sameObject(as: entry.identity), entry.identity.type == S_IFREG else {
                return .occupied(entry.identity)
            }
            try GroupedCopyAdmission.requireResidentRegular(parent: parent, name: literal, expected: entry.identity)
            let tree = try verifiedTree(parent: parent.fd, name: literal, cancellation: cancellation)
            let nodes = try snapshotTree(parent: parent.fd, name: literal, cancellation: cancellation)
            guard nodes.count == 1, tree.identity == entry.identity,
                  try NativeRenameEntry.observe(parent: parent, name: literal).nameBytes == name else { return .unavailable(.changed) }
            try parent.validate()
            return .verified(tree, identityDigest: stagingIdentityDigest(nodes))
        } catch is CancellationError { throw CancellationError() }
        catch { return .unavailable(reason(error)) }
    }

    private static func observeArea(_ url: URL, expected: EntrySnapshot?, parent: DirectoryAnchor?, limit: Int,
                                    cancellation: OperationCancellation) throws -> GroupedCopyObservedArea {
        try cancellation.check()
        guard let parent else { return .unavailable(.unavailable) }
        do {
            guard let entry = try NativeRenameEntry.optional(parent: parent, name: url.lastPathComponent) else { return .absent }
            guard entry.nameBytes == Data(url.lastPathComponent.utf8), entry.identity.type == S_IFDIR,
                  let expected, entry.identity.sameObject(as: expected) else { return .unavailable(.changed) }
            let area = try DirectoryAnchor(url, resolve: false)
            guard area.identity.sameObject(as: expected) else { return .unavailable(.changed) }
            let names = try children(in: area, cancellation: cancellation, limit: limit + 1)
            guard names.count <= limit else { return .unavailable(.invalidInventory) }
            let bytes = try names.map { name -> Data in
                let child = try NativeRenameEntry.observe(parent: area, name: name)
                guard child.nameBytes == Data(name.utf8) else { throw FileOperationFailure.recoveryUncertain }
                return child.nameBytes
            }
            try area.validate(); try parent.validate()
            return .present(area.identity, children: bytes)
        } catch is CancellationError { throw CancellationError() }
        catch { return .unavailable(reason(error)) }
    }

    private static func reason(_ error: Error) -> GroupedCopyObservationFailure {
        switch error {
        case FileOperationFailure.sourceChanged, FileOperationFailure.destinationChanged: .changed
        case FileOperationFailure.accessDenied: .denied
        case FileOperationFailure.unsupported: .unsupported
        case FileOperationFailure.recoveryUncertain: .invalidInventory
        default: .unavailable
        }
    }
}
