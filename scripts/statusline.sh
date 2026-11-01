#!/bin/sh
input=$(cat)

# parse all fields from stdin in one jq call via eval+@sh
# every field is type-checked before @sh: an array would become several shell words and run as a command;
# numbers reach awk and $(( )); timestamps are floored and bounded because $(( )) takes only plain integers
eval "$(echo "$input" | jq -r '
  def str: if type == "string" then . else "" end;
  def num: if type == "number" then tostring else "" end;
  def int: if type == "number" and . >= 0 and . < 1e12 then floor | tostring else "" end;
  def pct: if type == "number" and . > -1e9 and . < 1e9 then round | tostring else "" end;
  def pr: .pr | if type == "object" then . else {} end;
  "cwd="          + (.cwd | str | @sh),
  "session_id="   + (.session_id | str | @sh),
  "transcript="   + (.transcript_path | str | @sh),
  "project_dir="  + (.workspace.project_dir | str | @sh),
  "model="        + (.model.display_name | str | @sh),
  "used="         + (.context_window.used_percentage | if pct != "" then tostring else "" end | @sh),
  "used_int="     + (.context_window.used_percentage | pct | @sh),
  "ctx_size="     + (.context_window.context_window_size | num | @sh),
  "ctx_tokens="   + (.context_window.current_usage | if type == "object" then [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens] | map(select(type == "number")) | if length > 0 then add | tostring else "" end else "" end | @sh),
  "effort_val="   + (.effort.level | str | @sh),
  "thinking_in="  + (.thinking.enabled | if type == "boolean" then tostring else "" end | @sh),
  "cost_usd="     + (.cost.total_cost_usd | num | @sh),
  "session_pct="  + (.rate_limits.five_hour.used_percentage | pct | @sh),
  "session_reset="+ (.rate_limits.five_hour.resets_at | int | @sh),
  "weekly_pct="   + (.rate_limits.seven_day.used_percentage | pct | @sh),
  "weekly_reset=" + (.rate_limits.seven_day.resets_at | int | @sh),
  "pr_number="    + (pr.number | int | @sh),
  "pr_state="     + (pr.review_state | str | select(test("^[a-z_]*$")) // "" | @sh),
  "pr_kind="      + (pr.kind | str | select(. == "mr") // "" | @sh)
')"

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
gray="\033[0;90m"
cyan="\033[0;36m"
mag="\033[0;35m"

# git branch + dirty state
# symbolic-ref prints nothing outside a repo or on a detached HEAD
# " git:(<branch>) ✗" for the repo at $1
git_label() {
  dirty=""
  [ -n "$(git -C "$1" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="\033[0;33m ✗"
  printf " \033[1;34mgit:(\033[0;31m%s\033[1;34m)$dirty\033[0m" "$2"
}
git_info=""
branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
[ -n "$branch" ] && git_info=$(git_label "$cwd" "$branch")

# labelled progress bar; $3 is the color of the percentage (default white), $4 replaces its text
render_bar() {
  label="$1"
  pct_int="$2"
  filled=$(( pct_int * 10 / 100 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt 10 ] && filled=10
  empty=$(( 10 - filled ))
  bar=""
  i=0; while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  i=0; while [ $i -lt $empty ];  do bar="${bar}░"; i=$(( i + 1 )); done
  col=32
  [ "$pct_int" -ge 50 ] && col=33
  [ "$pct_int" -ge 80 ] && col=31
  printf "$gray%s:\033[0m\033[0;%sm%s\033[0m \033[0;%sm%s%%\033[0m" "$label" "$col" "$bar" "${3:-37}" "${4:-$pct_int}"
}

fmt_eta_hm() {
  total="$1"; [ "$total" -lt 0 ] && total=0
  printf "%dh %dm" "$(( total / 3600 ))" "$(( (total % 3600) / 60 ))"
}
fmt_eta_dhm() {
  total="$1"; [ "$total" -lt 0 ] && total=0
  printf "%dd %dh %dm" "$(( total / 86400 ))" "$(( (total % 86400) / 3600 ))" "$(( (total % 3600) / 60 ))"
}
# reset moment in local time, e.g. "Mon 19:00"; LC_ALL=C keeps English day names
fmt_reset_at() {
  LC_ALL=C date -r "$1" "+%a %H:%M" 2>/dev/null || LC_ALL=C date -d "@$1" "+%a %H:%M" 2>/dev/null
}

p6="      "
# awk durations: "1h 5m", "4m 2s", "9s"
awk_fmt='
  function fmt(x) {
    x = int(x)
    if (x >= 3600) return sprintf("%dh %dm", x / 3600, (x % 3600) / 60)
    if (x >= 60) return sprintf("%dm %ds", x / 60, x % 60)
    return sprintf("%ds", x)
  }'

# line 1: model + effort level; models without effort show nothing after the name
model_str=""
[ -n "$model" ] && model_str=$(printf "  $mag%s\033[0m" "$model")
[ -n "$effort_val" ] && model_str=$(printf "%s $mag%s\033[0m" "$model_str" "$effort_val")
# session cost: on the sess line, else on the used line, else on the cntx line, else (no context
# data) on line 1
cost_str=$(LC_ALL=C awk -v c="${cost_usd:-0}" -v col="$cyan" 'BEGIN { if (c + 0 > 0) printf "  %s$%.2f\033[0m", col, c }')
if [ -z "$used" ] && [ -n "$cost_usd" ]; then
  model_str="$model_str$cost_str"
fi
nl='
'
state_dir="$claude_dir/statusline-state"
session_ok=""
case "$session_id" in ''|*[!A-Za-z0-9_-]*) ;; *) session_ok=1 ;; esac

# rate limits belong to the account, not the session: saved whenever the payload has them as
# "<sess %> <sess reset> <week %> <week reset>" ("-" when absent), so a payload without them (the
# first one after /restart, until an API response) still draws sess/week, not the Enterprise lines
limits_cache="$state_dir/rate-limits"
if [ -n "$session_pct$weekly_pct" ]; then
  limits_line="${session_pct:--} ${session_reset:--} ${weekly_pct:--} ${weekly_reset:--}"
  limits_old=""
  [ -f "$limits_cache" ] && limits_old=$(cat "$limits_cache" 2>/dev/null)
  # write only on change; a failed write never breaks the render
  if [ "$limits_line" != "$limits_old" ]; then
    { mkdir -p "$state_dir" && printf '%s\n' "$limits_line" > "$limits_cache.$$" &&
      mv -f "$limits_cache.$$" "$limits_cache"; } 2>/dev/null || rm -f "$limits_cache.$$" 2>/dev/null
  fi
fi

# owner/repo of the origin remote on GitHub (an ssh alias like github-work counts), else nothing
gh_slug() {
  git -C "$1" --no-optional-locks remote get-url origin 2>/dev/null | sed -nE \
    's#^(https://|ssh://)?([^@/]+@)?github(\.com|-[A-Za-z0-9_-]+)[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$#\4/\5#p' |
    sed 's/\.git$//'
}

# " · PR #N" for a PR number and state; state words follow pr.review_state, plus merged/closed.
# Colors follow the footer badge: gray "PR", the number yellow while waiting for review
pr_label() {
  case "$1" in ''|*[!0-9]*) return ;; esac
  col=33 suffix=""
  case "$2" in
    approved) col=32 ;;
    changes_requested) col=31 ;;
    draft) col=90 suffix=" draft" ;;
    merged) col=35 suffix=" merged" ;;
    closed) col=90 suffix=" closed" ;;
  esac
  printf " ${gray}· %s\033[0m \033[0;%sm#%s%s\033[0m" "${3:-PR}" "$col" "$1" "$suffix"
}

# PR cache, one "<owner/repo> <branch> <checked> <number|-> <state|->" line per branch; the
# render never waits for gh: a stale entry is stamped as checked and refreshed in the background
pr_cache="$state_dir/pr-cache"
pr_store() {
  { mkdir -p "$state_dir" && t=$(mktemp "$pr_cache.XXXXXX") &&
    { [ -f "$pr_cache" ] && LC_ALL=C awk -v s="$1" -v b="$2" -v now="$3" \
        '!($1 == s && $2 == b) && now - $3 < 604800' "$pr_cache"
      printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5"; } > "$t" &&
    mv -f "$t" "$pr_cache"; } 2>/dev/null || rm -f "$t" 2>/dev/null
}
# runs in the background: the first account that can read the repo answers (GH_ACC from the
# repo's .env/.env, then the active gh account, then the others); a token in the environment wins
pr_fetch() {
  command -v gh > /dev/null 2>&1 || return
  logins="-"
  if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    logins=$({ sed -n 's/^GH_ACC=\([A-Za-z0-9-]*\)$/\1/p' "$3/.env/.env" 2>/dev/null | head -n 1
      gh auth status --hostname github.com --json hosts \
        --jq '.hosts["github.com"] | sort_by(.active | not) | .[].login' 2>/dev/null; } |
      grep -E '^[A-Za-z0-9-]+$' | awk '!seen[$0]++')
    [ -n "$logins" ] || logins="-"
  fi
  for login in $logins; do
    token=""
    [ "$login" = "-" ] || token=$(gh auth token --hostname github.com --user "$login" 2>/dev/null) || continue
    out=$(GH_TOKEN=${token:-${GH_TOKEN:-}} gh pr list --repo "$1" --head "$2" --state all --limit 1 \
      --json number,state,isDraft,reviewDecision 2>/dev/null) || continue
    res=$(printf '%s' "$out" | jq -r '.[0] // empty |
      [(.number | tostring),
       (if .state == "MERGED" then "merged" elif .state == "CLOSED" then "closed"
        elif .isDraft then "draft" elif .reviewDecision == "APPROVED" then "approved"
        elif .reviewDecision == "CHANGES_REQUESTED" then "changes_requested" else "pending" end)]
      | join(" ")' 2>/dev/null) || continue
    [ -n "$res" ] || res="- -"
    pr_store "$1" "$2" "$(date +%s)" $res
    return
  done
}
# " · PR #N" of <owner/repo> <branch> <root> from the cache
pr_cached() {
  [ -n "$1" ] && [ -n "$2" ] || return
  line=""
  [ -f "$pr_cache" ] && line=$(LC_ALL=C awk -v s="$1" -v b="$2" '$1 == s && $2 == b { print; exit }' "$pr_cache")
  set -- "$1" "$2" "$3" $line
  checked=${6:-0}
  case "$checked" in *[!0-9]*) checked=0 ;; esac
  now_pr=$(date +%s)
  if [ $(( now_pr - checked )) -gt 300 ]; then
    pr_store "$1" "$2" "$now_pr" "${7:--}" "${8:--}"
    ( pr_fetch "$1" "$2" "$3" ) < /dev/null > /dev/null 2>&1 &
  fi
  pr_label "${7:-}" "${8:-}"
}

cwd_root=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
# the repo root, so a cd into a subdir keeps the repo name; a worktree shows its own dir
dir=$(basename "${cwd_root:-$cwd}")
cwd_slug=""
[ -n "$cwd_root" ] && cwd_slug=$(gh_slug "$cwd_root")
# PR of the cwd branch: the payload mirrors the footer badge; without it (no gh check, or the
# PR merged or closed) the cache
if [ -n "$pr_number" ]; then
  pr_str=$(pr_label "$pr_number" "$pr_state" "$([ "$pr_kind" = mr ] && echo MR)")
elif [ -n "$branch" ]; then
  pr_str=$(pr_cached "$cwd_slug" "$branch" "$cwd_root")
else
  pr_str=""
fi

# repos the session edited: Edit/Write/NotebookEdit paths in the session transcript and its
# agent transcripts, read incrementally. State "<session_id>.repos": "v <rules>", then
# "o <offset> <file>" per transcript, up to the end of its last complete line, then "r <root>" per
# repo in first-edit order. A state of other rules (older versions have no "v" line) is dropped, so
# the transcripts are read again and roots the old rules got wrong go away
repos_rules=3
roots=""
# literal absolute and ~/ paths in a text, after a space, a quote or =; a path with $, a backtick,
# a glob or a backslash is built at run time and skipped
lits_jq='def lits: [scan("(?:^|[\\s\"\\x27=])((?:~/|/)[^\\s\"\\x27;&|()<>{}\\[\\],]*)")] | .[] | .[0] |
  sub("[.:]+$"; "") | select(length > 2 and (test("[$`*?\\\\]") | not)) |
  if startswith("~/") then env.HOME + .[1:] else . end;'
if [ -n "$session_ok" ] && [ -f "$transcript" ]; then
  repos_state="$state_dir/$session_id.repos"
  old_state=""
  [ -f "$repos_state" ] && old_state=$(cat "$repos_state" 2>/dev/null)
  [ "${old_state%%"$nl"*}" = "v $repos_rules" ] || old_state=""
  roots=$(printf '%s\n' "$old_state" | sed -n 's/^r //p')
  offsets=""
  for f in "$transcript" "${transcript%.jsonl}"/subagents/agent-*.jsonl; do
    [ -f "$f" ] || continue
    size=$(wc -c < "$f" | tr -d ' ')
    off=$(printf '%s\n' "$old_state" | F="$f" LC_ALL=C awk '
      /^o / { p = substr($0, length($1) + length($2) + 3); if (p == ENVIRON["F"]) { print $2; exit } }')
    case "$off" in ''|*[!0-9]*) off=0 ;; esac
    # a smaller file is a new transcript
    [ "$size" -lt "$off" ] && off=0
    if [ "$size" -gt "$off" ]; then
      # at most 16 MB per file and render: a resumed 120 MB transcript took 5 s in one pass
      chunk=$(( size - off ))
      [ "$chunk" -gt 16777216 ] && chunk=16777216
      # records count bytes (LC_ALL=C); a last record without its newline is half-written (or
      # cut by the chunk) and stays for the next render
      out=$(tail -c +$(( off + 1 )) "$f" 2>/dev/null | head -c "$chunk" | LC_ALL=C awk -v w="$chunk" '
        function emit(r) { if (r ~ /"name":"(Edit|Write|NotebookEdit|Bash)"/) print "L" r }
        NR > 1 { emit(prev) }
        { prev = $0; n += length($0) + 1 }
        END {
          if (NR > 0) { if (n == w) emit(prev); else n -= length(prev) + 1 }
          print "N" n + 0
        }')
      read_n=$(printf '%s\n' "$out" | sed -n 's/^N\([0-9][0-9]*\)$/\1/p' | tail -n 1)
      read_n=${read_n:-0}
      # a single line longer than the chunk: skip it rather than stall
      [ "$read_n" -eq 0 ] && [ "$chunk" -eq 16777216 ] && read_n=$chunk
      off=$(( off + read_n ))
      # dirs of edited files, and from Bash commands the dirs of "git -C <dir> <writing subcommand>".
      # A command is split into parts at newlines, ;, &&, || and |, a heredoc body staying with the
      # part that opens it. A part that writes by its command (sed -i, mv, python, a writing git
      # subcommand, ...) adds every literal path in its text (heredoc and -c code included), or, when
      # it runs a script file (python3 <file>, node <file>), "S<file>" instead, whose literal paths
      # are read below: neither the script path (a skill script reached through a symlink names
      # the clone the symlink points to) nor the arguments, which it may only read, are edits.
      # A part that writes only by a redirect adds the redirect target.
      # A command with a writing part also adds "cd <dir>". Relative dirs resolve against the cwd
      # of the entry, ~ against $HOME, and $vars are skipped
      dirs=$(printf '%s\n' "$out" | sed -n 's/^L//p' | jq -rR "$lits_jq"'
        def gitw: "commit|add|push|merge|rebase|reset|checkout|switch|tag|mv|rm|apply|am|cherry-pick|stash|restore|pull";
        def unq: sub("^[\"\\x27]"; "") | sub("[\"\\x27]$"; "");
        def abs($cwd): if startswith("~/") then env.HOME + .[1:] elif . == "~" then env.HOME
          elif startswith("/") then . elif $cwd != "" then $cwd + "/" + . else empty end;
        def word: "(\"[^\"]*\"|\\x27[^\\x27]*\\x27|[^\\s;&|)<>]+)";
        def parts: reduce (split("\n")[]) as $l ({o: [], t: null, i: null};
          if .t != null then .t as $t | .o[.i] += "\n" + $l |
            if $l | test("^\\s*" + $t + "\\s*$") then .t = null else . end
          else [$l | splits("\\s*(?:&&|\\|\\||[;|])\\s*") | sub("^[\\s({]+"; "")] as $p |
            ([$p[] | test("(?<!<)<<(?!<)")] | index(true)) as $h |
            if $h == null then .o += $p
            else ((.o | length) + $h) as $i | .o += $p | .i = $i |
              .t = ($p[$h] | capture("(?<!<)<<(?!<)-?\\s*[\"\\x27]?(?<g>[A-Za-z_][A-Za-z0-9_]*)") | .g)
            end
          end) | .o;
        fromjson? | select(type == "object" and .type == "assistant") | (.cwd | strings // "") as $cwd |
        .message.content[]? | select(type == "object" and .type == "tool_use") |
        if .name == "Edit" or .name == "Write" or .name == "NotebookEdit" then
          (.input.file_path // .input.notebook_path) | strings |
          select(startswith("/") and (contains("\n") | not)) | sub("/[^/]*$"; "")
        elif .name == "Bash" then
          .input.command | strings | . as $c |
          # per part: its command writes (judged by its first line, not the heredoc body), and
          # its redirect targets, also after a script it runs; -> and => are no redirects
          [$c | parts | .[] | . as $t | split("\n")[0] as $f | {t: $t,
            s: [$f | scan("^(?:python3?|node|bash|sh|zsh)\\s+(?:-(?![ce]\\s)[A-Za-z]+\\s+)*(\"[^\"]*\"|\\x27[^\\x27]*\\x27|[^-\\s;&|)<>][^\\s;&|)<>]*)") | .[0] |
              unq | select(test("[$`*?\\n]") | not) | abs($cwd)],
            c: ($f | test("\\bgit\\s+(-C\\s+\\S+\\s+)?(" + gitw + ")\\b") or
              test("sed\\s+-[a-zA-Z]*i|perl\\s+-[a-zA-Z]*i|\\b(mv|cp|rm|tee|touch|mkdir|patch|python3?|node|npx|bun)\\s|\\bnpm\\s+(?!(view|v|info|show|ls|list|outdated|search|whoami|ping|help|prefix|root|explain|why)\\b)")),
            r: [$f | scan("(?<![0-9&>=-])>>?\\s*(?!/dev/null|&)" + word) | .[0]]}] as $p |
          ($p | any(.c or (.r | length > 0))) as $w |
          ((($c | [scan("\\bgit\\s+-C\\s+" + word + "\\s+([a-z-]+)")] | .[] |
              select(.[1] | test("^(" + gitw + ")$")) | .[0]),
           (if $w then $c | [scan("(?:^|[;&|(\\n\"\\x27]\\s*)cd\\s+" + word)] | .[] | .[0]
            else empty end),
           ($p[] | .r[])) |
          unq | select(test("[$`*?\\n]") | not) | abs($cwd)),
          ($p[] | select(.c and (.s | length) == 0) | .t | lits),
          ($p[] | select(.c) | .s[] | "S" + .)
        else empty end' 2>/dev/null | awk '!seen[$0]++')
      # a script read once, on the render that reaches its entry; at most 256 KB, gone is no error
      # (S*) with the paren: bash 3.2 (/bin/sh on macOS) ends $( at the ) of a bare case pattern
      dirs=$(printf '%s\n' "$dirs" | while IFS= read -r d; do
        case "$d" in
          (S*) [ -f "${d#S}" ] && head -c 262144 "${d#S}" 2>/dev/null | jq -rRs "$lits_jq lits" 2>/dev/null ;;
          (*) printf '%s\n' "$d" ;;
        esac
      done | awk '!seen[$0]++')
      while IFS= read -r d; do
        [ -n "$d" ] || d=/
        # the file may be gone or not created yet: the nearest existing parent
        while [ ! -d "$d" ] && [ "$d" != "/" ]; do d=$(dirname "$d"); done
        # a symlinked path resolves to the physical clone, so both spellings give one root
        root=$(git -C "$d" --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || continue
        case "$nl$roots$nl" in *"$nl$root$nl"*) ;; *) roots="${roots:+$roots$nl}$root" ;; esac
      done <<EOF
$dirs
EOF
    fi
    offsets="$offsets${nl}o $off $f"
  done
  new_state=$(printf 'v %s\n%s\n' "$repos_rules" "${offsets#"$nl"}"; [ -n "$roots" ] && printf '%s\n' "$roots" | sed 's/^/r /')
  if [ "$new_state" != "$old_state" ]; then
    { mkdir -p "$state_dir" && printf '%s\n' "$new_state" > "$repos_state.$$" &&
      mv -f "$repos_state.$$" "$repos_state"; } 2>/dev/null || rm -f "$repos_state.$$" 2>/dev/null
  fi
fi

# the PR follows the branch it belongs to; a gray dot then separates it from the model
[ -n "$pr_str" ] && [ -n "$model_str" ] && model_str=$(printf " ${gray}·\033[0m %s" "${model_str#  }")
printf "\033[1;32m➜\033[0m  $cyan%s\033[0m%s%s%s\n" "$dir" "$git_info" "$pr_str" "$model_str"

# one line per other repo the session edited
while IFS= read -r root; do
  [ -n "$root" ] && [ "$root" != "$cwd_root" ] && [ -d "$root" ] || continue
  br=$(git -C "$root" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  label=$br
  [ -n "$label" ] || label=$(git -C "$root" --no-optional-locks rev-parse --short HEAD 2>/dev/null) || continue
  slug=$(gh_slug "$root")
  name=${slug:-$(basename "$root")}
  [ -n "$slug" ] && [ "${slug%%/*}" = "${cwd_slug%%/*}" ] && name=${slug#*/}
  repo_pr=""
  [ -n "$br" ] && repo_pr=$(pr_cached "$slug" "$br" "$root")
  printf "${gray}↳\033[0m  $cyan%s\033[0m%s%s\n" "$name" "$(git_label "$root" "$label")" "$repo_pr"
done <<EOF
$roots
EOF

# line 2: thinking + skills and memory estimates + prompts
# memory: the files Claude Code loads into every turn (the "Memory files" of /context), estimated
# like the skills. Walking from the project dir up to /: CLAUDE.md, .claude/CLAUDE.md and
# CLAUDE.local.md (AGENTS.md and .claude/AGENTS.md instead when none of them exists and the
# built-in agents-md plugin is on); the user and managed CLAUDE.md; project and user .claude/rules
# without paths: frontmatter; @path imports of all of them, up to four hops; MEMORY.md of auto
# memory (the first 200 lines, at most 25,000 bytes). Checked against /context of 2.1.316 in
# November 2026. Parsing every file each render would cost more than the rest of line 2, so the
# total is kept in statusline-state/mem-<project dir> with "<mtime> <size> <path>" of every file
# it looked at (missing ones too, so a new file shows up) and is recounted when one stat changes
# sets st; BSD stat first: GNU stat takes -f for file system info, which starts with no mtime;
# -L: a symlinked CLAUDE.md (dotfiles) changes with its target
mem_stat() {
  st=""
  [ $# -gt 0 ] || return 0
  st=$(stat -L -f '%m %z %N' "$@" 2>/dev/null)
  case "$st" in [0-9]*) ;; *) st=$(stat -L -c '%Y %s %n' "$@" 2>/dev/null) ;; esac
}
# the letters and digits spelled out: a range like A-Z also matches accented letters in a UTF-8
# locale of bash 3.2; Claude Code replaces /[^a-zA-Z0-9]/g, so a character outside the BMP (an
# emoji) is one "-" here and two there
alnum=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789
# prints "T <bytes>" and "C <path>" for every path it looked at
mem_count() {
  d=$1 roots="" set_auto=true set_agents=true set_dir=""
  # settings: user, project, local; a later one wins
  for f in "$claude_dir/settings.json" "$d/.claude/settings.json" "$d/.claude/settings.local.json"; do
    printf 'C %s\n' "$f"
    [ -f "$f" ] || continue
    v=$(jq -r 'if type == "object" then [
        (.autoMemoryEnabled | if type == "boolean" then tostring else "" end),
        (.enabledPlugins | if type == "object" then .["agents-md@builtin"] else null end | if type == "boolean" then tostring else "" end),
        (.autoMemoryDirectory | if type == "string" then . else "" end)
      ] | join("\u001f") else empty end' "$f" 2>/dev/null) || continue
    IFS=$(printf '\037') read -r a g m <<EOF
$v
EOF
    [ -n "$a" ] && set_auto=$a
    [ -n "$g" ] && set_agents=$g
    [ -n "$m" ] && set_dir=$m
  done
  case "$CLAUDE_CODE_DISABLE_AUTO_MEMORY" in 1|true) set_auto=false ;; esac
  # every candidate is stat-ed, but only a regular file is read: awk hangs on a FIFO and BSD awk
  # aborts on a directory
  root() { printf 'C %s\n' "$2"; [ -f "$2" ] && roots="$roots${nl}$1 $2"; }
  root u "$claude_dir/CLAUDE.md"
  root u "/Library/Application Support/ClaudeCode/CLAUDE.md"
  root u /etc/claude-code/CLAUDE.md
  p=$d
  while :; do
    b=${p%/}
    for f in CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md; do root c "$b/$f"; done
    for f in AGENTS.md .claude/AGENTS.md; do root a "$b/$f"; done
    [ -z "$b" ] && break
    p=${b%/*}
    [ -z "$p" ] && p=/
  done
  # rules: every .md below the dirs; the dirs themselves are stat-ed, so an added file shows up.
  # -L: rules may be symlinks, and so may the rules dir (find reports a loop and does not follow it)
  for r in "$d/.claude/rules" "$claude_dir/rules"; do
    printf 'C %s\n' "$r"
    [ -d "$r" ] || continue
    while IFS= read -r f; do
      if [ -d "$f" ]; then printf 'C %s\n' "$f"; else root r "$f"; fi
    done <<EOF
$(find -L "$r" \( -type d -o -type f -name '*.md' \) 2>/dev/null)
EOF
  done
  if [ "$set_auto" = true ]; then
    if [ -n "$set_dir" ]; then
      case "$set_dir" in "~/"*) set_dir="$HOME/${set_dir#"~/"}" ;; esac
      mem_file="${set_dir%/}/MEMORY.md"
    else
      # one dir per git repository (worktrees share the main one), else the project dir; the name
      # is the path with every character other than a letter or a digit turned into "-"
      slug=$CLAUDE_CODE_PROJECT_DIR_NAME
      if [ -z "$slug" ]; then
        top=$(git -C "$d" --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        case "$top" in
          */.git) top=${top%/.git} ;;
          ?*) top=$(git -C "$d" --no-optional-locks rev-parse --show-toplevel 2>/dev/null) ;;
          *) top=$(cd -P "$d" 2>/dev/null && pwd) ;;
        esac
        slug=${top//[!$alnum]/-}
      fi
      mem_file="$claude_dir/projects/$slug/memory/MEMORY.md"
    fi
    root m "$mem_file"
  fi
  printf '%s\n' "${roots#"$nl"}" | LC_ALL=C awk -v home="$HOME" -v user="$claude_dir/CLAUDE.md" \
    -v homeuser="$HOME/.claude/CLAUDE.md" -v agents="$set_agents" '
    function q(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
    # an import path: relative to the importing file, "~/" from home; "." and ".." folded so one
    # file reached two ways is counted once
    function resolve(f, tok,    p, n, parts, out, i, m) {
      if (tok ~ /\/$/) return ""
      if (substr(tok, 1, 2) == "~/") p = home substr(tok, 2)
      else if (substr(tok, 1, 1) == "/") p = tok
      else { p = f; sub(/\/[^\/]*$/, "", p); p = p "/" tok }
      n = split(p, parts, "/"); m = 0
      for (i = 2; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (m) m--; continue }
        out[++m] = parts[i]
      }
      p = ""
      for (i = 1; i <= m; i++) p = p "/" out[i]
      return p == "" ? "/" : p
    }
    # code spans hide imports: a run of n backticks up to the next run of exactly n; a run with no
    # match is plain text
    function nospan(s,    out, n, run, rest, scan, pos, k) {
      out = ""
      while (match(s, /`+/)) {
        n = RLENGTH; run = substr(s, RSTART, n)
        out = out substr(s, 1, RSTART - 1)
        rest = substr(s, RSTART + n)
        k = 0; scan = rest; pos = 0
        while (match(scan, /`+/)) {
          pos += RSTART + RLENGTH - 1
          if (RLENGTH == n) { k = pos; break }
          scan = substr(scan, RSTART + RLENGTH)
        }
        if (k) { out = out "x"; s = substr(rest, k + 1) } else { out = out run; s = rest }
      }
      return out s
    }
    # kind: u user, c project, a AGENTS.md, r rule, m MEMORY.md, i import; returns 1 when the file
    # exists
    function load(f, d, kind,    line, r, len, raw, over, fb, n, t, c, s, i, rest, tok, child, fence, fch, flen, cmt, fm, first, blank, pblank, phead, icode, inlist, code) {
      if (f in seen) return seen[f]
      seen[f] = 0
      # the roots are regular files already; an import may name a directory or a FIFO
      if (kind == "i") { print "C " f; if (system("test -f " q(f)) != 0) return 0 }
      first = 1; pblank = 1
      while ((r = (getline line < f)) > 0) {
        len = length(line) + 1
        # a file over 4 MiB is skipped whole: stop reading it there
        if ((raw += len) > 4194304) { over = 1; break }
        if (kind == "m") { if (++n > 200 || fb + len > 25000) break; fb += len; continue }
        sub(/\r$/, "", line)
        # rules: the frontmatter is not loaded, and a rule with paths: loads only on demand
        if (first && kind == "r" && line ~ /^---[ \t]*$/) { fm = 1; first = 0; continue }
        first = 0
        if (fm) {
          if (line ~ /^---[ \t]*$/) fm = 0
          else if (line ~ /^paths[ \t]*:/) { close(f); return seen[f] = 1 }
          continue
        }
        t = line; sub(/^ ? ? ?/, "", t)
        # fenced code: counted, never imports, HTML comments kept
        if (fence) {
          fb += len
          c = t; sub(/[ \t]+$/, "", c)
          if (substr(c, 1, 1) == fch && length(c) >= flen && c ~ /^(`+|~+)$/) { fence = 0; phead = 1; pblank = 0 }
          continue
        }
        if (match(t, /^(```+|~~~+)/)) { fence = 1; fch = substr(t, 1, 1); flen = RLENGTH; fb += len; continue }
        # block-level HTML comments are stripped before loading; text after the end counts
        if (cmt) {
          if (!(i = index(line, "-->"))) continue
          cmt = 0; line = substr(line, i + 3); len = length(line) + 1; t = line
        } else if (substr(t, 1, 4) == "<!--") {
          rest = substr(t, 5)
          if (!(i = index(rest, "-->"))) { cmt = 1; continue }
          line = substr(rest, i + 3); len = length(line) + 1; t = line
        }
        fb += len
        # indented code: four spaces or a tab after a blank line or a heading, outside a list
        blank = (line ~ /^[ \t]*$/)
        code = !blank && line ~ /^(    |\t)/ && !inlist && (pblank || phead || icode)
        icode = code || (icode && blank)
        if (!blank && line !~ /^(    |\t)/) inlist = (t ~ /^([-*+]|[0-9]+[.)])([ \t]|$)/) || (inlist && !pblank)
        pblank = blank; phead = (t ~ /^#/)
        if (code || d >= 4) continue
        # an import is "@" at the start or after a space, up to the next space; inline comments
        # and code spans hide it
        s = line
        while (i = index(s, "<!--")) {
          rest = substr(s, i + 4)
          if (!(n = index(rest, "-->"))) { s = substr(s, 1, i - 1); break }
          s = substr(s, 1, i - 1) " " substr(rest, n + 3)
        }
        s = nospan(s)
        while (match(s, /(^|[ \t])@[^ \t]+/)) {
          tok = substr(s, RSTART, RLENGTH); sub(/^[ \t]*@/, "", tok)
          s = substr(s, RSTART + RLENGTH)
          child = resolve(f, tok)
          if (child != "") load(child, d + 1, "i")
        }
      }
      close(f)
      # an empty file exists too
      if (r >= 0) seen[f] = 1
      if (!over) total += fb
      return seen[f]
    }
    { kind[NR] = substr($0, 1, 1); path[NR] = substr($0, 3) }
    END {
      for (i = 1; i <= NR; i++) {
        # ~/.claude/CLAUDE.md is the user file, not a project one of the home dir, also when
        # CLAUDE_CONFIG_DIR points elsewhere (assumed, not checked)
        if (kind[i] == "a" || kind[i] == "m" || (kind[i] == "c" && path[i] == homeuser)) continue
        # the user CLAUDE.md does not stop AGENTS.md from loading
        if (load(path[i], 0, kind[i]) && kind[i] == "c" && path[i] != user) claude = 1
      }
      for (i = 1; i <= NR; i++) {
        if (kind[i] == "a" && !claude && agents == "true") load(path[i], 0, "a")
        if (kind[i] == "m") load(path[i], 0, "m")
      }
      print "T " total + 0
    }' 2>/dev/null
}
mem_total=""
mem_dir="${project_dir:-$cwd}"
case "$mem_dir" in ''|/*) ;; *) mem_dir="$PWD/$mem_dir" ;; esac
if [ -n "$mem_dir" ]; then
  mem_key=${mem_dir//[!$alnum]/-}
  # a file name is at most 255 bytes: a long key is cut and gets a hash of the whole dir
  if [ ${#mem_key} -gt 200 ]; then ck=$(printf '%s' "$mem_dir" | cksum); mem_key="${mem_key:0:200}-${ck%% *}"; fi
  mem_cache="$state_dir/mem-$mem_key"
  mem_ok="" mem_old="" mem_v=""
  set --
  if [ -f "$mem_cache" ]; then
    while IFS= read -r l; do
      case "$l" in
        "v2 "*) mem_v=${l#v2 } ;;
        "P "*) [ "${l#P }" = "$mem_dir" ] && mem_ok=1 ;;
        "C "*) set -- "$@" "${l#C }" ;;
        "S "*) mem_old="${mem_old:+$mem_old$nl}${l#S }" ;;
      esac
    done < "$mem_cache"
    if [ -n "$mem_ok" ] && [ -n "$mem_v" ]; then mem_stat "$@"; [ "$st" = "$mem_old" ] && mem_total=$mem_v; fi
  fi
  if [ -z "$mem_total" ]; then
    set --
    while IFS= read -r l; do
      case "$l" in
        "T "*) mem_total=${l#T } ;;
        "C "*) set -- "$@" "${l#C }" ;;
      esac
    done <<EOF
$(mem_count "$mem_dir")
EOF
    case "$mem_total" in
      ''|*[!0-9]*) mem_total="" ;;
      *)
        mem_new="v2 $mem_total${nl}P $mem_dir"
        for f in "$@"; do mem_new="$mem_new${nl}C $f"; done
        mem_stat "$@"
        while IFS= read -r l; do [ -n "$l" ] && mem_new="$mem_new${nl}S $l"; done <<EOF
$st
EOF
        { mkdir -p "$state_dir" && printf '%s\n' "$mem_new" > "$mem_cache.$$" &&
          mv -f "$mem_cache.$$" "$mem_cache"; } 2>/dev/null || rm -f "$mem_cache.$$" 2>/dev/null
        ;;
    esac
  fi
fi
# skills: the payload has no per-category context breakdown, so estimate the skill listing from
# name + description in project and user SKILL.md frontmatter (~3 chars per token, matches /context
# within ~10%); skills with disable-model-invocation are not listed; plugin skills are not counted
set --
for f in "${project_dir:-$cwd}"/.claude/skills/*/SKILL.md "$claude_dir"/skills/*/SKILL.md; do
  # an unmatched glob stays literal, and BSD awk aborts on a missing file
  [ -f "$f" ] && set -- "$@" "$f"
done
# "  skll: ~3,100 tok ~0.3%": the byte total at ~3 per token, rounded to 100, and its share of the
# context window when the payload has its size
awk_est='
  function est(label, total, s,    n, u) {
    if (total <= 0) return
    n = total / 3
    u = sprintf("%d", int(n / 100 + 0.5) * 100)
    # under 50 tokens rounds to ~0: nothing to show
    if (u == "0") return
    while (u ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", u)
    printf "  %s: ~%s tok", label, u
    if (s > 0) printf " ~%.1f%%", n * 100 / s
  }'
est_str=""
# /dev/null: awk would read stdin with no files left
{ [ $# -gt 0 ] || [ -n "$mem_total" ]; } && est_str=$(LC_ALL=C awk -v s="${ctx_size:-0}" -v mem="${mem_total:-0}" "$awk_est"'
  function flush() { if (!skip) total += len; len = 0 }
  FNR == 1 { flush(); fm = 0; skip = 0; in_desc = 0 }
  # CRLF files: a trailing \r would hide the --- delimiters and skip the whole file
  { sub(/\r$/, "") }
  /^---[ \t]*$/ { fm++; in_desc = 0; next }
  fm != 1 { next }
  /^disable-model-invocation:[ \t]*true/ { skip = 1 }
  /^(name|description):/ { len += length($0); in_desc = ($0 ~ /^description:/); next }
  in_desc && /^[ \t]/ { len += length($0); next }
  { in_desc = 0 }
  END { flush(); est("skll", total, s); est("mem", mem, s) }' "$@" /dev/null 2>/dev/null)
case "$thinking_in" in
  true)  think_str=$(printf "${gray}thnk:\033[0m${cyan}on\033[0m") ;;
  false) think_str=$(printf "${gray}thnk:off\033[0m") ;;
  *)     think_str=$(printf "${gray}thnk:no\033[0m") ;;
esac

# prompts in the session: P per prompt, C per compaction, in transcript order. Tool results,
# meta and command entries (<command-name>, <bash-input>, <task-notification>), compact
# summaries and /compact itself are user entries too, but not prompts. The same pass sums the
# turn_duration entries Claude Code writes when a turn ends: "<sum ms> <last ms> <start|->",
# where start is the epoch of a prompt whose turn is still running.
# /rewind keeps the dropped entries in the file and appends an explicit last-prompt entry whose
# leafUuid is the entry to go on from (zeros: the start). After one, only the active branch counts:
# the entries from the leaf back along parentUuid, across a compaction along logicalParentUuid.
# The first pass also takes the explicit last-prompt entries and prints only "R" when it meets
# one, so a session without /rewind costs as before. Then the leaf is that leafUuid while no entry
# follows it, else the last entry with a uuid (tail -r reads from the end; a grep over the whole
# file took 2.4 s for 124 MB), and awk adds "I <uuid> <parent>" for the other entries: a full jq
# parse of them took 4.7 s for 124 MB (the count without /rewind 0.8 s), as did awk over every
# line. Every entry starts with "parentUuid" (the lines without it, such as api-request-blob, are
# skipped) and its first "uuid" and "logicalParentUuid" are its own (checked on 74,530 entries in
# October 2026)
rewind_re='^\{"type":"last-prompt".*"explicit":true'
other_ids() {
  grep '^{"parentUuid":' "$transcript" 2>/dev/null | grep -vE '"type":"(user|system)"' | LC_ALL=C awk '
    function id(key) { i = index($0, "\"" key "\":\""); return i ? substr($0, i + length(key) + 4, 36) : "" }
    {
      u = id("uuid")
      if (u == "") next
      p = substr($0, 1, 15) == "{\"parentUuid\":\"" ? substr($0, 16, 36) : id("logicalParentUuid")
      print "I", u, (p == "" ? "-" : p)
    }'
}
# $1: "" (find out), "-" (no chain) or the leaf
count_prompts() {
  { [ -n "$1" ] && [ "$1" != "-" ] && other_ids
    grep -E "\"type\":\"(user|system)\"|$rewind_re" "$transcript" 2>/dev/null; } | jq -nrR --arg leaf "$1" '
  [inputs |
    if startswith("I ") then split(" ") | {u: .[1], p: .[2]}
    else fromjson? | select(type == "object") | {u: (.uuid | if type == "string" then . else null end), p: (.parentUuid // .logicalParentUuid), e: .}
    end] |
  if $leaf == "" and any(.[]; .e.type == "last-prompt" and .e.explicit == true) then "R" else
  if $leaf == "" or $leaf == "-" then map(.e) else
    (reduce (.[] | select(.u != null)) as $x ({}; .[$x.u] = $x.p)) as $up |
    ([$leaf | recurse($up[.] | strings)] | map({key: ., value: true}) | from_entries) as $keep |
    map(select(.e != null and $keep[.u // ""]) | .e)
  end |
  map(
    if .type == "system" then
      if .subtype == "compact_boundary" then {k: "C"}
      elif .subtype == "turn_duration" then
        {k: "T", ms: (.durationMs | if type == "number" and . >= 0 then floor else 0 end)}
      else empty end
    elif .type != "user" or .isMeta == true or .isCompactSummary == true or .isSidechain == true then empty
    else (.timestamp | if type == "string" then sub("\\.[0-9]+"; "") | fromdateiso8601? else null end) as $at |
      .message.content |
      if type == "string" then select(startswith("<") or startswith("/compact") | not) | {k: "P", at: $at}
      elif type == "array" then select(map(.type?) | index("tool_result") | not) | {k: "P", at: $at}
      else empty end
    end) |
  (map(select(.k != "T") | .k) | join("")),
  "\(map(select(.k == "T") | .ms) | add // 0) \((map(select(.k == "T")) | last | .ms) // 0) \(if (last | .k) == "P" then (last | .at // "-" | tostring) else "-" end)"
  end' 2>/dev/null
}
# a session met with /rewind keeps its explicit entry, so "<session_id>.rewind" skips the first pass
rewind_flag=""
[ -n "$session_ok" ] && rewind_flag="$state_dir/$session_id.rewind"
marks="" turns="" leaf=""
# tail -r is BSD, tac GNU (also for the cache age of the last line)
rev="tail -r"; tail -r /dev/null > /dev/null 2>&1 || rev=tac
if [ -f "$transcript" ]; then
  if [ -n "$rewind_flag" ] && [ -f "$rewind_flag" ]; then scan=R; else scan=$(count_prompts "") || scan=""; fi
  if [ "$scan" = R ]; then
    [ -n "$rewind_flag" ] && { mkdir -p "$state_dir" && : > "$rewind_flag"; } 2>/dev/null
    m=$($rev "$transcript" 2>/dev/null | grep -m 1 -nE "$rewind_re")
    u=$($rev "$transcript" 2>/dev/null | grep -m 1 -n '"uuid":"')
    if [ -n "$u" ] && [ "${u%%:*}" -lt "${m%%:*}" ] 2>/dev/null; then
      leaf=$(printf '%s\n' "$u" | LC_ALL=C awk '{ i = index($0, "\"uuid\":\""); print substr($0, i + 8, 36) }')
    else
      leaf=$(printf '%s\n' "$m" | sed -n 's/.*"leafUuid":"\([0-9a-f-]*\)".*/\1/p')
    fi
    scan=$(count_prompts "${leaf:--}") || scan=""
  fi
  [ -n "$scan" ] && { marks=${scan%%"$nl"*}; turns=${scan#*"$nl"}; }
fi
# "13 prompts 8·4·1": the total, then the prompts before each compaction and since the last one;
# no prompts show nothing, but "0 prompts" once /rewind dropped them all
prompts_str=$(LC_ALL=C awk -v m="$marks" -v g="$gray" -v r="${leaf#-}" 'BEGIN {
  p = gsub(/P/, "P", m)
  if (p == 0 && r == "") exit
  u = sprintf("%d", p)
  while (u ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", u)
  printf "  \033[0;37m%s\033[0m %s%s", u, g, (p == 1 ? "prompt" : "prompts")
  seg = m
  gsub(/P/, "", seg)
  if (seg != "") {
    k = split(m, part, "C")
    printf "  "
    for (i = 1; i < k; i++) printf "%s%d", (i > 1 ? "·" : ""), length(part[i])
    # the count since the last compaction is white, like the total; ·0 right after one stays gray
    printf "·%s%d", (length(part[k]) > 0 ? "\033[0;37m" : ""), length(part[k])
  }
  printf "\033[0m"
}')
printf "%s%s${gray}%s\033[0m%s\n" "$p6" "$think_str" "$est_str" "$prompts_str"

if [ -n "$used" ]; then
  # current_usage gives exact tokens; older payloads only have the percentage
  ctx_n=$(LC_ALL=C awk -v s="${ctx_size:-0}" -v p="$used" -v n="$ctx_tokens" 'BEGIN {
  if (n == "") n = s * p / 100
  printf "%d", n
}')
  case "$ctx_n" in ''|*[!0-9]*) ctx_n=0 ;; esac

  # context growth since the previous prompt: the payload has no prompt boundary, so the
  # promptId of the last user entry in the transcript marks it; per-session state holds
  # "<promptId> <base> <last> <cost base> <cost last>", where the bases are the context and the
  # session cost when that prompt started (older state files have no cost fields)
  delta=0
  cost_delta_str=""
  case "$session_id" in
    ''|*[!A-Za-z0-9_-]*) ;;
    *)
      prompt_id=""
      [ -f "$transcript" ] && prompt_id=$(tail -c 262144 "$transcript" 2>/dev/null |
        grep -o '"promptId":"[A-Za-z0-9_-]*"' | tail -n 1 | cut -d'"' -f4)
      # zeros right after /compact are not a context size
      if [ -n "$prompt_id" ] && [ "$ctx_n" -gt 0 ]; then
        state_dir="$claude_dir/statusline-state"
        state="$state_dir/$session_id"
        # fixed-point: jq prints tiny costs in exponent form
        cost_n=$(LC_ALL=C awk -v c="${cost_usd:-0}" 'BEGIN { printf "%.6f", (c + 0 > 0 ? c : 0) }')
        s_prompt="" s_base="" s_last="" s_cbase="" s_clast=""
        [ -f "$state" ] && read -r s_prompt s_base s_last s_cbase s_clast < "$state" 2>/dev/null
        case "$s_base$s_last" in ''|*[!0-9]*) s_prompt="" ;; esac
        case "$s_cbase$s_clast" in *[!0-9.]*) s_cbase="" s_clast="" ;; esac
        if [ -z "$s_prompt" ]; then
          base=$ctx_n cbase=$cost_n
          # a new session file: drop the ones idle for a week
          find "$state_dir" -type f -mtime +7 -delete 2>/dev/null
        elif [ "$s_prompt" != "$prompt_id" ]; then
          base=$s_last cbase=${s_clast:-$cost_n}
        else
          base=$s_base cbase=${s_cbase:-$cost_n}
        fi
        # after /compact the context shrinks: count the growth from the compacted size
        [ "$ctx_n" -lt "$base" ] && base=$ctx_n
        delta=$(( ctx_n - base ))
        # cost of the current prompt so far; a smaller session cost (a resumed session counts
        # from zero) lowers the base the same way; hidden while the base is zero, as it would
        # repeat the session cost
        cost_info=$(LC_ALL=C awk -v c="$cost_n" -v b="$cbase" -v col="$cyan" 'BEGIN {
          if (c + 0 < b + 0) b = c
          printf "%.6f", b
          if (b > 0 && c - b >= 0.005) printf "  %s+$%.2f\033[0m", col, c - b
        }')
        cbase=${cost_info%%[!0-9.]*}
        cost_delta_str=${cost_info#"$cbase"}
        # write only on change; a failed write never breaks the render
        if [ "$prompt_id $base $ctx_n $cbase $cost_n" != "$s_prompt $s_base $s_last $s_cbase $s_clast" ]; then
          { mkdir -p "$state_dir" &&
            printf '%s %s %s %s %s\n' "$prompt_id" "$base" "$ctx_n" "$cbase" "$cost_n" > "$state.$$" &&
            mv -f "$state.$$" "$state"; } 2>/dev/null || rm -f "$state.$$" 2>/dev/null
        fi
      fi
      ;;
  esac
  [ -n "$cost_str" ] && cost_str="$cost_str$cost_delta_str"

  now=$(date +%s)

  # no rate_limits in the payload, but the account had them: a subscription, drawn from the cache
  # with a gray percentage, as the values may be stale. A window whose reset has passed has an
  # unknown usage: an empty bar, "--%" and no reset time (the next 5-hour window starts with the
  # next message, and the weekly reset moment is not known to be fixed)
  limits_col="" session_txt="" weekly_txt=""
  if [ -z "$session_pct" ] && [ -z "$weekly_pct" ] && [ -f "$limits_cache" ]; then
    c_sp="" c_sr="" c_wp="" c_wr="" c_ok=1
    read -r c_sp c_sr c_wp c_wr < "$limits_cache" 2>/dev/null
    # "-" or an integer short enough for test and $(( )), as the script wrote it
    for v in "$c_sp" "$c_sr" "$c_wp" "$c_wr"; do
      case "$v" in -) ;; ''|*[!0-9-]*|?*-*|?????????????*) c_ok="" ;; esac
    done
    if [ -n "$c_ok" ] && [ "$c_sp$c_wp" != "--" ]; then
      limits_col=90
      if [ "$c_sp" != - ]; then
        session_pct=$c_sp session_reset=""
        [ "$c_sr" = - ] || session_reset=$c_sr
        [ -n "$session_reset" ] && [ "$session_reset" -le "$now" ] && session_pct=0 session_txt=-- session_reset=""
      fi
      if [ "$c_wp" != - ]; then
        weekly_pct=$c_wp weekly_reset=""
        [ "$c_wr" = - ] || weekly_reset=$c_wr
        [ -n "$weekly_reset" ] && [ "$weekly_reset" -le "$now" ] && weekly_pct=0 weekly_txt=-- weekly_reset=""
      fi
    fi
  fi

  # Enterprise: no sess/week limits, so the spend comes from the claude.ai API cache
  spend_used="" spend_limit="" spend_pct=""
  if [ -z "$session_pct" ] && [ -z "$weekly_pct" ]; then
    cache_file="$claude_dir/usage-cache.json"
    fetch_script="$claude_dir/usage-fetch.js"

    # Refresh cache if absent or >5 min stale (background, non-blocking)
    cache_age=999999
    if [ -f "$cache_file" ]; then
      cache_ts=$(jq -r '.timestamp | if type == "number" and . >= 0 and . < 1e15 then floor else 0 end' "$cache_file" 2>/dev/null)
      [ -n "$cache_ts" ] && cache_age=$(( now - cache_ts / 1000 ))
    fi
    [ "$cache_age" -gt 300 ] && [ -f "$fetch_script" ] && node "$fetch_script" &>/dev/null &

    # Parse cache via jq+awk
    spend_used="" spend_limit="" spend_pct=""
    if [ -f "$cache_file" ] && [ "$cache_age" -lt 86400 ]; then
      read -r spend_used spend_limit spend_pct <<EOF
$(jq -r '[.data.spend.used.amount_minor // 0, .data.spend.used.exponent // 2, .data.spend.limit.amount_minor // 0, .data.spend.limit.exponent // 2, .data.spend.percent // 0] | @tsv' "$cache_file" 2>/dev/null | LC_ALL=C awk -F'\t' '{
  used_m=$1+0; used_e=$2+0; lim_m=$3+0; lim_e=$4+0; pct=$5+0
  printf "%.2f %.0f %d\n", used_m/10^used_e, lim_m/10^lim_e, pct
}')
EOF
    fi

  fi

  # line 3: cntx bar + exact tokens / window size + growth since the previous prompt (one awk call)
  ctx_info=$(LC_ALL=C awk -v s="${ctx_size:-0}" -v n="$ctx_n" -v d="$delta" -v g="$gray" '
  # thousands separators by hand: the %\047d flag is not portable across awk implementations
  function group(x,   u) {
    u = sprintf("%d", x)
    while (u ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", u)
    return u
  }
  BEGIN {
  col = (n >= 150000 ? "31" : (n >= 100000 ? "33" : "32"))
  t = s / 1000
  t = (t >= 1000 ? sprintf("%.0fM", t/1000) : sprintf("%.0fk", t))
  printf "\033[0;%sm%s\033[0m %stok /%s\033[0m", col, group(n), g, t
  if (d > 0) printf "  \033[0;%sm+%s\033[0m %stok\033[0m", col, group(d), g
}')
  # agent time: the finished turns plus a running one in white, then "+" the running or last turn
  # in gray, at the end of the last line (week, else rest, else cntx)
  time_str=$(LC_ALL=C awk -v t="$turns" -v now="$(date +%s)" -v g="$gray" "$awk_fmt"'
  BEGIN {
    if (split(t, f, " ") < 3) exit
    sum = f[1] / 1000; last = f[2] / 1000
    if (f[3] != "-" && now >= f[3] + 0) { last = now - f[3]; sum += last }
    if (sum < 1) exit
    printf "  \033[0;37m%s\033[0m", fmt(sum)
    if (last >= 1) printf "  %s+%s\033[0m", g, fmt(last)
  }')
  # billing month between UTC midnights on the 1st, for the Enterprise rest line
  month_start=$(TZ=UTC date -v1d -v0H -v0M -v0S +%s 2>/dev/null)
  next_month=$(TZ=UTC date -v+1m -v1d -v0H -v0M -v0S +%s 2>/dev/null)
  week_time="" rest_time=""
  if [ -n "$weekly_pct" ]; then week_time=$time_str
  elif [ -z "$session_pct" ] && [ -n "$month_start" ] && [ -n "$next_month" ]; then rest_time=$time_str
  else ctx_info="$ctx_info$time_str"
  fi
  ctx_bar=$(render_bar "cntx" "$used_int")
  # without a sess line the cost goes on the used line, else here
  [ -z "$session_pct" ] && { [ -z "$spend_pct" ] || [ -z "$spend_used" ]; } && ctx_info="$ctx_info$cost_str"
  printf "%s%s  %s\n" "$p6" "$ctx_bar" "$ctx_info"

  # line 4: sess
  if [ -n "$session_pct" ]; then
    sess_bar=$(render_bar "sess" "$session_pct" "$limits_col" "$session_txt")
    if [ -n "$session_reset" ]; then
      printf "%s%s  $gray%s  %s\033[0m%s\n" "$p6" "$sess_bar" "$(fmt_reset_at "$session_reset")" "$(fmt_eta_hm $(( session_reset - now )))" "$cost_str"
    else
      printf "%s%s%s\n" "$p6" "$sess_bar" "$cost_str"
    fi
  fi

  # line 5: week
  if [ -n "$weekly_pct" ]; then
    week_bar=$(render_bar "week" "$weekly_pct" "$limits_col" "$weekly_txt")
    if [ -n "$weekly_reset" ]; then
      printf "%s%s  $gray%s  %s\033[0m%s\n" "$p6" "$week_bar" "$(fmt_reset_at "$weekly_reset")" "$(fmt_eta_dhm $(( weekly_reset - now )))" "$week_time"
    else
      printf "%s%s%s\n" "$p6" "$week_bar" "$week_time"
    fi
  fi

  # Enterprise: no sess/week limits → show real usage from claude.ai API
  if [ -z "$session_pct" ] && [ -z "$weekly_pct" ]; then
    if [ -n "$spend_pct" ] && [ -n "$spend_used" ]; then
      usage_bar=$(render_bar "used" "$spend_pct")
      printf "%s%s  $cyan\$%s$gray/\$%s\033[0m%s\n" \
        "$p6" "$usage_bar" "$spend_used" "$spend_limit" "$cost_str"
    fi

    # rest: share of the billing month already elapsed + time until reset
    if [ -n "$month_start" ] && [ -n "$next_month" ]; then
      rest_bar=$(render_bar "rest" "$(( (now - month_start) * 100 / (next_month - month_start) ))")
      printf "%s%s  $gray%s\033[0m%s\n" "$p6" "$rest_bar" "$(fmt_eta_dhm $(( next_month - now )))" "$rest_time"
    fi
  fi
fi

# last line: when the session started (its first transcript entry, also after /rewind), how long
# it has been going, and the prompt cache age: the time since the last API response, the last
# assistant entry of the file (read from the end; after /rewind too, as the request still
# refreshed the cache of the shared prefix). Synthetic entries (API errors, "No response
# requested") and sidechain ones made no main request; up to 20 matches are tried.
# "<epoch> <5|->": 5 when that response wrote the cache with the 5-minute TTL only
start="" cache_at=""
# (a file-history-snapshot comes first, its timestamp nested)
[ -f "$transcript" ] && start=$(grep -m 1 -E '"type":"(user|assistant|system)"' "$transcript" 2>/dev/null |
  jq -r '.timestamp | strings | sub("\\.[0-9]+"; "") | fromdateiso8601? | floor' 2>/dev/null)
[ -n "$start" ] && cache_at=$($rev "$transcript" 2>/dev/null | grep -m 20 '"type":"assistant"' | jq -nrR '
  first(inputs | fromjson? | select(type == "object" and .type == "assistant" and .isSidechain != true and .message.model != "<synthetic>")) |
  (.timestamp | strings | sub("\\.[0-9]+"; "") | fromdateiso8601? | floor) as $at |
  (.message.usage.cache_creation | if type == "object" then . else {} end) as $w |
  "\($at) \(if ($w.ephemeral_5m_input_tokens // 0) > 0 and ($w.ephemeral_1h_input_tokens // 0) == 0 then 5 else "-" end)"' 2>/dev/null)
case "$start" in
  [0-9]*)
    now=$(date +%s)
    # a session from another day names the day
    fmt=+%H:%M
    [ $(( now - start )) -ge 86400 ] && fmt="+%a %H:%M"
    started=$(LC_ALL=C date -r "$start" "$fmt" 2>/dev/null || LC_ALL=C date -d "@$start" "$fmt" 2>/dev/null)
    # both durations name days from a day. The cache age is green while every cache TTL is alive,
    # yellow once only a 1-hour one can be (from 5 minutes), red from 1 hour; after a response that
    # wrote the 5-minute TTL only, red from 5 minutes
    LC_ALL=C awk -v s="$start" -v at="$started" -v c="$cache_at" -v now="$now" -v g="$gray" -v p6="$p6" "$awk_fmt"'
    function fmtd(x) { return x >= 86400 ? sprintf("%dd %dh %dm", x / 86400, (x % 86400) / 3600, (x % 3600) / 60) : fmt(x) }
    BEGIN {
      d = now > s ? now - s : 0
      printf "%s%ssession started\033[0m \033[0;37m%s\033[0m  %sgoing\033[0m \033[0;37m%s\033[0m", p6, g, at, g, fmtd(d)
      if (split(c, f, " ") == 2 && f[1] ~ /^[0-9]+$/) {
        a = now > f[1] + 0 ? now - f[1] : 0
        col = (a >= 3600 || (f[2] == "5" && a >= 300) ? "31" : (a >= 300 ? "33" : "32"))
        printf "  %scache\033[0m \033[0;%sm%s\033[0m", g, col, fmtd(a)
      }
      printf "\n"
    }'
    ;;
esac

exit 0
