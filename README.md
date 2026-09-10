# handoff — Claude Code plugin: end-of-turn handoff → /clear → resume

Auto-compact fires mid-turn and its summary drops decisions. This plugin instead acts **at the end of the turn**
that crosses a context threshold: Claude writes a structured handoff document itself, the plugin stages it,
**you type `/clear`** (the plugin never clears by itself unless `T3_AUTOCLEAR` is on), and the fresh context resumes from it via `/handoff:resume`. Running `/handoff:resume` without `/clear` just adds the document on top of the full context. Auto-compact stays on only as a safeguard far above the
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
* Optional, only for `T3_AUTOCLEAR`: [T3 Code](https://t3.chat/code) with [`t3ctl`](https://github.com/samzilverberg/t3ctl) on PATH, and `sqlite3` (ships with macOS)

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
| `T3_AUTOCLEAR` | false | Inside a T3 Code thread only: after staging, a detached helper waits for the turn to end, then sends `/clear` and `/handoff:resume` to **this session's** thread via `t3ctl`. Guards: (1) host must be T3 Code (`__CFBundleIdentifier=com.t3tools.t3code` or a "T3 Code" ancestor process), so CLI / Cowork / Superset sessions never touch a thread; (2) thread resolved by exact Claude session id from `~/.t3/userdata/state.sqlite` (`provider_session_runtime.resume_cursor_json.resume`, read-only), directory match only as a fallback when the db is unreadable and only if unambiguous; (3) re-checked right before `/clear`. Skips are logged and shown in the Stop message. `HANDOFF_T3_DRYRUN=1` resolves without sending |

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

## T3 Code: zero-keystroke handoff (`T3_AUTOCLEAR`)

[T3 Code](https://t3.chat/code) runs Claude Code as a stream-json child and its composer forwards slash commands, so
a `/clear` sent to the thread reaches Claude Code. With `T3_AUTOCLEAR=true` the Stop hook, after staging the handoff,
hands off to `scripts/t3-autoclear.sh`, which uses [`t3ctl`](https://github.com/samzilverberg/t3ctl) (a CLI for an
already-running T3 Code app: `threads list/wait/send`) to wait for the turn to end, send `/clear`, then `/handoff:resume`.
Nothing to type; the thread continues in a fresh context.

Setup: install `t3ctl` per its README (`pnpm install && pnpm link --global`), then `/plugin configure handoff@claude-handoff`
→ `T3_AUTOCLEAR=true`, and set "Auto-compact after" in T3 Code's Claude settings ~100k above `THRESHOLD`.

Safety: the helper only acts when the Claude process was spawned by T3 Code, resolves the thread by this session's
exact Claude session id (from T3's local state db), and re-checks that mapping right before sending `/clear`. Any
miss is logged and reported in the Stop message, and the manual path applies. Sessions started from the Claude CLI,
the desktop app or other wrappers are never touched; they always get the manual `/clear` + `/handoff:resume` prompt.

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

## Caveats

* macOS only for now: `handoff-lib.sh` guards on `uname -s` = Darwin and disables every hook (with a one-line system message) elsewhere. Linux would need `stat -f %m` → `stat -c %Y` and a check of `ps -o command=`.
* Tests used sonnet-5 at low effort with tiny thresholds; behaviour at 300k with opus/fable should be better, not worse.
* At Stop time the transcript lags by one assistant message, so the hook measures the context as of the previous model call (max over the last 3 usages). At 300k that is one tool call behind; a single huge read right before the turn ends is caught at the next turn end, or by the auto-compact safeguard.
* Blocking auto-compact after the API already returned a context-limit error fails that request. Keep the window ≥ 100k above the threshold.
* `T3_AUTOCLEAR` was verified once (sonnet 4.6, local-env thread, threshold 30k via a project `settings.local.json` env override): helper log shows `autoclear scheduled` → `sent /clear` → `sent /handoff:resume`, and the hooks log shows `SessionEnd(clear)`/`SessionStart(clear)` on the same pid. v0.3.7 guards (host + exact session id) dry-run tested from a live T3 worktree thread; other hosts (Claude CLI, Cowork, Superset) have no known API to inject `/clear`, so they keep the manual `/clear` + `/handoff:resume` path. Superset sessions are detectable via `SUPERSET_TAB_ID` if an adapter is ever wanted.
* `t3ctl` JSON output can contain raw control characters that break `jq`; the helper strips them. When scripting `t3ctl threads new`, never pass an empty thread ref to `threads send`: it resolves to some other thread.

## License

MIT. Issues and PRs welcome at https://github.com/samzilverberg/claude-handoff.
