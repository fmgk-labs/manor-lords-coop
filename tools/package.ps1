# package.ps1 : build the zip that players unzip into the game's Win64 folder.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\package.ps1 [-Game <Manor Lords folder>]
# Output: dist\ManorLordsCoop-<version>.zip and dist\INSTALL.txt (the same text is inside the zip).
# The zip holds the mod loader (UE4SS, MIT licence, copied from this PC's game folder) and the mod.
# -Variant nexus (for the Nexus Mods page) builds dist\ManorLordsCoop-<version>-nexus.zip WITH the loader build it was
#   tested on (the same loader files as the default zip: dwmapi.dll, ue4ss\UE4SS.dll, UE4SS-settings.ini, LICENSE,
#   Mods\shared\...) and the mod, but WITHOUT ue4ss\Mods\mods.txt and mods.json (a player's own list of mods is not touched;
#   the mod switches itself on with enabled.txt in its own folder). Plus the install note docs\INSTALL-nexus.txt
#   (also copied to dist\INSTALL-nexus.txt). It reads the loader from the game folder, like the default.
# The default (-Variant full) is unchanged. coop_dev.lua is left out of the nexus variant whatever -Dist is.
# -Game: where the loader files are copied from. Without it: this PC's lead test copy, <ML_TEST_ROOT>\_ml_test, from the
#   environment or tools\dev\local.env (tools never read the real install by default).
param([string]$Game = '', [string]$Dist = 'dist', [ValidateSet('full', 'nexus')][string]$Variant = 'full')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'dev\local_env.ps1')
if (-not $Game) { $Game = Get-MLTestCopy }
if (-not $Game) { throw "no game folder: pass -Game <Manor Lords folder with the loader>, or set ML_TEST_ROOT ($MLSetupHint)" }
$win  = Join-Path $Game 'ManorLords\Binaries\Win64'
$mod  = Join-Path $repo 'mod\ManorLordsCoop'
$ver  = (Select-String -Path (Join-Path $mod 'Scripts\coop.lua') -Pattern 'C\.version = "([^"]+)"').Matches[0].Groups[1].Value
# $Dist and $dist are the same variable (PowerShell names ignore case): decide the players' zip before the path replaces it
$playersZip = ($Dist -eq 'dist')
$dist = Join-Path $repo $Dist      # test builds go to dist	est so the zip to send is never overwritten
New-Item -ItemType Directory -Force $dist | Out-Null
$stage = Join-Path $dist 'stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$m = Join-Path $stage 'ue4ss\Mods\ManorLordsCoop'
New-Item -ItemType Directory -Force (Join-Path $m 'Scripts') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $stage 'ue4ss\Mods\shared') | Out-Null

# mod loader (both variants): from the installed folder, or from the development copy kept beside it (ue4ss_dev) when the installed
# one is missing (2026-11-11: a failed reinstall had removed it, and the zip could not be built)
$loader = Join-Path $win 'ue4ss'
if (-not (Test-Path (Join-Path $loader 'UE4SS.dll'))) { $loader = Join-Path $win 'ue4ss_dev' }
if (-not (Test-Path (Join-Path $loader 'UE4SS.dll'))) { throw 'UE4SS.dll not found in ue4ss or ue4ss_dev under the game folder' }
Copy-Item (Join-Path $win 'dwmapi.dll') $stage
foreach ($f in 'UE4SS.dll', 'UE4SS-settings.ini', 'LICENSE') { Copy-Item (Join-Path $loader $f) (Join-Path $stage 'ue4ss') }
Copy-Item (Join-Path $loader 'Mods\shared\*') (Join-Path $stage 'ue4ss\Mods\shared') -Recurse
if ($Variant -eq 'full') {   # the nexus variant leaves the player's mods.txt and mods.json alone
Set-Content (Join-Path $stage 'ue4ss\Mods\mods.txt') '; Manor Lords Co-op is switched on by the enabled.txt file in its own folder' -Encoding ASCII
Set-Content (Join-Path $stage 'ue4ss\Mods\mods.json') '[]' -Encoding ASCII
}

# the mod
Copy-Item (Join-Path $mod 'Scripts\*.lua') (Join-Path $m 'Scripts')
# the development channel (runs a Lua file from the link folder in test copies) never goes to players
if ($playersZip -or $Variant -eq 'nexus') { Remove-Item (Join-Path $m 'Scripts\coop_dev.lua') -ErrorAction SilentlyContinue }
if (($playersZip -or $Variant -eq 'nexus') -and (Test-Path (Join-Path $m 'Scripts\coop_dev.lua'))) { throw 'coop_dev.lua is still in a zip for players' }
$patch = Join-Path $repo 'native\coop_patch\out\coop_patch.dll'
$steam = Join-Path $repo 'native\coop_steam\out\coop_steam.dll'
if (-not (Test-Path $patch)) { throw 'native\coop_patch\out\coop_patch.dll is not built' }
if (-not (Test-Path $steam)) { throw 'native\coop_steam\out\coop_steam.dll is not built' }
Copy-Item $patch $m
Copy-Item $steam (Join-Path $m 'Scripts')
Copy-Item (Join-Path $mod 'coop.cfg') $m
Set-Content (Join-Path $m 'enabled.txt') '' -Encoding ASCII
# the link folder is there from the first start (the mod's log and the Steam piece's files live in it)
New-Item -ItemType Directory -Force (Join-Path $m 'link') | Out-Null
Set-Content (Join-Path $m 'link\readme.txt') 'Manor Lords Co-op keeps its log files here. Safe to delete while the game is closed.' -Encoding ASCII
if ($Variant -eq 'full') {
Copy-Item (Join-Path $repo 'docs\INSTALL.txt') (Join-Path $stage 'ManorLordsCoop-INSTALL.txt')
Copy-Item (Join-Path $repo 'docs\INSTALL.txt') (Join-Path $dist 'INSTALL.txt')
$zip = Join-Path $dist "ManorLordsCoop-$ver.zip"
} else {
$note = Join-Path $repo 'docs\INSTALL-nexus.txt'
if (-not (Test-Path $note)) { throw 'docs\INSTALL-nexus.txt is missing' }
Copy-Item $note (Join-Path $stage 'ManorLordsCoop-INSTALL.txt')
Copy-Item $note (Join-Path $dist 'INSTALL-nexus.txt')
$zip = Join-Path $dist "ManorLordsCoop-$ver-nexus.zip"
}

if (Test-Path $zip) { Remove-Item $zip -Force }
if ($Variant -eq 'full') {
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
} else {
# the nexus zip is written entry by entry so that every name uses "/" (what Nexus's file viewer and other tools expect)
# and there are no entries for empty folders (a folder with a file in it is created by that file)
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$za = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  $root = (Resolve-Path $stage).Path.TrimEnd('\') + '\'
  Get-ChildItem $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    $name = $_.FullName.Substring($root.Length).Replace('\', '/')
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $_.FullName, $name, 'Optimal')
  }
} finally { $za.Dispose() }
}
Remove-Item $stage -Recurse -Force
"built $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB), version $ver"
"hash  " + (Get-FileHash $zip -Algorithm SHA256).Hash
