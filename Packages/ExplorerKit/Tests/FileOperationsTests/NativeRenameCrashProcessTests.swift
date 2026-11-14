import Darwin
import Foundation
import Testing
@testable import FileOperations

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RENAME_CRASH_ACTION"] != nil))
struct NativeRenameCrashProcessTests {
    @Test func child() async throws {
        let env=ProcessInfo.processInfo.environment
        let text=try #require(env["MAC_EXPLORER_RENAME_SECURITY_TEST_ROOT"])
        let base=URL(fileURLWithPath:text)
        var repo=URL(fileURLWithPath:#filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        try #require(base.lastPathComponent == "source" && base.resolvingSymlinksInPath() == base
            && base.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            && UUID(uuidString:base.deletingLastPathComponent().lastPathComponent) != nil)
        let rawAction=try #require(env["MAC_EXPLORER_RENAME_CRASH_ACTION"])
        let reversing=rawAction.hasPrefix("reverse-")
        let action=reversing ? String(rawAction.dropFirst("reverse-".count)) : rawAction
        let root=base.appendingPathComponent(reversing ? "ReverseCrash" : "Crash",isDirectory:true)
        let source=root.appendingPathComponent("Generated.txt")
        let destination=root.appendingPathComponent("Destination",isDirectory:true)
        let output=destination.appendingPathComponent("Generated.txt")
        let journal=root.appendingPathComponent("history",isDirectory:true)
        if action == "interrupt" {
            try FileManager().createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try FileManager().createDirectory(at:destination,withIntermediateDirectories:false)
            try Data("Exact generated crash bytes.\n".utf8).write(to:source,options:.withoutOverwriting)
            var reverseID:UUID?
            if reversing {
                let result=await RecoverableFileOperations(journalDirectory:journal)
                    .perform(.copy(sources:[source],destinationDirectory:destination))
                try #require(result.result.disposition == .succeeded)
                let copiedID:UUID=try #require(result.recordID)
                reverseID=copiedID
            }
            // Both directions are interrupted immediately after the native move.
            let target=NativeCrashTarget()
            var hooks=RecoveryHooks()
            hooks.beforeExclusiveRename={ _,destination in target.set(destination) }
            hooks.afterRename={
                let bytes=Data("0082;67000001;GeneratedCrashBaseline;".utf8)
                let fd=open(target.get().path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
                precondition(fd>=0)
                precondition(bytes.withUnsafeBytes { fsetxattr(fd,"com.apple.quarantine",$0.baseAddress,bytes.count,0,0) }==0)
                close(fd)
                Self.emit(["phase":"crash", "pid":getpid(), "afterNativeRenameBeforeAfterImage":true,"reverse":reversing])
                _exit(86)
            }
            let engine=RecoverableFileOperations(journalDirectory:journal,hooks:hooks)
            if let reverseID { _ = await engine.undo(recordID:reverseID) }
            else { _ = await engine.perform(.move(sources:[source],destinationDirectory:destination)) }
            Issue.record("The exact native interruption was not reached")
        } else {
            let engine=RecoverableFileOperations(journalDirectory:journal)
            let records=try await engine.inspectExistingHistory()
            let record=try #require(records.records.first)
            try #require(records.records.count==1 && records.refusedEntries.isEmpty && !record.canUndo)
            var failureCodes:[String]=[]
            if action == "recover" {
                let result=await engine.recover(recordID:record.id)
                try #require(result.result.disposition == .failed)
                failureCodes=result.result.items.compactMap { if case .failed(let value)=$0.status { value.rawValue } else { nil } }
                try #require(!failureCodes.isEmpty)
                if !reversing { try #require(failureCodes.contains(FileOperationFailure.recoveryUncertain.rawValue)) }
                try #require(try await engine.inspectExistingHistory().records.first?.state == "needsReview")
            } else { try #require(action == "inspect") }
            let retained:URL
            if reversing {
                let storage=try OperationJournal(journal)
                let saved=try storage.inspectRecord(record.id)
                let step=try #require(saved?.steps.last)
                retained=step.source
                try #require(retained.lastPathComponent == "payload"
                    && retained.deletingLastPathComponent().deletingLastPathComponent() == destination
                    && retained.deletingLastPathComponent().lastPathComponent.hasPrefix(".mac-explorer-recovery-"))
            } else { retained=output }
            try #require(FileManager().fileExists(atPath:source.path) == reversing)
            if reversing { try #require(!FileManager().fileExists(atPath:output.path)) }
            try #require(Data(contentsOf:retained)==Data("Exact generated crash bytes.\n".utf8))
            Self.emit(["phase":action,"pid":getpid(),"passed":true,"uncertaintyPreserved":true,"reverse":reversing,"failureCodes":failureCodes])
        }
    }
    private static func emit(_ value:[String:Any]) {
        print("TRAVERSE_RENAME_CHILD "+String(decoding:try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self))
        fflush(stdout)
    }
}

private final class NativeCrashTarget: @unchecked Sendable {
    private let lock=NSLock()
    private var value:URL?
    func set(_ url:URL) { lock.withLock { value=url } }
    func get() -> URL { lock.withLock { value! } }
}
