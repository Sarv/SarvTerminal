import Foundation

/// A folder for organizing `SavedHost`s. Groups can nest — `parentID`
/// points to the parent group; `nil` means a top-level (root) group.
///
/// Persisted as JSON to `~/.config/sarvterminal/groups.json`.
struct HostGroup: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var parentID: UUID?
    /// SF Symbol name. "" → use the default folder icon.
    var iconSystemName: String
    /// Hex color string like `#FF9F0A`. "" → use the system accent.
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date

    static func blank(parentID: UUID? = nil) -> HostGroup {
        let now = Date()
        return HostGroup(
            id: UUID(),
            name: "",
            parentID: parentID,
            iconSystemName: "folder.fill",
            colorHex: "",
            createdAt: now,
            updatedAt: now
        )
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled group" : trimmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id             = try c.decodeIfPresent(UUID.self,   forKey: .id)             ?? UUID()
        name           = try c.decodeIfPresent(String.self, forKey: .name)           ?? ""
        parentID       = try c.decodeIfPresent(UUID.self,   forKey: .parentID)
        iconSystemName = try c.decodeIfPresent(String.self, forKey: .iconSystemName) ?? "folder.fill"
        colorHex       = try c.decodeIfPresent(String.self, forKey: .colorHex)       ?? ""
        createdAt      = try c.decodeIfPresent(Date.self,   forKey: .createdAt)      ?? now
        updatedAt      = try c.decodeIfPresent(Date.self,   forKey: .updatedAt)      ?? now
    }

    init(id: UUID, name: String, parentID: UUID?, iconSystemName: String,
         colorHex: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.parentID = parentID
        self.iconSystemName = iconSystemName
        self.colorHex = colorHex
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
