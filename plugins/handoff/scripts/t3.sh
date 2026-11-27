#!/bin/bash
# T3 Code layer (opt-in: T3_AUTOCLEAR=true). The base plugin works anywhere: hooks write and stage the handoff and
# the user types /clear + /handoff:resume. Under T3 Code this helper drives the handoff with t3ctl, inside the same
# thread, and keeps T3's view of the thread pointed at the live Claude session. Two flows, picked in the preflight:
#   fresh  (T3 Code >= 0.1.9, server capability freshContext): one "/handoff:resume" sent with `t3ctl threads send
#          --fresh`. T3 starts a new Claude session (new process, SessionStart(startup)) in the same thread and records
#          its id itself: no alias, no stale resume. The new session adopts the doc staged for the thread
#          (by-thread/<thread>.md, see publish in handoff-lib.sh).
#   clear  (older T3, or HANDOFF_T3_FRESH=false): "/clear" + "/handoff:resume" as plain text, with the alias below
#          on T3 < 0.1.10.
#
#   check [sid]            preflight (+ thread resolution with a sid); prints "ok: …" or the reason, exit 0/1.
#   nudge <file>           send the handoff-writing request to this thread as its OWN turn (T3 shows only a turn's
#                          last assistant message; an in-turn nudge would hide the real reply behind "Worked for …").
#   clear <doc>            once the handoff is staged: when the thread is idle, fresh flow: send "/handoff:resume" in
#                          a fresh session and wait for it to adopt the doc; clear flow: send "/clear", wait for the
#                          new session (SessionStart(clear) + alias), then send "/handoff:resume".
#                          HANDOFF_FRESH_MODEL / HANDOFF_FRESH_EFFORT (/handoff:now): `-m` / `-e` on that send.
#   model <ref> <effort>   (/handoff:now) resolve a model / effort for the fresh session; see the mode below.
#   alias <old sid>        (SessionStart(clear), sid = the new session) point the Claude session id T3 resumes for
#                          this thread at the new session's transcript (see below). Local only: db + files.
#   recover <prompt-file>  (UserPromptSubmit of a tombstoned session that T3 resumed: a /clear before 0.6 or a
#                          failed alias) stage the newest handoff of its /clear chain with a digest of the later
#                          transcripts inlined, then the handoff as above (fresh or /clear) with the prompt.
#
# The alias (clear flow only). T3 Code (Beta) 0.1.x records a thread's Claude session id once (statev2.sqlite,
# payload_json.nativeThreadRef.nativeId = R) and ignores the new id a /clear mints; whenever it respawns the process
# (idle reap, app restart) it runs `resume: R`. So after each /clear, R's transcript <R>.jsonl becomes a symlink to
# the new session's transcript (the original is kept as <R>.jsonl.pre-handoff): a respawn loads the live context,
# appends through the link, and keeps reporting id R, which is what T3 expects. Plugin state and handoff docs of the
# post-/clear sessions are keyed by R (state/aliased-by/<sid>), so they carry over such a respawn. Checked first:
# T3 pins no conversation head for the thread (resumeSessionAt would name a message the link hides), <R>.jsonl is in
# the same transcript dir as the new session (same project), and R is not already the new session (a T3 that follows
# /clear itself needs no alias).
# T3 Code >= 0.1.10 (pingdotgg/t3code#35054) follows a Claude-side /clear itself: it records the new session id when
# Claude reports it (system/init) and the next turn reopens the process on it. There the alias is skipped (asked from
# the server version: SessionStart(clear) runs before T3 has recorded the new id, so the db cannot tell yet) and a
# background check logs whether T3 did record it. Without a reachable server the alias is made as before.
#
# Requires T3 Code (Beta) >= 0.1.0 (state db ~/.t3/userdata/statev2.sqlite, read-only) and t3ctl. Every failure
# is logged ([t3] in hooks.log) and printed; nothing is sent or linked then.
# Guards: host is T3 Code; t3ctl/sqlite3 present; db, table, columns and payload shape as expected; server reachable,
# supported, >= MIN_T3 (alias: version only, best effort); thread resolved by exact Claude session id
# (nativeThreadRef.nativeId), via the alias map, or via our /clear tombstone chain; the thread's workspace is this
# project dir; the mapping is re-checked right before every send.
# Codex (HANDOFF_AGENT=codex, from scripts/codex-stop.sh): nudge and clear only, fresh flow only. Codex runs one
# app-server for every T3 thread (no T3CODE_THREAD_ID), so the thread comes from the db by the Codex session id
# (nativeThreadRef.nativeId), and the fresh session gets the handoff document inline as its first message (no
# /handoff:resume skill, no adoption): `clear <doc>` sends "[handoff plugin] … <doc>" with --fresh, then waits for T3
# to record the new Codex session for the thread and tombstones the old one.
# Usage: t3.sh <project root> <hooks.log> <claude session id> <mode> [arg]
#        HANDOFF_T3_FRESH=false: use the clear flow even where T3 offers fresh sessions.
#        HANDOFF_T3_DRYRUN=1: resolve and print only. HANDOFF_T3_DB: db path override. HANDOFF_T3_SEND_TIMEOUT (600).
#        HANDOFF_TRANSCRIPT: transcript path of <session id> (alias, recover). HANDOFF_T3_CLEAR_WAIT: seconds to wait
#        for the new session after /clear or the fresh send (30).

T3DB="${HANDOFF_T3_DB:-$HOME/.t3/userdata/statev2.sqlite}"
LEGACY_DB="$HOME/.t3/userdata/state.sqlite"
MIN_T3="0.1.0"
FOLLOWS_CLEAR="0.1.10"   # first T3 Code that records the session a Claude-side /clear starts (#35054)
SEND_TIMEOUT="${HANDOFF_T3_SEND_TIMEOUT:-600}"
V2T=orchestration_v2_projection_provider_threads
NEED="T3 automation needs T3 Code (Beta) >= $MIN_T3 (state db statev2.sqlite)"

t3() { T3CTL_AGENT=1 t3ctl "$@"; }
# foreground reads run inside hook timeouts: cap each at 5 s (perl ships with macOS)
t3json() { T3CTL_AGENT=1 perl -e 'alarm shift; exec @ARGV' 5 t3ctl "$@" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'; }
DBERR="$(mktemp -t handoff-t3db)"; trap 'rm -f "$DBERR"' EXIT
q() { sqlite3 -readonly -cmd ".timeout 2000" "$T3DB" "$1" 2>"$DBERR"; }
dberr() { head -1 "$DBERR" 2>/dev/null; }
oneline() { tr -d '\n' | cut -c1-240; }
# refusal <t3ctl output>: the readable reason of a failed command. T3 0.1.10 wraps it: .error.message is
# "orchestration.dispatchCommand failed: [{…"message":"<reason>",…}]"; take the inner message when there is one.
refusal() {
  local m i; m="$(printf '%s' "$1" | jq -r '.error.message // empty' 2>/dev/null | head -1)"
  i="$(printf '%s' "$m" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | head -1)"
  m="${i:-$m}"; [ -n "$m" ] || m="$1"; printf '%s' "$m" | oneline
}
RUNS=orchestration_v2_projection_runs; MSGS=orchestration_v2_projection_messages; T3THR=orchestration_v2_projection_threads
# session_of_thread <tid>: the Claude session T3 routes the thread's next user message to (empty when none or on a db
# error; see $DBERR). A thread keeps one provider-thread row per session; a fresh session adds one. Neither the newest
# updated_at, nor the thread's active pointer, nor the highest lastRunOrdinal is safe: a replaced session whose process
# is still alive (background work) bumps its row, takes the active pointer back and (0.1.12) gets its wake runs
# attributed to it whenever Claude wakes it (thread 569772de, 2026-11-24). T3 itself (0.1.12, #38824) routes a user
# message to the newest session started at or after the thread's last fresh start: the highest ordinal of a run with
# freshContext that is not queued, not cancelled before it started, and not started by a scheduled task. A wake can't
# move that boundary and the replaced row started before it. Mirrored here: rows started at or after the boundary
# (and not by a scheduled task's fresh run: T3 treats those as side conversations) first, then the active pointer, then lastRunOrdinal, then updated_at. Without the runs/threads tables (older T3,
# tests) the ordinal and updated_at keys remain.
T3SQL_MODE=""
t3sql_mode() {
  [ -n "$T3SQL_MODE" ] && return 0
  local n; n="$(q "select (select count(*) from sqlite_master where name in ('$RUNS','$MSGS','$T3THR')) || ',' || (select count(*) from pragma_table_info('$V2T') where name='provider_thread_id')")"
  case "$n" in "3,1") T3SQL_MODE=full;; *) T3SQL_MODE=basic;; esac
}
session_of_thread() {
  t3sql_mode
  if [ "$T3SQL_MODE" = full ]; then
    q "with b as (select coalesce(max(r.ordinal),0) as o from $RUNS r left join $MSGS m on m.message_id=json_extract(r.payload_json,'\$.userMessageId')
         where r.thread_id='$1' and json_extract(r.payload_json,'\$.freshContext')=1 and r.status<>'queued'
           and not (r.status='cancelled' and json_extract(r.payload_json,'\$.startedAt') is null)
           and json_extract(m.payload_json,'\$.scheduledTaskId') is null),
       s as (select r.ordinal as o from $RUNS r join $MSGS m on m.message_id=json_extract(r.payload_json,'\$.userMessageId')
         where r.thread_id='$1' and json_extract(r.payload_json,'\$.freshContext')=1 and json_extract(m.payload_json,'\$.scheduledTaskId') is not null)
       select json_extract(p.payload_json,'\$.nativeThreadRef.nativeId') from $V2T p cross join b left join $T3THR t on t.thread_id=p.thread_id
       where p.thread_id='$1'
       order by (coalesce(json_extract(p.payload_json,'\$.firstRunOrdinal'),-1) >= b.o and coalesce(json_extract(p.payload_json,'\$.firstRunOrdinal'),-1) not in (select o from s)) desc,
                (p.provider_thread_id = t.active_provider_thread_id) desc,
                coalesce(json_extract(p.payload_json,'\$.lastRunOrdinal'),-1) desc, p.updated_at desc limit 1"
  else
    q "select json_extract(payload_json,'\$.nativeThreadRef.nativeId') from $V2T where thread_id='$1' order by coalesce(json_extract(payload_json,'\$.lastRunOrdinal'),-1) desc, updated_at desc limit 1"
  fi
}
# active_session_of_thread <tid>: the session of the thread's active pointer: whose background work T3 checks before
# it starts a fresh session (0.1.12: only the active pointer's process, not other live processes of the thread). Can
# differ from session_of_thread when a replaced session's process took the pointer back. Basic layout: session_of_thread.
active_session_of_thread() {
  t3sql_mode
  if [ "$T3SQL_MODE" = full ]; then
    q "select json_extract(p.payload_json,'\$.nativeThreadRef.nativeId') from $T3THR t join $V2T p on p.provider_thread_id=t.active_provider_thread_id where t.thread_id='$1' limit 1"
  else session_of_thread "$1"; fi
}
thread_json() { t3json threads list -i "$1" | jq -c '.[0] // empty' 2>/dev/null; }

# plugin state (tombstones, logs) lives in the project's .claude/handoff; reuse the hook library for it
ROOT="$1"; LOG_ARG="$2"
export CLAUDE_PROJECT_DIR="$ROOT"
# shellcheck disable=SC1091
source "$(dirname "$0")/handoff-lib.sh"
[ -n "$LOG_ARG" ] && LOG="$LOG_ARG"
SID="${3:-}"; MODE="${4:-}"; ARG="$5"
say() { echo "$(date +%T) [t3] $*" >> "$LOG"; echo "$*"; }
logq() { echo "$(date +%T) [t3] $*" >> "$LOG"; }

# ---- background worker: t3.sh <root> <log> <msid> --bg <nudge|clear|fresh> <tid> <file> [live sid]
# msid = the session id T3 maps the thread to (re-checked before every send); live sid = the session running the
# hooks. clear/fresh: <file> = /handoff:resume arguments (may be empty).
if [ "$MODE" = "--bg" ]; then
  BMODE="$5"; TID="$6"; FILE="$7"; LIVE="${8:-$SID}"
  OUTCOME="$HANDOFF_DIR/state/$LIVE.t3clear"
  STARTED="$(date +%s)"
  deadline=$(( STARTED + SEND_TIMEOUT ))
  WHYNOT=""   # why the last send_when_idle gave up (for the outcome)
  # /handoff:now: model / effort for the fresh session (t3.sh model output, "-" = the thread's own). T3 keeps them
  # on the thread for later turns.
  MSEL=(); [ -n "${HANDOFF_FRESH_MODEL:-}" ] && [ "$HANDOFF_FRESH_MODEL" != - ] && MSEL+=(-m "$HANDOFF_FRESH_MODEL")
  [ -n "${HANDOFF_FRESH_EFFORT:-}" ] && [ "$HANDOFF_FRESH_EFFORT" != - ] && MSEL+=(-e "$HANDOFF_FRESH_EFFORT")
  PRESEND=""  # name of a check run right before each send: prints a reason when the send is no longer wanted
  BGASK=""; BGASKED=0   # fresh flow: ask the agent (once per handoff) to end background work T3 refuses a fresh session for
  BGMARK="background agents or commands"   # T3's refusal text (0.1.9 … 0.1.12)
  BGASKF="$HANDOFF_DIR/state/$LIVE.bgask"   # the ask went out for this handoff (cap: one; t3.sh clear starts over)
  # ask_end_background <refusal>: one normal turn (no --fresh) asking the agent to stop background work it no longer
  # needs; the fresh send is retried after that turn. Only when it reaches the session whose background work T3 checks:
  # T3 routes the ask (a user message) to session_of_thread, and checks the background work of the active pointer's
  # session (active_session_of_thread); both must be this session ($SID). Otherwise the ask lands in a session that has
  # nothing to stop (thread 569772de: six asks went to the new session, which had none). At most one per handoff (one
  # sent ask; up to 3 attempts while the ask itself cannot be sent).
  ask_end_background() {
    local f="$HANDOFF_DIR/state/$LIVE.bgask.txt" out now act
    if [ -e "$BGASKF" ]; then BGASKED=3; logq "request to end background work not repeated: already sent once for this handoff ($(cat "$BGASKF"))"; return 0; fi
    now="$(session_of_thread "$TID")"; act="$(active_session_of_thread "$TID")"
    if [ "$now" != "$SID" ]; then BGASKED=3; logq "request to end background work NOT sent to $TID: the thread maps to session '$now', not $SID whose fresh session T3 refused"; return 0; fi
    if [ -n "$act" ] && [ "$act" != "$SID" ]; then
      BGASKED=3; logq "request to end background work NOT sent to $TID: T3 refuses because of the background work of session $act (its active session pointer: an earlier session of the thread whose process is still alive), not of $SID; the fresh session can start once that work ends"
      echo "pending: T3 refuses the fresh session while session $act, an earlier session of this thread whose process is still alive, runs background agents or commands (since $(date +%H:%M)); the plugin retries until ${SEND_TIMEOUT}s after scheduling" > "$OUTCOME"
      return 0
    fi
    printf '[handoff plugin] The handoff document is written and staged, but T3 Code will not start the fresh session for it while this session still runs background work (T3: "%s"). Stop the background agents, monitors and commands that are no longer needed (TaskStop; for a background shell, KillShell or kill). If one must finish first, say which one and why in one line and leave it running. Do not start new work. Then end your turn: the plugin retries the fresh session once this thread is idle.\n' "$1" > "$f"
    out="$(t3 threads send "$TID" --stdin < "$f" 2>&1)" && { BGASKED=3; echo "session $SID, $(date +%T)" > "$BGASKF"; logq "asked the agent in $TID to end its background work (fresh session refused while it runs)"; return 0; }
    BGASKED=$((BGASKED+1)); logq "request to end background work not sent to $TID: $(printf '%s' "$out" | oneline)"
  }
  # send_when_idle <what> <text-file> [t3ctl send flags…]: wait for idle, re-check the mapping (and $PRESEND), send;
  # retry while busy (a run, or for --fresh: background agents/commands T3 will not end). 0 = sent, 2 = no longer
  # wanted ($PRESEND; reason in WHYNOT), 1 = not sent.
  send_when_idle() {
    local out left now rc what="$1" txt="$2" last="" why; shift 2
    while :; do
      left=$(( deadline - $(date +%s) ))
      if [ "$left" -le 0 ]; then
        WHYNOT="gave up after ${SEND_TIMEOUT}s${last:+, last refusal: $last}"
        logq "gave up after ${SEND_TIMEOUT}s: thread $TID never accepted $what${last:+ (last refusal: $last)}"; return 1
      fi
      out="$(t3 threads wait "$TID" --timeout "$left" 2>&1)" || logq "t3ctl threads wait $TID failed (rc=$?): $(printf '%s' "$out" | oneline)"
      if [ -n "$PRESEND" ] && why="$($PRESEND)" && [ -n "$why" ]; then WHYNOT="$why"; return 2; fi
      now="$(session_of_thread "$TID")"
      if [ -z "$now" ]; then
        if [ -s "$DBERR" ]; then logq "cannot read T3 db $T3DB ($(dberr)); $1 NOT sent"; else logq "thread $TID has no Claude session in the T3 db anymore; $1 NOT sent"; fi
        return 1
      fi
      [ "$now" = "$SID" ] || { WHYNOT="thread now maps to session $now"; logq "thread $TID now maps to session '$now', not $SID; $what NOT sent"; return 1; }
      out="$(t3 threads send "$TID" "$@" --stdin < "$txt" 2>&1)"; rc=$?
      [ $rc -eq 0 ] && return 0
      last="$(refusal "$out")"
      # exit 7 = incompatible server (e.g. --fresh without freshContext): retrying cannot help
      [ $rc -eq 7 ] && { WHYNOT="T3 refused: $last"; logq "$what to $TID refused (incompatible server): $last"; return 1; }
      logq "$what to $TID failed (thread busy?): $last; retrying after the next idle"
      case "$out" in *"$BGMARK"*)
        if [ -n "$BGASK" ]; then
          # tell the user too: the Stop hook's note shows the outcome while it is pending (ask_end_background may name
          # another session instead)
          grep -qs "^pending: T3 refuses" "$OUTCOME" || echo "pending: T3 refuses the fresh session while this session runs background agents or commands (since $(date +%H:%M)); stop them or press Stop, the plugin retries until ${SEND_TIMEOUT}s after scheduling" > "$OUTCOME"
          [ "$BGASKED" -lt 3 ] && ask_end_background "$last"
        fi;;
      esac
      sleep 5
    done
  }
  # nudge_obsolete: the handoff-writing request is no longer wanted: the session was handed off, or the handoff itself
  # got scheduled after this worker started (thread 569772de: a second Stop's nudge waited out the first nudge's turn and
  # went out in the same second as the fresh /handoff:resume, re-running the request in the replaced session)
  nudge_obsolete() {
    is_tombstoned "$LIVE" && { echo "session $LIVE was already handed off"; return 0; }
    [ "$FILE" = "$HANDOFF_DIR/state/$LIVE.nudge.txt" ] || return 0   # other turns (a held message released) still go
    [ -e "$OUTCOME" ] && [ "$(mtime "$OUTCOME")" -ge "$STARTED" ] && echo "the handoff is already scheduled ($(head -c 100 "$OUTCOME" | oneline))"
    return 0
  }
  # fresh_obsolete: the doc staged for the thread is gone before the fresh send: a compact (or a /clear) of the live
  # session consumed it, so the context is small again and the fresh session would have nothing to adopt (thread
  # 383ac993: the agent's background-work turn auto-compacted, then the worker kept retrying for 600s)
  fresh_obsolete() {
    [ -s "$BYTHREAD/$(printf '%s' "$TID" | tr '/' '_').md" ] || echo "the handoff document staged for thread $TID is gone (consumed by a compact or /clear of session $LIVE)"
    return 0
  }
  case "$BMODE" in
    follow)
      # alias skipped because T3 follows /clear itself: check (log only) that it records the new session $SID
      i=0; while [ "$(session_of_thread "$TID")" != "$SID" ] && [ $i -lt $(( ${HANDOFF_T3_CLEAR_WAIT:-30} * 2 )) ]; do sleep 0.5; i=$((i+1)); done
      now="$(session_of_thread "$TID")"
      if [ "$now" = "$SID" ]; then logq "T3 records the post-/clear session $SID for thread $TID"
      else logq "WARNING: T3 still maps thread $TID to '$now', not the post-/clear session $SID: a respawn would resume the pre-clear context (no alias was made: T3 Code $FILE)"; fi
      exit 0 ;;
    nudge)
      PRESEND=nudge_obsolete; send_when_idle "handoff nudge" "$FILE"; rc=$?
      [ $rc -eq 0 ] && logq "sent handoff nudge turn to $TID"
      [ $rc -eq 2 ] && logq "handoff nudge to $TID dropped: $WHYNOT"
      rm -f "$HANDOFF_DIR/state/$LIVE.nudge-pending"; exit 0 ;;
    fresh)
      if [ "$AGENT" = codex ]; then
        fail() { echo "failed:$1" > "$OUTCOME"; logq "codex handoff of $TID failed: $1"; exit 0; }
        Rf="$HANDOFF_DIR/state/$LIVE.resume-msg.txt"
        { printf '[handoff plugin] This T3 thread continues in a fresh context. Below is the handoff document that the previous context of this conversation wrote just before it was cleared (saved at %s). Treat it as the record of the work so far. First compare the repository with its "Workspace identity" section (branch, HEAD, uncommitted files): if it differs in a way the document does not explain, tell the user what differs before changing anything. Then continue from "Next steps"; if "Open questions for the user" is non-empty, ask those first. A step that waits for the user (their confirmation, an answer, a "go") stays waiting: say briefly where things stand and stop, do not do it on their behalf.\n\n' "$FILE"
          awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{f=0;next} !f' "$FILE"
          [ -s "${HANDOFF_RESUME_ARGS:-}" ] && { printf '\n---\n\n'; cat "$HANDOFF_RESUME_ARGS"; }; } > "$Rf"
        BGASK=1
        if ! send_when_idle "handoff (fresh session)" "$Rf" --fresh; then
          case "$WHYNOT" in
            *"$BGMARK"*) fail "handoff in a fresh session not sent: $WHYNOT. Stop this session's background work first: T3 refuses a fresh session while it runs" ;;
            *) fail "handoff in a fresh session not sent: $WHYNOT" ;;
          esac
        fi
        logq "sent the handoff to $TID in a fresh session"
        # T3 records the new Codex session for the thread once it starts
        # (T3 first adds a pending row without a native id: wait for a non-empty id other than the old one)
        i=0; NEW=""
        while [ $i -lt $(( ${HANDOFF_T3_CLEAR_WAIT:-30} * 2 )) ]; do
          NEW="$(session_of_thread "$TID")"; [ -n "$NEW" ] && [ "$NEW" != "$SID" ] && break
          sleep 0.5; i=$((i+1))
        done
        [ -n "$NEW" ] && [ "$NEW" != "$SID" ] || fail "T3 did not record a new Codex session for $TID within ${HANDOFF_T3_CLEAR_WAIT:-30}s"
        is_tombstoned "$LIVE" || tombstone_set "$LIVE" "codex" >/dev/null; tombstone_link "$LIVE" "$NEW"
        echo "done:$NEW" > "$OUTCOME"; logq "codex handoff of $TID to fresh session $NEW complete"; exit 0
      fi
      AUTO="$HANDOFF_DIR/state/t3-fresh/$(printf '%s' "$TID" | tr '/' '_')"
      fail() { rm -f "$AUTO"; echo "failed:$1" > "$OUTCOME"; logq "handoff of $TID failed: $1; type /clear, then /handoff:resume"; exit 0; }
      Rf="$HANDOFF_DIR/state/$LIVE.resume-cmd.txt"
      { printf '/handoff:resume'; [ -s "$FILE" ] && { printf ' '; cat "$FILE"; }; } > "$Rf"
      # SessionStart(startup) of the fresh session adopts the doc, sees this marker (no "invoke resume" note: the
      # message is /handoff:resume itself) and writes state/cleared/<live sid> = its session id
      mkdir -p "$(dirname "$AUTO")"; echo "$LIVE" > "$AUTO"
      MARK="$HANDOFF_DIR/state/cleared/$LIVE"; rm -f "$MARK"
      BGASK=1; PRESEND=fresh_obsolete
      send_when_idle "fresh /handoff:resume${MSEL[*]:+ (${MSEL[*]})}" "$Rf" --fresh "${MSEL[@]}"; rc=$?
      if [ $rc -eq 2 ]; then rm -f "$AUTO"; echo "cancelled:$WHYNOT" > "$OUTCOME"; logq "handoff of $TID cancelled, nothing sent: $WHYNOT"; exit 0; fi
      if [ $rc -ne 0 ]; then
        case "$WHYNOT" in
          *"$BGMARK"*) fail "/handoff:resume in a fresh session not sent: $WHYNOT. Stop this session's background agents/commands first: T3 refuses a fresh session (the composer's /clear too) while they run" ;;
          *) fail "/handoff:resume in a fresh session not sent: $WHYNOT" ;;
        esac
      fi
      logq "sent /handoff:resume to $TID in a fresh session"
      i=0; while [ ! -s "$MARK" ] && [ $i -lt $(( ${HANDOFF_T3_CLEAR_WAIT:-30} * 2 )) ]; do sleep 0.5; i=$((i+1)); done
      [ -s "$MARK" ] || fail "no fresh session adopted the handoff within ${HANDOFF_T3_CLEAR_WAIT:-30}s (see hooks.log)"
      NEW="$(cat "$MARK")"
      # T3 records the fresh session's id once Claude reports it: check (best effort, log only)
      i=0; while [ "$(session_of_thread "$TID")" != "$NEW" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
      if [ "$(session_of_thread "$TID")" = "$NEW" ]; then logq "T3 records session $NEW for thread $TID"
      else logq "WARNING: T3 maps thread $TID to '$(session_of_thread "$TID")', not the fresh session $NEW"; fi
      echo "done:$NEW" > "$OUTCOME"; logq "handoff of $TID to fresh session $NEW complete"; exit 0 ;;
    clear)
      fail() { echo "failed:$1" > "$OUTCOME"; logq "handoff of $TID failed: $1; type /clear, then /handoff:resume"; exit 0; }
      C="$HANDOFF_DIR/state/$LIVE.clear-cmd.txt"; printf '/clear' > "$C"
      MARK="$HANDOFF_DIR/state/cleared/$LIVE"; rm -f "$MARK"
      send_when_idle "/clear" "$C" || fail "/clear not sent: $WHYNOT"
      logq "sent /clear to $TID"
      # SessionStart(clear) writes state/cleared/<live sid> = new sid (after the alias step)
      i=0; while [ ! -s "$MARK" ] && [ $i -lt $(( ${HANDOFF_T3_CLEAR_WAIT:-30} * 2 )) ]; do sleep 0.5; i=$((i+1)); done
      [ -s "$MARK" ] || fail "no new session observed after /clear"
      NEW="$(cat "$MARK")"
      if [ "$(cat "$HANDOFF_DIR/state/aliases/$SID" 2>/dev/null)" = "$NEW" ]; then logq "session $SID (T3's) now follows $NEW"
      else
        # T3 >= 0.1.10 records the new session itself, shortly after the /clear: from now on the thread maps to it
        i=0; while [ "$(session_of_thread "$TID")" != "$NEW" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
        if [ "$(session_of_thread "$TID")" = "$NEW" ]; then logq "T3 records session $NEW for thread $TID (it follows /clear)"; SID="$NEW"
        else logq "WARNING: session $SID (T3's) is NOT aliased to $NEW and T3 did not record $NEW (see the alias line above); a T3 respawn would resume the pre-clear context"; fi
      fi
      Rf="$HANDOFF_DIR/state/$LIVE.resume-cmd.txt"
      { printf '/handoff:resume'; [ -s "$FILE" ] && { printf ' '; cat "$FILE"; }; } > "$Rf"
      send_when_idle "/handoff:resume${MSEL[*]:+ (${MSEL[*]})}" "$Rf" "${MSEL[@]}" || fail "/handoff:resume not sent after the /clear: $WHYNOT"
      echo "done:$NEW" > "$OUTCOME"; logq "sent /handoff:resume to $TID: handoff to session $NEW complete"; exit 0 ;;
  esac
  exit 0
fi

# ---- foreground
skip() { if [ "$MODE" = "check" ]; then say "$1"; exit 1; fi; say "$1; $MODE skipped"; exit 0; }
case "$MODE" in check|nudge|clear|alias|recover|model) ;; *) say "unknown mode '$MODE'; skipped"; exit 0;; esac

# ---- model <ref|""> <effort|"">: (/handoff:now) resolve the model and effort the fresh session should run on, against
# `t3ctl models` and this thread's current selection (T3CODE_THREAD_ID). Prints one line:
#   ok <instanceId/model|-> <effort|->   send these with `threads send -m/-e` (- = keep the thread's)
#   error: <reason>                      the user named something this thread cannot switch to (unknown model,
#                                        another provider: the fresh session resumes through a Claude skill, effort
#                                        the model does not offer)
#   skip: <reason>                       cannot check (no t3ctl, server down): t3ctl validates again when it sends
# Reads only; no T3 db, no thread resolution. Effort alone is checked against the thread's current model.
if [ "$MODE" = model ]; then
  WANT_M="$ARG"; WANT_E="${6:-}"
  command -v t3ctl >/dev/null 2>&1 || { echo "skip: t3ctl not on PATH"; exit 0; }
  CAT="$(t3json models)"
  jq -e 'type=="array" and length>0' >/dev/null 2>&1 <<<"$CAT" || { echo "skip: t3ctl models gave no model list (is T3 Code running?)"; exit 0; }
  CUR="null"; [ -n "$T3TID" ] && CUR="$(thread_json "$T3TID" | jq -c '.modelSelection // null' 2>/dev/null)"; [ -n "$CUR" ] || CUR="null"
  # aliases: the user's own t3ctl ones (config.json modelAliases) first, then the catalog's (T3's). t3ctl's built-in
  # aliases are left out: they lag behind the catalog (t3ctl 0.8.0: opus -> claude-opus-4-8, sonnet -> claude-sonnet-4-6).
  UAL="$(jq -c '.modelAliases // {}' "${T3CTL_CONFIG_DIR:-$HOME/.config/t3ctl}/config.json" 2>/dev/null)"; [ -n "$UAL" ] || UAL="{}"
  jq -r --arg m "$WANT_M" --arg e "$WANT_E" --argjson cur "$CUR" --argjson ual "$UAL" '
    def norm: ascii_downcase | gsub("^\\s+|\\s+$";"") | gsub("[\\s._]+";"-") | gsub("-+";"-");
    def names: [.model] + (if (.aliases|type)=="array" then .aliases else ((.aliases // "")|split(",")) end)
               | map(norm) | map(select(length>0));
    def efforts: (if (.effort|type)=="array" then .effort else ((.effort // "")|split("|")) end)
               | map(rtrimstr("*")|gsub("^\\s+|\\s+$";"")) | map(select(length>0));
    . as $cat | ($cur.instanceId // null) as $ci
    | (if $m == "" then
         {hit: ([$cat[] | select(.instanceId==$ci and .model==$cur.model)] | .[0]), keep: true}
       else
         (($ual | with_entries(.key |= norm))[$m|norm] // $m) as $m2
         | (if ($m2|test("/")) then ($m2|split("/")) else [null,$m2] end) as $p0
         | [(if $p0[0] then ($p0[0]|ascii_downcase) else null end), ($p0[1]|norm)] as $p
         | [$cat[] | select($p[0]==null or (.instanceId|ascii_downcase)==$p[0])
                   | select(names as $n | ($n|index($p[1])) != null or ($n|index("claude-"+$p[1])) != null)] as $hits
         | {hit: (($hits|map(select(.instanceId==$ci))) + $hits | .[0]), keep: false}
       end) as $res
    | $res.hit as $h
    | if ($res.keep|not) and $h == null then
        "error: unknown model \"\($m)\". Models here: \([$cat[] | select($ci==null or .instanceId==$ci) | .model] | join(", "))"
      elif ($res.keep|not) and $ci != null and $h.instanceId != $ci then
        "error: \($h.model) runs on provider \($h.provider // $h.instanceId), this thread on \($ci): a handoff keeps the provider (the fresh session resumes through /handoff:resume)"
      elif $e != "" and $h != null and ($h|efforts|length) > 0 and (($h|efforts)|index($e)) == null then
        "error: effort \"\($e)\" is not offered by \($h.model) (allowed: \($h|efforts|join(", ")))"
      else
        "ok \(if $res.keep then "-" else "\($h.instanceId)/\($h.model)" end) \(if $e == "" then "-" else $e end)"
      end' <<<"$CAT" 2>/dev/null || echo "skip: could not read the t3ctl model list"
  exit 0
fi
[ "$AGENT" = codex ] && case "$MODE" in alias|recover) say "$MODE: Claude only; skipped"; exit 0;; esac
case "$MODE" in nudge|clear|recover) [ -s "$ARG" ] || { say "$MODE: file '$ARG' missing or empty; skipped"; exit 0; };; esac
[ "$MODE" = "alias" ] && [ -z "$ARG" ] && { say "alias: no pre-clear session id; skipped"; exit 0; }

is_t3_host() {
  [ "$__CFBundleIdentifier" = "com.t3tools.t3code" ] && return 0
  local p=$PPID i=0
  while [ $i -lt 6 ] && [ "${p:-0}" -gt 1 ]; do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in *"T3 Code"*|*t3code*|*t3-code*) return 0;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i+1))
  done
  return 1
}
thread_for_session() { q "select thread_id from $V2T where json_extract(payload_json,'\$.nativeThreadRef.nativeId')='$1' order by updated_at desc limit 1"; }
predecessor_of() {
  local f; f="$(grep -l "\"continued_by\" *: *\"$1\"" "$HANDOFF_DIR/state/tombstones/"*.json 2>/dev/null | head -1)"
  [ -n "$f" ] && basename "$f" .json
}
version_ge() { [ "$(printf '%s\n%s\n' "${2%%-*}" "${1%%-*}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "${2%%-*}" ]; }
# t3_follows_clear <server version>: T3 records the session a Claude-side /clear starts (>= FOLLOWS_CLEAR). Pre-releases
# of 0.1.10 have it from nightly 20261112.4603 on; an older or unrecognised 0.1.10 pre-release counts as without it.
t3_follows_clear() {
  local v="$1" base="${1%%-*}" n
  version_ge "$base" "$FOLLOWS_CLEAR" || return 1
  [ "$v" = "$base" ] || [ "$base" != "$FOLLOWS_CLEAR" ] && return 0
  n="$(sed -n 's/^[0-9.]*-nightly\.\([0-9]\{8\}\)\.\([0-9]\{1,\}\).*/\1 \2/p' <<<"$v")"; [ -n "$n" ] || return 1
  set -- $n; [ "$1" -gt 20261112 ] || { [ "$1" -eq 20261112 ] && [ "$2" -ge 4603 ]; }
}
realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# 1. preflight
is_t3_host || skip "not a T3 Code session (host guard), handoff stays manual"
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
VER="(not asked)"
if [ "$MODE" != "alias" ]; then
  command -v t3ctl >/dev/null 2>&1 || skip "t3ctl not on PATH (install: https://github.com/samzilverberg/t3ctl)"
  ENV="$(t3json env)"
  VER="$(jq -r '.serverVersion // empty' <<<"$ENV" 2>/dev/null)"
  [ -n "$VER" ] || skip "T3 Code server not reachable via t3ctl within 5 s ($(jq -r '.error.code // .error.message // empty' <<<"$ENV" 2>/dev/null || true)); is T3 Code running?"
  [ "$(jq -r '.supported' <<<"$ENV" 2>/dev/null)" = "false" ] && skip "T3 Code server $VER is not supported by this t3ctl (update t3ctl or T3 Code)"
  version_ge "$VER" "$MIN_T3" || skip "T3 Code server $VER < $MIN_T3; $NEED"
elif command -v t3ctl >/dev/null 2>&1; then
  # alias (inside SessionStart's 10 s): only the server version, to skip the alias where T3 follows /clear itself
  VER="$(t3json env | jq -r '.serverVersion // empty' 2>/dev/null)"; [ -n "$VER" ] || VER="(unreachable)"
fi
# handoff flow: fresh session where T3 offers it (and this process knows its thread), else /clear + alias
FLOW=clear; FLOWWHY="no freshContext in T3 Code $VER"
if [ "$MODE" != "alias" ]; then
  if [ "$(cfg T3_FRESH true)" != "true" ]; then FLOWWHY="HANDOFF_T3_FRESH=false"
  elif [ "$(jq -r '.capabilities.freshContext // false' <<<"$ENV" 2>/dev/null)" != "true" ]; then :
  elif [ -z "$T3TID" ] && [ "$AGENT" != codex ]; then FLOWWHY="T3CODE_THREAD_ID not set in this process"
  elif ! version_ge "$(t3 --version 2>/dev/null)" 0.8.0; then FLOWWHY="t3ctl $(t3 --version 2>/dev/null) has no send --fresh (needs >= 0.8.0)"
  else FLOW=fresh; FLOWWHY=""; fi
fi
FLOWDESC="handoff via fresh session"; [ "$FLOW" = fresh ] || FLOWDESC="handoff via /clear + alias ($FLOWWHY)"
# Codex: no /clear flow (a Codex /clear is not reachable through T3): fresh sessions or nothing
[ "$AGENT" = codex ] && [ "$MODE" != alias ] && [ "$FLOW" != fresh ] && skip "Codex handoff needs T3 fresh sessions ($FLOWWHY; T3 Code >= 0.1.9, t3ctl >= 0.8.0)"

if [ "$MODE" = "check" ] && [ -z "$SID" ]; then say "ok: T3 Code $VER, $(basename "$T3DB") readable, t3ctl ready; $FLOWDESC"; exit 0; fi

# 2. thread resolution (alias: of the pre-clear session)
[ -n "$SID" ] || skip "no $AGENT session id"

# ---- alias where T3 follows /clear itself: nothing to link. Checked before the thread lookup: T3 may already have
# moved the thread off the pre-clear session. The new session keeps its own id as its key (no aliased-by entry); the
# pre-clear session stays tombstoned (SessionEnd(clear)) and so does the id it ran under when it was itself aliased.
if [ "$MODE" = "alias" ] && t3_follows_clear "$VER"; then
  TID="$(thread_for_session "$SID")"; [ -n "$TID" ] || TID="$(thread_for_session "$ARG")"; [ -n "$TID" ] || TID="$T3TID"
  K="$(session_key "$ARG")"
  if [ "$K" != "$ARG" ] && [ "$K" != "$SID" ]; then
    is_tombstoned "$K" || tombstone_set "$K" "${CPID:-?}" >/dev/null; tombstone_link "$K" "$SID"
  fi
  say "T3 Code $VER (>= $FOLLOWS_CLEAR) follows /clear natively; no alias for $ARG -> $SID (thread ${TID:-unknown})"
  [ -n "$TID" ] && [ -z "$HANDOFF_T3_DRYRUN" ] && { nohup bash "$0" "$ROOT" "$LOG" "$SID" --bg follow "$TID" "$VER" >/dev/null 2>&1 & disown 2>/dev/null || true; }
  exit 0
fi
LOOK="$SID"; [ "$MODE" = "alias" ] && LOOK="$ARG"
TID="$(thread_for_session "$LOOK")"; HOW="session id"; MSID="$LOOK"
[ -s "$DBERR" ] && skip "cannot read T3 db $T3DB ($(dberr))"
# a post-/clear session the T3 layer aliased: T3 knows it as the aliased id
if [ -z "$TID" ]; then
  K="$(session_key "$LOOK")"
  [ "$K" != "$LOOK" ] && { TID="$(thread_for_session "$K")"; [ -n "$TID" ] && { MSID="$K"; HOW="alias of $K"; }; }
fi
# sessions /cleared without an alias (plugin <= 0.5, alias failed): follow our /clear chain back (bounded)
hops=0; cur="$LOOK"
while [ -z "$TID" ] && [ $hops -lt 20 ]; do
  cur="$(predecessor_of "$cur")"; [ -n "$cur" ] || break
  hops=$((hops+1)); TID="$(thread_for_session "$cur")"
  [ -n "$TID" ] && { MSID="$cur"; HOW="pre-clear ancestor $cur, $hops /clear(s) back"; }
done
if [ -z "$TID" ]; then
  N="$(q "select count(*) from $V2T")"; K="$(q "select count(*) from $V2T where json_extract(payload_json,'\$.nativeThreadRef.nativeId') is not null")"
  [ "${N:-0}" -gt 0 ] && [ "${K:-0}" -eq 0 ] && skip "T3 db rows carry no payload_json.nativeThreadRef.nativeId (T3 Code db layout changed?)"
  skip "session $LOOK (and its pre-clear ancestors) not found in T3 state db $(basename "$T3DB")"
fi

# ---- recover gate: recover only a thread T3 still routes to this stale session ($MSID: the session itself, its alias
# key, or a pre-clear ancestor). Anywhere else the prompt is a wake of (or stray input into) a replaced process that is
# still alive: no recovery, nothing sent (thread 569772de: seven recoveries, six asks into the new session). Printed for
# handoff-userprompt.sh, which logs (rate-limited) and blocks: REPLACED <session> successor|other.
if [ "$MODE" = "recover" ]; then
  CUR="$(session_of_thread "$TID")"
  if [ "$CUR" != "$MSID" ]; then
    REL=other; cur="$SID"; i=0
    while [ $i -lt 20 ]; do cur="$(tombstone_get "$cur" continued_by)"; [ -n "$cur" ] || break; [ "$cur" = "$CUR" ] && { REL=successor; break; }; i=$((i+1)); done
    echo "REPLACED ${CUR:-none} $REL $TID"; exit 0
  fi
  # a background-task notification Claude injects into the stale process is not the user's message: never recover
  # with it (the fresh session would get it as the user's message); the next real message recovers the thread
  case "$(head -c 40 "$ARG")" in "<task-notification>"*) echo "WAKE_STALE $TID"; exit 0;; esac
fi

# ---- alias: local only (runs inside SessionStart's 10 s)
if [ "$MODE" = "alias" ]; then
  R="$MSID"; NEWT="$HANDOFF_TRANSCRIPT"
  [ "$R" = "$SID" ] && { say "T3 already records the new session $SID for thread $TID; no alias needed"; exit 0; }
  HEAD="$(q "select json_extract(payload_json,'\$.nativeConversationHeadRef') from $V2T where thread_id='$TID' order by updated_at desc limit 1")"
  [ -n "$HEAD" ] && skip "T3 pins a conversation head for thread $TID ($HEAD): resuming at it through an alias is unsafe"
  [ -n "$NEWT" ] || skip "no transcript path for the new session $SID"
  TD="$(dirname "$NEWT")"; RF="$TD/$R.jsonl"
  [ "$(basename "$NEWT")" = "$SID.jsonl" ] || skip "transcript $NEWT is not named after session $SID (Claude Code layout changed?)"
  [ -e "$RF" ] || [ -L "$RF" ] || skip "T3's session transcript $RF not found (thread $TID runs elsewhere?)"
  if [ -n "$HANDOFF_T3_DRYRUN" ]; then say "alias $R -> $SID for thread $TID (dry run)"; exit 0; fi
  if [ ! -L "$RF" ]; then
    KEEP="$RF.pre-handoff"; [ -e "$KEEP" ] && KEEP="$RF.pre-handoff-$(now)"
    mv "$RF" "$KEEP" || skip "cannot move $RF aside"
  fi
  ln -sfn "$SID.jsonl" "$RF" || skip "cannot link $RF"
  mkdir -p "$HANDOFF_DIR/state/aliases" "$HANDOFF_DIR/state/aliased-by" "$HANDOFF_DIR/state/tombstones/aliased" "$HANDOFF_DIR/sessions/archive"
  echo "$SID" > "$HANDOFF_DIR/state/aliases/$R"; echo "$R" > "$HANDOFF_DIR/state/aliased-by/$SID"
  # R is live again (as the new context); its per-window state and the consumed handoff start over
  [ -f "$(tombstone_file "$R")" ] && mv "$(tombstone_file "$R")" "$HANDOFF_DIR/state/tombstones/aliased/$R.json"
  rm -f "$HANDOFF_DIR/state/$R.json"
  [ -f "$HANDOFF_DIR/sessions/$R.md" ] && mv "$HANDOFF_DIR/sessions/$R.md" "$HANDOFF_DIR/sessions/archive/$R-$(now).md"
  say "aliased T3's session $R (thread $TID, matched by $HOW) -> $SID: a T3 respawn resumes the new context"
  exit 0
fi

TJ="$(thread_json "$TID")"
ST="$(jq -r '.status // empty' <<<"$TJ" 2>/dev/null)"
case "$ST" in
  "")       skip "could not read thread $TID via t3ctl" ;;
  missing)  skip "T3 db maps session to thread $TID but T3 Code does not know that thread (deleted?)" ;;
  archived) skip "thread $TID is archived" ;;
esac
# the thread must run in this project dir: its worktree, or (local threads) its project's workspace root
WT="$(jq -r '.worktreePath // empty' <<<"$TJ")"
if [ -z "$WT" ]; then PID_="$(jq -r '.projectId // empty' <<<"$TJ")"; WT="$(t3json projects | jq -r --arg p "$PID_" '.[] | select(.id==$p) | .workspaceRoot' 2>/dev/null)"; fi
if [ -n "$WT" ] && [ "$(realdir "$WT")" != "$(realdir "$ROOT")" ]; then
  case "$(realdir "$ROOT")/" in "$(realdir "$WT")/"*) [ "$AGENT" = codex ] || skip "thread $TID works in $WT, not in this project dir $ROOT";;
    *) skip "thread $TID works in $WT, not in this project dir $ROOT";; esac
fi
# the fresh session finds the doc by this process's T3 thread: it must be the thread resolved here
if [ "$FLOW" = fresh ] && [ "$AGENT" != codex ] && [ "$T3TID" != "$TID" ]; then FLOW=clear; FLOWWHY="this process's T3CODE_THREAD_ID $T3TID is not thread $TID"; FLOWDESC="handoff via /clear + alias ($FLOWWHY)"; fi
[ "$MODE" = "check" ] && { say "ok: T3 Code $VER; session $SID -> thread $TID ($ST, matched by $HOW); $FLOWDESC"; exit 0; }

bg() { nohup bash "$0" "$ROOT" "$LOG" "$MSID" --bg "$@" >/dev/null 2>&1 & BGPID=$!; disown 2>/dev/null || true; }

case "$MODE" in
  nudge)
    # one pending nudge worker per session and text file: a second Stop before the first nudge went out (a background
    # task's turn ran in between) refreshes the text the pending worker sends instead of queueing a second turn
    # (thread 569772de: the duplicate went out after the handoff was already written)
    NP="$HANDOFF_DIR/state/$SID.nudge-pending"
    if read -r PP PF 2>/dev/null < "$NP" && [ "$PF" = "$ARG" ] && nudge_pending "$SID" "$ARG"; then
      say "nudge already scheduled for thread $TID (worker pid $PP, session $SID): not queued twice; it sends the current text"; exit 0
    fi
    say "nudge scheduled for thread $TID (matched by $HOW, session $SID)"
    [ -n "$HANDOFF_T3_DRYRUN" ] && exit 0
    bg nudge "$TID" "$ARG" "$SID"; echo "$BGPID $ARG" > "$NP" ;;

  clear)
    if [ "$AGENT" = codex ]; then say "handoff (document sent as a fresh session) scheduled for thread $TID (matched by $HOW, session $SID)"
    elif [ "$FLOW" = fresh ]; then say "handoff (/handoff:resume in a fresh session$( [ -n "${HANDOFF_FRESH_MODEL:-}${HANDOFF_FRESH_EFFORT:-}" ] && echo ", model ${HANDOFF_FRESH_MODEL:--} effort ${HANDOFF_FRESH_EFFORT:--}")) scheduled for thread $TID (matched by $HOW, session $SID)"
    else say "handoff (/clear, then /handoff:resume) scheduled for thread $TID (matched by $HOW, session $SID; $FLOWWHY)"; fi
    [ -n "$HANDOFF_T3_DRYRUN" ] && exit 0
    echo "pending" > "$HANDOFF_DIR/state/$SID.t3clear"; rm -f "$HANDOFF_DIR/state/$SID.bgask"   # a new handoff: its own ask
    # HANDOFF_RESUME_ARGS (T3_DEFER): file with the user's held-back message, passed on to the fresh session
    if [ "$AGENT" = codex ]; then bg fresh "$TID" "$ARG" "$SID"; else bg "$FLOW" "$TID" "${HANDOFF_RESUME_ARGS:-}" "$SID"; fi ;;

  recover)
    # Tombstoned session resumed by T3: chain SID -> continued_by -> … -> tail. Stage the newest handoff doc of the
    # chain, with a digest of everything the later sessions said after it inlined, as THIS session's handoff, then
    # the handoff: fresh flow (T3 then records the fresh session) or /clear (which aliases T3's session to the fresh
    # one) + /handoff:resume.
    CHAIN=("$SID"); cur="$SID"; i=0
    while [ $i -lt 20 ]; do nx="$(tombstone_get "$cur" continued_by)"; [ -n "$nx" ] || break; CHAIN+=("$nx"); cur="$nx"; i=$((i+1)); done
    TAIL="${CHAIN[${#CHAIN[@]}-1]}"
    DOC=""; DOCI=-1
    for ((k=${#CHAIN[@]}-1; k>=0; k--)); do
      for d in "$HANDOFF_DIR/sessions/${CHAIN[$k]}.md" "$HANDOFF_DIR/sessions/$(session_key "${CHAIN[$k]}").md"; do
        [ -s "$d" ] && { DOC="$d"; DOCI=$k; break 2; }
      done
    done
    TDIR="$(dirname "${HANDOFF_TRANSCRIPT:-/nonexistent/x}")"
    SINCE="1970-01-01T00:00:00Z"; [ -n "$DOC" ] && SINCE="$(date -u -r "$(mtime "$DOC")" +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$HANDOFF_DIR/recovery"; DIG="$HANDOFF_DIR/recovery/$SID-digest.md"
    { printf '# Transcript digest after the last handoff document\n\nSessions (oldest first) after %s. User messages and assistant text only, long entries cut.\n' "$SINCE"
      for ((k=(DOCI<0?0:DOCI); k<${#CHAIN[@]}; k++)); do
        tf="$TDIR/${CHAIN[$k]}.jsonl"; [ -f "$tf" ] || continue
        printf '\n## Session %s\n\n' "${CHAIN[$k]}"
        jq -r --arg s "$SINCE" 'select((.type=="user" or .type=="assistant") and (.timestamp // "") > $s and (.isMeta|not)) | .message as $m
          | (if ($m.content|type)=="string" then $m.content else ([$m.content[]? | select(.type=="text") | .text] | join("\n")) end) as $t
          | select(($t|length) > 0 and ($t|startswith("<")|not))
          | "- **\(.type)** \(.timestamp[0:16]): \($t | gsub("\n+"; " ") | .[0:600])"' "$tf" 2>/dev/null | tail -n 80
      done; } > "$DIG"
    if [ -n "$HANDOFF_T3_DRYRUN" ]; then say "recover thread $TID from ${DOC:-no doc} + digest $DIG (dry run)"; exit 0; fi
    REC="$HANDOFF_DIR/sessions/$(session_key "$SID").md"
    { printf -- '---\nsession: %s\nreason: t3-recovery (chain %s)\nwritten: %s\n---\n\n' "$SID" "${CHAIN[*]}" "$(date -Iseconds)"
      printf '> Recovery note: T3 Code resumed this thread on a stale Claude session (%s) that had been /cleared; the work went on in later sessions (newest: %s). Below is the newest handoff document of that chain. The section "Transcript after this handoff" at the end holds what the user and the assistant said after it (newer than everything above it): re-check anything it reports as in progress.\n\n' "$SID" "$TAIL"
      if [ -n "$DOC" ]; then awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{f=0;next} !f' "$DOC" | sed '/./,$!d'
      else printf '# Handoff\n\nNo handoff document was written in the chain. Rebuild the state from the transcript below and the repo.\n'; fi
      # inlined (not just referenced): a resumed model does not reliably open a second file. Capped; full copy in $DIG
      printf '\n## Transcript after this handoff (digest, newest last; full copy: %s)\n\n' "$DIG"
      sed '1,/^Sessions (oldest first)/d' "$DIG" | tail -n 120; } > "$REC.tmp" && mv "$REC.tmp" "$REC"
    publish "$REC" "$SID"
    A="$HANDOFF_DIR/state/$SID.resume-args.txt"
    { printf 'This thread was just recovered by the handoff plugin: the earlier "STOP — stale session resume" note no longer applies. Before the Next steps, handle this message the user sent while the recovery ran:\n\n'; cat "$ARG"; } > "$A"
    echo "pending" > "$HANDOFF_DIR/state/$SID.t3clear"
    if [ "$FLOW" = fresh ]; then say "recovering thread $TID from ${DOC:-no doc} + digest $DIG (/handoff:resume with the user's message, in a fresh session)"
    else say "recovering thread $TID from ${DOC:-no doc} + digest $DIG (/clear, then /handoff:resume with the user's message)"; fi
    bg "$FLOW" "$TID" "$A" "$SID"
    echo "RECOVERING" ;;
esac
exit 0
