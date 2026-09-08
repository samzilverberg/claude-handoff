---
name: resume
description: Resume work from the handoff document staged by the previous context window of this session (after /clear). Use when the user says "resume", "continue from handoff", or right after a session-start note says a handoff is staged.
allowed-tools: Read
---

## Handoff from the previous context window of this session

!`d="${CLAUDE_PROJECT_DIR}/.claude/handoff"; p=$(ps -o ppid= -p $PPID | tr -d ' '); f="$d/by-pid/$p.md"; [ -s "$f" ] || f="$d/current.md"; if [ -s "$f" ]; then cat "$f"; else echo "(no handoff staged under $d)"; fi`

## Your task

The document above was written by the previous context window of this same conversation, at the user's request, just before the context was cleared. Treat it as the record of the work so far. Continue from "Next steps"; if "Open questions for the user" is non-empty, ask those first. $ARGUMENTS
