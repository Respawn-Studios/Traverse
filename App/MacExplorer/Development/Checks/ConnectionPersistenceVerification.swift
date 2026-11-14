#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

enum ConnectionQualificationFailure: Error { case stage(String) }

private final class ConnectionVerificationCalls: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func hit() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private final class ConnectionVerificationGate: @unchecked Sendable {
    private let condition = NSCondition(); private var started = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hold() throws {
        condition.lock(); defer { condition.unlock() }; started = true
        let deadline = Date().addingTimeInterval(2)
        while !released { guard condition.wait(until: deadline) else { throw SFTPSettingsFailure.unavailable } }
    }
}

@MainActor enum ConnectionPersistenceVerification {
    private enum PinReadinessBoundary: String {
        case generatedParent = "generated-parent"
        case saveGeneratedMetadata = "save-generated-metadata"
        case heldGeneratedLoad = "held-generated-load"
        case propertiesLoad = "properties-load"
        case ready = "ready"
        case nativePin = "native-pin"
        case coldRead = "cold-read"
        case liveOwner = "live-owner"
        case subscriptionClose = "subscription-close"
    }
    private static var pinReadinessBoundary = PinReadinessBoundary.generatedParent
    private static func settingsFailureCode(_ failure: RemoteSettingsFailure) -> String {
        switch failure {
        case .unsafe: "unsafe"
        case .unavailable: "unavailable"
        case .busy: "busy"
        case .cancelled: "cancelled"
        case .notOpen: "not-open"
        case .staleRevision: "stale-revision"
        case .invalidRecord: "invalid-record"
        case .incompatibleVersion: "incompatible-version"
        case .recoveryRequired: "recovery-required"
        case .durabilityUncertain: "durability-uncertain"
        case .capacity: "capacity"
        case .missing: "missing"
        }
    }
    private(set) static var pinAdmissionObservations: [[String: Any]] = []
    private(set) static var pinReadinessLoadDrained = true
    private static func observePin(_ stage: String, browser: BrowserViewController,
                                   owner: SFTPTabController, properties: ConnectionPropertiesController) {
        guard pinAdmissionObservations.count < 4 else { return }
        var values: [String: Any] = [:]
        values["stage"] = stage
        values["pinReady"] = browser.remotePins.isReady
        values["pinCanEdit"] = browser.remotePins.canEdit
        values["pinSaving"] = browser.remotePins.isSaving
        values["pinCount"] = browser.remotePins.collection.pins.count
        values["propertySourceCurrent"] = properties.sourceCurrentForVerification
        values["propertyWorkPending"] = properties.hasPendingWorkForVerification
        values["propertyPinEnabled"] = properties.pinButtonForVerification.isEnabled
        values["propertyPinNoticeVisible"] = !properties.pinNoticeForVerification.isHiddenOrHasHiddenAncestor
        values["propertyPinNoticeLoading"] = properties.pinNoticeForVerification.stringValue.contains("loading")
        values["propertyPinObservationActive"] = properties.pinObservationActiveForVerification
        values["ownerNavigationAdmitted"] = owner.navigationAdmittedForVerification
        values["browserSuspended"] = browser.isBrowserSuspended
        values["browserActivePane"] = browser.isActiveCommandPane
        values["sourceWindowVisible"] = browser.view.window?.isVisible == true
        values["browserReportedPinLoading"] = browser.status.stringValue.contains("Connection pins are loading or saving")
        pinAdmissionObservations.append(values)
    }
    private static func check(_ value: Bool, _ stage: String) throws {
        if !value { throw ConnectionQualificationFailure.stage(stage) }
    }
    private static func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            try check(ProcessInfo.processInfo.systemUptime < limit, stage)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private typealias Calls = ConnectionVerificationCalls
    private typealias Gate = ConnectionVerificationGate
    @MainActor private final class Context {
        var states: [SFTPRememberedState] = [], smb: [SMBConnectionCoordinator] = []
        var profiles: [ApplicationSMBConnections] = [], pins: [RemoteConnectionPinsController] = []
        var properties: ConnectionPropertiesController?
        func close() async {
            await properties?.closeAndDrain(); properties = nil
            for profile in profiles { await profile.closeAndDrain() }
            for pin in pins { _ = await pin.flush() }
            for state in states { await state.drain() }
            for state in smb { await state.drain() }
        }
    }
    static func run(root: URL, browser: BrowserViewController, owner: SFTPTabController) async throws -> [String] {
        pinAdmissionObservations = []
        let context = Context()
        do {
            let result = try await controls(root: root, browser: browser, owner: owner, context: context)
            await context.close(); return result
        } catch { await context.close(); throw error }
    }
    static func runPinReadiness(root: URL, browser: BrowserViewController, owner: SFTPTabController) async throws -> [String] {
        pinAdmissionObservations = []
        pinReadinessLoadDrained = true
        pinReadinessBoundary = .generatedParent
        let context = Context()
        do {
            let result = try await pinReadiness(root: root, browser: browser, owner: owner, context: context)
            await context.close(); return result
        } catch let issue as RemoteSettingsFailure {
            await context.close()
            throw ConnectionQualificationFailure.stage("pin-readiness-" + pinReadinessBoundary.rawValue
                + "-remote-settings-" + settingsFailureCode(issue))
        } catch { await context.close(); throw error }
    }
    private static func pinReadiness(root: URL, browser: BrowserViewController,
                                     owner: SFTPTabController, context: Context) async throws -> [String] {
        let calls = Calls(), gate = Gate()
        let vault = SFTPPasswordVault.refusingQualification { calls.hit() }
        let smbVault = SMBPasswordVault.refusingQualification { calls.hit() }
        guard let draft = owner.presentation else { throw ConnectionQualificationFailure.stage("pin-readiness-presentation-missing") }
        let stateRoot = root.appendingPathComponent("state")
        var stateInfo = stat()
        try check(lstat(stateRoot.path, &stateInfo) == 0 && stateInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && stateInfo.st_uid == geteuid() && stateInfo.st_mode & 0o777 == 0o700,
            "pin-readiness-generated-state-not-private")
        let fixtureRoot = stateRoot.appendingPathComponent("pin-readiness")
        try check(mkdir(fixtureRoot.path, 0o700) == 0, "pin-readiness-generated-parent-create")
        pinReadinessBoundary = .saveGeneratedMetadata
        let store = SFTPSettingsStore(directory: fixtureRoot.appendingPathComponent("sftp"))
        let state = SFTPRememberedState(settings: store, passwords: vault); context.states.append(state)
        let result = try await state.saveMetadata(draft, expectedRevision: 0,
            directory: SFTPDefaultDirectory(legacy: draft.address))
        guard let id = result.serverID, let saved = result.snapshot.visibleServers.first(where: { $0.id == id }) else {
            throw ConnectionQualificationFailure.stage("pin-readiness-saved-target-missing")
        }
        let target = try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: id,
            binding: WorkspaceConnectionBinding.sftp(saved.details), title: saved.details.name, relativeToHome: true)
        owner.adoptSavedTarget(target); browser.refreshCurrentConnectionBookmark()
        let pinsRoot = root.appendingPathComponent("state/pin-readiness/pins")
        browser.pinsController = BrowserPinsController(stateDirectory: pinsRoot)
        let pins = browser.remotePins; context.pins.append(pins)
        pinReadinessBoundary = .heldGeneratedLoad
        pins.beforeLoadForVerification = { try gate.hold() }
        pinReadinessLoadDrained = false
        browser.connectPins()
        let loading = Task { await pins.restoreIfNeeded() }
        let profile = ApplicationSMBConnections(directory: root.appendingPathComponent("state/pin-readiness/profile"),
            passwords: smbVault, sftpPasswords: vault)
        context.profiles.append(profile)
        do {
            try await wait("pin-readiness-generated-load-not-held") { gate.entered }
            pinReadinessBoundary = .propertiesLoad
            guard let properties = ConnectionPropertiesController(browser: browser, profile: profile, access: .sftp(state)) else {
                throw ConnectionQualificationFailure.stage("pin-readiness-properties-missing")
            }
            context.properties = properties
            try await wait("pin-readiness-property-metadata") { !properties.hasPendingWorkForVerification }
            properties.window?.contentView?.layoutSubtreeIfNeeded()
            observePin("held-generated-load", browser: browser, owner: owner, properties: properties)
            try check(!pins.isReady && !pins.canEdit && properties.sourceCurrentForVerification,
                      "pin-readiness-load-not-pending")
            try check(!properties.pinButtonForVerification.isEnabled && !browser.canPinCurrentFolder,
                      "pin-readiness-loading-button-enabled")
            let pinNotice = properties.pinNoticeForVerification
            try check(pinNotice.window === properties.window && !pinNotice.isHiddenOrHasHiddenAncestor
                && pinNotice.stringValue.contains("loading"), "pin-readiness-local-loading-notice-missing")
            if let content = properties.window?.contentView {
                let noticeRect = pinNotice.convert(pinNotice.bounds, to: content)
                try check(!noticeRect.isEmpty && content.bounds.contains(noticeRect), "pin-readiness-notice-clipped")
            } else { throw ConnectionQualificationFailure.stage("pin-readiness-window-closed") }
            properties.pinButtonForVerification.performClick(nil)
            try check(pins.collection.pins.isEmpty && !pins.isSaving && properties.pinObservationActiveForVerification,
                      "pin-readiness-disabled-click-admitted-intent")
            pinReadinessBoundary = .ready
            gate.release(); await loading.value
            try await wait("pin-readiness-live-button-not-enabled") {
                pins.isReady && pins.canEdit && properties.pinButtonForVerification.isEnabled
            }
            pinReadinessLoadDrained = true
            pins.beforeLoadForVerification = nil
            observePin("ready-before-native-pin", browser: browser, owner: owner, properties: properties)
            try check(pins.collection.pins.isEmpty && browser.canPinCurrentFolder,
                      "pin-readiness-queued-intent-ran-after-load")
            let tab = browser.activeID, count = browser.tabs.count, connection = owner.connectionID
            pinReadinessBoundary = .nativePin
            properties.pinButtonForVerification.performClick(nil)
            try check(pins.collection.pins.count == 1, "native-pin-not-created")
            if pins.isSaving {
                try check(!properties.pinButtonForVerification.isEnabled, "pin-readiness-save-button-enabled-while-busy")
            }
            observePin("native-pin-admitted", browser: browser, owner: owner, properties: properties)
            _ = await pins.flush()
            try await wait("pin-readiness-save-button-not-reenabled") { properties.pinButtonForVerification.isEnabled }
            observePin("native-pin-actual-save-drained", browser: browser, owner: owner, properties: properties)
            try check(pins.collection.pins.count == 1 && pins.canEdit, "native-pin-not-created")
            pinReadinessBoundary = .coldRead
            let cold = RemoteConnectionPinsController(directory: pinsRoot); context.pins.append(cold)
            await cold.restoreIfNeeded()
            try check(cold.canEdit && cold.collection == pins.collection, "pin-readiness-cold-persistence-mismatch")
            let pin = pins.collection.pins[0]
            pinReadinessBoundary = .liveOwner
            browser.enterRemoteAddress("~/GeneratedAway")
            try await wait("pin-readiness-navigation-away") { owner.navigationAdmittedForVerification && browser.remoteAddressText == "~/GeneratedAway" }
            browser.openRemotePin(pin.id)
            try await wait("pin-readiness-live-owner-return") { owner.navigationAdmittedForVerification && browser.remoteAddressText == "~" }
            try check(browser.activeID == tab && browser.tabs.count == count && owner.connectionID == connection
                && browser.sftpTabs[tab] === owner && browser.orderedSelectedURLs.isEmpty,
                      "pin-readiness-created-session-or-local-authority")
            pinReadinessBoundary = .subscriptionClose
            await properties.closeAndDrain()
            try check(!properties.pinObservationActiveForVerification, "pin-readiness-closed-form-retained-observer")
            context.properties = nil
            try check(calls.count == 0, "pin-readiness-opened-credential-vault")
            return ["Held generated private metadata load keeps the actual Properties Pin disabled with a visible local notice; disabled click queues no intent",
                    "Actual readiness re-enables Pin, native click charges one save and disables until drain; a cold reader matches committed typed pins and activation reuses the same connection",
                    "Closing Properties cancels its weak readiness subscription; generated vault observes zero calls and no load/flush contract or credential grant changes"]
        } catch {
            gate.release(); await loading.value
            try? await wait("pin-readiness-failed-load-drain") { pins.isReady }
            pinReadinessLoadDrained = pins.isReady
            pins.beforeLoadForVerification = nil
            throw error
        }
    }

    private static func controls(root: URL, browser: BrowserViewController, owner: SFTPTabController, context: Context) async throws -> [String] {
        var checks: [String] = []
        let maximum = try (0..<128).map { _ in try SFTPRemoteName(Data([120])) }
        _ = try SFTPDefaultDirectory(root: .home, components: maximum)
        do { _ = try SFTPDefaultDirectory(root: .home, components: maximum + [.init(Data([120]))]); throw ConnectionQualificationFailure.stage("default-directory-depth129") }
        catch is SFTPDefaultDirectory.Failure { }
        for text in ["~/Folder/../Outside", "~/A//B", "~/Bad\nName", "/OtherRoot"] {
            do { _ = try SFTPDefaultDirectory(field: text, root: .home); throw ConnectionQualificationFailure.stage("unsafe-default-directory-accepted") }
            catch is SFTPDefaultDirectory.Failure { }
            catch is SFTPConnectionInputFailure { }
            catch SFTPProtocolFailure.invalidOutput { }
        }
        let calls = Calls()
        let vault = SFTPPasswordVault.refusingQualification { calls.hit() }
        let smbVault = SMBPasswordVault.refusingQualification { calls.hit() }
        guard let draft = owner.presentation else { throw ConnectionQualificationFailure.stage("fixture-presentation-missing") }
        let store = SFTPSettingsStore(directory: root.appendingPathComponent("state/sftp-metadata"))
        let state = SFTPRememberedState(settings: store, passwords: vault); context.states.append(state)
        let keyBytes = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + Data(repeating: 49, count: 32)
        let key = try SFTPHostKey(keyBytes)
        let access = try SFTPKeyAccessReference(bookmark: Data([1]), request: draft.request, host: key, identity: key)
        let method = try SFTPServerKeyAuthentication(reference: access)
        var snapshot = try await store.openForExplicitWrite().snapshot
        snapshot = try await store.apply(.saveHost(.init(identity: .init(address: draft.address), key: key), replacing: nil), revision: snapshot.revision).snapshot
        let savedResult = try await store.apply(.saveServer(draft, id: nil, credentialID: nil, keyAuthentication: method), revision: snapshot.revision)
        snapshot = savedResult.snapshot
        guard let serverID = savedResult.serverID else { throw ConnectionQualificationFailure.stage("fixture-server-id") }
        let passwordDraft = try SFTPServerDraft(name: "Generated password metadata", address: .init("sftp://password.generated.invalid/"), account: "generated")
        let passwordIntent = try await store.apply(.beginPassword(.init(request: passwordDraft.request, key: key)), revision: snapshot.revision)
        snapshot = passwordIntent.snapshot
        guard let credential = passwordIntent.credential else { throw ConnectionQualificationFailure.stage("fixture-credential-id") }
        snapshot = try await store.apply(.confirmPassword(credential.id), revision: snapshot.revision).snapshot
        snapshot = try await store.apply(.saveServer(passwordDraft, id: nil, credentialID: credential.id), revision: snapshot.revision).snapshot
        let jump = try SFTPServerDraft(name: "Generated jump", address: .init("sftp://jump.generated.invalid/"), account: "generated")
        let description = try SFTPRouteDescription(destination: draft, jump: jump)
        let routeResult = try await store.apply(.saveRoute(description, jump: .init(key: key, signIn: .password),
            destination: .init(key: key, signIn: .password), id: nil), revision: snapshot.revision)
        snapshot = routeResult.snapshot; await store.close()
        guard let routeID = routeResult.routeID else { throw ConnectionQualificationFailure.stage("fixture-route-id") }
        let labelOnly = try await state.updatePresentation(id: serverID, expectedRevision: snapshot.revision,
            label: draft.name, directory: .init(legacy: draft.address))
        snapshot = labelOnly.snapshot
        try check(snapshot.format == 4 && snapshot.visibleServers.first(where: { $0.id == serverID })?.defaultDirectory == nil,
            "label-only-edit-unnecessarily-upgraded-store")
        let initial = snapshot, initialBinding = WorkspaceConnectionBinding.sftp(draft)
        for version in 1...4 {
            let object: [String: Any] = ["format": version, "protocolIdentity": "sftp-private-state", "revision": 0,
                "hosts": [], "servers": [], "credentials": [], "forgetAllPending": false]
            var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10)
            let legacy = try SFTPSettingsSnapshot.decode(bytes)
            try check(try legacy.encoded() == bytes, "legacy-v1-v4-shape-roundtrip")
        }
        checks.append("Actual canonical settings decoder preserves every legacy v1–4 empty shape")
        let homeChild = try SFTPDefaultDirectory(field: "~/Saved% #?", root: .home)
        try check(homeChild.pathUTF8 == Data("./Saved% #?".utf8), "home-default-became-absolute")
        let update = try await state.updatePresentation(id: serverID, expectedRevision: snapshot.revision, label: "Generated saved label", directory: homeChild)
        snapshot = update.snapshot
        let routeUpdate = try await state.updatePresentation(id: routeID, route: true, expectedRevision: snapshot.revision,
            label: "Generated route label", directory: homeChild)
        snapshot = routeUpdate.snapshot
        let encoded = try snapshot.encoded(), decoded = try SFTPSettingsSnapshot.decode(encoded)
        try check(snapshot.format == 5 && decoded == snapshot && snapshot.hosts == initial.hosts && snapshot.credentials == initial.credentials,
                  "v5-default-metadata-or-trust-changed")
        try check(snapshot.visibleServers.first(where: { $0.id == serverID })?.keyAuthentication == method
            && snapshot.visibleRoutes.first?.jump == initial.visibleRoutes.first?.jump
            && snapshot.visibleRoutes.first?.destination == initial.visibleRoutes.first?.destination
            && snapshot.visibleServers.first(where: { $0.id == serverID }).map { WorkspaceConnectionBinding.sftp($0.details) } == initialBinding,
            "metadata-edit-changed-auth-binding")
        var wrongVersion = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        wrongVersion["format"] = 4
        var wrongBytes = try JSONSerialization.data(withJSONObject: wrongVersion, options: [.sortedKeys, .withoutEscapingSlashes]); wrongBytes.append(10)
        do { _ = try SFTPSettingsSnapshot.decode(wrongBytes); throw ConnectionQualificationFailure.stage("v4-carried-v5-default") }
        catch SFTPSettingsFailure.incompatibleVersion { }
        do {
            _ = try await state.updatePresentation(id: serverID, expectedRevision: initial.revision, label: "Stale", directory: homeChild)
            throw ConnectionQualificationFailure.stage("metadata-stale-revision-accepted")
        } catch SFTPSettingsFailure.staleRevision { }
        checks.append("Format5 direct/route Home descendants roundtrip; v4 payload, stale edits and identity changes refuse; trust/key/credential/route witnesses remain exact")

        let routedDirectory = try SFTPDefaultDirectory(field: "/RouteDefault", root: .server)
        let routedUpdate = try await state.updatePresentation(id: routeID, route: true, expectedRevision: snapshot.revision,
            label: "Generated route label", directory: routedDirectory, expectedBinding: .init(route: description))
        snapshot = routedUpdate.snapshot
        guard let savedRoute = snapshot.visibleRoutes.first(where: { $0.id == routeID }) else {
            throw ConnectionQualificationFailure.stage("cross-root-route-missing")
        }
        var submittedRoute: SFTPConnectSubmission?
        let routeForm = SMBConnectModel { _, _ in throw ConnectionQualificationFailure.stage("unexpected-smb-connect") }
        routeForm.sftpHandler = { submission, _ in
            submittedRoute = submission
            return .init(server: .notRequested, password: .notRequested, open: {}, discard: { true })
        }
        routeForm.connectionProtocol = .sftp; routeForm.routeFeaturesAvailable = true
        routeForm.replaceSFTPServers([.init(id: routeID, details: savedRoute.details.destination, hasSavedPassword: false,
            route: savedRoute, defaultDirectory: try savedRoute.effectiveDefaultDirectory)])
        routeForm.choose(routeID)
        routeForm.password = "generated-destination"; routeForm.jumpHost.password = "generated-jump"
        routeForm.startingFolderField = "/RouteDefault/Child"
        try check(routeForm.password == "generated-destination" && routeForm.jumpHost.password == "generated-jump",
            "route-folder-edit-cleared-secrets")
        routeForm.connect(); try await wait("saved-route-connect-form") { !routeForm.busy }
        guard let submittedRoute, let submittedDescription = submittedRoute.route else {
            throw ConnectionQualificationFailure.stage("saved-route-form-not-submitted")
        }
        // Draft labels are presentation; the form derives the jump label from
        // its host. Endpoint/account bindings must remain exact.
        try check(submittedRoute.editingRoute == routeID
            && submittedRoute.defaultDirectory?.fieldText == "/RouteDefault/Child", "saved-route-default-not-submitted")
        try check(submittedRoute.draft.address == draft.address && submittedRoute.draft.account == draft.account
            && submittedDescription.jump.address == description.jump.address
            && submittedDescription.jump.account == description.jump.account
            && SFTPConnectionPreferenceBinding(route: submittedDescription) == SFTPConnectionPreferenceBinding(route: description)
            && snapshot.hosts == initial.hosts && snapshot.credentials == initial.credentials, "saved-route-default-rebound-auth")
        await routeForm.cancelAndDrain()
        checks.append("Format7 saved route defaults reconnect through the native form with unchanged destination/jump identities, trust and credential records")

        let target = try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: serverID, binding: initialBinding,
            title: "Generated saved label", relativeToHome: true)
        owner.adoptSavedTarget(target); browser.refreshCurrentConnectionBookmark()
        let profile = ApplicationSMBConnections(directory: root.appendingPathComponent("state/profile"), passwords: smbVault, sftpPasswords: vault)
        context.profiles.append(profile)
        guard let properties = ConnectionPropertiesController(browser: browser, profile: profile, access: .sftp(state)) else {
            throw ConnectionQualificationFailure.stage("properties-window-missing")
        }
        context.properties = properties
        try await wait("properties-metadata-load") { !properties.hasPendingWorkForVerification }
        if ProcessInfo.processInfo.arguments.contains("--capture-connection-properties"), let native = properties.window {
            try check(CGPreflightScreenCaptureAccess(), "properties-capture-access-unavailable")
            let settings = browser.settings, previousSize = browser.settings.interfaceSize
            defer { settings.interfaceSize = previousSize }
            for percent in [100, 150] {
                settings.interfaceSize = .init(percent)
                await Task.yield()
                native.contentView?.layoutSubtreeIfNeeded()
                try await GlassVerification.captureOwnedWindow(native,
                    to: root.appendingPathComponent("evidence/connection-properties-\(percent).png"))
            }
            checks.append("Actual generated Connection Properties captured at100/150percent using the shared tool chrome")
        }
        let tab = browser.activeID, session = owner.connectionID, tabCount = browser.tabs.count
        properties.labelField.stringValue = "Generated property label"; properties.directoryField.stringValue = "/PropertyFolder"
        try check(properties.saveAndGoButtonForVerification.isEnabled, "properties-save-go-disabled")
        properties.saveAndGoButtonForVerification.performClick(nil)
        try await wait("properties-save-go-drain") { !properties.hasPendingWorkForVerification && !owner.hasPendingPages && owner.rows.cache.retainedCount == 3 }
        guard let propertyState = try await state.inspect(), let server = propertyState.visibleServers.first(where: { $0.id == serverID }) else {
            throw ConnectionQualificationFailure.stage("properties-saved-state-missing")
        }
        try check(try server.effectiveDefaultDirectory.fieldText == "/PropertyFolder" && propertyState.format == 7,
            "properties-did-not-save-independent-root")
        try check(browser.activeID == tab && browser.tabs.count == tabCount && owner.connectionID == session
            && browser.sftpTabs[tab] === owner && browser.remoteAddressText == "/PropertyFolder", "properties-reconnected-or-retargeted")
        try check(propertyState.hosts == initial.hosts && propertyState.credentials == initial.credentials
            && server.keyAuthentication == method, "properties-opened-auth-or-mutated-trust")
        checks.append("Actual native Save & Go persists a server-root default independently of the original Home sign-in identity and navigates the same session/tab without authentication")

        properties.directoryField.stringValue = "~/BackHome"
        properties.saveAndGoButtonForVerification.performClick(nil)
        try await wait("properties-go-back-home") { !properties.hasPendingWorkForVerification && !owner.hasPendingPages
            && browser.remoteAddressText == "~/BackHome" }
        try check(browser.activeID == tab && owner.connectionID == session, "home-default-reconnected")
        checks.append("A second Save & Go returns to Home on the same live session without changing sign-in identity")

        browser.pinsController = BrowserPinsController(stateDirectory: root.appendingPathComponent("state/pins"))
        browser.connectPins(); await browser.pinsController.restoreIfNeeded(); await browser.remotePins.restoreIfNeeded()
        context.pins.append(browser.remotePins)
        observePin("restore-return-before-readiness", browser: browser, owner: owner, properties: properties)
        try await wait("native-pin-readiness-not-admitted") { browser.remotePins.isReady && browser.remotePins.canEdit }
        observePin("ready-before-native-pin", browser: browser, owner: owner, properties: properties)
        try check(properties.sourceCurrentForVerification && properties.pinButtonForVerification.isEnabled,
                  "native-pin-source-or-button-unavailable")
        properties.pinButtonForVerification.performClick(nil)
        _ = await browser.remotePins.flush()
        observePin("after-native-pin-flush", browser: browser, owner: owner, properties: properties)
        try check(browser.remotePins.collection.pins.count == 1, "native-pin-not-created")
        let pin = browser.remotePins.collection.pins[0]
        let restored = RemoteConnectionPinsController(directory: root.appendingPathComponent("state/pins")); context.pins.append(restored)
        await restored.restoreIfNeeded()
        try check(restored.canEdit && restored.collection == browser.remotePins.collection, "typed-pin-persistence-roundtrip")
        browser.enterRemoteAddress("~/Elsewhere")
        try await wait("pin-source-navigation") { !owner.hasPendingPages && browser.remoteAddressText == "~/Elsewhere" }
        browser.openRemotePin(pin.id)
        try await wait("live-pin-navigation") { !owner.hasPendingPages && browser.remoteAddressText == "~/BackHome" }
        try check(browser.activeID == tab && browser.tabs.count == tabCount && owner.connectionID == session
            && browser.orderedSelectedURLs.isEmpty, "pin-created-session-or-local-authority")
        await properties.closeAndDrain(); context.properties = nil
        checks.append("Native Pin saves a separate typed shortcut; a fresh guarded reader restores it and activation reuses the live session")

        let uiGate = Gate()
        let uiStore = SFTPSettingsStore(directory: root.appendingPathComponent("state/sftp-metadata"), probe: { stage in if stage == .beforeRename { try uiGate.hold() } })
        let uiState = SFTPRememberedState(settings: uiStore, passwords: vault); context.states.append(uiState)
        guard let closingProperties = ConnectionPropertiesController(browser: browser, profile: profile, access: .sftp(uiState)) else {
            throw ConnectionQualificationFailure.stage("closing-properties-missing")
        }
        context.properties = closingProperties
        try await wait("closing-properties-load") { !closingProperties.hasPendingWorkForVerification }
        closingProperties.labelField.stringValue = "Generated closed-window label"
        closingProperties.directoryField.stringValue = "~/MustNotNavigateAfterClose"
        closingProperties.saveAndGoButtonForVerification.performClick(nil)
        do {
            try await wait("properties-held-writer") { uiGate.entered }
            closingProperties.close()
            try check(profile.pendingMetadataCountForVerification == 1 && closingProperties.hasPendingWorkForVerification
                && closingProperties.window == nil, "closed-properties-fake-drained")
            browser.enterRemoteAddress("~/WhileClosing")
            try await wait("browse-during-metadata-close") { browser.remoteAddressText == "~/WhileClosing" && !owner.hasPendingPages }
            uiGate.release(); await closingProperties.closeAndDrain()
            try check(profile.pendingMetadataCountForVerification == 0 && browser.remoteAddressText == "~/WhileClosing"
                && browser.activeID == tab && owner.connectionID == session, "closed-properties-late-go-or-retained-task")
        } catch { uiGate.release(); await closingProperties.closeAndDrain(); throw error }
        context.properties = nil
        checks.append("Closing actual Properties releases its window but retains the held write; browsing stays usable and late Save & Go cannot retarget the source")

        let corruptRoot = root.appendingPathComponent("state/corrupt-pins")
        let conflictRoot = root.appendingPathComponent("state/conflicting-pins")
        try await Task.detached {
            try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data([123]).write(to: corruptRoot.appendingPathComponent("remote-connection-pins-v1.json"), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptRoot.appendingPathComponent("remote-connection-pins-v1.json").path)
        }.value
        let corrupt = RemoteConnectionPinsController(directory: corruptRoot); context.pins.append(corrupt)
        await corrupt.restoreIfNeeded(); corrupt.edit { _ = try $0.add(target: target, label: "Refused") }
        try check(!corrupt.canEdit, "corrupt-pins-became-writable")
        let conflict = RemoteConnectionPinsController(directory: conflictRoot); context.pins.append(conflict)
        await conflict.restoreIfNeeded()
        let external = try RemoteConnectionPinCollection().encoded()
        try await Task.detached {
            var file = BrowserSnapshotFile(directory: conflictRoot, name: "remote-connection-pins-v1.json", maximumBytes: RemoteConnectionPinCollection.maximumEncodedBytes)
            file.requiresPrivateDurability = true; try file.write(external) { _ = try RemoteConnectionPinCollection.decode($0) }
        }.value
        conflict.edit { _ = try $0.add(target: target, label: "Observed conflict") }; _ = await conflict.flush()
        let savedExternal = try await Task.detached { try Data(contentsOf: conflictRoot.appendingPathComponent("remote-connection-pins-v1.json")) }.value
        try check(!conflict.canEdit && savedExternal == external, "pin-conflict-overwrote-or-faked-success")
        checks.append("Corrupt pins remain read-only; a competing valid pin arrival refuses and retains its exact committed bytes")

        let smbDraft = try SMBServerDraft(name: "Generated SMB", address: .init("smb://smb.generated.invalid/Studio/"),
            account: "generated", domain: "STUDIO", security: .encrypted)
        let smbStore = SMBSavedServerStore(directory: root.appendingPathComponent("state/smb-metadata"))
        var smbSnapshot = try await smbStore.openForExplicitWrite().snapshot
        let smbIntent = try await smbStore.apply(.beginPassword(smbDraft.credentialBinding()), expectedRevision: smbSnapshot.revision)
        smbSnapshot = smbIntent.snapshot
        guard let smbClaim = smbIntent.credentialReference else { throw ConnectionQualificationFailure.stage("smb-fixture-credential-id") }
        smbSnapshot = try await smbStore.apply(.confirmPassword(smbClaim.id), expectedRevision: smbSnapshot.revision).snapshot
        let smbSaved = try await smbStore.apply(.saveServer(smbDraft, id: nil, credentialID: smbClaim.id), expectedRevision: smbSnapshot.revision)
        await smbStore.close()
        guard let smbID = smbSaved.serverID else { throw ConnectionQualificationFailure.stage("smb-fixture-server-id") }
        let smbCoordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL,
            storage: try .init(directory: root.appendingPathComponent("state/smb-runtime")), servers: smbStore,
            passwords: smbVault, activity: FileActivityGate(maximumActivities: 2),
            prepare: { _, _, _ in calls.hit(); throw SMBBrowserFailure.unavailable },
            open: { _, _, _, _, _, _ in calls.hit(); throw SMBBrowserFailure.unavailable })
        context.smb.append(smbCoordinator)
        let smbEdited = try await smbCoordinator.updatePresentation(id: smbID, expectedRevision: smbSaved.snapshot.revision,
            label: "Generated SMB label", components: [.init("Saved"), .init("Literal%?#")])
        guard let smbRecord = smbEdited.snapshot.visibleServers.first else { throw ConnectionQualificationFailure.stage("smb-updated-record") }
        try check(smbRecord.credentialID == smbClaim.id && smbEdited.snapshot.credentials == smbSaved.snapshot.credentials
            && smbRecord.details.account == smbDraft.account && smbRecord.details.domain == smbDraft.domain
            && smbRecord.details.security == smbDraft.security
            && WorkspaceConnectionBinding.smb(smbRecord.details) == WorkspaceConnectionBinding.smb(smbDraft)
            && smbRecord.details.address.components.map(\.displayName) == ["Saved", "Literal%?#"], "smb-metadata-edit-changed-authority")
        do {
            _ = try await smbCoordinator.updatePresentation(id: smbID, expectedRevision: smbSaved.snapshot.revision,
                label: "Stale", components: [])
            throw ConnectionQualificationFailure.stage("smb-stale-metadata-edit")
        } catch SMBServerStoreFailure.staleRevision { }
        checks.append("Actual SMB metadata coordinator preserves ready credentials, account/domain/policy and binding, refuses stale revision and performs no preparation/vault call; no live SMB owner is claimed")

        let methodStore = SFTPSettingsStore(directory: root.appendingPathComponent("state/sign-in-metadata"))
        let methodState = SFTPRememberedState(settings: methodStore, passwords: vault); context.states.append(methodState)
        var methodRevision: UInt64 = 0
        for signIn in [SFTPRouteSignIn.password, .keyFile, .serverPrompts, .keyFileAndServerPrompts] {
            let value = try await methodState.saveMetadata(draft, expectedRevision: methodRevision,
                directory: .init(legacy: draft.address), signIn: signIn)
            methodRevision = value.snapshot.revision
            guard let id = value.serverID, let saved = value.snapshot.visibleServers.first(where: { $0.id == id }) else {
                throw ConnectionQualificationFailure.stage("sign-in-preference-record-missing")
            }
            try check(saved.credentialID == nil && saved.keyAuthentication?.reference == nil
                && (saved.keyAuthentication != nil) == signIn.usesKey
                && saved.usesServerPrompts == (signIn == .serverPrompts)
                && (saved.keyAuthentication?.requiresServerPrompts ?? false) == (signIn == .keyFileAndServerPrompts)
                && value.snapshot.hosts.isEmpty && value.snapshot.credentials.isEmpty,
                "metadata-sign-in-preference-gained-access")
        }
        checks.append("Unsaved direct metadata retains the four sign-in preferences without passwords, key grants or remembered host trust")

        for afterRename in [false, true] {
            let directory = root.appendingPathComponent(afterRename ? "state/uncertain-metadata" : "state/interrupted-metadata")
            let normal = SFTPSettingsStore(directory: directory)
            let seed = SFTPRememberedState(settings: normal, passwords: vault); context.states.append(seed)
            let intent = try await seed.saveMetadata(draft, expectedRevision: 0, directory: .init(legacy: draft.address))
            guard let id = intent.serverID else { throw ConnectionQualificationFailure.stage("failure-fixture-id") }
            await seed.drain()
            let failingStore = SFTPSettingsStore(directory: directory, probe: { stage in
                if stage == (afterRename ? .renamed : .beforeRename) { throw SFTPSettingsFailure.unavailable }
            })
            let failing = SFTPRememberedState(settings: failingStore, passwords: vault); context.states.append(failing)
            do {
                _ = try await failing.updatePresentation(id: id, expectedRevision: intent.snapshot.revision, label: "Attempt", directory: homeChild)
                throw ConnectionQualificationFailure.stage("injected-save-reported-success")
            } catch let issue as SFTPSettingsFailure {
                try check(issue == (afterRename ? .durabilityUncertain : .unavailable), "wrong-save-failure-class")
            }
            if !afterRename {
                do { _ = try await failing.inspect(); throw ConnectionQualificationFailure.stage("interrupted-save-auto-recovered") }
                catch SFTPSettingsFailure.recoveryRequired { }
            }
        }
        checks.append("Real settings staging/published failures retain interruption or uncertainty and never produce a Saved result")

        let gateRoot = root.appendingPathComponent("state/cancelled-metadata")
        let gate = Gate(), gateStore = SFTPSettingsStore(directory: gateRoot, probe: { stage in if stage == .beforeRename { try gate.hold() } })
        let gateState = SFTPRememberedState(settings: gateStore, passwords: vault); context.states.append(gateState)
        let pending = Task { try await gateState.saveMetadata(draft, expectedRevision: 0, directory: homeChild) }
        let completion: SFTPSettingsMutation
        do {
            try await wait("metadata-held-writer") { gate.entered }; pending.cancel()
            do { _ = try await gateState.inspect(); throw ConnectionQualificationFailure.stage("cancelled-writer-fake-drained") }
            catch SFTPSettingsFailure.busy { }
            gate.release(); completion = try await pending.value
        } catch { gate.release(); _ = try? await pending.value; throw error }
        try check(completion.completedAfterCancellation && completion.serverID != nil, "late-metadata-commit-lost")
        await gateState.drain()
        checks.append("Cancellation retains the held writer until actual release; a completed late commit is reported honestly")

        checks += try await savedServerVisibility(root: root, browser: browser, state: state, calls: calls, smbVault: smbVault, vault: vault, context: context)
        let forgotten = await state.forget(.server(serverID, removePassword: false))
        try check(forgotten.server == .complete, "generated-forget-incomplete")
        let final = try await state.inspect()
        do {
            _ = try await state.updatePresentation(id: serverID, expectedRevision: final?.revision ?? 0, label: "Refused", directory: homeChild)
            throw ConnectionQualificationFailure.stage("forgotten-target-retargeted")
        } catch SFTPSettingsFailure.missing { }
        let form = SMBConnectModel { _, _ in calls.hit(); throw SMBBrowserFailure.unavailable }
        form.replaceSFTPServers([]); form.selectWorkspaceLocation(pin.target)
        try check(form.workspaceBlocked, "forgotten-pin-reconnect-not-refused")
        try check(calls.count == 0, "metadata-called-password-vault")
        checks.append("Forgotten saved targets cannot be edited/reconnected through a stale pin; refusing vault observed zero calls")
        return checks
    }

    private static func savedServerVisibility(root: URL, browser: BrowserViewController, state: SFTPRememberedState,
                                             calls: Calls, smbVault: SMBPasswordVault, vault: SFTPPasswordVault,
                                             context: Context) async throws -> [String] {
        guard let original = try await state.inspect() else { throw ConnectionQualificationFailure.stage("saved-location-seed-missing") }
        let directory = root.appendingPathComponent("state/saved-server-locations")
        let sftpDirectory = directory.appendingPathComponent("sftp-servers")
        let bytes = try original.encoded()
        try await Task.detached {
            try FileManager.default.createDirectory(at: sftpDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: sftpDirectory.appendingPathComponent("servers.json"), options: .withoutOverwriting)
            try Data().write(to: sftpDirectory.appendingPathComponent("owner.lock"), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sftpDirectory.appendingPathComponent("servers.json").path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sftpDirectory.appendingPathComponent("owner.lock").path)
            // A real unknown workspace shape must block admission, not the form.
            try Data("generated unavailable workspace\n".utf8).write(to: directory.appendingPathComponent("connection-workspace-location"), options: .withoutOverwriting)
        }.value
        let smbStore = SMBSavedServerStore(directory: directory.appendingPathComponent("smb-servers"))
        let initial = try await smbStore.openForExplicitWrite().snapshot
        let draft = try SMBServerDraft(name: "Generated SMB saved server", address: .init("smb://generated.invalid/Share"), account: "generated", domain: "", security: .encrypted)
        _ = try await smbStore.apply(.saveServer(draft, id: nil, credentialID: nil), expectedRevision: initial.revision)
        await smbStore.close()
        let reader = SavedServerLocations(directory: directory)
        reader.refresh(); await reader.work?.value
        try check(reader.snapshot.locations.count == 4 && reader.snapshot.unavailableProtocols.isEmpty,
            "cold-saved-server-metadata-not-visible")
        let earlier = browser.savedServerLocations
        browser.savedServerLocations = reader
        defer { browser.savedServerLocations = earlier; browser.refreshConnectedLocations(force: true) }
        browser.presentConnectedLocations([], force: true)
        try check(browser.disconnectedServerSnapshot.count == 4 && browser.volumeBrowser.connectedServers.saved.count == 4
            && browser.sidebarRoots.first(where: { $0.title == "Servers" })?.children?.count == 4,
            "disconnected-saved-server-rows-disappeared")
        guard let savedNode = browser.sidebarRoots.first(where: { $0.title == "Servers" })?.children?.first(where: { $0.serverBookmark != nil }) else {
            throw ConnectionQualificationFailure.stage("saved-server-sidebar-node-missing")
        }
        try check(browser.outlineView(browser.outline, shouldSelectItem: savedNode),
            "offline-saved-server-sidebar-refuses-selection")
        try await savedServerOverview(root: root, browser: browser, locations: reader)
        if let bookmark = savedNode.serverBookmark {
            try check(reader.beginConnecting(bookmark) && !reader.beginConnecting(bookmark), "saved-server-duplicate-connect-not-coalesced")
            reader.updateConnecting(bookmark, phase: "Authenticating…")
            browser.presentConnectedLocations([], force: true)
            try check(browser.volumeBrowser.connectedServers.saved.count == 4 && reader.connectionProgress[bookmark] == "Authenticating…",
                "saved-server-progress-lost-rows")
            reader.finishConnecting(bookmark)
            try check(reader.connectionProgress.isEmpty, "saved-server-progress-survived-completion")
        }
        let cold = SavedServerLocations(directory: directory); cold.refresh(); await cold.work?.value
        try check(cold.snapshot == reader.snapshot, "saved-server-list-was-session-only")
        if let bookmark = reader.snapshot.locations.first(where: { !$0.isSFTP }) {
            try closedUploadCards(browser: browser, bookmark: bookmark)
        }

        let smbFile = directory.appendingPathComponent("smb-servers/servers.json")
        let smbBytes = try await Task.detached { try Data(contentsOf: smbFile) }.value
        try await Task.detached { try Data("unfamiliar generated settings\n".utf8).write(to: smbFile) }.value
        reader.refresh(); await reader.work?.value
        try check(reader.snapshot.unavailableProtocols == ["SMB"] && reader.snapshot.locations.count == 3,
            "unavailable-smb-hid-saved-sftp")
        try await Task.detached { try smbBytes.write(to: smbFile) }.value
        reader.refresh(); await reader.work?.value

        let profile = ApplicationSMBConnections(directory: directory, passwords: smbVault, sftpPasswords: vault)
        context.profiles.append(profile)
        profile.presentActivity(in: browser, isSFTP: true); await profile.gateAWaitForSetup()
        try check(profile.verificationWindow == nil && profile.verificationSFTPStorage == nil
            && !profile.gateAHasCoordinator && calls.count == 0,
            "activity-review-activated-unverified-workspace")
        guard let selected = reader.snapshot.locations.first(where: \.isSFTP) else { throw ConnectionQualificationFailure.stage("saved-sftp-choice-missing") }
        var directPhases: [String] = [], directFinished: [Bool] = []
        profile.connectSaved(in: browser, savedServer: selected, phase: { directPhases.append($0) },
            finished: { directFinished.append($0) })
        await profile.gateAWaitForSetup()
        try check(directFinished == [false] && !directPhases.isEmpty && calls.count == 0,
            "saved-direct-workspace-fallback-missed-completion")
        try check(profile.verificationWindow?.window?.isVisible == true, "unavailable-workspace-hid-connect-window")
        guard let window = profile.verificationWindow else { throw ConnectionQualificationFailure.stage("connect-window-not-retained") }
        try check(window.model.storageNeedsReview && !window.model.managing && window.model.sftpServers.count == 3
            && window.model.selectedServer == selected.serverID && window.window?.isVisible == true,
            "blocked-connect-lost-saved-settings-or-review")
        window.model.connect()
        try check(!window.model.busy && calls.count == 0, "review-needed-connect-started-authentication")
        if let native = window.window, CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(native, to: root.appendingPathComponent("evidence/saved-server-workspace-review.png"))
        }
        window.close(); await profile.closeAndDrain()
        try check(directFinished == [false], "saved-direct-completion-repeated-after-close")
        try await legacyConnectionRestoration(root: root, browser: browser, vault: vault, smbVault: smbVault, context: context)
        try await forgetOfflineServers(directory: directory, browser: browser, locations: reader,
            calls: calls, smbVault: smbVault, vault: vault, context: context)
        return ["Cold read-only metadata restores all saved SMB/SFTP/route rows into This Mac and sidebar after the live list empties, without authentication",
                "An unfamiliar SMB record leaves saved SFTP rows visible; unavailable workspace still presents Connect with prefilled settings and review, refusing authentication",
                "Actual legacy-device review Cancel preserves the record, Restore Access revalidates and admits the same Connect window without authentication",
                "Go Connection Activity opens existing SFTP outcomes without Connect or authentication; an unverified workspace is not activated by review",
                "Native Forget Cancel preserves settings; confirmed SMB/SFTP/route Forget works with an unavailable listing workspace, preserves other servers and reads no password"]
    }

    private static func forgetOfflineServers(directory: URL, browser: BrowserViewController, locations: SavedServerLocations,
        calls: Calls, smbVault: SMBPasswordVault, vault: SFTPPasswordVault, context: Context) async throws {
        guard let parent = browser.view.window else { throw ConnectionQualificationFailure.stage("forget-parent-missing") }
        let profile = ApplicationSMBConnections(directory: directory, passwords: smbVault, sftpPasswords: vault)
        context.profiles.append(profile)
        @MainActor func confirm(_ bookmark: WorkspaceConnectionBookmark, button title: String) async throws {
            profile.confirmForgetSavedServer(bookmark, in: browser)
            try await wait("forget-confirmation-missing") { parent.attachedSheet != nil }
            guard let sheet = parent.attachedSheet, let content = sheet.contentView else {
                throw ConnectionQualificationFailure.stage("forget-sheet-missing")
            }
            let buttons = WorkspaceNetworkVerification.descendants(content).compactMap { $0 as? NSButton }
            try check(buttons.first(where: { $0.title == "Also remove its saved password from Keychain" })?.state == .off,
                "forget-password-removal-defaulted-on")
            guard let button = buttons.first(where: { $0.title == title }) else {
                throw ConnectionQualificationFailure.stage("forget-confirmation-action-missing")
            }
            button.performClick(nil)
            try await wait("forget-confirmation-not-closed") { parent.attachedSheet == nil }
            await profile.gateAWaitForSetup()
        }
        let initial = locations.snapshot
        guard let first = initial.locations.first else { throw ConnectionQualificationFailure.stage("forget-target-missing") }
        try await confirm(first, button: "Cancel")
        locations.refresh(); await locations.work?.value
        try check(locations.snapshot == initial && !profile.gateAHasCoordinator && calls.count == 0,
            "forget-cancel-changed-state")
        for kind in [WorkspaceConnectionBookmark.Kind.smbServer, .sftpServer, .sftpRoute] {
            guard let selected = locations.snapshot.locations.first(where: { $0.kind == kind }) else {
                throw ConnectionQualificationFailure.stage("forget-protocol-target-missing")
            }
            let before = locations.snapshot.locations
            try await confirm(selected, button: "Forget Server")
            locations.refresh(); await locations.work?.value
            try check(Set(locations.snapshot.locations) == Set(before.filter { $0 != selected })
                && browser.status.stringValue == "Saved server forgotten. Open connections remain available."
                && !profile.gateAHasCoordinator && calls.count == 0, "offline-forget-missed-exact-server")
        }
        let untouched = try await Task.detached {
            try Data(contentsOf: directory.appendingPathComponent("connection-workspace-location"))
        }.value
        try check(untouched == Data("generated unavailable workspace\n".utf8), "forget-activated-listing-workspace")
        await profile.closeAndDrain()
    }

    private static func closedUploadCards(browser: BrowserViewController, bookmark: WorkspaceConnectionBookmark) throws {
        let tab = browser.activeID, prior = browser.smbClosedUploadNotices[tab]
        let host = NSView(frame: browser.view.bounds); host.autoresizingMask = [.width, .height]
        browser.view.addSubview(host)
        defer { host.removeFromSuperview(); browser.smbClosedUploadNotices[tab] = prior }
        var historyCalls = 0
        let notice = RemoteClosedTransferNotice(message: "Two items uploaded. One unfinished folder needs review.", showHistory: { settings, window in
            if settings === browser.settings && window === browser.view.window { historyCalls += 1 }
        })
        browser.smbClosedUploadNotices[tab] = notice
        browser.showSavedNetworkLocation(bookmark, in: host, uploadNotice: notice)
        func historyButton() throws -> NSButton {
            guard let button = WorkspaceNetworkVerification.descendants(host).compactMap({ $0 as? NSButton })
                .first(where: { $0.identifier?.rawValue == "smb-closed-upload-history" }) else {
                throw ConnectionQualificationFailure.stage("smb-closed-history-button-missing")
            }
            return button
        }
        try historyButton().performClick(nil)
        try check(historyCalls == 1, "saved-smb-card-used-other-protocol-history")
        host.subviews.forEach { $0.removeFromSuperview() }
        browser.showClosedNetworkLocation(in: host, message: notice.message, notice: notice,
            historyAction: #selector(BrowserViewController.showSMBUploadOutcomes(_:)),
            historyTitle: "Upload Outcomes…", historyIdentifier: "smb-closed-upload-history")
        try historyButton().performClick(nil)
        try check(historyCalls == 2, "closed-smb-card-lost-history-owner")
    }

    private static func savedServerOverview(root: URL, browser: BrowserViewController,
                                            locations: SavedServerLocations) async throws {
        guard let window = browser.view.window else { throw ConnectionQualificationFailure.stage("server-overview-window-missing") }
        let frame = window.frame
        let material = (browser.settings.navigationStyle, browser.settings.glassFileContent, browser.settings.appearance)
        let visibility = (browser.volumeBrowser.isHidden, browser.folderScroll.isHidden, browser.iconBrowser.isHidden,
                          browser.smbHost.isHidden, browser.sftpHost.isHidden)
        let open = browser.volumeBrowser.connectedServers.onOpenSaved
        defer {
            browser.settings.navigationStyle = material.0; browser.settings.glassFileContent = material.1
            browser.settings.appearance = material.2; browser.updateMaterialSurfaces()
            browser.volumeBrowser.connectedServers.onOpenSaved = open
            browser.volumeBrowser.update(volumes: browser.volumes)
            browser.volumeBrowser.isHidden = visibility.0; browser.folderScroll.isHidden = visibility.1
            browser.iconBrowser.isHidden = visibility.2; browser.smbHost.isHidden = visibility.3
            browser.sftpHost.isHidden = visibility.4; window.setFrame(frame, display: true)
        }
        browser.canvasTransition?.finish()
        browser.settings.navigationStyle = .glass; browser.settings.glassFileContent = true
        browser.settings.appearance = .dark; browser.updateMaterialSurfaces()
        browser.volumeBrowser.isHidden = false; browser.folderScroll.isHidden = true
        browser.iconBrowser.isHidden = true; browser.smbHost.isHidden = true; browser.sftpHost.isHidden = true
        browser.volumeBrowser.update(volumes: [
            .init(url: root.appendingPathComponent("source/Generated SSD"), name: "Internal SSD", kind: .internalDisk,
                  totalBytes: 512 << 30, availableBytes: 256 << 30),
            .init(url: root.appendingPathComponent("source/Generated USB"), name: "Travel Drive", kind: .externalDisk,
                  totalBytes: 128 << 30, availableBytes: 64 << 30),
            .init(url: root.appendingPathComponent("source/Generated Work"), name: "Projects", kind: .externalDisk,
                  totalBytes: 2 << 40, availableBytes: 1 << 40)
        ])
        var activated: WorkspaceConnectionBookmark?
        browser.volumeBrowser.connectedServers.onOpenSaved = { activated = $0 }
        window.setContentSize(NSSize(width: 1100, height: 720))
        browser.view.layoutSubtreeIfNeeded(); browser.volumeBrowser.layoutSubtreeIfNeeded()
        browser.volumeBrowser.connectedServers.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        try check(browser.volumeBrowser.connectedServers.visibleTiles.count == 4, "server-overview-grid-not-visible")
        guard let tile = browser.volumeBrowser.connectedServers.visibleTiles.first else {
            throw ConnectionQualificationFailure.stage("server-overview-tile-missing")
        }
        let opened = tile.performAccessibleOpen(NSAccessibilityCustomAction(name: "Open", handler: { true }))
        try check(opened && activated.map { locations.snapshot.locations.contains($0) } == true,
            "server-tile-open-missed-saved-target")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/saved-server-overview.png"))
        }
        window.setContentSize(NSSize(width: 680, height: 620))
        browser.view.layoutSubtreeIfNeeded(); browser.volumeBrowser.layoutSubtreeIfNeeded()
        browser.volumeBrowser.connectedServers.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        try check(browser.volumeBrowser.visibleTiles.count == 3
            && browser.volumeBrowser.visibleTiles.allSatisfy { $0.view.bounds.width > 200 },
            "narrow-server-overview-collapsed-drive-tiles")
        try check(browser.volumeBrowser.scrollView.documentView !== browser.volumeBrowser.collectionView,
            "server-overview-does-not-share-scroll-document")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/saved-server-overview-narrow.png"))
        }
    }

    private static func legacyConnectionRestoration(root: URL, browser: BrowserViewController, vault: SFTPPasswordVault,
                                                    smbVault: SMBPasswordVault, context: Context) async throws {
        let directory = root.appendingPathComponent("state/generated-reboot-profile")
        let layout = try ApplicationStorageLayout(developmentState: directory,
            legacyAnalysis: directory.appendingPathComponent("unused-analysis-layout", isDirectory: true))
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        let original = try await Task.detached { () -> Data in
            guard let file = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory, writing: true, existingOnly: true),
                  let device = file.snapshot.earlier?.device else { throw ConnectionQualificationFailure.stage("reboot-generated-record-missing") }
            defer { file.close() }
            var old = file.snapshot; old.format = 1; old.protocolIdentity = "traverse-persistent-connections-v1"
            old.earlier = old.earlier?.rebased(device: device &+ 1, volume: nil)
            old.earlierLock = old.earlierLock?.rebased(device: device &+ 1, volume: nil)
            old.graph = old.graph.mapValues { $0.rebased(device: device &+ 1, volume: nil) }
            try file.commit(old); return try old.encoded()
        }.value
        let previous = browser.savedServerLocations
        browser.savedServerLocations = SavedServerLocations(directory: directory)
        defer { browser.savedServerLocations = previous; browser.refreshConnectedLocations(force: true) }
        let profile = ApplicationSMBConnections(directory: directory, passwords: smbVault, sftpPasswords: vault)
        context.profiles.append(profile)
        profile.present(in: browser); await profile.gateAWaitForSetup()
        guard let controller = profile.verificationWindow, let native = controller.window else { throw ConnectionQualificationFailure.stage("reboot-connect-not-visible") }
        try check(controller.model.storageNeedsReview, "legacy-device-drift-admitted-without-review")
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let value = view as? NSButton, value.title == title { return value }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        controller.model.onStorage?()
        try await wait("reboot-review-sheet-missing") { native.attachedSheet != nil }
        guard let cancel = button("Cancel", in: native.attachedSheet?.contentView) else { throw ConnectionQualificationFailure.stage("reboot-cancel-missing") }
        cancel.performClick(nil)
        try await wait("reboot-cancel-not-drained") { native.attachedSheet == nil }
        let afterCancel = try await Task.detached { try Data(contentsOf: layout.connectionWorkspaceRecordDirectory.appendingPathComponent("servers.json")) }.value
        try check(afterCancel == original && controller.model.storageNeedsReview, "reboot-cancel-rewrote-record")
        controller.model.onStorage?()
        try await wait("reboot-second-sheet-missing") { native.attachedSheet != nil }
        guard let restore = button("Restore Access", in: native.attachedSheet?.contentView) else { throw ConnectionQualificationFailure.stage("reboot-restore-missing") }
        restore.performClick(nil)
        try await wait("reboot-restore-not-ready") { native.attachedSheet == nil && !controller.model.managing
            && !controller.model.storageNeedsReview && profile.gateAHasCoordinator }
        let restoredState = try await workspace.inspect().state
        try check(controller.window === native && native.isVisible && restoredState == .active,
            "reboot-restore-replaced-window-or-left-refused")
        controller.close(); await profile.closeAndDrain()
        let record = layout.connectionWorkspaceRecordDirectory.appendingPathComponent("servers.json")
        let beforeReview = try await Task.detached { try Data(contentsOf: record) }.value
        let reviewer = ApplicationSMBConnections(directory: directory, passwords: smbVault, sftpPasswords: vault)
        context.profiles.append(reviewer)
        let earlierService = browser.connectionService
        browser.connectionService = reviewer
        defer { browser.connectionService = earlierService }
        let activity = BrowserMenus.menu(.go, target: browser).items.first { $0.title == "Connection Activity" }
        try check(activity?.submenu?.items.contains { $0.action == #selector(BrowserViewController.showSFTPConnectionActivity(_:)) } == true,
            "activity-go-menu-missing")
        browser.showSFTPConnectionActivity(nil); await reviewer.gateAWaitForSetup()
        try await wait("activity-offline-load") { reviewer.verificationSFTPStorage?.model.busy == false }
        try check(reviewer.verificationWindow == nil && reviewer.verificationSFTPStorage?.window?.isVisible == true,
            "activity-opened-connect-or-no-window")
        let afterReview = try await Task.detached { try Data(contentsOf: record) }.value
        try check(beforeReview == afterReview, "activity-review-mutated-workspace-record")
        await reviewer.closeAndDrain(); await workspace.stopAndDrain()
    }
}
#endif
