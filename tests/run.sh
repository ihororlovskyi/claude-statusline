#!/bin/bash
# Snapshot tests: render every payload in cases/ and compare it with expected/<name>.txt.
# panel-* cases go to the agent panel script, the rest to the main status line.
# cache-* cases get a config dir with a fresh usage-cache.json and no skills; @repo@ in a payload
# is replaced with a scratch git repo on branch "feature" with an untracked file, and @tmp@ in a
# payload, transcript, script a transcript runs (*.py) or seed with the dir of the other scratch
# repos (session-repos cases).
# cases/<name>.state and cases/<name>.repos, if present, seed statusline-state/<session_id> and
# <session_id>.repos of the case before it runs; @line1@ in a seed is the byte size of the first
# line of the case transcript. gh is a stub that fails, so no case reaches the network.
# Usage: bash tests/run.sh [--update]   (--update rewrites the snapshots after an intended change)
cd "$(dirname "$0")" || exit 1
# fixed timezone for reset times; no global or system git config (status.showUntrackedFiles=no
# would hide the dirty mark of the scratch repo)
export TZ=UTC GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# the cache must be fresh and the repo has an absolute path, so both are built per run;
# physical, as git prints repo roots with symlinks resolved (/var -> /private/var on macOS)
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
git init -q -b feature "$tmp/repo" && touch "$tmp/repo/untracked" || exit 1
# repos the session-repos transcripts edit: <dir> <branch> <origin>
while read -r d b url; do
  git init -q -b "$b" "$tmp/$d" || exit 1
  [ "$url" = "-" ] || git -C "$tmp/$d" remote add origin "$url" || exit 1
done <<REPOS
app feature git@github.com:acme/app.git
sib dev git@github.com:acme/lib.git
other dev https://github.com/sentimony/skills.git
plain main -
extra main git@github-work:acme/extra.git
wip dev git@github.com:acme/wip.git
detached main git@github.com:acme/detached.git
REPOS
touch "$tmp/sib/untracked"
# a fixed date and author keep the short hash of the detached HEAD stable
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
  git -C "$tmp/detached" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init &&
  git -C "$tmp/detached" checkout -q --detach || exit 1
ln -s "$tmp/sib" "$tmp/link-sib" && mkdir "$tmp/nogit" || exit 1
# dir-* cases: a cwd in a subfolder of the scratch repo and in a worktree of another repo
mkdir -p "$tmp/repo/sub/deep" && git -C "$tmp/detached" worktree add -q -b wt "$tmp/wt-tree" &&
  mkdir "$tmp/wt-tree/sub" || exit 1
mkdir "$tmp/bin" && printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh" && chmod +x "$tmp/bin/gh" || exit 1
export PATH="$tmp/bin:$PATH"
# transcripts may name @tmp@ paths, so they are read from a substituted copy
cp -R fixtures/transcripts "$tmp/transcripts" || exit 1
find "$tmp/transcripts" \( -name '*.jsonl' -o -name '*.py' \) -exec sed -i '' "s#@tmp@#$tmp#g" {} + || exit 1
mkdir "$tmp/cache-config"
# a copy: cases with a session_id write statusline-state/ into the config dir
cp -R fixtures/config "$tmp/config" || exit 1
# PRs of the scratch repos, fresh so no case refreshes them
now=$(date +%s)
mkdir -p "$tmp/config/statusline-state" && cat > "$tmp/config/statusline-state/pr-cache" <<PRS || exit 1
acme/app feature $now 7 pending
acme/lib dev $now 5 approved
sentimony/skills dev $now 109 merged
acme/extra main $now 3 closed
acme/wip dev $now 12 draft
PRS
printf '{"timestamp":%s000,"data":{"spend":{"used":{"amount_minor":12345,"exponent":2},"limit":{"amount_minor":50000,"exponent":2},"percent":25}}}\n' \
  "$(date +%s)" > "$tmp/cache-config/usage-cache.json"

update=""
[ "$1" = "--update" ] && update=1
fail=0
for f in cases/*.json; do
  name=$(basename "$f" .json)
  script=statusline.sh
  # skills come from fixtures, not the real ~/.claude
  config="$tmp/config"
  case "$name" in
    panel-*) script=subagent-statusline.sh ;;
    cache-*) config="$tmp/cache-config" ;;
  esac
  # jq --arg keeps the substituted path valid JSON whatever characters $TMPDIR has
  payload=$(jq -c --arg repo "$tmp/repo" --arg tmp "$tmp" \
    'walk(if . == "@repo@" then $repo elif type == "string" then gsub("@tmp@"; $tmp) else . end)' "$f") || exit 1
  for ext in state repos; do
    [ -f "cases/$name.$ext" ] || continue
    sid=$(printf '%s' "$payload" | jq -r .session_id)
    line1=$(head -n 1 "$(printf '%s' "$payload" | jq -r .transcript_path)" 2>/dev/null | wc -c | tr -d ' ')
    target="$config/statusline-state/$sid"
    [ "$ext" = repos ] && target="$target.repos"
    mkdir -p "$config/statusline-state" &&
      sed -e "s#@tmp@#$tmp#g" -e "s#@line1@#$line1#g" "cases/$name.$ext" > "$target" || exit 1
  done
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
