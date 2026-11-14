#if DEBUG
import AppKit
import CryptoKit
import Darwin
import FileOperations

/// Human foreground checks and explicit owned-fixture API qualification remain
/// distinct. Offscreen mode permits only the nonhuman owned-fixture Trash path;
/// ordinary verification never invokes these opt-in workflows.
@MainActor
enum InteractiveQualification {
    struct Failure: Error { let message: String }

    private struct Report: Codable, Sendable {
        var mode = "foreground-qualification"
        var permissions: PermissionObservation?
        var folderAccess: FolderObservation?
        var trash: TrashObservation?
    }

    private struct PermissionObservation: Codable, Sendable {
        var location = "Downloads"
        var status: String
        var shallowEntryCount = 0
        var metadataFailureCount = 0
        var truncated = false
        var posixError: Int32?
        var humanPromptObservation: String?
    }

    private struct FolderObservation: Codable, Sendable {
        var status: String
        var scopeStarted: Bool?
        var restoredState: String?
        var forgetVerified: Bool?
    }

    private struct TrashObservation: Codable, Sendable {
        var status: String
        var authorizationMode: String?
        var payloadSHA256: String?
        var sourceDevice: dev_t?
        var sourceInode: ino_t?
        var recoveryOriginalReceipt: String?
        var identityEvidence: String?
        var originalFixture: String?
        var trashLocation: String?
        var recoverableLocation: String?
        var restoredLocation: String?
        var ownPayloadVerified = false
        var restoredPayloadVerified = false
    }

    private struct TrashFixture: Sendable {
        let id: UUID
        let source: URL
        let restoreDirectory: URL
        let device: dev_t
        let inode: ino_t
    }

    private struct RecoveryContext: Sendable {
        let fixture: TrashFixture
        let location: URL
        let identityEvidence: String
    }

    /// Call after activation for human checks, or before offscreen verification
    /// for the explicit owned-fixture Trash API check. Neither mode screenshots
    /// permission/picker dialogs or navigates the browser to Downloads.
    static func run(window: NSWindow, fixtureRoot: URL, evidenceRoot: URL) async throws -> [String] {
        let args = ProcessInfo.processInfo.arguments
        let permissions = args.contains("--qualify-permissions")
        let folders = args.contains("--qualify-folder-access")
        let trash = args.contains("--qualify-trash")
        let trashFixture = args.contains("--qualify-trash-fixture")
        let recovery = args.contains("--restore-trash-fixture")
        let offscreen = args.contains("--offscreen")
        guard permissions || folders || trash || trashFixture || recovery else { return [] }
        guard !recovery || (offscreen && !permissions && !folders && !trash && !trashFixture && !args.contains("--qualify-glass") && !args.contains("--check-presentation")) else {
            throw Failure(message: "Receipt recovery requires offscreen mode alone, separate from qualification flags.")
        }
        guard !(trash && trashFixture) else { throw Failure(message: "Human and explicit owned-fixture Trash modes are mutually exclusive.") }
        guard !offscreen || ((trashFixture || recovery) && !permissions && !folders && !trash && !args.contains("--qualify-glass")) else {
            throw Failure(message: "Offscreen qualification permits only the explicit owned-fixture Trash API check.")
        }
        if permissions {
            guard let index = args.firstIndex(of: "--qualify-permissions"), args.indices.contains(index + 1),
                  args[index + 1] == "Downloads" else {
                throw Failure(message: "Only explicit Downloads metadata qualification is supported.")
            }
        }
        let buildRoot = fixtureRoot.deletingLastPathComponent().deletingLastPathComponent()
        try await Task.detached {
            try validateOwnedRoots(fixture: fixtureRoot, evidence: evidenceRoot, build: buildRoot)
        }.value
        var report = Report(mode: offscreen ? "offscreen-owned-fixture-api" : "foreground-qualification")
        var checks: [String] = []
        let reportURL = evidenceRoot.appendingPathComponent("interactive-qualification.json")
        try await Task.detached { try reserveNewReport(at: reportURL) }.value

        if recovery {
            guard let index = args.firstIndex(of: "--restore-trash-fixture"), args.indices.contains(index + 1) else {
                throw Failure(message: "Receipt recovery requires the exact prior qualification receipt.")
            }
            let receipt = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            let context = try await Task.detached { try recoveryContext(receipt: receipt, build: buildRoot) }.value
            guard receipt != reportURL else { throw Failure(message: "Recovery must not replace its historical receipt.") }
            report.mode = "offscreen-owned-fixture-recovery"
            report.trash = TrashObservation(status: "recovery-owned-payload-validated", authorizationMode: "explicit-owned-fixture-recovery",
                payloadSHA256: payloadHash(context.fixture.id), sourceDevice: context.fixture.device, sourceInode: context.fixture.inode,
                recoveryOriginalReceipt: receipt.path, identityEvidence: context.identityEvidence,
                originalFixture: context.fixture.source.path, trashLocation: context.location.path,
                recoverableLocation: context.location.path, ownPayloadVerified: true)
            try await write(report, to: reportURL)
            let engine = LocalFileOperations()
            let observation: FileOperationSelection
            let restoreDirectoryObservation: FileOperationSelection
            do {
                restoreDirectoryObservation = try await observeRestoreDirectory(context.fixture.restoreDirectory, using: engine)
                observation = try await engine.observeSelection([context.location])
            }
            catch {
                report.trash?.status = "recovery-preflight-failed-left-recoverable"
                try await write(report, to: reportURL)
                throw Failure(message: "Recovery preflight failed; the exact known fixture was left recoverable.")
            }
            // Revalidate after observation so any replacement during payload
            // checking cannot acquire the earlier object's authorization.
            try await Task.detached { try validatePayload(at: context.location, fixture: context.fixture) }.value
            let moved = await engine.perform(.moveObserved(selection: observation, destinationDirectory: context.fixture.restoreDirectory),
                                             observing: restoreDirectoryObservation)
            guard moved.disposition == .succeeded, moved.items.count == 1, let restored = moved.items.first?.destination else {
                report.trash?.status = "recovery-move-failed-left-for-inspection"
                if let known = moved.items.first?.recoveryURLs.first { report.trash?.recoverableLocation = known.path }
                try await write(report, to: reportURL)
                throw Failure(message: "No-replace recovery did not complete. Review the new recovery receipt; no cleanup was attempted.")
            }
            report.trash?.restoredLocation = restored.path
            report.trash?.recoverableLocation = restored.path
            report.trash?.status = "recovery-restored-awaiting-validation"
            try await write(report, to: reportURL)
            do { try await Task.detached { try validatePayload(at: restored, fixture: context.fixture) }.value }
            catch {
                report.trash?.status = "recovery-restored-validation-failed-left-for-inspection"
                try await write(report, to: reportURL)
                throw Failure(message: "Restored recovery payload validation failed; it was left at the reported location.")
            }
            report.trash?.restoredPayloadVerified = true
            report.trash?.status = "prior-owned-trash-fixture-restored-no-replace"
            try await write(report, to: reportURL)
            return ["Offscreen API recovery of exact prior owned Trash fixture: restored and payload verified; historical receipt unchanged"]
        }

        if permissions {
            let proceed = await prompt(window, title: "Qualify Downloads metadata access?",
                message: "This explicit check counts direct Downloads entries and reads shallow filesystem metadata only. It does not open file bodies, recurse, display filenames, navigate the browser to Downloads, or capture the permission dialog. If macOS asks, you choose Allow or Don’t Allow. No permission is reset.",
                buttons: ["Continue", "Skip"])
            if proceed == 0 {
                // Derive the real user's location inside this native app. Tooling
                // must never pass its build-only CFFIXED_USER_HOME shim here.
                let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
                var observation = await Task.detached { scanMetadata(downloads) }.value
                let response = await prompt(window, title: "What did you observe?",
                    message: "The metadata request finished. Select only the prompt outcome you personally observed. A successful read does not prove a new permission prompt appeared or that consent will survive rebuilding.",
                    buttons: ["I chose Allow", "I chose Don’t Allow", "No prompt appeared", "Not sure"])
                observation.humanPromptObservation = ["human-reported-allow", "human-reported-deny", "human-reported-no-prompt", "human-uncertain"][response]
                report.permissions = observation
                checks.append("Human-assisted Downloads shallow metadata request observed: \(observation.status); no names or bodies recorded")
            } else {
                report.permissions = PermissionObservation(status: "human-skipped")
                checks.append("Downloads permission qualification skipped by human")
            }
            try await write(report, to: reportURL)
        }

        if folders {
            report.folderAccess = try await qualifyFolder(window, fixture: fixtureRoot, build: buildRoot)
            try await write(report, to: reportURL)
            checks.append("Human folder-panel/bookmark qualification: \(report.folderAccess!.status)")
        }

        if trash || trashFixture {
            // The explicit CLI fixture flag is already authorized for the new
            // generated payload only. Never inspect browser selection or Downloads.
            let authorizationMode = trashFixture ? "explicit-owned-fixture" : "human-confirmed"
            let proceed: Int
            if trashFixture { proceed = 0 }
            else {
                proceed = await prompt(window, title: "Qualify real Trash and restore?",
                    message: "This creates one new marked UUID fixture under this checkout’s .build/test-fixtures, sends that generated folder to the real system Trash, validates only its own generated payload, then restores it with a no-replace move into its owned fixture. Nothing is permanently deleted. A failed restoration leaves the recoverable item for inspection.",
                    buttons: ["Trash and Restore Fixture", "Skip"])
            }
            if proceed != 0 {
                report.trash = TrashObservation(status: "human-skipped", authorizationMode: "human-skipped")
            } else {
                let fixture = try await Task.detached { try createTrashFixture(build: buildRoot) }.value
                report.trash = TrashObservation(status: "prepared", authorizationMode: authorizationMode,
                                               payloadSHA256: payloadHash(fixture.id), sourceDevice: fixture.device,
                                               sourceInode: fixture.inode, originalFixture: fixture.source.path)
                try await write(report, to: reportURL)
                let engine = LocalFileOperations()
                let observation = try await engine.observeSelection([fixture.source])
                let result = await engine.perform(.trash(sources: [fixture.source]), observing: observation)
                let item = result.items.first
                let destination = item?.destination ?? item?.recoveryURLs.first
                report.trash?.trashLocation = destination?.path
                report.trash?.recoverableLocation = destination?.path
                guard result.disposition == .succeeded, result.items.count == 1, let destination else {
                    report.trash?.status = "trash-not-qualified-review-recovery"
                    try await write(report, to: reportURL)
                    throw Failure(message: "Real Trash did not return a confirmed recoverable fixture location. Review the qualification report; nothing was permanently deleted.")
                }
                report.trash?.status = "trashed-awaiting-payload-validation"
                try await write(report, to: reportURL)
                do {
                    try await Task.detached { try validatePayload(at: destination, fixture: fixture) }.value
                    report.trash?.ownPayloadVerified = true
                } catch {
                    report.trash?.status = "trash-payload-not-qualified-left-recoverable"
                    try await write(report, to: reportURL)
                    throw Failure(message: "The generated Trash payload could not be validated. It was left recoverable; inspect the qualification report.")
                }
                report.trash?.status = "trashed-payload-verified-awaiting-restore"
                try await write(report, to: reportURL)
                let restoreObservation: FileOperationSelection
                let restoreDirectoryObservation: FileOperationSelection
                do {
                    restoreDirectoryObservation = try await observeRestoreDirectory(fixture.restoreDirectory, using: engine)
                    restoreObservation = try await engine.observeSelection([destination])
                }
                catch {
                    report.trash?.status = "restore-preflight-failed-left-recoverable"
                    try await write(report, to: reportURL)
                    throw Failure(message: "Restore preflight could not observe the owned Trash fixture. It was left at the reported recovery location.")
                }
                let restored = await engine.perform(.moveObserved(selection: restoreObservation, destinationDirectory: fixture.restoreDirectory),
                                                     observing: restoreDirectoryObservation)
                let restoredURL = restored.items.first?.destination
                guard restored.disposition == .succeeded, restored.items.count == 1, let restoredURL else {
                    report.trash?.status = "restore-not-qualified-left-for-inspection"
                    // If the engine reports a changed recovery location, preserve
                    // that known location rather than pretending the old one wins.
                    if let recovery = restored.items.first?.recoveryURLs.first { report.trash?.recoverableLocation = recovery.path }
                    try await write(report, to: reportURL)
                    throw Failure(message: "The owned Trash fixture could not be safely restored. Review the reported recovery location; no permanent deletion was attempted.")
                }
                report.trash?.restoredLocation = restoredURL.path
                report.trash?.recoverableLocation = restoredURL.path
                report.trash?.status = "restored-awaiting-payload-validation"
                try await write(report, to: reportURL)
                do {
                    try await Task.detached { try validatePayload(at: restoredURL, fixture: fixture) }.value
                    report.trash?.restoredPayloadVerified = true
                    report.trash?.status = "trash-and-no-replace-restore-qualified"
                } catch {
                    report.trash?.status = "restored-payload-not-qualified-left-for-inspection"
                    try await write(report, to: reportURL)
                    throw Failure(message: "The restored owned payload could not be validated. The reported restored fixture was left for inspection.")
                }
            }
            try await write(report, to: reportURL)
            checks.append("\(offscreen ? "Offscreen owned-fixture API" : "Foreground owned-fixture") real Trash/restore qualification: \(report.trash!.status)")
        }
        return checks
    }

    private static func qualifyFolder(_ window: NSWindow, fixture: URL, build: URL) async throws -> FolderObservation {
        let proceed = await prompt(window, title: "Qualify the native folder chooser?",
            message: "In the real folder panel, choose the generated fixture offered initially. Choosing any other folder cancels this qualification without reading it or saving a bookmark. Remember, restore, and forget apply only to isolated qualification state.",
            buttons: ["Choose Fixture…", "Skip"])
        guard proceed == 0 else { return FolderObservation(status: "human-skipped") }
        let state = build.appendingPathComponent("test-fixtures/interactive-folder-\(UUID().uuidString)", isDirectory: true)
        let controller = FolderAccessController(stateDirectory: state)
        guard let chosen = await controller.chooseFolder(in: window, initialDirectory: fixture) else {
            return FolderObservation(status: "human-cancelled-panel")
        }
        defer { chosen.lease.close() }
        guard chosen.selection.url.standardizedFileURL == fixture.standardizedFileURL else {
            return FolderObservation(status: "different-folder-selected-no-bookmark-saved", scopeStarted: chosen.lease.securityScopeStarted)
        }
        let remember = await prompt(window, title: "Remember this fixture reference?",
            message: "You chose the generated fixture. Explicitly remember its reference in isolated .build state, resolve it without another chooser, then forget it. This does not bypass macOS privacy policy. This check does not establish consent retention across launches or rebuilds.",
            buttons: ["Remember, Restore, and Forget", "Skip Remembering"])
        guard remember == 0 else { return FolderObservation(status: "human-selected-fixture-skipped-remember", scopeStarted: chosen.lease.securityScopeStarted) }
        guard let saved = await controller.acceptChosenFolder(chosen.selection.url, remember: true) else {
            return FolderObservation(status: "remember-cancelled", scopeStarted: chosen.lease.securityScopeStarted)
        }
        defer { saved.lease.close() }
        guard case .saved = saved.remembering else {
            return FolderObservation(status: "real-bookmark-save-failed", scopeStarted: saved.lease.securityScopeStarted)
        }
        let restoredController = FolderAccessController(stateDirectory: state)
        let restored = await restoredController.resolveRememberedFolders()
        let restoredState: String
        if restored.count == 1, restored.first?.id == saved.selection.id {
            switch restored[0].state {
            case .resolvedUnverified: restoredState = "resolved-unverified"
            case .needsRenewal: restoredState = "stale-needs-renewal"
            case .unavailable(let diagnostic): restoredState = "unavailable-\(diagnostic.kind.rawValue)"
            }
        } else { restoredState = "reference-count-or-id-mismatch" }
        let forgetFailure = await restoredController.forget(id: saved.selection.id)
        let afterForget = await FolderAccessController(stateDirectory: state).resolveRememberedFolders()
        return FolderObservation(status: forgetFailure == nil && afterForget.isEmpty ? "human-selection-remember-restore-forget-observed" : "forget-not-qualified",
                                 scopeStarted: saved.lease.securityScopeStarted, restoredState: restoredState,
                                 forgetVerified: forgetFailure == nil && afterForget.isEmpty)
    }

    /// No entry names leave this synchronous worker; no recursion or file-body
    /// reads. lstat-equivalent metadata observes symlinks without following them.
    nonisolated private static func scanMetadata(_ url: URL) -> PermissionObservation {
        let directory = url.withUnsafeFileSystemRepresentation { $0.flatMap { opendir($0) } }
        guard let directory else {
            let code = errno
            let diagnostic = FolderAccessDiagnostic.describe(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            return PermissionObservation(status: diagnostic.kind.rawValue, posixError: code)
        }
        defer { closedir(directory) }
        var result = PermissionObservation(status: "readable-metadata-observed")
        while result.shallowEntryCount < 100_000 {
            if Task.isCancelled { result.status = "cancelled-partial"; return result }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { result.posixError = errno; result.status = "enumeration-error-partial" }
                return result
            }
            let metadataRead: Bool? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { name in
                    if name[0] == 46 && (name[1] == 0 || (name[1] == 46 && name[2] == 0)) { return nil }
                    var metadata = stat()
                    return fstatat(dirfd(directory), name, &metadata, AT_SYMLINK_NOFOLLOW) == 0
                }
            }
            guard let metadataRead else { continue }
            result.shallowEntryCount += 1
            if !metadataRead { result.metadataFailureCount += 1 }
        }
        result.truncated = true
        result.status = "readable-metadata-count-capped"
        return result
    }

    private static func prompt(_ window: NSWindow, title: String, message: String, buttons: [String]) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let response = await alert.beginSheetModal(for: window)
        return min(max(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue, 0), buttons.count - 1)
    }

    private static func write(_ report: Report, to url: URL) async throws {
        try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        }.value
    }

    private static func observeRestoreDirectory(_ directory: URL, using engine: LocalFileOperations) async throws -> FileOperationSelection {
        let observation = try await engine.observeDirectory(directory)
        guard observation.urls.map(\.path) == [directory.path] else {
            throw Failure(message: "Owned restore directory was redirected; recovery refused.")
        }
        try await Task.detached { try requirePlainDirectories(directory) }.value
        return observation
    }

    /// Rewrites below journal only this invocation's newly reserved receipt.
    /// A manually reused evidence directory cannot replace historical evidence.
    nonisolated private static func reserveNewReport(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation {
            $0.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure(message: "Qualification receipt already exists or could not be reserved; historical evidence was left unchanged.") }
        close(descriptor)
    }

    nonisolated private static func validateOwnedRoots(fixture: URL, evidence: URL, build: URL) throws {
        guard fixture.isFileURL, evidence.isFileURL, build.lastPathComponent == ".build",
              fixture.deletingLastPathComponent().lastPathComponent == "fixtures",
              evidence.deletingLastPathComponent() == build.appendingPathComponent("evidence", isDirectory: true),
              fixture.standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL,
              evidence.standardizedFileURL == evidence.resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure(message: "Interactive qualification requires owned checkout fixture/evidence roots.")
        }
        let marker = fixture.appendingPathComponent(".mac-explorer-fixture.json")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]
        guard metadata?["generator"] as? String == "mac-explorer-dev", metadata?["complete"] as? Bool == true else {
            throw Failure(message: "Interactive qualification refused an unowned listing fixture.")
        }
    }

    nonisolated private static func createTrashFixture(build: URL) throws -> TrashFixture {
        let base = build.appendingPathComponent("test-fixtures", isDirectory: true)
        guard base.standardizedFileURL == base.resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure(message: "Trash qualification fixture root is redirected.")
        }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        let id = UUID()
        let owned = base.appendingPathComponent("interactive-trash-\(id.uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: owned, withIntermediateDirectories: false)
        try Data(id.uuidString.utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        let source = owned.appendingPathComponent("mac-explorer-trash-\(id.uuidString)", isDirectory: true)
        let restore = owned.appendingPathComponent("restored", isDirectory: true)
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: restore, withIntermediateDirectories: false)
        try Data(id.uuidString.utf8).write(to: source.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        try payload(id).write(to: source.appendingPathComponent("owned-payload.txt"), options: .withoutOverwriting)
        var identity = stat()
        let observed = source.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &identity) } ?? -1 }
        guard observed == 0, identity.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(message: "Could not observe the owned Trash fixture identity.")
        }
        return TrashFixture(id: id, source: source, restoreDirectory: restore, device: identity.st_dev, inode: identity.st_ino)
    }

    nonisolated private static func payload(_ id: UUID) -> Data {
        Data("Mac Explorer disposable Trash qualification payload \(id.uuidString)\n".utf8)
    }

    nonisolated private static func payloadHash(_ id: UUID) -> String {
        SHA256.hash(data: payload(id)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func recoveryContext(receipt: URL, build: URL) throws -> RecoveryContext {
        let evidence = build.appendingPathComponent("evidence", isDirectory: true)
        guard receipt.lastPathComponent == "interactive-qualification.json",
              receipt.deletingLastPathComponent().lastPathComponent.hasPrefix("ui-"),
              receipt.deletingLastPathComponent().deletingLastPathComponent() == evidence else {
            throw Failure(message: "Recovery requires a prior receipt under this checkout's .build/evidence/ui-*.")
        }
        try requirePlainDirectories(receipt.deletingLastPathComponent())
        let descriptor = receipt.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        guard descriptor >= 0 else { throw Failure(message: "Prior recovery receipt could not be opened safely.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var receiptStat = stat()
        guard fstat(descriptor, &receiptStat) == 0, receiptStat.st_mode & S_IFMT == S_IFREG,
              receiptStat.st_size > 0, receiptStat.st_size <= 65_536,
              let data = try handle.read(upToCount: 65_537), data.count == Int(receiptStat.st_size) else {
            throw Failure(message: "Prior recovery receipt is not a bounded regular file.")
        }
        let prior = try JSONDecoder().decode(Report.self, from: data)
        guard ["offscreen-owned-fixture-api", "foreground-qualification"].contains(prior.mode),
              let trash = prior.trash,
              ["explicit-owned-fixture", "human-confirmed"].contains(trash.authorizationMode ?? ""),
              let originalPath = trash.originalFixture, let trashPath = trash.trashLocation,
              trash.recoverableLocation == trashPath, trash.restoredLocation == nil else {
            throw Failure(message: "Receipt does not identify one unrecovered explicitly owned Trash fixture.")
        }
        let source = URL(fileURLWithPath: originalPath, isDirectory: true).standardizedFileURL
        let name = source.lastPathComponent
        let prefix = "mac-explorer-trash-"
        guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + id.uuidString,
              trash.payloadSHA256 == payloadHash(id) else {
            throw Failure(message: "Receipt fixture UUID or generated payload hash is invalid.")
        }
        let owned = build.appendingPathComponent("test-fixtures/interactive-trash-\(id.uuidString)", isDirectory: true)
        let expectedSource = owned.appendingPathComponent(name, isDirectory: true)
        guard source == expectedSource else { throw Failure(message: "Receipt original fixture is outside its exact owned UUID root.") }
        try requirePlainDirectories(owned)
        let restore = owned.appendingPathComponent("restored", isDirectory: true)
        try requirePlainDirectories(restore)
        let ownedDescriptor = owned.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        guard ownedDescriptor >= 0 else { throw Failure(message: "Owned UUID recovery directory is unavailable.") }
        defer { close(ownedDescriptor) }
        try verifyOwnedFile(".fixture-owner", expected: Data(id.uuidString.utf8), in: ownedDescriptor)
        var ownStat = stat()
        guard fstat(ownedDescriptor, &ownStat) == 0 else { throw Failure(message: "Owned recovery volume could not be observed.") }
        var missing = stat()
        errno = 0
        let sourceStatus = source.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &missing) } ?? -1 }
        guard sourceStatus == -1, errno == ENOENT else { throw Failure(message: "Original fixture path is occupied or uncertain; recovery refused.") }

        var volume = statfs()
        let volumeStatus = owned.withUnsafeFileSystemRepresentation { $0.map { statfs($0, &volume) } ?? -1 }
        guard volumeStatus == 0 else { throw Failure(message: "Recovery could not identify the owned fixture mount.") }
        let mountPath = withUnsafePointer(to: &volume.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let expectedTrash = URL(fileURLWithPath: mountPath, isDirectory: true)
            .appendingPathComponent(".Trashes/\(geteuid())/\(name)", isDirectory: true)
        let location = URL(fileURLWithPath: trashPath, isDirectory: true).standardizedFileURL
        guard location == expectedTrash.standardizedFileURL else {
            throw Failure(message: "Receipt Trash location does not match this UID and the owned fixture mount.")
        }
        try requirePlainDirectories(location)
        var target = stat()
        let targetStatus = location.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &target) } ?? -1 }
        guard targetStatus == 0, target.st_mode & S_IFMT == S_IFDIR, target.st_dev == ownStat.st_dev else {
            throw Failure(message: "Exact Trash fixture is unavailable or is on another volume.")
        }
        let evidenceKind: String
        if let device = trash.sourceDevice, let inode = trash.sourceInode {
            guard target.st_dev == device, target.st_ino == inode else { throw Failure(message: "Receipt's original directory identity no longer matches.") }
            evidenceKind = "recorded-source-device-inode-and-owned-payload"
        } else {
            guard trash.sourceDevice == nil, trash.sourceInode == nil else { throw Failure(message: "Receipt source identity is incomplete.") }
            // The early historical receipt predates identity fields. Bind its
            // exact known location to the UUID owner marker and exact payload;
            // record this weaker provenance instead of inventing an old inode.
            evidenceKind = "historical-receipt-exact-location-uuid-markers-and-payload"
        }
        let fixture = TrashFixture(id: id, source: source, restoreDirectory: restore, device: target.st_dev, inode: target.st_ino)
        try validatePayload(at: location, fixture: fixture)
        return RecoveryContext(fixture: fixture, location: location, identityEvidence: evidenceKind)
    }

    /// Metadata traversal only: never list directories, and reject symlink
    /// ancestors even when a system Trash ancestor allows search without read.
    nonisolated private static func requirePlainDirectories(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw Failure(message: "Recovery directory must be a local absolute path.") }
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            candidate.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            let result = candidate.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &metadata) } ?? -1 }
            guard result == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
                throw Failure(message: "Recovery directory is missing, linked, or unavailable.")
            }
        }
    }

    nonisolated private static func validatePayload(at location: URL, fixture: TrashFixture) throws {
        guard location.isFileURL, location.lastPathComponent == "mac-explorer-trash-\(fixture.id.uuidString)" else {
            throw Failure(message: "Generated qualification payload identity or contents did not match.")
        }
        let descriptor = location.withUnsafeFileSystemRepresentation {
            $0.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure(message: "Generated fixture could not be opened without following a link.") }
        defer { close(descriptor) }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_dev == fixture.device, identity.st_ino == fixture.inode else {
            throw Failure(message: "Generated fixture directory identity changed.")
        }
        try verifyOwnedFile(".fixture-owner", expected: Data(fixture.id.uuidString.utf8), in: descriptor)
        try verifyOwnedFile("owned-payload.txt", expected: payload(fixture.id), in: descriptor)
    }

    nonisolated private static func verifyOwnedFile(_ name: String, expected: Data, in directory: Int32) throws {
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw Failure(message: "Generated payload file was unavailable.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size == Int64(expected.count),
              try handle.read(upToCount: expected.count + 1) == expected else {
            throw Failure(message: "Generated payload file identity or contents did not match.")
        }
    }
}
#endif
