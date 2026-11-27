#!/bin/bash
# /handoff:now (manual handoff): argument parsing, arming in UserPromptSubmit, the Stop hook staging below the threshold,
# model / effort / note passed to the T3 helper. Stub T3 helper (HANDOFF_T3_SH) records its calls.
# Usage: bash tests/manual_test.sh
cd "$(dirname "$0")/.." || exit 1
SCR="$PWD/scripts"
P=0; F=0
ok()  { echo "ok   - $1"; P=$((P+1)); }
bad() { echo "FAIL - $1"; F=$((F+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

W="$(mktemp -d -t handoff-manual)"; trap 'rm -rf "$W"' EXIT
unset HANDOFF_THRESHOLD HANDOFF_LIVE_FROM HANDOFF_T3_DEFER HANDOFF_MAX_DOC_CHARS HANDOFF_FRESH_MODEL HANDOFF_FRESH_EFFORT
export HANDOFF_MAX_DOC_SHARE=0 T3CODE_THREAD_ID=thread-1
export HANDOFF_T3_AUTOCLEAR=true HANDOFF_CONF="$W/none.conf" HANDOFF_T3_SH="$W/t3stub.sh" CALLS="$W/calls"
cat > "$HANDOFF_T3_SH" <<'EOS'
#!/bin/bash
# t3.sh stub: <root> <log> <sid> <mode> [arg] [arg2]. STUB_MODEL=error|skip changes the model answer.
{ printf '%s %s' "$4" "$3"
  [ "$4" = model ] && printf ' m=%s e=%s' "$5" "$6"
  [ "$4" != model ] && [ -n "$5" ] && printf ' file=%s' "$(basename "$5")"
  [ -n "${HANDOFF_FRESH_MODEL:-}" ] && printf ' fm=%s' "$HANDOFF_FRESH_MODEL"
  [ -n "${HANDOFF_FRESH_EFFORT:-}" ] && printf ' fe=%s' "$HANDOFF_FRESH_EFFORT"
  [ -s "${HANDOFF_RESUME_ARGS:-}" ] && printf ' args=%s' "$(tail -n 1 "$HANDOFF_RESUME_ARGS")"
  echo; } >> "$CALLS"
case "$4" in
  check) echo "ok: stub";;
  model) case "$STUB_MODEL" in
           error) echo "error: unknown model \"$5\". Models here: claude-opus-5-5";;
           skip)  echo "skip: t3ctl not on PATH";;
           *)     m="-"; [ -n "$5" ] && m="claudeAgent/claude-$5-9"; e="${6:--}"; echo "ok $m $e";;
         esac;;
  nudge) echo "nudge scheduled for thread T";;
  clear) echo "handoff (stub) scheduled for thread T";;
esac
EOS
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : > "$CALLS"; }
doc() { mkdir -p "$(dirname "$1")"; printf '# Handoff\n## Goal\ng\n## Standing instructions from the user\ns\n## Decisions log\nd\n## Current state\nc\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\nnone\n' > "$1"; }

C="$W/claude"; mkdir -p "$C"; HC="$C/.claude/handoff"
ctr() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$2" >> "$W/$1.jsonl"; }
cstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, stop_hook_active:$a}' \
  | CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash "$SCR/handoff-stop.sh"; }
cups() { jq -nc --arg s "$1" --arg p "$2" '{session_id:$s, prompt:$p, hook_event_name:"UserPromptSubmit"}' \
  | CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash "$SCR/handoff-userprompt.sh"; }
mf() { jq -r ".$2" "$HC/state/manual/$1.json" 2>/dev/null; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }

# ---- argument parsing -------------------------------------------------------------------------------------------------
parse() { CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash -c "source '$SCR/handoff-lib.sh'; manual_parse \"\$1\"; printf '%s|%s|%s' \"\$MP_MODEL\" \"\$MP_EFFORT\" \"\$MP_NOTE\"" _ "$1"; }
check "parse: empty"                       '[ "$(parse "")" = "||" ]'
check "parse: model effort note"           '[ "$(parse " sonnet low fix the tests next")" = "sonnet|low|fix the tests next" ]'
check "parse: effort first, case-folded"   '[ "$(parse " HIGH Opus")" = "Opus|high|" ]'
check "parse: flags, -- starts the note"   '[ "$(parse " -m claude-opus-5-5 -e max -- high priority")" = "claude-opus-5-5|max|high priority" ]'
check "parse: --model= form"               '[ "$(parse " --model=claudeAgent/fable --effort=low")" = "claudeAgent/fable|low|" ]'
check "parse: plain words are the note"    '[ "$(parse " please wrap up the parser")" = "||please wrap up the parser" ]'
check "parse: opus high"                   '[ "$(parse " opus high")" = "opus|high|" ]'
check "parse: opus5 high"                  '[ "$(parse " opus5 high")" = "opus5|high|" ]'
check "parse: opus 5 high (version joined)" '[ "$(parse " opus 5 high")" = "opus-5|high|" ]'
check "parse: opus 4.8"                    '[ "$(parse " opus 4.8")" = "opus-4.8||" ]'
check "parse: opus-4.8"                    '[ "$(parse " opus-4.8")" = "opus-4.8||" ]'
check "parse: opus4"                       '[ "$(parse " opus4")" = "opus4||" ]'
check "parse: opus 4"                      '[ "$(parse " opus 4")" = "opus-4||" ]'
check "parse: opus v5"                     '[ "$(parse " opus v5 high")" = "opus-5|high|" ]'
check "parse: fable 5.1 low + note"        '[ "$(parse " fable 5.1 low then do x")" = "fable-5.1|low|then do x" ]'
check "parse: effort first, fable 5"       '[ "$(parse " high fable 5")" = "fable-5|high|" ]'
check "parse: -m with a separate version"  '[ "$(parse " -m opus 4.8 -e max")" = "opus-4.8|max|" ]'
check "parse: a number after an effort is the note" '[ "$(parse " low 5 things")" = "|low|5 things" ]'
check "parse: -- keeps a model-like note"  '[ "$(parse " -- opus 5 is great")" = "||opus 5 is great" ]'
check "parse: opus 5.5 high"               '[ "$(parse " opus 5.5 high")" = "opus-5.5|high|" ]'
check "parse: fable 5.2 mid -> medium"     '[ "$(parse " fable 5.2 mid")" = "fable-5.2|medium|" ]'
check "parse: fable5 mid -> medium"        '[ "$(parse " fable5 mid")" = "fable5|medium|" ]'
check "parse: short efforts (med/hi/lo/ultra/x-high/maximum)" '[ "$(parse " med")" = "|medium|" ] && [ "$(parse " hi")" = "|high|" ] && [ "$(parse " lo")" = "|low|" ] && [ "$(parse " ultra")" = "|ultrathink|" ] && [ "$(parse " x-high")" = "|xhigh|" ] && [ "$(parse " -e maximum")" = "|max|" ]'
check "parse: sonnet5 mid"                 '[ "$(parse " sonnet5 mid")" = "sonnet5|medium|" ]'
check "parse: sonnet 4.6 hi"               '[ "$(parse " sonnet 4.6 hi")" = "sonnet-4.6|high|" ]'
check "parse: Sonnet 5.5 max"              '[ "$(parse " Sonnet 5.5 max")" = "Sonnet-5.5|max|" ]'
check "parse: multi-line note kept"        '[ "$(parse " low first line
second line")" = "|low|first line
second line" ]'

# ---- UserPromptSubmit --------------------------------------------------------------------------------------------------
O="$(cups u0 "hello")"; check "prompt: ordinary message untouched" '[ -z "$O" ]'
O="$(cups u0 "/handoff:nowhere")"; check "prompt: other command untouched" '[ -z "$O" ] && [ ! -f "$HC/state/manual/u0.json" ]'

reset_calls; O="$(cups m1 "/handoff:now sonnet low finish the README")"
check "arm: marker with resolved model / effort / note" '[ "$(mf m1 model)" = claudeAgent/claude-sonnet-9 ] && [ "$(mf m1 effort)" = low ] && [ "$(mf m1 note)" = "finish the README" ]'
check "arm: model checked with the T3 helper" 'calls | grep -q "^model m1 m=sonnet e=low"'
check "arm: request names the document and sections" 'ctx "$O" | grep -q "sessions/m1.md" && ctx "$O" | grep -q "## Goal" && ctx "$O" | grep -q "<note>finish the README</note>"'
check "arm: request names the target" 'ctx "$O" | grep -q "to continue with model claude-sonnet-9, effort low"'
check "arm: note file for the fresh session" 'grep -q "finish the README" "$HC/state/m1.manual-note.txt"'
check "arm: user told" 'jq -r .systemMessage <<<"$O" | grep -q "manual handoff armed (model claude-sonnet-9, effort low)"'

# Stop below the threshold, no document yet: ask for it (counts as a request)
ctr m1 50000; reset_calls; O="$(cstop m1)"
check "stop: below threshold, no doc -> request (own T3 turn)" 'calls | grep -q "^nudge m1" && jq -r .systemMessage <<<"$O" | grep -q "^Handoff (/handoff:now (model claude-sonnet-9, effort low)): context is 50000 tokens. Asking Claude"'
check "stop: request text is the manual one" 'grep -q "asked to hand this conversation off now" "$HC/state/m1.nudge.txt"'
# document written: staged, fresh session with model / effort / note
doc "$HC/sessions/m1.md"; reset_calls; O="$(cstop m1)"
check "stop: staged and handed to T3 with model/effort/note" 'calls | grep -q "^clear m1 file=m1.md fm=claudeAgent/claude-sonnet-9 fe=low args=finish the README"'
check "stop: message" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff staged; once this turn ends"'
check "stop: marker consumed" '[ ! -f "$HC/state/manual/m1.json" ]'
check "stop: by-thread copy staged" '[ -s "$HC/by-thread/thread-1.md" ]'
reset_calls; O="$(cstop m1)"; check "stop: latched, nothing sent twice" '! calls | grep -q "^clear"'

# already scheduled and pending: /handoff:now refused
echo pending > "$HC/state/m1.t3clear"
O="$(cups m1 "/handoff:now")"; check "arm: refused while a handoff is scheduled" '[ "$(jq -r .decision <<<"$O")" = block ] && [ ! -f "$HC/state/manual/m1.json" ]'

# bad model: blocked, nothing armed
reset_calls; O="$(STUB_MODEL=error cups m2 "/handoff:now opus-9-9")"
check "arm: unknown model blocks (zero tokens)" '[ "$(jq -r .decision <<<"$O")" = block ] && jq -r .reason <<<"$O" | grep -q "unknown model" && [ ! -f "$HC/state/manual/m2.json" ]'
# cannot check: armed with the raw values, user warned
O="$(STUB_MODEL=skip cups m3 "/handoff:now opus")"
check "arm: unchecked model kept, warned" '[ "$(mf m3 model)" = opus ] && jq -r .systemMessage <<<"$O" | grep -q "not checked"'
# effort only
O="$(cups m4 "/handoff:now max")"; check "arm: effort only keeps the model (-)" '[ "$(mf m4 model)" = - ] && [ "$(mf m4 effort)" = max ]'
doc "$HC/sessions/m4.md"; ctr m4 1000; reset_calls; cstop m4 >/dev/null
check "stop: effort only -> fe set, model kept" 'calls | grep -q "^clear m4 file=m4.md fm=- fe=max$"'

# stale document (from before the arming) is not staged: rewrite requested
doc "$HC/sessions/m5.md"; touch -t 202001010000 "$HC/sessions/m5.md"
O="$(cups m5 "/handoff:now")"; check "arm: existing doc -> rewrite asked" 'ctx "$O" | grep -q "overwrite it even if it looks current"'
ctr m5 1000; reset_calls; O="$(cstop m5)"
check "stop: stale doc not staged, finalize asked" '! calls | grep -q "^clear" && grep -q "Finalize the handoff document" "$HC/state/m5.nudge.txt"'
touch "$HC/sessions/m5.md"; reset_calls; cstop m5 >/dev/null
check "stop: rewritten doc staged, no model flags" 'calls | grep -q "^clear m5 file=m5.md$"'

# loop guard does not hold back a manual handoff (first Stop of the session above the threshold)
export HANDOFF_LOOP_GUARD=true HANDOFF_THRESHOLD=100000
cups m6 "/handoff:now" >/dev/null; doc "$HC/sessions/m6.md"; ctr m6 150000; reset_calls; cstop m6 >/dev/null
check "stop: loop guard bypassed" 'calls | grep -q "^clear m6"'
unset HANDOFF_LOOP_GUARD HANDOFF_THRESHOLD

# a deferred handoff (T3_DEFER) is replaced by /handoff:now: no deferral at the Stop
export HANDOFF_T3_DEFER=resume
mkdir -p "$HC/state/defer"; echo all > "$HC/state/defer/m7"
O="$(cups m7 "/handoff:now low")"
check "arm: deferred handoff disarmed, message not held" '[ ! -f "$HC/state/defer/m7" ] && [ "$(jq -r ".decision // empty" <<<"$O")" = "" ] && [ -n "$(ctx "$O")" ]'
doc "$HC/sessions/m7.md"; ctr m7 1000; reset_calls; cstop m7 >/dev/null
check "stop: T3_DEFER=resume ignored, fresh session at once" 'calls | grep -q "^clear m7 file=m7.md fm=- fe=low"'
unset HANDOFF_T3_DEFER

# T3_AUTOCLEAR off: no T3 calls, model dropped with a warning, user types /clear
export HANDOFF_T3_AUTOCLEAR=false
reset_calls; O="$(cups m8 "/handoff:now sonnet keep going with step 4")"
check "arm: parsed note shown to the user" 'jq -r .systemMessage <<<"$O" | grep -q "Note for the next context: \"keep going with step 4\""'
check "off: model dropped, warned, note kept" '[ -z "$(mf m8 model)" ] && [ "$(mf m8 note)" = "keep going with step 4" ] && jq -r .systemMessage <<<"$O" | grep -q "needs T3 Code with T3_AUTOCLEAR" && [ -z "$(calls)" ]'
ctr m8 1000; O="$(cstop m8)"
check "off: in-turn request" 'ctx "$O" | grep -q "asked to hand this conversation off now"'
doc "$HC/sessions/m8.md"; O="$(cstop m8)"
check "off: staged, type /clear, note hint" 'jq -r .systemMessage <<<"$O" | grep -q "Type /clear, then /handoff:resume" && jq -r .systemMessage <<<"$O" | grep -q "add it after /handoff:resume" && [ -z "$(calls)" ]'
check "off: current.md staged" 'grep -q "^## Goal" "$HC/current.md"'
# no document after 2 requests: gives up, marker dropped
cups m9 "/handoff:now" >/dev/null; ctr m9 1000; cstop m9 >/dev/null; cstop m9 true >/dev/null; O="$(cstop m9 true)"
check "off: gives up after 2 requests" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff file is missing" && [ ! -f "$HC/state/manual/m9.json" ]'
O="$(cstop m9)"; check "off: back to normal afterwards (below threshold: nothing)" '[ -z "$O" ]'

echo "-----"; echo "passed: $P  failed: $F"; [ $F -eq 0 ]
