#!/usr/bin/env bash
# Starts a release on GitHub Actions (.github/workflows/release.yml), which
# bumps VERSION, builds, signs and notarizes the DMG, commits
# "release: SarvTerminal X.Y.Z", pushes the commit and the vX.Y.Z tag, creates
# the GitHub release and bumps the Homebrew cask.
#
#   ./scripts/release-ci.sh patch|minor|major      (npm run release:patch ...)
#   ./scripts/release-ci.sh dry                    build/sign/notarize only
#
# The workflow releases origin/main, so this refuses to start while local main
# has commits that aren't pushed: they would silently miss the release.
set -euo pipefail

REPO="${REPO:-Sarv/SarvTerminal}"
WORKFLOW="release.yml"

usage() { echo "usage: $0 patch|minor|major|dry" >&2; exit 1; }

workflow_args() {
  case "$1" in
    patch | minor | major) echo "-f bump=$1" ;;
    dry) echo "-f dry_run=true" ;;
    *) usage ;;
  esac
}

ensure_main_pushed() {
  git fetch -q origin main
  local unpushed
  unpushed=$(git rev-list --count origin/main..main)
  if [[ "$unpushed" != "0" ]]; then
    echo "local main has $unpushed unpushed commit(s). Push them first (git push), or they won't be in the release." >&2
    exit 1
  fi
}

latest_run_url() {
  gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json url --jq '.[0].url'
}

main() {
  [[ $# -eq 1 ]] || usage
  local args
  args=$(workflow_args "$1")
  ensure_main_pushed
  # shellcheck disable=SC2086
  gh workflow run "$WORKFLOW" --repo "$REPO" --ref main $args
  echo "Started the $1 release. Waiting for the run to register..."
  sleep 5
  echo "Watch it: $(latest_run_url)"
}

main "$@"
