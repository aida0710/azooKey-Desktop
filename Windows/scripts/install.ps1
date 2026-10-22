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
Get-Process azookey-windows-host, azookey-desktop-bridge -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$source = $PSScriptRoot
foreach ($item in 'azookey-tsf.dll', 'azookey-windows-host.exe', 'bridge', 'LICENSE', 'uninstall.ps1') {
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

$dll = Join-Path $Destination 'azookey-tsf.dll'
$registration = Start-Process -FilePath "$env:SystemRoot\System32\regsvr32.exe" -ArgumentList @('/s', "`"$dll`"") -Wait -PassThru
if ($registration.ExitCode -ne 0) { throw "regsvr32 failed ($($registration.ExitCode))" }

# Start the converter host at sign-in so the first key press does not wait for it.
$hostPath = Join-Path $Destination 'azookey-windows-host.exe'
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $hostRunValue -Value "`"$hostPath`""

# Show azooKey Tree in this user's Japanese keyboards.
$languages = Get-WinUserLanguageList
$japanese = $languages | Where-Object { $_.LanguageTag -eq 'ja' } | Select-Object -First 1
if (-not $japanese) {
    $languages.Add('ja')
    $japanese = $languages | Where-Object { $_.LanguageTag -eq 'ja' } | Select-Object -First 1
}
if (-not ($japanese.InputMethodTips -contains $textServiceTip)) {
    $japanese.InputMethodTips.Add($textServiceTip)
    Set-WinUserLanguageList $languages -Force
}
Write-Output "installed: $Destination"
Write-Output '入力方式の一覧に azooKey Tree を追加しました。Win+Space で切り替えられます。'
