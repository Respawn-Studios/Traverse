import Foundation

/// Exact, bounded native facts retained before one image-only APFS erase. The
/// application separately binds the backing image and its attachment.
public struct APFSVolumeFormatSnapshot: Codable, Equatable, Sendable {
    public struct Store: Codable, Equatable, Sendable {
        public let device: String
        public let uuid: UUID
        public let capacity: UInt64
    }
    public struct Member: Codable, Equatable, Sendable {
        public let device: String
        public let uuid: UUID
        public let name: String
        public let quota: UInt64
        public let reserve: UInt64
    }
    public let targetID: UUID
    public let targetDevice: String
    public let containerID: UUID
    public let containerDevice: String
    public let capacity: UInt64
    public let name: String
    public let caseSensitive: Bool
    public let stores: [Store]
    public let members: [Member]

    init(_ observed: APFSObservedVolume) {
        targetID = observed.info.uuid
        targetDevice = observed.info.device
        containerID = observed.container.uuid
        containerDevice = observed.container.device
        capacity = observed.container.capacity
        name = observed.info.name
        caseSensitive = observed.info.caseSensitive
        stores = observed.container.stores.map { .init(device: $0.device, uuid: $0.uuid, capacity: $0.capacity) }
        members = observed.container.volumes.map {
            .init(device: $0.device, uuid: $0.uuid, name: $0.name, quota: $0.quota, reserve: $0.reserve)
        }
    }

    public func validate() -> Bool {
        guard APFSContainerObservation.validContainer(containerDevice),
              APFSContainerObservation.validDevice(targetDevice),
              (try? APFSVolumeCreation.validatedName(name)) == name,
              capacity > 0, stores.count == 1, (1..<128).contains(members.count),
              stores.allSatisfy({ APFSContainerObservation.validDevice($0.device) && $0.capacity > 0 }),
              members.allSatisfy({ APFSContainerObservation.validDevice($0.device)
                  && (try? APFSVolumeCreation.validatedName($0.name)) == $0.name }),
              Set(members.map(\.uuid)).count == members.count,
              Set(members.map(\.device)).count == members.count,
              members.filter({ $0.uuid == targetID && $0.device == targetDevice && $0.name == name
                  && $0.quota == 0 && $0.reserve == 0 }).count == 1 else { return false }
        return true
    }

    func originalContainer() -> APFSContainerObservation {
        .init(device: containerDevice, uuid: containerID, selectedUUID: targetID,
              capacity: capacity, free: 0,
              stores: stores.map { .init(device: $0.device, uuid: $0.uuid, capacity: $0.capacity) },
              volumes: members.map { .init(device: $0.device, uuid: $0.uuid, name: $0.name,
                                           quota: $0.quota, reserve: $0.reserve) })
    }
}

/// This is deliberately a generated fixture identity, not authorization to
/// erase an arbitrary user image. The application verifies the file inode and
/// separately binds the live hdiutil/Disk Arbitration attachment.
public struct APFSVolumeFormatGeneratedOwner: Codable, Equatable, Sendable {
    public let fixtureID: UUID
    public let imagePath: String
    public let rootDevice: Int64
    public let rootInode: UInt64
    public let imageDevice: Int64
    public let imageInode: UInt64
    public let ownerUID: UInt32
    public let outerMediaID: UInt64

    public init(fixtureID: UUID, imagePath: String, rootDevice: Int64, rootInode: UInt64,
                imageDevice: Int64, imageInode: UInt64, ownerUID: UInt32, outerMediaID: UInt64) {
        self.fixtureID = fixtureID; self.imagePath = imagePath
        self.rootDevice = rootDevice; self.rootInode = rootInode
        self.imageDevice = imageDevice; self.imageInode = imageInode
        self.ownerUID = ownerUID; self.outerMediaID = outerMediaID
    }
    public func validate() -> Bool {
        let image = URL(fileURLWithPath: imagePath)
        let root = image.deletingLastPathComponent()
        return imagePath.hasPrefix("/") && image.standardizedFileURL.path == imagePath
            && image.lastPathComponent == "fixture.dmg"
            && root.lastPathComponent == "drive-lifecycle-" + fixtureID.uuidString
            && root.deletingLastPathComponent().lastPathComponent == "fixtures"
            && root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build"
            && rootDevice != 0 && rootInode != 0 && imageDevice != 0 && imageInode != 0 && outerMediaID != 0
    }
}

/// One persisted operation slot. On a fresh launch, every nonterminal phase
/// means the tool may have started, including `intent`: a crash can occur in
/// the gap between Process.run and the submitted-record publication.
public struct APFSVolumeFormatJobRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case intent, submitted, uncertain, compatibleReplacement, notSubmitted
    }
    public let version: Int
    public let id: UUID
    public let owner: APFSVolumeFormatGeneratedOwner
    public let snapshot: APFSVolumeFormatSnapshot
    public var phase: Phase
    public var replacementID: UUID?

    public init(id: UUID, owner: APFSVolumeFormatGeneratedOwner, snapshot: APFSVolumeFormatSnapshot, phase: Phase,
                replacementID: UUID? = nil) {
        version = 1; self.id = id; self.owner = owner; self.snapshot = snapshot
        self.phase = phase; self.replacementID = replacementID
    }
    public var isUnresolved: Bool { [.intent, .submitted, .uncertain, .compatibleReplacement].contains(phase) }
    public func validate() -> Bool {
        version == 1 && owner.validate() && snapshot.validate()
            && (phase == .compatibleReplacement) == (replacementID != nil)
            && replacementID != snapshot.targetID
    }
}

/// An intent is durable before Process.run. A cold intent is always potentially
/// submitted; only an actual prelaunch return can be recorded as no submission.
public enum APFSVolumeFormatRecoveryTerminal: Sendable, Equatable {
    case notSubmitted
    /// The backend saw a compatible APFS replacement. Marker evidence is not
    /// in this record, so the durable job remains unresolved.
    case compatibleReplacement(UUID)
    case uncertain
}

public protocol APFSVolumeFormatRecording: Sendable {
    /// Must bind the saved generated backing file and live outer attachment.
    /// A recorder cannot be paired with a default-true launch permission.
    func ownerStillCurrent() -> Bool
    func recordIntent(_ snapshot: APFSVolumeFormatSnapshot) async throws
    func recordSubmitted() async throws
    func recordTerminal(_ terminal: APFSVolumeFormatRecoveryTerminal) async throws
}

/// Shared by the real backend and focused failure tests. The postlaunch write
/// runs concurrently with pipe draining; it cannot turn a launched child into
/// a claimed cancellation. Every return waits for that write before terminal.
final class APFSVolumeFormatRecoverySession: @unchecked Sendable {
    private let recording: any APFSVolumeFormatRecording
    private let lock = NSLock()
    private var submission: Task<Void, Error>?
    init(_ recording: any APFSVolumeFormatRecording) { self.recording = recording }

    func ownerStillCurrent() -> Bool { recording.ownerStillCurrent() }

    func begin(_ snapshot: APFSVolumeFormatSnapshot) async throws {
        guard snapshot.validate(), ownerStillCurrent() else { throw APFSVolumeFormatFailure.changed }
        try await recording.recordIntent(snapshot)
    }
    func didSubmit() {
        lock.withLock {
            guard submission == nil else { return }
            submission = Task { try await recording.recordSubmitted() }
        }
    }
    func finish(_ result: APFSVolumeFormatResult) async -> APFSVolumeFormatResult {
        let task = lock.withLock { submission }
        var final = result
        if result.submitted {
            if let task {
                do { try await task.value }
                catch { final = Self.uncertain(result, submitted: true) }
            } else { final = Self.uncertain(result, submitted: true) }
        } else if task != nil {
            // A successful launch callback outranks a contradictory no-launch
            // return. Leave the durable record unresolved.
            if let task { _ = try? await task.value }
            final = Self.uncertain(result, submitted: true)
        }
        let terminal: APFSVolumeFormatRecoveryTerminal = !final.submitted ? .notSubmitted
            : final.failure == nil && final.formatted != nil ? .compatibleReplacement(final.formatted!.id) : .uncertain
        do { try await recording.recordTerminal(terminal) }
        catch {
            final = final.submitted ? Self.uncertain(final, submitted: true)
                : .init(submitted: false, formatted: nil, failure: .recoveryUnavailable)
        }
        return final
    }
    private static func uncertain(_ result: APFSVolumeFormatResult, submitted: Bool) -> APFSVolumeFormatResult {
        .init(submitted: submitted, formatted: nil, failure: .uncertain,
              toolExitStatus: result.toolExitStatus, diskutilErrorCode: result.diskutilErrorCode)
    }
}
