#!/bin/bash
# clear/compact: runs before CLAUDE.md is (re)read -> make sure current.md holds THIS process's handoff.
# startup: CLAUDE.md was already prefetched; if current.md belongs to another live process, tell Claude to ignore it.
source "$(dirname "$0")/handoff-lib.sh"
IN="$(cat)"
SRC="$(jq -r .source <<<"$IN")"; SID="$(jq -r .session_id <<<"$IN")"
log sessionstart "source=$SRC sid=$SID pid=$CPID owner=$(owner_pid)"
case "$SRC" in
  clear|compact)
    MINE="$HANDOFF_DIR/by-pid/$CPID.md"
    if [ -s "$MINE" ]; then
      cp "$MINE" "$CURRENT"; echo "$CPID" > "$OWNER"; log sessionstart "current.md <- by-pid/$CPID.md"
      # Without the CLAUDE.md import, the handoff is loaded on demand: tell Claude it exists.
      if ! grep -qs '@.claude/handoff/current.md' "$ROOT/CLAUDE.md" "$ROOT/.claude/CLAUDE.md" 2>/dev/null; then
        echo "A handoff document from the previous context window of this conversation is staged (written at the user's request before the context was cleared). Before doing anything else, invoke the handoff:resume skill to load it, then continue from its Next steps."
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
