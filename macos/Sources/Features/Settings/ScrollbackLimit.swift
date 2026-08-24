import Foundation

/// Pure helpers for the `scrollback-limit-bytes` and `scrollback-limit-lines`
/// settings.
///
/// Both are `Limit(usize)` on the Zig side (`src/config/limit.zig`), which
/// stores `unlimited` as `maxInt(usize)` and hands that sentinel to the C API
/// verbatim — so `UInt.max` means "no limit" on this side too.
enum ScrollbackLimit {
    /// The `unlimited` sentinel, matching `maxInt(usize)` in Zig.
    static let unlimited = UInt.max

    /// Ghostty's own defaults, used when the C API read fails.
    static let defaultBytes: UInt = 500_000_000
    static let defaultLines: UInt = unlimited

    static func isUnlimited(_ value: UInt) -> Bool { value == unlimited }

    /// The value to write to the config file: `unlimited`, or a plain integer.
    static func configValue(_ value: UInt) -> String {
        isUnlimited(value) ? "unlimited" : String(value)
    }

    /// Byte presets offered in the picker, smallest first, `unlimited` last.
    static let bytePresets: [UInt] =
        [10, 25, 50, 100, 250, 500, 1_000, 2_000, 4_000].map { $0 * 1_000_000 }
        + [unlimited]

    /// Line presets offered in the picker, smallest first, `unlimited` last.
    static let linePresets: [UInt] =
        [10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000] + [unlimited]

    /// Presets plus `current` when the configured value isn't one of them, so a
    /// hand-edited config shows its real value instead of snapping to a preset.
    static func options(presets: [UInt], current: UInt) -> [UInt] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    /// "Unlimited" / "No scrollback" / "500 MB" / "2 GB". Decimal units, to
    /// match the way the config file counts bytes.
    static func byteLabel(_ value: UInt) -> String {
        if isUnlimited(value) { return "Unlimited" }
        if value == 0 { return "No scrollback" }
        if value >= 1_000_000_000 {
            return unitLabel(Double(value) / 1_000_000_000, "GB")
        }
        return unitLabel(Double(value) / 1_000_000, "MB")
    }

    /// "Unlimited" / "No scrollback" / "100,000 lines".
    static func lineLabel(_ value: UInt) -> String {
        if isUnlimited(value) { return "Unlimited" }
        if value == 0 { return "No scrollback" }
        let formatted = NumberFormatter.localizedString(
            from: NSNumber(value: value),
            number: .decimal
        )
        return "\(formatted) lines"
    }

    /// Drop the decimal when the value is whole: "2 GB", not "2.0 GB".
    private static func unitLabel(_ value: Double, _ unit: String) -> String {
        value == value.rounded()
            ? "\(Int(value)) \(unit)"
            : String(format: "%.1f \(unit)", value)
    }
}
