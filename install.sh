#!/bin/sh
# Installs statusline.sh + subagent-statusline.sh into ~/.claude and wires statusLine + subagentStatusLine in settings.json.
set -eu

REPO="ihororlovskyi/claude-statusline"
BRANCH="${CLAUDE_STATUSLINE_BRANCH:-main}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
FILES="statusline.sh subagent-statusline.sh"

command -v jq > /dev/null 2>&1 || { echo "error: jq is required (brew install jq)" >&2; exit 1; }

mkdir -p "$CLAUDE_DIR"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# local clone: `sh install.sh` copies files from scripts/; piped from curl: download
repo_dir=$(cd "$(dirname "$0")" 2> /dev/null && pwd || echo "")
if [ -n "$repo_dir" ] && [ -f "$repo_dir/install.sh" ] && [ -f "$repo_dir/scripts/statusline.sh" ]; then
  for f in $FILES; do cp "$repo_dir/scripts/$f" "$tmp/$f"; done
else
  for f in $FILES; do
    curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/scripts/$f" -o "$tmp/$f"
  done
fi

for f in $FILES; do
  target="$CLAUDE_DIR/$f"
  if [ -f "$target" ] && ! cmp -s "$tmp/$f" "$target"; then
    cp "$target" "$target.bak"
    echo "backed up existing $f -> $target.bak"
  fi
  cp "$tmp/$f" "$target"
  chmod +x "$target"
  echo "installed $target"
done

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"
# custom dirs are single-quoted so spaces and shell metacharacters survive in the command
dir_ref="'$(printf '%s' "$CLAUDE_DIR" | sed "s/'/'\\\\''/g")'"
[ "$CLAUDE_DIR" = "$HOME/.claude" ] && dir_ref="~/.claude"
jq --arg main "bash $dir_ref/statusline.sh" --arg sub "bash $dir_ref/subagent-statusline.sh" \
  '.statusLine = {type: "command", command: $main}
  | .subagentStatusLine = {type: "command", command: $sub}' \
  "$SETTINGS" > "$tmp/settings.json"
mv "$tmp/settings.json" "$SETTINGS"
echo "updated $SETTINGS (backup: $SETTINGS.bak)"
echo "done - restart Claude Code to pick up the status line"
