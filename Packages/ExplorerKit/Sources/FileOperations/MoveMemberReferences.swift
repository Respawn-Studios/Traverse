import Darwin
import ExplorerCore
import Foundation

/// Root-relative identity chain; names select entries, identities prove them.
/// At most one bounded chain is open at a time. No listing or body read.
internal struct MoveReferenceChain: Codable, Equatable, Sendable {
    let root: URL
    let rootParent: EntrySnapshot
    let components: [String]
    let ancestors: [EntrySnapshot] // root, then each intermediate directory
    var location: URL { components.reduce(root) { $0.appendingPathComponent($1) } }

    func validateFormat() throws {
        guard root.hasStandardizedFilePath, root.path.hasPrefix("/"),
              root.path.utf8.count <= 8_192, !root.path.utf8.contains(0), rootParent.isDirectory,
              (1..<OperationLimits.maximumDepth).contains(components.count), ancestors.count == components.count,
              ancestors.allSatisfy({ $0.isDirectory && $0.device == rootParent.device }) else {
            throw FileOperationFailure.invalidRequest
        }
        for name in components { try validateName(name) }
        guard location.path.utf8.count <= 8_192 else { throw FileOperationFailure.unsupported }
    }
    func validate(object: EntrySnapshot) throws {
        try validateFormat()
        let fresh = try Self.observe(root: root, rootParent: rootParent, components: components)
        guard fresh.object.sameObject(as: object), zip(fresh.ancestors, ancestors).allSatisfy({ $0.sameObject(as: $1) }) else {
            throw FileOperationFailure.sourceChanged
        }
    }
    static func observe(root: URL, rootParent: EntrySnapshot, components: [String]) throws -> (object: EntrySnapshot, ancestors: [EntrySnapshot]) {
        guard (1..<OperationLimits.maximumDepth).contains(components.count) else { throw FileOperationFailure.unsupported }
        let parent = try DirectoryAnchor(root.deletingLastPathComponent(), resolve: false)
        guard parent.identity.sameObject(as: rootParent) else { throw FileOperationFailure.sourceChanged }
        let anchor = try DirectoryAnchor(root, resolve: false)
        var descriptors = [anchor.fd], ancestors = [anchor.identity]
        defer { for fd in descriptors.dropFirst() { close(fd) } }
        for name in components.dropLast() {
            try validateName(name)
            let fd = openat(descriptors.last!, name, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }
            descriptors.append(fd); ancestors.append(try EntrySnapshot(fd: fd))
        }
        let name = components.last!; try validateName(name)
        let object = try EntrySnapshot(parent: descriptors.last!, name: name)
        var info = stat()
        guard [S_IFREG, S_IFDIR].contains(object.type), object.device == anchor.identity.device,
              ancestors.allSatisfy({ $0.device == anchor.identity.device }),
              fstatat(descriptors.last!, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1 else { throw FileOperationFailure.unsupported }
        // Detect replacement of any intermediate entry while descriptors were open.
        for index in 1..<descriptors.count {
            guard try EntrySnapshot(parent: descriptors[index - 1], name: components[index - 1])
                .sameObject(as: ancestors[index]) else { throw FileOperationFailure.sourceChanged }
        }
        try anchor.validate(); try parent.validate()
        return (object, ancestors)
    }
}

/// Canonical sparse witness, created only from existing verified observations.
/// Decoding is not authority: passive history and live identity checks are required.
public struct MoveReferenceReceipt: Codable, Equatable, Sendable {
    private let version: Int
    public let ticket: MoveReferenceTicket
    internal let destination: EntrySnapshot
    internal let ancestors: [EntrySnapshot]
    internal init(ticket: MoveReferenceTicket, destination: EntrySnapshot, ancestors: [EntrySnapshot]) {
        version = 1; self.ticket = ticket; self.destination = destination; self.ancestors = ancestors
    }
    public func encoded() throws -> Data {
        _ = try ticket.encoded()
        guard version == 1, let member = ticket.member, ancestors.count == member.components.count,
              ancestors.allSatisfy({ $0.isDirectory && $0.device == ticket.destinationParent.device }),
              destination.type == ticket.sourceIdentity.type, destination.device == ticket.destinationParent.device else {
            throw FileOperationFailure.invalidRequest
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 65_536 else { throw FileOperationFailure.unsupported }; return data
    }
    public init(encoded: Data) throws {
        guard encoded.count <= 65_536 else { throw FileOperationFailure.invalidRequest }
        self = try JSONDecoder().decode(Self.self, from: encoded)
        guard try self.encoded() == encoded else { throw FileOperationFailure.invalidRequest }
    }
}

public struct MoveReferenceAdmission: Sendable {
    public let plan: TransferPlan
    public let tickets: [MoveReferenceTicket]
    /// Some supplied locations were unsupported, changed or outside eligible units.
    public let omitted: Int
}

extension RecoverableFileOperations {
    internal static func memberEvidence(_ ticket: MoveReferenceTicket, rootProof: MoveReferenceEvidence,
                                       receipt: MoveReferenceReceipt?) throws -> MoveReferenceEvidence {
        guard let member = ticket.member else {
            guard receipt == nil else { throw FileOperationFailure.invalidRequest }; return rootProof
        }
        guard let receipt, receipt.ticket == ticket else { throw FileOperationFailure.recoveryUncertain }
        _ = try receipt.encoded()
        let parents = rootProof.direction == .forward ? receipt.ancestors : member.ancestors
        guard parents[0].sameObject(as: rootProof.object) else { throw FileOperationFailure.sourceChanged }
        let chain = MoveReferenceChain(root: rootProof.location, rootParent: rootProof.parent,
            components: member.components, ancestors: parents)
        return MoveReferenceEvidence(ticket: ticket, direction: rootProof.direction, location: chain.location,
            object: rootProof.direction == .forward ? receipt.destination : ticket.sourceIdentity,
            parent: parents.last!, chain: chain)
    }

    /// Explicit sparse admission: no catalog crawl or extra operated-tree scan.
    /// Execute the returned plan, not the input plan, to retain copied-member proofs.
    public func observingMoveReferences(_ plan: TransferPlan, candidates: [URL],
        resolutions: [UUID: TransferConflictResolution] = [:]) async throws -> MoveReferenceAdmission {
        try await worker { cancellation in
            guard plan.isMove, let reservation = plan.moveReservation, reservation.owner == self.continuationSession,
                  candidates.count <= 2_048, plan.referenceMembers.isEmpty else { throw FileOperationFailure.invalidRequest }
            func units(_ entry: TransferEntry) -> [TransferEntry] {
                if entry.destinationIdentity != nil {
                    switch resolutions[entry.id] {
                    case .skip, nil: return []
                    case .merge: return (entry.children ?? []).flatMap(units)
                    case .replace, .keepBoth: break
                    }
                }
                return [entry]
            }
            let entries = plan.entries.flatMap(units)
            let bySource = Dictionary(uniqueKeysWithValues: entries.map { ($0.source.path, $0) })
            var tickets: [MoveReferenceTicket] = [], unique = Set<String>(), bytes = 0
            for candidate in candidates {
                try cancellation.check()
                guard candidate.hasStandardizedFilePath,
                      unique.insert(candidate.path).inserted else { continue }
                var current = candidate, selected: TransferEntry?
                for _ in 0...OperationLimits.maximumDepth {
                    if let entry = bySource[current.path] { selected = entry; break }
                    let parent = current.deletingLastPathComponent(); if parent == current { break }; current = parent
                }
                guard let entry = selected,
                      [S_IFREG, S_IFDIR].contains(entry.sourceIdentity.type) else { continue }
                let root = MoveReferenceTicket(entry, plan: plan, history: self.directory, reservation: reservation)
                do {
                    let ticket: MoveReferenceTicket
                    if candidate == entry.source {
                        ticket = MoveReferenceTicket(root: root, member: nil, source: root.source,
                            identity: root.sourceIdentity, parent: root.sourceParent, inputCount: entries.count)
                    } else {
                        let components = String(candidate.path.dropFirst(entry.source.path.count + 1)).split(separator: "/").map(String.init)
                        let observation = try MoveReferenceChain.observe(root: entry.source, rootParent: entry.sourceParent, components: components)
                        guard observation.ancestors[0].sameObject(as: entry.sourceIdentity) else { continue }
                        let chain = MoveReferenceChain(root: entry.source, rootParent: entry.sourceParent,
                            components: components, ancestors: observation.ancestors)
                        ticket = MoveReferenceTicket(root: root, member: chain, source: candidate,
                            identity: observation.object, parent: observation.ancestors.last!, inputCount: entries.count)
                    }
                    let size = try ticket.encoded().count
                    guard bytes + size <= 4_194_304 else { continue }
                    bytes += size; tickets.append(ticket)
                } catch is CancellationError { throw CancellationError() }
                catch { continue } // A private-name gap never fails the transfer.
            }
            var returned = plan; returned.referenceMembers = tickets.filter(\.isMember)
            return MoveReferenceAdmission(plan: returned, tickets: tickets, omitted: candidates.count - tickets.count)
        }
    }

    /// Projection from the existing validation seam, before public publication.
    internal static func memberReceipts(_ tickets: [MoveReferenceTicket], entry: TransferEntry,
        source: CopyComparison? = nil, destination: CopyComparison? = nil) -> [MoveReferenceReceipt] {
        tickets.compactMap { ticket in
            guard let member = ticket.member, member.root == entry.source,
                  member.ancestors[0].sameObject(as: entry.sourceIdentity) else { return nil }
            do {
                let copied: EntrySnapshot, parents: [EntrySnapshot]
                if let source, let destination {
                    let key = member.components.joined(separator: "/")
                    guard source.nodes[key]?.identity.sameObject(as: ticket.sourceIdentity) == true,
                          let observed = destination.nodes[key] else { return nil }
                    var captured: [EntrySnapshot] = []
                    for index in member.ancestors.indices {
                        let key = member.components.prefix(index).joined(separator: "/")
                        guard source.nodes[key]?.identity.sameObject(as: member.ancestors[index]) == true,
                              let parent = destination.nodes[key]?.identity else { return nil }
                        captured.append(parent)
                    }
                    copied = observed.identity; parents = captured
                } else {
                    try member.validate(object: ticket.sourceIdentity)
                    copied = ticket.sourceIdentity; parents = member.ancestors
                }
                let receipt = MoveReferenceReceipt(ticket: ticket, destination: copied, ancestors: parents)
                _ = try receipt.encoded(); return receipt
            } catch { return nil }
        }
    }
}
