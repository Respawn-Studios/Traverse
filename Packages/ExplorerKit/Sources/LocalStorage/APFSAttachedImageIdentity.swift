import CoreFoundation
import Darwin
import DiskArbitration
import Foundation
import IOKit

/// A typed, read-only projection of one hdiutil attachment. The image path
/// remains private operation state and never enters diagnostics or UI text.
private struct APFSImageAttachment: Equatable, Sendable {
    let imagePath: String
    let ownerUID: UInt32
    let outerDevice: String
    let deviceNames: Set<String>
}

/// One selected ordinary APFS leaf on an exact owned, local, writable .dmg.
/// Preparation and launch bind the exact attachment inventory. Fast launch
/// and terminal checks also use file descriptors and IOMedia identity.
public struct APFSAttachedImageWitness: Sendable {
    struct FileFacts: Equatable, Sendable {
        let parentDevice: Int64, parentInode: UInt64
        let imageDevice: Int64, imageInode: UInt64, imageBytes: Int64
        let ownerUID: UInt32
        let modifiedSeconds: Int64, modifiedNanos: Int64
        let changedSeconds: Int64, changedNanos: Int64
    }
    public struct DiskFacts: Sendable {
        public let mediaID: UInt64
        public let volumeUUID: UUID?
        public let name: String?
        public let mountPath: String?
    }
    struct Probe: Sendable {
        let file: @Sendable (String) -> FileFacts?
        let disk: @Sendable (String) -> DiskFacts?
        static let live = Probe(file: APFSAttachedImageWitness.realFile,
                                disk: APFSAttachedImageWitness.realDisk)
    }

    public let owner: APFSVolumeFormatImageOwner
    private let selected: ManagedVolume
    private let selectedDevice: String
    private let attachment: APFSImageAttachment
    private let originalModifiedSeconds: Int64
    private let originalModifiedNanos: Int64
    private let originalChangedSeconds: Int64
    private let originalChangedNanos: Int64
    private let probe: Probe

    public static func prepare(_ selected: ManagedVolume) async throws -> Self {
        try await prepare(selected, expectedFixtureOwner: nil)
    }

    /// The signed generated app has its own case and one-use target seal. It
    /// can bind that exact fixture when hdiutil omits an ordinary image field.
    @_spi(Qualification)
    public static func prepareSealedFixture(_ selected: ManagedVolume,
                                           expectedOwner: APFSVolumeFormatImageOwner) async throws -> Self {
        try await prepare(selected, expectedFixtureOwner: expectedOwner)
    }

    private static func prepare(_ selected: ManagedVolume,
                                expectedFixtureOwner: APFSVolumeFormatImageOwner?) async throws -> Self {
        try Task.checkCancellation()
        guard selected.deviceKind == .diskImage, selected.isInternal == false,
              selected.volumeUUID != nil, selected.mediaID != nil, selected.group != nil,
              selected.url != nil else { throw APFSVolumeFormatFailure.unsupported }
        let inspection = try await VolumeLifecycle.shared.inspect(selected)
        let witness: Self = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Result { () throws -> Self in
                    let data = try Self.readOnlyInfo()
                    let witness = try Self.make(selected: selected, inspection: inspection, plist: data, probe: .live,
                                                expectedFixtureOwner: expectedFixtureOwner)
                    if expectedFixtureOwner == nil {
                        try Self.checkStartupStorage(outside: witness.owner.outerMediaID)
                    }
                    return witness
                }
                continuation.resume(with: result)
            }
        }
        // The read-only child is owned through its bounded real return even if
        // the caller stopped waiting during the inquiry.
        try Task.checkCancellation()
        return witness
    }

    /// These facts survive the target's expected APFS UUID replacement.
    public func ownerCurrentFast() -> Bool {
        Self.sameBackingFile(owner, observed: probe.file(owner.imagePath))
            && probe.disk(owner.outerDevice)?.mediaID == owner.outerMediaID
    }

    /// Run on the ordinary tool queue immediately before the fast target check.
    /// Refresh observations without replacing any identity from the review.
    public func attachmentCurrentAtLaunch() -> Bool {
        guard let plist = try? Self.readOnlyInfo() else { return false }
        guard attachmentMatchesReview(plist: plist) else { return false }
        do { try Self.checkStartupStorage(outside: owner.outerMediaID); return true }
        catch { return false }
    }

    func attachmentMatchesReview(plist: Data) -> Bool {
        Self.ordinaryAttachment(in: plist, selectedDevice: selectedDevice) == attachment
    }

    /// Only a prelaunch check: a successful erase replaces this leaf.
    public func targetCurrentFast() -> Bool {
        guard let file = probe.file(owner.imagePath),
              Self.sameBackingFile(owner, observed: file),
              file.modifiedSeconds == originalModifiedSeconds,
              file.modifiedNanos == originalModifiedNanos,
              file.changedSeconds == originalChangedSeconds,
              file.changedNanos == originalChangedNanos,
              probe.disk(owner.outerDevice)?.mediaID == owner.outerMediaID,
              let disk = probe.disk(selectedDevice) else { return false }
        return disk.mediaID == selected.mediaID && disk.volumeUUID == selected.volumeUUID
            && disk.name == selected.name && disk.mountPath == selected.url?.standardizedFileURL.path
    }

    public static func backingFileCurrent(_ owner: APFSVolumeFormatImageOwner) -> Bool {
        sameBackingFile(owner, observed: realFile(owner.imagePath))
    }

    static func make(selected: ManagedVolume, inspection: VolumeInspection, plist: Data, probe: Probe,
                     expectedFixtureOwner: APFSVolumeFormatImageOwner? = nil) throws -> Self {
        guard selected.deviceKind == .diskImage, selected.isInternal == false,
              inspection.volume == selected, inspection.fields.fileSystem?.lowercased() == "apfs",
              inspection.fields.writable == true,
              inspection.deviceName.range(of: #"\Adisk[0-9]{1,6}s[0-9]{1,6}\z"#, options: .regularExpression) != nil,
              let selectedID = selected.volumeUUID, let selectedMedia = selected.mediaID,
              let group = selected.group, selectedMedia > 0, group > 0,
              let mount = selected.url?.standardizedFileURL else { throw APFSVolumeFormatFailure.unsupported }
        let attached: APFSImageAttachment
        if let expectedFixtureOwner {
            attached = try sealedAttachment(in: plist, image: URL(fileURLWithPath: expectedFixtureOwner.imagePath))
            guard attached.deviceNames.contains(inspection.deviceName) else { throw APFSVolumeFormatFailure.changed }
        } else {
            guard let value = ordinaryAttachment(in: plist, selectedDevice: inspection.deviceName) else {
                throw APFSVolumeFormatFailure.changed
            }
            attached = value
        }
        guard let file = probe.file(attached.imagePath), file.ownerUID == attached.ownerUID,
              let outer = probe.disk(attached.outerDevice), outer.mediaID == group,
              let leaf = probe.disk(inspection.deviceName), leaf.mediaID == selectedMedia,
              leaf.volumeUUID == selectedID, leaf.name == selected.name,
              leaf.mountPath == mount.path else { throw APFSVolumeFormatFailure.changed }
        let owner = APFSVolumeFormatImageOwner(imagePath: attached.imagePath,
            parentDevice: file.parentDevice, parentInode: file.parentInode,
            imageDevice: file.imageDevice, imageInode: file.imageInode, imageBytes: file.imageBytes,
            ownerUID: file.ownerUID, outerDevice: attached.outerDevice, outerMediaID: outer.mediaID)
        guard owner.validate() else { throw APFSVolumeFormatFailure.unsupported }
        if let expectedFixtureOwner, owner != expectedFixtureOwner { throw APFSVolumeFormatFailure.changed }
        let witness = Self(owner: owner, selected: selected, selectedDevice: inspection.deviceName, attachment: attached,
            originalModifiedSeconds: file.modifiedSeconds, originalModifiedNanos: file.modifiedNanos,
            originalChangedSeconds: file.changedSeconds, originalChangedNanos: file.changedNanos,
            probe: probe)
        guard witness.targetCurrentFast() else { throw APFSVolumeFormatFailure.changed }
        return witness
    }

    private static func ordinaryAttachment(in plist: Data, selectedDevice: String) -> APFSImageAttachment? {
        let leafName = "/dev/" + selectedDevice
        guard let (attached, record) = attachment(in: plist, matching: { rawDeviceClaims($0).contains(leafName) }),
              record["image-type"] as? String == "read/write disk image",
              APFSContainerObservation.boolean(record["system-image"]) == false else { return nil }
        return attached
    }

    private static func checkStartupStorage(outside group: UInt64) throws {
        do { try VolumeLifecycle.shared.validateStartupStorage(outside: group) }
        catch { throw APFSVolumeFormatFailure.protected }
    }

    private static func sameBackingFile(_ owner: APFSVolumeFormatImageOwner, observed file: FileFacts?) -> Bool {
        guard owner.validate(), owner.ownerUID == geteuid(), let file else { return false }
        return file.parentDevice == owner.parentDevice && file.parentInode == owner.parentInode
            && file.imageDevice == owner.imageDevice && file.imageInode == owner.imageInode
            && file.imageBytes == owner.imageBytes && file.ownerUID == owner.ownerUID
    }

    private static func rawDeviceClaims(_ record: [String: Any]) -> [String] {
        // Find exact claims even if another field makes the record ineligible.
        (record["system-entities"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["dev-entry"] as? String }
    }

    private static func attachment(in data: Data, matching: ([String: Any]) -> Bool)
        -> (APFSImageAttachment, [String: Any])? {
        guard !data.isEmpty, data.count <= 2 << 20,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]], images.count <= 256,
              images.allSatisfy({ row in
                  guard let entities = row["system-entities"] as? [[String: Any]] else { return false }
                  return entities.allSatisfy { $0["dev-entry"] is String }
              }),
              let item = images.filter(matching).only,
              let path = item["image-path"] as? String, path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              URL(fileURLWithPath: path).pathExtension.lowercased() == "dmg",
              noShadow(item, key: "shadow-path"), noShadow(item, key: "image-shadow-path"),
              APFSContainerObservation.boolean(item["writeable"]) == true,
              APFSContainerObservation.boolean(item["image-encrypted"]) == false,
              item["image-alias"] == nil || item["image-alias"] as? String == path,
              let uid = APFSContainerObservation.unsigned(item["owner-uid"]), uid == UInt64(geteuid()),
              let entities = item["system-entities"] as? [[String: Any]], !entities.isEmpty else { return nil }
        let names = rawDeviceClaims(item)
        guard names.count == entities.count,
              names.allSatisfy({ $0.hasPrefix("/dev/") && APFSContainerObservation.validDevice(String($0.dropFirst(5))) }),
              let first = names.first, APFSContainerObservation.validContainer(String(first.dropFirst(5))) else { return nil }
        let claims = Set(names)
        guard claims.count == names.count,
              images.filter({ $0["image-path"] as? String == path || $0["image-alias"] as? String == path }).count == 1,
              images.filter({ !claims.isDisjoint(with: rawDeviceClaims($0)) }).count == 1 else { return nil }
        return (APFSImageAttachment(imagePath: path, ownerUID: UInt32(uid),
            outerDevice: String(first.dropFirst(5)), deviceNames: Set(names.map { String($0.dropFirst(5)) })), item)
    }

    /// Only the generated review uses this inventory projection. Its caller
    /// independently seals the fixture, backing file and media IDs. It does
    /// not grant an ordinary image witness or synthesize a missing system flag.
    @_spi(Qualification)
    public static func observeSealedFixtureAttachment(_ image: URL) throws -> (outer: String, devices: Set<String>) {
        try sealedFixtureAttachment(image, plist: readOnlyInfo())
    }

    static func sealedFixtureAttachment(_ image: URL, plist: Data) throws -> (outer: String, devices: Set<String>) {
        let attached = try sealedAttachment(in: plist, image: image)
        return (attached.outerDevice, attached.deviceNames)
    }

    private static func sealedAttachment(in plist: Data, image: URL) throws -> APFSImageAttachment {
        guard image.isFileURL, image.lastPathComponent == "fixture.dmg",
              let (attached, record) = attachment(in: plist, matching: { $0["image-path"] as? String == image.path }),
              record["system-image"] == nil || APFSContainerObservation.boolean(record["system-image"]) == false else {
            throw APFSVolumeFormatFailure.changed
        }
        return attached
    }

    private static func noShadow(_ item: [String: Any], key: String) -> Bool {
        guard let value = item[key] else { return true }
        return value as? String == "<none>"
    }

    private static func realFile(_ path: String) -> FileFacts? {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.standardizedFileURL.path == path,
              url.pathExtension.lowercased() == "dmg" else { return nil }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { return nil }; defer { close(parent) }
        let file = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { return nil }; defer { close(file) }
        var p = stat(), f = stat(), fs = statfs()
        guard fstat(parent, &p) == 0, fstat(file, &f) == 0, fstatfs(file, &fs) == 0,
              p.st_mode & S_IFMT == S_IFDIR, f.st_mode & S_IFMT == S_IFREG,
              f.st_uid == geteuid(), f.st_nlink == 1, f.st_size > 0,
              f.st_mode & 0o200 != 0 else { return nil }
        let kind = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard kind == "apfs", fs.f_flags & UInt32(MNT_LOCAL) != 0,
              fs.f_flags & UInt32(MNT_RDONLY) == 0 else { return nil }
        return .init(parentDevice: Int64(p.st_dev), parentInode: p.st_ino,
            imageDevice: Int64(f.st_dev), imageInode: f.st_ino, imageBytes: Int64(f.st_size),
            ownerUID: f.st_uid, modifiedSeconds: Int64(f.st_mtimespec.tv_sec),
            modifiedNanos: Int64(f.st_mtimespec.tv_nsec),
            changedSeconds: Int64(f.st_ctimespec.tv_sec), changedNanos: Int64(f.st_ctimespec.tv_nsec))
    }

    private static func realDisk(_ device: String) -> DiskFacts? {
        guard device.range(of: #"\Adisk[0-9]{1,6}(s[0-9]{1,6}){0,2}\z"#,
                           options: .regularExpression) != nil,
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = device.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              let description = DADiskCopyDescription(disk) as NSDictionary? else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS, id > 0 else { return nil }
        let value = description[kDADiskDescriptionVolumeUUIDKey]
        let uuid: UUID?
        if let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() {
            uuid = UUID(uuidString: CFUUIDCreateString(nil, (value as! CFUUID)) as String)
        } else { uuid = nil }
        return .init(mediaID: id, volumeUUID: uuid,
            name: description[kDADiskDescriptionVolumeNameKey] as? String,
            mountPath: (description[kDADiskDescriptionVolumePathKey] as? URL)?.standardizedFileURL.path)
    }

    private static func readOnlyInfo() throws -> Data {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        child.arguments = ["info", "-plist"]
        child.environment = ["LANG": "C", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        return try readBoundedInfo(child, output: output, seconds: 20)
    }

    /// Package tests can exercise process lifetime with an inert child. The
    /// production entry point above fixes the executable and arguments.
    static func readBoundedInfo(_ child: Process, output: Pipe, seconds: TimeInterval) throws -> Data {
        try child.run()
        let control = ReadOnlyToolChildControl()
        control.attach(child)
        let result = NativeToolPipes.collect(child, output: output, outputLimit: 2 << 20,
            query: .init(control: control, timeout: seconds))
        control.detachAfterReap()
        guard result.status == 0, result.complete, !result.stopped, !result.stdoutTruncated else {
            throw APFSVolumeFormatFailure.unavailable
        }
        return result.stdout
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
