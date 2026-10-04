# claude-statusline

Custom status line for [Claude Code](https://code.claude.com): one script that renders both the main status line and the per-agent rows in the agent panel.

```
➜  my-project git:(main) ✗  Opus 5.5  $0.88
      thinking:on  effort:medium
      cntx:░░░░░░░░░░ 4%  40k/1M
      sess:░░░░░░░░░░ 9%  0h 53m
      week:████░░░░░░ 45%  1d 3h 3m

↳ Sonnet 5.5  6512 tok  $0.02  Running ping in foreground
↳ Haiku 4.5  12104 tok  $0.01  explorer
```

## Install

The repo is private, so the raw files need a GitHub token. With the [GitHub CLI](https://cli.github.com) logged in:

```sh
curl -fsSL -H "Authorization: token $(gh auth token)" \
  https://raw.githubusercontent.com/ihororlovskyi/claude-statusline/main/install.sh | sh
```

Without `gh`, export `GITHUB_TOKEN` (a token with read access to the repo) and use it in the header instead.

From a local clone:

```sh
sh install.sh
```

The installer:

- copies `statusline.sh` to `~/.claude/statusline.sh` (an existing different file is saved as `statusline.sh.bak`);
- sets `statusLine` and `subagentStatusLine` in `~/.claude/settings.json` (previous file saved as `settings.json.bak`):

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline.sh"
},
"subagentStatusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline.sh"
}
```

Restart Claude Code afterwards. `CLAUDE_CONFIG_DIR` is respected.

Requirements: `jq`, `curl`, `awk` (macOS defaults are fine).

## What it shows

**Main status line**

- directory, git branch with dirty marker, model, session cost;
- thinking and effort level;
- context window usage bar with tokens used / window size;
- 5-hour session and 7-day weekly rate limit bars with time to reset.

Bars and token counts turn yellow at 50% and red at 80%.

**Agent panel** (`subagentStatusLine`)

One row per running agent: model, tokens used, estimated cost, current activity. Finished agents are hidden.

- Tokens use the same color thresholds as the context bar, relative to the agent's own context window.
- Cost is not part of the Claude Code payload, so it is estimated from the agent transcript's `usage` and public [API pricing](https://platform.claude.com/docs/en/about-claude/pricing), including cache writes/reads, fast mode, and US-only inference. Update the price table in `statusline.sh` when pricing changes.

Background shells are not passed to `subagentStatusLine`, so they cannot be shown as rows.
