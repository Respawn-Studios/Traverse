import Darwin
import Foundation
@testable import LocalStorage
import Testing

struct APFSAttachedImageIdentityTests {
    private final class Facts: @unchecked Sendable {
        private let lock = NSLock()
        private let path: String
        private var fileValue: APFSAttachedImageWitness.FileFacts?
        private var disks: [String: APFSAttachedImageWitness.DiskFacts]
        init(path: String, file: APFSAttachedImageWitness.FileFacts, disks: [String: APFSAttachedImageWitness.DiskFacts]) {
            self.path = path; fileValue = file; self.disks = disks
        }
        func file(_ path: String) -> APFSAttachedImageWitness.FileFacts? {
            lock.withLock { path == self.path ? fileValue : nil }
        }
        func disk(_ device: String) -> APFSAttachedImageWitness.DiskFacts? { lock.withLock { disks[device] } }
        func replaceFile(_ value: APFSAttachedImageWitness.FileFacts?) { lock.withLock { fileValue = value } }
        func replaceDisk(_ device: String, _ value: APFSAttachedImageWitness.DiskFacts) {
            lock.withLock { disks[device] = value }
        }
    }
    private let targetID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!

    private func selection() -> ManagedVolume {
        .init(id: UUID(), name: "Erase Me", url: URL(fileURLWithPath: "/Volumes/Generated"),
              isInternal: false, canMount: false, canUnmount: true, canEject: true,
              fileSystemID: 30, group: 44, deviceKind: .diskImage, mediaID: 45, volumeUUID: targetID)
    }
    private func inspection(_ selected: ManagedVolume) -> VolumeInspection {
        .init(volume: selected, deviceName: "disk30s1", fields: .init(fileSystem: "apfs", writable: true))
    }
    private func plist(shadow: Bool = false, duplicate: Bool = false,
                       encrypted: Bool = false, writable: Bool = true,
                       imageType: String = "read/write disk image", systemImage: Any? = false,
                       ownerUID: Any? = nil, competing: [[String: Any]] = [],
                       imagePath: String = "/tmp/TraverseGenerated.dmg", devices: [String] = ["disk29", "disk30s1"]) throws -> Data {
        var item: [String: Any] = ["image-path": imagePath, "owner-uid": Int(geteuid()),
            "image-type": imageType, "writeable": writable, "image-encrypted": encrypted,
            "system-entities": devices.map { ["dev-entry": "/dev/" + $0] }]
        item["system-image"] = systemImage
        if let ownerUID { item["owner-uid"] = ownerUID }
        if shadow { item["shadow-path"] = "/tmp/shadow" }
        return try PropertyListSerialization.data(fromPropertyList: ["images": (duplicate ? [item, item] : [item]) + competing],
            format: .xml, options: 0)
    }
    private func facts(path: String = "/tmp/TraverseGenerated.dmg") -> (APFSAttachedImageWitness.FileFacts, Facts) {
        let file = APFSAttachedImageWitness.FileFacts(parentDevice: 11, parentInode: 12,
            imageDevice: 11, imageInode: 13, imageBytes: 1 << 30, ownerUID: geteuid(),
            modifiedSeconds: 100, modifiedNanos: 1, changedSeconds: 200, changedNanos: 2)
        let state = Facts(path: path, file: file, disks: [
            "disk29": .init(mediaID: 44, volumeUUID: nil, name: nil, mountPath: nil),
            "disk30s1": .init(mediaID: 45, volumeUUID: targetID,
                               name: "Erase Me", mountPath: "/Volumes/Generated")])
        return (file, state)
    }

    @Test func exactImageAndLeafAreRequiredAtLaunchButOnlyOuterSurvivesErase() throws {
        let selected = selection(), (file, state) = facts()
        let probe = APFSAttachedImageWitness.Probe(file: { state.file($0) }, disk: { state.disk($0) })
        let witness = try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected),
            plist: plist(), probe: probe)
        #expect(witness.ownerCurrentFast() && witness.targetCurrentFast())
        #expect(witness.owner.imageInode == file.imageInode && witness.owner.outerMediaID == 44)
        state.replaceDisk("disk30s1", .init(mediaID: 46, volumeUUID: UUID(),
                                             name: "Erase Me", mountPath: "/Volumes/Generated"))
        #expect(witness.ownerCurrentFast() && !witness.targetCurrentFast())
        state.replaceDisk("disk29", .init(mediaID: 99, volumeUUID: nil, name: nil, mountPath: nil))
        #expect(!witness.ownerCurrentFast() && !witness.targetCurrentFast())
        state.replaceDisk("disk29", .init(mediaID: 44, volumeUUID: nil, name: nil, mountPath: nil))
        state.replaceFile(.init(parentDevice: file.parentDevice, parentInode: file.parentInode,
            imageDevice: file.imageDevice, imageInode: file.imageInode, imageBytes: file.imageBytes,
            ownerUID: file.ownerUID, modifiedSeconds: 101, modifiedNanos: 1,
            changedSeconds: file.changedSeconds, changedNanos: file.changedNanos))
        #expect(witness.ownerCurrentFast() && !witness.targetCurrentFast())
        state.replaceFile(.init(parentDevice: file.parentDevice, parentInode: file.parentInode,
            imageDevice: file.imageDevice, imageInode: file.imageInode, imageBytes: file.imageBytes,
            ownerUID: file.ownerUID, modifiedSeconds: file.modifiedSeconds, modifiedNanos: file.modifiedNanos,
            changedSeconds: file.changedSeconds + 1, changedNanos: file.changedNanos))
        #expect(witness.ownerCurrentFast() && !witness.targetCurrentFast())
        state.replaceFile(.init(parentDevice: file.parentDevice, parentInode: file.parentInode,
            imageDevice: file.imageDevice, imageInode: file.imageInode + 1, imageBytes: file.imageBytes,
            ownerUID: file.ownerUID, modifiedSeconds: 100, modifiedNanos: 1,
            changedSeconds: file.changedSeconds, changedNanos: file.changedNanos))
        #expect(!witness.ownerCurrentFast())
    }

    @Test func shadowOrAmbiguousAttachmentCannotBePrepared() throws {
        let selected = selection(), (_, state) = facts()
        let probe = APFSAttachedImageWitness.Probe(file: { state.file($0) }, disk: { state.disk($0) })
        for data in [try plist(shadow: true), try plist(duplicate: true),
                     try plist(encrypted: true), try plist(writable: false),
                     try plist(imageType: "sparse disk image")] {
            #expect(throws: APFSVolumeFormatFailure.changed) {
                try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected),
                    plist: data, probe: probe)
            }
        }
    }

    @Test func launchInventoryMatchesTheEntireReviewedAttachment() throws {
        let selected = selection(), (_, state) = facts()
        let probe = APFSAttachedImageWitness.Probe(file: { state.file($0) }, disk: { state.disk($0) })
        let original = try plist(devices: ["disk29", "disk30s1", "disk30s2"])
        let witness = try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected),
            plist: original, probe: probe)
        #expect(witness.attachmentMatchesReview(plist: original))
        #expect(witness.attachmentMatchesReview(plist: try plist(devices: ["disk29", "disk30s2", "disk30s1"])))
        for changed in [try plist(devices: ["disk29", "disk30s1", "disk30s3"]),
                        try plist(imagePath: "/tmp/Replacement.dmg"),
                        try plist(systemImage: nil), try plist(duplicate: true)] {
            #expect(!witness.attachmentMatchesReview(plist: changed))
        }
        #expect(witness.targetCurrentFast())
    }

    @Test func competingRawClaimsAreCountedBeforeEligibility() throws {
        let selected = selection(), (_, state) = facts()
        let probe = APFSAttachedImageWitness.Probe(file: { state.file($0) }, disk: { state.disk($0) })
        let competing: [[String: Any]] = [
            ["image-path": "/tmp/OtherImage.dmg", "image-type": "RAW",
             "system-entities": [["dev-entry": "/dev/disk30s1"]]],
            ["image-path": "/tmp/OtherImage.dmg", "shadow-path": "/tmp/OtherShadow",
             "system-entities": [["dev-entry": "/dev/disk30s1"]]],
            ["image-path": "/tmp/TraverseGenerated.dmg",
             "system-entities": [["dev-entry": "/dev/disk63s1"]]],
            ["image-path": "/tmp/TraverseGenerated.dmg"],
            ["image-path": "/tmp/UnknownImage.dmg", "system-entities": ["unparseable"]],
            ["image-path": "/tmp/OtherImage.dmg", "image-alias": "/tmp/TraverseGenerated.dmg",
             "system-entities": [["dev-entry": "/dev/disk63s1"]]]
        ]
        for other in competing {
            let data = try plist(competing: [other])
            #expect(throws: APFSVolumeFormatFailure.changed) {
                try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected), plist: data, probe: probe)
            }
        }
        let unrelated = try plist(competing: [["image-path": "/tmp/Unrelated.dmg", "image-type": "RAW",
            "system-entities": [["dev-entry": "/dev/disk61"], ["dev-entry": "/dev/disk30s10"]]]])
        #expect(try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected),
            plist: unrelated, probe: probe).targetCurrentFast())
    }

    @Test func detachedFormatAndUnclassifiedAttachmentDoNotSupplyOrdinaryProof() throws {
        let selected = selection(), (_, state) = facts()
        let probe = APFSAttachedImageWitness.Probe(file: { state.file($0) }, disk: { state.disk($0) })
        let detached = try PropertyListSerialization.data(
            fromPropertyList: ["Format": "UDRW", "Properties": [String: String]()], format: .xml, options: 0)
        for data in [detached, try plist(imageType: "RAW", systemImage: nil),
                     try plist(imageType: "other", systemImage: nil), try plist(systemImage: nil),
                     try plist(systemImage: true), try plist(systemImage: 0), try plist(ownerUID: true),
                     try plist(ownerUID: -1), try plist(ownerUID: Int64(UInt32.max) + 1)] {
            #expect(throws: APFSVolumeFormatFailure.changed) {
                try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected), plist: data, probe: probe)
            }
        }
    }

    @Test func sealedFixtureInventoryRetainsOnlyItsExactCurrentGraph() throws {
        let fixture = URL(fileURLWithPath: "/tmp/GeneratedFixture/fixture.dmg")
        let before = try plist(imageType: "other", systemImage: nil, imagePath: fixture.path,
            devices: ["disk29", "disk30", "disk30s1", "disk30s2"])
        let sealed = try APFSAttachedImageWitness.sealedFixtureAttachment(fixture, plist: before)
        #expect(sealed.outer == "disk29" && sealed.devices.contains("disk30s1") && sealed.devices.contains("disk30s2"))
        let after = try plist(imageType: "other", systemImage: nil, imagePath: fixture.path,
            devices: ["disk29", "disk30", "disk30s1", "disk30s3"])
        let replaced = try APFSAttachedImageWitness.sealedFixtureAttachment(fixture, plist: after)
        #expect(replaced.outer == sealed.outer && replaced.devices.contains("disk30s1")
            && !replaced.devices.contains("disk30s2") && replaced.devices.contains("disk30s3"))
        let system = try plist(imageType: "other", systemImage: true, imagePath: fixture.path)
        #expect(throws: APFSVolumeFormatFailure.changed) {
            try APFSAttachedImageWitness.sealedFixtureAttachment(fixture, plist: system)
        }
    }

    @Test func sealedFixtureReviewRequiresExactReceiptAndSelectedLeaf() throws {
        let path = "/tmp/GeneratedFixture/fixture.dmg"
        let selected = selection(), (file, state) = facts(path: path)
        let probe = APFSAttachedImageWitness.Probe(file: { state.file($0) }, disk: { state.disk($0) })
        let owner = APFSVolumeFormatImageOwner(imagePath: path, parentDevice: file.parentDevice,
            parentInode: file.parentInode, imageDevice: file.imageDevice, imageInode: file.imageInode,
            imageBytes: file.imageBytes, ownerUID: file.ownerUID, outerDevice: "disk29", outerMediaID: 44)
        let observed = try plist(imageType: "other", systemImage: nil, imagePath: path)
        let witness = try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected), plist: observed,
            probe: probe, expectedFixtureOwner: owner)
        #expect(witness.owner == owner && witness.targetCurrentFast())
        #expect(throws: APFSVolumeFormatFailure.changed) {
            try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected), plist: observed, probe: probe)
        }
        for rejected in [try plist(imageType: "other", systemImage: true, imagePath: path),
                         try plist(imageType: "other", systemImage: nil, imagePath: path, devices: ["disk29", "disk30s2"]),
                         try plist(imageType: "other", systemImage: nil, imagePath: "/tmp/OtherFixture/fixture.dmg")] {
            #expect(throws: APFSVolumeFormatFailure.changed) {
                try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected), plist: rejected,
                    probe: probe, expectedFixtureOwner: owner)
            }
        }
        state.replaceFile(.init(parentDevice: file.parentDevice, parentInode: file.parentInode,
            imageDevice: file.imageDevice, imageInode: file.imageInode + 1, imageBytes: file.imageBytes,
            ownerUID: file.ownerUID, modifiedSeconds: file.modifiedSeconds, modifiedNanos: file.modifiedNanos,
            changedSeconds: file.changedSeconds, changedNanos: file.changedNanos))
        #expect(throws: APFSVolumeFormatFailure.changed) {
            try APFSAttachedImageWitness.make(selected: selected, inspection: inspection(selected), plist: observed,
                probe: probe, expectedFixtureOwner: owner)
        }
    }

    @Test func earlyOutputEOFStillHonorsInquiryDeadline() throws {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exec 1>&-; exec sleep 3"]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: APFSVolumeFormatFailure.unavailable) {
            _ = try APFSAttachedImageWitness.readBoundedInfo(child, output: output, seconds: 0.2)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test func completedReadOnlyChildReturnsOnlyAfterExit() throws {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/echo")
        child.arguments = ["inert"]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let bytes = try APFSAttachedImageWitness.readBoundedInfo(child, output: output, seconds: 2)
        #expect(String(decoding: bytes, as: UTF8.self) == "inert\n")
        #expect(!child.isRunning && child.terminationStatus == 0)
    }

    @Test func stoppedQueryReapsItsChildAfterBothStreamsClose() throws {
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exec 1>&- 2>&-; exec /bin/sleep 3"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = errors
        try child.run()
        let control = ReadOnlyToolChildControl()
        control.attach(child)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(150)) {
            control.requestStop()
        }
        let start = ProcessInfo.processInfo.systemUptime
        let result = NativeToolPipes.collect(child, output: output, outputLimit: 16,
            errors: errors, errorLimit: 16, query: .init(control: control, timeout: nil))
        control.detachAfterReap()
        #expect(result.stopped && !child.isRunning && result.status == -1)
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test func boundedMutationOutputDoesNotStopSubmittedChild() throws {
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf 'output'; printf 'errors' >&2"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = errors
        try child.run()
        let result = NativeToolPipes.collect(child, output: output, outputLimit: 3,
            errors: errors, errorLimit: 4)
        #expect(result.stdout == Data("out".utf8) && result.stderr == Data("erro".utf8))
        #expect(result.stdoutTruncated && result.stderrTruncated)
        #expect(result.complete && !result.stopped && !child.isRunning && result.status == 0)
    }
}
