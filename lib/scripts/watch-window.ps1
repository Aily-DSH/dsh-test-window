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
  [string]$PidFile = '',
  [Parameter(Mandatory = $true)][string]$OutFile,
  [Parameter(Mandatory = $true)][int]$X,
  [Parameter(Mandatory = $true)][int]$Y,
  [Parameter(Mandatory = $true)][int]$W,
  [Parameter(Mandatory = $true)][int]$H,
  [switch]$Maximize,
  [switch]$TopMost,
  [switch]$Foreground,
  # Who gets the keyboard when the window is up: never | idle | always.
  # `idle` only raises the window when the user has not touched keyboard or mouse
  # for IdleMs — that is what stops a launch from eating the middle of a sentence.
  [string]$Focus = 'idle',
  [int]$IdleMs = 1500,
  # The command to start. Started here (not by the host) so it can be given a
  # console whose window is never painted on the primary display.
  [string]$Command = '',
  [string]$Cwd = '',
  [string]$SpawnFile = '',
  [string]$TitleContains = '',
  [int]$TimeoutMs = 20000,
  [int]$SettleMs = 6000,
  [switch]$IncludeChildren
)

$ErrorActionPreference = 'Stop'
$startedAt = Get-Date

# `-Foreground` is the old spelling of the `always` policy.
if ($Foreground) { $Focus = 'always' }
if ($Focus -ne 'never' -and $Focus -ne 'always') { $Focus = 'idle' }

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
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
  [DllImport("kernel32.dll")] public static extern uint GetTickCount();

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  [StructLayout(LayoutKind.Sequential)]
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

  [StructLayout(LayoutKind.Sequential)]
  public struct GUITHREADINFO {
    public int cbSize;
    public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
  }

  [DllImport("user32.dll")]
  public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO info);

  public const int GUI_INMOVESIZE = 0x00000002;
  public const int GUI_INMENUMODE = 0x00000004;
  public const int GUI_POPUPMENUMODE = 0x00000010;

  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);

  /// <summary>A mouse button is physically held (drag, long press, rubber-band select).</summary>
  public static bool MouseHeld() {
    const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_MBUTTON = 0x04;
    return (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0
        || (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0
        || (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0;
  }

  /// <summary>A menu is open somewhere: right-click context menu, menu bar, tray menu.</summary>
  public static bool MenuOpen() {
    bool open = false;
    uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    EnumWindows((h, l) => {
      uint pid;
      GetWindowThreadProcessId(h, out pid);
      if (pid == self) return true;
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(64);
      GetClassNameW(h, sb, sb.Capacity);
      // #32768 is the class of every popup menu Windows draws.
      if (sb.ToString() == "#32768") { open = true; return false; }
      return true;
    }, IntPtr.Zero);
    return open;
  }

  /// <summary>The foreground app is inside a menu loop or a move/size loop.</summary>
  public static bool ForegroundInMode() {
    IntPtr fg = GetForegroundWindow();
    if (fg == IntPtr.Zero) return false;
    uint thread = GetWindowThreadProcessId(fg, IntPtr.Zero);
    if (thread == 0) return false;
    var info = new GUITHREADINFO();
    info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (!GetGUIThreadInfo(thread, ref info)) return false;
    return (info.flags & (GUI_INMENUMODE | GUI_POPUPMENUMODE | GUI_INMOVESIZE)) != 0
        || info.hwndMenuOwner != IntPtr.Zero;
  }

  /// <summary>
  /// True while the user is moving or resizing this window (or holding it with
  /// the mouse). Re-asserting the rectangle then snaps the window back under the
  /// cursor, which is exactly what makes a drag fail; the watcher backs off
  /// instead and lets the user decide where it lives.
  /// </summary>
  public static bool UserMoving(IntPtr hWnd) {
    if (MouseHeld()) {
      // Holding the window itself, or dragging from one of its edges.
      uint ownThread = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
      IntPtr fg = GetForegroundWindow();
      if (fg != IntPtr.Zero && GetWindowThreadProcessId(fg, IntPtr.Zero) == ownThread) return true;
    }
    uint thread = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
    if (thread == 0) return false;
    var info = new GUITHREADINFO();
    info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (!GetGUIThreadInfo(thread, ref info)) return false;
    if ((info.flags & GUI_INMOVESIZE) != 0) return true;
    // A drag also shows up as mouse capture on the window; require the button to
    // be down so a completed click is not mistaken for one.
    if (info.hwndCapture == hWnd && MouseHeld()) return true;
    return false;
  }

  /// <summary>Milliseconds since the user last touched keyboard or mouse.</summary>
  public static uint IdleMs() {
    var info = new LASTINPUTINFO();
    info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
    if (!GetLastInputInfo(ref info)) return uint.MaxValue;
    return unchecked(GetTickCount() - info.dwTime);
  }

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

  /// <summary>
  /// Windows worth looking at: owned by one of `pids`, or not present in the
  /// pre-launch snapshot `before` (so a window the launcher handed to another
  /// process is still found). Filtering here keeps the polling loop cheap.
  /// </summary>
  public static List<IntPtr> Candidates(uint[] pids, long[] before) {
    uint self = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    var wanted = new HashSet<uint>(pids);
    var known = new HashSet<long>(before);
    var found = new List<IntPtr>();
    EnumWindows((hWnd, lParam) => {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (pid == self) return true;
      bool owned = pids.Length > 0 && wanted.Contains(pid);
      if (!owned && known.Contains(hWnd.ToInt64())) return true;
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

/// <summary>
/// Starts the test program in a *new console whose window is created hidden*.
///
/// Two cheaper options both have a flaw this avoids:
///   - CREATE_NO_WINDOW / windowsHide: the program has no console handles, so a
///     launcher script's `timeout`, `pause` or `set /p` fail immediately;
///   - a plain visible console: Windows paints that black box on the primary
///     display before anyone can move it — the flash the user sees.
/// CREATE_NEW_CONSOLE keeps the console (and its handles) real, while
/// STARTF_USESHOWWINDOW + SW_HIDE keeps the window from ever being shown. If the
/// console turns out to be the test window after all, the watcher shows it
/// itself once it sits on the right display.
/// </summary>
public static class SpawnWin {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct STARTUPINFO {
    public int cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
    public int dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION {
    public IntPtr hProcess, hThread;
    public int dwProcessId, dwThreadId;
  }

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool CreateProcessW(string app, StringBuilder commandLine, IntPtr processAttributes,
    IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
    string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInfo);

  const uint CREATE_NEW_CONSOLE = 0x00000010;
  const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
  const uint STARTF_USESHOWWINDOW = 0x00000001;
  const short SW_HIDE = 0;

  public static int Hidden(string app, string commandLine, string currentDirectory) {
    var info = new STARTUPINFO();
    info.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    info.dwFlags = (int)STARTF_USESHOWWINDOW;
    info.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION processInfo;
    bool ok = CreateProcessW(app, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
      CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero,
      string.IsNullOrEmpty(currentDirectory) ? null : currentDirectory, ref info, out processInfo);
    if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return processInfo.dwProcessId;
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
$baselineHandles = [WatchWin]::Every()
$baselineKeys = New-Object 'System.Collections.Generic.List[Int64]'
$baseline = New-Object System.Collections.Generic.HashSet[Int64]
foreach ($handle in $baselineHandles) {
  $key = $handle.ToInt64()
  if ($baseline.Add($key)) { $baselineKeys.Add($key) }
}
[Int64[]]$baselineArray = $baselineKeys.ToArray()

# Ready handshake: the host waits for this file, so the program is only started
# once the watcher is already polling.
try { Set-Content -LiteralPath "$OutFile.ready" -Value ([string]$PID) -Encoding ASCII -Force } catch { }

# --------------------------------------------------------------- launching
# The program is started here rather than by the host, because only a spawn with
# CREATE_NEW_CONSOLE + SW_HIDE gives a console that works (`timeout`, `pause`,
# `set /p` inside a .cmd launcher) without painting a black box on the primary
# display first. That flash, plus the keyboard focus the console used to grab,
# are the two things this avoids.
$prevForeground = [WatchWin]::GetForegroundWindow()
$spawnedPid = 0
$spawnError = ''
if ($Command -ne '') {
  $comspec = $env:ComSpec
  if (-not $comspec) { $comspec = "$env:SystemRoot\System32\cmd.exe" }
  try {
    # Same quoting the host's shell would use: /s strips exactly the outer pair.
    $spawnedPid = [SpawnWin]::Hidden($comspec, ('/d /s /c "' + $Command + '"'), $Cwd)
  } catch {
    $spawnError = $_.Exception.Message
  }
  if ($SpawnFile -ne '') {
    $spawnPayload = if ($spawnError -ne '') {
      [pscustomobject]@{ ok = $false; error = $spawnError; command = $Command }
    } else {
      [pscustomobject]@{ ok = $true; pid = $spawnedPid; command = $Command }
    }
    try {
      $spawnUtf8 = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($SpawnFile, (ConvertTo-Json -InputObject $spawnPayload -Compress), $spawnUtf8)
    } catch { }
  }
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

# A window is placed, not necessarily activated. Whether this launch may take the
# keyboard is the user's choice:
#   always — raise the window (the old behaviour)
#   idle   — raise it only when the user has not touched keyboard/mouse for
#            IdleMs, so a launch never interrupts a sentence being typed
#   never  — never raise it, and put the keyboard back if the program grabs it
$gaveFocus = $false

# The user is in the middle of something right now: a mouse button is held (drag,
# rubber-band select, long press), a window is being moved, or a context menu is
# open. Nothing here may compete with that — no snapping the rectangle back, no
# keyboard changes — because that is what makes a drag or a menu click fail.
function Test-UserBusy {
  if ([WatchWin]::MouseHeld()) { return $true }
  if ([WatchWin]::MenuOpen()) { return $true }
  if ([WatchWin]::ForegroundInMode()) { return $true }
  return $false
}

function Test-FocusAllowed {
  if ($Foreground -or $Focus -eq 'always') { return $true }
  if ($Focus -eq 'never') { return $false }
  if (Test-UserBusy) { return $false }
  return ([WatchWin]::IdleMs() -ge $IdleMs)
}

# Put the keyboard back where the user left it. Engines and toolkits call
# SetForegroundWindow on their own window the moment it maps, which is what types
# the user's next words into a game they did not ask to switch to. This runs while
# the window settles, so the correction lands within a frame or two.
function Restore-Focus {
  param([IntPtr]$Handle, [int]$OwnerPid)
  if ($script:gaveFocus) { return }
  if (Test-UserBusy) { return }
  if ($prevForeground -eq [IntPtr]::Zero) { return }
  if (-not [WatchWin]::IsWindow($prevForeground)) { return }
  $fg = [WatchWin]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero -or $fg -eq $prevForeground) { return }
  # Only reclaim the keyboard from the window we just placed (or its process):
  # whatever else the user switched to in the meantime is none of our business.
  if ($fg -ne $Handle -and [WatchWin]::PidOf($fg) -ne [uint32]$OwnerPid) { return }
  [WatchWin]::BringToFront($prevForeground) | Out-Null
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
  if (Test-FocusAllowed) {
    [WatchWin]::BringToFront($Handle) | Out-Null
    $script:gaveFocus = $true
  }
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

# Picking the window, in order of confidence:
#   owned  — belongs to the process tree of the command          → take it at once
#   fresh  — new window of a process started after this launch   → take it after a
#            short grace, so the program's own window can still win over a helper
#            window that merely appeared in the same second
#   other  — any other window that appeared while we waited      → last resort
#   console— the shell wrapper's console box                    → last resort
# A window that was already on screen before the launch is never a candidate, so
# the chat window (or anything the user already had open) can never be taken.
$freshCache = @{}
$launchMark = $startedAt.AddSeconds(-1)

# Whether the command that was started for this watcher is still running. While
# it is, its own window may still be about to appear.
function Test-LauncherAlive {
  foreach ($root in $roots) {
    if (Get-Process -Id $root -ErrorAction SilentlyContinue) { return $true }
  }
  return $false
}

# Whether the process behind a window was started by this launch.
function Test-FreshProcess {  param([uint32]$Owner)
  if ($freshCache.ContainsKey($Owner)) { return $freshCache[$Owner] }
  $isFresh = $false
  try {
    $info = Get-Process -Id $Owner -ErrorAction Stop
    $isFresh = $info.StartTime -ge $launchMark
  } catch {
    $isFresh = $false
  }
  $freshCache[$Owner] = $isFresh
  return $isFresh
}

function Get-Candidate {
  param($PidSet, [Int64[]]$Known)
  $picked = @{ owned = $null; fresh = $null; other = $null; console = $null }
  $scores = @{ owned = -1; fresh = -1; other = -1; console = -1 }
  [uint32[]]$pidArray = @()
  if ($PidSet -and $PidSet.Count -gt 0) { $pidArray = [uint32[]]@($PidSet) }
  foreach ($handle in [WatchWin]::Candidates($pidArray, $baselineArray)) {
    $key = $handle.ToInt64()
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
    $visible = [WatchWin]::IsWindowVisible($handle)
    $owner = [WatchWin]::PidOf($handle)
    $owned = ($pidArray.Length -gt 0) -and ($pidArray -contains $owner)
    # Only a window the user can actually see is the test window. Engines and
    # drivers keep invisible windows around (see $helperClasses above) that are
    # easy to mistake for the real thing; the real window is mapped, then shown.
    # The one exception is the launcher console this watcher created hidden on
    # purpose: for a console-only program that window *is* the answer, and it is
    # shown by us once it sits on the target display.
    if (-not $visible -and -not ($isConsole -and $owned)) { continue }
    $title = [WatchWin]::TitleOf($handle)
    if ($title.StartsWith('__wgl')) { continue }
    if ($TitleContains -ne '' -and -not $title.Contains($TitleContains)) { continue }
    # The console box belongs to the wrapper even when the wrapper is in our own
    # process tree, so it never counts as "owned": it is the last resort only.
    if ($isConsole) { $tier = 'console' }
    elseif ($owned) { $tier = 'owned' }
    elseif (Test-FreshProcess -Owner $owner) { $tier = 'fresh' }
    else { $tier = 'other' }
    $score = [int]([Math]::Min(($rw * $rh) / 1000, 900000))
    if ($title -ne '') { $score += 1000 }
    if ($score -le $scores[$tier]) { continue }
    $scores[$tier] = $score
    $picked[$tier] = [pscustomobject]@{
      handle = $handle; class = $class; title = $title; pid = [int]$owner; tier = $tier
      x = $rx; y = $ry; w = $rw; h = $rh; visible = $visible; console = $isConsole
    }
  }
  return [pscustomobject]@{ owned = $picked.owned; fresh = $picked.fresh; other = $picked.other; console = $picked.console }
}

$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$roots = @()
$pidSet = New-Object System.Collections.Generic.HashSet[uint32]
$known = New-Object System.Collections.Generic.List[Int64]

# The program started above already gives us the root of the tree. The PidFile
# handshake is kept for the case where the host starts the program itself.
if ($spawnedPid -gt 0) {
  $roots = @([uint32]$spawnedPid)
  foreach ($value in $roots) { [void]$pidSet.Add($value) }
} elseif ($PidFile -ne '') {
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
}

# The timeout is about waiting for the *window*, so it starts now, not when this
# watcher was booted.
$deadline = (Get-Date).AddMilliseconds($TimeoutMs)

# Nothing to wait for when the command never started: report it at once instead
# of sitting out the whole timeout.
if ($spawnError -ne '') {
  $failed = [pscustomobject]@{
    ok = $false; reason = 'spawn-failed'; error = $spawnError; command = $Command
    waitedMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
  }
  $failedJson = ConvertTo-Json -InputObject $failed -Compress
  try {
    $failedUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $failedJson, $failedUtf8)
  } catch { }
  $failedJson
  exit 4
}

$tree = Get-ProcessTree -Roots $roots
foreach ($p in $tree) { [void]$pidSet.Add($p) }
$lastTreeScan = Get-Date

$target = $null
$consoleFallback = $null
$otherFallback = $null
$pending = $null
$pendingAt = $null

while ((Get-Date) -lt $deadline) {
  if (((Get-Date) - $lastTreeScan).TotalMilliseconds -ge 300) {
    $tree = Get-ProcessTree -Roots $roots
    foreach ($p in $tree) { [void]$pidSet.Add($p) }
    $lastTreeScan = Get-Date
  }
  $found = Get-Candidate -PidSet $pidSet -Known $known
  # A window of the command's own process tree is the answer, no need to wait.
  if ($found.owned) { $target = $found.owned; break }
  # A window of a newly started process is very likely the program too, but a
  # launcher can also flash its own helper window first, and another launch on
  # the same machine can put a window on screen at the same moment: only commit
  # to a stranger once the launcher itself has exited without a window of its own.
  if ($found.fresh) {
    if (-not $pending) {
      $pending = $found.fresh
      $pendingAt = Get-Date
    } elseif (((Get-Date) - $pendingAt).TotalMilliseconds -ge 900 -and -not (Test-LauncherAlive)) {
      $target = $pending
      break
    }
  }
  if ($found.console) { $consoleFallback = $found.console }
  if ($found.other) { $otherFallback = $found.other }
  Start-Sleep -Milliseconds 12
}

if (-not $target) { $target = $pending }
if (-not $target) { $target = $otherFallback }
# Nothing that looks like an app window: fall back to the console box the
# launcher was started in, which is what a console-only program shows.
if (-not $target) { $target = $consoleFallback }

if (-not $target) {
  # A launcher that already exited with a non-zero code never had a chance to
  # open anything: say so instead of blaming the timeout.
  $exitCode = $null
  if ($spawnedPid -gt 0) {
    try {
      $launcher = [System.Diagnostics.Process]::GetProcessById($spawnedPid)
      if ($launcher.HasExited) { $exitCode = $launcher.ExitCode }
    } catch { }
  }
  $failedBecauseExit = ($null -ne $exitCode) -and ($exitCode -ne 0)
  $none = [pscustomobject]@{
    ok = $false
    reason = if ($failedBecauseExit) { 'command-failed' } else { 'no-window' }
    exitCode = $exitCode
    pids = @($pidSet)
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
# The program may already have asked for the foreground while it mapped its
# window; give the keyboard straight back when it did.
Start-Sleep -Milliseconds 30
Restore-Focus -Handle $handle -OwnerPid $ownerPid

# Phase 2: settle. Applications such as the Godot 4 editor restore their own
# saved geometry (and even their own maximized state) after the first frames, so
# keep re-asserting the placement for a few seconds instead of trusting one call.
$attempts = 1
$replaced = 0
$maximizeNow = [bool]$Maximize
$maximizeTries = 0
$userMoved = $false
$settleBudget = [Math]::Max($SettleMs, 500)
$settleStarted = Get-Date
$pausedMs = 0
# Time spent waiting for the user to finish something cannot be spent on
# correcting the placement, so it does not eat the budget — but a single long
# session (a menu left open, a drag that never ends) cannot hold the watcher
# hostage forever either.
$hardStop = $settleStarted.AddMilliseconds($settleBudget + 20000)
while ((Get-Date) -lt $hardStop) {
  Start-Sleep -Milliseconds 50

  # The user grabbed the window itself: re-asserting the rectangle would snap it
  # back under their cursor and break the drag. The placement is theirs now.
  if ([WatchWin]::UserMoving($handle)) {
    $userMoved = $true
    break
  }
  # Anything else the user is doing (holding a menu open, dragging something
  # else, a long press) only pauses the correction, so the window still ends up
  # in the right place once they let go.
  if (Test-UserBusy) {
    $pausedMs += 50
    continue
  }
  if (((Get-Date) - $settleStarted).TotalMilliseconds - $pausedMs -ge $settleBudget) { break }
  # Keep the keyboard where the user left it while the window settles.
  Restore-Focus -Handle $handle -OwnerPid $ownerPid

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
      if ($found.owned) { $swap = $found.owned }
      elseif ($found.fresh) { $swap = $found.fresh }
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
if ($maximizeNow -and -not [WatchWin]::IsZoomed($handle) -and -not $userMoved) {
  Move-Window -Handle $handle
  [WatchWin]::ShowWindow($handle, [WatchWin]::SW_MAXIMIZE) | Out-Null
  Start-Sleep -Milliseconds 400
  $attempts++
}
$final = Get-WindowRect -Handle $handle
$zoomed = [bool][WatchWin]::IsZoomed($handle)
$inside = Test-OnMonitor -Rect $final -Maximized ($maximizeNow -and $zoomed)
if (-not $inside -and -not $userMoved) {
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
Restore-Focus -Handle $handle -OwnerPid $ownerPid
$settledTitle = [WatchWin]::TitleOf($handle)
if ($settledTitle) { $title = $settledTitle }
$payload = [pscustomobject]@{
  # A window the user dragged somewhere else is not a failure: it is where they
  # want it. Only a placement we made ourselves can be "outside the display".
  ok            = ($inside -or $userMoved)
  reason        = if ($inside -or $userMoved) { $null } else { 'outside-target-display' }
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
  userMoved     = [bool]$userMoved
  attempts      = [int]$attempts
  replaced      = [int]$replaced
  console       = [bool]$target.console
  class         = $target.class
  focus         = $Focus
  focusGiven    = [bool]$script:gaveFocus
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
