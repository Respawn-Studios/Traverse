import XCTest
@testable import ExplorerCore

final class ProductCapabilitiesTests: XCTestCase {
    func testDirectPublicUsesOrdinaryOwnersForLocalQualification() {
        let direct = ProductCapabilities(edition: .directPublic)
        XCTAssertTrue(direct.edition.isDeveloperID)
        XCTAssertFalse(direct.edition.isScopedDirect)
        let allowed: [ProductCapabilities.Feature] = [.localTrashAndRestore, .authoredZIPChanges,
            .tarCreation, .archiveSingleFileExtraction, .archiveZIPTreeExtraction,
            .archiveTARTreeExtraction, .archiveTARSingleFileExtraction,
            .serverSingleFileDownloads, .serverGroupDownloads, .serverDownloads,
            .archiveInternalTransfers, .serverActions, .driveHealth, .driveHealthLiveUpdates, .archiveExternalPromises]
        for feature in allowed {
            XCTAssertTrue(direct.allows(feature), feature.rawValue)
        }
        let held: [ProductCapabilities.Feature] = [.apfsVolumeCreation, .archiveExtraction,
            .archiveMemberChanges, .nativeTrash]
        for feature in held {
            XCTAssertFalse(direct.allows(feature), feature.rawValue)
        }
        XCTAssertEqual(direct.availability(of: .driveHealth), .available)
        XCTAssertEqual(direct.availability(of: .driveHealthLiveUpdates), .available)
    }
    func testPublicReleaseRetainsTheQualifiedScopedDirectFeaturesAndHolds() {
        let beta = ProductCapabilities(edition: .privateBeta)
        let publicRelease = ProductCapabilities(edition: .publicRelease)
        XCTAssertTrue(publicRelease.edition.isScopedDirect)
        XCTAssertFalse(ProductCapabilities.Edition.preview.isScopedDirect)
        for feature in ProductCapabilities.Feature.allCases {
            XCTAssertEqual(publicRelease.availability(of: feature), beta.availability(of: feature), feature.rawValue)
        }
        XCTAssertEqual(publicRelease.availability(of: .apfsVolumeCreation), .held(.hardwareQualification))
        XCTAssertEqual(publicRelease.availability(of: .nativeTrash), .held(.fileProtection))
    }
    func testAPFSImageCreationIsDevelopmentOnly() {
        XCTAssertTrue(ProductCapabilities(edition: .development).allows(.apfsVolumeCreation))
        for edition in [ProductCapabilities.Edition.preview, .privateBeta, .appStore, .unrecognized] {
            XCTAssertFalse(ProductCapabilities(edition: edition).allows(.apfsVolumeCreation))
        }
    }
    func testNativeTARCreationIncludesDevelopmentPreviewAndPrivateBeta() {
        for edition in [ProductCapabilities.Edition.development, .preview, .privateBeta] {
            XCTAssertTrue(ProductCapabilities(edition: edition).allows(.tarCreation))
        }
        XCTAssertEqual(ProductCapabilities(edition: .appStore).availability(of: .tarCreation), .held(.fileProtection))
        XCTAssertFalse(ProductCapabilities(edition: .unrecognized).allows(.tarCreation))
    }
    func testQualifiedProductFlowsDoNotDisappearFromThePrivateBeta() {
        let preview = ProductCapabilities(edition: .preview)
        let beta = ProductCapabilities(edition: .privateBeta)
        let shared: [ProductCapabilities.Feature] = [
            .serverActions, .serverDirectoryActions, .serverMove, .serverCut,
            .serverDropUpload, .serverFolderUpload, .serverPasteUpload, .routedUpload,
            .routedEditor, .smbOriginalTextEditing, .archiveTabs, .tarBrowsing, .tarCreation, .archiveTextPreview,
            .selectionGrouping, .airDrop, .fileBenchmarks, .driveHealth, .driveHealthLiveUpdates, .serverSingleFileDownloads,
            .archiveSingleFileExtraction, .archiveZIPTreeExtraction, .archiveTARTreeExtraction,
            .archiveTARSingleFileExtraction, .authoredZIPChanges, .localTrashAndRestore, .archiveExternalPromises,
            .serverGroupDownloads, .serverDownloads, .archiveInternalTransfers
        ]
        for feature in shared {
            XCTAssertTrue(preview.allows(feature), feature.rawValue)
            XCTAssertEqual(beta.availability(of: feature), preview.availability(of: feature), feature.rawValue)
        }
        // New Preview features must be classified here rather than silently
        // disappearing from a higher-numbered beta package.
        let previewOnly: Set<ProductCapabilities.Feature> = [.archiveExtraction, .archiveMemberChanges, .nativeTrash]
        XCTAssertEqual(Set(ProductCapabilities.Feature.allCases.filter { preview.allows($0) && !beta.allows($0) }), previewOnly)
        XCTAssertEqual(Set(ProductCapabilities.Feature.allCases.filter { preview.allows($0) && beta.allows($0) }), Set(shared))
    }

    func testProtectionAndHardwareHoldsRemainExplicitAcrossPackaging() {
        for edition in [ProductCapabilities.Edition.privateBeta, .appStore] {
            let product = ProductCapabilities(edition: edition)
            for feature in [ProductCapabilities.Feature.archiveExtraction, .archiveMemberChanges, .nativeTrash] {
                XCTAssertEqual(product.availability(of: feature), .held(.fileProtection), feature.rawValue)
            }
            XCTAssertFalse(product.allows(.apfsVolumeCreation))
        }
        XCTAssertTrue(ProductCapabilities(edition: .privateBeta).allows(.driveHealth))
        XCTAssertTrue(ProductCapabilities(edition: .privateBeta).allows(.driveHealthLiveUpdates))
        XCTAssertEqual(ProductCapabilities(edition: .appStore).availability(of: .driveHealth), .held(.hardwareQualification))
        XCTAssertEqual(ProductCapabilities(edition: .appStore).availability(of: .driveHealthLiveUpdates), .held(.hardwareQualification))
        let unknown = ProductCapabilities(edition: .unrecognized)
        XCTAssertTrue(ProductCapabilities.Feature.allCases.allSatisfy { !unknown.allows($0) })
        let store = ProductCapabilities(edition: .appStore)
        XCTAssertFalse(store.allows(.serverActions))
        XCTAssertEqual(store.availability(of: .smbOriginalTextEditing), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .serverSingleFileDownloads), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .serverGroupDownloads), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .serverDownloads), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .archiveSingleFileExtraction), .held(.storeQualification))
        for feature in [ProductCapabilities.Feature.archiveZIPTreeExtraction,
                        .archiveTARTreeExtraction, .archiveTARSingleFileExtraction] {
            XCTAssertEqual(store.availability(of: feature), .held(.storeQualification))
        }
        XCTAssertEqual(store.availability(of: .authoredZIPChanges), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .localTrashAndRestore), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .archiveExternalPromises), .held(.storeQualification))
        XCTAssertEqual(store.availability(of: .archiveInternalTransfers), .held(.storeQualification))
        XCTAssertTrue(store.allows(.tarBrowsing))
    }

    func testArchiveTransferRoutesStayIndependentFromQualifiedExtractionProducers() {
        for edition in [ProductCapabilities.Edition.development, .preview] {
            let product = ProductCapabilities(edition: edition)
            XCTAssertTrue(product.allows(.archiveInternalTransfers))
            XCTAssertTrue(product.allows(.archiveExternalPromises))
        }
        let beta = ProductCapabilities(edition: .privateBeta)
        XCTAssertTrue(beta.allows(.archiveSingleFileExtraction))
        XCTAssertTrue(beta.allows(.archiveZIPTreeExtraction))
        XCTAssertTrue(beta.allows(.archiveTARTreeExtraction))
        XCTAssertTrue(beta.allows(.archiveTARSingleFileExtraction))
        XCTAssertFalse(beta.allows(.archiveExtraction))
        XCTAssertTrue(beta.allows(.archiveInternalTransfers))
        XCTAssertTrue(beta.allows(.archiveExternalPromises))
    }
}
