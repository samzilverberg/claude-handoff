#!/bin/bash
# clear/compact: runs before CLAUDE.md is (re)read -> make sure current.md holds THIS process's handoff.
# startup: CLAUDE.md was already prefetched; if current.md belongs to another live process, tell Claude to ignore it.
source "$(dirname "$0")/handoff-lib.sh"
IN="$(cat)"
SRC="$(jq -r .source <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"
log sessionstart "source=$SRC sid=$SID pid=$CPID owner=$(owner_pid)"

# Zombie guard: any resume/compact/startup of a session that was already /cleared (tombstoned) is a
# resurrected pre-clear session (e.g. a T3 host resume cursor that never advanced to the new session).
# Tell the model to stop before it re-runs the work; its Stop/PreCompact hooks are inert too.
if [ "$SRC" != "clear" ] && is_tombstoned "$SID"; then
  WHEN="$(tombstone_get "$SID" cleared_at)"; TAIL="$(chain_tail "$SID")"
  log sessionstart "TOMBSTONED sid=$SID (cleared_at=$WHEN tail=$TAIL); injecting stop"
  if [ "$TAIL" != "$SID" ]; then WHERE="in Claude session $TAIL (\`claude --resume $TAIL\` in $ROOT)"
  else WHERE="in a newer session"; fi
  echo "STOP — stale session resume. This session ($SID) was handed off${WHEN:+ at $WHEN}; the work continues $WHERE. This is a leftover resume of an already-superseded session (typically a host resuming the pre-/clear session id). Do NOT continue the task, edit files, run tools, or write a handoff: that duplicates work the successor already did. Tell the user where the work continues (quote the location above) and stop."
  exit 0
fi

# Context lines for the model (plain stdout), or JSON with a user-visible warning when T3 auto-clear is broken.
OUT=""
say_ctx() { OUT="${OUT:+$OUT
}$1"; }

case "$SRC" in
  clear|compact)
    T3_RESUMING=""
    if [ "$SRC" = "clear" ]; then
      # the session this /clear superseded (same pid; bridged by SessionEnd(clear)): link it to this one
      B="$HANDOFF_DIR/state/pid-cleared/$CPID"; OLD="$(cat "$B" 2>/dev/null)"; rm -f "$B"
      if [ -n "$OLD" ] && [ "$OLD" != "$SID" ]; then
        tombstone_link "$OLD" "$SID"
        [ "$(state_get "$(session_key "$OLD")" t3_clear)" = "1" ] && T3_RESUMING=1   # t3.sh sends /handoff:resume itself
        # T3 layer: make the Claude session id T3 resumes for this thread follow this new session
        if [ "$(cfg T3_AUTOCLEAR false)" = "true" ]; then
          HANDOFF_TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$IN")" bash "$(dirname "$0")/t3.sh" "$ROOT" "$LOG" "$SID" alias "$OLD" >/dev/null 2>&1
        fi
        mkdir -p "$HANDOFF_DIR/state/cleared"; echo "$SID" > "$HANDOFF_DIR/state/cleared/$OLD"
      fi
    else
      # compact keeps the session id: start the per-context-window state over (attempt counters, latches)
      rm -f "$HANDOFF_DIR/state/$(session_key "$SID").json"
    fi
    MINE="$HANDOFF_DIR/by-pid/$CPID.md"
    if [ -s "$MINE" ]; then
      cp "$MINE" "$CURRENT"; echo "$CPID" > "$OWNER"; log sessionstart "current.md <- by-pid/$CPID.md"
      # Without the CLAUDE.md import, the handoff is loaded on demand: tell Claude it exists
      # (not when the T3 layer is about to send /handoff:resume itself).
      if [ -z "$T3_RESUMING" ] && ! grep -qs '@.claude/handoff/current.md' "$ROOT/CLAUDE.md" "$ROOT/.claude/CLAUDE.md" 2>/dev/null; then
        say_ctx "A handoff document from the previous context window of this conversation is staged (written at the user's request before the context was cleared). Before doing anything else, invoke the handoff:resume skill to load it, then continue from its Next steps."
      fi
    fi ;;
  startup|fork|resume)
    O="$(owner_pid)"
    if [ -n "$O" ] && [ "$O" != "$CPID" ] && [ "$(cfg STARTUP ignore)" = "ignore" ]; then
      if kill -0 "$O" 2>/dev/null; then
        say_ctx "Note: the 'Previous conversation' section in the project instructions was staged by a different, still-running Claude Code session (pid $O). It is not this session's history; ignore it unless the user refers to it."
      else
        reset_current   # stale owner is gone; clean up for the next reader (this session already read the stale copy)
        say_ctx "Note: the 'Previous conversation' section in the project instructions is a leftover from an earlier, finished session. It is not this session's history; ignore it unless the user refers to it."
      fi
    fi ;;
esac

# T3_AUTOCLEAR preflight on startup/resume: warn now, not first at the threshold. Silent when fine or not a T3 host.
WARN=""
if [ "$SRC" != "clear" ] && [ "$SRC" != "compact" ] && [ "$(cfg T3_AUTOCLEAR false)" = "true" ]; then
  R="$(bash "$(dirname "$0")/t3.sh" "$ROOT" "$LOG" "" check 2>/dev/null)"
  case "$R" in ok:*|"not a T3 Code session"*) ;; *) WARN="handoff: T3_AUTOCLEAR is on but the automatic T3 handoff will not work here ($R). At the threshold you will need to /clear + /handoff:resume by hand." ;; esac
fi
if [ -n "$WARN" ]; then
  if [ -n "$OUT" ]; then jq -nc --arg m "$WARN" --arg c "$OUT" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
  else jq -nc --arg m "$WARN" '{systemMessage:$m}'; fi
elif [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
fi
exit 0
