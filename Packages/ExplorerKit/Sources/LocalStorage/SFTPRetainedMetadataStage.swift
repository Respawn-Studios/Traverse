import Foundation

/// A staged write is never adopted. Only an exact canonical next-state prefix
/// proved by an ALREADY committed retirement intent can be observed read-only,
/// or discarded by explicit Resume before the operation is freshly re-proved.
final class SFTPRetainedMetadataStageAuthority: Sendable {
    private let ledger: SFTPSharedBudgetDocument?
    private init(_ ledger: SFTPSharedBudgetDocument?) { self.ledger = ledger }
    fileprivate static let ledgerRead = SFTPRetainedMetadataStageAuthority(nil)
    fileprivate static func references(_ ledger: SFTPSharedBudgetDocument) -> SFTPRetainedMetadataStageAuthority? {
        guard [2, 3].contains(ledger.format), !(ledger.retirements ?? []).isEmpty else { return nil }
        return .init(ledger)
    }
    func validate<D: RemoteSettingsDocument>(_ document: D, prefix: Data, selectedEditor: UUID? = nil) throws {
        var candidates: [Data] = []
        if let value = document as? SFTPSharedBudgetDocument, ledger == nil {
            try value.validate()
            guard [2, 3].contains(value.format), value.revision < UInt64.max else { throw RemoteSettingsFailure.recoveryRequired }
            for (index, intent) in (value.retirements ?? []).enumerated() where selectedEditor == nil || intent.editor.id == selectedEditor {
                var next = value; next.revision += 1
                switch intent.stage {
                case .deleting: next.retirements?[index].stage = .retiringHistory
                case .retiringHistory: next.retirements?[index].stage = .retiringEditor
                case .retiringEditor: next.retirements?[index].stage = .releasingCharges
                case .releasingCharges:
                    for body in next.bodies.indices where intent.bodies.contains(where: { $0.reference.id == next.bodies[body].id }) { next.bodies[body].phase = .removed }
                    next.retirements?.remove(at: index)
                }
                candidates.append(try next.encoded())
            }
        } else if let ledger {
            try ledger.validate()
            for intent in ledger.retirements ?? [] where selectedEditor == nil || intent.editor.id == selectedEditor {
                if var next = document as? SFTPOriginalEditorCatalogDocument, intent.stage == .retiringEditor {
                    guard next.revision < UInt64.max, let index = next.records.firstIndex(where: { $0 == intent.editor }) else { continue }
                    next.records[index].body = nil; next.records[index].bodyID = nil; next.records[index].recovery = []; next.records[index].journals = []
                    next.records[index].phase = .closedUnused; next.revision += 1; candidates.append(try next.encoded())
                }
                if var next = document as? SFTPInPlaceJournalDocument, intent.stage == .retiringHistory {
                    let present = next.records.filter { intent.editor.journals.contains($0.id) }
                    guard !present.isEmpty, Set(present.map(\.id)) == Set(intent.saves.map(\.id)),
                          try present.allSatisfy({ record in intent.saves.contains(.init(id: record.id, digest: try SFTPRetainedRetirementIntent.digest(record))) }),
                          next.revision < UInt64.max else { continue }
                    next.records.removeAll { intent.editor.journals.contains($0.id) }; next.revision += 1; candidates.append(try next.encoded())
                }
            }
        }
        guard candidates.contains(where: { $0.starts(with: prefix) }) else { throw RemoteSettingsFailure.recoveryRequired }
    }
}
enum SFTPRetainedMetadataAccess: Equatable { case passive, explicitResume }

/// Closed intent-scoped access, never an ordinary ignore-pending Boolean.
struct SFTPRetainedMetadataStageAccess: Sendable {
    let authority: SFTPRetainedMetadataStageAuthority
    let permitsStageRetirement: Bool
    private init(_ authority: SFTPRetainedMetadataStageAuthority, resume: Bool) {
        self.authority = authority; permitsStageRetirement = resume
    }
    static let inspectCommittedLedger = Self(.ledgerRead, resume: false)
    static let resumeCommittedLedger = Self(.ledgerRead, resume: true)
    static func inspectReferences(_ ledger: SFTPSharedBudgetDocument) -> Self? {
        SFTPRetainedMetadataStageAuthority.references(ledger).map { Self($0, resume: false) }
    }
    static func resumeReferences(_ ledger: SFTPSharedBudgetDocument) -> Self? {
        SFTPRetainedMetadataStageAuthority.references(ledger).map { Self($0, resume: true) }
    }
}
