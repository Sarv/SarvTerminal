import Foundation
import Testing
@testable import Ghostty

private let earlier = Date(timeIntervalSince1970: 1_000)
private let later = Date(timeIntervalSince1970: 2_000)

private func snippet(_ name: String, command: String = "ls", at date: Date = earlier) -> Snippet {
    Snippet(id: UUID(), name: name, command: command, createdAt: date, updatedAt: date)
}

private func host(_ label: String) -> SavedHost {
    var host = SavedHost.blank(hostname: "\(label).example.com")
    host.label = label
    return host
}

@Suite
struct RecordUpsertTests {
    @Test func appendsNewRecordStampedNow() throws {
        let added = snippet("a")
        let result = try #require(RecordUpsert.apply(added, to: [], now: later))
        #expect(result.count == 1)
        #expect(result[0].updatedAt == later)
    }

    @Test func unchangedRecordIsANoOp() {
        let stored = snippet("a")
        var resaved = stored
        resaved.updatedAt = later  // a caller re-saving with a fresh stamp
        #expect(RecordUpsert.apply(resaved, to: [stored], now: later) == nil)
    }

    @Test func changedRecordReplacesAndBumpsUpdatedAt() throws {
        let stored = snippet("a")
        var edited = stored
        edited.command = "pwd"
        let result = try #require(RecordUpsert.apply(edited, to: [stored], now: later))
        #expect(result == [Snippet(id: stored.id, name: "a", command: "pwd", createdAt: earlier, updatedAt: later)])
    }

    @Test func workingPasswordSavedOnlyWhenItChanged() {
        var stored = host("db")
        stored.authMethod = .password
        stored.password = "secret"
        #expect(VaultsTabsModel.hostWithWorkingPassword(stored, password: "secret") == nil)
        #expect(VaultsTabsModel.hostWithWorkingPassword(stored, password: "") == nil)
        #expect(VaultsTabsModel.hostWithWorkingPassword(stored, password: "new")?.password == "new")
        stored.authMethod = .ask
        #expect(VaultsTabsModel.hostWithWorkingPassword(stored, password: "new") == nil)
    }
}
