# Lane 81: where the owner's real mouse pointer is, read only (never moved), and whether it is inside one of the given
# processes' main windows.   powershell -File pointer.ps1 -Pids 123,456
param([string]$Pids = "")
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class L81Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
"@
$p = [System.Windows.Forms.Cursor]::Position
$out = "pointer $($p.X),$($p.Y)"; $inside = @()
foreach ($id in ($Pids -split "[, ]+" | Where-Object { $_ -match "^[0-9]+$" } | ForEach-Object { [int]$_ })) {
  $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
  if (-not $pr -or $pr.MainWindowHandle -eq [IntPtr]::Zero) { $out += " | $id no window"; continue }
  $r = New-Object L81Win+RECT
  [L81Win]::GetWindowRect($pr.MainWindowHandle, [ref]$r) | Out-Null
  $out += " | $id $($r.Left),$($r.Top)-$($r.Right),$($r.Bottom)"
  if ($p.X -ge $r.Left -and $p.X -lt $r.Right -and $p.Y -ge $r.Top -and $p.Y -lt $r.Bottom) { $inside += $id }
}
if ($inside.Count -gt 0) { $out += " | INSIDE " + ($inside -join ",") } else { $out += " | outside" }
$out
