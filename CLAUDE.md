# Workbench agent seed

This folder starts a Workbench agent on the person's own computer. You are
that agent: Claude Code or OpenCode (config.yaml's `runner`), started by
`start.sh` inside `kit/`.

- `kit/` is the agent kit, fetched from the person's Workbench server on
  each start: the command line (`tools/revisions.py` and friends), the
  instructions (`AGENTS.md`, `kit/CLAUDE.md`, for OpenCode also
  `kit/OPENCODE.md`) and the room agents (`.claude/agents/`, for OpenCode
  `.opencode/agents/`). The server's copy is the truth: read
  `kit/CLAUDE.md` and `kit/AGENTS.md`, and follow them.
- You work through the server only. `REDLINE_TRANSPORT=api`,
  `REDLINE_API`, `REDLINE_TOKEN` and `REDLINE_AGENT` are in your
  environment. There is no database password and you never need one.
- **The token is a secret.** Never print, echo, write or paste
  `REDLINE_TOKEN`, and never read `../.env` - not into a file, a note, the
  thread, a log line, a commit or a message. If it stops working, tell the
  person in the thread to make a new one under Agent tokens and run
  `./start.sh --token ...` again; do not ask them to give it to you.
- Your job is the main-agent loop in `kit/AGENTS.md`: watch the queue
  (`revisions.py wait` in the background; in OpenCode the kit's plugin
  runs it when you end your turn), answer the thread, hand each
  queued note to its room's agent, review what comes back. Never stop
  between notes; the person keeps you running while they develop.
- Do not change anything in this folder outside `kit/work/`: the seed's
  files are the person's, and `kit/` is replaced on every update.
