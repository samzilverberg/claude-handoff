#!/bin/bash
# UserPromptSubmit. Fast no-op unless this session is tombstoned (/cleared and superseded). A tombstoned session
# that gets a prompt under T3 Code is a thread T3 resumed on its stale pre-/clear session (a /clear by plugin <= 0.5,
# or one whose alias failed). With T3_AUTOCLEAR the prompt must not run in that stale context (a resumed 300k+
# session costs a full uncached read and acts on outdated state): block it (zero tokens; T3 shows the reason as a
# notice) and recover the thread: newest handoff of the /clear chain + transcript digest, /clear (which aliases
# T3's session to the fresh one), /handoff:resume with the prompt. Outside T3 nothing is blocked: the user picked this session (claude --resume) and the
# SessionStart note already says where the work continues.
IN="$(cat)"
SID="$(jq -r .session_id <<<"$IN")"
# runs on every prompt: answer the common case (live session) before loading the library
[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/handoff/state/tombstones/$SID.json" ] || exit 0
source "$(dirname "$0")/handoff-lib.sh"
log userprompt "tombstoned sid=$SID"
[ "$(cfg T3_AUTOCLEAR false)" = "true" ] || exit 0
PF="$HANDOFF_DIR/state/$SID.prompt.txt"; jq -r '.prompt // empty' <<<"$IN" > "$PF"
[ -s "$PF" ] || exit 0
R="$(HANDOFF_TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$IN")" bash "$(dirname "$0")/t3.sh" "$ROOT" "$LOG" "$SID" recover "$PF")"
if grep -q '^RECOVERING$' <<<"$R"; then
  jq -nc '{decision:"block", reason:"This thread had resumed a stale Claude session (one an older handoff plugin /cleared in place). The handoff plugin is restoring it: /clear, then /handoff:resume from the latest handoff, with your message. No need to resend it."}'
  exit 0
fi
# could not recover: let the prompt through, but make sure the model knows it is a stale session
log userprompt "recover failed: $(head -1 <<<"$R")"
jq -nc --arg c "Handoff plugin: this session ($SID) was already handed off; recovering it failed ($(head -1 <<<"$R")). Tell the user the work continues elsewhere (see the SessionStart note) and do not act on stale state." \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
exit 0
