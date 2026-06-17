import SwiftUI

/// Form for the Appearance section.
///
/// **B.1 scope (current):** background color / opacity / blur + window theme.
/// **B.1.1 follow-up:** theme picker (with discovery of built-in + user themes),
/// foreground / cursor / selection color overrides, palette editor.
/// **B.3:** Save actually writes these to `~/.config/ghostty/config` and reloads.
struct AppearanceSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            backgroundCard
            colorsCard
            backgroundImageCard
            themeCard
        }
    }

    // MARK: - Colors card

    private var colorsCard: some View {
        SettingsCard(title: "Colors") {
            row("Foreground") {
                ColorSwatchPicker(color: $viewModel.appearance.foregroundColor)
            }
            divider
            optionalColorRow(
                label: "Cursor",
                useOverride: $viewModel.appearance.useCursorColor,
                color: $viewModel.appearance.cursorColor
            )
            divider
            optionalColorRow(
                label: "Selection FG",
                useOverride: $viewModel.appearance.useSelectionForeground,
                color: $viewModel.appearance.selectionForeground
            )
            divider
            optionalColorRow(
                label: "Selection BG",
                useOverride: $viewModel.appearance.useSelectionBackground,
                color: $viewModel.appearance.selectionBackground
            )
            divider
            optionalColorRow(
                label: "Bold text",
                useOverride: $viewModel.appearance.useBoldColor,
                color: $viewModel.appearance.boldColor
            )
        }
    }

    private func optionalColorRow(
        label: String,
        useOverride: Binding<Bool>,
        color: Binding<Color>
    ) -> some View {
        row(label) {
            HStack(spacing: 12) {
                Toggle("Override", isOn: useOverride)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text(useOverride.wrappedValue ? "Custom" : "Default")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                if useOverride.wrappedValue {
                    ColorSwatchPicker(color: color)
                }
            }
        }
    }

    // MARK: - Background card

    private var backgroundCard: some View {
        SettingsCard(title: "Background") {
            row("Color") {
                ColorSwatchPicker(color: $viewModel.appearance.backgroundColor)
            }
            divider
            row("Opacity") {
                HStack(spacing: 12) {
                    Slider(value: $viewModel.appearance.backgroundOpacity, in: 0...1)
                        .frame(maxWidth: 320)
                    Text(String(format: "%.0f%%", viewModel.appearance.backgroundOpacity * 100))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            divider
            row("Blur") {
                Picker("", selection: $viewModel.appearance.backgroundBlur) {
                    ForEach(BackgroundBlurOption.availableOptions) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
            }
        }
    }

    // MARK: - Background image card

    private var backgroundImageCard: some View {
        SettingsCard(title: "Background Image") {
            row("Image") {
                imagePicker
            }

            divider
            row("Display") {
                Picker("", selection: $viewModel.appearance.backgroundDisplayShared) {
                    Text("Per-pane").tag(false)
                    Text("Shared").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .help("Per-pane: each terminal draws its own copy. Shared: one image behind all panes.")
            }

            // Shared mode: a single image behind translucent panes. The only
            // knob that applies is how translucent the panes are.
            if viewModel.appearance.hasBackgroundImage && viewModel.appearance.backgroundDisplayShared {
                divider
                row("Image visibility") {
                    HStack(spacing: 12) {
                        Slider(value: $viewModel.appearance.sharedImageVisibility, in: 0...1)
                            .frame(maxWidth: 320)
                        Text(String(format: "%.0f%%", viewModel.appearance.sharedImageVisibility * 100))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            // Per-pane mode: Ghostty's native background-image knobs. Only show
            // when an image is selected — keeps the card compact when not in use.
            if viewModel.appearance.hasBackgroundImage && !viewModel.appearance.backgroundDisplayShared {
                divider
                row("Opacity") {
                    HStack(spacing: 12) {
                        Slider(value: $viewModel.appearance.backgroundImageOpacity, in: 0...1)
                            .frame(maxWidth: 320)
                        Text(String(format: "%.0f%%", viewModel.appearance.backgroundImageOpacity * 100))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                divider
                row("Fit") {
                    Picker("", selection: $viewModel.appearance.backgroundImageFit) {
                        ForEach(BackgroundImageFit.allCases) { fit in
                            Text(fit.label).tag(fit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                }
                divider
                row("Position") {
                    Picker("", selection: $viewModel.appearance.backgroundImagePosition) {
                        ForEach(BackgroundImagePosition.allCases) { pos in
                            Text(pos.label).tag(pos)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }
                divider
                row("Tile") {
                    Toggle("Repeat image to fill", isOn: $viewModel.appearance.backgroundImageRepeat)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    /// File-picker button. If an image is set, shows the filename + a Remove
    /// button. Otherwise, "Choose image…".
    private var imagePicker: some View {
        HStack(spacing: 8) {
            Button {
                pickBackgroundImage()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.appearance.hasBackgroundImage
                          ? "photo.fill"
                          : "photo")
                    Text(viewModel.appearance.hasBackgroundImage
                         ? (viewModel.appearance.backgroundImagePath as NSString).lastPathComponent
                         : "Choose image…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 140, alignment: .leading)
            }
            .controlSize(.regular)

            if viewModel.appearance.hasBackgroundImage {
                Button("Remove") {
                    viewModel.appearance.backgroundImagePath = ""
                }
                .controlSize(.regular)
            }
        }
    }

    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Background Image"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentImageDirectory()

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.appearance.backgroundImagePath = url.path
        }
    }

    private func currentImageDirectory() -> URL? {
        let path = viewModel.appearance.backgroundImagePath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    // MARK: - Theme card

    private var themeCard: some View {
        SettingsCard(title: "Theme") {
            row("Window theme") {
                Picker("", selection: $viewModel.appearance.windowTheme) {
                    ForEach(WindowThemeOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
            }
            divider
            row("Theme") {
                HStack(spacing: 8) {
                    ThemePicker(themeName: $viewModel.appearance.themeName)
                    ThemePreviewButton(themeName: viewModel.appearance.themeName)
                }
            }
        }
    }

    // MARK: - Row + divider helpers

    private func row<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .frame(width: 130, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }
}

// MARK: - Settings card

/// Visual grouping for a related set of settings. Title at top, rounded
/// container, full-width.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }
}

// MARK: - BackgroundBlurOption availability

extension BackgroundBlurOption {
    /// Filters glass options out when running on older macOS.
    static var availableOptions: [BackgroundBlurOption] {
        var opts: [BackgroundBlurOption] = [.off, .subtle, .standard, .strong]
        if #available(macOS 26.0, *) {
            opts.append(.glassRegular)
            opts.append(.glassClear)
        }
        return opts
    }
}
