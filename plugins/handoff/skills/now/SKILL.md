---
name: now
description: Hand this conversation off to a fresh context now, before the context threshold, optionally continuing on another model or effort (T3 Code). Usage: /handoff:now [model] [effort] [note].
argument-hint: "[model] [effort] [note for the next context]"
disable-model-invocation: true
allowed-tools: Write, Read
---

The user asked to hand this conversation off now (`/handoff:now $ARGUMENTS`), before the context threshold: it continues
in a fresh context (under T3 Code, a fresh session of this thread, on the model and effort they named, if any).

The handoff plugin added a note to this prompt with the exact document path and its sections. Write the handoff
document now, as that note says, then stop. Do not continue the task in this context, and do not act on the model or
effort yourself: the plugin passes them, and the user's note, on to the fresh session.

If there is no such note from the handoff plugin in this turn, its hook did not run: tell the user so in one line
(`/handoff:status` shows the hook log) and stop.
