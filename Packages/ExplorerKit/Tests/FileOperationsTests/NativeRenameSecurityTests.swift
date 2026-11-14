import Darwin
import Foundation
import Testing
@testable import FileOperations

private struct RenameSecurityFixture {
    let root: URL, source: URL, destination: URL, journal: URL
    init(folder: Bool = false) throws {
        let base = try FileOperationTestFixtures.base(
            legacyVariable: "MAC_EXPLORER_RENAME_SECURITY_TEST_ROOT", legacyParent: "traverse-release")
        root = base.appendingPathComponent("rename-security-"+UUID().uuidString,isDirectory:true)
        try FileManager().createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        source = root.appendingPathComponent(folder ? "Generated Folder" : "Generated.txt")
        destination = root.appendingPathComponent("Destination",isDirectory:true)
        journal = root.appendingPathComponent("history",isDirectory:true)
        try FileManager().createDirectory(at:destination,withIntermediateDirectories:false)
        if folder { try FileManager().createDirectory(at:source,withIntermediateDirectories:false) }
        try Data("Exact generated rename bytes.\n".utf8).write(to:folder ? source.appendingPathComponent("Child.txt") : source,options:.withoutOverwriting)
    }
    var output: URL { destination.appendingPathComponent(source.lastPathComponent) }
}
private let renameCreatedMark = Data("0082;67000001;GeneratedRenameBaseline;".utf8)
private func renameSecurityAttribute(_ url:URL, _ name:String, _ value:Data?) throws {
    let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    guard fd>=0 else { throw posixFailure() }; defer { close(fd) }
    let result=value.map { bytes in bytes.withUnsafeBytes { fsetxattr(fd,name,$0.baseAddress,bytes.count,0,0) } }
        ?? fremovexattr(fd,name,0)
    guard result==0 else { throw posixFailure() }
}
private final class ReverseRenameTarget: @unchecked Sendable {
    private let lock=NSLock()
    private var value:URL?
    func set(_ url:URL) { lock.withLock { value=url } }
    func get() -> URL { lock.withLock { value! } }
}

@Suite(.serialized) struct NativeRenameSecurityTests {
    @Test func nativeOriginProjectionRequiresTheExactCreationBaselineAndEveryOtherField() throws {
        // Pure policy control: this host ignores attempts to set provenance.
        // Actual provenance-changing acceptance belongs to the marked app check.
        let f=try RenameSecurityFixture()
        let tree=try verifiedTree(f.source,cancellation:.init())
        let old=Data("generated old native origin".utf8),current=Data("generated current native origin".utf8)
        let unrelated=Data("unrelated origin".utf8),origin=SecurityAttribute(current)
        func image(_ provenance:Data?,_ q:Data?,_ content:String="same exact content and metadata") -> NativeRenameSecurityProjection {
            let p=NativeRenameSecurityProjection();p.append(Data(content.utf8))
            if let provenance { p.observeRootProvenance(provenance) }
            if let q { p.observeRootQuarantine(q) }
            return p
        }
        let before=image(old,nil)
        #expect(before.permitsNativeTransition(to:image(current,renameCreatedMark),before:tree,after:tree,origin:origin))
        #expect(before.permitsNativeTransition(to:image(current,nil),before:tree,after:tree,origin:origin))
        #expect(!before.permitsNativeTransition(to:image(current,renameCreatedMark),before:tree,after:tree,origin:nil))
        #expect(!before.permitsNativeTransition(to:image(unrelated,renameCreatedMark),before:tree,after:tree,origin:origin))
        #expect(!before.permitsNativeTransition(to:image(nil,renameCreatedMark),before:tree,after:tree,origin:origin))
        #expect(!before.permitsNativeTransition(to:image(current,renameCreatedMark,"changed metadata"),before:tree,after:tree,origin:origin))
        #expect(!image(old,renameCreatedMark).permitsNativeTransition(to:image(current,nil),before:tree,after:tree,origin:origin))
        #expect(!image(old,renameCreatedMark).permitsNativeTransition(to:image(current,Data("different quarantine".utf8)),before:tree,after:tree,origin:origin))
    }

    @Test func aNewCopyMayKeepItsOwnExactNativeCreationProvenance() throws {
        let f=try RenameSecurityFixture(),tree=try verifiedTree(f.source,cancellation:.init())
        let original=SecurityAttribute(Data("original creator".utf8)),created=SecurityAttribute(Data("current creator".utf8))
        let unrelated=SecurityAttribute(Data("unrelated creator".utf8))
        func permits(_ after:SecurityAttribute?,sourceAfter:SecurityAttribute?=nil) -> Bool {
            NativeCopyReceipt(relative:"",source:tree.identity,destination:tree.identity,destinationBeforeIdentity:tree.identity,
                destinationOwnership:.init(uid:geteuid(),gid:getegid()),sourceBefore:.init(provenance:original),
                destinationBefore:.init(provenance:created),sourceAfter:.init(provenance:sourceAfter ?? original),
                destinationAfter:.init(provenance:after)).permitsSecurityTransition()
        }
        #expect(permits(created))
        #expect(permits(original))
        #expect(!permits(nil))
        #expect(!permits(unrelated))
        #expect(!permits(created,sourceAfter:unrelated))
    }

    @Test func privateCreationOriginLeavesNoFileAndRefusesAnUnprivateDirectory() throws {
        let f=try RenameSecurityFixture()
        let before=try FileManager().contentsOfDirectory(atPath:f.root.path).sorted()
        let sampled = try NativeProcessSecurityOrigin.sample(in:f.root)
        #expect(NativeProcessSecurityOrigin.current == sampled)
        let fd=open(f.source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        try #require(fd>=0);defer { close(fd) }
        #expect(try CopySecurity.read(fd).provenance == sampled)
        #expect(try FileManager().contentsOfDirectory(atPath:f.root.path).sorted()==before)
        #expect(chmod(f.destination.path,0o777)==0)
        #expect(throws:FileOperationFailure.accessDenied) { try NativeProcessSecurityOrigin.sample(in:f.destination) }
        #expect(try FileManager().contentsOfDirectory(atPath:f.destination.path).isEmpty)
    }

    @Test func oldCopyUndoMayGainOneRootMarkAndPersistsItsCompleteReverseImage() async throws {
        for folder in [false,true] {
            let f=try RenameSecurityFixture(folder:folder)
            let original=try verifiedTree(f.source,cancellation:.init())
            let copied=await RecoverableFileOperations(journalDirectory:f.journal)
                .perform(.copy(sources:[f.source],destinationDirectory:f.destination))
            #expect(copied.result.disposition == .succeeded)
            let id=try #require(copied.recordID)
            let originalStep=try { () throws -> JournalStep in
                let priorJournal=try OperationJournal(f.journal)
                let value=try priorJournal.inspectRecord(id)
                return try #require(value?.steps.last)
            }()
            let target=ReverseRenameTarget()
            var hooks=RecoveryHooks()
            hooks.beforeExclusiveRename={ _,destination in target.set(destination) }
            hooks.afterRename={ try! renameSecurityAttribute(target.get(),CopySecurity.quarantineName,renameCreatedMark) }
            let undone=await RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks).undo(recordID:id)
            #expect(undone.result.disposition == .succeeded)
            #expect(original.matches(try verifiedTree(f.source,cancellation:.init())))
            #expect(!FileManager().fileExists(atPath:f.output.path))
            let image=try verifiedTree(target.get(),cancellation:.init())
            let record=try { () throws -> JournalRecord in
                let journal=try OperationJournal(f.journal)
                let readback=try journal.inspectRecord(id)
                return try #require(readback)
            }()
            #expect(record.state == "undone")
            #expect(record.steps.last?.before == originalStep.before)
            #expect(record.steps.last?.after?.matches(image)==true)
            let cold=RecoverableFileOperations(journalDirectory:f.journal)
            #expect(try await cold.retentionRecord(recordID:id).canCleanup)
            try renameSecurityAttribute(target.get(),CopySecurity.quarantineName,Data("0082;67000009;LaterReverseEdit;".utf8))
            #expect(try await !cold.retentionRecord(recordID:id).canCleanup)
        }
    }

    @Test func replacementUndoRecordsBothReverseImagesAndStillVerifiesRecoveryAreas() async throws {
        let f=try RenameSecurityFixture()
        try Data("Exact displaced generated bytes.\n".utf8).write(to:f.output,options:.withoutOverwriting)
        let ordinary=RecoverableFileOperations(journalDirectory:f.journal)
        let plan=try await ordinary.prepareTransfer(sources:[f.source],destinationDirectory:f.destination,move:false)
        let copied=await ordinary.perform(plan,resolutions:Dictionary(uniqueKeysWithValues:plan.conflicts.map { ($0.id,.replace) }))
        #expect(copied.result.disposition == .succeeded)
        let target=ReverseRenameTarget();var hooks=RecoveryHooks()
        hooks.beforeExclusiveRename={ _,destination in target.set(destination) }
        hooks.afterRename={ try! renameSecurityAttribute(target.get(),CopySecurity.quarantineName,renameCreatedMark) }
        let id=try #require(copied.recordID)
        let undone=await RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks).undo(recordID:id)
        #expect(undone.result.disposition == .succeeded)
        #expect(try Data(contentsOf:f.output)==Data("Exact displaced generated bytes.\n".utf8))
        #expect(try Data(contentsOf:f.source)==Data("Exact generated rename bytes.\n".utf8))
        let cold=RecoverableFileOperations(journalDirectory:f.journal)
        let retention=try await cold.retentionRecord(recordID:id)
        #expect(retention.canCleanup && retention.areas.allSatisfy(\.verified))
        let area=try #require(retention.areas.first { FileManager().fileExists(atPath:$0.url.appendingPathComponent("payload").path) })
        try Data("Changed retained generated copy.\n".utf8).write(to:area.url.appendingPathComponent("payload"))
        #expect(try await !cold.retentionRecord(recordID:id).canCleanup)
    }

    @Test func reverseSyncFailureKeepsTheOldDurableImageAndRefusesGuessedRecovery() async throws {
        let f=try RenameSecurityFixture()
        let copied=await RecoverableFileOperations(journalDirectory:f.journal)
            .perform(.copy(sources:[f.source],destinationDirectory:f.destination))
        #expect(copied.result.disposition == .succeeded)
        let id=try #require(copied.recordID)
        let target=ReverseRenameTarget();var hooks=RecoveryHooks()
        hooks.beforeExclusiveRename={ _,destination in target.set(destination) }
        hooks.afterRename={ try! renameSecurityAttribute(target.get(),CopySecurity.quarantineName,renameCreatedMark) }
        hooks.beforeSync={ _ in throw FileOperationFailure.ioFailure }
        let undone=await RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks).undo(recordID:id)
        #expect(undone.result.disposition == .failed)
        #expect(try Data(contentsOf:target.get())==Data("Exact generated rename bytes.\n".utf8))
        let cold=RecoverableFileOperations(journalDirectory:f.journal)
        #expect(await cold.recover(recordID:id).result.disposition == .failed)
        #expect(try await cold.inspectExistingHistory().records.first?.state == "needsReview")
        #expect(try await !cold.retentionRecord(recordID:id).canCleanup)
    }

    @Test func reverseAdditionCannotHideChangedContentOrReplaceAnExistingMark() async throws {
        for existing in [false,true] {
            let f=try RenameSecurityFixture()
            if existing { try renameSecurityAttribute(f.source,CopySecurity.quarantineName,renameCreatedMark) }
            let copied=await RecoverableFileOperations(journalDirectory:f.journal)
                .perform(.copy(sources:[f.source],destinationDirectory:f.destination))
            #expect(copied.result.disposition == .succeeded)
            let target=ReverseRenameTarget();var hooks=RecoveryHooks()
            hooks.beforeExclusiveRename={ _,destination in target.set(destination) }
            hooks.afterRename={
                try! renameSecurityAttribute(target.get(),CopySecurity.quarantineName,
                    existing ? Data("0082;67000004;Rewritten;".utf8) : renameCreatedMark)
                if !existing { try! Data("Changed during generated reverse".utf8).write(to:target.get()) }
            }
            let engine=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
            let undone=await engine.undo(recordID:try #require(copied.recordID))
            #expect(undone.result.items.contains { $0.status == .failed(.recoveryUncertain) })
            #expect(FileManager().fileExists(atPath:target.get().path))
            #expect(try await engine.inspectExistingHistory().records.first?.state == "needsReview")
        }
    }

    @Test func nativeRootQuarantineAdditionCompletesAndColdUndoKeepsItsExactMark() async throws {
        for folder in [false,true] {
            let f=try RenameSecurityFixture(folder:folder)
            let before=try verifiedTree(f.source,cancellation:.init())
            var hooks=RecoveryHooks()
            hooks.afterRename={ try! renameSecurityAttribute(f.output,CopySecurity.quarantineName,renameCreatedMark) }
            let service=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
            let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
            #expect(moved.result.disposition == .succeeded)
            let id=try #require(moved.recordID)
            let after=try verifiedTree(f.output,cancellation:.init())
            #expect(!before.matches(after)) // Never redefine the persisted full guard.
            let cold=RecoverableFileOperations(journalDirectory:f.journal)
            #expect(await cold.undo(recordID:id).result.disposition == .succeeded)
            #expect(after.matches(try verifiedTree(f.source,cancellation:.init())))
            #expect(!FileManager().fileExists(atPath:f.output.path))
        }
    }

    @Test func changedOrRemovedExistingMarkAndEmptyAdditionsRemainUncertain() async throws {
        for mode in ["changed","removed","empty"] {
            let f=try RenameSecurityFixture()
            if mode != "empty" { try renameSecurityAttribute(f.source,CopySecurity.quarantineName,renameCreatedMark) }
            var hooks=RecoveryHooks()
            hooks.afterRename={
                try! renameSecurityAttribute(f.output,CopySecurity.quarantineName,
                    mode == "removed" ? nil : (mode == "empty" ? Data() : Data("0082;67000002;Changed;".utf8)))
            }
            let service=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
            let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
            #expect(moved.result.items.contains { $0.status == .failed(.recoveryUncertain) })
            #expect(FileManager().fileExists(atPath:f.output.path))
            #expect(try await service.inspectExistingHistory().records.first?.state == "needsReview")
        }
    }

    @Test func securityAdditionCannotHideContentsMetadataOrDescendantChanges() async throws {
        // This host silently ignores writes to com.apple.provenance. Do not
        // claim an injected provenance change from a successful setter alone.
        for mode in ["contents","mode","custom","child-quarantine"] {
            let f=try RenameSecurityFixture(folder:mode == "child-quarantine")
            var hooks=RecoveryHooks()
            hooks.afterRename={
                try! renameSecurityAttribute(f.output,CopySecurity.quarantineName,renameCreatedMark)
                switch mode {
                case "contents": try! Data("different generated contents".utf8).write(to:f.output)
                case "mode": precondition(chmod(f.output.path,0o400)==0)
                case "custom": try! renameSecurityAttribute(f.output,"com.respawnstudios.generated",Data("changed".utf8))
                default: try! renameSecurityAttribute(f.output.appendingPathComponent("Child.txt"),CopySecurity.quarantineName,renameCreatedMark)
                }
            }
            let service=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
            let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
            #expect(moved.result.disposition == .failed, Comment(rawValue:mode))
            #expect(FileManager().fileExists(atPath:f.output.path))
            #expect(try await service.inspectExistingHistory().records.first?.state == "needsReview")
        }
    }

    @Test func aLaterMarkEditStillRefusesUndoAndRetainsDestination() async throws {
        let f=try RenameSecurityFixture()
        var hooks=RecoveryHooks()
        hooks.afterRename={ try! renameSecurityAttribute(f.output,CopySecurity.quarantineName,renameCreatedMark) }
        let service=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
        let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
        #expect(moved.result.disposition == .succeeded)
        try renameSecurityAttribute(f.output,CopySecurity.quarantineName,Data("0082;67000003;Later;".utf8))
        let cold=RecoverableFileOperations(journalDirectory:f.journal)
        #expect(await cold.undo(recordID:try #require(moved.recordID)).result.disposition == .failed)
        #expect(FileManager().fileExists(atPath:f.output.path))
        #expect(!FileManager().fileExists(atPath:f.source.path))
    }

    @Test func preexistingExactMarkSurvivesOrdinaryMoveAndUndo() async throws {
        let f=try RenameSecurityFixture()
        try renameSecurityAttribute(f.source,CopySecurity.quarantineName,renameCreatedMark)
        let before=try verifiedTree(f.source,cancellation:.init())
        let service=RecoverableFileOperations(journalDirectory:f.journal)
        let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
        #expect(moved.result.disposition == .succeeded)
        #expect(before.matches(try verifiedTree(f.output,cancellation:.init())))
        #expect(await service.undo(recordID:try #require(moved.recordID)).result.disposition == .succeeded)
        #expect(before.matches(try verifiedTree(f.source,cancellation:.init())))
    }

    @Test func additionBeforeTheFinalSourceFenceIsRefusedWithoutMoving() async throws {
        let f=try RenameSecurityFixture()
        var hooks=RecoveryHooks()
        hooks.afterIntent={ try! renameSecurityAttribute(f.source,CopySecurity.quarantineName,renameCreatedMark) }
        let service=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
        let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
        #expect(moved.result.items.contains { $0.status == .failed(.sourceChanged) })
        #expect(FileManager().fileExists(atPath:f.source.path))
        #expect(!FileManager().fileExists(atPath:f.output.path))
    }

    @Test func failedSyncDoesNotInventAnAfterImageOrWeakenCrashReconciliation() async throws {
        let f=try RenameSecurityFixture()
        var hooks=RecoveryHooks()
        hooks.afterRename={ try! renameSecurityAttribute(f.output,CopySecurity.quarantineName,renameCreatedMark) }
        hooks.beforeSync={ _ in throw FileOperationFailure.ioFailure }
        let service=RecoverableFileOperations(journalDirectory:f.journal,hooks:hooks)
        let moved=await service.perform(.move(sources:[f.source],destinationDirectory:f.destination))
        #expect(moved.result.disposition == .failed)
        let cold=RecoverableFileOperations(journalDirectory:f.journal)
        let recovered=await cold.recover(recordID:try #require(moved.recordID))
        #expect(recovered.result.disposition == .failed)
        #expect(FileManager().fileExists(atPath:f.output.path))
        #expect(!FileManager().fileExists(atPath:f.source.path))
        #expect(try await cold.inspectExistingHistory().records.first?.state == "needsReview")
    }
}
