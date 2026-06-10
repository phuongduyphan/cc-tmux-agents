#!/usr/bin/env bash
# cc-agents installer.
#
# Symlinks the skills into ~/.claude/skills/ (so `git pull` updates them in
# place) and installs the per-tool completion hooks for the agent CLIs that are
# present on this machine. Idempotent: safe to re-run after a pull.
#
# Usage:
#   ./install.sh            # symlink skills + install hooks for detected tools
#   ./install.sh --copy     # copy instead of symlink (no live updates on pull)
#   ./install.sh --skills "pi opencode autopilot"   # subset only

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DST="$HOME/.claude/skills"
MODE="link"
ONLY_SKILLS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE="copy"; shift ;;
    --skills) ONLY_SKILLS="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
skip() { printf '  \033[2m-\033[0m %s\n' "$1"; }

# --- 1. skills -> ~/.claude/skills ------------------------------------------
echo "Installing skills ($MODE) into $SKILLS_DST"
mkdir -p "$SKILLS_DST"
for src in "$REPO_DIR"/skills/*/; do
  name="$(basename "$src")"
  if [ -n "$ONLY_SKILLS" ]; then
    case " $ONLY_SKILLS " in
      *" $name "*) : ;;
      *) continue ;;
    esac
  fi
  dst="$SKILLS_DST/$name"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    warn "$name: $dst exists and is not a symlink; leaving it alone (move it aside and re-run to adopt the repo version)"
    continue
  fi
  rm -f "$dst"
  if [ "$MODE" = "link" ]; then
    ln -s "${src%/}" "$dst"
  else
    cp -R "${src%/}" "$dst"
  fi
  say "$name"
done

# --- 2. worker env file -------------------------------------------------------
ENV_FILE="$HOME/.config/cc-agents/env"
if [ ! -f "$ENV_FILE" ]; then
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<'EOF'
# cc-agents worker environment.
# Sourced by the pi dispatcher when launching a worker session, INSTEAD of your
# interactive shell rc. Put ONLY the model-provider keys the workers need here,
# so workers never inherit your full shell environment.
#
# ZAI_API_KEY=...
# ANTHROPIC_API_KEY=...
EOF
  chmod 600 "$ENV_FILE"
  say "created $ENV_FILE (add your provider API keys there)"
else
  skip "$ENV_FILE already exists"
fi

# --- 3. completion hooks (exact done-detection for `wait`) --------------------
echo "Installing completion hooks for detected tools"

# pi: agent_end extension
if command -v pi >/dev/null 2>&1 || [ -d "$HOME/.pi" ]; then
  mkdir -p "$HOME/.pi/agent/extensions"
  cp "$REPO_DIR/hooks/pi-cc-notify.ts" "$HOME/.pi/agent/extensions/cc-notify.ts"
  say "pi: ~/.pi/agent/extensions/cc-notify.ts"
else
  skip "pi not detected"
fi

# opencode: session.idle plugin
if command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; then
  mkdir -p "$HOME/.config/opencode/plugin"
  cp "$REPO_DIR/hooks/opencode-cc-notify.js" "$HOME/.config/opencode/plugin/cc-notify.js"
  say "opencode: ~/.config/opencode/plugin/cc-notify.js"
else
  skip "opencode not detected"
fi

# codex: notify program registered in config.toml
if command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then
  mkdir -p "$HOME/.codex"
  cp "$REPO_DIR/hooks/codex-cc-notify.sh" "$HOME/.codex/cc-notify.sh"
  chmod +x "$HOME/.codex/cc-notify.sh"
  CFG="$HOME/.codex/config.toml"
  touch "$CFG"
  if grep -q 'cc-notify\.sh' "$CFG"; then
    skip "codex: notify already registered in config.toml"
  elif grep -qE '^[[:space:]]*notify[[:space:]]*=' "$CFG"; then
    warn "codex: config.toml already has a different notify program; add $HOME/.codex/cc-notify.sh to it manually"
  else
    printf '\n# Auto-notify hook for the cc-agents /codex dispatcher\nnotify = ["%s/.codex/cc-notify.sh"]\n' "$HOME" >> "$CFG"
    say "codex: ~/.codex/cc-notify.sh registered in config.toml"
  fi
else
  skip "codex not detected"
fi

# cursor: stop hook registered in hooks.json
if command -v agent >/dev/null 2>&1 || [ -d "$HOME/.cursor" ]; then
  mkdir -p "$HOME/.cursor"
  cp "$REPO_DIR/hooks/cursor-cc-notify.sh" "$HOME/.cursor/cc-notify.sh"
  chmod +x "$HOME/.cursor/cc-notify.sh"
  HJ="$HOME/.cursor/hooks.json"
  if [ ! -f "$HJ" ]; then
    printf '{\n  "version": 1,\n  "hooks": {\n    "stop": [\n      { "command": "%s/.cursor/cc-notify.sh" }\n    ]\n  }\n}\n' "$HOME" > "$HJ"
    say "cursor: ~/.cursor/hooks.json created with stop hook"
  elif grep -q 'cc-notify\.sh' "$HJ"; then
    skip "cursor: stop hook already in hooks.json"
  else
    warn "cursor: ~/.cursor/hooks.json exists; add { \"command\": \"$HOME/.cursor/cc-notify.sh\" } under hooks.stop manually"
  fi
else
  skip "cursor not detected"
fi

echo
echo "Done. Run ./doctor to verify the setup, then try a skill from Claude Code, e.g.:"
echo "  /opencode say hello and exit"
