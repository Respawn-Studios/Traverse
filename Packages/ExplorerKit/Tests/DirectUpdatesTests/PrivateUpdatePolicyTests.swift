import Foundation
@testable import DirectUpdates
import Testing

struct PrivateUpdatePolicyTests {
    @Test func exactOriginAndClosedResourcePaths() throws {
        let endpoint = PrivateUpdateEndpoint.production
        #expect(endpoint.permits(endpoint.feed))
        #expect(endpoint.permits(URL(string:"https://respawn-studios.com/products/traverse/updates/notes/9.html")!))
        #expect(endpoint.permits(URL(string:"https://respawn-studios.com/products/traverse/updates/archives/" + String(repeating:"a",count:64) + ".dmg")!))
        for text in ["http://respawn-studios.com/products/traverse/updates/appcast.xml",
            "https://other.example/products/traverse/updates/appcast.xml",
            "https://respawn-studios.com:444/products/traverse/updates/appcast.xml",
            "https://user:pass@respawn-studios.com/products/traverse/updates/appcast.xml",
            "https://respawn-studios.com/products/traverse/updates/appcast.xml?secret=bad",
            "https://respawn-studios.com/products/traverse/updates/appcast.xml#secret",
            "https://respawn-studios.com/products/traverse/updates/%61ppcast.xml",
            "https://respawn-studios.com/products/traverse/updates/notes/../appcast.xml",
            "https://respawn-studios.com/products/traverse/preview/", "https://respawn-studios.com/products/traverse/updates/notes/09.html"] {
            #expect(!endpoint.permits(try #require(URL(string:text))))
        }
    }
    @Test func invitationIsBoundedAndNeverAddedToURLs() throws {
        for text in ["",String(repeating:"x",count:513),"generated\nsecret","generated\0secret"] {
            #expect(throws:(any Error).self) { try PrivateUpdateInvitation(text) }
        }
        let value = try PrivateUpdateInvitation("Generated-fixture-only")
        #expect(value.authorization == "Basic " + Data("traverse-beta:Generated-fixture-only".utf8).base64EncodedString())
        #expect(!PrivateUpdateEndpoint.production.feed.absoluteString.contains("Generated"))
        #expect(!String(describing:value).contains("Generated-fixture-only"))
        #expect(!String(reflecting:value).contains("Generated-fixture-only"))
    }
}
