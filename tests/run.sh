#!/bin/bash
# Snapshot tests: render every payload in cases/ and compare it with expected/<name>.txt.
# panel-* cases go to the agent panel script, the rest to the main status line.
# cache-* cases get a config dir with a fresh usage-cache.json and no skills; @repo@ in a payload
# is replaced with a scratch git repo on branch "feature" with an untracked file.
# Usage: bash tests/run.sh [--update]   (--update rewrites the snapshots after an intended change)
cd "$(dirname "$0")" || exit 1
# fixed timezone for reset times; no global or system git config (status.showUntrackedFiles=no
# would hide the dirty mark of the scratch repo)
export TZ=UTC GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# the cache must be fresh and the repo has an absolute path, so both are built per run
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
git init -q -b feature "$tmp/repo" && touch "$tmp/repo/untracked" || exit 1
mkdir "$tmp/cache-config"
printf '{"timestamp":%s000,"data":{"spend":{"used":{"amount_minor":12345,"exponent":2},"limit":{"amount_minor":50000,"exponent":2},"percent":25}}}\n' \
  "$(date +%s)" > "$tmp/cache-config/usage-cache.json"

update=""
[ "$1" = "--update" ] && update=1
fail=0
for f in cases/*.json; do
  name=$(basename "$f" .json)
  script=statusline.sh
  # skills come from fixtures, not the real ~/.claude
  config=fixtures/config
  case "$name" in
    panel-*) script=subagent-statusline.sh ;;
    cache-*) config="$tmp/cache-config" ;;
  esac
  # jq --arg keeps the substituted path valid JSON whatever characters $TMPDIR has
  payload=$(jq -c --arg repo "$tmp/repo" 'walk(if . == "@repo@" then $repo else . end)' "$f") || exit 1
  # the rest: bar measures today's date against the billing month
  actual=$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$config" bash "../scripts/$script" |
    sed -E 's/(rest:).*/\1 <date-dependent>/')
  expected="expected/$name.txt"
  if [ -n "$update" ]; then
    printf '%s\n' "$actual" > "$expected"
    echo "updated $name"
  elif out=$(printf '%s\n' "$actual" | diff -u "$expected" - 2>&1); then
    echo "ok      $name"
  else
    echo "FAIL    $name"
    printf '%s\n' "$out" | cat -v
    fail=1
  fi
done
exit $fail
