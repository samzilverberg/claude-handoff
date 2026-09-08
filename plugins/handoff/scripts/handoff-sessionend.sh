#!/bin/bash
# /clear: stage this session's handoff into current.md before the new session reads CLAUDE.md.
# Other exits: release current.md if this process owns it (so a later fresh startup does not inherit it).
source "$(dirname "$0")/handoff-lib.sh"
IN="$(cat)"
T="$(jq -r .transcript_path <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"; R="$(jq -r .reason <<<"$IN")"
log sessionend "reason=$R sid=$SID pid=$CPID ctx=$(context_tokens "$T")"
if [ "$R" = "clear" ]; then
  F="$(session_handoff "$T" "$SID" "sessionend-clear" "$(cfg MAX_AGE_SEC 86400)")" && publish "$F"
else
  [ "$(owner_pid)" = "$CPID" ] && reset_current
fi
exit 0
