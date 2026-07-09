import SwiftUI

/// Settings section: entry point for importing appearance + keybindings from
/// another terminal emulator. The actual work happens in ``ImportSettingsSheet``.
struct ImportSectionView: View {
    @State private var showSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Migrate from another terminal") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Coming from WezTerm, iTerm2, kitty, Alacritty, or Ghostty? Import your theme, colors, font, padding, and keybindings so SarvTerminal feels like home from the first launch.")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Appearance is mapped automatically; you review and confirm keybindings.",
                          systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)

                    Label("Your hosts, vaults, SFTP, and sync are never touched.",
                          systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)

                    Button {
                        showSheet = true
                    } label: {
                        Label("Import from another terminal…", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.large)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsMetrics.horizontalPadding)
            }

            SettingsCard(title: "What gets imported") {
                VStack(alignment: .leading, spacing: 0) {
                    supportRow("Ghostty", "Theme, colors, font, padding, cursor, keybinds — near 1:1.")
                    SettingsDivider()
                    supportRow("Alacritty · kitty", "Colors, font, opacity, padding, cursor, keybinds.")
                    SettingsDivider()
                    supportRow("WezTerm", "Best-effort scrape of a Lua config (colors, font, keybinds).")
                    SettingsDivider()
                    supportRow("iTerm2", "Colors from an exported .itermcolors file.")
                }
            }
        }
        .sheet(isPresented: $showSheet) {
            ImportSettingsSheet()
        }
    }

    private func supportRow(_ name: String, _ detail: String) -> some View {
        settingsRow(name, alignment: .top) {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
