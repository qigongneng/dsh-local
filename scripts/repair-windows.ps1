[CmdletBinding()]
param(
  [string]$DshHome,
  [ValidateNotNullOrEmpty()]
  [string]$Profile = 'web',
  [string]$RuntimeRoot,
  [switch]$ResetBuiltInSkin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DshHome {
  if ($DshHome) {
    return [IO.Path]::GetFullPath($DshHome)
  }
  if ($env:DSH_HOME) {
    return [IO.Path]::GetFullPath($env:DSH_HOME)
  }
  return Join-Path $env:USERPROFILE '.dsh'
}

function Add-RuntimeCandidate {
  param(
    [Collections.Generic.List[string]]$Candidates,
    [string]$Candidate
  )
  if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
    [void]$Candidates.Add($Candidate)
  }
}

function Resolve-DshRuntimeRoot {
  if ($RuntimeRoot) {
    $resolved = [IO.Path]::GetFullPath($RuntimeRoot)
    if (-not (Test-Path (Join-Path $resolved 'package.json') -PathType Leaf)) {
      throw "DSH runtime package.json was not found below: $resolved"
    }
    return $resolved
  }

  $candidates = [Collections.Generic.List[string]]::new()
  Add-RuntimeCandidate $candidates $env:DSH_RUNTIME_ROOT

  $dshCommand = Get-Command dsh -ErrorAction SilentlyContinue
  if ($dshCommand -and $dshCommand.Source) {
    $commandDirectory = Split-Path -Parent $dshCommand.Source
    Add-RuntimeCandidate $candidates (Join-Path $commandDirectory 'node_modules\@deepseek-ai\dsh')
  }

  $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
  if ($npmCommand) {
    $npmRoot = (& npm root --global 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $npmRoot) {
      Add-RuntimeCandidate $candidates (Join-Path $npmRoot.Trim() '@deepseek-ai\dsh')
    }
  }

  if ($env:APPDATA) {
    Add-RuntimeCandidate $candidates (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh')
  }
  if ($env:LOCALAPPDATA) {
    Add-RuntimeCandidate $candidates (Join-Path $env:LOCALAPPDATA 'npm\node_modules\@deepseek-ai\dsh')
  }

  foreach ($candidate in $candidates) {
    if (Test-Path (Join-Path $candidate 'package.json') -PathType Leaf) {
      return [IO.Path]::GetFullPath($candidate)
    }
  }
  return $null
}

function Reset-BuiltInSkinOverlay {
  param([string]$HomeDirectory)

  $stateFile = Join-Path $HomeDirectory 'skin-center-active.json'
  if (-not (Test-Path $stateFile -PathType Leaf)) {
    return [ordered]@{ changed = $false; reason = 'state-file-not-found'; backup = $null }
  }

  $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $state.active) {
    return [ordered]@{ changed = $false; reason = 'already-default'; backup = $null }
  }

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$stateFile.dsh-local-$timestamp.bak"
  Copy-Item $stateFile $backup -ErrorAction Stop
  $state.active = $null
  if ($null -eq $state.PSObject.Properties['initialized']) {
    $state | Add-Member -NotePropertyName initialized -NotePropertyValue $true
  } else {
    $state.initialized = $true
  }
  $json = $state | ConvertTo-Json -Depth 32
  [IO.File]::WriteAllText($stateFile, "$json`n", [Text.UTF8Encoding]::new($false))
  return [ordered]@{ changed = $true; reason = 'restored-default'; backup = $backup }
}

$resolvedHome = Resolve-DshHome
$profileDirectory = Join-Path (Join-Path $resolvedHome 'profiles') $Profile
$profileManifest = Join-Path $profileDirectory 'package.json'
$helper = Join-Path $PSScriptRoot 'patch-market-compat.mjs'
$nodeCommand = Get-Command node -ErrorAction Stop
$resolvedRuntime = Resolve-DshRuntimeRoot

if (-not (Test-Path $profileManifest -PathType Leaf)) {
  throw "DSH profile was not found: $profileManifest"
}
if (-not (Test-Path $helper -PathType Leaf)) {
  throw "Compatibility helper was not found: $helper"
}

$profileJson = Get-Content $profileManifest -Raw -Encoding UTF8
$frozenReferencePresent = $profileJson -match '"@linxin666/dsh-web-ui-all"'
if ($frozenReferencePresent) {
  Write-Warning '@linxin666/dsh-web-ui-all@0.3.6 is a frozen read-only reference. This repair will not update, enable, or modify it.'
}

$arguments = @($helper, $profileDirectory)
if ($resolvedRuntime) {
  $arguments += $resolvedRuntime
} else {
  Write-Warning 'The @deepseek-ai/dsh runtime root was not found. Market fixes will still run; Mineradio migration will be skipped.'
}

$previousErrorAction = $ErrorActionPreference
try {
  # Windows PowerShell 5.1 can turn a successful native program's stderr into
  # NativeCommandError when ErrorActionPreference is Stop. The helper writes
  # status messages to stderr by design, so merge the streams and judge only
  # the native exit code.
  $ErrorActionPreference = 'Continue'
  $helperOutput = & $nodeCommand.Source @arguments 2>&1
  $helperExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorAction
}
foreach ($line in $helperOutput) {
  Write-Host $line
}
if ($helperExitCode -ne 0) {
  throw "Theme compatibility helper exited with code $helperExitCode"
}

$skinResult = [ordered]@{ changed = $false; reason = 'not-requested'; backup = $null }
if ($ResetBuiltInSkin) {
  $skinResult = Reset-BuiltInSkinOverlay -HomeDirectory $resolvedHome
}

[ordered]@{
  ok = $true
  dshHome = $resolvedHome
  profile = $profileDirectory
  runtime = $resolvedRuntime
  frozenReferenceUntouched = $frozenReferencePresent
  builtInSkin = $skinResult
} | ConvertTo-Json -Depth 8
