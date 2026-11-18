# Start one copy of the game from a TEST copy of the game folder, in a small muted window, with a forced role.
#   start.ps1 -Exe <test copy exe> -Suffix <save profile suffix> -Role host|friend|idle -Name <link name> -Io <console folder, '' = io>
#             -WinX <left> -WinY <top> -ResX <w> -ResY <h> -PidFile <file> [-Extra "NAME=value NAME2=value"]
# Without -Exe: the lead's test copy, <ML_TEST_ROOT>\_ml_test (the environment or tools\dev\local.env).
param([string]$Exe = '', [string]$Suffix = 'Coop',
      [string]$Role = 'idle', [string]$Name = '', [string]$Io = '', [int]$WinX = 1920, [int]$WinY = 30, [int]$ResX = 960, [int]$ResY = 540,
      [string]$PidFile = '', [string]$Extra = '')
if (-not $Exe) {
    . (Join-Path $PSScriptRoot 'local_env.ps1')
    $t = Get-MLTestCopy
    if (-not $t) { "no -Exe and no ML_TEST_ROOT: $MLSetupHint"; exit 1 }
    $Exe = Join-Path $t 'ManorLords\Binaries\Win64\ManorLords-Win64-Shipping.exe'
}
if ($Exe -like '*SteamLibrary*') { 'REFUSED: this script only starts test copies, never the real install'; exit 1 }
if ($Exe -like '*\steamapps\*' -or $Exe -like '*/steamapps/*') { 'REFUSED: this script only starts test copies, never the real install (a steamapps folder)'; exit 1 }
if ($Suffix -notlike 'Coop*') { 'REFUSED: the save profile suffix must start with Coop (never the real saves)'; exit 1 }
$set = @{}
if ($Role -ne 'idle') { $set['COOP_ROLE'] = $Role }
if ($Name) { $set['COOP_NAME'] = $Name }
if ($Io) { $set['COOP_IO'] = $Io }
$set['COOP_STEAM'] = 'off'
foreach ($pair in ($Extra -split '\s+')) { if ($pair -match '^([A-Z_0-9]+)=(.*)$') { $set[$Matches[1]] = $Matches[2] } }
foreach ($k in 'COOP_ROLE', 'COOP_NAME', 'COOP_IO', 'COOP_STEAM', 'COOP_TEST_REPAIR', 'COOP_LINKDIR') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
foreach ($k in $set.Keys) { Set-Item "Env:$k" $set[$k] }
# the window in front right now (the user's own work, or his own running game): a new copy takes the focus when its
# window opens, so a hidden watcher puts this window back in front for the next 90 s (focus_back.ps1)
$prevFg = 0
try {
    Add-Type -Namespace MLStart -Name Fg -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();' -ErrorAction Stop
    $prevFg = [MLStart.Fg]::GetForegroundWindow().ToInt64()
} catch { $prevFg = 0 }
$p = Start-Process $Exe -ArgumentList '-windowed', "-ResX=$ResX", "-ResY=$ResY", "-WinX=$WinX", "-WinY=$WinY", '-nosound', "-saveddirsuffix=$Suffix" -PassThru
foreach ($k in $set.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
# ML_NO_FOCUS_BACK=1 (set by a run that uses the real mouse or keyboard on its copies, while the user is away): no
# watcher, because it would take the focus away from a copy that was just clicked and the next key would land elsewhere
if ($prevFg -ne 0 -and $p -and $env:ML_NO_FOCUS_BACK -ne '1') {
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'focus_back.ps1')`"", '-NewPid', $p.Id, '-Prev', $prevFg | Out-Null
}
"$Role pid $($p.Id)"
if ($PidFile) { $p.Id | Set-Content $PidFile }
