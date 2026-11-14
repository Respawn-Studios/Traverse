import CryptoKit
import Foundation

// Catalog9/textRevisionV3. Values describe recorded evidence; none is an access grant.
internal struct TextRevisionManifestV2: Codable, Equatable, Sendable {
    let version: Int
    let owner: UUID, id: UUID, generation: UUID
    let createdAt: Date
    let target: URL, parent: EntrySnapshot
    let area: URL, areaIdentity: EntrySnapshot
    let slot: RevisionDigest, base: TextRevisionHeadV2
    let read: RevisionWitness
    let baseline: TextRevisionBaselineV3?
    /// Present only in new records whose slot and witnesses are bound to the
    /// volume UUID observed through the held APFS directory descriptor.
    let persistentVolume: Data?
    var predecessor: UUID? { base.job }
    var persistentUUID: UUID? {
        guard let persistentVolume, persistentVolume.count == 16 else { return nil }
        return PersistentVolumeBinding(device: parent.device, uuid: persistentVolume).uuidValue
    }
    func matchesRecorded(_ first: RevisionWitness, _ second: RevisionWitness) -> Bool {
        guard version == 4, let uuid = persistentUUID else { return first == second }
        return first.samePersistentObservation(second, qualifiedVolume: uuid)
    }
    func matchesPersisted(_ stored: RevisionWitness, file: TextPinnedFileV2) -> Bool {
        guard version == 4, let persistentVolume else { return stored == file.witness }
        return file.volumeBinding.uuid == persistentVolume &&
            stored.samePersistentObservation(file.witness, qualifiedVolume: file.volume)
    }
    func matchesPersisted(_ stored: EntrySnapshot, current: EntrySnapshot, in directory: DirectoryAnchor) throws -> Bool {
        guard version == 4, let persistentVolume else { return stored.sameObject(as: current) }
        guard let binding = try PersistentVolumeBinding.qualified(in: directory),
              binding.uuid == persistentVolume else { return false }
        return binding.device == current.device && stored.inode == current.inode && stored.type == current.type &&
            stored.birthSeconds == current.birthSeconds && stored.birthNanos == current.birthNanos
    }
    func validate() throws {
        do {
            guard (version == 3 && persistentVolume == nil) ||
                    (version == 4 && persistentVolume?.count == 16 && persistentVolume?.contains(where: { $0 != 0 }) == true) else {
                throw FileOperationFailure.recoveryUncertain
            }
            guard target.isFileURL, area.isFileURL,
                  target == target.standardizedFileURL, area == area.standardizedFileURL,
                  target.deletingLastPathComponent() == area.deletingLastPathComponent(),
                  area.lastPathComponent == ".traverse-text-" + id.uuidString else {
                throw FileOperationFailure.recoveryUncertain
            }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textManifestLocation, error)
            throw error
        }
        do {
            guard parent.type == 0o040000, areaIdentity.type == 0o040000,
                  parent.device == areaIdentity.device else { throw FileOperationFailure.recoveryUncertain }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textManifestArea, error)
            throw error
        }
        do {
            guard base.slot == slot, matchesRecorded(base.witness, read),
                  base.job != id, base.sequence >= 0 else { throw FileOperationFailure.recoveryUncertain }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textManifestBinding, error)
            throw error
        }
        do {
            let expected = try version == 4
                ? textRevisionSlotV4(target: target, parent: parent, volume: persistentUUID!)
                : textRevisionSlotV2(target: target, parent: parent)
            guard slot == expected, version != 4 || (read.volume == persistentUUID && read.device == parent.device) else {
                throw FileOperationFailure.recoveryUncertain
            }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textManifestSlot, error)
            throw error
        }
        do { try read.validate() }
        catch {
            FileOperationDiagnostics.caughtFailure(.textManifestRead, error)
            throw error
        }
        do {
            if let baseline {
                try baseline.validate()
                guard baseline.after == base else { throw FileOperationFailure.recoveryUncertain }
            }
        } catch {
            FileOperationDiagnostics.caughtFailure(.textManifestBaseline, error)
            throw error
        }
    }
}

internal struct TextRevisionHeadV2: Codable, Equatable, Sendable {
    let slot: RevisionDigest, lineage: UUID
    let sequence: Int, job: UUID?
    let witness: RevisionWitness
}
internal struct TextRevisionBaselineV3: Codable, Equatable, Sendable {
    let before: TextRevisionHeadV2, after: TextRevisionHeadV2
    func validate() throws {
        try before.witness.validate(); try after.witness.validate()
        guard before.slot == after.slot, (0..<128).contains(before.sequence), after.sequence == before.sequence + 1,
              before.lineage != after.lineage, after.job == nil, before.witness != after.witness else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}
internal struct TextPreparationSettlementV3: Equatable, Sendable {
    let id: UUID, prefix: RevisionDigest
}
internal enum TextRevisionHeadEdgeV3: Codable, Equatable, Sendable {
    case native(TextRevisionTransitionV2)
    case baseline(job: UUID, prefix: RevisionDigest, change: TextRevisionBaselineV3)
    var before: TextRevisionHeadV2 { switch self { case .native(let edge): edge.before; case .baseline(_, _, let change): change.before } }
    var after: TextRevisionHeadV2 { switch self { case .native(let edge): edge.after; case .baseline(_, _, let change): change.after } }
    var job: UUID { switch self { case .native(let edge): edge.job; case .baseline(let job, _, _): job } }
    var slot: RevisionDigest { before.slot }
    var ordinal: Int { before.sequence }
    func validate(record: TextRevisionRecordV2) throws {
        switch self {
        case .native(let edge): try edge.validate(record: record)
        case .baseline(let job, let prefix, let change):
            try change.validate()
            guard job == record.id, record.manifest.baseline == change,
                  prefix == (try record.prefix(at: 1)) else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}
internal struct TextRevisionPreparationV2: Codable, Equatable, Sendable {
    let id: UUID, direction: RevisionDirection
    let read: RevisionWitness, restoring: RevisionWitness
    func directory(in record: TextRevisionRecordV2) -> URL {
        record.manifest.area.appendingPathComponent(direction.rawValue + "-" + id.uuidString)
    }
}
internal struct TextRevisionReadyV2: Codable, Equatable, Sendable {
    let attemptID: UUID, identity: EntrySnapshot
}
internal struct TextRevisionAttemptV2: Sendable {
    let preparation: TextRevisionPreparationV2
    var ready: TextRevisionReadyV2?
    var custody: TextRevisionCustodyV2?
    var intent: TextRevisionIntentV2?
    var applied: TextRevisionAppliedV2?
    var aborted = false
}
internal struct TextRevisionCustodyV2: Codable, Equatable, Sendable {
    let attemptID: UUID
    let direction: RevisionDirection
    let before: RevisionCopySeal
    let submitted: RevisionStagedEdit
    func validate() throws {
        try before.validate(); try submitted.validate()
        guard !before.copy.sameObject(submitted.edited),
              !before.source.sameObject(submitted.edited) else { throw FileOperationFailure.recoveryUncertain }
    }
}
internal struct TextRevisionIntentV2: Codable, Equatable, Sendable {
    let direction: RevisionDirection
    let read: RevisionWitness
    let candidate: RevisionCopySeal
    func validate(custody: TextRevisionCustodyV2) throws {
        try candidate.validate(); try custody.validate()
        guard direction == custody.direction, read == custody.before.source,
              candidate.source == custody.submitted.edited,
              !candidate.copy.sameObject(custody.before.copy),
              !candidate.copy.sameObject(read) else { throw FileOperationFailure.recoveryUncertain }
    }
}
internal struct TextRevisionAppliedV2: Codable, Equatable, Sendable {
    let output: RevisionWitness, originalPinnedAfter: RevisionWitness
    let candidatePinnedAfter: RevisionWitness
    let beforeAfter: RevisionWitness, submittedAfter: RevisionWitness
    func validate(intent: TextRevisionIntentV2, custody: TextRevisionCustodyV2) throws {
        try intent.validate(custody: custody)
        try output.validate(); try originalPinnedAfter.validate(); try candidatePinnedAfter.validate()
        guard originalPinnedAfter.links == 0, originalPinnedAfter.sameObject(intent.read),
              originalPinnedAfter.body == intent.read.body, originalPinnedAfter.bytes == intent.read.bytes,
              output.links == 1, output == candidatePinnedAfter,
              output.sameObject(intent.candidate.copy), output.body == custody.submitted.edited.body,
              output.bytes == custody.submitted.edited.bytes,
              output.modified == intent.candidate.copy.modified,
              output.metadata == intent.candidate.copy.metadata,
              output.security == intent.candidate.copy.security,
              output.document == intent.read.document, output.flags == intent.read.flags,
              beforeAfter == custody.before.copy, submittedAfter == custody.submitted.edited else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}

internal enum TextRevisionEventV2: Codable, Equatable, Sendable {
    case preparation(TextRevisionPreparationV2)
    case ready(TextRevisionReadyV2)
    case custody(TextRevisionCustodyV2)
    case intent(TextRevisionIntentV2)
    case applied(TextRevisionAppliedV2)
    case stoppedBeforeEntry
    case uncertain
    case retirementIntent(TextRetirementIntentV3)
    case retirementIntentRootMetadataV4(TextRetirementIntentV3)
    case retirementIntentNativeDirectoryV5(TextRetirementIntentV3)
    case retirementReturned(URL)
    case retirementConfirmed(VerifiedTree)
    case retirementConfirmedRootMetadataV4(TextRetirementConfirmationV4)
    case retirementConfirmedNativeDirectoryV5(TextRetirementConfirmationV5)
}
public enum LocalTextRevisionState: String, Sendable, Codable {
    case preparing, prepared, nativePending, committed, undoPrepared, undoPending, undone, notApplied, uncertain
}
internal struct TextRevisionProjectionV2: Sendable {
    var state: LocalTextRevisionState = .preparing
    var custody: TextRevisionCustodyV2?
    var intent: TextRevisionIntentV2?
    var forward: TextRevisionAppliedV2?
    var inverse: TextRevisionAppliedV2?
    var inverseAttempted = false
    var attempts: [TextRevisionAttemptV2] = []
    var retirement: TextRetirementIntentV3?
    var retirementRootMetadataV4 = false
    var retirementNativeDirectoryV5 = false
    var retirementTarget: URL?
    var retirementConfirmed = false
    var canPrepareInverse: Bool {
        state == .committed && !inverseAttempted && retirement == nil && attempts.count < TextRevisionRecordV2.maximumAttempts
    }
}
internal struct TextRevisionRecordV2: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumAttempts = 4, maximumEvents = 32, maximumEventBytes = 16_384, maximumBytes = 262_144
    let manifest: TextRevisionManifestV2
    let events: [TextRevisionEventV2]
    var revision: Int { events.count + 1 }
    var id: UUID { manifest.id }
    var description: String { "Text revision (private evidence omitted)" }
    var debugDescription: String { description }
    var prefix: RevisionDigest { get throws { .bytes(try textEncoded(self)) } }
    func prefix(at revision: Int) throws -> RevisionDigest {
        guard revision >= 1, revision <= self.revision else { throw FileOperationFailure.recoveryUncertain }
        return try TextRevisionRecordV2(manifest: manifest, events: Array(events.prefix(revision - 1))).prefix
    }
    func appending(_ event: TextRevisionEventV2) throws -> Self {
        let value = Self(manifest: manifest, events: events + [event]); _ = try value.project(); return value
    }
    func project() throws -> TextRevisionProjectionV2 {
        try manifest.validate()
        guard events.count <= Self.maximumEvents, try textEncoded(self).count <= Self.maximumBytes else { throw FileOperationFailure.unsupported }
        var result = TextRevisionProjectionV2()
        for event in events {
            guard try textEncoded(event).count <= Self.maximumEventBytes else { throw FileOperationFailure.unsupported }
            if result.retirement != nil {
                switch event { case .retirementReturned, .retirementConfirmed,
                    .retirementConfirmedRootMetadataV4, .retirementConfirmedNativeDirectoryV5: break
                default: throw FileOperationFailure.recoveryUncertain }
            }
            switch event {
            case .preparation(let preparation):
                guard result.retirement == nil else { throw FileOperationFailure.recoveryUncertain }
                try preparation.read.validate(); try preparation.restoring.validate()
                guard result.attempts.count < Self.maximumAttempts,
                      !result.attempts.contains(where: { $0.preparation.id == preparation.id }),
                      result.attempts.last.map({ $0.aborted || $0.applied != nil }) ?? true else {
                    throw FileOperationFailure.recoveryUncertain
                }
                if preparation.direction == .forward {
                    guard result.state == .preparing, result.attempts.isEmpty,
                          preparation.read == manifest.read, preparation.restoring == manifest.read else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                } else {
                    guard result.canPrepareInverse, let original = result.attempts.first?.custody,
                          manifest.matchesRecorded(preparation.restoring, original.before.copy) else { throw FileOperationFailure.recoveryUncertain }
                    result.state = .undoPrepared
                }
                if manifest.version == 4 {
                    guard preparation.read.volume == manifest.persistentUUID,
                          preparation.restoring.volume == manifest.persistentUUID else { throw FileOperationFailure.recoveryUncertain }
                }
                result.attempts.append(TextRevisionAttemptV2(preparation: preparation))
                result.custody = nil; result.intent = nil
            case .ready(let ready):
                guard let attempt = result.attempts.last, attempt.preparation.id == ready.attemptID,
                      attempt.ready == nil, !attempt.aborted, attempt.custody == nil,
                      ready.identity.type == 0o040000,
                      (manifest.version == 4
                        ? UInt64(UInt32(bitPattern: ready.identity.device)) == attempt.preparation.read.device
                        : ready.identity.device == manifest.areaIdentity.device) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                result.attempts[result.attempts.count - 1].ready = ready
            case .custody(let custody):
                try custody.validate()
                guard let attempt = result.attempts.last, attempt.ready != nil, !attempt.aborted,
                      attempt.custody == nil, custody.attemptID == attempt.preparation.id,
                      custody.direction == attempt.preparation.direction,
                      custody.before.source == attempt.preparation.read,
                      custody.submitted.origin.source == attempt.preparation.restoring else {
                    throw FileOperationFailure.recoveryUncertain
                }
                if custody.direction == .forward {
                    guard custody.direction == .forward, custody.before.source == manifest.read,
                          custody.submitted.origin.source == manifest.read else { throw FileOperationFailure.recoveryUncertain }
                    result.state = .prepared
                } else {
                    guard result.state == .undoPrepared, !result.inverseAttempted, custody.direction == .inverse,
                          let forwardCustody = events.compactMap({ if case .custody(let value) = $0 { value } else { nil } }).first,
                          manifest.matchesRecorded(custody.submitted.origin.source, forwardCustody.before.copy),
                          custody.submitted.edited.body == manifest.read.body,
                          custody.submitted.edited.bytes == manifest.read.bytes else { throw FileOperationFailure.recoveryUncertain }
                    result.state = .undoPrepared
                }
                result.attempts[result.attempts.count - 1].custody = custody
                result.custody = custody; result.intent = nil
            case .intent(let intent):
                guard let custody = result.custody,
                      result.state == .prepared || result.state == .undoPrepared else { throw FileOperationFailure.recoveryUncertain }
                try intent.validate(custody: custody); result.intent = intent
                result.attempts[result.attempts.count - 1].intent = intent
                if intent.direction == .inverse { result.inverseAttempted = true }
                result.state = intent.direction == .forward ? .nativePending : .undoPending
            case .applied(let applied):
                guard let custody = result.custody, let intent = result.intent,
                      result.state == .nativePending || result.state == .undoPending else { throw FileOperationFailure.recoveryUncertain }
                try applied.validate(intent: intent, custody: custody)
                result.attempts[result.attempts.count - 1].applied = applied
                if intent.direction == .forward { result.forward = applied; result.state = .committed }
                else { result.inverse = applied; result.state = .undone }
            case .stoppedBeforeEntry:
                if result.attempts.isEmpty {
                    guard result.state == .preparing else { throw FileOperationFailure.recoveryUncertain }
                    result.state = .notApplied; continue
                }
                guard let attempt = result.attempts.last, attempt.intent == nil, !attempt.aborted,
                      result.state == .preparing || result.state == .prepared || result.state == .undoPrepared else {
                    throw FileOperationFailure.recoveryUncertain
                }
                result.attempts[result.attempts.count - 1].aborted = true
                result.state = attempt.preparation.direction == .inverse ? .committed : .notApplied
            case .uncertain:
                guard result.state == .nativePending || result.state == .undoPending else { throw FileOperationFailure.recoveryUncertain }
                result.state = .uncertain
            case .retirementIntent(let intent), .retirementIntentRootMetadataV4(let intent),
                 .retirementIntentNativeDirectoryV5(let intent):
                guard [.committed, .undone, .notApplied].contains(result.state), result.retirement == nil,
                      intent.before.identity.sameObject(as: manifest.areaIdentity),
                      intent.head == nil || intent.head?.slot == manifest.slot,
                      result.forward == nil || intent.head != nil else { throw FileOperationFailure.recoveryUncertain }
                result.retirement = intent
                if case .retirementIntentRootMetadataV4 = event { result.retirementRootMetadataV4 = true }
                if case .retirementIntentNativeDirectoryV5 = event { result.retirementNativeDirectoryV5 = true }
            case .retirementReturned(let target):
                guard result.retirement != nil, result.retirementTarget == nil, !result.retirementConfirmed,
                      target.isFileURL, target == target.standardizedFileURL, target != manifest.area else { throw FileOperationFailure.recoveryUncertain }
                result.retirementTarget = target
            case .retirementConfirmed(let after):
                guard let intent = result.retirement, result.retirementTarget != nil,
                      !result.retirementRootMetadataV4, !result.retirementNativeDirectoryV5,
                      !result.retirementConfirmed,
                      intent.before.matchesNativeTrashTransition(after) else { throw FileOperationFailure.recoveryUncertain }
                result.retirementConfirmed = true
            case .retirementConfirmedRootMetadataV4(let confirmation):
                guard let intent = result.retirement, let target = result.retirementTarget,
                      result.retirementRootMetadataV4, !result.retirementConfirmed,
                      confirmation.returned.baseURL == nil,
                      confirmation.returned.absoluteString.utf8.elementsEqual(target.absoluteString.utf8),
                      intent.before.identity.sameObject(as: confirmation.after.identity),
                      confirmation.rootMetadata.map({ $0.validates(before: intent.before, after: confirmation.after) })
                        ?? intent.before.matchesNativeTrashTransition(confirmation.after) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                result.retirementConfirmed = true
            case .retirementConfirmedNativeDirectoryV5(let confirmation):
                guard let intent = result.retirement, let target = result.retirementTarget,
                      result.retirementNativeDirectoryV5, !result.retirementRootMetadataV4,
                      !result.retirementConfirmed,
                      confirmation.validates(before: intent.before, target: target) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                result.retirementConfirmed = true
            }
        }
        return result
    }
}

internal struct TextRevisionTransitionV2: Codable, Equatable, Sendable {
    let slot: RevisionDigest, ordinal: Int, job: UUID, recordRevision: Int, prefix: RevisionDigest
    let direction: RevisionDirection
    let before: TextRevisionHeadV2, after: TextRevisionHeadV2
    func validate(record: TextRevisionRecordV2) throws {
        guard recordRevision >= 1, recordRevision <= record.revision else { throw FileOperationFailure.recoveryUncertain }
        let prefixRecord = TextRevisionRecordV2(manifest: record.manifest, events: Array(record.events.prefix(recordRevision - 1)))
        let state = try prefixRecord.project()
        guard (0..<128).contains(ordinal), ordinal == before.sequence, after.sequence == ordinal + 1,
              slot == before.slot, slot == after.slot, slot == record.manifest.slot, record.id == job,
              prefix == (try record.prefix(at: recordRevision)),
              before.lineage == after.lineage, before.lineage == record.manifest.base.lineage else { throw FileOperationFailure.recoveryUncertain }
        if direction == .forward {
            guard state.state == .committed, before == record.manifest.base,
                  after.job == job, after.witness == state.forward?.output else { throw FileOperationFailure.recoveryUncertain }
        } else {
            guard state.state == .undone, before.job == job, after.job == record.manifest.predecessor,
                  state.intent.map({ record.manifest.matchesRecorded($0.read, before.witness) }) == true,
                  after.witness == state.inverse?.output else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}

internal struct TextRecoveryExportV2: Codable, Equatable, Sendable {
    let id: UUID, job: UUID, ordinal: Int
    let attemptID: UUID, direction: RevisionDirection
    let destination: URL, parent: EntrySnapshot
    let names: [String], sources: [URL], expected: [RevisionWitness]
    let completed: [RevisionWitness]
    let states: [LocalTextRecoveryCopyState]
    func validate() throws {
        guard (0..<10_000).contains(ordinal), names.count == 2, sources.count == 2, expected.count == 2,
              names[0] != names[1], completed.count <= 2, states.count == 2, destination.isFileURL,
              destination == destination.standardizedFileURL else { throw FileOperationFailure.recoveryUncertain }
        let verified = states.prefix(while: { $0 == .verified }).count
        guard completed.count == verified,
              states.dropFirst(verified).first.map({ $0 == .notAttempted || $0 == .publicationUnconfirmed }) ?? true,
              states.dropFirst(verified + 1).allSatisfy({ $0 == .notAttempted }) else { throw FileOperationFailure.recoveryUncertain }
        for name in names { try validateName(name) }
        for witness in expected + completed { try witness.validate() }
        for (original, copy) in zip(expected, completed) {
            guard copy.links == 1, !copy.sameObject(original), copy.body == original.body,
                  copy.bytes == original.bytes, copy.metadata == original.metadata,
                  copy.modified == original.modified, copy.flags == original.flags else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}

internal func textEncoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
}
internal func textDecoded<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
    let value = try JSONDecoder().decode(type, from: bytes)
    guard try textEncoded(value) == bytes else { throw FileOperationFailure.recoveryUncertain }; return value
}

internal func textRevisionSlotV2(target: URL, parent: EntrySnapshot) throws -> RevisionDigest {
    struct Slot: Encodable { let name: String, device: Int64, inode: UInt64, birthSeconds: Int, birthNanos: Int }
    let name = target.lastPathComponent.precomposedStringWithCanonicalMapping
        .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    return .bytes(try textEncoded(Slot(name: name, device: Int64(parent.device), inode: parent.inode,
        birthSeconds: parent.birthSeconds, birthNanos: parent.birthNanos)))
}

/// A new namespace keeps post-remount heads addressable. The version marker
/// prevents an older device-number slot from silently becoming this lineage.
internal func textRevisionSlotV4(target: URL, parent: EntrySnapshot, volume: UUID) throws -> RevisionDigest {
    struct Slot: Encodable {
        let version: Int, name: String, volume: UUID
        let inode: UInt64, birthSeconds: Int, birthNanos: Int
    }
    let name = target.lastPathComponent.precomposedStringWithCanonicalMapping
        .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    return .bytes(try textEncoded(Slot(version: 4, name: name, volume: volume,
        inode: parent.inode, birthSeconds: parent.birthSeconds, birthNanos: parent.birthNanos)))
}

internal struct TextSlotSelectionV4: Sendable {
    let slot: RevisionDigest
    /// Three retains the exact live device-number lineage; four is a new
    /// descriptor-bound persistent-volume lineage.
    let manifestVersion: Int
}
