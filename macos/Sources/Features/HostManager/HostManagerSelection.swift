import Combine
import Foundation

/// Section currently shown in the Vaults window's content area. The
/// titlebar accessory buttons (Vaults / SFTP) flip this from outside the
/// SwiftUI view tree, so it has to live in a shared `ObservableObject`.
final class HostManagerSelection: ObservableObject {
    static let shared = HostManagerSelection()

    enum Section: String, Hashable {
        case vaults
        case sftp   // dual-pane file manager (local ⇄ remote, server ⇄ server)
    }

    @Published var section: Section = .vaults

    /// Set to request the Hosts view open the editor for this host (e.g. the SSH
    /// connection popup's "Edit host"). Survives the dashboard mounting, unlike a
    /// one-shot notification. `HostsSectionView` consumes and clears it.
    @Published var pendingEditHostID: UUID?

    private init() {}
}
