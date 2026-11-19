import Foundation
import Testing
@testable import Ghostty

struct AgentForegroundTests {
    private func process(_ pid: Int, _ argv: [String]) -> RunningProcess {
        RunningProcess(pid: pid, argv: argv, workingDirectory: nil)
    }

    @Test func shellIsDecidedWithoutReadingTheJob() {
        let foreground = AgentForeground.classify(processName: "zsh") {
            Issue.record("a shell's job must not be read")
            return []
        }
        #expect(foreground == .shell)
    }

    /// Claude's native install runs a binary named after its version.
    @Test func versionNamedClaudeIsAnAgent() {
        let job = [process(10, ["claude", "--resume", "abc"])]
        #expect(AgentForeground.classify(processName: "2.1.328") { job } == .agent(.claude))
    }

    /// npm installs show up as `node`.
    @Test func npmInstalledAgentsAreRecognised() {
        let cases: [(String, AgentKind)] = [
            ("/x/node_modules/@openai/codex/bin/codex.js", .codex),
            ("/x/node_modules/@google/gemini-cli/dist/index.js", .gemini),
            ("/x/node_modules/@github/copilot/index.js", .copilot),
            ("/x/node_modules/@qwen-code/qwen-code/cli.js", .qwen),
            ("/x/node_modules/@factory/cli/bin/droid", .droid),
        ]
        for (script, kind) in cases {
            let job = [process(10, ["node", script])]
            #expect(AgentForeground.classify(processName: "node") { job } == .agent(kind))
        }
    }

    @Test func everyNativeAgentIsRecognised() {
        for kind in AgentKind.allCases {
            let argv = [kind.program] + ((kind == .amazonQ || kind == .kiro) ? ["chat"] : [])
            #expect(AgentForeground.classify(processName: kind.program) { [process(10, argv)] } == .agent(kind))
        }
    }

    @Test func otherProgramsAreNotAgents() {
        #expect(AgentForeground.classify(processName: "vim") { [process(10, ["vim", "a.md"])] } == .other)
        #expect(AgentForeground.classify(processName: "q") { [process(10, ["q", "translate"])] } == .other)
    }

    @Test func cacheReadsAProcessOnce() {
        var cache = AgentForegroundCache()
        let pane = UUID()
        var reads = 0
        let readJob: (Int) -> [RunningProcess] = { pid in reads += 1; return [RunningProcess(pid: pid, argv: ["claude"], workingDirectory: nil)] }
        _ = cache.foreground(pane: pane, pid: 10, processName: "claude", readJob: readJob)
        _ = cache.foreground(pane: pane, pid: 10, processName: "claude", readJob: readJob)
        #expect(reads == 1)
        // A new process in the pane is read again.
        _ = cache.foreground(pane: pane, pid: 11, processName: "claude", readJob: readJob)
        #expect(reads == 2)
    }
}
