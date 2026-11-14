import Darwin
import Foundation
import Testing
@testable import StorageAnalysis

@Suite struct StartupVolumePlanTests {
    private let groupID = "11111111-1111-4111-8111-111111111111"
    private let containerID = "22222222-2222-4222-8222-222222222222"
    private let systemID = "33333333-3333-4333-8333-333333333333"
    private let dataID = "44444444-4444-4444-8444-444444444444"
    private let viewID = "55555555-5555-4555-8555-555555555555"
    private let snapshotID = "66666666-6666-4666-8666-666666666666"
    private func info(_ device: String, id: String, mount: String? = nil, snapshot: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["FilesystemType": "apfs", "DeviceIdentifier": device,
            "APFSContainerReference": "disk9", "APFSVolumeGroupID": groupID,
            "VolumeUUID": id, "DiskUUID": id, "APFSSnapshot": snapshot, "Locked": false]
        if let mount { value["MountPoint"] = mount }
        if snapshot { value["APFSSnapshotUUID"] = snapshotID }
        return value
    }
    private var root: [String: Any] { info("disk9s1s42", id: viewID, mount: "/", snapshot: true) }
    private var group: [String: Any] {
        ["Containers": [["ContainerReference": "disk9", "APFSContainerUUID": containerID,
            "VolumeGroups": [["APFSVolumeGroupUUID": groupID, "Volumes": [
                ["Role": "System", "DeviceIdentifier": "disk9s1", "DiskUUID": systemID],
                ["Role": "Data", "DeviceIdentifier": "disk9s7", "DiskUUID": dataID]]]]]]]
    }
    private var container: [String: Any] {
        ["Containers": [["ContainerReference": "disk9", "APFSContainerUUID": containerID,
            "CapacityCeiling": 1_000_000, "CapacityFree": 250_000,
            "Volumes": [["DeviceIdentifier": "disk9s1", "APFSVolumeUUID": systemID, "Roles": ["System"]],
                        ["DeviceIdentifier": "disk9s7", "APFSVolumeUUID": dataID, "Roles": ["Data"]]]]]]
    }
    private func assemble(root: [String: Any]? = nil, group: [String: Any]? = nil, container: [String: Any]? = nil,
                          data: [String: Any]? = nil, system: [String: Any]? = nil) throws -> StartupFacts {
        let root = try StartupFactDecoder.info(root ?? self.root)
        let group = try StartupFactDecoder.group(group ?? self.group, root: root)
        return try StartupFactDecoder.assemble(root: root, group: group, container: container ?? self.container,
            system: StartupFactDecoder.info(system ?? info("disk9s1", id: systemID)),
            data: StartupFactDecoder.info(data ?? info("disk9s7", id: dataID, mount: "/Volumes/Explicitly discovered Data")))
    }
    @Test func explicitGroupAcceptsSnapshotViewWithoutGuessingItsBSDParent() throws {
        let facts = try assemble()
        #expect(facts.active.volume != facts.system.volume)
        #expect(facts.active.snapshot != nil)
        #expect(facts.data.mount == "/Volumes/Explicitly discovered Data")
        #expect(facts.membership.system.device == "disk9s1")
    }
    @Test func sandboxMayOmitLockReportingWithoutOmittingIdentityOrMountedSources() throws {
        var root = self.root
        var data = info("disk9s7", id: dataID, mount: "/Volumes/Explicitly discovered Data")
        var system = info("disk9s1", id: systemID)
        root.removeValue(forKey: "Locked")
        data.removeValue(forKey: "Locked")
        system.removeValue(forKey: "Locked")
        let facts = try assemble(root: root, data: data, system: system)
        #expect(facts.active.mount == "/")
        #expect(facts.active.locked == nil && facts.system.locked == nil && facts.data.locked == nil)
        #expect(facts.data.mount == "/Volumes/Explicitly discovered Data")
        data.removeValue(forKey: "MountPoint")
        #expect(throws: StartupStorageFailure.self) { try assemble(root: root, data: data, system: system) }
    }
    @Test func unknownLockReportingNeverOverridesLockedMembersOrMissingIdentity() throws {
        var root = self.root; root.removeValue(forKey: "Locked")
        var system = info("disk9s1", id: systemID); system["Locked"] = true
        #expect(throws: StartupStorageFailure.self) { try assemble(root: root, system: system) }
        for bad: Any in ["false", 0, NSNull()] {
            root["Locked"] = bad
            #expect(throws: StartupStorageFailure.self) { try assemble(root: root) }
        }
        root = self.root; root.removeValue(forKey: "Locked"); root.removeValue(forKey: "VolumeUUID")
        #expect(throws: StartupStorageFailure.self) { try assemble(root: root) }
        var containers = container["Containers"] as! [[String: Any]]
        var volumes = containers[0]["Volumes"] as! [[String: Any]]
        volumes[1]["Locked"] = true; containers[0]["Volumes"] = volumes
        #expect(throws: StartupStorageFailure.self) { try assemble(container: ["Containers": containers]) }
    }
    @Test func redactedCapacityCannotPreventVerifiedCoverageOrInventCapacity() throws {
        var containers = container["Containers"] as! [[String: Any]]
        containers[0].removeValue(forKey: "CapacityCeiling")
        containers[0].removeValue(forKey: "CapacityFree")
        let facts = try assemble(container: ["Containers": containers])
        #expect(facts.membership.data.volume == facts.data.volume)
        #expect(facts.containerCapacity == nil && facts.containerFree == nil)
        containers[0]["CapacityCeiling"] = "1000"
        #expect(throws: StartupStorageFailure.self) { try assemble(container: ["Containers": containers]) }
    }
    @Test func matchingNamesContainerAndDeviceSuffixCannotInventGroupMembership() {
        for key in ["APFSVolumeGroupID", "VolumeUUID", "DiskUUID"] {
            var root = self.root; root.removeValue(forKey: key)
            #expect(throws: StartupStorageFailure.self) { try assemble(root: root) }
        }
        var root = self.root; root["APFSVolumeGroupID"] = containerID
        #expect(throws: StartupStorageFailure.self) { try assemble(root: root) }
        root = self.root; root["VolumeUUID"] = dataID
        #expect(throws: StartupStorageFailure.self) { try assemble(root: root) }
    }
    @Test func unknownDuplicateRolesAndForeignMembersRefuse() {
        for roles in [["Data", "Data"], ["System", "VM"], ["System", "Data", "Preboot"]] {
            var c = group["Containers"] as! [[String: Any]], groups = c[0]["VolumeGroups"] as! [[String: Any]]
            groups[0]["Volumes"] = roles.enumerated().map { i, role in ["Role": role, "DeviceIdentifier": "disk9s\(i+1)", "DiskUUID": i == 0 ? systemID : dataID] }
            c[0]["VolumeGroups"] = groups
            #expect(throws: StartupStorageFailure.self) { try assemble(group: ["Containers": c]) }
        }
        var data = info("disk9s7", id: systemID, mount: "/Volumes/Data")
        #expect(throws: StartupStorageFailure.self) { try assemble(data: data) }
        data = info("disk9s7", id: dataID, mount: "/Volumes/Data"); data["APFSContainerReference"] = "disk8"
        #expect(throws: StartupStorageFailure.self) { try assemble(data: data) }
    }
    @Test func unmountedLockedWrongTypeAndMalformedFactsStayUnavailable() {
        var data = info("disk9s7", id: dataID)
        #expect(throws: StartupStorageFailure.self) { try assemble(data: data) }
        for (key, value): (String, Any) in [("Locked", true), ("Locked", "false"), ("MountPoint", "/Volumes/../Data"), ("FilesystemType", "hfs")] {
            data = info("disk9s7", id: dataID, mount: "/Volumes/Data"); data[key] = value
            #expect(throws: StartupStorageFailure.self) { try assemble(data: data) }
        }
        #expect(throws: StartupStorageFailure.self) { try APFSIdentity<APFSGroupTag>("00000000-0000-0000-0000-000000000000") }
        for value: Any in [-1, true, 1.5, Float(1.0), "1"] {
            #expect(throws: StartupStorageFailure.self) { try StartupFactDecoder.unsigned(["x": value], "x") }
        }
    }
    @Test func emptyBackingMountIsAbsentAndNeverMakesDataAvailable() throws {
        let backing = try StartupFactDecoder.info(info("disk9s1", id: systemID, mount: ""))
        #expect(backing.mount == nil)
        #expect(throws: StartupStorageFailure.self) {
            try assemble(data: info("disk9s7", id: dataID, mount: ""))
        }
        var malformed = info("disk9s7", id: dataID); malformed["MountPoint"] = false
        #expect(throws: StartupStorageFailure.self) { try StartupFactDecoder.info(malformed) }
    }
    @Test func plistDecodeIsBoundedAndExternalEntitiesNeverReachPropertyListLoading() throws {
        let encoded = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        #expect(try StartupFactDecoder.info(BoundedStartupPlist.decode(encoded)).device == "disk9s1s42")
        let external = Data("<?xml version=\"1.0\"?><!DOCTYPE plist [<!ENTITY x SYSTEM \"file:///not-an-admitted-file\">]><plist><dict><key>x</key><string>&x;</string></dict></plist>".utf8)
        #expect(throws: StartupStorageFailure.self) { try BoundedStartupPlist.decode(external) }
        let deep = Data(("<?xml version=\"1.0\"?><plist>" + String(repeating: "<array>", count: 1000) + String(repeating: "</array>", count: 1000) + "</plist>").utf8)
        #expect(throws: StartupStorageFailure.self) { try BoundedStartupPlist.decode(deep) }
        #expect(throws: StartupStorageFailure.self) { try BoundedStartupPlist.decode(Data(repeating: 0, count: (4 << 20) + 1)) }
    }
    @Test func extendedNativeFieldsRequireExactReturnedMasksAndDistinctPhysicalDomain() throws {
        var bytes = Data(repeating: 0, count: 48)
        func put(_ value: UInt64, at offset: Int, length: Int = 4) {
            for index in 0..<length { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        put(48, at: 0); put(UInt64(ATTR_CMN_RETURNED_ATTRS) | UInt64(ATTR_CMN_DEVID) | UInt64(ATTR_CMN_FILEID), at: 4)
        put(UInt64(ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_REALFSID), at: 20)
        put(7, at: 24); put(UInt64.max, at: 28, length: 8); put(7, at: 36); put(9, at: 40); put(10, at: 44)
        let fields = try StartupNativeRoot.decode(bytes)
        #expect(fields.device == 7 && fields.realDevice == 7 && fields.inode == UInt64.max)
        put(0, at: 20)
        #expect(throws: StartupStorageFailure.self) { try StartupNativeRoot.decode(bytes) }
        #expect(throws: StartupStorageFailure.self) { try StartupNativeRoot.decode(Data(repeating: 0, count: 47)) }
    }
}
