#!/bin/bash
# Snapshot tests: render every payload in cases/ and compare it with expected/<name>.txt.
# panel-* cases go to the agent panel script, the rest to the main status line.
# Usage: bash tests/run.sh [--update]   (--update rewrites the snapshots after an intended change)
cd "$(dirname "$0")" || exit 1
# fixed timezone for reset times; skills come from fixtures, not the real ~/.claude
export TZ=UTC CLAUDE_CONFIG_DIR=fixtures/config

update=""
[ "$1" = "--update" ] && update=1
fail=0
for f in cases/*.json; do
  name=$(basename "$f" .json)
  script=statusline.sh
  case "$name" in panel-*) script=subagent-statusline.sh ;; esac
  # the rest: bar measures today's date against the billing month
  actual=$(bash "../scripts/$script" < "$f" | sed -E 's/(rest:).*/\1 <date-dependent>/')
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
