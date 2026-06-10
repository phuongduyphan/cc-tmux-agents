---
name: pi
description: Delegate a coding task to a pi (pi-coding-agent) CLI session managed via tmux. Invoked as /pi. User drives all progress checks and interventions — no auto-polling.
---

# /pi — delegate to pi CLI

Spawns pi's TUI in a detached tmux session so Claude can offload work to it. The user stays in the loop: they ask Claude when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.claude/skills/pi/bin/pi-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `cc-pi`), launch `pi`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; pi queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until pi goes idle, then exit.** Run via a backgrounded Bash so the harness notifies Claude on completion (see "Auto-notify" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `cc-pi*` sessions.

## How to respond to the user

| User says                                                      | Do                                              |
|----------------------------------------------------------------|-------------------------------------------------|
| `/pi <task>`                                                   | `start <task>`; reply "Started. Tell me when to check." |
| "check pi" / "progress" / "what's pi doing" / "ask pi for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt pi" / "esc pi"                                      | `keys Escape` → `capture`.                      |
| "tell pi: X" / "send pi: X"                                    | `send X`.                                       |
| "kill pi" / "stop pi"                                          | `stop`.                                         |
| `/pi <task>` **+ "tell me when it's done" / "notify me" / "ping me when pi finishes"** | `start <task>`, then arm Auto-notify (below). |

Rules:
- **Never auto-poll** by burning Claude turns on a `ScheduleWakeup`/timer. Only `capture` when the user asks — *or* arm the `wait` watcher, which polls inside a cheap background shell instead.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Auto-notify (get pinged when pi finishes, no timer)

When the user wants to be told the moment pi is done — without Claude polling on a timer — arm a backgrounded watcher. The trick is entirely Claude-side: pi sends no signal. A background shell scrapes the pane and **exits when pi goes idle**, and the harness re-invokes Claude on that exit. The polling moves into a cheap shell loop; Claude is woken exactly once.

To arm it, after `start` (or after a `send`), call the `wait` verb through a **backgrounded Bash**:

```
Bash(
  command: "~/.claude/skills/pi/bin/pi-agent wait",
  run_in_background: true,
  description: "wait for pi to go idle"
)
```

On exit the harness notifies Claude. Read the final stdout line for the state, then `capture` and report to the user:

| Watcher's last line | Means | Claude does on wake |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, tell the user / `send y` if they authorized it |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-arm `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or pi never started working | `capture` to confirm |

Notes:
- **Arm `wait` immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition. Capture only *after* the watcher wakes you.
- This is the **only** sanctioned auto-detection path. Don't substitute a `ScheduleWakeup` timer (that's autopilot's job, with its own skill).
- The watcher debounces: pi briefly drops its working indicator between tool calls, so `wait` requires the indicator gone for `stable` secs (default 6) before declaring idle. Bump it for tasks with long gaps between steps.
- Re-arm after each `send` if you want a ping for that follow-up too — one `wait` covers one idle transition.

## Conventions

- Default session name: `cc-pi`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell pi to read it (e.g. `send "read /tmp/prompt.md and follow it"`).

## Safety & quirks

- pi's TUI prompts for tool permissions during the session. If the agent appears idle after activity, `capture` — it may be waiting on a confirmation prompt. Respond with `send y` (or whatever the prompt expects).
- pi reads model/provider/auth from its own config (`~/.pi/agent`) and env vars (e.g. `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`). If `start` fails with an auth error, run `pi` interactively once and use `/login` to set up a provider.
- For fully autonomous one-shot delegation without a TUI, use `pi -p "<task>"` via a background Bash instead of this skill.
