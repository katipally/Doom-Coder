#!/usr/bin/env bash
# Sync agent icons from assets/Agent-logos/ into both xcassets catalogs.
# Drop a replacement file at assets/Agent-logos/<name>.{webp,svg,png} and re-run.
#
# Source filename -> imageset name mapping is fixed below.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="assets/Agent-logos"
MAC="DoomCoder/Assets.xcassets"
IOS="DoomCoderCompanion/DoomCoderCompanion/Resources/Assets.xcassets"

# source_basename:imageset_name
mappings=(
  "claude_code:agent-claude"
  "codex:agent-codex"
  "cursor:agent-cursor"
  "github_copilot:agent-copilot-cli"
  "visual_studio_code:agent-vscode"
  "windsurf:agent-windsurf"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for entry in "${mappings[@]}"; do
  src_base="${entry%%:*}"
  dst="${entry##*:}"
  out="$TMP/${dst}.png"

  if [[ -f "$SRC/${src_base}.png" ]]; then
    sips -s format png "$SRC/${src_base}.png" --out "$out" -Z 512 >/dev/null
  elif [[ -f "$SRC/${src_base}.webp" ]]; then
    sips -s format png "$SRC/${src_base}.webp" --out "$out" -Z 512 >/dev/null
  elif [[ -f "$SRC/${src_base}.svg" ]]; then
    if ! command -v rsvg-convert >/dev/null; then
      echo "rsvg-convert required for $src_base.svg (brew install librsvg)" >&2
      exit 1
    fi
    rsvg-convert -w 512 -h 512 "$SRC/${src_base}.svg" -o "$out"
  else
    echo "missing source for $src_base in $SRC" >&2
    exit 1
  fi

  cp "$out" "$MAC/${dst}.imageset/icon.png"
  cp "$out" "$IOS/${dst}.imageset/icon.png"
  echo "synced ${dst}"
done

echo "done. ${#mappings[@]} icons synced to Mac + iOS catalogs."
