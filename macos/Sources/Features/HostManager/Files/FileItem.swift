import Foundation

/// One entry in a file browser pane (local or remote).
struct FileItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    /// Absolute path on its host (POSIX, "/"-separated for both local & remote).
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    /// Size in bytes (0 for directories we didn't stat).
    let size: Int64
    /// Last-modified, if known.
    let modified: Date?
    /// Symbolic permissions like "rwxr-xr-x" (no leading type char), if known.
    let permissions: String?

    var sizeText: String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "arrow.up.right.square" }
        return "doc"
    }
}

/// What a browser pane is connected to.
enum FileLocation: Equatable {
    case local
    case host(SavedHost)

    var title: String {
        switch self {
        case .local: return "Local"
        case .host(let h): return h.displayLabel
        }
    }

    var isLocal: Bool { if case .local = self { return true }; return false }
}
