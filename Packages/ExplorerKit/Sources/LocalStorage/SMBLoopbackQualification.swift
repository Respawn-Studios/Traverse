import Darwin
import ExplorerCore
import Foundation
import NetFS

/// Exact generated loopback packet only. No ordinary SMB endpoint is admitted.
@_spi(Qualification) public enum SMBLoopbackQualification {
    public static func run(packet: URL, temporaryMount: Bool = false, lifecycle: Bool = false, softMount: Bool = false) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try await runOwned(packet: packet, temporaryMount: temporaryMount, lifecycle: lifecycle, softMount: softMount) }.value
    }
    private static func runOwned(packet: URL, temporaryMount: Bool, lifecycle: Bool, softMount: Bool) async throws -> Data {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        guard packet.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-native-smb")
            && packet.resolvingSymlinksInPath() == packet && UUID(uuidString: packet.lastPathComponent) != nil
            && FileManager().fileExists(atPath: packet.appendingPathComponent("reservation.json").path) else { throw SMBConnectionProblem.invalidResult }
        let attempt = packet.appendingPathComponent("native-" + UUID().uuidString)
        try FileManager().createDirectory(at: attempt, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let comparison = temporaryMount ? try TemporaryMount(packet: packet, evidence: attempt) : nil
        defer {
            if let comparison {
                try? Self.write(["removed": comparison.removeIfEmptyAndUnchanged()],
                    to: attempt.appendingPathComponent("temporary-cleanup.json"))
            }
        }
        let mount = comparison?.mount ?? attempt.appendingPathComponent("mount")
        if comparison == nil {
            try FileManager().createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if lifecycle {
            guard let comparison,
                  matchesMarker(packet.appendingPathComponent("lifecycle-approved"),
                    expected: Data(("Two-request B10 lifecycle session\n" + packet.lastPathComponent + "\n").utf8))
            else { throw SMBConnectionProblem.denied }
            return try await runLifecycle(mount: mount, namespace: comparison, attempt: attempt, session: packet.lastPathComponent, softMount: softMount)
        }
        let endpoint = URL(string: "smb://127.0.0.1:15445/ExplorerQA")!
        // The private namespace must still be an ordinary local directory.
        var before = statfs()
        guard statfs(mount.path, &before) == 0 && before.f_flags & UInt32(MNT_LOCAL) != 0 else { throw SMBConnectionProblem.invalidResult }
        let started = ProcessInfo.processInfo.systemUptime
        let result = await SMBNativeAttempt().mount(endpoint: endpoint, at: mount, softMount: softMount)
        let exactRoot = result.paths.count == 1 && result.paths[0].utf8.elementsEqual(mount.path.utf8)
        try Self.write(["status": result.status, "returnedCount": result.paths.count,
            "returnedExactRoot": exactRoot, "seconds": ProcessInfo.processInfo.systemUptime-started,
            "pid": getpid(), "uid": getuid(), "completionReceived": result.completionReceived], to: attempt.appendingPathComponent("completion.json"))
        guard result.status == 0 && result.paths.count == 1 else { throw SMBConnectionProblem.unavailable }
        guard exactRoot else { throw SMBConnectionProblem.invalidResult }

        let activity = FileActivityGate(), observer = SMBMountObserver(activity: activity)
        let first = try await observer.observe(mount)
        guard first.source == Data("//GUEST:@127.0.0.1:15445/ExplorerQA".utf8) else { throw SMBConnectionProblem.invalidResult }
        var report: [String: Any] = ["readOnlySMB": true, "guestRequested": true, "authenticatedQualified": false,
            "serverReadOnlyIndependent": false, "metadataOnly": true, "ownedUnmount": false,
            "temporaryMountComparison": temporaryMount]
        var readFailure: (any Error)?
        do {
            let metadata = try await Self.readGeneratedMetadata(mount, activity: activity)
            report.merge(metadata) { _, new in new }
        } catch { readFailure = error; report["readFailure"] = true }
        // No automatic teardown from a callback alone: exact private root,
        // complete post-read identity, current owner and actual drain are needed.
        let final = try await observer.observe(mount)
        guard final == first && activity.activeCount == 0 else { throw SMBConnectionProblem.changed }
        let unmounted = await Self.normalUnmount(mount, expected: final)
        report["ownedUnmount"] = unmounted
        report["nativeSeconds"] = ProcessInfo.processInfo.systemUptime-started
        try Self.write(report, to: attempt.appendingPathComponent("result.json"))
        guard unmounted else { throw SMBConnectionProblem.busy }
        if let readFailure { throw readFailure }
        return try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
    }

    private static func readGeneratedMetadata(_ root: URL, activity: FileActivityGate,
                                             hold: SMBQualificationHold? = nil, evidence: URL? = nil) async throws -> [String: Any] {
        let cancellation = SMBQualificationCancellation()
        let result: [String: Any] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "MacExplorer.SMBGeneratedMetadata").async {
                let result = Result<[String: Any], Error> {
                    try cancellation.check()
                    let lease = try activity.begin(); defer { withExtendedLifetime(lease) {} }
                    let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
                    guard fd >= 0 else { throw SMBConnectionProblem.unavailable }
                    defer { Darwin.close(fd) }
                    try hold?.enterAndWait()
                    try cancellation.check()
                    var fs = statfs()
                    guard fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 else { throw SMBConnectionProblem.writableMount }
                    let copy = dup(fd)
                    guard copy >= 0 else { throw SMBConnectionProblem.unavailable }
                    guard let directory = fdopendir(copy) else { Darwin.close(copy); throw SMBConnectionProblem.unavailable }
                    defer { closedir(directory) }
                    var names: [String] = [], count = 0
                    errno = 0
                    while let item = readdir(directory) {
                        let name = withUnsafePointer(to: &item.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(validatingCString: $0) }
                        }
                        guard let name else { throw SMBConnectionProblem.invalidResult }
                        if name != "." && name != ".." { names.append(name); count += 1 }
                        guard count <= 64 else { throw SMBConnectionProblem.invalidResult }
                        try cancellation.check()
                        errno = 0
                    }
                    let enumerationErrno = errno
                    if let evidence {
                        try Self.write(["count": count, "generatedNames": names.sorted(),
                            "expectedNamesPresent": Set(names).isSuperset(of: ["Read me.txt", "Café 文件.txt", "Folder"]),
                            "enumerationErrno": enumerationErrno], to: evidence)
                    }
                    guard enumerationErrno == 0, Set(names).isSuperset(of: ["Read me.txt", "Café 文件.txt", "Folder"]) else { throw SMBConnectionProblem.invalidResult }
                    let regular = try SMBGeneratedFixtureNames.regularProbeNames(in: names)
                    var probes: [[String: Any]] = []
                    var metadataMatches = true
                    for (index, pair) in Array(zip(regular, [44, 128])).enumerated() {
                        let (name, expected) = pair
                        var value = stat()
                        let status = fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW), code = status == 0 ? 0 : errno
                        let matches = status == 0 && value.st_mode & S_IFMT == S_IFREG && value.st_size == expected
                        probes.append(["probe": index, "status": status, "errno": code, "kind": value.st_mode & S_IFMT,
                            "size": value.st_size, "matches": matches])
                        metadataMatches = metadataMatches && matches
                    }
                    var nested = stat(), empty = stat()
                    let nestedStatus = fstatat(fd, "Folder/Nested note.txt", &nested, AT_SYMLINK_NOFOLLOW)
                    let nestedCode = nestedStatus == 0 ? 0 : errno
                    let emptyStatus = fstatat(fd, "Folder/Empty folder", &empty, AT_SYMLINK_NOFOLLOW)
                    let emptyCode = emptyStatus == 0 ? 0 : errno
                    probes.append(["probe": 2, "status": nestedStatus, "errno": nestedCode, "kind": nested.st_mode & S_IFMT, "size": nested.st_size])
                    probes.append(["probe": 3, "status": emptyStatus, "errno": emptyCode, "kind": empty.st_mode & S_IFMT])
                    if let evidence {
                        try Self.write(["probes": probes], to: evidence.deletingLastPathComponent().appendingPathComponent("native-stat-results.json"))
                    }
                    guard metadataMatches, nestedStatus == 0, nested.st_mode & S_IFMT == S_IFREG, nested.st_size == 22,
                          emptyStatus == 0, empty.st_mode & S_IFMT == S_IFDIR else { throw SMBConnectionProblem.invalidResult }
                    try cancellation.check()
                    for name in ["Inside link", "Outside link", "Broken link"] {
                        let linked = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                        if linked >= 0 { Darwin.close(linked); throw SMBConnectionProblem.invalidResult }
                    }
                    let created = openat(fd, "Should not create.txt", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    if created >= 0 { Darwin.close(created); throw SMBConnectionProblem.writableMount }
                    guard [EROFS, EACCES, EPERM].contains(errno) else { throw SMBConnectionProblem.invalidResult }
                    guard renameat(fd, "Read me.txt", fd, "Should not rename.txt") != 0,
                          [EROFS, EACCES, EPERM].contains(errno), unlinkat(fd, "Read me.txt", 0) != 0,
                          [EROFS, EACCES, EPERM].contains(errno) else { throw SMBConnectionProblem.writableMount }
                    return ["observedRootEntries": count, "expectedRegularMetadata": true,
                        "nestedMetadata": true, "symlinkOpensRefused": true, "createRenameDeleteRefused": true]
                }
                continuation.resume(with: result)
            }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }

    private static func runLifecycle(mount: URL, namespace: TemporaryMount, attempt: URL, session: String, softMount: Bool) async throws -> Data {
        let address = try SMBShareAddress("smb://127.0.0.1/ExplorerQA")
        let endpoint = URL(string: "smb://127.0.0.1:15445/ExplorerQA")!
        let activity = FileActivityGate(), observer = SMBMountObserver(activity: activity)
        var model = SMBConnectionLifecycle(), report: [String: Any] = ["metadataOnly": true, "mountRequests": 0, "explicitSoftMount": softMount]
        func progress(_ stage: String) throws {
            try Self.write(["stage": stage, "session": session], to: attempt.appendingPathComponent(stage + ".json"))
        }
        func verify(_ value: SMBNativeResult, number: Int) async throws -> SMBMountObservation {
            let exact = value.paths.count == 1 && value.paths[0].utf8.elementsEqual(mount.path.utf8)
            try Self.write(["status": value.status, "completionReceived": value.completionReceived,
                "returnedCount": value.paths.count, "returnedExactRoot": exact],
                to: attempt.appendingPathComponent("completion-\(number).json"))
            guard value.status == 0, value.completionReceived, exact else { throw SMBConnectionProblem.invalidResult }
            let facts = try await observer.observe(mount)
            guard facts.source == Data("//GUEST:@127.0.0.1:15445/ExplorerQA".utf8) else { throw SMBConnectionProblem.invalidResult }
            return facts
        }
        let id = try model.begin(address)
        try progress("first-request-submitting")
        let firstResult = await SMBNativeAttempt().mount(endpoint: endpoint, at: mount, softMount: softMount)
        let first = try await verify(firstResult, number: 1)
        report["firstMountFlags"] = first.flags
        guard model.completed(id, result: .mounted(count: 1)) == .verifySingleMount(id),
              model.verified(id, problem: nil), let initialRead = model.beginRead() else { throw SMBConnectionProblem.invalidResult }
        var activeRead: UUID? = initialRead
        var firstFailure: (any Error)?
        do {
            let metadata = try await readGeneratedMetadata(mount, activity: activity, evidence: attempt.appendingPathComponent("native-listing.json"))
            report.merge(metadata) { _, new in new }
            try progress("generated-metadata-passed")
            guard model.readerFinished(initialRead) else { throw SMBConnectionProblem.invalidResult }
            activeRead = nil
            let hold = SMBQualificationHold()
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { hold.release() }
                group.addTask { _ = try await readGeneratedMetadata(mount, activity: activity, hold: hold) }
                try await wait { hold.isHeld }
                try progress("reader-held")
                guard let heldRead = model.beginRead() else { throw SMBConnectionProblem.invalidResult }
                activeRead = heldRead
                guard activity.activeCount == 1,
                      let token = activity.closeAdmission() else { throw SMBConnectionProblem.invalidResult }
                group.cancelAll(); model.closeView()
                guard model.hasOutstandingWork, model.phase == .finishingClosedView,
                      !model.canConnect, !model.canRead, !activity.ownsDrainedAdmission(token)
                else { throw SMBConnectionProblem.invalidResult }
                do { _ = try activity.begin(); throw SMBConnectionProblem.invalidResult }
                catch FileActivityError.admissionClosed {}
                try progress("reader-cancel-retained")
                hold.release()
                do { _ = try await group.next(); throw SMBConnectionProblem.invalidResult }
                catch is CancellationError {}
                guard model.readerFinished(heldRead), model.phase == .closed, !model.hasOutstandingWork,
                      await activity.waitUntilDrained(token), activity.reopen(token)
                else { throw SMBConnectionProblem.invalidResult }
                activeRead = nil
                try progress("reader-cancel-drained")
            }
            report["readerCloseCancelDrained"] = true
        } catch {
            firstFailure = error; report["firstPhaseFailed"] = true
            if let activeRead { _ = model.readerFinished(activeRead, problem: .invalidResult) }
        }
        let last = activity.isClosed ? first : try await observer.observe(mount)
        guard first == last, activity.activeCount == 0 else { throw SMBConnectionProblem.changed }
        let firstUnmount = activity.isClosed
            ? await normalUnmountCached(mount, expected: last, namespace: namespace)
            : await normalUnmount(mount, expected: last)
        try Self.write(["normalUnmount": firstUnmount, "failed": firstFailure != nil], to: attempt.appendingPathComponent("first-phase.json"))
        guard firstUnmount else { throw SMBConnectionProblem.busy }
        if let firstFailure { throw firstFailure }
        guard namespace.isOriginalLocalMountpoint() else { throw SMBConnectionProblem.changed }
        try progress("second-request-submitting")
        let delivery = SMBQualificationHold()
        var closed = SMBConnectionLifecycle()
        let closedID = try closed.begin(address)
        let native = SMBNativeAttempt()
        let secondResult = try await withThrowingTaskGroup(of: SMBNativeResult.self) { group in
            defer { delivery.release() }
            group.addTask { await native.mount(endpoint: endpoint, at: mount, softMount: softMount, delivery: delivery) }
            try await wait { delivery.isHeld || native.hasCompleted }
            guard delivery.isHeld else { _ = try await group.next(); throw SMBConnectionProblem.unavailable }
            guard closed.deadlinePassed(closedID) else { throw SMBConnectionProblem.invalidResult }
            closed.closeView()
            guard closed.nativeRequestPending, closed.hasOutstandingWork, !closed.canConnect,
                  closed.phase == .finishingClosedView else { throw SMBConnectionProblem.invalidResult }
            delivery.release()
            guard let result = try await group.next() else { throw SMBConnectionProblem.invalidResult }
            return result
        }
        let second = try await verify(secondResult, number: 2)
        guard closed.completed(closedID, result: .mounted(count: 1)) == .none,
              closed.phase == .closed, !closed.hasOutstandingWork, !closed.canRead else { throw SMBConnectionProblem.invalidResult }
        report["pendingCallbackCloseDrained"] = true
        report["mountRequests"] = 2
        let offlineHold = SMBQualificationHold()
        var offlineFailure: (any Error)?
        var offlineErrno: Int32 = -1
        do {
            offlineErrno = try await withThrowingTaskGroup(of: Int32.self) { group in
                defer { offlineHold.release() }
                group.addTask { try await offlineRead(mount, activity: activity, hold: offlineHold) }
                try await wait { offlineHold.isHeld }
                try Self.write(["session": session, "readerHeld": true, "activeReaders": activity.activeCount,
                    "nativeCallbackCompleted": true], to: attempt.appendingPathComponent("offline-ready.json"))
                try await wait(seconds: 60, milliseconds: 100) {
                    matchesMarker(attempt.appendingPathComponent("offline-stop-confirmed"), expected: Data((session + "\n").utf8))
                }
                offlineHold.release()
                guard let result = try await group.next() else { throw SMBConnectionProblem.invalidResult }
                return result
            }
        } catch { offlineFailure = error }
        let expectedErrors: [Int32] = [EIO, ENOTCONN, ETIMEDOUT, ENXIO, ENODEV, ECONNRESET, EHOSTDOWN, ESTALE, EPIPE, ECONNABORTED]
        report["offlineErrno"] = offlineErrno
        report["offlineFailureObserved"] = expectedErrors.contains(offlineErrno)
        guard activity.activeCount == 0, observer.outstandingCount == 0,
              let token = activity.closeAdmission(), activity.ownsDrainedAdmission(token) else { throw SMBConnectionProblem.busy }
        let secondUnmount = await normalUnmountCached(mount, expected: second, namespace: namespace)
        report["ownedUnmount"] = secondUnmount
        report["passed"] = firstUnmount && secondUnmount && offlineFailure == nil && expectedErrors.contains(offlineErrno)
        try Self.write(report, to: attempt.appendingPathComponent("result.json"))
        guard secondUnmount else { throw SMBConnectionProblem.busy }
        if let offlineFailure { throw offlineFailure }
        guard expectedErrors.contains(offlineErrno) else { throw SMBConnectionProblem.invalidResult }
        return try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
    }

    private static func offlineRead(_ root: URL, activity: FileActivityGate, hold: SMBQualificationHold) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "MacExplorer.SMBGeneratedOffline").async {
                let result = Result<Int32, Error> {
                    let lease = try activity.begin(); defer { withExtendedLifetime(lease) {} }
                    let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
                    guard fd >= 0 else { throw SMBConnectionProblem.unavailable }
                    defer { Darwin.close(fd) }
                    try hold.enterAndWait(seconds: 70)
                    let child = openat(fd, "Folder", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    if child >= 0 { Darwin.close(child); return 0 }
                    return errno
                }
                continuation.resume(with: result)
            }
        }
    }
    private static func normalUnmountCached(_ root: URL, expected: SMBMountObservation, namespace: TemporaryMount) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "MacExplorer.SMBOwnedOfflineUnmount").async {
                guard namespace.parentAndMarkerUnchanged() else { continuation.resume(returning: false); return }
                let capacity = getfsstat(nil, 0, MNT_NOWAIT)
                guard capacity > 0, capacity <= 4096 else { continuation.resume(returning: false); return }
                var mounts: [statfs] = Array(repeating: statfs(), count: Int(capacity))
                let count = mounts.withUnsafeMutableBufferPointer {
                    getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
                }
                guard count > 0, count <= capacity else { continuation.resume(returning: false); return }
                func bytes<T>(_ field: T) -> Data? {
                    withUnsafeBytes(of: field) { raw in raw.firstIndex(of: 0).map { Data(raw[..<$0]) } }
                }
                let matches = (0..<Int(count)).map { mounts[$0] }.filter { bytes($0.f_mntonname) == expected.root }
                guard matches.count == 1, let fs = matches.first, fs.f_owner == getuid(),
                      fs.f_fsid.val.0 == expected.fileSystemID, fs.f_fsid.val.1 == expected.fileSystemIDExtra,
                      fs.f_flags == expected.flags, bytes(fs.f_fstypename) == expected.fileSystem,
                      bytes(fs.f_mntfromname) == expected.source
                else { continuation.resume(returning: false); return }
                continuation.resume(returning: Darwin.unmount(root.path, 0) == 0)
            }
        }
    }
    private static func wait(seconds: Double = 8, milliseconds: Int64 = 10, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SMBConnectionProblem.unavailable }
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
    }
    private static func matchesMarker(_ url: URL, expected: Data) -> Bool {
        guard expected.count <= 1024 else { return false }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == getuid(),
              facts.st_nlink == 1, facts.st_size == expected.count else { return false }
        var bytes = [UInt8](repeating: 0, count: expected.count)
        return Darwin.read(fd, &bytes, bytes.count) == bytes.count && Data(bytes) == expected
    }
    private static func normalUnmount(_ root: URL, expected: SMBMountObservation) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "MacExplorer.SMBGeneratedUnmount").async {
                let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { continuation.resume(returning: false); return }
                func equal<T>(_ field: T, _ bytes: Data) -> Bool {
                    withUnsafeBytes(of: field) { raw in
                        guard let end = raw.firstIndex(of: 0) else { return false }
                        return Data(raw[..<end]) == bytes
                    }
                }
                var facts = statfs(), object = stat()
                let owned = fstatfs(fd, &facts) == 0 && fstat(fd, &object) == 0
                    && facts.f_owner == getuid() && SMBMountObservation.Object(object) == expected.object
                    && facts.f_fsid.val.0 == expected.fileSystemID && facts.f_fsid.val.1 == expected.fileSystemIDExtra
                    && facts.f_flags == expected.flags && equal(facts.f_fstypename, expected.fileSystem)
                    && equal(facts.f_mntonname, expected.root) && equal(facts.f_mntfromname, expected.source)
                Darwin.close(fd)
                continuation.resume(returning: owned && Darwin.unmount(root.path, 0) == 0)
            }
        }
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .withoutOverwriting)
    }

    /// One explicit owner-approved comparison, not a general temporary-path API.
    private struct TemporaryMount {
        let root: URL
        let mount: URL
        let marker: URL
        let markerBytes: Data
        let rootIdentity: SMBMountObservation.Object
        let mountIdentity: SMBMountObservation.Object
        init(packet: URL, evidence: URL) throws {
            let approval = packet.appendingPathComponent("internal-mount-approved")
            let fd = Darwin.open(approval.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw SMBConnectionProblem.denied }
            defer { Darwin.close(fd) }
            var facts = stat()
            let expected = Data(("One temporary B10 mountpoint\n" + packet.lastPathComponent + "\n").utf8)
            guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == getuid(),
                  facts.st_nlink == 1, facts.st_size == expected.count else { throw SMBConnectionProblem.denied }
            var bytes = [UInt8](repeating: 0, count: expected.count)
            guard Darwin.read(fd, &bytes, bytes.count) == bytes.count, Data(bytes) == expected else { throw SMBConnectionProblem.denied }
            let used = Darwin.open(packet.appendingPathComponent("internal-mount-used").path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
            guard used >= 0 else { throw SMBConnectionProblem.denied }
            defer { Darwin.close(used) }
            guard expected.withUnsafeBytes({ Darwin.write(used, $0.baseAddress, $0.count) }) == expected.count,
                  fsync(used) == 0 else { throw SMBConnectionProblem.unavailable }
            root = URL(fileURLWithPath: "/private/tmp/macexplorer-b10-" + UUID().uuidString)
            mount = root.appendingPathComponent("mount"); marker = root.appendingPathComponent("owned-marker")
            markerBytes = Data(("Mac Explorer generated B10 mount\n" + packet.lastPathComponent).utf8)
            try Self.recordPath(root, to: evidence)
            try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try markerBytes.write(to: marker, options: .withoutOverwriting)
            try FileManager().createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var parent = stat(), child = stat(), mark = stat()
            guard lstat(root.path, &parent) == 0, lstat(mount.path, &child) == 0, lstat(marker.path, &mark) == 0,
                  parent.st_uid == getuid(), child.st_uid == getuid(),
                  [parent, child, mark].reduce(Int64(0), { $0 + max($1.st_size, $1.st_blocks * 512) }) <= 65536
                else { throw SMBConnectionProblem.invalidResult }
            rootIdentity = .init(parent); mountIdentity = .init(child)
        }
        private static func recordPath(_ path: URL, to evidence: URL) throws {
            try JSONSerialization.data(withJSONObject: ["ownedRoot": path.path, "bytes": 65536, "entries": 8], options: .sortedKeys)
                .write(to: evidence.appendingPathComponent("temporary-root.json"), options: .withoutOverwriting)
        }
        func parentAndMarkerUnchanged() -> Bool {
            var parent = stat(), facts = stat()
            guard lstat(root.path, &parent) == 0, SMBMountObservation.Object(parent) == rootIdentity else { return false }
            let fd = Darwin.open(marker.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == getuid(),
                  facts.st_nlink == 1, facts.st_size == markerBytes.count else { return false }
            var bytes = [UInt8](repeating: 0, count: markerBytes.count)
            return Darwin.read(fd, &bytes, bytes.count) == bytes.count && Data(bytes) == markerBytes
        }
        func isOriginalLocalMountpoint() -> Bool {
            var child = stat()
            return parentAndMarkerUnchanged() && lstat(mount.path, &child) == 0
                && SMBMountObservation.Object(child) == mountIdentity
        }
        func removeIfEmptyAndUnchanged() -> Bool {
            var parent = stat(), child = stat(), mark = stat()
            guard lstat(root.path, &parent) == 0, .init(parent) == rootIdentity,
                  lstat(mount.path, &child) == 0, .init(child) == mountIdentity,
                  lstat(marker.path, &mark) == 0, mark.st_mode & S_IFMT == S_IFREG, mark.st_uid == getuid(),
                  mark.st_size == markerBytes.count, (try? Data(contentsOf: marker)) == markerBytes,
                  let names = try? FileManager().contentsOfDirectory(atPath: root.path),
                  Set(names) == ["mount", "owned-marker"] else { return false }
            // rmdir refuses any late occupant or mounted root; never recurse.
            guard Darwin.rmdir(mount.path) == 0, Darwin.unlink(marker.path) == 0 else { return false }
            return Darwin.rmdir(root.path) == 0
        }
    }
}

private struct SMBNativeResult: Sendable { let status: Int32; let paths: [String]; let completionReceived: Bool }
private final class SMBQualificationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}
private final class SMBQualificationHold: @unchecked Sendable {
    private let lock = NSLock(), releaseSignal = DispatchSemaphore(value: 0)
    private var held = false
    var isHeld: Bool { lock.withLock { held } }
    func enterAndWait(seconds: Double = 15) throws {
        lock.withLock { held = true }
        guard releaseSignal.wait(timeout: .now() + seconds) == .success else { throw SMBConnectionProblem.unavailable }
    }
    func release() { releaseSignal.signal() }
}
private final class SMBNativeAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.SMBGeneratedNetFS")
    private let completionLock = NSLock()
    private var didComplete = false
    var hasCompleted: Bool { completionLock.withLock { didComplete } }
    private var request: UnsafeMutableRawPointer?
    private var completed = false
    func mount(endpoint: URL, at root: URL, softMount: Bool = false, delivery: SMBQualificationHold? = nil) async -> SMBNativeResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let open = NSMutableDictionary()
                open[kNetFSUseGuestKey] = true; open[kNetFSAllowLoopbackKey] = true
                open[kNetFSForceNewSessionKey] = true; open[kNAUIOptionKey] = kNAUIOptionNoUI
                let options = NSMutableDictionary()
                options[kNetFSMountFlagsKey] = MNT_RDONLY | MNT_DONTBROWSE
                options[kNetFSMountAtMountDirKey] = true
                if softMount { options[kNetFSSoftMountKey] = true }
                let status = NetFSMountURLAsync(endpoint as CFURL, root as CFURL, nil, nil,
                    open, options, &request, queue) { [self] status, identifier, values in
                        guard !completed, request == identifier else { return }
                        completed = true
                        completionLock.withLock { didComplete = true }
                        let array = values as NSArray?
                        let paths = array.flatMap { $0.count <= 8 ? $0 as? [String] : nil } ?? []
                        continuation.resume(returning: .init(status: status, paths: paths, completionReceived: true))
                    }
                if status != 0, !completed {
                    completed = true; completionLock.withLock { didComplete = true }
                    continuation.resume(returning: .init(status: status, paths: [], completionReceived: false))
                } else if status == 0, let delivery {
                    // Real submission has returned; serial callback delivery is
                    // deliberately held for the generated consumer-close check.
                    try? delivery.enterAndWait()
                }
            }
        }
    }
}
