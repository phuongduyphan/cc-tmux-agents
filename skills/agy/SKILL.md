---
name: agy
description: Delegate a coding task to an agy (Antigravity CLI) session managed via tmux. Invoked as /agy. User drives all progress checks and interventions — no auto-polling.
---

# /agy — delegate to agy (Antigravity CLI)

Spawns the `agy` CLI in a detached tmux session so Claude can offload work to it. The user stays in the loop: they ask Claude when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.claude/skills/agy/bin/agy-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `cc-agy`), launch `agy --dangerously-skip-permissions`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; agy queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until agy goes idle, then exit.** Run via a backgrounded Bash so the harness notifies Claude on completion (see "Auto-notify" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — `/quit` then `kill-session`. Destroys the tmux session.
- `list`             — list active `cc-agy*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `/agy <task>`                                                      | `start <task>`; reply "Started. Tell me when to check." |
| "check agy" / "progress" / "what's agy doing" / "ask agy for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt agy" / "esc agy"                                        | `keys Escape` → `capture`.                      |
| "tell agy: X" / "send agy: X"                                      | `send X`.                                       |
| "kill agy" / "stop agy"                                            | `stop`.                                         |

Rules:
- **Never auto-poll** by burning Claude turns on a `ScheduleWakeup`/timer. Only `capture` when the user asks — *or* arm the `wait` watcher (see Auto-notify), which polls inside a cheap background shell instead.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `cc-agy`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell agy to read it.

## Safety

`--dangerously-skip-permissions` lets agy run arbitrary shell commands without approval. For untrusted tasks, launch inside a git worktree or sandbox directory.


## Auto-notify (get pinged when agy finishes, no timer)

When the user wants to be told the moment agy is done — without Claude polling on a timer — arm a backgrounded watcher. The trick is entirely Claude-side: agy sends no signal. A background shell scrapes the pane and **exits when agy goes idle**, and the harness re-invokes Claude on that exit. The polling moves into a cheap shell loop; Claude is woken exactly once.

Trigger: `/agy <task>` together with "tell me when it's done" / "notify me" / "ping me when agy finishes". Do `start <task>`, then call the `wait` verb through a **backgrounded Bash**:

```
Bash(
  command: "~/.claude/skills/agy/bin/agy-agent wait",
  run_in_background: true,
  description: "wait for agy to go idle"
)
```

On exit the harness notifies Claude. Read the final stdout line for the state, then `capture` and report to the user:

| Watcher's last line | Means | Claude does on wake |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, tell the user / `send y` if they authorized it |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-arm `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or agy never started working | `capture` to confirm |

Notes:
- **Arm `wait` immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition. Capture only *after* the watcher wakes you.
- This is the **only** sanctioned auto-detection path. Don't substitute a `ScheduleWakeup` timer (that's autopilot's job, with its own skill).
- The watcher debounces: the working indicator briefly drops between steps, so `wait` requires it gone for `stable` secs (default 6) before declaring idle. Bump it for tasks with long gaps between steps.
- Re-arm after each `send` if you want a ping for that follow-up too — one `wait` covers one idle transition.
