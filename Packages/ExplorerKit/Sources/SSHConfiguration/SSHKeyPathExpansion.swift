import Foundation

/// Explicit scalar context, never environment/home/config discovery. Returning
/// a suggested path confers neither access nor authority to read a private key.
public struct SSHKeyPathContext: Sendable {
    public let home: String, localUser: String
    public let userID: UInt32
    public let workingDirectory: String?
    public init(home: String, localUser: String, userID: UInt32, workingDirectory: String? = nil) {
        self.home = home; self.localUser = localUser; self.userID = userID; self.workingDirectory = workingDirectory
    }
}

public enum SSHKeyPathExpansion {
    public static func expand(_ path: String, profile: SSHResolvedProfile, context: SSHKeyPathContext) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("$"),
              context.home.hasPrefix("/"), context.home.utf8.count <= 4096,
              !context.home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SSHConfigurationFailure.invalidValue }
        let route: String
        switch profile.route { case .direct: route = ""; case .jump(let value): route = value; case .externalCommand: throw SSHConfigurationFailure.invalidValue }
        let tokens: [Character: String] = ["%": "%", "d": context.home, "h": profile.host, "n": profile.alias,
            "p": String(profile.port), "r": profile.user ?? "", "u": context.localUser, "i": String(context.userID),
            "j": route, "k": profile.alias]
        var expanded = "", escaped = false
        for character in path {
            if escaped {
                guard let replacement = tokens[character], character != "r" || profile.user != nil else { throw SSHConfigurationFailure.invalidValue }
                expanded += replacement; escaped = false
            } else if character == "%" { escaped = true }
            else { expanded.append(character) }
            guard expanded.utf8.count <= 4096 else { throw SSHConfigurationFailure.capacity }
        }
        guard !escaped, !expanded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SSHConfigurationFailure.invalidValue }
        if expanded == "~" { expanded = context.home }
        else if expanded.hasPrefix("~/") { expanded = context.home + String(expanded.dropFirst()) }
        else if expanded.hasPrefix("~") { throw SSHConfigurationFailure.invalidValue }
        if !expanded.hasPrefix("/") {
            guard let working = context.workingDirectory, working.hasPrefix("/"), working.utf8.count <= 4096 else { throw SSHConfigurationFailure.invalidValue }
            expanded = working + "/" + expanded
        }
        var components: [Substring] = []
        for component in expanded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw SSHConfigurationFailure.invalidValue }; components.removeLast()
            } else { components.append(component) }
        }
        let result = "/" + components.joined(separator: "/")
        guard !components.isEmpty, components.count <= 64, result.utf8.count <= 4096,
              components.allSatisfy({ $0.utf8.count <= 255 }) else { throw SSHConfigurationFailure.capacity }
        return result
    }
}
