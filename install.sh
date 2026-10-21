#!/bin/sh
# Installs statusline.sh + subagent-statusline.sh into ~/.claude and wires statusLine + subagentStatusLine in settings.json;
# turns off the footer PR badge in ~/.claude.json, as line 1 of the status line shows the PR.
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
  # the tag, or how far the clone is past it (v0.0.10-2-gabc1234-dirty)
  version=$(git -C "$repo_dir" describe --tags --always --dirty 2> /dev/null || echo "local clone")
else
  # the release asset has its tag here, a raw install.sh the branch it came from
  version=$BRANCH
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
# refreshInterval re-renders an idle status line, so the session times keep moving; a value already set is kept
jq --arg main "bash $dir_ref/statusline.sh" --arg sub "bash $dir_ref/subagent-statusline.sh" \
  '.statusLine = {type: "command", command: $main, refreshInterval: (.statusLine.refreshInterval // 60)}
  | .subagentStatusLine = {type: "command", command: $sub}' \
  "$SETTINGS" > "$tmp/settings.json"
mv "$tmp/settings.json" "$SETTINGS"
echo "updated $SETTINGS (backup: $SETTINGS.bak)"

# global config: ~/.claude.json, or .claude.json inside CLAUDE_CONFIG_DIR when it is set;
# Claude Code owns the file, so a missing one is not created and only this key is changed
GLOBAL="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
GLOBAL="${GLOBAL:-$HOME/.claude.json}"
if [ ! -f "$GLOBAL" ]; then
  echo "warning: $GLOBAL not found - start Claude Code once and rerun, or set \"prStatusFooterEnabled\": false there by hand" >&2
elif ! jq -e '.prStatusFooterEnabled == false' "$GLOBAL" > /dev/null 2>&1; then
  cp "$GLOBAL" "$GLOBAL.bak"
  jq '.prStatusFooterEnabled = false' "$GLOBAL" > "$tmp/claude.json"
  mv "$tmp/claude.json" "$GLOBAL"
  echo "set prStatusFooterEnabled: false in $GLOBAL (backup: $GLOBAL.bak)"
else
  echo "prStatusFooterEnabled is already false in $GLOBAL"
fi
# green only on a terminal, so logs and CI get plain text
done_word=done
[ -t 1 ] && done_word=$(printf '\033[0;32mdone\033[0m')
echo "$done_word - claude-statusline $version installed, restart Claude Code to pick up the status line"
