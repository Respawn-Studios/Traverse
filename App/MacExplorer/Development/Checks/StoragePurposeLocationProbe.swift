#if DEBUG
import AppKit
import SwiftUI

/// Frame evidence only for the exact generated qualification window. Never
/// supplies a click target, filesystem identity or product operation authority.
@MainActor enum StoragePurposeLocationProbe {
    static var enabled = false
    static let views = NSHashTable<StoragePurposeReviewView>.weakObjects()
    static func visibleReview(node: UInt64, window: NSWindow) -> Bool {
        views.allObjects.contains { view in
            guard view.node == node, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 40, view.bounds.height > 15 else { return false }
            let visible = view.visibleRect
            guard visible.width >= view.bounds.width - 1, visible.height >= view.bounds.height - 1 else { return false }
            // Require the full native button region inside the actual scrolling
            // viewport, not merely a nonempty view that exists below the fold.
            var parent = view.superview
            while let current = parent {
                if let clip = current as? NSClipView {
                    let frame = view.convert(view.bounds, to: clip)
                    return clip.bounds.insetBy(dx: -1, dy: -1).contains(frame)
                }
                parent = current.superview
            }
            return false
        }
    }
}
@MainActor final class StoragePurposeReviewView: NSView {
    var node: UInt64 = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct StoragePurposeReviewBounds: NSViewRepresentable {
    let node: UInt64
    func makeNSView(context: Context) -> StoragePurposeReviewView {
        let view = StoragePurposeReviewView(); view.node = node
        StoragePurposeLocationProbe.views.add(view); return view
    }
    func updateNSView(_ view: StoragePurposeReviewView, context: Context) { view.node = node }
}
#endif
