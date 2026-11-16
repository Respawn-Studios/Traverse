import Foundation

enum BrowserMotionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case full, reduced, off
    var id: Self { self }
    var title: String {
        switch self {
        case .full: "Full Animations"
        case .reduced: "Reduced Animations"
        case .off: "Off"
        }
    }
    var durationScale: Double {
        switch self {
        case .full: 1
        case .reduced: 0.55
        case .off: 0
        }
    }
    var distanceScale: Double {
        switch self {
        case .full: 1
        case .reduced: 0.25
        case .off: 0
        }
    }
    var toolWindowDuration: TimeInterval { 0.20 * durationScale }
    func paneDuration(closing: Bool) -> TimeInterval { (closing ? 0.24 : 0.30) * durationScale }
    func initialOpacity(_ full: Double) -> Double { self == .reduced ? 1 - (1 - full) * 0.4 : full }
}

enum BrowserMotionEffect: String, CaseIterable, Codable, Identifiable, Sendable {
    case tabStrip = "Tab creation and closing"
    case tabContent = "Switching tab contents"
    case folders = "Folder navigation"
    case panes = "Panes and sidebar"
    case windows = "Opening windows"
    case windowClosing = "Closing windows"
    case connectionStatus = "Connection indicators"
    case pages = "Pages and details"
    case sortIndicators = "Column sort arrows"
    case charts = "Storage chart transitions"
    var id: Self { self }
}

struct BrowserMotionPreferences: Codable, Equatable, Sendable {
    var mode = BrowserMotionMode.full
    /// Compatibility with the former boolean: true meant fully disabled.
    var reduceMotion: Bool {
        get { mode == .off }
        set { mode = newValue ? .off : .full }
    }
    var tabStrip = true, tabContent = true, folders = true, panes = true, windows = true, pages = true
    var windowClosing = true, connectionStatus = true
    var sortIndicators = true
    var charts = true
    init(
        mode: BrowserMotionMode = .full, reduceMotion: Bool? = nil,
        tabStrip: Bool = true, tabContent: Bool = true, folders: Bool = true, panes: Bool = true,
        windows: Bool = true, pages: Bool = true, sortIndicators: Bool = true, charts: Bool = true,
        windowClosing: Bool = true, connectionStatus: Bool = true
    ) {
        self.mode = reduceMotion.map { $0 ? .off : .full } ?? mode
        self.tabStrip = tabStrip
        self.tabContent = tabContent
        self.folders = folders
        self.panes = panes
        self.windows = windows
        self.windowClosing = windowClosing; self.connectionStatus = connectionStatus
        self.pages = pages
        self.sortIndicators = sortIndicators
        self.charts = charts
    }
    func selected(_ effect: BrowserMotionEffect) -> Bool {
        switch effect {
        case .tabStrip: tabStrip
        case .tabContent: tabContent
        case .folders: folders
        case .panes: panes
        case .windows: windows
        case .windowClosing: windowClosing
        case .connectionStatus: connectionStatus
        case .pages: pages
        case .sortIndicators: sortIndicators
        case .charts: charts
        }
    }
    func allows(_ effect: BrowserMotionEffect) -> Bool { mode != .off && selected(effect) }
    mutating func set(_ enabled: Bool, for effect: BrowserMotionEffect) {
        switch effect {
        case .tabStrip: tabStrip = enabled
        case .tabContent: tabContent = enabled
        case .folders: folders = enabled
        case .panes: panes = enabled
        case .windows: windows = enabled
        case .windowClosing: windowClosing = enabled
        case .connectionStatus: connectionStatus = enabled
        case .pages: pages = enabled
        case .sortIndicators: sortIndicators = enabled
        case .charts: charts = enabled
        }
    }
}

extension BrowserMotionPreferences {
    private enum CodingKeys: String, CodingKey {
        case mode, reduceMotion, tabStrip, tabContent, folders, panes, windows, windowClosing, connectionStatus, pages, sortIndicators, charts
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try values.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        mode = try values.decodeIfPresent(BrowserMotionMode.self, forKey: .mode) ?? (legacy ? .off : .full)
        tabStrip = try values.decodeIfPresent(Bool.self, forKey: .tabStrip) ?? true
        tabContent = try values.decodeIfPresent(Bool.self, forKey: .tabContent) ?? true
        folders = try values.decodeIfPresent(Bool.self, forKey: .folders) ?? true
        panes = try values.decodeIfPresent(Bool.self, forKey: .panes) ?? true
        windows = try values.decodeIfPresent(Bool.self, forKey: .windows) ?? true
        windowClosing = try values.decodeIfPresent(Bool.self, forKey: .windowClosing) ?? true
        connectionStatus = try values.decodeIfPresent(Bool.self, forKey: .connectionStatus) ?? true
        pages = try values.decodeIfPresent(Bool.self, forKey: .pages) ?? true
        sortIndicators = try values.decodeIfPresent(Bool.self, forKey: .sortIndicators) ?? true
        charts = try values.decodeIfPresent(Bool.self, forKey: .charts) ?? true
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        // An older build errs on the quieter side for either non-Full mode.
        try values.encode(mode != .full, forKey: .reduceMotion)
        try values.encode(tabStrip, forKey: .tabStrip)
        try values.encode(tabContent, forKey: .tabContent)
        try values.encode(folders, forKey: .folders)
        try values.encode(panes, forKey: .panes)
        try values.encode(windows, forKey: .windows)
        try values.encode(windowClosing, forKey: .windowClosing)
        try values.encode(connectionStatus, forKey: .connectionStatus)
        try values.encode(pages, forKey: .pages)
        try values.encode(sortIndicators, forKey: .sortIndicators)
        try values.encode(charts, forKey: .charts)
    }
}
