import SwiftUI

/// Vaults → Logs: the app-wide activity history (connections, syncs, transfers,
/// errors). Filterable by category and searchable; capped + persisted by
/// `ActivityLog`.
struct LogsSectionView: View {
    @ObservedObject private var log = ActivityLog.shared

    @State private var categoryFilter: ActivityCategory?
    @State private var search = ""
    @State private var showClearConfirm = false

    private var filtered: [ActivityEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return log.entries.filter { entry in
            if let cat = categoryFilter, entry.category != cat { return false }
            if q.isEmpty { return true }
            return entry.title.lowercased().contains(q)
                || (entry.detail?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Activity")
                .font(.headline)

            categoryMenu

            searchField
                .frame(maxWidth: 220)

            Spacer()

            Text("\(filtered.count) event\(filtered.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(log.entries.isEmpty)
            .help("Clear all activity")
            // Centered-logo SarvAlert — same dialog semantics everywhere.
            .onChange(of: showClearConfirm) { show in
                guard show else { return }
                SarvAlert.present(
                    title: "Clear all activity?",
                    message: "This removes the local activity history. It can't be undone.",
                    buttons: [
                        .init("Clear", isDefault: true, isDestructive: true),
                        .init("Cancel", isCancel: true),
                    ]) { result in
                    if result.buttonIndex == 0 { log.clear() }
                }
                showClearConfirm = false
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var categoryMenu: some View {
        Menu {
            Button {
                categoryFilter = nil
            } label: {
                if categoryFilter == nil { Label("All", systemImage: "checkmark") } else { Text("All") }
            }
            Divider()
            ForEach(ActivityCategory.allCases) { cat in
                Button {
                    categoryFilter = (categoryFilter == cat) ? nil : cat
                } label: {
                    if categoryFilter == cat {
                        Label(cat.label, systemImage: "checkmark")
                    } else {
                        Label(cat.label, systemImage: cat.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(categoryFilter?.label ?? "All")
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search activity", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { entry in
                    LogRow(entry: entry)
                    Divider().padding(.leading, 48)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(log.entries.isEmpty ? "No activity yet" : "No matching activity")
                .font(.title3.weight(.semibold))
            Text(log.entries.isEmpty
                 ? "Connections, syncs, and transfers will appear here."
                 : "Try a different filter or search.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LogRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.success ? entry.category.icon : "xmark.octagon.fill")
                .foregroundStyle(entry.success ? entry.category.tint : .red)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contextMenu {
            Button("Copy") {
                let line = "\(entry.date.formatted()) — \(entry.title)\(entry.detail.map { " · \($0)" } ?? "")"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
        }
    }
}
