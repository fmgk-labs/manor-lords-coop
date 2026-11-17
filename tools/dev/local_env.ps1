# local_env.ps1 : this PC's own paths for the PowerShell tools (dot-source it:  . (Join-Path <tools\dev> 'local_env.ps1')).
# Get-MLSetting <name>: the environment variable <name> if set (tools/dev/env.sh exports ML_TEST_ROOT, ML_SLOTS, ML_REPO),
# else the line <name>=<value> of tools\dev\local.env (git-ignored; template local.env.example): $env:ML_LOCAL_ENV,
# else this checkout's, else the main checkout's (a git worktree has no local.env of its own). '' when none has it.
# Get-MLTestCopy: the lead's test copy of the game folder, <ML_TEST_ROOT>\_ml_test, or '' when ML_TEST_ROOT is not set.
$MLDevDir = $PSScriptRoot

function Get-MLLocalEnvFile {
    if ($env:ML_LOCAL_ENV) { return $env:ML_LOCAL_ENV }
    $own = Join-Path $MLDevDir 'local.env'
    if (Test-Path -LiteralPath $own) { return $own }
    $common = ''
    try { $common = (& git -C $MLDevDir rev-parse --path-format=absolute --git-common-dir 2>$null | Select-Object -First 1) } catch { $common = '' }
    if ($common) {
        $main = Join-Path (Split-Path -Parent $common) 'tools\dev\local.env'
        if (Test-Path -LiteralPath $main) { return $main }
    }
    return ''
}

function Get-MLSetting([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if (-not $v) {
        $f = Get-MLLocalEnvFile
        if ($f -and (Test-Path -LiteralPath $f)) {
            foreach ($line in (Get-Content -LiteralPath $f)) {
                if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$' -and $Matches[1] -eq $Name) {
                    $v = $Matches[2].Trim('"').Trim("'")
                }
            }
        }
    }
    if (-not $v) { return '' }
    if ($v -match '^/([A-Za-z])/(.*)$') { $v = $Matches[1].ToUpper() + ':\' + $Matches[2] }   # a Git Bash path
    return $v.Replace('/', '\')
}

function Get-MLTestCopy {
    $root = Get-MLSetting 'ML_TEST_ROOT'
    if (-not $root) { return '' }
    return (Join-Path $root '_ml_test')
}

$MLSetupHint = 'copy tools\dev\local.env.example to tools\dev\local.env and fill in this PC''s paths (tools\dev\README.md, First-time setup)'
