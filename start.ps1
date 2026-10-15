# Start your Workbench agent on Windows, in WSL.
#
#   powershell -ExecutionPolicy Bypass -File start.ps1 -Api https://your-redline-server -Token rlat_...
#   ... -Api ... -Token ... -Service    first time, and start it at every Windows logon
#   ... start.ps1                       start it again (settings from config.yaml, kit updated)
#   ... start.ps1 opencode | claude     switch what runs the agent, and start it
#   ... -Runner opencode -Model provider/model
#   ... -Restart | -Stop | -Status | -Attach | -Logs | -Foreground | -DryRun
#   ... -Install | -Uninstall           start it at every Windows logon, or not any more
#
# The agent's command line runs on Linux, so on Windows it runs in WSL:
# this script hands everything to start.sh there. Claude Code (or OpenCode),
# git and Python 3.12+ have to be installed inside WSL (not in Windows).
# Settings are in config.yaml (flat `key: value` lines), the token in .env.
param(
  [Parameter(Position = 0)][string]$Command = "",
  [string]$Api = "",
  [string]$Token = "",
  [string]$Name = "",
  [string]$Runner = "",
  [string]$Model = "",
  [string]$Session = "",
  [switch]$Service,
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Restart,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Attach,
  [switch]$Logs,
  [switch]$Foreground,
  [switch]$DryRun
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

if ($Token -and $Token -notmatch '^rlat_[A-Za-z0-9_-]+$') { Write-Host "An agent token starts with rlat_ - make one in Workbench under Agent tokens."; exit 1 }
if ($Api -and $Api -notmatch '^https?://[^\s''"]+$') { Write-Host "The server address starts with https://"; exit 1 }
if ($Runner -and $Runner -notin @("claude", "opencode")) { Write-Host "-Runner is claude or opencode"; exit 1 }
if ($Command -and $Command -notin @("claude", "opencode", "start", "restart", "stop", "status", "attach", "logs", "install", "uninstall", "foreground")) {
  Write-Host "unknown command: $Command"; exit 1
}

# config.yaml: flat `key: value` lines (the same file start.sh reads).
function Get-Config([string]$Key) {
  $f = Join-Path $PSScriptRoot "config.yaml"
  if (-not (Test-Path $f)) { return "" }
  $v = ""
  foreach ($l in Get-Content $f) {
    if ($l -match "^$([regex]::Escape($Key)):\s*(.*?)\s*(\s#.*)?$") { $v = $Matches[1].Trim('"', "'") }
  }
  return $v
}

$session = Get-Config "session"
if (-not $session) { $session = "redline-agent" }
$taskName = "Workbench agent ($session)"

# Start at logon: a scheduled task that runs start.sh's service loop in WSL,
# in a hidden window, started again a minute after it stops.
function Install-Task {
  $wsl = "wsl.exe --cd '$PSScriptRoot' --exec bash ./start.sh --service-run"
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -Command `"$wsl`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Write-Host "installed: the task '$taskName' starts the agent at every logon - start.ps1 -Uninstall to undo"
}

function Uninstall-Task {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "uninstalled: it no longer starts at logon (start.ps1 starts it by hand)"
  } else { Write-Host "not installed" }
}

if ($Install -or $Command -eq "install") { Install-Task; exit 0 }
if ($Uninstall -or $Command -eq "uninstall") { Uninstall-Task; exit 0 }

$argv = @()
if ($Command)    { $argv += $Command }
if ($Api)        { $argv += @("--api", $Api) }
if ($Token)      { $argv += @("--token", $Token) }
if ($Name)       { $argv += @("--name", $Name) }
if ($Runner)     { $argv += @("--runner", $Runner) }
if ($Model)      { $argv += @("--model", $Model) }
if ($Session)    { $argv += @("--session", $Session) }
if ($Restart)    { $argv += "--restart" }
if ($Stop)       { $argv += "--stop" }
if ($Status)     { $argv += "--status" }
if ($Attach)     { $argv += "--attach" }
if ($Logs)       { $argv += "--logs" }
if ($Foreground) { $argv += "--foreground" }
if ($DryRun)     { $argv += "--dry-run" }

if ($Service) {
  # Set up (settings, kit) without opening the agent, then let the task run it.
  & wsl.exe --cd "$PSScriptRoot" --exec env REDLINE_NO_ATTACH=1 bash ./start.sh @argv
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Install-Task
  exit 0
}

# start.sh in this folder, run by WSL's bash - arguments passed as they are,
# no shell in between.
& wsl.exe --cd "$PSScriptRoot" --exec bash ./start.sh @argv
exit $LASTEXITCODE
