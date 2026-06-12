---
name: droid
description: Delegate a coding task to a Droid (Factory AI) CLI session managed via tmux. Invoke explicitly as $droid. User drives all progress checks and interventions — no auto-polling.
---

# $droid — delegate to Droid CLI

Spawns Droid's TUI (Factory's AI coding agent) in a detached tmux session so Codex can offload work to it. The user stays in the loop: they ask Codex when to check progress, what guidance to send, and when to stop.

## Primitive

All operations go through a single dispatcher:

```
~/.agents/skills/droid/bin/droid-agent [--session <name>] <verb> [args]
```

Verbs:

- `start [task...]`  — create session (default `codex-droid`), launch `droid`, type the task and press Enter. Returns immediately (non-blocking).
- `send <message>`   — type message + Enter. For follow-up guidance. Does **not** interrupt current generation; Droid queues the input.
- `keys <name>`      — send a raw tmux key (`Escape`, `C-c`, `Enter`, etc.). Used for interrupts.
- `capture [lines]`  — print last N ANSI-stripped rendered lines (default 500). Read-only, non-destructive.
- `wait [stable] [timeout]` — **block until the agent goes idle, then exit.** Run it in the **foreground** to block until the sub-agent finishes (the mode for Codex and other CLI orchestrators; see "Wait for completion" below). `stable` = secs the working indicator must stay gone before declaring idle (default 6); `timeout` = overall cap in secs (default 1800).
- `stop`             — kill-session. Destroys the tmux session.
- `list`             — list active `codex-droid*` sessions.

## How to respond to the user

| User says                                                          | Do                                              |
|--------------------------------------------------------------------|-------------------------------------------------|
| `$droid <task>` / "delegate to droid"                              | `start <task>`, then run `wait` in the **foreground** (blocks this turn until droid is idle); on return, `capture` + report. |
| `$droid <task>` **+ "tell me when it's done" / "notify me"**       | Same as `$droid <task>`; foreground `wait` is already the default. |
| "check droid" / "progress" / "what's droid doing" / "ask droid for progress" | `capture`. Show the relevant tail, add a one-line diagnosis (running / idle / error / prompt). **Do not send ESC.** |
| "interrupt droid" / "esc droid"                                    | `keys Escape` → `capture`.                      |
| "tell droid: X" / "send droid: X"                                  | `send X`.                                       |
| "kill droid" / "stop droid"                                        | `stop`.                                         |

Rules:
- **Never auto-poll** on a timer. For new tasks, run `wait` in the foreground by default (see "Wait for completion"), which blocks in one cheap shell loop instead of polling. Only `capture` separately when the user asks.
- **Never send `Escape`** unless the user explicitly asks to interrupt.
- `capture` is the default observation verb. Prefer it over intervention.

## Conventions

- Default session name: `codex-droid`. For concurrent tasks, pass `--session <name>` before the verb.
- Tasks and messages are **single-line**: newlines are interpreted as submit by the TUI. For long prompts, write the prompt to a file and tell Droid to read it.
- Requires a Codex rule allowing this dispatcher and `tmux` outside the sandbox (see `~/.codex/rules/default.rules`).

## Safety & quirks

- The Droid TUI defaults to **"Auto (Off) — all actions require approval"**, so Droid will pause on tool calls and wait for approval. If the agent sits idle after apparent activity, `capture` — it may be waiting on a permission prompt. Use `send y` / `send 1` or `keys Enter` to answer.
- To run with auto-approval, ask the user whether to toggle autonomy inside the TUI (`ctrl+L`) or start Droid differently. Do not enable autonomy without user consent.
- For fully autonomous one-shot delegation, consider `droid exec "<task>"` via a background Bash instead of this skill.
- While Droid is generating, the status line shows `Streaming...` / `Press ESC to stop`. The `[⏱ Ns]` timer in the footer is the **last response duration**, not a live processing signal — don't use it to infer activity.


## Wait for completion

After `start` — and after any `send` that should produce another completion report — run the `wait` verb in the **foreground**. This is the default for `$droid <task>`; the user does not need to say "tell me when it's done". It blocks the current turn in a single cheap shell loop and returns the instant droid goes idle, printing the final state on its last stdout line. Then `capture` and report.

Foreground is the right mode here. Codex (and most CLI agents) run a shell command to completion and cannot re-invoke themselves when a backgrounded command exits; that background-and-notify trick is specific to Claude Code. So `wait` blocks the turn rather than freeing it. **Long-task caveat:** if `wait` returns `timeout … still-busy`, or the orchestrator's own command timeout fires first, droid is still running, so just run `wait` again to keep waiting.

After `start` (or a follow-up `send`):

```
~/.agents/skills/droid/bin/droid-agent wait
```

Read the final stdout line for the state, then `capture` and report:

| Watcher's last line | Means | Do next |
|---|---|---|
| `idle … task-appears-complete`        | spinner gone and stable | `capture`, summarize the result |
| `prompt … permission-prompt`          | idle but a y/n prompt is up | `capture`, send `y` if authorized |
| `timeout … still-busy`                | hit the cap while still working | `capture`, report it's still going; re-run `wait` if desired |
| `gone` / `idle … no-activity`         | session killed, or droid never started working | `capture` to confirm |

Notes:
- **Run `wait` (foreground) immediately after `start`/`send` — don't `capture` first.** A fast model can finish during the gap, and the watcher will then report `no-activity` (it never saw the spinner) instead of catching the idle transition.
- Detection is screen-scrape based: droid sends no completion signal, so `wait` watches the working indicator (`BUSY_RE` at the top of the dispatcher). It debounces — the indicator must stay gone for `stable` secs (default 6) — so bump `stable` for tasks with long gaps between steps.
- Re-run `wait` after each `send` if you want to be notified for that follow-up too — one `wait` covers one idle transition.
