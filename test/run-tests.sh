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
t "Grok running the Claude config: blocks"  array  claude  '{}' 2 - GROK_HOOK_EVENT=stop
t "missing cs warns, does not block"        array  claude  '{}' 1 - PATH=/usr/bin:/bin
if cmp -s "$GATE" "$KIT/plugin/scripts/code-health-gate.sh"; then pass=$((pass+1)); echo "  ok    plugin copy of the script is identical"
else fail=$((fail+1)); echo "  FAIL  plugin/scripts/code-health-gate.sh differs from .agents/hooks/"; fi
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
