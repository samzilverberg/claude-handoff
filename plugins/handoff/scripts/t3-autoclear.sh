#!/bin/bash
# Opt-in (T3_AUTOCLEAR=true). Called by the Stop hook. Resolves the T3 Code thread that owns THIS Claude
# session, then in the background waits for the thread to go idle and sends it a message:
#   nudge <file>  the handoff-writing instruction, as its OWN turn. T3's timeline shows only the last
#                 assistant message of a turn and folds the rest behind "Worked for …"; an in-turn
#                 (additionalContext) nudge makes the "handoff written" note that last message and hides
#                 the real reply. A separate turn keeps the reply visible.
#   clear         /clear, then /handoff:resume (after the handoff is staged).
#   check         preflight only (plus thread resolution when a session id is given); prints "ok: …" or the
#                 reason, exit 0/1. Used by SessionStart and /handoff:status.
#
# Requires T3 Code (Beta) >= 0.1.0: its state db is ~/.t3/userdata/statev2.sqlite. Older T3 (state.sqlite
# only) is refused with a message; there is no fallback.
#
# Guards (each failure = log a reason, print it on stdout, exit 0 without touching any thread):
#   1. preflight: host is T3 Code (bundle id env or a "T3 Code" ancestor), so CLI / Cowork / Superset
#      sessions never reach t3ctl; t3ctl on PATH; sqlite3 on PATH; statev2.sqlite present and readable with the
#      expected table/columns; T3 server reachable via `t3ctl env`, supported, version >= MIN_T3.
#   2. thread: exact match of this session id against
#      orchestration_v2_projection_provider_threads.payload_json.nativeThreadRef.nativeId (read-only).
#      T3 v2 does not follow /clear: the thread keeps the pre-clear Claude session id. So when this session id
#      is unknown, walk back our own tombstone chain (old sid -> continued_by -> new sid) to the ancestor T3
#      knows. The thread must also be visible (not missing/archived) via t3ctl.
#   3. re-check right before every send: the thread must still map to the matched (ancestor) session id.
# A send fails when the thread is busy (the user typed something in the idle gap); the helper then waits
# for the next idle and retries until T3_SEND_TIMEOUT seconds (default 600) have passed.
# Usage: t3-autoclear.sh <project root> <hooks.log> <claude session id> [clear | nudge <file> | check]
#        HANDOFF_T3_DRYRUN=1: resolve and print only, send nothing. HANDOFF_T3_DB: override the db path.

T3DB="${HANDOFF_T3_DB:-$HOME/.t3/userdata/statev2.sqlite}"
LEGACY_DB="$HOME/.t3/userdata/state.sqlite"
MIN_T3="0.1.0"
SEND_TIMEOUT="${HANDOFF_T3_SEND_TIMEOUT:-600}"
V2T=orchestration_v2_projection_provider_threads
NEED="T3_AUTOCLEAR needs T3 Code (Beta) >= $MIN_T3 (state db statev2.sqlite)"

t3() { T3CTL_AGENT=1 t3ctl "$@"; }
# foreground reads run inside the Stop/SessionStart hook timeouts (15/10 s): cap each at 5 s (perl ships with macOS)
t3json() { T3CTL_AGENT=1 perl -e 'alarm shift; exec @ARGV' 5 t3ctl "$@" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'; }
DBERR="$(mktemp -t handoff-t3db)"; trap 'rm -f "$DBERR"' EXIT
# q <sql>: read-only query, 2 s busy timeout; stderr kept in $DBERR (first line via dberr)
q() { sqlite3 -readonly -cmd ".timeout 2000" "$T3DB" "$1" 2>"$DBERR"; }
dberr() { head -1 "$DBERR" 2>/dev/null; }
# Claude session id T3 has on record for a thread (empty when none or on a db error; see $DBERR)
session_of_thread() { q "select json_extract(payload_json,'\$.nativeThreadRef.nativeId') from $V2T where thread_id='$1' order by updated_at desc limit 1"; }

# ---- background worker: t3-autoclear.sh --bg <log> <sid> <tid> <mode> [file]
if [ "$1" = "--bg" ]; then
  LOG="$2"; SID="$3"; TID="$4"; MODE="$5"; FILE="$6"
  logbg() { echo "$(date +%T) [t3] $*" >> "$LOG"; }
  deadline=$(( $(date +%s) + SEND_TIMEOUT ))
  while :; do
    left=$(( deadline - $(date +%s) )); [ "$left" -gt 0 ] || { logbg "gave up after ${SEND_TIMEOUT}s: thread $TID never idle long enough to send ($MODE); type it manually"; exit 0; }
    out="$(t3 threads wait "$TID" --timeout "$left" 2>&1)" || logbg "t3ctl threads wait $TID failed (rc=$?): $(printf '%s' "$out" | tr -d '\n' | cut -c1-200)"
    now="$(session_of_thread "$TID")"
    if [ -z "$now" ]; then
      if [ -s "$DBERR" ]; then logbg "cannot read T3 db $T3DB ($(dberr)); $MODE NOT sent"
      else logbg "thread $TID has no Claude session in the T3 db anymore; $MODE NOT sent"; fi
      exit 0
    fi
    [ "$now" = "$SID" ] || { logbg "thread $TID now maps to session '$now', not $SID; $MODE NOT sent"; exit 0; }
    case "$MODE" in
      nudge) out="$(t3 threads send "$TID" --stdin < "$FILE" 2>&1)" && { logbg "sent handoff nudge turn to $TID"; exit 0; } ;;
      clear)
        if out="$(t3 threads send "$TID" '/clear' 2>&1)"; then
          logbg "sent /clear to $TID"; sleep 3
          if out="$(t3 threads send "$TID" '/handoff:resume' 2>&1)"; then logbg "sent /handoff:resume to $TID"
          else logbg "/handoff:resume send to $TID failed ($(printf '%s' "$out" | tr -d '\n' | cut -c1-200)); type it manually"; fi
          exit 0
        fi ;;
    esac
    logbg "send ($MODE) to $TID failed (thread busy?): $(printf '%s' "$out" | tr -d '\n' | cut -c1-200); retrying after the next idle"
    sleep 5
  done
fi

# ---- foreground: preflight + thread resolution, then spawn the worker
ROOT="$1"; LOG="$2"; SID="${3:-$CLAUDE_CODE_SESSION_ID}"; MODE="${4:-clear}"; FILE="$5"
say() { echo "$(date +%T) [t3] $*" >> "$LOG"; echo "$*"; }
# skip <reason>: log + print; check mode exits 1, the others 0 (the Stop hook reads the text, not the code)
skip() { if [ "$MODE" = "check" ]; then say "$1"; exit 1; fi; say "$1; $MODE skipped"; exit 0; }
case "$MODE" in clear|nudge|check) ;; *) say "unknown mode '$MODE'; skipped"; exit 0;; esac
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
# thread id whose Claude session is $1 (empty when unknown or on a db error)
thread_for_session() { q "select thread_id from $V2T where json_extract(payload_json,'\$.nativeThreadRef.nativeId')='$1' order by updated_at desc limit 1"; }
# session that was /cleared into $1, per our tombstones (old.json has continued_by=<new>); empty when none
predecessor_of() {
  local f; f="$(grep -l "\"continued_by\" *: *\"$1\"" "$ROOT/.claude/handoff/state/tombstones/"*.json 2>/dev/null | head -1)"
  [ -n "$f" ] && basename "$f" .json
}
# version_ge A B: A >= B (dotted numeric, pre-release suffix ignored)
version_ge() { [ "$(printf '%s\n%s\n' "${2%%-*}" "${1%%-*}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "${2%%-*}" ]; }

# 1. preflight
is_t3_host || skip "not a T3 Code session (host guard), handoff stays manual"
command -v t3ctl >/dev/null 2>&1 || skip "t3ctl not on PATH (install: https://github.com/samzilverberg/t3ctl)"
command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not on PATH"
if [ ! -e "$T3DB" ]; then
  [ -z "$HANDOFF_T3_DB" ] && [ -e "$LEGACY_DB" ] && skip "only the legacy T3 db $LEGACY_DB exists, no statev2.sqlite: T3 Code too old; $NEED"
  skip "T3 state db $T3DB not found; $NEED"
fi
[ -r "$T3DB" ] || skip "T3 state db $T3DB not readable"
COLS="$(q "select group_concat(name) from pragma_table_info('$V2T')")" || skip "cannot read T3 db $T3DB ($(dberr))"
[ -n "$COLS" ] || skip "T3 db $(basename "$T3DB") has no table $V2T (T3 Code db layout changed?); $NEED"
for c in thread_id updated_at payload_json; do
  case ",$COLS," in *",$c,"*) ;; *) skip "T3 db table $V2T lacks column $c (T3 Code db layout changed?)";; esac
done
ENV="$(t3json env)"
VER="$(jq -r '.serverVersion // empty' <<<"$ENV" 2>/dev/null)"
if [ -z "$VER" ]; then
  skip "T3 Code server not reachable via t3ctl within 5 s ($(jq -r '.error.code // .error.message // empty' <<<"$ENV" 2>/dev/null || true)); is T3 Code running?"
fi
[ "$(jq -r '.supported' <<<"$ENV" 2>/dev/null)" = "false" ] && skip "T3 Code server $VER is not supported by this t3ctl (update t3ctl or T3 Code)"
version_ge "$VER" "$MIN_T3" || skip "T3 Code server $VER < $MIN_T3; $NEED"

if [ "$MODE" = "check" ] && [ -z "$3" ]; then say "ok: T3 Code $VER, $(basename "$T3DB") readable, t3ctl reachable"; exit 0; fi

# 2. thread resolution
[ -n "$SID" ] || skip "no Claude session id"
TID="$(thread_for_session "$SID")"; HOW="session id"; MSID="$SID"
[ -s "$DBERR" ] && skip "cannot read T3 db $T3DB ($(dberr))"
# T3 v2 keeps the pre-clear session id: follow our /clear chain back to an ancestor it knows (bounded)
hops=0; cur="$SID"
while [ -z "$TID" ] && [ $hops -lt 20 ]; do
  cur="$(predecessor_of "$cur")"; [ -n "$cur" ] || break
  hops=$((hops+1)); TID="$(thread_for_session "$cur")"
  [ -n "$TID" ] && { MSID="$cur"; HOW="pre-clear ancestor $cur, $hops /clear(s) back"; }
done
if [ -z "$TID" ]; then
  N="$(q "select count(*) from $V2T")"; K="$(q "select count(*) from $V2T where json_extract(payload_json,'\$.nativeThreadRef.nativeId') is not null")"
  [ "${N:-0}" -gt 0 ] && [ "${K:-0}" -eq 0 ] && skip "T3 db rows carry no payload_json.nativeThreadRef.nativeId (T3 Code db layout changed?)"
  skip "session $SID (and its pre-clear ancestors) not found in T3 state db $(basename "$T3DB")"
fi
ST="$(t3json threads list -i "$TID" | jq -r '.[0].status // empty' 2>/dev/null)"
case "$ST" in
  "")       skip "could not read thread $TID status via t3ctl" ;;
  missing)  skip "T3 db maps session to thread $TID but T3 Code does not know that thread (deleted?)" ;;
  archived) skip "thread $TID is archived" ;;
esac
[ "$MODE" = "check" ] && { say "ok: T3 Code $VER; session $SID -> thread $TID ($ST, matched by $HOW)"; exit 0; }
say "$MODE scheduled for thread $TID (matched by $HOW, session $SID)"
[ -n "$HANDOFF_T3_DRYRUN" ] && exit 0

nohup bash "$0" --bg "$LOG" "$MSID" "$TID" "$MODE" "$FILE" >/dev/null 2>&1 &
disown 2>/dev/null || true
