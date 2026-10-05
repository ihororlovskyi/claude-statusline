# claude-statusline

Custom status line for Claude Code: `scripts/statusline.sh` renders the main status line (`statusLine`), `scripts/subagent-statusline.sh` renders the agent panel rows (`subagentStatusLine`).

## Files

| File | What it is |
|---|---|
| `scripts/statusline.sh` | Main status line. `jq` + `awk`; has a `#!/bin/sh` shebang but relies on bash (`&>`) and BSD `date -v` (macOS), so always run it via `bash` |
| `scripts/subagent-statusline.sh` | Agent panel rows, same dependencies |
| `install.sh` | Installer: puts both scripts into `~/.claude/` and sets both keys in `settings.json` via `jq` |
| `README.md` | User-facing documentation |

## How it works

- `scripts/statusline.sh` receives the main status line payload and prints several lines with ANSI colors.
- `scripts/subagent-statusline.sh` receives a payload with `tasks[]` and prints one JSON line `{"id": ..., "content": ...}` per task. For tasks that are not `running`, `content` is empty and the row is hidden.

Main status line details:

- The `sess` / `week` lines are drawn only when `rate_limits` is present (Pro/Max subscriptions). Enterprise/Team payloads have none, so a `rest:` bar is shown instead: the elapsed share of the billing month and the time until the 1st (00:00 UTC). If `~/.claude/usage-cache.json` exists (written by an optional `~/.claude/usage-fetch.js`, which is not in this repo), a `used:` bar with the monthly spend is shown above it.
- Payload fields used (observed October 2026): `model.display_name`, `workspace.project_dir`, `effort.level` (absent for models without effort, e.g. Haiku), `thinking.enabled`, `cost.total_cost_usd`, `context_window` with `context_window_size`, `used_percentage`, `current_usage{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`, `rate_limits.five_hour` / `seven_day` with `used_percentage`, `resets_at`.
- Effort is read from the payload only: a `settings.json` fallback would show an effort level for models that have none (they show no effort at all). `thinking.enabled` is always sent (Opus and Haiku, on and off); the fallback to `alwaysThinkingEnabled` is for older versions. `/config` writes `false` when thinking is turned off and removes the key when it is turned on, so a missing key means on; without `settings.json`, `thinking:no`.
- The `skills:` line is an estimate: the payload has no per-category breakdown like `/context`. It sums `name` + `description` from `SKILL.md` frontmatter in `workspace.project_dir` (fallback `cwd`) `/.claude/skills/*/` and `$CLAUDE_CONFIG_DIR/skills/*/`, divided by 3 (within ~10% of `/context` in October 2026), rounded to 100, plus its share of `context_window_size`. It shares line 2 with `thinking:`. Skills with `disable-model-invocation: true` are skipped, plugin skills are not counted.
- Context tokens = input + cache_creation + cache_read from `current_usage` (output is not part of the context); without it, `size * used_percentage / 100`.
- Right after `/compact` the payload sends zeros in `current_usage` and `used_percentage` until the next API response, so `cntx` briefly shows `0%` / `0 tok`; this is expected.

Agent panel details:

- Fields from `jq` are separated by `\037`, not a tab. `read` collapses consecutive tabs, so empty fields (for example, a missing `model`) shift.
- The payload has no cost. `jq` computes it from `usage` in the agent transcript (`<session>/subagents/agent-<id>.jsonl`), deduplicated by `message.id`. The price table (`def price`) is hardcoded from https://platform.claude.com/docs/en/about-claude/pricing. Update it when new models ship or prices change.
- The payload has no effort either. The top-level `effort` of the last `type: "assistant"` entry in the agent transcript is the effective level, read with `jq`: a plain `grep` would also match an `effort` key nested in tool input. Until the first assistant turn is written, no effort is shown. Verified October 2026 with the test agents in `.claude/agents/`:
  - the level comes from `effort:` in the agent's frontmatter, otherwise from the session; Haiku has none. The Agent tool has no effort parameter, so a different level needs a frontmatter edit (and a restart);
  - effort requested in the prompt text changes nothing in the transcript, and Haiku may refuse such a prompt as an injection;
  - an agent does not know its own effort: asked to report it, it echoes the prompt or guesses, so never trust a self-report;
  - edits to `.claude/agents/*.md` (including new files) take effect only after restarting Claude Code.
- Token colors: see thresholds in Colors.
- Background shells are not part of the payload, so they cannot be shown as rows.
- Payload fields (observed October 2026): `tasks[]` with `id`, `type`, `status`, `description`, `label`, `startTime`, `model`, `contextWindowSize`, `tokenCount`, `tokenSamples`, `cwd`; top level has `transcript_path`, `columns`, `session_id`. Older versions may omit `model`, in which case the model is read from the agent transcript. When only a background shell is running, the script is not called at all.
- The maximum number of rows the panel shows is undocumented.

## Colors

Keep them consistent with the main status line:

- model and effort level - `\033[0;35m` (magenta);
- cost and `thinking:on` - `\033[0;36m` (cyan);
- labels and secondary text (`cntx:`, `tok`, `thinking:off`, `skills:`) - `\033[0;38;2;153;153;153m` (gray rgb(153,153,153), measured from the Claude Code hint "(shift+tab to cycle)" in the dark theme);
- thresholds: token counts (main `cntx` and agent rows) are green below 100,000, yellow from 100,000, red from 150,000 tokens; bars (`cntx`, `sess`, `week`, `used`, `rest`) are yellow from 50%, red from 80%.

## Installation

The repo is public: `install.sh` downloads raw files from `raw.githubusercontent.com` without a token. When run from a clone (`scripts/statusline.sh` is next to it), files are copied locally without network access. Before overwriting, `.bak` copies are made for both scripts and `settings.json`. Add any new installable file to `FILES` in `install.sh` (files are taken from `scripts/`).

`install.sh` stays in the repo root and the scripts stay in `scripts/`: the public command `curl -fsSL .../main/install.sh | sh` and the raw paths `scripts/<file>` are already in use on other machines, so renaming or moving them breaks installation.

## Verifying changes

Minimal smoke test for both scripts:

```sh
echo '{"cwd":"/tmp","model":{"display_name":"Opus"}}' | bash scripts/statusline.sh
echo '{"transcript_path":"/nonexistent.jsonl","tasks":[{"id":"x","status":"running","label":"test","tokenCount":7981,"model":"claude-sonnet-5-5","contextWindowSize":1000000}]}' | bash scripts/subagent-statusline.sh
# edge cases: empty current_usage falls back to the percentage; no context data keeps the cost on line 1
echo '{"cwd":"/tmp","model":{"display_name":"Opus"},"context_window":{"used_percentage":14,"context_window_size":200000,"current_usage":{}}}' | bash scripts/statusline.sh
echo '{"cwd":"/tmp","model":{"display_name":"Opus"},"cost":{"total_cost_usd":0.88}}' | bash scripts/statusline.sh
```

After changes in the repo, update the installed copy: `sh install.sh`.

To see a real payload, temporarily add `printf '%s' "$input" > /tmp/statusline-payload.json` after `input=$(cat)` in the installed `~/.claude/statusline.sh`, then restore it with `sh install.sh`.

To check the panel live, run several background test agents: `test-haiku`, `test-sonnet-high`, `test-opus-medium`, `test-fable-low` in `.claude/agents/` (excepted from the `.claude/` ignore) each run a 60-second pause with a fixed model and effort; general-purpose agents work too. The harness blocks a standalone foreground `sleep`, so use `ping -c N 127.0.0.1 > /dev/null` for pauses. Explore and Plan agents are read-only and refuse commands with redirects.
