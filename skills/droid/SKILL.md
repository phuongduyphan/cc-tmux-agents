---
name: droid
description: Delegate a coding task to a Droid (Factory AI) CLI session managed via tmux. Invoked as /droid. User drives all progress checks and interventions — no auto-polling.
---

# /droid — delegate to Droid CLI

Spawns Droid's TUI (Factory's AI coding agent) in a detached tmux session so Claude can offload work to it. The user stays in the loop: they ask Claude when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.claude/skills/droid/bin/droid-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `cc-droid`), launch `droid`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Droid queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until droid goes idle, then exit.** Run via a backgrounded Bash so the harness notifies Claude on completion (see "Auto-notify" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `cc-droid*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `/droid <task>`                                                    | `start <task>`, then arm Auto-notify (below); reply "Started. I'll ping you when droid finishes." |
| "check droid" / "progress" / "what's droid doing" / "ask droid for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt droid" / "esc droid"                                    | `keys Escape` → `capture`.                      |
| "tell droid: X" / "send droid: X"                                  | `send X`.                                       |
| "kill droid" / "stop droid"                                        | `stop`.                                         |

Rules:
- **Never auto-poll** by burning Claude turns on a `ScheduleWakeup`/timer. For new tasks, arm the `wait` watcher by default (see Auto-notify), which polls inside a cheap background shell instead. Only `capture` when the user asks.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `cc-droid`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Droid to read it.

## Safety & quirks

- The Droid TUI defaults to **"Auto (Off) — all actions require approval"**, so Droid will pause on tool calls and wait for approval. If the agent sits idle after apparent activity, `capture` — it may be waiting on a permission prompt. Use `send y` / `send 1` or `keys Enter` to answer.
- To run with auto-approval, ask the user whether to toggle autonomy inside the TUI (`ctrl+L`) or start Droid differently. Do not enable autonomy without user consent.
- For fully autonomous one-shot delegation, consider `droid exec "<task>"` via a background Bash instead of this skill.
- While Droid is generating, the status line shows `Streaming...` / `Press ESC to stop`. The `[⏱ Ns]` timer in the footer is the **last response duration**, not a live processing signal — don't use it to infer activity.


## Auto-notify (get pinged when droid finishes, no timer)

After `start` — and after any `send` that should produce another completion ping — arm a backgrounded watcher. This is the default for `/droid <task>`; the user does not need to say "tell me when it's done". The trick is entirely Claude-side: droid sends no signal. A background shell scrapes the pane and **exits when droid goes idle**, and the harness re-invokes Claude on that exit. The polling moves into a cheap shell loop; Claude is woken exactly once.

To arm it, call the `wait` verb through a **backgrounded Bash**:

```
Bash(
  command: "~/.claude/skills/droid/bin/droid-agent wait",
  run_in_background: true,
  description: "wait for droid to go idle"
)
```

On exit the harness notifies Claude. Read the final stdout line for the state, then `capture` and report to the user:

| Watcher's last line | Means | Claude does on wake |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, tell the user / `send y` if they authorized it |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-arm `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or droid never started working | `capture` to confirm |

Notes:
- **Arm `wait` immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition. Capture only *after* the watcher wakes you.
- This is the **only** sanctioned auto-detection path. Don't substitute a `ScheduleWakeup` timer (that's autopilot's job, with its own skill).
- The watcher debounces: the working indicator briefly drops between steps, so `wait` requires it gone for `stable` secs (default 6) before declaring idle. Bump it for tasks with long gaps between steps.
- Re-arm after each `send` if you want a ping for that follow-up too — one `wait` covers one idle transition.
