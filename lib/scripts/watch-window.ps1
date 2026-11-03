<#
  Pre-warmed window watcher.

  The plugin starts this script BEFORE the program, because PowerShell needs a
  few hundred milliseconds to boot. By the time the program creates its window
  this script is already parked in a tight loop, so it hides the window before
  Windows ever paints it on the primary display, moves it to the target
  rectangle, and only then shows it again. That removes the visible flash.

  Handshake:
    1. after Add-Type finishes the baseline window set is captured, then
       <OutFile>.ready is written
    2. the host spawns the program and writes the process ids into PidFile
    3. this script applies the rectangle, then writes the JSON result to OutFile

  Which window it picks (the part that used to be wrong):
    * the process id list is the *root* of a tree, and the tree is re-read while
      polling: a launcher script (cmd, a .bat, npm) starts the real program a
      few seconds later, so a one-shot snapshot never contains it;
    * windows that did not exist before the launch count too, because launchers
      such as `start steam://…` hand the program to explorer, which is not a
      descendant of the launcher at all;
    * console windows (the cmd/conhost box a wrapper is started in) are not the
      test window. They are only used as a last resort, when nothing else
      appeared before the timeout.

  Placement rules (learned from real apps):
    * A hidden window is moved first, then shown, and only then maximized: a
      maximized hidden window is clamped against the monitor it currently
      belongs to, which is how a window ends up half outside the target screen.
    * Some programs (Godot 4 editors among them) re-apply their own saved
      geometry right after creation, or recreate their window entirely, so the
      rectangle is re-asserted for a few seconds and a dead handle is replaced
      by the new window of the same program.
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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
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
  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_TOOLWINDOW = 0x00000080;
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

  /// <summary>Every top-level window of the given processes.</summary>
  public static List<IntPtr> All(uint[] pids) {
    bool any = pids.Length == 0;
    var wanted = new HashSet<uint>(pids);
    uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    var found = new List<IntPtr>();
    EnumWindows((hWnd, lParam) => {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (pid == self) return true;
      if (!any && !wanted.Contains(pid)) return true;
      found.Add(hWnd);
      return true;
    }, IntPtr.Zero);
    return found;
  }

  /// <summary>Every top-level window, ignoring the owning process.</summary>
  public static List<IntPtr> Every() {
    uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    var found = new List<IntPtr>();
    EnumWindows((hWnd, lParam) => {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (pid == self) return true;
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

  public static string ClassOf(IntPtr hWnd) {
    var sb = new StringBuilder(256);
    GetClassNameW(hWnd, sb, sb.Capacity);
    return sb.ToString();
  }

  public static bool IsToolWindow(IntPtr hWnd) {
    return (GetWindowLong(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0;
  }

  public static uint PidOf(IntPtr hWnd) {
    uint pid;
    GetWindowThreadProcessId(hWnd, out pid);
    return pid;
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

# Windows that are never the test window. Console hosts are handled separately
# (they are the shell wrapper, not the app), the rest is desktop chrome.
$chromeClasses = @(
  'ConsoleWindowClass', 'PseudoConsoleWindow', 'CASCADIA_HOSTING_WINDOW_CLASS',
  'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd',
  'NotifyIconOverflowWindow', 'tooltips_class32', 'MSCTFIME UI', 'IME',
  'GDI+ Hook Window Class', 'SysShadow', 'TaskListThumbnailWnd',
  'Windows.UI.Core.CoreWindow', 'ApplicationManager_ImmersiveShellWindow'
)

# GPU drivers create invisible scratch windows while an engine initialises its
# context (Godot 4 on NVIDIA: class NVOpenGLPbuffer, title __wglDummyWindowFo…
# sized like the render surface). They are never what the user calls the test
# window, and picking one used to eat the whole placement.
$helperClasses = @(
  'NVOpenGLPbuffer', 'NVOpenGLWindow', 'GDI+ Window', 'OleMainThreadWndClass',
  'D3D9Window', 'DDrawWindow', 'MediaContextNotificationWindow'
)

# Everything that is already on screen before the program starts. A window that
# is not in here appeared because of this launch, even when the launcher handed
# the program to another process (explorer, a service, an existing instance).
$baseline = New-Object System.Collections.Generic.HashSet[Int64]
foreach ($handle in [WatchWin]::Every()) { [void]$baseline.Add($handle.ToInt64()) }

# Ready handshake: the host waits for this file, so the program is only started
# once the watcher is already polling.
try { Set-Content -LiteralPath "$OutFile.ready" -Value ([string]$PID) -Encoding ASCII -Force } catch { }

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

# ------------------------------------------------------------------ discovery

# Descendant process ids of the launcher. The launcher of a test window is very
# often a script, so this is re-read while polling: the program may be started
# seconds after the script itself, and the parent is usually gone by then.
function Get-ProcessTree {
  param([uint32[]]$Roots)
  $seen = New-Object System.Collections.Generic.HashSet[uint32]
  if ($Roots.Count -eq 0) { return $seen }
  $children = @{}
  foreach ($process in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)) {
    $parent = [uint32]$process.ParentProcessId
    if (-not $children.ContainsKey($parent)) {
      $children[$parent] = New-Object System.Collections.Generic.List[uint32]
    }
    $children[$parent].Add([uint32]$process.ProcessId)
  }
  $queue = New-Object System.Collections.Generic.Queue[uint32]
  foreach ($root in $Roots) {
    if ($seen.Add($root)) { $queue.Enqueue($root) }
  }
  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    if ($children.ContainsKey($current)) {
      foreach ($child in $children[$current]) {
        if ($seen.Add($child)) { $queue.Enqueue($child) }
      }
    }
  }
  return $seen
}

# Best window to place, or $null. `Console` candidates are only used as a last
# resort by the caller, so the wrapper's own console box never wins over the
# program the wrapper just started.
function Get-Candidate {
  param($PidSet, [Int64[]]$Known)
  $best = $null
  $bestScore = -1
  $bestConsole = $null
  $bestConsoleScore = -1
  foreach ($handle in [WatchWin]::Every()) {
    $key = $handle.ToInt64()
    $owner = [WatchWin]::PidOf($handle)
    $isNew = -not $baseline.Contains($key)
    $owned = $PidSet -and $PidSet.Contains([uint32]$owner)
    if (-not $isNew -and -not $owned) { continue }
    if ($Known -and ($Known -contains $key)) { continue }
    if ([WatchWin]::IsToolWindow($handle)) { continue }
    $class = [WatchWin]::ClassOf($handle)
    if ($helperClasses -contains $class) { continue }
    $isConsole = ($class -eq 'ConsoleWindowClass') -or ($class -eq 'PseudoConsoleWindow') -or ($class -eq 'CASCADIA_HOSTING_WINDOW_CLASS')
    if (-not $isConsole -and ($chromeClasses -contains $class)) { continue }
    $rx = 0; $ry = 0; $rw = 0; $rh = 0
    [WatchWin]::Rect($handle, [ref]$rx, [ref]$ry, [ref]$rw, [ref]$rh)
    # Ignore tiny helper windows (tooltips, IME bars, hidden message windows).
    if ($rw -lt 160 -or $rh -lt 120) { continue }
    # Only a window the user can actually see is the test window. Engines and
    # drivers keep invisible windows around (see $helperClasses above) that are
    # easy to mistake for the real thing; the real window is mapped, then shown.
    if (-not [WatchWin]::IsWindowVisible($handle)) { continue }
    $visible = $true
    $title = [WatchWin]::TitleOf($handle)
    if ($title.StartsWith('__wgl')) { continue }
    if ($TitleContains -ne '' -and -not $title.Contains($TitleContains)) { continue }
    $score = [int]([Math]::Min(($rw * $rh) / 1000, 900000))
    if ($title -ne '') { $score += 1000 }
    if ($owned) { $score += 2000 }
    $record = [pscustomobject]@{
      handle = $handle; class = $class; title = $title; pid = [int]$owner
      x = $rx; y = $ry; w = $rw; h = $rh; visible = $visible
      console = $isConsole; newWindow = $isNew
    }
    if ($isConsole) {
      if ($score -gt $bestConsoleScore) { $bestConsoleScore = $score; $bestConsole = $record }
    } elseif ($score -gt $bestScore) {
      $bestScore = $score
      $best = $record
    }
  }
  return [pscustomobject]@{ best = $best; console = $bestConsole }
}

$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$roots = @()
$pidSet = New-Object System.Collections.Generic.HashSet[uint32]
$known = New-Object System.Collections.Generic.List[Int64]

# Wait for the host to hand over the process ids.
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $PidFile) {
    try {
      $raw = Get-Content -LiteralPath $PidFile -Raw
      if ($raw) {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -and $parsed.pids) {
          $roots = @()
          foreach ($value in $parsed.pids) { $roots += [uint32]$value; [void]$pidSet.Add([uint32]$value) }
          break
        }
      }
    } catch { }
  }
  Start-Sleep -Milliseconds 10
}

# The timeout is about waiting for the *window*, so it starts now, not when this
# watcher was booted.
$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$tree = Get-ProcessTree -Roots $roots
foreach ($p in $tree) { [void]$pidSet.Add($p) }
$lastTreeScan = Get-Date

$target = $null
$consoleFallback = $null

while ((Get-Date) -lt $deadline) {
  if (((Get-Date) - $lastTreeScan).TotalMilliseconds -ge 300) {
    $tree = Get-ProcessTree -Roots $roots
    foreach ($p in $tree) { [void]$pidSet.Add($p) }
    $lastTreeScan = Get-Date
  }
  $found = Get-Candidate -PidSet $pidSet -Known $known
  if ($found.best) { $target = $found.best; break }
  if ($found.console) { $consoleFallback = $found.console }
  Start-Sleep -Milliseconds 12
}

# Nothing that looks like an app window: fall back to the console box the
# launcher was started in, which is what a console-only program shows.
if (-not $target) { $target = $consoleFallback }

if (-not $target) {
  $none = [pscustomobject]@{
    ok = $false; reason = 'no-window'; pids = @($pidSet)
    waitedMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
  }
  $noneJson = ConvertTo-Json -InputObject $none -Compress
  try {
    # No BOM: the host parses this file with JSON.parse, which rejects \uFEFF.
    $noneUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $noneJson, $noneUtf8)
  } catch { }
  $noneJson
  exit 2
}

$handle = $target.handle
$title = $target.title
$ownerPid = $target.pid
$firstX = $target.x; $firstY = $target.y; $firstW = $target.w; $firstH = $target.h
$firstVisible = $target.visible
$hiddenAt = Get-Date

if ($firstVisible) {
  [WatchWin]::ShowWindow($handle, [WatchWin]::SW_HIDE) | Out-Null
}

# Phase 1: place while hidden, then show it (maximize only after it is on the
# target display).
Move-Window -Handle $handle
Show-Placed -Handle $handle -MaximizeNow ([bool]$Maximize)

# Phase 2: settle. Applications such as the Godot 4 editor restore their own
# saved geometry (and even their own maximized state) after the first frames, so
# keep re-asserting the placement for a few seconds instead of trusting one call.
$attempts = 1
$replaced = 0
$maximizeNow = [bool]$Maximize
$maximizeTries = 0
$settleUntil = (Get-Date).AddMilliseconds([Math]::Max($SettleMs, 500))
while ((Get-Date) -lt $settleUntil) {
  Start-Sleep -Milliseconds 50

  # The program may throw its window away and create a new one (engine splash,
  # renderer switch). Adopt the replacement instead of reporting it as closed.
  if (-not [WatchWin]::IsWindow($handle)) {
    [void]$known.Add($handle.ToInt64())
    $swap = $null
    $swapDeadline = (Get-Date).AddMilliseconds(1500)
    while ((Get-Date) -lt $swapDeadline -and -not $swap) {
      $tree = Get-ProcessTree -Roots $roots
      foreach ($p in $tree) { [void]$pidSet.Add($p) }
      $found = Get-Candidate -PidSet $pidSet -Known $known
      if ($found.best) { $swap = $found.best }
      else { Start-Sleep -Milliseconds 40 }
    }
    if (-not $swap) { break }
    $target = $swap
    $handle = $swap.handle
    $title = $swap.title
    $ownerPid = $swap.pid
    $hiddenAt = Get-Date
    $replaced++
    if ($swap.visible) { [WatchWin]::ShowWindow($handle, [WatchWin]::SW_HIDE) | Out-Null }
    Move-Window -Handle $handle
    Show-Placed -Handle $handle -MaximizeNow $maximizeNow
    $attempts++
    continue
  }

  $rect = Get-WindowRect -Handle $handle

  if ($maximizeNow) {
    if ([WatchWin]::IsZoomed($handle) -and (Test-OnMonitor -Rect $rect -Maximized $true)) { continue }
    # The app dropped the maximized state, or maximized against the monitor it
    # belonged to before we moved it. Re-anchor on the target display first, then
    # maximize again: this is the sequence that actually sticks.
    if ($maximizeTries -ge 6) {
      [WatchWin]::ShowWindow($handle, [WatchWin]::SW_RESTORE) | Out-Null
      [WatchWin]::ShowWindow($handle, [WatchWin]::SW_HIDE) | Out-Null
      Move-Window -Handle $handle
      $maximizeNow = $false
      Show-Placed -Handle $handle -MaximizeNow $false
      $attempts++
      continue
    }
    Move-Window -Handle $handle
    [WatchWin]::ShowWindow($handle, [WatchWin]::SW_MAXIMIZE) | Out-Null
    $attempts++
    $maximizeTries++
    continue
  }

  if (Test-OnTarget -Rect $rect) { continue }
  if (-not [WatchWin]::IsWindowVisible($handle)) {
    Move-Window -Handle $handle
    Show-Placed -Handle $handle -MaximizeNow $false
    $attempts++
    continue
  }
  [WatchWin]::ShowWindow($handle, [WatchWin]::SW_HIDE) | Out-Null
  Move-Window -Handle $handle
  Show-Placed -Handle $handle -MaximizeNow $false
  $attempts++
}

# Phase 3: settle the final state and report it honestly.
# A crashed or self-closing program must not be reported as a placed window.
if (-not [WatchWin]::IsWindow($handle)) {
  $gone = [pscustomobject]@{
    ok = $false; reason = 'window-closed'; handle = $handle.ToInt64(); pid = $ownerPid
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
if ($maximizeNow -and -not [WatchWin]::IsZoomed($handle)) {
  Move-Window -Handle $handle
  [WatchWin]::ShowWindow($handle, [WatchWin]::SW_MAXIMIZE) | Out-Null
  Start-Sleep -Milliseconds 400
  $attempts++
}
$final = Get-WindowRect -Handle $handle
$zoomed = [bool][WatchWin]::IsZoomed($handle)
$inside = Test-OnMonitor -Rect $final -Maximized ($maximizeNow -and $zoomed)
if (-not $inside) {
  # Last resort: a plain work-area sized window, the placement every app accepts.
  [WatchWin]::ShowWindow($handle, [WatchWin]::SW_RESTORE) | Out-Null
  [WatchWin]::ShowWindow($handle, [WatchWin]::SW_HIDE) | Out-Null
  Move-Window -Handle $handle
  $maximizeNow = $false
  Show-Placed -Handle $handle -MaximizeNow $false
  Start-Sleep -Milliseconds 250
  $final = Get-WindowRect -Handle $handle
  $zoomed = [bool][WatchWin]::IsZoomed($handle)
  $inside = Test-OnMonitor -Rect $final -Maximized $false
  $attempts++
}

# The title is usually empty at the moment a window is first mapped; re-read it
# now that the settle loop has given the app time to set it.
$settledTitle = [WatchWin]::TitleOf($handle)
if ($settledTitle) { $title = $settledTitle }
$payload = [pscustomobject]@{
  ok            = $inside
  reason        = if ($inside) { $null } else { 'outside-target-display' }
  handle        = $handle.ToInt64()
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
  replaced      = [int]$replaced
  console       = [bool]$target.console
  class         = $target.class
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
