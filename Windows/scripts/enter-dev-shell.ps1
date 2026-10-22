# Puts MSVC and the newest installed Swift toolchain on PATH in this PowerShell
# session. Dot-source it: . Windows\scripts\enter-dev-shell.ps1 [-Architecture x86]
# Swift is only needed (and only installed) for x64, where the converter runs.
param([ValidateSet('x64', 'x86')] [string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$visualStudio = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'Visual Studio with the C++ x64 tools was not found.' }
Import-Module (Join-Path $visualStudio 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $visualStudio -SkipAutomaticLocation -DevCmdArguments "-arch=$Architecture -host_arch=x64" | Out-Null
# Compiler messages in English: localized ones are garbled over SSH and in CI logs.
$env:VSLANG = '1033'

if ($Architecture -ne 'x64') { return }

$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$toolchain = Get-ChildItem (Join-Path $swiftRoot 'Toolchains') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$runtime = Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$platform = Get-ChildItem (Join-Path $swiftRoot 'Platforms') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $toolchain -or -not $runtime -or -not $platform) { throw "Swift was not found under $swiftRoot." }
$env:Path = @((Join-Path $toolchain.FullName 'usr\bin'), (Join-Path $runtime.FullName 'usr\bin'), $env:Path) -join ';'
$env:SDKROOT = Join-Path $platform.FullName 'Windows.platform\Developer\SDKs\Windows.sdk\'
