#!/bin/sh
# Seed sample Sarv data so the GTK dialogs show content while testing.
#
# Writes plaintext JSON into the dev config dir; the stores read these via the
# legacy-plaintext path and migrate them to encrypted files on first save.
# Safe to re-run — it overwrites the sample files.
#
# Usage:
#   ./scripts/linux/seed-dev-data.sh            # seeds the debug/dev dir
#   SARV_DIR=~/.config/sarvterminal ./scripts/linux/seed-dev-data.sh   # release dir
set -eu

# `zig build run` produces a DEBUG build, which uses the -dev config dir.
BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
DIR="${SARV_DIR:-$BASE/sarvterminal-dev}"
mkdir -p "$DIR"
echo "seeding sample data into: $DIR"

cat > "$DIR/groups.json" <<'JSON'
[
  {"id":"11111111-1111-4111-8111-111111111111","name":"Production","parentID":null,"iconSystemName":"folder.fill","colorHex":"#FF9F0A","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"22222222-2222-4222-8222-222222222222","name":"Databases","parentID":"11111111-1111-4111-8111-111111111111","iconSystemName":"folder.fill","colorHex":"","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"33333333-3333-4333-8333-333333333333","name":"Personal","parentID":null,"iconSystemName":"folder.fill","colorHex":"","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
JSON

cat > "$DIR/hosts.json" <<'JSON'
[
  {"id":"aaaaaaaa-0000-4000-8000-000000000001","label":"web-prod-01","hostname":"203.0.113.10","port":22,"username":"deploy","authMethod":"ask","groupID":"11111111-1111-4111-8111-111111111111","tags":["web"],"createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"aaaaaaaa-0000-4000-8000-000000000002","label":"db-primary","hostname":"10.0.5.20","port":22,"username":"postgres","authMethod":"publicKey","identityFile":"~/.ssh/id_ed25519","groupID":"22222222-2222-4222-8222-222222222222","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"aaaaaaaa-0000-4000-8000-000000000003","label":"raspberry-pi","hostname":"192.168.1.50","port":22,"username":"pi","authMethod":"password","password":"changeme","groupID":"33333333-3333-4333-8333-333333333333","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"aaaaaaaa-0000-4000-8000-000000000004","label":"localhost","hostname":"127.0.0.1","port":22,"username":"","authMethod":"ask","note":"Local shell over SSH","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
JSON

cat > "$DIR/snippets.json" <<'JSON'
[
  {"id":"bbbbbbbb-0000-4000-8000-000000000001","name":"Tail syslog","command":"sudo tail -f /var/log/syslog","pinned":true,"createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"bbbbbbbb-0000-4000-8000-000000000002","name":"Disk usage","command":"df -h","pinned":false,"createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"bbbbbbbb-0000-4000-8000-000000000003","name":"Docker ps","command":"docker ps -a","pinned":false,"createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
JSON

cat > "$DIR/portforwards.json" <<'JSON'
[
  {"id":"cccccccc-0000-4000-8000-000000000001","name":"Postgres tunnel","kind":"local","hostID":"aaaaaaaa-0000-4000-8000-000000000002","bindAddress":"127.0.0.1","listenPort":5432,"destinationHost":"localhost","destinationPort":5432,"createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"},
  {"id":"cccccccc-0000-4000-8000-000000000002","name":"SOCKS proxy","kind":"dynamic","hostID":"aaaaaaaa-0000-4000-8000-000000000001","bindAddress":"127.0.0.1","listenPort":1080,"destinationHost":"localhost","destinationPort":0,"createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-01T00:00:00Z"}
]
JSON

# --- SSH Keys + Known Hosts populate the real ~/.ssh (those dialogs read it,
# not the vault). Demo material is clearly named and idempotent (safe re-run).
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if command -v ssh-keygen >/dev/null 2>&1; then
  for spec in "ed25519:sarv_demo_ed25519" "rsa:sarv_demo_rsa"; do
    typ="${spec%%:*}"; name="${spec##*:}"
    if [ ! -f "$SSH_DIR/$name" ]; then
      ssh-keygen -q -t "$typ" -f "$SSH_DIR/$name" -N "" -C "sarv-demo-$typ" || true
      echo "generated demo key: $SSH_DIR/$name"
    fi
  done

  # Seed a few known_hosts entries from the demo pubkey (valid, parseable).
  KH="$SSH_DIR/known_hosts"
  if ! grep -q "sarv-demo-known-host" "$KH" 2>/dev/null && [ -f "$SSH_DIR/sarv_demo_ed25519.pub" ]; then
    keypair="$(cut -d' ' -f1,2 "$SSH_DIR/sarv_demo_ed25519.pub")"
    {
      echo "web-prod-01.example.com $keypair sarv-demo-known-host"
      echo "db-primary.example.com $keypair sarv-demo-known-host"
      echo "[raspberry-pi.local]:2222 $keypair sarv-demo-known-host"
    } >> "$KH"
    chmod 600 "$KH"
    echo "seeded 3 known_hosts entries into $KH"
  fi
else
  echo "note: ssh-keygen not found — skipped SSH Keys + Known Hosts demo data."
fi

echo
echo "done. seeded:"
echo "  Hosts (4), Groups (3), Snippets (3), Port Forwarding (2)  [vault: $DIR]"
echo "  SSH Keys (2 demo) + Known Hosts (3 demo)                  [$SSH_DIR]"
echo "launch the app and open the ☰ menu → Hosts / SSH Keys / Known Hosts /"
echo "Snippets / Port Forwarding / Files."
echo
echo "to remove the SSH demo material later:"
echo "  rm -f $SSH_DIR/sarv_demo_* ; sed -i '/sarv-demo-known-host/d' $SSH_DIR/known_hosts"
