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

- The `sess` / `week` lines are drawn only when `rate_limits` is present (Pro/Max subscriptions). Enterprise/Team payloads have none, so a `usage:` line with the time until the 1st of the month (00:00 UTC) is shown instead. If `~/.claude/usage-cache.json` exists (written by an optional `~/.claude/usage-fetch.js`, which is not in this repo), a `used:` bar with the monthly spend is shown.

Agent panel details:

- Fields from `jq` are separated by `\037`, not a tab. `read` collapses consecutive tabs, so empty fields (for example, a missing `model`) shift.
- The payload has no cost. `jq` computes it from `usage` in the agent transcript (`<session>/subagents/agent-<id>.jsonl`), deduplicated by `message.id`. The price table (`def price`) is hardcoded from https://platform.claude.com/docs/en/about-claude/pricing. Update it when new models ship or prices change.
- Token colors follow the `cntx` line: green below 50%, yellow from 50%, red from 80% of the agent's `contextWindowSize`.
- Background shells are not part of the payload, so they cannot be shown as rows.
- Payload fields (observed October 2026): `tasks[]` with `id`, `type`, `status`, `description`, `label`, `startTime`, `model`, `contextWindowSize`, `tokenCount`, `tokenSamples`, `cwd`; top level has `transcript_path`, `columns`, `session_id`. Older versions may omit `model`, in which case the model is read from the agent transcript. When only a background shell is running, the script is not called at all.
- The maximum number of rows the panel shows is undocumented.

## Colors

Keep them consistent with the main status line:

- model - `\033[0;35m` (magenta);
- cost - `\033[0;36m` (cyan);
- labels and secondary text (`cntx:`, `tok`) - `\033[0;90m` (gray).

## Installation

The repo is public: `install.sh` downloads raw files from `raw.githubusercontent.com` without a token. When run from a clone (`scripts/statusline.sh` is next to it), files are copied locally without network access. Before overwriting, `.bak` copies are made for both scripts and `settings.json`. Add any new installable file to `FILES` in `install.sh` (files are taken from `scripts/`).

`install.sh` stays in the repo root and the scripts stay in `scripts/`: the public command `curl -fsSL .../main/install.sh | sh` and the raw paths `scripts/<file>` are already in use on other machines, so renaming or moving them breaks installation.

## Verifying changes

Minimal smoke test for both scripts:

```sh
echo '{"cwd":"/tmp","model":{"display_name":"Opus"}}' | bash scripts/statusline.sh
echo '{"transcript_path":"/nonexistent.jsonl","tasks":[{"id":"x","status":"running","label":"test","tokenCount":7981,"model":"claude-sonnet-5-5","contextWindowSize":1000000}]}' | bash scripts/subagent-statusline.sh
```

After changes in the repo, update the installed copy: `sh install.sh`.

To check the panel live, run several background test agents (general-purpose). The harness blocks a standalone foreground `sleep`, so use `ping -c N 127.0.0.1 > /dev/null` for pauses. Explore and Plan agents are read-only and refuse commands with redirects.
