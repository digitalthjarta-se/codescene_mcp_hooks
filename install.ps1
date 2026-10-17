# Install the CodeScene Code Health gate, MCP config and AGENTS.md into a git repository.
# PowerShell version of install.sh (Windows PowerShell 5.1 or PowerShell 7+). Run it from inside the repo:
#
#   irm https://raw.githubusercontent.com/digitalthjarta-se/codescene_mcp_hooks/main/install.ps1 | iex
#
# With options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/digitalthjarta-se/codescene_mcp_hooks/main/install.ps1))) -Agents claude,codex
#
# Existing files are merged, never overwritten. Run it again to update the gate script.
# The gate itself is a bash script: agents on Windows run it through Git Bash (or WSL).
param(
  [string[]]$Agents = @(),   # claude, copilot, codex, cursor, vscode (skips the question)
  [switch]$SkipMcp,          # don't add CodeScene MCP server config
  [switch]$SkipAgentsMd,     # don't add or extend AGENTS.md
  [switch]$DryRun,           # print what would change, change nothing
  [string]$Repo = ''         # repo path (default: the repo containing the current folder)
)

$ErrorActionPreference = 'Stop'

$KitRepo = if ($env:CODESCENE_HOOKS_REPO) { $env:CODESCENE_HOOKS_REPO } else { 'digitalthjarta-se/codescene_mcp_hooks' }
$KitRef = if ($env:CODESCENE_HOOKS_REF) { $env:CODESCENE_HOOKS_REF } else { 'main' }
$AgentIds = @('claude', 'copilot', 'codex', 'cursor', 'vscode')
$AgentNames = @('Claude Code (also Grok Build)', 'GitHub Copilot (CLI and cloud agent)', 'Codex', 'Cursor', 'VS Code (Copilot agent mode)')
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Target = ''
$script:Kit = ''
$script:Tmp = ''
$script:Chosen = @()

function Stop-Install([string]$Message) { throw "install.ps1: $Message" }
function Say([string]$Verb, [string]$Message) { '  {0,-8} {1}' -f $Verb, $Message | Write-Host }
function Has-Command([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function Has-Agent([string]$Id) { $script:Chosen -contains $Id }

# Always LF, no BOM: the gate script and hook configs are read by bash.
function Write-Text([string]$Path, [string]$Text) {
  if ($DryRun) { return }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $Utf8)
}

function Read-Text([string]$Path) { [IO.File]::ReadAllText($Path, $Utf8) -replace "`r`n", "`n" }

function Same-Content([string]$A, [string]$B) { (Read-Text $A) -eq (Read-Text $B) }

# Use the templates next to this script, or download them when it was piped to iex.
function Find-Kit {
  $here = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { '' }
  if ($here -and (Test-Path (Join-Path $here 'templates'))) { $script:Kit = $here; return }
  $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('codescene-hooks-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $script:Tmp | Out-Null
  $zip = Join-Path $script:Tmp 'kit.zip'
  Write-Host "Downloading $KitRepo@$KitRef"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$KitRepo/zip/$KitRef" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $script:Tmp -Force
  } catch { Stop-Install "could not download https://github.com/$KitRepo ($KitRef): $_" }
  $script:Kit = (Get-ChildItem -Directory $script:Tmp | Select-Object -First 1).FullName
}

function Resolve-Target {
  $dir = if ($Repo) { $Repo } else { (Get-Location).Path }
  if (-not (Test-Path $dir -PathType Container)) { Stop-Install "not a directory: $dir" }
  if (-not (Has-Command git)) { Stop-Install 'git is required' }
  $top = git -C $dir rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $top) { Stop-Install "not inside a git repository: $dir (cd into your repo, or pass -Repo)" }
  $script:Target = [IO.Path]::GetFullPath($top)
}

# True if the repo or PATH suggests the agent is in use.
function Test-Detected([string]$Id) {
  $map = @{
    claude  = @{ Dirs = @('.claude'); Cmds = @('claude', 'grok') }
    copilot = @{ Dirs = @('.github/hooks'); Cmds = @('copilot') }
    codex   = @{ Dirs = @('.codex'); Cmds = @('codex') }
    cursor  = @{ Dirs = @('.cursor'); Cmds = @('cursor', 'cursor-agent') }
    vscode  = @{ Dirs = @('.vscode'); Cmds = @('code') }
  }
  foreach ($d in $map[$Id].Dirs) { if (Test-Path (Join-Path $script:Target $d)) { return $true } }
  foreach ($c in $map[$Id].Cmds) { if (Has-Command $c) { return $true } }
  $false
}

function Show-Menu([bool[]]$Selected) {
  Write-Host 'Which AI coding agents should get the gate?'
  for ($i = 0; $i -lt $AgentIds.Count; $i++) {
    $box = if ($Selected[$i]) { 'x' } else { ' ' }
    Write-Host ("  {0}) [{1}] {2}" -f ($i + 1), $box, $AgentNames[$i])
  }
}

function Ask-Agents([bool[]]$Selected) {
  while ($true) {
    Show-Menu $Selected
    $reply = (Read-Host 'Type numbers to toggle (e.g. "1 3"), a = all, n = none, Enter = install').Trim()
    if ($reply -eq '') { return $Selected }
    if ($reply -eq 'a') { $Selected = @($true) * $AgentIds.Count }
    elseif ($reply -eq 'n') { $Selected = @($false) * $AgentIds.Count }
    else {
      foreach ($n in ($reply -split '[ ,]+')) {
        $i = 0
        if ([int]::TryParse($n, [ref]$i) -and $i -ge 1 -and $i -le $AgentIds.Count) { $Selected[$i - 1] = -not $Selected[$i - 1] }
      }
    }
    Write-Host ''
  }
}

function Test-Interactive { [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }

function Select-Agents {
  if ($Agents.Count -gt 0) {
    $list = @($Agents | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    foreach ($a in $list) { if ($AgentIds -notcontains $a) { Stop-Install "unknown agent: $a (use: $($AgentIds -join ', '))" } }
    $script:Chosen = $list
    return
  }
  [bool[]]$selected = $AgentIds | ForEach-Object { Test-Detected $_ }
  if (-not ($selected -contains $true)) { $selected = @($true) * $AgentIds.Count }
  if (Test-Interactive) { $selected = Ask-Agents $selected }
  else { Write-Host 'No terminal to ask on; using detected agents (set them with -Agents).' }
  $script:Chosen = @(for ($i = 0; $i -lt $AgentIds.Count; $i++) { if ($selected[$i]) { $AgentIds[$i] } })
  if ($script:Chosen.Count -eq 0) { Stop-Install 'no agents selected' }
}

# Copy a file if it doesn't exist; report if it exists.
function Copy-New([string]$Rel, [string]$Dst) {
  $src = Join-Path $script:Kit "templates/$Rel"
  $dstPath = Join-Path $script:Target $Dst
  if (-not (Test-Path $dstPath)) { Write-Text $dstPath (Read-Text $src); Say added $Dst }
  elseif (Same-Content $src $dstPath) { Say ok $Dst }
  else { Say skipped "$Dst (exists, differs: merge by hand from templates/$Rel)" }
}

# True if any string value anywhere in the JSON mentions the gate script.
function Test-HasGate($Node) {
  if ($null -eq $Node) { return $false }
  if ($Node -is [string]) { return $Node -match 'code-health-gate\.sh' }
  if ($Node -is [System.Collections.IEnumerable]) { foreach ($x in $Node) { if (Test-HasGate $x) { return $true } }; return $false }
  if ($Node -is [psobject]) { foreach ($p in $Node.PSObject.Properties) { if (Test-HasGate $p.Value) { return $true } } }
  $false
}

function Get-AtPath($Obj, [string[]]$Path) {
  foreach ($k in $Path) {
    if ($null -eq $Obj -or -not ($Obj.PSObject.Properties.Name -contains $k)) { return $null }
    $Obj = $Obj.$k
  }
  , $Obj
}

# Set a value at a path, creating objects on the way.
function Set-AtPath($Obj, [string[]]$Path, $Value) {
  for ($i = 0; $i -lt $Path.Count - 1; $i++) {
    $k = $Path[$i]
    if (-not ($Obj.PSObject.Properties.Name -contains $k)) { $Obj | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{}) }
    $Obj = $Obj.$k
  }
  $last = $Path[-1]
  if ($Obj.PSObject.Properties.Name -contains $last) { $Obj.$last = $Value }
  else { $Obj | Add-Member -NotePropertyName $last -NotePropertyValue $Value }
}

# Merge a JSON template into an existing JSON file.
# Mode 'hook': append the template's hook group at Path unless a gate hook exists. Mode 'server': add Path if missing.
function Merge-Json([string]$Rel, [string]$Dst, [string]$Mode, [string[]]$Path) {
  $src = Join-Path $script:Kit "templates/$Rel"
  $dstPath = Join-Path $script:Target $Dst
  if (-not (Test-Path $dstPath)) { Write-Text $dstPath (Read-Text $src); Say added $Dst; return }
  try {
    $doc = (Read-Text $dstPath) | ConvertFrom-Json
    $tpl = (Read-Text $src) | ConvertFrom-Json
    if ($doc.GetType().Name -ne 'PSCustomObject') { throw 'not an object' }
  } catch { Say skipped "$Dst (not plain JSON, maybe comments: merge by hand from templates/$Rel)"; return }
  $before = $doc | ConvertTo-Json -Depth 20
  if ($Mode -eq 'hook') {
    if (-not (Test-HasGate $doc)) {
      $existing = @(Get-AtPath $doc $Path)
      Set-AtPath $doc $Path (@($existing | Where-Object { $null -ne $_ }) + @(Get-AtPath $tpl $Path))
    }
  } elseif ($null -eq (Get-AtPath $doc $Path)) {
    Set-AtPath $doc $Path (Get-AtPath $tpl $Path)
  }
  $after = $doc | ConvertTo-Json -Depth 20
  if ($after -eq $before) { Say ok $Dst } else { Write-Text $dstPath ($after + "`n"); Say merged $Dst }
}

# 1. The gate script (always updated: it's ours)
function Install-Gate {
  $rel = '.agents/hooks/code-health-gate.sh'
  $src = Join-Path $script:Kit $rel
  $dst = Join-Path $script:Target $rel
  if ((Test-Path $dst) -and (Same-Content $src $dst)) { Say ok $rel; return }
  Write-Text $dst (Read-Text $src)
  Say written $rel
}

# 2. Hook registration per agent
function Install-Hooks {
  if (Has-Agent claude) { Merge-Json '.claude/settings.json' '.claude/settings.json' hook @('hooks', 'Stop') }
  if (Has-Agent codex) { Merge-Json '.codex/hooks.json' '.codex/hooks.json' hook @('hooks', 'Stop') }
  if (Has-Agent cursor) { Merge-Json '.cursor/hooks.json' '.cursor/hooks.json' hook @('hooks', 'stop') }
  if (Has-Agent copilot) {
    Copy-New '.github/hooks/code-health.json' '.github/hooks/code-health.json'
    Copy-New '.github/workflows/copilot-setup-steps.yml' '.github/workflows/copilot-setup-steps.yml'
  } elseif (Has-Agent vscode) {
    # VS Code reads .github/hooks/*.json, so it shares the Copilot hook file.
    Copy-New '.github/hooks/code-health.json' '.github/hooks/code-health.json'
  }
}

function Install-CodexMcp {
  $src = Join-Path $script:Kit 'templates/.codex/config.toml'
  $dst = Join-Path $script:Target '.codex/config.toml'
  if (-not (Test-Path $dst)) { Write-Text $dst (Read-Text $src); Say added '.codex/config.toml'; return }
  $current = Read-Text $dst
  if ($current -match '(?m)^\[mcp_servers\.codescene\]') { Say ok '.codex/config.toml'; return }
  Write-Text $dst ($current + "`n" + (Read-Text $src))
  Say merged '.codex/config.toml'
}

# 3. CodeScene MCP server
function Install-Mcp {
  if ($SkipMcp) { return }
  if ((Has-Agent claude) -or (Has-Agent copilot)) { Merge-Json '.mcp.json' '.mcp.json' server @('mcpServers', 'codescene') }
  if (Has-Agent vscode) { Merge-Json '.vscode/mcp.json' '.vscode/mcp.json' server @('servers', 'codescene') }
  if (Has-Agent cursor) { Merge-Json '.cursor/mcp.json' '.cursor/mcp.json' server @('mcpServers', 'codescene') }
  if (Has-Agent codex) { Install-CodexMcp }
}

# 4. AGENTS.md (append a marked section if the repo already has one)
function Install-AgentsMd {
  if ($SkipAgentsMd) { return }
  $src = Join-Path $script:Kit 'AGENTS.md'
  $dst = Join-Path $script:Target 'AGENTS.md'
  if (-not (Test-Path $dst)) { Write-Text $dst (Read-Text $src); Say added 'AGENTS.md'; return }
  $current = Read-Text $dst
  if ($current -match 'codescene-code-health:start') { Say ok 'AGENTS.md (CodeScene section present)'; return }
  $section = [regex]::Match((Read-Text $src), '(?s)[^\n]*codescene-code-health:start.*?codescene-code-health:end[^\n]*').Value
  Write-Text $dst ($current + "`n" + $section + "`n")
  Say merged 'AGENTS.md (CodeScene section appended)'
}

# The gate is bash and needs jq and cs: say so now rather than let it skip silently.
function Test-Prerequisites {
  $missing = @(@('bash', 'jq', 'cs') | Where-Object { -not (Has-Command $_) })
  if ($missing.Count -eq 0) { return }
  Write-Host ''
  Write-Host "Not on PATH yet: $($missing -join ', ')." -ForegroundColor Yellow
  Write-Host '  bash: install Git for Windows (https://gitforwindows.org) so agents can run the gate through Git Bash.'
  Write-Host '  jq:   winget install jqlang.jq'
  Write-Host '  cs:   see README "Install the cs CLI". Until all three are found the gate prints "gate skipped" and lets the agent finish.'
}

function Show-Next {
  Write-Host @'

Next:
  1. Each developer: install cs and sign in (cs auth login). See README "Install the cs CLI".
  2. Commit the files above. Copilot cloud agent reads hooks from the default branch only.
  3. Trust the repo in each agent (Copilot CLI and Codex silently skip untrusted repos).
  4. Test: make a change that lowers Code Health and ask the agent to finish.
'@
}

function Main {
  Resolve-Target
  Select-Agents
  Find-Kit
  Write-Host ''
  Write-Host "CodeScene Code Health gate -> $script:Target ($($script:Chosen -join ','))"
  if ($DryRun) { Write-Host '(dry run)' }
  Install-Gate
  Install-Hooks
  Install-Mcp
  Install-AgentsMd
  Test-Prerequisites
  Show-Next
}

try { Main }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; $global:LASTEXITCODE = 1 }
finally { if ($script:Tmp -and (Test-Path $script:Tmp)) { Remove-Item -Recurse -Force $script:Tmp } }
