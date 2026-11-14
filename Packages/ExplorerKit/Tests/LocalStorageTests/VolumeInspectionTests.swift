import CoreFoundation
import DiskArbitration
import Foundation
import Testing
@testable import LocalStorage

struct VolumeInspectionTests {
    @Test func nativeFieldsKeepVolumeAndOuterDeviceCapacitiesDistinct() {
        let value = VolumeInspection.Fields.read([
            kDADiskDescriptionVolumeKindKey: "apfs", kDADiskDescriptionDeviceModelKey: "  Generated drive  ",
            kDADiskDescriptionMediaSizeKey: NSNumber(value: 1000), kDADiskDescriptionMediaBlockSizeKey: NSNumber(value: 4096),
            kDADiskDescriptionMediaWritableKey: kCFBooleanTrue as Any
        ] as NSDictionary, outer: [kDADiskDescriptionMediaSizeKey: NSNumber(value: 8_000_000_000_000),
            kDADiskDescriptionDeviceProtocolKey: "USB", kDADiskDescriptionMediaRemovableKey: kCFBooleanFalse as Any] as NSDictionary)
        #expect(value.fileSystem == "apfs" && value.model == "Generated drive" && value.transport == "USB")
        #expect(value.mediaBytes == 1000 && value.outerDeviceBytes == 8_000_000_000_000 && value.blockBytes == 4096)
        #expect(value.writable == true && value.removable == false)
    }
    @Test func unknownAndUnexpectedNativeTypesStayUnavailable() {
        let value = VolumeInspection.Fields.read([
            kDADiskDescriptionDeviceModelKey: "bad\nmodel", kDADiskDescriptionDeviceVendorKey: String(repeating: "x", count: 513),
            kDADiskDescriptionMediaSizeKey: NSNumber(value: -1), kDADiskDescriptionMediaBlockSizeKey: NSNumber(value: 1.5),
            kDADiskDescriptionMediaWritableKey: NSNumber(value: 2), kDADiskDescriptionMediaRemovableKey: "true"
        ] as NSDictionary, outer: nil)
        #expect(value == .init())
        let boolSize = VolumeInspection.Fields.read([kDADiskDescriptionMediaSizeKey: kCFBooleanTrue as Any] as NSDictionary, outer: nil)
        #expect(boolSize.mediaBytes == nil)
        let overflow = VolumeInspection.Fields.read([kDADiskDescriptionMediaSizeKey: NSNumber(value: UInt64.max)] as NSDictionary, outer: nil)
        #expect(overflow.mediaBytes == nil)
    }
    @Test func nativeMountAndUUIDMustMatchTheDisplayedObservation() {
        let uuid = UUID(), url = URL(fileURLWithPath: "/generated/Volume")
        let nativeUUID = CFUUIDCreateFromString(nil, uuid.uuidString as CFString)!
        let target = ManagedVolume(id: UUID(), name: "Generated", url: url, isInternal: false,
            canMount: false, canUnmount: true, canEject: true, fileSystemID: 42, group: 43, mediaID: 44, volumeUUID: uuid)
        let data = [kDADiskDescriptionVolumePathKey: url, kDADiskDescriptionVolumeUUIDKey: nativeUUID] as NSDictionary
        #expect(VolumeLifecycle.matchesInspectionMount(data, target: target))
        #expect(!VolumeLifecycle.matchesInspectionMount([kDADiskDescriptionVolumePathKey: url] as NSDictionary, target: target))
        #expect(!VolumeLifecycle.matchesInspectionMount([kDADiskDescriptionVolumePathKey: URL(fileURLWithPath: "/generated/Other"),
            kDADiskDescriptionVolumeUUIDKey: nativeUUID] as NSDictionary, target: target))
    }
}
