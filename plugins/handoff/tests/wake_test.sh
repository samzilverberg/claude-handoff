#!/bin/bash
# 0.10.1: wakes of a replaced session, T3's routing, the background-work ask gate, the nudge race. Replays thread
# 569772de (2026-11-24, T3 Code 0.1.11): a fresh-session handoff completed, the old Claude process stayed alive for its
# background work, and every <task-notification> Claude woke it with ran `t3.sh recover`: a refused fresh send, an "end
# your background work" turn into the NEW session, a failed mapping check; 7 times. Uses a T3 state db with the tables
# T3 routes by (provider threads, runs, messages, threads) and a fake t3ctl. Pure bash, macOS.
# Run: bash plugins/handoff/tests/wake_test.sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"; SCR="$DIR/scripts"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'pkill -f "t3.sh $TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP" CLAUDE_HANDOFF_NESTED=""
unset T3CODE_THREAD_ID
export HANDOFF_THRESHOLD=1000 HANDOFF_LIVE_FROM=0 HANDOFF_LOOP_GUARD=false HANDOFF_MAX_DOC_SHARE=0
export HANDOFF_T3_AUTOCLEAR=true __CFBundleIdentifier=com.t3tools.t3code
export HANDOFF_T3_DB="$TMP/statev2.sqlite" HANDOFF_T3_SEND_TIMEOUT=25 HANDOFF_T3_CLEAR_WAIT=2
export F_LOG="$TMP/t3ctl.calls" F_ROOT="$TMP" F_REJECT="$TMP/reject" F_BUSY="$TMP/busy" F_REMAP="$TMP/remap.sql"
HD="$TMP/.claude/handoff"; LOG="$HD/hooks.log"

# fake t3ctl (T3 Code 0.1.12, freshContext): logs calls, stdin bodies to $F_LOG.sent. `threads send` fails while $F_BUSY
# exists; `--fresh` is refused while $F_REJECT exists (T3's background-work refusal, as t3ctl prints it), and then
# runs the SQL in $F_REMAP once (the thread moving on while the worker looks).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/t3ctl" <<'EOF2'
#!/bin/bash
echo "$*" >> "$F_LOG"
case "$1 $2" in
  "env ") echo '{"serverVersion":"0.1.12","supported":true,"capabilities":{"freshContext":true}}'; exit 0;;
  "--version ") echo 0.8.0; exit 0;;
  "projects ") echo "[{\"id\":\"P1\",\"workspaceRoot\":\"$F_ROOT\"}]"; exit 0;;
  "threads list") echo "[{\"id\":\"$4\",\"status\":\"idle\",\"projectId\":\"P1\",\"worktreePath\":\"$F_ROOT\"}]"; exit 0;;
  "threads wait") exit 0;;
  "threads send") [ -e "$F_BUSY" ] && { echo "thread is running" >&2; exit 1; }
    case " $* " in *" --fresh "*) if [ -e "$F_REJECT" ]; then
      [ -s "$F_REMAP" ] && { sqlite3 "$HANDOFF_T3_DB" < "$F_REMAP"; : > "$F_REMAP"; }
      echo '{"error":{"code":"rpc_error","message":"orchestration.dispatchCommand failed: [{\"_tag\":\"Fail\",\"error\":{\"message\":\"The current session is still running background agents or commands, and a fresh session would end them. Wait for them to finish, or press Stop, then send the message again.\"}}]"}}'; exit 1; fi;; esac
    { cat; echo; echo "-- $*"; } >> "$F_LOG.sent"; exit 0;;
esac
exit 0
EOF2
chmod +x "$TMP/bin/t3ctl"; export PATH="$TMP/bin:$PATH"

# T3 state db, the columns T3 0.1.12 routes by
sqlite3 "$HANDOFF_T3_DB" "create table orchestration_v2_projection_provider_threads(provider_thread_id text, thread_id text, updated_at text, payload_json text);
create table orchestration_v2_projection_runs(thread_id text, ordinal int, status text, payload_json text);
create table orchestration_v2_projection_messages(message_id text, payload_json text);
create table orchestration_v2_projection_threads(thread_id text, active_provider_thread_id text);"
# row <thread> <provider thread id> <claude sid> <first run> <last run> <updated_at>
row() { sqlite3 "$HANDOFF_T3_DB" "insert into orchestration_v2_projection_provider_threads values('$2','$1','$6','{\"nativeThreadRef\":{\"nativeId\":\"$3\"},\"firstRunOrdinal\":$4,\"lastRunOrdinal\":$5}')"; }
# run <thread> <ordinal> <fresh: true|false> [scheduled task id]
run() { sqlite3 "$HANDOFF_T3_DB" "insert into orchestration_v2_projection_runs values('$1',$2,'completed','{\"freshContext\":$3,\"userMessageId\":\"m-$1-$2\",\"startedAt\":\"x\"}');
  insert into orchestration_v2_projection_messages values('m-$1-$2','{\"scheduledTaskId\":$( [ -n "${4:-}" ] && echo "\"$4\"" || echo null)}')"; }
active() { sqlite3 "$HANDOFF_T3_DB" "delete from orchestration_v2_projection_threads where thread_id='$1'; insert into orchestration_v2_projection_threads values('$1','$2')"; }
lastrun() { sqlite3 "$HANDOFF_T3_DB" "update orchestration_v2_projection_provider_threads set payload_json=json_set(payload_json,'\$.lastRunOrdinal',$2) where provider_thread_id='$1'"; }

source "$SCR/handoff-lib.sh"
wait_for() { local i=0; while [ $i -lt $((${3:-12}*4)) ]; do grep -qsF -- "$1" "$2" 2>/dev/null && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
up() { echo "{\"session_id\":\"$1\",\"prompt\":$(jq -Rs . <<<"$2"),\"transcript_path\":\"$TMP/tx/$1.jsonl\"}" | bash "$SCR/handoff-userprompt.sh"; }
sends() { grep -s "^threads send" "$F_LOG" | wc -l | tr -d ' '; }
mkdir -p "$TMP/tx"
NOTE='<task-notification>
<task-id>ab96165d89f6c6f1c</task-id>
<status>completed</status>
</task-notification>'

# --- A. replay of 569772de: the fresh handoff completed (OLDS -> NEWS), the old process keeps getting wakes ----------
# the fresh run (13) started NEWS's row; T3 0.1.11 then bumped OLDS's row (updated_at) and moved its active pointer back
row T569 pt1 OLDS 1 12 2026-11-24T20:48:04Z; row T569 pt13 NEWS 13 29 2026-11-24T17:34:10Z
run T569 13 true; active T569 pt1
tombstone_set OLDS 85204 >/dev/null; tombstone_link OLDS NEWS >/dev/null
export T3CODE_THREAD_ID=T569; touch "$F_REJECT"   # the old process still runs background work
: > "$F_LOG"; : > "$LOG"; echo '# Handoff
NEWS current' > "$HD/current.md"
for i in 1 2 3 4 5 6 7; do
  OUT="$(up OLDS "$NOTE")"
  echo "$OUT" | jq -e '.decision=="block" and (.reason|test("replaced session \\(OLDS\\).*continues in session NEWS"))' >/dev/null || { bad "A: wake $i blocked with a short reason" "$OUT"; break; }
done
[ "$i" = 7 ] && ok "A: 7 wakes of the replaced session blocked (zero tokens), reason names the successor"
sleep 1
[ "$(grep -c 'wake of replaced session OLDS (thread T569 maps to successor NEWS); ignored (blocked, no recovery)' "$LOG")" = 1 ] && ok "A: logged once (rate-limited)" || bad "A: one log line" "$(cat "$LOG")"
! grep -q "recovering\|recover failed\|tombstoned sid" "$LOG" && ok "A: no recovery started" || bad "A: recovery" "$(grep -i recover "$LOG")"
[ "$(sends)" = 0 ] && ! grep -q "asked the agent" "$LOG" && ok "A: nothing sent to the thread: no fresh send, no ask turn" || bad "A: sends" "$(cat "$F_LOG")"
[ ! -e "$HD/by-thread/T569.md" ] && grep -q "NEWS current" "$HD/current.md" && ok "A: nothing re-staged (no by-thread doc, current.md untouched)" || bad "A: restaged" "$(ls "$HD/by-thread" 2>&1)"
HANDOFF_WAKE_LOG_EVERY=0 up OLDS "$NOTE" >/dev/null
grep -q "wake of replaced session OLDS .*; 6 more since" "$LOG" && ok "A: later log line counts the wakes in between" || bad "A: count" "$(tail -2 "$LOG")"
# 0.1.12 attributes a wake run to the active pointer: OLDS's row gets the newest run ordinal; routing stays on NEWS
lastrun pt1 30
OUT="$(up OLDS "$NOTE")"; echo "$OUT" | grep -q "continues in session NEWS" && [ "$(sends)" = 0 ] && ok "A: wake run attributed to the old row (0.1.12): still NEWS, nothing sent" || bad "A: ordinal bump" "$OUT"
# a real message that reached the old process (T3 < 0.1.12 could route one there): blocked, asked to resend, no recovery
OUT="$(up OLDS "what is the status?")"
echo "$OUT" | jq -e '.decision=="block" and (.reason|test("Send the message again"))' >/dev/null && [ "$(sends)" = 0 ] && ok "A: stray user message into the replaced process: blocked, resend asked, nothing sent" || bad "A: stray" "$OUT"
grep -q "prompt into replaced session OLDS (thread T569 maps to successor NEWS); blocked, no recovery" "$LOG" && ok "A: stray message logged" || bad "A: stray log" "$(tail -2 "$LOG")"
# the new session itself is unaffected: live (no-op hook), and its own handoff worker sees the thread as its own
OUT="$(up NEWS "next step")"; [ -z "$OUT" ] && ok "A: prompts of the new session pass untouched" || bad "A: new session" "$OUT"
rm -f "$F_REJECT"; : > "$F_LOG"; echo "body" > "$TMP/n.txt"
bash "$SCR/t3.sh" "$TMP" "$LOG" NEWS nudge "$TMP/n.txt" >/dev/null
wait_for "sent handoff nudge turn to T569" "$LOG" 6 && ok "A: a turn from NEWS is sent: T3 routes T569 to NEWS (newest updated_at / active pointer say OLDS)" || bad "A: routing" "$(tail -3 "$LOG")"
# a scheduled task's fresh run does not move T3's routing boundary
row T569 pt31 SCHED 31 31 2026-11-25T07:00:00Z; run T569 31 true scheduled-task:x; active T569 pt31
OUT="$(up OLDS "$NOTE")"; echo "$OUT" | grep -q "continues in session NEWS" && ok "A: scheduled fresh run is a side conversation: routing stays NEWS" || bad "A: scheduled" "$OUT"

# --- B. stale-thread recovery (plugin <= 0.5 /clear chain) still recovers: T3 routes the thread to the stale session ----
row TST ptS STALE 1 9 2026-11-20T10:00:00Z; active TST ptS
tombstone_set STALE 1 >/dev/null; tombstone_link STALE NEXT >/dev/null
printf '# Handoff\n## Goal\ng\n' > "$HD/sessions/NEXT.md"; echo '{}' > "$TMP/tx/STALE.jsonl"
export T3CODE_THREAD_ID=TST; : > "$F_LOG"
OUT="$(up STALE "$NOTE")"
echo "$OUT" | jq -e '.decision=="block" and (.reason|test("next message you send restores"))' >/dev/null && ! grep -q "recovering thread TST" "$LOG" && [ "$(sends)" = 0 ] \
  && ok "B: a wake of the stale session itself: blocked, no recovery with a task notification as the user's message" || bad "B: stale wake" "$OUT"
OUT="$(up STALE "where are we?")"
echo "$OUT" | jq -e '.decision=="block" and (.reason|test("restoring it"))' >/dev/null && grep -q "recovering thread TST" "$LOG" && ok "B: a real message recovers the stale thread (as before)" || bad "B: recover" "$OUT $(tail -3 "$LOG")"
wait_for "threads send TST --fresh --stdin" "$F_LOG" 6 && grep -q "where are we?" "$F_LOG.sent" && ok "B: fresh /handoff:resume with the message sent" || bad "B: send" "$(cat "$F_LOG")"
pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3

# --- C. ask gate: the "end your background work" turn only reaches the session whose background work T3 checks ------
fresh_doc() { mkdir -p "$HD/by-thread"; printf '# Handoff\n' > "$HD/by-thread/$1.md"; printf '# Handoff\n' > "$TMP/doc-$2.md"; }
# C1. live session LIVE1, T3 routes to it and its active pointer is on it: one ask, then not again
row TC1 pc1 LIVE1 1 5 2026-11-25T08:00:00Z; active TC1 pc1; export T3CODE_THREAD_ID=TC1; fresh_doc TC1 LIVE1
: > "$F_LOG"; touch "$F_REJECT"
bash "$SCR/t3.sh" "$TMP" "$LOG" LIVE1 clear "$TMP/doc-LIVE1.md" >/dev/null
wait_for "asked the agent in TC1 to end its background work" "$LOG" 6 && grep -qx "threads send TC1 --stdin" "$F_LOG" && ok "C1: ask sent to the session T3 checks" || bad "C1: ask" "$(grep '\[t3\]' "$LOG" | tail -3)"
grep -q "^pending: T3 refuses the fresh session while this session runs background agents" "$HD/state/LIVE1.t3clear" && ok "C1: outcome tells the user why it waits (shown by the next Stop)" || bad "C1: outcome" "$(cat "$HD/state/LIVE1.t3clear")"
pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3
# a second worker for the same handoff (recovery path) does not ask again
: > "$F_LOG"; nohup bash "$SCR/t3.sh" "$TMP" "$LOG" LIVE1 --bg fresh TC1 "" LIVE1 >/dev/null 2>&1 &
wait_for "request to end background work not repeated: already sent once for this handoff" "$LOG" 6 && ! grep -qx "threads send TC1 --stdin" "$F_LOG" && ok "C1: capped at one ask per handoff" || bad "C1: cap" "$(grep '\[t3\]' "$LOG" | tail -3)"
pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3
# C2. T3's active pointer is on an earlier session still alive with background work (it took the pointer back): no ask
row TC2 pc2a OLD2 1 4 2026-11-25T09:00:00Z; row TC2 pc2b LIVE2 5 8 2026-11-25T08:00:00Z; run TC2 5 true; active TC2 pc2a
export T3CODE_THREAD_ID=TC2; fresh_doc TC2 LIVE2; : > "$F_LOG"
bash "$SCR/t3.sh" "$TMP" "$LOG" LIVE2 clear "$TMP/doc-LIVE2.md" >/dev/null
wait_for "request to end background work NOT sent to TC2: T3 refuses because of the background work of session OLD2" "$LOG" 6 && ! grep -qx "threads send TC2 --stdin" "$F_LOG" && ok "C2: no ask when T3 checks another session's background work" || bad "C2: gate" "$(grep '\[t3\]' "$LOG" | tail -3)"
grep -q "while session OLD2, an earlier session of this thread whose process is still alive" "$HD/state/LIVE2.t3clear" && ok "C2: outcome names the session holding it up" || bad "C2: outcome" "$(cat "$HD/state/LIVE2.t3clear")"
pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3
# C3. the thread moved on (a fresh session started) when the refusal came back: no ask, then nothing sent
row TC3 pc3 LIVE3 1 5 2026-11-25T08:00:00Z; active TC3 pc3; export T3CODE_THREAD_ID=TC3; fresh_doc TC3 LIVE3; : > "$F_LOG"
printf "insert into orchestration_v2_projection_provider_threads values('pc3n','TC3','2026-11-25T08:10:00Z','{\"nativeThreadRef\":{\"nativeId\":\"NEW3\"},\"firstRunOrdinal\":6,\"lastRunOrdinal\":6}');
insert into orchestration_v2_projection_runs values('TC3',6,'completed','{\"freshContext\":true,\"userMessageId\":\"m-TC3-6\"}');\n" > "$F_REMAP"
bash "$SCR/t3.sh" "$TMP" "$LOG" LIVE3 clear "$TMP/doc-LIVE3.md" >/dev/null
wait_for "request to end background work NOT sent to TC3: the thread maps to session 'NEW3', not LIVE3" "$LOG" 6 && ok "C3: no ask once the thread routes elsewhere" || bad "C3: gate" "$(grep '\[t3\]' "$LOG" | tail -3)"
wait_for "thread TC3 now maps to session 'NEW3', not LIVE3; fresh /handoff:resume NOT sent" "$LOG" 10 && ! grep -qx "threads send TC3 --stdin" "$F_LOG" && ok "C3: worker stops, nothing sent" || bad "C3: stop" "$(grep '\[t3\]' "$LOG" | tail -3)"
pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3
# C4. a compact consumed the staged doc while T3 refused (thread 383ac993): handoff cancelled, no 600 s of retries
row TC4 pc4 LIVE4 1 5 2026-11-25T08:00:00Z; active TC4 pc4; export T3CODE_THREAD_ID=TC4; fresh_doc TC4 LIVE4; : > "$F_LOG"
bash "$SCR/t3.sh" "$TMP" "$LOG" LIVE4 clear "$TMP/doc-LIVE4.md" >/dev/null
wait_for "fresh /handoff:resume to TC4 failed (thread busy?)" "$LOG" 6 >/dev/null; rm -f "$HD/by-thread/TC4.md"
wait_for "handoff of TC4 cancelled, nothing sent: the handoff document staged for thread TC4 is gone" "$LOG" 10 && grep -q "^cancelled:" "$HD/state/LIVE4.t3clear" && ok "C4: staged doc consumed (compact) -> handoff cancelled" || bad "C4: cancel" "$(grep '\[t3\]' "$LOG" | tail -3)"
rm -f "$F_REJECT"; pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3

# --- D. nudge race: one pending nudge worker per session; dropped once the handoff itself is scheduled ------------------
row TD pd LIVED 1 5 2026-11-25T08:00:00Z; active TD pd; export T3CODE_THREAD_ID=TD; : > "$F_LOG"; : > "$F_LOG.sent"; touch "$F_BUSY"
printf 'request v1\n' > "$HD/state/LIVED.nudge.txt"
R1="$(bash "$SCR/t3.sh" "$TMP" "$LOG" LIVED nudge "$HD/state/LIVED.nudge.txt")"
printf 'request v2\n' > "$HD/state/LIVED.nudge.txt"
R2="$(bash "$SCR/t3.sh" "$TMP" "$LOG" LIVED nudge "$HD/state/LIVED.nudge.txt")"
case "$R1|$R2" in "nudge scheduled for thread TD"*"|nudge already scheduled for thread TD"*"not queued twice"*) ok "D: second nudge while the first waits: not queued twice";; *) bad "D: dedupe" "$R1 | $R2";; esac
[ "$(pgrep -f "t3.sh $TMP .* --bg nudge" | wc -l | tr -d ' ')" = 1 ] && ok "D: one nudge worker" || bad "D: workers" "$(pgrep -fl "t3.sh $TMP")"
wait_for "handoff nudge to TD failed (thread busy?)" "$LOG" 6 >/dev/null
echo pending > "$HD/state/LIVED.t3clear"; rm -f "$F_BUSY"   # the handoff got scheduled before the thread went idle
wait_for "handoff nudge to TD dropped: the handoff is already scheduled (pending)" "$LOG" 10 && [ ! -s "$F_LOG.sent" ] && ok "D: nudge dropped once the handoff is scheduled (no duplicate request turn)" || bad "D: drop" "$(grep '\[t3\]' "$LOG" | tail -3; cat "$F_LOG.sent")"
[ ! -e "$HD/state/LIVED.nudge-pending" ] && ok "D: worker cleared its pending marker" || bad "D: marker"
# delivered nudge: the refreshed text goes out
rm -f "$HD/state/LIVED.t3clear"; touch "$F_BUSY"
printf 'request v1\n' > "$HD/state/LIVED.nudge.txt"; bash "$SCR/t3.sh" "$TMP" "$LOG" LIVED nudge "$HD/state/LIVED.nudge.txt" >/dev/null
printf 'request v2\n' > "$HD/state/LIVED.nudge.txt"; bash "$SCR/t3.sh" "$TMP" "$LOG" LIVED nudge "$HD/state/LIVED.nudge.txt" >/dev/null
rm -f "$F_BUSY"; wait_for "sent handoff nudge turn to TD" "$LOG" 10 >/dev/null
[ "$(grep -c "^request" "$F_LOG.sent")" = 1 ] && grep -q "request v2" "$F_LOG.sent" && ok "D: exactly one nudge turn, with the latest text" || bad "D: sent" "$(cat "$F_LOG.sent")"
# the Stop hook does not count an undelivered request as a new attempt
pkill -f "t3.sh $TMP" 2>/dev/null; sleep 0.3; rm -f "$HD/state/LIVEE.json"
row TE pe LIVEE 1 5 2026-11-25T08:00:00Z; active TE pe; export T3CODE_THREAD_ID=TE; touch "$F_BUSY"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":5000}}}' > "$TMP/tx/LIVEE.jsonl"
stop() { echo "{\"transcript_path\":\"$TMP/tx/LIVEE.jsonl\",\"session_id\":\"LIVEE\",\"stop_hook_active\":false}" | bash "$SCR/handoff-stop.sh"; }
stop >/dev/null; stop >/dev/null
[ "$(state_get LIVEE final_attempts)" = 1 ] && grep -q "handoff request not delivered yet (nudge worker pending)" "$LOG" && ok "D: Stop before the nudge went out: not a second attempt" || bad "D: attempts" "$(state_get LIVEE final_attempts) $(grep '\[stop\]' "$LOG" | tail -2)"
rm -f "$F_BUSY"; pkill -f "t3.sh $TMP" 2>/dev/null

printf '\npassed: %d  failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
