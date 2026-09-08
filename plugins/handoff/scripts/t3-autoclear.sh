#!/bin/bash
# Opt-in (T3_AUTOCLEAR=true). Called by the Stop hook once a handoff is staged. Finds the T3 Code thread whose
# worktreePath is this project dir, then in the background: wait for the turn to end, send /clear, send /handoff:resume.
# Verified 2026-09-08 on a disposable local-env thread (sonnet 4.6): wait -> /clear -> /handoff:resume -> resumed turn. Logs to hooks.log.
ROOT="$1"; LOG="$2"
command -v t3ctl >/dev/null 2>&1 || { echo "$(date +%T) [t3] t3ctl not on PATH" >> "$LOG"; exit 0; }
# Match this project dir to a thread: worktree threads carry worktreePath; local-env threads have none, so fall
# back to the project's workspaceRoot. Prefer the running thread (the Stop hook runs while the turn is still open).
find_thread() {
  local status_filter="$1"
  T3CTL_AGENT=1 t3ctl threads list $status_filter 2>/dev/null | tr -d '\000-\010\013\014\016-\037' | jq -r --arg r "$ROOT" --argjson projects "$(T3CTL_AGENT=1 t3ctl projects 2>/dev/null | tr -d '\000-\010\013\014\016-\037' || echo '[]')" '
    ($projects | map({key: .id, value: .workspaceRoot}) | from_entries) as $roots
    | [ .[] | select( .worktreePath == $r or ((.worktreePath == null or .worktreePath == "") and $roots[.projectId] == $r) ) ]
    | sort_by(.updatedAt) | reverse | .[0].id // empty'
}
TID="$(find_thread '-s running')"; [ -z "$TID" ] && TID="$(find_thread '')"
[ -z "$TID" ] && { echo "$(date +%T) [t3] no thread with worktreePath=$ROOT" >> "$LOG"; exit 0; }
echo "$(date +%T) [t3] autoclear scheduled for thread $TID" >> "$LOG"
nohup bash -c "
  T3CTL_AGENT=1 t3ctl threads wait '$TID' --timeout 600 >/dev/null 2>&1
  T3CTL_AGENT=1 t3ctl threads send '$TID' '/clear' >/dev/null 2>&1 && echo \"\$(date +%T) [t3] sent /clear to $TID\" >> '$LOG'
  sleep 3
  T3CTL_AGENT=1 t3ctl threads send '$TID' '/handoff:resume' >/dev/null 2>&1 && echo \"\$(date +%T) [t3] sent /handoff:resume to $TID\" >> '$LOG'
" >/dev/null 2>&1 &
disown 2>/dev/null || true
