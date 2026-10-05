# claude-statusline

Custom status line for [Claude Code](https://code.claude.com): `scripts/statusline.sh` renders the main status line, `scripts/subagent-statusline.sh` renders the per-agent rows in the agent panel.

```
➜  my-project git:(main) ✗  Opus 5.5 medium
      thinking:on  skills: ~3,100 tokens (~0.3%)
      cntx:░░░░░░░░░░ 4%  40,213 tok /1M
      sess:░░░░░░░░░░ 9%  Mon 19:00  0h 53m  $0.88
      week:████░░░░░░ 45%  Tue 21:10  1d 3h 3m

↳ Sonnet 5.5 high  6,512 tok  $0.02  Running ping in foreground
↳ Haiku 4.5  12,104 tok  $0.01  explorer
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ihororlovskyi/claude-statusline/main/install.sh | sh
```

From a local clone:

```sh
sh install.sh
```

The installer:

- copies `scripts/statusline.sh` and `scripts/subagent-statusline.sh` to `~/.claude/` (an existing different file is saved with a `.bak` suffix);
- sets `statusLine` and `subagentStatusLine` in `~/.claude/settings.json` (previous file saved as `settings.json.bak`):

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline.sh"
},
"subagentStatusLine": {
  "type": "command",
  "command": "bash ~/.claude/subagent-statusline.sh"
}
```

Restart Claude Code afterwards. `CLAUDE_CONFIG_DIR` is respected.

Requirements: `jq`, `curl`, `awk` (macOS defaults are fine).

## What it shows

**Main status line**

- directory, git branch with dirty marker, model and effort level (omitted for models without effort);
- thinking mode (`thinking:on` / `off`, `no` when unknown);
- next to it, an estimate of the context taken by the skill listing (`skills: ~3,100 tokens (~0.3%)`, share of the context window): `name` + `description` from `SKILL.md` frontmatter in the project `.claude/skills/` and `~/.claude/skills/`, about 3 characters per token; plugin skills and skills with `disable-model-invocation: true` are not counted;
- context window usage bar with tokens used / window size;
- 5-hour session and 7-day weekly rate limit bars with the reset moment in local time and time to reset; the session cost sits on the `sess` line (on the `cntx` line when there are no rate limits);

Bars turn yellow at 50% and red at 80%. Token counts turn yellow at 100,000 and red at 150,000 tokens.

**Enterprise / Team accounts**

Usage-based plans have no 5-hour and 7-day limits, so Claude Code sends no `rate_limits` and the `sess` / `week` bars are not shown. Instead the last line shows how much of the billing month has passed and the time left until the reset (1st of the month, 00:00 UTC):

```
➜  my-project git:(main) ✗  Opus 5.5 medium
      thinking:on  skills: ~3,100 tokens (~0.3%)
      cntx:░░░░░░░░░░ 4%  40,213 tok /1M  $0.88
      rest:█░░░░░░░░░ 12%  27d 4h 24m
```

The session cost on the `cntx` line is still an API-price estimate from Claude Code, not your contract price.

If `~/.claude/usage-cache.json` exists (written by an optional `~/.claude/usage-fetch.js`, not part of this repo, refreshed in the background every 5 minutes), a monthly spend bar is added above `rest`:

```
      used:████░░░░░░ 42%  $210.00/$500
      rest:█░░░░░░░░░ 12%  27d 4h 24m
```

Expected cache shape: `{"timestamp": <ms>, "data": {"spend": {"used": {"amount_minor", "exponent"}, "limit": {"amount_minor", "exponent"}, "percent"}}}`. A cache older than 24 hours is ignored.

**Agent panel** (`subagentStatusLine`, `scripts/subagent-statusline.sh`)

One row per running agent: model, effort level, tokens used, estimated cost, current activity. Finished agents are hidden.

- Effort is the level the agent actually runs with, read from its transcript: the `effort` in the agent's `.claude/agents/*.md` frontmatter, otherwise the session's. Asking for an effort in the prompt text does not change it. Models without effort (Haiku) show none.

- Tokens use the same color thresholds as the `cntx` token count: yellow at 100,000, red at 150,000.
- Cost is not part of the Claude Code payload, so it is estimated from the agent transcript's `usage` and public [API pricing](https://platform.claude.com/docs/en/about-claude/pricing), including cache writes/reads, fast mode, and US-only inference. Update the price table in `scripts/subagent-statusline.sh` when pricing changes.

Background shells are not passed to `subagentStatusLine`, so they cannot be shown as rows.

## Skills

[scripts/skills.sh](scripts/skills.sh)

```bash
sh scripts/skills.sh
```

Have fun! ;)
