import AppKit

/// Relaunches the running app in place. Spawns a tiny detached shell that waits
/// for this process to fully exit, then reopens the bundle — so there's never a
/// moment with two live instances — and kicks off a normal quit (which still
/// runs `applicationWillTerminate`, so the open-tabs session is persisted and
/// any running-process confirm-quit is honored).
enum AppRelaunch {
    static func now() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \(shellQuoted(bundlePath))"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApp.terminate(nil)
    }

    /// Single-quote a string for safe interpolation into a `/bin/sh -c` command.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
