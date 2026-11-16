#if DEBUG || TRAVERSE_SFTP_EDITOR_QA || TRAVERSE_ARCHIVE_DRIVE_QA
import Darwin
import Foundation

/// Shared bounded reads for these generated access/recovery fixtures only.
private enum OperationAccessFixtureIO {
    nonisolated static func readRegular(_ url: URL, maximum: Int) -> Data? {
        guard maximum > 0, maximum <= 1 << 20 else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size > 0, UInt64(before.st_size) <= UInt64(maximum) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            guard count > 0 else { return nil }
            offset += count
        }
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return Data(bytes)
    }
}

#endif

#if DEBUG
import AppKit
import FileOperations
import LocalStorage

@MainActor enum OperationAccessRecoveryVerification {
    static func run() async {
        var owner: BrowserWindowController?
        do {
            guard let text=ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.invalid }
            let root=URL(fileURLWithPath:text)
            let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let oldRoot = root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
            let ordinaryRoot = root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            guard oldRoot || ordinaryRoot,
                  root.resolvingSymlinksInPath()==root, UUID(uuidString:root.lastPathComponent)?.uuidString==root.lastPathComponent
            else { throw Failure.invalid }
            if ordinaryRoot {
                let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: String]
                try require(reservation?["action"] == "operation-access-recovery", "Unmarked native access fixture")
            }
            let settings=BrowserSettings(persist:false); settings.autoRefreshFolders=false; settings.reviewsRecoveryAtStartup=false
            settings.motion.mode = .off
            let controller=BrowserWindowController(settings:settings);owner=controller
            let browser=controller.browser
            browser.permitsBackgroundVerification=true
            browser.folderAccess=FolderAccessController(stateDirectory:nil)
            browser.recoverableFileOperations=RecoverableFileOperations(journalDirectory:root.appendingPathComponent("unused-history"))
            controller.window?.setFrameOrigin(.init(x:-12000,y:-12000))
            let fixture=root.appendingPathComponent("source")
            controller.beginBrowsing();browser.navigate(to:.directory(fixture))
            try await wait { !browser.isLoading && browser.orderingTask==nil }
            var requests:[URL?]=[]
            browser.operationFolderAccessRequestForVerification={ requests.append($0) }
            let denied=FileOperationResult(items:[.init(source:fixture.appendingPathComponent("Generated.txt"),
                destination:fixture.appendingPathComponent("Destination/Generated.txt"),status:.failed(.accessDenied),recoveryURLs:[])],cancellationRequested:false)
            browser.showOperationResultSheet(denied)
            guard let sheet=controller.window?.attachedSheet, let button=find("Choose Folder Access…",in:sheet.contentView) else { throw Failure.missingButton }
            try require(button.isEnabled,"Denied result access action disabled")
            button.performClick(nil)
            try await wait { requests.count==1 && controller.window?.attachedSheet==nil }
            try require(requests[0]==fixture,"Access chooser guessed mutation authority from an item path")
            try require(browser.operationCoordinator.transfers.state.outstandingCount==0 && browser.operationTask==nil
                && browser.folderAccess.locations.isEmpty,"Selecting access retried work or invented a grant")
            let other=FileOperationResult(items:[.init(source:nil,destination:nil,status:.failed(.ioFailure),recoveryURLs:[],role:.job)],cancellationRequested:false)
            browser.showOperationResultSheet(other)
            guard let ordinary=controller.window?.attachedSheet else { throw Failure.missingSheet }
            try require(find("Choose Folder Access…",in:ordinary.contentView)==nil,"Nonpermission failure offered a misleading access fix")
            controller.window?.endSheet(ordinary,returnCode:.alertFirstButtonReturn)
            try await wait { controller.window?.attachedSheet==nil }
            browser.showOperationError(FileOperationFailure.accessDenied)
            guard let initial=controller.window?.attachedSheet,let access=find("Choose Folder Access…",in:initial.contentView) else { throw Failure.missingButton }
            access.performClick(nil)
            try await wait { requests.count==2 && controller.window?.attachedSheet==nil }
            let token=UUID()
            try require(browser.operationCoordinator.beginPreparation(owner:token),"Generated busy control failed")
            browser.requestOperationFolderAccess(initialDirectory:fixture)
            browser.operationCoordinator.finishPreparation(owner:token)
            try require(requests.count==2,"Busy command admitted a second chooser")
            if ordinaryRoot { try await verifyColdUndoAdmission(root: root, browser: browser) }
            controller.suspendBrowsing();controller.window?.close();owner=nil
            browser.requestOperationFolderAccess(initialDirectory:fixture)
            try require(requests.count==2,"Closed browser admitted access UI")
            try await wait { ApplicationFileActivity.gate.activeCount==0 }
            let report:[String:Any]=["passed":true,"checks":["Actual denied Results action tears down before chooser dispatch",
                "Actual admission-error action uses the same route","Other failures offer no permission guess",
                "No automatic retry, fabricated grant or queue resume","Busy and closed hosts refuse the chooser"] + (ordinaryRoot ? [
                "Cold extraction and authored ZIP/TAR Undo request the recorded parent before submission",
                "Cancel, wrong folder and stale engine preserve committed history",
                "Selected access permits the exact inverse and drains its leases"] : []),
                "chooserDispatches":requests.count,"realOSGrants":0,"personalMutations":0,
                "generatedExtractions":ordinaryRoot ? 1 : 0,"generatedArchiveCreations":ordinaryRoot ? 2 : 0,
                "generatedUndos":ordinaryRoot ? 3 : 0,
                "activityCount":ApplicationFileActivity.gate.activeCount]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                .write(to:root.appendingPathComponent("result.json"),options:.withoutOverwriting)
        } catch {
            owner?.suspendBrowsing();owner?.window?.close()
            if let text=ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] {
                let report:[String:Any]=["passed":false,"failure":String(describing:error)]
                try? JSONSerialization.data(withJSONObject:report).write(to:URL(fileURLWithPath:text).appendingPathComponent("result.json"),options:.withoutOverwriting)
            }
        }
        NSApplication.shared.terminate(nil)
    }
    /// Extraction and authored v3 jobs share the ordinary Browser command and
    /// controlled scope backend. This is not macOS grant acceptance.
    private static func verifyColdUndoAdmission(root: URL, browser: BrowserViewController) async throws {
        let destination = root.appendingPathComponent("source/Destination")
        let history = root.appendingPathComponent("state/history")
        let forward = RecoverableFileOperations(journalDirectory: history, zipOneFilePublicExtractionPolicy: .sourceQualification)
        let session = try await ZIPArchiveReader().open(root.appendingPathComponent("source/Access.zip"))
        let page = try await session.page(in: session.root)
        guard page.items.count == 1, let item = page.items.first else { throw Failure.invalid }
        let roots = try await session.rootsForExport([item.id])
        await session.close()
        guard let selected = roots.first, roots.count == 1 else { throw Failure.invalid }
        let observation = try await forward.checkReceivedFileDestination(parent: destination, name: selected.name)
        let plan = try await forward.prepareZIPRootFilePublicExtraction(selected, parent: destination,
            name: selected.name, observing: observation)
        let made = await forward.performZIPRootExport(plan)
        guard made.result.disposition == .succeeded, let id = made.recordID else { throw Failure.invalid }
        let engine = RecoverableFileOperations(journalDirectory: history, zipOneFilePublicExtractionPolicy: .sourceQualification)
        try await verifyColdUndoAccess(root: root, browser: browser, engine: engine, id: id,
            output: plan.destination, expectedBody: Data("Generated cold Undo access.\n".utf8))

        let input = root.appendingPathComponent("source/Authored.txt")
        try await Task.detached {
            try Data("Generated authored archive access.\n".utf8).write(to: input, options: .withoutOverwriting)
        }.value
        for tar in [false, true] {
            let archiveHistory = root.appendingPathComponent(tar ? "state/tar-history" : "state/zip-history")
            let writer = RecoverableFileOperations(journalDirectory: archiveHistory,
                strictPortableTARCreationPolicy: tar ? .developmentExactSource : .held)
            let observed = try await writer.observeSelection([input])
            let archive = tar
                ? try await writer.prepareTARCreation(sources: [input], parent: destination, name: "Created.tar", observing: observed)
                : try await writer.prepareZIPCreation(sources: [input], parent: destination, name: "Created.zip", observing: observed)
            let created = await writer.performArchiveCreation(archive)
            guard created.result.disposition == .succeeded, let archiveID = created.recordID else { throw Failure.invalid }
            guard let expected = await Task.detached(priority: .utility, operation: {
                OperationAccessFixtureIO.readRegular(archive.destination, maximum: 1 << 20)
            }).value else { throw Failure.invalid }
            let cold = RecoverableFileOperations(journalDirectory: archiveHistory)
            try await verifyColdUndoAccess(root: root, browser: browser, engine: cold, id: archiveID,
                output: archive.destination, expectedBody: expected)
        }
    }
    private static func verifyColdUndoAccess(root: URL, browser: BrowserViewController,
        engine: RecoverableFileOperations, id: UUID, output: URL, expectedBody: Data) async throws {
        let destination = output.deletingLastPathComponent()
        guard let record = try await engine.inspectExistingHistory().records.first(where: { $0.id == id }) else { throw Failure.invalid }
        browser.requiresUndoFolderSelectionForVerification = true
        defer {
            browser.requiresUndoFolderSelectionForVerification = false
            browser.undoFolderSelectionForVerification = nil
        }
        let backend = RecoveryScopeProbe(root: destination)
        var choices = 0
        var requested: [URL] = []
        for mode in 0..<3 {
            browser.recoverableFileOperations = engine
            browser.folderAccess = FolderAccessController(stateDirectory: nil, backend: backend)
            browser.undoFolderSelectionForVerification = { directory in
                choices += 1
                requested.append(directory)
                if mode == 0 { return nil }
                if mode == 1 {
                    return await browser.folderAccess.acceptChosenFolder(root.appendingPathComponent("source"))
                }
                browser.recoverableFileOperations = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("unused-history"))
                return nil
            }
            var outcome: RecoverableOperationResult?
            browser.startRecoveryOperation(record, rollback: false, presentsResult: false) { outcome = $0 }
            await browser.operationPreparationTask?.value
            try require(outcome != nil && outcome?.result.disposition != .succeeded
                && requested.last?.standardizedFileURL.pathComponents == destination.standardizedFileURL.pathComponents,
                "Undo admission did not settle its callback")
            let retained = try await engine.inspectExistingHistory().records.first { $0.id == id }
            try require(retained?.state == "committed" && retained?.canUndo == true
                && browser.operationTask == nil && browser.operationCoordinator.activeOwner == nil
                && browser.operationCoordinator.preparationOwner == nil && backend.active == 0,
                "Unsubmitted Undo changed history or retained its operation/access owner")
            guard let body = await Task.detached(priority: .utility, operation: {
                OperationAccessFixtureIO.readRegular(output, maximum: expectedBody.count)
            }).value else { throw Failure.invalid }
            try require(body == expectedBody, "Refused Undo changed the generated output")
        }
        browser.recoverableFileOperations = engine
        browser.folderAccess = FolderAccessController(stateDirectory: nil, backend: backend)
        browser.undoFolderSelectionForVerification = { directory in
            choices += 1
            requested.append(directory)
            return await browser.folderAccess.acceptChosenFolder(directory)
        }
        var outcome: RecoverableOperationResult?
        browser.startRecoveryOperation(record, rollback: false, presentsResult: false) { outcome = $0 }
        await browser.operationPreparationTask?.value
        await browser.operationTask?.value
        try require(outcome?.result.disposition == .succeeded && choices == 4 && backend.active == 0
            && requested.allSatisfy { $0.standardizedFileURL.pathComponents == destination.standardizedFileURL.pathComponents },
            "Exact selected destination did not complete Undo or release its scope")
        let removed = await Task.detached { !FileManager().fileExists(atPath: output.path) }.value
        try require(removed, "Confirmed Undo left the generated output visible")
    }
    private static func find(_ title:String,in root:NSView?)->NSButton? {
        guard let root else { return nil }
        if let button=root as? NSButton,button.title==title { return button }
        return root.subviews.lazy.compactMap { find(title,in:$0) }.first
    }
    private static func require(_ value:Bool,_ message:String)throws { if !value { throw UIVerification.Failure(message:message) } }
    private static func wait(_ condition:()->Bool)async throws {
        let end=ProcessInfo.processInfo.systemUptime+8
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime<end,"Generated access UI deadline")
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    private enum Failure:Error { case invalid,missingButton,missingSheet }
}
/// Generated native review: prove lease ownership without requesting real grants.
@MainActor enum RecoveryAccessQualification {
    @MainActor private final class Hold {
        var pending: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { pending = $0 } }
        func release() { pending?.resume(); pending = nil }
    }
    static func run() async {
        var owner: BrowserWindowController?
        let hold = Hold()
        do {
            guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.invalid }
            let root = URL(fileURLWithPath: text)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
                  root.resolvingSymlinksInPath() == root,
                  UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else { throw Failure.invalid }
            let fixture = root.appendingPathComponent("source"), source = fixture.appendingPathComponent("Source/Generated.txt")
            let destination = fixture.appendingPathComponent("Destination")
            let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/operations"))
            let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: destination, move: false)
            let copied = await engine.perform(plan, resolutions: [:])
            guard copied.result.disposition == .succeeded, let id = copied.recordID else { throw Failure.invalid }
            let undone = await engine.undo(recordID: id)
            try require(undone.result.disposition == .succeeded, "Generated Copy/Undo preparation failed")
            let backend = RecoveryScopeProbe(root: fixture)
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.motion.mode = .off
            let controller = BrowserWindowController(settings: settings); owner = controller
            let browser = controller.browser
            browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil, backend: backend)
            browser.recoverableFileOperations = engine
            controller.window?.setFrameOrigin(.init(x: -12000, y: -12000))
            controller.beginBrowsing(); browser.navigate(to: .computer)
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            guard let selected = await browser.folderAccess.acceptChosenFolder(fixture) else { throw Failure.invalid }
            selected.lease.close()
            try require(backend.active == 0, "Grant selection retained an unrelated browsing lease")
            browser.showOperationRecovery(nil)
            await browser.recoveryInspectionTask?.value
            await browser.retentionInspectionTask?.value
            let first = browser.retentionRecords.first(where: { $0.id == id })
            try require(first?.areas.count == 1 && first?.areas.allSatisfy(\.verified) == true
                        && first?.canCleanup == true && first?.logicalBytes.map({ $0 >= 44 }) == true,
                        "Selected backup did not verify from This Mac")
            let initialStarts = backend.starts
            browser.beforeRetentionInspectionForVerification = { await hold.wait() }
            browser.inspectRecoveryRetention(id)
            let blocked = browser.retentionInspectionTask
            try await wait { hold.pending != nil }
            try require(backend.active == 1 && backend.starts == initialStarts + 1,
                        "Selected verification did not retain exactly its remembered root")
            browser.recoveryWindow?.close()
            try require(backend.active == 1, "Closing review released access before its work drained")
            hold.release(); await blocked?.value
            try require(backend.active == 0 && browser.retentionRecords.allSatisfy { $0.id != id },
                        "Closed review published stale verification or leaked its lease")
            browser.beforeRetentionInspectionForVerification = nil
            let closedStarts = backend.starts
            browser.inspectOperationRecovery(); await browser.recoveryInspectionTask?.value
            try require(backend.starts == closedStarts, "Closed history refresh read historical file trees")
            browser.showOperationRecovery(nil)
            await browser.recoveryInspectionTask?.value
            await browser.retentionInspectionTask?.value
            try require(browser.retentionRecords.first(where: { $0.id == id })?.areas.allSatisfy(\.verified) == true
                        && backend.active == 0, "Reopened selected verification failed or retained access")
            browser.beforeRetentionInspectionForVerification = { await hold.wait() }
            browser.inspectRecoveryRetention(id)
            let changedSelection = browser.retentionInspectionTask
            try await wait { hold.pending != nil }
            browser.recoveryWindow?.showRequestedRecordUnavailable("Generated selection change")
            hold.release(); await changedSelection?.value
            try require(browser.retentionRecords.allSatisfy { $0.id != id } && backend.active == 0,
                        "Changed selection published stale verification")
            browser.recoveryWindow?.requestSelection(recordID: id)
            browser.inspectRecoveryRetention(id)
            let stale = browser.retentionInspectionTask
            try await wait { hold.pending != nil }
            browser.recoverableFileOperations = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("unused-history"))
            hold.release(); await stale?.value
            try require(browser.retentionRecords.allSatisfy { $0.id != id } && backend.active == 0,
                        "Changed engine published stale verification")
            controller.suspendBrowsing(); controller.window?.close(); owner = nil
            try await wait { ApplicationFileActivity.gate.activeCount == 0 }
            let report: [String: Any] = ["passed": true, "checks": ["This Mac selected-backup verification uses remembered root",
                "One selected root, no whole-history access", "Close retains access through drain and rejects late results",
                "Closed metadata refresh acquires no file roots",
                "Reopen verifies again", "Changed selection rejects stale completion", "Changed engine rejects stale completion"],
                "scopeStarts": backend.starts, "remainingScopes": backend.active, "realOSGrants": 0,
                "personalMutations": 0, "activityCount": ApplicationFileActivity.gate.activeCount]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        } catch {
            hold.release(); owner?.suspendBrowsing(); owner?.window?.close()
            if let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "failure": String(describing: error)])
                    .write(to: URL(fileURLWithPath: text).appendingPathComponent("result.json"), options: .withoutOverwriting)
            }
        }
        NSApplication.shared.terminate(nil)
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw UIVerification.Failure(message: message) }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Selected recovery control deadline")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case invalid }
}

private final class RecoveryScopeProbe: FolderAccessBackend, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var current = 0, count = 0
    init(root: URL) { self.root = root }
    var active: Int { lock.withLock { current } }
    var starts: Int { lock.withLock { count } }
    func startAccess(to url: URL) -> Bool {
        guard url == root else { return false }
        lock.withLock { current += 1; count += 1 }; return true
    }
    func stopAccess(to url: URL) { lock.withLock { current -= 1 } }
    func bookmark(for url: URL) throws -> Data { throw CocoaError(.fileReadUnsupportedScheme) }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw CocoaError(.fileReadUnsupportedScheme) }
}
#endif

#if TRAVERSE_SFTP_EDITOR_QA
import AppKit
import CoreServices
import CryptoKit
import Darwin
import ExplorerCore
@_spi(ArchiveProduction) @_spi(Qualification) import FileOperations
import Foundation
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage

/// A separate, counted signed visit through actual Launch Services folder
/// delivery. The generated fixture and every receipt stay outside the old
/// signed21 ZIP case; this route never grants access by constructing a URL.
@MainActor enum OperationAccessRecoverySignedVerification {
    nonisolated private static let body = Data("Generated cold Undo access.\n".utf8)
    nonisolated private static let leaf = "Received.txt"
    nonisolated private static let archiveName = "Access.zip"
    nonisolated private static let receiptFormat = "zip-one-file-access-v1"
    private enum Refusal: Error { case invalid }

    private struct Receipt: Codable, Sendable {
        let format: String
        let phase: String
        let fixtureID: String
        let recordID: String?
        let archiveSHA256: String?
        let inputSHA256: String?
        let catalog: GeneratedPublicCatalogObservation?
        let outputLeaf: String?
        let pid: Int32
        init(_ phase: String, fixtureID: String, recordID: UUID? = nil,
             archiveSHA256: String? = nil, format: String = receiptFormat, inputSHA256: String? = nil,
             catalog: GeneratedPublicCatalogObservation? = nil, outputLeaf: String? = nil) {
            self.format = format; self.phase = phase; self.fixtureID = fixtureID
            self.recordID = recordID?.uuidString; self.archiveSHA256 = archiveSHA256
            self.inputSHA256 = inputSHA256; self.catalog = catalog; self.outputLeaf = outputLeaf; pid = getpid()
        }
    }

    /// The files are private, exclusive and small. An interrupted attempt is
    /// retained and makes a later automatic retry refuse before any mutation.
    private struct ReceiptStore: Sendable {
        let directory: URL
        let format: String
        init(directory: URL, format: String = receiptFormat) { self.directory = directory; self.format = format }
        private func openedDirectory() throws -> Int32 {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw Refusal.invalid }
            var facts = stat()
            guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                  facts.st_uid == geteuid(), facts.st_mode & 0o077 == 0 else {
                close(fd); throw Refusal.invalid
            }
            return fd
        }
        func read(_ name: String) async throws -> Receipt? {
            try await Task.detached { [self] in
                let parent = try openedDirectory(); defer { close(parent) }
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 && errno == ENOENT { return nil }
                guard fd >= 0 else { throw Refusal.invalid }
                defer { close(fd) }
                var before = stat(), after = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_uid == geteuid(), before.st_mode & 0o077 == 0,
                      before.st_nlink == 1, (1...4096).contains(before.st_size) else { throw Refusal.invalid }
                let count = Int(before.st_size)
                var bytes = [UInt8](repeating: 0, count: count), offset = 0
                while offset < count {
                    let readCount = bytes.withUnsafeMutableBytes { raw in
                        Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                    }
                    guard readCount > 0 else { throw Refusal.invalid }
                    offset += readCount
                }
                guard fstat(fd, &after) == 0, before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Refusal.invalid }
                let value = try JSONDecoder().decode(Receipt.self, from: Data(bytes))
                guard value.format == format else { throw Refusal.invalid }
                return value
            }.value
        }
        func write(_ name: String, _ value: Receipt) async throws {
            guard value.format == format else { throw Refusal.invalid }
            try await Task.detached { [self] in
                let parent = try openedDirectory(); defer { close(parent) }
                let data = try JSONEncoder().encode(value)
                guard data.count <= 4096 else { throw Refusal.invalid }
                let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Refusal.invalid }
                defer { close(fd) }
                let complete = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                        guard count > 0 else { return false }
                        offset += count
                    }
                    return true
                }
                guard complete, fsync(fd) == 0, fsync(parent) == 0 else { throw Refusal.invalid }
            }.value
        }
    }

    nonisolated private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    nonisolated private static func fixtureRoot(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw Refusal.invalid }
        return repository.appendingPathComponent(".build/traverse-development", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
    nonisolated private static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.isFileURL && rhs.isFileURL && lhs.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
    }
    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func readGeneratedRegular(_ url: URL, maximum: Int) throws -> Data {
        guard let bytes = OperationAccessFixtureIO.readRegular(url, maximum: maximum) else { throw Refusal.invalid }
        return bytes
    }
    nonisolated private static func require(_ condition: Bool) throws {
        if !condition { throw Refusal.invalid }
    }
    private static func wait(seconds: Double, until condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func validateFixture(_ root: URL, expecting expectedSHA: String? = nil,
        archiveLeaf: String = archiveName, hashKey: String = "archiveSHA256",
        action: String = "operation-access-recovery",
        retaining access: FileAccessLifetimes) async throws -> String {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            let id = root.lastPathComponent
            guard (try? fixtureRoot(id)).map({ sameFolder(root, $0) }) == true,
                  sameFolder(root.resolvingSymlinksInPath(), root) else { throw Refusal.invalid }
            let markerURL = root.appendingPathComponent("reservation.json")
            let source = root.appendingPathComponent("source", isDirectory: true)
            let archive = source.appendingPathComponent(archiveLeaf)
            let destination = source.appendingPathComponent("Destination", isDirectory: true)
            var rootFacts = stat(), sourceFacts = stat(), markerFacts = stat(), archiveFacts = stat(), destinationFacts = stat()
            guard lstat(root.path, &rootFacts) == 0, rootFacts.st_mode & S_IFMT == S_IFDIR,
                  lstat(source.path, &sourceFacts) == 0, sourceFacts.st_mode & S_IFMT == S_IFDIR,
                  lstat(destination.path, &destinationFacts) == 0,
                  destinationFacts.st_mode & S_IFMT == S_IFDIR,
                  lstat(markerURL.path, &markerFacts) == 0, markerFacts.st_mode & S_IFMT == S_IFREG,
                  markerFacts.st_size <= 4096, markerFacts.st_nlink == 1,
                  lstat(archive.path, &archiveFacts) == 0, archiveFacts.st_mode & S_IFMT == S_IFREG,
                  archiveFacts.st_size <= 1 << 20, archiveFacts.st_nlink == 1,
                  [rootFacts, sourceFacts, destinationFacts, markerFacts, archiveFacts].allSatisfy({ $0.st_uid == geteuid() }) else {
                throw Refusal.invalid
            }
            let marker = try JSONSerialization.jsonObject(with: readGeneratedRegular(markerURL,
                maximum: 4096)) as? [String: String]
            let claimed = marker?[hashKey] ?? ""
            guard marker?["packet"] == "traverse-development-v1",
                  marker?["action"] == action,
                  claimed.utf8.count == 64,
                  claimed.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
                  expectedSHA == nil || claimed == expectedSHA else { throw Refusal.invalid }
            let bytes = try readGeneratedRegular(archive, maximum: 1 << 20)
            guard digest(bytes) == claimed,
                  try archive.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else {
                throw Refusal.invalid
            }
            return claimed
        }.value
    }

    private static func verifyPublished(_ output: URL, archive: URL, archiveSHA: String,
        retaining access: FileAccessLifetimes) async throws {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            guard try readGeneratedRegular(output, maximum: body.count) == body,
                  try output.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false,
                  digest(try readGeneratedRegular(archive, maximum: 1 << 20)) == archiveSHA else { throw Refusal.invalid }
        }.value
    }

    static func run(controller: BrowserWindowController, incoming: IncomingFolderOpening) async {
        var stage = "admission", phase = "unknown"
        do {
            try require(GeneratedSandboxReview.zipOneFileAccessAdmitted)
            guard let state = AppStorageLocations.stateDirectory else { throw Refusal.invalid }
            let store = ReceiptStore(directory: state.appendingPathComponent("zip-one-file-access-qa", isDirectory: true))
            let warmReceipt = try await store.read("warm.json")
            if let warmReceipt {
                phase = "cold"
                stage = "coldAdmission"
                try await cold(controller: controller, incoming: incoming, store: store, warm: warmReceipt,
                    stage: &stage)
                stage = "coldUndone"
            } else {
                phase = "warm"
                stage = "warmAdmission"
                try require(try await store.read("warm-attempt.json") == nil)
                try await warm(controller: controller, incoming: incoming, store: store,
                    stage: &stage)
                stage = "warmCommitted"
            }
            fputs("TRAVERSE_ZIP_ACCESS phase=\(phase) stage=\(stage) result=appChecksSatisfied pid=\(getpid())\n", stderr)
        } catch {
            // Fail closed. Diagnostics contain only fixed stage tokens; the
            // generated paths, archive body and private OS marks stay private.
            fputs("TRAVERSE_ZIP_ACCESS phase=\(phase) stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }

    private static func warm(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, stage: inout String) async throws {
        let browser = controller.browser
        stage = "awaitNativeOpen"
        try await wait(seconds: 20) { incoming.openedCount == 1 && browser.location.directoryURL != nil }
        guard let root = browser.location.directoryURL,
              let engine = browser.recoverableFileOperations else { throw Refusal.invalid }
        let access = await browser.accessLifetime(for: [root])
        defer { withExtendedLifetime(access) {} }
        try require(access.leases.count == 1 && sameFolder(access.leases[0].url, root)
            && browser.folderAccess.selectedRootCovering(root).map({ sameFolder($0, root) }) == true)
        stage = "fixture"
        let archiveSHA = try await validateFixture(root, retaining: access)
        let fixtureID = root.lastPathComponent
        let archive = root.appendingPathComponent("source", isDirectory: true).appendingPathComponent(archiveName)
        let destination = root.appendingPathComponent("source/Destination", isDirectory: true)
        let output = destination.appendingPathComponent(leaf)
        let reader = ZIPArchiveReader(activity: ApplicationFileActivity.gate)
        let session = try await reader.open(archive, retaining: access)
        let selected: ZIPRootExportSelection
        do {
            let page = try await session.page(in: session.root)
            try require(page.items.count == 1 && page.items[0].kind == .file && page.items[0].name == leaf)
            let previewSelection = try await session.selectionForTextPreview(page.items[0].id)
            let preview = try await reader.previewText(previewSelection, retaining: access)
            try require(Data(preview.text.utf8) == body)
            let roots = try await session.rootsForExport([page.items[0].id])
            guard roots.count == 1, let root = roots.first else { throw Refusal.invalid }
            selected = root
            await session.close()
        } catch {
            await session.close(); throw error
        }
        let observation = try await engine.checkReceivedFileDestination(parent: destination, name: leaf)
        let bound = ArchiveExtractionDestination(directory: destination, observation: observation,
            access: await browser.accessLifetime(for: [destination]))
        try require(bound.matchesObservedDirectory && bound.access.leases.count == 1)
        let model = ArchiveExtractionModel(source: archive, browser: browser, engine: engine,
            zipRoot: selected, destination: bound)
        stage = "warmAttempt"
        try await store.write("warm-attempt.json", Receipt("warmAttempt", fixtureID: fixtureID,
            archiveSHA256: archiveSHA))
        do {
            model.requestPreview()
            try await wait(seconds: 15) { model.canExtract }
            stage = "extract"
            model.extract()
            try require(model.isRunning && browser.operationTask != nil)
            await browser.operationTask?.value
            guard let result = model.outcome, result.result.disposition == .succeeded,
                  let recordID = result.recordID,
                  result.result.items.first?.destination.map({ sameFolder($0, output) }) == true else {
                throw Refusal.invalid
            }
            await model.closeAndDrain()
            stage = "warmVerify"
            try await verifyPublished(output, archive: archive, archiveSHA: archiveSHA, retaining: access)
            let history = try await engine.inspectExistingHistory()
            try require(history.records.contains { $0.id == recordID && $0.operation == "Extract ZIP"
                && $0.state == "committed" && $0.canUndo })
            let requirement = try await engine.undoAccessRequirement(recordID: recordID)
            try require(requirement.map({ sameFolder($0.directory, destination) }) == true)
            try await store.write("warm.json", Receipt("warmCommitted", fixtureID: fixtureID,
                recordID: recordID, archiveSHA256: archiveSHA))
        } catch {
            await model.closeAndDrain(); throw error
        }
    }

    private static func cold(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, warm: Receipt, stage: inout String) async throws {
        try require(warm.phase == "warmCommitted" && warm.format == receiptFormat)
        guard let idText = warm.recordID, let recordID = UUID(uuidString: idText),
              let archiveSHA = warm.archiveSHA256,
              archiveSHA.utf8.count == 64 else { throw Refusal.invalid }
        let root = try fixtureRoot(warm.fixtureID)
        let archive = root.appendingPathComponent("source", isDirectory: true).appendingPathComponent(archiveName)
        let destination = root.appendingPathComponent("source/Destination", isDirectory: true)
        let output = destination.appendingPathComponent(leaf)
        let browser = controller.browser
        // Let the ordinary workspace finish restoration before replacing its
        // access owner. A still-running startup must not reintroduce a grant.
        await controller.workspace.startupTask?.value
        try require(controller.workspace.sessionReady && controller.workspace.browsers.count == 1
            && controller.workspace.activeBrowser === browser)
        guard let engine = browser.recoverableFileOperations,
              TraverseAccessPolicy.requiresFolderSelection else { throw Refusal.invalid }
        // A transient controller deliberately removes any earlier remembered
        // grant from this generated browser only. Saved references stay on disk.
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        try require(incoming.openedCount == 0 && !browser.folderAccess.hasSelectedAccess(to: destination))
        try require(try await store.read("cold-attempt.json") == nil)
        let initial = try await engine.inspectExistingHistory()
        guard let record = initial.records.first(where: { $0.id == recordID }),
              record.operation == "Extract ZIP", record.state == "committed", record.canUndo,
              let requirement = try await engine.undoAccessRequirement(recordID: recordID),
              sameFolder(requirement.directory, destination) else { throw Refusal.invalid }
        stage = "coldAttempt"
        try await store.write("cold-attempt.json", Receipt("coldAttempt", fixtureID: warm.fixtureID,
            recordID: recordID, archiveSHA256: archiveSHA))
        var refused: RecoverableOperationResult?
        browser.startRecoveryOperation(record, rollback: false, presentsResult: false) { refused = $0 }
        stage = "nativePanel"
        try await wait(seconds: 12) { controller.window?.attachedSheet is NSOpenPanel }
        guard let panel = controller.window?.attachedSheet as? NSOpenPanel else { throw Refusal.invalid }
        try require(browser.folderAccess.pendingUndoDirectoryForQualification
            .map({ sameFolder($0, destination) }) == true
            && panel.canChooseDirectories && !panel.canChooseFiles
            && !browser.folderAccess.hasSelectedAccess(to: destination))
        browser.folderAccess.invalidatePendingRequests()
        try await wait(seconds: 12) { refused != nil && browser.operationPreparationTask == nil }
        try require(refused?.result.items.first?.status == .cancelled && browser.operationTask == nil
            && browser.operationCoordinator.activeOwner == nil
            && browser.operationCoordinator.preparationOwner == nil)
        let afterCancel = try await engine.inspectExistingHistory()
        try require(afterCancel.records.contains { $0.id == recordID && $0.state == "committed" && $0.canUndo })
        let renewed = try await engine.undoAccessRequirement(recordID: recordID)
        try require(renewed == requirement && incoming.openedCount == 0)
        try await store.write("cold-cancel.json", Receipt("nativePanelCancelled", fixtureID: warm.fixtureID,
            recordID: recordID, archiveSHA256: archiveSHA))
        fputs("TRAVERSE_ZIP_ACCESS phase=cold stage=awaitingOSRegrant pid=\(getpid())\n", stderr)
        stage = "awaitOSRegrant"
        try await wait(seconds: 45) { incoming.openedCount == 1 && browser.folderAccess.hasSelectedAccess(to: destination) }
        guard let opened = browser.location.directoryURL, sameFolder(opened, root) else { throw Refusal.invalid }
        let access = await browser.accessLifetime(for: [destination])
        defer { withExtendedLifetime(access) {} }
        try require(access.leases.count == 1 && sameFolder(access.leases[0].url, root)
            && browser.folderAccess.selectedRootCovering(destination).map({ sameFolder($0, root) }) == true)
        stage = "regrantVerify"
        _ = try await validateFixture(root, expecting: archiveSHA, retaining: access)
        try await verifyPublished(output, archive: archive, archiveSHA: archiveSHA, retaining: access)
        let current = try await engine.inspectExistingHistory()
        guard let fresh = current.records.first(where: { $0.id == recordID }),
              fresh.state == "committed", fresh.canUndo else { throw Refusal.invalid }
        let finalRequirement = try await engine.undoAccessRequirement(recordID: recordID)
        try require(finalRequirement == requirement)
        var undone: RecoverableOperationResult?
        stage = "undo"
        browser.startRecoveryOperation(fresh, rollback: false, presentsResult: false) { undone = $0 }
        try await wait(seconds: 30) { undone != nil || controller.window?.attachedSheet != nil }
        if controller.window?.attachedSheet != nil {
            browser.folderAccess.invalidatePendingRequests(); throw Refusal.invalid
        }
        try require(undone?.result.disposition == .succeeded)
        await browser.operationTask?.value
        let final = try await engine.inspectExistingHistory()
        try require(final.records.contains { $0.id == recordID && $0.state == "undone" && !$0.canUndo })
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            guard !FileManager.default.fileExists(atPath: output.path),
                  digest(try readGeneratedRegular(archive, maximum: 1 << 20)) == archiveSHA else { throw Refusal.invalid }
        }.value
        try await store.write("cold.json", Receipt("coldUndone", fixtureID: warm.fixtureID,
            recordID: recordID, archiveSHA256: archiveSHA))
    }
}


/// The same signed access owner covers concrete ZIP/TAR file/tree jobs. One
/// actual OS grant and one cold regrant replace repeated per-format choosers.
@MainActor private extension OperationAccessRecoverySignedVerification {
    nonisolated static let archiveReceiptFormat = "archive-public-access-v1"
    nonisolated static let childBody = Data("Generated tree child.\n".utf8)
    enum ArchiveJob: String, CaseIterable, Sendable {
        case zipTree, zipFile, zipCode, tarTree, tarFile, tarCode, compressedTree, compressedFile, compressedCode
        var isTree: Bool { self == .zipTree || self == .tarTree || self == .compressedTree }
        var isZIP: Bool { self == .zipTree || self == .zipFile || self == .zipCode }
        var compressed: Bool { self == .compressedTree || self == .compressedFile || self == .compressedCode }
        var isCode: Bool { self == .zipCode || self == .tarCode || self == .compressedCode }
        var entryName: String { isCode ? "InertCode" : leaf }
        var sourceName: String { isZIP ? "Access.zip" : compressed ? "Access.tar.gz" : "Access.tar" }
        var hashKey: String { isZIP ? "archiveSHA256" : compressed ? "compressedSHA256" : "tarSHA256" }
        var outputName: String { rawValue + (isTree ? "" : isCode ? "-NeverRun" : ".txt") }
        var operation: String { isZIP ? "Extract ZIP" : "Extract TAR" }
        var version: Int { isTree ? 16 : isZIP ? 15 : 17 }
        var purpose: String { isTree ? isZIP ? "zipTree" : "tarTree" : isZIP ? "zipFile" : "tarFile" }
    }
    private static func archiveReceipt(_ phase: String, root: URL, record: UUID? = nil, sha: String? = nil,
        catalog: GeneratedPublicCatalogObservation? = nil, outputLeaf: String? = nil) -> Receipt {
        Receipt(phase, fixtureID: root.lastPathComponent, recordID: record, archiveSHA256: sha,
            format: archiveReceiptFormat, catalog: catalog, outputLeaf: outputLeaf)
    }
    private static func clipboardOutputLeaf(_ job: ArchiveJob, receipt: Receipt) throws -> String {
        guard let name = receipt.outputLeaf else { return job.outputName }
        try require(job == .compressedFile && name == leaf)
        return name
    }
    static func archiveFixture(_ root: URL, job: ArchiveJob, expected: String? = nil,
        access: FileAccessLifetimes) async throws -> String {
        try await validateFixture(root, expecting: expected, archiveLeaf: job.sourceName,
            hashKey: job.hashKey, action: "archive-public-completion", retaining: access)
    }
    static func verifyArchiveOutput(_ output: URL, job: ArchiveJob, root: URL, access: FileAccessLifetimes) async throws {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            let code: Data
            if job.isTree || job.isCode {
                code = try readGeneratedRegular(root.appendingPathComponent("source/InertCode"), maximum: 16_880)
                guard code.count == 16_880,
                      digest(code) == "fe5ac89a4e3d903399c4b585b85bd9e458b1530144a25713cde88e037c53d6ae" else {
                    throw Refusal.invalid
                }
            } else { code = Data() }
            let files = job.isTree ? [output.appendingPathComponent(leaf): body,
                output.appendingPathComponent("Folder/Child.txt"): childBody,
                output.appendingPathComponent("InertCode"): code] : [output: job.isCode ? code : body]
            let directories = job.isTree ? [output, output.appendingPathComponent("Folder"),
                output.appendingPathComponent("Folder/Empty")] : []
            for directory in directories {
                var facts = stat()
                guard lstat(directory.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                      facts.st_mode & 0o7777 == 0o755, facts.st_uid == geteuid(),
                      try directory.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else {
                    throw Refusal.invalid
                }
            }
            if job.isTree {
                guard Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == [leaf, "Folder", "InertCode"],
                      Set(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Folder").path)) == ["Child.txt", "Empty"],
                      try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Folder/Empty").path).isEmpty else {
                    throw Refusal.invalid
                }
            }
            for (file, expected) in files {
                var facts = stat()
                guard lstat(file.path, &facts) == 0, facts.st_mode & 0o7777 == 0o644,
                      try readGeneratedRegular(file, maximum: expected.count) == expected,
                      try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else {
                    throw Refusal.invalid
                }
            }
        }.value
    }
    static func archiveModel(_ job: ArchiveJob, root: URL, browser: BrowserViewController,
        engine: RecoverableFileOperations, access: FileAccessLifetimes,
        stage: inout String) async throws -> ArchiveExtractionModel {
        let source = root.appendingPathComponent("source").appendingPathComponent(job.sourceName)
        let parent = root.appendingPathComponent("source/Destination", isDirectory: true)
        stage = "destination-" + job.rawValue
        let observation = job.isTree
            ? try await engine.checkReceivedDirectoryDestination(parent: parent, name: job.outputName)
            : try await engine.checkReceivedFileDestination(parent: parent, name: job.outputName)
        let destination = ArchiveExtractionDestination(directory: parent, observation: observation,
            access: await browser.accessLifetime(for: [parent]))
        try require(destination.matchesObservedDirectory && destination.access.leases.count == 1)
        var zip: ZIPRootExportSelection?, tar: TARExtractionSelection?
        if job.isZIP && !job.isTree {
            stage = "catalog-" + job.rawValue
            let session = try await ZIPArchiveReader(activity: ApplicationFileActivity.gate).open(source, retaining: access)
            do {
                let page = try await session.page(in: session.root)
                guard let file = page.items.first(where: { $0.name == job.entryName && $0.kind == .file }) else { throw Refusal.invalid }
                let roots = try await session.rootsForExport([file.id])
                guard roots.count == 1 else { throw Refusal.invalid }; zip = roots[0]
                await session.close()
            } catch { await session.close(); throw error }
        } else if !job.isZIP {
            let reader: TARArchiveReader
            if job.compressed {
                reader = ApplicationCompressedArchives.shared.reader(excluding: ApplicationOperationCoordinator.shared.protectedStorageLocations)
                stage = "cache-" + job.rawValue
                try await ApplicationCompressedArchives.shared.prepareStorage()
            } else { reader = TARArchiveReader(activity: ApplicationFileActivity.gate) }
            stage = "catalog-" + job.rawValue
            let session = job.compressed ? try await reader.prepareCompressed(source, retaining: access,
                publicQuarantineSource: true, progress: { progress in
                let phase: String
                switch progress.phase {
                case .checkingSource: phase = "checkingSource"
                case .preparingStorage: phase = "preparingStorage"
                case .checkingOrphans: phase = "checkingOrphans"
                case .checkingSpace: phase = "checkingSpace"
                case .checkingRoot: phase = "checkingRoot"
                case .decoding: phase = "decoding"
                case .validating: phase = "validating"
                case .cataloging: phase = "cataloging"
                }
                fputs("TRAVERSE_ARCHIVE_PREPARATION job=\(job.rawValue) phase=\(phase)\n", stderr)
            })
                : try await reader.open(source, retaining: access)
            do {
                stage = "selection-" + job.rawValue
                if job.isTree { tar = try await session.selectionForWholeExtraction() }
                else {
                    let page = try await session.page(in: session.root)
                    guard let file = page.items.first(where: { $0.name == job.entryName && $0.kind == .file }) else { throw Refusal.invalid }
                    tar = try await session.selectionForExtraction([file.id])
                }
                await session.close()
            } catch { await session.close(); throw error }
        }
        stage = "model-" + job.rawValue
        let model = ArchiveExtractionModel(source: source, browser: browser, engine: engine,
            tarMembers: tar, zipRoot: zip, destination: destination)
        model.name = job.outputName
        return model
    }
    private static func warmArchives(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, continuing: Bool = false, diagnosisOnly: Bool = false, repairing: Bool = false,
        stage: inout String) async throws {
        let browser = controller.browser
        stage = "awaitNativeOpen"
        try await wait(seconds: 20) { incoming.openedCount == 1 && browser.location.directoryURL != nil }
        guard let root = browser.location.directoryURL, let engine = browser.recoverableFileOperations else { throw Refusal.invalid }
        let access = await browser.accessLifetime(for: [root])
        defer { withExtendedLifetime(access) {} }
        try require(access.leases.count == 1 && sameFolder(access.leases[0].url, root)
            && browser.folderAccess.selectedRootCovering(root).map { sameFolder($0, root) } == true)
        for job in ArchiveJob.allCases { _ = try await archiveFixture(root, job: job, access: access) }
        var diagnosisAttemptName = "compressed-diagnostic-attempt.json"
        let continuationAttemptName = repairing ? "warm-public-source-repair-attempt.json" : "warm-continuation-attempt.json"
        if continuing {
            guard let earlier = try await store.read("warm-attempt.json"), earlier.fixtureID == root.lastPathComponent,
                  earlier.phase == "warmAttempt" else { throw Refusal.invalid }
            if repairing {
                try require(!diagnosisOnly)
                guard let earlierContinuation = try await store.read("warm-continuation-attempt.json"),
                      earlierContinuation.fixtureID == earlier.fixtureID, earlierContinuation.phase == "continuationAttempt",
                      let diagnostic = try await store.read("compressed-diagnostic2-attempt.json"),
                      diagnostic.fixtureID == earlier.fixtureID, diagnostic.phase == "compressedDiagnosticAttempt",
                      try await store.read(continuationAttemptName) == nil else { throw Refusal.invalid }
            } else if diagnosisOnly {
                guard let attempt = try await store.read("warm-continuation-attempt.json"),
                      attempt.fixtureID == earlier.fixtureID, attempt.phase == "continuationAttempt",
                      try await store.read("compressed-diagnostic.json") == nil else { throw Refusal.invalid }
                if let first = try await store.read(diagnosisAttemptName) {
                    try require(first.fixtureID == earlier.fixtureID && first.phase == "compressedDiagnosticAttempt")
                    diagnosisAttemptName = "compressed-diagnostic2-attempt.json"
                    try require(try await store.read(diagnosisAttemptName) == nil)
                }
            } else { try require(try await store.read("warm-continuation-attempt.json") == nil) }
            let history = try await engine.inspectExistingHistory()
            for job in ArchiveJob.allCases where !job.compressed {
                guard let receipt = try await store.read(job.rawValue + ".json"), receipt.fixtureID == earlier.fixtureID,
                      receipt.phase == "committed", let text = receipt.recordID, let id = UUID(uuidString: text), id.uuidString == text,
                      let sha = receipt.archiveSHA256, let expected = receipt.catalog else { throw Refusal.invalid }
                let observed = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                try require(observed == expected && observed.state == "committed" && observed.version == job.version
                    && observed.purpose == job.purpose && observed.requiresPublicQuarantine
                    && history.records.contains { $0.id == id && $0.state == "committed" && $0.canUndo })
                _ = try await archiveFixture(root, job: job, expected: sha, access: access)
                try await verifyArchiveOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(job.outputName),
                    job: job, root: root, access: access)
            }
            for job in ArchiveJob.allCases where job.compressed {
                try require(try await store.read(job.rawValue + ".json") == nil)
                let output = root.appendingPathComponent("source/Destination").appendingPathComponent(job.outputName)
                try await Task.detached { [access] in
                    defer { withExtendedLifetime(access) {} }; var facts = stat()
                    guard lstat(output.path, &facts) != 0, errno == ENOENT else { throw Refusal.invalid }
                }.value
            }
            try await store.write(diagnosisOnly ? diagnosisAttemptName : continuationAttemptName,
                archiveReceipt(diagnosisOnly ? "compressedDiagnosticAttempt"
                    : repairing ? "publicSourceRepairAttempt" : "continuationAttempt", root: root))
        } else { try await store.write("warm-attempt.json", archiveReceipt("warmAttempt", root: root)) }
        do {
            for job in ArchiveJob.allCases {
                if continuing && !job.compressed { continue }
                stage = "prepare-" + job.rawValue
                let sha = try await archiveFixture(root, job: job, access: access)
                let model = try await archiveModel(job, root: root, browser: browser, engine: engine, access: access, stage: &stage)
                do {
                    stage = "preview-" + job.rawValue
                    model.requestPreview()
                    try await wait(seconds: 20) { model.canExtract || !model.isPreparing && model.notice != "Checking the archive and destination…" }
                    if !model.canExtract, let error = model.previewFailureForQualification {
                        fputs("TRAVERSE_ARCHIVE_PREVIEW job=\(job.rawValue) domain=\(error.domain.rawValue) code=\(error.code)\n", stderr)
                    }
                    try require(model.canExtract)
                    // A reserved startup/grant completion visit may establish
                    // preparation readiness without creating another output or
                    // submitting a journal. It cannot retry the spent warm job.
                    if diagnosisOnly {
                        await model.closeAndDrain()
                        guard await ApplicationCompressedArchives.shared.closeAndDrain() else { throw Refusal.invalid }
                        try await store.write("compressed-diagnostic.json", archiveReceipt("compressedPreparationReady", root: root))
                        stage = "compressedPreparationReady"
                        return
                    }
                    stage = "extract-" + job.rawValue
                    model.extract()
                    guard model.isRunning, let work = browser.operationTask else { throw Refusal.invalid }
                    try await wait(seconds: 45) { browser.operationTask == nil || controller.window?.attachedSheet != nil }
                    try require(controller.window?.attachedSheet == nil)
                    await work.value
                    guard model.outcome?.result.disposition == .succeeded, let id = model.outcome?.recordID else { throw Refusal.invalid }
                    await model.closeAndDrain()
                    let output = root.appendingPathComponent("source/Destination").appendingPathComponent(job.outputName)
                    try await verifyArchiveOutput(output, job: job, root: root, access: access)
                    _ = try await archiveFixture(root, job: job, expected: sha, access: access)
                    let history = try await engine.inspectExistingHistory()
                    try require(history.records.contains { $0.id == id && $0.operation == job.operation && $0.state == "committed" && $0.canUndo })
                    let lead = try await engine.undoAccessRequirement(recordID: id)
                    try require(lead.map { sameFolder($0.directory, output.deletingLastPathComponent()) } == true)
                    let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                    try require(catalog.version == job.version && catalog.purpose == job.purpose
                        && catalog.state == "committed" && catalog.requiresPublicQuarantine)
                    let receipt = archiveReceipt("committed", root: root, record: id, sha: sha, catalog: catalog)
                    try await store.write(job.rawValue + ".json", receipt)
                    try await ReceiptStore(directory: root.appendingPathComponent("evidence"), format: store.format)
                        .write("warm-" + job.rawValue + ".json", receipt)
                    fputs("TRAVERSE_ARCHIVE_ACCESS phase=warm job=\(job.rawValue) result=committed pid=\(getpid())\n", stderr)
                } catch { await model.closeAndDrain(); throw error }
            }
            guard await ApplicationCompressedArchives.shared.closeAndDrain() else { throw Refusal.invalid }
            try await store.write("warm.json", archiveReceipt("archivesCommitted", root: root))
            stage = "archivesCommitted"
        } catch { _ = await ApplicationCompressedArchives.shared.closeAndDrain(); throw error }
    }
    private struct RecordedOutput: Sendable {
        let key: String, leaf: String, operation: String
        let id: UUID
        let receipt: Receipt
    }
    /// Shared real-access/relaunch inverse flow for independently recorded
    /// archive outputs and received selections. This grants no producer rights.
    private static func coldOutputs(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, root: URL, outputs: [RecordedOutput], label: String, stage: inout String,
        verify: @escaping @MainActor (RecordedOutput, FileAccessLifetimes) async throws -> Void) async throws {
        try require((1...16).contains(outputs.count) && Set(outputs.map(\.id)).count == outputs.count)
        let parent = root.appendingPathComponent("source/Destination", isDirectory: true)
        let browser = controller.browser
        try await wait(seconds: 20) { controller.workspace.sessionReady }
        try require(controller.workspace.sessionReady && controller.workspace.browsers.count == 1
            && controller.workspace.activeBrowser === browser)
        guard let engine = browser.recoverableFileOperations else { throw Refusal.invalid }
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        try require(incoming.openedCount == 0 && !browser.folderAccess.hasSelectedAccess(to: parent))
        try require(try await store.read("cold-attempt.json") == nil)
        let history = try await engine.inspectExistingHistory()
        for output in outputs {
            try require(history.records.contains { $0.id == output.id && $0.operation == output.operation
                && $0.state == "committed" && $0.canUndo })
        }
        try await store.write("cold-attempt.json", Receipt("coldAttempt", fixtureID: root.lastPathComponent, format: store.format))
        guard let first = history.records.first(where: { $0.id == outputs[0].id }),
              let lead = try await engine.undoAccessRequirement(recordID: first.id), sameFolder(lead.directory, parent) else { throw Refusal.invalid }
        var cancelled: RecoverableOperationResult?
        browser.startRecoveryOperation(first, rollback: false, presentsResult: false) { cancelled = $0 }
        stage = "nativeCancel"
        try await wait(seconds: 12) { browser.folderAccess.pendingUndoDirectoryForQualification != nil }
        try require(browser.folderAccess.pendingUndoDirectoryForQualification.map { sameFolder($0, parent) } == true
            && controller.window?.attachedSheet is NSOpenPanel)
        browser.folderAccess.invalidatePendingRequests()
        try await wait(seconds: 12) { cancelled != nil && browser.operationPreparationTask == nil }
        try require(cancelled?.result.items.first?.status == .cancelled && browser.operationTask == nil
            && browser.operationCoordinator.activeOwner == nil && browser.operationCoordinator.preparationOwner == nil)
        let afterCancel = try await engine.inspectExistingHistory()
        var cancelledCatalogs: [UUID: GeneratedPublicCatalogObservation] = [:]
        for output in outputs {
            let observed = try await engine.inspectGeneratedPublicCatalog(recordID: output.id)
            try require(afterCancel.records.contains { $0.id == output.id && $0.state == "committed" && $0.canUndo }
                && observed == output.receipt.catalog)
            cancelledCatalogs[output.id] = observed
        }
        try await store.write("cold-cancel.json", Receipt("nativePanelCancelled", fixtureID: root.lastPathComponent, format: store.format))
        stage = "awaitOSRegrant"
        fputs("\(label) phase=cold stage=awaitingOSRegrant pid=\(getpid())\n", stderr)
        try await wait(seconds: 45) { incoming.openedCount == 1 && browser.folderAccess.hasSelectedAccess(to: parent) }
        try require(browser.location.directoryURL.map { sameFolder($0, root) } == true)
        let access = await browser.accessLifetime(for: [parent])
        defer { withExtendedLifetime(access) {} }
        try require(access.leases.count == 1 && sameFolder(access.leases[0].url, root)
            && browser.folderAccess.selectedRootCovering(root).map { sameFolder($0, root) } == true)
        let exported = ReceiptStore(directory: root.appendingPathComponent("evidence"), format: store.format)
        for output in outputs {
            guard let cancelledCatalog = cancelledCatalogs[output.id] else { throw Refusal.invalid }
            try await exported.write("cancel-" + output.key + ".json", Receipt("nativePanelCancelled", fixtureID: root.lastPathComponent,
                recordID: output.id, format: store.format, catalog: cancelledCatalog))
            stage = "undo-" + output.key
            try await verify(output, access)
            let current = try await engine.inspectExistingHistory()
            guard let record = current.records.first(where: { $0.id == output.id }), record.canUndo, record.state == "committed",
                  let lead = try await engine.undoAccessRequirement(recordID: record.id), sameFolder(lead.directory, parent) else { throw Refusal.invalid }
            var undone: RecoverableOperationResult?
            browser.startRecoveryOperation(record, rollback: false, presentsResult: false) { undone = $0 }
            try await wait(seconds: 30) { undone != nil || controller.window?.attachedSheet != nil }
            try require(undone?.result.disposition == .succeeded && browser.operationTask == nil && controller.window?.attachedSheet == nil)
            try await Task.detached { [access] in
                defer { withExtendedLifetime(access) {} }
                var remaining = stat()
                guard lstat(parent.appendingPathComponent(output.leaf).path, &remaining) != 0,
                      errno == ENOENT else { throw Refusal.invalid }
            }.value
            let final = try await engine.inspectExistingHistory()
            try require(final.records.contains { $0.id == record.id && $0.state == "undone" && !$0.canUndo })
            let observed = try await engine.inspectGeneratedPublicCatalog(recordID: record.id)
            guard let earlier = output.receipt.catalog else { throw Refusal.invalid }
            try require(observed.version == earlier.version && observed.purpose == earlier.purpose
                && observed.requiresPublicQuarantine == earlier.requiresPublicQuarantine && observed.state == "undone")
            let receipt = Receipt("undone", fixtureID: root.lastPathComponent,
                recordID: record.id, archiveSHA256: output.receipt.archiveSHA256, format: store.format,
                inputSHA256: output.receipt.inputSHA256, catalog: observed, outputLeaf: output.receipt.outputLeaf)
            try await store.write("cold-" + output.key + ".json", receipt)
            try await exported.write("cold-" + output.key + ".json", receipt)
            fputs("\(label) phase=cold job=\(output.key) result=undone pid=\(getpid())\n", stderr)
        }
    }
    private static func coldArchives(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, warm: Receipt, stage: inout String) async throws {
        try require(warm.phase == "archivesCommitted")
        let root = try fixtureRoot(warm.fixtureID)
        var outputs: [RecordedOutput] = []
        for job in ArchiveJob.allCases {
            guard let receipt = try await store.read(job.rawValue + ".json"), receipt.fixtureID == warm.fixtureID,
                  receipt.phase == "committed", let idText = receipt.recordID, let id = UUID(uuidString: idText),
                  id.uuidString == idText, receipt.archiveSHA256 != nil else { throw Refusal.invalid }
            outputs.append(.init(key: job.rawValue, leaf: job.outputName, operation: job.operation, id: id, receipt: receipt))
        }
        try await coldOutputs(controller: controller, incoming: incoming, store: store, root: root,
            outputs: outputs, label: "TRAVERSE_ARCHIVE_ACCESS", stage: &stage) { output, access in
                guard let job = ArchiveJob(rawValue: output.key), let sha = output.receipt.archiveSHA256 else { throw Refusal.invalid }
                _ = try await archiveFixture(root, job: job, expected: sha, access: access)
                try await verifyArchiveOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(job.outputName),
                    job: job, root: root, access: access)
            }
        try await store.write("cold.json", archiveReceipt("archivesUndone", root: root))
    }

}

@MainActor extension OperationAccessRecoverySignedVerification {
    static func runArchives(controller: BrowserWindowController, incoming: IncomingFolderOpening) async {
        var stage = "admission", phase = "unknown"
        do {
            try require(GeneratedSandboxReview.archivePublicAccessAdmitted)
            guard let state = AppStorageLocations.stateDirectory else { throw Refusal.invalid }
            let store = ReceiptStore(directory: state.appendingPathComponent("archive-public-access-qa"), format: archiveReceiptFormat)
            if let warm = try await store.read("warm.json") {
                try require(!GeneratedSandboxReview.archivePublicContinuationAdmitted)
                phase = "cold"
                try await coldArchives(controller: controller, incoming: incoming, store: store, warm: warm, stage: &stage)
                stage = "archivesUndone"
            } else {
                let continuing = GeneratedSandboxReview.archivePublicContinuationAdmitted
                let repairing = GeneratedSandboxReview.archivePublicRepairedContinuationAdmitted
                let priorContinuation = try await store.read("warm-continuation-attempt.json")
                let diagnosisOnly = continuing && priorContinuation != nil && !repairing
                phase = diagnosisOnly ? "diagnostic" : "warm"
                if !continuing { try require(try await store.read("warm-attempt.json") == nil) }
                try await warmArchives(controller: controller, incoming: incoming, store: store,
                    continuing: continuing, diagnosisOnly: diagnosisOnly, repairing: repairing, stage: &stage)
            }
            fputs("TRAVERSE_ARCHIVE_ACCESS phase=\(phase) stage=\(stage) result=appChecksSatisfied pid=\(getpid())\n", stderr)
        } catch {
            let pending = cancelPublicationWork(controller)
            for work in pending { await work.value }
            if !publicationIdle(controller.browser) { stage = "drainUncertain" }
            // Fixed categories only: never emit a URL, body or free-form
            // Foundation description from the selected folder.
            let kind: String
            if let failure = error as? TARArchiveFailure { kind = "tar-" + failure.rawValue }
            else if let failure = error as? ZIPArchiveFailure {
                switch failure {
                case .malformed: kind = "zip-malformed"
                case .unsupported: kind = "zip-unsupported"
                case .unsafeName: kind = "zip-unsafeName"
                case .ambiguousNames: kind = "zip-ambiguousNames"
                case .unsupportedEncoding: kind = "zip-encoding"
                case .limited: kind = "zip-limited"
                case .unavailable: kind = "zip-unavailable"
                case .changed: kind = "zip-changed"
                case .stopped: kind = "zip-stopped"
                case .busy: kind = "zip-busy"
                case .closed: kind = "zip-closed"
                case .invalidFolder: kind = "zip-folder"
                case .invalidFilter: kind = "zip-filter"
                }
            }
            else if let failure = error as? StateDirectoryPreparationError {
                switch failure {
                case .invalidLocation: kind = "storage-location"
                case .unavailable: kind = "storage-unavailable"
                case .unsafeState: kind = "storage-unsafe"
                case .changed: kind = "storage-changed"
                case .busy: kind = "storage-busy"
                case .requiresBackgroundWorker: kind = "storage-worker"
                }
            } else if error is CancellationError { kind = "cancelled" }
            else { kind = "review-refusal" }
            fputs("TRAVERSE_ARCHIVE_ACCESS phase=\(phase) stage=\(stage) result=refused kind=\(kind) pid=\(getpid())\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }
}

/// Exact generated endpoint metadata. No saved server, credential store,
/// replacement connector or filesystem permission backend is used here.
@MainActor private extension OperationAccessRecoverySignedVerification {
    struct RemoteInput: Decodable, Sendable {
        let protocolName: String, host: String, port: Int, account: String
        let startPath: String
        let share: String?, fingerprint: String?
    }
    nonisolated static let primaryBody = Data("Traverse selected primary.\n".utf8)
    nonisolated static let secondBody = Data("Traverse selected second.\n".utf8)
    nonisolated static let folderBody = Data("Traverse folder child.\n".utf8)
    nonisolated static let remoteCodeSHA = "fe5ac89a4e3d903399c4b585b85bd9e458b1530144a25713cde88e037c53d6ae"
    private static func remoteInput(_ root: URL, isSMB: Bool, expected: String? = nil,
        access: FileAccessLifetimes) async throws -> (RemoteInput, String) {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            try require((try? fixtureRoot(root.lastPathComponent)).map { sameFolder($0, root) } == true
                && sameFolder(root.resolvingSymlinksInPath(), root))
            let marker = try JSONSerialization.jsonObject(with: readGeneratedRegular(root.appendingPathComponent("reservation.json"), maximum: 4096)) as? [String: String]
            let kind = isSMB ? "smb" : "sftp"
            guard marker?["packet"] == "traverse-development-v1",
                  marker?["action"] == "received-selection-completion-" + kind,
                  let claimed = marker?["connectionSHA256"], claimed.utf8.count == 64,
                  claimed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 }),
                  expected == nil || claimed == expected else { throw Refusal.invalid }
            let path = root.appendingPathComponent("source/Connection.json")
            var facts = stat()
            guard lstat(path.path, &facts) == 0, facts.st_mode & 0o7777 == 0o600 else { throw Refusal.invalid }
            let bytes = try readGeneratedRegular(path, maximum: 4096)
            guard digest(bytes) == claimed,
                  let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(fields.keys) == Set(["protocolName", "host", "port", "account", "startPath", isSMB ? "share" : "fingerprint"]) else {
                throw Refusal.invalid
            }
            let input = try JSONDecoder().decode(RemoteInput.self, from: bytes)
            guard input.protocolName == kind, input.host == "127.0.0.1", (1024...65535).contains(input.port),
                  (1...64).contains(input.account.utf8.count),
                  input.account.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 || $0 == 45 || $0 == 95 }),
                  isSMB ? input.share == "GroupFolderEncryptedQA" && input.startPath.isEmpty && input.fingerprint == nil
                    : input.share == nil && input.startPath == "/fixture" && input.fingerprint?.hasPrefix("SHA256:") == true && input.fingerprint?.utf8.count == 50 else { throw Refusal.invalid }
            return (input, claimed)
        }.value
    }
    private static func generatedSMBPassword() async throws -> String {
        try await Task.detached {
            // Only a directly spawned QA visit receives this private pipe.
            // Require its exact generated payload and EOF within five seconds.
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var bytes: [UInt8] = []
            while true {
                try Task.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw Refusal.invalid }
                var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&input, 1, Int32(max(1, min(5000, remaining * 1000))))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0, input.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw Refusal.invalid }
                var chunk = [UInt8](repeating: 0, count: 65 - bytes.count)
                let count = chunk.withUnsafeMutableBytes { raw in Darwin.read(STDIN_FILENO, raw.baseAddress!, raw.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Refusal.invalid }
                if count == 0 { break }
                bytes.append(contentsOf: chunk.prefix(count))
                guard bytes.count <= 64 else { throw Refusal.invalid }
            }
            guard bytes.count == 64, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 }),
                  let value = String(bytes: bytes, encoding: .utf8) else { throw Refusal.invalid }
            return value
        }.value
    }
    private static func connectGenerated(_ input: RemoteInput, browser: BrowserViewController,
        isSMB: Bool, stage: inout String) async throws {
        let service = ApplicationSMBConnections.shared
        stage = "connectForm"
        service.present(in: browser)
        try await wait(seconds: 20) { service.verificationWindow?.model.managing == false }
        guard let form = service.verificationWindow else { throw Refusal.invalid }
        let model = form.model
        model.connectionProtocol = isSMB ? .smb : .sftp
        model.address = isSMB ? "smb://127.0.0.1:\(input.port)/GroupFolderEncryptedQA" : "sftp://127.0.0.1:\(input.port)/fixture"
        model.account = input.account; model.name = "Generated received selection"
        model.rememberServer = false; model.rememberPassword = false
        model.transferBehavior = .readOnly
        if isSMB { model.password = try await generatedSMBPassword() }
        else { model.sftpAuthentication = .serverPrompts }
        try require(!model.rememberServer && !model.rememberPassword && !model.freshUploads && !model.reviewsUploads)
        stage = "connect"
        model.connect()
        if !isSMB {
            try await wait(seconds: 30) { service.verificationSFTPTrust != nil || !model.busy }
            guard let trust = service.verificationSFTPTrust else { throw Refusal.invalid }
            try require(trust.model.review.kind == .first && trust.model.review.fingerprint == input.fingerprint)
            trust.model.rememberKey = false; trust.model.proceed()
            stage = "generatedPrompt"
            try await wait(seconds: 30) { service.verificationSFTPInteractive != nil || !model.busy }
            guard let prompt = service.verificationSFTPInteractive, prompt.model.challenge.prompts.count == 1,
                  prompt.model.challenge.host == input.host, Int(prompt.model.challenge.port) == input.port,
                  prompt.model.challenge.prompts.allSatisfy({ !$0.echo }) else { throw Refusal.invalid }
            prompt.model.answers = ["123456"]; prompt.model.submit()
        }
        try await wait(seconds: 45) { !model.busy }
        try require(model.connected && !model.rememberingIncomplete)
    }
    private static func verifyRemoteOutput(_ output: URL, name: String, access: FileAccessLifetimes) async throws {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            let files: [URL: (Int, String)]
            if name == "Folder" {
                for directory in [output, output.appendingPathComponent("Empty")] {
                    var facts = stat()
                    guard lstat(directory.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                          facts.st_mode & 0o7777 == 0o755, facts.st_uid == geteuid(),
                          try directory.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else { throw Refusal.invalid }
                }
                try require(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == ["Child.txt", "Empty", "InertCode"]
                    && (try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Empty").path)).isEmpty)
                files = [output.appendingPathComponent("Child.txt"): (folderBody.count, digest(folderBody)),
                    output.appendingPathComponent("InertCode"): (16_880, remoteCodeSHA)]
            } else {
                guard name == "Primary.txt" || name == "Second.txt" else { throw Refusal.invalid }
                let body = name == "Primary.txt" ? primaryBody : secondBody
                files = [output: (body.count, digest(body))]
            }
            for (file, expected) in files {
                var facts = stat()
                guard lstat(file.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
                      facts.st_mode & 0o7777 == 0o644,
                      digest(try readGeneratedRegular(file, maximum: expected.0)) == expected.1,
                      try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else { throw Refusal.invalid }
            }
        }.value
    }
}

@MainActor private extension OperationAccessRecoverySignedVerification {
    private static func remoteReceipt(_ phase: String, root: URL, id: UUID? = nil, proof: String? = nil,
        store: ReceiptStore, catalog: GeneratedPublicCatalogObservation? = nil) -> Receipt {
        Receipt(phase, fixtureID: root.lastPathComponent, recordID: id, format: store.format, inputSHA256: proof, catalog: catalog)
    }
    private static func retainRemoteCommit(_ name: String, id: UUID, root: URL, proof: String,
        browser: BrowserViewController, engine: RecoverableFileOperations, store: ReceiptStore,
        access: FileAccessLifetimes) async throws {
        let output = root.appendingPathComponent("source/Destination").appendingPathComponent(name)
        try await verifyRemoteOutput(output, name: name, access: access)
        let expectedOperation = name == "Folder" ? "Download Folder" : "Download"
        let history = try await engine.inspectExistingHistory()
        try require(history.records.contains { $0.id == id && $0.operation == expectedOperation && $0.state == "committed" && $0.canUndo })
        let lead = try await engine.undoAccessRequirement(recordID: id)
        try require(lead.map { sameFolder($0.directory, output.deletingLastPathComponent()) } == true
            && browser.operationCoordinator.activeOwner == nil && browser.operationCoordinator.preparationOwner == nil)
        let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
        try require(catalog.version == (name == "Folder" ? 16 : 14)
            && catalog.purpose == (name == "Folder" ? "receivedFolder" : "receivedFile")
            && catalog.state == "committed" && catalog.requiresPublicQuarantine)
        let receipt = remoteReceipt("committed", root: root, id: id, proof: proof, store: store, catalog: catalog)
        try await store.write(name + ".json", receipt)
        try await ReceiptStore(directory: root.appendingPathComponent("evidence"), format: store.format)
            .write("warm-" + name + ".json", receipt)
    }
    private static func warmRemote(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, isSMB: Bool, stage: inout String) async throws -> Receipt {
        let browser = controller.browser, workspace = controller.workspace
        stage = "awaitNativeOpen"
        try await wait(seconds: 20) { incoming.openedCount == 1 && browser.location.directoryURL != nil }
        guard let root = browser.location.directoryURL, let engine = browser.recoverableFileOperations else { throw Refusal.invalid }
        let access = await browser.accessLifetime(for: [root])
        defer { withExtendedLifetime(access) {} }
        try require(access.leases.count == 1 && sameFolder(access.leases[0].url, root)
            && browser.folderAccess.selectedRootCovering(root).map { sameFolder($0, root) } == true)
        let (input, proof) = try await remoteInput(root, isSMB: isSMB, access: access)
        let parent = root.appendingPathComponent("source/Destination", isDirectory: true)
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            try require((try FileManager.default.contentsOfDirectory(atPath: parent.path)).isEmpty)
        }.value
        try await wait(seconds: 20) { workspace.sessionReady }
        controller.window?.setContentSize(.init(width: 1280, height: 760))
        try require(workspace.sessionReady && workspace.browsers.count == 1 && workspace.splitActive(at: .trailing))
        let peer = workspace.activeBrowser
        try require(peer !== browser && peer.folderAccess === browser.folderAccess && peer.recoverableFileOperations === engine)
        peer.navigate(to: .directory(parent))
        try await wait(seconds: 20) { !peer.isLoading && peer.folderAccess.hasSelectedAccess(to: parent) }
        try require(peer.location.directoryURL.map { sameFolder($0, parent) } == true)
        workspace.activate(browser)
        // One exclusive attempt per actually granted fixture, before any
        // connection/authentication. A repair uses a separately scoped root;
        // earlier attempts and records are never cleared or reused.
        try await store.write("warm-attempt.json", remoteReceipt("warmAttempt", root: root, proof: proof, store: store))
        try await connectGenerated(input, browser: browser, isSMB: isSMB, stage: &stage)
        stage = "listedSelection"
        let primary: Int, second: Int, folder: Int
        var sftp: SFTPTabController?, smb: SMBTabController?
        let table: NSTableView
        if isSMB {
            guard let owner = browser.smbTabs[browser.activeID] else { throw Refusal.invalid }; smb = owner
            try await wait(seconds: 30) { owner.rows.cache.snapshot?.state == .complete && owner.rows.cache.retainedCount == 3 && !owner.hasPendingPages }
            let rows = owner.rows.cache.loadedEntries
            guard Set(rows.map { $0.row.name.displayName }) == ["Primary.txt", "Second.txt", "Folder"],
                  let a = rows.first(where: { $0.row.name.displayName == "Primary.txt" }),
                  let b = rows.first(where: { $0.row.name.displayName == "Second.txt" }),
                  let c = rows.first(where: { $0.row.name.displayName == "Folder" }) else { throw Refusal.invalid }
            primary = Int(a.offset); second = Int(b.offset); folder = Int(c.offset); table = owner.rows.table
            try require(!owner.reviewsUploads && !owner.session.allowsSelectedUploads && !owner.session.allowsFolderUploads && owner.downloads != nil)
        } else {
            guard let owner = browser.sftpTabs[browser.activeID] else { throw Refusal.invalid }; sftp = owner
            try await wait(seconds: 30) { owner.rows.cache.snapshot?.state == .complete && owner.rows.cache.retainedCount == 3 && !owner.hasPendingPages }
            let rows = owner.rows.cache.loadedEntries
            guard Set(rows.map { $0.row.entry.name.displayName }) == ["Primary.txt", "Second.txt", "Folder"],
                  let a = rows.first(where: { $0.row.entry.name.displayName == "Primary.txt" }),
                  let b = rows.first(where: { $0.row.entry.name.displayName == "Second.txt" }),
                  let c = rows.first(where: { $0.row.entry.name.displayName == "Folder" }) else { throw Refusal.invalid }
            primary = Int(a.offset); second = Int(b.offset); folder = Int(c.offset); table = owner.rows.table
            try require(!owner.reviewsUploads && !owner.session.allowsFreshUploads && owner.downloads != nil)
        }
        let initialSpools: Set<UUID>
        if let smb, let storage = smb.downloads { initialSpools = Set(try await storage.inspect().map(\.id)) }
        else if let sftp, let storage = sftp.downloads { initialSpools = Set(try await storage.inspect().map(\.id)) }
        else { throw Refusal.invalid }
        controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet([primary, second]), byExtendingSelection: false)
        stage = "groupDownload"
        if let smb { try require(browser.remoteBatchDownload.canRequest(from: smb, toPane: true)); browser.remoteBatchDownload.request(from: smb, toPane: true) }
        else if let sftp { try require(browser.remoteBatchDownload.canRequest(from: sftp, toPane: true)); browser.remoteBatchDownload.request(from: sftp, toPane: true) }
        else { throw Refusal.invalid }
        guard let groupWork = browser.remoteBatchDownload.work else { throw Refusal.invalid }
        try await wait(seconds: 45) { browser.remoteBatchDownload.work == nil || controller.window?.attachedSheet != nil }
        try require(controller.window?.attachedSheet == nil)
        await groupWork.value
        guard let batch = browser.operationHistory.downloadBatch, batch.items.count == 2, batch.completed == 2,
              !batch.retainedStaging, !batch.stopped, browser.operationTask == nil,
              Set(batch.items.map { $0.destination.lastPathComponent }) == ["Primary.txt", "Second.txt"] else { throw Refusal.invalid }
        for item in batch.items {
            guard let id = item.outcome?.recordID, item.outcome?.result.disposition == .succeeded else { throw Refusal.invalid }
            try await retainRemoteCommit(item.destination.lastPathComponent, id: id, root: root, proof: proof,
                browser: browser, engine: engine, store: store, access: access)
        }
        stage = "folderDownload"
        table.selectRowIndexes(IndexSet(integer: folder), byExtendingSelection: false)
        controller.window?.makeFirstResponder(table)
        let folderWork: Task<Void, Never>
        if let smb {
            try require(browser.smbFolderDownload.canRequest(from: smb, toPane: true))
            browser.smbFolderDownload.request(from: smb, toPane: true)
            guard let task = browser.smbFolderDownload.qualificationWork else { throw Refusal.invalid }; folderWork = task
        } else if let sftp {
            try require(browser.sftpFolderDownload.canRequest(from: sftp, toPane: true))
            browser.sftpFolderDownload.request(from: sftp, toPane: true)
            guard let task = browser.sftpFolderDownload.qualificationWork else { throw Refusal.invalid }; folderWork = task
        } else { throw Refusal.invalid }
        // Normal connections must not require a second confirmation sheet.
        try await wait(seconds: 45) {
            (isSMB ? browser.smbFolderDownload.qualificationWork == nil : browser.sftpFolderDownload.qualificationWork == nil)
                || controller.window?.attachedSheet != nil
        }
        try require(controller.window?.attachedSheet == nil)
        await folderWork.value
        guard browser.lastOperationResult?.disposition == .succeeded, let id = browser.lastRecoveryRecordID,
              browser.operationTask == nil else { throw Refusal.invalid }
        try await retainRemoteCommit("Folder", id: id, root: root, proof: proof, browser: browser, engine: engine,
            store: store, access: access)
        if let smb, let storage = smb.downloads {
            let remaining = Set(try await storage.inspect().map(\.id))
            try require(smb.session.latest.failure == nil && remaining == initialSpools)
        }
        if let sftp, let storage = sftp.downloads {
            let remaining = Set(try await storage.inspect().map(\.id))
            try require(sftp.session.latest.failure == nil && remaining == initialSpools)
        }
        _ = try await remoteInput(root, isSMB: isSMB, expected: proof, access: access)
        return remoteReceipt("receivedCommitted", root: root, proof: proof, store: store)
    }
    private static func coldRemote(controller: BrowserWindowController, incoming: IncomingFolderOpening,
        store: ReceiptStore, warm: Receipt, isSMB: Bool, stage: inout String) async throws -> Receipt {
        guard warm.phase == "receivedCommitted", let proof = warm.inputSHA256 else { throw Refusal.invalid }
        let root = try fixtureRoot(warm.fixtureID)
        var outputs: [RecordedOutput] = []
        for name in ["Primary.txt", "Second.txt", "Folder"] {
            guard let receipt = try await store.read(name + ".json"), receipt.fixtureID == warm.fixtureID,
                  receipt.phase == "committed", receipt.inputSHA256 == proof,
                  let text = receipt.recordID, let id = UUID(uuidString: text), id.uuidString == text else { throw Refusal.invalid }
            outputs.append(.init(key: name, leaf: name, operation: name == "Folder" ? "Download Folder" : "Download", id: id, receipt: receipt))
        }
        let label = isSMB ? "TRAVERSE_SMB_SELECTION_DOWNLOAD" : "TRAVERSE_SFTP_SELECTION_DOWNLOAD"
        try await coldOutputs(controller: controller, incoming: incoming, store: store, root: root,
            outputs: outputs, label: label, stage: &stage) { output, access in
                _ = try await remoteInput(root, isSMB: isSMB, expected: proof, access: access)
                try await verifyRemoteOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(output.leaf),
                    name: output.leaf, access: access)
            }
        return remoteReceipt("receivedUndone", root: root, proof: proof, store: store)
    }
}
@MainActor private extension OperationAccessRecoverySignedVerification {
    private static func cancelPublicationWork(_ controller: BrowserWindowController) -> [Task<Void, Never>] {
        let browser = controller.browser
        browser.folderAccess.invalidatePendingRequests()
        let pending = [browser.operationPreparationTask, browser.operationTask, browser.remoteBatchDownload.work,
            browser.sftpFolderDownload.qualificationWork, browser.smbFolderDownload.qualificationWork].compactMap { $0 }
        browser.cancelFileOperation(nil); pending.forEach { $0.cancel() }
        if let review = controller.window?.attachedSheet?.windowController as? SFTPFolderDownloadPreview { review.finish(.cancel) }
        return pending
    }
    private static func publicationIdle(_ browser: BrowserViewController) -> Bool {
        browser.operationTask == nil && browser.operationPreparationTask == nil
            && browser.operationCoordinator.activeOwner == nil && browser.operationCoordinator.preparationOwner == nil
    }
    private static func drainGeneratedRemote(_ controller: BrowserWindowController, cancelling: Bool) async -> Bool {
        let browser = controller.browser
        let pending: [Task<Void, Never>]
        if cancelling { pending = cancelPublicationWork(controller) }
        else { guard publicationIdle(browser) else { return false }; pending = [] }
        let sftp = Array(browser.sftpTabs.values).map { $0.close() }
        let smb = Array(browser.smbTabs.values).map { $0.close() }
        await ApplicationSMBConnections.shared.closeAndDrain()
        for task in pending { await task.value }
        var drained = true
        for task in sftp {
            let result = await task.value
            drained = drained && result.localResourcesEnded && result.protocolValid && !result.contained
        }
        for task in smb {
            let result = await task.value
            drained = drained && result.actualExit && result.pipeDrained && result.socketAndCatalogDrained
                && result.ownerReleased && !result.forcedContainment && result.temporaryCatalogRemoved != false
        }
        return drained && publicationIdle(browser)
    }
}
@MainActor extension OperationAccessRecoverySignedVerification {
    static func runRemoteDownloads(controller: BrowserWindowController, incoming: IncomingFolderOpening, isSMB: Bool) async {
        var stage = "admission", phase = "unknown"
        let kind = isSMB ? "smb" : "sftp"
        let label = isSMB ? "TRAVERSE_SMB_SELECTION_DOWNLOAD" : "TRAVERSE_SFTP_SELECTION_DOWNLOAD"
        do {
            try require(isSMB ? GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted : GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted)
            guard let fixtureID = GeneratedSandboxReview.reviewFixtureID else { throw Refusal.invalid }
            let directory = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let store = ReceiptStore(directory: directory, format: "received-selection-" + kind + "-v1")
            if let warm = try await store.read("warm.json") {
                phase = "cold"
                _ = try fixtureRoot(fixtureID)
                try require(warm.fixtureID == fixtureID)
                let completed = try await coldRemote(controller: controller, incoming: incoming, store: store, warm: warm, isSMB: isSMB, stage: &stage)
                try require(await drainGeneratedRemote(controller, cancelling: false))
                try await store.write("cold.json", completed)
                stage = "receivedUndone"
            } else {
                phase = "warm"
                stage = "awaitNativeOpen"
                try await wait(seconds: 20) { incoming.openedCount == 1 && controller.browser.location.directoryURL != nil }
                guard let root = controller.browser.location.directoryURL,
                      root.lastPathComponent == fixtureID else { throw Refusal.invalid }
                _ = try fixtureRoot(root.lastPathComponent)
                try require(try await store.read("warm-attempt.json") == nil)
                let completed = try await warmRemote(controller: controller, incoming: incoming, store: store, isSMB: isSMB, stage: &stage)
                stage = "drain"
                try require(await drainGeneratedRemote(controller, cancelling: false))
                // Terminal completion and cold selection only become durable
                // after the actual ordinary connection owners have drained.
                try await store.write("warm.json", completed)
                stage = "receivedCommitted"
            }
            fputs("\(label) phase=\(phase) stage=\(stage) result=appChecksSatisfied pid=\(getpid())\n", stderr)
        } catch {
            let drained = await drainGeneratedRemote(controller, cancelling: true)
            if !drained { stage = "drainUncertain" }
            fputs("\(label) phase=\(phase) stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }
}
#endif

#if TRAVERSE_SFTP_EDITOR_QA
@MainActor extension OperationAccessRecoverySignedVerification {
    /// Ordinary inline archives, a private clipboard, the shared copy review
    /// and restart Undo. No ZIP writer or external promise is admitted here.
    static func runArchiveClipboard(controller: BrowserWindowController, incoming: IncomingFolderOpening) async {
        let browser = controller.browser, jobs = ArchiveJob.allCases.filter { !$0.isCode }
        let continuingPrefix = ProcessInfo.processInfo.arguments.contains("--qualify-archive-internal-continue-prefix-four")
        var phase = "warm", stage = "admission"
        do {
            guard GeneratedSandboxReview.archiveInternalAdmitted,
                  let root = GeneratedSandboxReview.reviewFixtureRoot else { throw Refusal.invalid }
            let directory = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let store = ReceiptStore(directory: directory, format: archiveReceiptFormat)
            let engine = browser.operationCoordinator.engine(at: directory.appendingPathComponent("history"))
            browser.recoverableFileOperations = engine
            browser.transferPasteboard = NSPasteboard.withUniqueName()
            if let warm = try await store.read("warm.json") {
                try require(!continuingPrefix)
                phase = "cold"
                try require(warm.phase == "clipboardCommitted" && warm.fixtureID == root.lastPathComponent)
                var outputs: [RecordedOutput] = []
                for job in jobs {
                    guard let receipt = try await store.read(job.rawValue + ".json"),
                          receipt.phase == "committed", receipt.fixtureID == root.lastPathComponent,
                          let text = receipt.recordID, let id = UUID(uuidString: text), id.uuidString == text else {
                        throw Refusal.invalid
                    }
                    outputs.append(.init(key: job.rawValue, leaf: try clipboardOutputLeaf(job, receipt: receipt),
                        operation: job.operation, id: id, receipt: receipt))
                }
                try await coldOutputs(controller: controller, incoming: incoming, store: store, root: root,
                    outputs: outputs, label: "TRAVERSE_ARCHIVE_INTERNAL", stage: &stage) { output, access in
                    guard let job = ArchiveJob(rawValue: output.key), let sha = output.receipt.archiveSHA256 else {
                        throw Refusal.invalid
                    }
                    _ = try await archiveFixture(root, job: job, expected: sha, access: access)
                    try await verifyArchiveOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(output.leaf),
                        job: job, root: root, access: access)
                }
                stage = "clipboardUndone"
            } else {
                let earlierAttempt = try await store.read("warm-attempt.json")
                if continuingPrefix {
                    let completionAttempt = try await store.read("warm-prefix-completion-attempt.json")
                    try require(earlierAttempt?.phase == "warmAttempt" && earlierAttempt?.fixtureID == root.lastPathComponent
                        && completionAttempt == nil)
                } else { try require(earlierAttempt == nil) }
                stage = "awaitNativeOpen"
                fputs("TRAVERSE_ARCHIVE_INTERNAL phase=warm stage=awaitNativeOpen result=ready pid=\(getpid())\n", stderr)
                try await wait(seconds: 45) { incoming.openedCount == 1 && browser.location.directoryURL.map { sameFolder($0, root) } == true }
                let access = await browser.accessLifetime(for: [root])
                defer { withExtendedLifetime(access) {} }
                try require(access.leases.count == 1 && sameFolder(access.leases[0].url, root))
                try await store.write(continuingPrefix ? "warm-prefix-completion-attempt.json" : "warm-attempt.json",
                    archiveReceipt("warmAttempt", root: root))
                var kept = Set<ArchiveJob>()
                if continuingPrefix {
                    stage = "validateCommittedPrefix"
                    let expected: [ArchiveJob] = [.zipTree, .zipFile, .tarTree, .tarFile]
                    var destinationNames = Set<String>()
                    var recoveryMarkers = Set<Data>()
                    for job in expected {
                        guard let receipt = try await store.read(job.rawValue + ".json"), receipt.phase == "committed",
                              receipt.fixtureID == root.lastPathComponent, receipt.outputLeaf == nil,
                              let text = receipt.recordID, let id = UUID(uuidString: text), id.uuidString == text,
                              let sourceSHA = receipt.archiveSHA256 else { throw Refusal.invalid }
                        let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                        try require(catalog == receipt.catalog && catalog.state == "committed" && catalog.version == job.version
                            && catalog.requiresPublicQuarantine && catalog.purpose == job.purpose)
                        _ = try await archiveFixture(root, job: job, expected: sourceSHA, access: access)
                        try await verifyArchiveOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(job.outputName),
                            job: job, root: root, access: access)
                        destinationNames.insert(job.outputName)
                        recoveryMarkers.insert(Data(("MacExplorer recovery v1\n" + id.uuidString
                            + "\nRetained until explicit cleanup.\n").utf8))
                        kept.insert(job)
                    }
                    for job in jobs where job.compressed { try require(try await store.read(job.rawValue + ".json") == nil) }
                    try await Task.detached { [access, destinationNames, recoveryMarkers] in
                        defer { withExtendedLifetime(access) {} }
                        let parent = root.appendingPathComponent("source/Destination")
                        let names = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path))
                        guard destinationNames.isSubset(of: names), names.count == destinationNames.count + recoveryMarkers.count else { throw Refusal.invalid }
                        var found = Set<Data>()
                        for name in names.subtracting(destinationNames) {
                            guard name.hasPrefix(".mac-explorer-recovery-"),
                                  UUID(uuidString: String(name.dropFirst(".mac-explorer-recovery-".count))) != nil else { throw Refusal.invalid }
                            let area = parent.appendingPathComponent(name)
                            var facts = stat()
                            guard lstat(area.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                                  facts.st_uid == geteuid(),
                                  Set(try FileManager.default.contentsOfDirectory(atPath: area.path)) == [".mac-explorer-recovery-v1"] else { throw Refusal.invalid }
                            let marker = try readGeneratedRegular(area.appendingPathComponent(".mac-explorer-recovery-v1"), maximum: 256)
                            guard recoveryMarkers.contains(marker), found.insert(marker).inserted else { throw Refusal.invalid }
                        }
                        guard found == recoveryMarkers else { throw Refusal.invalid }
                    }.value
                }
                let workspace = controller.workspace
                stage = "sourceReady"
                try await wait(seconds: 10) { workspace.sessionReady && !browser.isLoading && browser.orderingTask == nil }
                if let window = controller.window, window.frame.width < 1140 {
                    window.setContentSize(.init(width: 1140, height: window.contentLayoutRect.height))
                }
                try require(workspace.splitActive(at: .trailing))
                let target = workspace.activeBrowser
                target.recoverableFileOperations = engine
                target.navigate(to: .directory(root.appendingPathComponent("source/Destination")))
                stage = "destinationReady"
                try await wait(seconds: 10) { !target.isLoading && target.orderingTask == nil && target.canModifyCurrentFolder }
                for job in jobs {
                    if kept.contains(job) {
                        fputs("TRAVERSE_ARCHIVE_INTERNAL phase=warm job=\(job.rawValue) result=previouslyCommitted pid=\(getpid())\n", stderr)
                        continue
                    }
                    stage = "browse-" + job.rawValue
                    let sha = try await archiveFixture(root, job: job, access: access)
                    workspace.activate(browser)
                    browser.navigate(to: .archive(try ArchiveLocation(source: root.appendingPathComponent("source").appendingPathComponent(job.sourceName),
                        format: job.isZIP ? .zip : .tar)))
                    try await wait(seconds: 15) { browser.currentArchive.map { $0.current || $0.presentingPreparation } == true }
                    guard let archive = browser.currentArchive, let table = archive.table else { throw Refusal.invalid }
                    if job.compressed && archive.presentingPreparation {
                        guard let tar = archive.tarModelForVerification else { throw Refusal.invalid }
                        stage = "prepare-" + job.rawValue
                        try await wait(seconds: 15) { tar.canPrepareCompressed }
                        tar.prepareCompressed()
                        try await wait(seconds: 20) { archive.current && !archive.busy }
                    }
                    try require(archive.current && !archive.busy)
                    if let zip = archive.zipModelForVerification {
                        let selected = zip.visibleItems.filter { job.isTree || $0.name == job.entryName }
                        try require(selected.count == (job.isTree ? 3 : 1))
                        zip.selection = Set(selected.map(\.id))
                        try require(!zip.canCaptureClipboardMembers(.move))
                    } else if let tar = archive.tarModelForVerification {
                        let selected = tar.items.filter { job.isTree || $0.name == job.entryName }
                        try require(selected.count == (job.isTree ? 3 : 1))
                        tar.selection = Set(selected.map(\.id))
                    } else { throw Refusal.invalid }
                    stage = "copy-" + job.rawValue
                    controller.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    controller.window?.makeFirstResponder(table)
                    try await wait(seconds: 10) { browser.canCaptureArchiveClipboard(.copy) }
                    browser.copyFileURLs(nil)
                    try await wait(seconds: 10) { browser.clipboardState.scopedItem != nil && !archive.busy }
                    workspace.activate(target)
                    controller.window?.makeFirstResponder(target.table)
                    try await wait(seconds: 10) { target.canPasteScopedItem }
                    stage = "paste-" + job.rawValue
                    let direct = job == .compressedFile
                    browser.settings.alwaysReviewArchiveCopies = !direct
                    let earlierID = target.lastRecoveryRecordID
                    target.pasteFileURLs(nil)
                    let id: UUID
                    let outputName = direct ? leaf : job.outputName
                    if direct {
                        try await wait(seconds: 45) { ApplicationArchiveExtraction.shared.canAcceptPreparedSelection
                            && target.operationTask == nil && target.lastRecoveryRecordID != earlierID }
                        guard target.lastOperationResult?.disposition == .succeeded, let recorded = target.lastRecoveryRecordID else { throw Refusal.invalid }
                        id = recorded
                    } else {
                        try await wait(seconds: 15) { ApplicationArchiveExtraction.shared.controller != nil }
                        guard let review = ApplicationArchiveExtraction.shared.controller else { throw Refusal.invalid }
                        let model = review.model
                        model.name = outputName
                        try await wait(seconds: 20) { model.canExtract }
                        try require(sameFolder(model.parent, root.appendingPathComponent("source/Destination")))
                        model.extract()
                        try await wait(seconds: 45) { !model.isRunning && model.outcome != nil && target.operationTask == nil }
                        guard model.outcome?.result.disposition == .succeeded, let recorded = model.outcome?.recordID else { throw Refusal.invalid }
                        id = recorded
                    }
                    await ApplicationArchiveExtraction.shared.closeAndDrain()
                    try await verifyArchiveOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(outputName),
                        job: job, root: root, access: access)
                    let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: id)
                    try require(catalog.version == job.version && catalog.purpose == job.purpose
                        && catalog.state == "committed" && catalog.requiresPublicQuarantine)
                    let receipt = archiveReceipt("committed", root: root, record: id, sha: sha, catalog: catalog,
                        outputLeaf: direct ? outputName : nil)
                    try await store.write(job.rawValue + ".json", receipt)
                    try await ReceiptStore(directory: root.appendingPathComponent("evidence"), format: store.format)
                        .write("warm-" + job.rawValue + ".json", receipt)
                    browser.clipboardState.clear()
                    fputs("TRAVERSE_ARCHIVE_INTERNAL phase=warm job=\(job.rawValue) result=committed pid=\(getpid())\n", stderr)
                }
                stage = "clipboardCommitted"
            }
            let finished = stage
            stage = "drain"
            try await drainPromiseReview(controller)
            guard await ApplicationCompressedArchives.shared.closeAndDrain() else { throw Refusal.invalid }
            try await store.write(phase == "warm" ? "warm.json" : "cold.json", archiveReceipt(finished, root: root))
            stage = finished
            fputs("TRAVERSE_ARCHIVE_INTERNAL phase=\(phase) stage=\(stage) result=appChecksSatisfied pid=\(getpid())\n", stderr)
        } catch {
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            try? await drainPromiseReview(controller)
            _ = await ApplicationCompressedArchives.shared.closeAndDrain()
            fputs("TRAVERSE_ARCHIVE_INTERNAL phase=\(phase) stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        NSApp.terminate(nil)
    }

    /// Uses ordinary archive rows and real receiver callbacks. Only Source is
    /// opened initially; the destination must be chosen after the first drop.
    static func runArchivePromises(controller: BrowserWindowController, incoming: IncomingFolderOpening) async {
        let browser = controller.browser
        var phase = "warm", stage = "admission"
        do {
            guard GeneratedSandboxReview.archivePromiseAdmitted,
                  let root = GeneratedSandboxReview.reviewFixtureRoot else { throw Refusal.invalid }
            let directory = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let store = ReceiptStore(directory: directory, format: "archive-promise-receiver-v1")
            let engine = browser.operationCoordinator.engine(at: store.directory.appendingPathComponent("history"))
            browser.recoverableFileOperations = engine
            let warm = try await store.read("warm.json")
            let attempt = try await store.read("warm-attempt.json")
            let file = try await store.read("file.json"), folder = try await store.read("folder.json")
            if warm != nil || (attempt != nil && file != nil && folder != nil) {
                phase = "cold"
                if let warm {
                    try require(warm.fixtureID == root.lastPathComponent && warm.phase == "promisesCommitted")
                } else {
                    // Publication receipts precede the final review checkpoint.
                    // A teardown-check failure must not repeat either drag or
                    // manufacture a passing warm result. Validate both real
                    // committed records, then use ordinary cold access/Undo.
                    try require(attempt?.fixtureID == root.lastPathComponent && attempt?.phase == "warmAttempt")
                    fputs("TRAVERSE_ARCHIVE_PROMISE phase=cold stage=retainedPublications result=ready pid=\(getpid())\n", stderr)
                }
                var outputs: [RecordedOutput] = []
                for key in ["file", "folder"] {
                    guard let receipt = try await store.read(key + ".json"), receipt.fixtureID == root.lastPathComponent,
                          let text = receipt.recordID, let id = UUID(uuidString: text), id.uuidString == text,
                          receipt.phase == "committed", receipt.catalog?.state == "committed",
                          receipt.catalog?.version == (key == "file" ? 15 : 16), receipt.catalog?.requiresPublicQuarantine == true else { throw Refusal.invalid }
                    outputs.append(.init(key: key, leaf: promiseLeaf(key), operation: "Extract ZIP", id: id, receipt: receipt))
                }
                try await coldOutputs(controller: controller, incoming: incoming, store: store, root: root,
                    outputs: outputs, label: "TRAVERSE_ARCHIVE_PROMISE", stage: &stage) { output, access in
                    try await verifyPromiseOutput(root.appendingPathComponent("source/Destination").appendingPathComponent(output.leaf),
                        folder: output.key == "folder", access: access)
                }
                stage = "promisesUndone"
            } else {
                stage = "newWarmAdmission"
                try require(attempt == nil && file == nil && folder == nil)
                stage = "awaitSourceOpen"
                fputs("TRAVERSE_ARCHIVE_PROMISE phase=warm stage=awaitSourceOpen result=ready pid=\(getpid())\n", stderr)
                let source = root.appendingPathComponent("source/Source", isDirectory: true)
                try await wait(seconds: 45) { incoming.openedCount == 1 && browser.location.directoryURL.map { sameFolder($0, source) } == true }
                let access = await browser.accessLifetime(for: [source])
                defer { withExtendedLifetime(access) {} }
                try require(access.leases.count == 1 && sameFolder(access.leases[0].url, source)
                    && !browser.folderAccess.hasSelectedAccess(to: root.appendingPathComponent("source/Destination")))
                try require(try await store.read("warm-attempt.json") == nil)
                let archive = source.appendingPathComponent("Generated.zip")
                let sha = try await preparePromiseSource(source, fixtureID: root.lastPathComponent, access: access)
                try await store.write("warm-attempt.json", Receipt("warmAttempt", fixtureID: root.lastPathComponent, format: store.format))
                ApplicationZIPBrowser.shared.show(archive, from: browser)
                guard let shown = ApplicationZIPBrowser.shared.controller, let window = shown.window else { throw Refusal.invalid }
                let model = shown.model
                try await wait(seconds: 20) { !model.isLoading && !model.isPaging && model.viewIsCurrent }
                try require(Set(model.visibleItems.map(\.name)) == ["Generated Promise.txt", "Generated Folder"])
                window.title = "Generated signed ZIP drag · " + root.lastPathComponent.prefix(8)
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                for key in ["file", "folder"] {
                    guard let item = model.visibleItems.first(where: { $0.name == promiseLeaf(key) }) else { throw Refusal.invalid }
                    let previous = model.lastHandedExportForVerification?.id
                    model.selection = [item.id]
                    try await wait(seconds: 20) { model.externalExportReady && model.rowsForVerification?.selectedIDs == [item.id] }
                    stage = key + "Ready"
                    fputs("TRAVERSE_ARCHIVE_PROMISE phase=warm stage=\(stage) result=ready pid=\(getpid())\n", stderr)
                    try await wait(seconds: 600) {
                        guard let export = model.lastHandedExportForVerification, export.id != previous else { return false }
                        // An offered but unrequested promise is idle too. Wait
                        // for actual publication or terminal refusal, never
                        // mistake mouse-down admission for a completed drop.
                        return (export.completedForVerification > 0 || export.terminalForVerification) && export.drainedForVerification
                    }
                    guard let export = model.lastHandedExportForVerification,
                          export.completedForVerification == 1, export.outcomesForVerification.count == 1,
                          export.parentChoicesForVerification == (key == "file" ? 1 : 0),
                          let result = export.outcomesForVerification.first, result.result.disposition == .succeeded,
                          let record = result.recordID else { throw Refusal.invalid }
                    stage = "verify-" + key
                    let parent = root.appendingPathComponent("source/Destination", isDirectory: true)
                    let destinationAccess = await browser.accessLifetime(for: [parent])
                    try require(destinationAccess.leases.count == 1 && sameFolder(destinationAccess.leases[0].url, parent))
                    try await verifyPromiseOutput(parent.appendingPathComponent(promiseLeaf(key)), folder: key == "folder", access: destinationAccess)
                    let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: record)
                    try require(catalog.version == (key == "file" ? 15 : 16) && catalog.requiresPublicQuarantine && catalog.state == "committed")
                    let receipt = Receipt("committed", fixtureID: root.lastPathComponent, recordID: record,
                        archiveSHA256: sha, format: store.format, catalog: catalog)
                    try await store.write(key + ".json", receipt)
                    fputs("TRAVERSE_ARCHIVE_PROMISE phase=warm stage=\(key)Committed result=ready pid=\(getpid())\n", stderr)
                    withExtendedLifetime(destinationAccess) {}
                }
                stage = "promisesCommitted"
            }
            let finished = stage
            stage = "drain"
            try await drainPromiseReview(controller)
            try await store.write(phase == "warm" ? "warm.json" : "cold.json",
                Receipt(finished, fixtureID: root.lastPathComponent, format: store.format))
            stage = finished
            fputs("TRAVERSE_ARCHIVE_PROMISE phase=\(phase) stage=\(stage) result=appChecksSatisfied pid=\(getpid())\n", stderr)
        } catch {
            try? await drainPromiseReview(controller)
            fputs("TRAVERSE_ARCHIVE_PROMISE phase=\(phase) stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        NSApp.terminate(nil)
    }

    private static func drainPromiseReview(_ controller: BrowserWindowController) async throws {
        await ApplicationArchiveExports.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        let browsers = Array(controller.workspace.browsers.values)
        let observations = browsers.compactMap(\.directoryObservation)
        controller.suspendBrowsing()
        for browser in browsers { await browser.listingTask?.value; await browser.recoveryInspectionTask?.value }
        for observation in observations { await observation.waitUntilStopped() }
        await ArchiveTabCatalogPool.shared.closeAndDrain()
        await controller.flushSession()
        try await wait(seconds: 5) {
            ApplicationFileActivity.gate.activeCount == 0 && ApplicationArchiveExports.shared.countForVerification == 0
        }
    }

    private static func promiseLeaf(_ key: String) -> String { key == "file" ? "Generated Promise.txt" : "Generated Folder" }
    private static func preparePromiseSource(_ source: URL, fixtureID: String, access: FileAccessLifetimes) async throws -> String {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            let input = try JSONDecoder().decode([String: String].self,
                from: readGeneratedRegular(source.appendingPathComponent("Fixture.json"), maximum: 2048))
            guard Set(input.keys) == ["format", "fixtureID", "archiveSHA256", "action", "master"],
                  input["format"] == "archive-promise-generated-v1", input["fixtureID"] == fixtureID,
                  input["action"] == "signed-archive-promise-receiver",
                  input["master"] == "887B77DA-8583-42B1-9055-32B91A60641F",
                  let expected = input["archiveSHA256"], expected.utf8.count == 64 else { throw Refusal.invalid }
            var archive = source.appendingPathComponent("Generated.zip")
            guard digest(try readGeneratedRegular(archive, maximum: 65536)) == expected else { throw Refusal.invalid }
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Traverse generated fixture",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                kLSQuarantineTimeStampKey as String: Date()]
            try archive.setResourceValues(values)
            guard try archive.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false,
                  digest(try readGeneratedRegular(archive, maximum: 65536)) == expected else { throw Refusal.invalid }
            return expected
        }.value
    }
    private static func verifyPromiseOutput(_ output: URL, folder: Bool, access: FileAccessLifetimes) async throws {
        try await Task.detached { [access] in
            defer { withExtendedLifetime(access) {} }
            let bodies = folder ? ["Report.txt": "Generated folder report.\n", "Deep/More.txt": "Generated nested report.\n"]
                : ["": "Generated file promise.\n"]
            let directories = folder ? ["", "Deep", "Empty"] : []
            // The independent receiver owner checks the complete literal tree,
            // including the empty folder. Here read only the fixed known nodes.
            for child in directories {
                let directory = child.isEmpty ? output : output.appendingPathComponent(child)
                var facts = stat()
                guard lstat(directory.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                      facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o755,
                      try directory.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else { throw Refusal.invalid }
            }
            for (child, text) in bodies {
                let file = child.isEmpty ? output : output.appendingPathComponent(child)
                var facts = stat()
                guard lstat(file.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
                      facts.st_uid == geteuid(), facts.st_mode & 0o7777 == 0o644,
                      try readGeneratedRegular(file, maximum: 1024) == Data(text.utf8),
                      try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?.isEmpty == false else { throw Refusal.invalid }
            }
        }.value
    }
}

@MainActor extension OperationAccessRecoverySignedVerification {
    nonisolated private static let retirementFormat = "retained-editor-v5-qa-v1"
    nonisolated private static let retirementOriginal = Data("Generated retirement original\n".utf8)
    nonisolated private static let retirementEdited = Data("Generated retirement saved\n".utf8)

    /// One fixture-bound API journey through the ordinary editor file session.
    /// The physical Saved Versions button remains a separate UI qualification.
    static func runRetainedEditorRetirement(controller: BrowserWindowController) async {
        var phase = "admission", stage = "scope"
        do {
            guard GeneratedSandboxReview.retainedEditorRetirementV5Admitted,
                  let fixture = GeneratedSandboxReview.reviewFixtureID,
                  let engine = controller.browser.recoverableFileOperations else { throw Refusal.invalid }
            let file = try await retirementDocument(fixture)
            let directory = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let store = ReceiptStore(directory: directory, format: retirementFormat)
            let warm = try await store.read("warm.json")
            let attempt = try await store.read("warm-attempt.json")
            if let warm {
                phase = "cold"; stage = "coldAdmission"
                let cold = try await store.read("cold.json")
                try require(attempt?.phase == "warmAttempt" && attempt?.fixtureID == fixture
                    && warm.phase == "warmCommitted" && warm.fixtureID == fixture
                    && cold == nil)
                try await retirementCold(engine: engine, file: file, fixture: fixture, store: store, warm: warm)
                stage = "coldVerified"
            } else {
                phase = "warm"; stage = "warmAdmission"
                try require(attempt == nil)
                try await store.write("warm-attempt.json", Receipt("warmAttempt", fixtureID: fixture,
                    format: retirementFormat))
                stage = "warmAttempt"
                try await retirementWarm(controller: controller, engine: engine, file: file,
                    fixture: fixture, store: store, stage: &stage)
                stage = "warmCommitted"
            }
            fputs("TRAVERSE_EDITOR_RETIREMENT_V5 phase=\(phase) stage=\(stage) result=appChecksSatisfied pid=\(getpid())\n", stderr)
        } catch {
            // A partial warm attempt never becomes an automatic second Trash call.
            fputs("TRAVERSE_EDITOR_RETIREMENT_V5 phase=\(phase) stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }

    /// Inspect the one spent warm attempt under a distinct launch selector.
    /// This does not retry the warm route or synthesize its missing receipt.
    static func runRetainedEditorReadOnly(controller: BrowserWindowController) async {
        var stage = "scope"
        do {
            guard GeneratedSandboxReview.retainedEditorReadOnlyAdmitted,
                  let fixture = GeneratedSandboxReview.reviewFixtureID,
                  let engine = controller.browser.recoverableFileOperations else { throw Refusal.invalid }
            let directory = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let store = ReceiptStore(directory: directory, format: retirementFormat)
            stage = "receiptAdmission"
            let attempt = try await store.read("warm-attempt.json")
            let warm = try await store.read("warm.json")
            let cold = try await store.read("cold.json")
            let previous = try await store.read("read-only.json")
            try require(attempt?.phase == "warmAttempt" && attempt?.fixtureID == fixture
                && attempt?.recordID == nil && warm == nil && cold == nil && previous == nil)

            stage = "documentAdmission"
            let file = try await retirementDocument(fixture)
            try await verifyRetirementDocument(file)
            let session = LocalEditorFileSession(engine: engine)
            defer { try? session.closeAfterDrain() }
            let opened = try await session.open(file)
            try require(opened.url == file && opened.contents.encoded == retirementEdited)
            let page = try await session.revisions()
            guard page.records.count == 1, page.nextRecordID == nil,
                  let summary = page.records.first, summary.targetURL == file else { throw Refusal.invalid }
            stage = "selectedInspect"
            let inspection = try await session.inspectRevision(summary.recordID)
            try require(inspection.recordID == summary.recordID && inspection.targetURL == file
                && inspection.state == summary.state && inspection.retention == summary.retention
                && inspection.undoDisposition == summary.undoDisposition
                && !session.isWorking && engine.isIdleForCopyPreview)
            let rebound = try await retirementDocument(fixture)
            try require(rebound == file)
            try await verifyRetirementDocument(file)
            stage = "receiptWrite"
            try await store.write("read-only.json", Receipt("readOnlyInspected", fixtureID: fixture,
                recordID: summary.recordID, format: retirementFormat))
            stage = "readOnlyInspected"
            let undoEnded = inspection.undoDisposition == .endedByRetirement
            fputs("TRAVERSE_EDITOR_RETIREMENT_V5 phase=readOnly stage=\(stage) result=inspected state=\(inspection.state.rawValue) retention=\(inspection.retention.rawValue) metadataIsDurable=\(inspection.metadataIsDurable) canUndo=\(inspection.canUndo) undoEnded=\(undoEnded) documentUnchanged=true pid=\(getpid())\n", stderr)
        } catch {
            fputs("TRAVERSE_EDITOR_RETIREMENT_V5 phase=readOnly stage=\(stage) result=refused pid=\(getpid())\n", stderr)
        }
        NSApplication.shared.terminate(nil)
    }

    private static func retirementDocument(_ fixture: String) async throws -> URL {
        guard UUID(uuidString: fixture)?.uuidString == fixture else { throw Refusal.invalid }
        return try await Task.detached {
            guard let data = GeneratedSandboxReview.retainedEditorBoundDataRoot else { throw Refusal.invalid }
            let documents = data.appendingPathComponent("Documents", isDirectory: true)
            guard FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL.path
                    == documents.standardizedFileURL.path else { throw Refusal.invalid }
            return documents.appendingPathComponent(fixture, isDirectory: true)
                .appendingPathComponent("Generated Retirement.txt")
        }.value
    }

    private static func prepareRetirementDocument(_ file: URL) async throws {
        try await Task.detached {
            let documents = file.deletingLastPathComponent().deletingLastPathComponent()
            if mkdir(documents.path, 0o700) != 0 && errno != EEXIST { throw Refusal.invalid }
            var facts = stat()
            guard lstat(documents.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                  facts.st_uid == geteuid(), facts.st_mode & 0o022 == 0 else { throw Refusal.invalid }
            let root = file.deletingLastPathComponent()
            guard mkdir(root.path, 0o700) == 0 else { throw Refusal.invalid }
            guard lstat(root.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                  facts.st_uid == geteuid(), facts.st_mode & 0o077 == 0 else { throw Refusal.invalid }
            try retirementOriginal.write(to: file, options: .withoutOverwriting)
            guard chmod(file.path, 0o600) == 0,
                  try readGeneratedRegular(file, maximum: 1024) == retirementOriginal else { throw Refusal.invalid }
        }.value
    }

    private static func verifyRetirementDocument(_ file: URL) async throws {
        try await Task.detached {
            let root = file.deletingLastPathComponent()
            var facts = stat(), parent = stat()
            guard lstat(root.deletingLastPathComponent().path, &parent) == 0,
                  parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(),
                  parent.st_mode & 0o022 == 0,
                  lstat(root.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
                  facts.st_uid == geteuid(), facts.st_mode & 0o077 == 0,
                  try readGeneratedRegular(file, maximum: 1024) == retirementEdited else { throw Refusal.invalid }
        }.value
    }

    /// The prospective one-call scope is at most 16 generated entries/64 KiB.
    /// The engine independently revalidates the complete tree at mutation time.
    private static func requireTinyRetainedDirectory(_ root: URL) async throws {
        try await Task.detached {
            var pending = [root], entries = 0, bytes: Int64 = 0
            while let item = pending.popLast() {
                var facts = stat()
                guard lstat(item.path, &facts) == 0, facts.st_uid == geteuid() else { throw Refusal.invalid }
                entries += 1
                guard entries <= 16 else { throw Refusal.invalid }
                switch facts.st_mode & S_IFMT {
                case S_IFDIR:
                    let children = try FileManager.default.contentsOfDirectory(at: item,
                        includingPropertiesForKeys: nil, options: [])
                    guard children.count <= 16 - entries else { throw Refusal.invalid }
                    pending.append(contentsOf: children)
                case S_IFREG:
                    guard facts.st_nlink == 1, facts.st_size >= 0,
                          facts.st_size <= 65_536 - bytes else { throw Refusal.invalid }
                    bytes += facts.st_size
                default: throw Refusal.invalid
                }
            }
        }.value
    }

    private static func retirementWarm(controller: BrowserWindowController, engine: RecoverableFileOperations,
        file: URL, fixture: String, store: ReceiptStore, stage: inout String) async throws {
        try await prepareRetirementDocument(file)
        stage = "generatedDocument"
        let session = LocalEditorFileSession(engine: engine)
        defer { try? session.closeAfterDrain() }
        let opened = try await session.open(file)
        try require(opened.contents.encoded == retirementOriginal)
        let visible = TextDocumentState(value: opened.contents, binding: opened.binding)
        let edit = try visible.beginEdit()
        try visible.acceptEdit(edit, value: TextDocumentValue.original(retirementEdited))
        guard let snapshot = try visible.beginSave() else { throw Refusal.invalid }
        let coordinator = controller.browser.operationCoordinator
        try await coordinator.prepareOperationState(for: engine)
        stage = "savePrepared"
        let saved: (UUID, TextDocumentBinding)
        do {
            let owner = UUID()
            guard coordinator.begin(owner: owner) else { throw Refusal.invalid }
            defer { coordinator.finish(owner: owner) }
            guard case .confirmed(let generation, let binding, let target, let recordID, let baselineAdopted)
                    = await session.saveOriginal(snapshot),
                  generation == snapshot.id, target == file, let recordID, !baselineAdopted else { throw Refusal.invalid }
            saved = (recordID, binding)
        }
        try visible.finishSave(snapshot, result: .confirmed(saved.1))
        stage = "saved"
        try await verifyRetirementDocument(file)
        let before = try await session.inspectRevision(saved.0)
        try require(before.state == .committed && before.retention == .retained
            && before.metadataIsDurable && before.canUndo
            && before.recoveryLocation.deletingLastPathComponent().standardizedFileURL.path
                == file.deletingLastPathComponent().standardizedFileURL.path)
        let retired: LocalTextRetirementResult
        do {
            let owner = UUID()
            guard coordinator.begin(owner: owner) else { throw Refusal.invalid }
            defer { coordinator.finish(owner: owner) }
            let plan = try await session.prepareRetirement(saved.0)
            try require(plan.review.canCleanup && plan.review.areas.count == 1
                && plan.review.areas[0].url == before.recoveryLocation)
            try await requireTinyRetainedDirectory(before.recoveryLocation)
            let rebound = try await retirementDocument(fixture)
            try require(rebound == file)
            stage = "nativeDispatch"
            retired = try await session.retire(plan)
        }
        stage = "nativeReturned"
        // macOS may return a raw URL without a directory hint. The engine
        // preserves both that observation and its confirmed directory URL.
        try require(retired.recordID == saved.0 && retired.status == .succeeded
            && retired.retention == .retired && retired.undoEnded == true
            && retired.knownLocations.count >= 2
            && retired.knownLocations[0] == before.recoveryLocation
            && retired.unconfirmedReportedLocations.isEmpty)
        let after = try await session.inspectRevision(saved.0)
        try require(retirementConfirmed(after, recordID: saved.0, file: file)
            && !session.isWorking && engine.isIdleForCopyPreview && coordinator.activeOwner == nil)
        try await verifyRetirementDocument(file)
        stage = "warmReceipt"
        try await store.write("warm.json", Receipt("warmCommitted", fixtureID: fixture,
            recordID: saved.0, format: retirementFormat))
    }

    private static func retirementCold(engine: RecoverableFileOperations, file: URL,
        fixture: String, store: ReceiptStore, warm: Receipt) async throws {
        guard let raw = warm.recordID, let recordID = UUID(uuidString: raw),
              recordID.uuidString == raw else { throw Refusal.invalid }
        let rebound = try await retirementDocument(fixture)
        try require(rebound == file)
        let session = LocalEditorFileSession(engine: engine, selectedHistoricalRecordID: recordID)
        defer { try? session.closeAfterDrain() }
        let inspection = try await session.inspectRevision(recordID)
        try require(retirementConfirmed(inspection, recordID: recordID, file: file)
            && !session.isWorking && engine.isIdleForCopyPreview)
        try await verifyRetirementDocument(file)
        try await store.write("cold.json", Receipt("coldVerified", fixtureID: fixture,
            recordID: recordID, format: retirementFormat))
    }

    private static func retirementConfirmed(_ value: LocalTextRevisionInspection,
        recordID: UUID, file: URL) -> Bool {
        value.recordID == recordID && value.targetURL == file && value.state == .committed
            && value.retention == .retired && value.metadataIsDurable && !value.canUndo
            && value.undoDisposition == .endedByRetirement
    }
}
#endif

#if TRAVERSE_ARCHIVE_DRIVE_QA && !TRAVERSE_SFTP_EDITOR_QA && !DEBUG
import AppKit
import CoreServices
import CryptoKit
import FileOperations
import LocalStorage

/// The authored phase of the existing signed access/recovery checks. It drives
/// the real creation review, native editor and browser recovery command. There
/// is no alternate writer or executable command supplied by fixture data.
@MainActor enum OperationAccessRecoverySignedVerification {
    private enum Refusal: Error { case check(String) }
    private struct Observation: Codable, Equatable, Sendable {
        let sha256: String
        let bytes: Int
        let publiclyMarked: Bool
        let device: Int64
        let inode: UInt64
        let mode: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }
    private struct Member: Codable, Equatable, Sendable {
        let kind: String
        let bytes: Int
        let sha256: String?
    }
    private struct Step: Codable, Sendable {
        let recordID: UUID
        let kind: String
        let format: String
        let output: String
        let before: Observation?
        let after: Observation
        let membersBefore: [String: Member]?
        let membersAfter: [String: Member]?
    }
    private struct Receipt: Codable, Sendable {
        let phase: String
        let pid: Int32
        let inputs: [String: Observation]
        let steps: [Step]
    }
    private struct Outcome: Codable, Sendable {
        let passed: Bool
        let phase: String
        let stage: String
        let refusal: String?
        let pid: Int32
    }
    private struct DriveReceipt: Codable, Sendable {
        let jobID: UUID
        let phase: String
        let unresolved: Bool
        let beforeSHA256: String
        let afterSHA256: String
        let nativeMutationHeld: Bool
    }
    nonisolated private static let expectedInputs = [
        "Source/Notes.txt": Data("before\n".utf8),
        "Source/Nested/Config.json": Data("{\"generated\":true}\n".utf8)
    ]
    private static func require(_ value: Bool, _ code: String) throws {
        if !value { throw Refusal.check(code) }
    }
    private static func wait(_ code: String, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !ready() {
            try Task.checkCancellation()
            guard .now < deadline else { throw Refusal.check(code) }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    private nonisolated static func observe(_ file: URL) throws -> Observation {
        var before = stat(), after = stat()
        guard lstat(file.path, &before) == 0 else { throw Refusal.check("generated-file-observation") }
        guard let bytes = OperationAccessFixtureIO.readRegular(file, maximum: 1 << 20) else {
            throw Refusal.check("bounded-generated-file")
        }
        // Do not reuse a URL's resource cache across archive replacement.
        let fresh = URL(fileURLWithPath: file.path)
        let properties = try fresh.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        guard lstat(file.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw Refusal.check("generated-file-changed-during-observation")
        }
        return Observation(sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            bytes: bytes.count, publiclyMarked: properties?.isEmpty == false,
            device: Int64(after.st_dev), inode: after.st_ino, mode: UInt32(after.st_mode),
            modifiedSeconds: Int64(after.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec))
    }
    private static func observeFile(_ file: URL) async throws -> Observation {
        try await Task.detached { try observe(file) }.value
    }
    private static func inputs(_ fixture: URL) async throws -> [String: Observation] {
        try await Task.detached {
            var result: [String: Observation] = [:]
            for (name, expected) in expectedInputs {
                let file = fixture.appendingPathComponent(name)
                guard OperationAccessFixtureIO.readRegular(file, maximum: 4096) == expected else {
                    throw Refusal.check("generated-source-content")
                }
                result[name] = try observe(file)
            }
            guard Set(try FileManager.default.contentsOfDirectory(atPath: fixture.appendingPathComponent("Source").path))
                    == Set(["Notes.txt", "Nested", "Empty"]),
                  try FileManager.default.contentsOfDirectory(atPath: fixture.appendingPathComponent("Source/Nested").path)
                    == ["Config.json"] else { throw Refusal.check("exact-generated-source-tree") }
            var empty = stat()
            let folder = fixture.appendingPathComponent("Source/Empty")
            guard lstat(folder.path, &empty) == 0, empty.st_mode & S_IFMT == S_IFDIR,
                  empty.st_uid == geteuid(),
                  try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
                throw Refusal.check("generated-empty-folder")
            }
            return result
        }.value
    }
    private static func requireInputs(_ fixture: URL, unchanged before: [String: Observation]) async throws {
        let after = try await inputs(fixture)
        try require(after == before, "source-inputs-preserved")
    }
    private static func markGeneratedInputs(_ fixture: URL) async throws {
        let initial = try await inputs(fixture)
        try require(initial.values.allSatisfy { !$0.publiclyMarked }, "fresh-generated-input-marks")
        try await Task.detached {
            for name in expectedInputs.keys {
                var file = fixture.appendingPathComponent(name)
                var values = URLResourceValues()
                values.quarantineProperties = [
                    kLSQuarantineAgentNameKey as String: "Traverse Generated Archive Check",
                    kLSQuarantineTimeStampKey as String: Date()
                ]
                try file.setResourceValues(values)
                guard try observe(file).publiclyMarked else { throw Refusal.check("generated-public-mark") }
            }
        }.value
    }
    private static func write<T: Encodable & Sendable>(_ value: T, name: String, root: URL) async throws {
        try await Task.detached {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= 1 << 20, !name.contains("/"), name.hasSuffix(".json") else {
                throw Refusal.check("receipt-size-or-name")
            }
            let directory = root.appendingPathComponent("evidence")
            let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard parent >= 0 else { throw Refusal.check("receipt-parent") }
            defer { close(parent) }
            var facts = stat()
            guard fstat(parent, &facts) == 0, facts.st_uid == geteuid(), facts.st_mode & 0o077 == 0 else {
                throw Refusal.check("receipt-owner")
            }
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Refusal.check("receipt-replay") }
            defer { close(fd) }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                guard written > 0 else { throw Refusal.check("receipt-write") }
                offset += written
            }
            guard fsync(fd) == 0, fsync(parent) == 0 else { throw Refusal.check("receipt-durability") }
        }.value
    }
    private static func nativeEditor() -> NativeTextEditorWindow? {
        let editors = NSApp.windows.filter(\.isVisible).compactMap { $0.windowController as? NativeTextEditorWindow }
        return editors.count == 1 ? editors.first : nil
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private static func copyChoice(_ native: NativeTextEditorWindow, name: String?, cancel: Bool) async throws {
        native.saveAsButton.performClick(nil)
        try await wait("native-copy-review") { native.window?.attachedSheet != nil }
        guard let sheet = native.window?.attachedSheet, let content = sheet.contentView else {
            throw Refusal.check("native-copy-sheet")
        }
        if let name {
            guard let field = descendants(content).compactMap({ $0 as? NSTextField })
                .first(where: { $0.accessibilityLabel() == "Archive copy name" }) else {
                throw Refusal.check("native-copy-name")
            }
            try require(sheet.makeFirstResponder(field), "native-copy-focus")
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else { throw Refusal.check("native-copy-editor") }
            editor.insertText(name, replacementRange: .init(location: 0, length: editor.string.utf16.count))
            _ = sheet.makeFirstResponder(nil)
            try require(field.stringValue == name, "native-copy-typed-name")
        }
        guard let button = descendants(content).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == (cancel ? "Cancel" : "Save Copy") }) else {
            throw Refusal.check("native-copy-button")
        }
        button.performClick(nil)
        try await wait("native-copy-sheet-finished") { native.window?.attachedSheet == nil }
    }
    private static func openEditor(_ output: URL, format: ArchiveCreationFormat,
        browser: BrowserViewController) async throws {
        let access = await browser.accessLifetime(for: [output])
        if format == .zip {
            let reader = ZIPArchiveReader(activity: ApplicationFileActivity.gate)
            let session = try await reader.open(output, retaining: access)
            do {
                let folder = try await session.folder(at: ["Source"])
                let page = try await session.page(in: folder)
                guard let item = page.items.first(where: { $0.name == "Notes.txt" }) else { throw Refusal.check("zip-note") }
                let selection = try await session.selectionForTextPreview(item.id)
                ApplicationLocalTextEditors.shared.openArchiveText(selection, source: output,
                    path: "Source/Notes.txt", reader: reader, retaining: access, from: browser)
                try await wait("zip-native-editor") { nativeEditor()?.surface.textView.string == "before\n" }
                await session.close()
            } catch { await session.close(); throw error }
        } else {
            let reader = ApplicationCompressedArchives.shared.reader(excluding: AppStorageLocations.protectedDirectories)
            if format != .tar { try await ApplicationCompressedArchives.shared.prepareStorage() }
            let session = try await (format == .tar ? reader.open(output, retaining: access)
                : reader.prepareCompressed(output, retaining: access))
            do {
                let folder = try await session.folder(at: ["Source"])
                let page = try await session.page(in: folder)
                guard let item = page.items.first(where: { $0.name == "Notes.txt" }) else { throw Refusal.check("tar-note") }
                let selection = try await session.selectionForTextPreview(item.id)
                ApplicationLocalTextEditors.shared.openArchiveText(selection, source: output,
                    path: "Source/Notes.txt", reader: reader, retaining: access, from: browser)
                try await wait("tar-native-editor") { nativeEditor()?.surface.textView.string == "before\n" }
                await session.close()
            } catch { await session.close(); throw error }
        }
    }
    private static func retainedStep(_ id: UUID, kind: String, format: ArchiveCreationFormat,
        file: URL, before: Observation?, engine: RecoverableFileOperations,
        membersBefore: [String: Member]? = nil, membersAfter: [String: Member]? = nil) async throws -> Step {
        let history = try await engine.inspectExistingHistory()
        guard let record = history.records.first(where: { $0.id == id }) else { throw Refusal.check("record-missing") }
        try require(record.state == "committed" && record.canUndo && !record.canRecover,
            "committed-record-not-uncertain")
        if kind == "update" || kind.hasPrefix("member-") {
            try require(!record.canRestoreOriginalArchive && record.operation == "Update " + format.displayName,
                "format-specific-update-contract")
        }
        let observation = try await observeFile(file)
        try require(observation.publiclyMarked && observation.bytes <= 1 << 20, "authored-public-mark")
        return Step(recordID: id, kind: kind, format: format.rawValue,
            output: file.lastPathComponent, before: before, after: observation,
            membersBefore: membersBefore, membersAfter: membersAfter)
    }
    private static func formats(for suite: GeneratedArchiveDriveReview.Suite) -> [ArchiveCreationFormat] {
        suite == .authored ? ArchiveCreationFormat.allCases : ArchiveCreationFormat.allCases.filter { $0 != .zip }
    }
    private static let memberActions = ["new-folder", "new-file", "add", "replace", "duplicate", "rename", "batch-rename",
                                        "group", "copy", "cut", "delegate-drag", "remove"]
    private static func members(of file: URL, format: ArchiveCreationFormat) async throws -> [String: Member] {
        let reader = ApplicationCompressedArchives.shared.reader(excluding: AppStorageLocations.protectedDirectories)
        if format != .tar { try await ApplicationCompressedArchives.shared.prepareStorage() }
        let session = try await (format == .tar ? reader.open(file) : reader.prepareCompressed(file))
        do {
            let page = try await session.searchNames("")
            try require(!page.hasNext && page.total <= 32, "bounded-member-namespace")
            var result: [String: Member] = [:]
            for item in page.items {
                try require(result[item.path] == nil, "unique-member-path")
                switch item.kind {
                case .directory:
                    result[item.path] = Member(kind: "directory", bytes: 0, sha256: nil)
                case .file:
                    let selection = try await session.selectionForTextPreview(item.id)
                    let document = try await reader.openTextForEdit(selection)
                    let bytes = Data(document.contents.text.utf8)
                    try require(bytes.count <= 1024 && UInt64(bytes.count) == item.logicalBytes, "bounded-member-text")
                    result[item.path] = Member(kind: "file", bytes: bytes.count,
                        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
                default: throw Refusal.check("unexpected-generated-member-kind")
                }
            }
            await session.close()
            return result
        } catch { await session.close(); throw error }
    }
    private static func textMember(_ text: String) -> Member {
        let bytes = Data(text.utf8)
        return Member(kind: "file", bytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private static func initialMembers(notes: String) -> [String: Member] {
        let directory = Member(kind: "directory", bytes: 0, sha256: nil)
        return ["Source": directory, "Source/Empty": directory, "Source/Nested": directory,
            "Source/Nested/Config.json": textMember("{\"generated\":true}\n"),
            "Source/Notes.txt": textMember(notes)]
    }
    private static func memberSuffix(_ selection: GeneratedArchiveDriveReview.Selection,
        browser: BrowserViewController, engine: RecoverableFileOperations, inputs: [String: Observation],
        steps: inout [Step], stage: inout String) async throws {
        let directory = Member(kind: "directory", bytes: 0, sha256: nil)
        let config = textMember("{\"generated\":true}\n")
        for format in formats(for: .tarMembers) {
            let source = selection.fixtureRoot.appendingPathComponent("Review." + format.rawValue)
            var expected = initialMembers(notes: "before\nsigned edit " + format.rawValue + "\n")
            func move(_ from: String, to: String) throws {
                guard let member = expected.removeValue(forKey: from), expected[to] == nil else {
                    throw Refusal.check("fixed-member-sequence")
                }
                expected[to] = member
            }
            for action in memberActions {
                stage = format.rawValue + "/member-" + action
                try require(try await members(of: source, format: format) == expected, "exact-members-before-action")
                let beforeMembers = expected
                let before = try await observeFile(source)
                let id: UUID
                switch action {
                case "new-folder":
                    id = try await TARMemberActionDriver.perform(.newFolder, source: source, browser: browser,
                        folder: ["Source"], name: "Destination")
                    expected["Source/Destination"] = directory
                case "new-file":
                    id = try await TARMemberActionDriver.perform(.newFile, source: source, browser: browser,
                        folder: ["Source"], name: "Created.json")
                    expected["Source/Created.json"] = textMember("")
                    try await wait("created-member-native-editor") {
                        guard let document = ApplicationLocalTextEditors.shared.archiveDocumentForVerification(
                            source: source, path: "Source/Created.json") else { return false }
                        return document.opened.archiveURL == source && document.opened.archivePath == "Source/Created.json"
                            && nativeEditor() === document.window && document.window.surface.textView.string == ""
                            && document.window.language.titleOfSelectedItem == "JSON"
                    }
                    guard let editor = nativeEditor(), editor.window?.isDocumentEdited == false else {
                        throw Refusal.check("created-member-editor-is-clean")
                    }
                    editor.window?.performClose(nil)
                    try await wait("created-member-editor-close-drain") {
                        ApplicationLocalTextEditors.shared.documentReservationCount == 0
                            && !ApplicationLocalTextEditors.shared.hasFileWork
                    }
                case "add":
                    id = try await TARMemberActionDriver.perform(.add, source: source, browser: browser,
                        folder: ["Source"], addedSource: selection.fixtureRoot.appendingPathComponent("Source/Nested/Config.json"),
                        nativeAddDrop: true)
                    expected["Source/Config.json"] = config
                case "replace":
                    id = try await TARMemberActionDriver.perform(.add, source: source, browser: browser,
                        folder: ["Source"], addedSource: selection.fixtureRoot.appendingPathComponent("Source/Notes.txt"), replaceFiles: true)
                    expected["Source/Notes.txt"] = textMember("before\n")
                case "duplicate":
                    id = try await TARMemberActionDriver.perform(.duplicate, source: source, browser: browser,
                        folder: ["Source"], names: ["Config.json"])
                    expected["Source/Config (1).json"] = config
                case "rename":
                    id = try await TARMemberActionDriver.perform(.rename, source: source, browser: browser,
                        folder: ["Source"], names: ["Notes.txt"], name: "Renamed.txt")
                    try move("Source/Notes.txt", to: "Source/Renamed.txt")
                case "batch-rename":
                    id = try await TARMemberActionDriver.perform(.rename, source: source, browser: browser,
                        folder: ["Source"], names: ["Renamed.txt", "Config (1).json"], batchPrefix: "Batch ")
                    try move("Source/Renamed.txt", to: "Source/Batch Renamed.txt")
                    try move("Source/Config (1).json", to: "Source/Batch Config (1).json")
                case "group":
                    id = try await TARMemberActionDriver.perform(.group, source: source, browser: browser,
                        folder: ["Source"], names: ["Batch Renamed.txt", "Batch Config (1).json"], name: "Grouped")
                    expected["Source/Grouped"] = directory
                    try move("Source/Batch Renamed.txt", to: "Source/Grouped/Batch Renamed.txt")
                    try move("Source/Batch Config (1).json", to: "Source/Grouped/Batch Config (1).json")
                case "copy":
                    id = try await TARMemberActionDriver.transfer(.copy, source: source, browser: browser,
                        from: ["Source", "Grouped"], names: ["Batch Renamed.txt"], destination: ["Source", "Destination"])
                    expected["Source/Destination/Batch Renamed.txt"] = textMember("before\n")
                case "cut":
                    id = try await TARMemberActionDriver.transfer(.cut, source: source, browser: browser,
                        from: ["Source", "Grouped"], names: ["Batch Config (1).json"], destination: ["Source", "Destination"])
                    try move("Source/Grouped/Batch Config (1).json", to: "Source/Destination/Batch Config (1).json")
                case "delegate-drag":
                    id = try await TARMemberActionDriver.transfer(.drag, source: source, browser: browser,
                        from: ["Source"], names: ["Config.json"], destination: ["Source", "Destination"])
                    try move("Source/Config.json", to: "Source/Destination/Config.json")
                case "remove":
                    id = try await TARMemberActionDriver.perform(.remove, source: source, browser: browser,
                        folder: ["Source", "Grouped"], names: ["Batch Renamed.txt"])
                    try require(expected.removeValue(forKey: "Source/Grouped/Batch Renamed.txt") != nil, "fixed-removed-member")
                default: throw Refusal.check("fixed-member-action")
                }
                let actual = try await members(of: source, format: format)
                try require(actual == expected, "exact-members-after-action")
                steps.append(try await retainedStep(id, kind: "member-" + action, format: format,
                    file: source, before: before, engine: engine, membersBefore: beforeMembers, membersAfter: actual))
                try await requireInputs(selection.fixtureRoot, unchanged: inputs)
                try await write(Receipt(phase: format.rawValue + "-member-" + action, pid: getpid(), inputs: inputs, steps: steps),
                    name: "authored-prefix-" + String(steps.count) + ".json", root: selection.caseRoot)
            }
        }
    }
    private static func warm(_ selection: GeneratedArchiveDriveReview.Selection,
        browser: BrowserViewController, engine: RecoverableFileOperations, stage: inout String) async throws {
        let initial = try await inputs(selection.fixtureRoot)
        try await write(Receipt(phase: "warm-attempt", pid: getpid(), inputs: initial, steps: []),
            name: "authored-warm-attempt.json", root: selection.caseRoot)
        // Only the exact two generated inputs are marked, using the same public
        // resource API as the ordinary authored-archive check. No raw flags are
        // interpreted and no personal source is discovered or modified.
        try await markGeneratedInputs(selection.fixtureRoot)
        let before = try await inputs(selection.fixtureRoot)
        try require(before.values.allSatisfy(\.publiclyMarked), "marked-generated-inputs")
        try require((try await engine.inspectExistingHistory()).records.isEmpty, "fresh-authored-history")
        var steps: [Step] = []
        for format in formats(for: selection.suite) {
            stage = format.rawValue + "/create-review"
            browser.navigate(to: .directory(selection.fixtureRoot))
            try await wait(stage) { !browser.isLoading && browser.orderingTask == nil }
            let source = selection.fixtureRoot.appendingPathComponent("Source")
            browser.reloadFileRows(preserving: [source])
            try require(browser.canCreateZIP, "native-create-selection")
            ApplicationArchiveCreation.shared.show(sources: [source], from: browser)
            guard let panel = ApplicationArchiveCreation.shared.controller else { throw Refusal.check("creation-controller") }
            panel.model.chooseOutputFormat(format)
            panel.model.name = "Occupied." + format.rawValue
            try await wait("create-collision-preview") {
                !panel.model.isPreparing && panel.model.notice == FileOperationFailure.conflict.userMessage
            }
            try require(!panel.model.canCreate && panel.model.outcome == nil, "collision-refused-before-create")
            panel.window?.performClose(nil)
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try require((try await engine.inspectExistingHistory()).records.count == steps.count, "cancel-kept-history")
            ApplicationArchiveCreation.shared.show(sources: [source], from: browser)
            guard let created = ApplicationArchiveCreation.shared.controller else { throw Refusal.check("fresh-create-controller") }
            created.model.chooseOutputFormat(format)
            created.model.name = "Review." + format.rawValue
            try await wait("create-preview-ready") { created.model.canCreate }
            let expectedBytes = before.values.reduce(0) { $0 + $1.bytes }
            try require(created.model.plan?.files == 2 && created.model.plan?.folders == 3
                && created.model.plan?.logicalBytes == UInt64(expectedBytes), "exact-bounded-creation-preview")
            try await requireInputs(selection.fixtureRoot, unchanged: before)
            stage = format.rawValue + "/create"
            created.model.create()
            try await wait("create-terminal") { created.model.outcome != nil && !created.model.isRunning }
            guard let outcome = created.model.outcome else { throw Refusal.check("create-result") }
            if let item = outcome.result.items.first, case .failed(let failure) = item.status {
                throw Refusal.check("create-" + failure.rawValue)
            }
            guard outcome.result.disposition == .succeeded,
                  let createID = outcome.recordID else { throw Refusal.check("create-result") }
            let output = selection.fixtureRoot.appendingPathComponent("Review." + format.rawValue)
            stage = format.rawValue + "/verify-created-members"
            let createdMembers = selection.suite == .tarMembers ? try await members(of: output, format: format) : nil
            if let createdMembers {
                try require(createdMembers == initialMembers(notes: "before\n"), "exact-created-members")
            }
            let made = try await retainedStep(createID, kind: "create", format: format, file: output,
                before: nil, engine: engine, membersAfter: createdMembers)
            steps.append(made)
            await ApplicationArchiveCreation.shared.closeAndDrain()
            stage = format.rawValue + "/editor"
            try await openEditor(output, format: format, browser: browser)
            guard let editor = nativeEditor() else { throw Refusal.check("single-native-editor") }
            let edited = "before\nsigned edit " + format.rawValue + "\n"
            editor.surface.textView.insertText(edited,
                replacementRange: .init(location: 0, length: editor.surface.textView.string.utf16.count))
            try await wait("editor-edit-ready") { editor.window?.isDocumentEdited == true && editor.saveButton.isEnabled }
            stage = format.rawValue + "/save"
            editor.saveButton.performClick(nil)
            try await wait("editor-save-terminal") { !ApplicationLocalTextEditors.shared.hasFileWork }
            try require(editor.window?.isDocumentEdited == false && editor.saveButton.isEnabled,
                "editor-save-confirmed")
            guard let updateID = browser.lastRecoveryRecordID, updateID != createID else { throw Refusal.check("editor-update-record") }
            stage = format.rawValue + "/verify-saved-members"
            let editedMembers = selection.suite == .tarMembers ? try await members(of: output, format: format) : nil
            if let editedMembers {
                try require(editedMembers == initialMembers(notes: edited), "exact-edited-members")
            }
            steps.append(try await retainedStep(updateID, kind: "update", format: format, file: output,
                before: made.after, engine: engine, membersBefore: createdMembers, membersAfter: editedMembers))
            if selection.suite == .authored {
                let copied = edited + "saved copy\n"
                editor.surface.textView.insertText(copied,
                    replacementRange: .init(location: 0, length: editor.surface.textView.string.utf16.count))
                try await wait("copy-edit-ready") { editor.window?.isDocumentEdited == true && editor.saveAsButton.isEnabled }
                stage = format.rawValue + "/copy-cancel"
                try await copyChoice(editor, name: nil, cancel: true)
                try await wait("copy-cancel-idle") { !ApplicationLocalTextEditors.shared.hasFileWork }
                let afterCancel = try await engine.inspectExistingHistory()
                try require(editor.window?.isDocumentEdited == true && afterCancel.records.count == steps.count,
                    "copy-cancel-retained-draft")
                stage = format.rawValue + "/save-copy"
                let copy = selection.fixtureRoot.appendingPathComponent("Edited Copy." + format.rawValue)
                try await copyChoice(editor, name: copy.lastPathComponent, cancel: false)
                try await wait("editor-copy-terminal") { !ApplicationLocalTextEditors.shared.hasFileWork }
                try require(editor.window?.isDocumentEdited == false && editor.saveButton.isEnabled,
                    "editor-copy-confirmed")
                guard let copyID = browser.lastRecoveryRecordID, copyID != updateID else { throw Refusal.check("editor-copy-record") }
                steps.append(try await retainedStep(copyID, kind: "copy", format: format, file: copy,
                    before: nil, engine: engine))
                let unchanged = try await observeFile(output)
                try require(unchanged == steps[steps.count - 2].after, "save-copy-kept-original")
            }
            editor.window?.performClose(nil)
            try await wait("editor-native-close-drain") {
                ApplicationLocalTextEditors.shared.documentReservationCount == 0
                    && !ApplicationLocalTextEditors.shared.hasFileWork
            }
            try await requireInputs(selection.fixtureRoot, unchanged: before)
            try await write(Receipt(phase: format.rawValue + "-committed", pid: getpid(), inputs: before, steps: steps),
                name: "authored-prefix-" + String(steps.count) + ".json", root: selection.caseRoot)
        }
        if selection.suite == .tarMembers {
            try await memberSuffix(selection, browser: browser, engine: engine, inputs: before, steps: &steps, stage: &stage)
        }
        try require(steps.count == selection.suite.jobsMaximum
            && Set(steps.map(\.recordID)).count == selection.suite.jobsMaximum, "exact-forward-job-count")
        if selection.suite == .tarMembers {
            let history = try await engine.inspectExistingHistory()
            try require(history.records.count == steps.count
                && Set(history.records.map(\.id)) == Set(steps.map(\.recordID))
                && history.records.allSatisfy { $0.state == "committed" && $0.canUndo && !$0.canRecover },
                "complete-member-forward-history")
        }
        try await write(Receipt(phase: "warm-completed", pid: getpid(), inputs: before, steps: steps),
            name: "authored-warm.json", root: selection.caseRoot)
    }
    private static func cold(_ selection: GeneratedArchiveDriveReview.Selection,
        browser: BrowserViewController, engine: RecoverableFileOperations, stage: inout String) async throws {
        let receipt = try await Task.detached {
            guard let data = OperationAccessFixtureIO.readRegular(selection.caseRoot.appendingPathComponent("evidence/authored-warm.json"),
                maximum: 1 << 20) else { throw Refusal.check("warm-receipt") }
            return try JSONDecoder().decode(Receipt.self, from: data)
        }.value
        try require(receipt.phase == "warm-completed" && receipt.pid != getpid()
            && receipt.steps.count == selection.suite.jobsMaximum
            && Set(receipt.steps.map(\.recordID)).count == selection.suite.jobsMaximum, "true-cold-process-and-jobs")
        let warm = try await Task.detached {
            guard let data = OperationAccessFixtureIO.readRegular(selection.caseRoot.appendingPathComponent("evidence/archive-warm-result.json"),
                maximum: 4096) else { throw Refusal.check("warm-terminal-receipt") }
            return try JSONDecoder().decode(Outcome.self, from: data)
        }.value
        try require(warm.passed && warm.phase == "archive-warm" && warm.stage == "completed"
            && warm.pid == receipt.pid, "warm-owner-drain-confirmed")
        let kinds = selection.suite == .authored ? ["create", "update", "copy"] : ["create", "update"]
        var sequence = formats(for: selection.suite).flatMap { format in kinds.map { (format, $0) } }
        if selection.suite == .tarMembers {
            sequence += formats(for: selection.suite).flatMap { format in memberActions.map { (format, "member-" + $0) } }
        }
        try require(sequence.count == receipt.steps.count, "fixed-authored-sequence-count")
        for (index, step) in receipt.steps.enumerated() {
            let (format, kind) = sequence[index]
            try require(step.format == format.rawValue && step.kind == kind
                && step.output == (kind == "copy" ? "Edited Copy." : "Review.") + format.rawValue,
                "fixed-authored-job-sequence")
            if kind == "update" || kind.hasPrefix("member-") {
                let previous = receipt.steps[..<index].last { $0.output == step.output }
                try require(previous != nil && step.before == previous?.after, "exact-update-before-image")
                if selection.suite == .tarMembers {
                    try require(step.membersBefore != nil && step.membersAfter != nil
                        && step.membersBefore == previous?.membersAfter, "member-namespace-receipt")
                }
            } else { try require(step.before == nil, "new-copy-has-no-replacement") }
            if selection.suite == .tarMembers && kind == "create" {
                try require(step.membersBefore == nil && step.membersAfter == initialMembers(notes: "before\n"),
                    "member-setup-create-namespace")
            }
        }
        try await requireInputs(selection.fixtureRoot, unchanged: receipt.inputs)
        if selection.suite == .tarMembers {
            let history = try await engine.inspectExistingHistory()
            try require(history.records.count == receipt.steps.count
                && Set(history.records.map(\.id)) == Set(receipt.steps.map(\.recordID))
                && history.records.allSatisfy { $0.state == "committed" && $0.canUndo && !$0.canRecover },
                "complete-member-cold-admission-history")
        }
        try await write(Receipt(phase: "cold-attempt", pid: getpid(), inputs: receipt.inputs, steps: []),
            name: "authored-cold-attempt.json", root: selection.caseRoot)
        for (index, step) in receipt.steps.reversed().enumerated() {
            stage = step.format + "/undo-" + step.kind
            try require(ArchiveCreationFormat(rawValue: step.format) != nil && !step.output.contains("/")
                && step.output != "." && step.output != "..", "recorded-output-leaf")
            let file = selection.fixtureRoot.appendingPathComponent(step.output)
            let current = try await observeFile(file)
            try require(current == step.after && current.publiclyMarked, "cold-exact-output")
            if let expected = step.membersAfter, let format = ArchiveCreationFormat(rawValue: step.format) {
                try require(try await members(of: file, format: format) == expected, "cold-exact-member-namespace")
            }
            let history = try await engine.inspectExistingHistory()
            guard let record = history.records.first(where: { $0.id == step.recordID }),
                  record.state == "committed", record.canUndo
            else { throw Refusal.check("cold-record-and-parent") }
            let requirement = try await engine.undoAccessRequirement(recordID: step.recordID)
            if step.kind == "update" || step.kind.hasPrefix("member-") {
                // Original updates already bind their retained archive and
                // parent. The separate folder-grant requirement is for newly
                // produced outputs, not these native replacement records.
                try require(requirement == nil && !record.canRestoreOriginalArchive,
                    "committed-update-uses-ordinary-undo")
            } else {
                try require(requirement?.directory.path.utf8.elementsEqual(selection.fixtureRoot.path.utf8) == true,
                    "created-output-parent-requirement")
            }
            var result: RecoverableOperationResult?
            browser.startRecoveryOperation(record, rollback: false, presentsResult: false) { result = $0 }
            try await wait("native-cold-undo") { result != nil || browser.view.window?.attachedSheet != nil }
            try require(browser.view.window?.attachedSheet == nil && result?.result.disposition == .succeeded,
                "native-cold-undo-without-grant-or-overwrite")
            await browser.operationTask?.value
            if let expected = step.before {
                let restored = try await observeFile(file)
                try require(restored == expected && restored.publiclyMarked, "exact-earlier-archive-restored")
                if let expectedMembers = step.membersBefore, let format = ArchiveCreationFormat(rawValue: step.format) {
                    try require(try await members(of: file, format: format) == expectedMembers, "exact-earlier-member-namespace")
                }
            } else {
                let absent = await Task.detached {
                    var facts = stat(); return lstat(file.path, &facts) < 0 && errno == ENOENT
                }.value
                try require(absent, "exact-created-output-undone")
            }
            let final = try await engine.inspectExistingHistory()
            try require(final.records.contains { $0.id == step.recordID && $0.state == "undone" && !$0.canUndo },
                "cold-terminal-history")
            try await write(Receipt(phase: "cold-prefix-" + String(index + 1), pid: getpid(),
                inputs: receipt.inputs, steps: [step]), name: "authored-cold-" + String(index + 1) + ".json",
                root: selection.caseRoot)
        }
        try await requireInputs(selection.fixtureRoot, unchanged: receipt.inputs)
        if selection.suite == .tarMembers {
            let history = try await engine.inspectExistingHistory()
            try require(history.records.count == receipt.steps.count
                && Set(history.records.map(\.id)) == Set(receipt.steps.map(\.recordID))
                && history.records.allSatisfy { $0.state == "undone" && !$0.canUndo && !$0.canRecover },
                "complete-member-inverse-history")
        }
        try await write(Receipt(phase: "cold-completed", pid: getpid(), inputs: receipt.inputs, steps: receipt.steps),
            name: "authored-cold.json", root: selection.caseRoot)
    }
    static func runAuthoredArchives(selection: GeneratedArchiveDriveReview.Selection) async {
        var owner: BrowserWindowController?, stage = "admission"
        do {
            try require(GeneratedArchiveDriveReview.archiveAdmitted && !TraverseAccessPolicy.requiresFolderSelection,
                "exact-archive-review-admission")
            if selection.phase == .archiveCold {
                try require(!ArchiveCreationActivation.available && !TARArchiveEditingFeature.available
                    && !ZIPMemberRenameFeature.available, "cold-forward-controls-held")
            }
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.restoresSession = false
            settings.opensArchivesInTraverse = true; settings.motion.mode = .reduced
            InterfacePresentation.shared.bind(settings)
            let controller = BrowserWindowController(settings: settings); owner = controller
            let browser = controller.browser
            browser.privateNames.configure(browser)
            let namesDirectory = selection.journalDirectory.deletingLastPathComponent()
                .appendingPathComponent("private-names", isDirectory: true)
            try require(browser.privateNames.directory?.path == namesDirectory.path,
                "generated-saved-name-owner")
            browser.recoverableFileOperations = browser.operationCoordinator.engine(at: selection.journalDirectory)
            controller.beginBrowsing()
            await controller.workspace.startupTask?.value
            guard let engine = browser.recoverableFileOperations, let window = controller.window else { throw Refusal.check("browser-engine") }
            window.title = "Signed archive review · generated files"
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            browser.navigate(to: .directory(selection.fixtureRoot))
            try await wait("review-folder") { !browser.isLoading && browser.orderingTask == nil }
            switch selection.phase {
            case .archiveWarm: try await warm(selection, browser: browser, engine: engine, stage: &stage)
            case .archiveCold: try await cold(selection, browser: browser, engine: engine, stage: &stage)
            case .driveReadOnly: throw Refusal.check("archive-phase")
            }
            try require(await ApplicationLocalTextEditors.shared.prepareForTermination(), "editor-owner-drain")
            await ApplicationArchiveCreation.shared.closeAndDrain()
            await ArchiveTabCatalogPool.shared.closeAndDrain()
            try require(await ApplicationCompressedArchives.shared.closeAndDrain(), "compressed-owner-drain")
            try require(ApplicationFileActivity.gate.activeCount == 0 && browser.operationTask == nil
                && browser.operationPreparationTask == nil, "actual-archive-work-drain")
            stage = "completed"
            try await write(Outcome(passed: true, phase: selection.phase.rawValue, stage: stage, refusal: nil, pid: getpid()),
                name: selection.phase.rawValue + "-result.json", root: selection.caseRoot)
        } catch {
            let code: String
            if case Refusal.check(let detail) = error { code = detail }
            else if let failure = error as? TARMemberActionDriver.Failure {
                code = String(failure.stage.prefix(while: { $0 != ":" }))
            }
            else if let failure = error as? TARArchiveFailure { code = "archive-reader-" + failure.rawValue }
            else if let failure = error as? FileOperationFailure { code = failure.rawValue }
            else { code = "operation-refused" }
            let browser = owner?.browser
            browser?.operationPreparationTask?.cancel(); browser?.operationTask?.cancel()
            await browser?.operationPreparationTask?.value; await browser?.operationTask?.value
            await ApplicationArchiveCreation.shared.closeAndDrain()
            if let editor = nativeEditor(), editor.stopButton.isEnabled { editor.stopButton.performClick(nil) }
            try? await wait("failed-editor-work-drain") { !ApplicationLocalTextEditors.shared.hasFileWork }
            try? await write(Outcome(passed: false, phase: selection.phase.rawValue, stage: stage,
                refusal: code, pid: getpid()),
                name: selection.phase.rawValue + "-result.json", root: selection.caseRoot)
            let failures = browser?.lastOperationResult?.items.compactMap { item -> String? in
                if case .failed(let failure) = item.status { return failure.rawValue }
                return nil
            } ?? []
            try? await write(["stage": stage, "codes": failures.joined(separator: ",")],
                name: "failed-operation-codes.json", root: selection.caseRoot)
            // Only a known generated draft may be retained and discarded here.
            // Unexpected typing remains in its window for an explicit decision.
            if let editor = nativeEditor(), let window = editor.window,
               !ApplicationLocalTextEditors.shared.hasFileWork {
                let draft = editor.surface.textView.string
                let generated = Set(["before\n"] + ArchiveCreationFormat.allCases.flatMap { format in
                    let edited = "before\nsigned edit " + format.rawValue + "\n"
                    return [edited, edited + "saved copy\n"]
                })
                if generated.contains(draft) {
                    do {
                        try await write(["draft": draft, "origin": "exact-generated-archive-text"],
                            name: "failed-generated-draft.json", root: selection.caseRoot)
                        window.performClose(nil)
                        try await wait("failed-draft-close-choice") { !window.isVisible || window.attachedSheet != nil }
                        if let sheet = window.attachedSheet, let content = sheet.contentView {
                            guard let discard = descendants(content).compactMap({ $0 as? NSButton })
                                .first(where: { $0.title == "Don’t Save" || $0.title == "Close and Discard Visible Text" }) else {
                                throw Refusal.check("failed-draft-discard-choice")
                            }
                            discard.performClick(nil)
                        }
                        try await wait("failed-draft-native-close") {
                            !window.isVisible && ApplicationLocalTextEditors.shared.documentReservationCount == 0
                        }
                    } catch { /* Keep the native draft/window if its normal close cannot finish. */ }
                }
            }
        }
        await owner?.browser.privateNames.close()
        owner?.suspendBrowsing(); await owner?.flushSession(); owner?.window?.close()
        NSApp.terminate(nil)
    }
    static func runPassiveDriveInspection(selection: GeneratedArchiveDriveReview.Selection) async {
        var stage = "passive-admission"
        do {
            try require(GeneratedArchiveDriveReview.driveAdmitted && !GeneratedArchiveDriveReview.archiveAdmitted
                && !AppFeatureAvailability.allows(.apfsVolumeCreation), "passive-drive-role")
            guard let state = AppStorageLocations.stateDirectory,
                  state.path.utf8.elementsEqual(selection.journalDirectory.deletingLastPathComponent().path.utf8),
                  let store = NativeDriveJobStore.applicationStore() else { throw Refusal.check("passive-drive-store") }
            let file = state.appendingPathComponent("drive-jobs/native-drive-job-v1.json")
            let before = try await observeFile(file)
            stage = "passive-job-load"
            let snapshot = try await store.load()
            guard let record = snapshot.record, record.validate(), record.isUnresolved,
                  record.phase == .compatibleReplacement else { throw Refusal.check("provisional-job-remains-unresolved") }
            let after = try await observeFile(file)
            try require(before.sha256 == after.sha256 && before.bytes == after.bytes
                && !AppFeatureAvailability.allows(.apfsVolumeCreation), "passive-job-unchanged-no-mutation")
            try await write(DriveReceipt(jobID: record.id, phase: record.phase.rawValue, unresolved: true,
                beforeSHA256: before.sha256, afterSHA256: after.sha256, nativeMutationHeld: true),
                name: "passive-drive-record.json", root: selection.caseRoot)
            stage = "completed"
            try await write(Outcome(passed: true, phase: selection.phase.rawValue, stage: stage, refusal: nil, pid: getpid()),
                name: "drive-read-only-result.json", root: selection.caseRoot)
        } catch {
            let code: String
            if case Refusal.check(let detail) = error { code = detail } else { code = "passive-job-refused" }
            try? await write(Outcome(passed: false, phase: selection.phase.rawValue, stage: stage, refusal: code, pid: getpid()),
                name: "drive-read-only-result.json", root: selection.caseRoot)
        }
        NSApp.terminate(nil)
    }
}
#endif
