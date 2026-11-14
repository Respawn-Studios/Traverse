import Foundation
import ExplorerCore
import FileOperations
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBBrowserSessionTests: XCTestCase, @unchecked Sendable {
    func testUploadWorkerKeepsUnrequestedPublicDownloadsClosed() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let address = try SMBConnectionAddress("smb://127.0.0.1:15445/Shared")
        let request = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "",
                                         security: .encrypted, transferPreference: .normal)
        let endpoint = try SMBPreparedConnection.select(address, candidates: [.init(family: .ipv4,
            addressBytes: Data([127, 0, 0, 1]), scopeID: 0, interfaceIndex: 0)])
        let metadataOwner = try SMBBrowserOwner(bundle: root.appendingPathComponent("Absent.app"), request: request,
            endpoint: endpoint, storage: SMBTemporaryStorage(directory: root.appendingPathComponent("metadata-catalogs")),
            activity: FileActivityGate(maximumActivities: 1), password: SMBPassword("generated-control-only"))
        let metadataBrowser = SMBBrowserSession(metadataOwner, exposedSelectedDownloads: false, exposedFolderDownloads: false)
        XCTAssertEqual(metadataOwner.mode, .metadata)
        XCTAssertFalse(metadataBrowser.allowsTextRead)
        let owner = try SMBBrowserOwner(bundle: root.appendingPathComponent("Absent.app"), request: request,
            endpoint: endpoint, storage: SMBTemporaryStorage(directory: root.appendingPathComponent("catalogs")),
            activity: FileActivityGate(maximumActivities: 1), password: SMBPassword("generated-control-only"),
            selectedDownloads: false, folderDownloads: false, freshUploads: true)
        let defaultCapabilities = SMBBrowserSession(owner, exposedSelectedDownloads: false, exposedFolderDownloads: false)
        XCTAssertFalse(defaultCapabilities.allowsSelectedUploads)
        XCTAssertFalse(defaultCapabilities.allowsTextRead)
        let browser = SMBBrowserSession(owner, exposedSelectedDownloads: false, exposedFolderDownloads: false,
            exposedSelectedUploads: true)
        XCTAssertEqual(owner.mode, .selectedUpload)
        XCTAssertTrue(browser.allowsSelectedUploads)
        XCTAssertFalse(browser.allowsSelectedDownloads)
        XCTAssertFalse(browser.allowsTextRead)
        XCTAssertFalse(browser.allowsFolderDownloads)

        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 2, folders: 1, state: .complete)
        let file = try SMBDownloadSelection(connection: browser.id, snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Generated.bin"), attributes: 32,
                               logicalBytes: 1, modifiedFileTime: 1))
        let folder = try SMBFolderDownloadSelection(connection: browser.id, snapshot: snapshot,
            observation: .init(id: 2, name: SMBRemoteName("GeneratedFolder"), attributes: 0x10,
                               logicalBytes: 0, modifiedFileTime: 1))
        let bodies = root.appendingPathComponent("bodies")
        let storage = try SMBDownloadStorage(directory: bodies)
        do { _ = try await browser.download(file, storage: storage); XCTFail("Unrequested file body admitted") }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .invalidInput) }
        do { _ = try await browser.openText(selected: file, storage: SMBTextReadStorage(sharing: storage)); XCTFail("Unrequested text body admitted") }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .unavailable) }
        do { _ = try await browser.prepareFolderDownload(folder); XCTFail("Unrequested folder admitted") }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .invalidInput) }
        XCTAssertFalse(FileManager().fileExists(atPath: bodies.path))
    }

    func testPrivateTextAdmissionKeepsBinaryDownloadClosedAndRejectsStaleBeforeStorage() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let address = try SMBConnectionAddress("smb://127.0.0.1:15445/Shared")
        let request = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "",
                                         security: .encrypted, transferPreference: .normal)
        let endpoint = try SMBPreparedConnection.select(address, candidates: [.init(family: .ipv4,
            addressBytes: Data([127, 0, 0, 1]), scopeID: 0, interfaceIndex: 0)])
        let owner = try SMBBrowserOwner(bundle: root.appendingPathComponent("Absent.app"), request: request,
            endpoint: endpoint, storage: SMBTemporaryStorage(directory: root.appendingPathComponent("catalogs")),
            activity: FileActivityGate(maximumActivities: 1), password: SMBPassword("generated-control-only"),
            selectedDownloads: false, textReads: true)
        let browser = SMBBrowserSession(owner, exposedSelectedDownloads: false,
            exposedFolderDownloads: false, exposedTextReads: true)
        XCTAssertEqual(owner.mode, .selectedDownload)
        XCTAssertTrue(browser.allowsTextRead)
        XCTAssertFalse(browser.allowsSelectedDownloads)
        XCTAssertFalse(browser.allowsFolderDownloads)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: browser.id, snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Generated.txt"), attributes: 32,
                               logicalBytes: 4, modifiedFileTime: 1))
        let bodies = root.appendingPathComponent("bodies")
        let downloads = try SMBDownloadStorage(directory: bodies)
        do { _ = try await browser.download(selection, storage: downloads); XCTFail("Binary Download escaped its gate") }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .invalidInput) }
        do { _ = try await browser.openText(selected: selection, storage: SMBTextReadStorage(sharing: downloads)); XCTFail("Stale text read") }
        catch { XCTAssertEqual(error as? SMBDirectoryFailure, .stale) }
        let oversized = try SMBDownloadSelection(connection: browser.id, snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Oversized.txt"), attributes: 32,
                               logicalBytes: UInt64(TextDocumentValue.maximumBytes + 1), modifiedFileTime: 1))
        do { _ = try await browser.openText(selected: oversized, storage: SMBTextReadStorage(sharing: downloads)); XCTFail("Oversized text read") }
        catch { XCTAssertEqual(error as? SMBTextFailure, .unsupported) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodies.path))
    }

    func testPrivateTextLeaseValidatesUTF8AndDrainsSharedSpool() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let body = Data("hello\r\n".utf8)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Generated.txt"), attributes: 32,
                               logicalBytes: UInt64(body.count), modifiedFileTime: 1))
        let downloads = try SMBDownloadStorage(directory: root.appendingPathComponent("bodies"))
        let file = try await downloads.store.reserve(selection)
        try await file.append(request: selection.request, offset: 0, bytes: body)
        let checked = SMBDownloadReceipt(selection: selection, receivedBytes: UInt64(body.count))
        let digest = try await file.seal(checked)
        let lease = try await SMBTextReadLease.mint(file, checked: checked, digest: digest)
        XCTAssertEqual(lease.receipt.selection, selection)
        XCTAssertEqual(lease.receipt.receivedBytes, UInt64(body.count))
        let value = try await lease.read()
        XCTAssertEqual(value.text, "hello\n")
        XCTAssertEqual(value.encoded, body)
        let held = try await downloads.inspect()
        XCTAssertEqual(held.count, 1)
        let close = await lease.closeForViewer()
        let repeatedClose = await lease.closeForViewer()
        XCTAssertEqual(close, .removed)
        XCTAssertEqual(repeatedClose, .removed)
        let after = try await downloads.inspect()
        XCTAssertTrue(after.isEmpty)

        let invalid = Data([0xff])
        let badSelection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Invalid.txt"), attributes: 32,
                               logicalBytes: 1, modifiedFileTime: 1))
        let badFile = try await downloads.store.reserve(badSelection)
        try await badFile.append(request: badSelection.request, offset: 0, bytes: invalid)
        let badChecked = SMBDownloadReceipt(selection: badSelection, receivedBytes: 1)
        let badDigest = try await badFile.seal(badChecked)
        let badLease = try await SMBTextReadLease.mint(badFile, checked: badChecked, digest: badDigest)
        do { _ = try await badLease.read(); XCTFail("Invalid UTF-8 entered the view") }
        catch { XCTAssertEqual(error as? TextDocumentFailure, .invalidUTF8) }
        let invalidClose = await badLease.closeForViewer()
        XCTAssertEqual(invalidClose, .removed)
        let afterInvalid = try await downloads.inspect()
        XCTAssertTrue(afterInvalid.isEmpty)
    }

    func testPrivateTextCloseRetainsBodyWhenCheckedRemovalFails() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .complete)
        let selection = try SMBDownloadSelection(connection: UUID(), snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("Generated.txt"), attributes: 32,
                               logicalBytes: 1, modifiedFileTime: 1))
        let downloads = try SMBDownloadStorage(directory: root.appendingPathComponent("bodies"))
        let file = try await downloads.store.reserve(selection)
        try await file.append(request: selection.request, offset: 0, bytes: Data("x".utf8))
        let checked = SMBDownloadReceipt(selection: selection, receivedBytes: 1)
        let digest = try await file.seal(checked)
        let lease = try await SMBTextReadLease.mint(file, checked: checked, digest: digest)
        _ = try await lease.read()
        let unexpected = downloads.store.directory.appendingPathComponent("download-" + file.id.uuidString)
            .appendingPathComponent("generated-unexpected.txt")
        try Data("generated fixture".utf8).write(to: unexpected, options: .withoutOverwriting)
        let close = await lease.closeForViewer()
        XCTAssertEqual(close, .retainedForReview(file.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testPrecancelClosedActivityAndInvalidRootReleaseWithoutNetworkOrCreatingState() async throws {
        let activity = FileActivityGate(maximumActivities: 1), missing = URL(fileURLWithPath: "/not-a-generated-browser")
        let password = try SMBPassword("generated-control-only")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SMBBrowserSession.connectGenerated(bundleURL: missing, generatedCase: missing, activity: activity, password: password)
        }
        do { _ = try await cancelled.value; XCTFail() } catch { XCTAssertEqual(error as? SMBBrowserFailure, .stopped) }
        XCTAssertEqual(activity.activeCount, 0)
        let token = try XCTUnwrap(activity.closeAdmission())
        do { _ = try await SMBBrowserSession.connectGenerated(bundleURL: missing, generatedCase: missing, activity: activity, password: password); XCTFail() }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .unavailable) }
        XCTAssertEqual(activity.activeCount, 0); XCTAssertTrue(activity.reopen(token))
        do { _ = try await SMBBrowserSession.connectGenerated(bundleURL: missing, generatedCase: missing, activity: activity, password: password); XCTFail() }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .invalidInput) }
        XCTAssertEqual(activity.activeCount, 0)
    }

    func testUploadWorkerFolderPreparationReachesSnapshotGuardWithoutNetwork() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let address = try SMBConnectionAddress("smb://127.0.0.1:15445/Shared")
        let request = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "",
                                         security: .encrypted, transferPreference: .normal)
        let endpoint = try SMBPreparedConnection.select(address, candidates: [.init(family: .ipv4,
            addressBytes: Data([127, 0, 0, 1]), scopeID: 0, interfaceIndex: 0)])
        let owner = try SMBBrowserOwner(bundle: root.appendingPathComponent("Absent.app"), request: request,
            endpoint: endpoint, storage: SMBTemporaryStorage(directory: root.appendingPathComponent("catalogs")),
            activity: FileActivityGate(maximumActivities: 1), password: SMBPassword("generated-control-only"),
            folderDownloads: true, freshUploads: true)
        let browser = SMBBrowserSession(owner, exposedSelectedDownloads: false, exposedFolderDownloads: true)
        XCTAssertEqual(owner.mode, .selectedUpload)
        XCTAssertTrue(browser.allowsFolderDownloads)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 1, state: .complete)
        let folder = try SMBFolderDownloadSelection(connection: browser.id, snapshot: snapshot,
            observation: .init(id: 1, name: SMBRemoteName("GeneratedFolder"), attributes: 0x10,
                               logicalBytes: 0, modifiedFileTime: 1))
        do {
            let _: SMBPreparedFolderDownload = try await withCheckedThrowingContinuation {
                owner.prepareFolder(SMBFolderPreparationAttempt(folder), continuation: $0)
            }
            XCTFail("Preparation without an admitted snapshot")
        } catch { XCTAssertEqual(error as? SMBBrowserFailure, .busy) }
    }
}
