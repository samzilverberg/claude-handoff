#!/bin/bash
# Protections against handoff loops: the loop guard (a session hands off only after growing LIVE_EVERY since its first
# Stop) and the document size limit that shrinks with the threshold (MAX_DOC_SHARE), for the Claude (handoff-stop.sh)
# and Codex (codex-stop.sh) Stop hooks. Usage: bash tests/guards_test.sh
cd "$(dirname "$0")/.." || exit 1
SCR="$PWD/scripts"
P=0; F=0
ok()  { echo "ok   - $1"; P=$((P+1)); }
bad() { echo "FAIL - $1"; F=$((F+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

W="$(mktemp -d -t handoff-guards)"; trap 'rm -rf "$W"' EXIT
unset T3CODE_THREAD_ID HANDOFF_THRESHOLD HANDOFF_LIVE_FROM HANDOFF_LIVE_EVERY HANDOFF_MAX_DOC_CHARS HANDOFF_MAX_DOC_SHARE HANDOFF_LOOP_GUARD
export HANDOFF_T3_AUTOCLEAR=false HANDOFF_CONF="$W/none.conf" HANDOFF_T3_DB="$W/no-t3.sqlite"
doc() { printf '# Handoff\n## Goal\ng\n## Standing instructions from the user\ns\n## Decisions log\nd\n## Current state\n%s\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\nnone\n' "${2:-c}" > "$1"; }
LONG="$(printf 'x%.0s' $(seq 1 3000))"

# ---- lib: size limit from the threshold ---------------------------------------------------------------------------
R="$W/r"; mkdir -p "$R"
lib() { CLAUDE_PROJECT_DIR="$R" bash -c "source '$SCR/handoff-lib.sh'; $1"; }
doc "$W/big" "$LONG"   # ~3200 characters
check "share: threshold 1000 -> limit 1000 characters (25%, ~4 chars/token)" 'lib "doc_problems $W/big 1000" | grep -q "over the limit of 1000 (MAX_DOC_SHARE: 25% of the 1000-token"'
check "share: threshold 300000 -> MAX_DOC_CHARS (200000) is lower" '[ -z "$(lib "doc_problems $W/big 300000")" ] && HANDOFF_MAX_DOC_CHARS=100 lib "doc_problems $W/big 300000" | grep -q "limit of 100 (MAX_DOC_CHARS)"'
check "share: no threshold given -> MAX_DOC_CHARS only" '[ -z "$(lib "doc_problems $W/big")" ]'
check "share: MAX_DOC_SHARE=0 -> off" '[ -z "$(HANDOFF_MAX_DOC_SHARE=0 lib "doc_problems $W/big 1000")" ]'
check "share: MAX_DOC_SHARE=50 -> threshold 1000 gives 2000" 'HANDOFF_MAX_DOC_SHARE=50 lib "doc_problems $W/big 1000" | grep -q "limit of 2000"'
check "share: applies with MAX_DOC_CHARS=0 too" 'HANDOFF_MAX_DOC_CHARS=0 lib "doc_problems $W/big 1000" | grep -q "limit of 1000"'

# ---- Claude Stop hook -----------------------------------------------------------------------------------------------
C="$W/claude"; mkdir -p "$C"; HC="$C/.claude/handoff"
ctr() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$2" >> "$W/$1.jsonl"; }
cstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, stop_hook_active:$a}' \
  | CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash "$SCR/handoff-stop.sh"; }
ask() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1" | grep -q "$2"; }
ctr g1 330000; O="$(cstop g1)"; check "claude guard: first Stop above the threshold is silent" '[ -z "$O" ]'
ctr g1 340000; O="$(cstop g1)"; check "claude guard: +10k still silent" '[ -z "$O" ]'
ctr g1 351000; O="$(cstop g1)"; check "claude guard: +21k asks for the document" 'ask "$O" "sessions/g1.md"'
ctr g2 100000; cstop g2 >/dev/null; ctr g2 305000; O="$(cstop g2)"
check "claude guard: a session that started below the threshold asks at once" 'ask "$O" "sessions/g2.md"'
ctr g3 330000; O="$(HANDOFF_LOOP_GUARD=false cstop g3)"; check "claude guard: LOOP_GUARD=false asks at once" 'ask "$O" "sessions/g3.md"'
# mid-handoff (request already made) the guard stays out of the way: the follow-up Stop stages
doc "$HC/sessions/g1.md"; ctr g1 352000; O="$(cstop g1 true)"; check "claude guard: follow-up Stop of the handoff stages" 'jq -r .systemMessage <<<"$O" | grep -q "written and staged"'
# low threshold: an oversize document gets a condense request naming MAX_DOC_SHARE
ctr g4 1000; cstop g4 >/dev/null; ctr g4 6000; HANDOFF_THRESHOLD=5000 cstop g4 >/dev/null
doc "$HC/sessions/g4.md" "$LONG$LONG"   # ~6200 characters, limit 5000
O="$(HANDOFF_THRESHOLD=5000 cstop g4 true)"; check "claude share: low threshold -> condense request" 'ask "$O" "Condense it" && ask "$O" "MAX_DOC_SHARE: 25% of the 5000-token"'

# ---- Codex Stop hook ------------------------------------------------------------------------------------------------
X="$W/codex"; mkdir -p "$X"; HX="$X/.claude/handoff"
xtok() { printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"output_tokens":0},"model_context_window":475000}}}\n' "$2" >> "$W/$1.jsonl"; }
xstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --arg c "$X" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, cwd:$c, stop_hook_active:$a}' | bash "$SCR/codex-stop.sh"; }
xtok y1 330000; O="$(xstop y1)"; check "codex guard: first Stop above the threshold is silent" '[ -z "$O" ]'
xtok y2 330000; O="$(HANDOFF_LOOP_GUARD=false xstop y2)"; check "codex guard: LOOP_GUARD=false asks at once" '[ "$(jq -r .decision <<<"$O")" = block ]'
xtok y3 1000; xstop y3 >/dev/null; xtok y3 6000; HANDOFF_THRESHOLD=5000 xstop y3 >/dev/null
doc "$HX/sessions/y3.md" "$LONG$LONG"
O="$(HANDOFF_THRESHOLD=5000 xstop y3 true)"; check "codex share: low threshold -> condense request" 'jq -r .reason <<<"$O" | grep -q "MAX_DOC_SHARE: 25% of the 5000-token"'

echo "-----"; echo "passed: $P  failed: $F"; [ $F -eq 0 ]
