# Removes azooKey Tree for Windows. Run from an elevated PowerShell.
# The user's data is kept unless -RemoveUserData is given: the learning data in
# %LOCALAPPDATA%\azooKey Tree, the settings in %APPDATA%\azooKey Tree and the AI
# API key in Credential Manager.
param(
    [string]$Destination = (Join-Path $env:ProgramFiles 'azooKey Tree'),
    [switch]$RemoveUserData
)
$ErrorActionPreference = 'Stop'
$textServiceTip = '0411:{DC2488F5-F672-4910-9FEA-6D97306B86DA}{30051583-6CBB-49E0-AEAA-91AE64DCA550}'

# Windows PowerShell 5.1 for the International module, as in install.ps1.
$removeFromLanguageList = @"
`$languages = Get-WinUserLanguageList
foreach (`$language in `$languages) {
    if (`$language.InputMethodTips -contains '$textServiceTip') { [void]`$language.InputMethodTips.Remove('$textServiceTip') }
}
Set-WinUserLanguageList `$languages -Force
"@
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $removeFromLanguageList

Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'azooKeyTreeHost' -ErrorAction SilentlyContinue
Get-Process azookey-windows-host, azookey-desktop-bridge, azookey-settings -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Force -LiteralPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\azooKey Tree の設定.lnk') -ErrorAction SilentlyContinue

foreach ($entry in @(@{ Dll = (Join-Path $Destination 'x86\azookey-tsf.dll'); Regsvr32 = "$env:SystemRoot\SysWOW64\regsvr32.exe" },
                     @{ Dll = (Join-Path $Destination 'azookey-tsf.dll'); Regsvr32 = "$env:SystemRoot\System32\regsvr32.exe" })) {
    if (Test-Path $entry.Dll) {
        Start-Process -FilePath $entry.Regsvr32 -ArgumentList @('/u', '/s', "`"$($entry.Dll)`"") -Wait | Out-Null
    }
}
# Applications that still have the DLL loaded keep it until they exit; what
# cannot be deleted now is left for the next uninstall or a restart.
Get-ChildItem $Destination -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -Recurse -Force $_.FullName } catch { Write-Warning "使用中のため残しました: $($_.FullName)" }
}
Remove-Item -Force $Destination -ErrorAction SilentlyContinue
if ($RemoveUserData) {
    Remove-Item -Recurse -Force (Join-Path $env:LOCALAPPDATA 'azooKey Tree') -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'azooKey Tree') -ErrorAction SilentlyContinue
    # The same target name as Windows/src/shared/api_key_credential.h.
    cmdkey /delete:'azooKey Tree/openai-compatible' | Out-Null
}
Write-Output 'azooKey Tree を削除しました。'
