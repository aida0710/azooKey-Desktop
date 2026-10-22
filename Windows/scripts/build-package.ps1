# Builds azooKey Tree for Windows (x64) and stages the files that install.ps1 copies.
#
#   pwsh Windows\scripts\build-package.ps1 [-Output <dir>]
#
# Needs Visual Studio Build Tools (MSVC, Windows SDK, CMake, Ninja) and Swift 6.2
# on PATH, for example after Enter-VsDevShell.
param(
    [string]$Output = (Join-Path $PSScriptRoot '..\..\build\windows-package')
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$frontendBuild = Join-Path $repository 'build\windows-frontend'

Push-Location (Join-Path $repository 'Core')
try {
    # Swift for Windows ships only +Asserts toolchains, whose SIL verifier stops
    # on a dependency (swift-tokenizers) that release Linux toolchains accept.
    swift build -c release --product azookey-desktop-bridge -Xswiftc -Xfrontend -Xswiftc -sil-verify-none
    if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
    $swiftBuild = (swift build -c release --show-bin-path).Trim()
} finally {
    Pop-Location
}

# Swift's toolchain also puts clang++ on PATH; the text service is built with MSVC.
cmake -S (Join-Path $repository 'Windows') -B $frontendBuild -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=cl -DCMAKE_RC_COMPILER=rc
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }
cmake --build $frontendBuild
if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

# The x86 text service needs the x86 compiler environment, so it is built in a
# separate PowerShell that enters that developer shell.
$frontendBuildX86 = Join-Path $repository 'build\windows-frontend-x86'
$x86Build = @"
. '$PSScriptRoot\enter-dev-shell.ps1' -Architecture x86
cmake -S '$(Join-Path $repository 'Windows')' -B '$frontendBuildX86' -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=cl -DCMAKE_RC_COMPILER=rc
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
cmake --build '$frontendBuildX86' --target azookey-tsf tsf-harness
exit `$LASTEXITCODE
"@
pwsh -NoProfile -NonInteractive -Command $x86Build
if ($LASTEXITCODE -ne 0) { throw "x86 text service build failed ($LASTEXITCODE)" }

if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
$bridgeDirectory = Join-Path $Output 'bridge'
New-Item -ItemType Directory -Force -Path $bridgeDirectory | Out-Null
Copy-Item (Join-Path $frontendBuild 'azookey-tsf.dll'), (Join-Path $frontendBuild 'azookey-windows-host.exe') $Output
New-Item -ItemType Directory -Force -Path (Join-Path $Output 'x86') | Out-Null
Copy-Item (Join-Path $frontendBuildX86 'azookey-tsf.dll') (Join-Path $Output 'x86')
Copy-Item (Join-Path $swiftBuild 'azookey-desktop-bridge.exe') $bridgeDirectory
# SwiftPM looks for <Package>_<Target>.resources next to the executable.
Get-ChildItem $swiftBuild -Directory -Filter '*.resources' | ForEach-Object {
    Copy-Item -Recurse $_.FullName $bridgeDirectory
}
# The Swift runtime (and the Visual C++ runtime it was built with) travels with
# the bridge so nothing has to be installed system-wide.
$swiftRuntime = Get-ChildItem (Split-Path (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source) -ErrorAction SilentlyContinue
if (-not $swiftRuntime) {
    $swiftRuntime = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Swift\Runtimes') -Directory |
        Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'usr\bin') }
}
$swiftRuntime | Where-Object { $_.Extension -eq '.dll' } | Copy-Item -Destination $bridgeDirectory
Copy-Item (Join-Path $repository 'LICENSE') $Output
Copy-Item (Join-Path $PSScriptRoot 'install.ps1'), (Join-Path $PSScriptRoot 'uninstall.ps1') $Output
Write-Output "staged: $Output"
