import CryptoKit
import Foundation

/// Qualification remains separate from recording a native observation. Existing
/// callers retain the provisional contract until they explicitly select v2.
public enum APFSVolumeFormatCompletionPolicy: Equatable, Sendable {
    case provisional
    case sourceQualification
}

/// Historical facts from one owned, successfully returned native request. This
/// receipt is not erase authority, secure-erasure proof or a claim about current
/// bytes. A cold compatible layout cannot manufacture a warm completion.
public struct APFSVolumeFormatNativeCompletion: Codable, Equatable, Sendable {
    public let version: Int
    public let intentSHA256: String
    public let replacementID: UUID
    public let replacementDevice: String
    public let nativeExitStatus: Int32
    public let nativeErrorCode: Int?
    public let observedAt: Date

    init(intent: APFSVolumeFormatSnapshot, after: APFSContainerObservation,
         info: APFSVolumeObservation, nativeExitStatus: Int32, nativeErrorCode: Int? = nil,
         observedAt: Date = Date()) throws {
        guard nativeExitStatus == 0, intent.validate(),
              nativeErrorCode == nil || nativeErrorCode == 0,
              let replacement = APFSVolumeFormat.reconciledReplacement(
                before: intent.originalContainer(), after: after,
                original: intent.targetID, name: intent.name),
              info.uuid == replacement.uuid, info.device == replacement.device,
              info.container == intent.containerDevice, info.name == intent.name,
              info.caseSensitive == intent.caseSensitive,
              observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw APFSVolumeFormatFailure.uncertain
        }
        version = 1
        intentSHA256 = try Self.digest(intent)
        replacementID = replacement.uuid; replacementDevice = replacement.device
        self.nativeExitStatus = nativeExitStatus; self.observedAt = observedAt
        self.nativeErrorCode = nativeErrorCode
        guard validates(intent) else { throw APFSVolumeFormatFailure.uncertain }
    }

    public func validates(_ intent: APFSVolumeFormatSnapshot) -> Bool {
        guard version == 1, nativeExitStatus == 0, intent.validate(),
              nativeErrorCode == nil || nativeErrorCode == 0,
              replacementID != intent.targetID,
              APFSContainerObservation.validDevice(replacementDevice),
              replacementDevice.hasPrefix(intent.containerDevice + "s"),
              !intent.members.contains(where: { $0.uuid == replacementID }),
              !intent.members.contains(where: { $0.uuid != intent.targetID && $0.device == replacementDevice }),
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              let expected = try? Self.digest(intent) else { return false }
        return intentSHA256 == expected
    }

    private static func digest(_ snapshot: APFSVolumeFormatSnapshot) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
    }
}
