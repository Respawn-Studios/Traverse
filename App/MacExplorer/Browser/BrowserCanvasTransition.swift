import AppKit
import QuartzCore

/// Visible rows/items only. Native headers and materials are never captured or
/// changed, and this presentation owns no input, selection or file authority.
@MainActor
final class BrowserCanvasTransition: NSView {
    private let picture = NSImageView()
    private let foregroundClip = NSView()
    var image: NSImage? { picture.image }
    private var timeout: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var revealing = false
    private var direction = 0
    private var mode = BrowserMotionMode.full
    private var duration: Double { (direction == 0 ? 0.26 : 0.22) * mode.durationScale }
    var incomingViews: (() -> [NSView])?
    private let arrivals = NSHashTable<NSView>.weakObjects()
    private let originalOpacity = NSMapTable<NSView, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let arrivalKey = "canvas-arrival-" + UUID().uuidString
    private var revealBeganAt: CFTimeInterval?
    private(set) var visit: UUID?
    var isRevealing: Bool { revealing }
    private(set) var isFinished = false
    #if DEBUG
    private(set) var maximumArrivingForVerification = 0
    var arrivingCountForVerification: Int {
        arrivals.allObjects.filter { $0.layer?.animation(forKey: arrivalKey) != nil }.count
    }
    func arrivalStartForVerification(_ view: NSView) -> CFTimeInterval? {
        guard let layer = view.layer, let animation = layer.animation(forKey: arrivalKey) else { return nil }
        return layer.convertTime(animation.beginTime, to: nil)
    }
    #endif
    var onFinish: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    static func capture(in parent: NSView, overlayHost: NSView, foreground: [NSView], direction: Int,
                        mode: BrowserMotionMode = .full) -> BrowserCanvasTransition? {
        guard mode != .off, parent.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              parent.isDescendant(of: overlayHost), overlayHost.window === parent.window,
              let image = NativeForegroundSnapshot.capture(in: parent, views: foreground) else { return nil }
        let bridge = BrowserCanvasTransition(frame: parent.convert(parent.bounds, to: overlayHost))
        bridge.direction = direction
        bridge.mode = mode
        bridge.autoresizingMask = [.width, .height]; bridge.wantsLayer = true
        bridge.layer?.masksToBounds = true; bridge.layer?.backgroundColor = NSColor.clear.cgColor
        bridge.foregroundClip.frame = bridge.bounds; bridge.foregroundClip.autoresizingMask = [.width, .height]
        bridge.foregroundClip.wantsLayer = true; bridge.foregroundClip.layer?.masksToBounds = true
        bridge.foregroundClip.layer?.backgroundColor = NSColor.clear.cgColor
        bridge.addSubview(bridge.foregroundClip)
        bridge.picture.frame = bridge.bounds; bridge.picture.autoresizingMask = [.width, .height]
        bridge.picture.image = image; bridge.picture.imageScaling = .scaleNone; bridge.picture.imageAlignment = .alignTopLeft
        bridge.picture.wantsLayer = true; bridge.foregroundClip.addSubview(bridge.picture)
        overlayHost.addSubview(bridge, positioned: .above, relativeTo: nil)
        bridge.timeout = Task { @MainActor [weak bridge] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            bridge?.reveal()
        }
        return bridge
    }
    func bind(to visit: UUID) { self.visit = visit }
    /// A destination may add chrome above/below its rows. Never let an old row
    /// snapshot paint across that header, toolbar, pager or status text.
    func restrictForeground(to viewport: NSView, excludingHeader header: NSView? = nil, topInset: CGFloat = 0) {
        guard !isFinished, viewport.window === window, viewport.bounds.width > 1, viewport.bounds.height > 1 else { return }
        var visible = viewport.convert(viewport.bounds, to: self).intersection(bounds)
        visible.size.height = max(0, visible.height - max(0, topInset))
        if let header, header.window === window, !header.isHiddenOrHasHiddenAncestor {
            let heading = header.convert(header.bounds, to: self)
            visible = visible.intersection(NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                height: max(0, heading.minY - bounds.minY)))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AppKit owns the coordinate conversion and layer flipping. A raw
        // shape-layer mask can otherwise clip the opposite side of the image.
        if visible.isEmpty { visible = .zero }
        foregroundClip.frame = visible
        picture.autoresizingMask = []
        picture.frame = NSRect(origin: .init(x: -visible.minX, y: -visible.minY), size: bounds.size)
        CATransaction.commit()
    }
    func reveal() {
        guard !isFinished else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finish(); return }
        if revealing { stageIncomingForeground(); return }
        revealing = true; timeout?.cancel(); timeout = nil
        let began = CACurrentMediaTime(); revealBeganAt = began
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let shift = CABasicAnimation(keyPath: "transform.translation.x")
        shift.fromValue = 0; shift.toValue = -4 * Double(direction) * mode.distanceScale
        let animation = CAAnimationGroup(); animation.animations = direction == 0 ? [fade] : [fade, shift]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: direction == 0 ? .easeInEaseOut : .easeOut)
        stageIncomingForeground()
        CATransaction.begin(); CATransaction.setDisableActions(true); picture.layer?.opacity = 0; CATransaction.commit()
        animation.beginTime = picture.layer?.convertTime(began, from: nil) ?? began
        picture.layer?.add(animation, forKey: "canvasDissolve")
        cleanup = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds((self?.duration ?? 0) + 0.01)) } catch { return }
            self?.finish()
        }
    }
    func stageIncomingForeground() {
        guard !isFinished else { return }
        if let began = revealBeganAt, CACurrentMediaTime() - began >= duration { finish(); return }
        // Native reloads may replace cards/rows during a fade. Admit their new
        // views on the original clock rather than flashing or restarting it.
        // Only foregrounds fade; native materials and headers stay untouched.
        let visible = Array((incomingViews?() ?? []).prefix(256)).filter { !$0.isHiddenOrHasHiddenAncestor }
        let identities = Set(visible.map(ObjectIdentifier.init))
        for old in arrivals.allObjects where !identities.contains(ObjectIdentifier(old)) {
            restoreArrival(old); arrivals.remove(old); originalOpacity.removeObject(forKey: old)
        }
        for view in visible {
            view.wantsLayer = true
            if !arrivals.contains(view) {
                originalOpacity.setObject(NSNumber(value: view.layer?.opacity ?? 1), forKey: view)
                arrivals.add(view)
                CATransaction.begin(); CATransaction.setDisableActions(true); view.layer?.opacity = 0; CATransaction.commit()
            }
            guard let began = revealBeganAt, view.layer?.animation(forKey: arrivalKey) == nil else { continue }
            let opacity = originalOpacity.object(forKey: view)?.floatValue ?? 1
            let arrival = CABasicAnimation(keyPath: "opacity")
            arrival.fromValue = 0; arrival.toValue = opacity; arrival.duration = duration
            arrival.beginTime = view.layer?.convertTime(began, from: nil) ?? began
            arrival.timingFunction = CAMediaTimingFunction(name: direction == 0 ? .easeInEaseOut : .easeOut)
            CATransaction.begin(); CATransaction.setDisableActions(true); view.layer?.opacity = opacity; CATransaction.commit()
            view.layer?.add(arrival, forKey: arrivalKey)
        }
        #if DEBUG
        maximumArrivingForVerification = max(maximumArrivingForVerification, arrivals.allObjects.count)
        #endif
    }
    private func restoreArrival(_ view: NSView) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.layer?.removeAnimation(forKey: arrivalKey)
        view.layer?.opacity = originalOpacity.object(forKey: view)?.floatValue ?? 1
        CATransaction.commit()
    }
    func finish() {
        guard !isFinished else { return }
        isFinished = true; timeout?.cancel(); timeout = nil; cleanup?.cancel(); cleanup = nil
        incomingViews = nil; revealBeganAt = nil
        for view in arrivals.allObjects { restoreArrival(view) }
        arrivals.removeAllObjects(); originalOpacity.removeAllObjects()
        picture.layer?.removeAllAnimations(); picture.image = nil; removeFromSuperview()
        let action = onFinish; onFinish = nil; action?()
    }
}

@MainActor
extension BrowserViewController {
    func prepareCanvasTransition(enabled: Bool, directoryDirection: Int = 0) {
        canvasTransition?.finish(); canvasTransition = nil
        guard enabled, !isBrowserSuspended, !isLoading, orderingTask == nil,
              !metadataSearch.isShowingResults, let surface = contentSurface else { return }
        guard let transition = BrowserCanvasTransition.capture(in: surface.contentView, overlayHost: surface,
            foreground: visibleCanvasForeground(), direction: directoryDirection, mode: settings.motion.mode) else { return }
        canvasTransition = transition
        transition.incomingViews = { [weak self] in
            // Animate the rows/cards already on screen. Their presentation
            // must not wait for the rest of a listing or a drive refresh.
            guard let self, !isBrowserSuspended else { return [] }
            if !volumeBrowser.isHidden {
                volumeBrowser.layoutSubtreeIfNeeded()
                volumeBrowser.collectionView.layoutSubtreeIfNeeded()
            } else { activeFileView.layoutSubtreeIfNeeded() }
            return visibleCanvasForeground(realizingRows: true)
        }
        transition.onFinish = { [weak self, weak transition] in
            if self?.canvasTransition === transition { self?.canvasTransition = nil }
        }
    }
    var paneTransitionForeground: [NSView] { visibleCanvasForeground() }

    private func visibleCanvasForeground(realizingRows: Bool = false) -> [NSView] {
        if !archiveHost.isHidden, let owner = archiveTabs.values.first(where: { $0.view.superview === archiveHost }), let table = owner.table {
            let visible = table.rows(in: table.visibleRect)
            return visible.location == NSNotFound ? [] : (visible.location..<min(table.numberOfRows, visible.location + min(256, visible.length)))
                .compactMap { table.rowView(atRow: $0, makeIfNecessary: realizingRows) }
        }
        if !smbHost.isHidden, smbTabs[activeID] == nil { return savedNetworkForeground(in: smbHost) }
        if !sftpHost.isHidden, sftpTabs[activeID] == nil { return savedNetworkForeground(in: sftpHost) }
        let remote = !smbHost.isHidden ? smbTabs[activeID]?.rows.table : !sftpHost.isHidden ? sftpTabs[activeID]?.rows.table : nil
        if let remote {
            let visible = remote.rows(in: remote.visibleRect)
            return visible.location == NSNotFound ? [] : (visible.location..<min(remote.numberOfRows, visible.location + min(256, visible.length)))
                .compactMap { remote.rowView(atRow: $0, makeIfNecessary: realizingRows) }
        // Navigation has already changed the logical location. Capture the
        // surface that is still visible, before visibility follows the new
        // location; otherwise This Mac captures the hidden, empty destination.
        } else if !volumeBrowser.isHidden { return volumeBrowser.visibleTiles.map(\.view) }
        else if !iconBrowser.isHidden { return iconBrowser.collectionView.visibleItems().map(\.view) }
        else {
            let visible = table.rows(in: table.visibleRect)
            return visible.location == NSNotFound ? [] : (visible.location..<min(table.numberOfRows, visible.location + min(256, visible.length)))
                .compactMap { table.rowView(atRow: $0, makeIfNecessary: realizingRows) }
        }
    }
    func updateCanvasTransition() {
        guard let transition = canvasTransition else { return }
        transition.stageIncomingForeground()
        if loadError != nil || isBrowserSuspended { transition.finish() }
        else if transition.visit == sessionID {
            let cachedVolumes = showsComputerVolumes && !volumeBrowser.isHidden && volumeBrowser.tileCount > 0
            if cachedVolumes || !displayedEntries.isEmpty || (!isLoading && orderingTask == nil) { transition.reveal() }
        }
    }
}
