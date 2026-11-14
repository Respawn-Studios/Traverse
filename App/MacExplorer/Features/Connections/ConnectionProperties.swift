import AppKit
import Combine
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Concrete existing profile owners. This metadata surface has no Connect,
/// password, key-file, file-operation or generic provider capability.
enum ConnectionMetadataAccess {
    case sftp(SFTPRememberedState)
    case smb(SMBConnectionCoordinator)
}
extension SFTPAuthenticationChoice {
    var metadataSignIn: SFTPRouteSignIn {
        switch self {
        case .password: .password
        case .keyFile: .keyFile
        case .serverPrompts: .serverPrompts
        case .keyFileWithServerPrompts: .keyFileAndServerPrompts
        case .userCertificate(_, _, _, _, _, let prompts): prompts ? .keyFileAndServerPrompts : .keyFile
        }
    }
    var metadataRequiresCertificate: Bool {
        if case .userCertificate = self { true } else { false }
    }
}

@MainActor final class ConnectionPropertiesController: NSObject, NSWindowDelegate {
    private weak var browser: BrowserViewController?
    private let profile: ApplicationSMBConnections
    private let access: ConnectionMetadataAccess?
    private let tabID: UUID, connectionID: UUID
    private var visit: UUID
    private let sftp: SFTPServerDraft?, smb: SMBServerDraft?, route: SFTPRouteDescription?
    private let signIn: SFTPRouteSignIn
    private let requiresCertificate: Bool
    private let transferPreference: SFTPTransferPreference?
    private let initialBookmark: WorkspaceConnectionBookmark?
    private var savedID: UUID?, revision: UInt64?, accepting = true
    private var work: Task<Void, Never>?, sourceClose: BrowserNotificationObservation?
    private var pinObservation: AnyCancellable?
    private var controlsEnabled = false
    private(set) var window: NSWindow?
    let labelField = NSTextField(), directoryField = NSTextField()
    private let notice = NSTextField(wrappingLabelWithString: "Loading saved details…")
    private let saveButton = NSButton(title: "Save Details", target: nil, action: nil)
    private let saveGoButton = NSButton(title: "Save & Go", target: nil, action: nil)
    private let goButton = NSButton(title: "Go", target: nil, action: nil)
    private let pinButton = NSButton(title: "Pin Folder", target: nil, action: nil)
    private let pinNotice = NSTextField(wrappingLabelWithString: "Connection pins are loading…")
    private let currentFolderField = NSTextField(wrappingLabelWithString: "")

    init?(browser: BrowserViewController, profile: ApplicationSMBConnections = .shared,
          access: ConnectionMetadataAccess? = nil) {
        guard !browser.isBrowserSuspended, browser.view.window?.isVisible == true else { return nil }
        let remoteID: UUID, sftpValue: SFTPServerDraft?, smbValue: SMBServerDraft?, routeValue: SFTPRouteDescription?
        switch browser.location {
        case .sftp:
            guard let owner = browser.sftpTabs[browser.activeID], !owner.isClosing else { return nil }
            remoteID = owner.connectionID; sftpValue = owner.presentation; smbValue = nil; routeValue = owner.routeDescription
        case .smb:
            guard let owner = browser.smbTabs[browser.activeID], !owner.isClosing else { return nil }
            remoteID = owner.connectionID; sftpValue = nil; smbValue = owner.presentation; routeValue = nil
        default: return nil
        }
        self.browser = browser; self.profile = profile
        self.access = access ?? profile.connectionMetadataAccess(isSFTP: sftpValue != nil)
        tabID = browser.activeID; connectionID = remoteID; visit = browser.sessionID
        sftp = sftpValue; smb = smbValue; route = routeValue
        signIn = browser.sftpTabs[browser.activeID]?.signIn ?? .password
        requiresCertificate = browser.sftpTabs[browser.activeID]?.requiresUserCertificate ?? false
        transferPreference = browser.sftpTabs[browser.activeID]?.transferPreference
        initialBookmark = browser.currentRemoteBookmark; savedID = initialBookmark?.serverID
        super.init()
        build(relativeTo: browser)
        if let source = browser.view.window {
            sourceClose = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: source) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        let pins = browser.remotePins
        pinObservation = pins.$isReady.combineLatest(pins.$status).sink { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePinAvailability() }
        }
        load()
    }
    private var current: Bool {
        guard accepting, let browser, !browser.isBrowserSuspended, browser.isActiveCommandPane, browser.activeID == tabID,
              browser.sessionID == visit, browser.view.window?.isVisible == true else { return false }
        return browser.sftpTabs[tabID].map { !$0.isClosing && $0.connectionID == connectionID }
            ?? browser.smbTabs[tabID].map { !$0.isClosing && $0.connectionID == connectionID } ?? false
    }
    private func editableText(_ directory: SFTPDefaultDirectory) throws -> String {
        guard let text = directory.editableFieldText else { throw SFTPConnectionInputFailure.component }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPConnectionInputFailure.component }
        return text
    }
    private func build(relativeTo browser: BrowserViewController) {
        let panel = ToolWindowChrome.makeWindow(title: "Connection Properties",
            size: .init(width: 660, height: 610), minimumSize: .init(width: 620, height: 580))
        panel.delegate = self; window = panel
        let heading = NSTextField(labelWithString: "Current Connection")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let endpoint: String
        let account: String
        let security: String
        let initialLabel: String
        let initialDirectory: String
        if let sftp {
            let address: SFTPConnectionAddress = sftp.address
            endpoint = "\(address.serverField):\(address.port)"
            account = sftp.account
            security = "SFTP · Encrypted connection"
            initialLabel = sftp.name
            initialDirectory = (try? SFTPDefaultDirectory(legacy: address).fieldText) ?? "/"
        } else if let smb {
            let address: SMBConnectionAddress = smb.address
            endpoint = "\(address.serverField):\(address.port) / \(address.share.displayName)"
            account = smb.domain.isEmpty ? smb.account : "\(smb.domain) / \(smb.account)"
            security = "SMB · \(smb.security.rawValue)"
            initialLabel = smb.name
            let folder: String = address.startingFolderField
            initialDirectory = folder.isEmpty ? "/" : folder
        } else {
            endpoint = "Captured endpoint unavailable"; account = "Not captured"
            security = "Session metadata only"; initialLabel = browser.location.displayName; initialDirectory = "/"
        }
        labelField.stringValue = initialLabel
        directoryField.stringValue = initialDirectory
        for field in [labelField, directoryField] {
            field.usesSingleLineMode = true; field.cell?.isScrollable = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        labelField.setAccessibilityLabel("Saved connection label"); directoryField.setAccessibilityLabel("Saved starting folder")
        currentFolderField.stringValue = browser.remoteAddressText ?? "Unavailable"
        let startLabel = sftp != nil ? "Start in" : "Start in Share"
        directoryField.placeholderString = sftp != nil ? "Home, ~/folder, or /folder" : "/folder"
        directoryField.toolTip = sftp != nil ? "Use ~ for Home, ~/folder within Home, or /folder on the server." : "Choose a folder within this share."
        let gridRows: [[NSView]] = [
            [NSTextField(labelWithString: "Server"), NSTextField(wrappingLabelWithString: endpoint)],
            [NSTextField(labelWithString: "Account"), NSTextField(wrappingLabelWithString: account)],
            [NSTextField(labelWithString: "Security"), NSTextField(wrappingLabelWithString: security)],
            [NSTextField(labelWithString: "Current folder"), currentFolderField],
            [NSTextField(labelWithString: "Name"), labelField],
            [NSTextField(labelWithString: startLabel), directoryField]]
        let grid: NSGridView = NSGridView(views: gridRows)
        grid.columnSpacing = 18; grid.rowSpacing = 12; grid.column(at: 0).xPlacement = NSGridCell.Placement.trailing
        let help = NSTextField(wrappingLabelWithString: "Save a name and starting folder. Go opens it in this connection. To change the server or sign-in details, use Connect to Server.")
        help.textColor = .secondaryLabelColor; help.font = .systemFont(ofSize: 12)
        notice.textColor = .secondaryLabelColor
        pinNotice.textColor = .secondaryLabelColor; pinNotice.maximumNumberOfLines = 2
        pinNotice.setAccessibilityLabel("Connection pin availability")
        for (button, action) in [(saveButton, #selector(save(_:))), (saveGoButton, #selector(saveAndGo(_:))),
            (goButton, #selector(go(_:))), (pinButton, #selector(pin(_:)))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        let routeButton = NSButton(title: "Save Route in Connect to Server…", target: self, action: #selector(saveRouteInConnect(_:)))
        routeButton.bezelStyle = .rounded; routeButton.isHidden = route == nil || savedID != nil
        let useCurrent = NSButton(title: "Use Current Folder", target: self, action: #selector(useCurrentFolder(_:)))
        useCurrent.bezelStyle = .rounded
        let navigation = NSStackView(views: [useCurrent, goButton, pinButton]); navigation.spacing = 8
        goButton.setAccessibilityLabel("Go in This Connection")
        goButton.toolTip = "Open the entered folder using this connection."
        pinButton.setAccessibilityLabel("Pin Current Folder")
        let actions = NSStackView(views: [routeButton, saveButton, saveGoButton]); actions.spacing = 8
        actions.detachesHiddenViews = true
        let contents: [NSView] = [heading, grid, help, notice, navigation, pinNotice, actions]
        let stack: NSStackView = NSStackView(views: contents)
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
                grid.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor),
                notice.widthAnchor.constraint(equalTo: stack.widthAnchor), pinNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
                directoryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        }
        ToolWindowChrome.install(in: panel, settings: browser.settings)
        ToolWindowChrome.position(panel, relativeTo: browser.view.window)
        panel.makeKeyAndOrderFront(nil); enable(false)
    }
    private func enable(_ value: Bool) {
        controlsEnabled = value
        labelField.isEnabled = value; directoryField.isEnabled = value
        let canSave = value && revision != nil && access != nil && (sftp != nil || smb != nil)
            && !(route != nil && savedID == nil)
        saveButton.isEnabled = canSave; saveGoButton.isEnabled = canSave
        goButton.isEnabled = value
        updatePinAvailability()
    }
    private func updatePinAvailability() {
        guard accepting, let browser else { pinButton.isEnabled = false; return }
        let pins = browser.remotePins
        let sourceCurrent = current && browser.view.window?.attachedSheet == nil
        pinButton.isEnabled = controlsEnabled && work == nil && savedID != nil && revision != nil
            && sourceCurrent && pins.canEdit
        let text: String
        if !controlsEnabled || work != nil { text = "Wait for connection details to finish before pinning." }
        else if !sourceCurrent { text = "The source tab changed. Reopen Connection Properties before pinning." }
        else if savedID == nil { text = "Save Connection Details before pinning this folder." }
        else if revision == nil { text = "Saved details need review. Reopen Connection Properties before pinning." }
        else if !pins.isReady { text = "Connection pins are loading. Pin will be available when loading finishes." }
        else if pins.isSaving { text = "Saving the connection pin. Wait for the save to finish." }
        else if !pins.canEdit { text = "Saved connection pins need review. Their data was preserved." }
        else { text = pins.status.isEmpty ? "" : "Connection pins: " + pins.status }
        pinNotice.stringValue = text; pinNotice.isHidden = text.isEmpty
        let help = text.isEmpty ? "Save a shortcut to this folder on the current connection." : text
        pinButton.toolTip = help
        pinButton.setAccessibilityHelp(help)
    }
    private func start(_ operation: @escaping @MainActor () async -> Void) {
        guard accepting, work == nil else { return }; enable(false)
        work = profile.retainConnectionMetadataWork { [self] in
            await operation(); work = nil; if accepting { enable(true) }
        }
        if work == nil { notice.stringValue = "Connection details are still being saved or closed. Try again shortly."; enable(true) }
    }
    private func load() {
        start { [self] in
            do {
                switch access {
                case .sftp(let state):
                    let snapshot = try await state.inspect(); revision = snapshot?.revision ?? 0
                    if let id = savedID {
                        if route != nil {
                            guard let saved = snapshot?.visibleRoutes.first(where: { $0.id == id }),
                                  initialBookmark?.binding == WorkspaceConnectionBinding.route(saved.details) else { throw SFTPSettingsFailure.staleRevision }
                            labelField.stringValue = saved.details.destination.name; directoryField.stringValue = try editableText(saved.effectiveDefaultDirectory)
                        } else {
                            guard let saved = snapshot?.visibleServers.first(where: { $0.id == id }),
                                  initialBookmark?.binding == WorkspaceConnectionBinding.sftp(saved.details) else { throw SFTPSettingsFailure.staleRevision }
                            labelField.stringValue = saved.details.name; directoryField.stringValue = try editableText(saved.effectiveDefaultDirectory)
                        }
                    }
                case .smb(let state):
                    let snapshot = try await state.inspect(); revision = snapshot?.revision ?? 0
                    if let id = savedID {
                        guard let saved = snapshot?.visibleServers.first(where: { $0.id == id }),
                              initialBookmark?.binding == WorkspaceConnectionBinding.smb(saved.details) else { throw SMBServerStoreFailure.staleRevision }
                        labelField.stringValue = saved.details.name; directoryField.stringValue = saved.details.address.startingFolderField.isEmpty ? "/" : saved.details.address.startingFolderField
                    }
                case nil: revision = nil
                }
                guard accepting else { return }
                notice.stringValue = route != nil && savedID == nil ? "Use Connect to Server to remember this connection and its jump host. You can keep browsing here."
                    : access == nil ? "Saved details are unavailable. You can keep browsing this connection."
                    : savedID == nil ? "Save Details remembers this connection, without saving a password or private key."
                    : "Saved details loaded."
            } catch {
                revision = nil; if accepting { notice.stringValue = "These saved details changed or are unavailable. Reopen Connection Properties to review them." }
            }
        }
    }
    @objc private func save(_ sender: Any?) { save(go: false) }
    @objc private func saveAndGo(_ sender: Any?) { save(go: true) }
    private func save(go: Bool) {
        guard current, let revision else { notice.stringValue = "This connection or its saved details changed. Reopen Connection Properties."; return }
        let label = labelField.stringValue, path = directoryField.stringValue
        start { [self] in
            do {
                let target: WorkspaceConnectionBookmark
                let navigateTo: String
                switch access {
                case .sftp(let state):
                    guard let draft = sftp else { throw SFTPSettingsFailure.invalidRecord }
                    let directory = try SFTPDefaultDirectory(field: path, root: path.hasPrefix("/") ? .server : .home)
                    navigateTo = directory.fieldText
                    let result: SFTPSettingsMutation
                    if let id = savedID {
                        result = try await state.updatePresentation(id: id, route: route != nil, expectedRevision: revision, label: label, directory: directory,
                            expectedBinding: route.map { SFTPConnectionPreferenceBinding(route: $0) } ?? .init(server: draft))
                    } else {
                        guard route == nil else { throw SFTPSettingsFailure.invalidRecord }
                        result = try await state.saveMetadata(.init(name: label, address: draft.address, account: draft.account),
                            expectedRevision: revision, directory: directory, signIn: signIn,
                            transferPreference: transferPreference, requiresCertificate: requiresCertificate)
                    }
                    self.revision = result.snapshot.revision
                    let id = result.routeID ?? result.serverID
                    guard let id else { throw SFTPSettingsFailure.invalidRecord }; savedID = id
                    if let saved = result.snapshot.visibleRoutes.first(where: { $0.id == id }) {
                        target = try .init(kind: .sftpRoute, serverID: id, binding: WorkspaceConnectionBinding.route(saved.details), title: saved.details.destination.name,
                            components: directory.components.map(\.wireUTF8), relativeToHome: directory.root == .home)
                    } else if let saved = result.snapshot.visibleServers.first(where: { $0.id == id }) {
                        target = try .init(kind: .sftpServer, serverID: id, binding: WorkspaceConnectionBinding.sftp(saved.details), title: saved.details.name,
                            components: directory.components.map(\.wireUTF8), relativeToHome: directory.root == .home)
                    } else { throw SFTPSettingsFailure.missing }
                case .smb(let state):
                    guard let draft = smb else { throw SMBServerStoreFailure.invalidRecord }
                    let address = try SMBConnectionAddress(server: draft.address.serverField, port: draft.address.port,
                        share: draft.address.share.displayName, startingFolder: path)
                    navigateTo = address.startingFolderField.isEmpty ? "/" : address.startingFolderField
                    let result: SMBServerMutation
                    if let id = savedID { result = try await state.updatePresentation(id: id, expectedRevision: revision, label: label, components: address.components) }
                    else { result = try await state.saveMetadata(.init(name: label, address: address, account: draft.account, domain: draft.domain, security: draft.security), expectedRevision: revision) }
                    self.revision = result.snapshot.revision
                    guard let id = result.serverID, let saved = result.snapshot.visibleServers.first(where: { $0.id == id }) else { throw SMBServerStoreFailure.invalidRecord }
                    savedID = id
                    target = try .init(kind: .smbServer, serverID: id, binding: WorkspaceConnectionBinding.smb(saved.details), title: saved.details.name, components: address.components.map(\.wireUTF16))
                case nil: throw SFTPSettingsFailure.unavailable
                }
                guard accepting else { return }
                if let browser, let index = browser.tabs.firstIndex(where: { $0.id == tabID }) {
                    if let owner = browser.sftpTabs[tabID], owner.connectionID == connectionID, !owner.isClosing,
                       case .sftp(let value) = browser.tabs[index].location {
                        owner.adoptSavedTarget(target); browser.tabs[index].connectionBookmark = owner.bookmark(for: value)
                    } else if let owner = browser.smbTabs[tabID], owner.connectionID == connectionID, !owner.isClosing,
                              case .smb(let value) = browser.tabs[index].location {
                        owner.adoptSavedTarget(target); browser.tabs[index].connectionBookmark = owner.bookmark(for: value)
                    }
                    browser.recordBrowserSession()
                    browser.savedServerLocations.refresh(); browser.refreshConnectedLocations()
                }
                notice.stringValue = "Connection details saved. Sign-in details are unchanged."
                if go {
                    guard current else { notice.stringValue = "Details saved; the source tab changed, so its folder was not opened."; return }
                    browser?.enterRemoteAddress(navigateTo)
                    if let browser { visit = browser.sessionID; currentFolderField.stringValue = browser.remoteAddressText ?? "Unavailable" }
                }
            } catch {
                if accepting { notice.stringValue = "These changes could not be confirmed. Reopen Connection Properties to review the saved details." }
            }
        }
    }
    @objc private func go(_ sender: Any?) {
        guard current else { notice.stringValue = "The source tab changed. Reopen Properties."; return }
        let text = directoryField.stringValue
        if sftp != nil {
            guard let directory = try? SFTPDefaultDirectory(field: text, root: text.hasPrefix("/") ? .server : .home) else {
                notice.stringValue = "Enter ~ for Home, ~/folder within Home, or /folder on the server."; return
            }
            browser?.enterRemoteAddress(directory.fieldText)
        } else { browser?.enterRemoteAddress(text) }
        if let browser { visit = browser.sessionID; currentFolderField.stringValue = browser.remoteAddressText ?? "Unavailable" }
    }
    @objc private func useCurrentFolder(_ sender: Any?) {
        guard current, let text = browser?.remoteAddressText else { return }
        if let browser, case .sftp(let location) = browser.location {
            guard let owner = browser.sftpTabs[tabID],
                  let editable = owner.navigationDirectory(location)?.editableFieldText else {
                notice.stringValue = "This folder’s name cannot be entered as text. Pin it to return here."; return
            }
            directoryField.stringValue = editable
            return
        }
        directoryField.stringValue = text
    }
    @objc private func saveRouteInConnect(_ sender: Any?) {
        guard current, let route, let browser else { return }
        profile.presentRouteForSaving(route, in: browser)
    }
    @objc private func pin(_ sender: Any?) {
        updatePinAvailability()
        guard pinButton.isEnabled else { return }
        browser?.pinCurrentConnectionFolder(sender)
        updatePinAvailability()
    }
    func close() { accepting = false; pinObservation = nil; work?.cancel(); window?.close() }
    func closeAndDrain() async { let pending = work; close(); await pending?.value }
    func windowWillClose(_ notification: Notification) { accepting = false; pinObservation = nil; work?.cancel(); sourceClose = nil; window = nil }
    #if DEBUG
    var hasPendingWorkForVerification: Bool { work != nil }
    var sourceCurrentForVerification: Bool { current }
    func saveAndGoForVerification() { save(go: true) }
    var noticeForVerification: String { notice.stringValue }
    var saveAndGoButtonForVerification: NSButton { saveGoButton }
    var pinButtonForVerification: NSButton { pinButton }
    var pinNoticeForVerification: NSTextField { pinNotice }
    var pinObservationActiveForVerification: Bool { pinObservation != nil }
    #endif
}

@MainActor extension BrowserViewController {
    @objc func showCurrentConnectionProperties(_ sender: Any?) {
        guard hasLiveRemoteNavigation, !isBrowserSuspended, view.window?.isVisible == true, view.window?.attachedSheet == nil else { return }
        connectionProperties?.close()
        connectionProperties = ConnectionPropertiesController(browser: self, profile: connectionService)
    }
}
