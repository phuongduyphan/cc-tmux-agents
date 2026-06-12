# cc-tmux-agents

**Let Claude Code talk to your other coding agents.** Like Claude Code subagents, but the subagents are codex, opencode, pi, etc. Delegate a task, watch it work, send follow-ups, interrupt it, and have Claude review the result. Steer it yourself, or hand the whole thing off and walk away.

▶️ **[Watch the demo](https://drive.google.com/file/d/1T907nvPSicOJVnYiTr1K-sAwm5Td6sjc/view?usp=sharing)**

## Why

- **Pay top rates only for the thinking.** A strong model earns its price on planning and review, which are light on tokens. Implementation is the token-heavy part, so running it on a cheaper agent is where the real savings are, without giving up the decisions.
- **Minimal setup, basic primitives, build your own workflows.** One mechanism (tmux) drives any agent, no per-vendor API, so a handful of composable primitives (start, check, tell, interrupt, wait, kill) is the whole surface. Steer a run by hand, or compose those primitives into something fully autonomous: `/autopilot` is one such workflow, and you can build your own.
- **Works everywhere, from your laptop to your phone.** It's all tmux over SSH. Kick off a run at your desk, then check on it, steer it, or start a new one from your phone.

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
/opencode what is this project about?
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

Every coding agent is just a TUI in a terminal, so the whole integration is a handful of tmux commands against the agent's pane. No per-vendor API, no SDK: if a tool runs in a terminal, Claude can drive it.

| What Claude does | How (tmux) |
|---|---|
| Type the task or a follow-up | `send-keys` into the pane |
| Read what the agent is doing | `capture-pane`, with ANSI codes stripped |
| Interrupt a wrong turn | `send-keys Escape` |
| Start or tear down a run | `new-session` / `kill-session` |
| Know the instant it finishes | a per-tool completion hook, falling back to watching the spinner |

A small bash dispatcher (`bin/<name>-agent`) wraps these into verbs, and a `SKILL.md` tells Claude which verb to use when. Claude decides what to do; the cheaper model inside the agent does the typing.

Two skill trees let either side be the boss:

- **`skills/` → `~/.claude/skills`** (Claude Code as boss): skills invoked as `/name`. `wait` runs as a backgrounded command, so the harness pings Claude the moment the worker goes idle. This powers `/autopilot`.
- **`agents-skills/` → `~/.agents/skills`** (codex, opencode, or pi as boss): the same dispatchers in the cross-agent format, invoked as `$name`. These harnesses can't background-and-wake, so `wait` runs in the foreground, and there's no `/autopilot`.

Install both and use whichever boss you're in.

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

## Why tmux instead of headless mode

Most agent CLIs offer a headless `run`/`exec` mode. These skills deliberately drive the interactive TUI over tmux instead:

- **You can watch and steer mid-run.** Headless is fire-and-forget; tmux lets you or Claude read progress, course-correct, and redirect before a wrong approach burns an hour.
- **Interrupting is free.** A bad turn is one `Escape` away, instead of waiting for a headless run to finish or killing the process and losing its state.
- **One integration for every tool.** Every agent has a terminal UI; not every agent has a stable headless API. tmux works for all of them, including tools that ship next month.
- **The session is durable and reachable.** It lives on the host, so you can detach, close your laptop, and reattach from another machine (or your phone) with the run still going.
- **Warm context instead of a cold start each turn.** A headless `run` spins up a fresh session every invocation, so the agent re-reads everything from scratch. A persistent tmux session stays alive across turns, so the prompt cache stays warm and follow-ups are cheaper and faster.
