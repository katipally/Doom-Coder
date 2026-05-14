#!/usr/bin/env bash
# Download all 6 agent icons from the lobehub CDN and place them into
# the xcassets imagesets. Run this script once, then commit the PNG files.
# Safe to re-run — existing files are overwritten with the latest version.

set -euo pipefail

CDN="https://cdn.jsdelivr.net/npm/@lobehub/icons-static-png@1.90.0/light"
XCASSETS="$(dirname "$0")/../DoomCoder/Assets.xcassets"

# "asset:filename" pairs — compatible with bash 3.2 (macOS default)
ICONS=(
  "agent-claude:claudecode-color.png"
  "agent-codex:codex-color.png"
  "agent-copilot-cli:githubcopilot.png"
  "agent-cursor:cursor.png"
  "agent-windsurf:windsurf.png"
  "agent-vscode:copilot-color.png"
)

for pair in "${ICONS[@]}"; do
  asset="${pair%%:*}"
  filename="${pair##*:}"
  dest="${XCASSETS}/${asset}.imageset/icon.png"
  echo "Downloading ${filename} → ${dest}"
  curl -fsSL "${CDN}/${filename}" -o "${dest}"
done

echo ""
echo "Done! Commit the new PNG files:"
echo "  git add DoomCoder/Assets.xcassets/agent-*.imageset/"
echo "  git commit -m 'feat: refresh bundled agent icons from lobehub CDN'"
