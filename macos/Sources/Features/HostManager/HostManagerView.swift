import SwiftUI

/// Top-level layout for the Vaults window's content area. Section
/// selection (Vaults / SFTP) is driven externally by
/// `HostManagerSelection.shared`, set from the leading-titlebar
/// accessory buttons attached to the window.
struct HostManagerView: View {
    @ObservedObject private var selection = HostManagerSelection.shared

    var body: some View {
        Group {
            switch selection.section {
            case .vaults: VaultsView()
            case .sftp:   SFTPView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
