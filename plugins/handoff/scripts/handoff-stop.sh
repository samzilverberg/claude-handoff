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
KEY="$(session_key "$SID")"   # = SID, except post-/clear sessions under the T3 layer (see session_key)
F="$HANDOFF_DIR/sessions/$KEY.md"
log stop "ctx=$CTX thr=$THR live_from=$LIVE_FROM active=$ACTIVE sid=$SID"
rm -f "$HANDOFF_DIR/by-session/$SID.md"   # first turn after a /clear done in-process: no later process adopts it
# A tombstoned session was already /cleared and superseded; a resume of it is a stale zombie.
# Do not publish (would re-stage stale content) or nudge — stay inert.
if is_tombstoned "$SID"; then log stop "tombstoned sid=$SID; inert (no publish/nudge)"; exit 0; fi
held_after_block "$SID" && exit 0   # T3_DEFER: the message was held back, no real turn ran

# SECTIONS: see handoff-lib.sh

# Nudges are normally delivered in-turn (Stop additionalContext). Under T3 Code with T3_AUTOCLEAR that makes the
# "handoff written" note the turn's last assistant message, and T3's timeline shows only that one, folding the real
# reply behind "Worked for …". So in T3 mode the nudge goes out as its own turn via t3.sh nudge instead.
# T3_NUDGE_TURN=false switches back to the in-turn nudge (auto-clear itself unaffected), e.g. to compare while testing.
# t3_nudge <text>: returns 0 when the helper scheduled it (then do NOT emit additionalContext); R holds its report.
t3_nudge() {
  R=""; [ "$(cfg T3_AUTOCLEAR false)" = "true" ] || return 1
  [ "$(cfg T3_NUDGE_TURN true)" = "true" ] || { R="T3_NUDGE_TURN=false"; return 1; }
  local f="$HANDOFF_DIR/state/$SID.nudge.txt"
  printf '[handoff plugin] %s\n\n(Sent by the handoff plugin as a separate turn so that your previous reply stays the visible answer in T3 Code.)\n' "$1" > "$f"
  R="$(bash "$T3SH" "$ROOT" "$LOG" "$SID" nudge "$f")"
  case "$R" in *scheduled*) return 0;; *) return 1;; esac
}
# emit_nudge <systemMessage> <context>: T3 turn when possible, else in-turn additionalContext.
emit_nudge() {
  if t3_nudge "$2"; then
    jq -nc --arg m "$1 Delivered as a separate T3 turn so this reply stays visible. ${R}" '{systemMessage:$m}'
  else
    jq -nc --arg m "$1${R:+ (T3 turn not used: $R)}" --arg ctx "$2" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"Stop", additionalContext:$ctx}}'
  fi
}

# /handoff:now (manual_arm in handoff-lib.sh): this session hands off now, whatever its size. The document counts once it
# was (re)written after the arming; HEAD opens every message of the handoff branch.
MANUAL=""; MAN_AT=0
if is_manual "$SID"; then MANUAL=1; MAN_AT="$(manual_get "$SID" at)"; MAN_AT="${MAN_AT:-0}"; fi
if [ -n "$MANUAL" ]; then HEAD="Handoff (/handoff:now$(manual_desc "$SID")): context is ${CTX} tokens."
else HEAD="Handoff: context is ${CTX} tokens (limit ${THR})."; fi

# Loop guard: a session that starts at or above the threshold (a big handoff document, a threshold below the fresh
# context's base size) would hand off again at once, every session. Such a session (first Stop at or above the
# threshold) hands off only after growing by LIVE_EVERY since that first Stop, unless a handoff is already under way
# (final_written_ctx set). LOOP_GUARD=false turns it off. first_ctx is per session id.
FIRST="$(state_get "$SID" first_ctx)"; [ -n "$FIRST" ] || { FIRST="$CTX"; state_set "$SID" first_ctx "$CTX"; }
if [ -z "$MANUAL" ] && [ "$(cfg LOOP_GUARD true)" = true ] && [ "$THR" -gt 0 ] && [ "$CTX" -ge "$THR" ] && [ "$FIRST" -ge "$THR" ] && [ -z "$(state_get "$KEY" final_written_ctx)" ] && [ $((CTX - FIRST)) -lt "$LIVE_EVERY" ]; then
  log stop "ctx $CTX >= thr $THR but the session started at $FIRST (< $LIVE_EVERY growth): no handoff yet"
  exit 0
fi

# ---- final handoff at threshold (or asked for with /handoff:now)
if [ -n "$MANUAL" ] || { [ "$THR" -gt 0 ] && [ "$CTX" -ge "$THR" ]; }; then
  ATTEMPTS="$(state_get "$KEY" final_attempts)"; ATTEMPTS="${ATTEMPTS:-0}"
  FINAL_AT="$(state_get "$KEY" final_written_ctx)"
  MISSING=""; [ -s "$F" ] && MISSING="$(missing_sections "$F")"
  # Complete handoff exists but the user kept working without /clear: once the context grew by LIVE_EVERY since the
  # last write, ask for a refresh instead of restaging a stale document.
  PUB_AT="$(state_get "$KEY" pub_ctx)"
  if [ -z "$MANUAL" ] && [ -s "$F" ] && [ -z "$MISSING" ] && [ -n "$PUB_AT" ] && [ "$ACTIVE" != "true" ] && [ $((CTX - PUB_AT)) -ge "$LIVE_EVERY" ]; then
    state_set "$KEY" final_written_ctx "$CTX"
    emit_nudge "Handoff: context is ${CTX} tokens (limit ${THR}), ${LIVE_EVERY}+ tokens past the last handoff. Asking Claude to refresh the handoff document. Then /clear (under T3 Code with T3_AUTOCLEAR the plugin does that by itself)." \
               "The context window is at ${CTX} tokens, past the handoff limit of ${THR}, and the handoff document $F is out of date. Before stopping: update it so every section reflects the current state (overwrite with Write; Standing instructions and Decisions log are append-only, add new entries and re-tag old ones). ${SECTIONS} Then stop; do not continue the task."
    exit 0
  fi
  # ready: complete, and requested in this session (threshold) or written after /handoff:now armed it (manual)
  READY=""; if [ -n "$MANUAL" ]; then [ "$(mtime "$F")" -ge "$MAN_AT" ] && READY=1; else [ -n "$FINAL_AT" ] && READY=1; fi
  if [ -s "$F" ] && [ -z "$MISSING" ] && [ -n "$READY" ]; then
    [ "$ACTIVE" = "true" ] && state_set "$KEY" final_written_ctx "$CTX"
    # document checks before the first staging (doc_problems: probable secrets, size): up to 2 fix requests, then
    # staged anyway with a warning
    DW=""
    if [ "$(state_get "$KEY" t3_clear)" != "1" ]; then
      PROB="$(doc_problems "$F" "$THR")"
      if [ -n "$PROB" ]; then
        FIX="$(state_get "$KEY" fix_attempts)"; FIX="${FIX:-0}"
        if [ "$FIX" -lt 2 ]; then
          state_set "$KEY" fix_attempts "$((FIX+1))"
          emit_nudge "Handoff: the handoff document needs a fix before it is staged ($(cut -d. -f1 <<<"$PROB" | paste -sd ';' -))." \
                     "The handoff document $F is complete but cannot be staged as is: $(paste -sd ' ' - <<<"$PROB") Fix the file (overwrite it), keeping every section. Then stop; do not continue the task."
          exit 0
        fi
        DW=" Warning: the document still has $(cut -d. -f1 <<<"$PROB" | paste -sd ';' -) after 2 fix requests."
        log stop "staging despite: $(paste -sd ' ' - <<<"$PROB")"
      fi
    fi
    publish "$F" "$SID"; note_publish "$KEY" "$F" "$CTX"
    # T3 layer (t3.sh clear): /handoff:resume in a fresh session of this thread, or /clear + /handoff:resume. t3_clear
    # latches only once scheduled; a skip (thread not resolved, t3ctl missing …) is retried on the next Stop.
    # Outcome: state/<sid>.t3clear.
    if [ "$(cfg T3_AUTOCLEAR false)" = "true" ] && [ "$(state_get "$KEY" t3_clear)" = "1" ]; then
      RS="$(cat "$HANDOFF_DIR/state/$SID.t3clear" 2>/dev/null)"
      case "$RS" in
        failed:*) jq -nc --arg m "${HEAD}${DW} Handoff staged, but the automatic T3 handoff failed (${RS#failed:}). Type /clear, then /handoff:resume." '{systemMessage:$m}';;
        *)        jq -nc --arg m "${HEAD}${DW} Handoff staged; the automatic T3 handoff is already scheduled (${RS:-pending}; see hooks.log [t3])." '{systemMessage:$m}';;
      esac
    elif [ -z "$MANUAL" ] && [ "$(cfg T3_AUTOCLEAR false)" = "true" ] && is_armed "$SID"; then
      jq -nc --arg m "${HEAD}${DW} Handoff staged; this thread continues in a fresh session when you send your next message (T3_DEFER: that message runs there)." '{systemMessage:$m}'
    elif [ -z "$MANUAL" ] && [ "$(cfg T3_AUTOCLEAR false)" = "true" ] && [ -z "$(pending_prompt "$SID")" ] && [ "$(t3_defer)" = resume ] && defer_arm "$SID" resume; then
      jq -nc --arg m "${HEAD}${DW} Handoff staged; this thread continues in a fresh session when you send your next message (T3_DEFER=resume: that message runs there)." '{systemMessage:$m}'
    elif [ "$(cfg T3_AUTOCLEAR false)" = "true" ]; then
      # T3_DEFER: a held message (pending prompt) goes into the fresh session as /handoff:resume arguments
      # /handoff:now: the user's note and the model / effort go to the fresh session
      RA="$(pending_prompt "$SID")"; [ -n "$MANUAL" ] && [ -s "$HANDOFF_DIR/state/$SID.manual-note.txt" ] && RA="$HANDOFF_DIR/state/$SID.manual-note.txt"
      R="$(HANDOFF_RESUME_ARGS="$RA" HANDOFF_FRESH_MODEL="$(manual_get "$SID" model)" HANDOFF_FRESH_EFFORT="$(manual_get "$SID" effort)" bash "$T3SH" "$ROOT" "$LOG" "$SID" clear "$F")"
      case "$R" in
        *"fresh session) scheduled"*) state_set "$KEY" t3_clear 1
                     jq -nc --arg m "${HEAD}${DW} Handoff staged; once this turn ends the plugin sends /handoff:resume to this thread in a fresh session (T3 starts a new Claude session in the same thread). ${R}" '{systemMessage:$m}';;
        *scheduled*) state_set "$KEY" t3_clear 1
                     jq -nc --arg m "${HEAD}${DW} Handoff staged; once this turn ends the plugin sends /clear and /handoff:resume to this thread. ${R}" '{systemMessage:$m}';;
        *)           release_held_prompt "$SID" "automatic handoff skipped"
                     jq -nc --arg m "${HEAD}${DW} Handoff staged. Automatic T3 handoff skipped (${R:-no reason}); type /clear, then /handoff:resume." '{systemMessage:$m}';;
      esac
    else
      MX=""; [ -n "$MANUAL" ] && [ -s "$HANDOFF_DIR/state/$SID.manual-note.txt" ] && MX=" To pass your /handoff:now note on, add it after /handoff:resume."
      jq -nc --arg m "${HEAD}${DW} Handoff for this session is written and staged. Type /clear, then /handoff:resume (under T3 Code, T3_AUTOCLEAR does this automatically).${MX}" '{systemMessage:$m}'
    fi
    manual_done "$SID" staged
    exit 0
  fi
  if [ "$ATTEMPTS" -ge 2 ]; then
    [ -s "$F" ] && publish "$F" "$SID"
    release_held_prompt "$SID" "no complete handoff document after 2 requests"; manual_done "$SID" "no document after 2 requests"
    jq -nc --arg m "${HEAD} Handoff file is $( [ -s "$F" ] && echo "incomplete (missing: $(echo $MISSING | tr '\n' ' '))" || echo missing ); staged as-is. /clear will fall back to the transcript summarizer if needed." '{systemMessage:$m}'
    exit 0
  fi
  # a request whose T3 nudge turn has not gone out yet (a background task's turn ran first) is not a new attempt: the
  # pending worker sends the refreshed text (t3.sh nudge does not queue a second turn)
  if nudge_pending "$SID"; then log stop "handoff request not delivered yet (nudge worker pending): text refreshed, not counted as a new request"
  else state_set "$KEY" final_attempts "$((ATTEMPTS+1))"; fi
  state_set "$KEY" final_written_ctx "$CTX"
  if [ -s "$F" ] && [ -n "$MISSING" ]; then
    WHAT="The handoff document $F exists but is missing these sections: $(echo $MISSING | tr '\n' ', '). Add them (concrete content, not placeholders) and make sure the whole document reflects the current state."
  elif [ -s "$F" ]; then
    WHAT="Finalize the handoff document $F: bring every section up to date with the current state (overwrite with Write)."
  else
    WHAT="Write the handoff document with the Write tool to $F."
  fi
  if [ -n "$MANUAL" ]; then REQ="The user asked to hand this conversation off now (/handoff:now). This conversation"
  else REQ="The context window is at ${CTX} tokens, past the handoff limit of ${THR}. This conversation"; fi
  REQ="${REQ} will continue in a fresh context that sees only the repo and a handoff document. Before stopping: ${WHAT} ${SECTIONS} Then stop; do not continue the task."
  # T3_DEFER=all: nothing now; the user's next message starts the handoff (see defer_on_prompt)
  if [ -z "$MANUAL" ] && [ "$(t3_defer)" = all ] && [ "$ATTEMPTS" -eq 0 ] && [ "$ACTIVE" != "true" ] && defer_arm "$SID" all "$REQ"; then
    jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff due: it runs when you send your next message (T3_DEFER=all: handoff document first, then your message in a fresh session)." '{systemMessage:$m}'
    exit 0
  fi
  emit_nudge "${HEAD} Asking Claude to write the handoff document before it stops." "$REQ"
  exit 0
fi

# ---- live state (optional), only below the threshold
if [ "$LIVE_FROM" -gt 0 ] && [ "$CTX" -ge "$LIVE_FROM" ] && [ "$ACTIVE" != "true" ]; then
  LAST="$(state_get "$KEY" live_ctx)"; LAST="${LAST:-0}"
  if [ $((CTX - LAST)) -ge "$LIVE_EVERY" ]; then
    state_set "$KEY" live_ctx "$CTX"
    if [ -s "$F" ]; then WHAT="Update the running handoff document $F so it reflects the current state (overwrite with Write). Standing instructions and Decisions log are append-only: add new entries, mark old ones superseded/reversed, never delete. Keep the other sections under ~100 lines."; else WHAT="Create a running handoff document with the Write tool at $F (other sections under ~100 lines; Standing instructions and Decisions log complete)."; fi
    emit_nudge "Handoff: context is ${CTX} tokens (live state from ${LIVE_FROM}). Asking Claude to update the running handoff." \
               "Context is at ${CTX} tokens. Before stopping: ${WHAT} ${SECTIONS} It is a working copy that a fresh context could resume from if this one is lost. Then stop."
    exit 0
  fi
fi
exit 0
