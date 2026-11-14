import Darwin
import Foundation

@_spi(Qualification) public enum SFTPAuthenticationChoice: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case password(SFTPPassword?)
    case keyFile(SFTPSelectedPrivateKey?, passphrase: SFTPKeyPassphrase, rememberKey: Bool, profileAlias: String?)
    case serverPrompts
    case keyFileWithServerPrompts(SFTPSelectedPrivateKey?, passphrase: SFTPKeyPassphrase, rememberKey: Bool, profileAlias: String?)
    case userCertificate(key: SFTPSelectedPrivateKey?, certificate: SFTPSelectedUserCertificate?,
                         passphrase: SFTPKeyPassphrase, rememberAccess: Bool, profileAlias: String?, serverPrompts: Bool)
    var usesServerPrompts: Bool {
        switch self {
        case .serverPrompts, .keyFileWithServerPrompts: true
        case .userCertificate(_, _, _, _, _, let prompts): prompts
        default: false
        }
    }
    var usesUserCertificate: Bool {
        if case .userCertificate = self { true } else { false }
    }
    public var description: String { "<SFTP authentication choice>" }
    public var debugDescription: String { description }
}

/// Separate from a server password. Passphrases are session-only and never
/// enter saved-server JSON, password claims, process arguments or diagnostics.
@_spi(Qualification) public struct SFTPKeyPassphrase: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let bytes: Data
    public init(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 4096, !bytes.contains(0) else { throw SFTPSessionFailure.input }
        self.bytes = bytes
    }
    public var description: String { "<SSH key passphrase>" }
    public var debugDescription: String { description }
}

/// Explicit picker/reference authority, not loaded key material. Construction
/// validates only the supplied URL; no key-body read occurs before host review.
@_spi(Qualification) public struct SFTPSelectedPrivateKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private enum Source: Sendable { case file(URL, authority: URL?), remembered(SFTPKeyAccessReference) }
    private let source: Source
    let selectionID = UUID()
    var expectedIdentity: SFTPHostKey? { if case .remembered(let reference) = source { reference.identity } else { nil } }
    public init(file: URL, accessRoot: URL? = nil) throws {
        let path = try SSHSelectedFile.path(file)
        if let accessRoot {
            let root = try SSHSelectedFile.path(accessRoot)
            guard path.hasPrefix(root == "/" ? "/" : root + "/") else { throw SSHSelectedFileFailure.invalidSelection }
        }
        source = .file(file, authority: accessRoot)
    }
    public init(reference: SFTPKeyAccessReference) throws {
        try reference.validate(); source = .remembered(reference)
    }
    public var description: String { "<selected SSH private key>" }
    public var debugDescription: String { description }
    private func resolve(_ context: SFTPVerifiedSessionContext) throws -> URL {
        switch source {
        case .file(let file, _): return file
        case .remembered(let reference):
            guard context.permitsKeyReference else { throw SFTPSessionFailure.input }
            guard try reference.matches(context.keyAccessRequest(), host: context.key, routeBinding: context.routeKeyBinding) else { throw SFTPSessionFailure.keyChanged }
            var stale = false
            let file = try URL(resolvingBookmarkData: reference.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw SSHSelectedFileFailure.changed }; _ = try SSHSelectedFile.path(file); return file
        }
    }
    func readAfterHostReview(_ context: SFTPVerifiedSessionContext, check: () throws -> Void, hooks: SSHSelectedAccessHooks = .init()) throws -> Data {
        guard !Thread.isMainThread else { throw SFTPSessionFailure.busy }; try check()
        let file = try resolve(context)
        let accessURL: URL
        if case .file(_, let root) = source { accessURL = root ?? file } else { accessURL = file }
        return try SSHSelectedFile.read(file: file, accessRoot: accessURL, maximum: 32768,
            privateKey: true, check: check, hooks: hooks)
    }
    func referenceAfterAuthentication(_ context: SFTPVerifiedSessionContext, check: () throws -> Void) throws -> SFTPKeyAccessReference {
        guard !Thread.isMainThread, context.permitsKeyReference, let identity = context.authenticatedIdentity,
              context.authenticatedSelectionID == selectionID else { throw SFTPSessionFailure.input }
        try check()
        if case .remembered(let reference) = source {
            guard reference.identity == identity, try reference.matches(context.keyAccessRequest(), host: context.key, routeBinding: context.routeKeyBinding) else { throw SFTPSessionFailure.keyChanged }
            return reference
        }
        let file = try resolve(context)
        let accessURL: URL
        if case .file(_, let root) = source { accessURL = root ?? file } else { accessURL = file }
        let active = accessURL.startAccessingSecurityScopedResource()
        defer { if active { accessURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        try check()
        return try SFTPKeyAccessReference(bookmark: bookmark, request: context.keyAccessRequest(), host: context.key, identity: identity, routeBinding: context.routeKeyBinding)
    }
    /// A successful certificate session can save its selected private key only
    /// as one half of a certificate-required method, never as a plain-key one.
    func referenceAfterCertificateAuthentication(_ context: SFTPVerifiedSessionContext,
                                                 check: () throws -> Void) throws -> SFTPKeyAccessReference {
        guard !Thread.isMainThread, context.authenticatedWithUserCertificate,
              context.authenticatedSelectionID == selectionID, let identity = context.authenticatedIdentity,
              context.routeKeyBinding == nil else { throw SFTPSessionFailure.input }
        let request = try context.certificateAccessRequest(); try check()
        if case .remembered(let reference) = source {
            guard reference.identity == identity, try reference.matches(request, host: context.key) else {
                throw SFTPSessionFailure.keyChanged
            }
            return reference
        }
        let file = try resolve(context)
        let accessURL: URL
        if case .file(_, let root) = source { accessURL = root ?? file } else { accessURL = file }
        let active = accessURL.startAccessingSecurityScopedResource()
        defer { if active { accessURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        try check()
        return try SFTPKeyAccessReference(bookmark: bookmark, request: request, host: context.key, identity: identity)
    }
}

/// Explicit OpenSSH user-certificate selection, not certificate bytes or host-CA
/// trust. Reconnect reads the selected file again; no content is cached here.
@_spi(Qualification) public struct SFTPSelectedUserCertificate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private enum Source: Sendable {
        case file(URL, renewalDirectory: URL?)
        case remembered(SFTPCertificateAccessReference)
    }
    private let source: Source
    let selectionID = UUID()
    public init(file: URL, accessRoot: URL? = nil) throws {
        let path = try SSHSelectedFile.path(file)
        guard SSHSelectedFile.validLeaf(file.lastPathComponent) else { throw SSHSelectedFileFailure.invalidSelection }
        if let accessRoot {
            let root = try SSHSelectedFile.path(accessRoot)
            guard root != "/", root == file.deletingLastPathComponent().path,
                  path == root + "/" + file.lastPathComponent else {
                throw SSHSelectedFileFailure.invalidSelection
            }
        }
        source = .file(file, renewalDirectory: accessRoot)
    }
    public init(reference: SFTPCertificateAccessReference) throws {
        try reference.validate(); source = .remembered(reference)
    }
    public var description: String { "<selected SSH user certificate>" }
    public var debugDescription: String { description }
    func readAfterHostReview(_ context: SFTPVerifiedSessionContext, keyIdentity: SFTPHostKey?,
                             check: () throws -> Void, hooks: SSHSelectedAccessHooks = .init()) throws -> Data {
        guard !Thread.isMainThread else { throw SFTPSessionFailure.busy }
        try check()
        let body: Data
        switch source {
        case .file(let file, nil):
            body = try SSHSelectedFile.read(file: file, accessRoot: nil, maximum: 8192,
                privateKey: false, check: check, hooks: hooks)
        case .file(let file, .some(let directory)):
            body = try SSHSelectedFile.read(leaf: file.lastPathComponent, in: directory, maximum: 8192,
                check: check, hooks: hooks)
        case .remembered(let reference):
            guard let keyIdentity, try reference.matches(context.request(),
                host: context.key, identity: keyIdentity) else { throw SFTPSessionFailure.keyChanged }
            var stale = false
            let directory = try URL(resolvingBookmarkData: reference.directoryBookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            guard !stale else { throw SSHSelectedFileFailure.changed }
            body = try SSHSelectedFile.read(leaf: reference.leafName, in: directory, maximum: 8192,
                check: check, hooks: hooks)
        }
        guard !body.isEmpty, !body.contains(0), String(data: body, encoding: .utf8) != nil else {
            throw SFTPSessionFailure.keyInput
        }
        return body
    }
    func referenceAfterAuthentication(_ context: SFTPVerifiedSessionContext,
                                      check: () throws -> Void) throws -> SFTPCertificateAccessReference {
        guard !Thread.isMainThread, context.authenticatedWithUserCertificate,
              context.authenticatedCertificateSelectionID == selectionID,
              let identity = context.authenticatedIdentity, context.routeKeyBinding == nil else { throw SFTPSessionFailure.input }
        let request = try context.certificateAccessRequest(); try check()
        switch source {
        case .remembered(let reference):
            guard try reference.matches(request, host: context.key, identity: identity) else { throw SFTPSessionFailure.keyChanged }
            return reference
        case .file(_, nil):
            throw SFTPCertificateAccessFailure.renewalDirectoryRequired
        case .file(let file, .some(let directory)):
            let active = directory.startAccessingSecurityScopedResource()
            defer { if active { directory.stopAccessingSecurityScopedResource() } }
            let descriptor = try SSHSelectedFile.directory(directory)
            close(descriptor)
            let bookmark = try directory.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            try check()
            return try SFTPCertificateAccessReference(directoryBookmark: bookmark, leafName: file.lastPathComponent,
                request: request, host: context.key, identity: identity)
        }
    }
}

@_spi(Qualification) public enum SFTPCertificateAccessFailure: Error, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    case renewalDirectoryRequired
    public var description: String { "<SSH certificate renewal access unavailable>" }
    public var debugDescription: String { description }
}
