import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite
struct AgentHookTests {
    private let userHook: [String: Any] = [
        "matcher": "Bash",
        "hooks": [["type": "command", "command": "~/bin/audit.sh"]],
    ]

    private let claude = GroupedHookFormat(
        eventsKey: "hooks", specs: AgentHookIntegration.claudeSpecs, transport: .terminalSequence, timeout: 5)

    private func groups(_ settings: [String: Any], _ event: String, under key: String? = "hooks") -> [[String: Any]] {
        let events = key.map { settings[$0] as? [String: Any] } ?? settings
        return (events?[event] as? [[String: Any]]) ?? []
    }

    // MARK: - Grouped format (Claude Code, Codex, Gemini, Qwen, Droid)

    @Test func installingAddsEveryHookAndKeepsOtherSettings() {
        let settings: [String: Any] = ["model": "opus", "hooks": ["PreToolUse": [userHook]]]
        let installed = claude.installing(into: settings)

        #expect(installed["model"] as? String == "opus")
        for spec in AgentHookIntegration.claudeSpecs {
            let ours = groups(installed, spec.event).filter { group in
                (group["hooks"] as? [[String: Any]])?.first?["command"] as? String
                    == AgentHookCommand.command(for: spec.state, via: .terminalSequence)
            }
            #expect(ours.count == 1, "\(spec.event)")
            #expect(ours.first?["matcher"] as? String == spec.matcher)
        }
        let preToolUse = groups(installed, "PreToolUse")
        #expect(preToolUse.count == 2)
        #expect(preToolUse.first?["matcher"] as? String == "Bash")
        #expect(claude.isInstalled(in: installed))
        #expect(!claude.isInstalled(in: settings))
    }

    @Test func installingTwiceChangesNothing() {
        let once = claude.installing(into: ["hooks": ["PreToolUse": [userHook]]])
        let twice = claude.installing(into: once)
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    }

    @Test func installingReplacesAnOlderCopy() {
        let stale: [String: Any] = ["hooks": ["Stop": [[
            "hooks": [["type": "command", "command": "echo sarv-agent-status old"]],
        ]]]]
        let installed = claude.installing(into: stale)
        #expect(groups(installed, "Stop").count == 1)
        #expect(claude.isInstalled(in: installed))
    }

    @Test func removingLeavesOnlyTheUsersHooks() {
        let mixedGroup: [String: Any] = ["hooks": [
            ["type": "command", "command": "~/bin/notify.sh"],
            ["type": "command", "command": AgentHookCommand.command(for: .done, via: .terminalSequence)],
        ]]
        let settings: [String: Any] = ["hooks": ["PreToolUse": [userHook], "Stop": [mixedGroup]]]
        let removed = claude.removing(from: claude.installing(into: settings))

        #expect(groups(removed, "PreToolUse").count == 1)
        let stopHandlers = groups(removed, "Stop").first?["hooks"] as? [[String: Any]]
        #expect(stopHandlers?.map { $0["command"] as? String } == ["~/bin/notify.sh"])
        #expect((removed["hooks"] as? [String: Any])?["SessionStart"] == nil)
    }

    @Test func removingEverythingDropsTheHooksKey() {
        let removed = claude.removing(from: claude.installing(into: ["model": "opus"]))
        #expect(removed["hooks"] == nil)
        #expect(removed["model"] as? String == "opus")
    }

    /// Droid's hooks.json keeps events at the top level.
    @Test func topLevelEventsKeepOtherEventsAndRemoveCleanly() {
        let format = GroupedHookFormat(
            eventsKey: nil, specs: [AgentHookSpec("Stop", .done)], transport: .socket, timeout: 5)
        let file: [String: Any] = ["PreToolUse": [userHook]]
        let installed = format.installing(into: file)
        #expect(installed["hooks"] == nil)
        #expect(groups(installed, "Stop", under: nil).count == 1)
        #expect(groups(installed, "PreToolUse", under: nil).count == 1)
        #expect(format.isInstalled(in: installed))
        let removed = format.removing(from: installed)
        #expect(NSDictionary(dictionary: removed).isEqual(to: file))
    }

    // MARK: - Flat format (Cursor, Copilot)

    @Test func flatFormatAddsVersionAndRemovesOnlyOurs() {
        let format = AgentHookIntegration.copilot.target(paths(home: "/Users/test")).format
        let userEntry: [String: Any] = ["type": "command", "bash": "~/bin/log.sh", "timeoutSec": 3]
        let file: [String: Any] = ["version": 1, "hooks": ["agentStop": [userEntry]]]
        let installed = format.installing(into: [:])
        #expect(installed["version"] as? Int == 1)
        let stop = (installed["hooks"] as? [String: Any])?["agentStop"] as? [[String: Any]]
        #expect(stop?.first?["type"] as? String == "command")
        #expect(stop?.first?["timeoutSec"] as? Int == 5)
        #expect((stop?.first?["bash"] as? String).map(AgentHookCommand.isOurs) == true)

        let merged = format.installing(into: file)
        #expect(format.isInstalled(in: merged))
        #expect(NSDictionary(dictionary: format.removing(from: merged)).isEqual(to: file))
        #expect(format.removing(from: installed)["hooks"] == nil)
    }

    // MARK: - Commands

    /// The command must print JSON whose terminalSequence is the exact OSC
    /// 777 marker the core reads, and print nothing outside SarvTerminal.
    @Test func theTerminalCommandPrintsTheMarkerOnlyInsideSarvTerminal() throws {
        let command = AgentHookCommand.command(for: .blocked, via: .terminalSequence)
        let inside = try run(command, environment: [AgentHookEnvironment.statusFlag: "1"])
        #expect(inside.status == 0)
        let decoded = try JSONSerialization.jsonObject(with: Data(inside.output.utf8)) as? [String: Any]
        #expect(decoded?["terminalSequence"] as? String == "\u{1b}]777;notify;sarv-agent-status;blocked\u{07}")

        let outside = try run(command, environment: [:])
        #expect(outside.status == 0)
        #expect(outside.output.isEmpty)
    }

    /// The socket command delivers one parseable line, prints nothing, and
    /// exits 0 even when no socket is listening.
    @MainActor @Test func theSocketCommandSendsOneLineAndStaysQuiet() async throws {
        let socketPath = AgentStatusSocket.path(
            temporaryDirectory: NSTemporaryDirectory(), processID: Int32.random(in: 100_000...999_999), userID: getuid())
        let paneID = UUID()
        let lines = LineCollector()
        let server = AgentStatusSocket(path: socketPath) { lines.append($0) }
        try server.start()
        defer { server.stop() }

        let command = AgentHookCommand.command(for: .working, via: .socket)
        let environment = AgentHookEnvironment.values(socketPath: socketPath, paneID: paneID)
        let sent = try run(command, environment: environment)
        #expect(sent.status == 0)
        #expect(sent.output.isEmpty)
        for _ in 0..<100 where lines.all.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(lines.all.compactMap(AgentStatusMessage.parse)
                == [AgentStatusMessage(paneID: paneID, status: .working)])

        let missing = try run(command, environment: AgentHookEnvironment.values(
            socketPath: socketPath + ".gone", paneID: paneID))
        #expect(missing.status == 0)
        #expect(missing.output.isEmpty)
        let outside = try run(command, environment: [:])
        #expect(outside.status == 0)
    }

    @Test func statusMessagesParseStrictly() {
        let paneID = UUID()
        #expect(AgentStatusMessage.parse("sarv-agent-status \(paneID.uuidString) blocked")
                == AgentStatusMessage(paneID: paneID, status: .blocked))
        #expect(AgentStatusMessage.parse("sarv-agent-status \(paneID.uuidString) clear")?.status == .idle)
        #expect(AgentStatusMessage.parse("sarv-agent-status not-a-uuid done") == nil)
        #expect(AgentStatusMessage.parse("other \(paneID.uuidString) done") == nil)
        #expect(AgentStatusMessage.parse("sarv-agent-status \(paneID.uuidString) bogus") == nil)
        #expect(AgentStatusMessage.parse("sarv-agent-status \(paneID.uuidString)") == nil)
        #expect(AgentStatusSocket.line(from: Array("a b\nrest".utf8)) == "a b")
    }

    @Test func socketPathFallsBackWhenTooLong() {
        let short = AgentStatusSocket.path(temporaryDirectory: "/var/folders/x/T/", processID: 42, userID: 501)
        #expect(short == "/var/folders/x/T/sarvterminal-agents-42.sock")
        let long = AgentStatusSocket.path(
            temporaryDirectory: "/" + String(repeating: "d", count: 120), processID: 42, userID: 501)
        #expect(long == "/tmp/sarvterminal-agents-501-42.sock")
        #expect(AgentStatusSocket.processID(inSocketName: "sarvterminal-agents-42.sock") == 42)
        #expect(AgentStatusSocket.processID(inSocketName: "sarvterminal-agents-501-42.sock") == 42)
        #expect(AgentStatusSocket.processID(inSocketName: "other-42.sock") == nil)
    }

    private func run(_ command: String, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { mine, _ in mine }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    // MARK: - Integrations

    private func paths(home: String, environment: [String: String] = [:], existing: Set<String> = [])
        -> AgentHookPaths {
        AgentHookPaths(home: URL(fileURLWithPath: home), environment: environment,
                       fileExists: { existing.contains($0.path) })
    }

    @Test func integrationTargetsFollowEachAgentsRules() {
        let home = paths(home: "/Users/test")
        #expect(AgentHookIntegration.claudeCode.target(home).url.path == "/Users/test/.claude/settings.json")
        let claudeDir = paths(home: "/Users/test", environment: ["CLAUDE_CONFIG_DIR": "/cfg/claude"])
        #expect(AgentHookIntegration.claudeCode.target(claudeDir).url.path == "/cfg/claude/settings.json")
        let codexHome = paths(home: "/Users/test", environment: ["CODEX_HOME": "/cfg/codex"])
        #expect(AgentHookIntegration.codex.target(codexHome).url.path == "/cfg/codex/hooks.json")
        #expect(AgentHookIntegration.copilot.target(home).url.path
                == "/Users/test/.copilot/hooks/sarvterminal.json")

        // Droid: settings.json's "hooks" key, unless hooks.json exists.
        let droidSettings = AgentHookIntegration.droid.target(home)
        #expect(droidSettings.url.path == "/Users/test/.factory/settings.json")
        #expect((droidSettings.format as? GroupedHookFormat)?.eventsKey == "hooks")
        let withHooksFile = paths(home: "/Users/test", existing: ["/Users/test/.factory/hooks.json"])
        let droidHooks = AgentHookIntegration.droid.target(withHooksFile)
        #expect(droidHooks.url.path == "/Users/test/.factory/hooks.json")
        #expect((droidHooks.format as? GroupedHookFormat)?.eventsKey == nil)

        // Cursor counts only when its CLI is set up, not the editor alone.
        let editorOnly = paths(home: "/Users/test", existing: ["/Users/test/.cursor"])
        #expect(!AgentHookIntegration.cursor.isDetected(editorOnly))
        let cli = paths(home: "/Users/test", existing: ["/Users/test/.cursor/cli-config.json"])
        #expect(AgentHookIntegration.cursor.isDetected(cli))
    }

    @Test func onlyClaudeUsesTheTerminalTransport() {
        let home = paths(home: "/Users/test")
        for integration in AgentHookIntegration.all {
            let format = integration.target(home).format
            let installed = format.installing(into: [:])
            let text = String(data: (try? JSONSerialization.data(withJSONObject: installed)) ?? Data(),
                              encoding: .utf8) ?? ""
            let usesSocket = text.contains(AgentHookEnvironment.socket)
            #expect(usesSocket == (integration.id != AgentHookIntegration.claudeCode.id), "\(integration.id)")
        }
    }

    // MARK: - Setup offer

    @Test func theOfferSkipsOfferedDeclinedAndInstalledAgents() {
        let running = ["-zsh", "/opt/homebrew/bin/codex", "claude"]
        let first = AgentHookOffer.candidate(
            runningProcesses: running, offered: [], declined: [], isInstalled: { _ in false })
        #expect(first?.id == "claude-code")
        let afterClaude = AgentHookOffer.candidate(
            runningProcesses: running, offered: ["claude-code"], declined: [], isInstalled: { _ in false })
        #expect(afterClaude?.id == "codex")
        #expect(AgentHookOffer.candidate(
            runningProcesses: running, offered: ["claude-code"], declined: ["codex"],
            isInstalled: { _ in false }) == nil)
        #expect(AgentHookOffer.candidate(
            runningProcesses: running, offered: [], declined: [], isInstalled: { _ in true }) == nil)
        #expect(AgentHookOffer.candidate(
            runningProcesses: ["zsh", "vim"], offered: [], declined: [], isInstalled: { _ in false }) == nil)
    }

    // MARK: - File edge

    @Test func theFileEdgeRefusesBrokenJSONAndBacksUp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")

        #expect(try AgentConfigFile.read(url).isEmpty)

        try Data("{ not json".utf8).write(to: url)
        #expect(throws: AgentConfigFile.Failure.self) { try AgentConfigFile.read(url) }

        try Data(#"{"model": "opus"}"#.utf8).write(to: url)
        try AgentConfigFile.update(at: url, claude.installing)
        let backup = try AgentConfigFile.read(AgentConfigFile.backupURL(for: url))
        #expect(backup["model"] as? String == "opus" && backup["hooks"] == nil)
        let written = try AgentConfigFile.read(url)
        #expect(written["model"] as? String == "opus")
        #expect(claude.isInstalled(in: written))
        #expect(AgentConfigFile.backupURL(for: url).lastPathComponent == "settings.json.sarvterminal-backup")

        try AgentConfigFile.delete(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try AgentConfigFile.delete(url)
    }
}

/// Collects socket lines delivered on the main actor.
@MainActor
private final class LineCollector {
    private(set) var all: [String] = []
    func append(_ line: String) { all.append(line) }
}
