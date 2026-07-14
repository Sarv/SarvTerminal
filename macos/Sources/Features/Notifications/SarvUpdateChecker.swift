import AppKit
import Foundation
import OSLog

/// Lightweight git-based update check. Runs once at launch and then hourly.
/// When the remote version is newer than the running build it posts an
/// "Update available" notification whose "Show" action opens the release page.
///
/// NOTE: the repository is not public yet, so `latestVersionURL` and
/// `releasesPageURL` are TODO. Until `latestVersionURL` is set the check is a
/// no-op — everything else is wired and ready.
@MainActor
final class SarvUpdateChecker {
    static let shared = SarvUpdateChecker()

    /// The Sparkle appcast, served from this repo's `docs/` via GitHub Pages.
    /// Shared with Sparkle's own feed so both the download popup and this
    /// notification poll the same source.
    static let appcastURLString = "https://sarv.github.io/SarvTerminal/appcast.xml"

    /// Polled for the latest `<sparkle:shortVersionString>`.
    private static let latestVersionURL = URL(string: appcastURLString)

    /// The page the "update available" notification opens ("click here") — where
    /// the user downloads the new version.
    private static let releasesPageURL = URL(string: "https://sarv.com/sarv-terminal")

    /// How often to re-check while the app is running.
    private static let interval: TimeInterval = 60 * 60 // 1 hour

    private static let logger = Logger(
        subsystem: AppIdentity.bundleID,
        category: "update-checker"
    )

    private var timer: Timer?

    private init() {}

    /// Begin checking: once now, then every hour. Call once at launch.
    func start() {
        check()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 5 * 60
        self.timer = timer
    }

    /// Run a single check now.
    func check() {
        guard let url = Self.latestVersionURL else {
            Self.logger.debug("update check skipped — no URL configured (repo not public yet)")
            return
        }
        Task { await performCheck(url: url) }
    }

    private func performCheck(url: URL) async {
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Self.logger.warning("update check: bad HTTP status")
                return
            }
            guard let remote = Self.parseVersion(from: data) else {
                Self.logger.warning("update check: could not parse remote version")
                return
            }
            guard let current = Self.currentVersion else { return }
            if Self.isNewer(remote, than: current) {
                // Opening the notification takes the user to the Sarv Terminal
                // web page (not the raw DMG), as agreed.
                SarvNotifications.shared.notify(.updateAvailable(version: remote, url: Self.releasesPageURL))
            }
        } catch {
            Self.logger.warning("update check failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Version helpers

    private static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Accept a Sparkle appcast (first `<sparkle:shortVersionString>` = latest,
    /// since the newest item is listed first), a GitHub releases JSON
    /// (`tag_name`), or a plain version body.
    private static func parseVersion(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = json["tag_name"] as? String {
            return normalize(tag)
        }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        if let v = firstMatch(in: body,
                              pattern: #"<sparkle:shortVersionString>\s*([^<\s]+)\s*</sparkle:shortVersionString>"#) {
            return normalize(v)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count < 40 { return normalize(trimmed) }
        return nil
    }

    /// First capture group of `pattern` in `text`, or nil.
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func normalize(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Numeric component compare so "1.2.10" > "1.2.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = components(a), pb = components(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ v: String) -> [Int] {
        normalize(v).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
