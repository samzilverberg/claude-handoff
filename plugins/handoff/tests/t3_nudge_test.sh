#!/bin/bash
# Tests for the T3 separate-turn nudge: handoff-stop.sh emit_nudge/t3_nudge and t3-autoclear.sh (nudge + clear
# modes, busy retry, session re-check, dry-run, non-T3 fallback). Uses a fake t3ctl on PATH and a tiny sqlite
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
export HANDOFF_T3_DB="$TMP/state.sqlite"
export HANDOFF_T3_SEND_TIMEOUT=25
export T3_FAKE_LOG="$TMP/t3ctl.calls" T3_FAKE_BUSY="$TMP/busy"
HD="$TMP/.claude/handoff"; LOG="$HD/hooks.log"

# fake t3ctl: logs every call; `threads send` fails while $T3_FAKE_BUSY exists; --stdin body saved aside
mkdir -p "$TMP/bin"
cat > "$TMP/bin/t3ctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$T3_FAKE_LOG"
case "$1 $2" in
  "threads wait") exit 0;;
  "threads send") [ -e "$T3_FAKE_BUSY" ] && { echo "thread is running" >&2; exit 1; }
                  case " $* " in *" --stdin "*) cat > "$T3_FAKE_LOG.stdin";; esac; exit 0;;
esac
exit 0
EOF
chmod +x "$TMP/bin/t3ctl"; export PATH="$TMP/bin:$PATH"

sqlite3 "$HANDOFF_T3_DB" "create table provider_session_runtime(thread_id text, resume_cursor_json text);
  create table projection_thread_sessions(thread_id text, provider_session_id text);
  insert into provider_session_runtime values('THREAD1','{\"resume\":\"SID1\"}');"

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
wait_for "failed (thread busy?); retrying" "$CLOG" 6 && ok "C: retry logged while busy" || bad "C: no retry" "$(tail -3 "$CLOG")"
rm -f "$T3_FAKE_BUSY"
wait_for "sent /clear to THREAD1" "$CLOG" 12 && ok "C: /clear sent once the thread went idle" || bad "C: /clear never sent" "$(tail -3 "$CLOG")"
[ "$(grep -c "threads send THREAD1 /clear" "$T3_FAKE_LOG")" -ge 2 ] && ok "C: send attempted more than once" || bad "C: attempts" "$(cat "$T3_FAKE_LOG")"

# --- D. session re-check: thread remapped to another session before the retry -> nothing sent -------
reset_fake; touch "$T3_FAKE_BUSY"; printf 'nudge body\n' > "$TMP/n.txt"; DLOG="$TMP/d.log"
bash "$SCR/t3-autoclear.sh" "$TMP" "$DLOG" SID1 nudge "$TMP/n.txt" >/dev/null
wait_for "failed (thread busy?); retrying" "$DLOG" 6 >/dev/null
sqlite3 "$HANDOFF_T3_DB" "update provider_session_runtime set resume_cursor_json='{\"resume\":\"OTHER\"}' where thread_id='THREAD1';"
rm -f "$T3_FAKE_BUSY"
wait_for "now maps to session 'OTHER', not SID1; nudge NOT sent" "$DLOG" 12 && ok "D: remapped thread is left alone" || bad "D: re-check" "$(tail -3 "$DLOG")"
[ -e "$T3_FAKE_LOG.stdin" ] && bad "D: nudge must not be sent after remap" || ok "D: no nudge body sent"
sqlite3 "$HANDOFF_T3_DB" "update provider_session_runtime set resume_cursor_json='{\"resume\":\"SID1\"}' where thread_id='THREAD1';"

# --- E. dry-run resolves but sends nothing ---------------------------------------------------------
reset_fake
R="$(HANDOFF_T3_DRYRUN=1 bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" SID1 nudge "$TMP/n.txt")"
case "$R" in *"nudge scheduled for thread THREAD1"*) ok "E: dry-run reports the thread";; *) bad "E: dry-run output" "$R";; esac
sleep 1; [ -e "$T3_FAKE_LOG" ] && bad "E: dry-run must not call t3ctl" "$(cat "$T3_FAKE_LOG")" || ok "E: no t3ctl call in dry-run"

# --- F. unknown session / non-T3: Stop hook falls back to the in-turn nudge -------------------------
reset_fake
OUT="$(hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID9\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && ok "F: unknown session -> additionalContext fallback" || bad "F: fallback missing" "$OUT"
echo "$OUT" | grep -q "T3 turn not used: .*not found in T3 state db" && ok "F: fallback names the reason" || bad "F: reason" "$OUT"
OUT="$(HANDOFF_T3_AUTOCLEAR=false hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID8\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && ! echo "$OUT" | grep -q "T3 turn" && ok "F: T3_AUTOCLEAR=false keeps the plain in-turn nudge" || bad "F: non-T3 path" "$OUT"
OUT="$(HANDOFF_T3_NUDGE_TURN=false hook handoff-stop.sh "{\"transcript_path\":\"$T\",\"session_id\":\"SID7\",\"stop_hook_active\":false}")"
echo "$OUT" | grep -q additionalContext && echo "$OUT" | grep -q "T3 turn not used: T3_NUDGE_TURN=false" && ok "F: T3_NUDGE_TURN=false -> in-turn nudge, reason named" || bad "F: T3_NUDGE_TURN=false" "$OUT"
[ -e "$T3_FAKE_LOG" ] && bad "F: t3ctl must not be called in fallback cases" "$(cat "$T3_FAKE_LOG")" || ok "F: t3ctl untouched"

# --- G. bad mode / missing nudge file are refused up front ------------------------------------------
R="$(bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" SID1 bogus)"; case "$R" in *"unknown mode"*) ok "G: unknown mode refused";; *) bad "G: unknown mode" "$R";; esac
R="$(bash "$SCR/t3-autoclear.sh" "$TMP" "$LOG" SID1 nudge "$TMP/nope.txt")"; case "$R" in *"nudge file missing"*) ok "G: missing nudge file refused";; *) bad "G: missing file" "$R";; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
