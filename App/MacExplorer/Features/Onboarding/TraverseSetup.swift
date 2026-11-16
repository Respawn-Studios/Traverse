import AppKit
import Combine
import ExplorerCore
import SwiftUI

/// Explicit, optional setup. Permission state comes only from a chosen folder;
/// this model never probes private files or reads the system privacy database.
@MainActor
final class TraverseSetupModel: ObservableObject {
    static let titles = ["Choose your look", "Make navigation yours", "Find things your way", "Choose your access", "Stay up to date"]
    @Published var page = 0 {
        didSet {
            if !isClosed, Self.titles.indices.contains(page), oldValue != page {
                ApplicationDiagnostics.shared.event(.onboarding, .presenting, trace: sessionTrace, count: UInt64(page + 1), context: .init(.setupPage))
            }
        }
    }
    @Published var rememberAccess = true
    @Published var choosing = false
    @Published var finishing = false
    @Published var showsTourAfterSetup = false
    @Published var showsAdditionalAccess = false
    @Published var rememberUpdateAccess = true
    @Published var message = ""
    @Published var chosenFolder: String?
    @Published private(set) var changingStartup = false
    @Published private(set) var isClosed = false
    private let settings: BrowserSettings
    let folderAccess: FolderAccessController
    private weak var workspace: BrowserWorkspaceController?
    private weak var originatingBrowser: BrowserViewController?
    // Restoring a workspace replaces its startup browser. Setup edits shared
    // preferences/access, so it must not depend on that retired pane's lifetime.
    var browser: BrowserViewController? {
        if let workspace, !workspace.isClosing { return workspace.activeBrowser }
        return originatingBrowser
    }
    weak var window: NSWindow?
    private var task: Task<Void, Never>?
    private let sessionTrace = UUID()

    init(browser: BrowserViewController) {
        settings = browser.settings; folderAccess = browser.folderAccess
        workspace = browser.workspace; originatingBrowser = browser
        ApplicationDiagnostics.shared.event(.onboarding, .presenting, trace: sessionTrace, count: 1, context: .init(.setupPage))
    }
    func chooseStartup(_ mode: BrowserStartupMode) {
        guard !isClosed, task == nil, !changingStartup else { return }
        let settings = settings
        let trace = ApplicationDiagnostics.shared.workflow(.onboarding, context: .init(.setupStartup))
        changingStartup = true; message = ""
        task = Task { [weak self] in
            trace.event(.committing, context: .init(.setupStartup))
            do {
                try await settings.chooseStartup(mode, profile: settings.startupProfileID)
                trace.event(.completed, context: .init(.setupStartup))
            } catch {
                trace.event(error is CancellationError ? .cancelled : .failed, context: .init(.setupStartup), error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
                self?.message = "Your startup choice could not be saved. Please try again."
            }
            self?.changingStartup = false; self?.task = nil
        }
    }
    func chooseFolder(initialDirectory: URL? = nil) {
        guard !isClosed else { return }
        guard task == nil else { message = "Your previous setup choice is still finishing. Please try again."; return }
        guard let window else { message = "Close and reopen setup to choose a folder."; return }
        choosing = true; message = "Opening the folder selection window…"
        let remember = rememberAccess, folderAccess = folderAccess
        task = Task { [weak self] in
            let choice = await folderAccess.chooseFolder(in: window, initialDirectory: initialDirectory ?? BrowsingHome.url, remember: remember,
                purpose: .setup)
            guard let self else { return }
            defer { self.task = nil; self.choosing = false }
            guard !Task.isCancelled else { return }
            guard let choice else { self.message = "No folder selected. You can choose one later."; return }
            self.chosenFolder = choice.selection.url.lastPathComponent.isEmpty ? "Macintosh HD" : choice.selection.url.lastPathComponent
            switch choice.remembering {
            case .saved: self.message = "Folder selected · remembered on this Mac."
            case .failed: self.message = "Folder selected for this session. Traverse couldn’t remember it for next time."
            case .notRequested:
                self.message = folderAccess.locations.contains { $0.id == choice.selection.id && $0.isRemembered }
                    ? "This location is already remembered on this Mac."
                    : "Folder selected · this session only."
            }
        }
    }
    func finish() {
        guard !isClosed else { return }
        guard task == nil else { message = "Your previous setup choice is still finishing. Please try again."; return }
        let settings = settings
        let trace = ApplicationDiagnostics.shared.workflow(.onboarding, context: .init(.setupFinish))
        finishing = true; message = "Saving your choices…"
        task = Task { [weak self] in
            do {
                trace.event(.committing, context: .init(.setupFinish))
                try await settings.completeInitialSetup()
                // The acknowledged save is independent of whether this page
                // has since closed. Do not misreport a committed choice as lost.
                trace.event(.completed, context: .init(.setupFinish))
                guard let self, !Task.isCancelled else { return }
                let showTour = self.showsTourAfterSetup
                let browser = self.browser
                self.task = nil; self.finishing = false; self.window?.close()
                if let browser {
                    await browser.refreshRememberedFolderReferences()
                    if showTour { TraverseTourController.shared.show(from: browser) }
                }
            } catch {
                trace.event(error is CancellationError ? .cancelled : .failed, context: .init(.setupFinish), error: DiagnosticErrors.project(error), causes: DiagnosticErrors.causes(error))
                self?.message = "Setup could not be saved. Your existing settings were preserved; you can retry."
                self?.finishing = false; self?.task = nil
            }
        }
    }
    func close() {
        guard !isClosed else { return }
        ApplicationDiagnostics.shared.event(.onboarding, .finished, trace: sessionTrace,
            context: .init(.setupWindow, flags: task == nil ? [] : [.cancellationRequested]))
        isClosed = true
        task?.cancel(); task = nil
        if choosing { folderAccess.invalidatePendingRequests() }
        choosing = false
    }
}

@MainActor
final class TraverseSetupController: NSWindowController, NSWindowDelegate {
    static let shared = TraverseSetupController()
    private(set) var model: TraverseSetupModel?
    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { nil }
    func show(from browser: BrowserViewController) {
        if let window, window.isVisible, model?.isClosed == false {
            window.makeKeyAndOrderFront(nil); return
        }
        let model = TraverseSetupModel(browser: browser)
        let content = TraverseSetupView(settings: browser.settings, model: model)
        let window = ToolWindowChrome.makeWindow(title: "Welcome to Traverse",
            size: .init(width: 640, height: 590), minimumSize: .zero)
        let host = InterfaceHostingController(rootView: content)
        host.sizingOptions = []
        host.view.frame = .init(x: 0, y: 0, width: 640, height: 590)
        window.contentViewController = host
        ToolWindowChrome.install(in: window, settings: browser.settings)
        window.setContentSize(.init(width: 640, height: 590))
        window.contentMinSize = .init(width: 600, height: 520)
        window.delegate = self; self.window = window; self.model = model; model.window = window
        ToolWindowChrome.position(window, relativeTo: browser.view.window)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        // Welcome is a fresh session, not a retained settings window. Retiring
        // its hosting hierarchy also retires its old accessible button actions.
        // An old window's late notification must not cancel a newer session.
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model?.close()
        model?.window = nil
        model = nil
        window = nil
        // NSWindowController retains/tracks its content controller independently
        // of window. Otherwise assigning the next window can reinstall this
        // completed session's hosting controller over its freshly built page.
        contentViewController = nil
        // AppKit can retain a closed, non-released window. Its hosting view
        // must not keep an old setup session/action graph alive. Let close
        // complete before detaching that obsolete hierarchy.
        Task { @MainActor in
            await Task.yield()
            closing.orderOut(nil)
            closing.contentViewController = nil
            closing.contentView = nil
        }
    }
}

extension NSRect {
    func clamped(to area: NSRect) -> NSRect {
        let width = min(width, area.width), height = min(height, area.height)
        return .init(x: min(max(minX, area.minX), max(area.minX, area.maxX - width)),
              y: min(max(minY, area.minY), max(area.minY, area.maxY - height)), width: width, height: height)
    }
}

struct TraverseSetupView: View {
    @ObservedObject var settings: BrowserSettings
    @ObservedObject var model: TraverseSetupModel
    @ObservedObject private var updates = ApplicationUpdates.shared
    @State private var invitation = ""
    private var lastPage: Int { TraverseSetupModel.titles.count - 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: "folder.badge.gearshape").interfaceFont(.system(size: 34))
                    .foregroundStyle(Color(red: 0.55, green: 0.59, blue: 0.76)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(TraverseSetupModel.titles[model.page]).interfaceFont(.title2.bold())
                    Text("A few choices to help you feel at home.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.page + 1) of \(lastPage + 1)").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.page == 0 { appearance }
                    else if model.page == 1 { navigation }
                    else if model.page == 2 { search }
                    else if model.page == 3 { access }
                    else { updateChoices }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }.toolPageEntrance(model.page, enabled: settings.motion.allows(.pages), mode: settings.motion.mode)
                .disabled(model.choosing || model.finishing || model.changingStartup)
            if !model.message.isEmpty {
                Text(model.message).interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup-status")
            }
            Divider()
            HStack {
                if model.page > 0 { Button("Back") { model.page -= 1; model.message = "" } }
                if model.page < lastPage { Button("Skip Setup") { model.finish() } }
                Spacer()
                Text("Change these anytime in Settings.").interfaceFont(.caption).foregroundStyle(.secondary)
                if model.page < lastPage {
                    Button("Continue") { model.page += 1; model.message = "" }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.finishing ? "Saving…" : "Start Browsing") { model.finish() }.keyboardShortcut(.defaultAction)
                }
            }.disabled(model.choosing || model.finishing || model.changingStartup)
        }.padding(24).frame(minWidth: 600, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity, alignment: .topLeading)
            .disabled(model.isClosed)
            #if DEBUG
            .background(RenderedToolSession(model: model).allowsHitTesting(false))
            #endif
            .onChange(of: model.page) { _, _ in clearInvitation() }
            .onDisappear { clearInvitation() }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Appearance", selection: $settings.navigationStyle) {
                Text("Liquid Glass").tag(NavigationStyle.glass)
                Text("Solid").tag(NavigationStyle.solid)
            }.pickerStyle(.segmented)
            Toggle("Extend glass into the file content area", isOn: $settings.glassFileContent)
                .disabled(settings.navigationStyle != .glass)
            Text("Glass follows your wallpaper and system accessibility settings. Solid keeps a quieter background.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
            Picker("Motion", selection: $settings.motion.mode) {
                ForEach(BrowserMotionMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("Choose how much motion you see. Your Mac’s Reduce Motion setting always takes priority.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
            InterfaceSizePicker(settings: settings)
        }.accessibilityIdentifier("setup-appearance")
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When Traverse opens").interfaceFont(.headline)
            Picker("Start with", selection: Binding(get: { settings.startupMode }, set: model.chooseStartup)) {
                Text("Last session").tag(BrowserStartupMode.lastSession)
                Text("This Mac").tag(BrowserStartupMode.computer)
                if settings.startupProfileID != nil { Text("Saved profile").tag(BrowserStartupMode.profile) }
            }.pickerStyle(.segmented).disabled(model.changingStartup)
                .accessibilityIdentifier("setup-startup")
            Text(AppFeatureAvailability.policy.edition == .directPublic
                ? "Last session remembers this edition’s tabs, panes and locations. Saved servers reopen disconnected. macOS may still restrict some folders."
                : "Last session remembers tabs, panes and their locations on this Mac. Saved servers reopen disconnected. This Mac gives you a fresh start. Folder locations still need access.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            Picker("New tabs open", selection: $settings.newTabDestination) {
                ForEach(BrowserNewTabDestination.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Text("Familiar navigation").interfaceFont(.headline)
            Picker("Keyboard and file behavior", selection: $settings.keyboardProfile) {
                Text("Explorer").tag(KeyboardProfile.explorer)
                Text("Mac").tag(KeyboardProfile.mac)
                if settings.keyboardProfile == .custom { Text("Your custom choices").tag(KeyboardProfile.custom) }
            }.pickerStyle(.segmented)
            Text("Explorer uses Return to open files and familiar Cut/Move actions. Mac follows Finder-style keys. Customize shortcuts later in Settings.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
            Toggle("Show the address bar at the bottom", isOn: $settings.showsPathBar)
            Toggle("Show Open Terminal in the navigation bar", isOn: $settings.showsTerminalButton)
            Toggle("Show Eject buttons beside external drives", isOn: $settings.showsSidebarEject)
            Text("Keeps more room for your files by combining navigation and Search with your tabs.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
        }.accessibilityIdentifier("setup-navigation")
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search defaults").interfaceFont(.headline)
            Picker("Look in", selection: $settings.defaultSearchScope) {
                ForEach(BrowserDefaultSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.accessibilityIdentifier("setup-search-scope")
            Picker("Search sources", selection: $settings.privateNamesSources) {
                ForEach(PrivateNameSources.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text("These choices apply to new folders and tabs. This Mac uses your Mac’s filename index. Searches start when you press Return; file contents aren’t read.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Address suggestions").interfaceFont(.headline)
            Toggle("Suggest saved folder names", isOn: $settings.privateNamesAddressSuggestions)
            Toggle("Improve suggestions using folder visits", isOn: $settings.ranksAddressVisits)
                .accessibilityIdentifier("setup-folder-visits")
            Text("Optional visit history remembers folder locations and visit counts only on this Mac, for up to \(settings.addressVisitDays) days. Turn it off to clear saved visits. Manage the limits in Settings.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("setup-search")
    }
    private var access: some View {
        VStack(alignment: .leading, spacing: 13) {
            if AppFeatureAvailability.policy.edition == .directPublic {
                Text("This Direct Edition starts with separate history and saved locations. Earlier Traverse data stays in its previous location; finish pending Undo in that edition before switching. Saved passwords and folder references do not transfer automatically.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-direct-history-boundary")
            }
            if TraverseAccessPolicy.requiresFolderSelection {
                permission("Choose folders or whole drives", icon: "externaldrive", detail:
                    "Choose each drive you want to use below, or start with Home. The selection window is provided by macOS to allow access; browsing afterward stays in Traverse. Nothing is scanned or changed during setup.")
            } else {
                permission("Open folders with your Mac account", icon: "externaldrive", detail:
                    "Traverse uses the access your account already has. macOS privacy controls and folder permissions may still ask or deny access. Choose a folder here only if you want it in your saved locations.")
            }
            Toggle(TraverseAccessPolicy.requiresFolderSelection ? "Remember selected access on this Mac" : "Remember this location on this Mac", isOn: $model.rememberAccess)
                .disabled(!model.folderAccess.canRememberFolders || model.choosing)
            Text("Keep this choice for next time. Turn this off to use a new selection only until you quit. Manage saved locations in Settings.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.choosing ? "Choosing…" : "Choose a Folder or Drive…") { model.chooseFolder() }
                    .disabled(model.choosing || model.finishing).accessibilityIdentifier("setup-choose-access")
            }
            if TraverseAccessPolicy.requiresFolderSelection, let browser = model.browser, !browser.volumes.isEmpty {
                FolderAccessDriveChoicesView(access: model.folderAccess, drives: browser.volumes) {
                    model.chooseFolder(initialDirectory: $0)
                }.disabled(model.choosing || model.finishing)
            }
            FolderAccessLocationsView(access: model.folderAccess)
            Group {
                let access = model.folderAccess
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(settings.motion.allows(.pages)
                            ? .easeInOut(duration: settings.motion.mode == .reduced ? 0.12 : 0.22) : nil) {
                            model.showsAdditionalAccess.toggle()
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(model.showsAdditionalAccess ? 90 : 0))
                                .accessibilityHidden(true)
                            Text("More access options").interfaceFont(.headline)
                            Spacer()
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(model.showsAdditionalAccess ? "Expanded" : "Collapsed")
                        .accessibilityIdentifier("setup-more-access")
                    if model.showsAdditionalAccess {
                        TraversePermissionChecklist(access: access, showConnections: {
                            model.browser?.showSMBConnections(nil)
                        }, motion: settings.motion).transition(.opacity)
                    }
                }
            }
            Text("You can start browsing now and choose locations when you need them.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("setup-access")
    }
    private var updateChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            if updates.directUpdatesAvailable {
                if updates.requiresInvitation {
                    Toggle("Check for updates automatically", isOn: $settings.automaticUpdateChecks)
                        .accessibilityIdentifier("setup-update-checks")
                } else {
                    Toggle("Check for updates automatically", isOn: $settings.publicAutomaticUpdateChecks)
                        .accessibilityIdentifier("setup-update-checks")
                    Text("Optional and off by default. No invitation is needed; you choose when to download and install.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Text("When enabled, Traverse checks when you open it and about every six hours while running. You choose when to download and install; file work must finish before restarting.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                if updates.requiresInvitation && updates.hasInvitation {
                    Label("Beta update access is ready", systemImage: "checkmark.circle")
                } else if updates.requiresInvitation {
                    Text("Private beta invitation").interfaceFont(.headline)
                    Text("Use the password supplied with your beta download. You can also set this up later in Help → Updates.")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                    SecureField("Invitation password", text: $invitation)
                        .textFieldStyle(ToolTextEntryStyle()).privacySensitive().disabled(updates.working)
                        .accessibilityIdentifier("setup-update-invitation")
                        .onSubmit { submitInvitation() }
                    Toggle("Remember beta access securely on this Mac", isOn: $model.rememberUpdateAccess)
                        .disabled(updates.working).accessibilityIdentifier("setup-remember-invitation")
                    Text("Saved passwords use your Mac’s Keychain. Without saving, enter the invitation again after quitting. macOS may ask you to approve Keychain access.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(updates.working ? "Checking…" : "Enable Beta Updates") { submitInvitation() }
                            .disabled(updates.working || invitation.isEmpty)
                        if updates.working { ProgressView().controlSize(.small) }
                    }
                }
                if !updates.notice.isEmpty { Text(updates.notice).interfaceFont(.callout).foregroundStyle(.secondary) }
                if !updates.credentialNotice.isEmpty { Text(updates.credentialNotice).interfaceFont(.caption).foregroundStyle(.secondary) }
            } else { Text(updates.editionMessage).foregroundStyle(.secondary) }
            Divider()
            Toggle("Keep crash reports locally", isOn: $settings.crashCaptureEnabled)
            Text("Native captures can contain private paths. They stay on this Mac; nothing is sent automatically. Review, hide private details or remove copies in Help → Crash Reports & Feedback. Changing capture applies next launch.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            Toggle("Show me around after setup · three quick hints", isOn: $model.showsTourAfterSetup)
            Text("You can revisit every choice in Settings, and open the tour again from Help.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("setup-updates")
    }
    private func submitInvitation() {
        guard !updates.working, !invitation.isEmpty else { return }
        updates.useInvitation(invitation, remember: model.rememberUpdateAccess, checkImmediately: false)
        clearInvitation()
    }
    private func clearInvitation() {
        invitation = ""
        clearPrivateTextUndo(in: model.window)
    }
    private func permission(_ title: String, icon: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).interfaceFont(.headline)
            Text(detail).interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.help(detail)
    }
}
