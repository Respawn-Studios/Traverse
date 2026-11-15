import Foundation

/// Catalog format and operation semantics are independent version spaces.
internal enum OperationCatalogProtocol: String, Codable, Sendable {
    case treeV1, nameRenameV2, treeV3, nameRenameV4, archiveUpdateV5, archiveStrictCloneV6, downloadAdoptionV7, ownedTrashV8, treeTrashRootAddV9, ownedTrashRootAddDeleteV10, treeNativeTrashV11, treeNativeTrashV12, archiveNativeUpdateV13, receivedPublicDownloadV14, publicZIPExtractionFileV15, publicProducedTreeV16, publicTARExtractionFileV17, tarNativeUpdateV18, groupedCopyV1, selectionGroupV2, textRevisionV3
    var version: Int {
        switch self {
        case .treeV1, .groupedCopyV1: 1
        case .nameRenameV2, .selectionGroupV2: 2
        case .treeV3, .textRevisionV3: 3
        case .nameRenameV4: 4
        case .archiveUpdateV5: 5
        case .archiveStrictCloneV6: 6
        case .downloadAdoptionV7: 7
        case .ownedTrashV8: 8
        case .treeTrashRootAddV9: 9
        case .ownedTrashRootAddDeleteV10: 10
        case .treeNativeTrashV11: 11
        case .treeNativeTrashV12: 12
        case .archiveNativeUpdateV13: 13
        case .receivedPublicDownloadV14: 14
        case .publicZIPExtractionFileV15: 15
        case .publicProducedTreeV16: 16
        case .publicTARExtractionFileV17: 17
        case .tarNativeUpdateV18: 18
        }
    }
    static func ordinary(version: Int) throws -> Self {
        switch version {
        case 1: .treeV1
        case 2: .nameRenameV2
        case 3: .treeV3
        case 4: .nameRenameV4
        case 5: .archiveUpdateV5
        case 6: .archiveStrictCloneV6
        case 7: .downloadAdoptionV7
        case 8: .ownedTrashV8
        case 9: .treeTrashRootAddV9
        case 10: .ownedTrashRootAddDeleteV10
        case 11: .treeNativeTrashV11
        case 12: .treeNativeTrashV12
        case 13: .archiveNativeUpdateV13
        case 14: .receivedPublicDownloadV14
        case 15: .publicZIPExtractionFileV15
        case 16: .publicProducedTreeV16
        case 17: .publicTARExtractionFileV17
        case 18: .tarNativeUpdateV18
        default: throw FileOperationFailure.recoveryUncertain
        }
    }
}

internal enum OperationCatalogRecord: Sendable {
    case treeV1(JournalRecord)
    case nameRenameV2(JournalRecord)
    case treeV3(JournalRecord)
    case nameRenameV4(JournalRecord)
    case archiveUpdateV5(JournalRecord)
    case archiveStrictCloneV6(JournalRecord)
    case downloadAdoptionV7(JournalRecord)
    case ownedTrashV8(JournalRecord)
    case treeTrashRootAddV9(JournalRecord)
    case ownedTrashRootAddDeleteV10(JournalRecord)
    case treeNativeTrashV11(JournalRecord)
    case treeNativeTrashV12(JournalRecord)
    case archiveNativeUpdateV13(JournalRecord)
    case receivedPublicDownloadV14(JournalRecord)
    case publicZIPExtractionFileV15(JournalRecord)
    case publicProducedTreeV16(JournalRecord)
    case publicTARExtractionFileV17(JournalRecord)
    case tarNativeUpdateV18(JournalRecord)
    case groupedCopyV1(GroupedCopyRecord)
    case selectionGroupV2(SelectionGroupRecord)
    case textRevisionV3(TextRevisionRecordV2)

    var id: UUID {
        switch self { case .treeV1(let r), .nameRenameV2(let r), .treeV3(let r), .nameRenameV4(let r), .archiveUpdateV5(let r), .archiveStrictCloneV6(let r), .downloadAdoptionV7(let r), .ownedTrashV8(let r), .treeTrashRootAddV9(let r), .treeNativeTrashV11(let r), .treeNativeTrashV12(let r), .archiveNativeUpdateV13(let r), .receivedPublicDownloadV14(let r), .publicZIPExtractionFileV15(let r), .publicProducedTreeV16(let r), .publicTARExtractionFileV17(let r), .tarNativeUpdateV18(let r), .ownedTrashRootAddDeleteV10(let r): r.id; case .groupedCopyV1(let r): r.head.id; case .selectionGroupV2(let r): r.manifest.id; case .textRevisionV3(let r): r.id }
    }
    var legacy: JournalRecord? {
        switch self { case .treeV1(let r), .nameRenameV2(let r), .treeV3(let r), .nameRenameV4(let r), .archiveUpdateV5(let r), .archiveStrictCloneV6(let r), .downloadAdoptionV7(let r), .ownedTrashV8(let r), .treeTrashRootAddV9(let r), .ownedTrashRootAddDeleteV10(let r), .treeNativeTrashV11(let r), .treeNativeTrashV12(let r), .archiveNativeUpdateV13(let r), .receivedPublicDownloadV14(let r), .publicZIPExtractionFileV15(let r), .publicProducedTreeV16(let r), .publicTARExtractionFileV17(let r), .tarNativeUpdateV18(let r): r; case .groupedCopyV1, .selectionGroupV2, .textRevisionV3: nil }
    }
    var treeRecord: JournalRecord? {
        switch self { case .treeV1(let r), .treeV3(let r): r; default: nil }
    }
}

extension TransferMetadataPolicy: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else { throw FileOperationFailure.recoveryUncertain }
        self = value
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}
