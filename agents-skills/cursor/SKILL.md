---
name: cursor
description: Delegate a coding task to a Cursor Agent CLI session managed via tmux. Invoke explicitly as $cursor. User drives all progress checks and interventions — no auto-polling.
---

# $cursor — delegate to Cursor Agent CLI

Spawns Cursor Agent's TUI in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/cursor/bin/cursor-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-cursor`), launch `agent --force`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Cursor Agent queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `codex-cursor*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `$cursor <task>` / "delegate to cursor"                            | `start <task>`, then run `wait` in the **foreground** (blocks this turn until cursor is idle); on return, `capture` + report. |
| `$cursor <task>` **+ "tell me when it's done" / "notify me"**      | Same as `$cursor <task>`; foreground `wait` is already the default. |
| "check cursor" / "progress" / "what's cursor doing" / "ask cursor for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt cursor" / "esc cursor"                                  | `keys Escape` → `capture`.                      |
| "tell cursor: X" / "send cursor: X"                                | `send X`.                                       |
| "kill cursor" / "stop cursor"                                      | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. For new tasks, run `wait` in the foreground by default (see "Wait for completion"), which blocks in one cheap shell loop instead of polling. Only `capture` separately when the user asks.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-cursor`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Cursor Agent to read it.
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety

`--force` (alias `--yolo`) lets Cursor Agent run shell commands without per-command approval (denials still apply). For untrusted tasks, launch inside a git worktree or sandbox directory — or pass `--session` and edit the dispatcher to drop `--force`.


## Wait for completion

After `start` — and after any `send` that should produce another completion report — run the `wait` verb in the **foreground**. This is the default for `$cursor <task>`; the user does not need to say "tell me when it's done". It blocks the current turn in a single cheap shell loop and returns the instant cursor goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, cursor is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/cursor/bin/cursor-agent wait
```

`wait` auto-selects its detection mode:

- **Exact (hook-based)** when the `cc-notify` stop hook is installed (`~/.cursor/cc-notify.sh`, registered in `~/.cursor/hooks.json`) and the task was sent through this dispatcher. The hook writes `/tmp/<session>.done` on cursor's `stop` event; `wait` exits as soon as that file is newer than `/tmp/<session>.sent` (stamped before the task was typed). Race-free and no screen-scraping — if cursor finished before `wait` ran, it returns immediately.
- **Spinner (fallback)** when the hook isn't available: arm on cursor's working indicator appearing, then exit once it's been gone for `stable` secs.

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | hook fired, or spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or cursor never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** In spinner-fallback a fast model can finish during the gap and the watcher reports `no-activity`. (Hook mode is immune — it compares timestamps.)
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
