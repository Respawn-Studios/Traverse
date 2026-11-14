import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class RemoteItemObservationTests: XCTestCase {
    private func smb(_ name: String, attributes: UInt32 = 0, bytes: UInt64 = 19, time: UInt64 = 116_444_736_000_000_000) throws -> SMBDirectoryObservation {
        .init(id: 1, name: try .init(name), attributes: attributes, logicalBytes: bytes, modifiedFileTime: time)
    }
    private func sftp(_ name: String, mode: UInt32? = 0o100644, bytes: UInt64? = 19, time: UInt32? = 0) throws -> SFTPStoredRow {
        .init(observation: 1, entry: .init(name: try .init(Data(name.utf8)), logicalBytes: bytes, modifiedSeconds: time, permissions: mode))
    }
    func testSMBShareRelativeUnicodeSpellingAndPlainText() throws {
        let name = "Cafe\u{301} 50% #draft.txt"
        let value = try RemoteItemObservation(smb: smb(name), directory: [.init("Folder")], share: .init("Studio"), listingComplete: true)
        XCTAssertEqual(value.pathRoot,.smbShare("Studio")); XCTAssertEqual(value.name,name)
        XCTAssertEqual(Data(value.copyName!.utf8),Data(name.utf8))
        XCTAssertEqual(value.copyPath,"Folder/" + name); XCTAssertEqual(value.displayPath,value.copyPath)
        XCTAssertEqual(value.kind,.file); XCTAssertEqual(value.logicalBytes,19)
        XCTAssertEqual(value.modified,Date(timeIntervalSince1970:0)); XCTAssertNil(value.permissions); XCTAssertTrue(value.listingComplete)
        XCTAssertFalse(value.copyPath!.contains("file://"))
    }
    func testSMBFolderAndReparseSizeNeverPretendRecursiveContentTotals() throws {
        for (attributes,kind) in [(UInt32(16),RemoteItemObservation.Kind.folder),(UInt32(0x400),.link),(UInt32(0x410),.link)] {
            let value = try RemoteItemObservation(smb:smb("Item",attributes:attributes,bytes:UInt64.max,time:0),directory:[],share:.init("Share"),listingComplete:false)
            XCTAssertEqual(value.kind,kind); XCTAssertNil(value.logicalBytes); XCTAssertNil(value.modified); XCTAssertFalse(value.listingComplete)
        }
        let huge = try RemoteItemObservation(smb:smb("Item",bytes:UInt64.max,time:UInt64.max),directory:[],share:.init("Share"),listingComplete:true)
        XCTAssertEqual(huge.logicalBytes,UInt64.max); XCTAssertNil(huge.modified)
    }
    func testSFTPAbsoluteAndHomeRelativePathsStayDifferent() throws {
        for home in [false,true] {
            let value = try RemoteItemObservation(sftp:sftp("file\\name %25.txt"),directory:[.init(Data("Reports".utf8))],homeRelative:home,listingComplete:true)
            XCTAssertEqual(value.copyPath,(home ? "./" : "/") + "Reports/file\\name %25.txt")
            XCTAssertEqual(value.pathRoot,home ? .sftpHome : .sftpAbsolute)
            XCTAssertEqual(value.name,"file\\\\name %25.txt"); XCTAssertEqual(value.logicalBytes,19)
            XCTAssertEqual(value.modified,Date(timeIntervalSince1970:0)); XCTAssertEqual(value.permissions,0o100644)
        }
        let root = try RemoteItemObservation(sftp:sftp("root.txt"),directory:[],homeRelative:false,listingComplete:true)
        XCTAssertEqual(root.copyPath,"/root.txt")
    }
    func testEscapedControlsAndBidiCannotBecomeClipboardLines() throws {
        for unsafe in ["line\nnext","tab\tname","line\u{2028}next","line\u{2029}next","name\u{202e}txt","name\u{061c}txt","name\u{2069}"] {
            let value = try RemoteItemObservation(sftp:sftp(unsafe),directory:[],homeRelative:true,listingComplete:true)
            XCTAssertNil(value.copyName); XCTAssertNil(value.copyPath); XCTAssertTrue(value.name.contains("\\u{"))
            XCTAssertFalse(value.displayPath.contains("\n")); XCTAssertFalse(value.displayPath.contains("\u{202e}"))
            let parent = try RemoteItemObservation(sftp:sftp("safe.txt"),directory:[.init(Data(unsafe.utf8))],homeRelative:false,listingComplete:true)
            XCTAssertEqual(parent.copyName,"safe.txt"); XCTAssertNil(parent.copyPath)
        }
    }
    func testUnknownModeMissingMetadataAndNonFileKinds() throws {
        let absent = try RemoteItemObservation(sftp:sftp("Unknown",mode:nil,bytes:UInt64.max,time:nil),directory:[],homeRelative:true,listingComplete:false)
        XCTAssertEqual(absent.kind,.unknown); XCTAssertNil(absent.permissions); XCTAssertNil(absent.modified); XCTAssertNil(absent.logicalBytes)
        for (mode,kind) in [(UInt32(0o040755),RemoteItemObservation.Kind.folder),(0o120777,.link),(0o140644,.other)] {
            let value = try RemoteItemObservation(sftp:sftp("Item",mode:mode,bytes:UInt64.max,time:UInt32.max),directory:[],homeRelative:true,listingComplete:true)
            XCTAssertEqual(value.kind,kind); XCTAssertNil(value.logicalBytes); XCTAssertEqual(value.modified,Date(timeIntervalSince1970:TimeInterval(UInt32.max)))
        }
        let empty = try RemoteItemObservation(sftp:sftp("Empty",bytes:0),directory:[],homeRelative:false,listingComplete:true)
        XCTAssertEqual(empty.logicalBytes,0)
    }
    func testBoundsRefuseUnboundedDescriptionsBeforeBuildingStrings() throws {
        XCTAssertThrowsError(try RemoteItemObservation(smb:smb("file"),directory:Array(repeating:SMBRemoteName("a"),count:129),share:.init("Share"),listingComplete:true))
        let large = try SFTPRemoteName(Data(repeating:97,count:8192))
        XCTAssertThrowsError(try RemoteItemObservation(sftp:sftp("file"),directory:[large,large],homeRelative:false,listingComplete:true))
        let largestAllowed = try RemoteItemObservation(sftp:sftp("file"),directory:[large],homeRelative:true,listingComplete:false)
        XCTAssertNotNil(largestAllowed.copyPath); XCTAssertEqual(largestAllowed.pathRoot,.sftpHome)
    }
}
