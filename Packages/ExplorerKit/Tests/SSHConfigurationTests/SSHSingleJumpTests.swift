import Foundation
import Testing
@testable import SSHConfiguration

@Suite struct SSHSingleJumpTests {
    private func config(_ text: String) throws -> SSHConfiguration {
        try .init(documents: [.init(id: "config", bytes: Data(text.utf8))], root: "config")
    }
    @Test func explicitEndpointOverridesOnlyJumpAccountAndPort() throws {
        let value = try config("""
        Host destination
          HostName private.internal.test
          User destination-account
          ProxyJump explicit@gateway:2201
        Host gateway
          HostName edge.example.test
          User ignored
          Port 2222
          IdentityFile %d/.ssh/%n-%r-%p
        """).singleJump("destination", defaultUser: "fallback")
        #expect(value.destination.host == "private.internal.test" && value.destination.user == "destination-account")
        #expect(value.jump.alias == "gateway" && value.jump.host == "edge.example.test")
        #expect(value.jump.user == "explicit" && value.jump.port == 2201 && value.jump.route == .direct)
        let context = SSHKeyPathContext(home: "/generated/home", localUser: "local", userID: 501)
        #expect(try SSHKeyPathExpansion.expand(value.jump.identityFiles[0], profile: value.jump, context: context) == "/generated/home/.ssh/gateway-explicit-2201")
        #expect(String(reflecting: value) == "<one-jump SSH connection profile>")
    }
    @Test func uriBracketedIPv6AndLiteralDefaultsStayDeclarative() throws {
        for endpoint in ["ssh://route@[2001:db8::2]:2222", "route@[2001:db8::2]:2222"] {
            let route = try config("Host target\n ProxyJump \(endpoint)\nHost *\n IdentityFile generated-key\n").singleJump("target")
            #expect(route.jump.host == "2001:db8::2" && route.jump.port == 2222 && route.jump.user == "route")
            #expect(!route.jump.hasLiteralHostEntry && route.jump.identityFiles == ["generated-key"])
        }
        let route = try config("Host target\n ProxyJump gateway\nHost gateway\n User route\n Port 2200\n").singleJump("target")
        #expect(route.jump.user == "route" && route.jump.port == 2200)
    }
    @Test func nestedExternalAndUnresolvedRoutesNeverBecomeDirect() throws {
        for policy in ["ProxyJump another", "ProxyCommand generated-never-executed"] {
            #expect(throws: SSHJumpFailure.nestedRoute) {
                try config("Host target\n ProxyJump gateway\nHost gateway\n \(policy)\n").singleJump("target")
            }
        }
        for policy in ["Include absent", "IdentityAgent generated.sock", "HostKeyAlgorithms ssh-ed25519", "CertificateFile generated.pub"] {
            #expect(throws: SSHJumpFailure.unresolvedConfiguration) {
                try config("Host target\n ProxyJump gateway\nHost gateway\n \(policy)\n").singleJump("target")
            }
        }
        #expect(throws: SSHJumpFailure.noJump) { try config("Host target\n").singleJump("target") }
        #expect(throws: SSHJumpFailure.unresolvedConfiguration) {
            try config("Host target\n ProxyJump gateway\n IdentityAgent generated.sock\n").singleJump("target")
        }
    }
    @Test func malformedOrUnqualifiedRoutesCannotHideExtraAuthority() throws {
        for endpoint in ["first,second", "ssh://user:password@host", "user@@host", "@host", "host:", "host:0", "host:65536", "host:-1", "host/path", "ssh://host?x", "host%token", "[::1]extra", "[::1]:", "2001:db8::1", "[bad]:22", "-option"] {
            #expect(throws: (any Error).self) {
                try config("Host target\n ProxyJump \(endpoint)\n").singleJump("target")
            }
        }
    }
}
