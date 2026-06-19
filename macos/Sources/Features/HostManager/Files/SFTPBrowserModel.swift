import SwiftUI

/// State for one file-browser pane (local or a remote host).
@MainActor
final class SFTPBrowserModel: ObservableObject {
    @Published private(set) var location: FileLocation = .local
    @Published private(set) var path: String = ""
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var selectedID: String?

    private(set) var backend: FileBackend = LocalFileBackend()

    /// Visited-directory history for back/forward navigation.
    @Published private(set) var history: [String] = []
    @Published private(set) var historyIndex: Int = -1
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    enum SortColumn { case name, date, size, kind }
    @Published var sortColumn: SortColumn = .name
    @Published var sortAscending: Bool = true
    /// In-pane filter text.
    @Published var search: String = ""

    var selectedItem: FileItem? { items.first { $0.id == selectedID } }

    /// "folder" / "alias" / file extension / "file".
    func kind(_ item: FileItem) -> String {
        if item.isDirectory { return "folder" }
        if item.isSymlink { return "alias" }
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? "file" : ext.lowercased()
    }

    /// Filtered + sorted items for display. Folders always group first; the
    /// chosen column orders within each group, ascending/descending.
    var displayItems: [FileItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = items
        if !SFTPSettings.shared.showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) } }
        list.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let asc: Bool
            switch sortColumn {
            case .name: asc = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .date: asc = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: asc = a.size < b.size
            case .kind: asc = kind(a).localizedCaseInsensitiveCompare(kind(b)) == .orderedAscending
            }
            return sortAscending ? asc : !asc
        }
        return list
    }

    func setSort(_ column: SortColumn) {
        if sortColumn == column { sortAscending.toggle() }
        else { sortColumn = column; sortAscending = true }
    }

    /// Point this pane at a location and load its home directory.
    func connect(to location: FileLocation) {
        self.location = location
        switch location {
        case .local: backend = LocalFileBackend()
        case .host(let h): backend = RemoteFileBackend(host: h)
        }
        selectedID = nil
        history = []
        historyIndex = -1
        Task { await loadHome() }
    }

    func loadHome() async {
        do {
            let home = try await backend.homeDirectory()
            await load(home)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func load(_ newPath: String, record: Bool = true) async {
        isLoading = true
        error = nil
        do {
            let listed = try await backend.list(newPath)
            self.path = newPath
            self.items = listed
            self.selectedID = nil
            if record {
                // Drop any forward history, then push this directory.
                if historyIndex < history.count - 1 {
                    history.removeSubrange((historyIndex + 1)...)
                }
                history.append(newPath)
                historyIndex = history.count - 1
            }
        } catch {
            self.error = (error as? FileOpError)?.message ?? error.localizedDescription
        }
        isLoading = false
    }

    func reload() async { await load(path, record: false) }

    func open(_ item: FileItem) {
        guard item.isDirectory else { return }
        Task { await load(item.path) }
    }

    func goUp() {
        guard path != "/" && !path.isEmpty else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await load(parent.isEmpty ? "/" : parent) }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let target = history[historyIndex]
        Task { await load(target, record: false) }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let target = history[historyIndex]
        Task { await load(target, record: false) }
    }

    func newFolder(named name: String) async {
        do { try await backend.makeDirectory(backend.join(path, name)); await reload() }
        catch { self.error = (error as? FileOpError)?.message ?? error.localizedDescription }
    }

    func rename(_ item: FileItem, to newName: String) async {
        let dir = (item.path as NSString).deletingLastPathComponent
        do { try await backend.rename(item.path, to: backend.join(dir, newName)); await reload() }
        catch { self.error = (error as? FileOpError)?.message ?? error.localizedDescription }
    }

    func delete(_ item: FileItem) async {
        do { try await backend.delete(item); await reload() }
        catch { self.error = (error as? FileOpError)?.message ?? error.localizedDescription }
    }

    func setPermissions(_ item: FileItem, octal: String) async {
        do { try await backend.setPermissions(item.path, octal: octal); await reload() }
        catch { self.error = (error as? FileOpError)?.message ?? error.localizedDescription }
    }

    /// True if `name` already exists in this pane's current directory.
    func exists(name: String) async -> Bool {
        (try? await backend.exists(backend.join(path, name))) ?? false
    }
}
