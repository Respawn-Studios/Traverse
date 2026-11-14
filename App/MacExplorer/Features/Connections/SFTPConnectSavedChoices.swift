@_spi(Qualification) import LocalStorage

/// Pure App presentation mapping. Inspecting saved metadata never fetches a
/// password, opens a key file or changes an existing worker/session policy.
enum SFTPConnectSavedChoices {
    static func values(_ snapshot: SFTPSettingsSnapshot?) -> [SFTPConnectServerChoice] {
        let direct = snapshot?.visibleServers.map { server in
                SFTPConnectServerChoice(id: server.id, details: server.details,
                    hasSavedPassword: snapshot?.credentials.contains { $0.reference.id == server.credentialID && $0.state == .ready } == true,
                    keyAuthentication: server.keyAuthentication, usesServerPrompts: server.usesServerPrompts,
                    defaultDirectory: try? server.effectiveDefaultDirectory, transferPreference: server.transferPreference)
            } ?? []
        let routes = snapshot?.visibleRoutes.map { route in
                SFTPConnectServerChoice(id: route.id, details: route.details.destination,
                    hasSavedPassword: snapshot?.credentials.contains { $0.reference.id == route.destination.credentialID && $0.state == .ready } == true,
                    route: route, jumpHasSavedPassword: snapshot?.credentials.contains { $0.reference.id == route.jump.credentialID && $0.state == .ready } == true,
                    defaultDirectory: try? route.effectiveDefaultDirectory, transferPreference: route.transferPreference)
            } ?? []
        return direct + routes
    }
}
