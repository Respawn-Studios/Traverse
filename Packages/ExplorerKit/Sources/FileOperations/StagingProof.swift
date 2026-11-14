import CryptoKit
import Foundation

/// Fixed-size durable evidence of a completed, verified and synced unpublished copy.
/// The source of this proof is successful descriptor-copy receipts, never a remnant scan.
internal struct JournalStagingProof: Codable, Equatable, Sendable {
    let version: Int
    let payload: VerifiedTree
    let identityDigest: String
    let nodeCount: Int
    let stepCount: Int
    /// Version 2 only: one descriptor-bound APFS UUID for all copied nodes.
    let volumeUUID: Data?

    init(version: Int, payload: VerifiedTree, identityDigest: String, nodeCount: Int,
         stepCount: Int, volumeUUID: Data? = nil) {
        self.version = version; self.payload = payload; self.identityDigest = identityDigest
        self.nodeCount = nodeCount; self.stepCount = stepCount; self.volumeUUID = volumeUUID
    }

    func validate(area: JournalArea, stepCount currentSteps: Int) throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard [1, 2].contains(version), (1...OperationLimits.maximumNodes).contains(nodeCount),
              (0...currentSteps).contains(stepCount), payload.identity.device == area.identity.device,
              digest(payload.digest), digest(identityDigest) else { throw FileOperationFailure.recoveryUncertain }
        if version == 1 {
            guard volumeUUID == nil else { throw FileOperationFailure.recoveryUncertain }
        } else {
            guard let volumeUUID, volumeUUID.count == 16,
                  volumeUUID.contains(where: { $0 != 0 }) else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}

/// Bounded, operation-local receipts; descriptor copying invokes this synchronously.
internal final class StagingCopyReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: EntrySnapshot] = [:]

    func completed(_ relative: String, _ identity: EntrySnapshot) throws {
        try lock.withLock {
            guard nodes.count < OperationLimits.maximumNodes, nodes[relative] == nil else {
                throw FileOperationFailure.unsupported
            }
            nodes[relative] = identity
        }
    }

    func proof(parent: Int32, payload: VerifiedTree, stepCount: Int,
               persistentVolume: PersistentVolumeBinding? = nil,
               cancellation: OperationCancellation) throws -> JournalStagingProof {
        let expected = lock.withLock { nodes }
        let actual = try snapshotTree(parent: parent, name: "payload", cancellation: cancellation)
        guard !expected.isEmpty, actual.count == expected.count,
              expected.allSatisfy({ relative, identity in
                  actual[relative].map { identity.sameObject(as: $0.snapshot) } ?? false
              }) else { throw FileOperationFailure.sourceChanged }
        if let persistentVolume {
            try persistentVolume.validateRepresentation()
            guard payload.identity.device == persistentVolume.device,
                  actual.values.allSatisfy({ $0.snapshot.device == persistentVolume.device }) else {
                throw FileOperationFailure.sourceChanged
            }
        }
        return JournalStagingProof(version: persistentVolume == nil ? 1 : 2, payload: payload,
            identityDigest: stagingIdentityDigest(actual, persistentVolume: persistentVolume),
            nodeCount: actual.count, stepCount: stepCount, volumeUUID: persistentVolume?.uuid)
    }
}

internal func stagingIdentityDigest(_ nodes: [String: TreeNode],
                                    persistentVolume: PersistentVolumeBinding? = nil) -> String {
    var digest = SHA256()
    if let persistentVolume {
        digest.update(data: Data("staging-identity-v2-apfs\n".utf8))
        digest.update(data: persistentVolume.uuid)
    }
    for relative in nodes.keys.sorted() {
        let identity = nodes[relative]!.snapshot
        let name = Data(relative.utf8)
        digest.update(data: Data("\(name.count):".utf8)); digest.update(data: name)
        if persistentVolume != nil {
            digest.update(data: Data("|\(identity.inode):\(identity.type):\(identity.birthSeconds):\(identity.birthNanos);".utf8))
        } else {
            digest.update(data: Data("|\(identity.device):\(identity.inode):\(identity.type):\(identity.birthSeconds):\(identity.birthNanos);".utf8))
        }
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
