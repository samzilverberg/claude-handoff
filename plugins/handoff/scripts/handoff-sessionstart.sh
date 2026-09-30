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
  CB="$(tombstone_get "$SID" continued_by)"; WHEN="$(tombstone_get "$SID" cleared_at)"
  log sessionstart "TOMBSTONED sid=$SID (cleared_at=$WHEN continued_by=${CB:-?}); injecting stop"
  echo "STOP — stale session resume. This session ($SID) was handed off and /cleared${WHEN:+ at $WHEN}${CB:+, and its work continues in session $CB}. This is a leftover resume of an already-superseded session (typically the T3 host resuming the pre-/clear session id after an in-process /clear). Do NOT continue the task, edit files, run tools, or write a handoff — doing so duplicates work the successor session already did. Tell the user this thread was resumed onto a stale, superseded session and stop."
  exit 0
fi

case "$SRC" in
  clear|compact)
    MINE="$HANDOFF_DIR/by-pid/$CPID.md"
    if [ -s "$MINE" ]; then
      cp "$MINE" "$CURRENT"; echo "$CPID" > "$OWNER"; log sessionstart "current.md <- by-pid/$CPID.md"
      # Without the CLAUDE.md import, the handoff is loaded on demand: tell Claude it exists.
      if ! grep -qs '@.claude/handoff/current.md' "$ROOT/CLAUDE.md" "$ROOT/.claude/CLAUDE.md" 2>/dev/null; then
        echo "A handoff document from the previous context window of this conversation is staged (written at the user's request before the context was cleared). Before doing anything else, invoke the handoff:resume skill to load it, then continue from its Next steps."
      fi
    fi
    # Link the just-cleared session (same pid) to this successor, for the zombie-stop note above.
    if [ "$SRC" = "clear" ]; then
      B="$HANDOFF_DIR/state/pid-cleared/$CPID"
      if [ -f "$B" ]; then
        OLD="$(cat "$B" 2>/dev/null)"; [ -n "$OLD" ] && [ "$OLD" != "$SID" ] && tombstone_link "$OLD" "$SID"
        rm -f "$B"
      fi
    fi ;;
  startup|fork|resume)
    O="$(owner_pid)"
    if [ -n "$O" ] && [ "$O" != "$CPID" ] && [ "$(cfg STARTUP ignore)" = "ignore" ]; then
      if kill -0 "$O" 2>/dev/null; then
        echo "Note: the 'Previous conversation' section in the project instructions was staged by a different, still-running Claude Code session (pid $O). It is not this session's history; ignore it unless the user refers to it."
      else
        reset_current   # stale owner is gone; clean up for the next reader (this session already read the stale copy)
        echo "Note: the 'Previous conversation' section in the project instructions is a leftover from an earlier, finished session. It is not this session's history; ignore it unless the user refers to it."
      fi
    fi ;;
esac
exit 0
