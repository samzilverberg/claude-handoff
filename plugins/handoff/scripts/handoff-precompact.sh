#!/bin/bash
# Safeguard when auto-compact fires anyway (window set above the Stop threshold): make sure a handoff exists
# and is staged in current.md, which CLAUDE.md re-imports right after compaction. HANDOFF_MODE=block refuses
# proactive compaction instead and tells the user to /clear.
source "$(dirname "$0")/handoff-lib.sh"
IN="$(cat)"
T="$(jq -r .transcript_path <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"; TRIG="$(jq -r .trigger <<<"$IN")"
log precompact "trigger=$TRIG sid=$SID ctx=$(context_tokens "$T")"
F="$(session_handoff "$T" "$SID" "precompact-$TRIG")" && publish "$F"
if [ "$(cfg MODE inject)" = "block" ] && [ "$TRIG" = "auto" ]; then
  jq -nc '{decision:"block", reason:"Handoff staged in .claude/handoff/current.md. Auto-compact blocked; type /clear to continue from the handoff."}'
fi
exit 0
