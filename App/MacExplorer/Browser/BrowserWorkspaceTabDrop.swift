import AppKit
import ExplorerCore

enum WorkspaceTabDropPhase: Equatable { case update, prepare, perform }

/// Routes callbacks already delivered by AppKit's registered strips/panes.
/// Geometry chooses among live destinations; it never authenticates a source.
@MainActor
extension BrowserWorkspaceController {
    func routeTabDrag(_ info: NSDraggingInfo, receiver: NSView, phase: WorkspaceTabDropPhase) -> NSDragOperation {
        guard let context = tabDropContext(info, receiver: receiver), canChangePaneLayout else {
            clearTabDropPresentation(matching: info)
            return []
        }
        let footprint = TabStripView.dragFootprint(info, in: context.window)
        // Content-edge callbacks retain their split semantics when the pointer
        // is outside every tab band; a grazing preview must not mask Top Split.
        if let winner = tabBandWinner(pointer: info.draggingLocation, footprint: footprint,
                                      source: context.source, tabID: context.id,
                                      requirePointerInBand: !(receiver is TabStripView)) {
            clearTabDropPresentation(except: winner.browser.tabStrip)
            let result = winner.browser.tabStrip.showRoutedInsertion(info, at: winner.point, commit: phase == .perform)
            if phase == .perform || result.isEmpty { clearTabDropPresentation(matching: info) }
            return result
        }
        guard let host = receiver as? PaneHostView, paneHosts[host.paneID] === host,
              let target = browsers[host.paneID],
              let point = TabStripView.dragPoint(info, in: host, region: host.bounds),
              let edge = PaneHostView.edge(at: point, in: host.bounds),
              canMoveTab(context.id, from: context.source, beside: target.paneID, edge: edge) else {
            clearTabDropPresentation(matching: info)
            return []
        }
        clearTabDropPresentation(except: host)
        host.showRoutedSnap(edge, source: context.source.tabStrip, sequence: info.draggingSequenceNumber)
        if phase == .perform {
            // Keep the actual preview footprint and original tab separately.
            // Geometry informs only the animation after authentication above.
            let dropFrame = footprint.map { paneTreeHost.convert($0, from: nil) }
                ?? NSRect(origin: paneTreeHost.convert(info.draggingLocation, from: nil), size: .zero)
            clearTabDropPresentation(matching: info)
            return moveTab(context.id, from: context.source, beside: target, edge: edge, dropFrame: dropFrame) ? .move : []
        }
        return .move
    }

    /// A late exit may refer to the previous receiver after the winning strip
    /// has already changed. Revoke matching visuals only; never create one here.
    func exitTabDrag(_ info: NSDraggingInfo?, receiver: NSView) {
        // A source-less late exit cannot identify the visual generation. Native
        // source movement/end still revoke it without erasing a newer session.
        guard let info else { return }
        guard let context = tabDropContext(info, receiver: receiver), canChangePaneLayout else {
            clearTabDropPresentation(matching: info)
            return
        }
        revokeTabDropPreviews(from: context.source.tabStrip,
                              pointer: context.window.convertPoint(toScreen: info.draggingLocation),
                              footprint: TabStripView.dragFootprint(info, in: context.window).map(context.window.convertToScreen))
    }

    /// Native source movement also reaches unregistered regions. It can revoke
    /// a losing/abandoned preview, but cannot show a gap, grant or commit a drop.
    func revokeTabDropPreviews(from strip: TabStripView, pointer screenPoint: NSPoint, footprint screenFrame: NSRect?) {
        guard let drag = strip.liveTabDrag, let window = view.window,
              let source = layout.paneIDs.compactMap({ browsers[$0] }).first(where: { $0.tabStrip === strip }),
              source.tabs.contains(where: { $0.id == drag.id }), !source.isBrowserSuspended else { return }
        let pointer = window.convertPoint(fromScreen: screenPoint)
        let footprint = screenFrame.map(window.convertFromScreen)
        let winner = canChangePaneLayout
            ? tabBandWinner(pointer: pointer, footprint: footprint, source: source, tabID: drag.id,
                            requirePointerInBand: true)?.browser.tabStrip : nil
        for browser in browsers.values where browser.tabStrip !== winner {
            browser.tabStrip.clearDropPreview(matching: strip, sequence: drag.sequence)
        }
        for host in paneHosts.values {
            if winner != nil || !canChangePaneLayout { host.clearSnap(matching: strip, sequence: drag.sequence) }
            else { host.revokeSnapUnlessOverlapping(from: strip, sequence: drag.sequence,
                                                   pointer: screenPoint, footprint: screenFrame) }
        }
    }

    private func tabDropContext(_ info: NSDraggingInfo, receiver: NSView) -> (source: BrowserViewController, id: UUID, window: NSWindow)? {
        guard !isClosing, let window = view.window, receiver.window === window,
              !receiver.isHiddenOrHasHiddenAncestor, info.draggingDestinationWindow === window,
              layout.paneIDs.contains(where: { browsers[$0]?.tabStrip === receiver || paneHosts[$0] === receiver }),
              let drag = TabStripView.authenticatedDrag(info), drag.strip.window === window,
              let source = layout.paneIDs.compactMap({ browsers[$0] }).first(where: { $0.tabStrip === drag.strip }),
              !source.isBrowserSuspended, source.tabs.contains(where: { $0.id == drag.tabID }) else { return nil }
        return (source, drag.tabID, window)
    }

    /// At most four candidates, in the validated pane layout's stable order.
    /// Largest positive preview area wins. Exact ties favor the pointer's strip,
    /// then the first pane in layout order. The full header band includes empty
    /// append space; insertion placement remains the strip's native tab layout.
    private func tabBandWinner(pointer: NSPoint, footprint: NSRect?, source: BrowserViewController, tabID: UUID,
                               requirePointerInBand: Bool) -> (browser: BrowserViewController, point: NSPoint)? {
        guard let window = view.window else { return nil }
        let candidates = layout.paneIDs.compactMap { id -> (BrowserViewController, NSRect)? in
            guard let browser = browsers[id], !browser.isBrowserSuspended,
                  browser.tabStrip.window === window, !browser.tabStrip.isHiddenOrHasHiddenAncestor,
                  browser === source || browser.tabStrip.canReceiveTab?(source.tabStrip, tabID) == true else { return nil }
            let frame = browser.tabStrip.convert(browser.tabStrip.bounds, to: nil)
            return frame.width > 0 && frame.height > 0 ? (browser, frame) : nil
        }
        if requirePointerInBand && !candidates.contains(where: { $0.1.contains(pointer) }) { return nil }
        var best: (browser: BrowserViewController, point: NSPoint, area: CGFloat, ownsPointer: Bool)?
        for (browser, frame) in candidates {
            let ownsPointer = frame.contains(pointer)
            let area: CGFloat
            let point: NSPoint
            if let footprint {
                guard footprint.minX.isFinite, footprint.minY.isFinite, footprint.width.isFinite, footprint.height.isFinite,
                      footprint.width > 0, footprint.height > 0,
                      let overlapPoint = TabStripView.overlapPoint(pointer: pointer, footprint: footprint, region: frame) else { continue }
                let overlap = footprint.intersection(frame)
                area = overlap.width * overlap.height
                point = overlapPoint
            } else {
                // Older controlled callbacks without a native preview retain
                // pointer targeting. Production sessions retain their footprint.
                guard ownsPointer else { continue }
                area = 1; point = pointer
            }
            if best == nil || area > best!.area || (area == best!.area && ownsPointer && !best!.ownsPointer) {
                best = (browser, point, area, ownsPointer)
            }
        }
        return best.map { ($0.browser, $0.point) }
    }

    private func clearTabDropPresentation(except retained: NSView? = nil) {
        for browser in browsers.values where browser.tabStrip !== retained { browser.tabStrip.clearDropPreview() }
        for host in paneHosts.values where host !== retained { host.clearSnap() }
    }

    private func clearTabDropPresentation(matching info: NSDraggingInfo) {
        guard let source = info.draggingSource as? TabStripView else { return }
        for browser in browsers.values { browser.tabStrip.clearDropPreview(matching: source, sequence: info.draggingSequenceNumber) }
        for host in paneHosts.values { host.clearSnap(matching: source, sequence: info.draggingSequenceNumber) }
    }
}
