import Foundation

/// The two archive workbenches retain their own plans, access and operation
/// lifetimes. This interface shares only the direct-action presentation.
@MainActor
protocol ArchiveAutomaticActionModel: AnyObject {
    var automaticActionCanSubmit: Bool { get }
    var automaticActionShouldReveal: Bool { get }
    var automaticActionSucceeded: Bool { get }
    func prepareAutomaticAction() async -> Bool
    func performAutomaticAction()
    func waitForOperation() async
}
