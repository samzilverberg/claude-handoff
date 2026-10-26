# T3 Code: `/clear` and the stale Claude session (decision record)

Status: **active workaround** since plugin v0.6.0 (2026-10-26). Upstream fix pending:
[pingdotgg/t3code#24152](https://github.com/pingdotgg/t3code/issues/24152) (open), PR
[#24168](https://github.com/pingdotgg/t3code/pull/24168) (open). A T3 maintainer reproduced the bug on main and
updated the PR on 2026-10-24.

This doc covers what broke, what we tried, what we measured, why we chose the symlink alias, and how to take it out
once T3 fixes the bug. The README's "T3 Code layer" section describes the current behaviour. This doc keeps the
reasoning behind it.

## The problem

- T3 Code (Beta) 0.1.x stores a thread's Claude session id once, when it creates the provider thread. It lives in
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

- **Unit/e2e with fakes:** `plugins/handoff/tests/t3_test.sh`, 80 cases. The fake t3ctl plays `/clear` by running the
  real SessionEnd/SessionStart hooks. Run the whole suite with `for t in tests/*.sh; do bash $t; done`; 111 cases in
  total.
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

## When upstream fixes it (exit plan)

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

## Timeline

- v0.4.0: `/clear` + `/handoff:resume` sent with t3ctl. Silently broken by T3's db move.
- v0.5.0 (b44a8e6): reads `statev2.sqlite`; named preflight failures. Still cleared in place, so the bug above
  appeared (e7c1ec3a).
- v0.6.0 (f57d8f7): session alias + recovery of stuck threads. The successor-thread and `/compact` designs were
  built, tested and dropped along the way.
