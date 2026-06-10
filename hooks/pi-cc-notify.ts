// Auto-notify hook for the Claude Code /pi dispatcher (~/.claude/skills/pi).
//
// On agent_end (pi finished responding to a prompt), if the CC_DONE_SENTINEL
// env var is set, write the current epoch-millis to that file. The dispatcher
// launches pi with `tmux -e CC_DONE_SENTINEL=/tmp/<session>.done`, and its
// `wait` verb compares this file's mtime against /tmp/<session>.sent to detect
// completion EXACTLY — no screen-scraping, no spinner regex, no arm race.
//
// No-op for normal interactive pi sessions (env var unset), so installing this
// globally is harmless to everyday use.
import { writeFileSync } from "node:fs";

export default function (pi: any) {
  pi.on("agent_end", () => {
    const sentinel = process.env.CC_DONE_SENTINEL;
    if (!sentinel) return;
    try {
      writeFileSync(sentinel, String(Date.now()));
    } catch {
      // best-effort: never let the hook disrupt the session
    }
  });
}
