import Foundation
@testable import LocalStorage
import Testing

struct APFSVolumeFormatTests {
    private actor RecordingProbe: APFSVolumeFormatRecording {
        enum Failure: Error { case injected }
        var events: [String] = []
        let failIntent: Bool
        let failSubmission: Bool
        let failTerminal: Bool
        init(failIntent: Bool = false, failSubmission: Bool = false, failTerminal: Bool = false) {
            self.failIntent = failIntent
            self.failSubmission = failSubmission; self.failTerminal = failTerminal
        }
        nonisolated func ownerStillCurrent() -> Bool { true }
        func recordIntent(_ snapshot: APFSVolumeFormatSnapshot) throws {
            guard snapshot.validate() else { throw Failure.injected }
            events.append("intent")
            if failIntent { throw Failure.injected }
        }
        func recordSubmitted() throws {
            events.append("submitted")
            if failSubmission { throw Failure.injected }
        }
        func recordTerminal(_ terminal: APFSVolumeFormatRecoveryTerminal) throws {
            events.append("terminal:\(terminal)")
            if failTerminal { throw Failure.injected }
        }
        func trace() -> [String] { events }
    }
    private let containerID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let storeID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let targetID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    private let siblingID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    private let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!

    private func generatedOwner() -> APFSVolumeFormatGeneratedOwner {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        return .init(fixtureID: id,
            imagePath: "/tmp/traverse/.build/fixtures/drive-lifecycle-\(id.uuidString)/fixture.dmg",
            rootDevice: 11, rootInode: 12, imageDevice: 11, imageInode: 13,
            ownerUID: 501, outerMediaID: 14)
    }

    private func volume(_ id: UUID, device: String, name: String, quota: UInt64 = 0) -> APFSContainerObservation.Volume {
        .init(device: device, uuid: id, name: name, quota: quota, reserve: 0)
    }
    private func container(target: APFSContainerObservation.Volume? = nil,
                           sibling: APFSContainerObservation.Volume? = nil,
                           containerID: UUID? = nil,
                           extra: [APFSContainerObservation.Volume] = []) -> APFSContainerObservation {
        .init(device: "disk30", uuid: containerID ?? self.containerID, selectedUUID: targetID,
              capacity: 1 << 30, free: 700 << 20,
              stores: [.init(device: "disk29s2", uuid: storeID, capacity: 1 << 30)],
              volumes: [target ?? volume(targetID, device: "disk30s1", name: "Erase Me"),
                        sibling ?? volume(siblingID, device: "disk30s2", name: "Preserve Me")] + extra)
    }
    private func observed(mount: URL? = URL(fileURLWithPath: "/Volumes/Generated"),
                          target: APFSContainerObservation.Volume? = nil,
                          sibling: APFSContainerObservation.Volume? = nil) -> APFSObservedVolume {
        .init(info: .init(uuid: targetID, device: "disk30s1", container: "disk30", name: "Erase Me",
                          mount: mount, caseSensitive: false),
              container: container(target: target, sibling: sibling))
    }
    private func selection() -> ManagedVolume {
        .init(id: UUID(), name: "Erase Me", url: URL(fileURLWithPath: "/Volumes/Generated"),
              isInternal: false, canMount: false, canUnmount: true, canEject: true,
              fileSystemID: 31, group: 32, deviceKind: .diskImage, mediaID: 33, volumeUUID: targetID)
    }

    @Test func onlyMountedUniqueZeroAllocationTargetCanBeReviewed() throws {
        try APFSVolumeFormat.validateTarget(observed())
        #expect(throws: APFSVolumeFormatFailure.unsupported) {
            try APFSVolumeFormat.validateTarget(observed(mount: nil))
        }
        #expect(throws: APFSVolumeFormatFailure.unsupported) {
            try APFSVolumeFormat.validateTarget(observed(target: volume(targetID, device: "disk30s1", name: "Erase Me", quota: 1 << 20)))
        }
        #expect(throws: APFSVolumeFormatFailure.unsupported) {
            try APFSVolumeFormat.validateTarget(observed(sibling: volume(siblingID, device: "disk30s2", name: "Erase Me")))
        }
    }

    @Test func exactNameAndCurrentPolicyAreRequiredBeforeAnyNativeInquiry() async {
        let plan = APFSVolumeFormatPlan(selected: selection(), original: observed())
        let backend = APFSVolumeFormat()
        let probe = RecordingProbe()
        let wrong = await backend.perform(plan, confirmedName: "Other", recording: probe, permitted: { true })
        #expect(!wrong.submitted && wrong.formatted == nil && wrong.failure == .confirmationRequired)
        #expect(wrong.toolExitStatus == nil)
        let held = await backend.perform(plan, confirmedName: "Erase Me", recording: probe, permitted: { false })
        #expect(!held.submitted && held.formatted == nil && held.failure == .unavailable)
        #expect(held.toolExitStatus == nil)
        #expect(await probe.trace().isEmpty)
        #expect(!String(reflecting: plan).contains("Generated"))
    }

    @Test func onlyOneReplacementWithUnchangedSiblingCanReconcile() {
        let before = container()
        let replacement = volume(replacementID, device: "disk30s3", name: "Erase Me")
        let after = container(target: replacement)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before, after: after,
                                                       original: targetID, name: "Erase Me")?.uuid == replacementID)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before, after: before,
                                                       original: targetID, name: "Erase Me") == nil)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before,
                                                       after: container(target: replacement, sibling: volume(siblingID, device: "disk30s2", name: "Changed")),
                                                       original: targetID, name: "Erase Me") == nil)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before,
                                                       after: container(target: replacement, containerID: UUID()),
                                                       original: targetID, name: "Erase Me") == nil)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before,
                                                       after: container(target: replacement, extra: [volume(UUID(), device: "disk30s4", name: "Unexpected")]),
                                                       original: targetID, name: "Erase Me") == nil)
        let changedStore = APFSContainerObservation(device: before.device, uuid: before.uuid, selectedUUID: before.selectedUUID,
            capacity: before.capacity, free: before.free,
            stores: [.init(device: "disk29s3", uuid: storeID, capacity: before.capacity)],
            volumes: after.volumes)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before, after: changedStore,
                                                       original: targetID, name: "Erase Me") == nil)
        let changedCapacity = APFSContainerObservation(device: before.device, uuid: before.uuid, selectedUUID: before.selectedUUID,
            capacity: before.capacity - 1, free: before.free, stores: before.stores, volumes: after.volumes)
        #expect(APFSVolumeFormat.reconciledReplacement(before: before, after: changedCapacity,
                                                       original: targetID, name: "Erase Me") == nil)
        let allocatedTarget = container(target: volume(replacementID, device: "disk30s3", name: "Erase Me", quota: 1 << 20))
        #expect(APFSVolumeFormat.reconciledReplacement(before: before, after: allocatedTarget,
                                                       original: targetID, name: "Erase Me") == nil)
    }

    @Test func eraseCommandIsOneFixedAPFSLeafRequest() throws {
        let arguments = try APFSVolumeTool.eraseVolumeArguments(device: "disk30s1", name: "Data $(echo untouched) `literal`")
        #expect(arguments == ["apfs", "eraseVolume", "disk30s1", "-name", "Data $(echo untouched) `literal`"])
        for device in ["disk30", "disk30s1s2", "disk30s1; echo unsafe", "/dev/disk30s1"] {
            #expect(throws: APFSVolumeFormatFailure.unsupported) {
                try APFSVolumeTool.eraseVolumeArguments(device: device, name: "Erase Me")
            }
        }
        #expect(throws: APFSVolumeFormatFailure.unsupported) {
            try APFSVolumeTool.eraseVolumeArguments(device: "disk30s1", name: "-passphrase")
        }
    }

    @Test func durableIntentPrecedesNoLaunchTerminal() async throws {
        let probe = RecordingProbe()
        let session = APFSVolumeFormatRecoverySession(probe)
        let snapshot = APFSVolumeFormatSnapshot(observed())
        try await session.begin(snapshot)
        let result = await session.finish(.init(submitted: false, formatted: nil, failure: .cancelled))
        #expect(!result.submitted && result.failure == .cancelled)
        #expect(await probe.trace() == ["intent", "terminal:notSubmitted"])
        #expect(snapshot.validate())
        #expect(snapshot.originalContainer().sameIdentityAndMembers(as: container()))
    }

    @Test func failedIntentCannotReachSubmission() async {
        let probe = RecordingProbe(failIntent: true)
        let session = APFSVolumeFormatRecoverySession(probe)
        do {
            try await session.begin(APFSVolumeFormatSnapshot(observed()))
            Issue.record("Failed durable intent was accepted")
        } catch {
            #expect(error is RecordingProbe.Failure)
        }
        #expect(await probe.trace() == ["intent"])
    }

    @Test func lostImageOwnerRefusesIntentBeforeAnyLaunch() async {
        struct Rejected: APFSVolumeFormatRecording {
            func ownerStillCurrent() -> Bool { false }
            func recordIntent(_ snapshot: APFSVolumeFormatSnapshot) async throws {
                Issue.record("A lost image owner reached persistence")
            }
            func recordSubmitted() async throws { Issue.record("A lost image owner reached submission") }
            func recordTerminal(_ terminal: APFSVolumeFormatRecoveryTerminal) async throws {
                Issue.record("A lost image owner reached terminal storage")
            }
        }
        let session = APFSVolumeFormatRecoverySession(Rejected())
        do {
            try await session.begin(APFSVolumeFormatSnapshot(observed()))
            Issue.record("A lost image owner was admitted")
        } catch {
            #expect(error as? APFSVolumeFormatFailure == .changed)
        }
    }

    @Test func coldIntentAndSubmittedRecordsRemainUnresolved() throws {
        let snapshot = APFSVolumeFormatSnapshot(observed())
        let id = UUID(), owner = generatedOwner()
        let intent = APFSVolumeFormatJobRecord(id: id, owner: owner, snapshot: snapshot, phase: .intent)
        let cold = try JSONDecoder().decode(APFSVolumeFormatJobRecord.self, from: JSONEncoder().encode(intent))
        #expect(cold.validate() && cold.isUnresolved && cold.phase == .intent)
        var submitted = cold; submitted.phase = .submitted
        #expect(submitted.validate() && submitted.isUnresolved)
        var uncertain = cold; uncertain.phase = .uncertain
        #expect(uncertain.validate() && uncertain.isUnresolved)
        var noLaunch = cold; noLaunch.phase = .notSubmitted
        #expect(noLaunch.validate() && !noLaunch.isUnresolved)
        var compatible = cold; compatible.phase = .compatibleReplacement; compatible.replacementID = replacementID
        #expect(compatible.validate() && compatible.isUnresolved)
        var missingWitness = cold; missingWitness.phase = .compatibleReplacement
        #expect(!missingWitness.validate())
        #expect(APFSVolumeFormat.reconciledReplacement(before: cold.snapshot.originalContainer(),
            after: container(target: volume(replacementID, device: "disk30s3", name: "Erase Me")),
            original: cold.snapshot.targetID, name: cold.snapshot.name)?.uuid == replacementID)
    }

    @Test func postlaunchReceiptFailureRemainsUncertain() async throws {
        let probe = RecordingProbe(failSubmission: true)
        let session = APFSVolumeFormatRecoverySession(probe)
        try await session.begin(APFSVolumeFormatSnapshot(observed()))
        session.didSubmit()
        let candidate = APFSVolumeFormatResult(submitted: true,
            formatted: .init(id: replacementID, name: "Erase Me", mountPoint: URL(fileURLWithPath: "/Volumes/New")),
            failure: nil, toolExitStatus: 0)
        let result = await session.finish(candidate)
        #expect(result.submitted && result.formatted == nil && result.failure == .uncertain)
        #expect(await probe.trace() == ["intent", "submitted", "terminal:uncertain"])
    }

    @Test func compatibleBackendResultIsStillAnUnresolvedDurableJob() async throws {
        let probe = RecordingProbe()
        let session = APFSVolumeFormatRecoverySession(probe)
        try await session.begin(APFSVolumeFormatSnapshot(observed()))
        session.didSubmit()
        let candidate = APFSVolumeFormatResult(submitted: true,
            formatted: .init(id: replacementID, name: "Erase Me", mountPoint: nil),
            failure: nil, toolExitStatus: 0)
        let result = await session.finish(candidate)
        #expect(result.submitted && result.failure == nil && result.formatted?.id == replacementID)
        #expect(await probe.trace() == ["intent", "submitted", "terminal:compatibleReplacement(\(replacementID))"])
        let persisted = APFSVolumeFormatJobRecord(id: UUID(), owner: generatedOwner(),
            snapshot: APFSVolumeFormatSnapshot(observed()), phase: .compatibleReplacement,
            replacementID: replacementID)
        #expect(persisted.validate() && persisted.isUnresolved)
    }

    @Test func failedTerminalAcknowledgementDoesNotReportSuccess() async throws {
        let probe = RecordingProbe(failTerminal: true)
        let session = APFSVolumeFormatRecoverySession(probe)
        try await session.begin(APFSVolumeFormatSnapshot(observed()))
        let result = await session.finish(.init(submitted: false, formatted: nil, failure: .cancelled))
        #expect(!result.submitted && result.failure == .recoveryUnavailable)
        #expect(await probe.trace() == ["intent", "terminal:notSubmitted"])
    }

    @Test func submittedTerminalFailureAlsoRemainsUncertain() async throws {
        let probe = RecordingProbe(failTerminal: true)
        let session = APFSVolumeFormatRecoverySession(probe)
        try await session.begin(APFSVolumeFormatSnapshot(observed()))
        session.didSubmit()
        let candidate = APFSVolumeFormatResult(submitted: true,
            formatted: .init(id: replacementID, name: "Erase Me", mountPoint: nil),
            failure: nil, toolExitStatus: 0)
        let result = await session.finish(candidate)
        #expect(result.submitted && result.formatted == nil && result.failure == .uncertain)
        #expect(await probe.trace() == ["intent", "submitted", "terminal:compatibleReplacement(\(replacementID))"])
    }
}
