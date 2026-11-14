import Darwin
import Foundation

/// A device number is meaningful only during one mount. The UUID is read from
/// an already held APFS directory, so journal comparisons can identify its
/// volume after a later mount without changing live descriptor guards.
internal struct PersistentVolumeBinding: Codable, Equatable, Sendable {
    let device: dev_t
    let uuid: Data

    static func qualified(in parent: DirectoryAnchor) throws -> Self? {
        try parent.validate()
        var filesystem = statfs()
        guard fstatfs(parent.fd, &filesystem) == 0 else { throw posixFailure() }
        let kind = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard kind == "apfs", filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var bytes = Data(count: 64)
        let result = bytes.withUnsafeMutableBytes { raw in
            fgetattrlist(parent.fd, &attributes, raw.baseAddress!, raw.count, 0)
        }
        guard result == 0 else { throw FileOperationFailure.unsupported }
        func word(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard word(0) == 40, word(4) == UInt32(ATTR_CMN_RETURNED_ATTRS),
              word(8) == UInt32(ATTR_VOL_UUID), word(12) == 0,
              word(16) == 0, word(20) == 0 else { throw FileOperationFailure.unsupported }
        let binding = Self(device: parent.identity.device, uuid: bytes.subdata(in: 24..<40))
        try binding.validateRepresentation()
        try parent.validate()
        return binding
    }

    func validateRepresentation() throws {
        guard device != 0, uuid.count == 16, uuid.contains(where: { $0 != 0 }) else {
            throw FileOperationFailure.recoveryUncertain
        }
    }

    var uuidValue: UUID {
        let bytes = [UInt8](uuid)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

}

/// A record keeps raw device values and their independently observed APFS
/// volume UUIDs. Missing bindings preserve the older exact-device refusal.
internal struct PersistentVolumeBindings: Codable, Equatable, Sendable {
    private(set) var entries: [PersistentVolumeBinding] = []
    static let maximumEntries = OperationJournal.maximumInputs

    func binding(for device: dev_t) -> PersistentVolumeBinding? {
        entries.first { $0.device == device }
    }
    func contains(device: dev_t) -> Bool { binding(for: device) != nil }

    mutating func insert(_ binding: PersistentVolumeBinding?) throws {
        guard let binding else { return }
        try binding.validateRepresentation()
        if let existing = entries.first(where: { $0.device == binding.device }) {
            guard existing.uuid == binding.uuid else { throw FileOperationFailure.sourceChanged }
            return
        }
        guard entries.count < Self.maximumEntries else { throw FileOperationFailure.unsupported }
        entries.append(binding)
        entries.sort { $0.device < $1.device }
    }

    func validateRepresentation() throws {
        guard entries.count <= Self.maximumEntries else { throw FileOperationFailure.recoveryUncertain }
        for (index, entry) in entries.enumerated() {
            try entry.validateRepresentation()
            if index > 0, entries[index - 1].device >= entry.device {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }

    func matches(_ stored: EntrySnapshot, _ current: EntrySnapshot,
                 currentVolume: PersistentVolumeBinding?) -> Bool {
        guard stored.inode == current.inode, stored.type == current.type,
              stored.birthSeconds == current.birthSeconds,
              stored.birthNanos == current.birthNanos else { return false }
        guard let bound = binding(for: stored.device) else {
            return stored.device == current.device
        }
        return currentVolume?.device == current.device && currentVolume?.uuid == bound.uuid
    }

    func matchesRecorded(_ first: EntrySnapshot, _ second: EntrySnapshot) -> Bool {
        guard first.inode == second.inode, first.type == second.type,
              first.birthSeconds == second.birthSeconds,
              first.birthNanos == second.birthNanos else { return false }
        if first.device == second.device { return true }
        guard let firstVolume = binding(for: first.device),
              let secondVolume = binding(for: second.device) else { return false }
        return firstVolume.uuid == secondVolume.uuid
    }

    func matchesEntireSnapshot(_ stored: EntrySnapshot, _ current: EntrySnapshot,
                               currentVolume: PersistentVolumeBinding?) -> Bool {
        matches(stored, current, currentVolume: currentVolume) &&
            stored.mode == current.mode && stored.size == current.size &&
            stored.modifiedSeconds == current.modifiedSeconds && stored.modifiedNanos == current.modifiedNanos &&
            stored.changedSeconds == current.changedSeconds && stored.changedNanos == current.changedNanos
    }
}

internal extension JournalRecord {
    func matchesRecorded(_ first: VerifiedTree, _ second: VerifiedTree) -> Bool {
        guard first.digest == second.digest else { return false }
        if let persistentVolumes {
            return persistentVolumes.matchesRecorded(first.identity, second.identity)
        }
        return first.identity.sameObject(as: second.identity)
    }

    func matchesRecorded(_ first: EntrySnapshot, _ second: EntrySnapshot) -> Bool {
        persistentVolumes?.matchesRecorded(first, second) ?? first.sameObject(as: second)
    }

    func matchesPersisted(_ stored: EntrySnapshot, _ current: EntrySnapshot,
                          in parent: DirectoryAnchor) throws -> Bool {
        guard let persistentVolumes else { return stored.sameObject(as: current) }
        let currentVolume = persistentVolumes.contains(device: stored.device)
            ? try PersistentVolumeBinding.qualified(in: parent) : nil
        return persistentVolumes.matches(stored, current, currentVolume: currentVolume)
    }

    func matchesPersisted(_ stored: VerifiedTree, _ current: VerifiedTree,
                          in parent: DirectoryAnchor) throws -> Bool {
        guard stored.digest == current.digest else { return false }
        return try matchesPersisted(stored.identity, current.identity, in: parent)
    }
}
