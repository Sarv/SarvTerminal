import SwiftUI

/// SFTP tab — placeholder for the file-transfer feature. Always visible
/// as a top tab; clicking it shows this coming-soon view.
struct SFTPView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "folder")
                    .font(.system(size: 36))
                    .foregroundStyle(.primary)
            }

            Text("SFTP")
                .font(.title2.weight(.semibold))
            Text("Coming soon")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("File transfer over SSH with a dual-pane local/remote browser.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
