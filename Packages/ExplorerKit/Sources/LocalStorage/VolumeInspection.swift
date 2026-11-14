import CoreFoundation
import DiskArbitration
import Foundation

/// Captured presentation metadata only. This result grants no disk-operation
/// authority and must never substitute for a freshly prepared native action.
public struct VolumeInspection: Sendable {
    public let volume: ManagedVolume
    public let deviceName: String
    public let fields: Fields
    public let capturedAt: Date
    public init(volume: ManagedVolume, deviceName: String, fields: Fields, capturedAt: Date = Date()) {
        self.volume = volume; self.deviceName = deviceName; self.fields = fields; self.capturedAt = capturedAt
    }
    public struct Fields: Sendable, Equatable {
        public let fileSystem: String?
        public let model: String?
        public let vendor: String?
        public let transport: String?
        public let mediaBytes: UInt64?
        public let outerDeviceBytes: UInt64?
        public let blockBytes: UInt64?
        public let writable: Bool?
        public let removable: Bool?
        public init(fileSystem: String? = nil, model: String? = nil, vendor: String? = nil, transport: String? = nil,
                    mediaBytes: UInt64? = nil, outerDeviceBytes: UInt64? = nil, blockBytes: UInt64? = nil,
                    writable: Bool? = nil, removable: Bool? = nil) {
            self.fileSystem = fileSystem; self.model = model; self.vendor = vendor; self.transport = transport
            self.mediaBytes = mediaBytes; self.outerDeviceBytes = outerDeviceBytes; self.blockBytes = blockBytes
            self.writable = writable; self.removable = removable
        }
        internal static func read(_ volume: NSDictionary, outer: NSDictionary?) -> Self {
            func text(_ key: CFString) -> String? { string(volume[key]) ?? string(outer?[key]) }
            return .init(fileSystem: string(volume[kDADiskDescriptionVolumeKindKey]),
                model: text(kDADiskDescriptionDeviceModelKey), vendor: text(kDADiskDescriptionDeviceVendorKey),
                transport: text(kDADiskDescriptionDeviceProtocolKey), mediaBytes: unsigned(volume[kDADiskDescriptionMediaSizeKey]),
                outerDeviceBytes: outer.flatMap { unsigned($0[kDADiskDescriptionMediaSizeKey]) },
                blockBytes: unsigned(volume[kDADiskDescriptionMediaBlockSizeKey]),
                writable: boolean(volume[kDADiskDescriptionMediaWritableKey]),
                removable: boolean(outer?[kDADiskDescriptionMediaRemovableKey] ?? volume[kDADiskDescriptionMediaRemovableKey]))
        }
        private static func string(_ value: Any?) -> String? {
            guard let value = value as? String, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        private static func boolean(_ value: Any?) -> Bool? {
            guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            return value as? Bool
        }
        private static func unsigned(_ value: Any?) -> UInt64? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: value.objCType)),
                  value.compare(0) != .orderedAscending, value.compare(NSNumber(value: Int64.max)) != .orderedDescending else { return nil }
            return value.uint64Value
        }
    }
}

public protocol VolumeInspecting: Sendable {
    func inspect(_ target: ManagedVolume) async throws -> VolumeInspection
}
