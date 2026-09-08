---
name: status
description: Show the handoff plugin's state for this project: staged handoff, per-session files, recent hook log, effective config.
allowed-tools: Bash(cat *), Bash(ls *), Bash(tail *)
---

Effective config (HANDOFF_* env → plugin userConfig → default): THRESHOLD=!`echo "${HANDOFF_THRESHOLD:-${CLAUDE_PLUGIN_OPTION_THRESHOLD:-300000}}"` LIVE_FROM=!`echo "${HANDOFF_LIVE_FROM:-${CLAUDE_PLUGIN_OPTION_LIVE_FROM:-0}}"` LIVE_EVERY=!`echo "${HANDOFF_LIVE_EVERY:-${CLAUDE_PLUGIN_OPTION_LIVE_EVERY:-20000}}"` MODE=!`echo "${HANDOFF_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-inject}}"`

Handoff dir: !`ls -la "${CLAUDE_PROJECT_DIR}/.claude/handoff" "${CLAUDE_PROJECT_DIR}/.claude/handoff/sessions" "${CLAUDE_PROJECT_DIR}/.claude/handoff/by-pid" 2>&1`

Owner of current.md: !`cat "${CLAUDE_PROJECT_DIR}/.claude/handoff/current.owner" 2>/dev/null || echo none` (this Claude pid: !`ps -o ppid= -p $PPID | tr -d ' '`)

Last hook log lines:
!`tail -n 15 "${CLAUDE_PROJECT_DIR}/.claude/handoff/hooks.log" 2>/dev/null || echo "(no log yet)"`

Summarize the above for the user in a few lines: is a handoff staged, whose is it, when was it written, what is the threshold, and whether live state is on.
