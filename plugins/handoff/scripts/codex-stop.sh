#!/bin/bash
# Codex Stop hook: the end-of-turn handoff for OpenAI Codex (same thresholds and document as handoff-stop.sh).
#  THRESHOLD: ask Codex to write sessions/<sid>.md (max 2 asks), check the sections, then hand off:
#             T3 Code (T3_AUTOCLEAR): t3.sh sends the document to the same thread as a fresh session (T3 starts a new
#             Codex session there); elsewhere the user starts a new session and resumes from the file.
#  LIVE_FROM / LIVE_EVERY: running handoff below the threshold, as for Claude.
# Codex runs one app-server for all T3 threads (one pid, no T3CODE_THREAD_ID), so everything is keyed by the Codex
# session id; t3.sh finds the thread in T3's db by that id. Requests to the model: under T3 a separate turn (t3.sh
# nudge), else Stop {"decision":"block","reason":…}, which Codex runs as a continuation of this turn.
IN="$(cat)"
CWD="$(jq -r '.cwd // empty' <<<"$IN")"
export CLAUDE_PROJECT_DIR="${CWD:-$PWD}" HANDOFF_AGENT=codex
source "$(dirname "$0")/handoff-lib.sh"
T="$(jq -r '.transcript_path // empty' <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"
ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$IN")"
CTX="$(context_tokens "$T")"; CTX="${CTX:-0}"
THR="$(cfg THRESHOLD 300000)"; LIVE_FROM="$(cfg LIVE_FROM 0)"; LIVE_EVERY="$(cfg LIVE_EVERY 20000)"
# keep the threshold under the model's window (Codex auto-compacts at ~90% of it): at most 70% of the window
WIN="$(codex_window "$T")"; WIN="${WIN:-0}"
if [ "$THR" -gt 0 ] && [ "$WIN" -gt 0 ] && [ "$THR" -gt $((WIN * 7 / 10)) ]; then THR=$((WIN * 7 / 10)); fi
F="$HANDOFF_DIR/sessions/$SID.md"
log codex-stop "ctx=$CTX thr=$THR win=$WIN live_from=$LIVE_FROM active=$ACTIVE sid=$SID"
if is_tombstoned "$SID"; then log codex-stop "tombstoned sid=$SID; inert"; exit 0; fi
held_after_block "$SID" && exit 0   # T3_DEFER: the message was held back, no real turn ran
T3ON="$(cfg T3_AUTOCLEAR false)"
WRITE="Write it as a file (apply_patch, or a shell heredoc) at exactly this path: $F."

# emit_nudge <systemMessage> <request>: a separate T3 turn when possible, else a Stop block (continuation prompt).
emit_nudge() {
  local R="" f="$HANDOFF_DIR/state/$SID.nudge.txt"
  if [ "$T3ON" = "true" ] && [ "$(cfg T3_NUDGE_TURN true)" = "true" ]; then
    printf '[handoff plugin] %s\n\n(Sent by the handoff plugin as a separate turn so that your previous reply stays the visible answer in T3 Code.)\n' "$2" > "$f"
    R="$(HANDOFF_AGENT=codex bash "$T3SH" "$ROOT" "$LOG" "$SID" nudge "$f")"
    case "$R" in *scheduled*) jq -nc --arg m "$1 Delivered as a separate T3 turn. $R" '{systemMessage:$m}'; return;; esac
  fi
  jq -nc --arg m "$1${R:+ (T3 turn not used: $R)}" --arg r "[handoff plugin] $2" '{systemMessage:$m, decision:"block", reason:$r}'
}

# Loop guard: a session that starts at or above the threshold (a big handoff document, a threshold below the fresh
# context's base size) would hand off again at once, every session. The final handoff needs the session to have grown
# by LIVE_EVERY since its first Stop (or to be in the middle of one: FINAL_AT set).
FIRST="$(state_get "$SID" first_ctx)"; [ -n "$FIRST" ] || { FIRST="$CTX"; state_set "$SID" first_ctx "$CTX"; }
if [ "$THR" -gt 0 ] && [ "$CTX" -ge "$THR" ] && [ -z "$(state_get "$SID" final_written_ctx)" ] && [ $((CTX - FIRST)) -lt "$LIVE_EVERY" ]; then
  log codex-stop "ctx $CTX >= thr $THR but the session started at $FIRST (< $LIVE_EVERY growth): no handoff yet"
  exit 0
fi
if [ "$THR" -gt 0 ] && [ "$CTX" -ge "$THR" ]; then
  ATTEMPTS="$(state_get "$SID" final_attempts)"; ATTEMPTS="${ATTEMPTS:-0}"
  FINAL_AT="$(state_get "$SID" final_written_ctx)"
  MISSING=""; [ -s "$F" ] && MISSING="$(missing_sections "$F")"
  PUB_AT="$(state_get "$SID" pub_ctx)"   # growth since this version was staged (see note_publish)
  if [ -s "$F" ] && [ -z "$MISSING" ] && [ -n "$PUB_AT" ] && [ "$ACTIVE" != "true" ] && [ "$(state_get "$SID" t3_clear)" != "1" ] \
     && [ $((CTX - PUB_AT)) -ge "$LIVE_EVERY" ]; then
    state_set "$SID" final_written_ctx "$CTX"
    emit_nudge "Handoff: context is ${CTX} tokens (limit ${THR}), ${LIVE_EVERY}+ tokens past the last handoff. Asking Codex to refresh the handoff document." \
               "The context window is at ${CTX} tokens, past the handoff limit of ${THR}, and the handoff document $F is out of date. Before stopping: update it so every section reflects the current state (overwrite the file; Standing instructions and Decisions log are append-only, add new entries and re-tag old ones). ${SECTIONS} Then stop; do not continue the task."
    exit 0
  fi
  if [ -s "$F" ] && [ -z "$MISSING" ] && [ -n "$FINAL_AT" ]; then
    [ "$ACTIVE" = "true" ] && state_set "$SID" final_written_ctx "$CTX"
    # document checks before the first staging (doc_problems: probable secrets, size): up to 2 fix requests. After
    # that: staged with a warning, except that a document with probable secrets is not sent into the T3 thread
    # (the message would keep them in T3's db).
    DW=""; NOSEND=""
    if [ "$(state_get "$SID" t3_clear)" != "1" ]; then
      PROB="$(doc_problems "$F")"
      if [ -n "$PROB" ]; then
        FIX="$(state_get "$SID" fix_attempts)"; FIX="${FIX:-0}"
        if [ "$FIX" -lt 2 ]; then
          state_set "$SID" fix_attempts "$((FIX+1))"
          emit_nudge "Handoff: the handoff document needs a fix before it is staged ($(cut -d. -f1 <<<"$PROB" | paste -sd ';' -))." \
                     "The handoff document $F is complete but cannot be staged as is: $(paste -sd ' ' - <<<"$PROB") Fix the file (overwrite it), keeping every section. Then stop; do not continue the task."
          exit 0
        fi
        DW=" Warning: the document still has $(cut -d. -f1 <<<"$PROB" | paste -sd ';' -) after 2 fix requests."
        grep -q '^probable secrets' <<<"$PROB" && NOSEND=1
        log codex-stop "staging despite: $(paste -sd ' ' - <<<"$PROB")"
      fi
    fi
    stamp_workspace "$F"; note_publish "$SID" "$F" "$CTX"
    log publish "codex sid=$SID <- $F"
    if [ -n "$NOSEND" ]; then
      release_held_prompt "$SID" "document not sent (probable secrets)"
      jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Not sent automatically: redact $F, then start a fresh session and ask it to resume from that file." '{systemMessage:$m}'
    elif [ "$T3ON" = "true" ] && [ "$(state_get "$SID" t3_clear)" = "1" ]; then
      RS="$(cat "$HANDOFF_DIR/state/$SID.t3clear" 2>/dev/null)"
      case "$RS" in
        failed:*) jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written to $F, but the automatic T3 handoff failed (${RS#failed:}). Start a fresh session (T3 composer: /clear) and ask it to resume from $F." '{systemMessage:$m}';;
        *)        jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written; the automatic T3 handoff is already scheduled (${RS:-pending}; see hooks.log [t3])." '{systemMessage:$m}';;
      esac
    elif [ "$T3ON" = "true" ] && is_armed "$SID"; then
      jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written; this thread continues in a fresh session when you send your next message (T3_DEFER: that message runs there)." '{systemMessage:$m}'
    elif [ "$T3ON" = "true" ] && [ -z "$(pending_prompt "$SID")" ] && [ "$(t3_defer)" = resume ] && defer_arm "$SID" resume; then
      jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written; this thread continues in a fresh session when you send your next message (T3_DEFER=resume: that message runs there)." '{systemMessage:$m}'
    elif [ "$T3ON" = "true" ]; then
      # T3_DEFER: a held message (pending prompt) is appended to the document in the fresh session's first message
      R="$(HANDOFF_AGENT=codex HANDOFF_RESUME_ARGS="$(pending_prompt "$SID")" bash "$T3SH" "$ROOT" "$LOG" "$SID" clear "$F")"
      case "$R" in
        *scheduled*) state_set "$SID" t3_clear 1
                     jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written; once this turn ends the plugin sends it to this thread as a fresh session. ${R}" '{systemMessage:$m}';;
        *)           release_held_prompt "$SID" "automatic handoff skipped"
                     jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written to $F. Automatic T3 handoff skipped (${R:-no reason}); start a fresh session (T3 composer: /clear) and ask it to resume from $F." '{systemMessage:$m}';;
      esac
    else
      jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}).${DW} Handoff written to $F. Start a new session (/new) and ask it to resume from that file (or: \$handoff-resume)." '{systemMessage:$m}'
    fi
    exit 0
  fi
  if [ "$ATTEMPTS" -ge 2 ]; then
    release_held_prompt "$SID" "no complete handoff document after 2 requests"
    jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff file $F is $( [ -s "$F" ] && echo "incomplete (missing: $(echo $MISSING | tr '\n' ' '))" || echo missing ) after 2 requests; not handing off automatically." '{systemMessage:$m}'
    exit 0
  fi
  state_set "$SID" final_attempts "$((ATTEMPTS+1))"; state_set "$SID" final_written_ctx "$CTX"
  if [ -s "$F" ] && [ -n "$MISSING" ]; then
    WHAT="The handoff document $F exists but is missing these sections: $(echo $MISSING | tr '\n' ', '). Add them (concrete content, not placeholders) and make sure the whole document reflects the current state."
  elif [ -s "$F" ]; then
    WHAT="Finalize the handoff document $F: bring every section up to date with the current state (overwrite the file)."
  else
    WHAT="Write the handoff document. $WRITE"
  fi
  REQ="The context window is at ${CTX} tokens, past the handoff limit of ${THR}. This conversation will continue in a fresh context that sees only the repo and a handoff document. Before stopping: ${WHAT} ${SECTIONS} Then stop; do not continue the task."
  # T3_DEFER=all: nothing now; the user's next message starts the handoff (see defer_on_prompt)
  if [ "$(t3_defer)" = all ] && [ "$ATTEMPTS" -eq 0 ] && [ "$ACTIVE" != "true" ] && defer_arm "$SID" all "$REQ"; then
    jq -nc --arg m "Handoff: context is ${CTX} tokens (limit ${THR}). Handoff due: it runs when you send your next message (T3_DEFER=all: handoff document first, then your message in a fresh session)." '{systemMessage:$m}'
    exit 0
  fi
  emit_nudge "Handoff: context is ${CTX} tokens (limit ${THR}). Asking Codex to write the handoff document." "$REQ"
  exit 0
fi

if [ "$LIVE_FROM" -gt 0 ] && [ "$CTX" -ge "$LIVE_FROM" ] && [ "$ACTIVE" != "true" ]; then
  LAST="$(state_get "$SID" live_ctx)"; LAST="${LAST:-0}"
  if [ $((CTX - LAST)) -ge "$LIVE_EVERY" ]; then
    state_set "$SID" live_ctx "$CTX"
    if [ -s "$F" ]; then WHAT="Update the running handoff document $F so it reflects the current state (overwrite the file). Standing instructions and Decisions log are append-only: add new entries, mark old ones superseded/reversed, never delete. Keep the other sections under ~100 lines."
    else WHAT="Create a running handoff document (other sections under ~100 lines; Standing instructions and Decisions log complete). $WRITE"; fi
    emit_nudge "Handoff: context is ${CTX} tokens (live state from ${LIVE_FROM}). Asking Codex to update the running handoff." \
               "Context is at ${CTX} tokens. Before stopping: ${WHAT} ${SECTIONS} It is a working copy that a fresh context could resume from if this one is lost. Then stop."
    exit 0
  fi
fi
exit 0
