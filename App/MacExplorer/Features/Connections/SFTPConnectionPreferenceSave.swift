import Foundation
@_spi(Qualification) import LocalStorage

/// Only the bounded metadata owner writes. This helper cannot open a socket,
/// obtain credentials, create a mutation permit or change a live worker policy.
enum SFTPConnectionPreferenceSave {
    struct Request: Sendable {
        let draft: SFTPServerDraft
        let route: SFTPRouteDescription?
        let defaultDirectory: SFTPDefaultDirectory?
        let transferPreference: SFTPTransferPreference
        let rememberServer: Bool
        let editingServer: UUID?
        let editingRoute: UUID?
    }
    struct Outcome: Sendable { let snapshot: SFTPSettingsSnapshot?; let confirmed: Bool }
    static func persist(_ submission: Request, serverID: UUID?, routeID: UUID?,
                        state: SFTPRememberedState, snapshot: SFTPSettingsSnapshot?) async -> Outcome {
        guard submission.rememberServer else { return .init(snapshot: snapshot, confirmed: true) }
        do {
            guard let snapshot else { throw SFTPSettingsFailure.unavailable }
            let result: SFTPSettingsMutation
            if let route = submission.route {
                guard let id = routeID ?? submission.editingRoute,
                      let saved = snapshot.visibleRoutes.first(where: { $0.id == id }),
                      SFTPConnectionPreferenceBinding(route: saved.details) == .init(route: route) else { throw SFTPSettingsFailure.staleRevision }
                let directory = try submission.defaultDirectory ?? saved.effectiveDefaultDirectory
                result = try await state.updatePresentation(id: id, route: true, expectedRevision: snapshot.revision,
                    label: submission.draft.name, directory: directory, transferPreference: submission.transferPreference,
                    expectedBinding: .init(route: route))
            } else {
                guard let id = serverID ?? submission.editingServer,
                      let saved = snapshot.visibleServers.first(where: { $0.id == id }),
                      SFTPConnectionPreferenceBinding(server: saved.details) == .init(server: submission.draft) else { throw SFTPSettingsFailure.staleRevision }
                let directory = try submission.defaultDirectory ?? saved.effectiveDefaultDirectory
                result = try await state.updatePresentation(id: id, expectedRevision: snapshot.revision,
                    label: submission.draft.name, directory: directory, transferPreference: submission.transferPreference,
                    expectedBinding: .init(server: submission.draft))
            }
            // Always commit an explicit Remember choice, even when an inspected
            // record already looks equal. A passive read cannot repair or prove
            // durability after an earlier uncertain write.
            return .init(snapshot: result.snapshot, confirmed: true)
        } catch {
            // A renamed-but-unsynchronized record may be visible here. It still
            // must not become a confirmed Save merely because a read can see it.
            return .init(snapshot: try? await state.inspect(), confirmed: false)
        }
    }
}
