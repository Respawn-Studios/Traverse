import AppKit
import Combine
import Darwin
import SwiftUI
@_spi(Qualification) import LocalStorage

enum SFTPProfileFeature { static let available = true }
enum SFTPAuthenticationMethod: String, CaseIterable, Identifiable {
    case password = "Password", keyFile = "Private key", serverPrompts = "Server prompts"
    var id: Self { self }
}

@MainActor final class SFTPProfileImportModel: ObservableObject {
    @Published private(set) var profiles: [SFTPImportedProfile] = []
    @Published private(set) var selectedAlias: String?
    @Published private(set) var busy = false
    @Published private(set) var notice = ""
    @Published var query = ""
    private(set) var snapshot: SSHConfigurationImport?
    private(set) var authority: URL?
    private let reader = SSHConfigurationReader()
    private var task: Task<Void, Never>?
    var serverPromptsAvailable = SFTPInteractiveFeature.available
    var singleJumpAvailable = SFTPJumpFeature.available
    var selected: SFTPImportedProfile? { profiles.first { $0.alias == selectedAlias } }
    var filtered: [SFTPImportedProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? profiles : profiles.filter { $0.alias.localizedStandardContains(needle) || $0.address?.host.localizedStandardContains(needle) == true }
    }
    func select(_ profile: SFTPImportedProfile) { guard !busy else { return }; selectedAlias = profile.alias }
    func clearSelection() { selectedAlias = nil }
    func load(directory: URL) {
        guard !busy else { return }; busy = true; notice = "Reading selected SSH settings…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; task = nil }
            do {
                let home = try await UserAccountHome.resolve()
                let imported = try await reader.load(selected: directory.appendingPathComponent("config"), authorizedDirectory: directory,
                    userSSHDirectory: home.appendingPathComponent(".ssh", isDirectory: true))
                try Task.checkCancellation()
                profiles = imported.connectionProfiles(home: home, localUser: NSUserName(), userID: getuid(), serverPrompts: serverPromptsAvailable, singleJump: singleJumpAvailable)
                snapshot = imported; authority = directory; selectedAlias = nil; query = ""
                notice = profiles.isEmpty ? "No named Host entries were found in the selected settings." : "Choose a profile. Key files are used only after server verification."
            } catch {
                guard !Task.isCancelled else { notice = "Import cancelled."; return }
                notice = "Couldn’t import these SSH settings. Choose the folder containing config, or enter a connection manually."
            }
        }
    }
    func chooseFolder(owner: NSWindow?, prepare: @escaping @MainActor () -> Void) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.title = "Import SSH Profiles"; panel.prompt = "Import Profiles"
        panel.message = "Choose your SSH settings folder (usually .ssh). Traverse reads config and included settings in this folder. Key files are selected separately."
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }; prepare(); self?.load(directory: url)
        }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
    func cancel() { task?.cancel() }
    func drain() async { let pending = task; pending?.cancel(); await pending?.value }
}

extension SMBConnectModel {
    func applySSHProfile(_ profile: SFTPImportedProfile) {
        guard !unavailable else { return }
        choose(nil)
        // Selecting a profile supplies visible values, never a saved password,
        // host-trust decision, private-key read or persistent file grant.
        if let endpoint = profile.address { address = endpoint.displayAddress }
        account = profile.account ?? ""; name = profile.alias
        sshProfiles.select(profile)
        let available = serverPromptsAvailable ? ["publickey", "password", "keyboard-interactive"] : ["publickey", "password"]
        switch profile.preferredAuthentications.first(where: { available.contains($0) }) {
        case "publickey": sftpAuthentication = .keyFile
        case "keyboard-interactive": sftpAuthentication = .serverPrompts
        default: sftpAuthentication = .password
        }
        if profile.issues.contains(.certificate) {
            sftpAuthentication = .keyFile; useUserCertificate = true
        }
        if let jump = profile.jump { jumpHost.configure(jump); showAdvanced = true }
        showSSHProfiles = false
    }
    func chooseSSHKey(owner: NSWindow?, suggestion: URL? = nil) {
        guard !unavailable else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.title = "Choose SSH Private Key"; panel.prompt = "Choose Key"
        panel.message = "Choose a private key for this connection. Traverse uses it only after you verify the server."
        if let suggestion { panel.directoryURL = suggestion.deletingLastPathComponent() }
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.useSSHKey(url)
        }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
    func useSSHKey(_ file: URL, accessRoot: URL? = nil) {
        guard !unavailable, let choice = try? SFTPSelectedPrivateKey(file: file, accessRoot: accessRoot) else { return }
        selectedKey = choice; selectedKeyURL = file; selectedKeyName = file.lastPathComponent; savedKeyAvailable = false; keyPassphrase = ""
        savedCertificateAvailable = false
        sftpAuthentication = .keyFile
    }
    var activeProfileIssues: Set<SFTPProfileSetupIssue> {
        let issues = sshProfiles.selected?.issues ?? []
        return useUserCertificate && !jumpHost.enabled ? issues.subtracting([.certificate]) : issues
    }
    var activeProfileNeedsSetup: Bool { !activeProfileIssues.subtracting([.keyPath]).isEmpty }
    var certificateName: String {
        selectedCertificateURL?.lastPathComponent ?? (savedCertificateAvailable ? "Saved certificate · refreshed on reconnect" : "Choose the issued certificate")
    }
    func setCertificateMode(_ enabled: Bool) {
        guard !unavailable else { return }
        useUserCertificate = enabled
        if !enabled {
            if savedCertificateAvailable { savedKeyAvailable = false; selectedKeyName = "Choose a key file" }
            selectedCertificate = nil; selectedCertificateURL = nil; certificateDirectory = nil
            savedCertificateAvailable = false
        }
        certificateNotice = ""
    }
    func chooseSSHCertificate(owner: NSWindow?) {
        guard !unavailable else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.title = "Choose SSH User Certificate"; panel.prompt = "Choose Certificate"
        panel.message = "Choose the public certificate issued for your private key, usually named key-cert.pub."
        if let suggested = sshProfiles.selected?.certificateSuggestions.first
            ?? selectedKeyURL.map({ URL(fileURLWithPath: $0.path + "-cert.pub") }) {
            panel.directoryURL = suggested.deletingLastPathComponent(); panel.nameFieldStringValue = suggested.lastPathComponent
        }
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            useSSHCertificate(url)
            if rememberKeyAccess {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.chooseCertificateDirectory(owner: owner)
                }
            }
        }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
    func useSSHCertificate(_ file: URL, directory: URL? = nil) {
        guard !unavailable, let selected = try? SFTPSelectedUserCertificate(file: file, accessRoot: directory) else { return }
        selectedCertificate = selected; selectedCertificateURL = file; certificateDirectory = directory
        savedCertificateAvailable = false; savedKeyAvailable = false; useUserCertificate = true
        certificateNotice = ""
    }
    func setRememberKeyAccess(_ enabled: Bool, owner: NSWindow?) {
        guard !unavailable, !enabled || rememberServer else { return }
        rememberKeyAccess = enabled
        if enabled, useUserCertificate, selectedCertificateURL != nil, certificateDirectory == nil {
            chooseCertificateDirectory(owner: owner)
        }
    }
    func chooseCertificateDirectory(owner: NSWindow?) {
        guard !unavailable, let file = selectedCertificateURL else { return }
        let expected = file.deletingLastPathComponent()
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true; panel.directoryURL = expected
        panel.title = "Remember Certificate Renewal"; panel.prompt = "Allow Certificate Renewal"
        panel.message = "Choose the folder containing \(file.lastPathComponent). Traverse will read only this certificate name when reconnecting, including after your sign-in tool replaces it."
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let directory = panel.url else { rememberKeyAccess = false; return }
            guard directory.standardizedFileURL.path == expected.standardizedFileURL.path else {
                rememberKeyAccess = false
                certificateNotice = "Choose the folder containing the selected certificate to remember renewal access."
                return
            }
            useSSHCertificate(file, directory: directory)
        }
        if let owner { panel.beginSheetModal(for: owner, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
    func detachSSHProfile(owner: NSWindow?) {
        guard !unavailable else { return }
        let routed = sshProfiles.selected?.jump != nil
        let alert = NSAlert(); alert.messageText = routed ? "Customize this connection?" : "Create a separate direct connection?"
        alert.informativeText = routed ? "The destination and jump-host details will be kept. Future SSH profile changes will not apply to this customized connection. Both server identities will still be verified."
            : "The displayed address and account will be kept. Imported commands, jump routes and other SSH policies will not apply. Choose an authentication method and verify the server separately. Your SSH settings stay unchanged."
        alert.addButton(withTitle: routed ? "Customize Connection" : "Create Direct Connection"); alert.addButton(withTitle: "Cancel")
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.sshProfiles.clearSelection(); if !routed { self?.jumpHost.reset() }
        }
        if let owner { alert.beginSheetModal(for: owner, completionHandler: completed) } else { completed(alert.runModal()) }
    }
}

extension SFTPProfileSetupIssue {
    var userMessage: String {
        switch self {
        case .unresolvedConfiguration: "Some included or conditional SSH settings couldn’t be resolved."
        case .externalCommand: "This profile runs another app or script, such as a company or AWS connection command. Traverse won’t execute it."
        case .agent: "This profile requires SSH-agent access, which is unavailable here. A private key can be chosen for a separate connection."
        case .certificate: "Choose the SSH user certificate issued for this profile’s private key."
        case .algorithms: "This profile specifies an algorithm policy that needs review."
        case .hostTrust: "This profile specifies a host-trust policy that needs review."
        case .network: "This profile requires network settings that haven’t been applied."
        case .unsupportedOption: "This profile contains additional settings that haven’t been applied."
        case .authentication: "The profile’s required authentication method is not available yet."
        case .jumpHost: "This profile connects through a jump host. That route needs setup before connecting."
        case .keyPath: "One key path couldn’t be expanded. Choose the key file explicitly."
        }
    }
}

struct SFTPProfilePicker: View {
    @ObservedObject var model: SMBConnectModel
    @ObservedObject var profiles: SFTPProfileImportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH Profiles").interfaceFont(.headline)
            TextField("Find a profile", text: $profiles.query).textFieldStyle(ToolTextEntryStyle())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(profiles.filtered) { profile in
                        Button { model.applySSHProfile(profile) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.alias).interfaceFont(.body.weight(.medium))
                                    Text(profile.address?.host ?? "Needs setup").interfaceFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.needsSetup { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
                            }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(minHeight: 90, maxHeight: 260)
        }.padding(15).frame(width: 340)
    }
}

struct SFTPProfileControls: View {
    @ObservedObject var model: SMBConnectModel
    @ObservedObject var profiles: SFTPProfileImportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(profiles.profiles.isEmpty ? "Import SSH Profiles…" : "Import Other Profiles…", systemImage: "square.and.arrow.down") {
                    profiles.chooseFolder(owner: NSApp.keyWindow) { model.choose(nil) }
                }
                if !profiles.profiles.isEmpty {
                    Button(profiles.selectedAlias ?? "Choose Profile…") { model.showSSHProfiles.toggle() }
                        .popover(isPresented: $model.showSSHProfiles) { SFTPProfilePicker(model: model, profiles: profiles) }
                }
                if profiles.busy { ProgressView().controlSize(.small) }
            }.disabled(model.unavailable || profiles.busy)
            if !profiles.notice.isEmpty { Text(profiles.notice).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let profile = profiles.selected, !model.activeProfileNeedsSetup {
                VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Using \(profile.alias)’s settings", systemImage: "person.text.rectangle").interfaceFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Customize…") { model.detachSSHProfile(owner: NSApp.keyWindow) }.interfaceFont(.caption)
                }
                    if let jump = profile.jump {
                        Label("Via \(jump.address.host)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    if profile.issues.contains(.keyPath) {
                        Text(SFTPProfileSetupIssue.keyPath.userMessage).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let profile = profiles.selected {
                VStack(alignment: .leading, spacing: 6) {
                    Label(profile.alias, systemImage: model.activeProfileNeedsSetup ? "exclamationmark.circle" : "person.text.rectangle")
                        .interfaceFont(.callout.weight(.medium))
                    ForEach(model.activeProfileIssues.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                        Text($0.userMessage).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Use a separate direct connection…") { model.detachSSHProfile(owner: NSApp.keyWindow) }.interfaceFont(.caption)
                }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct SFTPAuthenticationEditor: View {
    @ObservedObject var model: SMBConnectModel
    @ObservedObject var profiles: SFTPProfileImportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sign in with", selection: $model.sftpAuthentication) {
                ForEach(SFTPAuthenticationMethod.allCases.filter { method in
                    guard method != .serverPrompts || model.serverPromptsAvailable else { return false }
                    guard let profile = profiles.selected else { return true }
                    return profile.preferredAuthentications.contains(method == .password ? "password" : method == .serverPrompts ? "keyboard-interactive" : "publickey")
                }) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("sftpSignIn")
            if model.sftpAuthentication == .keyFile {
                HStack {
                    Label(model.selectedKeyName.isEmpty ? "Choose a private key" : model.selectedKeyName, systemImage: "key")
                        .interfaceFont(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose Key…") { model.chooseSSHKey(owner: NSApp.keyWindow, suggestion: profiles.selected?.identitySuggestions.first) }
                        .accessibilityLabel("Choose private key").accessibilityIdentifier("sftpChooseKey")
                }
                if let root = profiles.authority, let suggested = profiles.selected?.identitySuggestions.first,
                   suggested.path.hasPrefix(root.path + "/"), model.selectedKey == nil, !model.savedKeyAvailable {
                    Button("Use \(suggested.lastPathComponent)") { model.useSSHKey(suggested, accessRoot: root) }.interfaceFont(.caption)
                }
                Toggle("Use an SSH user certificate", isOn: Binding(get: { model.useUserCertificate }, set: model.setCertificateMode))
                    .toggleStyle(.checkbox).disabled(model.jumpHost.enabled)
                    .accessibilityIdentifier("sftpUseCertificate")
                if model.useUserCertificate {
                    HStack {
                        Label(model.certificateName, systemImage: "checkmark.seal")
                            .interfaceFont(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose Certificate…") { model.chooseSSHCertificate(owner: NSApp.keyWindow) }
                            .accessibilityIdentifier("sftpChooseCertificate")
                    }
                    if let root = profiles.authority, let suggested = profiles.selected?.certificateSuggestions.first,
                       suggested.deletingLastPathComponent().path == root.path,
                       model.selectedCertificate == nil, !model.savedCertificateAvailable {
                        Button("Use \(suggested.lastPathComponent)") { model.useSSHCertificate(suggested, directory: root) }
                            .interfaceFont(.caption)
                    }
                    Text("Your company sign-in tool renews the certificate. Remember its folder once; Traverse reads the latest certificate each time you connect.")
                        .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.selectedCertificateURL != nil, model.certificateDirectory == nil {
                        Button("Remember Certificate Folder…") {
                            model.chooseCertificateDirectory(owner: NSApp.keyWindow)
                        }.interfaceFont(.caption)
                    }
                    if !model.certificateNotice.isEmpty {
                        Text(model.certificateNotice).interfaceFont(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Passphrase") {
                    SecureField("If the key is encrypted", text: $model.keyPassphrase).textContentType(.password)
                }
                Text("Key files are used after server verification. Passphrases stay in this connection only.")
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.serverPromptsAvailable {
                    Toggle("Allow an additional verification step", isOn: $model.extraServerPrompts).toggleStyle(.checkbox)
                        .accessibilityLabel("Allow an additional verification step").accessibilityIdentifier("sftpAdditionalVerification")
                        .help("Use this when the server asks for a code or other response after accepting your private key.")
                }
            } else if model.sftpAuthentication == .serverPrompts {
                Text("Your verified server will ask for the responses it needs, such as a password or one-time code. Responses aren’t saved.")
                    .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}
