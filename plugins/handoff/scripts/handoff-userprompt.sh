#!/bin/bash
# UserPromptSubmit. /handoff:now: arms a manual handoff (manual_arm in handoff-lib.sh). T3_DEFER (see defer_on_prompt in handoff-lib.sh): holds the message when a deferred handoff is
# armed. Otherwise a fast no-op unless this session is tombstoned (/cleared and superseded). A tombstoned session
# that gets a prompt under T3 Code is a thread T3 resumed on its stale pre-/clear session (a /clear by plugin <= 0.5,
# or one whose alias failed). With T3_AUTOCLEAR the prompt must not run in that stale context (a resumed 300k+
# session costs a full uncached read and acts on outdated state): block it (zero tokens; T3 shows the reason as a
# notice) and recover the thread: newest handoff of the /clear chain + transcript digest, then /handoff:resume with the
# prompt in a fresh T3 session (older T3: after a /clear that aliases T3's session to the new one). Outside T3
# nothing is blocked: the user picked this session (claude --resume) and the SessionStart note already says where the
# work continues.
# Recovery only when T3 still routes the thread to this stale session (t3.sh recover checks). A tombstoned session the
# thread no longer routes to is a replaced process that stayed alive (background work after a fresh-session handoff):
# Claude wakes it with a <task-notification> prompt whenever such work ends. That prompt is blocked, logged
# (rate-limited) and nothing is sent to the thread (0.10.0 recovered here: thread 569772de, 2026-11-24).
IN="$(cat)"
SID="$(jq -r .session_id <<<"$IN")"
# runs on every prompt: answer the common case (live session, nothing held) before loading the library
ST="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/handoff/state"
MAN=""; grep -qE '"prompt" *: *"/handoff:now([ \\"]|$)' <<<"$IN" && MAN=1
[ -n "$MAN" ] || [ -f "$ST/tombstones/$SID.json" ] || [ -f "$ST/defer/$SID" ] || [ -f "$ST/$SID.held" ] || exit 0
source "$(dirname "$0")/handoff-lib.sh"
# /handoff:now (manual handoff, see manual_arm): arm it and give this turn the writing request. A tombstoned session
# falls through to the handling below (it is not the thread's live session).
if [ -n "$MAN" ] && [ ! -f "$ST/tombstones/$SID.json" ]; then
  P="$(jq -r '.prompt // empty' <<<"$IN")"
  if is_manual_prompt "$P"; then rm -f "$ST/$SID.held"; manual_arm "$SID" "$P"; exit 0; fi
fi
# T3_DEFER: a handoff (or its fresh session) armed for this session's next message: hold the message, start it
defer_on_prompt "$SID" "$(jq -r '.prompt // empty' <<<"$IN")" "$HANDOFF_DIR/sessions/$(session_key "$SID").md" "$(session_key "$SID")" && exit 0
[ -f "$ST/tombstones/$SID.json" ] || exit 0
[ "$(cfg T3_AUTOCLEAR false)" = "true" ] || { log userprompt "tombstoned sid=$SID (T3_AUTOCLEAR off: runs)"; exit 0; }
P="$(jq -r '.prompt // empty' <<<"$IN")"; [ -n "$P" ] || exit 0
WAKE=""; case "$P" in "<task-notification>"*) WAKE=1;; esac
PF="$HANDOFF_DIR/state/$SID.prompt.txt"; printf '%s\n' "$P" > "$PF"
R="$(HANDOFF_TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$IN")" bash "$(dirname "$0")/t3.sh" "$ROOT" "$LOG" "$SID" recover "$PF")"
# rate-limited log for prompts into a replaced process (Claude wakes it for every background task that ends):
# first one, then at most one line per WAKE_LOG_EVERY seconds (600) with the count in between
quiet_log() {
  local f="$HANDOFF_DIR/state/$SID.wakes" n=0 last=0
  [ -f "$f" ] && read -r n last < "$f"
  if [ "${last:-0}" -gt 0 ] && [ $(( $(now) - last )) -lt "$(cfg WAKE_LOG_EVERY 600)" ]; then echo "$((n+1)) $last" > "$f"; return 0; fi
  log userprompt "$1$( [ "${n:-0}" -gt 0 ] && echo "; $n more since $(date -r "$last" +%H:%M:%S)")"; echo "0 $(now)" > "$f"
}
block() { jq -nc --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }
case "$R" in
  "REPLACED "*)
    # T3 routes the thread to another session: this process was replaced (fresh session) and is still alive, e.g. for
    # background work; Claude wakes it when that work ends. No recovery, nothing sent to the thread; the prompt is
    # blocked so the replaced 300k context does no work (zero tokens). T3 0.1.12 finishes such a wake turn by itself.
    read -r _ CUR REL TID <<<"$R"
    if [ -n "$WAKE" ]; then
      quiet_log "wake of replaced session $SID (thread $TID maps to $( [ "$REL" = successor ] && echo successor || echo session) $CUR); ignored (blocked, no recovery)"
      block "Handoff plugin: background-task notification for a replaced session ($SID); this T3 thread continues in session $CUR. Not run here."
    fi
    log userprompt "prompt into replaced session $SID (thread $TID maps to $( [ "$REL" = successor ] && echo successor || echo session) $CUR); blocked, no recovery"
    block "Handoff plugin: this message reached a replaced Claude session ($SID) that is still running; this T3 thread continues in session $CUR. Send the message again (T3 Code before 0.1.12 could route a message to a replaced session that background work had woken)." ;;
  "WAKE_STALE "*)
    quiet_log "background-task wake of stale session $SID (thread ${R#WAKE_STALE } still maps to it); blocked, recovery waits for a real message"
    block "Handoff plugin: background-task notification for a stale, already handed-off session ($SID); not run. The next message you send restores the thread from its latest handoff." ;;
esac
log userprompt "tombstoned sid=$SID"
if grep -q '^RECOVERING$' <<<"$R"; then
  jq -nc '{decision:"block", reason:"This thread had resumed a stale Claude session (one an older handoff plugin /cleared in place). The handoff plugin is restoring it: /handoff:resume from the latest handoff, with your message, in a new session of this thread. No need to resend it."}'
  exit 0
fi
# could not recover. A background-task wake still must not run the stale context (unless this is no T3 Code host, where
# the user picked this session)
log userprompt "recover failed: $(head -1 <<<"$R")"
if [ -n "$WAKE" ] && ! grep -q "^not a T3 Code session" <<<"$R"; then
  block "Handoff plugin: background-task notification for an already handed-off session ($SID); not run here."
fi
# a real message: let it through, but make sure the model knows it is a stale session
jq -nc --arg c "Handoff plugin: this session ($SID) was already handed off; recovering it failed ($(head -1 <<<"$R")). Tell the user the work continues elsewhere (see the SessionStart note) and do not act on stale state." \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
exit 0
