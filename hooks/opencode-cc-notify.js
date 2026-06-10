// Auto-notify hook for the Claude Code /opencode dispatcher (~/.claude/skills/opencode).
//
// On the session.idle event (opencode finished responding), if the
// CC_DONE_SENTINEL env var is set, write the current epoch-millis to that file.
// The dispatcher launches opencode with `tmux -e CC_DONE_SENTINEL=/tmp/<session>.done`,
// and its `wait` verb compares this file's mtime against /tmp/<session>.sent to
// detect completion EXACTLY — no screen-scraping, no spinner regex, no arm race.
//
// No-op for normal interactive opencode sessions (env var unset).
import { writeFileSync } from "node:fs";

export default {
  id: "cc-notify",
  server: async () => {
    return {
      event: async ({ event }) => {
        if (!event || event.type !== "session.idle") return;
        const sentinel = process.env.CC_DONE_SENTINEL;
        if (!sentinel) return;
        try {
          writeFileSync(sentinel, String(Date.now()));
        } catch {
          // best-effort: never let the hook disrupt the session
        }
      },
    };
  },
};
