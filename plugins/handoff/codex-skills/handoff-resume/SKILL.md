---
name: handoff-resume
description: Resume work from the handoff document a previous Codex context of this conversation wrote (handoff plugin). Use when the user says "resume", "continue from handoff", or names a file under .claude/handoff/sessions/.
---

# Resume from a handoff document

1. Find the document: the path the user named, else the newest file in `.claude/handoff/sessions/` of the project root
   (`ls -t .claude/handoff/sessions/*.md | head -1`). If there is none, say so and stop.
2. Read the whole file. It was written by the previous context of this conversation just before it was cleared, at the
   user's request: treat it as the record of the work so far.
3. Compare the repository with the document's "Workspace identity" section (branch, HEAD, uncommitted files). If it
   differs in a way the document does not explain, tell the user what differs before changing anything.
4. Continue from "Next steps". If "Open questions for the user" is non-empty, ask those first. A step that waits for
   the user (their confirmation, an answer, a "go") stays waiting: say briefly where things stand and stop.
