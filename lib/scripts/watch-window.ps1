<#
  Pre-warmed window watcher.

  The plugin starts this script BEFORE the program, because PowerShell needs a
  few hundred milliseconds to boot. By the time the program creates its window
  this script is already parked in a tight loop, so it hides the window before
  Windows ever paints it on the primary display, moves it to the target
  rectangle, and only then shows it again. That removes the visible flash.

  Handshake:
    1. after Add-Type finishes it writes <OutFile>.ready
    2. the host spawns the program and writes the process ids into PidFile
    3. this script applies the rectangle, then writes the JSON result to OutFile

  Placement rules (learned from real apps):
    * A hidden window is moved first, then shown, and only then maximized: a
      maximized hidden window is clamped against the monitor it currently
      belongs to, which is how a window ends up half outside the target screen.
    * Some programs (Godot 4 editors among them) re-apply their own saved
      geometry right after creation, so the rectangle is re-asserted for a few
      seconds instead of once.
    * The final rectangle is verified against the target display. When the app
      keeps fighting, the watcher falls back to a plain work-area sized window
      instead of a maximized one, because that placement is the one every app
      accepts.
#>
param(
  [Parameter(Mandatory = $true)][string]$PidFile,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [Parameter(Mandatory = $true)][int]$X,
  [Parameter(Mandatory = $true)][int]$Y,
  [Parameter(Mandatory = $true)][int]$W,
  [Parameter(Mandatory = $true)][int]$H,
  [switch]$Maximize,
  [switch]$TopMost,
  [switch]$Foreground,
  [string]$TitleContains = '',
  [int]$TimeoutMs = 20000,
  [int]$SettleMs = 6000,
  [switch]$IncludeChildren
)

$ErrorActionPreference = 'Stop'
$startedAt = Get-Date

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WatchWin {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLengthW(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  public const uint SWP_NOACTIVATE = 0x0010;
  public const uint SWP_SHOWWINDOW = 0x0040;
  public const uint SWP_NOZORDER = 0x0004;
  public const uint SWP_FRAMECHANGED = 0x0020;
  public const int SW_HIDE = 0;
  public const int SW_SHOWNOACTIVATE = 4;
  public const int SW_SHOW = 5;
  public const int SW_RESTORE = 9;
  public const int SW_MAXIMIZE = 3;
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

  public static List<IntPtr> All(uint[] pids) {
    bool any = pids.Length == 0;
    var wanted = new HashSet<uint>(pids);
    var found = new List<IntPtr>();
    EnumWindows((hWnd, lParam) => {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (!any && !wanted.Contains(pid)) return true;
      // Skip windows owned by this watcher (powershell console or hidden host).
      if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) return true;
      found.Add(hWnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string TitleOf(IntPtr hWnd) {
    var sb = new StringBuilder(512);
    GetWindowTextW(hWnd, sb, sb.Capacity);
    return sb.ToString();
  }

  public static void Rect(IntPtr hWnd, out int x, out int y, out int w, out int h) {
    RECT r; GetWindowRect(hWnd, out r);
    x = r.Left; y = r.Top; w = r.Right - r.Left; h = r.Bottom - r.Top;
  }

  public static void BringToFront(IntPtr hWnd) {
    // SetForegroundWindow is refused for background processes unless the caller
    // shares an input queue with the current foreground window.
    uint targetPid;
    uint targetThread = GetWindowThreadProcessId(hWnd, out targetPid);
    IntPtr fg = GetForegroundWindow();
    uint fgPid;
    uint fgThread = fg != IntPtr.Zero ? GetWindowThreadProcessId(fg, out fgPid) : 0;
    uint self = GetCurrentThreadId();
    bool attachedFg = false, attachedTarget = false;
    try {
      if (fgThread != 0 && fgThread != self) attachedFg = AttachThreadInput(self, fgThread, true);
      if (targetThread != 0 && targetThread != self) attachedTarget = AttachThreadInput(self, targetThread, true);
      SetForegroundWindow(hWnd);
    } finally {
      if (attachedFg) AttachThreadInput(self, fgThread, false);
      if (attachedTarget) AttachThreadInput(self, targetThread, false);
    }
  }
}
'@

try { [WatchWin]::SetProcessDpiAwareness(2) | Out-Null } catch { }
try { [WatchWin]::SetProcessDPIAware() | Out-Null } catch { }

# Ready handshake: the host waits for this file, so the program is only started
# once the watcher is already polling.
try { Set-Content -LiteralPath "$OutFile.ready" -Value ([string]$PID) -Encoding ASCII -Force } catch { }

$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$pidList = @()

# Wait for the host to hand over the process ids.
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $PidFile) {
    try {
      $raw = Get-Content -LiteralPath $PidFile -Raw
      if ($raw) {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -and $parsed.pids) {
          $pidList = @()
          foreach ($value in $parsed.pids) { $pidList += [uint32]$value }
          break
        }
      }
    } catch { }
  }
  Start-Sleep -Milliseconds 10
}

if ($IncludeChildren -and $pidList.Count -gt 0) {
  $seen = New-Object System.Collections.Generic.HashSet[int]
  $queue = New-Object System.Collections.Generic.Queue[int]
  foreach ($rootPid in $pidList) { [void]$seen.Add([int]$rootPid); [void]$queue.Enqueue([int]$rootPid) }
  $all = @()
  foreach ($process in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)) {
    $all += ,@([int]$process.ProcessId, [int]$process.ParentProcessId)
  }
  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    foreach ($pair in $all) {
      if ($pair[1] -eq $current -and $seen.Add($pair[0])) { [void]$queue.Enqueue($pair[0]) }
    }
  }
  $pidList = @($seen)
}

$target = [IntPtr]::Zero
$title = ''
$ownerPid = 0
$hiddenAt = 0
$firstX = 0; $firstY = 0; $firstW = 0; $firstH = 0; $firstVisible = $false

# Tight loop: the first moment a window exists we hide it, so it never paints on
# the wrong display.
while ((Get-Date) -lt $deadline) {
  foreach ($handle in [WatchWin]::All([uint32[]]$pidList)) {
    $candidate = [WatchWin]::TitleOf($handle)
    if ($TitleContains -ne '' -and -not $candidate.Contains($TitleContains)) { continue }
    $cx = 0; $cy = 0; $cw = 0; $ch = 0
    [WatchWin]::Rect($handle, [ref]$cx, [ref]$cy, [ref]$cw, [ref]$ch)
    # Ignore tiny helper windows (tooltips, IME bars, hidden message windows).
    if ($cw -lt 120 -or $ch -lt 80) { continue }
    $target = $handle
    $title = $candidate
    $owner = [uint32]0
    [WatchWin]::GetWindowThreadProcessId($handle, [ref]$owner) | Out-Null
    $ownerPid = [int]$owner
    # Record where the window was born: if it is already on the target display,
    # nothing was ever painted over the primary screen.
    $firstX = $cx; $firstY = $cy; $firstW = $cw; $firstH = $ch
    $firstVisible = [WatchWin]::IsWindowVisible($target)
    [WatchWin]::ShowWindow($target, [WatchWin]::SW_HIDE) | Out-Null
    $hiddenAt = (Get-Date)
    break
  }
  if ($target -ne [IntPtr]::Zero) { break }
  # 8 ms: fast enough to catch a window created in the same frame, cheap enough
  # to run for the whole timeout.
  Start-Sleep -Milliseconds 8
}

if ($target -eq [IntPtr]::Zero) {
  ConvertTo-Json -InputObject ([pscustomobject]@{ ok = $false; reason = 'no-window'; pids = $pidList }) -Compress
  exit 2
}

# Tolerance for "the window is where we asked for it". Engines adjust their own
# frame by a pixel or two (DPI rounding), which is not drift worth correcting.
$tolerance = 2
# A maximized window is deliberately a little larger than its monitor: Windows
# draws the frame just outside the screen edge. Without this allowance every
# correct maximize would look like a misplaced window (632,-1088 on a monitor
# at 640,-1080 is a *successful* maximize, not a failure).
$maximizedOverhang = 16

function Get-WindowRect {
  param([IntPtr]$Handle)
  $rx = 0; $ry = 0; $rw = 0; $rh = 0
  [WatchWin]::Rect($Handle, [ref]$rx, [ref]$ry, [ref]$rw, [ref]$rh)
  return [pscustomobject]@{ x = $rx; y = $ry; w = $rw; h = $rh }
}

function Test-OnMonitor {
  param([object]$Rect, [bool]$Maximized = $false)
  $pad = if ($Maximized) { $maximizedOverhang } else { 0 }
  return ($Rect.x -ge ($X - $pad - $tolerance)) -and
         ($Rect.y -ge ($Y - $pad - $tolerance)) -and
         (($Rect.x + $Rect.w) -le (($X + $W) + $pad + $tolerance)) -and
         (($Rect.y + $Rect.h) -le (($Y + $H) + $pad + $tolerance))
}

function Test-OnTarget {
  param([object]$Rect)
  return ([Math]::Abs($Rect.x - $X) -le $tolerance) -and
         ([Math]::Abs($Rect.y - $Y) -le $tolerance) -and
         ([Math]::Abs($Rect.w - $W) -le $tolerance) -and
         ([Math]::Abs($Rect.h - $H) -le $tolerance)
}

# Move a hidden window to the requested rectangle. No SHOWWINDOW flag: the
# window stays hidden until the caller decides how it should appear, so nothing
# is ever painted on the wrong display.
function Move-Window {
  param([IntPtr]$Handle)
  [WatchWin]::SetWindowPos($Handle, [IntPtr]::Zero, $X, $Y, $W, $H,
    ([WatchWin]::SWP_NOACTIVATE -bor [WatchWin]::SWP_NOZORDER)) | Out-Null
}

function Show-Placed {
  param([IntPtr]$Handle, [bool]$MaximizeNow)
  if ($MaximizeNow) {
    # Maximize only while the window is visible on the target display: Windows
    # clamps a hidden maximized window against the monitor it still belongs to.
    [WatchWin]::ShowWindow($Handle, [WatchWin]::SW_SHOWNOACTIVATE) | Out-Null
    [WatchWin]::ShowWindow($Handle, [WatchWin]::SW_MAXIMIZE) | Out-Null
  } else {
    [WatchWin]::ShowWindow($Handle, [WatchWin]::SW_SHOWNOACTIVATE) | Out-Null
  }
  if ($TopMost) {
    [WatchWin]::SetWindowPos($Handle, [WatchWin]::HWND_TOPMOST, $X, $Y, $W, $H,
      ([WatchWin]::SWP_NOACTIVATE -bor [WatchWin]::SWP_SHOWWINDOW)) | Out-Null
  }
  if ($Foreground) { [WatchWin]::BringToFront($Handle) | Out-Null }
}

# Phase 1: place while hidden, then show it (maximize only after it is on the
# target display).
Move-Window -Handle $target
Show-Placed -Handle $target -MaximizeNow ([bool]$Maximize)

# Phase 2: settle. Applications such as the Godot 4 editor restore their own
# saved geometry (and even their own maximized state) after the first frames, so
# keep re-asserting the placement for a few seconds instead of trusting one call.
$attempts = 1
$maximizeNow = [bool]$Maximize
$maximizeTries = 0
$settleUntil = (Get-Date).AddMilliseconds([Math]::Max($SettleMs, 500))
while ((Get-Date) -lt $settleUntil) {
  Start-Sleep -Milliseconds 50
  $rect = Get-WindowRect -Handle $target

  if ($maximizeNow) {
    if ([WatchWin]::IsZoomed($target) -and (Test-OnMonitor -Rect $rect -Maximized $true)) { continue }
    # The app dropped the maximized state, or maximized against the monitor it
    # belonged to before we moved it. Re-anchor on the target display first, then
    # maximize again: this is the sequence that actually sticks.
    if ($maximizeTries -ge 6) {
      [WatchWin]::ShowWindow($target, [WatchWin]::SW_RESTORE) | Out-Null
      [WatchWin]::ShowWindow($target, [WatchWin]::SW_HIDE) | Out-Null
      Move-Window -Handle $target
      $maximizeNow = $false
      Show-Placed -Handle $target -MaximizeNow $false
      $attempts++
      continue
    }
    Move-Window -Handle $target
    [WatchWin]::ShowWindow($target, [WatchWin]::SW_MAXIMIZE) | Out-Null
    $attempts++
    $maximizeTries++
    continue
  }

  if (Test-OnTarget -Rect $rect) { continue }
  if (-not [WatchWin]::IsWindowVisible($target)) {
    Move-Window -Handle $target
    Show-Placed -Handle $target -MaximizeNow $false
    $attempts++
    continue
  }
  [WatchWin]::ShowWindow($target, [WatchWin]::SW_HIDE) | Out-Null
  Move-Window -Handle $target
  Show-Placed -Handle $target -MaximizeNow $false
  $attempts++
}

# Phase 3: settle the final state and report it honestly.
# A crashed or self-closing program must not be reported as a placed window.
if (-not [WatchWin]::IsWindow($target)) {
  $gone = [pscustomobject]@{
    ok = $false; reason = 'window-closed'; handle = $target.ToInt64(); pid = $ownerPid
    title = $title; maximize = [bool]$Maximize; attempts = [int]$attempts
    hidAtMs = [int](([DateTime]$hiddenAt - $startedAt).TotalMilliseconds)
    firstX = $firstX; firstY = $firstY; firstWidth = $firstW; firstHeight = $firstH; firstVisible = $firstVisible
  }
  $goneJson = ConvertTo-Json -InputObject $gone -Compress
  try {
    $goneUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $goneJson, $goneUtf8)
  } catch { }
  $goneJson
  exit 3
}
if ($maximizeNow -and -not [WatchWin]::IsZoomed($target)) {
  Move-Window -Handle $target
  [WatchWin]::ShowWindow($target, [WatchWin]::SW_MAXIMIZE) | Out-Null
  Start-Sleep -Milliseconds 400
  $attempts++
}
$final = Get-WindowRect -Handle $target
$zoomed = [bool][WatchWin]::IsZoomed($target)
$inside = Test-OnMonitor -Rect $final -Maximized ($maximizeNow -and $zoomed)
if (-not $inside) {
  # Last resort: a plain work-area sized window, the placement every app accepts.
  [WatchWin]::ShowWindow($target, [WatchWin]::SW_RESTORE) | Out-Null
  [WatchWin]::ShowWindow($target, [WatchWin]::SW_HIDE) | Out-Null
  Move-Window -Handle $target
  $maximizeNow = $false
  Show-Placed -Handle $target -MaximizeNow $false
  Start-Sleep -Milliseconds 250
  $final = Get-WindowRect -Handle $target
  $zoomed = [bool][WatchWin]::IsZoomed($target)
  $inside = Test-OnMonitor -Rect $final -Maximized $false
  $attempts++
}

# The title is usually empty at the moment a window is first mapped; re-read it
# now that the settle loop has given the app time to set it.
$settledTitle = [WatchWin]::TitleOf($target)
if ($settledTitle) { $title = $settledTitle }
$payload = [pscustomobject]@{
  ok            = $inside
  reason        = if ($inside) { $null } else { 'outside-target-display' }
  handle        = $target.ToInt64()
  pid           = $ownerPid
  title         = $title
  x             = $final.x
  y             = $final.y
  width         = $final.w
  height        = $final.h
  maximize      = [bool]$Maximize
  maximized     = [bool]$maximizeNow
  maximizeFellBack = ([bool]$Maximize -and -not [bool]$maximizeNow)
  zoomed        = [bool]$zoomed
  inside        = [bool]$inside
  attempts      = [int]$attempts
  targetX       = $X
  targetY       = $Y
  targetWidth   = $W
  targetHeight  = $H
  hidAtMs       = [int](([DateTime]$hiddenAt - $startedAt).TotalMilliseconds)
  firstX        = $firstX
  firstY        = $firstY
  firstWidth    = $firstW
  firstHeight   = $firstH
  firstVisible  = $firstVisible
}
$json = ConvertTo-Json -InputObject $payload -Compress
try {
  # No BOM: the host parses this file with JSON.parse, which rejects \uFEFF.
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($OutFile, $json, $utf8)
} catch { }
$json
