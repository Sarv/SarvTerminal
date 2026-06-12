#!/usr/bin/env bash
# One-shot bootstrap: push your current Warp settings to a private GitHub repo.
# Usage:
#   GH_TOKEN=ghp_xxx REPO_URL=https://github.com/you/warp-data bash bootstrap-sync.sh
#
# Optionally provide a master password to encrypt SSH hosts:
#   MASTER_PASS=secret GH_TOKEN=... REPO_URL=... bash bootstrap-sync.sh
set -euo pipefail

: "${GH_TOKEN:?  Set GH_TOKEN=ghp_your_token}"
: "${REPO_URL:?  Set REPO_URL=https://github.com/yourname/repo}"

SYNC_DIR="$HOME/.warp-sync"
REPO_DIR="$SYNC_DIR/repo"
WARP_CONFIG="$HOME/.warp"
WARP_OSS_CONFIG="$HOME/.warp-oss"

# --------------------------------------------------------------------------
# 1. Clone (or init) the data repo
# --------------------------------------------------------------------------
mkdir -p "$SYNC_DIR"
chmod 700 "$SYNC_DIR"

if [[ -d "$REPO_DIR/.git" ]]; then
    echo "Repo already cloned at $REPO_DIR — pulling latest..."
    git -C "$REPO_DIR" \
        -c "credential.helper=" \
        -c "credential.helper=!f(){ echo username=x; echo \"password=${GH_TOKEN}\"; }; f" \
        pull origin main --quiet 2>/dev/null || true
else
    echo "Cloning $REPO_URL..."
    git -c "credential.helper=" \
        -c "credential.helper=!f(){ echo username=x; echo \"password=${GH_TOKEN}\"; }; f" \
        clone "$REPO_URL" "$REPO_DIR"
fi

mkdir -p "$REPO_DIR/config"

# --------------------------------------------------------------------------
# 2. Stage settings files
#    Source: ~/.warp (Warp Stable) and ~/.warp-oss (custom build), merged.
#    ~/.warp-oss takes precedence if it exists.
# --------------------------------------------------------------------------
copy_if_exists() {
    local src="$1" dst="$2"
    [[ -e "$src" ]] || return 0
    mkdir -p "$(dirname "$dst")"
    if [[ -d "$src" ]]; then
        rsync -a --delete "$src/" "$dst/"
    else
        cp "$src" "$dst"
    fi
    echo "  staged: $dst"
}

# Use ~/.warp as the base, overlay with ~/.warp-oss if present
for cfg_dir in "$WARP_CONFIG" "$WARP_OSS_CONFIG"; do
    [[ -d "$cfg_dir" ]] || continue
    copy_if_exists "$cfg_dir/settings.toml"              "$REPO_DIR/config/settings.toml"
    copy_if_exists "$cfg_dir/themes"                     "$REPO_DIR/config/themes"
    copy_if_exists "$cfg_dir/workflows"                  "$REPO_DIR/config/workflows"
    copy_if_exists "$cfg_dir/launch_configurations"      "$REPO_DIR/config/launch_configurations"
    copy_if_exists "$cfg_dir/tab_configs"                "$REPO_DIR/config/tab_configs"
    copy_if_exists "$cfg_dir/skills"                     "$REPO_DIR/config/skills"
    copy_if_exists "$cfg_dir/.mcp.json"                  "$REPO_DIR/config/.mcp.json"
done

# --------------------------------------------------------------------------
# 3. Encrypt and stage SSH hosts (if DB and master password available)
# --------------------------------------------------------------------------
WARP_DB="$HOME/Library/Application Support/WarpOss/warp.sqlite"
STABLE_DB="$HOME/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"

# Prefer the custom-build DB; fall back to Stable
[[ -f "$WARP_DB" ]] || WARP_DB="$STABLE_DB"

if [[ -f "$WARP_DB" && -n "${MASTER_PASS:-}" ]]; then
    HAS_TABLE=$(/usr/bin/sqlite3 "$WARP_DB" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ssh_hosts';" 2>/dev/null || echo "0")

    if [[ "$HAS_TABLE" == "1" ]]; then
        SSH_JSON=$(/usr/bin/sqlite3 -json "$WARP_DB" \
            "SELECT g.id AS group_id, g.name AS group_name, g.label,
                    h.id, h.alias, h.host, h.port, h.user, h.pass, h.notes
             FROM ssh_groups g LEFT JOIN ssh_hosts h ON h.group_id = g.id
             ORDER BY g.name, h.alias;" 2>/dev/null || echo "[]")

        mkdir -p "$REPO_DIR/ssh"
        printf '%s' "$SSH_JSON" | openssl enc -aes-256-cbc -pbkdf2 \
            -pass "pass:$MASTER_PASS" \
            -out "$REPO_DIR/ssh/hosts.enc"
        echo "  staged: $REPO_DIR/ssh/hosts.enc (SSH hosts encrypted)"
    else
        echo "  skipped SSH hosts (ssh_hosts table not found in DB)"
    fi
else
    [[ -n "${MASTER_PASS:-}" ]] || echo "  skipped SSH hosts (no MASTER_PASS set)"
    [[ -f "$WARP_DB" ]]         || echo "  skipped SSH hosts (DB not found at $WARP_DB)"
fi

# --------------------------------------------------------------------------
# 4. Save non-sensitive config (repo URL)
# --------------------------------------------------------------------------
cat > "$SYNC_DIR/config" <<EOF
REPO_URL=$REPO_URL
EOF
chmod 600 "$SYNC_DIR/config"

# Save PAT to macOS Keychain
security delete-generic-password -s "warp-sync-github" 2>/dev/null || true
security add-generic-password -a "warp-sync" -s "warp-sync-github" -w "$GH_TOKEN" -T "" -U
echo "PAT saved to macOS Keychain (service: warp-sync-github)"

# --------------------------------------------------------------------------
# 5. Commit and push
# --------------------------------------------------------------------------
cd "$REPO_DIR"
git add -A
if git diff --cached --quiet; then
    echo "Nothing changed — repo is already up to date."
else
    git commit -m "bootstrap: initial Warp settings $(date '+%Y-%m-%d %H:%M')" --quiet
    git -c "credential.helper=" \
        -c "credential.helper=!f(){ echo username=x; echo \"password=${GH_TOKEN}\"; }; f" \
        push origin HEAD:main --quiet
    echo "Pushed to $REPO_URL"
fi

echo ""
echo "Done. Repo contents:"
find "$REPO_DIR" -not -path '*/.git/*' -type f | sort | sed "s|$REPO_DIR/||"
