#!/usr/bin/env sh
set -e

echo "npx -y skills -v" && npx -y skills -v

# SENTIMONY SKILLS
# All at once
# npx skills add sentimony/skills -a codex claude-code -y
# Or each separately
# a "\ " prefix disables a skill on purpose: the leading space makes the name match nothing
npx skills add https://github.com/sentimony/skills -s \
  scope-triage \
  \ scope-check \
  plan-crafting \
  inline-plan-dev \
  subagent-plan-dev \
  git-worktree-isolation \
  parallel-agents \
  tdd \
  cross-review \
  review-request \
  review-resolution \
  debugging \
  web-debug \
  \ webapp-debugger \
  verification-gate \
  branch-finish \
  commit-all \
  gh-switch \
  frontend-crafting \
  vitest \
  typescript \
  echarts \
  prose-crafting \
  dashfix \
  negafix \
  maintaining-agent-context \
  secret-hygiene \
  \ skill-crafting \
  -a codex claude-code -y

echo "npx -y skillio -v" && npx -y skillio -v
echo "npx skillio ls -g" && npx skillio ls -g
echo "npx skillio ls" && npx skillio ls
