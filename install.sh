#!/bin/sh
# Installs statusline.sh into ~/.claude and wires statusLine + subagentStatusLine in settings.json.
# Private repo: raw files need a token (GITHUB_TOKEN or `gh auth token`).
set -eu

REPO="ihororlovskyi/claude-statusline"
BRANCH="${CLAUDE_STATUSLINE_BRANCH:-main}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TARGET="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v jq > /dev/null 2>&1 || { echo "error: jq is required (brew install jq)" >&2; exit 1; }

mkdir -p "$CLAUDE_DIR"
tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.json"' EXIT

# local clone: `sh install.sh` copies the file next to it; piped from curl: download
src_dir=$(cd "$(dirname "$0")" 2> /dev/null && pwd || echo "")
if [ -n "$src_dir" ] && [ -f "$src_dir/statusline.sh" ] && [ -f "$src_dir/install.sh" ]; then
  cp "$src_dir/statusline.sh" "$tmp"
else
  token="${GITHUB_TOKEN:-}"
  [ -z "$token" ] && command -v gh > /dev/null 2>&1 && token=$(gh auth token 2> /dev/null || true)
  [ -z "$token" ] && { echo "error: no GitHub token; set GITHUB_TOKEN or run gh auth login" >&2; exit 1; }
  curl -fsSL -H "Authorization: token $token" \
    "https://raw.githubusercontent.com/$REPO/$BRANCH/statusline.sh" -o "$tmp"
fi

if [ -f "$TARGET" ] && ! cmp -s "$tmp" "$TARGET"; then
  cp "$TARGET" "$TARGET.bak"
  echo "backed up existing statusline.sh -> $TARGET.bak"
fi
cp "$tmp" "$TARGET"
chmod +x "$TARGET"
echo "installed $TARGET"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"
cmd="bash $TARGET"
[ "$CLAUDE_DIR" = "$HOME/.claude" ] && cmd="bash ~/.claude/statusline.sh"
jq --arg cmd "$cmd" '.statusLine = {type: "command", command: $cmd}
  | .subagentStatusLine = {type: "command", command: $cmd}' \
  "$SETTINGS" > "$tmp.json"
mv "$tmp.json" "$SETTINGS"
echo "updated $SETTINGS (backup: $SETTINGS.bak)"
echo "done - restart Claude Code to pick up the status line"
