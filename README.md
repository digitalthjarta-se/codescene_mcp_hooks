# CodeScene Code Health gate for AI coding agents

Makes AI coding agents keep Code Health up, using [CodeScene](https://codescene.com):

1. **`AGENTS.md`** tells the agent to use the CodeScene MCP tools and to refactor until Code Health recovers. Advisory: the model can skip it.
2. **The CodeScene MCP server** gives the agent `code_health_review`, `pre_commit_code_health_safeguard` and friends.
3. **A stop hook** (`.agents/hooks/code-health-gate.sh`) runs when the agent tries to finish. If any changed file got worse, or a new file scores below 10, the agent is sent back to fix it. Deterministic: the model can't skip it.

The hook is not a merge gate. It allows one forced retry per stop, then lets the agent finish. Keep a CodeScene PR check as the gate that can say no.

One script serves every agent. Each agent gets a small config that points to it:

| Agent | Hook config (committed) | Event | Tested |
|---|---|---|---|
| Claude Code | `.claude/settings.json` | `Stop` | Live, 2.1.283 (repo config and plugin) |
| Grok Build | reads `.claude/settings.json` | `Stop` | Live, 1.0.41 |
| GitHub Copilot CLI | `.github/hooks/code-health.json` | `agentStop` | Live, 1.0.89 |
| VS Code (Copilot agent) | reads `.github/hooks/*.json` | `agentStop` = `Stop` | Checked in VS Code source |
| Copilot cloud agent | `.github/hooks/code-health.json` | `agentStop` | Docs only |
| Codex | `.codex/hooks.json` | `Stop` | Checked in Codex source |
| Cursor | `.cursor/hooks.json` | `stop` | Docs only |

"Live" means a real agent session was blocked, refactored and finished. Copilot CLI and Grok Build ran on macOS with the real `cs` (both took a file from 8.28 back to 10.0).

## Quick start

```bash
# 1. Once per machine: the CodeScene CLI, then sign in
curl -fsSL https://downloads.codescene.io/enterprise/cli/install-cs-tool.sh | sh
cs auth login

# 2. Once per repo: add hooks, MCP config and AGENTS.md
git clone git@github.com:digitalthjarta-se/codescene_mcp_hooks.git
./codescene_mcp_hooks/install.sh ~/Projects/my-repo
cd ~/Projects/my-repo && git add -A && git commit -m "Add CodeScene Code Health gate"

# 3. Trust the repo in your agent (see "Trust" below), then test:
#    make a function worse, ask the agent to finish, watch it get sent back.
```

`install.sh` never overwrites. It merges into existing `.claude/settings.json`, `.mcp.json` and friends, appends a marked section to an existing `AGENTS.md`, and skips JSON files with comments (it tells you which). Options: `--agents claude,codex,copilot,cursor,vscode`, `--skip-mcp`, `--skip-agents-md`, `--dry-run`. Run it again to update the script.

Requirements: `bash`, `git`, `jq` (built into macOS 15+, else `brew install jq`), `cs`, and Node.js 18+ for the MCP server.

## Install the CodeScene MCP server

The MCP server runs with `npx @codescene/codehealth-mcp` (downloads and caches the right binary on first run). `install.sh` writes the repo-level configs below, so teammates get it on clone.

| Agent | Repo file (written by `install.sh`) | Or, per user |
|---|---|---|
| Claude Code, Copilot CLI, Grok Build | `.mcp.json` | `claude mcp add codescene -- npx -y @codescene/codehealth-mcp` |
| VS Code | `.vscode/mcp.json` | CodeScene MCP extension (`codescene.codescene-codehealth-mcp`) |
| Cursor | `.cursor/mcp.json` | `~/.cursor/mcp.json` |
| Codex | `.codex/config.toml` | `~/.codex/config.toml` |

Other ways to install the server itself:

- Claude Code plugin with MCP server and CodeScene skills: `/plugin marketplace add codescene-oss/codescene-mcp-server`, then `/plugin install codescene@codescene`
- Homebrew: `brew tap codescene-oss/codescene-mcp-server https://github.com/codescene-oss/codescene-mcp-server && brew install cs-mcp`
- Windows: `irm https://raw.githubusercontent.com/codescene-oss/codescene-mcp-server/main/install.ps1 | iex`

Then sign in once: ask the agent *"Log me in to CodeScene"* (calls the `login` tool), or run the `login` MCP prompt. Details: [CodeScene MCP authentication](https://github.com/codescene-oss/codescene-mcp-server/blob/main/docs/authentication.md).

## Install the cs CLI

The hook calls the CodeScene CLI (`cs`), not the MCP server (`cs-mcp`). `cs-mcp` carries its own private copy of `cs`, but the hook can't rely on that path, so install `cs` too.

```bash
# macOS / Linux: installs to ~/.local/bin and adds it to PATH in your shell rc
curl -fsSL https://downloads.codescene.io/enterprise/cli/install-cs-tool.sh | sh
# CI / non-interactive: add -y to skip the prompt
curl -fsSL https://downloads.codescene.io/enterprise/cli/install-cs-tool.sh | sh -s -- -y
```

```powershell
# Windows (PowerShell)
Invoke-WebRequest -Uri 'https://downloads.codescene.io/enterprise/cli/install-cs-tool.ps1' -OutFile install-cs-tool.ps1
.\install-cs-tool.ps1
```

The installer needs `curl` and `unzip` and downloads from `downloads.codescene.io` and `devtools.codescene.io`. Check with `cs version`. The hook adds `~/.local/bin` to its own PATH, so it finds `cs` even when the agent was started from the Dock or Start menu.

Windows: the hook is a bash script. It runs where the agent runs hooks through bash (Git Bash for Claude Code, WSL). Copilot's `powershell` hook key isn't provided.

## Authentication: recommendations

`cs` looks for credentials in this order: `CS_ACCESS_TOKEN`, then a stored sign-in from `cs auth login`, then legacy on-prem basic auth. The MCP server uses `CS_ACCESS_TOKEN` or its own `login` tool.

| Where | Use | Why |
|---|---|---|
| Your machine | `cs auth login` for the hook, the MCP `login` tool for the server | Browser sign-in, stored and auto-refreshed. Works for agents started from the Dock, which don't see variables set in `.zshrc` |
| CI, cloud agents | `CS_ACCESS_TOKEN` as a secret | No browser there. Use a token you can revoke on its own, and rotate it |
| CodeScene on-prem | `CS_ONPREM_URL=https://codescene.example.com`, then either of the above | |

- Create a personal access token at [codescene.io/users/me/pat](https://codescene.io/users/me/pat) (on-prem: `https://<host>/configuration/user/token`).
- `CS_ACCESS_TOKEN` wins over a stored sign-in when both exist. If `cs auth status` shows the wrong account, check for a stale token in your environment.
- Never commit a token. `install.sh` writes no credentials.
- Tested with a CodeScene Cloud token. A standalone MCP license should work for the tools it covers, but hasn't been tried with the hook.

## Trust: the silent failure

Most agents only run repo hooks and repo MCP servers in a folder you have trusted. Untrusted means the hook just doesn't run, with no warning.

| Agent | How to trust |
|---|---|
| Claude Code | Accept the trust prompt when you first open the repo |
| Copilot CLI | Accept the folder trust prompt, or add the path to `trustedFolders` in `~/.copilot/config.json`. Headless: `COPILOT_ALLOW_ALL=true` trusts the current folder |
| Grok Build | `/hooks-trust`, or start with `grok --trust`. Stored in `~/.grok/trusted_folders.toml` |
| Codex | Mark the project trusted; `.codex/` config only loads in trusted projects |
| VS Code | Workspace trust, and hooks enabled (`chat.useHooks`) |
| Cursor | Project hooks run in trusted workspaces |

## Notes per agent

- **Claude Code**: `Stop` hook, exit 2 sends the reason back to Claude. Default timeout 600 s; the config sets 120 s.
- **Grok Build**: runs the project `.claude/settings.json` hooks (with `CLAUDE_PROJECT_DIR` set), so it needs no config of its own. It also imports `.cursor/hooks.json`; the script ignores that second call. Grok's default hook timeout is 5 s, which is why the Claude config sets `"timeout": 120`. Grok fires `Stop` again at shutdown and marks the retry with `stopHookActive` (camelCase); the script handles both. Hooks from Claude Code plugins don't run in Grok yet ([xai-org/plugin-marketplace#236](https://github.com/xai-org/plugin-marketplace/issues/236)), so use the repo config, not the plugin.
- **Copilot CLI**: `agentStop` with JSON `{"decision":"block","reason":...}`. Needs a trusted folder (above). Default timeout 30 s; the config sets 120 s.
- **VS Code**: reads `.github/hooks/*.json`, maps `agentStop` to `Stop`, and reads the `hookSpecificOutput` that the script prints in Copilot mode. If `chat.useClaudeHooks` is on, it also runs the Claude config, so the gate runs twice per stop (same result, just slower).
- **Codex**: `Stop` in `.codex/hooks.json`, run through your login shell in the session's working directory, hence the `git rev-parse` path. Exit 2 with a reason continues the session.
- **Cursor**: `stop` hook, `followup_message` makes Cursor continue, `loop_limit: 3` caps it. Cursor also imports `.claude/settings.json` by default; the script ignores that second call.

## Cloud agents

### GitHub Copilot cloud agent

1. Commit `.github/hooks/code-health.json` and `.github/workflows/copilot-setup-steps.yml` (both from `install.sh`) to the **default branch**. The cloud agent only reads hooks from there.
2. The setup workflow installs `cs` before the agent starts. The job must be named `copilot-setup-steps`.
3. Add the token for the hook: repo **Settings > Secrets and variables > Agents**, secret `CS_ACCESS_TOKEN`. Agents secrets become environment variables in the agent session, so the hook sees it.
4. MCP server: repo **Settings > Copilot > MCP servers**, paste [`cloud/copilot-cloud-agent-mcp.json`](cloud/copilot-cloud-agent-mcp.json). Add a second Agents secret, `COPILOT_MCP_CS_ACCESS_TOKEN`, with the same token: only `COPILOT_MCP_*` secrets reach MCP servers, and those don't reach the session.
5. Firewall: repo **Settings > Copilot > Internet access**, add `api.codescene.io` and `codescene.io` to the custom allowlist. Setup steps and MCP servers aren't behind the firewall, but commands the agent runs itself (like `cs review`) are.

A forced extra turn counts against the job's time limit.

### Claude Code cloud sessions (claude.ai/code, `claude --cloud`)

Cloud sessions start from a fresh clone and read the repo's `.claude/settings.json` hooks and `.mcp.json`, in sessions with one repository. They don't install plugins, so use the repo config here.

In the cloud environment settings:

1. **Setup script**: paste [`cloud/claude-cloud-setup.sh`](cloud/claude-cloud-setup.sh). It installs `cs` and `jq`.
2. **Environment variables**: `CS_ACCESS_TOKEN=<token>` and `CS_DISABLE_VERSION_CHECK=1`. Anyone who uses the environment can read these values, so use a dedicated token.
3. **Network access**: Custom, keep the default list, and add `downloads.codescene.io`, `devtools.codescene.io`, `api.codescene.io`, `codescene.io`.

Sessions with several repositories don't run repo hooks.

## Claude Code plugin (optional)

The hook is also packaged as a Claude Code plugin, for people who want it in every repo without committing files:

```
/plugin marketplace add digitalthjarta-se/codescene_mcp_hooks
/plugin install code-health-gate@digitalthjarta
```

To offer it to everyone who opens a repo, commit this to that repo's `.claude/settings.json`; teammates get it after they trust the folder:

```json
{
  "extraKnownMarketplaces": {
    "digitalthjarta": { "source": { "source": "github", "repo": "digitalthjarta-se/codescene_mcp_hooks" } }
  },
  "enabledPlugins": { "code-health-gate@digitalthjarta": true }
}
```

Use the plugin **or** the repo hook, not both (the gate would run twice). The plugin needs the same `cs` and sign-in. It doesn't work in Claude Code cloud sessions or in Grok Build: use the repo config there. The plugin only contains the hook. For the MCP server and CodeScene's skills, install CodeScene's own plugin (above).

## How the gate decides

1. Skip if this is already the forced retry (`stop_hook_active`, or `stopHookActive` in Grok), Grok's shutdown stop, or a duplicate import (Cursor or Grok running another agent's config).
2. Run `cs delta --output-format=json`: all uncommitted changes against `HEAD`, including staged and untracked files. The MCP tool `pre_commit_code_health_safeguard` runs the same command.
3. Block if a changed file's score dropped, or a new file scores below 10. (CodeScene's own git pre-commit hook blocks every new file; that's too strict for a stop hook.)
4. Send the reason back in the format each agent expects: exit 2 with the message on stderr (Claude Code, Codex, Grok), JSON `decision: block` (Copilot, VS Code), or `followup_message` (Cursor).

If `cs` or `jq` is missing, or `cs` can't sign in, the hook prints "gate skipped" and exits 1. In every agent that's a warning, never a block, so a broken setup can't trap the agent.

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing happens when the agent finishes | Repo trusted? Hook file committed (default branch for Copilot cloud)? Run `bash .agents/hooks/code-health-gate.sh claude <<<'{}'; echo $?` in the repo |
| "gate skipped: needs cs and jq" | `cs version`, `jq --version`, and whether `cs` is in `~/.local/bin` |
| "gate skipped: cs delta failed (signed in?)" | `cs auth status`, run `cs delta` in the repo |
| Hook times out | Large change set. Raise `timeout` / `timeoutSec` in the agent's config |
| Gate runs twice | Plugin and repo hook both active, or VS Code with `chat.useClaudeHooks` |

## Testing the script

```bash
bash test/run-tests.sh   # fake cs, no account needed: 16 cases, every agent mode
```

## Files

```
.agents/hooks/code-health-gate.sh      the gate (copied into each repo)
AGENTS.md                              agent instructions (copied or appended)
install.sh                             adds all of the below to a repo
templates/                             per-agent hook and MCP configs, Copilot setup workflow
cloud/                                 Claude cloud setup script, Copilot cloud agent MCP config
plugin/ + .claude-plugin/              Claude Code plugin and marketplace
test/run-tests.sh                      self-test
```

## Credits

`AGENTS.md` is adapted from CodeScene's [AGENTS-full.md](https://github.com/codescene-oss/codescene-mcp-server/blob/main/docs/AGENTS-full.md) (Apache-2.0). The degradation check follows CodeScene's own [`hooks/pre-commit`](https://github.com/codescene-oss/codescene-mcp-server/blob/main/hooks/pre-commit).
