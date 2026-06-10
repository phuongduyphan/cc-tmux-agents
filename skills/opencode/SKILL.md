---
name: opencode
description: Delegate a coding task to an Opencode CLI session managed via tmux. Invoked as /opencode. User drives all progress checks and interventions — no auto-polling.
---

# /opencode — delegate to Opencode CLI

Spawns Opencode's TUI in a detached tmux session so Claude can offload work to it. The user stays in the loop: they ask Claude when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.claude/skills/opencode/bin/opencode-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `cc-opencode`), launch `opencode`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Opencode queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until opencode goes idle, then exit.** Run via a backgrounded Bash so the harness notifies Claude on completion (see "Auto-notify" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `cc-opencode*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `/opencode <task>`                                                 | `start <task>`; reply "Started. Tell me when to check." |
| "check opencode" / "progress" / "what's opencode doing" / "ask opencode for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt opencode" / "esc opencode"                              | `keys Escape` → `capture`.                      |
| "tell opencode: X" / "send opencode: X"                            | `send X`.                                       |
| "kill opencode" / "stop opencode"                                  | `stop`.                                         |

Rules:
- **Never auto-poll** by burning Claude turns on a `ScheduleWakeup`/timer. Only `capture` when the user asks — *or* arm the `wait` watcher (see Auto-notify), which polls inside a cheap background shell instead.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `cc-opencode`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Opencode to read it.

## Safety & quirks

- The Opencode TUI has **no `--dangerously-skip-permissions` flag** (that flag only applies to `opencode run`). The TUI will prompt for tool permissions during the session. If you see the agent sitting idle after apparent activity, `capture` — it may be waiting on a permission prompt that needs `send y` or similar.
- For fully autonomous one-shot delegation, consider `opencode run --dangerously-skip-permissions "<task>"` via a background Bash instead of this skill.


## Auto-notify (get pinged when opencode finishes, no timer)

When the user wants to be told the moment opencode is done — without Claude polling on a timer — arm a backgrounded watcher. The trick is entirely Claude-side: opencode sends no signal. A background shell scrapes the pane and **exits when opencode goes idle**, and the harness re-invokes Claude on that exit. The polling moves into a cheap shell loop; Claude is woken exactly once.

Trigger: `/opencode <task>` together with "tell me when it's done" / "notify me" / "ping me when opencode finishes". Do `start <task>`, then call the `wait` verb through a **backgrounded Bash**:

```
Bash(
  command: "~/.claude/skills/opencode/bin/opencode-agent wait",
  run_in_background: true,
  description: "wait for opencode to go idle"
)
```

On exit the harness notifies Claude. Read the final stdout line for the state, then `capture` and report to the user:

| Watcher's last line | Means | Claude does on wake |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, tell the user / `send y` if they authorized it |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-arm `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or opencode never started working | `capture` to confirm |

Notes:
- **Arm `wait` immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition. Capture only *after* the watcher wakes you.
- This is the **only** sanctioned auto-detection path. Don't substitute a `ScheduleWakeup` timer (that's autopilot's job, with its own skill).
- The watcher debounces: the working indicator briefly drops between steps, so `wait` requires it gone for `stable` secs (default 6) before declaring idle. Bump it for tasks with long gaps between steps.
- Re-arm after each `send` if you want a ping for that follow-up too — one `wait` covers one idle transition.
