# T3 Code: `/clear` and the stale Claude session (decision record)

Status: **fixed upstream in T3 Code (Beta) 0.1.10** by
[pingdotgg/t3code#35054](https://github.com/pingdotgg/t3code/pull/35054) ("fix(server): Claude threads resume the
session /clear started", merged 2026-11-12, closes
[#24152](https://github.com/pingdotgg/t3code/issues/24152); first nightly `0.1.10-nightly.20261112.4603`). Since
plugin v0.7.1 (2026-11-18) the alias is made **only for T3 < 0.1.10** (see "Since 0.7.1" below); the exit plan is done.
Before that: active workaround from v0.6.0 (2026-10-26), fallback only since v0.7.0 (2026-11-12), when the T3 layer
switched to T3's native fresh session on >= 0.1.9 (PR #30325), which T3 tracks itself (see "Since 0.7"). Existing
aliases and `.pre-handoff` files stay in place: threads aliased before still resume through them.

This doc covers what broke, what we tried, what we measured, why we chose the symlink alias, and how to take it out
once T3 fixes the bug. The README's "T3 Code layer" section describes the current behaviour. This doc keeps the
reasoning behind it.

## The problem

- T3 Code (Beta) 0.1.0 – 0.1.9 stores a thread's Claude session id once, when it creates the provider thread. It lives in
  `~/.t3/userdata/statev2.sqlite`, table `orchestration_v2_projection_provider_threads`, at
  `payload_json.nativeThreadRef.nativeId`. Below we call this id **R**.
- T3 doesn't handle `/clear` itself. It passes `/clear` to Claude Code, which starts a new session (id **NEW**) inside
  the running process. Claude Code reports NEW in `system/init` and emits `conversation_reset`. T3 logs NEW and then
  ignores it.
- So `/clear` works while the process stays alive. Whenever T3 replaces the process, it runs `claude --resume=R` and
  the thread goes back to the pre-clear conversation. Nothing in the UI shows this happened. T3 replaces the process
  on:
  - a server or app restart;
  - the roughly 30-minute idle release;
  - a model or runtime-mode change it can't apply live.
- `nativeConversationHeadRef` (which T3 passes on as `resumeSessionAt`) was null on all 29 Claude threads we checked.
  It doesn't steer the resume.
- T3 has no command that re-points R. Rollback to thread start is the only code path that assigns a Claude thread a
  new id, and it also reverts files.

### Symptoms we saw

- v0.4 to v0.5 cleared threads in place with `/clear`. After a later respawn, a thread answered from the old context.
  Thread e7c1ec3a printed the plugin's own "stale superseded session" notice, because the plugin had tombstoned R
  when it was cleared.
- Upstream reports show the same thing: replies land in the old transcript, and `parentUuid` points at the pre-clear
  message.

## What we need

From the user:

1. The handoff runs automatically inside T3, with no keystrokes.
2. It stays in the **same UI thread**: no new sidebar entries.
3. **No `/compact`**: it costs an extra model call and time.
4. Keep `/clear` and work around the session-id problem.

Plain Claude CLI keeps the manual path: `/clear` then `/handoff:resume`.

## Options tried

| Option | Result | Verdict |
|---|---|---|
| **Successor thread per handoff** (`t3ctl threads continue`: new thread, same worktree/branch/model, handoff as its first prompt) | Built and worked. Adds a sidebar thread on every handoff. | Rejected by the user (new UI element). The t3ctl command was removed. |
| **T3 native `/compact`** (the exact text `/compact`; T3 treats it as maintenance) | Verified live: keeps the session id, so respawns stay correct. Costs a summarization call over the full context. `/compact <instructions>` can only extend the built-in prompt, not replace it, so it can't write our handoff. | Rejected by the user (cost and time). |
| **Write R into T3's db** | `statev2.sqlite` is event-sourced. Projections are rebuilt from events, and the db isn't ours to edit. | Rejected without trying. |
| **`thread.create` with `importedNativeThread`** (bind a thread to NEW) | T3 opens a native thread it has no turns for as a **new** session (`sessionId`, not `resume`). The first turn fails. Also creates a new thread. | Rejected (tested). |
| **`thread.stop`** to force a clean respawn on NEW | Only interrupts the running turn. The id stays R. | Rejected (tested). |
| **Rollback to thread start** (the only path that re-mints the id) | Reverts files. | Rejected. |
| **Steer with `resumeSessionAt` / `nativeConversationHeadRef`** | Always null for Claude threads, and we can't write it. | Not possible. |
| **Session alias: `<R>.jsonl` → symlink to `<NEW>.jsonl`** | Verified (below). | **Chosen.** |

## The chosen workaround: session alias

`claude --resume <id>` opens `<id>.jsonl` in the project's transcript dir (`~/.claude/projects/<dir>/`) and follows a
symlink there. Verified with `claude -p --resume A`, where `A.jsonl` is a symlink to `B.jsonl`, in plain mode and in
stream-json mode:

- it loads B's content;
- it reports session id **A** in `init` (the id T3 expects);
- it appends new entries through the link, so they land in B's file.

The flow (`plugins/handoff/scripts/t3.sh`, `handoff-sessionstart.sh`):

1. Stop hook, once the handoff is staged: `t3.sh clear` starts a background worker. Once the thread is idle, the
   worker sends `/clear` with `t3ctl`, then waits for the plugin's `state/cleared/<live sid>` marker (default 30 s,
   `HANDOFF_T3_CLEAR_WAIT`).
2. `SessionStart(clear)` reads OLD from the pid-cleared bridge, links the tombstone OLD → NEW, and runs
   `t3.sh … NEW alias OLD`. This step only touches local files, with no t3ctl calls, so it fits inside the hook's
   10 s limit:
   - R = the thread's `nativeThreadRef.nativeId`. If R == NEW, nothing to do: "no alias needed".
   - Guards (each failure is skipped and logged):
     - `nativeConversationHeadRef` must be null.
     - The transcript path must be known, and its basename must be `NEW.jsonl`.
     - `R.jsonl` must exist in the same dir.
   - `R.jsonl` is moved to `R.jsonl.pre-handoff` (or `.pre-handoff-<ts>` if that name is taken). If it is already
     a link, it is simply re-pointed. Then `ln -sfn NEW.jsonl R.jsonl`.
   - The plugin writes `state/aliases/R` = NEW and `state/aliased-by/NEW` = R. R's tombstone moves to
     `tombstones/aliased/`, because R is live again.
3. The worker sees the marker and sends `/handoff:resume`. The outcome goes to `state/<sid>.t3clear`, and the next
   Stop message reports it.
4. Plugin state and the handoff doc are keyed by R (`session_key`), so they survive a respawn, when the process runs
   under id R again. The next `/clear` re-points the link.

### Recovering threads stuck before v0.6

Threads cleared by v0.5 (or where the alias failed) resume a tombstoned session. The `UserPromptSubmit` hook blocks
the user's prompt, which costs 0 tokens; T3 shows the block reason as a notice. Then `t3.sh recover`:

1. Walks the `/clear` chain to the newest handoff doc.
2. Inlines a digest of the later transcripts. It is inlined because the model skipped the digest when the doc only
   referenced the file.
3. Runs the same `/clear` (which aliases) + `/handoff:resume <note + the user's message>`.

## How it was verified

- **Unit/e2e with fakes:** `plugins/handoff/tests/t3_test.sh`, 80 cases at 0.6 (130 at 0.7, with the fresh flow; 165
  at 0.7.1, with the 0.1.10 gate). The fake t3ctl plays `/clear` by running the real SessionEnd/SessionStart hooks. Run
  the whole suite with `for t in tests/*.sh; do bash $t; done`; 111 cases in total at 0.6, 161 at 0.7, 196 at 0.7.1.
- **Live in T3 Code (Beta) 0.1.2** (2026-10-26, scratch project, threshold 60k):
  1. Threshold → nudge → handoff → `/clear` → alias → `/handoff:resume` in about 2 s. Context went from 74k to 37k.
  2. Gave a fact *after* the `/clear`, then forced a respawn. T3 ran `--resume=<pre-clear id>` and the thread still
     knew the fact.
  3. A second handoff from the respawned process re-pointed the link. After another respawn the thread knew all
     three facts.
- **Forcing a respawn:** change the runtime mode, e.g. `t3ctl threads send <thread> --runtime-mode <other mode>
  "…"`. Under the hood this is the `thread.runtime-mode.set` orchestration command. Check `ps` for the new
  `claude … --resume=<id>`.

Useful queries:

```sh
DB=~/.t3/userdata/statev2.sqlite
# R and the conversation head for a thread
sqlite3 "$DB" "select json_extract(payload_json,'$.nativeThreadRef.nativeId'),
  json_extract(payload_json,'$.nativeConversationHeadRef') from orchestration_v2_projection_provider_threads
  where thread_id='<thread id>'"
# aliases in a transcript dir
ls -l ~/.claude/projects/<dir>/*.jsonl | grep -- '->'
```

## Costs and risks

- Writes inside Claude Code's transcript dir. Claude Code's own `/resume` picker can list R next to NEW (same
  content).
- `cleanupPeriodDays` may delete the link of a thread left idle that long. T3 would then fail to resume it.
- To undo an alias by hand: replace `<R>.jsonl` with `<R>.jsonl.pre-handoff`.
- If T3 ever sets `nativeConversationHeadRef`, the alias step stops by design: a pinned head message is hidden behind
  the link.

## Since 0.7: T3's native fresh session

T3 Code (Beta) 0.1.9 (PR #30325) added `freshContext` to `message.dispatch`. With it, T3 starts a **new provider
session in the same thread**: the provider thread starts as `pending:<runId>:fresh`, the old session is detached, and
T3 records the new native id itself. The capability is advertised as `freshContext` in the environment descriptor.
`steer_active`/`restart_active` dispatch is downgraded to `queue_after_active`, and the send is rejected while the
current session still runs background agents or commands. The web composer's `/clear` no longer reaches Claude Code:
it arms `freshContext` for the thread's next message. Plain `/clear` text sent through the API is **not**
intercepted (it still reaches Claude Code's `/clear`, and the bug above still applies to it).

What the plugin does with it (`t3.sh`, `handoff-lib.sh` `publish`, `handoff-sessionstart.sh`):

1. t3ctl 0.8.0 gained `threads send --fresh` (dispatches `freshContext: true`, refuses with exit 7 when the server
   lacks the capability).
2. Preflight picks the **fresh** flow when the server advertises `freshContext`, t3ctl >= 0.8.0, and the hook process
   has `T3CODE_THREAD_ID` (exported by T3 to its agents) equal to the resolved thread; `HANDOFF_T3_FRESH=false` forces
   the `/clear` flow. Otherwise: the `/clear` + alias flow above, unchanged.
3. Fresh flow: once the handoff is staged and the thread idle, one `t3ctl threads send <thread> --fresh
   "/handoff:resume"`. No `/clear`, no alias, no symlink: T3 owns the new session id, so a respawn resumes the new
   session. Busy or background-work refusals are retried after each idle until `T3_SEND_TIMEOUT`; the outcome names
   the last refusal. Exit 7 is not retried.
4. Finding the doc. A fresh session is a new process with `SessionStart(startup)`: no `SessionEnd(clear)`, no
   pid-cleared bridge, no `by-pid` copy. The old process ends with `SessionEnd(other)`, which resets `current.md` when
   it owns it. That broke the manual T3 path on 0.6.0 (composer `/clear`, then `/handoff:resume` loaded "(none)",
   reproduced live). So `publish` also stages the doc per T3 thread (`by-thread/<T3CODE_THREAD_ID>.md`, plus `.json`
   with the staging session and its key). `SessionStart(startup)` of a process whose thread has a staged doc adopts
   it (`by-pid/<new pid>.md`, `current.md`, owner), tombstones the staging session (and its key, when it ran aliased)
   with `continued_by` = the new session, and archives the per-thread copy. A `/clear` or compact that consumes the
   doc in-process drops the copy. The resume skill falls back to the per-thread copy after `by-pid`.
5. Keys: the fresh session is keyed by its own id (`session_key` = sid; no `aliased-by` entry). Old aliases stay in
   place for old threads.
6. Recovery of stuck threads uses the fresh flow where available; the stale session stays tombstoned.

Verified live on T3 Code 0.1.9 (2026-11-12, throwaway project, sonnet): threshold → nudge → handoff → one fresh
`/handoff:resume` → adopted within ~1 s → `nativeThreadRef.nativeId` = the new session id → the resumed session did the
plan's next steps. A fact given after the handoff survived a forced respawn (`--resume=<new id>` in `ps`). The manual
path (`--fresh "/handoff:resume"`, and `--fresh "continue"` with the SessionStart note) loaded the doc. Tests:
`tests/t3_test.sh` sections M–R (the fake t3ctl plays a fresh send as `SessionEnd(other)` of the old process plus
`SessionStart(startup)` of a new one with `T3CODE_THREAD_ID`, then records the new id).

## Since 0.7.1: T3 Code 0.1.10 follows `/clear` itself

What #35054 does (read in the PR and in the 0.1.10 server bundle, `runtimeLayer-*.mjs`): the Claude adapter keeps a
map `clearedNativeSessions` from the live process's native id to the `session_id` a later `system/init` reports. It
rewrites `provider_thread.updated` events with it, so the stored `nativeThreadRef.nativeId` becomes the new id and
`nativeConversationHeadRef` null. The next turn closes the process and opens a new one with `resume` on the new
session (one restart; background work still running in the process blocks it with the existing error). The follow-up
commit `97d9359` (forks, rewinds, and the next turn after `/clear` reusing the live process instead) is **not** in
0.1.10: its identifiers (`resetSessionByNativeThread`, `toProcessThread`, `withAttemptNativeSession`) are absent from
the bundle.

Verified live on 0.1.10 (2026-11-18, throwaway project, sonnet, plain `/clear` sent with `t3ctl threads send`):

1. `nativeThreadRef.nativeId` = the new session id about 1 s after the `/clear` (on `system/init`), not only after the
   next turn.
2. The next turn ran in a new process, `--resume=<new id>` (`SessionEnd(other)` of the old process, then
   `SessionStart(resume)` of the new session). A forced respawn (runtime-mode change) again ran `--resume=<new id>`;
   the thread knew a fact given after the `/clear` and not one from before it.
3. Plugin 0.7.0 still made the alias: its `SessionStart(clear)` hook ran about 0.9 s before T3 wrote the new id, so
   the db still showed R. Harmless (T3 no longer resumes R), but a leftover symlink and `aliased-by` entry per `/clear`.
4. Two breaks of 0.7.0's `/clear` flow on 0.1.10 (the flow is used there only with `HANDOFF_T3_FRESH=false`, a
   process without `T3CODE_THREAD_ID`, or t3ctl < 0.8.0):
   - The helper re-checks before each send that the thread still maps to the session it started from. After the
     `/clear` it maps to the new one, so `/handoff:resume` would not be sent.
   - The first turn after the `/clear` runs in a new process. The old process's `SessionEnd(other)` resets
     `current.md`, the new pid has no `by-pid` copy, and `SessionStart(clear)` already dropped the per-thread copy:
     `/handoff:resume` loaded "(none)" (reproduced).

What 0.7.1 does:

- `t3.sh alias` asks the server version (`t3ctl env`, 5 s cap; ~0.15 s measured) before resolving the thread. On
  T3 >= 0.1.10 (or a 0.1.10 nightly from 20261112.4603 on) it makes no alias and logs `T3 Code <v> (>= 0.1.10) follows
  /clear natively; no alias for <old> -> <new> (thread …)`. A background check then logs `T3 records the post-/clear
  session …` or a WARNING if T3 did not record it within `HANDOFF_T3_CLEAR_WAIT`. Older T3, other 0.1.10 pre-releases
  and an unreachable server get the alias as before. A version check rather than a db check, because inside
  `SessionStart(clear)` the db cannot know yet (point 3), and waiting for it would eat into the hook's 10 s.
- Keys and tombstones without an alias: the new session has no `aliased-by` entry, so `session_key` is its own id;
  the cleared session stays tombstoned (`SessionEnd(clear)`) and linked to the new one. If the cleared session itself
  ran under an alias key K (a thread aliased by 0.6), K is tombstoned and linked too, as the fresh flow does.
- The `/clear` worker accepts the id T3 records after the `/clear` (`T3 records session <new> for thread … (it
  follows /clear)`) and re-checks against it from then on.
- `SessionStart(clear)` under T3 keeps a copy of the doc as `by-session/<new sid>.md`. `SessionStart(resume)` of that
  session in another process adopts it (`by-pid/<new pid>.md`, `current.md`, owner); the session's first `Stop`
  drops it, so a later respawn never re-adopts it. With `97d9359` the first turn stays in the old process and the
  copy is dropped unused.
- Recovery (UserPromptSubmit block + `t3.sh recover`) already used the fresh flow where available (0.7.0); unchanged
  apart from a block notice that no longer says "/clear".

Verified live with 0.7.1 on 0.1.10 (2026-11-18): native `/clear` → no alias, no symlink, T3 recorded the new id;
`/handoff:resume` in the replacement process loaded the doc; a fact given after it survived a forced respawn. The
fresh flow (threshold → nudge → one fresh `/handoff:resume` → adopted) is unchanged. The `/clear` flow with
`HANDOFF_T3_FRESH=false` completed: `/clear` → no alias → helper followed T3's id → `/handoff:resume` → doc adopted by
the new process. Tests: `tests/t3_test.sh` sections S (version gate, incl. nightlies) and T (`/clear` flow on 0.1.10;
the fake plays T3 recording the new id and replacing the process on the next turn).

## When upstream fixes it (exit plan) — done in 0.7.1

Outcome: upstream shipped the fix as #35054 (not #24168) in T3 Code 0.1.10. Contrary to step 1 below, `t3.sh alias`
did **not** see R == NEW (T3 records NEW after `SessionStart(clear)`), so 0.7.0 kept aliasing; 0.7.1 gates the alias
on the server version instead. Steps 2 and 3 were carried out as described (see "Since 0.7.1"). What remains:

- The alias, the `aliased-by` mapping and the T3 `/clear` replay in the tests can go once the minimum supported T3 is
  >= 0.1.10.
- Keep `recover` and the UserPromptSubmit block while old stuck threads exist, and leave existing `.pre-handoff` files
  and links in place.

The plan as written at 0.7:

With 0.7 most of this is moot on T3 >= 0.1.9: the plugin's own handoff never sends plain `/clear` there. What is left:

- The alias still covers plain `/clear` text that reaches Claude Code (a user or script sending `/clear` through the API
  or t3ctl, older T3). Once #24168 (or an equivalent) ships, `t3.sh alias` sees R == NEW and logs "no alias needed".
- When the minimum supported T3 becomes >= 0.1.9 **and** #24168 is in, the `/clear` flow, the alias, `session_key`'s
  `aliased-by` mapping and the T3 `/clear` replay in the tests can go. Keep `recover` and the UserPromptSubmit block
  while old stuck threads exist, and leave existing `.pre-handoff` files and links in place.

The original plan, for the `/clear` flow:

PR #24168 records the id Claude reports after `/clear`. With it, T3's R becomes NEW.

1. **Nothing breaks.** `t3.sh alias` sees R == NEW, logs "no alias needed", and exits. Background clear, nudge, and
   resume behave as before.
2. **Confirm on the installed build.** Run a T3 thread, `/clear`, then:
   - `nativeThreadRef.nativeId` in `statev2.sqlite` should equal the new session id;
   - after a forced respawn, `ps` should show `--resume=<new id>`;
   - `hooks.log` should show `[t3] … no alias needed`.
3. **Then simplify.**
   - Gate the alias on the T3 version, or drop it.
   - Drop `session_key` / `aliased-by` keying for new sessions.
   - Keep `recover` and the UserPromptSubmit block for as long as old stuck threads exist.
   - Leave existing `.pre-handoff` files and links in place: they still serve old threads.
   - Update the README's T3 section, verified facts and caveats, and this doc's status line.
4. The plugin's preflight still requires T3 >= 0.1.0. Record which T3 version contains the fix there and in the
   README requirements.

## Since 0.10.1: wakes of a replaced session, and which session a thread belongs to

Incident (thread 569772de, 2026-11-24, T3 Code 0.1.11, plugin 0.7.2+). The fresh handoff completed at 18:01:27
(5fc41362 → 5d8bc668; old session tombstoned and linked). The old Claude process stayed alive for its background
agents, and Claude itself woke it with `<task-notification>` prompts (Claude-internal, not T3 sends; seen in its
transcript as `queue-operation` enqueue/dequeue). Each hit `UserPromptSubmit` → tombstoned → `t3.sh recover`. Seven
times between 18:01 and 18:18: a recovery doc re-staged per thread (the last one is still in `by-thread/`), a fresh
`/handoff:resume` refused for background work, an "end your background work" turn sent to the thread, which T3 routed
to the new session (no background work there; six such turns), then "thread now maps to 5d8bc668 … NOT sent".

Root causes:
1. Recovery ran for any prompt into a tombstoned session. It must only run when T3 still routes the thread to that
   stale session (the pre-0.7 case it was built for).
2. "The session T3 maps the thread to" was the provider-thread row with the newest `updated_at`. A thread has one row
   per session; the old process's own events (task roster changes, turn ends, exit) bump its row and move the thread's
   `active_provider_thread_id` back to it. That is why the mapping check passed for the old session at 18:03:15, the
   fresh send went out and was refused, and the ask went out. After the old process exited (22:48), the db still names
   the old session as both newest and active; the new session's own next handoff would have failed the mapping check.
3. The ask turn went to whichever session T3 routes user messages to, not to the one with the background work.

T3 Code 0.1.12, read from its bundle: a user message goes to the newest provider thread started at or after the
thread's last fresh start (`contextBoundaryOrdinal`: highest ordinal of a run with `freshContext`, not queued, not
cancelled before it started, not started by a scheduled task; rows started by a scheduled fresh run are side
conversations). Wakes and fresh starts act on the active pointer; a wake run is attributed to the active pointer, so the
old row's `lastRunOrdinal` can grow too. The fresh-session refusal checks only the active pointer's session. A
provider wake turn whose prompt a hook blocks ends normally (empty task-notification result accepted, or a 2-minute
deadline); no retry loop.

0.10.1:
- `session_of_thread` mirrors that routing rule in SQL (rows started at or after the boundary and not by a scheduled
  fresh run, then the active pointer, then `lastRunOrdinal`, then `updated_at`). Checked against every multi-session
  thread in the live db: equal to the active pointer everywhere except 569772de, where it names 5d8bc668, and the
  scheduled-run Codex threads, where it follows T3's side-conversation rule.
- `t3.sh recover` first checks it: thread routed to another session → `REPLACED <session> successor|other`, nothing
  sent; the hook blocks the prompt (zero tokens), logs once per `WAKE_LOG_EVERY` (600 s) with a count. A stray real
  message there is blocked with "send it again". A `<task-notification>` into a stale session T3 still routes to is
  blocked too, without a recovery (it is not the user's message).
- The background-work ask needs both: the thread routes to the refused session and T3's active pointer is on it.
  Otherwise it is skipped and the pending outcome names the session holding the fresh start up. At most one ask per
  handoff (`state/<sid>.bgask`; a new `t3.sh clear` resets it). The pending outcome ("pending: T3 refuses …") shows in
  the Stop note, so the user sees why the handoff waits.
- Thread 383ac993 (one ask followed by "gave up after 600s"): the ask turn auto-compacted the session, which consumed
  the staged doc; the worker kept retrying a handoff that was no longer needed. The fresh worker now cancels when the
  per-thread doc is gone. The second give-up there (11:28) was an agent that kept a background job running on
  purpose; the pending note is all the plugin can add.
- Nudge race (also 569772de): Stop at 18:00:05 scheduled a nudge; a task-notification turn ran before it went out;
  that turn's Stop (18:00:17) scheduled a second nudge. The first went out at 18:00:20, the second waited for the next
  idle and went out at 18:01:16, 0.2 s before the fresh `/handoff:resume` (T3 runs 12 and 13), so the request re-ran
  in the session being replaced and re-published its doc. Now one pending nudge worker per session and text file
  (`state/<sid>.nudge-pending`), the Stop does not count an undelivered request as an attempt, and a nudge still
  waiting when the handoff gets scheduled (or the session is tombstoned) is dropped.

Verified: `tests/wake_test.sh` (29 cases, a replay of 569772de on a db with T3's routing tables). Live on T3 Code
0.1.12 (2026-11-25, scratch project, sonnet, threshold 66k): background `sleep 420` → nudge (one) → doc → fresh send
refused 58 times → one ask (the agent kept the sleep as told) → sleep ends, Claude wakes the live session → fresh
session adopted the doc in 1 s; runs: start, user turn, nudge, ask, wake, fresh; nothing else. T3 0.1.12 ended the old
process at the fresh start, so no real wake of a replaced process happened; the installed hook fed three
`<task-notification>` prompts as the old session against the live db: three blocks, one log line, nothing sent.

## Timeline

- v0.4.0: `/clear` + `/handoff:resume` sent with t3ctl. Silently broken by T3's db move.
- v0.5.0 (b44a8e6): reads `statev2.sqlite`; named preflight failures. Still cleared in place, so the bug above
  appeared (e7c1ec3a).
- v0.6.0 (f57d8f7): session alias + recovery of stuck threads. The successor-thread and `/compact` designs were
  built, tested and dropped along the way.
- T3 Code 0.1.9 (PR #30325): native fresh session in the same thread. Plugin 0.6.0 regressed on its manual path
  (composer `/clear` + `/handoff:resume` loaded "(none)").
- v0.7.0: fresh flow via t3ctl 0.8.0 `threads send --fresh`; per-thread staging adopted by the fresh session; the
  `/clear` + alias flow kept as fallback.
- T3 Code 0.1.10 (PR #35054, merged 2026-11-12): T3 records the session a Claude-side `/clear` starts. Plugin 0.7.0
  still aliased there (harmless), and its `/clear` flow broke (resume not sent; doc lost across the process swap).
- v0.7.1 (2026-11-18): alias only for T3 < 0.1.10 (server version); `/clear` flow follows T3's new id; per-session doc
  copy adopted by the process T3 starts for the first post-clear turn. Verified live on 0.1.10.
- v0.7.2 (2026-11-18): `SessionEnd(clear)` tombstones and bridges before the summarizer (Claude Code 2.1.327 killed
  the hook ~1 s into it, which lost the `/clear` chain); a fresh send refused for background work asks the agent once
  to stop it (the blocker seen in thread dbeea855, reproduced live). Verified live on 0.1.10.
- v0.8.0 – v0.10.0: Codex support, `T3_DEFER`, loop guard, doc size limit (see README).
- T3 Code 0.1.12 (2026-11-25): #38824 routes a user message to the newest session after the last fresh start, even
  when a woken replaced session holds the active pointer; more wake sources (#30214, #40170, #37875).
- v0.10.1 (2026-11-25): recovery only when T3 still routes the thread to the stale session; wakes of a replaced
  session blocked and logged, nothing sent (thread 569772de); routing mirrors T3 0.1.12; background-work ask only to
  the session T3 checks, once per handoff; fresh worker cancels when a compact consumed the doc (383ac993); no
  duplicate nudge. Verified live on 0.1.12 (see above).
