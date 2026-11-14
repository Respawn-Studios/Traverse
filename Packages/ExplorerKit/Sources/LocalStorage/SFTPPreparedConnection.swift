import Darwin
import ExplorerCore
import Foundation

/// A resolver that did not release its child/owner cannot be reported as
/// fully closed merely because no SFTP session was admitted.
struct SFTPAddressPreparationFailure: Error, Sendable, CustomStringConvertible {
    let cause: SFTPSessionFailure
    let localResourcesEnded: Bool
    var description: String { "<SFTP address preparation failed>" }
}

/// A finite numeric observation, not host trust or password/access authority.
/// Only this credential-free preparation can construct it for a frozen peer.
@_spi(Qualification) public struct SFTPPreparedConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let host: String, port: UInt16, requestedScope: UInt32
    let numericHost: String
    public let interfaceScopeID: UInt32
    let expires: TimeInterval
    public var description: String { "<SFTP prepared connection>" }
    public var debugDescription: String { description }
    private init(request: SFTPConnectionRequest, numericHost: String, scopeID: UInt32) {
        host = request.address.host; port = request.address.port; requestedScope = request.address.scopeID
        self.numericHost = numericHost; interfaceScopeID = scopeID; expires = ProcessInfo.processInfo.systemUptime + 30
    }
    public static func prepare(_ request: SFTPConnectionRequest, bundleURL: URL, activity: FileActivityGate) async throws -> Self {
        guard !Task.isCancelled else { throw SFTPSessionFailure.stopped }
        let address = request.address
        if address.hostKind != .dns {
            return Self(request: request, numericHost: address.host, scopeID: address.scopeID)
        }
        let resolved: SMBHostnameResult
        do { resolved = try await SMBHostnameResolver.resolve(address.host, bundleURL: bundleURL, activity: activity) }
        catch let failure as SMBResolutionFailure { throw resolverFailure(failure) }
        if Task.isCancelled {
            throw SFTPAddressPreparationFailure(cause: .stopped, localResourcesEnded: resolved.lifetime.ownerReleased)
        }
        if let failure = resolved.failure {
            throw SFTPAddressPreparationFailure(cause: resolverFailure(failure), localResourcesEnded: resolved.lifetime.ownerReleased)
        }
        guard resolved.lifetime.actualExit, resolved.lifetime.pipeDrained,
              resolved.lifetime.ownerReleased, resolved.lifetime.lookupStarted, resolved.lifetime.submittedNativeQuery,
              resolved.lifetime.deallocatedNativeReference, !resolved.lifetime.forcedContainment, let candidate = resolved.addresses.first else {
            throw SFTPAddressPreparationFailure(cause: .unavailable, localResourcesEnded: resolved.lifetime.ownerReleased)
        }
        let family = candidate.family == .ipv4 ? AF_INET : AF_INET6
        var bytes = Array(candidate.addressBytes), text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard bytes.count == (family == AF_INET ? 4 : 16), inet_ntop(family, &bytes, &text, socklen_t(text.count)) != nil else {
            throw SFTPSessionFailure.input
        }
        let end = text.firstIndex(of: 0) ?? text.count
        let numeric = String(decoding: text.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return Self(request: request, numericHost: numeric, scopeID: candidate.scopeID)
    }
    static func resolverFailure(_ failure: SMBResolutionFailure) -> SFTPSessionFailure {
        switch failure {
        case .busy: .busy
        case .invalidInput: .input
        case .invalidOutput: .output
        case .stopped: .stopped
        case .deadline: .deadline
        case .workerExited: .exited
        case .unavailable, .containment: .unavailable
        }
    }
    func validate(for request: SFTPConnectionRequest, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard host == request.address.host, port == request.address.port, requestedScope == request.address.scopeID,
              now < expires else { throw SFTPSessionFailure.input }
    }
}

extension SFTPWorkerSession {
    /// Qualified native seam only. Ordinary routing is separately gated. Always
    /// paged; raw batches and arbitrary pre-verified keys are not public inputs.
    @_spi(Qualification) public static func openPrepared(_ request: SFTPConnectionRequest, endpoint: SFTPPreparedConnection,
        bundleURL: URL, activity: FileActivityGate, pool: SMBTemporaryCatalogPool, remembered: SFTPRememberedState? = nil,
        requestedDownloads: Bool = false, requestedFolderDownloads: Bool = false, freshUploads: Bool = false, keyAuthentication: Bool = false,
        interactiveAuthentication: Bool = false, freshFolderUploads: Bool = false,
        remoteActions: Bool = false, guardedInPlaceEditing: Bool = false) async throws -> SFTPWorkerSession {
        try endpoint.validate(for: request)
        let previous = try await remembered?.previousKey(for: SFTPHostIdentity(address: request.address))
        try endpoint.validate(for: request)
        let peer = try configuredPreparedPeer(request, endpoint: endpoint, bundleURL: bundleURL, pool: pool,
            previous: previous, requestedDownloads: requestedDownloads, requestedFolderDownloads: requestedFolderDownloads,
            freshUploads: freshUploads, keyAuthentication: keyAuthentication,
            interactiveAuthentication: interactiveAuthentication, freshFolderUploads: freshFolderUploads,
            remoteActions: remoteActions, guardedInPlaceEditing: guardedInPlaceEditing)
        return try await begin(peer: peer, account: request.account, activity: activity, pool: pool)
    }
    /// Pure admission composition for the prepared peer. Editor mode is an
    /// explicit connection-time choice and never follows upload bits alone.
    static func configuredPreparedPeer(_ request: SFTPConnectionRequest, endpoint: SFTPPreparedConnection,
        bundleURL: URL, pool: SMBTemporaryCatalogPool, previous: SFTPHostKey? = nil,
        requestedDownloads: Bool = false, requestedFolderDownloads: Bool = false, freshUploads: Bool = false,
        keyAuthentication: Bool = false, interactiveAuthentication: Bool = false,
        freshFolderUploads: Bool = false, remoteActions: Bool = false, guardedInPlaceEditing: Bool = false) throws -> SFTPPeerConfiguration {
        try endpoint.validate(for: request)
        guard !guardedInPlaceEditing || keyAuthentication else { throw SFTPSessionFailure.input }
        guard !remoteActions || keyAuthentication && requestedDownloads && requestedFolderDownloads && freshUploads else { throw SFTPSessionFailure.input }
        var peer = SFTPPeerConfiguration(host: request.address.host, port: request.address.port,
            numericHost: endpoint.numericHost, scopeID: endpoint.interfaceScopeID, bundle: bundleURL,
            validateAdmission: { try endpoint.validate(for: request) }, previousKey: previous, requestedScopeID: request.address.scopeID)
        peer.allowsRequestedDownloads = requestedDownloads
        peer.allowsRequestedFolderDownloads = requestedFolderDownloads
        peer.allowsFreshUploads = freshUploads
        peer.allowsFreshFolderUploads = freshFolderUploads
        peer.allowsRemoteActions = remoteActions
        peer.contentAccess = freshUploads ? .transferWrites : .readOnly
        peer.allowsKeyAuthentication = keyAuthentication
        peer.allowsInteractiveAuthentication = interactiveAuthentication || guardedInPlaceEditing
        if guardedInPlaceEditing {
            peer.contentAccess = .guardedInPlaceV1
            peer.inPlaceEditingPermit = try .preparedCandidate(peer: peer, pool: pool)
        }
        return peer
    }
}
