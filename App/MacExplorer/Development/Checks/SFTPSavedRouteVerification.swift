#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Exact signed-parent/worker/storage checks, optionally using the actual trust
/// and challenge windows. Recorded appearance is a separate motion gate.
@MainActor enum SFTPSavedRouteVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var number = 0
        func increment() { lock.withLock { number += 1 } }
        var value: Int { lock.withLock { number } }
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    static func run() async {
        var root: URL?, checkpoint = "scope", browser: SFTPBrowserSession?, model: SMBConnectModel?
        var ticker: Task<Void, Never>?, maximumGap = 0.0, phase = "unknown"
        var remembered: SFTPRememberedState?, closure: SFTPWorkerClose?
        var visibleForm: SMBConnectWindowController?, driver: Task<Void, Error>?
        let trust = SFTPSetupTrust(), prompts = SFTPSetupInteractive()
        let calls = Count()
        do {
            let arguments = ProcessInfo.processInfo.arguments
            func argument(_ name: String) throws -> String {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { throw Failure.scope }; return arguments[index + 1]
            }
            guard arguments.contains("--offscreen"), let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath: path), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "ssh-native-saved-route"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = location; phase = try argument("--generated-phase")
            try require(["seed", "reconnect", "passwords"].contains(phase))
            let passwords = phase == "passwords", memory = phase == "passwords" ? SFTPInMemoryPasswordQualification() : nil
            guard let port = UInt16(try argument("--generated-port")), port > 0,
                  let targetPort = UInt16(try argument("--generated-target-port")), targetPort > 0 else { throw Failure.scope }
            let outerFingerprint = try argument("--generated-fingerprint"), innerFingerprint = try argument("--generated-target-fingerprint")
            let factor = arguments.contains("--generated-both-factors")
            let visible = arguments.contains("--visible-reviews")
            let ordinaryFlags = arguments.contains("--ordinary-flags")
            try require(!passwords || !factor)
            for currentPhase in passwords ? ["seed", "reconnect"] : [phase] {
            phase = currentPhase; browser = nil; maximumGap = 0
            let storage = try SMBTemporaryStorage(directory: location.appendingPathComponent("state/Native/catalogs"))
            let activity = FileActivityGate(), pool = SMBTemporaryCatalogPool(storage: storage)
            let state = SFTPRememberedState(settings: .init(directory: location.appendingPathComponent("state/Native/settings")),
                passwords: memory?.vault ?? .refusingQualification { calls.increment() }); remembered = state
            let coordinator = SFTPConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: storage, remembered: state, activity: activity)
            let settings = BrowserSettings(persist: false)
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            InterfacePresentation.shared.bind(settings)
            var reviews = 0, challengeCount = 0, opened = false, outcome: SFTPRememberingStatus = .notRequested
            if visible {
                try prompts.beginConnection()
                visibleForm = SMBConnectWindowController(settings: settings) { _, _ in throw Failure.scope }
            }
            let form = visibleForm?.model ?? SMBConnectModel { _, _ in throw Failure.scope }; model = form
            form.onConnected = {}; form.onCancelled = {}
            if ordinaryFlags { try require(form.routeFeaturesAvailable && form.profileFeaturesAvailable && form.serverPromptsAvailable && form.sshProfiles.singleJumpAvailable) }
            form.routeFeaturesAvailable = true; form.profileFeaturesAvailable = true; form.serverPromptsAvailable = true
            form.sftpHandler = { submission, _ in
                guard let route = submission.route, let outer = submission.jumpAuthentication, let inner = submission.authentication else { throw Failure.scope }
                let result = try await coordinator.connectRoute(route, jumpAuthentication: outer, destinationAuthentication: inner,
                    savedRouteID: submission.editingRoute, remember: submission.rememberServer,
                    rememberJumpPassword: submission.rememberJumpPassword, rememberDestinationPassword: submission.rememberPassword,
                    serverPrompts: { @MainActor role, session, challenge in
                        guard challenge.session == session.review.session && challenge.host == session.review.host else { return nil }
                        challengeCount += 1
                        if visible { return await prompts.review(session, challenge: challenge, settings: settings, owner: visibleForm?.window) }
                        return try? .init(challenge.prompts.map { challenge.round == 2 ? "654321" : $0.echo ? "generated" : "123456" })
                    }, review: { @MainActor role, session in
                        do {
                            try require(session.review.current.fingerprint == (role == .jump ? outerFingerprint : innerFingerprint))
                            try require(session.review.kind == (phase == "seed" ? .first : .matching))
                            if visible {
                                if role == .destination { try require(await prompts.dismissAuthenticated()) }
                                let reviewed = await trust.reviewRoute(session, heading: role == .jump ? "Verify jump host" : "Verify destination server",
                                    settings: settings, owner: visibleForm?.window)
                                try require(reviewed.verified)
                            } else { try await session.approve(phase == "seed" ? .connectOnce : .useMatching) }
                            reviews += 1; return true
                        } catch { return false }
                    })
                if visible { try require(await prompts.dismissAuthenticated()) }
                outcome = result.remembering.server
                return .init(server: result.remembering.server == .complete ? .saved : .notRequested, password: result.remembering.password == .complete ? .saved : .notRequested,
                    keyAccess: result.remembering.keyAccess == .complete ? .saved : .notRequested,
                    open: { browser = result.session; opened = true }, discard: { await result.session.close().localResourcesEnded })
            }
            form.connectionProtocol = .sftp
            if phase == "seed" {
                form.address = "sftp://private.internal.test:\(targetPort)/generated"; form.account = "generated"; form.name = "Generated saved route"
                form.jumpHost.enabled = true; form.jumpHost.address = "sftp://127.0.0.1:\(port)"; form.jumpHost.account = "generated"
                let key = try SFTPSelectedPrivateKey(file: location.appendingPathComponent("source/client-key"))
                form.sftpAuthentication = .keyFile; form.selectedKey = key; form.selectedKeyName = "Generated client key"
                form.jumpHost.method = .keyFile; form.jumpHost.selectedKey = key; form.jumpHost.keyName = "Generated jump key"
                form.rememberServer = true; form.rememberKeyAccess = true; form.jumpHost.rememberKey = true
                form.extraServerPrompts = factor; form.jumpHost.extraPrompts = factor
                if passwords {
                    form.sftpAuthentication = .password; form.jumpHost.method = .password
                    form.password = "ephemeral qualification password"; form.jumpHost.password = "ephemeral qualification password"
                    form.rememberPassword = true; form.jumpHost.rememberPassword = true
                }
            } else {
                guard let saved = try await state.inspect()?.visibleRoutes.first else { throw Failure.scope }
                form.replaceSFTPServers([.init(id: saved.id, details: saved.details.destination, hasSavedPassword: passwords, route: saved, jumpHasSavedPassword: passwords)])
                form.choose(saved.id); form.rememberServer = false
                try require(form.selectedKey == nil && form.jumpHost.selectedKey == nil)
                try require(passwords ? !form.savedKeyAvailable && !form.jumpHost.savedKeyAvailable : form.savedKeyAvailable && form.jumpHost.savedKeyAvailable)
                try require(form.extraServerPrompts == factor && form.jumpHost.extraPrompts == factor)
            }
            form.keyPassphrase = "generated-only-not-a-secret"; form.jumpHost.passphrase = "generated-only-not-a-secret"
            if visible {
                visibleForm?.window?.title = "Saved jump connection · generated qualification"
                visibleForm?.present(); NSApplication.shared.activate(ignoringOtherApps: true)
            }
            var tick = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - tick); tick = now
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            } }
            checkpoint = "native-form-admission"; form.connect()
            var promptedWindows: [UUID: Int] = [:], typedRounds = Set<String>(), reviewedWindows = Set<ObjectIdentifier>()
            if visible {
                driver = Task { @MainActor in
                    while form.busy {
                        if let controller = trust.controller, !controller.model.busy, controller.model.finished == nil,
                           reviewedWindows.insert(ObjectIdentifier(controller)).inserted {
                            controller.model.proceed()
                        }
                        if let controller = prompts.controller, controller.model.phase == .input,
                           SFTPInteractiveConnectionVerification.fieldsReady(controller),
                           !typedRounds.contains(controller.model.challenge.id), let window = controller.window {
                            let challenge = controller.model.challenge
                            if let previous = promptedWindows[challenge.session] { try require(previous == window.windowNumber) }
                            else { promptedWindows[challenge.session] = window.windowNumber }
                            typedRounds.insert(challenge.id)
                            for (index, prompt) in challenge.prompts.enumerated() {
                                try SFTPInteractiveConnectionVerification.enterResponse(challenge.round == 2 ? "654321" : prompt.echo ? "generated" : "123456", at: index, in: controller)
                            }
                            try SFTPInteractiveConnectionVerification.pressReturn(window)
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            try require(form.password.isEmpty && form.keyPassphrase.isEmpty && form.jumpHost.password.isEmpty && form.jumpHost.passphrase.isEmpty)
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            while form.busy { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(10)) }
            try await driver?.value; driver = nil
            try require(opened && form.connected && reviews == 2 && challengeCount == (factor ? 4 : 0))
            if visible {
                try require(reviewedWindows.count == 2 && typedRounds.count == (factor ? 4 : 0)
                    && promptedWindows.count == (factor ? 2 : 0) && prompts.controller == nil && trust.controller == nil)
            }
            checkpoint = "metadata-and-saved-state"
            guard let browser else { throw Failure.scope }
            _ = try await browser.navigate(pathUTF8: Data("/generated".utf8))
            while browser.latest.snapshot?.state != .complete { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(10)) }
            let page = try await browser.page(offset: 0)
            try require(page.rows.count == 2 && !browser.allowsFreshUploads && !browser.allowsRequestedDownloads)
            let tab = SFTPTabController(session: browser, address: try .init(form.address), title: "Generated route",
                downloads: try .init(directory: location.appendingPathComponent("state/Native/downloads")))
            try require(tab.downloads == nil && tab.uploads == nil && tab.rows.onDownload == nil && tab.rows.onDownloadToPane == nil
                && tab.rows.table.menu?.items.filter { $0.title.hasPrefix("Download") }.allSatisfy(\.isHidden) == true)
            let snapshot = try await state.inspect()
            guard let saved = snapshot?.visibleRoutes.first else { throw Failure.scope }
            try require(snapshot?.visibleServers.isEmpty == true && snapshot?.credentials.count == (passwords ? 2 : 0))
            try require(passwords ? saved.jump.keyAccess == nil && saved.destination.keyAccess == nil : saved.jump.keyAccess != nil && saved.destination.keyAccess != nil)
            try require(outcome == (phase == "seed" ? .complete : .notRequested))
            closure = await tab.close().value
            try require(closure?.localResourcesEnded == true && closure?.temporaryStoreRemoved == true && closure?.contained == false
                && closure?.terminal?.tasksAfterRuntimeDrop == 0 && closure?.terminal?.catalogWriterEnd == .closed)
            checkpoint = "cold-forget-and-drain"
            if phase == "reconnect" {
                let removed = await state.forget(.route(saved.id, removePasswords: true)); try require(removed.server == .complete && removed.password == .complete)
                let after = try await state.inspect(); try require(after?.visibleRoutes.isEmpty == true && after?.credentials.isEmpty == true)
            }
            await state.drain(); try require(try await pool.inspect().isEmpty && activity.activeCount == 0 && calls.value == 0)
            ticker?.cancel(); await ticker?.value; ticker = nil; try require(maximumGap < 0.5)
            if let memory {
                let facts = memory.facts, cold = phase == "reconnect"
                try require(facts.stored == (cold ? 0 : 2) && facts.reads == (cold ? 2 : 0)
                    && facts.writes == 2 && facts.removals == (cold ? 2 : 0) && !facts.usedMainThread)
            }
            try write(["passed": true, "phase": phase, "formSubmission": true, "allInputSecretsClearedAfterAdmission": true,
                "freshHostReviews": reviews, "promptChallenges": challengeCount, "rows": page.rows.count,
                "coldReferencesAuthenticated": phase == "reconnect" && !passwords, "routeForgotten": phase == "reconnect", "keychainCalls": calls.value,
                "inMemoryPasswordBackend": passwords, "passwordReads": memory?.facts.reads ?? 0,
                "passwordWrites": memory?.facts.writes ?? 0, "passwordRemovals": memory?.facts.removals ?? 0,
                "actualExit": closure?.actualExit == true, "ipcEOF": closure?.ipcEOF == true, "catalogRemoved": closure?.temporaryStoreRemoved == true,
                "tasksAfter": closure?.terminal?.tasksAfterRuntimeDrop ?? 255, "maximumMainActorGapSeconds": maximumGap,
                "visibleNativeReviews": visible, "actualPromptWindows": promptedWindows.count,
                "nativeTypedRounds": typedRounds.count, "ordinaryFeatureFlags": ordinaryFlags,
                "unsupportedDownloadHidden": true, "visualAcceptance": false], to: location, phase: phase)
            visibleForm?.close(); visibleForm = nil
            }
        } catch {
            driver?.cancel(); _ = await driver?.result
            await model?.cancelAndDrain(); if let browser { closure = await browser.close() }; await remembered?.drain()
            _ = await prompts.closeAndDrain(); _ = await trust.closeAndDrain()
            ticker?.cancel(); await ticker?.value
            var line: UInt = 0; if case let Failure.check(number) = error { line = number }
            if let root { try? write(["passed": false, "checkpoint": checkpoint, "line": line, "errorType": String(reflecting: type(of: error)),
                "actualExit": closure?.actualExit == true, "ipcEOF": closure?.ipcEOF == true], to: root, phase: phase) }
        }
        visibleForm?.close()
        NSApplication.shared.terminate(nil)
    }
    private static func write(_ report: [String: Any], to root: URL, phase: String) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-saved-route-\(phase).json"), options: .withoutOverwriting)
    }
}
#endif
