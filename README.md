# claude-statusline

Custom status line for [Claude Code](https://code.claude.com): `scripts/statusline.sh` renders the main status line, `scripts/subagent-statusline.sh` renders the per-agent rows in the agent panel.

```
➜  my-project git:(main) ✗ · PR #11 · Opus 5.5 medium
↳  acme/skills git:(dev) ✗ · PR #109
      thnk:on  skll: ~3,100 tok ~0.3%  13 prompts  8·4·1
      cntx:░░░░░░░░░░ 4%  40,213 tok /1M  +777 tok
      sess:░░░░░░░░░░ 9%  Mon 19:00  0h 53m  $0.88  +$0.12
      week:████░░░░░░ 45%  Tue 21:10  1d 3h 3m  1h 13m  +5m 32s
      session started 09:40  going 3h 12m  +24m 10s

↳ rc-verifier  Opus 5.5 low  6,512 tok  $0.05  Running ping in foreground
↳ Explore  Haiku 5.5  12,104 tok  $0.01  explorer
```

## Install

```sh
curl -fsSL https://github.com/ihororlovskyi/claude-statusline/releases/latest/download/install.sh | sh
```

This installs the latest release.

From a local clone:

```sh
git clone https://github.com/ihororlovskyi/claude-statusline.git your-dir-name
cd your-dir-name
sh install.sh
# or, without cd
sh your-dir-name/install.sh
```

The installer:

- copies `scripts/statusline.sh` and `scripts/subagent-statusline.sh` to `~/.claude/` (an existing different file is saved with a `.bak` suffix);
- sets `statusLine` and `subagentStatusLine` in `~/.claude/settings.json` (previous file saved as `settings.json.bak` when it changes, so a rerun keeps the original; an invalid file stops the installer before anything is written):

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline.sh",
  "refreshInterval": 60
},
"subagentStatusLine": {
  "type": "command",
  "command": "bash ~/.claude/subagent-statusline.sh"
}
```

- turns off the PR badge in the prompt footer, as the status line shows the PR itself: sets `"prStatusFooterEnabled": false` in `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` when it is set; previous file saved as `.claude.json.bak`, other keys are kept). A missing file is not created, the installer only warns. To bring the badge back, turn on **Show PR status footer** in `/config`.

The last line names what was installed: the release tag (`done - claude-statusline v0.0.11 installed, ...`), or for a clone `git describe` of it (`v0.0.11-2-gabc1234-dirty`).

Restart Claude Code afterwards. `CLAUDE_CONFIG_DIR` is respected.

Requirements: `jq`, `curl`, `awk` (macOS defaults are fine); `gh` (logged in) for PR numbers of repos other than the current one.

## What it shows

**Main status line**

- directory (the repo root inside a git repo, so a `cd` into a subfolder keeps the repo name; a worktree shows its own folder), git branch with dirty marker, the pull request of the branch (`· PR #11`; `MR` for a GitLab merge request), then model and effort level (omitted for models without effort);
- one `↳` line per other git repo the session edited (`Edit`, `Write` and `NotebookEdit` calls of the session and its agents, and from shell commands `git -C <dir>` with a writing subcommand (`commit`, `add`, `push`, `checkout`, ...); a command is taken part by part (split at `;`, `&&`, `||`, `|` and new lines, a heredoc staying with its part): a part that writes (`sed -i`, `mv`, `python`, ...) adds every literal `/` or `~/` path in it, heredoc included, and in the script it runs (`python3 <file>`), but not the script itself, a part that only redirects adds the redirect target, and a command with such a part adds `cd <dir>`; a path in a shell variable, as in a loop, or built in code is not seen, and a repo the writing part only reads still counts): `owner/repo` of its GitHub `origin` (the owner is dropped when it matches the current repo's, the folder name without a GitHub remote), branch (a short hash on a detached HEAD), dirty marker and PR. A path through a symlink counts as the repo it points to;
- `PR` is gray and the number shows the state, as in the footer badge: yellow waiting for review, green approved, red changes requested, gray `draft` and `closed`, magenta `merged`. The current repo's PR comes from Claude Code (the same data as the footer badge); otherwise, and for the other repos, from `gh pr list`, run in the background at most every 5 minutes per branch with the first logged-in `gh` account that can read the repo (`GH_ACC` from the repo's `.env/.env` first, then the active account), so a new PR shows up on a later render;
- thinking mode (`thnk:on` / `off`, `no` when unknown);
- next to it, an estimate of the context taken by the skill listing (`skll: ~3,100 tok ~0.3%`, share of the context window): `name` + `description` from `SKILL.md` frontmatter in the project `.claude/skills/` and `~/.claude/skills/`, about 3 characters per token; plugin skills and skills with `disable-model-invocation: true` are not counted;
- context window usage bar with tokens used / window size, then how much the context has grown since the current prompt started (`+777 tok`, same color as the token count; hidden when it has not grown, on the first render of a session and when the payload has no `session_id`). The prompt boundary comes from the session transcript; per-session state lives in `~/.claude/statusline-state/` and files idle for 7 days are removed;
- at the end of the same line, the number of prompts in the session (`13 prompts`), and after a compaction the prompts before each one and since the last (`8·4·1`: 8 prompts, compacted, 4 more, compacted, 1 since; the total and the count since the last compaction are white, a `0` right after a compaction stays gray). Counted from user entries in the session transcript: tool results, slash-command and `!` shell entries, agent notifications and `/compact` itself are not prompts, so a prompt that starts with `<` or `/compact` is not counted either. After `/rewind` only the prompts of the active branch count (`0 prompts` when it went back to the start), and the agent time below drops the turns of the dropped branch too;
- 5-hour session and 7-day weekly rate limit bars with the reset moment in local time and time to reset; the session cost sits on the `sess` line (with no rate limits, on the `used` line, or on the `cntx` line when there is no `used` line), followed by the cost of the current prompt so far (`+$0.12`, from the same per-session state as `+777 tok`; hidden below one cent and on the first prompt of a session, where it would repeat the session cost);
- at the end of the last line (`week`, on Enterprise/Team `rest`): the time the agent has worked in the session in white (the `turn_duration` entries Claude Code writes when a turn ends, plus a turn still running), then `+` the time of the current or last prompt in gray (`1h 13m  +5m 32s`);
- the last line: when the session started in local time (its first transcript entry; with the day name once it is a day old), how long it has been going, and `+` the time between the last two prompts (`session started 09:40  going 3h 12m  +24m 10s`; after `/rewind`, of the active branch). The installer sets `refreshInterval: 60` (a value already set is kept), so the times move while the session is idle;

Bars turn yellow at 50% and red at 80%. Token counts turn yellow at 100,000 and red at 150,000 tokens.

**Enterprise / Team accounts**

Usage-based plans have no 5-hour and 7-day limits, so Claude Code sends no `rate_limits` and the `sess` / `week` bars are not shown. Instead the last line shows how much of the billing month has passed and the time left until the reset (1st of the month, 00:00 UTC):

```
➜  my-project git:(main) ✗  Opus 5.5 medium
      thnk:on  skll: ~3,100 tok ~0.3%  13 prompts  8·4·1
      cntx:░░░░░░░░░░ 4%  40,213 tok /1M  +777 tok  $0.88  +$0.12
      rest:█░░░░░░░░░ 12%  27d 4h 24m  1h 13m  +5m 32s
      session started 09:40  going 3h 12m  +24m 10s
```

The session cost (on the `used` line when it is shown, else on the `cntx` line) is still an API-price estimate from Claude Code, not your contract price.

If `~/.claude/usage-cache.json` exists (written by an optional `~/.claude/usage-fetch.js`, not part of this repo, refreshed in the background every 5 minutes), a monthly spend bar is added above `rest`:

```
      cntx:░░░░░░░░░░ 4%  40,213 tok /1M  +777 tok
      used:████░░░░░░ 42%  $210.00/$500  $0.88  +$0.12
      rest:█░░░░░░░░░ 12%  27d 4h 24m  1h 13m  +5m 32s
      session started 09:40  going 3h 12m  +24m 10s
```

Expected cache shape: `{"timestamp": <ms>, "data": {"spend": {"used": {"amount_minor", "exponent"}, "limit": {"amount_minor", "exponent"}, "percent"}}}`. A cache older than 24 hours is ignored.

**Agent panel** (`subagentStatusLine`, `scripts/subagent-statusline.sh`)

One row per running agent: agent type, model, effort level, tokens used, estimated cost, current activity. Finished agents are hidden.

- The agent type (`rc-verifier`, `Explore`) comes from the `agent-<id>.meta.json` Claude Code writes next to the agent transcript (`general-purpose` and `fork` too); without the file the row starts with the model.

- Effort is the level the agent actually runs with, read from its transcript: the `effort` in the agent's `.claude/agents/*.md` frontmatter, otherwise the session's. Asking for an effort in the prompt text does not change it. Models without effort (Haiku) show none.

- Tokens use the same color thresholds as the `cntx` token count: yellow at 100,000, red at 150,000.
- Cost is not part of the Claude Code payload, so it is estimated from the agent transcript's `usage` and public [API pricing](https://platform.claude.com/docs/en/about-claude/pricing), including cache writes/reads, fast mode, and US-only inference. Update the price table in `scripts/subagent-statusline.sh` when pricing changes.

Background shells are not passed to `subagentStatusLine`, so they cannot be shown as rows.

Have fun! ;)
