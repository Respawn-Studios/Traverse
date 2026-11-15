#if DEBUG
import AppKit
import CryptoKit
import Darwin
@_spi(Qualification) import FileOperations
import LocalStorage

@MainActor enum ArchivePromiseExportVerification {
    private static var openedSession: Catalog?
    private static var compressedPool: TARCompressedPreparationPool?
    private static var openedAccess: CountedAccess?
    private static var phase = "startup"
    private final class CountedAccess: FolderAccessBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0, stops = 0
        var active: Int { lock.withLock { starts - stops } }
        func startAccess(to url: URL) -> Bool { lock.withLock { starts += 1 }; return true }
        func stopAccess(to url: URL) { lock.withLock { stops += 1 } }
        func bookmark(for url: URL) throws -> Data { throw CancellationError() }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw CancellationError() }
    }
    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: [Bool]] = [:]
        private var errors: [String: [Int]] = [:]
        func receive(_ key: String, _ error: Error?) { lock.withLock { values[key, default: []].append(error == nil); errors[key,default: []].append(error.map { ($0 as NSError).code } ?? 0) } }
        func values(_ key: String) -> [Bool] { lock.withLock { values[key] ?? [] } }
        func errorCodes(_ key: String) -> [Int] { lock.withLock { errors[key] ?? [] } }
    }
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class ViewState {
        var current = true
        var notices: [String] = []
    }
    private struct Offered {
        let job: ArchivePromiseExport, providers: [String: NSFilePromiseProvider]
    }
    private enum Catalog {
        case zip(ZIPArchiveSession), tar(TARArchiveSession)
        func close() async {
            switch self { case .zip(let session): await session.close(); case .tar(let session): await session.close() }
        }
        func capture(_ names: Set<String>) async throws -> (ArchivePromiseRoots, [(name: String, path: String)]) {
            switch self {
            case .zip(let session):
                let items = try await session.page(in: session.root).items.filter { names.contains($0.name) }
                return (.zip(try await session.rootsForExport(Set(items.map(\.id)))), items.map { ($0.name, $0.path) })
            case .tar(let session):
                let items = try await session.page(in: session.root).items.filter { names.contains($0.name) }
                return (.tar(try await session.rootsForExport(Set(items.map(\.id)))), items.map { ($0.name, $0.path) })
            }
        }
    }
    static func run() async {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development", isDirectory: true),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              ["native-archive-promise-export", "native-archive-export"].contains(marker["action"] as? String ?? "") else { exit(2) }
        ArchivePromiseExportFeature.qualifying = true
        let inputs = try? Data(contentsOf: root.appendingPathComponent("inputs.json"))
        let input = inputs.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let publicPublication = input?["publicPublication"] as? Bool == true
        let format = input?["archiveFormat"] as? String ?? "zip"
        guard ["zip", "tar", "tar.gz", "tar.bz2"].contains(format), format == "zip" || publicPublication else { exit(2) }
        TARPromiseExportFeature.qualifying = format != "zip"
        guard format != "zip" || !TARPromiseExportFeature.available else { exit(2) }
        ArchivePromiseExportFeature.qualifyingPublications = publicPublication
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false; settings.motion.mode = .off
        let owner = BrowserWindowController(settings: settings)
        var checks: [String] = [], failure: [String: Any] = [:]
        var logger: DiagnosticRecorder?
        // Native run-loop callbacks need an explicit actor hop; they are not
        // proof of the current Swift executor. Measure actual actor service.
        let clock = Pulse(), timer = Timer(timeInterval: 0.016, repeats: true) { _ in Task { @MainActor in clock.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        do {
            let service = DiagnosticRecorder(directory: root.appendingPathComponent("state/logs"),limits: try .init(bytes: 512 << 10,segmentBytes: 64 << 10),recording: true)
            logger = service; ApplicationDiagnostics.shared.configureForVerification(service)
            try await verify(root, owner: owner, logger: service, format: format, publicPublication: publicPublication, checks: &checks)
        }
        catch {
            let value = error as NSError
            failure = ["domain": value.domain, "code": value.code, "phase": phase]
            if let value = error as? UIVerification.Failure { failure["assertion"] = value.message }
        }
        await ApplicationArchiveExports.shared.closeAndDrain()
        ApplicationDiagnostics.shared.configureForVerification(nil)
        await logger?.closeAndDrain()
        if let openedSession { await openedSession.close() }; openedSession = nil
        let spoolsDrained = await compressedPool?.closeAndDrain() ?? true; compressedPool = nil
        await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing()
        if let listing = owner.browser.listingTask { await listing.value }
        await owner.flushSession(); owner.window?.close(); timer.invalidate(); clock.tick()
        ArchivePromiseExportFeature.qualifying = false
        TARPromiseExportFeature.qualifying = false
        ArchivePromiseExportFeature.qualifyingPublications = false
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let drained = ApplicationArchiveExports.shared.countForVerification == 0 && ApplicationFileActivity.gate.activeCount == 0
            && openedAccess?.active == 0 && spoolsDrained
        openedAccess = nil
        let passed = failure.isEmpty && drained && clock.gap < 0.5 && clock.ticks > 10 && usage.ru_maxrss <= 256 << 20
        try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "failure": failure,
            "drained": drained, "maximumMainActorGapSeconds": clock.gap, "ticks": clock.ticks, "peakRSSBytes": usage.ru_maxrss,
            "actualPromiseCallbacks": true, "physicalGesture": false, "sandboxGrantExercised": false,
            "publicPublication": publicPublication, "archiveFormat": format, "spoolsDrained": spoolsDrained,
            "network": 0, "personalArchives": 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/native-archive-promise-export.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(_ root: URL, owner: BrowserWindowController, logger: DiagnosticRecorder,
        format: String, publicPublication: Bool, checks: inout [String]) async throws {
        let browser = owner.browser, source = root.appendingPathComponent("source/Generated." + format), access = CountedAccess()
        openedAccess = access
        guard let window = owner.window else { throw UIVerification.Failure(message: "Generated owner missing") }
        window.setFrame(.init(x: -12_000, y: -12_000, width: 1_000, height: 700), display: true)
        browser.permitsBackgroundVerification = true; browser.operationErrorPresenter = { _ in }; browser.operationResultPresenter = { _ in }
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history", isDirectory: true),
            activity: ApplicationFileActivity.beginOperation,
            zipOneFilePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
            tarOneFilePublicExtractionPolicy: format != "zip" ? .sourceQualification : .held,
            zipTreePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
            tarTreePublicExtractionPolicy: format != "zip" ? .sourceQualification : .held)
        browser.recoverableFileOperations = engine; browser.folderAccess = FolderAccessController(backend: access)
        let grant = await browser.folderAccess.acceptChosenFolder(root); grant?.lease.close()
        owner.beginBrowsing()
        try await wait { owner.workspace.sessionReady }
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait { !browser.isLoading && browser.orderingTask == nil
            && browser.location.directoryURL == source.deletingLastPathComponent() }
        let baselineAccess = access.active
        let session: Catalog
        if format == "zip" { session = .zip(try await ZIPArchiveReader().open(source)) }
        else if format == "tar" { session = .tar(try await TARArchiveReader().open(source)) }
        else {
            let cache = root.appendingPathComponent("state/compressed-cache")
            try await Task.detached { try FileManager().createDirectory(at: cache, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]) }.value
            let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: ApplicationFileActivity.gate)
            compressedPool = pool
            session = .tar(try await TARArchiveReader(compressedPool: pool).prepareCompressed(source, publicQuarantineSource: true))
        }
        openedSession = session
        let expected: [String: Data] = ["First.txt": Data("Generated first root\n".utf8), "Last.txt": Data("Generated last root\n".utf8)]
        func destination(_ name: String) async throws -> URL {
            let url = root.appendingPathComponent("state/" + name, isDirectory: true)
            try await Task.detached { try FileManager().createDirectory(at: url, withIntermediateDirectories: true) }.value
            return url
        }
        var linkedExport: UUID?
        let sourceTrace = UUID()
        ApplicationDiagnostics.shared.event(.drag,.admitted,trace: sourceTrace,context: .init(.dragSession))
        func offered(_ names: Set<String>, isCurrent: @escaping @MainActor () -> Bool = { true },
                     notice: @escaping @MainActor (String) -> Void = { _ in }) async throws -> Offered {
            let (roots, items) = try await session.capture(names)
            let preparation = ArchivePromisePreparation<Set<String>>()
            preparation.request(names, source: source, browser: browser, window: window,
                roots: { roots }, isCurrent: isCurrent, canPrepare: { browser.operationTask == nil }, notice: notice)
            try await wait { preparation.offer(for: names) != nil }
            guard let job = preparation.offer(for: names) else { throw FileOperationFailure.unavailable }
            var providers: [String: NSFilePromiseProvider] = [:]
            for item in items {
                guard let provider = job.provider(forArchivePath: item.path, marker: UUID()) else { throw UIVerification.Failure(message: "Promise missing") }
                providers[item.name] = provider
                let board = NSPasteboard(name: .init("Traverse.Generated.ZIPExport." + UUID().uuidString))
                defer { board.releaseGlobally() }
                try UIVerification.require(board.writeObjects([provider]) && board.pasteboardItems?.first?.types.contains(ArchiveMemberDragSource.pasteboardType) == true,
                    "Native promise lost the private marker")
                let receivers = NSFilePromiseReceiver.readableDraggedTypes
                try UIVerification.require(board.types?.contains(where: { receivers.contains($0.rawValue) }) == true,
                    "AppKit did not expose native promise receiver types")
            }
            try UIVerification.require(job.handOff(diagnosticTrace: sourceTrace), "Offer admission missing")
            return .init(job: job, providers: providers)
        }
        func send(_ offer: Offered, _ name: String, to target: URL, _ replies: Replies, _ key: String) throws {
            guard let provider = offer.providers[name], let delegate = provider.userInfo as? ArchivePromiseDelegate else {
                throw UIVerification.Failure(message: "Native delegate missing")
            }
            delegate.filePromiseProvider(provider, writePromiseTo: target) { replies.receive(key, $0) }
        }
        func complete(_ offer: Offered, _ replies: Replies, keys: [String]) async throws {
            try await wait { keys.allSatisfy { replies.values($0).count == 1 } && offer.job.drainedForVerification }
            if let inspection = browser.recoveryInspectionTask { await inspection.value }
            try await wait { browser.operationCoordinator.inspectionCount == 0 }
            offer.job.retireUncalled()
            try UIVerification.require(offer.job.terminalForVerification, "Offer lease did not drain")
            if publicPublication {
                for result in offer.job.outcomesForVerification where result.result.disposition == .succeeded {
                    guard let record = result.recordID else { throw UIVerification.Failure(message: "Promise publication record missing") }
                    let catalog = try await engine.inspectGeneratedPublicCatalog(recordID: record)
                    try UIVerification.require((format == "zip" ? [15, 16] : [16, 17]).contains(catalog.version), "Promise used a different publication contract")
                }
            }
        }
        if format == "zip" {
            phase = "same-selection-rearm"
            ApplicationZIPBrowser.shared.show(source, from: browser)
            guard let model = ApplicationZIPBrowser.shared.controller?.model else { throw FileOperationFailure.unavailable }
            try await wait { model.viewIsCurrent && !model.isLoading && !model.isPaging }
            guard let item = model.visibleItems.first(where: { $0.name == "First.txt" }) else { throw FileOperationFailure.unavailable }
            model.selection = [item.id]
            try await wait { model.externalExportReady }
            guard let captured = model.captureMemberDrag([item.id]), let job = captured.externalExport,
                  let provider = job.provider(for: item, marker: UUID()) else { throw FileOperationFailure.unavailable }
            try UIVerification.require(job.handOff(), "Repeated source did not hand off its first offer")
            model.memberDragDidHandOff(captured)
            let target = try await destination("RepeatedSelection"), hold = Hold(), replies = Replies()
            defer { hold.release() }
            job.beforeRootForVerification = { _ in await hold.pause() }
            let offer = Offered(job: job, providers: [item.name: provider])
            try send(offer, item.name, to: target.appendingPathComponent("Again.txt"), replies, "first")
            try await wait { hold.entered }
            model.memberDragDidEnd(captured)
            try UIVerification.require(!model.externalExportReady, "A busy export offered another writer")
            hold.release()
            try await complete(offer, replies, keys: ["first"])
            try await wait { model.externalExportReady && model.selection == [item.id] }
            guard let next = model.captureMemberDrag([item.id])?.externalExport,
                  next !== job, next.canHandOff, next.provider(for: item, marker: UUID()) != nil else {
                throw UIVerification.Failure(message: "The same selection did not produce a fresh native offer")
            }
            guard let id = job.outcomesForVerification.first?.recordID else { throw FileOperationFailure.unavailable }
            let exact = try await Task.detached {
                try Data(contentsOf: target.appendingPathComponent("Again.txt")) == expected["First.txt"]
            }.value
            try UIVerification.require(exact && replies.values("first") == [true], "Repeated drag changed the first delivery")
            let inverse = await engine.undo(recordID: id)
            try UIVerification.require(inverse.result.disposition == .succeeded, "Repeated drag delivery could not Undo")
            var held: [Offered] = []
            defer { held.forEach { $0.job.retireUncalled() } }
            for _ in 0..<8 { held.append(try await offered(["First.txt", "Last.txt"])) }
            try UIVerification.require(!ApplicationArchiveExports.shared.canOffer, "Pending native offers did not fill their bound")
            model.selection = []; model.selection = [item.id]
            try UIVerification.require(!model.externalExportReady, "A full native offer owner admitted another drag")
            held.removeFirst().job.retireUncalled()
            try await wait { model.externalExportReady && model.selection == [item.id] }
            held.forEach { $0.job.retireUncalled() }; held = []
            await ApplicationZIPBrowser.shared.stopAndDrain()
        }
        // Request order is independent of the archive's listing order.
        do {
            phase = "out-of-order"
            let view = ViewState()
            let target = try await destination("OutOfOrder"),
                offer = try await offered(["First.txt", "Last.txt"], isCurrent: { view.current }, notice: { view.notices.append($0) }),
                replies = Replies()
            linkedExport = offer.job.id
            // Fulfillment must retain the offer's admitted choices even when
            // the review's mutable switch changes before native callbacks.
            ArchivePromiseExportFeature.qualifyingPublications = false
            defer { ArchivePromiseExportFeature.qualifyingPublications = publicPublication }
            let relative = URL(fileURLWithPath: "Receiver Last.txt", isDirectory: false, relativeTo: target)
            try UIVerification.require(relative.baseURL != nil, "Composed native callback did not retain its base")
            try send(offer, "Last.txt", to: relative, replies, "last")
            try send(offer, "First.txt", to: target.appendingPathComponent("Receiver First.txt"), replies, "first")
            try await complete(offer, replies, keys: ["last", "first"])
            try UIVerification.require(replies.values("last") == [true] && replies.values("first") == [true] && offer.job.completedForVerification == 2,
                "Out-of-order callbacks lost a root")
            try UIVerification.require(view.notices.count == 2,
                "The current archive view lost completion notices while its own operation held admission")
            let values = try await Task.detached { [expected] in
                try [Data(contentsOf: target.appendingPathComponent("Receiver Last.txt")) == expected["Last.txt"],
                    Data(contentsOf: target.appendingPathComponent("Receiver First.txt")) == expected["First.txt"]]
            }.value
            try UIVerification.require(values.allSatisfy { $0 }, "Receiver leaf names redirected ZIP identity")
            let history = try await engine.inspectExistingHistory()
            for result in offer.job.outcomesForVerification {
                guard let id = result.recordID else { throw UIVerification.Failure(message: "Root history missing") }
                try UIVerification.require(history.records.first { $0.id == id }?.operation == (format == "zip" ? "Extract ZIP" : "Extract TAR"), "Wrong exact history")
                let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history", isDirectory: true),
                    zipOneFilePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
                    tarOneFilePublicExtractionPolicy: format != "zip" ? .sourceQualification : .held,
                    zipTreePublicExtractionPolicy: publicPublication ? .sourceQualification : .held,
                    tarTreePublicExtractionPolicy: format != "zip" ? .sourceQualification : .held)
                let undone = await cold.undo(recordID: id)
                try UIVerification.require(undone.result.disposition == .succeeded, "Cold root Undo failed")
            }
            checks.append("Native providers retain the marker, use AppKit promise types, serialize out-of-order writes to exact renamed leaves and retain independent cold Undo"
                + (format == "zip" ? "; the same ZIP selection produces a fresh offer after its own accepted export" : ""))
        }
        // The same delegate cannot enqueue a replay while its first request runs.
        do {
            phase = "replay"
            let target = try await destination("Replay"), offer = try await offered(["First.txt"]), replies = Replies(), hold = Hold()
            defer { hold.release() }
            offer.job.beforeRootForVerification = { _ in await hold.pause() }
            try send(offer, "First.txt", to: target.appendingPathComponent("One.txt"), replies, "first")
            try await wait { hold.entered }
            try send(offer, "First.txt", to: target.appendingPathComponent("Replay.txt"), replies, "replay")
            try UIVerification.require(replies.values("replay") == [false], "Replay was not refused immediately")
            hold.release(); try await complete(offer, replies, keys: ["first", "replay"])
            try UIVerification.require(replies.values("first") == [true] && offer.job.completedForVerification == 1, "Replay changed original acknowledgement")
            checks.append("A duplicate native callback fails once without replacing, cancelling or replaying its actual original writer")
        }
        do {
            phase = "partial-conflict"
            let target = try await destination("Partial"), offer = try await offered(["First.txt", "Last.txt", "Folder"]), replies = Replies()
            try await Task.detached { try Data("Existing stays".utf8).write(to: target.appendingPathComponent("Conflict.txt"), options: .withoutOverwriting) }.value
            try send(offer, "First.txt", to: target.appendingPathComponent("Good.txt"), replies, "good")
            try await wait { replies.values("good") == [true] && offer.job.drainedForVerification }
            if let inspection = browser.recoveryInspectionTask { await inspection.value }
            try await wait { browser.operationCoordinator.inspectionCount == 0 }
            try send(offer, "Last.txt", to: target.appendingPathComponent("Conflict.txt"), replies, "conflict")
            try send(offer, "Folder", to: target.appendingPathComponent("Untouched Folder", isDirectory: true), replies, "tail")
            try await complete(offer, replies, keys: ["good", "conflict", "tail"])
            let valid = try await Task.detached { try Data(contentsOf: target.appendingPathComponent("Conflict.txt")) == Data("Existing stays".utf8)
                && Data(contentsOf: target.appendingPathComponent("Good.txt")) == expected["First.txt"]
                && !FileManager().fileExists(atPath: target.appendingPathComponent("Untouched Folder").path) }.value
            try UIVerification.require(valid && replies.values("conflict") == [false] && replies.values("tail") == [false]
                && offer.job.completedForVerification == 1 && replies.errorCodes("conflict") == [CocoaError.fileWriteFileExists.rawValue],
                "Failure changed the verified prefix/conflict/tail or lost its typed receiver error")
            checks.append("A delayed conflict preserves the completed prefix and existing file, fails queued callbacks and retires untouched roots without overwriting")
        }
        do {
            phase = "source-retirement"
            let view = ViewState()
            let target = try await destination("ClosedSource"),
                offer = try await offered(["Folder", "Last.txt"], isCurrent: { view.current }, notice: { view.notices.append($0) }),
                replies = Replies(), hold = Hold()
            defer { hold.release() }
            offer.job.beforeRootForVerification = { _ in await hold.pause() }
            try send(offer, "Folder", to: URL(fileURLWithPath: "Folder", isDirectory: true, relativeTo: target), replies, "folder")
            try await wait { hold.entered }
            view.current = false
            offer.job.retireUncalled()
            try UIVerification.require(!offer.job.drainedForVerification && !offer.job.terminalForVerification && access.active > 0,
                "Source retirement detached accepted work")
            hold.release(); try await complete(offer, replies, keys: ["folder"])
            let tree = try await Task.detached { try Data(contentsOf: target.appendingPathComponent("Folder/Member.txt")) == Data("Generated folder member\n".utf8)
                && FileManager().contentsOfDirectory(atPath: target.appendingPathComponent("Folder/Empty").path).isEmpty }.value
            try UIVerification.require(tree && replies.values("folder") == [true] && view.notices.isEmpty,
                "Accepted folder did not finish after source retirement or changed a newer view's notice")
            try send(offer, "Last.txt", to: target.appendingPathComponent("Late.txt"), replies, "late")
            try await wait { replies.values("late") == [false] }
            checks.append("Source/offer retirement holds accepted folder work and scopes through exact nested/empty publication, refuses stale view notices and fails late uncalled roots")
        }
        do {
            phase = "stop-before-production"
            let target = try await destination("Stopped"), offer = try await offered(["First.txt", "Last.txt"]), replies = Replies(), hold = Hold()
            defer { hold.release() }
            offer.job.beforeRootForVerification = { _ in await hold.pause() }
            try send(offer, "First.txt", to: target.appendingPathComponent("Stopped.txt"), replies, "first")
            try await wait { hold.entered }
            try send(offer, "Last.txt", to: target.appendingPathComponent("Tail.txt"), replies, "tail")
            await Task.yield(); offer.job.stop()
            try UIVerification.require(!offer.job.drainedForVerification, "Stop reported drain before its accepted Task finished")
            hold.release(); try await complete(offer, replies, keys: ["first", "tail"])
            let empty = try await Task.detached { try FileManager().contentsOfDirectory(atPath: target.path).isEmpty }.value
            try UIVerification.require(empty && replies.values("first") == [false] && replies.values("tail") == [false], "Stop started a pending payload")
            checks.append("Stop before production completes pending callbacks with errors and waits for real accepted-task drain, creating no output")
        }
        do {
            phase = "parent-change"
            let first = try await destination("BoundParent"), other = try await destination("OtherParent")
            let offer = try await offered(["First.txt", "Last.txt"]), replies = Replies(), hold = Hold()
            defer { hold.release() }
            offer.job.beforeRootForVerification = { _ in await hold.pause() }
            try send(offer, "First.txt", to: first.appendingPathComponent("One.txt"), replies, "first")
            try await wait { hold.entered }
            try send(offer, "Last.txt", to: other.appendingPathComponent("Other.txt"), replies, "other")
            try await wait { replies.values("other") == [false] }
            hold.release(); try await complete(offer, replies, keys: ["first", "other"])
            let empty = try await Task.detached { try FileManager().contentsOfDirectory(atPath: first.path).isEmpty
                && FileManager().contentsOfDirectory(atPath: other.path).isEmpty }.value
            try UIVerification.require(empty && replies.values("first") == [false], "Changed callback parent widened a drag")
            checks.append("One drag is bound to one observed parent; a callback naming another folder stops unpublished work without a second grant")
        }
        do {
            phase = "busy"
            let view = ViewState()
            let target = try await destination("Busy"), offer = try await offered(["First.txt"], notice: { view.notices.append($0) }),
                replies = Replies(), token = UUID()
            try UIVerification.require(browser.operationCoordinator.beginPreparation(owner: token), "Busy control did not own preparation")
            defer { browser.operationCoordinator.finishPreparation(owner: token) }
            try send(offer, "First.txt", to: target.appendingPathComponent("Busy.txt"), replies, "busy")
            try await complete(offer, replies, keys: ["busy"])
            try UIVerification.require(replies.values("busy") == [false] && view.notices.last?.contains("current file operation") == true,
                "Busy callback entered a second writer or failed without a source-window explanation")
            checks.append("A busy global coordinator refuses the callback without a second writer or an indefinitely queued promise")
        }
        do {
            phase = "posted-callback-retirement"
            let target = try await destination("PostedCallback"), offer = try await offered(["First.txt"]), replies = Replies()
            try send(offer, "First.txt", to: target.appendingPathComponent("Unadmitted.txt"), replies, "posted")
            // No actor yield: the native delegate has posted its Task but the
            // job has not yet received/admitted that callback.
            try UIVerification.require(!offer.job.callbackDispatch.isIdle, "Native callback was not counted before actor dispatch")
            offer.job.retireUncalled()
            try UIVerification.require(!offer.job.terminalForVerification, "Retirement released a posted callback's scope")
            await offer.job.drain()
            try UIVerification.require(replies.values("posted") == [false] && offer.job.terminalForVerification,
                "Posted callback or its scope did not actually drain")
            checks.append("Retirement/quit seals native callback dispatch, waits for already posted actor tasks and completes unadmitted requests before releasing scopes")
        }
        do {
            phase = "invalid-callback-url"
            let offer = try await offered(["First.txt"]), replies = Replies()
            let base = root.appendingPathComponent("state/Refused", isDirectory: true)
            guard let dot = URL(string: "../Outside.txt", relativeTo: base),
                  let same = URL(string: "./Inside.txt", relativeTo: base) else { throw FileOperationFailure.invalidRequest }
            let safe = URL(fileURLWithPath: "Inside.txt", isDirectory: false, relativeTo: base)
            try UIVerification.require(!ArchivePromiseExport.originalPathIsAdmissible(dot)
                && !ArchivePromiseExport.originalPathIsAdmissible(same)
                && ArchivePromiseExport.originalPathIsAdmissible(safe)
                && ArchivePromiseExport.resolvedDestination(dot) == nil,
                "A composed dot component silently changed the callback spelling")
            guard let invalid = URL(string: "https://example.invalid/generated-no-request") else { throw UIVerification.Failure(message: "Invalid-URL control missing") }
            try send(offer, "First.txt", to: invalid, replies, "invalid")
            try await wait { replies.values("invalid") == [false] && offer.job.drainedForVerification }
            try UIVerification.require(offer.job.terminalForVerification && offer.job.outcomesForVerification.isEmpty,
                "Invalid callback URL retained an offer or reached filesystem production")
            checks.append("A non-file callback URL fails without networking or production and retires its offer immediately after dispatch drains")
        }
        do {
            phase = "chosen-parent-session-reuse"
            let originalAccess = browser.folderAccess
            let originalSelectionRule = ArchivePromiseExportFeature.requiresParentGrantForVerification
            defer {
                browser.folderAccess = originalAccess
                ArchivePromiseExportFeature.requiresParentGrantForVerification = originalSelectionRule
            }
            browser.folderAccess = FolderAccessController(backend: access)
            let sourceChoice = await browser.folderAccess.acceptChosenFolder(source.deletingLastPathComponent())
            sourceChoice?.lease.close()
            ArchivePromiseExportFeature.requiresParentGrantForVerification = true
            let target = try await destination("SessionReuse")
            let picker = FolderAccessController(backend: access)
            let cancelled = try await offered(["First.txt"]), cancellation = Replies()
            cancelled.job.chooseParentForVerification = { _ in nil }
            try send(cancelled, "First.txt", to: target.appendingPathComponent("Cancelled.txt"), cancellation, "cancelled")
            try await complete(cancelled, cancellation, keys: ["cancelled"])
            try UIVerification.require(cancellation.values("cancelled") == [false]
                && !browser.folderAccess.hasSelectedAccess(to: target), "Cancelled choice became a session grant")
            let first = try await offered(["First.txt"]), firstReply = Replies()
            first.job.chooseParentForVerification = { await picker.acceptChosenFolder($0) }
            try send(first, "First.txt", to: target.appendingPathComponent("One.txt"), firstReply, "one")
            try await complete(first, firstReply, keys: ["one"])
            try UIVerification.require(firstReply.values("one") == [true] && first.job.parentChoicesForVerification == 1
                && browser.folderAccess.hasSelectedAccess(to: target), "Successful actual choice was not retained for the session")
            let next = try await offered(["Last.txt"]), nextReply = Replies()
            next.job.chooseParentForVerification = { _ in nil }
            try send(next, "Last.txt", to: target.appendingPathComponent("Two.txt"), nextReply, "two")
            try await complete(next, nextReply, keys: ["two"])
            try UIVerification.require(nextReply.values("two") == [true] && next.job.parentChoicesForVerification == 0,
                "A later independent offer unnecessarily asked for the same folder again")
            for result in first.job.outcomesForVerification + next.job.outcomesForVerification {
                guard let record = result.recordID else { throw UIVerification.Failure(message: "Session reuse result missing") }
                try UIVerification.require(await engine.undo(recordID: record).result.disposition == .succeeded,
                    "Session grant reuse changed guarded Undo")
            }
            checks.append("Cancel retains no grant; an actual chosen and checked parent supports the next offer without another chooser, with independent Undo")
        }
        phase = "drain"; await session.close()
        try await wait { ApplicationArchiveExports.shared.countForVerification == 0 && ApplicationFileActivity.gate.activeCount == 0 }
        try UIVerification.require(access.active == baselineAccess, "Export scope starts/stops are unbalanced")
        checks.append("All actual promise owners, accepted tasks, operation activity and counted source/destination scopes drain")
        phase = "diagnostic-links"
        await logger.flush()
        var events: [DiagnosticEvent] = [], cursor: DiagnosticHistoryCursor?
        repeat {
            let page = try await logger.page(before: cursor,limit: 256); events += page.events; cursor = page.next
            try UIVerification.require(events.count <= 2048,"Generated log page bound exceeded")
        } while cursor != nil
        guard let linkedExport else { throw UIVerification.Failure(message: "Linked export trace missing") }
        let roots = events.filter { $0.action == .archiveExtract && $0.phase == .admitted && $0.relatedTrace == linkedExport }
        try UIVerification.require(roots.count == 2 && Set(roots.compactMap(\.count)) == [1,2]
            && events.contains { $0.trace == linkedExport && $0.relatedTrace == sourceTrace && $0.count == 2 },"Drag/export/root links missing")
        for root in roots {
            guard let link = events.first(where: { $0.trace == root.trace && $0.action == .fileOperation && $0.relatedTrace != nil }),
                  let job = link.relatedTrace else { throw UIVerification.Failure(message: "Root engine link missing") }
            try UIVerification.require(events.contains { $0.trace == job && $0.action == .fileOperation && $0.ordinal != nil },"Linked engine did not emit actual stages")
        }
        try UIVerification.require(events.contains { $0.action == .archiveExtract && $0.phase == .failed && $0.error == DiagnosticErrors.operation(.conflict) },"Preparation conflict was reduced to an unknown error")
        let export = root.appendingPathComponent("evidence/archive-diagnostics.jsonl")
        guard case let .saved(count,_,incomplete) = await logger.export(to: export,retainingAccess: "Generated archive logs") else {
            throw UIVerification.Failure(message: "Generated diagnostic export failed")
        }
        let text = try await Task.detached { try String(contentsOf: export,encoding: .utf8) }.value
        try UIVerification.require(count >= events.count && !incomplete && ![root.path,source.lastPathComponent,"First.txt","Receiver Last.txt","Generated first root","Generated folder member"].contains(where: text.contains),"Private workflow inputs escaped to exported logs")
        let errors: [(Error,CocoaError.Code)] = [(FileOperationFailure.accessDenied,.fileWriteNoPermission),
            (FileOperationFailure.outOfSpace,.fileWriteOutOfSpace),(FileOperationFailure.conflict,.fileWriteFileExists),(CancellationError(),.userCancelled)]
        for (error,wanted) in errors {
            try UIVerification.require(ArchivePromiseExport.callbackFailure(error).code == wanted,"Receiver error projection changed")
        }
        checks.append("Actual drag/export/root/engine traces preserve a typed conflict and safe Cocoa errors; exported JSON excludes generated paths, names and bodies")
    }
    private static func wait(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: "Generated promise did not settle at line \(line)") }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    @MainActor private final class Pulse {
        var last = ProcessInfo.processInfo.systemUptime, gap = 0.0, ticks = 0
        func tick() { let now = ProcessInfo.processInfo.systemUptime; gap = max(gap, now - last); last = now; ticks += 1 }
    }
}
#endif
