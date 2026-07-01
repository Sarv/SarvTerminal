import AppKit

/// Shared "Delete X?" confirmation, shown before destroying a saved item so no
/// delete action removes data without an explicit confirm. Mirrors the host
/// delete prompt's wording/style for consistency across the app.
///
/// Returns `true` when the user chose Delete. Call on the main thread from a
/// user action (it runs a modal).
enum DeleteConfirmation {
    @MainActor
    static func confirm(_ itemName: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(itemName)\u{201D}?"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
