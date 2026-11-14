#if DEBUG
import AppKit
import Foundation
@_spi(Qualification) import LocalStorage

/// Generated native setup only. No transport, personal SSH file or Keychain
/// backend is installed. The ordinary feature remains independently gated.
@MainActor enum SFTPProfileVerification {
    struct Outcome {
        let controller: SMBConnectWindowController
        let clips: [[String: Any]]
        let checks: [String: Any]
    }
    static func run(root: URL, settings: BrowserSettings) async throws -> Outcome {
        var calls = 0, keySubmissions = 0, certificateSubmissions = 0, passwordSubmissions = 0
        let owner = SMBConnectWindowController(settings: settings) { _, _ in throw Failure.generated }
        owner.model.profileFeaturesAvailable = true
        owner.model.sftpHandler = { submission, _ in
            guard let choice = submission.authentication,
                  !String(reflecting: submission).contains("generated-private") else { throw Failure.generated }
            switch choice {
            case .password: passwordSubmissions += 1
            case .keyFile(let selected, _, _, let alias):
                guard selected != nil, alias == "studio", !submission.rememberPassword else { throw Failure.generated }
                keySubmissions += 1
            case let .userCertificate(key, certificate, _, rememberAccess, alias, prompts):
                guard key != nil, certificate != nil, rememberAccess, alias == "certificate",
                      submission.rememberServer, !submission.rememberPassword, !prompts else { throw Failure.generated }
                certificateSubmissions += 1
            case .serverPrompts, .keyFileWithServerPrompts: throw Failure.generated
            }
            calls += 1
            return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        owner.model.connectionProtocol = .sftp
        owner.model.address = "generated.example"; owner.model.account = "generated"
        owner.model.onConnected = { } // Keep this generated window for inspection.
        guard let window = owner.window else { throw Failure.generated }
        window.title = "SSH profiles · generated review · motion audit"; window.setContentSize(.init(width: 660, height: 660))
        owner.present(); NSApplication.shared.activate(ignoringOtherApps: true)
        let directory = root.appendingPathComponent("source/SSH", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let text = "Host studio\n HostName generated.example\n User generated\n IdentityFile \(directory.appendingPathComponent("fixture-key").path)\nHost company\n HostName company.example\n User generated\n ProxyCommand generated-never-executed\nHost certificate\n HostName certificate.example\n User generated\n IdentityFile \(directory.appendingPathComponent("fixture-key").path)\n CertificateFile \(directory.appendingPathComponent("fixture-key-cert.pub").path)\n PreferredAuthentications publickey\n"
            try Data(text.utf8).write(to: directory.appendingPathComponent("config"), options: .withoutOverwriting)
            try Data("generated-placeholder-not-a-key".utf8).write(to: directory.appendingPathComponent("fixture-key"), options: .withoutOverwriting)
            try Data("generated-placeholder-not-a-certificate".utf8).write(to: directory.appendingPathComponent("fixture-key-cert.pub"), options: .withoutOverwriting)
        }.value
        owner.model.sshProfiles.load(directory: directory)
        try await wait { !owner.model.sshProfiles.busy }
        guard owner.model.sshProfiles.profiles.count == 3,
              let studio = owner.model.sshProfiles.profiles.first(where: { $0.alias == "studio" }),
              let company = owner.model.sshProfiles.profiles.first(where: { $0.alias == "company" }), company.needsSetup,
              let certificate = owner.model.sshProfiles.profiles.first(where: { $0.alias == "certificate" }), certificate.needsSetup else { throw Failure.generated }
        owner.model.applySSHProfile(company); owner.model.connect()
        guard calls == 0, !owner.model.busy else { throw Failure.generated }
        owner.model.applySSHProfile(studio)
        owner.model.useSSHKey(directory.appendingPathComponent("fixture-key"), accessRoot: directory)
        owner.model.keyPassphrase = "generated-private-passphrase"
        owner.model.sftpAuthentication = .password
        guard owner.model.keyPassphrase.isEmpty else { throw Failure.generated }
        owner.model.password = "generated-private-password"
        owner.model.sftpAuthentication = .keyFile
        guard owner.model.password.isEmpty else { throw Failure.generated }
        owner.model.rememberServer = true; owner.model.rememberKeyAccess = true; owner.model.rememberServer = false
        guard !owner.model.rememberKeyAccess else { throw Failure.generated }
        var clips: [[String: Any]] = []
        for index in 0..<4 {
            owner.model.sftpAuthentication = index % 2 == 0 ? .password : .keyFile
            try await Task.sleep(for: .milliseconds(300))
            let label = "ssh-authentication-\(index)"
            let report = try await NativeMotionRecorder.record(window: window, root: root, label: label, sampling: .diagnostic(for: window)) {
                owner.model.sftpAuthentication = index % 2 == 0 ? .keyFile : .password
            }
            let placeholder = owner.model.sftpAuthentication == .keyFile ? "If the key is encrypted" : "Password"
            let field = descendants(window.contentView).compactMap { $0 as? NSSecureTextField }.first { $0.placeholderString == placeholder }
            guard let field, field.stringValue.isEmpty else { throw Failure.stage("secure-field-\(index)") }
            clips.append(DevelopmentMotionVerification.clip(label, report: report, field: field, window: window))
            try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
            guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.stage("secure-focus-\(index)") }
            editor.insertText("generated-only-typing-control", replacementRange: NSRange(location: 0, length: 0))
            guard field.stringValue == "generated-only-typing-control" else { throw Failure.stage("secure-input-\(index)") }
            _ = window.makeFirstResponder(nil); owner.model.password = ""; owner.model.keyPassphrase = ""
        }
        owner.model.sftpAuthentication = .keyFile
        owner.model.connect(); try await wait { !owner.model.busy }
        guard calls == 1, keySubmissions == 1, passwordSubmissions == 0, owner.model.connected else { throw Failure.generated }
        owner.model.applySSHProfile(certificate)
        try require(owner.model.useUserCertificate && !owner.model.activeProfileNeedsSetup)
        owner.model.useSSHKey(directory.appendingPathComponent("fixture-key"), accessRoot: directory)
        owner.model.useSSHCertificate(directory.appendingPathComponent("fixture-key-cert.pub"), directory: directory)
        owner.model.rememberServer = true; owner.model.rememberKeyAccess = true
        owner.model.connect(); try await wait { !owner.model.busy }
        try require(calls == 2 && certificateSubmissions == 1 && owner.model.connected)
        let markerID = UUID()
        let marker = SFTPConnectServerChoice(id: markerID,
            details: try .init(name: "Generated certificate setup", address: .init("sftp://certificate.example"), account: "generated"),
            hasSavedPassword: false, keyAuthentication: try .init(requiresCertificate: true))
        owner.model.replaceSFTPServers([marker]); owner.model.choose(markerID)
        try require(owner.model.useUserCertificate && !owner.model.savedKeyAvailable && !owner.model.savedCertificateAvailable)
        owner.model.connect(); try require(calls == 2 && !owner.model.busy)
        owner.model.connectionProtocol = .smb
        guard owner.model.address.isEmpty, owner.model.selectedKey == nil, owner.model.keyPassphrase.isEmpty else { throw Failure.generated }
        owner.model.connectionProtocol = .sftp; owner.model.applySSHProfile(certificate)
        owner.model.useSSHKey(directory.appendingPathComponent("fixture-key"), accessRoot: directory)
        owner.model.useSSHCertificate(directory.appendingPathComponent("fixture-key-cert.pub"), directory: directory)
        owner.model.rememberServer = true; owner.model.rememberKeyAccess = true
        try await Task.sleep(for: .milliseconds(300))
        // SwiftUI's cached AppKit render can resolve controls differently from
        // the compositor. Use the same real-window recorder for the new form.
        let certificateLabel = "ssh-certificate-ready"
        let certificateClip = try await NativeMotionRecorder.record(window: window, root: root,
            label: certificateLabel, sampling: .diagnostic(for: window)) {
                window.contentView?.layoutSubtreeIfNeeded()
            }
        try JSONEncoder().encode(certificateClip).write(to: root.appendingPathComponent("evidence/\(certificateLabel).json"), options: .withoutOverwriting)
        clips.append(DevelopmentMotionVerification.clip(certificateLabel, report: certificateClip, field: nil, window: window))
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/ssh-final.png"))
        return .init(controller: owner, clips: clips, checks: ["profileImport": true, "unsupportedCommandNoSubmission": true,
            "methodSwitchClearsSecrets": true, "rememberKeyRequiresServer": true, "frozenKeySubmission": true,
            "certificateProfileSubmission": true, "certificateSetupRetainsMethod": true,
            "protocolSwitchClearsKey": true, "privateKeyBodyReads": 0, "networkAttempts": 0, "keychainCalls": 0])
    }
    private static func require(_ condition: @autoclosure () -> Bool) throws { guard condition() else { throw Failure.generated } }
    private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }; throw Failure.generated
    }
    private enum Failure: Error { case generated, stage(String) }
}
#endif
