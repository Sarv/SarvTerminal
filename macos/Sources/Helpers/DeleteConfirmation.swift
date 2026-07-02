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
        let result = SarvAlert.runModal(
            title: "Delete \u{201C}\(itemName)\u{201D}?",
            message: detail,
            buttons: [
                .init("Delete", isDefault: true, isDestructive: true),
                .init("Cancel", isCancel: true),
            ])
        return result.buttonIndex == 0
    }
}
