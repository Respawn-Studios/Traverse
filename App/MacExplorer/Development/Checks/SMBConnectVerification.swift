#if DEBUG
import AppKit
import Darwin
@_spi(Qualification) import LocalStorage

@MainActor enum SMBConnectVerification {
    private static var retained: SMBConnectWindowController?
    static func runStandalone() async {
        do {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "--analysis-source"), args.indices.contains(i + 1) else { throw UIVerification.Failure(message: "Missing generated Connect root") }
            let root = URL(fileURLWithPath: args[i + 1])
            let modelOnly = args.contains("--check-smb-connect-model-only")
            let settings = BrowserSettings(persist: false)
            var report = try await run(root: root, settings: settings, review: !modelOnly)
            if args.contains("--check-smb-connect-storage") {
                report["connectionStorage"] = try await SMBConnectionStorageVerification.run(root: root, settings: settings)
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/connect.json"), options: .withoutOverwriting)
            if modelOnly { NSApplication.shared.terminate(nil); return }
            if args.contains("--record-smb-connect-native-motion"), let retained, let window = retained.window {
                try NativeMotionRecorder.validateScope(window: window, root: root, label: "scope-control")
                for (candidate, label) in [(root.deletingLastPathComponent(), "scope-control"), (root, "../foreign"), (root, "")] {
                    do { try NativeMotionRecorder.validateScope(window: window, root: candidate, label: label); throw UIVerification.Failure(message: "Recording scope control failed") }
                    catch NativeMotionRecorder.Failure.scope { }
                }
                let title = window.title; window.title = "Ordinary window"
                do { try NativeMotionRecorder.validateScope(window: window, root: root, label: "scope-control"); throw UIVerification.Failure(message: "Recording admitted an ordinary window") }
                catch NativeMotionRecorder.Failure.scope { }
                window.title = title
                try Data("Four denied recording-scope controls passed; no stream admitted".utf8)
                    .write(to: root.appendingPathComponent("evidence/capture-scope-controls.txt"), options: .withoutOverwriting)
                for index in 1...4 {
                    let capture = try await NativeMotionRecorder.record(window: window, root: root, label: "native-motion-\(index)") {
                        if index <= 2 { retained.model.showAdvanced.toggle() }
                        else { retained.setSidebarVisible(!retained.model.showServers) }
                    }
                    try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/native-motion-\(index).json"), options: .withoutOverwriting)
                }
                window.close(); NSApplication.shared.terminate(nil); return
            }
            if args.contains("--capture-smb-connect-motion") {
                await runMotionRequests(root: root)
                try await Task.sleep(for: .seconds(1))
                NSApplication.shared.terminate(nil)
            }
        } catch { fputs("Generated Connect verification failed\n", stderr); NSApplication.shared.terminate(nil) }
    }
    /// A contained development diagnostic. Requests are generated fixture data,
    /// read off-main; production has no file-controlled UI or polling loop.
    private static func runMotionRequests(root: URL) async {
        for index in 1...4 {
            let url = root.appendingPathComponent("evidence/motion-\(index).request")
            let action: String? = await Task.detached(priority: .utility) {
                for _ in 0..<1200 {
                    if Task.isCancelled { return nil }
                    let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
                    if fd >= 0 {
                        defer { Darwin.close(fd) }
                        var info = stat()
                        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
                              info.st_nlink == 1, info.st_size > 0, info.st_size <= 16 else { return nil }
                        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
                        guard read(fd, &bytes, bytes.count) == bytes.count else { return nil }
                        return String(bytes: bytes, encoding: .utf8)
                    }
                    if errno != ENOENT { return nil }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return nil
            }.value
            guard let retained, let action else { return }
            // Pre-roll belongs only to this generated recording scenario.
            try? await Task.sleep(for: .milliseconds(350))
            let began = CACurrentMediaTime()
            let beganUnix = Date().timeIntervalSince1970 * 1000
            var geometry: [[String: Double]] = []
            if action == "advanced" { retained.model.showAdvanced.toggle() }
            else if action == "sidebar" { retained.setSidebarVisible(!retained.model.showServers) }
            else { return }
            for _ in 0..<36 {
                if let frame = retained.window?.frame {
                    geometry.append(["milliseconds": (CACurrentMediaTime() - began) * 1000,
                        "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height])
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            let report: [String: Any] = ["action": action, "geometry": geometry, "beganUnixMilliseconds": beganUnix,
                "advanced": retained.model.showAdvanced, "sidebar": retained.model.showServers]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/motion-\(index)-executed.json"), options: .withoutOverwriting)
        }
    }
    static func run(root: URL, settings: BrowserSettings, review: Bool) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(SandboxQualificationLaunch.permits(hasCaseMarker: true, arguments: ["--verify-ui", "--check-sftp-connect-standalone"])
            && !SandboxQualificationLaunch.permits(hasCaseMarker: true, arguments: ["--check-sftp-connect-standalone"])
            && !SandboxQualificationLaunch.permits(hasCaseMarker: true, arguments: ["--verify-ui", "--check-sftp-connect-standalone", "--show-browser"]),
            "Generated SFTP launch escaped its exact mode")
        let ordinaryRoot = root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && root.resolvingSymlinksInPath() == root
        let ordinaryMarker = ordinaryRoot ? (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json")))) as? [String: Any] : nil
        let ordinaryModel = ordinaryMarker?["packet"] as? String == "traverse-development-v1"
            && ordinaryMarker?["action"] as? String == "native-smb-connect-model"
        try require((ordinaryModel || [".build/b10-browser-qualification", ".build/b10-completion-qualification", ".build/b11-native-qualification"].contains(where: { root.deletingLastPathComponent() == repo.appendingPathComponent($0) }))
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
            "Connect review requires its exact generated case")
        let servers = try [SMBConnectServerChoice(id: UUID(), name: "Studio", address: SMBConnectionAddress("smb://studio.example.invalid/Shared"),
            account: "generated", domain: "", security: .encrypted),
            SMBConnectServerChoice(id: UUID(), name: "Test Lab", address: SMBConnectionAddress("smb://lab.example.invalid/Research"),
                account: "generated", domain: "", security: .encrypted)]
        var calls = 0, opened = 0
        let model = SMBConnectModel(servers: servers) { input, phase in
            calls += 1
            try require(input.rememberServer && !input.rememberPassword && input.security == .encrypted, "Independent remembering/security defaults differ")
            try require(input.password?.withUTF8Bytes { $0 == Data("generated-only".utf8) } == true, "Secret boundary differs")
            phase("Opening shared folder…")
            return .init(server: .saved, password: .notRequested, open: { opened += 1 }, discard: { true })
        }
        try require(!model.rememberServer && !model.rememberPassword && model.security == .encrypted, "New connection defaults changed")
        model.connect(); await Task.yield(); try require(calls == 0 && !model.busy, "Invalid input reached connection handler")
        model.choose(servers[0].id); model.password = "discard-this-generated-value"
        model.address = servers[1].address.displayAddress
        try require(model.password.isEmpty, "Endpoint edit retained old password")
        model.choose(servers[0].id); model.password = "generated-only"; model.connect()
        try await wait { !model.busy }; try require(calls == 1 && opened == 1 && model.connected && model.password.isEmpty, "Native form success/secret lifetime differs")

        var uploadChoices: [SFTPTransferPreference] = []
        let uploadModel = SMBConnectModel(servers: servers) { input, _ in
            uploadChoices.append(input.transferPreference)
            return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        uploadModel.smbUploadAvailable = true; uploadModel.choose(servers[0].id)
        try require(uploadModel.transferBehavior == .readOnly, "An older saved server silently gained write access")
        uploadModel.transferBehavior = .normal; uploadModel.password = "generated-only"; uploadModel.connect()
        try await wait { !uploadModel.busy }
        try require(uploadChoices == [.normal], "Explicit encrypted Upload choice did not reach the connection owner")
        uploadModel.choose(servers[0].id); uploadModel.transferBehavior = .normal
        uploadModel.security = .signedCompatibility
        try require(uploadModel.transferBehavior == .readOnly && !uploadModel.canUseFreshUploads,
            "Signed-only compatibility retained encrypted-only Upload access")

        let held = DiscardHold()
        var release: CheckedContinuation<Void, Never>?
        var cancelledOpen = 0
        let pending = SMBConnectModel { _, _ in
            await withCheckedContinuation { release = $0 }
            return .init(server: .notRequested, password: .notRequested, open: { cancelledOpen += 1 }, discard: { await held.close(); return true })
        }
        pending.address = servers[0].address.displayAddress; pending.account = "generated"; pending.password = "generated-only"; pending.connect()
        try await wait { release != nil }
        pending.cancel(); try require(pending.busy && pending.password.isEmpty, "Cancel released the UI owner early")
        release?.resume(); release = nil
        var entered = held.entered.stream.makeAsyncIterator(); _ = await entered.next()
        try require(pending.busy && cancelledOpen == 0, "Cancelled success handed off a connection")
        await held.finish(); try await wait { !pending.busy }
        try require(cancelledOpen == 0 && !pending.connected, "Cancelled unpublished connection became active")

        var lateRelease: CheckedContinuation<Void, Never>?, lateClosed = 0, lateOpen = 0
        let late = SMBConnectModel { _, _ in
            await withCheckedContinuation { lateRelease = $0 }
            return .init(server: .saved, password: .incomplete, open: { lateOpen += 1 }, discard: { true })
        }
        late.onCancelled = { lateClosed += 1 }
        late.address = servers[0].address.displayAddress; late.account = "generated"; late.password = "generated-only"; late.connect()
        try await wait { lateRelease != nil }; late.cancel(); lateRelease?.resume(); lateRelease = nil
        try await wait { !late.busy }
        try require(late.cancellationNotice && late.message == "Connection closed. Server saved. Password saving needs review."
            && lateOpen == 0 && lateClosed == 0, "Late remembering was hidden by a cancellation message")
        late.cancel(); try require(lateClosed == 1, "Acknowledged cancellation notice did not close")

        let denied = SMBConnectModel { _, _ in throw SMBWorkerFailure.authentication }
        denied.address = servers[0].address.displayAddress; denied.account = "generated"; denied.password = "generated-only"; denied.connect()
        try await wait { !denied.busy }
        try require(!denied.connected && denied.message.contains("wasn’t accepted"), "Authentication failure was not shown honestly")
        denied.cancel()
        let unavailableCounts = HandoffCounts()
        let unavailable = SMBConnectModel { _, _ in
            .init(server: .saved, password: .notRequested, open: { unavailableCounts.opened += 1 }, discard: {
                await MainActor.run { unavailableCounts.discarded += 1 }; return true
            }, canOpen: { false })
        }
        unavailable.address = servers[0].address.displayAddress; unavailable.account = "generated"; unavailable.password = "generated-only"
        unavailable.connect(); try await wait { !unavailable.busy }
        try require(unavailableCounts.opened == 0 && unavailableCounts.discarded == 1 && !unavailable.connected
            && unavailable.message.contains("destination pane closed") && unavailable.message.contains("Server saved"),
            "Closed pane published a hidden connection or lost actual remembering outcome")
        var passwordOnlyCalls = 0
        let passwordOnly = SMBConnectModel { input, _ in
            try require(input.password == nil && input.rememberPassword && !input.rememberServer, "Blank saved-password intent differs")
            passwordOnlyCalls += 1
            throw SMBPasswordFailure.missing
        }
        passwordOnly.address = servers[0].address.displayAddress; passwordOnly.account = "generated"; passwordOnly.rememberPassword = true
        passwordOnly.managing = true; passwordOnly.connect(); await Task.yield()
        try require(passwordOnlyCalls == 0, "Connect interleaved with settings management")
        passwordOnly.managing = false; passwordOnly.connect(); try await wait { !passwordOnly.busy }
        try require(passwordOnlyCalls == 1 && passwordOnly.message.contains("No saved password"), "Missing saved-password intent was not explicit")
        var sftpCalls = 0, sftpOpened = 0
        let sftp = SMBConnectModel { _, _ in throw UIVerification.Failure(message: "SFTP entered SMB setup") }
        sftp.sftpHandler = { input, _ in
            sftpCalls += 1
            try require(input.draft.address.host == "generated.invalid" && input.draft.account == "generated" && input.password != nil,
                "SFTP did not freeze its own typed request")
            return .init(server: .notRequested, password: .notRequested, open: { sftpOpened += 1 }, discard: { true })
        }
        sftp.password = "generated-only"; sftp.connectionProtocol = .sftp
        try require(sftp.password.isEmpty && !sftp.rememberServer && !sftp.rememberPassword, "Protocol switch retained secret or remembering intent")
        sftp.address = "smb://generated.invalid/Folder"; sftp.account = "generated"; sftp.connect(); await Task.yield()
        try require(sftpCalls == 0 && !sftp.busy, "SFTP accepted an SMB address")
        sftp.address = "generated.invalid"; sftp.account = "caf\u{e9}"; sftp.password = "generated-only"; sftp.account = "cafe\u{301}"
        try require(sftp.password.isEmpty, "Canonical-equivalent account edit retained a secret")
        sftp.account = "generated"; sftp.password = "generated-only"; sftp.connect(); sftp.address = "different.invalid"
        try await wait { !sftp.busy }; try require(sftpCalls == 1 && sftpOpened == 1, "SFTP frozen handoff failed")
        sftp.connectionProtocol = .smb
        try require(sftp.address.isEmpty && sftp.account.isEmpty && sftp.password.isEmpty, "Protocol switch mixed endpoints")
        let controller = SMBConnectWindowController(settings: settings, servers: servers) { _, phase in
            phase("Validating generated connection…")
            return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        guard let window = controller.window else { throw UIVerification.Failure(message: "Native Connect window missing") }
        controller.model.messageForGeneratedReview()
        controller.model.onConnected = { [weak controller] in controller?.model.messageForGeneratedReview() }
        settings.appearance = .dark
        window.title = "Connect to Server · generated review · no network"
        if review { controller.present() }
        else { window.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        try require(abs(window.frame.width - 600) < 1 && (500...640).contains(window.frame.height), "Compact Connect geometry changed after hosting layout")
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/connect-compact.png"))
        settings.appearance = .light
        try await Task.sleep(for: .milliseconds(300))
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/connect-light.png"))
        settings.appearance = .dark
        controller.setSidebarVisible(true, animated: false)
        controller.model.choose(servers[0].id); controller.model.showAdvanced = true
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/connect-sidebar-advanced.png"))
        controller.model.showAdvanced = false; controller.model.choose(nil)
        controller.setSidebarVisible(false, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        if ProcessInfo.processInfo.arguments.contains("--record-shared-connect") {
            settings.navigationStyle = .glass; settings.glassFileContent = true
            controller.model.sftpHandler = { _, _ in throw SFTPSessionFailure.stopped }
            controller.model.connectionProtocol = .sftp; controller.model.address = "sftp://generated.invalid/"; controller.model.account = "generated"
            controller.model.rememberServer = true; controller.model.name = "Generated SFTP"
            window.setContentSize(.init(width: 600, height: 580)); controller.present()
            try await Task.sleep(for: .milliseconds(200))
            let report = try await NativeMotionRecorder.record(window: window, root: root, label: "setup-connect") { controller.model.showAdvanced = true }
            try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/setup-connect.json"), options: .withoutOverwriting)
            controller.model.connectionProtocol = .smb; controller.model.showAdvanced = false
            try await Task.sleep(for: .milliseconds(250))
            let smb = try await NativeMotionRecorder.record(window: window, root: root, label: "setup-smb") { controller.model.showAdvanced = true }
            try JSONEncoder().encode(smb).write(to: root.appendingPathComponent("evidence/setup-smb.json"), options: .withoutOverwriting)
            let state = SFTPRememberedState(settings: .init(directory: root.appendingPathComponent("source/UncreatedSFTP")), passwords: .loginKeychain())
            let storage = try SMBTemporaryStorage(directory: root.appendingPathComponent("source/UncreatedRemotePool"))
            let storageWindow = SFTPConnectionStorageWindow(settings: settings, remembered: state, storage: storage)
            storageWindow.window?.title = "SFTP Storage · generated review"; storageWindow.present(relativeTo: window)
            try await wait { !storageWindow.model.busy }
            if let nativeWindow = storageWindow.window {
                let capture = try await NativeMotionRecorder.record(window: nativeWindow, root: root, label: "setup-storage") {}
                try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/setup-storage.json"), options: .withoutOverwriting)
            }
            await storageWindow.closeAndDrain(); await state.drain()
        }
        if review { retained = controller; controller.present(); NSApplication.shared.activate() }
        else { window.close() }
        let savedReconnect = try await SFTPTrustVerification.savedReconnectChecks()
        return ["passed": true, "sftpTypedSetup": sftpCalls == 1 && sftpOpened == 1, "exactAccountEdit": true,
            "savedReconnectChecks": savedReconnect, "checks": ["Compact form plus optional server sidebar", "Independent remembering defaults",
            "Typed input before admission", "Endpoint edit clears password", "Success handoff once", "Cancel retains owner through discard",
            "Authentication failure remains inline", "Shared Glass/Solid chrome", "Cancelled remembering reports actual outcomes before dismissal"],
            "networkConnections": 0, "keychainAccesses": 0, "savedPersonalPreferences": false,
            "reviewKeptOpen": review, "notExercised": ["Authenticated Connect from this form", "Saved-server persistence", "VoiceOver physical acceptance"]]
    }
    private static func require(_ value: Bool, _ reason: String) throws { if !value { throw UIVerification.Failure(message: reason) } }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw UIVerification.Failure(message: "Generated Connect state did not settle")
    }
    private actor DiscardHold {
        nonisolated let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        private var release: CheckedContinuation<Void, Never>?
        func close() async { entered.continuation.yield(()); await withCheckedContinuation { release = $0 } }
        func finish() { release?.resume(); release = nil }
    }
    @MainActor private final class HandoffCounts { var opened = 0, discarded = 0 }
}
#endif
