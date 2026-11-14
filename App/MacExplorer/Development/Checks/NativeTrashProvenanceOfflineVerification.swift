#if DEBUG
import AppKit
import Darwin
@_spi(Qualification) import FileOperations

/// Isolated generated control. The FileOperations provider moves only within
/// the exact private case; the default system Trash adapter is never created.
@MainActor enum NativeTrashProvenanceOfflineVerification {
    private static func privateMarker(_ root: URL) -> Int32? {
        var directory = stat(), markerFacts = stat()
        let marker = root.appendingPathComponent("reservation.json")
        guard lstat(root.path, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid(), directory.st_mode & 0o077 == 0,
              lstat(marker.path, &markerFacts) == 0,
              markerFacts.st_mode & S_IFMT == S_IFREG,
              markerFacts.st_uid == geteuid(), markerFacts.st_mode & 0o077 == 0,
              markerFacts.st_nlink == 1, markerFacts.st_size <= 4096 else { return nil }
        let caseFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard caseFD >= 0 else { return nil }
        let admitted: Bool = {
            var openedDirectory = stat()
            guard fstat(caseFD, &openedDirectory) == 0,
                  openedDirectory.st_dev == directory.st_dev,
                  openedDirectory.st_ino == directory.st_ino else { return false }
            let fd = openat(caseFD, marker.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var openedMarker = stat()
            guard fstat(fd, &openedMarker) == 0,
                  openedMarker.st_dev == markerFacts.st_dev,
                  openedMarker.st_ino == markerFacts.st_ino,
                  openedMarker.st_mode & S_IFMT == S_IFREG,
                  openedMarker.st_uid == geteuid(), openedMarker.st_mode & 0o077 == 0,
                  openedMarker.st_nlink == 1, openedMarker.st_size <= 4096,
                  let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return fields["packet"] as? String == "traverse-development-v1"
                && fields["action"] as? String == "native-trash-provenance-offline-v1"
                && fields["maximumFakeCalls"] as? Int == 2
                && fields["maximumSystemTrashCalls"] as? Int == 0
        }()
        guard admitted else { close(caseFD); return nil }
        return caseFD
    }

    static func run() async {
        var root: URL?
        var caseFD: Int32?
        defer { if let caseFD { close(caseFD) } }
        var report: [String: Any] = ["passed": false, "scopeRefused": true,
                                      "failureClass": "scopeRefused",
                                      "fakeProviderCalls": 0, "systemTrashCalls": 0]
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                throw FileOperationFailure.invalidRequest
            }
            let admitted = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard raw.hasPrefix("/"), admitted == admitted.standardizedFileURL,
                  admitted.resolvingSymlinksInPath() == admitted,
                  admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent,
                  ProcessInfo.processInfo.arguments.contains("--verify-ui"),
                  ProcessInfo.processInfo.arguments.contains("--check-trash-provenance-offline"),
                  Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  Bundle.main.object(forInfoDictionaryKey: "TraverseVerificationOnly") as? Bool == true,
                  let admittedFD = privateMarker(admitted) else {
                throw FileOperationFailure.invalidRequest
            }
            root = admitted
            caseFD = admittedFD
            let outcome = try await GeneratedNativeTrashProvenanceOfflineControl.run(root: admitted)
            report = ["passed": outcome.passed, "scopeRefused": false,
                "failureClass": outcome.failureClass,
                "plainSucceededAndUndone": outcome.plainSucceededAndUndone,
                "provenanceMutation": outcome.provenanceMutation.rawValue,
                "osAccessChangedInGeneratedRoute": outcome.osAccessChangedInGeneratedRoute,
                "exactFamilyObserved": outcome.exactFamilyObserved,
                "changedItemNeedsReview": outcome.changedItemNeedsReview,
                "changedItemReturnedSameObject": outcome.changedItemReturnedSameObject,
                "fakeProviderCalls": outcome.fakeProviderCalls,
                "systemTrashCalls": outcome.systemTrashCalls]
        } catch {
            report["scopeRefused"] = root == nil
            report["failureClass"] = (error as? GeneratedNativeTrashProvenanceOfflineFailure)?.rawValue
                ?? (root == nil ? "scopeRefused" : "controlException")
        }
        if let root, let caseFD,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            var current = stat(), pinned = stat()
            guard lstat(root.path, &current) == 0, fstat(caseFD, &pinned) == 0,
                  current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino else {
                NSApplication.shared.terminate(nil)
                return
            }
            let fd = openat(caseFD, "result.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if count == data.count { _ = fsync(fd) }
                close(fd)
            }
        }
        NSApplication.shared.terminate(nil)
    }
}
#endif
