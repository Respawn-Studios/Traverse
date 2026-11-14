import ExplorerCore
import Foundation
import Search
import XCTest

final class FileSizeInputTests: XCTestCase {
    func testExplicitDecimalAndBinaryUnitsRemainDistinct() throws {
        for (input, expected) in [("1 B", 1), ("1kb", 1_000), ("2 MB", 2_000_000),
            ("3GB", 3_000_000_000), ("4 TB", 4_000_000_000_000), ("1 KiB", 1_024),
            ("2miB", 2_097_152), ("3 GiB", 3_221_225_472), ("4TiB", 4_398_046_511_104)] as [(String, Int64)] {
            XCTAssertEqual(try FileSizeInput.bytes(input), expected, input)
        }
    }

    func testFractionsAreExactWholeBytesWithoutRounding() throws {
        for (input, expected) in [("1.5 MB", 1_500_000), (".5KiB", 512),
            ("0.0009765625 KiB", 1), ("0.000000000001 TB", 1), ("0.1 KB", 100), ("1.0", 1)] as [(String, Int64)] {
            XCTAssertEqual(try FileSizeInput.bytes(input), expected, input)
        }
        for input in ["0.1KiB", "0.5 B", "0.0001 KB"] {
            XCTAssertThrowsError(try FileSizeInput.bytes(input)) { XCTAssertEqual($0 as? FileSizeInput.Failure, .fractionalByte) }
        }
    }

    func testInt64BoundaryIsExactWithLargeFractionalUnits() throws {
        XCTAssertEqual(try FileSizeInput.bytes("9223372036854775807"), Int64.max)
        XCTAssertEqual(try FileSizeInput.bytes("9223372.036854775807 TB"), Int64.max)
        for input in ["9223372036854775808", "9223372.036854775808 TB", "8388608 TiB", "999999999999999999999999999999999999"] {
            XCTAssertThrowsError(try FileSizeInput.bytes(input)) { XCTAssertEqual($0 as? FileSizeInput.Failure, .tooLarge) }
        }
    }

    func testEmptyAndLegacyWholeByteInputsKeepTheirMeaning() throws {
        XCTAssertNil(try FileSizeInput.bytes(" \t"))
        for input in ["0", "-0", "-00", "+0"] { XCTAssertEqual(try FileSizeInput.bytes(input), 0) }
        XCTAssertEqual(try FileSizeInput.bytes("\t +001536 \t"), 1536)
        XCTAssertEqual(try FileSizeInput.bytes("\u{00a0}12\u{00a0}"), 12)
        XCTAssertThrowsError(try FileSizeInput.bytes("-1")) { XCTAssertEqual($0 as? FileSizeInput.Failure, .negativeValue) }
    }

    func testBoundedGrammarRejectsAmbiguityAndHostilePastes() {
        for input in ["1,000", "1,5 MB", "1e3", "NaN", "1_024", "1+2", "1 M B", "2G", "1 PB", "1MBx", ".", "1.", "+", "--0", "1\n", "1\0", "١ KB", "１ KB", "1 KıB", "0.0000000000001TB", String(repeating: "0", count: 65), String(repeating: " ", count: 1_000_000)] {
            XCTAssertThrowsError(try FileSizeInput.bytes(input), input.prefix(32).description)
        }
        XCTAssertEqual(try FileSizeInput.bytes(String(repeating: "0", count: 64)), 0)
    }

    func testParsedBoundsPreserveInclusiveMetadataAndLiteralFilenameMatching() throws {
        let request = try SearchRequest(filename: "[report]*", byteRange: XCTUnwrap(FileSizeInput.bytes("1KiB"))...XCTUnwrap(FileSizeInput.bytes("2KiB")))
        func entry(_ bytes: Int64?) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/Generated/[report]*.txt"), name: "[report]*.txt", kind: .file,
                byteCount: bytes)
        }
        XCTAssertTrue(request.matches(entry(1024)))
        XCTAssertTrue(request.matches(entry(2048)))
        XCTAssertFalse(request.matches(entry(1023)))
        XCTAssertFalse(request.matches(entry(2049)))
        XCTAssertFalse(request.matches(entry(nil)))
        XCTAssertFalse(try SearchRequest(filename: "[report]*", byteRange: 1024...2048).matches(
            FileEntry(url: URL(fileURLWithPath: "/Generated/report.txt"), name: "report.txt", kind: .file, byteCount: 1536)))
    }
}
