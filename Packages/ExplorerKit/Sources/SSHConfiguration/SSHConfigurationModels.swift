import Foundation

/// Explicitly supplied configuration bytes, never a path to open or execute.
public struct SSHConfigurationDocument: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public let bytes: Data
    public init(id: String, bytes: Data) { self.id = id; self.bytes = bytes }
    public var description: String { "<SSH configuration document>" }
    public var debugDescription: String { description }
}

/// A file-access owner resolves Include requests. Empty complete results mean
/// an authorized pattern matched no files; unavailable does not mean empty.
public struct SSHIncludeResolution: Sendable {
    public enum State: Sendable { case complete([String]), unavailable }
    public let document: String
    public let line: Int
    public let state: State
    public init(document: String, line: Int, state: State) {
        self.document = document; self.line = line; self.state = state
    }
}

public struct SSHIncludeRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let document: String
    public let line: Int
    public let patterns: [String]
    public var description: String { "<SSH configuration include>" }
    public var debugDescription: String { description }
}

public enum SSHConfigurationFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case capacity, encoding, syntax, invalidValue, missingDocument, duplicateDocument, includeCycle, invalidAlias, cancelled
    public var description: String { "<SSH configuration could not be used>" }
    public var debugDescription: String { description }
}

/// Requirements survive resolution. A connection adapter must explicitly
/// support them; parsing a profile is not evidence that it can connect.
public enum SSHProfileRequirement: String, Sendable, Hashable, CaseIterable {
    case conditionalConfiguration, includedConfiguration, externalCommand, agent, certificate
    case algorithmPolicy, hostTrustPolicy, networkBinding, unrecognizedOption
}

public enum SSHProfileRoute: Sendable, Equatable {
    case direct
    case jump(String)
    /// The actual configured command is deliberately not retained in a profile.
    case externalCommand
}

public struct SSHResolvedProfile: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let alias: String
    public let host: String
    public let port: UInt16
    public let user: String?
    public let identityFiles: [String]
    public let certificateFiles: [String]
    public let identityAgent: String?
    public let identitiesOnly: Bool
    public let preferredAuthentications: [String]
    public let route: SSHProfileRoute
    public let requirements: Set<SSHProfileRequirement>
    public let hasLiteralHostEntry: Bool
    public var description: String { "<SSH connection profile>" }
    public var debugDescription: String { description }
}

public struct SSHProfileSummary: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let alias: String
    public let resolved: SSHResolvedProfile?
    public let failure: SSHConfigurationFailure?
    public var description: String { "<SSH profile summary>" }
    public var debugDescription: String { description }
}
