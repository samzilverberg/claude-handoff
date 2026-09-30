#!/bin/bash
# End-to-end replay of the 2026-09-30 duplicate-run incident, driving the REAL hook scripts in the
# exact order the host fired them, and asserting the tombstone guard neutralises the zombie while the
# legitimate post-/clear session still works. Run: bash plugins/handoff/tests/e2e_incident_test.sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"; SCR="$DIR/scripts"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP" CLAUDE_HANDOFF_NESTED="" HANDOFF_T3_AUTOCLEAR=false HANDOFF_THRESHOLD=1
HD="$TMP/.claude/handoff"
# shellcheck disable=SC1090
source "$SCR/handoff-lib.sh"           # for CPID + tombstone_* assertions (same $PPID as the subprocess hooks)
hook() { echo "$2" | bash "$SCR/$1"; }

A="claude-session-A"       # original conversation (faf04547)
B="claude-session-B"       # post-/clear conversation (c1958824)
C="claude-session-C"       # an unrelated, never-cleared conversation (control)
T="$TMP/t.jsonl"; printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":500000}}}' > "$T"
handoff() { printf '# Handoff\n## Goal\n%s\n## Standing instructions\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\no\n' "$1" > "$HD/sessions/$2.md"; }

echo "# 1. session-A reaches threshold, Stop publishes its handoff"
handoff "work-from-A" "$A"; state_set "$A" final_written_ctx 500000
hook handoff-stop.sh "{\"session_id\":\"$A\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}" >/dev/null
grep -q 'work-from-A' "$HD/current.md" && ok "A's handoff published to current.md" || bad "A publish"

echo "# 2. /clear ends A -> SessionEnd(clear) tombstones A"
hook handoff-sessionend.sh "{\"reason\":\"clear\",\"session_id\":\"$A\",\"transcript_path\":\"$T\"}" >/dev/null
is_tombstoned "$A" && ok "SessionEnd(clear) tombstoned A" || bad "A not tombstoned"

echo "# 3. fresh session-B starts (same pid) -> SessionStart(clear) links + arms resume"
OUT="$(hook handoff-sessionstart.sh "{\"source\":\"clear\",\"session_id\":\"$B\"}")"
[ "$(tombstone_get "$A" continued_by)" = "$B" ] && ok "A linked -> continued_by B" || bad "link A->B" "$(tombstone_get "$A" continued_by)"
is_tombstoned "$B" && bad "B must not be tombstoned" || ok "B not tombstoned"
case "$OUT" in *"invoke the handoff:resume skill"*) ok "B told to resume the handoff";; *) bad "B resume note" "$OUT";; esac
grep -q 'work-from-A' "$HD/current.md" && ok "current.md holds A's handoff for B to resume" || bad "current.md for B"

echo "# 4. session-B does the work, then its process ends -> current.md released"
hook handoff-sessionend.sh "{\"reason\":\"other\",\"session_id\":\"$B\",\"transcript_path\":\"$T\"}" >/dev/null
grep -q '(none)' "$HD/current.md" && ok "SessionEnd(other) reset current.md" || bad "current.md not reset" "$(cat "$HD/current.md")"

echo "# 5. THE ZOMBIE: host respawns claude --resume A (stale cursor)"
OUT="$(hook handoff-sessionstart.sh "{\"source\":\"resume\",\"session_id\":\"$A\"}")"
case "$OUT" in *"STOP — stale session resume"*) ok "zombie A is told to STOP";; *) bad "zombie stop note" "$OUT";; esac
case "$OUT" in *"session $B"*) ok "stop note points to successor B";; *) bad "stop note names B";; esac

echo "# 6. zombie ignores the note and hits Stop/PreCompact -> hooks stay inert"
handoff "STALE-rewrite" "$A"          # simulate the zombie trying to rewrite its old handoff
OUT="$(hook handoff-stop.sh "{\"session_id\":\"$A\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}")"
[ -z "$OUT" ] && ok "zombie Stop is silent" || bad "zombie Stop silent" "$OUT"
grep -q '(none)' "$HD/current.md" && ok "zombie Stop did NOT re-publish stale content" || bad "zombie re-published!" "$(cat "$HD/current.md")"
hook handoff-precompact.sh "{\"session_id\":\"$A\",\"transcript_path\":\"$T\",\"trigger\":\"auto\"}" >/dev/null
grep -q '(none)' "$HD/current.md" && ok "zombie PreCompact did NOT re-stage stale content" || bad "zombie PreCompact re-staged!"

echo "# 7. control: an unrelated, never-cleared session resumes normally"
OUT="$(hook handoff-sessionstart.sh "{\"source\":\"resume\",\"session_id\":\"$C\"}")"
case "$OUT" in *"STOP — stale session resume"*) bad "control C wrongly stopped" "$OUT";; *) ok "never-cleared session C resumes without a stop";; esac

echo "-----"; echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
