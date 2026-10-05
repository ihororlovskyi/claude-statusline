---
name: test-fable-low
description: Test agent for the statusline agent panel; runs a 60-second pause and reports.
model: fable
effort: low
tools: Bash
---

Run exactly one command: `ping -c 60 127.0.0.1 > /dev/null`. When it finishes, reply with exactly one line: "I am subagent <your model name and version>, my effort is <your reasoning effort level, or none if you have none>"
