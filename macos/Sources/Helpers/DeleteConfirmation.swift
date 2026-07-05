import AppKit

/// Shared "Delete X?" confirmation, shown before destroying a saved item so no
/// delete action removes data without an explicit confirm. Mirrors the host
/// delete prompt's wording/style for consistency across the app.
///
/// Completion-based ON PURPOSE: it's virtually always triggered from a SwiftUI
/// button action, where a synchronous modal would open deaf to mouse events
/// (see SarvAlert.present). `completion(true)` = the user chose Delete.
enum DeleteConfirmation {
    @MainActor
    static func confirm(_ itemName: String, detail: String,
                        completion: @escaping (Bool) -> Void) {
        SarvAlert.present(
            title: "Delete \u{201C}\(itemName)\u{201D}?",
            message: detail,
            buttons: [
                .init("Delete", isDefault: true, isDestructive: true),
                .init("Cancel", isCancel: true),
            ]) { completion($0.buttonIndex == 0) }
    }
}
