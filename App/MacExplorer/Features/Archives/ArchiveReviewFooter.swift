import SwiftUI

/// Keep the primary action reachable when an archive review grows or uses
/// enlarged interface sizing. Completed actions can wrap independently.
struct ArchiveReviewFooter<Completed: View, Auxiliary: View, Primary: View>: View {
    let showsCompleted: Bool
    @ViewBuilder var completed: () -> Completed
    @ViewBuilder var auxiliary: () -> Auxiliary
    @ViewBuilder var primary: () -> Primary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCompleted {
                ViewThatFits(in: .horizontal) {
                    HStack(content: completed)
                    VStack(alignment: .leading, spacing: 8, content: completed)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { auxiliary(); Spacer(); primary() }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { auxiliary(); Spacer() }
                    HStack { Spacer(); primary() }
                }
            }
        }
    }
}
