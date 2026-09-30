#!/bin/bash
# End-of-turn logic. Never fires mid-turn.
#  LIVE_FROM  (tokens, 0=off): from this context size on, ask the model to keep sessions/<sid>.md updated,
#             re-asking only after the context grew by LIVE_EVERY tokens since the last update.
#  THRESHOLD  (tokens, 0=off): final handoff. Ask the model to write/finalize the file, verify the required
#             sections (max 2 nudges), stage it, tell the user to /clear.
source "$(dirname "$0")/handoff-lib.sh"
IN="$(cat)"
T="$(jq -r .transcript_path <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"
ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$IN")"
CTX="$(context_tokens "$T")"; CTX="${CTX:-0}"
THR="$(cfg THRESHOLD 300000)"; LIVE_FROM="$(cfg LIVE_FROM 0)"; LIVE_EVERY="$(cfg LIVE_EVERY 20000)"
F="$HANDOFF_DIR/sessions/$SID.md"
log stop "ctx=$CTX thr=$THR live_from=$LIVE_FROM active=$ACTIVE sid=$SID"
# A tombstoned session was already /cleared and superseded; a resume of it is a stale zombie.
# Do not publish (would re-stage stale content) or nudge — stay inert.
if is_tombstoned "$SID"; then log stop "tombstoned sid=$SID; inert (no publish/nudge)"; exit 0; fi

SECTIONS='Sections, in this order: # Handoff; ## Goal (the user'"'"'s actual ask, their words where possible); ## Standing instructions from the user (EVERY steering directive the user gave in this conversation, in order, near-verbatim, one bullet each: scope limits, "do not X", "always Y", style/format preferences, process rules, corrections of your behaviour. Tag each [active] or [superseded by #n] or [withdrawn], and name its source: which user message (quote a few words), CLAUDE.md, or a hook note; do not attribute a chat instruction to CLAUDE.md. Never drop an entry because it was later changed; the successor must see the history); ## Decisions log (each significant decision: what, who decided (user/assistant), why, and [active] or [reversed by #n]); ## Current state (done + how verified); ## In progress (exact step when context ended); ## Next steps (ordered, actionable); ## Key files & symbols (path:line, one-line role); ## Gotchas / dead ends (tried and rejected, why); ## Open questions for the user. Before writing, re-read the user'"'"'s messages in this conversation and make sure every directive appears under Standing instructions. Be concrete: paths, symbols, commands, exact decisions. No placeholders.'

# ---- final handoff at threshold
if [ "$THR" -gt 0 ] && [ "$CTX" -ge "$THR" ]; then
  ATTEMPTS="$(state_get "$SID" final_attempts)"; ATTEMPTS="${ATTEMPTS:-0}"
  FINAL_AT="$(state_get "$SID" final_written_ctx)"
  MISSING=""; [ -s "$F" ] && MISSING="$(missing_sections "$F")"
  # Complete handoff exists but the user kept working without /clear: once the context grew by LIVE_EVERY since the
  # last write, ask for a refresh instead of restaging a stale document.
  if [ -s "$F" ] && [ -z "$MISSING" ] && [ -n "$FINAL_AT" ] && [ "$ACTIVE" != "true" ] && [ $((CTX - FINAL_AT)) -ge "$LIVE_EVERY" ]; then
    state_set "$SID" final_written_ctx "$CTX"
    jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}), ${LIVE_EVERY}+ tokens past the last handoff. Asking Claude to refresh the handoff document. Then /clear (the plugin does not clear by itself unless T3_AUTOCLEAR is on)." \
           --arg ctx "The context window is at ${CTX} tokens, past the handoff limit of ${THR}, and the handoff document $F is out of date. Before stopping: update it so every section reflects the current state (overwrite with Write; Standing instructions and Decisions log are append-only, add new entries and re-tag old ones). ${SECTIONS} Then stop; do not continue the task." \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"Stop", additionalContext:$ctx}}'
    exit 0
  fi
  if [ -s "$F" ] && [ -z "$MISSING" ] && [ -n "$FINAL_AT" ]; then
    [ "$ACTIVE" = "true" ] && state_set "$SID" final_written_ctx "$CTX"
    publish "$F"
    if [ "$(cfg T3_AUTOCLEAR false)" = "true" ] && [ "$(state_get "$SID" t3_scheduled)" != "1" ]; then
      state_set "$SID" t3_scheduled 1; R="$(bash "$(dirname "$0")/t3-autoclear.sh" "$ROOT" "$LOG" "$SID")"
      case "$R" in
        *scheduled*) jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff staged; T3 auto-clear scheduled (/clear then /handoff:resume once this turn ends). ${R}" '{systemMessage:$m}';;
        *)           jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff staged. T3 auto-clear skipped (${R:-no reason}); type /clear, then /handoff:resume." '{systemMessage:$m}';;
      esac
    else
      jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff for this session is written and staged. Type /clear, then /handoff:resume (the plugin does not clear by itself unless T3_AUTOCLEAR is on)." '{systemMessage:$m}'
    fi
    exit 0
  fi
  if [ "$ATTEMPTS" -ge 2 ]; then
    [ -s "$F" ] && publish "$F"
    jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff file is $( [ -s "$F" ] && echo "incomplete (missing: $(echo $MISSING | tr '\n' ' '))" || echo missing ); staged as-is. /clear will fall back to the transcript summarizer if needed." '{systemMessage:$m}'
    exit 0
  fi
  state_set "$SID" final_attempts "$((ATTEMPTS+1))"; state_set "$SID" final_written_ctx "$CTX"
  if [ -s "$F" ] && [ -n "$MISSING" ]; then
    WHAT="The handoff document $F exists but is missing these sections: $(echo $MISSING | tr '\n' ', '). Add them (concrete content, not placeholders) and make sure the whole document reflects the current state."
  elif [ -s "$F" ]; then
    WHAT="Finalize the handoff document $F: bring every section up to date with the current state (overwrite with Write)."
  else
    WHAT="Write the handoff document with the Write tool to $F."
  fi
  jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Asking Claude to write the handoff document before it stops." \
         --arg ctx "The context window is at ${CTX} tokens, past the handoff limit of ${THR}. This conversation will continue in a fresh context that sees only the repo and a handoff document. Before stopping: ${WHAT} ${SECTIONS} Then stop; do not continue the task." \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"Stop", additionalContext:$ctx}}'
  exit 0
fi

# ---- live state (optional), only below the threshold
if [ "$LIVE_FROM" -gt 0 ] && [ "$CTX" -ge "$LIVE_FROM" ] && [ "$ACTIVE" != "true" ]; then
  LAST="$(state_get "$SID" live_ctx)"; LAST="${LAST:-0}"
  if [ $((CTX - LAST)) -ge "$LIVE_EVERY" ]; then
    state_set "$SID" live_ctx "$CTX"
    if [ -s "$F" ]; then WHAT="Update the running handoff document $F so it reflects the current state (overwrite with Write). Standing instructions and Decisions log are append-only: add new entries, mark old ones superseded/reversed, never delete. Keep the other sections under ~100 lines."; else WHAT="Create a running handoff document with the Write tool at $F (other sections under ~100 lines; Standing instructions and Decisions log complete)."; fi
    jq -nc --arg m "Handoff: context is ${CTX} tokens (live state from ${LIVE_FROM}). Asking Claude to update the running handoff." \
           --arg ctx "Context is at ${CTX} tokens. Before stopping: ${WHAT} ${SECTIONS} It is a working copy that a fresh context could resume from if this one is lost. Then stop." \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"Stop", additionalContext:$ctx}}'
    exit 0
  fi
fi
exit 0
