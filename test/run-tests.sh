#!/usr/bin/env bash
# Self-test for the gate script with a fake `cs` (no CodeScene account needed).
#   bash test/run-tests.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"; GATE="$KIT/.agents/hooks/code-health-gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cs" <<'EOF'
#!/bin/sh
case "$FAKE" in
  fail) echo "need token" >&2; exit 1 ;;
  empty) exit 0 ;;
  array) echo '[{"name":"a.js","old-score":9.09,"new-score":8.5},{"name":"n.js","old-score":null,"new-score":10},{"name":"ok.js","old-score":5,"new-score":9}]' ;;
  object) echo '{"results":[{"name":"b.js","new-score":6.0}],"metadata":{"status":"issues-found"}}' ;;
  clean) echo '{"results":[],"metadata":{"status":"no-issues-found"}}' ;;
esac
EOF
chmod +x "$TMP/bin/cs"
pass=0; fail=0
t() { # <name> <fake> <mode> <stdin> <want-exit> <want-stdout-regex|EMPTY|-> [env]
  local out ec
  out=$(env PATH="$TMP/bin:$PATH" FAKE="$2" "${7:-UNUSED=1}" bash "$GATE" "$3" <<<"$4" 2>/dev/null); ec=$?
  if [ "$ec" = "$5" ] && { [ "$6" = - ] || { [ "$6" = EMPTY ] && [ -z "$out" ]; } || printf '%s' "$out" | grep -Eq "$6"; }; then pass=$((pass+1)); echo "  ok    $1"
  else fail=$((fail+1)); echo "  FAIL  $1 (exit $ec, want $5; stdout: $out)"; fi
}
echo "gate: $GATE"
t "claude blocks on drop (exit 2)"          array  claude  '{"stop_hook_active":false}' 2 -
t "codex blocks on new file below 10"       object codex   '{}' 2 -
t "copilot prints decision block"           array  copilot '{}' 0 '"decision": "block"'
t "copilot prints VS Code field too"        array  copilot '{}' 0 'hookSpecificOutput'
t "cursor prints followup_message"          array  cursor  '{"loop_count":0}' 0 'followup_message'
t "clean change set passes"                 clean  claude  '{}' 0 EMPTY
t "empty cs output passes"                  empty  claude  '{}' 0 EMPTY
t "cs failure warns, does not block"        fail   claude  '{}' 1 -
t "retry guard: stop_hook_active"           array  claude  '{"stop_hook_active":true}' 0 EMPTY
t "Cursor running the Claude config: quiet" array  claude  '{"loop_count":0}' 0 EMPTY
t "Grok running the Cursor config: quiet"   array  cursor  '{}' 0 EMPTY GROK_HOOK_EVENT=stop
t "Grok running the Claude config: blocks"  array  claude  '{"stopHookActive":false,"reason":"end_turn"}' 2 - GROK_HOOK_EVENT=stop
t "Grok retry guard: stopHookActive"        array  claude  '{"stopHookActive":true,"reason":"end_turn"}' 0 EMPTY GROK_HOOK_EVENT=stop
t "Grok shutdown stop: quiet"               array  claude  '{"stopHookActive":false,"reason":"shutdown"}' 0 EMPTY GROK_HOOK_EVENT=stop
t "missing cs warns, does not block"        array  claude  '{}' 1 - PATH=/usr/bin:/bin
if cmp -s "$GATE" "$KIT/plugin/scripts/code-health-gate.sh"; then pass=$((pass+1)); echo "  ok    plugin copy of the script is identical"
else fail=$((fail+1)); echo "  FAIL  plugin/scripts/code-health-gate.sh differs from .agents/hooks/"; fi

echo "install: $KIT/install.sh"
check() { # <name> <command...>: pass if the command succeeds
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "  ok    $name"; else fail=$((fail+1)); echo "  FAIL  $name"; fi
}
inst() { (cd "$REPO/sub" && PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" bash "$KIT/install.sh" "$@" </dev/null 2>&1); }
REPO="$TMP/repo"; mkdir -p "$REPO/sub"; git -C "$REPO" init -q
mkdir -p "$REPO/.claude"; printf '{"permissions":{"allow":["Bash(ls)"]}}\n' > "$REPO/.claude/settings.json"
out=$(inst --agents claude,cursor)
check "installs at the repo root from a subfolder"   test -x "$REPO/.agents/hooks/code-health-gate.sh" -a -f "$REPO/.cursor/hooks.json" -a ! -e "$REPO/sub/.cursor"
check "merges into existing .claude/settings.json"   jq -e '.permissions.allow[0] == "Bash(ls)" and (.hooks.Stop | length == 1)' "$REPO/.claude/settings.json"
check "skips agents not asked for"                   test ! -e "$REPO/.codex" -a ! -e "$REPO/.github"
out=$(inst --agents claude,cursor)
check "second run changes nothing"                   bash -c '! grep -Eq "added|merged|written" <<<"$1"' _ "$out"
out=$(inst --dry-run)
check "no terminal: uses agents found in the repo"   grep -q "(claude,cursor)" <<<"$out"
check "outside a git repo: fails"                    bash -c '! (cd "$1" && bash "$2" --agents claude </dev/null)' _ "$TMP/bin" "$KIT/install.sh"
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
