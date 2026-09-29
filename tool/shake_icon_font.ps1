<#
.SYNOPSIS
  Replace the full Material icon font in a Windows release bundle with the
  tree-shaken one.

.DESCRIPTION
  `flutter build windows` never shakes the icon font. Its CMake step runs
  packages/flutter_tools/bin/tool_backend.dart, which passes
  -dTreeShakeIcons="true" WITH the quotes, and it starts `flutter assemble`
  without a shell, so nobody strips them: assemble compares "true" to true and
  skips the shaker. The bundle then carries all 1.6 MB of MaterialIcons, while
  the app uses about 26 KB of it. Android is not affected - its Gradle path
  passes the flag without quotes.

  This reruns the same assemble step with the flag spelled right, taking every
  other define from the config CMake just used, and copies the resulting font
  into the bundle. The shaker picks the icons from the Windows kernel itself;
  a font shaken for another platform would miss the desktop-only icons.

.PARAMETER BundleDir
  The release bundle, build\windows\x64\runner\Release.

.EXAMPLE
  powershell -File tool\shake_icon_font.ps1 -BundleDir build\windows\x64\runner\Release
#>
param([Parameter(Mandatory = $true)][string]$BundleDir)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$font = 'data\flutter_assets\fonts\MaterialIcons-Regular.otf'
$dest = Join-Path $BundleDir $font
if (-not (Test-Path -LiteralPath $dest)) { throw "No icon font in the bundle: $dest" }

# The defines CMake passed, so the rerun builds exactly the same bundle.
$configPath = Join-Path $repoRoot 'windows\flutter\ephemeral\generated_config.cmake'
$config = Get-Content -LiteralPath $configPath -Raw
function Get-ToolEnv([string]$name) {
  if ($config -notmatch ('"' + $name + '=([^"]*)"')) {
    throw "$name not found in $configPath - run flutter build windows first"
  }
  # CMake doubles backslashes in quoted strings (lib\\main.dart).
  return $Matches[1].Replace('\\', '\')
}

Push-Location $repoRoot
try {
  & flutter assemble --no-version-check --output=build `
    -dTargetPlatform=windows-x64 `
    "-dTrackWidgetCreation=$(Get-ToolEnv 'TRACK_WIDGET_CREATION')" `
    -dBuildMode=release `
    "-dTargetFile=$(Get-ToolEnv 'FLUTTER_TARGET')" `
    -dTreeShakeIcons=true `
    "-dDartObfuscation=$(Get-ToolEnv 'DART_OBFUSCATION')" `
    "--DartDefines=$(Get-ToolEnv 'DART_DEFINES')" `
    release_bundle_windows-x64_assets
  if ($LASTEXITCODE -ne 0) { throw 'flutter assemble failed' }
}
finally { Pop-Location }

$shaken = Join-Path $repoRoot 'build\flutter_assets\fonts\MaterialIcons-Regular.otf'
$before = (Get-Item -LiteralPath $dest).Length
$after = (Get-Item -LiteralPath $shaken).Length
# A font no smaller than the bundled one means the shaker did not run again.
if ($after -ge $before) { throw "Icon font was not shaken ($after bytes, bundle has $before)" }
Copy-Item -LiteralPath $shaken -Destination $dest -Force
Write-Host ("    icon font {0:N0} -> {1:N0} bytes" -f $before, $after)
