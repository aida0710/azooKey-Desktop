# Checks the installed settings app the way a user starts it: the Start menu
# entry, the window opening, a second start handing its page to the open window
# instead of opening another, and closing the window ending the app.
# Needs a desktop session and an installed package (install.ps1).
# Exit code is the number of failed checks.
#
#   pwsh Windows/tests/settings-app-cases.ps1 [-Destination "C:\Program Files\azooKey Tree"]
param(
    [string]$Destination = (Join-Path $env:ProgramFiles 'azooKey Tree')
)
$ErrorActionPreference = 'Stop'
# A started app has at most this long to reach its message loop or to exit.
$startLimitMilliseconds = 15000
$settingsWindowClass = 'azooKeyTreeSettings'
$closeMessage = 0x0010  # WM_CLOSE
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SettingsAppWindows {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@
$failed = 0
function Check([bool]$condition, [string]$description) {
    if ($condition) { "PASS $description" } else { "FAIL $description"; $script:failed++ }
}

$shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\azooKey Tree の設定.lnk'
Check (Test-Path -LiteralPath $shortcut) 'the Start menu has "azooKey Tree の設定"'
# WScript.Shell reads shortcuts only under names in the system's ANSI code page (see install.ps1).
$readableCopy = Join-Path ([IO.Path]::GetTempPath()) 'azookey-settings-shortcut.lnk'
Copy-Item -LiteralPath $shortcut $readableCopy -Force
$target = (New-Object -ComObject WScript.Shell).CreateShortcut($readableCopy).TargetPath
Remove-Item $readableCopy
Check ($target -eq (Join-Path $Destination 'azookey-settings.exe')) 'the entry starts the installed settings app'
Check (Test-Path (Join-Path $Destination 'build-info.txt')) 'the package records its build for the support report'

$first = Start-Process -FilePath $target -ArgumentList '--page', 'ai' -PassThru
Check ($first.WaitForInputIdle($startLimitMilliseconds)) 'the settings app starts'
$window = [SettingsAppWindows]::FindWindow($settingsWindowClass, $null)
Check ($window -ne [IntPtr]::Zero) 'the settings window opens'

$second = Start-Process -FilePath $target -ArgumentList '--page', 'dictionary' -PassThru
Check ($second.WaitForExit($startLimitMilliseconds) -and $second.ExitCode -eq 0) 'a second start hands its page to the open window and exits'
Check (-not $first.HasExited -and [SettingsAppWindows]::FindWindow($settingsWindowClass, $null) -eq $window) 'the first window stays the only one'

[void][SettingsAppWindows]::PostMessage($window, $closeMessage, [IntPtr]::Zero, [IntPtr]::Zero)
Check ($first.WaitForExit($startLimitMilliseconds)) 'closing the window ends the app'
"$failed check(s) failed"
exit $failed
