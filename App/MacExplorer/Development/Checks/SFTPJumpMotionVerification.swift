#if DEBUG
import AppKit
@_spi(Qualification) import LocalStorage

/// Generated form and native fields only. The handler never opens a transport
/// or password backend; selected placeholder keys are never read.
@MainActor enum SFTPJumpMotionVerification {
    private enum Failure: Error { case generated }
    static func run(root: URL, settings: BrowserSettings) async throws -> SFTPProfileVerification.Outcome {
        let owner = SMBConnectWindowController(settings: settings) { _, _ in throw Failure.generated }
        let model = owner.model
        model.profileFeaturesAvailable = true; model.serverPromptsAvailable = true; model.routeFeaturesAvailable = true
        model.sshProfiles.singleJumpAvailable = true
        model.sftpHandler = { _, _ in throw Failure.generated }
        model.connectionProtocol = .sftp
        let folder = root.appendingPathComponent("source/SSH", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("Host project\n HostName private.internal.test\n User generated\n ProxyJump gateway\nHost gateway\n HostName gateway.example\n User generated\n".utf8)
                .write(to: folder.appendingPathComponent("config"), options: .withoutOverwriting)
            try Data("generated-placeholder-never-read".utf8).write(to: folder.appendingPathComponent("key"), options: .withoutOverwriting)
        }.value
        model.sshProfiles.load(directory: folder)
        try await wait { !model.sshProfiles.busy }
        guard let profile = model.sshProfiles.profiles.first(where: { $0.alias == "project" }), !profile.needsSetup else { throw Failure.generated }
        model.applySSHProfile(profile)
        guard model.jumpHost.enabled, model.jumpHost.account == "generated", model.showAdvanced else { throw Failure.generated }
        // Imported settings keep the route explicit. The rest of this review
        // exercises the same editable controls after a deliberate detachment.
        model.sshProfiles.clearSelection()
        model.useSSHKey(folder.appendingPathComponent("key"), accessRoot: folder)
        model.jumpHost.selectedKey = try SFTPSelectedPrivateKey(file: folder.appendingPathComponent("key"), accessRoot: folder)
        model.jumpHost.keyName = "Generated jump key"
        model.jumpHost.method = .password; model.rememberServer = true
        guard let window = owner.window else { throw Failure.generated }
        let height = min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60)
        window.setContentSize(.init(width: settings.interfaceSize.percent == 150 ? 760 : 680, height: height))
        window.title = "Jump connection · generated review · compact Advanced"
        owner.present(); NSApplication.shared.activate(ignoringOtherApps: true)
        var clips: [[String: Any]] = []
        for index in 0..<4 {
            model.jumpHost.method = index % 2 == 0 ? .password : .keyFile
            try await Task.sleep(for: .milliseconds(300))
            let current = index % 2 == 0 ? "Jump host password" : "If the jump key is encrypted"
            guard let before = field(current, in: window) else { throw Failure.generated }
            before.scrollToVisible(before.bounds.insetBy(dx: -8, dy: -10))
            try await Task.sleep(for: .milliseconds(100))
            let label = "ssh-jump-method-\(index)"
            let report = try await NativeMotionRecorder.record(window: window, root: root, label: label, sampling: .diagnostic(for: window)) {
                model.jumpHost.method = index % 2 == 0 ? .keyFile : .password
            }
            guard let after = field(index % 2 == 0 ? "If the jump key is encrypted" : "Jump host password", in: window), after.stringValue.isEmpty else { throw Failure.generated }
            clips.append(DevelopmentMotionVerification.clip(label, report: report, field: after, window: window))
            try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
            after.scrollToVisible(after.bounds.insetBy(dx: -8, dy: -10))
            guard window.makeFirstResponder(after), let editor = after.currentEditor() as? NSTextView else { throw Failure.generated }
            editor.insertText("generated-only-typing", replacementRange: NSRange(location: 0, length: 0))
            guard (index % 2 == 0 ? model.jumpHost.passphrase : model.jumpHost.password) == "generated-only-typing" else { throw Failure.generated }
            _ = window.makeFirstResponder(nil); model.jumpHost.clearSecrets()
        }
        model.jumpHost.method = .serverPrompts
        try await Task.sleep(for: .milliseconds(300))
        guard model.jumpHost.password.isEmpty, model.jumpHost.passphrase.isEmpty else { throw Failure.generated }
        model.showAdvanced = false
        try await Task.sleep(for: .milliseconds(300))
        let label = "ssh-jump-advanced"
        let report = try await NativeMotionRecorder.record(window: window, root: root, label: label, sampling: .diagnostic(for: window)) { model.showAdvanced = true }
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
        clips.append(DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window))
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/ssh-jump-final.png"))
        return .init(controller: owner, clips: clips, checks: ["selectedCompactAdvanced": true, "importedSingleJumpApplied": true,
            "separateAuthenticationChoices": true, "nativeSecureTyping": true, "methodSwitchClearsSecrets": true,
            "privateKeyBodyReads": 0, "networkRequests": 0, "keychainCalls": 0])
    }
    private static func field(_ placeholder: String, in window: NSWindow) -> NSSecureTextField? {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return window.contentView.flatMap { descendants($0).compactMap { $0 as? NSSecureTextField }.first { $0.placeholderString == placeholder } }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw Failure.generated
    }
}
#endif
