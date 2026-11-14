import Darwin
import Foundation
@testable import LocalStorage
import Testing

private func usedRecord(_ used: Int64, length: UInt32 = 32,
                        common: UInt32 = UInt32(ATTR_CMN_RETURNED_ATTRS),
                        volume: UInt32 = (UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED)),
                        directory: UInt32 = 0) -> Data {
    var data = Data()
    for value in [length, common, volume, directory, 0, 0] {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
    withUnsafeBytes(of: used) { data.append(contentsOf: $0) }
    return data
}

@Test func nativeVolumeUsedDecoderRequiresReturnedValueNotZeroFilledStorage() {
    #expect(NativeVolumeUsedSpace.decode(usedRecord(0)) == 0)
    #expect(NativeVolumeUsedSpace.decode(usedRecord(9_000_000_001)) == 9_000_000_001)
    #expect(NativeVolumeUsedSpace.decode(usedRecord(Int64.max)) == UInt64(Int64.max))
    #expect(NativeVolumeUsedSpace.decode(usedRecord(-1)) == nil)
    #expect(NativeVolumeUsedSpace.decode(usedRecord(0, length: 24, volume: UInt32(ATTR_VOL_INFO))) == nil)
    #expect(NativeVolumeUsedSpace.decode(usedRecord(0, common: 0)) == nil)
    #expect(NativeVolumeUsedSpace.decode(usedRecord(0, volume: (UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED) | UInt32(ATTR_VOL_SIZE)))) == nil)
    #expect(NativeVolumeUsedSpace.decode(usedRecord(0, directory: 1)) == nil)
}

@Test func nativeVolumeUsedDecoderRejectsTruncatedAndOversizedProfiles() {
    let good = usedRecord(42)
    for count in 0..<32 { #expect(NativeVolumeUsedSpace.decode(Data(good.prefix(count))) == nil) }
    for length: UInt32 in [0, 23, 24, 28, 31, 33, UInt32.max] {
        #expect(NativeVolumeUsedSpace.decode(usedRecord(42, length: length)) == nil)
    }
    #expect(NativeVolumeUsedSpace.decode(usedRecord(42, common: (UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)))) == nil)
}

@Test func nativeVolumeUsedProbeUsesHeldDirectoryWithoutChangingIt() throws {
    // No enumeration or file-body read. Query only the repository's existing
    // directory descriptor; preserve its identity and namespace metadata.
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let descriptor = open(repository.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var before = stat(), after = stat()
    #expect(fstat(descriptor, &before) == 0)
    let value = try #require(NativeVolumeUsedSpace.read(directoryDescriptor: descriptor))
    #expect(value.observedAt <= Date())
    #expect(fstat(descriptor, &after) == 0)
    #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_gen == after.st_gen)
    #expect(before.st_size == after.st_size && before.st_mode == after.st_mode)
    #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    #expect(NativeVolumeUsedSpace.read(directoryDescriptor: -1) == nil)
}
