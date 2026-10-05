#!/bin/sh
# subagentStatusLine: payload carries tasks[], emit one JSON row per task
input=$(cat)

transcript=$(echo "$input" | jq -r '.transcript_path // ""')
subagents_dir="${transcript%.jsonl}/subagents"
# \037 instead of tab: read collapses consecutive tabs; tojson escapes newlines and \037,
# so one task stays one record
echo "$input" | jq -r '.tasks[] | [.id, (.status // ""), tojson] | join("\u001f")' |
while IFS="$(printf '\037')" read -r id status task; do
  [ -z "$id" ] && continue
  agent_file="$subagents_dir/agent-$id.jsonl"
  # finished rows need no transcript; /dev/null gives an empty entry list
  [ "$status" = "running" ] && [ -f "$agent_file" ] || agent_file=/dev/null
  # one pass over the transcript: model fallback, effort, cost; fromjson? skips a half-written last line
  jq -cnR --argjson t "$task" '
    def paint($c): "\u001b[0;\($c)m\(.)\u001b[0m";
    def commas: if test("^[0-9]{4}") then (.[:-3] | commas) + "," + .[-3:] else . end;
    # USD per MTok: input, 5m write, 1h write, cache read, output
    # (https://platform.claude.com/docs/en/about-claude/pricing)
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
    # empty content hides finished/idle rows
    if $t.status != "running" then {id: $t.id, content: ""} else
    [inputs | fromjson? | objects | select(.type == "assistant")] as $a
    # older payloads have no model field; fall back to the agent transcript
    | (($t.model | strings | select(. != "")) // ([$a[].message.model | strings | select(startswith("claude"))] | last) // "")
    # claude-opus-4-8 -> Opus 4.8, claude-haiku-4-5-20251001 -> Haiku 4.5
    | ((sub("^claude-"; "") | capture("^(?<f>opus|sonnet|haiku|fable|mythos)-(?<a>[0-9]+)(-(?<b>[0-9]{1,2}))?([^0-9].*)?$")
        | (.f[:1] | ascii_upcase) + .f[1:] + " " + .a + (if .b then "." + .b else "" end)) // "") as $name
    # payload has no effort; the transcript records the effective one per turn (agent frontmatter, else the
    # session; prompt text does not change it). Top-level field only: tool input may nest an "effort" key
    | ([$a[].effort | strings] | last // "") as $effort
    # payload has no cost; price the transcript usage, deduplicated by message id
    | (try ([$a[].message | objects | select(.usage)] | unique_by(.id) | map(
        (.model // "" | price) as $p
        | .usage as $u
        | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1h
        | (($u.cache_creation_input_tokens // 0) - $w1h) as $w5m
        | (if $u.speed == "fast" then 2 else 1 end) * (if $u.inference_geo == "us" then 1.1 else 1 end) as $mult
        | (($u.input_tokens // 0) * $p[0] + $w5m * $p[1] + $w1h * $p[2]
           + ($u.cache_read_input_tokens // 0) * $p[3] + ($u.output_tokens // 0) * $p[4]) * $mult / 1000000)
      | add // 0) catch 0 | . * 100 | round) as $cents
    # tokens: same absolute thresholds and colors as the main cntx line
    | (($t.tokenCount | numbers) // 0 | floor) as $tok
    | {id: $t.id, content: (
        "↳"
        + (if $name != "" then " " + ($name | paint(35)) else "" end)
        + (if $effort != "" then " " + ($effort | paint(35)) else "" end)
        + "  " + ($tok | tostring | commas | paint(if $tok >= 150000 then 31 elif $tok >= 100000 then 33 else 32 end))
        + " " + ("tok" | paint(90))
        + "  " + ("$\($cents / 100 | floor).\($cents % 100 | tostring | if length < 2 then "0" + . else . end)" | paint(36))
        + "  " + (($t.label | strings) // ($t.description | strings) // "" | gsub("[\n\r\u001f]"; " ")))}
    end' "$agent_file" 2>/dev/null
done
exit 0
