import Darwin
import Foundation
import Testing

@testable import FileOperations

private struct SandboxSecurityFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init() throws {
        let base = try FileOperationTestFixtures.base(
            legacyVariable: "MAC_EXPLORER_SANDBOX_CORE_TEST_ROOT", legacyParent: "distribution-qualification")
        root = base.appendingPathComponent("security-" + UUID().uuidString)
        try FileManager().createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = root.appendingPathComponent("Generated.txt")
        destination = root.appendingPathComponent("Destination")
        journal = root.appendingPathComponent("history")
        try Data("Generated quarantine preservation fixture.\n".utf8).write(to: source, options: .withoutOverwriting)
        try FileManager().createDirectory(
            at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    // Evidence, including all failed staging/receipts, is deliberately retained.
}

private let createdMark = Data("0082;67000001;GeneratedSandboxBaseline;".utf8)
private func quarantine(_ fd: Int32, _ value: Data) throws {
    guard value.withUnsafeBytes({ fsetxattr(fd, CopySecurity.quarantineName, $0.baseAddress, $0.count, 0, 0) }) == 0
    else { throw posixFailure() }
}

@Suite(.serialized) struct SandboxQuarantineTests {
    @Test func exactNonemptyCreatedBaselineIsPreservedAndOtherTransitionsRefuse() throws {
        let fixture = try SandboxSecurityFixture()
        let identity = try verifiedTree(fixture.source, cancellation: .init()).identity
        let q = SecurityAttribute(createdMark)
        let changed = SecurityAttribute(Data("0082;67000002;Changed;".utf8))
        let empty = SecurityAttribute(Data())
        func permits(before: SecurityAttribute?, after: SecurityAttribute?, sourceAfter: SecurityAttribute? = nil)
            -> Bool
        {
            NativeCopyReceipt(
                relative: "", source: identity, destination: identity, destinationBeforeIdentity: identity,
                destinationOwnership: .init(uid: geteuid(), gid: getegid()), sourceBefore: .init(),
                destinationBefore: .init(quarantine: before), sourceAfter: .init(quarantine: sourceAfter),
                destinationAfter: .init(quarantine: after)
            ).permitsSecurityTransition()
        }
        #expect(permits(before: q, after: q))
        #expect(!permits(before: nil, after: q))
        #expect(!permits(before: q, after: nil))
        #expect(!permits(before: q, after: changed))
        #expect(!permits(before: empty, after: empty))
        #expect(!permits(before: q, after: q, sourceAfter: changed))
    }

    @Test func wrongCreatedIdentityCannotAuthorizeTheSameMark() throws {
        let fixture = try SandboxSecurityFixture()
        let first = try verifiedTree(fixture.source, cancellation: .init()).identity
        let other = fixture.root.appendingPathComponent("Other.txt")
        try Data("other generated object".utf8).write(to: other, options: .withoutOverwriting)
        let second = try verifiedTree(other, cancellation: .init()).identity
        let q = CopySecurity(quarantine: SecurityAttribute(createdMark))
        let receipt = NativeCopyReceipt(
            relative: "", source: first, destination: second, destinationBeforeIdentity: first,
            destinationOwnership: .init(uid: geteuid(), gid: getegid()), sourceBefore: .init(), destinationBefore: q,
            sourceAfter: .init(), destinationAfter: q)
        #expect(!receipt.permitsSecurityTransition())
    }

    @Test func guardedFileAndFolderCopyRetainCreatedMarksAndColdUndo() async throws {
        for folder in [false, true] {
            let fixture = try SandboxSecurityFixture()
            var input = fixture.source
            if folder {
                input = fixture.root.appendingPathComponent("Generated Folder")
                try FileManager().createDirectory(at: input, withIntermediateDirectories: false)
                try Data("Generated child bytes".utf8).write(
                    to: input.appendingPathComponent("Child.txt"), options: .withoutOverwriting)
            }
            let original = try verifiedTree(input, cancellation: .init())
            let engine = RecoverableFileOperations(
                journalDirectory: fixture.journal,
                hooks: .init(
                    copyFaults: .init(beforeNativeCopy: { _, destination in try quarantine(destination, createdMark) }))
            )
            let result = await engine.perform(.copy(sources: [input], destinationDirectory: fixture.destination))
            #expect(result.result.disposition == .succeeded)
            let output = fixture.destination.appendingPathComponent(input.lastPathComponent)
            let descriptor = open(output.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            #expect(descriptor >= 0)
            if descriptor >= 0 {
                #expect(try CopySecurity.read(descriptor).quarantine == SecurityAttribute(createdMark))
                close(descriptor)
            }
            #expect(original.matches(try verifiedTree(input, cancellation: .init())))
            let cold = RecoverableFileOperations(journalDirectory: fixture.journal)
            #expect(await cold.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
            #expect(!FileManager().fileExists(atPath: output.path))
            #expect(original.matches(try verifiedTree(input, cancellation: .init())))
        }
    }

    @Test func changedAndRemovedCreatedMarksRefusePublicationAndPreserveSource() async throws {
        for remove in [false, true] {
            let fixture = try SandboxSecurityFixture()
            let original = try verifiedTree(fixture.source, cancellation: .init())
            let hooks = CopyFaultHooks(
                beforeNativeCopy: { _, destination in try quarantine(destination, createdMark) },
                afterNativeCopy: { _, destination in
                    if remove {
                        guard fremovexattr(destination, CopySecurity.quarantineName, 0) == 0 else {
                            throw posixFailure()
                        }
                    } else {
                        try quarantine(destination, Data("0082;67000002;Changed;".utf8))
                    }
                })
            let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: .init(copyFaults: hooks))
            let result = await engine.perform(
                .copy(sources: [fixture.source], destinationDirectory: fixture.destination))
            #expect(result.result.items.contains { $0.status == .failed(.copyMetadataMismatch) })
            #expect(
                !FileManager().fileExists(
                    atPath: fixture.destination.appendingPathComponent(fixture.source.lastPathComponent).path))
            #expect(original.matches(try verifiedTree(fixture.source, cancellation: .init())))
            #expect(result.recordID != nil && !result.result.items.flatMap(\.recoveryURLs).isEmpty)
        }
    }

    @Test func laterPostReceiptMutationCannotReuseTheBaseline() async throws {
        let fixture = try SandboxSecurityFixture()
        let hooks = CopyFaultHooks(
            beforeNativeCopy: { _, destination in try quarantine(destination, createdMark) },
            afterSecurityReceipt: { _, destination in
                try quarantine(destination, Data("0082;67000003;LateChange;".utf8))
            })
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: .init(copyFaults: hooks))
        let result = await engine.perform(.copy(sources: [fixture.source], destinationDirectory: fixture.destination))
        #expect(result.result.items.contains { $0.status == .failed(.copyMetadataMismatch) })
        #expect(
            !FileManager().fileExists(
                atPath: fixture.destination.appendingPathComponent(fixture.source.lastPathComponent).path))
    }
}
