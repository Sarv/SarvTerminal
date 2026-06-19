import SwiftUI

/// User preferences for the SFTP file manager + file viewer. Persisted to
/// UserDefaults; observed by the views.
final class SFTPSettings: ObservableObject {
    static let shared = SFTPSettings()

    private enum Keys {
        static let autoSave = "SarvSFTPAutoSave"
        static let confirmDelete = "SarvSFTPConfirmDelete"
        static let showHidden = "SarvSFTPShowHidden"
    }

    /// When true, edits in the file viewer save automatically (debounced);
    /// when false, the user saves manually (Save button / ⌘S).
    @Published var autoSave: Bool {
        didSet { UserDefaults.standard.set(autoSave, forKey: Keys.autoSave) }
    }
    /// Ask before deleting a file/folder.
    @Published var confirmDelete: Bool {
        didSet { UserDefaults.standard.set(confirmDelete, forKey: Keys.confirmDelete) }
    }
    /// Show dot-files in the browser.
    @Published var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: Keys.showHidden) }
    }

    private init() {
        let d = UserDefaults.standard
        let autoSaveValue = d.bool(forKey: Keys.autoSave)            // default false (manual)
        let confirmDeleteValue = d.object(forKey: Keys.confirmDelete) as? Bool ?? true
        let showHiddenValue = d.object(forKey: Keys.showHidden) as? Bool ?? true
        autoSave = autoSaveValue
        confirmDelete = confirmDeleteValue
        showHidden = showHiddenValue
        baselineAutoSave = autoSaveValue
        baselineConfirmDelete = confirmDeleteValue
        baselineShowHidden = showHiddenValue
    }

    // MARK: - Baseline / revert / reset
    //
    // The Settings footer offers a per-section "Revert" (undo changes made since
    // the window opened) and "Reset to Default". We mirror that here: capture a
    // baseline when Settings opens, then expose dirtiness / revert / reset.

    /// Factory defaults — what "Reset to Default" restores.
    static let defaultAutoSave = false
    static let defaultConfirmDelete = true
    static let defaultShowHidden = true

    private var baselineAutoSave: Bool
    private var baselineConfirmDelete: Bool
    private var baselineShowHidden: Bool

    /// Snapshot the current values as the point Revert returns to.
    func captureBaseline() {
        baselineAutoSave = autoSave
        baselineConfirmDelete = confirmDelete
        baselineShowHidden = showHidden
    }

    /// True when any value differs from the captured baseline.
    var isDirty: Bool {
        autoSave != baselineAutoSave
            || confirmDelete != baselineConfirmDelete
            || showHidden != baselineShowHidden
    }

    /// Restore the values from the captured baseline.
    func revertToBaseline() {
        autoSave = baselineAutoSave
        confirmDelete = baselineConfirmDelete
        showHidden = baselineShowHidden
    }

    /// Restore factory defaults.
    func resetToDefaults() {
        autoSave = Self.defaultAutoSave
        confirmDelete = Self.defaultConfirmDelete
        showHidden = Self.defaultShowHidden
    }
}
