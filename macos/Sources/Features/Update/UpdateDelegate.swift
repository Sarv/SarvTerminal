import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // SarvTerminal ships a single appcast (public GitHub Pages), shared with
        // the polling `SarvUpdateChecker`. The "Check for Updates" button and the
        // download popup read this; the popup installs from the appcast's DMG
        // enclosure once the release repo is public.
        SarvUpdateChecker.appcastURLString
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))

        // The auto-downloaded update would otherwise install SILENTLY on quit —
        // nothing in the Vaults window surfaces the ready state. Offer to
        // relaunch now (deferred so the delegate returns before the modal runs).
        let version = item.displayVersionString
        DispatchQueue.main.async {
            let result = SarvAlert.runModal(
                title: "Update Ready",
                message: "Sarv Terminal \(version) has been downloaded. " +
                         "Relaunch now to finish installing, or it will be " +
                         "installed automatically the next time you quit.",
                buttons: [
                    .init("Relaunch Now", isDefault: true),
                    .init("Later", isCancel: true),
                ])
            if result.buttonIndex == 0 {
                immediateInstallHandler()
            }
        }
        return true
    }
}
