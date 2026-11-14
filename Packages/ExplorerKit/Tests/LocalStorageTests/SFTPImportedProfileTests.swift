import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPImportedProfileTests: XCTestCase, @unchecked Sendable {
    private func imported(_ text: String) async throws -> (SSHConfigurationImport, URL) {
        let folder = try LocalStorageTestFixtures.directory()
            .appendingPathComponent("profile-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = folder.appendingPathComponent("config")
        try Data(text.utf8).write(to: config, options: .withoutOverwriting)
        let reader = SSHConfigurationReader()
        return (try await reader.load(selected: config, authorizedDirectory: folder, userSSHDirectory: folder), folder)
    }
    func testPlainProfilesSupplyTypedAddressAccountAndSuggestedKeyWithoutKeyReads() async throws {
        let (snapshot, folder) = try await imported("Host studio\n HostName %h.example.test\n User generated\n Port 2222\n IdentityFile ~/.ssh/%n\n IdentitiesOnly yes\n")
        let profiles = snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.alias, "studio"); XCTAssertEqual(profile.address?.host, "studio.example.test")
        XCTAssertEqual(profile.account, "generated"); XCTAssertFalse(profile.needsSetup)
        XCTAssertEqual(profile.identitySuggestions, [folder.appendingPathComponent(".ssh/studio")])
        XCTAssertFalse(FileManager().fileExists(atPath: profile.identitySuggestions[0].path))
        let draft = try SFTPServerDraft(name: "Fixture", address: XCTUnwrap(profile.address), account: "generated")
        try snapshot.validateConnection(alias: "studio", draft: draft, authentication: .keyFile(nil, passphrase: .init(""), rememberKey: false, profileAlias: "studio"))
        XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: .init(name: "Other", address: .init("other.example"), account: "generated"), authentication: .password(nil)))
    }
    func testExternalAgentJumpCertificateAndAlgorithmPoliciesAreNeverSilentlyDirect() async throws {
        for (option, expected): (String, SFTPProfileSetupIssue) in [
            ("ProxyCommand /usr/bin/false", .externalCommand), ("ProxyJump bastion", .jumpHost),
            ("IdentityAgent ~/generated-agent", .agent), ("CertificateFile ~/generated-cert.pub", .certificate),
            ("HostKeyAlgorithms ssh-rsa", .algorithms), ("UserKnownHostsFile ~/known_hosts", .hostTrust),
            ("Match exec generated-do-not-execute", .unresolvedConfiguration)] {
            let (snapshot, folder) = try await imported("Host studio\n HostName generated.example\n User generated\n " + option + "\n")
            let profile = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501).first)
            XCTAssertTrue(profile.issues.contains(expected)); XCTAssertTrue(profile.needsSetup)
            let draft = try SFTPServerDraft(name: "Fixture", address: .init("generated.example"), account: "generated")
            XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: draft, authentication: .password(nil)))
        }
    }
    func testUnexpandableKeyCanBeChosenExplicitlyButRestrictedAuthIsEnforced() async throws {
        let (snapshot, folder) = try await imported("Host studio\n HostName generated.example\n User generated\n IdentityFile ${UNREAD_ENV}/key\n PreferredAuthentications publickey\n")
        let profile = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501).first)
        XCTAssertEqual(profile.issues, [.keyPath]); XCTAssertFalse(profile.needsSetup); XCTAssertTrue(profile.identitySuggestions.isEmpty)
        let draft = try SFTPServerDraft(name: "Fixture", address: XCTUnwrap(profile.address), account: "generated")
        XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: draft, authentication: .password(nil)))
        try snapshot.validateConnection(alias: "studio", draft: draft, authentication: .keyFile(nil, passphrase: .init(""), rememberKey: false, profileAlias: nil))
    }
    func testCertificateProfileSuggestsPathsAndAdmitsOnlyExplicitDirectCertificateChoice() async throws {
        let (snapshot, folder) = try await imported("Host studio\n HostName generated.example\n User generated\n IdentityFile ~/.ssh/%n\n CertificateFile ~/.ssh/%n-cert.pub\n PreferredAuthentications publickey\n")
        let profile = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501).first)
        XCTAssertEqual(profile.identitySuggestions, [folder.appendingPathComponent(".ssh/studio")])
        XCTAssertEqual(profile.certificateSuggestions, [folder.appendingPathComponent(".ssh/studio-cert.pub")])
        XCTAssertTrue(profile.needsSetup)
        let draft = try SFTPServerDraft(name: "Fixture", address: XCTUnwrap(profile.address), account: "generated")
        let key = try SFTPSelectedPrivateKey(file: profile.identitySuggestions[0])
        let certificate = try SFTPSelectedUserCertificate(file: profile.certificateSuggestions[0])
        let choice = SFTPAuthenticationChoice.userCertificate(key: key, certificate: certificate,
            passphrase: try .init(""), rememberAccess: false, profileAlias: "studio", serverPrompts: false)
        XCTAssertTrue(profile.canConnect(using: choice))
        XCTAssertFalse(profile.canConnect(using: .keyFile(key, passphrase: try .init(""), rememberKey: false, profileAlias: "studio")))
        try snapshot.validateConnection(alias: "studio", draft: draft, authentication: choice)
        XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: draft,
            authentication: .keyFile(key, passphrase: .init(""), rememberKey: false, profileAlias: "studio")))
        XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: draft,
            authentication: .userCertificate(key: key, certificate: certificate, passphrase: .init(""),
                rememberAccess: false, profileAlias: "studio", serverPrompts: true)))
    }
    func testCertificateChoiceDoesNotClearIndependentAgentOrCommandHolds() async throws {
        for option in ["IdentityAgent ~/generated-agent", "ProxyCommand /usr/bin/false", "HostKeyAlgorithms ssh-rsa"] {
            let (snapshot, folder) = try await imported("Host studio\n HostName generated.example\n CertificateFile ~/.ssh/id-cert.pub\n " + option + "\n")
            let profile = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501).first)
            let choice = SFTPAuthenticationChoice.userCertificate(key: nil, certificate: nil,
                passphrase: try .init(""), rememberAccess: false, profileAlias: "studio", serverPrompts: false)
            XCTAssertFalse(profile.canConnect(using: choice))
            let draft = try SFTPServerDraft(name: "Fixture", address: XCTUnwrap(profile.address), account: "generated")
            XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: draft, authentication: choice))
        }
    }
    func testQualifiedSingleJumpAppliesBothAccountsPortsAndMethodPoliciesWithoutReadingKeys() async throws {
        let (snapshot, folder) = try await imported("""
        Host studio
          HostName target.example.test
          User target
          Port 2225
          ProxyJump gateway-user@gateway:2200
          PreferredAuthentications keyboard-interactive
        Host gateway
          HostName jump.example.test
          User overridden
          Port 22
          IdentityFile ~/.ssh/%h-%p-%r
          PreferredAuthentications publickey
        """)
        let profile = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501, serverPrompts: true, singleJump: true).first { $0.alias == "studio" })
        XCTAssertFalse(profile.needsSetup); let jump = try XCTUnwrap(profile.jump)
        XCTAssertEqual(jump.address.host, "jump.example.test"); XCTAssertEqual(jump.address.port, 2200); XCTAssertEqual(jump.account, "gateway-user")
        XCTAssertEqual(jump.identitySuggestions, [folder.appendingPathComponent(".ssh/jump.example.test-2200-gateway-user")])
        XCTAssertFalse(FileManager().fileExists(atPath: jump.identitySuggestions[0].path))
        let route = try SFTPRouteDescription(destination: .init(name: "Generated route", address: XCTUnwrap(profile.address), account: "target"),
            jump: .init(name: "Generated jump", address: jump.address, account: "gateway-user"))
        let key = SFTPAuthenticationChoice.keyFile(nil, passphrase: try .init(""), rememberKey: false, profileAlias: nil)
        try snapshot.validateRouteConnection(alias: "studio", route: route, jump: key, destination: .serverPrompts)
        XCTAssertThrowsError(try snapshot.validateRouteConnection(alias: "studio", route: route, jump: .password(nil), destination: .serverPrompts))
        XCTAssertThrowsError(try snapshot.validateRouteConnection(alias: "studio", route: route, jump: key, destination: .password(nil)))
        let changed = try SFTPRouteDescription(destination: route.destination, jump: .init(name: "Changed", address: .init("sftp://other.example.test:2200"), account: "gateway-user"))
        XCTAssertThrowsError(try snapshot.validateRouteConnection(alias: "studio", route: changed, jump: key, destination: .serverPrompts))
        XCTAssertThrowsError(try snapshot.validateConnection(alias: "studio", draft: route.destination, authentication: .serverPrompts))
        let disabled = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501, serverPrompts: true).first { $0.alias == "studio" })
        XCTAssertTrue(disabled.needsSetup); XCTAssertNil(disabled.jump)
    }
    func testEnablingSingleJumpDoesNotExecuteOrSilentlyBypassNestedCommandAndAgentRoutes() async throws {
        for option in ["ProxyJump other", "ProxyCommand /usr/bin/false", "IdentityAgent ~/generated-only-agent", "CertificateFile ~/generated-only-certificate"] {
            let (snapshot, folder) = try await imported("Host studio\n HostName target.example.test\n ProxyJump gateway\nHost gateway\n HostName jump.example.test\n " + option + "\n")
            let profile = try XCTUnwrap(snapshot.connectionProfiles(home: folder, localUser: "local", userID: 501, serverPrompts: true, singleJump: true).first { $0.alias == "studio" })
            XCTAssertTrue(profile.needsSetup); XCTAssertNil(profile.jump); XCTAssertTrue(profile.issues.contains(.jumpHost))
        }
    }
}
