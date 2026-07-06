import SwiftUI

/// Advanced section — config-file actions for power users.
///
/// Surfaces the config file path, links to open/reveal/reload, lists any
/// configuration errors Ghostty reported, and an option to reset the
/// GUI-written keys (preserves user-added content outside the GUI block).
struct AdvancedSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            fileCard
            actionsCard
            errorsCard
        }
    }

    // MARK: - Config file card

    private var fileCard: some View {
        SettingsCard(title: "Configuration File") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Path")
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                HStack {
                    Text(configFilePath)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        copyPath()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("Copy path to clipboard")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Actions card

    private var actionsCard: some View {
        SettingsCard(title: "Actions") {
            VStack(alignment: .leading, spacing: 0) {
                actionRow(
                    title: "Edit config file",
                    detail: "Opens the config in the inbuilt editor (syntax highlighting, ⌘S to save).",
                    systemImage: "doc.text",
                    action: editConfig
                )
                divider
                actionRow(
                    title: "Open in external editor",
                    detail: "Opens the config in your default text editor (e.g., $EDITOR or TextEdit).",
                    systemImage: "arrow.up.forward.app",
                    action: openInEditor
                )
                divider
                actionRow(
                    title: "Reveal in Finder",
                    detail: "Highlights the config file in a Finder window.",
                    systemImage: "folder",
                    action: revealInFinder
                )
                divider
                actionRow(
                    title: "Reload configuration",
                    detail: "Re-reads the file and applies changes without restarting.",
                    systemImage: "arrow.clockwise",
                    action: reloadConfig
                )
            }
        }
    }

    private func actionRow(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Errors card

    private var errorsCard: some View {
        SettingsCard(title: "Diagnostics") {
            let errors = configErrors
            if errors.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("No configuration errors")
                        .foregroundStyle(.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(errors.count) error\(errors.count == 1 ? "" : "s")")
                            .fontWeight(.semibold)
                    }
                    ForEach(errors.indices, id: \.self) { i in
                        Text(errors[i])
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Data + actions

    private var configErrors: [String] {
        (NSApp.delegate as? AppDelegate)?.ghostty.config.errors ?? []
    }

    private var configFilePath: String {
        return AppPaths.ghosttyConfigFile.path
    }

    private func editConfig() {
        FileEditorWindowController.shared.open(path: configFilePath)
    }

    private func openInEditor() {
        (NSApp.delegate as? AppDelegate)?.openConfig(nil)
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: configFilePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reloadConfig() {
        (NSApp.delegate as? AppDelegate)?.reloadConfig(nil)
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configFilePath, forType: .string)
    }

    private var divider: some View { Divider().padding(.leading, 16) }
}
