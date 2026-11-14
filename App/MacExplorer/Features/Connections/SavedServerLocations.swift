import Combine
import ExplorerCore
import Foundation
@_spi(Qualification) import LocalStorage

/// A bounded read-only view of this profile's saved connection settings. This
/// owner never activates the transfer workspace, opens a password or connects.
@MainActor final class SavedServerLocations: ObservableObject {
    struct Snapshot: Equatable {
        var locations: [WorkspaceConnectionBookmark] = []
        var smbChoices: [SMBConnectServerChoice] = []
        var sftpChoices: [SFTPConnectServerChoice] = []
        var unavailableProtocols: Set<String> = []
        var notice: String {
            guard !unavailableProtocols.isEmpty else { return "" }
            return "Saved " + unavailableProtocols.sorted().joined(separator: " and ")
                + " details need review. Existing data is preserved."
        }
    }
    private final class Weak {
        weak var value: SavedServerLocations?
        init(_ value: SavedServerLocations) { self.value = value }
    }
    private static var owners: [String: Weak] = [:]
    static func controller(directory: URL?) -> SavedServerLocations {
        guard let directory else { return .init(directory: nil) }
        owners = owners.filter { $0.value.value != nil }
        let key = directory.standardizedFileURL.path
        if let owner = owners[key]?.value { return owner }
        let owner = SavedServerLocations(directory: directory); owners[key] = Weak(owner); return owner
    }
    static func refreshExisting(directory: URL) {
        owners[directory.standardizedFileURL.path]?.value?.refresh()
    }

    @Published private(set) var snapshot = Snapshot()
    // Transient presentation only. An explicit user action owns the actual
    // connection; cold discovery neither connects nor reads credentials.
    @Published private(set) var connectionProgress: [WorkspaceConnectionBookmark: String] = [:]
    func connectingPhase(for target: WorkspaceConnectionBookmark) -> String? {
        connectionProgress.first { key, _ in
            key.kind == target.kind && key.serverID == target.serverID && key.binding == target.binding
        }?.value
    }
    func beginConnecting(_ target: WorkspaceConnectionBookmark) -> Bool {
        // Presentation only. Restored tabs can carry a different folder from
        // the saved default; the concrete coordinator revalidates their target.
        guard connectingPhase(for: target) == nil,
              connectionProgress.count < 8 else { return false }
        connectionProgress[target] = "Connecting…"
        return true
    }
    func updateConnecting(_ target: WorkspaceConnectionBookmark, phase: String) {
        guard let current = connectionProgress[target], current != phase else { return }
        connectionProgress[target] = phase
    }
    func finishConnecting(_ target: WorkspaceConnectionBookmark) { connectionProgress[target] = nil }
    private let smb: SMBSavedServerStore?, sftp: SFTPSettingsStore?
    private(set) var work: Task<Void, Never>?
    private var loaded = false, refreshAgain = false
    init(directory: URL?) {
        smb = directory.map { SMBSavedServerStore(directory: $0.appendingPathComponent("smb-servers")) }
        sftp = directory.map { SFTPSettingsStore(directory: $0.appendingPathComponent("sftp-servers")) }
    }
    func restoreIfNeeded() { if !loaded { refresh() } }
    func refresh() {
        guard work == nil else { refreshAgain = true; return }
        loaded = true
        work = Task { [weak self, smb, sftp] in
            async let smbSnapshot = smb?.inspect()
            async let sftpSnapshot = sftp?.inspect()
            var next = Snapshot()
            do {
                let value = try await smbSnapshot
                next.locations += Self.locations(value)
                next.smbChoices = ApplicationSMBConnections.choices(value)
            }
            catch {
                next.unavailableProtocols.insert("SMB")
                ApplicationDiagnostics.shared.event(.connect, .failed, error: DiagnosticErrors.project(error), context: .init(.savedServersRead))
            }
            do {
                let value = try await sftpSnapshot
                next.locations += Self.locations(value); next.sftpChoices = SFTPConnectSavedChoices.values(value)
            }
            catch {
                next.unavailableProtocols.insert("SFTP")
                ApplicationDiagnostics.shared.event(.connect, .failed, error: DiagnosticErrors.project(error), context: .init(.savedServersRead))
            }
            guard let self else { return }
            snapshot = next; work = nil
            if refreshAgain { refreshAgain = false; refresh() }
        }
    }
    private static func locations(_ snapshot: SMBServerSnapshot?) -> [WorkspaceConnectionBookmark] {
        snapshot?.visibleServers.compactMap { server in
            try? .init(kind: .smbServer, serverID: server.id, binding: WorkspaceConnectionBinding.smb(server.details),
                title: server.details.name, components: server.details.address.components.map(\.wireUTF16))
        } ?? []
    }
    private static func locations(_ snapshot: SFTPSettingsSnapshot?) -> [WorkspaceConnectionBookmark] {
        SFTPConnectSavedChoices.values(snapshot).compactMap { server in
            guard let directory = server.defaultDirectory else { return nil }
            return try? .init(kind: server.route == nil ? .sftpServer : .sftpRoute, serverID: server.id,
                binding: server.route.map { WorkspaceConnectionBinding.route($0.details) }
                    ?? WorkspaceConnectionBinding.sftp(server.details),
                title: server.details.name, components: directory.components.map(\.wireUTF8),
                relativeToHome: directory.root == .home)
        }
    }
}
