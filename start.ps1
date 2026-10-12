# Start your Redline agent on Windows, in WSL.
#
#   powershell -ExecutionPolicy Bypass -File start.ps1 -Api https://your-redline-server -Token rlat_...
#   powershell -ExecutionPolicy Bypass -File start.ps1            start again (settings from .env)
#   ... -Restart | -Stop | -Status | -Foreground
#
# The agent's command line runs on Linux, so on Windows it runs in WSL:
# this script hands everything to start.sh there. Claude Code, git and
# Python 3.12+ have to be installed inside WSL (not in Windows).
param(
  [string]$Api = "",
  [string]$Token = "",
  [string]$Name = "",
  [switch]$Restart,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Foreground
)
$ErrorActionPreference = "Stop"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Write-Host "WSL is needed: run 'wsl --install' in an administrator PowerShell, restart Windows,"
  Write-Host "open Ubuntu once to finish it, then run this again."
  exit 1
}
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "WSL has no Linux installed yet: run 'wsl --install -d Ubuntu', open Ubuntu once, then run this again."
  exit 1
}

if ($Token -and $Token -notmatch '^rlat_[A-Za-z0-9_-]+$') { Write-Host "An agent token starts with rlat_ - make one in Redline under Agent tokens."; exit 1 }
if ($Api -and $Api -notmatch '^https?://[^\s''"]+$') { Write-Host "The server address starts with https://"; exit 1 }

$argv = @()
if ($Api)        { $argv += @("--api", $Api) }
if ($Token)      { $argv += @("--token", $Token) }
if ($Name)       { $argv += @("--name", $Name) }
if ($Restart)    { $argv += "--restart" }
if ($Stop)       { $argv += "--stop" }
if ($Status)     { $argv += "--status" }
if ($Foreground) { $argv += "--foreground" }

# start.sh in this folder, run by WSL's bash - arguments passed as they are,
# no shell in between.
& wsl.exe --cd "$PSScriptRoot" --exec bash ./start.sh @argv
exit $LASTEXITCODE
