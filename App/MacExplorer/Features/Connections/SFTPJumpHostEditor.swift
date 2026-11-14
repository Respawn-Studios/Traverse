import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

enum SFTPJumpFeature { static let available = true }

@MainActor final class SFTPJumpHostModel: ObservableObject {
    @Published var enabled = false { didSet { if !enabled { clearSecrets(); selectedKey = nil; savedKeyAvailable = false; rememberPassword = false; rememberKey = false } } }
    @Published var address = "" { didSet { if !address.utf8.elementsEqual(oldValue.utf8) { identityChanged() } } }
    @Published var account = "" { didSet { if !account.utf8.elementsEqual(oldValue.utf8) { identityChanged() } } }
    @Published var method = SFTPAuthenticationMethod.password { didSet { if method != oldValue { clearSecrets(); extraPrompts = false } } }
    @Published var password = ""
    @Published var passphrase = ""
    @Published var keyName = ""
    @Published var selectedKey: SFTPSelectedPrivateKey?
    @Published var savedKeyAvailable = false
    @Published var hasSavedPassword = false
    @Published private(set) var changingSavedPassword = false
    @Published var rememberPassword = false
    @Published var rememberKey = false
    @Published var extraPrompts = false
    var profileAlias: String?
    var onIdentityChanged: (() -> Void)?
    private var applying = false
    func clearSecrets() { password = ""; passphrase = "" }
    func invalidateStoredAccess() { clearSecrets(); savedKeyAvailable = false; hasSavedPassword = false; changingSavedPassword = false }
    func changeSavedPassword() {
        guard hasSavedPassword else { return }
        changingSavedPassword = true; password = ""; rememberPassword = true
    }
    func useSavedPassword() {
        guard hasSavedPassword else { return }
        password = ""; changingSavedPassword = false; rememberPassword = false
    }
    func revealPasswordAfterSavedFailure() {
        guard hasSavedPassword else { return }
        changingSavedPassword = true; password = ""; rememberPassword = false
    }
    private func identityChanged() { guard !applying else { return }; invalidateStoredAccess(); onIdentityChanged?() }
    func reset() {
        applying = true; defer { applying = false }
        enabled = false; address = ""; account = ""; method = .password; keyName = ""
        hasSavedPassword = false; changingSavedPassword = false; extraPrompts = false; profileAlias = nil
    }
    func configure(_ imported: SFTPImportedJump) {
        reset(); applying = true; defer { applying = false }
        enabled = true; address = imported.address.displayAddress; account = imported.account ?? ""; profileAlias = imported.alias
        switch imported.preferredAuthentications.first(where: { ["publickey", "password", "keyboard-interactive"].contains($0) }) {
        case "publickey": method = .keyFile
        case "keyboard-interactive": method = .serverPrompts
        default: method = .password
        }
    }
    func configure(_ saved: SFTPSavedRoute, hasPassword: Bool) {
        reset(); applying = true; defer { applying = false }
        enabled = true; address = saved.details.jump.address.displayAddress; account = saved.details.jump.account
        profileAlias = saved.jump.profileAlias; hasSavedPassword = hasPassword
        switch saved.jump.signIn {
        case .password: method = .password
        case .serverPrompts: method = .serverPrompts
        case .keyFile, .keyFileAndServerPrompts:
            method = .keyFile; extraPrompts = saved.jump.signIn.usesServerPrompts
            savedKeyAvailable = saved.jump.keyAccess != nil; rememberKey = savedKeyAvailable
            keyName = saved.jump.keyAccess.map { "Saved key · " + $0.identity.algorithm } ?? "Choose a private key"
        }
    }
    func draft() throws -> SFTPServerDraft {
        let address = try SFTPConnectionAddress(address)
        return try .init(name: String(address.host.prefix(128)), address: address, account: account)
    }
    func authentication(rememberConnection: Bool) throws -> SFTPAuthenticationChoice {
        switch method {
        case .password: return .password(password.isEmpty ? nil : try .init(password))
        case .serverPrompts: return .serverPrompts
        case .keyFile:
            guard selectedKey != nil || savedKeyAvailable else { throw SFTPSessionFailure.keyInput }
            let phrase = try SFTPKeyPassphrase(passphrase)
            return extraPrompts ? .keyFileWithServerPrompts(selectedKey, passphrase: phrase, rememberKey: rememberConnection && rememberKey, profileAlias: profileAlias)
                : .keyFile(selectedKey, passphrase: phrase, rememberKey: rememberConnection && rememberKey, profileAlias: profileAlias)
        }
    }
    func chooseKey(owner: NSWindow?, suggestion: URL?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.title = "Choose Jump Host Private Key"; panel.prompt = "Choose Key"
        panel.message = "This key is used only after the jump host’s identity is verified."
        if let suggestion { panel.directoryURL = suggestion.deletingLastPathComponent() }
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let file = panel.url, let key = try? SFTPSelectedPrivateKey(file: file), let self else { return }
            method = .keyFile; selectedKey = key; keyName = file.lastPathComponent; savedKeyAvailable = false; passphrase = ""
        }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
}

struct SFTPJumpHostEditor: View {
    @ObservedObject var model: SFTPJumpHostModel
    @ObservedObject var connection: SMBConnectModel
    @ObservedObject var settings: BrowserSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Toggle("Connect through a jump host", isOn: $model.enabled).toggleStyle(.checkbox)
                .accessibilityIdentifier("sftpUseJumpHost")
                .disabled(connection.sshProfiles.selected?.jump != nil)
            if model.enabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Traverse verifies the jump host first, then the destination. Each has its own sign-in.")
                        .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Jump host") { TextField("Host or sftp://host:port", text: $model.address).accessibilityIdentifier("sftpJumpAddress") }
                    LabeledContent("Account") { TextField("Jump host account", text: $model.account).textContentType(.username).accessibilityIdentifier("sftpJumpAccount") }
                    Picker("Jump sign-in", selection: $model.method) {
                        ForEach(SFTPAuthenticationMethod.allCases.filter { method in
                            guard let imported = connection.sshProfiles.selected?.jump else { return true }
                            return imported.preferredAuthentications.contains(method == .password ? "password" : method == .serverPrompts ? "keyboard-interactive" : "publickey")
                        }) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("sftpJumpSignIn")
                    if model.method == .password {
                        if model.hasSavedPassword && !model.changingSavedPassword {
                            LabeledContent("Password") {
                                HStack(spacing: 12) {
                                    Label("Saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                                    Button("Change Password…") { model.changeSavedPassword() }
                                        .accessibilityIdentifier("sftpJumpChangePassword")
                                }
                            }
                        } else {
                            LabeledContent("Password") {
                                HStack(spacing: 12) {
                                    SecureField(model.changingSavedPassword ? "New jump password" : "Jump host password", text: $model.password)
                                        .textContentType(.password)
                                    if model.changingSavedPassword {
                                        Button("Use Saved Password") { model.useSavedPassword() }
                                            .accessibilityIdentifier("sftpJumpUseSavedPassword")
                                    }
                                }
                            }
                        }
                        Toggle("Remember jump password", isOn: $model.rememberPassword).toggleStyle(.checkbox).disabled(!connection.rememberServer)
                    } else if model.method == .keyFile {
                        HStack {
                            Label(model.keyName.isEmpty ? "Choose a jump host key" : model.keyName, systemImage: "key").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose Key…") { model.chooseKey(owner: NSApp.keyWindow, suggestion: connection.sshProfiles.selected?.jump?.identitySuggestions.first) }
                                .accessibilityLabel("Choose jump host private key").accessibilityIdentifier("sftpJumpChooseKey")
                        }
                        LabeledContent("Passphrase") { SecureField("If the jump key is encrypted", text: $model.passphrase).textContentType(.password) }
                        Toggle("Additional jump verification step", isOn: $model.extraPrompts).toggleStyle(.checkbox)
                            .accessibilityLabel("Additional jump verification step").accessibilityIdentifier("sftpJumpAdditionalVerification")
                        Toggle("Remember jump key access", isOn: $model.rememberKey).toggleStyle(.checkbox).disabled(!connection.rememberServer)
                    } else {
                        Text("The verified jump host will ask for the responses it needs. Answers are not saved.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if connection.sshProfiles.selected?.jump?.keyPathWarning == true {
                        Text("Choose the jump key explicitly; one configured key path could not be expanded.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(SFTPRoutedUploadFeature.available
                        ? "Browse, download, and upload new files. Folder uploads through a jump host aren’t available yet. Passphrases and verification codes stay in this connection only."
                        : SFTPRoutedDownloadFeature.available
                        ? "Browse and download files or folders. Uploads through a jump host are unavailable. Passphrases and verification codes stay in this connection only."
                        : "Jump connections currently support read-only browsing. Passphrases and verification codes stay in this connection only.")
                        .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 11))
            }
        }.animation(reduceMotion || !settings.motion.allows(.pages) ? nil : .easeInOut(duration: 0.25 * settings.motion.mode.durationScale), value: model.enabled)
            .toolPageCrossfade(model.method, motion: settings.motion)
    }
}
