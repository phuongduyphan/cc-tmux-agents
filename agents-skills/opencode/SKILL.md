---
name: opencode
description: Delegate a coding task to an Opencode CLI session managed via tmux. Invoke explicitly as $opencode. User drives all progress checks and interventions — no auto-polling.
---

# $opencode — delegate to Opencode CLI

Spawns Opencode's TUI in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/opencode/bin/opencode-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-opencode`), launch `opencode`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Opencode queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `codex-opencode*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `$opencode <task>` / "delegate to opencode"                        | `start <task>`, then run `wait` in the **foreground** (blocks this turn until opencode is idle); on return, `capture` + report. |
| `$opencode <task>` **+ "tell me when it's done" / "notify me"** | Same as `$opencode <task>`; foreground `wait` is already the default. |
| "check opencode" / "progress" / "what's opencode doing" / "ask opencode for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt opencode" / "esc opencode"                              | `keys Escape` → `capture`.                      |
| "tell opencode: X" / "send opencode: X"                            | `send X`.                                       |
| "kill opencode" / "stop opencode"                                  | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. For new tasks, run `wait` in the foreground by default (see "Wait for completion"), which blocks in one cheap shell loop instead of polling. Only `capture` separately when the user asks.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-opencode`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Opencode to read it.
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety & quirks

- The Opencode TUI has **no `--dangerously-skip-permissions` flag** (that flag only applies to `opencode run`). The TUI will prompt for tool permissions during the session. If you see the agent sitting idle after apparent activity, `capture` — it may be waiting on a permission prompt that needs `send y` or similar.
- For fully autonomous one-shot delegation, consider `opencode run --dangerously-skip-permissions "<task>"` via a background Bash instead of this skill.


## Wait for completion

After `start` — and after any `send` that should produce another completion report — run the `wait` verb in the **foreground**. This is the default for `$opencode <task>`; the user does not need to say "tell me when it's done". It blocks the current turn in a single cheap shell loop and returns the instant opencode goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, opencode is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/opencode/bin/opencode-agent wait
```

`wait` auto-selects its detection mode:

- **Exact (hook-based)** when the `cc-notify` plugin is installed (`~/.config/opencode/plugin/cc-notify.js`) and the task was sent through this dispatcher. The plugin writes `/tmp/<session>.done` on opencode's `session.idle` event; `wait` exits as soon as that file is newer than `/tmp/<session>.sent` (stamped before the task was typed). Race-free and no screen-scraping — if opencode finished before `wait` armed, it exits immediately.
- **Spinner (fallback)** when the plugin isn't available: arm on the working indicator appearing, then exit once it's been gone for `stable` secs.

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | hook fired, or spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or opencode never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** In spinner-fallback a fast model can finish during the gap and the watcher reports `no-activity`. (Hook mode is immune — it compares timestamps.)
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
