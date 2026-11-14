import Foundation
import Testing
@testable import SSHConfiguration

@Suite struct SSHConfigurationTests {
    @Test func hostnameTokensAndExplicitIdentityPathContextDoNotReadEnvironment() throws {
        let profile = try config("Host studio\n HostName %h.example.test\n User remote\n Port 2222\n IdentityFile %d/.ssh/%n-%r-%p\n").resolve("studio")
        #expect(profile.host == "studio.example.test")
        let context = SSHKeyPathContext(home: "/generated/home", localUser: "local", userID: 501)
        #expect(try SSHKeyPathExpansion.expand(profile.identityFiles[0], profile: profile, context: context) == "/generated/home/.ssh/studio-remote-2222")
        #expect(try SSHKeyPathExpansion.expand("~/.ssh/../identity-%%", profile: profile, context: context) == "/generated/home/identity-%")
        for path in ["$HOME/.ssh/key", "${HOME}/key", "~another/key", "%C", "%l", "trailing-%", "relative-key"] {
            #expect(throws: SSHConfigurationFailure.self) { try SSHKeyPathExpansion.expand(path, profile: profile, context: context) }
        }
        #expect(throws: SSHConfigurationFailure.self) { try config("Host studio\n HostName %n.example.test\n").resolve("studio") }
    }
    private func document(_ text: String, id: String = "config") -> SSHConfigurationDocument { .init(id: id, bytes: Data(text.utf8)) }
    private func config(_ text: String) throws -> SSHConfiguration { try .init(documents: [document(text)], root: "config") }

    @Test func namedProfileHasExplicitIdentityWithoutReadingOrSigning() throws {
        let value = try config("""
        Host studio
          HostName studio.example.test
          User generated
          Port 2222
          IdentityFile ~/.ssh/studio-key
          IdentitiesOnly yes
          PreferredAuthentications publickey,password
        """).resolve("studio")
        #expect(value.host == "studio.example.test" && value.user == "generated" && value.port == 2222)
        #expect(value.identityFiles == ["~/.ssh/studio-key"] && value.identitiesOnly)
        #expect(value.preferredAuthentications == ["publickey", "password"] && value.requirements.isEmpty)
        #expect(value.route == .direct && value.hasLiteralHostEntry)
        #expect(String(describing: value) == "<SSH connection profile>")
    }

    @Test func sourceOrderFirstValueAndAdditiveIdentitiesMatchSSH() throws {
        let value = try config("""
        Host *
          User first
          IdentityFile common
        Host studio
          User later
          HostName first.example.test
          IdentityFile specific
          IdentityFile common
          Port 2200
        Host STUDIO
          HostName ignored.example.test
          Port 3300
          IdentityFile last
        """).resolve("studio", defaultUser: "fallback")
        #expect(value.user == "first" && value.host == "first.example.test" && value.port == 2200)
        #expect(value.identityFiles == ["common", "specific", "last"])
    }

    @Test func positiveWildcardNegationAndCaseDoNotManufactureProfiles() throws {
        let cfg = try config("""
        Host *.test !private.test
          User wildcard
        Host alpha.test beta.test
          Port 2222
        Host private.test
          User private
        """)
        #expect(try cfg.resolve("ALPHA.TEST").user == "wildcard")
        #expect(try cfg.resolve("private.test").user == "private")
        #expect(try cfg.resolve("other.test").hasLiteralHostEntry == false)
        #expect(try cfg.profiles().map(\.alias) == ["alpha.test", "beta.test", "private.test"])
    }

    @Test func quoteCommentAssignmentAndEscapedNamesAreNotShellCode() throws {
        let cfg = try config("""
        # Generated only
        Host=studio
          HostName = example.test
          IdentityFile "a key #1"
          IdentityFile 'another key'
          IdentityFile key\\ with\\ spaces
          User generated # ignored
        """)
        let value = try cfg.resolve("studio")
        #expect(value.identityFiles == ["a key #1", "another key", "key with spaces"])
        #expect(value.user == "generated" && value.host == "example.test")
        #expect(throws: SSHConfigurationFailure.self) { try config("Host bad\n IdentityFile \"unterminated") }
        #expect(throws: SSHConfigurationFailure.self) { try config("Host bad\n IdentityFile trailing\\") }
    }

    @Test func includeRestoresParentConditionForEveryFileButKeepsAssignedOptions() throws {
        let cfg = try SSHConfiguration(documents: [
            document("Host studio\n Include conf.d/*\n Port 2201\n"),
            document("User inherited\nHost elsewhere\n Port 3300\n", id: "conf.d/first"),
            document("IdentityFile inherited-key\nHost *\n HostName included.example.test\n", id: "conf.d/second"),
        ], root: "config", includes: [.init(document: "config", line: 2, state: .complete(["conf.d/first", "conf.d/second"]))])
        let value = try cfg.resolve("studio")
        #expect(value.user == "inherited" && value.port == 2201 && value.host == "included.example.test")
        #expect(value.identityFiles == ["inherited-key"] && value.requirements.isEmpty)
        #expect(cfg.includeRequests.count == 1 && cfg.includeRequests[0].patterns == ["conf.d/*"])
    }

    @Test func inactiveIncludeCannotBecomeActiveAndMissingAuthorityIsNotEmpty() throws {
        let source = document("Host elsewhere\n Include child\nHost studio\n HostName example.test\n")
        let child = document("Host *\n User forbidden\n", id: "child")
        let cfg = try SSHConfiguration(documents: [source, child], root: "config",
            includes: [.init(document: "config", line: 2, state: .complete(["child"]))])
        #expect(try cfg.resolve("studio").user == nil)
        let unresolved = try config("Host studio\n Include unavailable\n").resolve("studio")
        #expect(unresolved.requirements.contains(.includedConfiguration))
        let absent = try SSHConfiguration(documents: [document("Host studio\n Include optional/*\n")], root: "config",
            includes: [.init(document: "config", line: 2, state: .complete([]))])
        #expect(try absent.resolve("studio").requirements.isEmpty)
    }

    @Test func cyclicIncludeAndOversizedConfigurationStopWithoutExecution() throws {
        let cfg = try SSHConfiguration(documents: [document("Host studio\nInclude config\n")], root: "config",
            includes: [.init(document: "config", line: 2, state: .complete(["config"]))])
        #expect(throws: SSHConfigurationFailure.includeCycle) { try cfg.resolve("studio") }
        #expect(throws: SSHConfigurationFailure.capacity) { try config("Host studio\nIdentityFile " + String(repeating: "x", count: 4097)) }
        #expect(throws: SSHConfigurationFailure.encoding) { try SSHConfiguration(documents: [.init(id: "config", bytes: Data([0xff]))], root: "config") }
        #expect(throws: SSHConfigurationFailure.self) { try SSHConfiguration(documents: [document("Host studio\n", id: "../config")], root: "../config") }
    }

    @Test func executableConditionalAndUnresolvedSecurityPoliciesRemainRequirements() throws {
        let cfg = try config("""
        Host studio
          ProxyCommand generated-never-executed --token=NOT-A-REAL-SECRET
          IdentityAgent /generated/agent.sock
          CertificateFile generated-cert.pub
          HostKeyAlgorithms ssh-ed25519
          UserKnownHostsFile generated-known-hosts
          BindAddress 127.0.0.1
          UnknownOption generated
        Match exec generated-never-executed
          User forbidden
        """)
        let value = try cfg.resolve("studio")
        #expect(value.route == .externalCommand)
        #expect(value.requirements == Set(SSHProfileRequirement.allCases.filter { $0 != .includedConfiguration }))
        #expect(value.user == nil && !String(describing: value).contains("NOT-A-REAL-SECRET"))
    }

    @Test func matchAllResetsHostConditionAndProxyKindsObeyFirstOccurrence() throws {
        let value = try config("""
        Host unrelated
          User wrong
        Match all
          User correct
        Host studio
          ProxyJump bastion
          ProxyCommand forbidden
        """).resolve("studio")
        #expect(value.user == "correct" && value.route == .jump("bastion"))
        #expect(!value.requirements.contains(.externalCommand) && !value.requirements.contains(.conditionalConfiguration))
        #expect(try config("Host studio\n ProxyCommand none\n ProxyJump other\n").resolve("studio").route == .direct)
    }

    @Test func badOneProfileDoesNotHideTheOtherLiteralProfiles() throws {
        let values = try config("Host good\n User generated\nHost bad\n Port 99999\n").profiles()
        #expect(values.count == 2 && values.first?.alias == "bad" && values.first?.failure == .invalidValue)
        #expect(values.last?.resolved?.user == "generated" && values.last?.failure == nil)
        #expect(throws: SSHConfigurationFailure.invalidAlias) { try config("Host *\n User generated\n").resolve("$(not-a-command)") }
    }
}
