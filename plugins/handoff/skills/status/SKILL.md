---
name: status
description: Show the handoff plugin's state for this project: staged handoff, per-session files, recent hook log, effective config.
allowed-tools: Bash(cat *), Bash(ls *), Bash(tail *), Bash(bash *)
---

Effective config (HANDOFF_* env → plugin userConfig → default): THRESHOLD=!`echo "${HANDOFF_THRESHOLD:-${CLAUDE_PLUGIN_OPTION_THRESHOLD:-300000}}"` LIVE_FROM=!`echo "${HANDOFF_LIVE_FROM:-${CLAUDE_PLUGIN_OPTION_LIVE_FROM:-0}}"` LIVE_EVERY=!`echo "${HANDOFF_LIVE_EVERY:-${CLAUDE_PLUGIN_OPTION_LIVE_EVERY:-20000}}"` MODE=!`echo "${HANDOFF_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-inject}}"` T3_AUTOCLEAR=!`echo "${HANDOFF_T3_AUTOCLEAR:-${CLAUDE_PLUGIN_OPTION_T3_AUTOCLEAR:-false}}"`

T3 auto-clear preflight (T3 Code (Beta) >= 0.1.0, statev2.sqlite, t3ctl, this session's thread): !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/t3-autoclear.sh" "${CLAUDE_PROJECT_DIR}" /dev/null "${CLAUDE_CODE_SESSION_ID}" check 2>&1`

Handoff dir: !`ls -la "${CLAUDE_PROJECT_DIR}/.claude/handoff" "${CLAUDE_PROJECT_DIR}/.claude/handoff/sessions" "${CLAUDE_PROJECT_DIR}/.claude/handoff/by-pid" 2>&1`

Owner of current.md: !`cat "${CLAUDE_PROJECT_DIR}/.claude/handoff/current.owner" 2>/dev/null || echo none` (this Claude pid: !`ps -o ppid= -p $PPID | tr -d ' '`)

Last hook log lines:
!`tail -n 15 "${CLAUDE_PROJECT_DIR}/.claude/handoff/hooks.log" 2>/dev/null || echo "(no log yet)"`

Summarize the above for the user in a few lines: is a handoff staged, whose is it, when was it written, what is the threshold, whether live state is on, and (when T3_AUTOCLEAR is true) whether the T3 auto-clear preflight is ok or what blocks it.
