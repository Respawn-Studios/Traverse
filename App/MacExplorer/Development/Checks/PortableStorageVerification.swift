#if DEBUG
    import AppKit
    import ExplorerCore
    import FileOperations
    import LocalStorage
    import StorageAnalysis

    @MainActor enum PortableStorageVerification {
        static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            try check(
                root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/overnight-foundation").path
                    && root.resolvingSymlinksInPath() == root
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Portable qualification requires its reserved generated case")
            guard let layout = AppStorageLocations.layout, layout.channel == .portable else {
                throw UIVerification.Failure(message: "Generated portable composition was not selected")
            }
            try check(
                layout.stateDirectory.path.hasPrefix(
                    root.appendingPathComponent("source/Library/Application Support").path + "/")
                    && layout.cacheDirectory.path.hasPrefix(
                        root.appendingPathComponent("source/Library/Caches").path + "/"),
                "Portable roots escaped generated OS bases")
            var checks: [String] = []
            let manager = FileManager()
            let file = layout.stateDirectory.appendingPathComponent("preferences.json")
            try check(
                !manager.fileExists(atPath: layout.stateDirectory.path)
                    && !manager.fileExists(atPath: layout.cacheDirectory.path),
                "Passive native startup created private state")
            let empty = await BrowserSettings.loadPortable()
            try check(
                empty.storageStateDirectory?.path == layout.stateDirectory.path
                    && empty.preferencesPersistenceStatus.isEmpty
                    && !manager.fileExists(atPath: layout.stateDirectory.path),
                "Absent bounded read created state or lost its write location")
            checks.append("portable native startup/read stay inert")
            empty.motion.mode = .reduced
            empty.folderSummariesEnabled = false
            await empty.drainPreferencesForVerification()
            let reopened = await BrowserSettings.loadPortable()
            try check(
                reopened.motion.mode == .reduced && !reopened.folderSummariesEnabled
                    && reopened.preferencesPersistenceStatus.isEmpty,
                "Portable save/reopen lost settings")
            checks.append("ordered preferences prepare the finite namespace and reopen")
            let original = try await PortablePreferencesReader().read(file)
            try check(original != nil, "Portable preference snapshot missing")

            // Existing operation and Undo formats use the selected state namespace.
            let coordinator = browser.operationCoordinator
            let engine = coordinator.engine(at: layout.stateDirectory.appendingPathComponent("history"))
            let absent = try await engine.inspectExistingHistory()
            try check(absent.readiness == .absent, "Generated portable history was not absent")
            try await coordinator.prepareOperationState(for: engine)
            let source = root.appendingPathComponent("source/Scan Root")
            let operationRoot = root.appendingPathComponent("source/Operation Root")
            let created = await engine.perform(.createFolder(parent: operationRoot, name: "Generated Operation Folder"))
            guard created.result.disposition == .succeeded, let record = created.recordID else {
                throw UIVerification.Failure(message: "Portable first operation failed")
            }
            let undone = await engine.undo(recordID: record)
            try check(
                undone.result.disposition == .succeeded
                    && !manager.fileExists(
                        atPath: operationRoot.appendingPathComponent("Generated Operation Folder").path),
                "Portable operation Undo did not restore the generated fixture")
            checks.append("portable history retains existing Create Folder/Undo protocol")

            let analysis = ApplicationStorageAnalysis.shared
            let owner = UUID()
            analysis.analyzeProperties(
                owner: owner, root: source, access: { "Generated local metadata only" }, onChange: { _, _ in })
            try await wait("Portable stored scan did not finish") {
                !analysis.hasWork && analysis.pagedResultForVerification != nil
            }
            guard let result = analysis.pagedResultForVerification else {
                throw UIVerification.Failure(message: "Portable scan result missing")
            }
            let summary = try await result.summary()
            try check(
                summary.value.counts.regularFiles == 2 && manager.fileExists(atPath: layout.analysisDirectory.path),
                "Portable scanner did not use its cache namespace")
            analysis.closeProperties(owner: owner)
            await analysis.stopAndDrain()
            checks.append("actual bundled scanner and stored results use separate portable caches")

            let network = ApplicationSMBConnections.shared
            network.present(in: browser, offscreen: true)
            try check(
                ApplicationSMBConnections.protectedStorageLocations.contains { $0.path == layout.smbDirectory.path },
                "Portable connection cache was not registered for removal protection")
            await network.closeAndDrain()
            try check(
                !manager.fileExists(atPath: layout.smbDirectory.path), "Passive Connect setup created a network catalog"
            )
            checks.append("Connect registers the cache root without network or credential access")

            let hold = PortableReadHold()
            let reader = PortablePreferencesReader(beforeRead: { hold.pause() })
            var completed = false
            var cancelled = false
            let reading = Task {
                do { _ = try await reader.read(file) } catch is CancellationError { cancelled = true } catch {}
                completed = true
            }
            try await wait("Controlled portable read did not enter") { hold.entered }
            reading.cancel()
            try await Task.sleep(for: .milliseconds(30))
            try check(!completed, "Cancellation abandoned a still-running preferences read")
            hold.release()
            await reading.value
            try check(cancelled && completed, "Cancelled preferences read published its late result")
            checks.append("cancelled background read waits for actual worker completion")

            let oversized = layout.stateDirectory.appendingPathComponent("oversized.json")
            let link = layout.stateDirectory.appendingPathComponent("linked.json")
            try await Task.detached {
                try Data(repeating: 65, count: 131_073).write(to: oversized, options: .withoutOverwriting)
                try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.path)
                try FileManager().createSymbolicLink(at: link, withDestinationURL: file)
            }.value
            for candidate in [oversized, link] {
                var refused = false
                do { _ = try await PortablePreferencesReader().read(candidate) } catch { refused = true }
                try check(refused, "Unsafe/oversized portable preferences were admitted")
            }
            checks.append("oversized and symlink snapshots refuse without repair")

            // A newer on-disk preference document is preserved and cannot be saved
            // through the session-only model created for that failed read.
            try await Task.detached {
                try Data("{\"version\":999}".utf8).write(to: file, options: .atomic)
                try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }.value
            let newer = await BrowserSettings.loadPortable()
            try check(
                !newer.canPersistCopyPreview && !newer.preferencesPersistenceStatus.isEmpty,
                "Newer portable preferences were writable")
            newer.motion.mode = .off
            await newer.drainPreferencesForVerification()
            let retained = try await PortablePreferencesReader().read(file)
            try check(
                retained == Data("{\"version\":999}".utf8), "Session-only change overwrote a newer preference document")
            checks.append("newer settings preserved with session-only edits")
            try check(ApplicationFileActivity.gate.activeCount == 0, "Portable local activity did not drain")
            return [
                "passed": true, "checks": checks, "metadataOnlyScan": true, "networkConnections": 0,
                "keychainQueries": 0,
                "personalProfileReads": 0, "appSandboxQualified": false, "developmentMigration": false,
                "localActivityAfterDrain": ApplicationFileActivity.gate.activeCount,
            ]
        }
        private static func check(_ condition: Bool, _ message: String) throws {
            try UIVerification.require(condition, message)
        }
        private static func wait(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw UIVerification.Failure(message: message)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private final class PortableReadHold: @unchecked Sendable {
        private let condition = NSCondition()
        private var started = false, released = false
        var entered: Bool {
            condition.lock()
            defer { condition.unlock() }
            return started
        }
        func pause() {
            condition.lock()
            defer { condition.unlock() }
            started = true
            while !released { if !condition.wait(until: Date().addingTimeInterval(3)) { return } }
        }
        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }
#endif
