import AppKit
import ExplorerCore
import Foundation

/// Update-only, private UI state. Never a grant, connection, operation replay,
/// scan result or a change to the user's ordinary launch preference.
struct UpdateWorkspaceResume: Codable, Sendable {
    enum ToolKind: String, Codable, Sendable { case settings, rememberedItems, properties, analysis, help }
    struct Tool: Codable, Sendable {
        let kind: ToolKind
        let frame: [Double]
        var urls: [URL] = []
    }
    let id: UUID
    let sourceBuild: UInt64
    let targetBuild: UInt64
    let created: Date
    let workspace: PaneWorkspaceSnapshot
    let frame: [Double]
    let tools: [Tool]
    func validate() throws {
        guard sourceBuild > 0, targetBuild > sourceBuild, tools.count <= 8 else { throw BrowserSnapshotFile.Failure.invalidDocument }
        try workspace.validate(); try Self.validateFrame(frame)
        guard created.timeIntervalSince1970.isFinite else { throw BrowserSnapshotFile.Failure.invalidDocument }
        for tool in tools {
            try Self.validateFrame(tool.frame)
            guard tool.urls.count <= 16, tool.kind == .properties || tool.urls.isEmpty else { throw BrowserSnapshotFile.Failure.invalidDocument }
            if !tool.urls.isEmpty {
                // Reuse the bounded lexical location contract. These URLs are
                // descriptions only; the normal reader reacquires access.
                let tabs = tool.urls.map { WorkspaceSession.Tab(location: .init(kind: .directory, url: $0)) }
                try WorkspaceSession(tabs: tabs).validate()
            }
        }
    }
    func eligible(build: UInt64, now: Date) -> Bool {
        let age = now.timeIntervalSince(created)
        return build >= targetBuild && age >= -300 && age <= 86_400
    }
    private static func validateFrame(_ frame: [Double]) throws {
        guard frame.count == 4, frame.allSatisfy(\.isFinite), abs(frame[0]) <= 1_000_000, abs(frame[1]) <= 1_000_000,
              (240...20_000).contains(frame[2]), (180...20_000).contains(frame[3]) else { throw BrowserSnapshotFile.Failure.invalidDocument }
    }
    static func coordinates(_ rect: NSRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }
    static func rect(_ frame: [Double]) -> NSRect { .init(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) }
}

/// One serialized, bounded writer. Atomic/durable records reuse the guarded
/// snapshot implementation. An acknowledged empty record replaces consumption;
/// neither startup nor a failure unlinks an unknown/newer document.
final class UpdateWorkspaceResumeStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Traverse.UpdateWorkspaceResume", qos: .utility)
    private let directory: URL?
    private struct Document: Codable {
        var version = 1
        var owner = "traverse-update-workspace"
        var pending: UpdateWorkspaceResume?
    }
    init(directory: URL?) { self.directory = directory }
    private var file: BrowserSnapshotFile? {
        directory.map { BrowserSnapshotFile(directory: $0, name: "update-workspace-v1.json", maximumBytes: 4 << 20, requiresPrivateDurability: true) }
    }
    private func decode(_ data: Data) throws -> Document {
        let value = try JSONDecoder().decode(Document.self, from: data)
        guard value.version == 1, value.owner == "traverse-update-workspace" else { throw BrowserSnapshotFile.Failure.invalidDocument }
        try value.pending?.validate(); return value
    }
    func save(_ record: UpdateWorkspaceResume) async throws {
        try await perform {
            guard let file = self.file else { throw BrowserSnapshotFile.Failure.unsafePath }
            try record.validate()
            let data = try JSONEncoder().encode(Document(pending: record))
            try file.write(data) { _ = try self.decode($0) }
        }
    }
    func read(build: UInt64, now: Date = Date()) async throws -> UpdateWorkspaceResume? {
        try await perform {
            guard let data = try self.file?.read() else { return nil }
            let record = try self.decode(data).pending
            return record?.eligible(build: build, now: now) == true ? record : nil
        }
    }
    func consume(_ id: UUID) async throws {
        try await perform {
            guard let file = self.file, let original = try file.read(), try self.decode(original).pending?.id == id else {
                throw BrowserSnapshotFile.Failure.invalidDocument
            }
            try file.write(JSONEncoder().encode(Document(pending: nil)), replacing: .bytes(original)) { _ = try self.decode($0) }
        }
    }
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) } }
        }
    }
}

@MainActor
extension BrowserWorkspaceController {
    func updateResumeRecord(targetBuild: UInt64, sourceBuild: UInt64) throws -> UpdateWorkspaceResume {
        guard let window = view.window else { throw BrowserSnapshotFile.Failure.invalidDocument }
        var tools: [UpdateWorkspaceResume.Tool] = []
        for tool in NSApplication.shared.windows where tool.isVisible && tool !== window && tools.count < 8 {
            let kind: UpdateWorkspaceResume.ToolKind
            var urls: [URL] = []
            if tool === settingsWindow { kind = .settings }
            else if let properties = tool.windowController as? FilePropertiesWindowController {
                guard properties.namesEditor?.hasChanges != true else { continue }
                kind = .properties; urls = Array(properties.model.urls.prefix(16))
            } else if tool.windowController is PrivateNamesWindowController { kind = .rememberedItems }
            else if tool.windowController is StorageAnalysisWindowController { kind = .analysis }
            else if tool === TraverseHelpController.shared.window { kind = .help }
            else { continue }
            tools.append(.init(kind: kind, frame: UpdateWorkspaceResume.coordinates(tool.frame), urls: urls))
        }
        let value = UpdateWorkspaceResume(id: UUID(), sourceBuild: sourceBuild, targetBuild: targetBuild, created: Date(),
            workspace: try captureSessionSnapshot(syncViewState: true), frame: UpdateWorkspaceResume.coordinates(window.frame), tools: tools)
        try value.validate(); return value
    }
    func restoreUpdateTools(_ record: UpdateWorkspaceResume) {
        for tool in record.tools {
            let window: NSWindow?
            switch tool.kind {
            case .settings: showWorkspaceSettings(); window = settingsWindow
            case .rememberedItems: activeBrowser.privateNames.showLibrary(browser: activeBrowser); window = activeBrowser.privateNames.visibleLibraryWindow
            case .properties:
                guard !tool.urls.isEmpty else { continue }
                activeBrowser.propertiesController.show(urls: tool.urls, relativeTo: view.window)
                window = activeBrowser.propertiesController.window
            case .analysis:
                // A prior scan is not a durable result. Reopen its idle window
                // without restarting traversal or asking for new access.
                ApplicationStorageAnalysis.shared.showAfterUpdate(from: activeBrowser)
                window = ApplicationStorageAnalysis.shared.toolWindow?.window
            case .help: TraverseHelpController.shared.show(.whatsNew, from: activeBrowser); window = TraverseHelpController.shared.window
            }
            if let window, let screen = view.window?.screen ?? NSScreen.main {
                window.setFrame(UpdateWorkspaceResume.rect(tool.frame).clamped(to: screen.visibleFrame), display: true)
            }
        }
        view.window?.makeKeyAndOrderFront(nil)
    }
}
