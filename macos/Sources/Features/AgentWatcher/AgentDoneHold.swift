import Foundation

/// How long a finished agent keeps showing done once you look at its tab,
/// before it turns idle. Settings › AI Agents › Show Done For.
enum AgentDoneHold: Int, CaseIterable, Identifiable {
    case rightAway = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    static let key = "SarvAgentDoneHold"
    static let defaultValue: AgentDoneHold = .twoMinutes

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .rightAway: "Until I view it"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        }
    }

    /// The saved choice, or the default when none is saved or it is unknown.
    static func stored(_ value: Any?) -> AgentDoneHold {
        (value as? Int).flatMap(AgentDoneHold.init(rawValue:)) ?? defaultValue
    }

    static var current: AgentDoneHold {
        stored(UserDefaults.standard.object(forKey: key))
    }
}
