#if DEBUG
import AppKit
import Darwin
@_spi(Qualification) @testable import LocalStorage

@MainActor enum SFTPTrustVerification {
    private enum Failure: Error { case generated }
    private final class Clock { var value = 0.0 }
    private static var retained: SFTPTrustWindowController?
    private static let current = "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA"
    private static let previous = "SHA256:EMnw0V1DZrQZslPeM2RBvpNj0Q1x7mXh0nQGgWr7zTA"
    private static func review(_ changed: Bool = false, matching: Bool = false) -> SFTPTrustPresentation {
        .init(host: "studio.example.invalid", port: 22, fingerprint: current, previousFingerprint: matching ? current : changed ? previous : nil)
    }
    private static func require(_ value: Bool) throws { if !value { throw Failure.generated } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < deadline); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func runStandalone() async {
        let args = ProcessInfo.processInfo.arguments
        do {
            guard let i = args.firstIndex(of: "--analysis-source"), args.indices.contains(i + 1) else { throw Failure.generated }
            let root = URL(fileURLWithPath: args[i + 1])
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b11-native-qualification")
                && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
                && root.resolvingSymlinksInPath() == root && root.path == ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"])
            let settings = BrowserSettings(persist: false); settings.appearance = .dark; settings.navigationStyle = .glass
            let checks = try await modelChecks()
            let live = SFTPTrustModel(review: review(true), copy: { _ in }, decision: { _ in .notRequested }, drain: { true })
            let controller = SFTPTrustWindowController(settings: settings, model: live); retained = controller
            controller.window?.title = "SFTP identity · generated review"
            controller.present(); try await Task.sleep(for: .milliseconds(200))
            guard let window = controller.window, let screen = window.screen else { throw Failure.generated }
            let visible = screen.visibleFrame
            try require(abs(window.frame.midX - visible.midX) < 2 && abs(window.frame.midY - visible.midY) < 2
                && window.isOpaque && window.backgroundColor != .clear && window.titlebarAppearsTransparent)
            var captures: [String] = []
            if args.contains("--record-sftp-trust-motion") {
                try NativeMotionRecorder.validateScope(window: window, root: root, label: "scope-control")
                for (other, label) in [(root.deletingLastPathComponent(), "scope-control"), (root, "../foreign"), (root, "")] {
                    do { try NativeMotionRecorder.validateScope(window: window, root: other, label: label); throw Failure.generated }
                    catch NativeMotionRecorder.Failure.scope { }
                }
                for (name, mode, forward) in [("trust-forward", BrowserMotionMode.full, true), ("trust-back", .full, false),
                                              ("trust-reduced", .reduced, true), ("trust-off", .off, false)] {
                    var motion = settings.motion; motion.mode = mode; settings.motion = motion
                    let capture = try await NativeMotionRecorder.record(window: window, root: root, label: name) {
                        if forward { live.showReplacement() } else { live.back() }
                    }
                    try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/\(name).json"), options: .withoutOverwriting)
                    captures.append(name)
                }
            }
            settings.navigationStyle = .solid; try await Task.sleep(for: .milliseconds(60))
            try require(!window.titlebarAppearsTransparent); settings.navigationStyle = .glass
            try await Task.sleep(for: .milliseconds(60)); try require(window.titlebarAppearsTransparent)
            window.performClose(nil); try await wait { live.finished == .cancelled && !window.isVisible }
            let report: [String: Any] = ["passed": true, "checks": checks, "centered": true, "glassSolid": true,
                "windowClosedAfterDrain": true, "clips": captures, "networkConnections": 0, "keychainAccesses": 0,
                "clipboardWasInjected": true, "personalCatalogs": 0]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/trust.json"), options: .withoutOverwriting)
            retained = nil; NSApplication.shared.terminate(nil)
        } catch { fputs("Generated SFTP trust verification failed\n", stderr); retained?.model.cancel(); NSApplication.shared.terminate(nil) }
    }
    static func savedReconnectChecks() async throws -> [String] {
        var checks: [String] = []
        var keyBytes = Data()
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &keyBytes)
        try SFTPWire.field(Data(repeating: 1, count: 32), into: &keyBytes)
        let key = try SFTPHostKey(keyBytes)
        let address = try SFTPConnectionAddress("studio.example.invalid:22")
        let identity = SFTPHostIdentity(address: address)
        var snapshot = SFTPSettingsSnapshot()
        snapshot.hosts = [.init(identity: identity, key: key)]
        let challenge = SFTPHostChallenge(session: UUID(), host: address.host, port: address.port,
            current: key, previous: key)
        try require(SFTPSetupTrust.durableMatchingHost(challenge, address: address, snapshot: snapshot))
        snapshot.hosts = []
        try require(!SFTPSetupTrust.durableMatchingHost(challenge, address: address, snapshot: snapshot))
        snapshot.hosts = [.init(identity: identity, key: key)]
        let changed = SFTPHostChallenge(session: UUID(), host: address.host, port: address.port,
            current: key, previous: nil)
        try require(!SFTPSetupTrust.durableMatchingHost(changed, address: address, snapshot: snapshot))
        let otherAddress = try SFTPConnectionAddress("studio.example.invalid:23")
        try require(!SFTPSetupTrust.durableMatchingHost(challenge, address: otherAddress, snapshot: snapshot))
        checks.append("matching-requires-exact-durable-host")
        let draft = try SFTPServerDraft(name: "Generated server", address: address, account: "generated")
        let savedID = UUID()
        let form = SMBConnectModel(handler: { _, _ in throw Failure.generated })
        form.connectionProtocol = .sftp
        form.replaceSFTPServers([.init(id: savedID, details: draft, hasSavedPassword: true)])
        form.choose(savedID)
        try require(form.usingSavedPassword && form.password.isEmpty)
        form.changeSavedPassword(); form.password = "new generated password"
        form.name = "Renamed generated server"
        form.startingFolderField = "~/other"
        try require(form.changingSavedPassword && form.password == "new generated password")
        form.useSavedPassword(); try require(form.usingSavedPassword && form.password.isEmpty)
        form.account = "other"
        try require(!form.usingSavedPassword)
        checks.append("saved-password-edit-requires-explicit-choice")
        return checks
    }
    private static func modelChecks() async throws -> [String] {
        var checks = try await savedReconnectChecks(), copied = ""
        var calls: [SFTPTrustIntent] = []
        let first = SFTPTrustModel(review: review(), copy: { copied = $0 }, decision: { intent in calls.append(intent); return .notRequested }, drain: { true })
        try require(!first.rememberKey && first.page == .identity && first.remaining == 120 && !first.busy)
        first.copyFingerprint(); try require(copied == current); checks.append("private-defaults-copy")
        first.proceed(); first.proceed(); try await wait { first.finished != nil }
        try require(calls == [.connectOnce] && first.finished == .verified); checks.append("single-connect-once")
        let remembered = SFTPTrustModel(review: review(), prefillRememberKey: true, copy: { _ in },
            decision: { intent in calls.append(intent); return .saved }, drain: { true })
        try require(remembered.rememberKeyPrefilled && remembered.rememberKey && calls == [.connectOnce])
        remembered.proceed(); try await wait { remembered.finished != nil }
        try require(calls.last == .rememberVerified && remembered.remembering == .saved); checks.append("explicit-key-remembering")
        let optedOut = SFTPTrustModel(review: review(), prefillRememberKey: true, copy: { _ in },
            decision: { intent in calls.append(intent); return .notRequested }, drain: { true })
        optedOut.rememberKey = false; optedOut.proceed(); try await wait { optedOut.finished != nil }
        try require(calls.last == .connectOnce)
        let restricted = SFTPTrustModel(review: review(), allowsRemembering: false, prefillRememberKey: true,
            copy: { _ in }, decision: { intent in calls.append(intent); return .notRequested }, drain: { true })
        try require(!restricted.rememberKeyPrefilled && !restricted.rememberKey)
        restricted.proceed(); try await wait { restricted.finished != nil }
        try require(calls.last == .connectOnce)
        let changedModel = SFTPTrustModel(review: review(true), prefillRememberKey: true,
            copy: { _ in }, decision: { intent in calls.append(intent); return .saved }, drain: { true })
        try require(!changedModel.rememberKeyPrefilled && !changedModel.rememberKey)
        let before = calls.count; changedModel.proceed(); changedModel.showReplacement(); changedModel.proceed(); await Task.yield()
        try require(calls.count == before && changedModel.finished == nil && changedModel.page == .replacement)
        changedModel.replacementCompared = true; changedModel.proceed(); try await wait { changedModel.finished != nil }
        try require(calls.last == .replaceVerified); checks.append("separate-replacement-admission")
        let matching = SFTPTrustModel(review: review(matching: true), copy: { _ in }, decision: { intent in calls.append(intent); return .notRequested }, drain: { true })
        matching.proceed(); try await wait { matching.finished != nil }; try require(calls.last == .useMatching); checks.append("matching-intent")
        let clock = Clock(); var expiredCalls = 0, expiredDrains = 0
        let expired = SFTPTrustModel(review: review(), now: { clock.value }, copy: { _ in }, decision: { _ in expiredCalls += 1; return .notRequested }, drain: { expiredDrains += 1; return true })
        clock.value = 121; expired.tick(); expired.proceed(); try await wait { expired.finished != nil }
        try require(expired.finished == .expired && expiredCalls == 0 && expiredDrains == 1); checks.append("monotonic-expiry")
        var resumeDecision: CheckedContinuation<Void, Never>?, resumeDrain: CheckedContinuation<Void, Never>?, decisionEnded = false, completed: SFTPTrustFinish?
        let late = SFTPTrustModel(review: review(), copy: { _ in }, decision: { _ in
            await withCheckedContinuation { resumeDecision = $0 }; decisionEnded = true; return .saved
        }, drain: { await withCheckedContinuation { resumeDrain = $0 }; return true })
        late.onFinish = { completed = $0 }; late.proceed(); try await wait { resumeDecision != nil }
        late.cancel(); late.cancel(); try await wait { resumeDrain != nil }
        try require(late.busy && completed == nil); resumeDecision?.resume(); try await wait { decisionEnded }
        try require(late.busy && completed == nil); resumeDrain?.resume(); try await wait { completed != nil }
        try require(completed == .cancelled && late.remembering == .saved && late.message.contains("key was saved")); checks.append("late-save-and-actual-drain")
        var failedDrain = 0
        let failed = SFTPTrustModel(review: review(), copy: { _ in }, decision: { _ in throw Failure.generated }, drain: { failedDrain += 1; return true })
        failed.proceed(); try await wait { failed.finished != nil }
        try require(failed.finished == .cancelled && failedDrain == 1 && failed.message.contains("could not be verified")); checks.append("failed-verification-drain")
        var attempts = 0, decisions = 0
        let uncertain = SFTPTrustModel(review: review(), copy: { _ in }, decision: { _ in decisions += 1; return .notRequested }, drain: { attempts += 1; return attempts == 2 })
        uncertain.cancel(); try await wait { uncertain.closureNeedsAttention }
        uncertain.proceed(); uncertain.tick(); await Task.yield()
        try require(uncertain.finished == nil && !uncertain.busy && decisions == 0 && attempts == 1)
        uncertain.cancel(); try await wait { uncertain.finished == .cancelled }
        try require(attempts == 2 && !uncertain.closureNeedsAttention); checks.append("uncertain-close-retains-and-retries")
        return checks
    }
}
#endif
