import Foundation

/// Preference associations, never filesystem or device-removal authority.
public enum VolumeProtectionLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case none, preventEject, keepMounted

    public func prevents(_ action: VolumeAction) -> Bool {
        switch action {
        case .mount: false
        case .unmount: self == .keepMounted
        case .eject, .forceUnmountAndEject: self != .none
        }
    }
}

public struct VolumeRemovalProtection: Equatable, Sendable {
    public let saved: [UUID: VolumeProtectionLevel]
    public let session: [UUID: VolumeProtectionLevel]
    public init(saved: [UUID: VolumeProtectionLevel] = [:], session: [UUID: VolumeProtectionLevel] = [:]) throws {
        guard saved.count <= 256, session.count <= 256,
              !saved.values.contains(.none), !session.values.contains(.none)
        else { throw VolumeLifecycleFailure.protectionUncertain }
        self.saved = saved; self.session = session
    }
    public static let empty = try! VolumeRemovalProtection()

    public func level(for volume: ManagedVolume) -> VolumeProtectionLevel {
        let persistent = volume.volumeUUID.flatMap { saved[$0] } ?? .none
        let temporary = session[volume.id] ?? .none
        if persistent == .keepMounted || temporary == .keepMounted { return .keepMounted }
        if persistent == .preventEject || temporary == .preventEject { return .preventEject }
        return .none
    }

    /// Call only with native-verified action members. A value here cannot prove
    /// that the caller supplied the complete physical-device scope.
    public func validate(target: ManagedVolume, action: VolumeAction, members: [ManagedVolume]) throws {
        guard action != .mount else { return }
        guard members.count <= 512, Set(members.map(\.id)).count == members.count,
              members.contains(where: { $0.id == target.id }) else { throw VolumeLifecycleFailure.protectionUncertain }
        let relevant = action == .unmount ? [target] : members
        if relevant.contains(where: { level(for: $0).prevents(action) }) { throw VolumeLifecycleFailure.userProtected }
        // A missing identity must not turn a previously saved association into
        // an implicit permission. Media/container-only records are not members.
        if !saved.isEmpty && relevant.contains(where: { $0.volumeUUID == nil && session[$0.id] == nil }) {
            throw VolumeLifecycleFailure.protectionUncertain
        }
    }
}
