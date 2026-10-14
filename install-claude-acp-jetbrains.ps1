#Requires -Version 5.1
<#
.SYNOPSIS
  Installs and registers the Claude Agent SDK ACP agent
  (https://github.com/agentclientprotocol/claude-agent-acp) as a custom
  agent in JetBrains IDEs (2025.3+) via the Agent Client Protocol (ACP).

.DESCRIPTION
  1. Checks/installs Node.js >= 22 (required by the package) via winget or choco.
  2. Installs the pinned version of @agentclientprotocol/claude-agent-acp
     globally via npm (override with $env:CLAUDE_AGENT_ACP_VERSION), then
     applies the local fixes stored in patches\claude-agent-acp\<version>\
     (requires git, used as the patch tool).
  3. Checks for the Claude Code CLI (used for auth) and offers to install it.
  4. Registers the agent in %USERPROFILE%\.jetbrains\acp.json, merging with
     any existing agents already configured there.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-claude-acp-jetbrains.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Package           = "@agentclientprotocol/claude-agent-acp"
# The version the patches in patches\claude-agent-acp\ were made and tested against.
$PinnedVersion     = "0.86.0"
$AgentVersion      = if ($env:CLAUDE_AGENT_ACP_VERSION) { $env:CLAUDE_AGENT_ACP_VERSION } else { $PinnedVersion }
$PatchRoot         = Join-Path $PSScriptRoot "patches\claude-agent-acp"
$AgentDisplayName  = "Claude Agent (ACP)"
$MinNodeMajor      = 22
$ConfigDir         = Join-Path $env:USERPROFILE ".jetbrains"
$ConfigFile        = Join-Path $ConfigDir "acp.json"

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "XX  $msg" -ForegroundColor Red; exit 1 }

function Refresh-Path {
  $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
  $user    = [System.Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = @($machine, $user) -join ";"
}

function Get-NodeMajorVersion {
  try {
    $v = & node -e "console.log(process.versions.node.split('.')[0])" 2>$null
    return [int]$v
  } catch {
    return 0
  }
}

function Install-Node {
  Info "Node.js >= $MinNodeMajor is required but was not found (or is too old). Attempting to install it."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Info "Installing Node.js LTS via winget..."
    winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements
  } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
    Info "Installing Node.js LTS via Chocolatey..."
    choco install nodejs-lts -y
  } else {
    Fail "Could not auto-install Node.js (no winget or choco found). Install Node.js $MinNodeMajor+ manually from https://nodejs.org and re-run this script."
  }
  Refresh-Path
}

# ---------------------------------------------------------------------------
# 1. Node.js
# ---------------------------------------------------------------------------

Info "Checking Node.js..."
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Install-Node
}

if ((Get-NodeMajorVersion) -lt $MinNodeMajor) {
  $currentVersion = (& node -v)
  Warn "Found Node.js $currentVersion, but claude-agent-acp requires Node.js >= $MinNodeMajor."
  Install-Node
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail "Node.js installation failed." }
if ((Get-NodeMajorVersion) -lt $MinNodeMajor) {
  Fail "Node.js $((& node -v)) is still older than required (>= $MinNodeMajor). Install a newer version manually (e.g. from nodejs.org) and re-run this script."
}
Ok "Node.js $((& node -v))"

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  Fail "npm was not found even though Node.js is installed. Please check your Node.js installation."
}
Ok "npm $((& npm -v))"

# ---------------------------------------------------------------------------
# 2. Install the ACP agent package
# ---------------------------------------------------------------------------

Info "Installing $Package@$AgentVersion globally via npm..."
& npm install -g "$Package@$AgentVersion"
if ($LASTEXITCODE -ne 0) { Fail "Failed to install $Package@$AgentVersion." }
Ok "$Package@$AgentVersion installed"

$npmRoot = (& npm root -g).Trim()

# ---------------------------------------------------------------------------
# 2b. Apply local patches to the installed package
# ---------------------------------------------------------------------------
# Patches live in patches\claude-agent-acp\<version>\ and are made against that
# exact published version. A version with no folder of its own gets the pinned
# version's patches: applying them is an unexpected success (warning, check the
# result), failing to apply them is an error, since the bugs they fix may still
# be there. Windows has no 'patch' command, so git applies them; it behaves as
# a plain patch tool outside a repository.

function Invoke-GitApply($PkgDir, $PatchFile, [switch]$Reverse, [switch]$Check) {
  $gitArgs = @("-C", $PkgDir, "apply")
  if ($Reverse) { $gitArgs += "--reverse" }
  if ($Check) { $gitArgs += "--check" }
  $gitArgs += $PatchFile
  # Under "Stop", Windows PowerShell 5.1 turns a native command's stderr into a
  # terminating error, and a failing --check is an expected answer here.
  $ErrorActionPreference = "Continue"
  & git @gitArgs 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Apply-Patches($PkgDir, $InstalledVersion) {
  if (Test-Path (Join-Path $PatchRoot $InstalledVersion)) {
    $sourceVersion = $InstalledVersion
  } else {
    $sourceVersion = $PinnedVersion
    Warn "No patches recorded for $InstalledVersion; trying those made for $sourceVersion."
  }
  $patchDir = Join-Path $PatchRoot $sourceVersion
  # A missing folder is not "nothing to patch": only an existing folder without
  # a .patch file records that a version needs no fix.
  if (-not (Test-Path $patchDir)) {
    Fail "Patch folder $patchDir is missing; run this script from a full checkout of the repository."
  }
  $patches =@(Get-ChildItem -Path $patchDir -Filter *.patch -File -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($patches.Count -eq 0) {
    Ok "No patches to apply for $InstalledVersion"
    return
  }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git is required to apply $patchDir\*.patch."
  }
  foreach ($p in $patches) {
    if (Invoke-GitApply $PkgDir $p.FullName -Reverse -Check) {
      if ($sourceVersion -eq $InstalledVersion) {
        Ok "Patch $($p.Name) already applied"
      } else {
        Warn "Patch $($p.Name), made for $sourceVersion, is already present in ${InstalledVersion}: check whether upstream shipped the fix."
      }
    } elseif (Invoke-GitApply $PkgDir $p.FullName -Check) {
      if (-not (Invoke-GitApply $PkgDir $p.FullName)) {
        Fail "Patch $($p.Name) passed its check but failed to apply to $PkgDir."
      }
      if ($sourceVersion -eq $InstalledVersion) {
        Ok "Applied patch $($p.Name)"
      } else {
        Warn "Applied patch $($p.Name), made for $sourceVersion, to ${InstalledVersion}: unexpected success, check the fix is still needed and correct."
      }
    } else {
      Fail "Patch $($p.Name) (made for $sourceVersion) does not apply to $Package $InstalledVersion in $PkgDir. Its fix may be missing: update the patch, or, if upstream fixed it, create $PatchRoot\$InstalledVersion\ holding a README and no .patch file."
    }
  }
  # A hunk can apply in the wrong place and still report success: prove the
  # result loads and that each fix behaves, before the IDE launches it.
  $ErrorActionPreference = "Continue"
  & node --check (Join-Path $PkgDir "dist\acp-agent.js")
  if ($LASTEXITCODE -ne 0) { Fail "The patched $PkgDir\dist\acp-agent.js no longer parses." }
  foreach ($check in @(Get-ChildItem -Path $patchDir -Filter *.check.mjs -File | Sort-Object Name)) {
    & node $check.FullName $PkgDir
    if ($LASTEXITCODE -ne 0) {
      Fail "Check $($check.Name) failed against ${PkgDir}: the patched agent does not behave as the patch intends."
    }
  }
}

$pkgDir = Join-Path $npmRoot ($Package -replace '/', '\')
$pkgJson = Join-Path $pkgDir "package.json"
if (-not (Test-Path $pkgJson)) { Fail "Could not find the installed package at $pkgDir." }
$installedVersion = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
Info "Applying local patches to $Package $installedVersion..."
Apply-Patches $pkgDir $installedVersion

$distPath = Join-Path $npmRoot "@agentclientprotocol\claude-agent-acp\dist\index.js"
if (-not (Test-Path $distPath)) {
  Fail "Could not locate the installed package entry point at $distPath."
}
$nodePath = (Get-Command node).Source
Ok "Resolved agent entry point: $nodePath $distPath"

# ---------------------------------------------------------------------------
# 3. Claude Code CLI (auth)
# ---------------------------------------------------------------------------
# claude-agent-acp uses the Claude Agent SDK, which authenticates either via
# an ANTHROPIC_API_KEY or via the credentials stored by the Claude Code CLI
# (subscription login) at %USERPROFILE%\.claude\.credentials.json. Since
# JetBrains launches the agent as a subprocess without your shell profile,
# relying on the CLI's stored login is the more reliable path (no secrets
# need to go into the ACP config).

Info "Checking for the Claude Code CLI (used for authentication)..."
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Info "Claude Code CLI not found. Installing @anthropic-ai/claude-code globally..."
  & npm install -g "@anthropic-ai/claude-code"
  if ($LASTEXITCODE -ne 0) {
    Warn "Could not install the Claude Code CLI automatically. Install it yourself (npm install -g @anthropic-ai/claude-code) and run 'claude' once to log in, or set ANTHROPIC_API_KEY."
  }
  Refresh-Path
}

$envBlock = @{}
$credentialsFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
if (Get-Command claude -ErrorAction SilentlyContinue) {
  Ok "Claude Code CLI found: $((Get-Command claude).Source)"
  if (Test-Path $credentialsFile) {
    Ok "Existing Claude Code login detected - the ACP agent will reuse it."
  } else {
    Warn "Claude Code CLI is installed but you don't appear to be logged in yet."
    Warn "Run 'claude' once in a terminal to complete login before using the agent in your IDE."
  }
} elseif ($env:ANTHROPIC_API_KEY) {
  Warn "ANTHROPIC_API_KEY is set in this shell. Embedding it into $ConfigFile (plaintext) so JetBrains can pass it to the agent."
  $reply = Read-Host "Proceed with embedding ANTHROPIC_API_KEY in $ConfigFile? [y/N]"
  if ($reply -match '^[Yy]') {
    $envBlock = @{ ANTHROPIC_API_KEY = $env:ANTHROPIC_API_KEY }
  } else {
    Warn "Skipping. You'll need to add auth (ANTHROPIC_API_KEY or 'claude' login) before the agent works."
  }
} else {
  Warn "No Claude Code CLI login and no ANTHROPIC_API_KEY found."
  Warn "Before using the agent, either run 'claude' once to log in, or set ANTHROPIC_API_KEY and re-run this script."
}

# ---------------------------------------------------------------------------
# 4. Register the agent in %USERPROFILE%\.jetbrains\acp.json
# ---------------------------------------------------------------------------

function ConvertTo-HashtableDeep($InputObject) {
  # Note: two non-obvious PowerShell pitfalls are worked around here:
  #  - "-is [PSCustomObject]" can return $true for plain strings once they've
  #    passed through a pipeline (ForEach-Object), so PSCustomObject-ness is
  #    checked via GetType().Name instead of the "-is" operator.
  #  - returning a single-element array via "return"/the output stream
  #    unwraps it to a scalar at the call site; Write-Output -NoEnumerate
  #    prevents that collapse.
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $ht = @{}
    foreach ($key in $InputObject.Keys) { $ht[$key] = ConvertTo-HashtableDeep $InputObject[$key] }
    return $ht
  } elseif ($InputObject.GetType().Name -eq 'PSCustomObject') {
    $ht = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $ht[$p.Name] = ConvertTo-HashtableDeep $p.Value }
    return $ht
  } elseif ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
    $out = @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
    Write-Output -NoEnumerate $out
  } else {
    return $InputObject
  }
}

Info "Registering agent in $ConfigFile..."
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$config = $null
if (Test-Path $ConfigFile) {
  $backupPath = "$ConfigFile.bak.$(Get-Date -Format yyyyMMddHHmmss)"
  Copy-Item -Path $ConfigFile -Destination $backupPath
  try {
    $parsed = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $config = ConvertTo-HashtableDeep $parsed
  } catch {
    Warn "Existing $ConfigFile is not valid JSON; a backup was kept at $backupPath. Starting from a fresh config."
  }
}

if (-not $config) {
  $config = @{
    default_mcp_settings = @{ use_custom_mcp = $true; use_idea_mcp = $false }
    agent_servers = @{}
  }
}
if (-not $config.ContainsKey("agent_servers")) { $config["agent_servers"] = @{} }

$agentEntry = @{
  command       = $nodePath
  args          = @($distPath)
  use_idea_mcp  = $true
  use_custom_mcp = $true
}
if ($envBlock.Count -gt 0) { $agentEntry["env"] = $envBlock }

$config["agent_servers"][$AgentDisplayName] = $agentEntry

($config | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigFile -Encoding utf8

Ok "Registered '$AgentDisplayName' in $ConfigFile"

# ---------------------------------------------------------------------------
# 5. Detect installed JetBrains IDEs (informational only - must never fail
#    the script, since the important work above is already done)
# ---------------------------------------------------------------------------

try {
  $ideRoots = @()
  if ($env:LOCALAPPDATA) {
    $ideRoots += (Join-Path $env:LOCALAPPDATA "Programs")
    $ideRoots += (Join-Path $env:LOCALAPPDATA "JetBrains\Toolbox\apps")
  }
  if ($env:ProgramFiles) { $ideRoots += (Join-Path $env:ProgramFiles "JetBrains") }
  if (${env:ProgramFiles(x86)}) { $ideRoots += (Join-Path ${env:ProgramFiles(x86)} "JetBrains") }

  $idePattern = 'IntelliJ|PyCharm|WebStorm|GoLand|CLion|PhpStorm|RubyMine|Rider|DataGrip|RustRover'
  $foundIdes = foreach ($root in $ideRoots) {
    if (Test-Path $root) {
      Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $idePattern } |
        Select-Object -ExpandProperty Name
    }
  }
  $foundIdes = $foundIdes | Select-Object -Unique
  if ($foundIdes) {
    Ok "Detected JetBrains IDE(s): $($foundIdes -join ', ')"
  } else {
    Warn "No JetBrains IDE detected in common install locations. Install one (2025.3+) to use this agent."
  }
} catch {
  Warn "Could not scan for installed JetBrains IDEs (non-fatal): $($_.Exception.Message)"
}

Write-Host ""
Ok "Done."
Write-Host "Next steps:"
Write-Host "  1. Make sure your JetBrains IDE is on version 2025.3 or later, with the AI Assistant plugin updated."
Write-Host "  2. If you haven't already, run 'claude' once in a terminal to log in (or ensure ANTHROPIC_API_KEY is set)."
Write-Host "  3. Restart the IDE, open the AI Chat tool window, and select '$AgentDisplayName' from the agent picker."
