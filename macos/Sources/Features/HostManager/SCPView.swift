import SwiftUI

/// SCP tab — placeholder for the remote → remote file-transfer feature.
struct SCPView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 36))
                    .foregroundStyle(.primary)
            }

            Text("SCP")
                .font(.title2.weight(.semibold))
            Text("Coming soon")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Server-to-server file transfers — pick a source and destination host, queue copies, monitor progress.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
