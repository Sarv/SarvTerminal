import SwiftUI
import AppKit

/// Inline color picker. Click the swatch → popover opens *anchored to the
/// swatch* with hex input + preset palette + "Use system picker" escape hatch.
///
/// Replaces SwiftUI's `ColorPicker` whose tap opens the global `NSColorPanel`
/// at whatever position the panel last had — often bottom-left of the screen,
/// not next to the swatch.
struct ColorSwatchPicker: View {
    @Binding var color: Color

    @State private var isPopoverPresented: Bool = false
    @State private var hexInput: String = ""

    var body: some View {
        Button {
            hexInput = Self.hexString(from: color)
            isPopoverPresented = true
        } label: {
            swatch
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            popover
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 60, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
    }

    // MARK: - Popover

    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Hex input row
            HStack(spacing: 8) {
                Text("Hex")
                    .foregroundStyle(.secondaryText)
                TextField("#000000", text: $hexInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit(applyHexInput)
                    .onChange(of: hexInput) { newValue in
                        // Live-apply if the input parses cleanly.
                        if let parsed = Self.color(fromHex: newValue) {
                            color = parsed
                        }
                    }

                // Color preview circle next to the input
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            }

            // Preset palette
            VStack(alignment: .leading, spacing: 6) {
                Text("Presets")
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 8),
                    spacing: 6
                ) {
                    ForEach(Self.presets, id: \.hex) { preset in
                        Button {
                            color = preset.color
                            hexInput = preset.hex.uppercased()
                        } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(preset.color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            }

            Divider()

            // Bottom row: "Use system picker" + Done
            HStack {
                Button("Use system picker…") {
                    isPopoverPresented = false
                    openSystemColorPanel()
                }
                .controlSize(.small)
                Spacer()
                Button("Done") {
                    isPopoverPresented = false
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    // MARK: - Actions

    private func applyHexInput() {
        if let parsed = Self.color(fromHex: hexInput) {
            color = parsed
        } else {
            // Reset to current color's hex so input is always valid on close.
            hexInput = Self.hexString(from: color)
        }
    }

    /// Escape hatch: open the global NSColorPanel for users who want the
    /// color wheel / sliders / image-pick. We position it near the swatch.
    private func openSystemColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = NSColor(color)
        if let keyWindow = NSApp.keyWindow {
            panel.setFrameTopLeftPoint(
                NSPoint(
                    x: keyWindow.frame.maxX + 16,
                    y: keyWindow.frame.maxY - 40
                )
            )
        }
        panel.showsAlpha = false
        panel.makeKeyAndOrderFront(nil)

        // Wire panel changes back to our binding via a Combine subscription.
        // We use a one-shot observer because this is a short-lived "advanced"
        // path.
        let token = NotificationCenter.default.addObserver(
            forName: NSColorPanel.colorDidChangeNotification,
            object: panel,
            queue: .main
        ) { _ in
            let c = panel.color
            color = Color(c)
            hexInput = Self.hexString(from: Color(c))
        }
        // Clean up the observer when the panel closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - Static helpers + presets

extension ColorSwatchPicker {
    /// Common terminal palette presets. Hand-curated.
    struct Preset {
        let name: String
        let hex: String
        var color: Color { ColorSwatchPicker.color(fromHex: hex) ?? .black }
    }

    static let presets: [Preset] = [
        // Row 1: dark backgrounds
        Preset(name: "Pure Black", hex: "#000000"),
        Preset(name: "Soft Black", hex: "#1A1A1A"),
        Preset(name: "Dracula", hex: "#282A36"),
        Preset(name: "Solarized Dark", hex: "#002B36"),
        Preset(name: "Nord", hex: "#2E3440"),
        Preset(name: "One Dark", hex: "#282C34"),
        Preset(name: "Tokyo Night", hex: "#1A1B26"),
        Preset(name: "Gruvbox", hex: "#282828"),
        // Row 2: light + accents
        Preset(name: "White", hex: "#FFFFFF"),
        Preset(name: "Solarized Light", hex: "#FDF6E3"),
        Preset(name: "Paper", hex: "#F5F5DC"),
        Preset(name: "Navy", hex: "#0D1117"),
        Preset(name: "Catppuccin", hex: "#1E1E2E"),
        Preset(name: "Rosé Pine", hex: "#191724"),
        Preset(name: "Midnight Blue", hex: "#1B1F2D"),
        Preset(name: "Charcoal", hex: "#2D2D2D"),
    ]

    /// `"#RRGGBB"` (uppercase) for any Color.
    static func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parse `"#RRGGBB"` or `"RRGGBB"` or 3-digit `"#RGB"` into a Color.
    /// Returns nil if the input doesn't look like a hex color.
    static func color(fromHex input: String) -> Color? {
        var hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        let r, g, b: Double
        switch hex.count {
        case 3:
            // Expand "#abc" -> "#aabbcc"
            let chars = Array(hex)
            r = doubleFor(hex: "\(chars[0])\(chars[0])")
            g = doubleFor(hex: "\(chars[1])\(chars[1])")
            b = doubleFor(hex: "\(chars[2])\(chars[2])")
        case 6:
            r = doubleFor(hex: String(hex.prefix(2)))
            g = doubleFor(hex: String(hex.dropFirst(2).prefix(2)))
            b = doubleFor(hex: String(hex.suffix(2)))
        default:
            return nil
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    private static func doubleFor(hex: String) -> Double {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return Double(v) / 255.0
    }
}
