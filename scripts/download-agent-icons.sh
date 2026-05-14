#!/usr/bin/env bash
# Download / extract all 6 agent icons and place them into xcassets imagesets.
# Run this script once, then commit the PNG files.
# Safe to re-run — existing files are overwritten with the latest version.
#
# Strategy per agent:
#   Claude Code, Codex, Copilot CLI — lobehub CDN (brand-specific variants)
#   Cursor, Windsurf, VS Code       — installed .app bundle; Cursor/Windsurf
#                                     fall back to CDN if app not installed.

set -euo pipefail

CDN="https://cdn.jsdelivr.net/npm/@lobehub/icons-static-png@latest/light"
XCASSETS="$(dirname "$0")/../DoomCoder/Assets.xcassets"
SIPS=/usr/bin/sips
CURL=/usr/bin/curl

# ── CDN icons (asset:cdn-filename) ──────────────────────────────────────────
CDN_ICONS=(
  "agent-claude:claudecode-color.png"
  "agent-codex:codex-color.png"
  "agent-copilot-cli:githubcopilot.png"
)

for pair in "${CDN_ICONS[@]}"; do
  asset="${pair%%:*}"
  filename="${pair##*:}"
  dest="${XCASSETS}/${asset}.imageset/icon.png"
  echo "CDN  ${filename} → ${dest}"
  "$CURL" -fsSL "${CDN}/${filename}" -o "${dest}"
done

# ── App-bundle icons (try installed app first, fall back to CDN) ─────────────
extract_or_cdn() {
  local asset="$1" icns="$2" cdn_fallback="$3"
  local dest="${XCASSETS}/${asset}.imageset/icon.png"
  if [ -f "$icns" ]; then
    echo "APP  ${icns} → ${dest}"
    "$SIPS" -s format png "$icns" --out "$dest" >/dev/null
  else
    echo "CDN  ${cdn_fallback} → ${dest} (app not installed)"
    "$CURL" -fsSL "${CDN}/${cdn_fallback}" -o "${dest}"
  fi
}

extract_or_cdn "agent-cursor"   "/Applications/Cursor.app/Contents/Resources/Cursor.icns"   "cursor.png"
extract_or_cdn "agent-windsurf" "/Applications/Windsurf.app/Contents/Resources/Windsurf.icns" "windsurf.png"

# VS Code — app bundle only (no lobehub CDN equivalent)
extract_app_only() {
  local asset="$1" icns="$2"
  local dest="${XCASSETS}/${asset}.imageset/icon.png"
  if [ -f "$icns" ]; then
    echo "APP  ${icns} → ${dest}"
    "$SIPS" -s format png "$icns" --out "$dest" >/dev/null
  else
    echo "SKIP ${asset} — VS Code not found at ${icns}"
  fi
}
extract_app_only "agent-vscode" "/Applications/Visual Studio Code.app/Contents/Resources/Code.icns"

echo ""
echo "Done! Commit the new PNG files:"
echo "  git add DoomCoder/Assets.xcassets/agent-*.imageset/"
echo "  git commit -m 'feat: refresh bundled agent icons'"

