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

    private var cachedLuminance: (path: String, value: Double)?

    /// Average relative luminance (0…1) of the shared background image, or nil
    /// if there's no image. Used to decide whether a host theme's text will be
    /// readable over it. Cached per image path.
    var imageAverageLuminance: Double? {
        guard useShared, !imagePath.isEmpty, let image = sharedImage else { return nil }
        if let cached = cachedLuminance, cached.path == imagePath { return cached.value }
        guard let value = Self.averageLuminance(of: image) else { return nil }
        cachedLuminance = (imagePath, value)
        return value
    }

    /// Down-sample the image to a single pixel to read its average color.
    private static func averageLuminance(of image: NSImage) -> Double? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
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
