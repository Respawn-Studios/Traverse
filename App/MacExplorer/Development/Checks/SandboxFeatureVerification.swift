#if DEBUG
    import AppKit
    import CryptoKit
    import Darwin
    import ExplorerCore
    import FileMemory
    import FileOperations
    import LocalStorage

    /// Real sandbox feature interfaces, only after the enclosing exact-case,
    /// signature/container checks. No production feature or access policy changes.
    @MainActor enum SandboxFeatureVerification {
        private static var currentOwner: ApplicationPrivateNames?
        private static var checks: [String] = []

        static func stopAndDrain() async {
            if let currentOwner { await currentOwner.close() }
            currentOwner = nil
        }

        static func run(
            root: URL, layout: ApplicationStorageLayout, browser: BrowserViewController,
            access: any Sendable
        ) async throws -> [String: Any] {
            checks = []
            let files = root.appendingPathComponent("source/Feature Root")
            let kept = files.appendingPathComponent("Kept.txt")
            let forgotten = files.appendingPathComponent("Forgotten.txt")
            let names = layout.stateDirectory.appendingPathComponent("private-names")
            let owner = ApplicationPrivateNames(directory: names, settings: browser.settings)
            currentOwner = owner
            stage("remember-consent")
            try require(!browser.settings.privateNamesAllowFollowing, "Generated following consent was already enabled")
            let editor = PrivateNamesEditorModel(owner: owner, settings: browser.settings, access: { _ in access })
            editor.select(kept)
            try await wait { !editor.loading }
            editor.nickname = "Sandbox Orion"
            editor.alternateDraft = "Generated reference"
            editor.labelDraft = "sandbox-check"
            editor.save()
            try await wait { !editor.saving && editor.showsConsent }
            let before = try await Task.detached {
                (!FileManager().fileExists(atPath: names.path), try tracked(kept))
            }.value
            try require(before.0 && !before.1, "Remember consent created catalog or enabled tracking early")
            editor.allowAndSave()
            try await wait { !editor.saving && !editor.loading && editor.itemID != nil }
            guard let id = editor.itemID else {
                throw UIVerification.Failure(message: "Generated Remember has no record")
            }
            editor.cancel()
            try require(
                try await Task.detached { try tracked(kept) }.value, "Explicit sandbox Remember did not enable tracking"
            )
            try require(
                try await matching(owner, "Sandbox Orion").map(\.item.id) == [id], "Saved nickname search differs")
            try require(
                try await matching(owner, "Generated reference").map(\.item.id) == [id], "Alternate-name search differs"
            )
            try require(
                try await matching(owner, "sandbox-check").map(\.item.id) == [id], "Private-label search differs")
            completed("explicit native consent, tracking and direct nickname/alternate/label search")

            stage("same-volume-move")
            let engine = browser.operationCoordinator.engine(
                at: layout.stateDirectory.appendingPathComponent("history-local-features-v1"))
            try await browser.operationCoordinator.prepareOperationState(for: engine)
            let moved = await engine.perform(
                .move(sources: [kept], destinationDirectory: files.appendingPathComponent("Move Target")))
            failures(moved)
            guard moved.result.disposition == .succeeded, let moveID = moved.recordID else {
                throw UIVerification.Failure(message: "Generated sandbox Move failed")
            }
            let movedURL = files.appendingPathComponent("Move Target/Kept.txt")
            try require(
                try await owner.entry(id).url == movedURL, "Saved reference did not follow the verified moved document")
            let undone = await engine.undo(recordID: moveID)
            failures(undone)
            let restored = try await owner.entry(id)
            try require(
                undone.result.disposition == .succeeded && restored.url == kept,
                "Generated Move Undo or saved reference failed")
            completed("same-volume generated Move and exact Undo preserve native reference")

            stage("forget")
            let forgottenID = try await owner.save(
                AuthoredNames(nickname: "Sandbox Disposable"), source: forgotten,
                id: nil, revision: nil, access: access, allowFollowing: true)
            try require(try await owner.forget(forgottenID) == .forgotten, "Generated Forget did not finish durably")
            try require(
                try await matching(owner, "Sandbox Disposable").isEmpty, "Forgotten nickname is still published")
            completed("durable Forget removes description while leaving generated source")
            await stopAndDrain()

            stage("zip-browse-preview-extract")
            try await archives(files: files, engine: engine, access: access)
            let ready = layout.stateDirectory.appendingPathComponent("sandbox-local-feature-ready-v1")
            try await Task.detached {
                try Data("sandbox-local-feature-v1".utf8).write(to: ready, options: .withoutOverwriting)
            }.value
            return try await finish(phase: "features")
        }

        static func reopen(root: URL, layout: ApplicationStorageLayout, browser: BrowserViewController) async throws
            -> [String: Any]
        {
            checks = []
            stage("fresh-process-denial")
            let files = root.appendingPathComponent("source/Feature Root")
            let kept = files.appendingPathComponent("Kept.txt")
            let unrelated = files.appendingPathComponent("Forgotten.txt")
            let ready = layout.stateDirectory.appendingPathComponent("sandbox-local-feature-ready-v1")
            let admitted = try await Task.detached {
                try Data(contentsOf: ready) == Data("sandbox-local-feature-v1".utf8)
            }.value
            try require(admitted, "Completed generated first-phase marker absent")
            let denied = await Task.detached { deniedOpen(kept) && deniedOpen(unrelated) }.value
            try require(denied, "Fresh sandbox process unexpectedly has the previous chooser grant")
            completed("fresh process initially denies direct access without chooser")
            let owner = ApplicationPrivateNames(
                directory: layout.stateDirectory.appendingPathComponent("private-names"),
                settings: browser.settings)
            currentOwner = owner
            stage("saved-reference-resolution")
            let matches = try await matching(owner, "Sandbox Orion")
            guard matches.count == 1, let id = matches.first?.item.id else {
                throw UIVerification.Failure(message: "Fresh private catalog lost its saved description")
            }
            try require(
                try await matching(owner, "Sandbox Disposable").isEmpty, "Forgotten description returned after restart")
            let rights = try await owner.use(id) { url in
                await Task.detached {
                    let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
                    let readable = fd >= 0
                    if fd >= 0 { close(fd) }
                    let write = open(url.path, O_WRONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
                    let code = errno
                    if write >= 0 { close(write) }
                    return readable && write < 0 && (code == EACCES || code == EPERM) && deniedOpen(unrelated)
                }.value
            }
            try require(rights, "Saved read-only reference rights or unrelated-source denial differ")
            try require(try await owner.entry(id).url == kept, "Fresh native reference failed metadata validation")
            completed("saved file bookmark grants read-only access; unrelated file stays denied")
            stage("remove-access-and-forget")
            try await owner.removeAccess(id)
            try require(
                try await owner.availability(id).availability == .accessRemoved,
                "Remove Access retained actionable reference")
            try require(try await matching(owner, "Sandbox Orion").count == 1, "Remove Access lost the description")
            try require(try await owner.forget(id) == .forgotten, "Final generated Forget remains incomplete")
            try require(try await matching(owner, "Sandbox Orion").isEmpty, "Final Forget retained a direct name hit")
            await stopAndDrain()
            completed("Remove Access retains names; final Forget and catalog drain complete")
            return try await finish(phase: "reference-reopen")
        }

        private static func archives(files: URL, engine: RecoverableFileOperations, access: any Sendable) async throws {
            let archive = files.appendingPathComponent("Generated.zip")
            let before = try await digest(archive)
            let reader = ZIPArchiveReader(
                activity: ApplicationFileActivity.gate, excludedRoots: AppStorageLocations.protectedDirectories)
            let session = try await reader.open(archive, retaining: access)
            let page = try await session.page(in: session.root)
            guard session.summary.files == 2, let text = page.items.first(where: { $0.name == "Readme.txt" }) else {
                throw UIVerification.Failure(message: "Generated sandbox ZIP metadata differs")
            }
            let selected = try await session.selectionForTextPreview(text.id)
            let preview = try await reader.previewText(selected, retaining: access)
            try require(preview.text == "Generated sandbox ZIP preview.\n", "Generated selected ZIP preview differs")
            await session.close()
            await reader.drain()
            completed("bounded ZIP metadata browsing and explicit checked selected text")
            let selection = try await engine.observeSelection([archive])
            let plan = try await engine.prepareZIPExtraction(
                source: archive, parent: files.appendingPathComponent("Operations"),
                name: "Sandbox Extracted", observing: selection)
            try require(plan.files == 2 && plan.folders == 1, "Generated ZIP extraction preview totals differ")
            let result = await engine.performArchiveExtraction(plan)
            failures(result)
            guard result.result.disposition == .succeeded, let id = result.recordID else {
                throw UIVerification.Failure(message: "Generated sandbox ZIP extraction failed")
            }
            let exact = try await Task.detached {
                try Data(contentsOf: plan.destination.appendingPathComponent("Readme.txt"))
                    == Data("Generated sandbox ZIP preview.\n".utf8)
                    && Data(contentsOf: plan.destination.appendingPathComponent("Nested/Child.txt"))
                        == Data("Generated sandbox ZIP extraction.\n".utf8)
            }.value
            try require(exact, "Generated ZIP extraction bytes differ")
            let undo = await engine.undo(recordID: id)
            failures(undo)
            let absent = await Task.detached { !FileManager().fileExists(atPath: plan.destination.path) }.value
            try require(
                undo.result.disposition == .succeeded && absent, "Sandbox ZIP Undo did not remove its exact output")
            try require(try await digest(archive) == before, "Sandbox ZIP source changed")
            completed("guarded ZIP extraction, exact Undo and unchanged source")
        }

        private static func matching(_ owner: ApplicationPrivateNames, _ text: String) async throws
            -> [RememberedNameMatch]
        {
            guard let pair = try await owner.list(query: text) else { return [] }
            var result: [RememberedNameMatch] = []
            try require(pair.0.publish { result = $0 }, "Generated name page publication refused")
            withExtendedLifetime(pair.1) {}
            return result
        }
        private nonisolated static func tracked(_ url: URL) throws -> Bool {
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                throw UIVerification.Failure(message: "Generated tracking observation failed")
            }
            return value.st_flags & UInt32(UF_TRACKED) != 0
        }
        private nonisolated static func deniedOpen(_ url: URL) -> Bool {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
            let code = errno
            if fd >= 0 { close(fd) }
            return fd < 0 && (code == EACCES || code == EPERM)
        }
        private static func digest(_ url: URL) async throws -> Data {
            try await Task.detached {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 64 << 10 else {
                    throw UIVerification.Failure(message: "Generated archive grew beyond fixture bounds")
                }
                return Data(SHA256.hash(data: try Data(contentsOf: url)))
            }.value
        }
        private static func stage(_ text: String) { SandboxFoundationVerification.setFeatureStage(text) }
        private static func completed(_ text: String) {
            checks.append(text)
            SandboxFoundationVerification.setFeatureChecks(checks)
        }
        private static func failures(_ result: RecoverableOperationResult) {
            SandboxFoundationVerification.setFeatureFailures(
                result.result.items.compactMap {
                    if case .failed(let code) = $0.status { return code.rawValue }
                    return nil
                })
        }
        private static func finish(phase: String) async throws -> [String: Any] {
            try await wait { ApplicationFileActivity.gate.activeCount == 0 }
            return [
                "passed": true, "phase": phase, "checks": checks, "localFeaturePacket": true,
                "localActivityAfterDrain": 0, "personalFiles": 0, "networkRequests": 0, "keychainQueries": 0,
                "remembranceFileBodyReads": 0, "physicalInput": false, "testFlightQualified": false,
            ]
        }
        private static func require(_ value: Bool, _ text: String) throws { try UIVerification.require(value, text) }
        private static func wait(_ predicate: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + 20
            while !predicate() {
                try require(ProcessInfo.processInfo.systemUptime < end, "Generated sandbox feature did not settle")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
#endif
