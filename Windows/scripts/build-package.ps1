# Builds azooKey Tree for Windows (x64) and stages the files that install.ps1 copies.
#
#   pwsh Windows\scripts\build-package.ps1 [-Output <dir>] [-LlamaDirectory <dir>] [-ModelDirectory <dir>]
#
# Needs Visual Studio Build Tools (MSVC, Windows SDK, CMake, Ninja) and Swift 6.2
# on PATH, for example after Enter-VsDevShell, plus Zenzai's two inputs:
# llama.cpp from build-llama.ps1 and the model from Tools\fetch-models.py.
param(
    [string]$Output = (Join-Path $PSScriptRoot '..\..\build\windows-package'),
    # build-llama.ps1's install folder: DLLs in bin, import libraries in lib.
    [string]$LlamaDirectory = (Join-Path $PSScriptRoot '..\..\build\llama-windows\install'),
    # Verified by `python Tools\fetch-models.py --model gguf` (same source and
    # SHA-256 as the macOS and Linux packages).
    [string]$ModelDirectory = (Join-Path $PSScriptRoot '..\..\build\models')
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$frontendBuild = Join-Path $repository 'build\windows-frontend'
# The bridge enables Zenzai when AZOOKEY_RESOURCES holds this file (BridgeMain).
$zenzaiModelName = 'ggml-model-Q5_K_M.gguf'

if (-not (Test-Path (Join-Path $LlamaDirectory 'lib\llama.lib'))) {
    throw "llama.cpp is not built in $LlamaDirectory; run Windows\scripts\build-llama.ps1"
}
if (-not (Test-Path (Join-Path $ModelDirectory $zenzaiModelName))) {
    throw "$zenzaiModelName is not in $ModelDirectory; run python Tools\fetch-models.py --model gguf"
}
$llamaLibraries = (Resolve-Path (Join-Path $LlamaDirectory 'lib')).Path

Push-Location (Join-Path $repository 'Core')
try {
    # ZenzaiCPU builds the converter against its llama.cpp systemLibrary target,
    # which links llama.lib; the converter also calls ggml's CPU device lookup.
    # Swift for Windows ships only +Asserts toolchains, whose SIL verifier stops
    # on a dependency (swift-tokenizers) that release Linux toolchains accept.
    swift build -c release --product azookey-desktop-bridge --traits ZenzaiCPU `
        -Xswiftc "-L$llamaLibraries" -Xswiftc -lggml -Xswiftc -Xfrontend -Xswiftc -sil-verify-none
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

if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
$bridgeDirectory = Join-Path $Output 'bridge'
New-Item -ItemType Directory -Force -Path $bridgeDirectory | Out-Null
Copy-Item (Join-Path $frontendBuild 'azookey-tsf.dll'), (Join-Path $frontendBuild 'azookey-windows-host.exe') $Output
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
# llama.cpp's DLLs use the same Visual C++ runtime (build-llama.ps1 checks).
Copy-Item (Join-Path $LlamaDirectory 'bin\*.dll') $bridgeDirectory
# The host passes this folder to the bridge as AZOOKEY_RESOURCES.
$modelsDirectory = Join-Path $Output 'models'
New-Item -ItemType Directory -Force -Path $modelsDirectory | Out-Null
Copy-Item (Join-Path $ModelDirectory $zenzaiModelName) $modelsDirectory
Copy-Item (Join-Path $repository 'LICENSE') $Output
# Notices for llama.cpp (MIT) and Zenzai's model (Apache-2.0), named as
# Tools/collect-licenses.py names them in the macOS and Linux packages.
$licensesDirectory = Join-Path $Output 'licenses'
New-Item -ItemType Directory -Force -Path $licensesDirectory | Out-Null
Copy-Item (Join-Path $repository 'packaging\licenses\llama.txt') $licensesDirectory
$apacheLicense = Join-Path $repository 'Core\.build\checkouts\AzooKeyKanaKanjiConverter\Sources\KanaKanjiConverterModuleWithDefaultDictionary\azooKey_dictionary_storage\LICENSE'
Copy-Item $apacheLicense (Join-Path $licensesDirectory 'Apache-2.0.txt')
Copy-Item (Join-Path $PSScriptRoot 'install.ps1'), (Join-Path $PSScriptRoot 'uninstall.ps1') $Output
Write-Output "staged: $Output"
