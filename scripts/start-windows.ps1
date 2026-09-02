[CmdletBinding()]
param(
  [ValidateRange(1, 65535)]
  [int]$Port = 3030,
  [string]$DshHome,
  [string]$RuntimeRoot,
  [switch]$ResetBuiltInSkin,
  [switch]$OpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repair = Join-Path $PSScriptRoot 'repair-windows.ps1'
$repairArguments = @{}
if ($DshHome) { $repairArguments.DshHome = $DshHome }
if ($RuntimeRoot) { $repairArguments.RuntimeRoot = $RuntimeRoot }
if ($ResetBuiltInSkin) { $repairArguments.ResetBuiltInSkin = $true }
& $repair @repairArguments

$dshCommand = Get-Command dsh -ErrorAction Stop
$launchArguments = @('web', '--port', $Port.ToString())
if (-not $OpenBrowser) {
  $launchArguments += '--no-open'
}

Write-Host "Starting the official DSH runtime on http://127.0.0.1:$Port"
& $dshCommand.Source @launchArguments
exit $LASTEXITCODE
