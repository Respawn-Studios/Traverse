// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExplorerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .library(name: "LocalStorage", targets: ["LocalStorage"]),
        .executable(name: "DriveHealthWorker", targets: ["DriveHealthWorker"]),
        .library(name: "FileOperations", targets: ["FileOperations"]),
        .library(name: "Search", targets: ["Search"]),
        .library(name: "StorageAnalysis", targets: ["StorageAnalysis"]),
        .executable(name: "RetainedColdProbe", targets: ["RetainedColdProbe"]),
        .library(name: "FileMemory", targets: ["FileMemory"]),
        .library(name: "DirectUpdates", targets: ["DirectUpdates"]),
        .library(name: "SSHConfiguration", targets: ["SSHConfiguration"]),
    ],
    targets: [
        .target(name: "ExplorerCore"),
        .target(name: "LocalStorage", dependencies: ["ExplorerCore", "FileOperations", "SSHConfiguration", "BoundedGzip", "DriveHealthNative"]),
        .target(name: "DriveHealthNative", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .executableTarget(name: "DriveHealthWorker", dependencies: ["DriveHealthNative"]),
        .target(name: "BoundedGzip", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "SSHConfiguration"),
        .target(name: "FileOperations"),
        .target(name: "Search", dependencies: ["ExplorerCore"]),
        .target(name: "StorageAnalysis", dependencies: ["ExplorerCore"], exclude: ["README.md"]),
        .executableTarget(name: "RetainedColdProbe", dependencies: ["StorageAnalysis", "ExplorerCore"]),
        .target(name: "FileMemory", dependencies: ["ExplorerCore", "LocalStorage", "FileOperations"]),
        .target(name: "DirectUpdates"),
        .testTarget(name: "DirectUpdatesTests", dependencies: ["DirectUpdates"]),
        .testTarget(name: "SSHConfigurationTests", dependencies: ["SSHConfiguration"]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "LocalStorageTests", dependencies: ["LocalStorage", "ExplorerCore", "FileOperations", "FileMemory"]),
        .testTarget(name: "FileOperationsTests", dependencies: ["FileOperations"]),
        .testTarget(name: "SearchTests", dependencies: ["Search", "ExplorerCore"]),
        .testTarget(name: "StorageAnalysisTests", dependencies: ["StorageAnalysis"]),
        .target(name: "NameStoreFaultSupport", path: "Tests/NameStoreFaultSupport", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FileMemoryTests", dependencies: ["FileMemory", "FileOperations", "ExplorerCore", "NameStoreFaultSupport"]),
    ]
)
