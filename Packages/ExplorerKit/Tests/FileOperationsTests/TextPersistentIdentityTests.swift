import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct TextIdentityFixture {
    let root: URL, state: URL, history: URL, file: URL
    let original = Data("Generated private text baseline\n".utf8)

    init() throws {
        let base = try FileOperationTestFixtures.base()
        root = base.appendingPathComponent("text-identity-" + UUID().uuidString, isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        history = state.appendingPathComponent("operation-recovery", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        file = source.appendingPathComponent("Editor.txt")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try original.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func engine() -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: history, protecting: [state])
    }
    func upgrade() async throws {
        #expect(await engine().upgradeLocalTextHistory().status == .succeeded)
    }
    func priorDevice() throws -> (current: dev_t, old: dev_t) {
        let current = try DirectoryAnchor(file.deletingLastPathComponent(), resolve: false).identity.device
        return (current, current == Int32.max ? current - 1 : current + 1)
    }
    func rebased<T: Codable>(_ value: T, current: dev_t, old: dev_t) throws -> T {
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        func visit(_ value: Any) -> Any {
            if var fields = value as? [String: Any] {
                for (key, member) in fields {
                    if key == "device", let number = member as? NSNumber, number.int32Value == current {
                        fields[key] = NSNumber(value: old)
                    } else { fields[key] = visit(member) }
                }
                return fields
            }
            if let array = value as? [Any] { return array.map(visit) }
            return value
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: visit(object)))
    }
    func rebasedForwardEpoch(_ record: TextRevisionRecordV2) throws -> TextRevisionRecordV2 {
        let devices = try priorDevice()
        let manifest: TextRevisionManifestV2 = try rebased(record.manifest, current: devices.current, old: devices.old)
        var events = record.events
        guard let last = events.firstIndex(where: { if case .applied = $0 { return true }; return false }) else {
            throw FileOperationFailure.recoveryUncertain
        }
        for index in 0...last {
            events[index] = try rebased(events[index], current: devices.current, old: devices.old)
        }
        return TextRevisionRecordV2(manifest: manifest, events: events)
    }
    func insertLegacyRecord(syntheticOldDevice: Bool = false) throws -> UUID {
        let journal = try OperationJournal(history)
        let pinned = try TextPinnedFileV2(file)
        let parent = pinned.parent
        let id = UUID()
        let area = try textCreatePrivateDirectory(parent: parent, name: ".traverse-text-" + id.uuidString,
                                                  owner: journal.owner)
        let devices = try priorDevice()
        let parentIdentity = syntheticOldDevice
            ? try rebased(parent.identity, current: devices.current, old: devices.old) : parent.identity
        let areaIdentity = syntheticOldDevice
            ? try rebased(area.identity, current: devices.current, old: devices.old) : area.identity
        let read = syntheticOldDevice
            ? try rebased(pinned.witness, current: devices.current, old: devices.old) : pinned.witness
        let slot = try textRevisionSlotV2(target: file, parent: parentIdentity)
        let head = TextRevisionHeadV2(slot: slot, lineage: UUID(), sequence: 0, job: nil, witness: read)
        let manifest = TextRevisionManifestV2(version: 3, owner: journal.owner, id: id, generation: UUID(),
            createdAt: Date(), target: file, parent: parentIdentity, area: area.url,
            areaIdentity: areaIdentity, slot: slot, base: head, read: read, baseline: nil, persistentVolume: nil)
        _ = try journal.beginTextV2(manifest)
        return id
    }
}

#if DEBUG
// These two suites depend on the Debug-only synthetic native Trash metadata
// hook. Ordinary persistent identity, Save, recovery and Undo tests below also
// exercise the optimized production implementation.
@Suite(.serialized) struct TextRetirementFingerprintDiagnosticsTests {
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [OperationDiagnosticStage] = []
        func append(_ value: OperationDiagnosticStage) { lock.withLock { values.append(value) } }
        var snapshot: [OperationDiagnosticStage] { lock.withLock { values } }
    }

    @Test func generatedDirectoryMetadataChangeStaysUnconfirmedAndNamesItsFamily() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        try await fixture.upgrade()
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        let ordinary = fixture.engine()
        let opened = try await ordinary.readLocalTextDocument(at: fixture.file)
        let save = try await ordinary.prepareLocalTextSave(from: opened.token,
            bytes: Data("Generated retirement diagnostic edit\n".utf8), generation: UUID())
        guard case .saved(let receipt) = await ordinary.performLocalTextSave(save), let id = receipt.recordID else {
            Issue.record("Generated text Save did not commit"); return
        }
        let documentBefore = try Data(contentsOf: fixture.file)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = { source in
            let from = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(returned, resolve: false)
            try exclusiveRename(from: from.fd, name: source.lastPathComponent,
                to: to.fd, name: source.lastPathComponent)
            return returned.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        }
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            provenance: Data("Generated directory provenance drift \(UUID().uuidString)".utf8))
        let engine = RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks, protecting: [fixture.state])
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let observed = Observations()
        FileOperationDiagnostics.install { if $0.jobID == id { observed.append($0) } }
        defer { FileOperationDiagnostics.install(nil) }
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .pending && result.undoEnded == true)
        #expect(try Data(contentsOf: fixture.file) == documentBefore)
        let target = returned.appendingPathComponent(plan.review.areas[0].url.lastPathComponent, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: target.path))
        let findings = observed.snapshot.filter { $0.checkpoint == .nativeTrashFingerprint && $0.recordID == id }
        #expect(findings.count == 1)
        if case .complete(let changed, _) = findings.first?.nativeTrashFinding {
            #expect(changed.contains(.provenance))
        } else { Issue.record("Native Trash mismatch lacked a complete family finding") }
    }
}

@Suite(.serialized) struct TextRetirementRootMetadataV4Tests {
    private enum PreviousReaderEvent: Codable {
        case retirementIntent(TextRetirementIntentV3)
        case retirementReturned(URL)
        case retirementConfirmed(VerifiedTree)
    }

    private func saved(_ fixture: TextIdentityFixture) async throws -> UUID {
        try await fixture.upgrade()
        let engine = fixture.engine()
        let opened = try await engine.readLocalTextDocument(at: fixture.file)
        let save = try await engine.prepareLocalTextSave(from: opened.token,
            bytes: Data("Generated V4 retirement edit\n".utf8), generation: UUID())
        guard case .saved(let receipt) = await engine.performLocalTextSave(save), let id = receipt.recordID else {
            throw FileOperationFailure.recoveryUncertain
        }
        return id
    }

    private func moveHook(_ destination: URL, mutate: (@Sendable (URL) throws -> Void)? = nil)
        -> @Sendable (URL) throws -> URL {
        { source in
            let from = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(destination, resolve: false)
            try exclusiveRename(from: from.fd, name: source.lastPathComponent,
                                to: to.fd, name: source.lastPathComponent)
            let target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try mutate?(target)
            return target
        }
    }

    private func nativeDirectoryEngine(_ fixture: TextIdentityFixture, hooks: RecoveryHooks = RecoveryHooks())
        -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks,
            protecting: [fixture.state], nativeTrashPolicy: .regularFilesAndDirectories,
            localTextRetirementPolicy: .nativeDirectoryV12)
    }

    private static func child(_ root: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let attempt = try #require(contents.first { $0.lastPathComponent != ".traverse-text-owner" })
        return attempt.appendingPathComponent("before")
    }

    @Test func rootOnlyNativeMetadataConfirmsDurablyAndOlderEventReaderRefusesIntent() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let beforeBody = try Data(contentsOf: fixture.file)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned)
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
            osAccess: Data(repeating: 0x5A, count: 72))
        let engine = RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks,
                                               protecting: [fixture.state])
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let beforeFamilies = NativeTrashFamilyCollector()
        #expect(plan.tree.matches(try verifiedTree(plan.review.areas[0].url,
            cancellation: OperationCancellation(), nativeTrashFamilyCollector: beforeFamilies)))
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .succeeded)
        #expect(result.retention == .retired && result.undoEnded == true)
        #expect(try Data(contentsOf: fixture.file) == beforeBody)
        let record = try OperationJournal(fixture.history).textRecordV2(id)
        #expect(try record.project().retirementConfirmed)
        guard let intent = record.events.first(where: { if case .retirementIntentRootMetadataV4 = $0 { return true }; return false }),
              let confirmation = record.events.last else { Issue.record("V4 retirement events missing"); return }
        #expect((try? JSONDecoder().decode(PreviousReaderEvent.self, from: textEncoded(intent))) == nil)
        if case .retirementConfirmedRootMetadataV4(let value) = confirmation {
            #expect(value.rootMetadata != nil)
            #expect(value.returned == result.knownLocations.last)
            if let proof = value.rootMetadata {
                var encoded = try #require(JSONSerialization.jsonObject(with: textEncoded(proof)) as? [String: Any])
                encoded["afterDescendantIdentity"] = Data(repeating: 0, count: 32).base64EncodedString()
                let forged = try JSONDecoder().decode(NativeTrashRootMetadataProofV4.self,
                    from: JSONSerialization.data(withJSONObject: encoded))
                let prefix = TextRevisionRecordV2(manifest: record.manifest, events: Array(record.events.dropLast()))
                #expect(throws: FileOperationFailure.recoveryUncertain) {
                    _ = try prefix.appending(.retirementConfirmedRootMetadataV4(.init(
                        returned: value.returned, after: value.after, rootMetadata: forged)))
                }
            }
            let families = try #require(beforeFamilies.snapshot())
            #expect(throws: FileOperationFailure.recoveryUncertain) {
                _ = try engine.verifyNativeTrashResult(value.returned, before: plan.tree,
                    cancellation: OperationCancellation(), beforeFamilies: families)
            }
            #expect(throws: FileOperationFailure.recoveryUncertain) {
                _ = try engine.verifyNativeTrashResult(value.returned, before: plan.tree,
                    cancellation: OperationCancellation(), beforeFamilies: families,
                    ordinaryMode: .ordinaryRegularFileNativeMetadata)
            }
        } else { Issue.record("V4 confirmation missing") }
    }

    @Test func nativeDirectoryV5NeedsItsOwnPolicyAtPrepareAndPerform() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let explicitlyHeld = RecoverableFileOperations(journalDirectory: fixture.history,
            protecting: [fixture.state], nativeTrashPolicy: .existingVerifiedPaths,
            localTextRetirementPolicy: .held)
        await #expect(throws: FileOperationFailure.unsupported) {
            try await explicitlyHeld.prepareLocalTextRetirement(recordID: id)
        }
        let narrowTrashOnly = RecoverableFileOperations(journalDirectory: fixture.history,
            protecting: [fixture.state], nativeTrashPolicy: .regularFilesAndDirectories)
        await #expect(throws: FileOperationFailure.unsupported) {
            try await narrowTrashOnly.prepareLocalTextRetirement(recordID: id)
        }
        let v5 = nativeDirectoryEngine(fixture)
        let plan = try await v5.prepareLocalTextRetirement(recordID: id)
        let refused = await narrowTrashOnly.performLocalTextRetirement(plan)
        #expect(refused.status == .failed(.unsupported))
        #expect(try OperationJournal(fixture.history).textRecordV2(id).project().retirement == nil)
    }

    @Test func nativeDirectoryV5DoesNotUpgradeAnOlderPendingIntent() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        final class NativeCallTrap: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func record() { lock.withLock { count += 1 } }
            var calls: Int { lock.withLock { count } }
        }
        let trap = NativeCallTrap()
        var hooks = RecoveryHooks()
        hooks.textEditor.boundary = { stage, _ in
            if stage == "beforeRetirementNative" { throw FileOperationFailure.ioFailure }
        }
        hooks.retentionTrash = { _ in
            trap.record()
            throw FileOperationFailure.ioFailure
        }
        let legacy = RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks,
            protecting: [fixture.state])
        let plan = try await legacy.prepareLocalTextRetirement(recordID: id)
        let documentBefore = try Data(contentsOf: fixture.file)
        let result = await legacy.performLocalTextRetirement(plan)
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .pending && result.undoEnded == true)
        #expect(trap.calls == 0)
        let pending = try OperationJournal(fixture.history).textRecordV2(id)
        let state = try pending.project()
        #expect(state.retirementRootMetadataV4 && !state.retirementNativeDirectoryV5)
        #expect(state.retirement != nil && state.retirementTarget == nil && !state.retirementConfirmed)
        #expect(plan.tree.matches(try verifiedTree(plan.review.areas[0].url,
            cancellation: OperationCancellation())))
        #expect(try Data(contentsOf: fixture.file) == documentBefore)
        await #expect(throws: FileOperationFailure.recoveryUncertain) {
            try await nativeDirectoryEngine(fixture).prepareLocalTextRetirement(recordID: id)
        }
        let after = try OperationJournal(fixture.history).textRecordV2(id)
        #expect(after == pending)
        #expect(plan.tree.matches(try verifiedTree(plan.review.areas[0].url,
            cancellation: OperationCancellation())))
        #expect(try Data(contentsOf: fixture.file) == documentBefore)
    }

    @Test func nativeDirectoryV5ConfirmsRootMarkChangeWithoutOSAccessChange() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let documentBefore = try Data(contentsOf: fixture.file)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned)
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8))
        let engine = nativeDirectoryEngine(fixture, hooks: hooks)
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .succeeded)
        #expect(result.retention == .retired && result.undoEnded == true)
        #expect(try Data(contentsOf: fixture.file) == documentBefore)
        let record = try OperationJournal(fixture.history).textRecordV2(id)
        #expect(try record.project().retirementConfirmed)
        guard let intent = record.events.first(where: {
            if case .retirementIntentNativeDirectoryV5 = $0 { return true }; return false
        }), let event = record.events.last,
              case .retirementConfirmedNativeDirectoryV5(let confirmation) = event,
              let proof = confirmation.rootMetadata else {
            Issue.record("V5 retirement events or root proof missing"); return
        }
        #expect((try? JSONDecoder().decode(PreviousReaderEvent.self, from: textEncoded(intent))) == nil)
        #expect(proof.validatesNativeDirectoryV12(before: plan.tree, after: confirmation.after))
        #expect(!proof.validates(before: plan.tree, after: confirmation.after))
        #expect(proof.beforeOSAccess == proof.afterOSAccess)
        #expect(confirmation.descendantIdentity == .some(proof.afterDescendantIdentity))
        let prefix = TextRevisionRecordV2(manifest: record.manifest, events: Array(record.events.dropLast()))
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try prefix.appending(.retirementConfirmedNativeDirectoryV5(.init(
                returned: confirmation.returned, after: confirmation.after, rootMetadata: proof,
                descendantIdentity: Data(repeating: 0, count: 32))))
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try prefix.appending(.retirementConfirmedNativeDirectoryV5(.init(
                returned: confirmation.returned, after: confirmation.after, rootMetadata: proof,
                descendantIdentity: nil)))
        }
    }

    @Test func nativeDirectoryV5ConfirmsExactGeneratedRenameWithoutRootProof() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned)
        let engine = nativeDirectoryEngine(fixture, hooks: hooks)
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .succeeded)
        let record = try OperationJournal(fixture.history).textRecordV2(id)
        #expect(try record.project().retirementConfirmed)
        guard let event = record.events.last,
              case .retirementConfirmedNativeDirectoryV5(let confirmation) = event else {
            Issue.record("V5 exact rename confirmation missing"); return
        }
        #expect(confirmation.rootMetadata == nil)
        #expect(confirmation.descendantIdentity == nil)
        #expect(plan.tree.matchesNativeTrashTransition(confirmation.after))
        let prefix = TextRevisionRecordV2(manifest: record.manifest, events: Array(record.events.dropLast()))
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try prefix.appending(.retirementConfirmedNativeDirectoryV5(.init(
                returned: confirmation.returned, after: confirmation.after, rootMetadata: nil,
                descendantIdentity: Data(repeating: 0x5A, count: 32))))
        }
    }

    @Test func nativeDirectoryV5KeepsProjectedAndRawReturnedURLAliases() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let documentBefore = try Data(contentsOf: fixture.file)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        let move = moveHook(returned)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = { source in
            let moved = try move(source)
            return URL(fileURLWithPath: moved.path, isDirectory: false)
        }
        let engine = nativeDirectoryEngine(fixture, hooks: hooks)
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .succeeded && result.retention == .retired && result.undoEnded == true)
        #expect(result.knownLocations.count == 3)
        if result.knownLocations.count == 3 {
            #expect(result.knownLocations[0] == plan.review.areas[0].url)
            #expect(result.knownLocations[1].path == result.knownLocations[2].path)
            #expect(result.knownLocations[1] != result.knownLocations[2])
        }
        #expect(result.unconfirmedReportedLocations.isEmpty)
        #expect(try Data(contentsOf: fixture.file) == documentBefore)
        let inspection = try await engine.inspectLocalTextRevision(recordID: id)
        #expect(inspection.metadataIsDurable && !inspection.canUndo
            && inspection.undoDisposition == .endedByRetirement)
    }

    @Test func nativeDirectoryV5ChangedDescendantStaysPending() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned, mutate: { target in
            let child = try Self.child(target)
            let descriptor = open(child.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw FileOperationFailure.ioFailure }
            defer { close(descriptor) }
            let byte: [UInt8] = [0x58]
            guard write(descriptor, byte, 1) == 1, fsync(descriptor) == 0 else {
                throw FileOperationFailure.ioFailure
            }
        })
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8))
        let engine = nativeDirectoryEngine(fixture, hooks: hooks)
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .pending && result.undoEnded == true)
        #expect(try !OperationJournal(fixture.history).textRecordV2(id).project().retirementConfirmed)
    }

    @Test func nativeDirectoryV5InterruptionAfterNativeStaysPending() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned)
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0082;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000002".utf8))
        hooks.textEditor.boundary = { stage, _ in
            if stage == "beforeRetirementSecondVerification" { throw CancellationError() }
        }
        let engine = nativeDirectoryEngine(fixture, hooks: hooks)
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .pending && result.undoEnded == true)
        #expect(try !OperationJournal(fixture.history).textRecordV2(id).project().retirementConfirmed)
    }

    @Test(arguments: ["descendant-quarantine", "descendant-access", "content", "identity"])
    func changedDescendantOrObjectCannotConfirm(_ variant: String) async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        let mutation: @Sendable (URL) throws -> Void = { target in
            if variant == "identity" {
                try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("original"))
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                return
            }
            let child = try Self.child(target)
            if variant == "content" {
                let descriptor = open(child.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw FileOperationFailure.ioFailure }
                defer { close(descriptor) }
                let byte: [UInt8] = [0x58]
                guard write(descriptor, byte, 1) == 1, fsync(descriptor) == 0 else {
                    throw FileOperationFailure.ioFailure
                }
                return
            }
            let name = variant == "descendant-access" ? "com.apple.macl" : CopySecurity.quarantineName
            let data = Data("Generated changed descendant attribute".utf8)
            let status = data.withUnsafeBytes { setxattr(child.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw FileOperationFailure.ioFailure }
        }
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned, mutate: mutation)
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
            osAccess: Data(repeating: 0x5A, count: 72))
        let engine = RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks,
                                               protecting: [fixture.state])
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        let target = returned.appendingPathComponent(plan.review.areas[0].url.lastPathComponent, isDirectory: true)
        if variant == "identity" {
            #expect(FileManager.default.fileExists(atPath: target.appendingPathExtension("original").path))
            #expect(FileManager.default.fileExists(atPath: target.path))
        } else if variant == "content" {
            #expect(try Data(contentsOf: Self.child(target)).last == 0x58)
        } else {
            let attribute = variant == "descendant-access" ? "com.apple.macl" : CopySecurity.quarantineName
            #expect(getxattr(try Self.child(target).path, attribute,
                             nil, 0, 0, XATTR_NOFOLLOW) > 0)
        }
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .pending && result.undoEnded == true)
        #expect(try !OperationJournal(fixture.history).textRecordV2(id).project().retirementConfirmed)
    }

    @Test func confirmationTagsCannotCrossTheIntentFence() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let plan = try await fixture.engine().prepareLocalTextRetirement(recordID: id)
        let record = try OperationJournal(fixture.history).textRecordV2(id)
        let intent = TextRetirementIntentV3(before: plan.tree, head: plan.head,
                                             headEpoch: plan.epochStamp?.epoch)
        let returned = fixture.root.appendingPathComponent("not-moved", isDirectory: true)
        let previous = try record.appending(.retirementIntent(intent)).appending(.retirementReturned(returned))
        let current = try record.appending(.retirementIntentRootMetadataV4(intent)).appending(.retirementReturned(returned))
        let nativeDirectory = try record.appending(.retirementIntentNativeDirectoryV5(intent))
            .appending(.retirementReturned(returned))
        let confirmation = TextRetirementConfirmationV4(returned: returned, after: plan.tree, rootMetadata: nil)
        let nativeConfirmation = TextRetirementConfirmationV5(returned: returned, after: plan.tree,
            rootMetadata: nil, descendantIdentity: nil)
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try previous.appending(.retirementConfirmedRootMetadataV4(confirmation))
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try current.appending(.retirementConfirmed(plan.tree))
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try previous.appending(.retirementConfirmedNativeDirectoryV5(nativeConfirmation))
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try current.appending(.retirementConfirmedNativeDirectoryV5(nativeConfirmation))
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try nativeDirectory.appending(.retirementConfirmedRootMetadataV4(confirmation))
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try nativeDirectory.appending(.retirementConfirmed(plan.tree))
        }
    }

    @Test func changedBetweenFullWalksRemainsPending() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned)
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
            osAccess: Data(repeating: 0x5A, count: 72))
        hooks.textEditor.boundary = { stage, recordID in
            guard stage == "beforeRetirementSecondVerification" else { return }
            let target = returned.appendingPathComponent(".traverse-text-" + recordID.uuidString,
                                                        isDirectory: true)
            let data = Data("Generated second-walk change".utf8)
            let path = try Self.child(target)
            let status = data.withUnsafeBytes {
                setxattr(path.path, "com.traverse.generated-second-walk", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            guard status == 0 else { throw FileOperationFailure.ioFailure }
        }
        let engine = RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks,
                                               protecting: [fixture.state])
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .pending && result.undoEnded == true)
        #expect(try !OperationJournal(fixture.history).textRecordV2(id).project().retirementConfirmed)
    }

    @Test func lostConfirmationAcknowledgementReadsBackTheCommittedReceipt() async throws {
        let fixture = try TextIdentityFixture(); defer { fixture.remove() }
        let id = try await saved(fixture)
        let returned = fixture.root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: false)
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var commits = 0
            func failThird() throws { try lock.withLock {
                commits += 1
                if commits == 3 { throw FileOperationFailure.ioFailure }
            } }
        }
        let counter = Counter()
        var hooks = RecoveryHooks()
        hooks.retentionTrash = moveHook(returned)
        hooks.nativeTrashSyntheticRootMetadata = try NativeTrashSyntheticRootMetadata(
            quarantine: Data("0083;67000001;TraverseGenerated;00000000-0000-0000-0000-000000000001".utf8),
            osAccess: Data(repeating: 0x5A, count: 72))
        hooks.journalHooks.afterSaveCommit = { try counter.failThird() }
        let engine = RecoverableFileOperations(journalDirectory: fixture.history, hooks: hooks,
                                               protecting: [fixture.state])
        let plan = try await engine.prepareLocalTextRetirement(recordID: id)
        let result = await engine.performLocalTextRetirement(plan)
        #expect(result.status == .failed(.recoveryUncertain))
        #expect(result.retention == .retired && result.undoEnded == true)
        #expect(try OperationJournal(fixture.history).textRecordV2(id).project().retirementConfirmed)
    }
}

#endif

@Test func newTextHistoryUsesDescriptorVolumeAndCanSaveThenUndo() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    let edited = Data("Generated edit after save\n".utf8)
    let plan = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited, generation: UUID())
    #expect(plan.manifestVersion == 4)
    let result = await engine.performLocalTextSave(plan)
    guard case .saved(let receipt) = result else { Issue.record("New text Save did not commit"); return }
    let id = try #require(receipt.recordID)
    let record = try OperationJournal(fixture.history).textRecordV2(id)
    let pinned = try TextPinnedFileV2(fixture.file)
    #expect(record.manifest.version == 4)
    #expect(record.manifest.persistentVolume == pinned.volumeBinding.uuid)
    #expect(record.manifest.slot == (try textRevisionSlotV4(target: fixture.file,
        parent: pinned.parent.identity, volume: pinned.volume)))
    #expect(try Data(contentsOf: fixture.file) == edited)
    #expect(await engine.undo(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: fixture.file) == fixture.original)
}

@Test func generatedTextRecoveryCopiesPublishBothVersionsAndRefuseChangedRetainedSource() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    let edited = Data("Generated recovery copy edit\n".utf8)
    let save = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited, generation: UUID())
    guard case .saved(let receipt) = await engine.performLocalTextSave(save) else {
        Issue.record("Generated text Save did not commit"); return
    }
    let id = try #require(receipt.recordID)
    let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let plan = try await engine.prepareLocalTextRecoveryCopies(recordID: id, destinationDirectory: destination,
        beforeName: "before.txt", submittedName: "submitted.txt")
    let cold = fixture.engine()
    let pair = try await cold.readLocalTextRevisionComparison(recordID: id, attemptID: plan.attemptID)
    #expect(pair.left.encoded == fixture.original && pair.right.encoded == edited)
    #expect(try await cold.inspectLocalTextRecoveryExports(recordID: id).isEmpty)
    await #expect(throws: FileOperationFailure.recoveryUncertain) {
        try await cold.readLocalTextRevisionComparison(recordID: id, attemptID: UUID())
    }
    let result = await engine.performLocalTextRecoveryCopies(plan)
    #expect(result.status == .succeeded)
    #expect(result.outcomes.map(\.state) == [.verified, .verified])
    #expect(try Data(contentsOf: destination.appendingPathComponent("before.txt")) == fixture.original)
    #expect(try Data(contentsOf: destination.appendingPathComponent("submitted.txt")) == edited)
    let inspected = try await engine.inspectLocalTextRecoveryExports(recordID: id)
    #expect(inspected.count == 1)
    #expect(inspected.first?.outcomes.map(\.currentlyAvailable) == [true, true])

    let later = try await engine.prepareLocalTextRecoveryCopies(recordID: id, destinationDirectory: destination,
        beforeName: "later-before.txt", submittedName: "later-submitted.txt")
    try Data("Changed generated retained source\n".utf8).write(to: later.sources[0], options: .atomic)
    await #expect(throws: FileOperationFailure.recoveryUncertain) {
        try await cold.readLocalTextRevisionComparison(recordID: id, attemptID: later.attemptID)
    }
    #expect(try await cold.readLocalTextRevisionVersion(recordID: id, attemptID: later.attemptID, version: .submitted).encoded == edited)
    #expect(try Data(contentsOf: fixture.file) == edited)
    let refused = await engine.performLocalTextRecoveryCopies(later)
    #expect(refused.status != .succeeded)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("later-before.txt").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("later-submitted.txt").path))
}

@Test func newTextHistoryKeepsOneStableHeadAcrossConsecutiveSaves() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let engine = fixture.engine()
    let firstRead = try await engine.readLocalTextDocument(at: fixture.file)
    let firstBytes = Data("Generated first save\n".utf8)
    let firstPlan = try await engine.prepareLocalTextSave(from: firstRead.token, bytes: firstBytes, generation: UUID())
    guard case .saved(let firstReceipt) = await engine.performLocalTextSave(firstPlan) else {
        Issue.record("First stable Save did not commit"); return
    }
    let firstID = try #require(firstReceipt.recordID)
    let secondRead = try await engine.readLocalTextDocument(at: fixture.file)
    let secondBytes = Data("Generated second save\n".utf8)
    let secondPlan = try await engine.prepareLocalTextSave(from: secondRead.token, bytes: secondBytes, generation: UUID())
    #expect(secondPlan.manifestVersion == 4)
    guard case .saved(let secondReceipt) = await engine.performLocalTextSave(secondPlan) else {
        Issue.record("Second stable Save did not commit"); return
    }
    let secondID = try #require(secondReceipt.recordID)
    let predecessor: UUID? = try {
        let journal = try OperationJournal(fixture.history)
        return try journal.textRecordV2(secondID).manifest.predecessor
    }()
    #expect(predecessor == firstID)
    #expect(await engine.undo(recordID: secondID).result.disposition == .succeeded)
    #expect(try Data(contentsOf: fixture.file) == firstBytes)
    #expect(await engine.undo(recordID: firstID).result.disposition == .succeeded)
    #expect(try Data(contentsOf: fixture.file) == fixture.original)
}

@Test func newTextHistoryPersistentProofAcceptsOnlySyntheticDeviceDrift() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    let edited = Data("Generated persistent text edit\n".utf8)
    let plan = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited, generation: UUID())
    guard case .saved(let receipt) = await engine.performLocalTextSave(plan) else {
        Issue.record("New text Save did not commit"); return
    }
    let id = try #require(receipt.recordID)
    let stored = try OperationJournal(fixture.history).textRecordV2(id)
    let devices = try fixture.priorDevice()
    let prior: TextRevisionRecordV2 = try fixture.rebased(stored, current: devices.current, old: devices.old)
    let projected = try prior.project()
    let pinned = try TextPinnedFileV2(fixture.file)
    let area = try DirectoryAnchor(prior.manifest.area, resolve: false)
    #expect(prior.manifest.slot == stored.manifest.slot)
    #expect(try prior.manifest.matchesPersisted(prior.manifest.areaIdentity, current: area.identity, in: area))
    #expect(prior.manifest.matchesPersisted(try #require(projected.forward).output, file: pinned))
    let custody = try #require(projected.attempts.first?.custody)
    let retained = try TextPinnedFileV2(prior.manifest.area.appendingPathComponent("forward-" + projected.attempts[0].preparation.id.uuidString)
        .appendingPathComponent("before"))
    #expect(prior.manifest.matchesPersisted(custody.before.copy, file: retained))
    let oldHead = TextRevisionHeadV2(slot: prior.manifest.slot, lineage: prior.manifest.base.lineage,
        sequence: 1, job: id, witness: try #require(projected.forward).output)
    let cut = TextCheckpoint10(id: UUID(), owner: prior.manifest.owner, nextEpoch: UUID(),
        slot: prior.manifest.slot, old: .init(epoch: UUID(), head: oldHead), oldGeneration: 0,
        maintenanceGeneration: 0, oldEpochDigest: .bytes(Data()), observed: pinned.witness,
        root: .init(slot: prior.manifest.slot, lineage: UUID(), sequence: 0, job: nil, witness: pinned.witness),
        members: [], edgesDigest: .bytes(Data()), endedUndoCount: 0, baselineAdopted: false,
        createdAt: Date(), persistentVolume: pinned.volume)
    try cut.validate()
    let unboundCut = TextCheckpoint10(id: cut.id, owner: cut.owner, nextEpoch: cut.nextEpoch,
        slot: cut.slot, old: cut.old, oldGeneration: cut.oldGeneration,
        maintenanceGeneration: cut.maintenanceGeneration, oldEpochDigest: cut.oldEpochDigest,
        observed: cut.observed, root: cut.root, members: cut.members, edgesDigest: cut.edgesDigest,
        endedUndoCount: cut.endedUndoCount, baselineAdopted: cut.baselineAdopted,
        createdAt: cut.createdAt, persistentVolume: nil)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try unboundCut.validate() }
    let unrelated = TextRevisionManifestV2(version: 4, owner: prior.manifest.owner, id: prior.id,
        generation: prior.manifest.generation, createdAt: prior.manifest.createdAt, target: prior.manifest.target,
        parent: prior.manifest.parent, area: prior.manifest.area, areaIdentity: prior.manifest.areaIdentity,
        slot: prior.manifest.slot, base: prior.manifest.base, read: prior.manifest.read,
        baseline: prior.manifest.baseline, persistentVolume: Data(repeating: 0xA5, count: 16))
    #expect(!unrelated.matchesPersisted(try #require(projected.forward).output, file: pinned))
    try Data("Changed generated after-image\n".utf8).write(to: fixture.file, options: .atomic)
    let changedPin = try TextPinnedFileV2(fixture.file)
    let forward = try #require(projected.forward)
    #expect(!prior.manifest.matchesPersisted(forward.output, file: changedPin))
}

@Test func newTextUndoModelKeepsCrossEpochBoundaryAndExactNativeAfterImage() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    let edited = Data("Generated model boundary edit\n".utf8)
    let plan = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited, generation: UUID())
    guard case .saved(let receipt) = await engine.performLocalTextSave(plan) else {
        Issue.record("New text Save did not commit"); return
    }
    let id = try #require(receipt.recordID)
    #expect(await engine.undo(recordID: id).result.disposition == .succeeded)
    let actual = try OperationJournal(fixture.history).textRecordV2(id)
    let previousForward = try fixture.rebasedForwardEpoch(actual)
    let projected = try previousForward.project()
    let output = try #require(projected.forward).output
    let restored = try #require(projected.inverse).output
    let before = TextRevisionHeadV2(slot: previousForward.manifest.slot,
        lineage: previousForward.manifest.base.lineage, sequence: 1, job: id, witness: output)
    let after = TextRevisionHeadV2(slot: previousForward.manifest.slot,
        lineage: before.lineage, sequence: 2, job: previousForward.manifest.predecessor, witness: restored)
    let inverse = TextRevisionTransitionV2(slot: before.slot, ordinal: 1, job: id,
        recordRevision: previousForward.revision, prefix: try previousForward.prefix,
        direction: .inverse, before: before, after: after)
    try inverse.validate(record: previousForward)
    #expect(output.device != restored.device)
    #expect(try Data(contentsOf: fixture.file) == fixture.original)
}

@Test func newTextCheckpointPreservesPersistentVolumeWithoutFalseBaseline() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    let edited = Data("Generated checkpoint text edit\n".utf8)
    let save = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited, generation: UUID())
    guard case .saved = await engine.performLocalTextSave(save) else {
        Issue.record("New text Save did not commit"); return
    }
    let current = try await engine.readLocalTextDocument(at: fixture.file)
    let checkpoint = try await engine.prepareLocalTextCheckpoint(from: current.token)
    #expect(!checkpoint.review.adoptsExternalBaseline)
    guard case .completed(let receipt) = await engine.performLocalTextCheckpoint(checkpoint) else {
        Issue.record("New stable text checkpoint did not commit"); return
    }
    let stored = try #require(OperationHistoryInspector.textRead10(fixture.history,
        cancellation: OperationCancellation()) { try $0.checkpoint10(receipt.checkpointID) } ?? nil)
    #expect(stored.persistentVolume == (try TextPinnedFileV2(fixture.file)).volume)
    #expect(!stored.baselineAdopted)
    #expect(try Data(contentsOf: fixture.file) == edited)
}

@Test func sameMountLegacyTextHistoryKeepsItsExactSlot() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    _ = try fixture.insertLegacyRecord()
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    let edited = Data("Generated same mount legacy edit\n".utf8)
    let plan = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited, generation: UUID())
    #expect(plan.manifestVersion == 3)
    guard case .saved(let receipt) = await engine.performLocalTextSave(plan) else {
        Issue.record("Same mount legacy Save did not commit"); return
    }
    let id = try #require(receipt.recordID)
    #expect(try OperationJournal(fixture.history).textRecordV2(id).manifest.version == 3)
    #expect(try Data(contentsOf: fixture.file) == edited)
    #expect(await engine.undo(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: fixture.file) == fixture.original)
}

@Test func ambiguousOlderTextSlotRefusesSaveWithoutChangingFixture() async throws {
    let fixture = try TextIdentityFixture(); defer { fixture.remove() }
    try await fixture.upgrade()
    let oldID = try fixture.insertLegacyRecord(syntheticOldDevice: true)
    let engine = fixture.engine()
    let opened = try await engine.readLocalTextDocument(at: fixture.file)
    do {
        _ = try await engine.prepareLocalTextSave(from: opened.token,
            bytes: Data("Refused generated edit\n".utf8), generation: UUID())
        Issue.record("Ambiguous old slot was accepted")
    } catch FileOperationFailure.legacyTextHistoryRequiresReview { }
    #expect(try Data(contentsOf: fixture.file) == fixture.original)
    #expect(try OperationJournal(fixture.history).textRecordV2(oldID).manifest.version == 3)
}
