import SwiftUI

/// Reusable top bar for every Vaults sub-section. The chrome, spacing, and
/// styling live here once; each section just supplies its buttons:
///   • `primary`  — the "+ New …" action (optionally a split button via `primaryMenu`)
///   • `actions`  — secondary text+icon buttons (Certificate, Shell History, Import…)
///   • `trailing` — icon-only buttons pinned right (search, grid, list…)
struct VaultsToolbar: View {
    struct Item: Identifiable {
        let id = UUID()
        var title: String = ""
        var icon: String
        var disabled: Bool = false
        var help: String? = nil
        var action: () -> Void = {}
    }

    var primary: Item?
    var primaryMenu: [Item] = []
    var actions: [Item] = []
    var trailing: [Item] = []

    var body: some View {
        HStack(spacing: 8) {
            if let primary { primaryButton(primary) }
            ForEach(actions) { actionButton($0) }
            Spacer(minLength: 12)
            ForEach(trailing) { iconButton($0) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func primaryButton(_ item: Item) -> some View {
        HStack(spacing: 0) {
            Button(action: item.action) {
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                    Text(item.title).fixedSize()
                }
                .padding(.leading, 12)
                .padding(.trailing, primaryMenu.isEmpty ? 12 : 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !primaryMenu.isEmpty {
                Divider().frame(height: 16).opacity(0.4)
                Menu {
                    ForEach(primaryMenu) { m in
                        Button(m.title, systemImage: m.icon, action: m.action).disabled(m.disabled)
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .font(.callout.weight(.medium))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.18)))
        .opacity(item.disabled ? 0.5 : 1)
        .disabled(item.disabled)
        .help(item.help ?? "")
    }

    private func actionButton(_ item: Item) -> some View {
        Button(action: item.action) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                Text(item.title).fixedSize()
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondaryText)
        .opacity(item.disabled ? 0.5 : 1)
        .disabled(item.disabled)
        .help(item.help ?? "")
    }

    private func iconButton(_ item: Item) -> some View {
        Button(action: item.action) {
            Image(systemName: item.icon).font(.system(size: 14))
                .padding(6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondaryText)
        .opacity(item.disabled ? 0.5 : 1)
        .disabled(item.disabled)
        .help(item.help ?? "")
    }
}

/// Reusable centered empty-state for Vaults sections.
struct VaultsEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondaryText)
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.secondary.opacity(0.12)))
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .foregroundStyle(.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A section that is just the shared toolbar + an empty state — used by the
/// not-yet-built Vaults sections so they share the exact same top bar.
struct VaultsScaffoldSection: View {
    let toolbar: VaultsToolbar
    let empty: VaultsEmptyState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            empty
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
