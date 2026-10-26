#!/bin/bash
# T3 Code layer (opt-in: T3_AUTOCLEAR=true). The base plugin works anywhere: hooks write and stage the handoff and
# the user types /clear + /handoff:resume. Under T3 Code this helper drives the same /clear + /handoff:resume with
# t3ctl, inside the same thread, and keeps T3's view of the thread pointed at the live Claude session:
#
#   check [sid]            preflight (+ thread resolution with a sid); prints "ok: …" or the reason, exit 0/1.
#   nudge <file>           send the handoff-writing request to this thread as its OWN turn (T3 shows only a turn's
#                          last assistant message; an in-turn nudge would hide the real reply behind "Worked for …").
#   clear <doc>            once the handoff is staged: when the thread is idle, send "/clear", wait for the new
#                          session (SessionStart(clear) + alias), then send "/handoff:resume".
#   alias <old sid>        (SessionStart(clear), sid = the new session) point the Claude session id T3 resumes for
#                          this thread at the new session's transcript (see below). Local only: db + files.
#   recover <prompt-file>  (UserPromptSubmit of a tombstoned session that T3 resumed: a /clear before 0.6 or a
#                          failed alias) stage the newest handoff of its /clear chain with a digest of the later
#                          transcripts inlined, then /clear + /handoff:resume as above with the prompt.
#
# The alias. T3 Code (Beta) 0.1.x records a thread's Claude session id once (statev2.sqlite,
# payload_json.nativeThreadRef.nativeId = R) and ignores the new id a /clear mints; whenever it respawns the process
# (idle reap, app restart) it runs `resume: R`. So after each /clear, R's transcript <R>.jsonl becomes a symlink to
# the new session's transcript (the original is kept as <R>.jsonl.pre-handoff): a respawn loads the live context,
# appends through the link, and keeps reporting id R, which is what T3 expects. Plugin state and handoff docs of the
# post-/clear sessions are keyed by R (state/aliased-by/<sid>), so they carry over such a respawn. Checked first:
# T3 pins no conversation head for the thread (resumeSessionAt would name a message the link hides), <R>.jsonl is in
# the same transcript dir as the new session (same project), and R is not already the new session (a T3 that follows
# /clear itself needs no alias).
#
# Requires T3 Code (Beta) >= 0.1.0 (state db ~/.t3/userdata/statev2.sqlite, read-only) and t3ctl. Every failure
# is logged ([t3] in hooks.log) and printed; nothing is sent or linked then.
# Guards: host is T3 Code; t3ctl/sqlite3 present; db, table, columns and payload shape as expected; server reachable,
# supported, >= MIN_T3 (not for alias: local only); thread resolved by exact Claude session id
# (nativeThreadRef.nativeId), via the alias map, or via our /clear tombstone chain; the thread's workspace is this
# project dir; the mapping is re-checked right before every send.
# Usage: t3.sh <project root> <hooks.log> <claude session id> <mode> [arg]
#        HANDOFF_T3_DRYRUN=1: resolve and print only. HANDOFF_T3_DB: db path override. HANDOFF_T3_SEND_TIMEOUT (600).
#        HANDOFF_TRANSCRIPT: transcript path of <session id> (alias, recover). HANDOFF_T3_CLEAR_WAIT: seconds to wait
#        for the new session after /clear (30).

T3DB="${HANDOFF_T3_DB:-$HOME/.t3/userdata/statev2.sqlite}"
LEGACY_DB="$HOME/.t3/userdata/state.sqlite"
MIN_T3="0.1.0"
SEND_TIMEOUT="${HANDOFF_T3_SEND_TIMEOUT:-600}"
V2T=orchestration_v2_projection_provider_threads
NEED="T3 automation needs T3 Code (Beta) >= $MIN_T3 (state db statev2.sqlite)"

t3() { T3CTL_AGENT=1 t3ctl "$@"; }
# foreground reads run inside hook timeouts: cap each at 5 s (perl ships with macOS)
t3json() { T3CTL_AGENT=1 perl -e 'alarm shift; exec @ARGV' 5 t3ctl "$@" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'; }
DBERR="$(mktemp -t handoff-t3db)"; trap 'rm -f "$DBERR"' EXIT
q() { sqlite3 -readonly -cmd ".timeout 2000" "$T3DB" "$1" 2>"$DBERR"; }
dberr() { head -1 "$DBERR" 2>/dev/null; }
oneline() { tr -d '\n' | cut -c1-240; }
# Claude session id T3 has on record for a thread (empty when none or on a db error; see $DBERR)
session_of_thread() { q "select json_extract(payload_json,'\$.nativeThreadRef.nativeId') from $V2T where thread_id='$1' order by updated_at desc limit 1"; }
thread_json() { t3json threads list -i "$1" | jq -c '.[0] // empty' 2>/dev/null; }

# plugin state (tombstones, logs) lives in the project's .claude/handoff; reuse the hook library for it
ROOT="$1"; LOG_ARG="$2"
export CLAUDE_PROJECT_DIR="$ROOT"
# shellcheck disable=SC1091
source "$(dirname "$0")/handoff-lib.sh"
[ -n "$LOG_ARG" ] && LOG="$LOG_ARG"
SID="${3:-}"; MODE="${4:-}"; ARG="$5"
say() { echo "$(date +%T) [t3] $*" >> "$LOG"; echo "$*"; }
logq() { echo "$(date +%T) [t3] $*" >> "$LOG"; }

# ---- background worker: t3.sh <root> <log> <msid> --bg <nudge|clear> <tid> <file> [live sid]
# msid = the session id T3 maps the thread to (re-checked before every send); live sid = the session running the
# hooks. clear: <file> = /handoff:resume arguments (may be empty).
if [ "$MODE" = "--bg" ]; then
  BMODE="$5"; TID="$6"; FILE="$7"; LIVE="${8:-$SID}"
  OUTCOME="$HANDOFF_DIR/state/$LIVE.t3clear"
  deadline=$(( $(date +%s) + SEND_TIMEOUT ))
  # send_when_idle <what> <text-file>: wait for idle, re-check the mapping, send; retry while busy. 0 = sent.
  send_when_idle() {
    local out left now
    while :; do
      left=$(( deadline - $(date +%s) )); [ "$left" -gt 0 ] || { logq "gave up after ${SEND_TIMEOUT}s: thread $TID never idle long enough ($1)"; return 1; }
      out="$(t3 threads wait "$TID" --timeout "$left" 2>&1)" || logq "t3ctl threads wait $TID failed (rc=$?): $(printf '%s' "$out" | oneline)"
      now="$(session_of_thread "$TID")"
      if [ -z "$now" ]; then
        if [ -s "$DBERR" ]; then logq "cannot read T3 db $T3DB ($(dberr)); $1 NOT sent"; else logq "thread $TID has no Claude session in the T3 db anymore; $1 NOT sent"; fi
        return 1
      fi
      [ "$now" = "$SID" ] || { logq "thread $TID now maps to session '$now', not $SID; $1 NOT sent"; return 1; }
      out="$(t3 threads send "$TID" --stdin < "$2" 2>&1)" && return 0
      logq "$1 to $TID failed (thread busy?): $(printf '%s' "$out" | oneline); retrying after the next idle"
      sleep 5
    done
  }
  case "$BMODE" in
    nudge)
      send_when_idle "handoff nudge" "$FILE" && logq "sent handoff nudge turn to $TID"; exit 0 ;;
    clear)
      fail() { echo "failed:$1" > "$OUTCOME"; logq "handoff of $TID failed: $1; type /clear, then /handoff:resume"; exit 0; }
      C="$HANDOFF_DIR/state/$LIVE.clear-cmd.txt"; printf '/clear' > "$C"
      MARK="$HANDOFF_DIR/state/cleared/$LIVE"; rm -f "$MARK"
      send_when_idle "/clear" "$C" || fail "/clear not sent (see hooks.log)"
      logq "sent /clear to $TID"
      # SessionStart(clear) writes state/cleared/<live sid> = new sid (after the alias step)
      i=0; while [ ! -s "$MARK" ] && [ $i -lt $(( ${HANDOFF_T3_CLEAR_WAIT:-30} * 2 )) ]; do sleep 0.5; i=$((i+1)); done
      [ -s "$MARK" ] || fail "no new session observed after /clear"
      NEW="$(cat "$MARK")"
      if [ "$(cat "$HANDOFF_DIR/state/aliases/$SID" 2>/dev/null)" = "$NEW" ]; then logq "session $SID (T3's) now follows $NEW"
      else logq "WARNING: session $SID (T3's) is NOT aliased to $NEW (see the alias line above); a T3 respawn would resume the pre-clear context"; fi
      Rf="$HANDOFF_DIR/state/$LIVE.resume-cmd.txt"
      { printf '/handoff:resume'; [ -s "$FILE" ] && { printf ' '; cat "$FILE"; }; } > "$Rf"
      send_when_idle "/handoff:resume" "$Rf" || fail "/handoff:resume not sent after the /clear"
      echo "done:$NEW" > "$OUTCOME"; logq "sent /handoff:resume to $TID: handoff to session $NEW complete"; exit 0 ;;
  esac
  exit 0
fi

# ---- foreground
skip() { if [ "$MODE" = "check" ]; then say "$1"; exit 1; fi; say "$1; $MODE skipped"; exit 0; }
case "$MODE" in check|nudge|clear|alias|recover) ;; *) say "unknown mode '$MODE'; skipped"; exit 0;; esac
case "$MODE" in nudge|clear|recover) [ -s "$ARG" ] || { say "$MODE: file '$ARG' missing or empty; skipped"; exit 0; };; esac
[ "$MODE" = "alias" ] && [ -z "$ARG" ] && { say "alias: no pre-clear session id; skipped"; exit 0; }

is_t3_host() {
  [ "$__CFBundleIdentifier" = "com.t3tools.t3code" ] && return 0
  local p=$PPID i=0
  while [ $i -lt 6 ] && [ "${p:-0}" -gt 1 ]; do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in *"T3 Code"*|*t3code*|*t3-code*) return 0;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i+1))
  done
  return 1
}
thread_for_session() { q "select thread_id from $V2T where json_extract(payload_json,'\$.nativeThreadRef.nativeId')='$1' order by updated_at desc limit 1"; }
predecessor_of() {
  local f; f="$(grep -l "\"continued_by\" *: *\"$1\"" "$HANDOFF_DIR/state/tombstones/"*.json 2>/dev/null | head -1)"
  [ -n "$f" ] && basename "$f" .json
}
version_ge() { [ "$(printf '%s\n%s\n' "${2%%-*}" "${1%%-*}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "${2%%-*}" ]; }
realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# 1. preflight
is_t3_host || skip "not a T3 Code session (host guard), handoff stays manual"
command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not on PATH"
if [ ! -e "$T3DB" ]; then
  [ -z "$HANDOFF_T3_DB" ] && [ -e "$LEGACY_DB" ] && skip "only the legacy T3 db $LEGACY_DB exists, no statev2.sqlite: T3 Code too old; $NEED"
  skip "T3 state db $T3DB not found; $NEED"
fi
[ -r "$T3DB" ] || skip "T3 state db $T3DB not readable"
COLS="$(q "select group_concat(name) from pragma_table_info('$V2T')")" || skip "cannot read T3 db $T3DB ($(dberr))"
[ -n "$COLS" ] || skip "T3 db $(basename "$T3DB") has no table $V2T (T3 Code db layout changed?); $NEED"
for c in thread_id updated_at payload_json; do
  case ",$COLS," in *",$c,"*) ;; *) skip "T3 db table $V2T lacks column $c (T3 Code db layout changed?)";; esac
done
VER="(not asked)"
if [ "$MODE" != "alias" ]; then
  command -v t3ctl >/dev/null 2>&1 || skip "t3ctl not on PATH (install: https://github.com/samzilverberg/t3ctl)"
  ENV="$(t3json env)"
  VER="$(jq -r '.serverVersion // empty' <<<"$ENV" 2>/dev/null)"
  [ -n "$VER" ] || skip "T3 Code server not reachable via t3ctl within 5 s ($(jq -r '.error.code // .error.message // empty' <<<"$ENV" 2>/dev/null || true)); is T3 Code running?"
  [ "$(jq -r '.supported' <<<"$ENV" 2>/dev/null)" = "false" ] && skip "T3 Code server $VER is not supported by this t3ctl (update t3ctl or T3 Code)"
  version_ge "$VER" "$MIN_T3" || skip "T3 Code server $VER < $MIN_T3; $NEED"
fi

if [ "$MODE" = "check" ] && [ -z "$SID" ]; then say "ok: T3 Code $VER, $(basename "$T3DB") readable, t3ctl ready"; exit 0; fi

# 2. thread resolution (alias: of the pre-clear session)
[ -n "$SID" ] || skip "no Claude session id"
LOOK="$SID"; [ "$MODE" = "alias" ] && LOOK="$ARG"
TID="$(thread_for_session "$LOOK")"; HOW="session id"; MSID="$LOOK"
[ -s "$DBERR" ] && skip "cannot read T3 db $T3DB ($(dberr))"
# a post-/clear session the T3 layer aliased: T3 knows it as the aliased id
if [ -z "$TID" ]; then
  K="$(session_key "$LOOK")"
  [ "$K" != "$LOOK" ] && { TID="$(thread_for_session "$K")"; [ -n "$TID" ] && { MSID="$K"; HOW="alias of $K"; }; }
fi
# sessions /cleared without an alias (plugin <= 0.5, alias failed): follow our /clear chain back (bounded)
hops=0; cur="$LOOK"
while [ -z "$TID" ] && [ $hops -lt 20 ]; do
  cur="$(predecessor_of "$cur")"; [ -n "$cur" ] || break
  hops=$((hops+1)); TID="$(thread_for_session "$cur")"
  [ -n "$TID" ] && { MSID="$cur"; HOW="pre-clear ancestor $cur, $hops /clear(s) back"; }
done
if [ -z "$TID" ]; then
  N="$(q "select count(*) from $V2T")"; K="$(q "select count(*) from $V2T where json_extract(payload_json,'\$.nativeThreadRef.nativeId') is not null")"
  [ "${N:-0}" -gt 0 ] && [ "${K:-0}" -eq 0 ] && skip "T3 db rows carry no payload_json.nativeThreadRef.nativeId (T3 Code db layout changed?)"
  skip "session $LOOK (and its pre-clear ancestors) not found in T3 state db $(basename "$T3DB")"
fi

# ---- alias: local only (runs inside SessionStart's 10 s)
if [ "$MODE" = "alias" ]; then
  R="$MSID"; NEWT="$HANDOFF_TRANSCRIPT"
  [ "$R" = "$SID" ] && { say "T3 already records the new session $SID for thread $TID; no alias needed"; exit 0; }
  HEAD="$(q "select json_extract(payload_json,'\$.nativeConversationHeadRef') from $V2T where thread_id='$TID' order by updated_at desc limit 1")"
  [ -n "$HEAD" ] && skip "T3 pins a conversation head for thread $TID ($HEAD): resuming at it through an alias is unsafe"
  [ -n "$NEWT" ] || skip "no transcript path for the new session $SID"
  TD="$(dirname "$NEWT")"; RF="$TD/$R.jsonl"
  [ "$(basename "$NEWT")" = "$SID.jsonl" ] || skip "transcript $NEWT is not named after session $SID (Claude Code layout changed?)"
  [ -e "$RF" ] || [ -L "$RF" ] || skip "T3's session transcript $RF not found (thread $TID runs elsewhere?)"
  if [ -n "$HANDOFF_T3_DRYRUN" ]; then say "alias $R -> $SID for thread $TID (dry run)"; exit 0; fi
  if [ ! -L "$RF" ]; then
    KEEP="$RF.pre-handoff"; [ -e "$KEEP" ] && KEEP="$RF.pre-handoff-$(now)"
    mv "$RF" "$KEEP" || skip "cannot move $RF aside"
  fi
  ln -sfn "$SID.jsonl" "$RF" || skip "cannot link $RF"
  mkdir -p "$HANDOFF_DIR/state/aliases" "$HANDOFF_DIR/state/aliased-by" "$HANDOFF_DIR/state/tombstones/aliased" "$HANDOFF_DIR/sessions/archive"
  echo "$SID" > "$HANDOFF_DIR/state/aliases/$R"; echo "$R" > "$HANDOFF_DIR/state/aliased-by/$SID"
  # R is live again (as the new context); its per-window state and the consumed handoff start over
  [ -f "$(tombstone_file "$R")" ] && mv "$(tombstone_file "$R")" "$HANDOFF_DIR/state/tombstones/aliased/$R.json"
  rm -f "$HANDOFF_DIR/state/$R.json"
  [ -f "$HANDOFF_DIR/sessions/$R.md" ] && mv "$HANDOFF_DIR/sessions/$R.md" "$HANDOFF_DIR/sessions/archive/$R-$(now).md"
  say "aliased T3's session $R (thread $TID, matched by $HOW) -> $SID: a T3 respawn resumes the new context"
  exit 0
fi

TJ="$(thread_json "$TID")"
ST="$(jq -r '.status // empty' <<<"$TJ" 2>/dev/null)"
case "$ST" in
  "")       skip "could not read thread $TID via t3ctl" ;;
  missing)  skip "T3 db maps session to thread $TID but T3 Code does not know that thread (deleted?)" ;;
  archived) skip "thread $TID is archived" ;;
esac
# the thread must run in this project dir: its worktree, or (local threads) its project's workspace root
WT="$(jq -r '.worktreePath // empty' <<<"$TJ")"
if [ -z "$WT" ]; then PID_="$(jq -r '.projectId // empty' <<<"$TJ")"; WT="$(t3json projects | jq -r --arg p "$PID_" '.[] | select(.id==$p) | .workspaceRoot' 2>/dev/null)"; fi
[ -n "$WT" ] && [ "$(realdir "$WT")" != "$(realdir "$ROOT")" ] && skip "thread $TID works in $WT, not in this project dir $ROOT"
[ "$MODE" = "check" ] && { say "ok: T3 Code $VER; session $SID -> thread $TID ($ST, matched by $HOW)"; exit 0; }

bg() { nohup bash "$0" "$ROOT" "$LOG" "$MSID" --bg "$@" >/dev/null 2>&1 & disown 2>/dev/null || true; }

case "$MODE" in
  nudge)
    say "nudge scheduled for thread $TID (matched by $HOW, session $SID)"
    [ -n "$HANDOFF_T3_DRYRUN" ] && exit 0
    bg nudge "$TID" "$ARG" ;;

  clear)
    say "handoff (/clear, then /handoff:resume) scheduled for thread $TID (matched by $HOW, session $SID)"
    [ -n "$HANDOFF_T3_DRYRUN" ] && exit 0
    echo "pending" > "$HANDOFF_DIR/state/$SID.t3clear"
    bg clear "$TID" "" "$SID" ;;

  recover)
    # Tombstoned session resumed by T3: chain SID -> continued_by -> … -> tail. Stage the newest handoff doc of the
    # chain, with a digest of everything the later sessions said after it inlined, as THIS session's handoff, then
    # /clear + /handoff:resume (the /clear aliases T3's session to the fresh one).
    CHAIN=("$SID"); cur="$SID"; i=0
    while [ $i -lt 20 ]; do nx="$(tombstone_get "$cur" continued_by)"; [ -n "$nx" ] || break; CHAIN+=("$nx"); cur="$nx"; i=$((i+1)); done
    TAIL="${CHAIN[${#CHAIN[@]}-1]}"
    DOC=""; DOCI=-1
    for ((k=${#CHAIN[@]}-1; k>=0; k--)); do
      for d in "$HANDOFF_DIR/sessions/${CHAIN[$k]}.md" "$HANDOFF_DIR/sessions/$(session_key "${CHAIN[$k]}").md"; do
        [ -s "$d" ] && { DOC="$d"; DOCI=$k; break 2; }
      done
    done
    TDIR="$(dirname "${HANDOFF_TRANSCRIPT:-/nonexistent/x}")"
    SINCE="1970-01-01T00:00:00Z"; [ -n "$DOC" ] && SINCE="$(date -u -r "$(mtime "$DOC")" +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$HANDOFF_DIR/recovery"; DIG="$HANDOFF_DIR/recovery/$SID-digest.md"
    { printf '# Transcript digest after the last handoff document\n\nSessions (oldest first) after %s. User messages and assistant text only, long entries cut.\n' "$SINCE"
      for ((k=(DOCI<0?0:DOCI); k<${#CHAIN[@]}; k++)); do
        tf="$TDIR/${CHAIN[$k]}.jsonl"; [ -f "$tf" ] || continue
        printf '\n## Session %s\n\n' "${CHAIN[$k]}"
        jq -r --arg s "$SINCE" 'select((.type=="user" or .type=="assistant") and (.timestamp // "") > $s and (.isMeta|not)) | .message as $m
          | (if ($m.content|type)=="string" then $m.content else ([$m.content[]? | select(.type=="text") | .text] | join("\n")) end) as $t
          | select(($t|length) > 0 and ($t|startswith("<")|not))
          | "- **\(.type)** \(.timestamp[0:16]): \($t | gsub("\n+"; " ") | .[0:600])"' "$tf" 2>/dev/null | tail -n 80
      done; } > "$DIG"
    if [ -n "$HANDOFF_T3_DRYRUN" ]; then say "recover thread $TID from ${DOC:-no doc} + digest $DIG (dry run)"; exit 0; fi
    REC="$HANDOFF_DIR/sessions/$(session_key "$SID").md"
    { printf -- '---\nsession: %s\nreason: t3-recovery (chain %s)\nwritten: %s\n---\n\n' "$SID" "${CHAIN[*]}" "$(date -Iseconds)"
      printf '> Recovery note: T3 Code resumed this thread on a stale Claude session (%s) that had been /cleared; the work went on in later sessions (newest: %s). Below is the newest handoff document of that chain. The section "Transcript after this handoff" at the end holds what the user and the assistant said after it (newer than everything above it): re-check anything it reports as in progress.\n\n' "$SID" "$TAIL"
      if [ -n "$DOC" ]; then awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{f=0;next} !f' "$DOC" | sed '/./,$!d'
      else printf '# Handoff\n\nNo handoff document was written in the chain. Rebuild the state from the transcript below and the repo.\n'; fi
      # inlined (not just referenced): a resumed model does not reliably open a second file. Capped; full copy in $DIG
      printf '\n## Transcript after this handoff (digest, newest last; full copy: %s)\n\n' "$DIG"
      sed '1,/^Sessions (oldest first)/d' "$DIG" | tail -n 120; } > "$REC.tmp" && mv "$REC.tmp" "$REC"
    publish "$REC"
    A="$HANDOFF_DIR/state/$SID.resume-args.txt"
    { printf 'This thread was just recovered by the handoff plugin: the earlier "STOP — stale session resume" note no longer applies. Before the Next steps, handle this message the user sent while the recovery ran:\n\n'; cat "$ARG"; } > "$A"
    echo "pending" > "$HANDOFF_DIR/state/$SID.t3clear"
    say "recovering thread $TID from ${DOC:-no doc} + digest $DIG (/clear, then /handoff:resume with the user's message)"
    bg clear "$TID" "$A" "$SID"
    echo "RECOVERING" ;;
esac
exit 0
