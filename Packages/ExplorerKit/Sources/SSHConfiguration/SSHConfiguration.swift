import Foundation

/// Bounded declarative OpenSSH configuration. No filesystem, environment,
/// subprocess, DNS, private-key, agent or trust-store access is performed here.
/// A Host profile is resolved afresh against explicitly supplied Include facts.
public struct SSHConfiguration: Sendable {
    struct Line: Sendable { let number: Int; let keyword: String; let arguments: [String] }
    private let documents: [String: [Line]]
    private let includes: [String: SSHIncludeResolution.State]
    private let root: String
    public let includeRequests: [SSHIncludeRequest]

    public init(documents: [SSHConfigurationDocument], root: String,
                includes: [SSHIncludeResolution] = []) throws {
        guard !documents.isEmpty, documents.count <= 32, includes.count <= 256 else { throw SSHConfigurationFailure.capacity }
        var parsed: [String: [Line]] = [:], requests: [SSHIncludeRequest] = [], total = 0
        for document in documents {
            guard Self.validID(document.id), parsed[document.id] == nil else { throw SSHConfigurationFailure.duplicateDocument }
            guard document.bytes.count <= 256 << 10, total <= (1 << 20) - document.bytes.count else { throw SSHConfigurationFailure.capacity }
            total += document.bytes.count
            let lines = try Self.parse(document.bytes)
            parsed[document.id] = lines
            for line in lines where line.keyword == "include" {
                requests.append(.init(document: document.id, line: line.number, patterns: line.arguments))
            }
        }
        guard parsed[root] != nil else { throw SSHConfigurationFailure.missingDocument }
        var resolutions: [String: SSHIncludeResolution.State] = [:]
        for resolution in includes {
            let key = Self.includeKey(resolution.document, resolution.line)
            guard resolution.line > 0, resolutions[key] == nil,
                  parsed[resolution.document]?.contains(where: { $0.number == resolution.line && $0.keyword == "include" }) == true else {
                throw SSHConfigurationFailure.invalidValue
            }
            if case .complete(let ids) = resolution.state {
                guard ids.count <= 32, ids.allSatisfy({ parsed[$0] != nil }) else { throw SSHConfigurationFailure.missingDocument }
            }
            resolutions[key] = resolution.state
        }
        self.documents = parsed; self.includes = resolutions; self.root = root; includeRequests = requests
    }

    /// Wildcard sections provide defaults but do not manufacture a list of
    /// hosts. A literal entry reachable only through an inactive Include is not
    /// presented as a usable named profile.
    public func profiles(defaultUser: String? = nil) throws -> [SSHProfileSummary] {
        var candidates: [String] = [], seen = Set<String>()
        for id in documents.keys.sorted() {
            for line in documents[id] ?? [] where line.keyword == "host" {
                for alias in line.arguments where Self.isLiteralAlias(alias) {
                    if seen.insert(alias.lowercased()).inserted { candidates.append(alias) }
                    guard candidates.count <= 128 else { throw SSHConfigurationFailure.capacity }
                }
            }
        }
        return try candidates.sorted { $0.lowercased() < $1.lowercased() }.compactMap { alias in
            do {
                let resolved = try resolve(alias, defaultUser: defaultUser)
                return resolved.hasLiteralHostEntry ? SSHProfileSummary(alias: alias, resolved: resolved, failure: nil) : nil
            } catch SSHConfigurationFailure.cancelled { throw SSHConfigurationFailure.cancelled }
            catch let failure as SSHConfigurationFailure { return SSHProfileSummary(alias: alias, resolved: nil, failure: failure) }
        }
    }

    public func resolve(_ alias: String, defaultUser: String? = nil) throws -> SSHResolvedProfile {
        guard Self.isLiteralAlias(alias), defaultUser.map(Self.validUser) ?? true else { throw SSHConfigurationFailure.invalidAlias }
        var state = Resolution(alias: alias)
        var visited: [String] = [], files = 0
        try consume(root, active: true, neverMatch: false, stack: &visited, files: &files, state: &state)
        let rawHost = state.single["hostname"] ?? alias
        var host = "", token = false
        for character in rawHost {
            if token {
                switch character { case "%": host.append("%"); case "h": host += alias; default: throw SSHConfigurationFailure.invalidValue }
                token = false
            } else if character == "%" { token = true } else { host.append(character) }
            guard host.utf8.count <= 253 else { throw SSHConfigurationFailure.capacity }
        }
        guard !token else { throw SSHConfigurationFailure.invalidValue }
        guard Self.validHost(host) else { throw SSHConfigurationFailure.invalidValue }
        let port: UInt16
        if let text = state.single["port"] {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(text), value > 0 else {
                throw SSHConfigurationFailure.invalidValue
            }
            port = value
        } else { port = 22 }
        let user = state.single["user"] ?? defaultUser
        guard user.map(Self.validUser) ?? true else { throw SSHConfigurationFailure.invalidValue }
        let only: Bool
        switch state.single["identitiesonly"]?.lowercased() {
        case nil, "no": only = false
        case "yes": only = true
        default: throw SSHConfigurationFailure.invalidValue
        }
        let order = state.single["preferredauthentications"]?.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            ?? ["publickey", "keyboard-interactive", "password"]
        guard !order.isEmpty, order.count <= 16, order.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy { Self.asciiWord($0) || $0 == 45 } }) else {
            throw SSHConfigurationFailure.invalidValue
        }
        let agent = state.single["identityagent"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        if agent != nil { state.requirements.insert(.agent) }
        if !state.certificates.isEmpty { state.requirements.insert(.certificate) }
        return .init(alias: alias, host: host, port: port, user: user,
            identityFiles: state.identities.filter { $0.lowercased() != "none" }, certificateFiles: state.certificates,
            identityAgent: agent, identitiesOnly: only, preferredAuthentications: order,
            route: state.route ?? .direct, requirements: state.requirements, hasLiteralHostEntry: state.literal)
    }

    private struct Resolution {
        let alias: String
        var single: [String: String] = [:]
        var identities: [String] = [], certificates: [String] = []
        var route: SSHProfileRoute?
        var requirements = Set<SSHProfileRequirement>()
        var literal = false
    }

    private func consume(_ id: String, active initial: Bool, neverMatch: Bool,
                         stack: inout [String], files: inout Int, state: inout Resolution) throws {
        guard stack.count < 8, files < 64 else { throw SSHConfigurationFailure.capacity }
        guard !stack.contains(id) else { throw SSHConfigurationFailure.includeCycle }
        guard let lines = documents[id] else { throw SSHConfigurationFailure.missingDocument }
        stack.append(id); files += 1; defer { stack.removeLast() }
        var active = initial
        for line in lines {
            if Task.isCancelled { throw SSHConfigurationFailure.cancelled }
            let key = line.keyword, values = line.arguments
            if key == "host" {
                active = !neverMatch && Self.matches(values, state.alias)
                if active && values.contains(where: { Self.isLiteralAlias($0) && $0.caseInsensitiveCompare(state.alias) == .orderedSame }) { state.literal = true }
                continue
            }
            if key == "match" {
                if values.count == 1, values[0].lowercased() == "all" {
                    active = !neverMatch; continue
                }
                // Match replaces the previous Host condition. Evaluating exec,
                // localnetwork, canonical/final etc would require another
                // authority/evaluation model. Preserve uncertainty globally.
                if !neverMatch { state.requirements.insert(.conditionalConfiguration) }
                active = false
                continue
            }
            if key == "include" {
                guard active else { continue }
                guard let resolution = includes[Self.includeKey(id, line.number)] else {
                    state.requirements.insert(.includedConfiguration); continue
                }
                switch resolution {
                case .unavailable: state.requirements.insert(.includedConfiguration)
                case .complete(let ids):
                    // OpenSSH restores the parent's active state after EACH
                    // included file. Child Host state cannot leak to a sibling
                    // include or the caller's subsequent lines.
                    for child in ids { try consume(child, active: active, neverMatch: neverMatch,
                        stack: &stack, files: &files, state: &state) }
                }
                continue
            }
            guard active else { continue }
            switch key {
            case "identityfile", "certificatefile":
                guard values.count == 1 else { throw SSHConfigurationFailure.invalidValue }
                if key == "identityfile" {
                    if !state.identities.contains(values[0]) { state.identities.append(values[0]) }
                    guard state.identities.count <= 16 else { throw SSHConfigurationFailure.capacity }
                } else {
                    if !state.certificates.contains(values[0]) { state.certificates.append(values[0]) }
                    guard state.certificates.count <= 16 else { throw SSHConfigurationFailure.capacity }
                }
            case "proxyjump", "proxycommand":
                guard !values.isEmpty else { throw SSHConfigurationFailure.invalidValue }
                if state.route == nil {
                    if values.count == 1 && values[0].lowercased() == "none" { state.route = .direct }
                    else if key == "proxyjump", values.count == 1 { state.route = .jump(values[0]) }
                    else { state.route = .externalCommand; state.requirements.insert(.externalCommand) }
                }
            case "hostname", "user", "port", "identitiesonly", "preferredauthentications", "identityagent":
                guard values.count == 1 else { throw SSHConfigurationFailure.invalidValue }
                if state.single[key] == nil { state.single[key] = values[0] }
            case "localcommand", "knownhostscommand": state.requirements.insert(.externalCommand)
            case "hostkeyalgorithms", "pubkeyacceptedalgorithms", "kexalgorithms", "ciphers", "macs": state.requirements.insert(.algorithmPolicy)
            case "hostkeyalias", "stricthostkeychecking", "userknownhostsfile", "globalknownhostsfile", "verifyhostkeydns", "updatehostkeys": state.requirements.insert(.hostTrustPolicy)
            case "bindaddress", "bindinterface", "addressfamily", "canonicalizehostname", "canonicaldomains", "canonicalizefallbacklocal": state.requirements.insert(.networkBinding)
            // These interactive-shell/session preferences do not confer SFTP
            // authority. No agent/X11/port forwarding or command is performed.
            case "addkeystoagent", "usekeychain", "forwardagent", "forwardx11", "forwardx11trusted", "requesttty", "remotecommand", "sessiontype",
                 "controlmaster", "controlpath", "controlpersist", "localforward", "remoteforward", "dynamicforward",
                 "exitonforwardfailure", "compression", "serveraliveinterval", "serveralivecountmax", "tcpkeepalive", "connecttimeout", "loglevel": break
            default: state.requirements.insert(.unrecognizedOption)
            }
        }
    }

    private static func includeKey(_ id: String, _ line: Int) -> String { id + "\0" + String(line) }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 4096 && !id.hasPrefix("/") && !id.contains("\0")
            && id.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func asciiWord(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
    private static func isLiteralAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.utf8.count <= 253 && alias.utf8.allSatisfy { asciiWord($0) || [45,46,58].contains($0) }
    }
    private static func validHost(_ host: String) -> Bool {
        isLiteralAlias(host) && !host.hasPrefix("-") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }
    private static func validUser(_ user: String) -> Bool {
        !user.isEmpty && user.utf8.count <= 256 && !user.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    static func matches(_ patterns: [String], _ host: String) -> Bool {
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcard(String(pattern.dropFirst()), host) { return false }
            } else if wildcard(pattern, host) { positive = true }
        }
        return positive
    }
    private static func wildcard(_ pattern: String, _ value: String) -> Bool {
        let p = Array(pattern.lowercased().utf8), v = Array(value.lowercased().utf8)
        var i = 0, j = 0, star: Int?, backtrack = 0
        while j < v.count {
            if i < p.count && (p[i] == 63 || p[i] == v[j]) { i += 1; j += 1 }
            else if i < p.count && p[i] == 42 { star = i; i += 1; backtrack = j }
            else if let star { backtrack += 1; j = backtrack; i = star + 1 }
            else { return false }
        }
        while i < p.count && p[i] == 42 { i += 1 }
        return i == p.count
    }
}
