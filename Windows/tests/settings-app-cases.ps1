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
$getSelectionMessage = 0x0188  # LB_GETCURSEL
# The page list's order follows Core's definition: input, conversion, dictionary, ai, support.
$dictionaryPage = 2
# PowerShell passes $null as "" to a string parameter; FindWindow needs a real null title.
$anyTitle = [NullString]::Value
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SettingsAppWindows {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int size);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr window);

    // "class / title / visible" of every top-level window the process owns.
    public static string[] WindowsOf(uint processId) {
        var found = new System.Collections.Generic.List<string>();
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId) {
                var name = new System.Text.StringBuilder(256);
                var text = new System.Text.StringBuilder(256);
                GetClassName(window, name, name.Capacity);
                GetWindowText(window, text, text.Capacity);
                found.Add(name + " / " + text + " / " + (IsWindowVisible(window) ? "visible" : "hidden"));
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
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

# The app sets this event once its window exists (settings_main.cpp); a second
# start waits for it too. Creating it here first means the signal cannot be missed.
$windowReady = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, 'Local\azooKeyTreeSettingsWindowReady')
$first = Start-Process -FilePath $target -ArgumentList '--page', 'ai' -PassThru
Check ($windowReady.WaitOne($startLimitMilliseconds)) 'the settings app reports its window'
$window = [SettingsAppWindows]::FindWindow($settingsWindowClass, $anyTitle)
Check ($window -ne [IntPtr]::Zero -and -not $first.HasExited) 'the settings window opens'

$second = Start-Process -FilePath $target -ArgumentList '--page', 'dictionary' -PassThru
Check ($second.WaitForExit($startLimitMilliseconds) -and $second.ExitCode -eq 0) 'a second start hands its page to the open window and exits'
Check (-not $first.HasExited -and [SettingsAppWindows]::FindWindow($settingsWindowClass, $anyTitle) -eq $window) 'the first window stays the only one'
# The open window shows the second start's page once it has read Core's definition.
$pageList = [SettingsAppWindows]::FindWindowEx($window, [IntPtr]::Zero, 'ListBox', $anyTitle)
$deadline = [DateTime]::UtcNow.AddMilliseconds($startLimitMilliseconds)
do {
    $shownPage = [int][SettingsAppWindows]::SendMessage($pageList, $getSelectionMessage, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($shownPage -eq $dictionaryPage) { break }
    Start-Sleep -Milliseconds 100
} while ([DateTime]::UtcNow -lt $deadline)
Check ($shownPage -eq $dictionaryPage) 'the open window switches to the page the second start asked for'

[void][SettingsAppWindows]::PostMessage($window, $closeMessage, [IntPtr]::Zero, [IntPtr]::Zero)
$closedAt = Get-Date
$ended = $first.WaitForExit($startLimitMilliseconds)
Check $ended 'closing the window ends the app'
if (-not $ended) {
    # What kept the app: a window still open (a dialog?) or a process without windows.
    "  windows of the app: " + (([SettingsAppWindows]::WindowsOf([uint32]$first.Id)) -join ' | ')
    $screenshots = Join-Path $PSScriptRoot '..\..\build\screenshots'
    New-Item -ItemType Directory -Force -Path $screenshots | Out-Null
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    [System.Drawing.Graphics]::FromImage($bitmap).CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $screenshots 'settings-app-not-closed.png'))
    $exited = $first.WaitForExit(30000)
    "  the app " + $(if ($exited) { "ended $([math]::Round(((Get-Date) - $closedAt).TotalSeconds, 1)) s after the close request" } else { 'was still running 45 s after the close request' })
    if (-not $exited) { Stop-Process -Id $first.Id -Force }
}
"$failed check(s) failed"
exit $failed
