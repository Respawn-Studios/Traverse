import Foundation
import Testing
@testable import LocalStorage

internal enum StreamedZIP {
    static func bytes(_ bytes: Data, method: UInt16 = 8, signed: Bool = true,
                      localWide: Bool = false, centralWide: Bool = false,
                      localActual: Bool = false) throws -> Data {
        let packed = method == 8 ? try ContentZIP.deflate(bytes) : bytes
        let name = Data("Streamed.bin".utf8), crc = UInt64(ZIPMetadataParser.crc32(bytes))
        var local = Data(repeating: 0, count: 30), central = Data(repeating: 0, count: 46)
        let localExtra = localWide ? GeneratedZIP.le(1, 2) + GeneratedZIP.le(16, 2)
            + GeneratedZIP.le(localActual ? UInt64(bytes.count) : 0, 8) + GeneratedZIP.le(localActual ? UInt64(packed.count) : 0, 8) : Data()
        let centralExtra = centralWide ? GeneratedZIP.le(1, 2) + GeneratedZIP.le(16, 2)
            + GeneratedZIP.le(UInt64(bytes.count), 8) + GeneratedZIP.le(UInt64(packed.count), 8) : Data()
        GeneratedZIP.put(&local, 0, 0x04034b50, 4); GeneratedZIP.put(&local, 4, localWide || centralWide ? 45 : 20, 2)
        GeneratedZIP.put(&local, 6, 0x0808, 2); GeneratedZIP.put(&local, 8, UInt64(method), 2)
        GeneratedZIP.put(&local, 14, localActual ? crc : 0, 4)
        GeneratedZIP.put(&local, 18, localWide ? UInt64(UInt32.max) : (localActual ? UInt64(packed.count) : 0), 4)
        GeneratedZIP.put(&local, 22, localWide ? UInt64(UInt32.max) : (localActual ? UInt64(bytes.count) : 0), 4)
        GeneratedZIP.put(&local, 26, UInt64(name.count), 2); GeneratedZIP.put(&local, 28, UInt64(localExtra.count), 2)
        local += name; local += localExtra; local += packed
        let width = localWide || centralWide ? 8 : 4
        if signed { local += GeneratedZIP.le(0x08074b50, 4) }
        local += GeneratedZIP.le(crc, 4); local += GeneratedZIP.le(UInt64(packed.count), width); local += GeneratedZIP.le(UInt64(bytes.count), width)
        GeneratedZIP.put(&central, 0, 0x02014b50, 4); GeneratedZIP.put(&central, 4, 0x0314, 2)
        GeneratedZIP.put(&central, 6, localWide || centralWide ? 45 : 20, 2); GeneratedZIP.put(&central, 8, 0x0808, 2)
        GeneratedZIP.put(&central, 10, UInt64(method), 2); GeneratedZIP.put(&central, 16, crc, 4)
        GeneratedZIP.put(&central, 20, centralWide ? UInt64(UInt32.max) : UInt64(packed.count), 4)
        GeneratedZIP.put(&central, 24, centralWide ? UInt64(UInt32.max) : UInt64(bytes.count), 4)
        GeneratedZIP.put(&central, 28, UInt64(name.count), 2); GeneratedZIP.put(&central, 30, UInt64(centralExtra.count), 2)
        GeneratedZIP.put(&central, 38, 0x8000 << 16, 4); central += name; central += centralExtra
        var end = Data(repeating: 0, count: 22)
        GeneratedZIP.put(&end, 0, 0x06054b50, 4); GeneratedZIP.put(&end, 8, 1, 2); GeneratedZIP.put(&end, 10, 1, 2)
        GeneratedZIP.put(&end, 12, UInt64(central.count), 4); GeneratedZIP.put(&end, 16, UInt64(local.count), 4)
        return local + central + end
    }
}

@Suite struct ZIPDataDescriptorTests {
    @Test func signedUnsignedStoredDeflatedAndSmallZIP64HaveExactContents() throws {
        let generated = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 * 71) })
        for body in [Data(), generated] {
            for method: UInt16 in [0, 8] {
                for signed in [false, true] {
                    for wide in [(false, false), (true, false), (false, true), (true, true)] {
                        let archive = try StreamedZIP.bytes(body, method: method, signed: signed, localWide: wide.0, centralWide: wide.1)
                        let result = try ContentZIP.verify(archive)
                        #expect(result.files == 1 && result.decodedBytes == body.count)
                    }
                }
            }
        }
        for wide in [false, true] {
            #expect(try ContentZIP.verify(StreamedZIP.bytes(generated, localWide: wide, localActual: true)).decodedBytes == generated.count)
        }
    }
    @Test func descriptorEveryTruncationAndChangedFieldRefusesBeforeDecoding() throws {
        let body = Data("generated streamed content".utf8)
        for signed in [false, true] {
            for wide in [false, true] {
                let archive = try StreamedZIP.bytes(body, signed: signed, localWide: wide)
                let record = try #require(ContentZIP.records(archive).first)
                let length = (wide ? 20 : 12) + (signed ? 4 : 0), start = Int(record.centralOffset) - length
                for count in 0..<length {
                    let truncated = Data(archive[..<(start + count)])
                    #expect(throws: (any Error).self) { try ZIPDataDescriptor.length(at: UInt64(start), before: UInt64(truncated.count),
                        crc: record.crc, packed: record.packed, logical: record.logical, wide: wide,
                        read: { offset, length in Data(truncated[Int(offset)..<(Int(offset) + length)]) }) }
                }
                for byte in (signed ? 4 : 0)..<length {
                    var changed = archive; changed[start + byte] ^= 1
                    #expect(throws: (any Error).self) { _ = try ContentZIP.verify(changed) }
                }
                var wrongWidth = archive
                if wide {
                    GeneratedZIP.put(&wrongWidth, 18, 0, 4); GeneratedZIP.put(&wrongWidth, 22, 0, 4)
                    // A malformed ZIP64 extra cannot be silently ignored.
                    GeneratedZIP.put(&wrongWidth, 30 + record.rawName.count + 2, 8, 2)
                } else { GeneratedZIP.put(&wrongWidth, start + (signed ? 8 : 4), UInt64(body.count + 1), 4) }
                #expect(throws: (any Error).self) { _ = try ContentZIP.verify(wrongWidth) }
            }
        }
    }
    @Test func localPlaceholdersAndDescriptorStructuralBoundsAreAuthoritative() throws {
        let bytes = try StreamedZIP.bytes(Data("generated".utf8), localWide: true)
        for change in [(14, UInt64(1), 4), (18, UInt64(0), 4), (30 + 12 + 4, UInt64(1), 8)] {
            var changed = bytes; GeneratedZIP.put(&changed, change.0, change.1, change.2)
            #expect(throws: (any Error).self) { _ = try ContentZIP.verify(changed) }
        }
        let small = try StreamedZIP.bytes(Data("generated".utf8)), record = try #require(ContentZIP.records(small).first)
        let shortened = ZIPPayloadRecord(name: record.name, rawName: record.rawName, kind: record.kind, flags: record.flags,
            method: record.method, crc: record.crc, logical: record.logical, packed: record.packed,
            localOffset: record.localOffset, centralOffset: record.centralOffset - 1, usesZIP64: record.usesZIP64)
        #expect(throws: (any Error).self) { _ = try ZIPContentVerifier.prepare([shortened], limits: .init(), check: {},
            read: { offset, count in Data(small[Int(offset)..<(Int(offset) + count)]) }) }
    }
    @Test func signatureShapedCRCIsNotMisclassifiedAndAmbiguityRefuses() throws {
        let signature: UInt32 = 0x08074b50
        for wide in [false, true] {
            for signed in [false, true] {
                let width = wide ? 8 : 4
                let bytes = (signed ? GeneratedZIP.le(UInt64(signature), 4) : Data()) + GeneratedZIP.le(UInt64(signature), 4)
                    + GeneratedZIP.le(3, width) + GeneratedZIP.le(9, width)
                #expect(try ZIPDataDescriptor.length(at: 0, before: UInt64(bytes.count), crc: signature, packed: 3, logical: 9,
                    wide: wide, read: { _, count in Data(bytes.prefix(count)) }) == bytes.count)
            }
        }
        let ambiguous = (0..<4).reduce(into: Data()) { value, _ in value += GeneratedZIP.le(UInt64(signature), 4) }
        #expect(throws: ZIPContentFailure.metadataMismatch) { try ZIPDataDescriptor.length(at: 0, before: UInt64(ambiguous.count),
            crc: signature, packed: UInt64(signature), logical: UInt64(signature), wide: false,
            read: { _, count in Data(ambiguous.prefix(count)) }) }
    }
}
