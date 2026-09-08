#!/bin/bash
# Opt-in (T3_AUTOCLEAR=true). Called by the Stop hook once a handoff is staged. Resolves the T3 Code thread that
# owns THIS Claude session, then in the background: wait for the turn to end, send /clear, send /handoff:resume.
#
# Guards (each failure = log a reason, print it on stdout, exit 0 without touching any thread):
#   1. host: this Claude process must have been spawned by T3 Code (bundle id env or a "T3 Code" ancestor).
#      CLI / Cowork / Superset sessions never reach t3ctl even if a T3 thread shares the same directory.
#   2. thread: exact match of this session id against T3's provider_session_runtime (resume cursor) or
#      projection_thread_sessions.provider_session_id in ~/.t3/userdata/state.sqlite (read-only).
#      Fallback (sqlite unavailable): worktreePath / local-env workspaceRoot match, accepted only when unambiguous.
#   3. re-check right before sending /clear: the thread must still map to this session id.
# Usage: t3-autoclear.sh <project root> <hooks.log> <claude session id>   (HANDOFF_T3_DRYRUN=1: resolve only)
# Verified 2026-09-08 on a disposable local-env thread (sonnet 4.6): wait -> /clear -> /handoff:resume -> resumed turn.
ROOT="$1"; LOG="$2"; SID="${3:-$CLAUDE_CODE_SESSION_ID}"
T3DB="${HANDOFF_T3_DB:-$HOME/.t3/userdata/state.sqlite}"
say() { echo "$(date +%T) [t3] $*" >> "$LOG"; echo "$*"; }

is_t3_host() {
  [ "$__CFBundleIdentifier" = "com.t3tools.t3code" ] && return 0
  local p=$PPID i=0
  while [ $i -lt 6 ] && [ "${p:-0}" -gt 1 ]; do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in *"T3 Code"*|*t3code*|*t3-code*) return 0;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i+1))
  done
  return 1
}
# thread id whose Claude session is $1 (empty when unknown)
thread_for_session() {
  local sid="$1"; [ -n "$sid" ] && [ -r "$T3DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 -readonly "$T3DB" "
    select thread_id from provider_session_runtime where json_extract(resume_cursor_json,'\$.resume')='$sid'
    union select thread_id from projection_thread_sessions where provider_session_id='$sid' limit 1;" 2>/dev/null
}
t3json() { T3CTL_AGENT=1 t3ctl "$@" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'; }
# fallback: threads whose worktreePath (or, for local-env threads, project workspaceRoot) is $ROOT; running first
threads_for_dir() {
  local status_filter="$1"
  t3json threads list $status_filter | jq -r --arg r "$ROOT" --argjson projects "$(t3json projects || echo '[]')" '
    ($projects | map({key: .id, value: .workspaceRoot}) | from_entries) as $roots
    | [ .[] | select( .worktreePath == $r or ((.worktreePath == null or .worktreePath == "") and $roots[.projectId] == $r) ) ]
    | sort_by(.updatedAt) | reverse | .[].id'
}

command -v t3ctl >/dev/null 2>&1 || { say "t3ctl not on PATH; autoclear skipped"; exit 0; }
is_t3_host || { say "not a T3 Code session (host guard); autoclear skipped, /clear stays manual"; exit 0; }

TID="$(thread_for_session "$SID")"; HOW="session id"
if [ -z "$TID" ]; then
  if [ -r "$T3DB" ]; then
    say "session $SID not found in T3 state db; autoclear skipped"; exit 0
  fi
  C="$(threads_for_dir '-s running')"; [ -z "$C" ] && C="$(threads_for_dir '')"
  N=$(printf '%s\n' "$C" | grep -c .)
  [ "$N" -eq 1 ] || { say "dir match for $ROOT is ambiguous or empty ($N candidates); autoclear skipped"; exit 0; }
  TID="$C"; HOW="dir match (no state db)"
fi
say "autoclear scheduled for thread $TID (matched by $HOW, session $SID)"
[ -n "$HANDOFF_T3_DRYRUN" ] && exit 0

nohup bash -c "
  T3CTL_AGENT=1 t3ctl threads wait '$TID' --timeout 600 >/dev/null 2>&1
  if [ -r '$T3DB' ]; then
    now=\$(sqlite3 -readonly '$T3DB' \"select json_extract(resume_cursor_json,'\\\$.resume') from provider_session_runtime where thread_id='$TID'\" 2>/dev/null)
    [ \"\$now\" = '$SID' ] || { echo \"\$(date +%T) [t3] thread $TID now maps to session '\$now', not $SID; /clear NOT sent\" >> '$LOG'; exit 0; }
  fi
  T3CTL_AGENT=1 t3ctl threads send '$TID' '/clear' >/dev/null 2>&1 && echo \"\$(date +%T) [t3] sent /clear to $TID\" >> '$LOG'
  sleep 3
  T3CTL_AGENT=1 t3ctl threads send '$TID' '/handoff:resume' >/dev/null 2>&1 && echo \"\$(date +%T) [t3] sent /handoff:resume to $TID\" >> '$LOG'
" >/dev/null 2>&1 &
disown 2>/dev/null || true
