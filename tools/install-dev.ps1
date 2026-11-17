# install-dev.ps1 : copy the mod from this repository into the game's mod-loader folder (development install).
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-dev.ps1 [-Role host|friend|off] [-Name friend1] [-LinkDir <folder>] [-Remove] [-Game <Manor Lords folder>]
# It writes only inside <game>\ManorLords\Binaries\Win64\ue4ss\Mods\ManorLordsCoop. The game must be restarted to pick it up.
# -Game: without it, this PC's lead test copy, <ML_TEST_ROOT>\_ml_test (the environment or tools\dev\local.env).
#   There is no default for a real install: name one with -Game only on purpose.
param([string]$Role = 'off', [string]$Name = 'friend1', [string]$LinkDir = '', [switch]$Remove,
      [string]$Game = '')
if (-not $Game) {
    . (Join-Path $PSScriptRoot 'dev\local_env.ps1')
    $Game = Get-MLTestCopy
    if (-not $Game) { "no -Game and no ML_TEST_ROOT: pass -Game <Manor Lords folder>, or $MLSetupHint"; exit 1 }
}

$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'mod\ManorLordsCoop'
$dst = Join-Path $Game 'ManorLords\Binaries\Win64\ue4ss\Mods\ManorLordsCoop'
if (-not (Test-Path (Join-Path $Game 'ManorLords\Binaries\Win64\ue4ss\Mods'))) { "mod loader folder not found under $Game"; exit 1 }

if ($Remove) {
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force; "removed $dst" } else { "nothing to remove" }
    exit 0
}

New-Item -ItemType Directory -Force (Join-Path $dst 'Scripts'), (Join-Path $dst 'link') | Out-Null
Copy-Item (Join-Path $src 'Scripts\*.lua') (Join-Path $dst 'Scripts') -Force
# the two native files (built from native\coop_patch and native\coop_steam). A copy that is in use by a running game
# cannot be replaced: close the game first.
$repo = Split-Path -Parent $PSScriptRoot
$patch = Join-Path $repo 'native\coop_patch\out\coop_patch.dll'
$steam = Join-Path $repo 'native\coop_steam\out\coop_steam.dll'
if (Test-Path $patch) { Copy-Item $patch (Join-Path $dst 'coop_patch.dll') -Force -ErrorAction SilentlyContinue; if (-not $?) { "  coop_patch.dll is in use: close the game and run this again" } } else { "  coop_patch.dll not built: the combat switch stays off" }
if (Test-Path $steam) { Copy-Item $steam (Join-Path $dst 'Scripts\coop_steam.dll') -Force -ErrorAction SilentlyContinue; if (-not $?) { "  coop_steam.dll is in use: close the game and run this again" } } else { "  coop_steam.dll not built: Steam joining stays off" }
# the mod loader loads a mod folder that contains enabled.txt
Set-Content (Join-Path $dst 'enabled.txt') '' -Encoding ASCII
$cfg = @(
    '# Manor Lords Co-op settings (written by install-dev.ps1)',
    "role = $Role",
    "name = $Name",
    "linkdir = $LinkDir"
)
Set-Content (Join-Path $dst 'coop.cfg') $cfg -Encoding ASCII
"installed to $dst"
"  role = $Role, name = $Name, linkdir = $(if ($LinkDir) { $LinkDir } else { '(the mod''s own link folder)' })"
"  files: " + ((Get-ChildItem (Join-Path $dst 'Scripts') -Filter *.lua | ForEach-Object { $_.Name }) -join ', ')
