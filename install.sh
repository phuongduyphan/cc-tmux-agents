#!/usr/bin/env bash
# cc-tmux-agents installer.
#
# Copies the skills into ~/.claude/skills/ and ~/.agents/skills/ and installs
# the per-tool completion hooks for the agent CLIs present on this machine.
# Only the skill folders shipped by this repo are touched; any other skills you
# have are left untouched. Idempotent: safe to re-run (it refreshes its own
# installs, after a `git pull` for example).
#
# Usage:
#   ./install.sh            # copy skills + install hooks for detected tools
#   ./install.sh --link     # symlink instead of copy (live updates on pull, no re-run)
#   ./install.sh --skills "pi opencode autopilot"   # subset only

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DST="$HOME/.claude/skills"
MODE="copy"
ONLY_SKILLS=""
MARKER=".cc-tmux-agents-managed"   # dropped into copied skills so re-runs can safely refresh them

while [ $# -gt 0 ]; do
  case "$1" in
    --link) MODE="link"; shift ;;
    --copy) MODE="copy"; shift ;;
    --skills) ONLY_SKILLS="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
skip() { printf '  \033[2m-\033[0m %s\n' "$1"; }

# Install one skill tree (copy or symlink), touching only the folders this repo
# ships. An existing same-named folder that we did NOT install is left alone, so
# a skill of yours that happens to share a name is never clobbered.
install_tree() {
  local srcdir="$1" dstroot="$2" src name dst
  mkdir -p "$dstroot"
  for src in "$srcdir"/*/; do
    name="$(basename "$src")"
    if [ -n "$ONLY_SKILLS" ]; then
      case " $ONLY_SKILLS " in
        *" $name "*) : ;;
        *) continue ;;
      esac
    fi
    dst="$dstroot/$name"
    if [ -L "$dst" ]; then
      rm -f "$dst"                                   # prior symlink install
    elif [ -e "$dst" ] && [ ! -e "$dst/$MARKER" ]; then
      warn "$name: $dst exists and wasn't installed by cc-tmux-agents; leaving it alone (move it aside and re-run to replace)"
      continue
    else
      rm -rf "$dst"                                  # our own prior copy (or nothing); refresh it
    fi
    if [ "$MODE" = "link" ]; then
      ln -s "${src%/}" "$dst"
    else
      cp -R "${src%/}" "$dst"
      touch "$dst/$MARKER"
    fi
    say "$name"
  done
}

# --- 1. skills -> ~/.claude/skills ------------------------------------------
echo "Installing skills ($MODE) into $SKILLS_DST"
install_tree "$REPO_DIR/skills" "$SKILLS_DST"

# --- 1b. agents-skills -> ~/.agents/skills ------------------------------------
# Same dispatchers in the cross-agent Agent Skills format, for using codex /
# opencode / pi (instead of Claude Code) as the orchestrator. Invoked as $name;
# `wait` runs in the foreground there (those harnesses can't background-and-
# reinvoke). Workers include claude and gemini.
AGENTS_DST="$HOME/.agents/skills"
echo "Installing agents-skills ($MODE) into $AGENTS_DST"
install_tree "$REPO_DIR/agents-skills" "$AGENTS_DST"

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
