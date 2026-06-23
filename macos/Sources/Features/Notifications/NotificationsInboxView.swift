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
        HStack {
            Text("Notifications")
                .font(.headline)
            Spacer()
            if !center.items.isEmpty {
                Button("Clear") { center.clear() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Text("No notifications")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ item: SarvNotificationItem) -> some View {
        Button {
            if let route = item.route {
                SarvNotifications.shared.open(route: route, url: item.url)
            }
            dismiss()
        } label: {
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
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text(item.date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
