import Foundation

enum ExternalComparisonTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, kaleidoscope, beyondCompare, visualStudioCode, fileMerge
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .kaleidoscope: "Kaleidoscope"
        case .beyondCompare: "Beyond Compare"
        case .visualStudioCode: "Visual Studio Code"
        case .fileMerge: "FileMerge (active Xcode)"
        }
    }
    var applicationName: String? {
        switch self {
        case .automatic: nil
        case .kaleidoscope: "Kaleidoscope.app"
        case .beyondCompare: "Beyond Compare.app"
        case .visualStudioCode: "Visual Studio Code.app"
        case .fileMerge: "Xcode.app/Contents/Applications/FileMerge.app"
        }
    }
    var bundleIdentifiers: [String] {
        switch self {
        case .automatic: []
        case .kaleidoscope: ["app.kaleidoscope.v4", "com.blackpixel.kaleidoscope"]
        case .beyondCompare: ["com.ScooterSoftware.BeyondCompare"]
        case .visualStudioCode: ["com.microsoft.VSCode"]
        case .fileMerge: ["com.apple.FileMerge"]
        }
    }
    func acceptsExitStatus(_ status: Int32) -> Bool {
        // Difference results are normal outcomes, not failed launches:
        // https://www.scootersoftware.com/v5help/command_line_reference.html
        if self == .beyondCompare { return [0, 1, 2, 11, 12, 13, 14].contains(status) }
        return status == 0
    }
    func command(application: URL, executable: URL?, files: [URL]) -> ExternalComparisonCommand? {
        guard self != .automatic, files.count == 2, Set(files).count == 2,
              files.allSatisfy({ $0.isFileURL && $0.query == nil && $0.fragment == nil && $0.path.utf8.count <= 4096 }) else { return nil }
        let helper: URL
        let arguments: [String]
        switch self {
        case .automatic: return nil
        case .kaleidoscope:
            helper = application.appendingPathComponent("Contents/MacOS/ksdiff")
            arguments = ["--no-stdin", "--no-wait"] + files.map(\.path)
        case .beyondCompare:
            guard let executable else { return nil }
            helper = executable; arguments = files.map(\.path)
        case .visualStudioCode:
            helper = application.appendingPathComponent("Contents/Resources/app/bin/code")
            arguments = ["--diff"] + files.map(\.path)
        case .fileMerge:
            helper = URL(fileURLWithPath: "/usr/bin/opendiff")
            arguments = files.map(\.path)
        }
        return .init(tool: self, application: application, executable: helper, arguments: arguments)
    }
}

struct ExternalComparisonCommand: Sendable {
    let tool: ExternalComparisonTool
    let application: URL
    let executable: URL
    /// Each path is a distinct argument. No shell, command string or merge
    /// destination is created by Traverse.
    let arguments: [String]
}
