---
name: autopilot
description: Autonomous orchestrator that delegates a task to a /pi, /opencode, /codex, or /cursor subagent and drives it to completion without user babysitting. Invoked as `/autopilot <pi|opencode|codex|cursor> <task>`. Arms a backgrounded `wait` for an instant completion ping, checkpoints the subagent every 10 minutes (interrupt, progress report, course-correct), and reviews the final output before exiting. Each `/autopilot` task uses a fresh subagent session.
---

# /autopilot: autonomous subagent orchestrator

Drives a single subagent (pi / opencode / codex / cursor) toward a goal without user-driven polling. Wraps the existing dispatchers at `~/.claude/skills/<name>/bin/<name>-agent` and adds two wake sources, a checkpoint protocol, and a final review gate.

This skill is the **autonomous counterpart** to `/pi`, `/opencode`, `/codex`, `/cursor` (which forbid auto-polling). When operating inside `/autopilot`, you are explicitly authorized to auto-poll those same dispatchers.

## Invocation

```
/autopilot <pi|opencode|codex|cursor> <task description>
```

- First token after `/autopilot` selects the subagent: one of `pi`, `opencode`, `codex`, `cursor`. Reject anything else.
- Everything after the subagent token is the task.

## Session naming and files

Session: `cc-<subagent>-autopilot` (e.g. `cc-pi-autopilot`). Distinct from the user-driven `cc-<subagent>` sessions so the two don't collide. Pass it explicitly: `<dispatcher> --session cc-<subagent>-autopilot <verb>`.

**Fresh session per task.** If a session with this name already exists when `/autopilot` is invoked fresh, `stop` it first.

Three files per run:

| File | Purpose |
|---|---|
| `/tmp/cc-autopilot-<subagent>-task.md` | the full task, so the subagent can re-read it |
| `/tmp/cc-autopilot-<subagent>-decisions.md` | the decision log; the single artifact the user reads when they return |
| `/tmp/cc-autopilot-<subagent>.done` | the done-sentinel; its presence means the loop has ended |

## The control flow

Every turn begins by checking the sentinel, then routing on the wake source. The full loop:

```
EVERY WAKE:
  sentinel present?  ──yes──▶ stale wake; one-line note; END turn (never restart)
        │ no
        ▼
  session absent?    ──yes──▶ PHASE 1 (start), then END turn
        │ no (a wake-up)
        ▼
  route on wake source:
    wait ping = idle/completion ──────────────▶ PHASE 3 (review)
    wait ping = timeout (still busy) ──────────▶ re-arm wait; END turn
    120s report tick ─────────────────────────▶ EVALUATE
    60s permission re-check / 10-min tick ─────▶ CHECKPOINT TICK

CHECKPOINT TICK (capture pane, classify one state):
    idle        ──▶ PHASE 3 (review)
    permission  ──▶ answer prompt; schedule 60s re-check; wait stays armed; END turn
    crashed     ──▶ BAIL (summary, stop, set sentinel, surface)
    busy        ──▶ kill wait; Escape + confirm; request 3-para report;
                    schedule 120s tick; END turn

EVALUATE (read the report):
    ground-truth with git diff; harvest DECISION lines
    direction OK?  ──yes──▶ send bare "continue" ──▶ RE-ARM
                   ──no───▶ inspect myself (Read/Bash/Grep)
                            same blocker 2nd round?  ──yes──▶ BAIL
                                                     ──no───▶ send "continue" + concrete fix;
                                                              log intervention ──▶ RE-ARM

PHASE 3 REVIEW (agent idle):
    git diff + run tests myself; harvest DECISION lines
    good?  ──yes──▶ summary to log; stop session; set sentinel; END loop (no re-arm)
           ──no───▶ send numbered fixes; log verdict ──▶ RE-ARM

RE-ARM: start fresh bg wait; schedule 10-min timer (subject to the one-pending-timer invariant)
```

Two wake sources, complementary:

- **bg `wait`** (a backgrounded Bash running `<dispatcher> --session cc-<subagent>-autopilot wait`): exits the instant the agent goes idle; the harness pings you on exit. Catches clean completion immediately. It can never catch a thinking loop (a stuck agent never goes idle).
- **10-minute timer** (`ScheduleWakeup`, flat interval, no cadence table): the checkpoint. Catches thinking loops, wrong-direction drift, permission prompts, and crashes. Two short special-case intervals exist: 120s to read a requested progress report, 60s to confirm a permission approval unblocked the agent.

## Identifying the wake source

Every turn after Phase 1 starts the same way:

1. **Sentinel guard first.** If `/tmp/cc-autopilot-<subagent>.done` exists, this wake is stale (a timer or wait ping that outlived the loop). Say nothing beyond one short line and end the turn. Do NOT restart the task.
2. Then identify the source:
   - A background-task completion notification for the `wait` command means the **wait pinged**. If `wait` exited reporting *idle/completion*, go straight to Phase 3 Review. If it exited on *timeout* (agent still busy), just re-arm `wait` and end the turn; the 10-min timer drives checkpoints.
   - A `ScheduleWakeup` firing carries its `reason` field: read it to know whether this is a regular 10-min tick, a 120s report tick, or a 60s permission re-check.

## Autonomous decisions (read first)

The user is away. Autopilot does **not** stop the loop to ask questions. When the subagent (or you, during a checkpoint) hits a decision point that would normally need user input:

1. **Find the most correct answer**, not a workaround. Derive it from the existing code's conventions, the task's stated intent, the surrounding behavior, and relevant tests, types, or docs already in the repo. Spend the tokens needed to be right. "I'll just hardcode it / add a TODO / return null for now" is **not** acceptable.
2. **Pick a direction and follow it through.** Don't half-commit.
3. **Record every such decision** in `/tmp/cc-autopilot-<subagent>-decisions.md` in the format:
   ```
   - [t<N>, <source>] <decision>: <why>
   ```
   where `<source>` is `<subagent>` (the subagent made the call) or `main` (you made the call during a checkpoint or review). One line per decision.
4. The decision log is the **single thing the user reads when they come back**. Treat it as the durable artifact of the session, alongside the code changes themselves.

Worth logging: choosing between plausible APIs/data shapes; inferring an underspecified requirement; picking an error-handling stance; trading off scope; any time you would otherwise have stopped to ask. Not worth logging: routine code with one obvious shape; formatting/lint-driven choices.

## Phase 1: Start (first invocation)

You are in Phase 1 if the sentinel is absent AND `<dispatcher> --session cc-<subagent>-autopilot list` shows the session is absent.

1. Validate the subagent token. If not in `{pi, opencode, codex, cursor}`, abort with a clear error and do **not** call `ScheduleWakeup`.
2. Stop any leftover `cc-<subagent>-autopilot` session. Delete any stale sentinel file.
3. Write the full task to `/tmp/cc-autopilot-<subagent>-task.md`.
4. Initialize the decision log at `/tmp/cc-autopilot-<subagent>-decisions.md` (overwrite any prior file). Header:
   ```
   # Autopilot decisions: <subagent>, <ISO date>
   Task: <task description>

   ```
5. `start` the session with the task. After it lands, `send` a short framing message:

   > "This is an autonomous session. Work until the task is fully complete. Do not ask clarifying questions and do not insert adhoc workarounds or 'TODO: revisit' shortcuts. When a real decision is needed (ambiguous requirement, design trade-off, multiple plausible APIs), pick the **most correct** option for this codebase, derived from the existing conventions, the surrounding code, and the task's intent. Then in your reply, write a short block of the form `DECISION: <what you decided>: <why>` so it's visible in the transcript. Continue working. When done, post a completion summary (what changed, what was verified, list of DECISIONs)."

6. Arm both wake sources:
   - `Bash(command: "<dispatcher> --session cc-<subagent>-autopilot wait", run_in_background: true)`
   - `ScheduleWakeup(delaySeconds: 600, prompt: "/autopilot <subagent> <task>", reason: "autopilot t1/cc-<subagent>-autopilot: 10-min checkpoint")`
   The `prompt` must be the invocation **verbatim** so the next firing re-enters this skill.
7. One-sentence status to the user: `Started autopilot on <subagent>; instant ping on completion, checkpoints every 10 min. Decisions logged to /tmp/cc-autopilot-<subagent>-decisions.md.` Stop.

## The 10-minute checkpoint tick

`capture 600` the pane and classify into exactly one state:

| State | Signals | Action |
|---|---|---|
| **idle** | no spinner, completion-style message or bare prompt | go to Phase 3 Review |
| **permission** | TUI shows a y/n / approve prompt and no spinner | `send y` (or whatever the prompt expects; read it carefully), schedule a 60s re-check, leave `wait` armed |
| **crashed** | visible crash, "session disconnected", unrecoverable API error | `capture 1500`, write a short error summary to the decision log, `stop` the session, **set the sentinel**, surface to the user, no re-arm |
| **busy** | spinner / "esc to interrupt" / actively working | run the checkpoint below |

**Checkpoint (busy):** interrupt unconditionally; this is the design, not an emergency measure. It catches both thinking loops AND confidently-wrong-direction work that looks active. Committed edits are on disk and the turn history is retained, so nothing real is lost; a bare `continue` resumes cleanly.

1. Kill the bg `wait` task first (otherwise the report turn finishing would masquerade as task completion and trigger a premature review).
2. `keys Escape`, then `capture 200` to confirm the interrupt landed.
3. `send "Pause. In 3 short paragraphs, report: (a) what you've completed so far, (b) what you're currently trying and why, (c) any blocker (error message, failing test, missing API). If a previous message asked you to log a DECISION, include any new ones. No code."`
4. `ScheduleWakeup(delaySeconds: 120, prompt: <verbatim invocation>, reason: "autopilot t<N>/<session>: awaiting checkpoint report")`. End the turn.

**Permission re-check (60s tick):** `capture`. If the agent is now busy, it unblocked: schedule the next regular 10-min tick and end the turn (do NOT run a checkpoint interrupt on an agent that just resumed). If still at the prompt, answer again; if it stays blocked after 2 attempts, treat as crashed.

## The 120s report tick: evaluate

1. `capture` and read the report. If the report is still being generated, schedule one more 120s tick and end the turn.
2. **Ground-truth it yourself.** A cheap model's self-report skews optimistic. Glance at `git status` / `git diff` to check the claimed progress is real and pointed at the task. Don't let the report launder its own optimism.
3. Harvest any new `DECISION:` blocks into the decision log. If you cannot tell which are new (context compacted), append everything you see and de-dupe later; better to over-log than miss one.
4. Verdict:
   - **Direction OK** (no blocker, work matches the task): `send "continue"`. Bare, no commentary.
   - **Blocker or drift**: investigate yourself with `Read` / `Bash` / `Grep`. Read the actual source files. Run the failing command. Identify the cause. Then `send` `continue` plus concrete guidance: name the file, the line, the API to use, the wrong assumption to drop. Vague guidance ("try a different approach") will loop again. Log it:
     ```
     - [t<N>, intervention] main: <what you told the subagent to do>: <why, citing the file/API you verified>
     ```
5. **Hard cap:** if the *same* blocker survives 2 intervention rounds, stop the loop: `stop` the session, write a brief incident summary (including the unresolved blocker) to the decision log, **set the sentinel**, surface to the user. Don't infinitely intervene.
6. Otherwise re-arm: start a fresh bg `wait`, `ScheduleWakeup` the next 10-min tick. End the turn.

## Phase 3: Review (agent went idle)

Reached via a `wait` ping or an idle classification at a tick.

1. `capture 1500` to read the subagent's final messages. Note the claimed deliverables. Harvest any remaining `DECISION:` blocks.
2. Independently verify. From your own working directory: `git status` and `git diff` to see what actually changed; run the relevant tests / typecheck / lint that the task implies. Don't trust the subagent's "tests pass" claim; re-run them.
3. Evaluate against the original task: does it implement what was asked? Half-finished code, dead branches, debug prints? Files touched that shouldn't be? Tests/lint clean?
4. **If clean:**
   - Append a final `## Summary` block to the decision log: checkpoints used, interventions, count of DECISION entries, files changed, tests run. Make it skimmable.
   - `stop` the session. **Set the sentinel** (`touch /tmp/cc-autopilot-<subagent>.done`).
   - Post a 2-3 sentence summary to the user, ending with: `Decisions log: /tmp/cc-autopilot-<subagent>-decisions.md.`
   - **No re-arm.** Loop ends. Stale wakes hit the sentinel guard and no-op.
5. **If issues:**
   - `send` a numbered list of concrete fixes (file + line + change). Don't paraphrase the issue; name it.
   - Log the verdict: `- [t<N>, review] main: rejected: <reasons>; sent fixes: <list>`.
   - Re-arm the bg `wait`. **Only schedule a new 10-min timer if this review was reached via a timer tick.** If it was reached via a `wait` ping, the previously scheduled timer is still pending and serves as the next checkpoint (see the invariant below).

## One-pending-timer invariant

At most one `ScheduleWakeup` timer is pending at any moment. Rules:

- A turn that was woken **by a timer** may schedule exactly one new timer (60s, 120s, or 600s per the flow).
- A turn that was woken **by the wait ping** must NOT schedule a new timer when continuing the loop; the pending one is still live.
- Terminal turns (Done, Bail) schedule nothing; the sentinel neutralizes whatever is still pending.

The bg `wait` follows the complementary rule: kill it before an Escape, re-arm it whenever the subagent is sent back to work, and let the sentinel absorb any stale ping after the loop ends.

## Hygiene and boundaries

- **One autopilot session per subagent at a time.** A new `/autopilot pi ...` stops the previous `cc-pi-autopilot` session.
- **Never `Escape` outside the checkpoint protocol.**
- **Never silently edit the codebase yourself** while the subagent is running (investigation during evaluation is fine). All code changes go through the subagent, so its session reflects reality.
- **Keep per-tick output to one sentence.** The point of autopilot is offloading tokens, not narrating.
- **No adhoc workarounds.** When intervening, the same rule applies as to the subagent: pick the correct fix, log the decision, move on.
- **End the loop cleanly.** Set the sentinel, skip the re-arm, and say so: `Autopilot done. <summary>. Decisions: /tmp/cc-autopilot-<subagent>-decisions.md.`

## When NOT to use

- Tasks under ~15 min: just do them inline.
- Tasks requiring iterative human design judgment: those stay with the main agent.
- A plain "tell me when it's done" with no intervention wanted: a single backgrounded `wait` on the user-driven skill is lighter.
- Tasks gated on external state (CI, deploys, queues): use `/loop` with the appropriate probe instead.
