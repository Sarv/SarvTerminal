import SwiftUI

/// "Show All Tabs" overview — a grid of cards, one per terminal tab, plus an
/// add card. Click a card to switch to that tab. (Cards show the tab's
/// name/color, not a live thumbnail — surfaces are live NSViews in use
/// elsewhere, so a true thumbnail would need snapshotting; a follow-up.)
struct VaultsAllTabsView: View {
    @ObservedObject var tabs: VaultsTabsModel = .shared

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 18)]

    var body: some View {
        ZStack {
            // Blur the window content behind the overview. No outside-click
            // dismiss — only Done / Esc close it.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Text("All Tabs").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { tabs.showAllTabs = false }
                        .keyboardShortcut(.cancelAction)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(Array(tabs.terminals.enumerated()), id: \.element.id) { index, tab in
                            card(tab, number: index + 1)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100)
        }
    }

    private func card(_ tab: VaultsTabsModel.TerminalTab, number: Int) -> some View {
        let isActive = tabs.selection == .terminal(tab.id)
        let accent = tab.color ?? .accentColor
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                Text(tab.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if number <= 9 {
                    Text("⌘\(number)").font(.system(size: 10)).foregroundStyle(.tertiaryText)
                }
                Button {
                    tabs.closeTerminal(tab.id)
                    // Don't leave the user staring at an empty overview.
                    if tabs.terminals.isEmpty { tabs.showAllTabs = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondaryText)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12))

            // Body placeholder (count of panes).
            ZStack {
                Color(NSColor.windowBackgroundColor)
                let count = tab.surfaceTree.root?.leaves().count ?? 1
                Text(count > 1 ? "\(count) panes" : "Terminal")
                    .font(.callout)
                    .foregroundStyle(.tertiaryText)
            }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? accent : Color.secondary.opacity(0.3),
                              lineWidth: isActive ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            tabs.selectTerminal(tab.id)
            tabs.showAllTabs = false
        }
    }
}
