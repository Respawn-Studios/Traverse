#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import Foundation
import ObjectiveC
import SwiftUI

/// Same-process accessibility only. The bounded walk never requests another
/// application's AX tree and never uses global input simulation.
@MainActor enum FolderCompositionOwnedControls {
    private static func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard String(cString: encoding).hasPrefix("@") else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private static func elements(_ window: NSWindow) -> [NSObject] {
        var visited = Set<ObjectIdentifier>(), count = 0
        func walk(_ raw: Any, depth: Int) -> [NSObject] {
            guard depth < 24, count < 2_048, let object = raw as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            count += 1
            var children = (value(object, "accessibilityChildren") as? [Any] ?? [])
                + (value(object, "accessibilityContents") as? [Any] ?? [])
            if let view = object as? NSView { children += view.subviews }
            if let window = object as? NSWindow, let view = window.contentView { children.append(view) }
            return [object] + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(window, depth: 0)
    }
    private static func named(_ title: String, in window: NSWindow, actionable: Bool = true) -> NSObject? {
        elements(window).first { element in
            if actionable {
                let role = value(element, "accessibilityRole") as? String
                guard role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.checkBox.rawValue else { return false }
            }
            return ["accessibilityLabel", "accessibilityTitle"].contains { value(element, $0) as? String == title }
                || (!actionable && value(element, "accessibilityValue") as? String == title)
        }
    }
    static func frame(_ title: String, in window: NSWindow, actionable: Bool = true) -> NSRect {
        guard let object = named(title, in: window, actionable: actionable) else { return .zero }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard let method = class_getInstanceMethod(type(of: object), selector), method_getNumberOfArguments(method) == 2 else { return .zero }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard String(cString: encoding) == "{CGRect={CGPoint=dd}{CGSize=dd}}" else { return .zero }
        typealias Function = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector)
    }
    // BEGIN native6 readiness
    static func isEnabled(_ title: String, in window: NSWindow) -> Bool {
        guard let object = named(title, in: window) else { return false }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard let method = class_getInstanceMethod(type(of: object), selector), method_getNumberOfArguments(method) == 2 else { return false }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard ["B", "c"].contains(String(cString: encoding)) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector).boolValue
    }
    // END native6 readiness
    static func press(_ title: String, in window: NSWindow) -> Bool {
    // BEGIN native6 readiness
        guard window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
              isEnabled(title, in: window) else { return false }
    // END native6 readiness
        guard let object = named(title, in: window) else { return false }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let method = class_getInstanceMethod(type(of: object), selector), method_getNumberOfArguments(method) == 2 else { return false }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard ["B", "c"].contains(String(cString: encoding)) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector).boolValue
    }
}


#endif

#if DEBUG
import Darwin
import ExplorerCore
import LocalStorage

private enum FolderCompositionFailure: Error { case stage(String) }
@MainActor private final class FolderCompositionTerminationEvents { var count = 0 }

private actor FolderCompositionFakeSystem: FolderDefaultSystem {
    let target: FolderDefaultApplication
    private var selected: FolderDefaultApplication
    private var store: (any FolderDefaultRecoveryStore)?
    private var before = false, after = false, waiter: CheckedContinuation<Void, Never>?
    private(set) var held = false, submissions = 0, pendingWasDurable = true
    init(target: FolderDefaultApplication, previous: FolderDefaultApplication) { self.target = target; selected = previous }
    func bind(_ store: any FolderDefaultRecoveryStore) { self.store = store }
    func hold(before: Bool = false, after: Bool = false) { self.before = before; self.after = after }
    func release() { before = false; after = false; let old = waiter; waiter = nil; held = false; old?.resume() }
    func runningApplication() async throws -> FolderDefaultApplication { target }
    func currentApplication() async throws -> FolderDefaultApplication? { selected }
    private func pause() async { held = true; await withCheckedContinuation { waiter = $0 } }
    func request(_ destination: FolderDefaultApplication, expecting current: FolderDefaultApplication,
                 permit: FolderDefaultRequestPermit) async -> FolderDefaultSystemReply {
        if before { before = false; await pause() }
        do {
            guard let row = try await store?.load(), row.stage == .pending, row.destination.identifies(destination),
                  selected.identifies(current) else { pendingWasDurable = false; return .notSubmitted }
        } catch { pendingWasDurable = false; return .notSubmitted }
        guard permit.beginSubmission() else { return .notSubmitted }
        submissions += 1
        if after { after = false; await pause() }
        selected = destination; return .completed(.returned)
    }
}

/// Generated fake backend only; real Settings roots/sheets/page navigation,
/// app delegate quit methods, activity and private native store are exercised.
@MainActor enum FolderDefaultCompositionVerification {
    private static func need(_ value: Bool, _ stage: String) throws { if !value { throw FolderCompositionFailure.stage(stage) } }
    private static func wait(_ stage: String, _ predicate: @MainActor () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(15)
        while !(await predicate()) { try need(.now < end, stage); try await Task.sleep(for: .milliseconds(20)) }
    }
    private static func rejected(_ action: () throws -> Void) throws {
        do { try action() }
        catch is FolderDefaultFailure { return }
        catch is DevelopmentReviewProfile.Failure { return }
        throw FolderCompositionFailure.stage("identity-refusal-missing")
    }
    private static func identityGroups(_ scope: URL) throws -> [String] {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        try need(FolderDefaultIdentityPolicy.acceptsPackageType("FNDR", identifier: "com.apple.finder", at: finder)
            && !FolderDefaultIdentityPolicy.acceptsPackageType("FNDR", identifier: "com.apple.finder", at: scope.appendingPathComponent("Finder.app"))
            && !FolderDefaultIdentityPolicy.acceptsPackageType("FNDR", identifier: "local.generated.other", at: finder)
            && !FolderDefaultIdentityPolicy.acceptsPackageType("FMWK", identifier: "com.apple.finder", at: finder), "system-finder-package-kind")
        let declaration: [String: Any] = ["MacExplorerPreviewFolderOpening": "public-folder-v1",
            "CFBundleDocumentTypes": [["CFBundleTypeName": "Folder", "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": "Alternate", "LSItemContentTypes": ["public.folder"]]]]
        try need(FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration(declaration), "exact-folder-declaration")
        var shippingDeclaration = declaration; shippingDeclaration.removeValue(forKey: "MacExplorerPreviewFolderOpening")
        try need(FolderDefaultIdentityPolicy.hasFolderDeclaration(shippingDeclaration)
            && !FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration(shippingDeclaration), "shared-declaration-does-not-grant-preview-mutation")
        var urlDeclaration = declaration; urlDeclaration["CFBundleURLTypes"] = [] as [String]
        var genericDeclaration = declaration
        genericDeclaration["CFBundleDocumentTypes"] = [["CFBundleTypeName": "Folder", "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate", "LSItemContentTypes": ["public.directory"]]]
        try need(!FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration([:])
            && !FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration(urlDeclaration)
            && !FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration(genericDeclaration), "foreign-folder-declarations-refused")
        let parent = scope.appendingPathComponent("source", isDirectory: true), id = scope.lastPathComponent
        let production = FolderDefaultApplication(url: parent.appendingPathComponent("Generated.app", isDirectory: true),
            bundleIdentifier: FolderDefaultFeature.shippingBundleIdentifier, name: "Generated")
        try production.validate()
        try need(FolderDefaultIdentityPolicy.acceptsTraverse(production, distribution: true, previewBuild: false), "production-preserved")
        let info: [String: Any] = ["MacExplorerDistributionChannel": DevelopmentReviewProfile.channel,
            "MacExplorerReviewCase": id, "MacExplorerReviewStorage": DevelopmentReviewProfile.Storage.repository.rawValue]
        let parsed = try FolderDefaultIdentityPolicy.previewCase(identifier: DevelopmentReviewProfile.identifier, info: info, applicationParent: parent)
        let preview = FolderDefaultApplication(url: parent.appendingPathComponent("Generated Preview.app", isDirectory: true),
            bundleIdentifier: DevelopmentReviewProfile.identifier, name: "Generated Preview", previewCaseID: parsed)
        try preview.validate()
        try need(parsed == id && FolderDefaultIdentityPolicy.acceptsTraverse(preview, distribution: false, previewBuild: true), "exact-preview-accepted")
        let malformedRows: [[String: Any]] = [[:], ["MacExplorerDistributionChannel": DevelopmentReviewProfile.channel],
            ["MacExplorerDistributionChannel": "foreign", "MacExplorerReviewCase": id],
            ["MacExplorerDistributionChannel": DevelopmentReviewProfile.channel, "MacExplorerReviewCase": "invalid"],
            ["MacExplorerDistributionChannel": DevelopmentReviewProfile.channel, "MacExplorerReviewCase": 1],
            ["MacExplorerDistributionChannel": DevelopmentReviewProfile.channel, "MacExplorerReviewCase": id, "MacExplorerReviewStorage": "unknown"]]
        for malformed in malformedRows {
            try rejected { _ = try FolderDefaultIdentityPolicy.previewCase(identifier: DevelopmentReviewProfile.identifier, info: malformed, applicationParent: parent) }
        }
        let generic = FolderDefaultApplication(url: production.url, bundleIdentifier: "local.macexplorer.development", name: "Generated")
        try need(!FolderDefaultIdentityPolicy.acceptsTraverse(generic, distribution: false, previewBuild: true), "generic-derived-refused")
        try rejected { _ = try FolderDefaultIdentityPolicy.previewCase(identifier: production.bundleIdentifier, info: info, applicationParent: parent) }
        try need(!FolderDefaultIdentityPolicy.acceptsTraverse(preview, distribution: true, previewBuild: true)
            && !FolderDefaultIdentityPolicy.acceptsTraverse(preview, distribution: false, previewBuild: false), "distribution-and-disabled-preview-refuse")
        try need(FolderDefaultIdentityPolicy.previewActivationEligible(preview, distribution: false, previewBuild: true)
            && !FolderDefaultIdentityPolicy.previewActivationEligible(preview, distribution: true, previewBuild: true)
            && !FolderDefaultIdentityPolicy.previewActivationEligible(production, distribution: false, previewBuild: true)
            && !FolderDefaultFeature.permitsSystemChanges, "activation-only-exact-nondistribution-preview-shipping-held")
        let foreign = FolderDefaultApplication(url: preview.url, bundleIdentifier: preview.bundleIdentifier, name: preview.name, previewCaseID: UUID().uuidString)
        try need(!preview.identifies(foreign), "same-path-foreign-profile-refused")
        let prior = FolderDefaultApplication(url: parent.appendingPathComponent("Previous.app", isDirectory: true), bundleIdentifier: "local.generated.previous", name: "Previous")
        let record = FolderDefaultRecoveryRecord(recordID: UUID(), traverse: preview, previous: prior, attemptID: UUID(), direction: .makeTraverse, stage: .pending)
        try record.validate()
        try need(try JSONDecoder().decode(FolderDefaultRecoveryRecord.self, from: JSONEncoder().encode(record)) == record, "preview-case-record-roundtrip")
        let sameFamily = FolderDefaultRecoveryRecord(recordID: UUID(), traverse: preview, previous: foreign, attemptID: UUID(), direction: .makeTraverse, stage: .pending)
        try rejected { try sameFamily.validate() }
        return ["exact-folder-viewer-declaration-and-url-type-refusal", "identity-production", "identity-exact-preview", "identity-foreign-partial-derived-refusal", "identity-distribution-preview-refusal", "identity-record-and-profile-affinity"]
    }
    private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    private static func select(_ page: BrowserSettingsView.Page, in window: NSWindow) throws {
        guard let table = descendants(window.contentView).compactMap({ $0 as? NSTableView }).first(where: { $0.identifier?.rawValue == "settings-navigation" }),
              let row = BrowserSettingsView.Page.ordered.firstIndex(of: page) else { throw FolderCompositionFailure.stage("actual-settings-navigation") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.delegate?.tableViewSelectionDidChange?(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    }
    private static func geometry(_ window: NSWindow) -> [NSRect]? {
        guard window.isVisible, let root = window.contentView,
              let viewport = descendants(root).first(where: { $0.identifier?.rawValue == "tool-page-viewport" }) else { return nil }
        let clip = window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        let rects = [window.frame, clip, root.frame, root.bounds] + ["Make Traverse Preview Default", "Restore Previous", "Refresh"].map { FolderCompositionOwnedControls.frame($0, in: window) }
        guard rects.allSatisfy({ [$0.origin.x,$0.origin.y,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }),
              rects.suffix(3).allSatisfy({ $0.width > 20 && $0.height > 12 && clip.insetBy(dx: -2, dy: -2).contains($0) }) else { return nil }
        return rects
    }
    private static func settled(_ window: NSWindow) async throws {
        var previous: [NSRect]?
        try await wait("actual-general-layout-two-spaced-samples") {
            let current = geometry(window)
            let stable = current != nil && previous == current
            previous = current
            if !stable { try? await Task.sleep(for: .milliseconds(100)) }
            return stable
        }
    }
    private static func press(_ title: String, in window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        try await wait("current-enabled-owned-swiftui-button:" + title) { window.isKeyWindow && FolderCompositionOwnedControls.isEnabled(title, in: window) }
        try need(FolderCompositionOwnedControls.press(title, in: window), "owned-swiftui-button-press:" + title)
    }
    private static func respond(_ title: String, in parent: NSWindow) async throws {
        try await wait("actual-consent-sheet:" + title) { parent.attachedSheet != nil }
        guard let sheet = parent.attachedSheet, sheet.sheetParent === parent else {
            throw FolderCompositionFailure.stage("actual-owned-alert-missing:" + title)
        }
        sheet.makeKeyAndOrderFront(nil)
        func currentButton() -> NSButton? {
            descendants(sheet.contentView).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        try await wait("current-enabled-owned-alert-button:" + title) {
            parent.attachedSheet === sheet && sheet.sheetParent === parent && sheet.isVisible && sheet.isKeyWindow
                && currentButton().map { $0.window === sheet && !$0.isHidden && $0.isEnabled } == true
        }
        guard let control = currentButton(), parent.attachedSheet === sheet, sheet.sheetParent === parent,
              sheet.isVisible, sheet.isKeyWindow, sheet.attachedSheet == nil,
              control.window === sheet, !control.isHidden, control.isEnabled else {
            throw FolderCompositionFailure.stage("owned-alert-button-affinity:" + title)
        }
        // The qualified Native6 path for actual NSAlert controls. SwiftUI card
        // presses still require their exact current AX press to return true.
        control.performClick(nil)
        try await wait("actual-consent-sheet-ended:" + title) { parent.attachedSheet == nil }
    }
    private static func tripwires() throws {
        let query = NSSelectorFromString("URLForApplicationToOpenContentType:")
        let setter = NSSelectorFromString("setDefaultApplicationAtURL:toOpenContentType:completionHandler:")
        guard let q = class_getInstanceMethod(NSWorkspace.self, query), method_getNumberOfArguments(q) == 3,
              let s = class_getInstanceMethod(NSWorkspace.self, setter), method_getNumberOfArguments(s) == 5 else { throw FolderCompositionFailure.stage("native-tripwire-api") }
        let read: @convention(block) (AnyObject, AnyObject) -> AnyObject? = { _, _ in _exit(91) }
        let write: @convention(block) (AnyObject, AnyObject, AnyObject, AnyObject?) -> Void = { _, _, _, _ in _exit(92) }
        method_setImplementation(q, imp_implementationWithBlock(read)); method_setImplementation(s, imp_implementationWithBlock(write))
    }
    static func run() async {
        var windows: [NSWindow] = [], owner: ApplicationFolderDefaults?, readOnlyOwner: ApplicationFolderDefaults?, backend: FolderCompositionFakeSystem?, names: ApplicationPrivateNames?
        var root: URL?
        var checks: [String] = [], failure = "none"
        do {
            let scope = try await Task.detached(priority: .utility) { () throws -> URL in
                guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw FolderCompositionFailure.stage("scope") }
                let root = URL(fileURLWithPath: raw, isDirectory: true)
                // This qualification source is tied to its compiled checkout;
                // it is not a path grant accepted by ordinary app UI.
                let repo = DevelopmentFixturePaths.repository
                guard root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-development", isDirectory: true).path,
                      root.resolvingSymlinksInPath().path == root.path, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else { throw FolderCompositionFailure.stage("scope-location") }
                let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
                let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("folder-default-composition-admission.json"))) as? [String: Any]
                guard marker?["action"] as? String == "folder-default-app-composition", admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C",
                      admission?["liveHandlerQueries"] as? Int == 0, admission?["liveAssociationSetters"] as? Int == 0,
                      admission?["fakeBackendOnly"] as? Bool == true else { throw FolderCompositionFailure.stage("scope-admission") }
                var facts = stat(); guard lstat(root.path, &facts) == 0, facts.st_uid == geteuid(), facts.st_mode & 0o777 == 0o700 else { throw FolderCompositionFailure.stage("owned-scope") }
                return root
            }.value
            root = scope
            // This generic Debug gate injects the generated factory owner. It
            // does not qualify the installed global Shared Preview namespace.
            try need(Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "development"
                && !FolderDefaultFeature.permitsSystemChanges, "exact-generic-debug-fake-app-held")
            try tripwires(); checks += try identityGroups(scope)
            let activity = ApplicationFileActivity.gate
            try need(activity.activeCount == 0, "shared-activity-start")
            let state = scope.appendingPathComponent("state", isDirectory: true)
            let target = FolderDefaultApplication(url: scope.appendingPathComponent("source/Generated Preview.app", isDirectory: true),
                bundleIdentifier: DevelopmentReviewProfile.identifier, name: "Traverse Preview Generated", previewCaseID: scope.lastPathComponent)
            let prior = FolderDefaultApplication(url: scope.appendingPathComponent("source/Generated Previous.app", isDirectory: true), bundleIdentifier: "local.generated.previous", name: "Previous Generated")
            let system = FolderCompositionFakeSystem(target: target, previous: prior); backend = system
            let rootPreparation = try AppStoragePreparation.owner(for: state)
            let service = try ApplicationFolderDefaults.forQualification(system: system, stateDirectory: state, rootPreparation: rootPreparation, activity: activity); owner = service
            guard let store = service.storeForQualification, let coordinator = service.coordinator else { throw FolderCompositionFailure.stage("actual-composition-owner") }
            await system.bind(store)
            let settings = BrowserSettings(persist: false); settings.motion = .init(mode: .full); settings.autoRefreshFolders = false
            settings.appearance = .dark
            InterfacePresentation.shared.bind(settings)
            let nameOwner = ApplicationPrivateNames(directory: nil, settings: settings); names = nameOwner
            for _ in 0..<2 {
                let view = BrowserSettingsView(settings: settings, namesOwner: nameOwner, folderDefaults: service)
                let window = BrowserSettingsWindow.make(view); windows.append(window)
                window.title = "Settings · generated review · folder default"
                window.center(); window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            try await wait("two-settings-one-owner") { service.presentationCountForQualification == 2 && !coordinator.isBusy }
            let leaf = state.appendingPathComponent("folder-opening", isDirectory: true)
            try need(!(await Task.detached { FileManager.default.fileExists(atPath: leaf.path) }.value), "passive-no-state-create")
            for percent in [100,150] { for style in [NavigationStyle.solid,.glass] {
                settings.interfaceSize = .init(percent); settings.navigationStyle = style
                for window in windows { try await settled(window) }
                windows[0].makeKeyAndOrderFront(nil); try await settled(windows[0])
                // Preserve the original view-cache evidence with its honest label.
                let styleName = style == .solid ? "solid" : "glass"
                try await UIVerification.snapshot(windows[0], to: scope.appendingPathComponent("evidence/default-\(percent)-\(styleName).png"))
                // Static, exact current-process window capture. No action, display,
                // audio, permission request or other application is captured.
                _ = try await NativeMotionRecorder.record(window: windows[0], root: scope,
                    label: "default-owned-\(percent)-\(styleName)", sampling: .diagnostic(for: windows[0]), action: {})
            } }
            checks.append("actual-settings-general-100150-solid-glass-geometry")
            checks.append("actual-settings-owned-window-static-dark-100150-solid-glass")
            try await press("Make Traverse Preview Default", in: windows[0]); try await respond("Cancel", in: windows[0])
            try need(!(await Task.detached { FileManager.default.fileExists(atPath: leaf.path) }.value), "cancel-consent-no-state")
            checks.append("actual-sheet-cancel-no-request-or-record")
            await system.hold(before: true)
            try await press("Make Traverse Preview Default", in: windows[0]); try await respond("Make Traverse Preview Default", in: windows[0])
            try await wait("actual-pending-before-submission") { await system.held }
            try select(.appearance, in: windows[0])
            // NativeToolPageHost still retains its outgoing General tree here.
            try need(service.presentationCountForQualification == 1, "synchronous-page-binding-revocation")
            await system.release(); try await wait("revoked-request-actual-drain") { !coordinator.isBusy }
            try need(await system.submissions == 0, "page-leave-refuses-native-entry")
            try select(.general, in: windows[0]); try await wait("fresh-general-token") { service.presentationCountForQualification == 2 && !coordinator.isBusy }
            checks.append("selected-page-before-fade-revokes-waiting-permit")
            await system.hold(after: true)
            try await press("Make Traverse Preview Default", in: windows[1]); try await respond("Make Traverse Preview Default", in: windows[1])
            try await wait("submitted-fake-callback-held") { let held = await system.held; let count = await system.submissions; return held && count == 1 }
            windows[1].close()
            let events = FolderCompositionTerminationEvents()
            let delegate = ApplicationDelegate(folderDefaultsForVerification: service) { events.count += 1 }
            try need(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "quit-defers-submitted-callback")
            try await Task.sleep(for: .milliseconds(100))
            try need(events.count == 0 && activity.activeCount > 0, "no-fake-quit-drain")
            service.resumeAfterCancelledTermination()
            try need(!service.isTerminating && service.presentationCountForQualification == 1, "cancelled-quit-resumes-presentation")
            await system.release(); try await wait("callback-store-old-quit-ended") { !coordinator.isBusy && activity.activeCount == 0 }
            try need(events.count == 0, "cancelled-quit-no-late-termination")
            let made = try await store.load()
            try need(made?.stage == .matched && made?.traverse.identifies(target) == true && made?.previous == prior, "actual-durable-make-after-close")
            windows[1].makeKeyAndOrderFront(nil)
            try await wait("retained-settings-reopen-fresh-token") { service.presentationCountForQualification == 2 && !coordinator.isBusy }
            windows[1].close()
            checks.append("shared-owner-window-close-reopen-and-cancelled-quit")
            try await press("Restore Previous", in: windows[0]); try await respond("Cancel", in: windows[0])
            try need(try await store.load() == made, "cancel-restore-keeps-durable-record")
            await system.hold(after: true)
            try await press("Restore Previous", in: windows[0]); try await respond("Restore Previous", in: windows[0])
            try await wait("restore-actual-callback-held") { let held = await system.held; let count = await system.submissions; return held && count == 2 }
            try need(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "second-quit-defers")
            try await Task.sleep(for: .milliseconds(100)); try need(events.count == 0 && activity.activeCount > 0, "restore-no-early-termination")
            await system.release()
            try await wait("actual-app-quit-event-after-drain") { events.count == 1 && activity.activeCount == 0 && !coordinator.isBusy }
            try need(delegate.applicationShouldTerminate(NSApp) == .terminateNow, "no-browser-termination-ready")
            let restored = try await store.load()
            try need(restored?.stage == .matched && restored?.direction == .restorePrevious && restored?.previous == prior, "restore-durable-exact-previous")
            try need(await system.pendingWasDurable, "all-fake-entries-follow-durable-pending")
            checks.append("actual-delegate-submitted-callback-readback-store-drain")
            // Independently exercise the ordinary no-browser branch, not only
            // the isolated-test fast branch, with the same drained owner.
            service.resumeAfterCancelledTermination()
            let normalEvents = FolderCompositionTerminationEvents()
            let normal = ApplicationDelegate(folderDefaultsForVerification: service, isolated: false) { normalEvents.count += 1 }
            try need(normal.applicationShouldTerminate(NSApp) == .terminateCancel, "ordinary-no-browser-drain-admission")
            try await wait("ordinary-no-browser-drain-event") { normalEvents.count == 1 && activity.activeCount == 0 }
            try need(normal.applicationShouldTerminate(NSApp) == .terminateNow, "ordinary-no-browser-ready")
            checks.append("ordinary-no-browser-quit-drains-before-return-now")
            guard let restored else { throw FolderCompositionFailure.stage("foreign-record-setup-source") }
            let foreignTarget = FolderDefaultApplication(url: target.url, bundleIdentifier: target.bundleIdentifier,
                name: target.name, previewCaseID: UUID().uuidString)
            let foreignRecord = FolderDefaultRecoveryRecord(recordID: UUID(), traverse: foreignTarget, previous: prior,
                attemptID: UUID(), direction: .makeTraverse, stage: .notSubmitted)
            try await store.replace(expected: restored, with: foreignRecord)
            try need(try await store.load() == foreignRecord, "foreign-record-setup-durable")
            service.resumeAfterCancelledTermination()
            try await wait("foreign-profile-record-readonly-refresh") { !coordinator.isBusy }
            let requests = await system.submissions
            try need(coordinator.hasForeignRestoreChoice && !coordinator.canMakeDefault && !coordinator.canRestorePrevious
                && requests == 2, "foreign-preview-profile-no-authority")
            checks.append("actual-foreign-preview-profile-record-refusal")
            let display = try ApplicationFolderDefaults.forQualification(system: system,
                stateDirectory: state, rootPreparation: rootPreparation, activity: activity, permitsChanges: false)
            readOnlyOwner = display
            guard let readOnly = display.coordinator else { throw FolderCompositionFailure.stage("read-only-owner") }
            let view = BrowserSettingsView(settings: settings, namesOwner: nameOwner, folderDefaults: display)
            let window = BrowserSettingsWindow.make(view); windows.append(window)
            window.title = "Settings · generated folder-opening status"
            window.center(); window.makeKeyAndOrderFront(nil)
            try await wait("read-only-status-observed") { display.presentationCountForQualification == 1 && !readOnly.isBusy && readOnly.current != nil }
            let readOnlyRequests = await system.submissions
            try need(!readOnly.permitsChanges && !readOnly.canMakeDefault && !readOnly.canRestorePrevious
                && readOnly.recovery == nil && readOnlyRequests == requests, "read-only-no-mutation-or-recovery-load")
            for percent in [100,150] {
                settings.interfaceSize = .init(percent)
                try await Task.sleep(for: .milliseconds(160))
                try await wait("read-only-refresh-visible") { FolderCompositionOwnedControls.isEnabled("Refresh", in: window) }
                try need(FolderCompositionOwnedControls.frame("Make Traverse Preview Default", in: window) == .zero
                    && FolderCompositionOwnedControls.frame("Restore Previous", in: window) == .zero, "read-only-hides-system-change-controls")
                try await GlassVerification.captureOwnedWindow(window,
                    to: scope.appendingPathComponent("evidence/folder-opening-status-\(percent).png"))
            }
            try need(try await store.load() == foreignRecord, "read-only-preserves-existing-restore-record")
            checks.append("shared-read-only-folder-status-100150-no-setter-or-history-change")
        } catch let FolderCompositionFailure.stage(stage) { failure = stage }
        catch { failure = "unexpected-composition-error" }
        await backend?.release()
        for window in windows { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }; window.close() }
        if let owner { _ = await owner.prepareForTermination() }
        if let readOnlyOwner { _ = await readOnlyOwner.prepareForTermination() }
        await names?.close()
        let drained = (owner?.coordinator?.isBusy != true) && (readOnlyOwner?.coordinator?.isBusy != true)
            && ApplicationFileActivity.gate.activeCount == 0 && windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil }
        let result: [String: Any] = ["passed": failure == "none" && drained, "failureStage": failure, "checks": checks,
            "actualOwnerDrain": drained, "liveHandlerQueries": 0, "liveSetters": 0, "fakeBackendOnly": true,
            "topLevelWindowsCreated": windows.count, "nativeOSAssociationQualified": false, "incomingGrantQualified": false,
            "distributionBinaryExercised": false, "productAdopted": false]
        if let root, let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("evidence/native-folder-default.json"), options: .withoutOverwriting)
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        NSApp.terminate(nil)
    }
}
#endif
