#if DEBUG || TRAVERSE_SFTP_EDITOR_QA
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Real signed helper and native trust/form, limited to the marked generated
/// development case. It never installs the login-Keychain backend.
@MainActor enum SFTPKeyConnectionVerification {
    private enum Failure: Error { case generated, check(UInt) }
    private final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(10)) }
    }
    #if DEBUG
    static func run() async {
        var root: URL?, stage = "scope", form: SMBConnectWindowController?, trust: SFTPSetupTrust?
        var session: SFTPBrowserSession?, coordinator: SFTPConnectionCoordinator?
        let accesses = Count()
        do {
            let arguments = ProcessInfo.processInfo.arguments
            func value(_ name: String) throws -> String {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index+1) else { throw Failure.generated }
                return arguments[index+1]
            }
            guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.generated }
            let location = URL(fileURLWithPath: path)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: location.appendingPathComponent("reservation.json"))) as? [String: Any]
            let cancelOnly = arguments.contains("--generated-native-cancel-only")
            try require(marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == (cancelOnly ? "ssh-key-native-loopback" : "ssh-independent-openssh"))
            root = location
            guard let port = UInt16(try value("--generated-port")), port > 0 else { throw Failure.generated }
            let fingerprint = try value("--generated-fingerprint")
            let settings = BrowserSettings(persist: false)
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            InterfacePresentation.shared.bind(settings)
            let directory = location.appendingPathComponent("state/Native"), key = location.appendingPathComponent("source/SSH/client-key")
            let vault = SFTPPasswordVault.refusingQualification { accesses.increment() }
            let storage = try SMBTemporaryStorage(directory: directory.appendingPathComponent("catalogs"))
            let pool = SMBTemporaryCatalogPool(storage: storage), activity = FileActivityGate()
            let draft = try SFTPServerDraft(name: "Generated OpenSSH", address: SFTPConnectionAddress("sftp://127.0.0.1:\(port)/fixture"), account: "generated")
            var savedID: UUID?, rows = 0, expectedFailure = false
            for iteration in 0..<(cancelOnly ? 1 : 3) {
                stage = "connect-\(iteration)"
                // New owners and disk inspection qualify a cold saved reference.
                let remembered = SFTPRememberedState(settings: SFTPSettingsStore(directory: directory.appendingPathComponent("settings")), passwords: vault)
                let connection = SFTPConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: storage, remembered: remembered, activity: activity)
                coordinator = connection
                let review = SFTPSetupTrust(); trust = review
                let window = SMBConnectWindowController(settings: settings) { _, _ in throw Failure.generated }; form = window
                window.model.profileFeaturesAvailable = true
                window.model.sftpHandler = { submission, _ in
                    guard let authentication = submission.authentication else { throw Failure.generated }
                    let outcome = try await connection.connect(submission.draft, authentication: authentication,
                        savedServerID: submission.editingServer, rememberServer: submission.rememberServer,
                        rememberPassword: false, profileFeatures: true, configuration: submission.configuration,
                        profileAlias: submission.profileAlias) { raw, state in
                            await review.review(raw, remembered: state, settings: settings, owner: window.window)
                        }
                    session = outcome.session
                    return .init(server: outcome.remembering.server == .complete ? .saved : .notRequested, password: .notRequested,
                        host: outcome.remembering.host == .complete ? .saved : .notRequested,
                        keyAccess: outcome.remembering.keyAccess == .complete ? .saved : .incomplete,
                        open: {}, discard: { await outcome.session.close().localResourcesEnded })
                }
                let model = window.model; model.connectionProtocol = .sftp
                model.onConnected = {}; model.onCancelled = {}
                model.address = draft.address.displayAddress; model.account = draft.account
                if iteration < 2 {
                    model.sshProfiles.load(directory: key.deletingLastPathComponent())
                    try await wait { !model.sshProfiles.busy }
                    stage = "imported-\(iteration)"
                    guard let profile = model.sshProfiles.profiles.first(where: { $0.alias == "generated" }) else { throw Failure.generated }
                    model.applySSHProfile(profile); model.useSSHKey(key, accessRoot: key.deletingLastPathComponent())
                    model.rememberServer = true; model.rememberKeyAccess = true; model.name = draft.name
                } else {
                    let snapshot = try await remembered.inspect()
                    guard let savedID, let saved = snapshot?.visibleServers.first(where: { $0.id == savedID }) else { throw Failure.generated }
                    try require(snapshot?.credentials.isEmpty == true && saved.keyAuthentication?.reference != nil)
                    model.replaceSFTPServers([.init(id: saved.id, details: saved.details, hasSavedPassword: false, keyAuthentication: saved.keyAuthentication)])
                    model.choose(savedID)
                    try require(model.savedKeyAvailable && model.selectedKey == nil && model.keyPassphrase.isEmpty)
                }
                model.keyPassphrase = "generated-only-not-a-secret"
                window.window?.title = "SFTP key connection · generated independent review"
                window.present(); NSApplication.shared.activate(ignoringOtherApps: true)
                stage = "submitted-\(iteration)"
                model.connect(); try await wait { review.controller != nil || !model.busy }
                guard let prompt = review.controller else { throw Failure.generated }
                stage = "trust-\(iteration)"
                try require(prompt.model.review.fingerprint == fingerprint && prompt.model.review.algorithm == "Ed25519")
                if iteration == 0 {
                    prompt.model.cancel(); try await wait { !model.busy }
                    stage = "cancelled-\(iteration)"
                    expectedFailure = !model.connected && model.keyPassphrase.isEmpty
                    try require(expectedFailure)
                    let untouched = try await remembered.inspect(); try require(untouched == nil)
                } else {
                    try require(prompt.model.review.kind == (iteration == 1 ? .first : .matching))
                    if iteration == 1 { prompt.model.rememberKey = true }
                    prompt.model.proceed(); try await wait { !model.busy }
                    try require(model.connected && !model.rememberingIncomplete && model.keyPassphrase.isEmpty)
                    guard let active = session else { throw Failure.generated }
                    _ = try await active.navigate(pathUTF8: Data("/fixture".utf8))
                    try await wait { active.latest.snapshot?.state == .complete }
                    let page = try await active.page(offset: 0)
                    try require(Set(page.rows.map { $0.entry.name.displayName }) == ["Folder", "Generated.txt"]); rows += page.rows.count
                    let ended = await active.close(); session = nil
                    try require(ended.localResourcesEnded && ended.temporaryStoreRemoved == true)
                    let snapshot = try await remembered.inspect(); savedID = snapshot?.visibleServers.first?.id
                    try require(snapshot?.visibleHosts.count == 1 && snapshot?.visibleServers.count == 1 && snapshot?.credentials.isEmpty == true)
                    if iteration == 2 {
                        let result = await remembered.forget(.all); try require(result.server == .complete)
                        let empty = try await remembered.inspect()
                        try require(empty?.visibleServers.isEmpty == true && empty?.servers.isEmpty == true && empty?.hosts.isEmpty == true)
                    }
                }
                await connection.drain(); coordinator = nil; await remembered.drain()
                let reviewEnded = await review.closeAndDrain(); try require(reviewEnded); trust = nil
                window.close(); form = nil
                try require(accesses.value == 0 && activity.activeCount == 0)
            }
            let stores = try await pool.inspect(); try require(stores.isEmpty)
            let report: [String: Any] = ["passed": true, "cancelBeforeAuthentication": expectedFailure, "coldRememberedKey": !cancelOnly,
                "nativeConnectAndTrust": true, "keychainCalls": accesses.value, "rows": rows, "completedLifetimes": cancelOnly ? 1 : 3,
                "allChildrenAndCatalogsDrained": true, "forgetRemovesKeyAccess": !cancelOnly, "personalEndpoints": 0, "remoteBodyRequests": 0]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                .write(to: location.appendingPathComponent("evidence/native-key.json"), options: .withoutOverwriting)
        } catch {
            if let session { _ = await session.close() }
            _ = await trust?.closeAndDrain(); await coordinator?.drain(); form?.close()
            var checkLine: UInt = 0
            if case let Failure.check(line) = error { checkLine = line }
            if let root { try? JSONSerialization.data(withJSONObject: ["passed": false,"stage":stage,"checkLine":checkLine,"errorType":String(reflecting:type(of:error)),"keychainCalls":accesses.value,
                "generatedFormMessage": form?.model.message ?? "", "hasSelectedKey":form?.model.selectedKey != nil,
                "profileIssues":form?.model.sshProfiles.selected?.issues.map(\.rawValue).sorted() ?? [],
                "profileSelected":form?.model.sshProfiles.selectedAlias != nil])
                .write(to: root.appendingPathComponent("evidence/native-key.json"), options: .withoutOverwriting) }
        }
        NSApplication.shared.terminate(nil)
    }
    #endif

    private struct CertificateInput: Codable, Sendable {
        let packet: String, caseID: String, protocolName: String, host: String
        let port: UInt16
        let account: String, startPath: String, hostFingerprint: String, keyLeaf: String, certificateLeaf: String
        enum CodingKeys: String, CodingKey {
            case packet, caseID = "case", protocolName = "protocol", host, port, account, startPath, hostFingerprint, keyLeaf, certificateLeaf
        }
        var valid: Bool {
            packet == "traverse-certificate-connection-v1" && UUID(uuidString: caseID)?.uuidString == caseID
                && protocolName == "sftp" && host == "127.0.0.1" && port > 1024 && account == "generated"
                && startPath == "/fixture" && hostFingerprint.hasPrefix("SHA256:") && hostFingerprint.utf8.count == 50
                && keyLeaf == "user_ecdsa" && certificateLeaf == "active-cert.pub"
        }
    }
    private struct CertificateWarm: Codable, Sendable {
        let input: CertificateInput
        let serverID: UUID
    }
    /// Uses the ordinary Connect owner and actual saved-server path. The host
    /// independently checks certificate IDs, source bytes and process shutdown.
    static func runCertificates(controller: BrowserWindowController, incoming: IncomingFolderOpening) async {
        let browser = controller.browser, calls = Count()
        var service: ApplicationSMBConnections?, stage = "admission", phase = "warm"
        do {
            try require(GeneratedSandboxReview.certificateConnectionAdmitted)
            guard let fixtureID = GeneratedSandboxReview.reviewFixtureID else { throw Failure.generated }
            stage = "statePreparation"
            let role = try await GeneratedSandboxReview.prepareFixtureStateDirectory()
            let active = try await certificateRead(role.appendingPathComponent("active.json"), optional: true)
            let warm: CertificateWarm
            if let active {
                phase = "cold"; stage = "savedMetadata"
                warm = try JSONDecoder().decode(CertificateWarm.self, from: active)
                try require(warm.input.valid && warm.input.caseID == fixtureID && incoming.openedCount == 0 && !incoming.receivedExplicitRequest)
                let folder = role
                try await certificateWrite(["fixtureID": warm.input.caseID, "phase": "cold-attempt"], to: folder.appendingPathComponent("cold-attempt.json"))
                let profile = ApplicationSMBConnections(directory: folder.appendingPathComponent("profile", isDirectory: true),
                    passwords: .refusingQualification { calls.increment() }, sftpPasswords: .refusingQualification { calls.increment() }, sftpEnabled: true)
                service = profile
                let locations = SavedServerLocations(directory: folder.appendingPathComponent("profile", isDirectory: true))
                locations.refresh(); await locations.work?.value
                guard locations.snapshot.locations.count == 1,
                      let bookmark = locations.snapshot.locations.first, bookmark.isSFTP,
                      bookmark.serverID == warm.serverID else { throw Failure.generated }
                stage = "savedB"
                try await certificateReconnect(profile, bookmark: bookmark, browser: browser, expectedFailure: nil)
                try await certificateDisconnect(browser)
                try await certificateWrite(["fixtureID": warm.input.caseID, "phase": "B-complete"], to: folder.appendingPathComponent("B-complete.json"))
                certificateEvent("cold", "B-complete")
                for (name, message) in [("expired", "certificate has expired"), ("wrong-principal", "server didn’t accept")] {
                    stage = name + "Barrier"
                    certificateEvent("cold", name + "-ready")
                    try await certificateBarrier(fixtureID: warm.input.caseID, phase: name + "-ready")
                    stage = name
                    try await certificateReconnect(profile, bookmark: bookmark, browser: browser, expectedFailure: message)
                    try require(browser.sftpTabs.isEmpty && incoming.openedCount == 0 && !incoming.receivedExplicitRequest)
                    try await certificateWrite(["fixtureID": warm.input.caseID, "phase": name + "-refused"], to: folder.appendingPathComponent(name + "-refused.json"))
                    certificateEvent("cold", name + "-refused")
                }
            } else {
                stage = "awaitNativeOpen"; certificateEvent("warm", stage)
                try await wait { incoming.openedCount == 1 && browser.location.directoryURL != nil }
                guard let root = browser.location.directoryURL else { throw Failure.generated }
                let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                try require(root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-development").path
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent)
                let access = await browser.accessLifetime(for: [root])
                defer { withExtendedLifetime(access) {} }
                try require(access.leases.count == 1)
                guard let marker = try await certificateRead(root.appendingPathComponent("reservation.json")) else { throw Failure.generated }
                try require(try JSONDecoder().decode([String: String].self, from: marker) == [
                    "packet": "traverse-development-v1", "action": "sftp-certificate-ca-acceptance",
                    "master": "887B77DA-8583-42B1-9055-32B91A60641F"
                ])
                guard let bytes = try await certificateRead(root.appendingPathComponent("source/Connection.json")) else { throw Failure.generated }
                let input = try JSONDecoder().decode(CertificateInput.self, from: bytes)
                try require(input.valid && input.caseID == fixtureID && input.caseID == root.lastPathComponent)
                let folder = role
                try await certificateWrite(["fixtureID": input.caseID, "phase": "warm-attempt"], to: folder.appendingPathComponent("warm-attempt.json"))
                let ssh = root.appendingPathComponent("source/SSH", isDirectory: true)
                // A second actual OS folder-open request must grant the exact
                // immediate certificate directory. A typed path is insufficient.
                stage = "awaitCertificateFolder"; certificateEvent("warm", stage)
                try await wait { incoming.openedCount == 2 && browser.location.directoryURL?.path == ssh.path }
                try require(browser.folderAccess.selectedRootCovering(ssh)?.path == ssh.path)
                let selected = await browser.accessLifetime(for: [ssh])
                defer { withExtendedLifetime(selected) {} }
                try require(selected.leases.contains { $0.url.path == ssh.path })
                let profile = ApplicationSMBConnections(directory: folder.appendingPathComponent("profile", isDirectory: true),
                    passwords: .refusingQualification { calls.increment() }, sftpPasswords: .refusingQualification { calls.increment() }, sftpEnabled: true)
                service = profile; profile.present(in: browser)
                try await wait { profile.verificationWindow?.model.managing == false }
                guard let form = profile.verificationWindow else { throw Failure.generated }
                let model = form.model
                model.connectionProtocol = .sftp; model.serverField = input.host; model.portField = String(input.port)
                model.account = input.account; model.startingFolderField = input.startPath; model.name = "Generated certificate server"
                model.transferBehavior = .readOnly
                model.useSSHKey(ssh.appendingPathComponent(input.keyLeaf), accessRoot: ssh)
                model.useSSHCertificate(ssh.appendingPathComponent(input.certificateLeaf), directory: ssh)
                model.rememberServer = true; model.rememberKeyAccess = true
                stage = "selectedA"; model.connect()
                try await wait { profile.verificationSFTPTrust != nil || !model.busy }
                guard let trust = profile.verificationSFTPTrust else { throw Failure.generated }
                try require(trust.model.review.kind == .first && trust.model.review.fingerprint == input.hostFingerprint)
                trust.model.rememberKey = true; trust.model.proceed()
                try await wait { !model.busy }
                try require(model.connected && !model.rememberingIncomplete && model.keyPassphrase.isEmpty)
                try await certificateListing(browser)
                guard let snapshot = try await profile.verificationSFTPRemembered?.inspect(),
                      snapshot.visibleServers.count == 1, snapshot.visibleHosts.count == 1, snapshot.credentials.isEmpty,
                      let saved = snapshot.visibleServers.first, saved.keyAuthentication?.requiresCertificate == true,
                      saved.keyAuthentication?.reference != nil, saved.keyAuthentication?.certificate != nil else { throw Failure.generated }
                warm = .init(input: input, serverID: saved.id)
                try await certificateDisconnect(browser)
                await profile.closeAndDrain(); service = nil
                try await certificateWrite(warm, to: role.appendingPathComponent("active.json"))
                try await certificateWrite(["fixtureID": input.caseID, "phase": "A-complete"], to: folder.appendingPathComponent("A-complete.json"))
                certificateEvent("warm", "A-complete")
            }
            await service?.closeAndDrain(); service = nil
            try require(calls.value == 0 && ApplicationSMBActivity.gate.activeCount == 0)
            stage = "drained"; certificateEvent(phase, stage, result: "appChecksSatisfied")
        } catch {
            await service?.closeAndDrain()
            certificateEvent(phase, stage, result: "refused")
        }
        NSApp.terminate(nil)
    }
    private static func certificateListing(_ browser: BrowserViewController) async throws {
        guard let owner = browser.sftpTabs[browser.activeID] else { throw Failure.generated }
        try await wait { owner.rows.cache.snapshot?.state == .complete && !owner.hasPendingPages }
        try require(owner.requiresUserCertificate && owner.rows.cache.retainedCount == 1
            && owner.rows.cache.loadedEntries.map { $0.row.entry.name.displayName } == ["Certificate.txt"]
            && !owner.session.allowsFreshUploads && !owner.session.allowsRequestedDownloads)
    }
    private static func certificateDisconnect(_ browser: BrowserViewController) async throws {
        guard let owner = browser.sftpTabs[browser.activeID] else { throw Failure.generated }
        let id = browser.activeID
        browser.view.window?.makeFirstResponder(owner.rows.table)
        browser.disconnectCurrentConnection(nil)
        try await wait { browser.sftpTabs[id] == nil }
        let ended = await owner.close().value
        try require(ended.localResourcesEnded && ended.actualExit && ended.ipcEOF && ended.temporaryStoreRemoved == true)
    }
    private static func certificateReconnect(_ profile: ApplicationSMBConnections, bookmark: WorkspaceConnectionBookmark,
        browser: BrowserViewController, expectedFailure: String?) async throws {
        var finished: Bool?, messages: [String] = []
        profile.connectSaved(in: browser, savedServer: bookmark, allowsFormFallback: false,
            phase: { messages.append($0) }, finished: { finished = $0 })
        try await wait { finished != nil && !profile.verificationCertificateConnectionPending }
        try require(profile.verificationWindow?.window?.isVisible != true && profile.verificationSFTPTrust == nil)
        if let expectedFailure {
            try require(finished == false && messages.contains { $0.localizedCaseInsensitiveContains(expectedFailure) })
        } else {
            try require(finished == true)
            try await certificateListing(browser)
        }
    }
    private static func certificateBarrier(fixtureID: String, phase: String) async throws {
        try require(phase == "expired-ready" || phase == "wrong-principal-ready")
        let expected = Array("TRAVERSE_CA_CONTROL case=\(fixtureID) phase=\(phase)\n".utf8)
        try await Task.detached(priority: .utility) {
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            var offset = 0
            while offset < expected.count {
                let remaining = Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000)
                guard remaining > 0 else { throw Failure.generated }
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining, 45_000)))
                if ready < 0 && errno == EINTR { continue }
                guard ready == 1 else { throw Failure.generated }
                var byte: UInt8 = 0
                let count = read(STDIN_FILENO, &byte, 1)
                if count < 0 && errno == EINTR { continue }
                guard count == 1 && byte == expected[offset] else { throw Failure.generated }
                offset += 1
            }
        }.value
    }
    private static func certificateEvent(_ phase: String, _ stage: String, result: String = "ready") {
        fputs("TRAVERSE_CERTIFICATE_CONNECTION phase=\(phase) stage=\(stage) result=\(result) pid=\(getpid())\n", stderr)
    }
    private static func certificateRead(_ url: URL, optional: Bool = false) async throws -> Data? {
        try await Task.detached {
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            if fd < 0 { if optional && errno == ENOENT { return nil }; throw Failure.generated }
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
                  before.st_nlink == 1, before.st_mode & 0o022 == 0, (1...8192).contains(before.st_size) else { throw Failure.generated }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let data = try handle.read(upToCount: 8193), data.count == before.st_size,
                  fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.generated }
            return data
        }.value
    }
    private static func certificateWrite<Value: Encodable & Sendable>(_ value: Value, to url: URL) async throws {
        try await Task.detached {
            let bytes = try JSONEncoder().encode(value)
            guard bytes.count <= 8192 else { throw Failure.generated }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.generated }
            defer { close(fd) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: bytes); try handle.synchronize()
        }.value
    }
}
#endif
