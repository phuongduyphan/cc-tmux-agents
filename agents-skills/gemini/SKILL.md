---
name: gemini
description: Delegate a coding task to a Gemini CLI session managed via tmux. Invoke explicitly as $gemini. User drives all progress checks and interventions — no auto-polling.
---

# $gemini — delegate to Gemini CLI

Spawns Gemini CLI in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/gemini/bin/gemini-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-gemini`), launch `gemini --yolo`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Gemini queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — `/quit` then `kill-session`. Destroys the tmux session.
- `list`             — list active `codex-gemini*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `$gemini <task>` / "delegate to gemini"                            | `start <task>`; reply "Started. Tell me when to check." |
| `$gemini <task>` **+ "tell me when it's done" / "notify me"** | `start <task>`, then run `wait` in the **foreground** (blocks this turn until gemini is idle); on return, `capture` + report. |
| "check gemini" / "progress" / "what's gemini doing" / "ask gemini for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt gemini" / "esc gemini"                                  | `keys Escape` → `capture`.                      |
| "tell gemini: X" / "send gemini: X"                                | `send X`.                                       |
| "kill gemini" / "stop gemini"                                      | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. Only act when the user asks — or run `wait` in the foreground (see "Wait for completion"), which blocks in one cheap shell loop instead of polling.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-gemini`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Gemini to read it.
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety

`--yolo` lets Gemini run arbitrary shell commands without approval. For untrusted tasks, launch inside a git worktree or sandbox directory.


## Wait for completion

When you want to know the moment gemini is done, run the `wait` verb in the **foreground** right after `start` (or a follow-up `send`). It blocks the current turn in a single cheap shell loop and returns the instant gemini goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, gemini is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/gemini/bin/gemini-agent wait
```

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or gemini never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition.
- Detection is screen-scrape based: gemini sends no completion signal, so `wait` watches the working indicator (`BUSY_RE` at the top of the dispatcher). It debounces — the indicator must stay gone for `stable` secs (default 6) — so bump `stable` for tasks with long gaps between steps.
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
