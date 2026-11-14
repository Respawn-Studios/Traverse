import Foundation
@testable import DirectUpdates
import Testing

struct PublicUpdatePolicyTests {
    @Test func localUserFeedAndArchivesCannotCrossTheScopedPublicLane() throws {
        let direct = PublicUpdateEndpoint.directProduction
        let scoped = PublicUpdateEndpoint.production
        let archive = try #require(URL(string:
            "https://respawn-studios.com/products/traverse/direct-updates/archives/"
            + String(repeating: "a", count: 64) + ".dmg"))
        #expect(direct.feed.absoluteString ==
            "https://respawn-studios.com/products/traverse/direct-updates/appcast.xml")
        #expect(direct.permits(direct.feed))
        #expect(direct.permits(archive))
        #expect(!direct.permits(scoped.feed))
        #expect(!scoped.permits(direct.feed))
        #expect(scoped.maximumBytes(for: archive) == 0)
    }
    @Test func exactPublicResourcesAndBounds() throws {
        let endpoint = PublicUpdateEndpoint.production
        let note = try #require(URL(string: "https://respawn-studios.com/products/traverse/public-updates/notes/69.html"))
        let archive = try #require(URL(string: "https://respawn-studios.com/products/traverse/public-updates/archives/"
            + String(repeating: "a", count: 64) + ".dmg"))
        #expect(endpoint.feed.absoluteString == "https://respawn-studios.com/products/traverse/public-updates/appcast.xml")
        #expect(endpoint.permits(endpoint.feed))
        #expect(endpoint.permits(note))
        #expect(endpoint.permits(archive))
        #expect(endpoint.maximumBytes(for: endpoint.feed) == 2 << 20)
        #expect(endpoint.maximumBytes(for: note) == 1 << 20)
        #expect(endpoint.maximumBytes(for: archive) == 128 << 20)
    }

    @Test func privateCredentialAndAlternateResourcesAreRejected() throws {
        let endpoint = PublicUpdateEndpoint.production
        for text in [
            "http://respawn-studios.com/products/traverse/public-updates/appcast.xml",
            "https://other.example/products/traverse/public-updates/appcast.xml",
            "https://respawn-studios.com:444/products/traverse/public-updates/appcast.xml",
            "https://user:pass@respawn-studios.com/products/traverse/public-updates/appcast.xml",
            "https://respawn-studios.com/products/traverse/public-updates/appcast.xml?invitation=generated",
            "https://respawn-studios.com/products/traverse/public-updates/appcast.xml#generated",
            "https://respawn-studios.com/products/traverse/public-updates/%61ppcast.xml",
            "https://respawn-studios.com/products/traverse/public-updates/notes/../appcast.xml",
            "https://respawn-studios.com/products/traverse/public-updates/notes/069.html",
            "https://respawn-studios.com/products/traverse/public-updates/notes/" + String(repeating: "a", count: 64) + ".html",
            "https://respawn-studios.com/products/traverse/public-updates/archives/" + String(repeating: "A", count: 64) + ".dmg",
            "https://respawn-studios.com/products/traverse/updates/appcast.xml",
            "https://respawn-studios.com/products/traverse/public-updates/source.tar.gz"
        ] {
            let url = try #require(URL(string: text))
            #expect(!endpoint.permits(url))
            #expect(endpoint.maximumBytes(for: url) == 0)
        }
    }
}
