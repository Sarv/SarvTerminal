import Foundation

/// Turns a captured argv into a command line a user would recognise and can
/// re-run at a shell prompt. Pure, no I/O.
enum PaneCommandLine {
    /// Shells mean "nothing running": an idle pane has nothing to replay.
    static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "nu", "dash", "ksh", "tcsh", "csh", "elvish", "xonsh", "pwsh", "login",
    ]

    /// Interpreters whose second argument may be an installed bin script, so
    /// `node /…/bin/pnpm run dev` replays as `pnpm run dev`.
    private static let interpreterPrefixes = ["node", "python", "ruby", "perl", "bun"]

    /// The replayable command line for `argv`, or nil when there is nothing
    /// worth replaying (no args, or the foreground is just a shell).
    static func replay(_ argv: [String]) -> String? {
        let words = readableArguments(normalized(argv))
        guard let first = words.first, !isShell(first) else { return nil }
        let line = words.map(Ghostty.Shell.quote).joined(separator: " ")
        // Control characters (Return, Ctrl-U…) would act as they are typed.
        return Ghostty.Shell.containsControlCharacters(line) ? nil : line
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func isShell(_ program: String) -> Bool {
        var name = basename(program)
        if name.hasPrefix("-") { name.removeFirst() }
        return shellNames.contains(name)
    }

    /// Node tools (npm, pnpm, yarn) set `process.title`, which overwrites the
    /// argv area: argv[0] becomes "npm run dev" and the rest are blanked.
    /// Split that back into words.
    static func normalized(_ argv: [String]) -> [String] {
        guard let first = argv.first, first.contains(" "),
              argv.dropFirst().allSatisfy({ $0.isEmpty }) else {
            return argv
        }
        return first.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Drop an interpreter that only runs an installed bin script, so the line
    /// reads as the user typed it and survives a runtime upgrade (an absolute
    /// nvm path would pin the old Node version).
    static func readableArguments(_ argv: [String]) -> [String] {
        guard argv.count >= 2 else { return argv }
        let interpreter = basename(argv[0]).lowercased()
        let script = argv[1]
        let isInterpreter = interpreterPrefixes.contains { interpreter.hasPrefix($0) }
        let parent = basename((script as NSString).deletingLastPathComponent)
        guard isInterpreter, script.hasPrefix("/"), parent == "bin" || parent == ".bin" else { return argv }
        return [basename(script)] + argv.dropFirst(2)
    }
}
