#!/bin/bash
# Opt-in (T3_AUTOCLEAR=true). Called by the Stop hook. Resolves the T3 Code thread that owns THIS Claude
# session, then in the background waits for the thread to go idle and sends it a message:
#   nudge <file>  the handoff-writing instruction, as its OWN turn. T3's timeline shows only the last
#                 assistant message of a turn and folds the rest behind "Worked for …"; an in-turn
#                 (additionalContext) nudge makes the "handoff written" note that last message and hides
#                 the real reply. A separate turn keeps the reply visible.
#   clear         /clear, then /handoff:resume (after the handoff is staged).
#
# Guards (each failure = log a reason, print it on stdout, exit 0 without touching any thread):
#   1. host: this Claude process must have been spawned by T3 Code (bundle id env or a "T3 Code" ancestor).
#      CLI / Cowork / Superset sessions never reach t3ctl even if a T3 thread shares the same directory.
#   2. thread: exact match of this session id against T3's provider_session_runtime (resume cursor) or
#      projection_thread_sessions.provider_session_id in ~/.t3/userdata/state.sqlite (read-only).
#      Fallback (sqlite unavailable): worktreePath / local-env workspaceRoot match, accepted only when unambiguous.
#   3. re-check right before every send: the thread must still map to this session id.
# A send fails when the thread is busy (the user typed something in the idle gap); the helper then waits
# for the next idle and retries until T3_SEND_TIMEOUT seconds (default 600) have passed.
# Usage: t3-autoclear.sh <project root> <hooks.log> <claude session id> [clear | nudge <file>]
#        HANDOFF_T3_DRYRUN=1: resolve and print only, send nothing.
# Verified 2026-09-08 on a disposable local-env thread (sonnet 4.6): wait -> /clear -> /handoff:resume -> resumed turn.

T3DB="${HANDOFF_T3_DB:-$HOME/.t3/userdata/state.sqlite}"
SEND_TIMEOUT="${HANDOFF_T3_SEND_TIMEOUT:-600}"

t3() { T3CTL_AGENT=1 t3ctl "$@"; }
# current Claude session id of a thread per T3's resume cursor (empty when the db is unreadable)
session_of_thread() {
  [ -r "$T3DB" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 -readonly "$T3DB" "select json_extract(resume_cursor_json,'\$.resume') from provider_session_runtime where thread_id='$1'" 2>/dev/null
}

# ---- background worker: t3-autoclear.sh --bg <log> <sid> <tid> <mode> [file]
if [ "$1" = "--bg" ]; then
  LOG="$2"; SID="$3"; TID="$4"; MODE="$5"; FILE="$6"
  logbg() { echo "$(date +%T) [t3] $*" >> "$LOG"; }
  deadline=$(( $(date +%s) + SEND_TIMEOUT ))
  while :; do
    left=$(( deadline - $(date +%s) )); [ "$left" -gt 0 ] || { logbg "gave up after ${SEND_TIMEOUT}s: thread $TID never idle long enough to send ($MODE)"; exit 0; }
    t3 threads wait "$TID" --timeout "$left" >/dev/null 2>&1
    if [ -r "$T3DB" ]; then
      now="$(session_of_thread "$TID")"
      [ "$now" = "$SID" ] || { logbg "thread $TID now maps to session '$now', not $SID; $MODE NOT sent"; exit 0; }
    fi
    case "$MODE" in
      nudge)
        if t3 threads send "$TID" --stdin < "$FILE" >/dev/null 2>&1; then logbg "sent handoff nudge turn to $TID"; exit 0; fi ;;
      clear)
        if t3 threads send "$TID" '/clear' >/dev/null 2>&1; then
          logbg "sent /clear to $TID"; sleep 3
          t3 threads send "$TID" '/handoff:resume' >/dev/null 2>&1 && logbg "sent /handoff:resume to $TID" || logbg "/handoff:resume send to $TID failed; type it manually"
          exit 0
        fi ;;
    esac
    logbg "send ($MODE) to $TID failed (thread busy?); retrying after the next idle"
    sleep 5
  done
fi

# ---- foreground: guards + thread resolution, then spawn the worker
ROOT="$1"; LOG="$2"; SID="${3:-$CLAUDE_CODE_SESSION_ID}"; MODE="${4:-clear}"; FILE="$5"
say() { echo "$(date +%T) [t3] $*" >> "$LOG"; echo "$*"; }
[ "$MODE" = "clear" ] || [ "$MODE" = "nudge" ] || { say "unknown mode '$MODE'; skipped"; exit 0; }
[ "$MODE" = "nudge" ] && [ ! -s "$FILE" ] && { say "nudge file missing; skipped"; exit 0; }

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
t3json() { t3 "$@" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'; }
# fallback: threads whose worktreePath (or, for local-env threads, project workspaceRoot) is $ROOT; running first
threads_for_dir() {
  local status_filter="$1"
  t3json threads list $status_filter | jq -r --arg r "$ROOT" --argjson projects "$(t3json projects || echo '[]')" '
    ($projects | map({key: .id, value: .workspaceRoot}) | from_entries) as $roots
    | [ .[] | select( .worktreePath == $r or ((.worktreePath == null or .worktreePath == "") and $roots[.projectId] == $r) ) ]
    | sort_by(.updatedAt) | reverse | .[].id'
}

command -v t3ctl >/dev/null 2>&1 || { say "t3ctl not on PATH; $MODE skipped"; exit 0; }
is_t3_host || { say "not a T3 Code session (host guard); $MODE skipped, handoff stays manual"; exit 0; }

TID="$(thread_for_session "$SID")"; HOW="session id"
if [ -z "$TID" ]; then
  if [ -r "$T3DB" ]; then
    say "session $SID not found in T3 state db; $MODE skipped"; exit 0
  fi
  C="$(threads_for_dir '-s running')"; [ -z "$C" ] && C="$(threads_for_dir '')"
  N=$(printf '%s\n' "$C" | grep -c .)
  [ "$N" -eq 1 ] || { say "dir match for $ROOT is ambiguous or empty ($N candidates); $MODE skipped"; exit 0; }
  TID="$C"; HOW="dir match (no state db)"
fi
say "$MODE scheduled for thread $TID (matched by $HOW, session $SID)"
[ -n "$HANDOFF_T3_DRYRUN" ] && exit 0

nohup bash "$0" --bg "$LOG" "$SID" "$TID" "$MODE" "$FILE" >/dev/null 2>&1 &
disown 2>/dev/null || true
