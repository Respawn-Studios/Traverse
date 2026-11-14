import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

/// Driven only in separate test processes by the admitted packet wrapper.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_ROOT"] != nil))
struct ZIPExtractionProcessTests {
    @Test func child() async throws {
        let env = ProcessInfo.processInfo.environment
        let admitted = URL(fileURLWithPath: try #require(env["MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_ROOT"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-extraction")
            && admitted.resolvingSymlinksInPath() == admitted && UUID(uuidString: admitted.lastPathComponent) != nil
            && FileManager().fileExists(atPath: admitted.appendingPathComponent("reservation.json").path))
        let root = admitted.appendingPathComponent("source/Process"), archive = root.appendingPathComponent("Generated.zip")
        let parent = root.appendingPathComponent("Destination"), journal = root.appendingPathComponent("journal")
        let action = try #require(env["MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_ACTION"])
        let boundary = try #require(env["MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_BOUNDARY"])
        let quarantine = env["MAC_EXPLORER_ZIP_EXTRACTION_PROCESS_QUARANTINE"] == "1"
        let security = Data("0081;65000001;MacExplorer-B09-Qualification;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        let beforeIntent = ["payloadCreated", "produced", "synced"].contains(boundary)
        if action == "forward" || action == "reverse" {
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try GeneratedZIP.bytes([.init("Folder/Report.txt"), .init("Empty/", mode: 0x4000, bytes: Data())])
                .write(to: archive, options: .withoutOverwriting)
            if quarantine {
                try #require(security.withUnsafeBytes { setxattr(archive.path,"com.apple.quarantine",$0.baseAddress,$0.count,0,XATTR_CREATE) } == 0)
            }
            var hooks = RecoveryHooks()
            if action == "forward" {
                hooks.archiveProduction.stage = { stage, _ in if stage.rawValue == boundary { Self.crash(boundary) } }
                hooks.afterIntent = { if boundary == "intent" { Self.crash(boundary) } }
                hooks.afterRename = { if boundary == "rename" { Self.crash(boundary) } }
            }
            let engine = RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
            let selection = try await engine.observeSelection([archive])
            let plan = try await engine.prepareArchiveExtraction(source:archive,parent:parent,name:"Extracted",observing:selection) { check in
                try PreparedZIPDirectory(archive,check:check,hooks:.init(inheritsQuarantine:quarantine))
            }
            let result = await engine.performArchiveExtraction(plan)
            try #require(result.result.disposition == .succeeded)
            if action == "reverse" {
                var reverse = RecoveryHooks()
                reverse.beforeRename = { if boundary == "reverse-before" { Self.crash(boundary) } }
                reverse.afterRename = { if boundary == "reverse-rename" { Self.crash(boundary) } }
                let cold = RecoverableFileOperations(journalDirectory: journal, hooks: reverse)
                _ = await cold.undo(recordID: try #require(result.recordID))
            }
            Issue.record("Requested extraction interruption did not occur")
        } else {
            let engine = RecoverableFileOperations(journalDirectory: journal)
            let inspection = try await engine.inspectExistingHistory(), record = try #require(inspection.records.first)
            try #require(inspection.records.count == 1 && inspection.refusedEntries.isEmpty && record.operation == "Extract ZIP")
            var report: [String: Any] = ["event": action, "pid": getpid(), "recordID": record.id.uuidString, "passed": true]
            if quarantine {
                var bytes=Data(count:security.count)
                try #require(bytes.withUnsafeMutableBytes { getxattr(archive.path,"com.apple.quarantine",$0.baseAddress,$0.count,0,0) } == security.count && bytes == security)
                report["sourceQuarantineUnchanged"] = true
            }
            if action == "recover" {
                let recovered = record.canUndo ? await engine.undo(recordID: record.id) : await engine.recover(recordID: record.id)
                try #require((recovered.result.disposition == .succeeded) == !beforeIntent)
                let retained = try await engine.retentionRecord(recordID: record.id)
                try #require(retained.canCleanup == !beforeIntent)
                try #require(!FileManager().fileExists(atPath: parent.appendingPathComponent("Extracted").path))
                let expected = GeneratedZIP.bytes([.init("Folder/Report.txt"), .init("Empty/", mode: 0x4000, bytes: Data())])
                try #require(Data(SHA256.hash(data: Data(contentsOf: archive))) == Data(SHA256.hash(data: expected)))
                report["recoverSucceeded"] = recovered.result.disposition == .succeeded
                report["cleanupQualified"] = retained.canCleanup
                report["sourceUnchanged"] = true
            } else { try #require(action == "inspect") }
            Self.emit(report)
        }
    }
    private static func emit(_ report: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("MAC_EXPLORER_ARCHIVE_CHILD " + String(decoding: bytes, as: UTF8.self)); fflush(stdout)
    }
    private static func crash(_ boundary: String) -> Never {
        emit(["event": "crash", "boundary": boundary, "pid": getpid(), "exit": 86]); _exit(86)
    }
}
