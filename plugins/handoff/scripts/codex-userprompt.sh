#!/bin/bash
# Codex UserPromptSubmit: T3_DEFER only (see defer_on_prompt in handoff-lib.sh). Holds the message when a deferred
# handoff is armed for this session and starts it; the message is re-sent into the fresh session. Fast no-op otherwise.
IN="$(cat)"
SID="$(jq -r .session_id <<<"$IN")"; CWD="$(jq -r '.cwd // empty' <<<"$IN")"
ST="${CWD:-$PWD}/.claude/handoff/state"
[ -f "$ST/defer/$SID" ] || [ -f "$ST/$SID.held" ] || exit 0
export CLAUDE_PROJECT_DIR="${CWD:-$PWD}" HANDOFF_AGENT=codex
source "$(dirname "$0")/handoff-lib.sh"
defer_on_prompt "$SID" "$(jq -r '.prompt // empty' <<<"$IN")" "$HANDOFF_DIR/sessions/$SID.md" "$SID"
exit 0
