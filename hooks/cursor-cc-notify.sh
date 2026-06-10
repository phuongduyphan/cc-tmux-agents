#!/usr/bin/env bash
# Cursor stop-hook for the Claude Code /cursor dispatcher (~/.claude/skills/cursor).
#
# Cursor runs this on the `stop` event (agent loop ended: completed/aborted/error),
# passing a JSON payload on stdin. We ignore the payload and, if CC_DONE_SENTINEL is
# set (the dispatcher launches `agent` with it via `tmux -e`, and cursor passes its
# env to this child), write the current time to that file. The dispatcher's `wait`
# verb compares its mtime against /tmp/<session>.sent to detect completion EXACTLY —
# no screen-scraping.
#
# Emits no stdout so cursor does not auto-submit a follow-up. No-op for normal
# interactive cursor sessions (env var unset).
cat >/dev/null 2>&1 || true   # drain stdin payload
[ -n "${CC_DONE_SENTINEL:-}" ] || exit 0
date +%s > "$CC_DONE_SENTINEL" 2>/dev/null || true
exit 0
