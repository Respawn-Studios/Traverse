import AppKit
import Combine
import SwiftUI
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// One native form for new connections and saved-server navigation. It owns no
/// socket, Keychain calls, preferences writes or local/remote file operations.
struct SMBConnectServerChoice: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let address: SMBConnectionAddress
    let account: String
    let domain: String
    let security: SMBWorkerSecurityPolicy
    var hasSavedPassword = false
    var transferPreference: SFTPTransferPreference = .readOnly
}
struct SMBConnectSubmission: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "<SMB connection submission>" }
    var debugDescription: String { description }
    let address: SMBConnectionAddress
    let account: String
    let domain: String
    let password: SMBPassword?
    let name: String
    let security: SMBWorkerSecurityPolicy
    let rememberServer: Bool
    let rememberPassword: Bool
    let editingServer: UUID?
    var transferPreference: SFTPTransferPreference = .readOnly
}
enum ExplorerConnectionProtocol: String, CaseIterable, Identifiable { case smb = "SMB", sftp = "SFTP"; var id: Self { self } }
enum SFTPTransferBehavior: String, CaseIterable, Identifiable {
    case normal = "Browse & transfer", cautious = "Ask before uploads", readOnly = "Read only"
    var id: Self { self }
    var preference: SFTPTransferPreference {
        switch self { case .normal: .normal; case .cautious: .cautious; case .readOnly: .readOnly }
    }
    init(preference: SFTPTransferPreference) {
        switch preference { case .normal: self = .normal; case .cautious: self = .cautious; case .readOnly: self = .readOnly }
    }
}
struct SFTPConnectServerChoice: Identifiable, Sendable, Equatable {
    let id: UUID
    let details: SFTPServerDraft
    let hasSavedPassword: Bool
    var keyAuthentication: SFTPServerKeyAuthentication? = nil
    var usesServerPrompts = false
    var route: SFTPSavedRoute? = nil
    var jumpHasSavedPassword = false
    var defaultDirectory: SFTPDefaultDirectory? = nil
    var transferPreference: SFTPTransferPreference? = nil
}
struct SFTPConnectSubmission: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "<SFTP connection submission>" }
    var debugDescription: String { description }
    let draft: SFTPServerDraft
    let password: SFTPPassword?
    let rememberServer: Bool, rememberPassword: Bool
    let editingServer: UUID?
    var freshUploads = false
    var freshFolderUploads = false
    var reviewsUploads = true
    // Legacy programmatic submissions remain conservative; the visible form
    // always supplies its explicit choice independently of capability gating.
    var transferPreference: SFTPTransferPreference = .readOnly
    var authentication: SFTPAuthenticationChoice? = nil
    var configuration: SSHConfigurationImport? = nil
    var profileAlias: String? = nil
    var route: SFTPRouteDescription? = nil
    var defaultDirectory: SFTPDefaultDirectory? = nil
    var jumpAuthentication: SFTPAuthenticationChoice? = nil
    var rememberJumpPassword = false
    var editingRoute: UUID? = nil
}
private struct ConnectDisplayServer: Identifiable {
    let id: UUID; let name: String, host: String; let hasSavedPassword: Bool
}
struct SMBConnectSavedOutcome: Sendable {
    enum Status: Sendable, Equatable { case notRequested, saved, incomplete }
    let server: Status
    let password: Status
    var host: Status = .notRequested
    var keyAccess: Status = .notRequested
    /// Ownership crosses into a browser tab only after the form accepts success.
    let open: @MainActor @Sendable () -> Void
    let discard: @Sendable () async -> Bool
    var canOpen: @MainActor @Sendable () -> Bool = { true }
}
@MainActor final class SMBConnectModel: ObservableObject {
    typealias Handler = @MainActor (SMBConnectSubmission, @escaping @MainActor (String) -> Void) async throws -> SMBConnectSavedOutcome
    typealias SFTPHandler = @MainActor (SFTPConnectSubmission, @escaping @MainActor (String) -> Void) async throws -> SMBConnectSavedOutcome
    var sftpHandler: SFTPHandler?
    @Published var connectionProtocol = ExplorerConnectionProtocol.smb { didSet { if connectionProtocol != oldValue { choose(nil) } } }
    @Published var address = "" { didSet { addressChanged(from: oldValue) } }
    @Published var serverField = "" {
        didSet { if !serverField.utf8.elementsEqual(oldValue.utf8) { fieldsChanged() } }
    }
    @Published var portField = "445" {
        didSet {
            if !portField.utf8.elementsEqual(oldValue.utf8) {
                if !updatingAddressFields { portWasEdited = true }
                fieldsChanged()
            }
        }
    }
    @Published var shareField = "" {
        didSet { if !shareField.utf8.elementsEqual(oldValue.utf8) { fieldsChanged() } }
    }
    @Published var startingFolderField = "" {
        didSet {
            if !startingFolderField.utf8.elementsEqual(oldValue.utf8) {
                fieldsChanged(invalidatesIdentity: false)
            }
        }
    }
    @Published var account = "" { didSet { if !account.utf8.elementsEqual(oldValue.utf8) { identityChanged() } } }
    @Published var domain = "" { didSet { if !domain.utf8.elementsEqual(oldValue.utf8) { identityChanged() } } }
    @Published var password = ""
    @Published private(set) var changingSavedPassword = false
    @Published var name = ""
    @Published var security: SMBWorkerSecurityPolicy = .encrypted {
        didSet {
            if connectionProtocol == .smb, security != .encrypted { transferBehavior = .readOnly }
        }
    }
    @Published var rememberServer = false { didSet { if !rememberServer { rememberKeyAccess = false; jumpHost.rememberKey = false; jumpHost.rememberPassword = false } } }
    @Published var rememberPassword = false
    @Published var showServers = false
    @Published var editorWidth: CGFloat = 600
    @Published var showAdvanced = false
    @Published var freshUploads = true
    @Published var freshFolderUploads = true
    @Published var reviewsUploads = false
    var transferBehavior: SFTPTransferBehavior {
        get { !freshUploads ? .readOnly : reviewsUploads ? .cautious : .normal }
        set { freshUploads = newValue != .readOnly; freshFolderUploads = newValue != .readOnly; reviewsUploads = newValue == .cautious }
    }
    @Published var freshUploadAvailable = false
    @Published var smbUploadAvailable = false
    var canUseFreshUploads: Bool {
        if connectionProtocol == .smb { return smbUploadAvailable && security == .encrypted }
        return freshUploadAvailable && (!jumpHost.enabled || SFTPRoutedUploadFeature.available)
    }
    var canUseFreshFolderUploads: Bool {
        if connectionProtocol == .smb { return canUseFreshUploads && SMBFolderUploadFeature.available }
        return canUseFreshUploads && SFTPFolderUploadFeature.available
            && (!jumpHost.enabled || SFTPRoutedFolderUploadFeature.available)
    }
    @Published var sftpAuthentication = SFTPAuthenticationMethod.password {
        didSet { if sftpAuthentication != oldValue { password = ""; keyPassphrase = ""; extraServerPrompts = false } }
    }
    @Published var extraServerPrompts = false
    @Published var keyPassphrase = ""
    @Published var rememberKeyAccess = false
    @Published var selectedKey: SFTPSelectedPrivateKey?
    @Published var selectedKeyURL: URL?
    @Published var selectedKeyName = ""
    @Published var savedKeyAvailable = false
    @Published var useUserCertificate = false
    @Published var selectedCertificate: SFTPSelectedUserCertificate?
    @Published var selectedCertificateURL: URL?
    @Published var certificateDirectory: URL?
    @Published var savedCertificateAvailable = false
    @Published var certificateNotice = ""
    @Published var showSSHProfiles = false
    @Published var sshProfiles = SFTPProfileImportModel()
    let jumpHost = SFTPJumpHostModel()
    @Published var selectedServer: UUID?
    @Published private(set) var servers: [SMBConnectServerChoice]
    @Published private(set) var sftpServers: [SFTPConnectServerChoice] = []
    fileprivate var visibleServers: [ConnectDisplayServer] {
        connectionProtocol == .smb ? servers.map { .init(id: $0.id, name: $0.name, host: $0.address.host, hasSavedPassword: $0.hasSavedPassword) }
            : sftpServers.map { .init(id: $0.id, name: $0.details.name, host: $0.details.address.host, hasSavedPassword: $0.hasSavedPassword) }
    }
    @Published private(set) var busy = false
    @Published var managing = false
    @Published private(set) var connectionStorageNotice = ""
    @Published private(set) var storageRefused = false
    var storageNeedsReview: Bool { !connectionStorageNotice.isEmpty }
    func showConnectionStorageIssue(_ message: String) { connectionStorageNotice = message }
    var unavailable: Bool { busy || managing || sshProfiles.busy }
    var profileFeaturesAvailable = SFTPProfileFeature.available
    var serverPromptsAvailable = SFTPInteractiveFeature.available
    var routeFeaturesAvailable = SFTPJumpFeature.available
    @Published private(set) var message = ""
    @Published private(set) var workspaceNotice = ""
    @Published private(set) var workspaceBlocked = false
    @Published private(set) var connected = false
    @Published private(set) var rememberingIncomplete = false
    @Published private(set) var cancellationNotice = false
    @Published private(set) var needsPasswordEntry = false
    private var applyingSaved = false
    private var updatingAddressFields = false
    private var portWasEdited = false
    private var appliedSelection: UUID?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let handler: Handler
    private var profileObservation: AnyCancellable?
    private var jumpObservation: AnyCancellable?
    private var importClosing = false
    var onConnected: (() -> Void)?
    var onCancelled: (() -> Void)?
    var onForgetServer: ((UUID) -> Void)?
    var onForgetPassword: (() -> Void)?
    var onStorage: (() -> Void)?
    var hasCurrentSavedPassword: Bool {
        guard let selectedServer else { return false }
        switch connectionProtocol {
        case .smb:
            guard let saved = servers.first(where: { $0.id == selectedServer && $0.hasSavedPassword }),
                  let entered = try? SMBConnectionAddress(address) else { return false }
            return entered.host == saved.address.host && entered.port == saved.address.port
                && entered.scopeID == saved.address.scopeID && entered.share == saved.address.share
                && account == saved.account && domain == saved.domain && security == saved.security
        case .sftp:
            guard let saved = sftpServers.first(where: { $0.id == selectedServer && $0.hasSavedPassword }),
                  let entered = try? SFTPConnectionAddress(address),
                  entered.host == saved.details.address.host, entered.port == saved.details.address.port,
                  entered.scopeID == saved.details.address.scopeID, account == saved.details.account else { return false }
            if let route = saved.route {
                guard jumpHost.enabled, let jump = try? jumpHost.draft(),
                      let current = try? SFTPRouteDescription(destination: saved.details, jump: jump),
                      WorkspaceConnectionBinding.route(current) == WorkspaceConnectionBinding.route(route.details) else { return false }
            } else if jumpHost.enabled { return false }
            return true
        }
    }
    var usingSavedPassword: Bool { hasCurrentSavedPassword && !changingSavedPassword }
    func changeSavedPassword() {
        guard hasCurrentSavedPassword else { return }
        changingSavedPassword = true; password = ""; rememberPassword = true
    }
    func useSavedPassword() {
        guard hasCurrentSavedPassword else { return }
        password = ""; changingSavedPassword = false; rememberPassword = false
    }
    func revealPasswordAfterSavedFailure() {
        guard hasCurrentSavedPassword else { return }
        changingSavedPassword = true; password = ""; rememberPassword = false
    }
    func showDeferredHostReview(_ kind: SFTPHostChallenge.Kind) {
        switch kind {
        case .changed: message = "This server’s identity changed. Connect again to review its new key before signing in. The saved password was not read."
        case .first: message = "The saved server identity is missing. Connect again to verify the server before signing in. The saved password was not read."
        case .matching: message = "Saved server identity changed during connection setup. Review Connection Storage before trying again. The saved password was not read."
        }
    }
    init(servers: [SMBConnectServerChoice] = [], handler: @escaping Handler) {
        self.servers = servers; self.handler = handler
        profileObservation = sshProfiles.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        jumpObservation = jumpHost.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        jumpHost.onIdentityChanged = { [weak self] in
            guard let self else { return }; identityChanged()
            if jumpHost.enabled {
                if !SFTPRoutedUploadFeature.available { transferBehavior = .readOnly }
                if !SFTPRoutedFolderUploadFeature.available { freshFolderUploads = false }
            }
        }
    }
    func choose(_ id: UUID?) {
        guard !busy else { return }
        applyingSaved = true; defer { applyingSaved = false }
        appliedSelection = id
        password = ""; changingSavedPassword = false
        message = ""; connected = false; cancellationNotice = false; storageRefused = false
        needsPasswordEntry = false; selectedServer = id
        resetKeyChoice(); sshProfiles.clearSelection(); jumpHost.reset()
        // Older saved details contain no transfer choice. They stay read-only;
        // a new connection visibly offers the normal policy before admission.
        transferBehavior = id == nil ? .normal : .readOnly
        if connectionProtocol == .sftp, let saved = sftpServers.first(where: { $0.id == id }) {
            address = saved.details.address.displayAddress; account = saved.details.account; domain = ""
            if let directory = saved.defaultDirectory { startingFolderField = directory.fieldText }
            name = saved.details.name; rememberServer = true; rememberPassword = false
            if let route = saved.route {
                jumpHost.configure(route, hasPassword: saved.jumpHasSavedPassword); showAdvanced = true
                switch route.destination.signIn {
                case .password: sftpAuthentication = .password
                case .serverPrompts: sftpAuthentication = .serverPrompts
                case .keyFile, .keyFileAndServerPrompts:
                    sftpAuthentication = .keyFile; extraServerPrompts = route.destination.signIn.usesServerPrompts
                    savedKeyAvailable = route.destination.keyAccess != nil; rememberKeyAccess = savedKeyAvailable
                    selectedKeyName = route.destination.keyAccess.map { "Saved key · " + $0.identity.algorithm } ?? "Choose a key file"
                }
            } else if let method = saved.keyAuthentication {
                sftpAuthentication = .keyFile; savedKeyAvailable = method.reference != nil
                useUserCertificate = method.requiresCertificate
                savedCertificateAvailable = method.certificate != nil
                extraServerPrompts = method.requiresServerPrompts
                selectedKeyName = method.reference.map { "Saved key · " + $0.identity.algorithm } ?? "Choose a key file"
                rememberKeyAccess = method.reference != nil && (!method.requiresCertificate || method.certificate != nil)
            } else if saved.usesServerPrompts {
                sftpAuthentication = .serverPrompts
            }
            transferBehavior = .init(preference: saved.transferPreference ?? saved.route?.transferPreference ?? .readOnly)
        } else if connectionProtocol == .smb, let saved = servers.first(where: { $0.id == id }) {
            address = saved.address.displayAddress; account = saved.account; domain = saved.domain
            security = saved.security; name = saved.name; rememberServer = true; rememberPassword = false
            transferBehavior = .init(preference: saved.security == .encrypted ? saved.transferPreference : .readOnly)
        } else {
            address = ""; account = ""; domain = ""; name = ""; security = .encrypted; rememberServer = false; rememberPassword = false
        }
    }
    func prefillUnsavedRoute(_ route: SFTPRouteDescription) {
        guard !busy else { return }
        connectionProtocol = .sftp; choose(nil)
        address = route.destination.address.displayAddress; account = route.destination.account
        name = route.destination.name; rememberServer = true; rememberPassword = false
        jumpHost.reset(); jumpHost.enabled = true
        jumpHost.address = route.jump.address.displayAddress; jumpHost.account = route.jump.account
        showAdvanced = true
        message = "Review both servers and choose sign-in methods to save this route. Your existing connection remains open."
    }
    private func identityChanged() {
        guard !applyingSaved else { return }
        password = ""; changingSavedPassword = false; resetConnectionFeedback()
        keyPassphrase = ""; savedKeyAvailable = false; savedCertificateAvailable = false
        jumpHost.invalidateStoredAccess()
    }
    private func resetConnectionFeedback() {
        guard !applyingSaved else { return }
        message = ""; connected = false; cancellationNotice = false
    }
    private func sameServerIdentity(_ lhs: String, _ rhs: String) -> Bool {
        switch connectionProtocol {
        case .sftp:
            guard let left = try? SFTPConnectionAddress(lhs), let right = try? SFTPConnectionAddress(rhs) else { return false }
            return left.host == right.host && left.port == right.port && left.scopeID == right.scopeID
        case .smb:
            guard let left = try? SMBConnectionAddress(lhs), let right = try? SMBConnectionAddress(rhs) else { return false }
            return left.host == right.host && left.port == right.port && left.scopeID == right.scopeID && left.share == right.share
        }
    }
    private func addressChanged(from oldValue: String) {
        guard !updatingAddressFields else { return }
        let sameIdentity = sameServerIdentity(address, oldValue)
        updatingAddressFields = true
        if connectionProtocol == .sftp, let endpoint = try? SFTPConnectionAddress(address) { applyFields(endpoint) }
        else if connectionProtocol == .smb, let endpoint = try? SMBConnectionAddress(address) { applyFields(endpoint) }
        else { serverField = address; portField = connectionProtocol == .sftp ? "22" : "445"; shareField = ""; startingFolderField = ""; portWasEdited = false }
        updatingAddressFields = false
        if !address.utf8.elementsEqual(oldValue.utf8) {
            if sameIdentity { resetConnectionFeedback() } else { identityChanged() }
        }
    }
    private func applyFields(_ endpoint: SFTPConnectionAddress) {
        serverField = endpoint.serverField; portField = String(endpoint.port); shareField = ""; startingFolderField = endpoint.startingFolderField; portWasEdited = false
    }
    private func applyFields(_ endpoint: SMBConnectionAddress) {
        serverField = endpoint.serverField; portField = String(endpoint.port); shareField = endpoint.share.displayName; startingFolderField = endpoint.startingFolderField; portWasEdited = false
    }
    private func fieldsChanged(invalidatesIdentity: Bool = true) {
        guard !updatingAddressFields else { return }
        if invalidatesIdentity { identityChanged() } else { resetConnectionFeedback() }
        updatingAddressFields = true; defer { updatingAddressFields = false }
        guard let port = UInt16(portField), port > 0, String(port) == portField else { address = ""; return }
        if connectionProtocol == .sftp {
            guard let directory = try? SFTPDefaultDirectory(field: startingFolderField, root: startingFolderField.hasPrefix("/") ? .server : .home),
                  let endpoint = try? SFTPConnectionAddress(server: serverField, port: port, startingFolder: directory.root == .home ? "" : directory.fieldText) else { address = ""; return }
            address = preservingSavedSFTPEndpoint(endpoint).displayAddress
        }
        else { address = (try? SMBConnectionAddress(server: serverField, port: port, share: shareField, startingFolder: startingFolderField))?.displayAddress ?? "" }
    }

    /// Start in is a navigation preference. Editing it cannot rewrite the
    /// original address used by a matching saved sign-in/trust identity.
    private func preservingSavedSFTPEndpoint(_ endpoint: SFTPConnectionAddress) -> SFTPConnectionAddress {
        guard let saved = sftpServers.first(where: { $0.id == selectedServer }),
              saved.details.address.host == endpoint.host, saved.details.address.port == endpoint.port,
              saved.details.address.scopeID == endpoint.scopeID, saved.details.account == account else { return endpoint }
        if let route = saved.route {
            guard jumpHost.enabled, let jump = try? jumpHost.draft(),
                  let current = try? SFTPRouteDescription(destination: saved.details, jump: jump),
                  SFTPConnectionPreferenceBinding(route: current) == SFTPConnectionPreferenceBinding(route: route.details) else { return endpoint }
        } else if jumpHost.enabled { return endpoint }
        return saved.details.address
    }
    /// URI paste remains optional. Normalize on explicit field submission or
    /// Connect, not in the middle of typing a host or its custom port.
    func acceptAddressEntry() {
        let embedded = serverField.contains("://") || serverField.contains("/")
            || serverField.contains("]:") || serverField.filter({ $0 == ":" }).count == 1
        guard embedded else { return }
        updatingAddressFields = true; defer { updatingAddressFields = false }
        if connectionProtocol == .sftp, let endpoint = try? SFTPConnectionAddress(serverField), !portWasEdited || String(endpoint.port) == portField {
            address = endpoint.displayAddress; applyFields(endpoint)
        } else if connectionProtocol == .smb, let endpoint = try? SMBConnectionAddress(serverField), !portWasEdited || String(endpoint.port) == portField {
            address = endpoint.displayAddress; applyFields(endpoint)
        }
    }
    func selectionChanged(_ id: UUID?) { if appliedSelection != id { choose(id) } }
    func selectWorkspaceLocation(_ bookmark: WorkspaceConnectionBookmark, reopeningTab: Bool = true) {
        connectionProtocol = bookmark.isSFTP ? .sftp : .smb
        let matches: Bool
        switch bookmark.kind {
        case .smbServer:
            matches = servers.first(where: { $0.id == bookmark.serverID }).map {
                (try? SMBServerDraft(name: $0.name, address: $0.address, account: $0.account, domain: $0.domain, security: $0.security))
                    .map { WorkspaceConnectionBinding.smb($0) == bookmark.binding } ?? false
            } ?? false
        case .sftpServer:
            matches = sftpServers.first(where: { $0.id == bookmark.serverID && $0.route == nil }).map {
                WorkspaceConnectionBinding.sftp($0.details) == bookmark.binding
            } ?? false
        case .sftpRoute:
            matches = sftpServers.first(where: { $0.id == bookmark.serverID })?.route.map {
                WorkspaceConnectionBinding.route($0.details) == bookmark.binding
            } ?? false
        }
        workspaceBlocked = !matches
        if matches { choose(bookmark.serverID) }
        workspaceNotice = matches ? (reopeningTab ? "Connect to reopen this saved tab. Your saved folder will be restored after sign-in." : "Review this saved server, then choose Connect.")
            : WorkspaceReconnectFailure.unavailable.message
    }
    func connect() {
        guard !unavailable, !workspaceBlocked, !storageNeedsReview else { return }
        needsPasswordEntry = false
        if changingSavedPassword && hasCurrentSavedPassword && password.isEmpty {
            message = "Enter the new password, or choose Use Saved Password."
            return
        }
        storageRefused = false
        acceptAddressEntry()
        ApplicationDiagnostics.shared.event(.connect, .requested)
        if connectionProtocol == .sftp { connectSFTP(); return }
        let submission: SMBConnectSubmission
        do {
            let endpoint = try SMBConnectionAddress(address)
            guard !account.isEmpty, account.utf8.count <= 256, domain.utf8.count <= 256,
                  !["guest", "anonymous"].contains(account.lowercased()),
                  !(account + domain).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw SMBConnectionInputFailure.account
            }
            let title = name.isEmpty ? String(endpoint.host.prefix(128)) : name
            _ = try SMBServerDraft(name: title, address: endpoint, account: account, domain: domain, security: security)
            submission = SMBConnectSubmission(address: endpoint, account: account, domain: domain, password: password.isEmpty ? nil : try SMBPassword(password), name: title,
                security: security, rememberServer: rememberServer, rememberPassword: rememberPassword, editingServer: selectedServer,
                transferPreference: canUseFreshUploads ? transferBehavior.preference : .readOnly)
        } catch {
            message = "Enter a host, port (1–65535), share and account. Guest connections are unavailable."
            return
        }
        start { phase in try await self.handler(submission, phase) }
    }
    private func connectSFTP() {
        guard let sftpHandler else { return }
        do {
            guard let port = UInt16(portField), port > 0, String(port) == portField else { throw SFTPConnectionInputFailure.address }
            let directory = try SFTPDefaultDirectory(field: startingFolderField,
                root: startingFolderField.hasPrefix("/") ? .server : .home)
            let entered = try SFTPConnectionAddress(server: serverField, port: port,
                startingFolder: directory.root == .home ? "" : directory.fieldText)
            let endpoint = preservingSavedSFTPEndpoint(entered), title = name.isEmpty ? String(endpoint.host.prefix(128)) : name
            let authentication: SFTPAuthenticationChoice
            switch sftpAuthentication {
            case .password: authentication = .password(password.isEmpty ? nil : try SFTPPassword(password))
            case .serverPrompts:
                guard serverPromptsAvailable else { message = "This saved sign-in method needs a newer Traverse build."; return }
                authentication = .serverPrompts
            case .keyFile:
                guard selectedKey != nil || savedKeyAvailable else { message = "Choose a private key for this connection."; return }
                if useUserCertificate {
                    guard !jumpHost.enabled else { message = "SSH certificate connections currently use a direct server connection."; return }
                    guard selectedCertificate != nil || savedCertificateAvailable else { message = "Choose the SSH certificate issued for this key."; return }
                    guard (selectedKey != nil) == (selectedCertificate != nil) else {
                        message = "Choose both the private key and its certificate, or use the saved pair."; return
                    }
                    guard !rememberKeyAccess || selectedCertificate == nil || certificateDirectory != nil else {
                        message = "Choose the certificate folder once to remember access to renewed certificates."; return
                    }
                    guard !extraServerPrompts || serverPromptsAvailable else {
                        message = "This saved sign-in method needs a newer Traverse build."; return
                    }
                    authentication = .userCertificate(key: selectedKey, certificate: selectedCertificate,
                        passphrase: try .init(keyPassphrase), rememberAccess: rememberServer && rememberKeyAccess,
                        profileAlias: sshProfiles.selectedAlias, serverPrompts: extraServerPrompts)
                } else if extraServerPrompts {
                    guard serverPromptsAvailable else { message = "This saved sign-in method needs a newer Traverse build."; return }
                    authentication = .keyFileWithServerPrompts(selectedKey, passphrase: try .init(keyPassphrase), rememberKey: rememberServer && rememberKeyAccess,
                        profileAlias: sshProfiles.selectedAlias)
                } else {
                    authentication = .keyFile(selectedKey, passphrase: try .init(keyPassphrase), rememberKey: rememberServer && rememberKeyAccess,
                        profileAlias: sshProfiles.selectedAlias)
                }
            }
            if let profile = sshProfiles.selected {
                let ready = jumpHost.enabled ? !useUserCertificate && !profile.needsSetup : profile.canConnect(using: authentication)
                guard ready else { message = "This SSH profile needs setup. Review the details below or create a separate connection."; return }
            }
            let draft = try SFTPServerDraft(name: title, address: endpoint, account: account)
            let route = jumpHost.enabled ? try SFTPRouteDescription(destination: draft, jump: jumpHost.draft()) : nil
            guard route == nil || routeFeaturesAvailable else { message = "Jump-host connections are still being qualified in this build."; return }
            let submission = SFTPConnectSubmission(draft: draft,
                password: password.isEmpty ? nil : try SFTPPassword(password), rememberServer: rememberServer,
                rememberPassword: sftpAuthentication == .password && rememberPassword && (route == nil || rememberServer),
                editingServer: route == nil ? selectedServer : nil,
                freshUploads: canUseFreshUploads && freshUploads,
                freshFolderUploads: canUseFreshFolderUploads && freshUploads && freshFolderUploads,
                reviewsUploads: reviewsUploads, transferPreference: transferBehavior.preference, authentication: authentication,
                configuration: sshProfiles.selectedAlias == nil ? nil : sshProfiles.snapshot, profileAlias: sshProfiles.selectedAlias,
                route: route, defaultDirectory: directory,
                jumpAuthentication: route == nil ? nil : try jumpHost.authentication(rememberConnection: rememberServer),
                rememberJumpPassword: route != nil && rememberServer && jumpHost.method == .password && jumpHost.rememberPassword,
                editingRoute: route == nil ? nil : sftpServers.first(where: { $0.id == selectedServer && $0.route != nil })?.id)
            start { phase in try await sftpHandler(submission, phase) }
        } catch { message = "Enter a host, port (1–65535) and account. Start in accepts Home (blank or ~), ~/folder, or /folder on the server." }
    }
    private func start(_ operation: @escaping @MainActor (@escaping @MainActor (String) -> Void) async throws -> SMBConnectSavedOutcome) {
        busy = true; password = ""; keyPassphrase = ""; jumpHost.clearSecrets(); connected = false; rememberingIncomplete = false; cancellationNotice = false; message = "Connecting…"; generation = UUID(); let token = generation
        ApplicationDiagnostics.shared.event(.connect, .preparing, trace: token)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let saved = try await operation { [weak self] phase in
                    guard let self, generation == token, busy, task?.isCancelled != true else { return }; message = phase
                }
                guard generation == token else { _ = await saved.discard(); return }
                password = ""; keyPassphrase = ""
                if Task.isCancelled {
                    let ended = await saved.discard() // Keep Busy until the unpublished session actually drains.
                    busy = false; task = nil
                    cancellationNotice = !ended || saved.host != .notRequested || saved.server != .notRequested || saved.password != .notRequested || saved.keyAccess != .notRequested
                    if cancellationNotice {
                        var notices = [ended ? "Connection closed." : "Connection closure is uncertain. Its resources remain reserved; try Quit again."]
                        if saved.host == .saved { notices.append("Verified server key saved.") }
                        if saved.host == .incomplete { notices.append("Server key saving needs review.") }
                        if saved.server == .saved { notices.append("Server saved.") }
                        if saved.password == .saved { notices.append("Password saved.") }
                        if saved.server == .incomplete { notices.append("Server saving needs review.") }
                        if saved.password == .incomplete { notices.append("Password saving needs review.") }
                        if saved.keyAccess == .saved { notices.append("Key access saved.") }
                        if saved.keyAccess == .incomplete { notices.append("Key access saving needs review.") }
                        message = notices.joined(separator: " ")
                    } else { message = "Connection cancelled."; onCancelled?() }
                    return
                }
                guard saved.canOpen() else {
                    let ended = await saved.discard(); busy = false; task = nil; cancellationNotice = true
                    var notices = [ended ? "The destination pane closed. Connection closed without opening a tab." : "The destination pane closed. Connection closure is uncertain; its resources remain reserved."]
                    if saved.host == .saved { notices.append("Verified server key saved.") }
                    if saved.server == .saved { notices.append("Server saved.") }
                    if saved.password == .saved { notices.append("Password saved.") }
                    if saved.server == .incomplete || saved.password == .incomplete { notices.append("Some remembering choices need review.") }
                    message = notices.joined(separator: " "); return
                }
                saved.open(); busy = false; task = nil
                connected = true
                ApplicationDiagnostics.shared.event(.connect, .completed, trace: token)
                rememberingIncomplete = saved.host == .incomplete || saved.server == .incomplete || saved.password == .incomplete || saved.keyAccess == .incomplete
                if rememberingIncomplete {
                    message = "Connected. Some remembering choices couldn’t be saved; your connection remains open."
                } else { message = "Connected." }
                onConnected?()
            } catch {
                guard generation == token else { return }
                let cause = (error as? SFTPConnectionFailure)?.cause ?? error
                needsPasswordEntry = cause is SMBPasswordFailure || cause is SFTPPasswordFailure
                    || (cause as? SFTPSessionFailure) == .authentication
                    || (cause as? SMBWorkerFailure) == .authentication
                    || (cause as? SMBBrowserFailure) == .authentication
                ApplicationDiagnostics.shared.event(.connect, Task.isCancelled ? .cancelled : .failed, trace: token,
                    error: DiagnosticErrors.project(error),
                    context: (error as? SFTPConnectionFailure)?.stage.map { .init($0.diagnosticCheckpoint) })
                busy = false; task = nil; keyPassphrase = ""
                let storageCause = (error as? SFTPConnectionFailure)?.cause ?? error
                storageRefused = (storageCause as? SFTPSessionFailure) == .storage
                    || (storageCause as? SMBBrowserFailure) == .storage
                    || (storageCause as? SMBBrowserFailure) == .quota
                    || storageCause is SMBTemporaryStorageFailure
                if let failure = error as? SFTPConnectionFailure {
                    password = ""; keyPassphrase = ""; cancellationNotice = Task.isCancelled || !failure.localResourcesEnded
                        || [failure.remembering.host, failure.remembering.server, failure.remembering.password].contains { $0 != .notRequested }
                    if failure.stage == .addressPreparation,
                       (failure.cause as? SFTPSessionFailure) == .deadline {
                        message = "Server name lookup timed out. Check the network or VPN, then try again."
                    } else { message = Self.sftpFailure(failure.cause) }
                    if !failure.localResourcesEnded { message += " Local connection closure is uncertain. Its resources remain reserved; review the identity window or try Quit again." }
                    if failure.remembering.host == .complete { message += " The verified key was saved." }
                    if failure.remembering.host == .incomplete { message += " Server key saving needs review." }
                    if failure.remembering.server == .complete { message += " Server saved." }
                    if failure.remembering.password == .complete { message += " Password saved." }
                    if failure.remembering.server == .incomplete || failure.remembering.password == .incomplete { message += " Some remembering choices need review." }
                    return
                }
                if Task.isCancelled || error is CancellationError {
                    password = ""; message = "Connection cancelled."; onCancelled?()
                } else {
                    message = connectionProtocol == .sftp ? Self.sftpFailure(error) : Self.failureMessage(error)
                }
            }
        }
    }
    func cancel() {
        password = ""; keyPassphrase = ""; jumpHost.clearSecrets()
        sshProfiles.cancel()
        if sshProfiles.busy {
            guard !importClosing else { return }; importClosing = true
            Task { [weak self] in
                guard let self else { return }; await sshProfiles.drain(); importClosing = false; onCancelled?()
            }
        } else if busy { message = "Closing connection…"; task?.cancel() }
        else { onCancelled?() }
    }
    func cancelAndDrain() async { let pending = task; cancel(); await pending?.value; await sshProfiles.drain() }
    func resetKeyChoice() {
        sftpAuthentication = .password; keyPassphrase = ""; rememberKeyAccess = false; extraServerPrompts = false
        selectedKey = nil; selectedKeyURL = nil; selectedKeyName = ""; savedKeyAvailable = false
        useUserCertificate = false; selectedCertificate = nil; selectedCertificateURL = nil
        certificateDirectory = nil; savedCertificateAvailable = false
        certificateNotice = ""
    }
    func replaceServers(_ values: [SMBConnectServerChoice], notice: String = "") {
        guard !busy else { return }; servers = values
        if connectionProtocol == .smb, let selectedServer, !values.contains(where: { $0.id == selectedServer }) { choose(nil) }
        if !notice.isEmpty { message = notice }
    }
    func replaceSFTPServers(_ values: [SFTPConnectServerChoice], notice: String = "") {
        guard !busy else { return }; sftpServers = values
        if connectionProtocol == .sftp, let selectedServer, !values.contains(where: { $0.id == selectedServer }) { choose(nil) }
        if !notice.isEmpty { message = notice }
    }
    private static func sftpFailure(_ error: any Error) -> String {
        if let failure = error as? WorkspaceReconnectFailure { return failure.message }
        if error is SMBTemporaryStorageFailure {
            return "Connection storage needs attention. Your saved text and downloaded files are kept. Review Connection Storage, then try again."
        }
        if error is CancellationError || (error as? SFTPSessionFailure) == .stopped { return "Connection cancelled." }
        if error is SFTPPasswordFailure { return "The saved password is unavailable for this exact verified host and account. Enter a password or review Connection Storage." }
        if error is SFTPSettingsFailure { return "Saved SFTP details need review. They have been preserved. Open Connection Storage before reconnecting." }
        if let failure = error as? SSHSelectedFileFailure {
            switch failure {
            case .permissions: return "The SSH key’s file permissions are too open. Use a private key readable only by your account."
            case .changed: return "The selected SSH settings or key changed. Choose it again before connecting."
            case .capacity: return "The selected SSH file exceeds the supported size. Choose a standard configuration or private key."
            default: return "The selected SSH file can’t be read. Choose it again and check its access."
            }
        }
        switch error as? SFTPSessionFailure {
        case .authentication: return "The server didn’t accept this account and sign-in method. Check the account, password or selected key and try again."
        case .keyPassphrase: return "The private key needs its correct passphrase. Enter it and try again."
        case .keyUnsupported: return "This key’s format, encryption or size is not supported. Use an Ed25519, ECDSA or RSA key in a supported OpenSSH or plain PEM format."
        case .keyChanged: return "The saved key or verified server identity changed. Choose the key again for these connection details."
        case .keyInput: return "The selected private key could not be verified. Choose the correct private key and try again."
        case .forwardDenied: return "The jump server couldn’t open a connection to this destination. Check its forwarding permission and the destination address."
        case .certificateExpired: return "The SSH certificate has expired according to this Mac’s clock. Renew your certificate, then reconnect."
        case .certificateNotYetValid: return "The SSH certificate is not valid yet according to this Mac’s clock. Check the time or obtain a new certificate, then reconnect."
        case .security: return "The server could not meet the required SSH security."
        case .denied: return "The server refused access."
        case .deadline: return "The server did not respond in time."
        case .busy: return "Another connection is opening or the connection limit is reached."
        case .storage: return "Temporary browsing storage is full or unavailable. Review Connection Storage."
        default: return "Couldn’t connect. Check the SFTP address and server, then try again."
        }
    }
    private static func failureMessage(_ error: Error) -> String {
        if let failure = error as? WorkspaceReconnectFailure { return failure.message }
        if let failure = error as? SMBPasswordFailure {
            switch failure {
            case .missing: return "Enter a password. No saved password is available for this connection."
            case .bindingMismatch: return "The saved password belongs to different connection details. Enter a password for these details."
            case .denied, .cancelled: return "Keychain access wasn’t granted. You can enter a password for this connection."
            default: return "The saved password is unavailable. You can enter it for this connection."
            }
        }
        let worker = error as? SMBWorkerFailure, browser = error as? SMBBrowserFailure, resolver = error as? SMBResolutionFailure
        if worker == .authentication || browser == .authentication { return "The account or password wasn’t accepted. Check them and try again." }
        if worker == .denied || browser == .denied { return "The server refused access to this share." }
        if worker == .security || browser == .security { return "The server couldn’t meet the selected security. Review Advanced." }
        if worker == .deadline || browser == .deadline || resolver == .deadline { return "The server didn’t respond in time. You can try again." }
        if browser == .busy || resolver == .busy { return "Another connection is opening or the connection limit is reached. Finish or close a connection, then try again." }
        if browser == .quota { return "Temporary browsing storage is full. Close a connection or review Connection Storage, then try again." }
        if browser == .storage || error is SMBTemporaryStorageFailure {
            return "Connection storage needs attention. Your saved text and downloaded files are kept. Review Connection Storage, then try again."
        }
        return "Couldn’t connect. Check the address and server, then try again."
    }
    #if DEBUG
    func messageForGeneratedReview() { message = "Generated layout review. Connect uses a simulated result; no server or Keychain is accessed." }
    #endif
}

private extension SFTPConnectionStage {
    var diagnosticCheckpoint: DiagnosticCheckpoint {
        switch self {
        case .configurationPreparation: .sftpConfigurationPreparation
        case .addressPreparation: .sftpAddressPreparation
        case .workerAdmission: .sftpWorkerAdmission
        case .hostReview: .sftpHostReview
        case .authenticationAndRemembering: .sftpAuthenticationAndRemembering
        case .browserAdoption: .sftpBrowserAdoption
        }
    }
}

@MainActor private struct SMBConnectForm: View {
    @ObservedObject var model: SMBConnectModel
    @ObservedObject var settings: BrowserSettings
    let toggleSidebar: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var addressFocused: Bool
    @FocusState private var domainFocused: Bool
    @State private var advancedHeight: CGFloat = 92
    var body: some View {
        HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved \(model.connectionProtocol.rawValue) Servers").interfaceFont(.headline)
                    if model.visibleServers.isEmpty {
                        Text("No saved servers yet. Choose Remember server when connecting to keep it here.")
                            .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    List(selection: $model.selectedServer) {
                        ForEach(model.visibleServers) { server in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(server.name, systemImage: "server.rack")
                                Text(server.host).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if server.hasSavedPassword { Label("Password saved", systemImage: "key").interfaceFont(.caption2).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4).tag(server.id)
                                .contextMenu { Button("Forget Server…", role: .destructive) { model.onForgetServer?(server.id) }.disabled(model.storageNeedsReview) }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    Button("New Connection", systemImage: "plus") { model.choose(nil); addressFocused = true }
                        .disabled(model.unavailable)
                    Button("Connection Storage…") { model.onStorage?() }.disabled(model.unavailable)
                        .interfaceFont(.callout)
                }.padding(14).frame(width: 225).disabled(model.unavailable)
                    .opacity(model.showServers ? 1 : 0).allowsHitTesting(model.showServers)
                    .accessibilityHidden(!model.showServers)
                Divider().frame(width: 1)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "network").interfaceFont(.system(size: 30)).foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect to Server").interfaceFont(.title2.weight(.semibold))
                        Text("Browse your shared folders and servers.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                        .help(model.showServers ? "Hide saved servers" : "Show saved servers")
                        .accessibilityLabel(model.showServers ? "Hide saved servers" : "Show saved servers")
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.workspaceNotice.isEmpty {
                        Label(model.workspaceNotice, systemImage: model.workspaceBlocked ? "exclamationmark.circle" : "rectangle.on.rectangle")
                            .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.sftpHandler != nil {
                        Picker("Protocol", selection: $model.connectionProtocol) {
                            ForEach(ExplorerConnectionProtocol.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).accessibilityLabel("Connection protocol")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        LabeledContent("Host / IP") {
                            TextField("server.example.com or 192.168.1.25", text: $model.serverField).focused($addressFocused)
                                .accessibilityLabel("Server host or IP address").accessibilityIdentifier("connectHost")
                                .onSubmit { model.acceptAddressEntry() }
                        }
                        LabeledContent("Port") {
                            TextField(model.connectionProtocol == .sftp ? "22" : "445", text: $model.portField)
                                .frame(width: 68 * CGFloat(settings.interfaceSize.percent) / 100).accessibilityLabel("Server port").accessibilityIdentifier("connectPort")
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    if model.connectionProtocol == .smb {
                        LabeledContent("Share") { TextField("Shared folder name", text: $model.shareField).accessibilityIdentifier("connectShare") }
                    }
                    LabeledContent("Account") { TextField("Account name", text: $model.account).textContentType(.username) }
                    if model.connectionProtocol == .sftp, model.jumpHost.enabled {
                        Label("Via \(model.jumpHost.address)", systemImage: "arrow.triangle.turn.up.right.diamond")
                            .interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if model.connectionProtocol == .sftp, model.profileFeaturesAvailable {
                        SFTPAuthenticationEditor(model: model, profiles: model.sshProfiles)
                    }
                    if model.connectionProtocol == .smb || !model.profileFeaturesAvailable || model.sftpAuthentication == .password {
                        if model.usingSavedPassword {
                            LabeledContent("Password") {
                                HStack(spacing: 12) {
                                    Label("Saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                                    Button("Change Password…") { model.changeSavedPassword() }
                                        .accessibilityIdentifier("connectChangePassword")
                                }
                            }
                        } else {
                            LabeledContent("Password") {
                                HStack(spacing: 12) {
                                    SecureField(model.changingSavedPassword ? "New password" : "Password", text: $model.password)
                                        .textContentType(.password)
                                    if model.changingSavedPassword {
                                        Button("Use Saved Password") { model.useSavedPassword() }
                                            .accessibilityIdentifier("connectUseSavedPassword")
                                    }
                                }
                            }
                        }
                    }
                    LabeledContent("Start in") {
                        TextField(model.connectionProtocol == .sftp ? "Home, ~/folder, or /folder" : "Share root (default), or /folder", text: $model.startingFolderField)
                            .accessibilityLabel("Optional starting folder").accessibilityIdentifier("connectStartingFolder")
                    }
                    HStack(spacing: 20) {
                        Toggle(model.connectionProtocol == .sftp && model.jumpHost.enabled ? "Remember connection" : "Remember server", isOn: $model.rememberServer)
                        if model.connectionProtocol == .smb || model.sftpAuthentication == .password {
                            Toggle("Remember password", isOn: $model.rememberPassword)
                                .disabled(model.connectionProtocol == .sftp && model.jumpHost.enabled && !model.rememberServer)
                        } else if model.profileFeaturesAvailable && model.sftpAuthentication == .keyFile {
                            Toggle(model.useUserCertificate ? "Remember key and certificate access" : "Remember key access",
                                isOn: Binding(get: { model.rememberKeyAccess }, set: { model.setRememberKeyAccess($0, owner: NSApp.keyWindow) }))
                                .disabled(!model.rememberServer)
                                .help(model.useUserCertificate
                                    ? "After a successful connection, remember the key and the certificate’s folder. Each reconnect reads the current certificate. Passphrases aren’t saved."
                                    : "Save access to this key file after a successful connection. Its passphrase is not saved.")
                        }
                    }.toggleStyle(.checkbox).interfaceFont(.callout).padding(.top, 2)
                    if model.rememberServer { LabeledContent("Save as") { TextField("Server name", text: $model.name) } }
                    if model.connectionProtocol == .sftp && model.jumpHost.enabled && model.rememberServer {
                        Text("Saves this route and both verified server identities after sign-in succeeds. Passwords and key-file access are separate choices.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(model.connectionProtocol == .sftp && model.sftpAuthentication == .serverPrompts
                         ? "Server settings can be remembered. Answers to server prompts stay in this connection only."
                         : model.connectionProtocol == .sftp && model.sftpAuthentication == .keyFile
                         ? "Remember server also saves your chosen sign-in method. Key-file access is a separate choice; passphrases aren’t saved."
                         : "Passwords are saved locally in your login Keychain only when requested, after connecting successfully.")
                        .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { model.showAdvanced.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right").interfaceFont(.caption.weight(.semibold))
                                .rotationEffect(.degrees(model.showAdvanced ? 90 : 0))
                            Text("Advanced")
                            Spacer()
                        }.frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Advanced")
                        .accessibilityValue(model.showAdvanced ? "Expanded" : "Collapsed")
                        .accessibilityHint(model.connectionProtocol == .smb ? "Domain and connection security" : "Authentication and saved password")
                        .accessibilityIdentifier("smbConnectAdvanced")
                        VStack(alignment: .leading, spacing: 10) {
                            if model.connectionProtocol == .smb {
                            LabeledContent("Domain") { TextField("Optional", text: $model.domain).focused($domainFocused) }
                            Picker("Security", selection: $model.security) {
                                Text("Encrypted (recommended)").tag(SMBWorkerSecurityPolicy.encrypted)
                                Text("Signed compatibility").tag(SMBWorkerSecurityPolicy.signedCompatibility)
                            }
                            } else {
                                if model.profileFeaturesAvailable { SFTPProfileControls(model: model, profiles: model.sshProfiles) }
                                Text(model.profileFeaturesAvailable ? "Server identity is verified before sign-in." : "Password authentication · Ed25519 server identity").interfaceFont(.callout)
                                Text(model.profileFeaturesAvailable ? "SSH profiles supply settings. External commands and automatic agent access are not used."
                                     : "Server identity is verified before using a password. SSH config, agents and private keys are not read.").interfaceFont(.caption).foregroundStyle(.secondary)
                                if model.routeFeaturesAvailable { SFTPJumpHostEditor(model: model.jumpHost, connection: model, settings: settings) }
                            }
                            Button(model.connectionProtocol == .sftp && model.jumpHost.enabled ? "Manage saved connection details…" : "Forget saved password for these details…") {
                                if model.connectionProtocol == .sftp && model.jumpHost.enabled { model.onStorage?() } else { model.onForgetPassword?() }
                            }
                                .interfaceFont(.caption).disabled(model.address.isEmpty || model.account.isEmpty)
                        }.padding(.top, 2).fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { advancedHeight = $0 }
                            .frame(height: model.showAdvanced ? advancedHeight : 0, alignment: .top).clipped()
                            .allowsHitTesting(model.showAdvanced).accessibilityElement(children: .contain)
                            .accessibilityHidden(!model.showAdvanced)
                }.textFieldStyle(ToolTextEntryStyle()).disabled(model.unavailable).padding(.trailing, 3)
                }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: .infinity).layoutPriority(1)
                if model.connectionProtocol == .sftp || model.smbUploadAvailable {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Use this connection", selection: Binding(get: { model.transferBehavior }, set: { model.transferBehavior = $0 })) {
                            ForEach(SFTPTransferBehavior.allCases) { Text($0.rawValue).tag($0) }
                        }.accessibilityIdentifier("connectTransferBehavior")
                        Text(!model.canUseFreshUploads ? "Uploads aren’t available for this connection. You can browse without changing server files."
                             : model.transferBehavior == .readOnly ? "Browse and download. Uploads are unavailable in this connection."
                             : model.transferBehavior == .cautious ? "Review the destination and name before each upload. Existing items are kept."
                             : model.connectionProtocol == .smb ? "Choose or drop files and folders to upload. Their server copies are verified before they appear. Existing items are kept."
                             : "Uploads start after you choose or drop an item. Existing items are kept.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.disabled(model.unavailable)
                        .help(model.connectionProtocol == .smb
                              ? "Remember server also saves this choice. Open connections keep their current capabilities. Selected items upload in order over an encrypted connection. Interrupted working copies remain available for review."
                              : "Remember server also saves this choice for future Connect actions on these exact details. Open connections keep their current capabilities. Folder uploads require a destination that others won’t move or replace while copying. Interrupted uploads may leave an incomplete item; Upload Outcomes keeps the result.")
                }
                Label(model.canUseFreshUploads && model.freshUploads ? (model.canUseFreshFolderUploads && model.freshFolderUploads ? "Encrypted · File and folder uploads" : "Encrypted · File uploads")
                    : model.connectionProtocol == .sftp || model.security == .encrypted ? "Encrypted connection · Read-only browsing" : "Signed connection · Traffic is not encrypted",
                    systemImage: model.connectionProtocol == .sftp || model.security == .encrypted ? "lock.shield" : "exclamationmark.shield")
                    .interfaceFont(.callout).foregroundStyle(model.connectionProtocol == .sftp || model.security == .encrypted ? Color.secondary : Color.orange)
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.message).interfaceFont(.callout).foregroundStyle(model.connected ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityLabel(model.message)
                }.frame(minHeight: 28, alignment: .topLeading)
                if model.storageNeedsReview || model.storageRefused {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.storageNeedsReview {
                            Text(model.connectionStorageNotice).interfaceFont(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Review Connection Storage…") { model.onStorage?() }
                            .disabled(model.managing || model.busy)
                            .accessibilityIdentifier("connectStorageReview")
                    }
                }
                HStack {
                    Text(model.connectionProtocol == .smb ? "SMB shared folders" : "SFTP · SSH file transfer").interfaceFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    let cancelTitle = model.busy ? "Cancel Connection" : "Cancel"
                    let submitTitle = model.connected || model.cancellationNotice ? "Done" : "Connect"
                    Button(cancelTitle) { model.cancel() }.keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text(cancelTitle)).accessibilityIdentifier("connectCancel")
                    Button(submitTitle) { if model.connected || model.cancellationNotice { model.cancel() } else { model.connect() } }
                        .accessibilityLabel(Text(submitTitle)).accessibilityIdentifier("connectSubmit")
                        .keyboardShortcut(.defaultAction).disabled(model.unavailable || model.workspaceBlocked || model.storageNeedsReview)
                }
            }.padding(22).frame(width: model.editorWidth)
        }
        .frame(width: model.editorWidth + 226).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).clipped()
        .onChange(of: model.selectedServer) { _, id in model.selectionChanged(id) }
        .onChange(of: model.showAdvanced) { _, expanded in if !expanded && domainFocused { addressFocused = true } }
        .onChange(of: model.jumpHost.enabled) { _, enabled in
            if enabled { if !SFTPRoutedUploadFeature.available { model.freshUploads = false }; if !SFTPRoutedFolderUploadFeature.available { model.freshFolderUploads = false } }
        }
        .onChange(of: model.freshUploads) { _, enabled in if !enabled { model.freshFolderUploads = false } }
        .onAppear { addressFocused = true }
        .environment(\.colorScheme, settings.appearance == .system ? systemColorScheme : settings.appearance == .dark ? .dark : .light)
        .animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeInOut(duration: 0.25 * settings.motion.mode.durationScale), value: model.showAdvanced)
        .toolPageCrossfade(model.sftpAuthentication, motion: settings.motion)
        .transaction { if reduceMotion || !settings.motion.allows(.pages) { $0.disablesAnimations = true } }
    }
}

@MainActor final class SMBConnectWindowController: NSWindowController, NSWindowDelegate {
    let model: SMBConnectModel
    private let settings: BrowserSettings
    private var closeAfterDrain = false
    private var positioned = false
    private let resizeMotion = SMBConnectResizeMotion()
    private var settingSidebarFrame = false
    var didClose: (() -> Void)?
    init(settings: BrowserSettings, servers: [SMBConnectServerChoice] = [], handler: @escaping SMBConnectModel.Handler) {
        self.settings = settings; model = SMBConnectModel(servers: servers, handler: handler)
        let window = ToolWindowChrome.makeWindow(title: "Connect to Server", size: .init(width: 600, height: 540),
            minimumSize: .init(width: 600, height: 540))
        window.contentMinSize = .init(width: 600, height: 540)
        super.init(window: window); window.delegate = self
        let host = InterfaceHostingController(rootView: SMBConnectForm(model: model, settings: settings) { [weak self] in self?.toggleSidebar() })
        // This controller owns window geometry, including the display-aligned
        // sidebar reveal. The SwiftUI ideal size must not resize it separately.
        host.sizingOptions = []
        window.contentViewController = host
        ToolWindowChrome.install(in: window, settings: settings)
        window.setContentSize(.init(width: 600, height: 540))
        model.onCancelled = { [weak self] in self?.window?.close() }
        model.onConnected = { [weak self] in
            guard let self else { return }
            if !model.rememberingIncomplete || closeAfterDrain { self.window?.close() }
        }
    }
    required init?(coder: NSCoder) { nil }
    #if DEBUG
    var gateANoFocus = false
    #endif
    func present(relativeTo owner: NSWindow? = nil, offscreen: Bool = false) {
        if let window, !positioned {
            ToolWindowChrome.position(window, relativeTo: owner); positioned = true
        }
        if offscreen { window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
        #if DEBUG
        if offscreen && gateANoFocus { window?.orderFront(nil); return }
        #endif
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    private func toggleSidebar() {
        setSidebarVisible(!model.showServers)
    }
    func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        let allowed = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && settings.motion.allows(.pages)
        // AppKit is the single geometry animator. The fixed-width form remains
        // right-anchored; SwiftUI never independently squeezes or translates it.
        model.showServers = visible
        guard let window else { return }
        let width: CGFloat = model.editorWidth + (model.showServers ? 226 : 0)
        var frame = window.frame; frame.origin.x = frame.maxX - width; frame.size.width = width
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
        }
        if allowed {
            resizeMotion.animate(window, to: frame, mode: settings.motion.mode)
        } else {
            resizeMotion.cancel(); settingSidebarFrame = true
            window.setFrame(frame, display: true); settingSidebarFrame = false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy || model.sshProfiles.busy { closeAfterDrain = true; model.cancel(); return false }
        model.password = ""; model.keyPassphrase = ""; return true
    }
    func windowWillClose(_ notification: Notification) {
        resizeMotion.cancel(); let callback = didClose; didClose = nil; callback?()
    }
    func windowWillStartLiveResize(_ notification: Notification) { resizeMotion.cancel() }
    func windowDidResize(_ notification: Notification) {
        guard let window, !settingSidebarFrame, !resizeMotion.isAnimating else { return }
        model.editorWidth = max(600, window.frame.width - (model.showServers ? 226 : 0))
    }
}

/// Advance real layout in display-aligned steps. Implicit whole-window scaling
/// can briefly stretch/clip native controls while the backing surface changes.
@MainActor private final class SMBConnectResizeMotion {
    @MainActor private final class Tick: NSObject {
        weak var owner: SMBConnectResizeMotion?
        @objc func update(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.update(link)
        }
    }
    private let tick = Tick()
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var start = NSRect.zero, finish = NSRect.zero
    private var began = 0.0
    private var duration = 0.36
    var isAnimating: Bool { link != nil }
    init() { tick.owner = self }
    isolated deinit { link?.invalidate() }
    func animate(_ window: NSWindow, to frame: NSRect, mode: BrowserMotionMode) {
        cancel(); self.window = window; start = window.frame; finish = frame; began = CACurrentMediaTime()
        duration = 0.36 * mode.durationScale
        let link = window.displayLink(target: tick, selector: #selector(Tick.update(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func cancel() { link?.invalidate(); link = nil; window = nil }
    private func update(_ link: CADisplayLink) {
        guard let window, window.isVisible else { cancel(); return }
        let progress = min(1, max(0, (link.targetTimestamp - began) / max(0.001, duration)))
        let eased = progress * progress * (3 - 2 * progress)
        let frame = NSRect(x: start.minX + (finish.minX - start.minX) * eased, y: start.minY,
            width: start.width + (finish.width - start.width) * eased, height: start.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        window.setFrame(frame, display: true, animate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()
        if progress >= 1 { cancel() }
    }
}
