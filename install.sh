#!/usr/bin/env bash
# Install the CodeScene Code Health gate, MCP config and AGENTS.md into a repository.
#
#   ./install.sh [options] <target-repo>
#
#   --agents LIST     comma-separated: claude,codex,copilot,cursor,vscode (default: all)
#   --skip-mcp        don't add CodeScene MCP server config
#   --skip-agents-md  don't add or extend AGENTS.md
#   --dry-run         print what would change, change nothing
#
# Existing files are merged, never overwritten. Run it again to update the gate script.
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
T="$KIT/templates"
AGENTS="claude,codex,copilot,cursor,vscode"
MCP=1; AGENTS_MD=1; DRY=0; TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agents) AGENTS="$2"; shift 2 ;;
    --skip-mcp) MCP=0; shift ;;
    --skip-agents-md) AGENTS_MD=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "usage: ./install.sh [options] <target-repo>" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "not a directory: $TARGET" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (macOS 15+ ships it; else brew install jq)" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"
has() { case ",$AGENTS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
say() { printf '  %-8s %s\n' "$1" "$2"; }
run() { [ "$DRY" = 1 ] || "$@"; }

# Copy a file if it doesn't exist; report if it exists.
copy_new() { # <template-rel> <target-rel>
  local src="$T/$1" dst="$TARGET/$2"
  if [ ! -e "$dst" ]; then run mkdir -p "$(dirname "$dst")"; run cp "$src" "$dst"; say added "$2"
  elif cmp -s "$src" "$dst"; then say ok "$2"
  else say skipped "$2 (exists, differs: merge by hand from templates/$1)"; fi
}

# Merge a JSON template into an existing JSON file with a jq program ($t = template).
merge_json() { # <template-rel> <target-rel> <jq-program>
  local src="$T/$1" dst="$TARGET/$2" out
  if [ ! -e "$dst" ]; then run mkdir -p "$(dirname "$dst")"; run cp "$src" "$dst"; say added "$2"; return; fi
  if ! out=$(jq --slurpfile t "$src" "$3" "$dst" 2>/dev/null); then
    say skipped "$2 (not plain JSON, maybe comments: merge by hand from templates/$1)"; return
  fi
  if [ "$out" = "$(jq . "$dst")" ]; then say ok "$2"; else
    [ "$DRY" = 1 ] || printf '%s\n' "$out" > "$dst"; say merged "$2"; fi
}

# shellcheck disable=SC2016  # $p and $t are jq variables, not shell
# jq: append the template's hook group under <path> unless a code-health-gate hook is already there.
add_hook='def gate: [.. | strings | select(test("code-health-gate\\.sh"))] | length > 0;
  if gate then . else setpath($p; (getpath($p) // []) + ($t[0] | getpath($p))) end'
# shellcheck disable=SC2016
add_server='if getpath($p) then . else setpath($p; $t[0] | getpath($p)) end'

echo "CodeScene Code Health gate -> $TARGET"
[ "$DRY" = 1 ] && echo "(dry run)"

# 1. The gate script (always updated: it's ours)
dst="$TARGET/.agents/hooks/code-health-gate.sh"
if [ -e "$dst" ] && cmp -s "$KIT/.agents/hooks/code-health-gate.sh" "$dst"; then say ok ".agents/hooks/code-health-gate.sh"
else run mkdir -p "$(dirname "$dst")"; run cp "$KIT/.agents/hooks/code-health-gate.sh" "$dst"; run chmod +x "$dst"
  say written ".agents/hooks/code-health-gate.sh"; fi

# 2. Hook registration per agent
has claude  && merge_json .claude/settings.json .claude/settings.json "$(printf '%s' "$add_hook" | sed 's/\$p/["hooks","Stop"]/g')"
has codex   && merge_json .codex/hooks.json .codex/hooks.json "$(printf '%s' "$add_hook" | sed 's/\$p/["hooks","Stop"]/g')"
has copilot && copy_new .github/hooks/code-health.json .github/hooks/code-health.json
has copilot && copy_new .github/workflows/copilot-setup-steps.yml .github/workflows/copilot-setup-steps.yml
has cursor  && merge_json .cursor/hooks.json .cursor/hooks.json "$(printf '%s' "$add_hook" | sed 's/\$p/["hooks","stop"]/g')"
# VS Code reads .github/hooks/*.json, so its hook comes with "copilot".
has vscode && ! has copilot && copy_new .github/hooks/code-health.json .github/hooks/code-health.json

# 3. CodeScene MCP server
if [ "$MCP" = 1 ]; then
  { has claude || has copilot; } && merge_json .mcp.json .mcp.json "$(printf '%s' "$add_server" | sed 's/\$p/["mcpServers","codescene"]/g')"
  has vscode && merge_json .vscode/mcp.json .vscode/mcp.json "$(printf '%s' "$add_server" | sed 's/\$p/["servers","codescene"]/g')"
  has cursor && merge_json .cursor/mcp.json .cursor/mcp.json "$(printf '%s' "$add_server" | sed 's/\$p/["mcpServers","codescene"]/g')"
  if has codex; then
    dst="$TARGET/.codex/config.toml"
    if [ -e "$dst" ] && grep -q '^\[mcp_servers\.codescene\]' "$dst"; then say ok ".codex/config.toml"
    elif [ -e "$dst" ]; then [ "$DRY" = 1 ] || { printf '\n'; cat "$T/.codex/config.toml"; } >> "$dst"; say merged ".codex/config.toml"
    else run mkdir -p "$TARGET/.codex"; run cp "$T/.codex/config.toml" "$dst"; say added ".codex/config.toml"; fi
  fi
fi

# 4. AGENTS.md (append a marked section if the repo already has one)
if [ "$AGENTS_MD" = 1 ]; then
  dst="$TARGET/AGENTS.md"
  if [ ! -e "$dst" ]; then run cp "$KIT/AGENTS.md" "$dst"; say added "AGENTS.md"
  elif grep -q 'codescene-code-health:start' "$dst"; then say ok "AGENTS.md (CodeScene section present)"
  else [ "$DRY" = 1 ] || { printf '\n'; sed -n '/codescene-code-health:start/,/codescene-code-health:end/p' "$KIT/AGENTS.md"; } >> "$dst"
    say merged "AGENTS.md (CodeScene section appended)"; fi
fi

cat <<EOF

Next:
  1. Each developer: install cs and sign in (cs auth login). See README "Install the cs CLI".
  2. Commit the files above. Copilot cloud agent reads hooks from the default branch only.
  3. Trust the repo in each agent (Copilot CLI and Codex silently skip untrusted repos).
  4. Test: make a change that lowers Code Health and ask the agent to finish.
EOF
