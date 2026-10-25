#!/bin/bash
# Tests for the T3 separate-turn nudge: handoff-stop.sh emit_nudge/t3_nudge and t3-autoclear.sh (nudge + clear
# modes, busy retry, session re-check, dry-run, non-T3 fallback, preflight, /clear chain). Uses a fake t3ctl on PATH and a tiny v2 sqlite
# state db. Pure bash, macOS. Run: bash plugins/handoff/tests/t3_nudge_test.sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"          # plugins/handoff
SCR="$DIR/scripts"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'pkill -f "t3-autoclear.sh --bg $TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP"
export CLAUDE_HANDOFF_NESTED=""
export HANDOFF_THRESHOLD=1000 HANDOFF_LIVE_FROM=0
export HANDOFF_T3_AUTOCLEAR=true
export __CFBundleIdentifier=com.t3tools.t3code      # host guard: pretend T3 Code spawned us
export HANDOFF_T3_DB="$TMP/statev2.sqlite"
export HANDOFF_T3_SEND_TIMEOUT=25
export T3_FAKE_LOG="$TMP/t3ctl.calls" T3_FAKE_BUSY="$TMP/busy" T3_FAKE_VERSION=0.1.2
HD="$TMP/.claude/handoff"; LOG="$HD/hooks.log"

# fake t3ctl: logs every call; `threads send` fails while $T3_FAKE_BUSY exists; --stdin body saved aside;
# `env` reports $T3_FAKE_VERSION (empty = no server); `threads list -i X` says missing when X = $T3_FAKE_MISSING
mkdir -p "$TMP/bin"
cat > "$TMP/bin/t3ctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$T3_FAKE_LOG"
case "$1 $2" in
  "env ") [ -n "$T3_FAKE_VERSION" ] || { echo '{"error":{"code":"no_server"}}'; exit 3; }
          echo "{\"serverVersion\":\"$T3_FAKE_VERSION\",\"supported\":true}"; exit 0;;
  "threads list") id="${4:-}"; st=idle; [ "$id" = "${T3_FAKE_MISSING:-}" ] && st=missing
                  echo "[{\"id\":\"$id\",\"status\":\"$st\"}]"; exit 0;;
  "threads wait") exit 0;;
  "threads send") [ -e "$T3_FAKE_BUSY" ] && { echo "thread is running" >&2; exit 1; }
                  case " $* " in *" --stdin "*) cat > "$T3_FAKE_LOG.stdin";; esac; exit 0;;
esac
exit 0
EOF
chmod +x "$TMP/bin/t3ctl"; export PATH="$TMP/bin:$PATH"

# T3 Code (Beta) >= 0.1.0 state db: thread <-> Claude session via payload_json.nativeThreadRef.nativeId
V2T=orchestration_v2_projection_provider_threads
v2row() { sqlite3 "$HANDOFF_T3_DB" "insert into $V2T values('$1','${3:-2026-10-25T08:00:00Z}','{\"nativeThreadRef\":{\"nativeId\":\"$2\"}}');"; }
sqlite3 "$HANDOFF_T3_DB" "create table $V2T(thread_id text, updated_at text, payload_json text);"
v2row THREAD1 SID1

# shellcheck disable=SC1090
source "$SCR/handoff-lib.sh"
hook() { echo "$2" | bash "$SCR/$1"; }
big_transcript() { printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":5000}}}' > "$1"; }
# wait_for <grep -F pattern> <file> [secs]
wait_for() { local i=0; while [ $i -lt $((${3:-12}*4)) ]; do grep -qsF -- "$1" "$2" 2>/dev/null && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
reset_fake() { rm -f "$T3_FAKE_LOG" "$T3_FAKE_LOG.stdin" "$T3_FAKE_BUSY"; }

T="$TMP/t.jsonl"; big_transcript "$T"

# --- A. Stop at threshold in T3 mode: nudge goes out as its own turn, not as additionalContext ----
reset_fake
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID1\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && bad "A: no additionalContext when the T3 turn is scheduled" "$OUT" || ok "A: no in-turn nudge"
echo "$OUT" | grep -q "separate T3 turn" && ok "A: systemMessage says separate turn" || bad "A: systemMessage" "$OUT"
[ "$(state_get SID1 final_attempts)" = "1" ] && ok "A: final_attempts=1" || bad "A: final_attempts" "$(state_get SID1 final_attempts)"
grep -q "nudge scheduled for thread THREAD1 (matched by session id" "$LOG" && ok "A: helper resolved by session id" || bad "A: helper log" "$(cat "$LOG")"
wait_for "threads send THREAD1 --stdin" "$T3_FAKE_LOG" && ok "A: t3ctl send --stdin called" || bad "A: t3ctl send not called" "$(cat "$T3_FAKE_LOG" 2>/dev/null)"
grep -q "threads wait THREAD1" "$T3_FAKE_LOG" && ok "A: waited for idle first" || bad "A: no wait"
grep -q '^\[handoff plugin\]' "$T3_FAKE_LOG.stdin" && grep -q "Write the handoff document" "$T3_FAKE_LOG.stdin" && grep -q "Standing instructions" "$T3_FAKE_LOG.stdin" \
  && ok "A: nudge body carries the instruction and sections" || bad "A: nudge body" "$(head -c 300 "$T3_FAKE_LOG.stdin" 2>/dev/null)"
wait_for "sent handoff nudge turn to THREAD1" "$LOG" && ok "A: hooks.log records the send" || bad "A: hooks.log send line" "$(cat "$LOG")"

# --- B. End of the nudge turn (stop_hook_active=false, complete file): publish + clear scheduled --------
reset_fake
printf '# Handoff\n## Goal\ng\n## Standing instructions\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\no\n' > "$HD/sessions/SID1.md"
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID1\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q "auto-clear scheduled" && ok "B: clear scheduled after the nudge turn" || bad "B: clear not scheduled" "$OUT"
[ -s "$HD/current.md" ] && grep -q "## Goal" "$HD/current.md" && ok "B: handoff published" || bad "B: not published"
wait_for "sent /handoff:resume to THREAD1" "$LOG" && ok "B: /clear + /handoff:resume sent" || bad "B: resume not sent" "$(cat "$LOG")"
grep -q "threads send THREAD1 /clear" "$T3_FAKE_LOG" && ok "B: /clear via t3ctl" || bad "B: /clear call" "$(cat "$T3_FAKE_LOG")"

# --- C. busy thread: send fails, helper retries after the next idle --------------------------------
reset_fake; touch "$T3_FAKE_BUSY"; CLOG="$TMP/c.log"      # own log: hooks.log already has B's "sent /clear"
bash "$SCR/t3-autoclear.sh" "$TMP" "$CLOG" SID1 clear >/dev/null
wait_for "failed (thread busy?): thread is running; retrying" "$CLOG" 6 && ok "C: retry logged while busy" || bad "C: no retry" "$(tail -3 "$CLOG")"
rm -f "$T3_FAKE_BUSY"
wait_for "sent /clear to THREAD1" "$CLOG" 12 && ok "C: /clear sent once the thread went idle" || bad "C: /clear never sent" "$(tail -3 "$CLOG")"
[ "$(grep -c "threads send THREAD1 /clear" "$T3_FAKE_LOG")" -ge 2 ] && ok "C: send attempted more than once" || bad "C: attempts" "$(cat "$T3_FAKE_LOG")"

# --- D. session re-check: thread remapped to another session before the retry -> nothing sent -------
reset_fake; touch "$T3_FAKE_BUSY"; printf 'nudge body\n' > "$TMP/n.txt"; DLOG="$TMP/d.log"
bash "$SCR/t3-autoclear.sh" "$TMP" "$DLOG" SID1 nudge "$TMP/n.txt" >/dev/null
wait_for "failed (thread busy?): thread is running; retrying" "$DLOG" 6 >/dev/null
v2row THREAD1 OTHER 2026-10-25T09:00:00Z     # newer row wins
rm -f "$T3_FAKE_BUSY"
wait_for "now maps to session 'OTHER', not SID1; nudge NOT sent" "$DLOG" 12 && ok "D: remapped thread is left alone" || bad "D: re-check" "$(tail -3 "$DLOG")"
[ -e "$T3_FAKE_LOG.stdin" ] && bad "D: nudge must not be sent after remap" || ok "D: no nudge body sent"
sqlite3 "$HANDOFF_T3_DB" "delete from $V2T where payload_json like '%OTHER%';"

# --- E. dry-run resolves but sends nothing ---------------------------------------------------------
reset_fake
R="$(HANDOFF_T3_DRYRUN=1 bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" SID1 nudge "$TMP/n.txt")"
case "$R" in *"nudge scheduled for thread THREAD1"*) ok "E: dry-run reports the thread";; *) bad "E: dry-run output" "$R";; esac
sleep 1; grep -qsE "threads (send|wait)" "$T3_FAKE_LOG" && bad "E: dry-run must not wait or send" "$(cat "$T3_FAKE_LOG")" || ok "E: dry-run only reads (env, list), never waits or sends"

# --- F. unknown session / non-T3: Stop hook falls back to the in-turn nudge -------------------------
reset_fake
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID9\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && ok "F: unknown session -> additionalContext fallback" || bad "F: fallback missing" "$OUT"
echo "$OUT" | grep -q "T3 turn not used: .*not found in T3 state db" && ok "F: fallback names the reason" || bad "F: reason" "$OUT"
OUT="$(HANDOFF_T3_AUTOCLEAR=false hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID8\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && ! echo "$OUT" | grep -q "T3 turn" && ok "F: T3_AUTOCLEAR=false keeps the plain in-turn nudge" || bad "F: non-T3 path" "$OUT"
OUT="$(HANDOFF_T3_NUDGE_TURN=false hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID7\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && echo "$OUT" | grep -q "T3 turn not used: T3_NUDGE_TURN=false" && ok "F: T3_NUDGE_TURN=false -> in-turn nudge, reason named" || bad "F: T3_NUDGE_TURN=false" "$OUT"
grep -qsE "threads (send|wait)" "$T3_FAKE_LOG" && bad "F: fallback cases must not wait or send" "$(cat "$T3_FAKE_LOG")" || ok "F: no wait/send in fallback cases"

# --- G. bad mode / missing nudge file are refused up front ------------------------------------------
R="$(bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" SID1 bogus)"; case "$R" in *"unknown mode"*) ok "G: unknown mode refused";; *) bad "G: unknown mode" "$R";; esac
R="$(bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" SID1 nudge "$TMP/nope.txt")"; case "$R" in *"nudge file missing"*) ok "G: missing nudge file refused";; *) bad "G: missing file" "$R";; esac

# --- H. /clear ancestor chain: T3 v2 keeps the pre-clear session id on the thread -------------------
v2row THREADV2 V2A
R="$(HANDOFF_T3_DRYRUN=1 bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" V2A clear)"
case "$R" in *"thread THREADV2 (matched by session id"*) ok "H: resolves by nativeThreadRef.nativeId";; *) bad "H: direct" "$R";; esac
# V2A was /cleared into V2B, V2B into V2C; T3 still has V2A on record
tombstone_set V2A 1 >/dev/null; tombstone_link V2A V2B >/dev/null; tombstone_set V2B 1 >/dev/null; tombstone_link V2B V2C >/dev/null
R="$(HANDOFF_T3_DRYRUN=1 bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" V2C clear)"
case "$R" in *"thread THREADV2 (matched by pre-clear ancestor V2A, 2 /clear(s) back"*) ok "H: post-clear session resolved via tombstone chain";; *) bad "H: chain" "$R";; esac
R="$(HANDOFF_T3_DRYRUN=1 bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" V2Z clear)"
case "$R" in *"not found in T3 state db statev2.sqlite"*) ok "H: unrelated session still skipped";; *) bad "H: unrelated" "$R";; esac
# bg re-check compares against the matched ancestor, so the clear is actually sent
reset_fake; HLOG="$TMP/h.log"
bash "$SCR/t3-autoclear.sh" "$TMP" "$HLOG" V2C clear >/dev/null
wait_for "sent /clear to THREADV2" "$HLOG" 12 && ok "H: /clear sent for chained session (re-check passes)" || bad "H: chained send" "$(tail -3 "$HLOG")"

# --- I. Stop hook: a skipped auto-clear does not latch t3_scheduled; retried on the next Stop --------
reset_fake
cp "$HD/sessions/SID1.md" "$HD/sessions/SID6.md"; state_set SID6 final_written_ctx 5000
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID6\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q "auto-clear skipped" && ok "I: unknown session -> auto-clear skipped" || bad "I: skip msg" "$OUT"
[ -z "$(state_get SID6 t3_scheduled)" ] && ok "I: t3_scheduled not latched on skip" || bad "I: latched" "$(state_get SID6 t3_scheduled)"
v2row THREAD6 SID6
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID6\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q "auto-clear scheduled" && ok "I: retried and scheduled on the next Stop" || bad "I: retry" "$OUT"
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID6\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q "already scheduled" && ! echo "$OUT" | grep -q "unless T3_AUTOCLEAR" && ok "I: later Stop says already scheduled" || bad "I: already" "$OUT"

# --- J. preflight: each broken moving part is refused with a reason naming it ----------------------
chk() { bash "$SCR/t3-autoclear.sh" "$TMP" "$TMP/j.log" "$@" 2>&1; }
R="$(chk "" check)"; RC=$?; [ $RC -eq 0 ] && case "$R" in "ok: T3 Code 0.1.2"*) true;; *) false;; esac && ok "J: check ok on a healthy setup" || bad "J: check ok" "rc=$RC $R"
R="$(chk SID1 check)"; case "$R" in *"session SID1 -> thread THREAD1 (idle"*) ok "J: check with a session resolves the thread";; *) bad "J: check sid" "$R";; esac
R="$(HANDOFF_T3_DB="$TMP/nope.sqlite" chk SID1 clear)"; case "$R" in *"not found; T3_AUTOCLEAR needs T3 Code (Beta) >= 0.1.0"*"clear skipped") ok "J: missing db named, requirement stated";; *) bad "J: missing db" "$R";; esac
mkdir -p "$TMP/oldhome/.t3/userdata"; touch "$TMP/oldhome/.t3/userdata/state.sqlite"
R="$(HOME="$TMP/oldhome" HANDOFF_T3_DB= chk SID1 check)"; RC=$?; [ $RC -eq 1 ] && case "$R" in *"only the legacy T3 db"*"T3 Code too old"*) true;; *) false;; esac && ok "J: legacy-only T3 called too old (check rc=1)" || bad "J: legacy" "rc=$RC $R"
sqlite3 "$TMP/empty.sqlite" "create table x(a);"
R="$(HANDOFF_T3_DB="$TMP/empty.sqlite" chk SID1 clear)"; case "$R" in *"has no table $V2T"*) ok "J: missing table named";; *) bad "J: table" "$R";; esac
sqlite3 "$TMP/cols.sqlite" "create table $V2T(thread_id text, updated_at text);"
R="$(HANDOFF_T3_DB="$TMP/cols.sqlite" chk SID1 clear)"; case "$R" in *"lacks column payload_json"*) ok "J: missing column named";; *) bad "J: column" "$R";; esac
echo "not a db" > "$TMP/junk.sqlite"
R="$(HANDOFF_T3_DB="$TMP/junk.sqlite" chk SID1 clear)"; case "$R" in *"cannot read T3 db"*) ok "J: unreadable/corrupt db reported";; *) bad "J: junk" "$R";; esac
sqlite3 "$TMP/shape.sqlite" "create table $V2T(thread_id text, updated_at text, payload_json text); insert into $V2T values('T','x','{\"other\":1}');"
R="$(HANDOFF_T3_DB="$TMP/shape.sqlite" chk SID1 clear)"; case "$R" in *"carry no payload_json.nativeThreadRef.nativeId"*) ok "J: payload shape change reported";; *) bad "J: shape" "$R";; esac
R="$(T3_FAKE_VERSION= chk SID1 clear)"; case "$R" in *"not reachable via t3ctl within 5 s (no_server)"*) ok "J: T3 server down reported";; *) bad "J: no server" "$R";; esac
R="$(T3_FAKE_VERSION=0.0.9 chk SID1 clear)"; case "$R" in *"0.0.9 < 0.1.0"*) ok "J: old T3 server version refused";; *) bad "J: old version" "$R";; esac
R="$(T3_FAKE_MISSING=THREAD1 chk SID1 clear)"; case "$R" in *"does not know that thread"*) ok "J: thread unknown to T3 refused";; *) bad "J: missing thread" "$R";; esac
R="$(PATH="/usr/bin:/bin" chk SID1 clear)"; case "$R" in *"t3ctl not on PATH"*) ok "J: missing t3ctl named";; *) bad "J: t3ctl" "$R";; esac

# --- K. SessionStart warns early when T3_AUTOCLEAR is on but broken, silent when healthy -------------
OUT="$(hook handoff-sessionstart.sh '{"source":"startup","session_id":"SSK1"}')"
echo "$OUT" | grep -q "auto-clear will not work" && bad "K: healthy setup must not warn" "$OUT" || ok "K: healthy -> no warning"
OUT="$(T3_FAKE_VERSION= hook handoff-sessionstart.sh '{"source":"resume","session_id":"SSK1"}')"
echo "$OUT" | jq -e '.systemMessage | test("auto-clear will not work here \\(T3 Code server not reachable")' >/dev/null 2>&1 && ok "K: broken -> systemMessage names the reason" || bad "K: warn" "$OUT"
OUT="$(T3_FAKE_VERSION= HANDOFF_T3_AUTOCLEAR=false hook handoff-sessionstart.sh '{"source":"startup","session_id":"SSK1"}')"
[ -z "$OUT" ] && ok "K: T3_AUTOCLEAR=false -> no preflight" || bad "K: off" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
