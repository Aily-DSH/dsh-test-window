<#
  Enumerate the physical displays of this machine as JSON.
  Coordinates are physical pixels and match SetWindowPos, because the process
  declares itself DPI-aware before asking Windows anything.
#>
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DpiAware {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
}
'@

try { [DpiAware]::SetProcessDpiAwareness(2) | Out-Null } catch { }
try { [DpiAware]::SetProcessDPIAware() | Out-Null } catch { }

$screens = [System.Windows.Forms.Screen]::AllScreens
$index = 0
$result = foreach ($screen in $screens) {
  $index += 1
  [pscustomobject]@{
    index      = $index
    device     = $screen.DeviceName
    primary    = [bool]$screen.Primary
    x          = [int]$screen.Bounds.X
    y          = [int]$screen.Bounds.Y
    width      = [int]$screen.Bounds.Width
    height     = [int]$screen.Bounds.Height
    workX      = [int]$screen.WorkingArea.X
    workY      = [int]$screen.WorkingArea.Y
    workWidth  = [int]$screen.WorkingArea.Width
    workHeight = [int]$screen.WorkingArea.Height
  }
}

ConvertTo-Json -InputObject @($result) -Compress -Depth 4
