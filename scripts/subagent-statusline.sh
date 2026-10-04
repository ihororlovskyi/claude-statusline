#!/bin/sh
# subagentStatusLine: payload carries tasks[], emit one JSON row per task
input=$(cat)

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
