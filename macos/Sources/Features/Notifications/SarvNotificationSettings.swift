import Foundation

/// Categories the user can independently enable or disable in Settings.
enum SarvNotificationCategory: String, CaseIterable, Identifiable {
    case transfers, tunnels, sync, ssh, security, update, tabs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transfers: return "File transfers"
        case .tunnels:   return "Port-forward tunnels"
        case .sync:      return "Settings sync"
        case .ssh:       return "SSH disconnects"
        case .security:  return "Security alerts"
        case .update:    return "App updates"
        case .tabs:      return "Tab prompts"
        }
    }

    var detail: String {
        switch self {
        case .transfers: return "SFTP upload/download finished or failed."
        case .tunnels:   return "A tunnel dropped or failed to start."
        case .sync:      return "Sync failed, or newer settings were pulled."
        case .ssh:       return "A connected host disconnected."
        case .security:  return "A server's host key changed (possible MITM)."
        case .update:    return "A new version of SarvTerminal is available."
        case .tabs:      return "A background tab is waiting for input (e.g. an AI coding agent prompt)."
        }
    }
}

/// User preferences for SarvTerminal's app-level notifications (UserDefaults).
/// `SarvNotifications.notify` consults this before delivering anything.
@MainActor
final class SarvNotificationSettings: ObservableObject {
    static let shared = SarvNotificationSettings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "SarvNotifEnabled"
        static let sound = "SarvNotifSoundEnabled"
        static let disabledCategories = "SarvNotifDisabledCategories"
    }

    /// Master switch — off means no notifications at all.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    /// Whether to play the alert sound.
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Keys.sound) } }
    /// Raw values of categories the user turned OFF (default = all on).
    @Published private var disabledCategories: Set<String> {
        didSet { defaults.set(Array(disabledCategories), forKey: Keys.disabledCategories) }
    }

    private init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        soundEnabled = defaults.object(forKey: Keys.sound) as? Bool ?? true
        disabledCategories = Set((defaults.array(forKey: Keys.disabledCategories) as? [String]) ?? [])
    }

    /// Whether a category should be delivered (respects the master switch).
    func isEnabled(_ category: SarvNotificationCategory) -> Bool {
        enabled && !disabledCategories.contains(category.rawValue)
    }

    /// Per-category toggle, independent of the master switch (so the UI keeps
    /// the user's choices when the master is flipped off and back on).
    func categoryOn(_ category: SarvNotificationCategory) -> Bool {
        !disabledCategories.contains(category.rawValue)
    }

    func setCategory(_ on: Bool, _ category: SarvNotificationCategory) {
        if on { disabledCategories.remove(category.rawValue) }
        else { disabledCategories.insert(category.rawValue) }
    }
}
