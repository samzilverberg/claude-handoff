#!/bin/bash
# Shared helpers. Sourced by the hook scripts.
# Nested `claude -p` runs inherit CLAUDE_HANDOFF_NESTED and must no-op.
[ -n "$CLAUDE_HANDOFF_NESTED" ] && exit 0
# macOS only for now (BSD stat/ps, t3ctl). Elsewhere: say so once per hook run and do nothing.
if [ "$(uname -s)" != "Darwin" ]; then
  echo '{"systemMessage":"handoff plugin: macOS only for now (uname -s != Darwin); hooks disabled on this host."}'
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
HANDOFF_DIR="$ROOT/.claude/handoff"
CURRENT="$HANDOFF_DIR/current.md"          # the file CLAUDE.md @imports
OWNER="$HANDOFF_DIR/current.owner"         # pid of the claude process whose handoff is in current.md
LOG="$HANDOFF_DIR/hooks.log"
mkdir -p "$HANDOFF_DIR/sessions" "$HANDOFF_DIR/by-pid" "$HANDOFF_DIR/state" "$HANDOFF_DIR/state/tombstones" "$HANDOFF_DIR/state/pid-cleared"
# cfg KEY default -> env HANDOFF_KEY (session override) > plugin userConfig (CLAUDE_PLUGIN_OPTION_KEY) > default
cfg() { local k="$1" d="$2" v; v="$(printenv "HANDOFF_$k" 2>/dev/null)"; [ -n "$v" ] || v="$(printenv "CLAUDE_PLUGIN_OPTION_$k" 2>/dev/null)"; printf '%s' "${v:-$d}"; }
# state get/set per session (tiny json)
state_get() { local f="$HANDOFF_DIR/state/$1.json"; [ -f "$f" ] && jq -r --arg k "$2" '.[$k] // empty' "$f" || true; }
state_set() { local f="$HANDOFF_DIR/state/$1.json"; local cur='{}'; [ -f "$f" ] && cur="$(cat "$f")"; jq -c --arg k "$2" --arg v "$3" '.[$k]=$v' <<<"$cur" > "$f"; }
REQUIRED_SECTIONS="Goal|Standing instructions|Decisions|Current state|In progress|Next steps|Key files|Gotchas|Open questions"
# missing_sections <file> -> prints missing section names (one per line); empty when all present
missing_sections() { local f="$1"; echo "$REQUIRED_SECTIONS" | tr '|' '\n' | while read -r sec; do grep -qiE "^##+ .*${sec}" "$f" 2>/dev/null || echo "$sec"; done; }
log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2" >> "$LOG"; }
now() { date +%s; }
mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
age() { echo $(( $(now) - $(mtime "$1") )); }

# pid of the claude process that spawned this hook (hooks are spawned directly: $PPID). Walk up as a fallback.
# Match the *executable* (first token, basename == claude), not any command line containing the
# substring "claude": a plain *claude* match also hits ".claude/…" paths (snapshot/plugin-cache
# shells), which would return an intermediate shell's pid instead of the real Claude process.
claude_pid() {
  local p=$PPID i=0 cmd exe
  while [ $i -lt 4 ] && [ "$p" -gt 1 ]; do
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"; exe="${cmd%% *}"
    case "${exe##*/}" in claude) echo "$p"; return;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i+1))
  done
  echo "$PPID"
}
CPID="$(claude_pid)"

# Approx current context = usage of the last assistant message in the transcript.
context_tokens() {
  local t="$1"; [ -f "$t" ] || { echo 0; return; }
  # max over the last 3 assistant messages: the transcript may not have flushed the final message yet at Stop time
  grep '"type":"assistant"' "$t" | tail -n 3 | jq -rs 'map((.message.usage // {}) as $u
    | (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0))) | max // 0' 2>/dev/null || echo 0
}

# Publish <file> as this process's handoff: current.md (imported by CLAUDE.md) + by-pid copy + owner marker.
publish() {
  local f="$1"; [ -s "$f" ] || return 1
  cp "$f" "$HANDOFF_DIR/by-pid/$CPID.md"; cp "$f" "$CURRENT"; echo "$CPID" > "$OWNER"
  log publish "pid=$CPID <- $f"
}
reset_current() { printf '# Handoff\n(none)\n' > "$CURRENT"; rm -f "$OWNER"; log reset "pid=$CPID"; }
owner_pid() { cat "$OWNER" 2>/dev/null || echo ""; }

# Condense JSONL transcript -> text for the summarizer (tool results truncated).
condense_transcript() {
  local t="$1" m="$(cfg RESULT_CHARS 600)"
  jq -r --argjson m "$m" '
    select(.type=="user" or .type=="assistant") | .message as $msg
    | if ($msg.content|type)=="string" then "\(.type|ascii_upcase): \($msg.content)"
      else ($msg.content[]? |
        if .type=="text" then "\($msg.role|ascii_upcase): \(.text)"
        elif .type=="tool_use" then "TOOL_USE \(.name): \((.input|tostring)[:$m])"
        elif .type=="tool_result" then "TOOL_RESULT: \((if (.content|type)=="string" then .content else ((.content // [])|map(.text? // "")|join(" ")) end)[:$m])"
        else empty end) end' "$t" 2>/dev/null
}

# generate_handoff <transcript> <session_id> <reason> -> writes sessions/<sid>.md via nested claude -p
generate_handoff() {
  local t="$1" sid="$2" reason="$3" out="$HANDOFF_DIR/sessions/$2.md"
  local condensed; condensed="$(condense_transcript "$t")"
  log gen "reason=$reason sid=$sid chars=${#condensed} model=$(cfg MODEL claude-opus-4-8)"
  local prompt='You are writing a HANDOFF DOCUMENT for a coding session whose context window is ending.
A fresh instance of the same agent will read ONLY this document plus the repo, then continue the work.
The transcript below contains the user'"'"'s messages in full. Every instruction the user gave is steering that the
successor must know about, even if it was later changed: record it and mark its status rather than dropping it.
Markdown, exactly these sections, in this order, bullets, concrete (paths, symbols, commands, exact decisions), no placeholders:
# Handoff
## Goal (the user'"'"'s actual ask, their words where possible)
## Standing instructions from the user (every directive, in order, near-verbatim: scope limits, "do not X", "always Y", style/format preferences, process rules, corrections. Tag each [active] / [superseded by #n] / [withdrawn]; name the source: user message (quote a few words), CLAUDE.md, or hook note)
## Decisions log (each significant decision: what, who decided (user/assistant), why, [active] / [reversed by #n])
## Current state (DONE, and how it was verified)
## In progress (exact step being executed when context ended)
## Next steps (ordered, actionable)
## Key files & symbols (path:line where known, one-line role each)
## Gotchas / dead ends (tried and rejected, why)
## Open questions for the user

Transcript follows (condensed; tool outputs truncated):'
  local result
  result="$(printf '%s\n\n%s\n' "$prompt" "$condensed" | CLAUDE_HANDOFF_NESTED=1 claude -p \
      --model "$(cfg MODEL claude-opus-4-8)" --setting-sources "" --no-session-persistence \
      --permission-mode plan --disallowedTools "Bash,Edit,Write,Agent" --effort "$(cfg EFFORT medium)" 2>>"$LOG")"
  if [ $? -ne 0 ] || [ -z "$result" ]; then log gen "FAILED"; return 1; fi
  { printf -- '---\nsession: %s\nreason: %s\nwritten: %s\ncontext_tokens: %s\n---\n\n' "$sid" "$reason" "$(date -Iseconds)" "$(context_tokens "$t")"
    printf '%s\n' "$result"; } > "$out"
  log gen "wrote $out ($(wc -c <"$out" | tr -d ' ') bytes)"
}

# session_handoff <transcript> <sid> <reason> [max_age] -> path of a usable handoff for this session (reuse fresh or generate)
session_handoff() {
  local f="$HANDOFF_DIR/sessions/$2.md" max="${4:-$(cfg FRESH_SEC 900)}"
  if [ -s "$f" ] && [ "$(age "$f")" -lt "$max" ]; then echo "$f"; return 0; fi
  generate_handoff "$1" "$2" "$3" && echo "$f"
}

# --- session tombstones (supersession guard) --------------------------------
# Root cause of the duplicate-run bug: an in-process /clear mints a NEW session id, but the T3
# Code host keeps its resume cursor on the OLD (pre-clear) id, so it later respawns
# `claude --resume <OLD>` — a "zombie" that carries the full pre-clear context, re-runs the task,
# and re-publishes the stale handoff, duplicating edits/jobs/threads. (Confirmed in hooks.log:
# sessionend reason=clear <OLD> -> sessionstart source=clear <NEW> -> hours later
# sessionstart source=resume <OLD> in a new pid, then repeated [publish] of <OLD>'s handoff.)
# A tombstone records that <OLD> was cleared/superseded so the zombie's hooks go inert and its
# SessionStart tells the model to stop. The claim-marker on the handoff (an earlier attempt)
# could not help: the zombie never goes through /handoff:resume.
tombstone_file() { echo "$HANDOFF_DIR/state/tombstones/$1.json"; }
is_tombstoned()  { [ -f "$(tombstone_file "$1")" ]; }
tombstone_get()  { local f; f="$(tombstone_file "$1")"; [ -f "$f" ] && jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null || true; }
# tombstone_set <sid> <cleared_by_pid> : mark <sid> as cleared/superseded (idempotent).
tombstone_set() {
  mkdir -p "$HANDOFF_DIR/state/tombstones"
  jq -nc --arg pid "$2" --arg at "$(date -Iseconds)" --argjson ts "$(now)" \
    '{cleared_by_pid:$pid, cleared_at:$at, cleared_ts:$ts}' > "$(tombstone_file "$1")"
  log tombstone "set sid=$1 by pid=$2"
}
# tombstone_link <sid> <continued_by_sid> : record the successor session (best-effort note only).
tombstone_link() {
  local f cur; f="$(tombstone_file "$1")"; [ -f "$f" ] || return 0
  cur="$(cat "$f")"; jq -c --arg n "$2" '.continued_by=$n' <<<"$cur" > "$f"
  log tombstone "link sid=$1 -> $2"
}
