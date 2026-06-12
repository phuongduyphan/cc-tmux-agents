---
name: claude
description: Delegate a coding task to a Claude Code CLI session managed via tmux. Invoke explicitly as $claude. User drives all progress checks and interventions — no auto-polling.
---

# $claude — delegate to Claude Code CLI

Spawns Claude Code in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/claude/bin/claude-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-claude`), launch `claude --dangerously-skip-permissions`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Claude queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `codex-claude*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `$claude <task>` / "delegate to claude"                            | `start <task>`, then run `wait` in the **foreground** (blocks this turn until claude is idle); on return, `capture` + report. |
| `$claude <task>` **+ "tell me when it's done" / "notify me"** | Same as `$claude <task>`; foreground `wait` is already the default. |
| "check claude" / "progress" / "what's claude doing" / "ask claude for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt claude" / "esc claude"                                  | `keys Escape` → `capture`.                      |
| "tell claude: X" / "send claude: X"                                | `send X`.                                       |
| "kill claude" / "stop claude"                                      | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. For new tasks, run `wait` in the foreground by default (see "Wait for completion"), which blocks in one cheap shell loop instead of polling. Only `capture` separately when the user asks.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-claude`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Claude to read it.
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety

`--dangerously-skip-permissions` lets Claude Code run any tool, any path, any shell command without approval prompts. For untrusted tasks, launch inside a git worktree or sandbox directory. Anthropic recommends this flag only for environments with no internet access.


## Wait for completion

After `start` — and after any `send` that should produce another completion report — run the `wait` verb in the **foreground**. This is the default for `$claude <task>`; the user does not need to say "tell me when it's done". It blocks the current turn in a single cheap shell loop and returns the instant claude goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, claude is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/claude/bin/claude-agent wait
```

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or claude never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition.
- Detection is screen-scrape based: claude sends no completion signal, so `wait` watches the working indicator (`BUSY_RE` at the top of the dispatcher). It debounces — the indicator must stay gone for `stable` secs (default 6) — so bump `stable` for tasks with long gaps between steps.
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
