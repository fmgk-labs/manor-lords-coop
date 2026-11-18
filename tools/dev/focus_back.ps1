# A game copy that starts takes the keyboard focus from whatever the user is doing (2026-11-17: a test copy took it
# from the owner's own running game). start.ps1 runs this watcher hidden for a short while after each start: whenever
# the window in front belongs to the new copy, the window that was in front before the start is put back.
# Nothing is typed and the mouse is not moved; only the window order changes. It never acts when the user has put
# some other window in front himself.
#   focus_back.ps1 -NewPid <pid of the new copy> -Prev <handle of the window that was in front> [-Seconds 90]
param([int]$NewPid, [long]$Prev, [int]$Seconds = 90)
if (-not $NewPid -or -not $Prev) { exit 0 }
Add-Type @'
using System; using System.Runtime.InteropServices;
public class MLFocus {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
'@
$prevH = [IntPtr]$Prev
$end = (Get-Date).AddSeconds($Seconds); $n = 0
while ((Get-Date) -lt $end) {
  if (-not [MLFocus]::IsWindow($prevH)) { break }
  $h = [MLFocus]::GetForegroundWindow(); $p = 0
  $t = [MLFocus]::GetWindowThreadProcessId($h, [ref]$p)
  if ($p -eq $NewPid) {
    $me = [MLFocus]::GetCurrentThreadId()
    [void][MLFocus]::AttachThreadInput($me, $t, $true)
    if ([MLFocus]::IsIconic($prevH)) { [void][MLFocus]::ShowWindow($prevH, 9) }      # 9 = restore a minimised window
    [void][MLFocus]::SetForegroundWindow($prevH)
    [void][MLFocus]::AttachThreadInput($me, $t, $false)
    $n++
  }
  Start-Sleep -Milliseconds 100
}
exit 0
