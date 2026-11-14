/// A separately versioned, optional explanation of stored filename/layout
/// evidence. These hints do not change v3 File Types, Storage Roles or Projects,
/// verify an application/format, grant access or authorize cleanup.
public enum AnalysisApplicationLayout: Int, CaseIterable, Sendable {
    case unclassified, applicationBundle, steamInstalled, steamWorkshop, steamDownloads, steamShaders
    case xcodeDerivedData, xcodeArchives, installedDeveloperTools, androidDeviceData, virtualMachinePackage
    case appleDeviceBackups, photosLibrary, videoLibrary, huggingFaceModels, huggingFaceDatasets, huggingFaceSpaces
    case ollamaModels, dockerVirtualDisk

    public var title: String {
        switch self {
        case .unclassified: "Unclassified layout / context unavailable"
        case .applicationBundle: "Application bundle layouts"
        case .steamInstalled: "Steam installed items"
        case .steamWorkshop: "Steam Workshop"
        case .steamDownloads: "Steam downloads / staging"
        case .steamShaders: "Steam shader data"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeArchives: "Xcode archives"
        case .installedDeveloperTools: "Developer-tool / SDK layouts"
        case .androidDeviceData: "Android virtual-device data"
        case .virtualMachinePackage: "Virtual-machine package names"
        case .appleDeviceBackups: "Apple device-backup layout"
        case .photosLibrary: "Photos library package names"
        case .videoLibrary: "Final Cut library package names"
        case .huggingFaceModels: "Hugging Face model repositories"
        case .huggingFaceDatasets: "Hugging Face dataset repositories"
        case .huggingFaceSpaces: "Hugging Face Spaces repositories"
        case .ollamaModels: "Ollama model directory"
        case .dockerVirtualDisk: "Docker virtual-disk layout"
        }
    }
}
