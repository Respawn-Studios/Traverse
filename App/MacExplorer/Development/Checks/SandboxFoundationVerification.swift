#if DEBUG
    import AppKit
    import Darwin
    import ExplorerCore
    import FileOperations
    import LocalStorage
    import Security
    import StorageAnalysis

    /// Isolated signed sandbox artifact only. No authority is inferred from paths,
    /// descriptors, an entitlements dictionary or a successful bookmark resolution.
    @MainActor enum SandboxFoundationVerification {
        static private(set) var failureDetails: [String: Any] = [:]
        static func setFeatureStage(_ text: String) { failureDetails["featureStage"] = text }
        static func setFeatureChecks(_ checks: [String]) { failureDetails["completedChecks"] = checks }
        static func setFeatureFailures(_ codes: [String]) { failureDetails["operationFailureCodes"] = codes }
        static func run(root: URL, phase: String, browser: BrowserViewController) async throws -> [String: Any] {
            failureDetails = [:]
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let identifier = "local.macexplorer.sandbox.qualification"
            try require(
                ["bootstrap", "grant", "features", "reference-reopen"].contains(phase)
                    && root.deletingLastPathComponent().path
                        == repo.appendingPathComponent(".build/distribution-qualification").path
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
                    && Bundle.main.bundleIdentifier == identifier
                    && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String
                        == root.lastPathComponent,
                "Sandbox qualification requires its exact built case and identity")
            try require(!SMBConnectionFeature.ordinaryEnabled, "Local sandbox test exposed network setup")
            let sandbox = await Task.detached { () -> Bool in
                var code: SecCode?
                var staticCode: SecStaticCode?
                var information: CFDictionary?
                guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                    SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                    SecCodeCopySigningInformation(
                        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                        == errSecSuccess,
                    let fields = information as? [String: Any],
                    let rights = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
                else { return false }
                let expected: Set<String> = [
                    "com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write",
                    "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.client",
                ]
                return Set(rights.keys) == expected && expected.allSatisfy { rights[$0] as? Bool == true }
            }.value
            try require(sandbox, "Actual parent sandbox rights differ from the reviewed four-key policy")
            guard let layout = AppStorageLocations.layout, layout.channel == .portable else {
                throw UIVerification.Failure(message: "Actual sandbox portable roots unavailable")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            try require(
                home.path.contains("/Library/Containers/" + identifier + "/Data")
                    && layout.stateDirectory.path.hasPrefix(home.path + "/Library/Application Support/")
                    && layout.cacheDirectory.path.hasPrefix(home.path + "/Library/Caches/"),
                "Foundation did not compose private roots inside the qualification container")
            let marker = layout.stateDirectory.appendingPathComponent("sandbox-qualification-owner-v1.json")
            let source = root.appendingPathComponent("source/Scan Root")
            var checks = [
                "actual four-key sandbox signature", "OS-selected portable container roots",
                "network setup unavailable",
            ]
            if phase == "bootstrap" {
                let before = await Task.detached { () -> (Bool, Bool, Bool) in
                    let manager = FileManager()
                    let absent =
                        !manager.fileExists(atPath: layout.stateDirectory.path)
                        && !manager.fileExists(atPath: layout.cacheDirectory.path)
                    let descriptor = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
                    let code = errno
                    if descriptor >= 0 { close(descriptor) }
                    return (absent, descriptor < 0, code == EACCES || code == EPERM)
                }.value
                try require(
                    before.0 && before.1 && before.2,
                    "Passive startup created state or generated source unexpectedly opened before a grant")
                checks.append("inert startup and actual pre-grant denial; no cause inferred")
                browser.settings.motion.mode = .reduced
                browser.settings.folderSummariesEnabled = false
                await browser.settings.drainPreferencesForVerification()
                let reopened = await BrowserSettings.loadPortable()
                try require(
                    reopened.motion.mode == .reduced && !reopened.folderSummariesEnabled
                        && reopened.preferencesPersistenceStatus.isEmpty,
                    "Actual sandbox preferences failed Save/reopen")
                try await Task.detached {
                    let bytes = try JSONSerialization.data(withJSONObject: [
                        "version": 1, "case": root.lastPathComponent,
                    ])
                    try bytes.write(to: marker, options: .withoutOverwriting)
                    try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                }.value
                checks.append("explicit private preferences Save/reopen and exact case marker")
            } else {
                guard let owner = try await PortablePreferencesReader().read(marker),
                    let fields = try JSONSerialization.jsonObject(with: owner) as? [String: Any],
                    fields["case"] as? String == root.lastPathComponent
                else {
                    throw UIVerification.Failure(message: "Sandbox container does not belong to this reserved case")
                }
                if phase == "reference-reopen" {
                    return try await SandboxFeatureVerification.reopen(root: root, layout: layout, browser: browser)
                }
                guard let window = browser.view.window else {
                    throw UIVerification.Failure(message: "Generated sandbox window missing")
                }
                window.title = "Sandbox foundation · choose generated case only"
                let access = FolderAccessController(
                    stateDirectory: layout.stateDirectory.appendingPathComponent("qualification-access"))
                guard let choice = await access.chooseFolder(in: window, initialDirectory: root, remember: false) else {
                    throw UIVerification.Failure(message: "Generated folder grant was cancelled")
                }
                defer { choice.lease.close() }
                try require(choice.selection.url.path == root.path, "Only the exact generated case may be selected")
                if phase == "features" {
                    return try await SandboxFeatureVerification.run(
                        root: root, layout: layout, browser: browser,
                        access: choice.lease)
                }
                let granted = choice.selection.url.appendingPathComponent("source/Scan Root")
                let fileSystem = LocalFileSystem(activityGate: ApplicationFileActivity.gate)
                var names = Set<String>()
                for try await event in fileSystem.entries(in: granted, showHidden: true, retaining: choice.lease) {
                    if case .batch(let entries) = event { names.formUnion(entries.map(\.name)) }
                }
                try require(
                    names == ["Generated.txt", "Generated.swift", "Nested"], "Granted native metadata listing differs")
                checks.append("system chooser grants exact generated case; native metadata listing")
                try await AppStoragePreparation.preparePortableCache()
                let storage = try AnalysisResultStorage(
                    directory: layout.analysisDirectory, sessionByteLimit: 8 << 20, poolByteLimit: 16 << 20)
                let analysis = ApplicationStorageAnalysis.shared
                analysis.enablePagedForQualification(storage: storage)
                let request = UUID()
                analysis.analyzeProperties(
                    owner: request, root: granted, access: { choice.lease }, onChange: { _, _ in })
                try await wait("Actual sandbox scanner did not seal a result") {
                    !analysis.hasWork && analysis.pagedResultForVerification != nil
                }
                try await verifySummary(analysis)
                analysis.closeProperties(owner: request)
                await analysis.stopAndDrain()
                checks.append("actual inheriting Rust worker, temporary SQLite and stored summary; readers drain")
                failureDetails["completedChecks"] = checks
                let operationRoot = choice.selection.url.appendingPathComponent("source/Operation Root")
                let probe = GeneratedSandboxCopyProbe()
                let journal = layout.stateDirectory.appendingPathComponent("history-quarantine-" + UUID().uuidString)
                let protection = AppStorageLocations.protectedDirectories
                let preparation = try AppStoragePreparation.owner(for: layout.stateDirectory)
                try await preparation.prepare()
                let engine = try await Task.detached {
                    try RecoverableFileOperations.generatedSandboxCopySession(
                        in: root, journal: journal,
                        probe: probe, protecting: protection, activity: ApplicationFileActivity.beginOperation)
                }.value
                let copied = await engine.perform(
                    .copy(
                        sources: [granted.appendingPathComponent("Generated.txt")], destinationDirectory: operationRoot)
                )
                failureDetails["copySecurityObservations"] = probe.snapshot()
                failureDetails["copyFailureCodes"] = copied.result.items.compactMap { item -> String? in
                    if case .failed(let code) = item.status { return code.rawValue }
                    return nil
                }
                guard copied.result.disposition == .succeeded, let copyID = copied.recordID else {
                    throw UIVerification.Failure(message: "Granted sandbox Copy failed its existing verification")
                }
                let equal = try await Task.detached {
                    try Data(contentsOf: operationRoot.appendingPathComponent("Generated.txt"))
                        == Data(contentsOf: granted.appendingPathComponent("Generated.txt"))
                }.value
                try require(equal, "Tiny generated sandbox Copy bytes differ")
                let copyUndo = await engine.undo(recordID: copyID)
                try require(copyUndo.result.disposition == .succeeded, "Sandbox Copy Undo failed")
                let made = await engine.perform(
                    .createFolder(parent: operationRoot, name: "Generated Operation Folder"))
                guard made.result.disposition == .succeeded, let makeID = made.recordID else {
                    throw UIVerification.Failure(message: "Sandbox Create Folder failed")
                }
                let makeUndo = await engine.undo(recordID: makeID)
                try require(makeUndo.result.disposition == .succeeded, "Sandbox Create Folder Undo failed")
                checks.append("existing guarded Copy/Create Folder and exact Undo")
            }
            try await wait("Sandbox local activity did not actually drain") {
                ApplicationFileActivity.gate.activeCount == 0
            }
            return [
                "passed": true, "phase": phase, "checks": checks, "localActivityAfterDrain": 0,
                "copySecurityObservations": failureDetails["copySecurityObservations"] ?? [],
                "personalFiles": 0, "networkRequests": 0, "keychainQueries": 0, "appStoreProvisioningQualified": false,
            ]
        }
        private static func verifySummary(_ analysis: ApplicationStorageAnalysis) async throws {
            guard let result = analysis.pagedResultForVerification else {
                throw UIVerification.Failure(message: "Sandbox result absent")
            }
            let summary = try await result.summary()
            try require(
                summary.value.counts.regularFiles == 3, "Sandbox scanner did not observe all generated nested files")
            await result.waitUntilReadersDrained()
        }
        private static func require(_ value: Bool, _ message: String) throws {
            try UIVerification.require(value, message)
        }
        private static func wait(_ message: String, _ predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !predicate() {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw UIVerification.Failure(message: message)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
#endif
