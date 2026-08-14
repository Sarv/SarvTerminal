import SwiftUI
import AppKit

/// macOS privacy (TCC) disk-access detection + a deep-link to the right
/// System Settings pane.
///
/// Terminals need access to protected folders (Desktop/Documents/Downloads).
/// The reliable grant for a terminal that spawns subprocesses is **Full Disk
/// Access**, which macOS attributes to the app's code signature rather than the
/// fragile per-subprocess "responsible process" chain (a `login`-spawned shell
/// resets that, so per-folder "Files & Folders" grants flap mid-session). There
/// is no API to *request* FDA — an app can only detect it's missing and guide
/// the user to Settings. That's what this does.
enum DiskAccess {
    /// Probe whether this app process can read a TCC-protected folder. Runs in
    /// the APP process (its own responsible process), so it reliably detects the
    /// common "no grant at all" case. On first run the probe itself triggers the
    /// system "would like to access your Desktop folder" prompt.
    ///
    /// Returns true if a protected folder is readable OR simply absent — only an
    /// explicit permission denial counts as "no access", so we never cry wolf.
    static func hasProtectedFolderAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Desktop", "Documents"] {
            let url = home.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return true
            } catch {
                return !isPermissionDenied(error)
            }
        }
        return true
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EPERM) { return true }
        return false
    }

    /// Open System Settings → Privacy & Security → Full Disk Access.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Slim notice bar shown at the top of the window when the app can't read
/// protected folders — with a one-click deep-link to grant Full Disk Access.
struct DiskAccessBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sarv Terminal doesn't have Full Disk Access")
                    .font(.callout.weight(.semibold))
                Text("Commands may fail with \u{201C}Operation not permitted\u{201D} in Desktop, Documents, and Downloads. Grant access, then relaunch the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Settings") { DiskAccess.openFullDiskAccessSettings() }
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss (rechecks on next launch)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}
