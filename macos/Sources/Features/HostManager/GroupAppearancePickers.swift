import SwiftUI

// MARK: - Palette

/// Curated color palette for group folders. The first entry is "Accent"
/// (empty hex) — meaning "no override, use the system accent color".
enum GroupColorPalette {
    static let entries: [(name: String, hex: String)] = [
        ("Accent",  ""),
        ("Red",     "#FF453A"),
        ("Orange",  "#FF9F0A"),
        ("Yellow",  "#FFD60A"),
        ("Green",   "#30D158"),
        ("Mint",    "#63E6E2"),
        ("Teal",    "#40C8E0"),
        ("Cyan",    "#64D2FF"),
        ("Blue",    "#0A84FF"),
        ("Indigo",  "#5E5CE6"),
        ("Purple",  "#BF5AF2"),
        ("Pink",    "#FF375F"),
        ("Brown",   "#AC8E68"),
        ("Gray",    "#8E8E93"),
    ]

    static func color(for hex: String) -> Color {
        if hex.isEmpty { return .accentColor }
        return Color(hex: hex) ?? .accentColor
    }
}

enum GroupIconPalette {
    static let symbols: [String] = [
        "folder.fill",
        "tray.full.fill",
        "shippingbox.fill",
        "building.2.fill",
        "server.rack",
        "network",
        "cloud.fill",
        "globe.americas.fill",
        "house.fill",
        "lock.fill",
        "star.fill",
        "tag.fill",
        "wrench.and.screwdriver.fill",
        "hammer.fill",
        "person.2.fill",
        "bolt.fill",
    ]
}

// MARK: - Color picker row

struct GroupColorPicker: View {
    @Binding var colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COLOR")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(GroupColorPalette.entries, id: \.hex) { entry in
                        Button {
                            colorHex = entry.hex
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(GroupColorPalette.color(for: entry.hex))
                                    .frame(width: 28, height: 28)
                                if colorHex == entry.hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay(
                                Circle().stroke(
                                    colorHex == entry.hex ? Color.primary.opacity(0.7) : .clear,
                                    lineWidth: 2
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(entry.name)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Icon picker row

struct GroupIconPicker: View {
    @Binding var iconSystemName: String
    let tintHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ICON")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GroupIconPalette.symbols, id: \.self) { sym in
                        Button {
                            iconSystemName = sym
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(GroupColorPalette.color(for: tintHex)
                                        .opacity(iconSystemName == sym ? 0.85 : 0.18))
                                    .frame(width: 32, height: 32)
                                Image(systemName: sym)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(iconSystemName == sym ? .white : .primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(sym)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Color helper

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
