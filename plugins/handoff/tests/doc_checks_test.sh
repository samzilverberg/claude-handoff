#!/bin/bash
# Document checks before staging (secrets, size), the Workspace identity stamp, and the refresh-after-publish rule,
# for the Claude (handoff-stop.sh) and Codex (codex-stop.sh) Stop hooks. Usage: bash tests/doc_checks_test.sh
cd "$(dirname "$0")/.." || exit 1
SCR="$PWD/scripts"
P=0; F=0
ok()  { echo "ok   - $1"; P=$((P+1)); }
bad() { echo "FAIL - $1"; F=$((F+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

W="$(mktemp -d -t handoff-doc)"; trap 'rm -rf "$W"' EXIT
unset T3CODE_THREAD_ID HANDOFF_THRESHOLD HANDOFF_LIVE_FROM HANDOFF_LIVE_EVERY HANDOFF_MAX_DOC_CHARS
export HANDOFF_T3_AUTOCLEAR=false HANDOFF_CONF="$W/none.conf" HANDOFF_T3_DB="$W/no-t3.sqlite"
doc() { printf '# Handoff\n## Goal\ng\n## Standing instructions from the user\ns\n## Decisions log\nd\n## Current state\n%s\n## In progress\ni\n## Next steps\nn\n## Key files & symbols\nk\n## Gotchas / dead ends\nx\n## Open questions for the user\nnone\n' "${2:-c}" > "$1"; }
GH="ghp_$(printf 'a%.0s' $(seq 1 30))"

# ---- lib: secret_hits / doc_problems ----------------------------------------------------------------------------
R="$W/r"; mkdir -p "$R"
lib() { CLAUDE_PROJECT_DIR="$R" bash -c "source '$SCR/handoff-lib.sh'; $1"; }
printf 'line one\ntoken %s here\n' "$GH" > "$W/s1"
check "secret: GitHub token found with its line" '[ "$(lib "secret_hits $W/s1")" = "GitHub token (line 2)" ]'
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAuthorization: Bearer abcdefghijklmnopqrstuvwxyz123\nkey sk-ant-abcdefghijklmnopqrstuvwxyz\nAKIAABCDEFGHIJKLMNOP\nxoxb-1234567890-abcdef\n' > "$W/s2"
check "secret: key, bearer, sk-, AWS, Slack all found" '[ "$(lib "secret_hits $W/s2" | wc -l | tr -d " ")" = 5 ]'
printf 'risk-management-and-compliance-review-items\nask-the-user-about-everything-first-please\nsk-short\nmask_ghp_notreally\n' > "$W/s3"
check "secret: no false positives on words ending in sk-" '[ -z "$(lib "secret_hits $W/s3")" ]'
doc "$W/clean"; check "doc_problems: clean doc -> none" '[ -z "$(lib "doc_problems $W/clean")" ]'
check "doc_problems: over MAX_DOC_CHARS" 'HANDOFF_MAX_DOC_CHARS=100 lib "doc_problems $W/clean" | grep -q "^size: .* over the limit of 100"'
check "doc_problems: default limit is 200000" 'lib "cfg MAX_DOC_CHARS 200000" | grep -qx 200000'
check "doc_problems: secrets line says what to do" 'lib "doc_problems $W/s1" | grep -q "^probable secrets: GitHub token (line 2). Replace each value"'

# ---- lib: stamp_workspace -----------------------------------------------------------------------------------------
G="$W/repo"; mkdir -p "$G"; git -C "$G" init -q -b main; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "first commit"
echo x > "$G/changed.txt"; mkdir -p "$G/.claude/handoff/sessions"; doc "$G/.claude/handoff/sessions/a.md"
D="$G/.claude/handoff/sessions/a.md"
CLAUDE_PROJECT_DIR="$G" bash -c "source '$SCR/handoff-lib.sh'; stamp_workspace '$D'"
check "stamp: section appended" 'grep -q "^## Workspace identity (recorded by the handoff plugin" "$D"'
check "stamp: branch and HEAD" 'grep -q "Branch: \`main\`" "$D" && grep -q "HEAD: \`[0-9a-f]* first commit\`" "$D"'
check "stamp: uncommitted file listed" 'grep -q "changed.txt" "$D" && grep -q "Uncommitted changes (1)" "$D"'
check "stamp: own .claude/handoff excluded" '! grep -q "\.claude/handoff" "$D"'
check "stamp: model sections kept" '[ -z "$(lib "missing_sections $D")" ]'
S1="$(wc -c <"$D")"; CLAUDE_PROJECT_DIR="$G" bash -c "source '$SCR/handoff-lib.sh'; stamp_workspace '$D'"
check "stamp: restamp replaces (one marker, same size)" '[ "$(grep -c "handoff plugin: workspace identity" "$D")" = 1 ] && [ "$(wc -c <"$D")" = "$S1" ]'
printf '\nextra line the model added later\n' >> "$D"   # model rewrote around it: everything from the marker is ours
CLAUDE_PROJECT_DIR="$G" bash -c "source '$SCR/handoff-lib.sh'; stamp_workspace '$D'"
check "stamp: content after the marker is the plugin's" '! grep -q "extra line" "$D" && [ "$(grep -c "handoff plugin: workspace identity" "$D")" = 1 ]'
doc "$W/nogit.md"; CLAUDE_PROJECT_DIR="$W/r" bash -c "source '$SCR/handoff-lib.sh'; stamp_workspace '$W/nogit.md' /"
check "stamp: non-git directory" 'grep -q "Not a git repository" "$W/nogit.md"'

# ---- Claude Stop hook ---------------------------------------------------------------------------------------------
C="$W/claude"; mkdir -p "$C"; HC="$C/.claude/handoff"
ctr() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s}}}\n' "$2" >> "$W/$1.jsonl"; }
cstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, stop_hook_active:$a}' \
  | CLAUDE_PROJECT_DIR="$C" CLAUDE_HANDOFF_NESTED="" bash "$SCR/handoff-stop.sh"; }
ctr c1 320000; O="$(cstop c1)"; check "claude: asks for the document" 'jq -r .hookSpecificOutput.additionalContext <<<"$O" | grep -q "sessions/c1.md"'
check "claude: request says no secrets, marks UNVERIFIED" 'jq -r .hookSpecificOutput.additionalContext <<<"$O" | grep -q "UNVERIFIED" && jq -r .hookSpecificOutput.additionalContext <<<"$O" | grep -q "Never copy secret values"'
doc "$HC/sessions/c1.md" "token $GH"
O="$(cstop c1 true)"
check "claude: secret -> fix request, not staged" 'jq -r .hookSpecificOutput.additionalContext <<<"$O" | grep -q "probable secrets: GitHub token" && ! grep -qs Goal "$HC/current.md"'
doc "$HC/sessions/c1.md" "token <GitHub token, from gh>"
O="$(cstop c1 true)"
check "claude: fixed -> staged" 'jq -r .systemMessage <<<"$O" | grep -q "written and staged"'
check "claude: staged copy carries the workspace stamp" 'grep -q "^## Workspace identity" "$HC/current.md"'
# persistent secret: 2 fix requests, then staged with a warning
ctr c2 320000; cstop c2 >/dev/null; doc "$HC/sessions/c2.md" "token $GH"
cstop c2 true >/dev/null; cstop c2 true >/dev/null; O="$(cstop c2 true)"
check "claude: after 2 fix requests staged with a warning" 'jq -r .systemMessage <<<"$O" | grep -q "Warning: the document still has probable secrets"'
# refresh counts from the staging, not from the request (writing a big document grows the context)
ctr c3 320000; cstop c3 >/dev/null; doc "$HC/sessions/c3.md"
ctr c3 360000; O="$(cstop c3)"   # separate-turn write (stop_hook_active false), +40k since the request
check "claude: first Stop after the write stages, no refresh request" 'jq -r .systemMessage <<<"$O" | grep -q "written and staged"'
perl -e "select(undef,undef,undef,1.2)"   # restamp in a later second: the version must not change
ctr c3 370000; O="$(cstop c3)"; check "claude: +10k after staging: no refresh" 'jq -r .systemMessage <<<"$O" | grep -q "written and staged"'
ctr c3 381000; O="$(cstop c3)"; check "claude: +21k after staging: refresh request" 'jq -r .hookSpecificOutput.additionalContext <<<"$O" | grep -q "out of date"'

# ---- Codex Stop hook ----------------------------------------------------------------------------------------------
X="$W/codex"; mkdir -p "$X"; HX="$X/.claude/handoff"
xtok() { printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"output_tokens":0},"model_context_window":475000}}}\n' "$2" >> "$W/$1.jsonl"; }
xstop() { jq -nc --arg s "$1" --arg t "$W/$1.jsonl" --arg c "$X" --argjson a "${2:-false}" '{session_id:$s, transcript_path:$t, cwd:$c, stop_hook_active:$a}' | bash "$SCR/codex-stop.sh"; }
xtok x1 100000; xstop x1 >/dev/null; xtok x1 320000; xstop x1 >/dev/null
doc "$HX/sessions/x1.md" "token $GH"
O="$(xstop x1 true)"; check "codex: secret -> fix request (block)" '[ "$(jq -r .decision <<<"$O")" = block ] && jq -r .reason <<<"$O" | grep -q "probable secrets"'
xstop x1 true >/dev/null; O="$(xstop x1 true)"
check "codex: persistent secret -> not sent, user told to redact" 'jq -r .systemMessage <<<"$O" | grep -q "Not sent automatically: redact"'
xtok x2 100000; xstop x2 >/dev/null; xtok x2 320000; xstop x2 >/dev/null; doc "$HX/sessions/x2.md"
O="$(xstop x2 true)"; check "codex: clean doc staged" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff written to"'
check "codex: document stamped" 'grep -q "^## Workspace identity" "$HX/sessions/x2.md"'
xtok x3 100000; xstop x3 >/dev/null; xtok x3 320000; xstop x3 >/dev/null; doc "$HX/sessions/x3.md"
xtok x3 360000; O="$(xstop x3)"; check "codex: first Stop after a big write stages, no refresh" 'jq -r .systemMessage <<<"$O" | grep -q "Handoff written to"'
perl -e "select(undef,undef,undef,1.2)"; xtok x3 370000; xstop x3 >/dev/null
xtok x3 381000; O="$(xstop x3)"; check "codex: +21k after staging: refresh request" 'jq -r .reason <<<"$O" | grep -q "out of date"'
HANDOFF_MAX_DOC_CHARS=50 xtok x4 100000; xstop x4 >/dev/null; xtok x4 320000; xstop x4 >/dev/null; doc "$HX/sessions/x4.md"
O="$(HANDOFF_MAX_DOC_CHARS=50 xstop x4 true)"; check "codex: oversize -> condense request" 'jq -r .reason <<<"$O" | grep -q "Condense it"'

echo "-----"; echo "passed: $P  failed: $F"; [ $F -eq 0 ]
