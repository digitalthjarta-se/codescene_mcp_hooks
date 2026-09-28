#!/usr/bin/env bash
# Install the CodeScene Code Health gate, MCP config and AGENTS.md into a git repository.
# Run it from inside the repo; it asks which agents to set up:
#
#   curl -fsSL https://raw.githubusercontent.com/digitalthjarta-se/codescene_mcp_hooks/main/install.sh | bash
#
# Existing files are merged, never overwritten. Run it again to update the gate script.
# Everything lives in functions and runs from the last line, so a cut-off download does nothing.
set -euo pipefail

KIT_REPO="${CODESCENE_HOOKS_REPO:-digitalthjarta-se/codescene_mcp_hooks}"
KIT_REF="${CODESCENE_HOOKS_REF:-main}"
AGENT_IDS=(claude copilot codex cursor vscode)
AGENT_NAMES=("Claude Code (also Grok Build)" "GitHub Copilot (CLI and cloud agent)" "Codex" "Cursor" "VS Code (Copilot agent mode)")
AGENTS=""; MCP=1; AGENTS_MD=1; DRY=0; TARGET=""; KIT=""; T=""

usage() {
  cat <<'EOF'
Usage: install.sh [options] [repo]

Installs into the git repository that contains the current folder (or [repo]).
Without --agents it asks which agents to set up.

  --agents LIST     comma-separated: claude,copilot,codex,cursor,vscode (skips the question)
  --skip-mcp        don't add CodeScene MCP server config
  --skip-agents-md  don't add or extend AGENTS.md
  --dry-run         print what would change, change nothing

Piped from curl, pass options after "bash -s --":
  curl -fsSL https://raw.githubusercontent.com/digitalthjarta-se/codescene_mcp_hooks/main/install.sh | bash -s -- --agents claude,codex
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }
say() { printf '  %-8s %s\n' "$1" "$2"; }
run() { [ "$DRY" = 1 ] || "$@"; }
has() { case ",$AGENTS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
has_tty() { (exec </dev/tty) 2>/dev/null; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --agents) [ $# -ge 2 ] || die "--agents needs a list"; AGENTS="$2"; shift 2 ;;
      --skip-mcp) MCP=0; shift ;;
      --skip-agents-md) AGENTS_MD=0; shift ;;
      --dry-run) DRY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) TARGET="$1"; shift ;;
    esac
  done
}

# Use the templates next to this script, or download them when it was piped from curl.
locate_kit() {
  local src="${BASH_SOURCE[0]:-}"
  if [ -n "$src" ] && [ -f "$src" ] && [ -d "$(dirname "$src")/templates" ]; then
    KIT="$(cd "$(dirname "$src")" && pwd)"
  else
    command -v curl >/dev/null || die "curl is required"
    KIT="$(mktemp -d)"; trap 'rm -rf "$KIT"' EXIT
    echo "Downloading $KIT_REPO@$KIT_REF"
    curl -fsSL "https://codeload.github.com/$KIT_REPO/tar.gz/$KIT_REF" | tar -xz -C "$KIT" --strip-components=1 \
      || die "could not download https://github.com/$KIT_REPO ($KIT_REF)"
  fi
  T="$KIT/templates"
}

resolve_target() {
  local dir="${TARGET:-$PWD}"
  [ -d "$dir" ] || die "not a directory: $dir"
  command -v git >/dev/null || die "git is required"
  command -v jq >/dev/null || die "jq is required (macOS 15+ ships it; else brew install jq)"
  TARGET="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository: $dir (cd into your repo, or pass its path)"
}

# Succeeds if the repo or PATH suggests the agent is in use.
detected() { # <agent-id>
  local d c dirs cmds
  case "$1" in
    claude)  dirs=".claude";       cmds="claude grok" ;;
    copilot) dirs=".github/hooks"; cmds="copilot" ;;
    codex)   dirs=".codex";        cmds="codex" ;;
    cursor)  dirs=".cursor";       cmds="cursor cursor-agent" ;;
    vscode)  dirs=".vscode";       cmds="code" ;;
  esac
  for d in $dirs; do [ -d "$TARGET/$d" ] && return 0; done
  for c in $cmds; do command -v "$c" >/dev/null && return 0; done
  return 1
}

# Fills SELECTED (0/1 per agent) with the detected agents, or all when none is found.
SELECTED=()
preselect() {
  local i any=0
  for i in "${!AGENT_IDS[@]}"; do
    if detected "${AGENT_IDS[$i]}"; then SELECTED[i]=1; any=1; else SELECTED[i]=0; fi
  done
  [ "$any" = 1 ] || set_all 1
}

set_all() { local i; for i in "${!AGENT_IDS[@]}"; do SELECTED[i]=$1; done; }

toggle() { # <1-based number>
  case "$1" in ''|*[!0-9]*) return ;; esac
  local i=$(($1 - 1))
  [ "$i" -ge 0 ] && [ "$i" -lt "${#AGENT_IDS[@]}" ] && SELECTED[i]=$((1 - SELECTED[i]))
  return 0
}

print_menu() {
  local i box
  echo "Which AI coding agents should get the gate?"
  for i in "${!AGENT_IDS[@]}"; do
    if [ "${SELECTED[i]}" = 1 ]; then box=x; else box=" "; fi
    printf '  %d) [%s] %s\n' $((i + 1)) "$box" "${AGENT_NAMES[i]}"
  done
  printf 'Type numbers to toggle (e.g. "1 3"), a = all, n = none, Enter = install: '
}

ask_agents() {
  local reply n
  while :; do
    print_menu
    read -r reply </dev/tty || reply=""
    case "$reply" in
      "") return ;;
      a|A) set_all 1 ;;
      n|N) set_all 0 ;;
      *) for n in ${reply//,/ }; do toggle "$n"; done ;;
    esac
    echo
  done
}

selected_list() {
  local i out=""
  for i in "${!AGENT_IDS[@]}"; do [ "${SELECTED[i]}" = 1 ] && out="$out,${AGENT_IDS[i]}"; done
  printf '%s' "${out#,}"
}

choose_agents() {
  [ -n "$AGENTS" ] && return
  preselect
  if has_tty; then ask_agents; else echo "No terminal to ask on; using detected agents (set them with --agents)."; fi
  AGENTS="$(selected_list)"
  [ -n "$AGENTS" ] || die "no agents selected"
}

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
ADD_HOOK='def gate: [.. | strings | select(test("code-health-gate\\.sh"))] | length > 0;
  if gate then . else setpath($p; (getpath($p) // []) + ($t[0] | getpath($p))) end'
# shellcheck disable=SC2016
ADD_SERVER='if getpath($p) then . else setpath($p; $t[0] | getpath($p)) end'

at_path() { # <jq-program> <jq-path>: substitute $p
  printf '%s' "$1" | sed "s/\\\$p/$2/g"
}

# 1. The gate script (always updated: it's ours)
install_gate() {
  local rel=".agents/hooks/code-health-gate.sh" dst="$TARGET/.agents/hooks/code-health-gate.sh"
  if [ -e "$dst" ] && cmp -s "$KIT/$rel" "$dst"; then say ok "$rel"; return; fi
  run mkdir -p "$(dirname "$dst")"; run cp "$KIT/$rel" "$dst"; run chmod +x "$dst"
  say written "$rel"
}

# 2. Hook registration per agent
install_hooks() {
  has claude  && merge_json .claude/settings.json .claude/settings.json "$(at_path "$ADD_HOOK" '["hooks","Stop"]')"
  has codex   && merge_json .codex/hooks.json .codex/hooks.json "$(at_path "$ADD_HOOK" '["hooks","Stop"]')"
  has cursor  && merge_json .cursor/hooks.json .cursor/hooks.json "$(at_path "$ADD_HOOK" '["hooks","stop"]')"
  if has copilot; then
    copy_new .github/hooks/code-health.json .github/hooks/code-health.json
    copy_new .github/workflows/copilot-setup-steps.yml .github/workflows/copilot-setup-steps.yml
  elif has vscode; then
    # VS Code reads .github/hooks/*.json, so it shares the Copilot hook file.
    copy_new .github/hooks/code-health.json .github/hooks/code-health.json
  fi
  return 0
}

# 3. CodeScene MCP server
install_mcp() {
  [ "$MCP" = 1 ] || return 0
  if has claude || has copilot; then
    merge_json .mcp.json .mcp.json "$(at_path "$ADD_SERVER" '["mcpServers","codescene"]')"
  fi
  has vscode && merge_json .vscode/mcp.json .vscode/mcp.json "$(at_path "$ADD_SERVER" '["servers","codescene"]')"
  has cursor && merge_json .cursor/mcp.json .cursor/mcp.json "$(at_path "$ADD_SERVER" '["mcpServers","codescene"]')"
  has codex && install_codex_mcp
  return 0
}

install_codex_mcp() {
  local dst="$TARGET/.codex/config.toml"
  if [ -e "$dst" ] && grep -q '^\[mcp_servers\.codescene\]' "$dst"; then say ok ".codex/config.toml"
  elif [ -e "$dst" ]; then [ "$DRY" = 1 ] || { printf '\n'; cat "$T/.codex/config.toml"; } >> "$dst"; say merged ".codex/config.toml"
  else run mkdir -p "$TARGET/.codex"; run cp "$T/.codex/config.toml" "$dst"; say added ".codex/config.toml"; fi
}

# 4. AGENTS.md (append a marked section if the repo already has one)
install_agents_md() {
  [ "$AGENTS_MD" = 1 ] || return 0
  local dst="$TARGET/AGENTS.md"
  if [ ! -e "$dst" ]; then run cp "$KIT/AGENTS.md" "$dst"; say added "AGENTS.md"
  elif grep -q 'codescene-code-health:start' "$dst"; then say ok "AGENTS.md (CodeScene section present)"
  else [ "$DRY" = 1 ] || { printf '\n'; sed -n '/codescene-code-health:start/,/codescene-code-health:end/p' "$KIT/AGENTS.md"; } >> "$dst"
    say merged "AGENTS.md (CodeScene section appended)"; fi
}

print_next() {
  cat <<EOF

Next:
  1. Each developer: install cs and sign in (cs auth login). See README "Install the cs CLI".
  2. Commit the files above. Copilot cloud agent reads hooks from the default branch only.
  3. Trust the repo in each agent (Copilot CLI and Codex silently skip untrusted repos).
  4. Test: make a change that lowers Code Health and ask the agent to finish.
EOF
}

main() {
  parse_args "$@"
  resolve_target
  choose_agents
  locate_kit
  echo
  echo "CodeScene Code Health gate -> $TARGET ($AGENTS)"
  [ "$DRY" = 1 ] && echo "(dry run)"
  install_gate
  install_hooks
  install_mcp
  install_agents_md
  print_next
}

main "$@"
