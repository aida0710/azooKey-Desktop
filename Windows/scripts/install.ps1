# Installs azooKey Tree for Windows from the staged package (this script's folder).
# Run from an elevated PowerShell: registering a text service writes HKLM.
#
#   pwsh -File install.ps1 [-Destination "C:\Program Files\azooKey Tree"]
param(
    [string]$Destination = (Join-Path $env:ProgramFiles 'azooKey Tree')
)
$ErrorActionPreference = 'Stop'
$textServiceTip = '0411:{DC2488F5-F672-4910-9FEA-6D97306B86DA}{30051583-6CBB-49E0-AEAA-91AE64DCA550}'
$hostRunValue = 'azooKeyTreeHost'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '管理者として実行してください（入力方式の登録に必要です）。'
}

# A running host or loaded DLL would keep the old files locked.
Get-Process azookey-windows-host, azookey-desktop-bridge, azookey-settings, azookey-ai-transform -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$source = $PSScriptRoot
foreach ($item in 'azookey-tsf.dll', 'x86', 'azookey-windows-host.exe', 'azookey-settings.exe', 'azookey-ai-transform.exe', 'build-info.txt', 'bridge', 'models', 'licenses', 'LICENSE', 'uninstall.ps1') {
    $target = Join-Path $Destination $item
    if (Test-Path $target) {
        try { Remove-Item -Recurse -Force $target }
        catch {
            # Applications that already loaded the old DLL keep it open; the
            # rename lets the new file take its place until they restart.
            Rename-Item $target ($item + '.old-' + [DateTime]::Now.ToString('yyyyMMddHHmmss'))
        }
    }
    Copy-Item -Recurse (Join-Path $source $item) $target
}

# 64-bit and 32-bit applications each load the build of their own bitness,
# registered under the same CLSID by the matching regsvr32.
$registrations = @(
    @{ Dll = (Join-Path $Destination 'azookey-tsf.dll'); Regsvr32 = "$env:SystemRoot\System32\regsvr32.exe" },
    @{ Dll = (Join-Path $Destination 'x86\azookey-tsf.dll'); Regsvr32 = "$env:SystemRoot\SysWOW64\regsvr32.exe" }
)
foreach ($entry in $registrations) {
    $registration = Start-Process -FilePath $entry.Regsvr32 -ArgumentList @('/s', "`"$($entry.Dll)`"") -Wait -PassThru
    if ($registration.ExitCode -ne 0) { throw "regsvr32 failed for $($entry.Dll) ($($registration.ExitCode))" }
}

# Start the converter host at sign-in so the first key press does not wait for it.
$hostPath = Join-Path $Destination 'azookey-windows-host.exe'
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $hostRunValue -Value "`"$hostPath`""

# Every user finds the settings window in the Start menu. WScript.Shell saves a
# shortcut only under a name in the system's ANSI code page (an English system
# cannot save a Japanese name), so it is saved under an ASCII name and renamed.
$startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$settingsShortcutName = 'azooKey Tree の設定.lnk'
$asciiShortcut = Join-Path $startMenu 'azooKey Tree Settings.lnk'
$settingsShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($asciiShortcut)
$settingsShortcut.TargetPath = Join-Path $Destination 'azookey-settings.exe'
$settingsShortcut.WorkingDirectory = $Destination
$settingsShortcut.Save()
Move-Item -Force $asciiShortcut (Join-Path $startMenu $settingsShortcutName)

# Show azooKey Tree in this user's Japanese keyboards. The International
# module fails to marshal its arguments under PowerShell 7 on some systems
# (seen on GitHub's Windows images), so Windows PowerShell 5.1 runs it.
$addToLanguageList = @"
`$languages = Get-WinUserLanguageList
`$japanese = `$languages | Where-Object { `$_.LanguageTag -eq 'ja' } | Select-Object -First 1
if (-not `$japanese) {
    `$languages.Add('ja')
    `$japanese = `$languages | Where-Object { `$_.LanguageTag -eq 'ja' } | Select-Object -First 1
}
if (-not (`$japanese.InputMethodTips -contains '$textServiceTip')) {
    `$japanese.InputMethodTips.Add('$textServiceTip')
    Set-WinUserLanguageList `$languages -Force
}
"@
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $addToLanguageList
if ($LASTEXITCODE -ne 0) { throw "could not add azooKey Tree to the language list ($LASTEXITCODE)" }
Write-Output "installed: $Destination"
Write-Output '入力方式の一覧に azooKey Tree を追加しました。Win+Space で切り替えられます。'
