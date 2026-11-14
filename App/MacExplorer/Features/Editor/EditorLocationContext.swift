import Foundation

/// Presentation from the already-opened document, never a path resolver or
/// authority for Save. The source owners keep their original bindings.
struct EditorLocationContext: Equatable {
    let label: String
    let detail: String
    let symbol: String

    static func local(_ url: URL) -> Self {
        .init(label: url.deletingLastPathComponent().lastPathComponent + " › " + url.lastPathComponent,
              detail: url.path, symbol: "folder")
    }
    static func archive(_ url: URL, member: String) -> Self {
        .init(label: url.lastPathComponent + " › " + member,
              detail: url.path + "\nZIP member: " + member, symbol: "archivebox")
    }
    static func remote(server: String, path: String) -> Self {
        .init(label: server + " › " + path,
              detail: "Remote file on " + server + "\n" + path
                + "\nSave updates this server file. Save Local Copy creates a new file on your Mac.",
              symbol: "server.rack")
    }
    static func retained(file: String, server: String, version: String) -> Self {
        .init(label: file + " · " + version + " · " + server,
              detail: "Saved copy on this Mac. This is not a read of the current server file.", symbol: "clock")
    }
    static func remoteSnapshot(server: String, path: String, captured: Date) -> Self {
        .init(label: server + " › " + path,
              detail: "Read-only snapshot captured " + captured.formatted(date: .abbreviated, time: .standard)
                + "\n" + path + "\nReopen the file to read it again. This window cannot save changes to the server.",
              symbol: "server.rack")
    }
}
