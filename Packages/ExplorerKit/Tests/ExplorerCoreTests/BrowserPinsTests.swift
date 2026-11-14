import ExplorerCore
import Foundation
import Testing

@Test func browserPinsRoundTripWithoutAccessOrFilesystemProbes() throws {
    var collection = BrowserPinCollection()
    let root = URL(fileURLWithPath: "/does-not-exist/Private Café/../Résumé", isDirectory: true)
    let id = try collection.add(url: root, label: "  Résumé work  ")
    let duplicate = try collection.add(url: root.standardizedFileURL, label: "Ignored duplicate label")
    #expect(id == duplicate)
    #expect(collection.pins.count == 1)
    #expect(collection.pins[0].label == "Résumé work")
    #expect(try BrowserPinCollection.decode(collection.encoded()) == collection)
    #expect(collection.pins[0].url.path == "/does-not-exist/Résumé")
}

@Test func browserPinsReorderRelabelAndForgetOnlyRequestedRecord() throws {
    var collection = BrowserPinCollection()
    let first = try collection.add(url: URL(fileURLWithPath: "/fixture/one"), label: "One")
    let second = try collection.add(url: URL(fileURLWithPath: "/fixture/two"), label: "Two")
    let third = try collection.add(url: URL(fileURLWithPath: "/fixture/three"), label: "Three")
    try collection.move(id: first, to: 2)
    #expect(collection.pins.map(\.id) == [second, third, first])
    try collection.relabel(id: second, label: "New label")
    #expect(collection.pins[0].url.path == "/fixture/two")
    #expect(collection.pins[0].label == "New label")
    try collection.remove(id: third)
    #expect(collection.pins.map(\.id) == [second, first])
    #expect(throws: BrowserPinCollection.Failure.self) { try collection.remove(id: third) }
    #expect(throws: BrowserPinCollection.Failure.self) { try collection.move(id: first, to: 2) }
}

@Test func browserPinsRejectRemoteCredentialsUnknownVersionsAndCorruption() throws {
    for text in ["https://example.com/private", "file://server/private", "file://user:password@localhost/private", "file:///private?token=x", "file:///private#fragment"] {
        let pin = BrowserPin(url: URL(string: text)!, label: "Private")
        #expect(throws: BrowserPinCollection.Failure.self) { try BrowserPinCollection(pins: [pin]).validate() }
    }
    let pin = BrowserPin(url: URL(fileURLWithPath: "/fixture"), label: "Fixture")
    #expect(throws: BrowserPinCollection.Failure.self) { try BrowserPinCollection(version: 2, pins: [pin]).validate() }
    #expect(throws: BrowserPinCollection.Failure.self) { try BrowserPinCollection(pins: [pin, pin]).validate() }
    #expect(throws: BrowserPinCollection.Failure.self) { try BrowserPinCollection.decode(Data(repeating: 0, count: BrowserPinCollection.maximumEncodedBytes + 1)) }
    #expect(throws: (any Error).self) { try BrowserPinCollection.decode(Data("invalid".utf8)) }
    let variants = [URL(fileURLWithPath: "/fixture", isDirectory: true), URL(fileURLWithPath: "/fixture", isDirectory: false)]
    #expect(throws: BrowserPinCollection.Failure.self) {
        try BrowserPinCollection(pins: variants.map { BrowserPin(url: $0, label: "Fixture") }).validate()
    }
}

@Test func browserPinsBoundCountsLabelsAndPathsWithoutTruncatingIntent() throws {
    var collection = BrowserPinCollection()
    for index in 0..<BrowserPinCollection.maximumPins {
        try collection.add(url: URL(fileURLWithPath: "/fixture/\(index)"), label: "\(index)")
    }
    let before = collection
    #expect(throws: BrowserPinCollection.Failure.self) {
        try collection.add(url: URL(fileURLWithPath: "/fixture/overflow"), label: "Overflow")
    }
    #expect(collection == before)
    for label in [" ", "line\nbreak", String(repeating: "é", count: 129)] {
        #expect(throws: BrowserPinCollection.Failure.self) { try collection.relabel(id: collection.pins[0].id, label: label) }
    }
    #expect(collection == before)
    let tooLong = BrowserPin(url: URL(fileURLWithPath: "/" + String(repeating: "x", count: BrowserPinCollection.maximumPathBytes)), label: "Long")
    #expect(throws: BrowserPinCollection.Failure.self) { try BrowserPinCollection(pins: [tooLong]).validate() }
}
