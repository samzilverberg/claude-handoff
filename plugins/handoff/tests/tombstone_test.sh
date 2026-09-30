#!/bin/bash
# Tests for the session-tombstone supersession guard: handoff-lib.sh (tombstone_* / claude_pid)
# and the hook wiring in handoff-sessionend.sh / handoff-sessionstart.sh / handoff-stop.sh /
# handoff-precompact.sh. Pure bash, macOS. Run: bash plugins/handoff/tests/tombstone_test.sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"          # plugins/handoff
SCR="$DIR/scripts"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP"
export CLAUDE_HANDOFF_NESTED=""      # set-but-empty: lib guard sees it, no exit
export HANDOFF_T3_AUTOCLEAR=false
HD="$TMP/.claude/handoff"
# shellcheck disable=SC1090
source "$SCR/handoff-lib.sh"

hook() { echo "$2" | bash "$SCR/$1"; }   # hook <script> <json-stdin> -> stdout

# a complete handoff doc (all required sections) so the Stop hook would publish if not inert
complete_handoff() {
  printf '# Handoff\n## Goal\ng\n## Standing instructions\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\no\n' > "$1"
}
# a transcript whose last assistant usage is 500k tokens (so context_tokens >= a low threshold)
big_transcript() { printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":500000}}}' > "$1"; }

# --- lib unit ---------------------------------------------------------------
tombstone_set OLD 111
is_tombstoned OLD && ok "tombstone_set marks sid" || bad "tombstone_set marks sid"
is_tombstoned NOPE && bad "unknown sid must not be tombstoned" || ok "unknown sid not tombstoned"
[ "$(tombstone_get OLD cleared_by_pid)" = "111" ] && ok "tombstone_get reads field" || bad "tombstone_get reads field"
tombstone_link OLD NEW
[ "$(tombstone_get OLD continued_by)" = "NEW" ] && ok "tombstone_link records successor" || bad "tombstone_link records successor"

# claude_pid matches the executable basename, not any ".claude/..." substring in the command line.
exe_is_claude() { local exe="${1%% *}"; case "${exe##*/}" in claude) return 0;; *) return 1;; esac; }
exe_is_claude '/opt/homebrew/bin/zsh -c source /Users/x/.claude/snap.sh' && bad "must not match .claude path shell" || ok "claude_pid ignores .claude path shells"
exe_is_claude '/Users/x/.claude/plugins/cache/node bin' && bad "must not match .claude plugin-cache" || ok "claude_pid ignores .claude plugin-cache"
exe_is_claude 'claude --resume faf04547' && ok "claude_pid matches real claude exe" || bad "claude_pid real exe"
exe_is_claude '/usr/local/bin/claude -p' && ok "claude_pid matches claude by full path" || bad "claude_pid full-path exe"

# --- integration: /clear tombstones the old sid + links successor ----------
rm -rf "$HD/state/tombstones"/* "$HD/state/pid-cleared"/* 2>/dev/null
SID_OLD="sess-OLD"; SID_NEW="sess-NEW"
complete_handoff "$HD/sessions/$SID_OLD.md"    # so session_handoff reuses instead of nested claude
T="$TMP/t.jsonl"; big_transcript "$T"
hook handoff-sessionend.sh   "{\"reason\":\"clear\",\"session_id\":\"$SID_OLD\",\"transcript_path\":\"$T\"}" >/dev/null
is_tombstoned "$SID_OLD" && ok "SessionEnd(clear) tombstones the cleared sid" || bad "SessionEnd(clear) tombstones"
hook handoff-sessionstart.sh "{\"source\":\"clear\",\"session_id\":\"$SID_NEW\"}" >/dev/null
[ "$(tombstone_get "$SID_OLD" continued_by)" = "$SID_NEW" ] && ok "SessionStart(clear) links successor sid" || bad "SessionStart(clear) links successor" "$(tombstone_get "$SID_OLD" continued_by)"
is_tombstoned "$SID_NEW" && bad "successor must NOT be tombstoned" || ok "successor not tombstoned"

# --- integration: resuming the tombstoned (zombie) sid is told to stop ------
OUT="$(hook handoff-sessionstart.sh "{\"source\":\"resume\",\"session_id\":\"$SID_OLD\"}")"
case "$OUT" in *"STOP — stale session resume"*) ok "SessionStart(resume) of zombie injects STOP";; *) bad "zombie stop note" "$OUT";; esac
case "$OUT" in *"continues in session $SID_NEW"*) ok "stop note names successor";; *) bad "stop note successor name" "$OUT";; esac
# control: resuming the live successor sid is NOT stopped
OUT="$(hook handoff-sessionstart.sh "{\"source\":\"resume\",\"session_id\":\"$SID_NEW\"}")"
case "$OUT" in *"STOP — stale session resume"*) bad "live successor must not be stopped" "$OUT";; *) ok "live successor resume not stopped";; esac

# --- integration: zombie Stop hook is inert (no publish / no nudge) ---------
export HANDOFF_THRESHOLD=1
printf '# sentinel\n' > "$HD/current.md"
complete_handoff "$HD/sessions/$SID_OLD.md"
state_set "$SID_OLD" final_written_ctx 500000       # so the (non-inert) publish branch would fire
OUT="$(hook handoff-stop.sh "{\"session_id\":\"$SID_OLD\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}")"
[ -z "$OUT" ] && ok "zombie Stop emits no systemMessage" || bad "zombie Stop silent" "$OUT"
[ "$(cat "$HD/current.md")" = "# sentinel" ] && ok "zombie Stop does not publish (current.md untouched)" || bad "zombie Stop must not publish"

# control: same Stop for a NON-tombstoned sid DOES publish -> proves the hook would otherwise act
SID_LIVE="sess-LIVE"; complete_handoff "$HD/sessions/$SID_LIVE.md"; state_set "$SID_LIVE" final_written_ctx 500000
printf '# sentinel\n' > "$HD/current.md"
hook handoff-stop.sh "{\"session_id\":\"$SID_LIVE\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}" >/dev/null
[ "$(cat "$HD/current.md")" != "# sentinel" ] && ok "control: non-tombstoned Stop publishes" || bad "control non-tombstoned publish (setup)"

# --- integration: zombie PreCompact is inert -------------------------------
printf '# sentinel\n' > "$HD/current.md"
hook handoff-precompact.sh "{\"session_id\":\"$SID_OLD\",\"transcript_path\":\"$T\",\"trigger\":\"auto\"}" >/dev/null
[ "$(cat "$HD/current.md")" = "# sentinel" ] && ok "zombie PreCompact does not publish" || bad "zombie PreCompact must not publish"

echo "-----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
