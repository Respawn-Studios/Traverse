import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum WorkspaceNetworkFeature {
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return true
    }
}

/// Shallow panes show one compact invitation rather than a cropped hero.
/// The same content remains scrollable if an outcome or larger text needs it.
@MainActor private final class SavedNetworkCardScroll: NSScrollView {
    weak var symbol: NSView?, heading: NSView?, detail: NSTextField?
    private var compact: Bool?
    override func layout() {
        super.layout()
        let small = contentView.bounds.height < 300 * InterfaceMetrics.scale
        guard compact != small else { return }; compact = small
        symbol?.isHidden = small; heading?.isHidden = small
        detail?.stringValue = small ? "Connect to continue here."
            : "Connect to continue here. Traverse asks only for missing sign-in details."
        documentView?.needsLayout = true
    }
}

enum WorkspaceReconnectFailure: Error {
    case unavailable, changed, stale, closureUncertain
    var message: String {
        switch self {
        case .unavailable: "This saved server is unavailable or was forgotten. Choose a server in Connect to Server, then save the layout again."
        case .changed: "These connection details changed. Restore the saved details or open a new connection, then save the layout again."
        case .stale: "The saved tab changed or closed. The connection was not opened in another tab."
        case .closureUncertain: "The saved tab changed. Connection closure needs attention; its local resources remain reserved."
        }
    }
}

/// One explicit Connect intent bound to the original disconnected visit. It
/// cannot retarget another tab/pane if navigation changes while sign-in awaits.
@MainActor final class WorkspaceReconnectTarget {
    weak var browser: BrowserViewController?
    let tabID: UUID, visitID: UUID, bookmark: WorkspaceConnectionBookmark
    init?(browser: BrowserViewController) {
        guard browser.isRemoteLocation, let bookmark = browser.tabs[browser.activeIndex].connectionBookmark,
              (try? bookmark.validate()) != nil, bookmark.matches(browser.location),
              browser.smbTabs[browser.activeID] == nil, browser.sftpTabs[browser.activeID] == nil else { return nil }
        self.browser = browser; tabID = browser.activeID; visitID = browser.sessionID; self.bookmark = bookmark
    }
    var isCurrent: Bool {
        guard let browser, !browser.isBrowserSuspended, browser.view.window != nil,
              browser.activeID == tabID, browser.sessionID == visitID,
              browser.tabs.contains(where: { $0.id == tabID && $0.connectionBookmark == bookmark && bookmark.matches($0.location) }),
              browser.smbTabs[tabID] == nil, browser.sftpTabs[tabID] == nil else { return false }
        return true
    }
    func validate(_ submission: SMBConnectSubmission, snapshot: SMBServerSnapshot?) throws {
        guard isCurrent else { throw WorkspaceReconnectFailure.stale }
        guard bookmark.kind == .smbServer, submission.editingServer == bookmark.serverID,
              WorkspaceConnectionBinding.smb(try .init(name: submission.name, address: submission.address,
                  account: submission.account, domain: submission.domain, security: submission.security)) == bookmark.binding else {
            throw WorkspaceReconnectFailure.changed
        }
        guard let server = snapshot?.visibleServers.first(where: { $0.id == bookmark.serverID }) else { throw WorkspaceReconnectFailure.unavailable }
        guard WorkspaceConnectionBinding.smb(server.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
    }
    func validate(_ submission: SFTPConnectSubmission, snapshot: SFTPSettingsSnapshot?) throws {
        guard isCurrent else { throw WorkspaceReconnectFailure.stale }
        switch bookmark.kind {
        case .smbServer: throw WorkspaceReconnectFailure.changed
        case .sftpServer:
            guard submission.route == nil, submission.editingServer == bookmark.serverID,
                  WorkspaceConnectionBinding.sftp(submission.draft) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
            guard let server = snapshot?.visibleServers.first(where: { $0.id == bookmark.serverID }) else { throw WorkspaceReconnectFailure.unavailable }
            guard WorkspaceConnectionBinding.sftp(server.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
        case .sftpRoute:
            guard let route = submission.route, submission.editingRoute == bookmark.serverID,
                  WorkspaceConnectionBinding.route(route) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
            guard let saved = snapshot?.visibleRoutes.first(where: { $0.id == bookmark.serverID }) else { throw WorkspaceReconnectFailure.unavailable }
            guard WorkspaceConnectionBinding.route(saved.details) == bookmark.binding else { throw WorkspaceReconnectFailure.changed }
        }
    }
}

@MainActor extension BrowserViewController {
    func refreshCurrentConnectionBookmark() {
        switch location {
        case .smb(let value):
            if let owner = smbTabs[activeID], !owner.isClosing { tabs[activeIndex].connectionBookmark = owner.bookmark(for: value) }
        case .sftp(let value):
            if let owner = sftpTabs[activeID], !owner.isClosing { tabs[activeIndex].connectionBookmark = owner.bookmark(for: value) }
        default: break
        }
    }
    func showSavedNetworkLocation(_ bookmark: WorkspaceConnectionBookmark, in host: NSView, uploadNotice: RemoteClosedTransferNotice? = nil) {
        host.subviews.forEach { $0.removeFromSuperview() }
        let scroll = SavedNetworkCardScroll(frame: host.bounds); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.hasHorizontalScroller = false
        let canvas = NSView(frame: host.bounds); canvas.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = canvas; pin(scroll, inside: host)
        let symbol = NSImageView(image: NSImage(systemSymbolName: "network", accessibilityDescription: nil) ?? NSImage())
        symbol.contentTintColor = .controlAccentColor; symbol.setAccessibilityHidden(true)
        symbol.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        let heading = NSTextField(labelWithString: "Connect when you’re ready")
        InterfaceMetrics.setFont(heading, base: .systemFont(ofSize: 19, weight: .semibold))
        let title = NSTextField(wrappingLabelWithString: bookmark.title)
        InterfaceMetrics.setFont(title, base: .systemFont(ofSize: 14, weight: .medium)); title.alignment = .center
        let names = bookmark.isSFTP ? (try? WorkspaceConnectionBinding.sftpComponents(bookmark).map(\.displayName))
            : (try? WorkspaceConnectionBinding.smbComponents(bookmark).map(\.displayName))
        let pathHint = (bookmark.isSFTP ? bookmark.relativeToHome ? "Home" : "Server" : "Share")
            + (names?.isEmpty == false ? " / " + (names ?? []).joined(separator: " / ") : "")
        let folder = NSTextField(wrappingLabelWithString: pathHint)
        folder.alignment = .center; folder.textColor = .secondaryLabelColor; folder.maximumNumberOfLines = 2
        folder.lineBreakMode = .byTruncatingMiddle; folder.toolTip = pathHint
        InterfaceMetrics.setFont(folder, base: .systemFont(ofSize: 12))
        let detail = NSTextField(wrappingLabelWithString: "Connect to continue here. Traverse asks only for missing sign-in details.")
        detail.alignment = .center; detail.textColor = .secondaryLabelColor
        InterfaceMetrics.setFont(detail, base: .systemFont(ofSize: 13))
        let pending = savedServerLocations.connectingPhase(for: bookmark) != nil
        let connect = NSButton(title: pending ? "Connecting…" : "Connect", target: self, action: #selector(connectSavedNetworkLocation(_:)))
        connect.isEnabled = !pending
        connect.bezelStyle = .rounded; connect.identifier = .init("workspace-connect-saved")
        connect.setAccessibilityLabel("Connect to saved \(bookmark.isSFTP ? "SFTP" : "SMB") location")
        let local = NSButton(title: "This Mac", target: self, action: #selector(goComputer(_:))); local.bezelStyle = .rounded
        let actions = NSStackView(views: [connect, local]); actions.orientation = .horizontal; actions.spacing = 10
        let stack = NSStackView(views: [symbol, heading, title, folder, detail, actions])
        stack.identifier = .init("workspace-network-card")
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 13; stack.detachesHiddenViews = true
        scroll.symbol = symbol; scroll.heading = heading; scroll.detail = detail
        if let uploadNotice {
            let outcome = NSTextField(wrappingLabelWithString: uploadNotice.message)
            outcome.textColor = .secondaryLabelColor; outcome.alignment = .center
            stack.addArrangedSubview(outcome)
            if uploadNotice.showHistory != nil {
                let action = bookmark.isSFTP ? #selector(showClosedSFTPUploadHistory(_:)) : #selector(showSMBUploadOutcomes(_:))
                let history = NSButton(title: bookmark.isSFTP ? "Connection Activity…" : "Upload Outcomes…", target: self, action: action)
                history.bezelStyle = .rounded; history.identifier = .init(bookmark.isSFTP ? "sftp-closed-upload-history" : "smb-closed-upload-history")
                stack.addArrangedSubview(history)
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false; canvas.addSubview(stack)
        heading.lineBreakMode = .byWordWrapping; heading.maximumNumberOfLines = 0; heading.alignment = .center
        // Prefer a readable card width without constraining its scroll viewport.
        // The split controller's trailing edge has a lower native priority;
        // equating card width to viewport width would squeeze the entire pane.
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 460)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = canvas.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor); preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([canvas.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor), preferredHeight,
            stack.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), stack.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(greaterThanOrEqualTo: canvas.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            preferredWidth, heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            folder.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 40), symbol.heightAnchor.constraint(equalToConstant: 40)])
        InterfacePresentation.shared.register(stack)
        updateCanvasTransition()
    }
    func showClosedNetworkLocation(in host: NSView, message: String, notice: RemoteClosedTransferNotice?,
        historyAction: Selector, historyTitle: String, historyIdentifier: String) {
        let field = NSTextField(wrappingLabelWithString: message)
        field.textColor = .secondaryLabelColor; field.alignment = .center
        let stack = NSStackView(views: [field]); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .centerX
        if notice?.showHistory != nil {
            let button = NSButton(title: historyTitle, target: self, action: historyAction)
            button.bezelStyle = .rounded; button.identifier = .init(historyIdentifier); stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: host.centerXAnchor), stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40),
            field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)])
        InterfacePresentation.shared.register(stack)
    }
    func savedNetworkForeground(in host: NSView) -> [NSView] {
        guard let scroll = host.subviews.first as? NSScrollView,
              let stack = scroll.documentView?.subviews.first(where: { $0.identifier?.rawValue == "workspace-network-card" }) as? NSStackView else { return [] }
        return stack.arrangedSubviews
    }
    @objc func connectSavedNetworkLocation(_ sender: Any?) {
        guard let target = WorkspaceReconnectTarget(browser: self), target.isCurrent else { return }
        #if DEBUG
        if let reconnectPresenterForVerification { reconnectPresenterForVerification(target); return }
        #endif
        if startSavedServerConnection(target.bookmark, reconnect: target), let button = sender as? NSButton {
            button.title = "Connecting…"; button.isEnabled = false
        }
    }
}
