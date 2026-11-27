# Builds JARVIS with the API keys from lib/.env (gitignored) compiled in, installs it on the
# connected phone and starts it.   Usage:  .\scripts\build_apk.ps1  [-Release]
#
# lib/.env format (one per line):  NAME=value
#   GEMINI_API_KEY, SARVAM_API_KEY, PICOVOICE_ACCESS_KEY (optional), GEMINI_MODEL (optional)
# Only the first word of each value is used, so trailing notes on a line are ignored.
param([switch]$Release)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$envFile = Join-Path $root "lib\.env"
if (-not (Test-Path $envFile)) { throw "lib/.env not found" }
$defines = [ordered]@{}
foreach ($line in Get-Content $envFile) {
    $t = $line.Trim()
    if ($t -eq "" -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
    $name = $t.Substring(0, $t.IndexOf("=")).Trim()
    $value = $t.Substring($t.IndexOf("=") + 1).Trim().Trim('"').Trim("'")
    $value = ($value -split '\s+')[0]
    if ($value) { $defines[$name] = $value }
}
New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null
$definesFile = Join-Path $root "build\jarvis_defines.json"   # build/ is gitignored
[IO.File]::WriteAllText($definesFile, ($defines | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))  # no BOM
Write-Host "Keys compiled in: $($defines.Keys -join ', ')"

$mode = if ($Release) { "--release" } else { "--debug" }
flutter build apk $mode "--dart-define-from-file=$definesFile"
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
$apk = if ($Release) { "build\app\outputs\flutter-apk\app-release.apk" } else { "build\app\outputs\flutter-apk\app-debug.apk" }
$adb = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
& $adb install -r $apk
& $adb shell am force-stop com.jarvis.jarvis
& $adb shell am start -n com.jarvis.jarvis/.MainActivity
Remove-Item $definesFile   # don't leave keys lying around
