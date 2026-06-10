---
name: pi
description: Delegate a coding task to a pi (pi-coding-agent) CLI session managed via tmux. Invoke explicitly as $pi. User drives all progress checks and interventions — no auto-polling.
---

# $pi — delegate to pi CLI

Spawns pi's TUI in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/pi/bin/pi-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-pi`), launch `pi`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; pi queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `codex-pi*` sessions.

## How to respond to the user

| User says                                                      | Do                                              |
|----------------------------------------------------------------|-------------------------------------------------|
| `$pi <task>` / "delegate to pi"                                | `start <task>`; reply "Started. Tell me when to check." |
| `$pi <task>` **+ "tell me when it's done" / "notify me"**      | `start <task>`, then run `wait` in the **foreground** (blocks this turn until pi is idle); on return, `capture` + report. |
| "check pi" / "progress" / "what's pi doing" / "ask pi for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt pi" / "esc pi"                                      | `keys Escape` → `capture`.                      |
| "tell pi: X" / "send pi: X"                                    | `send X`.                                       |
| "kill pi" / "stop pi"                                          | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. Only act when the user asks — or run `wait` in the foreground (see "Wait for completion"), which blocks in one cheap shell loop instead of polling.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-pi`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell pi to read it (e.g. `send "read /tmp/prompt.md and follow it"`).
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety & quirks

- pi's TUI prompts for tool permissions during the session. If the agent appears idle after activity, `capture` — it may be waiting on a confirmation prompt. Respond with `send y` (or whatever the prompt expects).
- pi reads model/provider/auth from its own config (`~/.pi/agent`) and env vars (e.g. `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`). If `start` fails with an auth error, run `pi` interactively once and use `/login` to set up a provider.
- For fully autonomous one-shot delegation without a TUI, use `pi -p "<task>"` via a background Bash instead of this skill.

## Wait for completion

When you want to know the moment pi is done, run the `wait` verb in the **foreground** right after `start` (or a follow-up `send`). It blocks the current turn in a single cheap shell loop and returns the instant pi goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, pi is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/pi/bin/pi-agent wait
```

`wait` auto-selects its detection mode:

- **Exact (hook-based)** when the `cc-notify` extension is installed (`~/.pi/agent/extensions/cc-notify.ts`) and the task was sent through this dispatcher. The extension writes `/tmp/<session>.done` on pi's `agent_end` event; `wait` exits as soon as that file is newer than `/tmp/<session>.sent` (stamped before the task was typed). Race-free and no screen-scraping — if pi finished before `wait` ran, it returns immediately.
- **Spinner (fallback)** when the extension isn't available: arm on pi's working indicator (the braille spinner / "Working…") appearing, then exit once it's been gone for `stable` secs.

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | hook fired, or spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or pi never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** In spinner-fallback a fast model can finish during the gap and the watcher reports `no-activity`. (Hook mode is immune — it compares timestamps.)
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
