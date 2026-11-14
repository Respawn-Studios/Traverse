import Foundation
import SSHConfiguration

@_spi(Qualification) public enum SFTPProfileSetupIssue: String, Sendable, Hashable {
    case unresolvedConfiguration, externalCommand, agent, certificate, algorithms, hostTrust, network, unsupportedOption
    case authentication, jumpHost, keyPath
}
@_spi(Qualification) public struct SFTPImportedProfile: Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: String { alias }
    public let alias: String
    public let address: SFTPConnectionAddress?
    public let account: String?
    public let identitySuggestions: [URL]
    public let certificateSuggestions: [URL]
    public let preferredAuthentications: [String]
    public let issues: Set<SFTPProfileSetupIssue>
    public var jump: SFTPImportedJump? = nil
    public var needsSetup: Bool { !issues.subtracting([.keyPath]).isEmpty }
    public func canConnect(using authentication: SFTPAuthenticationChoice) -> Bool {
        let admitted = authentication.usesUserCertificate ? issues.subtracting([.keyPath, .certificate])
            : issues.subtracting([.keyPath])
        return address != nil && admitted.isEmpty && jump == nil
    }
    public var description: String { "<imported SFTP connection profile>" }
    public var debugDescription: String { description }
}
@_spi(Qualification) public struct SFTPImportedJump: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let alias: String
    public let address: SFTPConnectionAddress
    public let account: String?
    public let identitySuggestions: [URL]
    public let preferredAuthentications: [String]
    public let keyPathWarning: Bool
    public var description: String { "<imported SSH jump settings>" }
    public var debugDescription: String { description }
}

extension SSHConfigurationImport {
    @_spi(Qualification) public func connectionProfiles(home: URL, localUser: String, userID: UInt32, serverPrompts: Bool = false, singleJump: Bool = false) -> [SFTPImportedProfile] {
        profiles.map { summary in
            guard let profile = summary.resolved, summary.failure == nil else {
                return .init(alias: summary.alias, address: nil, account: nil, identitySuggestions: [],
                    certificateSuggestions: [], preferredAuthentications: [], issues: [.unresolvedConfiguration])
            }
            var issues = Set<SFTPProfileSetupIssue>()
            for requirement in profile.requirements {
                switch requirement {
                case .conditionalConfiguration, .includedConfiguration: issues.insert(.unresolvedConfiguration)
                case .externalCommand: issues.insert(.externalCommand)
                case .agent: issues.insert(.agent)
                case .certificate: issues.insert(.certificate)
                case .algorithmPolicy: issues.insert(.algorithms)
                case .hostTrustPolicy: issues.insert(.hostTrust)
                case .networkBinding: issues.insert(.network)
                case .unrecognizedOption: issues.insert(.unsupportedOption)
                }
            }
            var importedJump: SFTPImportedJump?
            switch profile.route {
            case .direct: break
            case .jump:
                if singleJump, let resolved = try? configuration.singleJump(profile.alias) {
                    let outer = resolved.jump
                    let authority = outer.host.contains(":") ? "[\(outer.host)]:\(outer.port)" : "\(outer.host):\(outer.port)"
                    let context = SSHKeyPathContext(home: home.path, localUser: localUser, userID: userID)
                    var pathWarning = false
                    let paths = outer.identityFiles.compactMap { value -> URL? in
                        guard let path = try? SSHKeyPathExpansion.expand(value, profile: outer, context: context) else { pathWarning = true; return nil }
                        return URL(fileURLWithPath: path)
                    }
                    if let address = try? SFTPConnectionAddress("sftp://" + authority) {
                        importedJump = .init(alias: outer.alias, address: address, account: outer.user, identitySuggestions: paths,
                            preferredAuthentications: outer.preferredAuthentications, keyPathWarning: pathWarning)
                        if Set(outer.preferredAuthentications).isDisjoint(with: serverPrompts ? ["publickey", "password", "keyboard-interactive"] : ["publickey", "password"]) { issues.insert(.authentication) }
                    } else { issues.insert(.jumpHost) }
                } else { issues.insert(.jumpHost) }
            case .externalCommand: issues.insert(.externalCommand)
            }
            // Keyboard-interactive has its own next qualification. Do not
            // quietly replace an explicitly restricted method with password.
            if Set(profile.preferredAuthentications).isDisjoint(with: serverPrompts ? ["publickey", "password", "keyboard-interactive"] : ["publickey", "password"]) { issues.insert(.authentication) }
            let context = SSHKeyPathContext(home: home.path, localUser: localUser, userID: userID)
            let paths = profile.identityFiles.compactMap { value -> URL? in
                guard let path = try? SSHKeyPathExpansion.expand(value, profile: profile, context: context) else { issues.insert(.keyPath); return nil }
                return URL(fileURLWithPath: path)
            }
            let certificatePaths = profile.certificateFiles.compactMap { value -> URL? in
                guard let path = try? SSHKeyPathExpansion.expand(value, profile: profile, context: context) else {
                    issues.insert(.keyPath); return nil
                }
                return URL(fileURLWithPath: path)
            }
            let authority = profile.host.contains(":") ? "[\(profile.host)]:\(profile.port)" : "\(profile.host):\(profile.port)"
            let address = try? SFTPConnectionAddress("sftp://" + authority)
            if address == nil { issues.insert(.unresolvedConfiguration) }
            return .init(alias: profile.alias, address: address, account: profile.user,
                         identitySuggestions: paths, certificateSuggestions: certificatePaths,
                         preferredAuthentications: profile.preferredAuthentications, issues: issues, jump: importedJump)
        }
    }
    func validateConnection(alias: String, draft: SFTPServerDraft, authentication: SFTPAuthenticationChoice) throws {
        let profile = try configuration.resolve(alias)
        let remaining = authentication.usesUserCertificate ? profile.requirements.subtracting([.certificate]) : profile.requirements
        guard profile.hasLiteralHostEntry, remaining.isEmpty, profile.route == .direct,
              profile.host.lowercased() == draft.address.host, profile.port == draft.address.port,
              profile.user == nil || Data(profile.user!.utf8) == Data(draft.account.utf8) else { throw SFTPSessionFailure.input }
        try validateAuthentication(authentication, profile: profile)
    }
    func validateRouteConnection(alias: String, route: SFTPRouteDescription, jump: SFTPAuthenticationChoice, destination: SFTPAuthenticationChoice) throws {
        let resolved = try configuration.singleJump(alias)
        guard resolved.destination.hasLiteralHostEntry else { throw SFTPSessionFailure.input }
        for (profile, draft, choice) in [(resolved.jump, route.jump, jump), (resolved.destination, route.destination, destination)] {
            guard profile.requirements.isEmpty, !choice.usesUserCertificate,
                  profile.host.lowercased() == draft.address.host, profile.port == draft.address.port, draft.address.scopeID == 0,
                  profile.user == nil || Data(profile.user!.utf8) == Data(draft.account.utf8) else { throw SFTPSessionFailure.input }
            try validateAuthentication(choice, profile: profile)
        }
    }
    private func validateAuthentication(_ authentication: SFTPAuthenticationChoice, profile: SSHResolvedProfile) throws {
        switch authentication {
        case .password:
            guard profile.preferredAuthentications.contains("password") else { throw SFTPSessionFailure.input }
        case .keyFile:
            guard profile.preferredAuthentications.contains("publickey") else { throw SFTPSessionFailure.input }
        case .serverPrompts:
            guard profile.preferredAuthentications.contains("keyboard-interactive") else { throw SFTPSessionFailure.input }
        case .keyFileWithServerPrompts:
            guard profile.preferredAuthentications.contains("publickey"), profile.preferredAuthentications.contains("keyboard-interactive") else { throw SFTPSessionFailure.input }
        case .userCertificate(_, _, _, _, _, let prompts):
            guard profile.preferredAuthentications.contains("publickey"),
                  !prompts || profile.preferredAuthentications.contains("keyboard-interactive") else { throw SFTPSessionFailure.input }
        }
    }
}
