#!/bin/bash
# Tests for the T3 Code layer: t3.sh (check / nudge / clear / alias / recover, preflight, /clear chain), the Stop
# hook's separate-turn nudge and automatic /clear, SessionStart(clear)'s alias of T3's session, warning and
# stale-session note, and the UserPromptSubmit recover/block. Uses a fake t3ctl on PATH and a tiny v2 sqlite state db.
# Pure bash, macOS. Run: bash plugins/handoff/tests/t3_test.sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"          # plugins/handoff
SCR="$DIR/scripts"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'pkill -f "t3.sh $TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP"
export CLAUDE_HANDOFF_NESTED=""
export HANDOFF_THRESHOLD=1000 HANDOFF_LIVE_FROM=0
export HANDOFF_T3_AUTOCLEAR=true
export __CFBundleIdentifier=com.t3tools.t3code      # host guard: pretend T3 Code spawned us
export HANDOFF_T3_DB="$TMP/statev2.sqlite"
export HANDOFF_T3_SEND_TIMEOUT=25 HANDOFF_T3_CLEAR_WAIT=3
export T3_FAKE_LOG="$TMP/t3ctl.calls" T3_FAKE_BUSY="$TMP/busy" T3_FAKE_VERSION=0.1.2 T3_FAKE_ROOT="$TMP" T3_FAKE_TX="$TMP/tx" T3_FAKE_LIVE="$TMP/live" T3_FAKE_SCR="$(cd "$(dirname "$0")/../scripts" && pwd)"
HD="$TMP/.claude/handoff"; LOG="$HD/hooks.log"

# fake t3ctl: logs every call (stdin bodies to $T3_FAKE_LOG.stdin, all of them appended to .sent). `env` reports
# $T3_FAKE_VERSION (empty = no server). `threads list -i X`: idle, titled "Title of X", worktree $T3_FAKE_ROOT (or
# $T3_FAKE_WT), missing when X = $T3_FAKE_MISSING. `threads send` fails while $T3_FAKE_BUSY exists. A "/clear" send
# plays Claude Code's /clear in the thread's process: SessionEnd(clear) of the live session ($T3_FAKE_LIVE, else the
# session the db maps the thread to), then SessionStart(clear) of a new session CLRn with transcript $T3_FAKE_TX/CLRn.jsonl
# (skipped when $T3_FAKE_NOCLEAR is set).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/t3ctl" <<'EOF2'
#!/bin/bash
echo "$*" >> "$T3_FAKE_LOG"
case "$1 $2" in
  "env ") [ -n "$T3_FAKE_VERSION" ] || { echo '{"error":{"code":"no_server"}}'; exit 3; }
          echo "{\"serverVersion\":\"$T3_FAKE_VERSION\",\"supported\":true}"; exit 0;;
  "projects ") echo "[{\"id\":\"P1\",\"workspaceRoot\":\"$T3_FAKE_ROOT\"}]"; exit 0;;
  "threads list") id="${4:-}"; st=idle; [ "$id" = "${T3_FAKE_MISSING:-}" ] && st=missing
                  echo "[{\"id\":\"$id\",\"status\":\"$st\",\"title\":\"Title of $id\",\"projectId\":\"P1\",\"worktreePath\":\"${T3_FAKE_WT:-$T3_FAKE_ROOT}\"}]"; exit 0;;
  "threads wait") exit 0;;
  "threads send") [ -e "$T3_FAKE_BUSY" ] && { echo "thread is running" >&2; exit 1; }
                  case " $* " in *" --stdin "*) cat > "$T3_FAKE_LOG.stdin"; { cat "$T3_FAKE_LOG.stdin"; echo; echo "--"; } >> "$T3_FAKE_LOG.sent";; esac
                  if [ "$(cat "$T3_FAKE_LOG.stdin" 2>/dev/null)" = "/clear" ] && [ -z "$T3_FAKE_NOCLEAR" ]; then
                    live="$(cat "$T3_FAKE_LIVE" 2>/dev/null)"
                    [ -n "$live" ] || live="$(sqlite3 "$HANDOFF_T3_DB" "select json_extract(payload_json,'\$.nativeThreadRef.nativeId') from orchestration_v2_projection_provider_threads where thread_id='$3' order by updated_at desc limit 1")"
                    n=$(( $(cat "$T3_FAKE_TX/.n" 2>/dev/null || echo 0) + 1 )); echo $n > "$T3_FAKE_TX/.n"; new="CLR$n"; : > "$T3_FAKE_TX/$new.jsonl"
                    echo "{\"reason\":\"clear\",\"session_id\":\"$live\",\"transcript_path\":\"$T3_FAKE_TX/$live.jsonl\"}" | bash "$T3_FAKE_SCR/handoff-sessionend.sh" >/dev/null
                    echo "{\"source\":\"clear\",\"session_id\":\"$new\",\"transcript_path\":\"$T3_FAKE_TX/$new.jsonl\"}" | bash "$T3_FAKE_SCR/handoff-sessionstart.sh" >/dev/null
                    echo "$new" > "$T3_FAKE_LIVE"
                  fi; exit 0;;
esac
exit 0
EOF2
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
reset_fake() { rm -f "$T3_FAKE_LOG" "$T3_FAKE_LOG.stdin" "$T3_FAKE_LOG.sent" "$T3_FAKE_BUSY" "$T3_FAKE_LIVE"; }
mkdir -p "$TMP/tx"
full_doc() { printf '# Handoff\n## Goal\ng\n## Standing instructions\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\no\n' > "$1"; }
stop_in() { echo "{\"transcript_path\":\"$T\",\"session_id\":\"$1\",\"stop_hook_active\":false}"; }

T="$TMP/t.jsonl"; big_transcript "$T"

# --- A. Stop at threshold in T3 mode: nudge goes out as its own turn, not as additionalContext ----
reset_fake
OUT="$(hook handoff-stop.sh "$(stop_in SID1)")"
echo "$OUT" | grep -q additionalContext && bad "A: no additionalContext when the T3 turn is scheduled" "$OUT" || ok "A: no in-turn nudge"
echo "$OUT" | grep -q "separate T3 turn" && ok "A: systemMessage says separate turn" || bad "A: systemMessage" "$OUT"
grep -q "nudge scheduled for thread THREAD1 (matched by session id" "$LOG" && ok "A: helper resolved by session id" || bad "A: helper log" "$(tail -3 "$LOG")"
wait_for "threads send THREAD1 --stdin" "$T3_FAKE_LOG" && ok "A: t3ctl send --stdin called" || bad "A: t3ctl send not called" "$(cat "$T3_FAKE_LOG" 2>/dev/null)"
grep -q "threads wait THREAD1" "$T3_FAKE_LOG" && ok "A: waited for idle first" || bad "A: no wait"
grep -q '^\[handoff plugin\]' "$T3_FAKE_LOG.stdin" && grep -q "Write the handoff document" "$T3_FAKE_LOG.stdin" \
  && ok "A: nudge body carries the instruction" || bad "A: nudge body" "$(head -c 300 "$T3_FAKE_LOG.stdin" 2>/dev/null)"

# --- B. handoff written: next Stop stages it; /clear in the thread, T3's session aliased, /handoff:resume --------
reset_fake; full_doc "$HD/sessions/SID1.md"; echo '{"orig":"SID1 content"}' > "$TMP/tx/SID1.jsonl"
OUT="$(hook handoff-stop.sh "$(stop_in SID1)")"
echo "$OUT" | grep -q "once this turn ends the plugin sends /clear and /handoff:resume to this thread" && ok "B: automatic handoff scheduled message" || bad "B: message" "$OUT"
echo "$OUT" | grep -qi "new thread\|unless T3_AUTOCLEAR\|compact" && bad "B: no new-thread / manual / compact wording" "$OUT" || ok "B: no new-thread / manual / compact wording"
[ -s "$HD/current.md" ] && ok "B: handoff published" || bad "B: not published"
wait_for "sent /handoff:resume to THREAD1: handoff to session CLR1 complete" "$LOG" && ok "B: /clear + /handoff:resume done" || bad "B: flow" "$(tail -6 "$LOG")"
[ "$(sed -n 1p "$T3_FAKE_LOG.sent")" = "/clear" ] && [ "$(sed -n 3p "$T3_FAKE_LOG.sent")" = "/handoff:resume" ] && ok "B: sent exactly /clear, then /handoff:resume" || bad "B: sends" "$(cat "$T3_FAKE_LOG.sent")"
[ -L "$TMP/tx/SID1.jsonl" ] && [ "$(readlink "$TMP/tx/SID1.jsonl")" = "CLR1.jsonl" ] && ok "B: T3's session transcript now links to the new session" || bad "B: link" "$(ls -la "$TMP/tx")"
grep -q "SID1 content" "$TMP/tx/SID1.jsonl.pre-handoff" && ok "B: original transcript kept as .pre-handoff" || bad "B: original kept"
grep -q "session SID1 (T3's) now follows CLR1" "$LOG" && ok "B: alias confirmed in the log" || bad "B: alias log" "$(grep '\[t3\]' "$LOG" | tail -4)"
[ "$(session_key CLR1)" = "SID1" ] && ok "B: new session keyed by T3's session id" || bad "B: key" "$(session_key CLR1)"
is_tombstoned SID1 && bad "B: aliased session must stay live" "$(cat "$HD/state/tombstones/SID1.json")" || ok "B: T3's session stays live (it is the new context now)"
[ ! -f "$HD/sessions/SID1.md" ] && ls "$HD/sessions/archive/" | grep -q '^SID1-' && ok "B: consumed handoff archived" || bad "B: archive"
[ -z "$(state_get SID1 t3_clear)" ] && [ -z "$(state_get SID1 final_attempts)" ] && ok "B: per-window state started over" || bad "B: state" "$(cat "$HD/state/SID1.json" 2>/dev/null)"
[ "$(cat "$HD/state/CLR1.t3clear" 2>/dev/null; cat "$HD/state/SID1.t3clear")" = "done:CLR1" ] && ok "B: outcome done" || bad "B: outcome"
grep -q "threads continue\|threads settle" "$T3_FAKE_LOG" && bad "B: no thread created or settled" || ok "B: no thread created or settled"
# next window, live process (CLR1): threshold again -> nudged again, doc keyed by T3's id
reset_fake; echo CLR1 > "$T3_FAKE_LIVE"
OUT="$(hook handoff-stop.sh "$(stop_in CLR1)")"
wait_for "threads send THREAD1 --stdin" "$T3_FAKE_LOG" && grep -q "Write the handoff document with the Write tool to $HD/sessions/SID1.md" "$T3_FAKE_LOG.stdin" && ok "B: next window nudges for sessions/<T3 id>.md" || bad "B: second window" "$OUT $(cat "$T3_FAKE_LOG.stdin" 2>/dev/null | head -c 300)"
grep -q "nudge scheduled for thread THREAD1 (matched by alias of SID1" "$LOG" && ok "B: post-clear session resolved via the alias" || bad "B: alias resolution" "$(grep '\[t3\]' "$LOG" | tail -2)"
# T3 respawns the process: it comes back as SID1 (reading CLR1's transcript through the link); same window state
OUT="$(hook handoff-sessionstart.sh '{"source":"resume","session_id":"SID1"}')"
echo "$OUT" | grep -q "STOP" && bad "B: respawn under T3's id is not a zombie" "$OUT" || ok "B: respawn under T3's id is not a zombie"
[ "$(state_get SID1 final_attempts)" = "1" ] && ok "B: respawned process keeps the window's state" || bad "B: respawn state" "$(cat "$HD/state/SID1.json")"
# second handoff from the respawned process: /clear of SID1 -> CLR2; the alias moves on, the original stays kept
reset_fake; echo SID1 > "$T3_FAKE_LIVE"; full_doc "$HD/sessions/SID1.md"
hook handoff-stop.sh "$(stop_in SID1)" >/dev/null
wait_for "handoff to session CLR2 complete" "$LOG" && [ "$(readlink "$TMP/tx/SID1.jsonl")" = "CLR2.jsonl" ] && ok "B: second handoff re-points the alias" || bad "B: second handoff" "$(grep '\[t3\]' "$LOG" | tail -4)"
grep -q "SID1 content" "$TMP/tx/SID1.jsonl.pre-handoff" && [ ! -e "$TMP/tx/SID1.jsonl.pre-handoff-"* ] 2>/dev/null && ok "B: original transcript untouched by the re-point" || bad "B: original after re-point" "$(ls "$TMP/tx")"

# --- C. busy thread: nudge send fails, helper retries after the next idle -----------------------------
reset_fake; touch "$T3_FAKE_BUSY"; CLOG="$TMP/c.log"; echo "body" > "$TMP/n.txt"
v2row THREADC SIDC
bash "$SCR/t3.sh" "$TMP" "$CLOG" SIDC nudge "$TMP/n.txt" >/dev/null
wait_for "failed (thread busy?): thread is running; retrying" "$CLOG" 6 && ok "C: retry logged while busy" || bad "C: no retry" "$(tail -3 "$CLOG")"
rm -f "$T3_FAKE_BUSY"
wait_for "sent handoff nudge turn to THREADC" "$CLOG" 12 && ok "C: sent once the thread went idle" || bad "C: never sent" "$(tail -3 "$CLOG")"

# --- D. session re-check: thread remapped before the retry -> nothing done ----------------------------
reset_fake; touch "$T3_FAKE_BUSY"; DLOG="$TMP/d.log"
bash "$SCR/t3.sh" "$TMP" "$DLOG" SIDC nudge "$TMP/n.txt" >/dev/null
wait_for "failed (thread busy?): thread is running; retrying" "$DLOG" 6 >/dev/null
v2row THREADC OTHER 2026-10-25T09:00:00Z     # newer row wins
rm -f "$T3_FAKE_BUSY"
wait_for "now maps to session 'OTHER', not SIDC; handoff nudge NOT sent" "$DLOG" 12 && ok "D: remapped thread is left alone" || bad "D: re-check" "$(tail -3 "$DLOG")"

# --- E. dry-run resolves but never waits or sends -----------------------------------------------------
reset_fake
v2row THREADE SIDE; full_doc "$HD/sessions/SIDE.md"
R="$(HANDOFF_T3_DRYRUN=1 bash "$SCR/t3.sh" "$TMP" "$LOG" SIDE clear "$HD/sessions/SIDE.md")"
case "$R" in *"scheduled for thread THREADE"*) ok "E: dry-run reports the thread";; *) bad "E: dry-run output" "$R";; esac
sleep 1; grep -qsE "threads (send|wait) [A-Z]" "$T3_FAKE_LOG" && bad "E: dry-run must not act" "$(cat "$T3_FAKE_LOG")" || ok "E: dry-run only reads"
[ -e "$HD/state/SIDE.t3clear" ] && bad "E: dry-run leaves no state" || ok "E: dry-run leaves no state"

# --- F. unknown session / T3 off: Stop hook falls back to the in-turn nudge ---------------------------
reset_fake
OUT="$(hook handoff-stop.sh "$(stop_in SID9)")"
echo "$OUT" | grep -q additionalContext && ok "F: unknown session -> additionalContext fallback" || bad "F: fallback missing" "$OUT"
echo "$OUT" | grep -q "T3 turn not used: .*not found in T3 state db" && ok "F: fallback names the reason" || bad "F: reason" "$OUT"
OUT="$(HANDOFF_T3_AUTOCLEAR=false hook handoff-stop.sh "$(stop_in SID8)")"
echo "$OUT" | grep -q additionalContext && ! echo "$OUT" | grep -q "T3 turn" && ok "F: T3_AUTOCLEAR=false keeps the plain in-turn nudge" || bad "F: non-T3 path" "$OUT"
OUT="$(HANDOFF_T3_NUDGE_TURN=false hook handoff-stop.sh "$(stop_in SID7)")"
echo "$OUT" | grep -q "T3 turn not used: T3_NUDGE_TURN=false" && ok "F: T3_NUDGE_TURN=false -> in-turn nudge, reason named" || bad "F: T3_NUDGE_TURN=false" "$OUT"
grep -qsE "threads (send|wait) [A-Z]" "$T3_FAKE_LOG" && bad "F: fallback cases must not act" "$(cat "$T3_FAKE_LOG")" || ok "F: nothing sent in fallback cases"

# --- G. bad mode / missing files are refused up front --------------------------------------------------
R="$(bash "$SCR/t3.sh" "$TMP" "$LOG" SID1 bogus)"; case "$R" in *"unknown mode"*) ok "G: unknown mode refused";; *) bad "G: unknown mode" "$R";; esac
R="$(bash "$SCR/t3.sh" "$TMP" "$LOG" SID1 nudge "$TMP/nope.txt")"; case "$R" in *"missing or empty"*) ok "G: missing nudge file refused";; *) bad "G: missing file" "$R";; esac
R="$(bash "$SCR/t3.sh" "$TMP" "$LOG" SID1 clear "$TMP/nope.md")"; case "$R" in *"missing or empty"*) ok "G: missing handoff doc refused";; *) bad "G: missing doc" "$R";; esac

# --- H. /clear ancestor chain (sessions /cleared in place by plugin <= 0.5) ------------------------------
v2row THREADV2 V2A
tombstone_set V2A 1 >/dev/null; tombstone_link V2A V2B >/dev/null; tombstone_set V2B 1 >/dev/null; tombstone_link V2B V2C >/dev/null
R="$(bash "$SCR/t3.sh" "$TMP" "$LOG" V2C check)"
case "$R" in *"V2C -> thread THREADV2 (idle, matched by pre-clear ancestor V2A, 2 /clear(s) back"*) ok "H: post-clear session resolved via tombstone chain";; *) bad "H: chain" "$R";; esac
R="$(bash "$SCR/t3.sh" "$TMP" "$LOG" V2Z check)"; case "$R" in *"not found in T3 state db statev2.sqlite"*) ok "H: unrelated session skipped";; *) bad "H: unrelated" "$R";; esac
[ "$(chain_tail V2A)" = "V2C" ] && ok "H: chain_tail follows to the newest session" || bad "H: chain_tail" "$(chain_tail V2A)"

# --- I. Stop hook: a skipped handoff does not latch; retried on the next Stop; a /clear that never lands is reported --
reset_fake
full_doc "$HD/sessions/SID6.md"; state_set SID6 final_written_ctx 5000
OUT="$(hook handoff-stop.sh "$(stop_in SID6)")"
echo "$OUT" | grep -q "Automatic T3 handoff skipped" && ok "I: unknown session -> skipped" || bad "I: skip msg" "$OUT"
[ -z "$(state_get SID6 t3_clear)" ] && ok "I: not latched on skip" || bad "I: latched"
v2row THREAD6 SID6
export T3_FAKE_NOCLEAR=1
hook handoff-stop.sh "$(stop_in SID6)" | grep -q "plugin sends /clear and /handoff:resume" && ok "I: retried and scheduled on the next Stop" || bad "I: retry"
wait_for "handoff of THREAD6 failed: no new session observed after /clear" "$LOG" 15 && ok "I: /clear that never lands is detected" || bad "I: fail log" "$(tail -3 "$LOG")"
unset T3_FAKE_NOCLEAR
grep -q "^/handoff:resume" "$T3_FAKE_LOG.sent" && bad "I: no /handoff:resume without a new session" || ok "I: no /handoff:resume without a new session"
OUT="$(hook handoff-stop.sh "$(stop_in SID6)")"
echo "$OUT" | grep -q "automatic T3 handoff failed (no new session" && echo "$OUT" | grep -q "/handoff:resume" && ok "I: later Stop reports the failure + manual path" || bad "I: failure msg" "$OUT"

# --- I2. alias guards ----------------------------------------------------------------------------------------
al() { HANDOFF_TRANSCRIPT="$TMP/tx/$1.jsonl" bash "$SCR/t3.sh" "$TMP" "$LOG" "$1" alias "$2"; }
v2row THREADA SIDA; : > "$TMP/tx/NA1.jsonl"
R="$(al NA1 SIDA)"; case "$R" in *"T3's session transcript $TMP/tx/SIDA.jsonl not found"*) ok "I2: missing T3 transcript -> no alias";; *) bad "I2: missing transcript" "$R";; esac
echo '{}' > "$TMP/tx/SIDA.jsonl"
sqlite3 "$HANDOFF_T3_DB" "insert into $V2T values('THREADH','2026-10-25T08:00:00Z','{\"nativeThreadRef\":{\"nativeId\":\"SIDH\"},\"nativeConversationHeadRef\":{\"nativeId\":\"msg1\"}}');"; echo '{}' > "$TMP/tx/SIDH.jsonl"; : > "$TMP/tx/NH1.jsonl"
R="$(al NH1 SIDH)"; case "$R" in *"pins a conversation head"*) ok "I2: pinned conversation head -> no alias";; *) bad "I2: head" "$R";; esac
[ ! -L "$TMP/tx/SIDH.jsonl" ] && ok "I2: nothing linked when refused" || bad "I2: linked anyway"
R="$(al SIDA SIDA)"; case "$R" in *"no alias needed"*|*"already records"*) ok "I2: T3 already on the new session -> nothing to do";; *) bad "I2: same id" "$R";; esac
R="$(HANDOFF_TRANSCRIPT="$TMP/elsewhere/NA1.jsonl" bash "$SCR/t3.sh" "$TMP" "$LOG" NA1 alias SIDA)"; case "$R" in *"not found (thread THREADA runs elsewhere?)"*) ok "I2: other transcript dir -> no alias";; *) bad "I2: other dir" "$R";; esac
R="$(T3_FAKE_VERSION= al NA1 SIDA)"; case "$R" in *"aliased T3's session SIDA"*) ok "I2: alias needs no T3 server (local only)";; *) bad "I2: local only" "$R";; esac

# --- J. preflight: each broken moving part is refused with a reason naming it -----------------------------
chk() { bash "$SCR/t3.sh" "$TMP" "$TMP/j.log" "$@" 2>&1; }
R="$(chk "" check)"; RC=$?; [ $RC -eq 0 ] && case "$R" in "ok: T3 Code 0.1.2"*) true;; *) false;; esac && ok "J: check ok on a healthy setup" || bad "J: check ok" "rc=$RC $R"
R="$(HANDOFF_T3_DB="$TMP/nope.sqlite" chk SID1 check)"; case "$R" in *"not found; T3 automation needs T3 Code (Beta) >= 0.1.0"*) ok "J: missing db named, requirement stated";; *) bad "J: missing db" "$R";; esac
mkdir -p "$TMP/oldhome/.t3/userdata"; touch "$TMP/oldhome/.t3/userdata/state.sqlite"
R="$(HOME="$TMP/oldhome" HANDOFF_T3_DB= chk SID1 check)"; RC=$?; [ $RC -eq 1 ] && case "$R" in *"only the legacy T3 db"*"T3 Code too old"*) true;; *) false;; esac && ok "J: legacy-only T3 called too old (rc=1)" || bad "J: legacy" "rc=$RC $R"
sqlite3 "$TMP/empty.sqlite" "create table x(a);"
R="$(HANDOFF_T3_DB="$TMP/empty.sqlite" chk SID1 check)"; case "$R" in *"has no table $V2T"*) ok "J: missing table named";; *) bad "J: table" "$R";; esac
sqlite3 "$TMP/cols.sqlite" "create table $V2T(thread_id text, updated_at text);"
R="$(HANDOFF_T3_DB="$TMP/cols.sqlite" chk SID1 check)"; case "$R" in *"lacks column payload_json"*) ok "J: missing column named";; *) bad "J: column" "$R";; esac
echo "not a db" > "$TMP/junk.sqlite"
R="$(HANDOFF_T3_DB="$TMP/junk.sqlite" chk SID1 check)"; case "$R" in *"cannot read T3 db"*) ok "J: corrupt db reported";; *) bad "J: junk" "$R";; esac
sqlite3 "$TMP/shape.sqlite" "create table $V2T(thread_id text, updated_at text, payload_json text); insert into $V2T values('T','x','{\"other\":1}');"
R="$(HANDOFF_T3_DB="$TMP/shape.sqlite" chk SID1 check)"; case "$R" in *"carry no payload_json.nativeThreadRef.nativeId"*) ok "J: payload shape change reported";; *) bad "J: shape" "$R";; esac
R="$(T3_FAKE_VERSION= chk SID1 check)"; case "$R" in *"not reachable via t3ctl within 5 s (no_server)"*) ok "J: T3 server down reported";; *) bad "J: no server" "$R";; esac
R="$(T3_FAKE_VERSION=0.0.9 chk SID1 check)"; case "$R" in *"0.0.9 < 0.1.0"*) ok "J: old T3 server refused";; *) bad "J: old version" "$R";; esac
R="$(T3_FAKE_MISSING=THREAD1 chk SID1 check)"; case "$R" in *"does not know that thread"*) ok "J: thread unknown to T3 refused";; *) bad "J: missing thread" "$R";; esac
R="$(T3_FAKE_WT=/somewhere/else chk SID1 check)"; case "$R" in *"works in /somewhere/else, not in this project dir"*) ok "J: thread of another dir refused";; *) bad "J: other dir" "$R";; esac
R="$(PATH="/usr/bin:/bin" chk SID1 check)"; case "$R" in *"t3ctl not on PATH"*) ok "J: missing t3ctl named";; *) bad "J: t3ctl" "$R";; esac

# --- K. SessionStart: early warning when broken; stale-session note names where the work continues -------
OUT="$(hook handoff-sessionstart.sh '{"source":"startup","session_id":"SSK1"}')"
echo "$OUT" | grep -q "will not work" && bad "K: healthy setup must not warn" "$OUT" || ok "K: healthy -> no warning"
OUT="$(T3_FAKE_VERSION= hook handoff-sessionstart.sh '{"source":"resume","session_id":"SSK1"}')"
echo "$OUT" | jq -e '.systemMessage | test("will not work here \\(T3 Code server not reachable")' >/dev/null 2>&1 && ok "K: broken -> systemMessage names the reason" || bad "K: warn" "$OUT"
OUT="$(hook handoff-sessionstart.sh '{"source":"resume","session_id":"V2A"}')"
echo "$OUT" | grep -q 'claude --resume V2C' && ok "K: stale note names the newest session of the chain" || bad "K: chain tail" "$OUT"

# --- L. UserPromptSubmit: zombie of a /clear chain (plugin <= 0.5) -> blocked, recovered via /clear -------------
reset_fake
OUT="$(hook handoff-userprompt.sh '{"session_id":"SIDC","prompt":"hi"}')"
[ -z "$OUT" ] && ! grep -q "userprompt" "$LOG" && ok "L: live session -> silent no-op" || bad "L: no-op" "$OUT"
OUT="$(HANDOFF_T3_AUTOCLEAR=false hook handoff-userprompt.sh '{"session_id":"V2A","prompt":"x"}')"
[ -z "$OUT" ] && ok "L: T3 off -> never blocks" || bad "L: off" "$OUT"
# chain V2A -> V2B -> V2C, T3 resumed V2A; newest handoff is V2B's; V2C's transcript has later messages
reset_fake; echo V2A > "$T3_FAKE_LIVE"; full_doc "$HD/sessions/V2B.md"; touch -t 202610250800 "$HD/sessions/V2B.md"; echo '{}' > "$TMP/tx/V2A.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2026-10-25T09:00:00Z","message":{"role":"user","content":"please also bump the chart"}}' \
  '{"type":"assistant","timestamp":"2026-10-25T09:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Bumped chart to 1.2.3."}]}}' \
  '{"type":"user","timestamp":"2026-10-25T09:02:00Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}' > "$TMP/tx/V2C.jsonl"
OUT="$(hook handoff-userprompt.sh "{\"session_id\":\"V2A\",\"prompt\":\"status?\",\"transcript_path\":\"$TMP/tx/V2A.jsonl\"}")"
echo "$OUT" | jq -e '.decision=="block" and (.reason|test("/clear, then /handoff:resume"))' >/dev/null && ok "L: zombie prompt blocked with reason" || bad "L: block" "$OUT"
wait_for "sent /handoff:resume to THREADV2" "$LOG" && ok "L: /clear + /handoff:resume sent" || bad "L: flow" "$(tail -5 "$LOG")"
REC="$(ls "$HD/sessions/archive/"V2A-*.md 2>/dev/null | head -1)"
grep -q "Recovery note" "$REC" && grep -q "## Goal" "$REC" && grep -q "please also bump the chart" "$REC" && ok "L: recovery handoff = newest chain doc + inlined digest (consumed, archived)" || bad "L: rec doc" "$(ls "$HD/sessions/archive/")"
grep -q "please also bump the chart" "$HD/current.md" && ok "L: recovery handoff staged for /handoff:resume" || bad "L: staged"
DIG="$HD/recovery/V2A-digest.md"
grep -q "Bumped chart to 1.2.3" "$DIG" && ! grep -q "command-name" "$DIG" && ok "L: digest has later user+assistant text, no command noise" || bad "L: digest" "$(cat "$DIG" 2>/dev/null)"
N="$(cat "$T3_FAKE_LIVE")"
[ "$(readlink "$TMP/tx/V2A.jsonl")" = "$N.jsonl" ] && ! is_tombstoned V2A && ok "L: T3's session V2A now follows the fresh session $N" || bad "L: alias" "$(ls -la "$TMP/tx" | grep V2A)"
grep -q "^/handoff:resume This thread was just recovered" "$T3_FAKE_LOG.sent" && grep -q "status?" "$T3_FAKE_LOG.sent" && ok "L: /handoff:resume carries the user's message" || bad "L: resume args" "$(cat "$T3_FAKE_LOG.sent")"
OUT="$(hook handoff-userprompt.sh '{"session_id":"V2A","prompt":"again"}')"
[ -z "$OUT" ] && ok "L: a later respawn under V2A runs normally" || bad "L: second prompt" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
