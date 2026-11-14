import Foundation
import Testing
@testable import LocalStorage

struct VolumeRemovalProtectionTests {
    private func volume(id: UUID = UUID(), uuid: UUID? = UUID(), group: UInt64 = 9, mounted: Bool = true) -> ManagedVolume {
        ManagedVolume(id: id, name: "Generated", url: mounted ? URL(fileURLWithPath: "/generated") : nil,
            isInternal: false, canMount: !mounted, canUnmount: mounted, canEject: true,
            fileSystemID: mounted ? 99 : nil, group: group, mediaID: 10, volumeUUID: uuid)
    }
    @Test func actionMatrixNeverBlocksMountAndKeepMountedBlocksBothRemovalKinds() {
        for level in VolumeProtectionLevel.allCases {
            #expect(!level.prevents(.mount))
            #expect(level.prevents(.unmount) == (level == .keepMounted))
            #expect(level.prevents(.eject) == (level != .none))
            #expect(level.prevents(.forceUnmountAndEject) == (level != .none))
        }
    }
    @Test func noSavedAssociationLeavesPreviouslyQualifiedDevicesUsable() throws {
        let target = volume(uuid: nil)
        try VolumeRemovalProtection.empty.validate(target: target, action: .unmount, members: [target])
        try VolumeRemovalProtection.empty.validate(target: target, action: .eject, members: [target])
    }
    @Test func protectedUnmountedSiblingPreventsEjectFromUnprotectedSibling() throws {
        let target = volume(), sibling = volume(mounted: false)
        let rules = try VolumeRemovalProtection(saved: [try #require(sibling.volumeUUID): .preventEject])
        #expect(throws: VolumeLifecycleFailure.self) { try rules.validate(target: target, action: .eject, members: [target, sibling]) }
        try rules.validate(target: target, action: .unmount, members: [target, sibling])
    }
    @Test func keepMountedFollowsVolumeUUIDAcrossNativeSessionIDsButNotAReformat() throws {
        let uuid = UUID(), old = volume(uuid: uuid), reattached = volume(uuid: uuid), reformatted = volume()
        let rules = try VolumeRemovalProtection(saved: [uuid: .keepMounted])
        #expect(old.id != reattached.id)
        #expect(throws: VolumeLifecycleFailure.self) { try rules.validate(target: reattached, action: .unmount, members: [reattached]) }
        try rules.validate(target: reformatted, action: .eject, members: [reformatted])
    }
    @Test func duplicateUUIDNeverWeakensAnExistingSavedRule() throws {
        let uuid = UUID(), first = volume(uuid: uuid), second = volume(uuid: uuid)
        let rules = try VolumeRemovalProtection(saved: [uuid: .keepMounted])
        #expect(throws: VolumeLifecycleFailure.self) { try rules.validate(target: second, action: .eject, members: [first, second]) }
        #expect(rules.level(for: first) == .keepMounted && rules.level(for: second) == .keepMounted)
    }
    @Test func unidentifiedMemberRefusesWhenSavedProtectionCouldApply() throws {
        let target = volume(), unknown = volume(uuid: nil, mounted: false)
        let rules = try VolumeRemovalProtection(saved: [UUID(): .keepMounted])
        #expect(throws: VolumeLifecycleFailure.self) { try rules.validate(target: target, action: .eject, members: [target, unknown]) }
        try rules.validate(target: target, action: .unmount, members: [target])
    }
    @Test func sessionRuleDoesNotAttachByDriveNameOrNewNativeID() throws {
        let target = volume(uuid: nil), another = volume(uuid: nil)
        let rules = try VolumeRemovalProtection(session: [target.id: .keepMounted])
        #expect(throws: VolumeLifecycleFailure.self) { try rules.validate(target: target, action: .eject, members: [target]) }
        try rules.validate(target: another, action: .eject, members: [another])
    }
    @Test func strongestSavedOrSessionRuleWins() throws {
        let target = volume(), uuid = try #require(target.volumeUUID)
        let rules = try VolumeRemovalProtection(saved: [uuid: .keepMounted], session: [target.id: .preventEject])
        #expect(rules.level(for: target) == .keepMounted)
    }
    @Test func malformedMemberListsNeverGrantRemoval() throws {
        let target = volume(), unrelated = volume()
        #expect(throws: VolumeLifecycleFailure.self) { try VolumeRemovalProtection.empty.validate(target: target, action: .eject, members: []) }
        #expect(throws: VolumeLifecycleFailure.self) { try VolumeRemovalProtection.empty.validate(target: target, action: .eject, members: [unrelated]) }
        #expect(throws: VolumeLifecycleFailure.self) { try VolumeRemovalProtection.empty.validate(target: target, action: .eject, members: [target, target]) }
    }
    @Test func associationBoundsAndInactiveRecordsAreRejected() throws {
        let valid = Dictionary(uniqueKeysWithValues: (0..<256).map { _ in (UUID(), VolumeProtectionLevel.keepMounted) })
        _ = try VolumeRemovalProtection(saved: valid)
        var invalid = valid; invalid[UUID()] = .keepMounted
        #expect(throws: VolumeLifecycleFailure.self) { _ = try VolumeRemovalProtection(saved: invalid) }
        #expect(throws: VolumeLifecycleFailure.self) { _ = try VolumeRemovalProtection(session: invalid) }
        #expect(throws: VolumeLifecycleFailure.self) { _ = try VolumeRemovalProtection(saved: [UUID(): .none]) }
    }
}
