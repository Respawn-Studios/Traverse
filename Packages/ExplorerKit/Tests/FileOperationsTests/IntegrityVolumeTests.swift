import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct IntegrityVolumeManifest: Decodable {
    let version: Int
    let jobID: String
    let imageBytes: Int64
    let imageDev: Int64
    let imageIno: UInt64
    let rootDev: Int64
    let rootIno: UInt64
    let volumeUUID: String
    let mountDev: Int64
    let mountIno: UInt64
}

private struct IntegrityVolumeFixture {
    let root: URL
    let source: URL
    let mount: URL
    let control: DirectoryAnchor
    let manifest: IntegrityVolumeManifest

    init(root: URL, requiresMount: Bool = true) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/integrity-volumes", isDirectory: true)
        guard root.deletingLastPathComponent().path == base.path, UUID(uuidString: root.lastPathComponent) != nil else {
            throw FileOperationFailure.invalidRequest
        }
        let anchor = try DirectoryAnchor(root, resolve: false)
        var attributes = stat()
        guard fstat(anchor.fd, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0 else {
            throw FileOperationFailure.accessDenied
        }
        self.root = root
        source = root.appendingPathComponent("source", isDirectory: true)
        mount = root.appendingPathComponent("mount", isDirectory: true)
        control = try DirectoryAnchor(root.appendingPathComponent("control", isDirectory: true), resolve: false)
        manifest = try JSONDecoder().decode(IntegrityVolumeManifest.self,
            from: OperationJournal.read(name: "manifest.json", anchor: control))
        guard manifest.version == 1, manifest.jobID == root.lastPathComponent, manifest.imageBytes == 512 * 1024 * 1024,
              Int64(anchor.identity.device) == manifest.rootDev, anchor.identity.inode == manifest.rootIno else {
            throw FileOperationFailure.invalidRequest
        }
        let image = try EntrySnapshot(parent: anchor.fd, name: "fixture.dmg")
        guard image.type == S_IFREG, image.size == manifest.imageBytes, Int64(image.device) == manifest.imageDev,
              image.inode == manifest.imageIno else { throw FileOperationFailure.sourceChanged }
        let sourceAnchor = try DirectoryAnchor(source, resolve: false)
        guard sourceAnchor.identity.device == anchor.identity.device else { throw FileOperationFailure.invalidRequest }
        if requiresMount { try validateMount() }
    }

    func validateMount() throws {
        let mounted = try DirectoryAnchor(mount, resolve: false)
        let uuid = try mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard Int64(mounted.identity.device) == manifest.mountDev, mounted.identity.inode == manifest.mountIno,
              Int64(mounted.identity.device) != manifest.rootDev,
              uuid?.uppercased() == manifest.volumeUUID.uppercased() else { throw FileOperationFailure.destinationChanged }
    }

    var hostService: RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: root.appendingPathComponent("host-journal"))
    }

    func observedMount() throws -> FileOperationSelection {
        let mounted = try DirectoryAnchor(mount, resolve: false)
        guard Int64(mounted.identity.device) == manifest.mountDev, mounted.identity.inode == manifest.mountIno else {
            throw FileOperationFailure.destinationChanged
        }
        return FileOperationSelection(urls: [mount], identities: [mounted.identity])
    }

    func createSource(_ name: String) throws {
        let parent = try DirectoryAnchor(source, resolve: false)
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        // Generated payload only; no sparse allocation, cloning or personal input.
        let block = [UInt8](repeating: 0x6b, count: 262_144)
        for _ in 0..<64 {
            try block.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw posixFailure() }
                    offset += count
                }
            }
        }
        guard fsync(fd) == 0 else { throw posixFailure() }
        try syncDirectory(parent)
    }

    func receipt(phase: String, values: [String: String]) throws {
        var result = values
        result["version"] = "1"
        result["jobID"] = manifest.jobID
        result["phase"] = phase
        result["pid"] = String(getpid())
        try OperationJournal.writeExclusive(JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                                             name: phase + ".json", anchor: control)
    }

    func controlExists(_ name: String) -> Bool {
        (try? EntrySnapshot(parent: control.fd, name: name)) != nil
    }
}

private final class IntegrityNativeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func mark() { lock.withLock { entered = true } }
    var value: Bool { lock.withLock { entered } }
}

private func integrityStatus(_ result: FileOperationResult) -> String {
    result.items.map { item in
        switch item.status {
        case .succeeded: "succeeded"
        case .skipped: "skipped"
        case .notStarted: "notStarted"
        case .cancelled: "cancelled"
        case .failed(let cause): cause.rawValue
        }
    }.joined(separator: ",")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_INTEGRITY_VOLUME_PHASE"] != nil,
               "Explicit owned 512 MiB APFS image qualification only."))
func integrityVolumeQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["MAC_EXPLORER_INTEGRITY_VOLUME_PHASE"])
    guard ["prepare", "destination-full", "mid-copy-full", "retry-copy", "prepared-detach"].contains(phase) else {
        throw FileOperationFailure.invalidRequest
    }
    let root = URL(fileURLWithPath: try #require(environment["MAC_EXPLORER_INTEGRITY_VOLUME_ROOT"]), isDirectory: true)
    let fixture = try IntegrityVolumeFixture(root: root)
    let source = fixture.source.appendingPathComponent("payload.bin")
    let destination = fixture.mount.appendingPathComponent("payload.bin")
    switch phase {
    case "prepare":
        try fixture.createSource("payload.bin")
        try fixture.createSource("disconnect.bin")
        let tree = try verifiedTree(source, cancellation: OperationCancellation())
        _ = try await fixture.hostService.recoveryRecords()
        try fixture.receipt(phase: phase, values: ["sourceBytes": String(tree.identity.size), "sourceDigest": tree.digest])

    case "destination-full", "mid-copy-full":
        let before = try verifiedTree(source, cancellation: OperationCancellation())
        let probe = IntegrityNativeProbe()
        let hooks = RecoveryHooks(copyFaults: CopyFaultHooks(beforeNativeCopy: { _, _ in probe.mark() }))
        let service = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("host-journal"), hooks: hooks)
        let selection = try fixture.observedMount()
        let request: FileOperationRequest = phase == "mid-copy-full"
            ? .move(sources: [source], destinationDirectory: fixture.mount)
            : .copy(sources: [source], destinationDirectory: fixture.mount)
        let outcome = await service.perform(request, observing: selection)
        #expect(outcome.result.disposition == .failed)
        #expect(outcome.result.items.contains { $0.status == .failed(.outOfSpace) })
        #expect(before.matches(try verifiedTree(source, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: destination.path))
        if phase == "mid-copy-full" { #expect(probe.value) }
        try fixture.validateMount()
        let retained: RecoveryRetentionRecord?
        if let id = outcome.recordID { retained = try await service.retentionRecord(recordID: id) }
        else { retained = nil }
        try fixture.receipt(phase: phase, values: ["disposition": outcome.result.disposition.rawValue,
            "causes": integrityStatus(outcome.result), "sourcePreserved": "true", "publishedDestination": "false",
            "operation": phase == "mid-copy-full" ? "cross-volume-move" : "copy",
            "nativeCopyEntered": String(probe.value), "recordCreated": String(outcome.recordID != nil),
            "recordID": outcome.recordID?.uuidString ?? "", "recordState": retained?.state ?? "unrecorded",
            "retainedAreaCount": String(retained?.areas.count ?? 0), "cleanupProtected": String(retained?.canCleanup == false)])

    case "retry-copy":
        let prior = try JSONSerialization.jsonObject(with: OperationJournal.read(name: "mid-copy-full.json", anchor: fixture.control)) as? [String: String]
        let priorID = try #require(prior?["recordID"].flatMap(UUID.init(uuidString:)))
        let priorRecord = try await fixture.hostService.retentionRecord(recordID: priorID)
        #expect(priorRecord.state == "needsReview")
        #expect(!priorRecord.canCleanup)
        #expect(!FileManager().fileExists(atPath: destination.path))
        let selection = try fixture.observedMount()
        let outcome = await fixture.hostService.perform(.copy(sources: [source], destinationDirectory: fixture.mount), observing: selection)
        #expect(outcome.result.disposition == .succeeded)
        let original = try verifiedTree(source, cancellation: OperationCancellation())
        let copied = try verifiedTree(destination, cancellation: OperationCancellation())
        #expect(original.digest == copied.digest)
        try fixture.receipt(phase: phase, values: ["disposition": outcome.result.disposition.rawValue,
            "sourcePreserved": "true", "publishedDestination": "true", "destinationVerified": "true",
            "previousRecordState": priorRecord.state, "previousCleanupProtected": "true",
            "previousRetainedAreaCount": String(priorRecord.areas.count)])

    case "prepared-detach":
        let input = fixture.source.appendingPathComponent("disconnect.bin")
        let before = try verifiedTree(input, cancellation: OperationCancellation())
        let service = fixture.hostService
        let selection = try fixture.observedMount()
        let plan = try await service.prepareTransfer(sources: [input], destinationDirectory: fixture.mount, move: false, observing: selection)
        #expect(plan.conflicts.isEmpty)
        try OperationJournal.writeExclusive(JSONSerialization.data(withJSONObject: ["jobID": fixture.manifest.jobID]),
                                             name: "detach-ready.json", anchor: fixture.control)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while !fixture.controlExists("detach-release.json") && !fixture.controlExists("detach-abort.json") {
            guard clock.now < deadline else { throw FileOperationFailure.unavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
        if fixture.controlExists("detach-abort.json") {
            try fixture.receipt(phase: phase, values: ["qualification": "not-exercised", "reason": "Normal image ejection refused"])
            return
        }
        // The mount may be absent, or expose its underlying host directory. The immutable
        // plan's original device/parent guards must reject both without host fallback writes.
        let outcome = await service.perform(plan)
        #expect(outcome.result.disposition == .failed)
        #expect(before.matches(try verifiedTree(input, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: fixture.mount.appendingPathComponent("disconnect.bin").path))
        try fixture.receipt(phase: phase, values: ["disposition": outcome.result.disposition.rawValue,
            "causes": integrityStatus(outcome.result), "sourcePreserved": "true", "hostFallbackMutationAbsent": "true",
            "qualification": "Normal image ejection after prepared plan; not physical surprise disconnect"])

    default: throw FileOperationFailure.invalidRequest
    }
}
