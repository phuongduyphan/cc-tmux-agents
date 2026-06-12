# cc-tmux-agents

**Let Claude Code talk to your other coding agents.** Like Claude Code subagents, but the subagents are codex, opencode, pi, etc. Delegate a task, watch it work, send follow-ups, interrupt it, and have Claude review the result. Steer it yourself, or hand the whole thing off and walk away.

Running a high-end model (Claude, Codex) for *everything* is expensive, and most of that cost is implementation, the line-by-line typing, not the thinking. So split the work: keep Claude for planning, discussing, and reviewing, where judgment pays off, and hand the bulk implementation to a cheaper agent. You pay premium rates only for the small, high-leverage part.

The trick that makes it work: every coding agent is just a TUI in a terminal. So the entire integration surface is three tmux commands: `send-keys` to type into its prompt, `capture-pane` to read its screen, and `send-keys Escape` to interrupt it. Claude plays the boss; a cheaper model does the typing. No APIs, no SDKs, no vendor cooperation. If a tool runs in a terminal, Claude can drive it.

<!-- DEMO: replace with an asciinema GIF. Suggested capture (~30s):
     1. /autopilot opencode "add a --json flag to the status command"
     2. show the checkpoint ping firing
     3. show Claude reviewing the diff and reporting done
     Record with:  asciinema rec demo.cast   then   agg demo.cast demo.gif
-->
![demo](docs/demo.gif)

## Why

- **Pay top rates only for the thinking.** A strong model earns its price on planning and review, which are light on tokens. Implementation is the token-heavy part, so running it on a cheaper agent is where the real savings are, without giving up the decisions.
- **Cheap workers drift; a strong orchestrator keeps them honest.** Cheaper models loop, wander, and stall. Keeping Claude in the loop as the boss keeps the worker pointed at the goal.
- **One mechanism drives every tool.** No per-vendor API. tmux works for any TUI, including tools that ship next month.
- **Semi-auto or fully auto, same primitives.** Look over the agent's shoulder and steer when you want (`tmux attach`), or run `/autopilot` and let Claude checkpoint, course-correct, and review on its own.
- **A foundation for autonomous workflows.** The verbs (start, check, tell, interrupt, wait, kill) are composable. `/autopilot` is one workflow built on them; you can build your own.

## Quick start

```bash
git clone <this-repo> ~/code/cc-tmux-agents
cd ~/code/cc-tmux-agents
./install.sh                 # all skills; or: ./install.sh --skills "pi opencode autopilot"
./doctor                     # verify the setup
./doctor --smoke opencode    # optional ~30s live end-to-end test
```

`install.sh` symlinks the skills into place by default, so `git pull` updates them with no reinstall (pass `--copy` to install copies instead, which then need a re-run after each pull). Then, in Claude Code:

```
/opencode add a --json flag to the status command
```

That starts a tmux session running opencode, types the task, and (by default) arms a background `wait` so Claude is pinged the instant the worker finishes.

## What you can do

| You say | What happens |
|---|---|
| `/opencode <task>` | starts a tmux session running opencode, types the task, arms a backgrounded `wait` |
| "check opencode" | captures the pane, shows the tail, gives a one-line diagnosis |
| "tell opencode: X" | queues a follow-up into the same session |
| "interrupt opencode" | sends Escape |
| "tell me when it's done" | the default for plain delegation; Claude is pinged on completion |
| "kill opencode" | tears the session down |
| `/autopilot opencode <task>` | fully autonomous: checkpoints every 10 min, course-corrects, final review, decision log |

**Semi-auto:** delegate, then watch and steer. You can always look over an agent's shoulder with `tmux attach -t cc-opencode` (detach with `ctrl-b d`), from any machine that can SSH in.

**Fully auto:** `/autopilot <agent> <task>` hands the whole job to Claude. It arms two wake sources, checkpoints the worker every 10 minutes (interrupt, read progress, course-correct), breaks thinking loops, ground-truths progress against the actual diff, reviews the result, and logs every autonomous decision to `/tmp/cc-autopilot-<agent>-decisions.md`.

Supported workers: **pi, opencode, codex, cursor, copilot, droid, agy** (plus **claude** and **gemini** when another agent is the boss, see below).

## How it works

There are two skill trees, so any agent can be the boss:

- **`skills/` → `~/.claude/skills`** is for **Claude Code as the boss**. Skills are invoked as `/name`. Completion waiting is fully async: Claude runs `wait` as a backgrounded command, and the harness pings it the moment the worker goes idle. This is what powers `/autopilot`.
- **`agents-skills/` → `~/.agents/skills`** is the same dispatchers in the cross-agent Agent Skills format, for when **codex, opencode, or pi is the boss**. Skills are invoked as `$name`. One difference: those harnesses can't background a command and get re-woken, so `wait` runs in the foreground (the orchestrator blocks for that turn, then reports). There's no `/autopilot` here for the same reason: no background wake-up, no checkpoint loop.

Install both and use whichever boss you're in. Each skill is a `SKILL.md` (the contract Claude reads: a verb table plus rules) backed by a small bash dispatcher (`bin/<name>-agent`) that does the actual tmux work. Per-tool completion hooks give the `wait` verb exact done-detection instead of watching a spinner.

```
skills/<name>/SKILL.md          the contract Claude reads (verbs + rules)
skills/<name>/bin/<name>-agent  the tmux dispatcher that implements it
skills/autopilot/               the autonomous orchestrator (wraps the dispatchers)
agents-skills/<name>/           same dispatchers, cross-agent format (codex/opencode/pi as boss)
hooks/                          per-tool completion hooks (exact done-detection)
install.sh                      symlinks both trees, installs hooks
doctor                          verifies the setup; optional live smoke test
```

<details>
<summary><b>Prerequisites</b></summary>

- **tmux** (any reasonably modern version; the dispatchers avoid the tmux ≥ 3.2 `-e` flag)
- **perl** (strips ANSI codes from captured panes; preinstalled on macOS and almost every Linux distro)
- **Claude Code** as the orchestrator
- The agent CLIs you want to drive, installed and **authed** (`pi`, `opencode`, `codex`, cursor's `agent`, `copilot`, `droid`, `agy`). Skills for tools you don't have are inert; install only what you use with `--skills`.

Works on macOS and Linux (the dispatchers are bash, with BSD/GNU fallbacks). On Linux servers, the agent CLIs' own OAuth flows may need a browser, so auth each tool once before relying on the skills.

The installer also creates `~/.config/cc-agents/env` (chmod 600). Put the model-provider API keys your workers need there (e.g. `ZAI_API_KEY=...`). The pi dispatcher sources this file instead of your shell rc, so workers get only those keys, not your whole environment. If the file is absent it falls back to your login shell.
</details>

<details>
<summary><b>Security (read before unattended runs)</b></summary>

- Some dispatchers launch their tool with permissions relaxed so unattended runs don't stall: codex defaults to `--dangerously-bypass-approvals-and-sandbox`, agy to `--dangerously-skip-permissions`, copilot to `--allow-all`, cursor to `--force`. For codex you can override via `CC_CODEX_ARGS` (e.g. `CC_CODEX_ARGS="--full-auto"` keeps the OS sandbox on and lets the orchestrator answer approval prompts through the pane).
- opencode and pi have **no OS sandbox at all** (their permission prompts are UX, not isolation). For overnight or autonomous runs, prefer a dedicated container or VM holding only the worktree, the toolchain, and the one API key.
- Keep workers in per-task git worktrees without push credentials, and keep secrets out of the workspace.
</details>

<details>
<summary><b>Troubleshooting</b></summary>

- **`start` times out / `wait` never fires.** The dispatchers detect TUI state with two regexes per tool (`READY_RE`, `BUSY_RE`, near the top of each `bin/<name>-agent`). Tool UIs change between versions; if a tool updated and broke detection, run `<name>-agent capture` to see the actual screen text and adjust the regex. PRs welcome.
- **`wait` reports spinner-fallback instead of the hook.** Run `./doctor`: the hook file or its registration is missing for that tool.
- **pi starts but errors about API keys.** Add the provider key to `~/.config/cc-agents/env`.
- **Session already running.** Each skill uses one named session (e.g. `cc-pi`). Run `<name>-agent stop` or use `--session <other-name>` for parallel sessions.
</details>

## Background

Why tmux instead of headless `run`/`exec` modes, how the checkpoint loop breaks cheap-model thinking loops, and the plan-once-delegate-many workflow these skills enact: see the internal talk "Working with coding agents without a blank check".
</content>
</invoke>
