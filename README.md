# handoff — Claude Code plugin: end-of-turn handoff → /clear → resume

Auto-compact fires mid-turn and its summary drops decisions. This plugin instead acts **at the end of the turn**
that crosses a context threshold: Claude writes a structured handoff document itself, the plugin stages it,
**you type `/clear`**, and the fresh context resumes from it via `/handoff:resume`. Under T3 Code an optional layer
(`T3_AUTOCLEAR`) types `/clear` + `/handoff:resume` for you, in the same thread, and keeps T3 pointed at the live session. Running `/handoff:resume` without `/clear` just adds the document on top of the full context. Auto-compact stays on only as a safeguard far above the
threshold. Verified against Claude Code 2.1.263 with 18 driven test sessions plus real long sessions.

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
* Optional, only for the T3 layer (`T3_AUTOCLEAR`): [T3 Code](https://github.com/pingdotgg/t3code) **(Beta) >= 0.1.0**, i.e. the release whose state db is `~/.t3/userdata/statev2.sqlite` (older T3 with only `state.sqlite` is refused with a message, no fallback), [`t3ctl`](https://github.com/samzilverberg/t3ctl) on PATH, and `sqlite3` (ships with macOS)

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
| `STARTUP` | ignore | Fresh startup that finds another live session's staged handoff: `ignore` (inject a "not yours" note) or `adopt` |
| `T3_AUTOCLEAR` | false | T3 layer, inside a T3 Code thread only (see "T3 Code"). The handoff-writing request goes to the thread as its own turn; once the handoff is staged the plugin sends `/clear` and `/handoff:resume` **to the same thread**, and aliases the Claude session id T3 resumes to the new session (so a T3 respawn cannot bring back the pre-clear context). Threads `/clear`ed by plugin <= 0.5 are recovered on their next message. Requires T3 Code (Beta) >= 0.1.0 and t3ctl. Off, or wherever the preflight fails: the base `/clear` + `/handoff:resume` path |
| `T3_NUDGE_TURN` | true | With `T3_AUTOCLEAR`: `true` sends the handoff-writing request as its own turn; `false` uses the in-turn Stop nudge (the automatic /clear still runs). Flip it to compare while testing |
| `T3_SEND_TIMEOUT` | 600 | Seconds the T3 helper waits for the thread to go idle (and retries a send refused because the thread was busy) |

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

```
turn ends at ≥ THRESHOLD ─Stop─▶ t3.sh nudge: once the thread is idle, send "[handoff plugin] … write the handoff"
                                  as its own turn (the reply you were reading stays the turn's visible message)
handoff written ─Stop─▶ stage it ─▶ t3.sh clear: once idle, send "/clear" to the same thread
     SessionEnd(clear): stage the handoff, tombstone the cleared session
     SessionStart(clear) ─▶ t3.sh alias: <R>.jsonl (R = the Claude session id T3 recorded for the thread)
                            becomes a symlink to the new session's transcript; original kept as <R>.jsonl.pre-handoff
new session seen ─▶ send "/handoff:resume": the fresh context loads the handoff and continues from Next steps
later, T3 respawns the process (idle reap, app restart, mode change) with `--resume R`
     ─▶ Claude Code reads <R>.jsonl → the live post-/clear context; new turns append through the link, id stays R
```

Why the alias. T3 Code (Beta) 0.1.x records a thread's Claude session id once and ignores the new `session_id` a
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

Recovery of threads `/clear`ed by plugin <= 0.5 (or after a failed alias): when T3 resumes such a stale session and
the user types into it, the UserPromptSubmit hook blocks the prompt (0 tokens; T3 shows the reason as a notice),
stages the newest handoff document of the session's `/clear` chain with a digest of the later sessions' user and
assistant text inlined (full digest: `.claude/handoff/recovery/<sid>-digest.md`), and runs the same `/clear` (which
aliases the stale session to the fresh one) + `/handoff:resume`, with the user's message passed to `/handoff:resume`.

Requirements: T3 Code (Beta) **>= 0.1.0** (state db `~/.t3/userdata/statev2.sqlite`; older T3 is refused with
"only the legacy T3 db … T3 Code too old") and t3ctl. Setup: install `t3ctl` per its README
(`pnpm install && pnpm build && pnpm link --global`), then `/plugin configure handoff@claude-handoff` →
`T3_AUTOCLEAR=true`, and set "Auto-compact after" in T3 Code's Claude settings ~100k above `THRESHOLD`.

```
… turn ends at 362k …
Stop says: Handoff: context is 362104 tokens (limit 350000). Asking Claude to write the handoff document before it stops. Delivered as a separate T3 turn so this reply stays visible. nudge scheduled for thread <id> …
> [handoff plugin] The context window is at 362104 tokens … Write the handoff document …      (sent by the helper)
Claude: [Write .claude/handoff/sessions/<sid>.md] Handoff written.
Stop says: Handoff: context is 363900 tokens (limit 350000). Handoff staged; once this turn ends the plugin sends /clear and /handoff:resume to this thread. …
> /clear                                              (sent by the helper)
> /handoff:resume                                     (sent by the helper; Claude continues from Next steps)
```

Safety and future-proofing. The helper checks every moving part before acting and names the one that is off:
host is T3 Code (`__CFBundleIdentifier=com.t3tools.t3code` or a "T3 Code" ancestor), so CLI / desktop / Cowork /
Superset sessions never touch a thread; `t3ctl` and `sqlite3` on PATH;
`statev2.sqlite` present and readable, table `orchestration_v2_projection_provider_threads` with `thread_id`,
`updated_at`, `payload_json`, rows carrying `payload_json.nativeThreadRef.nativeId`; T3 server reachable via
`t3ctl env` (5 s cap), supported, >= 0.1.0. The thread is resolved by this session's exact Claude session id
(`nativeThreadRef.nativeId`; for sessions `/clear`ed in place, via the plugin's own `/clear` tombstone chain back to
the id T3 recorded); it must exist, not be archived, and work in this project dir (its worktree, or for local
threads its project's workspace root); the mapping is re-checked right before every send, and `/handoff:resume` goes out only after the new session is seen. The alias step runs inside SessionStart and is local only (db read + one symlink), so it works even if the T3 server is slow. The db is only ever read;
writes go through `t3ctl`. A failed preflight is reported at SessionStart (not first at the threshold), every skip
in the Stop message, every attempt in `hooks.log` (`[t3]`); the base path applies whenever the T3 layer cannot act.

Troubleshooting: `/handoff:status` (or `bash plugins/handoff/scripts/t3.sh <project> /dev/null <session id> check`)
prints `ok: …` or the blocking reason. `HANDOFF_T3_DRYRUN=1` resolves without acting. A failed automatic handoff
is reported in the next Stop message; the manual fallback is `/clear` then `/handoff:resume` (the alias still runs on a
typed `/clear`). To undo an alias: replace `<R>.jsonl` with `<R>.jsonl.pre-handoff`.

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
layer"), so it creates no new zombies. Hosts other than T3 keep the note-only guard. Two concurrent `--resume` of the *same* never-cleared id (a separate host duplicate-spawn
bug) is also out of scope. Tests: `plugins/handoff/tests/tombstone_test.sh`.

## Caveats

* macOS only for now: `handoff-lib.sh` guards on `uname -s` = Darwin and disables every hook (with a one-line system message) elsewhere. Linux would need `stat -f %m` → `stat -c %Y` and a check of `ps -o command=`.
* Tests used sonnet-5 at low effort with tiny thresholds; behaviour at 300k with opus/fable should be better, not worse.
* At Stop time the transcript lags by one assistant message, so the hook measures the context as of the previous model call (max over the last 3 usages). At 300k that is one tool call behind; a single huge read right before the turn ends is caught at the next turn end, or by the auto-compact safeguard.
* Blocking auto-compact after the API already returned a context-limit error fails that request. Keep the window ≥ 100k above the threshold.
* T3 layer history: <= 0.4 cleared in place via `/clear` + `/handoff:resume` sent with `t3ctl`; 0.5 moved thread resolution to `statev2.sqlite` after T3's db migration silently broke 0.4's lookup; 0.6 keeps `/clear` and aliases T3's recorded session to the post-clear one after finding that T3 0.1.x resumes the pre-clear session on respawn, and recovers threads left in that state. Driven end to end on T3 Code 0.1.2, including forced respawns (see Verified facts); the recovery path is covered by `tests/t3_test.sh` and its pieces (block, `/handoff:resume` with arguments, inlined digest) were driven live. Other hosts (Claude CLI, Cowork, Superset) have no known API to start a fresh context, so they keep the manual `/clear` + `/handoff:resume` path. Superset sessions are detectable via `SUPERSET_TAB_ID` if an adapter is ever wanted.
* The alias writes inside Claude Code's transcript dir: `<R>.jsonl` is a symlink, and the post-`/clear` transcripts hold entries under id R once T3 respawns. Claude Code's own `/resume` picker may list R next to the newest session (same content). Claude Code's transcript cleanup (`cleanupPeriodDays`) could remove the link of a thread idle that long; T3 would then fail to resume it. The thread's history, PR links, schedules and pins are untouched.
* `t3ctl` JSON output can contain raw control characters that break `jq`; the helper strips them. When scripting `t3ctl threads new`, never pass an empty thread ref to `threads send`: it resolves to some other thread.

## License

MIT. Issues and PRs welcome at https://github.com/samzilverberg/claude-handoff.
