#!/usr/bin/env bash
# Uploads the release credentials from this Mac to the GitHub Actions secrets
# that .github/workflows/release.yml reads. Run it in your own terminal:
# macOS asks for your login password before each Keychain read.
#
# Sources, the same ones scripts/release.sh uses locally:
#   SARV_P12_BASE64, SARV_P12_PASSWORD   the .p12 in ~/Downloads + Keychain
#   SPARKLE_ED_PRIVATE_KEY               the key Sparkle's generate_keys stored
#   RELEASE_TOKEN                        the ankursarv gh login (repo admin)
#   NOTARY_APPLE_ID, NOTARY_PASSWORD     notarytool's "sarv-notary" profile is
#       stored where nothing can read it back, so these are asked for on the
#       first run only and then saved to the login Keychain.
#
#   ./scripts/set-release-secrets.sh            set every secret
#   ./scripts/set-release-secrets.sh NAME ...   set only the named secrets
#
# Values are piped straight into `gh secret set` (encrypted locally before
# upload) and never written to disk or echoed.
set -euo pipefail

REPO="${REPO:-Sarv/SarvTerminal}"
# The secrets live on the "release" environment, which only main can use, so
# a workflow pushed to any other branch can't read them.
ENVIRONMENT="${ENVIRONMENT:-release}"
P12_PATH="${SARV_P12_PATH:-$HOME/Downloads/sarv-developerID-application.p12}"
P12_KC_SERVICE="sarv-terminal-p12"
SPARKLE_KC_SERVICE="https://sparkle-project.org"
SPARKLE_KC_ACCOUNT="ed25519"
NOTARY_ID_KC_SERVICE="sarv-notary-apple-id"
NOTARY_PW_KC_SERVICE="sarv-notary-password"
GH_ADMIN_ACCOUNT="ankursarv"
ALL_SECRETS=(SARV_P12_BASE64 SARV_P12_PASSWORD NOTARY_APPLE_ID NOTARY_PASSWORD SPARKLE_ED_PRIVATE_KEY RELEASE_TOKEN)

keychain_secret() { security find-generic-password -a "$2" -s "$1" -w; }

# Reads a value saved by an earlier run, else asks for it once and saves it.
keychain_or_ask() {
  local service="$1" question="$2" hidden="$3" value
  value=$(security find-generic-password -a "$USER" -s "$service" -w 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    if [[ "$hidden" == "hidden" ]]; then value=$(prompt_secret "$question"); else value=$(prompt_plain "$question"); fi
    [[ -n "$value" ]] && security add-generic-password -a "$USER" -s "$service" -w "$value" -U >/dev/null
  fi
  printf '%s' "$value"
}

prompt_secret() {
  local value
  read -rsp "$1: " value </dev/tty; echo >&2
  printf '%s' "$value"
}

prompt_plain() {
  local value
  read -rp "$1: " value </dev/tty
  printf '%s' "$value"
}

# Prints the value for one secret on stdout. Prompts only for what the
# Keychain doesn't hold.
secret_value() {
  case "$1" in
    SARV_P12_BASE64)        base64 -i "$P12_PATH" ;;
    SARV_P12_PASSWORD)      keychain_secret "$P12_KC_SERVICE" "$USER" ;;
    SPARKLE_ED_PRIVATE_KEY) keychain_secret "$SPARKLE_KC_SERVICE" "$SPARKLE_KC_ACCOUNT" ;;
    NOTARY_APPLE_ID)        keychain_or_ask "$NOTARY_ID_KC_SERVICE" "Apple ID used for notarization" plain ;;
    NOTARY_PASSWORD)        keychain_or_ask "$NOTARY_PW_KC_SERVICE" "App-specific password for that Apple ID" hidden ;;
    RELEASE_TOKEN)          gh auth token --user "$GH_ADMIN_ACCOUNT" ;;
    *) echo "unknown secret: $1" >&2; return 1 ;;
  esac
}

set_secret() {
  local name="$1" value
  value=$(secret_value "$name") || { echo "FAIL: $name (could not read the value)"; return 1; }
  [[ -n "$value" ]] || { echo "SKIP: $name (empty)"; return 0; }
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" --env "$ENVIRONMENT" >/dev/null
  echo "OK:   $name"
}

main() {
  command -v gh >/dev/null || { echo "gh is not installed"; exit 1; }
  [[ -f "$P12_PATH" ]] || { echo ".p12 not found at $P12_PATH (set SARV_P12_PATH)"; exit 1; }
  local names=("$@") failed=0
  [[ ${#names[@]} -gt 0 ]] || names=("${ALL_SECRETS[@]}")
  for name in "${names[@]}"; do
    set_secret "$name" || failed=1
  done
  echo
  gh secret list --repo "$REPO" --env "$ENVIRONMENT"
  return "$failed"
}

main "$@"
