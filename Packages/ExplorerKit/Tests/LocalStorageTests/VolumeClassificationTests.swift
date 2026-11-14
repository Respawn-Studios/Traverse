import Testing
import Foundation
@testable import LocalStorage

struct VolumeClassificationTests {
    @Test func preferenceUUIDAcceptsOnlyNativeUUIDValues() throws {
        let value = try #require(CFUUIDCreate(nil))
        let expected = UUID(uuidString: CFUUIDCreateString(nil, value) as String)
        #expect(VolumeLifecycle.preferenceUUID(value) == expected)
        #expect(VolumeLifecycle.preferenceUUID(nil) == nil)
        #expect(VolumeLifecycle.preferenceUUID("not a native UUID") == nil)
        #expect(VolumeLifecycle.preferenceUUID(42) == nil)
    }
    @Test func missingExternalFlagNeverAloneEstablishesImageOrExternalDevice() {
        #expect(VolumeLifecycle.deviceKind(internalFlag: nil, wholeInternal: nil, positivelyIdentifiedImage: false) == .unknown)
        #expect(VolumeLifecycle.deviceKind(internalFlag: false, wholeInternal: false, positivelyIdentifiedImage: false) == .externalDisk)
        #expect(VolumeLifecycle.deviceKind(internalFlag: nil, wholeInternal: nil, positivelyIdentifiedImage: true) == .diskImage)
    }
    @Test func internalStorageAlwaysRemainsProtectedEvenWithConflictingImageFacts() {
        #expect(VolumeLifecycle.deviceKind(internalFlag: true, wholeInternal: nil, positivelyIdentifiedImage: true) == .internalDisk)
        #expect(VolumeLifecycle.deviceKind(internalFlag: nil, wholeInternal: true, positivelyIdentifiedImage: true) == .internalDisk)
        #expect(VolumeLifecycle.deviceKind(internalFlag: false, wholeInternal: true, positivelyIdentifiedImage: false) == .internalDisk)
    }
}
