#!/usr/bin/env bash
# .agents/hooks/code-health-gate.sh <claude|codex|copilot|cursor>
input=$(cat); agent="${1:-claude}"; PATH="$HOME/.local/bin:$PATH"
{ command -v cs && command -v jq; } >/dev/null || { echo "gate skipped: needs cs and jq" >&2; exit 1; }
# Grok Build runs the Claude config itself; skip its import of the Cursor config
[ -n "${GROK_HOOK_EVENT:-}" ] && [ "$agent" != claude ] && exit 0
# skip: forced retry (one per stop), Grok's shutdown stop, Cursor importing the Claude config
jq -e --arg a "$agent" '.stop_hook_active == true or .stopHookActive == true or .reason == "shutdown"
  or (has("loop_count") and $a != "cursor")' >/dev/null 2>&1 <<<"$input" && exit 0
json=$(cs delta --output-format=json 2>/dev/null) ||
  { echo "gate skipped: cs delta failed (signed in?)" >&2; exit 1; }
degraded=$(jq -r '(if type == "object" then .results else . end)[]
  | select(.["new-score"] != null and .["new-score"] < (.["old-score"] // 10))
  | "\(.name): \(.["old-score"] // "new") -> \(.["new-score"])"' <<<"${json:-[]}") || exit 1
[ -z "$degraded" ] && exit 0
reason="Code Health dropped: $degraded. Refactor until it recovers: use the code_health_review"
reason+=" MCP tool or run cs review <file>, then re-check with cs delta."
case "$agent" in
  copilot) jq -n --arg r "$reason" '{decision:"block", reason:$r,
    hookSpecificOutput:{hookEventName:"Stop", decision:"block", reason:$r}}' ;;
  cursor) jq -n --arg r "$reason" '{followup_message:$r}' ;;
  *) echo "$reason" >&2; exit 2 ;;  # Claude Code, Codex, VS Code
esac
