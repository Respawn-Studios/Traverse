import AppKit
import Combine
import ObjectiveC
import SwiftUI

/// A product preference, independent of display resolution and file view zoom.
/// Invalid persisted values fall back without discarding unrelated preferences.
struct InterfaceSize: Codable, Equatable, Sendable {
    let percent: Int
    static let standard = Self(100)
    init(_ percent: Int) { self.percent = (100...150).contains(percent) && percent.isMultiple(of: 5) ? percent : 100 }
    var scale: CGFloat { CGFloat(percent) / 100 }
    init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(Int.self)) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(percent) }
}

@MainActor
final class InterfacePresentation: ObservableObject {
    static let shared = InterfacePresentation()
    /// The app's existing preference owner, never a second settings instance.
    private(set) weak var settings: BrowserSettings?
    @Published private(set) var size = InterfaceSize.standard
    @Published private(set) var motion = BrowserMotionPreferences()
    private var observation: AnyCancellable?
    private var motionObservation: AnyCancellable?
    private let roots = NSHashTable<NSView>.weakObjects()
    static let didChange = Notification.Name("TraverseInterfaceSizeDidChange")

    /// Bound once by application composition, never by opening a Settings page.
    func bind(_ settings: BrowserSettings) {
        self.settings = settings
        observation?.cancel()
        motionObservation?.cancel()
        motionObservation = settings.$motion.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.motion = value
            if !value.allows(.pages) {
                for window in self.registeredWindows { ToolContentMotion.finish(in: window) }
            }
        }
        observation = settings.$interfaceSize.removeDuplicates().sink { [weak self] value in
            guard let self, self.size != value else { return }
            // Reveal the current layout once per window without retaining an
            // outgoing layout picture. Fonts keep their exact requested size.
            for window in self.registeredWindows where window.isVisible {
                ToolContentMotion.finishContentMotion(in: window)
                if let content = (window.contentViewController as? ToolWindowChrome)?.contentHost ?? window.contentView {
                    ToolContentMotion.reveal(content, movesContent: false)
                }
            }
            self.size = value
            for root in self.roots.allObjects { self.apply(in: root) }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
    private var registeredWindows: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return roots.allObjects.compactMap(\.window).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    func register(_ root: NSView) { roots.add(root); apply(in: root) }
    static func markHosting(_ root: NSView) {
        objc_setAssociatedObject(root, &InterfaceAssociation.hosting, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    func apply(in root: NSView) {
        // SwiftUI gets the same metrics through its public environment. Walking
        // its internal AppKit controls would apply the enlargement twice.
        guard objc_getAssociatedObject(root, &InterfaceAssociation.hosting) == nil else { return }
        if let control = root as? NSControl, let font = control.font {
            let base = objc_getAssociatedObject(control, &InterfaceAssociation.font) as? NSFont ?? font
            objc_setAssociatedObject(control, &InterfaceAssociation.font, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if control.font?.pointSize != base.pointSize * size.scale {
                control.font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * size.scale)
            }
        }
        // Only explicitly tagged app-owned document views participate. Native
        // field editors inherit their control font and must not scale twice.
        if let text = root as? NSTextView, let base = objc_getAssociatedObject(text, &InterfaceAssociation.font) as? NSFont,
           text.font?.pointSize != base.pointSize * size.scale {
            text.font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * size.scale)
        }
        if let control = root as? NSControl {
            let stored = objc_getAssociatedObject(control, &InterfaceAssociation.controlSize) as? NSNumber
            let base = stored.flatMap { NSControl.ControlSize(rawValue: $0.uintValue) } ?? control.controlSize
            objc_setAssociatedObject(control, &InterfaceAssociation.controlSize, NSNumber(value: base.rawValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let large = size.percent >= 130
            switch base {
            case .mini: control.controlSize = large ? .small : .mini
            case .small: control.controlSize = large ? .regular : .small
            case .regular: control.controlSize = large ? .large : .regular
            default: control.controlSize = base
            }
            // Native symbol buttons already match their font when no explicit
            // symbol configuration is supplied; preserve their chosen weight.
        }
        if let table = root as? NSTableView,
           let base = objc_getAssociatedObject(table, &InterfaceAssociation.rowHeight) as? NSNumber {
            table.rowHeight = ceil(base.doubleValue * size.scale)
            // Header cells are not views, so the recursive control walk below
            // cannot enlarge them with the rest of an app-owned native table.
            for column in table.tableColumns {
                let cell = column.headerCell
                guard let font = cell.font else { continue }
                let base = objc_getAssociatedObject(cell, &InterfaceAssociation.font) as? NSFont ?? font
                objc_setAssociatedObject(cell, &InterfaceAssociation.font, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                cell.font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * size.scale)
            }
            if let header = table.headerView {
                var frame = header.frame; frame.size.height = ceil(28 * size.scale); header.frame = frame
                header.needsDisplay = true
            }
        }
        for constraint in root.constraints {
            if let base = objc_getAssociatedObject(constraint, &InterfaceAssociation.dimension) as? NSNumber {
                constraint.constant = base.doubleValue * size.scale
            }
        }
        for child in root.subviews { apply(in: child) }
        root.needsLayout = true; root.needsDisplay = true
    }
}

@MainActor
private enum InterfaceAssociation {
    static var font: UInt8 = 0
    static var dimension: UInt8 = 0
    static var hosting: UInt8 = 0
    static var controlSize: UInt8 = 0
    static var rowHeight: UInt8 = 0
}

@MainActor
enum InterfaceMetrics {
    static var scale: CGFloat { InterfacePresentation.shared.size.scale }
    static func points(_ base: CGFloat) -> CGFloat { base * scale }
    static func font(_ base: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: points(base), weight: weight)
    }
    /// The inset SwiftUI Table adds native column gaps and trailing padding.
    static func insetTableColumnBudget(in width: CGFloat, scale: CGFloat) -> CGFloat {
        max(0, width - (50 * scale + 12))
    }
    static func setFont(_ control: NSControl, base: NSFont) {
        objc_setAssociatedObject(control, &InterfaceAssociation.font, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        control.font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * scale)
    }
    static func setFont(_ text: NSTextView, base: NSFont) {
        objc_setAssociatedObject(text, &InterfaceAssociation.font, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        text.font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * scale)
    }
    static func setRowHeight(_ table: NSTableView, base: CGFloat) {
        let first = objc_getAssociatedObject(table, &InterfaceAssociation.rowHeight) == nil
        objc_setAssociatedObject(table, &InterfaceAssociation.rowHeight, NSNumber(value: base), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let height = ceil(base * scale)
        if table.rowHeight != height { table.rowHeight = height }
        // Native tables embedded inside SwiftUI keep their own narrow root;
        // SwiftUI's private controls are never walked or enlarged a second time.
        if first { InterfacePresentation.shared.register(table) }
    }
}

extension NSLayoutConstraint {
    /// Mark only app-owned dimensions. System window chrome is never scaled.
    @MainActor var interfaceScaled: NSLayoutConstraint {
        let base = objc_getAssociatedObject(self, &InterfaceAssociation.dimension) as? NSNumber ?? NSNumber(value: constant)
        objc_setAssociatedObject(self, &InterfaceAssociation.dimension, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        constant = base.doubleValue * InterfaceMetrics.scale
        return self
    }
}

private struct InterfaceScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var interfaceScale: CGFloat {
        get { self[InterfaceScaleKey.self] }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

/// Explicit semantic typography avoids inspecting SwiftUI.Font's private state.
struct InterfaceFont {
    var points: CGFloat
    var weight = Font.Weight.regular
    var design = Font.Design.default
    var digits = false
    static let largeTitle = Self(points: 26)
    static let title = Self(points: 22)
    static let title2 = Self(points: 17)
    static let title3 = Self(points: 15)
    static let headline = Self(points: 13, weight: .semibold)
    static let subheadline = Self(points: 12)
    static let body = Self(points: 13)
    static let callout = Self(points: 12)
    static let caption = Self(points: 11)
    static let caption2 = Self(points: 10)
    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Self {
        .init(points: size, weight: weight, design: design)
    }
    static func system(_ style: Self, design: Font.Design = .default, weight: Font.Weight? = nil) -> Self {
        var result = style; result.design = design; if let weight { result.weight = weight }; return result
    }
    func weight(_ weight: Font.Weight) -> Self { var result = self; result.weight = weight; return result }
    func bold() -> Self { weight(.bold) }
    func monospaced() -> Self { var result = self; result.design = .monospaced; return result }
    func monospacedDigit() -> Self { var result = self; result.digits = true; return result }
    func font(at scale: CGFloat) -> Font {
        let font = Font.system(size: points * scale, weight: weight, design: design)
        return digits ? font.monospacedDigit() : font
    }
}

private struct InterfaceFontModifier: ViewModifier {
    let style: InterfaceFont
    @Environment(\.interfaceScale) private var scale
    func body(content: Content) -> some View { content.font(style.font(at: scale)) }
}
extension View {
    func interfaceFont(_ style: InterfaceFont) -> some View { modifier(InterfaceFontModifier(style: style)) }
}

struct InterfaceRoot<Content: View>: View {
    @ObservedObject private var presentation = InterfacePresentation.shared
    let content: Content
    var body: some View {
        content.environment(\.interfaceScale, presentation.size.scale)
            .font(InterfaceFont.body.font(at: presentation.size.scale))
            .controlSize(presentation.size.percent >= 130 ? .large : .regular)
            .disclosureGroupStyle(TraverseDisclosureStyle())
    }
}

/// A disclosure's complete heading is one button. Expanding never relies on
/// hitting the chevron, and content controls retain their separate actions.
struct TraverseDisclosureStyle: DisclosureGroupStyle {
    @ObservedObject private var presentation = InterfacePresentation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.interfaceScale) private var scale
    func makeBody(configuration: Configuration) -> some View {
        let animation: Animation? = reduceMotion || !presentation.motion.allows(.pages) ? nil
            : .easeInOut(duration: 0.22 * presentation.motion.mode.durationScale)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(animation) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").interfaceFont(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12 * scale)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 24 * scale, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 19 * scale).transition(.opacity)
            }
        }
    }
}

@MainActor
final class InterfaceHostingController<Content: View>: NSHostingController<InterfaceRoot<Content>> {
    var content: Content {
        get { rootView.content }
        set { rootView = InterfaceRoot(content: newValue) }
    }
    init(rootView: Content) {
        super.init(rootView: InterfaceRoot(content: rootView))
        sizingOptions = [] // Window owners keep geometry across live text/theme changes.
        objc_setAssociatedObject(view, &InterfaceAssociation.hosting, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }
}

@MainActor
final class InterfaceHostingView<Content: View>: NSHostingView<InterfaceRoot<Content>> {
    var content: Content {
        get { rootView.content }
        set { rootView = InterfaceRoot(content: newValue) }
    }
    init(content: Content) {
        super.init(rootView: InterfaceRoot(content: content))
        objc_setAssociatedObject(self, &InterfaceAssociation.hosting, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    required init(rootView: InterfaceRoot<Content>) {
        super.init(rootView: rootView)
        objc_setAssociatedObject(self, &InterfaceAssociation.hosting, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }
}
