# cc-tmux-agents

<p align="">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey" alt="macOS and Linux">
  <img src="https://img.shields.io/badge/built%20with-Bash%20%2B%20tmux-green" alt="Built with Bash and tmux">
</p>

> Cross-agent orchestration for Claude Code, Codex, OpenCode, and other coding CLIs

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)"  srcset="https://github.com/user-attachments/assets/2c919775-71db-49af-8d58-10182a209745">
    <source media="(prefers-color-scheme: light)" srcset="https://github.com/user-attachments/assets/42d99f60-c8ec-4ed9-befe-0b8e74c0db81">
    <img src="https://github.com/user-attachments/assets/42d99f60-c8ec-4ed9-befe-0b8e74c0db81" alt="Let Claude Code talk to your other coding agents" width="100%">
  </picture>
</p>


## Why this project

- **Cross-agent communication.** Let Claude Code, Codex, OpenCode, Pi, and other coding CLIs work with each other.
- **Lightweight by design.** Connect the coding CLIs you already use through simple tmux-based skills and shell commands.
- **Lower model costs.** Keep planning and review on a stronger model while moving token-heavy implementation to a cheaper worker.

## What it does

Use one coding agent to work with another. For example, Claude Code can ask Codex or OpenCode to implement a feature, monitor its progress, send corrections, interrupt it when it goes in the wrong direction, and review the finished changes.

The worker runs inside a persistent tmux session, so both you and the supervising agent can inspect or steer it at any time, including remotely over SSH. The integration uses small Bash dispatchers and reusable skills, with no central orchestration server or vendor-specific API.

In this README, the agent that supervises the work is the **boss**. The agent running inside tmux is the **worker**.

https://github.com/user-attachments/assets/824acaf6-e4ba-461c-bed9-cc6775d43233

## tmux versus headless mode

Most coding-agent CLIs also offer a headless `run` or `exec` command. That works well for one-shot jobs. This project uses tmux when you want the worker to remain alive, visible, and steerable.

| | tmux (this project) | headless `run` / `exec` |
|---|---|---|
| Mid-run control | attach, inspect, redirect, or interrupt | often designed for one-shot execution; capabilities vary by CLI |
| Follow-ups | continue inside the same live session | continuity depends on the tool and invocation mode |
| Coverage | works with terminal-based CLIs | requires a supported headless interface |
| Remote access | detach and reattach from another computer or phone | usually controlled by the invoking process or wrapper |
| Context | keeps the worker session warm across turns | may start a new session for each invocation |

## Quick start

```bash
git clone https://github.com/phuongduyphan/cc-tmux-agents.git ~/code/cc-tmux-agents
cd ~/code/cc-tmux-agents
./install.sh                 # all skills; or: ./install.sh --skills "pi opencode autopilot"
./doctor                     # verify the setup
./doctor --smoke opencode    # optional live end-to-end test
```

Then, in Claude Code:

```text
/opencode what is this project about?
```

Claude starts OpenCode in a tmux session, sends it the task, and waits in the background. You can continue using Claude, check what OpenCode is doing, send it another instruction, or wait for Claude to notify you when it finishes.

`install.sh` touches only this project's skill folders. Re-run it after `git pull`, or use `--link` so updates are picked up through symlinks.

<details>
<summary><b>Prerequisites</b></summary>

- **tmux**
- **perl** for stripping ANSI codes from captured terminal output
- **Claude Code, Codex, OpenCode, or Pi** as the boss
- The worker CLIs you want to use, installed and authenticated

The dispatchers support macOS and Linux with BSD/GNU fallbacks. On remote Linux hosts, authenticate each CLI once before relying on unattended runs.

The installer also creates `~/.config/cc-agents/env` with mode `600`. Put worker-specific provider keys there, such as `ZAI_API_KEY`. The Pi dispatcher reads this file instead of loading your full shell environment.

</details>

## Supported agents

Some agents can supervise workers, while others currently work only as workers.

| Agent | Boss | Worker | Notes |
|---|:---:|:---:|---|
| Claude Code | yes (`/name`) | yes | Worker when Codex, OpenCode, or Pi is the boss. |
| Codex | yes (`$name`) | yes | Worker when Claude Code is the boss. |
| OpenCode | yes (`$name`) | yes | Boss or worker. |
| Pi | yes (`$name`) | yes | Boss or worker. |
| Cursor (`agent`) | no | yes | Worker only. |
| Copilot | no | yes | Worker only. |
| Droid (Factory AI) | no | yes | Worker only. |
| Agy (Antigravity) | no | yes | Worker only. |

## The six worker actions

Every worker skill supports the same six actions. For example, Claude Code can start OpenCode, read what it is doing, send another instruction, interrupt it, wait for it, or stop it.

| Action | You say | What happens | Dispatcher verb |
|---|---|---|---|
| **start** | `/opencode <task>` | launch the worker in tmux and send it the task | `start` |
| **check** | "check opencode" | read the terminal and summarize recent progress | `capture` |
| **tell** | "tell opencode: X" | send a follow-up into the same session | `send` |
| **interrupt** | "interrupt opencode" | send `Escape` to stop the current turn | `keys Escape` |
| **wait** | "tell me when it's done" | wait until the worker goes idle, then notify the boss | `wait` |
| **kill** | "kill opencode" | tear down the worker session | `stop` |

These actions are the foundation of the project. `/autopilot` combines them into one ready-made workflow, and you can combine them differently in your own `SKILL.md`.

You can also watch a worker directly:

```bash
tmux attach -t cc-opencode
```

## `/autopilot`

<img width="1249" height="535" alt="image" src="https://github.com/user-attachments/assets/22dbbc22-dab0-4c00-84e0-a891498d96a9" />

`/autopilot` is a ready-made Claude Code skill for supervising another coding agent.

For example, Claude can give a task to Codex, periodically check its work, correct it when it goes in the wrong direction, run the relevant tests, and review the final diff before reporting back to you.

It is similar in spirit to `[/workflow](https://code.claude.com/docs/en/workflows)` in Claude Code or `[/goal](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex)` in Codex, except the supervisor and worker can be different CLI agents.

```text
/autopilot <pi|opencode|codex|cursor> <task description>
```

`/autopilot` is built as a normal [`SKILL.md`](skills/autopilot/SKILL.md) using the same worker actions. It is one example workflow, and you can create your own skills in the same way.

## Workflow examples

### Claude plans, Codex implements

```text
# Work with Claude to create PLAN.md
/codex implement PLAN.md and run the test suite
"tell me when it's done"
```

When Codex finishes, Claude reads the diff and reviews the implementation.

### Redirect a worker mid-run

```text
"check pi"
"interrupt pi"
"tell pi: leave auth/ alone; the bug is in session/store.ts:42"
```

The Pi session stays alive, so it keeps its previous context and continues from your correction.

### Monitor from a phone with Termius

Install a mobile SSH client such as [Termius](https://termius.com/), connect to your development machine, and attach to the worker:

```bash
tmux attach -t cc-opencode
```

### Build your own cross-agent skill

`/autopilot` is a Claude Code skill that combines the existing worker actions into a supervision workflow.

You can create your own skill in the same way. For example, an `implement-and-review` skill could:

1. ask Codex to implement a feature;
2. wait until Codex finishes;
3. inspect the diff and run the tests;
4. ask OpenCode to review the result;
5. send any requested fixes back to Codex;
6. report the final result.

Create your own `SKILL.md` by combining the same worker actions. See [`skills/autopilot/SKILL.md`](skills/autopilot/SKILL.md) for a complete example.

## How this compares

- **Claude Code subagents:** Claude works with another Claude instance. This project lets Claude work with Codex, OpenCode, Pi, or another independent CLI.
- **Claude Code workflows or Codex goals:** those features run a workflow inside one product. `/autopilot` can supervise a worker from a different CLI.
- **Full orchestration platforms:** those projects may add dashboards, task queues, databases, schedulers, and fleet management. This project stays focused on lightweight skills and shell commands for agents running on one host.

## Security

<details>
<summary><b>Read before unattended runs</b></summary>

- Some workers run with relaxed approval or sandbox settings so they do not stall.
- OpenCode and Pi do not provide an OS sandbox. For autonomous runs, use a dedicated container or VM with limited credentials and only the required worktree.
- Keep secrets and push credentials out of the worker environment, and review the blast radius before using `/autopilot`.

</details>

## License

See [LICENSE](LICENSE).
