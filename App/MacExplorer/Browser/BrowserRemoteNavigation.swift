import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

typealias BrowserAddressEditingContext = BreadcrumbNavigationContext

/// Concrete remote paths remain on their owning authenticated session. This
/// route never opens Connect, constructs a local URL or resolves credentials.
@MainActor extension BrowserViewController {
    var hasLiveRemoteNavigation: Bool {
        if isSFTPLocation { return sftpTabs[activeID]?.isClosing == false }
        if isSMBLocation { return smbTabs[activeID]?.isClosing == false }
        return false
    }
    var remoteAddressText: String? {
        switch location {
        case .sftp(let value):
            guard let text = sftpTabs[activeID]?.navigationDirectory(value)?.editableFieldText,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return text
        case .smb(let value):
            guard let components = smbTabs[activeID]?.navigationComponents(value) else { return nil }
            return "/" + components.map(\.displayName).joined(separator: "/")
        default: return nil
        }
    }
    var remoteLoadedQuery: String {
        if isSFTPLocation { return sftpTabs[activeID]?.loadedNameQuery ?? "" }
        if isSMBLocation { return smbTabs[activeID]?.loadedNameQuery ?? "" }
        return ""
    }
    func setRemoteLoadedQuery(_ value: String) {
        guard hasLiveRemoteNavigation, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            filterField.stringValue = remoteLoadedQuery
            status.stringValue = "Use a shorter name query without control characters."; return
        }
        if isSFTPLocation { sftpTabs[activeID]?.setLoadedNameQuery(value) }
        else if isSMBLocation { smbTabs[activeID]?.setLoadedNameQuery(value) }
        folderFilter.synchronize()
    }
    func focusRemoteAddress() {
        guard !isBrowserSuspended, isActiveCommandPane, view.window?.attachedSheet == nil,
              let window = view.window, window.isVisible, hasLiveRemoteNavigation, let text = remoteAddressText,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            status.stringValue = "This connection or folder cannot be edited here. Use its breadcrumbs or Connect explicitly."; return
        }
        folderFilter.dismiss(); addressCompletion.cancel()
        addressEditingContext = .init(pane: paneID, tab: activeID, visit: sessionID, window: ObjectIdentifier(window))
        pathField.stringValue = text; pathControl.isHidden = true; pathField.isHidden = false
        pathField.toolTip = isSFTPLocation ? "Current connection: /folder for server root, ~/folder for account Home. Return opens; Escape cancels."
            : "Current share: /folder. Return opens; Escape cancels."
        (pathField.superview as? AddressSurfaceView)?.setEditing(true)
        focusLocationField()
    }
    func enterRemoteAddress(_ text: String, usingEditor: Bool = false) {
        guard text.utf8.count <= 65536 else { status.stringValue = "This remote address is too long."; return }
        guard !isBrowserSuspended, isActiveCommandPane, let window = view.window, window.isVisible,
              window.attachedSheet == nil, hasLiveRemoteNavigation else { status.stringValue = "Connection closed or unavailable here. Connect explicitly to continue."; return }
        if usingEditor {
            guard addressEditingContext == .init(pane: paneID, tab: activeID, visit: sessionID, window: ObjectIdentifier(window)) else {
                status.stringValue = "The source tab changed. Open its address again before navigating."; return
            }
        }
        do {
            switch location {
            case .sftp:
                guard let owner = sftpTabs[activeID] else { return }
                let directory: SFTPDefaultDirectory
                if text.lowercased().hasPrefix("sftp://") {
                    let value = try SFTPConnectionAddress(text)
                    guard value.host == owner.address.host, value.port == owner.address.port,
                          value.scopeID == owner.address.scopeID else { throw SFTPConnectionInputFailure.address }
                    directory = try .init(legacy: value)
                } else {
                    directory = try .init(field: text, root: text.hasPrefix("/") ? .server : .home)
                }
                let target = try owner.directoryLocation(components: directory.components, relativeToHome: directory.root == .home)
                navigate(to: .sftp(target))
            case .smb:
                guard let owner = smbTabs[activeID],
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw SMBDirectoryFailure.invalidInput
                }
                let parts: [SMBRemoteName]
                if text.lowercased().hasPrefix("smb://") {
                    guard let original = owner.presentation?.address else { throw SMBDirectoryFailure.invalidInput }
                    let requested = try SMBConnectionAddress(text)
                    guard requested.host == original.host, requested.port == original.port, requested.scopeID == original.scopeID,
                          requested.share.wireUTF16 == original.share.wireUTF16 else { throw SMBDirectoryFailure.invalidInput }
                    parts = requested.components
                } else {
                    guard text.hasPrefix("/"), text.utf8.count <= 8192 else { throw SMBDirectoryFailure.invalidInput }
                    let suffix = text.dropFirst()
                    if suffix.isEmpty { parts = [] }
                    else { parts = try suffix.split(separator: "/", omittingEmptySubsequences: false).map { try SMBRemoteName(String($0)) } }
                }
                navigate(to: .smb(try owner.directoryLocation(components: parts)))
            default: return
            }
            cancelLocationEditing(); focusBrowserContent()
        } catch {
            status.stringValue = isSFTPLocation
                ? "Enter /folder or ~/folder on this connection. A different server requires Connect to Server. Names stay exact; . and .. are unavailable."
                : "Enter /folder within this share. A different server or share requires Connect to Server."
        }
    }
    @objc func selectAllLoadedRemoteItems(_ sender: Any?) {
        if isSFTPLocation { sftpTabs[activeID]?.rows.selectAllLoaded() }
        else if isSMBLocation { smbTabs[activeID]?.rows.selectAllLoaded() }
    }
}
