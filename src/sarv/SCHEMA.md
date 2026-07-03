# Sarv Data Layer — On-Disk Schema Reference

The contract between the macOS (Swift) and Linux (Zig) implementations.
Both sides MUST read/write these formats identically — encrypted settings
sync moves these payloads between machines of either OS.

Extracted from the Swift sources (SavedHost.swift, HostGroup.swift,
Snippets.swift, PortForwarding.swift, ActivityLog.swift, SavedSession.swift,
SyncManifest.swift, SyncCrypto.swift, LocalDataCrypto.swift, AppPaths.swift).
If a Swift model changes, update this file and `src/sarv/model.zig` together.

## Common conventions

- JSON keys: Swift property names verbatim (camelCase, no key strategy).
- Dates: ISO-8601 strings (`2026-07-03T12:34:56Z`).
- UUIDs: lowercase hyphenated strings.
- Optionals: key absent when nil (Swift `encodeIfPresent` behavior) —
  Zig must use `emit_null_optional_fields = false`.
- Decoding is lenient: missing fields take defaults (Swift manual decoders);
  unknown fields are ignored (forward compatibility).

## Files (all under the config dir)

| File | Content | Encrypted at rest |
| --- | --- | --- |
| hosts.json | `[SavedHost]` | yes |
| groups.json | `[HostGroup]` | no (pretty-printed, sorted keys) |
| snippets.json | `[Snippet]` | yes |
| portforwards.json | `[PortForward]` | yes |
| saved-sessions.json | `[SavedSession]` | yes |
| activity.json | `[ActivityEntry]` (max 1000, newest first) | no |
| pinned-history.json | `[String]` (shell commands) | yes |

Config dir: `$XDG_CONFIG_HOME`/`~/.config` + `sarvterminal` (release) or
`sarvterminal-dev` (debug).

## Models

### SavedHost
`id` uuid · `label` str · `hostname` str · `port` int=22 · `username` str
· `note` str · `authMethod` enum(`password`|`publicKey`|`agent`|`ask`)=password
· `identityFile` str · `password` str · `forwardAgent` bool=false
· `strictHostKeyChecking` enum(`yes`|`no`|`ask`|`accept-new`)=ask
· `connectTimeoutSeconds` int=0 · `serverAliveIntervalSeconds` int=0
· `useCompression` bool=false · `requestTTY` bool=false · `proxyJump` str
· `localForwards` [str] · `remoteForwards` [str] · `dynamicForwardPort` int=0
· `initialCommand` str · `groupID` uuid? · `group` str (legacy) · `tags` [str]
· `themeName` str · `createdAt` date · `updatedAt` date

### HostGroup
`id` uuid · `name` str · `parentID` uuid? · `iconSystemName` str="folder.fill"
· `colorHex` str · `createdAt` date · `updatedAt` date

### Snippet
`id` uuid · `name` str · `command` str · `pinned` bool=false
· `createdAt` date · `updatedAt` date

### PortForward
`id` uuid · `name` str · `kind` enum(`local`|`remote`|`dynamic`)=local
· `hostID` uuid · `bindAddress` str="127.0.0.1" · `listenPort` int=8080
· `destinationHost` str="localhost" · `destinationPort` int=80
· `createdAt` date · `updatedAt` date

### ActivityEntry
`id` uuid · `date` date
· `category` enum(`connection`|`sync`|`transfer`|`error`|`info`)
· `title` str · `detail` str? · `success` bool=true

### SavedSession
`id` uuid · `name` str · `createdAt` date · `updatedAt` date · `colorID` str?
· `layout` PaneNode where PaneNode = `{"leaf": Pane}` |
`{"split": {"direction": "horizontal"|"vertical", "ratio": f64,
"left": PaneNode, "right": PaneNode}}` and Pane =
`kind` enum(`local`|`ssh`) · `workingDirectory` str? · `hostID` uuid?
· `command` str? · `title` str?

## At-rest encryption envelope (SarvEncEnvelope)

Encrypted files are a JSON envelope:

```json
{ "sarvEnc": 1, "blob": "<base64(nonce ‖ ciphertext ‖ tag)>" }
```

- AES-256-GCM, combined layout: 12-byte nonce ‖ ciphertext ‖ 16-byte tag.
- macOS: data key wrapped by Secure Enclave (ECIES) or device-only Keychain.
- Linux: data key from Secret Service (libsecret); file fallback
  `keystore/data-key-raw` (0600) mirrors the macOS debug keystore.
- Plaintext legacy files are detected (no `sarvEnc` key) and migrated;
  original saved as `<name>.pre-encryption.bak`.

## Sync (remote) format

- `manifest.json` (plaintext, sorted keys): `schema` int=1 · `version` int
  (monotonic) · `lastSyncDate` date · `deviceName` str · `kdfSalt` base64
  (16 bytes) · `kdfIterations` int (310000) · `verifier` base64
  (AES-GCM-combined of literal `sarv-sync-verifier-v1`) · `files` [str]
- `settings.enc`, `hosts.enc`: raw AES-256-GCM combined bytes (NO JSON
  envelope), key = PBKDF2-HMAC-SHA256(password, kdfSalt, kdfIterations, 32).
- `hosts.enc` plaintext = `{"hosts": [SavedHost], "groups": [HostGroup],
  "snippets": [Snippet]?}` (sorted keys).
- `settings.enc` plaintext = SyncSettingsPayload: `ghosttyConfig` str?
  · `bgShared` bool? · `bgImagePath` str? · `bgVisibility` f64?
  · `appKeybinds` {str:[str]}? · `sftpAutoSave` bool? · `sftpConfirmDelete`
  bool? · `sftpShowHidden` bool? · `backgroundImage` {name str, data base64}?
  — all optional, only non-nil serialized. Blank/default values never
  overwrite populated values on pull.
