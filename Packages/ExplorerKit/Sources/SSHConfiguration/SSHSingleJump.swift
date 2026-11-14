import Foundation

/// One declarative jump, resolved from the same explicitly supplied documents.
/// Resolving a route does not authorize DNS, a socket, credentials or a command.
public struct SSHSingleJump: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let destination: SSHResolvedProfile
    public let jump: SSHResolvedProfile
    public var description: String { "<one-jump SSH connection profile>" }
    public var debugDescription: String { description }
}

public enum SSHJumpFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case noJump, invalidEndpoint, multipleJumps, nestedRoute, unresolvedConfiguration
    public var description: String { "<SSH route could not be used>" }
    public var debugDescription: String { description }
}

extension SSHConfiguration {
    /// Explicit user/port in ProxyJump take precedence over the jump's Host
    /// stanza. Its HostName, identity suggestions and policies remain intact.
    public func singleJump(_ alias: String, defaultUser: String? = nil) throws -> SSHSingleJump {
        let target = try resolve(alias, defaultUser: defaultUser)
        guard target.requirements.isEmpty else { throw SSHJumpFailure.unresolvedConfiguration }
        guard case .jump(let text) = target.route else { throw SSHJumpFailure.noJump }
        let endpoint = try SSHJumpEndpoint(text)
        let inherited = try resolve(endpoint.alias, defaultUser: defaultUser)
        guard inherited.route == .direct else { throw SSHJumpFailure.nestedRoute }
        guard inherited.requirements.isEmpty else { throw SSHJumpFailure.unresolvedConfiguration }
        let jump = SSHResolvedProfile(alias: inherited.alias, host: inherited.host,
            port: endpoint.port ?? inherited.port, user: endpoint.user ?? inherited.user,
            identityFiles: inherited.identityFiles, certificateFiles: inherited.certificateFiles,
            identityAgent: inherited.identityAgent, identitiesOnly: inherited.identitiesOnly,
            preferredAuthentications: inherited.preferredAuthentications, route: .direct,
            requirements: inherited.requirements, hasLiteralHostEntry: inherited.hasLiteralHostEntry)
        return .init(destination: target, jump: jump)
    }
}

private struct SSHJumpEndpoint {
    let alias: String
    let user: String?
    let port: UInt16?
    init(_ input: String) throws {
        guard !input.isEmpty, input.utf8.count <= 1024 else { throw SSHJumpFailure.invalidEndpoint }
        guard !input.contains(",") else { throw SSHJumpFailure.multipleJumps }
        var value = input.hasPrefix("ssh://") ? String(input.dropFirst(6)) : input
        // No percent/environment expansion, password, URI path/query or command
        // language. An unqualified form is refused, never interpreted as direct.
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              !value.contains(where: { "/?#%\\".contains($0) }) else { throw SSHJumpFailure.invalidEndpoint }
        let users = value.split(separator: "@", omittingEmptySubsequences: false)
        guard users.count <= 2 else { throw SSHJumpFailure.invalidEndpoint }
        if users.count == 2 {
            let account = String(users[0])
            guard !account.isEmpty, account.utf8.count <= 256,
                  !account.contains(where: { ":[]".contains($0) }) else { throw SSHJumpFailure.invalidEndpoint }
            user = account; value = String(users[1])
        } else { user = nil }
        let host: String, portText: String?
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { throw SSHJumpFailure.invalidEndpoint }
            host = String(value[value.index(after: value.startIndex)..<end])
            let rest = value[value.index(after: end)...]
            guard host.contains(":"), rest.isEmpty || rest.hasPrefix(":") else { throw SSHJumpFailure.invalidEndpoint }
            portText = rest.isEmpty ? nil : String(rest.dropFirst())
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw SSHJumpFailure.invalidEndpoint }
            host = String(parts[0]); portText = parts.count == 2 ? String(parts[1]) : nil
        }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,95].contains($0) }),
              !host.hasPrefix("-"), !host.hasPrefix("."), !host.hasSuffix(".") else { throw SSHJumpFailure.invalidEndpoint }
        alias = host
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt16(portText), number != 0 else { throw SSHJumpFailure.invalidEndpoint }
            port = number
        } else { port = nil }
    }
}
