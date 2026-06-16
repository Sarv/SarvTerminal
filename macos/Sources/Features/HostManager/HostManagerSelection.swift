import Combine
import Foundation

/// Section currently shown in the Vaults window's content area. The
/// titlebar accessory buttons (Vaults / SFTP) flip this from outside the
/// SwiftUI view tree, so it has to live in a shared `ObservableObject`.
final class HostManagerSelection: ObservableObject {
    static let shared = HostManagerSelection()

    enum Section: String, Hashable {
        case vaults
        case sftp   // local → remote file push
        case scp    // remote → remote file transfer
    }

    @Published var section: Section = .vaults

    private init() {}
}
