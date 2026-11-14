import Foundation

/// One bounded off-main owner of private SFTP metadata. No network, Keychain,
/// system SSH files or passive repair. Mutation admission stays inside the
/// verified-session/Forget coordinator; UI can only inspect public snapshots.
@_spi(Qualification) public final class SFTPSettingsStore: @unchecked Sendable {
    typealias File = RemoteSettingsFile<SFTPSettingsSnapshot>
    private let location: URL
    private let queue = DispatchQueue(label: "MacExplorer.SFTP.Settings", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var owner: File?
    private let probe: File.Probe?
    public init(directory: URL) { location = directory; probe = nil }
    init(directory: URL, probe: @escaping File.Probe) { location = directory; self.probe = probe }
    deinit { let held = owner; queue.async { held?.close() } }

    public func inspect() async throws -> SFTPSettingsSnapshot? {
        let (value, _) = try await perform(read: true) { [self] () throws -> SFTPSettingsSnapshot? in
            if let owner { try owner.validateCurrent(); return owner.snapshot }
            guard let opened = try File.open(location, writing: false) else { return nil as SFTPSettingsSnapshot? }
            defer { opened.close() }; return opened.snapshot
        }; return value
    }
    func openForExplicitWrite(discardUncommittedStage: Bool = false) async throws -> SFTPSettingsMutation {
        let (value, late) = try await perform(read: false) { [self] in
            guard owner == nil else { throw SFTPSettingsFailure.busy }
            guard let file = try File.open(location, writing: true, discardStage: discardUncommittedStage, probe: probe) else { throw SFTPSettingsFailure.unavailable }
            owner = file; return file.snapshot
        }; return SFTPSettingsMutation(snapshot: value, completedAfterCancellation: late)
    }
    func apply(_ change: SFTPSettingsChange, revision: UInt64) async throws -> SFTPSettingsMutation {
        let (value, late) = try await perform(read: false) { [self] in
            guard let owner else { throw SFTPSettingsFailure.notOpen }; try owner.validateCurrent()
            guard owner.snapshot.revision == revision else { throw SFTPSettingsFailure.staleRevision }
            var next = owner.snapshot; var result = SFTPSettingsMutation(snapshot: next)
            if next.forgetAllPending {
                switch change {
                case .beginForgetAll, .beginForgetPassword, .finishForgetPassword, .finishForgetAll: break
                default: throw SFTPSettingsFailure.recoveryRequired
                }
            }
            switch change {
            case let .saveMetadata(draft, directory, signIn, transferPreference, requiresCertificate):
                try draft.validate(); try directory.validate()
                guard !requiresCertificate || signIn.usesKey else { throw SFTPSettingsFailure.invalidRecord }
                guard next.servers.count + (next.routes?.count ?? 0) < 64 else { throw SFTPSettingsFailure.invalidRecord }
                let legacy = try SFTPDefaultDirectory(legacy: draft.address)
                let stored: SFTPDefaultDirectory? = directory == legacy ? nil : directory
                let method: SFTPServerKeyAuthentication?
                if signIn.usesKey { method = try SFTPServerKeyAuthentication(requiresServerPrompts: signIn.usesServerPrompts,
                    requiresCertificate: requiresCertificate) }
                else { method = nil }
                let id = UUID()
                next.servers.append(.init(id: id, details: draft, credentialID: nil, removalPending: false,
                    keyAuthentication: method, defaultDirectory: stored, transferPreference: transferPreference, interactiveSignIn: signIn == .serverPrompts ? true : nil))
                if signIn.usesServerPrompts { next.format = max(next.format, 3) }
                else if signIn.usesKey { next.format = max(next.format, 2) }
                if requiresCertificate { next.format = max(next.format, 8) }
                if stored != nil { next.format = max(next.format, 5) }
                if (directory.root == .home) != (draft.address.components == nil) { next.format = max(next.format, 7) }
                if transferPreference != nil { next.format = max(next.format, 6) }; result.serverID = id
            case let .updatePresentation(id, label, directory, route, transferPreference, expectedBinding):
                try directory.validate()
                guard transferPreference == nil || expectedBinding != nil else { throw SFTPSettingsFailure.invalidRecord }
                var crossesRoot = false
                if route {
                    guard var routes = next.routes, let index = routes.firstIndex(where: { $0.id == id }), !routes[index].removalPending else { throw SFTPSettingsFailure.missing }
                    let old = routes[index]
                    if let expectedBinding {
                        guard expectedBinding == SFTPConnectionPreferenceBinding(route: old.details) else { throw SFTPSettingsFailure.staleRevision }
                    }
                    crossesRoot = (directory.root == .home) != (old.details.destination.address.components == nil)
                    guard !crossesRoot || expectedBinding != nil else { throw SFTPSettingsFailure.invalidRecord }
                    let destination = try SFTPServerDraft(name: label, address: old.details.destination.address, account: old.details.destination.account)
                    let legacy = try SFTPDefaultDirectory(legacy: old.details.destination.address)
                    routes[index] = .init(id: id, details: try .init(destination: destination, jump: old.details.jump),
                        jump: old.jump, destination: old.destination, removalPending: false, defaultDirectory: directory == legacy ? nil : directory,
                        transferPreference: transferPreference ?? old.transferPreference)
                    next.routes = routes; result.routeID = id
                } else {
                    guard let index = next.servers.firstIndex(where: { $0.id == id }), !next.servers[index].removalPending else { throw SFTPSettingsFailure.missing }
                    let old = next.servers[index].details
                    if let expectedBinding {
                        guard expectedBinding == SFTPConnectionPreferenceBinding(server: old) else { throw SFTPSettingsFailure.staleRevision }
                    }
                    crossesRoot = (directory.root == .home) != (old.address.components == nil)
                    guard !crossesRoot || expectedBinding != nil else { throw SFTPSettingsFailure.invalidRecord }
                    next.servers[index].details = try .init(name: label, address: old.address, account: old.account)
                    let legacy = try SFTPDefaultDirectory(legacy: old.address)
                    next.servers[index].defaultDirectory = directory == legacy ? nil : directory
                    if let transferPreference { next.servers[index].transferPreference = transferPreference }; result.serverID = id
                }
                if transferPreference != nil { next.format = max(next.format, 6) }
                if next.servers.contains(where: { $0.defaultDirectory != nil }) || (next.routes ?? []).contains(where: { $0.defaultDirectory != nil }) { next.format = max(next.format, 5) }
                if crossesRoot { next.format = max(next.format, 7) }
            case let .saveHost(host, previous):
                try host.identity.validate(); _ = try SFTPHostKey(host.key.bytes)
                if host.key.algorithm != "ssh-ed25519" { next.format = max(next.format, 2) }
                if let index = next.hosts.firstIndex(where: { $0.identity == host.identity }) {
                    guard next.hosts[index].key == previous else { throw SFTPSettingsFailure.staleRevision }
                    next.hosts[index] = host
                } else {
                    guard previous == nil else { throw SFTPSettingsFailure.staleRevision }
                    guard next.hosts.count < 128 else { throw SFTPSettingsFailure.capacity }; next.hosts.append(host)
                }
            case let .forgetHost(identity):
                guard let index = next.hosts.firstIndex(where: { $0.identity == identity }) else { throw SFTPSettingsFailure.missing }
                next.hosts.remove(at: index)
            case let .saveServer(draft, id, credentialID, keyAuthentication, serverPrompts):
                try draft.validate()
                if serverPrompts {
                    guard credentialID == nil, keyAuthentication == nil else { throw SFTPSettingsFailure.invalidRecord }
                    next.format = max(next.format, 3)
                }
                if let keyAuthentication {
                    try keyAuthentication.validate(); guard credentialID == nil else { throw SFTPSettingsFailure.invalidRecord }
                    next.format = max(next.format, keyAuthentication.requiresServerPrompts ? 3 : 2)
                    if keyAuthentication.requiresCertificate { next.format = max(next.format, 8) }
                }
                if let credentialID {
                    guard let claim = next.credentials.first(where: { $0.reference.id == credentialID }), claim.state == .ready,
                          claim.reference.bindingDigest == (try SFTPCredentialBinding(request: draft.request, keyDigest: claim.reference.hostKeyDigest)).digest else {
                        throw SFTPSettingsFailure.invalidRecord
                    }
                }
                if let id {
                    guard let index = next.servers.firstIndex(where: { $0.id == id }), !next.servers[index].removalPending else { throw SFTPSettingsFailure.missing }
                    if next.servers[index].details.address != draft.address || !next.servers[index].details.account.utf8.elementsEqual(draft.account.utf8) {
                        next.servers[index].defaultDirectory = nil
                        next.servers[index].transferPreference = nil
                    }
                    next.servers[index].details = draft; next.servers[index].credentialID = credentialID
                    next.servers[index].keyAuthentication = keyAuthentication; result.serverID = id
                    next.servers[index].interactiveSignIn = serverPrompts ? true : nil
                } else {
                    guard next.servers.count + (next.routes?.count ?? 0) < 64 else { throw SFTPSettingsFailure.capacity }; let id = UUID()
                    next.servers.append(.init(id: id, details: draft, credentialID: credentialID, removalPending: false,
                        keyAuthentication: keyAuthentication, interactiveSignIn: serverPrompts ? true : nil)); result.serverID = id
                }
            case let .beginPassword(binding):
                guard next.credentials.count < 128 else { throw SFTPSettingsFailure.capacity }
                let reference = SFTPCredentialReference(binding: binding); result.credential = reference
                next.credentials.append(.init(reference: reference, state: .preparing))
            case let .confirmPassword(id):
                guard let index = next.credentials.firstIndex(where: { $0.reference.id == id }), next.credentials[index].state == .preparing else { throw SFTPSettingsFailure.missing }
                next.credentials[index].state = .ready
            case let .beginForgetPassword(id): try Self.markPassword(id, in: &next)
            case let .finishForgetPassword(id):
                guard let index = next.credentials.firstIndex(where: { $0.reference.id == id }), next.credentials[index].state == .deleting else { throw SFTPSettingsFailure.missing }
                next.credentials.remove(at: index)
                for index in next.servers.indices where next.servers[index].credentialID == id { next.servers[index].credentialID = nil }
                if let routes = next.routes {
                    next.routes = routes.map { route in var copy = route
                        if copy.jump.credentialID == id { copy.jump.credentialID = nil }
                        if copy.destination.credentialID == id { copy.destination.credentialID = nil }; return copy
                    }
                }
            case let .beginForgetServer(id, remove):
                guard let index = next.servers.firstIndex(where: { $0.id == id }) else { throw SFTPSettingsFailure.missing }
                next.servers[index].removalPending = true
                if remove, let credential = next.servers[index].credentialID { try Self.markPassword(credential, in: &next) }
            case let .beginForgetExpectedServer(expected, remove):
                guard let index = next.servers.firstIndex(where: { $0.id == expected.id }) else { throw SFTPSettingsFailure.missing }
                guard next.servers[index] == expected, !next.servers[index].removalPending else { throw SFTPSettingsFailure.staleRevision }
                next.servers[index].removalPending = true
                if remove, let credential = next.servers[index].credentialID { try Self.markPassword(credential, in: &next) }
            case let .finishForgetServer(id):
                guard let index = next.servers.firstIndex(where: { $0.id == id }), next.servers[index].removalPending else { throw SFTPSettingsFailure.missing }
                if let id = next.servers[index].credentialID,
                   next.credentials.first(where: { $0.reference.id == id })?.state == .deleting { throw SFTPSettingsFailure.recoveryRequired }
                next.servers.remove(at: index)
            case .beginForgetAll:
                next.forgetAllPending = true; next.hosts.removeAll()
                for index in next.servers.indices { next.servers[index].removalPending = true }
                for index in next.credentials.indices { next.credentials[index].state = .deleting }
                if let routes = next.routes { next.routes = routes.map { route in var copy = route; copy.removalPending = true; return copy } }
            case .finishForgetAll:
                guard next.forgetAllPending, next.credentials.isEmpty else { throw SFTPSettingsFailure.recoveryRequired }
                next.servers.removeAll(); next.hosts.removeAll(); next.routes = nil; next.forgetAllPending = false
            case let .saveRoute(details, jump, destination, id):
                try details.validate(); next.format = max(next.format, 4)
                var routes = next.routes ?? []
                var value = SFTPSavedRoute(id: id ?? UUID(), details: details, jump: jump, destination: destination, removalPending: false)
                try value.validate()
                if let id {
                    guard let index = routes.firstIndex(where: { $0.id == id }), !routes[index].removalPending else { throw SFTPSettingsFailure.missing }
                    let old = routes[index]
                    if old.details.destination.address == details.destination.address,
                       old.details.destination.account.utf8.elementsEqual(details.destination.account.utf8),
                       old.details.jump.address == details.jump.address, old.details.jump.account.utf8.elementsEqual(details.jump.account.utf8) {
                        value.defaultDirectory = old.defaultDirectory
                        value.transferPreference = old.transferPreference
                    }
                    routes[index] = value
                } else { guard next.servers.count + routes.count < 64 else { throw SFTPSettingsFailure.capacity }; routes.append(value) }
                next.routes = routes; result.routeID = value.id
            case let .beginForgetRoute(id, remove):
                guard var routes = next.routes, let index = routes.firstIndex(where: { $0.id == id }) else { throw SFTPSettingsFailure.missing }
                routes[index].removalPending = true; next.routes = routes
                if remove {
                    for credential in [routes[index].jump.credentialID, routes[index].destination.credentialID].compactMap({ $0 }) { try Self.markPassword(credential, in: &next) }
                }
            case let .beginForgetExpectedRoute(expected, remove):
                guard var routes = next.routes, let index = routes.firstIndex(where: { $0.id == expected.id }) else { throw SFTPSettingsFailure.missing }
                guard routes[index] == expected, !routes[index].removalPending else { throw SFTPSettingsFailure.staleRevision }
                routes[index].removalPending = true; next.routes = routes
                if remove {
                    for credential in [routes[index].jump.credentialID, routes[index].destination.credentialID].compactMap({ $0 }) { try Self.markPassword(credential, in: &next) }
                }
            case let .finishForgetRoute(id):
                guard var routes = next.routes, let index = routes.firstIndex(where: { $0.id == id }), routes[index].removalPending else { throw SFTPSettingsFailure.missing }
                for credential in [routes[index].jump.credentialID, routes[index].destination.credentialID].compactMap({ $0 }) {
                    guard next.credentials.first(where: { $0.reference.id == credential })?.state != .deleting else { throw SFTPSettingsFailure.recoveryRequired }
                }
                routes.remove(at: index); next.routes = routes.isEmpty ? nil : routes
            }
            guard next.revision < UInt64.max else { throw SFTPSettingsFailure.capacity }; next.revision += 1
            try owner.commit(next)
            return SFTPSettingsMutation(snapshot: next, serverID: result.serverID, routeID: result.routeID, credential: result.credential)
        }
        return SFTPSettingsMutation(snapshot: value.snapshot, serverID: value.serverID, routeID: value.routeID, credential: value.credential, completedAfterCancellation: late)
    }
    private static func markPassword(_ id: UUID, in snapshot: inout SFTPSettingsSnapshot) throws {
        guard let index = snapshot.credentials.firstIndex(where: { $0.reference.id == id }) else { throw SFTPSettingsFailure.missing }
        snapshot.credentials[index].state = .deleting
        for index in snapshot.servers.indices where snapshot.servers[index].credentialID == id && !snapshot.servers[index].removalPending {
            snapshot.servers[index].credentialID = nil
        }
        if let routes = snapshot.routes {
            snapshot.routes = routes.map { route in var copy = route
                if !copy.removalPending {
                    if copy.jump.credentialID == id { copy.jump.credentialID = nil }
                    if copy.destination.credentialID == id { copy.destination.credentialID = nil }
                }; return copy
            }
        }
    }
    public func close() async {
        await withCheckedContinuation { continuation in
            lock.withLock { queue.async { [self] in owner?.close(); owner = nil; continuation.resume() } }
        }
    }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock(); private var stopped = false
        var cancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }
    private func perform<T: Sendable>(read: Bool, body: @escaping @Sendable () throws -> T) async throws -> (T, Bool) {
        let request = Request()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard pending < 8 else { lock.unlock(); continuation.resume(throwing: SFTPSettingsFailure.busy); return }; pending += 1
                queue.async { [self] in
                    let result: Result<T, Error> = request.cancelled ? .failure(SFTPSettingsFailure.cancelled) : Result { try body() }
                    let cancelled = request.cancelled; lock.withLock { pending -= 1 }
                    if read && cancelled { continuation.resume(throwing: SFTPSettingsFailure.cancelled) }
                    else { continuation.resume(with: result.map { ($0, cancelled) }) }
                }; lock.unlock()
            }
        } onCancel: { request.cancel() }
    }
}
