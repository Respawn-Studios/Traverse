import DiskArbitration
import Foundation

/// C callback context has process lifetime. Registrations are bounded and
/// removable; no callback can dereference a released per-scan object.
final class StartupTopologyWatch: @unchecked Sendable {
    static let shared = StartupTopologyWatch()
    private let queue = DispatchQueue(label: "MacExplorer.StartupTopology", qos: .utility)
    private let lock = NSLock()
    private var session: DASession?
    private struct Record {
        var targets: Set<String>?
        var changed = false
        var invalidation: (@Sendable () -> Void)?
    }
    private var records: [UUID: Record] = [:]
    private init() { queue.async { [self] in start() } }
    private func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        let keys = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeUUIDKey,
                    kDADiskDescriptionMediaBSDNameKey, kDADiskDescriptionMediaUUIDKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, keys, { disk, _, context in
            guard let context else { return }
            Unmanaged<StartupTopologyWatch>.fromOpaque(context).takeUnretainedValue().changed(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<StartupTopologyWatch>.fromOpaque(context).takeUnretainedValue().changed(disk)
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }
    private func changed(_ disk: DADisk) {
        let name = DADiskGetBSDName(disk).map { String(cString: $0) }
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            var callbacks: [@Sendable () -> Void] = []
            for id in Array(records.keys) {
                guard var record = records[id], !record.changed,
                      name == nil || record.targets == nil || record.targets!.contains(name!) else { continue }
                record.changed = true; records[id] = record
                if let callback = record.invalidation { callbacks.append(callback) }
            }
            return callbacks
        }
        callbacks.forEach { $0() }
    }
    func register() throws -> Registration {
        guard queue.sync(execute: { session != nil }) else { throw StartupStorageFailure.unavailable }
        return try lock.withLock {
            guard records.count < 8 else { throw StartupStorageFailure.busy }
            let id = UUID(); records[id] = Record(); return Registration(id: id, owner: self)
        }
    }
    final class Registration: @unchecked Sendable {
        let id: UUID
        private let owner: StartupTopologyWatch
        init(id: UUID, owner: StartupTopologyWatch) { self.id = id; self.owner = owner }
        deinit { _ = owner.lock.withLock { owner.records.removeValue(forKey: id) } }
        var isChanged: Bool { owner.lock.withLock { owner.records[id]?.changed ?? true } }
        func target(_ devices: Set<String>) throws {
            try owner.lock.withLock {
                guard var record = owner.records[id], !record.changed else { throw StartupStorageFailure.changed }
                record.targets = devices; owner.records[id] = record
            }
        }
        func whenInvalidated(_ callback: (@Sendable () -> Void)?) {
            let changed = owner.lock.withLock {
                guard var record = owner.records[id] else { return true }
                record.invalidation = callback; owner.records[id] = record; return record.changed
            }
            if changed { callback?() }
        }
    }
}
