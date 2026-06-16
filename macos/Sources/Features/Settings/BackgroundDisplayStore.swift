import SwiftUI
import AppKit

/// Runtime render-state for the background image, shared across the app via a
/// singleton so `VaultsRootView` can draw the window-level image regardless of
/// whether the Settings window is open.
///
/// This holder does NOT write the Ghostty config — `SettingsViewModel` is the
/// single writer (see `applyAppearanceDiff`). It just mirrors the two facts the
/// terminal window needs to render: whether we're in shared mode, and the image
/// path. Persisted to UserDefaults so the very first render after launch (before
/// Settings is ever opened) is correct.
final class BackgroundDisplayStore: ObservableObject {
    static let shared = BackgroundDisplayStore()

    /// Shared = one image drawn at the window level behind transparent panes.
    /// Per-pane = Ghostty draws `background-image` on each surface.
    @Published private(set) var useShared: Bool
    /// The background image path (used to render the window-level image).
    @Published private(set) var imagePath: String
    /// How visible the shared image is (0 = hidden, 1 = full). Applied directly
    /// as the SwiftUI image opacity, so the slider has an obvious effect
    /// regardless of the terminal background color.
    @Published private(set) var imageVisibility: Double

    private enum Keys {
        static let shared = "SarvBgShared"
        static let image = "SarvBgImagePath"
        static let visibility = "SarvBgVisibility"
    }

    private init() {
        useShared = UserDefaults.standard.bool(forKey: Keys.shared)
        if let saved = UserDefaults.standard.string(forKey: Keys.image), !saved.isEmpty {
            imagePath = saved
        } else {
            imagePath = Self.readConfigValue("background-image") ?? ""
        }
        let vis = UserDefaults.standard.double(forKey: Keys.visibility)
        imageVisibility = vis == 0 ? 0.45 : vis
    }

    /// Pushed by `SettingsViewModel` after it writes the config, so the
    /// terminal window re-renders the window-level image immediately.
    func update(useShared: Bool, imagePath: String, imageVisibility: Double) {
        self.useShared = useShared
        self.imagePath = imagePath
        self.imageVisibility = imageVisibility
        UserDefaults.standard.set(useShared, forKey: Keys.shared)
        UserDefaults.standard.set(imagePath, forKey: Keys.image)
        UserDefaults.standard.set(imageVisibility, forKey: Keys.visibility)
    }

    /// The image to render at window level (shared mode only).
    var sharedImage: NSImage? {
        guard useShared, !imagePath.isEmpty else { return nil }
        return NSImage(contentsOfFile: (imagePath as NSString).expandingTildeInPath)
    }

    static func readConfigValue(_ key: String) -> String? {
        let path = ("~/.config/ghostty/config" as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
