# handoff — Claude Code plugin: end-of-turn handoff → /clear → resume

Auto-compact fires mid-turn and its summary drops decisions. This plugin instead acts **at the end of the turn**
that crosses a context threshold: Claude writes a structured handoff document itself, the plugin stages it,
**you type `/clear`**, and the fresh context resumes from it via `/handoff:resume`. Under T3 Code an optional layer
(`T3_AUTOCLEAR`) does it for you, in the same thread: on T3 Code >= 0.1.9 it sends `/handoff:resume` as a fresh session (T3's own `/clear`), on older T3 it types `/clear` + `/handoff:resume` and keeps T3 pointed at the live session. Running `/handoff:resume` without `/clear` just adds the document on top of the full context. Auto-compact stays on only as a safeguard far above the
threshold. Verified against Claude Code 2.1.263 with 18 driven test sessions plus real long sessions.

**Manual handoff** (since 0.11): `/handoff:now [model] [effort] [note]` hands off right away, below the threshold;
under T3 Code it can continue the same thread on another model or effort. See [Manual handoff](#manual-handoff-handoffnow).

**OpenAI Codex** is supported too (since 0.8, same plugin dir, separate hooks): Codex writes the same document at the
threshold, and under T3 Code the thread continues from it in a fresh Codex session automatically. See
[Codex](#codex-openai).

```
turn ends ─Stop hook─▶ ctx ≥ THRESHOLD?  (never mid-turn)
   │  no handoff yet  → Claude is asked to write .claude/handoff/sessions/<sid>.md, then stop
   │  file incomplete → one more ask naming the missing sections (max 2)
   │  file complete   → staged as current.md + by-pid/<claude pid>.md; notice: "Type /clear"
   │  user keeps going → after LIVE_EVERY more tokens, Claude is asked to refresh the document (stale handoffs are never restaged)
/clear ─SessionEnd(clear)─▶ stage (or generate from transcript if Claude never wrote one)
       ─SessionStart(clear)─▶ runs before CLAUDE.md is read; ensures current.md is THIS process's;
                              tells Claude to invoke /handoff:resume (unless CLAUDE.md imports the file)
/handoff:resume ─▶ handoff enters the new context as part of the user turn (trusted channel)
optional LIVE_FROM ─▶ from that size on, Claude keeps the same file updated every LIVE_EVERY tokens
safeguard: auto-compact window ≈ THRESHOLD + 100k; PreCompact stages a handoff if it fires anyway
```

## Requirements

* macOS (the hooks use BSD `stat`/`ps`; they disable themselves with a notice on other OSes)
* Claude Code ≥ 2.1.263, `bash`, `jq`
* Optional, only for the T3 layer (`T3_AUTOCLEAR`): [T3 Code](https://github.com/pingdotgg/t3code) **(Beta) >= 0.1.0**, i.e. the release whose state db is `~/.t3/userdata/statev2.sqlite` (older T3 with only `state.sqlite` is refused with a message, no fallback), [`t3ctl`](https://github.com/samzilverberg/t3ctl) on PATH, and `sqlite3` (ships with macOS). The fresh-session flow needs T3 Code >= 0.1.9 (capability `freshContext`) and t3ctl >= 0.8.0 (`threads send --fresh`); without them the layer uses the `/clear` flow, with the session alias on T3 Code < 0.1.10 (0.1.10 follows a Claude-side `/clear` itself, [#35054](https://github.com/pingdotgg/t3code/pull/35054))

## Install

```
claude plugin marketplace add samzilverberg/claude-handoff
claude plugin install handoff@claude-handoff -s user
claude plugin install handoff@claude-handoff -s user --config THRESHOLD=300000 --config LIVE_FROM=0   # or /plugin configure handoff@claude-handoff in a session
/autocompact 400k                              # safeguard ~100k above the threshold; persistent: "autoCompactWindow": 400000 in ~/.claude/settings.json (T3 Code: "Auto-compact after")
```

From a local clone instead: `claude plugin marketplace add /path/to/claude-handoff`. Quick try without installing:
`claude --plugin-dir /path/to/claude-handoff/plugins/handoff`. Upgrade: `claude plugin marketplace update claude-handoff`
then `claude plugin update handoff@claude-handoff`, and restart the session.

Per project (optional): `/handoff:setup` creates `.claude/handoff/` and gitignores it; `/handoff:setup --import`
also adds a CLAUDE.md `@.claude/handoff/current.md` import so the handoff loads with zero keystrokes after
`/clear` (see "Channels" for the trade-off). Without setup the hooks create the directory on first use.

## Configuration

Precedence: `HANDOFF_<KEY>` env var (session override) > plugin userConfig (`/plugin configure handoff@claude-handoff`,
exported to hooks as `CLAUDE_PLUGIN_OPTION_<KEY>`) > built-in default:

| Key | Default | Meaning |
| --- | --- | --- |
| `THRESHOLD` | 300000 | Context tokens at end of turn that trigger the final handoff. 0 = off |
| `LIVE_FROM` | 0 (off) | From this context size on, keep a running handoff updated at turn ends. Suggested 150000 or THRESHOLD − 100k |
| `LIVE_EVERY` | 20000 | Re-update the running handoff only after the context grew by this many tokens |
| `MODE` | inject | PreCompact safeguard: `inject` stages a handoff and lets compaction run; `block` refuses proactive auto-compact and asks for `/clear` |
| `MODEL` / `EFFORT` | claude-opus-4-8 / medium | Nested `claude -p` summarizer, used only when Claude did not write the handoff itself |
| `MAX_DOC_CHARS` | 200000 | Size limit of the handoff document (characters, ~50k tokens). Above it Claude is asked to condense it before staging (see "Checks before staging"). 0 = no limit |
| `MAX_DOC_SHARE` | 25 | Lowers the size limit to this percent of `THRESHOLD` (tokens, ~4 characters each) when that is below `MAX_DOC_CHARS`: a 300k threshold keeps 200000 characters, a 40k one allows 40000. A fresh session starts at base context + document, so the document must leave it room to work. 0 = off |
| `LOOP_GUARD` | true | A session whose first turn ends at or above `THRESHOLD` hands off only after growing by `LIVE_EVERY` (see "Loop protection"). `false` = off |
| `STARTUP` | ignore | Fresh startup that finds another live session's staged handoff: `ignore` (inject a "not yours" note) or `adopt` |
| `T3_AUTOCLEAR` | false | T3 layer, inside a T3 Code thread only (see "T3 Code"). The handoff-writing request goes to the thread as its own turn; once the handoff is staged the plugin continues **the same thread** in a fresh Claude session: T3 Code >= 0.1.9 gets one `/handoff:resume` sent as a fresh session (T3 records the new session itself); older T3 gets `/clear` + `/handoff:resume`, with the Claude session id T3 resumes aliased to the new session (so a T3 respawn cannot bring back the pre-clear context). `HANDOFF_T3_FRESH=false` (env) forces the older flow. Threads `/clear`ed by plugin <= 0.5 are recovered on their next message. Requires T3 Code (Beta) >= 0.1.0 and t3ctl. Off, or wherever the preflight fails: the base `/clear` + `/handoff:resume` path |
| `T3_NUDGE_TURN` | true | With `T3_AUTOCLEAR`: `true` sends the handoff-writing request as its own turn; `false` uses the in-turn Stop nudge (the automatic /clear still runs). Flip it to compare while testing |
| `T3_DEFER` | off | With `T3_AUTOCLEAR`: when the handoff runs. `off`: right after the turn that crosses the threshold. `resume`: the document is written then, the fresh session waits for your next message. `all`: nothing at the turn end, your next message starts it. See "Deferred handoff". Experimental |
| `T3_SEND_TIMEOUT` | 600 | Seconds the T3 helper waits for the thread to go idle (and retries a send refused because the thread was busy) |

Per project, a `KEY=VALUE` file `.claude/handoff/handoff.conf` (`#` comments) overrides the userConfig (env still wins);
handy to try a setting in one project, e.g. `T3_DEFER=all`.

Skills: `/handoff:resume [extra instructions]`, `/handoff:status`, `/handoff:setup [--import]`.

## The handoff document

Both the in-context nudge (primary) and the transcript summarizer (fallback) ask for the same nine sections, in
this order. The Stop hook checks the headers are present before staging (one retry naming what is missing).

| Section | Content |
| --- | --- |
| Goal | the user's actual ask, their words where possible |
| **Standing instructions from the user** | every steering directive the user gave, in order, near-verbatim: scope limits, "do not X", "always Y", style/format preferences, process rules, corrections. Each tagged `[active]`, `[superseded by #n]` or `[withdrawn]`. Entries are never dropped, only re-tagged, so the successor sees the history |
| **Decisions log** | each significant decision: what, who decided (user/assistant), why, `[active]` or `[reversed by #n]` |
| Current state | done, and how it was verified |
| In progress | exact step being executed when the context ended |
| Next steps | ordered, actionable |
| Key files & symbols | path:line, one-line role |
| Gotchas / dead ends | tried and rejected, why |
| Open questions for the user | |

The nudge also says: re-read the user's messages before writing and make sure every directive appears under
Standing instructions. In live mode the two log sections are append-only; other sections are kept under ~100 lines.
The exact prompt text lives in `scripts/handoff-stop.sh` (`SECTIONS`) and `scripts/handoff-lib.sh` (`generate_handoff`).

### Checks before staging, and the workspace stamp

Before a complete document is staged (and, under T3, before the automatic handoff), the Stop hook checks it:

* **Probable secrets**: private keys, `sk-…` API keys, GitHub (`ghp_…`, `github_pat_…`), AWS (`AKIA…`/`ASIA…`), Slack
  (`xox?-…`) and bearer tokens. The request already says not to copy secret values; a hit asks for a redaction naming
  the line.
* **Size** over the limit: `MAX_DOC_CHARS` (200000 characters by default, room for long chains of handoffs), or
  `MAX_DOC_SHARE` percent of `THRESHOLD` (25%, ~4 characters per token) when that is lower. A request to condense,
  keeping Standing instructions, Decisions log and Next steps complete.

Up to two fix requests, then the document is staged anyway with a warning in the Stop message. Exception (Codex under
T3): a document that still has probable secrets is not sent into the thread, since the message would keep them in T3's
db; the Stop message says to redact and resume by hand.

#### Loop protection

A fresh session starts at its base context (system prompt, tools, instructions) plus the handoff document. If that is
already near or over `THRESHOLD`, the first turn would trigger the next handoff, and every session after it the same.
Two guards, for Claude and Codex:

* **Size share**: the document limit shrinks with the threshold (`MAX_DOC_SHARE`, above), so the document leaves most
  of the budget for work. Invisible at the default 300k threshold (200000 characters stays the lower limit).
* **Loop guard** (`LOOP_GUARD`): a session whose first Stop is at or above the threshold does not hand off until it has
  grown by `LIVE_EVERY` (20000 tokens) since then. A session that started below the threshold hands off as usual.

At staging the plugin appends (and on every later staging rewrites) a **Workspace identity** section: directory, git
branch, HEAD commit and uncommitted files (its own `.claude/handoff/` excluded). The resume instructions tell the next
context to compare the repository with it and to tell the user about an unexplained difference before changing
anything. The document request also asks to mark anything in Current state that was not actually checked as
`UNVERIFIED`. (Ideas taken from the `context-handoff` Codex plugin's packet validator and destination sentinel.)

A handoff that goes stale (the user keeps working without the handoff) is refreshed after `LIVE_EVERY` tokens counted
from the **staging** of the current version, not from the request that produced it: writing a large document in a
separate T3 turn can grow the context by more than `LIVE_EVERY` on its own.

## What you will see

```
… Claude ends a turn at 362k …
Stop says: Handoff: context is 362104 tokens (limit 350000). Asking Claude to write the handoff document before it stops.
Claude: [Write .claude/handoff/sessions/<sid>.md] Handoff written.
Stop says: Handoff: context is 363900 tokens (limit 350000). Handoff for this session is written and staged. Type /clear to continue from it in a fresh context.
> /clear
> continue                      (Claude invokes /handoff:resume on its own, or you type it)
```

## Channels for getting the handoff into the new context

| Channel | Trust | Multi-session | Bloat on unrelated startup | Keystrokes |
| --- | --- | --- | --- | --- |
| `/handoff:resume` skill (default) | user turn: accepted in every test | per Claude pid (`by-pid/<pid>.md`), no sharing | none | `/clear` then Claude self-invokes after the session-start note (or you type it) |
| CLAUDE.md `@import` (`/handoff:setup --import`) | user message: accepted in every test | shared `current.md`; owner marker + SessionStart(clear) rewrite keep it correct after `/clear`/compaction; a fresh startup in the same dir still prefetches a neighbour's copy (2–5k tokens) and gets a "not yours" note | yes, a few k tokens | `/clear` only |
| SessionStart stdout injection | system reminder: refused as prompt injection in 3/4 tests | n/a | none | not used |

Plugins cannot ship CLAUDE.md content, which is why the import needs `/handoff:setup --import` per project.

## T3 Code layer: zero-keystroke handoff (`T3_AUTOCLEAR`)

The plugin is two layers. The **base layer** works in any Claude Code host (CLI, desktop, T3): hooks detect the
threshold, Claude writes the handoff, the plugin stages it, the user types `/clear` and `/handoff:resume`. Claude Code
has no API for a hook to clear the context, so outside T3 those two keystrokes stay with the user. The **T3 layer**
(`scripts/t3.sh`, opt-in) replaces the keystrokes when the session runs inside a
[T3 Code](https://github.com/pingdotgg/t3code) thread, using [`t3ctl`](https://github.com/samzilverberg/t3ctl) (a CLI
for the running T3 Code app) and read-only lookups in T3's state db.

Since 0.7 there are two flows. T3 Code (Beta) **0.1.9** added fresh sessions (`freshContext` on a send; the
composer's `/clear` arms it for the next message): T3 starts a new Claude session in the **same thread** and records
its id itself, so the stale-resume problem below cannot happen on that path. The layer uses it when the server
advertises the capability, t3ctl has `threads send --fresh` (>= 0.8.0) and the process knows its thread
(`T3CODE_THREAD_ID`, which T3 exports to its agents); otherwise it falls back to the 0.6 `/clear` + alias flow.
`t3.sh check` (and `/handoff:status`) names the flow and why.

Fresh flow (T3 Code >= 0.1.9):

```
turn ends at ≥ THRESHOLD ─Stop─▶ t3.sh nudge: once the thread is idle, send "[handoff plugin] … write the handoff"
                                  as its own turn (the reply you were reading stays the turn's visible message)
handoff written ─Stop─▶ stage it: by-pid/<pid>.md, current.md, and by-thread/<T3 thread>.md (+ .json: staging session)
                 ─▶ t3.sh clear: once idle, `t3ctl threads send <thread> --fresh "/handoff:resume"`
     T3 detaches the old session: its process ends with SessionEnd(other)
     new process, SessionStart(startup): adopts by-thread/<thread>.md (→ by-pid/<new pid>.md, current.md), tombstones
                                         the old session (continued_by = the new one), archives the per-thread copy
     /handoff:resume loads the doc; the fresh context continues from Next steps. T3 records the new session id, so a
     later respawn runs `--resume <new id>`: no alias, no stale context
```

One nudge worker per session (since 0.10.1): when another turn runs before the nudge goes out (a background task's
notification), the next Stop refreshes the request text instead of queueing a second nudge turn and does not count it
as a second attempt; a nudge still waiting when the handoff gets scheduled is dropped. 0.10.0 could send the duplicate
in the same second as the fresh `/handoff:resume`, so the request re-ran in the session being replaced (thread 569772de).

The same adoption fixes the manual T3 path: composer `/clear` then `/handoff:resume` (or any message: the
SessionStart note asks Claude to load the staged handoff). Before 0.7 the fresh session found nothing: the old
process's `SessionEnd(other)` reset `current.md` and the new pid had no `by-pid` copy, so `/handoff:resume` loaded
"(none)" (reproduced on 0.1.9 with plugin 0.6.0). The adoption only runs on `startup` of a process whose
`T3CODE_THREAD_ID` has a staged doc: plain CLI sessions, other threads and respawns (`resume`) adopt nothing, and a
`/clear` or compact that consumes the doc in-process drops the per-thread copy. T3 refuses a fresh send while the
current session still runs background agents or commands ("… a fresh session would end them"). Since 0.7.2 the
helper then sends the session one normal turn (once per handoff) asking it to stop the background agents, monitors
and commands it no longer needs, or to say which one must finish; it retries the fresh send after each idle until
`T3_SEND_TIMEOUT` and then reports the last refusal, with the fix: stop the background work first (the composer's
`/clear` is refused the same way while it runs). Since 0.10.1 the ask is sent only when it reaches the session whose
background work T3 checks (the thread still routes to the refused session, and T3's active pointer is on it), at most
once per handoff; while T3 refuses, the Stop note shows why the handoff waits ("pending: T3 refuses the fresh session
while …"). When a compact consumes the staged doc before T3 accepts the fresh session, the helper cancels the handoff
instead of retrying (the context is small again).

Which session a thread belongs to. A thread keeps one provider-thread row per Claude session in T3's db. Since 0.10.1
the helper follows T3 0.1.12's own routing of user messages (#38824): the newest session started at or after the
thread's last fresh start (fresh runs started by a scheduled task don't count). The newest `updated_at` row and the
thread's active pointer are not reliable: a replaced session whose process stays alive for background work bumps its
row and takes the pointer back whenever Claude wakes it, and on 0.1.12 its wake runs count toward its row's
`lastRunOrdinal`.

Wakes of a replaced session (since 0.10.1). After a fresh-session handoff, the old Claude process can stay alive while
it has background work (seen on 0.1.11; on 0.1.12 T3 normally ends it, but e.g. a scheduled fresh start leaves it
running). Claude wakes it with a `<task-notification>` prompt whenever such work ends. Its session is tombstoned, so
the UserPromptSubmit hook sees it. If T3 routes the thread to another session (a successor in the session's chain, or
any other), the prompt is blocked (zero tokens; T3 0.1.12 finishes such a wake turn by itself), logged once per 10
minutes (`[userprompt] wake of replaced session …; ignored`), and nothing is sent to the thread: no recovery, no fresh
send, no background-work ask. 0.10.0 ran a recovery for every wake (thread 569772de: seven recoveries, six asks into
the new session). A real message that reaches a replaced process (T3 < 0.1.12 could route one there) is blocked with a
request to resend it.

`/clear` flow (T3 Code 0.1.0 – 0.1.8, `HANDOFF_T3_FRESH=false`, or plain `/clear` text sent through the API, which T3
0.1.9 and 0.1.10 still pass to Claude Code). The alias step in it applies to T3 Code < 0.1.10 only (see below):

```
turn ends at ≥ THRESHOLD ─Stop─▶ t3.sh nudge (as above)
handoff written ─Stop─▶ stage it ─▶ t3.sh clear: once idle, send "/clear" to the same thread
     SessionEnd(clear): stage the handoff, tombstone the cleared session
     SessionStart(clear) ─▶ t3.sh alias: <R>.jsonl (R = the Claude session id T3 recorded for the thread)
                            becomes a symlink to the new session's transcript; original kept as <R>.jsonl.pre-handoff
new session seen ─▶ send "/handoff:resume": the fresh context loads the handoff and continues from Next steps
later, T3 respawns the process (idle reap, app restart, mode change) with `--resume R`
     ─▶ Claude Code reads <R>.jsonl → the live post-/clear context; new turns append through the link, id stays R
```

Why the alias. T3 Code (Beta) 0.1.0 – 0.1.9 records a thread's Claude session id once and ignores the new `session_id` a
`/clear` mints (no T3 command re-points it). `/clear` itself works while the process lives, but whenever T3 respawns the
process it resumes the **pre-clear** id: before the alias, the thread silently returned to the stale context and
everything after the clear was unreachable from T3. Claude Code resolves `--resume <id>` to `<id>.jsonl` in the project's
transcript dir and follows a symlink there, keeping `<id>` as the session id, which is what T3 expects. Plugin state and
the handoff doc of every post-`/clear` session are keyed by R (`state/aliased-by/<sid>`), so they carry over such a
respawn, and the next `/clear` re-points the link. The alias is refused (and logged) when T3 pins a conversation head
for the thread (`nativeConversationHeadRef`, which would name a message the link hides), when `<R>.jsonl` is not in the
new session's transcript dir, or when T3 already records the new session (a T3 that follows `/clear` needs no alias).
Rejected alternatives: `/compact` (keeps the session id, but costs a summarization call over the full context, and its
prompt can only be extended, not replaced, so it cannot write the handoff itself), a successor thread per handoff
(one more sidebar entry each time), writing T3's db (event-sourced, not ours to edit), and
importing the new session into the thread (`thread.create` with `importedNativeThread` opens it as a new session).
Full record (what was tried and measured, how to verify, the exit plan and how it was carried out):
[docs/t3-clear-session-workaround.md](docs/t3-clear-session-workaround.md).

Fixed upstream in T3 Code **0.1.10** ([pingdotgg/t3code#35054](https://github.com/pingdotgg/t3code/pull/35054), closes
[#24152](https://github.com/pingdotgg/t3code/issues/24152); first nightly `0.1.10-nightly.20261112.4603`): when Claude
reports a new `session_id` in `system/init`, T3 records it for the thread (`nativeThreadRef.nativeId`, about a second
after the `/clear`), and the next turn runs in a new process that resumes it. Since 0.7.1 the alias step asks the
server version (`t3ctl env`, 5 s cap) and on >= 0.1.10 makes no alias: it logs `T3 Code <v> (>= 0.1.10) follows
/clear natively; no alias …`, the new session keeps its own id as its key, the cleared session stays tombstoned, and
a background check logs whether T3 recorded the new id. The version decides, not the db: `SessionStart(clear)` runs
before T3 has recorded the new id, so 0.7.0 still aliased on 0.1.10 (harmless, since T3 no longer resumes the old id).
A 0.1.10 nightly before 20261112.4603, another pre-release of 0.1.10, or an unreachable server still gets the alias.
Two more fixes for the `/clear` flow on 0.1.10: the helper follows the id T3 now records (0.7.0 refused to send
`/handoff:resume` because the thread "now maps to" the new session), and because the first turn after the `/clear`
runs in a new process (`SessionStart(resume)` of the new session, and the old process's exit resets `current.md`),
`SessionStart(clear)` keeps a per-session copy of the doc (`by-session/<sid>.md`, T3 only) that the new process adopts;
the first `Stop` drops it. Without it, `/clear` + `/handoff:resume` loaded "(none)" on 0.1.10 (reproduced with 0.7.0).
The follow-up upstream commit `97d9359` (forks, rewinds, and the next turn after `/clear` reusing the live process) is
not in 0.1.10; with it, the per-session copy simply goes unused.

Recovery of threads `/clear`ed by plugin <= 0.5 (or after a failed alias): when T3 resumes such a stale session (T3
still routes the thread to it) and the user types into it, the UserPromptSubmit hook blocks the prompt (0 tokens; T3 shows the reason as a notice),
stages the newest handoff document of the session's `/clear` chain with a digest of the later sessions' user and
assistant text inlined (full digest: `.claude/handoff/recovery/<sid>-digest.md`), and runs the handoff with the
user's message passed to `/handoff:resume`: a fresh session where available (the stale session stays tombstoned),
else `/clear` (which, on T3 < 0.1.10, aliases the stale session to the fresh one) + `/handoff:resume`. Threads already
aliased by 0.6 keep working: their next handoff on 0.1.9+ simply moves them to a fresh session, and the old links and
`.pre-handoff` files stay in place. A `<task-notification>` wake of such a stale session is blocked without a recovery
(it is not the user's message); the next real message recovers the thread.

Requirements: T3 Code (Beta) **>= 0.1.0** (state db `~/.t3/userdata/statev2.sqlite`; older T3 is refused with
"only the legacy T3 db … T3 Code too old") and t3ctl; the fresh flow needs T3 Code >= 0.1.9 and t3ctl >= 0.8.0; from
T3 Code 0.1.10 on, a Claude-side `/clear` needs no alias (T3 follows it itself). Setup: install `t3ctl` per its README
(`pnpm install && pnpm build && pnpm link --global`), then `/plugin configure handoff@claude-handoff` →
`T3_AUTOCLEAR=true`, and set "Auto-compact after" in T3 Code's Claude settings ~100k above `THRESHOLD`.

```
… turn ends at 362k …
Stop says: Handoff: context is 362104 tokens (limit 350000). Asking Claude to write the handoff document before it stops. Delivered as a separate T3 turn so this reply stays visible. nudge scheduled for thread <id> …
> [handoff plugin] The context window is at 362104 tokens … Write the handoff document …      (sent by the helper)
Claude: [Write .claude/handoff/sessions/<sid>.md] Handoff written.
Stop says: Handoff: context is 363900 tokens (limit 350000). Handoff staged; once this turn ends the plugin sends /handoff:resume to this thread in a fresh session (T3 starts a new Claude session in the same thread). …
> /handoff:resume                                     (sent by the helper as a fresh session; Claude continues from Next steps)
(older T3: "> /clear" then "> /handoff:resume", both sent by the helper)
```

Safety and future-proofing. The helper checks every moving part before acting and names the one that is off:
host is T3 Code (`__CFBundleIdentifier=com.t3tools.t3code` or a "T3 Code" ancestor), so CLI / desktop / Cowork /
Superset sessions never touch a thread; `t3ctl` and `sqlite3` on PATH;
`statev2.sqlite` present and readable, table `orchestration_v2_projection_provider_threads` with `thread_id`,
`updated_at`, `payload_json`, rows carrying `payload_json.nativeThreadRef.nativeId`; T3 server reachable via
`t3ctl env` (5 s cap), supported, >= 0.1.0; for the fresh flow also `capabilities.freshContext`, t3ctl >= 0.8.0
and `T3CODE_THREAD_ID` equal to the resolved thread. The thread is resolved by this session's exact Claude session id
(`nativeThreadRef.nativeId`; for sessions `/clear`ed in place, via the plugin's own `/clear` tombstone chain back to
the id T3 recorded); it must exist, not be archived, and work in this project dir (its worktree, or for local
threads its project's workspace root); the mapping is re-checked right before every send, and (`/clear` flow) `/handoff:resume` goes out only after the new session is seen; (fresh flow) the helper waits for the fresh session to adopt the doc and checks that T3 records its id. The alias step runs inside SessionStart: one `t3ctl env` for the server version (5 s cap; unreachable → alias as before), then local only (db read + one symlink). The db is only ever read;
writes go through `t3ctl`. A failed preflight is reported at SessionStart (not first at the threshold), every skip
in the Stop message, every attempt in `hooks.log` (`[t3]`); the base path applies whenever the T3 layer cannot act.

Troubleshooting: `/handoff:status` (or `bash plugins/handoff/scripts/t3.sh <project> /dev/null <session id> check`)
prints `ok: …` or the blocking reason. `HANDOFF_T3_DRYRUN=1` resolves without acting. A failed automatic handoff
is reported in the next Stop message; the manual fallback is `/clear` then `/handoff:resume` (in the T3 composer `/clear`
starts a fresh session on 0.1.9+, which adopts the staged doc; on older T3 the alias still runs on a typed `/clear`).
To undo an alias: replace `<R>.jsonl` with `<R>.jsonl.pre-handoff`.

## Codex (OpenAI)

The same plugin directory is also a Codex plugin (`.codex-plugin/plugin.json`, marketplace `.agents/plugins/marketplace.json`).
Codex loads only `hooks/codex-hooks.json` (Stop, SessionStart, UserPromptSubmit → `scripts/codex-*.sh`); the Claude hooks are untouched.
Verified with Codex CLI 0.171 under T3 Code 0.1.11 (t3ctl 0.8.0): three automatic handoffs in a row in one thread, the
user's directives (a codeword, a style rule) carried through all of them.

```
turn ends ─Stop─▶ ctx (rollout token_count: last input + output) ≥ THRESHOLD (capped at 70% of the model window)?
   │  T3 + T3_AUTOCLEAR: t3.sh nudge sends "[handoff plugin] … write the handoff to .claude/handoff/sessions/<sid>.md"
   │                     as its own turn; elsewhere Stop {"decision":"block","reason":…} (a continuation of the turn)
   │  file incomplete → one more ask naming the missing sections (max 2)
   │  file complete   → T3: `t3ctl threads send <thread> --fresh "<resume note + the document inline>"`; T3 starts a
   │                    new Codex session in the same thread and records it; the old session is tombstoned
   │                    elsewhere: "start a new session (/new) and resume from <file>" (skill: $handoff-resume)
loop guard: a session whose first Stop is at or above the threshold hands off only after growing LIVE_EVERY (a fresh
            session does not bounce straight into the next handoff; see "Loop protection")
SessionStart(compact): Codex compacted anyway → the state restarts and the model is pointed at the session's document
```

Differences from the Claude side, and why:

* **Keyed by Codex session id, no pids.** T3 runs one Codex app-server for all its Codex threads: every hook has the same
  parent pid and there is no `T3CODE_THREAD_ID`. `t3.sh` finds the thread in T3's db by the session id
  (`nativeThreadRef.nativeId`), as it does for Claude.
* **The document travels inline** in the fresh session's first message (a user turn, the trusted channel), so there is
  no `/handoff:resume`, no adoption at SessionStart and no `current.md`/`by-pid` bookkeeping.
* **Fresh flow only.** No `/clear` + alias flow (T3 Code >= 0.1.9 with `freshContext` and t3ctl >= 0.8.0 required for
  the automation; otherwise the Stop message says to start a fresh session by hand).
* **No transcript summarizer fallback** (Codex caps SessionEnd hooks at a few seconds). If Codex auto-compacts first,
  its own summary applies, plus the SessionStart(compact) pointer to the document when one exists.
* Documents live in the project's `.claude/handoff/sessions/`, shared with the Claude side, so `/handoff:setup`'s
  gitignore covers both agents (Codex sessions in T3 scratch threads write under that scratch dir).

Install (local clone; a git source works the same way):

```
codex plugin marketplace add /path/to/claude-handoff
codex plugin add handoff@claude-handoff
python3 /path/to/claude-handoff/plugins/handoff/scripts/codex-trust.py --yes    # after every install/upgrade
```

Codex runs a plugin hook only once it is trusted, and the trust hash covers the plugin's files, so every upgrade needs a
new review: `/hooks` in the Codex TUI, or `codex-trust.py` (lists the handoff hooks; `--yes` records their current
hashes through `codex app-server`). Hooks are loaded when a session starts: running sessions keep the old set.
Upgrade: `codex plugin marketplace upgrade claude-handoff` (git sources), `codex plugin add handoff@claude-handoff`, trust.

Configuration: Codex plugins have no userConfig, so the keys from "Configuration" go in `~/.codex/handoff.conf`
(`KEY=VALUE`, `#` comments; `HANDOFF_CONF` overrides the path), per project in `.claude/handoff/codex.conf`; env
`HANDOFF_<KEY>` still wins. Used: `THRESHOLD`, `LIVE_FROM`, `LIVE_EVERY`, `MAX_DOC_CHARS`, `MAX_DOC_SHARE`, `LOOP_GUARD`, `T3_AUTOCLEAR`, `T3_NUDGE_TURN`, `T3_DEFER`,
`T3_SEND_TIMEOUT`. Per project, `.claude/handoff/codex.conf` then `.claude/handoff/handoff.conf` override the global file. Example:

```
THRESHOLD=300000
T3_AUTOCLEAR=true
```

Codex auto-compacts at about 90% of the model window (seen at 434k of 475k); the 70% cap keeps the handoff ahead of it.
`model_auto_compact_token_limit` in `~/.codex/config.toml` moves Codex's own limit if needed.

## Manual handoff (`/handoff:now`)

Two cases the threshold does not cover: you want to hand off early (a natural break, a long context that is still
under the limit), or you want the rest of the work to run on another model or effort in the same T3 thread (e.g.
Opus/high for the design, Sonnet/medium for the mechanical part) without dragging the whole context along.

```
/handoff:now                                  hand off now, same model and effort
/handoff:now sonnet                           continue on Sonnet (T3 Code + T3_AUTOCLEAR)
/handoff:now opus max                         model and effort
/handoff:now low then run the e2e suite       effort only, plus a note for the next context
/handoff:now -m claudeAgent/claude-fable-5-2 -e high -- high-risk part next   explicit flags; `--` starts the note
```

Arguments: leading tokens are read as an effort (`low` `medium` `high` `xhigh` `max` `ultrathink`; also `lo`, `mid`/`med`,
`hi`, `x-high`, `maximum`, `ultra`), a model (`opus`,
`sonnet`, `haiku`, `fable`, `claude-…`, `<instance>/<model>`) or the flags `-m/--model`, `-e/--effort`; the first other
word, or `--`, starts the note, kept verbatim. A version right after the model joins it (`opus 4.8` = `opus-4.8`).
Models resolve against `t3ctl models` (T3's catalog): your own aliases in `~/.config/t3ctl/config.json`
(`modelAliases`) first, then family and version, then the catalog's aliases and slugs, with `.`/`_` read as `-`:

| You type | Runs on (catalog of 2026-11-27) |
| --- | --- |
| `opus`, `opus high` | newest Opus: `claude-opus-5-5` |
| `opus5`, `opus 5`, `opus-5` | newest Opus 5.x: `claude-opus-5-5` (T3's own alias `opus-5` means 5.0; here a bare major is a series) |
| `opus4`, `opus 4` | newest Opus 4.x: `claude-opus-4-8` |
| `opus 4.8`, `opus-4.8`, `opus4.8`, `claude-opus-4-8` | exactly `claude-opus-4-8` |
| `opus 5.0` | exactly `claude-opus-5` |
| `fable`, `fable5` / `fable 5.1` / `fable 5.0` | `claude-fable-5-2` / `claude-fable-5-1` / `claude-fable-5` |
| `opus 4.9`, `opus3` | blocked: unknown model (the message lists what exists) |

The same rule holds for every family (`sonnet`, `haiku`, …). A number right after the model is always read as its
version: `/handoff:now opus 3 tests left` is blocked as `opus-3`; write `/handoff:now opus -- 3 tests left`. t3ctl's built-in aliases are not used: they lag behind the catalog (t3ctl 0.8.0 maps `opus` to
`claude-opus-4-8`, `sonnet` to `claude-sonnet-4-6`). The resolved `<instance>/<model>` is what gets sent. A user alias
that does not look like a model name needs `-m` (`/handoff:now -m quick`).

What happens:

1. `UserPromptSubmit` sees `/handoff:now`, arms `state/manual/<sid>.json` and gives this turn the writing request
   (document path + sections) as context. With a model or effort under the T3 layer it first checks them with
   `t3ctl models` against the thread's current provider: an unknown model, a model of another provider (the fresh
   session resumes through `/handoff:resume`, a Claude skill) or an effort the model does not offer blocks the
   message (zero tokens, the reason is shown). When the list cannot be read, the values go through unchecked and T3
   checks them at the send. A deferred handoff (`T3_DEFER`) armed for the session is replaced.
2. Claude writes the document in that turn (`/handoff:now` is a skill that tells it to follow the note and stop).
3. The `Stop` hook treats the session as past the threshold, whatever its size: no loop guard, no deferral. A document
   older than the arming does not count (an earlier running copy must be rewritten); otherwise the usual rules hold:
   missing sections asked for (max 2), document checks, staging.
4. T3 layer: `/handoff:resume` goes to the thread in a fresh session with `threads send --fresh -m <model> -e <effort>`
   (older T3: the `/clear` flow, with `-m/-e` on the `/handoff:resume` send), the note as its arguments. T3 keeps the
   model and effort on the thread for later turns. Without the T3 layer: `Type /clear, then /handoff:resume`; a model
   or effort is dropped with a warning (pick them with `/model` after the `/clear`).

Refused while a T3 handoff of the session is already scheduled and pending. Claude only for now (Codex: no
`/handoff:now`). Tests: `tests/manual_test.sh`, plus `tests/t3_test.sh` (N: fresh session with `-m/-e` and the note;
N2: model resolution).

Verified live (2026-11-27, T3 Code 0.1.12, Claude Code 2.1.332, t3ctl 0.8.0): a thread on Opus/high got
`/handoff:now sonnet low then append …`; `UserPromptSubmit` received the raw `/handoff:now …` text and its
`additionalContext` reached the skill's turn (document written in that turn, staged at its Stop, no extra request); the
fresh session ran on `claude-sonnet-5-5` (transcript `message.model`), handled the note, and T3 recorded
`claude-sonnet-5-5`/`low` for the thread: a later plain message (no `-m/-e`) ran on Sonnet/low too (T3 runs table). A
`/handoff:now gpt-6.2-sol` was blocked before any turn (another provider).

## Deferred handoff (`T3_DEFER`, experimental)

By default the T3 handoff runs right after the turn that crosses the threshold, so the reply you want to read is
followed by the handoff turn and the resumed session's first reply. `T3_DEFER` (Claude: userConfig or
`.claude/handoff/handoff.conf`; Codex: `~/.codex/handoff.conf` or the project files) moves it to your next message:

| Value | At the turn end | Your next message |
| --- | --- | --- |
| `off` (default) | handoff request turn, then the fresh session | runs in the fresh session as usual |
| `resume` | handoff request turn (document written) | held; the fresh session starts with the document and your message |
| `all` | nothing (the Stop message says the handoff is due) | held; handoff request turn, then the fresh session with the document and your message |

The message is held by the `UserPromptSubmit` hook (`decision: block`; T3 keeps it in the timeline) and re-sent by the
plugin: Claude gets it as `/handoff:resume` arguments, Codex below the inline document, with a note that it wins over
the document's Next steps. A Stop right after the held message is ignored; the plugin's own messages
(`[handoff plugin] …`, `/handoff:resume …`) are never held. Deferral is armed only when the T3 helper reaches the
thread at that moment; otherwise the handoff runs at once as with `off`. If the handoff cannot finish (no complete
document after 2 requests, automatic handoff skipped, Codex document with probable secrets) the held message is sent
back as a normal message in the current session. Attachments of a held message are not carried over (the hook sees
the text only). Verified live for Codex 0.171 under T3 Code 0.1.11 (`all`).

## Verified facts (hooks reference + 18 driven sessions)

| Fact | Evidence |
| --- | --- |
| **Auto-compact fires mid-turn**, between tool calls | run1/run12 `compact_boundary` inside a turn; binary: summary "generated in the background at the autocompact threshold and swapped in when prompt-too-long fired" |
| `Stop` fires only at end of turn; `additionalContext` makes Claude write the file then stop; `systemMessage` renders as "Stop says: …"; `stop_hook_active` prevents loops | run3/11/12/13/15/17 |
| Claude writes complete handoffs when asked (section check passed first time in every run) | run12/13/15/17 |
| Context at Stop = usage of last assistant message in the transcript | matches driver in every run |
| `/clear` works as a stream-json user message (T3 Code); `SessionEnd(clear)` runs first and Claude Code waits for it | run7 (12 s generator) |
| `SessionStart(clear)` runs **before** CLAUDE.md is re-read; on startup CLAUDE.md is prefetched **before** hooks | run10 |
| Skill `!` commands see `${CLAUDE_PROJECT_DIR}` by substitution, not as a shell var | run15 failed, run17 passed |
| Claude self-invokes `/handoff:resume` after the session-start note; recall complete (ticket, branch, codeword, package manager) | run17 |
| Live mode: file created at first crossing, updated only after `LIVE_EVERY` growth | run16 |
| Hook `$PPID` is the Claude Code process, stable across `/clear` | run9/10/13 |
| `PreCompact` can block proactive auto-compact; nested `claude -p --setting-sources ""` works in hooks | run2/4/5 |
| Auto-compact trigger = `min(pct × window, window − ~45k)`; 200k window ran to 155.8k without compacting | run12/14 |
| Plugin `--plugin-dir` and marketplace install both run the hooks; `CLAUDE_PLUGIN_ROOT` resolves | run15–18 |
| Whole loop ran on the authoring session itself at 462k (nudge → handoff → stage → `/clear` → `/handoff:resume`) and inside two real T3 threads; `T3_AUTOCLEAR` completed the `/clear` + resume without a keystroke | hooks.log of this repo's session; ~/dev hooks.log during the T3 test |
| T3 Code: composer passes provider slash commands that open a message (so `/clear` reaches Claude Code); "Auto-compact after" setting maps to `autoCompactWindow`; thread JSON exposes `worktreePath` for hook→thread mapping | t3code source: composerSlashCommandSearch.ts, ClaudeAdapter.ts, t3ctl output |
| T3 Code (Beta) 0.1.x ignores a mid-process `session_id` change (`/clear`) and resumes the recorded pre-clear id on respawn | ClaudeAdapterV2 in the 0.1.2 server bundle; hooks.log: `SessionStart(resume)` of the pre-clear id hours after `/clear`; `statev2.sqlite` still on the old id |
| Claude Code `--resume A` with `A.jsonl` a symlink to `B.jsonl` loads B's conversation, reports session id A (stream-json `init`), appends through the link, and a later resume follows the mixed chain | `claude -p` (haiku), plain and stream-json, 2026-10-26 |
| T3 layer end to end on T3 Code 0.1.2 (sonnet, threshold 60k): threshold at 73k → nudge turn → handoff → `/clear` → alias → `/handoff:resume` (~2 s for the last three), context 74k → 37k; a fact given after the `/clear`; forced respawn (runtime-mode change: T3 ran `claude --resume=<pre-clear id>`) resumed the post-clear context (39.6k, fact known, no zombie note); a second handoff from the respawned process re-pointed the alias and survived another respawn | throwaway project, 2026-10-26 |
| `UserPromptSubmit` `decision:block` under T3: no model call, run ends idle, reason rendered as a `system_notice` turn item | T3 provider event log + `orchestration_v2_projection_turn_items` |
| T3 Code 0.1.9 fresh session (`message.dispatch` with `freshContext: true`, capability `freshContext`): the old Claude process ends with `SessionEnd(other)`, a new process starts with `SessionStart(startup)` in the same thread (the order of the two varies), T3 adds a provider-thread row whose `nativeThreadRef.nativeId` is the new session id, and a later respawn runs `--resume=<new id>`. T3 exports `T3CODE_THREAD_ID` to the agent process (hooks inherit it). Plain `/clear` text sent through the API still reaches Claude Code's `/clear` | server bundle of 0.1.9 (`runtimeLayer`, `ManagedEndpointRuntime`); hooks.log + statev2.sqlite, 2026-11-12 |
| Plugin 0.6.0 on T3 0.1.9: a fresh `/handoff:resume` loaded "(none)": the old process's `SessionEnd(other)` reset `current.md`, the new pid had no `by-pid` copy; the model answered "Fresh session — no prior work" | throwaway project, 2026-11-12 |
| T3 Code 0.1.10 contains #35054 (`clearedNativeSessions` in `ClaudeAdapterV2`) but not the follow-up `97d9359` (`resetSessionByNativeThread`, `toProcessThread` absent) | `app.asar` server bundle (`runtimeLayer-*.mjs`), 2026-11-18 |
| T3 Code 0.1.10 after plain `/clear` sent through the API: `nativeThreadRef.nativeId` = the new id about 1 s after the `/clear` (on `system/init`, not at the next turn), conversation head null; the next turn ran in a new process with `--resume=<new id>` (old process: `SessionEnd(other)`, new: `SessionStart(resume)`); a forced respawn (runtime-mode change) again ran `--resume=<new id>` and knew a fact given after the `/clear` but not one from before it. Plugin 0.7.0 meanwhile still made the alias (its hook ran ~0.9 s before T3 wrote the new id), and its `/clear` + `/handoff:resume` loaded "(none)" | throwaway project, 2026-11-18 |
| Plugin 0.7.1 on T3 Code 0.1.10: native `/clear` → "follows /clear natively; no alias", no symlink, background check saw T3 record the new id; `/handoff:resume` in the replacement process loaded the doc (per-session copy adopted); a fact after it survived a forced respawn. Threshold (40k) → nudge turn → handoff → one fresh `/handoff:resume` → adopted, T3 recorded the new id, the resumed session reported the plan's state and waited for the user's go. `/clear` flow (`HANDOFF_T3_FRESH=false`): `/clear` → no alias → helper followed T3's new id → `/handoff:resume` → new process adopted the doc | throwaway project, sonnet, 2026-11-18 |
| Plugin 0.7.2 on T3 Code 0.1.10: a fresh handoff in a thread running a background `sleep 900` was refused ("still running background agents or commands …"; t3ctl prints it nested inside `orchestration.dispatchCommand failed: [{…"message":"…"}]`); the helper sent one normal turn asking to stop it, the agent stopped it, and the next fresh send went through and loaded the doc (~10 s in all). A `/clear` whose `SessionEnd` was killed in the summarizer still left the tombstone and the link to the new session | throwaway project, sonnet, 2026-11-18 |
| Fresh flow end to end on T3 Code 0.1.9 (sonnet, threshold 55k): threshold at 72.5k → nudge turn → handoff → one `/handoff:resume` sent `--fresh` → adopted within ~1 s, T3 recorded the new id, context 82k → 50k, the resumed session did the plan's next steps; a fact given after the handoff; forced respawn (runtime-mode change) ran `--resume=<new id>` and knew that fact and the pre-handoff one from the doc. Manual path (`--fresh` `/handoff:resume`, and `--fresh` "continue" → Claude invoked `handoff:resume` from the SessionStart note) loaded the doc | throwaway project, 2026-11-12 |

## Comparison with public alternatives (source read 2026-09-08)

| | who96/claude-code-context-handoff | thepushkarp/handoff | Sonovore/claude-code-handoff | this |
| --- | --- | --- | --- | --- |
| Trigger | PreCompact (mid-turn) + SessionEnd(clear) | PreCompact | directive on **every** prompt + PreCompact | Stop at end of turn; auto-compact only safeguard |
| Content | deterministic extraction (last 15 user msgs, 800-char snippets, paths) | deterministic snapshot; model fills sections **after** compaction (Stop blocks ≤3×) | model keeps `session-state.md` continuously | model writes before loss with full context; section check; transcript summarizer fallback |
| Delivery | SessionStart stdout | SessionStart stdout + UserPromptSubmit | SessionStart stdout | skill in user turn, or CLAUDE.md import |
| Multi-session | one global `~/.claude/handoff/latest-handoff.md` | per-project appended file | one file per project | per pid + owner marker + startup guard |
| Works on current CC | PreCompact `systemMessage` discarded (harmless) | yes; lower fidelity | PreCompact directive can't reach the model pre-compaction (#43733) | yes |

Borrowed from thepushkarp: the section-completeness check with a bounded retry. Borrowed from Sonovore: the
optional live state, but gated by context size and growth instead of every prompt.

## Stale-session guard (duplicate-run protection)

An in-process `/clear` mints a **new** session id, but a host may keep its resume cursor on the
**old** (pre-`/clear`) id. Observed under T3 Code: after `/clear` (`SessionEnd(clear) <old>` →
`SessionStart(clear) <new>`, same pid), the thread was later respawned as `claude --resume <old>` in
a fresh process — a **zombie** carrying the full pre-`/clear` context that re-ran the task and
re-published the stale handoff, duplicating file edits, a scheduled job, and helper threads.

Guard: `SessionEnd(clear)` **tombstones** the cleared session id (`state/tombstones/<sid>.json`) and
`SessionStart(clear)` links the successor. Any later `resume`/`compact`/`startup` of a tombstoned id
is a zombie: `SessionStart` tells the model to stop (it was superseded by session X), and the `Stop`
and `PreCompact` hooks go **inert** so it can never re-stage stale content. A normal, never-cleared
`--resume` is unaffected (only `/clear`ed ids are tombstoned).

Residual: the guard makes the zombie *harmless* but cannot stop the host from spawning it; the model
is only *asked* to stop. Under T3 the layer goes further: the zombie's prompts are blocked before any model call and
forwarded (or the thread is recovered), and since 0.6 the T3 layer no longer `/clear`s in place at all (see "T3 Code
layer"), so it creates no new zombies; since 0.7 it uses T3's own fresh sessions where available, which T3 tracks
itself (the superseded session is tombstoned all the same). Hosts other than T3 keep the note-only guard. Two concurrent `--resume` of the *same* never-cleared id (a separate host duplicate-spawn
bug) is also out of scope. Tests: `plugins/handoff/tests/tombstone_test.sh`.

## Caveats

* macOS only for now: `handoff-lib.sh` guards on `uname -s` = Darwin and disables every hook (with a one-line system message) elsewhere. Linux would need `stat -f %m` → `stat -c %Y` and a check of `ps -o command=`.
* Tests used sonnet-5 at low effort with tiny thresholds; behaviour at 300k with opus/fable should be better, not worse.
* At Stop time the transcript lags by one assistant message, so the hook measures the context as of the previous model call (max over the last 3 usages). At 300k that is one tool call behind; a single huge read right before the turn ends is caught at the next turn end, or by the auto-compact safeguard.
* Blocking auto-compact after the API already returned a context-limit error fails that request. Keep the window ≥ 100k above the threshold.
* T3 layer history: <= 0.4 cleared in place via `/clear` + `/handoff:resume` sent with `t3ctl`; 0.5 moved thread resolution to `statev2.sqlite` after T3's db migration silently broke 0.4's lookup; 0.6 keeps `/clear` and aliases T3's recorded session to the post-clear one after finding that T3 0.1.x resumes the pre-clear session on respawn, and recovers threads left in that state; 0.7 uses T3 Code 0.1.9's fresh sessions (one `/handoff:resume` sent with `--fresh`; T3 records the new session, so no alias), keeps the 0.6 flow for older T3, and stages handoffs per T3 thread so a fresh session (also the composer's `/clear`) adopts them; 0.7.1 skips the alias on T3 Code >= 0.1.10, which follows a Claude-side `/clear` itself (#35054), and makes the `/clear` flow work there (follow T3's new id, doc adopted by the process T3 starts for the first post-clear turn). 0.6 was driven end to end on T3 Code 0.1.2, 0.7 on 0.1.9 and 0.7.1 on 0.1.10, all including forced respawns (see Verified facts); 0.7.2 asks the agent to stop background work that blocks a fresh session and keeps the `/clear` chain when `SessionEnd(clear)` is cut short; the recovery path is covered by `tests/t3_test.sh` and its pieces (block, `/handoff:resume` with arguments, inlined digest) were driven live; 0.10.1 gates recovery on T3's routing (wakes of a replaced session no longer recover), follows T3 0.1.12's routing rule, sends the background-work ask only to the session T3 checks, and fixes a duplicate nudge (see the decision record). Other hosts (Claude CLI, Cowork, Superset) have no known API to start a fresh context, so they keep the manual `/clear` + `/handoff:resume` path. Superset sessions are detectable via `SUPERSET_TAB_ID` if an adapter is ever wanted.
* The alias writes inside Claude Code's transcript dir: `<R>.jsonl` is a symlink, and the post-`/clear` transcripts hold entries under id R once T3 respawns. Claude Code's own `/resume` picker may list R next to the newest session (same content). Claude Code's transcript cleanup (`cleanupPeriodDays`) could remove the link of a thread idle that long; T3 would then fail to resume it. The thread's history, PR links, schedules and pins are untouched.
* The fresh flow relies on T3 exporting `T3CODE_THREAD_ID` to its Claude process (verified on 0.1.9). A per-thread doc that was staged but never consumed (no `/clear`, no fresh session, no compaction) waits in `by-thread/` and is adopted by the next fresh session of that thread, as a staged doc in the CLI is loaded after the next `/clear`.
* Seen on Claude Code 2.1.327 under T3 Code 0.1.10: a `/clear` with no fresh handoff doc (so `SessionEnd(clear)` starts the nested summarizer) had its `SessionEnd` hook killed within ~1 s, so no doc is written; the "Claude Code waits for SessionEnd(clear)" fact above (run7) no longer holds there. The automatic paths always have the doc ready (instant), so this affects only a manual `/clear` without a handoff. Since 0.7.2 the hook writes the tombstone and the `pid-cleared` bridge before the summarizer, so the `/clear` chain stays linked (verified live); 0.7.1 and earlier lost both.
* Wakes of a replaced session: on T3 0.1.12 a fresh handoff normally ends the old process (T3 refuses the fresh session while it runs background work), so the wake case of 0.10.1 is verified by a replay of thread 569772de (`tests/wake_test.sh`) and by the real hook against the live 0.1.12 db, not by a live wake. T3's refusal checks only the session of its active pointer; if a replaced, still-alive process holds the pointer, the fresh session waits for that process's background work, and the plugin can only say so (pending note), not stop it.
* The routing query reads T3's runs/messages/threads tables (layout of 0.1.11–0.1.12). Without them (older T3) it falls back to the newest run ordinal, then `updated_at`.
* t3ctl auth drift (seen 2026-11-27): `~/.config/t3ctl/config.json` listed `orchestration:operate` while the server's
  session (`t3ctl auth status`) granted only `orchestration:read`, so t3ctl did not upgrade and every write (`threads
  send`, so every automatic handoff and nudge) was refused with "missing required scope: orchestration:operate". Fix:
  `t3ctl auth pair --operate`. The helper treats the refusal like a busy thread: it retries until `T3_SEND_TIMEOUT`
  (600 s), logging each refusal, then records the handoff as failed (type /clear, then /handoff:resume).
* `t3ctl` JSON output can contain raw control characters that break `jq`; the helper strips them. When scripting `t3ctl threads new`, never pass an empty thread ref to `threads send`: it resolves to some other thread.

## License

MIT. Issues and PRs welcome at https://github.com/samzilverberg/claude-handoff.
