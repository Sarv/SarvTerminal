# Contributing to Sarv Terminal

**Everyone is welcome — let's make this a wonderful, full-fledged open-source terminal together.** 🎉

This document describes how to contribute to
[Sarv Terminal](https://github.com/Sarv/SarvTerminal) — whether you're fixing a
bug, polishing the UI, improving docs, or taking on a big feature. For build
internals and how the engine works, see [HACKING.md](HACKING.md).

## Where help matters most

- **🐧 A Linux UI** — the single biggest opportunity. The terminal *engine* is
  cross-platform, but the Sarv Terminal experience (Vaults, SFTP, Keychain,
  Port Forwarding, Sync) is currently SwiftUI/macOS only. If you're a GTK/Qt
  developer, we'd love your help.
- **🔒 Security hardening** — moving host passwords into the Keychain, audits,
  threat-model review.
- **🚀 Releases & packaging** — CI, signed/notarized builds, Homebrew.
- **📸 Docs & screenshots** — including the README gallery
  (see [`assets/screenshots/`](assets/screenshots)).

Of course, bug fixes and improvements anywhere in the app are just as welcome.

## I have a bug / something isn't working

1. Search the [issue tracker](https://github.com/Sarv/SarvTerminal/issues) —
   including closed issues — in case it's already reported or fixed.
2. If it's new, [open an issue](https://github.com/Sarv/SarvTerminal/issues/new)
   with your macOS version, app version (About screen), clear steps to
   reproduce, and what you expected vs. what happened.
3. For serial-console problems, please include your adapter/chipset — serial
   behavior is very hardware-specific (the in-app "report an issue" helper
   pre-fills this for you).

## I have an idea for a feature

Open an issue describing the problem you're trying to solve and the behavior
you'd like. For large features, please discuss **before** writing code so we
can align on the design — it saves everyone time.

## Pull requests

1. **Open an issue or discussion first** for anything non-trivial, so we can
   agree on direction before you invest significant effort.
2. Fork, create a branch, and keep the pull request **small and focused** —
   one logical change per PR.
3. Use [Conventional Commit](https://www.conventionalcommits.org/) messages
   (`feat:`, `fix:`, `docs:`, `refactor:`…), with small, logically-grouped
   commits.
4. Make sure it builds and runs:
   ```sh
   zig build        # builds the macOS app bundle
   zig build test   # run the Zig test suite
   ```
5. Format your changes: `zig fmt .` for Zig, `swiftlint lint --strict --fix`
   for Swift, and `prettier -w .` for everything else.
6. **Understand your code.** AI-assisted development is fine, but you should be
   able to explain what your change does and how it interacts with the rest of
   the system. Please don't submit generated code you haven't reviewed and
   understood.

## Code of conduct

Be kind and constructive — we want this to be a friendly community. Treat
everyone with respect.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
