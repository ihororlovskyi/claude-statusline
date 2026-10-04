#!/bin/sh
input=$(cat)

# subagentStatusLine mode: payload carries tasks[], emit one JSON row per task
if echo "$input" | jq -e 'has("tasks")' > /dev/null 2>&1; then
  transcript=$(echo "$input" | jq -r '.transcript_path // ""')
  subagents_dir="${transcript%.jsonl}/subagents"
  echo "$input" | jq -r '.tasks[] | [.id, (.status // ""), (.label // .description // ""), ((.tokenCount // 0) | tostring), (.model // ""), ((.contextWindowSize // 0) | tostring)] | join("\u001f")' |
  # \037 instead of tab: read collapses consecutive tabs, shifting empty fields
  while IFS="$(printf '\037')" read -r id status label tok raw ctx; do
    [ -z "$id" ] && continue
    # empty content hides finished/idle rows
    if [ "$status" != "running" ]; then
      jq -cn --arg id "$id" '{id:$id, content:""}'
      continue
    fi
    agent_file="$subagents_dir/agent-$id.jsonl"
    # older payloads have no model field; fall back to the agent transcript
    if [ -z "$raw" ] && [ -f "$agent_file" ]; then
      raw=$(grep -oE '"model":"claude[^"]*"' "$agent_file" 2>/dev/null | tail -1 | sed -E 's/.*"model":"//; s/"$//')
    fi
    # claude-opus-4-8 -> Opus 4.8, claude-haiku-4-5-20251001 -> Haiku 4.5
    model_name=$(echo "${raw#claude-}" | sed -nE 's/^(opus|sonnet|haiku|fable|mythos)-([0-9]+)(-([0-9]{1,2}))?([^0-9].*)?$/\1 \2.\4/p' | sed -E 's/\.$//' | awk '{ print toupper(substr($0,1,1)) substr($0,2) }')

    # payload has no cost; price the transcript usage (USD per MTok: input, 5m write, 1h write, cache read, output)
    cost=0
    if [ -f "$agent_file" ]; then
      cost=$(jq -rs '
        def price:
          sub("^claude-"; "") as $m
          | if   $m | test("^(fable|mythos)-5-1") then [10, 12.5, 20, 0.25, 50]
            elif $m | test("^(fable|mythos)-5")   then [10, 12.5, 20, 1, 50]
            elif $m | test("^opus-5-5")           then [4, 5, 8, 0.2, 20]
            elif $m | test("^opus-4(-1)?(-[0-9]{8})?$") then [15, 18.75, 30, 1.5, 75]
            elif $m | test("^opus-")              then [5, 6.25, 10, 0.5, 25]
            elif $m | test("^sonnet-5")           then [2, 2.5, 4, 0.2, 10]
            elif $m | test("^sonnet-")            then [3, 3.75, 6, 0.3, 15]
            elif $m | test("^haiku-4-5")          then [1, 1.25, 2, 0.1, 5]
            else [0, 0, 0, 0, 0] end;
        [.[] | select(.type == "assistant") | .message | select(.usage)]
        | unique_by(.id)
        | map(
            (.model | price) as $p
            | .usage as $u
            | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1h
            | (($u.cache_creation_input_tokens // 0) - $w1h) as $w5m
            | (if $u.speed == "fast" then 2 else 1 end) * (if $u.inference_geo == "us" then 1.1 else 1 end) as $mult
            | (($u.input_tokens // 0) * $p[0] + $w5m * $p[1] + $w1h * $p[2]
               + ($u.cache_read_input_tokens // 0) * $p[3] + ($u.output_tokens // 0) * $p[4]) * $mult / 1000000)
        | add // 0' "$agent_file" 2>/dev/null)
    fi

    # tokens: same thresholds and colors as the main cntx line
    tok_str=$(LC_NUMERIC=C awk -v n="$tok" -v c="$ctx" 'BEGIN {
      pct = (c > 0 ? n * 100 / c : 0)
      col = (pct >= 80 ? "31" : (pct >= 50 ? "33" : "32"))
      printf "\033[0;%sm%d\033[0m \033[0;90mtok\033[0m", col, n
    }')
    cost_str=$(LC_NUMERIC=C awk -v c="${cost:-0}" 'BEGIN { printf "\033[0;36m$%.2f\033[0m", c }')

    content="↳"
    [ -n "$model_name" ] && content="$content $(printf '\033[0;35m%s\033[0m' "$model_name")"
    content="$content  $tok_str  $cost_str  $label"
    jq -cn --arg id "$id" --arg content "$content" '{id:$id, content:$content}'
  done
  exit 0
fi

# parse all fields from stdin in one jq call via eval+@sh
eval "$(echo "$input" | jq -r '
  "cwd="          + (.cwd | @sh),
  "model="        + ((.model.display_name // "") | @sh),
  "used="         + ((.context_window.used_percentage // "") | tostring | @sh),
  "ctx_size="     + ((.context_window.context_window_size // "") | tostring | @sh),
  "effort_val="   + ((.effort.level // "") | @sh),
  "thinking_in="  + ((.thinking.enabled // "") | tostring | @sh),
  "cost_usd="     + ((.cost.total_cost_usd // "") | tostring | @sh),
  "session_pct="  + ((.rate_limits.five_hour.used_percentage // "") | tostring | @sh),
  "session_reset="+ ((.rate_limits.five_hour.resets_at // "") | tostring | @sh),
  "weekly_pct="   + ((.rate_limits.seven_day.used_percentage // "") | tostring | @sh),
  "weekly_reset=" + ((.rate_limits.seven_day.resets_at // "") | tostring | @sh)
')"

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
if [ "$thinking_in" = "true" ]; then
  thinking_label="thinking:on"
elif [ -z "$thinking_in" ] || [ -z "$effort_val" ]; then
  settings_file="$HOME/.claude/settings.json"
  if [ -f "$settings_file" ]; then
    eval "$(jq -r '
      "thinking_fallback=" + ((.alwaysThinkingEnabled // false) | tostring | @sh),
      "effort_fallback="   + (.effortLevel // "" | @sh)
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
  cost_fmt=$(LC_NUMERIC=C awk "BEGIN { printf \"\$%.2f\", $cost_usd }")
  cost_line1=$(printf "  \033[0;36m%s\033[0m" "$cost_fmt")
fi

model_str=""
[ -n "$model" ] && model_str=$(printf "  \033[0;35m%s\033[0m" "$model")
printf "\033[1;32m➜\033[0m  \033[0;36m%s\033[0m%s%s%s\n" "$dir" "$git_info" "$model_str" "$cost_line1"

if [ -n "$model" ] && [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")

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
$(LC_NUMERIC=C awk "BEGIN {
  u = $ctx_size * $used / 100 / 1000
  t = $ctx_size / 1000
  printf \"%s\t%s\n\",
    (u >= 1000 ? sprintf(\"%.0fM\", u/1000) : sprintf(\"%.0fk\", u)),
    (t >= 1000 ? sprintf(\"%.0fM\", t/1000) : sprintf(\"%.0fk\", t))
}")
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
    s_int=$(printf "%.0f" "$session_pct")
    sess_bar=$(render_bar "sess" "$s_int")
    if [ -n "$session_reset" ]; then
      printf "%s%s  \033[0;90m%s\033[0m\n" "$p6" "$sess_bar" "$(fmt_eta_hm $(( session_reset - now )))"
    else
      printf "%s%s\n" "$p6" "$sess_bar"
    fi
  fi

  # line 5: week
  if [ -n "$weekly_pct" ]; then
    w_int=$(printf "%.0f" "$weekly_pct")
    week_bar=$(render_bar "week" "$w_int")
    if [ -n "$weekly_reset" ]; then
      printf "%s%s  \033[0;90m%s\033[0m\n" "$p6" "$week_bar" "$(fmt_eta_dhm $(( weekly_reset - now )))"
    else
      printf "%s%s\n" "$p6" "$week_bar"
    fi
  fi

  # Enterprise: no sess/week limits → show real usage from claude.ai API
  if [ -z "$session_pct" ] && [ -z "$weekly_pct" ]; then
    cache_file="$HOME/.claude/usage-cache.json"
    fetch_script="$HOME/.claude/usage-fetch.js"

    # Refresh cache if absent or >5 min stale (background, non-blocking)
    cache_age=999999
    if [ -f "$cache_file" ]; then
      cache_ts=$(jq -r '.timestamp // 0' "$cache_file" 2>/dev/null)
      [ -n "$cache_ts" ] && cache_age=$(( now - cache_ts / 1000 ))
    fi
    [ "$cache_age" -gt 300 ] && [ -f "$fetch_script" ] && node "$fetch_script" &>/dev/null &

    # Parse cache via jq+awk
    spend_used="" spend_limit="" spend_pct=""
    if [ -f "$cache_file" ] && [ "$cache_age" -lt 86400 ]; then
      read -r spend_used spend_limit spend_pct <<EOF
$(jq -r '[.data.spend.used.amount_minor // 0, .data.spend.used.exponent // 2, .data.spend.limit.amount_minor // 0, .data.spend.limit.exponent // 2, .data.spend.percent // 0] | @tsv' "$cache_file" 2>/dev/null | LC_NUMERIC=C awk -F'\t' '{
  used_m=$1+0; used_e=$2+0; lim_m=$3+0; lim_e=$4+0; pct=$5+0
  if (used_e==0) used_e=2; if (lim_e==0) lim_e=2
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
