---
name: setup
description: One-time project setup for the handoff plugin: create .claude/handoff, gitignore it, and optionally add the CLAUDE.md import so a staged handoff loads automatically after /clear (zero-keystroke mode).
disable-model-invocation: true
allowed-tools: Bash(mkdir *), Bash(printf *), Bash(grep *), Edit, Write, Read
---

Set up the handoff plugin in `$CLAUDE_PROJECT_DIR`:

1. `mkdir -p .claude/handoff` and write `# Handoff\n(none)\n` to `.claude/handoff/current.md` if it does not exist.
2. Ensure `.gitignore` contains `.claude/handoff/`.
3. If the user passed `--import` in "$ARGUMENTS" (or asks for automatic loading): append the following block to the project `CLAUDE.md` (create it if missing) unless it is already there:

```
## Previous conversation (auto-maintained by the handoff plugin)
After /clear or compaction, the handoff written at the end of the previous context window of this session is
staged in `.claude/handoff/current.md` and included below. Continue from its "Next steps". If a session-start
note says this section belongs to another session, ignore it.

@.claude/handoff/current.md
```

Without `--import`, the handoff is loaded on demand with `/handoff:resume` instead (recommended when several sessions share this directory).

4. Report what you changed and remind the user: set the threshold via `/plugin manage` → handoff, or `HANDOFF_THRESHOLD` in the `env` block of settings.json; set `/autocompact 400k` (or `"autoCompactWindow": 400000` in settings.json) about 100k above the threshold.
