#!/bin/bash
# Codex SessionStart. The T3 handoff sends the document inline as the fresh session's first message, so a new session
# needs nothing here. compact: Codex auto-compacted anyway (above its own limit): start the per-window state over and
# point the model at this conversation's handoff document when one exists.
IN="$(cat)"
CWD="$(jq -r '.cwd // empty' <<<"$IN")"
export CLAUDE_PROJECT_DIR="${CWD:-$PWD}" HANDOFF_AGENT=codex
source "$(dirname "$0")/handoff-lib.sh"
SRC="$(jq -r .source <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"
log codex-sessionstart "source=$SRC sid=$SID"
if [ "$SRC" = "compact" ]; then
  rm -f "$HANDOFF_DIR/state/$SID.json"
  F="$HANDOFF_DIR/sessions/$SID.md"
  if [ -s "$F" ]; then
    jq -nc --arg c "This conversation was just compacted. A handoff document written earlier in it is at $F (last written $(date -r "$(mtime "$F")" '+%Y-%m-%d %H:%M')). Where the compacted summary lacks detail (standing instructions from the user, decisions, gotchas), read that file before continuing." \
      '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
  fi
fi
exit 0
