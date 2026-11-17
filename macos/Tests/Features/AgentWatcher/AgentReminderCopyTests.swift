import Foundation
import Testing
@testable import Ghostty

@MainActor
@Suite
struct AgentReminderCopyTests {
    @Test func aReminderReplacesTheTabsBannerAndSkipsTheInbox() {
        let tabID = UUID()
        let reminder = SarvNotifications.copy(for: .agentReminder(tab: "api", tabID: tabID))
        let first = SarvNotifications.copy(for: .tabMessage(tab: "api", message: "Allow?", tabID: tabID))
        #expect(reminder.route == .tab)
        #expect(reminder.tabID == tabID)
        #expect(reminder.dedupe == first.dedupe)
        #expect(!reminder.addsToInbox)
        #expect(first.addsToInbox)
    }
}
