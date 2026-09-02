$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path ([IO.Path]::GetTempPath()) ("dsh-local-windows-smoke-" + [Guid]::NewGuid().ToString('N'))
$dshHome = Join-Path $root '.dsh'
$profile = Join-Path $dshHome 'profiles\web'
$runtime = Join-Path $root 'AppData\Roaming\npm\node_modules\@deepseek-ai\dsh'
$store = Join-Path (Split-Path -Parent $runtime) 'dsh-client-store'
$market = Join-Path $profile 'node_modules\dshmarket'
$mineradio = Join-Path $profile 'node_modules\dsh-theme-mineradio'
$utf8 = [Text.UTF8Encoding]::new($false)

function Write-Fixture {
  param([string]$Path, [string]$Contents)
  $directory = Split-Path -Parent $Path
  [void](New-Item -ItemType Directory -Path $directory -Force)
  [IO.File]::WriteAllText($Path, $Contents, $utf8)
}

try {
  Write-Fixture (Join-Path $profile 'package.json') '{"dependencies":{"dshmarket":"1.39.0","dsh-theme-mineradio":"2.3.5","@linxin666/dsh-web-ui-all":"0.3.6"}}'
  Write-Fixture (Join-Path $runtime 'package.json') '{"name":"@deepseek-ai/dsh","version":"0.1.2-alpha.4"}'
  Write-Fixture (Join-Path $store 'package.json') '{"name":"@deepseek-ai/dsh-client-store"}'
  Write-Fixture (Join-Path $market 'package.json') '{"name":"dshmarket","version":"1.39.0"}'
  Write-Fixture (Join-Path $market 'lib\themes.js') 'const themeNames = new Set(themeEntries.map(p => p.name));'
  Write-Fixture (Join-Path $market 'lib\routes.js') "                    pendingRollbacks.clear();`n                    const activated = await themes.activateTheme(name);"
  Write-Fixture (Join-Path $mineradio 'package.json') "{`n  `"name`": `"dsh-theme-mineradio`",`n  `"version`": `"2.3.5`",`n  `"dsh`": {`n    `"inject`": [`n        `"@deepseek-ai/dsh-client-runtime`",`n        `"@deepseek-ai/dsh-client-locale`",`n        `"@deepseek-ai/dsh-client-ui`"`n    ]`n  }`n}"
  Write-Fixture (Join-Path $mineradio 'lib\client.js') 'require("@deepseek-ai/dsh-client-runtime/client")'
  Write-Fixture (Join-Path $dshHome 'skin-center-active.json') '{"active":{"id":"blue-fantasy"},"initialized":true}'

  $profileBefore = Get-Content (Join-Path $profile 'package.json') -Raw
  & (Join-Path $PSScriptRoot '..\scripts\repair-windows.ps1') -DshHome $dshHome -RuntimeRoot $runtime -ResetBuiltInSkin | Out-Host

  $marketThemes = Get-Content (Join-Path $market 'lib\themes.js') -Raw
  $marketRoutes = Get-Content (Join-Path $market 'lib\routes.js') -Raw
  $themeClient = Get-Content (Join-Path $mineradio 'lib\client.js') -Raw
  $themeManifest = Get-Content (Join-Path $mineradio 'package.json') -Raw
  $profileAfter = Get-Content (Join-Path $profile 'package.json') -Raw
  $skinState = Get-Content (Join-Path $dshHome 'skin-center-active.json') -Raw | ConvertFrom-Json
  $skinBackups = @(Get-ChildItem $dshHome -Filter 'skin-center-active.json.dsh-local-*.bak')

  if ($marketThemes -notmatch 'p\.npm') { throw 'npm identity patch was not applied' }
  if ($marketRoutes -notmatch 'enableRow') { throw 'theme row enable patch was not applied' }
  if ($themeClient -notmatch 'dsh-client-store') { throw 'Mineradio client migration was not applied' }
  if ($themeManifest -notmatch 'dsh-client-store') { throw 'Mineradio manifest migration was not applied' }
  if ($profileAfter -ne $profileBefore) { throw 'the frozen reference manifest was modified' }
  if ($null -ne $skinState.active) { throw 'the built-in skin overlay was not cleared' }
  if ($skinBackups.Count -ne 1) { throw 'the built-in skin state backup was not created' }

  Write-Host 'Windows repair smoke test passed.'
} finally {
  if (Test-Path $root) {
    Remove-Item $root -Recurse -Force
  }
}
