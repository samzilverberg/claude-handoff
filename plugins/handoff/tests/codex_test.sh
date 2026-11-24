#!/bin/bash
# Codex hooks (scripts/codex-*.sh) against fake Codex rollouts. No Codex, no T3 needed (T3_AUTOCLEAR off, except the
# t3.sh guard checks, which run outside T3 and must skip). Usage: bash tests/codex_test.sh
cd "$(dirname "$0")/.." || exit 1
P=0; F=0
ok()  { echo "ok   - $1"; P=$((P+1)); }
bad() { echo "FAIL - $1"; F=$((F+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

W="$(mktemp -d -t handoff-codex)"; trap '[ -n "$KEEP" ] || rm -rf "$W"' EXIT
export HANDOFF_CONF="$W/global.conf"; : > "$HANDOFF_CONF"
unset HANDOFF_THRESHOLD HANDOFF_LIVE_FROM HANDOFF_LIVE_EVERY HANDOFF_T3_AUTOCLEAR CLAUDE_PROJECT_DIR
# isolate from the host: the T3 helper must see "not a T3 Code session"
export __CFBundleIdentifier=test HANDOFF_T3_DB="$W/no-t3.sqlite"   # T3 unusable here even when the test runs under T3
PROJ="$W/proj"; mkdir -p "$PROJ"; HD="$PROJ/.claude/handoff"
tok() { printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"output_tokens":0},"model_context_window":%s}}}\n' "$2" "${3:-475000}" >> "$W/$1.jsonl"; }
stop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --arg c "$PROJ" --argjson a "${2:-false}" \
  '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"Stop", turn_id:"t", stop_hook_active:$a}' | bash scripts/codex-stop.sh; }
start() { jq -nc --arg s "$1" --arg c "$PROJ" --arg src "$2" '{session_id:$s, cwd:$c, hook_event_name:"SessionStart", source:$src}' | bash scripts/codex-sessionstart.sh; }
doc() { mkdir -p "$HD/sessions"; printf '# Handoff\n## Goal\ng\n## Standing instructions from the user\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\nnone\n' > "$HD/sessions/$1.md"; }

# 1. below the threshold: silent
tok a 10000; tok a 100000; O="$(stop a)"
check "below threshold: no output" '[ -z "$O" ]'
check "writes to the project's .claude/handoff (cwd from stdin)" '[ -f "$HD/hooks.log" ]'

# 2. crossing it (grown from the first Stop): Stop block asking for the document at sessions/<sid>.md
tok a 320000; O="$(stop a)"
check "threshold: decision block" '[ "$(jq -r .decision <<<"$O")" = block ]'
check "threshold: reason names the session file" 'jq -r .reason <<<"$O" | grep -q "sessions/a.md"'
check "threshold: reason lists the sections" 'jq -r .reason <<<"$O" | grep -q "Standing instructions from the user"'
check "threshold: reason is tagged [handoff plugin]" 'jq -r .reason <<<"$O" | grep -q "^\[handoff plugin\]"'

# 3. continuation without a file: second ask, then gives up after 2
O="$(stop a true)"; check "second ask while missing" '[ "$(jq -r .decision <<<"$O")" = block ]'
O="$(stop a true)"; check "after 2 asks: no more block" '[ "$(jq -r ".decision // empty" <<<"$O")" = "" ] && jq -r .systemMessage <<<"$O" | grep -q "after 2 requests"'

# 4. incomplete document: ask names the missing sections
tok b 100000; stop b >/dev/null; tok b 320000
mkdir -p "$HD/sessions"; printf '# Handoff\n## Goal\ng\n' > "$HD/sessions/b.md"
O="$(stop b)"; check "incomplete doc: names missing sections" 'jq -r .reason <<<"$O" | grep -q "missing these sections: Standing instructions"'

# 5. complete document after the ask: staged, manual instructions (no T3)
doc b; O="$(stop b true)"
check "complete doc: no block" '[ "$(jq -r ".decision // empty" <<<"$O")" = "" ]'
check "complete doc: tells how to resume" 'jq -r .systemMessage <<<"$O" | grep -q "Start a new session"'
check "complete doc: logged as published" 'grep -q "publish. codex sid=b" "$HD/hooks.log"'

# 6. window cap: threshold at most 70% of the model window
tok c 100000 200000; stop c >/dev/null; tok c 150000 200000; O="$(stop c)"
check "window cap: limit 140000 for a 200k window" 'jq -r .systemMessage <<<"$O" | grep -q "limit 140000"'

# 7. loop guard: a session that starts above the threshold does not hand off until it grew LIVE_EVERY
tok d 330000; O="$(stop d)"; check "loop guard: first Stop above threshold is silent" '[ -z "$O" ]'
tok d 340000; O="$(stop d)"; check "loop guard: +10k still silent" '[ -z "$O" ]'
tok d 351000; O="$(stop d)"; check "loop guard: +21k asks" '[ "$(jq -r .decision <<<"$O")" = block ]'

# 8. config precedence: env > project codex.conf > global conf > default
grow() { tok "$1" 10000; stop "$1" >/dev/null; tok "$1" 72000; }   # first Stop low, then 72k
echo "THRESHOLD=60000" > "$HANDOFF_CONF"
grow e1; O="$(stop e1)"; check "global conf threshold" 'jq -r .systemMessage <<<"$O" | grep -q "limit 60000"'
echo "THRESHOLD=70000 # per project" > "$HD/codex.conf"
grow e2; O="$(stop e2)"; check "project conf beats global (comment stripped)" 'jq -r .systemMessage <<<"$O" | grep -q "limit 70000"'
grow e3; O="$(HANDOFF_THRESHOLD=0 stop e3)"; check "env beats conf (0 = off)" '[ -z "$O" ]'
rm -f "$HD/codex.conf"; : > "$HANDOFF_CONF"
check "claude path ignores the codex conf" '[ "$(echo THRESHOLD=1 > "$HANDOFF_CONF"; CLAUDE_PROJECT_DIR="$PROJ" bash -c "source scripts/handoff-lib.sh; cfg THRESHOLD 300000")" = 300000 ]'
: > "$HANDOFF_CONF"

# 9. live mode
tok f 100000; tok f 160000
O="$(HANDOFF_LIVE_FROM=150000 stop f)"; check "live: asks for a running handoff" 'jq -r .reason <<<"$O" | grep -q "running handoff"'
tok f 170000; O="$(HANDOFF_LIVE_FROM=150000 stop f)"; check "live: no re-ask before LIVE_EVERY" '[ -z "$O" ]'

# 10. T3_AUTOCLEAR outside T3: falls back to the Stop block, says why
tok g 100000; stop g >/dev/null; tok g 320000
O="$(HANDOFF_T3_AUTOCLEAR=true stop g)"
check "T3 on, not a T3 host: block fallback" '[ "$(jq -r .decision <<<"$O")" = block ]'
check "T3 on, T3 unusable: reason in systemMessage" 'jq -r .systemMessage <<<"$O" | grep -q "T3 turn not used"'
doc g; O="$(HANDOFF_T3_AUTOCLEAR=true stop g true)"
check "T3 on, not a T3 host: handoff skipped with a reason" 'jq -r .systemMessage <<<"$O" | grep -q "Automatic T3 handoff skipped"'
R="$(HANDOFF_AGENT=codex bash scripts/t3.sh "$PROJ" "$HD/hooks.log" g alias x)"
check "t3.sh: alias refused for codex" 'grep -q "Claude only" <<<"$R"'

# 11. tombstoned session (handed off): inert
mkdir -p "$HD/state/tombstones"; echo '{}' > "$HD/state/tombstones/h.json"; tok h 400000; O="$(stop h)"
check "tombstoned: inert" '[ -z "$O" ]'

# 12. SessionStart: startup silent; compact with a doc points at it and resets state
O="$(start b startup)"; check "sessionstart startup: silent" '[ -z "$O" ]'
O="$(start b compact)"
check "sessionstart compact: points at the doc" 'jq -r .hookSpecificOutput.additionalContext <<<"$O" | grep -q "sessions/b.md"'
check "sessionstart compact: state reset" '[ ! -f "$HD/state/b.json" ]'

echo "-----"; echo "passed: $P  failed: $F"; [ $F -eq 0 ]
