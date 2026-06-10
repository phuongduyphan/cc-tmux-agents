#!/usr/bin/env bash
# Codex notify hook for the Claude Code /codex dispatcher (~/.claude/skills/codex).
#
# Codex runs `notify` with a single JSON argument on notable events. On the
# agent-turn-complete event, if CC_DONE_SENTINEL is set (the dispatcher launches
# codex with it via `tmux -e`, and codex passes its env to this child), write the
# current time to that file. The dispatcher's `wait` verb compares its mtime
# against /tmp/<session>.sent to detect completion EXACTLY — no screen-scraping.
#
# No-op for normal interactive codex sessions (env var unset), so wiring this
# globally is harmless to everyday use.
payload="${1:-}"
case "$payload" in
  *'"agent-turn-complete"'*) : ;;
  *) exit 0 ;;
esac
[ -n "${CC_DONE_SENTINEL:-}" ] || exit 0
date +%s > "$CC_DONE_SENTINEL" 2>/dev/null || true
exit 0
