import SwiftUI

/// The popover shown when the toolbar bell is clicked: a scrollable history of
/// recent app-level notifications. Tapping a row navigates to the relevant
/// section; "Clear" empties the inbox.
struct NotificationsInboxView: View {
    @ObservedObject private var center = SarvNotificationCenter.shared
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if center.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(center.items) { item in
                            row(item)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Notifications")
                .font(.headline)
            Spacer()
            #if DEBUG
            // Dev-only: fire a sample notification to verify the banner + sound
            // pipeline without juggling tabs or app focus.
            Button("Send test") {
                SarvNotifications.shared.notify(
                    .tabAttention(tab: "Test notification", tabID: UUID()))
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            #endif
            if !center.items.isEmpty {
                Button("Clear") { center.clear() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondaryText)
            Text("No notifications")
                .foregroundStyle(.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ item: SarvNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.read ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(item.body)
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(3)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiaryText)
            }
            Spacer(minLength: 8)
            // Explicit affordance so it's obvious the row is actionable.
            Button(action: { open(item) }) {
                Text("Open")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
    }

    private func open(_ item: SarvNotificationItem) {
        if let route = item.route {
            SarvNotifications.shared.open(route: route, url: item.url, tabID: item.tabID)
        }
        dismiss()
    }
}
