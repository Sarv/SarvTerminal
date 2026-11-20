import Foundation

/// A definite "ssh has logged in" signal for the connect watcher. ssh runs
/// `LocalCommand` on this Mac right after authentication succeeds, before the
/// remote shell starts; ours creates an empty marker file. Without it the
/// watcher could only guess from the screen whether a shell prompt appeared,
/// which fails for any prompt not ending in `$ # % ❯ >` (oh-my-zsh's
/// `➜  ~`, a right-side prompt, zsh's new-user menu). Pure.
enum SSHSessionMarker {
    /// A fresh marker path in the temp directory. Nothing is created: ssh does.
    static func makePath(directory: String = NSTemporaryDirectory(), id: UUID = UUID()) -> String {
        (directory as NSString).appendingPathComponent("sarv-ssh-\(id.uuidString).ready")
    }

    /// `command` with the options that touch `markerPath` once logged in. Only
    /// a plain `ssh …` command is changed. Behind a jump host only the final
    /// hop runs it (`-o` options don't reach ProxyJump hops), which is the
    /// login that matters.
    static func command(_ command: String, markerPath: String) -> String {
        guard command.hasPrefix("ssh ") else { return command }
        // ssh expands %-tokens in LocalCommand, then runs it with the user's
        // shell, so the path is shell-quoted and its % signs doubled.
        let localCommand = "/usr/bin/touch \(shellQuote(markerPath))"
            .replacingOccurrences(of: "%", with: "%%")
        let options = "-o PermitLocalCommand=yes -o \(shellQuote("LocalCommand=\(localCommand)"))"
        return "ssh \(options) \(command.dropFirst(4))"
    }
}
