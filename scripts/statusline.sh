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

dir=$(basename "$cwd")

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

# labelled progress bar
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
  printf "$gray%s:\033[0m\033[0;%sm%s\033[0m \033[0;37m%s%%\033[0m" "$label" "$col" "$bar" "$pct_int"
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

# owner/repo of the origin remote on GitHub (an ssh alias like github-work counts), else nothing
gh_slug() {
  git -C "$1" --no-optional-locks remote get-url origin 2>/dev/null | sed -nE \
    's#^(https://|ssh://)?([^@/]+@)?github(\.com|-[A-Za-z0-9_-]+)[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$#\4/\5#p' |
    sed 's/\.git$//'
}

# " · PR #N" for a PR number and state; state words follow pr.review_state, plus merged/closed
pr_label() {
  case "$1" in ''|*[!0-9]*) return ;; esac
  col=37 suffix=""
  case "$2" in
    approved) col=32 ;;
    changes_requested) col=31 ;;
    draft) col=90 suffix=" draft" ;;
    merged) col=35 suffix=" merged" ;;
    closed) col=90 suffix=" closed" ;;
  esac
  printf " ${gray}·\033[0m \033[0;%sm%s #%s%s\033[0m" "$col" "${3:-PR}" "$1" "$suffix"
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
# agent transcripts, read incrementally. State "<session_id>.repos": "o <offset> <file>" per
# transcript, up to the end of its last complete line, then "r <root>" per repo in first-edit order
roots=""
if [ -n "$session_ok" ] && [ -f "$transcript" ]; then
  repos_state="$state_dir/$session_id.repos"
  old_state=""
  [ -f "$repos_state" ] && old_state=$(cat "$repos_state" 2>/dev/null)
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
        function emit(r) { if (r ~ /"name":"(Edit|Write|NotebookEdit)"/) print "L" r }
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
      dirs=$(printf '%s\n' "$out" | sed -n 's/^L//p' | jq -rR '
        fromjson? | select(type == "object" and .type == "assistant") | .message.content[]? |
        select(type == "object" and .type == "tool_use" and (.name == "Edit" or .name == "Write" or .name == "NotebookEdit")) |
        (.input.file_path // .input.notebook_path) | strings | select(startswith("/") and (contains("\n") | not))' 2>/dev/null |
        sed 's#/[^/]*$##' | awk '!seen[$0]++')
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
  new_state=$(printf '%s\n' "${offsets#"$nl"}"; [ -n "$roots" ] && printf '%s\n' "$roots" | sed 's/^/r /')
  if [ "$new_state" != "$old_state" ]; then
    { mkdir -p "$state_dir" && printf '%s\n' "$new_state" > "$repos_state.$$" &&
      mv -f "$repos_state.$$" "$repos_state"; } 2>/dev/null || rm -f "$repos_state.$$" 2>/dev/null
  fi
fi

printf "\033[1;32m➜\033[0m  $cyan%s\033[0m%s%s%s\n" "$dir" "$git_info" "$model_str" "$pr_str"

# one line per other repo the session edited, at most 3, then "+N repos"
shown=0 more=0
while IFS= read -r root; do
  [ -n "$root" ] && [ "$root" != "$cwd_root" ] && [ -d "$root" ] || continue
  br=$(git -C "$root" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  label=$br
  [ -n "$label" ] || label=$(git -C "$root" --no-optional-locks rev-parse --short HEAD 2>/dev/null) || continue
  if [ "$shown" -ge 3 ]; then more=$(( more + 1 )); continue; fi
  shown=$(( shown + 1 ))
  slug=$(gh_slug "$root")
  name=${slug:-$(basename "$root")}
  [ -n "$slug" ] && [ "${slug%%/*}" = "${cwd_slug%%/*}" ] && name=${slug#*/}
  repo_pr=""
  [ -n "$br" ] && repo_pr=$(pr_cached "$slug" "$br" "$root")
  printf "${gray}↳\033[0m  $cyan%s\033[0m ${gray}·\033[0m%s%s\n" "$name" "$(git_label "$root" "$label")" "$repo_pr"
done <<EOF
$roots
EOF
[ "$more" -gt 0 ] && printf "${gray}↳  +%s %s\033[0m\n" "$more" "$([ "$more" -eq 1 ] && echo repo || echo repos)"

# line 2: thinking + skills estimate + prompts
# skills: the payload has no per-category context breakdown, so estimate the skill listing from
# name + description in project and user SKILL.md frontmatter (~3 chars per token, matches /context
# within ~10%); skills with disable-model-invocation are not listed; plugin skills are not counted
set --
for f in "${project_dir:-$cwd}"/.claude/skills/*/SKILL.md "$claude_dir"/skills/*/SKILL.md; do
  # an unmatched glob stays literal, and BSD awk aborts on a missing file
  [ -f "$f" ] && set -- "$@" "$f"
done
skills_str=""
[ $# -gt 0 ] && skills_str=$(LC_ALL=C awk -v s="${ctx_size:-0}" '
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
  END {
    flush()
    if (total == 0) exit
    n = total / 3
    u = sprintf("%d", int(n / 100 + 0.5) * 100)
    while (u ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", u)
    printf "  skll: ~%s tok", u
    if (s > 0) printf " ~%.1f%%", n * 100 / s
  }' "$@" 2>/dev/null)
case "$thinking_in" in
  true)  think_str=$(printf "${gray}thnk:\033[0m${cyan}on\033[0m") ;;
  false) think_str=$(printf "${gray}thnk:off\033[0m") ;;
  *)     think_str=$(printf "${gray}thnk:no\033[0m") ;;
esac

# prompts in the session: P per prompt, C per compaction, in transcript order. Tool results,
# meta and command entries (<command-name>, <bash-input>, <task-notification>), compact
# summaries and /compact itself are user entries too, but not prompts
marks=""
[ -f "$transcript" ] && marks=$(grep -E '"type":"(user|system)"' "$transcript" 2>/dev/null | jq -rR '
  fromjson? | select(type == "object") |
  if .type == "system" then select(.subtype == "compact_boundary") | "C"
  elif .type != "user" or .isMeta == true or .isCompactSummary == true or .isSidechain == true then empty
  else .message.content |
    if type == "string" then select(startswith("<") or startswith("/compact") | not) | "P"
    elif type == "array" then select(map(.type?) | index("tool_result") | not) | "P"
    else empty end
  end' 2>/dev/null | tr -d '\n')
# "13 prompts 8·4·1": the total, then the prompts before each compaction and since the last one
prompts_str=$(LC_ALL=C awk -v m="$marks" -v g="$gray" 'BEGIN {
  p = gsub(/P/, "P", m)
  if (p == 0) exit
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
printf "%s%s${gray}%s\033[0m%s\n" "$p6" "$think_str" "$skills_str" "$prompts_str"

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
  ctx_bar=$(render_bar "cntx" "$used_int")
  # without a sess line the cost goes on the used line, else here
  [ -z "$session_pct" ] && { [ -z "$spend_pct" ] || [ -z "$spend_used" ]; } && ctx_info="$ctx_info$cost_str"
  printf "%s%s  %s\n" "$p6" "$ctx_bar" "$ctx_info"

  # line 4: sess
  if [ -n "$session_pct" ]; then
    sess_bar=$(render_bar "sess" "$session_pct")
    if [ -n "$session_reset" ]; then
      printf "%s%s  $gray%s  %s\033[0m%s\n" "$p6" "$sess_bar" "$(fmt_reset_at "$session_reset")" "$(fmt_eta_hm $(( session_reset - now )))" "$cost_str"
    else
      printf "%s%s%s\n" "$p6" "$sess_bar" "$cost_str"
    fi
  fi

  # line 5: week
  if [ -n "$weekly_pct" ]; then
    week_bar=$(render_bar "week" "$weekly_pct")
    if [ -n "$weekly_reset" ]; then
      printf "%s%s  $gray%s  %s\033[0m\n" "$p6" "$week_bar" "$(fmt_reset_at "$weekly_reset")" "$(fmt_eta_dhm $(( weekly_reset - now )))"
    else
      printf "%s%s\n" "$p6" "$week_bar"
    fi
  fi

  # Enterprise: no sess/week limits → show real usage from claude.ai API
  if [ -z "$session_pct" ] && [ -z "$weekly_pct" ]; then
    # billing month runs between UTC midnights on the 1st
    month_start=$(TZ=UTC date -v1d -v0H -v0M -v0S +%s 2>/dev/null)
    next_month=$(TZ=UTC date -v+1m -v1d -v0H -v0M -v0S +%s 2>/dev/null)

    if [ -n "$spend_pct" ] && [ -n "$spend_used" ]; then
      usage_bar=$(render_bar "used" "$spend_pct")
      printf "%s%s  $cyan\$%s$gray/\$%s\033[0m%s\n" \
        "$p6" "$usage_bar" "$spend_used" "$spend_limit" "$cost_str"
    fi

    # rest: share of the billing month already elapsed + time until reset
    if [ -n "$month_start" ] && [ -n "$next_month" ]; then
      rest_bar=$(render_bar "rest" "$(( (now - month_start) * 100 / (next_month - month_start) ))")
      printf "%s%s  $gray%s\033[0m\n" "$p6" "$rest_bar" "$(fmt_eta_dhm $(( next_month - now )))"
    fi
  fi
fi

exit 0
