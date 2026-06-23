import AppKit
import Foundation
import OSLog
import UserNotifications

/// Where a notification's "Show" action should take the user. Encoded as a
/// raw string in the notification `userInfo` so `AppDelegate` can route the
/// click without holding a reference to the originating object.
enum SarvNotificationRoute: String {
    case hosts
    case transfers
    case portForwarding
    case sync
    case knownHosts
    case update
}

/// App-level events worth a macOS notification. Each case carries the
/// human-readable bits needed to render a title/body — the helper owns the
/// copy so call sites stay terse.
enum SarvNotificationEvent {
    case sftpFinished(file: String, host: String?)
    case sftpFailed(file: String, host: String?, reason: String)
    case tunnelDropped(label: String)
    case tunnelFailed(label: String, reason: String)
    case syncFinished(summary: String)
    case syncFailed(reason: String)
    case syncRemoteNewer(detail: String)
    case sshDisconnected(host: String)
    case hostKeyChanged(host: String, detail: String)
    case updateAvailable(version: String, url: URL?)
}

/// Central macOS-notification helper for SarvTerminal's app-level events
/// (transfers, tunnels, sync, SSH sessions, host-key changes, updates).
///
/// Reuses the shared `UNUserNotificationCenter`. Every notification carries
/// `userInfo[kindKey]` so the notification-center delegate in `AppDelegate`
/// routes these separately from Ghostty's surface-bound notifications.
@MainActor
final class SarvNotifications {
    static let shared = SarvNotifications()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sarv.terminal",
        category: "notifications"
    )

    /// Category id, distinct from Ghostty's surface notification category.
    static let categoryId = "com.sarv.terminal.notification"
    /// "Show" action id.
    static let actionShow = "com.sarv.terminal.notification.show"
    /// Marks a notification as ours (app-level, not surface-bound).
    static let kindKey = "sarvKind"
    /// Carries the `SarvNotificationRoute` raw value.
    static let routeKey = "sarvRoute"

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuthorization = false

    private init() {}

    // MARK: - Setup

    /// The notification category to register at launch. `AppDelegate` merges
    /// this with Ghostty's category rather than replacing it.
    var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [UNNotificationAction(identifier: Self.actionShow, title: "Show")],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// Request notification authorization once. The system only prompts the
    /// first time, so this is safe to call repeatedly.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Self.logger.warning("notification auth failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Delivery

    /// True if the given delivered/presented notification is one of ours.
    /// `nonisolated` so the notification-center delegate (which is called off
    /// the main actor) can branch on it without hopping actors.
    nonisolated static func isSarvNotification(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo[kindKey] != nil
    }

    /// Deliver a notification for an app-level event.
    func notify(_ event: SarvNotificationEvent) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        let copy = Self.copy(for: event)
        content.title = copy.title
        content.body = copy.body
        content.sound = .default

        // Mirror into the in-app inbox (the toolbar bell).
        SarvNotificationCenter.shared.add(title: copy.title, body: copy.body,
                                          route: copy.route, url: copy.url)

        var userInfo: [String: Any] = [Self.kindKey: copy.route.rawValue,
                                        Self.routeKey: copy.route.rawValue]
        if let url = copy.url { userInfo["url"] = url.absoluteString }
        content.userInfo = userInfo
        content.categoryIdentifier = Self.categoryId

        // A stable-ish identifier so repeated events of the same kind collapse
        // rather than stacking (e.g. a flapping tunnel).
        let identifier = "com.sarv.terminal.\(copy.route.rawValue).\(copy.dedupe)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Self.logger.warning("notification add failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Click routing

    /// Handle a click/dismiss on one of our notifications. Brings the app
    /// forward and posts `.sarvNotificationActivated` carrying the route so
    /// the UI can navigate.
    func handle(response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[Self.routeKey] as? String,
              let route = SarvNotificationRoute(rawValue: raw) else { return }

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, Self.actionShow:
            NSApp.activate(ignoringOtherApps: true)
            navigate(to: route, url: (userInfo["url"] as? String).flatMap(URL.init(string:)))
        default:
            break
        }
    }

    /// Open the UI for a route — used by inbox-row taps (the "Show" action
    /// goes through `handle(response:)`).
    func open(route: SarvNotificationRoute, url: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        navigate(to: route, url: url)
    }

    /// Bring the relevant UI forward for a notification route.
    private func navigate(to route: SarvNotificationRoute, url: URL?) {
        switch route {
        case .hosts:
            HostManagerController.shared.show()
            HostManagerSelection.shared.section = .vaults
            HostManagerSelection.shared.vaultsSection = .hosts
        case .transfers:
            HostManagerController.shared.show()
            HostManagerSelection.shared.section = .sftp
        case .portForwarding:
            HostManagerController.shared.show()
            HostManagerSelection.shared.section = .vaults
            HostManagerSelection.shared.vaultsSection = .portForwarding
        case .knownHosts:
            HostManagerController.shared.show()
            HostManagerSelection.shared.section = .vaults
            HostManagerSelection.shared.vaultsSection = .knownHosts
        case .sync:
            SettingsController.shared.show(section: .sync)
        case .update:
            if let url {
                NSWorkspace.shared.open(url)
            } else {
                HostManagerController.shared.show()
            }
        }
    }

    // MARK: - Copy

    private struct Copy {
        let title: String
        let body: String
        let route: SarvNotificationRoute
        var url: URL? = nil
        /// Suffix that lets same-kind notifications collapse vs. stack.
        var dedupe: String = "latest"
    }

    private static func copy(for event: SarvNotificationEvent) -> Copy {
        switch event {
        case let .sftpFinished(file, host):
            return Copy(
                title: "Transfer complete",
                body: host.map { "\(file) — \($0)" } ?? file,
                route: .transfers,
                dedupe: file
            )
        case let .sftpFailed(file, host, reason):
            return Copy(
                title: "Transfer failed",
                body: "\(host.map { "\(file) — \($0): " } ?? "\(file): ")\(reason)",
                route: .transfers,
                dedupe: file
            )
        case let .tunnelDropped(label):
            return Copy(
                title: "Tunnel stopped",
                body: "\(label) is no longer forwarding.",
                route: .portForwarding,
                dedupe: label
            )
        case let .tunnelFailed(label, reason):
            return Copy(
                title: "Tunnel failed",
                body: "\(label): \(reason)",
                route: .portForwarding,
                dedupe: label
            )
        case let .syncFinished(summary):
            return Copy(title: "Sync complete", body: summary, route: .sync)
        case let .syncFailed(reason):
            return Copy(title: "Sync failed", body: reason, route: .sync)
        case let .syncRemoteNewer(detail):
            return Copy(
                title: "Sync: remote is newer",
                body: detail.isEmpty ? "A newer copy is available — pull to update." : detail,
                route: .sync
            )
        case let .sshDisconnected(host):
            return Copy(
                title: "SSH disconnected",
                body: "Connection to \(host) ended.",
                route: .hosts,
                dedupe: host
            )
        case let .hostKeyChanged(host, detail):
            return Copy(
                title: "⚠️ Host key changed",
                body: "\(host): \(detail)",
                route: .knownHosts,
                dedupe: host
            )
        case let .updateAvailable(version, url):
            return Copy(
                title: "Update available",
                body: "SarvTerminal \(version) is available.",
                route: .update,
                url: url,
                dedupe: version
            )
        }
    }
}
