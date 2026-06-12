# cc-agents

Claude Code skills that let Claude drive other coding agents (pi, opencode, codex, cursor,
copilot, droid, agy) through tmux, plus `/autopilot`, an autonomous orchestrator that
delegates a task to one of those agents and babysits it to completion: checkpoints every 10
minutes, breaks thinking loops, ground-truths progress against the actual diff, reviews the
result, and logs every autonomous decision.

The idea: every coding agent is just a TUI in a terminal, so the whole integration surface is
`tmux send-keys` (type into its prompt), `tmux capture-pane` (read its screen), and
`tmux send-keys Escape` (interrupt it). Claude plays the boss; a cheap open model does the
typing. No APIs, no vendor cooperation.

## What's inside

```
skills/<name>/SKILL.md     the contract Claude reads (verb table + rules)
skills/<name>/bin/<name>-agent   the tmux dispatcher that implements it
skills/autopilot/SKILL.md  the autonomous orchestrator (wraps the dispatchers)
agents-skills/<name>/      same dispatchers in the cross-agent Agent Skills
                           format, for codex/opencode/pi as the ORCHESTRATOR
hooks/                     per-tool completion hooks (exact done-detection)
install.sh                 symlinks both trees, installs hooks
doctor                     verifies the setup; optional live smoke test
```

## Two skill trees: pick your orchestrator

**`skills/` → `~/.claude/skills`** is for **Claude Code as the boss**. Skills are invoked as
`/name`. Completion waiting is fully async and armed by default for plain delegation: Claude
runs `wait` as a backgrounded command after `start`, and the harness pings it the instant the
worker finishes (this also powers `/autopilot`). If a future worker lacks a `wait` primitive,
fall back to the old user-driven flow: start it and tell the user to ask when they want a check
or completion ping.

**`agents-skills/` → `~/.agents/skills`** is the same dispatchers in the cross-agent Agent
Skills format, for when **codex, opencode, or pi is the boss**. Skills are invoked as
`$name`, sessions are prefixed `codex-*`, and the worker set includes **claude** and
**gemini**. One behavioral difference: those harnesses can't background a command and get
re-invoked when it exits, so `wait` runs in the **foreground** (the orchestrator blocks for
that turn until the worker goes idle). There is no `/autopilot` equivalent in this tree for
the same reason: no background wake-up, no checkpoint loop.

Install both, use whichever boss you're in.

## Prerequisites

- **tmux** (any reasonably modern version; the dispatchers avoid the tmux ≥ 3.2 `-e` flag)
- **perl** (used to strip ANSI codes from captured panes; preinstalled on macOS and almost
  every Linux distro)
- **Claude Code** as the orchestrator
- The agent CLIs you actually want to drive, installed and **authed** (`pi`, `opencode`,
  `codex`, cursor's `agent`, `copilot`, `droid`, `agy`). Skills for tools you don't have are
  inert; install only what you use with `--skills`.

Works on macOS and Linux (the dispatchers are bash, with BSD/GNU fallbacks where they
differ). On Linux servers note that the agent CLIs' own OAuth flows may need a browser; auth
each tool once before relying on the skills.

## Install

```bash
git clone <this-repo> ~/code/cc-agents
cd ~/code/cc-agents
./install.sh            # all skills; or: ./install.sh --skills "pi opencode autopilot"
./doctor                # verify
./doctor --smoke opencode   # optional ~30s live end-to-end test
```

`install.sh` symlinks the skills, so `git pull` updates them in place. It also:

- installs the **completion hooks** for the tools present on the machine (pi `agent_end`
  extension, opencode `session.idle` plugin, codex `notify` program registered in
  `~/.codex/config.toml`, cursor `stop` hook in `~/.cursor/hooks.json`). These give the
  `wait` verb exact done-detection; without a hook it falls back to watching the spinner.
- creates `~/.config/cc-agents/env` (chmod 600). Put the model-provider API keys your
  workers need there (e.g. `ZAI_API_KEY=...`). The pi dispatcher sources this file instead
  of your shell rc, so workers get only those keys, not your whole environment. If the file
  is absent it falls back to launching through your login shell.

## Use

In Claude Code:

| You say | What happens |
|---|---|
| `/opencode <task>` | starts a tmux session running opencode, types the task, and arms backgrounded `wait` by default |
| "check opencode" | captures the pane, shows the tail, one-line diagnosis |
| "tell opencode: X" | queues a follow-up into the same session |
| "interrupt opencode" | sends Escape |
| "tell me when it's done" | already the default for plain delegation; Claude is pinged on completion |
| "kill opencode" | tears the session down |
| `/autopilot opencode <task>` | fully autonomous: checkpoints, course-corrections, final review, decision log at `/tmp/cc-autopilot-<agent>-decisions.md` |

You can always look over an agent's shoulder yourself: `tmux attach -t cc-opencode`
(detach with `ctrl-b d`), from any machine that can SSH in.

## Security notes, read before unattended runs

- Some dispatchers launch their tool with permissions relaxed so unattended runs don't
  stall: codex defaults to `--dangerously-bypass-approvals-and-sandbox`, agy to
  `--dangerously-skip-permissions`, copilot to `--allow-all`, cursor to `--force`. For
  codex you can override via `CC_CODEX_ARGS` (e.g. `CC_CODEX_ARGS="--full-auto"` keeps the
  OS sandbox on and lets the orchestrator answer approval prompts through the pane).
- opencode and pi have **no OS sandbox at all** (their permission prompts are UX, not
  isolation). For overnight/autonomous runs, prefer a dedicated container or VM with the
  worktree, the toolchain, and the one API key, and nothing else.
- Keep workers in per-task git worktrees without push credentials, and keep secrets out of
  the workspace.

## Troubleshooting

- **`start` times out / `wait` never fires.** The dispatchers detect TUI state with two
  regexes per tool (`READY_RE`, `BUSY_RE`, near the top of each `bin/<name>-agent`). Tool
  UIs change between versions; if a tool updated and broke detection, run
  `<name>-agent capture` to see the actual screen text and adjust the regex. PRs welcome.
- **`wait` reports spinner-fallback instead of the hook.** Run `./doctor`: the hook file or
  its registration is missing for that tool.
- **pi starts but errors about API keys.** Add the provider key to
  `~/.config/cc-agents/env`.
- **Session already running.** Each skill uses one named session (e.g. `cc-pi`). Run
  `<name>-agent stop` or use `--session <other-name>` for parallel sessions.

## Background

Why tmux instead of headless `run`/`exec` modes, how the checkpoint loop breaks cheap-model
thinking loops, and the plan-once-delegate-many workflow these skills enact: see the
internal talk "Working with coding agents without a blank check".
