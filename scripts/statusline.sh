#!/bin/sh
input=$(cat)

# parse all fields from stdin in one jq call via eval+@sh
# every field is type-checked before @sh: an array would become several shell words and run as a command;
# numbers reach awk and $(( )); timestamps are floored and bounded because $(( )) takes only plain integers
eval "$(echo "$input" | jq -r '
  def str: if type == "string" then . else "" end;
  def num: if type == "number" then tostring else "" end;
  def int: if type == "number" and . >= 0 and . < 1e12 then floor | tostring else "" end;
  "cwd="          + (.cwd | str | @sh),
  "model="        + (.model.display_name | str | @sh),
  "used="         + (.context_window.used_percentage | num | @sh),
  "ctx_size="     + (.context_window.context_window_size | num | @sh),
  "effort_val="   + (.effort.level | str | @sh),
  "thinking_in="  + (.thinking.enabled | if type == "boolean" then tostring else "" end | @sh),
  "cost_usd="     + (.cost.total_cost_usd | num | @sh),
  "session_pct="  + (.rate_limits.five_hour.used_percentage | num | @sh),
  "session_reset="+ (.rate_limits.five_hour.resets_at | int | @sh),
  "weekly_pct="   + (.rate_limits.seven_day.used_percentage | num | @sh),
  "weekly_reset=" + (.rate_limits.seven_day.resets_at | int | @sh)
')"

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

dir=$(basename "$cwd")

# git branch + dirty state
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$dirty" ]; then
      git_info=$(printf " \033[1;34mgit:(\033[0;31m%s\033[1;34m)\033[0;33m ✗\033[0m" "$branch")
    else
      git_info=$(printf " \033[1;34mgit:(\033[0;31m%s\033[1;34m)\033[0m" "$branch")
    fi
  fi
fi

# thinking: stdin first, fallback to settings.json; effort fallback if not in stdin
thinking_label="thinking:off"
if [ -z "$thinking_in" ] || [ -z "$effort_val" ]; then
  settings_file="$claude_dir/settings.json"
  if [ -f "$settings_file" ]; then
    eval "$(jq -r '
      "thinking_fallback=" + ((.alwaysThinkingEnabled // false) | tostring | @sh),
      "effort_fallback="   + (.effortLevel | if type == "string" then . else "" end | @sh)
    ' "$settings_file" 2>/dev/null)"
    [ -z "$thinking_in" ] && thinking_in="$thinking_fallback"
    [ -z "$effort_val"  ] && effort_val="$effort_fallback"
  fi
fi
[ "$thinking_in" = "true" ] && thinking_label="thinking:on"

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
  if   [ "$pct_int" -ge 80 ]; then printf "\033[0;90m%s:\033[0m\033[0;31m%s\033[0m \033[0;37m%s%%\033[0m" "$label" "$bar" "$pct_int"
  elif [ "$pct_int" -ge 50 ]; then printf "\033[0;90m%s:\033[0m\033[0;33m%s\033[0m \033[0;37m%s%%\033[0m" "$label" "$bar" "$pct_int"
  else                             printf "\033[0;90m%s:\033[0m\033[0;32m%s\033[0m \033[0;37m%s%%\033[0m" "$label" "$bar" "$pct_int"
  fi
}

# awk instead of the printf builtin: sh mode ignores a per-command LC_ALL and misparses decimals in comma locales
round() { LC_ALL=C awk -v n="$1" 'BEGIN { printf "%.0f", n }'; }

fmt_eta_hm() {
  total="$1"; [ "$total" -lt 0 ] && total=0
  printf "%dh %dm" "$(( total / 3600 ))" "$(( (total % 3600) / 60 ))"
}
fmt_eta_dhm() {
  total="$1"; [ "$total" -lt 0 ] && total=0
  printf "%dd %dh %dm" "$(( total / 86400 ))" "$(( (total % 86400) / 3600 ))" "$(( (total % 3600) / 60 ))"
}

p6="      "

# line 1: cost
cost_line1=""
if [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ]; then
  cost_fmt=$(LC_ALL=C awk -v c="$cost_usd" 'BEGIN { printf "$%.2f", c }')
  cost_line1=$(printf "  \033[0;36m%s\033[0m" "$cost_fmt")
fi

model_str=""
[ -n "$model" ] && model_str=$(printf "  \033[0;35m%s\033[0m" "$model")
printf "\033[1;32m➜\033[0m  \033[0;36m%s\033[0m%s%s%s\n" "$dir" "$git_info" "$model_str" "$cost_line1"

if [ -n "$used" ]; then
  used_int=$(round "$used")

  # line 2: thinking + effort
  if [ "$thinking_label" = "thinking:on" ]; then
    th_colored=$(printf "\033[0;90mthinking:\033[0m\033[0;36mon\033[0m")
  else
    th_colored=$(printf "\033[0;90mthinking:\033[0m\033[0;90moff\033[0m")
  fi
  ef_colored=""
  [ -n "$effort_val" ] && ef_colored=$(printf "  \033[0;90meffort:\033[0m\033[0;36m%s\033[0m" "$effort_val")
  printf "%s%s%s\n" "$p6" "$th_colored" "$ef_colored"

  # line 3: cntx bar + tokens (one awk call)
  read -r tok_k ctx_k <<EOF
$(LC_ALL=C awk -v s="${ctx_size:-0}" -v p="$used" 'BEGIN {
  u = s * p / 100 / 1000
  t = s / 1000
  printf "%s\t%s\n",
    (u >= 1000 ? sprintf("%.0fM", u/1000) : sprintf("%.0fk", u)),
    (t >= 1000 ? sprintf("%.0fM", t/1000) : sprintf("%.0fk", t))
}')
EOF
  if   [ "$used_int" -ge 80 ]; then tokens=$(printf "\033[0;31m%s\033[0m\033[0;90m/%s\033[0m" "$tok_k" "$ctx_k")
  elif [ "$used_int" -ge 50 ]; then tokens=$(printf "\033[0;33m%s\033[0m\033[0;90m/%s\033[0m" "$tok_k" "$ctx_k")
  else                              tokens=$(printf "\033[0;32m%s\033[0m\033[0;90m/%s\033[0m" "$tok_k" "$ctx_k")
  fi
  ctx_bar=$(render_bar "cntx" "$used_int")
  printf "%s%s  %s\n" "$p6" "$ctx_bar" "$tokens"

  now=$(date +%s)

  # line 4: sess
  if [ -n "$session_pct" ]; then
    s_int=$(round "$session_pct")
    sess_bar=$(render_bar "sess" "$s_int")
    if [ -n "$session_reset" ]; then
      printf "%s%s  \033[0;90m%s\033[0m\n" "$p6" "$sess_bar" "$(fmt_eta_hm $(( session_reset - now )))"
    else
      printf "%s%s\n" "$p6" "$sess_bar"
    fi
  fi

  # line 5: week
  if [ -n "$weekly_pct" ]; then
    w_int=$(round "$weekly_pct")
    week_bar=$(render_bar "week" "$w_int")
    if [ -n "$weekly_reset" ]; then
      printf "%s%s  \033[0;90m%s\033[0m\n" "$p6" "$week_bar" "$(fmt_eta_dhm $(( weekly_reset - now )))"
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

    # Time until first of next month (UTC midnight = billing reset)
    next_month=$(TZ=UTC date -v+1m -v1d -v0H -v0M -v0S +%s 2>/dev/null)
    eta_str=""
    [ -n "$next_month" ] && eta_str=$(fmt_eta_dhm $(( next_month - now )))

    if [ -n "$spend_pct" ] && [ -n "$spend_used" ]; then
      usage_bar=$(render_bar "used" "$spend_pct")
      if [ -n "$eta_str" ]; then
        printf "%s%s  \033[0;36m\$%s\033[0;90m/\$%s\033[0m  \033[0;90m%s\033[0m\n" \
          "$p6" "$usage_bar" "$spend_used" "$spend_limit" "$eta_str"
      else
        printf "%s%s  \033[0;36m\$%s\033[0;90m/\$%s\033[0m\n" \
          "$p6" "$usage_bar" "$spend_used" "$spend_limit"
      fi
    elif [ -n "$eta_str" ]; then
      printf "%s\033[0;90musage:\033[0m  \033[0;90m%s\033[0m\n" "$p6" "$eta_str"
    fi
  fi
fi

exit 0
