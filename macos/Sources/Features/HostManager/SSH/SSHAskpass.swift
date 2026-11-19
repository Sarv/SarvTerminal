import Foundation

/// Feeds SSH passwords to `ssh` out-of-band via an `SSH_ASKPASS` helper, so ssh
/// never prompts for the password on the terminal (no "password:" line, no echo).
///
/// The helper is a tiny one-shot script: it prints a per-connection password
/// file's contents to stdout, then deletes the file. We set `SSH_ASKPASS` +
/// `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+, which macOS ships) on the ssh
/// surface's environment so ssh calls the helper instead of the TTY.
enum SSHAskpass {
    /// Path to the helper script, (re)created on first access.
    /// Prints the password file's contents. ssh may call askpass more than once
    /// (e.g. password + keyboard-interactive), so we do NOT delete the file
    /// here — the app removes it on connect / close / relaunch.
    private static let helperPath: String? = writeHelper(named: "sarv-askpass.sh", script: """
        #!/bin/sh
        cat "$SARV_ASKPASS_FILE"
        """)

    /// Interactive helper for `SSHPromptBroker`: hands the prompt (and the
    /// asking ssh's pid) to the app as `<id>.req` in `$SARV_PROMPT_DIR`, waits
    /// for `<id>.resp` ("OK" + answer, or "CANCEL"), and prints the answer.
    /// Gives up after 10 minutes or when the app removes the directory.
    static let interactiveHelperPath: String? = writeHelper(named: "sarv-askpass-prompt.sh", script: """
        #!/bin/sh
        d="$SARV_PROMPT_DIR"
        [ -d "$d" ] || exit 1
        id="$$"
        printf '%s\\n%s' "$PPID" "$1" > "$d/$id.tmp" || exit 1
        mv "$d/$id.tmp" "$d/$id.req" || exit 1
        n=0
        while [ ! -f "$d/$id.resp" ]; do
          [ -d "$d" ] || exit 1
          n=$((n + 1))
          [ "$n" -gt 3000 ] && exit 1
          sleep 0.2
        done
        { IFS= read -r status; IFS= read -r answer; } < "$d/$id.resp"
        rm -f "$d/$id.resp"
        [ "$status" = OK ] || exit 1
        printf '%s\\n' "$answer"
        """)

    private static func writeHelper(named name: String, script: String) -> String? {
        guard let dir = supportDirectory() else { return nil }
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    private static func supportDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
    }

    /// Environment variables to set on an ssh surface so it reads `password`
    /// from the askpass helper. Returns an empty dict for an empty password (key
    /// / agent auth — ssh should not be forced through askpass then).
    static func env(forPassword password: String) -> [String: String] {
        guard !password.isEmpty, let helper = helperPath else { return [:] }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-ssh-\(UUID().uuidString)")
        do {
            // Newline-terminated; ssh strips the trailing newline.
            try (password + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return [:]
        }
        return [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            "SARV_ASKPASS_FILE": fileURL.path,
        ]
    }
}
