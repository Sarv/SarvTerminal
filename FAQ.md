# Sarv Terminal — FAQ

Common questions about how Sarv Terminal behaves. Don't see yours here?
[Open an issue](https://github.com/Sarv/SarvTerminal/issues).

## Pressing Up Arrow shows commands from my other tabs/sessions

This is controlled by your **shell**, not by Sarv Terminal. Command history and
Up-Arrow recall are handled by your shell's readline (zsh / bash), and many shell
setups enable *shared history* — every command is written to a single history file
immediately and re-read on each prompt, so all tabs end up seeing one another's
commands.

Sarv Terminal does **not** enable this itself. It behaves identically in iTerm2,
Terminal.app, or upstream Ghostty with the same shell configuration. We deliberately
don't override it: the alternatives — keeping a separate history file per tab (which
loses that session's history when the tab closes, and leaves orphaned files after a
crash) or rewriting your `~/.zshrc` / `~/.bashrc` — are worse than leaving your shell
in control.

To get **per-tab** Up-Arrow history:

**zsh** — in `~/.zshrc`, disable shared history:

```sh
unsetopt SHARE_HISTORY
```

If a framework like oh-my-zsh / prezto enabled it, add this line *after* the framework
loads. You can keep `INC_APPEND_HISTORY` if you still want each command written to the
shared file for safekeeping — on its own it does not cause the cross-tab bleed.

**bash** — in `~/.bashrc`, remove `history -a; history -n` from `PROMPT_COMMAND` (and
drop `shopt -s histappend` if you don't want a shared history file at all).

Restart your shell or open a new tab for the change to take effect.
