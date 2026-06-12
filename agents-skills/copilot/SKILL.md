---
name: copilot
description: Delegate a coding task to a GitHub Copilot CLI session managed via tmux. Invoke explicitly as $copilot. User drives all progress checks and interventions — no auto-polling.
---

# $copilot — delegate to GitHub Copilot CLI

Spawns Copilot CLI in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/copilot/bin/copilot-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-copilot`), launch `copilot --allow-all`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Copilot queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `codex-copilot*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `$copilot <task>` / "delegate to copilot"                          | `start <task>`, then run `wait` in the **foreground** (blocks this turn until copilot is idle); on return, `capture` + report. |
| `$copilot <task>` **+ "tell me when it's done" / "notify me"** | Same as `$copilot <task>`; foreground `wait` is already the default. |
| "check copilot" / "progress" / "what's copilot doing" / "ask copilot for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt copilot" / "esc copilot"                                | `keys Escape` → `capture`.                      |
| "tell copilot: X" / "send copilot: X"                              | `send X`.                                       |
| "kill copilot" / "stop copilot"                                    | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. For new tasks, run `wait` in the foreground by default (see "Wait for completion"), which blocks in one cheap shell loop instead of polling. Only `capture` separately when the user asks.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-copilot`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Copilot to read it.
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety

`--allow-all` is shorthand for `--allow-all-tools --allow-all-paths --allow-all-urls` — full autonomy: any tool, any path (including outside the cwd), any URL, no approval prompts. For untrusted tasks, launch inside a git worktree or downgrade to `--allow-all-tools` alone (paths outside cwd will then prompt interactively).


## Wait for completion

After `start` — and after any `send` that should produce another completion report — run the `wait` verb in the **foreground**. This is the default for `$copilot <task>`; the user does not need to say "tell me when it's done". It blocks the current turn in a single cheap shell loop and returns the instant copilot goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, copilot is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/copilot/bin/copilot-agent wait
```

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or copilot never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition.
- Detection is screen-scrape based: copilot sends no completion signal, so `wait` watches the working indicator (`BUSY_RE` at the top of the dispatcher). It debounces — the indicator must stay gone for `stable` secs (default 6) — so bump `stable` for tasks with long gaps between steps.
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
