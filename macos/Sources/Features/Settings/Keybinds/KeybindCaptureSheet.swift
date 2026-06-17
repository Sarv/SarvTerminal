import SwiftUI
import AppKit
import Carbon  // for kVK_* key codes

/// Modal that captures a single key combination by listening for the next
/// keyDown. The user can press any combo; Cancel / Retry / Save afterward.
struct KeybindCaptureSheet: View {
    let actionLabel: String

    /// Called with the captured combo in Ghostty config format (e.g.
    /// "cmd+t", "ctrl+shift+a", "cmd+f1").
    let onCapture: (String) -> Void
    let onCancel: () -> Void

    @State private var capturedConfig: String = ""
    @State private var capturedSymbol: String = ""
    @State private var monitor: Any?
    @State private var hasInteracted: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Set keybinding for")
                    .foregroundStyle(.secondary)
                Text(actionLabel)
                    .font(.title3.weight(.semibold))
            }

            // Capture area
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        capturedConfig.isEmpty ? Color.accentColor.opacity(0.5) : Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.5, dash: capturedConfig.isEmpty ? [4, 4] : [])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )

                VStack(spacing: 6) {
                    if capturedConfig.isEmpty {
                        Image(systemName: "keyboard")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Listening… press a key combination")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(capturedSymbol)
                            .font(.title.monospaced())
                            .foregroundStyle(.primary)
                        Text(capturedConfig)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .frame(height: 110)

            Text(hasInteracted
                 ? "Press a different combo to change, or click Save."
                 : "Modifiers alone won't capture — press at least one non-modifier key.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Retry") {
                    capturedConfig = ""
                    capturedSymbol = ""
                    hasInteracted = true
                }
                .disabled(capturedConfig.isEmpty)
                Button("Save") {
                    onCapture(capturedConfig)
                }
                .disabled(capturedConfig.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: startMonitoring)
        .onDisappear(perform: stopMonitoring)
    }

    // MARK: - Event monitoring

    private func startMonitoring() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil  // consume — prevent the keydown from doing anything else
        }
    }

    private func stopMonitoring() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        var flags = event.modifierFlags
        guard let (configKey, symbolKey, dropShift) = resolveKey(for: event) else {
            // Only modifiers pressed; ignore until a real key arrives.
            return
        }
        // If the shifted form produces a different symbol (e.g. shift+= → +),
        // we use that as the key and drop the shift modifier so the binding
        // matches Ghostty's own default representation.
        if dropShift { flags.remove(.shift) }

        var configParts: [String] = []
        var symbolParts: [String] = []
        if flags.contains(.control) { configParts.append("ctrl");  symbolParts.append("⌃") }
        if flags.contains(.option)  { configParts.append("alt");   symbolParts.append("⌥") }
        if flags.contains(.shift)   { configParts.append("shift"); symbolParts.append("⇧") }
        if flags.contains(.command) { configParts.append("cmd");   symbolParts.append("⌘") }
        configParts.append(configKey)
        symbolParts.append(symbolKey)

        capturedConfig = configParts.joined(separator: "+")
        capturedSymbol = symbolParts.joined()
        hasInteracted = true
    }

    /// Returns (config-format, display-symbol, dropShift). `dropShift` is
    /// true when shift produced a different symbol (e.g. shift+= → +) so
    /// the caller can drop the shift modifier from the rendered combo.
    private func resolveKey(for event: NSEvent) -> (String, String, Bool)? {
        // Common special keys by hardware code (independent of layout).
        if let mapped = specialKeyName(for: Int(event.keyCode)) {
            return (mapped.0, mapped.1, false)
        }

        // Printable keys: check whether shift produced a *different* glyph
        // (i.e. = vs +, 1 vs !, ; vs :). If so, prefer the shifted glyph as
        // the key and have the caller drop the shift modifier.
        let unshifted = (event.charactersIgnoringModifiers ?? "").lowercased()
        let typed = (event.characters ?? "").lowercased()

        if event.modifierFlags.contains(.shift),
           !unshifted.isEmpty, !typed.isEmpty,
           unshifted != typed {
            return (typed, typed.uppercased(), /* dropShift: */ true)
        }

        guard !unshifted.isEmpty else { return nil }
        return (unshifted, unshifted.uppercased(), false)
    }

    private func specialKeyName(for keyCode: Int) -> (String, String)? {
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return ("enter", "⏎")
        case kVK_Tab:        return ("tab", "⇥")
        case kVK_Space:      return ("space", "Space")
        case kVK_Delete:     return ("backspace", "⌫")
        case kVK_ForwardDelete: return ("delete", "⌦")
        case kVK_Escape:     return ("escape", "⎋")
        case kVK_LeftArrow:  return ("arrow_left", "←")
        case kVK_RightArrow: return ("arrow_right", "→")
        case kVK_UpArrow:    return ("arrow_up", "↑")
        case kVK_DownArrow:  return ("arrow_down", "↓")
        case kVK_Home:       return ("home", "↖︎")
        case kVK_End:        return ("end", "↘︎")
        case kVK_PageUp:     return ("page_up", "⇞")
        case kVK_PageDown:   return ("page_down", "⇟")
        case kVK_F1:  return ("f1", "F1")
        case kVK_F2:  return ("f2", "F2")
        case kVK_F3:  return ("f3", "F3")
        case kVK_F4:  return ("f4", "F4")
        case kVK_F5:  return ("f5", "F5")
        case kVK_F6:  return ("f6", "F6")
        case kVK_F7:  return ("f7", "F7")
        case kVK_F8:  return ("f8", "F8")
        case kVK_F9:  return ("f9", "F9")
        case kVK_F10: return ("f10", "F10")
        case kVK_F11: return ("f11", "F11")
        case kVK_F12: return ("f12", "F12")
        default: return nil
        }
    }

}
