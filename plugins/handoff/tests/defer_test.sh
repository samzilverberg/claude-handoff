#!/bin/bash
# T3_DEFER (deferred handoff) for Claude and Codex, with a stub T3 helper (HANDOFF_T3_SH) that records its calls.
# Usage: bash tests/defer_test.sh
cd "$(dirname "$0")/.." || exit 1
SCR="$PWD/scripts"
P=0; F=0
ok()  { echo "ok   - $1"; P=$((P+1)); }
bad() { echo "FAIL - $1"; F=$((F+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

W="$(mktemp -d -t handoff-defer)"; trap 'rm -rf "$W"' EXIT
unset T3CODE_THREAD_ID HANDOFF_THRESHOLD HANDOFF_LIVE_FROM HANDOFF_T3_DEFER HANDOFF_MAX_DOC_CHARS
export HANDOFF_T3_AUTOCLEAR=true HANDOFF_CONF="$W/none.conf" HANDOFF_T3_SH="$W/t3stub.sh" CALLS="$W/calls"
cat > "$HANDOFF_T3_SH" <<'EOS'
#!/bin/bash
# t3.sh stub: <root> <log> <sid> <mode> [file]. STUB_CHECK=fail makes the preflight fail.
{ printf '%s %s' "$4" "$3"; [ -n "$5" ] && printf ' file=%s' "$(basename "$5")"
  [ -s "${HANDOFF_RESUME_ARGS:-}" ] && printf ' args=%s' "$(tail -n 1 "$HANDOFF_RESUME_ARGS")"
  [ "$4" = nudge ] && [ -s "$5" ] && printf ' text=%s' "$(head -c 40 "$5" | tr '\n' ' ')"
  echo; } >> "$CALLS"
case "$4" in
  check) [ "$STUB_CHECK" = fail ] && { echo "not a T3 Code session"; exit 1; }; echo "ok: stub";;
  nudge) echo "nudge scheduled for thread T";;
  clear) echo "handoff (stub) scheduled for thread T";;
esac
EOS
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : > "$CALLS"; }
doc() { mkdir -p "$(dirname "$1")"; printf '# Handoff\n## Goal\ng\n## Standing instructions from the user\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\nnone\n' > "$1"; }

# ---- Claude ----------------------------------------------------------------------------------------------------------
C="$W/claude"; mkdir -p "$C"; HC="$C/.claude/handoff"
ctr() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$2" >> "$W/$1.jsonl"; }
cstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, stop_hook_active:$a}' \
  | CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash "$SCR/handoff-stop.sh"; }
cups() { jq -nc --arg s "$1" --arg p "$2" '{session_id:$s, prompt:$p, hook_event_name:"UserPromptSubmit"}' \
  | CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash "$SCR/handoff-userprompt.sh"; }

# off (default): the request goes out at once
reset_calls; ctr c0 320000; O="$(cstop c0)"
check "claude off: nudge sent at the turn end" 'calls | grep -q "^nudge c0"'

# all
export HANDOFF_T3_DEFER=all
reset_calls; ctr c1 320000; O="$(cstop c1)"
check "claude all: turn end only announces" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff due: it runs when you send your next message"'
check "claude all: nothing sent at the turn end" '! calls | grep -q "^nudge"'
check "claude all: armed" '[ "$(cat "$HC/state/defer/c1")" = all ]'
O="$(cups c1 "please also fix the README")"
check "claude all: next message held (block)" '[ "$(jq -r .decision <<<"$O")" = block ] && jq -r .reason <<<"$O" | grep -q "No need to resend"'
check "claude all: handoff request sent as its own turn" 'calls | grep -q "^nudge c1 file=c1.nudge.txt text=\[handoff plugin\] The context window"'
check "claude all: disarmed, message kept" '[ ! -f "$HC/state/defer/c1" ] && grep -q "please also fix the README" "$HC/state/c1.pending-prompt.txt"'
O="$(cstop c1)"; check "claude all: Stop right after the held message is ignored" '[ -z "$O" ]'
O="$(cups c1 "[handoff plugin] The context window is at …")"; check "claude all: plugin prompt passes" '[ -z "$O" ]'
doc "$HC/sessions/c1.md"; reset_calls; O="$(cstop c1)"
check "claude all: staged, fresh session carries the held message" 'calls | grep -q "^clear c1 file=c1.md args=please also fix the README"'
check "claude all: Stop message says scheduled" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff staged"'
O="$(cups c1 "second message")"; check "claude all: later messages not held again" '[ -z "$O" ]'

# resume
export HANDOFF_T3_DEFER=resume
reset_calls; ctr c2 320000; O="$(cstop c2)"
check "claude resume: request sent at the turn end" 'calls | grep -q "^nudge c2"'
doc "$HC/sessions/c2.md"; reset_calls; O="$(cstop c2)"
check "claude resume: staged, fresh session waits" 'jq -r .systemMessage <<<"$O" | grep -q "continues in a fresh session when you send your next message" && ! calls | grep -q "^clear"'
O="$(cstop c2)"; check "claude resume: later Stop keeps waiting" 'jq -r .systemMessage <<<"$O" | grep -q "when you send your next message" && ! calls | grep -q "^clear"'
O="$(cups c2 "go on with step 3")"
check "claude resume: message held" '[ "$(jq -r .decision <<<"$O")" = block ]'
check "claude resume: fresh session with the message" 'calls | grep -q "^clear c2 file=c2.md args=go on with step 3"'
check "claude resume: latched" '[ "$(jq -r .t3_clear "$HC/state/c2.json")" = 1 ]'

# preflight fails: no deferral, the handoff runs at once
export HANDOFF_T3_DEFER=all
reset_calls; ctr c3 320000; O="$(STUB_CHECK=fail cstop c3)"
check "claude all, T3 unreachable: request at once" 'calls | grep -q "^nudge c3" && [ ! -f "$HC/state/defer/c3" ]'
# T3_AUTOCLEAR off: T3_DEFER has no effect (no T3 helper calls at all)
reset_calls; ctr c4 320000; O="$(HANDOFF_T3_AUTOCLEAR=false cstop c4)"
check "claude, T3 off: in-turn request, no deferral" '[ -n "$(jq -r ".hookSpecificOutput.additionalContext // empty" <<<"$O")" ] && [ ! -f "$HC/state/defer/c4" ] && [ -z "$(calls)" ]'
# document never completes: the held message is sent back as a normal turn
reset_calls; ctr c5 320000; cstop c5 >/dev/null; cups c5 "do the thing" >/dev/null; cstop c5 >/dev/null
reset_calls; cstop c5 true >/dev/null; O="$(cstop c5 true)"
check "claude all, no document: held message released" 'calls | grep -q "^nudge c5 file=c5.pending-raw.txt text=do the thing"'

# ---- Codex -----------------------------------------------------------------------------------------------------------
X="$W/codex"; mkdir -p "$X"; HX="$X/.claude/handoff"
xtok() { printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"output_tokens":0},"model_context_window":475000}}}\n' "$2" >> "$W/$1.jsonl"; }
xstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --arg c "$X" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, cwd:$c, stop_hook_active:$a}' | bash "$SCR/codex-stop.sh"; }
xups() { jq -nc --arg s "$1" --arg c "$X" --arg p "$2" '{session_id:$s, cwd:$c, prompt:$p, hook_event_name:"UserPromptSubmit", turn_id:"t"}' | bash "$SCR/codex-userprompt.sh"; }

export HANDOFF_T3_DEFER=all
O="$(xups nobody "hello")"; check "codex: no-op when nothing is armed" '[ -z "$O" ]'
reset_calls; xtok x1 100000; xstop x1 >/dev/null; xtok x1 320000; O="$(xstop x1)"
check "codex all: turn end only announces" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff due" && [ "$(jq -r ".decision // empty" <<<"$O")" = "" ] && ! calls | grep -q "^nudge"'
O="$(xups x1 "now refactor the parser")"
check "codex all: message held" '[ "$(jq -r .decision <<<"$O")" = block ] && calls | grep -q "^nudge x1 file=x1.nudge.txt"'
O="$(xstop x1)"; check "codex all: Stop after the held message ignored" '[ -z "$O" ]'
doc "$HX/sessions/x1.md"; reset_calls; O="$(xstop x1)"
check "codex all: fresh session carries the held message" 'calls | grep -q "^clear x1 file=x1.md args=now refactor the parser"'

export HANDOFF_T3_DEFER=resume
reset_calls; xtok x2 100000; xstop x2 >/dev/null; xtok x2 320000; xstop x2 >/dev/null
check "codex resume: request at the turn end" 'calls | grep -q "^nudge x2"'
doc "$HX/sessions/x2.md"; reset_calls; O="$(xstop x2)"
check "codex resume: written, waits for the next message" 'jq -r .systemMessage <<<"$O" | grep -q "when you send your next message" && ! calls | grep -q "^clear"'
O="$(xups x2 "continue")"
check "codex resume: message held, fresh session with it" '[ "$(jq -r .decision <<<"$O")" = block ] && calls | grep -q "^clear x2 file=x2.md args=continue"'

# ---- per-project conf (.claude/handoff/handoff.conf), both agents -----------------------------------------------------
pcfg() { CLAUDE_PROJECT_DIR="$1" HANDOFF_AGENT="$2" CLAUDE_HANDOFF_NESTED="" bash -c "source '$SCR/handoff-lib.sh'; cfg $3 dflt"; }
echo "T3_DEFER=resume" > "$HC/handoff.conf"
check "conf: claude reads the project handoff.conf" '[ "$(env -u HANDOFF_T3_DEFER bash -c "$(declare -f pcfg); SCR=$SCR; pcfg $C claude T3_DEFER")" = resume ]'
check "conf: env still wins" '[ "$(HANDOFF_T3_DEFER=all pcfg "$C" claude T3_DEFER)" = all ]'
check "conf: project file beats userConfig" '[ "$(env -u HANDOFF_T3_DEFER CLAUDE_PLUGIN_OPTION_T3_DEFER=off bash -c "$(declare -f pcfg); SCR=$SCR; pcfg $C claude T3_DEFER")" = resume ]'
echo "T3_DEFER=all" > "$HX/handoff.conf"; echo "T3_DEFER=resume" > "$HX/codex.conf"
check "conf: codex.conf beats handoff.conf for codex" '[ "$(env -u HANDOFF_T3_DEFER bash -c "$(declare -f pcfg); SCR=$SCR; pcfg $X codex T3_DEFER")" = resume ]'
rm -f "$HX/codex.conf"
check "conf: codex falls back to handoff.conf" '[ "$(env -u HANDOFF_T3_DEFER bash -c "$(declare -f pcfg); SCR=$SCR; pcfg $X codex T3_DEFER")" = all ]'

echo "-----"; echo "passed: $P  failed: $F"; [ $F -eq 0 ]
