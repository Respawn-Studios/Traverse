import Foundation
import Testing

@testable import ExplorerCore

struct IncomingFolderURLTests {
    @Test func retainsExactURLAndDeduplicatesLexicalPaths() throws {
        let first = URL(fileURLWithPath: "/tmp/Café 文件/100% complete", isDirectory: true)
        let alternate = URL(fileURLWithPath: "/tmp/Café 文件/child/../100% complete")
        let other = URL(fileURLWithPath: "/tmp/second")
        let result = try IncomingFolderURLs.admit([first, alternate, other])
        #expect(result == [first, other])
        #expect(result[0].absoluteString == first.absoluteString)
        #expect(try IncomingFolderURLs.admit([URL(fileURLWithPath: "/")]).count == 1)
    }
    @Test func refusesSchemesCredentialsRemoteHostsAndURLDecorations() throws {
        for text in [
            "https://example.com/folder", "smb://server/share", "file://server/share/folder",
            "file://user:secret@localhost/tmp/Folder", "file:///tmp/Folder?query", "file:///tmp/Folder#section",
            "file:///tmp/line%0Abreak", "file:///tmp/nul%00byte",
        ] {
            let value = try #require(URL(string: text))
            #expect(throws: IncomingFolderURLs.Failure.unsupportedURL) { try IncomingFolderURLs.admit([value]) }
        }
    }
    @Test func boundsWholeBatchAndRejectsInvalidBatchAtomically() throws {
        let value = URL(fileURLWithPath: "/tmp/Folder")
        #expect(throws: IncomingFolderURLs.Failure.batchLimit) { try IncomingFolderURLs.admit([]) }
        #expect(throws: IncomingFolderURLs.Failure.batchLimit) {
            try IncomingFolderURLs.admit(Array(repeating: value, count: 17))
        }
        #expect(try IncomingFolderURLs.admit((0..<16).map { URL(fileURLWithPath: "/tmp/Folder\($0)") }).count == 16)
        #expect(throws: IncomingFolderURLs.Failure.unsupportedURL) {
            try IncomingFolderURLs.admit([value, URL(string: "smb://server/share")!])
        }
        #expect(throws: IncomingFolderURLs.Failure.unsupportedURL) {
            try IncomingFolderURLs.admit([URL(fileURLWithPath: "/" + String(repeating: "a", count: 4097))])
        }
    }
}
