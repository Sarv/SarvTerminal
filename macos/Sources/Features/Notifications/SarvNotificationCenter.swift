import Foundation

/// One entry in the in-app notification inbox (the toolbar bell). Mirrors a
/// delivered macOS notification so the user can review what happened while
/// they were away, even after the banner is gone.
struct SarvNotificationItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    let body: String
    let routeRaw: String
    let urlString: String?
    /// For `.tab` routes — the tab to open when this row is clicked.
    let tabIDString: String?
    var read: Bool

    init(id: UUID = UUID(), date: Date, title: String, body: String,
         route: SarvNotificationRoute, url: URL?, tabID: UUID? = nil, read: Bool = false) {
        self.id = id
        self.date = date
        self.title = title
        self.body = body
        self.routeRaw = route.rawValue
        self.urlString = url?.absoluteString
        self.tabIDString = tabID?.uuidString
        self.read = read
    }

    var route: SarvNotificationRoute? { SarvNotificationRoute(rawValue: routeRaw) }
    var url: URL? { urlString.flatMap(URL.init(string:)) }
    var tabID: UUID? { tabIDString.flatMap(UUID.init(uuidString:)) }
}

/// In-memory + on-disk history of app-level notifications, surfaced by the
/// toolbar bell. Persists the most recent `maxItems` so the inbox survives a
/// relaunch.
@MainActor
final class SarvNotificationCenter: ObservableObject {
    static let shared = SarvNotificationCenter()

    @Published private(set) var items: [SarvNotificationItem] = []

    /// True while the inbox popover is open. New notifications that arrive then
    /// are recorded as already-read (no count bump) and don't play a sound —
    /// the user is already looking at the list.
    @Published var isInboxOpen = false

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    private let maxItems = 100
    private let fileURL = AppPaths.configDir.appendingPathComponent("notifications.json")

    private init() { load() }

    /// Record a delivered notification (called by `SarvNotifications.notify`).
    func add(title: String, body: String, route: SarvNotificationRoute, url: URL?, tabID: UUID? = nil, date: Date = Date()) {
        let item = SarvNotificationItem(date: date, title: title, body: body, route: route,
                                        url: url, tabID: tabID, read: isInboxOpen)
        items.insert(item, at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        save()
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        items = items.map { var i = $0; i.read = true; return i }
        save()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SarvNotificationItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
