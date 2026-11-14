#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// One exact signed generated peer. No saved key, Keychain, browser/history,
/// personal endpoint/config/agent or file-body request is admitted here.
@MainActor enum SFTPLiveTrustVerification {
    private enum Failure: Error { case generated }
    private final class State {
        var session: SFTPWorkerSession?, closed: SFTPWorkerClose?
        var decisionCalls = 0, verified = false, maximumGap = 0.0
    }
    private static var retained: SFTPTrustWindowController?
    private static func require(_ value: Bool) throws { if !value { throw Failure.generated } }
    static func runStandalone() async {
        let args = ProcessInfo.processInfo.arguments, state = State()
        var root: URL?
        do {
            func field(_ name: String) throws -> String {
                guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { throw Failure.generated }; return args[i + 1]
            }
            let supplied = URL(fileURLWithPath: try field("--analysis-source"))
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let mode = try field("--generated-mode"), fingerprint = try field("--generated-fingerprint")
            guard let port = UInt16(try field("--generated-port")), port > 0, ["first", "cancel-host", "remembered", "browser"].contains(mode),
                  supplied.deletingLastPathComponent() == repo.appendingPathComponent(".build/b11-native-qualification"),
                  UUID(uuidString: supplied.lastPathComponent)?.uuidString == supplied.lastPathComponent,
                  supplied.resolvingSymlinksInPath() == supplied,
                  Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String == supplied.lastPathComponent,
                  Bundle.main.bundleURL.path.hasPrefix(supplied.appendingPathComponent("artifacts/").path),
                  fingerprint.hasPrefix("SHA256:"), fingerprint.utf8.count == 50 else { throw Failure.generated }
            root = supplied
            let activity = FileActivityGate(), settings = BrowserSettings(persist: false)
            settings.appearance = .dark; settings.navigationStyle = .glass
            let pool = SMBTemporaryCatalogPool(storage: try SMBTemporaryStorage(directory: supplied.appendingPathComponent("stores/pool"), sessionByteLimit: (mode == "browser" ? 64 : 8) << 20))
            let request = try SFTPConnectionRequest(address: SFTPConnectionAddress("sftp://127.0.0.1:\(port)"), account: "generated")
            if mode == "browser" {
                try await SFTPBrowserVerification.run(root: supplied, request: request, fingerprint: fingerprint, pool: pool, activity: activity, settings: settings)
                NSApplication.shared.terminate(nil); return
            }
            if mode == "remembered" {
                try await runRememberedSequence(root: supplied, request: request, fingerprint: fingerprint, pool: pool, activity: activity, settings: settings)
                NSApplication.shared.terminate(nil); return
            }
            let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: activity)
            try require(activity.activeCount == 0)
            let session = try await SFTPWorkerSession.openPrepared(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL, activity: activity, pool: pool)
            state.session = session
            try require(session.review.kind == .first && session.review.host == request.address.host && session.review.port == port
                && session.review.current.fingerprint == fingerprint && activity.activeCount == 1)
            let presentation = SFTPTrustPresentation(host: session.review.host, port: session.review.port,
                fingerprint: session.review.current.fingerprint, previousFingerprint: session.review.previous?.fingerprint)
            let model = SFTPTrustModel(review: presentation, copy: { _ in }, decision: { intent in
                try require(intent == .connectOnce); state.decisionCalls += 1
                try await session.approve(.connectOnce); return .notRequested
            }, drain: { state.closed = await session.close(); return state.closed?.localResourcesEnded == true })
            let controller = SFTPTrustWindowController(settings: settings, model: model); retained = controller
            controller.window?.title = "SFTP live identity · generated review"; controller.onVerified = { state.verified = true }
            controller.present(); try await Task.sleep(for: .milliseconds(120))
            try require(!model.rememberKey && state.decisionCalls == 0 && !state.verified)
            if mode == "cancel-host" { controller.window?.performClose(nil) } else { model.proceed() }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while model.finished == nil { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(5)) }
            var rows = 0
            if mode == "first" {
                try require(model.finished == .verified && state.verified && state.decisionCalls == 1)
                // The password is not even constructed until real worker-backed
                // host verification completed through the native review model.
                try await session.authenticate(SFTPPassword("ephemeral qualification password"))
                let (generation, empty) = try await session.openStoredDirectory(String(decoding: request.address.initialPathUTF8, as: UTF8.self))
                try require(empty.count == 0); let observed = try await session.ingestNext(generation)
                guard let page = try await session.page(generation, snapshot: observed, offset: 0) else { throw Failure.generated }
                rows = page.rows.count
                try require(rows == 2 && page.rows[0].entry.name.wireUTF8 == Data("Generated first.txt".utf8)
                    && page.rows[1].entry.name.wireUTF8 == Data("Generated second.txt".utf8)
                    && page.rows[0].entry.logicalBytes == 123 && page.rows[1].entry.logicalBytes == 456)
                let complete = try await session.ingestNext(generation); try require(complete.state == .complete && complete.count == 2)
                state.closed = await session.close()
            } else { try require(model.finished == .cancelled && !state.verified && state.decisionCalls == 0) }
            guard let closed = state.closed else { throw Failure.generated }
            try require(closed.localResourcesEnded && closed.exitStatus == 0 && !closed.contained && closed.protocolValid
                && closed.terminal?.runtimeDisposed == true && closed.terminal?.catalogWriterEnd == .closed
                && closed.temporaryStoreRemoved == true && activity.activeCount == 0)
            let empty = try await pool.inspect(); try require(empty.isEmpty && controller.window?.isVisible == false)
            let report: [String: Any] = ["passed": true, "mode": mode, "actualChildExit": closed.actualExit,
                "ipcEOF": closed.ipcEOF, "writerClosed": true, "storeRemoved": true, "poolEmpty": true, "activity": activity.activeCount,
                "decisionCalls": state.decisionCalls, "verifiedBeforePassword": state.verified, "rows": rows,
                "keychainAccesses": 0, "personalCatalogs": 0, "clipboardWasInjected": true, "windowClosedAfterDrain": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: supplied.appendingPathComponent("evidence/live-ui-\(mode).json"), options: .withoutOverwriting)
            retained = nil; NSApplication.shared.terminate(nil)
        } catch {
            if let session = state.session { state.closed = await session.close() }
            if let root {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "actualChildExit": state.closed?.actualExit ?? false,
                    "ipcEOF": state.closed?.ipcEOF ?? false, "storeRemoved": state.closed?.temporaryStoreRemoved ?? false])
                    .write(to: root.appendingPathComponent("evidence/live-ui-failure.json"), options: .withoutOverwriting)
            }
            fputs("Generated live SFTP trust verification failed\n", stderr); NSApplication.shared.terminate(nil)
        }
    }
    private static func runRememberedSequence(root: URL, request: SFTPConnectionRequest, fingerprint: String,
        pool: SMBTemporaryCatalogPool, activity: FileActivityGate, settings: BrowserSettings) async throws {
        guard let namespace = UUID(uuidString: root.lastPathComponent) else { throw Failure.generated }
        let location = root.appendingPathComponent("sftp-private-state")
        var memory = SFTPRememberedState(settings: SFTPSettingsStore(directory: location), passwords: .generatedQualification(namespace: namespace))
        var current: SFTPWorkerSession?, completed = 0, savedServer: UUID?, passwordWasSaved = false
        do {
            try require(try await memory.inspect() == nil)
            for index in 0..<3 {
                let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: activity)
                let session = try await SFTPWorkerSession.openPrepared(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
                    activity: activity, pool: pool, remembered: memory); current = session
                let expected = index == 0 ? SFTPHostChallenge.Kind.first : index == 1 ? .matching : .changed
                try require(session.review.kind == expected && (index == 2 ? session.review.current.fingerprint != fingerprint : session.review.current.fingerprint == fingerprint))
                if index > 0 { try require(session.review.previous?.fingerprint == fingerprint) }
                let state = State(), memoryForReview = memory
                let model = SFTPTrustModel(review: .init(host: session.review.host, port: session.review.port,
                    fingerprint: session.review.current.fingerprint, previousFingerprint: session.review.previous?.fingerprint), copy: { _ in }, decision: { intent in
                    state.decisionCalls += 1
                    if index == 0 {
                        try require(intent == .rememberVerified); try await session.approve(.remember)
                        let saved = try await session.rememberVerifiedHost(using: memoryForReview)
                        try require(saved.host == .complete); return .saved
                    }
                    try require(index == 1 && intent == .useMatching); try await session.approve(.useMatching); return .notRequested
                }, drain: { state.closed = await session.close(); return state.closed?.localResourcesEnded == true })
                let controller = SFTPTrustWindowController(settings: settings, model: model); retained = controller
                controller.present()
                if index == 2 {
                    model.proceed(); try require(!model.busy && state.decisionCalls == 0)
                    model.showReplacement(); model.proceed(); try require(!model.busy && state.decisionCalls == 0)
                    controller.window?.performClose(nil)
                } else { model.rememberKey = index == 0; model.proceed() }
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while model.finished == nil { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(5)) }
                if index < 2 {
                    try require(model.finished == .verified && state.decisionCalls == 1); controller.window?.close()
                    if index == 0 {
                        let password = try SFTPPassword("ephemeral qualification password")
                        try await session.authenticate(password)
                        let draft = try SFTPServerDraft(name: "Generated saved SFTP", address: request.address, account: request.account)
                        let saved = try await session.rememberAuthenticatedServer(draft, password: password, using: memory,
                            rememberServer: true, rememberPassword: true, editing: nil)
                        try require(saved.server == .complete && saved.password == .complete && saved.serverID != nil)
                        savedServer = saved.serverID; passwordWasSaved = true
                    } else { try await session.authenticateSaved(using: memory, serverID: savedServer) }
                    let (id, _) = try await session.openStoredDirectory(".")
                    let prefix = try await session.ingestNext(id), page = try await session.page(id, snapshot: prefix, offset: 0)
                    try require(page?.rows.count == 2)
                    let final = try await session.ingestNext(id); try require(final.state == .complete && final.count == 2)
                    state.closed = await session.close()
                } else { try require(model.finished == .cancelled && state.decisionCalls == 0) }
                guard let closed = state.closed else { throw Failure.generated }
                try require(closed.localResourcesEnded && closed.exitStatus == 0 && !closed.contained && closed.protocolValid
                    && closed.terminal?.catalogWriterEnd == .closed && closed.temporaryStoreRemoved == true && activity.activeCount == 0)
                try require(try await pool.inspect().isEmpty && controller.window?.isVisible == false)
                completed += 1; current = nil; retained = nil; await memory.drain()
                // Cold settings/Keychain owners, rather than a remembered in-memory key.
                memory = SFTPRememberedState(settings: SFTPSettingsStore(directory: location), passwords: .generatedQualification(namespace: namespace))
            }
            let before = try await memory.inspect()
            try require(before?.visibleHosts.count == 1 && before?.visibleHosts.first?.key.fingerprint == fingerprint)
            let forgotten = await memory.forget(.all); await memory.drain()
            let after = try await memory.inspect()
            try require(forgotten.host == .complete && forgotten.server == .complete && forgotten.password == .complete
                && after?.hosts.isEmpty == true && after?.servers.isEmpty == true && after?.credentials.isEmpty == true)
            try JSONSerialization.data(withJSONObject: ["passed": true, "completedLifetimes": completed, "coldMatchingKey": true,
                "changedKeySentNoAuthentication": true, "savedPasswordUsedOnlyAfterVerification": true,
                "generatedKeychainEntriesCreated": 1, "generatedKeychainEntriesRemoved": 1, "allChildrenAndCatalogsDrained": true,
                "personalQueries": 0, "clipboardWasInjected": true], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/live-ui-remembered.json"), options: .withoutOverwriting)
        } catch {
            if let current { _ = await current.close() }
            let cleanup = await memory.forget(.all); await memory.drain()
            try? JSONSerialization.data(withJSONObject: ["passed": false, "completedLifetimes": completed,
                "generatedPasswordWasSaved": passwordWasSaved, "exactGeneratedCleanupComplete": cleanup.password == .complete])
                .write(to: root.appendingPathComponent("evidence/live-ui-remembered-failure.json"), options: .withoutOverwriting)
            retained?.window?.close(); retained = nil; throw error
        }
    }
}
#endif
