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
# Which agent runs the hooks: claude (default) or codex (scripts/codex-*.sh set HANDOFF_AGENT=codex before sourcing).
AGENT="${HANDOFF_AGENT:-claude}"
# Codex plugins have no userConfig: their settings live in a KEY=VALUE file (HANDOFF_CONF, default ~/.codex/handoff.conf).
HANDOFF_CONF="${HANDOFF_CONF:-${CODEX_HOME:-$HOME/.codex}/handoff.conf}"
# cfg KEY default -> env HANDOFF_KEY (session override) > per-project KEY=VALUE file (.claude/handoff/handoff.conf;
# codex: codex.conf first) > plugin userConfig (CLAUDE_PLUGIN_OPTION_KEY; codex: the global conf file) > default
conf_get() { [ -f "$2" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -1 | sed 's/[[:space:]]*\(#.*\)\{0,1\}$//; s/^"\(.*\)"$/\1/'; }
cfg() {
  local k="$1" d="$2" v f; v="$(printenv "HANDOFF_$k" 2>/dev/null)"
  if [ "$AGENT" = codex ]; then
    for f in "$HANDOFF_DIR/codex.conf" "$HANDOFF_DIR/handoff.conf" "$HANDOFF_CONF"; do [ -n "$v" ] && break; v="$(conf_get "$k" "$f")"; done
  else
    [ -n "$v" ] || v="$(conf_get "$k" "$HANDOFF_DIR/handoff.conf")"
    [ -n "$v" ] || v="$(printenv "CLAUDE_PLUGIN_OPTION_$k" 2>/dev/null)"
  fi
  printf '%s' "${v:-$d}"
}
# state get/set per session (tiny json)
state_get() { local f="$HANDOFF_DIR/state/$1.json"; [ -f "$f" ] && jq -r --arg k "$2" '.[$k] // empty' "$f" || true; }
state_set() { local f="$HANDOFF_DIR/state/$1.json"; local cur='{}'; [ -f "$f" ] && cur="$(cat "$f")"; jq -c --arg k "$2" --arg v "$3" '.[$k]=$v' <<<"$cur" > "$f"; }
# session_key <sid>: key for per-context-window state and the handoff doc. On T3 < 0.1.10 the T3 layer (t3.sh alias) maps every
# post-/clear session of a thread to the Claude session id T3 resumes, so both carry over a T3 respawn that comes
# back under that id. Elsewhere: the sid itself.
session_key() { local k; k="$(cat "$HANDOFF_DIR/state/aliased-by/$1" 2>/dev/null)"; echo "${k:-$1}"; }
REQUIRED_SECTIONS="Goal|Standing instructions|Decisions|Current state|In progress|Next steps|Key files|Gotchas|Open questions"
# missing_sections <file> -> prints missing section names (one per line); empty when all present
missing_sections() { local f="$1"; echo "$REQUIRED_SECTIONS" | tr '|' '\n' | while read -r sec; do grep -qiE "^##+ .*${sec}" "$f" 2>/dev/null || echo "$sec"; done; }
log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2" >> "$LOG"; }
timed() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }   # timed <sec> <cmd…> (hook time limits)

# --- document checks, run before a handoff document is staged or sent ---------------------------------------------
# label|ERE. Anchored on a non-word character (or line start) where a prefix could end an ordinary word ("risk-…").
SECRET_PATTERNS='private key|-----BEGIN [A-Z ]*PRIVATE KEY-----
OpenAI/Anthropic-style API key|(^|[^A-Za-z0-9_-])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}
GitHub token|(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})
AWS access key|(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}
Slack token|(^|[^A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}
bearer token|[Bb]earer [A-Za-z0-9._~+/=-]{20,}'
# secret_hits <file> -> "label (line N)" per hit, at most 10
secret_hits() {
  local f="$1" label re
  while IFS='|' read -r label re; do
    [ -n "$re" ] || continue
    grep -nE -- "$re" "$f" 2>/dev/null | cut -d: -f1 | awk -v l="$label" '{print l " (line " $0 ")"}'
  done <<<"$SECRET_PATTERNS" | head -n 10
}
# doc_problems <file> [threshold] -> one line per problem (empty = fine): probable secrets, size over the limit.
# Size limit: MAX_DOC_CHARS (200000), lowered to MAX_DOC_SHARE percent (25) of the threshold (tokens, ~4 characters
# each) when that is smaller. A fresh session starts at base context + document; a document near the threshold leaves
# it no room to work before the next handoff, so the limit shrinks with low thresholds.
doc_problems() {
  local f="$1" thr="${2:-0}" max share cap n hits why="MAX_DOC_CHARS"
  max="$(cfg MAX_DOC_CHARS 200000)"; max="${max%.*}"; share="$(cfg MAX_DOC_SHARE 25)"; share="${share%.*}"
  if [ "${share:-0}" -gt 0 ] && [ "$thr" -gt 0 ]; then
    cap=$((thr * share * 4 / 100))
    if [ "$max" -le 0 ] || [ "$cap" -lt "$max" ]; then max="$cap"; why="MAX_DOC_SHARE: ${share}% of the ${thr}-token handoff threshold, ~4 characters per token"; fi
  fi
  hits="$(secret_hits "$f" | paste -sd ',' - | sed 's/,/, /g')"
  [ -n "$hits" ] && echo "probable secrets: $hits. Replace each value with a placeholder that says what it was and where it lives (e.g. <GitHub token, from ~/.config/gh>), never the value."
  n="$(wc -c <"$f" | tr -d ' ')"
  [ "$max" -gt 0 ] && [ "$n" -gt "$max" ] && echo "size: $n characters, over the limit of $max ($why). Condense it: keep Standing instructions, Decisions log and Next steps complete, shorten the narrative sections, and point to files or commits instead of pasting their content."
  return 0
}

# stamp_workspace <file> [dir]: (re)write the trailing "Workspace identity" section the plugin records at staging time
# (directory, git branch, HEAD, uncommitted files), so the next context can tell whether the repo moved since. Replaces
# an earlier stamp; everything from the marker line on belongs to the plugin.
WS_MARK='<!-- handoff plugin: workspace identity (rewritten at every staging) -->'
stamp_workspace() {
  local f="$1" dir="${2:-$ROOT}" tmp top st n
  [ -s "$f" ] || return 1
  tmp="$f.ws.$$"
  awk -v m="$WS_MARK" '$0==m{exit} /^[[:space:]]*$/{b=b $0 "\n"; next} {printf "%s", b; b=""; print}' "$f" > "$tmp"
  {
    printf '\n%s\n## Workspace identity (recorded by the handoff plugin, %s)\n\n- Directory: `%s`\n' "$WS_MARK" "$(date '+%Y-%m-%d %H:%M %Z')" "$dir"
    if top="$(timed 5 git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
      printf -- '- Repository: `%s`\n- Branch: `%s`\n- HEAD: `%s`\n' "$top" \
        "$(timed 5 git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || echo '(detached)')" \
        "$(timed 5 git -C "$dir" log -1 --format='%h %s' 2>/dev/null | cut -c1-120)"
      st="$(timed 5 git -C "$dir" --no-optional-locks status --short 2>/dev/null | grep -v '\.claude/handoff/')"
      n="$(printf '%s' "$st" | grep -c .)"
      if [ "$n" -eq 0 ]; then printf -- '- Uncommitted changes: none\n'
      else
        printf -- '- Uncommitted changes (%s):\n\n```\n%s\n```\n' "$n" "$(printf '%s\n' "$st" | head -n 40)"
        [ "$n" -gt 40 ] && printf -- '(and %s more)\n' $((n - 40))
      fi
    else printf -- '- Not a git repository\n'; fi
    printf '\nOn resume: compare the repository with this record (branch, HEAD, uncommitted files). If it differs in a way this document does not explain, tell the user what differs before changing anything.\n'
  } >> "$tmp"
  mv "$tmp" "$f"
}
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
# Codex: the rollout's last token_count event (input + output of the last model request = what the next one reads).
context_tokens() {
  local t="$1"; [ -f "$t" ] || { echo 0; return; }
  if [ "$AGENT" = codex ]; then
    grep '"type":"token_count"' "$t" | tail -n 1 | jq -r '.payload.info.last_token_usage // {} | ((.input_tokens // 0) + (.output_tokens // 0))' 2>/dev/null || echo 0
    return
  fi
  # max over the last 3 assistant messages: the transcript may not have flushed the final message yet at Stop time
  grep '"type":"assistant"' "$t" | tail -n 3 | jq -rs 'map((.message.usage // {}) as $u
    | (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0))) | max // 0' 2>/dev/null || echo 0
}

# codex_window <rollout>: the model's context window as Codex reports it (0 when unknown)
codex_window() { grep '"type":"token_count"' "$1" 2>/dev/null | tail -n 1 | jq -r '.payload.info.model_context_window // 0' 2>/dev/null || echo 0; }

# The nine handoff sections (both agents' end-of-turn requests).
SECTIONS='Sections, in this order: # Handoff; ## Goal (the user'"'"'s actual ask, their words where possible); ## Standing instructions from the user (EVERY steering directive the user gave in this conversation, in order, near-verbatim, one bullet each: scope limits, "do not X", "always Y", style/format preferences, process rules, corrections of your behaviour. Tag each [active] or [superseded by #n] or [withdrawn], and name its source: which user message (quote a few words), CLAUDE.md, or a hook note; do not attribute a chat instruction to CLAUDE.md. Never drop an entry because it was later changed; the successor must see the history); ## Decisions log (each significant decision: what, who decided (user/assistant), why, and [active] or [reversed by #n]); ## Current state (done + how verified; mark anything not actually checked in this conversation UNVERIFIED); ## In progress (exact step when context ended); ## Next steps (ordered, actionable); ## Key files & symbols (path:line, one-line role); ## Gotchas / dead ends (tried and rejected, why); ## Open questions for the user. Before writing, re-read the user'"'"'s messages in this conversation and make sure every directive appears under Standing instructions. Be concrete: paths, symbols, commands, exact decisions. No placeholders. Never copy secret values (API keys, tokens, passwords, private keys) into it: name them and where they live instead. The plugin appends a Workspace identity section (git branch, HEAD, changes) itself.'

# T3 Code sets T3CODE_THREAD_ID (its thread id) in the env of the agent processes it runs. A T3 "fresh session"
# (composer /clear, or a send with freshContext: T3 Code >= 0.1.9) replaces the process: the new session starts with
# SessionStart(startup) in a new pid, so neither by-pid nor the /clear bridge reaches it. publish() therefore also
# stages the doc per thread (by-thread/<thread>.md + .json: who staged it); SessionStart(startup) of the next session
# of that thread adopts it (adopt_thread_doc), and a /clear or compact that consumes it in-process drops it.
T3TID="${T3CODE_THREAD_ID:-}"
BYTHREAD="$HANDOFF_DIR/by-thread"
thread_doc() { printf '%s/%s' "$BYTHREAD" "$(printf '%s' "$T3TID" | tr '/' '_')"; }   # base path, no extension
# drop_thread_doc [why]: the staged per-thread doc was consumed (or superseded): archive it
drop_thread_doc() {
  [ -n "$T3TID" ] || return 0; local b; b="$(thread_doc)"; [ -f "$b.md" ] || { rm -f "$b.json"; return 0; }
  mkdir -p "$BYTHREAD/consumed"; mv "$b.md" "$BYTHREAD/consumed/$(basename "$b")-$(now).md"; rm -f "$b.json"
  log by-thread "dropped staged doc of thread $T3TID (${1:-consumed})"
}

# Publish <file> [sid] as this process's handoff: current.md (imported by CLAUDE.md) + by-pid copy + owner marker
# (+ by-thread copy under T3 Code, see above; sid = the session whose handoff it is).
publish() {
  local f="$1" sid="${2:-}"; [ -s "$f" ] || return 1
  stamp_workspace "$f"
  cp "$f" "$HANDOFF_DIR/by-pid/$CPID.md"; cp "$f" "$CURRENT"; echo "$CPID" > "$OWNER"
  if [ -n "$T3TID" ]; then
    local b; b="$(thread_doc)"; mkdir -p "$BYTHREAD"; cp "$f" "$b.md"
    jq -nc --arg sid "$sid" --arg key "$( [ -n "$sid" ] && session_key "$sid")" --arg pid "$CPID" --arg doc "$f" --arg at "$(date -Iseconds)" \
      '{sid:$sid, key:$key, pid:$pid, doc:$doc, at:$at}' > "$b.json"
  fi
  log publish "pid=$CPID <- $f${T3TID:+ (+ by-thread $T3TID)}"
}
# note_publish <key> <file> <ctx>: remember the context size at which this version of the document was staged. A
# version = a hash of the model-written part (the workspace stamp, rewritten at every staging, excluded). The "refresh
# a stale handoff" request counts growth from there, not from the request that produced the document: writing a large
# document can itself grow the context past LIVE_EVERY.
note_publish() {
  local h; h="$(awk -v m="$WS_MARK" '$0==m{exit} {print}' "$2" | shasum | cut -c1-16)"
  [ "$h" = "$(state_get "$1" pub_hash)" ] && return 0
  state_set "$1" pub_hash "$h"; state_set "$1" pub_ctx "$3"
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
Markdown, exactly these sections, in this order, bullets, concrete (paths, symbols, commands, exact decisions), no placeholders, no secret values (name keys/tokens/passwords and where they live instead):
# Handoff
## Goal (the user'"'"'s actual ask, their words where possible)
## Standing instructions from the user (every directive, in order, near-verbatim: scope limits, "do not X", "always Y", style/format preferences, process rules, corrections. Tag each [active] / [superseded by #n] / [withdrawn]; name the source: user message (quote a few words), CLAUDE.md, or hook note)
## Decisions log (each significant decision: what, who decided (user/assistant), why, [active] / [reversed by #n])
## Current state (DONE, and how it was verified; mark anything not actually checked UNVERIFIED)
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
# chain_tail <sid>: follow continued_by links to the newest session (bounded); <sid> itself when none
chain_tail() { local cur="$1" nx i=0; while [ $i -lt 20 ]; do nx="$(tombstone_get "$cur" continued_by)"; [ -n "$nx" ] || break; cur="$nx"; i=$((i+1)); done; echo "$cur"; }
# tombstone_link <sid> <continued_by_sid> : record the successor session (best-effort note only).
tombstone_link() {
  local f cur; f="$(tombstone_file "$1")"; [ -f "$f" ] || return 0
  cur="$(cat "$f")"; jq -c --arg n "$2" '.continued_by=$n' <<<"$cur" > "$f"
  log tombstone "link sid=$1 -> $2"
}

# nudge_pending <sid> [file]: a T3 nudge worker (t3.sh nudge) for this session still waits to send <file> (default: the
# handoff request, state/<sid>.nudge.txt); state/<sid>.nudge-pending = "<worker pid> <file>", removed by the worker
nudge_pending() {
  local p f; [ -f "$HANDOFF_DIR/state/$1.nudge-pending" ] || return 1; read -r p f < "$HANDOFF_DIR/state/$1.nudge-pending"
  [ "$f" = "${2:-$HANDOFF_DIR/state/$1.nudge.txt}" ] && kill -0 "$p" 2>/dev/null && ps -o command= -p "$p" 2>/dev/null | grep -q 't3\.sh.* --bg nudge'
}

# --- deferred handoff (T3_DEFER, T3 layer only) ----------------------------------------------------------------------
# off (default): the handoff runs right after the turn that crosses the threshold. resume: the document is written then,
# but the fresh session waits for the user's next message. all: nothing at the turn end; the next message starts it
# (document, then fresh session). Either way the held message is blocked in UserPromptSubmit and re-sent into the fresh
# session (resume args / inline), so the user reads the last reply undisturbed and the message runs in the new context.
# Files: state/defer/<sid> = armed kind; state/<sid>.pending-prompt.txt (resume args), .pending-raw.txt (the message);
# state/<sid>.held = a message was blocked (a Stop right after it is not a real turn end).
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T3SH="${HANDOFF_T3_SH:-$LIBDIR/t3.sh}"   # tests point this at a stub
DEFER_DIR="$HANDOFF_DIR/state/defer"
t3_defer() {
  [ "$(cfg T3_AUTOCLEAR false)" = "true" ] || { echo off; return; }
  case "$(cfg T3_DEFER off)" in resume) echo resume;; all) echo all;; *) echo off;; esac
}
is_plugin_prompt() { case "$1" in "[handoff plugin]"*|"/handoff:resume"*) return 0;; esac; return 1; }
# defer_arm <sid> <kind> [request text]: hold the handoff (all) or its fresh session (resume) until the next message.
# Only when the T3 helper reaches this thread now (else the caller runs the handoff at once). 0 = armed; DEFER_WHY.
defer_arm() {
  local R; DEFER_WHY=""
  R="$(bash "$T3SH" "$ROOT" "$LOG" "$1" check 2>/dev/null)"
  case "$R" in ok:*) ;; *) DEFER_WHY="${R:-T3 helper check failed}"; log defer "not armed ($2) for sid=$1: $DEFER_WHY"; return 1;; esac
  mkdir -p "$DEFER_DIR"; echo "$2" > "$DEFER_DIR/$1"
  [ -n "${3:-}" ] && printf '[handoff plugin] %s\n\n(Sent by the handoff plugin before your held-back message, which then runs in a fresh session of this thread.)\n' "$3" > "$HANDOFF_DIR/state/$1.nudge.txt"
  log defer "armed $2 for sid=$1"
}
is_armed() { [ -f "$DEFER_DIR/$1" ]; }
# held_after_block <sid>: true (and consumed) when this Stop follows a message the plugin blocked
held_after_block() { [ -f "$HANDOFF_DIR/state/$1.held" ] || return 1; rm -f "$HANDOFF_DIR/state/$1.held"; log defer "Stop after a held message (sid=$1): ignored"; }
pending_prompt() { local p="$HANDOFF_DIR/state/$1.pending-prompt.txt"; [ -s "$p" ] && echo "$p"; }
# release_held_prompt <sid> <why>: the deferred handoff cannot finish: send the held message back as a normal turn
release_held_prompt() {
  local raw="$HANDOFF_DIR/state/$1.pending-raw.txt" R
  [ -s "$raw" ] || return 0
  R="$(bash "$T3SH" "$ROOT" "$LOG" "$1" nudge "$raw")"
  log defer "released the held message of sid=$1 ($2): $R"
  rm -f "$HANDOFF_DIR/state/$1.pending-prompt.txt" "$raw"
}
# defer_on_prompt <sid> <prompt> <doc> <key>: UserPromptSubmit. Prints the hook output and returns 0 when it acted.
defer_on_prompt() {
  local sid="$1" p="$2" doc="$3" key="$4" m="$DEFER_DIR/$1" kind pp raw R
  if is_plugin_prompt "$p"; then rm -f "$HANDOFF_DIR/state/$sid.held"; return 1; fi
  [ -f "$m" ] || return 1
  kind="$(cat "$m")"; rm -f "$m"
  pp="$HANDOFF_DIR/state/$sid.pending-prompt.txt"; raw="$HANDOFF_DIR/state/$sid.pending-raw.txt"
  printf '%s\n' "$p" > "$raw"
  { printf '%s\n\n' "The user sent the message below after the previous context of this thread ended. It was held back so that it runs in this fresh context: handle it now, with the handoff document as the record of the work so far (where they conflict, the message wins over the document's Next steps)."
    printf '%s\n' "$p"; } > "$pp"
  case "$kind" in
    all)    R="$(bash "$T3SH" "$ROOT" "$LOG" "$sid" nudge "$HANDOFF_DIR/state/$sid.nudge.txt")" ;;
    resume) R="$(HANDOFF_RESUME_ARGS="$pp" bash "$T3SH" "$ROOT" "$LOG" "$sid" clear "$doc")"
            case "$R" in *scheduled*) state_set "$key" t3_clear 1;; esac ;;
  esac
  case "$R" in
    *scheduled*)
      touch "$HANDOFF_DIR/state/$sid.held"; log defer "held the message of sid=$sid; $kind started: $R"
      if [ "$kind" = all ]; then W="the handoff document is written first, then your message"; else W="your message"; fi
      jq -nc --arg r "Handoff plugin: this context is past its handoff limit, so this message is held back: $W runs in a fresh session of this thread. No need to resend it." '{decision:"block", reason:$r}'
      return 0 ;;
  esac
  rm -f "$pp" "$raw"; log defer "deferred $kind could not start for sid=$sid: $R; message runs here"
  jq -nc --arg m "Handoff plugin: the deferred handoff could not start (${R:-no reason}); this message runs in the current context." '{systemMessage:$m}'
  return 0
}

# --- manual handoff (/handoff:now) -----------------------------------------------------------------------------------
# The user types `/handoff:now [model] [effort] [note]` to hand off before the threshold, optionally continuing on another
# model or effort of the same provider (T3 layer: the fresh session is sent with `threads send --fresh -m … -e …`).
# UserPromptSubmit arms state/manual/<sid>.json (manual_arm) and gives the turn the writing request; the Stop hook treats
# the session as past the threshold (no loop guard, no T3_DEFER) and stages the document once it was (re)written after
# the arming, then runs the handoff (T3_AUTOCLEAR: fresh session; else the user types /clear). The note reaches the fresh
# session as /handoff:resume arguments. Files: state/manual/<sid>.json {at, model, effort, note}, state/<sid>.manual-note.txt.
MANUAL_DIR="$HANDOFF_DIR/state/manual"
EFFORTS="low medium high xhigh max ultrathink"
is_manual_prompt() { case "$1" in "/handoff:now"|"/handoff:now "*|"/handoff:now"$'\n'*|"/handoff:now"$'\t'*) return 0;; esac; return 1; }
is_manual() { [ -f "$MANUAL_DIR/$1.json" ]; }
manual_get() { local f="$MANUAL_DIR/$1.json"; [ -f "$f" ] && jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null; return 0; }
manual_done() { [ -f "$MANUAL_DIR/$1.json" ] && log manual "done sid=$1 (${2:-})"; rm -f "$MANUAL_DIR/$1.json"; }
# manual_desc <sid>: " (model X, effort Y)" for messages; empty when neither was asked
manual_desc() {
  local m e; m="$(manual_get "$1" model)"; e="$(manual_get "$1" effort)"; m="${m#-}"; e="${e#-}"; m="${m##*/}"
  [ -n "$m$e" ] && printf ' (%s%s%s)' "${m:+model $m}" "${m:+${e:+, }}" "${e:+effort $e}"
  return 0
}
# looks_like_model <lowercase token>: a bare /handoff:now argument meant as a model (validated later where possible)
looks_like_model() { case "$1" in */*|claude-*|opus*|sonnet*|haiku*|fable*|gpt-*|codex*) return 0;; esac; return 1; }
# manual_parse <args>: sets MP_MODEL, MP_EFFORT, MP_NOTE. Leading tokens: -m/--model X, -e/--effort X, an effort word,
# a model-looking token; the first other token (or `--`) starts the note, kept verbatim. A version right after the model
# joins it ("opus 4.8" -> opus-4.8, "opus 5" -> opus-5; t3.sh model resolves family and version).
manual_parse() {
  local rest="$1" tok nxt lc re='^[[:space:]]*([^[:space:]]+)(.*)$' ver='^[vV]?([0-9]+([._-][0-9]+)?)$'
  MP_MODEL=""; MP_EFFORT=""; MP_NOTE=""
  # join_version: MP_MODEL takes the version token at the start of $rest, if any
  join_version() { [[ "$rest" =~ $re ]] && [[ "${BASH_REMATCH[1]}" =~ $ver ]] || return 0
    local v="${BASH_REMATCH[1]}"; [[ "$rest" =~ $re ]]; MP_MODEL="$MP_MODEL-$v"; rest="${BASH_REMATCH[2]}"; }
  while [[ "$rest" =~ $re ]]; do
    tok="${BASH_REMATCH[1]}"; nxt="${BASH_REMATCH[2]}"; lc="$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')"
    case "$tok" in
      --) rest="$nxt"; break;;
      -m|--model|-e|--effort)
        [[ "$nxt" =~ $re ]] || break
        case "$tok" in -m|--model) MP_MODEL="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; join_version; continue;;
          *) MP_EFFORT="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')";; esac
        rest="${BASH_REMATCH[2]}"; continue;;
      --model=*) MP_MODEL="${tok#*=}";;
      --effort=*) MP_EFFORT="$(printf '%s' "${tok#*=}" | tr '[:upper:]' '[:lower:]')";;
      *)
        if [ -z "$MP_EFFORT" ] && [[ " $EFFORTS " == *" $lc "* ]]; then MP_EFFORT="$lc"
        elif [ -z "$MP_MODEL" ] && looks_like_model "$lc"; then MP_MODEL="$tok"; rest="$nxt"; join_version; continue
        else break; fi;;
    esac
    rest="$nxt"
  done
  MP_NOTE="$(printf '%s' "$rest" | sed -e '1s/^[[:space:]]*//' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
  MP_NOTE="${MP_NOTE%"${MP_NOTE##*[![:space:]]}"}"
}
# manual_arm <sid> <prompt>: UserPromptSubmit of `/handoff:now …`. Prints the hook output: the writing request as
# additionalContext, or a block when the handoff cannot be armed (bad model/effort, one already under way).
manual_arm() {
  local sid="$1" key doc R m e warn="" what req desc st
  key="$(session_key "$sid")"; doc="$HANDOFF_DIR/sessions/$key.md"
  manual_parse "${2#/handoff:now}"; m="$MP_MODEL"; e="$MP_EFFORT"
  # a T3 handoff of this session already scheduled and not finished: nothing to arm
  st="$(cat "$HANDOFF_DIR/state/$sid.t3clear" 2>/dev/null)"
  if [ "$(state_get "$key" t3_clear)" = 1 ] && { [ "$st" = pending ] || case "$st" in pending:*) true;; *) false;; esac; }; then
    log manual "not armed (sid=$sid): a T3 handoff is already scheduled ($st)"
    jq -nc --arg r "Handoff plugin: a handoff of this session is already scheduled ($st); /handoff:now not run. See /handoff:status." '{decision:"block", reason:$r}'
    return 0
  fi
  if [ -n "$m$e" ]; then
    if [ "$(cfg T3_AUTOCLEAR false)" = true ] && [ -n "$T3TID" ]; then
      R="$(bash "$T3SH" "$ROOT" "$LOG" "$sid" model "$m" "$e" 2>/dev/null | tail -n 1)"
      case "$R" in
        "ok "*) read -r _ m e <<<"$R";;
        "error: "*)
          log manual "not armed (sid=$sid): $R"
          jq -nc --arg r "Handoff plugin: /handoff:now not run: ${R#error: }. Usage: /handoff:now [model] [effort] [note]; put -- before a note whose first words were read as a model or version." '{decision:"block", reason:$r}'
          return 0;;
        *) warn=" Model/effort not checked (${R#skip: }); T3 checks them when it starts the fresh session.";;
      esac
    else
      warn=" Model/effort switching needs T3 Code with T3_AUTOCLEAR=true; after /clear pick them yourself (/model)."
      m=""; e=""
    fi
  fi
  mkdir -p "$MANUAL_DIR"; rm -f "$DEFER_DIR/$sid"   # an explicit handoff replaces a deferred one
  state_set "$key" final_attempts 0; state_set "$key" fix_attempts 0; state_set "$key" t3_clear ""
  rm -f "$HANDOFF_DIR/state/$sid.manual-note.txt"
  [ -n "$MP_NOTE" ] && printf '%s\n\n%s\n' "The user wrote this note when they handed the previous context off (/handoff:now); take it into account before the document's Next steps:" "$MP_NOTE" > "$HANDOFF_DIR/state/$sid.manual-note.txt"
  jq -nc --argjson at "$(now)" --arg m "$m" --arg e "$e" --arg n "$MP_NOTE" '{at:$at, model:$m, effort:$e, note:$n}' > "$MANUAL_DIR/$sid.json"
  desc="$(manual_desc "$sid")"
  log manual "armed sid=$sid$desc${MP_NOTE:+ note=${#MP_NOTE} chars}"
  if [ -s "$doc" ]; then what="Rewrite the handoff document $doc with the Write tool (it exists from earlier: overwrite it even if it looks current) so every section reflects the current state; Standing instructions and Decisions log are append-only."
  else what="Write the handoff document with the Write tool to $doc."; fi
  local on="" nt=""
  [ -n "$desc" ] && { on="${desc# (}"; on=", to continue with ${on%)}"; }
  [ -n "$MP_NOTE" ] && nt=" The user's note for the next context (the plugin passes it on too; reflect it in Next steps): <note>${MP_NOTE}</note>."
  req="The user asked to hand this conversation off now (/handoff:now)${on}: it continues in a fresh context that sees only the repo and a handoff document. Do not continue the task in this context.${nt} ${what} ${SECTIONS} Then stop."
  local shown=""; [ -n "$MP_NOTE" ] && { shown="$(printf '%s' "$MP_NOTE" | tr '\n' ' ' | cut -c1-80)"; [ ${#MP_NOTE} -gt 80 ] && shown="$shown…"; shown=" Note for the next context: \"$shown\"."; }
  jq -nc --arg m "Handoff plugin: manual handoff armed${desc}.${shown} Claude writes the handoff document in this turn, then $( [ "$(cfg T3_AUTOCLEAR false)" = true ] && echo "the thread continues in a fresh session" || echo "type /clear, then /handoff:resume").${warn}" --arg c "$req" \
    '{systemMessage:$m, hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
}
