import Foundation
import Testing
@testable import LocalStorage

struct TARMetadataTests {
    @Test(arguments: TARReaderTestFixture.Variant.allCases)
    func independentCatalogReadsMetadataWithoutMemberBodies(variant: TARReaderTestFixture.Variant) throws {
        let bytes = try TARReaderTestFixture.bytes(variant)
        let expected = TARReaderTestFixture.rows(variant)
        var reads = [(UInt64, Int)]()
        let parsed = try parse(bytes) { reads.append(($0, $1)) }
        let catalog = try TARCatalogBuilder.build(parsed, check: {})
        let actual = parsed.records.map {
            TARReaderTestFixture.Row(path: $0.path, kind: $0.kind.rawValue, bytes: $0.bytes, dataOffset: $0.dataOffset)
        }
        #expect(actual == expected)
        #expect(parsed.metadataBytes == reads.reduce(0) { $0 + $1.1 })
        #expect(parsed.witness.count == 32 && catalog.witness == parsed.witness)
        #expect(catalog.summary.logicalBytes == expected.filter { $0.kind == "file" }.reduce(0) { $0 + $1.bytes })
        #expect(catalog.summary.files == expected.filter { $0.kind == "file" }.count)
        #expect(catalog.nodes.count <= 20_000)
        let (end, physical): (UInt64, Int) = switch variant {
        case .ustar: (70_144, 6)
        case .pax, .gnu: (2048, 2)
        case .rootAndLinks: (3072, 5)
        case .empty: (0, 0)
        }
        #expect(parsed.endOffset == end && parsed.physicalRecords == physical)
        // PAX/GNU extension bodies are metadata. Only ordinary file bodies are forbidden here.
        for (offset, count) in reads {
            for row in expected where row.kind == "file" && row.bytes > 0 {
                #expect(offset + UInt64(count) <= row.dataOffset || offset >= row.dataOffset + row.bytes)
            }
        }
        for field in TARArchiveOrder.Field.allCases {
            for descending in [false, true] {
                let ids = try TARCatalogOrdering.ids(catalog.nodes[0].children, nodes: catalog.nodes,
                    order: .init(field, descending: descending), check: {})
                #expect(Set(ids) == Set(catalog.nodes[0].children))
            }
        }
    }

    enum Refusal: CaseIterable, Equatable, Sendable {
        case checksum, truncated, oneZero, noZero, trailer, unknownType, magic, base256, globalPAX
        case duplicate, caseCollision, unicodeCollision
    }
    @Test(arguments: Refusal.allCases)
    func malformedUnsupportedAndAmbiguousCatalogsRefuse(reason: Refusal) throws {
        let sample = try TARReaderTestFixture.bytes()
        let bytes: Data
        let failure: TARArchiveFailure
        switch reason {
        case .checksum:
            var altered = sample; altered[0] ^= 1; bytes = altered; failure = .malformed
        case .truncated: bytes = sample.prefix(600); failure = .malformed
        case .oneZero:
            bytes = TARReaderTestFixture.terminated(try TARReaderTestFixture.member("one")).dropLast(512)
            failure = .malformed
        case .noZero: bytes = try TARReaderTestFixture.member("none"); failure = .malformed
        case .trailer:
            bytes = TARReaderTestFixture.terminated(try TARReaderTestFixture.member("trailer"))
                + Data([1]) + Data(repeating: 0, count: 511)
            failure = .malformed
        case .unknownType:
            bytes = TARReaderTestFixture.changingFirstHeader(sample) { $0[156] = 83 }; failure = .unsupported
        case .magic:
            bytes = TARReaderTestFixture.changingFirstHeader(sample) { $0.replaceSubrange(257..<263, with: "other\0".utf8) }
            failure = .unsupported
        case .base256:
            bytes = TARReaderTestFixture.changingFirstHeader(sample) { $0[124] = 128 }; failure = .unsupported
        case .globalPAX:
            bytes = TARReaderTestFixture.changingFirstHeader(sample) { $0[156] = 103 }; failure = .unsupported
        case .duplicate, .caseCollision, .unicodeCollision:
            let names = reason == .duplicate ? ["Same", "Same"]
                : reason == .caseCollision ? ["Name", "name"] : ["café", "cafe\u{301}"]
            bytes = try TARReaderTestFixture.terminated(names.reduce(into: Data()) {
                $0 += try TARReaderTestFixture.member($1)
            })
            failure = .ambiguousNames
        }
        #expect(throws: failure) {
            _ = try TARCatalogBuilder.build(parse(bytes), check: {})
        }
    }

    @Test(arguments: ["../Escape", "/Absolute", "A/../Escape", "A//Member",
                      "C:Drive", "Back\\slash", "Control\u{1}", "Bidi\u{202e}"])
    func unsafePathsNeverEnterCatalog(name: String) throws {
        let bytes = TARReaderTestFixture.terminated(try TARReaderTestFixture.member(name))
        #expect(throws: TARArchiveFailure.unsafeName) { _ = try parse(bytes) }
    }

    enum Bound: CaseIterable, Sendable {
        case records, nodes, metadata, member, logical, names, search, path, invalidRecords
    }
    @Test(arguments: Bound.allCases)
    func parserAndCatalogEnforceIndependentLimits(bound: Bound) throws {
        let bytes = try TARReaderTestFixture.bytes()
        var limits = TARReadLimits()
        switch bound {
        case .records: limits.records = 0
        case .nodes: limits.nodes = 1
        case .metadata: limits.metadataBytes = 511
        case .member: limits.memberBytes = 2
        case .logical: limits.logicalBytes = 2
        case .names: limits.nameBytes = 1
        case .search: limits.searchBytes = 1
        case .path: limits.pathBytes = 1
        case .invalidRecords: limits.records = -1
        }
        #expect(throws: TARArchiveFailure.limited) {
            _ = try TARCatalogBuilder.build(parse(bytes, limits: limits), limits: limits, check: {})
        }
    }

    @Test func stopAndShortReadDoNotReturnPartialCatalogs() throws {
        let bytes = try TARReaderTestFixture.bytes()
        var checks = 0
        #expect(throws: TARArchiveFailure.stopped) {
            _ = try TARMetadataParser.parse(length: UInt64(bytes.count), check: {
                checks += 1
                if checks == 3 { throw TARArchiveFailure.stopped }
            }, read: { offset, count in bytes.subdata(in: Int(offset)..<(Int(offset) + count)) })
        }
        #expect(checks == 3)
        #expect(throws: TARArchiveFailure.malformed) {
            _ = try TARMetadataParser.parse(length: UInt64(bytes.count), check: {},
                read: { _, count in Data(repeating: 0, count: count - 1) })
        }
    }

    private func parse(_ bytes: Data, limits: TARReadLimits = .init(),
                       observed: (UInt64, Int) -> Void = { _, _ in }) throws -> TARParsedDirectory {
        try TARMetadataParser.parse(length: UInt64(bytes.count), limits: limits, check: {}, read: { offset, count in
            try #require(count >= 0 && offset <= UInt64(bytes.count) && UInt64(count) <= UInt64(bytes.count) - offset)
            observed(offset, count)
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        })
    }
}
