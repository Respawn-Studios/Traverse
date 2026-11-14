#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SFTPJumpConnectionVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var number = 0
        func increment() { lock.withLock { number += 1 } }
        var value: Int { lock.withLock { number } }
    }
    private static func require(_ condition: Bool, line: UInt = #line) throws { if !condition { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, checkpoint = "scope", jump: SFTPJumpHostStage?, destination: SFTPWorkerSession?, browser: SFTPBrowserSession?
        var operation: Task<Void, Error>?, complete = false, maximumGap = 0.0, ticker: Task<Void, Never>?
        var closure: SFTPWorkerClose?, rows = 0
        let trust = SFTPSetupTrust(), prompts = SFTPSetupInteractive(), calls = Count()
        do {
            let args = ProcessInfo.processInfo.arguments
            func argument(_ name: String) throws -> String {
                guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { throw Failure.scope }; return args[index + 1]
            }
            guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath: path), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "ssh-native-jump"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = location
            guard let port = UInt16(try argument("--generated-port")), port > 0,
                  let targetPort = UInt16(try argument("--generated-target-port")), targetPort > 0 else { throw Failure.scope }
            let outerFingerprint = try argument("--generated-fingerprint"), targetFingerprint = try argument("--generated-target-fingerprint")
            let action = try argument("--generated-action"), factor = args.contains("--generated-outer-factor")
            let independent = args.contains("--independent-openssh")
            try require(["complete", "cancel-jump", "cancel-destination"].contains(action))
            let settings = BrowserSettings(persist: false); settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            InterfacePresentation.shared.bind(settings)
            let storage = try SMBTemporaryStorage(directory: location.appendingPathComponent("state/Native/catalogs"))
            let pool = SMBTemporaryCatalogPool(storage: storage), activity = FileActivityGate()
            let remembered = SFTPRememberedState(settings: .init(directory: location.appendingPathComponent("state/Native/settings")), passwords: .refusingQualification { calls.increment() })
            let outerRequest = try SFTPConnectionRequest(address: .init("sftp://127.0.0.1:\(port)"), account: "generated")
            let target = try SFTPConnectionRequest(address: .init("sftp://\(independent ? "localhost" : "private.internal.test"):\(targetPort)"), account: "generated")
            let selected = try SFTPSelectedPrivateKey(file: location.appendingPathComponent("source/client-key"))
            let phrase = try SFTPKeyPassphrase("generated-only-not-a-secret")
            var tick = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; maximumGap = max(maximumGap, now - tick); tick = now
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            } }
            try prompts.beginConnection()
            operation = Task {
                let endpoint = try await SFTPPreparedConnection.prepare(outerRequest, bundleURL: Bundle.main.bundleURL, activity: activity)
                let stage = try await SFTPJumpHostStage.openPrepared(destination: target, jump: outerRequest, endpoint: endpoint,
                    bundleURL: Bundle.main.bundleURL, activity: activity, pool: pool); jump = stage
                guard await trust.reviewOnce(stage, heading: "Verify jump server", settings: settings, owner: nil).verified else { throw SFTPSessionFailure.stopped }
                if factor {
                    var step = try await stage.beginInteractiveAuthentication(key: selected, passphrase: phrase)
                    while case .challenge(let challenge) = step {
                        guard let answers = await prompts.review(stage, challenge: challenge, settings: settings, owner: nil) else { throw SFTPSessionFailure.stopped }
                        step = try await stage.answer(answers, challenge: challenge)
                    }
                    guard await prompts.dismissAuthenticated() else { throw SFTPSessionFailure.stopped }
                } else { _ = try await stage.authenticate(key: selected, passphrase: phrase) }
                let inner = try await stage.destinationSession(); destination = inner
                do { _ = try await stage.destinationSession(); throw Failure.scope }
                catch SFTPSessionFailure.busy { }
                guard await trust.reviewOnce(inner, heading: "Verify destination server", settings: settings, owner: nil).verified else { throw SFTPSessionFailure.stopped }
                _ = try await inner.authenticate(key: selected, passphrase: phrase)
                let draft = try SFTPServerDraft(name: "Generated route", address: target.address, account: target.account)
                do { _ = try await inner.rememberAuthenticatedServer(draft, password: .init("generated-not-saved"), using: remembered,
                    rememberServer: true, rememberPassword: true, editing: nil); throw Failure.scope }
                catch SFTPSettingsFailure.invalidRecord { }
                let adopted = try await SFTPBrowserSession.adoptAuthenticated(inner); browser = adopted
                _ = try await adopted.navigate(pathUTF8: Data((independent ? "/fixture" : "/generated").utf8))
                try await wait { adopted.latest.snapshot?.state == .complete }; rows = try await adopted.page(offset: 0).rows.count
                try require(rows == 2 && !adopted.allowsFreshUploads)
                closure = await adopted.close(); browser = nil; destination = nil; jump = nil; complete = true
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            checkpoint = "jump-review"; try await wait { trust.controller != nil || complete }
            guard let outer = trust.controller else { throw Failure.scope }
            try require(outer.model.review.fingerprint == outerFingerprint && !outer.model.allowsRemembering)
            if action == "cancel-jump" { outer.window?.performClose(nil) }
            else {
                outer.model.proceed()
                if factor {
                    checkpoint = "jump-factor"
                    for round in 1...(independent ? 8 : 2) {
                        try await wait { prompts.controller?.model.challenge.round == UInt8(round) && prompts.controller?.model.phase == .input || independent && trust.controller.map { $0 !== outer } == true }
                        if independent && trust.controller.map({ $0 !== outer }) == true { break }
                        guard let window = prompts.controller, let native = window.window else { throw Failure.scope }
                        try await wait { SFTPInteractiveConnectionVerification.fieldsReady(window) }
                        for (index, prompt) in window.model.challenge.prompts.enumerated() {
                            try SFTPInteractiveConnectionVerification.enterResponse(independent ? "123456" : round == 2 ? "654321" : prompt.echo ? "generated" : "123456", at: index, in: window)
                        }
                        try SFTPInteractiveConnectionVerification.pressReturn(native)
                        try await wait { window.model.phase != .input }
                    }
                }
                checkpoint = "destination-review"
                try await wait { trust.controller.map { $0 !== outer } == true || complete }
                guard let inner = trust.controller else { throw Failure.scope }
                try require(inner.model.review.fingerprint == targetFingerprint && !inner.model.allowsRemembering)
                if action == "cancel-destination" { inner.window?.performClose(nil) } else { inner.model.proceed() }
            }
            checkpoint = "outcome"
            do { try await operation?.value; try require(action == "complete" && complete) }
            catch SFTPSessionFailure.stopped { try require(action != "complete" && !complete) }
            if let destination { closure = await destination.close() } else if let jump { closure = await jump.close() }
            _ = await prompts.closeAndDrain(); _ = await trust.closeAndDrain()
            try require(closure?.localResourcesEnded == true && closure?.temporaryStoreRemoved == true && closure?.contained == false)
            try require(closure?.terminal?.tasksAfterRuntimeDrop == 0 && closure?.terminal?.catalogWriterEnd == .closed)
            let catalogues = try await pool.inspect(), saved = try await remembered.inspect()
            try require(catalogues.isEmpty && saved == nil && activity.activeCount == 0 && calls.value == 0)
            ticker?.cancel(); await ticker?.value; ticker = nil; try require(maximumGap < 0.5)
            let report: [String: Any] = ["passed": true, "action": action, "outerFactor": factor, "rows": rows,
                "twoSeparateNativeReviews": action != "cancel-jump", "immutableDestinationHandoff": complete,
                "directSavedAuthorityRefused": complete, "keychainCalls": calls.value, "destinationLocalDNSRequests": 0,
                "actualExit": closure?.actualExit == true, "ipcEOF": closure?.ipcEOF == true, "catalogRemoved": closure?.temporaryStoreRemoved == true,
                "contained": closure?.contained == true, "tasksAfter": closure?.terminal?.tasksAfterRuntimeDrop ?? 255,
                "maximumMainActorGapSeconds": maximumGap, "drainSeconds": closure?.drainElapsedSeconds ?? 0]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: location.appendingPathComponent("evidence/native-jump.json"), options: .withoutOverwriting)
        } catch {
            operation?.cancel(); _ = await prompts.closeAndDrain(); _ = await trust.closeAndDrain()
            if let browser { closure = await browser.close() } else if let destination { closure = await destination.close() } else if let jump { closure = await jump.close() }
            _ = await operation?.result; ticker?.cancel(); await ticker?.value
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? JSONSerialization.data(withJSONObject: ["passed": false, "checkpoint": checkpoint, "line": line,
                "errorType": String(reflecting: type(of: error)), "actualExit": closure?.actualExit == true,
                "ipcEOF": closure?.ipcEOF == true, "contained": closure?.contained == true,
                "protocolValid": closure?.protocolValid == true, "catalogRemoved": closure?.temporaryStoreRemoved == true]).write(to: root.appendingPathComponent("evidence/native-jump.json"), options: .withoutOverwriting) }
        }
        NSApplication.shared.terminate(nil)
    }
}
#endif
