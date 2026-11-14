import Darwin
import ExplorerCore
import Foundation

/// One explicit connection attempt's immutable logical and numeric endpoints.
/// Not Codable: a layout/saved server must never persist resolved authority.
@_spi(Qualification) public struct SMBPreparedConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: SMBConnectionAddress
    let numericHost: String, scopeID: UInt32
    private let expires: TimeInterval
    var helperIdentity: SMBBundledHelperIdentity.Prepared?
    public var description: String { "<Prepared SMB connection>" }
    public var debugDescription: String { description }

    /// Production orchestration verifies the selected local bundle before a
    /// saved password is queried. Endpoint-only controls keep their pure seam.
    static func prepareValidated(_ address: SMBConnectionAddress, bundleURL: URL, activity: FileActivityGate) async throws -> Self {
        try Task.checkCancellation()
        let lease = try activity.begin()
        let identity: SMBBundledHelperIdentity.Prepared
        do {
            identity = try await Task.detached(priority: .userInitiated) {
                try withExtendedLifetime(lease) { try SMBBundledHelperIdentity.prepare(.browser, bundle: bundleURL) }
            }.value
        } catch { throw SMBBrowserFailure.unavailable }
        try Task.checkCancellation()
        var endpoint = try await prepare(address, bundleURL: bundleURL, activity: activity)
        endpoint.helperIdentity = identity; return endpoint
    }

    public static func prepare(_ address: SMBConnectionAddress, bundleURL: URL, activity: FileActivityGate) async throws -> Self {
        try Task.checkCancellation()
        let candidates: [SMBResolvedAddress]
        if address.hostKind == .dns {
            let result = try await SMBHostnameResolver.resolve(address.host, bundleURL: bundleURL, activity: activity)
            guard result.failure == nil, result.lifetime.actualExit, result.lifetime.pipeDrained,
                  result.lifetime.ownerReleased, !result.lifetime.forcedContainment else {
                throw result.failure ?? SMBResolutionFailure.containment
            }
            candidates = result.addresses
        } else {
            let family: Int32 = address.hostKind == .ipv4 ? AF_INET : AF_INET6
            var bytes = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
            guard inet_pton(family, address.host, &bytes) == 1 else { throw SMBResolutionFailure.invalidInput }
            candidates = [.init(family: family == AF_INET ? .ipv4 : .ipv6, addressBytes: Data(bytes), scopeID: address.scopeID, interfaceIndex: 0)]
        }
        try Task.checkCancellation()
        return try select(address, candidates: candidates)
    }
    /// Internal seam for exact resolver-result controls, not a caller-supplied
    /// destination in the public Connect interface. Preserve resolver ordering.
    static func select(_ address: SMBConnectionAddress, candidates: [SMBResolvedAddress], now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Self {
        guard !candidates.isEmpty, candidates.count <= 16, now.isFinite else { throw SMBResolutionFailure.invalidOutput }
        let candidate = candidates[0], bytes = Array(candidate.addressBytes)
        guard bytes.count == (candidate.family == .ipv4 ? 4 : 16), candidate.scopeID < 0xffff_fff0 else { throw SMBResolutionFailure.invalidOutput }
        if candidate.family == .ipv4 {
            guard candidate.scopeID == 0, bytes[0] > 0, bytes[0] < 224 else { throw SMBResolutionFailure.invalidOutput }
        } else {
            guard bytes.contains(where: { $0 != 0 }), bytes[0] != 255,
                  !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || candidate.scopeID > 0 else { throw SMBResolutionFailure.invalidOutput }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = candidate.family == .ipv4 ? AF_INET : AF_INET6
        guard bytes.withUnsafeBytes({ inet_ntop(family, $0.baseAddress, &output, socklen_t(output.count)) }) != nil else {
            throw SMBResolutionFailure.invalidOutput
        }
        let host = String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if address.hostKind != .dns {
            guard host == address.host, candidate.scopeID == address.scopeID else { throw SMBResolutionFailure.invalidOutput }
        }
        return Self(address: address, numericHost: host, scopeID: candidate.scopeID, expires: now + 30, helperIdentity: nil)
    }
    func validate(for request: SMBServerDraft, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard request.address == address, now.isFinite, expires - 30 <= now, now < expires else { throw SMBResolutionFailure.invalidInput }
        try request.validate()
    }
    func command(session: UUID, catalog: URL, quota: UInt64, policy: SMBWorkerSecurityPolicy) -> String {
        let host = Self.hex(Data(address.host.utf8))
        let share = address.share.displayName.utf16.map { String(format: "%04x", $0) }.joined()
        return "MEXSMBB2 START \(session.uuidString) \(policy.rawValue) \(numericHost) \(address.port) \(scopeID) \(host) \(share) \(Self.hex(Data(catalog.path.utf8))) \(quota)\n"
    }
    static func credentials(account: String, domain: String, password: SMBPassword) -> Data {
        var result = Data("CREDENTIALS \(hex(Data(account.utf8))) ".utf8)
        password.withUTF8Bytes { result.append(contentsOf: hex($0).utf8) }
        result.append(contentsOf: " \(domain.isEmpty ? "-" : hex(Data(domain.utf8)))\n".utf8)
        return result
    }
    private static func hex(_ value: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: value.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
}
