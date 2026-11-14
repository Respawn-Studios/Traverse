import Darwin
import Foundation

internal struct CoreSelectionGroupOutcome: Sendable {
    let id: UUID
    /// Last acknowledged value only. After any failure, inspection must reopen storage.
    let lastAcknowledged: SelectionGroupRecord
    let failure: FileOperationStatus?
    var succeeded: Bool { failure == nil }
}

extension RecoverableFileOperations {
    internal func upgradeSelectionGroupHistory(backup: URL) async throws {
        try await worker { cancellation in
            let inspection = try OperationHistoryInspector.inspect(self.directory, cancellation: cancellation)
            guard case .available(let version) = inspection.readiness, [3,4].contains(version),
                  inspection.refusedEntries.isEmpty else { throw FileOperationFailure.recoveryUncertain }
            let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
            try journal.upgradeForSelectionGroup(backup: backup)
        }
    }

    internal func prepareSelectionGroup(sources: [URL], name: String) async throws -> CoreSelectionGroupPlan {
        try await worker { cancellation in
            guard (1...512).contains(sources.count), let first = sources.first else { throw FileOperationFailure.invalidRequest }
            try validateName(name)
            let parent = try DirectoryAnchor(first.deletingLastPathComponent(), resolve: false)
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.requireDirectory(parent); try protection.requireEntry(parent: parent, name: name)
            guard let volume = try NativeRenameVolume.qualified(in: parent) else { throw FileOperationFailure.unsupported }
            try requireAbsent(name, in: parent.fd)
            let members = try sources.map { url in
                try cancellation.check()
                guard url.isFileURL, url == url.standardizedFileURL, url.deletingLastPathComponent() == parent.url else { throw FileOperationFailure.invalidRequest }
                try protection.requireEntry(parent: parent, name: url.lastPathComponent)
                return try NativeRenameEntry.observe(parent: parent, name: url.lastPathComponent)
            }
            let history = try SelectionGroupHistoryIdentity(self.directory)
            let id = UUID()
            try SelectionGroupManifest(owner: UUID(), id: id, createdAt: Date(), parent: parent.url,
                parentIdentity: parent.identity, volume: volume, folderName: Data(name.utf8),
                areaName: ".mac-explorer-selection-" + id.uuidString, members: members).validate()
            try parent.validate(); try volume.validate(in: parent)
            return CoreSelectionGroupPlan(parent: parent.url, parentIdentity: parent.identity, volume: volume,
                members: members, folderName: Data(name.utf8), engine: self.continuationSession, use: ContinuationUse(), history: history)
        }
    }

    internal func performSelectionGroup(_ plan: CoreSelectionGroupPlan, progress: OperationProgressReporter? = nil) async throws -> CoreSelectionGroupOutcome {
        guard plan.engine == continuationSession else { throw FileOperationFailure.invalidRequest }
        try plan.use.claim()
        return try await worker(progress: progress) { cancellation in
            guard let history = plan.history else { throw FileOperationFailure.invalidRequest }
            try history.validate(self.directory)
            let parent = try DirectoryAnchor(plan.parent, resolve: false)
            guard parent.identity.sameObject(as: plan.parentIdentity) else { throw FileOperationFailure.destinationChanged }
            try plan.volume.validate(in: parent)
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.requireDirectory(parent)
            for entry in plan.members {
                try cancellation.check(); try protection.requireEntry(parent: parent, name: entry.name)
                let now = try NativeRenameEntry.observe(parent: parent, name: entry.name)
                guard now == entry else { throw FileOperationFailure.sourceChanged }
            }
            try requireAbsent(String(decoding: plan.folderName, as: UTF8.self), in: parent.fd)
            let inspection = try OperationHistoryInspector.inspect(self.directory, cancellation: cancellation)
            guard [OperationHistoryReadiness.available(catalogVersion: 7), .available(catalogVersion: 9), .available(catalogVersion: 10)].contains(inspection.readiness), inspection.refusedEntries.isEmpty else { throw FileOperationFailure.recoveryUncertain }
            try self.hooks.selectionGroup.checkpoint?("beforeHistoryWriter", plan.jobID, nil)
            let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation, existingSelectionHistory: history)
            try self.hooks.selectionGroup.checkpoint?("afterHistoryWriter", plan.jobID, nil)
            try protection.historyOpened(journal.anchor)
            let id = plan.jobID, manifest = SelectionGroupManifest(owner: journal.owner, id: id, createdAt: Date(),
                parent: plan.parent, parentIdentity: plan.parentIdentity, volume: plan.volume, folderName: plan.folderName,
                areaName: ".mac-explorer-selection-" + id.uuidString, members: plan.members)
            var record = try journal.beginSelectionGroup(manifest)
            do {
                try self.selectionCheckpoint("afterManifest", record)
                try cancellation.check(); try protection.requireEntry(parent: parent, name: manifest.areaName)
                try journal.validateSelectionOwnership()
                guard mkdirat(parent.fd, manifest.areaName, 0o700) == 0 else { throw posixFailure() }
                let area = try DirectoryAnchor(manifest.area, resolve: false)
                let (markerFD, markerIdentity) = try self.selectionCreateMarker(manifest, area: area)
                defer { close(markerFD) }
                guard mkdirat(area.fd, "candidate", 0o755) == 0 else { throw posixFailure() }
                let candidate = try DirectoryAnchor(manifest.area.appendingPathComponent("candidate"), resolve: false)
                try syncDirectory(candidate); try syncDirectory(area); try syncDirectory(parent)
                try self.selectionCheckpoint("afterCreationBeforeReceipt", record)
                try parent.validate(); try area.validate(); try candidate.validate()
                let created = try NativeRenameEntry.observe(parent: area, name: "candidate")
                guard created.identity.sameObject(as: candidate.identity),
                      try self.selectionChildren(candidate, cancellation: cancellation).isEmpty else { throw FileOperationFailure.sourceChanged }
                try candidate.validate(); try area.validate()
                let marker = try NativeRenameEntry.observe(parent: area, name: "owner")
                guard marker.identity.sameObject(as: markerIdentity), try EntrySnapshot(fd: markerFD).sameObject(as: markerIdentity) else { throw FileOperationFailure.sourceChanged }
                record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .created, entry: created, area: area.identity, marker: marker))
                record = try self.selectionEdge(record, edge: .publish, journal: journal, protection: protection, cancellation: cancellation)
                cancellation.progress?.begin(.publishing, source: manifest.parent, destination: manifest.folder, items: manifest.members.count)
                for ordinal in manifest.members.indices {
                    try cancellation.check()
                    record = try self.selectionEdge(record, edge: .move(ordinal), journal: journal, protection: protection, cancellation: cancellation)
                    cancellation.progress?.advance(items: 1)
                }
                try self.selectionValidateFrontier(record, allowAdditional: false, cancellation: cancellation.draining())
                record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .finish))
                return CoreSelectionGroupOutcome(id: id, lastAcknowledged: record, failure: nil)
            } catch {
                return CoreSelectionGroupOutcome(id: id, lastAcknowledged: record, failure: operationStatus(error))
            }
        }
    }

    internal func reviewSelectionGroup(_ id: UUID) async throws -> CoreSelectionGroupReview {
        try await worker { cancellation in
            let history = try SelectionGroupHistoryIdentity(self.directory)
            guard case .selectionGroupV2(let record) = try OperationHistoryInspector.record(self.directory, id: id, cancellation: cancellation, selectionHistory: history) else { throw FileOperationFailure.invalidRequest }
            let state = try record.project()
            let pending = state.pending.map { self.selectionObserved(record, edge: $0) }
            var extra = false, problem: SelectionGroupObservedLocation?
            if state.container == .publicFolder, state.pending != .retire,
               ![.cleanupPending, .cleaned, .closedRetained].contains(state.state) {
                do { extra = try self.selectionValidateFrontier(record, allowAdditional: true, cancellation: cancellation) }
                catch is CancellationError { throw CancellationError() }
                catch { problem = self.selectionObservationFailure(error) }
            }
            return CoreSelectionGroupReview(record: record, pendingLocation: pending, additionalItems: extra, problem: problem,
                engine: self.continuationSession, use: ContinuationUse(), history: history)
        }
    }

    /// Explicit review never repeats a forward rename. It records the currently
    /// proven side after revalidation and both-directory sync, marked confirmed.
    internal func confirmSelectionGroupDisposition(_ review: CoreSelectionGroupReview) async throws -> SelectionGroupRecord {
        guard review.engine == continuationSession else { throw FileOperationFailure.invalidRequest }
        try review.use.claim()
        return try await worker { cancellation in
            guard let history = review.history else { throw FileOperationFailure.invalidRequest }
            try history.validate(self.directory)
            try self.hooks.selectionGroup.checkpoint?("beforeHistoryWriter", review.record.manifest.id, nil)
            let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation, existingSelectionHistory: history)
            try self.hooks.selectionGroup.checkpoint?("afterHistoryWriter", review.record.manifest.id, nil)
            let record = try journal.selectionGroup(review.record.manifest.id)
            guard record == review.record, let edge = try record.project().pending,
                  let location = review.pendingLocation, [.original, .destination].contains(location),
                  self.selectionObserved(record, edge: edge) == location else { throw FileOperationFailure.sourceChanged }
            let pair = try self.selectionPair(record, edge: edge)
            try self.selectionCheckPair(record, pair: pair)
            try syncDirectory(pair.source); try syncDirectory(pair.destination)
            guard self.selectionObserved(record, edge: edge) == location else { throw FileOperationFailure.recoveryUncertain }
            if edge == .retire, location == .destination {
                let retained = try DirectoryAnchor(pair.destination.url.appendingPathComponent(pair.to), resolve: false)
                guard retained.identity.sameObject(as: pair.expected.identity),
                      try self.selectionChildren(retained, cancellation: cancellation).isEmpty else { throw FileOperationFailure.conflict }
                try retained.validate()
            }
            var event: SelectionGroupEvent
            if location == .destination {
                let now = try NativeRenameEntry.observe(parent: pair.destination, name: pair.to)
                event = SelectionGroupEvent(kind: pair.outcome, ordinal: pair.ordinal, entry: now, confirmed: true)
            } else {
                let kind: SelectionGroupEventKind
                switch edge { case .publish: kind = .publicationAtOriginal; case .move: kind = .moveAtOriginal; case .restore: kind = .returnAtGroup; case .retire: kind = .retireAtPublic }
                event = SelectionGroupEvent(kind: kind, ordinal: pair.ordinal, confirmed: true)
            }
            return try journal.appendSelectionGroup(record, event)
        }
    }

    internal func undoSelectionGroup(_ review: CoreSelectionGroupReview, progress: OperationProgressReporter? = nil) async throws -> CoreSelectionGroupOutcome {
        guard review.engine == continuationSession else { throw FileOperationFailure.invalidRequest }
        try review.use.claim()
        return try await worker(progress: progress) { cancellation in
            guard let history = review.history else { throw FileOperationFailure.invalidRequest }
            try history.validate(self.directory)
            try self.hooks.selectionGroup.checkpoint?("beforeHistoryWriter", review.record.manifest.id, nil)
            let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation, existingSelectionHistory: history)
            try self.hooks.selectionGroup.checkpoint?("afterHistoryWriter", review.record.manifest.id, nil)
            var record = try journal.selectionGroup(review.record.manifest.id)
            guard record == review.record, try record.project().pending == nil else { throw FileOperationFailure.sourceChanged }
            let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
            try protection.historyOpened(journal.anchor)
            do {
                var state = try record.project()
                if state.container == .privateCandidate {
                    guard state.canCloseUnpublished, record.maximumEvents - record.events.count >= 4 else { throw FileOperationFailure.invalidRequest }
                    let area = try self.selectionArea(record)
                    let entry = try NativeRenameEntry.observe(parent: area, name: "candidate")
                    guard let expected = state.containerEntry, entry.sameEntry(as: expected), entry.nameBytes == expected.nameBytes else { throw FileOperationFailure.sourceChanged }
                    try self.selectionCheckpoint("beforeUnpublishedOpen", record)
                    let folder = try DirectoryAnchor(record.manifest.area.appendingPathComponent("candidate"), resolve: false)
                    guard folder.identity.sameObject(as: expected.identity),
                          try self.selectionChildren(folder, cancellation: cancellation).isEmpty else { throw FileOperationFailure.sourceChanged }
                    try self.selectionCheckpoint("afterUnpublishedEmpty", record)
                    try folder.validate(); try area.validate()
                    guard try self.selectionChildren(folder, cancellation: cancellation).isEmpty else { throw FileOperationFailure.conflict }
                    record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .closeUnpublished))
                    return CoreSelectionGroupOutcome(id: record.manifest.id, lastAcknowledged: record, failure: nil)
                }
                _ = try self.selectionValidateFrontier(record, allowAdditional: true, cancellation: cancellation)
                if state.state != .undoing && state.state != .membersRestored {
                    record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .beginUndo))
                }
                cancellation.progress?.begin(.retaining, source: record.manifest.folder, destination: record.manifest.parent, items: state.memberPhases.filter { $0 == .grouped }.count)
                while let ordinal = try record.project().memberPhases.lastIndex(of: .grouped) {
                    try cancellation.check()
                    record = try self.selectionEdge(record, edge: .restore(ordinal), journal: journal, protection: protection, cancellation: cancellation)
                    cancellation.progress?.advance(items: 1)
                }
                state = try record.project()
                if state.state != .membersRestored { record = try journal.appendSelectionGroup(record, SelectionGroupEvent(kind: .membersRestored)) }
                let extras = try self.selectionValidateFrontier(record, allowAdditional: true, cancellation: cancellation)
                guard !extras else { throw FileOperationFailure.conflict }
                record = try self.selectionEdge(record, edge: .retire, journal: journal, protection: protection, cancellation: cancellation)
                return CoreSelectionGroupOutcome(id: record.manifest.id, lastAcknowledged: record, failure: nil)
            } catch { return CoreSelectionGroupOutcome(id: record.manifest.id, lastAcknowledged: record, failure: operationStatus(error)) }
        }
    }

    private struct SelectionPair {
        let source: DirectoryAnchor
        let destination: DirectoryAnchor
        let from: String
        let to: String
        let expected: NativeRenameEntry
        let intent: SelectionGroupEventKind
        let outcome: SelectionGroupEventKind
        let ordinal: Int?
    }
    private func selectionCreateMarker(_ manifest: SelectionGroupManifest, area: DirectoryAnchor) throws -> (Int32, EntrySnapshot) {
        let fd = openat(area.fd, "owner", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        do {
            let data = Data((manifest.owner.uuidString + ":" + manifest.id.uuidString).utf8)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                    guard count > 0 else { throw posixFailure() }; offset += count
                }
            }
            guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw posixFailure() }
            let identity = try EntrySnapshot(fd: fd)
            try syncDirectory(area); try area.validate()
            return (fd, identity)
        } catch { close(fd); throw error }
    }
    internal func selectionParent(_ record: SelectionGroupRecord) throws -> DirectoryAnchor {
        let parent = try DirectoryAnchor(record.manifest.parent, resolve: false)
        guard parent.identity.sameObject(as: record.manifest.parentIdentity) else { throw FileOperationFailure.destinationChanged }
        try record.manifest.volume.validate(in: parent); return parent
    }
    internal func selectionArea(_ record: SelectionGroupRecord) throws -> DirectoryAnchor {
        let state = try record.project(), area = try DirectoryAnchor(record.manifest.area, resolve: false)
        guard let identity = state.area, area.identity.sameObject(as: identity) else { throw FileOperationFailure.sourceChanged }
        var st = stat()
        guard fstat(area.fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & 0o077 == 0,
              try OperationJournal.read(name: "owner", anchor: area) == Data((record.manifest.owner.uuidString + ":" + record.manifest.id.uuidString).utf8) else { throw FileOperationFailure.recoveryUncertain }
        let marker = try NativeRenameEntry.observe(parent: area, name: "owner")
        guard state.marker.map({ marker.sameEntry(as: $0) && marker.nameBytes == $0.nameBytes }) == true else { throw FileOperationFailure.sourceChanged }
        try record.manifest.volume.validate(in: area); return area
    }
    internal func selectionFolder(_ record: SelectionGroupRecord) throws -> DirectoryAnchor {
        let parent = try selectionParent(record), state = try record.project()
        guard let expected = state.containerEntry, state.container == .publicFolder else { throw FileOperationFailure.recoveryUncertain }
        let observed = try NativeRenameEntry.observe(parent: parent, name: record.manifest.folder.lastPathComponent)
        guard observed.sameEntry(as: expected), observed.nameBytes == expected.nameBytes else { throw FileOperationFailure.sourceChanged }
        let folder = try DirectoryAnchor(record.manifest.folder, resolve: false)
        guard folder.identity.sameObject(as: expected.identity) else { throw FileOperationFailure.sourceChanged }
        try record.manifest.volume.validate(in: folder); return folder
    }
    private func selectionPair(_ record: SelectionGroupRecord, edge: SelectionGroupEdge) throws -> SelectionPair {
        let state = try record.project(), parent = try selectionParent(record)
        switch edge {
        case .publish:
            return SelectionPair(source: try selectionArea(record), destination: parent, from: "candidate", to: record.manifest.folder.lastPathComponent,
                expected: state.containerEntry!, intent: .publishIntent, outcome: .published, ordinal: nil)
        case .move(let ordinal):
            return SelectionPair(source: parent, destination: try selectionFolder(record), from: record.manifest.members[ordinal].name,
                to: record.manifest.members[ordinal].name, expected: record.manifest.members[ordinal], intent: .moveIntent, outcome: .moved, ordinal: ordinal)
        case .restore(let ordinal):
            return SelectionPair(source: try selectionFolder(record), destination: parent, from: record.manifest.members[ordinal].name,
                to: record.manifest.members[ordinal].name, expected: state.memberEntries[ordinal], intent: .returnIntent, outcome: .returned, ordinal: ordinal)
        case .retire:
            return SelectionPair(source: parent, destination: try selectionArea(record), from: record.manifest.folder.lastPathComponent, to: "retained",
                expected: state.containerEntry!, intent: .retireIntent, outcome: .retired, ordinal: nil)
        }
    }
    private func selectionCheckPair(_ record: SelectionGroupRecord, pair: SelectionPair) throws {
        try pair.source.validate(); try pair.destination.validate()
        try record.manifest.volume.validate(in: pair.source); try record.manifest.volume.validate(in: pair.destination)
        _ = try selectionParent(record); _ = try selectionArea(record)
    }
    private func selectionObserved(_ record: SelectionGroupRecord, edge: SelectionGroupEdge) -> SelectionGroupObservedLocation {
        do {
            let pair = try selectionPair(record, edge: edge)
            try selectionCheckPair(record, pair: pair)
            let old = try NativeRenameEntry.optional(parent: pair.source, name: pair.from)
            let new = try NativeRenameEntry.optional(parent: pair.destination, name: pair.to)
            if let old, new == nil {
                try SelectionGroupRecord.requireTransition(pair.expected, old, parent: pair.source.identity, name: Data(pair.from.utf8)); return .original
            }
            if let new, old == nil {
                try SelectionGroupRecord.requireTransition(pair.expected, new, parent: pair.destination.identity, name: Data(pair.to.utf8)); return .destination
            }
            return old != nil && new != nil ? .conflict : .unavailable
        } catch { return selectionObservationFailure(error) }
    }
    internal func selectionObservationFailure(_ error: Error) -> SelectionGroupObservedLocation {
        switch error as? FileOperationFailure {
        case .accessDenied: return .denied
        case .unavailable: return .disconnectedOrUnavailable
        case .unsupported: return .unsupported
        case .sourceChanged, .destinationChanged, .notFound: return .changed
        case .conflict: return .conflict
        case .ioFailure: return .unreadable
        default: return .unavailable
        }
    }
    @discardableResult private func selectionValidateFrontier(_ record: SelectionGroupRecord, allowAdditional: Bool, cancellation: OperationCancellation) throws -> Bool {
        let state = try record.project(), parent = try selectionParent(record), folder = try selectionFolder(record)
        _ = try selectionArea(record)
        var names = Set<Data>()
        for ordinal in record.manifest.members.indices {
            try cancellation.check()
            if state.pending == .move(ordinal) || state.pending == .restore(ordinal) { continue }
            let grouped = state.memberPhases[ordinal] == .grouped
            if allowAdditional && !grouped { continue }
            let expected = grouped ? state.memberEntries[ordinal] : record.manifest.members[ordinal]
            let current = try NativeRenameEntry.observe(parent: grouped ? folder : parent, name: expected.name)
            try SelectionGroupRecord.requireTransition(expected, current, parent: grouped ? folder.identity : parent.identity, name: expected.nameBytes)
            try requireAbsent(expected.name, in: grouped ? parent.fd : folder.fd)
            if grouped { names.insert(expected.nameBytes) }
        }
        // Only the app-created container's immediate entries are enumerated.
        // The content or descendants of each selected root remain opaque.
        let actual = Set(try selectionChildren(folder, cancellation: cancellation).map { Data($0.utf8) })
        let extras = !actual.subtracting(names).isEmpty
        if !allowAdditional && extras { throw FileOperationFailure.conflict }
        try folder.validate(); try parent.validate(); return extras
    }
    internal func selectionChildren(_ folder: DirectoryAnchor, cancellation: OperationCancellation) throws -> [String] {
        try GroupedCopyFilesystemEvidence.children(in: folder, cancellation: cancellation, limit: 1024)
    }
    internal func selectionCheckpoint(_ stage: String, _ record: SelectionGroupRecord, _ ordinal: Int? = nil) throws {
        try hooks.selectionGroup.checkpoint?(stage, record.manifest.id, ordinal)
    }
    private func selectionEdge(_ old: SelectionGroupRecord, edge: SelectionGroupEdge, journal: OperationJournal,
                               protection: HistoryProtection, cancellation: OperationCancellation) throws -> SelectionGroupRecord {
        let pair = try selectionPair(old, edge: edge)
        try selectionCheckPair(old, pair: pair)
        // The whole affected frontier is an edge guard, not just a final check.
        // Tail/restored entries have no remaining inverse obligation; selected
        // directory descendants remain opaque. No unqualified change witness.
        if edge != .publish {
            let extra = try selectionValidateFrontier(old, allowAdditional: true, cancellation: cancellation)
            if case .move = edge, extra { throw FileOperationFailure.conflict }
        }
        if edge == .publish {
            let candidate = try DirectoryAnchor(pair.source.url.appendingPathComponent(pair.from), resolve: false)
            guard candidate.identity.sameObject(as: pair.expected.identity),
                  try selectionChildren(candidate, cancellation: cancellation).isEmpty else { throw FileOperationFailure.sourceChanged }
            try candidate.validate()
        }
        if edge == .retire {
            let folder = try selectionFolder(old)
            guard try selectionChildren(folder, cancellation: cancellation).isEmpty else { throw FileOperationFailure.conflict }
        }
        try cancellation.check(); try protection.requireEntry(parent: pair.source, name: pair.from)
        try protection.requireEntry(parent: pair.destination, name: pair.to)
        guard selectionObserved(old, edge: edge) == .original else { throw FileOperationFailure.sourceChanged }
        let pinned = try pinEntry(parent: pair.source.fd, name: pair.from, matching: pair.expected.identity)
        defer { close(pinned) }
        try old.reserveEdge(edge)
        try journal.reserveSelectionCapacity(old)
        try selectionCheckpoint("beforeIntent", old, pair.ordinal)
        let intent = try journal.appendSelectionGroup(old, SelectionGroupEvent(kind: pair.intent, ordinal: pair.ordinal))
        try selectionCheckpoint("afterIntent", intent, pair.ordinal)
        try cancellation.check(); try selectionCheckPair(intent, pair: pair)
        guard try EntrySnapshot(fd: pinned).sameObject(as: pair.expected.identity), selectionObserved(intent, edge: edge) == .original else { throw FileOperationFailure.sourceChanged }
        try protection.requireEntry(parent: pair.source, name: pair.from); try protection.requireEntry(parent: pair.destination, name: pair.to)
        // Intent durability and its observers must not make an earlier empty
        // observation authorize publication/retirement of a newly nonempty folder.
        if edge == .publish || edge == .retire {
            let container = try DirectoryAnchor(pair.source.url.appendingPathComponent(pair.from), resolve: false)
            guard container.identity.sameObject(as: pair.expected.identity),
                  try selectionChildren(container, cancellation: cancellation).isEmpty else { throw FileOperationFailure.conflict }
            try container.validate(); try selectionCheckPair(intent, pair: pair)
        }
        try hooks.beforeExclusiveRename?(pair.source.url.appendingPathComponent(pair.from), pair.destination.url.appendingPathComponent(pair.to))
        try journal.validateSelectionOwnership()
        try cancellation.beginMutation()
        try exclusiveRename(from: pair.source.fd, name: pair.from, to: pair.destination.fd, name: pair.to)
        try selectionCheckpoint("afterNative", intent, pair.ordinal)
        guard selectionObserved(intent, edge: edge) == .destination,
              try EntrySnapshot(fd: pinned).sameObject(as: pair.expected.identity) else { throw FileOperationFailure.recoveryUncertain }
        try selectionCheckpoint("beforeSourceSync", intent, pair.ordinal)
        try hooks.beforeSync?(pair.source.url); try syncDirectory(pair.source)
        try selectionCheckpoint("beforeDestinationSync", intent, pair.ordinal)
        try hooks.beforeSync?(pair.destination.url); try syncDirectory(pair.destination)
        try selectionCheckPair(intent, pair: pair)
        guard selectionObserved(intent, edge: edge) == .destination,
              try EntrySnapshot(fd: pinned).sameObject(as: pair.expected.identity) else { throw FileOperationFailure.recoveryUncertain }
        if edge == .retire {
            let retired = try DirectoryAnchor(pair.destination.url.appendingPathComponent(pair.to), resolve: false)
            guard try selectionChildren(retired, cancellation: cancellation.draining()).isEmpty else { throw FileOperationFailure.recoveryUncertain }
        }
        let result = try NativeRenameEntry.observe(parent: pair.destination, name: pair.to)
        try selectionCheckpoint("beforeOutcome", intent, pair.ordinal)
        let next = try journal.appendSelectionGroup(intent, SelectionGroupEvent(kind: pair.outcome, ordinal: pair.ordinal, entry: result))
        try selectionCheckpoint("afterOutcome", next, pair.ordinal)
        return next
    }
}
