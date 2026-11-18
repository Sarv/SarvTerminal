import Foundation
import Testing
@testable import Ghostty

private let sessionID = "bfa05988-6fbf-456c-bfee-06cdae5194f4"

private func process(_ pid: Int, _ argv: [String], cwd: String? = "/work") -> RunningProcess {
    RunningProcess(pid: pid, argv: argv, workingDirectory: cwd)
}

@Suite
struct PaneCommandLineTests {
    @Test func idleShellHasNothingToReplay() {
        #expect(PaneCommandLine.replay(["-zsh"]) == nil)
        #expect(PaneCommandLine.replay(["/bin/bash", "--login"]) == nil)
        #expect(PaneCommandLine.replay([]) == nil)
    }

    /// npm overwrites argv with its process title and blanks the rest.
    @Test func splitsANodeProcessTitleBackIntoWords() {
        #expect(PaneCommandLine.replay(["npm run start:local:ankur", "", "", ""]) == "npm run start:local:ankur")
    }

    /// `node /…/bin/pnpm run dev` reads as typed and survives an nvm upgrade.
    @Test func dropsTheInterpreterInFrontOfABinScript() {
        let argv = ["node", "/Users/me/.nvm/versions/node/v24.17.0/bin/nodemon", "dev-server.js"]
        #expect(PaneCommandLine.replay(argv) == "nodemon dev-server.js")
        #expect(PaneCommandLine.replay(["node", "server-local.js"]) == "node server-local.js")
    }

    @Test func quotesArgumentsWithSpaces() {
        #expect(PaneCommandLine.replay(["grep", "-r", "two words", "."]) == "grep -r 'two words' .")
    }

    @Test func refusesControlCharacters() {
        #expect(PaneCommandLine.replay(["echo", "a\nrm -rf x"]) == nil)
    }
}

@Suite
struct AgentDetectionTests {
    @Test func detectsNativeAndNpmInstalls() {
        #expect(AgentKind.detect(["claude"]) == .claude)
        #expect(AgentKind.detect(["/Users/me/.local/bin/claude", "--model", "opus"]) == .claude)
        #expect(AgentKind.detect(["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claude)
        #expect(AgentKind.detect(["node", "/x/node_modules/@openai/codex/bin/codex.js"]) == .codex)
        #expect(AgentKind.detect(["vim", "notes.md"]) == nil)
    }

    /// `q` is too generic a name: only its chat mode is the agent.
    @Test func amazonQCountsOnlyInChatMode() {
        #expect(AgentKind.detect(["q", "chat"]) == .amazonQ)
        #expect(AgentKind.detect(["q", "translate"]) == nil)
    }
}

@Suite
struct AgentResumeRulesTests {
    @Test func resumesAnExactSessionAndKeepsBehaviourFlags() {
        let command = AgentResumeRules.restoreCommand(
            kind: .claude,
            argv: ["claude", "--model", "opus", "--dangerously-skip-permissions", "fix the login bug"],
            evidence: .session(sessionID))
        #expect(command == .init(
            commandLine: "claude --resume \(sessionID) --model opus --dangerously-skip-permissions"))
    }

    /// The prompt must never be replayed: it would re-run the task.
    @Test func neverReplaysAPrompt() {
        let command = AgentResumeRules.restoreCommand(
            kind: .codex, argv: ["codex", "delete the old migrations"], evidence: .unknown)
        #expect(command == .init(commandLine: "codex"))
    }

    @Test func startsFreshWhenTheAgentNeverSavedAConversation() {
        let command = AgentResumeRules.restoreCommand(kind: .claude, argv: ["claude"], evidence: .none)
        #expect(command == .init(commandLine: "claude"))
    }

    @Test func usesAnIdFromTheOriginalLaunch() {
        let gemini = AgentResumeRules.restoreCommand(
            kind: .gemini, argv: ["gemini", "--resume", sessionID], evidence: .unknown)
        #expect(gemini == .init(commandLine: "gemini --resume \(sessionID)"))

        let codex = AgentResumeRules.restoreCommand(
            kind: .codex, argv: ["codex", "resume", sessionID, "-m", "gpt-5"], evidence: .unknown)
        #expect(codex == .init(commandLine: "codex resume \(sessionID) -m gpt-5"))

        let amp = AgentResumeRules.restoreCommand(
            kind: .amp, argv: ["amp", "threads", "continue", "T-1234abcd-ef"], evidence: .unknown)
        #expect(amp == .init(commandLine: "amp threads continue T-1234abcd-ef"))
    }

    /// "latest" and picker indexes are not ids: resuming them could land on
    /// the wrong conversation or a picker, so the agent starts fresh.
    @Test func ignoresNonIdResumeValues() {
        let latest = AgentResumeRules.restoreCommand(
            kind: .gemini, argv: ["gemini", "--resume", "latest"], evidence: .unknown)
        #expect(latest == .init(commandLine: "gemini"))
        let index = AgentResumeRules.restoreCommand(
            kind: .gemini, argv: ["gemini", "-r", "3"], evidence: .unknown)
        #expect(index == .init(commandLine: "gemini"))
    }

    @Test func amazonQResumesTheFoldersConversation() {
        let command = AgentResumeRules.restoreCommand(kind: .amazonQ, argv: ["q", "chat"], evidence: .unknown)
        #expect(command == .init(commandLine: "q chat --resume"))
    }

    @Test func readsFlagsInEqualsForm() {
        #expect(AgentResumeRules.sessionID(in: ["--session-id=\(sessionID)"], kind: .qwen) == sessionID)
        #expect(AgentResumeRules.kept(["--model=opus", "hi"], for: .claude) == ["--model=opus"])
    }
}

@Suite
struct AgentSessionRecordsTests {
    @Test func trustsAClaudeRecordOnlyForItsOwnPid() throws {
        let json = #"{"pid": 42, "sessionId": "\#(sessionID)", "cwd": "/Users/me/app"}"#
        let data = try #require(json.data(using: .utf8))
        #expect(AgentSessionRecords.claudeRecord(data, pid: 42) == .init(sessionID: sessionID, cwd: "/Users/me/app"))
        #expect(AgentSessionRecords.claudeRecord(data, pid: 43) == nil)
    }

    /// A Claude started from inside another Claude inherits the parent's id;
    /// only the value it set for its own children is its session.
    @Test func readsClaudesSessionFromItsChildrenNotItsInheritedEnv() {
        let parent = ["CLAUDE_CODE_SESSION_ID": "parent-session-0000"]
        let child = ["CLAUDE_CODE_SESSION_ID": sessionID]
        #expect(AgentSessionRecords.claudeChildSessionID(inherited: parent, children: [parent, child]) == sessionID)
        #expect(AgentSessionRecords.claudeChildSessionID(inherited: parent, children: [parent]) == nil)
        let other = ["CLAUDE_CODE_SESSION_ID": "another-session-0000"]
        #expect(AgentSessionRecords.claudeChildSessionID(inherited: [:], children: [child, other]) == nil)
    }

    @Test func slugsAProjectFolderLikeClaude() {
        #expect(AgentSessionRecords.claudeProjectSlug("/Users/me/projects/my.app_v2") == "-Users-me-projects-my-app-v2")
    }

    @Test func readsTheCodexThreadIdFromARolloutPath() {
        let base = "/Users/me/.codex/sessions/2026/11/18/rollout-2026-11-18T10-22-05-\(sessionID)"
        #expect(AgentSessionRecords.codexSessionID(base + ".jsonl") == sessionID)
        #expect(AgentSessionRecords.codexSessionID(base + "_2.jsonl") == sessionID)
        #expect(AgentSessionRecords.codexSessionID("/Users/me/.codex/history.jsonl") == nil)
    }
}

@Suite
struct PaneCommandResolverTests {
    private let noEvidence: PaneCommandResolver.EvidenceLookup = { _, _ in .unknown }

    @Test func idlePaneRestoresNothing() {
        #expect(PaneCommandResolver.resolve(job: [process(1, ["-zsh"])], evidence: noEvidence) == nil)
        #expect(PaneCommandResolver.resolve(job: [], evidence: noEvidence) == nil)
    }

    @Test func plainCommandRunsAgain() {
        let capture = PaneCommandResolver.resolve(
            job: [process(10, ["npm run dev", "", ""], cwd: "/srv/app"), process(11, ["node", "server.js"])],
            evidence: noEvidence)
        #expect(capture == .init(command: .init(commandLine: "npm run dev"),
                                 workingDirectory: "/srv/app"))
    }

    /// `npx` leads the job; the agent is a child, and its pid is what the
    /// session lookup must see.
    @Test func findsAnAgentBehindAWrapper() {
        var askedPIDs: [Int] = []
        let capture = PaneCommandResolver.resolve(
            job: [process(10, ["npm exec @openai/codex", ""]),
                  process(11, ["node", "/x/@openai/codex/bin/codex.js"], cwd: "/repo"),
                  process(12, ["/x/codex-darwin-arm64/codex"], cwd: "/repo")],
            evidence: { kind, processes in
                askedPIDs = processes.map(\.pid)
                return kind == .codex ? .session(sessionID) : .unknown
            })
        #expect(askedPIDs == [11, 12])
        #expect(capture == .init(command: .init(commandLine: "codex resume \(sessionID)"),
                                 workingDirectory: "/repo"))
    }
}

@Suite
struct PaneCommandCacheTests {
    private let pane = UUID()

    private func cache(counting reads: Reference) -> PaneCommandCache {
        PaneCommandCache(readJob: { pid in
            reads.value += 1
            return [process(pid, ["npm", "run", "dev"])]
        })
    }

    final class Reference { var value = 0 }

    @Test func reusesARecentCaptureForTheSameProcess() {
        let reads = Reference()
        let cache = cache(counting: reads)
        let start = Date()
        _ = cache.capture(pane: pane, foregroundPID: 7, fresh: false, now: start)
        _ = cache.capture(pane: pane, foregroundPID: 7, fresh: false, now: start.addingTimeInterval(2))
        #expect(reads.value == 1)
        _ = cache.capture(pane: pane, foregroundPID: 8, fresh: false, now: start.addingTimeInterval(3))
        #expect(reads.value == 2)
        _ = cache.capture(pane: pane, foregroundPID: 8, fresh: true, now: start.addingTimeInterval(4))
        #expect(reads.value == 3)
    }

    /// At quit the pty may already be gone: keep the last good capture.
    @Test func keepsTheLastCaptureWhenTheProcessIsGone() {
        let cache = cache(counting: Reference())
        let first = cache.capture(pane: pane, foregroundPID: 7, fresh: false)
        #expect(first != nil)
        #expect(cache.capture(pane: pane, foregroundPID: nil, fresh: true) == first)
    }

    @Test func pruneDropsClosedPanes() {
        let cache = cache(counting: Reference())
        _ = cache.capture(pane: pane, foregroundPID: 7, fresh: false)
        _ = cache.capture(pane: UUID(), foregroundPID: 8, fresh: false)
        cache.prune(keeping: [pane])
        #expect(cache.count == 1)
    }
}

@Suite
struct PaneRestorePersistenceTests {
    private func session(_ pane: SavedSession.Pane) -> SavedSession {
        SavedSession(name: "api", createdAt: Date(), updatedAt: Date(), layout: .leaf(pane))
    }

    private let pane = SavedSession.Pane(kind: .local, workingDirectory: "/srv")

    @Test func fingerprintIgnoresSnapshotIdentityButNotContent() {
        let first = session(pane)
        let second = session(pane)
        #expect(TabSessionStore.fingerprint([first]) == TabSessionStore.fingerprint([second]))

        var running = pane
        running.restoreCommand = .init(commandLine: "npm run dev")
        #expect(TabSessionStore.fingerprint([first]) != TabSessionStore.fingerprint([session(running)]))
    }

    /// session.json written by an older build has no restoreCommand.
    @Test func decodesPanesSavedBeforeTheField() throws {
        let json = #"{"kind": "local", "workingDirectory": "/srv"}"#
        let decoded = try JSONDecoder().decode(SavedSession.Pane.self, from: Data(json.utf8))
        #expect(decoded.restoreCommand == nil)
    }

    @Test func procArgsParserSkipsExecPathAndPadding() {
        var bytes: [UInt8] = withUnsafeBytes(of: Int32(2).littleEndian) { Array($0) }
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("server.js".utf8) + [0]
        bytes += Array("PATH=/bin".utf8) + [0]
        let parsed = RunningProcessReader.parseProcArgs(bytes)
        #expect(parsed?.argv == ["node", "server.js"])
        #expect(parsed?.environment == ["PATH=/bin"])
    }
}

@Suite
struct AgentSessionWatchTests {
    private let home = "/Users/me"

    @Test func readsThePidFromAClaudeSessionFile() {
        #expect(AgentSessionWatch.claudePID(fromPath: "\(home)/.claude/sessions/4242.json") == 4242)
        #expect(AgentSessionWatch.claudePID(fromPath: "\(home)/.claude/sessions/4242.abc.key") == nil)
        #expect(AgentSessionWatch.claudePID(fromPath: "\(home)/.claude/projects/4242.json") == nil)
        #expect(AgentSessionWatch.claudePID(fromPath: "\(home)/.claude/sessions/x42.json") == nil)
    }

    @Test func routesEachChangeToItsPane() {
        let claudePane = UUID(), codexPane = UUID(), otherClaude = UUID()
        let tracked: [UUID: TrackedAgent] = [
            claudePane: .init(kind: .claude, pids: [10, 11]),
            otherClaude: .init(kind: .claude, pids: [20]),
            codexPane: .init(kind: .codex, pids: [30]),
        ]
        #expect(AgentSessionWatch.panesToRefresh(
            changedPaths: ["\(home)/.claude/sessions/11.json"], tracked: tracked) == [claudePane])
        #expect(AgentSessionWatch.panesToRefresh(
            changedPaths: ["\(home)/.codex/sessions/2026/11/18/rollout-2026-11-18T10-00-00-abc.jsonl"],
            tracked: tracked) == [codexPane])
        #expect(AgentSessionWatch.panesToRefresh(
            changedPaths: ["\(home)/.claude/sessions/99.json"], tracked: tracked).isEmpty)
        #expect(!AgentSessionWatch.isRelevant(["\(home)/.claude/sessions/11.abc.key"]))
    }

    @Test func watchesTheParentUntilTheSessionsFolderExists() {
        let url = URL(fileURLWithPath: home)
        let existing: Set<String> = ["\(home)/.claude/sessions", "\(home)/.codex"]
        #expect(AgentSessionWatch.watchedDirectories(home: url, exists: existing.contains)
            == ["\(home)/.claude/sessions", "\(home)/.codex"])
        #expect(AgentSessionWatch.watchedDirectories(home: url, exists: { _ in false }).isEmpty)
    }

    @Test func tracksTheAgentAndItsChildren() {
        let job = [process(1, ["node", "/usr/local/bin/claude"]), process(2, ["claude"]), process(3, ["mcp-server"])]
        #expect(PaneCommandResolver.trackedAgent(in: job)?.kind == .claude)
        #expect(PaneCommandResolver.trackedAgent(in: [process(1, ["npm", "run", "dev"])]) == nil)
    }

    @Test func aWatchedAgentCaptureStaysUntilInvalidated() {
        let pane = UUID()
        var reads = 0
        let cache = PaneCommandCache(
            locator: AgentSessionLocator(home: URL(fileURLWithPath: "/nonexistent")),
            readJob: { pid in reads += 1; return [process(pid, ["claude"])] })
        let start = Date()
        _ = cache.capture(pane: pane, foregroundPID: 5, fresh: false, now: start)
        _ = cache.capture(pane: pane, foregroundPID: 5, fresh: false, now: start.addingTimeInterval(60))
        #expect(reads == 1)
        #expect(cache.trackedAgents[pane]?.kind == .claude)
        cache.invalidate(panes: [pane])
        _ = cache.capture(pane: pane, foregroundPID: 5, fresh: false, now: start.addingTimeInterval(61))
        #expect(reads == 2)
    }

    @Test func anUnwatchedAgentStillExpires() {
        let pane = UUID()
        var reads = 0
        let cache = PaneCommandCache(readJob: { pid in reads += 1; return [process(pid, ["gemini"])] })
        let start = Date()
        _ = cache.capture(pane: pane, foregroundPID: 5, fresh: false, now: start)
        _ = cache.capture(pane: pane, foregroundPID: 5, fresh: false, now: start.addingTimeInterval(PaneCommandCache.maxAge + 1))
        #expect(reads == 2)
    }
}

@Suite(.serialized)
struct FileEventStreamTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    @Test func deliversAChangedFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("123.json")
        var seen: [String] = []
        let stream = FileEventStream(directories: [directory.path], latency: 0.05) { seen += $0 }
        #expect(stream != nil)
        try Data("{}".utf8).write(to: file)
        // FSEvents reports real paths (/private/var for /var), so match the name.
        let delivered = { seen.contains { $0.hasSuffix("/" + file.lastPathComponent) } }
        for _ in 0..<100 where !delivered() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(delivered())
        stream?.stop()
    }

    /// The stream must not keep its handler (and what it captures) alive.
    /// FSEvents drops its last reference on the delivery queue, so let the
    /// main queue drain before checking.
    @MainActor
    @Test func releasesItsHandlerWhenDropped() async throws {
        final class Owner {}
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var weakOwner: Owner?
        var stream: FileEventStream?
        do {
            let owner = Owner()
            weakOwner = owner
            stream = FileEventStream(directories: [directory.path]) { _ in _ = owner }
            #expect(stream != nil)
        }
        #expect(weakOwner != nil)
        stream = nil
        for _ in 0..<40 where weakOwner != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(weakOwner == nil)
    }

    @Test func refusesAnEmptyDirectoryList() {
        #expect(FileEventStream(directories: []) { _ in } == nil)
    }
}

@Suite
struct InheritedAgentEnvironmentTests {
    /// Launched from inside Claude, the app must not hand that session's
    /// variables to its shells, or a `claude` started there writes no
    /// per-pid record and can't be resumed on reopen.
    @Test func picksOnlyAParentClaudeSessionsVariables() {
        let environment = [
            "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "abc", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_PID": "42", "CLAUDE_EFFORT": "high",
            "CLAUDE_CONFIG_DIR": "/cfg", "PATH": "/bin", "HOME": "/Users/me",
        ]
        #expect(InheritedAgentEnvironment.leakedNames(in: environment) == [
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_EFFORT", "CLAUDE_PID",
        ])
    }

    @Test func decodesARestoreCommandSavedWithTheOldAutoRunKey() throws {
        let json = #"{"commandLine": "npm run dev", "autoRun": false}"#
        let decoded = try JSONDecoder().decode(SavedSession.RestoreCommand.self, from: Data(json.utf8))
        #expect(decoded == .init(commandLine: "npm run dev"))
    }
}
