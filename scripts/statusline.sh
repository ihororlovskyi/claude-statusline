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
  "cwd="          + (.cwd | str | @sh),
  "project_dir="  + (.workspace.project_dir | str | @sh),
  "model="        + (.model.display_name | str | @sh),
  "used="         + (.context_window.used_percentage | num | @sh),
  "used_int="     + (.context_window.used_percentage | pct | @sh),
  "ctx_size="     + (.context_window.context_window_size | num | @sh),
  "ctx_tokens="   + (.context_window.current_usage | if type == "object" then [.input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens] | map(select(type == "number")) | if length > 0 then add | tostring else "" end else "" end | @sh),
  "effort_val="   + (.effort.level | str | @sh),
  "thinking_in="  + (.thinking.enabled | if type == "boolean" then tostring else "" end | @sh),
  "cost_usd="     + (.cost.total_cost_usd | num | @sh),
  "session_pct="  + (.rate_limits.five_hour.used_percentage | pct | @sh),
  "session_reset="+ (.rate_limits.five_hour.resets_at | int | @sh),
  "weekly_pct="   + (.rate_limits.seven_day.used_percentage | pct | @sh),
  "weekly_reset=" + (.rate_limits.seven_day.resets_at | int | @sh)
')"

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
gray="\033[0;90m"
cyan="\033[0;36m"
mag="\033[0;35m"

dir=$(basename "$cwd")

# git branch + dirty state
# symbolic-ref prints nothing outside a repo or on a detached HEAD
git_info=""
branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  dirty=""
  [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="\033[0;33m ✗"
  git_info=$(printf " \033[1;34mgit:(\033[0;31m%s\033[1;34m)$dirty\033[0m" "$branch")
fi

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
# session cost: on the sess line, else on the cntx line, else (no context data) on line 1
cost_str=$(LC_ALL=C awk -v c="${cost_usd:-0}" -v col="$cyan" 'BEGIN { if (c + 0 > 0) printf "  %s$%.2f\033[0m", col, c }')
if [ -z "$used" ] && [ -n "$cost_usd" ]; then
  model_str="$model_str$cost_str"
fi
printf "\033[1;32m➜\033[0m  $cyan%s\033[0m%s%s\n" "$dir" "$git_info" "$model_str"

# line 2: thinking + skills estimate
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
    printf "  skills: ~%s tokens", u
    if (s > 0) printf " (~%.1f%%)", n * 100 / s
  }' "$@" 2>/dev/null)
case "$thinking_in" in
  true)  think_str=$(printf "${gray}thinking:\033[0m${cyan}on\033[0m") ;;
  false) think_str=$(printf "${gray}thinking:off\033[0m") ;;
  *)     think_str=$(printf "${gray}thinking:no\033[0m") ;;
esac
printf "%s%s${gray}%s\033[0m\n" "$p6" "$think_str" "$skills_str"

if [ -n "$used" ]; then
  # line 3: cntx bar + exact tokens / window size (one awk call)
  # current_usage gives exact tokens; older payloads only have the percentage
  ctx_info=$(LC_ALL=C awk -v s="${ctx_size:-0}" -v p="$used" -v n="$ctx_tokens" -v g="$gray" 'BEGIN {
  if (n == "") n = s * p / 100
  col = (n >= 150000 ? "31" : (n >= 100000 ? "33" : "32"))
  # thousands separators by hand: the %\047d flag is not portable across awk implementations
  u = sprintf("%d", n)
  while (u ~ /[0-9][0-9][0-9][0-9]/) sub(/[0-9][0-9][0-9]($|,)/, ",&", u)
  t = s / 1000
  t = (t >= 1000 ? sprintf("%.0fM", t/1000) : sprintf("%.0fk", t))
  printf "\033[0;%sm%s\033[0m %stok /%s\033[0m", col, u, g, t
}')
  ctx_bar=$(render_bar "cntx" "$used_int")
  [ -z "$session_pct" ] && ctx_info="$ctx_info$cost_str"
  printf "%s%s  %s\n" "$p6" "$ctx_bar" "$ctx_info"

  now=$(date +%s)

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

    # billing month runs between UTC midnights on the 1st
    month_start=$(TZ=UTC date -v1d -v0H -v0M -v0S +%s 2>/dev/null)
    next_month=$(TZ=UTC date -v+1m -v1d -v0H -v0M -v0S +%s 2>/dev/null)

    if [ -n "$spend_pct" ] && [ -n "$spend_used" ]; then
      usage_bar=$(render_bar "used" "$spend_pct")
      printf "%s%s  $cyan\$%s$gray/\$%s\033[0m\n" \
        "$p6" "$usage_bar" "$spend_used" "$spend_limit"
    fi

    # rest: share of the billing month already elapsed + time until reset
    if [ -n "$month_start" ] && [ -n "$next_month" ]; then
      rest_bar=$(render_bar "rest" "$(( (now - month_start) * 100 / (next_month - month_start) ))")
      printf "%s%s  $gray%s\033[0m\n" "$p6" "$rest_bar" "$(fmt_eta_dhm $(( next_month - now )))"
    fi
  fi
fi

exit 0
